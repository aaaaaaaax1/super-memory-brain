---
name: skill-evolution-loop
description: Internal Super Brain governance skill for lightweight SkillOpt-inspired evolution: capture failure samples, propose bounded rule/skill edits, validate with small replay gates, stage proposals for user review, and only then allow adoption/hot-refresh. Use when recurring failures, compression drift, hallucinated resume, wrong skill routing, repeated tool/schema mistakes, or user feedback indicates a reusable rule should improve. Do not auto-read full histories or call external APIs.
---

# Skill Evolution Loop

Use a lightweight SkillOpt-style loop without adding SkillOpt runtime dependencies.

## Scope

This is an internal governance skill, not a daily user-facing tool. The user should not need to name it. ORC should trigger it when failures or repeated corrections reveal a reusable rule/skill improvement.

## Loop

1. **Capture failure sample**
   - Record compact evidence: trigger, expected behavior, actual failure, affected rule/skill, and source evidence.
   - Never store secrets, raw long transcripts, credentials, cookies, or private unrelated content.

2. **Propose bounded edit**
   - Candidate must be small and targeted: add/delete/replace a rule, skill paragraph, routing condition, or validation case.
   - Prefer one clear change over broad rewrites.
   - Include rollback note and affected files.

3. **Validation gate**
   - A proposal is only adoptable when it passes a small replay/checklist gate.
   - Required gate fields: failure no longer occurs, existing critical behavior preserved, no extra verbosity/token bloat, no privacy regression, no broad auto-mutation.
   - If there is no real validation evidence, status is `staged`, not `accepted`.

4. **Stage for review**
   - Save proposals under `memory/workspace/skill-evolution/proposals/`.
   - Do not mutate existing rules automatically unless the user explicitly approves or the current task is already an approved rule-edit task.

5. **Adopt and refresh**
   - After approval, apply the minimal patch, run targeted verification, then hot-refresh known skill installs.

## Output Discipline

For normal operation, report only:

```text
已记录改进样本：<id>
暂存提案：<path>
状态：staged | validated | adopted
```

Do not dump full failure histories unless the user asks for an audit.

## Triggers

- User says a behavior repeated, e.g. `又开始幻想`, `压缩后又倒带`, `技能太多我用不过来`.
- A bug/failure is fixed by changing a reusable rule rather than one-off code.
- Routing chooses the wrong skill, loads too much, misses a needed skill, or requires the user to remember skill names.
- A verification gap or tool schema mistake repeats.
- A compact replay case can prevent recurrence.

## Non-goals

- No autonomous external API training.
- No full transcript harvesting by default.
- No automatic global rule mutation from unverified suggestions.
- No replacing G1 governance, ORC routing, or NexSandglass memory.
