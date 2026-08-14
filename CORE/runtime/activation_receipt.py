from __future__ import annotations

"""Small, content-addressed activation gate for Super Brain.

The module deliberately owns only activation identity, readiness, and the
scoped receipt.  It does not own task mutations, memory writes, or Hook
dispatch.  Callers pass already-observed task/memory projections and receive a
bounded receipt that can be validated on the next turn.
"""

import hashlib
import json
import os
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from core_rule_registry import load_registry, public_projection as project_core_rules


ACTIVATION_SCHEMA = "super-brain.activation-receipt.v1"
ACTIVATION_STATES = {"full_brain_active", "withheld", "failed"}
CORE_CAPABILITIES = ("runtime", "route", "memory", "task_state", "continuation", "response_policy", "core_rules")
ACTIVE_RECEIPTS_DIRECTORY = "receipts-current"
LEGACY_RECEIPTS_DIRECTORY = "receipts"


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


def _static_identity(package_root: Path) -> dict[str, Any]:
    manifest_path = package_root / "manifest.json"
    route_path = package_root / "route-map.json"
    capabilities_path = package_root / "capabilities.json"
    manifest = _read_json(manifest_path)
    route_map = _read_json(route_path)
    capabilities = _read_json(capabilities_path)
    registry = load_registry(package_root, manifest=manifest if isinstance(manifest, dict) else {})
    core_rules = project_core_rules(registry)
    return {
        "manifest": manifest if isinstance(manifest, dict) else {},
        "manifestHash": file_sha256(manifest_path),
        "routeMap": route_map if isinstance(route_map, dict) else {},
        "routeMapHash": file_sha256(route_path),
        "capabilities": capabilities if isinstance(capabilities, dict) else {},
        "capabilitiesHash": file_sha256(capabilities_path),
        "manifestReady": isinstance(manifest, dict) and bool(manifest.get("version")),
        "routeMapReady": isinstance(route_map, dict) and bool(route_map.get("routes")),
        "capabilitiesReady": isinstance(capabilities, dict) and bool(capabilities.get("capabilities")),
        "coreRules": core_rules,
        "coreRulesReady": core_rules.get("status") == "current",
    }


def _receipt_hash(receipt: dict[str, Any]) -> str:
    body = {key: value for key, value in receipt.items() if key not in {"receiptHash", "writtenAt"}}
    return canonical_hash(body)


def activate(
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
        },
        "scope": {
            "workspaceKey": str(workspace_key or ""),
            "sessionKeyHash": canonical_hash({"sessionKey": str(session_key or "")}) if session_key else "",
            "taskId": str(task_id or ""),
            "taskInstanceId": str(task_instance_id or ""),
            "scopeRef": scope,
        },
        "route": {
            "name": str(route or "bare_wake"),
            "routeMapHash": identity["routeMapHash"],
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
    if value.get("scope", {}).get("scopeRef") != scope:
        return None, "ACTIVATION_RECEIPT_SCOPE_MISMATCH"
    if value.get("receiptHash") != _receipt_hash(value):
        return None, "ACTIVATION_RECEIPT_HASH_INVALID"
    if package_root is not None:
        identity = _static_identity(Path(package_root).expanduser().resolve())
        package = value.get("package") or {}
        route = value.get("route") or {}
        if package.get("manifestHash") != identity["manifestHash"]:
            return None, "ACTIVATION_RECEIPT_MANIFEST_STALE"
        if route.get("routeMapHash") != identity["routeMapHash"]:
            return None, "ACTIVATION_RECEIPT_ROUTE_STALE"
        core_rules = identity["coreRules"]
        if core_rules.get("status") != "current":
            return None, "ACTIVATION_RECEIPT_CORE_RULE_REGISTRY_WITHHELD"
        receipt_rules = value.get("coreRules") if isinstance(value.get("coreRules"), dict) else {}
        if (
            int(receipt_rules.get("registryVersion", 0) or 0) != int(core_rules.get("registryVersion", 0) or 0)
            or str(receipt_rules.get("payloadHash", "")) != str(core_rules.get("payloadHash", ""))
            or str(receipt_rules.get("activeEffectsHash", "")) != str(core_rules.get("activeEffectsHash", ""))
        ):
            return None, "ACTIVATION_RECEIPT_CORE_RULE_REGISTRY_STALE"
    return value, "ACTIVATION_RECEIPT_CURRENT"


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
    contract_value = contract if isinstance(contract, dict) else {}
    scope = _scope_ref(workspace_key, session_key, task_id, task_instance_id)
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
        if action_authorization == "allowed":
            refresh = refresh or str(current.get("actionAuthorization", "withheld")) != "allowed"

    if not refresh and current is not None:
        return current, "ACTIVATION_RECEIPT_CURRENT"

    receipt = activate(
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
        degraded_reasons=degraded_reasons,
        require_scope=require_scope,
    )
    return receipt, "ACTIVATION_RECEIPT_REISSUED" if prior_receipt_exists else "ACTIVATION_RECEIPT_CREATED"


__all__ = [
    "ACTIVATION_SCHEMA",
    "ACTIVATION_STATES",
    "CORE_CAPABILITIES",
    "activate",
    "canonical_hash",
    "ensure_current",
    "file_sha256",
    "read_valid",
    "receipt_path",
]
