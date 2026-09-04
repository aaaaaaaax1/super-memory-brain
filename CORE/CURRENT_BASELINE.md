# Current Baseline

Last Updated: 2026-08-14
Status: [CURRENT]
Package Version: 0.6.0

## Source and privacy boundary

`CORE/` is the only active Super Brain source tree. The parent directory is
the direct Git working tree and intentionally exposes only `CORE/`, the two
numbered VBS launchers, bootstrap guidance, and ignored local state. Local
memory, runtime state, backups, and historical evidence live in
`../private-state/` and `../private-archive/`, both excluded by the parent
`.gitignore`.

The parent `memory` entry is a local compatibility junction to `private-state`.
It is not public source and must never be staged.

## Control plane

- H7 `brain_turn` is the lifecycle authority.
- `super-brain-rules.json` is the only behavioral-policy registry.
- The latest real assistant-visible reply locates continuation; H7 maps it to
  the scoped task and live project evidence before action.
- The installed `super-memory-brain` skill is the single host entry.
- Package capabilities are absorbed Super Brain procedures, not independent
  host skills.
- A non-Codex local MCP host uses `runtime/local_scope_adapter.py`; only the
  real project cwd and `SUPER_BRAIN_LOCAL_SESSION_ID` cross the process
  boundary, and every scope change requires a fresh launcher process.

## Current verification

Run source checks from `CORE/` before a Git review:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-package.ps1 -PackageOnly
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-ui-regression.ps1 -Json
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\release-readiness.ps1 -Json
```

No share/export package is generated. Publish only the reviewed Git source
tree after the privacy preflight is clean.
