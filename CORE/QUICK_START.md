# Quick Start

This repository is the current Super Memory Brain source and direct Git root.
There is no share-package generation step.

## Install

```powershell
scripts\bootstrap.ps1
scripts\first-load-bootstrap.ps1 -Json
```

After installation, the single static `super-memory-brain` MCP entry can be
discovered for health checks, but it intentionally has no user scope. A host
that needs governed local work must launch one process per project scope with
the package adapter in `references/local-mcp-adapter.md`; never put a session
id in MCP arguments or persistent configuration.

## Daily checks

```powershell
scripts\brain.ps1 status -Json
scripts\brain.ps1 next 继续 -Json
scripts\memory-eval.ps1 -Json
scripts\release-readiness.ps1 -Json
```

For maintenance, use `scripts\doctor.ps1`, `scripts\summary.ps1`,
`scripts\startup-check.ps1`, `scripts\skill-sync-check.ps1`,
`scripts\memory-mode.ps1`, and `scripts\memory-health.ps1`. Review install
backups in dry-run mode before cleanup. The UI routes are
`scripts\install-ui.vbs` and `scripts\install.bat console`; the single
active memory root is private-state/shared. The installer can show child
script logs. Use `scripts\check-install-ui-paths.ps1` for its path gate.
Super Brain uses H7 `brain_turn` and does not install P7/Hook. Optional
Commander controls start with `team-dispatch-check.ps1`. Hybrid Recall and
ADR maintenance use `memory-eval.ps1`, `last-memory-eval.json`, and
`decision-search.ps1 -AdrOnly`.

## Local Git privacy

Commit the source tree directly. Keep these local-only paths ignored:

```text
private-state\
private-archive\
memory\
runtime\state\workspace\
output\
ui\node_modules\
**\__pycache__\
*.pyc
```

Do not copy or publish local memory, runtime state, credentials, logs, or
machine-specific configuration. The repository itself is the only distribution
artifact.
