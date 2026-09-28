#!/bin/sh
# afs-test.sh [afs-script]: the "reconnect the next day" regression, in the
# afs-lab.sh gate. Default script: vm/afs. Root; run `afs-lab.sh setup` first.
#
# 1. mount, as in the PIE session: DISPLAY set and SSH_ASKPASS exported (NixOS
#    does that whenever X is on); here the askpass never answers, like an
#    x11-ssh-askpass window lost behind the desktop
# 2. "a day passes": the link black-holes, the ticket expires, the link returns
# 3. something touches ~/afs (a terminal, i3bar...), then `afs` again: it must
#    remount within 90s, on a fresh sshfs, with nothing left waiting on askpass
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${1:-$HERE/../vm/afs}
LIFE_S=${LIFE_S:-120}
AFS=/tmp/afs-under-test ASKPASS=/tmp/afs-test-askpass

cp "$SCRIPT" "$AFS"; chmod 755 "$AFS"
printf '#!/bin/sh\nexec sleep 100000\n' >"$ASKPASS"; chmod 755 "$ASKPASS"
chmod 666 /dev/fuse

as_epita() {
  su epita -s /bin/sh -c "export DISPLAY=:0 SSH_ASKPASS=$ASKPASS; $1"
}
reset() {
  su epita -s /bin/sh -c 'fusermount3 -uz ~/afs' 2>/dev/null || true
  pkill -9 -u epita -x sshfs 2>/dev/null || true
  pkill -9 -u epita -x ssh 2>/dev/null || true
  pkill -9 -u epita -x sleep 2>/dev/null || true
  "$HERE/afs-lab.sh" heal
}
# live ones only: zombies linger where PID 1 does not reap (containers)
live() { ps -u epita -o pid=,stat=,comm= | awk -v c="$1" '$2 !~ /Z/ && $3 == c { print $1 }'; }
die() { echo "FAIL: $1" >&2; ps -o pid,stat,wchan:22,args -u epita >&2 || true; reset; exit 1; }

reset
echo "== 1. first mount"
as_epita "kdestroy 2>/dev/null; printf 'xlogin\npw\n' | $AFS" >/dev/null 2>&1 || die "first mount failed"
as_epita 'timeout 10 cat ~/afs/hello.txt' >/dev/null || die "first mount unreadable"
old=$(live sshfs)

echo "== 2. a day passes (link cut ${LIFE_S}s + ticket expired)"
"$HERE/afs-lab.sh" cut
sleep $((LIFE_S + 20))
"$HERE/afs-lab.sh" heal
as_epita 'kdestroy 2>/dev/null' || true

echo "== 3. reconnect"
as_epita '(timeout 30 ls ~/afs >/dev/null 2>&1 &)'; sleep 3
# poll, don't wait: a process stuck on the old mount is unkillable (D state)
log=$(mktemp); rcf=$(mktemp); t0=$(date +%s)
( as_epita "printf 'xlogin\npw\n' | $AFS" >"$log" 2>&1; echo $? >"$rcf" ) &
while [ ! -s "$rcf" ] && [ $(($(date +%s) - t0)) -lt 90 ]; do sleep 1; done
dt=$(($(date +%s) - t0))
sed 's/^/   | /' "$log"
[ -s "$rcf" ] || die "afs still hanging after ${dt}s"
rc=$(cat "$rcf"); rm -f "$log" "$rcf"
echo "   afs exit=$rc after ${dt}s"
[ "$rc" -eq 0 ] || die "afs exited $rc"
as_epita 'timeout 10 cat ~/afs/hello.txt' >/dev/null || die "remount unreadable"
new=$(live sshfs)
[ -n "$new" ] && [ "$new" != "$old" ] || die "still the old sshfs ($old), not a fresh mount"
[ "$(live sshfs | wc -l)" -eq 1 ] || die "leftover sshfs processes"
! pgrep -u epita -f "$ASKPASS|sleep 100000" >/dev/null || die "something is waiting on an askpass prompt"
reset
echo "PASS"
