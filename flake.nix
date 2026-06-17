{
  description = "Claude Desktop for Linux - fully declarative NixOS package with Cowork support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Claude Desktop version and source
      claudeVersion = "1.13576.0";
      claudeDmgHash = "sha256-1Vu29njSi5aEMXU1Bo7QtSEV8ZLBdDj27Y0rgSRV3D8=";
      claudeDmgUrl = "https://downloads.claude.ai/releases/darwin/universal/${claudeVersion}/Claude-1290fc2ef5fd27a3883b74505e0ff917413d6832.dmg";

      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      forEachSystem = f: builtins.listToAttrs (map (system: {
        name = system;
        value = f system;
      }) supportedSystems);

    in {
      packages = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Real glibc dynamic loader, used to run Anthropic's generic-Linux Claude Code
          # binary on NixOS (its baked /lib64/ld-linux interpreter is a NixOS stub). See
          # patch 16 + scripts/ccd-ld-wrap.js.
          glibcLdso = "${pkgs.glibc}/lib/${
            if system == "aarch64-linux" then "ld-linux-aarch64.so.1" else "ld-linux-x86-64.so.2"
          }";

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

              # --- Patch 02: Platform flag — REMOVED ---
              # Historically this flipped the Windows VM-client flag true on Linux so the
              # app would route through the TypeScript/IPC VM path instead of @ant/claude-swift.
              # As of 1.13576.0 Anthropic dropped the Windows VM client entirely: there is a
              # single Swift loader (B_t()/qo()) and the availability check (S3i/Hce, patch 03)
              # hardcodes "darwin" with no win32 branch left to piggyback on — so the old
              # `X=process.platform==="darwin",Y=process.platform==="win32"` pair no longer
              # exists. The routing job this patch did is now fully covered by patch 03
              # (make availability "supported" on Linux) plus patch 06a (return the Linux VM
              # instance from the getter before the Swift module is ever touched). Dropped.

              # --- Patch 03: Availability check (regex) ---
              # The Cowork capability check (S3i, reached via Hce()/X_().yukonSilver) hardcodes
              # `const A="darwin",e=process.arch` then probes the macOS version and
              # `require("@ant/claude-swift").vm.isVirtualizationSupported()` — all of which
              # fail (or throw) on Linux. Short-circuit it: when global.__linuxCowork is live,
              # return {status:"supported"} before any darwin/Swift logic runs. Hce() then flows
              # through the platform-agnostic enterprise gating to Vj({status:"supported"}),
              # so both the sync (X_()) and async (o0A()) availability paths report supported.
              echo "[patch:03] Patching availability check..."
              perl -i -pe 's{(function \w+\(\)\{var \w+;const \w+="darwin",\w+=process\.arch;)}{$1if(process.platform==="linux"\&\&global.__linuxCowork)return\{status:"supported"\};}g' "$INDEX"
              grep -qP 'const \w+="darwin",\w+=process\.arch;if\(process\.platform==="linux"&&global\.__linuxCowork\)return\{status:"supported"\}' "$INDEX" \
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
              # Linux uses theme-aware PNGs instead of Windows ICOs. The filename is now chosen
              # by `switch(Y1r){case"ico":...;case"template-image":e="TrayIconTemplate.png";...}`
              # where Y1r is hardcoded "template-image" — a flat (non-theme-aware) icon that
              # won't adapt to a dark panel on Linux. Rewrite only the template-image case so
              # Linux picks the dark/light PNG by nativeTheme (matching the existing "png" case),
              # while macOS keeps its OS-adapted template image untouched.
              echo "[patch:08b] Patching tray icon filename selection..."
              perl -i -pe 's{(switch\(\w+\)\{case"ico":\w+=(\w+)\.nativeTheme\.shouldUseDarkColors\?"Tray-Win32-Dark\.ico":"Tray-Win32\.ico";break;case"template-image":)(\w+)="TrayIconTemplate\.png";break}{$1$3=process.platform==="linux"?($2.nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"):"TrayIconTemplate.png";break}g' "$INDEX"
              grep -qP 'case"template-image":\w+=process\.platform==="linux"\?\(\w+\.nativeTheme\.shouldUseDarkColors\?"TrayIconTemplate-Dark\.png"' "$INDEX" \
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
              # The builder now computes the image path first (`const t=join(dir(),e)`), then
              # runs `if(OQ&&(OQ.destroy(),OQ=null),!A){...return}OQ=new Tray(...createFromPath(t))`.
              # Inject the Linux in-place update before that destroy/recreate, while the old
              # tray (OQ) is still live: if it exists and is still wanted (A), setImage and return.
              echo "[patch:12] Patching tray in-place update..."
              perl -i -pe 's{(const (\w+)=\w+\.join\([\w\$]+\(\),\w+\);)(if\((\w+)&&\(\4\.destroy\(\),\4=null\),!(\w+)\)\{[\w\$]+\(\);return\}\4=new (\w+)\.Tray\(\6\.nativeImage\.createFromPath\(\2\)\))}{$1if(process.platform==="linux"&&$4&&$5){$4.setImage($6.nativeImage.createFromPath($2));return}$3}g' "$INDEX"
              grep -qP 'process\.platform==="linux"&&\w+&&\w+\)\{\w+\.setImage\(\w+\.nativeImage\.createFromPath\(\w+\)\);return\}' "$INDEX" \
                || { echo "ERROR: patch 12 (tray in-place update) failed to apply"; exit 1; }
              echo "[patch:12] Done"

              # --- Patch 13: macOS-only systemPreferences.setUserDefault guard (regex) ---
              # Top-level app init unconditionally calls
              # `systemPreferences.setUserDefault("NSAutoFillHeuristicsEnabled","boolean",!1)`.
              # setUserDefault is a macOS-only Electron API; on Linux it's undefined, so the
              # call throws "setUserDefault is not a function" during module load and the app
              # crashes at startup. Gate it behind a darwin check (`&&` short-circuits on Linux,
              # leaving the trailing comma-sequence — e.g. ...,GCo() — to run untouched). The
              # other systemPreferences.* calls are already darwin-gated or runtime/try-catch'd.
              echo "[patch:13] Patching systemPreferences.setUserDefault guard..."
              perl -i -pe 's{(\w+)\.systemPreferences\.setUserDefault\(}{process.platform==="darwin"\&\&$1.systemPreferences.setUserDefault(}g' "$INDEX"
              grep -qP 'process\.platform==="darwin"&&\w+\.systemPreferences\.setUserDefault\(' "$INDEX" \
                || { echo "ERROR: patch 13 (setUserDefault guard) failed to apply"; exit 1; }
              echo "[patch:13] Done"

              # --- Patch 14: macOS-only app.configureWebAuthn guard (regex) ---
              # The same top-level init (right after setUserDefault) calls GCo(), whose entire
              # body is `app.configureWebAuthn({touchID:{keychainAccessGroup:...}})`. That Touch
              # ID WebAuthn config is macOS-only; configureWebAuthn is absent on Linux's Electron,
              # so it throws "configureWebAuthn is not a function" at module load — the next
              # startup crash after patch 13. Gate it behind a darwin check (Anthropic ships it
              # working on macOS; on Linux the `&&` short-circuits to a no-op).
              echo "[patch:14] Patching app.configureWebAuthn guard..."
              perl -i -pe 's{(\w+)\.app\.configureWebAuthn\(}{process.platform==="darwin"\&\&$1.app.configureWebAuthn(}g' "$INDEX"
              grep -qP 'process\.platform==="darwin"&&\w+\.app\.configureWebAuthn\(' "$INDEX" \
                || { echo "ERROR: patch 14 (configureWebAuthn guard) failed to apply"; exit 1; }
              echo "[patch:14] Done"

              # --- Patch 15: macOS-only BrowserWindow method guards (regex) ---
              # Two BrowserWindow instance methods are macOS-only and absent on Linux's Electron,
              # so they throw "X is not a function" when their window is created/updated:
              #   15a setWindowButtonPosition — positions the traffic-light buttons (called from
              #       the zoom-factor handler on the main window).
              #   15b setHiddenInMissionControl — one call (the quick-entry window) is unguarded;
              #       the other two sites are already `process.platform==="darwin"&&`-gated.
              # Convert both to optional-call (`method?.(...)`) — the idiom the app itself uses for
              # platform-optional methods (e.g. `app.dock?.bounce`). On macOS the method exists and
              # runs; on Linux it short-circuits to a no-op. The already-darwin-gated
              # setHiddenInMissionControl sites are unaffected (method still exists on macOS).
              echo "[patch:15a] Patching setWindowButtonPosition..."
              perl -i -pe 's{(\.setWindowButtonPosition)\(}{$1?.(}g' "$INDEX"
              grep -qP '\.setWindowButtonPosition\?\.\(' "$INDEX" \
                || { echo "ERROR: patch 15a (setWindowButtonPosition) failed to apply"; exit 1; }
              echo "[patch:15a] Done"

              echo "[patch:15b] Patching setHiddenInMissionControl..."
              perl -i -pe 's{(\.setHiddenInMissionControl)\(}{$1?.(}g' "$INDEX"
              grep -qP '\.setHiddenInMissionControl\?\.\(' "$INDEX" \
                || { echo "ERROR: patch 15b (setHiddenInMissionControl) failed to apply"; exit 1; }
              echo "[patch:15b] Done"

              # --- Patch 16: Claude Code native-binary loader shim (append) ---
              # The downloaded CCD binary (<userData>/claude-code/<ver>/claude) is a generic-Linux
              # ELF whose interpreter /lib64/ld-linux-x86-64.so.2 is a NixOS stub, so the SDK's
              # spawn fails with "native binary ... exists but failed to launch" (ENOENT on the
              # missing interpreter). The append installs global __claudeCcdLdWrap() (returns
              # [ld.so, ["--argv0",bin,bin,...args]] for ELFs under /claude-code/, else the command
              # unchanged) and monkeypatches child_process spawn/spawnSync/execFile/execFileSync to
              # route those launches through a real glibc loader, whichever SDK path is used. The
              # loader path is baked from pkgs.glibc. Works for the default AND fhs variants.
              echo "[patch:16] Installing Claude Code loader shim..."
              cat ${./scripts/ccd-ld-wrap.js} >> "$INDEX"
              perl -i -pe 's{__CLAUDE_LDSO__}{${glibcLdso}}g' "$INDEX"
              grep -qF '${glibcLdso}' "$INDEX" && ! grep -qF '__CLAUDE_LDSO__' "$INDEX" \
                || { echo "ERROR: patch 16 loader path substitution failed"; exit 1; }
              grep -qF '__claudeCcdWrapped' "$INDEX" \
                || { echo "ERROR: patch 16 (loader shim append) failed to apply"; exit 1; }
              echo "[patch:16] Done"

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
