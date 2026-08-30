"""Real stdio MCP -> local Broker channel integration checks."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

import brain_mcp
from brain_core import BrainCore
from mcp_transport_health import LocalBrokerStdioTransportHealth
from scope_broker import ScopeBroker
from scope_broker_ipc import ScopeBrokerControlClient, ScopeBrokerServer
from scope_provider import BrokerScopeProvider


def _workspace_key(root: Path) -> str:
    normalized = str(root.resolve()).rstrip("/\\").lower()
    return "ws-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24]


def _contract(project: Path, suffix: str) -> dict[str, object]:
    return {
        "schema": "super-brain.execution-contract.v1",
        "status": "active",
        "taskId": "mcp-broker-" + suffix,
        "taskInstanceId": "ti-" + suffix * 32,
        "workspaceKey": _workspace_key(project),
        "ownerSessionKey": "sid-" + suffix * 24,
        "packageVersion": "0.6.0",
        "revision": 1,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _hash(value: dict[str, object]) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _live_mcp_environment() -> dict[str, str]:
    """Ensure this is a real Broker-backed stdio process, never replay."""

    environment = dict(os.environ)
    # Deliberately poison retired deployment variables.  The injected local
    # stdio transport must neither read their binding file nor let them alter
    # its runtime identity/health.
    environment.pop("SUPER_BRAIN_MCP_OFFLINE_REPLAY", None)
    environment["SUPER_BRAIN_PACKAGE_ROOT"] = str(Path(__file__).resolve().parent / "not-the-package")
    environment["SUPER_BRAIN_RUNTIME_IDENTITY"] = "stale-deployment-identity"
    environment["SUPER_BRAIN_MCP_TRANSPORT"] = "codex_registered_v1"
    environment["SUPER_BRAIN_MCP_REGISTRATION_EPOCH"] = "stale-deployment-epoch"
    return environment


def _send(process: subprocess.Popen[str], value: dict[str, object]) -> dict[str, object]:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    process.stdin.flush()
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if line:
            return json.loads(line)
    raise AssertionError("MCP response timeout")


def _status_payload(response: dict[str, object]) -> dict[str, object]:
    result = response.get("result") or {}
    content = result.get("content") if isinstance(result, dict) else None
    assert isinstance(content, list) and content and isinstance(content[0], dict)
    return json.loads(str(content[0]["text"]))


def test_bound_task_layer_uses_the_channel_projection() -> None:
    """Task/session recall must use the bound channel, never generic recall."""

    with tempfile.TemporaryDirectory(prefix="super-brain-broker-task-recall-") as directory:
        state = Path(directory) / "state"
        memory = state / "shared"
        project = Path(directory) / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        contract = _contract(project, "c")
        broker = ScopeBroker(state)
        registered = broker.register_workline(contract, expected_contract_hash=_hash(contract))
        assert registered.ok and registered.context is not None
        channel = broker.open_channel()
        paired = broker.pair_channel(channel, registered.context.workline_id, access_mode="read")
        assert paired.ok
        core = BrainCore(
            ROOT,
            memory,
            scope_provider=BrokerScopeProvider(broker, channel),
            runtime_mode="local_stdio_scope_broker",
            transport_health=LocalBrokerStdioTransportHealth(broker, channel),
        )
        projection = {
            "scopeRef": "f" * 64,
            "stateHash": "e" * 64,
            "revision": 1,
            "packageVersion": "0.6.0",
            "lifecycle": "active",
            "contractRevision": 1,
            "planFingerprint": "plan-current",
            "lastConfirmedSentence": "bound task recall is projected from the channel",
            "lastConfirmedSource": "assistant_visible_reply",
            "currentPhase": "verification",
            "currentStep": "read the exact current task projection",
            "nextAction": "continue with the broker-bound workline",
            "completedSteps": [],
            "pendingSteps": ["continue"],
            "blockers": [],
            "evidenceRefs": [],
            "verificationResults": [],
            "updatedAt": "2026-08-29T00:00:00Z",
            "actionAuthorization": "withheld",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        expected = {
            "ok": True,
            "available": True,
            "snapshotHash": "d" * 64,
            "projection": projection,
        }
        with mock.patch.object(brain_mcp, "read_mcp_task_projection", return_value=expected) as reader:
            with mock.patch.object(core, "recall", side_effect=AssertionError("generic recall must not run")):
                result = brain_mcp.handle_tool(
                    core,
                    "brain_recall",
                    {"query": "当前任务", "layer": "task", "top_k": 1, "max_tokens": 120},
                    state / "workspace" / "mcp-snapshot.json",
                )
        body = _status_payload({"result": result})
        assert result["isError"] is False, result
        assert body and body[0]["sourceType"] == "task_projection", body
        reader.assert_called_once_with(
            state / "workspace" / "mcp-snapshot.json",
            workspace_key=contract["workspaceKey"],
            owner_session_key=contract["ownerSessionKey"],
        )


def main() -> None:
    test_bound_task_layer_uses_the_channel_projection()
    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-broker-") as directory:
        state = Path(directory) / "state"
        state.mkdir()
        project_a = Path(directory) / "project-a"
        project_b = Path(directory) / "project-b"
        project_a.mkdir()
        project_b.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        poisoned_binding = state / "workspace/runtime-state/mcp-runtime-binding.json"
        poisoned_binding.parent.mkdir(parents=True, exist_ok=True)
        poisoned_binding.write_text('{"poison":"deployment-adapter"}', encoding="utf-8")
        poisoned_binding_before = poisoned_binding.read_bytes()
        contracts = [_contract(project_a, "a"), _contract(project_b, "b")]
        registrations = [
            control.register_workline(contract, expected_contract_hash=_hash(contract), project_root=project)
            for contract, project in zip(contracts, (project_a, project_b))
        ]
        assert all(item.get("ok") is True for item in registrations)
        processes: list[subprocess.Popen[str]] = []
        try:
            for index, registration in enumerate(registrations):
                process = subprocess.Popen(
                    [sys.executable, "-B", str(ROOT / "runtime" / "brain_mcp.py"), "--package-root", str(ROOT), "--memory-root", str(state / "shared")],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    env=_live_mcp_environment(),
                )
                processes.append(process)
                # MCP requires a real initialize before tool discovery or
                # calls.  This guards the process-local handshake state rather
                # than a host/deployment registration marker.
                pre_init = _send(process, {"jsonrpc": "2.0", "id": 900 + index, "method": "tools/list", "params": {}})
                assert pre_init.get("error", {}).get("message") == "H7_MCP_INITIALIZE_REQUIRED", pre_init
                initialize = _send(process, {"jsonrpc": "2.0", "id": index + 1, "method": "initialize", "params": {}})
                assert initialize.get("result", {}).get("serverInfo", {}).get("name") == "super-memory-brain"
                initialize_handshake = initialize.get("result", {}).get("liveMcpHandshake", {})
                assert initialize_handshake.get("schema") == "super-brain.mcp-live-handshake.v2", initialize
                assert initialize_handshake.get("state") == "current", initialize
                assert initialize_handshake.get("code") == "H7_MCP_LOCAL_STDIO_CURRENT", initialize
                assert initialize_handshake.get("transport") == "local_scope_broker_stdio", initialize
                assert initialize_handshake.get("scope", {}).get("provider") == "scope_broker_channel", initialize
                assert initialize_handshake.get("scope", {}).get("state") == "unbound", initialize
                assert initialize_handshake.get("packageVersion"), initialize
                initialize_serialized = json.dumps(initialize, ensure_ascii=False)
                for secret_marker in ("leaseId", "pairingToken", "sbpg-v1.", "sbl-"):
                    assert secret_marker not in initialize_serialized, initialize
                initial_status = _status_payload(
                    _send(
                        process,
                        {"jsonrpc": "2.0", "id": 25 + index, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}},
                    )
                )
                assert initial_status.get("scopeBinding", {}).get("provider") == "scope_broker_channel", initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("schema") == "super-brain.mcp-live-handshake.v2", initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("state") == "current", initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("transport") == "local_scope_broker_stdio", initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("scope", {}).get("state") == "unbound", initial_status
                assert initial_status.get("mcpRuntimeBinding", {}).get("deploymentAdapter", {}).get("state") == "not_applicable", initial_status
                assert poisoned_binding.read_bytes() == poisoned_binding_before
                assert initial_status.get("localPathsExposed") is False, initial_status
                initial_serialized = json.dumps(initial_status, ensure_ascii=False)
                assert str(ROOT.resolve()) not in initial_serialized, initial_status
                assert str(state.resolve()) not in initial_serialized, initial_status
                tools = _send(process, {"jsonrpc": "2.0", "id": 30 + index, "method": "tools/list", "params": {}})
                declared = tools.get("result", {}).get("tools", [])
                recall = next(item for item in declared if item.get("name") == "brain_recall")
                assert "task_scope" not in recall.get("inputSchema", {}).get("properties", {})

                # An unbound stdio connection cannot run even a checkpoint.
                # This proves that no request argument, cwd, or environment
                # value silently selects a workline before Broker binding.
                unbound_turn = _status_payload(
                    _send(
                        process,
                        {
                            "jsonrpc": "2.0",
                            "id": 40 + index,
                            "method": "tools/call",
                            "params": {"name": "brain_turn", "arguments": {"phase": "checkpoint"}},
                        },
                    )
                )
                assert unbound_turn.get("code") == "H7_SCOPE_CHANNEL_UNBOUND", unbound_turn
                channels = control.list_channels().get("channels", [])
                assert isinstance(channels, list) and channels
                unbound = [item for item in channels if isinstance(item, dict) and item.get("state") == "unbound"]
                assert unbound
                channel_id = str(unbound[-1]["channelId"])
                # Pairing is a single Broker-side transaction.  No bearer
                # token crosses CLI/IPC/MCP output on the production path.
                attached = control.pair_channel(
                    channel_id,
                    str(registration["scope"]["worklineId"]),
                    access_mode="read",
                )
                assert attached.get("ok") is True
                for secret_marker in ("leaseId", "pairingToken", "sbpg-v1.", "sbl-", "h7Scope"):
                    assert secret_marker not in json.dumps(attached, ensure_ascii=False), attached
                status = _status_payload(_send(process, {"jsonrpc": "2.0", "id": 10 + index, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}}))
                binding = status.get("scopeBinding")
                assert isinstance(binding, dict)
                assert binding.get("state") == "bound"
                assert binding.get("scope", {}).get("taskId") == contracts[index]["taskId"]
                assert binding.get("scope", {}).get("workspaceKey") == contracts[index]["workspaceKey"]
                assert status.get("liveMcpHandshake", {}).get("state") == "current", status
                assert status.get("liveMcpHandshake", {}).get("scope", {}).get("state") == "bound", status
                status_serialized = json.dumps(status, ensure_ascii=False)
                for secret_marker in ("leaseId", "pairingToken", "sbpg-v1.", "sbl-"):
                    assert secret_marker not in status_serialized, status
                assert str((project_a if index == 0 else project_b).resolve()) not in status_serialized, status

                # Raw selectors are rejected for every production Broker tool,
                # not merely ignored outside brain_recall.
                selector = _status_payload(
                    _send(
                        process,
                        {
                            "jsonrpc": "2.0",
                            "id": 70 + index,
                            "method": "tools/call",
                            "params": {
                                "name": "brain_status",
                                "arguments": {
                                    "task_scope": {
                                        "workspace_key": contracts[index]["workspaceKey"],
                                        "owner_session_key": contracts[index]["ownerSessionKey"],
                                    }
                                },
                            },
                        },
                    )
                )
                assert selector.get("code") == "H7_SCOPE_SELECTOR_FORBIDDEN", selector

                # A read attachment can inspect its own binding, but the
                # write check inside turn_runtime still blocks checkpoint
                # mutations.  This guards direct runtime callers as well as
                # the MCP adapter's friendly early read check.
                read_lease_turn = _status_payload(
                    _send(
                        process,
                        {
                            "jsonrpc": "2.0",
                            "id": 50 + index,
                            "method": "tools/call",
                            "params": {"name": "brain_turn", "arguments": {"phase": "checkpoint"}},
                        },
                    )
                )
                assert read_lease_turn.get("code") == "H7_SCOPE_WRITE_LEASE_REQUIRED", read_lease_turn

            # A fresh connection is never implicitly attached, even though
            # the durable workline registry already exists.
            fresh = subprocess.Popen(
                [sys.executable, "-B", str(ROOT / "runtime" / "brain_mcp.py"), "--package-root", str(ROOT), "--memory-root", str(state / "shared")],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                env=_live_mcp_environment(),
            )
            processes.append(fresh)
            _send(fresh, {"jsonrpc": "2.0", "id": 20, "method": "initialize", "params": {}})
            unbound_status = _status_payload(_send(fresh, {"jsonrpc": "2.0", "id": 21, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}}))
            assert unbound_status.get("scopeBinding", {}).get("state") == "unbound"
            assert unbound_status.get("scopeBinding", {}).get("code") == "H7_SCOPE_CHANNEL_UNBOUND"
            assert unbound_status.get("liveMcpHandshake", {}).get("state") == "current", unbound_status
            assert unbound_status.get("liveMcpHandshake", {}).get("scope", {}).get("state") == "unbound", unbound_status
        finally:
            for process in processes:
                try:
                    if process.stdin:
                        process.stdin.close()
                    process.terminate()
                    process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    process.kill()
            server.stop()
    print("runtime_mcp_scope_broker_integration_regression: PASS")


if __name__ == "__main__":
    main()
