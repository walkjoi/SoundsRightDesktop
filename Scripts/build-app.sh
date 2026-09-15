#!/bin/bash
# Builds SoundsRight.app using SwiftPM + Command Line Tools only (no Xcode,
# no Apple Developer account). Output: build.noindex/SoundsRight.app, ad-hoc
# signed. The .noindex suffix keeps Spotlight/Launchpad from listing the build
# artifact as a second "SoundsRight" alongside the installed copy.
#
# Usage: Scripts/build-app.sh [release]
# The debug configuration does NOT build under Command Line Tools: SwiftPM
# defines DEBUG there, which compiles the #if DEBUG-wrapped #Preview blocks,
# and the SwiftUI previews macro plugin ships only with full Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIG="${1:-release}"
APP="build.noindex/SoundsRight.app"

# --- @State macro workaround (Command Line Tools only) -----------------------
# The macOS 27 SDK ships `@State` as a `State()` macro whose `SwiftUIMacros`
# compiler plugin is bundled only with full Xcode. Under CLT the plugin is
# missing, so `swift build` fails on every `@State`. Rather than depend on the
# plugin, build from a copy of the sources in which each `@State` attribute is
# rewritten to `@CLTState` — a drop-in property wrapper (SoundsRight/Utilities/
# StateMacroShim.swift) that forwards to `SwiftUI.State`. The canonical tree is
# left untouched; Xcode builds still use the real macro. See CLAUDE.md.
SRC="build.noindex/src"
mkdir -p "$SRC"
# Mirror sources into the build copy (preserve .build for incremental builds).
rsync -a --delete "$ROOT/SoundsRight/" "$SRC/SoundsRight/"
# Reuse the canonical manifest, but rewrite the vendored-package path to an
# absolute one so it still resolves from the relocated package root.
cp "$ROOT/Package.swift" "$SRC/Package.swift"
perl -pi -e "s{\.package\(path: \"Vendor/KeyboardShortcuts\"\)}{.package(path: \"$ROOT/Vendor/KeyboardShortcuts\")}" "$SRC/Package.swift"
# Two forms: the `@State` attribute, and the bare `State(...)`/`State<...>`
# storage initializer written in a view's `init` (e.g. `_deck = State(...)`).
# The lookbehind leaves `.State` (qualified) and `StateObject` untouched, and
# `[(<]` after the name skips `@StateObject` and other `State`-prefixed words.
grep -rlE --include='*.swift' '@State|(^|[^.[:alnum:]_])State[(<]' "$SRC/SoundsRight" \
    | xargs -r perl -pi -e 's/\@State\b/\@CLTState/g; s/(?<![.\w@])State(?=[(<])/CLTState/g'

swift build -c "$CONFIG" --package-path "$SRC"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$SRC/.build/$CONFIG/SoundsRight" "$APP/Contents/MacOS/SoundsRight"

# Substitute the Xcode build-setting variables Info.plist expects.
sed -e 's/\$(EXECUTABLE_NAME)/SoundsRight/g' \
    -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.soundsright.desktop/g' \
    -e 's/\$(PRINCIPAL_CLASS)/NSApplication/g' \
    SoundsRight/Info.plist > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# SPM resource bundles (e.g. KeyboardShortcuts localizations) must sit in
# Contents/Resources for Bundle.module to resolve at runtime.
for bundle in "$SRC/.build/$CONFIG"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# App icon: SwiftPM can't compile the asset catalog (actool ships with Xcode),
# so build an .icns from the same PNGs with iconutil (part of macOS) and point
# CFBundleIconFile at it. Xcode builds get the icon from Assets.xcassets instead.
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
