# Super Memory Brain Package 使用说明

`super-memory-brain-package` 是一个可分发的超级记忆大脑技能包。它把一个统一入口技能、三个功能模块、NexSandglass 本地记忆引擎、安装脚本、状态检查脚本和本地记忆目录放在一起，方便安装、备份、迁移和查看。

默认安装入口是包根目录的 `install.bat`（分享包也带此入口），它转发到统一 `scripts\bootstrap.ps1` 完成技能、hook、正式记忆根、MCP 和集成验证。首次加载“超级大脑”时，hook 还会自主检查 MCP 是否存在、是否绑定当前包和正式记忆根；发现过期或临时路径时会自动修复并要求新任务重新发现 MCP。图形界面和交互菜单是备用入口，分别使用 `install.bat ui` 和 `install.bat console`。朋友安装和隐私边界见 `FRIEND_INSTALL.md`。

## 当前版本

```text
0.5.96
```

版本信息见：

```text
manifest.json
CHANGELOG.md
```

## 客观评测边界

`scripts\intelligence-eval.ps1` 只用于包内回归验收，其加权值不是客观智能分。
当前外部客观状态是 `not_scored`。可比较结论必须在相同模型、版本、工具、
预算和环境下做基础 Codex 与 Codex+超级大脑的官方基准配对 A/B，只改变
`super_memory_brain_enabled`，并保留盲评和官方 harness 工件。

```powershell
scripts\objective-benchmark.ps1 -Action Plan -Json
scripts\objective-benchmark.ps1 -Action Evaluate -ResultsPath <paired-run.json> -ReportPath <report.json> -Json
```

报告只给出每个公开基准的原始通过率、配对增益、置信区间和胜负数，不把
SWE-bench、BFCL、LongMemEval、tau3-bench 拼成自定义总分。

## 扩展和技能能力中心

超级大脑可以把扩展进来的技能/插件转成 ORC 可路由能力，不需要你每次手动指定技能名。

常用命令：

```powershell
scripts\brain.ps1 skills
scripts\brain.ps1 skills 浏览器
scripts\brain.ps1 capability browser-act
scripts\brain.ps1 extensions
scripts\extension-ingest.ps1 -Action Inspect -Path <技能或插件目录> -Json
scripts\extension-ingest.ps1 -Action Adopt -Path <技能或插件目录> -ExtensionId <id> -Json
scripts\extension-ingest.ps1 -Action RebuildMap -Json
```

`skills` / `capability` 是查看和诊断入口；真正执行时仍由 ORC 根据意图、触发词、能力、适用阶段、setup 要求和验证证据自动路由。

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
│  ├─ workspace-lifecycle-manager.ps1 # 工作区生命周期维护：会话绑定/AgentBridge/锁/tmp
│  ├─ auto-hygiene-runner.ps1        # 自动记忆卫生：过长压缩/重复清理/隐私命中提示
│  ├─ post-task-maintenance.ps1      # 任务后安全维护 hook
│  ├─ self-improvement-queue.ps1     # 自改进候选队列
│  ├─ summary.ps1                    # 一屏超级大脑状态摘要
│  ├─ script-tiers.ps1               # 查看脚本安全分级
│  ├─ memory-health.ps1              # 记忆健康摘要
│  ├─ agent-bridge-channel.ps1           # 跨 Agent 共享会话通道；Open/Send/Inbox/Ack/Close/Status
│  ├─ checkpoint-writer.ps1              # 写入 active checkpoint，并登记共享 agent/session/task 身份卡
│  ├─ task-register.ps1                  # 轻量登记共享任务状态；不触碰 active checkpoint，不跑重检查
│  ├─ task-index.ps1                     # 跨 Agent/会话任务索引；-Table 输出窄 Markdown 状态表
│  ├─ memory-eval.ps1                    # 只读记忆评测 harness
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
│  ├─ session-binding.ps1            # 临时会话绑定 evidence bundle：TTL/memory:off/版本/根路径/隐私守卫
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


## 可选扩展技能包

`extensions/` 内置可选扩展，不默认常驻、不默认安装：

- `karpathy-guidelines`：AI/ML、第一性原理、避免过度工程、代码验证习惯。
- `mattpocock-skills`：TypeScript、React、TDD、PRD、triage、前端工程工作流；仅收 curated subset，排除 deprecated/in-progress/personal。

启用方式示例：

