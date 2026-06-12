/**
 * Claude Cowork Linux Implementation
 *
 * Provides sandboxed directory access using bubblewrap instead of macOS VMs.
 * This module replaces VM-based isolation with Linux namespace-based sandboxing.
 */

const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');

const COWORK_BASE_DIR = '/tmp/claude-cowork-sessions';

// Dynamic bwrap path: env var > PATH lookup > common locations
function findBwrap() {
  if (process.env.BWRAP_PATH) return process.env.BWRAP_PATH;
  try {
    return execFileSync('which', ['bwrap'], { encoding: 'utf8' }).trim();
  } catch (e) {
    // Fallback to common locations
    for (const p of ['/usr/bin/bwrap', '/run/current-system/sw/bin/bwrap']) {
      if (fs.existsSync(p)) return p;
    }
    return 'bwrap'; // Last resort: hope it's in PATH at runtime
  }
}
const BWRAP_PATH = findBwrap();

/**
 * Session Manager - Tracks active Cowork sessions
 */
class CoworkSessionManager {
  constructor() {
    this.sessions = new Map();
    this.processes = new Map();

    // Ensure base directory exists
    if (!fs.existsSync(COWORK_BASE_DIR)) {
      fs.mkdirSync(COWORK_BASE_DIR, { recursive: true, mode: 0o700 });
    }
  }

  /**
   * Create a new Cowork session
   */
  createSession(sessionId) {
    if (this.sessions.has(sessionId)) {
      return this.sessions.get(sessionId);
    }

    const sessionDir = path.join(COWORK_BASE_DIR, sessionId);
    const mntDir = path.join(sessionDir, 'mnt');
    const outputsDir = path.join(mntDir, 'outputs');
    const sandboxRoot = path.join(sessionDir, 'sandbox-root');

    // Create session directories
    fs.mkdirSync(sessionDir, { recursive: true, mode: 0o700 });
    fs.mkdirSync(mntDir, { recursive: true, mode: 0o755 });
    fs.mkdirSync(outputsDir, { recursive: true, mode: 0o755 });
    fs.mkdirSync(sandboxRoot, { recursive: true, mode: 0o755 });

    const session = {
      id: sessionId,
      dir: sessionDir,
      mntDir: mntDir,
      outputsDir: outputsDir,
      sandboxRoot: sandboxRoot,
      mounts: new Map(),
      createdAt: Date.now(),
      lastActivity: Date.now(),
    };

    this.sessions.set(sessionId, session);

    // Write session metadata
    const metadataPath = path.join(sessionDir, 'session.json');
    fs.writeFileSync(metadataPath, JSON.stringify({
      id: sessionId,
      created: new Date().toISOString(),
      platform: 'linux-bubblewrap',
    }, null, 2));

    return session;
  }

  /**
   * Get or create session
   */
  getSession(sessionId) {
    if (this.sessions.has(sessionId)) {
      return this.sessions.get(sessionId);
    }
    return this.createSession(sessionId);
  }

  /**
   * Add a directory mount to session
   */
  addMount(sessionId, hostPath, name = null) {
    const session = this.getSession(sessionId);
    const mountName = name || path.basename(hostPath);
    const mountPoint = path.join(session.mntDir, mountName);

    // Create bind mount using symlink (simple approach for Electron)
    // For true isolation, we'll use bubblewrap when spawning processes
    if (!fs.existsSync(mountPoint)) {
      fs.symlinkSync(hostPath, mountPoint);
    }

    session.mounts.set(mountName, {
      hostPath: hostPath,
      mountPoint: mountPoint,
      name: mountName,
      addedAt: Date.now(),
    });

    session.lastActivity = Date.now();
    return mountPoint;
  }

  /**
   * Remove a mount from session
   */
  removeMount(sessionId, name) {
    const session = this.sessions.get(sessionId);
    if (!session) return false;

    const mount = session.mounts.get(name);
    if (!mount) return false;

    // Remove symlink
    try {
      if (fs.existsSync(mount.mountPoint)) {
        fs.unlinkSync(mount.mountPoint);
      }
    } catch (err) {
      console.error(`Failed to remove mount ${name}:`, err);
    }

    session.mounts.delete(name);
    session.lastActivity = Date.now();
    return true;
  }

  /**
   * Get all mounts for a session
   */
  getMounts(sessionId) {
    const session = this.sessions.get(sessionId);
    if (!session) return [];
    return Array.from(session.mounts.values());
  }

