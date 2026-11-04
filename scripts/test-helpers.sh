#!/bin/sh
# Unprivileged tests for helper/sstp-helper and helper/install-helper.sh.
# Paths are redirected into a temp dir; nothing touches the system.
#   sh scripts/test-helpers.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); }
bad(){ fail=$((fail+1)); printf 'FAIL: %s\n' "$*"; }
check(){ if eval "$1"; then ok; else bad "$2"; fi; }

for f in "$ROOT"/helper/*; do sh -n "$f" || bad "syntax: $f"; done

# --- sstp-helper ---------------------------------------------------------
# A fake sstpc that prints its arguments, one per line in brackets.
# …and what it reads from stdin, as <stdin:…>
printf '#!/bin/sh\nfor a; do printf "[%%s]\\n" "$a"; done\nIFS= read -r p || true\nprintf "<stdin:%%s>\\n" "$p"\n' > "$T/sstpc"; chmod +x "$T/sstpc"
helper(){ # helper <extra-case> — a copy of sstp-helper on temp paths
	sed -e "s#^SSTPC=.*#SSTPC=$T/sstpc#" -e "s#^CONF=.*#CONF=$T/server.conf#" \
	    -e "s#^RUN=.*#RUN=$T/run#" -e "s#^LOG=.*#LOG=$T/log#" -e "s#^LINKPID=.*#LINKPID=$T/none.pid#" -e "s#^HOSTS=.*#HOSTS=$T/hosts#" \
	    "$ROOT/helper/sstp-helper" |
	awk -v extra="$1" '{print} /^case "\$\{1:-\}" in$/{print "\t" extra ";;"}' > "$T/h.sh"
}
cat > "$T/server.conf" <<'EOF'
SSTP_HOST='vpn.example.com:4443'
SSTP_USER='DOMAIN\alex'
SSTP_PASS='p'\''a\ss&$x ;|'
VERIFY_CERT=1
BLOCK_IPV6=1
EOF

helper 't) load_conf; write_options; cat "$RUN/ppp.options"; start_sstpc; sleep 1'
out=$(sh "$T/h.sh" t)
check 'printf "%s\n" "$out" | grep -qx usepeerdns' "pppd uses the server DNS"
check 'printf "%s\n" "$out" | grep -qx nodefaultroute' "pppd does not set a default route"
check 'printf "%s\n" "$out" | grep -qx "lcp-echo-interval 5" && printf "%s\n" "$out" | grep -qx "lcp-echo-failure 4"' "a dead tunnel is noticed within 20 s"
check '! grep -q "alex\|p.a" "$T/run/ppp.options"' "no credentials in the pppd options file"
check '[ "$(stat -f %Lp "$T/run/ppp.options")" = 600 ]' "options file is private"
args=$(cat "$T/log")
check 'printf "%s\n" "$args" | grep -qxF "[DOMAIN\\alex]"' "login reaches sstpc verbatim"
check 'printf "%s\n" "$args" | grep -qxF "<stdin:p'"'"'a\\ss&\$x ;|>"' "password reaches sstpc verbatim, through stdin"
check '! printf "%s\n" "$args" | grep -qF "[p'"'"'a" && printf "%s\n" "$args" | grep -qxF "[-]"' "the password is not on the command line"
check 'printf "%s\n" "$args" | grep -qxF "[vpn.example.com:4443]"' "host with port reaches sstpc"
check 'printf "%s\n" "$args" | grep -qxF "[/etc/ssl/cert.pem]"' "strict TLS by default"

sed -i '' 's/^VERIFY_CERT=1/VERIFY_CERT=0/' "$T/server.conf"; rm -f "$T/log"
helper 't) load_conf; start_sstpc; sleep 1'
sh "$T/h.sh" t
check 'grep -qxF "[--cert-warn]" "$T/log"' "VERIFY_CERT=0 uses --cert-warn"

helper 't) load_conf; echo "$SERVER_NAME"'
check '[ "$(sh "$T/h.sh" t)" = vpn.example.com ]' "server name without port for pinning"

helper 't) mkdir -p "$RUN"; : > "$RUN/pinned"; apply_routes ppp9 && echo routed || echo refused'
check '[ "$(sh "$T/h.sh" t)" = refused ]' "no tunnel routes without a pinned server"

# Routes and firewall: fake route(8), pfctl, dig, dscacheutil and scutil log
# their arguments. FAIL_ROUTE / FAIL_PF (grep patterns) make matching calls
# fail. The real tools are never called, except `pfctl -n` (parse only).
mkdir -p "$T/bin"
cat > "$T/bin/route" <<EOF
#!/bin/sh
echo "\$*" >> "$T/route.log"
case "\$*" in "-n get default") printf 'gateway: 192.168.1.1\ninterface: %s\n' "\${FAKE_DEFIF:-en0}" ;; esac
[ -n "\${FAIL_ROUTE:-}" ] && echo "\$*" | grep -q -- "\$FAIL_ROUTE" && exit 1
exit 0
EOF
cat > "$T/bin/pfctl" <<EOF
#!/bin/sh
echo "\$*" >> "$T/pf.log"
[ -n "\${FAIL_PF:-}" ] && echo "\$*" | grep -q -- "\$FAIL_PF" && exit 1
case "\$*" in
	-sr) [ -n "\${FAKE_NO_ANCHOR:-}" ] || echo 'anchor "com.apple/*" all' ;;
	-E) echo 'Token : 42' ;;
	"-s info") [ -n "\${FAKE_PF_DISABLED:-}" ] && echo 'Status: Disabled' || echo 'Status: Enabled' ;;
	"-a com.apple/sstp-mac-client -s rules") [ -n "\${FAKE_ANCHOR_EMPTY:-}" ] || echo 'block return out quick all' ;;
	"-a com.apple/sstp-mac-client -F rules") [ -e "$T/run/pf.token" ] && echo "flushed-with-token" >> "$T/pf.log" ;;
esac
exit 0
EOF
cat > "$T/bin/ifconfig" <<EOF
#!/bin/sh
case "\$1" in
	-l) echo "lo0 en0 en5 en7 en8 en9 utun3 ppp9" ;;
	en0) printf 'en0: flags=8863<UP>\n\tinet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255\n' ;;
	en5) printf 'en5: flags=8863<UP>\n' ;;
	# a rogue DHCP server hands out a /3; a public subnet; a valid 10.x /16
	en7) printf 'en7: flags=8863<UP>\n\tinet 10.1.2.3 netmask 0xe0000000 broadcast 31.255.255.255\n' ;;
	en8) printf 'en8: flags=8863<UP>\n\tinet 10.20.0.5 netmask 0xffff0000 broadcast 10.20.255.255\n' ;;
	en9) printf 'en9: flags=8863<UP>\n\tinet 203.0.113.5 netmask 0xffffff00 broadcast 203.0.113.255\n' ;;
	utun3) printf 'utun3: flags=8051<UP>\n\tinet 10.8.0.2 --> 10.8.0.1 netmask 0xff000000\n' ;;
	ppp9) printf 'ppp9: flags=8051<UP>\n\tinet 172.16.3.33 --> 192.168.1.1 netmask 0xffffff00\n' ;;
esac
exit 0
EOF
cat > "$T/bin/sudo" <<EOF
#!/bin/sh
# sudo -n -u nobody <cmd…>: records the user, runs the command
echo "\$*" >> "$T/sudo.log"
shift 3; exec "\$@"
EOF
cat > "$T/bin/dig" <<EOF
#!/bin/sh
echo "\$*" >> "$T/dig.log"
[ -n "\${FAKE_DIG:-}" ] && echo "\$FAKE_DIG"
exit 0
EOF
cat > "$T/bin/dscacheutil" <<EOF
#!/bin/sh
[ -n "\${FAKE_DNS:-}" ] && echo "ip_address: \$FAKE_DNS"
exit 0
EOF
printf '#!/bin/sh\nprintf "resolver #1\\n  nameserver[0] : 8.8.8.8\\n  nameserver[1] : 192.168.1.1\\n"\n' > "$T/bin/scutil"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/killall"
chmod +x "$T/bin/"*
routes_helper(){ # like helper(), with the fake tools first on PATH
	helper "$1"
	sed -i '' "s#^PATH=.*#PATH=$T/bin:/usr/bin:/bin:/usr/sbin:/sbin#" "$T/h.sh"
}
reset_routes(){
	rm -rf "$T/run" "$T/route.log" "$T/pf.log" "$T/dig.log"
	mkdir -p "$T/run"; echo 192.0.2.1 > "$T/run/pinned"
	printf '127.0.0.1 localhost\n' > "$T/hosts"
}

# Tunnel routes
reset_routes
routes_helper 't) BLOCK_IPV6=1; apply_routes ppp9 && echo routed || echo refused'
check '[ "$(sh "$T/h.sh" t)" = routed ]' "routes are applied with a pinned server"
check '[ "$(grep -c -- "-interface ppp9" "$T/route.log")" = 4 ]' "four /2 tunnel routes on the ppp interface"
check '[ "$(wc -l < "$T/run/routes6" | tr -d " ")" = 2 ]' "IPv6 block routes are recorded"
# The server's DNS may sit in a subnet the Mac is attached to (192.168.1.x
# at home and in a café): host routes keep it in the tunnel
reset_routes
printf 'Wed : primary   DNS address 192.168.1.1\nWed : secondary DNS address 192.168.1.2\n' > "$T/log"
sh "$T/h.sh" t >/dev/null
check 'grep -q -- "add -host 192.168.1.2 -interface ppp9" "$T/route.log"' "the tunnel's DNS server is routed into the tunnel"
check '! grep -q -- "-host 192.168.1.1 -interface" "$T/route.log"' "the peer needs no route (pppd sets it)"
routes_helper 't) stop_tunnel; [ -e "$RUN/hostroutes" ] || echo end'
check '[ "$(sh "$T/h.sh" t)" = end ] && grep -q -- "delete -host 192.168.1.2" "$T/route.log"' "DNS host routes go with the tunnel"
rm -f "$T/log"
routes_helper 't) BLOCK_IPV6=1; apply_routes ppp9 && echo routed || echo refused'
reset_routes
check '[ "$(FAIL_ROUTE="add -inet6" sh "$T/h.sh" t)" = routed ]' "an existing IPv6 block route is reused (change)"
reset_routes
check '[ "$(FAIL_ROUTE="-inet6" sh "$T/h.sh" t)" = refused ]' "IPv6 block that cannot be set fails closed"
reset_routes
check '[ "$(FAIL_ROUTE="-interface" sh "$T/h.sh" t)" = refused ]' "tunnel route that cannot be set fails"

# Firewall (pf): the kill-switch
reset_routes
routes_helper 't) BLOCK_IPV6=1; firewall_load "${2:-}" && echo on || echo failed'
check '[ "$(sh "$T/h.sh" t)" = on ]' "firewall loads"
check 'grep -qx -- "-a com.apple/sstp-mac-client -f $T/run/pf.rules" "$T/pf.log"' "rules go into the app's own anchor"
check '[ "$(cat "$T/run/pf.token")" = 42 ] && grep -qx -- "-E" "$T/pf.log"' "pf is enabled with a reference token"
check '[ "$(tail -1 "$T/run/pf.rules")" = "block return out quick all" ]' "everything not allowed is blocked"
check 'grep -qx "pass out quick inet proto tcp to { 192.0.2.1 } port 443 user root" "$T/run/pf.rules"' "only sstpc's connection to the SSTP server is allowed"
check 'grep -qx "pass out quick inet proto udp from any port 68 to any port 67 user root" "$T/run/pf.rules"' "only the system's DHCP client is allowed"
check 'grep -qx "pass out quick inet to 192.168.1.0/24" "$T/run/pf.rules" && grep -qx "pass out quick inet to 10.20.0.0/16" "$T/run/pf.rules"' "the attached private networks are allowed"
check '! grep -q "0/3\|203.0.113\|:network\|utun3\|ppp9\|10.0.0.0/8\|172.16.0.0/12" "$T/run/pf.rules"' "a rogue netmask, a public subnet and tunnels are not"
check 'grep -qx "pass out quick proto { udp tcp } to { 192.168.1.1 8.8.8.8 } port 53 user nobody" "$T/run/pf.rules"' "only the helper's lookups may reach the DNS servers"
dns_block=$(grep -nx "block return out quick proto { udp tcp } to any port { 53 853 }" "$T/run/pf.rules" | cut -d: -f1)
first_lan=$(grep -n "^pass out quick inet to " "$T/run/pf.rules" | head -1 | cut -d: -f1)
check '[ -n "$dns_block" ] && [ -n "$first_lan" ] && [ "$dns_block" -lt "$first_lan" ]' "DNS outside the tunnel is blocked before the local network is allowed"
check '! grep -q "on ppp" "$T/run/pf.rules"' "no tunnel interface is allowed before it exists"
check '! grep -q "pass out quick inet6 all" "$T/run/pf.rules"' "IPv6 to the internet is blocked"
sh "$T/h.sh" t ppp9 >/dev/null
check 'grep -qx "pass out quick on ppp9 all" "$T/run/pf.rules"' "the tunnel interface is allowed once up"
check '[ "$(grep -cx -- "-E" "$T/pf.log")" = 1 ]' "pf is enabled once per session"
if [ -x /sbin/pfctl ]; then
	check '/sbin/pfctl -n -f "$T/run/pf.rules" 2>/dev/null' "the rules parse with the real pfctl"
fi
reset_routes
check '[ "$(FAKE_NO_ANCHOR=1 sh "$T/h.sh" t)" = failed ] && ! grep -q -- "-f /etc/pf.conf" "$T/pf.log"' "a missing system anchor point fails instead of replacing the main ruleset"
reset_routes
check '[ "$(FAKE_ANCHOR_EMPTY=1 sh "$T/h.sh" t)" = failed ]' "rules that did not take effect are reported"
# Someone disabled pf or flushed our rules: status brings the kill-switch back
reset_routes; sh "$T/h.sh" t >/dev/null; : > "$T/pf.log"
routes_helper 't) true'
FAKE_PF_DISABLED=1 sh "$T/h.sh" status >/dev/null
check 'grep -qx -- "-E" "$T/pf.log" && grep -q -- "-a com.apple/sstp-mac-client -f" "$T/pf.log"' "a disabled pf is re-enabled while the kill-switch should be on"
check '[ "$(grep -c . "$T/run/pf.token")" = 2 ]' "every pf reference is kept for release"
: > "$T/pf.log"; sh "$T/h.sh" status >/dev/null
check '! grep -q -- "-E\|-f" "$T/pf.log"' "an intact kill-switch is left alone"
routes_helper 't) BLOCK_IPV6=1; firewall_load "${2:-}" && echo on || echo failed'
reset_routes
check '[ "$(FAIL_PF="-a com.apple" sh "$T/h.sh" t)" = failed ] && [ ! -e "$T/run/pf.token" ]' "a firewall that cannot be loaded is reported"
reset_routes
routes_helper 't) BLOCK_IPV6=0; firewall_load "" >/dev/null; cat "$RUN/pf.rules"'
check 'sh "$T/h.sh" t | grep -qx "pass out quick inet6 all"' "IPv6 is allowed when the user turned its block off"

# Strict: any failure keeps traffic blocked; only `down` unblocks
reset_routes
routes_helper 't) BLOCK_IPV6=1; SERVER_NAME=vpn.example.com; firewall_load "" >/dev/null; set_hosts 192.0.2.1; echo 0.0.0.0/2 > "$RUN/routes"; fail_up "authentication failed"'
check 'sh "$T/h.sh" t | grep -qx "error=authentication failed"' "a failed up reports its error"
check '[ -s "$T/run/pf.token" ] && [ ! -e "$T/run/routes" ]' "a failed up keeps the firewall and drops the tunnel routes"
routes_helper 't) true'
check '[ "$(sh "$T/h.sh" status | head -1)" = state=dropped ]' "an active firewall without a tunnel reports a dropped session"
sh "$T/h.sh" down >/dev/null
check 'grep -qx -- "-a com.apple/sstp-mac-client -F rules" "$T/pf.log" && grep -qx -- "-X 42" "$T/pf.log"' "down flushes only its rules and releases pf"
check '[ ! -e "$T/run/pf.token" ]' "down forgets the firewall"
check '! grep -q flushed-with-token "$T/pf.log"' "down forgets the firewall before flushing it (a status meanwhile cannot re-arm it)"
check '! grep -q sstp-mac-client "$T/hosts" && grep -qx "127.0.0.1 localhost" "$T/hosts"' "down removes only its own hosts entry"

# /etc/hosts: sstpc finds the server without DNS (pf blocks mDNSResponder)
reset_routes
routes_helper 't) SERVER_NAME=vpn.example.com; set_hosts "$2"; cat "$HOSTS"'
sh "$T/h.sh" t 203.0.113.1 >/dev/null
check '[ "$(sh "$T/h.sh" t 203.0.113.2 | grep -c sstp-mac-client)" = 1 ] && grep -qx "203.0.113.2 vpn.example.com # sstp-mac-client" "$T/hosts"' "the hosts entry is replaced, not duplicated"
routes_helper 't) SERVER_NAME=203.0.113.5; set_hosts 203.0.113.5; cat "$HOSTS"'
reset_routes
check '! sh "$T/h.sh" t | grep -q sstp-mac-client' "no hosts entry for a server given as an IP"
printf '10.0.0.5 nas' > "$T/hosts"   # no trailing newline
routes_helper 't) SERVER_NAME=vpn.example.com; set_hosts 203.0.113.3; cat "$HOSTS"; echo ---; clear_hosts; cat "$HOSTS"'
out=$(sh "$T/h.sh" t)
check 'printf "%s\n" "$out" | grep -qx "10.0.0.5 nas" && printf "%s\n" "$out" | grep -qx "203.0.113.3 vpn.example.com # sstp-mac-client"' "the entry gets its own line without a trailing newline"
check '[ "$(cat "$T/hosts")" = "10.0.0.5 nas" ]' "removing the entry keeps the other lines"
check '[ "$(stat -f %Lp "$T/hosts")" = 644 ] && [ -z "$(ls "$T"/hosts.sstp.* 2>/dev/null)" ]' "hosts stays world-readable, no temp files left"
printf '203.0.113.2 vpn.example.com # sstp-mac-client\n' >> "$T/hosts"
routes_helper 't) true'
sh "$T/h.sh" status >/dev/null
check 'grep -q sstp-mac-client "$T/hosts"' "status does not rewrite /etc/hosts"

# A whole `up` that fails (fake sstpc exits at once): stale hosts entry
# removed before resolving, firewall on from the start and kept after
reset_routes; rm -f "$T/run/pinned"
printf '127.0.0.1 localhost\n203.0.113.2 vpn.example.com # sstp-mac-client\n' > "$T/hosts"
printf '%s\n' "SSTP_HOST='vpn.example.com'" "SSTP_USER='alex'" "SSTP_PASS='pw'" > "$T/server.conf"
routes_helper 't) true'
out=$(FAKE_DNS=203.0.113.4 sh "$T/h.sh" up || true)
check 'printf "%s\n" "$out" | grep -q "^error=could not connect"' "a failed connect reports its error"
check '[ -s "$T/run/pf.token" ]' "a failed first connect leaves the kill-switch on"
check 'grep -qx "203.0.113.4 vpn.example.com # sstp-mac-client" "$T/hosts" && ! grep -q 203.0.113.2 "$T/hosts"' "up resolves without the stale hosts entry"
check '[ "$(sed -n 1p "$T/pf.log")" != "-E" ] && grep -n -- "-E" "$T/pf.log" | head -1 | grep -q .' "pf is enabled during up"
sh "$T/h.sh" down >/dev/null

# Resolving the server
reset_routes; rm -f "$T/run/pinned"
routes_helper 't) SERVER_NAME=vpn.example.com; pin_server_route; cat "$RUN/pinned"'
check '[ "$(FAKE_DNS=203.0.113.8 sh "$T/h.sh" t | tail -1)" = 203.0.113.8 ]' "before the firewall the system resolver is used"
reset_routes; rm -f "$T/run/pinned"; echo 42 > "$T/run/pf.token"
check '[ "$(FAKE_DIG=203.0.113.9 FAKE_DNS=203.0.113.8 sh "$T/h.sh" t | tail -1)" = 203.0.113.9 ]' "behind the firewall the server is resolved directly, as root"
check 'grep -q "@192.168.1.1" "$T/dig.log" && grep -q "^-n -u nobody dig" "$T/sudo.log"' "the system DNS servers are asked, as nobody"
reset_routes; echo 198.51.100.7 > "$T/run/pinned"
check '[ "$(sh "$T/h.sh" t | tail -1)" = 198.51.100.7 ]' "server pin falls back to the last address when nothing resolves"
reset_routes; echo 198.51.100.7 > "$T/run/pinned"; echo 42 > "$T/run/pf.token"
check '[ "$(sh "$T/h.sh" t | tail -1)" = 198.51.100.7 ]' "behind the firewall an unanswered lookup falls back to the last address"
reset_routes; echo 198.51.100.7 > "$T/run/pinned"
check '[ "$(FAKE_DEFIF=ppp0 sh "$T/h.sh" t | tail -1)" = 198.51.100.7 ]' "the last server pin survives a retry without a gateway"
rm -rf "$T/run" "$T/route.log" "$T/pf.log" "$T/dig.log"

# Cancel: `down` during an `up` stops that `up` first (it would otherwise
# carry on and turn the firewall back on); anything else holding the lock
# PID is left alone.
# The lock is a symlink whose target is the holder's PID (created atomically).
mkdir -p "$T/run"
helper 't) true'
perl -e '$0 = shift; sleep 30' "/bin/sh $T/h.sh up" & running_up=$!
sleep 0.3; ln -s "$running_up" "$T/run/up.lock"
sh "$T/h.sh" down >/dev/null
check '! kill -0 "$running_up" 2>/dev/null && [ ! -e "$T/run/up.lock" ] && [ ! -L "$T/run/up.lock" ]' "down cancels a running up"
sleep 30 & not_up=$!
ln -s "$not_up" "$T/run/up.lock"
sh "$T/h.sh" down >/dev/null
check 'kill -0 "$not_up" 2>/dev/null' "down does not kill another process holding a stale lock PID"
check '[ ! -L "$T/run/up.lock" ]' "down removes a lock that no up holds"
kill "$not_up" 2>/dev/null || true; wait 2>/dev/null || true
rm -rf "$T/run"

# A rejected password: a stable code for the app, whatever pppd's wording
reset_routes; rm -f "$T/run/pinned"; printf '127.0.0.1 localhost\n' > "$T/hosts"
printf '%s\n' "SSTP_HOST='vpn.example.com'" "SSTP_USER='alex'" "SSTP_PASS='pw'" > "$T/server.conf"
cp "$T/sstpc" "$T/sstpc.args"
printf '#!/bin/sh\necho "MS-CHAP authentication failed: E=691"\nexec sleep 5\n' > "$T/sstpc"
routes_helper 't) true'
out=$(FAKE_DNS=203.0.113.4 sh "$T/h.sh" up || true)
check 'printf "%s\n" "$out" | grep -qx "error_code=auth"' "a rejected password is reported with error_code=auth"
check 'printf "%s\n" "$out" | grep -qx "error=authentication failed"' "and with the old message for older apps"
sh "$T/h.sh" down >/dev/null; pkill -f "$T/run/ppp.options" 2>/dev/null || true
mv -f "$T/sstpc.args" "$T/sstpc"; rm -rf "$T/run" "$T/route.log" "$T/pf.log"

# PIDs from pid files may have been reused by another process by now: only
# our sstpc and pppd are killed, and only they count as a running session.
# Like the real ones, the fakes carry our options file on their command line,
# and pppd renames itself after its tty (it shows as /dev/ttys000 in ps).
mkdir -p "$T/run"
fake(){ perl -e '$0 = shift; sleep 30' "$1" & }
sleep 30 & other=$!
fake "/dev/ttys000 38400 user alex file /tmp//sstp-pppd.X file $T/run/ppp.options"; fake_pppd=$!
fake "$T/sstpc --log-stderr vpn.example.com -- file $T/run/ppp.options"; fake_sstpc=$!
sleep 0.3
check 'kill -0 "$fake_pppd" && kill -0 "$fake_sstpc"' "fake pppd and sstpc are running"
helper 't) pppd_alive && echo alive || echo dead'
printf '%s\nppp9\n' "$fake_pppd" > "$T/none.pid"
check '[ "$(sh "$T/h.sh" t)" = alive ]' "pppd is recognised although it renamed itself after its tty"
printf '%s\nppp9\n' "$other" > "$T/none.pid"
check '[ "$(sh "$T/h.sh" t)" = dead ]' "a reused pppd PID is not our pppd"
helper 't) true'
echo "$other" > "$T/run/sstpc.pid"
sh "$T/h.sh" down >/dev/null
check 'kill -0 "$other" 2>/dev/null' "down does not kill a process that reused a PID"
printf '%s\nppp9\n' "$fake_pppd" > "$T/none.pid"; echo "$fake_sstpc" > "$T/run/sstpc.pid"
sh "$T/h.sh" down >/dev/null; sleep 1
check '! kill -0 "$fake_pppd" 2>/dev/null && ! kill -0 "$fake_sstpc" 2>/dev/null' "down stops pppd and sstpc"
kill "$other" "$fake_pppd" "$fake_sstpc" 2>/dev/null || true
wait 2>/dev/null || true
rm -rf "$T/run" "$T/none.pid"

helper 't) true'
check '[ "$(sh "$T/h.sh" status | head -1)" = state=disconnected ]' "status when idle"
check 'sh "$T/h.sh" status | grep -qx "version=[0-9]*"' "status reports the helper version"
check 'sh "$T/h.sh" down | grep -qx state=disconnected' "down when idle"
mkdir -p "$T/run"; echo 192.0.2.1 > "$T/run/pinned"
check '[ "$(sh "$T/h.sh" status | head -1)" = state=dropped ]' "leftover routes report a dropped session"
rm -f "$T/run/pinned"
check '! sh "$T/h.sh" bogus 2>/dev/null' "unknown command is rejected"
printf 'x --password hunter2 y\npassword "hunter2"\n' > "$T/log"
check '! sh "$T/h.sh" log | grep -q hunter2' "log output hides passwords"

echo "SSTP_HOST='bad host;rm'" >> "$T/server.conf"
helper 't) load_conf'
check 'sh "$T/h.sh" t | grep -q "^error=invalid server address"' "bad host is rejected"
echo "SSTP_HOST='--help'" >> "$T/server.conf"
check 'sh "$T/h.sh" t | grep -q "^error=invalid server address"' "a host that looks like an option is rejected"
printf "SSTP_HOST='vpn.example.com'\nSSTP_PASS='%0129d'\n" 0 >> "$T/server.conf"
check 'sh "$T/h.sh" t | grep -q "^error=the password is too long"' "a password too long for sstpc is rejected"

# One `up` at a time
printf '%s\n' "SSTP_HOST='vpn.example.com'" "SSTP_USER='alex'" "SSTP_PASS='pw'" > "$T/server.conf"
rm -rf "$T/run" "$T/log"; mkdir -p "$T/run"
helper 't) true'
perl -e '$0 = shift; sleep 30' "/bin/sh $T/h.sh up" & other_up=$!
sleep 0.3; ln -s "$other_up" "$T/run/up.lock"
check 'sh "$T/h.sh" up | grep -qx state=disconnected' "second up reports status while another up runs"
check '[ ! -s "$T/log" ]' "second up does not start another sstpc"
kill "$other_up" 2>/dev/null || true; wait "$other_up" 2>/dev/null || true
rm -f "$T/run/up.lock"; ln -s 999999 "$T/run/up.lock"
helper 't) take_up_lock && echo got'
check '[ "$(sh "$T/h.sh" t)" = got ]' "stale up lock of a dead helper is taken over"
check '[ ! -L "$T/run/up.lock" ]' "up lock is released on exit"
rm -f "$T/run/up.lock"; mkdir -p "$T/run/up.lock"; echo 999999 > "$T/run/up.lock/pid"
check '[ "$(sh "$T/h.sh" t)" = got ] && [ ! -e "$T/run/up.lock" ]' "a stale directory lock of an older helper is replaced"
sleep 30 & reused=$!
rm -f "$T/run/up.lock"; ln -s "$reused" "$T/run/up.lock"
check '[ "$(sh "$T/h.sh" t)" = got ]' "a lock PID reused by another process does not block connecting"
kill "$reused" 2>/dev/null || true; wait "$reused" 2>/dev/null || true
# A user's process carrying our options path is not our session
perl -e '$0 = shift; sleep 30' "sleep 99 $T/run/ppp.options" & fake_session=$!
sleep 0.3
check '[ "$(sh "$T/h.sh" status | head -1)" = state=disconnected ]' "a non-root process with our options path is not a session"
kill "$fake_session" 2>/dev/null || true; wait 2>/dev/null || true

# Rejected login or password is recognised, only in the new part of the log
helper 't) auth_failed_since "$2" && echo yes || echo no'
echo "MS-CHAP authentication failed: Authentication failure" > "$T/log"
check '[ "$(sh "$T/h.sh" t "$(stat -f %z "$T/log")")" = no ]' "an old auth failure in the log is ignored"
check '[ "$(sh "$T/h.sh" t 0)" = yes ]' "auth failure is recognised"

# A log that cannot be written (disk full) does not abort `down` midway
helper 't) true'
sed -i '' "s#^LOG=.*#LOG=/nonexistent/sstp-test.log#" "$T/h.sh"
check 'sh "$T/h.sh" down 2>/dev/null | grep -qx state=disconnected' "down completes even when the log cannot be written"
helper 't) echo "$LC_ALL"'
check '[ "$(LC_ALL=ru_RU.UTF-8 sh "$T/h.sh" t)" = C ]' "the helper runs the system tools in the C locale"

# --- install-helper.sh (validation only, no root) --------------------------
sed -e 's/^\[ "$(id -u)" = 0 \] || die "must run as root"$/:/' \
    -e "s#^CONF=.*#CONF=$T/saved.conf#" "$ROOT/helper/install-helper.sh" > "$T/i.sh"
settings(){ printf '%s\n' "SSTP_HOST=$1" "SSTP_USER=$2" "SSTP_PASS=$3" > "$T/s"; chmod 600 "$T/s"; }
validate(){ # validate HOST USER PASS -> prints error or "valid"
	settings "$1" "$2" "$3"
	sh -c ". '$T/i.sh' >/dev/null 2>&1 || true" 2>/dev/null
	HOST=$1 LOGIN=$2 PASS=$3 VERIFY=1 BLOCK6=1 sh -c "
		$(sed -n '/^die()/p; /^validate(){/,/^}/p' "$ROOT/helper/install-helper.sh")
		validate && echo valid" 2>&1
}
check '[ "$(validate vpn.example.com alex pw)" = valid ]' "installer accepts valid settings"
check '[ "$(validate vpn.example.com:443 alex pw)" = valid ]' "installer accepts host:port"
check 'validate "vpn example.com" alex pw | grep -q error=' "installer rejects spaces in host"
check 'validate vpn.example.com:99999 alex pw | grep -q error=' "installer rejects bad port"
check 'validate vpn.example.com alex "a\"b" | grep -q error=' "installer rejects double quote in password"
check 'validate vpn.example.com alex "a\\b" | grep -q error=' "installer rejects backslash in password"
check 'validate vpn.example.com "" pw | grep -q error=' "installer rejects empty login"
check 'validate -vpn.example.com alex pw | grep -q error=' "installer rejects a host that looks like an option"
long=$(printf '%0129d' 0)
check 'validate vpn.example.com alex "$long" | grep -q error=' "installer rejects a password too long for sstpc"
check '[ "$(validate vpn.example.com alex "${long#0}")" = valid ]' "installer accepts a 128-byte password"

# value() never sources the file: shell syntax stays data
printf 'SSTP_HOST=$(touch %s/pwned)\n' "$T" > "$T/s"
sh -c "$(sed -n '/^value(){/p' "$ROOT/helper/install-helper.sh"); value SSTP_HOST '$T/s'" >/dev/null
check '[ ! -e "$T/pwned" ]' "settings file values are not executed"

# shq() round-trips through sh
q=$(sh -c "$(sed -n '/^shq(){/p' "$ROOT/helper/install-helper.sh"); shq \"p'a\\\\ss&\\\$x\"")
check '[ "$(sh -c "printf %s $q")" = "p'"'"'a\\ss&\$x" ]' "shq() quoting round-trips"

# render_conf() writes a file that sources back to the exact values
conf=$(HOST=vpn.example.com LOGIN='DOMAIN\alex' PASS="p'a\\ss&\$x ;|" VERIFY=1 BLOCK6=0 sh -c "
	$(sed -n '/^shq(){/p; /^render_conf(){/,/^}/p' "$ROOT/helper/install-helper.sh")
	render_conf")
printf '%s\n' "$conf" > "$T/rendered.conf"
check '[ "$(sh -c ". \"$T/rendered.conf\"; printf %s \"\$SSTP_USER\"")" = "DOMAIN\\alex" ]' "rendered login survives backslashes"
check '[ "$(sh -c ". \"$T/rendered.conf\"; printf %s \"\$SSTP_PASS\"")" = "p'"'"'a\\ss&\$x ;|" ]' "rendered password survives special characters"
check 'grep -qx BLOCK_IPV6=0 "$T/rendered.conf"' "rendered options"

# Every fixed helper/installer message has a Russian translation (the app
# looks them up by their English text)
for f in "$ROOT/helper/sstp-helper" "$ROOT/helper/install-helper.sh"; do
	# usage lines are for developers calling the scripts by hand
	grep -oE 'die "[^"$]+"' "$f" | sed -E 's/^die "(.*)"$/\1/' | grep -v '^usage:' | sort -u |
	while IFS= read -r msg; do
		grep -qF "\"$msg\" = " "$ROOT/Resources/ru.lproj/Localizable.strings" || echo "$msg"
	done
done > "$T/untranslated"
check '[ ! -s "$T/untranslated" ]' "helper messages have Russian translations: $(tr '\n' ';' < "$T/untranslated")"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
