# Single-Agent Subagent Workflow

Purpose: provide the default Super Brain collaboration model inside one agent host. The controller stays user-facing and clean; internal subagents are execution or verification helpers that return structured cards and evidence.

## When To Use

Use this workflow for complex work that needs staged investigation, code edits, test runs, verification, audit, or evidence closeout, especially when the user asks to let a subagent modify, inspect, test, review, verify, or produce evidence.

Use it when ORC decides the task is too broad for a direct answer but does not require cross-agent communication.

## When Not To Use

Do not use this workflow for ordinary chat, simple coding, small explanations, or visible-context continuation.

Do not use it for explicit channel commands such as open agent channel, connect agent channel, send to agent channel, read channel reply, or close channel. Those are legacy Agent Bridge channel commands.

Do not create group-chat role play, multi-agent chatter, daemon loops, or real-time agent-to-agent inbox polling.

## Controller Role

The controller agent faces the user and owns objective clarity, constraints, approvals, routing, evidence review, final decision, and closure.

The controller creates task cards, reviews result cards, may request an audit card, and decides whether the result is accepted, revised, or blocked.

## Executor Subagent Role

An executor subagent performs bounded work such as search, code modification, local investigation, test execution, or evidence generation.

It must stay within allowed files and forbidden actions, return a result card, and never decide final completion by itself.

## Reviewer / Verifier Subagent Role

A reviewer or verifier subagent performs read-only or explicitly scoped checks over diffs, tests, hashes, route behavior, evidence, and scope boundaries.

It returns an audit card. The controller decides whether to accept or require fixes.

## Task Card Schema

```json
{
  "id": "task-id",
  "objective": "bounded task objective",
  "ownerRole": "executor|reviewer|verifier",
  "allowedFiles": ["paths or globs"],
  "forbiddenActions": ["actions requiring separate approval"],
  "context": "compact relevant context",
  "acceptanceCriteria": ["observable criteria"],
  "validationCommands": ["commands to run or justify skipping"],
  "expectedOutput": "result card or audit card",
  "approvalRequired": ["approval gates"]
}
```

## Result Card Schema

```json
{
  "taskId": "task-id",
  "status": "done|partial|blocked|failed",
  "summary": "what changed or was found",
  "filesChanged": ["paths"],
  "commandsRun": ["commands"],
  "testsRun": ["tests and results"],
  "evidencePaths": ["evidence files"],
  "hashes": [{"path":"file","sha256":"..."}],
  "risks": ["remaining risks"],
  "next": "recommended next action"
}
```

## Audit Card Schema

```json
{
  "taskId": "task-id",
  "decision": "accept|revise|reject|blocked",
  "findings": ["bugs, risks, missing tests"],
  "scopeViolations": ["out-of-scope changes"],
  "missingEvidence": ["missing proof"],
  "verificationResult": "commands and observed result",
  "requiredFixes": ["fixes required before acceptance"],
  "next": "next controller action"
}
```

## Evidence JSON

Each phase closeout should produce evidence with at least:

```json
{
  "phase": "phase name",
  "changedFiles": ["paths"],
  "skippedActions": ["skipped risky actions"],
  "hotPathChanged": "yes|no|minimal",
  "coldReferenceAdded": "yes|no",
  "routeRegression": {"nonStrict":"result", "strict":"result"},
  "pester": "result",
  "skillSync": "result or reason not applicable",
  "sensitiveHashes": [{"path":"file", "sha256":"..."}],
  "coldStartRiskAssessment": "short assessment",
  "rollbackPath": "path",
  "decision": "accepted|revise|blocked"
}
```

## Approval Gates

Ask for explicit user approval before destructive cleanup, broad overwrite, installed sync, hot-refresh, deploy, external publishing, MCP registration, hook/global bootstrap rewrite, secret handling, or work outside the approved file scope.

Deletion, archival, unpinning, cleanup, and overwrite are denied by default. A mutation is authorized only when the current user explicitly approves its exact action, complete target set, and user-visible impact, or when a current user-approved plan explicitly lists that same action, target set, and impact.

