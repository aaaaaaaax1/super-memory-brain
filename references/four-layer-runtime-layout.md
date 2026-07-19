# Four-Layer Ownership, Two-Root Deployment

Use four logical layers with two user-facing top-level roots:

1. `sourceRoot`: Git-tracked, sanitized source and tests. No mutable memory.
2. `runtimeRoot`: the complete local Super Brain instance and entrypoints.
3. `stateRoot`: mutable shared/agent memory, checkpoints, indexes, and workspace state under `runtimeRoot/private-state`.
4. `archiveRoot`: local evidence, install backups, and bounded recovery backups under `runtimeRoot/private-archive`.

The normal local shape is:

```text
<workspace-root>/
  super-memory-brain-package/
    private-state/
    private-archive/
    memory -> private-state
  super-memory-brain-git/
```

The package is a self-contained local system. The Git root contains the full
shareable implementation but excludes private memory, machine-local layout,
credentials, runtime state, caches, and local archives.

`runtime-layout.json` is the private machine-local adapter. Keep
`runtime-layout.example.json` in source control. `runtimeRoot/memory` may remain an
NTFS compatibility junction to the contained `stateRoot`; code should call
`Get-SuperBrainMemoryBaseRoot` instead of constructing `runtimeRoot/memory`.

Backup defaults copy durable memory and continuity-critical workspace state only.
Full generated workspace capture requires explicit `-IncludeWorkspace`.
Normal installation never prunes archived install backups. Cleanup requires either
`cleanup-install-backups.ps1 -Apply` or the explicit install-time
`install.ps1 -PruneBackups` switch; `KeepBackups` alone is non-destructive.

Public source export must include `maintenance-policy.json`, `route-map.json`,
`capabilities.json`, and the runtime-layout example, while excluding the private
layout, `private-state`, `private-archive`, memory bodies, machine paths,
backups, and archives.
