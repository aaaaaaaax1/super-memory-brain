# Commands

Common Super Memory Brain commands.

## T0 read-only checks

```powershell
scripts\doctor.ps1
scripts\doctor.ps1 -Json
scripts\check-install-ui-paths.ps1
scripts\check-install-ui-paths.ps1 -Json
scripts\maintain.ps1
scripts\summary.ps1
scripts\startup-check.ps1
scripts\skill-sync-check.ps1
scripts\memory-mode.ps1 -Mode Status
scripts\memory-health.ps1
scripts\script-tiers.ps1
scripts\compact-report.ps1
scripts\recall-recent.ps1 -Count 5
scripts\profile-card.ps1 -Refresh -Json
scripts\session-restore.ps1 -Query "继续上次" -Json
scripts\recall-search.ps1 -Query "super-memory-brain" -TopK 3 -MaxTokens 1200 -Layer all -Json
scripts\decision-search.ps1 -Query "super-memory-brain"
scripts\decision-search.ps1 -AdrOnly -Status accepted
scripts\decision-audit.ps1
scripts\memory-eval.ps1 -Json
scripts\roadmap-manager.ps1 -Json
scripts\memory-regression-checker.ps1 -Json
scripts\task-state-reporter.ps1 -Json
scripts\privacy-sentinel.ps1 -Json
scripts\completion-guard.ps1 -Json -AllowPrivacyRisk
scripts\super-brain-dashboard.ps1 -Json
scripts\checkpoint-writer.ps1 -Action Get -Json
scripts\checkpoint-writer.ps1 -Action Start -TaskId task-demo -SessionId sess-demo -CurrentStep "implement recall" -NextAction "continue recall changes" -Json
scripts\checkpoint-writer.ps1 -Action Complete -TaskId task-demo -CurrentStep "done" -NextAction "ready for verification" -Json
scripts\auto-continuation.ps1 -Json
scripts\status-snapshot-writer.ps1 -Summary "checkpoint" -NextAction "continue from dashboard" -Json
scripts\privacy-hit-locator.ps1 -Json
scripts\memory-quality-fixer.ps1 -Json
scripts\memory-quality-fixer.ps1 -ShowDetails -Json
scripts\optimize-advisor.ps1
scripts\optimize-advisor.ps1 -Json
scripts\lesson-replay.ps1 -Query "install ui" -Json
scripts\team-dispatch-check.ps1 -Json
scripts\team-template-list.ps1 -Json
scripts\team-template-select.ps1 -DispatchLevel review_board -Reason architecture_change,logic_safety_required -Json
scripts\team-task-status.ps1 -Json
scripts\team-task-review-gate.ps1 -Json
scripts\team-memory-retrieval.ps1 -Query "subagent" -TopK 5 -Json
```

## T1 generated state / verification / share copy

```powershell
scripts\ci.ps1
scripts\lint.ps1
scripts\smoke-test.ps1
scripts\state.ps1
scripts\update-state.ps1
scripts\auto-check.ps1
scripts\verify-package.ps1
scripts\verify-package.ps1 -Integration
scripts\prepare-share.ps1
scripts\verify-share.ps1
scripts\memory-eval-report.ps1
scripts\maintain.ps1 -ApplySafe
scripts\release-share.ps1
scripts\team-template-list.ps1 -Json
scripts\team-template-select.ps1 -DispatchLevel review_board -Reason architecture_change,logic_safety_required -Json
scripts\team-task-new.ps1 -Goal "..." -DispatchLevel single_delegate -Json
scripts\team-task-add-delegation.ps1 -TeamTaskId team-YYYYMMDD-HHMMSS -Role code-explorer -Task "..." -Evidence "path:line" -Json
scripts\team-task-decision.ps1 -TeamTaskId team-YYYYMMDD-HHMMSS -Status accepted -Json
scripts\team-task-index.ps1 -Json
```

## T2 controlled mutation, explicit intent required

