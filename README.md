# Super Memory Brain Package 使用说明

`super-memory-brain-package` 是一个可分发的超级记忆大脑技能包。它把一个统一入口技能、三个功能模块、NexSandglass 本地记忆引擎、安装脚本、状态检查脚本和本地记忆目录放在一起，方便安装、备份、迁移和查看。

## 当前版本

```text
0.5.43
```

版本信息见：

```text
manifest.json
CHANGELOG.md
```

## 目录结构

```text
super-memory-brain-package/
├─ README.md                         # 本说明文档
├─ QUICK_START.md                    # 一页快速开始
├─ COMMANDS.md                       # 常用命令索引
├─ manifest.json                     # 包版本和模块清单
├─ CHANGELOG.md                      # 变更记录
├─ super-memory-brain/               # 统一入口技能
│  └─ SKILL.md
├─ modules/                          # 三个模块技能
│  ├─ skill-orchestrator/            # ORC / 超级大脑 / 调度
│  ├─ plusunm-g1/                    # G1 / 记忆治理
│  └─ nexsandglass-dedicated-memory/ # 沙漏 / 本地深层记忆
├─ vendor/
│  └─ NexSandglass-Agent-DedicatedMemory/ # NexSandglass 本体源码
├─ scripts/
│  ├─ install.ps1                    # 安装脚本
│  ├─ install.bat                    # Windows 双击 UI 入口，console 参数打开控制台备用注入器
│  ├─ install-ui.ps1                 # WinForms 图形安装器，首页为统一控制台
│  ├─ install-ui.vbs                 # 无黑窗 UI 启动器
│  ├─ brain.bat                      # 双击打开超级大脑控制台
│  ├─ brain-ui.vbs                   # 超级大脑控制台无黑窗启动器
│  ├─ check-install-ui-paths.ps1      # 只读 UI 路径预检
│  ├─ health-check.ps1               # 基础健康检查
│  ├─ status.ps1                     # 状态面板
│  ├─ doctor.ps1                     # 只读一键诊断
│  ├─ maintain.ps1                   # 维护总入口：计划/安全维护/确认维护
│  ├─ summary.ps1                    # 一屏超级大脑状态摘要
│  ├─ script-tiers.ps1               # 查看脚本安全分级
│  ├─ memory-health.ps1              # 记忆健康摘要
│  ├─ memory-eval.ps1                # 只读记忆评测 harness
│  ├─ memory-eval-report.ps1         # 写入最近一次记忆评测报告
│  ├─ backup.ps1                     # 备份脚本
│  ├─ backup-retention.ps1           # 备份保留/清理候选报告
│  ├─ cleanup-install-backups.ps1    # 安装备份清理：默认预览，-Apply 后删除
│  ├─ migrate.ps1                    # 迁移脚本
│  ├─ compact.ps1                    # 记忆压缩候选报告
│  ├─ compact-report.ps1             # 精确重复记忆报告
│  ├─ compact-apply.ps1              # 带确认保护和备份的精确重复记忆清理
│  ├─ write-memory.ps1               # 记忆写入门控
│  ├─ audit-memory.ps1               # 记忆审计报告
│  ├─ baseline-update.ps1            # 更新当前基线
│  ├─ prepare-share.ps1              # 生成瘦身且不含私人记忆的分享包
│  ├─ verify-package.ps1             # 整包验证
│  ├─ auto-check.ps1                 # 自动读取/刷新最近验证状态
│  ├─ startup-check.ps1              # 启动 hook / 配置文件检查
│  ├─ update-state.ps1               # 更新轻量状态缓存
│  ├─ state.ps1                      # 读取轻量状态缓存
│  ├─ recall-search.ps1              # 搜索长期记忆
│  ├─ recall-recent.ps1              # 查看最近记忆
│  ├─ session-restore.ps1            # 新会话轻量恢复包：状态/断点/摘要/证据卡
│  ├─ learn-memory.ps1               # “学一下/记住这个”治理写入协议
│  ├─ profile-card.ps1                # 轻量用户偏好/画像卡，按需注入
│  ├─ skill-sync-check.ps1           # 检查安装技能与包内技能是否同步
│  ├─ repair-hook.ps1                # 修复/刷新 session-start hook
│  ├─ encoding-check.ps1             # 编码/乱码检查
│  ├─ graph-normalize.ps1            # 图谱 CURRENT 标记规范化
│  ├─ write-decision.ps1             # 写入结构化决策颗粒、记忆和图谱边
│  ├─ decision-search.ps1            # 只读搜索结构化决策图谱
│  ├─ decision-audit.ps1             # 只读审计决策图谱、粒子和记忆
│  ├─ bootstrap.ps1                  # 新机器一键安装验证
│  ├─ release-private.ps1            # 私人迁移包，包含 memory
│  ├─ release-share.ps1              # 分享包，不含私人 memory
│  ├─ task-verification.ps1           # 最近任务验收摘要
│  ├─ team-dispatch-check.ps1         # Commander 派工等级只读评估
│  ├─ team-task-*.ps1                 # 任务级 subagent 协作记忆
│  ├─ ci.ps1                         # 一条命令完整自检
│  ├─ lint.ps1                       # 语法检查和可选 PSScriptAnalyzer
│  └─ smoke-test.ps1                 # 临时安装冒烟测试
└─ memory/                           # 包内本地记忆与状态目录
   ├─ shared/                        # 全局共享记忆根，只有用户同意全 agent 共享时写入
   ├─ agents/                        # 单 agent 私有记忆根，如 agents/zcode、agents/codex
   ├─ groups/                        # 自定义共享组记忆根，如 groups/design-team
   ├─ workspace/                     # 包状态、验证结果、共享策略
   ├─ graph.jsonl                    # 包级 lineage / decision graph
   └─ scripts/                       # share 包 runtime 模板；实际运行时会复制到各记忆根
   └─ sandglass.db                   # 辅助索引数据库
```

