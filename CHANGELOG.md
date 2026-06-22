# Changelog

## 0.5.43

- Hardened `learn-memory.ps1` CLI handling for repeated string-array values by accepting remaining arguments and routing extra `[TAG]` values into tags instead of failing positional binding.
- Added Tool schema discipline to Super Brain and ORC so optional workflow tools such as TodoWrite are not retried with identical invalid arguments after schema validation failures.

## 0.5.42

- Added Super Brain slimming safety invariants: optimization must not damage overall function or introduce logic/function breakpoints.
- Slimmed cold-start routing by making Commander Team Memory explicit-only from the public entry while preserving Super Brain automatic wake/status/recall/learn/session-restore triggers.
- Added compact script groups for script inventory display while keeping the full manifest script truth source intact.
- Reduced default memory evidence-card/session/profile snippet budgets without deleting recall sources or durable memory.

## 0.5.41

- Added preview-first learning with similar-memory duplicate checks to `learn-memory.ps1`, including `-Preview`, `-AllowDuplicate`, and compact similar evidence cards.
- Added `profile-card.ps1` and connected profile-card refresh/restore so user preference/persona recall stays small and token-budgeted.

## 0.5.40

- Added the governed `learn-memory.ps1` protocol for explicit `学一下` / `记住这个` requests, storing compact stable summaries through G1 instead of raw chat.
- Added the token-budgeted `session-restore.ps1` protocol for new-session lightweight restore: state, checkpoint, last snapshot, experience-index preview, and optional evidence cards only when continuity triggers justify recall.

## 0.5.39

- Added token-budgeted recall evidence cards to reduce prompt tokens while preserving judgment evidence.

## 0.5.38

- Added recency-first recall, profile/persona preference recall, and active checkpoint lifecycle state control.

## 0.5.37

- Added unified WinForms Super Brain Console UI, console launchers, and shared-memory provenance checkpoint rules.

## 0.5.36

- Added `brain.ps1` as a unified Super Brain command for status, next action, intent, release readiness, scorecards, dispatch learning, CI hints, and help.
- Added `version-bump.ps1` as a dry-run-first version bump helper for manifest, changelog, baseline, history, and graph lineage updates.

## 0.5.35

- Added intent routing, smart next actions, compact health summaries, Agent Team scorecards, task retrospectives, and release readiness checks.
- These utility entrances make Super Brain status, routing, team choice, release safety, and post-task learning easier to use from one-command workflows.

## 0.5.30

- Added dispatch learning over private team-task history with template stats, blocked-task counters, and routing recommendations.
- Added trigger simulation checks for common continuation, search, release, architecture, and memory-sensitive routing scenarios.
- Extended CI and package verification so dispatch intelligence and trigger routing remain covered by repeatable checks.

## 0.5.29

- Added regression guards for `task-verification.ps1` non-positional binding, `smoke-test.ps1` memory-sharing policy restoration, and `verify-package.ps1` integration temp-install policy restoration.
- Extended package verification so these 0.5.28/0.5.29 safeguards are checked even when Pester is unavailable.

## 0.5.28

- Hardened `task-verification.ps1` with non-positional parameter binding so accidental unnamed array values fail fast instead of shifting into later fields such as `-Risks`.
- Fixed `smoke-test.ps1` to restore `memory\workspace\memory-sharing-policy.json` after temporary install checks, preventing `.tmp-smoke-test` memory roots from leaking into later verification.
- Updated verification docs/baseline metadata for stricter completion handoff and isolated smoke-test state.

## 0.5.27

- Cleaned shared memory quality findings: untagged entries, too-long entries, and malformed decision particle are resolved.
- Expanded the experience index with G1 display, roadmap memory regression, state-control continuation, and privacy/quality WhatIf lessons.

## 0.5.26

- Added privacy hit locator, memory quality WhatIf fixer, and lesson replay over the experience index.
- Compact dashboard text output and explicit CI state-control checks make health findings easier to act on.

## 0.5.25

- Added the state control layer: Super Brain dashboard, auto-continuation advisor, and durable status snapshot writer.
- State and continuation answers can now use one dashboard, one next-action advisor, and one persisted checkpoint instead of reconstructing progress from scattered files.

## 0.5.24

- Added proactive stability helpers: roadmap manager, memory regression checker, task state reporter, privacy sentinel, and completion guard.
- Extended package verification and command docs so critical route/status/privacy/completion checks are first-class and repeatable.

## 0.5.23

