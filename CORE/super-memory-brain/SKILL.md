---
name: super-memory-brain
description: "Route Super Brain/G1 and governed task continuity, progress/status/next-step, recovery/history, recall/learning, repair/maintenance, subagent, and canonical git提交—even without naming Super Brain. Skip greetings, ordinary chat/code, user-agent, and human-brain mentions."
---

## Role And Roots

This skill is a lightweight host adapter: it decides whether to enter Super
Brain, reads one bounded runtime result or cold reference, and presents it. It
does not own task trees, plans, wake logic, authorization, checkpoints, memory,
verification, or rollback. H7 runtime/MCP and durable memory remain package-root authority.

Super Brain itself is an independent control-plane Agent system. The latest
user instruction owns objectives and authorization; H7 owns execution state;
the exact assistant-visible receipt plus current project proof owns progress;
live project evidence owns facts; the versioned registry owns behavior.
Memory, absorbed capabilities, this adapter, and collaborator agents are
supplemental and non-authorizing. Other agents act only as bounded executors,
reviewers, or verifiers and cannot replace or rewrite this control plane.

The versioned `super-brain-rules.json` registry is the sole behavioral-policy
authority. This adapter only routes into that authority and must never create a
second copy, priority order, or exception to its rules.

Super Brain is host-model neutral: it never selects, hardcodes, or binds a
宿主 LLM or approval provider. If one host model is unavailable, H7 continuity
must remain usable; the host's currently available authorized capability or a
human approval path decides approval. The adapter may report that an external
approval capability is unavailable, but it must not turn that into an H7 or
ordinary-continuation deadlock.

An installed copy may contain only `SKILL.md`, `package-root.txt`, and
`memory-root.txt`; resolve the full package and active state root from those
markers, never from files beside this adapter.

Current user instruction, live evidence, and tool results beat older memory.

Adapter prose is a soft conciseness optimization: keep it compact and complete
for fast loading, but never delete operating boundaries to satisfy a fixed byte ceiling.

## Absorbed Capability Boundary

Super Brain is the only host-facing capability entry. Bundled sources are
package-owned provenance and parity references: retain source, license,
trigger, boundary, and verification evidence, but never install, directly
invoke, or route them as independent host skills. Each selected capability must
use a verified Super Brain-native procedure/contract; an upstream source may be
consulted only for provenance or parity review, never as the execution path.
Order is H7 scope/contract, core rules, project evidence, Super Brain, then one
bounded native capability. A capability never replaces authorization, latest
instruction, task state, or verification. `skill-capability-map.ps1` projects
capabilities; `extension-capability-map.ps1` is a compatibility compiler, not a menu.

For non-trivial work, run bounded `absorbed-capability-route.ps1` after intent.
Select by meaning, verified trigger, role, boundary, and task context; users
never need to name a source. High confidence adds at most
four compact cards and activates only the selected cold native procedure at its
`applyAt` phase. Never preload sources, make a keyword menu, auto-load an
upstream `sourcePath`, or let a card authorize mutation. Every absorbed
procedure must preserve or improve the verified source outcomes, have its own
boundary and acceptance check, and emit a compact non-authorizing H7 capability
receipt/hash when it participates. H7 governs continuity mechanism, and any
external change stays proposal-only until exact approval.

## Wake And Route Triggers

Load this adapter for:

- explicit `超级大脑`, `Super Brain`, standalone `G1`, status, health, version,
  repair, refresh, install, restore, or maintenance;
- task status, progress, next step, interruption recovery, prior-session work,
  recall, remember, learning, or durable preference intent;
- fresh-task semantic intent for governed progress, continuation, recovery,
  project state, learning, repair, or maintenance also loads this adapter; the
  user does not need to name Super Brain or `G1` literally;
- configured canonical workflow phrases such as `git怎么写`;
- explicit subagent execution/review/verification or Agent Bridge channel intent.

Ordinary greeting or chat stays direct, as does ordinary code. Do not load it for greetings or ordinary chat/code with enough visible context,
`user agent`, product names containing G1, human-brain mentions, or generic
agent wording without delegation/channel intent.

The hookless Turn Runtime wakes governed current-task state without an explicit
`continue`. Global AGENTS selects the route; `brain_turn(open)` binds current
scope, memory, and recovery evidence; `brain_turn(close)` decides continuation
or `ResumeParent`; do not reproduce this with keyword catalogs or broad memory
injection.

## Runtime Handoff

