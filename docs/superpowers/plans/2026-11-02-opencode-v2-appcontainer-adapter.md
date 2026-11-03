# OpenCode V2 AppContainer Adapter Implementation Plan

**Goal:** Automatically route OpenCode shell tool calls into the existing account-free CLI and reject other model tools.

**Architecture:** A separate JavaScript V2 plugin rewrites the shell create hook into a system PowerShell bridge. Only base64 data containing the original command enters that bridge; the original command executes inside AppContainer. OpenCode starts in a trusted control directory outside the writable workspace, so workspace configuration cannot become a host plugin. The launcher uses an isolated user-only profile containing the existing model configuration and only this adapter; normal work configuration is preserved.

**Tech Stack:** Node ESM, node:test, Windows PowerShell 5.1, OpenCode V2 2.1.4-bc.59bb7.n67, bank-sandbox 0.3.0.

## Constraints

- Module: integrations/opencode-v2-bank-sandbox, sibling to windows-bank-appcontainer.
- No host fallback, automatic package installation, new SAM account, network capability, or client source changes.
- Permit only shell tool; reject task, file, MCP and unknown tools.
- Reject unsupported shells and working directories; commands execute at sandbox root.
- Plugin, runner, control directory and model configuration must remain outside writable workspace.
- Test actual OpenCode JSONL tool results and host filesystem state; model prose is not evidence.
- Git for Windows remains unsupported. Windows 10 VDI outcome remains pending.

## Tasks

- [x] Research exact local V2 hook mutation and configuration discovery semantics.
- [x] Add failing node tests for command injection, path boundaries, unsupported shells, unknown tools, and missing runner.
- [x] Implement plugin routing and restrictive tool hook; run node tests.
- [x] Add a Windows launcher/setup with trusted control directory and isolated configuration. Ensure setup never prints provider credentials.
- [x] Verify bridge execution and no-fallback initialization failure using synthetic host-vs-AppContainer files.
- [x] Run actual OpenCode prompts for workspace write, outside read/write and denied non-shell tool; verify nested executable isolation in the bridge suite. Network is retained as a documented core-CLI boundary, not a new OpenCode acceptance claim.
- [x] Document exact claims, unsupported operations and cleanup. Package separately and review security-sensitive changes.
