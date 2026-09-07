{
  lib,
  pkgs,
  callPackages,
}:

let
  evalModules =
    module:
    lib.evalModules {
      class = "repartImage";
      modules = [
        {
          _file = "<mkRepartImage>";
          _module.args.pkgs = lib.mkOptionDefault pkgs;
        }
        {
          _file = "<mkRepartImage args>";
          imports = lib.toList module;
        }
        ./modules
      ];
    };
in
{
  __functor = _: module: (evalModules module).config.image;

  inherit evalModules;

  modules = ./modules;

  optionsDoc = callPackages ./options-doc.nix { };
}
