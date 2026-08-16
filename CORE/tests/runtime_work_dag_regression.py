from __future__ import annotations

import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from work_dag import DEFINITION_SCHEMA, normalize_definition, project_state, seed_or_refresh


def _contract(*, revision: int = 7, fingerprint: str = "a" * 16, statuses: tuple[str, ...] = ("completed", "in_progress", "pending")) -> dict[str, object]:
    return {
        "ok": True,
        "taskId": "task-dag-regression",
        "taskInstanceId": "ti-" + "a" * 32,
        "workspaceKey": "ws-" + "b" * 24,
        "ownerSessionKey": "sid-" + "c" * 24,
        "revision": revision,
        "planReceipt": {"planFingerprint": fingerprint},
        "canonicalPlan": {
            "items": [
                {"itemId": "node-a", "label": "A", "status": statuses[0], "ordinal": 1},
                {"itemId": "node-b", "label": "B", "status": statuses[1], "ordinal": 2},
                {"itemId": "node-c", "label": "C", "status": statuses[2], "ordinal": 3},
            ]
        },
    }


def _definition() -> dict[str, object]:
    return {
        "schema": DEFINITION_SCHEMA,
        "nodes": [
            {"nodeId": "node-a", "dependsOn": []},
            {"nodeId": "node-b", "dependsOn": ["node-a"]},
            {"nodeId": "node-c", "dependsOn": ["node-a"]},
        ],
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def test_dependency_projection_uses_contract_status_without_worker_state() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        state_path = Path(temporary) / "work-dag.json"
        seeded = seed_or_refresh(state_path=state_path, contract=_contract(), action="seed", definition=_definition())
        assert seeded["ok"] is True and seeded["code"] == "H7_WORK_DAG_SEEDED"
        projection = seeded["projection"]
        assert projection["activeNodeIds"] == ["node-b"]
        assert projection["readyNodeIds"] == ["node-c"]
        assert projection["backgroundWorkers"] is False
        assert projection["nonAuthorizing"] is True
        assert all("status" not in node or node["status"] in {"completed", "in_progress", "pending"} for node in projection["nodes"])


def test_cycle_and_coverage_fail_closed() -> None:
    malformed = _definition()
    malformed["nodes"] = [
        {"nodeId": "node-a", "dependsOn": ["node-b"]},
        {"nodeId": "node-b", "dependsOn": ["node-a"]},
        {"nodeId": "node-c", "dependsOn": []},
    ]
    normalized, code = normalize_definition(malformed, _contract())
    assert normalized is None
    assert code == "H7_WORK_DAG_DEFINITION_CYCLE_OR_COVERAGE_INVALID"


def test_stale_contract_binding_requires_explicit_refresh_cas() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        state_path = Path(temporary) / "work-dag.json"
        first = _contract()
        seeded = seed_or_refresh(state_path=state_path, contract=first, action="seed", definition=_definition())
        assert seeded["ok"] is True
        changed = _contract(revision=8, fingerprint="b" * 16, statuses=("completed", "completed", "pending"))
        stale_projection, current = project_state(json.loads(state_path.read_text(encoding="utf-8")), changed)
        assert current is False
        assert stale_projection["code"] == "H7_WORK_DAG_H7_BINDING_STALE"
        wrong = seed_or_refresh(
            state_path=state_path,
            contract=changed,
            action="refresh",
            definition=_definition(),
            expected_dag_revision=0,
        )
        assert wrong["ok"] is False and wrong["code"] == "H7_WORK_DAG_CAS_MISMATCH"
        refreshed = seed_or_refresh(
            state_path=state_path,
            contract=changed,
            action="refresh",
            definition=_definition(),
            expected_dag_revision=1,
        )
        assert refreshed["ok"] is True and refreshed["projection"]["readyNodeIds"] == ["node-c"]


def test_refresh_without_definition_preserves_existing_custom_graph() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        state_path = Path(temporary) / "work-dag.json"
        custom = _definition()
        custom["nodes"] = [
            {"nodeId": "node-a", "dependsOn": []},
            {"nodeId": "node-b", "dependsOn": ["node-a"]},
            {"nodeId": "node-c", "dependsOn": ["node-a"]},
        ]
        seeded = seed_or_refresh(state_path=state_path, contract=_contract(), action="seed", definition=custom)
        assert seeded["ok"] is True
        changed = _contract(revision=8, fingerprint="b" * 16, statuses=("completed", "completed", "pending"))
        refreshed = seed_or_refresh(
            state_path=state_path,
            contract=changed,
            action="refresh",
            expected_dag_revision=1,
        )
        assert refreshed["ok"] is True
        node_c = next(node for node in refreshed["projection"]["nodes"] if node["nodeId"] == "node-c")
        assert node_c["dependsOn"] == ["node-a"]
        assert refreshed["projection"]["readyNodeIds"] == ["node-c"]


def test_refresh_requires_explicit_definition_when_plan_nodes_change() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        state_path = Path(temporary) / "work-dag.json"
        seeded = seed_or_refresh(state_path=state_path, contract=_contract(), action="seed", definition=_definition())
        assert seeded["ok"] is True
        changed = _contract(revision=8, fingerprint="b" * 16)
        changed["canonicalPlan"] = {
            "items": [
                {"itemId": "node-a", "label": "A", "status": "completed", "ordinal": 1},
                {"itemId": "node-b", "label": "B", "status": "pending", "ordinal": 2},
                {"itemId": "node-d", "label": "D", "status": "pending", "ordinal": 3},
            ]
        }
        rejected = seed_or_refresh(
            state_path=state_path,
            contract=changed,
            action="refresh",
            expected_dag_revision=1,
        )
        assert rejected["ok"] is False
        assert rejected["code"] == "H7_WORK_DAG_REFRESH_DEFINITION_REQUIRED"


def _run_powershell(arguments: list[str]) -> dict[str, object]:
    command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", *arguments]
    completed = subprocess.run(command, cwd=str(ROOT), text=True, capture_output=True, check=False)
    text = completed.stdout.strip()
    assert text, completed.stderr
    value = json.loads(text)
    value["_exit"] = completed.returncode
    return value


def test_powershell_wrapper_binds_real_execution_contract() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        state_root = Path(temporary) / "state"
        state_root.mkdir()
        contract_script = ROOT / "scripts" / "execution-contract.ps1"
        work_dag_script = ROOT / "scripts" / "work-dag.ps1"
        task_id = "task-work-dag-wrapper"
        workspace = "ws-" + "d" * 24
        session = "sid-" + "e" * 24
        created = _run_powershell(
            [
                str(contract_script),
                "-Action",
                "Set",
                "-TaskId",
                task_id,
                "-WorkspaceKey",
                workspace,
                "-SessionKey",
                session,
                "-FocusId",
                "main",
                "-FocusLabel",
                "main",
                "-InstructionMode",
                "continue",
                "-LatestUserInstruction",
                "approved dag regression",
                "-NextAction",
                "A",
                "-PendingSteps",
                "A,B,C",
                "-EnableCanonicalPlan",
                "-RequireStructuralGuards",
                "-StateRoot",
                str(state_root),
                "-Json",
            ]
        )
        assert created["ok"] is True
        seeded = _run_powershell(
            [
                str(work_dag_script),
                "-Action",
                "Seed",
                "-TaskId",
                task_id,
                "-WorkspaceKey",
                workspace,
                "-SessionKey",
                session,
                "-StateRoot",
                str(state_root),
                "-Json",
            ]
        )
        assert seeded["ok"] is True and seeded["projection"]["readyNodeIds"]
        assert seeded["backgroundWorkers"] is False
        updated = _run_powershell(
            [
                str(contract_script),
                "-Action",
                "Set",
                "-TaskId",
                task_id,
                "-WorkspaceKey",
                workspace,
                "-SessionKey",
                session,
                "-NextAction",
                "A refreshed",
                "-ExpectedRevision",
                str(created["revision"]),
                "-ExpectedPlanFingerprint",
                str(created["planReceipt"]["planFingerprint"]),
                "-TransitionId",
                "dag-wrapper-contract-change",
                "-StateRoot",
                str(state_root),
                "-Json",
            ]
        )
        assert updated["ok"] is True
        stale = _run_powershell(
            [
                str(work_dag_script),
                "-Action",
                "Get",
                "-TaskId",
                task_id,
                "-WorkspaceKey",
                workspace,
                "-SessionKey",
                session,
                "-StateRoot",
                str(state_root),
                "-Json",
            ]
        )
        assert stale["ok"] is False and stale["code"] == "H7_WORK_DAG_H7_BINDING_STALE"
        refreshed = _run_powershell(
            [
                str(work_dag_script),
                "-Action",
                "Refresh",
                "-TaskId",
                task_id,
                "-WorkspaceKey",
                workspace,
                "-SessionKey",
                session,
                "-ExpectedDagRevision",
                "1",
                "-StateRoot",
                str(state_root),
                "-Json",
            ]
        )
        assert refreshed["ok"] is True and refreshed["projection"]["state"] == "current"


def test_powershell_wrapper_uses_compact_contract_transport() -> None:
    script = (ROOT / "scripts" / "work-dag.ps1").read_text(encoding="utf-8")
    assert "ConvertTo-WorkDagContractView" in script
    assert "$dagContract = ConvertTo-WorkDagContractView -Contract $contract" in script
    assert "$contractJson = $dagContract | ConvertTo-Json -Depth 8 -Compress" in script
    assert "$contractJson = $contract | ConvertTo-Json -Depth 32 -Compress" not in script


def main() -> None:
    test_dependency_projection_uses_contract_status_without_worker_state()
    test_cycle_and_coverage_fail_closed()
    test_stale_contract_binding_requires_explicit_refresh_cas()
    test_refresh_without_definition_preserves_existing_custom_graph()
    test_refresh_requires_explicit_definition_when_plan_nodes_change()
    test_powershell_wrapper_binds_real_execution_contract()
    test_powershell_wrapper_uses_compact_contract_transport()
    print("runtime_work_dag_regression: PASS")


if __name__ == "__main__":
    main()
