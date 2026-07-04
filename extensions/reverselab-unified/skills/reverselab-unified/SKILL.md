---
name: reverselab-unified
description: Unified ReverseLab skill for reverse engineering. Use when the user says 逆向, ReverseLab, open-reverselab, Open-tgtylab, reverse engineering, reversing, sample analysis, PE/APK reverse, CTF reverse, website/API reverse, 接口逆向, 样本分析, APK 逆向, PE 逆向, 一键部署逆向工具, 装齐逆向工具, or asks whether the two ReverseLab repos are installed or shareable through Super Brain. Routes between LING71671/open-reverselab local commands, GeniusHu-tgty/Open-tgtylab reverse_lab_tools MCP, and browser-act-skill-forge for website/API behavior reverse work. Do not use for unrelated debugging or generic security talk.
---

# ReverseLab Unified

Use this skill as a thin router over two external ReverseLab repositories:

- `LING71671/open-reverselab`: local reverse-engineering workspace and command wrappers.
- `GeniusHu-tgty/Open-tgtylab`: RE knowledge and `reverse_lab_tools` MCP implementation.

The skill is shareable as part of Super Brain. The upstream repositories and heavy tools are installed on each recipient machine by the deploy script.

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
- If neither MCP nor local repos are present, read `references/install-and-share.md` and use the one-click deploy script.

## One-Click Deploy

For deploy/install fully/装齐/一键部署 requests, use:

```powershell
powershell -ExecutionPolicy Bypass -File "<this-skill>/scripts/reverselab-deploy.ps1" -Apply -Profile Full -RegisterCodexMcp
```

This single entrypoint handles repository cloning, core wrappers, ReverseLabToolsMCP dependency sync, optional Codex MCP registration, upstream toolchain installation, and final status/toolcheck verification.

Use `-Profile Core` only when the user wants a lightweight core install without the heavy optional toolchain.

## Shareability Rule

When packaging Super Brain for others, include this skill and scripts, but do not assume the external repos are already present. The recipient-facing behavior is:

```text
detect -> deploy missing dependencies -> clone/configure -> verify
```

Never hardcode the original user's local paths as the only usable configuration.

## Super Brain Lightweight Rule

Keep Super Brain light:

- Do not add the full ReverseLab instructions to the Super Brain hot path.
- Use the extension manifest and skill description for wake triggers.
- Load this skill only for reverse-engineering, ReverseLab, or reverse-tool deployment intent.
- Load `references/install-and-share.md` only for setup/deployment.
- Load `references/workflows.md` only for concrete PE/APK/CTF/API workflows.

## References

- Read `references/install-and-share.md` when a recipient needs setup, cloning, MCP registration, one-click deployment, or dependency explanation.
- Read `references/workflows.md` for PE/APK/CTF/API routing examples.

