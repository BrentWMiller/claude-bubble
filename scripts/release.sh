#!/bin/bash
# Builds the GitHub Releases download: a universal (Apple silicon + Intel) app, ad-hoc signed, zipped as
# build/ClaudeBubble-<version>.zip. It isn't notarized, so first launch needs the steps in the README.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

OUT=build/release
APP="$OUT/Claude Bubble.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClaudeBubble" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/claude-bubble-hook" "$APP/Contents/Resources/"
cp hook/claude-bubble-hook.sh hook/claude-bubble-statusline.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh
codesign --force --sign - "$APP/Contents/Resources/claude-bubble-hook"
codesign --force --sign - "$APP"

ZIP="build/ClaudeBubble-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP"
shasum -a 256 "$ZIP"
