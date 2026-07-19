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
scripts\user-adaptation.ps1 -Action Status -Json
scripts\user-adaptation.ps1 -Action List -Json
scripts\user-adaptation.ps1 -Action Packet -Context coding -Json
scripts\user-adaptation.ps1 -Action Forget -PreferenceId <id> -ConfirmForget -Json
scripts\user-adaptation-observer.ps1 -Mode Preview -TaskId <id> -WorkspaceKey <key> -Signals response_detail=concise -Json
scripts\session-restore.ps1 -Query "继续上次" -Json
scripts\session-restore.ps1 -Query "继续上次" -BindSession -SessionId sess-demo -Json
scripts\session-binding.ps1 -Action Get -Json
scripts\session-binding.ps1 -Action Clear -Json
scripts\recall-search.ps1 -Query "super-memory-brain" -TopK 3 -MaxTokens 1200 -Layer all -Json
scripts\decision-search.ps1 -Query "super-memory-brain"
scripts\decision-search.ps1 -AdrOnly -Status accepted
scripts\decision-audit.ps1
scripts\memory-eval.ps1 -Json
scripts\runtime-status.ps1 -Json
scripts\runtime-eval.ps1 -McpReplay -Json
scripts\verify-extensions.ps1
scripts\roadmap-manager.ps1 -Json
scripts\memory-regression-checker.ps1 -Json
scripts\task-state-reporter.ps1 -Json
scripts\privacy-sentinel.ps1 -Json
scripts\completion-guard.ps1 -Json -AllowPrivacyRisk
scripts\cognitive-enforce.ps1 "开启子agent通道" -Json
scripts\runtime-drift-checkpoint.ps1 -Phase BeforeAct -ObservedAction "open fresh AgentBridge target channel" -Json
scripts\reflection-promotion.ps1 -Mode Preview -TriggerType completed_fix -Summary "verified reusable lesson" -Json
scripts\super-brain-dashboard.ps1 -Json
scripts\checkpoint-writer.ps1 -Action Get -Json
scripts\checkpoint-writer.ps1 -Action Start -TaskId task-demo -SessionId sess-demo -CurrentStep "implement recall" -NextAction "continue recall changes" -Json
scripts\checkpoint-writer.ps1 -Action Complete -TaskId task-demo -CurrentStep "done" -NextAction "ready for verification" -Json
scripts\auto-continuation.ps1 -Json
scripts\status-snapshot-writer.ps1 -Summary "checkpoint" -NextAction "continue from dashboard" -Json
scripts\privacy-hit-locator.ps1 -Json
scripts\memory-quality-fixer.ps1 -Json
scripts\memory-quality-fixer.ps1 -ShowDetails -Json
scripts\workspace-lifecycle-manager.ps1 -Json
scripts\auto-hygiene-runner.ps1 -Json
scripts\self-improvement-queue.ps1 -Action Status -Json
scripts\self-improvement-queue.ps1 -Action Resolve -CandidateId improve-demo -Resolution resolved -ResolutionEvidence "targeted replay passed" -Json
scripts\self-improvement-queue.ps1 -Action Maintain -Json
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
scripts\task-verification.ps1 -TaskId <id> -Summary "verified" -Evidence "test evidence" -AdaptationSignals reasoning_style=evidence_first -AdaptationContext coding -Json
scripts\team-template-list.ps1 -Json
scripts\team-template-select.ps1 -DispatchLevel review_board -Reason architecture_change,logic_safety_required -Json
scripts\team-task-new.ps1 -Goal "..." -DispatchLevel single_delegate -Json
scripts\team-task-add-delegation.ps1 -TeamTaskId team-YYYYMMDD-HHMMSS -Role code-explorer -Task "..." -Evidence "path:line" -Json
scripts\team-task-decision.ps1 -TeamTaskId team-YYYYMMDD-HHMMSS -Status accepted -Json
scripts\team-task-index.ps1 -Json
scripts\agent-bridge-channel.ps1 -Action Open -ChannelId chan-demo -FromAgentId codexid00002 -SessionId codex-session-demo -Alias "子agent" -Json
scripts\agent-bridge-channel.ps1 -Action WaitConnect -ChannelId chan-demo -AgentId codexid00002 -WaitSeconds 120 -PollIntervalSeconds 2 -Json
scripts\agent-bridge-channel.ps1 -Action Connect -ChannelId chan-demo -OperatorAgentId zcodeid00001 -OperatorName "main" -ToAgentId codexid00002 -Alias "子agent" -TargetSession codex-session-demo -Json
scripts\agent-bridge-channel.ps1 -Action Active -Json
scripts\agent-bridge-channel.ps1 -Action SendAndWait -Alias "子agent" -Summary "你好" -WaitSeconds 60 -PollIntervalSeconds 2 -Json
scripts\agent-bridge-channel.ps1 -Action WaitInbox -ChannelId chan-demo -AgentId codexid00002 -SessionId codex-session-demo -WaitSeconds 300 -PollIntervalSeconds 2 -Json
scripts\agent-bridge-channel.ps1 -Action Inbox -ChannelId chan-demo -AgentId codexid00002 -SessionId codex-session-demo -Json
scripts\agent-bridge-channel.ps1 -Action Ack -ChannelId chan-demo -AgentId codexid00002 -MessageId msg-demo -Json
scripts\task-register.ps1 -Platform codex -Agent codex -AgentId codexid00002 -SessionId codex-fast-test-001 -SessionTitle "任务状态快路径测试" -TaskId task-codex-fast-register-test -TaskName "Codex 快速任务登记测试" -Status active -CurrentStep "写入共享任务状态" -NextAction "ZCode 查询任务状态" -Json
scripts\task-index.ps1 -Json
scripts\task-index.ps1 -Table
scripts\task-index.ps1 -Agent codex -Table
scripts\task-index.ps1 -SessionId sess-demo -Table
```

## Agent Bridge natural-language short commands

```text
开启子agent通道
连接子agent通道：chan-xxxx，别名 子agent
向子agent发送信息：你好
读取子agent通道回复
关闭子agent通道
```

`开启子agent通道` is enough in the sub-agent session: it maps to Open → WaitConnect → WaitInbox, reports `waiting_connect` once, treats Open success as a persistent target-mode wait state, and must not auto-close. Only explicit close wording maps to `Close`.

## T2 controlled mutation, explicit intent required

```powershell
scripts\install.ps1
scripts\bootstrap.ps1
scripts\install.ps1 -Extensions karpathy-guidelines,mattpocock-skills
scripts\install.ps1 -PruneBackups -KeepBackups 5
scripts\install-runtime.ps1
scripts\install-runtime.ps1 -Remove
install.bat
scripts\install.bat
scripts\install.bat bootstrap
scripts\install.bat ui
scripts\install.bat console
scripts\install.bat console
scripts\install-ui.ps1 -SmokeTest
scripts\install-ui.vbs
scripts\install-menu.ps1
scripts\install-agent.ps1 -AgentName <agent-name> -SkillRoot <path-to-skills>
scripts\hot-refresh-skills.ps1 -AllKnown
scripts\hot-refresh-skills.ps1 -AllKnown -Extensions karpathy-guidelines,mattpocock-skills
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

