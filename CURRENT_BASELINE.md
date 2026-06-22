# CURRENT_BASELINE

Last Updated: 2026-06-22
Status: [CURRENT][VERIFIED]
Package Version: 0.5.43

## Current State

super-memory-brain-package is the active distributable Super Memory Brain package.

Package path:

``text
<package-root>
``

Package-local active shared memory root:

``text
<package-root>\memory\shared
``

Main active memory file:

``text
<package-root>\memory\shared\sandglass.txt
``

## Active Architecture

``text
super-memory-brain
- skill-orchestrator                 # ORC / Super Brain / routing
- plusunm-g1                         # G1 / memory governance
- nexsandglass-dedicated-memory      # NexSandglass / local deep memory
``

## Active Memory Policy

``text
G1 governs memory; ORC routes only when needed; Sandglass stores stable state only and Hybrid Recall retrieves Sandglass + graph + state + recent evidence only on semantic/keyword recall; memory:auto is default; private memory requires confirmation and [PRIVACY].
``

## Verified Capabilities

- [VERIFIED] Super Brain slimming safety invariant is active: optimization must not damage overall function, remove capability chains, or introduce logic/function breakpoints.
- [VERIFIED] Commander Team Memory is explicit-only from the public entry; normal Super Brain wake/status/recall/learn/session-restore automatic triggers remain active, but team templates, team-task state, and dispatch scoring stay unloaded until explicit team/subagent/review_board/code-capable approval.
- [VERIFIED] Script inventory remains complete in `manifest.scripts`, while `manifest.scriptGroups` and `script-tiers.ps1` provide compact grouped views without breaking verification.
- [VERIFIED] Memory index defaults are slimmer through smaller evidence cards, profile cards, session restore previews, and state/experience/persona snippets while preserving state/graph/Sandglass/recent/persona recall sources.

- [VERIFIED] Installed ZCode/Codex skill directories use `package-root.txt` to point to the current dynamic package root.
- [VERIFIED] Installed ZCode/Codex skill directories use `memory-root.txt` to point to the active memory root.
- [VERIFIED] All supported agents use hot-loadable root markers: `package-root.txt` and `memory-root.txt` can be changed without rewriting installed skill bodies; the next skill load reads the current package and memory root.
- [VERIFIED] Default global shared memory is `<package-root>\memory\shared`; split/private agent memory uses `<package-root>\memory\agents\<agent-name>` only after explicit user intent; custom group memory uses `<package-root>\memory\groups\<group-name>`.
- [VERIFIED] `memory\workspace\memory-sharing-policy.json` tracks the active memory root; default installs initialize it to shared memory to keep global behavior consistent.
- [VERIFIED] Unknown agents can install with `install-agent.ps1` by providing `-AgentName` and `-SkillRoot`, then `memory-root.txt` points to the chosen scoped root.
- [VERIFIED] `migrate-memory-layout.ps1` merges old memory + new memory safely: `memory\merge-overlay` is the UI import folder, common nested `memory\merge-overlay\memory` imports are auto-detected, missing legacy items are copied, existing text memory files append legacy content under `MIGRATED_LEGACY_MEMORY`, overwrite mode replaces same-name files without deleting unrelated new files, successful UI imports clean the import folder, and legacy roots are never deleted by default.

