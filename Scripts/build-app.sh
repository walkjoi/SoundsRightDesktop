#!/bin/bash
# Builds SoundsRight.app using SwiftPM + Command Line Tools only (no Xcode,
# no Apple Developer account). Output: build/SoundsRight.app, ad-hoc signed.
#
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/SoundsRight.app"

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
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
