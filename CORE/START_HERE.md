# Start Here

Use `CORE/` as the only Super Memory Brain source. The parent directory holds
only the two numbered launchers, Git guardrails, and ignored local state.

1. Run `scripts\bootstrap.ps1` to install the single host adapter and H7 MCP.
2. Open a new Codex task and ask for `Super Brain` status.
3. Use `scripts\release-readiness.ps1 -Json` before committing.

`../private-state`, `../private-archive`, the parent `memory` junction, and runtime workspace
state are local machine data. They remain available to Super Brain but are
excluded from Git by the parent `.gitignore`.

Do not create or upload a separate share package. Others install from the Git
repository itself.