- Added Team Memory Retrieval over private team-task records with query, top-k summaries, scoring, and optional delegation evidence.
- Promoted the Agent/subagent roadmap into durable ADR memory so route, current progress, remaining targets, and blockers can be recalled and updated when the route advances.

## 0.5.22

- Added Drift Guard + Commander Review Gate for team-task records to block unfinished Commander decisions, pending verification, missing code-capable authorization fields, unreviewed code-capable changes, and drift guard failures.
- Extended package verification and docs to cover the review gate and team memory retrieval path.

## 0.5.21

- Added code-capable subagent authorization, review, audit, and drift-guard records while keeping subagents unable to edit or apply patches automatically.
- Kept Commander/G1/NexSandglass behavior unchanged and preserved existing team-task/template workflows.
- Moved Commander Team Memory and ORC team dispatch into an on-demand path so cold start, simple `继续`, direct answers, status checks, and memory recall do not load subagent/team routing details by default.

## 0.5.20

- Added private workspace Agent Team templates in `memory\workspace\agent-teams.json`.
- Added `team-template-list.ps1` and `team-template-select.ps1` for template inspection and dispatch-level selection.
- Extended team-task records, index, status, doctor, and verification with template summaries.
- Preserved Commander review and evidence-first constraints; templates cannot bypass ORC/G1/NexSandglass behavior or grant code-write permission.
- Documented the future code-capable subagent authorization model with Commander review and drift-guard supervision.

## 0.5.19

- Added Commander Agent Teams foundation with Level 0-3 dispatch scoring.
- Added private workspace team-task records for task-level subagent collaboration memory.
- Added evidence-first delegation reports and Commander adoption/rejection decisions to prevent fabricated code and logic.
- Integrated team-task state with doctor, task verification, package verification, docs, and share privacy checks.
- Preserved existing ORC, G1, NexSandglass, Hybrid Recall, ADR, verify, release, and hot-refresh behavior.

## 0.5.18

- Added structured risk aggregation to `doctor.ps1`, including `riskSummary`, recent CI/eval/task-verification state, and visible `RISK` lines in text mode.
- Added `check-install-ui-paths.ps1` as a read-only preflight for UI package paths, required UI scripts, workspace paths, merge-overlay, and common Agent skills directories.
- Extended `task-verification.ps1` with evidence, next steps, and embedded doctor risk summaries for durable completion handoff.
- Updated manifest, verification, docs, baseline, and command index for the 0.5.18 release checklist.

## 0.5.17

- Added structured reusable experience entries under `memory\workspace\experiences` plus `write-experience.ps1` to maintain `experience-index.md` without turning lessons into hard rules.
- Integrated experience-index recall into `recall-search.ps1` so similar symptoms can surface concise lesson titles and evidence paths.
- Extended `doctor.ps1 -Json` with last verify/release/hot-refresh summaries and experience index counts.
- Added `task-verification.ps1` to write `memory\workspace\last-task-verification.json` from recent verification, release, and hot-refresh status.

## 0.5.16

- Fixed state trust: `auto-check.ps1` now requires `lastVerifyOk=true` before trusting `super-brain-state.json`, and `update-state.ps1` reports overall state health from both hook and package verification.
- Stabilized package verification by replacing the fragile direct `memory recent python` check with the existing `recall-recent.ps1` helper path and clearer failure details.
- Hardened install UI share smoke coverage so `install-ui.ps1 -SmokeTest` checks the inline no-memory share release path markers.
- Kept the successful WinForms share flow: UI no-memory share generation runs inline, writes `last-release.json`, updates the status panel, and avoids child PowerShell lifecycle exits.

## 0.5.15

- Added a `memory\merge-overlay` old-memory import folder and extended `migrate-memory-layout.ps1` with `-ImportRoot`, `-Mode Merge|Overwrite`, and `-CleanupImport`.
- Added a new install UI “记忆导入” page that detects old memory, opens the import folder, runs merge or overwrite after typed confirmation, shows success/failure dialogs, and clears the import folder only after success.
- Updated verification, docs, baseline, manifest, and recall fixtures for the merge-overlay import flow.

## 0.5.14

- Updated `migrate-memory-layout.ps1` with an old memory + new memory merge strategy: copy missing legacy items, append legacy text memory into existing text files with a migration marker, keep newer non-text conflicts, and still never delete legacy roots.
- Added package verification coverage for the migration merge strategy and refreshed version metadata.

## 0.5.13

