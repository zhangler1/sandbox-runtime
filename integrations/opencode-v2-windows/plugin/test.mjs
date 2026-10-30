import assert from 'node:assert/strict'
import { test } from 'node:test'
import { win32 } from 'node:path'
import plugin, { wrapShell } from './index.js'

const options = { sandboxExe: process.execPath, workspace: process.cwd(), denyRead: [] }

test('wraps shell commands without embedding their raw text', () => {
  const event = { shell: 'powershell.exe', cwd: options.workspace, command: "Write-Output 'hello'; exit 3", timeout: 30000, env: { SystemRoot: options.workspace } }
  wrapShell(event, options)
  assert.match(event.command, /--shell powershell/)
  assert.match(event.command, /FromBase64String/)
  assert.doesNotMatch(event.command, /Write-Output|hello/)
  assert.equal(event.env.SystemRoot, process.env.SystemRoot)
})

test('rejects a shell cwd outside the configured workspace', () => {
  const event = { shell: 'powershell.exe', cwd: win32.resolve(options.workspace, '..', 'outside'), command: 'whoami' }
  assert.throws(() => wrapShell(event, options), /cwd/)
})

test('preserves a shell cwd inside the workspace', () => {
  const subdir = win32.join(options.workspace, 'src')
  const event = { shell: 'powershell.exe', cwd: subdir, command: 'pwd' }
  wrapShell(event, options)
  assert.match(event.command, /--cwd/)
})

test('rejects PowerShell 7 until that shell is supported by the runner', () => {
  const event = { shell: 'pwsh.exe', cwd: options.workspace, command: 'pwd' }
  assert.throws(() => wrapShell(event, options), /unsupported shell/)
})

test('reads V2 plugin options from ctx.options and blocks other tools', async () => {
  let shellHook
  let toolHook
  await plugin.setup({
    options,
    tool: { hook: async (_name, callback) => { toolHook = callback } },
    shell: { hook: async (_name, callback) => { shellHook = callback } },
  })
  assert.throws(() => toolHook({ tool: 'read' }), /not permitted/)
  const event = { shell: 'powershell.exe', cwd: options.workspace, command: 'whoami' }
  shellHook(event)
  assert.match(event.command, /--workspace/)
})