```powershell
scripts\install.ps1 -Extensions karpathy-guidelines,mattpocock-skills
scripts\hot-refresh-skills.ps1 -AllKnown -Extensions karpathy-guidelines,mattpocock-skills
scripts\verify-extensions.ps1
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


### 3.6 自动维护与压缩续接

0.5.73 起，超级大脑会把低风险本地维护当成默认职责：

- `maintenance-policy.json` 定义哪些维护可自动做、哪些必须确认、哪些永不自动做。
- `scripts\workspace-lifecycle-manager.ps1` 处理过期 `session-binding.json`、过期/关闭 Agent Bridge 临时通道、陈旧 active pointer、陈旧锁、生成型 tmp 文件。
- `scripts\auto-hygiene-runner.ps1` 对过长记忆和精确重复记忆做证据归档后压缩/清理；物理删改后同步重建 Sandglass、SQLite FTS、Shadow Sand 和图谱行号；隐私命中只提示确认，不自动删除。
- `scripts\post-task-maintenance.ps1` 在任务验证后串起生命周期维护、记忆卫生、自改进队列、状态快照。
- `scripts\self-improvement-queue.ps1` 用稳定问题家族管理遗漏、自动化缺口和逻辑断点。`Status` 零写入，`Collect` 只更新家族计数，`Resolve` 必须携带验证证据，`Maintain` 同步反思终态并把关闭、重复、陈旧或超预算实例写入可恢复归档；活跃候选默认不超过 32 个，且不改技能、不发布、不越权。

压缩/续接时的优先级固定为：可见上文 → 压缩摘要/记录 → checkpoint/status/ledger/最近工具结果 → 长期记忆补充。长期记忆不能覆盖更新的可见上下文。

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

从 `0.5.96` 开始，Sandglass 候选检索采用自适应稀疏链：先用本地 FTS5 完成低延迟关联召回，候选不足时再调用 IDX 模糊索引，全部未命中时才进入旧四路路由兜底；随后仍由 `BrainCore` 统一执行图关系、来源、时效、置信度和未知事实拒答。该路径不增加启动文本，也不要求向量模型或外部图数据库。

从 `0.5.78` 开始，超级大脑增加跨路由的“工程判断”能力：修复、优化、架构、性能、迁移、根因和最优方案任务会自动启用 `references/engineering-judgment.md`，普通问候和低风险小任务仍保持直接路径。`scripts/engineering-decision-gate.ps1` 强制区分 `FACT / INFERENCE / UNKNOWN`，事实必须绑定当前证据，根因必须标记 `verified / hypothesis / unknown`，关键未知需要最低成本判别测试；没有目标、约束、备选、权衡、标准和未知解消证据时，不允许声称“最优”。每个执行步骤都要有输入、输出、验收和停止条件。

从 `0.5.72` 开始，超级大脑增加“目标路线锁”和“已验证模块集成一致性守卫”：`scripts/goal-route-lock.ps1` / `scripts/route-checkpoint.ps1` 负责记住用户已同意的主目标、路线、非目标和禁止漂移方向，发现偏航时输出 `ROUTE_DRIFT_DETECTED`；`scripts/verified-module-snapshot.ps1` / `scripts/integration-parity-check.ps1` 负责记录模块验证契约，并在接入主体时检查入口、参数、环境、依赖、状态、调用链和验收路径是否仍一致，发现变形时输出 `INTEGRATION_DRIFT_DETECTED`。完成标准拆分为 `module smoke OK`、`integration smoke OK`、`user-facing acceptance OK`，避免“模块测通但主体跑不通”。`scripts/causal-change-plan.ps1` 把结构化改动固定成因果计划：observed problem -> root cause -> known facts/prior changes -> proposed change -> expected optimization -> verification method -> residual risk；吸收 RCA、Theory of Change、Systems Thinking、OODA/PDCA/AAR、ADR 和 anti-overfitting lesson guard 的思路，要求先说明原因、假设、预期改善和验证方式，再修改和学习。

从 `0.5.71` 开始，超级大脑增加受控自我学习闭环：`scripts/cognitive-enforce.ps1` 把高风险任务的认知预检变成强制门，`scripts/runtime-drift-checkpoint.ps1` 在执行中持久化 `DRIFT_DETECTED` / `unresolvedDrift` 状态，`scripts/reflection-promotion.ps1` 从用户纠正、失败、验证结果、复盘和漂移状态生成学习候选，并在证据、隐私、重复、冲突、置信度检查通过后，才通过 `learn-memory.ps1`、`write-experience.ps1` 或 `skill-evolution.ps1` 晋升为记忆/经验/技能演化候选。默认 Analyze/Preview 不写长期记忆，避免把聊天噪音、秘密或一次性事故当成规则。

从 `0.5.70` 开始，超级大脑从“存储/检索系统”升级为“记忆驱动的执行控制系统”：新增 `scripts/cognitive-preflight.ps1`，在重要执行前生成认知约束卡，汇总用户硬规则、已接受约束、相似经验、领域反射、`mustPreserve` 与 `driftGuards`。记忆被分层使用：semantic memory 保存稳定事实/偏好/项目知识，episodic memory 保存历史任务轨迹/失败/修复，procedural memory 保存可复用流程/检查表，working memory 保存当前目标/约束/证据/假设/下一步。执行中如违反记忆约束必须触发 `DRIFT_DETECTED`，回到已接受约束后再继续。

从 `0.5.69` 开始，Agent Bridge 子 agent 通道短命令禁止创建嵌套智能体：`开启子agent通道` 中的 `子agent` 指当前受控目标会话本身，必须在当前 Codex/ZCode 会话内本地运行 `agent-bridge-channel.ps1 -Action Open`，不得再启动 Tesla/worker/explorer/helper 之类的二级 agent。

从 `0.5.68` 开始，Agent Bridge 子 agent 的等待超时语义改为 quiet idle：`WaitConnect` / `WaitInbox` 没有连接或没有消息时返回 `idle_waiting_connect` / `idle_waiting_message`，并带有 `notBlocked`、`noProgressReportRequired`，表示通道仍开着且不需要继续刷状态；这不是 blocked、paused、failed 或 completed。

从 `0.5.67` 开始，Agent Bridge 子 agent 短命令更严格：`开启子agent通道` / `Open` 在没有显式传入 channelId 时必须为当前子会话创建新通道，不得复用旧 active/last 通道；子 agent 收到一条消息并回复后也不得宣布 `Goal completed` / `目标完成`，必须继续保持 target-mode 等待下一条消息，直到主 agent 或用户显式关闭。

从 `0.5.66` 开始，全局启动规则增加硬兜底：任何包含 ASCII `agent` 且混有 CJK/非英文字符的用户短语，都应优先路由到 Super Memory Brain Agent Bridge，而不是宿主默认的 explorer/worker/default agent 角色帮助；除非用户明确是在询问角色帮助或指定 explorer/worker/default。

从 `0.5.65` 开始，全局启动规则会把 Agent Bridge 通道短语优先路由到 Super Memory Brain：新 ZCode/Codex 会话遇到 `开启agent通道`、`开启子agent通道`、`连接子agent通道`、`agent通道`、`agent bridge`、`subagent channel` 应先加载/读取 `super-memory-brain`，避免被宿主默认 agent/worker/explorer 帮助拦截。

从 `0.5.64` 开始，Agent Bridge 支持自然语言短命令协议：子 Agent 会话里只说 `开启子agent通道` 就应自动进入 `Open -> WaitConnect -> WaitInbox` 目标模式；开启成功不是任务完成，而是持续等待主 Agent 连接/发消息的状态，不得因为返回 channelId、等待超时、无消息或回复结束而自动关闭。主 Agent 侧可用 `连接子agent通道：chan-xxxx，别名 子agent`、`向子agent发送信息：你好`、`读取子agent通道回复`、`关闭子agent通道` 完成连接、发送、读取和显式关闭。

从 `0.5.63` 开始，Agent Bridge 子 Agent 目标等待状态更明确：子 Agent `Open` 后只报告一次 `waiting_connect` 和 channelId，不再反复输出等待连接；主 Agent `Connect` 后子 Agent 可用 `WaitConnect` 得到一次 `connected` 通知，然后通过 `WaitInbox` 进行有边界的静默消息等待，看到消息才回复，且不会因超时、已发 channelId 或无消息而自动 `Close`。

从 `0.5.62` 开始，Agent Bridge 通道支持主从目标模式：被控/子 Agent 先 `Open` 通道等待，主/操作 Agent `Connect` 一次后把 alias、目标 Agent、目标会话和 last sent/received 写入 `active-agent-bridge-channel.json`；之后用户可直接说“向子agent发送信息：...”，主 Agent 通过 `SendAndWait` 使用已连接通道发送并在限定时间内等待回复，直到用户明确 `Close` 才结束。

从 `0.5.61` 开始，超级大脑新增 Agent Bridge 共享会话通道：`agent-bridge-channel.ps1` 以 Open/Send/Inbox/Ack/Close/Status 管理 `memory/workspace/agent-bridge/channels` 下的隔离通道，支持 `target-session` 路由；Agent1 可以作为发送/接收代理向 Agent2 目标会话发消息，并从同一个通道读取 Agent2 回复。通道内容默认只是 advisory，不写长期共享记忆，除非 Commander 明确 adopt。

从 `0.5.60` 开始，超级大脑新增 `task-register.ps1` 轻量任务登记快路径：当 Codex/ZCode 只需要登记或更新共享任务状态时，它只写 `memory/shared` 下的 agent/session/task/link 身份卡，不触碰 `active-checkpoint.json`，也不运行 doctor、verify-package、hot-refresh、CI、dashboard、auto-check 或 recall。

从 `0.5.59` 开始，超级大脑新增跨 Agent/跨会话任务身份索引：`checkpoint-writer.ps1` 会登记共享 agent/session/task 身份卡和 task-memory 链接，`task-index.ps1 -Table` 用窄 Markdown 表显示全部 Agent、指定 Agent 或指定会话的未完成任务；未登记会话会显示“未知，不等于没有任务”，避免把索引缺失误判为没有任务。

从 `0.5.58` 开始，超级大脑进一步增强为可靠任务执行系统：`task-index.ps1` 可列出当前/暂停/完成/候选任务；`intent-gate.ps1` 把只计划、只状态、执行、澄清脚本化；`recovery-e2e.ps1` 覆盖恢复端到端场景；`step-ledger.ps1` 细粒度记录步骤证据、验证、阻塞和下一步；任务候选按 active checkpoint、active task、paused/blocked、recent completed、status fallback 排序；`host-cache-check.ps1` 检测安装副本和宿主缓存风险。

从 `0.5.58` 开始，超级大脑还把当前任务状态和免粘贴恢复固定为默认规则：普通“任务状态/进度/下一步”优先回答当前会话任务，不当成系统健康检查；冷启动/压缩/中断恢复先读可见上下文、active checkpoint、step ledger、status-card 和最近验证，不要求用户粘贴大段旧回复；多个候选任务时给编号让用户选择；ZCode 会话默认不用 TodoWrite，除非用户明确要求。

从 `0.5.54` 开始，超级大脑还把冷启动主导权固定为默认规则：普通聊天、普通代码、普通 `继续` 优先走状态卡/可见上下文/Light dashboard，不自动唤醒 deep recall、team dispatch、full dashboard 或 full verify。可以用 `scripts\cold-start-audit.ps1 -Json` 验证这些负例仍然保持轻量。

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

安装时会自动刷新真实 `session-start` hook 里的超级大脑路径，让新会话指向当前这份包。安装脚本会先备份已有 skill，失败时自动回滚；默认不会清理历史安装备份，只有显式使用 `-PruneBackups`（可配合 `-KeepBackups`）或运行 `cleanup-install-backups.ps1 -Apply` 才会删除旧备份。换电脑或移动目录后，重新运行 `install.ps1` 即可更新 hook 路径。

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

分享包由 `prepare-share.ps1` 按 manifest 复制脚本、核心技能和可选 `extensions/`，并只复制 NexSandglass 必要运行文件；不会带内部 Python helper、`.git`、zip、demo、`__pycache__`、`.pyc`、私人记忆、`memory\shared`、`memory\agents`、`memory\groups`、共享策略或本机状态缓存。`prepare-share.ps1` 会保护目标路径，避免误删包根、父目录、用户目录或磁盘根目录；覆盖已有分享目录时要求目标带分享包标记，未标记目录需显式 `-Force`。公开/GitHub 分享包会自动生成根级 `.gitignore`，排除本地记忆、marker、缓存、日志、生成包和密钥文件，并把已知本机绝对路径替换为 `<package-root>` / `<memory-root>` / `<user-home>` 等占位符。`verify-share.ps1` 会验证瘦身规则、扩展目录/技能文件、分享包标记、`.gitignore`、通配隐私文件、敏感文本模式和本机路径残留。当前默认分享包目录是同级 `super-memory-brain-package-share*`。

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
