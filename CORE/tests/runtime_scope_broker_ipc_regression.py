"""Focused safety checks for the local Scope Broker IPC transport."""

from __future__ import annotations

import hashlib
import hmac
import json
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from scope_broker_ipc import (  # noqa: E402
    ENDPOINT_SCHEMA,
    ScopeBrokerAlreadyRunning,
    ScopeBrokerClient,
    ScopeBrokerControlClient,
    ScopeBrokerServer,
    _canonical,
    _canonical_hash,
    _read_endpoint_bundle,
)
from mcp_transport_health import LocalBrokerStdioTransportHealth  # noqa: E402
from scope_provider import BrokerChannelHandle, BrokerScopeProvider  # noqa: E402


def _signed(secret: bytes, method: str, params: dict[str, object], nonce: str) -> dict[str, object]:
    mac = hmac.new(secret, _canonical({"method": method, "params": params, "nonce": nonce}), hashlib.sha256).hexdigest()
    return {"method": method, "params": params, "nonce": nonce, "mac": mac}


def _contract(project: Path) -> dict[str, object]:
    normalized = str(project.resolve()).rstrip("/\\").lower()
    return {
        "schema": "super-brain.execution-contract.v1",
        "status": "active",
        "taskId": "scope-broker-ipc-shared-owner",
        "taskInstanceId": "ti-" + "a" * 32,
        "workspaceKey": "ws-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24],
        "ownerSessionKey": "sid-" + "b" * 24,
        "packageVersion": "1.0.0",
        "revision": 1,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _contract_hash(value: dict[str, object]) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _bootstrap_bound_channel(
    client: ScopeBrokerClient,
    contract: dict[str, object],
    project: Path,
    *,
    access_mode: str = "read",
) -> str:
    """Use the package-owned atomic user bootstrap path in IPC regressions."""

    result = client.bootstrap_bound_channel(
        contract,
        expected_contract_hash=_contract_hash(contract),
        project_root=project,
        access_mode=access_mode,
    )
    assert result.get("ok") is True, result
    channel = str(result.get("channelId", ""))
    assert channel.startswith("sbc-") and len(channel) == 36, result
    return channel


def test_server_singleton_and_secret_fingerprint() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-singleton-") as directory:
        state = Path(directory) / "state"
        first = ScopeBrokerServer(state)
        endpoint = first.start()
        try:
            assert endpoint["schema"] == ENDPOINT_SCHEMA
            assert endpoint["instanceId"]
            assert len(str(endpoint["secretSha256"])) == 64
            second = ScopeBrokerServer(state)
            try:
                second.start()
            except ScopeBrokerAlreadyRunning as error:
                assert error.endpoint_data.get("instanceId") == endpoint["instanceId"]
            else:  # pragma: no cover - defensive assertion
                raise AssertionError("second server replaced a live broker")
            bundle = _read_endpoint_bundle(first.endpoint_path, first.secret_path)
            assert bundle is not None
            assert bundle[0]["instanceId"] == endpoint["instanceId"]
            assert hmac.compare_digest(bundle[0]["secretSha256"], hashlib.sha256(bundle[1]).hexdigest())
        finally:
            first.stop()


def test_authenticated_nonce_is_one_shot() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-nonce-") as directory:
        server = ScopeBrokerServer(Path(directory) / "state")
        server.start()
        try:
            bundle = _read_endpoint_bundle(server.endpoint_path, server.secret_path)
            assert bundle is not None
            secret = bundle[1]
            request = _signed(secret, "ping", {}, "nonce-" + "a" * 24)
            assert server._dispatch(request)["code"] == "H7_SCOPE_BROKER_PONG"
            replay = server._dispatch(request)
            assert replay["code"] == "H7_SCOPE_BROKER_NONCE_REPLAYED"
            malformed = dict(request)
            malformed["nonce"] = "short"
            assert server._dispatch(malformed)["code"] == "H7_SCOPE_BROKER_NONCE_INVALID"
        finally:
            server.stop()


def test_endpoint_bundle_rejects_oversized_metadata() -> None:
    """Endpoint discovery must not parse attacker-controlled large files."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-endpoint-size-") as directory:
        state = Path(directory) / "state"
        runtime_root = state / "workspace/runtime-state/scope-broker"
        runtime_root.mkdir(parents=True)
        (runtime_root / "secret.bin").write_bytes(b"x" * 32)
        (runtime_root / "endpoint.json").write_text("{" + "\"padding\":\"" + ("x" * 20000) + "\"}", encoding="utf-8")
        assert _read_endpoint_bundle(runtime_root / "endpoint.json", runtime_root / "secret.bin") is None


def test_pairing_tokens_cannot_cross_ipc() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-pairing-") as directory:
        server = ScopeBrokerServer(Path(directory) / "state")
        server.start()
        try:
            bundle = _read_endpoint_bundle(server.endpoint_path, server.secret_path)
            assert bundle is not None
            secret = bundle[1]
            request = _signed(
                secret,
                "issue_pairing_grant",
                {"channelId": "sbc-" + "a" * 32, "worklineId": "sbw-" + "b" * 32},
                "nonce-" + "b" * 24,
            )
            result = server._dispatch(request)
            assert result["code"] == "H7_SCOPE_PAIRING_TOKEN_TRANSPORT_RETIRED"
            assert "pairingToken" not in result
        finally:
            server.stop()


def test_concurrent_clients_spawn_one_child() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-start-") as directory:
        state = Path(directory) / "state"
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        clients = [ScopeBrokerClient(state, runtime_path=runtime) for _ in range(5)]
        channels: list[str] = []
        owned_channels: dict[ScopeBrokerClient, str] = {}
        errors: list[BaseException] = []

        def worker(client: ScopeBrokerClient) -> None:
            try:
                channel = client.open_channel()
                assert channel
                channels.append(channel)
                owned_channels[client] = channel
            except BaseException as error:  # pragma: no cover - assertion fan-in
                errors.append(error)

        threads = [threading.Thread(target=worker, args=(client,)) for client in clients]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=8)
        try:
            assert not errors, errors
            assert len(channels) == len(clients)
            bundle = _read_endpoint_bundle(state / "workspace/runtime-state/scope-broker/endpoint.json", state / "workspace/runtime-state/scope-broker/secret.bin")
            assert bundle is not None
            pids = {client._process.pid for client in clients if client._process is not None and client._process.poll() is None}
            assert pids <= {bundle[0]["pid"]}
        finally:
            for client, channel in owned_channels.items():
                try:
                    client.close_channel(channel)
                except Exception:
                    pass
            # Only the client that launched the child is allowed to terminate
            # it directly; the authenticated idle request handles cleanup.
            for client in clients:
                client.close()
            # Give the deferred server stop a bounded chance to release its
            # Windows lock handle before TemporaryDirectory cleanup.
            deadline = time.monotonic() + 3
            while (state / "workspace/runtime-state/scope-broker/broker.lock").exists() and time.monotonic() < deadline:
                time.sleep(0.05)


def test_owner_close_preserves_a_shared_bound_channel() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-shared-owner-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        owner = ScopeBrokerClient(state, runtime_path=runtime)
        peer = ScopeBrokerClient(state, runtime_path=runtime)
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        owner_channel = ""
        peer_channel = ""
        launched: subprocess.Popen[object] | None = None
        try:
            owner_channel = owner.open_channel()
            assert owner_channel
            launched = owner._process
            assert launched is not None and launched.poll() is None
            contract = _contract(project)
            peer_channel = _bootstrap_bound_channel(peer, contract, project, access_mode="read")

            # This is the exact production teardown order: the owner closes
            # only its channel, then releases its client.  The still-bound
            # peer must retain both the broker process and its scope lease.
            assert owner.close_channel(owner_channel).get("ok") is True
            owner_channel = ""
            owner.close()
            assert launched.poll() is None
            authorization = peer.authorize(peer_channel, write=False)
            assert authorization.get("ok") is True, authorization
            assert authorization.get("code") == "H7_SCOPE_AUTHORIZED", authorization
        finally:
            if peer_channel:
                try:
                    peer.close_channel(peer_channel)
                except Exception:
                    pass
            if owner_channel:
                try:
                    owner.close_channel(owner_channel)
                except Exception:
                    pass
            try:
                owner.shutdown_if_idle()
            except Exception:
                pass
            if launched is not None and launched.poll() is None:
                try:
                    launched.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    launched.terminate()
                    try:
                        launched.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        launched.kill()
            peer.close()
            control.close()


def test_shutdown_if_idle_requires_the_expected_broker_instance() -> None:
    """A stale client must not stop a replacement Broker instance."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-shutdown-cas-") as directory:
        state = Path(directory) / "state"
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        server = ScopeBrokerServer(state, idle_seconds=None)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        try:
            current_instance = str(server.endpoint().get("instanceId", ""))
            bundle = _read_endpoint_bundle(server.endpoint_path, server.secret_path)
            assert bundle is not None
            missing = server._dispatch(_signed(bundle[1], "shutdown_if_idle", {}, "shutdown-missing-instance"))
            assert missing.get("ok") is False, missing
            assert missing.get("code") == "H7_SCOPE_BROKER_INSTANCE_REQUIRED", missing
            assert server.is_running

            rejected = control.shutdown_if_idle(expected_instance_id="sbi-" + "f" * 32)
            assert rejected.get("ok") is False, rejected
            assert rejected.get("code") == "H7_SCOPE_BROKER_INSTANCE_CHANGED", rejected
            assert server.is_running

            accepted = control.shutdown_if_idle(expected_instance_id=current_instance)
            assert accepted.get("ok") is True, accepted
            assert accepted.get("code") == "H7_SCOPE_BROKER_SHUTDOWN_ACCEPTED", accepted
            deadline = time.monotonic() + 2.0
            while server.is_running and time.monotonic() < deadline:
                time.sleep(0.02)
            assert not server.is_running

            # The deferred stop releases the process-local lease from its
            # worker thread.  A different thread must be able to start the
            # next Broker on the same state root immediately; this catches a
            # cross-thread RLock leak that can be invisible in one-thread
            # tests.
            replacement_result: list[dict[str, object]] = []

            def start_and_stop_replacement() -> None:
                replacement = ScopeBrokerServer(state, idle_seconds=None)
                try:
                    replacement_result.append(replacement.start())
                finally:
                    replacement.stop()

            replacement_thread = threading.Thread(target=start_and_stop_replacement)
            replacement_thread.start()
            replacement_thread.join(timeout=2.0)
            assert not replacement_thread.is_alive()
            assert replacement_result and replacement_result[0].get("instanceId"), replacement_result
        finally:
            server.stop()
            control.close()


