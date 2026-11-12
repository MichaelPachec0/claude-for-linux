// Enhanced Linux stub for claude-native module
// Key difference from existing solutions: Uses Electron APIs instead of no-ops
const { BrowserWindow, Notification, app, nativeImage } = require('electron');
const fs = require('fs');
const os = require('os');
const path = require('path');

// Set Claude icon on every BrowserWindow so the dock shows the correct icon
if (process.platform === 'linux') {
  app.on('browser-window-created', (event, window) => {
    try {
      const iconPath = require('path').join(
        require('path').dirname(app.getAppPath()),
        'resources', 'icon.png'
      );
      const icon = nativeImage.createFromPath(iconPath);
      if (!icon.isEmpty()) window.setIcon(icon);
    } catch (e) {}
  });
}

class ClaudeNativeLinux {
  constructor() {
    this._mainWindow = null;
  }

  // Called by main process to register window
  setMainWindow(win) {
    this._mainWindow = win;
  }

  // OS version detection
  getWindowsVersion() {
    // Compatibility stub for code that checks Windows version
    return "10.0.0";
  }

  getWindowsElevationType() {
    // Patch 02 enables the Windows code path on Linux, so the app probes UAC
    // elevation. Linux has no UAC — report the non-elevated default (callers treat
    // "limited"/"full" as elevatable; "default" => can_elevate:false).
    return "default";
  }

  getOSVersion() {
    return os.release();
  }

  getPlatform() {
    return 'linux';
  }

  // Window effects - compositor handles these on Linux
  setWindowEffect(effect) {
    // macOS has vibrancy effects, Linux compositors handle this
    return true;
  }

  removeWindowEffect() {
    return true;
  }

  // CRITICAL: Window state - use Electron API, not hardcoded values
  getIsMaximized() {
    if (!this._mainWindow) return false;
    return this._mainWindow.isMaximized();
  }

  isFullScreen() {
    if (!this._mainWindow) return false;
    return this._mainWindow.isFullScreen();
  }

  isMinimized() {
    if (!this._mainWindow) return false;
    return this._mainWindow.isMinimized();
  }

  isVisible() {
    if (!this._mainWindow) return true;
    return this._mainWindow.isVisible();
  }

  // Window management
  maximize() {
    if (this._mainWindow) this._mainWindow.maximize();
  }

  minimize() {
    if (this._mainWindow) this._mainWindow.minimize();
  }

  restore() {
    if (this._mainWindow) this._mainWindow.restore();
  }

  focus() {
    if (this._mainWindow) this._mainWindow.focus();
  }

  show() {
    if (this._mainWindow) this._mainWindow.show();
  }

  hide() {
    if (this._mainWindow) this._mainWindow.hide();
  }

  close() {
    if (this._mainWindow) this._mainWindow.close();
  }

  // Notifications - delegate to Electron
  showNotification(options) {
    if (Notification.isSupported()) {
      const notification = new Notification(options);
      notification.show();
      return notification;
    }
    return null;
  }

  // Taskbar/dock integration
  flashFrame(flag) {
    if (this._mainWindow) {
      this._mainWindow.flashFrame(flag !== false);
    }
  }

  clearFlashFrame() {
    if (this._mainWindow) {
      this._mainWindow.flashFrame(false);
    }
  }

  setProgressBar(progress) {
    if (this._mainWindow) {
      // Clamp between 0 and 1
      const normalized = Math.max(0, Math.min(1, progress));
      this._mainWindow.setProgressBar(normalized);
    }
  }

  clearProgressBar() {
    if (this._mainWindow) {
      this._mainWindow.setProgressBar(-1);
    }
  }

  // Badge/overlay icon - limited support on Linux
  setOverlayIcon(icon, description) {
    // Not well supported on Linux, but try anyway
    if (this._mainWindow && this._mainWindow.setOverlayIcon) {
      this._mainWindow.setOverlayIcon(icon, description);
      return true;
    }
    return false;
  }

  clearOverlayIcon() {
    if (this._mainWindow && this._mainWindow.setOverlayIcon) {
      this._mainWindow.setOverlayIcon(null, '');
      return true;
    }
    return false;
  }

  setBadgeCount(count) {
    if (app && app.setBadgeCount) {
      app.setBadgeCount(count);
      return true;
    }
    return false;
  }

