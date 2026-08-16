from __future__ import annotations

"""Read-only, content-addressed Super Brain execution-rule registry.

The registry is deliberately separate from long-term memory.  It contains
stable execution invariants only; callers receive a bounded applicability
projection and never persist the source signal used to select it.
"""

import hashlib
import json
import re
from pathlib import Path
from typing import Any, Iterable, Mapping


REGISTRY_SCHEMA = "super-brain.core-rule-registry.v1"
REGISTRY_HASH_ALGORITHM = "sha256(canonical-json-without-payloadHash)"
REGISTRY_RELATIVE_PATH = "super-brain-rules.json"
REGISTRY_REQUIRED_FIELDS = {
    "schema", "registryVersion", "packageVersion", "hashAlgorithm", "payloadHash", "rules",
}
RULE_REQUIRED_FIELDS = {
    "ruleId", "revision", "priority", "scope", "trigger", "effect",
    "enforcement", "entrypoint", "acceptanceTests", "status", "supersedes",
}
MANIFEST_REQUIRED_FIELDS = {"path", "schema", "hashAlgorithm", "requiredRuleIds"}
REQUIRED_RULE_IDS = (
    "SB-PROJECT-GROUNDED-DESIGN-001",
    "SB-DEFECT-ROOT-REPAIR-001",
    "SB-RULE-MEMORY-SPLIT-001",
    "SB-UNIFIED-SHARED-MEMORY-001",
    "SB-ABILITY-ABSORPTION-001",
    "SB-FOUR-QUADRANT-EXECUTION-001",
    "SB-CONCURRENT-STATE-CAS-001",
    "SB-TEMPORARY-TASK-CARD-LIFECYCLE-001",
    "SB-LATEST-STATE-001",
    "SB-VISIBLE-PROGRESS-ANCHOR-001",
    "SB-PROGRESS-TRUTH-001",
    "SB-PROPOSAL-GATE-001",
    "SB-AUTO-RESUME-001",
    "SB-STAGE-VERIFY-001",
    "SB-STAGE-USER-RECEIPT-001",
    "SB-EFFICIENT-DELIVERY-001",
    "SB-NO-REPEAT-FAILED-ROUTE-001",
    "SB-CHILD-LIFECYCLE-001",
    "SB-H7-ACTIVATION-001",
    "SB-INDEPENDENT-CONTROL-PLANE-AGENT-001",
    "SB-RUNTIME-ADAPTER-INDEPENDENCE-001",
    "SB-PRIMARY-HOST-ENTRY-001",
    "SB-ADAPTER-CONCISENESS-001",
    "SB-BOOTSTRAP-SINGLE-SOURCE-001",
    "SB-CONTROL-PLANE-MAINTAINABILITY-001",
    "SB-DIRECT-GIT-SOURCE-001",
    "SB-ON-DEMAND-PROJECT-KNOWLEDGE-001",
)

_RULE_ID = re.compile(r"^SB-[A-Z0-9-]+-[0-9]{3}$")
_IDENTIFIER = re.compile(r"^[a-z][a-z0-9_]*$")
_HASH = re.compile(r"^[0-9a-f]{64}$")


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
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _bounded_public(result: Mapping[str, Any] | None, *, signals: Iterable[Any] = ()) -> dict[str, Any]:
    value = result if isinstance(result, Mapping) else {}
    rules = value.get("rules") if isinstance(value.get("rules"), list) else []
    signal_set = {
        str(item).strip().lower()
        for item in signals
        if isinstance(item, (str, int, float)) and str(item).strip()
    }
    applicable = [
        rule for rule in rules
        if isinstance(rule, Mapping)
        and signal_set.intersection(
            str(trigger).strip().lower()
            for trigger in rule.get("trigger", [])
            if isinstance(trigger, str)
        )
    ]
    active_ids = [str(rule.get("ruleId", "")) for rule in rules if isinstance(rule, Mapping) and rule.get("ruleId")]
    applicable_ids = [str(rule.get("ruleId", "")) for rule in applicable if rule.get("ruleId")]
    effects = [
        {
            "ruleId": str(rule.get("ruleId", "")),
            "revision": int(rule.get("revision", 0) or 0),
            "priority": int(rule.get("priority", 0) or 0),
            "scope": str(rule.get("scope", "")),
            "effect": str(rule.get("effect", "")),
            "enforcement": str(rule.get("enforcement", "")),
        }
        for rule in rules
        if isinstance(rule, Mapping)
    ]
    applicable_effects = [effect for effect in effects if effect["ruleId"] in set(applicable_ids)]
    return {
        "status": str(value.get("status", "withheld")),
        "code": str(value.get("code", "CORE_RULE_REGISTRY_UNAVAILABLE")),
        "schema": str(value.get("schema", REGISTRY_SCHEMA)),
        "registryVersion": int(value.get("registryVersion", 0) or 0),
        "packageVersion": str(value.get("packageVersion", "")),
        "hashAlgorithm": str(value.get("hashAlgorithm", REGISTRY_HASH_ALGORITHM)),
        "payloadHash": str(value.get("payloadHash", "")),
        "fileSha256": str(value.get("fileSha256", "")),
        "activeEffectsHash": str(value.get("activeEffectsHash", canonical_hash(effects) if effects else "")),
        "activeRuleCount": len(active_ids) if value.get("status") == "current" else 0,
        "applicableRuleIds": applicable_ids if value.get("status") == "current" else [],
        "applicableEffectsHash": canonical_hash(applicable_effects) if applicable_effects else "",
        "signalStored": False,
    }


