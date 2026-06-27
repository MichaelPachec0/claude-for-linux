# Claude Desktop for Linux

[![Nix Flake](https://img.shields.io/badge/Nix-Flake-5277C3?logo=nixos&logoColor=white)](https://github.com/heytcass/claude-for-linux)
[![Platform](https://img.shields.io/badge/Platform-Linux-blue?logo=linux&logoColor=white)](https://github.com/heytcass/claude-for-linux)
[![License](https://img.shields.io/badge/License-Personal%20Use-orange)](./LICENSE)
[![Claude Desktop](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2Fheytcass%2Fclaude-for-linux%2Fmain%2Fflake.nix&search=claudeVersion%20%3D%20%22(%5B%5E%22%5D%2B)%22&replace=v$1&label=Claude%20Desktop&color=d97757)](https://claude.ai)
[![Cowork](https://img.shields.io/badge/Cowork-Enabled-green)](./COWORK_PROGRESS.md)

Fully declarative NixOS package for Claude Desktop on Linux with Cowork support. Extracts from the macOS DMG, patches for Linux compatibility, and wraps with Electron 37.

## Quick Start

### NixOS / Nix (Recommended)

```bash
# Run directly
nix run github:heytcass/claude-for-linux

# With FHS wrapper (better MCP + Cowork compatibility)
nix run github:heytcass/claude-for-linux#claude-desktop-fhs

# Install to profile
nix profile install github:heytcass/claude-for-linux
```

Launching from a terminal returns immediately — the app detaches into its own
session (like a `.desktop` launch) instead of holding the shell open until you
quit. Console output is logged to `$XDG_STATE_HOME/claude-desktop/claude-desktop.log`
(defaults to `~/.local/state/claude-desktop/claude-desktop.log`). To keep the app
attached to the terminal for live debugging, set `CLAUDE_DESKTOP_FOREGROUND=1`:

```bash
CLAUDE_DESKTOP_FOREGROUND=1 nix run github:heytcass/claude-for-linux
```

### NixOS Module

```nix
# flake.nix
{
  inputs.claude-for-linux.url = "github:heytcass/claude-for-linux";

  outputs = { self, nixpkgs, claude-for-linux, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-for-linux.nixosModules.default
        { programs.claude-desktop.enable = true; }
      ];
    };
  };
}
```

### Home Manager Module

```nix
{
  imports = [ claude-for-linux.homeManagerModules.default ];
  programs.claude-desktop = {
    enable = true;
    fhs = true;  # FHS wrapper for MCP compatibility
  };
}
```

See [NIX_README.md](./NIX_README.md) for detailed configuration options.

### Ubuntu/Debian (Legacy)

The `scripts/` directory contains older Ubuntu-specific scripts for Claude Desktop v1.1.1200. These target a pre-installed Electron app at `/opt/claude-desktop/`.

## What Works

- **Sign-in** via Google OAuth / SSO (opens system browser, returns via deep link)
- **Native Wayland** support (not XWayland) via `--ozone-platform-hint=auto`
- **HiDPI scaling** (sharp rendering)
- **Window decorations** with titlebar overlay
- **Claude Code** tool execution
- **File uploads and downloads**
- **Full chat** functionality
- **Cowork** directory picker and bubblewrap sandboxing (WIP - see [COWORK_PROGRESS.md](./COWORK_PROGRESS.md))

## Architecture

```
macOS DMG (fetchurl)
       |
  7zz (LZFSE-aware) -> app.asar
       |
  asar_tool.py extract -> raw JS (.vite/build/index.js)
       |
  version-resilient patches (perl -pe regex + dynamic Node.js)
       |
  asar_tool.py pack -> patched app.asar
       |
  electron_37 + makeWrapper -> claude-desktop
  buildFHSEnv               -> claude-desktop-fhs
```

Patches are applied inline in the Nix `buildPhase` as `perl -pe` regex with `\w+`
wildcards for minified identifiers (plus one dynamic Node.js patch for the large
VM-start injection), so version bumps usually don't require patch changes. Each is
verified with `grep -qP` (and `node --check` for appended code) so a stale regex
aborts the build instead of shipping silently. The full chain — see
[CLAUDE.md](./CLAUDE.md#patch-chain) for the detailed rationale:

| # | Purpose |
|---|---------|
| 00 | Electron native-module stubs for Linux (`@ant/claude-native`) |
| 01 | Load the bubblewrap Cowork module |
| 03 | Report Cowork "supported" on Linux |
| 04 | Skip the macOS VM bundle download |
| 05 | Start a bubblewrap session at VM start (dynamic Node.js patch) |
| 06 | Return the Linux VM instance from the VM/platform getters |
| 07 | Rebrand "for Windows"/"for Mac" → "for Linux" |
| 08 | Theme-aware PNG tray icon |
| 10 | Add Linux targets to Claude Code `getHostPlatform()` |
| 11 | Resolve the shell-env worker via `__dirname` |
| 12 | Update the tray image in place (stop StatusNotifierItem spam) |
| 13 | Guard macOS-only `systemPreferences.setUserDefault` |
| 14 | Guard macOS-only `app.configureWebAuthn` (Touch ID) |
| 15 | Optional-call macOS-only `BrowserWindow` methods |
| 16 | Run the Claude Code binary via the Nix glibc loader |
| 17 | Pass eIPC origin validation for bundled renderer windows |
| 18 | Restore the native tray context menu on Linux |

Patches **02** (win32 VM-client platform flag) and **09** (DBus tray cleanup delay)
were removed — dropped upstream and crash-prone respectively; see CLAUDE.md.

## Project Structure

```
.
├── flake.nix                          # NixOS package: extract → patch → wrap (patches inline)
├── modules/
│   ├── claude-cowork-linux.js         # Bubblewrap session manager (Cowork sandbox)
│   └── enhanced-claude-native-stub.js # Patch 00 — Linux replacement for @ant/claude-native
├── scripts/
│   ├── cowork-init.js                 # Patch 01 IIFE — loads the Cowork module
│   ├── branding-fix.js                # Patch 07 IIFE — "for Linux" UI strings
│   ├── patch-vm-start.js              # Patch 05 — dynamic VM-start injection (Node.js)
│   ├── ccd-ld-wrap.js                 # Patch 16 — Claude Code glibc-loader shim
│   ├── patches-2321/ … patches-2685/  # Legacy per-version patch sets (historical reference)
│   └── install-*.sh / patch-cowork-*  # Legacy Ubuntu / v1.1.1200 scripts
├── tools/
│   └── asar_tool.py                   # ASAR extract/pack (LZFSE-aware)
├── docs/
│   └── patching-architecture.md       # Patch strategy + identifier-discovery greps
└── examples/                          # NixOS / Home Manager config examples
```

## Development

```bash
# Enter dev shell with all tools
nix develop

# Build and test
nix build .#claude-desktop      # Basic variant
nix build .#claude-desktop-fhs  # FHS variant
nix flake check                 # Validate structure
```

## License

For personal use only. Claude Desktop is property of Anthropic.
