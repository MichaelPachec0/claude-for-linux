# claude-for-linux

Enabling macOS-only Claude Desktop features on Linux via runtime patching.

## Architecture

- **Source**: macOS DMG fetched via `fetchurl` (see `claudeVersion` in `flake.nix`)
- **Extraction**: `7zz` (modern 7-Zip, LZFSE-aware) + `asar_tool.py` — newer DMGs are LZFSE-compressed; `dmg2img` lacks LZFSE support and silently corrupts them
- **Runtime**: `electron_37` from nixpkgs
- **Packaging**: Nix flake with `makeWrapper` + `buildFHSEnv`

## Key Commands

```bash
# Build
nix build .                     # Default (direct electron wrapper)
nix build .#claude-desktop-fhs  # FHS wrapper (Cowork + MCP)
nix build .#claude-app          # Just the patched app.asar

# Run
nix run .
nix run .#claude-desktop-fhs

# Validate
nix flake check

# Dev shell
nix develop
```

## Patching Workflow

Patches use `perl -pe` regex with `\w+` wildcards for minified identifiers, so version bumps should not require patch changes.

1. **Fetch DMG URL**: `curl -sI https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect | grep location`
2. **Update hash**: `nix-prefetch-url <url>` then convert to SRI
3. **Update version/hash/URL** in `flake.nix`
4. **Build**: `nix build .` — if it succeeds, patches are still valid
5. **If build fails**: Check the `grep -qP` verification errors to see which regex needs updating

See `docs/patching-architecture.md` for the full technical analysis.

## Patch Chain

| # | Method | Purpose |
|---|--------|---------|
| 00 | File copy | Electron API stubs for Linux (`@ant/claude-native`) |
| 01 | Append IIFE | Load bubblewrap Cowork module |
| 02 | — | **Removed** — win32 VM-client path dropped upstream (1.13576.0); job now covered by 03 + 06a; see `flake.nix` |
| 03 | `perl -pe` regex | Return "supported" for Linux availability (anchored on the `="darwin",process.arch` capability check) |
| 04 | `perl -pe` regex | Skip macOS VM bundle download |
| 05 | Node.js dynamic | Create bubblewrap session at VM start |
| 06 | `perl -pe` regex | Return Linux VM instance from getters |
| 07 | Append IIFE | Replace "for Windows"/"for Mac" with "for Linux" |
| 08 | `perl -pe` regex | Use theme-aware PNGs for tray icon |
| 09 | — | **Removed** — injected `await` into now-synchronous fns (crash); see `flake.nix` |
| 10 | `perl -pe` regex | Add Linux targets to Claude Code `getHostPlatform()` (was throwing) |
| 11 | `perl -pe` regex | Resolve shell-env worker via `__dirname` (was using `process.resourcesPath`) |
| 12 | `perl -pe` regex | Update tray image in place on Linux (stop StatusNotifierItem re-export spam) |
| 13 | `perl -pe` regex | Gate macOS-only `systemPreferences.setUserDefault` behind a darwin check (was crashing at startup) |
| 14 | `perl -pe` regex | Gate macOS-only `app.configureWebAuthn` (Touch ID WebAuthn) behind a darwin check (was crashing at startup) |
| 15 | `perl -pe` regex | Optional-call macOS-only BrowserWindow methods `setWindowButtonPosition` / `setHiddenInMissionControl` (were crashing on window setup) |
| 16 | Append IIFE | Run the downloaded Claude Code (CCD) binary via the Nix glibc loader (its `/lib64/ld-linux` is a NixOS stub) + fall back to `$HOME` when a spawn cwd doesn't exist (stale macOS project paths) |
| 17 | `perl -pe` regex | Pass eIPC origin validation for bundled renderer windows (find-in-page/about/quick/buddy): the validators only allow `file:` frames when `app.isPackaged` (false under `electron <asar>`), and the Linux frame URL `file://app:///…` throws in `new URL()`. Short-circuit all 8 URL-parsing validators **before** the parse for top-level `file:` frames under `/.vite/renderer/` (read-only store path) |
| 18 | `perl -pe` regex | Restore native tray context menu on Linux. 1.13576.0 dropped the upstream `cn ? popUpContextMenu : setContextMenu` branch and now always Electron-draws the popup, which renders squished on Wayland (a tray popup has no parent surface to anchor). Re-inject `setContextMenu` (native dbusmenu, panel-rendered) on Linux and gate the `popUpContextMenu` right-click handler to non-Linux |

## Electron Gotchas

- **Process types**: Main (type='browser') vs renderer - only main can access Node.js
- **ASAR tool**: Use `tools/asar_tool.py` not `npx asar` (has bugs)
- **App caching**: Kill all processes with `pkill -f claude-desktop` before testing
- **ChildProcess objects**: Can't add methods via assignment - use Proxy

## Current State

See `COWORK_PROGRESS.md` for detailed status of Cowork Linux implementation.
