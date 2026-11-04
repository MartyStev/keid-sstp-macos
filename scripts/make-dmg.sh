#!/bin/sh
# Packs "build/Keid.app" into build/Keid-<version>.dmg with a
# drag-to-Applications layout.
#
#   sh scripts/make-dmg.sh
#
# Notarization (optional, needs a Developer ID–signed app, see build-app.sh):
#   xcrun notarytool store-credentials sstp-notary --apple-id … --team-id …
#   NOTARY_PROFILE=sstp-notary sh scripts/make-dmg.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(tr -d ' \n' < VERSION)
APP="build/Keid.app"
DMG="build/Keid-$VERSION.dmg"
STAGE=build/dmg

log(){ printf '==> %s\n' "$*"; }

[ -d "$APP" ] || sh scripts/build-app.sh

log "staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Keid.app"
ln -s /Applications "$STAGE/Applications"

log "creating $DMG"
hdiutil create -quiet -volname "Keid $VERSION" -srcfolder "$STAGE" \
	-fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
rm -rf "$STAGE"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
	codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
	log "notarizing"
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$DMG"
fi

hdiutil verify -quiet "$DMG"
# bare file name, so `shasum -a 256 -c` works next to the downloaded DMG
( cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" ) | tee "$DMG.sha256"
log "done: $DMG ($(du -h "$DMG" | cut -f1))"
