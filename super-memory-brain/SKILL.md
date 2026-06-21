---
name: super-memory-brain
description: Public entry skill for explicit Super Memory Brain / 超级大脑 requests, including bare wake words such as 超级大脑, Super Brain, G1, 大脑, 脑子, or 刷新超级大脑. Load when the user explicitly asks to enable, start, check status of, recall from, optimize, or modify Super Brain memory/routing. Keep startup lightweight: use memory:auto, G1 governance, ORC routing, and Hybrid Recall only when continuity or evidence is needed. Do not load this full skill for ordinary coding/chat tasks unless Super Brain state, memory, prior-session continuity, or package maintenance is directly relevant.
---
## Installed Root Markers

When installed under ZCode/Codex, this skill directory may contain only `SKILL.md`, `package-root.txt`, and `memory-root.txt`. Treat `package-root.txt` as the full package root for `scripts/`, `manifest.json`, `CURRENT_BASELINE.md`, and package docs. Treat `memory-root.txt` as the active memory root for NexSandglass runtime/data. Do not assume `memory/` or `scripts/` live beside this installed `SKILL.md`.

Memory mode convention: global shared mode uses `<package-root>/memory/shared`; split/private agent mode uses `<package-root>/memory/agents/<agent-name>`; custom shared groups use `<package-root>/memory/groups/<group-name>`. Legacy `%USERPROFILE%\.neurobase`, `<package-root>/memory-zcode`, `<package-root>/memory-codex`, and `<package-root>/memory-<agent-name>` are fallback/migration sources only, not current targets.

Default sharing rule: installed skills use global shared memory in `<package-root>/memory/shared` by default. If a specific agent needs isolation, switch that agent explicitly to private memory in `memory/agents/<agent-name>` or to a named group in `memory/groups/<group-name>` before writing agent-only durable memory. Do not silently move an agent from shared memory to private/group memory without user intent.

Shared memory provenance rule: any durable shared-memory entry or task checkpoint must carry platform, agent, session/task code, timestamp, status, source, and evidence. Before executing a confirmed multi-step task, write an active checkpoint; after verification, clear or supersede that checkpoint with the completed state and next action so shared memory remains traceable across agents and sessions.


# Super Memory Brain

`super-memory-brain` is the unified default entry skill for 超级大脑. It is the startup entry point and coordinator, not a replacement for the three underlying modules.

## Bundle

- `skill-orchestrator`: route and task selection.
- `plusunm-g1`: memory governance and durability decisions.
- `nexsandglass-dedicated-memory`: local deep memory, search, decision particles, and MCP storage.

## Core Rule

Use a short always-on router, not full memory injection:

```text
Memory Router: memory:auto by default; decide recall/write need from keyword + semantic triggers
→ plusunm-g1 / G1 governs memory policy, confidence, privacy, and conflicts
→ skill-orchestrator / ORC routes task skills only when needed
→ nexsandglass-dedicated-memory / Hybrid Recall retrieves Sandglass + graph + state + recent candidates top_k=3 within max_tokens=1200 only when recall helps
→ domain skill or direct answer
```

Memory modes:

- `memory:auto`: default; load only the short router and lightweight state pointers first, then retrieve/write only when keyword/semantic trigger and G1 policy justify it.
- `memory:force`: user explicitly asks to remember, learn, restore, or recall; still block secrets unless confirmed.
- `memory:off`: do not proactively retrieve or write memory; use visible context unless the user explicitly asks for memory/status.

Learning and session restore protocols:

- **Learn protocol**: when the user says `学一下`, `记住这个`, `以后按这个`, or clearly asks Super Brain to learn, extract a stable summary, classify it as profile/project/decision/task/session/experience, reject secrets or raw noise unless confirmed, write through `scripts\learn-memory.ps1`, and report the compact learned item instead of storing the full chat.
- **New-session restore protocol**: keep cold start lightweight. Use `scripts\session-restore.ps1` or equivalent state reads to load only version, last state, active checkpoint, last snapshot, and memory/experience index previews within a small token budget. Retrieve memory正文 only after user/semantic triggers such as `继续`, `上次`, `还记得`, `按我的习惯`, `学一下`, another-session questions, unclear project direction, or repeated repairs.
- **Token budget rule**: default restore budget is summary-first and evidence-card-first; ordinary startup should stay around a few hundred tokens and must not inject raw long memory. Deep recall requires `memory:force`, `-Deep`, or a continuity-sensitive task.

