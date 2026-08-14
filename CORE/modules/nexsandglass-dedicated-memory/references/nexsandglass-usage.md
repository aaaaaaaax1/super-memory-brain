# NexSandglass Backend Usage Reference

## What It Is

NexSandglass is the vendored local storage/search backend used by Super Brain.
It supports keyword/index/FTS-style search, decision particles, drift/persona
traces, and derived indexes. It is not a host skill, standalone MCP, or second
memory authority.

The Super Brain runtime owns discovery, routing, scope, privacy, and writes.
This document records backend provenance and bounded implementation usage only.

## Installed Files

Vendored source:

```text
<package-root>\vendor\NexSandglass-Agent-DedicatedMemory
```

Active state (runtime supplied):

```text
<package-root>\private-state\shared
```

No host-specific or Hermes copy is an active runtime dependency.

## Core Commands

Set module path first:

```powershell
$env:PYTHONPATH="<package-root>\vendor\NexSandglass-Agent-DedicatedMemory"
$env:NEXSANDBASE_HOME="<package-root>\private-state\shared"
```

Write memory:

```powershell
python -c "from sandglass_log import log_message; print(log_message('hello', 'user'))"
```

Search memory:

```powershell
python -c "from sandglass_vault import search; print(search('关键词'))"
```

Recent memory:

```powershell
python -c "from sandglass_vault import recent; print(recent(5))"
```

Write decision particle:

```powershell
python -c "from decision_particles import log; log('选A还是B', 'B')"
```

Do not start `sandglass_mcp.py`. The only runtime transport is
`runtime\brain_mcp.py` (or the same-contract H7 CLI).

## Important Modules

- `sandglass_log.py`: write memory via `log_message` / `log_conversation`.
- `sandglass_vault.py`: search and recent reads.
- `decision_particles.py`: explicit decision memory.
- `sandglass_think.py`: L3 synthesis / search filter / pulse-aware thinking.
- `sandglass_mcp.py`: MCP server entry.
- `sandglass_paths.py`: path source of truth; uses `NEXSANDBASE_HOME` or `~/.neurobase`.
- `plugin.py`: gateway write hook.
- `memory_provider.py`: Hermes memory provider integration.

## Integration Policy

Use it only after Super Brain H7 has selected a bounded native memory
procedure. Super Brain owns governance and routing; this backend owns only
storage/search and derived-index mechanics.

Do not use NexSandglass as a secret store.
