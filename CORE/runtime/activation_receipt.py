from __future__ import annotations

"""Small, content-addressed activation gate for Super Brain.

The module deliberately owns only activation identity, readiness, and the
scoped receipt.  It does not own task mutations, memory writes, or Hook
dispatch.  Callers pass already-observed task/memory projections and receive a
bounded receipt that can be validated on the next turn.
"""

import errno
import hashlib
import json
import math
import os
import tempfile
import time
import uuid
from contextlib import contextmanager
from functools import wraps
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from core_rule_registry import REGISTRY_RELATIVE_PATH, load_registry, public_projection as project_core_rules


ACTIVATION_SCHEMA = "super-brain.activation-receipt.v1"
ACTIVATION_STATES = {"full_brain_active", "withheld", "failed"}
CORE_CAPABILITIES = ("runtime", "route", "memory", "task_state", "continuation", "response_policy", "core_rules")
ROUTE_CLASSES = {"direct", "memory", "task", "continuity", "diagnostic"}
ACTIVATION_TIERS = {"none", "memory_only", "task", "continuity_light", "full_diagnostic"}
ROUTE_METADATA_FIELDS = (
    "routeClass",
    "activationTier",
    "requiresTaskPointer",
    "requiresProjectProof",
    "requiresCapabilityRoute",
    "userVisibleState",
)
ACTIVE_RECEIPTS_DIRECTORY = "receipts-current"
ACTIVATION_LOCK_TIMEOUT_SECONDS = 2.0
LEGACY_RECEIPTS_DIRECTORY = "receipts"
_STATIC_IDENTITY_CACHE_MAX = 8
_STATIC_IDENTITY_CACHE: dict[str, tuple[tuple[tuple[int, int], ...], dict[str, Any]]] = {}


def _static_identity_stamps(paths: tuple[Path, ...]) -> tuple[tuple[int, int], ...] | None:
    """Return one bounded filesystem stamp per static identity input."""

    stamps: list[tuple[int, int]] = []
    for path in paths:
        try:
            stat = path.stat()
        except OSError:
            return None
        stamps.append((stat.st_mtime_ns, stat.st_size))
    return tuple(stamps)


def _static_identity_cache_get(
    key: str,
    stamps: tuple[tuple[int, int], ...] | None,
) -> dict[str, Any] | None:
    if stamps is None:
        return None
    cached = _STATIC_IDENTITY_CACHE.get(key)
    if cached is None or cached[0] != stamps:
        return None
    _STATIC_IDENTITY_CACHE.pop(key, None)
    _STATIC_IDENTITY_CACHE[key] = cached
    return cached[1]


def _static_identity_cache_put(
    key: str,
    stamps: tuple[tuple[int, int], ...] | None,
    identity: dict[str, Any],
) -> None:
    # Missing inputs are deliberately not cached: a newly repaired package
    # must be retried immediately instead of inheriting a withheld snapshot.
    if stamps is None:
        return
    _STATIC_IDENTITY_CACHE.pop(key, None)
    _STATIC_IDENTITY_CACHE[key] = (stamps, identity)
    while len(_STATIC_IDENTITY_CACHE) > _STATIC_IDENTITY_CACHE_MAX:
        _STATIC_IDENTITY_CACHE.pop(next(iter(_STATIC_IDENTITY_CACHE)))


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def file_sha256(path: Path) -> str:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return ""


def _read_static_json_with_hash(path: Path) -> tuple[Any, str]:
    """Read one static JSON input once and derive its parsed form and digest.

    Activation identity needs both a byte-exact package hash and a UTF-8-sig
    JSON projection. Reading the file separately for each can observe two
    different versions during a package update as well as adding cold-start
    I/O. Keep both values tied to the same raw bytes; malformed JSON retains
    its byte hash exactly as the former separate JSON and SHA-256 reads did,
    while missing or unreadable input still fails closed.
    """

    try:
        raw = path.read_bytes()
    except OSError:
        return None, ""
    digest = hashlib.sha256(raw).hexdigest()
    try:
        return json.loads(raw.decode("utf-8-sig")), digest
    except (UnicodeError, json.JSONDecodeError):
        return None, digest


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _scope_ref(workspace_key: str, session_key: str, task_id: str = "", task_instance_id: str = "") -> str:
    return canonical_hash(
        {
            "workspaceKey": str(workspace_key or ""),
            "ownerSessionKey": str(session_key or ""),
            "taskId": str(task_id or ""),
            "taskInstanceId": str(task_instance_id or ""),
        }
    )


