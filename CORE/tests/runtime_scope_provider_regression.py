from __future__ import annotations

import hashlib
import inspect
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from scope_broker import ScopeBroker
from brain_core import MCP_RUNTIME_MODE_OFFLINE_REPLAY, MCP_RUNTIME_MODE_STDIO, BrainCore
from mcp_transport_health import OfflineReplayMcpTransportHealth
from scope_provider import (
    BrokerScopeProvider,
    LegacyCwdEnvScopeProvider,
    OfflineReplayScopeProvider,
    ScopeResolution,
    TestScopeProvider,
)


NOW = datetime.now(timezone.utc).replace(microsecond=0)
LOCAL_SESSION_ENV = "SUPER_BRAIN_LOCAL_SESSION_ID"


def contract() -> dict[str, object]:
    return {
        "schema": "super-brain.execution-contract.v1",
        "status": "active",
        "taskId": "task-scope-provider-regression",
        "taskInstanceId": "ti-" + "a" * 32,
        "workspaceKey": "ws-" + "b" * 24,
        "ownerSessionKey": "sid-" + "c" * 24,
        "packageVersion": "1.0.0",
        "revision": 1,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def contract_hash(value: dict[str, object]) -> str:
    import json

    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def test_broker_provider_requires_one_bound_channel() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-provider-") as directory:
        broker = ScopeBroker(Path(directory) / "state")
        value = contract()
        registered = broker.register_workline(value, expected_contract_hash=contract_hash(value), now=NOW)
        assert registered.ok and registered.context is not None

        channel = broker.open_channel()
        provider = BrokerScopeProvider(broker, channel)
        unbound_authorization = provider.authorize(write=True)
        assert unbound_authorization["ok"] is False
        assert unbound_authorization["code"] == "H7_SCOPE_CHANNEL_UNBOUND"
        assert unbound_authorization["state"] == "unbound"
        assert provider.status()["provider"] == "scope_broker_channel"
        unbound = provider.resolve(write=True)
        assert unbound.state == "missing"
        assert unbound.code == "H7_SCOPE_CHANNEL_UNBOUND"
        assert unbound.source == "broker_channel"

        grant = broker.issue_pairing_grant(channel, registered.context.workline_id, access_mode="write", now=NOW)
        assert broker.attach_channel(channel, grant.token, now=NOW).ok
        current = provider.resolve(write=True)
        assert current.current
        assert current.source == "broker_channel"
        assert current.context is not None
        assert current.workspace_key == value["workspaceKey"]
        assert current.owner_session_key == value["ownerSessionKey"]
        assert current.context.workline_id == registered.context.workline_id
        # The IPC adapter and in-process broker must expose the same typed
        # context contract; callers should not have to branch on transport.
        assert current.context.contract_hash == registered.context.contract_hash
        assert current.context.scope_ref == registered.context.scope_ref
        assert current.h7_scope_projection()["taskId"] == value["taskId"]
        public = current.public_projection()
        assert "leaseId" not in public
        assert public["rawPromptStored"] is False
        assert public["rawTranscriptStored"] is False


def test_broker_provider_has_no_ambient_identity_fallback() -> None:
    previous = os.environ.get(LOCAL_SESSION_ENV)
    try:
        os.environ[LOCAL_SESSION_ENV] = "ambient-value-must-not-bind-a-channel"
        with tempfile.TemporaryDirectory(prefix="super-brain-scope-provider-") as directory:
            broker = ScopeBroker(Path(directory) / "state")
            result = BrokerScopeProvider(broker, broker.open_channel()).resolve()
            assert result.state == "missing"
            assert result.code == "H7_SCOPE_CHANNEL_UNBOUND"
    finally:
        if previous is None:
            os.environ.pop(LOCAL_SESSION_ENV, None)
        else:
            os.environ[LOCAL_SESSION_ENV] = previous


def test_broker_provider_drops_cached_scope_after_rebind_or_denial() -> None:
    """A control-plane rebind cannot leave the prior workline in short cache."""

    with tempfile.TemporaryDirectory(prefix="super-brain-scope-provider-rebind-") as directory:
        broker = ScopeBroker(Path(directory) / "state")
        first_contract = contract()
        first = broker.register_workline(first_contract, expected_contract_hash=contract_hash(first_contract), now=NOW)
        assert first.ok and first.context is not None
        second_contract = dict(first_contract)
        second_contract.update(
            {
                "taskId": "task-scope-provider-rebound",
                "taskInstanceId": "ti-" + "d" * 32,
                "ownerSessionKey": "sid-" + "e" * 24,
            }
        )
        second = broker.register_workline(second_contract, expected_contract_hash=contract_hash(second_contract), now=NOW)
        assert second.ok and second.context is not None

        channel = broker.open_channel()
        assert broker.pair_channel(channel, first.context.workline_id, access_mode="read", now=NOW).ok
        provider = BrokerScopeProvider(broker, channel, cache_seconds=60.0)
        cached = provider.snapshot()
        assert cached["scopeRef"] == first.context.scope_ref

        # Pairing a new workline happens outside the provider.  A plain
        # snapshot immediately afterwards must already see the new workline;
        # no object-wide time cache may retain the prior scope in this window.
        assert broker.detach_channel(channel).ok
        assert broker.pair_channel(channel, second.context.workline_id, access_mode="read", now=NOW).ok
        rebound = provider.snapshot()
        assert rebound["ok"] is True
        assert rebound["scopeRef"] == second.context.scope_ref
        assert provider.authorize()["scopeRef"] == second.context.scope_ref

        # A later revocation/expiry-equivalent denial also clears the cache;
        # a snapshot must not return the previously authorized workline.
        assert broker.detach_channel(channel).ok
        denied = provider.authorize()
        assert denied["ok"] is False
        assert provider.snapshot()["ok"] is False


def test_non_cli_core_requires_explicit_scope_provider_and_transport_health() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-core-injection-") as directory:
        memory = Path(directory) / "state" / "shared"
        memory.mkdir(parents=True)
        try:
            BrainCore(ROOT, memory, runtime_mode=MCP_RUNTIME_MODE_STDIO)
        except ValueError as error:
            assert str(error) == "H7_SCOPE_PROVIDER_REQUIRED"
        else:  # pragma: no cover - defensive assertion
            raise AssertionError("stdio runtime accepted an implicit legacy scope provider")
        try:
            BrainCore(ROOT, memory, runtime_mode=MCP_RUNTIME_MODE_STDIO, scope_provider=TestScopeProvider({}))
        except ValueError as error:
            assert str(error) == "H7_MCP_TRANSPORT_HEALTH_REQUIRED"
        else:  # pragma: no cover - defensive assertion
            raise AssertionError("stdio runtime accepted no transport health")
        try:
            BrainCore(ROOT, memory, runtime_mode=MCP_RUNTIME_MODE_OFFLINE_REPLAY)
        except ValueError as error:
            assert str(error) == "H7_SCOPE_PROVIDER_REQUIRED"
        else:  # pragma: no cover - defensive assertion
            raise AssertionError("offline replay inherited a legacy scope provider")
        replay = BrainCore(
            ROOT,
            memory,
            runtime_mode=MCP_RUNTIME_MODE_OFFLINE_REPLAY,
            scope_provider=OfflineReplayScopeProvider(),
            transport_health=OfflineReplayMcpTransportHealth(),
        )
        assert replay.runtime_mode == MCP_RUNTIME_MODE_OFFLINE_REPLAY
        assert replay.authorize_scope()["code"] == "H7_MCP_OFFLINE_REPLAY_NOT_LIVE"


def test_legacy_provider_uses_only_cwd_and_local_session() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-provider-") as directory:
        project = Path(directory) / "project"
        project.mkdir()
        provider = LegacyCwdEnvScopeProvider(
            cwd_reader=lambda: str(project),
            session_reader=lambda: "local-session-for-provider",
        )
        result = provider.resolve()
        expected_workspace = "ws-" + hashlib.sha256(
            os.path.abspath(str(project)).rstrip("/\\").lower().encode("utf-8")
        ).hexdigest()[:24]
        expected_session = "sid-" + hashlib.sha256(b"local-session-for-provider").hexdigest()[:24]
        assert result.current
        assert result.source == "legacy_cwd_env"
        assert result.workspace_key == expected_workspace
        assert result.owner_session_key == expected_session
        assert result.context is None


def test_legacy_provider_fails_closed_without_local_session() -> None:
    provider = LegacyCwdEnvScopeProvider(cwd_reader=os.getcwd, session_reader=lambda: "")
    result = provider.resolve()
    assert result.state == "missing"
    assert result.code == "H7_SCOPE_PROVIDER_LOCAL_SESSION_MISSING"
    assert result.source == "legacy_cwd_env"


def test_test_provider_is_deterministic_and_no_retired_identity_is_referenced() -> None:
    expected = ScopeResolution(state="withheld", code="H7_TEST_WITHHELD", source="test")
    assert TestScopeProvider(expected).resolve(write=True) is expected
    source = (ROOT / "runtime" / "scope_provider.py").read_text(encoding="utf-8")
    assert "CODEX_THREAD_ID" not in source
    assert "host_thread_payload" not in source
    assert inspect.signature(BrokerScopeProvider.resolve).parameters.keys() == {"self", "write"}


def main() -> None:
    test_broker_provider_requires_one_bound_channel()
    test_broker_provider_has_no_ambient_identity_fallback()
    test_broker_provider_drops_cached_scope_after_rebind_or_denial()
    test_non_cli_core_requires_explicit_scope_provider_and_transport_health()
    test_legacy_provider_uses_only_cwd_and_local_session()
    test_legacy_provider_fails_closed_without_local_session()
    test_test_provider_is_deterministic_and_no_retired_identity_is_referenced()
    print("runtime_scope_provider_regression: 7 passed")


if __name__ == "__main__":
    main()
