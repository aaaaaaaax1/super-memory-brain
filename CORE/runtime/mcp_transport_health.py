"""Injectable, platform-neutral health for one local MCP stdio transport.

The health object is deliberately process-local.  It proves only that this
MCP server instance initialized successfully and can still reach its own
authenticated Scope Broker channel.  It never reads deployment registration,
host configuration, ambient workspace/session identity, or a persisted global
"live" marker.
"""

from __future__ import annotations

import threading
from collections.abc import Mapping
from typing import Any, Protocol


HANDSHAKE_SCHEMA = "super-brain.mcp-live-handshake.v2"
LOCAL_STDIO_TRANSPORT = "local_scope_broker_stdio"


def _package_version(runtime_identity: Mapping[str, Any] | None) -> str:
    runtime = runtime_identity if isinstance(runtime_identity, Mapping) else {}
    for key in ("sourceCoreRules", "servedCoreRules"):
        rules = runtime.get(key)
        if isinstance(rules, Mapping):
            value = str(rules.get("packageVersion", "")).strip()
            if value:
                return value
    return ""


class McpTransportHealth(Protocol):
    """Small lifecycle contract injected by an MCP entry adapter."""

    def mark_initialized(self, runtime_identity: Mapping[str, Any]) -> Mapping[str, Any]: ...

    def status(self, runtime_identity: Mapping[str, Any]) -> Mapping[str, Any]: ...

    def close(self) -> None: ...


