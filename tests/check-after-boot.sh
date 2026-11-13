#!/bin/bash
# check-after-boot.sh - after a reboot MySQL and Asterisk must be up on their own
set -euo pipefail
for i in $(seq 1 60); do asterisk -rx "core waitfullybooted" >/dev/null 2>&1 && break; sleep 1; done
for u in mysql asterisk; do
  printf "%-10s %s, %s, restarts=%s\n" "$u" "$(systemctl is-active $u)" "$(systemctl is-enabled $u)" "$(systemctl show -p NRestarts --value $u)"
  [ "$(systemctl is-active $u)" = active ]
done
[ "$(systemctl show -p NRestarts --value asterisk)" = 0 ]
ls -ld /run/asterisk
systemctl show -p After --value asterisk | tr " " "\n" | grep -x mysql.service >/dev/null
asterisk -rx "core show version"
n="$(asterisk -rx "odbc show asterisk" | sed -n "s/.*Number of active connections: \([0-9]*\).*/\1/p")"
echo "ODBC active connections: ${n:-0}"; [ "${n:-0}" -ge 1 ]
asterisk -rx "module show like codec_g723" | grep -E "codec_g723.so .*Running" >/dev/null
asterisk -rx "dialplan show 888@default" | grep -F "Gosub(sub-join_conference2,s,1)" >/dev/null
echo "reboot test passed"
