import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs'
import { join, win32 } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'

test('adapter routes shell data and rejects host execution bypasses', async () => {
  const modulePath = fileURLToPath(new URL('../index.js', import.meta.url))
  assert.ok(existsSync(modulePath), 'adapter module must exist before shell calls can be protected')
  const { default: plugin, wrapShell, allowTool } = await import('../index.js')
  const parent = join(tmpdir(),'bank-adapter-unit-tests')
  mkdirSync(parent, { recursive: true })
  const root = mkdtempSync(join(parent, 'adapter-'))
  try {
    const workspace = join(root, 'work'), controlDirectory = join(root, 'control')
    mkdirSync(workspace); mkdirSync(controlDirectory)
    const sandboxExe = join(controlDirectory, 'bank-sandbox.exe')
    writeFileSync(sandboxExe, 'fixture')
    const options = { workspace, controlDirectory, sandboxExe }
    const command = "Write-Output '中文'; & calc.exe; $(whoami); `\"\nexit 9"
    const event = { shell: 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', cwd: controlDirectory, command, timeout: 9000, env: { SECRET: 'do-not-forward' } }
    wrapShell(event, options)
    assert.equal(event.cwd, controlDirectory)
    assert.equal(win32.basename(event.shell).toLowerCase(), 'powershell.exe')
    assert.ok(!event.command.includes('calc.exe'), 'untrusted text must not execute in the host bridge')
    const encoded = event.command.match(/FromBase64String\('([A-Za-z0-9+/=]+)'\)/)?.[1]
    assert.equal(Buffer.from(encoded, 'base64').toString('utf8'), command)
    assert.ok(event.command.includes('--timeout-ms 9000'))
    assert.equal(event.timeout, 19000, 'outer host timeout must leave the CLI time to terminate its job')
    assert.ok(event.command.includes('$null -eq $LASTEXITCODE'), 'bridge must reject a skipped native command')
    assert.equal(event.env.SECRET, undefined)
    mkdirSync(join(root,'.git'))
    assert.throws(() => wrapShell({ ...event, command }, options), /Git/)
    rmSync(join(root,'.git'),{recursive:true})
    assert.throws(() => wrapShell({ ...event, shell: 'bash.exe', command }, options), /unsupported shell/)
    assert.throws(() => wrapShell({ ...event, cwd: root, command }, options), /cwd/)
    assert.throws(() => wrapShell({ ...event, command }, { ...options, sandboxExe: join(workspace, 'fake.exe') }), /outside|missing/)
    assert.throws(() => wrapShell({ ...event, command }, { ...options, controlDirectory: workspace }), /outside/)
    assert.throws(() => wrapShell({ ...event, command }, { ...options, sandboxExe: join(controlDirectory, 'missing.exe') }), /missing/)
    assert.throws(() => wrapShell({ ...event, command: 'x\0y' }, options), /NUL/)
    for (const tool of ['read', 'write', 'edit', 'apply_patch', 'task', 'mcp__exec', 'unknown']) assert.throws(() => allowTool({ tool }), /not permitted/)
    allowTool({ tool: 'shell' })
    const hooks = []
    const oldGate = process.env.BANK_SANDBOX_LAUNCHER, oldDisable = process.env.OPENCODE_CONFIG_PROJECT_DISABLE
    process.env.BANK_SANDBOX_LAUNCHER = '1'; process.env.OPENCODE_CONFIG_PROJECT_DISABLE = '1'
    try {
      await plugin.setup({ options, tool: { hook: async (name, fn) => hooks.push(['tool', name, fn]) }, shell: { hook: async (name, fn) => hooks.push(['shell', name, fn]) } })
    } finally {
      for (const [key,value] of [['BANK_SANDBOX_LAUNCHER',oldGate],['OPENCODE_CONFIG_PROJECT_DISABLE',oldDisable]]) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value
      }
    }
    assert.deepEqual(hooks.map(x => x.slice(0,2)), [['tool','execute.before'],['shell','create.before']])
    assert.throws(() => hooks[0][2]({tool:'read'}), /not permitted/)
  } finally { rmSync(root, {recursive:true,force:true}) }
})
