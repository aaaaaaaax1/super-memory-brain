from __future__ import annotations

"""Small, stateless H7 turn-intent contract.

The caller supplies one normalized intent kind after interpreting visible user
context.  This module never accepts, stores, hashes, or classifies raw prompt
text; it only turns that bounded choice into the rule, memory, and response
obligations that H7 can evidence.
"""

import hashlib
import json
from typing import Any


SCHEMA = "super-brain.turn-intent.v1"
TURN_INTENTS = (
    "direct",
    "greeting",
    "side_message",
    "task_status",
    "continuity",
    "design_evaluate",
    "plan_proposal",
    "super_brain_issue_continuity",
    "super_brain_issue_runtime",
    "super_brain_issue_memory",
    "super_brain_issue_ui",
    "user_correction",
    "memory_write",
)
MEMORY_MODES = {"auto", "force", "off"}


def canonical_hash(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    ).hexdigest()


def _spec(
    *,
    signals: tuple[str, ...] = (),
    governed: bool = True,
    response_profile: str = "direct",
    problem_nature: str = "",
    learning_target: str = "none",
    memory_use: str = "scope_bound_recall",
    project_evidence: bool = False,
    plan_approval: str = "not_applicable",
    execution_assist_required: bool = False,
    execution_assist_allowed: bool = True,
    route_class: str = "direct",
    activation_tier: str = "none",
    requires_task_pointer: bool = False,
    requires_project_proof: bool = False,
    requires_capability_route: bool = False,
    user_visible_state: str = "direct",
    activation_route: str = "direct_answer",
) -> dict[str, Any]:
    return {
        "signals": signals,
        "governed": governed,
        "responseProfile": response_profile,
        "problemNature": problem_nature,
        "learningTarget": learning_target,
        "memoryUse": memory_use,
        "projectEvidenceRequired": project_evidence,
        "planApproval": plan_approval,
        "executionAssistRequired": execution_assist_required,
        "executionAssistAllowed": execution_assist_allowed,
        "routeClass": route_class,
        "activationTier": activation_tier,
        "requiresTaskPointer": requires_task_pointer,
        "requiresProjectProof": requires_project_proof,
        "requiresCapabilityRoute": requires_capability_route,
        "userVisibleState": user_visible_state,
        "activationRoute": activation_route,
    }


_SPECS: dict[str, dict[str, Any]] = {
    "direct": _spec(activation_route="direct_answer"),
    "greeting": _spec(governed=False, response_profile="direct", memory_use="none", execution_assist_allowed=False, activation_route="direct_answer"),
    "side_message": _spec(governed=False, response_profile="direct", memory_use="none", execution_assist_allowed=False, activation_route="direct_answer"),
    "task_status": _spec(
        signals=("status",),
        response_profile="status",
        memory_use="current_state_only",
        route_class="task",
        activation_tier="task",
        requires_task_pointer=True,
        user_visible_state="task",
        activation_route="current_task_status",
    ),
    "continuity": _spec(
        signals=("resume", "continue", "recovery"),
        response_profile="continuity",
        memory_use="recovery_context",
        route_class="continuity",
        activation_tier="continuity_light",
        requires_task_pointer=True,
        requires_project_proof=True,
        user_visible_state="continuity",
        activation_route="current_session_continue",
    ),
    "design_evaluate": _spec(
        signals=("design", "evaluate", "plan"),
        response_profile="project_design",
        memory_use="project_evidence_support",
        project_evidence=True,
        plan_approval="required_before_mutation",
        execution_assist_required=True,
        route_class="task",
        activation_tier="task",
        requires_task_pointer=True,
        requires_project_proof=True,
        requires_capability_route=True,
        user_visible_state="task",
        activation_route="collaborative_intent",
    ),
    "plan_proposal": _spec(
        signals=("plan", "proposal", "evaluate"),
        response_profile="proposal",
        memory_use="project_evidence_support",
        project_evidence=True,
        plan_approval="required_before_mutation",
        execution_assist_required=True,
        route_class="task",
        activation_tier="task",
        requires_task_pointer=True,
        requires_project_proof=True,
        requires_capability_route=True,
        user_visible_state="task",
        activation_route="collaborative_intent",
    ),
    "super_brain_issue_continuity": _spec(
        signals=("super_brain_defect", "root_cause", "repair", "resume", "continue"),
        response_profile="super_brain_issue",
        problem_nature="execution_continuity",
        learning_target="execution_rule_candidate",
        memory_use="core_rule_first",
        project_evidence=True,
        execution_assist_required=True,
        route_class="diagnostic",
        activation_tier="full_diagnostic",
        requires_task_pointer=True,
        requires_project_proof=True,
        requires_capability_route=True,
        user_visible_state="diagnostic",
        activation_route="fix_bug",
    ),
    "super_brain_issue_runtime": _spec(
        signals=("super_brain_defect", "root_cause", "repair", "governed_turn"),
        response_profile="super_brain_issue",
        problem_nature="hookless_runtime",
        learning_target="core_rule_candidate",
        memory_use="core_rule_first",
        project_evidence=True,
        execution_assist_required=True,
        route_class="diagnostic",
        activation_tier="full_diagnostic",
        requires_task_pointer=True,
        requires_project_proof=True,
        requires_capability_route=True,
        user_visible_state="diagnostic",
        activation_route="fix_bug",
    ),
    "super_brain_issue_memory": _spec(
        signals=("super_brain_defect", "root_cause", "repair", "memory_recall"),
        response_profile="super_brain_issue",
        problem_nature="memory_recall_effect",
        learning_target="system_rule_candidate",
        memory_use="memory_recall_diagnosis",
        project_evidence=True,
        execution_assist_required=True,
        route_class="diagnostic",
        activation_tier="full_diagnostic",
        requires_task_pointer=True,
        requires_project_proof=True,
        requires_capability_route=True,
        user_visible_state="diagnostic",
        activation_route="fix_bug",
    ),
    "super_brain_issue_ui": _spec(
        signals=("super_brain_defect", "root_cause", "repair"),
        response_profile="super_brain_issue",
        problem_nature="memory_ui_projection",
        learning_target="experience_candidate",
        memory_use="project_projection_diagnosis",
        project_evidence=True,
        execution_assist_required=True,
        route_class="diagnostic",
        activation_tier="full_diagnostic",
        requires_task_pointer=True,
        requires_project_proof=True,
        requires_capability_route=True,
        user_visible_state="diagnostic",
        activation_route="fix_bug",
    ),
    "user_correction": _spec(
        signals=("user_correction", "learning"),
        response_profile="correction",
        learning_target="classification_required_before_learning",
        memory_use="classify_before_write",
        route_class="direct",
        activation_tier="none",
        user_visible_state="direct",
        activation_route="direct_answer",
    ),
    "memory_write": _spec(
        signals=("remember", "learning"),
        response_profile="memory_candidate",
        learning_target="memory_candidate_only",
        memory_use="candidate_not_commit",
        route_class="memory",
        activation_tier="memory_only",
        requires_task_pointer=True,
        user_visible_state="memory",
        activation_route="memory_write_candidate",
    ),
}


