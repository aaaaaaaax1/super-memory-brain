# Four-Layer Runtime Layout

Use four physical roots with one-way responsibilities:

1. `sourceRoot`: Git-tracked, sanitized source and tests. No mutable memory.
2. `runtimeRoot`: installed package code and entrypoints. No historical backups.
3. `stateRoot`: mutable shared/agent memory, checkpoints, indexes, and workspace state.
4. `archiveRoot`: immutable evidence archives, install backups, and bounded recovery backups.

`runtime-layout.json` is the private machine-local adapter. Keep
`runtime-layout.example.json` in source control. `runtimeRoot/memory` may remain an
NTFS junction to `stateRoot` while older scripts are migrated; code should call
`Get-SuperBrainMemoryBaseRoot` instead of constructing `runtimeRoot/memory`.

Backup defaults copy durable memory and continuity-critical workspace state only.
Full generated workspace capture requires explicit `-IncludeWorkspace`.
Normal installation never prunes archived install backups. Cleanup requires either
`cleanup-install-backups.ps1 -Apply` or the explicit install-time
`install.ps1 -PruneBackups` switch; `KeepBackups` alone is non-destructive.

Public source export must include `maintenance-policy.json`, `route-map.json`,
`capabilities.json`, and the runtime-layout example, while excluding the private
layout, memory bodies, machine paths, backups, and archives.
