# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions match `CFBundleShortVersionString` (the `VERSION` file).

## [1.2.0] — 2026-11-04

The app is now called **Keid** (it was SSTP Client). Update: drag Keid into Applications, delete the old “SSTP Client” app, open Keid, then open Settings and click **Save** once, so the new network helper (version 10) is installed. Your server and login carry over; turn **Launch at login** on again if you used it.

### Changed
- Renamed to **Keid**, so it is not mixed up with sstp-client, the program it runs; the bundle identifier, the helper and its settings stay the same. The DMG is now `Keid-<version>.dmg`.
- Lighter on the battery: the helper status is read every 15 s while connected and every 30 s while disconnected (it was every 4 s, each time starting sudo, a shell and pfctl). It stays every 4 s while the panel is open, while connecting, reconnecting or blocked, and any network change or wake-up checks at once.

### Security
- The kill-switch no longer trusts the network's netmask: only attached networks that lie wholly in a private range are allowed, so a rogue DHCP server handing out a /3 "LAN" cannot open half the internet around the tunnel.
- DNS (ports 53 and 853) outside the tunnel is blocked for everyone but the helper's own lookups, also to the local router.
- The firewall allows only sstpc's TCP connection to the SSTP server port and only the system's DHCP client, instead of any traffic to the server and any UDP from port 68.
- `sstpc` is built with stack protection and checked libc calls; it fails on an empty password from stdin instead of trying it, and wipes its copy of the buffer.
- The helper looks for its processes among root's only, deletes sstpc's temp password file left by a killed session, and runs the system tools in the C locale.

### Fixed
- Disconnect racing a status poll could leave the firewall on while the app showed "Disconnected".
- A connect lock left by a killed helper whose PID was reused blocked every Connect until a restart; the lock is now created atomically and checked to be ours.
- With automatic reconnection off, a drop showed "Reconnecting" with no way to connect again; it now offers Connect and Disconnect.
- A status that could not be read once (right after wake) turned "Connected" or "Internet blocked" into "Not set up".
- A cancelled administrator prompt in Settings stopped automatic reconnection; turning auto-reconnect off cancels a retry already scheduled.
- The panel's fast polling and log refresh now stop when the panel is closed (window visibility instead of onAppear); status reads never run twice at once.
- A hung helper call is killed after SIGTERM and never leaves the app busy, even when a child holds its output open.
- Notifications show while the panel is open and wait for the permission prompt; the Settings draft starts fresh each time the window opens; a failed Cancel shows its error.
- THIRD_PARTY_NOTICES said `sstpc` is built unmodified; since 1.1.0 it carries our stdin-password patch, now stated with its date, as the GPL asks.
- Building `sstpc` no longer leaves ~430 MB of build trees in `build/deps`.

## [1.1.0] — 2026-11-04

Update: open Settings and click **Save** once, so the new network helper (version 9) is installed.

### Added
- Faster recovery: a dead tunnel is noticed within 20 s (was 80 s), and a dropped tunnel is retried at once when the network comes back or the Mac wakes, instead of after the back-off.
- Notifications when the connection is lost or restored and when the server rejects the login (Settings → Show notifications).
- A distinct menu bar icon and title, “Internet blocked”, while the kill-switch blocks traffic; data counters in the panel; **Copy Log**.
- Roadmap in the README; `make test` runs shellcheck on the scripts when it is installed.
- Kill-switch on the pf firewall: from Connect until Disconnect nothing leaves the Mac outside the tunnel — also while connecting, after a drop, a wrong password or any failure, and from apps bound to Wi-Fi. Only the SSTP server and the local network stay reachable. While blocked the panel says so and offers **Disconnect and unblock internet**.
- **Cancel** while connecting: stops the connect in progress (the helper ends the running `up` before turning the firewall off).
- A warning in the panel while the server certificate is not checked.
- `make test` uses Xcode when it is installed but not selected, and says clearly when the Swift tests are skipped.

### Fixed
- On a network that uses the same addresses as the one behind the VPN (both 192.168.1.x), DNS lookups to the tunnel's DNS server went to the local network; they are now routed into the tunnel.
- Settings are applied only when saving worked; the window edits a draft and shows "Not saved yet".
- Errors from outside the helper are shown in a sentence in the app's language; every helper message is checked for a Russian translation.
- Restarting after a language change waits for the app to quit instead of a fixed second.
- A rejected login is recognised by a stable code (`error_code=auth`) instead of pppd's wording, so a changed message cannot make the app retry a wrong password.
- A status read during Disconnect could switch the tunnel back on.
- Automatic reconnection could stop for good if its timer fired while another operation ran.
- Connecting now fails instead of reporting a tunnel that traffic could bypass, when a tunnel or IPv6 block route cannot be set.
- The installer's success was detected by any "ok" in its output.
- Save and Uninstall in Settings no longer run over an operation in progress.
- A hung `sudo` or helper no longer leaves the app busy forever: helper commands time out (75 s for connecting, 30 s for disconnecting, 15 s otherwise).
- The `.sha256` file next to the DMG names the bare file, so `shasum -a 256 -c` works in the download folder.

### Security
- The VPN password never appears on a command line: the helper passes it to `sstpc` through stdin (patched sstp-client, `scripts/patches/sstpc-password-stdin.patch`); before, `ps` could show it for a moment.
- The helper kills only `pppd` and `sstpc`: a PID left in a pid file and reused by another process is no longer killed as root, nor taken for a running session.
- Passwords are limited to 128 bytes: sstpc 1.0.20 writes a longer one past its 255-byte buffer.
- Server addresses must start with a letter or a digit, so sstpc cannot take them for an option.
- CI: no write token for builds and pull requests; releases are published by a separate job. Actions are pinned to commit SHAs (Dependabot keeps them current), and release builds do not reuse a cached `sstpc`.

## [1.0.0] — 2026-11-04

First public release.

### Added
- Menu bar app: connect and disconnect in one click, connection details and log in the panel.
- Server, login and password entered in Settings and saved through the administrator prompt into a root-only file.
- Full tunnel: all IPv4 traffic and DNS through the SSTP server, a `/32` route pinning the server to the physical gateway, IPv6 blocked while connected.
- Automatic reconnection with back-off after Wi-Fi changes, sleep or server restarts; cleanup of routes left by a dropped session.
- A clear "login or password rejected" message, with no further retries.
- Strict TLS certificate check by default, optional for self-signed servers.
- Interface language switch in Settings: System, English, Русский. Messages from the helper are translated too.
- Launch at login; uninstalling the helper from Settings.
- App icon: a shield with a lock ringed by a constellation. The menu bar icon is 15% larger than the default symbol size.
- A self-contained universal `sstpc` 1.0.20, built statically with OpenSSL 3.5.9 (the legacy provider built in, as MS-CHAPv2 needs MD4) and libevent 2.1.13 from pinned, checksummed sources.
- Build scripts and a `Makefile` for `sstpc`, the app and the DMG; helper tests and Swift tests; CI that releases the DMG for `v*` tags.
