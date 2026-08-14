# Objective Evaluation

The package-local `intelligence-eval.ps1` is an internal acceptance gate. Its
weighted values are not an objective intelligence score and must not be used
for cross-system comparisons.

Objective claims require a paired A/B run against an official public benchmark:

1. Keep host model, model version, tools, budget, environment, and task set fixed.
2. Change only `super_memory_brain_enabled` between baseline and treatment.
3. Randomize order and blind judging.
4. Preserve the official harness artifact and SHA-256.
5. Report raw baseline/treatment pass rates, paired percentage-point delta,
   confidence intervals, wins, losses, and benchmark version.
6. Never combine SWE-bench, BFCL, LongMemEval, and tau3-bench into one custom
   intelligence number.

Use `scripts/objective-benchmark.ps1 -Action Plan -Json` before running an
official harness. Normalize completed paired outcomes to
`super-brain.objective-benchmark-run.v1`, then evaluate that artifact with
`-Action Evaluate -ResultsPath <path> -ReportPath <path> -Json`.

Until an official paired run exists, the objective status is `not_scored`.

## LongMemEval-V2 Candidate

LongMemEval-V2 is registered as a fresh official candidate at the pinned
official harness commit `6f020ac2fc3275e46c706d3406e02c3ed79b7be2` and
dataset revision `f152293e235517d504809563c833d7190b8c713b`.

The adapter lives in `runtime/longmemeval_v2_adapter.py`. It is loaded only by
`runtime/longmemeval_v2_harness_entry.py`, which registers one memory backend
with the unchanged official harness. The adapter writes trajectory observations
into a new, per-run Sandglass root under a path explicitly named for
LongMemEval-V2. It never opens the active user memory root, rejects trajectory
objects containing question, answer, or evaluator fields, and sends only the
runtime's bounded retrieved evidence to the reader. Its benchmark projection
retains compact trajectory/field provenance and a grounding contract, while the
ordinary user-memory recall projection remains unchanged.

Every treatment memory configuration must provide both `corpus_path` and
`corpus_sha256`. Before ingesting any trajectory, the adapter hashes the
actual local corpus file and rejects a mismatch. The path is runtime-only; the
private metadata retains the verified hash, never the corpus body.

For the text-only projection, the adapter builds a private
`lme_trajectory_records` directory beside the isolated FTS index. Query-time
selection first groups bounded matching state records by their observed
`trajectory_id`, then emits each selected trajectory's recorded
`goal/outcome` header with its strongest state evidence. This prevents one
trajectory's repeated chunks from consuming all four evidence positions. The
directory is derived only from already admitted trajectory observations; it
never stores benchmark questions, answers, evaluator labels, or active user
memory. The normal reader contract remains at most four bounded evidence
packets under the configured 500-token budget.

The wrapper defaults `--super-brain-max-api-retries` to `0`, so an upstream
retry cannot silently exceed an approved external-request budget. This setting
changes only the wrapper process; the pinned official repository is unchanged.
When an operator explicitly raises that value, the custom Responses bridge now
uses the same bounded budget: at most three retries for HTTP 408/429/5xx or
allowlisted terminal conditions such as `rate_limit_exceeded`. Each retry is
reported only by status/code and count; no prompt, answer, response body, or
credential is written to the retry log. Non-transient request and model errors
remain fail-closed.

On Windows, `scripts/longmemeval-v2.ps1 -Action Prepare -Apply` can bootstrap
the pinned Python 3.11.9 runtime into the private benchmark state when no
compatible interpreter is already available. The official `python.org`
installer is checked against SHA-256
`5ee42c4eee1e6b4464bb23722f90b45303f79442df63083f05322f1785f5fdde` and its
Authenticode signature before use. It targets only the private state directory
and disables PATH, launcher, and file-association integration. This step still
requires `-Apply`; it does not download benchmark data, send a prompt, or make
a model request. The 1.11 GiB small-tier corpus remains a separate explicit
`FetchTextData -Apply` operation.

The first supported protocol is the official `small` tier, run separately for
the web and enterprise domains. Within each domain the tier shares one
100-trajectory haystack, so treatment builds one isolated store per domain.
The baseline uses the official `no_retrieval` backend with an empty memory
context. Both arms must use the same reader model identity, endpoint, budget,
tools, data revision, harness commit, question order, and environment. The
only changed variable is Super Brain enablement.

The current adapter is intentionally text-only for trajectory memory. It may
include official question images when the official harness supplies them, but
does not inspect or emit trajectory screenshots. A completed run is therefore
an `official_harness_text_memory_ablation_not_leaderboard`, not a full
multimodal LongMemEval-V2 leaderboard result. Do not call it a general
intelligence score, a hidden-test score, or evidence of user-preference
learning.

Before any paid run, retain private hashes for the official repository tree,
dataset revision and checksums, adapter, renderer, package manifest,
`brain_core.py`, memory policy, both arm configurations, selected case set,
and each produced official harness artifact. The public package must contain
only the adapter and protocol, never benchmark data, answers, prompts, API
credentials, or run outputs.

## Blinded Diagnostic Runner

`scripts/objective-benchmark-runner.ps1` is the local evidence layer for a
paired blind diagnostic. It is not an official benchmark adapter and its final
report is always `diagnostic_non_publishable`.

