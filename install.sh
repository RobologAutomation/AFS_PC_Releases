#!/bin/bash
# AFS Controller installer for an Ubuntu mini-PC.
#
#   sudo bash install.sh            clean install: back up, remove every earlier
#                                   fuel application (FlowMeterApp with its cloud
#                                   upload and Hamachi VPN, afsd, any earlier AFS
#                                   Controller) and its data, install fresh
#   sudo bash install.sh --check    report what is there, change nothing
#   sudo bash install.sh --deb F --sig S   install a package brought by the
#                                   technician app (PC without internet)
#   --no-ssh-lock                   leave SSH as it is (keys and passwords)
#
# Run by the AFS Controller app over SSH ("Install on PC"), or by hand.
# Output lines for the app: "STEP n/N text", "INFO key=value",
# "RESULT OK <version>" / "RESULT CHECKED" / "RESULT FAIL <CODE> <text>".
#
# Published in RobologAutomation/AFS_PC_Releases (install.sh), next to the
# packages it installs. Packages are installed only with a valid Ed25519
# signature of the AFS release key. Nothing is removed before the new
# software is downloaded and verified, and everything removed is first put
# in /var/backups/afs-backup-<date>.tar.gz.

set -u
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

OWNER=RobologAutomation
REPO=AFS_PC_Releases
BRANCH=main
CHANNEL=beta
RAW="https://raw.githubusercontent.com/$OWNER/$REPO"
API="https://api.github.com/repos/$OWNER/$REPO/contents"
PUBKEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA5JefAv0bOjkkkh0bAL1zjKYablCnBKH6jf9J0tCRV34=
-----END PUBLIC KEY-----'
# The only SSH key trusted after the install (Robolog).
ROBOLOG_SSH_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEz3877iMyaEEQp3sxma5BIQWQi6Vq+pgf2yM8y3z/nf robolog-afs'
WORK=/tmp/afs-install
NETSTAGE=/var/lib/afs-net-switch
TOTAL=9

CHECK=0; DEB=""; SIG=""; SSH_LOCK=1
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1 ;;
        --deb) DEB="$2"; shift ;;
        --sig) SIG="$2"; shift ;;
        --channel) CHANNEL="$2"; shift ;;
        --no-ssh-lock) SSH_LOCK=0 ;;
        *) echo "RESULT FAIL USAGE unknown option $1"; exit 2 ;;
    esac
    shift
done

step() { echo "STEP $1/$TOTAL $2"; }
info() { echo "INFO $1=$2"; }
fail() { echo "RESULT FAIL $1 ${2:-}"; exit 1; }
list() { tr '\n' ' ' | sed 's/ *$//'; }

installed_version() {
    if command -v afs-controller >/dev/null 2>&1; then
        afs-controller -version 2>/dev/null | awk '{print $2}'
    else
        echo none
    fi
}

