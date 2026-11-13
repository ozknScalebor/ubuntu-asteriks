#!/bin/bash
# =====================================================================
#  install.sh - Asterisk LTS + MySQL 8.0 + ODBC realtime, OFFLINE
#  Target: Ubuntu 24.04 (noble) without internet access.
#  bundle/ must have been produced beforehand by collect-packages.sh
#  (or downloaded from the GitHub release).
#
#  Nothing is compiled here: Asterisk is installed from the prebuilt
#  asterisk-offline .deb in bundle/debs.
#
#  Usage:  sudo bash install.sh
#  Log:    /var/log/asterisk-offline-install.log
#
#  What the system looked like before the first installation (packages,
#  users, MySQL accounts, odbc.ini, ...) is recorded in /var/lib/asterisk-offline
#  so that uninstall.sh removes only what this installer added.
# =====================================================================
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo bash install.sh)."; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
. "$HERE/config.env"

LOG=/var/log/asterisk-offline-install.log
exec > >(tee -a "$LOG") 2>&1
log() { echo -e "\n-----------------------------------------------------------\n---- $*\n-----------------------------------------------------------"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for v in DB_PASS ARI_PASS $( [ "$ROOT_REMOTE" = yes ] && echo ROOT_REMOTE_PASS ) $( [ "$DB_REMOTE" = yes ] && echo DB_REMOTE_PASS ); do
  case "${!v}" in ""|CHANGE_ME) die "$v is not set in config.env.";; esac
done

case "$MYSQL_REMOTE_AUTH" in mysql_native_password|caching_sha2_password) ;;
  *) die "MYSQL_REMOTE_AUTH must be mysql_native_password or caching_sha2_password.";; esac

[ -f "$HERE/bundle/debs/Packages" ] || die "bundle/ not found. Run collect-packages.sh on an internet-connected machine first."
. /etc/os-release
[ "${VERSION_CODENAME:-}" = "$UBUNTU_CODENAME" ] || die "This bundle targets $UBUNTU_CODENAME; this system is ${VERSION_CODENAME:-?}."

export DEBIAN_FRONTEND=noninteractive
HAS_SYSTEMD=0; [ -d /run/systemd/system ] && HAS_SYSTEMD=1

ast_running() { # true while this system's Asterisk answers or its pid is alive
  asterisk -rx 'core show version' >/dev/null 2>&1 && return 0
  local pid; pid="$(cat /var/run/asterisk/asterisk.pid 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

svc() { # svc <start|restart|enable> <name>   (falls back to direct start without systemd)
  if [ "$HAS_SYSTEMD" = 1 ]; then systemctl "$1" "$2"; return; fi
  [ "$1" = enable ] && return 0
  case "$2" in
    mysql)    service mysql "$1" ;;
    asterisk) if [ "$1" = restart ]; then
                asterisk -rx 'core stop now' >/dev/null 2>&1 || true
                # wait until the old process is gone before starting a new one
                # (checked via its control socket and pid file, not by process name)
                for i in $(seq 1 20); do ast_running || break; sleep 1; done
                ast_running && die "could not stop the running asterisk process"
              fi
              /usr/sbin/asterisk -U asterisk -G asterisk ;;
  esac
}

# Placeholder substitution: @@DB_PASS@@ etc.
sed_esc() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }
subst() { # subst <source> <target>
  sed -e "s|@@DB_NAME@@|$(sed_esc "$DB_NAME")|g"   -e "s|@@DB_USER@@|$(sed_esc "$DB_USER")|g" \
      -e "s|@@DB_PASS@@|$(sed_esc "$DB_PASS")|g"   -e "s|@@ARI_USER@@|$(sed_esc "$ARI_USER")|g" \
      -e "s|@@ARI_PASS@@|$(sed_esc "$ARI_PASS")|g" "$1" > "$2"
}
sql_str() { printf "%s" "$1" | sed "s/'/''/g"; }   # escape single quotes for SQL

