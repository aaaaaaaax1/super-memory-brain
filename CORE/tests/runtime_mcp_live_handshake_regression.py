from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from brain_core import BrainCore
from brain_mcp import handle_tool
from mcp_runtime_identity import runtime_dependency_paths, runtime_identity
from runtime_turn_runtime_regression import write_context_contract, write_native_memory_snapshot


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def payload(result: dict[str, object]) -> dict[str, object]:
    return json.loads(str(result["content"][0]["text"]))


def root_hash(path: Path) -> str:
    return hashlib.sha256(str(path.resolve()).rstrip("/\\").lower().encode("utf-8")).hexdigest()


def workspace_key(path: Path) -> str:
    return "ws-" + root_hash(path)[:24]


def powershell_mcp_path_hash(path: Path) -> str:
    """Call the production installer helper rather than copy its formula."""

    if os.name != "nt":
        return root_hash(path)
    common = ROOT / "scripts" / "common.ps1"
    command = (
        "$ErrorActionPreference='Stop'; "
        f". '{common}'; "
        f"Get-SuperBrainMcpPathHash -Root '{path}'"
    )
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
        timeout=15,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip().lower()


def binding_hash(value: dict[str, object]) -> str:
    fields = (
        "schema", "state", "registrationEpoch", "packageVersion", "runtimeIdentity",
        "packageRootHash", "memoryRootHash", "configuredAt", "liveHandshake",
        "rawPromptStored", "rawTranscriptStored",
    )
    return hashlib.sha256(
        json.dumps({key: value.get(key) for key in fields}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def copy_package(destination: Path) -> None:
    # The resident MCP's identity closure does not import the fresh CLI
    # transport, but a package-owned stale-worker fallback must ship it.
    for relative in (*runtime_dependency_paths(ROOT), "runtime/brain_cli.py"):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / relative).read_bytes())
    for relative in ("route-map.json", "capabilities.json"):
        (destination / relative).write_bytes((ROOT / relative).read_bytes())


def write_binding(core: BrainCore, *, epoch: str) -> Path:
    binding = {
        "schema": "super-brain.mcp-runtime-binding.v1",
        "state": "restart_required",
        "registrationEpoch": epoch,
        "packageVersion": str(core.manifest["version"]),
        "runtimeIdentity": runtime_identity(core.package_root),
        "packageRootHash": root_hash(core.package_root),
        "memoryRootHash": root_hash(core.memory_base),
        "configuredAt": "2026-08-16T00:00:00+00:00",
        "liveHandshake": None,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    binding["payloadHash"] = binding_hash(binding)
    path = core.workspace / "runtime-state" / "mcp-runtime-binding.json"
    write_json(path, binding)
    return path


def environment(package: Path, memory: Path, epoch: str) -> dict[str, str]:
    value = dict(os.environ)
    value.pop("SUPER_BRAIN_MCP_OFFLINE_REPLAY", None)
    value["SUPER_BRAIN_PACKAGE_ROOT"] = str(package)
    value["NEXSANDBASE_HOME"] = str(memory)
    value["SUPER_BRAIN_RUNTIME_IDENTITY"] = runtime_identity(package)
    value["SUPER_BRAIN_MCP_TRANSPORT"] = "codex_registered_v1"
    value["SUPER_BRAIN_MCP_REGISTRATION_EPOCH"] = epoch
    return value


def test_offline_replay_never_becomes_live() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-offline-mcp-") as directory:
        package = Path(directory) / "package"
        memory = Path(directory) / "state" / "shared"
        package.mkdir(parents=True)
        memory.mkdir(parents=True)
        copy_package(package)
        core = BrainCore(package, memory)
        saved = os.environ.get("SUPER_BRAIN_MCP_OFFLINE_REPLAY")
        os.environ["SUPER_BRAIN_MCP_OFFLINE_REPLAY"] = "1"
        try:
            status = payload(handle_tool(core, "brain_status", {}))
            assert status["liveMcpHandshake"]["state"] == "offline_replay", status
            assert status["liveMcpHandshake"]["code"] == "H7_MCP_OFFLINE_REPLAY_NOT_LIVE", status
        finally:
            if saved is None:
                os.environ.pop("SUPER_BRAIN_MCP_OFFLINE_REPLAY", None)
            else:
                os.environ["SUPER_BRAIN_MCP_OFFLINE_REPLAY"] = saved


def test_offline_replay_governed_turn_fails_closed() -> None:
    """The protocol harness must never enter H7 lifecycle execution."""

    with tempfile.TemporaryDirectory(prefix="super-brain-offline-turn-") as directory:
        memory = Path(directory) / "state" / "shared"
        memory.mkdir(parents=True)
        requests = (
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            + "\n"
            + json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {"name": "brain_turn", "arguments": {"phase": "evidence"}},
                }
            )
            + "\n"
        )
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "brain_mcp.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(memory),
                "--offline-replay",
            ],
            input=requests,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=20,
        )
        assert completed.returncode == 0, completed.stderr
        lines = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        assert len(lines) == 2, completed.stdout
        tool = lines[1].get("result", {})
        assert tool.get("isError") is True, tool
        content = tool.get("content", [])
        assert isinstance(content, list) and content
        body = json.loads(str(content[0]["text"]))
        assert body.get("available") is False, body
        assert body.get("code") == "H7_MCP_OFFLINE_REPLAY_NOT_LIVE", body