def receipt_path(memory_base: str | Path, scope_ref: str) -> Path:
    """Return the one writable, package-local H7 activation receipt path.

    ``activation/receipts`` is legacy evidence only.  Some historical package
    installations redirected it through a host-owned junction which may be
    unreadable or deny temporary-file creation.  A governed turn must repair
    that condition rather than hang, fall back to a Hook, or continue without
    an activation receipt.  ``receipts-current`` is therefore the sole active
    receipt root; the legacy target is never used for new reads or writes.
    """

    return (
        Path(memory_base)
        / "workspace"
        / "runtime-state"
        / "activation"
        / ACTIVE_RECEIPTS_DIRECTORY
        / f"{str(scope_ref)[:64]}.json"
    )


@contextmanager
def _activation_lock(memory_base: str | Path, scope_ref: str):
    """Take a handle-owned advisory lock for one activation scope.

    The persistent marker is diagnostic only.  The OS handle owns the lock,
    so process exit releases it automatically and an old owner can never
    unlink a replacement lock during cleanup.
    """

    lock_path = Path(memory_base) / "workspace" / "runtime-state" / "activation" / f"{scope_ref}.lock"
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        yield False
        return
    try:
        handle = lock_path.open("a+b")
    except OSError:
        yield False
        return
    acquired = False

    try:
        handle.seek(0)
        existing_marker = handle.read(513)
        if len(existing_marker) > 512 or existing_marker not in {b"", b"0"}:
            # Preserve the legacy token-lock safety boundary.  An older
            # process may still own a create-only lock that this advisory
            # protocol cannot observe; require explicit repair rather than
            # racing it.
            handle.close()
            yield False
            return
        if existing_marker == b"":
            handle.seek(0, os.SEEK_END)
            handle.write(b"0")
            handle.flush()
            os.fsync(handle.fileno())
    except OSError:
        handle.close()
        yield False
        return

    try:
        if os.name == "nt":
            import msvcrt
        else:
            import fcntl
    except ImportError:
        handle.close()
        yield False
        return

    try:
        timeout = float(ACTIVATION_LOCK_TIMEOUT_SECONDS)
    except (TypeError, ValueError, OverflowError):
        timeout = 2.0
    if not math.isfinite(timeout) or timeout < 0:
        timeout = 0.0
    started = time.monotonic()
    while time.monotonic() - started < timeout:
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
        handle.close()


def _ensure_current_locked(func):
    @wraps(func)
    def wrapped(package_root=None, memory_base=None, *args, **kwargs):
        if package_root is None and "package_root" in kwargs:
            package_root = kwargs.pop("package_root")
        if memory_base is None and "memory_base" in kwargs:
            memory_base = kwargs.pop("memory_base")
        if package_root is None or memory_base is None:
            raise TypeError("ensure_current requires package_root and memory_base")
        scope = _scope_ref(
            str(kwargs.get("workspace_key", "")),
            str(kwargs.get("session_key", "")),
            str(kwargs.get("task_id", "")),
            str(kwargs.get("task_instance_id", "")),
        )
        with _activation_lock(memory_base, scope) as acquired:
            if not acquired:
                return {
                    "schema": ACTIVATION_SCHEMA,
                    "activationState": "withheld",
                    "activationId": "",
                    "activationCode": "ACTIVATION_SCOPE_LOCK_TIMEOUT",
                    "actionAuthorization": "withheld",
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }, "ACTIVATION_SCOPE_LOCK_TIMEOUT"
            return func(package_root, memory_base, *args, **kwargs)
    return wrapped


