#!/usr/bin/env node
import { parseArgs } from './options.mjs';
import { runSandboxed } from './runner.mjs';
import { getSandboxStatus, installSandbox, uninstallSandbox } from './setup.mjs';

const usage = `Windows sandbox CLI (SRT 0.0.81)

Usage:
  windows-sandbox-cli.exe status
  windows-sandbox-cli.exe install
  windows-sandbox-cli.exe uninstall
  windows-sandbox-cli.exe run --shell powershell|cmd|git-bash --workspace <absolute-path> [--cwd <workspace-subdirectory>] --command <text> [--deny-read <absolute-path>]... [--allow-domain <exact-host>]... [--bash-exe <absolute-bash.exe>] [--timeout-ms 30000] [--json]

Install prompts for administrator permission once and skips user-profile read access.
Git Bash requires --bash-exe pointing to a real Git for Windows installation outside the user profile.
The workspace must exist outside the user profile. Network access is denied by default; --allow-domain permits only named hosts.
Reads follow host NTFS permissions unless an explicit --deny-read path is stamped.
`;

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
    if (options.action === 'help') {
      process.stdout.write(usage);
      return;
    }
    if (['status', 'install', 'uninstall'].includes(options.action)) {
      const result = options.action === 'install' ? await installSandbox()
        : options.action === 'uninstall' ? await uninstallSandbox()
          : await getSandboxStatus();
      process.stdout.write(`${JSON.stringify(result)}\n`);
      process.exitCode = result.cancelled || (options.action !== 'uninstall' && !result.userProvisioned) ? 1 : 0;
      return;
    }
    const result = await runSandboxed(options);
    const ok = result.exitCode === 0 && !result.timedOut && !result.outputLimitExceeded;
    if (options.json) {
      process.stdout.write(`${JSON.stringify({ ok, ...result })}\n`);
    } else {
      process.stdout.write(result.stdout);
      process.stderr.write(result.stderr);
      if (result.timedOut) process.stderr.write('Sandbox command timed out.\n');
      if (result.outputLimitExceeded) process.stderr.write('Sandbox command output exceeded 1 MiB.\n');
    }
    process.exitCode = result.timedOut ? 124 : result.outputLimitExceeded ? 125 : result.exitCode ?? 125;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (options?.json || process.argv.includes('--json')) {
      process.stdout.write(`${JSON.stringify({ ok: false, error: message })}\n`);
    } else {
      process.stderr.write(`Sandbox error: ${message}\n`);
    }
    process.exitCode = 125;
  }
}

main().catch((error) => {
  process.stderr.write(`Sandbox fatal error: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 125;
});
