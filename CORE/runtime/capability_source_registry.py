from __future__ import annotations

"""Validated, package-owned provenance sources for H7 native capabilities.

The registry is deliberately small and declarative.  It admits only explicit
package-local sources that can map their outcomes to a Super Brain native
contract; it never exposes a source path or executes an upstream skill.
"""

import hashlib
import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping


REGISTRY_SCHEMA = "super-brain.capability-source-registry.v1"
SOURCE_TYPE = "absorbed-capability-source"
NATIVE_CONTRACT_SCHEMA = "super-brain.native-capability-contract.v1"
NATIVE_PARITY_SCHEMA = "super-brain.native-capability-parity.v1"

_MAX_SOURCES = 8
_MAX_SELECTED = 4
_SOURCE_ID = re.compile(r"^[a-z][a-z0-9-]{1,79}$")
_NAMESPACE = re.compile(r"^[a-z][a-z0-9-]{1,63}$")
_CAPABILITY_ID = re.compile(r"^[A-Za-z][A-Za-z0-9._:-]{1,159}$")
_CONTRACT_ID = re.compile(r"^sb\.native\.[a-z0-9][a-z0-9._-]{1,159}$")
_COMMIT = re.compile(r"^[a-f0-9]{7,64}$")
_SLUG = re.compile(r"[^a-z0-9]+")

_NAME_PRIORITY = {
    "grill-me": 1000,
    "diagnosing-bugs": 900,
    "tdd": 850,
    "to-prd": 800,
    "to-issues": 750,
    "codebase-design": 700,
    "improve-codebase-architecture": 650,
    "domain-modeling": 600,
    "prototype": 550,
    "handoff": 500,
    "teach": 450,
    "writing-great-skills": 400,
}


def canonical_hash(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    ).hexdigest()


def _safe_text(value: Any, maximum: int = 160) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = " ".join(value.strip().split())
    return normalized if normalized and len(normalized) <= maximum else None


def _slug(value: str) -> str:
    return _SLUG.sub("-", value.lower()).strip("-") or "capability"


