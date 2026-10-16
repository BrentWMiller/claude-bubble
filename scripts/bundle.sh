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
chmod +x "$APP/Contents/Resources/claude-bubble-hook.sh"
cp hook/claude-bubble-statusline.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/claude-bubble-statusline.sh"
# App Intents metadata for the Focus filter (what Xcode's build would produce), from the release build's const values.
if xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  META=.build/appintents
  mkdir -p "$META"
  find .build -name "*.swiftconstvalues" -path "*ClaudeBubble.build*" ! -path "*ClaudeBubbleCore*" ! -path "*index-build*" \
    | grep -i "/release/" > "$META/constvals.list" || true
  ls "$PWD"/Sources/ClaudeBubble/*.swift > "$META/sources.list"
  xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" --module-name ClaudeBubble \
    --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple "$(uname -m)-apple-macosx14.0" \
    --source-file-list "$META/sources.list" --swift-const-vals-list "$META/constvals.list" --force --quiet-warnings >/dev/null 2>&1 \
    || echo "warning: App Intents metadata failed; the Focus filter won't appear" >&2
else
  echo "warning: Xcode's appintentsmetadataprocessor not found; the Focus filter won't appear" >&2
fi
codesign --force --sign - "$APP"
echo "Built $APP"

# Install a copy where Spotlight, Launchpad and Login Items can find it.
DEST="$HOME/Applications/Claude Bubble.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
