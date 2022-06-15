{ pkgs, project, ghcVersion }:

project.shellFor {
  # Workaround for https://github.com/input-output-hk/haskell.nix/issues/231
  exactDeps = false;

  buildInputs = with pkgs; [
    cabal-install
    ghcid
    nixfmt
    haskell.packages.${ghcVersion}.brittany
  ];
}
