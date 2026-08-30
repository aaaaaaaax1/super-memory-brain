"""Scope sources owned by Super Brain, with a narrow legacy CLI seam.

The production MCP path uses :class:`BrokerScopeProvider`.  It receives an
already-bound channel from the local Scope Broker and never derives identity
from a host thread, request payload, cwd, or ambient environment.  The legacy
provider is kept only for existing CLI/tests that explicitly run in a
task-local process; it is never selected by ``brain_mcp.main``.
"""

from __future__ import annotations

import hashlib
import os
import re
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Protocol

from scope_broker import ScopeContext


_WORKSPACE_RE = re.compile(r"^ws-[a-f0-9]{16,64}$", re.IGNORECASE)
_SESSION_RE = re.compile(r"^sid-[a-f0-9]{16,64}$", re.IGNORECASE)
_TASK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$")
_TASK_INSTANCE_RE = re.compile(r"^ti-[a-f0-9]{16,64}$", re.IGNORECASE)
_HASH_RE = re.compile(r"^[a-f0-9]{64}$", re.IGNORECASE)
_CHANNEL_RE = re.compile(r"^sbc-[a-f0-9]{32}$", re.IGNORECASE)


class ScopeProvider(Protocol):
    """Minimal read/authorization contract consumed by BrainCore."""

    def snapshot(self, *, force: bool = False) -> Mapping[str, Any]: ...

    def authorize(self, *, write: bool = False) -> Mapping[str, Any]: ...

    def project_root(self) -> Path | None: ...

    def status(self) -> Mapping[str, Any]: ...

    def resolve(self, *, write: bool = False) -> "ScopeResolution": ...


