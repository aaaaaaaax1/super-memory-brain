# NexSandglass Usage Reference

## What It Is

NexSandglass is a local-first AI agent memory engine. It stores plaintext local memory under `.neurobase`, supports keyword/index/FTS-style search, decision particles, drift/persona traces, weave/causal threading, and an optional MCP server.

It is not originally packaged as a ZCode/Codex skill. This wrapper skill makes it discoverable and gives ORC/G1 safe usage rules.

## Installed Files

Source:

```text
<user-home>\Documents\Codex\2026-06-02\new-chat\_skill_downloads\NexSandglass-Agent-DedicatedMemory
```

Runtime:

```text
<user-home>\.neurobase\scripts
<user-home>\.neurobase\sandglass.txt
<user-home>\.neurobase\decision_particles.txt
```

Hermes plugin copies:

```text
%LOCALAPPDATA%\hermes\plugins\memory\nexsandglass\__init__.py
%LOCALAPPDATA%\hermes\plugins\sandglass\__init__.py
```

## Core Commands

Set module path first:

```powershell
$env:PYTHONPATH="$env:USERPROFILE\.neurobase\scripts"
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

Start MCP server:

```powershell
python "$env:USERPROFILE\.neurobase\scripts\sandglass_mcp.py"
```

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

Use it after G1 has decided memory should be searched or written.

- G1 owns memory governance.
- ORC owns skill routing.
- NexSandglass owns local sandglass storage/search.

Do not use NexSandglass as a secret store.