- Simplified `install-ui.ps1` into a focused Chinese skill injector: global ZCode/Codex injection with shared memory by default, custom Agent `skills` directory injection, and preview-first `install-backup-*` cleanup.
- Updated the Super Brain entry skill so the START discipline is silent-by-default but mandatory for substantive answers, adds a visible `G1` prefix only on final answers when the Super Brain path is active, and restores task position after interruptions before continuing.
- Upgraded `recall-search.ps1` to Hybrid Recall with Sandglass, graph, state-anchor, and recent fallback candidates plus score, confidence, reason, sourceType, and tokenEstimate fields.
- Added ADR decision records through `write-decision.ps1 -Adr`, `decision-search.ps1 -AdrOnly/-Status/-Owner/-Scope`, and expanded `decision-audit.ps1` / `memory-health.ps1` ADR counters.
- Added `memory-eval.ps1` and `memory-eval-report.ps1` with `tests/memory-eval-tests.json`, JSON metrics, CI integration, and `memory\workspace\last-memory-eval.json` reporting.
- Updated manifest, docs, baseline, share verification, and package verification for Hybrid Recall, ADR lifecycle, and Memory Eval Harness.

## 0.5.12

- Added `install-ui.ps1`, a native Windows WinForms installer UI that delegates to existing scripts and keeps typed safety confirmations.
- Added `install-ui.vbs` as a no-console launcher; `install.bat` now opens the UI by default and supports `install.bat console` for the old menu.
- Added UI smoke-test support through `install-ui.ps1 -SmokeTest` and verification coverage for UI scripts.
- Updated docs, manifest, baseline, recall tests, and graph lineage for the UI launcher.

## 0.5.11

- Added `cleanup-install-backups.ps1` to prune older `install-backup-*` folders with dry-run output by default and deletion only with `-Apply`.
- Added the install backup cleanup action to the unified installer cleanup menu with dry-run preview before `DELETE` confirmation.
- Added START-based response discipline to the Super Brain entry skill: scope, think, act, report, and track completion status.
- Updated manifest, baseline, docs, graph lineage, and verification checks for install backup cleanup and response discipline.

## 0.5.10

- Replaced the plain installer BAT with a unified menu launcher for ZCode/Codex installs, auto-detected agents, manual SkillRoot installs, memory scope switching, diagnostics, CI, and cleanup.
- Added auto-detection for common agent skill roots such as ZCode, Codex, Claude, Cursor, Windsurf, Roo/Cline, Continue, Gemini, OpenCode, and Aider.
- Added `cleanup-legacy-memory.ps1` to safely delete only verified migrated `memory-zcode` and `memory-codex` legacy roots after hash comparison.
- Documented marker-based hot loading: installed skills keep lightweight copies while `package-root.txt` and `memory-root.txt` point to the current package and memory root.

## 0.5.9

- Moved active memory roots under `memory\shared`, `memory\agents\<agent-name>`, and `memory\groups\<group-name>` so split/private/group memory stays inside the package memory tree.
- Added `install-agent.ps1` for unknown agents: provide an agent name and skills directory, then the installer writes `package-root.txt` and `memory-root.txt` to the right scoped memory root.
- Added `memory\workspace\memory-sharing-policy.json` and `.memory-scope.json` markers so first-run sharing choices are explicit and shared/group memory writes cannot happen before scope confirmation.
- Added `migrate-memory-layout.ps1` to copy old `memory`, `memory-zcode`, and `memory-codex` roots into the new layout without deleting old data.
- Hardened share verification so `memory\shared`, `memory\agents`, `memory\groups`, scope markers, root markers, and sharing policy do not leak into share packages.

## 0.5.8

- Added installed skill `package-root.txt` and `memory-root.txt` markers so ZCode/Codex entry skills can locate the dynamic package root and active memory root.
- Added `memory-mode.ps1` to switch between shared memory, split ZCode/Codex memory, and per-agent `memory-<agent-name>` roots under the same package.
- Updated install, sync, startup, health, package, and share verification around root markers and prevented marker leakage in share packages.
- Kept `%USERPROFILE%\.neurobase` as legacy fallback only; current installs use package-local memory roots.

## 0.5.7

- Added short always-on memory router policy: `memory:auto`, semantic+keyword recall, summary-first retrieval, top_k=3, and max_tokens=1200.
- Added layered memory policy tags for profile, project, decision, task, session, summaries, and negative feedback.
- Extended `write-memory.ps1`, `recall-search.ps1`, `decision-search.ps1`, and `memory-health.ps1` for memory modes, layers, budgets, expiry metadata, and feedback counters.
- Compressed startup hook injection into a stable short router prefix and updated startup/status/package verification checks.
- Updated ORC/G1/NexSandglass routing docs to use threshold-based Plan Mode, Explore Agent, and tool calls.

