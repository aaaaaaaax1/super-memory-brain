# Work-Line Hierarchy Decision

## Problem

A confirmed plan can be lost when a newer user-approved plan is not committed
before a side branch starts. A flat branch list also makes a nested branch look
like the main line after compaction. The result is a plausible but stale resume.

## GitHub Evidence

- Temporal binds child creation to an initiation event, uses idempotent request
  identity, and rejects stale persistence mutations with expected record
  versions:
  [child initiation](https://github.com/temporalio/temporal/blob/c83faf5c4b07e38cb851ecf55a5f26662b45039d/service/history/workflow/mutable_state_impl.go#L6346-L6407),
  [conditional mutation](https://github.com/temporalio/temporal/blob/c83faf5c4b07e38cb851ecf55a5f26662b45039d/service/history/workflow/mutable_state_impl.go#L7497-L7524).
- LangGraph checkpoints use `thread_id` as the checkpoint primary key and carry
  `parent_config`, separating identity from parent history:
  [checkpoint base](https://github.com/langchain-ai/langgraph/blob/49ae27c2ae983cfb92091b0dea9f7bc37a716479/libs/checkpoint/langgraph/checkpoint/base/__init__.py#L145),
  [thread identity](https://github.com/langchain-ai/langgraph/blob/49ae27c2ae983cfb92091b0dea9f7bc37a716479/libs/checkpoint/langgraph/checkpoint/base/__init__.py#L182-L190).
- Prefect persists `parent_task_run_id` and reloads an existing subflow after a
  process restart to avoid duplicate child runs:
  [parent field](https://github.com/PrefectHQ/prefect/blob/60025750fb7ea1d69fef8a1c8b1e013cdc8149ae/src/prefect/client/schemas/objects.py#L625),
  [subflow reattach](https://github.com/PrefectHQ/prefect/blob/60025750fb7ea1d69fef8a1c8b1e013cdc8149ae/src/prefect/flow_engine.py#L902-L922).
- Microsoft Durable Task keeps orchestration replay deterministic, exposes
  `IsReplaying`, and treats sub-orchestrators as explicit children:
  [replay contract](https://github.com/microsoft/durabletask-dotnet/blob/883211a3a7ab0b55bb90b9c9e498148e4d65ead9/src/Abstractions/TaskOrchestrationContext.cs#L39-L63),
  [child orchestrator API](https://github.com/microsoft/durabletask-dotnet/blob/883211a3a7ab0b55bb90b9c9e498148e4d65ead9/src/Abstractions/TaskOrchestrationContext.cs#L320-L383).
  Its core runtime also rejects messages from an older execution generation:
  [execution generation check](https://github.com/Azure/durabletask/blob/5217032961abf45846f462732a5e2813316e3747/src/DurableTask.Core/TaskOrchestrationDispatcher.cs#L877-L963).

## Audit 1: Architecture

Adopt explicit task/workspace/session identity, direct-parent links, bounded
checkpoints, idempotent resume, and revision-bound plan receipts. Keep the
existing scoped execution contract as authority. Derive the user-facing tree
from its return stack; do not introduce a second task-tree database.

## Audit 2: Adversarial Failures

Hard-stop these cases:

- a prompt revision is newer than its accepted-plan receipt;
- a child tries to reopen an ancestor as another child, creating a cycle;
- a nested child tries to jump directly to the root instead of its parent;
- `continue` changes focus instead of retaining the active line;
- a visible assistant commitment attempts to bypass an unreconciled instruction;
- a return card or current plan no longer matches its canonical fingerprint;
- a foreign task, workspace, or root session is counted as current work;
- a stale checkpoint or memory record conflicts with current visible intent.

## Audit 3: Reverse And Minimality

Do not embed Temporal, LangGraph, Prefect, or an external service. Their useful
invariants fit in the existing atomic JSON contract. Keep `returnStack` as the
single ancestry authority, derive `lineage`, cap depth, store only fingerprints
in `planReceipt`, and keep this detail cold. This avoids new startup text,
network dependencies, background services, and duplicated mutable state.

## Accepted Contract

1. `lineage` is root-to-current and exposes depth, parent, child, role, status,
   and next action.
2. `ResumeParent` moves exactly one level upward.
3. `currentLineCount` includes only current scoped lineage plus retained
   unfinished lines.
4. Every non-observation `Set` writes a revision-bound `planReceipt`.
5. Prompt observation advances the contract revision but preserves the old
   receipt, forcing explicit reconciliation before mutation.
6. Mutation guards may bind the caller's observed revision and plan fingerprint;
   stale callers fail instead of reusing a same-name focus.
7. `continue` retains focus, `side_branch` pushes a non-ancestor, `ResumeParent`
   pops one level, and only `replace` clears ancestry.
8. Legacy contracts remain readable; the receipt hard gate applies after a new
   contract write opts into it.

## Canonical Plan Continuity Follow-Up

The hierarchy contract remains valid. Historical plan documents are retired
from the public source tree; current canonical-plan evidence is bound only to
the scoped execution contract and its verified state-root source receipt.

This follow-up does not introduce a second task tree or plan database. The
execution contract remains authoritative; state cards, pointers, hot indexes,
checkpoints, snapshots, and summaries remain non-authoritative projections.

The follow-up was subsequently challenged by two independent reverse audits.
The accepted refinement keeps the same architecture but moves mandatory
structural CAS/idempotency, pending-instruction preservation, pointer/lifecycle
binding, minimum projection integrity, and terminal plan sealing into Phase 1.
Canonical membership/order/status, approval-scoped mutation, branch binding,
and canonical-main-first output enter in Phase 2. Full evidence binding remains
Phase 3 and full performance/failure-matrix enforcement remains Phase 4.

No local work package, compact summary, state card, checkpoint, pointer, or
memory result may promote itself into the canonical main plan. Legacy state may
be located for reconciliation, but missing current identity bindings make it
non-authorizing rather than silently discarded.