def test_read_only_control_close_preserves_a_warm_idle_broker() -> None:
    """A status-only control client must not gain teardown authority."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-control-close-") as directory:
        state = Path(directory) / "state"
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        server = ScopeBrokerServer(state, idle_seconds=None)
        server.start()
        owner = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        channel = ""
        try:
            channel = owner.open_channel()
            assert channel
            inspected = control.status(channel)
            assert inspected.get("ok") is True, inspected
            assert owner.close_channel(channel).get("ok") is True
            channel = ""
            control.close()
            assert server.is_running
        finally:
            if channel:
                owner.close_channel(channel)
            owner.close()
            server.stop()


def test_stale_endpoint_is_replaced() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-stale-") as directory:
        state = Path(directory) / "state"
        runtime_root = state / "workspace/runtime-state/scope-broker"
        runtime_root.mkdir(parents=True)
        stale_secret = b"x" * 32
        (runtime_root / "secret.bin").write_bytes(stale_secret)
        (runtime_root / "endpoint.json").write_text(
            json.dumps(
                {
                    "schema": ENDPOINT_SCHEMA,
                    "host": "127.0.0.1",
                    "port": 65530,
                    "pid": 2**31,
                    "startedAt": time.time() - 60,
                    "instanceId": "sbi-" + "f" * 32,
                    "secretSha256": hashlib.sha256(stale_secret).hexdigest(),
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        client = ScopeBrokerClient(state, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        channel = client.open_channel()
        try:
            assert channel
            bundle = _read_endpoint_bundle(client.endpoint_path, client.secret_path)
            assert bundle is not None and bundle[0]["pid"] != 2**31
        finally:
            client.close_channel(channel)
            client.close()


def test_repeated_stop_cannot_remove_a_new_broker_endpoint() -> None:
    """A delayed teardown from an old instance must be harmless."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-stop-owner-") as directory:
        state = Path(directory) / "state"
        first = ScopeBrokerServer(state)
        second: ScopeBrokerServer | None = None
        try:
            first.start()
            first.stop()

            second = ScopeBrokerServer(state)
            second.start()
            before = _read_endpoint_bundle(second.endpoint_path, second.secret_path)
            assert before is not None

            # This is the delayed second stop that previously deleted the
            # replacement Broker's live endpoint and secret.
            first.stop()
            after = _read_endpoint_bundle(second.endpoint_path, second.secret_path)
            assert after is not None
            assert second.is_running
        finally:
            if second is not None:
                second.stop()
            else:
                first.stop()