## 0.5.6

- Unified decision writes so `write-decision.ps1` now records structured decision particles, governed Sandglass memory, and decision graph edges.
- Added read-only `decision-search.ps1` and `decision-audit.ps1` for structured decision retrieval and audit.
- Extended graph, memory health, and package verification checks to cover decision graph JSON parsing and decision lifecycle consistency.
- Updated manifest, documentation, and baseline files for the new decision lifecycle.

## 0.5.5

- Strengthened recall/status routing: state, version, progress, previous-session, and memory questions must load `super-memory-brain` first in read-only mode.
- Updated startup hook injection so the short startup rule explicitly says to load `Skill super-memory-brain` before answering recall/status questions.
- Verification now checks the entry skill, hook repair script, startup check, and status view for the mandatory skill-load rule.
- `ci.ps1` now isolates child script exits so failures still write `memory\workspace\last-ci.json`.
- `status.ps1` now checks the mandatory skill-load hook rule and exits success explicitly when OK.

## 0.5.4

- Added `common.ps1` shared helpers for hook auto-discovery, runtime file inventory, and UTF-8 no BOM writes.
- Hook path discovery now scans installed Superpowers plugin versions instead of hardcoding `5.1.0`.
- Moved NexSandglass runtime file inventory into `manifest.json`.
- Added Pester test skeleton and `test-pester.ps1`; `ci.ps1` runs it when available.
- `ci.ps1`, `update-state.ps1`, `verify-package.ps1`, and share marker writes now use UTF-8 no BOM helper writes.

## 0.5.3

- Promoted `ci.ps1` as the default stability entrypoint.
- `ci.ps1` now writes machine-readable status to `memory\workspace\last-ci.json`.
- Updated README, QUICK_START, and COMMANDS to make `ci.ps1` the first recommended check.

## 0.5.2

- Added `ci.ps1` as the one-command local stability check.
- Added `lint.ps1` for PowerShell parse checks and optional PSScriptAnalyzer checks.
- Added `smoke-test.ps1` to verify temporary install, health check, status JSON, and Python memory runtime.
- Hardened `install.ps1` with default skill backups, backup pruning, and failure rollback.

## 0.5.1

- Hardened `prepare-share.ps1` with destination path guards and share package marker checks.
- Hardened `verify-share.ps1` with marker validation, privacy glob scans, and sensitive text pattern scans.
- Added `verify-package.ps1 -Integration`, `-WithShareBuild`, and `-WithTempInstall` so default verification avoids heavy share/temp-install integration unless requested.
- Updated `maintain.ps1 -ApplyConfirmed` and `bootstrap.ps1` to use full integration verification.

## 0.5.0

- Added `maintain.ps1` as the centralized maintenance entrypoint.
- `maintain.ps1` defaults to a read-only maintenance plan.
- Added `maintain.ps1 -ApplySafe` for low-risk maintenance: encoding/graph fixes, state cache update, and compaction dry-run.
- Added `maintain.ps1 -ApplyConfirmed` for explicit high-impact maintenance: hook repair, duplicate compaction with backup, backup retention apply, and full verification.
- Verification now enforces `ApplySafe` / `ApplyConfirmed` switch metadata.

## 0.4.9

- Added `doctor.ps1` as a read-only aggregate diagnostic entrypoint.
- Added `QUICK_START.md` for one-page install/status/share guidance.
- Added `COMMANDS.md` as a tiered command index for common operations.
- Included quick docs and doctor diagnostics in package and share verification.

## 0.4.8

- Added `summary.ps1` for compact read-only Super Brain status output.
- Added `script-tiers.ps1` for readable T0/T1/T2/T3 script safety metadata views.
- Added `memory-health.ps1` for read-only memory line, tag, duplicate, length, and private-pattern health counts.
- Integrated the new lightweight JSON views into package verification without adding startup overhead.

## 0.4.7

- Added manifest-driven script inventory checks so public `.ps1` / `.bat` scripts cannot drift from `manifest.json`.
- Added `scriptMetadata` tiers (`T0` to `T3`) to classify read-only, generated-state, controlled-mutation, and high-impact manual scripts.
- Slimmed share package generation: scripts are copied from `manifest.json`, internal Python helpers are excluded, and vendor payload excludes `.git`, zip, demo, cache, and generated files.
- Hardened share verification to reject private memory/state files, extra public scripts, leaked internal helpers, and vendor bloat.