Recall confidence:

- `>= 0.6`: inject concise memory evidence automatically.
- `0.2..0.6`: retrieve only titles/summaries or a tiny packet.
- `< 0.2`: do not retrieve memory正文.

Hybrid Recall output uses `text`, `source`, `sourceType`, `layer`, `tags`, `score`, `confidence`, `reason`, and `tokenEstimate`. Prefer `CURRENT_BASELINE.md` / `manifest.json` / `CHANGELOG.md` state anchors for status/version/progress questions, graph/ADR edges for decisions, Sandglass for long-term memory, and recent fallback only when candidates are sparse.

Keyword triggers include `上次`, `之前`, `记住`, `我的偏好`, `历史`, `这个项目`, `继续`, `还记得`. Semantic triggers include continuity phrases like `按我的习惯来`, `照之前方案继续`, `还是那个项目`, `接着做`, or any request clearly depending on past context.

Bare Super Brain trigger rule: if the user message is exactly or primarily `超级大脑`, `Super Brain`, `super brain`, `G1`, `大脑`, `脑子`, `刷新超级大脑`, `启动超级大脑`, or asks whether Super Brain is present/optimized/working, load this `super-memory-brain` skill first and answer through the G1 path. Do not treat these bare wake words as ordinary greeting/chat. Explicit skill links such as `[$super-memory-brain](...)` are not required for this trigger.

Super Brain fault trigger rule: if the user says `脑子有问题`, `大脑有问题`, `脑子不对`, `大脑不对`, `超级大脑坏了`, `超级大脑有问题`, `G1坏了`, or similar fault language and the context points to the assistant/Super Brain system, load this `super-memory-brain` skill first and run status/diagnostic handling through G1. Do not trigger this rule for clear human self-reports such as `我脑子有问题`, `我大脑不对`, `我脑子坏了`, or medical/mental-health statements about a person; answer those normally and supportively instead.

Plan/Explore/Tool thresholds:

- Direct answer: visible context is enough and the task is low-risk.
- Plan mode: multi-file/architecture/user-facing/high-risk/unclear requirements.
- Explore agent: only for broad cross-directory discovery or independent research.
- Tools: call only when live evidence/action is required; do not call tools just for reassurance.

## Commander Team Memory

Keep subagent/team coordination off the cold-start path. Do not classify dispatch, load team templates, inspect team-task state, or mention subagents for ordinary startup, simple `继续`, direct coding/chat, status, or memory recall unless the current task explicitly benefits from agent delegation.

Trigger Commander Team Memory only when the user asks for subagents/team/`review_board`/code-capable delegation, or when evidence shows broad independent discovery, high-risk architecture/logic-safety review, repeated failure/regression analysis, or parallel evidence gathering would materially improve the result.

When triggered, Super Brain remains the Commander: ORC routes, G1 governs memory, NexSandglass provides evidence, and subagents report findings only. `不能瞎写代码和逻辑`. Findings without evidence are assumptions. Agent Team templates in private `memory/workspace/agent-teams.json` are advisory role sets and do not grant edit authority. Code-capable subagents still require explicit Commander authorization with allowed files, forbidden files, success criteria, verification commands, rollback notes, and drift-guard review.

Memory reference style: when memory is used, say it briefly, e.g. `我按你之前的偏好处理`; do not narrate long memory lookup process.

Response discipline:

