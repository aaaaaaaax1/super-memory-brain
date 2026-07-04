# ORC Routing Route

ORC is a complexity gate, not the default answer path.

Use ORC when work has multiple domains, staged implementation, broad search,
verification risk, release risk, design plus code, or agent coordination.

Do not use ORC when the user asks for a small direct answer, simple code
snippet, ordinary explanation, or casual chat.

Route discipline:
- Select the smallest useful skill/tool set.
- Prefer existing project conventions.
- Avoid load-all-skills behavior.
- Use memory only when continuity or prior decisions affect correctness.
- Keep user-visible route narration short.

Known Phase 0b gap:
- `complex-multi-domain-orc`

## Single-Agent Subagent Workflow

For complex tasks that need delegated execution, investigation, tests, verification, audit, or evidence, ORC should prefer the single-agent internal workflow:

1. Controller writes a compact task card.
2. Executor subagent performs bounded work and returns a result card.
3. Reviewer/verifier subagent performs read-only checks when risk warrants it and returns an audit card.
4. Controller reviews cards, evidence, diffs, hashes, and validation results.
5. Controller decides accept/revise/blocked and records closeout evidence.

Read `references/single-agent-subagent-workflow.md` for the full schema. Do not default to cross-agent channel, inbox, wait, ack, or target-mode for subagent execution/review/verification. Use legacy Agent Bridge only for explicit channel/open/connect/send/read/close requests.

## Automatic Evolution Closeout

After a complex task closes, ORC should let the controller generate a learning candidate, result card, and optional audit card. Bounded automatic evolution is enabled by default but must pass the Ponytail gate in `references/automatic-evolution-policy.md`. Low-risk lessons can become package-local cold-reference/test improvements with rollback and validation. Global startup, hot path expansion, installed sync, hot-refresh, deploy, publish, secrets, destructive cleanup, and MCP registration are L4 hard-stop actions, not auto-applied.
