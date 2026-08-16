from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from agent_asset_loadout import resolve_agent_asset_loadout
from execution_assist import resolve_execution_assist


def test_default_loadout_is_controller_owned_and_worker_free() -> None:
    loadout, code = resolve_agent_asset_loadout(
        ROOT,
        task_class="engineering",
        semantic_signals={"engineering_design", "implementation"},
        apply_phase="planning",
    )

    assert code == "H7_AGENT_ASSET_REGISTRY_CURRENT"
    assert loadout is not None and loadout["state"] == "ready"
    assert loadout["dispatchMode"] == "direct"
    assert loadout["selectedAssetIds"] == ["h7-controller", "native-capability-router"]
    assert loadout["backgroundWorkers"] is False
    assert loadout["hostSkillExecution"] is False
    assert loadout["upstreamExecution"] is False
    assert loadout["h7StateAuthority"] is True
    assert loadout["rawPromptStored"] is False and loadout["rawTranscriptStored"] is False


def test_explicit_delegation_only_selects_a_packet_not_a_worker() -> None:
    loadout, code = resolve_agent_asset_loadout(
        ROOT,
        task_class="engineering",
        semantic_signals={"testing"},
        apply_phase="verification",
        delegation_requested=True,
    )

    assert code == "H7_AGENT_ASSET_REGISTRY_CURRENT"
    assert loadout is not None and loadout["state"] == "ready"
    assert "bounded-delegation-packet" in loadout["selectedAssetIds"]
    assert loadout["dispatchMode"] == "single_delegate_requires_explicit_authority"
    assert loadout["backgroundWorkers"] is False
    assert loadout["h7StateAuthority"] is True


def test_invalid_background_worker_policy_fails_closed() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        package = Path(temporary)
        source = json.loads((ROOT / "agent-asset-registry.json").read_text(encoding="utf-8"))
        source["policy"]["backgroundWorkers"] = "allowed"
        (package / "agent-asset-registry.json").write_text(json.dumps(source), encoding="utf-8")

        loadout, code = resolve_agent_asset_loadout(
            package,
            task_class="engineering",
            semantic_signals={"implementation"},
            apply_phase="execution",
        )

        assert loadout is None
        assert code == "H7_AGENT_ASSET_REGISTRY_INVALID"


def test_execution_assist_projects_the_native_loadout_without_paths() -> None:
    receipt, code = resolve_execution_assist(
        ROOT,
        {"kind": "design_evaluate", "governed": True, "executionAssistRequired": True},
    )

    assert code == "H7_EXECUTION_ASSIST_DEFAULTED"
    assert receipt is not None
    loadout = receipt["assetLoadout"]
    assert loadout["state"] == "ready"
    assert "h7-controller" in loadout["selectedAssetIds"]
    assert loadout["backgroundWorkers"] is False
    serialized = json.dumps(receipt, ensure_ascii=False)
    assert '"sourcePath"' not in serialized
    assert "agent-asset-registry.json" not in serialized


def main() -> None:
    test_default_loadout_is_controller_owned_and_worker_free()
    test_explicit_delegation_only_selects_a_packet_not_a_worker()
    test_invalid_background_worker_policy_fails_closed()
    test_execution_assist_projects_the_native_loadout_without_paths()
    print("runtime_agent_asset_loadout_regression: PASS")


if __name__ == "__main__":
    main()
