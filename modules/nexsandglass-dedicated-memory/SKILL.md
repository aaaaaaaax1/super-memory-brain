---
name: nexsandglass-dedicated-memory
description: "Use NexSandglass/DedicatedMemory for governed local memory writes, history search, decision particles, drift/persona memory, MCP setup, or coordination with Super Brain and plusunm-g1. Trigger on NexSandglass, Sandglass, 沙漏, or local memory engine."
---
## Installed Root Markers

When installed under ZCode/Codex, this skill directory may contain only `SKILL.md`, `package-root.txt`, and `memory-root.txt`. Treat `package-root.txt` as the full package root for `scripts/`, `manifest.json`, `CURRENT_BASELINE.md`, and package docs. Treat `memory-root.txt` as the active memory root for NexSandglass runtime/data. Do not assume `memory/` or `scripts/` live beside this installed `SKILL.md`.

Memory mode convention: global shared mode uses `<package-root>/memory/shared`; split/private agent mode uses `<package-root>/memory/agents/<agent-name>`; custom shared groups use `<package-root>/memory/groups/<group-name>`. Legacy `%USERPROFILE%\.neurobase`, `<package-root>/memory-zcode`, `<package-root>/memory-codex`, and `<package-root>/memory-<agent-name>` are fallback/migration sources only, not current targets.

Sharing policy: default global shared memory is active at `<package-root>/memory/shared`. If the user asks to isolate memory, use private per-agent memory in `<package-root>/memory/agents/<agent-name>`, a named group in `<package-root>/memory/groups/<group-name>`, or `memory:off` for no durable writes.


# NexSandglass Dedicated Memory

Use NexSandglass as a local-first memory engine behind ORC/G1, not as a replacement for the current control layer.

## Roles

- `skill-orchestrator / ORC / Super Brain stack`: routing brain. Decides whether this skill is needed.
- `plusunm-g1`: primary governed memory gate. It decides durable memory policy and conflict precedence.
- `nexsandglass-dedicated-memory`: auxiliary local memory engine for plaintext sandglass logging, search, decision particles, drift/persona traces, and optional MCP service.

Precedence:
1. Latest user instruction.
2. Live files and verified tool output.
3. Explicit project memory / G1 state.
4. NexSandglass search results.
5. Older summaries or model memory.

## Installed Paths

- Source repo: `<user-home>\Documents\Codex\2026-06-02\new-chat\_skill_downloads\NexSandglass-Agent-DedicatedMemory`
- Runtime scripts: package default `super-memory-brain-package\memory\scripts`; local legacy path may be `<user-home>\.neurobase\scripts`
- Data root: package default `super-memory-brain-package\memory`; local legacy path may be `<user-home>\.neurobase`
- Main data file: package default `super-memory-brain-package\memory\sandglass.txt`
- Decision file: package default `super-memory-brain-package\memory\decision_particles.txt`
- MCP entry: package default `super-memory-brain-package\memory\scripts\sandglass_mcp.py`

NexSandglass uses `NEXSANDBASE_HOME` if set; otherwise it defaults to `%USERPROFILE%\.neurobase`.

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
$env:PYTHONPATH="$env:USERPROFILE\.neurobase\scripts"
python -c "from sandglass_vault import recent; print(recent(3))"
```

Also verify the skill files exist when installation or sync is questioned:

```text
<user-home>\.zcode\skills\nexsandglass-dedicated-memory\SKILL.md
<user-home>\.codex\skills\nexsandglass-dedicated-memory\SKILL.md
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
$env:PYTHONPATH="$env:USERPROFILE\.neurobase\scripts"
python -c "from sandglass_vault import search; print(search('关键词'))"
```

For recent entries:

```powershell
$env:PYTHONPATH="$env:USERPROFILE\.neurobase\scripts"
python -c "from sandglass_vault import recent; print(recent(5))"
```

### Write memory

Use only after G1 policy says the fact is durable and non-secret.

```powershell
$env:PYTHONPATH="$env:USERPROFILE\.neurobase\scripts"
python -c "from sandglass_log import log_message; log_message('short durable event', 'agent')"
```

Prefer `sender='user'` for durable user-stated rules/preferences, and `sender='agent'` for assistant workflow notes that passed the value filter.

### Write decision particle

Use for explicit choices, accepted route decisions, or A/B decisions.

```powershell
$env:PYTHONPATH="$env:USERPROFILE\.neurobase\scripts"
python -c "from decision_particles import log; log('选A还是B', 'B')"
```

## MCP Server

Start the local MCP service when a client needs it:

```powershell
$env:PYTHONPATH="$env:USERPROFILE\.neurobase\scripts"
python "$env:USERPROFILE\.neurobase\scripts\sandglass_mcp.py"
```

The upstream README says the service runs on `localhost:8765`. Verify with the actual server output before configuring clients.

## Coordination With Super Brain + G1

Default route for new messages:

```text
Memory Router: memory:auto; decide recall/write need from keyword + semantic triggers
→ plusunm-g1 memory governance
→ skill-orchestrator / ORC task routing
→ nexsandglass-dedicated-memory only when local memory search/write helps
→ domain skill or direct answer
```

Use NexSandglass to extend recall depth, not to override G1. If NexSandglass returns stale or conflicting memory, say so and prefer current files/user instruction.

## References

Read `references/nexsandglass-usage.md` when you need command examples, install verification, or the repo's feature map.
