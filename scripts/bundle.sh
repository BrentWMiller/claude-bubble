#!/bin/bash
# Builds build/ClaudeBubble.app from the SwiftPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/ClaudeBubble.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeBubble "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp hook/claude-bubble-hook.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/claude-bubble-hook.sh"
codesign --force --sign - "$APP"
echo "Built $APP"
