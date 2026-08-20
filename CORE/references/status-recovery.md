# Status And Recovery Route

Super Brain is an independent H7 control-plane Agent. This document describes
its local-only recovery contract; it does not create a second state store or an
external continuation policy. The current cwd, `SUPER_BRAIN_LOCAL_SESSION_ID`,
scoped execution contract, current local progress receipt, and live project
proof remain the authoritative control plane.

Host transport is permanently retired. H7 never reads, waits for, retries, or
persists Host tail, context, thread, readback, or metadata; it also never binds,
starts, or bridges those inputs. Every legacy Host transport input is rejected
before decoding with `H7_HOST_TRANSPORT_RETIRED`.

## Authority Split

The records below have different jobs and must never substitute for one
another:

1. The latest user instruction controls the objective, authorization, stop,
   replace, and priority decision. It is never a progress anchor and cannot
   select, truncate, or rewrite the latest assistant progress.
2. The scoped execution contract stores the mapped task state, canonical plan,
   work-line tree, and permitted action for exactly one local cwd/session scope.
3. The current local progress receipt records the latest proof-bound progress
   publication for that contract. It cannot replace task state or live facts.
4. Live project evidence and the H7 project-progress proof establish project
   facts and actual completed work. A stale proof is not evidence of current
   progress.
5. Memory, summaries, handoffs, checkpoints, tool narration, and collaborator
   reports are supplemental evidence only. They never replace the current local
   scope, contract, progress receipt, or project proof.

## Local-Only Continuation

For the same main workline, compaction, pause-after-continue, restart, model
switch, rebind, and user correction, H7 has one recovery input: exactly one
current local cwd/session scope, meaning cwd plus `SUPER_BRAIN_LOCAL_SESSION_ID`. H7 resolves one scoped
execution contract, then rechecks its current local progress receipt and live
project proof. The resulting `local_contract_current` recovery projection is
non-authorizing and contains no external text, identity, thread, or locator.

Summaries, memory, old receipts, cache/leases, and state cards cannot select
normal continuation. Public `host_visible_context`, `host_thread_payload`,
`visible_progress_assertion`, Host readback, and Host metadata inputs return
`H7_HOST_TRANSPORT_RETIRED` immediately. A missing local scope, non-unique
contract, stale proof, or unavailable H7 runtime withholds governed action.

### Resume Decision

1. **Resolve scope.** Derive the workspace only from cwd and the owner session
   only from `SUPER_BRAIN_LOCAL_SESSION_ID`.
2. **Map and verify.** Resolve exactly one current scoped contract and validate
   its current local progress receipt plus live project proof. Use those records
   to establish the actual task, workline, phase, step, completed work, pending
   work, and allowed next action.

A missing, ambiguous, foreign, or evidence-conflicting mapping enters
reconciliation before mutation. An old summary, contract, checkpoint, memory
record, receipt, external thread, or external message cannot replace the current
local scope and current proof.

### Local Progress And Ordinary Continuity

The current local progress receipt validates the strict v4 progress envelope:

```text
G1
[H7-PROGRESS-V4 receipt_hash=<64 lowercase hex characters>]
<one compact progress sentence>
```

The envelope becomes durable progress only when its hash, exact sentence, local
scope, execution-contract revision, and live project proof are current. Plain
commentary cannot claim a phase, completed work, authorization, or a formal
stage transition. Strict v4 validation remains required for a durable
progress/phase/completion claim and for a forward formal stage transition.

When mapping finds no active task, H7 performs **ordinary no-task continuity**
without creating an execution contract, task card, state card, project proof,
or fake repair task. H7 participation is still real; the absence of a task card
does not disable continuity.

Routine H7 and proof validation runs silently in the background for ordinary
continuation. Do not repeatedly display its reads, hashes, or synchronization
steps. Surface them only for a blocker, detected drift, explicit status request,
formal progress/stage receipt, or high-impact action. Strict current validation
remains mandatory before a published progress claim, formal stage transition,
or high-impact mutation.

### State Cards And Boundary Recovery

