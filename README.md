# Asterisk 22 LTS offline installer for Ubuntu 24.04

Installs Asterisk 22 LTS with MySQL 8.0 and ODBC realtime on an Ubuntu 24.04 machine **without internet access**.

Asterisk is compiled once (on GitHub Actions or any internet-connected Ubuntu 24.04 machine) and shipped as a `.deb` package. Nothing is compiled on the target machine, and no compiler is installed there.

| Component | Version |
|---|---|
| OS | Ubuntu 24.04 LTS (noble) |
| Asterisk | 22.11.0 LTS, built from source as `asterisk-offline_22.11.0-1_amd64.deb` |
| pjproject | 2.17 (bundled with Asterisk) |
| MySQL | 8.0 (Ubuntu noble package) |
| ODBC | unixODBC + MariaDB Connector/ODBC (`odbc-mariadb`) |
| DB schema | Asterisk alembic scripts, run in a Python 3.12 venv |

## Quick start

### 1. Get the bundle

**Option A: GitHub Actions (recommended).** No local Ubuntu machine is needed.

1. Open **Actions → Offline bundle → Run workflow**. Optionally enter a different Asterisk version.
2. The workflow runs three jobs:
   - **build**: compiles Asterisk into a `.deb` and downloads every runtime dependency inside a clean `ubuntu:24.04` container. The `.deb` includes the sound packages, `codec_opus`, `codec_g723`, the systemd unit and the alembic scripts. The bundle contents are checked before continuing.
   - **test**: extracts the bundle in an `ubuntu:24.04` container started with `--network none` and runs `install.sh` end to end. It also checks that no compiler was installed.
   - **test-systemd**: the same offline installation on `ubuntu:24.04` running systemd, followed by a reboot of the container. MySQL and Asterisk must come back on their own, with an active ODBC connection.
   - **release**: if the test passes, publishes `asterisk-<version>-offline-ubuntu2404-<date>-r<run>.tar.gz` and its `.sha256` under **Releases**.
3. Download the `.tar.gz` from the release.

**Option B: any internet-connected Ubuntu 24.04 machine** (a VM or WSL works):

```bash
sudo bash collect-packages.sh      # runs build-asterisk-deb.sh first if needed
```

This creates `bundle/`.

### 2. Install on the offline machine

The target must be a fresh Ubuntu 24.04 installation (server or desktop). Copy the archive (or this folder including `bundle/`) to it, then:

```bash
tar xzf asterisk-*-offline-ubuntu2404-*.tar.gz
cd asterisk-*-offline-ubuntu2404-*/
nano config.env                    # adjust passwords if needed
sudo bash install.sh
```

The installation takes a few minutes. The log is written to `/var/log/asterisk-offline-install.log`.

## What `install.sh` does

1. Installs the packages from `bundle/debs` through a temporary local apt repository. The system's apt sources are not modified. Besides Asterisk, MySQL and ODBC this includes `curl` and MySQL's recommended packages, which the previous 18.13 package also installed.
2. Creates the `asterisk` user and group.
3. Checks that every module in `REQUIRED_MODULES` is present.
4. Installs `/etc/asterisk` from `configs/asterisk/`. A previous `/etc/asterisk` is moved to `/etc/asterisk.bak-<timestamp>`.
5. Sets file ownership and permissions.
6. Configures MySQL:
   - removes anonymous users and the test database
   - creates the database and `'asterisk'@'localhost'` with all privileges on it (used by ODBC and alembic)
   - optionally creates `'asterisk'@'%'` for applications on other hosts, limited to `SELECT, INSERT, UPDATE, DELETE` on the Asterisk database, and checks its grants
   - optionally allows remote root access and binds to all interfaces
7. Configures the ODBC DSN `asterisk` and creates the schema with alembic.
8. Starts Asterisk via systemd and verifies the installation (see below). A drop-in (`/etc/systemd/system/asterisk.service.d/10-mysql.conf`) makes Asterisk start after MySQL, so ODBC realtime is available right after a reboot.

## Configuration

### Settings: `config.env`

