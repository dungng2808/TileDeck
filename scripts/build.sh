#!/bin/bash
# Builds TileDeck.app into ./build. Usage: scripts/build.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
FLAGS=()
[[ "$CONFIG" == "release" ]] && FLAGS=(-Xswiftc -Osize)

swift build -c "$CONFIG" "${FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/TileDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/TileDeck" "$APP/Contents/MacOS/TileDeck"
# The privileged fan helper, registered with launchd through SMAppService.
cp "$BIN_DIR/TileDeckHelper" "$APP/Contents/MacOS/TileDeckHelper"
cp Resources/LaunchDaemons/com.dungng.tiledeck.helper.plist "$APP/Contents/Library/LaunchDaemons/"
if [[ "$CONFIG" == "release" ]]; then
    strip -x "$APP/Contents/MacOS/TileDeck" "$APP/Contents/MacOS/TileDeckHelper"
fi

# A stable signing identity keeps the Accessibility permission across rebuilds;
# ad-hoc signing (-) makes macOS ask again after every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
# Inside out: the helper first, then the app that contains it.
codesign --force --options runtime --identifier com.dungng.tiledeck.helper --sign "${IDENTITY:--}" "$APP/Contents/MacOS/TileDeckHelper"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1)), signed with: ${IDENTITY:-ad-hoc}"
