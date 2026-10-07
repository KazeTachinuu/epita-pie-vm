#!/bin/sh
# Hotfix `afs` on an installed VM, no root, no rebuild:
#   curl -fsSL https://raw.githubusercontent.com/KazeTachinuu/epita-pie-vm/master/vm/hotfix.sh | sh
# Installs the current vm/afs into ~/.nix-profile/bin, which NixOS puts
# before /run/current-system/sw/bin in PATH; /home/epita persists.
# Safe to re-run; a no-op once the VM's own afs is current.
set -eu

URL=https://raw.githubusercontent.com/KazeTachinuu/epita-pie-vm/master/vm/afs
SYS=$(readlink -f /run/current-system/sw/bin/afs 2>/dev/null || true)

# first per-user profile on PATH that nix does not manage (those are symlinks)
bin=
for d in "$HOME/.nix-profile" "$HOME/.local/state/nix/profile"; do
  [ -L "$d" ] || { bin=$d/bin; break; }
done
[ -n "$bin" ] || { echo "hotfix: no free profile dir on PATH" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" >"$tmp/body"
sh -n "$tmp/body"

# the baked copy is the same script under a nix header
body() { sed -n '/^#!\/bin\/sh$/,$p' "$1" | sed 1d; }
if [ -f "$SYS" ] && [ "$(body "$SYS")" = "$(body "$tmp/body")" ]; then
  rm -f "$bin/afs"; echo "afs already up to date"; exit 0
fi

# keep the baked afs's PATH line: its tools (zenity, sshfs, krb5) by store path
{ echo '#!/bin/sh'
  [ -f "$SYS" ] && grep -m1 '^export PATH=' "$SYS" || true
  sed 1d "$tmp/body"; } >"$tmp/afs"
chmod 755 "$tmp/afs"
mkdir -p "$bin"
mv "$tmp/afs" "$bin/afs"

case "$(command -v afs)" in
  "$bin/afs") echo "afs fixed. Stuck ~/afs: afs off, then afs" ;;
  *) echo "afs fixed; open a new terminal to use it" ;;
esac