## 核心功能

### 1. 一个入口技能

入口技能：

```text
super-memory-brain
```

它负责把三个模块组织成一套系统：

```text
用户消息
→ skill-orchestrator / ORC / 超级大脑
→ plusunm-g1 / G1 记忆治理
→ nexsandglass-dedicated-memory / 沙漏本地深层记忆
→ 具体任务技能或直接回答
```

### 2. 三个模块

| 模块 | 作用 |
|---|---|
| `skill-orchestrator` | 超级大脑 / ORC，负责判断当前任务需要哪些技能 |
| `plusunm-g1` | G1 记忆门，负责判断什么该记、什么不该记、冲突时听谁的 |
| `nexsandglass-dedicated-memory` | NexSandglass 沙漏，负责本地记忆写入、搜索、决策粒子和深层记忆 |

### 3. 默认记忆策略

```text
G1审记，ORC调度，沙漏只存稳态；隐私记忆需确认并标 [PRIVACY]。
```

意思是：

- G1 先判断这条信息值不值得长期记。
- ORC 判断是否需要调用沙漏。
- NexSandglass 只保存稳定偏好、接受规则、关键决策、回滚点、复用命令/路径/流程、验证结果。
- 不保存 API Key、密码、token、cookie、base64、完整 payload、SSE 流、临时噪音、长日志。

### 5. 轻量记忆路由

默认配置：

```text
memory_router: always_on_short
memory_full_injection: off
memory_retrieval: hybrid = Sandglass + graph + state + recent, semantic + keyword scored
memory_top_k: 3
memory_max_tokens: 1200
memory_default: summary_first
memory_mode: auto / force / off
```

记忆分层使用标签，不拆数据库：

```text
[PROFILE]   用户长期偏好
[PROJECT]   项目背景、技术栈、重要约定
[DECISION]  历史决策
[ADR]       架构/长期策略决策记录
[TASK]      未完成任务和上下文
[SESSION]   最近会话摘要
[SUMMARY]   摘要优先检索
[NEGATIVE_FEEDBACK] 用户否定或纠错
```

检索默认使用 Hybrid Recall：把 Sandglass 搜索、`memory\graph.jsonl` 决策/版本关系、`CURRENT_BASELINE.md` / `manifest.json` / `CHANGELOG.md` 状态锚点、最近记忆 fallback 统一成 `sourceType`、`score`、`confidence`、`reason`、`tokenEstimate` 候选，再按 `TopK` / `MaxTokens` 返回少量证据；过期、stale、负反馈记忆降权，不自动删除。用户说“不是这个 / 别按上次 / 不对 / 错了 / 以后不要”时写为负反馈，防止错误记忆反复出现。