  getBadgeCount() {
    if (app && app.getBadgeCount) {
      return app.getBadgeCount();
    }
    return 0;
  }

  // System integration
  setAppUserModelId(id) {
    if (app && app.setAppUserModelId) {
      app.setAppUserModelId(id);
    }
  }

  // Keyboard constants - preserve from original if app uses them
  get KeyboardKey() {
    return {
      // Common key codes - add more if needed
      VK_RETURN: 13,
      VK_ESCAPE: 27,
      VK_SPACE: 32,
      VK_LEFT: 37,
      VK_UP: 38,
      VK_RIGHT: 39,
      VK_DOWN: 40,
      VK_DELETE: 46,
    };
  }

  // Accessibility features
  isAccessibilityEnabled() {
    // Linux doesn't have the same accessibility query API
    return true;
  }

  // Power management
  getPowerState() {
    return {
      onBattery: false,
      charging: false,
      percent: 100
    };
  }

  // Screen capture/recording detection
  isScreenCaptureAllowed() {
    return true;
  }

  // Microphone/camera access
  isMicrophoneAccessAllowed() {
    return true;
  }

  isCameraAccessAllowed() {
    return true;
  }

  // File system operations - delegate to Node.js fs module
  // (if the app uses these, they should work fine with standard fs)

  // System theme detection
  getSystemTheme() {
    const nativeTheme = require('electron').nativeTheme;
    return nativeTheme.shouldUseDarkColors ? 'dark' : 'light';
  }

  onSystemThemeChanged(callback) {
    const nativeTheme = require('electron').nativeTheme;
    nativeTheme.on('updated', () => {
      callback(nativeTheme.shouldUseDarkColors ? 'dark' : 'light');
    });
  }
}

// ---------------------------------------------------------------------------
// safe-fs native handle API
//
// As of 4.23118.1 the app's safe-fs layer (CC-2885) refuses path-based opens:
// every read/write under a "root" is opened *beneath* a native directory handle
// provided by @ant/claude-native (openRootDir / openBeneath / *Beneath). The
// real binding is a macOS .node, so on Linux the module either fails to load
// ("@ant/claude-native is required for safe-fs containment") or — with this
// stub — loads without the API ("t.openRootDir is not a function", surfaced as
// ERR_SAFE_FS_ROOT). Every state write then fails: window state, plan usage,
// skills sync, remote-control state, Cowork settings.
//
// Emulate the binding with Node fs. Handles are plain fds, which is what the
// app expects: it passes them straight to fs.fstat/ftruncate/close and hands
// fds from openBeneath back into the *Beneath calls. Paths are re-rooted via
// /proc/self/fd/<fd> so an operation can never escape the handle it was given,
// and each intermediate directory is opened with O_DIRECTORY|O_NOFOLLOW, so a
// symlink planted inside a root is rejected with ELOOP like the native code.
// ---------------------------------------------------------------------------

const FD_DIR = '/proc/self/fd';

function segsPath(fd, segs) {
  let p = `${FD_DIR}/${fd}`;
  for (const seg of segs) {
    if (
      typeof seg !== 'string' ||
      seg === '' ||
      seg === '.' ||
      seg === '..' ||
      seg.includes('/') ||
      seg.includes('\0')
    ) {
      const err = new Error(`unsafe path segment: ${String(seg)}`);
      err.code = 'ELOOP';
      throw err;
    }
    p = path.join(p, seg);
  }
  return p;
}

function openBeneath(rootFd, segs, flags, mode) {
  let fd = rootFd;
  let owned = false;
  try {
    for (let i = 0; i < segs.length - 1; i++) {
      const next = fs.openSync(
        `${FD_DIR}/${fd}/${segs[i]}`,
        fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW,
      );
      if (owned) {
        try { fs.closeSync(fd); } catch (e) {}
      }
      fd = next;
      owned = true;
    }
    // segs[0] is the leaf here; an empty segs list means "the root itself".
    const target = segs.length ? `${FD_DIR}/${fd}/${segs[segs.length - 1]}` : `${FD_DIR}/${fd}`;
    const openFlags = segs.length ? flags | fs.constants.O_NOFOLLOW : flags;
    return fs.openSync(target, openFlags, mode);
  } finally {
    if (owned) {
      try { fs.closeSync(fd); } catch (e) {}
    }
  }
}