def test_project_root_survives_broker_restart_and_pair_stays_public() -> None:
    """A restart must restore the private proof root without leaking a lease."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-root-restart-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        first = ScopeBrokerServer(state)
        first.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        channel = ""
        try:
            contract = _contract(project)
            initial_channel = _bootstrap_bound_channel(client, contract, project, access_mode="read")
            initial_status = client.status(initial_channel)
            assert initial_status.get("ok") is True, initial_status
            workline = str(initial_status.get("scope", {}).get("worklineId", ""))
            assert workline
            client.close_channel(initial_channel)
            first.stop()

            second = ScopeBrokerServer(state)
            second.start()
            try:
                attached = client.bootstrap_bound_channel(
                    contract,
                    expected_contract_hash=_contract_hash(contract),
                    project_root=project,
                    access_mode="read",
                )
                assert attached.get("ok") is True, attached
                channel = str(attached.get("channelId", ""))
                assert channel
                serialized = json.dumps(attached, ensure_ascii=False)
                assert "leaseId" not in serialized
                assert "h7Scope" not in serialized
                assert "sbl-" not in serialized
                authorized = client.authorize(channel, write=False)
                assert authorized.get("ok") is True, authorized
                assert authorized.get("scope", {}).get("projectRoot") == str(project.resolve())
                assert BrokerScopeProvider(client, channel).project_root() == project.resolve()
                # The root is private to an authorized channel; discovery
                # projections never expose it.
                discovered = control.get_workline(workline)
                assert "projectRoot" not in json.dumps(discovered, ensure_ascii=False)
                assert "projectRoot" not in json.dumps(control.list_channels(), ensure_ascii=False)
            finally:
                if channel:
                    client.close_channel(channel)
                second.stop()
        finally:
            control.close()
            client.close()


def test_bootstrap_withholds_tampered_private_root_state() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-root-tamper-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        channel = ""
        try:
            contract = _contract(project)
            first = client.bootstrap_bound_channel(
                contract,
                expected_contract_hash=_contract_hash(contract),
                project_root=project,
                access_mode="read",
            )
            assert first.get("ok") is True, first
            first_channel = str(first["channelId"])
            initial_status = client.status(first_channel)
            workline = str(initial_status["scope"]["worklineId"])
            client.close_channel(first_channel)
            roots_path = state / "workspace/runtime-state/scope-broker/project-roots.json"
            tampered = json.loads(roots_path.read_text(encoding="utf-8"))
            # Preserve the envelope hash to prove that strict per-record shape
            # validation—not merely the outer checksum—rejects opaque fields.
            tampered["roots"][workline]["unexpected"] = "must-not-be-accepted"
            tampered["payloadHash"] = _canonical_hash(
                {key: value for key, value in tampered.items() if key != "payloadHash"}
            )
            roots_path.write_text(json.dumps(tampered, separators=(",", ":")), encoding="utf-8")
            server.stop()
            restarted = ScopeBrokerServer(state)
            restarted.start()
            try:
                result = client.bootstrap_bound_channel(
                    contract,
                    expected_contract_hash=_contract_hash(contract),
                    project_root=project,
                    access_mode="read",
                )
                assert result.get("ok") is False, result
                assert result.get("code") == "H7_SCOPE_PROJECT_ROOT_REGISTRY_INVALID", result
                # A bootstrap must never silently replace a malformed private
                # root map.  The explicit repair path owns that mutation.
                persisted = json.loads(roots_path.read_text(encoding="utf-8"))
                assert persisted["roots"][workline]["unexpected"] == "must-not-be-accepted", persisted
            finally:
                if channel:
                    client.close_channel(channel)
                restarted.stop()
        finally:
            control.close()
            client.close()


def test_bootstrap_rechecks_a_deleted_project_root() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-root-deleted-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        channel = ""
        try:
            contract = _contract(project)
            initial_channel = _bootstrap_bound_channel(client, contract, project, access_mode="read")
            initial_status = client.status(initial_channel)
            assert initial_status.get("ok") is True, initial_status
            assert client.close_channel(initial_channel).get("ok") is True
            workline = str(initial_status["scope"]["worklineId"])
            project.rmdir()
            result = client.bootstrap_bound_channel(
                contract,
                expected_contract_hash=_contract_hash(contract),
                project_root=project,
                access_mode="read",
            )
            assert result.get("ok") is False, result
            assert result.get("code") == "H7_SCOPE_PROJECT_ROOT_INVALID", result
        finally:
            if channel:
                client.close_channel(channel)
            server.stop()
            control.close()
            client.close()


def test_bound_status_withholds_after_project_root_disappears() -> None:
    """Status and local transport health must agree with authorize's root gate."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-root-status-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        channel = ""
        try:
            contract = _contract(project)
            channel = _bootstrap_bound_channel(client, contract, project, access_mode="read")
            assert client.status(channel).get("code") == "H7_SCOPE_CHANNEL_BOUND"

            health = LocalBrokerStdioTransportHealth(client, channel)
            health.mark_initialized({"state": "current", "sourceIdentity": "test", "servedCoreRules": {}})
            project.rmdir()

            status = client.status(channel)
            assert status.get("ok") is False, status
            assert status.get("code") == "H7_SCOPE_PROJECT_ROOT_INVALID", status
            handshake = health.status({"state": "current", "sourceIdentity": "test", "servedCoreRules": {}})
            assert handshake.get("state") == "withheld", handshake
            assert handshake.get("code") == "H7_SCOPE_PROJECT_ROOT_INVALID", handshake
        finally:
            if channel:
                client.close_channel(channel)
            server.stop()
            control.close()
            client.close()