从 `0.5.41` 开始，学习和画像恢复更稳：

- `scripts\learn-memory.ps1 -Preview` 会先展示将学习的摘要、标签、分类和相似记忆证据卡；发现高相似记忆时默认不重复写入，除非显式使用 `-AllowDuplicate`。
- `scripts\profile-card.ps1` 会把用户偏好、习惯、画像相关记忆压缩成 `memory\workspace\profile-card.json`，新会话只有命中画像/偏好触发时才注入这张小卡。
- `scripts\session-restore.ps1` 会按需读取 profile card，避免把完整长期记忆放进启动上下文。

从 `0.5.40` 开始，超级大脑新增两条默认协议：

- `scripts\learn-memory.ps1`：当你说“学一下 / 记住这个 / 以后按这个”时，把内容压缩成稳定摘要，经 G1 标签、隐私和质量门控后写入长期记忆；需要经验复用时还能同步到 `experience-index.md`，避免保存整段聊天噪音。
- `scripts\session-restore.ps1`：新会话默认只生成轻量恢复包，包含版本状态、活动断点、最近状态快照、经验索引预览和按需证据卡；只有命中“继续 / 上次 / 还记得 / 按我的习惯”等触发词，才做更深的 Hybrid Recall，避免启动上下文越来越重。

从 `0.5.39` 开始，Hybrid Recall 默认使用 token budget 和 evidence cards：`memory-policy.json` 的 `contextBudget` 会限制证据 token，`recall-search.ps1` 会为每条候选生成 `evidenceCard`，包含 `source / claim / whyRelevant / confidence / lastVerified / snippet / tokenEstimate`。这样默认上下文更短，判断仍保留来源、理由、置信度和最近性。

从 `0.5.38` 开始，Hybrid Recall 还会做三件事：

- 优先记住更近的事情：候选增加 `ageDays`、`recencyScore`、`recallPriority`，近事更容易被叫起。
- 更容易想起你是什么样的人：当问题涉及“我的偏好 / 我的性格 / 我的经历 / 按我的习惯来 / 你还记得我吗”时，会提高 `profile`、`experience`、`persona` 证据优先级。
- 长任务真正有断点：`scripts\checkpoint-writer.ps1` 把预执行任务写成 `memory\workspace\active-checkpoint.json`，完成后清理或 supersede，`super-brain-dashboard.ps1`、`auto-continuation.ps1`、`completion-guard.ps1` 都会用它。

### 6. 召回触发

当用户提到这些内容时，应先查显式记忆 / NexSandglass，再回答：

```text
另一个会话
上次
之前
以前
还记得吗
改到哪了
进度
超级大脑状态
接受过的规则
旧决策
```

### 7. Commander Agent Teams

超级大脑现在可以在不替换 ORC/G1/NexSandglass 的前提下，按任务复杂度自动评估是否需要 subagent 协作：简单任务保持 `direct`，跨文件/长任务/架构/高风险任务可升级为 `single_delegate`、`team_parallel` 或 `review_board`。subagent 只提交证据、假设、未知项、风险和建议；Commander 审核后才采纳逻辑或写入记忆。硬规则是：不能瞎写代码和逻辑。

只读派工评估：

```powershell
scripts\team-dispatch-check.ps1 -ArchitectureChange -LongTask -LogicSafetyRequired
scripts\team-dispatch-check.ps1 -Json
```

私有 workspace team-task 记录：

```powershell
scripts\team-task-new.ps1 -Goal "..." -DispatchLevel review_board
scripts\team-task-status.ps1
```

Agent Team templates are private workspace configuration in `memory\workspace\agent-teams.json`. Use `team-template-list.ps1` to inspect templates and `team-template-select.ps1` to see which template Commander would attach for a dispatch level and reason set.

Durable Agent/subagent roadmap memory must stay current: `0.5.20` Agent Team 模板化, `0.5.21` Code-Capable Subagent Authorization, `0.5.22` Drift Guard + Commander Review Gate, and `0.5.23` Team Memory Retrieval. When this route advances, update or supersede the roadmap ADR so future status/recall answers can report completed version, current step, remaining targets, and blockers without relying on the user to reconstruct context.

