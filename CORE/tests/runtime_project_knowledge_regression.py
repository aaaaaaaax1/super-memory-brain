from __future__ import annotations

import hashlib
import json
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from brain_context import canonical_hash, project_progress_root_hash, validate_project_progress_proof
from project_knowledge import public_projection, resolve_project_knowledge


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _proof(root: Path, files: list[str]) -> dict[str, object]:
    evidence = [
        {"kind": "project_file", "relativePath": relative, "sha256": _sha256(root / relative)}
        for relative in files
    ]
    body: dict[str, object] = {
        "schema": "super-brain.project-progress-proof.v1",
        "state": "current",
        "phase": "Fixture",
        "currentStep": "Inspect the proof-bound slice.",
        "completedItems": [],
        "projectEvidence": evidence,
        "verificationResults": [],
        "nextAction": "Run focused verification.",
        "missing": [],
        "projectRootHash": project_progress_root_hash(root),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def _status(root: Path, proof: dict[str, object]) -> dict[str, object]:
    return validate_project_progress_proof(
        proof,
        project_root=root,
        expected_phase="Fixture",
        expected_current_step="Inspect the proof-bound slice.",
        expected_next_action="Run focused verification.",
        expected_completed_steps=[],
    )


def _route(mode: str = "focused") -> dict[str, object]:
    return {
        "schema": "super-brain.project-knowledge-route.v1",
        "state": "ready",
        "code": "H7_PROJECT_KNOWLEDGE_ROUTE_READY",
        "mode": mode,
        "coverage": "proof_bound_slice",
        "fullTreeScan": False,
        "persistentIndex": False,
        "backgroundWorkers": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
    }


def _ready_route(mode: str = "focused") -> dict[str, object]:
    route = _route(mode)
    route["payloadHash"] = canonical_hash(route)
    return route


def test_proof_bound_slice_parses_local_relations_and_marks_dynamic_unknowns() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-project-knowledge-") as directory:
        root = Path(directory)
        (root / "app").mkdir()
        (root / "app" / "main.py").write_text(
            "from .service import run\nimport importlib\nvalue = importlib.import_module(name)\n",
            encoding="utf-8",
        )
        (root / "app" / "service.py").write_text("def run():\n    return 1\n", encoding="utf-8")
        (root / "settings.json").write_text('{"entry":"./app/main.py"}', encoding="utf-8")
        proof = _proof(root, ["app/main.py", "app/service.py", "settings.json"])
        status = _status(root, proof)
        assert status["current"] is True, status
        result, code = resolve_project_knowledge(
            root,
            project_progress_proof=proof,
            project_progress_status=status,
            route=_ready_route(),
            expected_phase="Fixture",
            expected_current_step="Inspect the proof-bound slice.",
            expected_next_action="Run focused verification.",
        )
        assert code == "H7_PROJECT_KNOWLEDGE_READY" and result is not None, (code, result)
        assert result["state"] == "ready" and result["fullTreeScan"] is False
        assert result["persistentIndex"] is False and result["backgroundWorkers"] is False
        assert {edge["relation"] for edge in result["relations"]} >= {"python_import", "json_local_reference"}
        assert any(edge["to"] == "app/service.py" for edge in result["relations"])
        assert any(item["code"] == "python_dynamic_import" for item in result["unknowns"])
        assert all(str(root).lower() not in json.dumps(item).lower() for item in result["nodes"] + result["relations"])
        public = public_projection(result)
        assert "nodes" not in public and "relations" not in public and public["payloadHash"] == result["payloadHash"]


def test_not_applicable_route_never_requires_a_project_root_or_reads_files() -> None:
    route = _route()
    route["state"] = "not_applicable"
    route["code"] = "H7_PROJECT_KNOWLEDGE_ROUTE_NOT_APPLICABLE"
    route["payloadHash"] = canonical_hash({key: value for key, value in route.items() if key != "payloadHash"})
    result, code = resolve_project_knowledge(
        None,
        project_progress_proof=None,
        project_progress_status=None,
        route=route,
    )
    assert code == "H7_PROJECT_KNOWLEDGE_NOT_APPLICABLE" and result is not None
    assert result["state"] == "not_applicable" and result["filesRead"] == 0


def test_hash_drift_and_path_escape_fail_closed_without_cache_reuse() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-project-knowledge-drift-") as directory:
        root = Path(directory)
        (root / "module.py").write_text("value = 1\n", encoding="utf-8")
        proof = _proof(root, ["module.py"])
        status = _status(root, proof)
        initial, _ = resolve_project_knowledge(
            root,
            project_progress_proof=proof,
            project_progress_status=status,
            route=_ready_route("impact"),
            expected_phase="Fixture",
            expected_current_step="Inspect the proof-bound slice.",
            expected_next_action="Run focused verification.",
        )
        assert initial is not None and initial["state"] == "ready"
        (root / "module.py").write_text("value = 2\n", encoding="utf-8")
        drifted, code = resolve_project_knowledge(
            root,
            project_progress_proof=proof,
            project_progress_status=status,
            route=_ready_route("impact"),
            expected_phase="Fixture",
            expected_current_step="Inspect the proof-bound slice.",
            expected_next_action="Run focused verification.",
        )
        assert drifted is not None and drifted["state"] == "withheld"
        assert code == "H7_PROJECT_KNOWLEDGE_PROOF_RECHECK_FAILED"
        escaped = dict(proof)
        escaped["projectEvidence"] = [{"kind": "project_file", "relativePath": "../outside.py", "sha256": "a" * 64}]
        escaped["payloadHash"] = canonical_hash({key: value for key, value in escaped.items() if key != "payloadHash"})
        escaped_result, _ = resolve_project_knowledge(
            root,
            project_progress_proof=escaped,
            project_progress_status={"state": "current", "current": True},
            route=_ready_route(),
            expected_phase="Fixture",
            expected_current_step="Inspect the proof-bound slice.",
            expected_next_action="Run focused verification.",
        )
        assert escaped_result is not None and escaped_result["state"] == "withheld"


def test_external_symlink_evidence_is_rejected_when_supported() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-project-knowledge-symlink-") as directory:
        base = Path(directory)
        root = base / "root"
        root.mkdir()
        outside = base / "outside.py"
        outside.write_text("value = 1\n", encoding="utf-8")
        link = root / "linked.py"
        try:
            link.symlink_to(outside)
        except OSError:
            return
        proof = _proof(root, ["linked.py"])
        result, _ = resolve_project_knowledge(
            root,
            project_progress_proof=proof,
            project_progress_status={"state": "current", "current": True},
            route=_ready_route(),
            expected_phase="Fixture",
            expected_current_step="Inspect the proof-bound slice.",
            expected_next_action="Run focused verification.",
        )
        assert result is not None and result["state"] == "withheld"


def test_implementation_is_bounded_and_does_not_walk_the_tree() -> None:
    source = (ROOT / "runtime" / "project_knowledge.py").read_text(encoding="utf-8")
    assert ".rglob(" not in source and ".glob(" not in source and "os.walk" not in source
    assert "MAX_FILES = 16" in source and "MAX_HOPS = 1" in source


def main() -> None:
    test_proof_bound_slice_parses_local_relations_and_marks_dynamic_unknowns()
    test_not_applicable_route_never_requires_a_project_root_or_reads_files()
    test_hash_drift_and_path_escape_fail_closed_without_cache_reuse()
    test_external_symlink_evidence_is_rejected_when_supported()
    test_implementation_is_bounded_and_does_not_walk_the_tree()
    print("runtime_project_knowledge_regression: PASS")


if __name__ == "__main__":
    main()
