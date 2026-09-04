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

Hookless H7/MCP lifecycle:
- `brain_turn` is the only normal lifecycle authority. UserPromptSubmit,
  Stop, P7, and Host readback are retired compatibility surfaces and never
  provide continuation proof or authorization.
- `install-runtime.ps1` registers one static `local_mcp_launcher.py` entry for
  discovery and health. It deliberately starts without a local session id, so
  `H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED`/`withheld` and zero Broker
  channels are the expected static result.
- A real host-neutral embedding adapter must launch one process per local
  project scope with the actual project cwd and a strict
  `SUPER_BRAIN_LOCAL_SESSION_ID` in the child environment. The package-owned
  contract and lifecycle helper are documented in
  `references/local-mcp-adapter.md`; the SID never belongs in argv, MCP
  arguments, persistent config, or visible output.
- H7 resolves the current execution contract and live project proof before the
  Broker bind. Changing cwd, SID, or Broker instance requires a fresh launcher
  process; a new SID uses explicit local rebind issue → consume → finalize.
- `brain_cli.py` remains an equivalent local H7 fallback for compatibility,
  but its legacy environment provider intentionally preserves historical SID
  normalization. It is not a substitute for the strict host-neutral MCP
  adapter.

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
