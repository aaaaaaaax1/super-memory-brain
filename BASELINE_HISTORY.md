# BASELINE_HISTORY

## 0.5.79

Date: 2026-07-13
Status: [CURRENT][VERIFIED]
Change:
- Added bounded memory lifecycle with global and per-layer budgets, write admission, expiry-aware hygiene planning, and budget-aware health and optimization signals.
Supersedes: 0.5.78
Rollback: Restore 0.5.78 scripts/docs/manifest/baseline if 0.5.79 changes need to be disabled temporarily.

## 0.5.78

Date: 2026-07-13
Status: [HISTORY][VERIFIED]
Change:
- Added evidence-bounded engineering judgment with FACT/INFERENCE/UNKNOWN grounding, qualified optimality, task-scoped decision and execution gates, and active ORC routing without a new top-level route.
Supersedes: 0.5.77
Rollback: Restore 0.5.77 scripts/docs/manifest/baseline if 0.5.78 changes need to be disabled temporarily.

## 0.5.77

Date: 2026-07-13
Status: [HISTORY][VERIFIED]
Change:
- Harden historical recovery intent routing, relevance-gated recall, and explicit missing-evidence anti-hallucination boundaries.
Supersedes: 0.5.76
Rollback: Restore 0.5.76 scripts/docs/manifest/baseline if 0.5.77 changes need to be disabled temporarily.

## 0.5.76

Date: 2026-07-13
Status: [HISTORY][VERIFIED]
Change:
- Repair health truth synchronization, modern verifier contracts, completion-audit role routing, host sync readiness, ADR integrity, and memory hygiene.
Supersedes: 0.5.75
Rollback: Restore 0.5.75 scripts/docs/manifest/baseline if 0.5.76 changes need to be disabled temporarily.

## 0.5.75

Date: 2026-07-02
Status: [HISTORY][VERIFIED]
Change:
- Added a Super Brain extension/skill ingestion hub with List/Inspect/Adopt/RebuildMap actions.
- Added extension capability map generation and merged core+extension skill list/search/detail views for ORC automatic routing.
- Added `brain.ps1 skills`, `brain.ps1 capability`, and `brain.ps1 extensions` user-facing commands while preserving rules_as_execution_constraints_not_menu_calls.
Supersedes: 0.5.74
Rollback: Restore 0.5.74 scripts/docs/manifest/baseline if extension ingestion or merged capability routing causes regressions.

## 0.5.74

Date: 2026-07-02
Status: [HISTORY][VERIFIED]
Change:
- Closed residual guard risks by making current-task-context freshness explicit, expanding skill capability/completion audit coverage, and requiring real-user-path acceptance metadata before completion claims.
- Completion audit now expects current-task guard, real-user-path verifier, version record keeper, cache freshness checker, and skill proficiency learning coverage in addition to rule/test/review roles.
Supersedes: 0.5.73
Rollback: Restore 0.5.73 scripts, manifest, skill-capability-map, baseline docs, and regression tests if the stricter completion audit blocks valid internal-only work.

## 0.5.73

Date: 2026-06-30
Status: [HISTORY][VERIFIED]
Change:
- Added the five approved automation modules: workspace lifecycle manager, auto hygiene runner, machine-readable maintenance policy, post-task maintenance hook, and self-improvement queue.
- Safe local hygiene is automatic with archive/evidence and verification; destructive/private/external/broad/hook-install/global/unclear-risk actions require confirmation.
- Compaction/resume must prioritize visible context, compressed summaries/records, checkpoints/status/ledger, and recent tool results before long-term memory.
Supersedes: 0.5.72
Rollback: Restore 0.5.72 manifest/scripts/docs/policies/startup bootstrap if automatic maintenance causes regressions.

## 0.5.72

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Added Goal Route Lock, Route Checkpoint, Verified Module Snapshot, Integration Parity Check, procedure expectations, structural causal reasoning, causal-change-plan.ps1, and gap/logic-breakpoint candidate generation.
- Completion and task verification now distinguish module smoke, integration smoke, and user-facing acceptance evidence.
- Structural thinking now records observed problem -> root cause -> known facts/prior changes -> proposed intervention -> expected optimization -> verification method -> residual risk, with RCA / Theory of Change / Systems Thinking / OODA / PDCA / AAR / ADR / anti-overfitting lesson guard concepts absorbed into procedure memory.
Supersedes: 0.5.71
Rollback: Restore 0.5.71 manifest/scripts/docs/tests if route/integration guards need temporary disablement.

## 0.5.71

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Added cognitive enforcement, runtime drift checkpoints, governed reflection promotion, and AgentBridge procedure-card reuse so Super Brain self-learning is an execution-control loop instead of passive storage.
- Reflection promotion remains preview/analyze by default and only applies durable learning through governed memory, experience, or skill-evolution paths after privacy, duplicate, evidence, conflict, and confidence gates.
Supersedes: 0.5.70
Rollback: Restore 0.5.70 scripts, manifest, Super Brain rule wording, baseline docs, and regression tests if cognitive enforcement or reflection promotion must be disabled temporarily.

## 0.5.70

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Added cognitive-preflight as a memory-driven execution-control layer that turns stored/retrieved memory into pre-action constraints, similar-experience reuse, working-memory guidance, and drift guards.
- Documented semantic/episodic/procedural/working memory roles and reflection/lesson promotion after corrections or failures.
Supersedes: 0.5.69
Rollback: Restore 0.5.69 scripts, manifest, Super Brain rule wording, README, baseline, and regression tests if cognitive preflight must be disabled temporarily.

