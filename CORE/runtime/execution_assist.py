from __future__ import annotations

"""Bounded, privacy-safe execution assistance for Super Brain.

This module is the single hot-path implementation of the four-quadrant
protocol and absorbed native-capability selection.  It consumes only compact
semantic classifications supplied by the host or derived from a typed H7
intent.  It never receives, stores, returns, or hashes a raw user prompt,
conversation transcript, source path, or host identity.
"""

import hashlib
import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping


REQUEST_SCHEMA = "super-brain.execution-assist-request.v1"
RECEIPT_SCHEMA = "super-brain.execution-assist-receipt.v1"
CAPABILITY_ROUTE_SCHEMA = "super-brain.capability-route-receipt.v1"
CAPABILITY_APPLY_PRESENTATION_SCHEMA = "super-brain.capability-apply-presentation.v1"

CAPABILITY_ROUTE_FIELDS = {
    "schema",
    "state",
    "code",
    "selectedNativeCapabilityIds",
    "nativeContractIds",
    "provenanceHashes",
    "parityHashes",
    "routeHash",
    "nonAuthorizing",
    "rawPromptStored",
    "rawTranscriptStored",
    "sourcePathsOmitted",
}
RECEIPT_FIELDS = {
    "schema",
    "state",
    "code",
    "taskClass",
    "semanticSignals",
    "questionBudget",
    "clarificationRequired",
    "assumptionDisclosureRequired",
    "riskAndAlternativeReviewRequired",
    "minimalExperiment",
    "quadrants",
    "capabilityRouteReceipt",
    "capabilityApplyPresentation",
    "automatic",
    "nonAuthorizing",
    "rawPromptStored",
    "rawTranscriptStored",
    "sourcePathsOmitted",
    "payloadHash",
}

CAPABILITY_APPLY_PRESENTATION_FIELDS = {
    "schema",
    "state",
    "code",
    "applyPhase",
    "activeNativeCapabilityIds",
    "deferredNativeCapabilityIds",
    "nonAuthorizing",
    "rawPromptStored",
    "rawTranscriptStored",
    "sourcePathsOmitted",
    "payloadHash",
}

REQUEST_FIELDS = {
    "schema",
    "taskClass",
    "semanticSignals",
    "materialUnknown",
    "clarificationRequired",
    "sharedUnknown",
    "rawPromptStored",
    "rawTranscriptStored",
}

