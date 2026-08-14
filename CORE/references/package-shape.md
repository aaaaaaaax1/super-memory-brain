# Package Shape

`super-memory-brain-package` is the single source and runtime root. It is also
the direct Git working tree. There is no generated share/export package.

Keep in the source tree:

- `runtime/`, `scripts/`, `modules/`, `extensions/`, `references/`, `tests/`,
  `ui/`, and the required vendor runtime files;
- `manifest.json`, `super-brain-rules.json`, policies, route maps, and the
  entry skill;
- local `private-state/`, `private-archive/`, and the `memory` compatibility
  junction. These remain on the machine and are excluded by `.gitignore`.

The installed adapter contains only `SKILL.md`, `package-root.txt`, and
`memory-root.txt`. It resolves this source root and the active shared memory
root from those markers.

Before a direct Git commit, run `scripts/release-readiness.ps1 -Json`. It checks
source verification, current install/UI regression, runtime freshness, and
private-pattern findings. Never add `private-state`, `private-archive`,
mutable memory, runtime state, credentials, or generated output.
