#!/bin/bash
# =====================================================================
#  collect-packages.sh
#  Runs on an INTERNET-CONNECTED Ubuntu 24.04 machine (or a clean
#  ubuntu:24.04 container). Produces bundle/ for the offline target:
#    bundle/debs/    asterisk-offline .deb + every runtime dependency,
#                    MySQL, ODBC, python3-venv, and a local apt index
#    bundle/wheels/  alembic + PyMySQL wheels for the target's Python
#
#  If bundle/debs/asterisk-offline_*.deb does not exist yet,
#  build-asterisk-deb.sh is run first.
#
#  Usage:  sudo bash collect-packages.sh
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
. "$HERE/config.env"

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
. /etc/os-release
[ "${VERSION_CODENAME:-}" = "$UBUNTU_CODENAME" ] || { echo "Must run on $UBUNTU_CODENAME (this system: ${VERSION_CODENAME:-?})."; exit 1; }

log() { echo -e "\n==== $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

B="$HERE/bundle"
mkdir -p "$B/debs" "$B/wheels"
DEB="$B/debs/asterisk-offline_${ASTERISK_VERSION}-1_amd64.deb"

# ---------------------------------------------------------------------
log "1/4 Asterisk package"
if [ ! -s "$DEB" ]; then
  echo "  $DEB not found, building it."
  bash "$HERE/build-asterisk-deb.sh"
fi
[ -s "$DEB" ] || die "$DEB was not produced"
dpkg-deb -f "$DEB" Package Version

# ---------------------------------------------------------------------
log "2/4 Runtime .deb packages (full dependency closure)"
# Packages install.sh asks apt for. Build tools (gcc, -dev) are NOT included.
echo "asterisk-offline mysql-server mysql-client unixodbc odbcinst odbc-mariadb python3-venv" \
  | tr ' ' '\n' > "$B/debs/PACKAGE-LIST.txt"

apt-get update
command -v apt-ftparchive >/dev/null || apt-get install -y apt-utils
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# Empty dpkg status: pretend nothing is installed, so every dependency is downloaded.
# This way nothing is missing on the target, whether it is a desktop or a minimal server.
: > "$WORK/status"
apt-get -y --download-only \
  -o Dir::State::status="$WORK/status" \
  -o Dir::Cache::archives="$B/debs" \
  -o APT::Install-Recommends=false \
  install "$DEB" $(grep -v '^asterisk-offline$' "$B/debs/PACKAGE-LIST.txt")
rm -rf "$B/debs/partial" "$B/debs/lock"

# Local apt repository index (apt resolves dependencies on the target)
(cd "$B/debs" && apt-ftparchive packages . > Packages && gzip -9kf Packages)

# ---------------------------------------------------------------------
log "3/4 Python wheels (alembic + PyMySQL, Python $TARGET_PYTHON)"
python3 -m pip --version >/dev/null 2>&1 || apt-get install -y python3-pip
python3 -m pip download --only-binary=:all: --dest "$B/wheels" \
  --python-version "${TARGET_PYTHON/./}" --platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 \
  alembic pymysql

# ---------------------------------------------------------------------
log "4/4 Summary"
echo "  .deb files: $(ls "$B"/debs/*.deb | wc -l)"
echo "  wheels:     $(ls "$B"/wheels/*.whl | wc -l)"
if dpkg-deb -f "$DEB" Depends | grep -qE '(^|[ ,])(gcc|g\+\+|make)[ ,(]'; then die "the Asterisk package depends on a compiler"; fi
du -sh "$B"
echo
echo "Done. Copy this folder (including bundle/) to the offline machine and run:"
echo "  sudo bash install.sh"
