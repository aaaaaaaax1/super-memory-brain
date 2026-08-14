# Status And Recovery Route

Super Brain is an independent H7 control-plane Agent. This document describes
its recovery contract; it does not create a second state store or a host-side
continuation policy. The current H7 scope, execution contract, visible-progress
receipt, and live project proof remain the authoritative control plane.

## Authority Split

The records below have different jobs and must never substitute for one
another:

1. The latest user instruction controls the objective, authorization, stop,
   replace, and priority decision. It is never a progress anchor and cannot
   select, truncate, or rewrite the latest assistant progress.
2. The time-latest real assistant reply still visible in the current thread
   locates where continuation begins. It is never sufficient by itself to claim
   the task, phase, step, completed work, or next mutation.
3. The scoped execution contract stores the mapped task state, canonical plan,
   work-line tree, and permitted action. It cannot select a visible locator by
   itself, but it is valid current-state evidence after H7 has mapped that
   locator to exactly one same-scope workline.
4. Live project evidence and the H7 project-progress proof establish project
   facts and actual completed work. A stale proof is not evidence of current
   progress.
5. A strict H7 v4 durable visible-progress receipt validates the current
   locator when it is present; it never causes H7 to scan backward and select an
   older reply. Memory, summaries, handoffs, checkpoints, tool narration, and
   collaborator reports are supplemental evidence only. They never replace the
   current visible locator.

## Visible-First, Mapping-Second Continuation

For the same main workline, compaction, pause-after-continue, restart, model
switch, rebind, and user correction, H7 first reads the current thread's
**time-latest real assistant reply still visible in the visible context**. That
is `current_visible_assistant`: it answers only **where to resume looking**.
It is not a task selector and cannot, by its wording alone, decide what work was
actually completed.

When the Host has already injected the exact current visible tail into the
agent context, the adapter derives one bounded `codex_visible_context`
observation without a thread read. Otherwise it reads the current thread tail
once and supplies one bounded host-derived `visible_progress_assertion`, never
raw thread text or Host identities. If it has no already-exposed current-tail
observation, it may make exactly one bounded
`read_thread(turnLimit=1, includeOutputs=false, maxOutputCharsPerItem=480)`
read and one `turnLimit=2` retry only when no actual assistant candidate is
returned. It does not scan the conversation, project tree, summaries,
contracts, checkpoints, memory, user messages, or older receipts to find a more
convenient replacement. This transport cannot cryptographically attest a
caller-supplied assertion, so the adapter must derive it from current
Host-visible context or the bounded fallback read, and H7 must still validate
scope and receipt binding. A process-local
cache/lease, old contract, checkpoint, summary, memory, or old receipt is never
a locator substitute. If the Host cannot provide a current observation, H7 withholds the
governed action and repairs the evidence path; a timeout never proves that
prior visible context is unavailable.

### Two-Stage Resume Decision

1. **Locate.** Select only the time-latest actual `agentMessage` currently
   visible in this thread. A newer ordinary message remains the locator; H7
   must not walk backward to an older v4 receipt.
2. **Map and verify.** Starting from that locator, H7 maps it to exactly one
   same-scope task/workline using current scope identity and then uses the
   current contract plus live project evidence to establish the actual phase,
   step, completed work, pending work, and allowed next action. A missing,
   ambiguous, foreign, or evidence-conflicting mapping does not silently choose
   an older task; it enters reconciliation before mutation.

This is deliberately one-way: the visible reply locates the resume point;
current task state and project proof explain what that point means. An old
summary, old contract, old checkpoint, memory record, or old receipt cannot
replace the locator, but a current same-scope contract and current project proof
are required to interpret it accurately.

### Candidate Classes And Ordinary Continuity

`latest_durable_assistant` only validates whether the same current locator has
the strict v4 prefix in its first three non-empty lines:

```text
G1
[H7-PROGRESS-V4 receipt_hash=<64 lowercase hex characters>]
<one compact progress sentence>
```

Later evidence is display-only and never changes the binding. A strict v4
candidate becomes durable progress only when its hash, exact sentence, scope,
and live project proof are current. A plain current reply remains
display-only continuity evidence: it may be the correct normal continuation
starting point, but it cannot itself claim a phase, completed work,
authorization, or a formal stage transition.
Strict v4 validation is required for a durable progress/phase/completion claim
and for a forward formal stage transition.

When mapping finds no active task, H7 performs **ordinary no-task continuity**:
it keeps the current visible reply as the continuity point and responds normally
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

A state card is an exceptional recovery selector, not a normal same-workline
readback or synchronization record. Normal same-workline continuation,
compaction, pause-and-resume, and restart keep the current visible locator in a
transient H7 receipt binding only: they do not persist a visible-readback/state
card or perform a per-turn state-card CAS. A state card may select a workline
only in two cases:

1. H7 has proved that this current session truly cannot read its prior visible
   context after the bounded current-thread read and retry have completed with a
   structured unavailable result; or
2. H7 has verified an approved `parent_return` to another approved workline and
   selects the already-approved parent workline.

A skipped read, timeout, slow response, missing attempt, stale hot index, or
old receipt is **not** proof that visible context is unavailable. Those cases
withhold the governed action and repair the evidence path; they never authorize
a state-card fallback. A same-process cache or lease is likewise not a fallback.
The state card can never override a same-workline current visible locator.

