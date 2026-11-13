#!/bin/bash
# =====================================================================
#  uninstall.sh - removes what install.sh added, OFFLINE
#
#  install.sh records the state of the system before the first installation
#  in /var/lib/asterisk-offline (and copies this script there). Only what the
#  installer added is removed:
#    - packages that were not installed before (dependencies included);
#      packages that other software still needs are kept
#    - the Asterisk configuration, data, logs, service drop-in, alembic venv
#    - the Asterisk database and the MySQL accounts the installer created;
#      the MySQL server itself only if the installer installed it and it
#      holds no other databases
#    - /etc/odbc.ini is restored, users/groups the installer created are deleted
#  A backup (configuration, Asterisk data, database dump) is written to
#  /var/backups before anything is removed.
#
#  Usage:  sudo bash uninstall.sh [options]
#    -y, --yes       do not ask for confirmation
#    -n, --dry-run   show what would be removed, change nothing
#    --keep-mysql    leave MySQL (server, databases, accounts, settings) untouched
#    --no-backup     skip the backup (the database is then lost)
#  Log:    /var/log/asterisk-offline-uninstall.log
# =====================================================================
set -euo pipefail

YES=0; DRY=0; KEEP_MYSQL=0; BACKUP=1
for a in "$@"; do
  case "$a" in
    -y|--yes)     YES=1 ;;
    -n|--dry-run) DRY=1 ;;
    --keep-mysql) KEEP_MYSQL=1 ;;
    --no-backup)  BACKUP=0 ;;
    -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (see --help)"; exit 2 ;;
  esac
done

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo bash uninstall.sh)."; exit 1; }

