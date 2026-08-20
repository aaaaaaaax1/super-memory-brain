from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from core_rule_registry import REQUIRED_RULE_IDS, canonical_hash, load_registry, public_projection


def clone(value: object) -> object:
    return json.loads(json.dumps(value, ensure_ascii=False))


def sign(value: dict[str, object]) -> dict[str, object]:
    result = clone(value)
    assert isinstance(result, dict)
    result["payloadHash"] = canonical_hash({key: item for key, item in result.items() if key != "payloadHash"})
    return result


def write_fixture(root: Path, registry: dict[str, object] | bytes, manifest: dict[str, object]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8", newline="\n")
    path = root / "super-brain-rules.json"
    if isinstance(registry, bytes):
        path.write_bytes(registry)
    else:
        path.write_text(json.dumps(registry, ensure_ascii=False), encoding="utf-8", newline="\n")


def assert_local_only_contract() -> None:
    """Keep docs, manifest, and runtime aligned with Host transport retirement."""

    skill = (ROOT / "super-memory-brain" / "SKILL.md").read_text(encoding="utf-8")
    recovery = (ROOT / "references" / "status-recovery.md").read_text(encoding="utf-8")
    turn_runtime = (ROOT / "runtime" / "turn_runtime.py").read_text(encoding="utf-8")
    brain_core = (ROOT / "runtime" / "brain_core.py").read_text(encoding="utf-8")
    brain_mcp = (ROOT / "runtime" / "brain_mcp.py").read_text(encoding="utf-8")
    brain_cli = (ROOT / "runtime" / "brain_cli.py").read_text(encoding="utf-8")
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))

    for marker in (
        "Host transport is permanently retired",
        "local cwd/session scope",
        "H7_HOST_TRANSPORT_RETIRED",
        "local_contract_current",
        "`SUPER_BRAIN_LOCAL_SESSION_ID`",
        "same H7 CLI",
        "never reads, waits for, retries, or persists Host",
    ):
        assert marker in skill, marker
    for marker in ("Host transport is permanently retired", "local cwd/session scope", "H7_HOST_TRANSPORT_RETIRED"):
        assert marker in recovery, marker

    assert "H7_LOCAL_CONTRACT_RECOVERY_CURRENT" in turn_runtime
    assert '"local_contract_current"' in turn_runtime
    assert "SUPER_BRAIN_LOCAL_SESSION_ID" in brain_core
    assert "H7_HOST_TRANSPORT_RETIRED" in brain_mcp
    assert "current local cwd/session scope" in brain_mcp
    assert "host_continuation_bridge" not in brain_mcp
    assert "read_thread" not in brain_mcp
    assert "allow_direct_assertion" not in brain_cli
    assert "SUPER_BRAIN_REQUIRE_HOST_TAIL" not in brain_cli
    assert "H7_EXTERNAL_CONTINUATION_STATE_FORBIDDEN" in turn_runtime
    assert "from continuation_capsule import" not in turn_runtime
    assert "H7_CONTINUATION_CAPSULE_" not in turn_runtime
    assert not (ROOT / "runtime" / "continuation_capsule.py").exists()
    assert '"continuation_capsule": {' not in brain_mcp
    assert "continuation-capsule" not in brain_cli

    native = {str(item).replace("/", "\\") for item in manifest.get("nativeRuntimeFiles", [])}
    assert "runtime\\host_visible_tail.py" not in native
    assert "runtime\\host_continuation_bridge.py" not in native
    assert not (ROOT / "runtime" / "host_visible_tail.py").exists()
    assert not (ROOT / "runtime" / "host_continuation_bridge.py").exists()


def assert_current_rule_contract(current: dict[str, object], source: dict[str, object]) -> None:
    assert current["status"] == "current", current
    assert current["code"] == "CORE_RULE_REGISTRY_CURRENT", current
    assert {rule["ruleId"] for rule in current["rules"]} == set(REQUIRED_RULE_IDS), current
    assert current["payloadHash"] == canonical_hash({key: value for key, value in source.items() if key != "payloadHash"})
    assert current["registryVersion"] == source["registryVersion"]
    rules = {str(rule["ruleId"]): rule for rule in current["rules"]}

    local_effect_markers = {
        "SB-DEFECT-ROOT-REPAIR-001": (7, "current_local_cwd_session_contract", "never_use_host_tail"),
        "SB-LATEST-STATE-001": (34, "current_local_cwd_super_brain_local_session", "host_transport_retired"),
        "SB-VISIBLE-PROGRESS-ANCHOR-001": (30, "retire_host_visible_context_tail", "h7_host_transport_retired"),
        "SB-CONTROL-PLANE-MAINTAINABILITY-001": (13, "local_only_continuation_control_plane", "permanently_remove_host"),
        "SB-PROGRESS-TRUTH-001": (18, "current_local_cwd_super_brain_local_session", "reject_every_host_locator"),
        "SB-STAGE-VERIFY-001": (6, "local_progress_hash", "host_readback"),
        "SB-EFFICIENT-DELIVERY-001": (7, "local_only_hot_path", "reject_legacy_host_inputs_before_decode"),
        "SB-H7-ACTIVATION-001": (10, "verified_local_cwd", "host_transport_retired"),
        "SB-INDEPENDENT-CONTROL-PLANE-AGENT-001": (4, "independent_local_control_plane", "never_consume_or_persist_host"),
        "SB-RUNTIME-ADAPTER-INDEPENDENCE-001": (4, "valid_local_cwd", "host_continuation_binding"),
        "SB-PRIMARY-HOST-ENTRY-001": (5, "local_cwd_super_brain_local_session", "host_transport_retired"),
        "SB-STAGE-USER-RECEIPT-001": (3, "without_host_readback", "host_readback"),
    }
    for rule_id, (revision, *markers) in local_effect_markers.items():
        rule = rules[rule_id]
        assert rule["revision"] == revision, rule
        effect = str(rule["effect"])
        for marker in markers:
            assert marker in effect, (rule_id, marker, effect)

    assert rules["SB-VISIBLE-PROGRESS-ANCHOR-001"]["entrypoint"] == "runtime/turn_runtime.py"
    assert rules["SB-PROGRESS-TRUTH-001"]["entrypoint"] == "runtime/turn_runtime.py"
    assert rules["SB-H7-ACTIVATION-001"]["entrypoint"] == "runtime/turn_runtime.py"
    assert rules["SB-STAGE-VERIFY-001"]["entrypoint"] == "scripts/execution-contract.ps1"
    for rule in current["rules"]:
        assert rule["status"] == "active", rule
        encoded = json.dumps(rule, ensure_ascii=False)
        assert "host_visible_tail.py" not in encoded
        assert "host_continuation_bridge.py" not in encoded


