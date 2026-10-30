import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));

test('help describes the standalone run interface', () => {
  const result = spawnSync(process.execPath, [script, '--help'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /--shell powershell\|cmd\|git-bash/);
});

test('invalid requests fail without launching a normal shell', () => {
  const result = spawnSync(process.execPath, [script, 'run', '--shell', 'cmd', '--workspace', 'D:\\work', '--command', '', '--json'], { encoding: 'utf8' });
  assert.equal(result.status, 125);
  const output = JSON.parse(result.stdout);
  assert.equal(output.ok, false);
  assert.match(output.error, /command/);
});
