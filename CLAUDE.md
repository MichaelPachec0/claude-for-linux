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
| 02 | `perl -pe` regex | Route Linux through VM path (platform flag) |
| 03 | `perl -pe` regex | Return "supported" for Linux availability |
| 04 | `perl -pe` regex | Skip macOS VM bundle download |
| 05 | Node.js dynamic | Create bubblewrap session at VM start |
| 06 | `perl -pe` regex | Return Linux VM instance from getters |
| 07 | Append IIFE | Replace "for Windows"/"for Mac" with "for Linux" |
| 08 | `perl -pe` regex | Use theme-aware PNGs for tray icon |
| 09 | — | **Removed** — injected `await` into now-synchronous fns (crash); see `flake.nix` |
| 10 | `perl -pe` regex | Add Linux targets to Claude Code `getHostPlatform()` (was throwing) |

## Electron Gotchas

- **Process types**: Main (type='browser') vs renderer - only main can access Node.js
- **ASAR tool**: Use `tools/asar_tool.py` not `npx asar` (has bugs)
- **App caching**: Kill all processes with `pkill -f claude-desktop` before testing
- **ChildProcess objects**: Can't add methods via assignment - use Proxy

## Current State

See `COWORK_PROGRESS.md` for detailed status of Cowork Linux implementation.
