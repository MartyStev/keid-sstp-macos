#!/bin/sh
# install-helper.sh — run as root by Keid through the standard macOS
# administrator prompt ("do shell script ... with administrator privileges").
#
#   install-helper.sh install <resources-dir> <settings-file> <user>
#   install-helper.sh uninstall
#
# install: copies sstp-helper and the bundled sstpc into a root-owned
# directory, writes the server settings (root, 600) and a sudoers rule that
# lets <user> run `sstp-helper up|down|status|log` without a password.
#
# <settings-file> is written by the app (mode 600) and deleted here. One
# KEY=VALUE per line, values are raw (never sourced): SSTP_HOST, SSTP_USER,
# SSTP_PASS, VERIFY_CERT, BLOCK_IPV6. An empty SSTP_PASS keeps the saved one.
set -eu
umask 022
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

BASE=/Library/PrivilegedHelperTools/sstp-mac-client
HELPER=$BASE/sstp-helper
CONFDIR=/etc/sstp-mac-client
CONF=$CONFDIR/server.conf
SUDOERS=/etc/sudoers.d/sstp-mac-client
RUN=/var/run/sstp-mac-client
LOG=/var/log/sstp-mac-client.log

die(){ printf 'error=%s\n' "$*"; exit 1; }
[ "$(id -u)" = 0 ] || die "must run as root"

# Single-quote for sh: the settings file is sourced by sstp-helper.
shq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# value KEY FILE — the raw value of KEY (first match), or empty.
value(){ sed -n "s/^$1=//p" "$2" | head -1; }

saved_value(){
	[ -f "$CONF" ] || return 0
	# shellcheck disable=SC1090
	( . "$CONF"; eval "printf '%s' \"\${$1:-}\"" )
}

validate(){
	case "$HOST" in ''|*[!A-Za-z0-9.:-]*) die "server address may contain only letters, digits, dots, dashes and :port" ;; esac
	# sstpc would take a host starting with a dash for an option
	case "$HOST" in [!A-Za-z0-9]*) die "server address must start with a letter or a digit" ;; esac
	case "$HOST" in *:*)
		_port=${HOST##*:}
		case "$_port" in ''|*[!0-9]*) die "port must be a number" ;; esac
		[ "$_port" -ge 1 ] && [ "$_port" -le 65535 ] || die "port must be 1–65535" ;;
	esac
	[ -n "$LOGIN" ] || die "login is empty"
	[ -n "$PASS" ] || die "password is empty"
	# sstpc writes the password into a pppd options file as password "…"
	# without escaping: pppd would end the word at a double quote and treat a
	# backslash as an escape, so the server would get a different password.
	case "$PASS" in *\"*|*\\*) die "the password cannot contain a double quote or a backslash (sstpc limitation)" ;; esac
	# sstpc's buffer for `password "…"` is 255 bytes and it writes past it
	[ "$(printf '%s' "$PASS" | wc -c | tr -d ' ')" -le 128 ] || die "the password is too long (at most 128 bytes)"
	case "$VERIFY" in 0|1) ;; *) die "bad VERIFY_CERT" ;; esac
	case "$BLOCK6" in 0|1) ;; *) die "bad BLOCK_IPV6" ;; esac
}

install_files(){
	_res=$1
	[ -f "$_res/sstp-helper" ] && [ -x "$_res/sstpc" ] || die "app bundle is incomplete: $_res"
	mkdir -p "$BASE"
	chown root:wheel "$BASE"; chmod 755 "$BASE"
	install -o root -g wheel -m 755 "$_res/sstp-helper" "$HELPER"
	install -o root -g wheel -m 755 "$_res/sstpc" "$BASE/sstpc"
	# sstpc privilege separation directory (it runs as root otherwise)
	mkdir -p /var/run/sstpc
	touch /etc/ppp/options
}

render_conf(){
	# printf, not echo: /bin/sh's echo expands backslashes (DOMAIN\alex)
	printf '%s\n' "# Keid server settings. Change them in the app (Settings)." \
		"SSTP_HOST=$(shq "$HOST")" "SSTP_USER=$(shq "$LOGIN")" "SSTP_PASS=$(shq "$PASS")" \
		"VERIFY_CERT=$VERIFY" "BLOCK_IPV6=$BLOCK6"
}