## 0.5.69

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Hardened Agent Bridge short command semantics so `开启子agent通道` opens a local channel in the current controlled target conversation and must not launch a nested agent/worker/explorer/helper/Tesla.
Supersedes: 0.5.68
Rollback: Restore 0.5.68 super-memory-brain/agent-bridge skill wording, common.ps1 bootstrap, smart-next guidance, docs, and tests if no-nested-agent routing needs to be disabled temporarily.

## 0.5.68

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Changed Agent Bridge subordinate idle waits so no-connection/no-message is quiet idle waiting, not blocked/paused/failed/completed.
- Added no-progress-report-required guards to prevent repeated target-mode status chatter while waiting.
Supersedes: 0.5.67
Rollback: Restore 0.5.67 agent-bridge-channel.ps1, smart-next.ps1, skill wording, common.ps1 startup guard, docs, and tests if idle-wait semantics need to be disabled temporarily.

## 0.5.67

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Fixed Agent Bridge channel open so sub-agent short-command `Open` creates a fresh channel by default instead of reusing an old active/last channel.
- Hardened target mode so one received message plus one reply is not treated as Goal/target completion; the sub-agent must keep waiting until explicit close.
Supersedes: 0.5.66
Rollback: Restore 0.5.66 agent-bridge-channel.ps1, Agent Bridge skill wording, common.ps1 startup guard, docs, and tests if fresh-channel/no-goal-completion behavior needs to be disabled temporarily.

## 0.5.66

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Added a hard global startup guard so mixed CJK/non-English phrases containing ASCII `agent` route to Super Brain Agent Bridge instead of host default explorer/worker/default role help.
Supersedes: 0.5.65
Rollback: Restore 0.5.65 common.ps1/startup bootstrap behavior if the hard CJK-agent routing guard needs to be disabled temporarily.

## 0.5.65

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Added Agent Bridge channel trigger phrases to the global Super Memory Brain startup bootstrap so new agent conversations route `开启agent通道` / `开启子agent通道` through Super Brain instead of host default agent role help.
Supersedes: 0.5.64
Rollback: Restore 0.5.64 common.ps1/startup bootstrap behavior if global startup channel routing needs to be disabled temporarily.

## 0.5.64

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Added Agent Bridge short-command protocol and routing so `开启子agent通道` is enough for sub-agent target mode: Open reports `waiting_connect` once, then WaitConnect/WaitInbox keep the channel alive without auto-close.
Supersedes: 0.5.63
Rollback: Restore 0.5.63 intent-router, smart-next, skills, docs, manifest, and tests if short-command routing needs to be disabled temporarily.

## 0.5.63

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Added Agent Bridge subordinate wait-state actions with `WaitConnect`, `WaitInbox`, `waiting_connect`, one-time connected notification, bounded silent message waiting, and no repeated waiting output/no auto-close behavior.
Supersedes: 0.5.62
Rollback: Restore 0.5.62 `agent-bridge-channel.ps1`, manifest, docs, and tests if subordinate wait-state behavior needs to be disabled temporarily.

## 0.5.62

Date: 2026-06-28
Status: [HISTORY][VERIFIED]
Change:
- Upgraded Agent Bridge channel mode with Connect/Active/WaitReply/SendAndWait, remembered active channel alias, bounded reply waiting, and user-close-clears-active behavior for controlled main/sub-agent conversations.
Supersedes: 0.5.61
Rollback: Restore 0.5.61 `agent-bridge-channel.ps1`, manifest, docs, and tests if target-mode active channel behavior needs to be disabled temporarily.

## 0.5.61

Date: 2026-06-27
Status: [HISTORY][VERIFIED]
Change:
- Added isolated Agent Bridge channel conversations with Open/Send/Inbox/Ack/Close/Status so Agent1 can relay to Agent2 target sessions and read replies from the same workspace channel.
Supersedes: 0.5.60
Rollback: Restore 0.5.60 manifest/docs/scripts/tests if shared channel conversations need to be disabled temporarily.

## 0.5.60

Date: 2026-06-27
Status: [HISTORY][VERIFIED]
Change:
- Added `task-register.ps1` lightweight task registration fast path so Codex/ZCode can broadcast shared task status without active checkpoint writes or heavy doctor/verify/hot-refresh/CI flows.
Supersedes: 0.5.59
Rollback: Restore 0.5.59 manifest/docs/scripts/tests if status-only task registration needs to be disabled temporarily.

## 0.5.59

Date: 2026-06-27
Status: [HISTORY][VERIFIED]
Change:
- Added cross-agent/session task identity indexing with shared agent/session/task cards, task-memory links, compact task-status tables, and unknown-not-no-task semantics for unregistered sessions.
Supersedes: 0.5.58
Rollback: Restore 0.5.58 skill/docs/manifest/scripts/tests if shared task identity indexing needs to be disabled temporarily.

## 0.5.58

Date: 2026-06-27
Status: [HISTORY][VERIFIED]
Change:
- Added Agent Bridge dispatch and resilience extras: target-agent/new-session handoff packets, role permission checks, lightweight queue relay, dry-run team-task archival, and clearer host-session cache limitation prompts.
Supersedes: 0.5.57
Rollback: Restore 0.5.57 skill/docs/manifest/scripts/tests if bridge dispatch extras need to be disabled temporarily.