## 0.4.6

- Added `backup-retention.ps1` for dry-run-first pruning of package backups, compact memory backups, and Super Brain hook backups.
- Added hook startup rule length guards to `repair-hook.ps1` and `startup-check.ps1` so startup injection stays short.
- Added an explicit `-Force` guard to `compact-apply.ps1`; bare apply now reports confirmation required instead of modifying memory when duplicates exist.
- Extended package/share verification to cover backup retention, hook length checks, and compact apply confirmation protection.

## 0.4.5

- `auto-check.ps1` now reads `memory\workspace\super-brain-state.json` first and runs full verification only when state is missing, stale, failed, or forced.
- `recall-search.ps1` and `recall-recent.ps1` now emit UTF-8 JSON-friendly output to reduce console mojibake risk.
- Added `compact-report.ps1` for safe duplicate-memory reports.
- Added `compact-apply.ps1` with backup and dry-run support; it only removes exact duplicate memory text, not semantic variants.
- Integrated state-first auto-check and compaction dry-run checks into `verify-package.ps1`.

## 0.4.4

- Compressed `session-start` hook injection to a smaller default Super Brain startup rule.
- Added lightweight state cache via `update-state.ps1`, `state.ps1`, and `memory\workspace\super-brain-state.json`.
- Added recall helpers: `recall-search.ps1` and `recall-recent.ps1`.
- Added `skill-sync-check.ps1` to compare package skills with installed ZCode/Codex copies.
- Integrated state, recall helper, and skill sync checks into `verify-package.ps1` without adding startup overhead.

## 0.4.3

- Kept startup lightweight: the session-start hook injects only a short default Super Brain rule and does not run heavy checks on every startup.
- Added `repair-hook.ps1` for explicit hook self-healing after plugin updates, path moves, or stale hook content.
- Added `encoding-check.ps1` for UTF-8/mojibake checks and safe targeted fixes.
- Added `graph-normalize.ps1` so only the current version keeps `[CURRENT][VERIFIED]` in graph lineage.
- Added `write-decision.ps1` for explicit decision particles without adding startup overhead.
- Added `bootstrap.ps1`, `release-private.ps1`, and `release-share.ps1` for new-machine setup and safer private/share releases.
- Integrated maintenance checks into `verify-package.ps1`, not into the hot startup path.

## 0.4.2

- Enhanced `install.ps1` to automatically refresh the real `session-start` hook with the current package path during installation.
- `startup-check.ps1` now verifies the hook contains the current package path, preventing stale paths after moving the package or installing on another computer.
- This makes package-local memory portable: copy the package, run install, and the startup hook points to the copied package path.

## 0.4.1

- Added `startup-check.ps1` to verify startup hook injection, core skill install paths, package memory root, and common ZCode/Codex config files.
- `status.ps1`, `health-check.ps1`, and `verify-package.ps1` now include startup hook/config readiness checks.
- Updated `session-start` hook so new sessions receive the default `super-memory-brain` startup rule, memory shortcut, recall trigger, and startup auto-check rule.
- Updated the entry skill to require startup/config checks for first-run, continue, state, breakage, and startup questions.

## 0.4.0

- Added `auto-check.ps1` so assistants can read the latest verification result or rerun verification automatically.
- `verify-package.ps1` now writes `memory\workspace\last-verify-package.json` for conversation-readable status.
- Entry skill now requires assistants to auto-check first-run/continue/state questions instead of asking users to run commands.
- Added `release.ps1` for one-command release package generation.
- Release flow runs full package verification before generating a share package.
- Release flow verifies the generated share package before reporting success.
- `prepare-share.ps1` now includes `BASELINE_HISTORY.md` and `tests` in share packages.
- `manifest.json` script list now includes `verify-share.ps1`.
- `verify-share.ps1` now supports `-SkipPrepare` and validates release-critical files.

## 0.3.5

- Integrated recall tests into `verify-package.ps1`.
- Integrated share-package privacy verification into `verify-package.ps1`.
- Integrated temporary install plus `status.ps1 -Json` verification into `verify-package.ps1`.
- Updated graph lineage check to use the current manifest version.

## 0.3.4

