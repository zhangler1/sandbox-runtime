import { win32 } from 'node:path';

const VALUE_OPTIONS = new Set(['--shell', '--workspace', '--cwd', '--command', '--bash-exe', '--timeout-ms', '--deny-read', '--allow-domain']);

export function parseArgs(argv) {
  if (argv.length === 1 && (argv[0] === '--help' || argv[0] === 'help')) return { action: 'help' };
  if (argv.length === 1 && ['install', 'status', 'uninstall'].includes(argv[0])) return { action: argv[0] };
  if (argv[0] !== 'run') throw new Error('Expected run, install, status, uninstall, or --help');

  const values = new Map();
  const denyRead = [];
  const allowDomains = [];
  let json = false;
  for (let i = 1; i < argv.length; i++) {
    const name = argv[i];
    if (name === '--json') {
      if (json) throw new Error('Duplicate option --json');
      json = true;
      continue;
    }
    if (!VALUE_OPTIONS.has(name)) throw new Error(`Unknown option ${name}`);
    if (name !== '--deny-read' && name !== '--allow-domain' && values.has(name)) throw new Error(`Duplicate option ${name}`);
    const value = argv[++i];
    if (value === undefined) throw new Error(`Missing value for option ${name}`);
    if (name === '--deny-read') denyRead.push(value);
    else if (name === '--allow-domain') allowDomains.push(value);
    else values.set(name, value);
  }

  const shell = values.get('--shell');
  if (!['powershell', 'cmd', 'git-bash'].includes(shell)) throw new Error('shell must be powershell, cmd, or git-bash');
  const workspace = values.get('--workspace');
  if (!workspace || !win32.isAbsolute(workspace) || workspace.startsWith('\\\\')) {
    throw new Error('workspace must be an absolute local Windows path');
  }
  const cwd = values.get('--cwd') ?? workspace;
  if (!win32.isAbsolute(cwd) || cwd.startsWith('\\')) {
    throw new Error('cwd must be an absolute local Windows path');
  }
  for (const path of denyRead) {
    if (!win32.isAbsolute(path) || path.startsWith('\\\\') || win32.normalize(path) === win32.parse(path).root) {
      throw new Error('--deny-read requires a concrete absolute local path, not a drive root');
    }
  }
  for (const domain of allowDomains) {
    if (!/^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$/.test(domain)) {
      throw new Error('--allow-domain requires an exact DNS hostname');
    }
  }
  const command = values.get('--command');
  if (!command?.trim()) throw new Error('command must be nonempty');

  const bashExe = values.get('--bash-exe');
  if (shell === 'git-bash') {
    if (!bashExe) throw new Error('git-bash requires --bash-exe');
    if (!win32.isAbsolute(bashExe) || bashExe.startsWith('\\\\')) {
      throw new Error('--bash-exe must be an absolute local Windows path');
    }
    if (win32.basename(bashExe).toLowerCase() !== 'bash.exe') throw new Error('--bash-exe must point to bash.exe');
  } else if (bashExe) {
    throw new Error('--bash-exe is only valid with git-bash');
  }

  const rawTimeout = values.get('--timeout-ms') ?? '30000';
  const timeoutMs = Number(rawTimeout);
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 300_000) {
    throw new Error('timeout-ms must be an integer from 1 to 300000');
  }

  return { action: 'run', shell, workspace: win32.normalize(workspace), cwd: win32.normalize(cwd), command, bashExe, timeoutMs, json, denyRead: denyRead.map(path => win32.normalize(path)), allowDomains };
}
