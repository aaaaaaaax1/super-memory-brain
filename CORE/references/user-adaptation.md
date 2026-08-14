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
typed observation (no raw prompt)
-> candidate -> validated -> staged/shadow -> active
                    |             |             |
                    v             v             v
               conflicted      dormant      superseded -> forgotten
-> scoped native packet (max three directives / 96 tokens / 384 characters)
```

An explicit user preference can promote immediately at high confidence.
Inferred behavior needs repeated evidence across at least three tasks and two
contexts, with no contradiction. A global preference never overrides a matching
project or workflow preference, and no preference is loaded when confidence or
scope does not match.

`validated` is recorded as compact evidence metadata before an inferred
candidate may influence later staging or activation: it names only the scope,
support, task/context diversity, contradiction, confidence, and anti-overfit
checks. It stores no prompt body or personality prose. A status transition or
local validation record proves only that the local gate was met, not that the
model objectively improved.

Parameterized inferred preferences require at least four distinct verified
tasks over two dates, modal support of at least 75 percent, and median absolute
deviation no greater than one. Numeric pass-count variation is aggregated
inside one semantic group; different value, risk floor, or applicability
contexts are semantic conflicts. High-cost global defaults such as review
volume require explicit confirmation. User silence, model output, and task
success by itself are not evidence. One verified correction suppresses an
affected inferred active preference immediately.

V2 adds bounded `speaking_style`, `detail_control`, `progress_cadence`, and
`review_protocol` policies. Review counts are typed parameters, not generated
prose: forward passes are 1-5, reverse passes are 0-3, the risk floor is
`workflow` or `structural`, and an optional bounded context list can narrow
applicability. Unknown fields and out-of-range values are rejected; they are
never silently clamped.

## Storage

State lives under the private state root at `workspace/user-adaptation/` and is
bounded by `memory-policy.json`. Observations contain only enumerated
keys/values, scope, task/context identifiers, timestamps, and evidence hashes.
Raw prompts, freeform transcripts, secrets, and inferred personality prose are
forbidden.

Vendor Persona output is advisory candidate material only. It is never direct
authority for stable preferences.

The only action-shaping read interface is the scoped resolver. The private
native projection remains a fail-closed contract until its parity and latency
gates pass; it must return no packet for unknown context, stale hash or
generation, disabled state, malformed content, scope ambiguity, or pointer
mismatch, and must never launch PowerShell, perform broad recall, or fall back
to model inference.

Verified task outcomes use a separate structured observer. Caller-provided
`AdaptationSignals`, context, and workflow values are assertions only; they
have no promotion authority. A real, non-test, non-subagent host user turn may
emit a content-addressed
`super-brain.user-adaptation-confirmation-receipt.v2` under
`runtime-state/user-confirmation-receipts/`. The receipt binds task, workspace,
owner session, contract revision, canonical plan identity, a typed selection,
and a workspace-qualified workflow identity hash without storing user text.
After atomic completion, task verification derives the exact signal set,
context, scope, and workflow from that receipt and writes a V2 immutable
artifact under `runtime-state/user-adaptation-verifications/`. Missing, stale,
tampered, cross-task, cross-workspace, or caller-only evidence writes zero
observations. V1 accepted-outcome artifacts cannot create V2 observations.

Review measurements use producer `verified_task_protocol`: requested pass
counts and optional applicability contexts come from the host receipt, while
the completed canonical plan proves the pass counts and risk floor. A
caller-provided measurement string or workflow key by itself is not evidence.
User-correction observations use a replayable
`analyzed -> closing -> applied -> closed` lifecycle. The exact candidate,
verified outcome, immutable artifact, and target preference are hash-bound;
recording the correction and making the old inferred preference dormant share
one CAS transaction. A crash before final close leaves `closing` plus a
retryable request rather than a false closed state.
Enumerated values may declare applicable contexts so a problem-specific rule
does not consume packet budget or alter normal low-risk work outside debugging
and review.

The observer never infers signals from summaries, transcripts, freeform prose,
or a packet that was already applied. One observed outcome is only evidence; it
does not bypass the normal three-task/two-context promotion gate. Preview mode
writes only its result card and never mutates observations.

The Codex prompt hook recognizes only trusted direct clauses with durable
intent, a current-user/assistant actor binding, and an enumerated habit. Bare
`always` or `by default` is insufficient. It classifies multi-line example,
sample, log, translation, quotation, and role blocks before clause parsing, and
uses closed current-user templates rather than a generic `my/you` token check.
`-TestPrompt` and subagent turns write neither preferences nor confirmation
receipts. Ordinary requests, third-party preferences, ambiguous values, and raw
prompt text are not learned.

Strict current-task choices such as a task-scoped response mode or explicit
review-pass counts may create a confirmation receipt, but not a durable
preference. Only a later successful, matching task outcome turns that receipt
into inferred evidence, and normal promotion still requires repeated tasks,
dates, contexts, confidence, staging, and conflict gates.

Durable capture excludes quoted spans, fenced or indented code, block quotes,
pasted or timestamped logs, translations, examples, samples, hypotheticals,
and negated statements. Trusted clauses are evaluated independently, so a later
example cannot erase a valid direct preference. The V2 evidence kinds are
`durable_explicit`, `task_instruction`, `verified_outcome`,
`workflow_measurement`, and `verified_correction`; each has a fixed trusted
producer and promotion power.

## Observable Evolution

`user-adaptation.ps1 -Action Explain` reports why one retained preference or
candidate currently exists. `-Action Evolution` reports only bounded lifecycle
changes and current counts. Both reports are local diagnostic evidence, not
proof that the model has objectively improved: they carry
`trustLevel=local_same_user_unattested` and remain `not_scored` unless a
separate paired, blinded evaluation manifest exists.

Lifecycle receipts form a bounded hash-linked chain. Their summaries contain
only opaque entity identifiers, typed status transitions, coarse scope, reason
codes, hashes, and timestamps; they never contain task text, paths, raw
prompts, transcripts, or freeform evidence. If receipt history is pruned or a
preference is forgotten, coverage is `partial` or `redacted` and every rate
metric remains `not_scored` rather than being reconstructed from missing data.
Reinstating a forgotten identity also emits a typed `forgotten -> reinstated`
identity event, so the history does not imply that an old preference silently
returned; new evidence is still required before any preference becomes active.

## Experience And Method Reuse

Prior experience is a low-priority advisory hypothesis, not an execution
authority. For a non-trivial task, preflight may retrieve a relevant verified
decision, failure pattern, procedure card, or experience index entry before
acting. The retrieved item can suggest a method or a comparison option, but
the latest user instruction, current task state, live evidence, policy,
permissions, and safety gates always win.

A similar experience with no independent current evidence has
`reuseStatus=insufficient`; it cannot become a fact, a hard rule, or an
automatic mutation. When no relevant experience exists, Super Brain must use
current evidence, first-principles reasoning, and applicable reusable
procedures or tools as parallel options. It must not force a new task into an
old recipe or suppress a better solution merely because history is empty or
different.

Verified outcomes and corrections may feed the bounded reflection and staged
learning loop. They can improve future method selection and collaboration
style, but they do not create a freeform persona, self-reinforce from their
own use, or bypass review and evidence gates.

## Migration

V1 state is migrated in place only after a read-only preview and backup plan.
The preview validates every source schema and existing profile value, returns
only counts and hashes, and performs no mutation. Existing explicit preferences
retain source, scope, confidence, status, and value. Legacy tombstone hashes are
preserved as compatibility blockers. Apply uses one lock and compare-and-swap
revision; a failure leaves V1 untouched and V2 disabled. Rollback is bound to a
`super-brain.user-adaptation-rollback-receipt.v2` receipt.

## Commands

- `user-adaptation.ps1 -Action Status -Json`
- `user-adaptation.ps1 -Action List -Json`
- `user-adaptation.ps1 -Action PolicyContract -Json`
- `user-adaptation.ps1 -Action MigratePreview -Json`
- `user-adaptation.ps1 -Action Set -HabitKey <key> -Value <value> -Scope global -Json`
- `user-adaptation.ps1 -Action Observe ...`
- `user-adaptation.ps1 -Action Synthesize -Json`
- `user-adaptation.ps1 -Action Packet -Context coding -Json`
- `user-adaptation.ps1 -Action Explain -PreferenceId <pref-id> -Json`
- `user-adaptation.ps1 -Action Evolution -Json`
- `user-adaptation.ps1 -Action Forget -PreferenceId <id> -ConfirmForget -Json`
- `user-adaptation.ps1 -Action Enable|-Action Disable -Json`
- `user-adaptation-observer.ps1 -Mode Preview -TaskId <id> -WorkspaceKey <key> -Signals response_detail=concise -Json`
- `user-adaptation-observer.ps1 -Mode Apply ...` after matching successful task verification

Post-task maintenance may synthesize already-structured observations. Cognitive
preflight may read one compact packet. Neither path may load a full profile or
raw history.
