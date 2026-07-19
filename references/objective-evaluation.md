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

For v14 LongMemEval generation, run
`local/objective_answer_runner.py` once per arm with
`--benchmark-variant s_cleaned`. The older paired `objective_runner.py` is a
legacy diagnostic and must not produce fresh v14 evidence.

1. Run `Prepare` to write an opaque A/B judge input and a private mapping
   state. The judge input contains no baseline/treatment labels.
2. Set `SUPER_BRAIN_JUDGE_RESPONSES_URL` and the named credential environment
   variable outside package files, then run `Probe -Apply`.
   The judge client accepts both JSON Responses payloads and SSE streams, but
   model identity is admitted only from the final `response.completed` object.
3. Run `Judge -Apply` with the configured `gpt-5.6-luna` / `max` settings, or
   supply an independently produced
   `super-brain.objective-blind-judge-result.v1` artifact.
   The result path is an atomic incremental checkpoint: rerunning `Judge` with
   the same blind input validates and resumes completed decisions, and a fully
   completed result returns without another network call. Every resumable
   checkpoint retains the hash of the endpoint authority that produced it.
4. Run `Finalize` with the `stateSha256` receipt returned by `Prepare` as
   `-ExpectedStateSha256`; it revalidates the state and both answer artifacts,
   then unblinds and emits raw
   paired counts, rates, wins, losses, and ties.

The runner stores answer and raw judge-response hashes in its final report,
not credentials or raw judge replies. A reachable local proxy is not evidence
that a requested model or reasoning level is supported; a successful probe is
required before a paid full run. Legacy
`super-brain.objective-benchmark-run.v1` results are diagnostic only because
their protocol fields are self-attested.
