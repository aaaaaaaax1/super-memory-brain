# Governed User Adaptation

Purpose: make collaboration increasingly user-specific without treating one-off
behavior as a permanent trait or injecting a full profile into every task.

## Authority

Current explicit user instructions always win. Adaptation may influence response
detail, reasoning presentation, proactive thresholds, bounded autonomy,
verification depth, feature integration thinking, and clarification style. It
must never change facts, safety, permissions, authorization, or privacy rules.

## Lifecycle

```text
structured observation (no raw prompt)
-> candidate grouped by habit/value/scope
-> confidence, distinct-task, distinct-context, and contradiction gates
-> stable scoped preference
-> relevant task packet (max three directives / 120 tokens)
-> reinforcement, correction, supersession, or explicit forgetting
```

An explicit user preference can promote immediately at high confidence.
Inferred behavior needs repeated evidence across at least three tasks and two
contexts, with no contradiction. A global preference never overrides a matching
project or workflow preference, and no preference is loaded when confidence or
scope does not match.

## Storage

State lives under `memory/workspace/user-adaptation/` and is bounded by
`memory-policy.json`. Observations contain only enumerated keys/values, scope,
task/context identifiers, timestamps, and evidence hashes. Raw prompts, freeform
transcripts, secrets, and inferred personality prose are forbidden.

Vendor Persona output is advisory candidate material only. It is never direct
authority for stable preferences.

Verified task outcomes use a separate structured observer. It accepts at most
three enumerated `habit=value` signals and applies them only when task id and
workspace match a successful `last-task-verification.json`. The default scope
is project. Workflow observations use a project-plus-workflow key, so the same
workflow name in another project cannot inherit them. User-correction signals
also require a matching correction candidate whose lifecycle is closed.
Enumerated values may declare applicable contexts so a problem-specific rule
does not consume packet budget or alter normal low-risk work outside debugging
and review.

The observer never infers signals from summaries, transcripts, freeform prose,
or a packet that was already applied. One observed outcome is only evidence; it
does not bypass the normal three-task/two-context promotion gate. Preview mode
writes only its result card and never mutates observations.

The Codex prompt hook recognizes only strong durable preference wording such as
"going forward", "by default", or "I prefer" combined with an enumerated habit.
`-TestPrompt` reports the signal without mutating adaptation state. Ordinary
requests, one-off style instructions, ambiguous values, and raw prompt text are
not learned.

## Commands

- `user-adaptation.ps1 -Action Status -Json`
- `user-adaptation.ps1 -Action List -Json`
- `user-adaptation.ps1 -Action Set -HabitKey <key> -Value <value> -Scope global -Json`
- `user-adaptation.ps1 -Action Observe ...`
- `user-adaptation.ps1 -Action Synthesize -Json`
- `user-adaptation.ps1 -Action Packet -Context coding -Json`
- `user-adaptation.ps1 -Action Forget -PreferenceId <id> -ConfirmForget -Json`
- `user-adaptation.ps1 -Action Enable|-Action Disable -Json`
- `user-adaptation-observer.ps1 -Mode Preview -TaskId <id> -WorkspaceKey <key> -Signals response_detail=concise -Json`
- `user-adaptation-observer.ps1 -Mode Apply ...` after matching successful task verification

Post-task maintenance may synthesize already-structured observations. Cognitive
preflight may read one compact packet. Neither path may load a full profile or
raw history.
