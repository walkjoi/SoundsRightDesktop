#!/bin/bash
# Builds SoundsRight.app using SwiftPM, without needing an Apple Developer
# account. Output: build.noindex/SoundsRight.app, ad-hoc signed. The .noindex
# suffix keeps Spotlight/Launchpad from listing the build artifact as a second
# "SoundsRight" alongside the installed copy.
#
# Usage: Scripts/build-app.sh [release]
#
# Toolchain: as of SDK 27 SwiftUI's @State is a macro, and macro plugins ship
# only with full Xcode — so a Command-Line-Tools-only toolchain can no longer
# compile any SwiftUI view. Xcode is therefore required, but it need not be the
# active developer directory: this script points at it directly, so
# `xcode-select` can stay on the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build.noindex/SoundsRight.app"

# libSwiftUIMacros.dylib is what expands @State; it lives in the Xcode platform
# directory and has no Command Line Tools equivalent.
SWIFTUI_MACROS="Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
CURRENT_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

if [ ! -f "$CURRENT_DEVELOPER_DIR/$SWIFTUI_MACROS" ]; then
    if [ -f "/Applications/Xcode.app/Contents/Developer/$SWIFTUI_MACROS" ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        echo "Using the Xcode toolchain at $DEVELOPER_DIR (SwiftUI macro plugins)"
    else
        echo "error: Xcode is required — SwiftUI's macro plugins ship only with it," >&2
        echo "       and $CURRENT_DEVELOPER_DIR does not provide them." >&2
        exit 1
    fi
fi

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/SoundsRight" "$APP/Contents/MacOS/SoundsRight"

# Substitute the Xcode build-setting variables Info.plist expects.
sed -e 's/\$(EXECUTABLE_NAME)/SoundsRight/g' \
    -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.soundsright.desktop/g' \
    -e 's/\$(PRINCIPAL_CLASS)/NSApplication/g' \
    SoundsRight/Info.plist > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# SPM resource bundles (e.g. KeyboardShortcuts localizations) must sit in
# Contents/Resources for Bundle.module to resolve at runtime.
for bundle in ".build/$CONFIG"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Icons: SwiftPM can't compile the asset catalog (actool ships with Xcode), so
# the script packs what Xcode would have produced from Assets.xcassets.
# Xcode builds still get both icons from the catalog via
# ASSETCATALOG_COMPILER_APPICON_NAME / Image("MenuBarIcon").

# Dock / Finder / About: same PNGs → .icns, then CFBundleIconFile.
ICONSET_SRC="SoundsRight/Resources/Assets.xcassets/AppIcon.appiconset"
if command -v iconutil >/dev/null && [ -e "$ICONSET_SRC/AppIcon-512x512@2x.png" ]; then
    ICONSET="build.noindex/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        cp "$ICONSET_SRC/AppIcon-${size}x${size}.png"    "$ICONSET/icon_${size}x${size}.png"
        cp "$ICONSET_SRC/AppIcon-${size}x${size}@2x.png" "$ICONSET/icon_${size}x${size}@2x.png"
    done
    iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
    rm -rf "$ICONSET"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Menu bar: NSImage(named: "MenuBarIcon") resolves these loose PNGs the same
# way it resolves a compiled imageset. Template rendering is forced in
# SoundsRightApp (the catalog's template-rendering-intent is lost without actool).
MENUBAR_SRC="SoundsRight/Resources/Assets.xcassets/MenuBarIcon.imageset"
if [ -e "$MENUBAR_SRC/MenuBarIcon.png" ]; then
    cp "$MENUBAR_SRC/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
    cp "$MENUBAR_SRC/MenuBarIcon@2x.png" "$APP/Contents/Resources/MenuBarIcon@2x.png"
fi

# Prefer the stable self-signed identity (create it once with
# Scripts/setup-signing.sh): TCC pins the Accessibility grant to the signer,
# so identity-signed rebuilds keep the grant while ad-hoc ones lose it.
# (No --deep: nested bundles are resource-only and need no signing of their own.)
SIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "SoundsRight Dev"; then
    SIGN_IDENTITY="SoundsRight Dev"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    SIGN_IDENTITY="Apple Development"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "Built: $APP (signed: $SIGN_IDENTITY)"