TASK_CLASSES = {"engineering", "product", "productivity", "learning", "general"}
APPLY_PHASES = {"planning", "execution", "verification"}
SEMANTIC_SIGNALS = {
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

_CAPABILITY_ID = re.compile(r"^[A-Za-z][A-Za-z0-9._:-]{1,159}$")
_CONTRACT_ID = re.compile(r"^sb\.native\.[a-z0-9][a-z0-9._-]{1,159}$")
_SHA256 = re.compile(r"^[a-f0-9]{64}$")
_SLUG = re.compile(r"[^a-z0-9]+")

_INTENT_DEFAULTS: dict[str, tuple[str, tuple[str, ...]]] = {
    "design_evaluate": ("engineering", ("engineering_design",)),
    "plan_proposal": ("product", ("product_planning",)),
    "super_brain_issue_continuity": ("productivity", ("productivity_workflow",)),
    "super_brain_issue_runtime": ("engineering", ("bug_diagnosis", "engineering_design")),
    "super_brain_issue_memory": ("engineering", ("bug_diagnosis",)),
    "super_brain_issue_ui": ("engineering", ("bug_diagnosis", "engineering_design")),
}

_INTENT_ASSIST_REQUIRED = frozenset(_INTENT_DEFAULTS)
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


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_text(value: Any, maximum: int = 80) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = " ".join(value.strip().split())
    return normalized if normalized and len(normalized) <= maximum else None


def _slug(value: str) -> str:
    return _SLUG.sub("-", value.lower()).strip("-") or "capability"


def _default_request(intent: Mapping[str, Any] | None) -> dict[str, Any]:
    kind = str((intent or {}).get("kind", "direct"))
    task_class, signals = _INTENT_DEFAULTS.get(kind, ("general", ()))
    return {
        "schema": REQUEST_SCHEMA,
        "taskClass": task_class,
        "semanticSignals": list(signals),
        "materialUnknown": False,
        "clarificationRequired": False,
        "sharedUnknown": False,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def normalize_request(value: Any, *, turn_intent: Mapping[str, Any] | None = None) -> tuple[dict[str, Any] | None, str]:
    """Validate a compact host classification without accepting user text."""

    if value is None:
        return _default_request(turn_intent), "H7_EXECUTION_ASSIST_DEFAULTED"
    if not isinstance(value, Mapping) or set(value) != REQUEST_FIELDS:
        return None, "H7_EXECUTION_ASSIST_REQUEST_FIELDS_INVALID"
    if value.get("schema") != REQUEST_SCHEMA:
        return None, "H7_EXECUTION_ASSIST_REQUEST_SCHEMA_INVALID"
    task_class = _safe_text(value.get("taskClass"), 32)
    if task_class not in TASK_CLASSES:
        return None, "H7_EXECUTION_ASSIST_TASK_CLASS_INVALID"
    raw_signals = value.get("semanticSignals")
    if not isinstance(raw_signals, list) or len(raw_signals) > 6:
        return None, "H7_EXECUTION_ASSIST_SIGNALS_INVALID"
    signals: list[str] = []
    for item in raw_signals:
        signal = _safe_text(item, 48)
        if signal not in SEMANTIC_SIGNALS or signal in signals:
            return None, "H7_EXECUTION_ASSIST_SIGNALS_INVALID"
        signals.append(signal)
    material_unknown = value.get("materialUnknown")
    clarification = value.get("clarificationRequired")
    shared_unknown = value.get("sharedUnknown")
    if not all(isinstance(item, bool) for item in (material_unknown, clarification, shared_unknown)):
        return None, "H7_EXECUTION_ASSIST_BOOLEAN_INVALID"
    if clarification and not material_unknown:
        return None, "H7_EXECUTION_ASSIST_CLARIFICATION_MATERIALITY_INVALID"
    if value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return None, "H7_EXECUTION_ASSIST_PRIVACY_INVALID"
    return {
        "schema": REQUEST_SCHEMA,
        "taskClass": task_class,
        "semanticSignals": signals,
        "materialUnknown": material_unknown,
        "clarificationRequired": clarification,
        "sharedUnknown": shared_unknown,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }, "H7_EXECUTION_ASSIST_REQUEST_CURRENT"


@lru_cache(maxsize=8)
def _load_extension(extension_path: str, modified_ns: int, size: int) -> dict[str, Any] | None:
    """Read one immutable package-owned capability source once per identity."""

    del modified_ns, size
    path = Path(extension_path)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or value.get("type") != "absorbed-capability-source":
        return None
    return value


def _extension_source(package_root: str | Path) -> tuple[dict[str, Any] | None, str]:
    path = Path(package_root).expanduser().resolve() / "extensions" / "mattpocock-skills" / "extension.json"
    try:
        stat = path.stat()
    except OSError:
        return None, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_UNAVAILABLE"
    source = _load_extension(str(path), int(stat.st_mtime_ns), int(stat.st_size))
    if source is None:
        return None, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_INVALID"
    if not all(_safe_text(source.get(key), 240) for key in ("id", "sourceRepo", "sourceCommit", "license")):
        return None, "H7_EXECUTION_ASSIST_PROVENANCE_INVALID"
    return source, "H7_EXECUTION_ASSIST_CAPABILITY_SOURCE_CURRENT"


def _native_contracts(source: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    contracts: dict[str, dict[str, Any]] = {}
    for item in source.get("nativeBehaviorContracts", []) or []:
        if not isinstance(item, Mapping):
            continue
        contract_id = _safe_text(item.get("id"), 160)
        if (
            contract_id is None
            or not _CONTRACT_ID.fullmatch(contract_id)
            or item.get("schema") != "super-brain.native-capability-contract.v1"
            or item.get("executionOwner") != "super-memory-brain"
            or item.get("sourceUse") != "provenance_cold_reference_only"
        ):
            continue
        contracts[contract_id] = dict(item)
    return contracts


def _candidate_records(source: Mapping[str, Any], signals: set[str]) -> list[dict[str, Any]]:
    contracts = _native_contracts(source)
    category_contracts = source.get("nativeBehaviorContractByCategory")
    category_contracts = category_contracts if isinstance(category_contracts, Mapping) else {}
    parity_by_skill = source.get("nativeParityBySkill")
    parity_by_skill = parity_by_skill if isinstance(parity_by_skill, Mapping) else {}
    extension_digest = _file_sha256(
        Path(source.get("_path"))
    ) if isinstance(source.get("_path"), str) else ""
    selected: list[dict[str, Any]] = []
    for skill in source.get("skills", []) or []:
        if not isinstance(skill, Mapping):
            continue
        name = _safe_text(skill.get("name"), 120)
        if not name:
            continue
        eligibility = str(skill.get("routeEligibility", "auto"))
        if eligibility in {"reference_only", "adapter_only"}:
            continue
        # ``explicit_only`` remains a cold/manual route.  The normal auto
        # route deliberately selects only skills declared safe for semantic
        # activation; this avoids expanding a user request into setup work.
        if eligibility == "explicit_only":
            continue
        tags = {
            tag for tag in skill.get("semanticTags", []) or []
            if isinstance(tag, str) and tag in SEMANTIC_SIGNALS
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
            if phase not in APPLY_PHASES or phase in apply_at:
                apply_at = []
                break
            apply_at.append(phase)
        if not apply_at:
            continue
        native_contract_id = _safe_text(skill.get("nativeBehaviorContractId"), 160)
        if not native_contract_id:
            native_contract_id = _safe_text(category_contracts.get(str(skill.get("category", ""))), 160)
        contract = contracts.get(native_contract_id or "")
        parity = parity_by_skill.get(name)
        if contract is None or not isinstance(parity, Mapping):
            continue
        procedure = _safe_text(parity.get("procedureId"), 160)
        if not procedure:
            continue
        capability_id = "sb.native.mattpocock." + _slug(name) + ".v1"
        if not _CAPABILITY_ID.fullmatch(capability_id):
            continue
        provenance_hash = canonical_hash(
            {
                "extensionSha256": extension_digest,
                "extensionId": str(source.get("id", "")),
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
        selected.append(
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
    return selected


def _route(source: Mapping[str, Any], signals: set[str]) -> dict[str, Any]:
    candidates = sorted(
        _candidate_records(source, signals),
        key=lambda item: (-int(item["score"]), str(item["capabilityId"])),
    )
    used_groups: set[str] = set()
    result: list[dict[str, Any]] = []
    for candidate in candidates:
        group = str(candidate["mutualExclusionGroup"])
        if group and group in used_groups:
            continue
        result.append(candidate)
        if group:
            used_groups.add(group)
        if len(result) == 4:
            break
    selected_ids = [str(item["capabilityId"]) for item in result]
    contract_ids = list(dict.fromkeys(str(item["contractId"]) for item in result))
    return {
        "selectedNativeCapabilityIds": selected_ids,
        "nativeContractIds": contract_ids,
        "provenanceHashes": [
            {"capabilityId": str(item["capabilityId"]), "provenanceHash": str(item["provenanceHash"])}
            for item in result
        ],
        "parityHashes": [
            {
                "capabilityId": str(item["capabilityId"]),
                "contractId": str(item["contractId"]),
                "parityHash": str(item["parityHash"]),
            }
            for item in result
        ],
        "routeCards": result,
    }


def _capability_route(route: Mapping[str, Any], *, withheld: bool = False) -> dict[str, Any]:
    selected = list(route.get("selectedNativeCapabilityIds", []) or []) if not withheld else []
    contracts = list(route.get("nativeContractIds", []) or []) if not withheld else []
    provenance = list(route.get("provenanceHashes", []) or []) if not withheld else []
    parity = list(route.get("parityHashes", []) or []) if not withheld else []
    state = "withheld" if withheld else ("ready" if selected else "not_applicable")
    code = {
        "ready": "CAPABILITY_ROUTE_READY",
        "not_applicable": "CAPABILITY_ROUTE_NOT_APPLICABLE",
        "withheld": "CAPABILITY_ROUTE_CLARIFICATION_REQUIRED",
    }[state]
    body = {
        "schema": CAPABILITY_ROUTE_SCHEMA,
        "state": state,
        "code": code,
        "selectedNativeCapabilityIds": selected,
        "nativeContractIds": contracts,
        "provenanceHashes": provenance,
        "parityHashes": parity,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
    }
    return {**body, "routeHash": canonical_hash(body)}


def _capability_apply_presentation(
    route: Mapping[str, Any], *, apply_phase: str, withheld: bool = False
) -> dict[str, Any]:
    """Project one H7-native route into the lifecycle phase that may use it.

    The projection is deliberately informational and non-authorizing.  It
    lets the controller use a selected native procedure at the correct phase
    without loading an upstream skill or turning a route into permission.
    """

    selected = list(route.get("selectedNativeCapabilityIds", []) or []) if not withheld else []
    cards = list(route.get("routeCards", []) or []) if not withheld else []
    apply_by_id = {
        str(card.get("capabilityId", "")): list(card.get("applyAt", []) or [])
        for card in cards
        if isinstance(card, Mapping)
    }
    active = [capability_id for capability_id in selected if apply_phase in apply_by_id.get(capability_id, [])]
    deferred = [capability_id for capability_id in selected if capability_id not in active]
    state = "withheld" if withheld else ("ready" if selected else "not_applicable")
    code = {
        "ready": "H7_CAPABILITY_APPLY_READY",
        "not_applicable": "H7_CAPABILITY_APPLY_NOT_APPLICABLE",
        "withheld": "H7_CAPABILITY_APPLY_WITHHELD",
    }[state]
    body = {
        "schema": CAPABILITY_APPLY_PRESENTATION_SCHEMA,
        "state": state,
        "code": code,
        "applyPhase": apply_phase,
        "activeNativeCapabilityIds": active,
        "deferredNativeCapabilityIds": deferred,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def _capability_apply_presentation_is_valid(value: Any, route: Mapping[str, Any]) -> bool:
    if not isinstance(value, Mapping) or set(value) != CAPABILITY_APPLY_PRESENTATION_FIELDS:
        return False
    state = value.get("state")
    expected_code = {
        "ready": "H7_CAPABILITY_APPLY_READY",
        "not_applicable": "H7_CAPABILITY_APPLY_NOT_APPLICABLE",
        "withheld": "H7_CAPABILITY_APPLY_WITHHELD",
    }.get(state)
    apply_phase = value.get("applyPhase")
    selected = list(route.get("selectedNativeCapabilityIds", []) or [])
    active = value.get("activeNativeCapabilityIds")
    deferred = value.get("deferredNativeCapabilityIds")
    if (
        value.get("schema") != CAPABILITY_APPLY_PRESENTATION_SCHEMA
        or value.get("code") != expected_code
        or apply_phase not in APPLY_PHASES
        or value.get("nonAuthorizing") is not True
        or value.get("rawPromptStored") is not False
        or value.get("rawTranscriptStored") is not False
        or value.get("sourcePathsOmitted") is not True
        or not isinstance(active, list)
        or not isinstance(deferred, list)
        or len(active) > 4
        or len(deferred) > 4
        or any(item not in selected for item in active + deferred)
        or len(set(active + deferred)) != len(active) + len(deferred)
        or set(active + deferred) != set(selected)
        or not isinstance(value.get("payloadHash"), str)
        or not _SHA256.fullmatch(str(value.get("payloadHash")))
    ):
        return False
    if (state == "ready") != bool(selected):
        return False
    return str(value.get("payloadHash")) == canonical_hash(
        {key: item for key, item in value.items() if key != "payloadHash"}
    )


def _capability_route_is_valid(value: Any) -> bool:
    """Verify the self-contained, source-path-free native route receipt."""

    if not isinstance(value, Mapping) or set(value) != CAPABILITY_ROUTE_FIELDS:
        return False
    state = value.get("state")
    expected_code = {
        "ready": "CAPABILITY_ROUTE_READY",
        "not_applicable": "CAPABILITY_ROUTE_NOT_APPLICABLE",
        "withheld": "CAPABILITY_ROUTE_CLARIFICATION_REQUIRED",
    }.get(state)
    if (
        value.get("schema") != CAPABILITY_ROUTE_SCHEMA
        or value.get("code") != expected_code
        or value.get("nonAuthorizing") is not True
        or value.get("rawPromptStored") is not False
        or value.get("rawTranscriptStored") is not False
        or value.get("sourcePathsOmitted") is not True
        or not isinstance(value.get("routeHash"), str)
        or not _SHA256.fullmatch(str(value.get("routeHash")))
    ):
        return False
    selected = value.get("selectedNativeCapabilityIds")
    contracts = value.get("nativeContractIds")
    provenance = value.get("provenanceHashes")
    parity = value.get("parityHashes")
    if not all(isinstance(item, list) and len(item) <= 4 for item in (selected, contracts, provenance, parity)):
        return False
    selected_ids = list(selected)
    contract_ids = list(contracts)
    if (
        len(set(selected_ids)) != len(selected_ids)
        or len(set(contract_ids)) != len(contract_ids)
        or any(not isinstance(item, str) or not _CAPABILITY_ID.fullmatch(item) for item in selected_ids)
        or any(not isinstance(item, str) or not _CONTRACT_ID.fullmatch(item) for item in contract_ids)
    ):
        return False
    if (state == "ready") != bool(selected_ids) or (state == "ready" and not contract_ids):
        return False
    if state != "ready" and (selected_ids or contract_ids or provenance or parity):
        return False
    expected_selected = set(selected_ids)
    seen_provenance: set[str] = set()
    for item in provenance:
        if (
            not isinstance(item, Mapping)
            or set(item) != {"capabilityId", "provenanceHash"}
            or item.get("capabilityId") not in expected_selected
            or not isinstance(item.get("provenanceHash"), str)
            or not _SHA256.fullmatch(str(item.get("provenanceHash")))
            or item["capabilityId"] in seen_provenance
        ):
            return False
        seen_provenance.add(str(item["capabilityId"]))
    seen_parity: set[str] = set()
    for item in parity:
        if (
            not isinstance(item, Mapping)
            or set(item) != {"capabilityId", "contractId", "parityHash"}
            or item.get("capabilityId") not in expected_selected
            or item.get("contractId") not in set(contract_ids)
            or not isinstance(item.get("parityHash"), str)
            or not _SHA256.fullmatch(str(item.get("parityHash")))
            or item["capabilityId"] in seen_parity
        ):
            return False
        seen_parity.add(str(item["capabilityId"]))
    return (
        seen_provenance == expected_selected
        and seen_parity == expected_selected
        and str(value.get("routeHash"))
        == canonical_hash({key: item for key, item in value.items() if key != "routeHash"})
    )


def receipt_is_valid(value: Any) -> bool:
    """Validate the compact H7-owned execution-assist receipt before reuse."""

    if not isinstance(value, Mapping) or set(value) != RECEIPT_FIELDS:
        return False
    state = value.get("state")
    expected_code = {
        "ready": "H7_EXECUTION_ASSIST_READY",
        "not_applicable": "H7_EXECUTION_ASSIST_NOT_APPLICABLE",
        "clarification_required": "H7_EXECUTION_ASSIST_CLARIFICATION_REQUIRED",
    }.get(state)
    signals = value.get("semanticSignals")
    experiment = value.get("minimalExperiment")
    if (
        value.get("schema") != RECEIPT_SCHEMA
        or value.get("code") != expected_code
        or value.get("taskClass") not in TASK_CLASSES
        or not isinstance(signals, list)
        or len(signals) > 6
        or signals != sorted(set(signals))
        or any(not isinstance(item, str) or item not in SEMANTIC_SIGNALS for item in signals)
        or not isinstance(value.get("questionBudget"), int)
        or value.get("automatic") is not True
        or value.get("nonAuthorizing") is not True
        or value.get("rawPromptStored") is not False
        or value.get("rawTranscriptStored") is not False
        or value.get("sourcePathsOmitted") is not True
        or not isinstance(value.get("payloadHash"), str)
        or not _SHA256.fullmatch(str(value.get("payloadHash")))
        or not isinstance(experiment, Mapping)
        or set(experiment) != {
            "required",
            "singleVariableRequired",
            "successSignalRequired",
            "failureSignalRequired",
            "evidenceRequired",
        }
        or not all(isinstance(item, bool) for item in experiment.values())
        or value.get("quadrants")
        != {
            "commonKnown": "reuse_confirmed_goal_context_acceptance_and_boundaries",
            "userKnownAgentUnknown": "ask_at_most_three_only_if_material_else_disclose_assumptions_and_proceed",
            "agentKnownUserUnknown": "surface_risks_alternatives_tradeoffs_and_faulty_premises",
            "sharedUnknown": "use_a_minimal_experiment_when_needed",
        }
        or not _capability_route_is_valid(value.get("capabilityRouteReceipt"))
        or not _capability_apply_presentation_is_valid(
            value.get("capabilityApplyPresentation"), value.get("capabilityRouteReceipt")
        )
    ):
        return False
    clarification = value.get("clarificationRequired") is True
    if value.get("questionBudget") != (3 if clarification else 0):
        return False
    if state == "clarification_required" and not clarification:
        return False
    if state != "clarification_required" and clarification:
        return False
    return str(value.get("payloadHash")) == canonical_hash(
        {key: item for key, item in value.items() if key != "payloadHash"}
    )


def resolve_execution_assist(
    package_root: str | Path,
    turn_intent: Mapping[str, Any] | None,
    request: Any = None,
    *,
    apply_phase: str = "planning",
) -> tuple[dict[str, Any] | None, str]:
    """Build one compact four-quadrant + native-route receipt.

    The caller's typed intent gives the default capability family.  A host may
    add a compact semantic classification for material uncertainty or a more
    specific native procedure, but cannot supply raw text or authorization.
    """

    if apply_phase not in APPLY_PHASES:
        return None, "H7_EXECUTION_ASSIST_APPLY_PHASE_INVALID"
    intent = turn_intent if isinstance(turn_intent, Mapping) else {}
    normalized, request_code = normalize_request(request, turn_intent=intent)
    if normalized is None:
        return None, request_code
    kind = str(intent.get("kind", "direct"))
    signals = set(normalized["semanticSignals"])
    nontrivial = (
        intent.get("executionAssistRequired") is True
        or kind in _INTENT_ASSIST_REQUIRED
        or bool(signals)
        or bool(normalized["materialUnknown"])
        or bool(normalized["sharedUnknown"])
    )
    if nontrivial:
        source, source_code = _extension_source(package_root)
        if source is None:
            return None, source_code
        source = {
            **source,
            "_path": str(
                Path(package_root).expanduser().resolve()
                / "extensions"
                / "mattpocock-skills"
                / "extension.json"
            ),
        }
        route = _route(source, signals)
    else:
        route = {
            "selectedNativeCapabilityIds": [],
            "nativeContractIds": [],
            "provenanceHashes": [],
            "parityHashes": [],
        }
    clarification_required = bool(normalized["clarificationRequired"])
    route_receipt = _capability_route(route, withheld=clarification_required)
    apply_presentation = _capability_apply_presentation(
        route, apply_phase=apply_phase, withheld=clarification_required
    )
    state = "clarification_required" if clarification_required else ("ready" if nontrivial else "not_applicable")
    code = {
        "ready": "H7_EXECUTION_ASSIST_READY",
        "not_applicable": "H7_EXECUTION_ASSIST_NOT_APPLICABLE",
        "clarification_required": "H7_EXECUTION_ASSIST_CLARIFICATION_REQUIRED",
    }[state]
    quadrants = {
        "commonKnown": "reuse_confirmed_goal_context_acceptance_and_boundaries",
        "userKnownAgentUnknown": "ask_at_most_three_only_if_material_else_disclose_assumptions_and_proceed",
        "agentKnownUserUnknown": "surface_risks_alternatives_tradeoffs_and_faulty_premises",
        "sharedUnknown": "use_a_minimal_experiment_when_needed",
    }
    body = {
        "schema": RECEIPT_SCHEMA,
        "state": state,
        "code": code,
        "taskClass": normalized["taskClass"],
        "semanticSignals": sorted(signals),
        "questionBudget": 3 if clarification_required else 0,
        "clarificationRequired": clarification_required,
        "assumptionDisclosureRequired": bool(nontrivial and not clarification_required),
        "riskAndAlternativeReviewRequired": bool(nontrivial),
        "minimalExperiment": {
            "required": bool(normalized["sharedUnknown"]),
            "singleVariableRequired": bool(normalized["sharedUnknown"]),
            "successSignalRequired": bool(normalized["sharedUnknown"]),
            "failureSignalRequired": bool(normalized["sharedUnknown"]),
            "evidenceRequired": bool(normalized["sharedUnknown"]),
        },
        "quadrants": quadrants,
        "capabilityRouteReceipt": route_receipt,
        "capabilityApplyPresentation": apply_presentation,
        "automatic": True,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
    }
    body["payloadHash"] = canonical_hash(body)
    return body, request_code


def public_projection(value: Mapping[str, Any] | None) -> dict[str, Any]:
    """Expose only the compact, non-secret operating contract."""

    receipt = value if receipt_is_valid(value) else {}
    route = receipt.get("capabilityRouteReceipt") if isinstance(receipt.get("capabilityRouteReceipt"), Mapping) else {}
    presentation = (
        receipt.get("capabilityApplyPresentation")
        if isinstance(receipt.get("capabilityApplyPresentation"), Mapping)
        else {}
    )
    return {
        "state": str(receipt.get("state", "withheld")),
        "code": str(receipt.get("code", "H7_EXECUTION_ASSIST_UNAVAILABLE")),
        "taskClass": str(receipt.get("taskClass", "")),
        "semanticSignals": list(receipt.get("semanticSignals", []) or [])[:6],
        "questionBudget": int(receipt.get("questionBudget", 0) or 0),
        "clarificationRequired": receipt.get("clarificationRequired") is True,
        "assumptionDisclosureRequired": receipt.get("assumptionDisclosureRequired") is True,
        "riskAndAlternativeReviewRequired": receipt.get("riskAndAlternativeReviewRequired") is True,
        "minimalExperiment": receipt.get("minimalExperiment") if isinstance(receipt.get("minimalExperiment"), Mapping) else {},
        "quadrants": receipt.get("quadrants") if isinstance(receipt.get("quadrants"), Mapping) else {},
        "selectedNativeCapabilityIds": list(route.get("selectedNativeCapabilityIds", []) or [])[:4],
        "nativeContractIds": list(route.get("nativeContractIds", []) or [])[:4],
        "routeHash": str(route.get("routeHash", "")),
        "capabilityApplyPhase": str(presentation.get("applyPhase", "")),
        "activeNativeCapabilityIds": list(presentation.get("activeNativeCapabilityIds", []) or [])[:4],
        "deferredNativeCapabilityIds": list(presentation.get("deferredNativeCapabilityIds", []) or [])[:4],
        "capabilityApplyPresentationHash": str(presentation.get("payloadHash", "")),
        "payloadHash": str(receipt.get("payloadHash", "")),
        "automatic": receipt.get("automatic") is True,
        "nonAuthorizing": receipt.get("nonAuthorizing") is True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": receipt.get("sourcePathsOmitted") is True,
    }


def capability_route_receipt(value: Mapping[str, Any] | None) -> dict[str, Any] | None:
    receipt = value if isinstance(value, Mapping) else {}
    route = receipt.get("capabilityRouteReceipt")
    return dict(route) if isinstance(route, Mapping) else None


__all__ = [
    "CAPABILITY_ROUTE_SCHEMA",
    "CAPABILITY_APPLY_PRESENTATION_SCHEMA",
    "RECEIPT_SCHEMA",
    "REQUEST_SCHEMA",
    "canonical_hash",
    "capability_route_receipt",
    "normalize_request",
    "public_projection",
    "receipt_is_valid",
    "resolve_execution_assist",
]
