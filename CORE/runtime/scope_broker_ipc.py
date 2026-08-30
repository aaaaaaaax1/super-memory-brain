"""Authenticated loopback IPC for the Super Brain Scope Broker.

The MCP adapter talks to one resident broker through a short JSON-lines RPC.
Only the broker keeps channel bindings, pairing grants, and write leases in
memory.  The endpoint and secret are private state files; neither is emitted
by normal MCP responses.  This module intentionally has no Host, Codex thread,
or environment-derived scope logic.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import hmac
import json
import os
import secrets
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from scope_broker import ScopeBroker, ScopeBrokerResult


ENDPOINT_SCHEMA = "super-brain.scope-broker-endpoint.v1"
_MAX_LINE = 512 * 1024
_MAX_PARAMS = 512 * 1024
_CONNECT_TIMEOUT = 2.0
_READ_TIMEOUT = 4.0
_START_LOCK_TIMEOUT = 4.0
_NONCE_TTL_SECONDS = 300.0
_MAX_SEEN_NONCES = 4096
_ENDPOINT_MAX_BYTES = 16 * 1024
_MIN_NONCE_LENGTH = 16
_MAX_NONCE_LENGTH = 128
_BROKER_IDLE_SECONDS = 10.0
# Broker shutdown and unbound-channel reclamation are separate lifecycles.
# A local MCP may be initialized first and paired by a trusted control client
# a little later; ten seconds is too short for that normal two-process path.
# Keep the broker's process idle budget small, but give an unbound channel a
# bounded pairing grace window.  Explicit close_channel still releases it
# immediately, so this does not pin a healthy client after normal teardown.
_UNBOUND_CHANNEL_GRACE_SECONDS = 120.0
PROJECT_ROOTS_SCHEMA = "super-brain.scope-broker-project-roots.v1"
_PROJECT_ROOTS_MAX_BYTES = 512 * 1024
_PROJECT_ROOTS_MAX_ENTRIES = 2048
_PROJECT_ROOTS_FIELDS = frozenset(
    {
        "schema",
        "registryRevision",
        "roots",
        "rawPromptStored",
        "rawTranscriptStored",
        "payloadHash",
    }
)
_PROJECT_ROOT_RECORD_FIELDS = frozenset(
    {
        "worklineId",
        "workspaceKey",
        "contractRevision",
        "contractHash",
        "projectRoot",
        "updatedAt",
        "rawPromptStored",
        "rawTranscriptStored",
    }
)


class ScopeBrokerAlreadyRunning(RuntimeError):
    """Raised when another broker already owns this state root."""

    def __init__(self, endpoint: Mapping[str, Any] | None = None) -> None:
        self.endpoint_data = dict(endpoint or {})
        super().__init__("scope broker is already running")


_LOCAL_LOCKS_GUARD = threading.Lock()
_LOCAL_LOCKS: dict[str, threading.RLock] = {}


def _local_lock(path: Path) -> threading.RLock:
    key = str(path.resolve()).lower()
    with _LOCAL_LOCKS_GUARD:
        value = _LOCAL_LOCKS.get(key)
        if value is None:
            value = threading.RLock()
            _LOCAL_LOCKS[key] = value
        return value


class _FileLease:
    """Cross-process advisory lock retained until ``release``.

    A process-local lock is layered over the OS lock because POSIX advisory
    locks are process-scoped and therefore do not serialize two descriptors
    opened by threads in this same process.
    """

    def __init__(self, path: Path, *, timeout: float = _START_LOCK_TIMEOUT) -> None:
        self.path = path
        self.timeout = max(0.1, float(timeout))
        self._local = _local_lock(path)
        self._handle: Any = None
        self._local_held = False
        self._held = False

    def acquire(self) -> bool:
        if not self._local.acquire(timeout=self.timeout):
            return False
        self._local_held = True
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            handle = self.path.open("a+b")
        except OSError:
            self.release()
            return False
        self._handle = handle
        try:
            handle.seek(0, os.SEEK_END)
            if handle.tell() == 0:
                handle.write(b"0")
                handle.flush()
            started = time.monotonic()
            while time.monotonic() - started < self.timeout:
                try:
                    handle.seek(0)
                    if os.name == "nt":
                        import msvcrt

                        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl

                        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self._held = True
                    return True
                except OSError as error:
                    if error.errno not in {errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK}:
                        break
                    time.sleep(0.01)
        except OSError:
            pass
        self.release()
        return False

    def release(self) -> None:
        handle, self._handle = self._handle, None
        if handle is not None and self._held:
            try:
                handle.seek(0)
                if os.name == "nt":
                    import msvcrt

                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
        self._held = False
        if handle is not None:
            try:
                handle.close()
            except OSError:
                pass
        if self._local_held:
            self._local_held = False
            try:
                self._local.release()
            except RuntimeError:
                pass

    def __enter__(self) -> "_FileLease":
        if not self.acquire():
            raise TimeoutError(f"could not acquire broker lock: {self.path}")
        return self

    def __exit__(self, *_: Any) -> None:
        self.release()


def _atomic_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(prefix=".scope-broker-secret-", suffix=".tmp", dir=str(path.parent))
    temporary = Path(raw_path)
    try:
        try:
            os.chmod(temporary, 0o600)
        except OSError:
            pass
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(prefix=".scope-broker-endpoint-", suffix=".tmp", dir=str(path.parent))
    temporary = Path(raw_path)
    try:
        try:
            os.chmod(temporary, 0o600)
        except OSError:
            pass
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(dict(value), handle, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _canonical_hash(value: Any) -> str:
    return hashlib.sha256(_canonical(value)).hexdigest()


def _workspace_key_for_root(root: Path) -> str:
    normalized = str(root.expanduser().resolve()).rstrip("/\\").lower()
    return "ws-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24]


def _read_private_json(path: Path, *, max_bytes: int) -> tuple[dict[str, Any] | None, bool]:
    """Read one broker-owned private JSON file.

    The boolean distinguishes a missing file (normal first boot) from a
    present-but-invalid file.  Invalid private state is never guessed through
    or silently replaced by a different scope.
    """

    try:
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or path.is_symlink() or info.st_size > max_bytes:
            return None, True
        if os.name != "nt" and stat.S_IMODE(info.st_mode) & 0o077:
            return None, True
        if hasattr(os, "getuid") and info.st_uid != os.getuid():
            return None, True
        raw = path.read_text(encoding="utf-8")
        value = json.loads(raw)
    except FileNotFoundError:
        return None, False
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
        return None, True
    return (value, False) if isinstance(value, dict) else (None, True)


def _canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _safe_path(root: str | Path) -> Path:
    return Path(root).expanduser().resolve()


def _pid_alive(pid: Any) -> bool:
    """Return whether a local endpoint owner process still exists."""

    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # The process exists but this user cannot probe it further.  The
        # authenticated ping below remains the authority for endpoint use.
        return True
    except (OSError, OverflowError):
        return False
    return True


def _read_endpoint_bundle(endpoint_path: Path, secret_path: Path) -> tuple[dict[str, Any], bytes] | None:
    """Read and validate the atomically-published endpoint/secret pair."""

    for path in (endpoint_path, secret_path):
        try:
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) or path.is_symlink():
                return None
            if path == endpoint_path and info.st_size > _ENDPOINT_MAX_BYTES:
                return None
            if path == secret_path and info.st_size != 32:
                return None
            if os.name != "nt" and stat.S_IMODE(info.st_mode) & 0o077:
                return None
            if hasattr(os, "getuid") and info.st_uid != os.getuid():
                return None
        except OSError:
            return None
    try:
        endpoint_value = json.loads(endpoint_path.read_text(encoding="utf-8"))
        secret = secret_path.read_bytes()
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(endpoint_value, dict) or len(secret) != 32:
        return None
    if endpoint_value.get("schema") != ENDPOINT_SCHEMA:
        return None
    if endpoint_value.get("host") != "127.0.0.1":
        return None
    port = endpoint_value.get("port")
    pid = endpoint_value.get("pid")
    instance_id = endpoint_value.get("instanceId")
    secret_sha256 = endpoint_value.get("secretSha256")
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        return None
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    if not isinstance(instance_id, str) or not (16 <= len(instance_id) <= 128):
        return None
    if not isinstance(secret_sha256, str) or len(secret_sha256) != 64:
        return None
    if not hmac.compare_digest(secret_sha256.lower(), hashlib.sha256(secret).hexdigest()):
        return None
    return endpoint_value, secret


def _remove_endpoint_pair(endpoint_path: Path, secret_path: Path) -> None:
    """Best-effort stale pair cleanup; callers must hold the broker lock."""

    for path in (endpoint_path, secret_path):
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass


def _probe_endpoint(endpoint: Mapping[str, Any], secret: bytes) -> bool:
    """Authenticate a cheap ping against one endpoint candidate."""

    nonce = secrets.token_urlsafe(18)
    values: dict[str, Any] = {}
    method = "ping"
    mac = hmac.new(secret, _canonical({"method": method, "params": values, "nonce": nonce}), hashlib.sha256).hexdigest()
    request = {"method": method, "params": values, "nonce": nonce, "mac": mac}
    try:
        with socket.create_connection((str(endpoint["host"]), int(endpoint["port"])), timeout=_CONNECT_TIMEOUT) as connection:
            connection.settimeout(_READ_TIMEOUT)
            connection.sendall(_canonical(request) + b"\n")
            raw = b""
            while b"\n" not in raw and len(raw) <= _MAX_LINE:
                chunk = connection.recv(8192)
                if not chunk:
                    break
                raw += chunk
        value = json.loads(raw.split(b"\n", 1)[0].decode("utf-8"))
        return (
            isinstance(value, dict)
            and value.get("ok") is True
            and value.get("code") == "H7_SCOPE_BROKER_PONG"
            and hmac.compare_digest(str(value.get("instanceId", "")), str(endpoint.get("instanceId", "")))
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        return False


class ScopeBrokerServer:
    """One process-wide broker service for all MCP adapter connections.

    ``broker.lock`` is held for the complete lifetime of the server.  This
    makes an endpoint replacement atomic with respect to concurrent startup,
    and means a stale endpoint can only be removed after the previous owner
    has exited (the OS releases its lock on an abnormal termination).
    """

    def __init__(
        self,
        state_root: str | Path,
        *,
        idle_seconds: float | None = None,
        unbound_channel_grace_seconds: float | None = None,
    ) -> None:
        self.state_root = _safe_path(state_root)
        self.runtime_root = self.state_root / "workspace" / "runtime-state" / "scope-broker"
        self.endpoint_path = self.runtime_root / "endpoint.json"
        self.secret_path = self.runtime_root / "secret.bin"
        self.project_roots_path = self.runtime_root / "project-roots.json"
        self._broker_lock_path = self.runtime_root / "broker.lock"
        self.broker = ScopeBroker(self.state_root)
        # The in-memory index retains the full private record rather than a
        # bare path, so every authorization can recheck the record against the
        # current durable workline revision/hash.
        self._project_roots: dict[str, dict[str, Any]] = {}
        self._project_root_registry_invalid = False
        self._project_root_lock = threading.RLock()
        self._socket: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._secret = b""
        self._instance_id = ""
        self._broker_lock: _FileLease | None = None
        self._last_activity = time.monotonic()
        self.idle_seconds = None if idle_seconds is None else max(0.1, float(idle_seconds))
        self._channel_last_seen: dict[str, float] = {}
        self._memory_nonce_lock = threading.RLock()
        self._seen_nonces: dict[str, float] = {}
        self._lifecycle_lock = threading.RLock()
        # Serialize binding mutations with the corresponding project-root
        # proof check.  Without one server-level guard, authorize/status could
        # read context A, a control client could rebind the channel to B, and
        # the response would still expose A after its root check completed.
        self._binding_guard = threading.RLock()
        self._shutdown_requested = False
        # Teardown is one-shot for each published broker instance.  Without
        # this guard a delayed second ``stop`` could remove a newer broker's
        # endpoint after this instance has already released its lifetime lock.
        self._stop_finalized = True
        self.unbound_channel_grace_seconds = (
            _UNBOUND_CHANNEL_GRACE_SECONDS
            if unbound_channel_grace_seconds is None
            else max(0.1, float(unbound_channel_grace_seconds))
        )

    def start(self) -> dict[str, Any]:
        # Serialize start/stop transitions.  The actual startup helper keeps
        # its existing error handling; the wrapper makes a concurrent stop
        # unable to observe a half-published instance as already finalized.
        with self._lifecycle_lock:
            try:
                return self._start_locked()
            finally:
                if self._socket is None:
                    self._stop_finalized = True

    def _start_locked(self) -> dict[str, Any]:
        if self._socket is not None:
            return self.endpoint()
        self._stop_finalized = False
        self.runtime_root.mkdir(parents=True, exist_ok=True)
        broker_lock = _FileLease(self._broker_lock_path)
        if not broker_lock.acquire():
            existing = _read_endpoint_bundle(self.endpoint_path, self.secret_path)
            raise ScopeBrokerAlreadyRunning(existing[0] if existing else None)
        self._broker_lock = broker_lock
        try:
            self._stop.clear()
            self._shutdown_requested = False
            self._channel_last_seen.clear()
            with self._memory_nonce_lock:
                self._seen_nonces.clear()
            # Channels, grants, and leases are intentionally process-local;
            # reconstructing the primitive prevents a stop/start cycle from
            # reviving capabilities issued by the previous server instance.
            self.broker = ScopeBroker(self.state_root)
            self._load_project_roots()
            existing = _read_endpoint_bundle(self.endpoint_path, self.secret_path)
            if existing is not None and _pid_alive(existing[0].get("pid")):
                # Holding the OS lock while the old process is alive indicates
                # a legacy owner that predates this lock, or a PID-reuse edge;
                # never overwrite an apparently live endpoint.  A failed ping
                # is not proof of death: the owner may be between publish and
                # listen, or temporarily busy.  Availability can be retried;
                # deleting a live owner's secret cannot be repaired safely.
                raise ScopeBrokerAlreadyRunning(existing[0])
            if existing is None:
                # A tampered or partially published pair may fail structural
                # validation while its owner is still alive.  Preserve it and
                # fail closed rather than deleting a live broker's secret.
                try:
                    raw_endpoint = json.loads(self.endpoint_path.read_text(encoding="utf-8"))
                    if isinstance(raw_endpoint, dict) and _pid_alive(raw_endpoint.get("pid")):
                        raise ScopeBrokerAlreadyRunning(raw_endpoint)
                except ScopeBrokerAlreadyRunning:
                    raise
                except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
                    pass
            # A dead/malformed endpoint is safe to remove only after acquiring
            # the broker lifetime lock above.
            _remove_endpoint_pair(self.endpoint_path, self.secret_path)

            self._secret = secrets.token_bytes(32)
            self._instance_id = "sbi-" + secrets.token_hex(16)
            _atomic_bytes(self.secret_path, self._secret)
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
            try:
                sock.bind(("127.0.0.1", 0))
                sock.listen(16)
                sock.settimeout(0.25)
            except Exception:
                sock.close()
                raise
            self._socket = sock
            endpoint = {
                "schema": ENDPOINT_SCHEMA,
                "host": "127.0.0.1",
                "port": int(sock.getsockname()[1]),
                "pid": os.getpid(),
                "startedAt": time.time(),
                "instanceId": self._instance_id,
                "secretSha256": hashlib.sha256(self._secret).hexdigest(),
            }
            _atomic_json(self.endpoint_path, endpoint)
            self._last_activity = time.monotonic()
            self._thread = threading.Thread(target=self._serve, name="super-memory-scope-broker", daemon=True)
            self._thread.start()
            return endpoint
        except ScopeBrokerAlreadyRunning:
            # Preserve the live owner's endpoint/secret.  The generic failure
            # path below removes files only after a bind/publish failure.
            lock, self._broker_lock = self._broker_lock, None
            if lock is not None:
                lock.release()
            raise
        except Exception:
            sock, self._socket = self._socket, None
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
            _remove_endpoint_pair(self.endpoint_path, self.secret_path)
            lock, self._broker_lock = self._broker_lock, None
            if lock is not None:
                lock.release()
            raise

    def endpoint(self) -> dict[str, Any]:
        if self._socket is None:
            raise RuntimeError("broker is not running")
        return {
            "schema": ENDPOINT_SCHEMA,
            "host": "127.0.0.1",
            "port": int(self._socket.getsockname()[1]),
            "pid": os.getpid(),
            "instanceId": self._instance_id,
            "secretSha256": hashlib.sha256(self._secret).hexdigest() if self._secret else "",
        }

    def _load_project_roots(self) -> None:
        """Load only validated broker-private project-root bindings.

        The durable scope registry intentionally contains no machine path.
        This sidecar is private transport state: each entry is tied to the
        exact durable workline revision/hash and to the canonical workspace
        key.  A missing sidecar is normal on first boot; malformed or stale
        data is withheld and can be repaired by an explicit register call.
        """

        value, invalid = _read_private_json(self.project_roots_path, max_bytes=_PROJECT_ROOTS_MAX_BYTES)
        loaded: dict[str, dict[str, Any]] = {}
        registry_invalid = invalid
        if not invalid and value is not None:
            if set(value) != _PROJECT_ROOTS_FIELDS:
                registry_invalid = True
            elif value.get("schema") != PROJECT_ROOTS_SCHEMA:
                registry_invalid = True
            else:
                entries = value.get("roots")
                payload = {key: item for key, item in value.items() if key != "payloadHash"}
                if not isinstance(entries, dict) or len(entries) > _PROJECT_ROOTS_MAX_ENTRIES:
                    registry_invalid = True
                elif (
                    not isinstance(value.get("registryRevision"), int)
                    or isinstance(value.get("registryRevision"), bool)
                    or int(value.get("registryRevision", -1)) != len(entries)
                ):
                    registry_invalid = True
                elif value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
                    registry_invalid = True
                elif not isinstance(value.get("payloadHash"), str) or not hmac.compare_digest(
                    str(value.get("payloadHash")), _canonical_hash(payload)
                ):
                    registry_invalid = True
                else:
                    for workline_id, entry in entries.items():
                        if not isinstance(workline_id, str) or not isinstance(entry, dict):
                            registry_invalid = True
                            continue
                        workline = self.broker.get_workline(workline_id)
                        context = workline.context if workline.ok else None
                        if context is None or not self._project_root_entry_matches(context, entry):
                            # Stale entries are not authority.  Drop them from
                            # the live projection, but retain the invalid flag
                            # so pairing cannot silently proceed from a
                            # partially trusted file.
                            registry_invalid = True
                            continue
                        loaded[workline_id] = dict(entry)
        with self._project_root_lock:
            self._project_roots = loaded
            self._project_root_registry_invalid = registry_invalid

    def _project_root_entry_matches(self, context: Any, entry: Mapping[str, Any]) -> bool:
        if not isinstance(entry, Mapping) or set(entry) != _PROJECT_ROOT_RECORD_FIELDS:
            return False
        if entry.get("rawPromptStored") is not False or entry.get("rawTranscriptStored") is not False:
            return False
        if not all(
            isinstance(entry.get(field), str)
            for field in ("worklineId", "workspaceKey", "contractHash", "projectRoot", "updatedAt")
        ):
            return False
        updated_at = str(entry.get("updatedAt", ""))
        try:
            parsed_updated_at = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
        except (TypeError, ValueError):
            return False
        if parsed_updated_at.tzinfo is None:
            return False
        root_raw = str(entry.get("projectRoot", "")).strip()
        if not root_raw or len(root_raw) > 32768:
            return False
        try:
            root = Path(root_raw).expanduser().resolve()
        except OSError:
            return False
        if not root.is_dir() or _workspace_key_for_root(root) != str(context.workspace_key).lower():
            return False
        try:
            revision = entry.get("contractRevision", -1)
            if isinstance(revision, bool):
                return False
            revision = int(revision)
        except (TypeError, ValueError, OverflowError):
            return False
        return bool(
            str(entry.get("worklineId", "")) == str(context.workline_id)
            and str(entry.get("workspaceKey", "")).lower() == str(context.workspace_key).lower()
            and revision == int(context.contract_revision)
            and hmac.compare_digest(str(entry.get("contractHash", "")), str(context.contract_hash))
        )

    @staticmethod
    def _project_root_record(context: Any, root: Path) -> dict[str, Any]:
        return {
            "worklineId": str(context.workline_id),
            "workspaceKey": str(context.workspace_key),
            "contractRevision": int(context.contract_revision),
            "contractHash": str(context.contract_hash),
            "projectRoot": str(root.resolve()),
            "updatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def _persist_project_roots(self) -> bool:
        """Persist the root map while ``_project_root_lock`` is held."""

        entries: dict[str, Any] = {}
        for workline_id, entry in self._project_roots.items():
            workline = self.broker.get_workline(workline_id)
            context = workline.context if workline.ok else None
            if context is None:
                continue
            if not self._project_root_entry_matches(context, entry):
                # A later explicit register is allowed to repair a stale
                # private map.  Do not let an obsolete entry permanently
                # block unrelated current worklines from publishing theirs.
                continue
            entries[workline_id] = dict(entry)
        body: dict[str, Any] = {
            "schema": PROJECT_ROOTS_SCHEMA,
            "registryRevision": len(entries),
            "roots": entries,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        body["payloadHash"] = _canonical_hash(body)
        try:
            _atomic_json(self.project_roots_path, body)
            try:
                os.chmod(self.project_roots_path, 0o600)
            except OSError:
                pass
            self._project_roots = {str(key): dict(item) for key, item in entries.items()}
            self._project_root_registry_invalid = False
            return True
        except (OSError, TypeError, ValueError):
            return False

    def _project_root_for_context(self, context: Any) -> str:
        if context is None:
            return ""
        with self._project_root_lock:
            entry = self._project_roots.get(str(context.workline_id))
            entry = dict(entry) if isinstance(entry, Mapping) else None
        if not isinstance(entry, Mapping) or not self._project_root_entry_matches(context, entry):
            return ""
        try:
            root = Path(str(entry.get("projectRoot", ""))).expanduser().resolve()
        except OSError:
            return ""
        # Revalidate on every authorization boundary.  A deleted, replaced,
        # or retargeted directory must never become a proof root by cache.
        if not root.is_dir() or _workspace_key_for_root(root) != str(context.workspace_key).lower():
            return ""
        return str(root)

    def _project_root_failure_code(self, context: Any) -> str:
        with self._project_root_lock:
            if self._project_root_registry_invalid:
                return "H7_SCOPE_PROJECT_ROOT_REGISTRY_INVALID"
            if context is None or str(getattr(context, "workline_id", "")) not in self._project_roots:
                return "H7_SCOPE_PROJECT_ROOT_REBIND_REQUIRED"
        return "H7_SCOPE_PROJECT_ROOT_INVALID"

    def _endpoint_owned_by(self, instance_id: str, secret: bytes) -> bool:
        """Check that the published endpoint still belongs to this instance."""

        if not instance_id or not secret:
            return False
        bundle = _read_endpoint_bundle(self.endpoint_path, self.secret_path)
        if bundle is None:
            return False
        endpoint, published_secret = bundle
        return bool(
            endpoint.get("pid") == os.getpid()
            and hmac.compare_digest(str(endpoint.get("instanceId", "")), instance_id)
            and hmac.compare_digest(published_secret, secret)
        )

    def stop(self, *, expected_instance_id: str = "") -> None:
        # Detach all owned resources under one lifecycle lock.  A repeated or
        # delayed call then becomes a no-op and cannot clean up a replacement
        # broker that may have published the same state-root endpoint later.
        with self._lifecycle_lock:
            if expected_instance_id and expected_instance_id != self._instance_id:
                return
            if self._stop_finalized:
                return
            self._stop_finalized = True
            self._shutdown_requested = True
            self._stop.set()
            sock, self._socket = self._socket, None
            thread, self._thread = self._thread, None
            lock, self._broker_lock = self._broker_lock, None
            instance_id = self._instance_id
            secret = self._secret
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=1.0)
        # Keep the broker lifetime file lock until this ownership check and
        # cleanup finish so a new broker cannot publish between validation and
        # removal.
        if self._endpoint_owned_by(instance_id, secret):
            _remove_endpoint_pair(self.endpoint_path, self.secret_path)
        if lock is not None:
            lock.release()
        # Do not leave a Windows handle open on a broker.lock file after the
        # server has stopped.  The file itself is harmless and is deliberately
        # retained as the stable lock name; only the owning descriptor must be
        # released before temporary state cleanup.

    @property
    def is_running(self) -> bool:
        return self._socket is not None and not self._stop.is_set()

    def _touch(self, channel_id: str = "") -> None:
        now = time.monotonic()
        if not channel_id:
            self._last_activity = now
            return
        # Only retain activity for channels that the Broker actually owns.
        # An authenticated caller can still submit a syntactically valid but
        # unknown channel ID; indexing those arbitrary values would create an
        # unbounded memory-growth path before the request is rejected.
        with self.broker._memory_lock:
            if channel_id not in self.broker._channels:
                return
            self._channel_last_seen[channel_id] = now
        self._last_activity = now

    def _maybe_idle_shutdown(self) -> bool:
        if self.idle_seconds is None:
            return False
        now = time.monotonic()
        # Never stop while a channel is bound; its lease is the client-visible
        # liveness contract.  Unbound channels are transport remnants and can
        # be reaped after one idle interval.
        # Take one lock-protected snapshot.  Handler threads can pair, open,
        # or close channels concurrently; iterating the live dict/set without
        # the broker lock can otherwise race and kill the accept loop.
        try:
            with self._binding_guard:
                with self.broker._memory_lock:
                    expired = self.broker._expire_bindings(datetime.now(timezone.utc))
                    for channel_id in expired:
                        # Lease expiry transitions a channel back to unbound.
                        # It receives a fresh pairing grace period rather than
                        # being reaped immediately based on its old timestamp.
                        self._channel_last_seen[channel_id] = now
                    channels = tuple(getattr(self.broker, "_channels", set()))
                    bindings = set(getattr(self.broker, "_bindings", {}))
                    last_seen = {
                        channel_id: self._channel_last_seen.get(channel_id, self._last_activity)
                        for channel_id in channels
                    }
        except Exception:
            return False
        for channel_id in channels:
            if channel_id not in bindings and now - last_seen.get(channel_id, now) >= self.unbound_channel_grace_seconds:
                try:
                    with self._binding_guard:
                        with self.broker._memory_lock:
                            # Recheck both binding and activity under the same
                            # lock.  A request arriving at the grace boundary
                            # may have refreshed ``_channel_last_seen`` after
                            # the first snapshot; it must not be reclaimed on
                            # stale timing data.
                            current_last_seen = self._channel_last_seen.get(channel_id, now)
                            if (
                                channel_id in self.broker._channels
                                and channel_id not in self.broker._bindings
                                and now - current_last_seen >= self.unbound_channel_grace_seconds
                            ):
                                self.broker.close_channel(channel_id)
                                self._channel_last_seen.pop(channel_id, None)
                except Exception:
                    pass
        # Close the last race with a concurrent open_channel: reserve the
        # shutdown state while holding the lifecycle lock, so a client cannot
        # receive a fresh channel ID in the tiny interval before stop().
        with self._lifecycle_lock:
            if self._shutdown_requested:
                return True
            with self.broker._memory_lock:
                if self.broker._bindings or self.broker._channels:
                    return False
            if now - self._last_activity < self.idle_seconds:
                return False
            self._shutdown_requested = True
            return True

    def _serve(self) -> None:
        while not self._stop.is_set():
            sock = self._socket
            if sock is None:
                return
            try:
                connection, _ = sock.accept()
            except socket.timeout:
                if self._maybe_idle_shutdown():
                    # ``stop`` is safe from the accept thread; it skips joining
                    # itself and releases the lifetime lock before returning.
                    self.stop()
                    return
                continue
            except OSError:
                return
            thread = threading.Thread(target=self._handle, args=(connection,), daemon=True)
            thread.start()

    def _handle(self, connection: socket.socket) -> None:
        with connection:
            connection.settimeout(_READ_TIMEOUT)
            try:
                raw = b""
                while b"\n" not in raw and len(raw) <= _MAX_LINE:
                    chunk = connection.recv(8192)
                    if not chunk:
                        break
                    raw += chunk
                line = raw.split(b"\n", 1)[0]
                if not line or len(line) > _MAX_LINE:
                    return
                request = json.loads(line.decode("utf-8"))
                response = self._dispatch(request)
            except Exception:
                response = {"ok": False, "code": "H7_SCOPE_BROKER_PROTOCOL_INVALID"}
            try:
                connection.sendall(_canonical(response) + b"\n")
            except OSError:
                pass

    def _dispatch(self, request: Any) -> dict[str, Any]:
        if not isinstance(request, dict):
            return {"ok": False, "code": "H7_SCOPE_BROKER_PROTOCOL_INVALID"}
        method = request.get("method")
        params = request.get("params", {})
        nonce = request.get("nonce")
        mac = request.get("mac")
        if not isinstance(method, str) or not method or len(method) > 128 or not isinstance(params, dict):
            return {"ok": False, "code": "H7_SCOPE_BROKER_PROTOCOL_INVALID"}
        try:
            if len(_canonical(params)) > _MAX_PARAMS:
                return {"ok": False, "code": "H7_SCOPE_BROKER_PROTOCOL_INVALID"}
        except (TypeError, ValueError, OverflowError):
            return {"ok": False, "code": "H7_SCOPE_BROKER_PROTOCOL_INVALID"}
        if not isinstance(nonce, str) or not isinstance(mac, str):
            return {"ok": False, "code": "H7_SCOPE_BROKER_AUTH_REQUIRED"}
        if not (_MIN_NONCE_LENGTH <= len(nonce) <= _MAX_NONCE_LENGTH) or any(ord(char) < 0x21 or ord(char) > 0x7E for char in nonce):
            return {"ok": False, "code": "H7_SCOPE_BROKER_NONCE_INVALID"}
        if len(mac) != 64 or any(char not in "0123456789abcdefABCDEF" for char in mac):
            return {"ok": False, "code": "H7_SCOPE_BROKER_AUTH_INVALID"}
        expected = hmac.new(self._secret, _canonical({"method": method, "params": params, "nonce": nonce}), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, mac):
            return {"ok": False, "code": "H7_SCOPE_BROKER_AUTH_INVALID"}
        now = time.monotonic()
        with self._memory_nonce_lock:
            # Drop old request nonces before checking replay.  A nonce is
            # consumed only after HMAC authentication succeeds, so malformed
            # traffic cannot exhaust the replay cache.
            cutoff = now - _NONCE_TTL_SECONDS
            for seen, timestamp in tuple(self._seen_nonces.items()):
                if timestamp < cutoff:
                    self._seen_nonces.pop(seen, None)
            if nonce in self._seen_nonces:
                return {"ok": False, "code": "H7_SCOPE_BROKER_NONCE_REPLAYED"}
            if len(self._seen_nonces) >= _MAX_SEEN_NONCES:
                oldest = min(self._seen_nonces, key=self._seen_nonces.get)
                self._seen_nonces.pop(oldest, None)
            self._seen_nonces[nonce] = now
        self._touch(str(params.get("channelId", "")) if isinstance(params.get("channelId", ""), str) else "")
        return self._method(method, params)

    @staticmethod
    def _result(result: Any, *, private: bool = False) -> dict[str, Any]:
        if isinstance(result, ScopeBrokerResult):
            body = result.public_projection()
            if private:
                if result.lease_id:
                    body["leaseId"] = result.lease_id
                if result.context is not None:
                    body["h7Scope"] = result.context.h7_scope_projection()
            return body
        return {"ok": False, "code": "H7_SCOPE_BROKER_RESULT_INVALID", "state": "withheld"}

    def _method(self, method: str, p: dict[str, Any]) -> dict[str, Any]:
        b = self.broker
        if method == "ping":
            return {"ok": True, "code": "H7_SCOPE_BROKER_PONG", "instanceId": self._instance_id}
        if method == "open_channel":
            with self._lifecycle_lock:
                if self._shutdown_requested:
                    return {"ok": False, "code": "H7_SCOPE_BROKER_STOPPING", "state": "stopping"}
                channel_id = b.open_channel()
                self._touch(channel_id)
                return {"ok": True, "channelId": channel_id}
        if method == "list_channels":
            channels = []
            with self._binding_guard:
                with b._memory_lock:
                    channel_ids = tuple(sorted(getattr(b, "_channels", set())))
                for channel_id in channel_ids:
                    status = b.status(channel_id)
                    item = status.public_projection()
                    item["channelId"] = channel_id
                    # Listing is only a control-plane discovery operation.  Do
                    # not project another connection's task/workspace context;
                    # the caller must target one channel and then authorize it.
                    item.pop("scope", None)
                    channels.append(item)
            return {"ok": True, "channels": channels}
        if method == "status":
            with self._binding_guard:
                result = b.status(str(p.get("channelId", "")))
                # A bound channel is not meaningfully healthy when its private
                # proof root has been deleted, retargeted, or become stale.
                # The binding guard keeps this proof check atomic with a
                # concurrent detach/re-pair on the same channel.
                if result.context is not None and not self._project_root_for_context(result.context):
                    return {
                        "ok": False,
                        "code": self._project_root_failure_code(result.context),
                        "state": "withheld",
                        "rawPromptStored": False,
                        "rawTranscriptStored": False,
                    }
                return self._result(result)
        if method == "authorize":
            with self._binding_guard:
                result = b.authorize(str(p.get("channelId", "")), write=p.get("write", False))
                body = self._result(result, private=True)
                if result.context is not None:
                    root = self._project_root_for_context(result.context)
                    if not root:
                        return {
                            "ok": False,
                            "code": self._project_root_failure_code(result.context),
                            "state": "withheld",
                            "rawPromptStored": False,
                            "rawTranscriptStored": False,
                        }
                    body.setdefault("h7Scope", {})["projectRoot"] = root
                    body.setdefault("scope", {})["projectRoot"] = root
                return body
        if method == "renew_lease":
            # Renewal is invoked only by the MCP provider's in-process lease
            # cache.  It needs the refreshed expiry, never another bearer
            # capability or a full scope projection.
            return self._result(
                b.renew_lease(
                    str(p.get("channelId", "")),
                    str(p.get("leaseId", "")),
                    lease_seconds=p.get("leaseSeconds", 300),
                )
            )
        if method == "detach_channel":
            with self._binding_guard:
                return self._result(b.detach_channel(str(p.get("channelId", ""))))
        if method == "close_channel":
            channel_id = str(p.get("channelId", ""))
            with self._binding_guard:
                result = b.close_channel(channel_id)
                with b._memory_lock:
                    self._channel_last_seen.pop(channel_id, None)
            return self._result(result)
        if method == "shutdown_if_idle":
            # This control method is intentionally idempotent.  A client may
            # request cleanup after closing its channel while another adapter
            # is still active; in that case the broker remains resident.
            with self._lifecycle_lock:
                with b._memory_lock:
                    if b._bindings or b._channels:
                        return {"ok": False, "code": "H7_SCOPE_BROKER_NOT_IDLE", "state": "active"}
                if self._shutdown_requested:
                    return {"ok": True, "code": "H7_SCOPE_BROKER_SHUTDOWN_ACCEPTED", "state": "stopping"}
                self._shutdown_requested = True
                self._stop.set()
                # Let the current handler flush its response, then perform the
                # same endpoint/lock cleanup as an ordinary ``stop`` call.
                # This also works for an embedded server object, not only the
                # standalone ``serve`` process.
                threading.Thread(
                    target=self._deferred_stop,
                    args=(self._instance_id,),
                    name="super-memory-scope-broker-stop",
                    daemon=True,
                ).start()
                return {"ok": True, "code": "H7_SCOPE_BROKER_SHUTDOWN_ACCEPTED", "state": "stopping"}
        # These are local control-surface operations.  They share the same
        # authenticated socket but are never exposed by the MCP adapter.
        if method == "register_workline":
            with self._lifecycle_lock:
                if self._shutdown_requested:
                    return {"ok": False, "code": "H7_SCOPE_BROKER_STOPPING", "state": "stopping"}
                contract = p.get("contract")
                raw_root = str(p.get("projectRoot", "")).strip()
                if not raw_root:
                    return {"ok": False, "code": "H7_SCOPE_PROJECT_ROOT_REQUIRED", "state": "withheld"}
                try:
                    root = Path(raw_root).expanduser().resolve()
                    if not root.is_dir() or not isinstance(contract, Mapping):
                        return {"ok": False, "code": "H7_SCOPE_PROJECT_ROOT_INVALID", "state": "withheld"}
                    normalized = str(root).rstrip("/\\").lower()
                    expected = "ws-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24]
                    if str(contract.get("workspaceKey", "")).strip().lower() != expected:
                        return {"ok": False, "code": "H7_SCOPE_PROJECT_ROOT_MISMATCH", "state": "withheld"}
                except OSError:
                    return {"ok": False, "code": "H7_SCOPE_PROJECT_ROOT_INVALID", "state": "withheld"}
                with self._binding_guard:
                    result = b.register_workline(contract, expected_contract_hash=p.get("expectedContractHash"))
                    if result.ok and result.context is not None:
                        with self._project_root_lock:
                            prior_roots = {key: dict(value) for key, value in self._project_roots.items()}
                            prior_invalid = self._project_root_registry_invalid
                            self._project_roots[result.context.workline_id] = self._project_root_record(result.context, root)
                            if not self._persist_project_roots():
                                self._project_roots = prior_roots
                                self._project_root_registry_invalid = prior_invalid
                                return {
                                    "ok": False,
                                    "code": "H7_SCOPE_PROJECT_ROOT_WRITE_FAILED",
                                    "state": "withheld",
                                    "rawPromptStored": False,
                                    "rawTranscriptStored": False,
                                }
                    return self._result(result)
        if method == "get_workline":
            return self._result(b.get_workline(str(p.get("worklineId", ""))))
        if method == "pair_channel":
            # Pairing is deliberately performed inside the broker.  The
            # one-shot grant never crosses IPC and therefore cannot appear in
            # a CLI argument, MCP response, or log line.
            with self._lifecycle_lock:
                if self._shutdown_requested:
                    return {"ok": False, "code": "H7_SCOPE_BROKER_STOPPING", "state": "stopping"}
                with self._binding_guard:
                    workline = b.get_workline(str(p.get("worklineId", "")))
                    if workline.ok and workline.context is not None:
                        root = self._project_root_for_context(workline.context)
                        if not root:
                            return {
                                "ok": False,
                                "code": self._project_root_failure_code(workline.context),
                                "state": "withheld",
                                "rawPromptStored": False,
                                "rawTranscriptStored": False,
                            }
                    result = b.pair_channel(
                        str(p.get("channelId", "")),
                        str(p.get("worklineId", "")),
                        access_mode=p.get("accessMode", "write"),
                        ttl_seconds=p.get("ttlSeconds", 60),
                        lease_seconds=p.get("leaseSeconds", 300),
                    )
                    # The control surface receives only a public success projection.
                    # Lease renewal capability is minted internally and first carried
                    # only by the private authorize response consumed by the provider.
                    return self._result(result)
        if method == "issue_pairing_grant":
            # Bearer pairing tokens never cross the IPC boundary.  The
            # historical two-step methods remain available only on the
            # in-process broker compatibility seam.
            return {"ok": False, "code": "H7_SCOPE_PAIRING_TOKEN_TRANSPORT_RETIRED", "state": "withheld"}
        if method == "attach_channel":
            return {"ok": False, "code": "H7_SCOPE_PAIRING_TOKEN_TRANSPORT_RETIRED", "state": "withheld"}
        return {"ok": False, "code": "H7_SCOPE_BROKER_METHOD_UNKNOWN", "state": "withheld"}

    def _deferred_stop(self, expected_instance_id: str = "") -> None:
        time.sleep(0.05)
        self.stop(expected_instance_id=expected_instance_id)


class ScopeBrokerClient:
    """Adapter-side client; it never accepts a scope selector."""

    def __init__(self, state_root: str | Path, *, auto_start: bool = True, runtime_path: str | Path | None = None) -> None:
        self.state_root = _safe_path(state_root)
        self.runtime_root = self.state_root / "workspace" / "runtime-state" / "scope-broker"
        self.endpoint_path = self.runtime_root / "endpoint.json"
        self.secret_path = self.runtime_root / "secret.bin"
        self._startup_lock_path = self.runtime_root / "startup.lock"
        self.auto_start = auto_start
        self.runtime_path = Path(runtime_path).resolve() if runtime_path else Path(__file__).resolve()
        self._start_lock = threading.Lock()
        self._process: subprocess.Popen[Any] | None = None
        self.last_context: Any = None
        self._endpoint_checked_at = 0.0
        self._endpoint_fingerprint = ""
        self._endpoint_probe_interval = 1.0

    def _ensure_endpoint(self) -> bool:
        if self._endpoint_active():
            return True
        if not self.auto_start:
            return False
        with self._start_lock:
            # Serialize startup across all adapter processes sharing a state
            # root.  Each process rechecks the endpoint after acquiring the
            # lock, so only one child can be spawned.
            startup_lock = _FileLease(self._startup_lock_path)
            if not startup_lock.acquire():
                return self._endpoint_active()
            try:
                if self._endpoint_active():
                    return True
                # During a server's two-file publication window the endpoint
                # may be temporarily unreadable while its PID is already
                # alive.  Do not delete that live owner's files or launch a
                # competing broker; simply wait for the pair to settle.
                owner_alive = False
                try:
                    raw_endpoint = json.loads(self.endpoint_path.read_text(encoding="utf-8"))
                    owner_alive = _pid_alive(raw_endpoint.get("pid")) if isinstance(raw_endpoint, dict) else False
                except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
                    owner_alive = False
                if owner_alive:
                    deadline = time.monotonic() + _CONNECT_TIMEOUT
                    while time.monotonic() < deadline:
                        if self._endpoint_active():
                            return True
                        time.sleep(0.03)
                    return False
                # No live owner remains while the startup lock is held.  This
                # is the only point where stale endpoint files are removed.
                _remove_endpoint_pair(self.endpoint_path, self.secret_path)
                command = [
                    sys.executable,
                    "-X",
                    "utf8",
                    str(self.runtime_path),
                    "serve",
                    "--state-root",
                    str(self.state_root),
                    "--idle-seconds",
                    str(_BROKER_IDLE_SECONDS),
                    "--unbound-channel-grace-seconds",
                    str(_UNBOUND_CHANNEL_GRACE_SECONDS),
                ]
                try:
                    # Keep the resident broker's working directory outside the
                    # package checkout.  On Windows a child whose cwd is the
                    # copied ``runtime`` directory prevents test/install
                    # cleanup and needlessly pins an old package tree.
                    self._process = subprocess.Popen(
                        command,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        # Never pin either the package checkout or the private
                        # state directory as the child cwd; Windows cleanup of
                        # a temporary install must remain possible.
                        cwd=tempfile.gettempdir(),
                    )
                except OSError:
                    return False
                deadline = time.monotonic() + _CONNECT_TIMEOUT
                while time.monotonic() < deadline:
                    if self._endpoint_active():
                        return True
                    if self._process.poll() is not None:
                        break
                    time.sleep(0.03)
            finally:
                startup_lock.release()
        return False

    def _endpoint_readable(self) -> tuple[str, int] | None:
        bundle = _read_endpoint_bundle(self.endpoint_path, self.secret_path)
        if bundle is None:
            return None
        endpoint, _ = bundle
        return str(endpoint["host"]), int(endpoint["port"])

    def _endpoint_active(self, *, force_probe: bool = False) -> bool:
        bundle = _read_endpoint_bundle(self.endpoint_path, self.secret_path)
        if bundle is None:
            self._endpoint_fingerprint = ""
            return False
        endpoint, secret = bundle
        if not _pid_alive(endpoint.get("pid")):
            return False
        fingerprint = f"{endpoint.get('pid')}:{endpoint.get('port')}:{endpoint.get('instanceId')}:{endpoint.get('secretSha256')}"
        now = time.monotonic()
        if not force_probe and fingerprint == self._endpoint_fingerprint and now - self._endpoint_checked_at <= self._endpoint_probe_interval:
            return True
        if not self._probe(endpoint, secret):
            self._endpoint_fingerprint = ""
            return False
        self._endpoint_fingerprint = fingerprint
        self._endpoint_checked_at = now
        return True

    def _probe(self, endpoint: Mapping[str, Any], secret: bytes) -> bool:
        return _probe_endpoint(endpoint, secret)

    def _call(
        self,
        method: str,
        params: Mapping[str, Any] | None = None,
        *,
        allow_auto_start: bool = True,
    ) -> dict[str, Any]:
        if allow_auto_start:
            endpoint_ready = self._ensure_endpoint()
        else:
            # Teardown/control calls must never auto-start a replacement child
            # merely because the endpoint vanished during shutdown.
            endpoint_ready = self._endpoint_active(force_probe=True)
        if not endpoint_ready:
            return {"ok": False, "code": "H7_SCOPE_BROKER_UNAVAILABLE", "state": "withheld"}
        endpoint = self._endpoint_readable()
        if endpoint is None:
            return {"ok": False, "code": "H7_SCOPE_BROKER_ENDPOINT_INVALID", "state": "withheld"}
        host, port = endpoint
        values = dict(params or {})
        nonce = secrets.token_urlsafe(18)
        bundle = _read_endpoint_bundle(self.endpoint_path, self.secret_path)
        if bundle is None:
            return {"ok": False, "code": "H7_SCOPE_BROKER_ENDPOINT_INVALID", "state": "withheld"}
        _, secret = bundle
        mac = hmac.new(secret, _canonical({"method": method, "params": values, "nonce": nonce}), hashlib.sha256).hexdigest()
        request = {"method": method, "params": values, "nonce": nonce, "mac": mac}
        try:
            with socket.create_connection((host, port), timeout=_CONNECT_TIMEOUT) as connection:
                connection.settimeout(_READ_TIMEOUT)
                connection.sendall(_canonical(request) + b"\n")
                raw = b""
                while b"\n" not in raw and len(raw) <= _MAX_LINE:
                    chunk = connection.recv(8192)
                    if not chunk:
                        break
                    raw += chunk
            value = json.loads(raw.split(b"\n", 1)[0].decode("utf-8"))
            return dict(value) if isinstance(value, dict) else {"ok": False, "code": "H7_SCOPE_BROKER_RESPONSE_INVALID", "state": "withheld"}
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            return {"ok": False, "code": "H7_SCOPE_BROKER_UNAVAILABLE", "state": "withheld"}

    def current_instance_id(self, *, force_probe: bool = False) -> str:
        """Return the authenticated Broker instance currently reachable."""

        if not self._endpoint_active(force_probe=force_probe):
            return ""
        bundle = _read_endpoint_bundle(self.endpoint_path, self.secret_path)
        if bundle is None:
            return ""
        endpoint, _ = bundle
        return str(endpoint.get("instanceId", ""))

    def open_channel(self, *, allow_auto_start: bool = True) -> str:
        # Only the initial adapter construction may auto-start the resident
        # broker.  Recovery opens are explicitly no-auto-start and remain
        # unbound until the trusted control surface pairs them.
        value = self._call("open_channel", allow_auto_start=allow_auto_start)
        return str(value.get("channelId", "")) if value.get("ok") is True else ""

    def status(self, channel_id: str, *, allow_auto_start: bool = False) -> dict[str, Any]:
        return self._call("status", {"channelId": channel_id}, allow_auto_start=allow_auto_start)

    def authorize(self, channel_id: str, *, write: bool = False, allow_auto_start: bool = False) -> dict[str, Any]:
        value = self._call(
            "authorize",
            {"channelId": channel_id, "write": bool(write)},
            allow_auto_start=allow_auto_start,
        )
        self.last_context = value.get("scope") if isinstance(value.get("scope"), dict) else None
        return value

    def renew_lease(
        self,
        channel_id: str,
        lease_id: str,
        *,
        lease_seconds: int = 300,
        allow_auto_start: bool = False,
    ) -> dict[str, Any]:
        return self._call(
            "renew_lease",
            {"channelId": channel_id, "leaseId": lease_id, "leaseSeconds": lease_seconds},
            allow_auto_start=allow_auto_start,
        )

    def detach_channel(self, channel_id: str, *, allow_auto_start: bool = False) -> dict[str, Any]:
        return self._call("detach_channel", {"channelId": channel_id}, allow_auto_start=allow_auto_start)

    def close_channel(self, channel_id: str, *, allow_auto_start: bool = False) -> dict[str, Any]:
        return self._call("close_channel", {"channelId": channel_id}, allow_auto_start=allow_auto_start)

    def shutdown_if_idle(self) -> dict[str, Any]:
        """Ask a broker child to exit when no channels remain."""

        return self._call("shutdown_if_idle", allow_auto_start=False)

    def close(self) -> None:
        """Release a client-owned child without killing a shared broker.

        The authenticated shutdown request is safe when another adapter is
        active (the server returns ``H7_SCOPE_BROKER_NOT_IDLE``).  A bounded
        process wait then handles a child that accepted shutdown but has not
        yet reached its event loop; only the process this client started is
        ever terminated directly.
        """

        process = self._process
        shutdown_accepted = False
        try:
            # Only a client that actually spawned this child may request its
            # shutdown.  The no-auto-start control call prevents teardown from
            # creating a replacement broker when its endpoint is already gone.
            if process is not None and process.poll() is None:
                shutdown = self.shutdown_if_idle()
                shutdown_accepted = shutdown.get("code") == "H7_SCOPE_BROKER_SHUTDOWN_ACCEPTED"
        except Exception:
            pass
        if process is not None:
            # A client that launched the broker may still share it with other
            # adapters.  ``NOT_IDLE`` and transport uncertainty are not proof
            # that this client is the last user, so release only our local
            # handle.  The broker's own idle reaper will clean up later.
            # Direct termination is permitted only after the authenticated
            # server has accepted an idle shutdown request.
            if not shutdown_accepted:
                self._process = None
                return
            try:
                process.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                try:
                    process.terminate()
                    process.wait(timeout=1.0)
                except (OSError, subprocess.TimeoutExpired):
                    try:
                        process.kill()
                    except OSError:
                        pass
            self._process = None


class ScopeBrokerControlClient(ScopeBrokerClient):
    def list_channels(self) -> dict[str, Any]:
        return self._call("list_channels")

    def register_workline(self, contract: Mapping[str, Any], *, expected_contract_hash: str, project_root: str | Path | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {"contract": dict(contract), "expectedContractHash": expected_contract_hash}
        if project_root is not None:
            params["projectRoot"] = str(project_root)
        return self._call("register_workline", params)

    def get_workline(self, workline_id: str) -> dict[str, Any]:
        return self._call("get_workline", {"worklineId": workline_id})

    def pair_channel(
        self,
        channel_id: str,
        workline_id: str,
        *,
        access_mode: str = "write",
        ttl_seconds: int = 60,
        lease_seconds: int = 300,
    ) -> dict[str, Any]:
        """Pair a channel through the broker without transporting a token."""

        return self._call(
            "pair_channel",
            {
                "channelId": channel_id,
                "worklineId": workline_id,
                "accessMode": access_mode,
                "ttlSeconds": ttl_seconds,
                "leaseSeconds": lease_seconds,
            },
        )


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--state-root", required=True)
    serve.add_argument("--idle-seconds", type=float, default=_BROKER_IDLE_SECONDS)
    serve.add_argument(
        "--unbound-channel-grace-seconds",
        type=float,
        default=_UNBOUND_CHANNEL_GRACE_SECONDS,
    )
    args = parser.parse_args()
    if args.command != "serve":
        return 2
    server = ScopeBrokerServer(
        args.state_root,
        idle_seconds=args.idle_seconds,
        unbound_channel_grace_seconds=args.unbound_channel_grace_seconds,
    )
    try:
        server.start()
    except ScopeBrokerAlreadyRunning:
        # Another adapter owns this state root.  Exiting is important: a
        # second resident process must never spin while holding no endpoint.
        return 0
    try:
        while server.is_running:
            time.sleep(0.25)
    except KeyboardInterrupt:
        return 0
    finally:
        server.stop()


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "ENDPOINT_SCHEMA",
    "ScopeBrokerAlreadyRunning",
    "ScopeBrokerClient",
    "ScopeBrokerControlClient",
    "ScopeBrokerServer",
]
