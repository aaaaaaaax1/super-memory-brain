# Legacy Writer Retirement

P5 classifies pre-control-plane paths so a compatibility artifact cannot become
a second source of current task truth.

| Entry | Classification | Current behavior |
| --- | --- | --- |
| `scripts/step-ledger.ps1` | forwarder | Writes a task/workspace-scoped ledger; task-only and global records are read-only migration inputs. |
| `scripts/session-compact.ps1` | forwarder | Writes bounded, task/workspace-scoped historical archive artifacts; they are non-authorizing. |
| `scripts/project-continuity.ps1` | retired-error | Read-only status explains the canonical owner; every former mutation fails closed. |

The current authorities are `execution-contract.ps1`, `checkpoint-writer.ps1`,
and `TaskStateStore`. Legacy global `task-graph.json`, `step-ledger.json`,
and `session-notes.md` are historical compatibility evidence only; no current
action, completion claim, or decision may be authorized from them.
