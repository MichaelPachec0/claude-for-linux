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
  asar_tool.py extract -> raw JS
       |
  8 patches:
    00: Native module stub (@ant/claude-native + AuthRequest)
    01: Cowork module loader (claude-cowork-linux)
    02: Platform flag (route Linux through TypeScript VM path)
    03: Availability check (NH() returns supported)
    04: Skip bundle download (TCe() short-circuit)
    05: VM start intercept (ppt() -> bubblewrap session)
    06: VM getter override (Ai() + fwe())
    07: Platform branding ("for Linux" in UI)
       |
  asar_tool.py pack -> patched app.asar
       |
  electron_37 + makeWrapper -> claude-desktop
  buildFHSEnv -> claude-desktop-fhs
```

## Project Structure

```
.
├── flake.nix                         # Full NixOS package definition
├── modules/
│   ├── claude-cowork-linux.js        # Bubblewrap session manager
│   └── enhanced-claude-native-stub.js # Linux native module replacement
├── scripts/
│   ├── patches-2685/                 # Patches for v1.1.2685
│   │   ├── 00-native-module-stub.js
│   │   ├── 01-cowork-module-loader.js
│   │   ├── 02-platform-flag.js
│   │   ├── 03-availability-check.js
│   │   ├── 04-skip-download.js
│   │   ├── 05-vm-start-intercept.js
│   │   ├── 06-vm-getter.js
│   │   └── 07-platform-branding.js
│   ├── patch-cowork-*.js             # Legacy patches for v1.1.1200
│   └── install-*.sh                  # Legacy Ubuntu install scripts
├── tools/
│   └── asar_tool.py                  # ASAR archive manipulation
└── examples/                         # NixOS/Home Manager config examples
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