- 0.5.73 automatic maintenance uses `maintenance-policy.json`: safe local hygiene can run automatically with evidence/archive, while destructive/private/external/broad/hook-install/global/unclear-risk actions require confirmation.
- After context compression, resume from visible context, compressed summaries/records, checkpoint/status/ledger, and recent tool results before using long-term memory as supplemental evidence.
- Use `scripts\recall-search.ps1 -Query "..." -Json` to get token-budgeted Hybrid Recall results with `evidenceCard` objects for compact prompt injection.
- Use `scripts\brain.bat` to double-click open the Super Brain 控制台; the first tab aggregates status, natural-language intent, next action, release checks, no-memory share release, Agent scorecards, dispatch learning, full CI, and hot refresh.
- Use root `install.bat` for the one-click unified bootstrap; use `install.bat ui` for the Chinese native Windows skill injector UI and `install.bat console` for the console fallback injector.
- The UI focuses on global ZCode/Codex injection, hot-refreshing already installed Agent skill copies/root markers/memory runtime after brain changes, custom Agent `skills` directory injection, `memory\merge-overlay` / `memory\merge-overlay\memory` old-memory merge/overwrite import, default no-memory share package generation with optional private memory package checkbox, and preview-first `install-backup-*` cleanup; default injected memory is global shared memory.
- Default stability check: `scripts\ci.ps1`; it now includes Memory Eval Harness reporting.
- Prefer T0 scripts for normal checks, especially `scripts\memory-eval.ps1 -Json` for recall/decision quality checks.
- T2/T3 scripts can modify memory, hooks, installed skills, backups, or private packages.
- Commander team tasks use `team-dispatch-check.ps1` for read-only Level 0-3 dispatch scoring and private `team-task-*` workspace records for evidence-gated subagent collaboration.
- Agent/subagent roadmap state is durable memory: `0.5.20` Agent Team templates, `0.5.21` code-capable authorization, `0.5.22` Drift Guard + Commander Review Gate, and `0.5.23` Team Memory Retrieval; update the roadmap ADR whenever the route advances.
- Use `scripts\team-task-review-gate.ps1 -Json` to verify code-capable tasks cannot pass with missing authorization, unreviewed changes, drift guard failures, unfinished Commander decisions, or pending verification.
- Use `scripts\team-memory-retrieval.ps1 -Query "..." -Json` to recall team-task progress, evidence, decisions, and remaining work from private workspace records.
- Use `scripts\dispatch-learning.ps1 -Json` to summarize team-task history into dispatch recommendations, `scripts\trigger-simulation.ps1 -Json` to verify common prompt scenarios route to expected dispatch levels/templates, and `scripts\cold-start-audit.ps1 -Json` to prove ordinary continue/casual G1-brain mentions stay on the light path without waking recall/team/full verify.
- Use `scripts\brain.ps1 status`, `scripts\brain.ps1 next 继续`, `scripts\brain.ps1 optimize`, `scripts\brain.ps1 release`, `scripts\brain.ps1 skills`, `scripts\brain.ps1 capability browser-act`, and `scripts\brain.ps1 extensions` as the unified Super Brain command surface.
- Use `scripts\extension-ingest.ps1 -Action List -Json`, `-Action Inspect -Path <dir> -Json`, `-Action Adopt -Path <dir> -ExtensionId <id> -Json`, and `-Action RebuildMap -Json` to list, inspect, adopt, and route extension skills/plugins.
- Use `scripts\extension-capability-map.ps1 -Json` and `scripts\skill-capability-map.ps1 -List -Json` to rebuild or inspect the merged core+extension capability map; this is visibility for ORC routing, not a manual-only skill menu.
- Use `scripts\version-bump.ps1 -Version 0.5.37 -Summary "..." -Json` for dry-run version bump previews; add `-Apply` only when ready to write version files.
- Use `scripts\intent-router.ps1 继续 -Json`, `scripts\smart-next.ps1 继续 -Json`, and `scripts\health-summary.ps1 -Json` as practical Super Brain entrances for intent, next action, and current readiness.
- Use `scripts\agent-scorecard.ps1 -Json` to inspect Agent Team suitability and `scripts\release-readiness.ps1 -Json` before sharing packages externally.
- Agent Team templates live in private `memory\workspace\agent-teams.json`; template scripts select role sets only and do not grant code-write permission.
- Future code-capable subagents require explicit Commander authorization, file boundaries, verification commands, rollback notes, and drift-guard review.
- Use `scripts\script-tiers.ps1` for the authoritative script safety view from `manifest.json`.
- Use `scripts\objective-benchmark.ps1 -Action Plan -Json` to inspect the official paired A/B benchmark protocol. Internal `intelligence-eval.ps1` values are acceptance metrics only; objective claims require official harness artifacts and `objective-benchmark.ps1 -Action Evaluate`.

