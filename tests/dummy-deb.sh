#!/bin/bash
# dummy-deb.sh <name> <depends> - installs a minimal package with the given dependencies
set -euo pipefail
D="$(mktemp -d)"; mkdir "$D/DEBIAN"
printf 'Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDepends: %s\nDescription: test package\n' "$1" "$2" > "$D/DEBIAN/control"
dpkg-deb -b "$D" "$D.deb" >/dev/null && dpkg -i "$D.deb" >/dev/null && rm -rf "$D" "$D.deb"
echo "installed $1 (Depends: $2)"
