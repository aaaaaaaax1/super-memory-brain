# Automatic Evolution Learning Policy

Purpose: let Super Brain improve itself after task closeout without turning every learning into a manual approval ceremony. The policy is bounded: it favors evidence, cold references, tests, and small package-local improvements, while hard-stopping global, installed, secret, destructive, or publishing actions.

## Default

Automatic evolution is enabled by default for Super Brain closeout. The controller may create or update a learning candidate after each task when there is verified evidence. The candidate must pass the Ponytail gate before any proposal is staged.

This policy does not require user approval to record evidence-only observations or close a proven low-risk evidence-only candidate. It never auto-adopts a rule, skill, test, reference, runtime behavior, installation, or package change. High-risk actions are hard-stop/blocked and recorded with the reason.

## Ponytail Gate

Apply Ponytail before every automatic evolution action:

1. Do not write a learning if no durable reuse exists.
2. Do not duplicate an existing rule, reference, test, route, or capability.
3. Prefer evidence over a new rule when evidence is enough.
4. Prefer a cold reference over hot-path text.
5. Merge related candidates instead of creating many small fragments.
6. Use the smallest safe package-local diff.
7. Never cut validation, privacy, rollback, or explicit user constraints.

Candidate lifecycle is bounded. Read-only status and reflection preview must not
create candidates or last-result files. Collection updates a stable problem
family instead of creating one item per task. Maintenance keeps at most 32
active families by default and archives merged source instances, closed items,
stale singletons, and overflow with restore metadata; it never silently deletes
the only evidence copy.

Phase 6 memory evaluation may feed this system only through
`evaluation-learning-bridge.ps1`. The bridge accepts a fresh current-binding
aggregate with distinct consumed holdout and family sets, stores only aggregate
hashes and unmet gate ids, and stages one deduplicated proposal. It never
copies cases, answers, user memory, or raw prompts, and never adopts a rule.

## Canonical Lifecycle

The queue is the canonical lifecycle projection for learning candidates:

```text
candidate -> staged -> validated -> adopted | rejected | resolved
                         \-> blocked
```

- `staged` and `validated` may be synchronized only from an exact
  `skill-evolution` proposal id plus evidence fingerprint.
- A governed skill/rule proposal may enter `adopted` only after a current v2
  validation artifact proves a sealed replay, an unused independently generated
  holdout, no consumed-holdout reuse, and an anti-overfit gate. It also requires
  an explicit approval receipt and a comparable measured-effect artifact. A
  legacy validation artifact remains visible for compatibility but cannot
  authorize new governed adoption.
- `adopted` is never an automatic outcome. A governed proposal remains visible
  while adopted so later task receipts can prove that the improvement transfers
  beyond its original replay.
- `rejected` records a failed governed replay. `blocked` records the prior
  state and a compact reason without discarding evidence.
- `resolved` may be automatic only for a low-risk `evidence_only` candidate
  after three different current, task-bound, privacy-safe verification receipt
  hashes. The three receipts must also come from three different task ids.
- A governed skill/rule proposal resolves only after its approved adoption has
  three different current, task-bound, privacy-safe pass receipts. This closes
  the learning record, not the underlying rule or package change.
- Queue receipt storage is allowlisted: identifiers, hashes, binding fields,
  boolean checks, and timestamps only. Raw prompts, summaries, transcripts,
  evidence text, paths, payloads, and secrets are rejected.
- If no comparable effect artifact exists, the record states `not_scored` and
  must not claim that Super Brain improved. `not_scored` is an honest unknown,
  not a pass.

Ponytail source markers live in `extensions/ponytail/` and cognitive preflight references. This policy uses Ponytail as a gate, not as a new hot-path dependency.

## Automatic Evolution Levels

| Level | Name | Default | Allowed Result |
| --- | --- | --- | --- |
| L0 | observe | auto | Record compact evidence or candidate metadata only. |
| L1 | stage preference/lesson | auto | Stage a stable preference, repeated failure pattern, audit checklist, evidence schema, or verified workflow lesson for governed review. |
| L2 | prepare low-risk procedure/cold-reference proposal | auto if evidence and Ponytail pass | Produce a package-local proposal and validation plan; do not apply it. |
| L3 | prepare package-local cold reference/test proposal | auto with rollback and validation | Produce a staged package-local proposal only; no global startup, installed sync, deploy, publish, or secret handling. |
| L4 | global/hot/install/deploy/publish/secret/destructive | hard-stop | Do not auto-apply. Record blocked reason and required explicit task scope if the user later wants it. |

## Evidence-Only Auto-Resolution

Low-risk candidates may become `resolved` automatically when all are true:

- The candidate is explicitly classified as low-risk `evidence_only` and is not
  a rule, skill, runtime, MCP, hook, install, release, or hot-path change.
- Three distinct current verification receipts prove the observation across
  three different completed task ids.
- Each receipt is privacy-safe, current-bound, and has a unique immutable hash.
- The action only closes the evidence family. It does not patch or adopt any
  artifact.

Examples: an already-fixed evidence observation, a duplicate quality signal,
or a verified one-off condition that no longer needs active tracking.

## Medium-Risk Auto-Patch

Medium-risk candidates may generate a compact proposal and evidence automatically, but remain `candidate` or `staged` until an explicit governed task approves and validates a change. They must not touch global bootstrap, installed skill sync, installed copies, hot-refresh, deploy, external publishing, MCP registration, hooks, secrets, or destructive cleanup.

Required closeout: changed files, rollback path, hashes, validation results, skipped high-risk actions, and cold-start impact.

## High-Risk Hard Stop

The following are L4 and must be hard-stop/blocked, not auto-applied:

- AGENTS.md / CLAUDE.md / GEMINI.md / global startup / hooks.
- super-memory-brain or ORC hot-path expansion beyond a short route marker.
- installed skill sync, installed copies, broad or narrow hot-refresh, package install, deploy, external publishing, or release operations.
- MCP registration or external service wiring.
- destructive cleanup, broad overwrite, dependency install, network update.
- secrets, credentials, raw private data, raw transcripts, payloads, samples, or malware details.

Record the blocked reason in evidence. Do not ask the user for approval as part of automatic evolution; wait for an explicit new task scope.

## Closeout Contract

At task closeout, the controller may append an evidence-only learning candidate with:

```json
{
  "kind": "learningCandidate",
  "riskLevel": "L0|L1|L2|L3|L4",
  "sourceEvidence": ["paths or hashes"],
  "candidate": "compact reusable lesson",
  "ponytailDecision": "skip|merge|evidence-only|cold-reference|test-patch|blocked",
  "promotionDecision": "candidate|staged|evidence-only-resolved|blocked",
  "blockedReason": "only for L4 or failed gate"
}
```

Do not store secrets, raw transcripts, or private payloads. Keep full policy here; hot paths may keep only a one-line pointer.