Classify, consume one bounded runtime packet or cold reference, apply
confidence/privacy gates, then return compact evidence. `allowed` uses only the
supplied action; `withheld` reconciles the newest visible instruction; missing,
stale, ambiguous, foreign-session, or conflicting state fails closed. Lineage
lives in runtime, not skill prose; consult `execution-contract.ps1`; do not
reproduce this with skill prose, a keyword catalog, broad memory injection, or
a substitute for runtime evidence. Details are cold in
`references/runtime-control-plane.md` and `references/status-recovery.md`.

### Fresh Codex Or Missing Conversation History

A newly installed Codex client or a task opened before MCP discovery can have no
conversation history, no current-task hot index, or no visible `brain_turn`
tool yet. Resolve `package-root.txt` and `memory-root.txt` first, and report a
missing package root only after the actual marker target is absent. If the
markers and H7 binding are current but the current task cannot expose
`brain_turn`, invoke the package-owned `brain_cli.py turn-runtime` with the
same verified scope, typed intent, and bounded checkpoint. This is the same H7
runtime contract over its CLI transport, not a degraded mode. Do not use
visible/live evidence as a substitute for a governed H7 turn. If neither the
MCP transport nor the same H7 CLI can produce a current scoped receipt, stop
the governed operation with an explicit `H7_RUNTIME_UNAVAILABLE` diagnosis and
repair path; never continue as if Super Brain were active. Missing chat history is never evidence that durable package state is missing.

Before any governed tool call or project mutation after compression, restart,
pause/resume, model switch, or a user correction, complete one H7
`brain_turn(open)` (MCP or the same CLI fallback). A stale MCP is not a
permission to reason from a summary: use the CLI fallback immediately or
withhold.

Host transport is permanently retired. This adapter never reads, waits for, retries, or persists Host
tail, context, thread, readback, or metadata; it also never binds, starts, or
bridges those inputs. Public `host_visible_context`,
`host_thread_payload`, `visible_progress_assertion`, Host readback, and Host
metadata are rejected before decoding with `H7_HOST_TRANSPORT_RETIRED`.

Every same-workline continuation uses one verified local cwd/session scope: cwd plus
`SUPER_BRAIN_LOCAL_SESSION_ID`, its unique current scoped execution contract,
current local progress receipt, and live project proof. H7 maps that evidence to
one same-scope task/workline and establishes the actual phase, step, completed
work, pending work, and allowed action. The `local_contract_current` recovery
projection is non-authorizing, card-free, and contains no external text,
identity, thread, or locator.

Summaries, handoffs, memory, checkpoints, old receipts, user quotations, model
recaps, collaborator text, and process-local cache/leases cannot select or
authorize continuation. Missing, ambiguous, foreign, or evidence-conflicting
local scope enters reconciliation before mutation. H7 may use a state card only
for a verified `parent_return` to another approved workline; timeout, stale
index, or missing entry adapter never enables a state-card fallback.

The current local progress receipt may validate a strict H7 v4 prefix: `G1`,
`[H7-PROGRESS-V4 receipt_hash=<64 lowercase hex characters>]`, and one exact
progress sentence. Its hash, scope, contract revision, and live project proof
must all be current. Plain commentary never alters progress, phase, step, next
action, authorization, project proof, or the execution contract.

Routine H7 identity and project-proof validation stays in the background for an
ordinary continuation and is not repeatedly shown to the user. Surface it only
for an explicit status request, a blocker, detected drift, a formal
progress/stage receipt, or a high-impact action. Formal stage transitions and
high-impact actions still require current validation before execution. The
normal path never imports or waits on an external continuation bridge and never
trades current evidence for a same-process cache/lease.

Auto-alignment is an emergency-only drift repair, not a normal continuation
path. Only after H7 detects a local contract/proof mismatch may it compare the
same-scope contract, issued local progress receipt, and live project proof. It
may detect the mismatch, but it never silently writes or realigns the contract.
The controller must perform an explicit H7 checkpoint with fresh live proof and
publish a fresh v4 receipt before continuing. On drift, first resolve current
same-scope task state and live project proof to prevent duplicated or
already-failed work; then correct scoped state, repair the root cause, and replay
the same path before declaring success.

Hot update/restart rebind is equally strict: H7 may CAS-rebind one unique
same-workspace contract only after current package/runtime identity, scope,
exact v4 receipt binding, and live project proof validate together. The same
transaction rebuilds the hot index and activation receipt. A stale MCP runtime
uses the equivalent H7 CLI for repair, not a degraded answer. Missing identity,
scope, proof, uniqueness, or derived-index rebuild withholds the turn.