mysql_up() {
  for i in $(seq 1 30); do mysqladmin ping >/dev/null 2>&1 && break; sleep 1; done
  # dpkg postinst may leave the socket directory at 700 (persists without systemd);
  # the asterisk user must be able to reach the socket
  chmod 755 /var/run/mysqld
}

# ---------------------------------------------------------------------
# Installation record for uninstall.sh. Every value is recorded only the first
# time it is reached, so re-running install.sh keeps the original state.
STATE=/var/lib/asterisk-offline
mkdir -p "$STATE/orig"; chmod 700 "$STATE"
touch "$STATE/state.env" "$STATE/new-packages.txt" "$STATE/etc-backups.txt"
state_has() { grep "^$1=" "$STATE/state.env" >/dev/null; }
state_set() { state_has "$1" || printf '%s=%q\n' "$1" "$2" >> "$STATE/state.env"; }
yes_no() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }
installed_pkgs() { dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="ii"{print $2}' | sort -u; }
state_set DB_NAME "$DB_NAME"
state_set DB_USER "$DB_USER"
state_set ASTERISK_USER_PREEXISTED "$(yes_no getent passwd asterisk)"
state_set ASTERISK_GROUP_PREEXISTED "$(yes_no getent group asterisk)"
state_set MYSQL_USER_PREEXISTED "$(yes_no getent passwd mysql)"
state_set MYSQL_GROUP_PREEXISTED "$(yes_no getent group mysql)"
state_set ODBC_DRIVER_PREEXISTED "$(yes_no odbcinst -q -d -n 'MariaDB Unicode')"
if ! state_has ODBC_INI_PREEXISTED; then   # overwritten in step 7
  if [ -e /etc/odbc.ini ]; then cp -p /etc/odbc.ini "$STATE/orig/odbc.ini"; state_set ODBC_INI_PREEXISTED 1
  else state_set ODBC_INI_PREEXISTED 0; fi
fi
# purging tzdata (if this installer adds it) deletes these
for f in /etc/localtime /etc/timezone; do
  { [ -e "$f" ] || [ -L "$f" ]; } && [ ! -e "$STATE/orig/$(basename "$f")" ] && [ ! -L "$STATE/orig/$(basename "$f")" ] && cp -P "$f" "$STATE/orig/"
done
cp "$HERE/uninstall.sh" "$STATE/uninstall.sh"; chmod 700 "$STATE/uninstall.sh"
# kept until step 1 has finished, so an interrupted run does not lose track of its packages
[ -f "$STATE/.pkgs-before" ] || installed_pkgs > "$STATE/.pkgs-before"

# ---------------------------------------------------------------------
log "1/8 Installing packages from the local repository (no internet)"
STAGE=/opt/asterisk-offline
mkdir -p "$STAGE"
[ "$(cd "$HERE" && pwd -P)" = "$STAGE" ] || { rm -rf "$STAGE/bundle"; cp -a "$HERE/bundle" "$STAGE/"; }
chmod -R a+rX "$STAGE"

APT_LIST="$(mktemp)"
echo "deb [trusted=yes] file:$STAGE/bundle/debs ./" > "$APT_LIST"
APT_OPTS=(-o Dir::Etc::sourcelist="$APT_LIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
apt-get "${APT_OPTS[@]}" update
apt-get "${APT_OPTS[@]}" -y --no-install-recommends install $(cat "$STAGE/bundle/debs/PACKAGE-LIST.txt")
rm -f "$APT_LIST"
# packages added by this run (dependencies included) / removed by it (conflicts)
installed_pkgs > "$STATE/.pkgs-after"
{ cat "$STATE/new-packages.txt"; comm -13 "$STATE/.pkgs-before" "$STATE/.pkgs-after"; } | sort -u > "$STATE/.new"
mv "$STATE/.new" "$STATE/new-packages.txt"
comm -23 "$STATE/.pkgs-before" "$STATE/.pkgs-after" >> "$STATE/removed-packages.txt"
rm -f "$STATE/.pkgs-before" "$STATE/.pkgs-after"
dpkg-query -W -f='  ${Package} ${Version}\n' asterisk-offline
echo "  $(wc -l < "$STATE/new-packages.txt") packages were added by this installer."

# ---------------------------------------------------------------------
log "2/8 asterisk user"
getent group asterisk >/dev/null || groupadd -r asterisk
id asterisk >/dev/null 2>&1 || useradd -r -d /var/lib/asterisk -g asterisk -s /usr/sbin/nologin asterisk
usermod -aG audio,dialout asterisk

# ---------------------------------------------------------------------
log "3/8 Checking required modules"
MISSING=""
for m in $REQUIRED_MODULES; do [ -f "/usr/lib/asterisk/modules/$m.so" ] || MISSING="$MISSING $m"; done
[ -z "$MISSING" ] || die "required modules are missing from the asterisk-offline package:$MISSING"
echo "  All $(echo $REQUIRED_MODULES | wc -w) required modules are present."

# ---------------------------------------------------------------------
log "4/8 Configuration: /etc/asterisk <- configs/asterisk/ (complete set)"
# A previous installation's /etc/asterisk is kept as a backup.
BK=""
if [ -d /etc/asterisk ] && [ -n "$(ls -A /etc/asterisk 2>/dev/null)" ]; then
  BK="/etc/asterisk.bak-$(date +%Y%m%d-%H%M%S)"
  mv /etc/asterisk "$BK"; echo "  previous /etc/asterisk backed up to $BK"
fi
# The first backup is the configuration that existed before this installer
# (kept by uninstall.sh); later ones are backups of this installer's own files.
state_set ETC_ASTERISK_PREVIOUS "$BK"
[ -z "$BK" ] || echo "$BK" >> "$STATE/etc-backups.txt"
mkdir -p /etc/asterisk
for f in "$HERE"/configs/asterisk/*; do subst "$f" "/etc/asterisk/$(basename "$f")"; done
sed -i '/^;runuser/s/^;//;/^;rungroup/s/^;//' /etc/asterisk/asterisk.conf
echo "  $(ls /etc/asterisk | wc -l) files installed"

# ---------------------------------------------------------------------
log "5/8 File permissions"
mkdir -p /var/run/asterisk
chown -R asterisk:asterisk /etc/asterisk /var/{lib,log,spool,run}/asterisk
chmod -R u=rwX,g=rX,o= /etc/asterisk /var/{lib,log,spool}/asterisk

# ---------------------------------------------------------------------
log "6/8 MySQL"
svc enable mysql; svc restart mysql; mysql_up

mysql_has_user() { [ "$(mysql -N -e "SELECT COUNT(*) FROM mysql.user WHERE user='$(sql_str "$1")' AND host='$2'")" != 0 ]; }
state_set DB_PREEXISTED "$(yes_no test -n "$(mysql -N -e "SHOW DATABASES LIKE '$(sql_str "$DB_NAME")'")")"
state_set MYSQL_LOCAL_USER_PREEXISTED "$(yes_no mysql_has_user "$DB_USER" localhost)"
state_set MYSQL_REMOTE_USER_PREEXISTED "$(yes_no mysql_has_user "$DB_USER" %)"
state_set MYSQL_ROOT_REMOTE_PREEXISTED "$(yes_no mysql_has_user root %)"

mysql <<SQL
-- What mysql_secure_installation does
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
-- Asterisk database and user
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '$(sql_str "$DB_USER")'@'localhost' IDENTIFIED BY '$(sql_str "$DB_PASS")';
ALTER USER '$(sql_str "$DB_USER")'@'localhost' IDENTIFIED BY '$(sql_str "$DB_PASS")';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '$(sql_str "$DB_USER")'@'localhost';
FLUSH PRIVILEGES;
SQL

if [ "$DB_REMOTE" = "yes" ]; then
  # Applications on other hosts: data access to the Asterisk database only
  mysql <<SQL
CREATE USER IF NOT EXISTS '$(sql_str "$DB_USER")'@'%' IDENTIFIED WITH ${MYSQL_REMOTE_AUTH} BY '$(sql_str "$DB_REMOTE_PASS")';
ALTER USER '$(sql_str "$DB_USER")'@'%' IDENTIFIED WITH ${MYSQL_REMOTE_AUTH} BY '$(sql_str "$DB_REMOTE_PASS")';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`${DB_NAME}\`.* TO '$(sql_str "$DB_USER")'@'%';
FLUSH PRIVILEGES;
SQL
  GRANTS="$(mysql -N -e "SHOW GRANTS FOR '$(sql_str "$DB_USER")'@'%'")"
  echo "$GRANTS" | sed 's/^/  /'
  echo "$GRANTS" | grep -F "GRANT SELECT, INSERT, UPDATE, DELETE ON \`${DB_NAME}\`.*" >/dev/null \
    || die "'$DB_USER'@'%' did not get the expected privileges."
fi

if [ "$ROOT_REMOTE" = "yes" ]; then
  # root@localhost keeps auth_socket, so 'sudo mysql' still works on the server
  mysql <<SQL
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED WITH ${MYSQL_REMOTE_AUTH} BY '$(sql_str "$ROOT_REMOTE_PASS")';
ALTER USER 'root'@'%' IDENTIFIED WITH ${MYSQL_REMOTE_AUTH} BY '$(sql_str "$ROOT_REMOTE_PASS")';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
fi

if [ "$DB_REMOTE" = "yes" ] || [ "$ROOT_REMOTE" = "yes" ]; then
  mysql -t -e "SELECT user, host, plugin FROM mysql.user WHERE host='%'" | sed 's/^/  /'
fi

if [ "$MYSQL_BIND_ALL" = "yes" ]; then
  [ -f "$STATE/orig/mysqld.cnf" ] || cp -p /etc/mysql/mysql.conf.d/mysqld.cnf "$STATE/orig/mysqld.cnf"
  sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
  svc restart mysql; mysql_up
fi

# ---------------------------------------------------------------------
log "7/8 ODBC and database schema (alembic)"
odbcinst -q -d | grep '^\[MariaDB Unicode\]' >/dev/null || \
  printf '[MariaDB Unicode]\nDescription=MariaDB Connector/ODBC(Unicode)\nDriver=libmaodbc.so\nSetup=libmaodbc.so\nUsageCount=1\n' \
  | odbcinst -i -d -r
subst "$HERE/configs/odbc/odbc.ini.in" /etc/odbc.ini
chown root:asterisk /etc/odbc.ini; chmod 640 /etc/odbc.ini

VENV=/opt/asterisk-alembic
python3 -m venv "$VENV"
"$VENV/bin/pip" install --no-index --find-links="$STAGE/bundle/wheels" alembic pymysql

DBM=/usr/share/asterisk/ast-db-manage          # shipped in the asterisk-offline package
URL="$("$VENV/bin/python" - "$DB_USER" "$DB_PASS" "$DB_NAME" <<'PY'
import sys, urllib.parse as u
user, pw, db = sys.argv[1:4]
url = f"mysql+pymysql://{u.quote(user, safe='')}:{u.quote(pw, safe='')}@localhost/{db}?unix_socket=/var/run/mysqld/mysqld.sock"
print(url.replace('%', '%%'))   # escape for configparser interpolation
PY
)"
ALEMBIC_INI="$VENV/config.ini"
sed "s|^sqlalchemy.url = .*|sqlalchemy.url = ${URL}|" "$DBM/config.ini.sample" > "$ALEMBIC_INI"
chmod 600 "$ALEMBIC_INI"
(cd "$DBM" && PYTHONDONTWRITEBYTECODE=1 "$VENV/bin/alembic" -c "$ALEMBIC_INI" upgrade head)

echo "  ODBC check:"
echo "SELECT COUNT(*) AS ps_tables FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name LIKE 'ps\\_%';" \
  | isql -b -v asterisk

# ---------------------------------------------------------------------
log "8/8 Asterisk service and verification"
if [ "$HAS_SYSTEMD" = 1 ]; then
  # Start Asterisk only after the local MySQL is ready (mysql.service is Type=notify).
  # Otherwise res_odbc fails its pre-connect at boot and, with the default
  # negative_connection_cache of 300 s, realtime stays unavailable for 5 minutes.
  mkdir -p /etc/systemd/system/asterisk.service.d
  cat > /etc/systemd/system/asterisk.service.d/10-mysql.conf <<'UNIT'
[Unit]
Wants=mysql.service
After=mysql.service
UNIT
  systemctl daemon-reload
fi
svc enable asterisk
if ! svc restart asterisk; then
  [ "$HAS_SYSTEMD" = 1 ] && { systemctl status asterisk --no-pager -l || true; journalctl -u asterisk -n 50 --no-pager || true; }
  die "asterisk service failed to start"
fi
UP=0
for i in $(seq 1 30); do asterisk -rx 'core waitfullybooted' >/dev/null 2>&1 && { UP=1; break; }; sleep 1; done
# Asterisk opens its control socket before loading modules; if a required module
# fails, waitfullybooted can succeed and the process exits right after.
sleep 2; asterisk -rx 'core show uptime' >/dev/null 2>&1 || UP=0
[ "$UP" = 1 ] || die "Asterisk did not start within 30 s. A preload-require module in modules.conf may have failed to load: /var/log/asterisk/messages.log"
if [ "$HAS_SYSTEMD" = 1 ]; then
  # The unit is Type=notify: active means Asterisk reported READY=1 to systemd
  [ "$(systemctl is-active asterisk)" = active ] || { systemctl status asterisk --no-pager -l || true; die "asterisk.service is not active"; }
  [ "$(systemctl show -p NRestarts --value asterisk)" = 0 ] || die "asterisk.service restarted during startup (see journalctl -u asterisk)"
  systemctl is-enabled asterisk >/dev/null || die "asterisk.service is not enabled at boot"
  echo "  asterisk.service: active, enabled, no restarts"
fi

echo; asterisk -rx 'core show version'
echo; asterisk -rx 'odbc show asterisk'
echo; asterisk -rx 'pjsip show transports'
echo; asterisk -rx 'module show like opus'

echo; echo "  Verification:"
FAIL=""
for m in $REQUIRED_MODULES $EXTERNAL_CODECS ${G72X_CODECS:-}; do
  if asterisk -rx "module show like $m.so" | grep -E "^$m\\.so .*Running" >/dev/null; then
    echo "    [OK]    $m"
  else
    echo "    [FAIL]  $m is not running"; FAIL="$FAIL $m"
  fi
done
# G.723.1 must be usable for transcoding in both directions
if [ -n "${G72X_CODECS:-}" ] && [[ " $G72X_CODECS " == *" codec_g723 "* ]]; then
  # grep without -q: with pipefail, an early grep exit would SIGPIPE asterisk and fail the check
  if asterisk -rx 'core show translation paths g723' | grep -F '(g723@8000)->(slin@8000)' >/dev/null \
     && asterisk -rx 'core show translation paths slin' | grep -F '(slin@8000)->(g723@8000)' >/dev/null; then
    echo "    [OK]    G.723.1 <-> slin translation paths"
  else
    echo "    [FAIL]  no G.723.1 translation path"; FAIL="$FAIL g723-translation"
  fi
fi
ACTIVE="$(asterisk -rx 'odbc show asterisk' | sed -n 's/.*Number of active connections: \([0-9]*\).*/\1/p')"
if [ "${ACTIVE:-0}" -ge 1 ]; then
  echo "    [OK]    ODBC 'asterisk' connection is active"
else
  echo "    [FAIL]  no active ODBC 'asterisk' connection"; FAIL="$FAIL odbc-connection"
fi
[ -z "$FAIL" ] || die "installation verification failed:$FAIL  (log: /var/log/asterisk/messages.log)"

log "Done. Log: $LOG"
echo "To remove everything this installer added: sudo bash $STATE/uninstall.sh"
