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
              # Match package keys - handle both unquoted and quoted keys
              # Quoted keys can contain : (e.g., '@exa-labs/prom-client@https://codeload.github.com/...')
              pkgMatchQuoted = builtins.match "^  ['\"](.+)['\"]:[[:space:]]*$" line;
              pkgMatchUnquoted = builtins.match "^  ([^:]+):[[:space:]]*$" line;
              pkgMatch = if pkgMatchQuoted != null then pkgMatchQuoted else pkgMatchUnquoted;
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
              # Include packages with integrity hash OR with tarball URL (for GitHub tarballs)
              if integrity != null || tarball != null then
                {
                  current = state.current;
                  acc = state.acc ++ [{
                    key = state.current;
                    integrity = integrity;  # may be null for GitHub tarballs
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

  # Canonicalize a path by resolving ".." and "." segments
  canonicalizePath = path:
    let
      # Split path into segments
      segments = lib.splitString "/" path;
      
      # Fold over segments to resolve ".." and remove "."
      canonicalize = acc: segment:
        if segment == "." || segment == "" then
          acc  # Skip "." and empty segments
        else if segment == ".." then
          # Go up one level by removing last segment
          if builtins.length acc > 0 then
            lib.init acc
          else
            acc  # Can't go above root
        else
          acc ++ [ segment ];  # Add normal segment
      
      canonicalSegments = builtins.foldl' canonicalize [] segments;
      canonicalPath = lib.concatStringsSep "/" canonicalSegments;
    in
    if canonicalPath == "" then "." else canonicalPath;

  # Parse link: dependencies from a single pnpm-lock.yaml
  parseLinkDepsFromSingleLock = lockFile:
    let
      text = builtins.readFile lockFile;
      lines = lib.splitString "\n" text;
      
      # Find importers section
      findImportersStart = lines:
        let
          indices = lib.imap0 (i: line:
            if builtins.match "^importers:[[:space:]]*$" line != null then i else null
          ) lines;
          filtered = builtins.filter (x: x != null) indices;
        in
        if builtins.length filtered > 0 then builtins.elemAt filtered 0 else null;
      
      importersStart = findImportersStart lines;
      
      # Parse dependencies looking for link: or file: versions
      parseDeps = lines:
        let
          processLine = state: line:
            let
              # Match version: link:../path or version: file:../path
              linkMatch = builtins.match "^[[:space:]]+version: (link:|file:)(.+)$" line;
              # Match dependency name (indented with specifier on next line)
              nameMatch = builtins.match "^[[:space:]]+([^:[:space:]]+):$" line;
            in
            if nameMatch != null then
              state // { currentName = builtins.elemAt nameMatch 0; }
            else if linkMatch != null && state.currentName != null then
              let
                prefix = builtins.elemAt linkMatch 0;
                path = builtins.elemAt linkMatch 1;
              in
              {
                currentName = null;
                deps = state.deps ++ [{
                  name = state.currentName;
                  relativePath = path;
                }];
              }
            else
              state;
          
          initialState = { currentName = null; deps = []; };
          finalState = lib.foldl processLine initialState lines;
        in
        finalState.deps;
      
      deps = if importersStart != null then parseDeps lines else [];
    in
    deps;

  # Recursively discover ALL transitive link deps (uv2nix-style: build everything in one pass)
  # This follows the chain: B -> C -> submodule, discovering all deps from their lockfiles
  # linkSources is used to override paths for deps outside the flake source tree (git submodules)
  discoverTransitiveLinkDeps = lockFile: linkSources:
    let
      lockFileDir = builtins.dirOf lockFile;
      
      # Helper to extract path from flake input
      getPath = src: if builtins.isPath src then src 
        else if builtins.isAttrs src && builtins.hasAttr "outPath" src then src.outPath
        else toString src;
      
      # Recursive helper with visited set for cycle detection
      discoverWithVisited = visited: currentLockFile:
        let
          currentLockDir = builtins.dirOf currentLockFile;
          directDeps = parseLinkDepsFromSingleLock currentLockFile;
          
          # Process each direct dep
          processDep = dep:
            let
              # Compute the absolute path for this dep
              depPath = if builtins.hasAttr dep.name linkSources
                then getPath linkSources.${dep.name}
                else currentLockDir + "/${dep.relativePath}";
              
              # Canonicalize path for cycle detection
              canonicalDepPath = toString depPath;
              
              # Check if this dep has its own lockfile
              depLockFile = depPath + "/pnpm-lock.yaml";
              hasLockFile = builtins.pathExists depLockFile;
              
              # Skip if already visited (cycle detection)
              alreadyVisited = builtins.elem canonicalDepPath visited;
              
              # Recursively get transitive deps if not visited and has lockfile
              transitiveDeps = if alreadyVisited || !hasLockFile then []
                else discoverWithVisited (visited ++ [canonicalDepPath]) depLockFile;
            in
            # Return this dep plus its transitive deps
            [{
              name = dep.name;
              relativePath = dep.relativePath;
              nixPath = depPath;
              fromLockFile = currentLockFile;
            }] ++ transitiveDeps;
          
          # Process all direct deps and flatten
          allDeps = builtins.concatLists (builtins.map processDep directDeps);
        in
        allDeps;
      
      # Start recursion with empty visited set
      allTransitiveDeps = discoverWithVisited [] lockFile;
      
      # Deduplicate by name (keep first occurrence)
      deduplicateByName = deps:
        let
          addIfNew = acc: dep:
            if builtins.any (d: d.name == dep.name) acc then acc
            else acc ++ [dep];
        in
        builtins.foldl' addIfNew [] deps;
    in
    deduplicateByName allTransitiveDeps;

  # Legacy: Parse link deps from a single lockfile (non-recursive)
  parseLinkDepsFromLock = parseLinkDepsFromSingleLock;

  # Discover link: dependencies recursively from package.json with cycle detection
  # (kept for backward compatibility, but new code should use parseLinkDepsFromLock)
  discoverLinkDeps = src: packagePath:
    let
      # Internal helper that tracks visited paths to prevent infinite recursion
      discoverLinkDepsWithVisited = visited: currentPath:
        let
          # Canonicalize path to handle ".." and "." segments
          canonicalPath = canonicalizePath currentPath;
          
          # Check if we've already visited this path
          alreadyVisited = builtins.elem canonicalPath visited;
        in
        if alreadyVisited then
          []  # Return empty list to break the cycle
        else
          let
            packageJsonPath = src + "/${canonicalPath}/package.json";
            packageJson = if builtins.pathExists packageJsonPath then
              builtins.fromJSON (builtins.readFile packageJsonPath)
            else
              {};
            
            deps = (packageJson.dependencies or {}) // (packageJson.devDependencies or {});
            
            linkDeps = builtins.filter (name:
              let value = deps.${name}; in
              lib.hasPrefix "link:" value || lib.hasPrefix "file:" value
            ) (builtins.attrNames deps);
            
            resolveLinkPath = name:
              let
                value = deps.${name};
                relativePath = if lib.hasPrefix "link:" value then
                  lib.removePrefix "link:" value
                else
                  lib.removePrefix "file:" value;
                # Resolve relative to currentPath
                resolvedPath = if canonicalPath == "." then
                  relativePath
                else
                  "${canonicalPath}/${relativePath}";
              in
              {
                inherit name;
                path = resolvedPath;
                lockFile = src + "/${resolvedPath}/pnpm-lock.yaml";
              };
            
            directLinks = builtins.map resolveLinkPath linkDeps;
            
            # Add current path to visited set
            newVisited = visited ++ [ canonicalPath ];
            
            # Recursively discover transitive link: dependencies
            recurse = link:
              let
                transitive = discoverLinkDepsWithVisited newVisited link.path;
              in
              [ link ] ++ transitive;
            
            allLinks = lib.unique (lib.flatten (builtins.map recurse directLinks));
          in
          allLinks;
    in
    discoverLinkDepsWithVisited [] packagePath;

  mkPnpmTarballs = { lockFile, src ? null, packagePath ? ".", linkDepsOverride ? null }:
    let
      # Use override if provided (holy mode), otherwise discover from src (legacy mode)
      linkDeps = if linkDepsOverride != null then
        linkDepsOverride
      else if src != null then 
        discoverLinkDeps src packagePath 
      else 
        [];
      
      # Check if there's a lockfile at the src root (monorepo root) - only in legacy mode
      srcRootLockFile = if src != null then src + "/pnpm-lock.yaml" else null;
      hasSrcRootLockFile = srcRootLockFile != null && builtins.pathExists srcRootLockFile;
      
      # Collect all lockfiles (main + src root + linked packages)
      allLockFiles = [ lockFile ] 
        ++ (if hasSrcRootLockFile && srcRootLockFile != lockFile then [ srcRootLockFile ] else [])
        ++ (builtins.filter (lf: lf != null) (builtins.map (link: link.lockFile) linkDeps));
      
      # Parse all lockfiles and merge packages
      allLocks = builtins.map parsePnpmLock allLockFiles;
      allPackages = lib.flatten (builtins.map (lock: lock.packages) allLocks);
      
      # Deduplicate by key (first occurrence wins)
      uniquePackages = lib.foldl (acc: pkg:
        if builtins.any (p: p.key == pkg.key) acc then
          acc
        else
          acc ++ [ pkg ]
      ) [] allPackages;

      tarballDrvs = builtins.map (pkg:
        let
          parsed = parsePackageKey pkg.key;
          url = if pkg.tarball != null then pkg.tarball else makeTarballUrl parsed.name parsed.version;
          # For GitHub tarballs without integrity hash, use fetchurl without hash
          # This requires impure evaluation but is necessary for GitHub dependencies
          isGitHubTarball = pkg.tarball != null && 
            (lib.hasPrefix "https://codeload.github.com" pkg.tarball ||
             lib.hasPrefix "https://github.com" pkg.tarball);
        in
        {
          key = pkg.key;
          # Track if this is a directory (from builtins.fetchTarball) or file (from fetchurl)
          isDir = isGitHubTarball && pkg.integrity == null;
          drv = if pkg.integrity != null then
            pkgs.fetchurl {
              inherit url;
              hash = pkg.integrity;
            }
          else if isGitHubTarball then
            # GitHub tarballs don't have integrity hashes, use builtins.fetchTarball
            # This requires --impure flag when building
            # Note: builtins.fetchTarball returns a directory, not a file
            builtins.fetchTarball {
              inherit url;
            }
          else
            # Fallback: try to fetch without hash (will fail if not in cache)
            pkgs.fetchurl {
              inherit url;
            };
        }
      ) uniquePackages;

      manifest = builtins.toJSON (
        builtins.listToAttrs (
          builtins.map (item: {
            name = item.key;
            # For directories (GitHub tarballs), the output will be basename.tgz
            # For files (regular tarballs), the output is just the basename
            value = if item.isDir then 
              "${item.drv}.tgz"  # This will be replaced with actual path in runCommand
            else 
              "${item.drv}";
          }) tarballDrvs
        )
      );
      
      # Also store the list of link dependencies and their lockfiles for buildPhase
      linkDepsJson = builtins.toJSON (builtins.map (link: {
        inherit (link) name path;
        lockFile = toString link.lockFile;
      }) linkDeps);

    in
    pkgs.runCommand "pnpm-tarballs" {
      nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
    } (
      ''
        mkdir -p "$out"
      '' + lib.concatMapStringsSep "\n" (item:
        if item.isDir then
          # For directories (from builtins.fetchTarball), re-tar them
          ''tar -czf "$out/$(basename "${item.drv}").tgz" -C "${item.drv}" .''
        else
          # For files (from fetchurl), just copy
          ''cp "${item.drv}" "$out/$(basename "${item.drv}")"''
      ) tarballDrvs + ''
        
        # Write manifest.json
        cat > "$out/manifest.json" <<'EOF'
${manifest}
EOF
        
        # Write link-deps.json for buildPhase
        cat > "$out/link-deps.json" <<'EOF'
${linkDepsJson}
EOF
      ''
    );

  # New function: mkPnpmNodeModules - returns just node_modules derivation
  # uv2nix-style: paths resolved from lockfile, minimal configuration needed
  # 
  # Simple usage (like uv2nix):
  #   mkPnpmNodeModules { lockFile = ./pnpm-lock.yaml; }
  #
  # For git submodule deps only:
  #   mkPnpmNodeModules { 
  #     lockFile = ./pnpm-lock.yaml;
  #     linkSources = { "escape-string-regexp" = escape-string-regexp; };
  #   }
  mkPnpmNodeModules = {
    # Path to pnpm-lock.yaml (required)
    lockFile,
    # Optional: workspace root for resolving link deps
    # Defaults to directory containing lockFile (like uv2nix)
    workspaceRoot ? null,
    # Optional: importer path (only needed for multi-importer lockfiles)
    # Defaults to "." for single-importer lockfiles
    importer ? null,
    packagePath ? null,  # deprecated, use importer
    includeDevDependencies ? true,
    installLinkDeps ? true,
    # Optional: explicit sources for link deps that are git submodules
    # Only needed when link deps are in git submodules (nix doesn't include submodules in flake source)
    # Example: { "escape-string-regexp" = escape-string-regexp-flake-input; }
    linkSources ? {},
    # Legacy mode: if true, use old package.json walking for link dep discovery
    # If false (default), parse link deps from lockfile (uv2nix-style)
    legacyWorkspaceMode ? false,
    # Skip transitive link dep discovery (useful when using linkWorkspace in mkNodePackage)
    # Set to true when local deps are provided via flake inputs and linkWorkspace
    skipTransitiveLinkDeps ? false,
    ...
  }@args:
    let
      # Derive workspaceRoot from lockFile if not provided (uv2nix-style)
      effectiveWorkspaceRoot = if workspaceRoot != null then workspaceRoot else builtins.dirOf lockFile;
      
      # Use importer if provided, otherwise fall back to packagePath, otherwise default to "."
      effectiveImporter = if importer != null then importer 
        else if packagePath != null then packagePath 
        else ".";
      
      # uv2nix-style: Recursively discover ALL transitive link deps in one pass
      # This follows B -> C -> submodule, building everything together
      # Skip if skipTransitiveLinkDeps is true (when using linkWorkspace in mkNodePackage)
      allTransitiveLinkDeps = if skipTransitiveLinkDeps then [] else discoverTransitiveLinkDeps lockFile linkSources;
      
      # Helper to extract path from flake input (which may be an attrset with outPath)
      getPath = src: if builtins.isPath src then src 
        else if builtins.isAttrs src && builtins.hasAttr "outPath" src then src.outPath
        else toString src;
      
      # Build linkDepPaths from the transitive deps
      lockFileDir = builtins.dirOf lockFile;
      linkDepPaths = builtins.listToAttrs (builtins.map (dep: {
        name = dep.name;
        value = {
          relativePath = dep.relativePath;
          nixPath = dep.nixPath;
          # Check if the linked package has its own lockfile
          lockFile = let p = dep.nixPath + "/pnpm-lock.yaml"; in
            if builtins.pathExists p then p else null;
        };
      }) allTransitiveLinkDeps);
      
      # For legacy mode, use the old discovery method
      legacyLinkDeps = if legacyWorkspaceMode then discoverLinkDeps effectiveWorkspaceRoot effectiveImporter else [];
      
      # Build link deps list for mkPnpmTarballs
      linkDepsForTarballs = if legacyWorkspaceMode then
        legacyLinkDeps
      else
        builtins.map (dep: {
          name = dep.name;
          path = dep.relativePath;
          lockFile = linkDepPaths.${dep.name}.lockFile;
        }) allTransitiveLinkDeps;
      
      pnpmTarballs = mkPnpmTarballs { 
        inherit lockFile;
        # In uv2nix-style mode, we don't pass src to mkPnpmTarballs for discovery
        # Instead, we pass the pre-computed link deps from lockfile
        src = if legacyWorkspaceMode then effectiveWorkspaceRoot else null;
        packagePath = effectiveImporter;
        linkDepsOverride = if legacyWorkspaceMode then null else linkDepsForTarballs;
      };

      # Compute lockfile directory relative to effectiveWorkspaceRoot
      lockDir = builtins.dirOf lockFile;
      lockFileName = builtins.baseNameOf lockFile;
      lockFileRelative = if lib.hasPrefix (toString effectiveWorkspaceRoot) (toString lockFile) then
        lib.removePrefix "${toString effectiveWorkspaceRoot}/" (toString lockFile)
      else
        lockFileName;
      
      # Reuse the same patch.py logic from original mkPnpmPackageV6V9
      patchPy = pkgs.writeText "patch.py" ''
        import json
        import sys
        import os
        from ruamel.yaml import YAML

        manifest_path = '${pnpmTarballs}/manifest.json'
        link_deps_path = '${pnpmTarballs}/link-deps.json'

        with open(manifest_path, 'r') as f:
            manifest = json.load(f)

        with open(link_deps_path, 'r') as f:
            link_deps = json.load(f)

        yaml = YAML()
        yaml.preserve_quotes = True
        yaml.default_flow_style = False

        def patch_lockfile(lockfile_path):
            if not os.path.exists(lockfile_path):
                print(f"Warning: Lockfile {lockfile_path} does not exist, skipping")
                return 0
            
            # Check if the lockfile is writable (not in nix store)
            # Linked lockfiles that point to nix store paths are already patched
            if not os.access(lockfile_path, os.W_OK):
                print(f"Skipping read-only lockfile: {lockfile_path} (already in nix store)")
                return 0
                
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
            
            return patches_applied

        main_lockfile = '${lockFileRelative}'
        print(f"Patching main lockfile: {main_lockfile}")
        patches = patch_lockfile(main_lockfile)
        print(f"Applied {patches} patches to {main_lockfile}")

        for link in link_deps:
            link_lockfile = link['path'] + '/pnpm-lock.yaml'
            print(f"Patching linked lockfile: {link_lockfile}")
            patches = patch_lockfile(link_lockfile)
            print(f"Applied {patches} patches to {link_lockfile}")
      '';

      # JSON of link dep paths for holy mode buildPhase
      linkDepPathsJson = builtins.toJSON (lib.mapAttrs (name: info: {
        relativePath = info.relativePath;
        nixPath = toString info.nixPath;
      }) linkDepPaths);

    in
    pkgs.stdenvNoCC.mkDerivation {
      name = "pnpm-node-modules-${builtins.replaceStrings ["/"] ["-"] effectiveImporter}";
      src = effectiveWorkspaceRoot;

      nativeBuildInputs = with pkgs; [
        nodejs
        pnpm
        python3Packages.ruamel-yaml
        jq
      ];
      
      # Skip fixupPhase which includes noBrokenSymlinks check
      # We handle link: dependencies manually in buildPhase
      dontFixup = true;

      buildPhase = ''
        set -euo pipefail
        set -x
        
        export HOME=$TMPDIR/home
        mkdir -p "$HOME"

        STORE_DIR="$TMPDIR/pnpm-store"
        mkdir -p "$STORE_DIR"
        
        export CI=true
        export PNPM_STORE_DIR="$STORE_DIR"
        export PNPM_HOME="${pkgs.pnpm}/bin"
        export NPM_CONFIG_OFFLINE=true
        export NPM_CONFIG_AUDIT=false
        export NPM_CONFIG_FUND=false
        export npm_config_update_notifier=false
        export npm_config_manage_package_manager_versions=false
        ${if includeDevDependencies then "export NPM_CONFIG_PRODUCTION=false" else ""}

        PKG_DIR="${effectiveImporter}"
        LOCK_FILE_REL="${lockFileRelative}"
        LOCK_DIR=$(dirname "$LOCK_FILE_REL")

        ${if !legacyWorkspaceMode && builtins.length allTransitiveLinkDeps > 0 then ''
        # Holy mode: create symlinks from expected relative paths to Nix store paths
        echo "Setting up link: dependencies (holy mode)"
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: info: 
          if info.nixPath != null then ''
          LINK_REL_PATH="${info.relativePath}"
          LINK_NIX_PATH="${info.nixPath}"
          echo "Creating symlink: $LINK_REL_PATH -> $LINK_NIX_PATH"
          mkdir -p "$(dirname "$LINK_REL_PATH")"
          if [ -e "$LINK_REL_PATH" ]; then
            rm -rf "$LINK_REL_PATH"
          fi
          ln -s "$LINK_NIX_PATH" "$LINK_REL_PATH"
          '' else ''
          echo "Warning: No source provided for link dep ${name} (${info.relativePath})"
          ''
        ) linkDepPaths)}
        '' else ""}

        if [ -f "$PKG_DIR/package.json" ]; then
          echo "Removing packageManager field from $PKG_DIR/package.json"
          ${pkgs.jq}/bin/jq 'del(.packageManager)' "$PKG_DIR/package.json" > "$PKG_DIR/package.json.tmp" && mv "$PKG_DIR/package.json.tmp" "$PKG_DIR/package.json"
        fi

        ${pkgs.python3}/bin/python3 ${patchPy}

        echo "Fetching dependencies for main lockfile: $LOCK_DIR"
        ${pkgs.pnpm}/bin/pnpm fetch --offline --frozen-lockfile --store-dir "$STORE_DIR" --lockfile-dir "$LOCK_DIR" --config.manage-package-manager-versions=false
        
        ${if installLinkDeps then ''
        if [ -f "${pnpmTarballs}/link-deps.json" ]; then
          ${pkgs.jq}/bin/jq -c '.[]' "${pnpmTarballs}/link-deps.json" | while read -r link; do
            LINK_PATH=$(echo "$link" | ${pkgs.jq}/bin/jq -r '.path')
            LINK_NAME=$(echo "$link" | ${pkgs.jq}/bin/jq -r '.name')
            
            # Skip if linked path is in nix store (read-only, already built)
            if [[ "$LINK_PATH" == /nix/store/* ]] || [[ "$(${pkgs.coreutils}/bin/realpath -m "$LINK_PATH")" == /nix/store/* ]]; then
              echo "Skipping fetch for $LINK_NAME (in nix store, already built)"
              continue
            fi
            
            if [ -f "$LINK_PATH/pnpm-lock.yaml" ]; then
              echo "Fetching dependencies for linked package $LINK_NAME at $LINK_PATH"
              ${pkgs.pnpm}/bin/pnpm fetch --offline --frozen-lockfile --store-dir "$STORE_DIR" --lockfile-dir "$LINK_PATH" --config.manage-package-manager-versions=false || echo "Warning: Failed to fetch for $LINK_PATH"
            fi
          done
        fi
        
        if [ -f "${pnpmTarballs}/link-deps.json" ]; then
          ${pkgs.jq}/bin/jq -c '.[]' "${pnpmTarballs}/link-deps.json" | while read -r link; do
            LINK_PATH=$(echo "$link" | ${pkgs.jq}/bin/jq -r '.path')
            LINK_NAME=$(echo "$link" | ${pkgs.jq}/bin/jq -r '.name')
            
            # Skip if linked path is in nix store (read-only, already built)
            if [[ "$LINK_PATH" == /nix/store/* ]] || [[ "$(${pkgs.coreutils}/bin/realpath -m "$LINK_PATH")" == /nix/store/* ]]; then
              echo "Skipping install for $LINK_NAME (in nix store, already built)"
              continue
            fi
            
            if [ -f "$LINK_PATH/pnpm-lock.yaml" ]; then
              echo "Installing dependencies for linked package $LINK_NAME at $LINK_PATH"
              cd "$LINK_PATH"
              ${pkgs.pnpm}/bin/pnpm install --frozen-lockfile --offline --store-dir "$STORE_DIR" --lockfile-dir . --config.manage-package-manager-versions=false --force ${if includeDevDependencies then "--prod=false" else ""} || echo "Warning: Failed to install for $LINK_PATH"
              cd "$OLDPWD"
            fi
          done
        fi
        '' else ""}
        
        cd "$PKG_DIR"
        ${pkgs.pnpm}/bin/pnpm install --frozen-lockfile --offline --store-dir "$STORE_DIR" --lockfile-dir . --config.manage-package-manager-versions=false --force ${if includeDevDependencies then "--prod=false" else ""}
        cd "$OLDPWD"
        
        ${if installLinkDeps then ''
        # Post-install fixup: rewrite link: dependencies to point to valid Nix store paths
        if [ -f "${pnpmTarballs}/link-deps.json" ]; then
          echo "Fixing link: dependencies to point to valid Nix store paths"
          ${pkgs.jq}/bin/jq -c '.[]' "${pnpmTarballs}/link-deps.json" | while read -r link; do
            LINK_PATH=$(echo "$link" | ${pkgs.jq}/bin/jq -r '.path')
            LINK_NAME=$(echo "$link" | ${pkgs.jq}/bin/jq -r '.name')
            
            # Compute absolute path to the linked package in the Nix store
            ABS_PATH=$(${pkgs.coreutils}/bin/realpath -m "$LINK_PATH")
            DEST="$PKG_DIR/node_modules/$LINK_NAME"
            
            if [ -e "$ABS_PATH" ]; then
              echo "Fixing link: $LINK_NAME -> $ABS_PATH"
              # Create parent directory for scoped packages (e.g., @scope/pkg)
              mkdir -p "$(dirname "$DEST")"
              rm -rf "$DEST"
              ln -s "$ABS_PATH" "$DEST"
            else
              echo "Warning: Link target $ABS_PATH does not exist for $LINK_NAME"
            fi
          done
        fi
        '' else ""}
      '';

      installPhase = ''
        mkdir -p $out
        
        if [ -d "${effectiveImporter}/node_modules" ]; then
          cp -r "${effectiveImporter}/node_modules" $out/
        fi
        
        cp ${pnpmTarballs}/manifest.json $out/
        cp ${pnpmTarballs}/link-deps.json $out/
      '';
    };

  # New function: mkNodePackage - wrapper that uses node_modules + runs build
  mkNodePackage = {
    src,
    nodeModulesDrv,
    pname,
    version ? "1.0.0",
    buildScript ? "build",
    workspaceName ? null,
    installPhase ? null,
    linkWorkspace ? {},
    nativeBuildInputs ? [],
    buildInputs ? [],
    preBuild ? "",
    postBuild ? "",
    ...
  }@args:
    let
      defaultInstallPhase = ''
        mkdir -p $out
        if [ -d "dist" ]; then
          cp -r dist $out/
        fi
        if [ -f "package.json" ]; then
          cp package.json $out/
        fi
      '';

      buildCommand = if workspaceName != null then
        "pnpm -r --filter '^${workspaceName}' run ${buildScript}"
      else
        "pnpm run ${buildScript}";

    in
    pkgs.stdenvNoCC.mkDerivation ({
      inherit pname version src;

      nativeBuildInputs = with pkgs; [
        nodejs
        pnpm
      ] ++ nativeBuildInputs;

      inherit buildInputs;

      buildPhase = ''
        set -euo pipefail
        set -x
        
        # Remove packageManager field from package.json to prevent pnpm from trying to install itself
        if [ -f "package.json" ]; then
          echo "Removing packageManager field from package.json"
          ${pkgs.jq}/bin/jq 'del(.packageManager)' package.json > package.json.tmp && mv package.json.tmp package.json
        fi
        
        if [ -d "${nodeModulesDrv}/node_modules" ]; then
          cp -r "${nodeModulesDrv}/node_modules" ./
          # Make node_modules writable so we can modify it
          chmod -R u+w node_modules
        fi
        
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: output: ''
          if [ -L "node_modules/${name}" ] || [ -d "node_modules/${name}" ]; then
            rm -rf "node_modules/${name}"
            ln -s "${output}" "node_modules/${name}"
          fi
        '') linkWorkspace)}
        
        export PATH="$PWD/node_modules/.bin:$PATH"

        ${preBuild}

        ${if buildScript != null then buildCommand else ""}
        
        ${postBuild}
      '';

      installPhase = if installPhase != null then installPhase else defaultInstallPhase;
    } // builtins.removeAttrs args [
      "src"
      "nodeModulesDrv"
      "pname"
      "version"
      "buildScript"
      "workspaceName"
      "installPhase"
      "linkWorkspace"
      "nativeBuildInputs"
      "buildInputs"
      "preBuild"
      "postBuild"
    ]);

  # Backward compatibility wrapper
  mkPnpmPackageV6V9 = {
    src,
    pname,
    version ? "1.0.0",
    lockFile ? "${src}/pnpm-lock.yaml",
    workspaceName ? null,
    packagePath ? ".",
    importer ? null,
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
      effectiveImporter = if importer != null then importer else packagePath;
      
      nodeModulesDrv = mkPnpmNodeModules {
        workspaceRoot = src;  # For backward compat, src is the workspace root
        inherit lockFile includeDevDependencies;
        importer = effectiveImporter;
        # Use legacy mode for backward compatibility
        legacyWorkspaceMode = true;
      };
    in
    mkNodePackage ({
      inherit src nodeModulesDrv pname version buildScript workspaceName installPhase nativeBuildInputs buildInputs preBuild postBuild;
    } // builtins.removeAttrs args [
      "src"
      "pname"
      "version"
      "lockFile"
      "workspaceName"
      "packagePath"
      "importer"
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
  inherit mkPnpmTarballs mkPnpmNodeModules mkNodePackage mkPnpmPackageV6V9 parsePnpmLock parsePackageKey makeTarballUrl;
}