online() { curl -fsS -m 8 -o /dev/null https://api.github.com/ 2>/dev/null; }

# Prints "version file sha256 commit" of the newest release on the channel.
latest() {
    local m
    m=$(curl -fsS -m 20 -H "Accept: application/vnd.github.raw" -H "User-Agent: afs-install" \
        "$API/$CHANNEL/manifest.json?ref=$BRANCH" 2>/dev/null) ||
    m=$(curl -fsS -m 20 "$RAW/$BRANCH/$CHANNEL/manifest.json?t=$(date +%s)" 2>/dev/null) || return 1
    printf '%s' "$m" | python3 -c '
import json, sys
m = json.load(sys.stdin)
print(m["version"], m["file"], m["sha256"], m.get("commit") or "-")'
}

# ------------------------------------------------- what the earlier software left

# Services of earlier fuel applications: afsd (Dart) and FlowMeterApp ("FCC Handler").
old_units() {
    systemctl list-unit-files --no-legend 'afsd*' 'flowmeter*' 2>/dev/null | awk '{print $1}'
}

# Files of earlier fuel applications and old bench tools.
old_files() {
    for p in /opt/afsd /etc/afsd /usr/local/bin/afsd /var/lib/afsd /var/log/afsd \
             /etc/systemd/system/afsd.service /lib/systemd/system/afsd.service \
             /etc/systemd/system/flowmeter.service /transactions; do
        [ -e "$p" ] && echo "$p"
    done
    # In home folders: afsd, FlowMeterApp (program, start script, log, config,
    # transactions, cloud upload and deploy scripts), old tools.
    find /home /root -maxdepth 2 \( -iname 'afsd*' -o -name vegasim -o -name afs-soak -o -name afs-mock \
        -o -name 'FlowMeterApp*' -o -name runUploadTransactions.sh -o -name uploadTransactions.sh \
        -o -name update_wifis.sh -o -name 'deploy-flowmeter*' -o -name flowmeter.log -o -name uploadLog.txt \
        -o -name iot-flowmeter.json -o -name transactions -o -name rpiSerialWarmer.py \
        -o -name 'logmein-hamachi*.deb' \) 2>/dev/null
    # Generic names: only the FlowMeterApp copies (they name its server).
    for f in /home/*/installer.sh /home/*/colours.sh /root/installer.sh /root/colours.sh; do
        [ -f "$f" ] && grep -qiE 'electronodes|FlowMeter|cecho' "$f" && echo "$f"
    done
}

# Crontab lines of the FlowMeterApp cloud upload.
old_cron_users() {
    for u in $(cut -d: -f1 /etc/passwd); do
        crontab -l -u "$u" 2>/dev/null | grep -qE 'runUploadTransactions|uploadTransactions|FlowMeterApp|electronodes' && echo "$u"
    done
}

hamachi_present() { dpkg -s logmein-hamachi >/dev/null 2>&1 || [ -d /var/lib/logmein-hamachi ]; }

# State of the AFS Controller itself (records, settings, logins) for a fresh start.
own_data() {
    for p in /var/lib/afs /etc/afs; do [ -e "$p" ] && echo "$p"; done
}

# Netplan files that define WiFi (the old setup; the AFS Controller needs
# NetworkManager to own the WiFi).
netplan_wifi() { grep -lE '^[[:space:]]*wifis:' /etc/netplan/*.yaml 2>/dev/null; }

# ---------------------------------------------------------------- check only
if [ "$CHECK" = 1 ]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null
    info os "${PRETTY_NAME:-unknown}"
    info arch "$(dpkg --print-architecture 2>/dev/null || uname -m)"
    info hostname "$(hostname)"
    info installed "$(installed_version)"
    info service "$(systemctl is-active afs-controller 2>/dev/null || echo none)"
    info disk_free_mb "$(df -Pm / | awk 'NR==2{print $4}')"
    info old_services "$(old_units | list)"
    info old_files "$(old_files | list)"
    info old_cron "$(old_cron_users | list)"
    info hamachi "$(hamachi_present && echo yes || echo no)"
    info wifi_manager "$( [ -n "$(netplan_wifi)" ] && echo netplan || echo NetworkManager)"
    if online; then
        info internet yes
        read -r lv _ <<< "$(latest 2>/dev/null || echo unknown)"
        info latest "$lv"
    else
        info internet no
    fi
    echo "RESULT CHECKED"
    exit 0
fi

# ------------------------------------------------------------------- install
[ "$(id -u)" = 0 ] || fail NOT_ROOT "run with sudo"

step 1 "Checking the PC"
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null
case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) ;;
    *) fail UNSUPPORTED_OS "${PRETTY_NAME:-unknown OS}: Ubuntu 22.04 or 24.04 is needed" ;;
esac
[ "$(dpkg --print-architecture)" = amd64 ] || fail UNSUPPORTED_ARCH "$(dpkg --print-architecture)"
free=$(df -Pm / | awk 'NR==2{print $4}')
[ "${free:-0}" -ge 300 ] || fail NO_SPACE "${free} MB free, 300 MB needed"
for c in openssl tar sha256sum systemctl dpkg python3; do
    command -v "$c" >/dev/null || fail MISSING_TOOL "$c"
done
info os "$PRETTY_NAME"
info installed "$(installed_version)"
user="${SUDO_USER:-}"
home=$(getent passwd "$user" | cut -d: -f6)

step 2 "Backing up existing data"
mkdir -p /var/backups "$WORK"
stamp=$(date +%Y%m%d-%H%M%S)
backup="/var/backups/afs-backup-$stamp.tar.gz"
journalctl -u 'afs*' --no-pager -o short-iso > "$WORK/journal-afs.txt" 2>/dev/null || true
journalctl -u 'afsd*' -u 'flowmeter*' --no-pager -o short-iso > "$WORK/journal-old.txt" 2>/dev/null || true
for u in $(cut -d: -f1 /etc/passwd); do
    crontab -l -u "$u" > "$WORK/crontab-$u.txt" 2>/dev/null || rm -f "$WORK/crontab-$u.txt"
done
paths="$WORK /etc/netplan /etc/NetworkManager/system-connections /var/lib/logmein-hamachi /root/.ssh/authorized_keys"
[ -n "$home" ] && paths="$paths $home/.ssh/authorized_keys"
for u in $(old_units); do
    f=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)
    [ -n "$f" ] && paths="$paths $f"
done
paths="$paths $(own_data | list) $(old_files | list)"
existing=""
for p in $paths; do [ -e "$p" ] && existing="$existing $p"; done
# shellcheck disable=SC2086
tar czf "$backup" --ignore-failed-read $existing 2>/dev/null
chmod 0600 "$backup"
info backup "$backup ($(du -h "$backup" | cut -f1))"

# The new software is downloaded and verified before anything is removed.
step 3 "Getting the software"
if [ -n "$DEB" ]; then
    [ -f "$DEB" ] && [ -f "$SIG" ] || fail NO_PACKAGE "package or signature missing"
    cp "$DEB" "$WORK/pkg.deb"; cp "$SIG" "$WORK/pkg.deb.sig"
    want=""
else
    online || fail NO_INTERNET "the PC cannot reach GitHub"
    rel=$(latest) || fail NO_INTERNET "release list not readable"
    read -r ver file want commit <<< "$rel"
    base="$RAW/$BRANCH"
    [ "$commit" != "-" ] && base="$RAW/$commit"
    info latest "$ver"
    curl -fsS -m 300 -o "$WORK/pkg.deb" "$base/$file" || fail DOWNLOAD "package download failed"
    curl -fsS -m 30 -o "$WORK/pkg.deb.sig" "$base/$file.sig" || fail DOWNLOAD "signature download failed"
fi

step 4 "Checking the signature"
if [ -n "$want" ]; then
    got=$(sha256sum "$WORK/pkg.deb" | cut -d' ' -f1)
    [ "$got" = "$want" ] || fail BAD_HASH "SHA-256 differs from the release list"
fi
printf '%s\n' "$PUBKEY" > "$WORK/release.pub"
openssl pkeyutl -verify -pubin -inkey "$WORK/release.pub" -rawin -in "$WORK/pkg.deb" \
    -sigfile "$WORK/pkg.deb.sig" >/dev/null 2>&1 || fail BAD_SIGNATURE "not signed by the AFS release key"
info signature ok

step 5 "Removing the old fuel applications"
for u in $(old_units); do
    systemctl disable --now "$u" >/dev/null 2>&1
    info stopped "$u"
done
for u in $(old_cron_users); do
    crontab -l -u "$u" 2>/dev/null | grep -vE 'runUploadTransactions|uploadTransactions|FlowMeterApp|electronodes' | crontab -u "$u" -
    info removed "cloud upload job (crontab of $u)"
done
if hamachi_present; then
    timeout 15 hamachi logout >/dev/null 2>&1
    apt-get purge -y -q -o DPkg::Lock::Timeout=180 logmein-hamachi >/dev/null 2>&1
    rm -rf /var/lib/logmein-hamachi
    info removed "Hamachi VPN"
fi
n=0
for p in $(old_files); do
    rm -rf --one-file-system "$p" && n=$((n + 1))
    info removed "$p"
done
systemctl daemon-reload 2>/dev/null
systemctl reset-failed 'afsd*' 'flowmeter*' 2>/dev/null
[ "$n" = 0 ] && info removed "no old application files found"

step 6 "Removing the previous AFS Controller"
# A fresh start: package, records, settings and logins go (they are in the
# backup). The network setup stays, so this SSH session keeps working.
if dpkg -s afs-controller >/dev/null 2>&1; then
    apt-get purge -y -q -o DPkg::Lock::Timeout=180 afs-controller > "$WORK/purge.log" 2>&1 ||
        { tail -5 "$WORK/purge.log"; fail REMOVE "the installed AFS Controller could not be removed (delivery in progress?)"; }
    info removed "previous AFS Controller"
fi
for p in $(own_data); do
    rm -rf --one-file-system "$p"
    info removed "$p"
done
rm -f /etc/ssh/sshd_config.d/60-afs-keyonly.conf

step 7 "Installing the software"
if ! apt-get install -y -q -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold \
        "$WORK/pkg.deb" > "$WORK/apt.log" 2>&1; then
    # No internet for dependencies: the package itself needs only the base system.
    dpkg -i --force-confold "$WORK/pkg.deb" > "$WORK/apt.log" 2>&1 ||
        { tail -5 "$WORK/apt.log"; fail INSTALL "package install failed"; }
fi
for _ in $(seq 1 30); do
    [ "$(systemctl is-active afs-controller 2>/dev/null)" = active ] && break
    sleep 1
done
[ "$(systemctl is-active afs-controller 2>/dev/null)" = active ] || fail NOT_RUNNING "installed, but the service did not start"
v=$(installed_version)
info installed "$v"

step 8 "Securing SSH"
if [ "$SSH_LOCK" = 0 ]; then
    info ssh "unchanged (--no-ssh-lock)"
elif [ -z "$home" ] || [ ! -d /etc/ssh/sshd_config.d ]; then
    info ssh "unchanged (no login user or no sshd_config.d)"
else
    # Robolog's key only (earlier vendor keys are in the backup), then key-only.
    install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$home/.ssh"
    printf '%s\n' "$ROBOLOG_SSH_KEY" > "$home/.ssh/authorized_keys"
    chown "$user:$(id -gn "$user")" "$home/.ssh/authorized_keys"
    chmod 0600 "$home/.ssh/authorized_keys"
    [ -f /root/.ssh/authorized_keys ] && : > /root/.ssh/authorized_keys
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/60-afs-keyonly.conf
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        info ssh "Robolog key only, password logins off"
    else
        rm -f /etc/ssh/sshd_config.d/60-afs-keyonly.conf
        info ssh "Robolog key set; password logins kept (sshd rejected the change)"
    fi
fi

step 9 "Moving WiFi to NetworkManager"
files=$(netplan_wifi)
if [ -z "$files" ]; then
    info network "WiFi already on NetworkManager"
elif ! command -v nmcli >/dev/null; then
    info network "NetworkManager not installed (no internet for it): WiFi left on netplan"
else
    rm -rf "$NETSTAGE"; mkdir -p "$NETSTAGE/new" "$NETSTAGE/old"
    chmod 0700 "$NETSTAGE"
    cp -p /etc/netplan/*.yaml "$NETSTAGE/old/"
    # NetworkManager profiles from every netplan WiFi network (same SSIDs and
    # passwords), and the netplan files without their WiFi part.
    # shellcheck disable=SC2086
    python3 - "$NETSTAGE" $files <<'PY' || fail NETWORK "netplan WiFi could not be read"
import os, sys, uuid, yaml
stage, files = sys.argv[1], sys.argv[2:]
prio = 100
for f in files:
    with open(f) as fh:
        d = yaml.safe_load(fh) or {}
    net = d.get("network") or {}
    wifis = net.pop("wifis", None) or {}
    for dev, cfg in wifis.items():
        for ssid, ap in ((cfg or {}).get("access-points") or {}).items():
            ap = ap or {}
            name = "afs-import-%d" % (100 - prio)
            lines = ["[connection]", "id=%s" % ssid, "uuid=%s" % uuid.uuid4(), "type=wifi",
                     "autoconnect=true", "autoconnect-priority=%d" % prio, "",
                     "[wifi]", "mode=infrastructure", "ssid=%s" % ssid, ""]
            if ap.get("password"):
                lines += ["[wifi-security]", "key-mgmt=wpa-psk", "psk=%s" % ap["password"], ""]
            lines += ["[ipv4]", "method=auto", "", "[ipv6]", "method=auto", ""]
            path = os.path.join(stage, "new", name + ".nmconnection")
            with open(path, "w") as out:
                out.write("\n".join(lines))
            os.chmod(path, 0o600)
            prio -= 1
    keep = {k: v for k, v in net.items() if k not in ("version", "renderer")}
    out = os.path.join(stage, "new", os.path.basename(f))
    if keep:
        with open(out, "w") as fh:
            yaml.safe_dump({"network": net}, fh, default_flow_style=False)
        os.chmod(out, 0o600)
    else:
        open(out + ".remove", "w").close()
PY
    info network "WiFi networks taken over: $(grep -h '^id=' "$NETSTAGE"/new/*.nmconnection 2>/dev/null | cut -d= -f2- | list)"
    # The switch drops this SSH connection, so it runs on its own 15 s after
    # this script ends, and goes back to netplan if the WiFi does not come up.
    cat > "$NETSTAGE/switch.sh" <<'SW'
#!/bin/bash
S=/var/lib/afs-net-switch
for f in "$S"/new/*.yaml; do [ -e "$f" ] && cp -p "$f" /etc/netplan/; done
for f in "$S"/new/*.yaml.remove; do [ -e "$f" ] && rm -f "/etc/netplan/$(basename "$f" .remove)"; done
cp -p "$S"/new/*.nmconnection /etc/NetworkManager/system-connections/ 2>/dev/null
netplan generate && netplan apply
systemctl restart NetworkManager
for _ in $(seq 1 90); do
    if nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -q '^wifi:connected'; then
        logger -t afs-install "WiFi now on NetworkManager"
        exit 0
    fi
    sleep 1
done
logger -t afs-install "WiFi did not come up on NetworkManager; netplan restored"
rm -f /etc/NetworkManager/system-connections/afs-import-*.nmconnection
for f in "$S"/new/*.yaml; do [ -e "$f" ] && rm -f "/etc/netplan/$(basename "$f")"; done
cp -p "$S"/old/*.yaml /etc/netplan/
netplan generate && netplan apply
systemctl restart NetworkManager
SW
    chmod 0700 "$NETSTAGE/switch.sh"
    systemd-run --quiet --unit=afs-wifi-switch --on-active=15 /bin/bash "$NETSTAGE/switch.sh" ||
        fail NETWORK "could not schedule the WiFi switch"
    info network "WiFi moves to NetworkManager in 15 s: this connection drops, the PC is back on the same WiFi within about a minute"
fi

rm -rf "$WORK"
echo "RESULT OK $v"