scripts\goal-route-lock.ps1 -Action Create -AcceptedGoal "accepted goal" -AcceptedRoute "route step" -NonGoals "non-goal" -Json
scripts\route-checkpoint.ps1 -Phase BeforeAct -ObservedAction "next action" -Json
scripts\verified-module-snapshot.ps1 -Action Create -Module "module-name" -VerifiedBehavior "behavior" -Entrypoint "entry" -VerificationCommand "command" -Evidence "evidence" -Json
scripts\integration-parity-check.ps1 -Module "module-name" -CurrentEntrypoint "entry" -ModuleSmokeOk -IntegrationSmokeOk -UserAcceptanceOk -Json
scripts\causal-change-plan.ps1 -Action Create -ObservedProblem "symptom" -RootCause "cause" -KnownFacts "known fact" -ProposedChange "change" -ExpectedOptimization "expected improvement" -VerificationMethod "test/check" -Json
scripts\engineering-decision-gate.ps1 -Action Create -TaskId "task-id" -Problem "problem" -PainPoint "costly failure" -Objective "objective" -Facts "verified fact" -FactEvidence "command/log/file evidence" -RootCauseStatus verified -RootCause "cause" -RootCauseEvidence "evidence" -Constraints "constraint" -Options "option A","option B" -Tradeoffs "A tradeoff","B tradeoff" -Criteria "criterion" -SelectedOption "option A" -ExecutionSteps "step" -StepInputs "input" -StepOutputs "output" -StepAcceptance "acceptance" -StepStopConditions "stop condition" -AcceptanceCriteria "final acceptance" -Risks "residual risk" -Json
