---
name: skill-orchestrator
description: Internal ORC routing layer for Super Memory Brain after the public `super-memory-brain` entry skill is explicitly active. Use only for non-trivial routing decisions, smallest-useful skill/tool selection, workflow coordination, evidence-gated review, or Agent Bridge coordination. Do not claim the public Super Brain trigger; do not load full ORC for simple direct answers where visible context is enough.
---

## Installed Root Markers

When installed under ZCode/Codex, this skill directory may contain only
`SKILL.md`, `package-root.txt`, and `memory-root.txt`.

- Read `package-root.txt` for the full package root.
- Read `memory-root.txt` for the active NexSandglass memory root.
- Do not assume `scripts/`, `manifest.json`, `references/`, or `memory/` live
  beside the installed skill copy.

Current user instruction, visible context, live files, and verified tool output
beat older memory.

## Core Rule

ORC is a complexity gate, not the default answer path.

```text
classify intent
-> bypass ORC for direct/simple work
-> if complex, choose the smallest useful skill/tool set
-> read `capabilities.json` and one primary cold reference when needed
-> verify before final claims
```

Keep routing private unless it affects the user's next decision, permission,
cost, time, risk, or verification result.

Safety invariant: slimming may shorten ORC, but must not remove direct-answer
bypass, memory governance, task/status/continuation boundaries, Agent Bridge
distinction, evidence gates, rollback awareness, or regression markers.

## Activation Gates

Use ORC for:

- Multi-domain or multi-file work.
- Staged implementation, migration, release, install, repair, or hot-refresh.
- Work with meaningful verification, rollback, privacy, or user-owned behavior
  risk.
- Broad codebase discovery, external research, design plus code, or test
  planning.
- Explicit team/subagent/review-board/delegation requests.
- Super Brain Agent Bridge coordination after the public entry route has chosen
  `agent_bridge_channel`.

Do not use ORC for:

- Ordinary greeting, chat, or acknowledgement.
- Simple explanations or small code snippets with enough visible context.
- Casual mentions of `G1`, product names, games, `user agent`, or human brain
  wording.
- `continue` when the visible current task is sufficient.
- Status questions that only need current visible task state.

When unsure, start direct and escalate only if complexity becomes real.

## Entry Relationship

`super-memory-brain` is the public entry. ORC is internal.

- Public wake, memory, status, continuation, Agent Bridge, maintenance, and
  privacy routes are classified by `super-memory-brain/SKILL.md`.
- ORC only takes over when that route requires non-trivial skill/tool/workflow
  selection.
- Follow `route-map.json` for route names and `capabilities.json` for capability
  ownership.
- Follow `references/index.md` for one-hop cold-path navigation.

Do not let ORC override the public entry rules:

- Task status is not system health.
- Bare `continue` is current-session-first.
- System status reads lightweight state/status card/last-verify summary first;
  install-refresh docs are only for explicit refresh, repair, install,
  hot-refresh, hook, or maintenance action.
- Agent Bridge commands are not host default worker/explorer help.

## Routing Matrix

| Case | Route | First Action |
| --- | --- | --- |
| Simple answer/code | `direct_answer` | Answer from visible context; no ORC cold path. |
| Current progress/next step | `current_task_status` | Visible context/checklist first; no system health dump. |
| Previous/another-session recovery | `historical_recovery` | Use status recovery; recall only if needed. |
| Secret or sensitive memory write | `privacy_memory_gate` | Refuse or ask; no durable secret storage. |
| Stable preference/decision memory | `memory_write_candidate` | Compact candidate, conflict check, G1 gate. |
| Agent channel/open/connect/send | `agent_bridge_channel` | Read Agent Bridge route; do not launch nested host agents. |
| Complex staged work | `orc_complex_routing` | Read `references/orc-routing.md` and `capabilities.json`. |
| Refresh/install/repair | `maintenance_hot_refresh` | Read install/refresh reference; require rollback and approvals. |
| Release/share/package | `maintenance_release` | Read release reference; verify privacy boundaries. |

