# To build this derivation, run `nix-build -E 'with import ./. { }; mkRepartImage.optionsDoc'`
{
  lib,
  pkgs,
  nixosOptionsDoc,
}:

let
  # Not mkRepartImage.evalModules. The manual builds with the pinned nixpkgs
  # from ci/pinned.json, whose mkRepartImage may be older or missing.
  configuration = lib.evalModules {
    class = "repartImage";
    modules = [
      { _module.args.pkgs = lib.mkOptionDefault pkgs; }
      ./modules
    ];
  };

  root = toString ./modules;
  revision = lib.trivial.revisionWithDefault "master";
  removeRoot = file: lib.removePrefix "/" (lib.removePrefix root file);

  transformDeclaration =
    file:
    let
      fileStr = toString file;
      subpath = "pkgs/build-support/mk-repart-image/modules/" + removeRoot fileStr;
    in
    assert lib.hasPrefix root fileStr;
    {
      url = "https://github.com/NixOS/nixpkgs/blob/${revision}/${subpath}";
      name = subpath;
    };
in
nixosOptionsDoc {
  documentType = "none";
  options = removeAttrs configuration.options [ "_module" ];
  transformOptions = opt: opt // { declarations = map transformDeclaration opt.declarations; };
}
