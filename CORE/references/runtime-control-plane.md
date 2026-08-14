# Runtime Control Plane

The installed skill is a host adapter. Runtime code owns continuity, planning,
authorization, verification, and automatic wake behavior. A skill may select
the entry route and present a bounded result, but it must not recreate these
rules in prompt text.

## Automatic Wake Path

Every host prompt takes the smallest applicable tier:

1. `L0 direct`: `routing-kernel.ps1` rejects greetings and independent direct
   messages without reading memory or task bodies.
2. `L1 hot`: `runtime-wake-core.ps1` reads one session-and-workspace index. It
   uses explicit topics, bounded terms derived from the accepted plan, compact
   replies, and anaphoric references to decide whether current state matters.
3. `L2 contract`: only a dependent, contextual, actionable, or material-risk
   prompt reaches `execution-contract.ps1`. The contract records the newer
   instruction, classifies its work-line affinity, and withholds old actions
   until reconciliation.
4. `L3 recall`: summary or deep memory search is allowed only when the contract
   and visible state are insufficient and memory policy authorizes it.

`L0` and `L1` call no model, network, FTS, semantic database, or deep recall.
They never inject a memory body. The internal `L1` p95 budget is 25 ms and the
native prompt-hook work p95 budget is 250 ms. Process launch and OS scheduling
are recorded as a separate cold-start envelope metric: they must be reported,
but cannot silently replace a hot-path correctness or latency result.

For a continuation route, `L2` treats the latest user instruction and latest
assistant progress receipt as separate scoped authorities: the instruction
controls authorization, while the receipt preserves the last confirmed phase,
completion state, evidence, return point, and ordered next-work context. The
runtime may not merge these records across task, workspace, session, task
instance, package version, or anchor binding. If they do not reconcile, action
authorization is withheld while the user-visible receipt still states the last
verified assistant progress and the exact reason action cannot continue.

## Hot Index

After a committed contract-continuity transaction,
`execution-contract.ps1` refreshes
`runtime-state/execution-hot-index/<session>--<workspace>.json` as a derived
cache. The cache is not part of lifecycle authority and may be rebuilt from the
committed contract. Each entry contains only hashed scope identity, revision,
line identity, labels, explicit topic keys, and bounded wake terms. It stores no action body,
commitment body, raw prompt, transcript, memory body, credential, or executable
authorization.

Before topic keys and derived wake terms enter this cache, secret-shaped values
are removed rather than redacted into searchable terms. If a write or revision
sync fails, the runtime retries one bounded rebuild and, if still unavailable,
writes a non-executable session/workspace recovery marker. The next eligible
hot read repairs from the locked contract; stale cache entries never authorize
work.

Prompt-hook telemetry is separate from the cache at
`runtime-state/prompt-hook-telemetry/<session>--<workspace>.json`. The legacy
`workspace/last-codex-user-prompt-hook.json` file is a content-free compatibility
pointer only, so one session cannot overwrite another session's telemetry body.

## Scoped P7 Diagnostic Arms

P7 native prompt-hook acceptance uses a short-lived diagnostic arm, not a
generic workspace flag. Exactly one unexpired arm may exist in a workspace and
it belongs to one verified execution-contract scope:

`workspaceKey + ownerSessionKey + taskId + taskInstanceId + contractRevision`.

Create it only through `codex_prompt_hook.py --arm-diagnostic`; direct JSON
edits are unsupported. The armer also binds its caller's current Codex session
to `ownerSessionKey`; a foreign task cannot impersonate an owner to create an
arm, cannot replace an active arm, cannot consume it, and cannot create its
receipt. The hook validates the complete scope only after stdin, hot-index
resolution, and contract validation; early returns, entry traces, and
pre-contract exceptions leave the arm untouched. While an arm is active, the
native process may write `entry-traces/<armId>.json` to prove only that Python
started. It stores neither scope identity, prompt, raw session data, nor memory
body, and explicitly cannot qualify as P7 success evidence.

Receipts are written to `prompt-hook-diagnostics/receipts/<armId>.json`. A
receipt is acceptable only when its matching `armId` has
`consumeState="committed"`; a `prepared` receipt is an incomplete consume and
is never P7 evidence. The legacy `last-one-shot-dispatch-receipt.json` is a
best-effort compatibility pointer only; P7 acceptance must read the matching
arm-specific committed receipt. Legacy unscoped v1 arms are inert and must be
formally replaced, never treated as live evidence.

This is a governance guard, not a filesystem security boundary: same-user
processes can still bypass it by manually editing private state. Therefore the
workflow rule is one P7 owner task, all other tasks read-only, and all normal
arming through the supported command.

The full execution contract remains the authority. A missing, stale,
multi-task, foreign-session, or conflicting hot index cannot authorize work.
Multiple current tasks stay ambiguous until a task-scoped source selects one.
Cache failure may reduce speed, never correctness; the contract path fails
closed and can rebuild the derived index.