## 0.5.57

Date: 2026-06-26
Status: [HISTORY][VERIFIED]
Change:
- Added isolated Agent Bridge module and script for controlled multi-agent dialogue, task handoff, heartbeat, failover, new-conversation continuation, and Commander-only adoption without default shared-memory pollution.
Supersedes: 0.5.56
Rollback: Restore 0.5.56 skill/docs/manifest/scripts/tests if agent bridge needs to be disabled temporarily.

## 0.5.56

Date: 2026-06-26
Status: [HISTORY][VERIFIED]
Change:
- Added reliable task execution system upgrades: task index/list buckets, scriptable intent gate, recovery E2E validation, detailed step ledger, ranked resume candidates, and host cache freshness checks.
Supersedes: 0.5.55
Rollback: Restore 0.5.55 skill/docs/manifest/scripts/tests if task execution system upgrades need to be disabled temporarily.

## 0.5.55

Date: 2026-06-26
Status: [HISTORY][VERIFIED]
Change:
- Added current-task status and paste-free resume hardening so `任务状态` prioritizes the current conversation task, recovery reads compact anchors instead of requiring pasted old replies, ambiguous resumes ask for a numbered task choice, and ZCode avoids TodoWrite unless explicitly requested.
Supersedes: 0.5.54
Rollback: Restore 0.5.54 skill/docs/manifest/tests if the current-task resume hardening needs to be disabled temporarily.

## 0.5.54

Date: 2026-06-25
Status: [HISTORY][VERIFIED]
Change:
- Added cold-start dominance and output suppression hardening: auto-check no longer runs full verify by default when stale, dashboard has Light/Full/Team modes, smart-next avoids dispatch learning outside team intent, plain continue avoids recall by itself, and Super Brain/ORC rules suppress accidental skill wakeups and verbose output.
Supersedes: 0.5.53
Rollback: Restore 0.5.53 scripts/docs/manifest/baseline if 0.5.54 changes need to be disabled temporarily.

## 0.5.53

Date: 2026-06-25
Status: [HISTORY][VERIFIED]
Change:
- Added CompleteTask/ArchiveTask/ClearTask task lifecycle hardening and archived task workspace records for crash-safe continuation.
- Embedded continuity, impact, and codegraph summaries in status snapshots and task verification; refined dynamic unknown detection through CommandAst.
Supersedes: 0.5.52
Rollback: Restore 0.5.52 scripts/docs/manifest/baseline if crash-resume lifecycle hardening needs to be disabled temporarily.

## 0.5.52

Date: 2026-06-25
Status: [HISTORY][VERIFIED]
Change:
- Upgraded codegraph indexing with dynamic PowerShell call edges and lightweight workspace read/write dataflow.
- Added impact advisor for changed-file risk analysis, affected scripts/workspace files, and recommended verification commands.
Supersedes: 0.5.51
Rollback: Restore 0.5.51 scripts/docs/manifest/baseline if impact advice or codegraph v2 dataflow needs to be disabled temporarily.

## 0.5.51

Date: 2026-06-25
Status: [HISTORY][VERIFIED]
Change:
- Added lightweight PowerShell codegraph indexing for script/function/parameter/call edges and mutation metadata.
- Connected codegraph-index to Project Graph Continuity, verification, Pester regression guards, and CI.
Supersedes: 0.5.50
Rollback: Restore 0.5.50 scripts/docs/manifest/baseline if codegraph indexing needs to be disabled temporarily.

## 0.5.50

Date: 2026-06-25
Status: [HISTORY][VERIFIED]
Change:
- Expanded Project Graph Continuity with task graph state, step-ledger actions, candidate-only agent findings, and Commander admission/rejection controls.
- Strengthened structure baseline rules so open steps and candidate findings remain explicit before completion or formal memory claims.
Supersedes: 0.5.49
Rollback: Restore 0.5.49 scripts/docs/manifest/baseline if task-graph or findings isolation needs to be disabled temporarily.

## 0.5.49

Date: 2026-06-23
Status: [HISTORY][VERIFIED]
Change:
- Added extension smoke/collision/health summary checks and privacy token false-positive regression guards.
- Removed default session-restore snippet tails, reduced default restore evidence to 2 cards, and compacted active checkpoint restore output while preserving automatic recall triggers and Codex/ZCode shared-memory checks.
Supersedes: 0.5.48
Rollback: Restore 0.5.48 scripts/docs/manifest/tests if the expanded health checks need to be disabled.

## 0.5.48

Date: 2026-06-23
Status: [HISTORY][VERIFIED]
Change:
- Added opt-in external extension packs for Karpathy guidelines and curated Matt Pocock skills, plus extension manifest verification.
Supersedes: 0.5.47
Rollback: Restore 0.5.47 scripts/docs/manifest and remove `extensions/` if optional external skill packs need to be disabled.

## 0.5.47

Date: 2026-06-22
Status: [HISTORY][VERIFIED]
Change:
- Added compression-recovery stale guards so continuation prefers fresh status cards/snapshots and rejects old task summaries when version or verify time shows they are stale.
Supersedes: 0.5.46
Rollback: Restore 0.5.46 scripts/docs/manifest/baseline and remove the compression-recovery memory-eval case if the stale-summary guard needs to be disabled temporarily.

## 0.5.46

