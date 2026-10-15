#!/bin/bash
# Regenerates Resources/AppIcon.icns from the orb shaders.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
{ echo "import Foundation"; cat Sources/ClaudeBubble/OrbShaders.swift Sources/ClaudeBubbleCore/{BubbleState,OrbParams,OrbAnimator,OrbGeometry}.swift | grep -v '^import Foundation$'; } > "$WORK/lib.swift"
swiftc -O "$WORK/lib.swift" scripts/icon/main.swift -o "$WORK/render-icon"
"$WORK/render-icon" "$WORK/icon_1024.png"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
