{
  lib,
  pkgs,
  config,
  ...
}:

let
  partitionOptions = {
    options = {
      storePaths = lib.mkOption {
        type = lib.types.listOf lib.types.pathInStore;
        default = [ ];
        description = "The store paths to copy into the partition, together with their closure.";
      };

      nixStorePrefix = lib.mkOption {
        type = lib.types.path;
        default = "/nix/store";
        description = ''
          The prefix to use for store paths. This is useful when you want to
          build a partition that only contains store paths and is mounted under
          `/nix/store` or if you want to create the store paths below a parent
          path (e.g., `/@nix/nix/store`).
        '';
      };

      contents = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              source = lib.mkOption {
                type = lib.types.path;
                description = "Path of the file or directory to copy.";
              };
            };
          }
        );
        default = { };
        example = lib.literalExpression ''
          {
            "/EFI/BOOT/BOOTX64.EFI".source =
              "''${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi";

            "/loader/loader.conf".source = pkgs.writeText "loader.conf" "timeout 5";
          }
        '';
        description = "Files to copy into the partition, keyed by their target path.";
      };

      repartConfig = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.str
            lib.types.int
            lib.types.bool
            (lib.types.listOf lib.types.str)
          ]
        );
        example = {
          Type = "home";
          SizeMinBytes = "512M";
          SizeMaxBytes = "2G";
        };
        description = ''
          The `[Partition]` section of the definition file.
          See {manpage}`repart.d(5)` for all available options.
        '';
      };
    };
  };
in
{
  options = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Name of the image.";
    };

    version = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Version of the image.";
    };

    baseName = lib.mkOption {
      type = lib.types.str;
      default = config.name + lib.optionalString (config.version != null) "_${config.version}";
      defaultText = lib.literalMD "{option}`name`, followed by `_` and {option}`version` when set.";
      description = ''
        Basename of the image filename without any extension (e.g. `image_1`).
      '';
    };

    package = lib.mkPackageOption pkgs "systemd-repart" {
      # We use buildPackages so that repart images are built with the build
      # platform's systemd, allowing for cross-compiled systems to work.
      default = [
        "buildPackages"
        "systemd"
      ];
      example = ''
        pkgs.buildPackages.systemdMinimal.override {
          withRepart = true;
          withCryptsetup = true;
        }
      '';
    };

    compression = {
      enable = lib.mkEnableOption "image compression";

      algorithm = lib.mkOption {
        type = lib.types.enum [
          "zstd"
          "xz"
          "zstd-seekable"
        ];
        default = "zstd";
        description = "Compression algorithm.";
      };

      level = lib.mkOption {
        type = lib.types.int;
        # Generally default to slightly faster than default compression
        # levels under the assumption that most of the building will be done
        # for development and release builds will be customized.
        default = 3;
        description = ''
          Compression level. The available range depends on {option}`compression.algorithm`.
        '';
      };
    };

    seed = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      # Generated with `uuidgen`. Random but fixed to improve reproducibility.
      default = "0867da16-f251-457d-a9e8-c31f9a3c220b";
      description = ''
        A UUID to use as a seed. You can set this to `random` to explicitly
        randomize the partition UUIDs. `null` does not pass a seed to
        systemd-repart.
        See {manpage}`systemd-repart(8)` for more information.
      '';
    };

    split = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enables generation of split artifacts from partitions. If enabled, for
        each partition with `SplitName=` set, a separate output file containing
        just the contents of that partition is generated.
      '';
    };

    sectorSize = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          512
          1024
          2048
          4096
        ]
      );
      default = 512;
      example = 4096;
      description = ''
        The sector size of the disk image produced by systemd-repart. `null`
        does not pass a sector size to systemd-repart.
      '';
    };

    imageSize = lib.mkOption {
      type = lib.types.strMatching "^([0-9]+[KMGTP]?|auto)$";
      default = "auto";
      example = "512G";
      description = ''
        Size of the produced image in bytes with optional K, M, G, T suffix,
        or `auto` to determine the minimal size automatically.
      '';
    };

    createEmpty = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to create a new image file. If disabled, systemd-repart
        applies the partition definitions to the existing `.raw` file named
        after {option}`baseName` in the build directory.
      '';
    };

    partitions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule partitionOptions);
      default = { };
      example = lib.literalExpression ''
        {
          "10-esp" = {
            contents = {
              "/EFI/BOOT/BOOTX64.EFI".source =
                "''${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi";
            };
            repartConfig = {
              Type = "esp";
              Format = "vfat";
            };
          };
          "20-root" = {
            storePaths = [ pkgs.hello ];
            repartConfig = {
              Type = "root";
              Format = "ext4";
              Minimize = "guess";
            };
          };
        }
      '';
      description = ''
        The partitions of the image, keyed by the name of their `repart.d`
        definition file. The names determine the order of the partitions.
      '';
    };

    mkfsOptions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = lib.literalExpression ''
        {
          vfat = [ "-S 512" "-c" ];
        }
      '';
      description = ''
        Specify extra options for created file systems. The specified options
        are converted to individual environment variables of the format
        `SYSTEMD_REPART_MKFS_OPTIONS_<FSTYPE>`.

        See [upstream systemd documentation](https://github.com/systemd/systemd/blob/v255/docs/ENVIRONMENT.md?plain=1#L575-L577)
        for information about the usage of these environment variables.

        The example would produce the following environment variable:
        ```
        SYSTEMD_REPART_MKFS_OPTIONS_VFAT="-S 512 -c"
        ```
      '';
    };
  };
}
