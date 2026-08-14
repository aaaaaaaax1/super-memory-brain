# Phase 6 Memory Evaluation

Phase 6 evaluates the memory path as four separate layers. It does not turn a
local diagnostic into an objective intelligence score.

1. Ingestion: records enter an isolated state root through `write-memory.ps1`.
2. Retrieval: a fresh `BrainCore` process returns evidence metadata at rank 4
   and evaluation-only rank 10. Normal MCP/CLI recall remains capped at four
   cards and 500 tokens.
3. Grounding: an answer artifact declares every claim and its retrieved
   evidence ids. Undeclared or unsupported claims are failures.
4. Final answer: compact required phrases or abstention are scored separately
   from retrieval so a lucky answer cannot hide missing evidence.

For an abstention case with no expected evidence ids, unrelated top-four
context is not a recall miss. The negative-evidence check is instead the
grounded empty abstention itself: no answer text, no claims, and no unsupported
claim. This keeps an irrelevant retrieved record from converting a correct
"unknown" answer into a false E2E failure.

## Holdout Contract

Use `super-brain.memory-e2e-source.v1` with compact case ids, a `familyId` for
each case, records, query, category, expected evidence ids, and answer
expectations. `familyId` identifies a memory family (session/entity/decision
chain), not a prompt variant. Optionally provide `excludedFamilyHashes` for
calibration families; the seal rejects overlap without storing those raw ids in
reports. Seal it with:

```powershell
scripts\phase6-memory-eval.ps1 -Action Seal -SourcePath <private-source.json> -OutputPath <sealed.json>
```

The output is `super-brain.memory-e2e-holdout.sealed.v1`. It is immutable:
case hashes, the family-set hash, and the set hash are checked before every run.
A consumed run writes a marker beside the report, bound to the final report
file hash. It also reserves the sealed set hash in a package-private registry
before evaluation, so changing the report or marker path cannot make a set
fresh again. The aggregate command requires two distinct sealed sets, no
overlap between their hashed family memberships, and the same current runtime
binding; an unconsumed, stale, tampered, or reused report fails closed.

## Blinded Answer Input

Before a real E2E run, create a private blinded answer input from the sealed
holdout:

```powershell
scripts\phase6-memory-eval.ps1 -Action PrepareAnswerInput -SealedPath <sealed.json> -OutputPath <private-answer-input.json>
```

The input contains only each query and the normal top-four retrieved evidence
cards. It never contains expected evidence ids, expected phrases, or full
record payloads. It is private because its retrieved evidence text can be
sensitive and must not be committed or included in a public report.

Use the narrow generator before a real run:

```powershell
scripts\phase6-answer-artifact-generator.ps1 -Action Status -Json
scripts\phase6-answer-artifact-generator.ps1 -Action Preflight -AnswerInputPath <private-answer-input.json> -Json
scripts\phase6-answer-artifact-generator.ps1 -Action Probe -Apply -Json
scripts\phase6-answer-artifact-generator.ps1 -Action Generate -Apply -AnswerInputPath <private-answer-input.json> -OutputPath <private-answers.json> -Json
```

Generation has a private atomic checkpoint beside the private output by default.
`-MaxNewBatches N` intentionally stops only after N completed batches, and
`-Resume` sends only the remaining pending batches. Each batch may be sent once:
an `in_progress` or `blocked` checkpoint is indeterminate and cannot be replayed
automatically. Start a new controlled evaluation run after inspecting such a
checkpoint. Checkpoints, blinded inputs, and answer artifacts remain private.

This exact-once rule applies to answer batches, not the synthetic transport
probe. `Probe` contains no sealed input and may retry a bounded number of
pre-response transport failures (`408`, `425`, `429`, `5xx`, timeout, or missing
completion event). It records its attempt count and only writes a receipt after
one completed response. A rejected model identity, malformed reply, or any
formal batch failure remains fail-closed without automatic replay.

Transport selection is fail-closed and ordered: an explicit command or complete
`SUPER_BRAIN_ANSWER_*` pair, then the current Codex Desktop Responses provider
from its local `config.toml`, then the locally managed Smag credential cache,
then a complete `SMAG_*` pair. A partial explicit configuration, unsupported
Codex `wire_api`, HTML response, or model mismatch stops the run; the generator
does not silently switch models, endpoints, or retry through another provider.
Credentials, endpoint text, raw prompts, and raw model replies are never written
into the package or report. The generator accepts only the blinded input, refuses public
package output paths, requires the endpoint to report the requested model, and
writes an answer artifact atomically. It defaults to the configured `max`
reasoning effort and sends bounded batches; every output still passes
per-case evidence isolation before it can be accepted. The separate independent
blind judge uses its own model and reasoning configuration.

