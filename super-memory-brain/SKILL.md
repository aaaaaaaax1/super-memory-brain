---
name: super-memory-brain
description: "Route explicit 超级大脑/Super Brain/G1 control, status, recall, continuation, learning, restore, maintenance, subagent, Agent Bridge, and canonical git提交 requests. Skip greetings, ordinary chat/code, user-agent, and human-brain mentions."
---

## Installed Root Markers

When installed under ZCode/Codex, this skill directory may contain only
`SKILL.md`, `package-root.txt`, and `memory-root.txt`.

- Read `package-root.txt` for the full package root.
- Read `memory-root.txt` for the active NexSandglass memory root.
- Do not assume `scripts/`, `manifest.json`, `references/`, or `memory/` live
  beside the installed skill copy.

Memory roots:

- Shared default: `<package-root>/memory/shared`.
- Private agent mode: `<package-root>/memory/agents/<agent-name>`.
- Named shared group: `<package-root>/memory/groups/<group-name>`.

Current user instruction, visible context, live files, and verified tool output
beat older memory.

## Core Rule

Use Super Memory Brain as a short router, not as full memory injection.

```text
classify intent
-> decide whether Super Brain/G1/ORC/recall is needed
-> read the smallest hot entry
-> use references/index.md for cold paths
-> avoid user-visible routing noise unless it affects the next action
```

Ordinary chat, simple code, direct explanations, and casual mentions stay on the
host path. Do not show a `G1` prefix or run memory scripts unless the user
explicitly asks for memory/status/continuity, the answer depends on prior
state, or a terse request matches a configured canonical workflow preference.

Visible G1 invariant: when Super Brain, G1, ORC, NexSandglass, governed recall,
or governed writeback actually participates, the first user-facing update and
the final summary each begin with `G1`; when the final reply is the only update,
its first line is exactly `G1`. Intermediate updates do not carry the prefix.
Never show `G1` when Super Brain did not participate. Keep progress reports to
status, key progress, errors, and result path; retain necessary checks and omit
unrelated narration.

Safety invariant: slimming may shorten or defer loading, but must not remove
recall, status, continuation recovery, privacy gating, Agent Bridge, install,
verification, hot-refresh, or rollback paths.

Context budget invariant: always-on startup text is a routing index, not a
manual. Keep the generated global bootstrap within its enforced character
budget; keep skill descriptions short and discriminative; keep commands,
examples, long trigger lists, skill catalogs, memory bodies, and evidence in
cold skill/reference paths. New always-on text requires a measured size delta,
a route-critical justification, and regression coverage. If the budget would be
exceeded, consolidate or move details cold instead of raising the limit by
default.

GPT-5 Anti-Degradation Guard: keep senior-engineer execution quality active by default. Read the code/context before changing it, avoid lazy generic answers, prefer the smallest reversible implementation, preserve user changes, verify before closeout, keep outputs compact and evidence-based, and load the full base-instructions reference only when drift, degraded behavior, frontend quality, review discipline, or instruction recovery requires it. Full source: `references/base-instructions/gpt-5.5-base-instructions.md`.

## Wake And Route Triggers

Load this skill first for explicit Super Brain control:

- `超级大脑`, `启动超级大脑`, `刷新超级大脑`, `Super Brain`, standalone `G1`.
- Super Brain/G1 status, health, version, refresh, repair, install, restore.
- `任务状态`, current progress, next step, where are we, current checkpoint.
- Stateful continuation: `继续` only when it depends on the current visible task
  or explanation; `上次`, `之前`, `另一个会话`, previous/last-time wording
  signals possible historical recovery.
- `还记得` / `do you remember` routes to bounded memory recall unless previous-session wording is also present.
- `记住`, remember preference, recall memory, learning, durable rule update.
- A terse request matching a configured workflow preference. Perform one
  bounded canonical lookup before replying; do not replace a current verified
  response contract with generic command text.
- Hard output gate for the configured Git phrases: after a unique current
  verified lookup, output only Chinese `Summary`, `Description`, and the actual
  `Commit button text`. A missing or conflicting record blocks the answer; do
  not emit shell Git commands, apology text, or unverified staging/commit claims.
- Before non-trivial mutation, run a query-matched rule preflight capped at
  three current constraints. Do not load the whole rule catalog; do not act on
  a remembered rule when the preflight is missing or conflicting.
