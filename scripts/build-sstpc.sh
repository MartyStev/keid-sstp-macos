#!/bin/sh
# Builds a self-contained, universal (arm64 + x86_64) `sstpc` with OpenSSL and
# libevent linked statically, so the app needs neither Homebrew nor any dylib
# outside the system.
#
#   sh scripts/build-sstpc.sh            -> build/sstpc/sstpc
#
# Sources are pinned by version and SHA-256 (cross-checked against the
# upstream .sha256 file for OpenSSL and the Homebrew formulae). Our patches to
# sstp-client are in scripts/patches (sstpc-*.patch).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK="$ROOT/build/deps"
OUT="$ROOT/build/sstpc"
MIN_MACOS=14.0
ARCHS=${ARCHS:-"arm64 x86_64"}
JOBS=$(sysctl -n hw.ncpu)

OPENSSL_VER=3.5.9
OPENSSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz

LIBEVENT_VER=2.1.13-stable
LIBEVENT_SHA=f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c
LIBEVENT_URL=https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VER/libevent-$LIBEVENT_VER.tar.gz

SSTP_VER=1.0.20
SSTP_SHA=6c84b6cdcc21ebea6daeb8c5356dcdfd8681f4981a734f8485ed0b31fc30aadd
SSTP_URL=https://gitlab.com/sstp-project/sstp-client/-/releases/$SSTP_VER/downloads/dist-gzip/sstp-client-$SSTP_VER.tar.gz

log(){ printf '==> %s\n' "$*"; }
die(){ printf 'error: %s\n' "$*" >&2; exit 1; }

command -v pkg-config >/dev/null 2>&1 || die "pkg-config is required (brew install pkgconf)"

fetch(){ # fetch URL SHA256 -> path of verified tarball
	_f="$WORK/src/$(basename "$1")"
	mkdir -p "$WORK/src"
	[ -f "$_f" ] || curl -sSfL --retry 3 -o "$_f.part" "$1" && { [ -f "$_f" ] || mv "$_f.part" "$_f"; }
	echo "$2  $_f" | shasum -a 256 -c - >/dev/null || { rm -f "$_f"; die "checksum mismatch for $(basename "$1")"; }
	echo "$_f"
}

unpack(){ # unpack TARBALL ARCH -> source dir
	_d="$WORK/$2"
	mkdir -p "$_d"
	tar -xzf "$1" -C "$_d"
	echo "$_d/$(tar -tzf "$1" | head -1 | cut -d/ -f1)"
}

host_triple(){ case "$1" in arm64) echo aarch64-apple-darwin ;; x86_64) echo x86_64-apple-darwin ;; esac; }
openssl_target(){ case "$1" in arm64) echo darwin64-arm64-cc ;; x86_64) echo darwin64-x86_64-cc ;; esac; }