def test_installer_path_hash_contract_matches_python_runtime() -> None:
    """Fresh PowerShell registration must satisfy the resident MCP preflight."""

    installer = (ROOT / "scripts" / "install-runtime.ps1").read_text(encoding="utf-8")
    assert "packageRootHash = Get-SuperBrainMcpPathHash $Root" in installer
    assert "memoryRootHash = Get-SuperBrainMcpPathHash (Get-SuperBrainMemoryBaseRoot $Root)" in installer
    assert powershell_mcp_path_hash(ROOT) == root_hash(ROOT)
    memory_base = ROOT.parent / "private-state"
    assert powershell_mcp_path_hash(memory_base) == root_hash(memory_base)
    # The MCP env remains scoped to the one active shared child, but the
    # binding hash is intentionally for the canonical state root.
    memory_shared = memory_base / "shared"
    assert powershell_mcp_path_hash(memory_shared) != root_hash(memory_base)


def test_registration_epoch_blocks_old_worker_until_real_initialize() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-live-mcp-") as directory:
        package = Path(directory) / "package"
        memory = Path(directory) / "state" / "shared"
        package.mkdir(parents=True)
        memory.mkdir(parents=True)
        copy_package(package)
        first_epoch = "a" * 32
        second_epoch = "b" * 32
        old_env = environment(package, memory, first_epoch)
        core = BrainCore(package, memory)
        binding_path = write_binding(core, epoch=first_epoch)

        # A target binding is not live until the real MCP initialize path signs it.
        old_values = {key: os.environ.get(key) for key in old_env}
        os.environ.update(old_env)
        try:
            before = payload(handle_tool(core, "brain_status", {}))
            assert before["liveMcpHandshake"]["state"] == "withheld", before
            assert before["liveMcpHandshake"]["code"] == "H7_MCP_LIVE_HANDSHAKE_REQUIRED", before
        finally:
            for key, value in old_values.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

        initialized = subprocess.run(
            [sys.executable, "-B", str(package / "runtime" / "brain_mcp.py"), "--package-root", str(package), "--memory-root", str(memory)],
            input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}) + "\n",
            env=old_env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=15,
        )
        assert initialized.returncode == 0, initialized.stderr
        init_payload = json.loads(initialized.stdout.strip())
        assert init_payload["result"]["liveMcpHandshake"]["state"] == "current", init_payload

        # Changing only the expected epoch simulates a config re-registration.
        updated = json.loads(binding_path.read_text(encoding="utf-8"))
        updated["state"] = "restart_required"
        updated["registrationEpoch"] = second_epoch
        updated["liveHandshake"] = None
        updated["payloadHash"] = binding_hash(updated)
        write_json(binding_path, updated)
        os.environ.update(old_env)
        try:
            bridged_recent = handle_tool(core, "brain_recent", {})
            assert bridged_recent["isError"] is False, bridged_recent
            assert payload(bridged_recent) == [], bridged_recent
            # Explicit health remains truthful: the old MCP worker is still
            # stale even though its normal read used a fresh CLI transport.
            stale_status = payload(handle_tool(core, "brain_status", {}))
            assert stale_status["liveMcpHandshake"]["state"] == "withheld", stale_status
            assert stale_status["liveMcpHandshake"]["code"] == "H7_MCP_RUNTIME_REBIND_REQUIRED", stale_status
        finally:
            for key, value in old_values.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

        new_env = environment(package, memory, second_epoch)
        rebound = subprocess.run(
            [sys.executable, "-B", str(package / "runtime" / "brain_mcp.py"), "--package-root", str(package), "--memory-root", str(memory)],
            input=json.dumps({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {}}) + "\n",
            env=new_env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=15,
        )
        assert rebound.returncode == 0, rebound.stderr
        rebound_payload = json.loads(rebound.stdout.strip())
        assert rebound_payload["result"]["liveMcpHandshake"]["state"] == "current", rebound_payload


def test_retired_host_inputs_are_rejected_before_any_bridge() -> None:
    """Retired Host payloads fail closed before identity/CLI work is attempted."""

    with tempfile.TemporaryDirectory(prefix="super-brain-retired-host-") as directory:
        package = Path(directory) / "package"
        memory = Path(directory) / "state" / "shared"
        package.mkdir(parents=True)
        memory.mkdir(parents=True)
        copy_package(package)
        worker = BrainCore(package, memory)

        for field, value in (
            ("host_visible_context", {"text": "继续普通对话。"}),
            ("host_thread_payload", {"thread": {"id": "retired"}}),
        ):
            result = handle_tool(
                worker,
                "brain_turn",
                {"phase": "open", "turn_intent": "continuity", field: value},
            )
            body = payload(result)
            assert result["isError"] is True, result
            assert body["code"] == "H7_HOST_TRANSPORT_RETIRED", body


def test_non_object_jsonrpc_input_does_not_crash_the_worker() -> None:
    """Malformed scalar/array frames yield JSON-RPC invalid-request errors."""

    with tempfile.TemporaryDirectory(prefix="super-brain-invalid-jsonrpc-") as directory:
        memory = Path(directory) / "state" / "shared"
        memory.mkdir(parents=True)
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "brain_mcp.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(memory),
                "--offline-replay",
            ],
            input="null\n[]\n",
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=20,
        )
        assert completed.returncode == 0, completed.stderr
        replies = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        assert len(replies) == 2, completed.stdout
        assert all(reply.get("error", {}).get("code") == -32600 for reply in replies), replies


def main() -> None:
    test_offline_replay_never_becomes_live()
    test_offline_replay_governed_turn_fails_closed()
    test_installer_path_hash_contract_matches_python_runtime()
    test_registration_epoch_blocks_old_worker_until_real_initialize()
    test_retired_host_inputs_are_rejected_before_any_bridge()
    test_non_object_jsonrpc_input_does_not_crash_the_worker()
    print("runtime_mcp_live_handshake_regression: PASS")


if __name__ == "__main__":
    main()
