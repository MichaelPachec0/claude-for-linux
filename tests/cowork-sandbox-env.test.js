// Tests for the Cowork sandbox environment (modules/claude-cowork-linux.js).
//
// Upstream's Cowork code was written for a macOS-hosted Linux VM: it spawns bare
// commands ("bash", "claude") and sends only env *additions* (TZ, GIT_CONFIG_*,
// an OAuth token), relying on the guest image for PATH/HOME/USER. These tests
// pin the bubblewrap replacement to that contract: a guest-like base env built
// from an allowlist, never the host Electron env.
//
// Run: COWORK_SANDBOX_PATH=<tools>/bin node --test tests/cowork-sandbox-env.test.js
// The integration test needs bwrap + user namespaces and a tools dir; it skips
// (with a reason) when either is unavailable, e.g. inside the Nix build sandbox.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');
const { spawnSync } = require('child_process');

const MODULE = process.env.COWORK_MODULE ||
  path.join(__dirname, '..', 'modules', 'claude-cowork-linux.js');
const { CoworkSessionManager, buildSandboxEnv } = require(MODULE);

const HOST_ENV = {
  PATH: '/run/wrappers/bin:/usr/bin:/usr/sbin:/home/u/.nix-profile/bin:/run/current-system/sw/bin',
  HOME: '/home/u',
  USER: 'u',
  DBUS_SESSION_BUS_ADDRESS: 'unix:path=/run/user/1000/bus',
  SSH_AUTH_SOCK: '/run/user/1000/ssh-agent',
  WAYLAND_DISPLAY: 'wayland-1',
  LD_LIBRARY_PATH: '/nix/store/x-libsecret/lib',
  COWORK_SANDBOX_PATH: '/nix/store/abc-cowork-sandbox-tools/bin',
  HTTPS_PROXY: 'http://proxy:3128',
  no_proxy: 'localhost',
  TZ: 'Europe/Berlin',
};

test('host-only variables never reach the sandbox', () => {
  const env = buildSandboxEnv({ home: '/sessions/rcw-1', user: 'rcw-1', hostEnv: HOST_ENV });
  for (const k of ['DBUS_SESSION_BUS_ADDRESS', 'SSH_AUTH_SOCK', 'WAYLAND_DISPLAY',
    'LD_LIBRARY_PATH', 'COWORK_SANDBOX_PATH']) {
    assert.equal(env[k], undefined, `${k} leaked into sandbox env`);
  }
});

test('base env mirrors the VM guest user', () => {
  const env = buildSandboxEnv({ home: '/sessions/rcw-1', user: 'rcw-1', hostEnv: HOST_ENV });
  assert.equal(env.HOME, '/sessions/rcw-1');
  assert.equal(env.USER, 'rcw-1');
  assert.equal(env.LOGNAME, 'rcw-1');
  assert.equal(env.LANG, 'C.UTF-8');
  assert.equal(env.TMPDIR, '/tmp');
});

test('PATH is the sandbox tools dir plus guest FHS dirs, not the host PATH', () => {
  const env = buildSandboxEnv({ home: '/h', user: 'u', hostEnv: HOST_ENV });
  assert.equal(env.PATH, '/nix/store/abc-cowork-sandbox-tools/bin:/usr/local/bin:/usr/bin:/bin');
});

test('PATH falls back to guest FHS dirs without a tools dir', () => {
  const { COWORK_SANDBOX_PATH, ...host } = HOST_ENV;
  const env = buildSandboxEnv({ home: '/h', user: 'u', hostEnv: host });
  assert.equal(env.PATH, '/usr/local/bin:/usr/bin:/bin');
});

test('proxy and TZ pass through from the host', () => {
  const env = buildSandboxEnv({ home: '/h', user: 'u', hostEnv: HOST_ENV });
  assert.equal(env.HTTPS_PROXY, 'http://proxy:3128');
  assert.equal(env.no_proxy, 'localhost');
  assert.equal(env.TZ, 'Europe/Berlin');
});

test('caller (upstream) env overrides the base, and a caller PATH keeps the tools dir first', () => {
  const env = buildSandboxEnv({
    home: '/h', user: 'u', hostEnv: HOST_ENV,
    callerEnv: { TZ: 'America/Los_Angeles', HOME: '/custom', GIT_OPTIONAL_LOCKS: '0', PATH: '/opt/x/bin' },
  });
  assert.equal(env.TZ, 'America/Los_Angeles');
  assert.equal(env.HOME, '/custom');
  assert.equal(env.GIT_OPTIONAL_LOCKS, '0');
  assert.equal(env.PATH, '/nix/store/abc-cowork-sandbox-tools/bin:/opt/x/bin');
});

// --- Integration: a real bwrap sandbox, launched with a host-style PATH that
// contains no directory visible inside the sandbox (the original
// "bwrap: execvp bash: No such file or directory" failure).
function integrationSkipReason() {
  const tools = process.env.COWORK_SANDBOX_PATH;
  if (!tools || !fs.existsSync(path.join(tools, 'bash'))) return 'COWORK_SANDBOX_PATH unset or has no bash';
  const bwrap = process.env.BWRAP_PATH || 'bwrap';
  const probe = spawnSync(bwrap, ['--ro-bind', '/nix/store', '/nix/store', '--dev', '/dev',
    path.join(tools, 'true')], { encoding: 'utf8' });
  if (probe.status !== 0) return `bwrap cannot create a sandbox here: ${(probe.stderr || probe.error || '').toString().trim()}`;
  return null;
}

test('bare "bash" starts in the sandbox and finds the guest toolset', { skip: integrationSkipReason() || false }, async () => {
  const saved = { PATH: process.env.PATH, SECRET: process.env.COWORK_TEST_HOST_SECRET };
  process.env.PATH = '/run/wrappers/bin:/usr/bin:/usr/sbin:/run/current-system/sw/bin';
  process.env.COWORK_TEST_HOST_SECRET = 'must-not-leak';
  const manager = new CoworkSessionManager();
  const sessionId = `test-${process.pid}`;
  try {
    const { child } = manager.spawnSandboxed(sessionId, 'bash',
      ['-c', 'command -v ls grep sed awk find git python3 node curl >/dev/null && echo TOOLS_OK; ' +
        'python3 -c "import pip" && echo PIP_OK; env'],
      { env: { GIT_OPTIONAL_LOCKS: '0' }, vmProcessName: 'rcw-test' });
    let out = '', err = '';
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { err += d; });
    const code = await new Promise(resolve => child.on('exit', resolve));
    assert.equal(code, 0, `sandbox exited ${code}: ${err}`);
    assert.match(out, /^TOOLS_OK$/m);
    assert.match(out, /^PIP_OK$/m);
    assert.match(out, /^HOME=\/sessions\/rcw-test$/m);
    assert.match(out, /^GIT_OPTIONAL_LOCKS=0$/m);
    assert.doesNotMatch(out, /COWORK_TEST_HOST_SECRET/);
  } finally {
    process.env.PATH = saved.PATH;
    if (saved.SECRET === undefined) delete process.env.COWORK_TEST_HOST_SECRET;
    else process.env.COWORK_TEST_HOST_SECRET = saved.SECRET;
    manager.destroySession(sessionId);
  }
});
