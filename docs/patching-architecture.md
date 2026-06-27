# Patching Architecture: Analysis and Automation Strategy

This document describes the patching approach in `claude-for-linux`, compares it with the regex-based approach used by [`claude-desktop-linux-flake`](https://github.com/heytcass/claude-desktop-linux-flake), and documents the path toward automated, version-resilient patching.

## Current State

**Option B (hybrid approach) is implemented**, and the chain has since grown from the
original Cowork patches to also cover Linux-specific crashes, Claude Code, and the tray
as upstream evolved. All patches are applied inline in the Nix `buildPhase`:

- **Regex patches** (`perl -pe` with `\w+` identifier wildcards): 03, 04, 06a/06b, 08a/08b,
  10, 11, 12, 13, 14, 15a/15b, 17, 18
- **Dynamic Node.js patch**: VM start (05) via `scripts/patch-vm-start.js` — the injection
  is ~100 lines, too large for a single regex, so it discovers the function boundary from
  the `[VM:start]` log string and injects the bubblewrap block
- **Append-IIFE patches**: 01 (`scripts/cowork-init.js`), 07 (`scripts/branding-fix.js`),
  16 (`scripts/ccd-ld-wrap.js`)
- **File-copy patch**: 00 (`modules/enhanced-claude-native-stub.js` → `@ant/claude-native`)
- Every regex patch is verified with a `grep -qP` post-check (and `node --check` for the
  appended IIFEs). A failed verify **aborts the build**, so a stale regex can't ship silently
- Patch 02 (win32 VM-client platform flag) removed in 1.13576.0 — dropped upstream; the
  routing it did is now covered by patch 03 + 06a
- Patch 09 (DBus tray cleanup delay) removed in 1.11847.5: its `await new Promise(...)`
  injection landed in now-synchronous functions (tray `HAe`, VM pipes `yMi`/`SMi`),
  a hard SyntaxError at startup. Reintroduce only as an async-aware node-script patch.

The per-version `scripts/patches-XXXX/` directories (2321, 2512, 2685) remain only as
historical reference for the old exact-match approach below; the build no longer uses them.

## The Problem

Claude Desktop ships as a macOS DMG containing minified Electron JavaScript. Each release changes minified identifier names (e.g., `Li` becomes `Ci`, `vz()` becomes `fz()`), even when the underlying logic is unchanged. The current approach uses **exact string matching** to find and patch these identifiers, which breaks on every version bump and requires manual updates.

## Old Approach (Replaced)

The previous approach used exact string matching, described here for historical context.

### How It Worked

9 Node.js patch scripts in `scripts/patches-XXXX/` performed exact string find-and-replace on the extracted `index.js`:

```javascript
// Patch 02: exact match — breaks when identifier changes
const original = 'Ci=process.platform==="win32"';
const replacement = 'Ci=process.platform==="win32"||process.platform==="linux"';
indexContent = indexContent.replace(original, replacement);
```

### What Each Patch Does

| # | Purpose | What it modifies | Identifier-dependent? |
|---|---------|------------------|-----------------------|
| 00 | Native module stub | `@ant/claude-native/index.js` (whole file replacement) | No |
| 01 | Cowork module loader | Appends to end of `index.js` | No |
| 02 | Platform flag | **Removed** in 1.13576.0 — the `darwin`/`win32` flag pair (Windows VM client) was deleted upstream; routing is now handled by patch 03 + 06a | n/a |
| 03 | Availability check | `function NAME(){var V;const V="darwin",V=process.arch;...}` → prepend Linux `{status:"supported"}` return | **Yes** — anchored on the `="darwin",process.arch` capability check |
| 04 | Skip download | `async function NAME(VAR,VAR){...[downloadVM]` → prepend Linux early-return | **Yes** — function name + params |
| 05 | VM start intercept | `async function NAME(VAR,VAR,VAR,VAR){...[VM:start]` → prepend Linux bubblewrap session | **Yes** — function name + ~6 internal refs |
| 06 | VM getter override | Two small functions → prepend Linux VM return | **Yes** — function names + inner call |
| 07 | Platform branding | `mainView.js` preload injection | No |
| 08 | Tray icon fix | Resource path function + icon filename selection | **Yes** — function name + module aliases |

**6 of 9 patches are identifier-dependent** and break on every release.

### Update History

| Version | Identifier changes required |
|---------|----------------------------|
| v2685 → v2998 | `Hi→Li`, `N7→vz`, `Qke→gTe`, `D0t→i0t`, `Ii→_i`, `B1e→Oxe`, `nSt→hxt`, `Pe↔Te` swapped |
| v2998 → v3189 | `Li→Ci`, `vz→fz`, `gTe→zTe`, `i0t→v_t`, `_i→Ei`, `Oxe→aAe`, `hxt→RAt`, `Pe↔Te` swapped back, new `yukonSilver` feature flag added to download function |

Every version bump requires ~30 minutes of manual grep work to find the new names.

## Alternative Approach (claude-desktop-linux-flake)

The other project uses **regex-based `perl -pe` substitutions** with wildcard captures for identifiers, applied directly in the Nix build phase:

```perl
# Tray icon: captures the variable name with \w+, works regardless of what it's called
perl -i -pe 's{:(\w)="TrayIconTemplate\.png"}{:$1=require("electron").nativeTheme.shouldUseDarkColors?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"}g'

# Origin validation: \w+ matches any identifier
perl -i -pe 's{e\.protocol==="file:"&&\w+\.app\.isPackaged===!0}{e.protocol==="file:"}g'

# Title bar: captures variable names with backreferences
perl -i -pe 's{if\(!(\w+)\s*&&\s*(\w+)\)}{if($1 && $2)}g'
```

### Key Differences

| Aspect | This project (exact match) | claude-desktop-linux-flake (regex) |
|--------|---------------------------|-------------------------------------|
| Identifier resilience | Breaks every release | Survives if code structure is stable |
| Pattern matching | Literal string `.includes()` | Perl regex with `\w+` wildcards |
| Patch application | Node.js scripts | Inline `perl -pe` in Nix buildPhase |
| Cowork/VM support | Full (patches 03-06) | None — basic app only |
| Native bindings | JS stubs (patch 00) | Rust NAPI module (`patchy-cnb`) |
| Scope | 9 patches, ~600 LOC | 5 inline perl commands, ~10 LOC |

### What They Don't Patch

`claude-desktop-linux-flake` does **not** support Cowork (the VM/sandbox feature). It only does:
- Title bar visibility
- Platform detection for Claude Code (`"linux-x64"`)
- Origin validation for `file://` protocol
- Tray icon theme selection
- Tray stability (debouncing, DBus cleanup, window blur)

The Cowork patches (03-06) are the most complex and most identifier-dependent in our project.

## Identifier Discovery Patterns

Even when doing manual updates, the key insight is that **each function has a stable semantic signature** that survives minification. Only the names change. Here are the grep patterns that reliably find each target across versions:

```bash
INDEX=/path/to/extracted/.vite/build/index.js

# Patch 02: REMOVED in 1.13576.0 — the darwin/win32 platform-flag pair (the Windows
# VM client) no longer exists; the capability check below hardcodes "darwin" instead.

# Patch 03: Availability check — the platform/arch capability check (reached via the
# yukonSilver feature getter). It hardcodes `const X="darwin",Y=process.arch` then probes
# the macOS version + @ant/claude-swift; we short-circuit it with a Linux supported return.
grep -oP 'function \w+\(\)\{var \w+;const \w+="darwin",\w+=process\.arch;' $INDEX

# Patch 04: Download guard — the async function near [downloadVM] log messages
# (params are minified, e.g. (A,e); the verify regex uses \(\w+,\w+\), not literal (t,e))
grep -oP 'async function \w+\(\w,\w\)\{.{0,200}downloadVM' $INDEX

# Patch 05: VM start — 4-param async function whose body emits the [VM:start] log.
# The body preamble is refactored across versions (cleanup loops now precede the
# Date.now()/info() sequence), so [VM:start] can sit ~400+ chars in. patch-vm-start.js
# locates the first [VM:start] and scans back to the nearest 4-param async decl.
grep -oP 'async function \w+\(\w,\w,\w,\w\)\{.{0,600}\[VM:start\]' $INDEX

# Patch 06a: VM getter — returns (t?.vm) ?? null
grep -oP 'async function \w+\(\)\{const t=await \w+\(\);return\(t==null\?void 0:t\.vm\)\?\?null\}' $INDEX

# Patch 06b: Platform getter — returns null for non-darwin
grep -oP 'async function \w+\(\)\{return process\.platform!=="darwin"\?null:await \w+\(\)\}' $INDEX

# Patch 08a: Resource path — returns resourcesPath or __dirname resolve
grep -oP 'function \w+\(\)\{return \w+\.app\.isPackaged\?\w+\.resourcesPath:\w+\.resolve\(__dirname,"\.\.","\.\.","resources"\)\}' $INDEX

# Patch 08b: Tray icon filename — the icon-name switch (was a ternary pre-1.13576.0,
# now `switch(FLAG){case"ico":...;case"template-image":VAR="TrayIconTemplate.png";...}`).
# We rewrite the template-image case to pick a theme-aware PNG on Linux.
grep -oP 'switch\(\w+\)\{case"ico":\w+=\w+\.nativeTheme\.shouldUseDarkColors\?"Tray-Win32-Dark\.ico":"Tray-Win32\.ico";break;case"template-image":\w+="TrayIconTemplate\.png"' $INDEX

# Patches 13-15: macOS/Windows-only Electron APIs that are ABSENT on Linux's electron_37
# and throw "X is not a function". These accumulate as Anthropic adds native integrations,
# so re-scan on every bump. setProgressBar/setIcon/dock.* are cross-platform or already
# optional-chained — only the genuinely macOS-only ones called UNGUARDED need patching.
grep -oP '\w+\.systemPreferences\.setUserDefault\(' $INDEX                 # patch 13 (darwin guard)
grep -oP '\w+\.app\.configureWebAuthn\(' $INDEX                            # patch 14 (darwin guard)
grep -oP '\w+\.setWindowButtonPosition\(' $INDEX                           # patch 15a (optional-call)
grep -oP '\w+\.setHiddenInMissionControl\(' $INDEX                         # patch 15b (optional-call; 1 of 3 sites unguarded)
# General sweep for the next one that breaks — list every macOS-only method call and
# eyeball which lack a `process.platform==="darwin"` / `m6()` guard or a `?.` optional-call:
grep -oP '\.(setActivationPolicy|setSecureKeyboardEntryEnabled|setWindowButtonVisibility|getUserDefault|setUserActivity|setVibrancy|setRepresentedFilename|moveToApplicationsFolder)\(' $INDEX

# Patch 16: Claude Code (CCD) loader shim — append-only, no identifier discovery. The
# build substitutes the `__CLAUDE_LDSO__` sentinel in scripts/ccd-ld-wrap.js with the Nix
# glibc ld.so path and appends the IIFE; verify is `grep -qF "$glibcLdso"` + absence of the sentinel.

# Patch 17: eIPC origin validator — the per-window guard that bails when there is no
# senderFrame. Several validators share this exact preamble; the patch short-circuits each
# for top-level file: frames under /.vite/renderer/ before the throwing `new URL()` parse.
grep -oP 'function \w+\(\w+\)\{var \w+;if\(!\w+\.senderFrame\|\|!\w+\.senderFrame\.url\)return!1;' $INDEX

# Patch 18: tray context menu — the tray builder's click handler immediately followed by
# the SAME tray var's right-click handler (unique to the builder). We inject setContextMenu
# on Linux and gate the popUpContextMenu right-click handler to non-Linux.
grep -oP '\w+=\w+\(\),\w+\.on\("click",\(\)=>void \w+\(\)\),\w+\.on\("right-click"' $INDEX
```

Patches 00-12 have been stable across v2685, v2998, v3189; the 1.13576.0 refactor dropped
patch 02 and reworked 03/08b/12 (see the patch-difficulty table above). Patches 13-15 were
added for 1.13576.0's new macOS-native call sites (Touch ID WebAuthn, traffic-light
positioning, Mission Control hiding) that crash at startup/window-setup on Linux. Patches
16-17 followed for Claude Code's downloaded native binary (NixOS `ld-linux` stub) and the
bundled renderer windows' eIPC origin validation. Patch 18 (1.15200.0-era) restores the
native dbusmenu tray menu after 1.13576.0 dropped the upstream `setContextMenu` branch and
began Electron-drawing a Wayland-unanchorable popup.

