# Keid — SSTP VPN client for the macOS menu bar.
#
# Command Line Tools are enough for everything except `swift test`, which
# needs Xcode for the Testing framework (see `make test`).

.PHONY: test test-helpers sstpc app dmg icon clean

## Helper script tests (unprivileged) and the Swift tests. The Swift tests
## need Xcode (the Testing framework): its Developer folder is used when the
## active one is Command Line Tools; without Xcode they are skipped, loudly.
XCODE_DEV := $(firstword $(wildcard /Applications/Xcode*.app/Contents/Developer))
test: test-helpers
	@if xcrun --find xctest >/dev/null 2>&1; then \
		swift test; \
	elif [ -n "$(XCODE_DEV)" ]; then \
		DEVELOPER_DIR="$(XCODE_DEV)" swift test; \
	else \
		echo "SKIPPED: swift test needs Xcode for the Testing framework (only Command Line Tools here)."; \
		echo "         Install Xcode from the App Store to run SSTPCoreTests."; \
	fi

test-helpers:
	sh scripts/test-helpers.sh
	@# the helper runs as root: static checks are worth it (brew install shellcheck)
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s sh helper/sstp-helper helper/install-helper.sh scripts/*.sh && echo "shellcheck: clean"; \
	else \
		echo "SKIPPED: shellcheck is not installed (brew install shellcheck)."; \
	fi

## Static universal sstpc (OpenSSL + libevent, pinned and checksummed sources).
sstpc:
	sh scripts/build-sstpc.sh

## build/Keid.app, universal, ad-hoc signed unless CODESIGN_IDENTITY is set.
app: test-helpers
	sh scripts/build-app.sh

## build/Keid-<version>.dmg (+ .sha256), notarized when NOTARY_PROFILE is set.
dmg: app
	sh scripts/make-dmg.sh

## Redraws the README images: docs/icon.png and docs/social-preview.png.
icon:
	swift scripts/make-icon.swift build/AppIcon.iconset
	cp build/AppIcon.iconset/icon_256x256@2x.png docs/icon.png
	swift scripts/make-social-preview.swift docs/icon.png docs/social-preview.png

clean:
	rm -rf .build build/*.app build/*.dmg build/*.sha256 build/dmg build/AppIcon.iconset
