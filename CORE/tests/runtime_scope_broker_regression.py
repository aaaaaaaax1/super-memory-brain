from __future__ import annotations

import hashlib
import inspect
import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from scope_broker import ScopeBroker


NOW = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)


def contract(*, revision: int = 7, marker: str = "do-not-persist-contract-body") -> dict[str, object]:
    return {
        "schema": "super-brain.execution-contract.v1",
        "status": "active",
        "taskId": "task-scope-broker-regression",
        "taskInstanceId": "ti-" + "a" * 32,
        "workspaceKey": "ws-" + "b" * 24,
        "ownerSessionKey": "sid-" + "c" * 24,
        "packageVersion": "1.0.0",
        "revision": revision,
        # This field is intentionally not part of the registry projection. It
        # proves the broker retains an H7 hash rather than a contract body.
        "currentStep": marker,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def canonical_contract_hash(value: dict[str, object]) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def register(broker: ScopeBroker, value: dict[str, object]) -> str:
    result = broker.register_workline(value, expected_contract_hash=canonical_contract_hash(value), now=NOW)
    assert result.ok and result.code == "H7_SCOPE_WORKLINE_CURRENT"
    assert result.context is not None
    return result.context.workline_id


def test_unbound_pair_foreign_replay_and_write_lease() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-broker-") as directory:
        state_root = Path(directory) / "state"
        broker = ScopeBroker(state_root)
        workline_id = register(broker, contract())
        channel_a = broker.open_channel()
        channel_b = broker.open_channel()

        unbound = broker.status(channel_a, now=NOW)
        assert unbound.ok and unbound.code == "H7_SCOPE_CHANNEL_UNBOUND" and unbound.state == "unbound"
        # Status is healthy for a known channel, but authorization may never
        # turn that transport-level success into a scope grant.
        unbound_authorization = broker.authorize(channel_a, now=NOW)
        assert not unbound_authorization.ok
        assert unbound_authorization.code == "H7_SCOPE_CHANNEL_UNBOUND"
        assert unbound_authorization.state == "unbound"

        grant_a = broker.issue_pairing_grant(channel_a, workline_id, access_mode="write", ttl_seconds=60, now=NOW)
        assert not isinstance(grant_a, type(unbound))

        foreign = broker.attach_channel(channel_b, grant_a.token, now=NOW)
        assert not foreign.ok and foreign.code == "H7_SCOPE_PAIRING_GRANT_CHANNEL_MISMATCH"

        bound = broker.attach_channel(channel_a, grant_a.token, lease_seconds=15, now=NOW)
        assert bound.ok and bound.code == "H7_SCOPE_CHANNEL_BOUND" and bound.access_mode == "write"
        assert bound.context is not None and bound.context.workline_id == workline_id
        assert broker.authorize(channel_a, write=True, now=NOW).ok

        read_grant = broker.issue_pairing_grant(channel_b, workline_id, access_mode="read", ttl_seconds=60, now=NOW)
        read_bound = broker.attach_channel(channel_b, read_grant.token, now=NOW)
        assert read_bound.ok and read_bound.access_mode == "read"
        assert broker.authorize(channel_b, write=False, now=NOW).ok
        read_write = broker.authorize(channel_b, write=True, now=NOW)
        assert not read_write.ok and read_write.code == "H7_SCOPE_WRITE_LEASE_REQUIRED"

        detached = broker.detach_channel(channel_a)
        assert detached.ok and detached.code == "H7_SCOPE_CHANNEL_DETACHED"
        replay = broker.attach_channel(channel_a, grant_a.token, now=NOW)
        assert not replay.ok and replay.code == "H7_SCOPE_PAIRING_GRANT_REPLAYED"

        # Normal tool projections never expose a renewal capability.
        assert "leaseId" not in bound.public_projection()
        assert broker.authorize(channel_b, write="yes", now=NOW).code == "H7_SCOPE_WRITE_FLAG_INVALID"


def test_expired_grants_and_leases_fail_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-broker-") as directory:
        broker = ScopeBroker(Path(directory) / "state")
        workline_id = register(broker, contract())

        expired_channel = broker.open_channel()
        expired_grant = broker.issue_pairing_grant(expired_channel, workline_id, ttl_seconds=1, now=NOW)
        expired = broker.attach_channel(expired_channel, expired_grant.token, now=NOW + timedelta(seconds=1))
        assert not expired.ok and expired.code == "H7_SCOPE_PAIRING_GRANT_EXPIRED"

        leased_channel = broker.open_channel()
        lease_grant = broker.issue_pairing_grant(leased_channel, workline_id, ttl_seconds=60, now=NOW)
        bound = broker.attach_channel(leased_channel, lease_grant.token, lease_seconds=15, now=NOW)
        assert bound.ok
        lease_expired = broker.status(leased_channel, now=NOW + timedelta(seconds=15))
        assert not lease_expired.ok and lease_expired.code == "H7_SCOPE_CHANNEL_LEASE_EXPIRED"
        assert broker.status(leased_channel, now=NOW + timedelta(seconds=16)).code == "H7_SCOPE_CHANNEL_UNBOUND"


def test_pairing_request_ref_is_scoped_short_lived_and_one_shot() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-broker-ref-") as directory:
        broker = ScopeBroker(Path(directory) / "state")
        workline_id = register(broker, contract())
        channel, pairing_ref = broker.open_channel_with_ref(now=NOW)
        assert pairing_ref.startswith("sbpr-") and len(pairing_ref) == 37
        first = broker.status(channel, now=NOW)
        assert first.ok and first["pairingRequestRef"] == pairing_ref
        assert broker.pairing_request_ref(channel, now=NOW) == pairing_ref

        bound = broker.pair_request(pairing_ref, workline_id, access_mode="read", now=NOW)
        assert bound.ok and bound.code == "H7_SCOPE_CHANNEL_BOUND"
        assert broker.pairing_request_ref(channel, now=NOW) == ""
        assert "pairingRequestRef" not in broker.status(channel, now=NOW).public_projection()
        replay = broker.pair_request(pairing_ref, workline_id, access_mode="read", now=NOW)
        assert not replay.ok and replay.code in {
            "H7_SCOPE_PAIRING_REQUEST_REF_EXPIRED",
            "H7_SCOPE_PAIRING_REQUEST_REF_INVALID",
        }


def test_pairing_request_ref_expires_and_refreshes_without_rebinding_scope() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-broker-ref-expiry-") as directory:
        broker = ScopeBroker(Path(directory) / "state")
        workline_id = register(broker, contract())
        channel, old_ref = broker.open_channel_with_ref(now=NOW)
        expired = broker.status(channel, now=NOW + timedelta(seconds=301))
        assert expired.ok and expired.state == "unbound"
        new_ref = str(expired["pairingRequestRef"])
        assert new_ref.startswith("sbpr-") and new_ref != old_ref
        stale = broker.pair_request(old_ref, workline_id, access_mode="read", now=NOW + timedelta(seconds=301))
        assert not stale.ok and stale.code == "H7_SCOPE_PAIRING_REQUEST_REF_EXPIRED"
        assert broker.pair_request(new_ref, workline_id, access_mode="read", now=NOW + timedelta(seconds=301)).ok


def test_pairing_request_ref_concurrent_consumption_binds_once() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-broker-ref-concurrent-") as directory:
        broker = ScopeBroker(Path(directory) / "state")
        workline_id = register(broker, contract())
        channel, pairing_ref = broker.open_channel_with_ref(now=NOW)
        import concurrent.futures

        def consume() -> str:
            return broker.pair_request(pairing_ref, workline_id, access_mode="read", now=NOW).code

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            codes = list(executor.map(lambda _: consume(), range(8)))
        assert codes.count("H7_SCOPE_CHANNEL_BOUND") == 1, codes
        assert all(code in {"H7_SCOPE_CHANNEL_BOUND", "H7_SCOPE_PAIRING_REQUEST_REF_EXPIRED", "H7_SCOPE_PAIRING_REQUEST_REF_INVALID", "H7_SCOPE_CHANNEL_ALREADY_BOUND"} for code in codes), codes
        assert broker.authorize(channel, write=False, now=NOW).ok


def test_registry_survives_restart_but_channels_and_grants_do_not() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-broker-") as directory:
        state_root = Path(directory) / "state"
        first = ScopeBroker(state_root)
        value = contract(marker="contract-content-must-not-enter-registry")
        workline_id = register(first, value)
        old_channel = first.open_channel()
        old_grant = first.issue_pairing_grant(old_channel, workline_id, now=NOW)
        assert first.attach_channel(old_channel, old_grant.token, now=NOW).ok

        registry_path = state_root / "workspace" / "runtime-state" / "scope-broker" / "registry.json"
        registry_text = registry_path.read_text(encoding="utf-8")
        assert "contract-content-must-not-enter-registry" not in registry_text
        assert "currentStep" not in registry_text
        assert "contractHash" in registry_text

        restarted = ScopeBroker(state_root)
        assert restarted.status(old_channel, now=NOW).code == "H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED"
        recovered = restarted.get_workline(workline_id)
        assert recovered.ok and recovered.context is not None
        assert recovered.context.contract_hash == canonical_contract_hash(value)

        new_channel = restarted.open_channel()
        assert restarted.status(new_channel, now=NOW).code == "H7_SCOPE_CHANNEL_UNBOUND"
        # Grants are deliberately process-local; explicit pairing is required
        # after restart even though the workline registry is durable.
        assert restarted.attach_channel(new_channel, old_grant.token, now=NOW).code == "H7_SCOPE_PAIRING_GRANT_INVALID"
        new_grant = restarted.issue_pairing_grant(new_channel, workline_id, now=NOW)
        assert restarted.attach_channel(new_channel, new_grant.token, now=NOW).ok


def test_contract_hash_conflicts_and_host_identity_dependencies_are_rejected() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-broker-") as directory:
        broker = ScopeBroker(Path(directory) / "state")
        original = contract(revision=7, marker="first")
        register(broker, original)

        changed_same_revision = contract(revision=7, marker="different")
        conflict = broker.register_workline(
            changed_same_revision,
            expected_contract_hash=canonical_contract_hash(changed_same_revision),
            now=NOW,
        )
        assert not conflict.ok and conflict.code == "H7_SCOPE_CONTRACT_HASH_CONFLICT"

        updated = contract(revision=8, marker="different")
        current = broker.register_workline(updated, expected_contract_hash=canonical_contract_hash(updated), now=NOW)
        assert current.ok and current.context is not None and current.context.contract_revision == 8
        wrong_hash = broker.register_workline(updated, expected_contract_hash="0" * 64, now=NOW)
        assert not wrong_hash.ok and wrong_hash.code == "H7_SCOPE_CONTRACT_HASH_MISMATCH"
        missing_hash = broker.register_workline(updated, now=NOW)
        assert not missing_hash.ok and missing_hash.code == "H7_SCOPE_CONTRACT_HASH_REQUIRED"

    source = inspect.getsource(sys.modules["scope_broker"])
    assert "CODEX_THREAD_ID" not in source
    assert "SUPER_BRAIN_LOCAL_SESSION_ID" not in source
    assert "os.environ" not in source

    # MCP-facing paths can only use the current opaque channel and a pairing
    # capability; no request method can select a workspace/session/workline.
    for method_name in ("status", "authorize", "detach_channel", "close_channel", "renew_lease"):
        names = set(inspect.signature(getattr(ScopeBroker, method_name)).parameters)
        assert not names & {"workspace_key", "owner_session_key", "task_id", "task_instance_id", "workline_id"}


def test_registry_tampering_fails_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-broker-") as directory:
        state_root = Path(directory) / "state"
        broker = ScopeBroker(state_root)
        workline_id = register(broker, contract())
        registry_path = state_root / "workspace" / "runtime-state" / "scope-broker" / "registry.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        registry["worklines"][0]["workspaceKey"] = "ws-" + "d" * 24
        registry_path.write_text(json.dumps(registry, separators=(",", ":")), encoding="utf-8")
        restarted = ScopeBroker(state_root)
        tampered = restarted.get_workline(workline_id)
        assert not tampered.ok and tampered.code == "H7_SCOPE_REGISTRY_INVALID"


def main() -> None:
    test_unbound_pair_foreign_replay_and_write_lease()
    test_expired_grants_and_leases_fail_closed()
    test_pairing_request_ref_is_scoped_short_lived_and_one_shot()
    test_pairing_request_ref_expires_and_refreshes_without_rebinding_scope()
    test_pairing_request_ref_concurrent_consumption_binds_once()
    test_registry_survives_restart_but_channels_and_grants_do_not()
    test_contract_hash_conflicts_and_host_identity_dependencies_are_rejected()
    test_registry_tampering_fails_closed()
    print("runtime_scope_broker_regression: 8 passed")


if __name__ == "__main__":
    main()
