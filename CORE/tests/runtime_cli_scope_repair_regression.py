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
sys.path.insert(0, str(ROOT / "tests"))

from runtime_turn_runtime_regression import write_context_contract  # noqa: E402
from scope_broker_ipc import ScopeBrokerClient, ScopeBrokerServer, _canonical_hash  # noqa: E402


def _contract_hash(value: dict[str, object]) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _cli(
    *,
    memory: Path,
    cwd: Path,
    action: str,
    session: str = "",
) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
    if session:
        environment["SUPER_BRAIN_LOCAL_SESSION_ID"] = session
    return subprocess.run(
        [
            sys.executable,
            "-B",
            str(ROOT / "runtime" / "brain_cli.py"),
            "--package-root",
            str(ROOT),
            "--memory-root",
            str(memory),
            "scope",
            "--action",
            action,
        ],
        cwd=str(cwd),
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
        timeout=20,
    )


def _payload(result: subprocess.CompletedProcess[str]) -> dict[str, object]:
    assert result.returncode == 0, result.stderr
    value = json.loads(result.stdout)
    assert isinstance(value, dict), value
    return value


def test_public_scope_selectors_are_retired_without_starting_a_broker() -> None:
    """The compatibility action names cannot enumerate or select any scope."""

    with tempfile.TemporaryDirectory(prefix="super-brain-cli-scope-retired-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        for action in ("list", "status", "register", "bind"):
            payload = _payload(_cli(memory=memory, cwd=project, action=action))
            assert payload == {
                "ok": False,
                "schema": "super-brain.local-scope-repair.v1",
                "available": False,
                "state": "withheld",
                "code": "H7_SCOPE_SELECTOR_CONTROL_RETIRED",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }, payload
        broker_root = state / "workspace" / "runtime-state" / "scope-broker"
        assert not (broker_root / "endpoint.json").exists()
        assert not (broker_root / "registry.json").exists()

    # The production parser must not retain a channel/ref/workline/contract
    # selector even as an ignored compatibility field.
    source = (ROOT / "runtime" / "brain_cli.py").read_text(encoding="utf-8")
    for selector in ("--channel-id", "--pairing-request-ref", "--workline-id", "--contract-file", "--project-root"):
        assert selector not in source, selector


def test_scope_repair_requires_a_current_local_contract_before_side_effects() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-cli-scope-missing-contract-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        invalid_session = _payload(
            _cli(
                memory=memory,
                cwd=project,
                action="repair",
                session="local-session-is-not-a-launcher-sid",
            )
        )
        assert invalid_session["ok"] is False, invalid_session
        assert invalid_session["code"] == "H7_SCOPE_LOCAL_SESSION_REQUIRED", invalid_session
        payload = _payload(
            _cli(
                memory=memory,
                cwd=project,
                action="repair",
                session="sid-" + "a" * 24,
            )
        )
        assert payload["ok"] is False, payload
        assert payload["code"] == "H7_SCOPE_LOCAL_CURRENT_CONTRACT_REQUIRED", payload
        broker_root = state / "workspace" / "runtime-state" / "scope-broker"
        assert not (broker_root / "endpoint.json").exists()
        assert not (broker_root / "registry.json").exists()


def test_scope_repair_requires_an_existing_exact_broker_workline() -> None:
    """The user CLI cannot create a workline while repairing a root map."""

    with tempfile.TemporaryDirectory(prefix="super-brain-cli-scope-repair-rebind-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        session = "sid-" + "c" * 24
        write_context_contract(state, project, session, task_id="task-cli-scope-repair-rebind")

        payload = _payload(_cli(memory=memory, cwd=project, action="repair", session=session))
        assert payload == {
            "ok": False,
            "schema": "super-brain.local-scope-repair.v1",
            "available": False,
            "state": "withheld",
            "code": "H7_SCOPE_REPAIR_REBIND_REQUIRED",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }, payload
        broker_root = state / "workspace" / "runtime-state" / "scope-broker"
        assert not (broker_root / "registry.json").exists()
        assert not (broker_root / "project-roots.json").exists()


def test_scope_repair_rebuilds_only_current_root_projection_without_a_channel() -> None:
    """A repair may rebuild trusted root proof, but cannot create a binding."""

    with tempfile.TemporaryDirectory(prefix="super-brain-cli-scope-repair-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        session = "sid-" + "b" * 24
        write_context_contract(state, project, session, task_id="task-cli-scope-repair")
        contract_path = next((state / "workspace" / "runtime-state" / "execution-contracts").glob("*.json"))
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        assert isinstance(contract, dict)

        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        first = ScopeBrokerServer(state)
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        restarted: ScopeBrokerServer | None = None
        channel = ""
        try:
            first.start()
            bound = client.bootstrap_bound_channel(
                contract,
                expected_contract_hash=_contract_hash(contract),
                project_root=project,
                access_mode="read",
            )
            assert bound.get("ok") is True, bound
            channel = str(bound.get("channelId", ""))
            assert channel.startswith("sbc-"), bound
            assert client.close_channel(channel).get("ok") is True
            channel = ""
            first.stop()

            roots_path = state / "workspace" / "runtime-state" / "scope-broker" / "project-roots.json"
            tampered = json.loads(roots_path.read_text(encoding="utf-8"))
            workline_id = next(iter(tampered["roots"]))
            tampered["roots"][workline_id]["unexpected"] = "must-require-explicit-repair"
            tampered["payloadHash"] = _canonical_hash({key: value for key, value in tampered.items() if key != "payloadHash"})
            roots_path.write_text(json.dumps(tampered, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

            restarted = ScopeBrokerServer(state)
            restarted.start()
            assert restarted._project_root_registry_invalid is True

            payload = _payload(_cli(memory=memory, cwd=project, action="repair", session=session))
            assert payload == {
                "ok": True,
                "schema": "super-brain.local-scope-repair.v1",
                "available": True,
                "state": "repaired",
                "code": "H7_SCOPE_LOCAL_REPAIR_COMPLETED",
                "scopeVerified": True,
                "bindingCreated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }, payload
            serialized = json.dumps(payload, ensure_ascii=False)
            for private_marker in (session, str(project.resolve()), "sbc-", "sbs-", "sbw-", "channelId", "worklineId", "projectRoot"):
                assert private_marker not in serialized, serialized

            repaired = json.loads(roots_path.read_text(encoding="utf-8"))
            assert "unexpected" not in repaired["roots"][workline_id], repaired
            assert restarted._project_root_registry_invalid is False
            with restarted.broker._memory_lock:
                assert restarted.broker._channels == set()
                assert restarted.broker._bindings == {}
        finally:
            if channel:
                try:
                    client.close_channel(channel)
                except Exception:
                    pass
            if restarted is not None:
                restarted.stop()
            else:
                first.stop()
            client.close()


def main() -> None:
    test_public_scope_selectors_are_retired_without_starting_a_broker()
    test_scope_repair_requires_a_current_local_contract_before_side_effects()
    test_scope_repair_requires_an_existing_exact_broker_workline()
    test_scope_repair_rebuilds_only_current_root_projection_without_a_channel()
    print("runtime_cli_scope_repair_regression: PASS")


if __name__ == "__main__":
    main()
