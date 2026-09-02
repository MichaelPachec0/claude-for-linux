{
  description = "Claude Desktop for Linux - fully declarative NixOS package with Cowork support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Claude Desktop version and source
      claudeVersion = "1.44121.0";
      claudeDmgHash = "sha256-4hzTf/KRiAN3BU5SR4oOGrOYLpmjr71V7fIdzeF+Uwc=";
      claudeDmgUrl = "https://downloads.claude.ai/releases/darwin/universal/${claudeVersion}/Claude-a670de389e37e5e93692c0aedf350fe0d2cde4c1.dmg";

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

              # --- Main-process file set -------------------------------------------------
              # The main process is code-split, and HOW it is split changes without notice:
              #   <= 1.22209.2  monolithic index.js
              #   1.22209.3     index.js loader stub + ONE big index.chunk-<hash>.js
              #   1.28929.0     entry moved to index.pre.js (package.json "main"), which
              #                 require()s index.js, which require()s ~30 chunks out of 347
              # The old "resolve the stub's first required chunk" heuristic broke on that last
              # reshuffle: the first require() is now a 1.7 KB esm-interop helper, so every
              # regex patch targeted a file containing none of their anchors and silently
              # no-op'd. Chunk layout is a bundler artifact with no stability guarantee, so
              # stop guessing which file holds what: run every regex patch across ALL emitted
              # main-process JS and let the anchors decide. Each patch still hard-fails if its
              # anchor matched nowhere, so a genuine upstream shape change is still caught.
              BUILD="extracted/.vite/build"
              CHUNKS=()
              while IFS= read -r f; do CHUNKS+=("$f"); done < <(find "$BUILD" -maxdepth 1 -name '*.js' | sort)
              if [ ''${#CHUNKS[@]} -eq 0 ]; then
                echo "ERROR: no main-process JS found under $BUILD"
                exit 1
              fi
              echo "  Main-process bundle: ''${#CHUNKS[@]} JS files under $BUILD (code-split)"

              # Appends (cowork loader, CCD shim) go into the loader stub index.js: it is
              # require()d by the index.pre.js entry and itself require()s every chunk, so
              # appended code runs after the whole main process is defined — exactly the
              # pre-split layout where index.js held both the main code and the bootstrap.
              INDEX="$BUILD/index.js"
              MAINVIEW="$BUILD/mainView.js"

              # patch_js <name> <perl-expr> <verify-pcre>
              # Applies the substitution across every main-process file, then requires the
              # result to be observable somewhere. Both args must be single-quoted at the call
              # site: they are expanded once, into perl/grep, never re-parsed by the shell.
              #
              # NOTE on quoting in the anchors below: as of 1.28929.0 the minifier emits
              # BACKTICK string literals (`darwin`, not "darwin"), declares with `let` rather
              # than `const`, and uses native optional chaining (`x?.vm`) instead of the old
              # `x==null?void 0:x.vm` desugar. Anchors therefore accept either quote style via
              # ["\x60] (\x60 = backtick, kept as an escape so the char is unambiguous inside
              # nested nix/shell/perl quoting) and either declaration keyword. Injected code
              # always uses plain double quotes — valid JS regardless of what the minifier does.
              patch_js() {
                local name="$1" expr="$2" verify="$3"
                perl -i -pe "$expr" "''${CHUNKS[@]}"
                grep -qP "$verify" "''${CHUNKS[@]}" \
                  || { echo "ERROR: patch $name failed to apply"; exit 1; }
              }

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
              # The Cowork capability check (reached via the yukonSilver capability getter) returns
              # {status:"supported"|"unsupported"} for the current platform. Newer builds added
              # first-class Windows Cowork support, so it NO LONGER hardcodes the old
              # `const A="darwin",e=process.arch` pair (patch 02/03's historic anchor). It now reads
              # the platform into a var and branches per-OS:
              #   function v7i(){const A=process.platform;
              #     if(A!=="darwin"&&A!=="win32")return{status:"unsupported",...unsupported_platform};
              #     const e=process.arch; if(e!=="x64"&&e!=="arm64")return{...unsupported_architecture};
              #     ...then probes OS version + (darwin) @ant/claude-swift.vm.isVirtualizationSupported()
              #        / (win32) HCS — all of which reject or throw on Linux.
              # Linux is rejected by the very FIRST guard (unsupported_platform). Short-circuit it:
              # inject a Linux early-return at the top of the function, before `let A=process.platform`,
              # so when global.__linuxCowork is live it reports {status:"supported"} before any
              # darwin/win32/Swift/HCS logic runs. Anchored on the unique first-guard signature
              # (`let \w+=process.platform;if(\w+!==`darwin`&&\w+!==`win32`)return{status:`unsupported``).
              # Both the sync and async availability paths flow through this one function.
              echo "[patch:03] Patching availability check..."
              patch_js 03 \
                's{(function [\w\$]+\(\)\{)((?:const|let|var) [\w\$]+=process\.platform;if\([\w\$]+!==["\x60]darwin["\x60]&&[\w\$]+!==["\x60]win32["\x60]\)return\{status:["\x60]unsupported["\x60])}{$1if(process.platform==="linux"&&global.__linuxCowork)return{status:"supported"};$2}g' \
                'function [\w$]+\(\)\{if\(process\.platform==="linux"&&global\.__linuxCowork\)return\{status:"supported"\};(?:const|let|var) [\w$]+=process\.platform;'
              echo "[patch:03] Done"

              # --- Patch 04: Skip download (regex) ---
              # Skips macOS VM bundle download on Linux. The downloader is the two-arg async
              # function that opens by reading the yukonSilver capability off the capability
              # map (`async function X(e,n){let{yukonSilver:r}=p.n();return r?.status===`supported`?...`)
              # — a unique, stable signature. The old anchor was "any two-arg async function
              # within 200 chars of a [downloadVM] log string", which also matched the unrelated
              # stale-cache sweeper in the same chunk.
              # 1.44121.0: the body now opens with an awaited feature-gate fetch
              # (`async function sU(e,t){await Lz();let{yukonSilver:r}=zz();...`), so the
              # anchor allows one optional `await X();` statement before the destructure.
              # The other yukonSilver destructures in the bundle keep different arities or
              # preambles (3-arg warm-downloader, Date.now() in the startVM wrapper), so the
              # match stays unique.
              echo "[patch:04] Patching download skip..."
              patch_js 04 \
                's{(async function [\w\$]+\([\w\$]+,[\w\$]+\)\{(?:await [\w\$]+\(\);)?)(let\{yukonSilver:)}{$1if(process.platform==="linux"&&global.__linuxCowork){console.log("[Cowork Linux] Skipping bundle download");return!1}$2}g' \
                'if\(process\.platform==="linux"&&global\.__linuxCowork\)\{console\.log\("\[Cowork Linux\] Skipping bundle download"\)'
              echo "[patch:04] Done"

              # --- Patch 19: Cowork setup state for the renderer (regex) ---
              # Patch 04 makes the VM-bundle download a no-op on Linux, but the renderer does
              # not ask "did the download run" — it asks the CoworkVM eIPC interface for the
              # bundle's state on disk:
              #   getDownloadStatus(){return hK()?WO.Downloading:mK()?WO.Ready:WO.NotDownloaded}
              #   async download(){try{return await dK(),{success:mK()}}catch...}
              # 1.30096.1: the probes used to be namespaced member calls (`j.u()`) and the enum a
              # two-level member (`E.u.Ready`); the minifier now emits bare hoisted identifiers
              # (`mK()`, `WO`). Both captures therefore allow dots but no longer require them.
              # (The eIPC interface was also renamed CoworkVM -> ClaudeVM; the anchors never
              # matched on the interface name, so that rename is inert here.)
              # `mK()` is the bundle-file readiness probe (every macOS VM bundle file present
              # and hash-matched under <userData>/…). On Linux nothing is ever downloaded, so it
              # returns false forever: the Cowork tab shows the "Get set up for agent mode —
              # download a one-time package" card, and pressing it reports {success:false} (patch
              # 04 short-circuits the download), so the user is stuck in that card and never
              # reaches VM start (patch 05) at all.
              # Report Ready / success on Linux when the bubblewrap backend is live — there is no
              # bundle to install; the "workspace" is created per session by patch 05.
              echo "[patch:19a] Patching Cowork download status..."
              patch_js 19a \
                's{(getDownloadStatus\(\)\{)(return [\w\$.]+\(\)\?([\w\$.]+)\.Downloading:)}{$1if(process.platform==="linux"&&global.__linuxCowork)return $3.Ready;$2}g' \
                'getDownloadStatus\(\)\{if\(process\.platform==="linux"&&global\.__linuxCowork\)return [\w$.]+\.Ready;'
              echo "[patch:19a] Done"

              echo "[patch:19b] Patching Cowork download result..."
              patch_js 19b \
                's{(async download\(\)\{)(try\{return await [\w\$.]+\(\),\{success:)}{$1if(process.platform==="linux"&&global.__linuxCowork)return{success:!0};$2}g' \
                'async download\(\)\{if\(process\.platform==="linux"&&global\.__linuxCowork\)return\{success:!0\};'
              echo "[patch:19b] Done"

              # --- Patch 20: macOS "disclaimer" helper wrapper (regex) ---
              # Claude Code is never spawned directly: every launch is routed through a small
              # macOS helper binary that lives in the app bundle at Contents/Helpers/disclaimer
              # (it exists so macOS attributes TCC/privacy prompts to the helper rather than to
              # Electron). The resolver and the wrapper are:
              #   function a(){let e=path.dirname(process.resourcesPath);return path.join(e,`Helpers`,`disclaimer`)}
              #   function o(e){return{cmd:a(),args:[e.cmd,...e.args]}}
              # and the host-loop session builder feeds that straight to the SDK:
              #   let De=s.i({cmd:x,args:[]});
              #   e.pathToClaudeCodeExecutable=De.cmd; e.executableArgs=De.args;
              # so the SDK is told the EXECUTABLE is the disclaimer helper and the real claude
              # binary is merely argv[1]. On Linux there is no Contents/Helpers — the path lands
              # inside the Electron store dir (<electron>/libexec/electron/Helpers/disclaimer) —
              # so every Cowork session dies instantly with
              #   "Claude Code native binary not found at .../Helpers/disclaimer"
              #   (error_category: disclaimer_binary_missing)
              # which the UI reports as "The Claude Code binary is missing or damaged."
              # There is nothing for the helper to do on Linux (no TCC), so route around it.
              # 1.44121.0 reshaped this site: the single pass-through wrapper
              # (`function o(e){return{cmd:a(),args:[e.cmd,...e.args]}}`) is now a resolver
              # pair plus TWO wrappers that each null-check the resolver themselves:
              #   function NKe(){{let e=path.dirname(process.resourcesPath);return path.join(e,"Helpers","disclaimer")}}
              #   function PKe(){return NKe()}
              #   function Sp(e){let t=PKe();if(!t)return{cmd:e.cmd,args:e.args,processGroupLeader:!1};...--pgroup...}
              #   function RKe(e){let t=PKe();return t?{cmd:t,args:["--ports-only",...]}:e}
              # i.e. upstream itself ships a no-helper pass-through path behind a falsy
              # resolver. So patch the resolver instead of the wrappers: make the
              # `function X(){return Y()}` that immediately follows the Helpers/disclaimer
              # path builder return null on Linux. Both wrappers (and any future caller
              # that copies the null-check idiom) then take upstream's own pass-through,
              # and the macOS path stays byte-identical.
              echo "[patch:20] Patching macOS disclaimer helper resolver..."
              patch_js 20 \
                's{(["\x60]disclaimer["\x60]\)\}\})function ([\w\$]+)\(\)\{return ([\w\$]+)\(\)\}}{$1function $2(){return process.platform==="linux"?null:$3()}}g' \
                'function [\w$]+\(\)\{return process\.platform==="linux"\?null:[\w$]+\(\)\}'
              echo "[patch:20] Done"

              # --- Patch 05: VM start intercept (dynamic Node.js) ---
              # Discovers function name via [VM:start] log string, injects bubblewrap session.
              # The script locates the owning chunk itself (the [VM:start] function has moved
              # between chunks across releases), so it only needs the extracted app root.
              echo "[patch:05] Patching VM start intercept..."
              ${pkgs.nodejs}/bin/node ${./scripts/patch-vm-start.js} extracted
              echo "[patch:05] Done"

              # --- Patch 06a: VM getter (regex) ---
              # Returns Linux VM instance from getter function. As of 1.28929.0 the minifier
              # emits native optional chaining, so the body is `return(await X())?.vm??null`
              # rather than the old `const A=await X();return(A==null?void 0:A.vm)??null`
              # desugar.
              echo "[patch:06a] Patching VM getter..."
              patch_js 06a \
                's{(async function )([\w\$]+)(\(\)\{)(return\(await [\w\$]+\(\)\)\?\.vm\?\?null)}{$1$2$3if(process.platform==="linux"&&global.__linuxCowork&&global.__linuxCowork.vmInstance){console.log("[Cowork Linux] $2() returning Linux VM");return global.__linuxCowork.vmInstance}$4}g' \
                '\[Cowork Linux\] [\w$]+\(\) returning Linux VM'
              echo "[patch:06a] Done"

              # --- Patch 06b: Platform getter (regex) ---
              # Don't return null for Linux in the platform-gated Swift-module getter. In
              # 1.28929.0 the ternary is written the other way round —
              # `async function kN(){return process.platform===`darwin`?await DN():null}`
              # (was `...!=="darwin"?null:await ...`) — so widen the darwin test to darwin||linux
              # instead of narrowing a negated one.
              # NOTE: the minifier's identifier alphabet includes `$` (e.g. `$at` in 1.24012.11).
              # Perl's `\w` is [A-Za-z0-9_] and does NOT match `$`, so every identifier capture
              # must be `[\w\$]+`.
              echo "[patch:06b] Patching platform getter..."
              patch_js 06b \
                's{(async function [\w\$]+\(\)\{return )process\.platform===["\x60]darwin["\x60](\?await [\w\$]+\(\):null\})}{$1(process.platform==="darwin"||process.platform==="linux")$2}g' \
                '\(process\.platform==="darwin"\|\|process\.platform==="linux"\)\?await [\w$]+\(\):null'
              echo "[patch:06b] Done"

              # --- Patch 07: Platform branding ---
              echo "[patch:07] Injecting platform branding fix..."
              cat ${./scripts/branding-fix.js} >> "$MAINVIEW"
              echo "[patch:07] Done"

              # --- Patch 08a: Tray icon resource path (regex) ---
              # Returns real filesystem path on Linux (COSMIC SNI can't read from ASAR)
              # 1.28929.0: the packaged branch is bare `process.resourcesPath` (was aliased
              # through the electron-namespace var) and `path` is reached as `X.default.resolve`,
              # so the path helper capture must tolerate an optional `.default` member.
              echo "[patch:08a] Patching tray icon resource path..."
              patch_js 08a \
                's{function ([\w\$]+)\(\)\{return ([\w\$]+)\.app\.isPackaged\?process\.resourcesPath:([\w\$]+(?:\.default)?)\.resolve\(__dirname,["\x60]\.\.["\x60],["\x60]\.\.["\x60],["\x60]resources["\x60]\)\}}{function $1(){return process.platform==="linux"?$3.join($3.dirname($2.app.getAppPath()),"resources"):$2.app.isPackaged?process.resourcesPath:$3.resolve(__dirname,"..","..","resources")}}g' \
                'process\.platform==="linux"\?[\w$.]+\.join\([\w$.]+\.dirname\('
              echo "[patch:08a] Done"

              # --- Patch 08b: Tray icon filename (regex) ---
              # Linux uses theme-aware PNGs instead of Windows ICOs. The filename is chosen by a
              # switch over a build-time constant that is hardcoded to "template-image" in the
              # macOS build, so Linux lands on the flat, non-theme-aware mac template icon that
              # cannot adapt to a dark panel. Rewrite only the template-image case so Linux picks
              # a dark/light PNG by nativeTheme, while macOS keeps its OS-adapted template image.
              #
              # 1.30096.1 shape (was `X=<name>;break` assignments, now direct returns):
              #   switch(vje){case`ico`:return!e&&o.nativeTheme.shouldUseDarkColors?`Tray-Win32-Dark.ico`:`Tray-Win32.ico`;
              #               case`template-image`:return`TrayIconTemplate.png`;
              #               case`png`:return e||dIt()===`gnome`||o.nativeTheme.shouldUseDarkColors?`TrayIconLinux-Dark.png`:`TrayIconLinux.png`;
              # That `png` case and its TrayIconLinux{,-Dark}.png assets are new upstream Linux
              # art, but it is unreachable: the discriminant is `vje=`template-image`` — a mac
              # build constant, not a runtime platform check. So the patch stays, and now returns
              # upstream's own Linux icons rather than the mac template pair.
              # The ico-case prefix is matched loosely ([^;]*?) because it grew a `!e&&` guard.
              echo "[patch:08b] Patching tray icon filename selection..."
              patch_js 08b \
                's{(switch\([\w\$.]+\)\{case["\x60]ico["\x60]:return[^;]*?([\w\$]+)\.nativeTheme\.shouldUseDarkColors\?["\x60]Tray-Win32-Dark\.ico["\x60]:["\x60]Tray-Win32\.ico["\x60];case["\x60]template-image["\x60]:return)["\x60]TrayIconTemplate\.png["\x60]}{$1 process.platform==="linux"?($2.nativeTheme.shouldUseDarkColors?"TrayIconLinux-Dark.png":"TrayIconLinux.png"):"TrayIconTemplate.png"}g' \
                'template-image["\x60]:return process\.platform==="linux"\?\([\w$]+\.nativeTheme\.shouldUseDarkColors\?"TrayIconLinux-Dark\.png"'
              echo "[patch:08b] Done"

              # --- Patch 10: Claude Code (CCD) host platform — REMOVED (upstream) ---
              # The Claude Code-for-Desktop binary resolver's getHostPlatform() used to map only
              # darwin/win32 to a target triple and throw "Unsupported platform" on anything else,
              # which surfaced on Linux as "Failed to get commands from temporary query". This
              # patch injected the linux-x64/linux-arm64 branch. As of 1.28929.0 upstream ships
              # exactly that branch itself:
              #   getHostPlatform(){let e=process.arch;...;if(process.platform===`linux`)
              #     return e===`arm64`?`linux-arm64`:`linux-x64`;throw Error(...)}
              # so the injection has nothing left to add. Keep the assertion, though: if a future
              # release drops the linux branch again, CCD silently regresses to the throw, and a
              # hard build failure here is how we find out.
              echo "[patch:10] Verifying upstream Linux host platform support..."
              grep -qP 'if\(process\.platform===["\x60]linux["\x60]\)return [\w$]+===["\x60]arm64["\x60]\?["\x60]linux-arm64["\x60]:["\x60]linux-x64["\x60]' "''${CHUNKS[@]}" \
                || { echo "ERROR: patch 10 — upstream getHostPlatform() no longer handles linux; re-add the injection"; exit 1; }
              echo "[patch:10] Done (native)"

              # --- Patch 11: Shell-env worker path (regex) ---
              # The shell-PATH extractor forks shellPathWorker.js, but resolves it relative to
              # process.resourcesPath/app.asar (the standard packaged layout). Here app.asar
              # lives at app.getAppPath(), not under Electron's resourcesPath, so the fork fails
              # ("Shell path worker not found") and the app falls back to a bare process.env —
              # losing the user's real PATH for MCP servers and Cowork tools. Resolve via
              # __dirname (the asar dir of index.js) on Linux; the worker is forked from inside
              # the asar just as it is on macOS.
              # __dirname resolves to .vite/build for every code-split chunk as well as for
              # index.js — they are all emitted side by side — so the Linux branch is correct
              # whichever chunk the helper ends up in.
              echo "[patch:11] Patching shell-env worker path..."
              patch_js 11 \
                's{function ([\w\$]+)\(\)\{return ([\w\$]+(?:\.default)?)\.join\(process\.resourcesPath,["\x60]app\.asar["\x60],["\x60]\.vite["\x60],["\x60]build["\x60],["\x60]shell-path-worker["\x60],["\x60]shellPathWorker\.js["\x60]\)\}}{function $1(){return process.platform==="linux"?$2.join(__dirname,"shell-path-worker","shellPathWorker.js"):$2.join(process.resourcesPath,"app.asar",".vite","build","shell-path-worker","shellPathWorker.js")}}g' \
                'process\.platform==="linux"\?[\w$.]+\.join\(__dirname,"shell-path-worker","shellPathWorker\.js"\)'
              echo "[patch:11] Done"

              # --- Patch 12: Tray in-place update — REMOVED ---
              # This patch stopped the tray builder from destroy+recreating the Tray on every call
              # (helper-app-launched + nativeTheme "updated" + menuBarEnabled all invoke it during
              # startup). Each recreate re-exported the StatusNotifierItem / dbusmenu D-Bus objects
              # before the old one finished deregistering, spamming "org.kde.StatusNotifierItem.* is
              # already exported". It injected a Linux "if the tray exists and is still wanted,
              # setImage and return" branch before the destroy/recreate.
              # As of 1.17377.1 upstream implements this natively — and better. The builder now
              # caches the Tray instance (was `let HE=null`) and its last image path (`OuA`), and its
              # body runs:
              #   if(!A){HE&&!HE.isDestroyed()&&HE.destroy(),HE=null,OuA=null,...;return}          // not wanted
              #   if(HE&&!HE.isDestroyed()){t!==OuA&&(HE.setImage(..createFromPath(t)),OuA=t);return} // in place
              #   HE=new cA.Tray(..createFromPath(t)),OuA=t,...HE.on("click"..)                    // first create only
              # An existing, still-wanted tray takes the in-place setImage branch — guarded by
              # t!==OuA, so it only re-images when the theme/icon actually changed — and returns; it
              # never destroy+recreates. The old anchor (`...HE=null),!A){..}HE=new ..Tray`) no longer
              # exists and the patch has nothing left to add. Dropped. (Patch 18 still restores the
              # native context menu on the surviving `HE.on("click")/HE.on("right-click")` wiring.)

              # --- Patch 18: Tray native context menu on Linux (regex) ---
              # Upstream regression in 1.13576.0: the tray builder USED to branch on a flag
              #   cn ? GE.on("right-click", ()=>...popUpContextMenu(pG)...) : GE.setContextMenu(pG)
              # and on Linux took the setContextMenu(pG) path — handing a com.canonical.dbusmenu
              # tree to the panel (COSMIC/Hyprland/etc.), which lays the menu out natively. In
              # 1.13576.0 Anthropic DELETED the setContextMenu branch; the builder now ALWAYS wires
              #   QQ.on("right-click", ()=>...QQ.popUpContextMenu(FcA)...)
              # i.e. Electron draws its own GTK popup. On Wayland a tray popup has no parent surface
              # to anchor to, so the compositor collapses it — the menu renders "squished". (Not an
              # Electron-version issue: 1.12603.1 rendered fine under the same Electron; the menu
              # mechanism is what changed.) Restore the native path on Linux: after the menu is built
              # (`FcA=EXe()`), call setContextMenu(FcA), and gate the popUpContextMenu right-click
              # handler to non-Linux — exactly the old `cn` ternary. Anchored on the click handler
              # (`X.on("click",()=>void Y())`) immediately followed by the same tray var's
              # right-click handler, which is unique to the tray builder.
              #
              # v1.18286.0 note: the minifier named the tray var "$E" (LEADING $). Perl/PCRE
              # \w is [A-Za-z0-9_] and EXCLUDES $, so the old \w+ identifier captures never
              # matched "$E.on(...)" and the whole substitution silently no-op'd (patch 18
              # "failed to apply"). Widen every identifier capture to [\w$]+. In Perl the class
              # MUST be written [\w\$]: an unescaped $] interpolates the $] Perl-version
              # variable inside the char class -> "Invalid [] range". PCRE (grep -P) does not
              # interpolate $, so plain [\w$] is correct (and required) there.
              #
              # v1.28929.0 note: the menu builder is now reached as a member call (`dm=i.p()`,
              # was a bare `FcA=EXe()`), so the builder capture allows one `.member` hop.
              #
              # v1.44121.0 note: the old anchor (menu-build assignment immediately followed by
              # the click/right-click pair) is gone. The tray builder now (a) inserts a status
              # subscription between the menu build and the handler wiring, (b) wires click as
              # `Q9.on("click",(()=>{H4r()||j3r()}))` (was `()=>void X()`), and (c) rebuilds the
              # menu LAZILY inside the right-click handler behind a dirty flag before
              # `Q9?.popUpContextMenu(b3r)`. Re-anchor on the click+right-click pair itself and
              # capture the menu variable out of the popUpContextMenu call; the menu is already
              # built (`b3r=S3n()`) before the handlers are wired, so setContextMenu($menu) at
              # wiring time hands the panel the same menu the popup would have shown. Linux
              # loses only the lazy rebuild-on-dirty, which the old native path never had
              # either (the panel re-reads the dbusmenu tree it was handed).
              echo "[patch:18] Patching tray native context menu (Linux)..."
              patch_js 18 \
                's{(([\w\$]+)\.on\(["\x60]click["\x60],\(\(\)=>\{[\w\$]+\(\)\|\|[\w\$]+\(\)\}\)\)),(\2\.on\(["\x60]right-click["\x60],\(\(\)=>\{\(async\(\)=>\{.{0,400}?\2\?\.popUpContextMenu\(([\w\$]+)\)\)\}\)\(\)\}\)\))}{$1,process.platform==="linux"&&$2.setContextMenu($4),process.platform!=="linux"&&$3}g' \
                'process\.platform==="linux"&&[\w$]+\.setContextMenu\([\w$]+\),process\.platform!=="linux"&&[\w$]+\.on\(["\x60]right-click'
              echo "[patch:18] Done"

              # --- Patch 13: macOS-only systemPreferences.setUserDefault guard (regex) ---
              # Top-level app init unconditionally calls
              # `systemPreferences.setUserDefault("NSAutoFillHeuristicsEnabled","boolean",!1)`.
              # setUserDefault is a macOS-only Electron API; on Linux it's undefined, so the
              # call throws "setUserDefault is not a function" during module load and the app
              # crashes at startup. Gate it behind a darwin check (`&&` short-circuits on Linux,
              # leaving the trailing comma-sequence — e.g. ...,GCo() — to run untouched). The
              # other systemPreferences.* calls are already darwin-gated or runtime/try-catch'd.
              echo "[patch:13] Patching systemPreferences.setUserDefault guard..."
              patch_js 13 \
                's{([\w\$]+)\.systemPreferences\.setUserDefault\(}{process.platform==="darwin"&&$1.systemPreferences.setUserDefault(}g' \
                'process\.platform==="darwin"&&[\w$]+\.systemPreferences\.setUserDefault\('
              echo "[patch:13] Done"

              # --- Patch 14: macOS-only app.configureWebAuthn guard (regex) ---
              # The same top-level init (right after setUserDefault) calls GCo(), whose entire
              # body is `app.configureWebAuthn({touchID:{keychainAccessGroup:...}})`. That Touch
              # ID WebAuthn config is macOS-only; configureWebAuthn is absent on Linux's Electron,
              # so it throws "configureWebAuthn is not a function" at module load — the next
              # startup crash after patch 13. Gate it behind a darwin check (Anthropic ships it
              # working on macOS; on Linux the `&&` short-circuits to a no-op).
              echo "[patch:14] Patching app.configureWebAuthn guard..."
              patch_js 14 \
                's{([\w\$]+)\.app\.configureWebAuthn\(}{process.platform==="darwin"&&$1.app.configureWebAuthn(}g' \
                'process\.platform==="darwin"&&[\w$]+\.app\.configureWebAuthn\('
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
              patch_js 15a \
                's{(\.setWindowButtonPosition)\(}{$1?.(}g' \
                '\.setWindowButtonPosition\?\.\('
              echo "[patch:15a] Done"

              echo "[patch:15b] Patching setHiddenInMissionControl..."
              patch_js 15b \
                's{(\.setHiddenInMissionControl)\(}{$1?.(}g' \
                '\.setHiddenInMissionControl\?\.\('
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

              # --- Patch 17: eIPC origin validation for bundled renderer windows (regex) ---
              # The auxiliary windows (find-in-page, about, quick, buddy) load their HTML from
              # the bundle via loadFile(join(app.getAppPath(),".vite/renderer/<name>/...")), then
              # their preloads call shared eIPC interfaces — DesktopIntl.getInitialLocale et al.
              # Each interface guards its handler with an origin validator (gHe/ne/vr/g0/... — 8
              # functions sharing one body) that allows file: frames ONLY when app.isPackaged===true.
              # On Linux this fails two ways at once:
              #   1. We launch as `electron <app.asar>`, so app.isPackaged is FALSE — the file:
              #      branch (`protocol==="file:"&&isPackaged===!0`) never matches.
              #   2. The frame URL comes through as a malformed `file://app:///.vite/renderer/...`
              #      (empty port) on which `new URL()` THROWS, so the validator returns false at
              #      its `try{e=new URL(...)}catch{return!1}` step before any origin check runs.
              # Result: 'Incoming "getInitialLocale" call on interface "DesktopIntl" ... did not
              # pass origin validation'. Inject a Linux short-circuit at the TOP of every URL-
              # parsing validator (before `new URL`, so it survives the throw): accept a top-level
              # (parent===null) file: frame whose path is under the bundle's `/.vite/renderer/`.
              # That dir lives in the read-only Nix store, so no attacker can plant HTML there —
              # this only re-grants first-party bundled renderers the access macOS gets for free
              # via isPackaged, and leaves the claude.ai (https:) allowlist path untouched.
              #
              # v1.28929.0 note: the leading `var <tmp>;` (the old optional-chaining desugar
              # temp) is gone now that the minifier emits native `?.`, so it is no longer part
              # of the anchor. The 9 validators are spread over 8 chunks, which is exactly why
              # patches run across the whole file set rather than one resolved bundle.
              echo "[patch:17] Patching eIPC origin validation for renderer windows..."
              patch_js 17 \
                's{(function [\w\$]+\(([\w\$]+)\)\{if\(!\2\.senderFrame\|\|!\2\.senderFrame\.url\)return!1;)}{$1if(process.platform==="linux"&&$2.senderFrame.parent===null&&$2.senderFrame.url.startsWith("file:")&&$2.senderFrame.url.includes("/.vite/renderer/"))return!0;}g' \
                'if\(process\.platform==="linux"&&[\w$]+\.senderFrame\.parent===null&&[\w$]+\.senderFrame\.url\.startsWith\("file:"\)&&[\w$]+\.senderFrame\.url\.includes\("/\.vite/renderer/"\)\)return!0;'
              echo "[patch:17] Done"

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
              # Extra important now that patches run across every chunk: index.pre.js wraps its
              # `require("./index.js")` in a try/catch that funnels the error into the crash
              # reporter, so a SyntaxError in a patched chunk does NOT produce an obvious startup
              # failure — it produces a silently half-dead app.
              echo "[verify] Syntax-checking patched JavaScript..."
              for jsfile in "''${CHUNKS[@]}"; do
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
              # TrayIconLinux{,-Dark}.png are what patch 08b selects on Linux (upstream
              # added them in 1.30096.1); without them here the tray renders blank.
              for icon in extracted/resources/TrayIconTemplate*.png extracted/resources/TrayIconLinux*.png extracted/resources/icon.png; do
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

          # Foreground Electron wrapper (direct electron). This holds the
          # controlling terminal until the app exits — correct for running
          # *inside* a sandbox/init (the FHS runScript) but not what you want
          # when launching from a shell. The user-facing packages wrap this in
          # a detaching launcher (mkDetachingLauncher) so `nix run` / a terminal
          # invocation returns immediately instead of being swallowed.
          claudeDesktopForeground = pkgs.symlinkJoin {
            name = "claude-desktop-foreground-${claudeVersion}";
            paths = [ claudeApp ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.electron}/bin/electron $out/bin/claude-desktop \
                --add-flags "$out/lib/claude-desktop/app.asar" \
                --add-flags "--no-sandbox" \
                --add-flags "--ozone-platform-hint=auto" \
                --add-flags "--class=com.anthropic.Claude" \
                --add-flags "--password-store=gnome-libsecret" \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bubblewrap ]} \
                --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libsecret ]} \
                --set BWRAP_PATH "${pkgs.bubblewrap}/bin/bwrap" \
                --set COWORK_SANDBOX_GLIBC "${pkgs.glibc}/lib" \
                --set CHROME_DESKTOP "com.anthropic.Claude.desktop" \
                --prefix XDG_DATA_DIRS : "$out/share"
            '';
          };

          # Wrap a foreground launcher so that starting it from a shell (e.g.
          # `nix run`) returns immediately and the GUI keeps running detached —
          # the way a .desktop launch behaves — instead of the Electron process
          # holding the terminal until you quit the app.
          #
          # setsid --fork puts the app in a brand-new session (no controlling
          # tty, so it survives the terminal closing) and exits the parent right
          # away, freeing the shell. stdout/stderr go to a log file so the
          # maintainer can still read the app's console output; set
          # CLAUDE_DESKTOP_FOREGROUND=1 to keep the app attached to the terminal
          # (handy for live-watching logs while debugging patches).
          mkDetachingLauncher = innerBin: pkgs.writeShellScriptBin "claude-desktop" ''
            if [ -n "''${CLAUDE_DESKTOP_FOREGROUND:-}" ]; then
              exec "${innerBin}" "$@"
            fi
            logdir="''${XDG_STATE_HOME:-$HOME/.local/state}/claude-desktop"
            mkdir -p "$logdir" 2>/dev/null || logdir="''${TMPDIR:-/tmp}"
            exec ${pkgs.util-linux}/bin/setsid --fork "${innerBin}" "$@" \
              >>"$logdir/claude-desktop.log" 2>&1 </dev/null
          '';

          # Basic Claude Desktop package: detaching launcher + desktop entry + icons.
          # Icon=claude below is a hicolor theme NAME, not a path, so the package
          # must also ship share/icons/hicolor/<size>/apps/claude.png — that comes
          # from claudeApp in paths. Drop claudeApp and the entry renders iconless
          # in rofi/quickshell/any XDG menu.
          claudeDesktop = pkgs.symlinkJoin {
            name = "claude-desktop-${claudeVersion}";
            paths = [ (mkDetachingLauncher "${claudeDesktopForeground}/bin/claude-desktop") claudeApp ];
            postBuild = ''
              # Desktop entry. The basename and StartupWMClass must both equal the
              # Wayland app_id Electron actually reports (com.anthropic.Claude,
              # verified with `hyprctl clients`) — NOT "claude-desktop"/"Claude".
              # Panels and taskbars map a live toplevel to its entry by app_id, so
              # any other name leaves running windows iconless even though menus
              # like rofi (which never see app_id) look fine.
              mkdir -p $out/share/applications
              cat > $out/share/applications/com.anthropic.Claude.desktop <<DESKTOP
              [Desktop Entry]
              Name=Claude
              Comment=Claude AI Assistant
              Exec=$out/bin/claude-desktop %U
              Icon=claude
              Type=Application
              Categories=Development;Utility;
              MimeType=x-scheme-handler/claude;
              StartupWMClass=com.anthropic.Claude
              DESKTOP
              sed -i 's/^              //' $out/share/applications/com.anthropic.Claude.desktop
            '';
            meta = with pkgs.lib; {
              description = "Claude Desktop for Linux with Cowork support";
              homepage = "https://claude.ai";
              platforms = platforms.linux;
              mainProgram = "claude-desktop";
            };
          };

          # FHS sandbox running the foreground wrapper. dieWithParent is disabled
          # because the user-facing claudeDesktopFHS detaches this via
          # setsid --fork: bwrap's parent (setsid) exits immediately, and the
          # default --die-with-parent would then SIGKILL the whole sandbox the
          # instant the launcher returns. With it off (and no PID namespace),
          # bwrap simply reparents to init and keeps running. runScript points at
          # the *foreground* binary so Electron stays in the foreground of bwrap's
          # own detached session, keeping the sandbox alive until the app quits.
          claudeDesktopFHSInner = pkgs.buildFHSEnv {
            name = "claude-desktop";
            dieWithParent = false;
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
            runScript = "${claudeDesktopForeground}/bin/claude-desktop";
            meta = with pkgs.lib; {
              description = "Claude Desktop for Linux (FHS) with Cowork and MCP support";
              homepage = "https://claude.ai";
              platforms = platforms.linux;
              mainProgram = "claude-desktop";
            };
          };

          # FHS wrapper for maximum compatibility (cowork + MCP), detached so it
          # doesn't swallow the launching terminal.
          claudeDesktopFHS = pkgs.symlinkJoin {
            name = "claude-desktop-fhs-${claudeVersion}";
            # claudeApp is joined in for share/icons/hicolor/*/apps/claude.png.
            # Without it the desktop entry's Icon=claude resolves to nothing and
            # launchers (rofi, quickshell, any XDG menu) show a blank/fallback
            # icon. The FHS sandbox itself only needs claudeDesktopFHSInner; the
            # app payload here is inert symlinks.
            paths = [
              (mkDetachingLauncher "${claudeDesktopFHSInner}/bin/claude-desktop")
              claudeApp
            ];
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

            # Attribute name is the .desktop basename, and it must equal the
            # Wayland app_id Electron reports (com.anthropic.Claude) so panels and
            # taskbars can map a live window back to this entry for its icon.
            # Same reason StartupWMClass carries the app_id rather than "Claude".
            xdg.desktopEntries."com.anthropic.Claude" = lib.mkIf cfg.createDesktopEntry {
              name = "Claude";
              genericName = "AI Assistant";
              exec = "${pkg}/bin/claude-desktop %U";
              icon = "claude";
              categories = [ "Development" "Utility" ];
              comment = "Claude Desktop with Linux Cowork support";
              mimeType = [ "x-scheme-handler/claude" ];
              settings = {
                StartupWMClass = "com.anthropic.Claude";
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
              electron_41
              _7zz

              # Development tools
              prettier
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
