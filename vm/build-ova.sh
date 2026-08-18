#!/bin/sh
# Build both EPITA PIE appliances from nixpie's nixos-pie config, offline-friendly:
#   dist/epita-pie-virtualbox.ova  VirtualBox (native: config.system.build.virtualBoxOVA)
#   dist/epita-pie-vmware.ova      VMware     (ovftool round-trip: vmx-15 hardware, NAT)
#   dist/SHA256SUMS
#
# Idempotent: a seeded builder volume and an already-built OVA are reused; only
# missing work runs. Re-runnable safely. Needs docker; the VMware step also needs
# VMware's ovftool on the host (skipped with a warning if absent).
#
# Disk budget: ~80 GB free. The seeded PIE store (~74 GB) lives in a docker volume;
# assembly adds a ~55 GB raw image + a ~13 GB OVA transiently.
# Time budget (NVMe, warm cache): seed ~30 min, OVA build 1-3 h, ovftool ~20 min.
set -eu

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SELF/.." && pwd)
SEED_IMG="${PIE_SEED_IMG:-nixos-pie-vm:latest}"   # image whose /nix (store+DB) we reuse
VOL="${PIE_NIX_VOL:-pie-ova-store}"               # dedicated builder volume
BUILDER="${PIE_BUILDER_IMG:-nixos/nix:latest}"    # sandboxed nix builder (nixbld + CA baked in)
OUT="$ROOT/dist"
NIX_CFG="experimental-features = nix-command flakes
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="

# marker output: [*] step  [+] done  [!] warn  [x] fatal
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
  G='\033[1;32m'; Y='\033[33m'; R='\033[31m'; N='\033[0m'
else G=''; Y=''; R=''; N=''; fi
say()  { printf "${G}[*]${N} %s\n" "$1"; }
ok()   { printf "${G}[+]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N} %s\n" "$1" >&2; }
die()  { printf "${R}[x]${N} %s\n" "$1" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"
mkdir -p "$OUT"

avail=$(df -Pk "$OUT" | awk 'NR==2 {print int($4/1048576)}')
[ "${avail:-0}" -ge 70 ] || warn "only ${avail:-?} GB free; ~80 GB recommended for assembly"

docker volume create "$VOL" >/dev/null

# 1. Seed the builder store (idempotent). nixos-pie-vm carries a populated nix DB;
#    copying its /nix/store + /nix/var/nix/db makes every PIE path valid, so only the
#    changed toplevel + image tooling build, and the rest comes from cache.nixos.org.
if docker run --rm -v "$VOL":/nix "$BUILDER" \
     sh -c '[ -e /nix/var/nix/db/db.sqlite ] && [ "$(ls /nix/store | wc -l)" -gt 1000 ]' 2>/dev/null; then
  ok "builder store already seeded ($VOL)"
else
  say "seeding $VOL from $SEED_IMG /nix (store + DB; ~74 GB, ~30 min)"
  cid=$(docker create "$SEED_IMG" true)
  docker export "$cid" | docker run --rm -i --privileged -v "$VOL":/nix "$BUILDER" \
    sh -c 'cd / && tar -xf - nix/store nix/var/nix/db 2>/dev/null'
  docker rm "$cid" >/dev/null
  ok "seeded"
fi

# 2. Build the VirtualBox OVA (sandboxed = reproducible: it uses the seeded store
#    instead of rebuilding paths non-deterministically). In-container we first
#    register the few gitlab-only tools cache cannot serve (their source is
#    unreachable), then self-heal a stale/empty nixos-ova output the seed may ship.
say "building VirtualBox OVA (sandboxed; only the delta builds; 1-3 h)"
docker rm -f pie-ova-build >/dev/null 2>&1 || true   # leftover from a killed run
docker run --rm --privileged --name pie-ova-build \
  -v "$VOL":/nix -v "$SELF":/vm:ro -v "$OUT":/out \
  -e NIX_CONFIG="$NIX_CFG" "$BUILDER" sh -eu -c '
    reg=0
    for d in /nix/store/*-*; do
      case "$d" in *.drv|*.lock|*.chroot*) continue ;; esac
      [ -e "$d" ] || continue
      nix-store --check-validity "$d" 2>/dev/null && continue          # already valid
      nix path-info --store https://cache.nixos.org "$d" >/dev/null 2>&1 && continue  # cache serves it
      printf "%s\n\n0\n" "$d" | nix-store --register-validity 2>/dev/null && reg=$((reg+1)) || true
    done
    echo "  registered $reg offline-only path(s)"
    build() { nix build --impure --no-link --print-out-paths --expr "import /vm/pie-ova.nix {}"; }
    out=$(build)
    if ! ls "$out"/*.ova >/dev/null 2>&1; then     # seed shipped an empty output registered valid
      echo "  stale empty output; dropping and rebuilding"
      nix store delete "$out" 2>/dev/null || nix-store --delete "$out" 2>/dev/null || true
      out=$(build)
    fi
    cp -f "$out"/*.ova /out/epita-pie-virtualbox.ova
  ' || die "VirtualBox OVA build failed"
[ -s "$OUT/epita-pie-virtualbox.ova" ] || die "epita-pie-virtualbox.ova not produced"
ok "VirtualBox OVA -> dist/epita-pie-virtualbox.ova"

# 3. VMware OVA (host, needs ovftool). Converting the VBox OVA directly keeps a
#    virtualbox-2.2 descriptor VMware rejects; round-trip through a VMX so ovftool
#    re-authors the hardware (vmx-15), then fix the NIC back to NAT (ovftool defaults
#    a new VMX NIC to bridged) and export a conformant OVA.
if command -v ovftool >/dev/null 2>&1; then
  say "building VMware OVA (ovftool round-trip: vmx-15, NAT; ~20 min)"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  ovftool --lax --overwrite --allowExtraConfig "$OUT/epita-pie-virtualbox.ova" "$tmp/EPITA-PIE.vmx" >/dev/null 2>&1 \
    || die "ovftool OVA->VMX failed"
  sed -i 's/virtualhw.version = "[0-9]*"/virtualhw.version = "15"/;
          s/ethernet0.connectionType = "bridged"/ethernet0.connectionType = "nat"/' "$tmp/EPITA-PIE.vmx"
  ovftool --overwrite --targetType=OVA "$tmp/EPITA-PIE.vmx" "$OUT/epita-pie-vmware.ova" >/dev/null 2>&1 \
    || die "ovftool VMX->OVA failed"
  rm -rf "$tmp"; trap - EXIT
  ok "VMware OVA -> dist/epita-pie-vmware.ova"
else
  warn "ovftool not on host; skipping VMware OVA (VirtualBox OVA is complete)"
fi

# 4. Checksums for the artifacts that exist.
( cd "$OUT" && sha256sum epita-pie-virtualbox.ova epita-pie-vmware.ova 2>/dev/null > SHA256SUMS ) || true
ok "checksums -> dist/SHA256SUMS"
say "done"