Date: 2026-06-22
Status: [HISTORY][VERIFIED]
Change:
- Added proactive long-memory compression and experience-learning rules, and compressed the Atoapi horizontal history audit memory while preserving graph/ADR evidence.
Supersedes: 0.5.45
Rollback: Restore 0.5.45 scripts/docs/manifest/baseline and the prior sandglass line if proactive compression/experience rules need to be disabled temporarily.

## 0.5.45

Date: 2026-06-22
Status: [HISTORY][VERIFIED]
Change:
- Added temporary session-binding evidence bundles with TTL, memory:off, version/root/privacy guards, status/doctor visibility, and avoidable-issue prevention rules.
Supersedes: 0.5.44
Rollback: Restore 0.5.44 scripts/docs/manifest/baseline if session binding needs to be disabled temporarily.

## 0.5.44

Date: 2026-06-22
Status: [HISTORY][VERIFIED]
Change:
- Added durable rules for version-iteration before/after comparison, positive/neutral/negative optimization classification, and meticulous detail control for high-quality releases.
Supersedes: 0.5.43
Rollback: Restore 0.5.43 scripts/docs/manifest/baseline if the iteration review/detail-control rules need to be disabled temporarily.

## 0.5.43

Date: 2026-06-22
Status: [HISTORY][VERIFIED]
Change:
- Hardened learn-memory CLI string-array argument handling and added tool schema discipline so invalid optional tool calls are corrected or skipped instead of repeated.
Supersedes: 0.5.42
Rollback: Restore 0.5.42 scripts/docs/manifest/baseline if CLI argument hardening needs to be disabled temporarily.

## 0.5.42

Date: 2026-06-22
Status: [HISTORY][VERIFIED]
Change:
- Added slimming safety invariants, explicit-only Commander Team Memory entry loading, compact script groups, and reduced default recall/profile/session evidence budgets while preserving full capability paths.
Supersedes: 0.5.41
Rollback: Restore 0.5.41 scripts/docs/manifest/baseline if cold-start slimming or explicit-only Commander Team loading needs to be disabled temporarily.

## 0.5.41

Date: 2026-06-21
Status: [HISTORY][VERIFIED]
Change:
- Added preview-first learning, similar-memory duplicate checks, and compact profile-card restore for profile/persona preference recall.
Supersedes: 0.5.40
Rollback: Restore 0.5.40 scripts/docs/manifest/baseline if 0.5.41 changes need to be disabled temporarily.

## 0.5.40

Date: 2026-06-21
Status: [HISTORY][VERIFIED]
Change:
- Added governed learn-memory protocol for explicit learn/remember requests and token-budgeted session-restore protocol for lightweight new-session continuity.
Supersedes: 0.5.39
Rollback: Restore 0.5.39 scripts/docs/manifest/baseline if 0.5.40 changes need to be disabled temporarily.

## 0.5.39

Date: 2026-06-21
Status: [HISTORY][VERIFIED]
Change:
- Added token-budgeted recall evidence cards to reduce prompt tokens while preserving judgment evidence.
Supersedes: 0.5.38
Rollback: Restore 0.5.38 scripts/docs/manifest/baseline if 0.5.39 changes need to be disabled temporarily.

## 0.5.38

Date: 2026-06-21
Status: [HISTORY][VERIFIED]
Change:
- Added recency-first recall, profile/persona preference recall, and active checkpoint lifecycle state control.
Supersedes: 0.5.37
Rollback: Restore 0.5.37 scripts/docs/manifest/baseline if 0.5.38 changes need to be disabled temporarily.

## 0.5.37

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Added unified WinForms Super Brain Console UI, console launchers, and shared-memory provenance checkpoint rules.
Supersedes: 0.5.36
Rollback: Restore 0.5.36 scripts/docs/manifest/baseline if 0.5.37 changes need to be disabled temporarily.

## 0.5.36

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Added brain.ps1 as a unified read-only Super Brain command for status, next action, intent, release readiness, scorecards, dispatch learning, CI hints, and help.
- Added version-bump.ps1 as a dry-run-first version bump helper that updates manifest, changelog, baseline, history, and graph lineage only with -Apply.
Supersedes: 0.5.35
Rollback: Restore 0.5.35 scripts/docs/manifest/baseline if unified command or version-bump helper should be disabled temporarily.

## 0.5.35

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Added intent-router.ps1, smart-next.ps1, health-summary.ps1, agent-scorecard.ps1, task-retrospective.ps1, and release-readiness.ps1.
- Super Brain can now classify common user intents, suggest the next action, summarize health, score Agent Team templates, write concise retrospectives, and check release readiness.
Supersedes: 0.5.30
Rollback: Restore 0.5.30 scripts/docs/manifest/baseline if smart utility entrances should be disabled temporarily.

## 0.5.30

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Added dispatch-learning.ps1 for read-only learning from private team-task history, including template stats, blocked-task counters, and routing recommendations.
- Added trigger-simulation.ps1 to verify common prompts route to expected dispatch levels and templates.
- Extended ci.ps1 and verify-package.ps1 so dispatch intelligence and trigger simulation are covered by repeatable checks.
Supersedes: 0.5.29
Rollback: Restore 0.5.29 scripts/docs/manifest/baseline if dispatch-learning or trigger-simulation checks need to be disabled temporarily.

