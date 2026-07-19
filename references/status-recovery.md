# Status And Recovery Route

Current visible context wins. Use this order:

1. Current user message and visible conversation tail, including the latest
   assistant commitment.
2. Current task execution contract when compression/disconnect removed the
   visible tail.
3. Current plan, checklist, phase checkpoint, or recent tool output.
4. Active task index or status card.
5. Lightweight Super Brain state.
6. Summary recall.
7. Deep recall only when the user explicitly references a previous or another
   session and lighter state is insufficient.

## Resume Receipt

After an interruption, compaction, disconnect, model switch, or task handoff,
emit a compact user-visible continuity receipt before taking the next action:

- `已接上：` the task and package/version currently being resumed;
- `上次最后一句：` a short quote of the latest visible user or assistant
  sentence/commitment, or a clearly labeled summary when only a checkpoint is
  available;
- `当前状态：` the phase and newest verified evidence;
- `下一步：` the one action authorized by the latest instruction.

Do not claim continuity from vague memory. If the latest sentence, task
identity, or authorized next action cannot be established, say that it is
unknown and ask for confirmation before mutation. Keep the receipt compact; do
not replay a transcript or inject it into every ordinary turn.

## Workspace Isolation

- Automatic continuation requires a matching `workspaceKey`, derived as a stable fingerprint instead of storing the raw workspace path in continuity cards.
- A scoped current-task context selects its matching scoped checkpoint before the compatibility pointer.
- Legacy unscoped, stale, foreign-workspace, or parallel checkpoints remain available for explicit task-id recovery but must not supply the current task, next action, or completion evidence automatically.

When current context and active checkpoint disagree, run
`scripts\task-state-store.ps1 -Action Audit -Json`. Report both task IDs and
keep them separate; a compatibility pointer is not authority to merge tasks.
Use `references/task-state-store.md` only when revision, replay, or migration
details are needed.

Task status is not system health. For `task status`, `where are we`, `next
step`, or `continue`, answer the current work first. Do not run doctor, CI, or
package verification unless the user asks for system health or the current task
requires it.

## Latest Execution Contract

Phase/status and the latest execution commitment are separate state. A
checkpoint answers where the task is; `scripts/execution-contract.ps1` answers
what the latest user instruction and assistant commitment authorize next.

- A visible conversation tail always wins.
- After compression or disconnect, use the current task contract before a phase
  checkpoint.
- A new user instruction marks the contract pending reconciliation. Do not
  continue the old mutation until the assistant writes the updated focus,
  constraints, invalidated work items, and acceptance criteria.
- For an inserted request, classify it before mutation: `continue` keeps the
  current task, `side_branch` saves a bounded parent return card, and `replace`
  explicitly supersedes the parent. When intent is unclear, default to
  `side_branch`; after the branch, run `execution-contract.ps1 -Action
  ResumeParent` instead of starting an unrelated task.
- Missing, stale, foreign-task, version-mismatched, or conflicting contracts
  make the latest action unknown. Report status from the checkpoint if useful,
  but ask for confirmation instead of inventing or repeating work.

## Multi-Line Task Closeout

When a main task has inserted branches, completing one branch is not completion
of the whole task. Before continuing, emit one compact work-line list derived
from visible state and `execution-contract.ps1`:

- main line;
- line completed now;
- unfinished or suspended lines;
- next line and why it has priority.

The latest explicit user priority wins. If the user did not choose a line,
resume the nearest suspended parent with `-Action ResumeParent`. Use the
bounded `workLineStatus` and visible checklist/checkpoint; do not scan deep
memory or replay the transcript merely to build this list. Never label a
partial branch result as whole-task completion.

Known Phase 0b gaps:
- `current-task-status`
- `zh-task-status`
- `zh-where-now-status`
- `continue-previous-task`
- `zh-continuation-last`

Second-hop only: if task identity remains unclear after this route, read
`references/task-identity-index.md`; do not load it from the index directly.