@dataclass(frozen=True, slots=True)
class ScopeResolution:
    """Stable provider result used by adapters and focused regressions."""

    state: str
    code: str
    source: str
    context: Any = None
    workspace_key: str = ""
    owner_session_key: str = ""
    project_root: str = ""
    access_mode: str = ""

    @property
    def current(self) -> bool:
        return self.state == "current"

    def public_projection(self) -> dict[str, Any]:
        result = {
            "state": self.state,
            "code": self.code,
            "source": self.source,
            "workspaceKey": self.workspace_key,
            "ownerSessionKey": self.owner_session_key,
            "accessMode": self.access_mode,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        if self.context is not None and hasattr(self.context, "public_projection"):
            result["scope"] = self.context.public_projection()
        return result

    def h7_scope_projection(self) -> dict[str, Any]:
        if self.context is not None and hasattr(self.context, "h7_scope_projection"):
            return dict(self.context.h7_scope_projection())
        return {
            "workspaceKey": self.workspace_key,
            "ownerSessionKey": self.owner_session_key,
        }


def _valid(value: Any, pattern: re.Pattern[str]) -> str:
    text = str(value or "").strip()
    return text.lower() if pattern.fullmatch(text) else ""


def _workspace_from_path(path: Path) -> str:
    normalized = str(path.expanduser().resolve()).rstrip("/\\").lower()
    return "ws-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24]


def _context_from_projection(value: Any) -> ScopeContext | None:
    """Rehydrate the typed broker context returned over IPC.

    The IPC transport intentionally serializes only the safe projection.  The
    provider restores that projection to the same immutable ``ScopeContext``
    shape used by an in-process broker, so callers do not have two subtly
    different authorization semantics depending on transport.
    """

    if not isinstance(value, Mapping):
        return None
    try:
        fields = {
            "session_id": str(value.get("sessionId", "")),
            "workline_id": str(value.get("worklineId", "")),
            "workspace_key": _valid(value.get("workspaceKey"), _WORKSPACE_RE),
            "owner_session_key": _valid(value.get("ownerSessionKey"), _SESSION_RE),
            "task_id": str(value.get("taskId", "")),
            "task_instance_id": _valid(value.get("taskInstanceId"), _TASK_INSTANCE_RE),
            "package_version": str(value.get("packageVersion", "")),
            "contract_revision": value.get("contractRevision"),
            "contract_hash": _valid(value.get("contractHash"), _HASH_RE),
            "scope_ref": _valid(value.get("scopeRef"), _HASH_RE),
        }
        if (
            not re.fullmatch(r"^sbs-[a-f0-9]{32}$", fields["session_id"], re.IGNORECASE)
            or not re.fullmatch(r"^sbw-[a-f0-9]{32}$", fields["workline_id"], re.IGNORECASE)
            or not _TASK_RE.fullmatch(fields["task_id"])
            or not _TASK_INSTANCE_RE.fullmatch(fields["task_instance_id"])
            or not fields["package_version"]
            or isinstance(fields["contract_revision"], bool)
            or not isinstance(fields["contract_revision"], int)
            or fields["contract_revision"] < 0
            or not fields["contract_hash"]
            or not fields["scope_ref"]
        ):
            return None
        return ScopeContext(**fields)
    except (TypeError, ValueError):
        return None


class LegacyEnvironmentScopeProvider:
    """Compatibility provider for a task-local CLI/test process only."""

    provider_kind = "legacy_local_process"

    def __init__(self, *, cwd_reader: Any | None = None, session_reader: Any | None = None) -> None:
        self._cwd_reader = cwd_reader or (lambda: str(Path.cwd()))
        self._session_reader = session_reader or (lambda: os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID", ""))

    def resolve(self, *, write: bool = False) -> ScopeResolution:
        value = dict(self.authorize(write=write))
        current = bool(value.get("ok"))
        return ScopeResolution(
            state="current" if current else "missing",
            code="H7_SCOPE_AUTHORIZED" if current else ("H7_SCOPE_PROVIDER_LOCAL_SESSION_MISSING" if not value.get("ownerSessionKey") else "H7_SCOPE_PROVIDER_UNAVAILABLE"),
            source="legacy_cwd_env",
            workspace_key=str(value.get("workspaceKey", "")),
            owner_session_key=str(value.get("ownerSessionKey", "")),
            project_root=str(value.get("projectRoot", "")),
            access_mode=str(value.get("accessMode", "")),
        )

    def snapshot(self, *, force: bool = False) -> Mapping[str, Any]:
        try:
            root = Path(str(self._cwd_reader())).expanduser().resolve()
        except OSError:
            return {}
        session_raw = str(self._session_reader() or "").strip()
        if not session_raw:
            return {"workspaceKey": _workspace_from_path(root), "provider": self.provider_kind}
        session = session_raw.lower()
        if not _SESSION_RE.fullmatch(session):
            session = "sid-" + hashlib.sha256(session_raw.encode("utf-8")).hexdigest()[:24]
        return {
            "workspaceKey": _workspace_from_path(root),
            "ownerSessionKey": session,
            "projectRoot": str(root),
            "provider": self.provider_kind,
        }

    def authorize(self, *, write: bool = False) -> Mapping[str, Any]:
        value = dict(self.snapshot(force=True))
        value["ok"] = bool(value.get("workspaceKey") and value.get("ownerSessionKey"))
        value["code"] = "H7_SCOPE_AUTHORIZED" if value["ok"] else "H7_SCOPE_LOCAL_PROCESS_REQUIRED"
        value["accessMode"] = "write" if write and value["ok"] else "read"
        return value

    def project_root(self) -> Path | None:
        try:
            root = Path(str(self._cwd_reader())).expanduser().resolve()
        except OSError:
            return None
        return root if root.is_dir() else None

    def status(self) -> Mapping[str, Any]:
        value = dict(self.snapshot(force=True))
        value.update({"state": "bound" if value.get("ownerSessionKey") else "unbound", "code": "H7_SCOPE_LEGACY_PROVIDER"})
        return value


class StaticScopeProvider:
    """Small in-memory provider for isolated runtime tests."""

    provider_kind = "test_static"

    def __init__(self, scope: Mapping[str, Any], project_root: str | Path | None = None) -> None:
        self._fixed = scope if isinstance(scope, ScopeResolution) else None
        self._scope = dict(scope) if isinstance(scope, Mapping) else {}
        self._project_root = Path(project_root).expanduser().resolve() if project_root else None

    def snapshot(self, *, force: bool = False) -> Mapping[str, Any]:
        return dict(self._scope)

    def authorize(self, *, write: bool = False) -> Mapping[str, Any]:
        value = dict(self._scope)
        value.update({"ok": bool(value.get("workspaceKey") and value.get("ownerSessionKey")), "code": "H7_SCOPE_AUTHORIZED" if value.get("workspaceKey") and value.get("ownerSessionKey") else "H7_SCOPE_UNBOUND", "accessMode": "write" if write else "read"})
        return value

    def project_root(self) -> Path | None:
        return self._project_root

    def status(self) -> Mapping[str, Any]:
        value = dict(self._scope)
        value.update({"state": "bound" if value.get("ownerSessionKey") else "unbound", "code": "H7_SCOPE_STATIC_PROVIDER"})
        return value

    def resolve(self, *, write: bool = False) -> ScopeResolution:
        if self._fixed is not None:
            return self._fixed
        value = dict(self.authorize(write=write))
        current = bool(value.get("ok"))
        return ScopeResolution(
            state="current" if current else "missing",
            code="H7_SCOPE_AUTHORIZED" if current else "H7_SCOPE_UNBOUND",
            source="test",
            workspace_key=str(value.get("workspaceKey", "")),
            owner_session_key=str(value.get("ownerSessionKey", "")),
            project_root=str(self._project_root or ""),
            access_mode=str(value.get("accessMode", "")),
        )


class OfflineReplayScopeProvider:
    """Non-authorizing provider reserved for the explicit MCP replay harness.

    An offline protocol replay may prove JSON-RPC framing, but it has no live
    local channel and must never inherit the CLI's cwd/session provider.  This
    provider makes that boundary explicit for both direct runtime calls and the
    stdio adapter.
    """

    provider_kind = "offline_mcp_replay"

    @staticmethod
    def _withheld() -> dict[str, Any]:
        return {
            "ok": False,
            "state": "withheld",
            "code": "H7_MCP_OFFLINE_REPLAY_NOT_LIVE",
            "provider": OfflineReplayScopeProvider.provider_kind,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def snapshot(self, *, force: bool = False) -> Mapping[str, Any]:
        return self._withheld()

    def authorize(self, *, write: bool = False) -> Mapping[str, Any]:
        return self._withheld()

    def project_root(self) -> Path | None:
        return None

    def status(self) -> Mapping[str, Any]:
        return self._withheld()

    def resolve(self, *, write: bool = False) -> ScopeResolution:
        return ScopeResolution(
            state="withheld",
            code="H7_MCP_OFFLINE_REPLAY_NOT_LIVE",
            source="offline_mcp_replay",
        )


class BrokerChannelHandle:
    """One MCP process's replaceable private Broker channel.

    A Broker restart invalidates all old channels by design.  This handle can
    open a *new unbound* channel after that explicit broker response, so the
    existing stdio process does not need to be restarted merely to let the
    trusted control surface pair it again.  It never selects a workline,
    pairs a channel, or retries a governed operation.
    """

    _RESTARTED_CODE = "H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED"

    def __init__(self, client: Any, channel_id: str) -> None:
        self.client = client
        self._channel_id = str(channel_id or "").strip()
        self._closed = False
        self._lock = threading.RLock()
        # Reopening is safe only when the endpoint proves that the Broker
        # instance changed.  A missing/closed channel on the same Broker is an
        # explicit revocation and must remain closed rather than being
        # silently replaced with a new unbound channel.
        self._broker_instance_id = self._current_instance_id()

    @property
    def channel_id(self) -> str:
        with self._lock:
            return self._channel_id

    def _current_instance_id(self, *, force_probe: bool = False) -> str:
        getter = getattr(self.client, "current_instance_id", None)
        if not callable(getter):
            return ""
        try:
            value = getter(force_probe=force_probe)
        except TypeError:
            try:
                value = getter()
            except Exception:
                return ""
        except Exception:
            return ""
        return str(value or "").strip()

    def _open_unbound_locked(self, *, replace: bool = False) -> bool:
        """Open one fresh unbound channel without selecting or pairing scope."""

        if self._closed:
            return False
        if self._channel_id and not replace:
            return True
        opener = getattr(self.client, "open_channel", None)
        if not callable(opener):
            return False
        try:
            replacement = str(opener(allow_auto_start=False) or "").strip()
        except TypeError:
            # Older test doubles may not expose the keyword.  Do not invoke
            # them as a fallback in production: without an endpoint identity
            # we cannot prove that a replacement is a Broker restart.
            return False
        except Exception:
            return False
        if not _CHANNEL_RE.fullmatch(replacement):
            return False
        self._channel_id = replacement
        self._broker_instance_id = self._current_instance_id()
        return True

    def ensure_channel(self) -> bool:
        """Recover an initially empty channel when a Broker is already live."""

        with self._lock:
            return self._open_unbound_locked()

    def reopen_after_restart(self, observed_channel_id: str, result: Mapping[str, Any] | None) -> bool:
        """Replace only a channel rejected by the current Broker instance.

        ``authorize``/``status`` are read-side checks, so retrying that exact
        check once is safe.  The replacement remains unbound and is therefore
        incapable of authorizing work until an explicit control-plane pair.
        """

        if not isinstance(result, Mapping) or str(result.get("code", "")) != self._RESTARTED_CODE:
            return False
        current_instance_id = self._current_instance_id(force_probe=True)
        with self._lock:
            if self._closed:
                return False
            # Another component sharing this handle already recovered it.
            if observed_channel_id != self._channel_id:
                return bool(self._channel_id)
            # The same Broker uses this code for an explicitly closed or
            # otherwise unknown channel.  Only a changed endpoint instance is
            # evidence of a restart and permits a fresh unbound channel.
            if not self._broker_instance_id or not current_instance_id or current_instance_id == self._broker_instance_id:
                return False
            self._channel_id = ""
            return self._open_unbound_locked(replace=True)

    def close_channel(self) -> None:
        """Close the currently owned channel once, without starting a Broker."""

        with self._lock:
            if self._closed:
                return
            self._closed = True
            channel_id = self._channel_id
            self._channel_id = ""
        close = getattr(self.client, "close_channel", None)
        if callable(close) and channel_id:
            try:
                close(channel_id)
            except Exception:
                pass


class BrokerScopeProvider:
    """Scope provider backed by one private broker channel.

    Channel bindings can be changed by the trusted control surface outside this
    process.  Therefore scope identity is never retained in an object-wide
    time cache: each operation observes the Broker's current binding.  The
    cost is a small local IPC round trip; it prevents a just-rebound channel
    from authorizing or proving work for its previous workline.
    """

    provider_kind = "scope_broker_channel"
    _LEASE_RENEW_WINDOW_SECONDS = 60
    _LEASE_RENEW_SECONDS = 3600

    def __init__(self, client: Any, channel_id: str | BrokerChannelHandle, *, cache_seconds: float = 0.20) -> None:
        self.client = client
        self.channel_handle = channel_id if isinstance(channel_id, BrokerChannelHandle) else BrokerChannelHandle(client, str(channel_id or ""))
        # Retain the argument for adapter compatibility, but deliberately do
        # not cache a mutable channel binding across independent requests.
        self.cache_seconds = 0.0
        self._lock = threading.RLock()
        self.last_context: Any = None
        self._lease_id = ""
        self._lease_expires_at = ""

    @property
    def channel_id(self) -> str:
        return self.channel_handle.channel_id

    def _clear_private_lease(self) -> None:
        with self._lock:
            self._lease_id = ""
            self._lease_expires_at = ""
            self.last_context = None

    def _remember_private_lease(self, result: Any, value: Mapping[str, Any]) -> None:
        """Keep renewal capability in-process; never return it to callers."""

        lease_id = str(getattr(result, "lease_id", "") or value.get("leaseId", "")).strip()
        lease_expires_at = str(
            getattr(result, "lease_expires_at", "") or value.get("leaseExpiresAt", "")
        ).strip()
        with self._lock:
            if re.fullmatch(r"^sbl-[a-f0-9]{32}$", lease_id, re.IGNORECASE):
                self._lease_id = lease_id
            if lease_expires_at:
                self._lease_expires_at = lease_expires_at
            if not value.get("ok") and str(value.get("code", "")) in {
                "H7_SCOPE_CHANNEL_UNBOUND",
                "H7_SCOPE_CHANNEL_LEASE_EXPIRED",
                "H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED",
                "H7_SCOPE_CHANNEL_CLOSED",
                "H7_SCOPE_LEASE_MISMATCH",
            }:
                self._lease_id = ""
                self._lease_expires_at = ""

    def _renew_if_needed(self) -> None:
        """Refresh a live lease shortly before expiry, if the client supports it."""

        with self._lock:
            lease_id = self._lease_id
            expires_raw = self._lease_expires_at
        if not lease_id or not expires_raw:
            return
        try:
            expires = datetime.fromisoformat(expires_raw.replace("Z", "+00:00"))
            if expires.tzinfo is None:
                return
            remaining = (expires.astimezone(timezone.utc) - datetime.now(timezone.utc)).total_seconds()
        except (TypeError, ValueError):
            return
        if remaining > self._LEASE_RENEW_WINDOW_SECONDS:
            return
        renew = getattr(self.client, "renew_lease", None)
        if not callable(renew):
            return
        try:
            result = renew(self.channel_id, lease_id, lease_seconds=self._LEASE_RENEW_SECONDS)
        except Exception:
            return
        value = dict(result) if isinstance(result, Mapping) else {}
        self._remember_private_lease(result, value)

    def _call(self, *, write: bool = False, force: bool = False) -> dict[str, Any]:
        # ``force`` remains part of the provider protocol.  Every broker call
        # is already fresh; callers use it to document a material boundary.
        del force
        self.channel_handle.ensure_channel()
        self._renew_if_needed()
        channel_id = self.channel_id
        try:
            result = self.client.authorize(channel_id, write=write)
        except Exception:
            result = {"ok": False, "code": "H7_SCOPE_BROKER_UNAVAILABLE", "state": "withheld"}
        initial_value = dict(result) if isinstance(result, Mapping) else {}
        if self.channel_handle.reopen_after_restart(channel_id, initial_value):
            # A restarted Broker has no binding/lease for the new channel.
            # Rechecking authorization is safe and yields the explicit
            # ``CHANNEL_UNBOUND`` repair state; it never replays a write.
            self._clear_private_lease()
            try:
                result = self.client.authorize(self.channel_id, write=write)
            except Exception:
                result = {"ok": False, "code": "H7_SCOPE_BROKER_UNAVAILABLE", "state": "withheld"}
        self.last_context = getattr(result, "context", None)
        if hasattr(result, "public_projection"):
            value = dict(result.public_projection())
            if self.last_context is not None and hasattr(self.last_context, "h7_scope_projection"):
                value["h7Scope"] = dict(self.last_context.h7_scope_projection())
        else:
            value = dict(result) if isinstance(result, Mapping) else {"ok": False, "code": "H7_SCOPE_BROKER_INVALID", "state": "withheld"}
        self._remember_private_lease(result, value)
        # IPC's private authorization projection may carry a renewal token;
        # consume it above and strip it before any provider response leaves
        # this process.
        value.pop("leaseId", None)
        scope = value.get("scope") if isinstance(value.get("scope"), Mapping) else value.get("h7Scope")
        if self.last_context is None and isinstance(scope, Mapping):
            self.last_context = _context_from_projection(scope)
        if isinstance(scope, Mapping):
            value.update({str(k): v for k, v in scope.items() if str(k) in {"workspaceKey", "ownerSessionKey", "taskId", "taskInstanceId", "packageVersion", "contractRevision", "contractHash", "scopeRef", "projectRoot"}})
        value["provider"] = self.provider_kind
        if value.get("ok") is True:
            workspace_key = _valid(value.get("workspaceKey"), _WORKSPACE_RE)
            owner_session_key = _valid(value.get("ownerSessionKey"), _SESSION_RE)
            if workspace_key and owner_session_key:
                value["workspaceKey"] = workspace_key
                value["ownerSessionKey"] = owner_session_key
            else:
                # A status query can legitimately report an existing channel
                # as healthy but unbound.  That is never operation
                # authorization.  Normalize every incomplete positive result
                # to fail closed, including alternative broker transports.
                has_identity_fields = bool(str(value.get("workspaceKey") or "").strip() or str(value.get("ownerSessionKey") or "").strip())
                code = (
                    "H7_SCOPE_BROKER_CONTEXT_INVALID"
                    if has_identity_fields
                    else str(value.get("code") or "H7_SCOPE_BROKER_CONTEXT_MISSING")
                )
                state = "unbound" if code == "H7_SCOPE_CHANNEL_UNBOUND" or value.get("state") == "unbound" else "withheld"
                self.last_context = None
                value = {
                    "ok": False,
                    "code": code,
                    "state": state,
                    "provider": self.provider_kind,
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }

        with self._lock:
            if value.get("ok") is not True:
                self.last_context = None
        return value

    def snapshot(self, *, force: bool = False) -> Mapping[str, Any]:
        return self._call(force=force)

    def authorize(self, *, write: bool = False) -> Mapping[str, Any]:
        return self._call(write=write, force=True)

    def project_root(self) -> Path | None:
        # The project root is a material proof input and always comes from the
        # current authorized Broker response.
        value = self._call(force=True)
        raw = str(value.get("projectRoot", "")).strip()
        if not raw:
            return None
        try:
            root = Path(raw).expanduser().resolve()
        except OSError:
            return None
        return root if root.is_dir() else None

    def status(self) -> Mapping[str, Any]:
        self.channel_handle.ensure_channel()
        channel_id = self.channel_id
        try:
            value = self.client.status(channel_id)
        except Exception:
            value = {"ok": False, "code": "H7_SCOPE_BROKER_UNAVAILABLE", "state": "withheld"}
        initial_value = dict(value) if isinstance(value, Mapping) else {}
        if self.channel_handle.reopen_after_restart(channel_id, initial_value):
            try:
                value = self.client.status(self.channel_id)
            except Exception:
                value = {"ok": False, "code": "H7_SCOPE_BROKER_UNAVAILABLE", "state": "withheld"}
        result = dict(value) if isinstance(value, Mapping) else {"ok": False, "code": "H7_SCOPE_BROKER_INVALID", "state": "withheld"}
        result["provider"] = self.provider_kind
        return result

    def resolve(self, *, write: bool = False) -> ScopeResolution:
        value = self._call(write=write, force=True)
        scope = value.get("scope") if isinstance(value.get("scope"), Mapping) else value
        current = bool(value.get("ok") is True and value.get("workspaceKey") and value.get("ownerSessionKey"))
        return ScopeResolution(
            state="current" if current else ("missing" if str(value.get("code", "")).startswith("H7_SCOPE_CHANNEL_UNBOUND") else "withheld"),
            code=str(value.get("code", "H7_SCOPE_BROKER_UNAVAILABLE")),
            source="broker_channel",
            context=self.last_context,
            workspace_key=str((scope or {}).get("workspaceKey", "")),
            owner_session_key=str((scope or {}).get("ownerSessionKey", "")),
            project_root=str((scope or {}).get("projectRoot", "")),
            access_mode=str(value.get("accessMode", "")),
        )


# Explicit names used by the standalone provider contract.  Keep the longer
# environment name as a compatibility alias for BrainCore's CLI seam.
LegacyCwdEnvScopeProvider = LegacyEnvironmentScopeProvider
TestScopeProvider = StaticScopeProvider


__all__ = [
    "BrokerChannelHandle",
    "BrokerScopeProvider",
    "LegacyCwdEnvScopeProvider",
    "LegacyEnvironmentScopeProvider",
    "OfflineReplayScopeProvider",
    "ScopeResolution",
    "ScopeProvider",
    "StaticScopeProvider",
    "TestScopeProvider",
]
