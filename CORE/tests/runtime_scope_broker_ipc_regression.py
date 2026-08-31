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
            peer_channel = peer.open_channel()
            assert peer_channel

            contract = _contract(project)
            registration = control.register_workline(contract, expected_contract_hash=_contract_hash(contract), project_root=project)
            assert registration.get("ok") is True, registration
            workline = str(registration.get("scope", {}).get("worklineId", ""))
            assert workline
            attachment = control.pair_channel(peer_channel, workline, access_mode="read")
            assert attachment.get("ok") is True, attachment

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
            registration = control.register_workline(
                contract,
                expected_contract_hash=_contract_hash(contract),
                project_root=project,
            )
            assert registration.get("ok") is True, registration
            workline = str(registration.get("scope", {}).get("worklineId", ""))
            assert workline
            first.stop()

            second = ScopeBrokerServer(state)
            second.start()
            try:
                channel = client.open_channel()
                assert channel
                attached = control.pair_channel(channel, workline, access_mode="read")
                assert attached.get("ok") is True, attached
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


def test_pair_requires_root_repair_when_private_root_state_is_tampered() -> None:
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
            registration = control.register_workline(contract, expected_contract_hash=_contract_hash(contract), project_root=project)
            assert registration.get("ok") is True, registration
            workline = str(registration["scope"]["worklineId"])
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
                channel = client.open_channel()
                result = control.pair_channel(channel, workline, access_mode="read")
                assert result.get("ok") is False, result
                assert result.get("code") == "H7_SCOPE_PROJECT_ROOT_REGISTRY_INVALID", result
            finally:
                if channel:
                    client.close_channel(channel)
                restarted.stop()
        finally:
            control.close()
            client.close()


def test_pair_rechecks_a_deleted_project_root() -> None:
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
            registration = control.register_workline(contract, expected_contract_hash=_contract_hash(contract), project_root=project)
            assert registration.get("ok") is True, registration
            workline = str(registration["scope"]["worklineId"])
            project.rmdir()
            channel = client.open_channel()
            result = control.pair_channel(channel, workline, access_mode="read")
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
            registration = control.register_workline(contract, expected_contract_hash=_contract_hash(contract), project_root=project)
            assert registration.get("ok") is True, registration
            channel = client.open_channel()
            assert channel
            assert control.pair_channel(channel, str(registration["scope"]["worklineId"]), access_mode="read").get("ok") is True
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


def test_authorize_root_check_is_atomic_against_channel_rebind() -> None:
    """A root proof cannot race a detach/re-pair into a stale scope reply."""

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
            registered_a = control.register_workline(
                contract_a,
                expected_contract_hash=_contract_hash(contract_a),
                project_root=project_a,
            )
            registered_b = control.register_workline(
                contract_b,
                expected_contract_hash=_contract_hash(contract_b),
                project_root=project_b,
            )
            assert registered_a.get("ok") is True, registered_a
            assert registered_b.get("ok") is True, registered_b
            workline_a = str(registered_a["scope"]["worklineId"])
            workline_b = str(registered_b["scope"]["worklineId"])
            channel = client.open_channel()
            assert channel
            assert control.pair_channel(channel, workline_a, access_mode="read").get("ok") is True

            original_root_lookup = server._project_root_for_context
            entered_root_lookup = threading.Event()
            release_root_lookup = threading.Event()

            def paused_root_lookup(context: object) -> str:
                entered_root_lookup.set()
                assert release_root_lookup.wait(timeout=3)
                return original_root_lookup(context)

            server._project_root_for_context = paused_root_lookup  # type: ignore[method-assign]
            authorization: dict[str, object] = {}
            rebind: dict[str, object] = {}
            rebind_done = threading.Event()

            def authorize() -> None:
                authorization.update(server._method("authorize", {"channelId": channel}))

            def detach_and_rebind() -> None:
                server._method("detach_channel", {"channelId": channel})
                rebind.update(
                    server._method(
                        "pair_channel",
                        {"channelId": channel, "worklineId": workline_b, "accessMode": "read"},
                    )
                )
                rebind_done.set()

            authorize_thread = threading.Thread(target=authorize)
            rebind_thread = threading.Thread(target=detach_and_rebind)
            authorize_thread.start()
            assert entered_root_lookup.wait(timeout=3)
            rebind_thread.start()
            time.sleep(0.1)
            assert not rebind_done.is_set()
            release_root_lookup.set()
            authorize_thread.join(timeout=3)
            rebind_thread.join(timeout=3)
            assert not authorize_thread.is_alive()
            assert not rebind_thread.is_alive()
            assert authorization.get("ok") is True, authorization
            assert authorization.get("scope", {}).get("taskId") == contract_a["taskId"]
            assert rebind.get("ok") is True, rebind
        finally:
            try:
                server._project_root_for_context = original_root_lookup  # type: ignore[name-defined,method-assign]
            except (NameError, AttributeError):
                pass
            if "channel" in locals() and channel:
                client.close_channel(channel)
            server.stop()
            control.close()
            client.close()