## 0.5.29

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Added Pester regression guards for task-verification.ps1 non-positional binding, smoke-test.ps1 memory-sharing policy restoration, and verify-package.ps1 integration temp-install policy restoration.
- Extended verify-package.ps1 with static regression checks for the same safeguards so they are covered even when Pester is unavailable.
Supersedes: 0.5.28
Rollback: Restore 0.5.28 tests/scripts/docs/manifest/baseline if the new regression checks need to be disabled temporarily.

## 0.5.28

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Hardened task-verification.ps1 with non-positional parameter binding so accidental unnamed array values fail fast instead of shifting into later fields such as risks.
- Fixed smoke-test.ps1 to restore memory-sharing-policy.json after temporary install checks, preventing .tmp-smoke-test memory roots from leaking into later verification.
- Updated docs/baseline metadata for stricter completion handoff verification and isolated smoke-test state.
Supersedes: 0.5.27
Rollback: Restore 0.5.27 scripts/docs/manifest/baseline if positional task-verification command examples must be preserved temporarily.

## 0.5.27

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Cleaned shared memory quality findings: untagged entries, too-long entries, and malformed decision particle are resolved.
- Expanded experience-index and structured experiences with G1 display contract, roadmap memory regression, state-control continuation, and privacy/quality WhatIf lessons.
Supersedes: 0.5.26
Rollback: Restore 0.5.26 memory/docs/manifest/baseline if the memory quality cleanup or experience additions must be reverted.

## 0.5.26

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Added privacy-hit-locator.ps1, memory-quality-fixer.ps1, and lesson-replay.ps1.
- Dashboard text output is compact, and ci.ps1 explicitly runs dashboard, auto-continuation, completion guard, memory quality WhatIf, and lesson replay checks.
Supersedes: 0.5.25
Rollback: Restore 0.5.25 scripts/docs/manifest/baseline if quality helper checks should be disabled.

## 0.5.25

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Added super-brain-dashboard.ps1, auto-continuation.ps1, and status-snapshot-writer.ps1.
- State control layer centralizes current version, roadmap, verification, hot refresh, task state, memory regression, privacy, review gate, risks, next action, and durable continuation snapshots.
Supersedes: 0.5.24
Rollback: Restore 0.5.24 scripts/docs/manifest/baseline if dashboard/continuation/snapshot control should be disabled.

## 0.5.24

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Added roadmap-manager.ps1, memory-regression-checker.ps1, task-state-reporter.ps1, privacy-sentinel.ps1, and completion-guard.ps1.
- Stability helpers make roadmap state, critical memory recall, task completion state, privacy warnings, and final completion gates repeatable.
Supersedes: 0.5.23
Rollback: Restore 0.5.23 scripts/docs/manifest/baseline if proactive stability helper checks must be disabled.

## 0.5.23

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Team Memory Retrieval added for private team-task records with query, scoring, top-k summaries, and optional delegation evidence.
- Agent/subagent roadmap is stored as durable ADR memory and must be updated or superseded whenever the route advances.
Supersedes: 0.5.22
Rollback: Restore 0.5.22 scripts/docs/manifest/baseline if team memory retrieval or roadmap recall must be disabled.

## 0.5.22

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Drift Guard + Commander Review Gate blocks missing code-capable authorization fields, unreviewed code-capable changes, drift guard failures, unfinished Commander decisions, and pending verification.
- Package verification covers the review gate and Team Memory Retrieval script path.
Supersedes: 0.5.21
Rollback: Restore 0.5.21 scripts/docs/manifest/baseline if the explicit gate must be removed.

## 0.5.21

Date: 2026-06-20
Status: [HISTORY][VERIFIED]
Change:
- Code-capable subagent authorization, review, audit, and drift-guard records are present without granting automatic file editing or patch application.
- Commander Team Memory and ORC team dispatch are gated behind explicit subagent/team/review-board requests or evidence-backed high-risk/broad parallel discovery needs.
- Cold start, simple `继续`, direct answers, status checks, and memory recall keep the lightweight ORC/G1 flow and do not load subagent/team routing details by default.
Supersedes: 0.5.20
Rollback: Restore 0.5.20 skill rules/docs/manifest if code-capable authorization and cold-start gating must be removed.

## 0.5.20

Date: 2026-06-19
Status: [HISTORY][VERIFIED]
Change:
- Agent Team templates added as private workspace configuration.
- Team-task records can attach selected template id/name/roles.
- Doctor and verification now surface template config health.
- Future code-capable subagent authorization is documented as explicit Commander-gated and drift-guarded.
Supersedes: 0.5.19
Rollback: Restore 0.5.19 scripts/docs/manifest and remove template config integration if templates must be disabled.

## 0.5.19

Date: 2026-06-19
Status: [HISTORY][VERIFIED]
Change:
- Commander Team Memory foundation added with dispatch scoring and private team-task workspace records.
- Evidence-first anti-fabrication rules documented for Commander and subagents.
- Team-task status integrated with doctor, task verification, and verify-package.
- Existing ORC, G1, NexSandglass, Hybrid Recall, ADR, verify, release, and hot-refresh behavior remains preserved.
Supersedes: 0.5.18
Rollback: Restore 0.5.18 manifest, skill rules, docs, scripts, and workspace index behavior if Commander Team Memory must be disabled.

## 0.5.18