For a verified recovery event—compaction, restart, model switch, cross-session
rebind, user correction, explicit resume of a suspended workline, or child
return—call `brain_turn(open)` with the matching `recovery_event`. H7 returns a
transient `recoveryPresentation.openingLine`; show that exact local-contract
line first: `本地执行契约：进度：…｜当前：…｜下一步：…`. The line is
non-authorizing and contains no external text, identity, thread, readback,
metadata, or locator. Do not emit raw commentary as a standalone substitute or
explain H7's validation before the actual continuation result.
Completed phases stay historical; a withheld action means reconcile the newest
instruction, never resume by guess. The event must be scope-bound
runtime/checkpoint evidence or a verified child return; never infer it from a
bare `continue` or another user wording.

The first recovery receipt must use H7's exact
`recoveryPresentation.openingLine`. It shows the verified mapped phase, current
step, and next action without any external sentence, identity, thread, or hash.
The local projection does not mutate the contract or make a durable progress claim. For
`recovery_event=none`, H7 returns `H7_RECOVERY_PRESENTATION_SUPPRESSED`; do not
emit this acknowledgement. Caller-attested replies and external continuation
inputs are rejected; they never replace the local contract or authorize
continuation. If the local scope or required H7 runtime transport is unavailable,
withhold governed work and repair the evidence path instead of emitting a
generic continuation.

For such a genuine recovery, the first visible update states the verified
continuation progress and active action, then actually continues it. Only a
current v4 receipt may state durable completion. Ordinary continuous work, a bare `continue`, status
replies, and progress updates are not recovery events and must not use this
presentation. Do not use it for greetings or independent direct requests.

During ordinary continuous execution, do not turn every intermediate update
into a `进度：…｜当前：…｜下一步：…` card. State only the concrete result or
immediate next action in plain language. Reserve phase/status presentation for
the first line of a verified recovery and H7-bound stage passed, failed,
blocked, or completion receipts.

Before a material phase, branch, verification, return-point update, or any
reply that reports project progress, call `brain_turn(phase=checkpoint)` with
one bounded `assistant_visible_reply` `progress_checkpoint`: its exact progress
sentence must be the progress sentence actually shown in that reply, with its
current phase, step, and next action. The checkpoint is an atomic H7 contract
update, not a raw prompt/transcript channel. Changing any of those scope fields
requires a fresh project proof in the same update; if either write cannot be
made, do not claim a durable recovery point or progress update.

If the current user instruction newly authorizes, redirects, or resolves an
active workline, supply its compact protected form as
`latest_user_instruction` to that same checkpoint. H7 binds it to the scoped
instruction anchor in the CAS transaction; it never preserves a raw prompt or
transcript. When the proof names canonical-plan items, H7 must atomically mark
only those exact, evidence- and verification-bound items completed. A verified
item must never remain `pending`, and an unknown plan-item mapping fails closed
instead of inventing task progress.

Every normal visible progress receipt uses the strict v4 durable envelope:

```text
G1
[H7-PROGRESS-V4 receipt_hash=<visibleProgressReceipt.payloadHash>]
<one compact progress sentence>
```

The second line is a lowercase SHA-256 hash bound to the issued scoped H7
`visibleProgressReceipt`, not to a transient `open` receipt. H7 accepts only
that exact shape as durable progress. Freeform commentary,
unclassified messages, loose `G1`, legacy markers, and truncated text are not
durable anchors and never authorize a progress claim or formal stage transition.
They may trigger a withheld drift repair, but can never become normal progress
on their own.

For a project-progress claim, recovery, phase transition, or completion, bind
the same checkpoint to one `project_progress_proof`: current phase and step,
each completed item, SHA-256-verified relative project evidence, passed
verification identifiers, and the next action. H7 must re-verify the proof
against the live project root before it reports actual progress. A missing,
stale, mismatched, or unverified proof is `withheld`, never a best-effort
progress claim; it does not authorize a fallback from the governed runtime.

Every forward formal stage transition also requires an H7 closeout receipt and
an H7-issued user stage receipt bound to the same local progress hash. Emit the
receipt directly; no Host readback or acknowledgement is required.
An execution-contract field mutation, old checkpoint, side branch, or summary
cannot advance a stage by itself.

### Stage User Receipt

