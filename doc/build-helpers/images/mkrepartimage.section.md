# pkgs.mkRepartImage {#sec-pkgs-mkRepartImage}

`pkgs.mkRepartImage` builds a disk image with a GUID Partition Table (GPT).
It uses `systemd-repart` to build the image.
The NixOS module `image.repart` uses it to build images of NixOS systems.

Use `extendModules` on the derivation to change the configuration of an image and `overrideAttrs` to change its derivation.

The output contains the image, named after {option}`fileName`, and the JSON output of systemd-repart as `repart-output.json`.

:::{.example #ex-pkgs-mkRepartImage}
# Building an image of a NixOS system

The `image.repart` module described in the [NixOS manual](https://nixos.org/manual/nixos/unstable/#sec-image-repart) does the same from within a NixOS configuration.

```nix
{ pkgs, lib, ... }:
let
  nixos = pkgs.nixos {
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };
    boot.loader.grub.enable = false;
  };
  inherit (nixos) config;
  inherit (pkgs.stdenv.hostPlatform) efiArch;
in
pkgs.mkRepartImage {
  name = "image";
  partitions = {
    "esp" = {
      contents = {
        "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
          "${config.systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
        "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
          "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
      };
      repartConfig = {
        Type = "esp";
        Format = "vfat";
        SizeMinBytes = "96M";
      };
    };
    "root" = {
      storePaths = [ config.system.build.toplevel ];
      repartConfig = {
        Type = "root";
        Format = "ext4";
        Label = "nixos";
        Minimize = "guess";
      };
    };
  };
}
```
:::

:::{.example #ex-pkgs-mkRepartImage-override}
# Changing the configuration and the derivation of an image

```nix
let
  compressed =
    (image.extendModules {
      modules = [ { compression.enable = true; } ];
    }).config.image;

  qcow2 = image.overrideAttrs (previousAttrs: {
    nativeBuildInputs = previousAttrs.nativeBuildInputs ++ [ pkgs.qemu-utils ];
    postBuild = ''
      qemu-img convert -f raw -O qcow2 ${image.config.baseName}.raw ${image.config.baseName}.qcow2
      rm ${image.config.baseName}.raw
    '';
  });
in
{
  inherit compressed qcow2;
}
```
:::

## Options {#sec-pkgs-mkRepartImage-options}

```{=include=} options
id-prefix: opt-mkRepartImage-
list-id: configuration-variable-list
source: ../../mkrepartimage-options.json
```
