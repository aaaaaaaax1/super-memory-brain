# Maintenance And Release Route

Use for release/share/package/privacy review and maintenance work after the
user explicitly asks for it.

Release safety:
- Install UI regression rule: every package update, version bump, extension/skill addition, or install/share/UI/manifest change must run scripts/install-ui-regression.ps1 before completion. release-readiness.ps1 must treat a missing or stale last-install-ui-regression.json as blocking.
- Verify package contents before share.
- Exclude private memory unless the user explicitly requests a private package.
- Do not include secrets, raw credentials, or local-only state in share output.
- Preserve rollback path and version evidence.

Maintenance safety:
- Safe local hygiene may run automatically only when low risk.
- Destructive deletion, broad overwrites, install hooks, and global rewrites
  require confirmation.

This is a cold path. Do not load it for ordinary chat or simple code tasks.

Second-hop only: for package contents, share exclusions, or rollback evidence, read
`references/package-shape.md`; do not load it from the index directly.

