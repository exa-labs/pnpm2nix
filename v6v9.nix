{ pkgs }:

let
  lib = pkgs.lib;

  parsePnpmLock = lockFile:
    let
      text = builtins.readFile lockFile;
      lines = lib.splitString "\n" text;

      findPackagesStart = lines:
        let
          indices = lib.imap0 (i: line:
            if builtins.match "^packages:[[:space:]]*$" line != null then i else null
          ) lines;
          filtered = builtins.filter (x: x != null) indices;
        in
        if builtins.length filtered > 0 then builtins.elemAt filtered 0 else null;

      findPackagesEnd = lines: startIdx:
        let
          restLines = lib.lists.drop (startIdx + 1) lines;
          indices = lib.imap0 (i: line:
            if builtins.match "^[a-zA-Z].*:.*$" line != null then i else null
          ) restLines;
          filtered = builtins.filter (x: x != null) indices;
        in
        if builtins.length filtered > 0 then
          startIdx + 1 + (builtins.elemAt filtered 0)
        else
          builtins.length lines;

      pkgStartIdx = findPackagesStart lines;
      pkgEndIdx = if pkgStartIdx != null then findPackagesEnd lines pkgStartIdx else 0;
      pkgLines = if pkgStartIdx != null then
        lib.lists.sublist (pkgStartIdx + 1) (pkgEndIdx - pkgStartIdx - 1) lines
      else
        [];

      stripQuotes = str:
        let
          match = builtins.match ''^['"](.+)['"]$'' str;
        in
        if match != null then builtins.elemAt match 0 else str;

      parsePackages = lines:
        let
          initialState = {
            current = null;
            acc = [];
          };

          processLine = state: line:
            let
              pkgMatch = builtins.match "^  ([^:]+):[[:space:]]*$" line;
              resMatch = builtins.match "^    resolution: [{](.*)[}][[:space:]]*$" line;

              extractIntegrity = resStr:
                let
                  intMatch = builtins.match ".*integrity: ([^,}]+).*" resStr;
                in
                if intMatch != null then stripQuotes (builtins.elemAt intMatch 0) else null;

              extractTarball = resStr:
                let
                  tarMatch = builtins.match ".*tarball: ([^,}]+).*" resStr;
                in
                if tarMatch != null then stripQuotes (builtins.elemAt tarMatch 0) else null;

            in
            if pkgMatch != null then
              {
                current = stripQuotes (builtins.elemAt pkgMatch 0);
                acc = state.acc;
              }
            else if resMatch != null && state.current != null then
              let
                resStr = builtins.elemAt resMatch 0;
                integrity = extractIntegrity resStr;
                tarball = extractTarball resStr;
              in
              if integrity != null then
                {
                  current = state.current;
                  acc = state.acc ++ [{
                    key = state.current;
                    inherit integrity;
                    tarball = tarball;
                  }];
                }
              else
                state
            else
              state;

          finalState = lib.foldl processLine initialState lines;
        in
        finalState.acc;

      packages = parsePackages pkgLines;

    in
    {
      inherit packages;
    };

  parsePackageKey = key:
    let
      normalized = if builtins.substring 0 1 key == "/" then
        builtins.substring 1 (builtins.stringLength key - 1) key
      else
        key;
      withoutPeer = builtins.head (builtins.split "\\(" normalized);
      match = builtins.match "^(.*)@([^@]+)$" withoutPeer;
    in
    if match == null then
      null
    else
      {
        name = builtins.elemAt match 0;
        version = builtins.elemAt match 1;
      };

  makeTarballUrl = name: version:
    let
      parts = builtins.filter (x: x != "") (builtins.split "/" name);
      packageName = builtins.elemAt parts (builtins.length parts - 1);
    in
    "https://registry.npmjs.org/${name}/-/${packageName}-${version}.tgz";

  mkPnpmTarballs = { lockFile }:
    let
      lock = parsePnpmLock lockFile;

      tarballDrvs = builtins.map (pkg:
        let
          parsed = parsePackageKey pkg.key;
          url = if pkg.tarball != null then pkg.tarball else makeTarballUrl parsed.name parsed.version;
        in
        {
          key = pkg.key;
          drv = pkgs.fetchurl {
            inherit url;
            hash = pkg.integrity;
          };
        }
      ) lock.packages;

      manifest = builtins.toJSON (
        builtins.listToAttrs (
          builtins.map (item: {
            name = item.key;
            value = "${item.drv}";
          }) tarballDrvs
        )
      );

    in
    pkgs.runCommand "pnpm-tarballs" {} (
      ''
        mkdir -p "$out"
      '' + lib.concatMapStringsSep "\n" (item:
        ''cp "${item.drv}" "$out/$(basename "${item.drv}")"''
      ) tarballDrvs + ''
        
        # Write manifest.json
        cat > "$out/manifest.json" <<'EOF'
${manifest}
EOF
      ''
    );

  mkPnpmPackageV6V9 = {
    src,
    pname,
    version ? "1.0.0",
    lockFile ? "${src}/pnpm-lock.yaml",
    workspaceName ? null,
    packagePath ? ".",
    buildScript ? "build",
    installPhase ? null,
    includeDevDependencies ? true,
    nativeBuildInputs ? [],
    buildInputs ? [],
    preBuild ? "",
    postBuild ? "",
    ...
  }@args:
    let
      pnpmTarballs = mkPnpmTarballs { inherit lockFile; };

      defaultInstallPhase = ''
        mkdir -p $out
        if [ -d "${packagePath}/dist" ]; then
          cp -r ${packagePath}/dist $out/
        fi
        if [ -f "${packagePath}/package.json" ]; then
          cp ${packagePath}/package.json $out/
        fi
      '';

      buildCommand = if workspaceName != null then
        "pnpm -r --filter '^${workspaceName}' run ${buildScript}"
      else
        "pnpm run ${buildScript}";

      # Compute lockfile directory and package directory relative to src
      lockDir = builtins.dirOf lockFile;
      lockFileName = builtins.baseNameOf lockFile;
      # Compute relative path from src to lockfile
      lockFileRelative = if lib.hasPrefix (toString src) (toString lockFile) then
        lib.removePrefix "${toString src}/" (toString lockFile)
      else
        lockFileName;
      
      # Create patch.py as a separate file to avoid heredoc issues
      patchPy = pkgs.writeText "patch.py" ''
        import json
        import sys
        import os
        from ruamel.yaml import YAML

        # Use the lockfile in the build directory (writable)
        lockfile_path = '${lockFileRelative}'
        manifest_path = '${pnpmTarballs}/manifest.json'

        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        yaml = YAML()
        yaml.preserve_quotes = True
        yaml.default_flow_style = False

        with open(lockfile_path, 'r') as f:
            lockfile = yaml.load(f)

        patches_applied = 0
        sections_to_patch = []

        if 'packages' in lockfile:
            sections_to_patch.append(('packages', lockfile['packages']))
        if 'snapshots' in lockfile:
            sections_to_patch.append(('snapshots', lockfile['snapshots']))

        for section_name, section in sections_to_patch:
            for key, tarball_path in manifest.items():
                if key in section:
                    entry = section[key]
                    if isinstance(entry, dict) and 'resolution' in entry:
                        if isinstance(entry['resolution'], dict):
                            entry['resolution']['tarball'] = f"file://{tarball_path}"
                            patches_applied += 1
                
                if section_name == 'snapshots':
                    for snapshot_key in section.keys():
                        normalized_key = snapshot_key.split('(')[0]
                        if normalized_key == key:
                            entry = section[snapshot_key]
                            if isinstance(entry, dict) and 'resolution' in entry:
                                if isinstance(entry['resolution'], dict):
                                    entry['resolution']['tarball'] = f"file://{tarball_path}"
                                    patches_applied += 1

        with open(lockfile_path, 'w') as f:
            yaml.dump(lockfile, f)
      '';

    in
    pkgs.stdenvNoCC.mkDerivation ({
      inherit pname version src;

      nativeBuildInputs = with pkgs; [
        nodejs
        pnpm
        python3Packages.ruamel-yaml
        jq
      ] ++ nativeBuildInputs;

      inherit buildInputs;

      buildPhase = ''
        set -euo pipefail
        set -x  # Enable command tracing for debugging
        
        export HOME=$TMPDIR/home
        mkdir -p "$HOME"

        STORE_DIR="$TMPDIR/pnpm-store"
        mkdir -p "$STORE_DIR"
        
        # Configure pnpm via environment variables (no .npmrc file needed)
        export PNPM_STORE_DIR="$STORE_DIR"
        export PNPM_HOME="${pkgs.pnpm}/bin"
        export NPM_CONFIG_OFFLINE=true
        export NPM_CONFIG_AUDIT=false
        export NPM_CONFIG_FUND=false
        export npm_config_update_notifier=false
        export npm_config_manage_package_manager_versions=false
        ${if includeDevDependencies then "export NPM_CONFIG_PRODUCTION=false" else ""}

        # Set package directory and compute lockfile paths
        PKG_DIR="${packagePath}"
        LOCK_FILE_REL="${lockFileRelative}"
        LOCK_DIR=$(dirname "$LOCK_FILE_REL")

        # Remove packageManager field from package.json in the package directory
        if [ -f "$PKG_DIR/package.json" ]; then
          echo "Removing packageManager field from $PKG_DIR/package.json"
          ${pkgs.jq}/bin/jq 'del(.packageManager)' "$PKG_DIR/package.json" > "$PKG_DIR/package.json.tmp" && mv "$PKG_DIR/package.json.tmp" "$PKG_DIR/package.json"
        fi

        # Run the patcher (lockfile is now in the writable build directory)
        ${pkgs.python3}/bin/python3 ${patchPy}

        # Run pnpm fetch and install with lockfile-dir
        ${pkgs.pnpm}/bin/pnpm fetch --offline --frozen-lockfile --store-dir "$STORE_DIR" --lockfile-dir "$LOCK_DIR" --config.manage-package-manager-versions=false
        
        # Install dependencies for the package
        # Note: We don't use -C flag because it prevents pnpm from installing dependencies of link: packages
        # Instead, we cd into the package directory and use . as lockfile-dir
        cd "$PKG_DIR"
        ${pkgs.pnpm}/bin/pnpm install --frozen-lockfile --offline --store-dir "$STORE_DIR" --lockfile-dir . --config.manage-package-manager-versions=false --force ${if includeDevDependencies then "--prod=false" else ""}
        cd "$OLDPWD"

        # Set up PATH to include node_modules/.bin for build tools from the package directory
        export PATH="$PWD/$PKG_DIR/node_modules/.bin:$PATH"

        ${preBuild}

        ${if buildScript != null then 
          "cd \"$PKG_DIR\" && " + buildCommand
        else 
          ""
        }
        
        ${postBuild}
      '';

      installPhase = if installPhase != null then installPhase else defaultInstallPhase;
    } // builtins.removeAttrs args [
      "src"
      "pname"
      "version"
      "lockFile"
      "workspaceName"
      "packagePath"
      "buildScript"
      "installPhase"
      "includeDevDependencies"
      "nativeBuildInputs"
      "buildInputs"
      "preBuild"
      "postBuild"
    ]);

in
{
  inherit mkPnpmTarballs mkPnpmPackageV6V9 parsePnpmLock parsePackageKey makeTarballUrl;
}