def test_authorize_root_check_is_atomic_against_concurrent_bootstrap() -> None:
    """A root proof cannot race a second bootstrap into a stale scope reply."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-root-atomic-") as directory:
        state = Path(directory) / "state"
        project_a = Path(directory) / "project-a"
        project_b = Path(directory) / "project-b"
        project_a.mkdir()
        project_b.mkdir()
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        channel = ""
        bootstrapped_b: dict[str, object] = {}
        try:
            contract_a = _contract(project_a)
            contract_b = dict(contract_a)
            contract_b.update(
                {
                    "taskId": "scope-broker-atomic-rebind",
                    "taskInstanceId": "ti-" + "c" * 32,
                    "workspaceKey": "ws-" + hashlib.sha256(
                        str(project_b.resolve()).rstrip("/\\").lower().encode("utf-8")
                    ).hexdigest()[:24],
                }
            )
            channel = _bootstrap_bound_channel(client, contract_a, project_a, access_mode="read")

            original_root_lookup = server._project_root_for_context
            entered_root_lookup = threading.Event()
            release_root_lookup = threading.Event()

            def paused_root_lookup(context: object) -> str:
                entered_root_lookup.set()
                assert release_root_lookup.wait(timeout=3)
                return original_root_lookup(context)

            server._project_root_for_context = paused_root_lookup  # type: ignore[method-assign]
            authorization: dict[str, object] = {}
            bootstrap_done = threading.Event()

            def authorize() -> None:
                authorization.update(server._method("authorize", {"channelId": channel}))

            def bootstrap_successor() -> None:
                bootstrapped_b.update(
                    server._method(
                        "bootstrap_bound_channel",
                        {
                            "contract": contract_b,
                            "expectedContractHash": _contract_hash(contract_b),
                            "projectRoot": str(project_b),
                            "accessMode": "read",
                        },
                    )
                )
                bootstrap_done.set()

            authorize_thread = threading.Thread(target=authorize)
            rebind_thread = threading.Thread(target=bootstrap_successor)
            authorize_thread.start()
            assert entered_root_lookup.wait(timeout=3)
            rebind_thread.start()
            time.sleep(0.1)
            assert not bootstrap_done.is_set()
            release_root_lookup.set()
            authorize_thread.join(timeout=3)
            rebind_thread.join(timeout=3)
            assert not authorize_thread.is_alive()
            assert not rebind_thread.is_alive()
            assert authorization.get("ok") is True, authorization
            assert authorization.get("scope", {}).get("taskId") == contract_a["taskId"], authorization
            assert bootstrapped_b.get("ok") is True, bootstrapped_b
            successor_channel = str(bootstrapped_b.get("channelId", ""))
            assert successor_channel and successor_channel != channel, bootstrapped_b
            assert client.status(successor_channel).get("state") == "bound"
            client.close_channel(successor_channel)
        finally:
            try:
                server._project_root_for_context = original_root_lookup  # type: ignore[name-defined,method-assign]
            except (NameError, AttributeError):
                pass
            if channel:
                client.close_channel(channel)
            server.stop()
            control.close()
            client.close()


def test_provider_reopens_an_unbound_channel_after_broker_restart() -> None:
    """A legacy unbound transport may reopen after restart, never regain scope."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-provider-restart-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        first = ScopeBrokerServer(state)
        first.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        handle: BrokerChannelHandle | None = None
        second: ScopeBrokerServer | None = None
        try:
            contract = _contract(project)
            original_channel = _bootstrap_bound_channel(client, contract, project, access_mode="read")
            handle = BrokerChannelHandle(client, original_channel)
            provider = BrokerScopeProvider(client, handle)
            assert provider.authorize().get("ok") is True

            first.stop()
            second = ScopeBrokerServer(state)
            second.start()

            # Compatibility recovery may open a replacement transport channel,
            # but it must remain unbound. Production launcher channels set
            # ``allow_reopen_after_restart=False`` and return restart-required.
            recovered = provider.authorize()
            assert recovered.get("ok") is False, recovered
            assert recovered.get("code") == "H7_SCOPE_CHANNEL_UNBOUND", recovered
            assert handle.channel_id and handle.channel_id != original_channel
            retired = control.pair_channel(handle.channel_id, "sbw-" + "a" * 32, access_mode="read")
            assert retired.get("code") == "H7_SCOPE_PAIRING_CONTROL_RETIRED", retired
            assert provider.authorize().get("code") == "H7_SCOPE_CHANNEL_UNBOUND"
        finally:
            if handle is not None:
                handle.close_channel()
            if second is not None:
                second.stop()
            else:
                first.stop()
            control.close()
            client.close()