def _atomic_json(path: Path, value: Any) -> None:
    # Keep the temporary file on the same package-local volume as the active
    # receipt.  Do not resolve or write through the retired host-owned
    # ``activation/receipts`` junction: it can deny file creation and make an
    # otherwise small H7 activation block indefinitely on Windows.
    target_parent = path.parent
    target_path = target_parent / path.name
    target_parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(prefix=".activation-receipt-", suffix=".tmp", dir=str(target_parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(raw_path, target_path)
    finally:
        try:
            os.unlink(raw_path)
        except FileNotFoundError:
            pass


def _hash_list(values: Iterable[Any]) -> str:
    return canonical_hash([str(value) for value in values if str(value)])


def route_metadata(route_map: Any, route: Any) -> dict[str, Any]:
    """Return bounded route metadata without making it an authorization gate.

    Older package maps do not carry the metadata fields yet.  Their safe
    compatibility default is a direct, non-activating route; a malformed
    entry is ignored field-by-field instead of widening activation authority.
    """

    route_name = str(route or "bare_wake")
    result: dict[str, Any] = {
        "routeClass": "direct",
        "activationTier": "none",
        "requiresTaskPointer": False,
        "requiresProjectProof": False,
        "requiresCapabilityRoute": False,
        "userVisibleState": "direct",
    }
    if route_name == "bare_wake":
        result.update({"routeClass": "continuity", "activationTier": "continuity_light", "userVisibleState": "continuity"})
    elif route_name in {"current_session_continue", "historical_recovery"}:
        result.update(
            {
                "routeClass": "continuity",
                "activationTier": "continuity_light",
                "requiresTaskPointer": True,
                "requiresProjectProof": True,
                "userVisibleState": "continuity",
            }
        )
    elif route_name in {"memory_recall", "privacy_memory_gate", "workflow_preference_recall"}:
        result.update({"routeClass": "memory", "activationTier": "memory_only", "userVisibleState": "memory"})
    elif route_name == "memory_write_candidate":
        result.update({"routeClass": "memory", "activationTier": "memory_only", "requiresTaskPointer": True, "userVisibleState": "memory"})
    elif route_name in {"current_task_status", "browser_automation", "agent_bridge_channel"}:
        result.update(
            {
                "routeClass": "task",
                "activationTier": "task",
                "requiresTaskPointer": True,
                "requiresCapabilityRoute": route_name in {"browser_automation", "agent_bridge_channel"},
                "userVisibleState": "task",
            }
        )
    elif route_name in {"orc_complex_routing", "collaborative_intent", "single_agent_subagent_workflow"}:
        result.update(
            {
                "routeClass": "task",
                "activationTier": "task",
                "requiresTaskPointer": True,
                "requiresProjectProof": True,
                "requiresCapabilityRoute": True,
                "userVisibleState": "task",
            }
        )
    elif route_name in {"system_status", "fix_bug", "repository_readiness", "maintenance_hot_refresh"}:
        result.update(
            {
                "routeClass": "diagnostic",
                "activationTier": "full_diagnostic",
                "userVisibleState": "diagnostic",
            }
        )
        if route_name != "system_status":
            result.update({"requiresTaskPointer": True, "requiresProjectProof": True, "requiresCapabilityRoute": True})

    entries = route_map.get("routes") if isinstance(route_map, dict) else None
    if isinstance(entries, list):
        selected = next((entry for entry in entries if isinstance(entry, dict) and str(entry.get("route", "")) == route_name), None)
        if isinstance(selected, dict):
            route_class = str(selected.get("routeClass", ""))
            if route_class in ROUTE_CLASSES:
                result["routeClass"] = route_class
            activation_tier = str(selected.get("activationTier", ""))
            if activation_tier in ACTIVATION_TIERS:
                result["activationTier"] = activation_tier
            for field in ("requiresTaskPointer", "requiresProjectProof", "requiresCapabilityRoute"):
                if isinstance(selected.get(field), bool):
                    result[field] = selected[field]
            user_state = str(selected.get("userVisibleState", ""))
            if user_state in ROUTE_CLASSES:
                result["userVisibleState"] = user_state
    return result


def _static_identity(package_root: Path) -> dict[str, Any]:
    manifest_path = package_root / "manifest.json"
    route_path = package_root / "route-map.json"
    capabilities_path = package_root / "capabilities.json"
    registry_path = package_root / REGISTRY_RELATIVE_PATH
    static_paths = (manifest_path, route_path, capabilities_path, registry_path)
    cache_key = os.path.normcase(str(package_root))
    stamps = _static_identity_stamps(static_paths)
    cached = _static_identity_cache_get(cache_key, stamps)
    if cached is not None:
        return cached
    manifest, manifest_hash = _read_static_json_with_hash(manifest_path)
    route_map, route_map_hash = _read_static_json_with_hash(route_path)
    capabilities, capabilities_hash = _read_static_json_with_hash(capabilities_path)
    registry = load_registry(package_root, manifest=manifest if isinstance(manifest, dict) else {})
    core_rules = project_core_rules(registry)
    identity = {
        "manifest": manifest if isinstance(manifest, dict) else {},
        "manifestHash": manifest_hash,
        "routeMap": route_map if isinstance(route_map, dict) else {},
        "routeMapHash": route_map_hash,
        "capabilities": capabilities if isinstance(capabilities, dict) else {},
        "capabilitiesHash": capabilities_hash,
        "manifestReady": isinstance(manifest, dict) and bool(manifest.get("version")),
        "routeMapReady": isinstance(route_map, dict) and bool(route_map.get("routes")),
        "capabilitiesReady": isinstance(capabilities, dict) and bool(capabilities.get("capabilities")),
        "coreRules": core_rules,
        "coreRulesReady": core_rules.get("status") == "current",
    }
    # Re-stamp after reading. A write during compilation must not be hidden
    # behind the cached snapshot on the next request.
    _static_identity_cache_put(cache_key, _static_identity_stamps(static_paths), identity)
    return identity


def _receipt_hash(receipt: dict[str, Any]) -> str:
    body = {key: value for key, value in receipt.items() if key not in {"receiptHash", "writtenAt"}}
    return canonical_hash(body)


def _activate_unlocked(
    package_root: str | Path,
    memory_base: str | Path,
    *,
    memory_root: str | Path | None = None,
    workspace_key: str = "",
    session_key: str = "",
    task_id: str = "",
    task_instance_id: str = "",
    route: str = "bare_wake",
    memory_mode: str = "auto",
    memory_snapshot_hash: str = "",
    memory_refs: Iterable[Any] = (),
    contract: dict[str, Any] | None = None,
    instruction_anchor_hash: str = "",
    continuation_receipt_hash: str = "",
    recovery_checkpoint_id: str = "",
    recovery_state_hash: str = "",
    return_point: dict[str, Any] | None = None,
    action_authorization: str = "withheld",
    degraded_reasons: Iterable[str] = (),
    require_scope: bool = False,
    activation_id: str = "",
) -> dict[str, Any]:
    package = Path(package_root).expanduser().resolve()
    memory_base_path = Path(memory_base).expanduser().resolve()
    memory_root_path = Path(memory_root).expanduser().resolve() if memory_root else memory_base_path
    identity = _static_identity(package)
    scope = _scope_ref(workspace_key, session_key, task_id, task_instance_id)
    refs = [str(value) for value in memory_refs if str(value)]
    contract = contract if isinstance(contract, dict) else {}
    contract_hash = canonical_hash(contract) if contract else ""
    contract_revision = int(contract.get("revision", 0) or 0)
    route_name = str(route or "bare_wake")
    metadata = route_metadata(identity["routeMap"], route_name)
    task_state = "ready" if task_id and contract else "none"
    reasons = [str(value) for value in degraded_reasons if str(value)]
    checks = {
        "packageRoot": package.exists(),
        "memoryRoot": memory_root_path.exists(),
        "manifest": identity["manifestReady"] and bool(identity["manifestHash"]),
        "routeMap": identity["routeMapReady"] and bool(identity["routeMapHash"]),
        "capabilities": identity["capabilitiesReady"] and bool(identity["capabilitiesHash"]),
        "coreRules": bool(identity["coreRulesReady"]),
        "scope": bool(workspace_key and session_key) if require_scope else True,
    }
    core_ready = all(checks.values())
    if not core_ready:
        state = "failed" if not checks["packageRoot"] or not checks["memoryRoot"] else "withheld"
        reasons = list(dict.fromkeys(reasons + [key for key, value in checks.items() if not value]))
    elif reasons:
        # Partial activation is not permission to continue governed work.
        # Surface it as withheld so callers must repair or reconcile first.
        state = "withheld"
    else:
        state = "full_brain_active"
    if action_authorization not in {"allowed", "withheld", "not_applicable"}:
        action_authorization = "withheld"
    if task_state == "none" and action_authorization == "allowed":
        action_authorization = "not_applicable"
    receipt: dict[str, Any] = {
        "schema": ACTIVATION_SCHEMA,
        "activationId": activation_id or "act-" + uuid.uuid4().hex,
        "activatedAt": utc_now(),
        "activationState": state,
        "package": {
            "version": str(identity["manifest"].get("version", "")),
            "manifestHash": identity["manifestHash"],
            "capabilitiesHash": identity["capabilitiesHash"],
        },
        "scope": {
            "workspaceKey": str(workspace_key or ""),
            "sessionKeyHash": canonical_hash({"sessionKey": str(session_key or "")}) if session_key else "",
            "taskId": str(task_id or ""),
            "taskInstanceId": str(task_instance_id or ""),
            "scopeRef": scope,
        },
        "route": {
            "name": route_name,
            "routeMapHash": identity["routeMapHash"],
            **metadata,
        },
        "capabilities": {
            "core": list(CORE_CAPABILITIES),
            "coreReady": core_ready,
            "routeMapReady": bool(checks["routeMap"]),
            "capabilityMapReady": bool(checks["capabilities"]),
            "coreRulesReady": bool(checks["coreRules"]),
        },
        "coreRules": identity["coreRules"],
        "memory": {
            "mode": str(memory_mode or "auto"),
            "snapshotHash": str(memory_snapshot_hash or ""),
            "refs": refs[:8],
            "refsHash": _hash_list(refs[:8]),
            "bodyLoaded": bool(refs),
        },
        "task": {
            "state": task_state,
            "taskId": str(task_id or ""),
            "taskInstanceId": str(task_instance_id or ""),
            "contractRevision": contract_revision,
            "contractHash": contract_hash,
            "instructionAnchorHash": str(instruction_anchor_hash or ""),
            "continuationReceiptHash": str(continuation_receipt_hash or ""),
        },
        "recovery": {
            "checkpointId": str(recovery_checkpoint_id or ""),
            "stateHash": str(recovery_state_hash or ""),
            "returnPoint": return_point if isinstance(return_point, dict) else None,
        },
        "actionAuthorization": action_authorization if state == "full_brain_active" else "withheld",
        "degradedReasons": reasons,
        "checks": checks,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    receipt["receiptHash"] = _receipt_hash(receipt)
    receipt["writtenAt"] = receipt["activatedAt"]
    _atomic_json(receipt_path(memory_base_path, scope), receipt)
    return receipt


def activate(*args, **kwargs):
    """Write one activation receipt under the same per-scope lock as repair."""

    package_root = args[0] if args else kwargs.get("package_root", "")
    memory_base = args[1] if len(args) > 1 else kwargs.get("memory_base", "")
    scope = _scope_ref(
        str(kwargs.get("workspace_key", "")),
        str(kwargs.get("session_key", "")),
        str(kwargs.get("task_id", "")),
        str(kwargs.get("task_instance_id", "")),
    )
    with _activation_lock(memory_base, scope) as acquired:
        if not acquired:
            return {
                "schema": ACTIVATION_SCHEMA,
                "activationState": "withheld",
                "activationId": "",
                "activationCode": "ACTIVATION_SCOPE_LOCK_TIMEOUT",
                "actionAuthorization": "withheld",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        return _activate_unlocked(*args, **kwargs)


def read_valid(
    memory_base: str | Path,
    *,
    workspace_key: str = "",
    session_key: str = "",
    task_id: str = "",
    task_instance_id: str = "",
    package_root: str | Path | None = None,
) -> tuple[dict[str, Any] | None, str]:
    scope = _scope_ref(workspace_key, session_key, task_id, task_instance_id)
    path = receipt_path(memory_base, scope)
    value = _read_json(path)
    if not isinstance(value, dict):
        return None, "ACTIVATION_RECEIPT_MISSING"
    if value.get("schema") != ACTIVATION_SCHEMA:
        return None, "ACTIVATION_RECEIPT_SCHEMA_INVALID"
    if value.get("activationState") not in ACTIVATION_STATES:
        return None, "ACTIVATION_RECEIPT_STATE_INVALID"
    if value.get("actionAuthorization") not in {"allowed", "withheld", "not_applicable"}:
        return None, "ACTIVATION_RECEIPT_AUTHORIZATION_INVALID"
    if value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return None, "ACTIVATION_RECEIPT_PRIVACY_INVALID"
    scope_value = value.get("scope")
    if not isinstance(scope_value, dict):
        return None, "ACTIVATION_RECEIPT_SCOPE_INVALID"
    expected_session_hash = (
        canonical_hash({"sessionKey": str(session_key or "")}) if session_key else ""
    )
    if (
        scope_value.get("scopeRef") != scope
        or str(scope_value.get("workspaceKey", "")) != str(workspace_key or "")
        or str(scope_value.get("sessionKeyHash", "")) != expected_session_hash
        or str(scope_value.get("taskId", "")) != str(task_id or "")
        or str(scope_value.get("taskInstanceId", "")) != str(task_instance_id or "")
    ):
        return None, "ACTIVATION_RECEIPT_SCOPE_MISMATCH"
    if value.get("receiptHash") != _receipt_hash(value):
        return None, "ACTIVATION_RECEIPT_HASH_INVALID"
    if package_root is not None:
        identity = _static_identity(Path(package_root).expanduser().resolve())
        package = value.get("package")
        route = value.get("route")
        if not isinstance(package, dict):
            return None, "ACTIVATION_RECEIPT_PACKAGE_INVALID"
        if not isinstance(route, dict):
            return None, "ACTIVATION_RECEIPT_ROUTE_INVALID"
        if package.get("manifestHash") != identity["manifestHash"]:
            return None, "ACTIVATION_RECEIPT_MANIFEST_STALE"
        if package.get("capabilitiesHash") != identity["capabilitiesHash"]:
            return None, "ACTIVATION_RECEIPT_CAPABILITIES_STALE"
        if route.get("routeMapHash") != identity["routeMapHash"]:
            return None, "ACTIVATION_RECEIPT_ROUTE_STALE"
        core_rules = identity["coreRules"]
        if core_rules.get("status") != "current":
            return None, "ACTIVATION_RECEIPT_CORE_RULE_REGISTRY_WITHHELD"
        receipt_rules = value.get("coreRules") if isinstance(value.get("coreRules"), dict) else {}
        try:
            receipt_registry_version = int(receipt_rules.get("registryVersion", 0) or 0)
            current_registry_version = int(core_rules.get("registryVersion", 0) or 0)
        except (TypeError, ValueError, OverflowError):
            return None, "ACTIVATION_RECEIPT_CORE_RULES_INVALID"
        if (
            receipt_registry_version != current_registry_version
            or str(receipt_rules.get("payloadHash", "")) != str(core_rules.get("payloadHash", ""))
            or str(receipt_rules.get("activeEffectsHash", "")) != str(core_rules.get("activeEffectsHash", ""))
        ):
            return None, "ACTIVATION_RECEIPT_CORE_RULE_REGISTRY_STALE"
    return value, "ACTIVATION_RECEIPT_CURRENT"


@_ensure_current_locked
def ensure_current(
    package_root: str | Path,
    memory_base: str | Path,
    *,
    memory_root: str | Path | None = None,
    workspace_key: str = "",
    session_key: str = "",
    task_id: str = "",
    task_instance_id: str = "",
    route: str = "bare_wake",
    memory_mode: str = "auto",
    memory_snapshot_hash: str = "",
    memory_refs: Iterable[Any] = (),
    contract: dict[str, Any] | None = None,
    instruction_anchor_hash: str = "",
    continuation_receipt_hash: str = "",
    recovery_checkpoint_id: str = "",
    recovery_state_hash: str = "",
    return_point: dict[str, Any] | None = None,
    action_authorization: str = "withheld",
    degraded_reasons: Iterable[str] = (),
    require_scope: bool = False,
) -> tuple[dict[str, Any], str]:
    """Return a current activation receipt, repairing a missing/stale one.

    The core runtime may be reached without the Desktop Hook.  Every governed
    route therefore gets one small, idempotent activation self-heal.  A valid
    receipt is reused unless its task, instruction, memory, recovery, or
    authorization binding has changed; no prompt or transcript is stored.
    """

    refs = [str(value) for value in memory_refs if str(value)]
    requested_reasons = list(dict.fromkeys(str(value) for value in degraded_reasons if str(value)))
    contract_value = contract if isinstance(contract, dict) else {}
    scope = _scope_ref(workspace_key, session_key, task_id, task_instance_id)
    package_path = Path(package_root).expanduser().resolve()
    memory_root_path = Path(memory_root).expanduser().resolve() if memory_root else Path(memory_base).expanduser().resolve()
    expected_checks = {
        "packageRoot": package_path.exists(),
        "memoryRoot": memory_root_path.exists(),
        "scope": bool(workspace_key and session_key) if require_scope else True,
    }
    expected_reasons = list(dict.fromkeys(requested_reasons + [key for key, value in expected_checks.items() if not value]))
    prior_receipt_exists = receipt_path(memory_base, scope).exists()
    current, current_code = read_valid(
        memory_base,
        workspace_key=workspace_key,
        session_key=session_key,
        task_id=task_id,
        task_instance_id=task_instance_id,
        package_root=package_root,
    )
    refresh = current is None
    if current is not None:
        current_task = current.get("task") if isinstance(current.get("task"), dict) else {}
        current_memory = current.get("memory") if isinstance(current.get("memory"), dict) else {}
        current_recovery = current.get("recovery") if isinstance(current.get("recovery"), dict) else {}
        current_route = current.get("route") if isinstance(current.get("route"), dict) else {}
        refresh = refresh or str(current_route.get("name", "bare_wake")) != str(route or "bare_wake")
        current_reasons = list(dict.fromkeys(
            str(value) for value in (current.get("degradedReasons") or []) if str(value)
        ))
        refresh = refresh or current_reasons != expected_reasons
        if str(current.get("activationState", "")) == "failed":
            refresh = True
        if contract_value:
            refresh = refresh or int(current_task.get("contractRevision", 0) or 0) != int(contract_value.get("revision", 0) or 0)
            refresh = refresh or str(current_task.get("contractHash", "")) != canonical_hash(contract_value)
        if instruction_anchor_hash:
            refresh = refresh or str(current_task.get("instructionAnchorHash", "")) != str(instruction_anchor_hash)
        if continuation_receipt_hash:
            refresh = refresh or str(current_task.get("continuationReceiptHash", "")) != str(continuation_receipt_hash)
        if recovery_checkpoint_id:
            refresh = refresh or str(current_recovery.get("checkpointId", "")) != str(recovery_checkpoint_id)
        if recovery_state_hash:
            refresh = refresh or str(current_recovery.get("stateHash", "")) != str(recovery_state_hash)
        if memory_snapshot_hash:
            refresh = refresh or str(current_memory.get("snapshotHash", "")) != str(memory_snapshot_hash)
        if refs:
            refresh = refresh or list(current_memory.get("refs", []) or []) != refs[:8]
        requested_authorization = str(action_authorization or "withheld")
        if requested_authorization not in {"allowed", "withheld", "not_applicable"}:
            requested_authorization = "withheld"
        if not (task_id and contract_value) and requested_authorization == "allowed":
            requested_authorization = "not_applicable"
        refresh = refresh or str(current.get("actionAuthorization", "withheld")) != requested_authorization

    if not refresh and current is not None:
        return current, "ACTIVATION_RECEIPT_CURRENT"

    receipt = _activate_unlocked(
        package_root,
        memory_base,
        memory_root=memory_root,
        workspace_key=workspace_key,
        session_key=session_key,
        task_id=task_id,
        task_instance_id=task_instance_id,
        route=route,
        memory_mode=memory_mode,
        memory_snapshot_hash=memory_snapshot_hash,
        memory_refs=refs,
        contract=contract_value,
        instruction_anchor_hash=instruction_anchor_hash,
        continuation_receipt_hash=continuation_receipt_hash,
        recovery_checkpoint_id=recovery_checkpoint_id,
        recovery_state_hash=recovery_state_hash,
        return_point=return_point,
        action_authorization=action_authorization,
        degraded_reasons=requested_reasons,
        require_scope=require_scope,
    )
    return receipt, "ACTIVATION_RECEIPT_REISSUED" if prior_receipt_exists else "ACTIVATION_RECEIPT_CREATED"


__all__ = [
    "ACTIVATION_SCHEMA",
    "ACTIVATION_STATES",
    "ACTIVATION_TIERS",
    "CORE_CAPABILITIES",
    "ROUTE_CLASSES",
    "ROUTE_METADATA_FIELDS",
    "activate",
    "canonical_hash",
    "ensure_current",
    "file_sha256",
    "read_valid",
    "receipt_path",
    "route_metadata",
]