```powershell
scripts\install.ps1
scripts\install.bat
scripts\install.bat console
scripts\install-ui.ps1 -SmokeTest
scripts\install-ui.vbs
scripts\install-menu.ps1
scripts\install-agent.ps1 -AgentName <agent-name> -SkillRoot <path-to-skills>
scripts\hot-refresh-skills.ps1 -AllKnown
scripts\memory-mode.ps1 -Mode Shared
scripts\memory-mode.ps1 -Mode SplitMemory
scripts\memory-mode.ps1 -Mode Agent -AgentName <agent-name>
scripts\memory-mode.ps1 -Mode Group -GroupName <group-name>
scripts\cleanup-legacy-memory.ps1
scripts\cleanup-install-backups.ps1
scripts\repair-hook.ps1
scripts\write-memory.ps1 -Text "[CURRENT][VERIFIED] ..." -Layer project -Summary
scripts\learn-memory.ps1 -Text "..." -Layer project -Preview -Json
scripts\learn-memory.ps1 -Text "..." -Layer project -Tags "[PROJECT]" -Json
scripts\write-decision.ps1 -Question "..." -Decision "..." -Key "..."
scripts\write-decision.ps1 -Adr -Question "..." -Title "..." -Decision "..." -Context "..." -Consequences "..." -Scope "..."
scripts\graph-add.ps1
scripts\encoding-check.ps1 -Fix
scripts\graph-normalize.ps1 -Fix
scripts\compact-apply.ps1 -Force
```

## T3 high impact / manual only

```powershell
scripts\bootstrap.ps1
scripts\maintain.ps1 -ApplyConfirmed
scripts\release-private.ps1
scripts\backup-retention.ps1 -Apply
scripts\cleanup-legacy-memory.ps1 -Apply
scripts\cleanup-install-backups.ps1 -Apply
```

## Notes

- Use `scripts\recall-search.ps1 -Query "..." -Json` to get token-budgeted Hybrid Recall results with `evidenceCard` objects for compact prompt injection.
- Use `scripts\brain.bat` to double-click open the Super Brain 控制台; the first tab aggregates status, natural-language intent, next action, release checks, no-memory share release, Agent scorecards, dispatch learning, full CI, and hot refresh.
- Use `scripts\install.bat` for the Chinese native Windows skill injector UI; use `scripts\install.bat console` for the console fallback injector.
- The UI focuses on global ZCode/Codex injection, hot-refreshing already installed Agent skill copies/root markers/memory runtime after brain changes, custom Agent `skills` directory injection, `memory\merge-overlay` / `memory\merge-overlay\memory` old-memory merge/overwrite import, default no-memory share package generation with optional private memory package checkbox, and preview-first `install-backup-*` cleanup; default injected memory is global shared memory.
- Default stability check: `scripts\ci.ps1`; it now includes Memory Eval Harness reporting.
- Prefer T0 scripts for normal checks, especially `scripts\memory-eval.ps1 -Json` for recall/decision quality checks.
- T2/T3 scripts can modify memory, hooks, installed skills, backups, or private packages.
- Commander team tasks use `team-dispatch-check.ps1` for read-only Level 0-3 dispatch scoring and private `team-task-*` workspace records for evidence-gated subagent collaboration.
- Agent/subagent roadmap state is durable memory: `0.5.20` Agent Team templates, `0.5.21` code-capable authorization, `0.5.22` Drift Guard + Commander Review Gate, and `0.5.23` Team Memory Retrieval; update the roadmap ADR whenever the route advances.
- Use `scripts\team-task-review-gate.ps1 -Json` to verify code-capable tasks cannot pass with missing authorization, unreviewed changes, drift guard failures, unfinished Commander decisions, or pending verification.
- Use `scripts\team-memory-retrieval.ps1 -Query "..." -Json` to recall team-task progress, evidence, decisions, and remaining work from private workspace records.
- Use `scripts\dispatch-learning.ps1 -Json` to summarize team-task history into dispatch recommendations, and `scripts\trigger-simulation.ps1 -Json` to verify common prompt scenarios route to expected dispatch levels/templates.
- Use `scripts\brain.ps1 status`, `scripts\brain.ps1 next 继续`, `scripts\brain.ps1 optimize`, and `scripts\brain.ps1 release` as the unified Super Brain command surface.
- Use `scripts\version-bump.ps1 -Version 0.5.37 -Summary "..." -Json` for dry-run version bump previews; add `-Apply` only when ready to write version files.
- Use `scripts\intent-router.ps1 继续 -Json`, `scripts\smart-next.ps1 继续 -Json`, and `scripts\health-summary.ps1 -Json` as practical Super Brain entrances for intent, next action, and current readiness.
- Use `scripts\agent-scorecard.ps1 -Json` to inspect Agent Team suitability and `scripts\release-readiness.ps1 -Json` before sharing packages externally.
- Agent Team templates live in private `memory\workspace\agent-teams.json`; template scripts select role sets only and do not grant code-write permission.
- Future code-capable subagents require explicit Commander authorization, file boundaries, verification commands, rollback notes, and drift-guard review.
- Use `scripts\script-tiers.ps1` for the authoritative script safety view from `manifest.json`.