A state card is an exceptional `parent_return` selector, not a normal
same-workline synchronization record. Local-contract recovery remains card-free:
it does not persist an external-readback/state card or perform a per-turn
state-card CAS.
A state card may select a workline only after H7 verifies an approved
`parent_return` to another approved workline.

A timeout, stale hot index, old receipt, or missing entry adapter is **not** a
state-card eligibility signal. A same-process cache or lease is likewise not a
fallback. The state card can never override a valid current local contract.

### Drift Diagnosis And Repair

On drift, H7 must: (1) resolve the current local scope, contract, progress
receipt, and live project proof, (2) prevent a duplicate or already-failed
action, (3) correct the current scoped state, (4) repair the root cause, and
(5) replay the same path before declaring success. Auto-alignment remains an
emergency-only guard, never the normal route.

`brain_cli.py turn-runtime` is the same H7 runtime transport when the registered
MCP is unavailable or stale; it is not a degraded continuation mode. It binds
the same workspace cwd and `SUPER_BRAIN_LOCAL_SESSION_ID`. If neither runtime
entry can return a current scoped H7 receipt, return `H7_RUNTIME_UNAVAILABLE`
and repair before governed work resumes.

## Resume Receipt

After a verified interruption, compaction, disconnect, model switch,
cross-session rebind, explicit resume of a suspended workline, or verified
child return, emit one compact user-visible continuity receipt before mutation.
Its first line is H7's exact local recovery presentation:
`本地执行契约：进度：<verified phase>｜当前：<verified step>｜下一步：<verified action>`.
The presentation is non-authorizing and contains no external text, identity,
thread, metadata, or hash. If phase, step, or next action cannot be verified
together, H7 withholds recovery and repairs the evidence boundary.

Presentation correctness is part of the receipt contract. Evidence identity,
completed/pending detail, branch identity, and return-point information remain
internal unless the user explicitly requests status or diagnosis after recovery.

- Separate completed historical phases from the active mapped phase internally.
  A previous accepted phase is not evidence that it is currently executing.
- When `actionAuthorization=withheld`, say that the current action is to
  reconcile the latest user instruction and repair the missing mapping/proof.
  Do not expose, imply, or execute an older action just to complete a receipt.
- A clearly labeled checkpoint-only state may be shown for diagnosis, but it
  cannot authorize continuation or be presented as a verified resume receipt.
- External prose never becomes a v4 sentence, stage claim, project proof, or
  continuation locator. The local projection has no external tail.

The direct progress presentation is event-bound. It appears exactly once on the
first visible update only when H7 has a scope-bound recovery event or a
verified child-return receipt. A bare `continue`, ordinary continuous turn,
status reply, progress update, greeting, or independent request does not emit
a recovery presentation.

During ordinary continuous execution, do not repeat a phase/status card on
each intermediate message. Use plain language for the concrete result or
immediate next action. Phase/status presentation belongs only to the verified
recovery opening line and H7-bound stage passed, failed, blocked, or completion
receipts.

Do not claim durable progress from vague memory. If the current local scope,
contract, progress receipt, same-scope task/workline mapping, project proof, or
authorized next action cannot be established, withhold before mutation and
repair the evidence path.

## Emergency Drift Reconciliation

Automatic alignment is an emergency-only guard after H7 detects a local
contract/proof mismatch. It is not a normal continuation path and must not hide
a broken publication or rebind flow. The guard may inspect only the current
same-scope contract, issued local progress receipt, and live project proof. It
detects the mismatch but never writes or silently realigns the contract.

The controller must perform an explicit H7 checkpoint with fresh live project
proof and publish a fresh v4 receipt before continuing. Caller-provided state,
external messages, legacy markers, and old contracts cannot be auto-promoted,
advance a stage, change a workline, or alter authorization.

## P0 Continuity Priority Invariant

`decision_key`: `resume-local-contract-then-scoped-progress-mapping-v3`
`topic_key`: `continuation`, `local-contract`, `scoped-progress-mapping`,
`resume-receipt`, `instruction-anchor`, `task-order`

