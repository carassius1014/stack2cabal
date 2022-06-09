{ pkgs, ghcVersion }:
let
  # keep the source as minimal as possible to avoid unnecessary rebuilds
  cleanedSrc = pkgs.haskell-nix.haskellLib.cleanGit { src = ./.; };
  src = with pkgs;
    lib.cleanSourceWith {
      name = "stack2nix-source";
      src = cleanedSrc;
    };

in pkgs.haskell-nix.cabalProject {
  inherit src;
  compiler-nix-name = ghcVersion;
}
