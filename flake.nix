{
  description = "Load pnpm's pnpm-lock.yaml into Nix expressions - supports lockfile v5, v6, and v9";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      lib = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pnpm2nixV5 = import ./default.nix { inherit pkgs; };
          pnpm2nixV6V9 = import ./v6v9.nix { inherit pkgs; };
        in {
          inherit (pnpm2nixV5) mkPnpmPackage mkPnpmEnv defaultPnpmOverrides;
          inherit (pnpm2nixV6V9) mkPnpmTarballs mkPnpmNodeModules mkNodePackage mkPnpmPackageV6V9;
          mkPnpmPackageAuto = args:
            let
              lockFile = args.pnpmLock or (args.src + "/pnpm-lock.yaml");
              text = builtins.readFile lockFile;
              versionMatch = builtins.match ".*lockfileVersion: ['\"]?([0-9.]+)['\"]?.*" text;
              version = if versionMatch != null then builtins.elemAt versionMatch 0 else "5";
              majorVersion = builtins.head (builtins.split "\\." version);
            in
            if majorVersion == "5" || majorVersion == "3" then
              pnpm2nixV5.mkPnpmPackage args
            else
              pnpm2nixV6V9.mkPnpmPackageV6V9 args;
        });
    };
}