Stability helpers in `0.5.24` make this proactive: `roadmap-manager.ps1` builds the route status card, `memory-regression-checker.ps1` verifies critical memories are still recallable, `task-state-reporter.ps1` reports current completion state, `privacy-sentinel.ps1` warns about private-pattern hits before sharing, and `completion-guard.ps1` aggregates verification, hot refresh, task evidence, recall regression, review gate, and privacy status before completion.

State control helpers in `0.5.25` make status and continuation explicit: `super-brain-dashboard.ps1` is the unified dashboard, `auto-continuation.ps1` decides where `继续` should resume from, and `status-snapshot-writer.ps1` writes a durable `last-status-snapshot.json` checkpoint for the next session.

Quality helpers in `0.5.26` make health findings actionable: `privacy-hit-locator.ps1` locates private-pattern hits, `memory-quality-fixer.ps1` produces WhatIf cleanup actions, `lesson-replay.ps1` recalls matching lessons, dashboard text output is compact, and CI explicitly runs the state-control checks. `0.5.28` also hardens `task-verification.ps1` so unnamed command-line array values fail fast instead of being silently bound to later completion fields, and restores memory-sharing policy after smoke-test temporary installs. `0.5.29` adds regression guards for both safeguards through Pester tests and package verification checks. `0.5.30` adds dispatch learning and trigger simulation so autonomous routing is checked against historical team-task evidence and common prompt scenarios. `0.5.35` adds practical Super Brain entrances for intent routing, smart next actions, health summaries, Agent Team scorecards, task retrospectives, and release readiness. `0.5.36` adds a unified `brain.ps1` command and dry-run-first `version-bump.ps1` helper.

```powershell
scripts\team-template-list.ps1 -Json
scripts\team-template-select.ps1 -DispatchLevel review_board -Reason architecture_change,logic_safety_required -Json
scripts\roadmap-manager.ps1 -Json
scripts\memory-regression-checker.ps1 -Json
scripts\task-state-reporter.ps1 -Json
scripts\privacy-sentinel.ps1 -Json
scripts\completion-guard.ps1 -Json -AllowPrivacyRisk
scripts\super-brain-dashboard.ps1 -Json
scripts\auto-continuation.ps1 -Json
scripts\status-snapshot-writer.ps1 -Summary "checkpoint" -NextAction "continue from dashboard" -Json
scripts\privacy-hit-locator.ps1 -Json
scripts\memory-quality-fixer.ps1 -Json
scripts\lesson-replay.ps1 -Query "install ui" -Json
scripts\dispatch-learning.ps1 -Json
scripts\trigger-simulation.ps1 -Json
scripts\brain.ps1 status
scripts\brain.ps1 next 继续
scripts\brain.ps1 release
scripts\version-bump.ps1 -Version 0.5.37 -Summary "next change" -Json
scripts\intent-router.ps1 继续 -Json
scripts\smart-next.ps1 继续 -Json
scripts\health-summary.ps1 -Json
scripts\agent-scorecard.ps1 -Json
scripts\task-retrospective.ps1 -Summary "checkpoint" -Json
scripts\release-readiness.ps1 -Json
scripts\team-task-review-gate.ps1 -Json
scripts\team-memory-retrieval.ps1 -Query "subagent" -TopK 5 -Json
```

Future code-capable subagents require explicit Commander authorization, allowed-file boundaries, forbidden-file boundaries, success criteria, verification commands, rollback notes, and drift-guard review. Templates do not grant write permission by themselves.

### 8. 旧记忆导入

推荐通过安装 UI 操作：把旧 memory 文件内容放入 `memory\merge-overlay`；如果你直接把整个旧 `memory` 文件夹拖进去，形成 `memory\merge-overlay\memory`，脚本也会自动识别这一层并从里面导入。打开 `scripts\install.bat`，首页点“打开记忆导入页”，先刷新检测，再选择“合并旧记忆”或“覆盖冲突文件”。合并会追加同名文本记忆并保留非文本新文件；覆盖只覆盖同名文件，不删除新目录中旧目录没有的文件。执行前需要输入 `MERGE` 或 `OVERWRITE` 二次确认；执行成功后会自动删除 `memory\merge-overlay`，避免下次重复检测。

