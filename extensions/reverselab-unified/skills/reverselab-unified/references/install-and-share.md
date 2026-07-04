# Install And Share

## What This Skill Bundles

This skill bundles the Super Brain extension layer:

- `SKILL.md`
- status script
- one-click deploy script
- workflow references

The two upstream repositories and heavier reverse-engineering tools are installed on the recipient machine by the deploy script.

## External Repositories

Recommended default locations:

```text
%USERPROFILE%\ReverseLab\open-reverselab
%USERPROFILE%\ReverseLab\Open-tgtylab
```

Upstream repos:

```text
https://github.com/LING71671/open-reverselab.git
https://github.com/GeniusHu-tgty/Open-tgtylab.git
```

## Dependencies

Minimum:

- Git
- Python 3.10+
- uv or pip

Toolchain groups installed or checked by full deploy:

- ReverseLabToolsMCP
- open-reverselab command wrappers
- Android tools: apktool, jadx, uber-apk-signer, Frida mobile files when available
- Windows tools: Cutter, Detect It Easy, PE-bear, Procmon, ProcDump, Frida tools, related GUI helpers
- CTF/API tools: sqlmap, dirsearch, jwt_tool, tplmap, ffuf, gobuster, httpx, nuclei, katana, and related wrappers
- Common tools: Maven, Ghidra path/setup checks

## One-Click Full Deploy

From the installed skill folder:

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\reverselab-deploy.ps1" -Apply -Profile Full -RegisterCodexMcp
```

This performs the full deploy path:

- clone `LING71671/open-reverselab`
- clone `GeniusHu-tgty/Open-tgtylab`
- create `open-reverselab` core wrappers under `tools/bin`
- install/sync `ReverseLabToolsMCP` Python dependencies with `uv`
- register `reverse_lab_tools` in Codex MCP config when `-RegisterCodexMcp` is supplied
- run `open-reverselab\scripts\misc\install_tools.ps1 -All`
- run status and toolcheck verification

Use this lighter command only when the user wants the core MCP/router stack without the heavy optional toolchain:

```powershell
powershell -ExecutionPolicy Bypass -File ".\scripts\reverselab-deploy.ps1" -Apply -Profile Core -RegisterCodexMcp
```

## Verification

After deploy, verify:

- both repo roots exist
- `open-reverselab/.mcp.json` exists
- `Open-tgtylab/.mcp.json` exists
- `ReverseLabToolsMCP/reverse_lab_tools_mcp.py` exists
- Codex config contains `reverse_lab_tools` when MCP registration was requested
- `ai_toolcheck` has written board reports for common/windows/android/ctf-website

## Full Deploy Result

The deploy script installs everything that the upstream repositories can install from the command line. Some host-specific GUI/device tools may still require local confirmation, extraction, driver setup, or path selection. When that happens, the deploy report lists them as remaining items:

- Ghidra Java/extraction setup
- x64dbg and Scylla archive/plugin setup
- HxD installer confirmation
- Burp Suite local setup
- Android SDK platform-tools, emulator/device drivers, Frida target binaries

These are not ignored. They are detected or reported explicitly so the recipient knows what remains.

## Sharing Guarantee

After Super Brain is shared, this skill gives recipients the same one-click deploy path to install dependencies and connect the external repos.
