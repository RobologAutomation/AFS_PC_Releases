#!/bin/bash
# AFS Controller installer for an Ubuntu mini-PC.
#
#   sudo bash install.sh            back up, remove every AFS application and
#                                   its data (old afsd and any earlier AFS
#                                   Controller), download, verify, install fresh
#   sudo bash install.sh --check    report what is there, change nothing
#   sudo bash install.sh --deb F --sig S   install a package brought by the
#                                   technician app (PC without internet)
#   --no-ssh-lock                   leave SSH password logins on
#
# Run by the AFS Controller app over SSH ("Install on PC"), or by hand.
# Output lines for the app: "STEP n/N text", "INFO key=value",
# "RESULT OK <version>" / "RESULT CHECKED" / "RESULT FAIL <CODE> <text>".
#
# Published in RobologAutomation/AFS_PC_Releases (install.sh), next to the
# packages it installs. Packages are installed only with a valid Ed25519
# signature of the AFS release key.

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
WORK=/tmp/afs-install
TOTAL=8

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

old_units() { systemctl list-unit-files --no-legend 'afsd*' 2>/dev/null | awk '{print $1}'; }

# The old AFS application (afsd, Dart) and old bench tools: everything of it on disk.
old_files() {
    for p in /opt/afsd /etc/afsd /usr/local/bin/afsd /var/lib/afsd /var/log/afsd \
             /etc/systemd/system/afsd.service /lib/systemd/system/afsd.service; do
        [ -e "$p" ] && echo "$p"
    done
    find /home /root -maxdepth 2 \( -iname 'afsd*' -o -name vegasim -o -name afs-soak -o -name afs-mock \) 2>/dev/null
}

# State of the AFS Controller itself (records, settings, logins) for a fresh start.
own_data() {
    for p in /var/lib/afs /etc/afs; do [ -e "$p" ] && echo "$p"; done
}

# ---------------------------------------------------------------- check only
if [ "$CHECK" = 1 ]; then
    . /etc/os-release 2>/dev/null
    info os "${PRETTY_NAME:-unknown}"
    info arch "$(dpkg --print-architecture 2>/dev/null || uname -m)"
    info hostname "$(hostname)"
    info installed "$(installed_version)"
    info service "$(systemctl is-active afs-controller 2>/dev/null || echo none)"
    info disk_free_mb "$(df -Pm / | awk 'NR==2{print $4}')"
    info old_services "$(old_units | tr '\n' ' ' | sed 's/ *$//')"
    info old_files "$(old_files | tr '\n' ' ' | sed 's/ *$//')"
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
. /etc/os-release 2>/dev/null
case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) ;;
    *) fail UNSUPPORTED_OS "${PRETTY_NAME:-unknown OS}: Ubuntu 22.04 or 24.04 is needed" ;;
esac
[ "$(dpkg --print-architecture)" = amd64 ] || fail UNSUPPORTED_ARCH "$(dpkg --print-architecture)"
free=$(df -Pm / | awk 'NR==2{print $4}')
[ "${free:-0}" -ge 300 ] || fail NO_SPACE "${free} MB free, 300 MB needed"
for c in openssl tar sha256sum systemctl dpkg; do
    command -v "$c" >/dev/null || fail MISSING_TOOL "$c"
done
info os "$PRETTY_NAME"
info installed "$(installed_version)"

step 2 "Backing up existing data"
mkdir -p /var/backups
stamp=$(date +%Y%m%d-%H%M%S)
backup="/var/backups/afs-backup-$stamp.tar.gz"
mkdir -p "$WORK"
journalctl -u 'afs*' --no-pager -o short-iso > "$WORK/journal-afs.txt" 2>/dev/null || true
journalctl -u 'afsd*' --no-pager -o short-iso > "$WORK/journal-afsd.txt" 2>/dev/null || true
paths=""
for p in /etc/NetworkManager/system-connections "$WORK/journal-afs.txt" "$WORK/journal-afsd.txt" \
         $(own_data) $(old_files); do
    [ -e "$p" ] && paths="$paths $p"
done
for u in $(old_units); do
    f=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)
    [ -n "$f" ] && [ -e "$f" ] && paths="$paths $f"
done
if [ -n "$paths" ]; then
    # shellcheck disable=SC2086
    tar czf "$backup" --ignore-failed-read $paths 2>/dev/null
    chmod 0600 "$backup"
    info backup "$backup ($(du -h "$backup" | cut -f1))"
else
    info backup "nothing to back up"
fi

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

step 5 "Removing the old AFS application"
for u in $(old_units); do
    systemctl disable --now "$u" >/dev/null 2>&1
    info stopped "$u"
done
n=0
for p in $(old_files); do
    rm -rf --one-file-system "$p" && n=$((n + 1))
    info removed "$p"
done
systemctl daemon-reload 2>/dev/null
systemctl reset-failed 'afsd*' 2>/dev/null
[ "$n" = 0 ] && info removed "no old AFS application found"

step 6 "Removing the previous AFS Controller"
# A fresh start: package, records, settings and logins go (they are in the
# backup). The network setup stays, so this SSH session keeps working.
if dpkg -s afs-controller >/dev/null 2>&1; then
    apt-get purge -y -q -o DPkg::Lock::Timeout=180 afs-controller > "$WORK/purge.log" 2>&1 ||
        { tail -5 "$WORK/purge.log"; fail REMOVE "the installed AFS Controller could not be removed (delivery in progress?)"; }
    info removed "AFS Controller $(grep -o 'afs-controller ([^)]*)' "$WORK/purge.log" | head -1)"
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
user="${SUDO_USER:-}"
home=$(getent passwd "$user" | cut -d: -f6)
if [ "$SSH_LOCK" = 0 ]; then
    info ssh "password logins kept (--no-ssh-lock)"
elif [ -n "$home" ] && [ -s "$home/.ssh/authorized_keys" ] && [ -d /etc/ssh/sshd_config.d ]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/60-afs-keyonly.conf
    if sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        info ssh "key-only (password logins off)"
    else
        rm -f /etc/ssh/sshd_config.d/60-afs-keyonly.conf
        info ssh "unchanged (sshd rejected the change)"
    fi
else
    # Without a key for this user, locking would shut out all remote access.
    info ssh "password logins kept: no SSH key set up for ${user:-this user}"
fi

rm -rf "$WORK"
echo "RESULT OK $v"