- Subagent execution/review/verification requests such as letting a subagent modify, test, audit, or produce evidence.
- Legacy/manual Agent Bridge channel commands: `agent channel`, `subagent channel`, `agent bridge`, `子agent通道`, open/connect/send/read/close channel.

Negative triggers:

- Ordinary greeting or chat.
- Simple coding request with enough visible context.
- `user agent` explanation.
- Product/game/model names containing `G1`.
- Human brain/脑子 phrases such as "my brain is confused".
- Generic `agent` meaning unless paired with channel/open/connect/send/bridge intent.

## Route Map

Prefer `route-map.json` for machine-readable route names and `capabilities.json`
for capability ownership. Use `references/index.md` as the one-hop cold-path
navigation table.

Hot route summary:

| Route | Use When | First Read |
| --- | --- | --- |
| `bare_wake` | explicit Super Brain/G1 wake | this file only |
| `current_task_status` | current task/progress/next step | `references/status-recovery.md` |
| `system_status` | Super Brain health/version/system state | lightweight state/status card/last-verify summary |
| `current_session_continue` | continue visible task/explanation | visible context/checklist |
| `historical_recovery` | previous/last/another session | `references/status-recovery.md` |
| `memory_recall` | remember/recall a stable preference, decision, or rule | `references/memory-governance.md` |
| `privacy_memory_gate` | remember/store secret or sensitive data | `references/memory-governance.md` |
| `memory_write_candidate` | stable preference/rule/decision | `references/memory-governance.md` |
| `workflow_preference_recall` | configured terse workflow-format request | `references/memory-governance.md` |
| `automatic_evolution_learning` | post-task bounded learning closeout | `references/automatic-evolution-policy.md` |
| `anti_degradation_guard` | GPT-5 execution quality drift or instruction recovery | `references/base-instructions/gpt-5.5-base-instructions.md` |
| `single_agent_subagent_workflow` | subagent execution/review/verification inside one agent | `references/single-agent-subagent-workflow.md` |
| `agent_bridge_channel` | explicit legacy channel open/connect/send/read/close | `references/agent-bridge.md` |
| `maintenance_hot_refresh` | refresh/install/repair | `references/install-refresh.md` |
| `maintenance_release` | release/share/package/privacy review | `references/maintenance-release.md` |
| `orc_complex_routing` | complex multi-domain task | `references/orc-routing.md` |

Do not route `system_status` to install/refresh docs by default. Read
`references/install-refresh.md` only for explicit refresh, repair, install,
hot-refresh, hook, or maintenance action.

Single-hop rule: after `references/index.md` selects a file, read that file and
stop. Follow a second reference only when the first file explicitly says the
route is blocked without it.

## Memory Modes

- `memory:auto`: default. Retrieve or write only when keyword/semantic triggers
  and G1 policy justify it. A configured terse workflow preference is one such
  trigger and uses one bounded canonical lookup.
- `memory:force`: user explicitly asks to remember/recall. Privacy still wins.
- `memory:off`: no proactive retrieval or durable writes; use visible context.

G1 owns memory governance. NexSandglass is storage/search, not authority. ORC
owns task routing, not memory admission.

Use confidence gates:

- High confidence: inject a compact memory packet.
- Medium confidence: use summary/title/evidence only.
- Low confidence: skip memory body and say what is missing if needed.

## State And Continuation Priority

For status, continuation, and recovery:

1. Current user message and visible conversation.
2. Current plan/checklist/checkpoint/recent tool result.
3. Active task index or status card.
4. Lightweight Super Brain state.
5. Summary recall.
6. Deep recall only when explicit previous/another-session context requires it.

Task status is not system health. Do not answer `任务状态`, "where are we", or
"next step" by running doctor, CI, package verification, or system dashboard
unless the user asks for system health or the task requires it.

Bare `continue` is current-session-first. Upgrade to historical recovery only
when the user says previous, last time, another session, `上次`, `之前`, or the
visible context is insufficient.

