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
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp hook/claude-bubble-hook.sh "$APP/Contents/Resources/"
cp .build/release/claude-bubble-hook "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/Resources/claude-bubble-hook"
chmod +x "$APP/Contents/Resources/claude-bubble-hook.sh"
cp hook/claude-bubble-statusline.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/claude-bubble-statusline.sh"
codesign --force --sign - "$APP"
echo "Built $APP"

# Install a copy where Spotlight, Launchpad and Login Items can find it.
DEST="$HOME/Applications/Claude Bubble.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
