# Windows Bank AppContainer Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Produce a reviewable no-account Windows sandbox update with stronger workspace isolation, read-only diagnostics, recoverable persistent setup, and broader real-command verification.

**Architecture:** Keep the existing AppContainer Package SID, zero network capabilities, suspended child token check, and Job Object. Add per-user cross-session synchronization and reject overlapping workspace ACLs before mutation. Treat the profile as durable; expose static health/plan information without creating it. Keep AppContainer metadata-directory protection out of the delivery until an allow-only ACL design can prove safe inheritance and rollback.

**Tech Stack:** Windows 10 x64, .NET Framework 4.x C#, Windows PowerShell 5.1, NTFS ACL, AppContainer APIs.

## Global Constraints

- Work inside D:\windows沙箱\sandbox-runtime-bank-no-account on codex/windows-no-account-sandbox.
- No new SAM account, driver, Hyper-V, Node dependency, or unsandboxed fallback.
- All new security claims require actual host-versus-AppContainer checks, not a parser-only assertion.
- The bank VDI outcome remains unverified until the user supplies its logs. Preserve the 0.2.0 package; write any new package to a new path.
- Do not add deny ACEs against AppContainer Package SID as a substitute for tested read-only metadata policy.

---

### Task 1: Cross-session locking and overlapping workspace rejection

**Files:** `integrations/windows-bank-appcontainer/src/Policy.cs`, `integrations/windows-bank-appcontainer/src/Program.cs`, `integrations/windows-bank-appcontainer/test/verify.ps1`.

**Interfaces:** `Policy.CheckNoOverlappingPackageGrant(string workspace, SecurityIdentifier ownSid)` reads actual directory ACLs; `Program` holds one per-user Global topology mutex for prepare/remove and one per-user Global workspace mutex for the active workspace. Lock creation/open failure stops the command.

- [x] Add a synthetic test that prepares a child workspace and proves parent prepare fails without changing parent ACL, and the reverse order. Run it against 0.2.0 and confirm failure for the missing guard.
- [x] Before `Prepare` changes a profile or ACL, reject conflicting writable package grants on the candidate root, ancestors and descendant directories. Skip only the exact current workspace SID on the current root for idempotent prepare. Keep reparse/hardlink scanning.
- [x] Replace session-local synchronization with restrictive per-user Global mutexes. Preserve independent nonoverlapping workspace runs.
- [x] Run the targeted test as a normal host process and confirm both orders reject, the original workspace still runs, and cleanup restores state.

### Task 2: Read-only plan and structured status

**Files:** `integrations/windows-bank-appcontainer/src/Policy.cs`, `integrations/windows-bank-appcontainer/src/Program.cs`, new `integrations/windows-bank-appcontainer/src/Reporting.cs`, `integrations/windows-bank-appcontainer/test/verify.ps1`.

**Interfaces:** `plan --workspace PATH --json` and `status --workspace PATH --json` return parseable objects containing workspace, package SID, profile-folder state, root-grant state, and static readiness. `plan` reports whether `prepare` would add an ACL grant and whether safety checks fail. No plan/status action mutates a profile or ACL.

- [x] Add a test on a fresh synthetic workspace that snapshots DACL/profile, calls `plan --json`, parses the output, and confirms no mutation. Confirm the current CLI fails the test because plan is missing.
- [x] Implement JSON escaping, read-only inspection, and explicit error fields; do not hide profile-folder query errors as simple absence.
- [x] Add a partial-state test: after prepare, poison only the synthetic profile Temp with a junction; status must report not-ready and run must fail before child execution. Restore the fixture safely.
- [x] Preserve default human-readable status for existing scripts; run targeted tests and check JSON can be consumed by Windows PowerShell 5.1.

### Task 3: Durable setup and accurate cleanup

**Files:** `integrations/windows-bank-appcontainer/src/Policy.cs`, `integrations/windows-bank-appcontainer/test/verify.ps1`.

**Interfaces:** Repeated `prepare` repairs a partial per-workspace profile/grant state. `remove` preflights both workspace and profile trees before deleting either, and reports failures as retryable partial state. Explicit `remove` is the only profile deletion action.

- [x] Add a test that creates a profile-only state on a synthetic workspace and confirms a repeated prepare completes it without changing another workspace. Confirm the baseline CLI does not expose the required partial-state diagnosis.
- [x] Remove implicit profile deletion from prepare's ACL failure path; ensure idempotent retry is safe under the Global topology lock.
- [x] Preflight cleanup for reparse/hardlinks and root ACL before deleting profile; retain failure information and no host execution fallback.
- [x] Run targeted synthetic recovery tests. Do not claim forced-kill/VDI recovery without a corresponding observed test.

### Task 4: Execution and network evidence

**Files:** `integrations/windows-bank-appcontainer/src/Program.cs`, `integrations/windows-bank-appcontainer/src/Runner.cs`, `integrations/windows-bank-appcontainer/test/verify.ps1`.

**Interfaces:** Add `run --workspace PATH --exec ABSOLUTE_EXE [--arg VALUE ...]` as an alternative to `--shell`/`--command`, with Windows argument quoting and the existing AppContainer token/Job/stdio checks. Do not inherit arbitrary host environment.

- [x] Add a failing test for direct execution of a system binary with an argument containing spaces; confirm no unsandboxed fallback.
- [x] Implement direct executable launch using the same suspended process and validation path. Preserve the CMD/PowerShell interface.
- [x] Add actual child checks for direct file access and descendants; add an optional bank target network control that first confirms the host can reach the target, then verifies the AppContainer cannot connect. Never count infrastructure failure as a network-denied pass.
- [x] Run the targeted tests and the existing full `test/verify.ps1` as a normal host process.

### Task 5: Documentation, package, and review

**Files:** `integrations/windows-bank-appcontainer/README.md`, `integrations/windows-bank-appcontainer/验证记录.md`, `integrations/windows-bank-appcontainer/package.ps1`, `D:\windows沙箱\交付\windows-bank-appcontainer-0.3.0-preview-20261102`.

- [x] Update the documented commands, exit-code ambiguity, readiness limits, overlap rule, EDR logging guidance, and the explicit metadata-protection limitation.
- [x] Run build with `/warnaserror+`, the full real-host security suite, and `git diff --check`. Examine every new security claim against observed output.
- [x] Package to the new D-drive destination, verify ZIP contents and SHA256, then rerun the packaged executable's tests under Windows PowerShell 5.1.
- [x] Request a code review of changed security-sensitive code and address concrete findings before sharing the new package.
