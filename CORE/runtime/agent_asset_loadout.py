from __future__ import annotations

"""Package-owned, no-worker asset selection for Super Brain execution.

An asset is a logical controller/router/verifier/delegation role, not a host
skill, subprocess, agent session, daemon, or separate memory store.  This
module only returns a bounded, non-authorizing loadout.  H7 keeps all state
authority and the controller must obtain explicit authorization before any
real delegation.
"""

import hashlib
import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping


REGISTRY_SCHEMA = "super-brain.agent-asset-registry.v1"
LOADOUT_SCHEMA = "super-brain.agent-asset-loadout.v1"

_TASK_CLASSES = {"engineering", "product", "productivity", "learning", "general"}
_SEMANTIC_SIGNALS = {
    "bug_diagnosis",
    "engineering_design",
    "product_planning",
    "productivity_workflow",
    "learning_teaching",
    "challenge_assumptions",
    "testing",
    "optimization",
    "implementation",
}
_APPLY_PHASES = {"planning", "execution", "verification"}
_ASSET_ID = re.compile(r"^[a-z][a-z0-9-]{1,79}$")
_ROLES = {"controller", "router", "verifier", "delegation_packet"}
_ACTIVATE_WHEN = {"always", "nontrivial", "verification", "explicit_multi_agent"}
_DISPATCH_MODES = {"direct", "explicit_only"}
_STATE_ACCESS = {"h7_only", "none", "isolated_only"}
_MAX_ASSETS = 8
_MAX_SELECTED = 4


def canonical_hash(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    ).hexdigest()


def _safe_text(value: Any, maximum: int = 80) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = " ".join(value.strip().split())
    return normalized if normalized and len(normalized) <= maximum else None