Prepare two separately generated answer artifacts with schema
`super-brain.objective-answer-artifact.v1`. Each needs a shared
`caseSetHash`, identical case `id`/`prompt`/`reference`/`rubric` values, and a
`generator` object containing `runId`, `executionId`, `modelId`,
`modelVersion`, `requestedModelId`, `reportedModelId`, `toolchainHash`, `budgetHash`, `environmentHash`,
`promptTemplateHash`, `independentExecution`, and
`superMemoryBrainEnabled`. Baseline must set the last field to `false`; the
treatment must set it to `true`. Requested, reported, and per-case response
model identities must match exactly; aliases and overrides are rejected.
The benchmark variant is also explicit and comparison-bound. LongMemEval
`longmemeval_s_cleaned.json` runs use `benchmarkVariant=s_cleaned`; they must
never be labeled `oracle`.

For v14 LongMemEval generation, use
`scripts/objective-answer-artifact-generator.ps1` as an independently invoked
single-arm launcher once per arm with `benchmarkVariant=s_cleaned`. It accepts
only a private `super-brain.objective-answer-input.v1` prepared by the external
benchmark/harness workflow; it does not fetch an official corpus, install a
provider, or claim that an official adapter is installed. The input carries
the later blind-judge `reference` and `rubric`, but the generator never sends
either field to the answer model. Baseline cases must have an empty
`retrievedContext`; treatment cases may carry only their own retrieved context.
Each output is private, requires explicit `-Apply`, verifies the endpoint
reported model, and records separate execution, package, selection, corpus,
harness, prompt, budget, environment, and response-receipt hashes. Do not
label an `s_cleaned` run as `oracle`; a legacy paired `objective_runner.py`
must not produce fresh v14 evidence.

Every `Generate` invocation also creates a private atomic checkpoint beside the
requested answer artifact by default (`<output>.checkpoint.json`), or at the
explicit private `-CheckpointPath`. The checkpoint is bound to the answer
input, pair contract, model, reasoning effort, batch budget, endpoint hash,
current toolchain fingerprint, and successful transport-probe receipt. Use
`-MaxNewBatches N` only to create an intentional handoff boundary, then resume
the same arm with `-Resume` and the identical generation settings. Completed
batches are never sent again. A checkpoint containing a failed or
`in_progress` batch fails closed instead of retrying it: start a new controlled
diagnostic run after the provider is stable. Checkpoints and answer artifacts
remain private; they do not store credentials or raw transport replies.

1. Run `Prepare` to write an opaque A/B judge input and a private mapping
   state. The judge input contains no baseline/treatment labels.
2. Set `SUPER_BRAIN_JUDGE_RESPONSES_URL` and the named credential environment
   variable outside package files, then run `Probe -Apply`. When no explicit
   pair is present, the current Codex Desktop Responses provider is selected
   before the managed SMAG fallback. Partial explicit configuration, HTML, a
   model mismatch, or unsupported provider wire API fails closed: there is no
   hidden endpoint/model switch or retry. The judge client accepts both JSON
   Responses payloads and SSE streams, but model identity is admitted only from
   the final `response.completed` object. A successful probe writes a private
   transport receipt bound to the endpoint, requested model, reasoning effort,
   and current bridge/client hashes. `configured_unverified` means only that a
   URL and credential were found; it is never permission for batch generation.
3. Run `Judge -Apply` with the configured `gpt-5.6-terra` / `max` settings, or
   supply an independently produced
   `super-brain.objective-blind-judge-result.v1` artifact.
   The result path is an atomic incremental checkpoint: rerunning `Judge` with
   the same blind input validates and resumes completed decisions, and a fully
   completed result returns without another network call. Every resumable
   checkpoint retains the hash of the endpoint authority that produced it. A
   judge run with pending decisions requires a fresh matching transport receipt
   before it sends any batch request; completed checkpoints and purely local
   checkpoint closure make no network call and do not need a new probe.
4. Run `Finalize` with the `stateSha256` receipt returned by `Prepare` as
   `-ExpectedStateSha256`; it revalidates the state and both answer artifacts,
   then unblinds and emits raw
   paired counts, rates, wins, losses, and ties.

When the Desktop-native agent path is available but an external Responses
bridge is not suitable for the judge, the runner also supports a private,
host-native judge handoff. After `Prepare`, run `ExportNative -Apply` with the
private blind input, a private native manifest path, and an explicit batch
size. It writes one opaque batch per host dispatch; a batch contains only the
task, reference, rubric, candidate A, and candidate B. It never contains
baseline/treatment condition labels or the unblinding map. Each native host
response must contain only its bound batch id/hash, host agent/dispatch ids,
and one Boolean pass decision for each candidate. `ImportNative -Apply`
re-hashes every batch, rejects label leakage, duplicate dispatches, incomplete
coverage, and binding/model/contract mismatches, then writes a local
`super-brain.objective-blind-judge-result.v1` for `Finalize`. All manifests,
batches, host responses, receipts, and reports must remain under
`private-state` when they live inside this package. This route is a
Desktop-native internal diagnostic fallback, not an official LongMemEval run
or a general model-intelligence score.

The runner stores answer and raw judge-response hashes in its final report,
not credentials or raw judge replies. A reachable local proxy is not evidence
that a requested model or reasoning level is supported; a successful probe is
required before a paid full run. Legacy
`super-brain.objective-benchmark-run.v1` results are diagnostic only because
their protocol fields are self-attested.