命令行等价操作：

```powershell
scripts\migrate-memory-layout.ps1 -ImportRoot "<package-root>\memory\merge-overlay" -Mode Merge -Apply -CleanupImport
scripts\migrate-memory-layout.ps1 -ImportRoot "<package-root>\memory\merge-overlay" -Mode Overwrite -Apply -CleanupImport
```

## 推荐使用方式

默认总入口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\ci.ps1"
```

`ci.ps1` 会串起 lint、包验证、Memory Eval Harness、维护检查、分享包验证、冒烟安装和完整集成验证，并写入机器可读状态：

```text
memory\workspace\last-ci.json
memory\workspace\last-memory-eval.json
```

这条命令通过，代表当前包处于“安装即用、稳定可靠”的状态。若中途某一步失败，`ci.ps1` 也会继续写入 `memory\workspace\last-ci.json`，Memory Eval Harness 会写入 `memory\workspace\last-memory-eval.json`，方便下一轮定位。

## 安装方法

### Windows 双击 UI 安装

优先使用统一控制台：

```text
scripts\brain.bat
```

它会打开超级大脑控制台。控制台首页集中提供状态摘要、自然语言输入、下一步建议、意图识别、发包检查、无记忆分享包、Agent 评分、调度学习、完整 CI 和热刷新技能。

也可以打开技能注入器：

运行：

```text
scripts\install.bat
```

它默认打开 WinForms 图形技能注入器。若需要控制台备用注入器，可运行：

```text
scripts\install.bat console
```

也可以直接运行无黑窗 UI 启动器：

```text
scripts\install-ui.vbs
```

### PowerShell 安装

在 PowerShell 里运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\install.ps1"
```

安装后会复制技能到：

```text
%USERPROFILE%\.zcode\skills
%USERPROFILE%\.codex\skills
```

已安装 skill 目录只作为发现入口，并会生成两个指针文件：

```text
package-root.txt  # 指向当前 install.ps1 所在的完整 super-memory-brain-package
memory-root.txt   # 指向当前启用的记忆目录
```

默认全局共享记忆目录（只有用户同意所有 agent 共享时写入）：

```text
super-memory-brain-package\memory\shared
```

分离记忆模式：

```text
super-memory-brain-package\memory\agents\zcode
super-memory-brain-package\memory\agents\codex
```

其他 agent 默认接入全局共享记忆；需要隔离时，可在对应 Agent 内显式切换到私有记忆目录：

```text
super-memory-brain-package\memory\agents\<agent-name>
```

自定义共享组目录：

```text
super-memory-brain-package\memory\groups\<group-name>
```

默认安装会把 ZCode、Codex 和通过安装器注入的其它 Agent 指向 `memory\shared` 全局共享记忆。若某个 Agent 需要隔离，可在该 Agent 内显式切换到 `memory\agents\<agent-name>` 私有记忆或指定群组记忆。

未知 agent 接入：

```powershell
scripts\install-agent.ps1 -AgentName my-agent -SkillRoot "D:\SomeAgent\skills"
scripts\install-agent.ps1 -AgentName my-agent -SkillRoot "D:\SomeAgent\skills" -Mode Group -GroupName research
scripts\install-agent.ps1 -AgentName my-agent -SkillRoot "D:\SomeAgent\skills" -Mode Shared
```

迁移旧记忆布局（只复制，不删除旧目录）：

```powershell
scripts\migrate-memory-layout.ps1 -Apply
```

安装时会自动刷新真实 `session-start` hook 里的超级大脑路径，让新会话指向当前这份包。安装脚本会先备份已有 skill，失败时自动回滚；换电脑或移动目录后，重新运行 `install.ps1` 即可更新 hook 路径。

热加载约定：已安装 skill 正文保持轻量副本，运行时通过 `package-root.txt` 和 `memory-root.txt` 动态指向当前包和当前记忆根。`memory-mode.ps1`、`install-agent.ps1` 或手动更新 marker 后，不需要重写 skill 正文；下一次加载该 skill 时会读取最新 root marker。改动包内技能/规则/runtime 后，应主动运行 `scripts\hot-refresh-skills.ps1 -AllKnown` 轻量刷新已安装 Agent 技能副本、root marker 和 memory runtime；如果 Agent 缓存了技能内容，则新开会话后生效。

