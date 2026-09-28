#!/bin/sh
# Hotfix `afs` on an installed VM, no root, no rebuild:
#   curl -fsSL https://raw.githubusercontent.com/KazeTachinuu/epita-pie-vm/master/vm/hotfix.sh | sh
# Installs the current vm/afs into ~/.nix-profile/bin, which NixOS puts
# before /run/current-system/sw/bin in PATH; /home/epita persists.
# Undo: rm ~/.nix-profile/bin/afs (do it after moving to a newer OVA).
set -eu

URL=https://raw.githubusercontent.com/KazeTachinuu/epita-pie-vm/master/vm/afs
SYS=/run/current-system/sw/bin/afs

# first per-user profile on PATH that nix does not manage (those are symlinks)
bin=
for d in "$HOME/.nix-profile" "$HOME/.local/state/nix/profile"; do
  [ -L "$d" ] || { bin=$d/bin; break; }
done
[ -n "$bin" ] || { echo "hotfix: no free profile dir on PATH" >&2; exit 1; }
mkdir -p "$bin"

new=$(mktemp)
curl -fsSL "$URL" >"$new.body"
sh -n "$new.body"
# keep the baked afs's PATH line: its tools (zenity, sshfs, krb5) by store path
{ echo '#!/bin/sh'
  grep -m1 '^export PATH=' "$(readlink -f "$SYS")" || true
  sed 1d "$new.body"; } >"$new"
rm -f "$new.body"
chmod 755 "$new"
mv "$new" "$bin/afs"

case "$(command -v afs)" in
  "$bin/afs") echo "afs fixed ($bin/afs). Stuck ~/afs: afs off, then afs" ;;
  *) echo "afs fixed ($bin/afs); open a new terminal to use it" ;;
esac
