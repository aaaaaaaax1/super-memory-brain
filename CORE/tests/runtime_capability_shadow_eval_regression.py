from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from capability_shadow_eval import (
    evaluate_capability_shadow,
    generate_shadow_evaluation,
    load_current_evaluation,
    shadow_gate_is_valid,
    write_shadow_evaluation,
)
from capability_source_registry import route_capabilities


def _copy_binding_fixture(destination: Path) -> None:
    for name in (
        "manifest.json",
        "capability-source-registry.json",
        "capability-shadow-fixtures.json",
    ):
        shutil.copy2(ROOT / name, destination / name)
    runtime = destination / "runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    for name in ("capability_shadow_eval.py", "capability_source_registry.py", "execution_assist.py"):
        shutil.copy2(ROOT / "runtime" / name, runtime / name)
    source = destination / "extensions" / "mattpocock-skills"
    source.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "extensions" / "mattpocock-skills" / "extension.json", source / "extension.json")


def test_current_evaluation_is_compact_private_and_gate_ready() -> None:
    evaluation, code = load_current_evaluation(ROOT)
    assert evaluation is not None and code == "H7_CAPABILITY_SHADOW_EVALUATION_CURRENT", code
    assert evaluation["state"] == "passed"
    assert evaluation["metrics"] == {
        "oracleEvidenceRate": 1.0,
        "retrievalRecallAt1": 1.0,
        "retrievalRecallAt3": 1.0,
        "unknownAbstentionRate": 1.0,
        "routeStabilityRate": 1.0,
        "unsupportedActivationCount": 0,
    }
    serialized = json.dumps(evaluation, ensure_ascii=False)
    assert "queryTokens" not in serialized
    assert "requiredChecks" not in serialized
    assert "sourcePath" not in serialized
    privacy_projection = serialized.lower().replace("rawpromptstored", "").replace("rawtranscriptstored", "")
    assert "prompt" not in privacy_projection and "transcript" not in privacy_projection

    route, route_code = route_capabilities(ROOT, {"engineering_design"})
    assert route is not None and route_code == "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_CURRENT"
    gate, gate_code = evaluate_capability_shadow(ROOT, route)
    assert gate_code == "H7_CAPABILITY_SHADOW_CURRENT"
    assert shadow_gate_is_valid(gate)
    assert gate["state"] == "ready" and gate["activationAllowed"] is True


def test_missing_stale_and_tampered_receipts_fail_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-shadow-eval-") as directory:
        package = Path(directory)
        _copy_binding_fixture(package)

        generated, code = generate_shadow_evaluation(package)
        assert generated is not None and code == "H7_CAPABILITY_SHADOW_EVALUATION_CURRENT", code
        before = sorted(path.relative_to(package).as_posix() for path in package.rglob("*") if path.is_file())
        write_shadow_evaluation(package, generated)
        after = sorted(path.relative_to(package).as_posix() for path in package.rglob("*") if path.is_file())
        assert sorted(set(after) - set(before)) == ["capability-shadow-evaluation.json"]
        current, current_code = load_current_evaluation(package)
        assert current is not None and current_code == "H7_CAPABILITY_SHADOW_EVALUATION_CURRENT"

        extension = package / "extensions" / "mattpocock-skills" / "extension.json"
        extension.write_text(extension.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        stale, stale_code = load_current_evaluation(package)
        assert stale is None and stale_code == "H7_CAPABILITY_SHADOW_EVALUATION_STALE"

        _copy_binding_fixture(package)
        regenerated, _ = generate_shadow_evaluation(package)
        assert regenerated is not None
        write_shadow_evaluation(package, regenerated)
        receipt_path = package / "capability-shadow-evaluation.json"
        tampered = json.loads(receipt_path.read_text(encoding="utf-8"))
        tampered["metrics"]["retrievalRecallAt1"] = 0.0
        receipt_path.write_text(json.dumps(tampered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        invalid, invalid_code = load_current_evaluation(package)
        assert invalid is None and invalid_code == "H7_CAPABILITY_SHADOW_EVALUATION_HASH_MISMATCH"


def main() -> None:
    test_current_evaluation_is_compact_private_and_gate_ready()
    test_missing_stale_and_tampered_receipts_fail_closed()
    print("runtime_capability_shadow_eval_regression: PASS")


if __name__ == "__main__":
    main()
