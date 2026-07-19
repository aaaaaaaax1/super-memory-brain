# Structured Technology Decision

Purpose: turn architecture and stack selection into a cold, evidence-bounded
decision workflow. The user answers short multiple-choice questions; Super
Brain retrieves feasible stack profiles, scores them, explains the winner, and
lists facts that require fresh verification before implementation.

## Activation

Use for architecture, framework, database, AI-native toolchain, edge runtime,
deployment, or full-stack selection. Keep it cold for ordinary coding and do
not add the catalog or questionnaire to startup context.

## Decision Chain

```text
multiple-choice requirements
-> functional role and platform constraints
-> feasible architecture profiles
-> weighted multi-dimensional score
-> compatibility and hard-constraint checks
-> recommendation under current evidence
-> fresh verification of volatile facts
-> engineering-decision-gate before commitment
```

The requirement model covers product/function purpose, target platform, team
preference, scale/latency, data shape, AI workload, security/compliance,
operations/deployment, budget, delivery speed, and maintenance horizon.

## Evidence Boundary

Catalog scores are auditable expert priors on a 1-5 scale, not live benchmarks
or universal truth. They support comparison, not factual claims about the
latest version, price, regional availability, license, benchmark, or compliance
certification. Those volatile facts remain `UNKNOWN` until checked against
current official sources and the target environment.

Call a result `recommended under current evidence` unless live evidence proves
all assumptions required by the Engineering Judgment best-option guard.

## Interface

```powershell
scripts\technology-decision.ps1 -Action Questionnaire -Json
scripts\technology-decision.ps1 -Action Recommend -AnswersJson '<answers>' -Json
scripts\technology-decision.ps1 -Action Recommend -AnswersPath '.\answers.json' -Json
scripts\technology-decision.ps1 -Action Catalog -Layer backend -Query dotnet -Json
scripts\technology-decision.ps1 -Action Validate -Json
```

`Questionnaire` emits choices only. `Recommend` never guesses missing answers;
it returns only the missing questions and their options. `Catalog`, `Validate`,
and `Questionnaire` are read-only. No answer or recommendation is written to
memory automatically.

## Output Contract

- Requirement card: selected choices and derived priorities.
- Ranked profiles: total, baseline, fit, dimension contribution, strengths,
  tradeoffs, and hard warnings.
- Stack map: architecture, frontend, backend, data, AI, edge, deployment, and
  observability roles remain separate even if one platform can implement more
  than one role.
- Fresh checks: versions, pricing, regions, licenses, security/compliance,
  deployment quotas, benchmarks, and team proof-of-concept results.
- Decision boundary: confidence and conditions that could change the winner.

## Maintenance

Extend `references/technology-catalog.json` with representative technologies
or profiles. Keep stable IDs, score every declared dimension, reference only
known component IDs, and run `technology-decision.ps1 -Action Validate` plus
Pester and package verification. Prefer representative, decision-relevant
options over an exhaustive package registry.
