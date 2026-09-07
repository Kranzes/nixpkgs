{
  lib,
  mkRepartImage,
  hello,
  writeText,
  runCommand,
  jq,
  nixosTests,
}:

let
  partitions = {
    "10-esp" = {
      contents."/hello.txt".source = writeText "hello.txt" "hello";
      repartConfig = {
        Type = "esp";
        Format = "vfat";
        SizeMinBytes = "64M";
      };
    };
    "20-store" = {
      storePaths = [ hello ];
      nixStorePrefix = "/";
      repartConfig = {
        Type = "linux-generic";
        Format = "erofs";
        Minimize = "best";
      };
    };
  };

  checkImage =
    image:
    runCommand "${image.name}-check" { nativeBuildInputs = [ jq ]; } ''
      test -f ${image}/${image.fileName}
      test "$(jq length ${image}/repart-output.json)" -eq 2
      touch $out
    '';
in

lib.recurseIntoAttrs {
  basic = checkImage (mkRepartImage {
    name = "repart-test";
    version = "1";
    inherit partitions;
  });

  compressed = checkImage (mkRepartImage {
    name = "repart-test-compressed";
    inherit partitions;
    compression = {
      enable = true;
      algorithm = "zstd";
    };
  });

  extended =
    checkImage
      (
        (mkRepartImage {
          name = "repart-test-extended";
          inherit partitions;
          compression.enable = true;
        }).extendModules
        {
          modules = [
            {
              compression.enable = lib.mkForce false;
              partitions."10-esp".contents."/extended.txt".source = writeText "extended.txt" "extended";
            }
          ];
        }
      ).config.image;

  inherit (nixosTests)
    appliance-repart-image
    appliance-repart-image-verity-store
    activation-bashless-image
    nix-store-veritysetup
    ;
}
