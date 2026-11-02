# Tests in: nixos/tests/ec2-image.nix
{
  config,
  options,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkDefault
    mkIf
    mkMerge
    mkOption
    optionalString
    types
    ;
  inherit (lib.options) literalExpression;
  cfg = config.amazonImage;
  inherit (config.ec2) bootMode;
  inherit (config.boot.loader) grub;
  grubDevices = lib.filter (device: device != "nodev") grub.devices;
  inherit (config.system.build) toplevel;

  configFile = pkgs.writeText "configuration.nix" ''
    { modulesPath, ... }: {
      imports = [ "''${modulesPath}/virtualisation/amazon-image.nix" ];
      ec2.bootMode = "${bootMode}";
      ${optionalString config.ec2.zfs.enable ''
        ec2.zfs.enable = true;
        networking.hostId = "${config.networking.hostId}";
      ''}
    }
  '';

  # Initial contents of root's nixos channel.
  # FIXME: merge with channel.nix / make-channel.nix.
  channelSources = pkgs.runCommand "nixos-${config.system.nixos.version}" { } ''
    mkdir -p $out
    cp -prd ${lib.cleanSource pkgs.path} $out/nixos
    chmod -R u+w $out/nixos
    if [ ! -e $out/nixos/nixpkgs ]; then
      ln -s . $out/nixos/nixpkgs
    fi
    rm -rf $out/nixos/.git
    echo -n ${config.system.nixos.versionSuffix} > $out/nixos/.version-suffix
  '';

  storePaths = [ toplevel ] ++ lib.optional config.nix.channel.enable channelSources;

  autoSize = config.virtualisation.diskSize == "auto";

  # The VM only installs what needs a mounted disk. The raw image is built in
  # the same derivation, so the store never holds an intermediate image.
  repartBuilder = pkgs.vmTools.runInLinuxVM (
    config.image.repart.image.overrideAttrs (previousAttrs: {
      nativeBuildInputs = previousAttrs.nativeBuildInputs ++ [
        (lib.getBin config.nix.package)
        config.system.build.nixos-install
        pkgs.buildPackages.jq
        pkgs.buildPackages.qemu-utils
      ];
      memSize = 1024;
      preVM = ''
        # The phases of repart-image.nix that build the raw image.
        runPhase patchPhase
        runPhase buildPhase
        diskImage=$PWD/${config.image.baseName}.raw
      '';
      postVM = ''
        mkdir -p $out/nix-support
        image=$out/${config.image.fileName}
        ${
          if cfg.format == "raw" then
            "mv $diskImage $image"
          else
            "qemu-img convert -f raw -O ${cfg.format} $diskImage $image"
        }
        echo "file ${cfg.format} $image" >> $out/nix-support/hydra-build-products

        jq -n \
          --arg system_version ${lib.escapeShellArg config.system.nixos.version} \
          --arg system ${lib.escapeShellArg pkgs.stdenv.hostPlatform.system} \
          --arg logical_bytes "$(qemu-img info --output json "$image" | jq '."virtual-size"')" \
          --arg boot_mode "${bootMode}" \
          --arg file "$image" \
           '{}
           | .label = $system_version
           | .boot_mode = $boot_mode
           | .system = $system
           | .logical_bytes = $logical_bytes
           | .file = $file
           | .disks.root.logical_bytes = $logical_bytes
           | .disks.root.file = $file
           ' > $out/nix-support/image-info.json
      '';
      buildCommand = ''
        export HOME=$TMPDIR
        # Nothing is built here, and the VM has no nixbld group.
        export NIX_CONFIG="build-users-group ="
        root=/mnt
        mkdir -p $root
        mount -L nixos $root
        ${optionalString grub.efiSupport ''
          mkdir -p $root${config.boot.loader.efi.efiSysMountPoint}
          mount -L ESP $root${config.boot.loader.efi.efiSysMountPoint}
        ''}

        # The store paths are already in place, so only register them.
        nix-store --store $root --load-db < ${pkgs.closureInfo { rootPaths = storePaths; }}/registration
        nixos-install --root $root --system ${toplevel} ${
          if config.nix.channel.enable then "--channel ${channelSources}" else "--no-channel-copy"
        } \
          --no-bootloader --no-root-passwd --substituters ""

        ${lib.concatMapStrings (device: ''
          mkdir -p "$(dirname ${device})"
          ln -s /dev/vda ${device}
        '') grubDevices}
        for dir in dev proc sys; do
          mkdir -p $root/$dir
          mount --rbind /$dir $root/$dir
        done
        mkdir -p $root/tmp
        mount -t tmpfs tmpfs $root/tmp
        # GRUB needs an mtab.
        ln -s /proc/mounts $root/etc/mtab
        NIXOS_INSTALL_BOOTLOADER=1 chroot $root ${config.system.build.installBootLoader} ${toplevel}
        rm $root/etc/mtab
        umount -R $root
      '';
    })
  );
in
{
  imports = [
    ../../../modules/virtualisation/amazon-image.nix
    ../../../modules/virtualisation/disk-size-option.nix
    ../../../modules/image/file-options.nix
    ../../../modules/image/repart.nix
    (lib.mkRenamedOptionModuleWith {
      sinceRelease = 2411;
      from = [
        "amazonImage"
        "sizeMB"
      ];
      to = [
        "virtualisation"
        "diskSize"
      ];
    })
    (lib.mkRenamedOptionModuleWith {
      sinceRelease = 2505;
      from = [
        "amazonImage"
        "name"
      ];
      to = [
        "image"
        "baseName"
      ];
    })
  ];

  options.amazonImage = {
    contents = mkOption {
      example = literalExpression ''
        [ { source = pkgs.memtest86 + "/memtest.bin";
            target = "boot/memtest.bin";
          }
        ]
      '';
      default = [ ];
      description = ''
        Files to copy to fixed locations in the root filesystem of the image,
        as a list of `source` and `target` pairs.
      '';
    };

    format = mkOption {
      type = types.enum [
        "raw"
        "qcow2"
        "vpc"
      ];
      default = "vpc";
      description = "The image format to output";
    };
  };

  config = mkMerge [
    {
      # Use a priority just below mkOptionDefault (1500) instead of lib.mkDefault
      # to avoid breaking existing configs using that.
      virtualisation.diskSize = lib.mkOverride 1490 (4 * 1024);
      virtualisation.diskSizeAutoSupported = !config.ec2.zfs.enable;

      system.nixos.tags = [ "amazon" ];
      system.build.image = config.system.build.amazonImage;
      image.extension = if cfg.format == "vpc" then "vhd" else cfg.format;
    }

    (mkIf (!config.ec2.zfs.enable) {
      ec2.bootMode = mkIf pkgs.stdenv.hostPlatform.isx86 (mkDefault "uefi-preferred");

      image.repart = {
        enable = true;
        # repart derives image.baseName from this; keep its usual default.
        name = options.image.baseName.default;
        imageSize = if autoSize then "auto" else "${toString config.virtualisation.diskSize}M";
        partitions = {
          bios-boot = mkIf (grubDevices != [ ]) {
            repartConfig = {
              Type = "21686148-6449-6e6f-744e-656564454649";
              SizeMinBytes = "1M";
              SizeMaxBytes = "1M";
            };
          };
          esp = mkIf grub.efiSupport {
            repartConfig =
              let
                # Room for about 10 generations of kernels and initrds.
                size = if pkgs.stdenv.hostPlatform.isx86 then "512M" else "1G";
              in
              {
                Type = "esp";
                Format = "vfat";
                Label = "ESP";
                SizeMinBytes = size;
                SizeMaxBytes = size;
              };
          };
          root = {
            inherit storePaths;
            contents = {
              "/etc/nixos/configuration.nix".source = configFile;
            }
            // lib.genAttrs' cfg.contents (
              { source, target }: lib.nameValuePair "/${lib.removePrefix "/" target}" { inherit source; }
            );
            repartConfig = {
              Type = "root";
              Format = config.fileSystems."/".fsType;
              Label = "nixos";
            }
            // lib.optionalAttrs autoSize { Minimize = "guess"; };
          };
        };
      };

      system.build.amazonImage = repartBuilder;
    })

    (mkIf config.ec2.zfs.enable {
      system.build.amazonImage = import ../../../lib/make-multi-disk-zfs-image.nix {
        inherit
          lib
          config
          configFile
          pkgs
          ;
        inherit (cfg) contents format;
        name = config.image.baseName;

        includeChannel = true;

        bootSize = 1000; # 1G is the minimum EBS volume

        rootSize = config.virtualisation.diskSize;
        rootPoolProperties = {
          ashift = 12;
          autoexpand = "on";
        };

        datasets = config.ec2.zfs.datasets;

        postVM = ''
           extension=''${rootDiskImage##*.}
           friendlyName=$out/${config.image.baseName}
           rootDisk="$friendlyName.root.$extension"
           bootDisk="$friendlyName.boot.$extension"
           mv "$rootDiskImage" "$rootDisk"
           mv "$bootDiskImage" "$bootDisk"

           mkdir -p $out/nix-support
           echo "file ${cfg.format} $bootDisk" >> $out/nix-support/hydra-build-products
           echo "file ${cfg.format} $rootDisk" >> $out/nix-support/hydra-build-products

          ${pkgs.jq}/bin/jq -n \
            --arg system_version ${lib.escapeShellArg config.system.nixos.version} \
            --arg system ${lib.escapeShellArg pkgs.stdenv.hostPlatform.system} \
            --arg root_logical_bytes "$(${pkgs.qemu_kvm}/bin/qemu-img info --output json "$rootDisk" | ${pkgs.jq}/bin/jq '."virtual-size"')" \
            --arg boot_logical_bytes "$(${pkgs.qemu_kvm}/bin/qemu-img info --output json "$bootDisk" | ${pkgs.jq}/bin/jq '."virtual-size"')" \
            --arg boot_mode "${bootMode}" \
            --arg root "$rootDisk" \
            --arg boot "$bootDisk" \
           '{}
             | .label = $system_version
             | .boot_mode = $boot_mode
             | .system = $system
             | .disks.boot.logical_bytes = $boot_logical_bytes
             | .disks.boot.file = $boot
             | .disks.root.logical_bytes = $root_logical_bytes
             | .disks.root.file = $root
             ' > $out/nix-support/image-info.json
        '';
      };
    })
  ];

  meta.maintainers = with lib.maintainers; [ arianvp ];
}