Date: 2026-06-19
Status: [HISTORY][VERIFIED]
Change:
- `doctor.ps1` now exposes structured risk aggregation with recent verify/release/hot-refresh/CI/eval/task-verification state.
- Added read-only `check-install-ui-paths.ps1` to preflight install UI package paths, required UI scripts, workspace paths, merge-overlay, and Agent skill candidates.
- `task-verification.ps1` now records evidence, next steps, and embedded doctor risk summaries for durable handoff.
- Updated verification, manifest, docs, baseline, and command coverage for the 0.5.18 checklist.
Supersedes: 0.5.17
Rollback: Restore 0.5.17 scripts/docs and remove `check-install-ui-paths.ps1` from the manifest if UI path preflight must be disabled.

## 0.5.17

Date: 2026-06-19
Status: [HISTORY][VERIFIED]
Change:
- Added structured reusable experiences in `memory\workspace\experiences` plus `write-experience.ps1` and a maintained `experience-index.md`.
- `recall-search.ps1` can surface experience-index candidates when symptoms/triggers match.
- `doctor.ps1 -Json` now includes last verify/release/hot-refresh summaries and experience index counts.
- Added `task-verification.ps1` for durable task completion verification summaries.
Supersedes: 0.5.16
Rollback: Restore 0.5.16 scripts/docs and remove `memory\workspace\experiences` only if structured experience indexing must be disabled.

## 0.5.16

Date: 2026-06-19
Status: [HISTORY][VERIFIED]
Change:
- `auto-check.ps1` and `update-state.ps1` now keep `super-brain-state.json` health aligned with `last-verify-package.json` so stale successful state cannot hide failed verification.
- `verify-package.ps1` uses `recall-recent.ps1` for the memory recent check instead of a fragile direct Python snippet.
- `install-ui.ps1 -SmokeTest` checks inline no-memory share release markers, preserving the successful BAT/VBS WinForms share flow.
Supersedes: 0.5.15
Rollback: Restore 0.5.15 scripts and rerun `scripts\update-state.ps1`, `scripts\verify-package.ps1`, and `scripts\hot-refresh-skills.ps1 -AllKnown`.

## 0.5.15

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- `memory\merge-overlay` is now the fixed old-memory import folder for UI-driven merge/overwrite.
- `migrate-memory-layout.ps1` supports `-ImportRoot`, `-Mode Merge|Overwrite`, and `-CleanupImport` while preserving safe dry-run behavior.
- `install-ui.ps1` adds a “记忆导入” page with detection, typed confirmation, success/failure dialogs, and successful-import cleanup.
Supersedes: 0.5.14
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, install backups, package backups, and the original old memory source if import failed before cleanup.

## 0.5.14

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- `migrate-memory-layout.ps1` now uses an old memory + new memory merge strategy: missing legacy items are copied, existing text memory files append legacy content under a migration marker, and non-text conflicts keep the new file.
- Verification now checks that the migration merge strategy stays present.
Supersedes: 0.5.13
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, install backups, package backups, and untouched legacy memory roots.

## 0.5.13

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- `install-ui.ps1` is now a focused Chinese skill injector: one-click global ZCode/Codex injection with shared memory by default, custom Agent `skills` directory injection, and preview-first `install-backup-*` cleanup.
- `super-memory-brain/SKILL.md` now makes START silent-by-default but mandatory for substantive answers.
- `recall-search.ps1` now performs Hybrid Recall across Sandglass, graph, state anchors, and recent fallback with score/confidence/source metadata.
- `write-decision.ps1`, `decision-search.ps1`, and `decision-audit.ps1` now support ADR records with status, context, consequences, alternatives, owner, scope, and supersedes auditing.
- `memory-eval.ps1`, `memory-eval-report.ps1`, and `tests\memory-eval-tests.json` add a read-only Memory Eval Harness plus durable eval reporting.
- Verification, CI, docs, manifest, share checks, and baseline files are aligned with Hybrid Recall + ADR + Eval.
Supersedes: 0.5.12
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, install backups, and package backups; run `scripts\graph-normalize.ps1 -Fix` if version lineage must be restored.

## 0.5.12

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- `install-ui.ps1` adds a native Windows WinForms installer UI while preserving existing backend scripts and typed confirmations.
- `install-ui.vbs` launches the UI without a console window.
- `install.bat` now opens the UI by default and keeps the old console menu through `install.bat console`.
- Verification covers the UI smoke test, script inventory, docs, and share package inclusion.
Supersedes: 0.5.11
Rollback: Use `scripts\install.bat console`, `scripts\install-menu.ps1`, or install/package backups.

## 0.5.11

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- `install-menu.ps1` now exposes install backup cleanup as a two-step dry-run plus explicit delete flow.
- `cleanup-install-backups.ps1` keeps the newest install backups and deletes older `install-backup-*` folders only with `-Apply`.
- `super-memory-brain/SKILL.md` now records the START-based response discipline and completion reporting rule.
- Manifest version advanced to keep install comparisons and verification aligned.
Supersedes: 0.5.10
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, install backups, and package backups.

## 0.5.10

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- `install.bat` now opens a unified menu for ZCode/Codex, auto-detected agents, manual SkillRoot installs, memory mode changes, diagnostics, CI, and cleanup.
- Agent detection covers common local agent skill roots while still allowing manual `AgentName` + `SkillRoot` input.
- `cleanup-legacy-memory.ps1` safely removes migrated `memory-zcode` and `memory-codex` only after exact hash verification.
Supersedes: 0.5.9
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, install backups, and `memory\agents` scoped roots.

