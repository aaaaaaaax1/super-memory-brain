from __future__ import annotations

import json
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from execution_assist import REQUEST_SCHEMA, resolve_execution_assist


def _intent(kind: str) -> dict[str, object]:
    return {"kind": kind, "governed": True}


def test_default_engineering_route_is_native_and_private() -> None:
    receipt, code = resolve_execution_assist(ROOT, _intent("design_evaluate"))

    assert code == "H7_EXECUTION_ASSIST_DEFAULTED"
    assert receipt is not None and receipt["state"] == "ready"
    route = receipt["capabilityRouteReceipt"]
    assert route["state"] == "ready"
    assert "sb.native.mattpocock.codebase-design.v1" in route["selectedNativeCapabilityIds"]
    assert route["nonAuthorizing"] is True
    assert route["rawPromptStored"] is False and route["rawTranscriptStored"] is False
    assert receipt["capabilityApplyPresentation"]["applyPhase"] == "planning"
    assert "sb.native.mattpocock.codebase-design.v1" in receipt["capabilityApplyPresentation"]["activeNativeCapabilityIds"]
    serialized = json.dumps(receipt, ensure_ascii=False)
    assert '"sourcePath"' not in serialized and "extensions/mattpocock-skills" not in serialized
    assert "query" not in serialized and "input" not in serialized


def test_four_quadrant_clarification_and_experiment_contract() -> None:
    request = {
        "schema": REQUEST_SCHEMA,
        "taskClass": "engineering",
        "semanticSignals": ["challenge_assumptions", "testing"],
        "materialUnknown": True,
        "clarificationRequired": True,
        "sharedUnknown": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    receipt, code = resolve_execution_assist(ROOT, _intent("design_evaluate"), request)

    assert code == "H7_EXECUTION_ASSIST_REQUEST_CURRENT"
    assert receipt is not None and receipt["state"] == "clarification_required"
    assert receipt["questionBudget"] == 3
    assert receipt["capabilityRouteReceipt"]["state"] == "withheld"
    experiment = receipt["minimalExperiment"]
    assert experiment == {
        "required": True,
        "singleVariableRequired": True,
        "successSignalRequired": True,
        "failureSignalRequired": True,
        "evidenceRequired": True,
    }


def test_non_material_clarification_is_rejected() -> None:
    invalid = {
        "schema": REQUEST_SCHEMA,
        "taskClass": "general",
        "semanticSignals": [],
        "materialUnknown": False,
        "clarificationRequired": True,
        "sharedUnknown": False,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    receipt, code = resolve_execution_assist(ROOT, _intent("direct"), invalid)

    assert receipt is None
    assert code == "H7_EXECUTION_ASSIST_CLARIFICATION_MATERIALITY_INVALID"


def test_apply_phase_defers_and_reactivates_native_capabilities() -> None:
    planning, _ = resolve_execution_assist(ROOT, _intent("design_evaluate"), apply_phase="planning")
    execution, _ = resolve_execution_assist(ROOT, _intent("design_evaluate"), apply_phase="execution")
    verification, _ = resolve_execution_assist(ROOT, _intent("design_evaluate"), apply_phase="verification")

    assert planning is not None and execution is not None and verification is not None
    capability_id = "sb.native.mattpocock.codebase-design.v1"
    assert capability_id in planning["capabilityApplyPresentation"]["activeNativeCapabilityIds"]
    assert capability_id in execution["capabilityApplyPresentation"]["deferredNativeCapabilityIds"]
    assert capability_id in verification["capabilityApplyPresentation"]["activeNativeCapabilityIds"]
    assert execution["capabilityRouteReceipt"] == planning["capabilityRouteReceipt"]
    assert execution["capabilityApplyPresentation"]["nonAuthorizing"] is True


def test_invalid_apply_phase_fails_closed() -> None:
    receipt, code = resolve_execution_assist(ROOT, _intent("design_evaluate"), apply_phase="publish")
    assert receipt is None
    assert code == "H7_EXECUTION_ASSIST_APPLY_PHASE_INVALID"


def test_warm_route_p95_is_under_25ms() -> None:
    resolve_execution_assist(ROOT, _intent("design_evaluate"))
    durations: list[float] = []
    for _ in range(160):
        start = time.perf_counter()
        receipt, _ = resolve_execution_assist(ROOT, _intent("design_evaluate"))
        durations.append(time.perf_counter() - start)
        assert receipt is not None
    p95 = sorted(durations)[int(len(durations) * 0.95) - 1]
    assert p95 < 0.025, p95


def main() -> None:
    test_default_engineering_route_is_native_and_private()
    test_four_quadrant_clarification_and_experiment_contract()
    test_non_material_clarification_is_rejected()
    test_apply_phase_defers_and_reactivates_native_capabilities()
    test_invalid_apply_phase_fails_closed()
    test_warm_route_p95_is_under_25ms()
    print("runtime_execution_assist_regression: PASS")


if __name__ == "__main__":
    main()
