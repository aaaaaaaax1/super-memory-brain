# Install And Refresh Route

Use for explicit refresh, install, repair, hot-refresh, hook repair, or host
skill synchronization requests.

Safe default:
- Install UI regression rule: after changing install.bat, install UI/menu scripts, memory import, cleanup, hot-refresh, manifest, or extensions, run scripts/install-ui-regression.ps1 and keep its workspace report current before handoff.
- Read lightweight state and manifest summary.
- Prefer dry-run or report mode before writing.
- Ask before hook/global rewrite, broad overwrite, destructive cleanup, or any
  private/raw-secret handling.
- Keep output compact: what changed, verification result, rollback path.

Do not treat ordinary task status as install/refresh.

Lifecycle ownership:
- `install.bat`, the UI global-install button, and the console global-install action delegate to `bootstrap.ps1`; this is the only complete one-click install orchestrator.
- `install.ps1` is an internal installation stage and an advanced test/custom-target entry, not the user-facing complete install path.
- `first-load-bootstrap.ps1` verifies the narrow runtime/MCP binding and a bounded stdio protocol probe on an explicit Super Brain load. A successful probe is cached for a short local interval; a failed binding or probe reuses the transactional MCP repair path.
- `hot-refresh-skills.ps1` synchronizes already installed package-owned skill copies; it does not replace installation.
- `doctor.ps1` and `verify-package.ps1` diagnose and verify; they do not install or refresh.

Codex UserPromptSubmit lifecycle:
- `hooks.json` points only to the fixed dispatcher under
  `<CODEX_HOME>\hooks\super-memory-brain`; `command` and `commandWindows`
  use the same direct Python dispatcher command. Neither command may point
  directly into a movable package tree. The sibling stable `.cmd` launcher is
  retained only as a compatibility shim for an already-cached legacy Host. A
  verified managed `.cmd` cache can run the current dispatcher without forcing
  a Desktop restart; it still requires one real submit before it is accepted.
- The dispatcher resolves the installed `package-root.txt` marker on every
  invocation, computes the current Handler generation, and delegates to the
  bounded native launcher. It writes a canonical entry receipt only after the
  child succeeds with valid hook JSON and the observed Windows command chain is
  either `ChatGPT -> codex -> launcher -> dispatcher` (the app-server hook
  runner) or `ChatGPT -> codex -> codex-code-mode-host -> launcher ->
  dispatcher` (the Code Mode runner). A PowerShell relay below the owner, a
  synthetic CLI call, or a child failure cannot validate a Host.
- Cached pre-dispatcher PowerShell, Python, native, or launcher commands may
  hot-handoff to the fixed dispatcher, but their compatibility files remain
  until a real generation-matched Desktop event has been accepted. The stable
  entry receipt records the active Desktop ancestor rather than requiring the
  immediate parent to be the Host, so compatibility shims remain attestable.
- `configurationOk` proves only installed files, command shape, discovery, and
  trust. `liveHostValidated` requires a current-generation v2 entry receipt
  with `desktopCommandChainVerified=true`, source
  `desktop_windows_command_chain`, and a live `codex` app-server or
  `codex-code-mode-host` process. Legacy ancestry-only receipts are evidence of
  neither dispatch nor recovery.
  `restartRequired` is true only when an older active Host has not demonstrated
  the stable entrypoint.
- P7 real-user evidence and governed native learning reject missing, unmanaged,
  or mismatched Handler generations; synthetic CLI evidence remains explicitly
  labeled and cannot stand in for the real Desktop path.

One-click transaction:
- `bootstrap.ps1` performs a read-only preflight before host writes, snapshots only package-owned skills and memory-runtime metadata, then installs skills, startup routing, the hook, MCP, and self-tests in that order.
- The repository root is the active source and runtime root. Refresh updates
  the single adapter and H7 MCP binding in place; no presentation-root copy or
  second runtime tree is created.
- Hook and MCP configuration use their existing local backups; a failed later stage restores those files in reverse order and restores the package-owned snapshot. A transaction receipt stays in the private install archive for inspection.
- `bootstrap.ps1 -PreflightOnly` is the safe readiness check. `-NoBackup` is intentionally rejected on this public one-click route because it would invalidate the rollback guarantee.
- Backup cleanup is report-first: it retains a bounded number of committed and fully rolled-back transaction receipts, never auto-deletes unresolved rollback evidence, and deletes only with explicit `-Apply`.
- Legacy cleanup remains report-first. It may delete only allowlisted migrated roots after package verification and byte-for-byte parity; it never imports archives, content exports, or oversized evidence into the active state root.

Second-hop only: for package layout, install markers, or hot-refresh copy scope, read
`references/package-shape.md`; do not load it from the index directly.


## Installer Capability Invariant

Every Super Brain update, especially major versions, must keep `scripts/install.bat` and the install UI abilities current. This includes one-click global inject/refresh, selected/manual agent skill injection, memory import, backup cleanup, hot-refresh/report-only behavior, direct-Git readiness, and privacy checks.

When adding or moving skills, extensions, cold references, routes, or scripts, update the installer and verification pipeline in the same change. Do not leave `install.bat` or the UI unable to run the advertised actions.

Before closeout for any install/UI/manifest/extension/cold-reference update, run `scripts/install-ui-regression.ps1` and preserve its evidence. This is the acceptance gate that prevents updates from breaking the user's install workflow.
