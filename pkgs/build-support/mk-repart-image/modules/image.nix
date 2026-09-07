{
  lib,
  pkgs,
  config,
  options,
  extendModules,
  ...
}:

let
  inherit (pkgs) buildPackages;

  systemdArch =
    let
      inherit (pkgs.stdenv) hostPlatform;
    in
    if hostPlatform.isAarch32 then
      "arm"
    else if hostPlatform.isAarch64 then
      "arm64"
    else if hostPlatform.isx86_32 then
      "x86"
    else if hostPlatform.isx86_64 then
      "x86-64"
    else if hostPlatform.isMips32 then
      "mips-le"
    else if hostPlatform.isMips64 then
      "mips64-le"
    else if hostPlatform.isPower then
      "ppc"
    else if hostPlatform.isPower64 then
      "ppc64"
    else if hostPlatform.isRiscV32 then
      "riscv32"
    else if hostPlatform.isRiscV64 then
      "riscv64"
    else if hostPlatform.isS390 then
      "s390"
    else if hostPlatform.isS390x then
      "s390x"
    else if hostPlatform.isLoongArch64 then
      "loongarch64"
    else if hostPlatform.isAlpha then
      "alpha"
    else
      hostPlatform.parsed.cpu.name;

  amendRepartDefinitions =
    pkgs.runCommand "amend-repart-definitions.py"
      {
        nativeBuildInputs = [
          buildPackages.python3
          buildPackages.ruff
          buildPackages.mypy
        ];
      }
      ''
        install ${../amend-repart-definitions.py} $out
        patchShebangs --build $out

        ruff format --check $out
        ruff check $out
        mypy --strict $out
      '';

  fileSystemToolMapping = {
    "vfat" = [
      buildPackages.dosfstools
      buildPackages.mtools
    ];
    "ext4" = [ buildPackages.e2fsprogs.bin ];
    "squashfs" = [ buildPackages.squashfs-tools ];
    "erofs" = [ buildPackages.erofs-utils ];
    "btrfs" = [ buildPackages.btrfs-progs ];
    "xfs" = [ buildPackages.xfsprogs ];
    "swap" = [ buildPackages.util-linux ];
  };

  # Without Format=, systemd-repart formats partitions that copy files as vfat
  # for ESP and XBOOTLDR partitions and as ext4 otherwise.
  format =
    partition:
    partition.repartConfig.Format or (
      if partition.contents == { } && partition.storePaths == [ ] then
        null
      else if
        lib.elem (partition.repartConfig.Type or null) [
          "esp"
          "xbootldr"
        ]
      then
        "vfat"
      else
        "ext4"
    );

  formats = lib.filter (f: f != null) (lib.mapAttrsToList (_n: v: format v) config.partitions);

  fileSystemTools = lib.concatMap (f: fileSystemToolMapping.${f} or [ ]) formats;

  compressors = {
    zstd = {
      package = buildPackages.zstd;
      extension = ".zst";
      command = level: "zstd --no-progress --threads=$NIX_BUILD_CORES -${toString level}";
    };
    xz = {
      package = buildPackages.xz;
      extension = ".xz";
      command = level: "xz --keep --verbose --threads=$NIX_BUILD_CORES -${toString level}";
    };
    zstd-seekable = {
      package = buildPackages.zeekstd;
      extension = ".zst";
      command = level: "zeekstd --no-progress --frame-size 2M --compression-level ${toString level}";
    };
  };

  compressor = compressors.${config.compression.algorithm};

  mkfsOptionsToEnv =
    opts:
    lib.mapAttrs' (fsType: flags: {
      name = "SYSTEMD_REPART_MKFS_OPTIONS_${lib.toUpper fsType}";
      value = builtins.concatStringsSep " " flags;
    }) opts;

  iniFormat = pkgs.formats.ini { listsAsDuplicateKeys = true; };

  definitionsDirectory = pkgs.linkFarm "repart.d" (
    lib.mapAttrsToList (n: v: {
      name = "${n}.conf";
      path = iniFormat.generate "${n}.conf" { Partition = v.repartConfig; };
    }) config.partitions
  );

  makeClosure = paths: pkgs.closureInfo { rootPaths = paths; };

  # Add the closure of the provided Nix store paths to the partitions so
  # that amend-repart-definitions.py can read it.
  addClosure =
    _name: partitionConfig:
    partitionConfig
    // (lib.optionalAttrs (partitionConfig.storePaths != [ ]) {
      closure = "${makeClosure partitionConfig.storePaths}/store-paths";
    });

  # See GPTMaxLabelLength in nixos/lib/systemd-lib.nix.
  GPTMaxLabelLength = 36;
