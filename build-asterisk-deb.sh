#!/bin/bash
# =====================================================================
#  build-asterisk-deb.sh
#  Runs on an INTERNET-CONNECTED Ubuntu 24.04 machine (or a clean
#  ubuntu:24.04 container). Compiles Asterisk once and produces a single
#  .deb package:
#      bundle/debs/asterisk-offline_<version>-1_amd64.deb
#
#  Included in the package: Asterisk with bundled pjproject, sound packages,
#  codec_opus, the systemd unit and the alembic schema scripts
#  (/usr/share/asterisk/ast-db-manage).
#  NOT included: /etc/asterisk (configuration ships separately and is
#  installed by install.sh).
#
#  Usage:    sudo bash build-asterisk-deb.sh
#  Testing:  ASTERISK_TARBALL=/path/asterisk.tar.gz  SKIP_SOUNDS=1  SKIP_EXTERNAL_CODECS=1
# =====================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
. "$HERE/config.env"

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }
. /etc/os-release
[ "${VERSION_CODENAME:-}" = "$UBUNTU_CODENAME" ] || { echo "Must run on $UBUNTU_CODENAME (this system: ${VERSION_CODENAME:-?})."; exit 1; }

log()   { echo -e "\n==== $*"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
fetch() { echo "  downloading: $1"; curl -fL --retry 3 --connect-timeout 20 -o "$2.part" "$1" && mv "$2.part" "$2"; }
is_elf() { [ "$(head -c4 "$1" | od -An -c | tr -d ' ')" = '177ELF' ]; }

export DEBIAN_FRONTEND=noninteractive
W="$HERE/build"                       # work directory (not committed)
CACHE="$W/cache"                      # externals + sounds cache
OUT="$HERE/bundle/debs"
PKG="asterisk-offline"
DEBVER="${ASTERISK_VERSION}-1"
mkdir -p "$W/dl" "$CACHE" "$OUT"

# ---------------------------------------------------------------------
log "1/7 Asterisk $ASTERISK_VERSION source"
TARBALL="$W/dl/asterisk-$ASTERISK_VERSION.tar.gz"
if [ -n "${ASTERISK_TARBALL:-}" ]; then
  cp "$ASTERISK_TARBALL" "$TARBALL"
elif [ ! -s "$TARBALL" ]; then
  fetch "https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-$ASTERISK_VERSION.tar.gz" "$TARBALL" \
   || fetch "https://github.com/asterisk/asterisk/releases/download/$ASTERISK_VERSION/asterisk-$ASTERISK_VERSION.tar.gz" "$TARBALL"
  if curl -fsL -o "$TARBALL.sha256" "https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-$ASTERISK_VERSION.sha256"; then
    (cd "$W/dl" && sha256sum --ignore-missing -c "asterisk-$ASTERISK_VERSION.tar.gz.sha256")
  fi
fi
rm -rf "$W/src"; mkdir -p "$W/src"
tar -xzf "$TARBALL" -C "$W/src"
SRC="$W/src/asterisk-$ASTERISK_VERSION"
[ -x "$SRC/configure" ] || die "$SRC/configure not found"

# ---------------------------------------------------------------------
log "2/7 Bundled third-party sources (pjproject)"
. "$SRC/third-party/versions.mak"
PJ="pjproject-$PJPROJECT_VERSION.tar.bz2"
[ -s "$CACHE/$PJ" ] || fetch "https://raw.githubusercontent.com/asterisk/third-party/master/pjproject/$PJPROJECT_VERSION/$PJ" "$CACHE/$PJ"
want="$(grep -F "$PJ" "$SRC/third-party/pjproject/$PJ.md5" | cut -d' ' -f1)"
got="$(md5sum "$CACHE/$PJ" | cut -d' ' -f1)"
[ "$want" = "$got" ] || die "pjproject MD5 mismatch ($got != $want)"

# ---------------------------------------------------------------------
log "3/7 Sound packages ($SOUND_PACKAGES)"
if [ -z "${SKIP_SOUNDS:-}" ]; then
  eval "$(grep -E '^(CORE_SOUNDS_VERSION|EXTRA_SOUNDS_VERSION|MOH_VERSION):=' "$SRC/sounds/Makefile" | sed 's/:=/=/')"
  SURL="https://downloads.asterisk.org/pub/telephony/sounds/releases"
  for p in $SOUND_PACKAGES; do
    lc="$(echo "$p" | tr 'A-Z' 'a-z')"
    case "$lc" in
      core-sounds-*)  f="asterisk-$lc-$CORE_SOUNDS_VERSION.tar.gz" ;;
      extra-sounds-*) f="asterisk-$lc-$EXTRA_SOUNDS_VERSION.tar.gz" ;;
      moh-*)          f="asterisk-$lc-$MOH_VERSION.tar.gz" ;;
      *) die "Unknown sound package: $p" ;;
    esac
    [ -s "$CACHE/$f" ] || fetch "$SURL/$f" "$CACHE/$f"
    [ -s "$CACHE/$f.sha1" ] || fetch "$SURL/$f.sha1" "$CACHE/$f.sha1" || true
  done
