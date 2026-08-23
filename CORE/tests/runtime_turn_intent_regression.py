from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from turn_intent import TURN_INTENTS, public_projection, resolve_turn_intent


def main() -> int:
    assert "super_brain_issue_runtime" in TURN_INTENTS

    route_map = json.loads((ROOT / "route-map.json").read_text(encoding="utf-8-sig"))
    route_entries = route_map.get("routes") if isinstance(route_map, dict) else None
    assert isinstance(route_entries, list), route_map
    route_metadata = {
        str(entry.get("route")): entry
        for entry in route_entries
        if isinstance(entry, dict) and str(entry.get("route", "")).strip()
    }
    assert len(route_metadata) == len(
        [entry for entry in route_entries if isinstance(entry, dict) and str(entry.get("route", "")).strip()]
    ), "route-map contains duplicate route names"
    parity_fields = (
        "routeClass",
        "activationTier",
        "requiresTaskPointer",
        "requiresProjectProof",
        "requiresCapabilityRoute",
        "userVisibleState",
    )
    for kind in TURN_INTENTS:
        resolved = resolve_turn_intent(kind)
        route = str(resolved.get("activationRoute", ""))
        assert route in route_metadata, (kind, route)
        declared = route_metadata[route]
        for field in parity_fields:
            assert resolved.get(field) == declared.get(field), (kind, route, field, resolved, declared)

    design = resolve_turn_intent("design_evaluate")
    assert design["ok"] is True, design
    assert design["ruleSignals"] == ["mutation_guard", "design", "evaluate", "plan"], design
    assert design["projectEvidenceRequired"] is True, design
    assert design["planApproval"] == "required_before_mutation", design
    assert design["memoryUse"] == "project_evidence_support", design
    assert design["learningWriteAllowed"] is False, design
    assert design["routeClass"] == "task", design
    assert design["activationTier"] == "task", design
    assert design["requiresTaskPointer"] is True, design
    assert design["requiresProjectProof"] is True, design
    assert design["requiresCapabilityRoute"] is True, design
    assert design["userVisibleState"] == "task", design
    assert design["activationRoute"] == "collaborative_intent", design
    assert design["payloadHash"]

    issue = resolve_turn_intent("super_brain_issue_runtime")
    assert issue["ok"] is True, issue
    assert issue["ruleSignals"][0] == "mutation_guard", issue
    assert issue["problemNature"] == "hookless_runtime", issue
    assert issue["responseOrder"] == "essence>fact_inference_unknown>repair>next", issue
    assert issue["learningTarget"] == "core_rule_candidate", issue
    assert issue["memoryUse"] == "core_rule_first", issue
    assert issue["projectEvidenceRequired"] is True, issue
    assert issue["routeClass"] == "diagnostic", issue
    assert issue["activationTier"] == "full_diagnostic", issue
    assert issue["requiresTaskPointer"] is True, issue
    assert issue["requiresProjectProof"] is True, issue
    assert issue["requiresCapabilityRoute"] is True, issue
    assert issue["userVisibleState"] == "diagnostic", issue
    assert issue["activationRoute"] == "fix_bug", issue

    continuity = resolve_turn_intent("continuity")
    assert continuity["routeClass"] == "continuity", continuity
    assert continuity["activationTier"] == "continuity_light", continuity
    assert continuity["requiresTaskPointer"] is True, continuity
    assert continuity["requiresProjectProof"] is True, continuity
    assert continuity["requiresCapabilityRoute"] is False, continuity
    assert continuity["activationRoute"] == "current_session_continue", continuity

    memory_write = resolve_turn_intent("memory_write")
    assert memory_write["routeClass"] == "memory", memory_write
    assert memory_write["activationTier"] == "memory_only", memory_write
    assert memory_write["requiresTaskPointer"] is True, memory_write
    assert memory_write["activationRoute"] == "memory_write_candidate", memory_write
    assert memory_write["requiresProjectProof"] is False, memory_write
    assert memory_write["requiresCapabilityRoute"] is False, memory_write

    greeting = resolve_turn_intent("greeting")
    assert greeting["ok"] is True and greeting["governed"] is False, greeting
    assert greeting["memoryMode"] == "off", greeting
    assert greeting["ruleSignals"] == [], greeting
    assert greeting["memoryUse"] == "none", greeting

    side_message = resolve_turn_intent("side_message")
    assert side_message["governed"] is False, side_message
    assert side_message["ruleSignals"] == [], side_message

    for kind in TURN_INTENTS:
        resolved = resolve_turn_intent(kind)
        assert resolved["routeClass"] in {"direct", "memory", "task", "continuity", "diagnostic"}, (kind, resolved)
        assert resolved["activationTier"] in {"none", "memory_only", "task", "continuity_light", "full_diagnostic"}, (kind, resolved)
        for field in ("requiresTaskPointer", "requiresProjectProof", "requiresCapabilityRoute"):
            assert isinstance(resolved[field], bool), (kind, field, resolved)
        assert resolved["userVisibleState"] in {"direct", "memory", "task", "continuity", "diagnostic"}, (kind, resolved)
        assert isinstance(resolved["activationRoute"], str) and resolved["activationRoute"], (kind, resolved)
        if resolved["governed"]:
            assert resolved["ruleSignals"][0] == "mutation_guard", (kind, resolved)
        else:
            assert "mutation_guard" not in resolved["ruleSignals"], (kind, resolved)

    forced_greeting = resolve_turn_intent("greeting", memory_mode="force")
    assert forced_greeting["memoryMode"] == "force", forced_greeting

    correction = resolve_turn_intent("user_correction")
    assert correction["learningWriteAllowed"] is False, correction
    assert correction["learningTarget"] == "classification_required_before_learning", correction
    assert correction["memoryUse"] == "classify_before_write", correction

    invalid = resolve_turn_intent("not-a-real-intent")
    assert invalid["ok"] is False and invalid["code"] == "TURN_INTENT_INVALID", invalid
    invalid_mode = resolve_turn_intent("direct", memory_mode="raw")
    assert invalid_mode["ok"] is False and invalid_mode["code"] == "TURN_INTENT_MEMORY_MODE_INVALID", invalid_mode

    public = public_projection(issue)
    assert "rawPrompt" not in str(public).lower()
    assert public["rawPromptStored"] is False and public["rawTranscriptStored"] is False
    print("TURN_INTENT_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
