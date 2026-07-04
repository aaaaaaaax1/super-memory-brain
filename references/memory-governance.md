# Memory Governance Route

Mode defaults:
- `memory:auto`: retrieve/write only when keyword or semantic continuity needs it.
- `memory:force`: user explicitly asks to remember or recall; privacy still wins.
- `memory:off`: no proactive retrieval or durable writes.

Write only compact durable facts:
- Stable preference.
- Accepted decision.
- Current task state, blocker, next action.
- Reusable workflow that was verified.

Never store:
- API keys, tokens, passwords, cookies, bearer strings, or private credentials.
- Raw transcripts, full payloads, full SSE streams, base64 blobs, or long logs.
- Guesses, noise, rejected variants, or stale conflicts.

Conflict order: latest user instruction, live files, verified tool output,
current checkpoint, governed memory, older summaries.

Known Phase 0b gaps:
- `privacy-api-key-memory`
- `stable-preference-memory`
- `zh-memory-privacy-api-key`
- `zh-memory-preference`
