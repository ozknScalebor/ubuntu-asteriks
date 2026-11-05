# Migration from the Asterisk 18.13 / Ubuntu 20.04 package

This document compares the previous offline package (`asterisk-18.13-with-mysql-offline-installation-ubuntu-2004-desktop`) with this one, item by item. It covers Asterisk modules, configuration files and system packages. Every difference is either listed as intentional, explained by an upstream removal, or was fixed.

## Method

| Side | How the data was obtained |
|---|---|
| Old modules | Ubuntu 20.04 root with the old package's 256 `asterisk-dependencies` packages installed. Asterisk 18.13.0 configured exactly as the old `install.sh` did (`./configure`, default menuselect). `menuselect.makeopts` gives the build result. |
| New modules | `menuselect.makeopts` of the 22.11.0 build, cross-checked against the `.so` files actually present in the `asterisk-offline` package. |
| Old configuration | All 117 files in the old `asterisk-custom-configs/`, compared with the stock 18.13.0 `configs/samples`. |
| New configuration | `configs/asterisk/` (106 files), compared with the stock 22.11.0 samples and checked on a running Asterisk 22. |
| Old packages | All 294 `.deb` files shipped by the old package. |
| New packages | `dpkg-query` on a fresh, minimal Ubuntu 24.04 after an offline `install.sh` run. |

## Asterisk modules

| | Asterisk 18.13 (old) | Asterisk 22.11 (new) |
|---|---|---|
| Modules built | 340 | 345 |
| Utilities installed | astcanary, astdb2sqlite3, astdb2bdb | identical |
| AGI scripts installed | none | identical |
| Compile options | BUILD_NATIVE, OPTIONAL_API | OPTIONAL_API |

`BUILD_NATIVE` is intentionally disabled, so the package runs on any x86-64 CPU and not only on the build machine's CPU.

### Built in 18.13 but not in 22.11

| Module | Reason |
|---|---|
| `res_stir_shaken`, `res_pjsip_stir_shaken` | **Fixed.** In Asterisk 21+ these modules require libjwt. `install_prereq` does not list `libjwt-dev`, so menuselect skipped them silently. `build-asterisk-deb.sh` now installs `libjwt-dev`, and both modules are built and running. |
| `app_ices` | Removed upstream (`1f1a87a97b`, 2021-08-16) |
| `app_image` | Removed upstream (`13963e643b`, 2021-08-16) |
| `app_nbscat` | Removed upstream (`98e0745a14`, 2021-08-16) |
| `app_url` | Removed upstream (`7c642c55b8`, 2021-08-16) |
| `chan_oss` | Removed upstream (`95f3a4a9ad`, 2021-08-16) |
| `chan_alsa` | Removed upstream (`de3ce178ab`, 2022-11-14); was `noload` in the old `modules.conf` |
| `chan_mgcp` | Removed upstream (`89a7d30a97`, 2022-11-15) |
| `chan_skinny` | Removed upstream (`8d652ab4be`, 2022-11-16) |
| `app_osplookup` | Removed upstream (`d0140fc7fe`, 2022-11-18) |
| `res_monitor` | Removed upstream (`6b03d60c7d`, 2022-11-18); use `MixMonitor` |
| `chan_sip` | Removed upstream (`4095a382da`, 2022-11-28); was `noload` in the old `modules.conf` |

None of the removed modules was used by the old configuration. All of their configuration files were unmodified stock samples (see below).

### New in 22.11

`app_broadcast`, `app_if`, `app_signal`, `app_sla`, `app_stasis_broadcast`, `chan_websocket`, `func_export`, `func_uuid`, `res_cdrel_custom`, `res_geolocation`, `res_pjsip_aoc`, `res_pjsip_geolocation`, `res_pjsip_maintenance`, `res_pjsip_rfc3329`, `res_stasis_broadcast`, `res_websocket_client`.

### Guarding against silent drops

`tools/expected-modules.txt` lists all 345 modules. `build-asterisk-deb.sh` fails if any of them is missing from the build. A future Asterisk version or build dependency change therefore cannot drop a module unnoticed. Update the list deliberately when changing `ASTERISK_VERSION`.

Modules that are not built in either version (default-disabled or missing hardware/driver dependencies) are identical between old and new. Examples: `chan_dahdi`, `chan_mobile`, `app_voicemail_imap`, `res_corosync`, `res_config_mysql`, `app_meetme`, `chan_ooh323`, `format_mp3`.

## Configuration files

The old package shipped 117 files. **107 were byte-identical to the stock Asterisk 18.13 samples**; 10 contained customisations.