def test_provider_reopens_only_an_unbound_channel_after_broker_restart() -> None:
    """Restart recovery may reopen transport, but pairing remains explicit."""

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
            registration = control.register_workline(contract, expected_contract_hash=_contract_hash(contract), project_root=project)
            assert registration.get("ok") is True, registration
            workline = str(registration["scope"]["worklineId"])
            original_channel = client.open_channel()
            assert original_channel
            assert control.pair_channel(original_channel, workline, access_mode="read").get("ok") is True
            handle = BrokerChannelHandle(client, original_channel)
            provider = BrokerScopeProvider(client, handle)
            assert provider.authorize().get("ok") is True

            first.stop()
            second = ScopeBrokerServer(state)
            second.start()

            # The old channel is rejected, then exactly one replacement opens.
            # It carries no scope until the control plane pairs it explicitly.
            recovered = provider.authorize()
            assert recovered.get("ok") is False, recovered
            assert recovered.get("code") == "H7_SCOPE_CHANNEL_UNBOUND", recovered
            assert handle.channel_id and handle.channel_id != original_channel
            assert control.pair_channel(handle.channel_id, workline, access_mode="read").get("ok") is True
            assert provider.authorize().get("ok") is True
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
            registration = control.register_workline(contract, expected_contract_hash=_contract_hash(contract), project_root=project)
            assert registration.get("ok") is True, registration
            workline = str(registration["scope"]["worklineId"])
            channel = client.open_channel()
            assert channel
            assert control.pair_channel(channel, workline, access_mode="read").get("ok") is True
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


