"""Platform-neutral, local Scope Broker primitives for Super Brain.

The broker owns the durable session/workline registry while channel bindings,
write leases, and pairing grants deliberately stay process-local.  A transport
adapter may therefore be restarted without turning an old connection, a task
identifier, or a request payload into authority over a previous workline.

This module is intentionally independent of MCP, CLI process environment, and
any host-specific metadata.  Its only durable input is a validated H7
execution-contract projection; the full contract is never persisted here.
"""

from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import secrets
import tempfile
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from collections.abc import Mapping as MappingABC
from typing import Any, Iterator, Mapping


REGISTRY_SCHEMA = "super-brain.scope-broker-registry.v1"
CONTEXT_SCHEMA = "super-brain.scope-context.v1"
PAIRING_GRANT_SCHEMA = "super-brain.scope-pairing-grant.v1"

_REGISTRY_FIELDS = {
    "schema",
    "registryRevision",
    "sessions",
    "worklines",
    "rawPromptStored",
    "rawTranscriptStored",
    "payloadHash",
}
_SESSION_FIELDS = {"sessionId", "workspaceKey", "ownerSessionKey", "createdAt"}
_WORKLINE_FIELDS = {
    "worklineId",
    "sessionId",
    "workspaceKey",
    "ownerSessionKey",
    "taskId",
    "taskInstanceId",
    "packageVersion",
    "contractRevision",
    "contractHash",
    "scopeRef",
    "createdAt",
    "updatedAt",
}

_WORKSPACE_KEY_RE = re.compile(r"^ws-[a-f0-9]{16,64}$")
_OWNER_SESSION_KEY_RE = re.compile(r"^sid-[a-f0-9]{16,64}$")
_BROKER_SESSION_ID_RE = re.compile(r"^sbs-[a-f0-9]{32}$")
_WORKLINE_ID_RE = re.compile(r"^sbw-[a-f0-9]{32}$")
_TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$")
_TASK_INSTANCE_ID_RE = re.compile(r"^ti-[a-f0-9]{16,64}$")
_PACKAGE_VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$")
_SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
_CHANNEL_ID_RE = re.compile(r"^sbc-[a-f0-9]{32}$")
_PAIRING_REQUEST_REF_RE = re.compile(r"^sbpr-[a-f0-9]{32}$")
_LEASE_ID_RE = re.compile(r"^sbl-[a-f0-9]{32}$")
_PAIRING_TOKEN_RE = re.compile(r"^sbpg-v1\.[A-Za-z0-9_-]{32,128}$")

_MAX_REGISTRY_SESSIONS = 256
_MAX_REGISTRY_WORKLINES = 2048
_MAX_CONTRACT_BYTES = 256 * 1024
_MAX_GRANTS = 512
_MIN_GRANT_TTL_SECONDS = 1
_MAX_GRANT_TTL_SECONDS = 300
_MIN_LEASE_SECONDS = 15
_MAX_LEASE_SECONDS = 3600
_DEFAULT_LEASE_SECONDS = 300
_PAIRING_REQUEST_REF_TTL_SECONDS = 300
_LOCK_TIMEOUT_SECONDS = 2.0

_PROCESS_LOCKS_GUARD = threading.Lock()
_PROCESS_LOCKS: dict[str, threading.RLock] = {}


