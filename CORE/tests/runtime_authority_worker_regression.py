from __future__ import annotations

import os
import subprocess
import tempfile
import time
from pathlib import Path
from unittest import mock

import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

import turn_close_dispatcher as dispatcher


def test_worker_is_disabled_for_one_shot_cli_calls() -> None:
    previous = os.environ.pop("SUPER_BRAIN_MCP_TRANSPORT", None)
    try:
        dispatcher._shutdown_authority_channel()
        assert dispatcher._invoke_warm_authority(ROOT, ["-Action", "Get"], 1.0) is None
        assert dispatcher._AUTHORITY_CHANNEL is None
    finally:
        if previous is not None:
            os.environ["SUPER_BRAIN_MCP_TRANSPORT"] = previous


def test_registered_mcp_reuses_one_bounded_authority_process() -> None:
    previous = os.environ.get("SUPER_BRAIN_MCP_TRANSPORT")
    os.environ["SUPER_BRAIN_MCP_TRANSPORT"] = "codex_registered_v1"
    try:
        dispatcher._shutdown_authority_channel()
        with tempfile.TemporaryDirectory(prefix="super-brain-authority-worker-") as directory:
            state_root = Path(directory) / "state"
            arguments = {
                "package_root": ROOT,
                "state_root": state_root,
                "action": "Get",
                "task_id": "",
                "workspace_key": "ws-" + "a" * 24,
                "session_key": "sid-" + "b" * 24,
                "timeout": 12.0,
            }
            first_code, first = dispatcher._invoke_contract(**arguments)
            second_code, second = dispatcher._invoke_contract(**arguments)
            assert first_code == 0 and second_code == 0
            assert first == second
            assert isinstance(first, dict) and first.get("code") == "EXECUTION_CONTRACT_NOT_FOUND"
            channel = dispatcher._AUTHORITY_CHANNEL
            assert channel is not None and channel._process is not None and channel._process.poll() is None
    finally:
        dispatcher._shutdown_authority_channel()
        if previous is None:
            os.environ.pop("SUPER_BRAIN_MCP_TRANSPORT", None)
        else:
            os.environ["SUPER_BRAIN_MCP_TRANSPORT"] = previous


def test_worker_protocol_and_idle_reaper_are_fail_closed() -> None:
    marker = dispatcher._AUTHORITY_WORKER_MARKER + "0000000000000001:"
    assert dispatcher._parse_worker_marker(marker + "0", marker) == 0
    assert dispatcher._parse_worker_marker(marker + "1", marker) == 1
    assert dispatcher._parse_worker_marker(marker + "2", marker) is None
    assert dispatcher._parse_worker_marker(marker + "garbage", marker) is None

    previous_transport = os.environ.get("SUPER_BRAIN_MCP_TRANSPORT")
    previous_idle = dispatcher._AUTHORITY_WORKER_IDLE_SECONDS
    os.environ["SUPER_BRAIN_MCP_TRANSPORT"] = "codex_registered_v1"
    dispatcher._AUTHORITY_WORKER_IDLE_SECONDS = 0.05
    try:
        dispatcher._shutdown_authority_channel()
        with tempfile.TemporaryDirectory(prefix="super-brain-authority-worker-idle-") as directory:
            state_root = Path(directory) / "state"
            code, result = dispatcher._invoke_contract(
                ROOT,
                state_root,
                action="Get",
                task_id="",
                workspace_key="ws-" + "c" * 24,
                session_key="sid-" + "d" * 24,
                timeout=12.0,
            )
            assert code == 0 and isinstance(result, dict)
            channel = dispatcher._AUTHORITY_CHANNEL
            assert channel is not None and channel._process is not None
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and channel._process is not None:
                time.sleep(0.05)
            assert channel._process is None or channel._process.poll() is not None
            deadline = time.monotonic() + 2.0
            while time.monotonic() < deadline and channel._reaper is not None and channel._reaper.is_alive():
                time.sleep(0.05)
            assert channel._reaper is None or not channel._reaper.is_alive()
    finally:
        dispatcher._shutdown_authority_channel()
        dispatcher._AUTHORITY_WORKER_IDLE_SECONDS = previous_idle
        if previous_transport is None:
            os.environ.pop("SUPER_BRAIN_MCP_TRANSPORT", None)
        else:
            os.environ["SUPER_BRAIN_MCP_TRANSPORT"] = previous_transport


def test_malformed_warm_payload_falls_back_to_cold_authority() -> None:
    completed = subprocess.CompletedProcess(
        args=["powershell.exe"],
        returncode=0,
        stdout='{"ok":true,"code":"COLD_AUTHORITY"}',
        stderr="",
    )
    with mock.patch.object(dispatcher, "_invoke_warm_authority", return_value=(1, "transport failure")):
        with mock.patch.object(dispatcher.subprocess, "run", return_value=completed) as cold_run:
            code, result = dispatcher._invoke_contract(
                ROOT,
                ROOT / "test-state",
                action="Get",
                task_id="",
                workspace_key="ws-" + "e" * 24,
                session_key="sid-" + "f" * 24,
                timeout=1.0,
            )
    assert code == 0 and result == {"ok": True, "code": "COLD_AUTHORITY"}
    cold_run.assert_called_once()


def test_failed_worker_start_does_not_create_reaper() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-authority-worker-missing-") as directory:
        channel = dispatcher._AuthorityWorker(Path(directory))
        try:
            assert channel.invoke(["-Action", "Get"], 0.25) is None
            assert channel._reaper is None
        finally:
            channel.shutdown()


def test_worker_that_exits_during_start_does_not_create_reaper() -> None:
    dead_process = mock.Mock()
    dead_process.pid = 0
    dead_process.poll.return_value = 1
    dead_process.stdin = None
    dead_process.stdout = None
    dead_process.stderr = None
    with tempfile.TemporaryDirectory(prefix="super-brain-authority-worker-exit-") as directory:
        channel = dispatcher._AuthorityWorker(ROOT)
        try:
            with mock.patch.object(dispatcher.subprocess, "Popen", return_value=dead_process):
                assert channel.invoke(["-Action", "Get"], 0.25) is None
            assert channel._reaper is None
        finally:
            channel.shutdown()


def main() -> None:
    test_worker_is_disabled_for_one_shot_cli_calls()
    test_registered_mcp_reuses_one_bounded_authority_process()
    test_worker_protocol_and_idle_reaper_are_fail_closed()
    test_malformed_warm_payload_falls_back_to_cold_authority()
    test_failed_worker_start_does_not_create_reaper()
    test_worker_that_exits_during_start_does_not_create_reaper()
    print("runtime authority worker regression: PASS")


if __name__ == "__main__":
    main()