in
{
  options = {
    finalPartitions = lib.mkOption {
      type = lib.types.attrs;
      internal = true;
      readOnly = true;
      description = ''
        Convenience option to access partitions with added closures.
      '';
    };

    extension = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "raw" + lib.optionalString config.compression.enable compressor.extension;
      defaultText = lib.literalMD "`raw`, with the suffix of {option}`compression.algorithm` appended when {option}`compression.enable` is set.";
      description = ''
        Extension of the image filename (e.g. `raw` or `raw.zst`).
      '';
    };

    fileName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${config.baseName}.${config.extension}";
      defaultText = lib.literalMD "{option}`baseName` and {option}`extension` joined by a dot.";
      description = ''
        Filename of the image including all extensions (e.g `image_1.raw` or
        `image_1.raw.zst`).
      '';
    };

    image = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      description = ''
        The image built from this configuration.
      '';
    };

    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [ ];
      internal = true;
      visible = false;
      description = ''
        Assertions checked when evaluating the image.
      '';
    };

    warnings = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
      visible = false;
      description = ''
        Warnings shown when evaluating the image.
      '';
    };
  };

  config = {
    finalPartitions = lib.mapAttrs addClosure config.partitions;

    assertions = lib.flatten (
      lib.mapAttrsToList (
        fileName: partitionConfig:
        let
          inherit (partitionConfig) repartConfig;
          labelLength = builtins.stringLength repartConfig.Label;
        in
        [
          {
            assertion = repartConfig ? Type;
            message = "The partition '${fileName}' has no Type= set in repartConfig.";
          }
          {
            assertion = repartConfig ? Label -> GPTMaxLabelLength >= labelLength;
            message = ''
              The partition label '${repartConfig.Label}'
              defined for '${fileName}' is ${toString labelLength} characters long,
              but the maximum label length supported by UEFI is ${toString GPTMaxLabelLength}.
            '';
          }
        ]
      ) config.partitions
    );

    warnings = lib.flatten (
      lib.mapAttrsToList (
        fileName: partitionConfig:
        let
          inherit (partitionConfig) repartConfig;
          suggestedMaxLabelLength = GPTMaxLabelLength - 2;
          labelLength = builtins.stringLength repartConfig.Label;
        in
        lib.optional (repartConfig ? Label && labelLength >= suggestedMaxLabelLength) ''
          The partition label '${repartConfig.Label}'
          defined for '${fileName}' is ${toString labelLength} characters long.
          The suggested maximum label length is ${toString suggestedMaxLabelLength}.

          If you use systemd-sysupdate style A/B updates, this might
          not leave enough space to increment the version number included in
          the label in a future release. For example, if your label is
          ${toString GPTMaxLabelLength} characters long (the maximum enforced by UEFI) and
          you're at version 9, you cannot increment this to 10.
        ''
      ) config.partitions
    );

    image = lib.asserts.checkAssertWarn config.assertions config.warnings (
      pkgs.stdenvNoCC.mkDerivation (
        (
          if config.version != null then
            {
              pname = config.name;
              inherit (config) version;
            }
          else
            { inherit (config) name; }
        )
        // {
          __structuredAttrs = true;
          strictDeps = true;

          # the image will be self-contained so we can drop references
          # to the closure that was used to build it
          unsafeDiscardReferences.out = true;

          nativeBuildInputs = [
            config.package
            buildPackages.util-linux
            buildPackages.fakeroot
          ]
          ++ lib.optionals config.compression.enable [
            compressor.package
          ]
          ++ fileSystemTools;

          env = mkfsOptionsToEnv config.mkfsOptions;

          inherit definitionsDirectory;

          partitionsJSON = builtins.toJSON config.finalPartitions;

          systemdRepartFlags = [
            "--architecture=${systemdArch}"
            "--dry-run=no"
            "--size=${config.imageSize}"
            "--definitions=repart.d"
            "--split=${lib.boolToString config.split}"
            "--json=pretty"
          ]
          ++ lib.optionals (config.seed != null) [
            "--seed=${config.seed}"
          ]
          ++ lib.optionals config.createEmpty [
            "--empty=create"
          ]
          ++ lib.optionals (config.sectorSize != null) [
            "--sector-size=${toString config.sectorSize}"
          ];

          dontUnpack = true;
          dontPatch = true;
          dontFixup = true;

          configurePhase = ''
            runHook preConfigure

            amendedRepartDefinitionsDir=$(${amendRepartDefinitions} <(echo "$partitionsJSON") $definitionsDirectory)
            ln -vs $amendedRepartDefinitionsDir repart.d

            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild

            echo "Building image with systemd-repart..."
            unshare --map-root-user fakeroot systemd-repart \
              "''${systemdRepartFlags[@]}" \
              "${config.baseName}.raw" \
              | tee repart-output.json

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out
          ''
          # Compression is implemented in the same derivation as opposed to in a
          # separate derivation to allow users to save disk space. Disk images are
          # already very space intensive so we want to allow users to mitigate this.
          + lib.optionalString config.compression.enable ''
            for f in "${config.baseName}"*; do
              echo "Compressing $f with ${config.compression.algorithm}..."
              # Keep the original file when compressing and only delete it afterwards
              ${compressor.command config.compression.level} "$f" && rm "$f"
            done
          ''
          + ''
            mv -v repart-output.json "${config.baseName}"* $out

            runHook postInstall
          '';

          passthru = {
            inherit
              amendRepartDefinitions
              config
              options
              extendModules
              ;
            inherit (config) fileName extension;
          };
        }
      )
    );
  };
}
