#!/bin/sh
# Offline seed build: assemble pie-desktop:latest by reusing the store already
# inside nixos-pie:latest and injecting only the desktop-extras delta, built
# with nixpie's own pkgs and substituted from cache.nixos.org (no EPITA cache).
#
# Host needs only docker. All nix work runs inside a privileged nixos/nix
# container against a persistent -v pie-nix-store:/nix volume. Prototype driver;
# paths are discovered at runtime and spliced into a generated Dockerfile.
set -eu

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE=nixos-pie:latest
IMG=pie-desktop:latest
NIXPIE="${PIE_NIXPIE:-github:epita/nixpie}"
# base image's system-path (its /bin holds gcc/clang/gdb and the rest)
SYSPATH="${PIE_SYSPATH:-/nix/store/zi7dapjjfx190833rmg4xwj0v950jxsg-system-path}"
# build context on real disk (the store tar can be tens of MB; keep off tmpfs)
BD="${PIE_BUILDDIR:-$HOME/.cache/pie-seed}"

# cache.nixos.org ONLY -- proves the extras need no EPITA cache.
NIX_CFG="experimental-features = nix-command flakes
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="

mkdir -p "$BD"

# 1. build the extras seed, emit its full runtime closure + the env store path.
docker run --rm --privileged \
    -v pie-nix-store:/nix -v "$SELF:/image:ro" -v "$BD:/out" \
    -e NIX_CONFIG="$NIX_CFG" \
    nixos/nix:latest sh -c '
        set -eu
        out=$(nix build --impure --no-link --print-out-paths \
            --expr "import /image/extras.nix { flake = \"'"$NIXPIE"'\"; }")
        cp "$out/env-path" /out/env-path
        rm -rf /out/etc && cp -r "$out/etc" /out/etc
        nix-store -qR "$out" > /out/closure.txt
    '
ENVPATH=$(cat "$BD/env-path")

# 2. delta = closure paths whose basename is not already in the base image.
docker run --rm --entrypoint "$SYSPATH/bin/ls" "$BASE" -1 /nix/store \
    | sort > "$BD/base-names.txt"
while read -r p; do basename "$p"; done < "$BD/closure.txt" | sort > "$BD/closure-names.txt"
comm -23 "$BD/closure-names.txt" "$BD/base-names.txt" \
    | sed 's#^#/nix/store/#' > "$BD/new-paths.txt"
echo "injecting $(wc -l < "$BD/new-paths.txt") new store paths (of $(wc -l < "$BD/closure.txt") in closure)"

# 3. tar just the delta, entries relative to / (nix/store/...).
docker run --rm --privileged -v pie-nix-store:/nix -v "$BD:/out" \
    nixos/nix:latest sh -c 'cd / && tar -cf /out/store.tar --numeric-owner -T /out/new-paths.txt'

# 4. stage context + generated Dockerfile, then build FROM the base.
cp "$SELF/entrypoint.sh" "$BD/entrypoint.sh"
cat > "$BD/Dockerfile" <<EOF
FROM $BASE
ADD store.tar /
COPY etc /etc
COPY entrypoint.sh /entrypoint.sh
ENV PATH=$ENVPATH/bin:$SYSPATH/bin:/bin:/usr/bin \\
    FONTCONFIG_FILE=/etc/fonts/fonts.conf \\
    HOME=/home/pie USER=pie DISPLAY=:1 \\
    KRB5CCNAME=FILE:/tmp/krb5cc_1000
EXPOSE 5901
WORKDIR /home/pie
ENTRYPOINT ["$ENVPATH/bin/bash", "/entrypoint.sh"]
EOF

docker build -t "$IMG" "$BD"
echo "built $IMG (base store reused; ${ENVPATH}/bin on PATH)"