## 0.5.9

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Scoped memory roots now live under `memory\shared`, `memory\agents\<agent-name>`, and `memory\groups\<group-name>`.
- Unknown agents can install the same Super Brain package with `install-agent.ps1` and get their own `memory-root.txt` target.
- First-run sharing policy and `.memory-scope.json` markers prevent accidental shared/group memory pollution.
- `migrate-memory-layout.ps1` copies old ZCode/Codex/shared memory into the new layout without deleting legacy roots.
Supersedes: 0.5.8
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, install backups, and legacy memory roots.

## 0.5.8

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Installed ZCode/Codex skills now get dynamic `package-root.txt` and `memory-root.txt` markers.
- Added Shared, SplitMemory, and Agent memory modes while keeping one shared package.
- Agent memory roots default to `memory-<agent-name>` under the current package; `.neurobase` is legacy fallback only.
Supersedes: 0.5.7
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and install backups.

## 0.5.7

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Added short always-on memory router policy with `memory:auto`, semantic+keyword recall, summary-first retrieval, top_k=3, and max_tokens=1200.
- Added memory layers for profile, project, decision, task, session, summaries, and negative feedback using tags instead of new databases.
- Extended write/search/health scripts for memory modes, layer filters, retrieval budgets, expiry metadata, and feedback counters.
- Compressed startup hook injection to a stable short router prefix and aligned ORC/G1/NexSandglass threshold routing docs.
Supersedes: 0.5.6
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and install backups.

## 0.5.6

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Unified decision writes across structured decision particles, governed Sandglass memory, and graph decision edges.
- Added read-only `decision-search.ps1` and `decision-audit.ps1` for current-first decision retrieval and decision lifecycle audit.
- Extended graph search, graph normalization, memory health, and package verification to cover decision graph consistency.
- Updated manifest and docs for the structured decision lifecycle.
Supersedes: 0.5.5
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and install backups.

## 0.5.5

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- State, version, progress, previous-session, and memory questions must load `super-memory-brain` first in read-only mode.
- Startup hook injection explicitly tells assistants to load `Skill super-memory-brain` before recall/status answers.
- Verification checks entry skill, hook scripts, startup check, and status view for this mandatory routing rule.
- CI now records `last-ci.json` even when a child step fails, and status view exits cleanly on success.
Supersedes: 0.5.4
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and install backups.

## 0.5.4

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Added `common.ps1` for hook discovery, runtime inventory, and UTF-8 no BOM writes.
- Hook path discovery now scans installed Superpowers plugin versions instead of relying on a hardcoded version.
- Moved NexSandglass runtime file inventory into `manifest.json`.
- Added Pester test skeleton and `test-pester.ps1`; `ci.ps1` runs it when available.
Supersedes: 0.5.3
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and install backups.

## 0.5.3

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Promoted `ci.ps1` as the default stability entrypoint.
- `ci.ps1` writes machine-readable status to `memory\workspace\last-ci.json`.
- README, QUICK_START, and COMMANDS now recommend `ci.ps1` first.
Supersedes: 0.5.2
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and install backups.

## 0.5.2

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Added `ci.ps1` as one-command local stability check.
- Added `lint.ps1` for syntax lint and optional PSScriptAnalyzer checks.
- Added `smoke-test.ps1` for temporary install and runtime smoke validation.
- Hardened `install.ps1` with backups and rollback on failure.
Supersedes: 0.5.1
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and install backups.

## 0.5.1

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Hardened `prepare-share.ps1` with destination path guards and share marker checks.
- Hardened `verify-share.ps1` with marker, private glob, and sensitive text scans.
- Added explicit integration switches to `verify-package.ps1`.
- Kept full integration verification in `maintain.ps1 -ApplyConfirmed` and `bootstrap.ps1`.
Supersedes: 0.5.0
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.5.0

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Added `maintain.ps1` as a centralized maintenance entrypoint.
- Default maintenance mode is read-only and reports a plan.
- Added `-ApplySafe` for low-risk maintenance.
- Added `-ApplyConfirmed` for explicit high-impact maintenance.
Supersedes: 0.4.9
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.9

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Added read-only `doctor.ps1` aggregate diagnostics.
- Added `QUICK_START.md` for one-page operational guidance.
- Added `COMMANDS.md` as a tiered command index.
- Included quick docs and doctor checks in package/share verification.
Supersedes: 0.4.8
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.8