After every phase/stage gate reaches `passed`, `failed`, or `blocked`, send the
user a compact receipt **before beginning the next phase**: stage name or
number, status, concrete verification evidence, H7/live-proof binding, and the
next action. Never silently advance a phase or imply completion without that
receipt. Ongoing work may have concise intermediate updates, but a phase
boundary always has this explicit user-visible receipt.

For a governed task/status/continuity/recall/learning/repair turn, call
`brain_turn` with `phase=open` before work. Before a terminal reply call it with
`phase=close` and the same bounded `progress_checkpoint` when the reply changes
or confirms progress; if `mustContinue` or `requiresParentResume` is true,
continue the current work or return to the parent instead of ending the turn. A
withheld result reconciles the newest visible instruction. Do not pass raw prompt
text as completion evidence.

## Route Map

Use `route-map.json`/`capabilities.json` or one hop from `references/index.md`; `bare_wake`
stays here. Task/status/history starts with a runtime packet, ownership uses the runtime-control
plane, and other domains use their matching one-hop reference. Read a second only to unblock work.

## Memory And Privacy

## Hookless Turn Runtime

`UserPromptSubmit` and `Stop` are retired for Super Brain. The only lifecycle
authority is `brain_turn`: it uses cwd plus an explicit
`SUPER_BRAIN_LOCAL_SESSION_ID`, one scoped execution contract,
activation receipt, typed-memory refs/hash, and the existing turn-close
dispatcher. Do not let a long-lived MCP worker guess a task. MCP
`brain_recall` remains bounded for ordinary semantic memory or an explicitly
verified `task_scope` (`top_k=1`, `max_tokens=120`; never above `top_k=3`,
`max_tokens=500`).

Only the current local contract, local progress receipt, and live project proof
are in-turn context. `brain_turn` creates the scope-bound H7 runtime receipt and
bounded telemetry; it never stores a raw prompt or transcript. Skip recall for
ordinary direct work/greetings; do not retry by watching logs or session files;
unavailable or conflicting state fails closed for governed work.

If the registered H7 MCP transport is unavailable **or its live
`brain_status.runtimeIdentity` is not `current`** but the current process has a
verified workspace cwd plus `SUPER_BRAIN_LOCAL_SESSION_ID`, use the
package-owned `brain_cli` equivalent
command: `turn-runtime` with the same typed intent and a Base64 UTF-8 progress
checkpoint, or bounded `recall`/`recent`/`status` reads.
It has the same H7 contract authority and is an equivalent transport, never a
degraded execution path. A live MCP identity mismatch is a real repair state:
do not call the stale MCP as current, and request exact approval before
re-registering the one global MCP entry. Do not revive P7, a prompt Hook, or a
background worker. If the CLI cannot bind the same scope or return a current receipt,
fail closed with `H7_RUNTIME_UNAVAILABLE` and repair instead of answering from
external context.

Before a governed `brain_turn`, provide one normalized `turn_intent` enum from
the visible request (`design_evaluate`, `continuity`, `super_brain_issue_*`,
`user_correction`, or `memory_write` as applicable). The runtime maps that enum
to rule signals and memory/write obligations; it never infers them from stored
prompt text.

Memory Modes are bounded and route-scoped:

- `memory:auto`: recall only when intent depends on prior state, workflow, decision, evidence, or stable preference.
- `memory:force`: explicit recall/remember; privacy still wins.
- `memory:off`: visible state only; no proactive retrieval or durable write.

Use confidence gates: high injects a compact packet, medium only a summary/title/evidence pointer,
low skips the body. NexSandglass stores/searches; G1 admits; ORC routes. Never store secrets,
credentials, raw transcripts, payloads, base64, large logs, guesses, rejected variants, or unapproved
sensitive data. Durable writes are limited to compact verified preferences, decisions, supersession,
task state, reusable workflows, and rollback/version evidence.

## Output Contracts

Visible G1 invariant: when Super Brain, G1, ORC, governed recall, or governed
writeback actually participates, the first user-facing update and final summary
begin with `G1`. This is valid only after the scoped activation receipt reports
`full_brain_active`, `withheld`, or `failed`; a bare `G1` is never proof of
startup and is forbidden. `full_brain_active` may use `G1`; `withheld` or
`failed` must state that activation is blocked and why. A governed turn never
uses a `degraded` receipt as permission to continue.
A bare `G1` is presentation only, never a durable progress anchor. Any visible
progress intended for later continuation must use the strict three-line v4
envelope defined above and bind its second line to the issued
`visibleProgressReceipt.payloadHash`.
Intermediate updates do not begin with `G1`. When the final reply is the only update, its
first line is exactly the state-aware `G1` line. For a plain full-brain result,
the line is exactly `G1`; withheld or failed results must add their state.
Never show `G1` when Super Brain did not participate.

