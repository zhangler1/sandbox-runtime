import { existsSync, lstatSync, realpathSync } from 'node:fs'
import { win32 } from 'node:path'
import { fileURLToPath } from 'node:url'

const quote = value => `'${value.replaceAll("'", "''")}'`
const equal = (a, b) => a.toLowerCase() === b.toLowerCase()
const inside = (root, value) => equal(root, value) || value.toLowerCase().startsWith(root.toLowerCase() + '\\')

function localPath(value, label, directory) {
  if (typeof value !== 'string' || !/^[A-Za-z]:[\\/]/.test(value) || /[\x00-\x1f]/.test(value) || value.slice(2).includes(':')) {
    throw new Error(`Bank sandbox: ${label} must be an absolute local path`)
  }
  const path = win32.normalize(value).replace(/\\$/, '')
  if (path.length < 4 || !existsSync(path)) throw new Error(`Bank sandbox: ${label} missing or drive root`)
  const info = lstatSync(path)
  if (info.isSymbolicLink() || (directory ? !info.isDirectory() : !info.isFile())) throw new Error(`Bank sandbox: invalid ${label}`)
  if (!equal(path, realpathSync.native(path))) throw new Error(`Bank sandbox: ${label} contains an alias or reparse point`)
  return path
}

export function validateOptions(options) {
  const workspace = localPath(options?.workspace, 'workspace', true)
  const controlDirectory = localPath(options?.controlDirectory, 'controlDirectory', true)
  const sandboxExe = localPath(options?.sandboxExe, 'sandboxExe', false)
  for (let parent = controlDirectory; parent; ) {
    if (existsSync(win32.join(parent,'.git'))) throw new Error('Bank sandbox: controlDirectory must be outside every Git repository')
    const next = win32.dirname(parent)
    if (next === parent) break
    parent = next
  }
  if (!sandboxExe.toLowerCase().endsWith('.exe')) throw new Error('Bank sandbox: runner must be an EXE')
  for (const [label, path] of [['controlDirectory', controlDirectory], ['sandboxExe', sandboxExe], ['plugin', fileURLToPath(import.meta.url)]]) {
    if (inside(workspace, win32.normalize(path))) throw new Error(`Bank sandbox: ${label} must be outside workspace`)
  }
  if (inside(controlDirectory, workspace)) throw new Error('Bank sandbox: workspace must be outside controlDirectory')
  return { workspace, controlDirectory, sandboxExe }
}

export function allowTool(event) {
  if (event?.tool !== 'shell') throw new Error(`Bank sandbox: tool ${event?.tool} is not permitted; use shell inside the sandbox`)
}

export function wrapShell(event, options) {
  const { workspace, controlDirectory, sandboxExe } = validateOptions(options)
  if (!event || typeof event.command !== 'string' || !event.command.trim()) throw new Error('Bank sandbox: empty command')
  if (event.command.includes('\0')) throw new Error('Bank sandbox: NUL in command')
  if (Buffer.byteLength(event.command, 'utf8') > 12000) throw new Error('Bank sandbox: command exceeds 12000 UTF-8 bytes')
  const cwd = localPath(event.cwd, 'shell cwd', true)
  if (!equal(cwd, workspace) && !equal(cwd, controlDirectory)) throw new Error('Bank sandbox: shell cwd must equal workspace or controlDirectory')
  const name = win32.basename(event.shell ?? '').toLowerCase()
  const shell = name === 'powershell.exe' ? 'powershell' : name === 'cmd.exe' ? 'cmd' : undefined
  if (!shell) throw new Error(`Bank sandbox: unsupported shell ${event.shell}`)
  if (event.timeout !== undefined && (!Number.isSafeInteger(event.timeout) || event.timeout < 1)) throw new Error('Bank sandbox: invalid timeout')
  const timeout = Math.min(event.timeout ?? 30000, 300000)
  event.timeout = timeout + 10000
  const encoded = Buffer.from(event.command, 'utf8').toString('base64')
  const windows = process.env.SystemRoot
  if (!windows || !/^[A-Za-z]:\\/.test(windows)) throw new Error('Bank sandbox: Windows system directory unavailable')
  const bridge = win32.join(windows, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  if (!existsSync(bridge)) throw new Error('Bank sandbox: system PowerShell missing')
  event.shell = bridge
  event.cwd = controlDirectory
  event.env = Object.fromEntries(Object.entries({ SystemRoot: windows, WINDIR: windows,
    PATH: win32.join(windows, 'System32'), PATHEXT: '.COM;.EXE;.BAT;.CMD', ComSpec: win32.join(windows,'System32','cmd.exe'), TEMP: process.env.TEMP, TMP: process.env.TMP,
    USERPROFILE: process.env.USERPROFILE }).filter(([, value]) => typeof value === 'string'))
  event.command = "$ErrorActionPreference='Stop'; " +
    `$bankCommand=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded}')); ` +
    `$global:LASTEXITCODE=$null; & ${quote(sandboxExe)} run --workspace ${quote(workspace)} --shell ${shell} --timeout-ms ${timeout} --command $bankCommand; ` +
    "if ($null -eq $LASTEXITCODE) { throw 'Bank sandbox: CLI did not return an exit code' }; exit $LASTEXITCODE"
}

export default {
  id: 'opencode-v2-bank-appcontainer',
  async setup(ctx) {
    if (process.env.BANK_SANDBOX_LAUNCHER !== '1' || process.env.OPENCODE_CONFIG_PROJECT_DISABLE !== '1') {
      throw new Error('Bank sandbox: launch through launch.ps1 with project configuration disabled')
    }
    validateOptions(ctx.options)
    await ctx.tool.hook('execute.before', allowTool)
    await ctx.shell.hook('create.before', event => wrapShell(event, ctx.options))
  },
}
