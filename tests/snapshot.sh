#!/bin/bash
# snapshot.sh <dir> - records the system state that uninstall.sh must restore
set -euo pipefail
mkdir -p "$1"
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="ii"{print $2}' | sort > "$1/packages.txt"
{ getent passwd | cut -d: -f1; getent group | cut -d: -f1 | sed 's/^/group:/'; } | sort > "$1/accounts.txt"
for f in /etc/localtime /etc/timezone; do
  if [ -L "$f" ]; then echo "$f -> $(readlink "$f")"; elif [ -e "$f" ]; then md5sum "$f"; else echo "$f absent"; fi
done > "$1/files.txt"
echo "snapshot: $(wc -l < "$1/packages.txt") packages"