def inactive_status(runtime_identity: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Return an explicit non-MCP projection for CLI/test construction."""

    runtime = runtime_identity if isinstance(runtime_identity, Mapping) else {}
    return {
        "schema": HANDSHAKE_SCHEMA,
        "state": "not_applicable",
        "code": "H7_MCP_RUNTIME_NOT_ACTIVE",
        "transport": "",
        "runtimeIdentity": "",
        "broker": {"state": "not_applicable", "code": "H7_SCOPE_BROKER_NOT_ACTIVE", "available": False},
        "scope": {"provider": "", "state": "not_applicable", "code": "H7_SCOPE_CHANNEL_NOT_ACTIVE", "accessMode": ""},
        "packageVersion": _package_version(runtime),
        "registryVersion": int((runtime.get("servedCoreRules") or {}).get("registryVersion", 0) or 0),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


class OfflineReplayMcpTransportHealth:
    """Explicit test-only transport state; it can never claim liveness."""

    def mark_initialized(self, runtime_identity: Mapping[str, Any]) -> Mapping[str, Any]:
        return self.status(runtime_identity)

    def status(self, runtime_identity: Mapping[str, Any]) -> Mapping[str, Any]:
        runtime = runtime_identity if isinstance(runtime_identity, Mapping) else {}
        return {
            "schema": HANDSHAKE_SCHEMA,
            "state": "offline_replay",
            "code": "H7_MCP_OFFLINE_REPLAY_NOT_LIVE",
            "transport": "offline_mcp_replay",
            "runtimeIdentity": "",
            "broker": {"state": "not_applicable", "code": "H7_SCOPE_BROKER_NOT_ACTIVE", "available": False},
            "scope": {"provider": "", "state": "not_applicable", "code": "H7_SCOPE_CHANNEL_NOT_ACTIVE", "accessMode": ""},
            "packageVersion": _package_version(runtime),
            "registryVersion": int((runtime.get("servedCoreRules") or {}).get("registryVersion", 0) or 0),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def close(self) -> None:
        return None


class LocalBrokerStdioTransportHealth:
    """Health of one initialized stdio MCP connection and its private channel."""

    def __init__(self, client: Any, channel_id: Any, *, provider_kind: str = "scope_broker_channel") -> None:
        self._client = client
        # ``BrokerChannelHandle`` is intentionally duck-typed here to avoid a
        # transport-health -> scope-provider import cycle.  A plain string
        # remains supported for isolated tests and compatibility callers.
        self._channel_handle = channel_id if hasattr(channel_id, "channel_id") and hasattr(channel_id, "reopen_after_restart") else None
        self._channel_id = "" if self._channel_handle is not None else str(channel_id or "")
        self._provider_kind = str(provider_kind or "scope_broker_channel")
        self._initialized = False
        self._closed = False
        self._lock = threading.RLock()

    def mark_initialized(self, runtime_identity: Mapping[str, Any]) -> Mapping[str, Any]:
        with self._lock:
            if not self._closed:
                self._initialized = True
        return self.status(runtime_identity)

    def close(self) -> None:
        with self._lock:
            self._closed = True

    def _channel_status(self) -> dict[str, Any]:
        if self._channel_handle is not None:
            ensure = getattr(self._channel_handle, "ensure_channel", None)
            if callable(ensure):
                try:
                    ensure()
                except Exception:
                    pass
        channel_id = str(getattr(self._channel_handle, "channel_id", "") or self._channel_id)
        if not channel_id:
            return {"ok": False, "code": "H7_SCOPE_CHANNEL_OPEN_FAILED", "state": "withheld"}
        try:
            value = self._client.status(channel_id)
        except Exception:
            value = {"ok": False, "code": "H7_SCOPE_BROKER_UNAVAILABLE", "state": "withheld"}
        result = dict(value) if isinstance(value, Mapping) else {"ok": False, "code": "H7_SCOPE_BROKER_INVALID", "state": "withheld"}
        if self._channel_handle is not None:
            try:
                reopened = bool(self._channel_handle.reopen_after_restart(channel_id, result))
            except Exception:
                reopened = False
            if reopened:
                try:
                    value = self._client.status(str(getattr(self._channel_handle, "channel_id", "")))
                except Exception:
                    value = {"ok": False, "code": "H7_SCOPE_BROKER_UNAVAILABLE", "state": "withheld"}
                result = dict(value) if isinstance(value, Mapping) else {"ok": False, "code": "H7_SCOPE_BROKER_INVALID", "state": "withheld"}
        return result

    def status(self, runtime_identity: Mapping[str, Any]) -> Mapping[str, Any]:
        runtime = runtime_identity if isinstance(runtime_identity, Mapping) else {}
        with self._lock:
            initialized = self._initialized
            closed = self._closed
        channel = self._channel_status() if not closed else {"ok": False, "code": "H7_SCOPE_CHANNEL_CLOSED", "state": "withheld"}
        channel_code = str(channel.get("code", "H7_SCOPE_BROKER_UNAVAILABLE"))
        channel_state = str(channel.get("state", "withheld"))
        pairing_ref = str(
            channel.get("pairingRequestRef", "")
            or getattr(self._channel_handle, "pairing_request_ref", "")
            or ""
        )
        channel_ok = bool(
            channel.get("ok") is True
            and channel_code in {"H7_SCOPE_CHANNEL_UNBOUND", "H7_SCOPE_CHANNEL_BOUND"}
            and channel_state in {"unbound", "bound"}
        )
        if runtime.get("state") != "current":
            state, code = "withheld", str(runtime.get("code", "H7_MCP_RUNTIME_IDENTITY_STALE"))
        elif closed:
            state, code = "withheld", "H7_MCP_LOCAL_STDIO_CLOSED"
        elif not channel_ok:
            state, code = "withheld", channel_code
        elif not initialized:
            state, code = "initializing", "H7_MCP_INITIALIZE_REQUIRED"
        else:
            state, code = "current", "H7_MCP_LOCAL_STDIO_CURRENT"
        return {
            "schema": HANDSHAKE_SCHEMA,
            "state": state,
            "code": code,
            "transport": LOCAL_STDIO_TRANSPORT,
            "runtimeIdentity": str(runtime.get("sourceIdentity", "")) if state == "current" else "",
            "broker": {
                "state": "current" if channel_ok else "withheld",
                "code": channel_code,
                "available": channel_ok,
            },
            "scope": {
                "provider": self._provider_kind,
                "state": channel_state,
                "code": channel_code,
                "accessMode": str(channel.get("accessMode", "")),
                "pairingRequestRef": pairing_ref if channel_state == "unbound" else "",
            },
            "packageVersion": _package_version(runtime),
            "registryVersion": int((runtime.get("servedCoreRules") or {}).get("registryVersion", 0) or 0),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }


__all__ = [
    "HANDSHAKE_SCHEMA",
    "LOCAL_STDIO_TRANSPORT",
    "LocalBrokerStdioTransportHealth",
    "McpTransportHealth",
    "OfflineReplayMcpTransportHealth",
    "inactive_status",
]