| | Count | Handling |
|---|---|---|
| Customised in the old package | 10 | Same changes applied to the 22.11 samples (see below); `codecs.conf` additionally gets a `[g723]` section |
| Stock samples, still in 22.11 | 91 | Replaced by the 22.11 stock samples |
| Stock samples, module removed in 22.11 | 16 | Not shipped (table below) |
| New samples in 22.11 | 5 | Shipped as stock: `chan_websocket.conf`, `geolocation.conf`, `res_config_odbc.conf`, `res_http_media_cache.conf`, `websocket_client.conf` |
| **Total in `configs/asterisk/`** | **106** | identical to `make samples` + customisations |

### Old files without a 22.11 counterpart

All 16 were unmodified stock samples in the old package, so no setting is lost.

| File | Module | Removed upstream |
|---|---|---|
| `alsa.conf` | chan_alsa | `de3ce178ab` 2022-11-14 |
| `app_mysql.conf` | app_mysql | `2f510d7a88` 2021-08-16 (also not built in 18.13) |
| `cdr_mysql.conf` | cdr_mysql | `2a0e383e4f` 2021-08-16 (also not built in 18.13) |
| `cdr_syslog.conf` | cdr_syslog | `30d5264409` 2021-08-16 (also not built in 18.13) |
| `mgcp.conf` | chan_mgcp | `89a7d30a97` 2022-11-15 |
| `misdn.conf` | chan_misdn | `1eb2d85c99` 2021-08-16 (also not built in 18.13) |
| `muted.conf` | muted | obsolete sample removed in `bce722e60d` 2022-04-02 |
| `osp.conf` | app_osplookup | `d0140fc7fe` 2022-11-18 |
| `oss.conf` | chan_oss | `95f3a4a9ad` 2021-08-16 |
| `phone.conf` | chan_phone | `6cc948f94e` 2021-08-16 (also not built in 18.13) |
| `res_config_sqlite.conf` | res_config_sqlite | `800fd84af6` 2021-08-16 (also not built in 18.13) |
| `res_pktccops.conf` | res_pktccops | `89a7d30a97` 2022-11-15 (also not built in 18.13) |
| `sip.conf`, `sip_notify.conf` | chan_sip | `4095a382da` 2022-11-28 |
| `skinny.conf` | chan_skinny | `8d652ab4be` 2022-11-16 |
| `vpb.conf` | chan_vpb | `20b2741232` 2021-08-16 (also not built in 18.13) |

### Customisations and their adaptation to Asterisk 22

| File | Old (18.13) | New (22.11) | Adaptation |
|---|---|---|---|
| `extensions.conf` | `Macro(create_conference)` / `Macro(join_conference)` | `Gosub(sub-create_conference,s,1)` / `Gosub(sub-join_conference,s,1)` | `app_macro` was removed in Asterisk 21. Contexts renamed `macro-*` → `sub-*`, `Return()` added. |
| `modules.conf` | `preload => res_odbc.so`, `res_config_odbc.so` | `preload-require => …` | Asterisk refuses to start if ODBC realtime cannot load, instead of running without it. |
| `res_odbc.conf` | user `root` | user from `config.env` (`asterisk`) | Dedicated database user; values come from placeholders. |
| `res_config_mysql.conf` | root credentials | placeholders | Same content; the module is not built (as before). |
| `ari.conf` | user `user` / `user` | placeholders, defaults `user` / `user` | Unchanged otherwise. |
| `extconfig.conf`, `sorcery.conf`, `http.conf`, `pjsip.conf`, `confbridge.conf` | — | identical changes | Options are valid in 22.11 without changes. |
| `codecs.conf` | no `[g723]` section (codec default 6.3 kbps) | `[g723] sendrate=63` | Added so the G.723.1 send rate of the new `codec_g723` is visible and adjustable; behaviour is unchanged. |

Checked on a running Asterisk 22.11:

- **ARI:** enabled, output format `pretty`, user `user` (read/write).
- **HTTP:** enabled and bound to `0.0.0.0:8088`.
- **PJSIP transports:** `transport-udp` on `0.0.0.0:5060` and `transport-wss` are active.
- **ConfBridge:**
  - `my_bridge`: language `en_GB`, mixing interval 40.
  - `my_user`: MOH when empty disabled, drop silence enabled, silence threshold 2000 ms, talking threshold 256, announce join/leave disabled.
  - `my_menu`: all 8 entries present.
- **ODBC:** DSN `asterisk` has 1 active connection.
- **Realtime:** an endpoint inserted into `ps_endpoints` / `ps_auths` / `ps_aors` is visible in `pjsip show endpoint`.
- **Dialplan:** `666` and `777` resolve to the `Gosub` routines. No `Macro()` and no unresolved `@@…@@` placeholder remain.
- **Log:** no warning or error refers to any of the customised files. The remaining startup messages come from unconfigured stock modules (PostgreSQL, LDAP, TDS, RADIUS, XMPP entity ID). The old package showed the same messages because it shipped the same stock samples.

**End-to-end SIP test (SIPp):**

