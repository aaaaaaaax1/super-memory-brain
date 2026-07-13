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

## Bounded Memory Lifecycle

Long-term memory uses a bounded budget from `memory-policy.json` rather than
growing without limit. The lifecycle budget covers total lines, total
characters, and per-layer line quotas for profile, project, decision, task,
and session memory.

- `memory-health.ps1 -Json` reports current usage, utilization, layer counts,
  retention windows, and whether new writes are allowed.
- `write-memory.ps1` rejects a write that would exceed the global or layer
  budget. A warning near the limit is allowed, but the warning must be visible
  to maintenance and optimization checks.
- `auto-hygiene-runner.ps1` may archive exact duplicates and explicitly expired
  records when `-ApplySafe` is used. It only plans stale/history and budget
  overflow actions; current verified memory is never silently deleted. After a
  physical rewrite it rebuilds the Sandglass, SQLite FTS, Shadow Sand, and
  graph line-number projections while preserving mapped trust and tag metadata.
- Budget overflow requires a reviewed, evidence-preserving archival decision.
  Archive originals before any confirmed rewrite and keep recall pointed at
  current, verified, in-scope records.

Memory quality is therefore measured by usable, current evidence rather than
raw record count. Compression and archival must not turn old context into a
current fact or allow a stale record to override live evidence.

Conflict order: latest user instruction, live files, verified tool output,
current checkpoint, governed memory, older summaries.

## Memory Consolidation And Verified Writeback

`topic_key`: `memory-consolidation-verified-writeback`  
`decision_key`: `canonical-memory-replacement`

- Before writing, retrieve the canonical memory for the same `topic_key` or
  `decision_key`.
- When an active canonical memory already exists, update it, merge its evidence,
  or replace it. Do not append a duplicate, near-duplicate, or wording-only
  variant.
- When a new conclusion overturns an older one, mark the older record
  `superseded`, link it to the new canonical record, and exclude it from default
  decisions.
- Keep one active conclusion per topic in hot memory. Keep raw logs, long
  conversations, temporary experiments, and obsolete proposals only in a cold
  path or evidence index.
- Do not claim a rule or memory was written until the target file was changed on
  disk and verified. Verification records the file path, rule title,
  `topic_key` or `decision_key`, change result (`added`, `updated`, or
  `replaced`), and file modification time.
- Do not promote unverified inference to canonical memory. Record verification
  status, evidence source, and applicability boundary.
- New verified evidence outranks older memory. Older memory never overrides the
  current source, current logs, or the latest explicit user instruction.

Known Phase 0b gaps:
- `privacy-api-key-memory`
- `stable-preference-memory`
- `zh-memory-privacy-api-key`
- `zh-memory-preference`

## Recall Trigger Decision Ladder

Use the smallest deterministic route that can answer correctly:

1. A configured workflow phrase maps directly to its `decision_key`. Perform
   an exact current-and-verified decision lookup; do not use generic semantic
   search for the response contract.
2. Explicit remember/recall, prior-session, accepted-decision, or user-profile
   wording may use bounded semantic recall after checking visible context and
   current task state.
3. A current-session continuation uses visible context, checkpoints, and recent
   tool results first. Long-term memory is supplemental.
4. Ordinary chat or a common word such as `git`, `model`, `agent`, or `memory`
   by itself does not justify broad recall.

Normalize Unicode width, case, whitespace, and punctuation before workflow
phrase matching. Use configured aliases only inside the same intent family.
Never let a loose keyword override a more specific negative case or the user's
current wording.

Every injected memory must satisfy all applicable gates: source exists, record
is `[CURRENT][VERIFIED]`, scope matches, no active conflict exists, and the
record is not stale or superseded. Missing or conflicting canonical state is a
hard stop for memory claims: report the missing evidence instead of completing
the answer from model memory.

## Canonical Workflow Preference Recall

- A terse request that matches a configured reusable workflow phrase is a
  `memory:auto` recall trigger even when it does not say "remember" or
  "recall".
- Store the phrase-to-decision mapping in `memory-policy.json`; keep the
  canonical response contract in the single current memory decision rather
  than copying it into global startup instructions or a second hot rule.
- Perform one bounded lookup, accept only the `[CURRENT][VERIFIED]` canonical
  result for the configured `decision_key`, and answer in that contract's
  requested format. Use `decision-search.ps1 -Key <decision_key> -CurrentOnly`
  for this deterministic lookup. Do not substitute a generic template when the
  canonical result exists.
- If the configured canonical record is missing, stale, conflicting, or cannot
  be verified, say so plainly instead of claiming to remember its format.
