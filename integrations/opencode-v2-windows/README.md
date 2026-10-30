# OpenCode V2 Windows sandbox integration

This directory contains **source code**, not a built release. It is separate from the core `sandbox-runtime` library:

- `cli/` is a small Windows command runner using `@anthropic-ai/sandbox-runtime` 0.0.81 and the pinned `srt-win` helper. It runs PowerShell, CMD, or Git Bash under the `srt-sandbox` account. The default policy allows writes in one workspace, denies network access, and denies reads of `.env` and `.env.local` in that workspace. `--deny-read` adds explicit read denials.
- `plugin/` is a JavaScript server plugin for OpenCode V2 work mode. It wraps the V2 shell hook through the CLI and blocks non-shell tools. Its installer adds the plugin to `~/.bocomcode/work/config/bocomcode.json` without changing the configured model or key.

## Build and install (Windows x64)

Use Node.js 24 and npm. From `cli/`, run `npm ci`, `npm test`, then `npm run build:exe`. The build writes `cli/dist/windows-sandbox-cli.exe`; it embeds the `srt-win` helper and pins its SHA-256. Copy the EXE to `plugin/windows-sandbox-cli.exe`. Build artifacts and `node_modules` are not committed.

In PowerShell, enter `plugin/` and run the following. The first command prompts for administrator permission and provisions the local sandbox account and WFP rules; it skips the broad user-profile read grant. The workspace must already exist, be on a local drive outside the user profile, and not be a drive root or junction.

```powershell
.\windows-sandbox-cli.exe install
.\install.ps1 -Workspace 'D:\work\project' -DenyRead 'D:\work\sensitive'
```

Keep the plugin directory and EXE **outside** the workspace: the installer rejects either trusted component inside the tree the sandbox can write. Start a **new** OpenCode V2 `--channel=work` process in the configured workspace. Check that a shell `whoami` tool call returns `srt-sandbox`. Commands may run from a real subdirectory of the workspace; junctions and symlinks are rejected. This version supports Windows PowerShell 5.1, CMD and Git Bash; `pwsh.exe` is rejected rather than silently changed to PowerShell 5.1.

To remove only the OpenCode plugin registration, run `plugin/remove.ps1`; this does not uninstall the machine-wide SRT account and WFP rules. SRT may keep workspace grants between runs for reuse, as documented by its Windows implementation. The CLI does not forcibly remove those grants while another session might be using them; use the SRT uninstall/ACL maintenance commands when decommissioning a workspace.

## CLI policy and limits

The CLI's optional `--allow-domain registry.npmmirror.com` (or another exact DNS hostname) permits only that domain for a single invocation. It was added for network benchmarking. The OpenCode plugin does **not** pass this option, so its network policy remains deny-all. A `--deny-read` entry is needed to protect an otherwise readable external path; Windows SRT does not make every external file unreadable. The Windows runtime is marked alpha upstream and retains its documented network and filesystem limitations.

This integration has been tested with an OpenCode V2 work process and GLM-5.2 on one Windows x64 machine. The local review results covered PowerShell, CMD, Git Bash, workspace writes, external write rejection, and explicit read denial. A separate benchmark-only CLI confirmed HTTP 200 for a single allowed domain and HTTP 000 when denied. These observations do not establish production readiness or a general network egress guarantee.
