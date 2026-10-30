import assert from 'node:assert/strict';
import test from 'node:test';
import { parseArgs } from '../src/options.mjs';

test('parses a PowerShell command without changing its text', () => {
  const value = parseArgs([
    'run', '--shell', 'powershell', '--workspace', 'D:\\workspace\\demo',
    '--command', "Set-Content -LiteralPath 'D:\\workspace\\demo\\a.txt' -Value x",
  ]);
  assert.equal(value.action, 'run');
  assert.equal(value.shell, 'powershell');
  assert.equal(value.workspace, 'D:\\workspace\\demo');
  assert.equal(value.command, "Set-Content -LiteralPath 'D:\\workspace\\demo\\a.txt' -Value x");
  assert.equal(value.timeoutMs, 30_000);
});

test('requires an absolute workspace and a nonempty command', () => {
  assert.throws(() => parseArgs(['run', '--shell', 'cmd', '--workspace', 'relative', '--command', 'whoami']), /absolute/);
  assert.throws(() => parseArgs(['run', '--shell', 'cmd', '--workspace', 'D:\\work', '--command', '  ']), /command/);
});

test('accepts a working directory below the workspace and rejects a relative cwd', () => {
  const base = ['run', '--shell', 'powershell', '--workspace', 'D:\\work', '--command', 'pwd'];
  assert.equal(parseArgs([...base, '--cwd', 'D:\\work\\src']).cwd, 'D:\\work\\src');
  assert.throws(() => parseArgs([...base, '--cwd', 'src']), /cwd/);
});

test('requires a specific Git Bash executable', () => {
  assert.throws(() => parseArgs(['run', '--shell', 'git-bash', '--workspace', 'D:\\work', '--command', 'whoami']), /bash-exe/);
  assert.throws(() => parseArgs(['run', '--shell', 'git-bash', '--bash-exe', 'bash.exe', '--workspace', 'D:\\work', '--command', 'whoami']), /absolute/);
  const value = parseArgs(['run', '--shell', 'git-bash', '--bash-exe', 'C:\\Program Files\\Git\\bin\\bash.exe', '--workspace', 'D:\\work', '--command', 'whoami']);
  assert.equal(value.bashExe, 'C:\\Program Files\\Git\\bin\\bash.exe');
});

test('accepts repeated absolute deny-read paths and rejects a drive root', () => {
  const result = parseArgs(['run', '--shell', 'powershell', '--workspace', 'D:\\work', '--command', 'whoami', '--deny-read', 'D:\\outside', '--deny-read', 'C:\\Users\\Public\\report.txt']);
  assert.deepEqual(result.denyRead, ['D:\\outside', 'C:\\Users\\Public\\report.txt']);
  assert.throws(() => parseArgs(['run', '--shell', 'cmd', '--workspace', 'D:\\work', '--command', 'whoami', '--deny-read', 'D:\\']), /deny-read/);
  assert.throws(() => parseArgs(['run', '--shell', 'cmd', '--workspace', 'D:\\work', '--command', 'whoami', '--deny-read', 'relative']), /deny-read/);
});

test('accepts an exact network allow-domain and rejects wildcards or URLs', () => {
  const args = ['run', '--shell', 'git-bash', '--bash-exe', 'D:\\Git\\bin\\bash.exe', '--workspace', 'D:\\work', '--command', 'curl https://registry.npmmirror.com'];
  assert.deepEqual(parseArgs([...args, '--allow-domain', 'registry.npmmirror.com']).allowDomains, ['registry.npmmirror.com']);
  assert.throws(() => parseArgs([...args, '--allow-domain', '*.example.com']), /allow-domain/);
  assert.throws(() => parseArgs([...args, '--allow-domain', 'https://example.com']), /allow-domain/);
});

test('rejects unknown options and unreasonable timeouts', () => {
  assert.throws(() => parseArgs(['run', '--shell', 'bash', '--workspace', 'D:\\work', '--command', 'whoami']), /shell/);
  assert.throws(() => parseArgs(['run', '--shell', 'cmd', '--workspace', 'D:\\work', '--command', 'whoami', '--oops']), /option/);
  assert.throws(() => parseArgs(['run', '--shell', 'cmd', '--workspace', 'D:\\work', '--command', 'whoami', '--timeout-ms', '0']), /timeout/);
});

test('supports explicit setup and read-only status commands', () => {
  assert.deepEqual(parseArgs(['install']), { action: 'install' });
  assert.deepEqual(parseArgs(['status']), { action: 'status' });
  assert.deepEqual(parseArgs(['uninstall']), { action: 'uninstall' });
  assert.throws(() => parseArgs(['install', '--force']), /Expected|option/);
});
