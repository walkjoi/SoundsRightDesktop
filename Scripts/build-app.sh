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

CONFIG="${1:-release}"
APP="build.noindex/SoundsRight.app"

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

# Ad-hoc signature: required on Apple Silicon, needs no developer account.
# (No --deep: nested bundles are resource-only and need no signing of their own.)
codesign --force --sign - "$APP"

echo "Built: $APP"
