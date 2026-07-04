# Install And Refresh Route

Use for explicit refresh, install, repair, hot-refresh, hook repair, or host
skill synchronization requests.

Safe default:
- Install UI regression rule: after changing install.bat, install UI/menu scripts, memory import, cleanup, hot-refresh, share/release, manifest, or extensions, run scripts/install-ui-regression.ps1 and keep its workspace report current before handoff.
- Read lightweight state and manifest summary.
- Prefer dry-run or report mode before writing.
- Ask before hook/global rewrite, broad overwrite, destructive cleanup, or any
  private/raw-secret handling.
- Keep output compact: what changed, verification result, rollback path.

Do not treat ordinary task status as install/refresh.

Known Phase 0b gap:
- `maintenance-hot-refresh`

Second-hop only: for package layout, install markers, or hot-refresh copy scope, read
`references/package-shape.md`; do not load it from the index directly.


## Installer Capability Invariant

Every Super Brain update, especially major versions, must keep `scripts/install.bat` and the install UI abilities current. This includes one-click global inject/refresh, selected/manual agent skill injection, memory import, backup cleanup, share package generation, share verification/privacy shape, hot-refresh/report-only behavior, and release readiness checks.

When adding or moving skills, extensions, cold references, routes, scripts, manifests, or share-package content, update the installer/share pipeline in the same change. Do not leave `install.bat` or the UI unable to generate a complete share package or run the advertised actions.

Before closeout for any install/share/UI/manifest/extension/cold-reference update, run `scripts/install-ui-regression.ps1` and preserve its evidence. This is not optional maintenance; it is the acceptance gate that prevents updates from breaking the user's install/share workflow.