fi

# ---------------------------------------------------------------------
log "4/7 Prebuilt Digium codecs ($EXTERNAL_CODECS)"
if [ -z "${SKIP_EXTERNAL_CODECS:-}" ]; then
  MAJ="${ASTERISK_VERSION%%.*}.0"
  for m in $EXTERNAL_CODECS; do
    base="https://downloads.digium.com/pub/telephony/$m/asterisk-$MAJ/x86-64"
    fetch "$base/manifest.xml" "$W/dl/$m-manifest.xml"
    ver="$(sed -n 's/.*<package[^>]* version="\([^"]*\)".*/\1/p' "$W/dl/$m-manifest.xml" | sed -n 1p)"
    [ -n "$ver" ] || die "could not read the $m version from its manifest"
    [ -s "$CACHE/$m-$ver-x86_64.tar.gz" ] || fetch "$base/$m-$ver-x86_64.tar.gz" "$CACHE/$m-$ver-x86_64.tar.gz"
  done
fi

# asterisk-g72x prebuilt modules (G.723.1)
if [ -z "${SKIP_EXTERNAL_CODECS:-}" ] && [ -n "${G72X_CODECS:-}" ]; then
  G72X_TAG="ast${ASTERISK_VERSION%%.*}0-gcc4-glibc-$G72X_CPU"        # e.g. ast220-gcc4-glibc-x86_64-pentium4
  g72x_get() { curl -fL --retry 3 --connect-timeout 20 -o "$2.part" "https://asterisk.hosting.lv/bin/$1" \
               || curl -fL --retry 3 --connect-timeout 20 -o "$2.part" "http://asterisk.hosting.lv/bin/$1"; mv "$2.part" "$2"; }
  echo "  downloading asterisk-g72x MD5SUM"; g72x_get MD5SUM "$W/dl/g72x-MD5SUM"
  for m in $G72X_CODECS; do
    f="$m-$G72X_TAG.so"
    if [ ! -s "$CACHE/$f" ]; then echo "  downloading: $f"; g72x_get "$f" "$CACHE/$f"; fi
    want="$(awk -v f="$f" '$2==f || $2=="*"f {print $1}' "$W/dl/g72x-MD5SUM")"
    got="$(md5sum "$CACHE/$f" | cut -d' ' -f1)"
    [ -n "$want" ] || die "$f is not listed in the asterisk-g72x MD5SUM file"
    [ "$want" = "$got" ] || die "$f MD5 mismatch ($got != $want)"
    echo "  $f MD5 OK"
  done
fi

# ---------------------------------------------------------------------
log "5/7 Build dependencies (installed on this machine only, not packaged)"
eval "$(grep -E '^PACKAGES_DEBIAN(_BUILD)?=' "$SRC/contrib/scripts/install_prereq")"
DROP=" doxygen graphviz subversion wget "
# libjwt-dev is required by res_stir_shaken / res_pjsip_stir_shaken in Asterisk 21+,
# but install_prereq does not list it; without it menuselect silently skips both modules.
# libsystemd-dev is required for sd_notify(): the shipped systemd unit is Type=notify and
# waits for READY=1. Without it Asterisk never reports ready and systemd kills it after
# the start timeout. install_prereq does not list it either.
BUILD_PKGS="dpkg-dev binutils libjwt-dev libsystemd-dev"
apt-get update
for p in $PACKAGES_DEBIAN; do
  [[ "$DROP" == *" $p "* ]] && continue
  if apt-cache show "$p" >/dev/null 2>&1; then BUILD_PKGS="$BUILD_PKGS $p"; else echo "  (not available, skipped: $p)"; fi
done
apt-get install -y --no-install-recommends $BUILD_PKGS

# ---------------------------------------------------------------------
log "6/7 Compiling Asterisk"
cd "$SRC"
./configure --with-pjproject-bundled --with-jansson-bundled=no \
            --with-externals-cache="$CACHE" --with-sounds-cache="$CACHE"
make menuselect.makeopts
MS=menuselect/menuselect
# No CPU-specific optimisation: the package must run on other CPUs
$MS --disable BUILD_NATIVE menuselect.makeopts
$MS --disable-category MENUSELECT_CORE_SOUNDS --disable-category MENUSELECT_MOH \
    --disable-category MENUSELECT_EXTRA_SOUNDS menuselect.makeopts
for p in $SOUND_PACKAGES; do
  if compgen -G "$CACHE/asterisk-$(echo "$p" | tr 'A-Z' 'a-z')-*.tar.gz" >/dev/null; then
    $MS --enable "$p" menuselect.makeopts
  else
    echo "  WARNING: $p is not in the cache and will not be packaged"
  fi
done
# Asterisk's own externals downloader needs internet; codecs are added manually below
for m in $EXTERNAL_CODECS; do $MS --disable "$m" menuselect.makeopts || true; done
for m in $REQUIRED_MODULES; do $MS --enable "$m" menuselect.makeopts; done

make -j"$(nproc)"

DEST="$W/root"
rm -rf "$DEST"
make install DESTDIR="$DEST"
make samples DESTDIR="$DEST"      # phoneprov templates + sample voicemail
rm -rf "$DEST/etc/asterisk"       # configuration is not packaged; install.sh installs configs/asterisk/

MODDIR="$DEST/usr/lib/asterisk/modules"
MISSING=""
for m in $REQUIRED_MODULES; do [ -f "$MODDIR/$m.so" ] || MISSING="$MISSING $m"; done
[ -z "$MISSING" ] || die "required modules were not built:$MISSING  (see: cd $SRC && $MS --list-options)"
echo "  All $(echo $REQUIRED_MODULES | wc -w) required modules were built."

# Full module list check: every module in tools/expected-modules.txt must be built.
# Catches modules that menuselect silently drops because a build dependency is missing.
EXPECTED="$HERE/tools/expected-modules.txt"
if [ -f "$EXPECTED" ] && [ -z "${SKIP_MODULE_LIST_CHECK:-}" ]; then
  MISSING=""
  while read -r m; do
    case "$m" in ""|\#*) continue ;; esac
    [ -f "$MODDIR/$m.so" ] || MISSING="$MISSING $m"
  done < "$EXPECTED"
  [ -z "$MISSING" ] || die "modules listed in tools/expected-modules.txt were not built:$MISSING"
  echo "  All modules in tools/expected-modules.txt were built ($(grep -cv '^\(#\|$\)' "$EXPECTED"))."
fi

# Digium codecs
DOCDIR="$DEST/var/lib/asterisk/documentation/thirdparty"
mkdir -p "$DOCDIR"
for m in $EXTERNAL_CODECS; do
  tb="$(compgen -G "$CACHE/$m-*-x86_64.tar.gz" | sed -n 1p || true)"
  [ -n "$tb" ] || { echo "  WARNING: $m is not in the cache and will not be packaged"; continue; }
  t="$(mktemp -d)"; tar -xzf "$tb" -C "$t"; d="$(find "$t" -mindepth 1 -maxdepth 1 -type d | sed -n 1p)"
  install -m 755 "$d"/*.so "$MODDIR"/
  for x in "$d"/*.xml; do [ "$(basename "$x")" = manifest.xml ] || install -m 644 "$x" "$DOCDIR"/; done
  echo "  $(basename "$tb") -> $(cd "$d" && ls *.so | tr '\n' ' ')"
  rm -rf "$t"
done

# asterisk-g72x codecs (installed under their plain module name, e.g. codec_g723.so)
for m in ${G72X_CODECS:-}; do
  f="$CACHE/$m-ast${ASTERISK_VERSION%%.*}0-gcc4-glibc-$G72X_CPU.so"
  [ -s "$f" ] || { echo "  WARNING: $(basename "$f") is not in the cache and will not be packaged"; continue; }
  install -m 755 "$f" "$MODDIR/$m.so"
  echo "  $(basename "$f") -> $m.so"
done

# systemd unit and alembic schema scripts
install -D -m 644 contrib/systemd/asterisk.service "$DEST/usr/lib/systemd/system/asterisk.service"
# /run is a tmpfs: let systemd create /run/asterisk (owned by User=asterisk) on every start,
# otherwise the control socket cannot be created after a reboot.
sed -i 's|^#RuntimeDirectory=asterisk|RuntimeDirectory=asterisk|' "$DEST/usr/lib/systemd/system/asterisk.service"
grep -q '^RuntimeDirectory=asterisk' "$DEST/usr/lib/systemd/system/asterisk.service" \
  || die "could not enable RuntimeDirectory in asterisk.service"
# The unit is Type=notify: Asterisk must be linked against libsystemd to send READY=1
objdump -p "$DEST/usr/sbin/asterisk" | grep -E 'NEEDED +libsystemd\.so' >/dev/null \
  || die "asterisk is not linked against libsystemd; the Type=notify service would never become ready"
echo "  asterisk is linked against libsystemd (sd_notify), RuntimeDirectory enabled."
mkdir -p "$DEST/usr/share/asterisk"
cp -a contrib/ast-db-manage "$DEST/usr/share/asterisk/ast-db-manage"
rm -f "$DEST/usr/share/asterisk/ast-db-manage/config.ini"

# Drop debug info to save space; the symbol table stays so backtraces remain readable
while IFS= read -r -d '' f; do
  if is_elf "$f"; then strip --strip-debug "$f" 2>/dev/null || true; fi
done < <(find "$DEST" -type f \( -name '*.so*' -o -perm -u+x \) -print0)

# Build information
mkdir -p "$DEST/usr/share/doc/$PKG"
{
  echo "Asterisk:          $ASTERISK_VERSION"
  echo "pjproject:         $PJPROJECT_VERSION (bundled)"
  echo "Build date:        $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "Build system:      $PRETTY_NAME"
  echo "Sound packages:    $SOUND_PACKAGES"
  echo "Prebuilt codecs:   $EXTERNAL_CODECS ${G72X_CODECS:-} (asterisk-g72x $G72X_CPU)"
  echo "Required modules:  $REQUIRED_MODULES"
  echo; echo "Modules in this package:"; ls "$MODDIR" | sed 's/^/  /'
} > "$DEST/usr/share/doc/$PKG/BUILD-INFO"

# ---------------------------------------------------------------------
log "7/7 Building the .deb"
# Derive runtime dependencies from the binaries
META="$W/meta"; rm -rf "$META"; mkdir -p "$META/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: amd64\n' "$PKG" "$PKG" > "$META/debian/control"
ELFS=()
while IFS= read -r -d '' f; do
  if is_elf "$f"; then ELFS+=("$f"); fi
done < <(find "$DEST" -type f \( -name '*.so*' -o -perm -u+x \) -print0)
DEPENDS="$(cd "$META" && dpkg-shlibdeps -O --ignore-missing-info -l"$DEST/usr/lib" -S"$DEST" "${ELFS[@]}" 2>/dev/null \
           | sed -n 's/^shlibs:Depends=//p')"
[ -n "$DEPENDS" ] || die "dpkg-shlibdeps produced no dependencies"

mkdir -p "$DEST/DEBIAN"
cat > "$DEST/DEBIAN/control" <<EOF
Package: $PKG
Version: $DEBVER
Architecture: amd64
Maintainer: Asterisk offline package <root@localhost>
Section: comm
Priority: optional
Installed-Size: $(du -sk --exclude=DEBIAN "$DEST" | cut -f1)
Depends: $DEPENDS
Conflicts: asterisk, asterisk-modules, asterisk-config, asterisk-core-sounds-en
Replaces: asterisk, asterisk-modules
Description: Asterisk $ASTERISK_VERSION PBX built from source for offline installation
 Includes bundled pjproject $PJPROJECT_VERSION, sound packages, codec_opus,
 codec_g723 (asterisk-g72x), the systemd unit and the alembic schema scripts.
 /etc/asterisk is not included.
EOF
echo "activate-noawait ldconfig" > "$DEST/DEBIAN/triggers"

DEB="$OUT/${PKG}_${DEBVER}_amd64.deb"
dpkg-deb --build --root-owner-group -Zxz "$DEST" "$DEB"
echo; dpkg-deb -f "$DEB" Package Version Installed-Size
ls -la "$DEB"
