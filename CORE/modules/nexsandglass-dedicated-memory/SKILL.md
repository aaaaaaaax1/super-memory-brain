---
name: nexsandglass-dedicated-memory
description: "Internal Super Brain memory backend and provenance module. It is never an independent host skill or MCP route; Super Brain decides recall/write policy and invokes only the bounded native memory procedure."
---
## Ownership Boundary

This module is package source, not a separately installed host entry. The only host-facing entry is `super-memory-brain`; the package root and H7 runtime own routing, authorization, continuity, privacy, and writes. Keep this module as vendored implementation/provenance and invoke it only through Super Brain-native memory contracts.

Memory root convention: the resolved Super Brain shared root is the only live read/write target. Concurrent agents are separated by task, workspace, and session provenance in that one store, not by host-specific databases. Legacy `%USERPROFILE%\.neurobase`, `<package-root>/memory-zcode`, `<package-root>/memory-codex`, `<package-root>/memory-<agent-name>`, agent roots, and group roots are read-only migration sources only.

Memory policy: Super Brain owns one `private-state/shared` authority. When durable memory must not be used for a turn, use `memory:off`; never create a host-, agent-, group-, or project-specific replacement root.


# NexSandglass Backend (Super Brain Internal)

Use NexSandglass only as the local storage/search implementation behind Super Brain H7. It is not a replacement for the control plane, a host route, a second MCP, or an authorization source.

## Roles

- `super-memory-brain`: sole host-facing control-plane entry and route owner.
- H7/core rules: decide scope, authorization, continuity, privacy, and durable writes.
- `nexsandglass-dedicated-memory`: bounded backend for plaintext storage, search, decision particles, and derived indexes.

Precedence:
1. Latest user instruction.
2. Live files and verified tool output.
3. Explicit project memory / G1 state.
4. NexSandglass search results.
5. Older summaries or model memory.

## Source and State Paths

- Vendored source: `<package-root>\vendor\NexSandglass-Agent-DedicatedMemory`
- Active state: `<package-root>\private-state\shared`
- Compatibility path: `<package-root>\memory` (junction only; never a second authority)
- Runtime entry: `<package-root>\runtime\brain_mcp.py` or the equivalent H7 CLI; do not start a standalone Sandglass MCP.

The runtime supplies `NEXSANDBASE_HOME` from the verified active memory root. A legacy `%USERPROFILE%\.neurobase` path is migration evidence only and must not become active.

## Safe Memory Rules

Write only compact durable facts that help future work:
- accepted user preferences and stable rules;
- important decisions and why they were accepted;
- reusable workflow recipes;
- project milestones, blockers, and next actions.

Never write:
- API keys, tokens, passwords, cookies, private credentials;
- raw base64, full payloads, complete responses, full SSE streams, full image reference objects;
- huge logs, temporary debug dumps, rejected drafts, or sensitive personal data unless explicitly required.

NexSandglass stores plaintext. Treat it as local durable memory protected by OS-level disk security, not as a secret store.

## Default Memory Write Policy

System shortcut: `G1审记，ORC调度，沙漏只存稳态；不存秘密、噪音、猜测、长原文。`

Use this compressed policy for every new message or stable decision:

1. Let `plusunm-g1` decide whether the fact is durable enough to keep.
2. Let `skill-orchestrator / ORC` decide whether NexSandglass is needed at all.
3. Write to NexSandglass only when the fact is one of these:
   - stable user preference;
   - accepted rule or baseline;
   - important decision or rollback point;
   - reusable command, path, or workflow;
   - blocker, milestone, or verified result.
4. Do not write transient chat, guesses, noise, secrets, or long raw output.
5. If uncertain, do not write yet; wait for confirmation or later acceptance.
6. When a user says a rule is accepted or asks to remember it, write the shortest durable form and avoid duplication.

## Memory System Add-ons

### 1. Retrieval Triggers

Search NexSandglass only after the short memory router decides recall is useful. Use keyword + semantic triggers.

Keyword triggers:
- `之前`, `上次`, `以前`, `记得吗`, `还记得吗`, `另一个会话`, `别的会话`, `上一轮`, `改到哪`, `进度`, `查一下记忆`, `查沙漏`, `查 G1`, `我的偏好`, `历史`, `这个项目`, `继续`.

Semantic triggers:
- the user implies continuity without exact keywords, such as `按我的习惯来`, `照之前方案继续`, `还是那个项目`, `接着做`, `按已有约定`;
- the user asks whether you know/remember another session, prior work, accepted rules, package state, or Super Brain progress;
- the task depends on accepted rules, long-term preferences, old decisions, or project history;
- current context is insufficient but old local memory likely contains the answer;
- resuming a high-context project or checking whether a route was accepted before.