`continue`, `maintenance`, `cleanup`, and similarly vague instructions are never authorization. Wildcard expansion, target-set growth, target drift, stale approval, and unknown identity fail closed and require new explicit approval. Authorization is scoped to one action, target set, impact, task, and approval source. Only a verified internal executor/reviewer/verifier agent child may be closed or interrupted; close/interrupt is never archive/delete. Parent, user-owned, MCP, and unknown identities must never be archived, deleted, hidden, or unpinned.

## Forbidden Actions

Internal subagents must not edit AGENTS.md, install dependencies, deploy, publish, register MCP, write durable memory, hot-refresh installed skills, or modify unrelated files unless the task card explicitly allows it and the user approved the gate.

## Context Isolation

Give subagents compact context only: objective, constraints, relevant files, commands, and evidence requirements. Do not pass raw long transcripts or secrets. Keep findings advisory until the controller admits them.

## Parallel Dispatch And State Ownership

Dispatch independent, non-blocking discovery, test, and review sidecars in
parallel when they materially shorten the task. Do not delegate the immediate
critical-path step when the controller needs its result before acting.

- Give each subagent a disjoint file scope or make it read-only.
- The controller alone owns `execution-contract.ps1`, current-task contexts,
  checkpoints, durable memory, parent resumption, and task completion.
- A subagent that needs stateful probes must use an isolated `StateRoot` and a
  test-only task ID. It must not write shared workspace state.
- Results are advisory cards. The controller merges evidence, resolves
  conflicts, runs the acceptance checks, and only then updates task state.
- Close or reuse subagents promptly; do not leave dormant agents holding a
  branch or treating a report as task completion.

## Subagent Lifecycle Auto-Close Invariant

Only a verified internal executor/reviewer/verifier agent child may be closed or interrupted. Such verified children use an explicit terminal-event
set: `task_complete`, `turn_aborted`, `interrupted`, `task_failed`,
`no_longer_needed`, and explicit user stop/cancel. On any terminal event the
controller must close/interrupt the child runtime immediately, before
`ResumeParent` or any next parent action. This is child-only closeout, not
archival: never archive, delete, or hide the parent or a user-owned Codex
conversation. Child cleanup is never task/session archival or deletion. Parent, user-owned, MCP, and unknown identities must never be archived, deleted, hidden, or unpinned. A returned result is not a live child: close it first, then
resume the parent. Only a child with an explicitly authorized next action may
remain open. Idle, ended, or no-next-action children must not retain a thread,
lease, branch, or active pointer. A close failure must emit a structured reason
and remain visible for reconciliation; it must never be silently orphaned. If
the identity is unknown or parent-owned, fail closed. Explicit Agent Bridge
channel sessions are the compatibility exception and close only after an
explicit channel-close command.

## Worktree / Checkpoint / Rollback Recommendation

Prefer small phases. Before writes, record rollback paths or pre-change hashes. For risky edits, use an isolated worktree or backup. Close each phase with changed files, tests, evidence paths, and remaining risk.

## Cold Start Discipline

The hot path only names this workflow and points here. Full schemas, examples, and closeout rules stay in this reference. Ordinary chat and direct coding must not load this file.

## Why Not Channel Mode

Channel mode is for explicit cross-agent communication. It is slower, requires inbox/wait/ack state, and can create empty waiting replies. The default collaboration model is now single-agent internal delegation with structured cards and controller audit.

## Legacy Agent Bridge Compatibility

Agent Bridge channel scripts remain available for explicit legacy/manual-only commands: open/connect/send/read/close agent channel. They are not the default route for subagent execution, review, verification, or evidence work.

## Automatic Evolution Closeout

After controller acceptance, generate a compact learning candidate when the task reveals a reusable preference, repeated failure mode, verified workflow, checklist, evidence schema, or cold-reference improvement. Use `references/automatic-evolution-policy.md` and the Ponytail gate. Keep learning candidates evidence-first; do not write secrets, raw transcripts, installed sync, hot-refresh, deploy, publish, MCP registration, or global startup changes.

Result and audit cards should mention whether automatic evolution was skipped, staged for governed review, evidence-only resolved, or hard-stopped. Automatic evolution never auto-adopts a cold reference, test, rule, skill, or runtime change.

## Closeout Rules

The controller closes a phase only after evidence proves acceptance criteria. A subagent result is not completion. If evidence is missing, request fixes or an audit card. If all checks pass, record evidence and summarize the decision.