Compaction/resume priority: after context compression, use visible context,
then the current task execution contract, compressed summary/records,
checkpoints, ledgers, and recent tool results before long-term memory. Phase
status and latest execution commitment are separate: a checkpoint reports where
the task is, while `execution-contract.ps1` reports what the latest instruction
authorizes next. A new unreconciled user instruction blocks old mutations.
Missing/stale/conflicting contract state makes the latest action unknown; do not
guess or repeat an older step. Stale memory never overrides newer visible
context. Resume receipt: after interruption, compaction, disconnect, model switch,
or handoff, briefly echo the latest visible sentence/commitment, then state
current phase, verified evidence, and the authorized next action; if any of
these is unknown, do not mutate.

Mid-task insertion rule: classify a new request before changing focus. `continue`
extends the current task; `side_branch` is the default for an interruption and
saves a bounded parent return card; `replace` is allowed only when the user
clearly supersedes the original task. After a side branch, restore the parent
focus and next action with `execution-contract.ps1 -Action ResumeParent`. Never
discard the parent task merely because the latest message is about something
else.

Multi-line task closeout rule: after one line completes, show a compact list of
the main line, the line completed now, unfinished lines, and the next line.
Follow the latest explicit user priority; otherwise resume the nearest suspended
parent. Use bounded `workLineStatus` plus visible task state, not deep recall.

Work-line visibility rule: when more than one line exists, the first status
update after a new instruction or resume must name the main line, current line,
suspended/unfinished lines, effective execution order, and concrete next action.
Use the bounded user view from the execution contract; technical IDs alone are
not a user-facing status.

Topic-affinity rule: bind a new message to a line only from a unique current
task-scoped match or an explicit continuation signal. Show the selected line and
confidence. Unknown, derived-only, or tied matches remain visibly unclassified
and cannot authorize mutation until reconciled as `continue`, `side_branch`,
`ResumeParent`, or explicit `replace`. Memory may support the decision but may
not supply or override line identity.

## Privacy And Durable Memory

Never store:

- API keys, tokens, passwords, cookies, bearer strings, private credentials.
- Raw transcripts, full payloads, full SSE streams, full image objects, base64.
- Large logs, guesses, noise, rejected variants, stale conflicts.
- Sensitive personal data unless explicitly required and approved.

Store only compact durable facts:

- Stable user preference.
- Accepted decision and supersession.
- Current task state, blocker, next action.
- Verified reusable workflow.
- Rollback/version evidence when useful.

Before a durable write, prune stale/conflicting memory and summarize. Shared
memory writes must use package locking/atomic helpers; do not add raw
`WriteAllText`, `Set-Content`, `Add-Content`, or bare append paths.

## Single-Agent Subagent Workflow

For complex work where the user asks a subagent to modify, inspect, test, review, verify, or produce evidence, prefer `single_agent_subagent_workflow` and read `references/single-agent-subagent-workflow.md`. Dispatch independent, non-blocking sidecars in parallel when they materially shorten the task; the controller alone owns execution contracts, state writes, integration, and final acceptance. Do not use channel/inbox/wait/ack for this default workflow.

post-task closeout may run bounded automatic evolution through Ponytail gate; full policy in `references/automatic-evolution-policy.md`.

## Legacy Agent Bridge Entry

Agent Bridge channel is legacy/manual-only compatibility for explicit cross-agent channel commands, not the default subagent workflow.

Route to `agent_bridge_channel` only when the user explicitly asks to open, connect, send to, read from, or close an agent/subagent channel, including mixed Chinese/English phrasing.

Rules:

- Open creates a fresh local channel unless the user supplies a channel id.
- Do not launch nested host agents/workers/explorers/helpers to open a channel.
- `WaitConnect` and `WaitInbox` idle means quiet waiting, not failure.
- After one reply, keep waiting for the next message until explicit close.
- No durable memory write by default.

Read `references/agent-bridge.md` for full channel behavior.

## ORC And Capability Routing

Use ORC only when complexity justifies it: multi-domain work, broad search,
staged implementation, tests, release, design plus code, or agent coordination.

Do not load ORC for simple answers, small code snippets, ordinary explanations,
or casual chat.

When ORC is needed, read `capabilities.json` and `references/orc-routing.md`.
Select the smallest useful skill/tool set. Avoid load-all-skills behavior.

