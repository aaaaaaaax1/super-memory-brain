# Agent Bridge Route

Legacy/manual-only compatibility: this route is not the default subagent execution, review, verification, or evidence workflow. Prefer `references/single-agent-subagent-workflow.md` for single-agent internal delegation.

Use only when the user explicitly asks to open, connect, send to, read from, or close an
`agent channel`, `subagent channel`, or `agent bridge`, including mixed
Chinese/English phrasing.

Compatibility behavior:
- Route to `agent_bridge_channel`.
- Open creates a fresh channel unless the user supplies a channel id.
- Do not launch nested host agents, explorers, workers, or helpers to open the
  channel.
- `WaitConnect` and `WaitInbox` idle means quiet waiting, not failure.
- After one reply, keep waiting until explicit close.

Default memory behavior: no durable memory write.

Known Phase 0b gaps:
- `agent-bridge-open`
- `zh-agent-bridge-open`
- `zh-agent-bridge-connect`
- `negative-agent-word-meaning`
- `negative-user-agent-zh`

Default collaboration note: channel mode is legacy/manual-only/compatibility and is not default workflow. Do not use WaitInbox, SendAndWait, or target-mode unless the user explicitly asks for channel communication.