def _canonical_hash(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _utc_now(now: datetime | None = None) -> datetime:
    value = now or datetime.now(timezone.utc)
    if value.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    return value.astimezone(timezone.utc)


def _timestamp(now: datetime | None = None) -> str:
    return _utc_now(now).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value or len(value) > 64:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def _safe_string(value: Any, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str):
        return ""
    normalized = value.strip()
    return normalized if pattern.fullmatch(normalized) else ""


def _scope_ref(
    *,
    session_id: str,
    workline_id: str,
    workspace_key: str,
    owner_session_key: str,
) -> str:
    """Return a stable opaque identity for one broker-owned workline."""

    return _canonical_hash(
        {
            "schema": "super-brain.scope-broker-scope-ref.v1",
            "sessionId": session_id,
            "worklineId": workline_id,
            "workspaceKey": workspace_key.lower(),
            "ownerSessionKey": owner_session_key.lower(),
        }
    )


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _process_lock(path: Path) -> threading.RLock:
    key = str(path.resolve()).lower()
    with _PROCESS_LOCKS_GUARD:
        lock = _PROCESS_LOCKS.get(key)
        if lock is None:
            lock = threading.RLock()
            _PROCESS_LOCKS[key] = lock
        return lock


@contextmanager
def _advisory_lock(path: Path) -> Iterator[bool]:
    """Acquire the same persistent-file style lock used by runtime journals."""

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        handle = path.open("a+b")
    except OSError:
        yield False
        return
    try:
        try:
            handle.seek(0, os.SEEK_END)
            if handle.tell() == 0:
                handle.write(b"0")
                handle.flush()
        except OSError:
            yield False
            return
        try:
            if os.name == "nt":
                import msvcrt
            else:
                import fcntl
        except ImportError:
            yield False
            return
        acquired = False
        started = time.monotonic()
        while time.monotonic() - started < _LOCK_TIMEOUT_SECONDS:
            try:
                handle.seek(0)
                if os.name == "nt":
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except OSError as error:
                if error.errno not in {errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK}:
                    break
                time.sleep(0.01)
        try:
            yield acquired
        finally:
            if acquired:
                try:
                    handle.seek(0)
                    if os.name == "nt":
                        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                    else:
                        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
    finally:
        handle.close()


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(prefix=".scope-broker-", suffix=".tmp", dir=str(path.parent))
    temporary = Path(raw_path)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


@dataclass(frozen=True, slots=True)
class ScopeContext:
    """An immutable broker-owned workline identity with an H7 hash binding."""

    session_id: str
    workline_id: str
    workspace_key: str
    owner_session_key: str
    task_id: str
    task_instance_id: str
    package_version: str
    contract_revision: int
    contract_hash: str
    scope_ref: str

    def public_projection(self) -> dict[str, Any]:
        """Return the complete safe transport projection, never a contract body."""

        return {
            "schema": CONTEXT_SCHEMA,
            "sessionId": self.session_id,
            "worklineId": self.workline_id,
            "workspaceKey": self.workspace_key,
            "ownerSessionKey": self.owner_session_key,
            "taskId": self.task_id,
            "taskInstanceId": self.task_instance_id,
            "packageVersion": self.package_version,
            "contractRevision": self.contract_revision,
            "contractHash": self.contract_hash,
            "scopeRef": self.scope_ref,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def h7_scope_projection(self) -> dict[str, Any]:
        """Return the minimal immutable binding for an internal H7 adapter.

        This is intentionally an explicit, already-authorized context object,
        not a request selector.  A future ``BrainCore(scope_provider=...)``
        integration can consume this projection without consulting cwd,
        environment, host metadata, or a caller-supplied scope key.
        """

        return {
            "workspaceKey": self.workspace_key,
            "ownerSessionKey": self.owner_session_key,
            "taskId": self.task_id,
            "taskInstanceId": self.task_instance_id,
            "packageVersion": self.package_version,
            "contractRevision": self.contract_revision,
            "contractHash": self.contract_hash,
            "scopeRef": self.scope_ref,
        }

    def _record(self, *, created_at: str, updated_at: str) -> dict[str, Any]:
        return {
            "worklineId": self.workline_id,
            "sessionId": self.session_id,
            "workspaceKey": self.workspace_key,
            "ownerSessionKey": self.owner_session_key,
            "taskId": self.task_id,
            "taskInstanceId": self.task_instance_id,
            "packageVersion": self.package_version,
            "contractRevision": self.contract_revision,
            "contractHash": self.contract_hash,
            "scopeRef": self.scope_ref,
            "createdAt": created_at,
            "updatedAt": updated_at,
        }


@dataclass(frozen=True, slots=True)
class PairingGrant:
    """An opaque, one-shot control-plane grant.

    The token is intentionally omitted from ``repr`` so normal diagnostics do
    not accidentally include it.  The broker retains only its SHA-256 hash.
    """

    token: str = field(repr=False)
    expires_at: str
    access_mode: str

    def control_projection(self) -> dict[str, Any]:
        return {
            "schema": PAIRING_GRANT_SCHEMA,
            "expiresAt": self.expires_at,
            "accessMode": self.access_mode,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }


@dataclass(frozen=True, slots=True)
class ScopeBrokerResult(MappingABC[str, Any]):
    """A safe operation result that never carries grants or contract bodies."""

    ok: bool
    code: str
    state: str
    context: ScopeContext | None = None
    access_mode: str = ""
    lease_id: str = ""
    lease_expires_at: str = ""
    pairing_request_ref: str = ""

    def public_projection(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "ok": self.ok,
            "code": self.code,
            "state": self.state,
            "accessMode": self.access_mode,
            # Lease IDs are channel-private renewal capabilities.  Adapters
            # may retain ``lease_id`` from this result, but must not place it
            # on a normal MCP/tool response.
            "leaseActive": bool(self.lease_id),
            "leaseExpiresAt": self.lease_expires_at,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        if self.pairing_request_ref:
            value["pairingRequestRef"] = self.pairing_request_ref
        if self.context is not None:
            value["scope"] = self.context.public_projection()
        return value

    # Mapping compatibility keeps the broker usable across local adapters
    # that expect JSON-like results while preserving the typed result fields
    # for in-process callers.  Iteration exposes only the safe projection;
    # private lease capabilities remain available solely as ``lease_id``.
    def __getitem__(self, key: str) -> Any:
        return self.public_projection()[key]

    def __iter__(self) -> Iterator[str]:
        return iter(self.public_projection())

    def __len__(self) -> int:
        return len(self.public_projection())


@dataclass(slots=True)
class _GrantRecord:
    token_hash: str
    channel_id: str
    workline_id: str
    access_mode: str
    expires_at: datetime
    used: bool = False


@dataclass(slots=True)
class _ChannelBinding:
    workline_id: str
    context: ScopeContext
    access_mode: str
    lease_id: str
    lease_expires_at: datetime


@dataclass(slots=True)
class _PairingRequest:
    ref: str
    channel_id: str
    broker_instance_id: str
    expires_at: datetime


class ScopeBroker:
    """Own Super Brain scope registry and transient channel capability state.

    ``register_workline`` and ``issue_pairing_grant`` belong to a local trusted
    control surface.  Transport adapters receive only ``open_channel``,
    ``attach_channel``, ``authorize``/``status``, and ``detach_channel``.
    In particular, none of the channel-facing methods accepts a workspace,
    session, task, or workline selector.
    """

    def __init__(self, state_root: str | Path) -> None:
        self.state_root = Path(state_root).expanduser().resolve()
        self._registry_path = self.state_root / "workspace" / "runtime-state" / "scope-broker" / "registry.json"
        self._lock_path = self._registry_path.with_suffix(".lock")
        self._memory_lock = threading.RLock()
        self._channels: set[str] = set()
        self._bindings: dict[str, _ChannelBinding] = {}
        self._write_leases: dict[str, str] = {}
        self._grants: dict[str, _GrantRecord] = {}
        self._pairing_requests: dict[str, _PairingRequest] = {}
        self._channel_pairing_refs: dict[str, str] = {}
        # Pairing refs are bound to this in-memory Broker instance.  A fresh
        # Broker object (including a restart) therefore cannot consume an old
        # ref even if a stale caller still has its text.
        self._instance_id = "sbi-" + secrets.token_hex(16)

    # -- Durable SB-owned session/workline registry -----------------------

    def register_workline(
        self,
        contract: Mapping[str, Any],
        *,
        expected_contract_hash: str | None = None,
        now: datetime | None = None,
    ) -> ScopeBrokerResult:
        """Create or refresh a workline from one exact current H7 contract.

        Only the compact identity projection and canonical contract hash are
        written.  The contract itself, including all descriptive fields, never
        becomes broker state.
        """

        try:
            binding = self._contract_binding(contract, expected_contract_hash=expected_contract_hash)
        except ValueError as error:
            return self._failure(str(error), "withheld")
        current_time = _utc_now(now)
        current_stamp = _timestamp(current_time)
        try:
            with _process_lock(self._lock_path):
                with _advisory_lock(self._lock_path) as acquired:
                    if not acquired:
                        return self._failure("H7_SCOPE_REGISTRY_LOCK_TIMEOUT", "withheld")
                    registry = self._read_registry()
                    if registry is None:
                        return self._failure("H7_SCOPE_REGISTRY_INVALID", "withheld")
                    sessions = list(registry["sessions"])
                    worklines = list(registry["worklines"])
                    matching_sessions = [
                        item
                        for item in sessions
                        if item["workspaceKey"] == binding["workspaceKey"]
                        and item["ownerSessionKey"] == binding["ownerSessionKey"]
                    ]
                    if len(matching_sessions) > 1:
                        return self._failure("H7_SCOPE_REGISTRY_AMBIGUOUS", "withheld")
                    changed = False
                    if matching_sessions:
                        session = matching_sessions[0]
                    else:
                        if len(sessions) >= _MAX_REGISTRY_SESSIONS:
                            return self._failure("H7_SCOPE_REGISTRY_CAPACITY", "withheld")
                        session = {
                            "sessionId": "sbs-" + secrets.token_hex(16),
                            "workspaceKey": binding["workspaceKey"],
                            "ownerSessionKey": binding["ownerSessionKey"],
                            "createdAt": current_stamp,
                        }
                        sessions.append(session)
                        changed = True

                    matching_worklines = [
                        item
                        for item in worklines
                        if item["workspaceKey"] == binding["workspaceKey"]
                        and item["ownerSessionKey"] == binding["ownerSessionKey"]
                        and item["taskId"] == binding["taskId"]
                        and item["taskInstanceId"] == binding["taskInstanceId"]
                    ]
                    if len(matching_worklines) > 1:
                        return self._failure("H7_SCOPE_REGISTRY_AMBIGUOUS", "withheld")
                    if matching_worklines:
                        existing = matching_worklines[0]
                        result = self._refresh_existing_workline(existing, binding, current_stamp)
                        if result is None:
                            return self._failure("H7_SCOPE_CONTRACT_REVISION_STALE", "withheld")
                        if result is False:
                            return self._failure("H7_SCOPE_CONTRACT_HASH_CONFLICT", "withheld")
                        context, did_change = result
                        changed = changed or did_change
                    else:
                        if len(worklines) >= _MAX_REGISTRY_WORKLINES:
                            return self._failure("H7_SCOPE_REGISTRY_CAPACITY", "withheld")
                        workline_id = "sbw-" + secrets.token_hex(16)
                        context = ScopeContext(
                            session_id=session["sessionId"],
                            workline_id=workline_id,
                            workspace_key=binding["workspaceKey"],
                            owner_session_key=binding["ownerSessionKey"],
                            task_id=binding["taskId"],
                            task_instance_id=binding["taskInstanceId"],
                            package_version=binding["packageVersion"],
                            contract_revision=binding["contractRevision"],
                            contract_hash=binding["contractHash"],
                            scope_ref=_scope_ref(
                                session_id=session["sessionId"],
                                workline_id=workline_id,
                                workspace_key=binding["workspaceKey"],
                                owner_session_key=binding["ownerSessionKey"],
                            ),
                        )
                        worklines.append(context._record(created_at=current_stamp, updated_at=current_stamp))
                        changed = True
                    if changed:
                        registry["sessions"] = sessions
                        registry["worklines"] = worklines
                        registry["registryRevision"] = int(registry["registryRevision"]) + 1
                        self._write_registry(registry)
        except (OSError, TypeError, ValueError):
            return self._failure("H7_SCOPE_REGISTRY_WRITE_FAILED", "withheld")
        with self._memory_lock:
            for channel, stored in tuple(self._bindings.items()):
                if stored.workline_id == context.workline_id:
                    self._bindings[channel] = _ChannelBinding(
                        workline_id=stored.workline_id,
                        context=context,
                        access_mode=stored.access_mode,
                        lease_id=stored.lease_id,
                        lease_expires_at=stored.lease_expires_at,
                    )
        return ScopeBrokerResult(True, "H7_SCOPE_WORKLINE_CURRENT", "current", context=context)

    def get_workline(self, workline_id: str) -> ScopeBrokerResult:
        """Read one durable workline by its broker-generated opaque ID."""

        normalized = _safe_string(workline_id, _WORKLINE_ID_RE)
        if not normalized:
            return self._failure("H7_SCOPE_WORKLINE_ID_INVALID", "withheld")
        try:
            with _process_lock(self._lock_path):
                with _advisory_lock(self._lock_path) as acquired:
                    if not acquired:
                        return self._failure("H7_SCOPE_REGISTRY_LOCK_TIMEOUT", "withheld")
                    registry = self._read_registry()
        except OSError:
            return self._failure("H7_SCOPE_REGISTRY_UNAVAILABLE", "withheld")
        if registry is None:
            return self._failure("H7_SCOPE_REGISTRY_INVALID", "withheld")
        records = [item for item in registry["worklines"] if item["worklineId"] == normalized]
        if len(records) != 1:
            return self._failure("H7_SCOPE_WORKLINE_UNKNOWN", "withheld")
        return ScopeBrokerResult(True, "H7_SCOPE_WORKLINE_CURRENT", "current", context=self._context_from_record(records[0]))

    # -- In-memory channel binding and grants -----------------------------

    def open_channel(self) -> str:
        """Create a fresh private channel identity for one live connection."""

        channel_id, _ = self.open_channel_with_ref()
        return channel_id

    def open_channel_with_ref(self, *, now: datetime | None = None) -> tuple[str, str]:
        """Create a channel and its short-lived control-plane pairing ref."""

        with self._memory_lock:
            while True:
                channel_id = "sbc-" + secrets.token_hex(16)
                if channel_id not in self._channels:
                    self._channels.add(channel_id)
                    ref = "sbpr-" + secrets.token_hex(16)
                    expires_at = _utc_now(now) + timedelta(seconds=_PAIRING_REQUEST_REF_TTL_SECONDS)
                    self._pairing_requests[ref] = _PairingRequest(ref, channel_id, self._instance_id, expires_at)
                    self._channel_pairing_refs[channel_id] = ref
                    return channel_id, ref

    def pairing_request_ref(self, channel_id: str, *, now: datetime | None = None) -> str:
        """Return the current unbound pairing ref for one channel."""

        channel = _safe_string(channel_id, _CHANNEL_ID_RE)
        if not channel:
            return ""
        current_time = _utc_now(now)
        with self._memory_lock:
            self._expire_pairing_requests(current_time)
            if channel not in self._channels or channel in self._bindings:
                return ""
            return self._ensure_pairing_request_locked(channel, now=current_time)

    def pairing_request_channel(self, pairing_request_ref: str, *, now: datetime | None = None) -> str:
        """Resolve a live request ref to its channel for internal touch only.

        The channel ID never leaves the authenticated Broker process through
        this helper; it exists solely to keep an unbound connection alive
        while the control plane consumes its request reference.
        """

        ref = _safe_string(pairing_request_ref, _PAIRING_REQUEST_REF_RE)
        if not ref:
            return ""
        current_time = _utc_now(now)
        with self._memory_lock:
            self._expire_pairing_requests(current_time)
            request = self._pairing_requests.get(ref)
            if (
                request is None
                or request.broker_instance_id != self._instance_id
                or request.channel_id not in self._channels
                or request.channel_id in self._bindings
            ):
                return ""
            return request.channel_id

    def pair_request(
        self,
        pairing_request_ref: str,
        workline_id: str,
        *,
        access_mode: str = "write",
        ttl_seconds: int = 60,
        lease_seconds: int = _DEFAULT_LEASE_SECONDS,
        now: datetime | None = None,
    ) -> ScopeBrokerResult:
        """Consume one connection-owned ref and explicitly pair that channel."""

        ref = _safe_string(pairing_request_ref, _PAIRING_REQUEST_REF_RE)
        workline = _safe_string(workline_id, _WORKLINE_ID_RE)
        mode = self._access_mode(access_mode)
        grant_ttl = self._ttl(ttl_seconds, _MIN_GRANT_TTL_SECONDS, _MAX_GRANT_TTL_SECONDS)
        lease_ttl = self._ttl(lease_seconds, _MIN_LEASE_SECONDS, _MAX_LEASE_SECONDS)
        if not ref:
            return self._failure("H7_SCOPE_PAIRING_REQUEST_REF_INVALID", "withheld")
        if not workline:
            return self._failure("H7_SCOPE_WORKLINE_ID_INVALID", "withheld")
        if not mode:
            return self._failure("H7_SCOPE_ACCESS_MODE_INVALID", "withheld")
        # ``pair_request`` consumes its own short-lived capability directly;
        # retain the legacy grant-TTL validation so public control-plane
        # callers cannot accidentally accept values that the compatible
        # channel-ID path rejects.
        if grant_ttl is None:
            return self._failure("H7_SCOPE_PAIRING_TTL_INVALID", "withheld")
        if lease_ttl is None:
            return self._failure("H7_SCOPE_LEASE_TTL_INVALID", "withheld")
        current_time = _utc_now(now)
        # Read the durable workline while holding the registry lock, then
        # take the in-memory channel lock only for the final bind.  This is
        # deliberately registry -> memory, matching registration's order.
        # The former implementation held ``_memory_lock`` while calling
        # ``pair_channel``; its nested durable lookup inverted that order
        # against ``register_workline`` and could stall all live channels.
        try:
            with _process_lock(self._lock_path):
                with _advisory_lock(self._lock_path) as acquired:
                    if not acquired:
                        return self._failure("H7_SCOPE_REGISTRY_LOCK_TIMEOUT", "withheld")
                    registry = self._read_registry()
                    if registry is None:
                        return self._failure("H7_SCOPE_REGISTRY_INVALID", "withheld")
                    records = [item for item in registry["worklines"] if item["worklineId"] == workline]
                    if len(records) != 1:
                        return self._failure("H7_SCOPE_WORKLINE_UNKNOWN", "withheld")
                    context = self._context_from_record(records[0])
                    if context is None:
                        return self._failure("H7_SCOPE_REGISTRY_INVALID", "withheld")
                    with self._memory_lock:
                        self._expire_bindings(current_time)
                        self._expire_pairing_requests(current_time)
                        request = self._pairing_requests.get(ref)
                        if request is None:
                            return self._failure("H7_SCOPE_PAIRING_REQUEST_REF_EXPIRED", "withheld")
                        if request.broker_instance_id != self._instance_id:
                            return self._failure("H7_SCOPE_PAIRING_REQUEST_REF_INSTANCE_MISMATCH", "withheld")
                        channel_id = request.channel_id
                        if channel_id not in self._channels:
                            self._pairing_requests.pop(ref, None)
                            self._channel_pairing_refs.pop(channel_id, None)
                            return self._failure("H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", "withheld")
                        if channel_id in self._bindings:
                            return self._failure("H7_SCOPE_CHANNEL_ALREADY_BOUND", "withheld")
                        if mode == "write" and context.workline_id in self._write_leases:
                            return self._failure("H7_SCOPE_WRITE_LEASE_HELD", "withheld")
                        binding = _ChannelBinding(
                            workline_id=context.workline_id,
                            context=context,
                            access_mode=mode,
                            lease_id="sbl-" + secrets.token_hex(16),
                            lease_expires_at=current_time + timedelta(seconds=lease_ttl),
                        )
                        self._bindings[channel_id] = binding
                        if mode == "write":
                            self._write_leases[context.workline_id] = channel_id
                        self._pairing_requests.pop(ref, None)
                        self._channel_pairing_refs.pop(channel_id, None)
                        return ScopeBrokerResult(
                            True,
                            "H7_SCOPE_CHANNEL_BOUND",
                            "bound",
                            context=context,
                            access_mode=binding.access_mode,
                            lease_id=binding.lease_id,
                            lease_expires_at=_timestamp(binding.lease_expires_at),
                        )
        except OSError:
            return self._failure("H7_SCOPE_REGISTRY_UNAVAILABLE", "withheld")

    def issue_pairing_grant(
        self,
        channel_id: str,
        workline_id: str,
        *,
        access_mode: str = "write",
        ttl_seconds: int = 60,
        now: datetime | None = None,
    ) -> PairingGrant | ScopeBrokerResult:
        """Issue a one-shot grant targeted to one currently unbound channel."""

        channel = _safe_string(channel_id, _CHANNEL_ID_RE)
        workline = _safe_string(workline_id, _WORKLINE_ID_RE)
        mode = self._access_mode(access_mode)
        ttl = self._ttl(ttl_seconds, _MIN_GRANT_TTL_SECONDS, _MAX_GRANT_TTL_SECONDS)
        if not channel:
            return self._failure("H7_SCOPE_CHANNEL_ID_INVALID", "withheld")
        if not workline:
            return self._failure("H7_SCOPE_WORKLINE_ID_INVALID", "withheld")
        if not mode:
            return self._failure("H7_SCOPE_ACCESS_MODE_INVALID", "withheld")
        if ttl is None:
            return self._failure("H7_SCOPE_PAIRING_TTL_INVALID", "withheld")
        current_time = _utc_now(now)
        with self._memory_lock:
            self._expire_bindings(current_time)
            self._prune_grants(current_time)
            if channel not in self._channels:
                return self._failure("H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", "withheld")
            if channel in self._bindings:
                return self._failure("H7_SCOPE_CHANNEL_ALREADY_BOUND", "withheld")
        workline_result = self.get_workline(workline)
        if not workline_result.ok:
            return workline_result
        expires_at = current_time + timedelta(seconds=ttl)
        with self._memory_lock:
            self._expire_bindings(current_time)
            if len(self._grants) >= _MAX_GRANTS:
                self._prune_grants(current_time, aggressive=True)
                if len(self._grants) >= _MAX_GRANTS:
                    return self._failure("H7_SCOPE_PAIRING_CAPACITY", "withheld")
            if channel not in self._channels:
                return self._failure("H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", "withheld")
            if channel in self._bindings:
                return self._failure("H7_SCOPE_CHANNEL_ALREADY_BOUND", "withheld")
            while True:
                token = "sbpg-v1." + secrets.token_urlsafe(32)
                token_digest = _token_hash(token)
                if token_digest not in self._grants:
                    break
            self._grants[token_digest] = _GrantRecord(
                token_hash=token_digest,
                channel_id=channel,
                workline_id=workline,
                access_mode=mode,
                expires_at=expires_at,
            )
        return PairingGrant(token=token, expires_at=_timestamp(expires_at), access_mode=mode)

    def attach_channel(
        self,
        channel_id: str,
        pairing_grant: str,
        *,
        lease_seconds: int = _DEFAULT_LEASE_SECONDS,
        now: datetime | None = None,
    ) -> ScopeBrokerResult:
        """Consume a channel-targeted grant and bind that channel to its scope."""

        channel = _safe_string(channel_id, _CHANNEL_ID_RE)
        lease = self._ttl(lease_seconds, _MIN_LEASE_SECONDS, _MAX_LEASE_SECONDS)
        if not channel:
            return self._failure("H7_SCOPE_CHANNEL_ID_INVALID", "withheld")
        if not isinstance(pairing_grant, str) or not _PAIRING_TOKEN_RE.fullmatch(pairing_grant):
            return self._failure("H7_SCOPE_PAIRING_GRANT_INVALID", "withheld")
        if lease is None:
            return self._failure("H7_SCOPE_LEASE_TTL_INVALID", "withheld")
        current_time = _utc_now(now)
        token_digest = _token_hash(pairing_grant)
        with self._memory_lock:
            self._expire_bindings(current_time)
            self._expire_pairing_requests(current_time)
            if channel not in self._channels:
                return self._failure("H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", "withheld")
            if channel in self._bindings:
                return self._failure("H7_SCOPE_CHANNEL_ALREADY_BOUND", "withheld")
            grant = self._grants.get(token_digest)
            if grant is None:
                return self._failure("H7_SCOPE_PAIRING_GRANT_INVALID", "withheld")
            if grant.used:
                return self._failure("H7_SCOPE_PAIRING_GRANT_REPLAYED", "withheld")
            if current_time >= grant.expires_at:
                return self._failure("H7_SCOPE_PAIRING_GRANT_EXPIRED", "withheld")
            if grant.channel_id != channel:
                return self._failure("H7_SCOPE_PAIRING_GRANT_CHANNEL_MISMATCH", "withheld")
            if grant.access_mode == "write" and grant.workline_id in self._write_leases:
                return self._failure("H7_SCOPE_WRITE_LEASE_HELD", "withheld")
        workline_result = self.get_workline(grant.workline_id)
        if not workline_result.ok or workline_result.context is None:
            return self._failure("H7_SCOPE_WORKLINE_UNKNOWN", "withheld")
        expires_at = current_time + timedelta(seconds=lease)
        with self._memory_lock:
            # The control-plane lookup occurred outside the in-memory lock;
            # recheck all transient conditions before consuming the capability.
            self._expire_bindings(current_time)
            grant = self._grants.get(token_digest)
            if grant is None:
                return self._failure("H7_SCOPE_PAIRING_GRANT_INVALID", "withheld")
            if grant.used:
                return self._failure("H7_SCOPE_PAIRING_GRANT_REPLAYED", "withheld")
            if current_time >= grant.expires_at:
                return self._failure("H7_SCOPE_PAIRING_GRANT_EXPIRED", "withheld")
            if channel not in self._channels:
                return self._failure("H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", "withheld")
            if channel in self._bindings:
                return self._failure("H7_SCOPE_CHANNEL_ALREADY_BOUND", "withheld")
            if grant.channel_id != channel:
                return self._failure("H7_SCOPE_PAIRING_GRANT_CHANNEL_MISMATCH", "withheld")
            if grant.access_mode == "write" and grant.workline_id in self._write_leases:
                return self._failure("H7_SCOPE_WRITE_LEASE_HELD", "withheld")
            lease_id = "sbl-" + secrets.token_hex(16)
            binding = _ChannelBinding(
                workline_id=grant.workline_id,
                context=workline_result.context,
                access_mode=grant.access_mode,
                lease_id=lease_id,
                lease_expires_at=expires_at,
            )
            self._bindings[channel] = binding
            pairing_ref = self._channel_pairing_refs.pop(channel, "")
            if pairing_ref:
                self._pairing_requests.pop(pairing_ref, None)
            if grant.access_mode == "write":
                self._write_leases[grant.workline_id] = channel
            grant.used = True
        return ScopeBrokerResult(
            True,
            "H7_SCOPE_CHANNEL_BOUND",
            "bound",
            context=workline_result.context,
            access_mode=binding.access_mode,
            lease_id=binding.lease_id,
            lease_expires_at=_timestamp(binding.lease_expires_at),
        )

    def pair_channel(
        self,
        channel_id: str,
        workline_id: str,
        *,
        access_mode: str = "write",
        ttl_seconds: int = 60,
        lease_seconds: int = _DEFAULT_LEASE_SECONDS,
        now: datetime | None = None,
    ) -> ScopeBrokerResult:
        """Atomically pair one unbound channel without exposing a token.

        The lower-level grant/attach methods remain available to a narrow
        in-process compatibility seam and to regression tests.  Transport
        control surfaces should call this method instead: the one-shot token
        is created, consumed, and discarded while the broker lock is held, so
        it cannot leak through command-line arguments, logs, or JSON output.
        """

        # ``issue_pairing_grant`` and ``attach_channel`` each take the memory
        # lock and recheck all transient state at their commit boundary.  Do
        # not hold that lock across the durable ``get_workline`` lookup inside
        # those helpers: pairing one channel must not stall status/open/close
        # operations for every other live channel.
        grant = self.issue_pairing_grant(
            channel_id,
            workline_id,
            access_mode=access_mode,
            ttl_seconds=ttl_seconds,
            now=now,
        )
        if isinstance(grant, ScopeBrokerResult):
            return grant
        result = self.attach_channel(
            channel_id,
            grant.token,
            lease_seconds=lease_seconds,
            now=now,
        )
        if result.ok:
            return result
        # A failed attach normally leaves the grant unused.  Remove that
        # transient capability so a control-plane race cannot accumulate an
        # unconsumed token in the resident broker.
        try:
            with self._memory_lock:
                self._grants.pop(_token_hash(grant.token), None)
        except Exception:
            pass
        return result

    def status(self, channel_id: str, *, now: datetime | None = None) -> ScopeBrokerResult:
        """Return only the current channel's safe binding projection."""

        channel = _safe_string(channel_id, _CHANNEL_ID_RE)
        if not channel:
            return self._failure("H7_SCOPE_CHANNEL_ID_INVALID", "withheld")
        current_time = _utc_now(now)
        with self._memory_lock:
            expired = self._expire_bindings(current_time)
            self._expire_pairing_requests(current_time)
            if channel not in self._channels:
                return self._failure("H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", "withheld")
            if channel in expired:
                return ScopeBrokerResult(
                    False,
                    "H7_SCOPE_CHANNEL_LEASE_EXPIRED",
                    "unbound",
                    pairing_request_ref=self._ensure_pairing_request_locked(channel, now=current_time),
                )
            binding = self._bindings.get(channel)
            if binding is None:
                pairing_ref = self._ensure_pairing_request_locked(channel, now=current_time)
                return ScopeBrokerResult(
                    True,
                    "H7_SCOPE_CHANNEL_UNBOUND",
                    "unbound",
                    pairing_request_ref=pairing_ref,
                )
            return ScopeBrokerResult(
                True,
                "H7_SCOPE_CHANNEL_BOUND",
                "bound",
                context=binding.context,
                access_mode=binding.access_mode,
                lease_id=binding.lease_id,
                lease_expires_at=_timestamp(binding.lease_expires_at),
            )

    def authorize(
        self,
        channel_id: str,
        *,
        write: bool = False,
        now: datetime | None = None,
    ) -> ScopeBrokerResult:
        """Read the channel-bound immutable context for a proposed operation."""

        if not isinstance(write, bool):
            return self._failure("H7_SCOPE_WRITE_FLAG_INVALID", "withheld")
        result = self.status(channel_id, now=now)
        if not result.ok:
            return result
        if result.context is None:
            # ``status`` intentionally reports a healthy-but-unbound channel
            # as ``ok`` so control-plane callers can distinguish it from an
            # unknown or failed channel.  Authorization has stricter
            # semantics: without the broker-owned immutable context it must
            # never grant an operation.
            if result.code == "H7_SCOPE_CHANNEL_UNBOUND" or result.state == "unbound":
                return self._failure("H7_SCOPE_CHANNEL_UNBOUND", "unbound")
            return self._failure("H7_SCOPE_BROKER_CONTEXT_MISSING", "withheld")
        if write and result.access_mode != "write":
            return self._failure("H7_SCOPE_WRITE_LEASE_REQUIRED", "withheld", context=result.context)
        return ScopeBrokerResult(
            True,
            "H7_SCOPE_AUTHORIZED",
            "authorized",
            context=result.context,
            access_mode=result.access_mode,
            lease_id=result.lease_id,
            lease_expires_at=result.lease_expires_at,
        )

    def renew_lease(
        self,
        channel_id: str,
        lease_id: str,
        *,
        lease_seconds: int = _DEFAULT_LEASE_SECONDS,
        now: datetime | None = None,
    ) -> ScopeBrokerResult:
        """Renew one exact live channel lease; a channel cannot renew another."""

        channel = _safe_string(channel_id, _CHANNEL_ID_RE)
        lease_token = _safe_string(lease_id, _LEASE_ID_RE)
        duration = self._ttl(lease_seconds, _MIN_LEASE_SECONDS, _MAX_LEASE_SECONDS)
        if not channel or not lease_token:
            return self._failure("H7_SCOPE_LEASE_ID_INVALID", "withheld")
        if duration is None:
            return self._failure("H7_SCOPE_LEASE_TTL_INVALID", "withheld")
        current_time = _utc_now(now)
        with self._memory_lock:
            expired = self._expire_bindings(current_time)
            if channel not in self._channels:
                return self._failure("H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", "withheld")
            if channel in expired:
                return self._failure("H7_SCOPE_CHANNEL_LEASE_EXPIRED", "unbound")
            binding = self._bindings.get(channel)
            if binding is None:
                return self._failure("H7_SCOPE_CHANNEL_UNBOUND", "unbound")
            if not secrets.compare_digest(binding.lease_id, lease_token):
                return self._failure("H7_SCOPE_LEASE_MISMATCH", "withheld")
            binding.lease_expires_at = current_time + timedelta(seconds=duration)
            return ScopeBrokerResult(
                True,
                "H7_SCOPE_LEASE_RENEWED",
                "bound",
                context=binding.context,
                access_mode=binding.access_mode,
                lease_id=binding.lease_id,
                lease_expires_at=_timestamp(binding.lease_expires_at),
            )

    def detach_channel(self, channel_id: str) -> ScopeBrokerResult:
        """Release a channel binding and any associated write lease."""

        channel = _safe_string(channel_id, _CHANNEL_ID_RE)
        if not channel:
            return self._failure("H7_SCOPE_CHANNEL_ID_INVALID", "withheld")
        with self._memory_lock:
            if channel not in self._channels:
                return self._failure("H7_SCOPE_CHANNEL_UNKNOWN_OR_RESTARTED", "withheld")
            binding = self._bindings.pop(channel, None)
            if binding is None:
                pairing_ref = self._ensure_pairing_request_locked(channel)
                return ScopeBrokerResult(True, "H7_SCOPE_CHANNEL_UNBOUND", "unbound", pairing_request_ref=pairing_ref)
            if binding.access_mode == "write" and self._write_leases.get(binding.workline_id) == channel:
                self._write_leases.pop(binding.workline_id, None)
            pairing_ref = self._ensure_pairing_request_locked(channel, replace=True)
            return ScopeBrokerResult(
                True,
                "H7_SCOPE_CHANNEL_DETACHED",
                "unbound",
                context=binding.context,
                access_mode=binding.access_mode,
                pairing_request_ref=pairing_ref,
            )

    def close_channel(self, channel_id: str) -> ScopeBrokerResult:
        """Forget a transport channel permanently within this broker lifetime."""

        result = self.detach_channel(channel_id)
        channel = _safe_string(channel_id, _CHANNEL_ID_RE)
        if not channel or not result.ok:
            return result
        with self._memory_lock:
            self._channels.discard(channel)
            ref = self._channel_pairing_refs.pop(channel, "")
            if ref:
                self._pairing_requests.pop(ref, None)
        return ScopeBrokerResult(True, "H7_SCOPE_CHANNEL_CLOSED", "closed", context=result.context)

    def refresh_bound_contract(
        self,
        channel_id: str,
        lease_id: str,
        contract: Mapping[str, Any],
        *,
        now: datetime | None = None,
    ) -> ScopeBrokerResult:
        """Refresh one already-bound write channel after an H7 contract commit.

        This is an internal runtime operation.  It never selects a workline:
        the channel and its existing write lease identify the only allowed
        binding, and the incoming contract must match that identity exactly.
        """

        channel = _safe_string(channel_id, _CHANNEL_ID_RE)
        lease = _safe_string(lease_id, _LEASE_ID_RE)
        if not channel or not lease:
            return self._failure("H7_SCOPE_CONTRACT_REFRESH_AUTH_INVALID", "withheld")
        if not isinstance(contract, Mapping):
            return self._failure("H7_SCOPE_CONTRACT_INVALID", "withheld")
        try:
            encoded = json.dumps(
                dict(contract),
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
        except (TypeError, ValueError):
            return self._failure("H7_SCOPE_CONTRACT_INVALID", "withheld")
        expected_hash = hashlib.sha256(encoded).hexdigest()
        try:
            incoming = self._contract_binding(contract, expected_contract_hash=expected_hash)
        except ValueError as error:
            return self._failure(str(error), "withheld")
        current_time = _utc_now(now)
        with self._memory_lock:
            self._expire_bindings(current_time)
            stored = self._bindings.get(channel)
            if channel not in self._channels or stored is None:
                return self._failure("H7_SCOPE_CHANNEL_UNBOUND", "unbound")
            if stored.access_mode != "write":
                return self._failure("H7_SCOPE_WRITE_LEASE_REQUIRED", "withheld", context=stored.context)
            if not secrets.compare_digest(stored.lease_id, lease):
                return self._failure("H7_SCOPE_LEASE_MISMATCH", "withheld", context=stored.context)
            prior = stored.context
            if any(
                (
                    incoming["workspaceKey"] != prior.workspace_key,
                    incoming["ownerSessionKey"] != prior.owner_session_key,
                    incoming["taskId"] != prior.task_id,
                    incoming["taskInstanceId"] != prior.task_instance_id,
                    incoming["packageVersion"] != prior.package_version,
                )
            ):
                return self._failure("H7_SCOPE_CONTRACT_IDENTITY_MISMATCH", "withheld", context=prior)
            if incoming["contractRevision"] < prior.contract_revision:
                return self._failure("H7_SCOPE_CONTRACT_REVISION_STALE", "withheld", context=prior)
            if incoming["contractRevision"] == prior.contract_revision and incoming["contractHash"] != prior.contract_hash:
                return self._failure("H7_SCOPE_CONTRACT_HASH_CONFLICT", "withheld", context=prior)
            workline_id = prior.workline_id
            prior_access_mode = stored.access_mode
            prior_lease_expiry = stored.lease_expires_at

        # ``register_workline`` performs the durable CAS-like revision/hash
        # update and refreshes all in-process bindings for this workline.  The
        # binding guard in the IPC server closes the detach/rebind race around
        # this call; the final check below protects direct in-process callers.
        result = self.register_workline(contract, expected_contract_hash=expected_hash, now=now)
        if not result.ok or result.context is None:
            return result
        with self._memory_lock:
            current = self._bindings.get(channel)
            if (
                current is None
                or current.workline_id != workline_id
                or current.access_mode != prior_access_mode
                or not secrets.compare_digest(current.lease_id, lease)
            ):
                return self._failure("H7_SCOPE_CONTRACT_REFRESH_RACE", "withheld")
            self._bindings[channel] = _ChannelBinding(
                workline_id=current.workline_id,
                context=result.context,
                access_mode=current.access_mode,
                lease_id=current.lease_id,
                lease_expires_at=prior_lease_expiry,
            )
        return ScopeBrokerResult(
            True,
            "H7_SCOPE_CONTRACT_PROJECTION_REFRESHED",
            "bound",
            context=result.context,
            access_mode=prior_access_mode,
            lease_expires_at=_timestamp(prior_lease_expiry),
        )

    # -- Internal validation/persistence ----------------------------------

    @staticmethod
    def _failure(code: str, state: str, *, context: ScopeContext | None = None) -> ScopeBrokerResult:
        return ScopeBrokerResult(False, code, state, context=context)

    @staticmethod
    def _access_mode(value: Any) -> str:
        return str(value) if isinstance(value, str) and value in {"read", "write"} else ""

    @staticmethod
    def _ttl(value: Any, minimum: int, maximum: int) -> int | None:
        if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
            return None
        return value

    def _contract_binding(
        self,
        contract: Mapping[str, Any],
        *,
        expected_contract_hash: str | None,
    ) -> dict[str, Any]:
        if not isinstance(contract, Mapping):
            raise ValueError("H7_SCOPE_CONTRACT_INVALID")
        try:
            encoded = json.dumps(dict(contract), ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        except (TypeError, ValueError):
            raise ValueError("H7_SCOPE_CONTRACT_INVALID") from None
        if not encoded or len(encoded) > _MAX_CONTRACT_BYTES:
            raise ValueError("H7_SCOPE_CONTRACT_INVALID")
        if contract.get("schema") != "super-brain.execution-contract.v1" or contract.get("status") != "active":
            raise ValueError("H7_SCOPE_CONTRACT_NOT_CURRENT")
        for key in ("rawPromptStored", "rawTranscriptStored"):
            if key in contract and contract.get(key) is not False:
                raise ValueError("H7_SCOPE_CONTRACT_PRIVACY_INVALID")
        workspace_key = _safe_string(contract.get("workspaceKey"), _WORKSPACE_KEY_RE).lower()
        owner_session_key = _safe_string(contract.get("ownerSessionKey"), _OWNER_SESSION_KEY_RE).lower()
        task_id = _safe_string(contract.get("taskId"), _TASK_ID_RE)
        task_instance_id = _safe_string(contract.get("taskInstanceId"), _TASK_INSTANCE_ID_RE).lower()
        package_version = _safe_string(contract.get("packageVersion"), _PACKAGE_VERSION_RE)
        revision = contract.get("revision")
        if (
            not workspace_key
            or not owner_session_key
            or not task_id
            or not task_instance_id
            or not package_version
            or isinstance(revision, bool)
            or not isinstance(revision, int)
            or not 0 <= revision <= 2_147_483_647
        ):
            raise ValueError("H7_SCOPE_CONTRACT_BINDING_INVALID")
        contract_hash = hashlib.sha256(encoded).hexdigest()
        expected = _safe_string(expected_contract_hash, _SHA256_RE)
        if not expected:
            raise ValueError("H7_SCOPE_CONTRACT_HASH_REQUIRED")
        if not secrets.compare_digest(contract_hash, expected):
            raise ValueError("H7_SCOPE_CONTRACT_HASH_MISMATCH")
        return {
            "workspaceKey": workspace_key,
            "ownerSessionKey": owner_session_key,
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "packageVersion": package_version,
            "contractRevision": revision,
            "contractHash": contract_hash,
        }

    def _refresh_existing_workline(
        self,
        existing: dict[str, Any],
        binding: dict[str, Any],
        updated_at: str,
    ) -> tuple[ScopeContext, bool] | bool | None:
        prior_revision = int(existing["contractRevision"])
        prior_hash = str(existing["contractHash"])
        incoming_revision = int(binding["contractRevision"])
        incoming_hash = str(binding["contractHash"])
        if incoming_revision < prior_revision:
            return None
        if incoming_revision == prior_revision and incoming_hash != prior_hash:
            return False
        context = ScopeContext(
            session_id=str(existing["sessionId"]),
            workline_id=str(existing["worklineId"]),
            workspace_key=binding["workspaceKey"],
            owner_session_key=binding["ownerSessionKey"],
            task_id=binding["taskId"],
            task_instance_id=binding["taskInstanceId"],
            package_version=binding["packageVersion"],
            contract_revision=incoming_revision,
            contract_hash=incoming_hash,
            scope_ref=str(existing["scopeRef"]),
        )
        changed = incoming_revision != prior_revision
        if changed:
            existing.update(context._record(created_at=str(existing["createdAt"]), updated_at=updated_at))
        return context, changed

    def _empty_registry(self) -> dict[str, Any]:
        body = {
            "schema": REGISTRY_SCHEMA,
            "registryRevision": 0,
            "sessions": [],
            "worklines": [],
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return {**body, "payloadHash": _canonical_hash(body)}

    def _read_registry(self) -> dict[str, Any] | None:
        if not self._registry_path.exists():
            return self._empty_registry()
        try:
            raw = self._registry_path.read_bytes()
            value = json.loads(raw.decode("utf-8"))
            return value if self._registry_valid(value) else None
        except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
            return None

    def _write_registry(self, registry: dict[str, Any]) -> None:
        body = {key: value for key, value in registry.items() if key != "payloadHash"}
        registry["payloadHash"] = _canonical_hash(body)
        if not self._registry_valid(registry):
            raise ValueError("invalid registry")
        _atomic_json(self._registry_path, registry)

    def _registry_valid(self, registry: Any) -> bool:
        if not isinstance(registry, dict) or set(registry) != _REGISTRY_FIELDS:
            return False
        try:
            body = {key: value for key, value in registry.items() if key != "payloadHash"}
            calculated_hash = _canonical_hash(body)
        except (TypeError, ValueError):
            return False
        if (
            registry.get("schema") != REGISTRY_SCHEMA
            or isinstance(registry.get("registryRevision"), bool)
            or not isinstance(registry.get("registryRevision"), int)
            or int(registry["registryRevision"]) < 0
            or registry.get("rawPromptStored") is not False
            or registry.get("rawTranscriptStored") is not False
            or not isinstance(registry.get("payloadHash"), str)
            or not _SHA256_RE.fullmatch(str(registry["payloadHash"]))
            or calculated_hash != registry["payloadHash"]
            or not isinstance(registry.get("sessions"), list)
            or not isinstance(registry.get("worklines"), list)
            or len(registry["sessions"]) > _MAX_REGISTRY_SESSIONS
            or len(registry["worklines"]) > _MAX_REGISTRY_WORKLINES
        ):
            return False
        sessions: dict[str, dict[str, Any]] = {}
        for item in registry["sessions"]:
            if not isinstance(item, dict) or set(item) != _SESSION_FIELDS:
                return False
            session_id = _safe_string(item.get("sessionId"), _BROKER_SESSION_ID_RE)
            workspace_key = _safe_string(item.get("workspaceKey"), _WORKSPACE_KEY_RE).lower()
            owner_key = _safe_string(item.get("ownerSessionKey"), _OWNER_SESSION_KEY_RE).lower()
            if not session_id or not workspace_key or not owner_key or _parse_timestamp(item.get("createdAt")) is None or session_id in sessions:
                return False
            sessions[session_id] = item
        worklines: set[str] = set()
        workline_identity: set[tuple[str, str, str, str]] = set()
        for item in registry["worklines"]:
            if not isinstance(item, dict) or set(item) != _WORKLINE_FIELDS:
                return False
            context = self._context_from_record(item, strict=False)
            if context is None or context.workline_id in worklines:
                return False
            session = sessions.get(context.session_id)
            if session is None or session["workspaceKey"] != context.workspace_key or session["ownerSessionKey"] != context.owner_session_key:
                return False
            if _parse_timestamp(item.get("createdAt")) is None or _parse_timestamp(item.get("updatedAt")) is None:
                return False
            identity = (context.workspace_key, context.owner_session_key, context.task_id, context.task_instance_id)
            if identity in workline_identity:
                return False
            worklines.add(context.workline_id)
            workline_identity.add(identity)
        return True

    def _context_from_record(self, record: Mapping[str, Any], *, strict: bool = True) -> ScopeContext | None:
        try:
            session_id = _safe_string(record.get("sessionId"), _BROKER_SESSION_ID_RE)
            workline_id = _safe_string(record.get("worklineId"), _WORKLINE_ID_RE)
            workspace_key = _safe_string(record.get("workspaceKey"), _WORKSPACE_KEY_RE).lower()
            owner_session_key = _safe_string(record.get("ownerSessionKey"), _OWNER_SESSION_KEY_RE).lower()
            task_id = _safe_string(record.get("taskId"), _TASK_ID_RE)
            task_instance_id = _safe_string(record.get("taskInstanceId"), _TASK_INSTANCE_ID_RE).lower()
            package_version = _safe_string(record.get("packageVersion"), _PACKAGE_VERSION_RE)
            revision = record.get("contractRevision")
            contract_hash = _safe_string(record.get("contractHash"), _SHA256_RE)
            scope_ref = _safe_string(record.get("scopeRef"), _SHA256_RE)
            if (
                not session_id
                or not workline_id
                or not workspace_key
                or not owner_session_key
                or not task_id
                or not task_instance_id
                or not package_version
                or isinstance(revision, bool)
                or not isinstance(revision, int)
                or not 0 <= revision <= 2_147_483_647
                or not contract_hash
                or scope_ref != _scope_ref(
                    session_id=session_id,
                    workline_id=workline_id,
                    workspace_key=workspace_key,
                    owner_session_key=owner_session_key,
                )
            ):
                return None
            return ScopeContext(
                session_id=session_id,
                workline_id=workline_id,
                workspace_key=workspace_key,
                owner_session_key=owner_session_key,
                task_id=task_id,
                task_instance_id=task_instance_id,
                package_version=package_version,
                contract_revision=revision,
                contract_hash=contract_hash,
                scope_ref=scope_ref,
            )
        except (AttributeError, TypeError, ValueError):
            if strict:
                return None
            return None

    def _expire_bindings(self, now: datetime) -> set[str]:
        expired: set[str] = set()
        for channel, binding in tuple(self._bindings.items()):
            if now < binding.lease_expires_at:
                continue
            expired.add(channel)
            self._bindings.pop(channel, None)
            if binding.access_mode == "write" and self._write_leases.get(binding.workline_id) == channel:
                self._write_leases.pop(binding.workline_id, None)
        return expired

    def _ensure_pairing_request_locked(
        self,
        channel_id: str,
        *,
        replace: bool = False,
        now: datetime | None = None,
    ) -> str:
        current_time = _utc_now(now)
        current = self._channel_pairing_refs.get(channel_id, "")
        if current and not replace:
            request = self._pairing_requests.get(current)
            if (
                request is not None
                and request.broker_instance_id == self._instance_id
                and request.channel_id == channel_id
                and request.expires_at > current_time
            ):
                return current
        if current:
            self._pairing_requests.pop(current, None)
        ref = "sbpr-" + secrets.token_hex(16)
        self._channel_pairing_refs[channel_id] = ref
        self._pairing_requests[ref] = _PairingRequest(
            ref,
            channel_id,
            self._instance_id,
            current_time + timedelta(seconds=_PAIRING_REQUEST_REF_TTL_SECONDS),
        )
        return ref

    def _expire_pairing_requests(self, now: datetime) -> None:
        for ref, request in tuple(self._pairing_requests.items()):
            if (
                request.expires_at <= now
                or request.broker_instance_id != self._instance_id
                or request.channel_id not in self._channels
                or request.channel_id in self._bindings
            ):
                self._pairing_requests.pop(ref, None)
                if self._channel_pairing_refs.get(request.channel_id) == ref:
                    self._channel_pairing_refs.pop(request.channel_id, None)

    def _prune_grants(self, now: datetime, *, aggressive: bool = False) -> None:
        for token_digest, grant in tuple(self._grants.items()):
            if now >= grant.expires_at or (aggressive and grant.used):
                self._grants.pop(token_digest, None)
        if len(self._grants) <= _MAX_GRANTS:
            return
        for token_digest in list(self._grants)[: len(self._grants) - _MAX_GRANTS]:
            self._grants.pop(token_digest, None)


__all__ = [
    "CONTEXT_SCHEMA",
    "PAIRING_GRANT_SCHEMA",
    "REGISTRY_SCHEMA",
    "PairingGrant",
    "ScopeBroker",
    "ScopeBrokerResult",
    "ScopeContext",
]