def test_provider_does_not_reopen_an_explicitly_closed_channel() -> None:
    """Same-instance revocation is not mistaken for a Broker restart."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-provider-close-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        handle: BrokerChannelHandle | None = None
        try:
            contract = _contract(project)
            channel = _bootstrap_bound_channel(client, contract, project, access_mode="read")
            handle = BrokerChannelHandle(client, channel)
            provider = BrokerScopeProvider(client, handle)
            assert provider.authorize().get("ok") is True

            closed = client.close_channel(channel)
            assert closed.get("code") == "H7_SCOPE_CHANNEL_CLOSED", closed
            denied = provider.authorize()
            assert denied.get("ok") is False, denied
            assert denied.get("code") == "H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", denied
            assert handle.channel_id == channel
        finally:
            if handle is not None:
                handle.close_channel()
            server.stop()
            control.close()
            client.close()


def test_provider_can_open_an_initially_empty_channel_without_pairing() -> None:
    """A transient startup failure can recover transport, never scope."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-provider-empty-") as directory:
        state = Path(directory) / "state"
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        handle = BrokerChannelHandle(client, "")
        provider = BrokerScopeProvider(client, handle)
        assert handle.channel_id == ""
        server = ScopeBrokerServer(state)
        server.start()
        try:
            status = provider.status()
            assert handle.channel_id
            assert status.get("code") == "H7_SCOPE_CHANNEL_UNBOUND", status
            assert status.get("state") == "unbound", status
        finally:
            handle.close_channel()
            server.stop()
            client.close()


def test_cli_bind_is_retired_without_private_capabilities() -> None:
    """The public CLI cannot select a channel/workline binding anymore."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-cli-bind-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "brain_cli.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(state / "shared"),
                "scope",
                "--action",
                "bind",
            ],
            cwd=str(project),
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=20,
        )
        assert completed.returncode == 0, completed.stderr
        payload = json.loads(completed.stdout)
        assert payload.get("ok") is False, payload
        assert payload.get("code") == "H7_SCOPE_SELECTOR_CONTROL_RETIRED", payload
        serialized = json.dumps(payload, ensure_ascii=False)
        for private_marker in ("leaseId", "h7Scope", "pairingToken", "sbpg-v1.", "sbl-", "projectRoot", "channelId", "worklineId"):
            assert private_marker not in serialized, payload
        broker_root = state / "workspace" / "runtime-state" / "scope-broker"
        assert not (broker_root / "endpoint.json").exists()
        assert not (broker_root / "registry.json").exists()


def test_existing_channel_calls_never_autostart_a_replacement() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-no-autostart-") as directory:
        state = Path(directory) / "state"
        server = ScopeBrokerServer(state)
        server.start()
        client = ScopeBrokerClient(state, auto_start=True, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        channel = client.open_channel()
        assert channel
        try:
            server.stop()
            result = client.status(channel)
            assert result.get("ok") is False, result
            assert result.get("code") in {"H7_SCOPE_BROKER_UNAVAILABLE", "H7_SCOPE_BROKER_ENDPOINT_INVALID"}, result
            assert client._process is None
        finally:
            client.close()


def test_unbound_channel_gets_a_pairing_grace_window() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-pair-grace-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state, idle_seconds=0.1, unbound_channel_grace_seconds=1.0)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        channel = ""
        try:
            contract = _contract(project)
            channel = client.open_channel()
            assert channel
            time.sleep(0.35)
            result = client.status(channel)
            assert result.get("ok") is True, result
            assert result.get("state") == "unbound", result
            assert result.get("code") == "H7_SCOPE_CHANNEL_UNBOUND", result
        finally:
            if channel:
                client.close_channel(channel)
            server.stop()
            control.close()
            client.close()


def test_bootstrap_bound_channel_is_atomic_and_ref_free() -> None:
    """Local bootstrap binds one current contract without an intermediate ref."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-bootstrap-atomic-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        try:
            contract = _contract(project)
            params = {
                "contract": contract,
                "expectedContractHash": _contract_hash(contract),
                "projectRoot": str(project),
                "accessMode": "write",
                "leaseSeconds": 300,
            }
            result = server._method("bootstrap_bound_channel", params)
            assert result.get("ok") is True, result
            channel = str(result.get("channelId", ""))
            assert channel.startswith("sbc-") and len(channel) == 36, result
            with server.broker._memory_lock:
                assert channel in server.broker._channels
                assert channel in server.broker._bindings
                assert channel not in server.broker._channel_pairing_refs
                assert not server.broker._pairing_requests
            binding = server.broker._bindings[channel]
            assert binding.context.workspace_key == contract["workspaceKey"]
            assert binding.context.owner_session_key == contract["ownerSessionKey"]
        finally:
            server.stop()


