# Claude Desktop for Linux - Nix Flake Guide

[![Nix Flake](https://img.shields.io/badge/Nix-Flake-5277C3?logo=nixos&logoColor=white)](https://github.com/heytcass/claude-for-linux)
[![NixOS](https://img.shields.io/badge/NixOS-Module-blue?logo=nixos&logoColor=white)](./examples/nixos-configuration.nix)
[![Home Manager](https://img.shields.io/badge/Home%20Manager-Module-green?logo=nixos&logoColor=white)](./examples/home-manager.nix)

Fully declarative Nix flake that builds Claude Desktop v1.1.2685 for Linux from the macOS DMG, applies runtime patches, and wraps with `electron_37` from nixpkgs.

## Quick Start

### Prerequisites

Nix with flakes enabled:
```bash
# NixOS users: already have Nix
# Others: install Nix
sh <(curl -L https://nixos.org/nix/install) --daemon

# Enable flakes (add to ~/.config/nix/nix.conf)
experimental-features = nix-command flakes
```

### Run Directly

```bash
# Basic variant
nix run github:heytcass/claude-for-linux

# FHS variant (recommended for Cowork + MCP)
nix run github:heytcass/claude-for-linux#claude-desktop-fhs
```

### Install to Profile

```bash
nix profile install github:heytcass/claude-for-linux
```

## Installation Methods

### Method 1: Standalone (Any Linux with Nix)

```bash
# Run directly (no installation needed)
nix run github:heytcass/claude-for-linux

# Or install to user profile
nix profile install github:heytcass/claude-for-linux
```

### Method 2: NixOS System-Wide

```nix
# flake.nix
{
  inputs.claude-for-linux.url = "github:heytcass/claude-for-linux";

  outputs = { self, nixpkgs, claude-for-linux, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-for-linux.nixosModules.default
        {
          programs.claude-desktop = {
            enable = true;
            fhs = true;   # Use FHS wrapper (default: true)
          };
        }
      ];
    };
  };
}
```

### Method 3: Home Manager

```nix
# home.nix
{
  imports = [ claude-for-linux.homeManagerModules.default ];

  programs.claude-desktop = {
    enable = true;
    fhs = true;               # FHS wrapper (default: true)
    createDesktopEntry = true; # XDG desktop entry (default: true)
  };
}
```

## Package Variants

| Package | Description | Use Case |
|---------|-------------|----------|
| `claude-desktop` (default) | Direct electron wrapper | Simple usage, minimal deps |
| `claude-desktop-fhs` | `buildFHSEnv` wrapper | Cowork, MCP servers, tools needing `/usr/bin` paths |
| `claude-app` | Just the patched app.asar | Building custom wrappers |
| `asar-tool` | Python ASAR extract/pack tool | Development |

### FHS vs Direct

The **FHS variant** (`claude-desktop-fhs`) wraps Claude in a `buildFHSEnv` environment with:
- `/usr/bin/bwrap`, `/usr/bin/node`, `/usr/bin/python3` available
- Standard library paths (`/lib`, `/usr/lib`)
- Common tools: git, curl, docker-client, coreutils

This is recommended when using Cowork (bubblewrap needs standard paths) or MCP servers that expect FHS layout.

The **direct variant** (`claude-desktop`) runs electron directly with `makeWrapper`. It sets `BWRAP_PATH` and adds bubblewrap to `PATH`, but MCP servers may not find expected binaries.

## How It Works

### Build Pipeline

1. **Fetch**: Downloads macOS DMG via `fetchurl` (hash-verified)
2. **Extract**: `7zz` (LZFSE-aware 7-Zip) to get `app.asar` from the `.app` bundle
3. **Unpack**: `asar_tool.py extract` to get raw JavaScript
4. **Patch**: 7 Node.js scripts modify the minified code:
   - `00`: Install Linux native module stub
   - `01`: Load bubblewrap-based Cowork module
   - `02`: Route Linux through TypeScript VM path (set `sa` flag)
   - `03`: Return "supported" from availability check
   - `04`: Skip macOS VM bundle download
   - `05`: Intercept VM start - create bubblewrap session instead
   - `06`: Override VM getter to return Linux instance
5. **Repack**: `asar_tool.py pack` back into `app.asar`
6. **Wrap**: `makeWrapper` with `electron_37`, flags, and environment

### Key Architecture Decision

Claude Desktop 1.1.2321 has two VM paths:
- **macOS**: `@ant/claude-swift` (Swift native module, requires macOS)
- **Windows**: TypeScript VM client (`h7e`) over IPC sockets

By setting the `sa` platform flag to include Linux (patch 02), we route through the TypeScript path, which is more compatible with Linux. The VM start function (patch 05) then creates a bubblewrap session instead of connecting to a Windows IPC server.

## Configuration Options

### NixOS Module

```nix
programs.claude-desktop = {
  enable = true;   # Install Claude Desktop
  fhs = true;      # Use FHS wrapper (default: true)
  package = ...;   # Override package (default: claude-desktop)
};
```

### Home Manager Module

```nix
programs.claude-desktop = {
  enable = true;
  fhs = true;               # Use FHS wrapper (default: true)
  createDesktopEntry = true; # Create XDG desktop entry (default: true)
  package = ...;             # Override package
};
```

## Development

### Dev Shell

```bash
nix develop
```

Provides: nodejs, python3, bubblewrap, electron_37, 7zz, prettier

### Building

```bash
nix build .                     # Default (claude-desktop)
nix build .#claude-desktop      # Direct wrapper
nix build .#claude-desktop-fhs  # FHS wrapper
nix build .#claude-app          # Just the patched app.asar
nix flake check                 # Validate structure
```

### Testing

```bash
# Launch and check logs
nix run . 2>&1 | grep -E "Cowork|error"

# Expected output:
# [Cowork] Linux Cowork enabled via bubblewrap
# [Cowork] Bubblewrap available: bubblewrap 0.11.0
```

### Updating to New Versions

When Claude Desktop updates, the minified function names change. To update patches:

1. Get the new DMG URL: `curl -sI https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect | grep location`
2. Update `claudeVersion` and `claudeDmgHash` in `flake.nix`
3. Extract and search new index.js for equivalent patterns
4. Update search strings in `scripts/patches-2321/*.js`
5. Test: `nix build . && nix run .`

## Troubleshooting

### Build Fails at DMG Extraction

```bash
# Check if the DMG URL is still valid
curl -sI "https://claude.ai/api/desktop/darwin/universal/dmg/latest/redirect"
```

### Wayland Issues

The wrapper passes `--ozone-platform-hint=auto`. If you need to force Wayland:
```bash
claude-desktop --ozone-platform=wayland
```

### Cowork Not Appearing

Check that the patches applied:
```bash
nix build .#claude-app -L 2>&1 | grep -E "Patch|applied|WARNING"
```

All patches should show "applied" with no "WARNING" lines.

### Bubblewrap Permission Errors

On some systems, user namespaces may be restricted:
```bash
# Check kernel setting
sysctl kernel.unprivileged_userns_clone
# Should be 1. If 0:
sudo sysctl kernel.unprivileged_userns_clone=1
```

## License

Same as the main project. Claude Desktop is property of Anthropic.