def main() -> int:
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    source = json.loads((ROOT / "super-brain-rules.json").read_text(encoding="utf-8"))
    assert_local_only_contract()
    current = load_registry(ROOT, manifest=manifest)
    assert_current_rule_contract(current, source)

    design = public_projection(current, signals=("design",))
    assert design["applicableRuleIds"] == [
        "SB-PROJECT-GROUNDED-DESIGN-001",
        "SB-FOUR-QUADRANT-EXECUTION-001",
        "SB-PROGRESS-TRUTH-001",
        "SB-ON-DEMAND-PROJECT-KNOWLEDGE-001",
    ], design
    continuation = public_projection(current, signals=("continue",))
    assert continuation["applicableRuleIds"] == [
        "SB-LATEST-STATE-001",
        "SB-VISIBLE-PROGRESS-ANCHOR-001",
        "SB-PROGRESS-TRUTH-001",
        "SB-AUTO-RESUME-001",
        "SB-H7-ACTIVATION-001",
    ], continuation
    stage = public_projection(current, signals=("stage_complete",))
    assert stage["applicableRuleIds"] == [
        "SB-PROGRESS-TRUTH-001",
        "SB-STAGE-VERIFY-001",
        "SB-H7-ACTIVATION-001",
        "SB-STAGE-USER-RECEIPT-001",
    ], stage
    greeting = public_projection(current, signals=("greeting",))
    assert greeting["applicableRuleIds"] == [] and greeting["signalStored"] is False, greeting

    with tempfile.TemporaryDirectory(prefix="super-brain-rule-registry-") as raw:
        fixture = Path(raw) / "package"
        write_fixture(fixture, source, manifest)

        hash_mismatch = clone(source)
        assert isinstance(hash_mismatch, dict)
        assert isinstance(hash_mismatch["rules"], list)
        hash_mismatch["rules"][0]["effect"] = "project_root_evidence_gate_changed"
        write_fixture(fixture, hash_mismatch, manifest)
        assert load_registry(fixture, manifest=manifest)["code"] == "CORE_RULE_REGISTRY_HASH_MISMATCH"

        missing_required = clone(source)
        assert isinstance(missing_required, dict)
        missing_required["rules"] = [
            rule for rule in missing_required["rules"] if rule["ruleId"] != "SB-H7-ACTIVATION-001"
        ]
        write_fixture(fixture, sign(missing_required), manifest)
        assert load_registry(fixture, manifest=manifest)["code"] == "CORE_RULE_REGISTRY_REQUIRED_RULE_MISSING"

        duplicate = clone(source)
        assert isinstance(duplicate, dict)
        duplicate["rules"][1]["ruleId"] = duplicate["rules"][0]["ruleId"]
        write_fixture(fixture, sign(duplicate), manifest)
        assert load_registry(fixture, manifest=manifest)["code"] == "CORE_RULE_REGISTRY_RULE_ID_INVALID"

        wrong_manifest = clone(manifest)
        assert isinstance(wrong_manifest, dict)
        wrong_manifest["coreRuleRegistry"]["path"] = "wrong-rules.json"
        write_fixture(fixture, source, wrong_manifest)
        assert load_registry(fixture, manifest=wrong_manifest)["code"] == "CORE_RULE_REGISTRY_MANIFEST_PATH_MISMATCH"

        write_fixture(fixture, b"\xef\xbb\xbf" + json.dumps(source).encode("utf-8"), manifest)
        assert load_registry(fixture)["code"] == "CORE_RULE_REGISTRY_BOM_FORBIDDEN"
        write_fixture(fixture, b"\xff\xfe\x00", manifest)
        assert load_registry(fixture)["code"] == "CORE_RULE_REGISTRY_UTF8_INVALID"
        write_fixture(fixture, b"{invalid", manifest)
        assert load_registry(fixture)["code"] == "CORE_RULE_REGISTRY_JSON_INVALID"
        (fixture / "super-brain-rules.json").unlink()
        assert load_registry(fixture, manifest=manifest)["code"] == "CORE_RULE_REGISTRY_MISSING"

    print("CORE_RULE_REGISTRY_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
