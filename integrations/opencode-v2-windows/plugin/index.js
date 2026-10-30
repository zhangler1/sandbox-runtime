import { existsSync } from 'node:fs'
import { win32 } from 'node:path'

const quote = (value) => `'${String(value).replaceAll("'", "''")}'`

function localPath(value, label) {
  if (typeof value !== 'string' || !win32.isAbsolute(value) || value.startsWith('\\\\')) {
    throw new Error(`Windows sandbox: ${label} must be an absolute local path`)
  }
  return win32.normalize(value)
}

function shellType(shell) {
  const name = win32.basename(shell).toLowerCase()
  if (name === 'powershell.exe') return 'powershell'
  if (name === 'cmd.exe') return 'cmd'
  if (name === 'bash.exe') return 'git-bash'
  throw new Error(`Windows sandbox: unsupported shell ${shell}`)
}

export function wrapShell(event, options) {
  const exe = localPath(options?.sandboxExe, 'sandboxExe')
  const workspace = localPath(options?.workspace, 'workspace')
  if (!existsSync(exe)) throw new Error(`Windows sandbox: EXE missing: ${exe}`)
  if (!existsSync(workspace)) throw new Error(`Windows sandbox: workspace missing: ${workspace}`)
  if (!event || typeof event.command !== 'string' || !event.command.trim()) {
    throw new Error('Windows sandbox: empty shell command')
  }
  const cwd = localPath(event.cwd, 'shell cwd')
  const relative = win32.relative(workspace, cwd)
  if (relative === '..' || relative.startsWith(`..${win32.sep}`) || win32.isAbsolute(relative)) {
    throw new Error(`Windows sandbox: shell cwd must stay inside configured workspace: ${workspace}`)
  }
  const type = shellType(event.shell)
  const timeout = Number.isSafeInteger(event.timeout) && event.timeout > 0
    ? Math.min(event.timeout, 300000) : 30000
  const encoded = Buffer.from(event.command, 'utf8').toString('base64')
  const args = [`run --shell ${type}`, `--workspace ${quote(workspace)}`, `--cwd ${quote(cwd)}`]
  if (type === 'git-bash') args.push(`--bash-exe ${quote(localPath(event.shell, 'bash.exe'))}`)
  for (const path of options.denyRead ?? []) args.push(`--deny-read ${quote(localPath(path, 'denyRead'))}`)
  args.push(`--timeout-ms ${timeout}`, '--command $sandboxCommand')
  const systemPowerShell = win32.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  if (!existsSync(systemPowerShell)) throw new Error(`Windows sandbox: PowerShell missing: ${systemPowerShell}`)
  event.shell = systemPowerShell
  event.env = { ...event.env, SystemRoot: process.env.SystemRoot }
  event.command = `$sandboxCommand=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded}')); & ${quote(exe)} ${args.join(' ')}; exit $LASTEXITCODE`
}

export default {
  id: 'opencode-v2-windows-sandbox',
  async setup(ctx) {
    await ctx.tool.hook('execute.before', (event) => {
      if (event.tool !== 'shell') throw new Error(`Windows sandbox: tool ${event.tool} is not permitted in this mode`)
    })
    await ctx.shell.hook('create.before', (event) => wrapShell(event, ctx.options))
  },
}