1. `REGISTER` as endpoint `2001` with digest authentication. Credentials come from the database through realtime, and the contact is stored in `ps_contacts`.
2. `INVITE` to `666` with `X-ConfNum: 4242`. The call enters `sub-create_conference`, `GROUP(conference)` is set to `4242`, and ConfBridge conference `4242` is created.
3. A second call to `777` with the same header joins it (2 users).
4. `BYE` tears everything down.

## System packages

The old package installed 294 `.deb` files: 256 Asterisk build dependencies, 16 MySQL, 4 MariaDB ODBC, 14 Python, 4 expect. On the new target:

| Category | Count | Notes |
|---|---|---|
| Same package present | 48 | e.g. `mysql-server`, `odbc-mariadb`, `unixodbc`, `libjansson4`, `libsrtp2-1`, `libxml2`, `mecab-ipadic-utf8`, `curl` |
| Renamed or newer soname present | 19 | e.g. `libssl1.1` → `libssl3t64`, `libodbc1` → `libodbc2`, `libcurl4` → `libcurl4t64`, `libsnmp35` → `libsnmp40t64`, `python3.8` → `python3.12` |
| Build-only, not needed on the target | 188 | Compiler, `-dev` headers, autotools, doxygen/graphviz, git/subversion, debhelper. Asterisk is compiled into the `.deb`, so none of them is needed on the target. |
| Not needed on the target | 39 | Listed below |

The 39 packages that are not needed:

- **Libraries of modules that are not built in either version:**
  - `libbluetooth3`: chan_mobile
  - `libc-client2007e`, `mlock`: app_voicemail_imap
  - `libcfg7`, `libcpg4`, `libcorosync-common4`, `libqb0`: res_corosync
  - `libmysqlclient21`: res_config_mysql, app_mysql, cdr_mysql
  - `libfftw3-*`: binaural rendering
  - `libsndfile1`, `libflac8`: conf_bridge_binaural_hrir_importer
- **Libraries of modules removed upstream:**
  - `libosptk4`: app_osplookup
  - `libvpb1`: chan_vpb
- **Pulled in only by build packages:**
  - compiler runtimes and flex: `libatomic1`, `libgomp1`, `libfl2`
  - the krb5 development stack: `libgssrpc4`, `libkadm5*`, `libkdb5-9`
  - `-dev` packages: `libncurses6`, `libportaudiocpp0`, `libct4`, `udev`
- **Renamed:** `odbcinst1debian2` is `libodbcinst2` in Ubuntu 24.04 (present).
- **Replaced by a different method:**
  - `expect`, `tcl-expect`, `tcl8.6`, `libtcl8.6`: `mysql_secure_installation` automation is replaced by direct SQL.
  - Python 3.8 with `python3-pip`, `python3-setuptools`, `python3-wheel`: replaced by Python 3.12 and `python3-venv`. `mysqlclient` (compiled) is replaced by PyMySQL (pure Python).

The runtime dependencies of the Asterisk binaries are derived with `dpkg-shlibdeps` from the compiled files, so every library a built module links against is installed.

To keep parity with the old package, `collect-packages.sh` also installs:
- `mysql-server`'s recommended packages: `libhtml-template-perl`, `mecab-ipadic-utf8`, `libcgi-fast-perl` and their dependencies
- the `curl` command-line tool

### Other components

| Component | Old | New |
|---|---|---|
| MySQL server | 8.0.36 (Ubuntu 20.04) | 8.0.46 (Ubuntu 24.04) |
| ODBC driver | MySQL Connector/ODBC 8.3.0, debug build copied to `/usr/local/lib` | MariaDB Connector/ODBC 3.1 (`odbc-mariadb`) |
| Database user for Asterisk | `root` | dedicated `asterisk` user; `'root'@'%'` remote access kept (`ROOT_REMOTE=yes`) |
| MySQL setup | `mysql_secure_installation` via expect | equivalent SQL (anonymous users and test database removed) |
| Schema | alembic 1.13 + mysqlclient, Python 3.8 | alembic + PyMySQL in a Python 3.12 venv, schema at the 22.11 head |
| Service | SysV init script (`make config`) | Asterisk's systemd unit |
| pjproject | 2.12 (bundled) | 2.17 (bundled) |
| Sounds | core-sounds-en-gsm, moh-opsound-wav, extra-sounds-en-wav (cached) | the same three, built into the `.deb` |
| `codec_opus` | `codec_opus.so` | `codec_opus.so` and `format_ogg_opus.so` |
| `codec_g723` | prebuilt `codec_g723.so` (asterisk-g72x, built with GCC 4.6.3 in 2012) | asterisk-g72x 1.4.5 prebuilt module for Asterisk 22 (`codec_g723-ast220-gcc4-glibc-x86_64-pentium4.so`, MD5-verified), IPP linked statically. `install.sh` verifies that it runs and that G.723.1 ↔ slin translation works. |
| `make progdocs` | API documentation generated on the target | not generated (documentation only) |