For non-trivial repair, optimization, architecture, migration, performance,
root-cause, or best-option decisions, ORC applies the cross-cutting engineering
judgment contract in `references/engineering-judgment.md` and uses
`engineering-decision-gate.ps1` before meaningful mutation/completion. Keep
FACT / INFERENCE / UNKNOWN separate, require evidence for facts, label root
cause verified/hypothesis/unknown, test critical unknowns cheaply, qualify
optimality by objective/constraints/alternatives/tradeoffs/criteria, and give
  each execution step input/output/acceptance/stop conditions. Ordinary chat and
  tiny direct tasks stay concise.

For feature, workflow, product-behavior, or automation requests, load the cold
`references/collaborative-intent.md` gate before meaningful mutation. State the
real outcome, product role, integration path, non-goals, autonomy tier, and
minimum verification; reversible alone is not enough. Direct local changes may
proceed, workflow changes align first, and structural changes require discussion.

Proactive intervention is thresholded: interrupt only for evidence-backed
material expected benefit or material/high risk; keep marginal improvements
silent. An unverified high risk may trigger only a compact verify-or-contain
warning, never a factual claim. Approved plans with at least three concrete
steps start a lightweight checkpoint and close it only after matching successful
verification.

Checkpoint hard gate: before the first mutation of an approved plan with three
or more concrete steps, invoke `autonomous-executor.ps1 -ApprovedPlan
-PlanSteps ...` and confirm `checkpoint.created=true`. If the call fails or no
matching active checkpoint exists, stop before mutation and repair/report the
continuity gate. Do not defer checkpoint creation until completion.

## Maintenance And Install

For refresh/install/repair/hot-refresh, read `references/install-refresh.md`.
For release/share/package review, read `references/maintenance-release.md`.

On an explicit Super Brain/G1 load, the host pre-turn hook performs
`scripts/first-load-bootstrap.ps1`: it checks the installed entry skill,
formal memory root, and the narrow MCP binding. A missing or stale MCP binding
is repaired once against the formal root; the user is told when a new Codex
task is needed for tool discovery. A normal greeting does not run this path.

The single-click install path is `scripts/install.bat`, which delegates to
`scripts/bootstrap.ps1` and completes skill injection, hook setup, runtime/MCP
registration, first-load verification, and package integration checks in one
idempotent flow. `install.bat ui` and `install.bat console` remain optional
interactive entrypoints.

Safe defaults:

- Prefer dry-run/report mode before writes.
- Ask before destructive cleanup, hook/global rewrite, broad overwrite, private
  memory handling, or external publishing.
- Report what changed, verification result, and rollback path.

## Baseline And Regression

Current strict route regression files:

- `tests/route-regression-cases.json`
- `scripts/route-regression.ps1`
- `tests/powershell/RouteRegression.Tests.ps1`

Accepted production baseline:

- Strict regression: `ok=true`, `total >= 42`, `failed=0`.
- `knownBaselineGapCount=0`; a new mismatch is a regression, not an accepted gap.

## Dispatch Checklist

Before answering a Super Brain-triggered request, run this mental checklist:

1. Is this explicit Super Brain/G1/memory/status/continuation/Agent Bridge
   intent, or ordinary chat with a tempting keyword?
2. If ordinary chat, answer directly and do not load cold paths.
3. If status, decide task status vs system status before reading files.
4. If continuation, decide current session vs historical recovery before recall.
5. If memory write, run the privacy gate before any storage/search action.
6. If a terse workflow phrase is configured, perform its bounded canonical
   recall before replying; do not fall back to a generic template.
7. If subagent execution/review/verification is requested, use single-agent workflow before generic team dispatch.
8. If explicit channel/open/connect/send/read/close is requested, choose legacy Agent Bridge.
9. If ORC, confirm complexity justifies it and choose the smallest route.
10. If maintenance, check approval and rollback requirements before writes.

Do not hide a route mismatch with looser wording or baseline metadata. Strict
regression is the acceptance gate.

## Compatibility Regression Markers

Keep these compact markers until the full Pester suite is updated to read
`route-map.json` and references directly:

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
- Multi-line task closeout rule.
- Engineering judgment rule.
- engineering-decision-gate.ps1.
- FACT / INFERENCE / UNKNOWN.
- evidence_grounding.
- engineering_decision.

## Output Style

For functional tasks, keep answers compact:

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

Mention memory or G1 only when it was explicitly requested or materially used.
Never narrate long lookup or routing internals unless the user asks.