@lru_cache(maxsize=32)
def _load_json(path_text: str, modified_ns: int, size: int) -> dict[str, Any] | None:
    del modified_ns, size
    try:
        value = json.loads(Path(path_text).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


@lru_cache(maxsize=32)
def _file_sha256(path_text: str, modified_ns: int, size: int) -> str:
    del modified_ns, size
    digest = hashlib.sha256()
    try:
        with Path(path_text).open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return ""
    return digest.hexdigest()


def _registry_path(root: Path) -> Path:
    return root / "capability-source-registry.json"


def _manifest_relative_path(value: Any) -> str | None:
    text = _safe_text(value, 240)
    if text is None:
        return None
    normalized = text.replace("\\", "/")
    parts = normalized.split("/")
    if (
        normalized.startswith("/")
        or ":" in normalized
        or len(parts) < 3
        or parts[0] != "extensions"
        or parts[-1] != "extension.json"
        or any(not part or part in {".", ".."} for part in parts)
    ):
        return None
    return "/".join(parts)


def _resolve_manifest(root: Path, relative_path: str) -> Path | None:
    extensions = (root / "extensions").resolve()
    candidate = (root / Path(relative_path)).resolve()
    try:
        candidate.relative_to(extensions)
    except ValueError:
        return None
    return candidate


def _registry_entries(registry: Mapping[str, Any]) -> list[dict[str, Any]] | None:
    if set(registry) != {"schema", "registryVersion", "sources"}:
        return None
    if registry.get("schema") != REGISTRY_SCHEMA or registry.get("registryVersion") != 1:
        return None
    raw_sources = registry.get("sources")
    if not isinstance(raw_sources, list) or not raw_sources or len(raw_sources) > _MAX_SOURCES:
        return None
    entries: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_namespaces: set[str] = set()
    seen_paths: set[str] = set()
    for raw in raw_sources:
        if not isinstance(raw, Mapping) or set(raw) != {"sourceId", "manifestPath", "capabilityNamespace", "required"}:
            return None
        source_id = _safe_text(raw.get("sourceId"), 80)
        namespace = _safe_text(raw.get("capabilityNamespace"), 64)
        manifest_path = _manifest_relative_path(raw.get("manifestPath"))
        required = raw.get("required")
        if (
            source_id is None
            or namespace is None
            or manifest_path is None
            or not _SOURCE_ID.fullmatch(source_id)
            or not _NAMESPACE.fullmatch(namespace)
            or not isinstance(required, bool)
            or source_id in seen_ids
            or namespace in seen_namespaces
            or manifest_path in seen_paths
        ):
            return None
        seen_ids.add(source_id)
        seen_namespaces.add(namespace)
        seen_paths.add(manifest_path)
        entries.append(
            {
                "sourceId": source_id,
                "manifestPath": manifest_path,
                "capabilityNamespace": namespace,
                "required": required,
            }
        )
    return entries


def _source_is_admissible(source: Mapping[str, Any], entry: Mapping[str, Any]) -> bool:
    if (
        source.get("id") != entry.get("sourceId")
        or source.get("type") != SOURCE_TYPE
        or source.get("sourceUse") != "provenance_cold_reference_only"
    ):
        return False
    for name in ("sourceRepo", "sourceCommit", "license"):
        if _safe_text(source.get(name), 240) is None:
            return False
    if not _COMMIT.fullmatch(str(source.get("sourceCommit", ""))):
        return False
    return isinstance(source.get("nativeBehaviorContracts"), list) and isinstance(source.get("skills"), list)


def load_capability_sources(package_root: str | Path) -> tuple[list[dict[str, Any]] | None, str]:
    """Return admitted source manifests or a fail-closed status code."""

    root = Path(package_root).expanduser().resolve()
    registry_path = _registry_path(root)
    try:
        registry_stat = registry_path.stat()
    except OSError:
        return None, "H7_EXECUTION_ASSIST_CAPABILITY_REGISTRY_UNAVAILABLE"
    registry = _load_json(str(registry_path), int(registry_stat.st_mtime_ns), int(registry_stat.st_size))
    entries = _registry_entries(registry or {}) if registry is not None else None
    if entries is None:
        return None, "H7_EXECUTION_ASSIST_CAPABILITY_REGISTRY_INVALID"
    registry_digest = _file_sha256(str(registry_path), int(registry_stat.st_mtime_ns), int(registry_stat.st_size))
    if not registry_digest:
        return None, "H7_EXECUTION_ASSIST_CAPABILITY_REGISTRY_UNAVAILABLE"
    sources: list[dict[str, Any]] = []
    for entry in entries:
        manifest_path = _resolve_manifest(root, str(entry["manifestPath"]))
        if manifest_path is None:
            return None, "H7_EXECUTION_ASSIST_CAPABILITY_REGISTRY_INVALID"
        try:
            manifest_stat = manifest_path.stat()
        except OSError:
            if entry["required"]:
                return None, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_UNAVAILABLE"
            continue
        source = _load_json(str(manifest_path), int(manifest_stat.st_mtime_ns), int(manifest_stat.st_size))
        if source is None or not _source_is_admissible(source, entry):
            return None, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_INVALID"
        digest = _file_sha256(str(manifest_path), int(manifest_stat.st_mtime_ns), int(manifest_stat.st_size))
        if not digest:
            return None, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_UNAVAILABLE"
        sources.append(
            {
                **source,
                "_capabilityNamespace": str(entry["capabilityNamespace"]),
                "_manifestSha256": digest,
                "_registrySha256": registry_digest,
            }
        )
    if not sources:
        return None, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_UNAVAILABLE"
    return sources, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_CURRENT"


def _native_contracts(source: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    contracts: dict[str, dict[str, Any]] = {}
    for item in source.get("nativeBehaviorContracts", []) or []:
        if not isinstance(item, Mapping):
            continue
        contract_id = _safe_text(item.get("id"), 160)
        if (
            contract_id is None
            or not _CONTRACT_ID.fullmatch(contract_id)
            or item.get("schema") != NATIVE_CONTRACT_SCHEMA
            or item.get("executionOwner") != "super-memory-brain"
            or item.get("sourceUse") != "provenance_cold_reference_only"
        ):
            continue
        contracts[contract_id] = dict(item)
    return contracts


def _valid_parity(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, Mapping) or value.get("schema") != NATIVE_PARITY_SCHEMA:
        return None
    procedure = _safe_text(value.get("procedureId"), 160)
    if procedure is None:
        return None
    for name in ("sourceOutcomes", "nativeOutcomes", "enhancements", "acceptance"):
        items = value.get(name)
        if not isinstance(items, list) or not items or len(items) > 12:
            return None
        if any(_safe_text(item, 240) is None for item in items):
            return None
    return dict(value)


def _candidate_records(source: Mapping[str, Any], signals: set[str]) -> list[dict[str, Any]]:
    contracts = _native_contracts(source)
    category_contracts = source.get("nativeBehaviorContractByCategory")
    category_contracts = category_contracts if isinstance(category_contracts, Mapping) else {}
    parity_by_skill = source.get("nativeParityBySkill")
    parity_by_skill = parity_by_skill if isinstance(parity_by_skill, Mapping) else {}
    manifest_digest = str(source.get("_manifestSha256", ""))
    registry_digest = str(source.get("_registrySha256", ""))
    namespace = str(source.get("_capabilityNamespace", ""))
    if not manifest_digest or not registry_digest or not _NAMESPACE.fullmatch(namespace):
        return []
    candidates: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for skill in source.get("skills", []) or []:
        if not isinstance(skill, Mapping):
            continue
        name = _safe_text(skill.get("name"), 120)
        if name is None:
            continue
        eligibility = str(skill.get("routeEligibility", "auto"))
        if eligibility != "auto":
            continue
        tags = {
            tag
            for tag in skill.get("semanticTags", []) or []
            if isinstance(tag, str) and tag in {
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
        }
        matches = tags.intersection(signals)
        if not matches:
            continue
        raw_apply_at = skill.get("applyAt")
        if not isinstance(raw_apply_at, list) or not raw_apply_at or len(raw_apply_at) > 3:
            continue
        apply_at: list[str] = []
        for value in raw_apply_at:
            phase = _safe_text(value, 24)
            if phase not in {"planning", "execution", "verification"} or phase in apply_at:
                apply_at = []
                break
            apply_at.append(phase)
        if not apply_at:
            continue
        native_contract_id = _safe_text(skill.get("nativeBehaviorContractId"), 160)
        if native_contract_id is None:
            native_contract_id = _safe_text(category_contracts.get(str(skill.get("category", ""))), 160)
        contract = contracts.get(native_contract_id or "")
        parity = _valid_parity(parity_by_skill.get(name))
        if contract is None or parity is None:
            continue
        capability_id = f"sb.native.{namespace}.{_slug(name)}.v1"
        if not _CAPABILITY_ID.fullmatch(capability_id) or capability_id in seen_ids:
            continue
        seen_ids.add(capability_id)
        provenance_hash = canonical_hash(
            {
                "registrySha256": registry_digest,
                "manifestSha256": manifest_digest,
                "sourceId": str(source.get("id", "")),
                "sourceRepo": str(source.get("sourceRepo", "")),
                "sourceCommit": str(source.get("sourceCommit", "")),
                "license": str(source.get("license", "")),
                "capabilityId": capability_id,
                "contractId": native_contract_id,
            }
        )
        parity_hash = canonical_hash(
            {
                "capabilityId": capability_id,
                "contractId": native_contract_id,
                "parity": parity,
            }
        )
        score = len(matches) * 100 + _NAME_PRIORITY.get(name, 0)
        if "challenge_assumptions" in signals and name == "grill-me":
            score += 10_000
        candidates.append(
            {
                "capabilityId": capability_id,
                "contractId": native_contract_id,
                "provenanceHash": provenance_hash,
                "parityHash": parity_hash,
                "score": score,
                "mutualExclusionGroup": _safe_text(skill.get("mutualExclusionGroup"), 80) or "",
                "applyAt": apply_at,
            }
        )
    return candidates


def route_capabilities(package_root: str | Path, signals: set[str]) -> tuple[dict[str, Any] | None, str]:
    """Merge admitted sources into one deterministic, native-only route."""

    sources, code = load_capability_sources(package_root)
    if sources is None:
        return None, code
    candidates: list[dict[str, Any]] = []
    for source in sources:
        candidates.extend(_candidate_records(source, signals))
    candidates.sort(key=lambda item: (-int(item["score"]), str(item["capabilityId"])))
    used_groups: set[str] = set()
    used_capabilities: set[str] = set()
    selected: list[dict[str, Any]] = []
    for candidate in candidates:
        capability_id = str(candidate["capabilityId"])
        group = str(candidate["mutualExclusionGroup"])
        if capability_id in used_capabilities or (group and group in used_groups):
            continue
        selected.append(candidate)
        used_capabilities.add(capability_id)
        if group:
            used_groups.add(group)
        if len(selected) == _MAX_SELECTED:
            break
    selected_ids = [str(item["capabilityId"]) for item in selected]
    contract_ids = list(dict.fromkeys(str(item["contractId"]) for item in selected))
    route = {
        "selectedNativeCapabilityIds": selected_ids,
        "nativeContractIds": contract_ids,
        "provenanceHashes": [
            {"capabilityId": str(item["capabilityId"]), "provenanceHash": str(item["provenanceHash"])}
            for item in selected
        ],
        "parityHashes": [
            {
                "capabilityId": str(item["capabilityId"]),
                "contractId": str(item["contractId"]),
                "parityHash": str(item["parityHash"]),
            }
            for item in selected
        ],
        "routeCards": selected,
    }
    # Evaluation is a separate activation gate.  It is intentionally checked
    # after deterministic source routing, so a stale/missing receipt cannot
    # change which capability would have been selected; it only prevents use.
    from capability_shadow_eval import evaluate_capability_shadow

    shadow_gate, shadow_code = evaluate_capability_shadow(package_root, route)
    route["shadowGate"] = shadow_gate
    if shadow_gate.get("state") != "ready":
        route["selectedNativeCapabilityIds"] = []
        route["nativeContractIds"] = []
        route["provenanceHashes"] = []
        route["parityHashes"] = []
        route["routeCards"] = []
        route["activationWithheld"] = True
        return route, shadow_code
    return route, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_CURRENT"


__all__ = ["REGISTRY_SCHEMA", "load_capability_sources", "route_capabilities"]