### Drift Diagnosis And Repair

`latest_assistant` is reserved for detected drift diagnosis only. It may
describe a mismatch, but never selects normal continuation or auto-mutates a
contract. On drift, H7 must: (1) map the current visible locator to the latest
same-scope task state and live project evidence, (2) prevent a duplicate or
already-failed action, (3) correct the current visible/scoped state, (4) repair
the root cause, and (5) replay the same path before declaring success.
Auto-alignment remains an emergency-only guard, never the normal route.

`brain_cli.py turn-runtime` is the same H7 transport when the registered MCP
is unavailable or stale; it is not a degraded continuation mode. If neither
transport can return a current scoped H7 receipt, return
`H7_RUNTIME_UNAVAILABLE` and repair before governed work resumes.

## Resume Receipt

After a verified interruption, compaction, disconnect, model switch,
cross-session rebind, explicit resume of a suspended workline, or verified
child return, emit one compact user-visible continuity receipt before mutation.
Its first line is H7's exact recovery presentation of the current visible
locator. The receipt then states the result of the same-scope mapping, rather
than treating the locator sentence itself as the task state:

- `已接上：` followed immediately by the exact time-latest real assistant
  sentence visible in the current thread;
- `定位：` that same sentence and its display/durable classification, never a
  user message or summary;
- `映射：` the verified task/workline plus actual phase, step, and completed or
  pending work derived from current H7 state and live project proof;
- `下一步：` the action authorized after that mapping and reconciliation with
  the latest user instruction.

Presentation correctness is part of the receipt contract:

- Separate completed historical phases from the active mapped phase. A previous
  accepted phase is not evidence that it is currently executing.
- Include compact evidence with the H7 receipt/proof identity and a return
  point with the nearest suspended parent or `none`.
- When `actionAuthorization=withheld`, say that the current action is to
  reconcile the latest user instruction and repair the missing mapping/proof.
  Do not expose, imply, or execute an older action just to complete a receipt.
- A clearly labeled checkpoint-only state may be shown for diagnosis, but it
  cannot authorize continuation or be presented as a verified resume receipt.
- When the current tail is plain prose, acknowledge it exactly as display-only;
  do not pretend it is an older v4 sentence, a stage claim, or project proof.

The acknowledgement is event-bound, not wording-bound. It appears exactly once
on the first visible update only when H7 has a scope-bound recovery event or a
verified child-return receipt. A bare `continue`, ordinary continuous turn,
status reply, progress update, greeting, or independent request does not emit
`已接上：`.

Do not claim durable progress from vague memory. If the exact current locator,
same-scope task/workline mapping, current project proof for a progress claim,
or authorized next action cannot be established, withhold before mutation and
repair the evidence path.

## Emergency Drift Reconciliation

Automatic alignment is an emergency-only guard after H7 detects a current-tail
mismatch. It is not a normal continuation path and it must not hide a broken
publication or rebind flow.

The guard may use only a current-thread, same-scope, strict v4 durable envelope
that H7 has verified against an issued receipt. It detects the mismatch but
never writes, realigns, or promotes the observed sentence into the contract.
It returns `H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED`. The controller
must perform an explicit H7 checkpoint with fresh live project proof and then
publish a fresh v4 receipt before continuing. The fallback may not accept
caller-provided state, advance a stage, change a work-line, alter authorization,
or turn a user-attested message into normal progress.

`user_attested_visible_reply`, plain assistant commentary, a legacy H7 marker,
and an old contract remain reconciliation clues only. They can block an unsafe
walk-back to old progress, but cannot be auto-promoted. Only the explicit H7
checkpoint can publish a new strict v4 receipt; that new receipt must then pass
the same normal current-thread replay before work continues.

## P0 Continuity Priority Invariant

`decision_key`: `resume-visible-locator-then-scoped-progress-mapping-v2`
`topic_key`: `continuation`, `visible-locator`, `scoped-progress-mapping`,
`resume-receipt`, `instruction-anchor`, `task-order`

On every verified recovery, the first user-facing update begins from the exact
time-latest real assistant reply visible in the current thread, then states the
verified same-scope task/workline mapping and only then reconciles the latest
user instruction. The first response is a concise proof of connection: task
instance, active main line or branch, actual mapped phase/step, verified
completed/pending work, evidence, and return point.

The instruction, visible locator, H7 receipt, task mapping, and project proof
have separate roles, not competing "latest" records. The user instruction
controls what may happen next; the visible locator identifies where the resume
check starts; the H7 receipt, current contract, and project proof establish what
actually happened. They must bind the same task, workspace, owner session, task
instance, package version, and current rule registry. A mismatch fails closed
and never exports cross-task progress.

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
- Host thread/session scope, workspace key, task instance, and exact v4
  receipt-bound progress sentence;
- current live project proof and scoped contract revision;
- CAS rebind result plus rebuilt hot index and activation receipt.

If uniqueness, identity, scope, proof, or derived-index reconstruction fails,
H7 withholds and reports the repair condition. It must not replay an old
contract, call a stale MCP current, or resume from a summary. After rebind, run
the same bounded current-thread v4 replay before declaring continuity restored.

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

A forward formal stage transition additionally requires a Host-read-back user
stage receipt that H7 binds to the same closeout receipt and visible-progress
hash. After every `passed`, `failed`, or `blocked` stage gate, send the user a
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
