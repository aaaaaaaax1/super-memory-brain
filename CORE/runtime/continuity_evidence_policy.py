"""Advisory evidence weights for model-led continuity decisions.

This module ranks compact, already-validated evidence metadata. It does not
read user prompts, task bodies, project files, or memory, and it cannot grant
execution permission. The model receives the current request through its
normal conversation context and remains responsible for interpreting it.
"""

from __future__ import annotations

from typing import Any

from activation_receipt import canonical_hash


SCHEMA = "super-brain.continuity-evidence.v1"
WEIGHTS = {
    "current_user_request": 1.0,
    "live_project_evidence": 1.0,
    "current_project_progress": 0.9,
    "current_visible_progress": 0.85,
    "current_scoped_contract": 0.75,
    "typed_memory": 0.45,
    "contract_next_action": 0.35,
}


def _state(value: Any, *, current_labels: tuple[str, ...] = ("current",)) -> str:
    return "current" if isinstance(value, dict) and value.get("state") in current_labels else "unavailable_or_stale"


def _candidate(
    source: str,
    domain: str,
    state: str,
    weight: float,
    evidence_hash: str = "",
    *,
    use: str,
) -> dict[str, Any]:
    return {
        "source": source,
        "domain": domain,
        "state": state,
        "weight": weight if state in {"current", "ready", "available_to_model"} else 0.0,
        "evidenceHash": evidence_hash,
        "use": use,
        "nonAuthorizing": True,
    }


def build_continuity_evidence(
    *,
    turn_intent: dict[str, Any] | None,
    task: dict[str, Any] | None,
    project_knowledge: dict[str, Any] | None,
    typed_memory: dict[str, Any] | None,
    action_authorization: str,
) -> dict[str, Any]:
    """Rank current evidence by the question it can answer, not by one total order."""

    intent = turn_intent if isinstance(turn_intent, dict) else {}
    current_task = task if isinstance(task, dict) else {}
    project = project_knowledge if isinstance(project_knowledge, dict) else {}
    memory = typed_memory if isinstance(typed_memory, dict) else {}
    progress = current_task.get("projectProgress") if isinstance(current_task.get("projectProgress"), dict) else {}
    visible = current_task.get("visibleProgress") if isinstance(current_task.get("visibleProgress"), dict) else {}
    contract_current = bool(current_task.get("contractHash")) and int(current_task.get("contractRevision", 0) or 0) > 0
    memory_current = str(memory.get("state", "")) in {"selected", "ready"} and bool(memory.get("payloadHash"))
    memory_effects = memory.get("effects") if isinstance(memory.get("effects"), list) else []
    memory_weight = WEIGHTS["typed_memory"]
    if memory_current:
        valid_weights = [
            float(effect.get("advisoryWeight"))
            for effect in memory_effects
            if isinstance(effect, dict)
            and isinstance(effect.get("advisoryWeight"), (int, float))
            and not isinstance(effect.get("advisoryWeight"), bool)
            and 0.0 <= float(effect.get("advisoryWeight")) <= 1.0
        ]
        if valid_weights:
            memory_weight = min(0.65, max(valid_weights))

    candidates = [
        _candidate(
            "latest_user_request",
            "objective",
            "available_to_model",
            WEIGHTS["current_user_request"],
            use="read_the_visible_current_user_request_directly_it_defines_the_goal_and_may_replace_an_older_task_action",
        ),
        _candidate(
            "live_project_evidence",
            "facts",
            _state(project, current_labels=("ready",)),
            WEIGHTS["live_project_evidence"],
            str(project.get("payloadHash", "")),
            use="verify_current_project_facts_and_claims",
        ),
        _candidate(
            "current_project_progress_proof",
            "progress",
            _state(progress),
            WEIGHTS["current_project_progress"],
            str(progress.get("payloadHash", "")),
            use="ground_what_is_verified_done",
        ),
        _candidate(
            "current_visible_progress_receipt",
            "progress",
            _state(visible),
            WEIGHTS["current_visible_progress"],
            str(visible.get("payloadHash", "")),
            use="anchor_what_was_last_reported",
        ),
        _candidate(
            "current_scoped_execution_contract",
            "continuity",
            "current" if contract_current else "unavailable_or_stale",
            WEIGHTS["current_scoped_contract"],
            str(current_task.get("contractHash", "")),
            use="identify_the_workline_and_recent_state_not_a_mandatory_next_step",
        ),
        _candidate(
            "eligible_typed_memory",
            "supporting_context",
            "current" if memory_current else "unavailable_or_stale",
            memory_weight,
            str(memory.get("payloadHash", "")),
            use="offer_optional_historical_context_that_must_be_checked_against_current_evidence",
        ),
        _candidate(
            "contract_next_action",
            "action_hint",
            "current" if contract_current and str(current_task.get("nextAction", "")).strip() else "unavailable_or_stale",
            WEIGHTS["contract_next_action"],
            canonical_hash({
                "contractHash": str(current_task.get("contractHash", "")),
                "nextAction": str(current_task.get("nextAction", "")),
            }) if contract_current and str(current_task.get("nextAction", "")).strip() else "",
            use="candidate_for_the_model_to_accept_reframe_or_discard",
        ),
    ]
    body: dict[str, Any] = {
        "schema": SCHEMA,
        "state": "advisory",
        "turnIntent": str(intent.get("kind", "direct")),
        "weightScale": "relative_hints_0_to_1_not_probabilities",
        "weightsComparableOnlyWithinDomain": True,
        "candidates": candidates,
        "modelDiscretion": {
            "currentRequestOwnsObjective": True,
            "liveEvidenceOwnsProjectFacts": True,
            "contractNextActionIsNotACommand": True,
            "mayReframeOrStopWhenCurrentRequestCallsForIt": True,
            "continuationIsNotMandatory": True,
            "weightsDoNotGrantExecutionPermission": True,
        },
        "actionAuthorization": {
            "state": str(action_authorization or "withheld"),
            "weightingCanGrantPermission": False,
        },
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "nonAuthorizing": True,
    }
    body["payloadHash"] = canonical_hash(body)
    return body


__all__ = ["SCHEMA", "WEIGHTS", "build_continuity_evidence"]