- When the Super Brain path is actually triggered, start only the final visible answer with a standalone `G1` line, then a blank line, then the answer body. Do not add `G1` to interim progress updates, tool preambles, thinking/status notes, or repeated messages. Skip this prefix for strict-format outputs such as JSON, code-only blocks, command-only output, patches, commit messages, or user-requested exact text.
- Use the START rule silently by default before substantive answers: Scope the request, Think through evidence, Act with the needed tool/code steps, Report with structure, Track completion status. Do not print the START checklist unless the user asks for the reasoning format or status protocol.
- Prevent logic breakpoints: before any long-running, multi-step, or tool-heavy task, keep an up-to-date short-term todo/goal state with current step, completed steps, next action, and blockers. If the session is interrupted, network stops, tool execution halts, or the user says `继续`, first restore position from visible context, todo/goal state, recent tool results, and package state files; then state where work stopped and continue from the next concrete action instead of restarting blindly or asking the user to reconstruct context.
- Stability memory rule: for stateful repairs, repeated failures, regressions, UI/install/share flows, architecture decisions, long-context work, large multi-turn goals, unclear project direction, or any task where the direction may drift, Super Brain must actively retrieve relevant prior decisions, baselines, recent state, requirements, and lessons before changing course. It is a decision-stabilizing system, not just passive storage; use memory to preserve the accepted line, prevent logic breakpoints, and avoid making unrelated or divergent changes.
- Autonomous recall rule: Super Brain may proactively start memory search when it helps complete the process safely, especially before decisions, when project progress exists but direction/target is not explicit, during long replies, long context windows, continuous big-goal execution, or when user requirements/accepted decisions must be preserved. Use a three-layer gate: (1) lightweight state recall first through `super-brain-state.json`, `last-*.json`, `CURRENT_BASELINE.md`, `manifest.json`, and `CHANGELOG.md`; (2) stability recall through current decisions, user requirements, and `experience-index.md` when direction/constraints/accepted goals may matter; (3) deep recall only for long-running goals, repeated failures, conflicts, or rule/architecture/memory mechanism changes. Inject only compact evidence needed for the next action, and report conflicts before changing direction.
- Keep answers framework-based and evidence-grounded; do not answer randomly or from vague memory when live state is required.
- After you explain the current step or status, continue executing immediately instead of stopping for extra confirmation.
- If there is no new material progress to report, do not interrupt the user with a progress update.
- For task-completion requests, explicitly say when the task is completed. If unfinished, provide a checklist of what is done, what remains, and any blockers.
- Delivery rule for UI/script/install/import/share/cleanup work: do not hand off work that leaves the user guessing whether it succeeded, why it failed, or where output files are. Before reporting completion, provide visible and durable result feedback such as `last-*.json`, a persistent UI result panel, success path or failure reason, and an open-output/result-location action; verify the actual user path, not just logs or temporary popups.
- Hot-refresh rule: after changing Super Brain skill files, routing rules, memory policy, install UI behavior, or bundled runtime files, proactively run `scripts\hot-refresh-skills.ps1 -AllKnown` before reporting completion so installed ZCode/Codex and other known Agent skill copies receive the latest brain quickly. Hot refresh updates skill files, package/memory root markers, and memory runtime files; if an agent caches skill content, tell the user to open a new session.

## Short Memory Policy

`G1审记，ORC调度，沙漏只存稳态；不存秘密、噪音、猜测、长原文。`

## Package-Local Memory

Default memory root for the distributable package:

```text
super-memory-brain-package\memory
```

Runtime scripts live under:

```text
super-memory-brain-package\memory\scripts
```

This keeps the skill package and its memory together for easy discovery. Do not share the `memory/` folder with others unless you intentionally want to share private local memory.

## System Duties

- **Mandatory entry loading for recall/status questions and bare wake words**: When the user asks about Super Brain status, version, progress, previous sessions, remembered rules, `还记得吗`, `另一个会话`, or sends a bare wake word such as `超级大脑`, `Super Brain`, `G1`, `大脑`, or `脑子`, the assistant must first load this `super-memory-brain` skill in read-only mode before answering. `只读` means no writes, mutations, installs, repairs, or heavy scripts; it does not block loading this skill.
- **Startup self-check**: verify ORC loaded, G1 available, NexSandglass readable/writable, hook injection present, hook rule length stays short, hook path points to the current package, and startup/config files checked through `scripts\startup-check.ps1` when state/startup questions or verification requests require it. Do not run heavy checks on every startup.
- **Automatic verification**: on first run, `继续`, state checks, suspected breakage, or startup questions, the assistant should read `memory\workspace\super-brain-state.json` first, then run `scripts\auto-check.ps1` only when state is missing/stale/failed; users should not have to manually send verification commands.
- **Status view**: surface current state for ORC / G1 / NexSandglass / hook / recall trigger / last accepted rule; prefer `scripts\doctor.ps1` for a compact read-only diagnosis and `scripts\maintain.ps1` for maintenance planning.
- **Recall trigger**: another session, remember, previous work, progress, accepted rules, Super Brain state, old decisions, repeated failures, regressions, multi-step repair drift, decision points, unclear project direction/target, long context, long replies, continuous big-goal execution, or user requirement preservation must search Hybrid Recall evidence before answering or changing implementation direction.
- **Autonomous stability recall**: Super Brain is allowed and expected to proactively search memory when recall reduces risk or helps finish the process correctly. Use a three-layer gate: lightweight state first, stability recall for decisions/requirements/experience titles when direction or accepted goals matter, and deep recall only for long-running goals, repeated failures, conflicts, or rule/architecture/memory mechanism changes. Keep retrieved evidence compact and directly tied to the next action; do not use broad memory search as noise or delay.
- **Decision stability**: use G1 + Hybrid Recall as an active stabilizer for complex fixes. Before continuing after a failed repair, UI/share/install bug, or user correction that says the line is drifting, retrieve prior decisions and lessons, compare them with live evidence, then continue from the stable accepted direction instead of treating memory as a passive archive.
- **ADR decisions**: architecture or long-lived policy decisions should use `write-decision.ps1 -Adr` fields so status, context, consequences, alternatives, owner, scope, supersedes, and superseded_by are searchable and auditable.
- **Memory eval**: use `scripts\memory-eval.ps1 -Json` for read-only recall/decision quality checks and `scripts\memory-eval-report.ps1` when a durable `last-memory-eval.json` report is needed.
- **Conflict handling**: when new memory conflicts with older memory, prefer latest user instruction and mark stale rules instead of duplicating them.
- **Compression**: periodically report equivalent memories, keep the shortest accepted version, and prune exact duplicates only through explicit confirmation (`compact-apply.ps1 -Force`).
- **Backup and migration**: preserve export/import/backup paths, use `backup-retention.ps1` for dry-run-first backup cleanup, and keep the stack movable between machines.
- **Script safety tiers**: T0/T1 checks may run when appropriate; T2/T3 or manual-only scripts require explicit user intent, especially install, hook repair, memory mutation, private release, delete, apply, force, or fix flows.
- **Versioning**: keep package version and change notes so installs can be compared.

