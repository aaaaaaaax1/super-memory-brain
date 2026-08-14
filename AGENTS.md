# Repository Guidelines

## Project Structure & Module Organization

`CORE/` is the only implementation root. It contains H7 in `CORE/runtime/`,
PowerShell in `CORE/scripts/`, the host entry in `CORE/super-memory-brain/`,
capabilities in `CORE/modules/` or `CORE/extensions/`, tests in `CORE/tests/`,
and the UI in `CORE/ui/`. Root JSON policy files also live in `CORE/`.

The outer root is intentionally small: `CORE/`, the two numbered VBS launchers,
this bootstrap, Git guardrails, and ignored local state only.

## Build, Test, and Development Commands

Run implementation commands from `CORE/` in PowerShell:

```powershell
.\scripts\lint.ps1                         # Parse PowerShell; use PSScriptAnalyzer when available
.\scripts\test-pester.ps1 -Tier Fast        # Fast routing and manifest checks
.\scripts\test-pester.ps1 -Tier Core        # H7 continuity/control-plane regression suite
.\scripts\verify-package.ps1 -PackageOnly   # Validate package layout and receipts
Set-Location ui; npm install; npm run build  # Build the Vite control center
```

Run Fast/Core while iterating, then focused regression and
package verification before handoff.

## Coding Style & Naming Conventions

Match nearby code: PowerShell functions use `Verb-Noun` and PascalCase;
Python uses `snake_case`; JSON uses two spaces. Keep scripts UTF-8 and put
behavioral changes in the versioned registry and its tests—not skill prose.

## Testing Guidelines

Name Pester files `*.Tests.ps1` and Python regressions
`runtime_*_regression.py`. Add a focused regression for control-plane,
privacy, installation, and routing changes. Isolate state in fixtures; never
read local memory or machine paths.

## Commits, Pull Requests, and Privacy

Use concise imperative subjects, e.g. `feat: add H7 proof gate` or
`refactor: simplify runtime binding`. PRs state the behavior change, tests,
and install/UI impact. Never stage `private-state/`, `private-archive/`,
`memory/`, credentials, logs, or machine-specific paths; run
`git status --short` before committing.

## Agent-Specific Bootstrap

<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->
## Super Memory Brain Bootstrap

- Entry: explicit Super Brain/G1, governed continuity/status/recall/learning/repair, or the configured git workflow phrases load `super-memory-brain`; then use H7 `brain_turn`.
- Git workflow trigger: `git怎么写`/`git呢`/`怎么提交` routes to Super Brain canonical workflow handling.
- Authority: bootstrap only. All behavioral policy, priority, progress truth, and stage rules come solely from the package `super-brain-rules.json` and H7 contract/runtime; this file must never duplicate or override them.
- Safety: bootstrap never selects a continuation anchor or interprets summaries. If H7 MCP is unavailable, use the same H7 CLI; if no current scoped receipt is possible, block and repair. Never use Hook/P7 or visible context as a substitute.
- Refresh: package marker resolves the current Super Brain root; refresh this bootstrap together with the one Super Brain adapter after a verified package update.

## Browser Route

Use Playwright for normal browser automation; load `browser-act` only on request or if Playwright cannot reliably complete visible state.
<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->