On every verified recovery, H7 uses the unique scoped local contract plus the
current local progress receipt and project proof, then verifies the same-scope
task/workline mapping and reconciles the latest user instruction. The first
user-facing update is H7's exact local opening line; detailed task, branch,
evidence, and return-point data remain available only to an explicit status or
diagnostic request.

The instruction, H7 receipt, task mapping, and project proof have separate
roles, not competing "latest" records. They must bind the same task, workspace,
owner session, task instance, package version, and current rule registry. A
mismatch fails closed and never exports cross-task progress.

## Workspace Isolation And Hot Update Recovery

Automatic continuation requires the same `workspaceKey`, task instance, and
current scoped H7 contract. Legacy, foreign-workspace, parallel, or stale
records remain readable only for explicit diagnosis; none may supply the
current task, next action, or completion claim.

Package/adapter refresh must not be represented as a generic degraded state.
When a long-lived MCP runtime identity is stale, use the same H7 CLI transport
for diagnosis and repair. A hot-update handover may rebind exactly one unique
contract only in one H7 transaction after all of the following are current and
verified:

- package/runtime identity and rule-registry hash;
- verified cwd, `SUPER_BRAIN_LOCAL_SESSION_ID`, unique current scoped contract,
  and exact v4 receipt-bound local progress sentence;
- current live project proof and scoped contract revision;
- CAS rebind result plus rebuilt hot index and activation receipt.

If uniqueness, identity, scope, proof, or derived-index reconstruction fails,
H7 withholds and reports the repair condition. It must not replay an old
contract, call a stale MCP current, or resume from a summary. After rebind,
validate the current local v4 receipt before declaring continuity restored.

## Latest Execution Contract

The execution contract records state and authorization; the v4 receipt records
the actual latest published progress. A new user instruction marks the contract
for reconciliation before mutation, but does not erase completed work or
replace the receipt. An inserted request is classified as `continue`,
`side_branch`, or `replace`; only an explicit replace can clear ancestry.

Missing, stale, foreign-task, version-mismatched, or conflicting contracts make
the next action unknown. Report that condition and repair it; never invent or
repeat a mutation from a stale contract. A visible assistant receipt cannot
clear `needsReconciliation` or refresh an unverified plan receipt.

## Canonical Active Checklist Additive Continuity

`decision_key`: `active-checklist-additive-continuity-v1`
`topic_key`: `active-checklist`, `additive-request`, `scope-replacement`,
`plan-recovery`, `continuation`

An accepted main checklist is durable task state, not a paraphrase of the most
recent user message. A later request is additive by default: preserve accepted
unfinished work, completed/pending states, and order across compaction,
interruption, side branches, and parent return. Only explicit user replacement
wording can remove items, and the contract records what was superseded.

Before a status, plan, next-step, or continuation response, reconcile the
current instruction with the accepted checklist and current work-line tree. A
checkpoint or memory card may locate work but cannot discard checklist items,
invent a replacement, or select a continuation anchor.

## Stage And Phase Gate

No automatic or visible phase/stage claim is valid without both a current H7
checkpoint or closeout receipt and live project proof for the claimed phase,
completed work, verification identifiers, and next action. Missing, stale, or
mismatched proof is `withheld`, not best-effort progress.

A forward formal stage transition additionally requires an H7-issued user
stage receipt bound to the same closeout receipt and local progress hash. Emit
the receipt directly; no Host readback or acknowledgement is required. After
every `passed`, `failed`, or `blocked` stage gate, send the user a
compact stage receipt before beginning the next phase: stage name/number,
status, concrete verification evidence, and next action. Never silently
advance a phase, infer Stage 10 from a field mutation, or let a side branch
bypass a same-workline closeout.

## Nested Work-Line Hierarchy

Branches are a bounded tree, not a flat task list. The active line can resume
only its nearest suspended parent; repeated `ResumeParent` calls move one level
at a time. Before continuing after a branch, show the main line, completed
line, unfinished/suspended lines, and the current ordered action. Do not label
a partial branch result as whole-task completion.
