# Engineering Judgment Contract

Purpose: make non-trivial engineering advice evidence-bounded, decision-oriented,
and executable without burdening ordinary chat or tiny obvious tasks.

## Activation

Activate this contract for debugging, repair, optimization, architecture,
migration, performance, root-cause analysis, consequential design choices, and
claims that one option is best or optimal.

Do not activate it for greetings, acknowledgements, simple factual answers, or
tiny fully specified low-risk actions. Concision is part of the contract.

## Required Reasoning Chain

```text
pain point
-> FACT / INFERENCE / UNKNOWN separation
-> root cause and constraints
-> explicit objective function
-> feasible option comparison
-> best option under current evidence
-> dependency-ordered execution
-> per-step verification
-> final acceptance and residual risk
```

## Epistemic Classes

- `FACT`: supported by named live evidence. A memory, prior summary, or confident
  statement is not a fact until checked against current evidence.
- `INFERENCE`: a conclusion derived from facts. State the dependency and do not
  present it as observed evidence.
- `UNKNOWN`: information that is absent, stale, conflicting, or not yet tested.
  Mark critical unknowns and choose the cheapest test that can discriminate
  between materially different decisions.

Newer live evidence overrides memory and earlier assumptions. When evidence is
missing, reduce the claim instead of filling the gap with plausible detail.

## Root Cause

Every root-cause statement has one status:

- `verified`: requires direct evidence.
- `hypothesis`: requires a discriminating test.
- `unknown`: requires a discriminating test before causal certainty.

Symptoms, contributing conditions, and root causes must remain separate.

## Best-Option Guard

Do not call a choice best or optimal unless all of these are explicit:

1. Objective or cost function.
2. Constraints and non-negotiables.
3. At least two feasible alternatives.
4. Tradeoffs for each alternative.
5. Decision criteria.
6. Evidence supporting the facts used by the decision.
7. Resolution evidence for any critical unknown that could change the winner.

Without those conditions, label the result `recommended under current evidence`,
not `optimal`. Optimal means best under the stated objective and constraints,
not universally best.

## Execution Contract

Each execution step records:

- input and dependency;
- expected output;
- acceptance condition;
- stop condition.

Order steps by dependency. Verify each step before consuming its output in the
next step. On failed acceptance or a stop condition, halt, update the model, and
recompute the next action instead of continuing the old plan.

A hypothesis or unknown root cause may pass the pre-mutation gate when it has a
discriminating test plan. It may not pass completion until that test has result
evidence or the root cause has been reclassified as verified.

## Output Contract

For non-trivial engineering work, use this compact shape:

```text
Judgment: the decision and confidence boundary
Evidence: FACT / INFERENCE / UNKNOWN
Best option: winner under the stated objective and constraints
Execution chain: dependency-ordered steps with checks
Acceptance/Risk: completion evidence and residual risk
```

Use `scripts/engineering-decision-gate.ps1` to create task-scoped decision
evidence before meaningful mutation or completion.