为了避免启动变慢，`session-start` hook 只注入短启动规则，不在每次新会话启动时运行重检查。重检查放在 `status.ps1`、`auto-check.ps1`、`verify-package.ps1`、`bootstrap.ps1` 里按需执行。

## 常用脚本

双击或运行图形安装器启动包：

```powershell
scripts\install.bat
```

无黑窗 UI 入口：

```powershell
scripts\install-ui.vbs
```

旧命令行菜单入口：

```powershell
scripts\install.bat console
```

UI 现在只做三件事：一键全局注入/刷新 ZCode + Codex（默认全局共享记忆）、给自动识别或手动填写的 Agent `skills` 目录注入技能、预览并清理旧 `install-backup-*` 备份。界面文案为中文，执行长任务时会临时禁用操作区、防止重复点击，并把子脚本输出实时写入日志框。

只读维护计划：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\maintain.ps1"
```

一条命令完整自检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\ci.ps1"
```

`ci.ps1` 会串起 lint、包验证、维护检查、分享包验证、冒烟安装和完整集成验证，并写入 `memory\workspace\last-ci.json`，用于确认“安装即用、稳定可靠”。

低风险安全维护：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\maintain.ps1" -ApplySafe
```

确认维护入口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\maintain.ps1" -ApplyConfirmed
```

只读一键诊断（包含风险聚合）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\doctor.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\doctor.ps1" -Json
```

UI 路径预检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\check-install-ui-paths.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\check-install-ui-paths.ps1" -Json
```

### 状态面板

快速一屏摘要：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\summary.ps1"
```

快速状态缓存：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\state.ps1"
```

刷新状态缓存：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\update-state.ps1"
```

完整状态面板：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\status.ps1"
```

它会检查：

```text
Super Memory Brain: OK / MISSING
ORC / skill-orchestrator: OK / MISSING
G1 / plusunm-g1: OK / MISSING
NexSandglass skill: OK / MISSING
Package memory root: OK / MISSING
NexSandglass runtime log: OK / MISSING
NexSandglass runtime vault: OK / MISSING
Session-start hook: OK / MISSING
Hook startup rule: OK / MISSING
Hook memory shortcut: OK / MISSING
Hook recall trigger: OK / MISSING
Startup auto-check: OK / FAILED
Recent memory: ...
```

### 启动检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\startup-check.ps1"
```

它会检查 ZCode/Codex 技能安装、包内记忆根目录、真实 `session-start` hook、启动注入规则、启动规则长度、当前包路径、召回触发和常见配置文件是否存在。`status.ps1`、`health-check.ps1`、`verify-package.ps1` 会自动调用它。

### 自动检测（助手优先）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\auto-check.ps1"
```

对话里遇到首次运行、`继续`、状态询问或疑似故障时，助手应优先读 `memory\workspace\super-brain-state.json`；如果轻量状态缺失、过期或失败，再读 `memory\workspace\last-verify-package.json` 或自动运行 `auto-check.ps1` / `verify-package.ps1`，不要求用户手动发送命令。

### 健康检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\health-check.ps1"
```

### 一键新机器安装验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\bootstrap.ps1"
```

### 修复启动 hook

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\repair-hook.ps1"
```

### 维护检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\encoding-check.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\graph-normalize.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\compact-report.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\compact-apply.ps1" -WhatIfOnly
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\memory-health.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\script-tiers.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\backup-retention.ps1"
```

`compact-apply.ps1` 只删除完全重复的记忆文本；默认 `-WhatIfOnly` 只预览，真正修改需要显式 `-Force`，执行前会备份 `sandglass.txt`。

`backup-retention.ps1` 默认只报告包备份、压缩备份和 hook 备份的清理候选；真正删除需要显式 `-Apply`。

### 脚本分级和分享包瘦身

`manifest.json` 是公开操作脚本的单一清单来源，`verify-package.ps1` 会检查 `scripts\*.ps1` / `scripts\*.bat` 是否和 manifest 一致。

脚本安全分级：