  /**
   * Cleanup session
   */
  destroySession(sessionId) {
    const session = this.sessions.get(sessionId);
    if (!session) return;

    // Kill any running processes
    const sessionProcs = Array.from(this.processes.values())
      .filter(p => p.sessionId === sessionId);

    for (const proc of sessionProcs) {
      try {
        if (proc.child && !proc.child.killed) {
          proc.child.kill('SIGTERM');
        }
      } catch (err) {
        console.error(`Failed to kill process ${proc.id}:`, err);
      }
      this.processes.delete(proc.id);
    }

    // Remove session directory
    try {
      fs.rmSync(session.dir, { recursive: true, force: true });
    } catch (err) {
      console.error(`Failed to remove session directory:`, err);
    }

    this.sessions.delete(sessionId);
  }

  /**
   * Spawn a sandboxed process using bubblewrap
   */
  spawnSandboxed(sessionId, command, args = [], options = {}) {
    const session = this.getSession(sessionId);
    const processId = randomUUID();

    // Build bubblewrap arguments.
    //
    // Tight isolation: bind only what a sandboxed command actually needs, probing
    // each source for existence (a missing --ro-bind source makes bwrap abort).
    // On NixOS a store binary is self-contained under /nix/store (its ELF
    // interpreter and libraries all resolve there), so the traditional FHS dirs
    // /usr, /lib, /sbin are deliberately NOT exposed. Only widen this list when a
    // tool genuinely needs a path — keep the sandbox surface minimal.
    const bwrapArgs = [];
    const roBinds = [
      '/nix/store',                                            // binaries + interpreter + libs (essential on NixOS)
      '/bin',                                                  // /bin/sh for shell shebangs
      '/usr/bin/env',                                          // #!/usr/bin/env shebangs
      '/etc/resolv.conf', '/etc/hosts', '/etc/nsswitch.conf',  // DNS (network namespace is shared, not unshared)
      '/etc/ssl', '/etc/static', '/etc/pki',                   // TLS trust store (NixOS routes certs via /etc/ssl + /etc/static)
    ];
    for (const src of roBinds) {
      if (fs.existsSync(src)) bwrapArgs.push('--ro-bind', src, src);
    }

    // The downloaded agent (Claude Code) is a dynamically-linked glibc ELF that
    // expects /lib64/ld-linux-x86-64.so.2 + libc/libm/libpthread/libdl/librt,
    // which NixOS does not place at those paths. The Nix wrapper points
    // COWORK_SANDBOX_GLIBC at a glibc lib dir; bind it at /lib and /lib64 so such
    // binaries can load. (Verified: the CCD binary needs only glibc, nothing else.)
    const glibcLib = process.env.COWORK_SANDBOX_GLIBC;
    if (glibcLib && fs.existsSync(glibcLib)) {
      bwrapArgs.push('--ro-bind', glibcLib, '/lib', '--ro-bind', glibcLib, '/lib64');
    }

    // Make the command itself reachable: bind its directory read-only. The agent
    // binary lives under the user's config dir, which is not otherwise exposed.
    if (path.isAbsolute(command) && fs.existsSync(command)) {
      const cmdDir = path.dirname(command);
      bwrapArgs.push('--ro-bind', cmdDir, cmdDir);
    }

    // Virtual file systems
    bwrapArgs.push(
      '--proc', '/proc',
      '--dev', '/dev',
      '--tmpfs', '/tmp',
    );

    // Expose the session mount tree. Bind each real directory directly under
    // /sessions/<id>/mnt/<name> (bwrap creates the intermediate path). We do NOT
    // bind session.mntDir itself: it holds host->path symlinks that addMount()
    // creates for the main process's direct file access, which are meaningless
    // inside the sandbox and would shadow these real binds (the symlink target
    // isn't bound, so bwrap aborts with ENOENT).
    const mntRoot = `/sessions/${sessionId}/mnt`;
    bwrapArgs.push('--bind', session.outputsDir, `${mntRoot}/outputs`);
    for (const mount of session.mounts.values()) {
      bwrapArgs.push('--bind', mount.hostPath, `${mntRoot}/${mount.name}`);
    }

    // Writable per-session HOME — the agent writes its config/state here. Callers
    // point HOME at SANDBOX_HOME via env (and CLAUDE_CONFIG_DIR underneath it).
    const sandboxHome = '/home/cowork';
    const homeHostDir = path.join(session.dir, 'home');
    if (!fs.existsSync(homeHostDir)) fs.mkdirSync(homeHostDir, { recursive: true, mode: 0o700 });
    bwrapArgs.push('--bind', homeHostDir, sandboxHome);

    // Additional mounts requested by the caller: { guestPath: { path, mode } }.
    // mode containing 'w' or 'd' => writable bind, else read-only. A relative
    // guestPath is resolved under the sandbox HOME.
    if (options.additionalMounts && typeof options.additionalMounts === 'object') {
      for (const [guestPath, spec] of Object.entries(options.additionalMounts)) {
        if (!spec || !spec.path || !fs.existsSync(spec.path)) continue;
        const target = path.isAbsolute(guestPath) ? guestPath : path.posix.join(sandboxHome, guestPath);
        const writable = typeof spec.mode === 'string' && /[wd]/.test(spec.mode);
        bwrapArgs.push(writable ? '--bind' : '--ro-bind', spec.path, target);
      }
    }

    // Isolation flags
    bwrapArgs.push(
      '--unshare-pid',     // Separate process namespace
      '--unshare-ipc',     // Separate IPC namespace
      '--die-with-parent', // Kill when parent dies
    );

    // Working directory
    if (options.cwd) {
      bwrapArgs.push('--chdir', options.cwd);
    }

    // Command and arguments
    bwrapArgs.push(command, ...args);

    // Debug: summarize the sandbox (no secrets — env is passed separately and not
    // included; only paths/mount points are shown). Set COWORK_DEBUG=1 for the
    // full bwrap argument list (host paths, still no env values).
    console.log('[Cowork Linux] sandbox exec ' + JSON.stringify({
      command,
      argc: args.length,
      cwd: options.cwd || null,
      glibc: !!(glibcLib && fs.existsSync(glibcLib)),
      home: sandboxHome,
      mounts: Array.from(session.mounts.keys()),
      additionalMounts: options.additionalMounts ? Object.keys(options.additionalMounts) : [],
    }));
    if (process.env.COWORK_DEBUG) {
      console.log('[Cowork Linux] bwrap ' + bwrapArgs.join(' '));
    }

    // Spawn the sandboxed process. Default HOME to the writable sandbox home so
    // the agent doesn't try to write to a non-existent host home path.
    const childEnv = { ...(options.env || process.env) };
    if (!childEnv.HOME) childEnv.HOME = sandboxHome;
    const child = spawn(BWRAP_PATH, bwrapArgs, {
      stdio: options.stdio || 'pipe',
      env: childEnv,
    });

    const procInfo = {
      id: processId,
      sessionId: sessionId,
      command: command,
      args: args,
      child: child,
      pid: child.pid,
      startedAt: Date.now(),
    };

    this.processes.set(processId, procInfo);

    // Cleanup on exit
    child.on('exit', (code, signal) => {
      procInfo.exitCode = code;
      procInfo.exitSignal = signal;
      procInfo.exitedAt = Date.now();
      // Keep in map for a bit for status queries
      setTimeout(() => {
        this.processes.delete(processId);
      }, 5000);
    });

    session.lastActivity = Date.now();
    return procInfo;
  }