build_arch(){
	_arch=$1
	_prefix="$WORK/$_arch/prefix"
	# stack canaries and checked libc calls: sstpc runs as root and parses
	# what the network sends
	_cflags="-arch $_arch -mmacosx-version-min=$MIN_MACOS -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2"
	rm -rf "$WORK/$_arch"; mkdir -p "$_prefix"

	# no-module: the legacy provider (MD4, needed by MS-CHAPv2) is compiled
	# into libcrypto instead of a separate legacy.dylib the app does not ship.
	log "[$_arch] OpenSSL $OPENSSL_VER"
	_src=$(unpack "$OPENSSL_TGZ" "$_arch")
	( cd "$_src" &&
	  ./Configure "$(openssl_target "$_arch")" no-shared no-module no-tests no-docs no-apps \
		--prefix="$_prefix" --libdir=lib -mmacosx-version-min=$MIN_MACOS >/dev/null &&
	  make -j"$JOBS" build_libs >/dev/null &&
	  make install_dev >/dev/null )

	log "[$_arch] libevent $LIBEVENT_VER"
	_src=$(unpack "$LIBEVENT_TGZ" "$_arch")
	( cd "$_src" &&
	  CFLAGS="$_cflags" ./configure --host="$(host_triple "$_arch")" --prefix="$_prefix" \
		--disable-shared --enable-static --disable-openssl --disable-samples \
		--disable-libevent-regress --disable-debug-mode >/dev/null &&
	  make -j"$JOBS" >/dev/null && make install >/dev/null )

	log "[$_arch] sstp-client $SSTP_VER"
	_src=$(unpack "$SSTP_TGZ" "$_arch")
	for _p in "$ROOT"/scripts/patches/sstpc-*.patch; do
		patch -s -p1 -d "$_src" < "$_p" || die "[$_arch] patch failed: $(basename "$_p")"
	done
	( cd "$_src" &&
	  PKG_CONFIG_PATH="$_prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$_prefix/lib/pkgconfig" \
	  CFLAGS="$_cflags" LDFLAGS="-arch $_arch -mmacosx-version-min=$MIN_MACOS" \
	  ./configure --host="$(host_triple "$_arch")" --prefix="$_prefix" \
		--disable-shared --enable-static --disable-ppp-plugin \
		--with-runtime-dir=/var/run/sstpc >/dev/null &&
	  make -j"$JOBS" >/dev/null )
	cp "$_src/src/sstpc" "$WORK/$_arch/sstpc"

	# Nothing outside /usr/lib and /System may be linked dynamically.
	if otool -L "$WORK/$_arch/sstpc" | awk 'NR>1{print $1}' | grep -vE '^(/usr/lib/|/System/)'; then
		die "[$_arch] sstpc links non-system libraries (see above)"
	fi
}

OPENSSL_TGZ=$(fetch "$OPENSSL_URL" "$OPENSSL_SHA")
LIBEVENT_TGZ=$(fetch "$LIBEVENT_URL" "$LIBEVENT_SHA")
SSTP_TGZ=$(fetch "$SSTP_URL" "$SSTP_SHA")

_bins=""
for a in $ARCHS; do build_arch "$a"; _bins="$_bins $WORK/$a/sstpc"; done

mkdir -p "$OUT"
# shellcheck disable=SC2086
lipo -create $_bins -output "$OUT/sstpc"
strip -x "$OUT/sstpc"

# Smoke test: sstpc loads the legacy provider (MD4) while initialising, before
# any network I/O. Point it at a closed local port and look for the error.
_smoke=$(mktemp)
# The password goes in through stdin, as the helper passes it (our patch).
printf 'x\n' | "$OUT/sstpc" --log-stderr --log-level 3 --cert-warn --user x --password - 127.0.0.1:1 -- noauth >"$_smoke" 2>&1 &
_pid=$!
sleep 2
kill "$_pid" 2>/dev/null || true
wait "$_pid" 2>/dev/null || true
if grep -q "Could not load legacy crypto provider" "$_smoke"; then
	cat "$_smoke" >&2; rm -f "$_smoke"
	die "sstpc cannot load the OpenSSL legacy provider (MS-CHAPv2 needs MD4)"
fi
if grep -q "password from standard input" "$_smoke"; then
	cat "$_smoke" >&2; rm -f "$_smoke"
	die "sstpc did not take the password from stdin (scripts/patches not applied?)"
fi
rm -f "$_smoke"
_first="$WORK/$(echo $ARCHS | cut -d' ' -f1)"
cp "$_first"/sstp-client-*/COPYING "$OUT/COPYING.sstp-client"
cp "$_first"/openssl-*/LICENSE.txt "$OUT/LICENSE.OpenSSL"
cp "$_first"/libevent-*/LICENSE "$OUT/LICENSE.libevent"
printf 'sstp-client %s\nOpenSSL %s\nlibevent %s\n' "$SSTP_VER" "$OPENSSL_VER" "$LIBEVENT_VER" > "$OUT/VERSIONS"
# the per-architecture build trees (~430 MB) are rebuilt from scratch every
# time; the verified tarballs in $WORK/src stay as a download cache
for a in $ARCHS; do rm -rf "${WORK:?}/$a"; done
log "done: $OUT/sstpc ($(lipo -archs "$OUT/sstpc"))"
