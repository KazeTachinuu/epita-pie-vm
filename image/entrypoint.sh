#!/bin/sh
# PIE desktop session: home-wipe (afs-safe) -> Xvnc -> i3 -> afs.
# Serves plain VNC on :5901; connect a native client (remote-viewer / built-in).
set -eu
export HOME=/home/pie USER=pie
export FONTCONFIG_FILE=/etc/fonts/fonts.conf
# nixpie sets TERMINAL=alacritty, but alacritty needs GPU/EGL that a software
# VNC desktop lacks (no mesa here either) -> it won't start. urxvt is GPU-less,
# instant over VNC, and honors the kit's URxvt Xresources font.
export DISPLAY=:1 TERMINAL=urxvt
export KRB5CCNAME=FILE:/tmp/krb5cc_1000
: "${GEOMETRY:=1440x900}"

mkdir -p "$HOME/.config/i3" /tmp/.X11-unix /var/cache/fontconfig
chmod 1777 /tmp /tmp/.X11-unix 2>/dev/null || true

# campus model: drop a stale AFS mount first, re-check, then wipe home residue
# excluding afs, so we never rm -rf into a live sshfs mount (would delete AFS
# files remotely).
if mountpoint -q "$HOME/afs" 2>/dev/null; then fusermount -u "$HOME/afs" 2>/dev/null || true; fi
mountpoint -q "$HOME/afs" 2>/dev/null || rm -rf "$HOME/afs" 2>/dev/null || true
find "$HOME" -mindepth 1 -maxdepth 1 ! -name afs -exec rm -rf {} + 2>/dev/null || true
mkdir -p "$HOME/.config/i3"

# some terminals open a login shell, which reads .bash_profile (not .bashrc);
# bridge it so the kit config (starship, aliases) loads either way once
# install.sh has linked .bashrc from AFS.
printf '[ -r ~/.bashrc ] && . ~/.bashrc\n' > "$HOME/.bash_profile"

# ship the stock i3 config so i3 never launches i3-config-wizard
[ -f "$HOME/.config/i3/config" ] || cp /etc/pie/i3-config "$HOME/.config/i3/config"

Xvnc :1 -geometry "$GEOMETRY" -depth 24 -SecurityTypes None -AlwaysShared -rfbport 5901 \
    >/tmp/xvnc.log 2>&1 &
xvnc=$!
i=0; while [ ! -e /tmp/.X11-unix/X1 ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done

# the three commands nixpie runs before i3, reproduced verbatim
setxkbmap us,fr,gb 2>/dev/null || true
xrdb -merge /etc/pie/Xresources 2>/dev/null || true
feh --bg-scale /etc/pie/background.jpg 2>/dev/null || true

dbus-daemon --session --address=unix:path=/tmp/dbus.sock >/dev/null 2>&1 &
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus.sock
i3 >/tmp/i3.log 2>&1 &

# backgrounded so Cancel just closes the dialog instead of blocking startup
( sleep 3; afs ) &

# the container lives as long as the VNC server; connect a native client to :5901
wait "$xvnc"