def test_bootstrap_bound_channel_rolls_back_registry_and_root_on_bind_failure() -> None:
    """A failed second write bootstrap leaves the first scope untouched."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-bootstrap-rollback-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        try:
            contract = _contract(project)
            params = {
                "contract": contract,
                "expectedContractHash": _contract_hash(contract),
                "projectRoot": str(project),
                "accessMode": "write",
                "leaseSeconds": 300,
            }
            first = server._method("bootstrap_bound_channel", params)
            assert first.get("ok") is True, first
            first_channel = str(first["channelId"])
            registry_path = state / "workspace" / "runtime-state" / "scope-broker" / "registry.json"
            roots_path = state / "workspace" / "runtime-state" / "scope-broker" / "project-roots.json"
            registry_before = registry_path.read_bytes()
            roots_before = roots_path.read_bytes()
            with server.broker._memory_lock:
                channels_before = set(server.broker._channels)
                bindings_before = dict(server.broker._bindings)
                leases_before = dict(server.broker._write_leases)

            failed = server._method("bootstrap_bound_channel", params)
            assert failed.get("ok") is False, failed
            assert failed.get("code") == "H7_SCOPE_WRITE_LEASE_HELD", failed
            assert registry_path.read_bytes() == registry_before
            assert roots_path.read_bytes() == roots_before
            with server.broker._memory_lock:
                assert server.broker._channels == channels_before
                assert server.broker._bindings == bindings_before
                assert server.broker._write_leases == leases_before
            assert first_channel in server.broker._bindings
        finally:
            server.stop()


def test_bootstrap_rolls_back_when_project_root_persist_fails() -> None:
    """A root-map write fault cannot leave a newly registered scope behind."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-bootstrap-persist-fault-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        try:
            first_contract = _contract(project)
            first = server._method(
                "bootstrap_bound_channel",
                {
                    "contract": first_contract,
                    "expectedContractHash": _contract_hash(first_contract),
                    "projectRoot": str(project),
                    "accessMode": "read",
                    "leaseSeconds": 300,
                },
            )
            assert first.get("ok") is True, first
            registry_path = state / "workspace" / "runtime-state" / "scope-broker" / "registry.json"
            roots_path = state / "workspace" / "runtime-state" / "scope-broker" / "project-roots.json"
            registry_before = registry_path.read_bytes()
            roots_before = roots_path.read_bytes()
            with server.broker._memory_lock:
                channels_before = set(server.broker._channels)
                bindings_before = dict(server.broker._bindings)
                leases_before = dict(server.broker._write_leases)

            second_contract = dict(first_contract)
            second_contract["taskId"] = "scope-broker-ipc-persist-fault"
            second_contract["taskInstanceId"] = "ti-" + "c" * 32
            original_persist = server._persist_project_roots
            server._persist_project_roots = lambda: False  # type: ignore[method-assign]
            try:
                failed = server._method(
                    "bootstrap_bound_channel",
                    {
                        "contract": second_contract,
                        "expectedContractHash": _contract_hash(second_contract),
                        "projectRoot": str(project),
                        "accessMode": "read",
                        "leaseSeconds": 300,
                    },
                )
            finally:
                server._persist_project_roots = original_persist  # type: ignore[method-assign]

            assert failed.get("ok") is False, failed
            assert failed.get("code") == "H7_SCOPE_PROJECT_ROOT_WRITE_FAILED", failed
            assert registry_path.read_bytes() == registry_before
            assert roots_path.read_bytes() == roots_before
            with server.broker._memory_lock:
                assert server.broker._channels == channels_before
                assert server.broker._bindings == bindings_before
                assert server.broker._write_leases == leases_before
        finally:
            server.stop()


def test_failed_bootstrap_rollback_invalidates_cached_project_roots() -> None:
    """A failed compensating restore must disable pre-fault root authority."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-bootstrap-rollback-fault-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        try:
            contract = _contract(project)
            params = {
                "contract": contract,
                "expectedContractHash": _contract_hash(contract),
                "projectRoot": str(project),
                "accessMode": "write",
                "leaseSeconds": 300,
            }
            first = server._method("bootstrap_bound_channel", params)
            assert first.get("ok") is True, first
            original_restore = server._restore_private_file
            server._restore_private_file = lambda _path, _snapshot: False  # type: ignore[method-assign]
            try:
                failed = server._method("bootstrap_bound_channel", params)
            finally:
                server._restore_private_file = original_restore  # type: ignore[method-assign]

            assert failed.get("ok") is False, failed
            assert failed.get("code") == "H7_SCOPE_BOOTSTRAP_ROLLBACK_FAILED", failed
            with server._project_root_lock:
                assert server._project_root_registry_invalid is True
                assert server._project_roots == {}
            workline = server.broker.get_workline(next(iter(server.broker._write_leases)))
            assert workline.ok and workline.context is not None
            assert server._project_root_for_context(workline.context) == ""
            assert server._project_root_failure_code(workline.context) == "H7_SCOPE_PROJECT_ROOT_REGISTRY_INVALID"
        finally:
            server.stop()


def test_bootstrap_bound_channel_rejects_invalid_inputs_without_side_effects() -> None:
    """Validation failures do not create channels or mutate durable state."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-bootstrap-validation-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        foreign = Path(directory) / "foreign"
        project.mkdir()
        foreign.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        try:
            contract = _contract(project)
            base = {
                "contract": contract,
                "expectedContractHash": _contract_hash(contract),
                "projectRoot": str(project),
                "accessMode": "write",
                "leaseSeconds": 300,
            }
            invalid_mode = server._method("bootstrap_bound_channel", {**base, "accessMode": "admin"})
            assert invalid_mode.get("code") == "H7_SCOPE_ACCESS_MODE_INVALID", invalid_mode
            mismatch = server._method("bootstrap_bound_channel", {**base, "projectRoot": str(foreign)})
            assert mismatch.get("code") == "H7_SCOPE_PROJECT_ROOT_MISMATCH", mismatch
            registry_path = state / "workspace" / "runtime-state" / "scope-broker" / "registry.json"
            roots_path = state / "workspace" / "runtime-state" / "scope-broker" / "project-roots.json"
            assert not registry_path.exists()
            assert not roots_path.exists()
            with server.broker._memory_lock:
                assert not server.broker._channels
                assert not server.broker._bindings
                assert not server.broker._write_leases
        finally:
            server.stop()


