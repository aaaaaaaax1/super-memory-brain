# Baseline History

## 0.6.0 — 2026-08-14

- Moved the active package source into `CORE/` while keeping the outer working
  tree limited to the two launchers and contributor bootstrap.
- Kept H7 as the sole continuity lifecycle, with the single Codex adapter and
  private state resolved outside the source tree.
- Added package-version rebind coverage and release gates for the CORE layout.

## 0.5.98

On 2026-08-13 the package was consolidated into one direct Git source tree.
Earlier migration, share-package, and machine-path records were moved out of
the public tree. Any retained local historical evidence belongs in
`private-archive/` and remains Git-ignored.