Date: 2026-06-18
Status: [HISTORY][VERIFIED]
Change:
- Added read-only `summary.ps1` for compact Super Brain status.
- Added read-only `script-tiers.ps1` for T0/T1/T2/T3 script safety views.
- Added read-only `memory-health.ps1` for tag, duplicate, length, and privacy-pattern counts without raw memory output.
- Integrated the new lightweight JSON views into package verification.
Supersedes: 0.4.7
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.7

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added manifest-driven script inventory consistency checks.
- Added script safety tiers and metadata for public and internal helper scripts.
- Slimmed share packages by copying scripts from manifest and curating vendor runtime files.
- Hardened share verification against private state, internal helper leaks, extra scripts, and vendor bloat.
Supersedes: 0.4.6
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.6

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added dry-run-first backup retention for package backups, compact memory backups, and Super Brain hook backups.
- Added hook startup rule length guards in repair and startup checks.
- Added explicit `-Force` confirmation protection before `compact-apply.ps1` modifies memory.
- Extended verification to cover the new maintenance guards.
Supersedes: 0.4.5
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.5

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- `auto-check.ps1` now uses `super-brain-state.json` first and avoids full verification when fresh state is OK.
- Recall helpers now output UTF-8 JSON-friendly results.
- Added safe exact-duplicate memory compaction reporting and dry-run/apply scripts.
Supersedes: 0.4.4
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.4

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Compressed startup hook injection text while preserving default Super Brain activation.
- Added lightweight state cache: `memory\workspace\super-brain-state.json`, `update-state.ps1`, and `state.ps1`.
- Added recall helpers: `recall-search.ps1` and `recall-recent.ps1`.
- Added `skill-sync-check.ps1` to compare package skills with installed ZCode/Codex copies.
Supersedes: 0.4.3
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.3

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added hook self-healing through `repair-hook.ps1` while keeping startup hook lightweight.
- Added `encoding-check.ps1` and `graph-normalize.ps1` as maintenance/verification tools, not startup work.
- Added `write-decision.ps1` for explicit decision particles.
- Added `bootstrap.ps1`, `release-private.ps1`, and `release-share.ps1` for setup and release workflows.
Supersedes: 0.4.2
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.2

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- `install.ps1` now refreshes the real `session-start` hook with the current package path during installation.
- `startup-check.ps1` now verifies the hook contains the current package path.
- Moving the package to another computer now only requires copying the package and rerunning install.
Supersedes: 0.4.1
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.1

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added `startup-check.ps1` for startup hook/config readiness checks.
- Integrated startup checks into `status.ps1`, `health-check.ps1`, and `verify-package.ps1`.
- Updated real `session-start` hook to inject the default `super-memory-brain` startup rule, memory shortcut, recall trigger, and startup auto-check rule.
Supersedes: 0.4.0
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.4.0

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added `auto-check.ps1` so assistants can read the latest verification result or rerun verification automatically.
- `verify-package.ps1` now writes `memory\workspace\last-verify-package.json` for conversation-readable status.
- Entry skill now requires automatic checks for first-run, continue, state, and breakage questions.
- Added `release.ps1` for one-command release package generation.
- Release flow runs full package verification before generating a share package.
- Release flow verifies the generated share package before reporting success.
- `prepare-share.ps1` now includes `BASELINE_HISTORY.md` and `tests` in share packages.
- `verify-share.ps1` now supports `-SkipPrepare` and validates release-critical files.
Supersedes: 0.3.5
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.3.5

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Integrated recall tests, share-package privacy verification, temporary install verification, and `status.ps1 -Json` checks into `verify-package.ps1`.
- Updated graph lineage check to use the current manifest version.
Supersedes: 0.3.4
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.3.4

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Enhanced `status.ps1` with `-Json` output for automation.
- Added status success/failure exit codes.
- Added `-ZCodeSkills` and `-MemoryRoot` parameters for target-aware status checks.
- Preserved human-readable status output by default.
Supersedes: 0.3.3
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.3.3

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Enhanced `health-check.ps1` with explicit success/failure exit codes.
- Added `-ZCodeSkills` and `-MemoryRoot` parameters for install-target checks.
- Updated `install.ps1` to pass install targets into post-install health checks.
Supersedes: 0.3.2
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.3.2

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added post-install health check to `install.ps1`.
- Added `-SkipVerify` for controlled installs that should skip automatic verification.
- Install prints `POST_INSTALL_HEALTH_CHECK_OK` after successful health checks.
Supersedes: 0.3.1
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.3.1

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Enhanced `verify-package.ps1` from file-existence checks to content-level verification.
- Added JSON parse checks, version alignment checks, mojibake marker checks, recall order checks, graph lineage checks, PowerShell parser checks, and memory backend access checks.
- Added `verify-share.ps1` to confirm share packages exclude private memory files.
Supersedes: 0.3.0
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.3.0

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added structured memory layer.
- Added relationship graph support via `memory/graph.jsonl`.
- Added recall tests via `tests/memory-recall-tests.json` and `scripts/test-recall.ps1`.
- Added fact extraction candidate script.
- Added legacy memory tagging script.
- Added short-term workspace compaction script.
Supersedes: 0.2.4
Rollback: Use `CHANGELOG.md`, `CURRENT_BASELINE.md`, and package backups.

## 0.2.4

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added memory governance scripts: `write-memory.ps1`, `audit-memory.ps1`, `baseline-update.ps1`, `prepare-share.ps1`, `verify-package.ps1`.
- Added `memory-policy.json`.
- Private memory requires confirmation and `[PRIVACY]`.
Supersedes: 0.2.3

## 0.2.3

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added `CURRENT_BASELINE.md`.
- Added current-state answer priority.
- Added memory tags.
Supersedes: 0.2.2

## 0.2.2

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Moved memory into package-local `memory/`.
- Updated scripts to use package-local memory.
Supersedes: 0.2.1

## 0.2.1

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added recall trigger for another-session / remember / progress questions.
Supersedes: 0.2.0

## 0.2.0

Date: 2026-06-17
Status: [HISTORY][VERIFIED]
Change:
- Added status panel, conflict arbitration, compact report, backup/migrate scripts, manifest and changelog.
Supersedes: 0.1.0

## 0.1.0

Date: 2026-06-17
Status: [HISTORY]
Change:
- First distributable package with entry skill, three modules, vendor, install script, and health check.