When an active bound context exists, a contract change does not become current
through an isolated file write. `TaskStateStore CommitContinuity` writes the
new contract, current context, route checkpoint, and their compatibility
pointers as one recoverable WAL transaction. Readers that encounter a prepared
or stale binding withhold action authorization until `Reconcile -Apply` finishes
the original transaction. Locator-only contexts retain the direct compatibility
path and cannot be promoted to authorization by a cache or pointer.

## Action Dependency Preflight

Exact short actions enter a preflight route before any default command or
workflow is inferred. This is an action entry gate, not a broad keyword search:
`commit`, `package`, `test`, `modify`, and `sync` first check the bounded
current task scope. A valid packet is bound to the current workspace, task,
owner session, package version, contract revision, and plan fingerprint; it
contains only constraints and acceptance criteria, never an old next action.

- A bound task emits `ACTION_DEPENDENCY_PREFLIGHT` with authorization withheld
  until the current visible instruction is reconciled.
- A bare `test` with no current or residual task state remains a direct request.
  Scope-dependent bare actions (`commit`, `package`, `modify`, `sync`) fail
  closed rather than selecting a default workspace or version.
- Stale, ineligible, foreign, ambiguous, or conflicting task state also blocks
  a short action, including `test`; old summaries and historical success never
  supply missing authorization.
- When a bound, authorizing current-task context exists, the mutation guard
  also verifies the exact task projection, current context hash, contract
  revision/fingerprint/session binding, any existing route checkpoint, and the
  per-task WAL pending set. A mismatch withholds the action instead of treating
  the contract file or a compatibility pointer as enough evidence.
- The prompt hook does not claim that an action has completed. Completion is
  recorded only by the task/phase writer and verified through its scoped
  checkpoint and atomic completion receipt. Without a platform-wide post-tool
  hook, this keeps correctness at the explicit mutation boundary instead of
  adding a background scan to ordinary chat.

## Formal Phase Closeout

A formal phase transition on the same work line, such as `P0 -> P1` or
`P2.2 -> P2.3`, is a cold mutation gate rather than a prompt-time scan.
`execution-contract.ps1` refuses the transition until a compact, task-bound
phase-closeout receipt supplies both a real user-path artifact and a relevant
counterexample artifact. The receipt is bound to the current task, workspace,
owner session, package version, previous contract revision, and previous plan
fingerprint. Each artifact stays under task-scoped private runtime state and is
SHA-256 verified.

`TaskStateStore CommitContinuity` repeats that validation against the prior
canonical contract, so a caller cannot bypass the gate by staging a contract
file directly. A missing, stale, foreign, altered, or incomplete receipt stops
the transition. Explicit branch return and scope replacement are not mistaken
for a phase advance. Ordinary chat and the hot prompt hook do not read these
artifacts, so their latency and context budgets remain unchanged.

## Capability Ownership

| Capability | Runtime owner |
| --- | --- |
| Product coherence and feature intent | `collaborative-intent.md`, `cognitive-preflight.ps1` |
| Current task status and resume receipt | `execution-contract.ps1`, `status-recovery.md` |
| Parent/child work lines and latest-plan freshness | `execution-contract.ps1` |
| Checkpoints and crash recovery | `checkpoint-writer.ps1`, `task-state-store.ps1` |
| Mutation authorization and drift blocking | `cognitive-enforce.ps1`, `runtime-drift-checkpoint.ps1` |
| Evidence-based engineering decisions | `engineering-decision-gate.ps1` |
| Memory admission and OCR/log/code-noise isolation | `memory-governance.md`, recall runtime |
| Derived memory-index freshness | accepted memory writer / explicit physical-rewrite rebuild |
| Self-learning candidate review | `reflection-promotion.ps1`, `skill-evolution-loop` |
| Completion and non-regression | `task-state-store.ps1`, `task-verification.ps1`, `completion-guard.ps1` |

Completion is a lifecycle transaction, not a status string. Task verification
creates immutable task-scoped evidence, `TaskStateStore CompleteTask` closes all
owned active surfaces, and the completion guard then verifies the canonical
completed projection and an empty per-task WAL pending set. Fast registration
cannot write a terminal state. Foreign `last-*` drift files never satisfy or
block a task when an exact task-scoped drift record is available.

## Non-Regression Contract

Moving behavior out of the skill is an architectural migration, not a feature
reduction. Existing recall, proactive intervention, parent return, planning,
privacy, skill routing, checkpoint, engineering judgment, verification,
learning, install, refresh, and rollback behavior must keep passing its prior
tests. New automatic-wake tests are additive.

Acceptance requires all of the following:

- semantic task dependency wakes the correct line without `continue` wording;
- compact approvals and option replies wake the active line;
- greetings and independent direct questions stay silent;
- interruption, compaction, and restart recover the bounded whole lineage;
- foreign sessions and ambiguous tasks do not leak or select actions;
- read-only recall does not create, lock, synchronize, or rebuild derived
  memory indexes, and separate memory roots cannot share a loaded backend;
- the hot path stays within its latency and context budgets;
- the pre-change behavior suite does not lose a passing case.
