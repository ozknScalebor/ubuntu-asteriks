#!/usr/bin/env python3
"""
Regenerates configs/asterisk/ from an Asterisk release's sample files.

Usage:  build-configs.py <asterisk-source>/configs/samples <output-dir>

Every sample file is copied to the output directory (with the .sample suffix
removed, exactly like `make samples`), then the customisations below are
applied. The output directory is therefore a complete, self-contained copy
of /etc/asterisk.

Each edit replaces a piece of text that must occur EXACTLY ONCE in the sample
file. If it is not found (for example because a newer Asterisk release changed
the sample), the script stops with an error instead of silently skipping it.

Passwords and user names are left as @@NAME@@ placeholders; install.sh fills
them in from config.env.
"""
import pathlib
import sys

APPEND = object()

EDITS = {
    # --- ARI: pretty JSON + application user --------------------------------
    "ari.conf": [
        (";pretty = no        ; When set to yes, responses from ARI are",
         "pretty = yes        ; When set to yes, responses from ARI are"),
        (APPEND,
         "\n[@@ARI_USER@@]\n"
         "type=user\n"
         "read_only=no\n"
         "password=@@ARI_PASS@@\n"
         "password_format=plain\n"),
    ],
    # --- ConfBridge profiles -------------------------------------------------
    "confbridge.conf": [
        (APPEND,
         "\n[my_bridge]\n"
         "type=bridge\n"
         "language=en_GB\n"
         "mixing_interval=40\n"
         "\n[my_user]\n"
         "type=user\n"
         "music_on_hold_when_empty=no\n"
         "announce_join_leave=no\n"
         "dsp_talking_threshold=256\n"
         "dsp_silence_threshold=2000\n"
         "dsp_drop_silence=yes\n"
         "\n[my_menu]\n"
         "type=menu\n"
         "*=playback_and_continue(press&digits/1&confbridge-dec-list-vol-out&press&digits/2&confbridge-inc-list-vol-out&press&digits/3&confbridge-mute-out&confbridge-menu-exit-in&press&digits/0)\n"
         "*1=decrease_listening_volume\n"
         "1=decrease_listening_volume\n"
         "*2=increase_listening_volume\n"
         "2=increase_listening_volume\n"
         "*3=toggle_mute\n"
         "3=toggle_mute\n"
         "*0=no_op\n"),
    ],
    # --- G.723.1 (codec_g723 from asterisk-g72x reads [g723] in codecs.conf) --
    "codecs.conf": [
        (APPEND,
         "\n; G.723.1 send rate for outgoing audio: 63 = 6.3 kbps (codec default), 53 = 5.3 kbps.\n"
         "; Incoming streams are decoded at either rate automatically.\n"
         "[g723]\n"
         "sendrate=63\n"),
    ],
    # --- PJSIP realtime tables -> ODBC ---------------------------------------
    "extconfig.conf": [
        (APPEND,
         "\nps_endpoints => odbc,asterisk\n"
         "ps_auths => odbc,asterisk\n"
         "ps_aors => odbc,asterisk\n"
         "ps_domain_aliases => odbc,asterisk\n"
         "ps_endpoint_id_ips => odbc,asterisk\n"
         "ps_contacts => odbc,asterisk\n"),
    ],
    # --- Dialplan: Macro() was removed in Asterisk 21 -> Gosub()/Return() -----
    "extensions.conf": [
        (APPEND,
         "\n[default]\n"
         "exten => _X.,1,NoOp(Default)\n"
         "same => n,Dial(PJSIP/${EXTEN})\n"
         "\n"
         "; Previously Macro(create_conference) / Macro(join_conference).\n"
         "; app_macro was removed in Asterisk 21; same flow with Gosub.\n"
         "exten => 666,1,Gosub(sub-create_conference,s,1)\n"
         "exten => 777,1,Gosub(sub-join_conference,s,1)\n"
         "; Joins the fixed conference 1234 (no X-ConfNum header needed).\n"
         "exten => 888,1,Gosub(sub-join_conference2,s,1)\n"
         "\n[sub-create_conference]\n"
         "exten => s,1,Set(__CONFERENCENUM=${PJSIP_HEADER(read,X-ConfNum)})\n"
         "same => n,Set(GROUP(conference)=${CONFERENCENUM})\n"
         "same => n,ConfBridge(${CONFERENCENUM},my_bridge,my_user)\n"
         "same => n,Return()\n"
         "\n[sub-join_conference]\n"
         "exten => s,1,Set(__CONFERENCENUM=${PJSIP_HEADER(read,X-ConfNum)})\n"
         "same => n,ConfBridge(${CONFERENCENUM},my_bridge,my_user)\n"
         "same => n,Return()\n"
         "\n[sub-join_conference2]\n"
         "exten => s,1,Set(__CONFERENCENUM=1234)\n"
         "same => n,ConfBridge(1234,my_bridge,my_user)\n"
         "same => n,Return()\n"),
    ],
    # --- HTTP (for ARI and WSS) -----------------------------------------------
    "http.conf": [
        (";enabled=yes\n", "enabled=yes\n"),
        ("bindaddr=127.0.0.1\n", "bindaddr=0.0.0.0\n"),
        (";bindport=8088\n", "bindport=8088\n"),
    ],
    # --- Load the ODBC modules early and make them mandatory ------------------
    "modules.conf": [
        (APPEND,
         "\n; ODBC realtime is mandatory: if a module fails to load, Asterisk\n"
         "; refuses to start instead of silently running without realtime.\n"
         "preload-require => res_odbc.so\n"
         "preload-require => res_config_odbc.so\n"
         "\n; RADIUS CDR/CEL are not used. Asterisk looks for\n"
         "; /etc/radiusclient-ng/radiusclient.conf while Ubuntu's radcli installs\n"
         "; /etc/radcli/radiusclient.conf, so these modules could not load in the previous\n"
         "; 18.13 package either. To use RADIUS accounting, remove these lines and set\n"
         "; radiuscfg => /etc/radcli/radiusclient.conf in the [radius] section of\n"
         "; cdr.conf and cel.conf.\n"
         "noload => cdr_radius.so\n"
         "noload => cel_radius.so\n"),
    ],
    # --- PJSIP transports -----------------------------------------------------
    "pjsip.conf": [
        (APPEND,
         "\n[transport-udp]\n"
         "type=transport\n"
         "protocol=udp\n"
         "bind=0.0.0.0:5060\n"
         "\n[transport-wss]\n"
         "type=transport\n"
         "protocol=wss\n"
         "bind=0.0.0.0\n"),
    ],
    # --- res_config_mysql (kept for parity; unused because ODBC is used) ------
    "res_config_mysql.conf": [
        (";dbhost = 127.0.0.1\n;dbname = asterisk\n;dbuser = myuser\n;dbpass = mypass\n;dbport = 3306\n",
         "dbhost = 127.0.0.1\ndbname = @@DB_NAME@@\ndbuser = @@DB_USER@@\ndbpass = @@DB_PASS@@\ndbport = 3306\n"),
    ],
    # --- res_odbc: [asterisk] connection --------------------------------------
    "res_odbc.conf": [
        ("enabled => no\n;\n; This value should match an entry in /etc/odbc.ini\n"
         "; (or /usr/local/etc/odbc.ini, on FreeBSD and similar systems).\n"
         "dsn => asterisk\n",
         "enabled => yes\n;\n; This value should match an entry in /etc/odbc.ini\n"
         "; (or /usr/local/etc/odbc.ini, on FreeBSD and similar systems).\n"
         "dsn => asterisk\n"
         "username => @@DB_USER@@\n"
         "password => @@DB_PASS@@\n"
         "pre-connect => yes\n"),
    ],
    # --- sorcery: PJSIP objects from realtime ---------------------------------
    "sorcery.conf": [
        (";[res_pjsip]\n;endpoint=realtime,ps_endpoints\n;auth=realtime,ps_auths\n"
         ";aor=realtime,ps_aors\n;domain_alias=realtime,ps_domain_aliases\n",
         "[res_pjsip]\nendpoint=realtime,ps_endpoints\nauth=realtime,ps_auths\n"
         "aor=realtime,ps_aors\ndomain_alias=realtime,ps_domain_aliases\n"
         "contact=realtime,ps_contacts\n"),
    ],
}


def main():
    samples = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for old_file in out.iterdir():
        if old_file.is_file():
            old_file.unlink()
    n = 0
    for smp in sorted(samples.iterdir()):
        if not smp.is_file():
            continue
        # same as `make samples`: *.sample -> suffix removed, others (*.adsi) as-is
        dst = smp.name[: -len(".sample")] if smp.name.endswith(".sample") else smp.name
        (out / dst).write_bytes(smp.read_bytes())
        n += 1
    print(f"{n} sample files copied")
    for name, edits in EDITS.items():
        text = (samples / f"{name}.sample").read_text()
        for old, new in edits:
            if old is APPEND:
                if not text.endswith("\n"):
                    text += "\n"
                text += new
                continue
            n = text.count(old)
            if n != 1:
                sys.exit(f"ERROR: {name}: expected text found {n} times (must be 1):\n{old!r}")
            text = text.replace(old, new)
        (out / name).write_text(text)
        print(f"ok  {name}")


if __name__ == "__main__":
    main()