- [VERIFIED] Recall/status/version/progress questions must load `super-memory-brain` first in read-only mode before file search.
- [VERIFIED] Startup hook injection explicitly routes recall/status trigger questions to `Skill super-memory-brain` first.
- [VERIFIED] status.ps1 checks the mandatory skill-load hook rule and exits success explicitly when OK.
- [VERIFIED] ci.ps1 isolates child script exits and writes `memory\workspace\last-ci.json` even when a step fails.
- [VERIFIED] Hook path discovery scans installed Superpowers plugin versions and avoids hardcoded `5.1.0` dependency.
- [VERIFIED] common.ps1 centralizes hook discovery, runtime file inventory, and UTF-8 no BOM writes.
- [VERIFIED] manifest.json owns the NexSandglass runtime file inventory.
- [VERIFIED] test-pester.ps1 runs Pester tests when installed and skips cleanly otherwise.
- [VERIFIED] ci.ps1 is the default stability entrypoint and writes `memory\workspace\last-ci.json`.
- [VERIFIED] ci.ps1 provides one-command local stability checks for install-ready behavior.
- [VERIFIED] task-verification.ps1 writes `memory\workspace\last-task-verification.json` from recent verify/release/hot-refresh status, doctor risk summaries, team-task evidence, explicit evidence, and next-step fields for completion handoff; non-positional parameter binding prevents unnamed array values from silently shifting into later fields.
- [VERIFIED] smoke-test.ps1 restores `memory\workspace\memory-sharing-policy.json` after temporary install checks so `.tmp-smoke-test` memory roots do not leak into later verification.
- [VERIFIED] Regression guards cover task-verification non-positional binding and smoke-test memory-sharing policy restoration through Pester tests and verify-package static checks.
- [VERIFIED] lint.ps1 parses all PowerShell scripts and uses PSScriptAnalyzer when available.
- [VERIFIED] smoke-test.ps1 verifies temporary install, health check, status JSON, and Python memory runtime.
- [VERIFIED] `install.bat` opens the native Windows WinForms skill injector UI by default and supports `install.bat console` for the console fallback injector.
- [VERIFIED] `install-ui.vbs` launches the skill injector UI without a console window.
- [VERIFIED] `install-ui.ps1 -SmokeTest` verifies UI dependencies, action script mapping, and inline no-memory share release markers without showing the interactive UI.
- [VERIFIED] `install-ui.ps1` generates no-memory share packages inline from the UI process, writes `last-release.json`, updates the status panel, and avoids child PowerShell lifecycle exits.
- [VERIFIED] `install-ui.ps1` focuses on global ZCode/Codex skill injection, proactive hot-refreshing of already installed Agent skill copies/root markers/memory runtime after brain changes, custom Agent `skills` directory injection, `memory\merge-overlay` old-memory merge/overwrite import, default no-memory share package generation with optional private memory package checkbox, and preview-first `install-backup-*` cleanup while disabling action controls during long-running scripts.
- [VERIFIED] install.ps1 backs up existing skills and rolls back on failure.
- [VERIFIED] prepare-share.ps1 protects share destinations with path guards and share marker checks.
- [VERIFIED] verify-share.ps1 scans share packages for private globs and sensitive text patterns.
- [VERIFIED] verify-package.ps1 supports -Integration, -WithShareBuild, and -WithTempInstall for explicit heavy validation.
- [VERIFIED] maintain.ps1 -ApplyConfirmed and bootstrap.ps1 use full integration verification.
- [VERIFIED] Startup hook includes Default Super Brain startup rule.
- [VERIFIED] Startup hook includes Memory shortcut.
- [VERIFIED] Startup hook includes Recall trigger.
- [VERIFIED] Startup hook includes Startup auto-check rule.
- [VERIFIED] install.ps1 refreshes the real session-start hook with the current package path during installation.
- [VERIFIED] Startup hook remains lightweight and does not run heavy checks on every new session.
- [VERIFIED] session-start injection is compressed to a minimal Super Brain rule.
- [VERIFIED] `memory\workspace\super-brain-state.json` provides a lightweight state cache whose overall health now requires both hook readiness and successful package verification.
- [VERIFIED] auto-check.ps1 uses the lightweight state cache first only when `lastVerifyOk=true`; stale or failed verification forces a fresh package check.
- [VERIFIED] recall-search.ps1 and recall-recent.ps1 emit UTF-8 JSON-friendly output.
- [VERIFIED] compact-report.ps1 reports exact duplicate memory entries safely.
- [VERIFIED] maintain.ps1 provides a centralized maintenance entrypoint with read-only plan mode.
- [VERIFIED] maintain.ps1 -ApplySafe performs low-risk maintenance without deleting memory/backups or reinstalling skills.
- [VERIFIED] maintain.ps1 -ApplyConfirmed groups explicit high-impact maintenance behind a manual confirmation switch.
- [VERIFIED] doctor.ps1 provides a read-only aggregate diagnostic entrypoint with structured risk aggregation, recent verify/release/hot-refresh/CI/eval/task-verification/team-task summaries, Agent Team template health, and experience index counts.
- [VERIFIED] Commander Agent Teams uses evidence-gated Level 0-3 dispatch without replacing ORC/G1/NexSandglass behavior.
- [VERIFIED] Commander Team Memory and code-capable subagent authorization remain available, but subagent/team routing is off the cold-start path and runs only for explicit subagent/team/review-board requests or evidence-backed broad/high-risk work.
- [VERIFIED] Cold start, simple `继续`, direct answers, status checks, and memory recall keep the lightweight ORC/G1 flow without loading Agent Team templates, team-task state, or dispatch scoring by default.
- [VERIFIED] Agent Team templates live in private `memory\workspace\agent-teams.json` and map dispatch reasons to Explore Team, Review Team, Release Team, or Solo Delegate role sets.
- [VERIFIED] team-template-list.ps1 and team-template-select.ps1 expose template inventory and advisory template selection without granting code-write permission.
- [VERIFIED] Code-capable subagents are reserved for future explicit Commander authorization with file boundaries, verification commands, rollback notes, and drift-guard review.
- [VERIFIED] team-task workspace records capture delegation evidence, Commander decisions, verification status, and memory admission decisions.
- [VERIFIED] team-task workspace state remains private workspace state and is excluded from share releases.
- [VERIFIED] team-dispatch-check.ps1 provides read-only Commander dispatch scoring for direct, single_delegate, team_parallel, and review_board levels.
- [VERIFIED] team-task-review-gate.ps1 provides the 0.5.22 Drift Guard + Commander Review Gate: code-capable tasks cannot pass with missing authorization fields, unreviewed changes, drift guard failures, unfinished Commander decisions, or pending verification.
- [VERIFIED] team-memory-retrieval.ps1 provides the 0.5.23 Team Memory Retrieval path over private team-task records with query, scoring, top-k summaries, and optional delegation evidence.
- [VERIFIED] Agent/subagent roadmap state is durable ADR memory: 0.5.20 Agent Team 模板化, 0.5.21 Code-Capable Subagent Authorization, 0.5.22 Drift Guard + Commander Review Gate, and 0.5.23 Team Memory Retrieval; route advancement must update or supersede the roadmap ADR.
- [VERIFIED] roadmap-manager.ps1 provides a route status card from roadmap ADR recall, CURRENT_BASELINE, team-task status, and last task verification.
- [VERIFIED] memory-regression-checker.ps1 verifies critical recall cases for the agent/subagent roadmap, 0.5.23 route recall, team memory retrieval, and G1 display rule.
- [VERIFIED] task-state-reporter.ps1 reports current version, verification status, hot refresh, roadmap completion, remaining route work, and review gate blockers.
- [VERIFIED] privacy-sentinel.ps1 reports memory-health private-pattern risk before sharing and never deletes memory automatically.
- [VERIFIED] completion-guard.ps1 aggregates package verification, hot refresh, task verification, roadmap recall, memory regression, task state, review gate, and privacy sentinel status.
- [VERIFIED] super-brain-dashboard.ps1 provides the unified state control dashboard for version, roadmap, task, verification, hot refresh, memory regression, privacy, review gate, risks, and next action.
- [VERIFIED] auto-continuation.ps1 provides the `继续` next-action advisor from dashboard state, last task verification, blockers, and last status snapshot.
- [VERIFIED] status-snapshot-writer.ps1 writes memory/workspace/last-status-snapshot.json as a durable continuation checkpoint.
- [VERIFIED] privacy-hit-locator.ps1 locates private-pattern hits by file, line, pattern, preview, and likely false-positive hints.
- [VERIFIED] memory-quality-fixer.ps1 provides WhatIf-only cleanup actions for untagged lines, too-long memories, and malformed decision particles.
- [VERIFIED] lesson-replay.ps1 recalls matching experience-index lessons before repeated repairs or direction changes.
- [VERIFIED] brain.ps1 provides a unified Super Brain command for status, next action, intent classification, release readiness, Agent scorecards, dispatch learning, CI hints, and help.
- [VERIFIED] version-bump.ps1 previews version updates by default and only updates manifest, changelog, baseline, history, and graph lineage when explicitly run with -Apply.
- [VERIFIED] intent-router.ps1 classifies common user requests into continuation, status, fixes, features, release, memory recall, and team/review intents with recommended actions.
- [VERIFIED] smart-next.ps1 combines intent routing, dashboard state, auto-continuation, and dispatch learning into a single next-action advisor.
- [VERIFIED] health-summary.ps1 provides a compact human-readable readiness summary backed by dashboard and doctor diagnostics.
- [VERIFIED] agent-scorecard.ps1 scores Agent Team templates from private team-task history, verified rates, usage, risk counters, and recommendations.
- [VERIFIED] task-retrospective.ps1 writes memory/workspace/last-retrospective.json with concise post-task lessons and evidence.
- [VERIFIED] release-readiness.ps1 checks current package verification, full CI, hot refresh, privacy, and share package freshness before external sharing.
- [VERIFIED] dispatch-learning.ps1 summarizes private team-task history into template stats, blocked-task counters, and routing recommendations for smarter autonomous dispatch.
- [VERIFIED] trigger-simulation.ps1 verifies common continuation, search, release, architecture, and memory-sensitive prompts route to expected dispatch levels and templates.
- [VERIFIED] ci.ps1 explicitly runs dashboard, auto-continuation, completion guard, memory quality WhatIf, lesson replay, dispatch learning, and trigger simulation checks.
- [VERIFIED] Shared memory quality findings are cleaned: memory-quality-fixer reports actionCount=0 after tagging early package-local memory entries, compressing long summaries/ADR entries, and normalizing the malformed v0.4.3 decision particle.
- [VERIFIED] Experience index now includes reusable lessons for G1 display contract, roadmap memory regression, state-control continuation, and privacy/quality WhatIf cleanup.
- [VERIFIED] team-task-status.ps1 and team-task-index.ps1 provide private workspace collaboration status without exposing raw private memory.
- [VERIFIED] check-install-ui-paths.ps1 provides a read-only UI path preflight for package roots, required UI scripts, workspace paths, merge-overlay, and common Agent skills directories.
- [VERIFIED] QUICK_START.md provides one-page install/status/share guidance.
- [VERIFIED] COMMANDS.md provides a tiered command index for common operations.
- [VERIFIED] summary.ps1 provides a compact read-only Super Brain status summary.
- [VERIFIED] script-tiers.ps1 displays manifest script safety tiers without running maintenance actions.
- [VERIFIED] memory-health.ps1 reports memory health counts without printing raw memories by default.
- [VERIFIED] manifest.json is the single source of truth for public script inventory.
- [VERIFIED] scriptMetadata classifies scripts into T0/T1/T2/T3 safety tiers.
- [VERIFIED] verify-package.ps1 checks script inventory consistency and safety-tier metadata.
- [VERIFIED] prepare-share.ps1 creates a slim share package with manifest-driven scripts and curated vendor runtime files.
- [VERIFIED] verify-share.ps1 rejects private memory/state files, internal helper leaks, extra scripts, and vendor bloat.
- [VERIFIED] repair-hook.ps1 and startup-check.ps1 guard startup hook injection length so startup stays lightweight.
- [VERIFIED] `super-memory-brain` entry skill enforces START response discipline silently by default: scope, think, act, report, and track completion status.
- [VERIFIED] When the Super Brain path is active, final responses start with a standalone `G1` line unless strict-format output would be polluted; interim progress updates do not repeat `G1`.
- [VERIFIED] Logic breakpoint recovery restores current step, completed work, next action, and blockers after interruption or `继续` before continuing execution.
- [VERIFIED] Task-completion responses explicitly say when work is complete; unfinished work reports done items, remaining items, and blockers.
- [VERIFIED] `cleanup-install-backups.ps1` reports install backup cleanup candidates by default and deletes only with explicit `-Apply`.
- [VERIFIED] `install-menu.ps1` exposes install backup cleanup with a dry-run preview before requiring `DELETE` confirmation.
- [VERIFIED] backup-retention.ps1 reports backup cleanup candidates by default and applies pruning only with explicit -Apply.
- [VERIFIED] compact-apply.ps1 requires explicit -Force before modifying memory when exact duplicates exist.
- [VERIFIED] compact-apply.ps1 supports dry-run and backups before removing exact duplicate memory entries.
- [VERIFIED] recall-search.ps1 and recall-recent.ps1 provide stable memory lookup helpers.
- [VERIFIED] skill-sync-check.ps1 verifies installed ZCode/Codex skill copies match the package.
- [VERIFIED] repair-hook.ps1 self-heals hook content after plugin updates or path moves.
- [VERIFIED] encoding-check.ps1 detects mojibake in memory/package text files.
- [VERIFIED] graph-normalize.ps1 keeps only the current version marked [CURRENT][VERIFIED].
- [VERIFIED] Short memory router is always-on while full memory injection stays off by default.
- [VERIFIED] memory-policy.json defines memory:auto/force/off modes, profile/project/decision/task/session layers, summary-first retrieval, top_k=3, max_tokens=1200, expiry windows, and negative feedback rules.
- [VERIFIED] write-memory.ps1 supports MemoryMode, Layer, Summary, ExpiresAt, and negative feedback tagging while preserving privacy confirmation.
- [VERIFIED] write-experience.ps1 writes structured reusable lessons, maintains `experience-index.md`, and keeps experience details separate from hard rules.
- [VERIFIED] `recall-search.ps1` supports TopK, MaxTokens, Layer, MemoryMode, and summary-first retrieval while keeping -Limit compatibility.
- [VERIFIED] `recall-search.ps1` can surface concise experience-index candidates from `memory\workspace\experience-index.md` and structured `memory\workspace\experiences\*.json` entries when symptoms or triggers match.
- [VERIFIED] recall-search.ps1 now implements Hybrid Recall across Sandglass, graph, state anchors, and recent fallback, returning sourceType, score, confidence, reason, and tokenEstimate.
- [VERIFIED] memory-policy.json defines Hybrid Recall source weights, boosts, penalties, confidence gates, and state triggers.
- [VERIFIED] decision-search.ps1 supports TopK and MaxTokens budgets for current-first decision graph retrieval.
- [VERIFIED] write-decision.ps1 supports ADR fields: Title, Status, Context, Consequences, Alternatives, Owner, Scope, Tags, and Supersedes.
- [VERIFIED] decision-search.ps1 supports AdrOnly, Status, Owner, Scope, and superseded filtering for ADR retrieval.
- [VERIFIED] decision-audit.ps1 reports ADR schema gaps, invalid statuses, supersedes issues, current conflicts, and superseded counts.
- [VERIFIED] memory-health.ps1 reports layerCounts, summaryCount, negativeFeedbackCount, expiresCount, expiredCount, and invalidExpiryCount without raw memory output.
- [VERIFIED] memory-health.ps1 includes ADR graph, subject, current, superseded, and memory counters without printing raw memories.
- [VERIFIED] memory-eval.ps1 provides a read-only Memory Eval Harness for static, Hybrid Recall, and decision/ADR cases.
- [VERIFIED] memory-eval-report.ps1 writes `memory\workspace\last-memory-eval.json` for auditability, and ci.ps1 includes this step.
- [VERIFIED] repair-hook.ps1 injects a shorter stable startup prefix with memory:auto, G1 governs, ORC routes, and Sandglass semantic/keyword recall.
- [VERIFIED] startup-check.ps1 and status.ps1 verify the short router prefix and startup rule length.
- [VERIFIED] skill-orchestrator uses threshold-based Plan Mode, Explore Agent, and tool calls instead of loading every plausible skill body.
- [VERIFIED] verify-package.ps1 checks memory policy schema, router budget scripts, short startup router checks, and memory-health layer/expiry/feedback counters.
- [VERIFIED] write-decision.ps1 records structured decision particles, governed Sandglass memory, and graph decision edges.
- [VERIFIED] decision-search.ps1 provides read-only current-first decision graph retrieval.
- [VERIFIED] decision-audit.ps1 reports graph parse errors, decision current conflicts, unverified decision edges, and particle format anomalies.
- [VERIFIED] memory-health.ps1 includes decision memory, graph, particle, graph parse, and current-conflict counts without printing raw memories.
- [VERIFIED] graph-search.ps1 supports JSON output, relation filtering, current-only filtering, and stale inclusion controls.
- [VERIFIED] graph-normalize.ps1 reports decision current conflicts while preserving version CURRENT normalization.
- [VERIFIED] verify-package.ps1 checks structured decision lifecycle scripts, graph JSONL parsing, decision audit JSON, and decision search JSON.
- [VERIFIED] bootstrap.ps1, release-private.ps1, and release-share.ps1 provide setup and release entry points.
- [VERIFIED] startup-check.ps1 verifies hook injection, the current package path, and common ZCode/Codex config files.
- [VERIFIED] status.ps1, health-check.ps1, and verify-package.ps1 include startup hook/config readiness checks.
- [VERIFIED] Package-local NexSandglass memory read/write works.
- [VERIFIED] write-memory.ps1 gates low-quality/private memory.
- [VERIFIED] audit-memory.ps1 reports memory health.
- [VERIFIED] prepare-share.ps1 creates a privacy-clean package copy.
- [VERIFIED] verify-package.ps1 checks content, version alignment, mojibake markers, recall order, graph lineage, PowerShell syntax, memory backend access, share cleaning, temporary install, and status JSON.
- [VERIFIED] verify-package.ps1 writes the latest machine-readable result to `memory\workspace\last-verify-package.json`.
- [VERIFIED] auto-check.ps1 reads the latest result or reruns verification automatically when missing, stale, forced, or failed.
- [VERIFIED] verify-share.ps1 confirms share packages exclude private memory files.

## Known Limitations

- [KNOWN_LIMITATION] plusunm-g1 currently works primarily as a skill-policy/governance layer; do not assume `python -m brain_memory` exists. Use package root markers and the PowerShell/NexSandglass script entry points under `scripts/` and `<memory-root>\scripts`.
- [PRIVACY] Do not share memory/ unless intentionally sharing private local memory.

## If Asked What Changed Recently

Answer from this order:

1. memory/workspace/super-brain-state.json for lightweight state when present
2. memory/workspace/last-verify-package.json; if missing/stale/failed, assistant runs scripts/auto-check.ps1 automatically
3. CURRENT_BASELINE.md
4. manifest.json
5. CHANGELOG.md
6. Hybrid Recall via recall-search.ps1 / NexSandglass / graph / state anchors
7. live file verification
