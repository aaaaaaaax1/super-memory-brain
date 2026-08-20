from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from brain_cli import _mcp_bridge_turn_runtime_args, _retired_host_transport_payload
from brain_mcp import handle_tool
from turn_close_dispatcher import PHASE_CLOSEOUT_RECORD_SCHEMA, create_phase_closeout
from turn_runtime import checkpoint_turn, close_turn, open_turn, run_turn


def payload(result: dict[str, object]) -> dict[str, object]:
    text = result["content"][0]["text"]  # type: ignore[index]
    value = json.loads(str(text))
    assert isinstance(value, dict)
    return value


def test_mcp_host_arguments_are_rejected_before_core_access() -> None:
    for field in ("host_visible_context", "host_thread_payload", "visible_progress_assertion"):
        result = handle_tool(object(), "brain_turn", {field: {}})
        assert result["isError"] is True, result
        value = payload(result)
        assert value["code"] == "H7_HOST_TRANSPORT_RETIRED", value
        assert value["retiredInputs"] == [field], value


def test_cli_host_arguments_are_rejected_before_decoding() -> None:
    args = argparse.Namespace(
        visible_progress_assertion_json="not-json",
        visible_progress_assertion_base64="",
        host_thread_json="",
        host_thread_base64="",
        host_visible_context_json="",
        host_visible_context_base64="",
    )
    result = _retired_host_transport_payload(args)
    assert result is not None
    assert result["code"] == "H7_HOST_TRANSPORT_RETIRED"


def test_stale_cli_bridge_rejects_retired_fields() -> None:
    args, code = _mcp_bridge_turn_runtime_args({"phase": "open", "host_thread_payload": {}})
    assert args is None
    assert code == "H7_HOST_TRANSPORT_RETIRED"


class UnreadableHostPayload(dict[str, object]):
    def __iter__(self):  # type: ignore[no-untyped-def]
        raise AssertionError("retired Host payload was inspected")

    def get(self, *args: object, **kwargs: object) -> object:
        raise AssertionError("retired Host payload was inspected")


def test_direct_turn_entrypoints_reject_all_host_payloads_before_core_access() -> None:
    entrypoints = ((open_turn, "open"), (checkpoint_turn, "checkpoint"), (close_turn, "close"))
    retired_fields = (
        "host_readback_projection",
        "host_thread_payload",
        "host_visible_context",
        "visible_progress_assertion",
    )
    for entrypoint, phase in entrypoints:
        for field in retired_fields:
            result = entrypoint(  # type: ignore[operator]
                object(),  # type: ignore[arg-type]
                **{field: UnreadableHostPayload()},
            )
            assert result["code"] == "H7_HOST_TRANSPORT_RETIRED", result
            assert result["phase"] == phase, result
            assert result["retiredInputs"] == [field], result


def test_run_turn_rejects_host_payloads_before_dispatch_or_type_filtering() -> None:
    retired_fields = (
        "host_readback_projection",
        "host_thread_payload",
        "host_visible_context",
        "visible_progress_assertion",
    )
    for phase in ("open", "checkpoint", "close", "evidence"):
        for field in retired_fields:
            result = run_turn(
                object(),  # type: ignore[arg-type]
                phase=phase,
                **{field: UnreadableHostPayload()},
            )
            assert result["code"] == "H7_HOST_TRANSPORT_RETIRED", result
            assert result["phase"] == phase, result
            assert result["retiredInputs"] == [field], result

    none_result = run_turn(
        object(),  # type: ignore[arg-type]
        phase="invalid",
        **{field: None for field in retired_fields},
    )
    assert none_result["code"] == "TURN_RUNTIME_PHASE_INVALID", none_result


def test_closeout_contract_is_local_v4_and_has_no_host_parameter() -> None:
    import inspect

    signature = inspect.signature(create_phase_closeout)
    assert "host_readback_projection" not in signature.parameters
    assert PHASE_CLOSEOUT_RECORD_SCHEMA == "super-brain.phase-closeout-receipt.v4"
    source = (ROOT / "runtime" / "turn_close_dispatcher.py").read_text(encoding="utf-8")
    assert "phase-closeout-v4" in source
    assert "hostStageReceipt" not in source


def test_host_bridge_is_not_on_active_manifest_or_mcp_hot_path() -> None:
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    native = set(manifest.get("nativeRuntimeFiles", []))
    assert "runtime\\host_visible_tail.py" not in native
    assert "runtime\\host_continuation_bridge.py" not in native
    mcp_source = (ROOT / "runtime" / "brain_mcp.py").read_text(encoding="utf-8")
    assert "host_continuation_bridge" not in mcp_source
    assert "read_thread(" not in mcp_source


def test_require_host_tail_environment_cannot_reactivate_transport() -> None:
    old = os.environ.get("SUPER_BRAIN_REQUIRE_HOST_TAIL")
    os.environ["SUPER_BRAIN_REQUIRE_HOST_TAIL"] = "1"
    try:
        source = (ROOT / "runtime" / "brain_cli.py").read_text(encoding="utf-8")
        assert "SUPER_BRAIN_REQUIRE_HOST_TAIL" not in source
        assert "H7_HOST_TRANSPORT_RETIRED" in source
    finally:
        if old is None:
            os.environ.pop("SUPER_BRAIN_REQUIRE_HOST_TAIL", None)
        else:
            os.environ["SUPER_BRAIN_REQUIRE_HOST_TAIL"] = old


def main() -> int:
    tests = [value for name, value in globals().items() if name.startswith("test_") and callable(value)]
    for test in tests:
        test()
    print(f"host transport retirement regression: {len(tests)} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
