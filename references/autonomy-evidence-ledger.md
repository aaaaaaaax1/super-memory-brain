# Autonomy Evidence Ledger

Purpose: measure governed autonomy from auditable records without treating a
completed task, a score input, or a closed correction as proof by itself.

## Countability

`autonomy-evidence-ledger.ps1` is a cold audit path. It never runs during a
normal prompt and does not add anything to the global bootstrap.

It derives three counts for the current workspace and package version:

- `verifiedRealWorldTasks`: a task-scoped `verified-task-outcome` record with
  verified user-path acceptance, task-specific guards, a completed checkpoint
  emitted by `task-verification.ps1`, package/hot-refresh verification, and no
  raw prompt or summary.
- `verifiedAutonomyScenarios`: a qualifying real-world task that also has a
  hash-matched `governed-autonomy-authorization` record from a threshold
  approved plan. A completed checkpoint alone never qualifies.
- `closedCorrectionLoops`: a closed correction candidate whose immutable link
  points to one qualifying real-world outcome for that same candidate and
  workspace.

Legacy cards, generic completed checkpoints, unlinked corrections, caller
supplied counts, foreign workspace records, version-mismatched records, and
privacy-invalid records count as zero.

## Writers

- `autonomous-executor.ps1` writes an authorization only after its hard gate
  passes and an approved-plan checkpoint exists.
- `task-verification.ps1` writes one compact outcome record after matching
  completion succeeds. It stores only flags, IDs, hashes, and file references.
- `reflection-promotion.ps1` can link a newly closed correction only when it
  finds exactly one matching qualified outcome.

These records remain local state. They make the package's internal acceptance
metrics auditable; they do not create an objective intelligence score or defend
against deliberate local state tampering.