def _withheld(code: str, **extra: Any) -> dict[str, Any]:
    result: dict[str, Any] = {"status": "withheld", "code": code}
    result.update(extra)
    return result


def _is_bounded_int(value: Any, minimum: int, maximum: int) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and minimum <= value <= maximum


def _clean_string_list(value: Any, *, allow_empty: bool = False) -> list[str] | None:
    if not isinstance(value, list):
        return None
    items = [item for item in value if isinstance(item, str) and item.strip()]
    if len(items) != len(value) or len(set(items)) != len(items) or (not allow_empty and not items):
        return None
    return items


def _manifest_error(manifest: Mapping[str, Any], package_version: str, rule_ids: set[str]) -> str | None:
    declared = manifest.get("coreRuleRegistry")
    if not isinstance(declared, Mapping) or set(declared) != MANIFEST_REQUIRED_FIELDS:
        return "CORE_RULE_REGISTRY_MANIFEST_DECLARATION_INVALID"
    if str(declared.get("path", "")).replace("\\", "/") != REGISTRY_RELATIVE_PATH:
        return "CORE_RULE_REGISTRY_MANIFEST_PATH_MISMATCH"
    if declared.get("schema") != REGISTRY_SCHEMA:
        return "CORE_RULE_REGISTRY_MANIFEST_SCHEMA_MISMATCH"
    if declared.get("hashAlgorithm") != REGISTRY_HASH_ALGORITHM:
        return "CORE_RULE_REGISTRY_MANIFEST_HASH_ALGORITHM_MISMATCH"
    declared_ids = _clean_string_list(declared.get("requiredRuleIds"))
    if declared_ids is None or set(declared_ids) != set(REQUIRED_RULE_IDS):
        return "CORE_RULE_REGISTRY_MANIFEST_REQUIRED_IDS_INVALID"
    if not isinstance(manifest.get("version"), str) or str(manifest.get("version", "")) != package_version:
        return "CORE_RULE_REGISTRY_PACKAGE_VERSION_MISMATCH"
    if not set(REQUIRED_RULE_IDS).issubset(rule_ids):
        return "CORE_RULE_REGISTRY_MANIFEST_RULES_UNAVAILABLE"
    return None


def _rule_error(rule: Any, seen_ids: set[str]) -> str | None:
    if not isinstance(rule, Mapping) or set(rule) != RULE_REQUIRED_FIELDS:
        return "CORE_RULE_REGISTRY_RULE_FIELDS_INVALID"
    rule_id = rule.get("ruleId")
    if not isinstance(rule_id, str) or not _RULE_ID.fullmatch(rule_id) or rule_id in seen_ids:
        return "CORE_RULE_REGISTRY_RULE_ID_INVALID"
    if not _is_bounded_int(rule.get("revision"), 1, 1_000_000):
        return "CORE_RULE_REGISTRY_RULE_REVISION_INVALID"
    if not _is_bounded_int(rule.get("priority"), 0, 1_000):
        return "CORE_RULE_REGISTRY_RULE_PRIORITY_INVALID"
    if rule.get("scope") not in {"global", "runtime"}:
        return "CORE_RULE_REGISTRY_RULE_SCOPE_INVALID"
    if rule.get("enforcement") not in {"runtime", "host_policy"}:
        return "CORE_RULE_REGISTRY_ENFORCEMENT_INVALID"
    if rule.get("status") not in {"active", "superseded", "retired"}:
        return "CORE_RULE_REGISTRY_RULE_STATUS_INVALID"
    trigger = _clean_string_list(rule.get("trigger"))
    acceptance = _clean_string_list(rule.get("acceptanceTests"))
    supersedes = _clean_string_list(rule.get("supersedes"), allow_empty=True)
    if trigger is None or acceptance is None or supersedes is None:
        return "CORE_RULE_REGISTRY_RULE_LIST_INVALID"
    if not all(_IDENTIFIER.fullmatch(item) for item in trigger + acceptance):
        return "CORE_RULE_REGISTRY_RULE_IDENTIFIER_INVALID"
    if not isinstance(rule.get("effect"), str) or not _IDENTIFIER.fullmatch(str(rule.get("effect", ""))):
        return "CORE_RULE_REGISTRY_RULE_EFFECT_INVALID"
    entrypoint = rule.get("entrypoint")
    normalized = str(entrypoint or "").replace("\\", "/")
    if not isinstance(entrypoint, str) or not normalized or normalized.startswith("/") or ".." in normalized.split("/"):
        return "CORE_RULE_REGISTRY_RULE_ENTRYPOINT_INVALID"
    return None


