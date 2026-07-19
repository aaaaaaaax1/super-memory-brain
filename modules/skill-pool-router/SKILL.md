---
name: skill-pool-router
description: "Resolve an exact user-named skill across active and indexed cold pools before overlapping/default skills; exact match wins without restart. Also provides capability fallback and reversible hot/cold skill management."
---

# Skill Pool Router

Keep the active Codex skill catalog small while preserving all specialized
skills outside the active scan path.

## Routing

Use this skill only when:

- the user asks to inspect, reduce, activate, or restore skills; or
- the user explicitly names a skill or a phrase that may be an indexed skill name; or
- a task clearly needs a specialized capability absent from active skills.

Selection priority is deterministic:

1. Exact active or indexed-cold skill name/folder selected by the user.
2. Explicit backend or tool selected by the user.
3. Active default skill for the capability.
4. One bounded capability search when no exact selection exists.

An exact user-selected skill must not be replaced by an overlapping active
default. Read the resolved `SKILL.md` and use that skill unless the user changes
the selection.

For a specialized task, use `Search` once, select at most one exact capability
match, then read only its verified `skillFile` in place. Cold storage affects
catalog visibility, not callability. Do not move it active and do not require a
new conversation.

When the user explicitly names a skill absent from the current session catalog,
`Resolve` it by both `name` and `folder` across the live active catalog and then
the indexed cold pool before saying it is missing. The resolver verifies the
selected `SKILL.md` SHA256 and returns the path to read immediately. Never infer
absence from the session catalog or callable-tool list alone. A configured
backend or environment variable is not a substitute for checking both pools.

`Smag` (`share-mini-imagegen`) is a protected active skill for this user. Do not
move it back to the cold pool during profile reapplication.

`免费生图` is also protected active because its exact user-facing name must work
even in a Desktop process that started before the prompt hook was installed.

This router is independent of Super Memory Brain. Do not add its catalog or
details to the Super Brain global bootstrap.

## Management

`Report`, `Resolve`, and index-changing actions validate skill text as strict
UTF-8 and reject known semantic mojibake markers, including corruption in
helper scripts. A valid frontmatter block or matching hash does not override a
content-health failure.

Run report mode first:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Report -Json
```

Apply the protected default profile:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Apply -Json
```

Activate one cold skill:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Activate -SkillName <name> -Json
```

Expose a cold skill to new Codex tasks without moving or copying its source:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Expose -SkillName <name> -Json
```

Remove only that active junction while preserving the cold source:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Hide -SkillName <name> -Json
```

Resolve a named active or cold skill for immediate use without moving it:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Resolve -SkillName <name> -Json
```

Search by capability when no active skill fits:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Search -Query <capability> -Json
```

Rebuild the cold index without changing the active pool:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Reindex -Json
```

`Reindex`, `Apply`, `Activate`, `Expose`, and `Hide` also refresh the compact
`~/.codex-cold-skills/skill-name-index.tsv` used by the pre-turn hook. It
contains names, paths, and hashes only; descriptions and skill bodies stay out
of startup context.

Restore an entire apply operation:

```powershell
& "$HOME\.codex\skills\skill-pool-router\scripts\manage-skill-pool.ps1" -Action Restore -ManifestPath <manifest> -Json
```

No action permanently deletes a skill. `Expose` and `Hide` change only a
reversible active junction; `Resolve` and `Search` work in the current task.
