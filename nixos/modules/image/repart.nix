# This module exposes options to build a disk image with a GUID Partition Table
# (GPT). It uses systemd-repart to build the image.

{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.image.repart;
in
{
  imports = [
    ./repart-verity-store.nix
    ./file-options.nix
  ];

  options.image.repart = lib.mkOption {
    type = lib.types.submoduleWith {
      class = "repartImage";
      modules = [
        pkgs.mkRepartImage.modules
        {
          _file = "${toString ./repart.nix}";
          config._module.args.pkgs = lib.mkOptionDefault pkgs;

          options.partitions = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { config, ... }:
                {
                  options = {
                    # Superseded by `nixStorePrefix`. Unfortunately, `mkChangedOptionModule`
                    # does not support submodules.
                    stripNixStorePrefix = lib.mkOption {
                      default = "_mkMergedOptionModule";
                      visible = false;
                    };
                  };

                  config = lib.mkIf (config.stripNixStorePrefix == true) {
                    nixStorePrefix = "/";
                  };
                }
              )
            );
          };
        }
      ];
    };
    default = { };
    description = ''
      Configuration of the image built by `pkgs.mkRepartImage`.
    '';
  };

  config = {
    image.baseName =
      let
        version = config.image.repart.version;
        versionInfix = if version != null then "_${version}" else "";
      in
      cfg.name + versionInfix;
    image.extension = cfg.extension;

    image.repart = {
      name = lib.mkIf (config.system.image.id != null) (lib.mkOptionDefault config.system.image.id);
      version = lib.mkDefault config.system.image.version;
      baseName = config.image.baseName;

      warnings = lib.flatten (
        lib.mapAttrsToList (
          fileName: partitionConfig:
          lib.optional (partitionConfig.stripNixStorePrefix != "_mkMergedOptionModule") ''
            The option definition `image.repart.partitions.${fileName}.stripNixStorePrefix`
            has changed to `image.repart.partitions.${fileName}.nixStorePrefix` and now
            accepts the path to use as prefix directly. Use `nixStorePrefix = "/"` to
            achieve the same effect as setting `stripNixStorePrefix = true`.
          ''
        ) cfg.partitions
      );
    };

    system.build.image = cfg.image;
  };

  meta = {
    # The option declarations need pkgs.mkRepartImage.
    buildDocsInSandbox = false;
    maintainers = with lib.maintainers; [
      nikstur
      willibutz
    ];
  };
}
