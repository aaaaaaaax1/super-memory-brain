# Four-Layer Ownership, Direct Git Deployment

Use four logical layers inside one user-facing source root:

## Publication Source

In direct Git mode, sourceRoot and runtimeRoot are the same complete local
package. The root .gitignore excludes private state, archives, and mutable
memory through the compatibility junction, so GitHub Desktop sees only public
implementation changes. There is no separate share/export tree.

1. `sourceRoot`: the direct Git working tree for normal local commits; it is the same path as runtimeRoot in direct mode.
2. `runtimeRoot`: the complete local Super Brain instance and entrypoints.
3. `stateRoot`: mutable shared/agent memory, checkpoints, indexes, and workspace state under `runtimeRoot/private-state`.
4. `archiveRoot`: local evidence, install backups, and bounded recovery backups under `runtimeRoot/private-archive`.

The normal local shape is:

```text
<workspace-root>/
  super-memory-brain-package/
    .git/                         (direct Git metadata)
    private-state/
    private-archive/
    memory -> private-state       (compatibility junction; ignored by Git)
```

The package is a self-contained local system and the only Git repository.
Its checked-in `.gitignore` keeps private memory, machine-local layout,
credentials, runtime state, caches, and archives out of commits. Publishing is
performed directly from this source tree after the privacy and Git preflight;
no generated share package or export manifest is created.

## Runtime Control-Plane Boundary

Inside `runtimeRoot`, ownership flows in one direction:

1. The installed `super-memory-brain` skill is a small host adapter for intent
   classification, route selection, and bounded result presentation.
2. Hooks and runtime scripts own execution contracts, work-line transitions,
   checkpoints, freshness guards, verification, and rollback behavior.
3. `stateRoot` is the durable source for runtime state; skills never substitute
   prompt text for a missing or conflicting state transition.
4. Compact projections return only the active path, counts, evidence, and next
   authorized action needed by the host.

Threading and plan correctness therefore remain system behavior even if a skill
is cold, shortened, refreshed, or temporarily unavailable. The skill tells the
host when and how to enter the system; it does not implement the system.

The session/workspace hot index is a derived cache under `stateRoot`, not a
fifth ownership layer. It stores bounded wake metadata only; the execution
contract remains authoritative. See `references/runtime-control-plane.md`.

## BrainKernel Owner Matrix

Keep each runtime record owned by one layer:

1. `scripts/execution-contract.ps1` owns durable work-line state, return
   stacks, plan receipts, merge dossiers, and action authorization.
2. `scripts/internal/runtime-wake-core.ps1` and
   `runtime/codex_prompt_hook.py` may only maintain the bounded hot projection
   and a redacted observation revision. They cannot select, restore, or expose
   an old action; the contract remains the authority.
3. `runtime/brain_core.py` is a per-instance, read-only evidence assembly
   kernel. It never changes process-global import paths or memory-root
   environment state, and it never synchronizes, rebuilds, or locks a derived
   memory index while answering a recall. For a current-task recall it first
   accepts one session-and-workspace-bound hot-index contract, and rejects it
   when authorization or its plan receipt is stale.
4. Accepted memory writes own derived-index freshness. `sandglass_log.py`
   refreshes the FTS and Sandglass indexes after a durable append; physical
   rewrites use the explicit full rebuild path. Read-only recall may fall back
   to a bounded raw-log scan while an index is unavailable.
5. `runtime/brain_mcp.py` and `runtime/brain_cli.py` are transport only. They
   share the kernel's request defaults and do not own memory, state, ranking,
   or lifecycle mutations.
6. `current-task-context.ps1` writes task-scoped records and a workspace-scoped
   compatibility projection. The legacy global pointer is never allowed to
   replace a pointer from another workspace.

This keeps the native hot path short while preventing a legacy compatibility
record from becoming a second current-task authority.

`runtime-layout.json` is the private machine-local adapter. Keep
`runtime-layout.example.json` in source control. `runtimeRoot/memory` may remain an
NTFS compatibility junction to the contained `stateRoot`; code should call
`Get-SuperBrainMemoryBaseRoot` instead of constructing `runtimeRoot/memory`.

Backup defaults copy durable memory and continuity-critical workspace state only.
Full generated workspace capture requires explicit `-IncludeWorkspace`.
Normal installation never prunes archived install backups. Cleanup requires either
`cleanup-install-backups.ps1 -Apply` or the explicit install-time
`install.ps1 -PruneBackups` switch; `KeepBackups` alone is non-destructive.

The public Git tree includes the policy, route, capability, and runtime-layout
example files while excluding the private layout, `private-state`,
`private-archive`, memory bodies, machine paths, backups, and archives. The
privacy preflight and Git index are the release-integrity checks; no separate
manifest or export directory is required.