def test_bootstrap_bound_channel_withholds_tampered_root_registry() -> None:
    """Bootstrap cannot silently repair a malformed private root map."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-bootstrap-root-invalid-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        try:
            contract = _contract(project)
            first = server._method(
                "bootstrap_bound_channel",
                {
                    "contract": contract,
                    "expectedContractHash": _contract_hash(contract),
                    "projectRoot": str(project),
                    "accessMode": "read",
                    "leaseSeconds": 300,
                },
            )
            assert first.get("ok") is True, first
            first_channel = str(first["channelId"])
            roots_path = state / "workspace" / "runtime-state" / "scope-broker" / "project-roots.json"
            tampered = json.loads(roots_path.read_text(encoding="utf-8"))
            tampered["roots"][next(iter(tampered["roots"]))]["unexpected"] = "nope"
            tampered["payloadHash"] = _canonical_hash({key: value for key, value in tampered.items() if key != "payloadHash"})
            roots_path.write_text(json.dumps(tampered, separators=(",", ":")), encoding="utf-8")
            server._load_project_roots()
            before_registry = (state / "workspace" / "runtime-state" / "scope-broker" / "registry.json").read_bytes()
            before_roots = roots_path.read_bytes()
            failed = server._method(
                "bootstrap_bound_channel",
                {
                    "contract": contract,
                    "expectedContractHash": _contract_hash(contract),
                    "projectRoot": str(project),
                    "accessMode": "read",
                    "leaseSeconds": 300,
                },
            )
            assert failed.get("code") == "H7_SCOPE_PROJECT_ROOT_REGISTRY_INVALID", failed
            assert (state / "workspace" / "runtime-state" / "scope-broker" / "registry.json").read_bytes() == before_registry
            assert roots_path.read_bytes() == before_roots
            with server.broker._memory_lock:
                assert set(server.broker._channels) == {first_channel}
        finally:
            server.stop()


def test_repair_local_scope_rebuilds_only_the_current_contract_root_proof() -> None:
    """Explicit repair restores a poisoned root map without opening a channel."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-local-repair-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        try:
            contract = _contract(project)
            first = server._method(
                "bootstrap_bound_channel",
                {
                    "contract": contract,
                    "expectedContractHash": _contract_hash(contract),
                    "projectRoot": str(project),
                    "accessMode": "read",
                    "leaseSeconds": 300,
                },
            )
            assert first.get("ok") is True, first
            channel = str(first["channelId"])
            roots_path = state / "workspace" / "runtime-state" / "scope-broker" / "project-roots.json"
            tampered = json.loads(roots_path.read_text(encoding="utf-8"))
            tampered["roots"][next(iter(tampered["roots"]))]["unexpected"] = "nope"
            tampered["payloadHash"] = _canonical_hash({key: value for key, value in tampered.items() if key != "payloadHash"})
            roots_path.write_text(json.dumps(tampered, separators=(",", ":")), encoding="utf-8")
            server._load_project_roots()
            with server._project_root_lock:
                assert server._project_root_registry_invalid is True
            with server.broker._memory_lock:
                channels_before = set(server.broker._channels)
                bindings_before = dict(server.broker._bindings)
                binding_objects_before = {channel_id: id(binding) for channel_id, binding in server.broker._bindings.items()}

            original_register = server.broker.register_workline

            def forbidden_register(*_args: object, **_kwargs: object) -> object:
                raise AssertionError("repair_local_scope must not call register_workline")

            server.broker.register_workline = forbidden_register  # type: ignore[method-assign]

            try:
                repaired = server._method(
                    "repair_local_scope",
                    {
                        "contract": contract,
                        "expectedContractHash": _contract_hash(contract),
                        "projectRoot": str(project),
                    },
                )
            finally:
                server.broker.register_workline = original_register  # type: ignore[method-assign]
            assert repaired.get("ok") is True, repaired
            assert repaired.get("code") == "H7_SCOPE_PROJECT_ROOT_REPAIRED", repaired
            assert "channelId" not in repaired and "scope" not in repaired, repaired
            with server._project_root_lock:
                assert server._project_root_registry_invalid is False
            with server.broker._memory_lock:
                assert server.broker._channels == channels_before == {channel}
                assert server.broker._bindings == bindings_before
                assert {channel_id: id(binding) for channel_id, binding in server.broker._bindings.items()} == binding_objects_before
            context = server.broker._bindings[channel].context
            assert server._project_root_for_context(context) == str(project.resolve())
        finally:
            server.stop()


