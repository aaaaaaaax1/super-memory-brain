# TaskStateStore

Purpose: provide one deep task-state interface across current context,
checkpoints, and shared task cards without replacing their compatibility files
in one risky migration.

## Interface

- `Commit`: stage a compatibility payload, append a `prepared` WAL event,
  atomically materialize the compatibility file, append `committed`, and update
  the projection. This is the normal writer path.
- `Record`: legacy/import-only metadata indexing for an already materialized
  compatibility file.
- `Get`: read one task projection by `taskId`.
- `Audit`: compare compatibility pointers and report conflicts without merging.
- `Rebuild`: deterministically reconstruct projections from append-only events;
  dry-run unless `-Apply` is supplied.
- `Reconcile`: find incomplete prepared transactions and finish only those
  whose staged payload and expected revision still verify; dry-run unless
  `-Apply` is supplied.
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

Projections under `workspace/task-state-store/projections` are rebuildable views,
not a second source of task truth. `index.json` is a bounded 500-task lookup view.
Archived event segments and replayable snapshots live under `archive` and
`snapshots`; compaction never deletes the original segment.

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