LOG=/var/log/asterisk-offline-uninstall.log
[ "$DRY" = 1 ] || exec > >(tee -a "$LOG") 2>&1
log()  { echo -e "\n---- $*"; }
warn() { echo "  WARNING: $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }
sql()  { echo "  + mysql: $1"; [ "$DRY" = 1 ] || mysql -e "$1"; }
sql_str() { printf "%s" "$1" | sed "s/'/''/g"; }

export DEBIAN_FRONTEND=noninteractive
HAS_SYSTEMD=0; [ -d /run/systemd/system ] && HAS_SYSTEMD=1
STATE=/var/lib/asterisk-offline
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------
# What was installed
# ---------------------------------------------------------------------
DB_NAME=asterisk; DB_USER=asterisk
if [ -f "$STATE/state.env" ]; then
  LEGACY=0
  # shellcheck disable=SC1091
  . "$STATE/state.env"
else
  # Installed by a bundle older than this script: nothing was recorded, so
  # only what certainly belongs to this installer is removed.
  LEGACY=1
  [ -f "$HERE/config.env" ] && { DB_NAME="$(. "$HERE/config.env"; echo "$DB_NAME")"; DB_USER="$(. "$HERE/config.env"; echo "$DB_USER")"; }
fi
st() { local v="${!1:-}"; if [ -n "$v" ]; then echo "$v"; else echo "${2-0}"; fi; }   # recorded value or default

installed() { [ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | cut -c1-2)" = ii ]; }
installed asterisk-offline || [ "$LEGACY" = 0 ] || die "asterisk-offline is not installed and no installation record exists in $STATE. Nothing to uninstall."

MYSQL_RUNNING=0
mysql_ok() { mysql -N -e 'SELECT 1' >/dev/null 2>&1; }
if command -v mysql >/dev/null 2>&1; then
  if ! mysql_ok && installed mysql-server-core-8.0; then
    [ "$DRY" = 1 ] || { if [ "$HAS_SYSTEMD" = 1 ]; then systemctl start mysql || true; else service mysql start || true; fi; }
    for i in $(seq 1 30); do mysql_ok && break; [ "$DRY" = 1 ] && break; sleep 1; done
  fi
  mysql_ok && MYSQL_RUNNING=1
fi

# installed packages with their Provides and dependencies: "status|name|provides|deps"
pkg_db() { dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${Provides}|${Pre-Depends}, ${Depends}\n' 2>/dev/null | awk -F'|' '$1 ~ /^ii/'; }
# closure <pkg>... : the given installed packages and everything they depend on
closure() {
  pkg_db | awk -F'|' -v seeds="$*" '
    function clean(s) { sub(/\(.*$/, "", s); gsub(/[ \t]/, "", s); sub(/:.*$/, "", s); return s }
    { inst[$2] = 1; dep[$2] = $4
      n = split($3, pv, ","); for (i = 1; i <= n; i++) { p = clean(pv[i]); if (p != "") prov[p] = prov[p] " " $2 } }
    END {
      n = split(seeds, q, " "); head = 1; tail = n; for (i = 1; i <= n; i++) seen[q[i]] = 1
      while (head <= tail) {
        p = q[head++]; if (!(p in inst)) continue; print p
        m = split(dep[p], d, /[,|]/)
        for (j = 1; j <= m; j++) {
          x = clean(d[j]); if (x == "") continue
          c = (x in inst) ? x : ""; if (x in prov) c = c prov[x]
          k = split(c, cs, " "); for (l = 1; l <= k; l++) if (!(cs[l] in seen)) { seen[cs[l]] = 1; q[++tail] = cs[l] }
        }
      }
    }' | sort -u
}
minus() { comm -23 <(printf '%s\n' $1 | sort -u) <(printf '%s\n' $2 | sort -u) | xargs; }

# ---- MySQL mode -------------------------------------------------------
NEW_PKGS=""
[ "$LEGACY" = 0 ] && NEW_PKGS="$(xargs < "$STATE/new-packages.txt")"
MYSQL_NEW=0; [[ " $NEW_PKGS " == *" mysql-server-core-8.0 "* ]] && MYSQL_NEW=1
OTHER_DBS=""
if [ "$MYSQL_RUNNING" = 1 ]; then
  OTHER_DBS="$(mysql -N -e 'SHOW DATABASES' | grep -vxF -e information_schema -e mysql -e performance_schema -e sys -e "$DB_NAME" | xargs || true)"
fi
if [ "$KEEP_MYSQL" = 1 ]; then
  MYSQL_MODE=keep        # nothing in MySQL is touched
elif [ "$MYSQL_NEW" = 1 ] && [ -z "$OTHER_DBS" ]; then
  MYSQL_MODE=remove      # the installer installed MySQL and only the Asterisk database is in it
else
  MYSQL_MODE=clean       # the server stays; the Asterisk database and accounts are removed
fi
if [ "$MYSQL_MODE" = remove ] && [ "$MYSQL_RUNNING" = 0 ] && [ -d /var/lib/mysql ] && [ "$BACKUP" = 1 ]; then
  die "MySQL is not running, so the database cannot be checked and backed up. Start it (systemctl start mysql) or use --keep-mysql or --no-backup."
fi

# ---- Packages ---------------------------------------------------------
if [ "$LEGACY" = 1 ]; then
  PURGE="asterisk-offline"
else
  PURGE=""
  for p in $NEW_PKGS; do installed "$p" && PURGE="$PURGE $p"; done
  installed asterisk-offline && [[ " $PURGE " != *" asterisk-offline "* ]] && PURGE="$PURGE asterisk-offline"
fi
KEPT=""
if [ "$MYSQL_MODE" != remove ]; then
  # MySQL stays: keep the server and everything it needs
  K="$(closure mysql-server mysql-server-8.0 mysql-server-core-8.0 | xargs)"
  KEPT="$(comm -12 <(printf '%s\n' $PURGE | sort -u) <(printf '%s\n' $K | sort -u) | xargs)"
  PURGE="$(minus "$PURGE" "$K")"
fi
# Never remove a package that is not ours: if purging the list would take other
# installed packages with it, keep what those packages depend on and try again.
for i in $(seq 1 15); do
  [ -n "$PURGE" ] || break
  SIM="$(apt-get -s -o APT::Get::AutomaticRemove=false purge $PURGE 2>&1)" || die "apt-get cannot plan the package removal; nothing was changed:\n$SIM"
  WOULD="$(echo "$SIM" | awk '/^Purg /{print $2}' | sed 's/:.*//' | sort -u | xargs)"
  EXTRA="$(minus "$WOULD" "$PURGE")"
  [ -z "$EXTRA" ] && break
  K="$(closure $EXTRA | xargs)"
  KEPT="$KEPT $(comm -12 <(printf '%s\n' $PURGE | sort -u) <(printf '%s\n' $K | sort -u) | xargs)"
  PURGE="$(minus "$PURGE" "$K")"
  [[ " $K " == *" asterisk-offline "* ]] && die "installed packages depend on asterisk-offline ($EXTRA); remove them first."
  [ "$i" = 15 ] && die "could not find a package set that leaves other software intact; nothing was changed."
done
KEPT="$(printf '%s\n' $KEPT | sort -u | xargs)"

# ---- Plan -------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
BK="/var/backups/asterisk-offline-uninstall-$TS"
echo "Asterisk offline uninstaller"
[ "$LEGACY" = 1 ] && echo "  No installation record found (installed by an older bundle): only Asterisk itself is removed."
echo
echo "Will be removed:"
echo "  - Asterisk service, /etc/asterisk, /var/{lib,spool,log,run}/asterisk, /usr/lib/asterisk, /usr/share/asterisk"
echo "  - /opt/asterisk-alembic, /opt/asterisk-offline, /etc/systemd/system/asterisk.service.d, $STATE"
echo "  - packages ($(echo $PURGE | wc -w)): $PURGE"
case "$MYSQL_MODE" in
  keep)   echo "  - MySQL: nothing (--keep-mysql)" ;;
  remove) echo "  - MySQL: server, all its data (/var/lib/mysql) and settings; it was installed by install.sh and holds only '$DB_NAME'" ;;
  clean)  echo "  - MySQL: database '$DB_NAME' and the accounts install.sh created; the server stays"
          [ -n "$OTHER_DBS" ] && echo "           (other databases exist: $OTHER_DBS)" ;;
esac
echo
echo "Kept:"
[ -n "$KEPT" ] && echo "  - packages still needed by other software or by MySQL: $KEPT"
[ "$LEGACY" = 1 ] && echo "  - other packages, the asterisk user, 'root'@'%' and the MySQL bind-address (not recorded by the old installer)"
[ -n "$(st ETC_ASTERISK_PREVIOUS '')" ] && echo "  - $(st ETC_ASTERISK_PREVIOUS '') (configuration that existed before install.sh)"
[ -s "$STATE/removed-packages.txt" ] && echo "  - packages removed by install.sh are not reinstalled (offline): $(xargs < "$STATE/removed-packages.txt")"
[ -n "$KEPT$(st ETC_ASTERISK_PREVIOUS '')" ] || [ "$LEGACY" = 1 ] || [ -s "$STATE/removed-packages.txt" ] || echo "  - nothing that install.sh added"
if [ "$BACKUP" = 1 ]; then echo "Backup first: $BK"; else echo "No backup (--no-backup)."; fi

if [ "$DRY" = 1 ]; then echo; echo "Dry run: commands below are shown, not executed."
elif [ "$YES" = 0 ]; then
  [ -t 0 ] || die "not running on a terminal; pass --yes to confirm."
  read -r -p "Type 'yes' to continue: " ans; [ "$ans" = yes ] || { echo "Aborted."; exit 1; }
fi

# ---------------------------------------------------------------------
log "1/7 Stopping Asterisk"
if [ "$HAS_SYSTEMD" = 1 ] && systemctl cat asterisk.service >/dev/null 2>&1; then
  run systemctl disable --now asterisk.service || true
elif command -v asterisk >/dev/null 2>&1 && asterisk -rx 'core show version' >/dev/null 2>&1; then
  run asterisk -rx 'core stop now' || true
fi
if [ "$DRY" = 0 ]; then
  for i in $(seq 1 20); do
    pid="$(cat /var/run/asterisk/asterisk.pid 2>/dev/null || true)"
    { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || break; sleep 1
  done
  [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null && die "Asterisk (pid $pid) did not stop."
fi

# ---------------------------------------------------------------------
log "2/7 Backup"
if [ "$BACKUP" = 1 ]; then
  run mkdir -p "$BK"; run chmod 700 "$BK"
  [ -d /etc/asterisk ] && run tar -C / -czf "$BK/etc-asterisk.tar.gz" etc/asterisk
  DATA=""; for d in var/lib/asterisk var/spool/asterisk var/log/asterisk; do [ -d "/$d" ] && DATA="$DATA $d"; done
  [ -n "$DATA" ] && run tar -C / -czf "$BK/asterisk-data.tar.gz" --exclude=var/lib/asterisk/sounds --exclude=var/lib/asterisk/moh \
      --exclude=var/lib/asterisk/documentation --exclude=var/lib/asterisk/rest-api --exclude=var/lib/asterisk/static-http $DATA
  for f in /etc/odbc.ini /etc/mysql/mysql.conf.d/mysqld.cnf; do [ -f "$f" ] && run cp -p "$f" "$BK/"; done
  [ -d "$STATE" ] && run cp -a "$STATE" "$BK/install-record"
  if [ "$MYSQL_MODE" != keep ] && [ "$MYSQL_RUNNING" = 1 ] && [ -n "$(mysql -N -e "SHOW DATABASES LIKE '$(sql_str "$DB_NAME")'")" ]; then
    echo "  + mysqldump $DB_NAME > $BK/$DB_NAME.sql.gz"
    if [ "$DRY" = 0 ]; then
      mysqldump --single-transaction --routines --triggers --events --databases "$DB_NAME" | gzip > "$BK/$DB_NAME.sql.gz" \
        || die "database backup failed; nothing was removed."
    fi
  fi
  [ "$DRY" = 1 ] || ls -la "$BK"
else
  echo "  skipped"
fi

# ---------------------------------------------------------------------
log "3/7 MySQL ($MYSQL_MODE)"
if [ "$MYSQL_MODE" = clean ]; then
  if [ "$MYSQL_RUNNING" = 1 ]; then
    U="$(sql_str "$DB_USER")"
    if [ "$(st DB_PREEXISTED)" = 1 ]; then echo "  database '$DB_NAME' existed before install.sh: kept"
    else sql "DROP DATABASE IF EXISTS \`$DB_NAME\`"; fi
    [ "$(st MYSQL_LOCAL_USER_PREEXISTED)" = 1 ]  || sql "DROP USER IF EXISTS '$U'@'localhost'"
    [ "$(st MYSQL_REMOTE_USER_PREEXISTED)" = 1 ] || sql "DROP USER IF EXISTS '$U'@'%'"
    [ "$LEGACY" = 1 ] || [ "$(st MYSQL_ROOT_REMOTE_PREEXISTED)" = 1 ] || sql "DROP USER IF EXISTS 'root'@'%'"
    if [ -f "$STATE/orig/mysqld.cnf" ]; then
      run cp -p "$STATE/orig/mysqld.cnf" /etc/mysql/mysql.conf.d/mysqld.cnf
      if [ "$HAS_SYSTEMD" = 1 ]; then run systemctl restart mysql; else run service mysql restart; fi
    fi
  else
    warn "MySQL is not running: database '$DB_NAME' and its accounts were not removed."
  fi
elif [ "$MYSQL_MODE" = remove ]; then
  # stopped here: without an init system the package scripts cannot stop it
  if [ "$HAS_SYSTEMD" = 1 ]; then run systemctl disable --now mysql.service || true
  else run service mysql stop || true; fi
  if [ "$DRY" = 0 ]; then
    for i in $(seq 1 30); do
      pid="$(cat /run/mysqld/mysqld.pid 2>/dev/null || true)"
      { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || break; sleep 1
    done
    [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null && die "MySQL (pid $pid) did not stop."
  fi
  echo "  the server is removed with the packages below"
else
  echo "  untouched"
fi

# ---------------------------------------------------------------------
log "4/7 Files"
if [ -d /etc/systemd/system/asterisk.service.d ]; then
  run rm -f /etc/systemd/system/asterisk.service.d/10-mysql.conf
  run rmdir --ignore-fail-on-non-empty /etc/systemd/system/asterisk.service.d
fi
for d in /etc/asterisk /opt/asterisk-alembic /opt/asterisk-offline; do [ -e "$d" ] && run rm -rf "$d"; done
# backups of this installer's own configuration (re-runs); the pre-existing one stays
if [ -f "$STATE/etc-backups.txt" ]; then
  while read -r b; do
    [ -n "$b" ] && [ "$b" != "$(st ETC_ASTERISK_PREVIOUS '')" ] && [ -d "$b" ] && run rm -rf "$b"
  done < "$STATE/etc-backups.txt"
fi

# ---------------------------------------------------------------------
log "5/7 Packages"
if [ -n "$PURGE" ]; then
  run apt-get -y -o APT::Get::AutomaticRemove=false purge $PURGE
else
  echo "  none"
fi
[ "$HAS_SYSTEMD" = 1 ] && { run systemctl daemon-reload; run systemctl reset-failed asterisk.service 2>/dev/null || true; }

# leftovers that dpkg does not remove (runtime data, logs, MySQL data)
if ! installed asterisk-offline || [ "$DRY" = 1 ]; then
  for d in /var/lib/asterisk /var/spool/asterisk /var/log/asterisk /var/run/asterisk /usr/lib/asterisk /usr/share/asterisk; do
    [ -e "$d" ] && run rm -rf "$d"
  done
fi
if [ "$MYSQL_MODE" = remove ]; then
  if [ "$DRY" = 1 ] || ! dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'mysql-server*' 2>/dev/null | grep '^ii' >/dev/null; then
    for d in /var/lib/mysql /var/lib/mysql-files /var/lib/mysql-keyring /var/lib/mysql-upgrade /var/log/mysql /run/mysqld; do
      [ -e "$d" ] && run rm -rf "$d"
    done
    if [ "$DRY" = 1 ] || ! dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'mysql-common' 'mariadb-common' 2>/dev/null | grep '^ii' >/dev/null; then
      [ -e /etc/mysql ] && run rm -rf /etc/mysql
    fi
  else
    warn "a MySQL server package is still installed; /var/lib/mysql was kept."
  fi
fi

# files that purging packages such as tzdata deletes although they existed before
for f in localtime timezone; do
  { [ -e "$STATE/orig/$f" ] || [ -L "$STATE/orig/$f" ]; } && [ ! -e "/etc/$f" ] && [ ! -L "/etc/$f" ] && run cp -P "$STATE/orig/$f" "/etc/$f"
done

# ---------------------------------------------------------------------
log "6/7 ODBC"
if [ "$LEGACY" = 1 ]; then
  command -v odbcinst >/dev/null 2>&1 && [ -f /etc/odbc.ini ] && run odbcinst -u -s -l -n asterisk || true
elif [ -f "$STATE/orig/odbc.ini" ]; then
  run cp -p "$STATE/orig/odbc.ini" /etc/odbc.ini
elif [ -f /etc/odbc.ini ] && [ "$(st ODBC_INI_PREEXISTED)" = 0 ]; then
  run rm -f /etc/odbc.ini
fi
if [ "$LEGACY" = 0 ] && [ "$(st ODBC_DRIVER_PREEXISTED)" = 0 ] && command -v odbcinst >/dev/null 2>&1 \
   && odbcinst -q -d -n 'MariaDB Unicode' >/dev/null 2>&1; then
  run odbcinst -u -d -n 'MariaDB Unicode' || true
fi

# ---------------------------------------------------------------------
log "7/7 Users and installation record"
del_user()  { getent passwd "$1" >/dev/null && run userdel "$1" || true; }
del_group() { getent group "$1" >/dev/null && run groupdel "$1" || true; }
if [ "$LEGACY" = 0 ]; then
  [ "$(st ASTERISK_USER_PREEXISTED)" = 1 ]  || del_user asterisk
  [ "$(st ASTERISK_GROUP_PREEXISTED)" = 1 ] || del_group asterisk
  if [ "$MYSQL_MODE" = remove ]; then
    [ "$(st MYSQL_USER_PREEXISTED)" = 1 ]  || del_user mysql
    [ "$(st MYSQL_GROUP_PREEXISTED)" = 1 ] || del_group mysql
  fi
fi
[ -d "$STATE" ] && run rm -rf "$STATE"

echo
if [ "$DRY" = 1 ]; then echo "Dry run finished; nothing was changed."
else
  echo "Asterisk offline installation removed."
  [ "$BACKUP" = 1 ] && echo "Backup: $BK"
  echo "Log: $LOG"
fi
