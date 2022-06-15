{
  description =
    "Convert stack projects to cabal.project + cabal.project.freeze";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-22.05";

    haskellNix.url = "github:input-output-hk/haskell.nix";
    haskellNix.inputs.nixpkgs.follows = "nixpkgs";

    flake-utils.url = "github:numtide/flake-utils";
    flake-utils.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, haskellNix, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          inherit (haskellNix) config;
          overlays = haskellNix.nixpkgsArgs.overlays or [ ]
            ++ [ haskellNix.overlay (self: super: { }) ];
        };
        ghcVersion = "ghc902";
        project = import ./. { inherit pkgs ghcVersion; };
      in {
        devShells.default =
          import ./shell.nix { inherit pkgs ghcVersion project; };
        packages = {
          default = project;
        };
      });
}
