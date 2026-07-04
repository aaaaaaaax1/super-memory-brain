# Package Shape

Second-hop reference for install, refresh, release, and package maintenance
routes. Do not load from `references/index.md` directly.

Package root contains runtime docs, scripts, modules, memory, and installable
skill entrypoints. Installed skill folders may contain only `SKILL.md`,
`package-root.txt`, and `memory-root.txt`; use those markers to find the real
package and memory roots.

Distribution guard:
- Include `super-memory-brain/`, `modules/`, `scripts/`, `manifest.json`, route
  maps, capabilities, tests, and required vendor runtime files.
- Exclude private/raw memory, secrets, local tokens, and install backups unless
  the user explicitly requests a private local backup.
- Preserve rollback evidence: source path, backup path, changed files,
  verification commands, and result.

Refresh guard:
- Hot refresh may update installed skill copies and marked startup bootstrap.
- Hook/global rewrite, broad overwrite, deletion, or private data handling needs
  explicit approval.
- If a host caches skill text, tell the user to open a new session after refresh.