def test_cli_bind_stdout_never_emits_private_capabilities() -> None:
    """The public CLI control path must match the IPC secrecy boundary."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-cli-bind-") as directory:
        state = Path(directory) / "state"
        project = Path(directory) / "project"
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        client = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        channel = ""
        try:
            contract = _contract(project)
            registration = control.register_workline(contract, expected_contract_hash=_contract_hash(contract), project_root=project)
            assert registration.get("ok") is True, registration
            channel = client.open_channel()
            assert channel
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
                    "--channel-id",
                    channel,
                    "--workline-id",
                    str(registration["scope"]["worklineId"]),
                    "--access-mode",
                    "read",
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                check=False,
                timeout=20,
            )
            assert completed.returncode == 0, completed.stderr
            payload = json.loads(completed.stdout)
            assert payload.get("ok") is True, payload
            serialized = json.dumps(payload, ensure_ascii=False)
            for private_marker in ("leaseId", "h7Scope", "pairingToken", "sbpg-v1.", "sbl-", "projectRoot"):
                assert private_marker not in serialized, payload
        finally:
            if channel:
                client.close_channel(channel)
            server.stop()
            control.close()
            client.close()


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
            registration = control.register_workline(contract, expected_contract_hash=_contract_hash(contract), project_root=project)
            assert registration.get("ok") is True, registration
            channel = client.open_channel()
            assert channel
            time.sleep(0.35)
            result = control.pair_channel(channel, str(registration["scope"]["worklineId"]), access_mode="read")
            assert result.get("ok") is True, result
        finally:
            if channel:
                client.close_channel(channel)
            server.stop()
            control.close()
            client.close()


def test_pairing_request_ref_routes_exact_concurrent_channels() -> None:
    """The control plane pairs the connection that issued each ref."""

    with tempfile.TemporaryDirectory(prefix="super-brain-ipc-pairing-ref-") as directory:
        state = Path(directory) / "state"
        project_a = Path(directory) / "project-a"
        project_b = Path(directory) / "project-b"
        project_a.mkdir()
        project_b.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        runtime = ROOT / "runtime" / "scope_broker_ipc.py"
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=runtime)
        client_a = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        client_b = ScopeBrokerClient(state, auto_start=False, runtime_path=runtime)
        channels: list[tuple[ScopeBrokerClient, str]] = []
        try:
            registrations = []
            for project in (project_a, project_b):
                value = _contract(project)
                registration = control.register_workline(
                    value,
                    expected_contract_hash=_contract_hash(value),
                    project_root=project,
                )
                assert registration.get("ok") is True, registration
                registrations.append(registration)

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

            results: list[dict[str, object] | None] = [None, None]

            def pair(index: int, ref: str, registration: dict[str, object]) -> None:
                results[index] = control.pair_request(
                    ref,
                    str(registration["scope"]["worklineId"]),
                    access_mode="read",
                )

            threads = [
                threading.Thread(target=pair, args=(0, ref_a, registrations[0])),
                threading.Thread(target=pair, args=(1, ref_b, registrations[1])),
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=8)
            assert all(isinstance(result, dict) and result.get("ok") is True for result in results), results

            status_a = client_a.status(channel_a)
            status_b = client_b.status(channel_b)
            assert status_a.get("state") == "bound" and status_b.get("state") == "bound"
            assert status_a.get("scope", {}).get("workspaceKey") == registrations[0]["scope"]["workspaceKey"], status_a
            assert status_b.get("scope", {}).get("workspaceKey") == registrations[1]["scope"]["workspaceKey"], status_b
            assert "pairingRequestRef" not in status_a and "pairingRequestRef" not in status_b

            replay = control.pair_request(ref_a, str(registrations[0]["scope"]["worklineId"]), access_mode="read")
            assert replay.get("ok") is False, replay
            serialized = json.dumps({"listed": listed, "results": results, "a": status_a, "b": status_b}, ensure_ascii=False)
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
    test_stale_endpoint_is_replaced()
    test_repeated_stop_cannot_remove_a_new_broker_endpoint()
    test_project_root_survives_broker_restart_and_pair_stays_public()
    test_pair_requires_root_repair_when_private_root_state_is_tampered()
    test_pair_rechecks_a_deleted_project_root()
    test_bound_status_withholds_after_project_root_disappears()
    test_authorize_root_check_is_atomic_against_channel_rebind()
    test_provider_reopens_only_an_unbound_channel_after_broker_restart()
    test_provider_does_not_reopen_an_explicitly_closed_channel()
    test_provider_can_open_an_initially_empty_channel_without_pairing()
    test_cli_bind_stdout_never_emits_private_capabilities()
    test_existing_channel_calls_never_autostart_a_replacement()
    test_unbound_channel_gets_a_pairing_grace_window()
    test_pairing_request_ref_routes_exact_concurrent_channels()
    test_channel_activity_index_ignores_unknown_authenticated_ids()
    print("runtime_scope_broker_ipc_regression: PASS")


if __name__ == "__main__":
    main()
