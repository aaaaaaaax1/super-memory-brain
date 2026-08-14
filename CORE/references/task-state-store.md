# TaskStateStore

Purpose: provide one deep task-state interface across current context,
checkpoints, and shared task cards without replacing their compatibility files
in one risky migration.

## Interface

- `Commit`: stage a compatibility payload, append a `prepared` WAL event,
  atomically materialize the compatibility file, append `committed`, and update
  the projection. This is the normal writer path.
- `CompleteTask`: validate the current execution contract, plan fingerprint,
  owner session, workspace, package version, and immutable task verification;
  its evidence binding must also match the current source tree and the exact
  verification artifact hash. Then close every task-owned active surface in one
  recoverable transaction.
- `CommitContinuity`: advance a bound active execution contract together with
  its task-scoped current context, route checkpoint, and compatibility
  pointers in one recoverable transaction. The caller stages read-only
  previews first; the WAL publishes derived files before the new contract and
  updates the task projection only after every hash verifies. A crash leaves a
  `prepared` transaction that `Reconcile -Apply` can replay without selecting a
  partial plan or route as current.
  A formal same-line phase advance also requires the prior phase's compact
  closeout receipt: one real user-path artifact and one counterexample artifact,
  both task/session/version/revision/plan-fingerprint bound and SHA-256 checked.
  Missing or altered evidence rejects the transaction before WAL prepare.
- `CommitActiveBundle`: register an active checkpoint, its shared task card,
  and the active-checkpoint compatibility pointer in one recoverable
  transaction. Session, agent, and task-link indexes remain derived post-commit
  surfaces. A partial start cannot become an independently current checkpoint
  or task card; recovery replays the original bundle and revision.
- `Record`: legacy/import-only metadata indexing for an already materialized
  compatibility file.
- `Get`: read one task projection by `taskId`.
- `Audit`: compare compatibility pointers and report conflicts without merging.
- `Rebuild`: deterministically reconstruct projections from append-only events;
  dry-run unless `-Apply` is supplied.
- `Reconcile`: find incomplete prepared transactions and finish only those
  whose staged payload and expected revision still verify; dry-run unless
  `-Apply` is supplied.
- `ReconcileAmbiguousState`: classify legacy completion conflicts and lost
  authority without inferring completion. Safe tasks are quarantined through
  independent WAL transactions; cross-workspace identity conflicts, shared
  sources, pointers, hot-index references, and incomplete WAL remain blocked.
  Dry-run unless `-Apply` is supplied.
- `Compact`: identify per-task journals over the event/byte limits, archive the
  old segment, and restart from a replayable metadata-only snapshot; dry-run
  unless `-Apply` is supplied. Journals with incomplete transactions are never
  compacted.
- `Import`: index existing scoped files without changing them; dry-run unless
  `-Apply` is supplied.

`Commit -ExpectedRevision N` is compare-and-swap. A stale revision fails before
WAL prepare. Calls without an expected revision still serialize through the
store mutation lock and assign a monotonic revision. Fault-injection tests cover
crashes after prepare and after materialization.

## Data Shape

Events are split by task under `workspace/task-state-store/events`. They contain
only transaction/identity, revision, entity kind, source path, hash, bounded
owner/lease metadata, status, and timestamp. They do not copy task bodies,
prompts, memory text, or evidence payloads.

The append-only journal is the durable authority and projections under
`workspace/task-state-store/projections` are its canonical read model.
Checkpoint, context, task-card, route-lock, contract, and compatibility-pointer
files are materialized projections; they do not independently decide lifecycle.
`index.json` is a bounded 500-task lookup view.
Archived event segments and replayable snapshots live under `archive` and
`snapshots`; compaction never deletes the original segment.

Ambiguous evidence manifests and byte-preserving source copies live under
`quarantine/ambiguous-state`. A `quarantined` lifecycle is a non-completion
disposition: it clears wakeable task surfaces, records a transaction and
manifest hash, and cannot authorize a completion claim or normal task write.

## Completion Rule

`CompleteTask` is the only normal terminal transition. `Commit` and
`task-register.ps1` reject `completed`, `verified`, `cancelled`, and `archived`
payloads before they can bypass the completion transaction. A user-visible
completion claim is authorized only when `completion-guard.ps1` observes the
same task's canonical projection in `completed`, both completed checkpoint and
task card, no active context, and no incomplete WAL transaction. Task-scoped
runtime drift evidence wins over any foreign global compatibility pointer.

For active work, a bound execution-contract revision is never authoritative by
itself once a bound current context exists. `CommitContinuity` owns the
contract-to-context-to-route handoff. A missing or non-authorizing locator
context stays on the compatibility path and cannot silently gain task
authorization. The execution hot index is a rebuildable cache after the WAL
commit, never a lifecycle authority.

## Evidence Version Binding

Completion evidence is a single tuple carried from the task verification through
the completion manifest, WAL event, projection lifecycle, and terminal plan seal:
`packageVersion`, source-tree (`gitTreeHash`) identity, `taskId`, `workspaceKey`,
`ownerSessionKey`, and the SHA-256 of the immutable task-verification artifact.
The source-tree calculation runs only on explicit verification, completion, and
recovery paths; it never runs in the prompt hot path. Git worktrees bind the
committed tree plus current working changes; portable installs use the equivalent
shareable-content fallback.

Records without this binding are historical. They remain readable for audit but
cannot authorize completion, autonomy evidence, or recovery. A prepared WAL
completion rechecks the artifact and source-tree binding before materializing any
remaining commands, so a changed artifact or code tree stays blocked instead of
being replayed as completed.

## Identity Rule

Different task IDs are never merged. If `current-task-context.json` and
`active-checkpoint.json` identify different tasks, `Audit` returns `conflict`,
both projections remain independent, and `merged=false`.

## Migration

P1 is staged-command materialization: existing files remain compatible while
their writers call `Commit-SuperBrainTaskState`. `Sync-SuperBrainTaskState` is
kept only for bounded legacy import. Reconcile and compaction run on maintenance
cold paths, so startup and ordinary prompts do not pay their cost. Once readers
consume projections and replay verification has been stable across releases,
compatibility pointers may become read-only projections in a later phase.
