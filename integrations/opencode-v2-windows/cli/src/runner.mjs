import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { realpathSync } from 'node:fs';
import { mkdtemp, readFile, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, relative, resolve, sep, win32 } from 'node:path';
import { getAsset, isSea } from 'node:sea';
import {
  SandboxManager,
  VENDORED_SRT_WIN_EXE,
  checkWindowsSandboxStatusAsync,
  resolveSrtWin,
} from '@anthropic-ai/sandbox-runtime';

const HELPER_SHA256 = {
  x64: 'a8e22bc098ac1146ec9b9151d5f1770c05b897cd1ac588161e1287a248cc9176',
  arm64: 'c7b204c8fab94059dbf7a6a805b844abad3deb82614e07e4b8d4b5bb5c4374f7',
};
const OUTPUT_LIMIT = 1024 * 1024;

export function decodeOutput(buffer, shell) {
  if (!buffer.length) return '';
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  } catch {
    return new TextDecoder(shell === 'git-bash' ? 'utf-8' : 'gbk').decode(buffer);
  }
}

function within(base, target) {
  const rel = win32.relative(win32.resolve(base), win32.resolve(target));
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${win32.sep}`) && !win32.isAbsolute(rel));
}

export async function validateTransportRoot(root, workspace) {
  if (!win32.isAbsolute(root) || root.startsWith('\\\\') || within(workspace, root)) {
    throw new Error('Sandbox transport root must be a local path outside the workspace');
  }
  const actual = await realpath(root);
  if (within(workspace, actual)) {
    throw new Error('Sandbox transport root resolves inside the workspace');
  }
  return root;
}

export function selectShell(options, profile = homedir()) {
  if (options.shell === 'powershell' || options.shell === 'cmd') return options.shell;
  if (options.shell !== 'git-bash') throw new Error(`Unsupported shell: ${options.shell}`);
  const exe = options.bashExe;
  if (!exe || !win32.isAbsolute(exe) || win32.basename(exe).toLowerCase() !== 'bash.exe') {
    throw new Error('Git Bash requires an absolute --bash-exe path');
  }
  if (within(profile, exe) || exe.toLowerCase().includes('\\windowsapps\\')) {
    throw new Error('Git Bash inside the user profile or WindowsApps cannot be granted read access');
  }
  return exe;
}

export function buildPolicy(workspace, transport, helper, gitBashRoot, denyRead = [], allowDomains = []) {
  return {
    network: { allowedDomains: allowDomains, deniedDomains: allowDomains.length ? [] : ['*'], strictAllowlist: true, allowLocalBinding: false },
    filesystem: {
      allowRead: gitBashRoot ? [workspace, transport, gitBashRoot] : [workspace, transport],
      allowWrite: [workspace],
      denyRead: [join(workspace, '.env'), join(workspace, '.env.local'), ...denyRead],
      denyWrite: [],
    },
    windows: { srtWin: { path: helper } },
  };
}

export async function loadHelperBytes() {
  return isSea() ? Buffer.from(getAsset('srt-win.exe')) : readFile(VENDORED_SRT_WIN_EXE);
}

export async function writeVerifiedHelper(path) {
  await writeFile(path, await loadHelperBytes(), { flag: 'wx' });
  const digest = createHash('sha256').update(await readFile(path)).digest('hex');
  if (digest !== HELPER_SHA256[process.arch]) throw new Error('SRT helper hash does not match pinned 0.0.81');
}

function trustedTaskkill(workspace) {
  const root = process.env.SystemRoot;
  if (!root || !win32.isAbsolute(root) || root.startsWith('\\')) throw new Error('SystemRoot must be an absolute local Windows path');
  const executable = realpathSync(win32.join(root, 'System32', 'taskkill.exe'));
  if (within(workspace, executable)) throw new Error('System taskkill path overlaps the writable workspace');
  return executable;
}

async function collectChild(wrapped, cwd, workspace, timeoutMs, shell) {
  const taskkill = trustedTaskkill(workspace);
  return await new Promise((finish, reject) => {
    const child = spawn(wrapped.argv[0], wrapped.argv.slice(1), {
      cwd, env: wrapped.env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout = [];
    const stderr = [];
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let timedOut = false;
    let outputLimitExceeded = false;
    let settled = false;
    const killTree = () => {
      if (child.pid) spawnSync(taskkill, ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, timeout: 5000 });
      child.kill();
    };
    const timer = setTimeout(() => { timedOut = true; killTree(); }, timeoutMs);
    child.stdout.on('data', (chunk) => {
      stdoutBytes += chunk.length;
      if (stdoutBytes <= OUTPUT_LIMIT) stdout.push(chunk);
      else if (!outputLimitExceeded) { outputLimitExceeded = true; killTree(); }
    });
    child.stderr.on('data', (chunk) => {
      stderrBytes += chunk.length;
      if (stderrBytes <= OUTPUT_LIMIT) stderr.push(chunk);
      else if (!outputLimitExceeded) { outputLimitExceeded = true; killTree(); }
    });
    child.once('error', (error) => { if (!settled) { settled = true; clearTimeout(timer); reject(error); } });
    child.once('close', (exitCode, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      finish({ exitCode, signal, stdout: decodeOutput(Buffer.concat(stdout), shell), stderr: decodeOutput(Buffer.concat(stderr), shell), timedOut, outputLimitExceeded });
    });
  });
}

export async function runSandboxed(options) {
  if (process.platform !== 'win32') throw new Error('This sandbox CLI requires Windows');
  const workspace = resolve(options.workspace);
  if (within(homedir(), workspace)) throw new Error('Workspace must be outside the current user profile');
  if (dirname(workspace) === workspace) throw new Error('Workspace cannot be a drive root');
  const info = await stat(workspace);
  if (!info.isDirectory()) throw new Error('Workspace is not a directory');
  if ((await realpath(workspace)).toLowerCase() !== workspace.toLowerCase()) {
    throw new Error('Workspace must not be a junction or symlink');
  }
  const cwd = resolve(options.cwd ?? workspace);
  if (!within(workspace, cwd)) throw new Error('cwd must be inside the workspace');
  if (!(await stat(cwd)).isDirectory() || (await realpath(cwd)).toLowerCase() !== cwd.toLowerCase()) {
    throw new Error('cwd must be a real directory, not a junction or symlink');
  }

  const shell = selectShell(options);
  if (options.shell === 'git-bash') {
    const bashInfo = await stat(shell);
    if (!bashInfo.isFile()) throw new Error('Git Bash executable is not a file');
  }
  const gitBashRoot = options.shell === 'git-bash' ? dirname(dirname(shell)) : undefined;
  const transportRoot = await validateTransportRoot(tmpdir(), workspace);
  const transport = await mkdtemp(join(transportRoot, 'srt-cli-'));
  const helper = join(transport, 'srt-win.exe');
  let initialized = false;
  try {
    await writeVerifiedHelper(helper);
    const status = await checkWindowsSandboxStatusAsync({ srtWin: resolveSrtWin({ path: helper }) });
    if (!status.user.provisioned) throw new Error('SRT Windows sandbox account is not installed');
    await SandboxManager.initialize(buildPolicy(workspace, transport, helper, gitBashRoot, options.denyRead, options.allowDomains));
    initialized = true;
    if (SandboxManager.getWindowsProfileRead() !== 'absent') {
      throw new Error('Global user-profile read grant is active');
    }
    const wrapped = await SandboxManager.wrapWithSandboxArgv(options.command, shell, undefined, undefined, cwd);
    const result = await collectChild(wrapped, cwd, workspace, options.timeoutMs, options.shell);
    return { shell: options.shell, shellExe: shell, workspace, ...result };
  } finally {
    let cleanupError;
    try {
      if (initialized) await SandboxManager.reset();
    } catch (error) { cleanupError = error; }
    try {
      await rm(transport, { recursive: true, force: true, maxRetries: 20, retryDelay: 500 });
    } catch (error) { cleanupError ??= error; }
    if (cleanupError) throw cleanupError;
  }
}
