from __future__ import annotations

"""H7-bound declarative work-DAG records.

The canonical execution contract remains the only task-state authority.  A
work-DAG record contains only a dependency declaration and a strict binding to
one exact contract revision and plan fingerprint; node status is always
projected from that contract.  It therefore cannot schedule workers, create a
second task store, or advance work on its own.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Mapping


DEFINITION_SCHEMA = "super-brain.work-dag-definition.v1"
STATE_SCHEMA = "super-brain.work-dag.v1"
PROJECTION_SCHEMA = "super-brain.work-dag-projection.v1"

_MAX_NODES = 48
_MAX_DEPENDENCIES = 12
_NODE_ID = re.compile(r"^[A-Za-z][A-Za-z0-9._:-]{1,159}$")
_HASH = re.compile(r"^[a-f0-9]{64}$")
_PLAN_FINGERPRINT = re.compile(r"^[a-f0-9]{16,96}$")
_TASK_STATUS = {"pending", "in_progress", "completed", "blocked", "cancelled"}


def canonical_hash(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    ).hexdigest()


def _compact(value: Any, maximum: int) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = " ".join(value.strip().split())
    return normalized if normalized and len(normalized) <= maximum else None


def _contract_view(contract: Any) -> tuple[dict[str, Any] | None, str]:
    if not isinstance(contract, Mapping) or contract.get("ok") is not True:
        return None, "H7_WORK_DAG_CONTRACT_UNAVAILABLE"
    task_id = _compact(contract.get("taskId"), 160)
    task_instance_id = _compact(contract.get("taskInstanceId"), 80)
    workspace_key = _compact(contract.get("workspaceKey"), 160)
    owner_session_key = _compact(contract.get("ownerSessionKey"), 160)
    try:
        revision = int(contract.get("revision", 0) or 0)
    except (TypeError, ValueError):
        revision = 0
    plan_receipt = contract.get("planReceipt") if isinstance(contract.get("planReceipt"), Mapping) else {}
    plan_fingerprint = _compact(plan_receipt.get("planFingerprint"), 96)
    canonical_plan = contract.get("canonicalPlan") if isinstance(contract.get("canonicalPlan"), Mapping) else {}
    items = canonical_plan.get("items") if isinstance(canonical_plan.get("items"), list) else []
    if (
        not task_id
        or not task_instance_id
        or not workspace_key
        or not owner_session_key
        or revision <= 0
        or not plan_fingerprint
        or not _PLAN_FINGERPRINT.fullmatch(plan_fingerprint)
        or not 1 <= len(items) <= _MAX_NODES
    ):
        return None, "H7_WORK_DAG_CONTRACT_INVALID"
    normalized_items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in items:
        if not isinstance(item, Mapping):
            return None, "H7_WORK_DAG_CONTRACT_INVALID"
        node_id = _compact(item.get("itemId"), 160)
        label = _compact(item.get("label"), 180)
        status = _compact(item.get("status"), 32)
        try:
            ordinal = int(item.get("ordinal", 0) or 0)
        except (TypeError, ValueError):
            ordinal = 0
        if (
            not node_id
            or not _NODE_ID.fullmatch(node_id)
            or node_id in seen
            or not label
            or status not in _TASK_STATUS
            or ordinal <= 0
        ):
            return None, "H7_WORK_DAG_CONTRACT_INVALID"
        seen.add(node_id)
        normalized_items.append({"nodeId": node_id, "label": label, "status": status, "ordinal": ordinal})
    normalized_items.sort(key=lambda item: (int(item["ordinal"]), str(item["nodeId"])))
    if [int(item["ordinal"]) for item in normalized_items] != list(range(1, len(normalized_items) + 1)):
        return None, "H7_WORK_DAG_CONTRACT_INVALID"
    return (
        {
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "workspaceKey": workspace_key,
            "ownerSessionKey": owner_session_key,
            "contractRevision": revision,
            "planFingerprint": plan_fingerprint,
            "items": normalized_items,
        },
        "H7_WORK_DAG_CONTRACT_CURRENT",
    )


def _default_definition(contract: Mapping[str, Any]) -> dict[str, Any]:
    previous = ""
    nodes: list[dict[str, Any]] = []
    for item in contract["items"]:
        node_id = str(item["nodeId"])
        nodes.append({"nodeId": node_id, "dependsOn": [previous] if previous else []})
        previous = node_id
    return {
        "schema": DEFINITION_SCHEMA,
        "nodes": nodes,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _detect_cycle(nodes: Mapping[str, list[str]]) -> bool:
    visiting: set[str] = set()
    visited: set[str] = set()

    def walk(node_id: str) -> bool:
        if node_id in visited:
            return False
        if node_id in visiting:
            return True
        visiting.add(node_id)
        for dependency in nodes.get(node_id, []):
            if walk(dependency):
                return True
        visiting.remove(node_id)
        visited.add(node_id)
        return False

    return any(walk(node_id) for node_id in nodes)


def normalize_definition(value: Any, contract: Mapping[str, Any]) -> tuple[dict[str, Any] | None, str]:
    # Keep the public normalizer tied to the canonical contract shape rather
    # than an internal pre-normalized view.  This makes validation identical
    # for the PowerShell wrapper, CLI callers, and focused regressions.
    contract_view, contract_code = _contract_view(contract)
    if contract_view is None:
        return None, contract_code
    if not isinstance(value, Mapping) or set(value) != {"schema", "nodes", "rawPromptStored", "rawTranscriptStored"}:
        return None, "H7_WORK_DAG_DEFINITION_FIELDS_INVALID"
    if value.get("schema") != DEFINITION_SCHEMA or value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return None, "H7_WORK_DAG_DEFINITION_INVALID"
    raw_nodes = value.get("nodes")
    items = list(contract_view.get("items", []) or [])
    allowed_ids = {str(item["nodeId"]) for item in items}
    if not isinstance(raw_nodes, list) or len(raw_nodes) != len(allowed_ids) or not raw_nodes:
        return None, "H7_WORK_DAG_DEFINITION_COVERAGE_INVALID"
    dependencies_by_id: dict[str, list[str]] = {}
    for raw in raw_nodes:
        if not isinstance(raw, Mapping) or set(raw) != {"nodeId", "dependsOn"}:
            return None, "H7_WORK_DAG_DEFINITION_FIELDS_INVALID"
        node_id = _compact(raw.get("nodeId"), 160)
        depends_on = raw.get("dependsOn")
        if not node_id or not _NODE_ID.fullmatch(node_id) or node_id not in allowed_ids or node_id in dependencies_by_id:
            return None, "H7_WORK_DAG_DEFINITION_COVERAGE_INVALID"
        if not isinstance(depends_on, list) or len(depends_on) > _MAX_DEPENDENCIES:
            return None, "H7_WORK_DAG_DEFINITION_INVALID"
        normalized_dependencies: list[str] = []
        for raw_dependency in depends_on:
            dependency = _compact(raw_dependency, 160)
            if (
                not dependency
                or dependency not in allowed_ids
                or dependency == node_id
                or dependency in normalized_dependencies
            ):
                return None, "H7_WORK_DAG_DEFINITION_INVALID"
            normalized_dependencies.append(dependency)
        dependencies_by_id[node_id] = normalized_dependencies
    if set(dependencies_by_id) != allowed_ids or _detect_cycle(dependencies_by_id):
        return None, "H7_WORK_DAG_DEFINITION_CYCLE_OR_COVERAGE_INVALID"
    nodes = [
        {"nodeId": str(item["nodeId"]), "dependsOn": dependencies_by_id[str(item["nodeId"])]}
        for item in items
    ]
    return (
        {
            "schema": DEFINITION_SCHEMA,
            "nodes": nodes,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        },
        "H7_WORK_DAG_DEFINITION_CURRENT",
    )


def _state_body(contract: Mapping[str, Any], definition: Mapping[str, Any], dag_revision: int) -> dict[str, Any]:
    dependencies = {str(node["nodeId"]): list(node["dependsOn"]) for node in definition["nodes"]}
    return {
        "schema": STATE_SCHEMA,
        "taskId": str(contract["taskId"]),
        "taskInstanceId": str(contract["taskInstanceId"]),
        "workspaceKey": str(contract["workspaceKey"]),
        "ownerSessionKey": str(contract["ownerSessionKey"]),
        "contractRevision": int(contract["contractRevision"]),
        "planFingerprint": str(contract["planFingerprint"]),
        "dagRevision": dag_revision,
        "definitionHash": canonical_hash(definition),
        "nodes": [
            {
                "nodeId": str(item["nodeId"]),
                "dependsOn": list(dependencies[str(item["nodeId"])]),
            }
            for item in contract["items"]
        ],
        "stateAuthority": "h7_canonical_plan_only",
        "backgroundWorkers": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _state_with_hash(contract: Mapping[str, Any], definition: Mapping[str, Any], dag_revision: int) -> dict[str, Any]:
    body = _state_body(contract, definition, dag_revision)
    return {**body, "payloadHash": canonical_hash(body)}


def state_is_valid(value: Any) -> bool:
    if not isinstance(value, Mapping) or set(value) != {
        "schema",
        "taskId",
        "taskInstanceId",
        "workspaceKey",
        "ownerSessionKey",
        "contractRevision",
        "planFingerprint",
        "dagRevision",
        "definitionHash",
        "nodes",
        "stateAuthority",
        "backgroundWorkers",
        "nonAuthorizing",
        "rawPromptStored",
        "rawTranscriptStored",
        "payloadHash",
    }:
        return False
    try:
        contract_revision = int(value.get("contractRevision", 0) or 0)
        dag_revision = int(value.get("dagRevision", 0) or 0)
    except (TypeError, ValueError):
        return False
    nodes = value.get("nodes")
    if (
        value.get("schema") != STATE_SCHEMA
        or not _compact(value.get("taskId"), 160)
        or not _compact(value.get("taskInstanceId"), 80)
        or not _compact(value.get("workspaceKey"), 160)
        or not _compact(value.get("ownerSessionKey"), 160)
        or contract_revision <= 0
        or dag_revision <= 0
        or not isinstance(value.get("planFingerprint"), str)
        or not _PLAN_FINGERPRINT.fullmatch(str(value.get("planFingerprint")))
        or not isinstance(value.get("definitionHash"), str)
        or not _HASH.fullmatch(str(value.get("definitionHash")))
        or not isinstance(nodes, list)
        or not 1 <= len(nodes) <= _MAX_NODES
        or value.get("stateAuthority") != "h7_canonical_plan_only"
        or value.get("backgroundWorkers") is not False
        or value.get("nonAuthorizing") is not True
        or value.get("rawPromptStored") is not False
        or value.get("rawTranscriptStored") is not False
        or not isinstance(value.get("payloadHash"), str)
        or not _HASH.fullmatch(str(value.get("payloadHash")))
    ):
        return False
    seen: set[str] = set()
    graph: dict[str, list[str]] = {}
    for node in nodes:
        if not isinstance(node, Mapping) or set(node) != {"nodeId", "dependsOn"}:
            return False
        node_id = node.get("nodeId")
        dependencies = node.get("dependsOn")
        if not isinstance(node_id, str) or not _NODE_ID.fullmatch(node_id) or node_id in seen:
            return False
        if not isinstance(dependencies, list) or len(dependencies) > _MAX_DEPENDENCIES:
            return False
        normalized_dependencies: list[str] = []
        for dependency in dependencies:
            if (
                not isinstance(dependency, str)
                or not _NODE_ID.fullmatch(dependency)
                or dependency == node_id
                or dependency in normalized_dependencies
            ):
                return False
            normalized_dependencies.append(dependency)
        seen.add(node_id)
        graph[node_id] = normalized_dependencies
    if any(dependency not in seen for dependencies in graph.values() for dependency in dependencies) or _detect_cycle(graph):
        return False
    return str(value["payloadHash"]) == canonical_hash({key: item for key, item in value.items() if key != "payloadHash"})


def project_state(state: Any, contract: Any) -> tuple[dict[str, Any], bool]:
    contract_view, contract_code = _contract_view(contract)
    if contract_view is None:
        return _projection_withheld(contract_code), False
    if not state_is_valid(state):
        return _projection_withheld("H7_WORK_DAG_STATE_INVALID"), False
    state_map = dict(state)
    binding_matches = (
        state_map["taskId"] == contract_view["taskId"]
        and state_map["taskInstanceId"] == contract_view["taskInstanceId"]
        and state_map["workspaceKey"] == contract_view["workspaceKey"]
        and state_map["ownerSessionKey"] == contract_view["ownerSessionKey"]
        and int(state_map["contractRevision"]) == int(contract_view["contractRevision"])
        and state_map["planFingerprint"] == contract_view["planFingerprint"]
    )
    if not binding_matches:
        return (
            {
                "schema": PROJECTION_SCHEMA,
                "state": "stale_binding",
                "code": "H7_WORK_DAG_H7_BINDING_STALE",
                "dagRevision": int(state_map["dagRevision"]),
                "contractRevision": int(contract_view["contractRevision"]),
                "planFingerprint": str(contract_view["planFingerprint"]),
                "readyNodeIds": [],
                "activeNodeIds": [],
                "nodes": [],
                "backgroundWorkers": False,
                "nonAuthorizing": True,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            },
            False,
        )
    status_by_id = {str(item["nodeId"]): str(item["status"]) for item in contract_view["items"]}
    label_by_id = {str(item["nodeId"]): str(item["label"]) for item in contract_view["items"]}
    nodes: list[dict[str, Any]] = []
    ready: list[str] = []
    active: list[str] = []
    for node in state_map["nodes"]:
        node_id = str(node["nodeId"])
        dependencies = list(node["dependsOn"])
        status = status_by_id[node_id]
        dependency_statuses = [status_by_id[dependency] for dependency in dependencies]
        blocked_by_dependencies = any(status in {"blocked", "cancelled"} for status in dependency_statuses)
        is_ready = status == "pending" and all(dependency_status == "completed" for dependency_status in dependency_statuses)
        if is_ready:
            ready.append(node_id)
        if status == "in_progress":
            active.append(node_id)
        nodes.append(
            {
                "nodeId": node_id,
                "label": label_by_id[node_id],
                "dependsOn": dependencies,
                "status": status,
                "ready": is_ready,
                "blockedByDependencies": blocked_by_dependencies,
            }
        )
    projection = {
        "schema": PROJECTION_SCHEMA,
        "state": "current",
        "code": "H7_WORK_DAG_CURRENT",
        "dagRevision": int(state_map["dagRevision"]),
        "contractRevision": int(contract_view["contractRevision"]),
        "planFingerprint": str(contract_view["planFingerprint"]),
        "readyNodeIds": ready,
        "activeNodeIds": active,
        "nodes": nodes,
        "backgroundWorkers": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return projection, True


def _projection_withheld(code: str) -> dict[str, Any]:
    return {
        "schema": PROJECTION_SCHEMA,
        "state": "withheld",
        "code": code,
        "dagRevision": 0,
        "contractRevision": 0,
        "planFingerprint": "",
        "readyNodeIds": [],
        "activeNodeIds": [],
        "nodes": [],
        "backgroundWorkers": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


@contextmanager
def _file_lock(path: Path, timeout_seconds: float = 5.0) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + timeout_seconds
    with path.open("a+b") as handle:
        handle.seek(0, os.SEEK_END)
        if handle.tell() == 0:
            handle.write(b"0")
            handle.flush()
        while True:
            try:
                if os.name == "nt":
                    import msvcrt

                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("H7_WORK_DAG_LOCK_TIMEOUT")
                time.sleep(0.025)
        try:
            yield
        finally:
            try:
                if os.name == "nt":
                    import msvcrt

                    handle.seek(0)
                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass


def _atomic_write(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_text = tempfile.mkstemp(prefix=".work-dag-", suffix=".tmp", dir=str(path.parent))
    temporary = Path(temporary_text)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _decode_base64_json(value: str) -> Any:
    if not value:
        return None
    try:
        decoded = base64.b64decode(value.encode("ascii"), validate=True).decode("utf-8")
        return json.loads(decoded)
    except (UnicodeError, ValueError, json.JSONDecodeError):
        raise ValueError("H7_WORK_DAG_TRANSPORT_INVALID")


def _definition_from_state(state: Mapping[str, Any]) -> dict[str, Any]:
    """Recover the previous declarative graph without inventing a new DAG.

    A Refresh is allowed to rebind the derived projection to a newer H7
    contract revision.  It must not silently replace a user-supplied graph
    with the sequential default merely because the caller omitted a new
    definition.
    """

    return {
        "schema": DEFINITION_SCHEMA,
        "nodes": [
            {"nodeId": str(node["nodeId"]), "dependsOn": list(node["dependsOn"])}
            for node in state["nodes"]
        ],
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def seed_or_refresh(
    *,
    state_path: Path,
    contract: Mapping[str, Any],
    action: str,
    definition: Any = None,
    expected_dag_revision: int = -1,
) -> dict[str, Any]:
    contract_view, code = _contract_view(contract)
    if contract_view is None:
        return {"ok": False, "code": code, "rawPromptStored": False, "rawTranscriptStored": False}
    if action not in {"seed", "refresh"}:
        return {"ok": False, "code": "H7_WORK_DAG_ACTION_INVALID", "rawPromptStored": False, "rawTranscriptStored": False}
    lock_path = state_path.with_suffix(state_path.suffix + ".lock")
    try:
        with _file_lock(lock_path):
            existing = _read_json(state_path)
            if action == "seed":
                parsed_definition, definition_code = normalize_definition(
                    definition if definition is not None else _default_definition(contract_view),
                    contract,
                )
                if parsed_definition is None:
                    return {"ok": False, "code": definition_code, "rawPromptStored": False, "rawTranscriptStored": False}
                if existing is not None:
                    projection, current = project_state(existing, contract)
                    if current and str(existing.get("definitionHash", "")) == canonical_hash(parsed_definition):
                        return {
                            "ok": True,
                            "code": "H7_WORK_DAG_SEED_IDEMPOTENT",
                            "stateMutated": False,
                            "projection": projection,
                            "rawPromptStored": False,
                            "rawTranscriptStored": False,
                        }
                    return {
                        "ok": False,
                        "code": "H7_WORK_DAG_SEED_REQUIRES_REFRESH",
                        "projection": projection,
                        "rawPromptStored": False,
                        "rawTranscriptStored": False,
                    }
                next_state = _state_with_hash(contract_view, parsed_definition, 1)
                _atomic_write(state_path, next_state)
                projection, _ = project_state(next_state, contract)
                return {
                    "ok": True,
                    "code": "H7_WORK_DAG_SEEDED",
                    "stateMutated": True,
                    "projection": projection,
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }
            if existing is None or not state_is_valid(existing):
                return {"ok": False, "code": "H7_WORK_DAG_STATE_UNAVAILABLE", "rawPromptStored": False, "rawTranscriptStored": False}
            if expected_dag_revision < 0 or int(existing["dagRevision"]) != expected_dag_revision:
                return {
                    "ok": False,
                    "code": "H7_WORK_DAG_CAS_MISMATCH",
                    "dagRevision": int(existing["dagRevision"]),
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }
            definition_input = definition if definition is not None else _definition_from_state(existing)
            parsed_definition, definition_code = normalize_definition(definition_input, contract)
            if parsed_definition is None:
                if definition is None:
                    return {
                        "ok": False,
                        "code": "H7_WORK_DAG_REFRESH_DEFINITION_REQUIRED",
                        "rawPromptStored": False,
                        "rawTranscriptStored": False,
                    }
                return {"ok": False, "code": definition_code, "rawPromptStored": False, "rawTranscriptStored": False}
            next_state = _state_with_hash(contract_view, parsed_definition, int(existing["dagRevision"]) + 1)
            _atomic_write(state_path, next_state)
            projection, _ = project_state(next_state, contract)
            return {
                "ok": True,
                "code": "H7_WORK_DAG_REFRESHED",
                "stateMutated": True,
                "projection": projection,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
    except TimeoutError as exc:
        return {"ok": False, "code": str(exc), "rawPromptStored": False, "rawTranscriptStored": False}


def get_projection(*, state_path: Path, contract: Mapping[str, Any]) -> dict[str, Any]:
    state = _read_json(state_path)
    projection, current = project_state(state, contract)
    return {
        "ok": current,
        "code": str(projection["code"]),
        "stateMutated": False,
        "projection": projection,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="H7 declarative work-DAG helper")
    parser.add_argument("--action", choices=("seed", "refresh", "get", "validate"), required=True)
    parser.add_argument("--state-path", required=True)
    parser.add_argument("--contract-base64", required=True)
    parser.add_argument("--definition-base64", default="")
    parser.add_argument("--expected-dag-revision", type=int, default=-1)
    args = parser.parse_args(argv)
    try:
        contract = _decode_base64_json(args.contract_base64)
        definition = _decode_base64_json(args.definition_base64) if args.definition_base64 else None
        state_path = Path(args.state_path).expanduser().resolve()
        if args.action == "validate":
            view, code = _contract_view(contract)
            if view is None:
                result = {"ok": False, "code": code, "rawPromptStored": False, "rawTranscriptStored": False}
            else:
                normalized, definition_code = normalize_definition(definition if definition is not None else _default_definition(view), contract)
                result = {
                    "ok": normalized is not None,
                    "code": definition_code,
                    "nodeCount": len((normalized or {}).get("nodes", []) or []),
                    "backgroundWorkers": False,
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }
        elif args.action == "get":
            result = get_projection(state_path=state_path, contract=contract)
        else:
            result = seed_or_refresh(
                state_path=state_path,
                contract=contract,
                action=args.action,
                definition=definition,
                expected_dag_revision=int(args.expected_dag_revision),
            )
    except ValueError as exc:
        result = {"ok": False, "code": str(exc), "rawPromptStored": False, "rawTranscriptStored": False}
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0 if result.get("ok") is True else 1


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))


__all__ = [
    "DEFINITION_SCHEMA",
    "PROJECTION_SCHEMA",
    "STATE_SCHEMA",
    "canonical_hash",
    "get_projection",
    "normalize_definition",
    "project_state",
    "seed_or_refresh",
    "state_is_valid",
]
