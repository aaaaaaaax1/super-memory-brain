"""Regression coverage for the public host-neutral local MCP adapter."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from local_scope_adapter import (  # noqa: E402
    ADAPTER_SCHEMA,
    LOCAL_SESSION_ENV,
    LocalScopeAdapterError,
    build_environment,
    build_launch_spec,
    close_process,
    generate_session_id,
    launch,
    validate_session_id,
    verify_startup,
)
from scope_broker_ipc import ScopeBrokerControlClient, ScopeBrokerServer  # noqa: E402


def _integration_helpers():
    # Keep the fixture contract identical to the existing live MCP regression
    # without duplicating H7 contract construction in this adapter test.
    sys.path.insert(0, str(ROOT / "tests"))
    from runtime_mcp_scope_broker_integration_regression import (  # type: ignore
        _send,
        _status_payload,
        _write_live_contract,
    )

    return _send, _status_payload, _write_live_contract


def test_session_ids_are_strict_and_random() -> None:
    first = generate_session_id()
    second = generate_session_id()
    assert first != second
    assert validate_session_id(first) == first
    assert validate_session_id(first.upper()) == first
    assert validate_session_id("sid-short") is None
    assert validate_session_id("legacy-session") is None
    assert validate_session_id("") is None


def test_launch_spec_keeps_scope_in_env_and_cwd_only() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-local-adapter-spec-") as directory:
        root = Path(directory)
        package = root / "package"
        package_runtime = package / "runtime"
        package_runtime.mkdir(parents=True)
        (package_runtime / "local_mcp_launcher.py").write_text("# fixture\n", encoding="utf-8")
        (package_runtime / "brain_mcp.py").write_text("# fixture\n", encoding="utf-8")
        memory = root / "memory"
        workspace = root / "workspace"
        memory.mkdir()
        workspace.mkdir()
        session = "sid-" + "a" * 24
        spec = build_launch_spec(
            package,
            memory,
            workspace,
            session,
            python_executable="python",
            environment_source={
                "PATH": "fixture-path",
                "SystemRoot": "fixture-root",
                "CODEX_THREAD_ID": "must-not-cross",
                "HOST_VISIBLE_CONTEXT": "must-not-cross",
                "SUPER_BRAIN_WORKSPACE_KEY": "must-not-cross",
            },
        )
        assert spec.schema == ADAPTER_SCHEMA
        assert spec.cwd == workspace.resolve()
        assert spec.requires_fresh_process is True
        assert spec.requiresFreshProcess is True
        assert spec.environment[LOCAL_SESSION_ENV] == session
        assert "fixture-path" in spec.environment.values()
        assert session not in " ".join(spec.argv)
        assert session not in repr(spec)
        for forbidden in ("CODEX_THREAD_ID", "HOST_VISIBLE_CONTEXT", "SUPER_BRAIN_WORKSPACE_KEY"):
            assert forbidden not in spec.environment

        try:
            launch(spec, cwd=str(workspace))
        except LocalScopeAdapterError as exc:
            assert exc.code == "H7_SCOPE_ADAPTER_LAUNCH_OVERRIDE_FORBIDDEN"
        else:
            raise AssertionError("launch must not permit cwd override")


def test_invalid_inputs_fail_before_process_start() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-local-adapter-invalid-") as directory:
        root = Path(directory)
        package = root / "package"
        (package / "runtime").mkdir(parents=True)
        (package / "runtime" / "local_mcp_launcher.py").write_text("# fixture\n", encoding="utf-8")
        (package / "runtime" / "brain_mcp.py").write_text("# fixture\n", encoding="utf-8")
        memory = root / "memory"
        workspace = root / "workspace"
        memory.mkdir()
        workspace.mkdir()
        for value in ("", "legacy", "sid-zzzzzzzzzzzzzzzz", "sid-" + "a" * 65):
            try:
                build_launch_spec(package, memory, workspace, value)
            except LocalScopeAdapterError as exc:
                assert exc.code == "H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED"
            else:
                raise AssertionError(f"invalid session accepted: {value!r}")
        try:
            build_launch_spec(package, memory, root / "missing", "sid-" + "b" * 24)
        except LocalScopeAdapterError as exc:
            assert exc.code == "H7_SCOPE_INJECTION_WORKSPACE_INVALID"
        else:
            raise AssertionError("missing workspace accepted")
        try:
            build_launch_spec(package, None, workspace, "sid-" + "b" * 24)  # type: ignore[arg-type]
        except LocalScopeAdapterError as exc:
            assert exc.code == "H7_LOCAL_MCP_LAUNCHER_MEMORY_INVALID"
        else:
            raise AssertionError("missing memory root accepted")
        try:
            build_environment("legacy")
        except LocalScopeAdapterError as exc:
            assert exc.code == "H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED"
        else:
            raise AssertionError("invalid environment session accepted")


def test_injected_user_path_verifies_and_closes_cleanly() -> None:
    send, status_payload, write_live_contract = _integration_helpers()
    with tempfile.TemporaryDirectory(prefix="super-brain-local-adapter-e2e-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        session = "sid-" + "c" * 24
        (state / "workspace").mkdir(parents=True, exist_ok=True)
        write_live_contract(state, project, session, "local-adapter-e2e")
        source = dict(os.environ)
        source.update(
            {
                "CODEX_THREAD_ID": "retired-host-id",
                "HOST_VISIBLE_CONTEXT": "retired-host-context",
                "SUPER_BRAIN_MCP_OFFLINE_REPLAY": "1",
            }
        )
        spec = build_launch_spec(ROOT, memory, project, session, environment_source=source)
        process = launch(spec)
        try:
            initialized = send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            assert verify_startup(initialized), initialized
            handshake_text = json.dumps(initialized, ensure_ascii=False)
            assert session not in handshake_text
            status = status_payload(
                send(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {"name": "brain_status", "arguments": {}},
                    },
                )
            )
            assert status.get("scopeBinding", {}).get("scopeAuthorized") is True, status
        finally:
            exit_code = close_process(process)
            assert exit_code == 0, exit_code


def test_static_launcher_without_sid_is_withheld() -> None:
    send, _status_payload, _write_live_contract = _integration_helpers()
    with tempfile.TemporaryDirectory(prefix="super-brain-local-adapter-static-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        environment = {key: value for key, value in os.environ.items() if key != LOCAL_SESSION_ENV}
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        process = subprocess.Popen(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "local_mcp_launcher.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(memory),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            env=environment,
            cwd=str(project),
        )
        try:
            initialized = send(process, {"jsonrpc": "2.0", "id": 3, "method": "initialize", "params": {}})
            assert not verify_startup(initialized)
            handshake = ((initialized.get("result", {}) or {}).get("liveMcpHandshake", {}) or {})
            assert handshake.get("scopeInjection", {}).get("code") == "H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED", initialized
            assert handshake.get("scope", {}).get("scopeReady") is False, initialized
            listed = control.list_channels()
            assert listed.get("ok") is True and listed.get("channels") == [], listed
        finally:
            assert close_process(process) == 0
            control.close()
            server.stop()


def main() -> None:
    test_session_ids_are_strict_and_random()
    test_launch_spec_keeps_scope_in_env_and_cwd_only()
    test_invalid_inputs_fail_before_process_start()
    test_injected_user_path_verifies_and_closes_cleanly()
    test_static_launcher_without_sid_is_withheld()
    print("runtime_local_scope_adapter_regression: PASS")


if __name__ == "__main__":
    main()