For a uniquely resolved canonical Git workflow request, output only Chinese
`Summary`, `Description`, and the actual `Commit button text`. Missing or
conflicting current evidence blocks that format; do not substitute generic Git
commands, apology text, or unverified commit claims.

For functional status use `State:`, `Action:`, `Evidence:`, and `Next:`; keep only
the key result, error, verification, and result path.

## Super Brain Issue Protocol

For an explicit Super Brain issue, first give problem essence, FACT / INFERENCE / UNKNOWN,
repair direction, and next action in the user's language. Safe local repairs in the approved scope
continue through diagnosis, repair, and user-level regression without another `continue`; an overall
plan waits approval, while governed writes retain their confirmation gates. Do not call explanation
or plan a repair; after verified repair, stage only a compact learning candidate and never auto-adopt
a rule, skill, runtime policy, or hook change.
Use the returned `turnIntent.problemNature` as the issue classification, and keep its
`learningTarget` as a candidate disposition until the scoped repair and replay pass.

## Delegation And Compatibility

For explicit subagent work use `single_agent_subagent_workflow`; independent, non-blocking sidecars may run in parallel,
but the controller owns state writes, integration, and final acceptance. Agent Bridge is
legacy/manual-only compatibility for explicit channel requests, not the default workflow or durable memory.
Post-task closeout may run bounded automatic evolution through the Ponytail gate; policy is cold in
`references/automatic-evolution-policy.md`.

### Destructive Target Authorization Invariant

Deletion, archival, unpinning, cleanup, and overwrite are denied by default. A mutation is authorized only when the current user explicitly approves its exact action, complete target set, and user-visible impact, or when a current user-approved plan explicitly lists that same action, target set, and impact.

`continue`, `maintenance`, `cleanup`, and similarly vague instructions are never authorization. Wildcard expansion, target-set growth, target drift, stale approval, and unknown identity fail closed and require new explicit approval. Authorization is scoped to one action, target set, impact, task, and approval source; it cannot be inherited from unrelated work or standing maintenance permission.

### Subagent Lifecycle Invariant

Only a verified internal executor/reviewer/verifier agent child may be closed or interrupted. For such verified children, `task_complete`, `turn_aborted`, `interrupted`, `task_failed`,
`no_longer_needed`, or an explicit user stop/cancel is terminal: close the child runtime only before `ResumeParent`.
This is a child-only interrupt/stop, not archival: never archive, delete, or hide the parent or any user-owned Codex
conversation. Child cleanup is never task/session archival or deletion. Parent, user-owned, MCP, and unknown identities must never be archived, deleted, hidden, or unpinned. After a child returns its result, close it first and only then resume the parent; keep a child open
only when it has an explicitly authorized next action. Never leave idle, ended, or no-next-action children holding
threads. If close fails, record and surface the failure; never silently orphan the child. Unknown or parent-owned
identities fail closed. Explicit Agent Bridge channel sessions remain manual and close only on explicit close.
An app-managed MCP server or transport is not a child agent: never stop it as generic child cleanup, and never
trade a live transport for cosmetic process-count reduction.

## Maintenance And Quality

`scripts/first-load-bootstrap.ps1` owns explicit-load health/MCP repair and `scripts/install.bat`
idempotent installation. Prefer report or dry-run mode; Ask before destructive cleanup, global/hook
rewrite, broad overwrite, private-memory handling, publishing, or irreversible work.

Delivery efficiency is an execution invariant: keep one active parent workline;
parallelize only independent, bounded child checks; run the fastest deterministic
acceptance loop first; timebox broad suites and narrow an overlong suite to its
affected path. Close a finished child before `ResumeParent`. Never create idle
tasks, simulate progress, skip required verification, or let parallel work
overwrite the parent's scoped state.

GPT-5 Anti-Degradation Guard: read code/context before mutation, preserve user changes, keep
FACT / INFERENCE / UNKNOWN separate, use the smallest reversible implementation, and verify before closeout.
Load `references/base-instructions/gpt-5.5-base-instructions.md` only for instruction or quality drift.
Moving behavior from this adapter into the runtime does not remove the adapter or its governing boundary.
Existing recall, continuity, planning, privacy, routing, verification, learning, install, refresh,
and rollback regressions remain required; automatic-wake tests are additive.