```text
T0 = 只读查询 / 状态 / 报告
T1 = 低风险生成状态 / 验证 / 复制发布包
T2 = 修改记忆、hook、图谱或安装目录，需要明确意图
T3 = 删除、覆盖、私人导出、清理备份等高影响操作，必须手动确认
```

分享包由 `prepare-share.ps1` 按 manifest 复制脚本，并只复制 NexSandglass 必要运行文件；不会带内部 Python helper、`.git`、zip、demo、`__pycache__`、`.pyc`、私人记忆、`memory\shared`、`memory\agents`、`memory\groups`、共享策略或本机状态缓存。`prepare-share.ps1` 会保护目标路径，避免误删包根、父目录、用户目录或磁盘根目录；覆盖已有分享目录时要求目标带分享包标记，未标记目录需显式 `-Force`。公开/GitHub 分享包会自动生成根级 `.gitignore`，排除本地记忆、marker、缓存、日志、生成包和密钥文件，并把已知本机绝对路径替换为 `<package-root>` / `<memory-root>` / `<user-home>` 等占位符。`verify-share.ps1` 会验证瘦身规则、分享包标记、`.gitignore`、通配隐私文件、敏感文本模式和本机路径残留。当前默认分享包目录是同级 `super-memory-brain-package-share*`。

### Hybrid Recall 辅助

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\recall-recent.ps1" -Count 5
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\recall-search.ps1" -Query "super-memory-brain" -TopK 3 -MaxTokens 1200 -Json
```

`recall-search.ps1` 返回统一候选结构：`text`、`source`、`sourceType`、`layer`、`tags`、`score`、`confidence`、`reason`、`tokenEstimate`。`MemoryMode off` 会跳过召回，`Layer` 可限制 profile/project/decision/task/session。

### Memory Eval Harness

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\memory-eval.ps1" -Json
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\memory-eval-report.ps1"
```

`memory-eval.ps1` 是 T0 只读评测入口，覆盖 staticSources、recallSearch、decisionSearch case；`memory-eval-report.ps1` 是 T1 报告入口，会写 `memory\workspace\last-memory-eval.json`。

### 技能同步检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\skill-sync-check.ps1"
```

### 决策 / ADR 检索和审计

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\decision-search.ps1" -Query "super-memory-brain"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\decision-search.ps1" -AdrOnly -Status accepted
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\decision-audit.ps1"
```

`write-decision.ps1` 会同时写入结构化 decision particle、Sandglass 决策摘要和 `memory\graph.jsonl` 决策边；传入 `-Adr` 或 ADR 字段时会写 `[DECISION][ADR]`，并记录 `has_title`、`has_status`、`has_context`、`has_consequence`、`has_owner`、`affects`、`has_alternative`、`supersedes`、`superseded_by`。`decision-audit.ps1` 只读检查 graph JSONL、决策 current 冲突、ADR schema 缺口、非法 status、supersedes 指向和粒子格式异常。

### 写入决策 / ADR

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\write-decision.ps1" -Question "选哪个方案" -Decision "采用 B"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\write-decision.ps1" -Adr -Question "长期召回策略" -Title "Hybrid Recall" -Decision "采用 Sandglass + graph + state + recent" -Context "状态和决策需要可审计召回" -Consequences "召回输出 score/confidence/reason/tokenEstimate" -Scope "memory"
```

### 备份

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\backup.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\backup-retention.ps1"
```

会在包目录下生成：

```text
backup-YYYYMMDD-HHMMSS/
```

`backup-retention.ps1` 默认只预览清理候选；真正删除旧备份需要显式加 `-Apply`。

### 迁移

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\migrate.ps1" -Destination "D:\Backup"
```

### 记忆压缩候选报告

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\compact.ps1"
```

这个脚本只搜索可能重复的记忆，不自动删除历史。

## 记忆放在哪里？

现在记忆就在包下面：

```text
super-memory-brain-package\memory
```

主记忆文件是：

```text
memory\sandglass.txt
```

它不是 `.ps1` 文件。`.ps1` 是脚本；真正的记忆是 `.txt` / `.idx` / `.db` 等数据文件。

### 发布包生成

私人迁移包，包含自己的 `memory/`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\release-private.ps1"
```

分享包，不含私人记忆，适合 GitHub/public 手动上传：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\release-share.ps1"
```

