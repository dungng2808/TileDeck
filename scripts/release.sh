#!/bin/bash
# Builds TileDeck, signs it with a Developer ID certificate, notarizes it with
# Apple and zips it for a GitHub release.
#
# Needs a paid Apple Developer Program membership and, once:
#   xcrun notarytool store-credentials TileDeck \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific password>
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
    echo "No \"Developer ID Application\" certificate in the keychain." >&2
    exit 1
fi
PROFILE="${NOTARY_PROFILE:-TileDeck}"

CODESIGN_IDENTITY="$IDENTITY" scripts/build.sh release
VERSION="$(plutil -extract CFBundleShortVersionString raw build/TileDeck.app/Contents/Info.plist)"
ZIP="build/TileDeck-$VERSION.zip"

ditto -c -k --keepParent build/TileDeck.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/TileDeck.app
# Zip again so the download carries the stapled ticket and opens offline.
rm "$ZIP"
ditto -c -k --keepParent build/TileDeck.app "$ZIP"

echo "Ready: $ZIP — attach it to a GitHub release tagged v$VERSION"
