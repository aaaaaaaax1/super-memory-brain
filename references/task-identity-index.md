# Task Identity Index

Second-hop reference for `references/status-recovery.md` only. Do not load from
`references/index.md` directly.

Use when task status, current progress, or cross-session continuation is unclear
after visible context and the primary status route.

Read order:
1. Current visible conversation and host todo/checkpoint.
2. `memory/shared/tasks/active/*.task.json` and `memory/shared/tasks/paused/*.task.json`.
3. `memory/shared/sessions/*.session.json` for session name and shortened id.
4. `memory/shared/agents/*.agent.json` only when the user asks about a specific agent.
5. Legacy `memory/workspace/active-checkpoint.json`, `step-ledger.json`, and `status-card.json`.

Rules:
- Unknown session or agent means `unknown`, not `no task`.
- Do not bulk-import old sessions without explicit dry-run approval.
- Use `scripts/task-index.ps1 -Json` for read-only lookup.
- Use `scripts/task-register.ps1` only for explicit status registration/update.
- Keep output compact: current task, progress, stop point, next action, waiting state.