## Skill Autopilot

The user should not need to remember skill names.

1. Infer capabilities from the user's goal, live files, risk, and output type.
2. Select the smallest useful skill/tool set.
3. Load a skill body only when metadata is insufficient or the skill changes the
   implementation, safety, verification, or output quality.
4. Drop task-specific skills after their phase is done.
5. Prefer existing project conventions and mature local tools.
6. Avoid load-all-skills, broad filesystem scans, and noisy route narration.
7. If a new skill/plugin is installed but not routable, create or update a
   capability note/route rule before calling the integration complete.

Use `capabilities.json` and existing package scripts as the cold source of truth
for capability ownership instead of embedding a full skill catalog here.

## Memory Governance

ORC schedules memory work; G1 governs memory admission.

- Default: `memory:auto`.
- Use recall only when continuity, prior decisions, task resumption, or evidence
  changes correctness.
- Use `memory:force` when the user explicitly asks to remember/recall; privacy
  still wins.
- Use `memory:off` when the user disables memory.
- Prefer visible context, checkpoints, ledgers, and verified files before
  long-term memory.
- Never store secrets, raw transcripts, full payloads, full SSE streams, base64,
  large logs, guesses, or stale/rejected variants.

When durable write is justified, store compact stable facts only: accepted
decisions, supersession, task state, blocker, next action, reusable workflow, and
rollback/version evidence.

## Evidence And Ownership

Protect user-owned function.

1. Anchor to the latest user request and stated non-goals.
2. Verify live files/tool output before making file-state or test claims.
3. Do not delete, disable, rewrite, migrate, or simplify user functionality
   unless the current request requires it or the user approved the scope.
4. For risky edits, create or identify a rollback point first.
5. Keep changes scoped to the touched phase and allowed files.
6. Before finalizing, report changed files, verification, gaps, and next allowed
   step.

If information is missing, state what is missing and use the smallest blocking
question only when a safe assumption is not possible.

## Planning And Execution

Use the lightest process that still controls risk.

- Fast path: direct answer, tiny edit, or obvious local command.
- Plan/checklist: multi-file edits, uncertain requirements, user-visible
  behavior, broad search, or hard-to-reverse work.
- Spec-lite: non-trivial features, product ideas, architecture changes, or
  acceptance criteria.
- Diagnosis loop: hard bugs, regressions, flaky tests, or performance issues.
- Review stance: when the user asks for review, findings first, severity ordered,
  with file/line evidence.

Implementation loop:

```text
understand -> inspect minimal evidence -> edit smallest scope -> verify -> report
```

## Team And Agent Dispatch

Keep team/subagent routing dormant by default.

Use delegation only for explicit team/subagent/review-board requests, broad
independent discovery, architecture or memory-policy risk, install/hook/release
risk, repeated failures, or explicit logic-safety concerns.

Levels:

- `direct`: Commander handles the task.
- `single_delegate`: one bounded evidence report.
- `team_parallel`: independent reports with clear boundaries.
- `review_board`: high-risk review before adoption.

Subagents provide evidence-backed reports only. Commander decides. Code-capable
subagents require explicit authorization with file boundaries, verification
commands, rollback notes, and drift-guard supervision.

Agent Bridge is separate from delegation:

- `agent_bridge_channel` opens/connects/sends/reads a local channel.
- Do not launch nested host agents/workers/explorers/helpers to open a channel.
- `WaitConnect` and `WaitInbox` idle means quiet waiting, not failure.
- Keep waiting until explicit close.

## Tooling And Browser Route

Use tools when live evidence/action is required or materially faster.

- Prefer `rg`/`rg --files` for search.
- Use structured parsers/APIs when available.
- Use package scripts for package behavior instead of retyping large logic.
- Browser operations default to `browser-act` unless Playwright is explicitly
  requested or needed for Playwright tests/workflows.
- Web/current/recommendation/high-stakes facts require current source checks.

Ask before destructive cleanup, broad overwrites, global bootstrap/hook rewrites,
private memory handling, external publishing, or unclear-risk operations.

