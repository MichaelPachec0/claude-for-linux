{
  description = "Claude Desktop for Linux - fully declarative NixOS package with Cowork support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Claude Desktop version and source
      claudeVersion = "1.12603.1";
      claudeDmgHash = "sha256-yiw07a2jfdb6RuUTIlPkjTEJtR/J/yw/JJph7g/CIrk=";
      claudeDmgUrl = "https://downloads.claude.ai/releases/darwin/universal/${claudeVersion}/Claude-3df4fd263723119bc45f0af2d784afd5055e2ba9.dmg";

      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      forEachSystem = f: builtins.listToAttrs (map (system: {
        name = system;
        value = f system;
      }) supportedSystems);

    in {
      packages = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Fetch macOS DMG
          claudeSrc = pkgs.fetchurl {
            url = claudeDmgUrl;
            hash = claudeDmgHash;
          };

          # Python ASAR tool
          asarTool = pkgs.writeScriptBin "asar-tool" ''
            #!${pkgs.python3}/bin/python3
            ${builtins.readFile ./tools/asar_tool.py}
          '';

          # Extract app.asar from DMG and apply patches
          claudeApp = pkgs.stdenv.mkDerivation {
            pname = "claude-desktop-app";
            version = claudeVersion;

            src = claudeSrc;

            nativeBuildInputs = with pkgs; [
              _7zz
              python3
              nodejs
              perl
            ];

            dontUnpack = true;

            buildPhase = ''
              runHook preBuild

              echo "=== Extracting Claude Desktop ${claudeVersion} ==="

              # Extract the app bundle straight from the DMG.
              # Modern 7-Zip decompresses LZFSE-compressed UDIF images natively;
              # dmg2img does not. Newer Claude DMGs (>= 1.118xx) are LZFSE-compressed,
              # which dmg2img silently corrupts ("LZFSE block found, but no support is
              # compiled in") so app.asar can never be located. The [3/6] find check
              # below is the real failure guard, so tolerate 7-Zip's cosmetic HFS
              # "Headers Error" warning on alternate streams.
              echo "[1/6] Extracting DMG (LZFSE-aware 7-Zip)..."
              mkdir -p dmg-contents
              7zz x -y -odmg-contents $src > /dev/null 2>&1 || true

              echo "[2/6] Extraction complete"

              # Find app.asar
              echo "[3/6] Locating app.asar..."
              APP_ASAR=$(find dmg-contents -name "app.asar" -path "*/Contents/Resources/*" | head -1)
              if [ -z "$APP_ASAR" ]; then
                echo "ERROR: app.asar not found in DMG"
                find dmg-contents -name "*.asar" || true
                exit 1
              fi
              echo "  Found: $APP_ASAR"

              # Also grab app.asar.unpacked if it exists
              APP_UNPACKED="$(dirname "$APP_ASAR")/app.asar.unpacked"

              # Locate the Resources directory (contains i18n, icons, etc.)
              RESOURCES_DIR="$(dirname "$APP_ASAR")"
              echo "  Resources dir: $RESOURCES_DIR"

              # Extract ASAR
              echo "[4/6] Extracting ASAR..."
              mkdir -p extracted
              ${asarTool}/bin/asar-tool extract "$APP_ASAR" extracted

              # Copy i18n resources into ASAR tree
              # The app looks for resources/i18n/*.json relative to the ASAR root
              echo "  Copying i18n resources..."
              mkdir -p extracted/resources/i18n
              for json in "$RESOURCES_DIR"/*.json; do
                if [ -f "$json" ]; then
                  cp "$json" extracted/resources/i18n/
                fi
              done
              echo "  Copied $(ls extracted/resources/i18n/*.json 2>/dev/null | wc -l) i18n files"

              # Copy tray icons directly into resources/ (not resources/icons/)
              # The app resolves icon paths via path.resolve(__dirname, "../..", "resources")
              echo "  Copying tray icons..."
              for icon in "$RESOURCES_DIR"/TrayIcon*.png "$RESOURCES_DIR"/Tray-Win32*.ico "$RESOURCES_DIR"/EchoTray*.png; do
                if [ -f "$icon" ]; then
                  cp "$icon" extracted/resources/
                fi
              done
              echo "  Copied $(ls extracted/resources/TrayIcon* extracted/resources/EchoTray* extracted/resources/Tray-Win32* 2>/dev/null | wc -l) tray icons"

              # Extract app icon from ICNS for notification icon and desktop entry
              echo "  Extracting app icons from ICNS..."
              ICNS_FILE="$RESOURCES_DIR/electron.icns"
              if [ -f "$ICNS_FILE" ]; then
                mkdir -p icon-extracted
                ${pkgs.python3}/bin/python3 ${./tools/icns_extract.py} "$ICNS_FILE" icon-extracted
                # Place 256px icon in ASAR resources as icon.png (used for notifications)
                if [ -f icon-extracted/256.png ]; then
                  cp icon-extracted/256.png extracted/resources/icon.png
                  echo "  Installed icon.png (256x256) for notifications"
                elif [ -f icon-extracted/512.png ]; then
                  cp icon-extracted/512.png extracted/resources/icon.png
                  echo "  Installed icon.png (512x512) for notifications"
                fi
              else
                echo "  WARNING: electron.icns not found, skipping app icon extraction"
              fi

              # Apply patches (version-resilient regex + dynamic discovery)
              echo "[5/6] Applying patches..."

              INDEX="extracted/.vite/build/index.js"
              MAINVIEW="extracted/.vite/build/mainView.js"

              # --- Patch 00: Native module stub ---
              echo "[patch:00] Installing native module stub..."
              mkdir -p extracted/node_modules/@ant/claude-native
              cp ${./modules/enhanced-claude-native-stub.js} extracted/node_modules/@ant/claude-native/index.js
              cat > extracted/node_modules/@ant/claude-native/package.json <<STUBPKG
              {"name":"@ant/claude-native","version":"1.0.0-linux-stub","main":"index.js"}
              STUBPKG
              echo "[patch:00] Done"

              # --- Patch 01: Cowork module loader ---
              echo "[patch:01] Installing cowork module..."
              mkdir -p extracted/node_modules/claude-cowork-linux
              cp ${./modules/claude-cowork-linux.js} extracted/node_modules/claude-cowork-linux/index.js
              cat > extracted/node_modules/claude-cowork-linux/package.json <<COWORKPKG
              {"name":"claude-cowork-linux","version":"2.0.0","main":"index.js"}
              COWORKPKG
              cat ${./scripts/cowork-init.js} >> "$INDEX"
              echo "[patch:01] Done"

              # --- Patch 02: Platform flag (regex) ---
              # Makes the Windows platform flag also true on Linux, routing through TS VM path
              echo "[patch:02] Patching platform flag..."
              perl -i -pe 's{(\w+=process\.platform==="darwin",)(\w+)(=process\.platform==="win32")}{$1$2$3||process.platform==="linux"}g' "$INDEX"
              grep -qP '\w+=process\.platform==="win32"\|\|process\.platform==="linux"' "$INDEX" \
                || { echo "ERROR: patch 02 (platform flag) failed to apply"; exit 1; }
              echo "[patch:02] Done"

              # --- Patch 03: Availability check (regex) ---
              # Prepends Linux "supported" return before the platform check
              echo "[patch:03] Patching availability check..."
              perl -i -pe 's{(function )(\w+)(\(\)\{)(const (\w+)=process\.platform;if\(\5!=="darwin"&&\5!=="win32"\)return\{status:"unsupported")}{$1$2$3if(process.platform==="linux"\&\&global.__linuxCowork)return\{status:"supported"\};$4}g' "$INDEX"
              grep -qP 'if\(process\.platform==="linux"&&global\.__linuxCowork\)return\{status:"supported"\}' "$INDEX" \
                || { echo "ERROR: patch 03 (availability check) failed to apply"; exit 1; }
              echo "[patch:03] Done"

              # --- Patch 04: Skip download (regex) ---
              # Skips macOS VM bundle download on Linux
              echo "[patch:04] Patching download skip..."
              perl -i -pe 's{(async function \w+\(\w+,\w+\)\{)(.{0,200}?\[downloadVM\])}{$1if(process.platform==="linux"\&\&global.__linuxCowork){console.log("[Cowork Linux] Skipping bundle download");return!1}$2}g' "$INDEX"
              grep -qP 'async function \w+\(\w+,\w+\)\{if\(process\.platform==="linux"' "$INDEX" \
                || { echo "ERROR: patch 04 (skip download) failed to apply"; exit 1; }
              echo "[patch:04] Done"

              # --- Patch 05: VM start intercept (dynamic Node.js) ---
              # Discovers function name via [VM:start] log string, injects bubblewrap session
              echo "[patch:05] Patching VM start intercept..."
              ${pkgs.nodejs}/bin/node ${./scripts/patch-vm-start.js} extracted
              echo "[patch:05] Done"

              # --- Patch 06a: VM getter (regex) ---
              # Returns Linux VM instance from getter function
              echo "[patch:06a] Patching VM getter..."
              perl -i -pe 's{(async function )(\w+)(\(\)\{)(const \w+=await \w+\(\);return\(\w+==null\?void 0:\w+\.vm\)\?\?null)}{$1$2$3if(process.platform==="linux"\&\&global.__linuxCowork\&\&global.__linuxCowork.vmInstance){console.log("[Cowork Linux] $2() returning Linux VM");return global.__linuxCowork.vmInstance}$4}g' "$INDEX"
              grep -qP '\[Cowork Linux\] \w+\(\) returning Linux VM' "$INDEX" \
                || { echo "ERROR: patch 06a (VM getter) failed to apply"; exit 1; }
              echo "[patch:06a] Done"

              # --- Patch 06b: Platform getter (regex) ---
              # Don't return null for Linux in platform-gated getter
              echo "[patch:06b] Patching platform getter..."
              perl -i -pe 's{(async function \w+\(\)\{return )process\.platform!=="darwin"\?null(:await \w+\(\))}{''${1}process.platform!=="darwin"\&\&process.platform!=="linux"?null''${2}}g' "$INDEX"
              grep -qP 'process\.platform!=="darwin"&&process\.platform!=="linux"\?null' "$INDEX" \
                || { echo "ERROR: patch 06b (platform getter) failed to apply"; exit 1; }
              echo "[patch:06b] Done"

              # --- Patch 07: Platform branding ---
              echo "[patch:07] Injecting platform branding fix..."
              cat ${./scripts/branding-fix.js} >> "$MAINVIEW"
              echo "[patch:07] Done"

              # --- Patch 08a: Tray icon resource path (regex) ---
              # Returns real filesystem path on Linux (COSMIC SNI can't read from ASAR)
              echo "[patch:08a] Patching tray icon resource path..."
              perl -i -pe 's{function ([\w\$]+)\(\)\{return (\w+)\.app\.isPackaged\?(\w+)\.resourcesPath:(\w+)\.resolve\(__dirname,"\.\.","\.\.","resources"\)\}}{function $1(){return process.platform==="linux"?$4.join($4.dirname($2.app.getAppPath()),"resources"):$2.app.isPackaged?$3.resourcesPath:$4.resolve(__dirname,"..","..","resources")}}g' "$INDEX"
              grep -qP 'process\.platform==="linux"\?\w+\.join\(\w+\.dirname\(' "$INDEX" \
                || { echo "ERROR: patch 08a (tray icon path) failed to apply"; exit 1; }
              echo "[patch:08a] Done"

              # --- Patch 08b: Tray icon filename (regex) ---
              # Linux uses theme-aware PNGs instead of Windows ICOs
              echo "[patch:08b] Patching tray icon filename selection..."
              perl -i -pe 's{(\w+)\?(\w+)=(\w+)\.nativeTheme\.shouldUseDarkColors\?"Tray-Win32-Dark\.ico":"Tray-Win32\.ico":(\w+)="TrayIconTemplate\.png"}{process.platform==="linux"?($2=$3.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"):$1?$2=$3.nativeTheme.shouldUseDarkColors?"Tray-Win32-Dark.ico":"Tray-Win32.ico":$4="TrayIconTemplate.png"}g' "$INDEX"
              grep -qP 'process\.platform==="linux"\?\(' "$INDEX" \
                || { echo "ERROR: patch 08b (tray icon filename) failed to apply"; exit 1; }
              echo "[patch:08b] Done"

              # --- Patch 10: Claude Code (CCD) host platform (regex) ---
              # The Claude Code-for-Desktop binary resolver's getHostPlatform() maps
              # darwin/win32 to a target triple and throws "Unsupported platform" on anything
              # else. On Linux that throw propagates up as "Failed to get commands from
              # temporary query" (the local-binary override path is dead code in this build,
              # so the throw is unavoidable otherwise). Teach it the linux targets — Anthropic
              # ships linux CCD binaries (the macOS Cowork VM is itself Linux), so resolution
              # can proceed via the normal preseed/download path instead of throwing.
              echo "[patch:10] Patching Claude Code host platform..."
              perl -i -pe 's{(getHostPlatform\(\)\{const (\w+)=process\.arch;if\(process\.platform==="darwin"\)return \2==="arm64"\?"darwin-arm64":"darwin-x64";if\(process\.platform==="win32"\)return \2==="arm64"\?"win32-arm64":"win32-x64";)}{$1if(process.platform==="linux")return $2==="arm64"?"linux-arm64":"linux-x64";}g' "$INDEX"
              grep -qP 'if\(process\.platform==="linux"\)return \w+==="arm64"\?"linux-arm64":"linux-x64"' "$INDEX" \
                || { echo "ERROR: patch 10 (CCD host platform) failed to apply"; exit 1; }
              echo "[patch:10] Done"

              # --- Patch 11: Shell-env worker path (regex) ---
              # The shell-PATH extractor forks shellPathWorker.js, but resolves it relative to
              # process.resourcesPath/app.asar (the standard packaged layout). Here app.asar
              # lives at app.getAppPath(), not under Electron's resourcesPath, so the fork fails
              # ("Shell path worker not found") and the app falls back to a bare process.env —
              # losing the user's real PATH for MCP servers and Cowork tools. Resolve via
              # __dirname (the asar dir of index.js) on Linux; the worker is forked from inside
              # the asar just as it is on macOS.
              echo "[patch:11] Patching shell-env worker path..."
              perl -i -pe 's{function (\w+)\(\)\{return (\w+)\.join\(process\.resourcesPath,"app\.asar","\.vite","build","shell-path-worker","shellPathWorker\.js"\)\}}{function $1(){return process.platform==="linux"?$2.join(__dirname,"shell-path-worker","shellPathWorker.js"):$2.join(process.resourcesPath,"app.asar",".vite","build","shell-path-worker","shellPathWorker.js")}}g' "$INDEX"
              grep -qP 'process\.platform==="linux"\?\w+\.join\(__dirname,"shell-path-worker","shellPathWorker\.js"\)' "$INDEX" \
                || { echo "ERROR: patch 11 (shell-env worker path) failed to apply"; exit 1; }
              echo "[patch:11] Done"

              # --- Patch 12: Tray in-place update (regex) ---
              # The single tray builder destroys and recreates the Tray on every call, and it's
              # invoked several times during startup (helper-app-launched + nativeTheme "updated"
              # + menuBarEnabled). Each new Tray re-exports the StatusNotifierItem / dbusmenu
              # D-Bus objects before the destroyed one finishes deregistering, spamming
              # "org.kde.StatusNotifierItem.* is already exported". On Linux, if a tray already
              # exists and is still wanted, update its image in place and return instead of
              # destroy+recreate (click handler and menu persist from first creation). This is
              # the race the removed patch 09 targeted, fixed without an (illegal) await.
              echo "[patch:12] Patching tray in-place update..."
              perl -i -pe 's{((\w+)===void 0;)(if\(\2&&\(\2\.destroy\(\),\2=null\),!(\w+)\)\{\w+\(\);return\}\2=new (\w+)\.Tray\(\5\.nativeImage\.createFromPath\((\w+)\)\))}{$1if(process.platform==="linux"&&$2&&$4){$2.setImage($5.nativeImage.createFromPath($6));return}$3}g' "$INDEX"
              grep -qP 'process\.platform==="linux"&&\w+&&\w+\)\{\w+\.setImage\(\w+\.nativeImage\.createFromPath\(\w+\)\);return\}' "$INDEX" \
                || { echo "ERROR: patch 12 (tray in-place update) failed to apply"; exit 1; }
              echo "[patch:12] Done"

              # --- Patch 09: DBus tray cleanup delay — REMOVED ---
              # This patch inserted `await new Promise(r=>setTimeout(r,250))` after every
              # `X&&(X.destroy(),X=null)` to space out StatusNotifierItem re-registration.
              # As of 1.11847.5 that pattern also matches the VM client pipe teardown
              # (I0/tQ/Iy in yMi()/SMi()) AND the tray itself (nE in HAe()) — all of which
              # are now SYNCHRONOUS functions. Injecting `await` into a non-async function
              # is a hard SyntaxError ("Unexpected token 'new'") that crashes the app at
              # startup. The tray-race mitigation is cosmetic and cannot be expressed as a
              # bare `await` here, so the patch is dropped. If the COSMIC tray race resurfaces,
              # reintroduce it as a node-script patch that makes HAe() async (and updates its
              # callers) rather than a blanket regex.

              # --- Verify: every patched file must still be valid JavaScript ---
              # A passing grep post-check only proves the *text* changed — not that the
              # result parses. A regex that injects e.g. `await` into a now-synchronous
              # function (as the old tray patch 09 did in 1.11847.5) builds fine but throws
              # "SyntaxError: Unexpected token" at startup. `node --check` is the parser, so
              # this turns that whole class of silent breakage into a hard build failure.
              echo "[verify] Syntax-checking patched JavaScript..."
              for jsfile in "$INDEX" "$MAINVIEW"; do
                ${pkgs.nodejs}/bin/node --check "$jsfile" \
                  || { echo "ERROR: $jsfile failed 'node --check' after patching (broken JS)"; exit 1; }
              done
              echo "[verify] Patched JavaScript parses cleanly"

              # Repack ASAR
              echo "[6/6] Repacking ASAR..."
              ${asarTool}/bin/asar-tool pack extracted app.asar

              echo "=== Build complete ==="

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/claude-desktop
              cp app.asar $out/lib/claude-desktop/

              # Copy unpacked resources if they exist
              if [ -d "$(dirname $(find dmg-contents -name 'app.asar' -path '*/Contents/Resources/*' | head -1))/app.asar.unpacked" ]; then
                cp -r "$(dirname $(find dmg-contents -name 'app.asar' -path '*/Contents/Resources/*' | head -1))/app.asar.unpacked" \
                  $out/lib/claude-desktop/app.asar.unpacked
              fi

              # Copy tray icons and app icon to real filesystem (alongside ASAR)
              # COSMIC's SNI can't read from inside ASAR archives, so these must
              # be on the real filesystem for the tray icon to display correctly.
              mkdir -p $out/lib/claude-desktop/resources
              for icon in extracted/resources/TrayIconTemplate*.png extracted/resources/icon.png; do
                if [ -f "$icon" ]; then
                  cp "$icon" $out/lib/claude-desktop/resources/
                fi
              done

              # Install hicolor theme icons for desktop entry
              if [ -d icon-extracted ]; then
                for png in icon-extracted/*.png; do
                  size=$(basename "$png" .png)
                  if [ "$size" -gt 0 ] 2>/dev/null; then
                    mkdir -p "$out/share/icons/hicolor/''${size}x''${size}/apps"
                    cp "$png" "$out/share/icons/hicolor/''${size}x''${size}/apps/claude.png"
                    echo "  Installed ''${size}x''${size} icon"
                  fi
                done
              fi

              runHook postInstall
            '';
          };

          # Basic Claude Desktop wrapper (direct electron)
          claudeDesktop = pkgs.symlinkJoin {
            name = "claude-desktop-${claudeVersion}";
            paths = [ claudeApp ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.electron}/bin/electron $out/bin/claude-desktop \
                --add-flags "$out/lib/claude-desktop/app.asar" \
                --add-flags "--no-sandbox" \
                --add-flags "--ozone-platform-hint=auto" \
                --add-flags "--class=Claude" \
                --add-flags "--password-store=gnome-libsecret" \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bubblewrap ]} \
                --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libsecret ]} \
                --set BWRAP_PATH "${pkgs.bubblewrap}/bin/bwrap" \
                --set COWORK_SANDBOX_GLIBC "${pkgs.glibc}/lib" \
                --set CHROME_DESKTOP "claude-desktop.desktop" \
                --prefix XDG_DATA_DIRS : "$out/share"

              # Desktop entry
              mkdir -p $out/share/applications
              cat > $out/share/applications/claude-desktop.desktop <<DESKTOP
              [Desktop Entry]
              Name=Claude
              Comment=Claude AI Assistant
              Exec=$out/bin/claude-desktop %U
              Icon=claude
              Type=Application
              Categories=Development;Utility;
              MimeType=x-scheme-handler/claude;
              StartupWMClass=Claude
              DESKTOP
              sed -i 's/^              //' $out/share/applications/claude-desktop.desktop
            '';
            meta = with pkgs.lib; {
              description = "Claude Desktop for Linux with Cowork support";
              homepage = "https://claude.ai";
              platforms = platforms.linux;
              mainProgram = "claude-desktop";
            };
          };

          # FHS wrapper for maximum compatibility (cowork + MCP)
          claudeDesktopFHS = pkgs.buildFHSEnv {
            name = "claude-desktop";
            targetPkgs = pkgs: with pkgs; [
              bubblewrap
              nodejs
              python3
              glibc
              openssl
              libsecret          # Electron safeStorage backend (gnome-libsecret) for token persistence
              docker-client
              coreutils
              bash
              gnugrep
              gnused
              gawk
              findutils
              git
              curl
              wget
            ];
            runScript = "${claudeDesktop}/bin/claude-desktop";
            meta = with pkgs.lib; {
              description = "Claude Desktop for Linux (FHS) with Cowork and MCP support";
              homepage = "https://claude.ai";
              platforms = platforms.linux;
              mainProgram = "claude-desktop";
            };
          };

        in {
          default = claudeDesktop;
          claude-desktop = claudeDesktop;
          claude-desktop-fhs = claudeDesktopFHS;
          claude-app = claudeApp;
          asar-tool = asarTool;
        }
      );

      apps = forEachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/claude-desktop";
        };
        claude-desktop = {
          type = "app";
          program = "${self.packages.${system}.claude-desktop}/bin/claude-desktop";
        };
        claude-desktop-fhs = {
          type = "app";
          program = "${self.packages.${system}.claude-desktop-fhs}/bin/claude-desktop";
        };
      });

      # NixOS module
      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.claude-desktop;
        in {
          options.programs.claude-desktop = {
            enable = lib.mkEnableOption "Claude Desktop with Cowork support";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.claude-desktop;
              defaultText = lib.literalExpression "claude-for-linux.packages.\${system}.claude-desktop";
              description = "The Claude Desktop package to use.";
            };

            fhs = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Use FHS wrapper for better MCP and Cowork compatibility.";
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [
              (if cfg.fhs
               then self.packages.${pkgs.system}.claude-desktop-fhs
               else cfg.package)
              pkgs.bubblewrap
            ];
          };
        };

      # Home Manager module
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.claude-desktop;
          pkg = if cfg.fhs
                then self.packages.${pkgs.system}.claude-desktop-fhs
                else cfg.package;
        in {
          options.programs.claude-desktop = {
            enable = lib.mkEnableOption "Claude Desktop with Cowork support";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.claude-desktop;
              defaultText = lib.literalExpression "claude-for-linux.packages.\${system}.claude-desktop";
              description = "The Claude Desktop package to use.";
            };

            fhs = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Use FHS wrapper for better MCP and Cowork compatibility.";
            };

            createDesktopEntry = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Create desktop entry for Claude Desktop.";
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ pkg pkgs.bubblewrap ];

            xdg.desktopEntries.claude-desktop = lib.mkIf cfg.createDesktopEntry {
              name = "Claude";
              genericName = "AI Assistant";
              exec = "${pkg}/bin/claude-desktop %U";
              icon = "claude";
              categories = [ "Development" "Utility" ];
              comment = "Claude Desktop with Linux Cowork support";
              mimeType = [ "x-scheme-handler/claude" ];
              settings = {
                StartupWMClass = "Claude";
              };
            };
          };
        };

      # Development shell
      devShells = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              nodejs
              python3
              bubblewrap
              electron_37
              _7zz

              # Development tools
              nodePackages.prettier
            ];

            shellHook = ''
              echo "Claude Desktop Linux Development Shell"
              echo ""
              echo "  node:     $(node --version)"
              echo "  python3:  $(python3 --version 2>&1)"
              echo "  bwrap:    $(bwrap --version 2>&1 | head -1)"
              echo "  electron: $(electron --version 2>/dev/null || echo 'available')"
              echo ""
              echo "Build:  nix build ."
              echo "Run:    nix run ."
              echo "FHS:    nix run .#claude-desktop-fhs"
            '';
          };
        }
      );
    };
}
