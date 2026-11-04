#!/bin/sh
# Builds "build/Keid.app" — universal (arm64 + x86_64), with the
# helper scripts and a self-contained sstpc inside.
#
#   sh scripts/build-app.sh
#
# Signing: ad-hoc by default. Set CODESIGN_IDENTITY="Developer ID Application:
# …" to sign for distribution with the hardened runtime (needed for
# notarization, see make-dmg.sh).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(tr -d ' \n' < VERSION)
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
APP="$ROOT/build/Keid.app"
IDENTITY=${CODESIGN_IDENTITY:--}

log(){ printf '==> %s\n' "$*"; }

[ -x build/sstpc/sstpc ] && [ -f build/sstpc/LICENSE.OpenSSL ] || sh scripts/build-sstpc.sh

log "compiling (arm64, x86_64)"
for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
	swift build -c release --triple "$triple" --product SSTPClient >/dev/null
done
BIN_ARM=.build/arm64-apple-macosx/release/SSTPClient
BIN_X86=.build/x86_64-apple-macosx/release/SSTPClient

log "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
lipo -create "$BIN_ARM" "$BIN_X86" -output "$APP/Contents/MacOS/SSTPClient"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

R="$APP/Contents/Resources"
cp -R Resources/en.lproj Resources/ru.lproj "$R/"
install -m 755 helper/sstp-helper helper/install-helper.sh build/sstpc/sstpc "$R/"

swift scripts/make-icon.swift build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$R/AppIcon.icns"

# Licenses of everything shipped in the bundle
cp LICENSE "$R/Licenses/LICENSE-Keid.txt"
cp THIRD_PARTY_NOTICES.md "$R/Licenses/"
cp build/sstpc/COPYING.sstp-client "$R/Licenses/COPYING-sstp-client.txt"
cp build/sstpc/LICENSE.OpenSSL "$R/Licenses/LICENSE-OpenSSL.txt"
cp build/sstpc/LICENSE.libevent "$R/Licenses/LICENSE-libevent.txt"
cp build/sstpc/VERSIONS "$R/Licenses/VERSIONS.txt"

log "signing ($IDENTITY)"
if [ "$IDENTITY" = "-" ]; then
	codesign --force --sign - "$R/sstpc"
	codesign --force --sign - "$APP"
else
	codesign --force --options runtime --timestamp --sign "$IDENTITY" "$R/sstpc"
	codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

log "done: $APP ($(lipo -archs "$APP/Contents/MacOS/SSTPClient"), $VERSION build $BUILD_NUMBER)"
