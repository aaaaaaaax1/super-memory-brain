---
name: plusunm-g1
description: "Use plusunm-g1 for explicit, governed continuity: recall, task resumption, context persistence, memory replacement, anti-amnesia, deterministic state, and rollback. Prefer verified local state over hidden AI memory when a memory decision is required."
---
## Installed Root Markers

When installed under ZCode/Codex, this skill directory may contain only `SKILL.md`, `package-root.txt`, and `memory-root.txt`. Treat `package-root.txt` as the full package root for `scripts/`, `manifest.json`, `CURRENT_BASELINE.md`, and package docs. Treat `memory-root.txt` as the active memory root for NexSandglass runtime/data. Do not assume `memory/` or `scripts/` live beside this installed `SKILL.md`.

Memory mode convention: global shared mode uses `<package-root>/memory/shared`; split/private agent mode uses `<package-root>/memory/agents/<agent-name>`; custom shared groups use `<package-root>/memory/groups/<group-name>`. Legacy `%USERPROFILE%\.neurobase`, `<package-root>/memory-zcode`, `<package-root>/memory-codex`, and `<package-root>/memory-<agent-name>` are fallback/migration sources only, not current targets.

Sharing policy: default global shared memory is active at `<package-root>/memory/shared`. If the user asks to isolate memory, use private per-agent memory in `<package-root>/memory/agents/<agent-name>`, a named group in `<package-root>/memory/groups/<group-name>`, or `memory:off` for no durable writes.


# PlusUNM G1

Use this as the explicit-memory layer for Codex. It wraps the downloaded `plusunm/plusunm` project, which is a governed cognitive runtime, not a ready-made Codex `SKILL.md`.

Local repo:
- `<user-home>\Documents\Codex\2026-06-02\new-chat\_skill_downloads\plusunm`

Hard limit:
- This skill cannot disable platform or model-hidden memory.
- It makes PlusUNM/local explicit state the working source of truth.
- Current user instruction and live files beat old memory.

## Operating Rule

For continuity, resumption, project memory, workflow learning, or "what did we decide" questions:

1. Use the short memory router: `memory:auto` by default, `memory:force` on explicit user remember/recall, `memory:off` when the user disables memory.
2. Prefer explicit state: PlusUNM runtime, project memory files, handoffs, accepted baselines, live files, and verified tool output.
3. Do not rely on vague AI memory as evidence.
4. If explicit state is missing, say what is missing and reconstruct from live files or user-provided context.
5. Write only durable facts that will speed future work.
6. Prune stale or rejected variants before adding new memory.
7. Use confidence gates for recall: high injects a compact memory packet, medium injects only summary/title, low skips memory正文.

Memory layers are separate concepts, not separate databases by default:

- `profile`: durable user preferences.
- `project`: project background, stack, conventions.
- `decision`: accepted decisions and supersession.
- `task`: open tasks, blockers, next actions.
- `session`: recent session summaries.

## Fast Path

Use this compact loop:

```text
Recall -> Verify -> Act -> Capture -> Prune
```

- Recall: check explicit memory/handoff/project files when continuity matters.
- Verify: compare recalled state with current user request and live files.
- Act: use the smallest stable route that completes the task.
- Capture: save only accepted decisions, key routes, reusable recipes, blockers, and next actions.
- Prune: remove old clutter, duplicate logs, raw payloads, failed drafts, and stale assumptions.

## Runtime Usage

Do not assume a `brain_memory` Python module exists in this package. In this installed Super Memory Brain package, use the root markers first:

1. Read `package-root.txt` for the package root.
2. Read `memory-root.txt` for the active memory root.
3. Run package scripts from `<package-root>\scripts`.

Common checks:

```powershell
scripts\status.ps1 -Json
scripts\memory-health.ps1 -Json
scripts\recall-recent.ps1 -Count 5
scripts\recall-search.ps1 -Query "<query>" -TopK 3 -MaxTokens 1200 -Layer all -Json
```

The local runtime is NexSandglass under `<memory-root>\scripts` (`sandglass_vault.py`, `sandglass_log.py`, and related modules). If a Python import is needed, set `NEXSANDBASE_HOME=<memory-root>` and `PYTHONPATH=<memory-root>\scripts`, then import the documented `sandglass_*` modules. If a script or import fails, report the unavailable runtime and fall back to explicit local markdown/json memory files.

## What To Store

Store compact, durable, non-secret facts:

- Project identity and goal.
- Accepted baseline/version.
- Current route and why it won.
- Key files, commands, tools, skills, and verification evidence.
- Reusable solved-task recipe.
- Known blockers and next action.
- Rollback points and historical version nodes when useful.

## What Not To Store

Never store:

- API keys, tokens, passwords, cookies, private credentials.
- Raw base64, full payloads, complete responses, full SSE streams, or full image reference objects.
- Large logs, repeated chat dumps, unrelated drafts, rejected variants, or speculation.
- Sensitive personal data unless the user explicitly asks and it is necessary.

## Conflict Resolution

Use this precedence:

1. Latest user instruction.
2. Live files and verified tool output.
3. Current project memory/handoff.
4. PlusUNM governed state.
5. Older summaries.
6. Model/AI memory only as a weak hint, never as proof.

## Output Style

For functional tasks, be short:

```markdown
State:
- ...
Action:
- ...
Evidence:
- ...
Next:
- ...
```

For literary/text tasks, expand only when quality requires it.

## Pairing

- Use `skill-orchestrator` to route work and enforce concise execution.
- Use `context-summarizer` for compact persistent project memory.
- Use `chat-repair-summarizer` for broken, bloated, stalled, or polluted chats.
- Use PlusUNM G1 as the explicit-memory authority behind those workflows.
