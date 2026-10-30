import assert from 'node:assert/strict';
import test from 'node:test';
import { buildPolicy, decodeOutput, loadHelperBytes, selectShell, validateTransportRoot } from '../src/runner.mjs';
import { createHash } from 'node:crypto';

test('policy grants writes only to the workspace and denies network by default', () => {
  const policy = buildPolicy('D:\\workspace\\demo', 'D:\\workspace\\transport', 'D:\\tools\\srt-win.exe');
  assert.deepEqual(policy.filesystem.allowWrite, ['D:\\workspace\\demo']);
  assert.deepEqual(policy.filesystem.allowRead, ['D:\\workspace\\demo', 'D:\\workspace\\transport']);
  assert.deepEqual(policy.network.allowedDomains, []);
  assert.deepEqual(policy.network.deniedDomains, ['*']);
  assert.equal(policy.network.strictAllowlist, true);
});

test('policy stamps explicit read-deny paths in addition to protected workspace files', () => {
  const policy = buildPolicy('D:\\work', 'D:\\transport', 'D:\\helper.exe', undefined, ['D:\\outside']);
  assert.deepEqual(policy.filesystem.denyRead, ['D:\\work\\.env', 'D:\\work\\.env.local', 'D:\\outside']);
});

test('policy permits only the explicitly allowed network domain', () => {
  const policy = buildPolicy('D:\\work', 'D:\\transport', 'D:\\helper.exe', undefined, [], ['registry.npmmirror.com']);
  assert.deepEqual(policy.network.allowedDomains, ['registry.npmmirror.com']);
  assert.deepEqual(policy.network.deniedDomains, []);
  assert.equal(policy.network.strictAllowlist, true);
});

test('PowerShell and CMD use explicit SRT shell types', () => {
  assert.equal(selectShell({ shell: 'powershell' }), 'powershell');
  assert.equal(selectShell({ shell: 'cmd' }), 'cmd');
});

test('Git Bash resolves only a concrete executable outside the user profile', () => {
  assert.equal(selectShell({ shell: 'git-bash', bashExe: 'C:\\Program Files\\Git\\bin\\bash.exe' }, 'C:\\Users\\alice'), 'C:\\Program Files\\Git\\bin\\bash.exe');
  assert.throws(() => selectShell({ shell: 'git-bash', bashExe: 'C:\\Users\\alice\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe' }, 'C:\\Users\\alice'), /profile|WindowsApps/);
});

test('loads the pinned Windows helper from the local SRT package', async () => {
  const bytes = await loadHelperBytes();
  assert.equal(createHash('sha256').update(bytes).digest('hex'), 'a8e22bc098ac1146ec9b9151d5f1770c05b897cd1ac588161e1287a248cc9176');
});

test('decodes Windows console errors without losing Chinese text', () => {
  const gbk = Buffer.from('bedcbef8b7c3ceca', 'hex');
  assert.equal(decodeOutput(gbk, 'powershell'), '拒绝访问');
  assert.equal(decodeOutput(gbk, 'cmd'), '拒绝访问');
  assert.equal(decodeOutput(Buffer.from('Permission denied'), 'git-bash'), 'Permission denied');
});

test('rejects a transport root inside the writable workspace', async () => {
  const workspace = 'D:\\workspace\\sandbox';
  await assert.rejects(validateTransportRoot(workspace, workspace), /transport.*workspace/i);
  await assert.rejects(validateTransportRoot('D:\\workspace\\sandbox\\tmp', workspace), /transport.*workspace/i);
});