An external generator produces `super-brain.memory-e2e-answer-artifact.v1`
bound to this input hash. Its v2 provenance declares an actual response-derived
run receipt, generator hash, requested/reported model identity, endpoint hash,
per-case model evidence, `independentExecution=true`,
`expectedAnswerDataAvailable=false`, and `rawResponseStored=false`. The
generator derives non-abstained claim links only from exact value matches in
evidence supplied to that case. A short explicit "insufficient evidence"
response is normalized to abstention; every other unmatched answer is rejected
rather than assigned a citation and is not retried automatically. The evaluator
rejects a real consumed run without that binding, and aggregation rejects a
reused external generator receipt across fresh sets. This remains an auditable
operator-attestation boundary, not cryptographic proof of how an external model
was prompted.

## Desktop-Native Transport

When the Desktop host can complete normal Codex requests but an external
Responses bridge cannot reproduce that transport shape, the operator may use
the narrow host-native path instead of retrying a sealed request through the
bridge. It is a Phase 6 internal-acceptance fallback, not an external API
result and not an official paired A/B benchmark result.

```powershell
scripts\phase6-answer-artifact-generator.ps1 -Action ExportNative -Apply -AnswerInputPath <private-answer-input.json> -OutputPath <private-native-batch.json> -Model gpt-5.6-terra -Json
# Dispatch one fresh Desktop-native agent with only the exported batch as its input.
# The agent writes only schema, batchId, batchHash, and cases[id, answerText] to <private-native-response.json>.
scripts\phase6-answer-artifact-generator.ps1 -Action ImportNative -Apply -AnswerInputPath <private-answer-input.json> -NativeBatchPath <private-native-batch.json> -NativeResponsePath <private-native-response.json> -NativeAgentId <host-agent-id> -NativeDispatchId <host-dispatch-id> -OutputPath <private-answer-artifact.json> -Model gpt-5.6-terra -Json
```

`ExportNative` allow-lists only the query and that case's top-four retrieved
evidence; it excludes expected phrases, expected evidence ids, full source
records, case hashes, and raw expected-answer payloads. Its bound privacy
contract attests that expected data and raw transcripts are absent. `ImportNative`
accepts only one exact response for the bound batch, derives citations and all
provenance locally, and records a SHA-256-bound host dispatch receipt. It does
not accept agent-provided provenance, model identity, evidence ids, prompts,
references, or rubrics. Native agent access is an operator-attestation boundary:
the agent must start fresh, without parent context, and read only the exported
batch. It is not a cryptographic sandbox.

There is no automatic retry for an exported sealed batch. A malformed response,
missing host receipt, model-identity mismatch, batch mismatch, or unsupported
claim fails closed. The response, receipt, imported artifact, and report stay
under `private-state`; public reports still omit raw prompts, evidence, answers,
and user memory.

The existing v13 60-case behavioral holdout is not a Phase 6 memory E2E set.
It stays unconsumed unless its own behavioral protocol is run; do not retrofit
memory payloads into it.

## Required Gates

The evaluator reports, but does not average away, these gates:

- oracle evidence availability >= 95%
- Recall@4 >= 95%
- Recall@10 >= 95%
- every category E2E rate >= 85%
- unsupported claims <= 1
- each fresh sealed E2E run >= 90%
- an aggregate requires two distinct, fresh, consumed sealed runs at the same
  runtime binding
- each real sealed run needs at least 20 cases across at least 4 categories;
  diagnostic self-tests are exempt and remain non-publishable

Run a real sealed set only after its blinded answer input and independently
generated answer artifact are ready:

```powershell
scripts\phase6-memory-eval.ps1 -Action Run -SealedPath <sealed.json> -AnswerInputPath <private-answer-input.json> -AnswerArtifactPath <answers.json> -OutputPath <report.json> -Consume
scripts\phase6-memory-eval.ps1 -Action Aggregate -ReportPaths <report-a.json>,<report-b.json> -OutputPath <aggregate.json>
```

When a fresh aggregate has unmet gates, the optional cold bridge may stage one
deduplicated repair proposal without changing any rule or memory:

```powershell
scripts\evaluation-learning-bridge.ps1 -Action Preview -AggregatePath <aggregate.json> -Json
scripts\evaluation-learning-bridge.ps1 -Action Stage -AggregatePath <aggregate.json> -Json
```

`Stage` accepts only a current-binding, fresh aggregate with distinct consumed
holdout and family sets. It stores hashes and unmet gate ids only, then creates
a `staged` proposal. A matching replay artifact is still required before that
proposal can become `validated`; neither command auto-adopts a rule.

Reports never include raw prompts, record text, answer text, or real user
memory. Final-answer scoring is deterministic required-phrase plus evidence
linkage scoring, so it is an internal acceptance signal rather than a semantic
model judge or objective intelligence score. `SelfTest` creates two temporary
synthetic sealed sets and is always `diagnostic_non_publishable`; synthetic
answers cannot be consumed through the real CLI path.