## Toward Automated Patching

### Option A: Convert to Regex-Based Patching

Replace the 6 identifier-dependent Node.js patches with `perl -pe` substitutions in the Nix build phase, using `\w+` wildcards for identifiers. This is what `claude-desktop-linux-flake` does for its simpler patches.

**Feasibility for each patch:**

| Patch | Regex conversion difficulty | Notes |
|-------|----------------------------|-------|
| 02 (platform flag) | Removed | The win32 VM client was dropped upstream in 1.13576.0; patch 03 + 06a cover the routing |
| 03 (availability) | Easy | Prepend Linux return before the platform check |
| 04 (skip download) | Medium | Function structure changed between versions (new feature flag); regex must be loose enough |
| 05 (VM start) | Hard | 100+ line replacement including bubblewrap session setup; regex can't insert new code blocks easily |
| 06 (VM getter) | Easy | Two small function-level prepends |
| 08 (tray icon) | Easy | Already demonstrated in the other project |

**Problem:** Patch 05 is a **massive code injection** (~100 lines of new bubblewrap session logic). Perl regex isn't suited for inserting multi-line code blocks into minified single-line JS.

### Option B: Hybrid Approach

1. Convert patches 02, 03, 04, 06, 08 to regex (easy wins — resilient to identifier changes)
2. Keep patch 05 as a **semantic injection**: use regex to find the function boundary, then inject the Linux block via a Node.js script that uses the regex-discovered function name