Confidence gates:
- high confidence (`>= 0.6`): inject a concise memory packet.
- medium confidence (`0.2..0.6`): inject only summaries/titles.
- low confidence (`< 0.2`): do not retrieve memory正文.

Default retrieval stays small: `top_k=3`, `max_tokens=1200`, summary-first.

If one of these triggers appears, do not answer from vague memory first. Search explicit memory/NexSandglass, then answer with evidence or say what is missing.

### 2. Write Triggers

After G1 approves durability, write NexSandglass when:
- the user says: `记住`, `以后都`, `默认`, `采用`, `就这个`, `按这个来`;
- an install, repair, configuration, migration, or workflow is verified;
- a command/path/process becomes reusable;
- an A/B route, baseline, rollback point, milestone, blocker, or verified result matters later.

### 3. Dedup And Update

Before writing a durable rule, search related keywords first. If similar memory exists:
- do not duplicate the same sentence;
- prefer the newest accepted user instruction;
- mark old conflicting rules as stale in the new short note;
- keep only the shortest durable replacement.

### 4. Memory Tags

Use short tags to make recall distinguish current facts from history:

```text
[CURRENT]          current accepted baseline
[VERIFIED]         verified by live file/tool output
[HISTORY]          historical event, not necessarily current
[STALE]            old rule/version superseded by newer accepted rule
[BLOCKER]          unresolved issue or limitation blocking work
[KNOWN_LIMITATION] known limitation that should not be rediscovered every time
[PRIVACY]          privacy-sensitive note, do not share by default
```

For current package state, prefer a single `[CURRENT][VERIFIED]` memory and update `CURRENT_BASELINE.md` rather than writing many competing status notes.

### 5. Health Check

Use this quick check when memory reliability matters:

```powershell
$env:PYTHONPATH="<package-root>\vendor\NexSandglass-Agent-DedicatedMemory"
$env:NEXSANDBASE_HOME="<package-root>\private-state\shared"
python -c "from sandglass_vault import recent; print(recent(3))"
```

### 6. Startup Shortcut

When startup context can be edited, include this memory shortcut:

```text
Memory shortcut: G1审记，ORC调度，沙漏只存稳态；不存秘密、噪音、猜测、长原文。
```

## Fast Path

Before using NexSandglass, let G1/ORC decide whether memory search or write is useful.

### Search memory

Use when the user asks what was decided before, mentions old context, or needs recall beyond current chat.

```powershell
$env:PYTHONPATH="<package-root>\vendor\NexSandglass-Agent-DedicatedMemory"
$env:NEXSANDBASE_HOME="<package-root>\private-state\shared"
python -c "from sandglass_vault import search; print(search('关键词'))"
```

For recent entries:

```powershell
$env:PYTHONPATH="<package-root>\vendor\NexSandglass-Agent-DedicatedMemory"
$env:NEXSANDBASE_HOME="<package-root>\private-state\shared"
python -c "from sandglass_vault import recent; print(recent(5))"
```

### Write memory

Use only after G1 policy says the fact is durable and non-secret.

```powershell
$env:PYTHONPATH="<package-root>\vendor\NexSandglass-Agent-DedicatedMemory"
$env:NEXSANDBASE_HOME="<package-root>\private-state\shared"
python -c "from sandglass_log import log_message; log_message('short durable event', 'agent')"
```

Prefer `sender='user'` for durable user-stated rules/preferences, and `sender='agent'` for assistant workflow notes that passed the value filter.

### Write decision particle

Use for explicit choices, accepted route decisions, or A/B decisions.

```powershell
$env:PYTHONPATH="<package-root>\vendor\NexSandglass-Agent-DedicatedMemory"
$env:NEXSANDBASE_HOME="<package-root>\private-state\shared"
python -c "from decision_particles import log; log('选A还是B', 'B')"
```

## Runtime Entry

Do not start or register a standalone Sandglass MCP. Use the one configured
Super Brain MCP or its package-owned H7 CLI equivalent; both bind the same
workspace, session, project proof, and `private-state/shared` root.

## Coordination With Super Brain

Default route for new messages:

```text
H7 scope and core rules → Super Brain intent/route → bounded native memory
procedure (this module) only when needed → domain action. The backend never
overrides the latest user instruction, project evidence, task state, or H7
authorization.
```

Use this backend to extend bounded recall depth, not to override Super Brain.
If it returns stale or conflicting memory, prefer current files, the latest user
instruction, and H7 project proof.

## References

Read `references/nexsandglass-usage.md` when you need command examples, install verification, or the repo's feature map.