// Raw stat shape the app's Stat wrapper consumes (seconds/nanoseconds, not ms).
function rawStat(st) {
  const split = (ns, ms) => {
    if (typeof ns === 'bigint') {
      return [Number(ns / 1000000000n), Number(ns % 1000000000n)];
    }
    const total = Math.round(ms * 1e6);
    return [Math.floor(total / 1e9), total % 1e9];
  };
  const atime = split(st.atimeNs, st.atimeMs);
  const mtime = split(st.mtimeNs, st.mtimeMs);
  const ctime = split(st.ctimeNs, st.ctimeMs);
  const birthtime = split(st.birthtimeNs, st.birthtimeMs);
  return {
    dev: Number(st.dev),
    ino: Number(st.ino),
    mode: Number(st.mode),
    nlink: Number(st.nlink),
    uid: Number(st.uid),
    gid: Number(st.gid),
    rdev: Number(st.rdev),
    size: Number(st.size),
    blksize: Number(st.blksize),
    blocks: Number(st.blocks),
    // Fields the wrapper actually reads.
    atimeSec: atime[0], atimeNsec: atime[1],
    mtimeSec: mtime[0], mtimeNsec: mtime[1],
    ctimeSec: ctime[0], ctimeNsec: ctime[1],
    birthtimeSec: birthtime[0], birthtimeNsec: birthtime[1],
  };
}

const safeFs = {
  async openRootDir(root) {
    // No O_NOFOLLOW here: the app asserts the root is a real directory itself,
    // and following a symlinked config dir is the pre-safe-fs behaviour.
    return fs.openSync(root, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY);
  },

  async openBeneath(rootFd, segs, flags, mode) {
    return openBeneath(rootFd, segs, flags, mode);
  },

  async renameBeneath(rootFd, srcSegs, dstSegs) {
    fs.renameSync(segsPath(rootFd, srcSegs), segsPath(rootFd, dstSegs));
  },

  async linkBeneath(rootFd, srcSegs, dstSegs) {
    fs.linkSync(segsPath(rootFd, srcSegs), segsPath(rootFd, dstSegs));
  },

  async unlinkBeneath(rootFd, segs) {
    fs.unlinkSync(segsPath(rootFd, segs));
  },

  async rmdirBeneath(rootFd, segs) {
    fs.rmdirSync(segsPath(rootFd, segs));
  },

  async mkdirBeneath(rootFd, segs, mode) {
    fs.mkdirSync(segsPath(rootFd, segs), mode === undefined ? undefined : { mode });
  },

  async statBeneath(rootFd, segs) {
    return rawStat(fs.statSync(segsPath(rootFd, segs), { bigint: true }));
  },

  async lstatBeneath(rootFd, segs) {
    return rawStat(fs.lstatSync(segsPath(rootFd, segs), { bigint: true }));
  },

  async statHandleBeneath(rootFd, segs) {
    const fd = openBeneath(rootFd, segs, fs.constants.O_RDONLY, 0);
    return { fd, isSymbolicLink: false };
  },

  async readdirBeneath(rootFd, segs, limit) {
    const dir = segsPath(rootFd, segs);
    const names = fs.readdirSync(dir);
    const truncated = limit !== undefined && names.length > limit;
    const entries = (limit === undefined ? names : names.slice(0, limit)).map((name) => {
      let isFile = false;
      let isDirectory = false;
      let isSymbolicLink = false;
      try {
        const st = fs.lstatSync(path.join(dir, name));
        isFile = st.isFile();
        isDirectory = st.isDirectory();
        isSymbolicLink = st.isSymbolicLink();
      } catch (e) {}
      return { name, isFile, isDirectory, isSymbolicLink };
    });
    return { entries, truncated };
  },
};

// AuthRequest stub - returns isAvailable()=false so the app falls back to
// system browser auth instead of macOS ASWebAuthenticationSession
class AuthRequest {
  static isAvailable() {
    return false;
  }
  start() {
    return Promise.reject(new Error('AuthRequest not available on Linux'));
  }
  cancel() {}
}

// Export singleton instance with AuthRequest as a static property
const instance = new ClaudeNativeLinux();
instance.AuthRequest = AuthRequest;
instance.getActiveWindowHandle = () => null;
Object.assign(instance, safeFs);
module.exports = instance;