This reduces the manual update surface from 6 patches to just 1 (patch 05), and even that one could be automated since the function is reliably findable via the `[VM:start]` log string.

### Option C: Electron Preload Injection

Instead of patching `index.js` at all, inject a preload script that monkey-patches the relevant modules at runtime:

```javascript
// preload.js — loaded before app code via --require
const Module = require('module');
const origLoad = Module._load;
Module._load = function(request, parent) {
  const result = origLoad.apply(this, arguments);
  // Intercept and modify specific modules as they load
  return result;
};
```

This approach wouldn't need to know identifier names at all — it could intercept at the module/export level. However, Vite's bundled output doesn't use `require()` in the standard way, so this may not work for the main bundle.

### Option D: AST-Based Patching

Parse `index.js` into an AST (using a fast parser like `acorn` or `oxc`), find nodes by semantic structure (e.g., "a function that checks `process.platform` and returns `{status:'unsupported'}`"), and modify the tree. This is the most robust but most complex approach.

**Pros:** Completely identifier-agnostic, can handle structural changes
**Cons:** Minified JS ASTs are huge (~4.3MB source), parser must handle all edge cases, transforms are complex to write

### Recommended Path

**Option B (hybrid)** gives the best cost/benefit:

1. Convert the 5 simple patches to `perl -pe` regex — immediate win, zero maintenance
2. For patch 05, write a Node.js script that uses regex to discover the function name and internal identifiers dynamically, then generates the replacement string. This is essentially what the manual process does, but automated.
3. The only remaining failure mode is if Anthropic **restructures the code logic** (not just renames identifiers), which happens rarely and would require manual review regardless.

