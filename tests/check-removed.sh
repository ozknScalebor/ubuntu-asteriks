#!/bin/bash
# check-removed.sh <snapshot-dir> [extra-package...]
# Fails unless the system matches the snapshot taken before install.sh
# (plus the given packages, which were installed later by something else).
set -euo pipefail
S="$1"; shift
fail=0
check() { if eval "$2"; then echo "OK    $1"; else echo "FAIL  $1"; fail=1; fi; }
T="$(mktemp -d)"
bash "$(dirname "$0")/snapshot.sh" "$T" >/dev/null
{ cat "$S/packages.txt"; printf '%s\n' "$@"; } | sed '/^$/d' | sort -u > "$T/expected.txt"
check "installed packages are the same as before install.sh${*:+ (+ $*)}" "diff '$T/expected.txt' '$T/packages.txt'"
check "users and groups are the same as before"     "diff '$S/accounts.txt' '$T/accounts.txt'"
check "/etc/localtime and /etc/timezone unchanged"  "diff '$S/files.txt' '$T/files.txt'"
check "no partially removed packages"               "! dpkg -l | grep -E '^(rc|iU|iF|rF|rH)' >/dev/null"
for p in /etc/asterisk /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /var/run/asterisk \
         /usr/lib/asterisk /usr/share/asterisk /usr/sbin/asterisk /opt/asterisk-alembic /opt/asterisk-offline \
         /var/lib/asterisk-offline /etc/systemd/system/asterisk.service.d /lib/systemd/system/asterisk.service \
         /var/lib/mysql /etc/mysql /run/mysqld /etc/odbc.ini; do
  check "$p removed" "[ ! -e '$p' ]"
done
check "no asterisk or mysqld process" "! grep -x -e asterisk -e mysqld /proc/[0-9]*/comm >/dev/null 2>&1"
B="$(ls -d /var/backups/asterisk-offline-uninstall-* | tail -1)"
check "backup: database dump"    "[ -s '$B/asterisk.sql.gz' ] && zcat '$B/asterisk.sql.gz' | grep 'CREATE TABLE \`ps_endpoints\`' >/dev/null"
check "backup: /etc/asterisk"    "tar -tzf '$B/etc-asterisk.tar.gz' | grep -x 'etc/asterisk/extensions.conf' >/dev/null"
rm -rf "$T"
exit $fail
