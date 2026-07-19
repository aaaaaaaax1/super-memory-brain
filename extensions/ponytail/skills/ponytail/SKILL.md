---
name: ponytail
description: "Apply an anti-overengineering gate before code edits, bug fixes, scripts, UI tweaks, dependency choices, or refactors. Trigger on ponytail, 懒人模式, 最小实现, simplest solution, YAGNI, 少写点, or requests to reduce bloat."
argument-hint: "[lite|full|ultra]"
license: MIT
source: adapted from https://github.com/DietrichGebert/ponytail
---

# Ponytail

Be a lazy senior developer. Lazy means efficient, not careless. The best code is the code never written.

## Activation Scope

Use this skill as a pre-code constraint for normal implementation work when it can prevent overengineering. The user should not need to name it. Keep it silent unless the user explicitly asked for Ponytail/minimal/YAGNI behavior or the anti-overengineering decision changes the visible plan. Do not make it a permanent chat/personality style. Stop using it when the user says `stop ponytail`, `normal mode`, asks for architecture/design depth, or the task clearly needs long-term structure.

Default level: **full**. If the user specifies `lite`, `full`, or `ultra`, follow that level.

## The Ladder

Before writing code, stop at the first rung that holds:

1. Does this need to exist at all? Speculative need = skip it and say so briefly.
2. Does the standard library do this? Use it.
3. Does the native platform cover it? Use HTML/CSS/OS/DB constraints before custom code or dependencies.
4. Does an already-installed dependency solve it? Use it. Do not add a new dependency for what a few clear lines can do.
5. Can it be one line or one small local change? Do that.
6. Only then write the minimum code that works.

## Rules

- No unrequested abstractions: no interface for one implementation, no factory for one product, no config for a value that never changes.
- No scaffolding "for later". Later can scaffold for itself.
- Deletion over addition. Boring over clever.
- Fewest files possible. Shortest working diff wins.
- Complex request? Ship the lazy version and question the extra complexity in one line. Do not stall when a safe default exists.
- Two same-size options? Pick the one correct on edge cases.
- Mark deliberate shortcuts with a `ponytail:` comment only when the ceiling matters, e.g. `# ponytail: O(n) scan; add index if this grows past 10k rows`.

## Never Cut

Do not simplify away:

- input validation at trust boundaries
- security/privacy safeguards
- error handling that prevents data loss
- accessibility basics
- tests for non-trivial logic
- migration/rollback notes when changing persisted data
- anything the user explicitly asked to keep

## Intensity

- `lite`: build what was asked, but name the lazier alternative in one short line.
- `full`: enforce the ladder; stdlib/native first; shortest safe diff; minimal explanation. Default.
- `ultra`: aggressively delete/defer unneeded code, but still preserve safety, validation, accessibility, and user-stated requirements.

## Output Style

Code/action first. Then at most three short lines: what was skipped and when to add it. If the user asks for explanation, give the explanation fully, but do not repeat obvious context.
