# Third-party software

The app's own code (Swift sources, helper scripts, build scripts) is under the
MIT License (see `LICENSE`). The app bundle also ships a separately executed
program, `sstpc`, built from the components below by `scripts/build-sstpc.sh`.
Their license texts are inside the app at
`Keid.app/Contents/Resources/Licenses/`.

| Component | Version | License | Source |
|---|---|---|---|
| sstp-client (`sstpc`) | 1.0.20 | GPL-2.0-or-later | https://gitlab.com/sstp-project/sstp-client |
| OpenSSL (statically linked into `sstpc`) | 3.5.9 | Apache-2.0 | https://github.com/openssl/openssl |
| libevent (statically linked into `sstpc`) | 2.1.13-stable | BSD-3-Clause | https://github.com/libevent/libevent |

`sstpc` links OpenSSL 3 (Apache-2.0), which is compatible with GPL version 3
but not version 2, so the distributed `sstpc` binary is offered under
**GPL-3.0** (permitted by sstp-client's "or later" clause).

**Modified.** Since 2026-11-04 (app version 1.1.0) `sstpc` is built from
sstp-client with one change by the authors of Keid (formerly SSTP Client):
`scripts/patches/sstpc-password-stdin.patch` lets `--password -` read the
password from standard input, so it never appears on a command line. The
change is marked in the patched source (`src/sstp-option.c`). Version 1.0.0
shipped sstp-client unmodified.

**Corresponding source.** `sstpc` is built from the exact upstream release
tarballs listed above (version and SHA-256 are pinned in
`scripts/build-sstpc.sh`) plus the patches in `scripts/patches/`. The same
sources and patches are available from the URLs above, from this repository
and from its release page for at least three years after each release;
`sh scripts/build-sstpc.sh` reproduces the binary.

The app also uses macOS's own `/usr/sbin/pppd` (part of macOS, not shipped).