  /**
   * Check if a process is running
   */
  isProcessRunning(processId) {
    const proc = this.processes.get(processId);
    if (!proc) return false;
    if (!proc.child) return false;
    if (proc.child.killed) return false;
    if (proc.exitCode !== undefined) return false;

    // Double-check with kill signal 0
    try {
      process.kill(proc.child.pid, 0);
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * Check if bubblewrap is available
   */
  static isAvailable() {
    return fs.existsSync(BWRAP_PATH);
  }

  /**
   * Get version info
   */
  static getVersion() {
    if (!CoworkSessionManager.isAvailable()) {
      return null;
    }

    try {
      const output = execFileSync(BWRAP_PATH, ['--version'], { encoding: 'utf8' });
      return output.trim();
    } catch (err) {
      return 'unknown';
    }
  }
}

/**
 * VM Compatibility Adapter
 * Provides macOS VM-like API using Linux sandboxing
 */
class VMCompatibilityAdapter {
  constructor(sessionManager, sessionId) {
    this.sessionManager = sessionManager;
    this.sessionId = sessionId;
    this._vmProcessId = `cowork-${sessionId}`;
    this._isConnected = true;
  }

  /**
   * Get VM process ID (simulated)
   */
  getVmProcessId() {
    return this._vmProcessId;
  }

  /**
   * Check if guest is connected
   */
  isGuestConnected() {
    return Promise.resolve(this._isConnected);
  }

  /**
   * Check if a process is running
   */
  isProcessRunning(name) {
    // Special handling for heartbeat ping
    if (name === '__heartbeat_ping__') {
      return Promise.resolve(this._isConnected);
    }

    // Check if any sandboxed process matches name
    const procs = Array.from(this.sessionManager.processes.values())
      .filter(p => p.sessionId === this.sessionId);

    for (const proc of procs) {
      if (proc.command.includes(name) || proc.args.some(a => a.includes(name))) {
        if (this.sessionManager.isProcessRunning(proc.id)) {
          return Promise.resolve(true);
        }
      }
    }

    return Promise.resolve(false);
  }

  /**
   * Disconnect (cleanup)
   */
  disconnect() {
    this._isConnected = false;
    this.sessionManager.destroySession(this.sessionId);
  }
}

// Export
module.exports = {
  CoworkSessionManager,
  VMCompatibilityAdapter,
  COWORK_BASE_DIR,
};
