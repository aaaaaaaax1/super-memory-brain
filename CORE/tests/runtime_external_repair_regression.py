from __future__ import annotations

import ast
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import external_repair


def test_external_controller_isolation() -> None:
    source = (ROOT / "scripts" / "external_repair.py").read_text(encoding="utf-8")
    tree = ast.parse(source)
    forbidden = {
        "brain_core",
        "turn_runtime",
        "brain_mcp",
        "execution_assist",
        "project_knowledge",
        "turn_close_dispatcher",
        "continuation_policy",
    }
    imported: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    assert not imported.intersection(forbidden), imported

    inspected = external_repair.inspect_package(ROOT)
    assert inspected["schema"] == external_repair.SCHEMA
    assert inspected["authority"]["h7Called"] is False
    assert inspected["authority"]["memoryRead"] is False
    assert inspected["authority"]["taskStateWrite"] is False
    assert inspected["authority"]["capabilityRoute"] is False
    assert inspected["authority"]["projectKnowledge"] is False
    assert len(inspected["payloadHash"]) == 64


def test_delivery_profiles_are_bounded_and_scope_aware() -> None:
    assert external_repair.classify_scope(["ui/config.json"]) == "rapid"
    assert external_repair.classify_scope(["runtime/execution_assist.py"]) == "standard"
    assert external_repair.classify_scope(["runtime/turn_runtime.py"]) == "critical"
    assert external_repair.classify_scope(["super-brain-rules.json"]) == "critical"

    rapid = external_repair.plan_delivery(ROOT, ["ui/config.json"])
    critical = external_repair.plan_delivery(ROOT, ["runtime/turn_runtime.py"])
    assert rapid["mode"] == "rapid"
    assert rapid["profile"]["artifactTargetMinutes"] == 15
    assert rapid["profile"]["failureLimit"] == 2
    assert critical["mode"] == "critical"
    assert critical["authority"]["h7Called"] is False


def test_allow_list_rejects_arbitrary_commands() -> None:
    try:
        external_repair.run_verification(ROOT, mode="rapid", tests=["python -c evil"])
    except ValueError as exc:
        assert "allow-listed" in str(exc)
    else:
        raise AssertionError("external repair accepted an arbitrary command")


def main() -> int:
    test_external_controller_isolation()
    test_delivery_profiles_are_bounded_and_scope_aware()
    test_allow_list_rejects_arbitrary_commands()
    print("EXTERNAL_REPAIR_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