All versions, passwords and switches are in `config.env`:

| Variable | Purpose |
|---|---|
| `ASTERISK_VERSION` | Asterisk release to build |
| `SOUND_PACKAGES`, `EXTERNAL_CODECS` | Sound packages and prebuilt Digium codecs included in the `.deb` |
| `G72X_CODECS`, `G72X_CPU` | Prebuilt asterisk-g72x codecs (G.723.1) included in the `.deb`, and their CPU variant |
| `REQUIRED_MODULES` | Modules that must be built and running (see *Verification*) |
| `DB_NAME`, `DB_USER`, `DB_PASS` | Asterisk database and the user ODBC/alembic connect with |
| `DB_REMOTE`, `DB_REMOTE_PASS` | Create `'<DB_USER>'@'%'` with `SELECT, INSERT, UPDATE, DELETE` on `<DB_NAME>.*` for remote applications |
| `ROOT_REMOTE`, `ROOT_REMOTE_PASS` | Create `'root'@'%'` for remote access |
| `MYSQL_REMOTE_AUTH` | Authentication plugin of the two remote accounts: `mysql_native_password` (default, as in the 18.13 package, works with older clients) or `caching_sha2_password` |
| `MYSQL_BIND_ALL` | Set MySQL `bind-address = 0.0.0.0` |
| `ARI_USER`, `ARI_PASS` | ARI user |

`install.sh` refuses to run if a password is empty or `CHANGE_ME`.

### Asterisk configuration: `configs/asterisk/`

This directory is the **complete** `/etc/asterisk` (106 files): the Asterisk 22.11 sample files with the project's customisations applied. Edit the files here directly; added or removed files are reflected in the installation.

Configuration is not part of the `.deb`. Changing it never requires rebuilding Asterisk; on a running system use `asterisk -rx "core reload"` (or `dialplan reload`, `pjsip reload`).

Customisations compared to the stock samples (full diff: `configs/custom-vs-22.11-samples.diff`):

