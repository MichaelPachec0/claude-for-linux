
// --- Claude Code native-binary loader shim (Linux) ---
// The Claude Code "for Desktop" (CCD) native binary is downloaded at runtime to
// <userData>/claude-code/<version>/claude. Anthropic ships a generic-Linux ELF whose
// dynamic-loader is /lib64/ld-linux-x86-64.so.2 — which on NixOS is a stub that prints
// "NixOS cannot run dynamically linked executables" and exits, so the SDK's spawn fails
// with "native binary ... exists but failed to launch" (ENOENT on the missing interpreter).
//
// Rather than patch the binary on disk (which would race the SDK's hash verification and
// re-download logic), invoke it through a real glibc loader: `ld.so --argv0 <bin> <bin> args`.
// __CLAUDE_LDSO__ is substituted at build time with the Nix glibc ld-linux path. argv0 is
// preserved so the binary still sees its own path as argv[0]. Only ELF files under
// /claude-code/ are wrapped — node/scripts/system tools pass through untouched, and in the
// FHS variant this is a harmless no-op (the same nixpkgs glibc either way).
//
// The wrap is applied by monkeypatching child_process at the source (spawn/spawnSync/
// execFile/execFileSync), so it catches every code path the SDK might use to launch the
// binary, not just one named spawn helper.
globalThis.__claudeCcdLdWrap = function (cmd, args) {
  try {
    if (process.platform === "linux" && typeof cmd === "string" && cmd.indexOf("/claude-code/") !== -1) {
      const fs = require("fs");
      const fd = fs.openSync(cmd, "r");
      const magic = Buffer.alloc(4);
      fs.readSync(fd, magic, 0, 4, 0);
      fs.closeSync(fd);
      if (magic[0] === 0x7f && magic[1] === 0x45 && magic[2] === 0x4c && magic[3] === 0x46) {
        if (!globalThis.__claudeCcdLdWrapLogged) {
          globalThis.__claudeCcdLdWrapLogged = true;
          try { console.error("[Cowork Linux] routing Claude Code binary through glibc loader:", cmd); } catch (e2) {}
        }
        return ["__CLAUDE_LDSO__", ["--argv0", cmd, cmd].concat(args || [])];
      }
    }
  } catch (e) {
    /* fall through to the unmodified command */
  }
  return [cmd, args];
};

(function () {
  if (process.platform !== "linux") return;
  try {
    const cp = require("child_process");
    if (cp.__claudeCcdWrapped) return;
    cp.__claudeCcdWrapped = true;
    ["spawn", "spawnSync", "execFile", "execFileSync"].forEach(function (name) {
      const orig = cp[name];
      if (typeof orig !== "function") return;
      cp[name] = function (command, args, options) {
        if (Array.isArray(args)) {
          const w = globalThis.__claudeCcdLdWrap(command, args);
          if (w[0] !== command) {
            // A wrapped CCD launch. If options.cwd points at a directory that doesn't
            // exist (e.g. a /Users/... macOS project path carried over to Linux), the
            // spawn fails with ENOENT — Node reports it against the executable, masking
            // the real cause. Fall back to the home directory so command listing/queries
            // still work; real sessions on existing dirs are untouched.
            if (options && options.cwd) {
              try {
                if (!require("fs").existsSync(options.cwd)) {
                  options = Object.assign({}, options, { cwd: require("os").homedir() });
                }
              } catch (eC) { /* leave cwd as-is */ }
            }
            return orig.call(this, w[0], w[1], options);
          }
        }
        return orig.apply(this, arguments);
      };
    });
  } catch (e) {
    try { console.error("[Cowork Linux] child_process wrap failed:", e && e.message); } catch (e2) {}
  }
})();
