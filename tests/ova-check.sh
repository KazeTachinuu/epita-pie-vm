#!/bin/sh
# ova-check.sh OVA...: check built OVAs without booting them.
#   - manifest (.mf) matches the files
#   - the disk's /nix/store holds vm/afs as `afs`, with grep + pkill on its PATH
#   - store files are root-owned (sandbox uids break OpenSSH, hence `afs`)
# Root (losetup); needs tar, qemu-img, debugfs (e2fsprogs), sfdisk.
# SAVE_AFS=path: also keep the baked afs (e.g. for tests/afs-test.sh).
set -eu

AFS=$(cd "$(dirname "$0")/.." && pwd)/vm/afs
ok()   { printf '[+] %s\n' "$1"; }
fail() { printf '[x] %s\n' "$1" >&2; rc=1; }
rc=0
body() { sed -n '/^#!\/bin\/sh$/,$p' "$1" | sed 1d; }   # script after its own #!/bin/sh

# on disk, not /tmp: the raw disk image is ~55 GB (sparse)
t=$(mktemp -d "${TMPDIR:-/var/tmp}/ova-check.XXXXXX")
loop=
trap '[ -z "$loop" ] || losetup -d "$loop"; rm -rf "$t"' EXIT
checked=
for ova; do
  echo "== $ova"
  rm -rf "$t/x"; mkdir "$t/x"; tar -xf "$ova" -C "$t/x"
  # "SHA1 (f) = h" (VirtualBox) or "SHA256(f)= h" (VMware)
  if ( cd "$t/x"; n=0
       sed -n 's/^SHA\([0-9]*\) *(\(.*\)) *= *\([0-9a-f]*\).*$/\1 \3 \2/p' ./*.mf >../sums
       while read -r alg sum f; do
         echo "$sum  $f" | "sha${alg}sum" -c --quiet || exit 1; n=$((n + 1))
       done <../sums
       [ "$n" -ge 2 ] )
  then ok "manifest"; else fail "manifest"; fi
  vmdk=$(ls "$t"/x/*.vmdk)
  sum=$(sha256sum "$vmdk" | cut -d' ' -f1)
  case " $checked " in *" $sum "*) ok "disk identical to one already checked"; continue ;; esac

  qemu-img convert -O raw "$vmdk" "$t/disk.raw"
  start=$(sfdisk -d "$t/disk.raw" | sed -n 's/.*start= *\([0-9]*\).*/\1/p' | head -1)
  loop=$(losetup -r -o $((start * 512)) -f --show "$t/disk.raw")
  dbg() { debugfs -R "$1" "$loop" 2>/dev/null; }

  store=$(dbg "ls /nix/store" | tr -s ' ' '\n' | grep -E '^[a-z0-9]{32}-afs$' | head -1)
  if [ -z "$store" ]; then fail "no afs in /nix/store"; else
    dbg "cat /nix/store/$store/bin/afs" >"$t/afs"
    if [ "$(body "$t/afs")" = "$(body "$AFS")" ]; then ok "afs = vm/afs ($store)"
    else fail "afs differs from vm/afs"; fi
    [ -z "${SAVE_AFS:-}" ] || cp "$t/afs" "$SAVE_AFS"
    path=$(grep -m1 '^export PATH=' "$t/afs" || true)
    for p in gnugrep procps sshfs krb5 zenity; do
      case "$path" in *"-$p-"*) ;; *) fail "afs PATH lacks $p" ;; esac
    done
    uid=$(dbg "stat /nix/store/$store/bin/afs" | sed -n 's/.*User: *\([0-9]*\).*/\1/p')
    if [ "$uid" = 0 ]; then ok "store root-owned"; else fail "store owned by uid $uid"; fi
  fi
  losetup -d "$loop"; loop=; rm -f "$t/disk.raw"
  checked="$checked $sum"
done
[ "$rc" -eq 0 ] && echo PASS || echo FAIL
exit "$rc"