The auto-update CI could then:
1. Bump version/hash/URL (already done)
2. Run `nix build`
3. If it succeeds → auto-merge
4. If it fails → the patches need logic-level review (rare)

## Appendix: Identifier History

| Purpose | v2685 | v2998 | v3189 | 1.13576.0 |
|---------|-------|-------|-------|-----------|
| Platform flag | `Hi` | `Li` | `Ci` | — (removed upstream) |
| Availability check | `N7()` | `vz()` | `fz()` | `Hce()` → `S3i()` (the `="darwin",process.arch` check) |
| Download guard | `Qke()` | `gTe()` | `zTe()` | `PjA()` |
| VM start function | `D0t()` | `i0t()` | `v_t()` | `N8i()` |
| VM getter | `Ii()` | `_i()` | `Ei()` | `qo()` |
| Platform getter | `B1e()` | `Oxe()` | `aAe()` | `Q_t()` |
| Internal getter | `F1e()` | `Rxe()` | `iAe()` | `B_t()` (Swift loader) |
| Status dispatch | `lC(Ih.X)` | `g2(pf.X)` | `x2(wf.X)` | `WuA()` (zero-arg notifier) |
| electron module | `Pe` | `Te` | `Pe` | `cA` |
| path module | `Te` | `Pe` | `Te` |
| resources var | `_a` | `Sa` | `xa` |