def load_registry(package_root: str | Path, *, manifest: Mapping[str, Any] | None = None) -> dict[str, Any]:
    package = Path(package_root).expanduser().resolve()
    path = package / REGISTRY_RELATIVE_PATH
    try:
        raw = path.read_bytes()
    except OSError:
        return _withheld("CORE_RULE_REGISTRY_MISSING")
    if raw.startswith(b"\xef\xbb\xbf"):
        return _withheld("CORE_RULE_REGISTRY_BOM_FORBIDDEN")
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return _withheld("CORE_RULE_REGISTRY_UTF8_INVALID")
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return _withheld("CORE_RULE_REGISTRY_JSON_INVALID")
    if not isinstance(value, dict) or set(value) != REGISTRY_REQUIRED_FIELDS:
        return _withheld("CORE_RULE_REGISTRY_ROOT_INVALID")
    if value.get("schema") != REGISTRY_SCHEMA:
        return _withheld("CORE_RULE_REGISTRY_SCHEMA_INVALID")
    if value.get("hashAlgorithm") != REGISTRY_HASH_ALGORITHM:
        return _withheld("CORE_RULE_REGISTRY_HASH_ALGORITHM_INVALID")
    if not _is_bounded_int(value.get("registryVersion"), 1, 1_000_000):
        return _withheld("CORE_RULE_REGISTRY_VERSION_INVALID")
    package_version = value.get("packageVersion")
    if not isinstance(package_version, str) or not package_version.strip():
        return _withheld("CORE_RULE_REGISTRY_PACKAGE_VERSION_INVALID")
    declared_hash = value.get("payloadHash")
    if not isinstance(declared_hash, str) or not _HASH.fullmatch(declared_hash):
        return _withheld("CORE_RULE_REGISTRY_PAYLOAD_HASH_INVALID")
    rules = value.get("rules")
    if not isinstance(rules, list) or not rules:
        return _withheld("CORE_RULE_REGISTRY_RULES_INVALID")
    seen_ids: set[str] = set()
    for rule in rules:
        error = _rule_error(rule, seen_ids)
        if error:
            return _withheld(error)
        seen_ids.add(str(rule["ruleId"]))
    missing = [rule_id for rule_id in REQUIRED_RULE_IDS if rule_id not in seen_ids]
    if missing:
        return _withheld("CORE_RULE_REGISTRY_REQUIRED_RULE_MISSING", missingRuleIds=missing)
    if any(
        not isinstance(rule, Mapping) or rule.get("status") != "active"
        for rule in rules if str(rule.get("ruleId", "")) in REQUIRED_RULE_IDS
    ):
        return _withheld("CORE_RULE_REGISTRY_REQUIRED_RULE_INACTIVE")
    body = {key: item for key, item in value.items() if key != "payloadHash"}
    expected = canonical_hash(body)
    if declared_hash != expected:
        return _withheld("CORE_RULE_REGISTRY_HASH_MISMATCH", payloadHash=declared_hash)
    if manifest is not None:
        if not isinstance(manifest, Mapping):
            return _withheld("CORE_RULE_REGISTRY_MANIFEST_INVALID")
        manifest_error = _manifest_error(manifest, package_version, seen_ids)
        if manifest_error:
            return _withheld(manifest_error)
    active = [dict(rule) for rule in rules if isinstance(rule, Mapping) and rule.get("status") == "active"]
    effects = [
        {
            "ruleId": str(rule["ruleId"]),
            "revision": int(rule["revision"]),
            "priority": int(rule["priority"]),
            "scope": str(rule["scope"]),
            "effect": str(rule["effect"]),
            "enforcement": str(rule["enforcement"]),
        }
        for rule in active
    ]
    return {
        "status": "current",
        "code": "CORE_RULE_REGISTRY_CURRENT",
        "schema": REGISTRY_SCHEMA,
        "registryVersion": int(value["registryVersion"]),
        "packageVersion": package_version,
        "hashAlgorithm": REGISTRY_HASH_ALGORITHM,
        "payloadHash": expected,
        "fileSha256": file_sha256(path),
        "activeEffectsHash": canonical_hash(effects),
        "rules": active,
    }


def public_projection(result: Mapping[str, Any] | None, *, signals: Iterable[Any] = ()) -> dict[str, Any]:
    """Return public, non-memory applicability metadata for supplied intent signals."""

    return _bounded_public(result, signals=signals)


__all__ = [
    "REGISTRY_HASH_ALGORITHM", "REGISTRY_RELATIVE_PATH", "REGISTRY_SCHEMA", "REQUIRED_RULE_IDS",
    "canonical_hash", "file_sha256", "load_registry", "public_projection",
]