@lru_cache(maxsize=16)
def _read_registry(path_text: str, modified_ns: int, size: int) -> dict[str, Any] | None:
    del modified_ns, size
    try:
        value = json.loads(Path(path_text).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _registry_path(package_root: str | Path) -> Path:
    return Path(package_root).expanduser().resolve() / "agent-asset-registry.json"


def _valid_string_list(value: Any, *, allowed: set[str], maximum: int, minimum: int = 0) -> list[str] | None:
    if not isinstance(value, list) or not minimum <= len(value) <= maximum:
        return None
    items: list[str] = []
    for raw in value:
        item = _safe_text(raw, 80)
        if item not in allowed or item in items:
            return None
        items.append(item)
    return items


def _registry_entries(value: Any) -> tuple[dict[str, Any], list[dict[str, Any]]] | None:
    if not isinstance(value, Mapping) or set(value) != {"schema", "registryVersion", "policy", "assets"}:
        return None
    if value.get("schema") != REGISTRY_SCHEMA or value.get("registryVersion") != 1:
        return None
    policy = value.get("policy")
    if not isinstance(policy, Mapping) or set(policy) != {
        "defaultDispatch",
        "stateAuthority",
        "hostSkillExecution",
        "upstreamExecution",
        "backgroundWorkers",
        "rawPromptStored",
        "rawTranscriptStored",
    }:
        return None
    if policy != {
        "defaultDispatch": "direct",
        "stateAuthority": "h7_only",
        "hostSkillExecution": "forbidden",
        "upstreamExecution": "forbidden",
        "backgroundWorkers": "forbidden",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }:
        return None
    raw_assets = value.get("assets")
    if not isinstance(raw_assets, list) or not 1 <= len(raw_assets) <= _MAX_ASSETS:
        return None
    assets: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_roles: set[str] = set()
    expected_fields = {
        "assetId",
        "role",
        "applyAt",
        "activateWhen",
        "taskClasses",
        "semanticSignals",
        "dispatchMode",
        "stateAccess",
        "resultOnly",
    }
    for raw in raw_assets:
        if not isinstance(raw, Mapping) or set(raw) != expected_fields:
            return None
        asset_id = _safe_text(raw.get("assetId"), 80)
        role = _safe_text(raw.get("role"), 40)
        activate_when = _safe_text(raw.get("activateWhen"), 40)
        dispatch_mode = _safe_text(raw.get("dispatchMode"), 40)
        state_access = _safe_text(raw.get("stateAccess"), 40)
        apply_at = _valid_string_list(raw.get("applyAt"), allowed=_APPLY_PHASES, maximum=3, minimum=1)
        task_classes = _valid_string_list(raw.get("taskClasses"), allowed=_TASK_CLASSES, maximum=5, minimum=1)
        signals = _valid_string_list(raw.get("semanticSignals"), allowed=_SEMANTIC_SIGNALS, maximum=6)
        if (
            asset_id is None
            or not _ASSET_ID.fullmatch(asset_id)
            or asset_id in seen_ids
            or role not in _ROLES
            or role in seen_roles
            or activate_when not in _ACTIVATE_WHEN
            or dispatch_mode not in _DISPATCH_MODES
            or state_access not in _STATE_ACCESS
            or apply_at is None
            or task_classes is None
            or signals is None
            or not isinstance(raw.get("resultOnly"), bool)
        ):
            return None
        if role == "controller" and (state_access != "h7_only" or raw.get("resultOnly") is not False):
            return None
        if role != "controller" and (state_access == "h7_only" or raw.get("resultOnly") is not True):
            return None
        if role == "delegation_packet" and (activate_when != "explicit_multi_agent" or dispatch_mode != "explicit_only"):
            return None
        if role != "delegation_packet" and dispatch_mode != "direct":
            return None
        seen_ids.add(asset_id)
        seen_roles.add(role)
        assets.append(
            {
                "assetId": asset_id,
                "role": role,
                "applyAt": apply_at,
                "activateWhen": activate_when,
                "taskClasses": task_classes,
                "semanticSignals": signals,
                "dispatchMode": dispatch_mode,
                "stateAccess": state_access,
                "resultOnly": bool(raw["resultOnly"]),
            }
        )
    if "controller" not in seen_roles:
        return None
    return dict(policy), assets


def _active(asset: Mapping[str, Any], *, task_class: str, signals: set[str], apply_phase: str, delegation_requested: bool) -> bool:
    if task_class not in asset.get("taskClasses", []) or apply_phase not in asset.get("applyAt", []):
        return False
    required_signals = set(asset.get("semanticSignals", []) or [])
    if required_signals and not required_signals.intersection(signals):
        return False
    activate_when = str(asset.get("activateWhen", ""))
    if activate_when == "always":
        return True
    if activate_when == "nontrivial":
        return bool(signals)
    if activate_when == "verification":
        return apply_phase == "verification"
    if activate_when == "explicit_multi_agent":
        return delegation_requested
    return False


def resolve_agent_asset_loadout(
    package_root: str | Path,
    *,
    task_class: str,
    semantic_signals: set[str],
    apply_phase: str,
    delegation_requested: bool = False,
    applicable: bool = True,
    withheld: bool = False,
) -> tuple[dict[str, Any] | None, str]:
    """Return a small H7-owned logical role loadout or fail closed.

    Calling this function never launches, reserves, polls, or installs an
    agent.  ``delegation_requested`` may select only a packet role; a separate
    controller decision and explicit user authority remain mandatory before a
    host agent can be created.
    """

    if task_class not in _TASK_CLASSES or apply_phase not in _APPLY_PHASES:
        return None, "H7_AGENT_ASSET_LOADOUT_INPUT_INVALID"
    if (
        not isinstance(delegation_requested, bool)
        or not isinstance(applicable, bool)
        or any(signal not in _SEMANTIC_SIGNALS for signal in semantic_signals)
    ):
        return None, "H7_AGENT_ASSET_LOADOUT_INPUT_INVALID"
    # Direct/simple work must not pay a registry-read cost or gain artificial
    # task machinery.  The loadout remains an explicit, validated no-op until
    # H7 has classified the turn as non-trivial.
    if not applicable:
        body = {
            "schema": LOADOUT_SCHEMA,
            "state": "not_applicable",
            "code": "H7_AGENT_ASSET_LOADOUT_NOT_APPLICABLE",
            "applyPhase": apply_phase,
            "dispatchMode": "direct",
            "selectedAssetIds": [],
            "deferredAssetIds": [],
            "h7StateAuthority": True,
            "backgroundWorkers": False,
            "hostSkillExecution": False,
            "upstreamExecution": False,
            "nonAuthorizing": True,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return {**body, "payloadHash": canonical_hash(body)}, "H7_AGENT_ASSET_LOADOUT_NOT_APPLICABLE"
    path = _registry_path(package_root)
    try:
        stat = path.stat()
    except OSError:
        return None, "H7_AGENT_ASSET_REGISTRY_UNAVAILABLE"
    registry = _read_registry(str(path), int(stat.st_mtime_ns), int(stat.st_size))
    parsed = _registry_entries(registry)
    if parsed is None:
        return None, "H7_AGENT_ASSET_REGISTRY_INVALID"
    policy, assets = parsed
    selected = [
        asset
        for asset in assets
        if applicable
        and not withheld
        and _active(
            asset,
            task_class=task_class,
            signals=semantic_signals,
            apply_phase=apply_phase,
            delegation_requested=delegation_requested,
        )
    ][:_MAX_SELECTED]
    selected_ids = [str(asset["assetId"]) for asset in selected]
    deferred_ids = [
        str(asset["assetId"])
        for asset in assets
        if str(asset["assetId"]) not in selected_ids
        and task_class in asset.get("taskClasses", [])
        and apply_phase in asset.get("applyAt", [])
    ][:_MAX_SELECTED]
    state = "withheld" if withheld else ("ready" if selected else "not_applicable")
    body = {
        "schema": LOADOUT_SCHEMA,
        "state": state,
        "code": {
            "ready": "H7_AGENT_ASSET_LOADOUT_READY",
            "not_applicable": "H7_AGENT_ASSET_LOADOUT_NOT_APPLICABLE",
            "withheld": "H7_AGENT_ASSET_LOADOUT_WITHHELD",
        }[state],
        "applyPhase": apply_phase,
        "dispatchMode": "single_delegate_requires_explicit_authority" if delegation_requested and not withheld else policy["defaultDispatch"],
        "selectedAssetIds": selected_ids,
        "deferredAssetIds": [] if withheld else deferred_ids,
        "h7StateAuthority": True,
        "backgroundWorkers": False,
        "hostSkillExecution": False,
        "upstreamExecution": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}, "H7_AGENT_ASSET_REGISTRY_CURRENT"


def loadout_is_valid(value: Any) -> bool:
    if not isinstance(value, Mapping) or set(value) != {
        "schema",
        "state",
        "code",
        "applyPhase",
        "dispatchMode",
        "selectedAssetIds",
        "deferredAssetIds",
        "h7StateAuthority",
        "backgroundWorkers",
        "hostSkillExecution",
        "upstreamExecution",
        "nonAuthorizing",
        "rawPromptStored",
        "rawTranscriptStored",
        "payloadHash",
    }:
        return False
    state = value.get("state")
    expected_code = {
        "ready": "H7_AGENT_ASSET_LOADOUT_READY",
        "not_applicable": "H7_AGENT_ASSET_LOADOUT_NOT_APPLICABLE",
        "withheld": "H7_AGENT_ASSET_LOADOUT_WITHHELD",
    }.get(state)
    selected = value.get("selectedAssetIds")
    deferred = value.get("deferredAssetIds")
    if (
        value.get("schema") != LOADOUT_SCHEMA
        or value.get("code") != expected_code
        or value.get("applyPhase") not in _APPLY_PHASES
        or value.get("dispatchMode") not in {"direct", "single_delegate_requires_explicit_authority"}
        or not isinstance(selected, list)
        or not isinstance(deferred, list)
        or len(selected) > _MAX_SELECTED
        or len(deferred) > _MAX_SELECTED
        or len(set(selected)) != len(selected)
        or len(set(deferred)) != len(deferred)
        or set(selected).intersection(deferred)
        or any(not isinstance(asset_id, str) or not _ASSET_ID.fullmatch(asset_id) for asset_id in selected + deferred)
        or value.get("h7StateAuthority") is not True
        or value.get("backgroundWorkers") is not False
        or value.get("hostSkillExecution") is not False
        or value.get("upstreamExecution") is not False
        or value.get("nonAuthorizing") is not True
        or value.get("rawPromptStored") is not False
        or value.get("rawTranscriptStored") is not False
        or not isinstance(value.get("payloadHash"), str)
        or not re.fullmatch(r"[a-f0-9]{64}", str(value.get("payloadHash")))
        or (state == "ready") != bool(selected)
        or (state == "withheld" and (selected or deferred))
    ):
        return False
    return str(value["payloadHash"]) == canonical_hash({key: item for key, item in value.items() if key != "payloadHash"})


def public_projection(value: Mapping[str, Any] | None) -> dict[str, Any]:
    """Return a compact, path-free public loadout projection."""

    loadout = value if loadout_is_valid(value) else {}
    return {
        "state": str(loadout.get("state", "withheld")),
        "code": str(loadout.get("code", "H7_AGENT_ASSET_LOADOUT_UNAVAILABLE")),
        "applyPhase": str(loadout.get("applyPhase", "")),
        "dispatchMode": str(loadout.get("dispatchMode", "")),
        "selectedAssetIds": list(loadout.get("selectedAssetIds", []) or [])[:_MAX_SELECTED],
        "deferredAssetIds": list(loadout.get("deferredAssetIds", []) or [])[:_MAX_SELECTED],
        "h7StateAuthority": loadout.get("h7StateAuthority") is True,
        "backgroundWorkers": False,
        "hostSkillExecution": False,
        "upstreamExecution": False,
        "nonAuthorizing": loadout.get("nonAuthorizing") is True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "payloadHash": str(loadout.get("payloadHash", "")),
    }


__all__ = [
    "LOADOUT_SCHEMA",
    "REGISTRY_SCHEMA",
    "loadout_is_valid",
    "public_projection",
    "resolve_agent_asset_loadout",
]