## Specialist Routing Summary

Keep this as a compact pointer list; detailed routing belongs in
`capabilities.json`, installed skill metadata, and cold references.

- App/mobile foundation choices: use app route-choice guidance before patching.
- Frontend UI/design/builds: use frontend/design/browser verification skills.
- Vue/Nuxt/Vite/Pinia/Vitest/pnpm/turbo/UnoCSS: use the matching ecosystem
  skill when the codebase or request needs it.
- Android/Flutter/React Native/iOS: use the matching platform skill/tooling.
- Docs/API/library usage: prefer official/current docs routes.
- Image generation: use the user's configured image route and keep payloads
  private.
- Memory/continuity/handoff/chat repair: use G1/context/handoff routes as
  appropriate.
- Skill/plugin creation or installation: use the dedicated skill creator or
  installer route.

Do not embed the full installed skill catalog here. The catalog is a cold path.

## Cold Path Index

Read at most one primary reference first:

- `references/orc-routing.md`: ORC complexity gate and route discipline.
- `references/status-recovery.md`: task status, continuation, historical
  recovery.
- `references/memory-governance.md`: memory/privacy write gate.
- `references/agent-bridge.md`: Agent Bridge channel behavior.
- `references/install-refresh.md`: refresh/install/repair/hot-refresh.
- `references/maintenance-release.md`: release/share/package privacy review.
- `references/package-shape.md`: package structure only when the primary
  maintenance reference requires it.

Single-hop rule: after `references/index.md` selects a file, read that file and
stop. Follow a second reference only when the first file explicitly says the
route is blocked without it.

## Regression And Phase Gates

During Phase 4 draft/apply:

- Do not modify `super-memory-brain/SKILL.md`, `manifest.json`,
  `scripts/common.ps1`, global bootstrap, or hot-refresh machinery.
- Draft first; do not overwrite this file until ZCode/G1 approves.
- Before apply, create `rollback-phase4-pre-apply-<timestamp>`.
- Apply may only touch `modules/skill-orchestrator/SKILL.md` unless a later gate
  explicitly expands scope.
- Non-strict route regression must have `failed=0`.
- Strict route regression may fail only known baseline gaps and must not exceed
  the Phase 0b known gap count during Phase 4.
- Phase 6 strict acceptance requires `failed=0`.
- Full Pester must not add failures. The existing manifest extension ingest /
  capability routing marker failure is not fixed in Phase 4 unless separately
  approved.

Known gaps are not accepted final behavior; they are must-fix before Phase 6.

## Compatibility Regression Markers

Keep these compact markers until the full Pester suite reads structured route
metadata directly:

- Product-manager intent gate.
- Current-session task status rule.
- Execution-state checkpoint rule.
- OCR/log/code noise isolation rule.
- Cross-agent/session task identity index rule.
- compact task status table.
- sessionName.
- agentId.
- Cognitive execution loop rule.
- cognitive-preflight.ps1.
- cognitive-enforce.ps1.
- runtime-drift-checkpoint.ps1.
- reflection-promotion.ps1.
- semantic memory.
- episodic memory.
- procedural memory.
- working memory.
- DRIFT_DETECTED.
- Self-learning loop rule.
- Unfinished-task progress-only rule.
- skill-capability-map.ps1.
- extension-capability-map.ps1.
- extension-ingest.ps1.
- ORC-routable capabilities.
- executionHardGate.
- goal-route-lock.ps1.
- accepted-constraints-preflight.ps1.
- task-verification.ps1.
- agent-bridge-channel.ps1.
- rule_auto_application.
- current_task_detection.
- real_user_path_acceptance.
- self_learning_loop_hook.
- multi_agent_non_regression.
- compact_report_discipline.
- rule_skill_fusion.
- pre_action_constraint.
- challenge_gate.
- review_verifier.

## Output Style

For functional work, keep reports compact:

```text
State:
- ...
Action:
- ...
Evidence:
- ...
Next:
- ...
```

Mention ORC/G1 only when explicitly requested or materially used.
