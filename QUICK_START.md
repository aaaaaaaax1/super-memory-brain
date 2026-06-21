# 快速开始

Super Memory Brain 包快速上手。

## 1. 安装

双击启动 Windows 图形技能注入器：

```text
scripts\install.bat
```

无黑窗 UI 启动器：

```text
scripts\install-ui.vbs
```

命令行菜单备用入口：

```text
scripts\install.bat console
```

UI 现在是“技能注入器”：一键全局注入/刷新 ZCode + Codex（默认全局共享记忆）、热刷新已安装 Agent 技能副本、给自动识别或手动填写的 Agent `skills` 目录注入技能、从 `memory\merge-overlay` 或常见的 `memory\merge-overlay\memory` 检测旧记忆并选择合并/覆盖、生成默认无记忆分享包（可选勾选含记忆私人包）、预览并清理旧安装备份 `install-backup-*`。Agent 需要隔离时，再在对应 Agent 内显式切换私有记忆。界面文案为中文，长任务运行时会禁用操作区、防止重复点击，并实时显示子脚本日志。

也可以直接运行 PowerShell，只安装 ZCode/Codex：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\install.ps1" -MemoryMode Shared
```

## 2. Check status

Recommended default self-check:

```powershell
scripts\ci.ps1
```

It writes:

```text
memory\workspace\last-ci.json
memory\workspace\last-memory-eval.json
```

Fast one-screen summary:

```powershell
scripts\summary.ps1
```

Read-only maintenance plan:

```powershell
scripts\maintain.ps1
```

Safe low-risk maintenance:

```powershell
scripts\maintain.ps1 -ApplySafe
```

Read-only diagnosis:

```powershell
scripts\doctor.ps1
scripts\doctor.ps1 -Json
scripts\check-install-ui-paths.ps1
scripts\check-install-ui-paths.ps1 -Json
```

Read-only Commander dispatch estimate for complex work:

```powershell
scripts\team-dispatch-check.ps1 -ArchitectureChange -LongTask -VerificationRequired
scripts\team-dispatch-check.ps1 -Json
```

Commander keeps ORC/G1/NexSandglass active and only opens subagent/team-task collaboration when evidence value is worth it.

Inspect Agent Team templates:

```powershell
scripts\team-template-list.ps1
scripts\team-template-select.ps1 -DispatchLevel team_parallel -Reason broad_search,parallelizable
```

Templates select role sets only; code-capable subagents are future work and require explicit Commander authorization plus drift-guard review.

## 3. Check startup and sync

```powershell
scripts\startup-check.ps1
scripts\skill-sync-check.ps1
scripts\memory-mode.ps1 -Mode Status
```

## 4. Check memory health

```powershell
scripts\memory-health.ps1
```

## 5. Search memory with Hybrid Recall

```powershell
scripts\recall-search.ps1 -Query "super-memory-brain" -TopK 3 -MaxTokens 1200 -Layer all -Json
```

Default memory mode is `auto`: Hybrid Recall combines Sandglass, graph, state anchors, and recent fallback into scored candidates with `sourceType`, `confidence`, `reason`, and `tokenEstimate`; no full-history injection.

## 6. Check decisions and ADRs

```powershell
scripts\decision-search.ps1 -Query "super-memory-brain"
scripts\decision-search.ps1 -AdrOnly -Status accepted
scripts\decision-audit.ps1
```

`decision-search.ps1` is read-only and returns current/verified decisions first. ADR records add status/context/consequence/supersedes metadata; `decision-audit.ps1` reports decision graph, ADR schema, particle, and memory consistency without printing raw private memory.

## 7. Run memory eval

```powershell
scripts\memory-eval.ps1 -Json
scripts\memory-eval-report.ps1
```

`memory-eval.ps1` is read-only. `memory-eval-report.ps1` writes `memory\workspace\last-memory-eval.json` for auditability.

## 8. Share safely

Create a privacy-clean GitHub/public share package:

```powershell
scripts\release-share.ps1
```

The command prints `PUBLIC_SAFE_PACKAGE <path>` after the generated package passes verification. Upload only that generated directory to GitHub; do not turn the live package root into a public repository.

Verify share privacy, marker, `.gitignore`, slimness, secret patterns, and local path cleanup:

```powershell
scripts\verify-share.ps1 -Destination "<PUBLIC_SAFE_PACKAGE path>" -SkipPrepare
```

`prepare-share.ps1` protects the destination path and will not delete unmarked existing directories unless `-Force` is used intentionally. Public share packages include a root `.gitignore` that keeps local memory, machine markers, logs, caches, generated releases, and secrets out of git.

Do not publish these sources to GitHub:

```text
live package root
release-private.ps1 output
memory\shared\
memory\workspace\
memory\agents\
memory\groups\
memory\persona\
memory\archive\
install-backup-*\
```

Do not share private memory files unless intentionally sharing local memory:

```text
memory\sandglass.txt
memory\sandglass.idx
memory\sandglass.db
memory\shadow_sand.db
memory\decision_particles.txt
memory\workspace\*.json
memory\persona\
memory\archive\
```

## Memory mode

Shared package, shared memory:

```powershell
scripts\memory-mode.ps1 -Mode Shared
```

Shared package, separated ZCode/Codex memory:

```powershell
scripts\memory-mode.ps1 -Mode SplitMemory
```

Other agents use `memory\agents\<agent-name>` by default and can be installed into any compatible skills directory:

```powershell
scripts\install-agent.ps1 -AgentName explore-agent -SkillRoot "D:\SomeAgent\skills"
scripts\memory-mode.ps1 -Mode Agent -AgentName explore-agent -Target Codex
```

Group sharing uses `memory\groups\<group-name>`:

```powershell
scripts\memory-mode.ps1 -Mode Group -GroupName research -Target Both
```

`memory\workspace\memory-sharing-policy.json` records the user's choice. First use must ask whether all agents share memory, each agent uses private memory, a named group shares memory, or persistent writes stay off. `.neurobase`, `memory-zcode`, `memory-codex`, and `memory-<agent-name>` are legacy fallback/migration sources only; current installs use `memory-root.txt`.
