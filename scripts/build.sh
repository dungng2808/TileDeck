#!/bin/bash
# Builds TileDeck.app into ./build. Usage: scripts/build.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
FLAGS=()
[[ "$CONFIG" == "release" ]] && FLAGS=(-Xswiftc -Osize)

swift build -c "$CONFIG" "${FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TileDeck"

APP="build/TileDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/TileDeck"
[[ "$CONFIG" == "release" ]] && strip -x "$APP/Contents/MacOS/TileDeck"

# A stable signing identity keeps the Accessibility permission across rebuilds;
# ad-hoc signing (-) makes macOS ask again after every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1)), signed with: ${IDENTITY:-ad-hoc}"
