---
name: reverselab-unified
description: "Route explicit reverse-engineering work across ReverseLab tools and browser-act-skill-forge. Trigger on 逆向, ReverseLab, PE/APK/CTF reverse, sample analysis, website/API reverse, 接口逆向, or ReverseLab install/share checks; not generic debugging."
---

# ReverseLab Unified

Use this skill as a thin router over two external ReverseLab repositories:

- `LING71671/open-reverselab`: local reverse-engineering workspace and command wrappers.
- `GeniusHu-tgty/Open-tgtylab`: RE knowledge and `reverse_lab_tools` MCP implementation.

The capability is absorbed into Super Brain as a native, on-demand procedure.
The upstream repositories and heavy tools are local deployment dependencies;
they are never independent Super Brain host skills or automatic routes.

## First Step

Run the status script before assuming paths:

```powershell
powershell -ExecutionPolicy Bypass -File "<this-skill>/scripts/reverselab-status.ps1" -Json
```

If this skill is installed through Super Brain, `<this-skill>` is the installed skill folder. If only the package source is available, use the source folder under `extensions/reverselab-unified/skills/reverselab-unified`.

## Routing

- For local PE/APK/sample triage: prefer `mcp__reverse_lab_tools.sample_full_workup` when exposed. Otherwise use `open-reverselab` command wrappers from `tools/bin`.
- For knowledge lookup: prefer `mcp__reverse_lab_tools.kb_catalog`, `kb_router`, and `kb_read_file`.
- For Python RE libraries: prefer `mcp__reverse_lab_tools.python_re_tool_status` and related version/install tools when exposed.
- For toolbox discovery: prefer `mcp__reverse_lab_tools.toolbox_list`.
- For website/API behavior reverse work: use `browser-act-skill-forge` if installed and the task needs browser/API behavior capture.
- If neither MCP nor local repos are present, read `references/install-and-deploy.md` and use the one-click deploy script.

## One-Click Deploy

For deploy/install fully/装齐/一键部署 requests, use:

```powershell
powershell -ExecutionPolicy Bypass -File "<this-skill>/scripts/reverselab-deploy.ps1" -Apply -Profile Full -RegisterCodexMcp
```

This single entrypoint handles repository cloning, core wrappers, ReverseLabToolsMCP dependency sync, optional Codex MCP registration, upstream toolchain installation, and final status/toolcheck verification.

Use `-Profile Core` only when the user wants a lightweight core install without the heavy optional toolchain.

## Direct Git Deployment Rule

When a checkout is used elsewhere, include only the source skill and scripts;
do not create a generated package or export tree. The checkout behavior is:

```text
detect -> deploy missing dependencies -> clone/configure -> verify
```

Never hardcode the original user's local paths as the only usable configuration.

## Super Brain Lightweight Rule

Keep Super Brain light:

- Do not add the full ReverseLab instructions to the Super Brain hot path.
- Use the extension manifest and skill description for wake triggers.
- Load this skill only for reverse-engineering, ReverseLab, or reverse-tool deployment intent.
- Load `references/install-and-deploy.md` only for setup/deployment.
- Load `references/workflows.md` only for concrete PE/APK/CTF/API workflows.

## References

- Read `references/install-and-deploy.md` when setup, cloning, MCP registration, one-click deployment, or dependency explanation is needed.
- Read `references/workflows.md` for PE/APK/CTF/API routing examples.

