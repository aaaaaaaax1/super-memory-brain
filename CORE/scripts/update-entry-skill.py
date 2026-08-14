import os
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent.parent

content = '''---
name: super-memory-brain
description: Unified Super Brain host entry. H7, the core rule registry, project evidence, native capability routing, and the one shared private memory root are owned by Super Brain; bundled modules are internal procedures and provenance, never independent host skills.
---

# Super Memory Brain

This is the sole host-facing entry for the independent Super Brain control-plane
Agent. Internal modules and vendored sources are implementation/provenance;
they do not create alternate routes, memory roots, or MCP servers.

## Bundle

- H7/core rules: scope, authorization, continuity, project proof, and stage truth.
- Native capability procedures: engineering, productivity, grill-me, and other absorbed abilities.
- NexSandglass backend: bounded local storage/search only, under `private-state/shared`.

## Core Rule

Use this order:

```text
User instruction → H7 scope/contract → core rules/project evidence → Super
Brain intent and native capability route → bounded procedure → verification.
```

## Short Memory Policy

`G1审记，ORC调度，沙漏只存稳态；不存秘密、噪音、猜测、长原文。`

## Package-Local Memory

Active memory root for this local package:

```text
super-memory-brain-package\\private-state\\shared
```

The `memory/` junction is compatibility-only; runtime scripts live under:

```text
super-memory-brain-package\\runtime and vendor\\NexSandglass-Agent-DedicatedMemory
```

Never upload `private-state`, `private-archive`, or the `memory/` junction target.
Use the source Git checkout directly; do not generate a share/export package.

## System Duties

- **Startup self-check**: verify H7 activation, current runtime identity, native rules, and the one active memory root.
- **Status view**: surface the current task/workline, phase, project proof, H7 receipts, and selected native procedure.
- **Recall trigger**: continuity or prior decisions use bounded Super Brain recall; current visible context and live project evidence remain authoritative.
- **Conflict handling**: when new memory conflicts with older memory, prefer latest user instruction and mark stale rules instead of duplicating them.
- **Compression**: periodically merge equivalent memories, keep the shortest accepted version, and prune duplicates.
- **Backup and migration**: preserve local archive/restore paths without exposing private state or creating export packages.
- **Versioning**: keep package version and change notes so installs can be compared.

## Bundled Installation Notes

To make this skill work on another machine, install the source checkout and
run the package installer. It must include the internal procedures:

- `skill-orchestrator`
- `plusunm-g1`
- `nexsandglass-dedicated-memory`

The active memory root is created locally under `private-state/shared`; it is
not part of the public Git payload.

Do not copy this adapter as an independent replacement for the package runtime.

## Optional Checks

- Verify `brain_status`, `brain_turn`, and the H7 CLI equivalent bind the same
  package root, runtime identity, task scope, and `private-state/shared` root.
- Verify native capability routing is semantic, bounded, non-authorizing, and
  never installs or invokes upstream skills directly.
- Verify private-state and archives are ignored and absent from Git tracked content.

## Package Shape

Source checkout shape:

```text
super-memory-brain-package/
├─ super-memory-brain/
├─ modules/
│  ├─ skill-orchestrator/
│  ├─ plusunm-g1/
│  └─ nexsandglass-dedicated-memory/
├─ vendor/
│  └─ NexSandglass-Agent-DedicatedMemory/
├─ private-state/       (local, ignored)
├─ private-archive/     (local, ignored)
├─ memory -> private-state (compatibility junction, ignored)
└─ scripts/
   ├─ install.ps1
   ├─ install.bat
   ├─ health-check.ps1
   ├─ status.ps1
   ├─ backup.ps1
   ├─ migrate.ps1
   └─ compact.ps1
```
'''

paths = [
    PACKAGE_ROOT / 'super-memory-brain' / 'SKILL.md',
]
for skills_home in filter(None, [os.environ.get('ZCODE_HOME'), os.environ.get('CODEX_HOME')]):
    paths.append(Path(skills_home) / 'skills' / 'super-memory-brain' / 'SKILL.md')
for p in paths:
    path = Path(p)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')
    print('wrote', path)
