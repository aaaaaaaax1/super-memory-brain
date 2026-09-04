# Changelog

## 0.6.0

- Complete CORE layout migration with explicit H7 package-version rebind and source-only release boundaries.
- Added the host-neutral local MCP scope adapter: one real project cwd plus a
  strict process-only local session id, with static discovery remaining inert.
- Hardened Broker teardown with mandatory instance CAS and per-client channel
  ownership, preventing read-only clients and stale channels from stopping a
  replacement instance.

## 0.5.98 — 2026-08-13

- Consolidated public source at the direct Git root.
- Kept mutable memory and private history in ignored `private-state/` and
  `private-archive/` roots.
- Retired separate share/export distribution routes and obsolete root-layout
  migration shims.
- Kept H7 as the single lifecycle authority and Super Brain as the only
  host-facing skill entry.
- Kept absorbed engineering, productivity, and review capabilities package
  owned and semantically routed through Super Brain.
