# Offline seed: build the desktop extras with nixpie's OWN pkgs so their
# runtime deps are byte-identical to the base image's store paths, then let
# `docker build FROM nixos-pie:latest` overlay just these into the existing
# store. Substituted from cache.nixos.org only (public nixpkgs); no EPITA cache.
{ flake ? "github:epita/nixpie" }:
let
  nixpie = builtins.getFlake flake;
  base   = nixpie.nixosConfigurations.nixos-pie;
  pkgs   = base.pkgs;
  lib    = pkgs.lib;

  afs = pkgs.writeShellApplication {
    name = "afs";
    # no openssh here: the base ships openssh-with-gssapi, and `afs` finds it via
    # `command -v ssh`. A plain openssh would shadow it and break AFS (kinit works
    # but the GSSAPI handshake to the gate fails -> "connection reset by peer").
    runtimeInputs = with pkgs; [ krb5 sshfs fuse3 coreutils findutils gnugrep procps zenity util-linux ];
    # same script as the VM (build-seed.sh mounts vm/ at /vm)
    text = builtins.readFile /vm/afs;
    excludeShellChecks = [ "SC2015" "SC2016" "SC2317" ];
  };

  extras = (with pkgs; [
    tigervnc                       # Xvnc = X server + VNC; connect a native client
    i3 feh dejavu_fonts alacritty
    sshfs krb5 zenity
    bashInteractive coreutils util-linux
    mesa libglvnd                  # software GL/EGL (llvmpipe) so alacritty renders under VNC
  ]) ++ [ afs ];

  env = pkgs.buildEnv {
    name = "pie-extras";
    paths = extras;
    pathsToLink = [ "/bin" "/etc" "/share" "/lib" ];
    ignoreCollisions = true;
  };

  wallpaper   = "${nixpie}/modules/services/x11/files/background.jpg";
  i3config    = "${pkgs.i3}/etc/i3/config";
  # makeFontsConf's output <include>s /etc/fonts/conf.d, which we don't ship, so
  # the generic-family priority lists never load and `monospace` mis-resolves to
  # FreeMono. Ship a self-contained conf that pins the generics to DejaVu (as
  # campus does) and pulls fontconfig's rendering defaults straight from the store.
  fontsConf   = pkgs.writeText "fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <dir>${pkgs.dejavu_fonts}</dir>
      <dir>${pkgs.freefont_ttf}</dir>
      <cachedir>/var/cache/fontconfig</cachedir>
      <include ignore_missing="yes">${pkgs.fontconfig.out}/etc/fonts/conf.d</include>
      <match target="pattern"><test name="family"><string>monospace</string></test>
        <edit name="family" mode="prepend" binding="strong"><string>DejaVu Sans Mono</string></edit></match>
      <match target="pattern"><test name="family"><string>sans-serif</string></test>
        <edit name="family" mode="prepend" binding="strong"><string>DejaVu Sans</string></edit></match>
      <match target="pattern"><test name="family"><string>serif</string></test>
        <edit name="family" mode="prepend" binding="strong"><string>DejaVu Serif</string></edit></match>
    </fontconfig>
  '';
  xresources  = pkgs.writeText "Xresources" ''
    *foreground: #ffffff
    *background: #000000
    *color12:    #2ca2f5
    URxvt.font:  xft:DejaVu Sans Mono:pixelsize=10
  '';

  etcLayer = pkgs.runCommand "pie-etc" { } ''
    mkdir -p $out/etc/fonts $out/etc/pie
    cp ${fontsConf}  $out/etc/fonts/fonts.conf
    cp ${wallpaper}  $out/etc/pie/background.jpg
    cp ${xresources} $out/etc/pie/Xresources
    sed 's/Mod1/Mod4/g' ${i3config} > $out/etc/pie/i3-config  # PIE uses Super (Mod4), not Alt
    printf 'root:x:0:0:root:/root:/bin/bash\npie:x:1000:1000:pie:/home/pie:/bin/bash\n' > $out/etc/passwd
    printf 'root:x:0:\npie:x:1000:\n' > $out/etc/group
    printf 'passwd: files\ngroup: files\nhosts: files dns\n' > $out/etc/nsswitch.conf
    cat > $out/etc/krb5.conf <<'EOF'
    [libdefaults]
        default_realm = CRI.EPITA.FR
        default_ccache_name = FILE:/tmp/krb5cc_%{uid}
        dns_lookup_kdc = true
    [realms]
        CRI.EPITA.FR = { }
    EOF
  '';

  # Single closure root: contains real /etc files at $out/etc and the extras
  # env symlink at $out/env (its /bin is what goes on PATH). nix-store -qR on
  # this covers every store path we must inject into the base image.
  seed = pkgs.runCommand "pie-seed" { passthru = { inherit env etcLayer; }; } ''
    mkdir -p $out
    ln -s ${env} $out/env
    cp -r ${etcLayer}/etc $out/etc
    chmod -R u+w $out/etc
    printf '%s\n' "${env}"      > $out/env-path
    printf '%s\n' "${etcLayer}" > $out/etc-path
  '';
in
  seed
