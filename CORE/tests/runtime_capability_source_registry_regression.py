from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from execution_assist import resolve_execution_assist
from capability_shadow_eval import generate_shadow_evaluation, write_shadow_evaluation


def _intent() -> dict[str, object]:
    return {"kind": "design_evaluate", "governed": True, "executionAssistRequired": True}


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _source_manifest(source_id: str, skill_name: str) -> dict[str, object]:
    contract_id = f"sb.native.{source_id}.engineering.v1"
    return {
        "id": source_id,
        "type": "absorbed-capability-source",
        "sourceRepo": f"https://example.invalid/{source_id}",
        "sourceCommit": "a" * 40,
        "license": "MIT",
        "sourceUse": "provenance_cold_reference_only",
        "nativeBehaviorContracts": [
            {
                "schema": "super-brain.native-capability-contract.v1",
                "id": contract_id,
                "entry": "evidence_first_engineering_loop",
                "executionOwner": "super-memory-brain",
                "sourceUse": "provenance_cold_reference_only",
                "requiredReceipts": ["current_project_evidence"],
                "verification": ["focused_verification"],
            }
        ],
        "nativeBehaviorContractByCategory": {"engineering": contract_id},
        "nativeParityBySkill": {
            skill_name: {
                "schema": "super-brain.native-capability-parity.v1",
                "procedureId": f"sb.native.{source_id}.procedure.v1",
                "sourceOutcomes": ["source outcome"],
                "nativeOutcomes": ["native outcome"],
                "enhancements": ["H7 remains authoritative"],
                "acceptance": ["focused verification"],
            }
        },
        "skills": [
            {
                "name": skill_name,
                "category": "engineering",
                "semanticTags": ["engineering_design"],
                "applyAt": ["planning", "verification"],
                "routeEligibility": "auto",
            }
        ],
    }


def _write_shadow_fixture(package: Path, contract_ids: list[str]) -> None:
    _write_json(
        package / "capability-shadow-fixtures.json",
        {
            "schema": "super-brain.capability-shadow-fixtures.v1",
            "fixtureVersion": 1,
            "cases": [
                {
                    "caseId": f"source-{index}",
                    "contractId": contract_id,
                    "queryTokens": [f"source{index}", "engineering", "evidence"],
                    "requiredChecks": ["source_cold_only", "native_owner", "receipts", "verification"],
                }
                for index, contract_id in enumerate(contract_ids, start=1)
            ],
            "unknownQueryTokens": ["unmatched", "no-such-capability"],
        },
    )


def _prepare_shadow_binding(package: Path, contract_ids: list[str]) -> None:
    _write_json(package / "manifest.json", {"version": "fixture"})
    for name in ("capability_shadow_eval.py", "capability_source_registry.py", "execution_assist.py"):
        target = package / "runtime" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "runtime" / name, target)
    _write_shadow_fixture(package, contract_ids)
    evaluation, code = generate_shadow_evaluation(package)
    assert evaluation is not None and code == "H7_CAPABILITY_SHADOW_EVALUATION_CURRENT", code
    write_shadow_evaluation(package, evaluation)


def test_multiple_sources_share_one_private_native_route() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        package = Path(temporary)
        _write_json(
            package / "agent-asset-registry.json",
            json.loads((ROOT / "agent-asset-registry.json").read_text(encoding="utf-8")),
        )
        _write_json(
            package / "capability-source-registry.json",
            {
                "schema": "super-brain.capability-source-registry.v1",
                "registryVersion": 1,
                "sources": [
                    {
                        "sourceId": "source-a",
                        "manifestPath": "extensions/source-a/extension.json",
                        "capabilityNamespace": "sourcea",
                        "required": True,
                    },
                    {
                        "sourceId": "source-b",
                        "manifestPath": "extensions/source-b/extension.json",
                        "capabilityNamespace": "sourceb",
                        "required": True,
                    },
                ],
            },
        )
        _write_json(package / "extensions" / "source-a" / "extension.json", _source_manifest("source-a", "design-a"))
        _write_json(package / "extensions" / "source-b" / "extension.json", _source_manifest("source-b", "design-b"))
        _prepare_shadow_binding(
            package,
            ["sb.native.source-a.engineering.v1", "sb.native.source-b.engineering.v1"],
        )

        receipt, code = resolve_execution_assist(package, _intent())

        assert code == "H7_EXECUTION_ASSIST_DEFAULTED"
        assert receipt is not None and receipt["state"] == "ready"
        route = receipt["capabilityRouteReceipt"]
        assert route["selectedNativeCapabilityIds"] == [
            "sb.native.sourcea.design-a.v1",
            "sb.native.sourceb.design-b.v1",
        ]
        serialized = json.dumps(receipt, ensure_ascii=False)
        assert "source-a/extension.json" not in serialized
        assert "source-b/extension.json" not in serialized
        assert '"sourcePath"' not in serialized

        (package / "capability-shadow-evaluation.json").unlink()
        withheld, withheld_code = resolve_execution_assist(package, _intent())
        assert withheld_code == "H7_EXECUTION_ASSIST_DEFAULTED"
        assert withheld is not None and withheld["state"] == "ready"
        assert withheld["capabilityRouteReceipt"]["state"] == "withheld"
        assert withheld["capabilityRouteReceipt"]["code"] == "CAPABILITY_ROUTE_EVALUATION_WITHHELD"
        assert withheld["capabilityRouteReceipt"]["selectedNativeCapabilityIds"] == []
        assert withheld["capabilityApplyPresentation"]["activeNativeCapabilityIds"] == []


def test_registry_rejects_escape_path_before_routing() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        package = Path(temporary)
        _write_json(
            package / "capability-source-registry.json",
            {
                "schema": "super-brain.capability-source-registry.v1",
                "registryVersion": 1,
                "sources": [
                    {
                        "sourceId": "source-a",
                        "manifestPath": "../outside/extension.json",
                        "capabilityNamespace": "sourcea",
                        "required": True,
                    }
                ],
            },
        )

        receipt, code = resolve_execution_assist(package, _intent())

        assert receipt is None
        assert code == "H7_EXECUTION_ASSIST_CAPABILITY_REGISTRY_INVALID"


def test_hot_path_has_no_source_specific_manifest_literal() -> None:
    source = (ROOT / "runtime" / "execution_assist.py").read_text(encoding="utf-8")
    assert "mattpocock-skills" not in source


def main() -> None:
    test_multiple_sources_share_one_private_native_route()
    test_registry_rejects_escape_path_before_routing()
    test_hot_path_has_no_source_specific_manifest_literal()
    print("runtime_capability_source_registry_regression: PASS")


if __name__ == "__main__":
    main()
