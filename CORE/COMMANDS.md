# Commands

Run commands from the repository root.

## Install and runtime

```powershell
scripts\bootstrap.ps1
scripts\first-load-bootstrap.ps1 -Json
scripts\runtime-status.ps1 -Json
scripts\brain.ps1 status -Json
```

## Memory and continuity

```powershell
scripts\recall-search.ps1 -Query "..." -Json
scripts\memory-eval.ps1 -Json
scripts\session-restore.ps1 -Json
scripts\task-index.ps1 -Json
```

## Verification and maintenance

```powershell
scripts\verify-package.ps1 -PackageOnly
scripts\verify-package.ps1 -Integration
scripts\ci.ps1
scripts\install-ui-regression.ps1 -Json
scripts\release-readiness.ps1 -Json
scripts\maintain.ps1
scripts\maintain.ps1 -ApplySafe
```

## Git privacy

The repository is the direct source and publication root. Review `git status
--short` before staging. Never stage `private-state`, `private-archive`, the
`memory` junction contents, runtime workspace state, credentials, or generated
output. No share/export command exists.

## Maintenance tiers

Use `scripts\script-tiers.ps1` to inspect T0 through T3 actions. For install
backup cleanup run `scripts\cleanup-install-backups.ps1`, then
`scripts\cleanup-install-backups.ps1 -Apply` only after reviewing the preview.
The native Windows skill injector UI is `scripts\install-ui.ps1 -SmokeTest`
or `scripts\install-ui.vbs`; `scripts\brain.bat` opens the console path, and
`scripts\install.bat console` starts the console menu. Keep
`install-backup-*` local and verify entry paths with
`scripts\check-install-ui-paths.ps1`.

For Hybrid Recall and decisions run `scripts\memory-eval.ps1 -Json`,
`scripts\memory-eval-report.ps1`, `scripts\write-decision.ps1 -Adr`, and
`scripts\decision-search.ps1 -AdrOnly`. Optional Commander maintenance
includes `scripts\team-dispatch-check.ps1 -Json`,
`scripts\team-task-new.ps1`, `scripts\team-task-decision.ps1`,
`scripts\team-task-status.ps1`, `scripts\team-task-review-gate.ps1`,
`scripts\team-memory-retrieval.ps1`, `scripts\roadmap-manager.ps1`,
`scripts\memory-regression-checker.ps1`, `scripts\task-state-reporter.ps1`,
`scripts\privacy-sentinel.ps1`, `scripts\completion-guard.ps1`,
`scripts\super-brain-dashboard.ps1`, `scripts\auto-continuation.ps1`,
`scripts\status-snapshot-writer.ps1`, `scripts\privacy-hit-locator.ps1`,
`scripts\memory-quality-fixer.ps1`, `scripts\optimize-advisor.ps1`, and
`scripts\lesson-replay.ps1`.
