#!/bin/bash
# test-reinstall.sh - run inside the extracted bundle on a fresh Ubuntu 24.04:
# install, uninstall, check that the system is as before, install again,
# then uninstall with a package installed later that needs one of ours.
set -euo pipefail
T="$(cd "$(dirname "$0")" && pwd)"
step() { echo; echo "=================== $*"; }

bash "$T/snapshot.sh" /root/before
step "install"
bash ./install.sh
if dpkg -s gcc >/dev/null 2>&1; then echo "compiler installed on the target (unexpected)"; exit 1; fi

step "uninstall refuses to run without confirmation when there is no terminal"
if bash /var/lib/asterisk-offline/uninstall.sh </dev/null; then echo "uninstall ran without confirmation"; exit 1; fi
step "uninstall --dry-run changes nothing"
bash /var/lib/asterisk-offline/uninstall.sh --dry-run
asterisk -rx 'core show version' >/dev/null && [ -d /var/lib/asterisk-offline ] && dpkg -s asterisk-offline >/dev/null

step "uninstall"
bash /var/lib/asterisk-offline/uninstall.sh --yes
bash "$T/check-removed.sh" /root/before

step "install again on the cleaned system"
bash ./install.sh

step "uninstall keeps packages that software installed later depends on"
bash "$T/dummy-deb.sh" other-app psmisc
bash ./uninstall.sh --yes
bash "$T/check-removed.sh" /root/before other-app psmisc
echo; echo "reinstall test passed"