write_conf(){
	mkdir -p "$CONFDIR"; chown root:wheel "$CONFDIR"; chmod 700 "$CONFDIR"
	_tmp=$(mktemp "$CONFDIR/.server.conf.XXXXXX")
	render_conf > "$_tmp"
	chown root:wheel "$_tmp"; chmod 600 "$_tmp"
	mv -f "$_tmp" "$CONF"
}

write_sudoers(){
	_user=$1
	_tmp=$(mktemp /tmp/sstp-mac-client.sudoers.XXXXXX)
	cat > "$_tmp" <<EOF
# Keid: these four helper commands only, no other arguments.
$_user ALL=(root) NOPASSWD: $HELPER up, $HELPER down, $HELPER status, $HELPER log
EOF
	visudo -cf "$_tmp" >/dev/null || { rm -f "$_tmp"; die "sudoers rule failed validation"; }
	install -o root -g wheel -m 440 "$_tmp" "$SUDOERS"
	rm -f "$_tmp"
}

cmd_install(){
	[ $# -eq 3 ] || die "usage: install <resources-dir> <settings-file> <user>"
	_res=$1; _settings=$2; _user=$3
	# macOS short user names; anything else must not reach sudoers.
	case "$_user" in ''|*[!A-Za-z0-9_.-]*|[.-]*) die "bad user name" ;; esac
	id "$_user" >/dev/null 2>&1 || die "no such user: $_user"
	[ -f "$_settings" ] || die "settings file is missing"
	# The settings file must belong to the requesting user and be private.
	[ "$(stat -f %Su "$_settings")" = "$_user" ] || die "settings file has the wrong owner"
	case "$(stat -f %Lp "$_settings")" in 600|400) ;; *) die "settings file must be mode 600" ;; esac

	HOST=$(value SSTP_HOST "$_settings")
	LOGIN=$(value SSTP_USER "$_settings")
	PASS=$(value SSTP_PASS "$_settings")
	VERIFY=$(value VERIFY_CERT "$_settings"); VERIFY=${VERIFY:-1}
	BLOCK6=$(value BLOCK_IPV6 "$_settings"); BLOCK6=${BLOCK6:-1}
	rm -f "$_settings"
	[ -n "$PASS" ] || PASS=$(saved_value SSTP_PASS)
	validate

	# A running session keeps the old settings; stop it first.
	[ -x "$HELPER" ] && "$HELPER" down >/dev/null 2>&1 || true
	install_files "$_res"
	write_conf
	write_sudoers "$_user"
	echo "ok"
}

cmd_uninstall(){
	[ -x "$HELPER" ] && "$HELPER" down >/dev/null 2>&1 || true
	# in case the helper was already gone: no kill-switch may outlive the app
	pfctl -a com.apple/sstp-mac-client -F rules >/dev/null 2>&1 || true
	for _tok in $(cat /var/run/sstp-mac-client/pf.token 2>/dev/null); do pfctl -X "$_tok" >/dev/null 2>&1 || true; done
	if grep -q ' # sstp-mac-client$' /etc/hosts 2>/dev/null; then
		_tmp=$(mktemp /etc/hosts.sstp.XXXXXX)
		_rc=0; grep -v ' # sstp-mac-client$' /etc/hosts > "$_tmp" || _rc=$?
		if [ "$_rc" -le 1 ]; then
			chmod 644 "$_tmp"; chown root:wheel "$_tmp"; mv -f "$_tmp" /etc/hosts
		else
			rm -f "$_tmp"
		fi
	fi
	rm -f "$SUDOERS"
	rm -rf "$BASE" "$CONFDIR" "$RUN"
	rm -f "$LOG" "$LOG.1"
	echo "ok"
}

case "${1:-}" in
	install) shift; cmd_install "$@" ;;
	uninstall) cmd_uninstall ;;
	*) die "usage: install-helper.sh install <resources-dir> <settings-file> <user> | uninstall" ;;
esac
