# Status And Recovery Route

Current visible context wins. Use this order:

1. Current user message and visible conversation.
2. Current plan, checklist, checkpoint, or recent tool output.
3. Active task index or status card.
4. Lightweight Super Brain state.
5. Summary recall.
6. Deep recall only when the user explicitly references a previous or another
   session and lighter state is insufficient.

Task status is not system health. For `task status`, `where are we`, `next
step`, or `continue`, answer the current work first. Do not run doctor, CI, or
package verification unless the user asks for system health or the current task
requires it.

Known Phase 0b gaps:
- `current-task-status`
- `zh-task-status`
- `zh-where-now-status`
- `continue-previous-task`
- `zh-continuation-last`

Second-hop only: if task identity remains unclear after this route, read
`references/task-identity-index.md`; do not load it from the index directly.