| File | Change |
|---|---|
| `extconfig.conf` | `ps_*` tables → `odbc,asterisk` |
| `sorcery.conf` | `[res_pjsip]` endpoint/auth/aor/domain_alias/contact → realtime |
| `res_odbc.conf` | `[asterisk]` enabled, credentials, `pre-connect` |
| `modules.conf` | `preload-require` for `res_odbc.so` and `res_config_odbc.so`; `noload` for the unused `cdr_radius.so` / `cel_radius.so` |
| `pjsip.conf` | `transport-udp` (5060) and `transport-wss` |
| `http.conf` | enabled on `0.0.0.0:8088` |
| `ari.conf` | `pretty = yes`, ARI user |
| `confbridge.conf` | `my_bridge`, `my_user`, `my_menu` profiles |
| `extensions.conf` | `[default]` → `Dial(PJSIP/${EXTEN})`; 666/777 conference via `Gosub`; 888 joins the fixed conference `1234` |
| `res_config_mysql.conf` | database settings (unused, ODBC is used instead) |
| `codecs.conf` | `[g723] sendrate=63` for `codec_g723` (6.3 kbps, the codec's default made explicit) |

Credentials in these files are `@@DB_USER@@`, `@@DB_PASS@@`, `@@DB_NAME@@`, `@@ARI_USER@@` and `@@ARI_PASS@@` placeholders. `install.sh` fills them in from `config.env`.

`tools/build-configs.py` regenerates this directory from a newer Asterisk release's samples. This overwrites manual edits in `configs/asterisk/`, so only use it when moving to a new Asterisk version:

```bash
python3 tools/build-configs.py <asterisk-source>/configs/samples configs/asterisk
```

It stops with an error if one of the customisations no longer applies to the new sample files.

## Verification

Problems stop the installation instead of being skipped silently:

| Stage | Check |
|---|---|
| Build | `build-asterisk-deb.sh` fails if a module in `REQUIRED_MODULES` or in `tools/expected-modules.txt` (the full list of 345 modules) was not built. menuselect silently skips modules with missing build dependencies. |
| Startup | `modules.conf` loads the ODBC modules with `preload-require`. If one cannot load, Asterisk exits instead of running without realtime. |
| End of install | `install.sh` fails unless every required module is `Running` and the ODBC `asterisk` connection is active. |

The default `REQUIRED_MODULES` covers what the current configuration uses: ODBC realtime, PJSIP + WSS, the dialplan functions, ConfBridge and ARI. If you add a feature to the configuration, add its module to the list.

## Notes

- **Migrating from the Asterisk 18.13 package.** See [docs/migration-from-18.md](docs/migration-from-18.md) for the item-by-item comparison of modules, configuration files and system packages.

- **`Macro()` → `Gosub()`.** `app_macro` was removed in Asterisk 21. The 666/777 conference flow uses `Gosub(sub-create_conference,s,1)` / `Gosub(sub-join_conference,s,1)` with the same `X-ConfNum` header and `GROUP(conference)` logic.
- **Package name.** The package is `asterisk-offline`. It conflicts with Ubuntu's own `asterisk` packages (20.x on noble), so the two cannot be installed side by side.
- **Portable build.** `BUILD_NATIVE` is disabled, so the `.deb` is not tied to the CPU of the build machine.
- **systemd.** Asterisk is linked against libsystemd, so the `Type=notify` unit becomes active when Asterisk reports ready. `RuntimeDirectory=asterisk` recreates `/run/asterisk` on every start, so the service also comes up after a reboot.
- **RADIUS.** `cdr_radius` and `cel_radius` are disabled in `modules.conf`. Asterisk looks for `/etc/radiusclient-ng/radiusclient.conf`, while Ubuntu's radcli installs `/etc/radcli/radiusclient.conf`, so these modules could not load in the previous package either. To use RADIUS accounting, remove the `noload` lines and set `radiuscfg => /etc/radcli/radiusclient.conf` in the `[radius]` section of `cdr.conf` and `cel.conf`.
- **G.723.1.** `codec_g723.so` is the asterisk-g72x author's prebuilt module for Asterisk 22 (from asterisk.hosting.lv, checked against the published MD5SUM). Intel IPP is linked statically into it. It cannot be compiled from source in this project because G.723.1 needs Intel's discontinued IPP speech codec libraries. The default CPU variant `x86_64-pentium4` runs on every x86-64 CPU. `install.sh` checks that the module runs and that G.723.1 ↔ slin translation works. The send rate is set in `codecs.conf` (`[g723] sendrate=63` or `53`).
- **MySQL accounts.** `'asterisk'@'localhost'` and `'asterisk'@'%'` are two separate accounts with their own passwords. Connections on the server itself (ODBC, alembic) use the `localhost` account; connections from other hosts use the `%` account, which cannot change the schema or reach other databases. For administration from another host use `'root'@'%'`.
- **ConfBridge language.** `confbridge.conf` uses `language=en_GB`, but only `en` sounds are packaged.
- **Package freshness.** Packages are as current as the day the bundle was built. Rebuild the bundle before a new installation to pick up security updates.

## Files

```
config.env                  versions, passwords, switches
build-asterisk-deb.sh       compiles Asterisk into bundle/debs/asterisk-offline_*.deb (online)
collect-packages.sh         collects runtime dependencies and wheels into bundle/ (online)
install.sh                  installs on the offline target
configs/asterisk/           complete /etc/asterisk with placeholders
configs/odbc/odbc.ini.in    ODBC DSN template
configs/custom-vs-22.11-samples.diff   customisations vs. the stock samples
tools/build-configs.py      regenerates configs/asterisk/ for a new Asterisk release
tools/expected-modules.txt  every module the .deb must contain (build fails otherwise)
docs/migration-from-18.md   item-by-item comparison with the previous 18.13 package
.github/workflows/          GitHub Actions: build, offline install test, release
```

`bundle/`, `build/` and `dist/` are generated and not committed.

If you edit the scripts on Windows, keep LF line endings. With CRLF, bash fails; fix it with `sed -i 's/\r$//' *.sh config.env`.