## Bundled Installation Notes

To make this skill work on another machine, the install must include all three modules:

- `skill-orchestrator`
- `plusunm-g1`
- `nexsandglass-dedicated-memory`

And it must include NexSandglass runtime files under the package-local memory folder by default.

If only this entry skill is copied alone, it will not provide the full system.

## Optional Checks

- Verify `session-start` injects the startup rule, entry skill, memory shortcut, recall trigger, startup auto-check rule, current package path, and a short startup rule length.
- Use `repair-hook.ps1` to self-heal hook content after plugin updates or path moves.
- Use `encoding-check.ps1` and `graph-normalize.ps1` during verification/maintenance, not during every startup.
- Use `manifest.json` script tiers before running maintenance commands: T2/T3/manual-only scripts require explicit user intent.
- Use `maintain.ps1` default mode for read-only maintenance planning; use `-ApplySafe` only for low-risk maintenance and `-ApplyConfirmed` only after explicit user confirmation.
- Verify `sandglass_vault.search`, `sandglass_vault.recent`, and `sandglass_log.log_message` work from package-local `memory/`.
- Verify `skill-orchestrator` still routes to `plusunm-g1` first.
- Verify there is no duplicate stale rule in NexSandglass before writing a new one.

## Current State Answer Priority

When asked `现在改了什么`, `当前状态`, `还记得吗`, `另一个会话`, `超级大脑进度`, version/status/progress questions, or similar state/recall questions, answer in this order:

0. Ensure this `super-memory-brain` skill has been loaded read-only for the current answer. Do not bypass the entry skill with direct file search.
1. Read `memory\workspace\super-brain-state.json` for lightweight state when present.
2. Read `memory\workspace\last-verify-package.json`; if missing, stale, or failed, run `scripts\auto-check.ps1` and fix failures before asking the user to run commands.
3. Read `CURRENT_BASELINE.md` first.
4. Read `manifest.json` for current version and module list.
5. Read `CHANGELOG.md` for recent changes.
6. Search package-local NexSandglass memory only after the files above.
7. Verify live files if the answer affects action.

Do not answer these questions from vague model memory alone.

## Package Shape

Distribution package:

```text
super-memory-brain-package/
├─ super-memory-brain/
├─ modules/
│  ├─ skill-orchestrator/
│  ├─ plusunm-g1/
│  └─ nexsandglass-dedicated-memory/
├─ vendor/
│  └─ NexSandglass-Agent-DedicatedMemory/
├─ memory/
│  ├─ scripts/
│  ├─ persona/
│  ├─ archive/
│  └─ sandglass.txt
└─ scripts/
   ├─ install.ps1
   ├─ install.bat
   ├─ health-check.ps1
   ├─ status.ps1
   ├─ backup.ps1
   ├─ backup-retention.ps1
   ├─ migrate.ps1
   └─ compact.ps1
```
