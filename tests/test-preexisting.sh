#!/bin/bash
# test-preexisting.sh - run inside the extracted bundle on a fresh Ubuntu 24.04:
# MySQL (with another database), unixODBC and curl are installed before
# install.sh. uninstall.sh must remove only what install.sh added.
set -euo pipefail
step() { echo; echo "=================== $*"; }
export DEBIAN_FRONTEND=noninteractive

step "prepare: software that was there before install.sh"
echo "deb [trusted=yes] file:$PWD/bundle/debs ./" > /tmp/local.list
O=(-o Dir::Etc::sourcelist=/tmp/local.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
apt-get "${O[@]}" update -qq
apt-get "${O[@]}" install -y -qq --no-install-recommends mysql-server unixodbc-common curl >/dev/null
chmod 755 /var/run/mysqld 2>/dev/null || true
if [ -d /run/systemd/system ]; then systemctl start mysql; else service mysql start; fi
for i in $(seq 1 30); do mysqladmin ping >/dev/null 2>&1 && break; sleep 1; done
mysql -e "CREATE DATABASE crm; CREATE TABLE crm.t (id INT); INSERT INTO crm.t VALUES (42);"
printf '[crm]\nDriver=other\n' > /etc/odbc.ini
B=/root/before; mkdir -p $B
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="ii"{print $2}' | sort > $B/packages.txt
md5sum /etc/odbc.ini /etc/mysql/mysql.conf.d/mysqld.cnf > $B/files.md5
mysql -N -e "SELECT user, host FROM mysql.user ORDER BY 1, 2" > $B/mysql-users.txt

step "install"
bash ./install.sh

step "uninstall"
bash ./uninstall.sh --yes

step "checks"
fail=0
check() { if eval "$2"; then echo "OK    $1"; else echo "FAIL  $1"; fail=1; fi; }
check "installed packages are the same as before"   "dpkg-query -W -f='\${db:Status-Abbrev} \${Package}\n' | awk '\$1==\"ii\"{print \$2}' | sort | diff $B/packages.txt -"
check "odbc.ini and mysqld.cnf restored"            "md5sum -c $B/files.md5"
check "MySQL still running"                         "mysqladmin ping >/dev/null 2>&1"
check "other database intact"                       "[ \"\$(mysql -N -e 'SELECT id FROM crm.t')\" = 42 ]"
check "asterisk database removed"                   "[ -z \"\$(mysql -N -e \"SHOW DATABASES LIKE 'asterisk'\")\" ]"
check "MySQL accounts are the same as before"       "mysql -N -e 'SELECT user, host FROM mysql.user ORDER BY 1, 2' | diff $B/mysql-users.txt -"
check "asterisk user removed"                       "! getent passwd asterisk >/dev/null"
check "/etc/asterisk removed"                       "[ ! -e /etc/asterisk ]"
exit $fail
