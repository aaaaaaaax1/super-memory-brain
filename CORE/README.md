# Super Memory Brain

Version: 0.6.0

Super Memory Brain is a host-neutral independent control-plane agent. H7
`brain_turn` owns lifecycle, continuity, task state, project proof, and
verification. The installed skill is only a thin entry adapter; a local MCP
host uses `runtime/local_scope_adapter.py` to inject the project cwd and one
strict local session without relying on Host or platform thread metadata.

`CORE/` is the single source tree. Its parent is the direct Git working tree
and intentionally exposes only `CORE/` plus the two numbered VBS launchers.
Clone the repository to install it; there is no generated share/export package.

## Layout

- `runtime/`: H7 runtime, MCP/CLI transport, continuity, rules, and UI server.
- `scripts/`: install, refresh, memory, task, verification, and maintenance.
- `super-memory-brain/`: the only host-facing skill entry.
- `modules/`, `extensions/`, `references/`, `tests/`, `ui/`, `vendor/`:
  package-owned capabilities, cold references, regressions, and UI.
- `../private-state/`: local memory and mutable task/runtime state. Never commit.
- `../private-archive/`: local historical evidence. Never commit.
- `../memory/`: compatibility junction to `private-state`; its contents are local.

## Install and verify

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\bootstrap.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\first-load-bootstrap.ps1" -Json
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\verify-package.ps1" -PackageOnly
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\release-readiness.ps1" -Json
```

Install or refresh only the single `super-memory-brain` host entry. Bundled
capabilities are absorbed into Super Brain and routed semantically; they are
not installed as independent host skills. For a non-Codex local MCP embedding,
follow `references/local-mcp-adapter.md`.

## Git privacy

The parent `.gitignore` excludes local memory, archives, runtime state, caches,
generated output, credentials, and machine-local markers. Before committing,
inspect `git status --short` and `git check-ignore -v` for private paths. Never
stage `private-state`, `private-archive`, `memory`, runtime workspace state,
logs, `.env`, keys, or generated outputs.

`super-brain-rules.json` is the sole behavioral-policy registry. Current user
instruction owns objective and authorization; H7 owns execution state; the
latest visible assistant reply plus live project proof owns progress; files and
tool results own project facts; memory is supplemental. On drift, correct the
visible state first, repair the root cause, and replay the same path.

For the full operating references, read `CURRENT_BASELINE.md`, then
`manifest.json`, then `CHANGELOG.md`; use `QUICK_START.md`, `COMMANDS.md`,
`scripts\doctor.ps1`, `scripts\install-ui.vbs`, `scripts\install.bat console`,
`scripts\brain.bat`, and `scripts\check-install-ui-paths.ps1` as needed.
Super Brain installs one adapter only and uses H7 `brain_turn`; it does not
install or depend on P7/Hook routes. Hybrid Recall, ADR records,
`memory-eval.ps1`, and `last-memory-eval.json` remain local verification
surfaces. Install backups are reviewed with `cleanup-install-backups.ps1`.
Commander Agent Teams remain optional and are operated through
`team-dispatch-check.ps1` and `team-task-status.ps1`.