def resolve_turn_intent(intent: Any = "direct", *, memory_mode: Any = "auto") -> dict[str, Any]:
    """Resolve one safe, non-persistent H7 turn profile.

    ``intent`` is a bounded enum, not user text.  Callers must choose the
    issue subtype based on visible current context; ambiguity remains explicit
    instead of being guessed from historical memory.
    """

    kind = str(intent or "direct").strip().lower()
    mode = str(memory_mode or "auto").strip().lower()
    if kind not in _SPECS:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "TURN_INTENT_INVALID",
            "kind": kind,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    if mode not in MEMORY_MODES:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "TURN_INTENT_MEMORY_MODE_INVALID",
            "kind": kind,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    spec = _SPECS[kind]
    # A non-state insertion must never wake recall or inherit a governed
    # memory mode.  It is intentionally indistinguishable from a greeting at
    # the H7 storage boundary: direct host handling only, no contract write.
    effective_mode = "off" if kind in {"greeting", "side_message"} and mode == "auto" else mode
    signals = list(spec["signals"])
    if spec["governed"]:
        signals.insert(0, "mutation_guard")
    body: dict[str, Any] = {
        "schema": SCHEMA,
        "kind": kind,
        "governed": bool(spec["governed"]),
        "memoryMode": effective_mode,
        "ruleSignals": signals,
        "responseProfile": str(spec["responseProfile"]),
        "problemNature": str(spec["problemNature"]),
        "responseOrder": "essence>fact_inference_unknown>repair>next" if spec["responseProfile"] == "super_brain_issue" else "",
        "repairMode": "diagnose_and_repair" if spec["responseProfile"] == "super_brain_issue" else "",
        "learningTarget": str(spec["learningTarget"]),
        "memoryUse": str(spec["memoryUse"]),
        "learningWriteAllowed": False,
        "projectEvidenceRequired": bool(spec["projectEvidenceRequired"]),
        "planApproval": str(spec["planApproval"]),
        "executionAssistRequired": bool(spec["executionAssistRequired"]),
        "executionAssistAllowed": bool(spec["executionAssistAllowed"]),
        "routeClass": str(spec["routeClass"]),
        "activationTier": str(spec["activationTier"]),
        "requiresTaskPointer": bool(spec["requiresTaskPointer"]),
        "requiresProjectProof": bool(spec["requiresProjectProof"]),
        "requiresCapabilityRoute": bool(spec["requiresCapabilityRoute"]),
        "userVisibleState": str(spec["userVisibleState"]),
        "activationRoute": str(spec["activationRoute"]),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    body["payloadHash"] = canonical_hash(body)
    return {"ok": True, "code": "TURN_INTENT_CURRENT", **body}


def public_projection(value: dict[str, Any] | None) -> dict[str, Any]:
    """Bound external output to metadata only; never expose caller text."""

    value = value if isinstance(value, dict) else {}
    fields = (
        "schema", "kind", "governed", "memoryMode", "ruleSignals", "responseProfile",
        "problemNature", "responseOrder", "repairMode", "learningTarget", "learningWriteAllowed",
        "memoryUse",
        "projectEvidenceRequired", "planApproval", "executionAssistRequired", "executionAssistAllowed",
        "routeClass", "activationTier", "requiresTaskPointer", "requiresProjectProof",
        "requiresCapabilityRoute", "userVisibleState",
        "activationRoute",
        "payloadHash", "rawPromptStored", "rawTranscriptStored",
    )
    return {
        "ok": bool(value.get("ok")),
        "code": str(value.get("code", "TURN_INTENT_UNAVAILABLE")),
        **{field: value.get(field) for field in fields if field in value},
    }


__all__ = ["SCHEMA", "TURN_INTENTS", "canonical_hash", "public_projection", "resolve_turn_intent"]