成功时会输出 `PUBLIC_SAFE_PACKAGE <path>`、`INCLUDES_MEMORY false`、`VERIFY_STATUS ok`。只上传这个生成目录；不要上传 live package root、`release-private.ps1` 产物、`memory\shared`、`memory\workspace` 或 `install-backup-*`。

旧的一体发布入口仍可用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<package-root>\scripts\release.ps1"
```

`memory\sandglass.txt` 是追加式明文记忆文件。每写入一条记忆，就追加一行。随着使用时间变长，它会逐渐变大。

这也是为什么包里有：

```text
scripts\compact.ps1
```

它用来查找重复记忆、旧规则和可合并内容。当前为了安全，它只生成候选报告，不自动删除。

## 记忆有没有日期？

有。

`sandglass.txt` 每一行格式大致是：

```text
YYYY-MM-DD HH:mm:ss | sender | memory text
```

示例：

```text
2026-06-17 02:56:52 | user | package-local memory verified: super-memory-brain now stores memory under package memory folder
```

也就是说，每条记忆都有精确日期和时间。

## 如何手动写入一条记忆？

PowerShell 示例：

```powershell
$pkg = "<package-root>"
$env:NEXSANDBASE_HOME = Join-Path $pkg "memory"
$env:PYTHONPATH = Join-Path $env:NEXSANDBASE_HOME "scripts"
python -c "from sandglass_log import log_message; print(log_message('这里写要长期保存的记忆', 'user'))"
```

## 如何搜索记忆？

```powershell
$pkg = "<package-root>"
$env:NEXSANDBASE_HOME = Join-Path $pkg "memory"
$env:PYTHONPATH = Join-Path $env:NEXSANDBASE_HOME "scripts"
python -c "from sandglass_vault import search; print(search('关键词'))"
```

## 如何查看最近记忆？

```powershell
$pkg = "<package-root>"
$env:NEXSANDBASE_HOME = Join-Path $pkg "memory"
$env:PYTHONPATH = Join-Path $env:NEXSANDBASE_HOME "scripts"
python -c "from sandglass_vault import recent; print(recent(5))"
```

## 隐私注意

这个包现在包含记忆目录：

```text
memory/
```

如果你要把这个包发给别人，必须先确认是否要包含自己的记忆。

如果不想把私人记忆发出去，请删除或排除：

```text
super-memory-brain-package\memory\sandglass.txt
super-memory-brain-package\memory\sandglass.idx
super-memory-brain-package\memory\sandglass.db
super-memory-brain-package\memory\decision_particles.txt
super-memory-brain-package\memory\persona\
super-memory-brain-package\memory\archive\
```

更安全的分发方式是：

```text
发技能和脚本，不发 memory/ 里的个人数据。
```

可以保留空目录：

```text
memory\scripts
memory\persona
memory\archive
```

但不要带自己的 `sandglass.txt`。

## 结构化记忆能力

0.3.0 起，包内增加结构化记忆层：

```text
CURRENT_BASELINE.md                 # 当前状态锚点
BASELINE_HISTORY.md                 # 基线演化历史
memory/graph.jsonl                  # 关系图谱 / 因果链
memory/workspace/session-notes.md   # 短期工作记忆压缩结果
tests/memory-recall-tests.json      # 召回测试集
```

新增脚本：

```text
scripts/graph-add.ps1               # 添加关系
scripts/graph-search.ps1            # 搜索关系
scripts/extract-facts.ps1           # 从文本提取候选事实
scripts/test-recall.ps1             # 测试记忆召回规则
scripts/tag-legacy-memory.ps1       # 给旧记忆补 [HISTORY] 标签
scripts/session-compact.ps1         # 压缩短期工作记忆
```

当前状态类问题应优先读取：

```text
memory/workspace/super-brain-state.json → memory/workspace/last-verify-package.json → CURRENT_BASELINE.md → manifest.json → CHANGELOG.md → NexSandglass 搜索 → live file verification
```

## 当前推荐使用方式

日常只需要记住三件事：

1. 看状态：

```powershell
scripts\status.ps1
```

2. 安装到新机器：

```powershell
scripts\install.bat
```

3. 记忆在这里：

```text
memory\sandglass.txt
```
