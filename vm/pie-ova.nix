# Self-contained bootable image from nixpie's nixos-pie config.
# Turns the netboot (tmpfs+squashfs+torrent) config into a normal disk image
# with a bootloader and a real root fs, keeping the graphical PIE desktop.
# Build target: config.system.build.virtualBoxOVA (OVA) or .qcow (qcow2).
# Pinned: a rebuild gives the same system. Bump the rev to follow campus.
{ flake ? "github:epita/nixpie/837363999e9fd7052cf117b440d987743c94a864" }:
let
  nixpie = builtins.getFlake flake;
  base   = nixpie.nixosConfigurations.nixos-pie;

  overridden = base.extendModules {
    modules = [
      ({ config, lib, pkgs, modulesPath, ... }: {
        imports = [
          # provides system.build.virtualBoxOVA + grub + a real root fs on /dev/sda
          "${modulesPath}/virtualisation/virtualbox-image.nix"
        ];

        # 1. Turn OFF netboot: removes tmpfs "/", squashfs .ro-store, overlay
        #    /nix/store, and the grub.enable=false hack. virtualbox-image then
        #    supplies the real ext4 root + grub.
        netboot.enable = lib.mkForce false;

        # 2. Disk big enough for the whole PIE store (measured 40GB) + headroom.
        virtualisation.diskSize = 55 * 1024;   # MiB (was virtualbox.baseImageSize)

        # 3. Standalone/offline: nothing at boot may depend on CRI network.
        cri.users.checkEpitaUserAllowed = lib.mkForce false;
        cri.salt.enable                 = lib.mkForce false;
        cri.sm-inventory-agent.enable   = lib.mkForce false;
        cri.machine-state.enable        = lib.mkForce false;
        cri.node-exporter.enable        = lib.mkForce false;
        cri.idle-shutdown.enable        = lib.mkForce false;
        cri.aria2.enable                = lib.mkForce false;  # campus torrent seeder

        # 4. epita user already exists (cri.users.createEpitaUser, no password).
        #    Autologin into the graphical session.
        services.displayManager.autoLogin = { enable = lib.mkForce true; user = "epita"; };

        # 4b. Guest integration: clipboard, drag-and-drop, auto display resize.
        #     open-vm-tools serves VMware; virtualbox-image.nix already sets
        #     virtualisation.virtualbox.guest.enable for that flavor.
        virtualisation.vmware.guest.enable = true;

        # 4c. First boot: a once-ever welcome (marker persists in /home/epita),
        #     then the AFS offer. afs with no tty runs its zenity flow; already
        #     mounted and cancel both exit silently, so it never nags.
        services.xserver.displayManager.sessionCommands = ''
          ( sleep 3
            if [ ! -e "$HOME/.pie-welcomed" ]; then
              touch "$HOME/.pie-welcomed"
              ${pkgs.zenity}/bin/zenity --info --title="EPITA PIE" --width=360 --text="Local user: epita, no password. Home persists.\nYour EPITA files: the AFS login follows, or run: afs" 2>/dev/null || true
            fi
            afs
          ) >/dev/null 2>&1 &
        '';

        # 5. The man-cache derivation fails inside containers (nixpie known issue).
        documentation.man.cache.enable = lib.mkForce false;

        # 5b. The default VM name is ~90 chars; VBoxManage export builds the temp
        #     disk path from it twice and hits VBOX_E_NOT_SUPPORTED "file name
        #     too long". Give it a short name.
        virtualbox.vmName = lib.mkForce "EPITA-PIE";

        # 5c. The .ova is a tar; VBox names the internal .ovf/.vmdk after the
        #     output fileName (= image.baseName.image.extension). The default
        #     baseName is ~85 chars, so the .ovf entry exceeds tar's 100-char
        #     limit (VERR_TAR_NAME_TOO_LONG). Short baseName -> "epita-pie.ova".
        image.baseName = lib.mkForce "epita-pie";

        # 5d. Usable defaults: the IDE-heavy PIE desktop is unusable on the
        #     builder's stock 1 vCPU / 1536 MB. Ship 6 GB / 4 vCPU (host needs
        #     >6 GB RAM; students can change these at import time).
        virtualbox.memorySize = lib.mkForce 6144;
        virtualbox.params.cpus = 4;
        # image default is 32 MB; VirtualBox recommends 128 for smooth desktops
        virtualbox.params.vram = lib.mkForce 128;

        # 6. `afs`: kinit -> GSSAPI ssh to the gate -> sshfs mount -> apply
        #    ~/afs/.confs, for using your real AFS from home. The real system's
        #    ssh already has GSSAPI configured, so no extra flags are needed here.
        environment.systemPackages = [
          (pkgs.writeShellApplication {
            name = "afs";
            runtimeInputs = with pkgs; [ krb5 sshfs fuse3 coreutils findutils gnugrep procps zenity util-linux ];
            excludeShellChecks = [ "SC2015" "SC2016" "SC2317" ];
            text = builtins.readFile /vm/afs;
          })
        ];
      })
    ];
  };

  ova = overridden.config.system.build.virtualBoxOVA;

  # make-disk-image populates the ext4 in preVM (on the host) with cptofs, which
  # uses LKL: a userspace Linux kernel with a hardcoded ~100MB. That OOMs
  # ("deadlocked on memory") on the PIE store's millions of small files, and
  # there is no memory knob (checked: no flag, no env var). QEMU_OPTS is
  # irrelevant here (it sizes the *separate* later bootloader VM, not cptofs).
  #
  # Fix: bypass cptofs. mke2fs populates the fs natively at creation, on the
  # host, with normal memory. Two surgical single-line patches to the preVM env
  # string: add -d to the mkfs, and turn the now-redundant cptofs invocation
  # into a no-op (`true` swallows its continued args).
  #
  # OWNERSHIP: `mkfs.ext4 -d "$root"` copies the build sandbox's file ownership
  # (nixbld, 30001:30000) into the image, and OpenSSH then refuses to start
  # ("Bad owner or permissions on .../ssh_config.d/...-ssh-proxy.conf"), which
  # breaks `afs` with a misleading "connection reset by peer" (cptofs wrote
  # root-owned files, so the original pipeline never hit this). Under fakeroot
  # every file stats as root:root, so wrapping the mkfs is the whole fix
  # (verified: files land 0:0); no chown pass, no extra disk.
  patchedPreVM = builtins.replaceStrings
    [ "mkfs.ext4 -b 4096 -F -L nixos $diskImage"
      "cptofs -p -P 1" ]
    [ ''${overridden.pkgs.fakeroot}/bin/fakeroot mkfs.ext4 -b 4096 -F -L nixos -d "$root" $diskImage''
      "true -p -P 1" ]
    ova.preVM;
in
  # preVM patch is the real fix; QEMU_OPTS gives the brief bootloader VM some
  # headroom. Both are plain env attrs, so rebuild via derivation(drvAttrs//…),
  # the low-level form (runInLinuxVM strips the override* helpers).
  derivation (ova.drvAttrs // {
    preVM = patchedPreVM;
    QEMU_OPTS = " -m 4096 -object memory-backend-memfd,id=mem,size=4096M,share=on -machine memory-backend=mem";
  })
