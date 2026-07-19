# Automatic Evolution Learning Policy

Purpose: let Super Brain improve itself after task closeout without turning every learning into a manual approval ceremony. The policy is bounded: it favors evidence, cold references, tests, and small package-local improvements, while hard-stopping global, installed, secret, destructive, or publishing actions.

## Default

Automatic evolution is enabled by default for Super Brain closeout. The controller may create a learning candidate after each task when there is verified evidence. The candidate must pass the Ponytail gate before promotion.

This policy does not require user approval for low-risk learning. It also does not convert high-risk work into an approval prompt loop; high-risk actions are hard-stop/blocked and recorded with the reason.

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

Ponytail source markers live in `extensions/ponytail/` and cognitive preflight references. This policy uses Ponytail as a gate, not as a new hot-path dependency.

## Automatic Evolution Levels

| Level | Name | Default | Allowed Result |
| --- | --- | --- | --- |
| L0 | observe | auto | Record compact evidence or candidate metadata only. |
| L1 | learn preference/lesson | auto | Promote stable user preference, repeated failure pattern, audit checklist, evidence schema, or verified workflow lesson when privacy-safe and non-duplicative. |
| L2 | promote low-risk procedure/cold-reference improvement | auto if evidence and Ponytail pass | Patch package-local cold reference, checklist, or evidence schema with rollback and validation. |
| L3 | package-local cold reference/test improvement | auto with rollback and validation | Patch package-local reference or tests only; no global startup, installed sync, deploy, publish, or secret handling. |
| L4 | global/hot/install/deploy/publish/secret/destructive | hard-stop | Do not auto-apply. Record blocked reason and required explicit task scope if the user later wants it. |

## Low-Risk Auto-Promotion

Low-risk candidates may be promoted automatically when all are true:

- Evidence comes from the just-completed task or repeated verified failures.
- The learning is privacy-safe and contains no secrets, raw transcripts, payloads, samples, tokens, or private long logs.
- Existing references, rules, and tests do not already cover it.
- The result stays package-local and cold-path by default.
- Validation passes or the evidence clearly records why validation is not applicable.

Examples: stable user preference, repeated failure mode, successful verification workflow, audit checklist, evidence schema, or cold reference clarification.

## Medium-Risk Auto-Patch

Medium-risk candidates may generate a patch and evidence automatically, but must stay within package-local cold references, tests, or metadata. They must not touch global bootstrap, installed skill sync, installed copies, hot-refresh, deploy, publish, release/share, MCP registration, hooks, secrets, or destructive cleanup.

Required closeout: changed files, rollback path, hashes, validation results, skipped high-risk actions, and cold-start impact.

## High-Risk Hard Stop

The following are L4 and must be hard-stop/blocked, not auto-applied:

- AGENTS.md / CLAUDE.md / GEMINI.md / global startup / hooks.
- super-memory-brain or ORC hot-path expansion beyond a short route marker.
- installed skill sync, installed copies, broad or narrow hot-refresh, package install, deploy, publish, release/share.
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
  "promotionDecision": "auto-promoted|evidence-only|blocked",
  "blockedReason": "only for L4 or failed gate"
}
```

Do not store secrets, raw transcripts, or private payloads. Keep full policy here; hot paths may keep only a one-line pointer.