def test_repair_local_scope_requires_an_existing_exact_workline_without_mutation() -> None:
    """Repair cannot create or refresh a workline while rebuilding roots."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-local-repair-rebind-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        try:
            contract = _contract(project)
            first = server._method(
                "bootstrap_bound_channel",
                {
                    "contract": contract,
                    "expectedContractHash": _contract_hash(contract),
                    "projectRoot": str(project),
                    "accessMode": "read",
                    "leaseSeconds": 300,
                },
            )
            assert first.get("ok") is True, first
            registry_path = state / "workspace" / "runtime-state" / "scope-broker" / "registry.json"
            roots_path = state / "workspace" / "runtime-state" / "scope-broker" / "project-roots.json"

            # Put the root map in the explicit repair state, then present a
            # same-workline but newer contract.  Repair must not turn that
            # mismatch into a durable refresh/rebind.
            tampered = json.loads(roots_path.read_text(encoding="utf-8"))
            workline_id = next(iter(tampered["roots"]))
            tampered["roots"][workline_id]["unexpected"] = "repair-must-not-refresh"
            tampered["payloadHash"] = _canonical_hash({key: value for key, value in tampered.items() if key != "payloadHash"})
            roots_path.write_text(json.dumps(tampered, separators=(",", ":")), encoding="utf-8")
            registry_before = registry_path.read_bytes()
            roots_before = roots_path.read_bytes()
            with server.broker._memory_lock:
                bindings_before = dict(server.broker._bindings)
                binding_objects_before = {channel: id(binding) for channel, binding in server.broker._bindings.items()}
                channels_before = set(server.broker._channels)
                leases_before = dict(server.broker._write_leases)

            newer = dict(contract)
            newer["revision"] = int(contract["revision"]) + 1
            original_register = server.broker.register_workline

            def forbidden_register(*_args: object, **_kwargs: object) -> object:
                raise AssertionError("repair_local_scope must not call register_workline")

            server.broker.register_workline = forbidden_register  # type: ignore[method-assign]
            try:
                failed = server._method(
                    "repair_local_scope",
                    {
                        "contract": newer,
                        "expectedContractHash": _contract_hash(newer),
                        "projectRoot": str(project),
                    },
                )
            finally:
                server.broker.register_workline = original_register  # type: ignore[method-assign]

            assert failed == {
                "ok": False,
                "code": "H7_SCOPE_REPAIR_REBIND_REQUIRED",
                "state": "withheld",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }, failed
            assert registry_path.read_bytes() == registry_before
            assert roots_path.read_bytes() == roots_before
            with server.broker._memory_lock:
                assert server.broker._channels == channels_before
                assert server.broker._bindings == bindings_before
                assert {channel: id(binding) for channel, binding in server.broker._bindings.items()} == binding_objects_before
                assert server.broker._write_leases == leases_before
        finally:
            server.stop()


def test_legacy_pairing_control_is_retired_without_state_mutation() -> None:
    """Retired selector/ref controls cannot bind or mutate live channels."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-pairing-ref-") as directory:
        state = Path(directory) / "state"
        server = ScopeBrokerServer(state)
        server.start()
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        client_a = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        client_b = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        channels: list[tuple[ScopeBrokerClient, str]] = []
        try:
            channel_a = client_a.open_channel()
            channel_b = client_b.open_channel()
            channels.extend(((client_a, channel_a), (client_b, channel_b)))
            ref_a = client_a.last_pairing_request_ref
            ref_b = client_b.last_pairing_request_ref
            assert channel_a and channel_b and ref_a and ref_b
            assert ref_a.startswith("sbpr-") and ref_b.startswith("sbpr-") and ref_a != ref_b
            assert client_a.status(channel_a).get("pairingRequestRef") == ref_a
            assert client_b.status(channel_b).get("pairingRequestRef") == ref_b

            listed = control.list_channels().get("channels", [])
            assert {str(item.get("channelId", "")) for item in listed if isinstance(item, dict)} >= {channel_a, channel_b}, listed
            # Pairing refs belong exclusively to the MCP connection that
            # received them from open/status.  The global control-plane list
            # must not expose another connection's opaque pairing capability.
            listed_serialized = json.dumps(listed, ensure_ascii=False)
            assert "pairingRequestRef" not in listed_serialized, listed
            assert ref_a not in listed_serialized and ref_b not in listed_serialized, listed

            retired_a = control.pair_request(ref_a, "sbw-" + "a" * 32, access_mode="read")
            retired_b = control.pair_channel(channel_b, "sbw-" + "b" * 32, access_mode="read")
            assert retired_a.get("ok") is False and retired_a.get("code") == "H7_SCOPE_PAIRING_CONTROL_RETIRED", retired_a
            assert retired_b.get("ok") is False and retired_b.get("code") == "H7_SCOPE_PAIRING_CONTROL_RETIRED", retired_b

            status_a = client_a.status(channel_a)
            status_b = client_b.status(channel_b)
            assert status_a.get("state") == "unbound" and status_b.get("state") == "unbound"
            serialized = json.dumps({"listed": listed, "a": status_a, "b": status_b}, ensure_ascii=False)
            for private_marker in ("leaseId", "pairingToken", "sbpg-v1.", "sbl-", "projectRoot"):
                assert private_marker not in serialized, serialized
        finally:
            for client, channel in channels:
                if channel:
                    try:
                        client.close_channel(channel)
                    except Exception:
                        pass
            server.stop()
            control.close()
            client_a.close()
            client_b.close()


def test_channel_activity_index_ignores_unknown_authenticated_ids() -> None:
    """Rejected channel IDs cannot grow the Broker's activity map."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-touch-bound-") as directory:
        state = Path(directory) / "state"
        server = ScopeBrokerServer(state, idle_seconds=None)
        server.start()
        try:
            bundle = _read_endpoint_bundle(server.endpoint_path, server.secret_path)
            assert bundle is not None
            secret = bundle[1]
            for index in range(256):
                channel = "sbc-" + f"{index:032x}"
                request = _signed(secret, "status", {"channelId": channel}, f"touch-{index:024d}")
                result = server._dispatch(request)
                assert result["ok"] is False
                assert result["code"] == "H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED"
            assert server._channel_last_seen == {}
        finally:
            server.stop()


def main() -> None:
    test_server_singleton_and_secret_fingerprint()
    test_authenticated_nonce_is_one_shot()
    test_endpoint_bundle_rejects_oversized_metadata()
    test_pairing_tokens_cannot_cross_ipc()
    test_concurrent_clients_spawn_one_child()
    test_owner_close_preserves_a_shared_bound_channel()
    test_shutdown_if_idle_requires_the_expected_broker_instance()
    test_read_only_control_close_preserves_a_warm_idle_broker()
    test_stale_endpoint_is_replaced()
    test_repeated_stop_cannot_remove_a_new_broker_endpoint()
    test_project_root_survives_broker_restart_and_pair_stays_public()
    test_bootstrap_withholds_tampered_private_root_state()
    test_bootstrap_rechecks_a_deleted_project_root()
    test_bound_status_withholds_after_project_root_disappears()
    test_authorize_root_check_is_atomic_against_concurrent_bootstrap()
    test_provider_reopens_an_unbound_channel_after_broker_restart()
    test_provider_does_not_reopen_an_explicitly_closed_channel()
    test_provider_can_open_an_initially_empty_channel_without_pairing()
    test_cli_bind_is_retired_without_private_capabilities()
    test_existing_channel_calls_never_autostart_a_replacement()
    test_unbound_channel_gets_a_pairing_grace_window()
    test_bootstrap_bound_channel_is_atomic_and_ref_free()
    test_bootstrap_bound_channel_rolls_back_registry_and_root_on_bind_failure()
    test_bootstrap_rolls_back_when_project_root_persist_fails()
    test_failed_bootstrap_rollback_invalidates_cached_project_roots()
    test_bootstrap_bound_channel_rejects_invalid_inputs_without_side_effects()
    test_bootstrap_bound_channel_withholds_tampered_root_registry()
    test_repair_local_scope_rebuilds_only_the_current_contract_root_proof()
    test_repair_local_scope_requires_an_existing_exact_workline_without_mutation()
    test_legacy_pairing_control_is_retired_without_state_mutation()
    test_channel_activity_index_ignores_unknown_authenticated_ids()
    print("runtime_scope_broker_ipc_regression: PASS")


if __name__ == "__main__":
    main()
