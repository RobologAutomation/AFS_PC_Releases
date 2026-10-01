#!/bin/bash
# AFS Controller installer for an Ubuntu mini-PC.
#
#   sudo bash install.sh            back up, clean, download, verify, install
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
TOTAL=7

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
paths=""
for p in /var/lib/afs /etc/afs /etc/NetworkManager/system-connections "$WORK/journal-afs.txt"; do
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

step 3 "Stopping old services"
n=0
for u in $(old_units); do
    systemctl disable --now "$u" >/dev/null 2>&1 && n=$((n + 1))
    info stopped "$u"
done
[ "$n" = 0 ] && info stopped none

step 4 "Getting the software"
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

step 5 "Checking the signature"
if [ -n "$want" ]; then
    got=$(sha256sum "$WORK/pkg.deb" | cut -d' ' -f1)
    [ "$got" = "$want" ] || fail BAD_HASH "SHA-256 differs from the release list"
fi
printf '%s\n' "$PUBKEY" > "$WORK/release.pub"
openssl pkeyutl -verify -pubin -inkey "$WORK/release.pub" -rawin -in "$WORK/pkg.deb" \
    -sigfile "$WORK/pkg.deb.sig" >/dev/null 2>&1 || fail BAD_SIGNATURE "not signed by the AFS release key"
info signature ok

step 6 "Installing the software"
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

step 7 "Securing SSH"
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
