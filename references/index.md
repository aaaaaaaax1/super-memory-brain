# Super Memory Brain Reference Index

Purpose: keep hot-path skills short. Use this index only after the short router
or entry skill has selected a route. Read one referenced file at a time.

| Intent | Read | Do not read |
| --- | --- | --- |
| Bare wake, explicit Super Brain/G1 control | `super-memory-brain/SKILL.md` hot path only | Full manifest, CI, maintenance docs |
| Current task status | `references/status-recovery.md` | System doctor, package verify, broad recall |
| Previous session / continue last task | `references/status-recovery.md` then summary recall only if needed | Deep recall before visible/checkpoint state |
| Task-state conflict, CAS, replay, or projection rebuild | `references/task-state-store.md` | Merging different task IDs or treating compatibility pointers as authoritative state |
| Memory write, consolidation, replacement, or recall | `references/memory-governance.md` | Raw transcripts, secrets, full Sandglass dump |
| User habits, personalization, adaptation status, or forgetting | `references/user-adaptation.md` | Raw prompts, full persona injection, one-off behavior as a permanent trait |
| Execution autonomy or approval boundary | `references/execution-autonomy.md` | Repeated confirmation for already-authorized safe work |
| Internal autonomy evidence counts or score evidence provenance | `references/autonomy-evidence-ledger.md` | Treating completed cards, supplied numbers, or unlinked corrections as autonomy proof |
| Subagent execution / review / verification inside one agent | `references/single-agent-subagent-workflow.md` | Agent Bridge channel, group chat, load-all-skills |
| Agent Bridge channel | `references/agent-bridge.md` | Host default explorer/worker help; not default subagent workflow |
| ORC / complex routing | `references/orc-routing.md` | Load-all-skills, unrelated skill docs |
| Engineering judgment / repair / optimization / architecture / best-option claim | `references/engineering-judgment.md` | Prompt-only certainty, stale memory as fact, universal optimality claims |
| Objective intelligence evaluation or cross-system comparison | `references/objective-evaluation.md` | Package-local weighted acceptance scores presented as objective results |
| Technology stack, framework, database, AI toolchain, edge, deployment, or architecture selection | `references/technology-decision.md` | Long-form requirement interrogation, unscored option dumps, catalog priors presented as live facts |
| Feature, workflow, product behavior, or automation intent | `references/collaborative-intent.md` | Isolated function work without product role, flow integration, non-goals, or bounded autonomy |
| Refresh / install / repair | `references/install-refresh.md` | Destructive install, hook rewrite, broad overwrite without approval |
| Release / share / maintenance | `references/maintenance-release.md` | Private memory, raw secrets, unverified packages |
| Source/runtime/state/archive layout, oversized evidence, or backup architecture | `references/four-layer-runtime-layout.md` | Moving private state into Git, deleting evidence, runtime-root backup accumulation |
| New/update skill, extension, plugin, MCP, route, or script capability | `references/extension-integration-invariant.md` | AGENTS/global bootstrap, hot-refresh, release/publish without explicit approval |
| Post-task automatic evolution closeout | `references/automatic-evolution-policy.md` | AGENTS/global bootstrap, installed sync, hot-refresh, deploy, publish, secrets, destructive actions |
| GPT-5 anti-degradation guard / base instructions recovery | `references/base-instructions/gpt-5.5-base-instructions.md` | Loading full base instructions for ordinary chat or simple tasks |

Single-hop rule: if this index points to a reference, read that reference and
stop. Only follow a second reference when the first file explicitly says the
route is blocked without it.

Baseline guard: strict route regression is green with no accepted baseline gaps.
Any future mismatch is a regression and must remain visible until fixed.