- Enhanced `status.ps1` with `-Json` output for automation.
- Added status success/failure exit codes.
- Added `-ZCodeSkills` and `-MemoryRoot` parameters for target-aware status checks.
- Preserved human-readable status output by default.

## 0.3.3

- Enhanced `health-check.ps1` with explicit success/failure exit codes.
- Added `-ZCodeSkills` and `-MemoryRoot` parameters for install-target checks.
- Updated `install.ps1` to pass install targets into post-install health checks.

## 0.3.2

- Added post-install health check to `install.ps1`.
- Added `-SkipVerify` for installs that need to skip automatic verification.
- Install now prints `POST_INSTALL_HEALTH_CHECK_OK` when runtime and installed skills pass health checks.

## 0.3.1

- Enhanced `verify-package.ps1` with content-level checks.
- Added JSON parse checks for `manifest.json`, `memory-policy.json`, and recall tests.
- Added baseline, changelog, README, recall-order, graph-lineage, mojibake-marker, PowerShell syntax, and memory backend checks.
- Updated current baseline to reflect verification hardening.
- Added `verify-share.ps1` to assert share packages do not include private memory files.

## 0.3.0

- Added structured memory layer.
- Added `BASELINE_HISTORY.md` as a versioned state timeline.
- Added `memory/graph.jsonl` plus `graph-add.ps1` / `graph-search.ps1` for relationship edges.
- Added `extract-facts.ps1` for candidate fact extraction.
- Added `test-recall.ps1` for baseline, privacy, and share-path recall checks.
- Added `tag-legacy-memory.ps1` for converting old untagged entries to `[HISTORY]`.
- Added `session-compact.ps1` for short-term workspace compaction.
- Added `memory/workspace/session-notes.md` for compressed working memory.
- Updated `manifest.json` and `README.md` for structured memory and verification flow.

## 0.2.4

- Added `memory-policy.json` as machine-readable governance policy.
- Added `write-memory.ps1` with admission scoring and private-memory confirmation via `-ConfirmPrivate`.
- Added `audit-memory.ps1` for tag counts, untagged entries, long entries, and possible private-pattern hits.
- Added `baseline-update.ps1` to update `CURRENT_BASELINE.md` and write a `[CURRENT][VERIFIED]` memory.
- Added `prepare-share.ps1` to create a privacy-clean package copy without private memory files.
- Added `verify-package.ps1` for full package verification.
- Updated privacy policy: private memories are not forbidden, but require user confirmation and `[PRIVACY]`.

## 0.2.3

- Added `CURRENT_BASELINE.md` as the current-state anchor for new sessions.
- Added current state answer priority: read baseline, manifest, changelog, then search NexSandglass.
- Added memory tags: `[CURRENT]`, `[VERIFIED]`, `[HISTORY]`, `[STALE]`, `[BLOCKER]`, `[KNOWN_LIMITATION]`, `[PRIVACY]`.
- Wrote latest `[CURRENT][VERIFIED]` package memory for v0.2.3.

## 0.2.2

- Added package-local memory root: `super-memory-brain-package\memory`.
- Updated package scripts to use package-local `memory/` by default.
- Migrated existing `.neurobase` memory into package-local `memory/` without deleting the legacy copy.
- Updated entry skill and NexSandglass module docs to explain package-local memory and privacy risk when sharing the package.

## 0.2.1

- Added explicit recall trigger for questions about another session, previous work, progress, accepted rules, Super Brain state, or old decisions.
- Updated `session-start` hook to instruct new conversations to search explicit memory / NexSandglass before answering recall-sensitive questions.
- Updated ORC routing so `另一个会话 / 还记得 / 改到哪 / 超级大脑进度` goes through `plusunm-g1` then `nexsandglass-dedicated-memory`.
- Restored `nexsandglass-dedicated-memory` module after detecting the installed copy had been overwritten by entry-skill content.

## 0.2.0

- Added `super-memory-brain` as a unified entry skill for ORC + G1 + NexSandglass.
- Added startup self-check/status duties to the entry skill.
- Added conflict arbitration, compression, backup, and migration rules.
- Added package scripts:
  - `scripts/status.ps1`
  - `scripts/backup.ps1`
  - `scripts/migrate.ps1`
  - `scripts/compact.ps1`
- Kept the short memory policy:
  - `G1审记，ORC调度，沙漏只存稳态；不存秘密、噪音、猜测、长原文。`

## 0.1.0

- Created the first distributable package.
- Included entry skill, three modules, NexSandglass vendor files, install script, and health check.
