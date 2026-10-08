#!/bin/sh
# afs-errors.sh [afs-script]: every failure path of `afs` in the afs-lab.sh gate:
# the message the user sees, the exit status, and that nothing hangs.
# Root, after afs-lab.sh. Default script: vm/afs.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${1:-$HERE/../vm/afs}
AFS=/tmp/afs-under-test
GATE=ssh.cri.epita.fr
cp "$SCRIPT" "$AFS"; chmod 755 "$AFS"
chmod 666 /dev/fuse

pass=0 failed=0
check() {  # check NAME CONDITION...: report one expectation
  name=$1; shift
  if "$@"; then pass=$((pass + 1)); echo "  ok    $name"
  else failed=$((failed + 1)); echo "  FAIL  $name"; sed 's/^/        | /' "$out"; fi
}
has() { grep -qF -- "$1" "$out"; }
reset() {
  su epita -s /bin/sh -c 'fusermount3 -uz ~/afs 2>/dev/null; kdestroy 2>/dev/null' || true
  pkill -9 -u epita -x sshfs 2>/dev/null; pkill -9 -u epita -x ssh 2>/dev/null; true
}
# run afs as epita, no tty (terminal flow, no zenity): input on stdin
out=/tmp/afs-out rc=0 dt=0
run() {  # run INPUT [ARGS]
  t0=$(date +%s)
  printf '%b' "$1" | su epita -s /bin/sh -c "timeout 150 $AFS ${2:-}" >"$out" 2>&1
  rc=$?; dt=$(($(date +%s) - t0))
}
principal() {  # principal NAME [OPTS]: like EPITA's, preauth required; reset if it exists
  kadmin.local -q "addprinc +requires_preauth ${2:-} -pw pw $1" 2>&1 | grep -q "already exists" \
    && kadmin.local -q "modprinc +requires_preauth -unlock ${2:-} $1" >/dev/null 2>&1; true
}
mounted() { grep -qs " /home/epita/afs fuse" /proc/mounts; }

principal nohome; id nohome >/dev/null 2>&1 || useradd -m -s /bin/sh nohome
principal nogate                                  # no unix account on the gate
kadmin.local -q "addpol -maxfailure 2 -lockoutduration 1h lockpol" >/dev/null 2>&1 || true
principal locked "-policy lockpol"

echo "== 1. wrong password, then right"
reset; run 'xlogin\nbad\nxlogin\npw\n'
check "reason + tries left"        has "wrong password (2 tries left)"
check "then mounts"                mounted
check "says ready"                 has "you can start working"
check "exit 0"                     [ "$rc" -eq 0 ]

echo "== 2. afs off, then afs: ticket reused, no password"
su epita -s /bin/sh -c "$AFS off" >/dev/null 2>&1
run ''
check "still-valid ticket"         has "(still valid)"
check "mounted again"              mounted
check "exit 0"                     [ "$rc" -eq 0 ]

echo "== 3. three wrong passwords"
reset; run 'xlogin\nbad1\nxlogin\nbad2\nxlogin\nbad3\n'
check "final reason"               has "Login failed: wrong password"
check "1 try left shown"           has "(1 tries left)"
check "exit 1, not mounted"        sh -c "[ $rc -eq 1 ] && ! grep -qs ' /home/epita/afs fuse' /proc/mounts"

echo "== 4. unknown login"
reset; run 'nosuchuser\npw\n\n'
check "unknown login"              has "unknown login"

echo "== 5. account locked by the KDC: stop at once"
reset; run 'locked\nbad\nlocked\nbad\n\n'
reset; run 'locked\npw\nlocked\npw\nlocked\npw\n'
check "account locked"             has "account locked"
check "no retry (1 attempt)"       sh -c "[ \$(grep -c 'password:' $out) -eq 1 ]"
check "exit 1"                     [ "$rc" -eq 1 ]
kadmin.local -q "modprinc -unlock locked" >/dev/null 2>&1

echo "== 6. KDC unreachable: stop at once"
reset; pkill -x krb5kdc; sleep 1
run 'xlogin\npw\nxlogin\npw\nxlogin\npw\n'
check "cannot reach EPITA"         has "cannot reach EPITA"
check "no retry (1 attempt)"       sh -c "[ \$(grep -c 'password:' $out) -eq 1 ]"
check "fast (<30 s)"               [ "$dt" -lt 30 ]
krb5kdc

echo "== 7. gate unreachable"
reset; cp /etc/hosts /tmp/hosts.bak
sed "s/^127.0.0.1 $GATE/10.255.255.1 $GATE/" /tmp/hosts.bak >/tmp/hosts.new; cat /tmp/hosts.new >/etc/hosts
run 'xlogin\npw\n'
cat /tmp/hosts.bak >/etc/hosts
check "cannot reach the gate"      has "cannot reach ssh.cri.epita.fr"
check "exit 1, under 2.5 min"      sh -c "[ $rc -eq 1 ] && [ $dt -lt 150 ]"

echo "== 8. gate refuses the login"
reset; run 'nogate\npw\n'
check "gate refused"               has "the EPITA gate refused your login"
check "exit 1"                     [ "$rc" -eq 1 ]

echo "== 9. no AFS home"
reset; run 'nohome\npw\n'
check "no AFS home"                has "no AFS home found for nohome"
check "exit 1"                     [ "$rc" -eq 1 ]

echo "== 10. install.sh fails: warn, stay mounted"
reset; c=/afs/cri.epita.fr/user/x/xl/xlogin/u/.confs
printf '#!/bin/sh\nexit 3\n' >"$c/install.sh"; chmod 755 "$c/install.sh"; chown xlogin "$c/install.sh"
run 'xlogin\npw\n'
rm -f "$c/install.sh"
check "warning with exit code"     has "install.sh failed (exit 3)"
check "still mounted, exit 0"      sh -c "[ $rc -eq 0 ] && grep -qs ' /home/epita/afs fuse' /proc/mounts"

echo "== 11. GUI flow (zenity stand-in: logs each dialog, answers from a script)"
reset; z=/tmp/zstub; mkdir -p $z; rm -f $z/log
printf 'xlogin/bad\nxlogin/pw\n' >$z/answers
cat >$z/zenity <<'EOF'
#!/bin/sh
# record the dialog; --forms answers from the script; --progress drains stdin
z=/tmp/zstub kind=$1
text=$(printf '%s\n' "$@" | sed -n 's/^--text=//p' | tr '\n' ' ')
echo "$kind | $text" >>$z/log
case $kind in
  --forms) a=$(head -1 $z/answers); sed -i 1d $z/answers; [ -n "$a" ] && echo "$a" ;;
  --progress) cat >/dev/null ;;
esac
EOF
chmod 755 $z/zenity; chmod -R a+rwX $z
su epita -s /bin/sh -c "PATH=$z:\$PATH DISPLAY=:0 timeout 150 $AFS" </dev/null >/dev/null 2>&1
rc=$?; sleep 1; cp $z/log "$out"
check "reason shown in the form"   has "--forms | Login failed: wrong password (2 tries left)"
check "progress window"            has "--progress | Connecting to AFS..."
check "ready dialog"               has "you can start working"
check "final dialog"               has "Your configs are applied"
check "no error dialog, exit 0"    sh -c "! grep -q -- '--error' $out && [ $rc -eq 0 ]"

reset
echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
