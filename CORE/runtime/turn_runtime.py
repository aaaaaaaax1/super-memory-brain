"""Authoritative no-Hook Super Brain turn lifecycle.

This module is deliberately the only write-side entry point for the normal
MCP/CLI turn lifecycle.  It composes the existing execution contract,
typed-memory context, activation receipt, and continuation dispatcher without
introducing a worker, a second state store, or prompt persistence.
"""

from __future__ import annotations

import errno
import hashlib
import json
import math
import os
import re
import tempfile
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from activation_receipt import canonical_hash, ensure_current
from brain_context import canonical_hash as context_hash
from brain_core import (
    MCP_RUNTIME_MODE_OFFLINE_REPLAY,
    TURN_RUNTIME_CONTEXT_SNAPSHOT_KEY,
    TURN_RUNTIME_CONTEXT_SNAPSHOT_SCHEMA,
    BrainCore,
    agent_identity,
)
from capability_shadow_eval import shadow_gate_is_valid
from continuation_policy import decide_turn_close
from execution_assist import capability_route_receipt as execution_assist_capability_route_receipt
from execution_assist import public_projection as public_execution_assist
from execution_assist import project_knowledge_route_is_valid
from execution_assist import receipt_is_valid as execution_assist_receipt_is_valid
from execution_assist import resolve_execution_assist
from failure_loop_guard import evaluate_failure_loop
from failure_loop_guard import receipt_is_valid as failure_loop_receipt_is_valid
from project_knowledge import public_projection as public_project_knowledge
from project_knowledge import receipt_is_valid as project_knowledge_receipt_is_valid
from project_knowledge import resolve_project_knowledge
from run_observability import receipt_is_valid as run_observability_receipt_is_valid
from run_observability import summarize_telemetry as summarize_run_observability
from turn_close_dispatcher import (
    _invoke_contract,
    create_phase_closeout,
    dispatch_turn_close,
    is_formal_phase,
    record_progress_checkpoint,
)
from turn_intent import public_projection as public_turn_intent
from turn_intent import resolve_turn_intent


SCHEMA = "super-brain.turn-runtime.v1"
RECEIPT_SCHEMA = "super-brain.turn-runtime-receipt.v1"
TELEMETRY_SCHEMA = "super-brain.turn-runtime-telemetry.v1"
MODE = "hookless_turn_runtime"
MAX_TELEMETRY_EVENTS = 16
MAX_FAILURE_LOOP_HISTORY = 256
MAX_FAILURE_LOOP_RESERVATIONS = 32
FAILURE_LOOP_LOCK_TIMEOUT_SECONDS = 2.0
FAILURE_LOOP_RESERVATION_TTL_SECONDS = 120.0
FAILURE_LOOP_RESERVATION_TIMEOUT_MULTIPLIER = 4.0
FAILURE_LOOP_RESERVATION_GRACE_SECONDS = 30.0
MAX_REFERENCE_CHARS = 240
CAPABILITY_ROUTE_RECEIPT_SCHEMA = "super-brain.capability-route-receipt.v1"
CAPABILITY_ROUTE_RECEIPT_FIELDS = {
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
    "shadowGate",
}
CAPABILITY_ROUTE_STATES = {"ready", "not_applicable", "withheld"}
CAPABILITY_ROUTE_CODE_RE = re.compile(r"^CAPABILITY_ROUTE_[A-Z0-9_]{3,96}$")
CAPABILITY_NATIVE_ID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._:-]{1,159}$")
CAPABILITY_NATIVE_CONTRACT_ID_RE = re.compile(r"^sb\.native\.[a-z0-9][a-z0-9._-]{1,159}$")
CAPABILITY_SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
CAPABILITY_ROUTE_COMPATIBILITY_SCHEMA = "super-brain.capability-route-compatibility.v1"
CAPABILITY_ROUTE_COMPATIBILITY_FIELDS = {
    "schema",
    "state",
    "externalRouteHash",
    "externalSelectionHash",
    "nonAuthorizing",
    "cannotSelectCapabilities",
    "rawPromptStored",
    "rawTranscriptStored",
    "payloadHash",
}
RECOVERY_PRESENTATION_SCHEMA = "super-brain.recovery-presentation.v3"
RECOVERY_EVENTS = {
    "none",
    "compaction",
    "restart",
    "model_switch",
    "cross_session",
    "pause_resume",
    "user_correction",
    "parent_return",
}

# A close/checkpoint call may perform several internal ``open_turn`` reads.
# Reuse is intentionally call-local and receipt-validated; no process/global
# cache is allowed to become a continuation authority.
ExecutionAssistBundle = tuple[dict[str, Any], dict[str, Any], dict[str, Any] | None, str]

NORMAL_CONTINUITY_INTENTS = {
    "task_status",
    "continuity",
    "user_correction",
}

FORMAL_OPEN_INTENTS = {
    "design_evaluate",
    "plan_proposal",
    "memory_write",
}
# A normal continuation is read-only and must not spawn a second authority
# process.  Persisted memory/task-card mutations, however, must project the
# exact action authorization returned by execution-contract.ps1.
ACTION_AUTHORIZATION_REQUIRED_INTENTS = {"memory_write"}


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _utc_after(seconds: float) -> str:
    try:
        requested = max(0.0, float(seconds))
        if not math.isfinite(requested):
            requested = float("inf")
        target = datetime.now(timezone.utc) + timedelta(seconds=requested)
    except (TypeError, ValueError, OverflowError):
        # A malformed or unbounded caller timeout must not crash the guarded
        # side-effect path.  Saturate at the representable UTC ceiling; this
        # keeps the reservation live until explicit reconciliation rather than
        # accidentally expiring it early.
        target = datetime.max.replace(tzinfo=timezone.utc)
    return target.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_utc_timestamp(value: Any) -> datetime | None:
    """Accept the compact UTC timestamps written by this runtime only."""

    if not isinstance(value, str) or not value or not value.endswith("Z"):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError, OverflowError):
        return None
    return parsed.astimezone(timezone.utc) if parsed.tzinfo is not None else None


def _reservation_ttl_for_timeout(value: Any = None) -> float:
    """Keep a retry reservation live for the full bounded side-effect window."""

    try:
        requested = float(value)
    except (TypeError, ValueError, OverflowError):
        return FAILURE_LOOP_RESERVATION_TTL_SECONDS
    if not math.isfinite(requested) or requested <= 0:
        return FAILURE_LOOP_RESERVATION_TTL_SECONDS
    # A close may perform more than one authority transaction; retain the
    # reservation across that bounded sequence plus a small scheduling margin.
    return max(
        FAILURE_LOOP_RESERVATION_TTL_SECONDS,
        requested * FAILURE_LOOP_RESERVATION_TIMEOUT_MULTIPLIER
        + FAILURE_LOOP_RESERVATION_GRACE_SECONDS,
    )


def _compact(value: Any, maximum: int = MAX_REFERENCE_CHARS) -> str:
    text = " ".join(str(value or "").split())
    if len(text) <= maximum:
        return text
    return text[: maximum - 3].rstrip() + "..."


def _strict_text(value: Any, *, maximum: int, pattern: re.Pattern[str]) -> str | None:
    """Accept only compact, path-free identifiers supplied by a route receipt."""

    if not isinstance(value, str) or not value or len(value) > maximum or value != value.strip():
        return None
    return value if pattern.fullmatch(value) else None


def _strict_hash(value: Any) -> str | None:
    return _strict_text(value, maximum=64, pattern=CAPABILITY_SHA256_RE)


def _parent_return_state_card(
    context: dict[str, Any],
    contract: dict[str, Any],
) -> tuple[dict[str, Any] | None, str]:
    """Select a different approved workline only from the H7 state card.

    Parent return is the sole continuation case that intentionally leaves the
    current visible assistant tail: that tail belongs to the completed child
    line.  The post-``ResumeParent`` contract/state card is therefore the
    bounded selector for the already-approved parent, never a general
    substitute for same-workline visible context.
    """

    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    state_card = contract.get("continuityStateCard") if isinstance(contract.get("continuityStateCard"), dict) else {}
    transition = contract.get("lastTransition") if isinstance(contract.get("lastTransition"), dict) else {}
    visible = task.get("visibleProgress") if isinstance(task.get("visibleProgress"), dict) else {}
    sentence = str(task.get("lastConfirmedSentence", ""))
    source = str(task.get("lastConfirmedSource", ""))
    if (
        str(transition.get("action", "")) != "ResumeParent"
        or not state_card
        or str(state_card.get("activeLineId", "")) != str(contract.get("focusId", ""))
        or str(state_card.get("phase", "")) != str(task.get("currentPhase", ""))
        or str(state_card.get("currentStep", "")) != str(task.get("currentStep", ""))
        or str(state_card.get("nextAction", "")) != str(task.get("nextAction", ""))
        or str(state_card.get("lastConfirmedSentence", "")) != sentence
        or str(state_card.get("lastConfirmedSource", "")) != source
        or source != "assistant_visible_reply"
        or visible.get("state") != "current"
        or visible.get("continuationEligible") is not True
        or not sentence
    ):
        return None, "H7_PARENT_RETURN_STATE_CARD_REQUIRED"
    body = {
        "state": "current",
        "code": "H7_PARENT_RETURN_STATE_CARD_CURRENT",
        "lastConfirmedSentence": sentence,
        "source": source,
        "currentPhase": str(task.get("currentPhase", "")),
        "currentStep": str(task.get("currentStep", "")),
        "nextAction": str(task.get("nextAction", "")),
        "stateCardHash": canonical_hash(
            {
                "activeLineId": str(state_card.get("activeLineId", "")),
                "phase": str(state_card.get("phase", "")),
                "currentStep": str(state_card.get("currentStep", "")),
                "nextAction": str(state_card.get("nextAction", "")),
                "lastConfirmedSentence": str(state_card.get("lastConfirmedSentence", "")),
                "lastConfirmedSource": str(state_card.get("lastConfirmedSource", "")),
            }
        ),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    body["payloadHash"] = canonical_hash(body)
    return body, "H7_PARENT_RETURN_STATE_CARD_CURRENT"


def _recovery_presentation(
    recovery_event: str,
    parent_return_state_card: dict[str, Any] | None = None,
    continuity_mapping: dict[str, Any] | None = None,
) -> tuple[dict[str, Any] | None, str]:
    """Build one compact event-bound projection from local state only."""

    if recovery_event not in RECOVERY_EVENTS:
        return None, "H7_RECOVERY_EVENT_INVALID"
    if recovery_event == "none":
        body: dict[str, Any] = {
            "schema": RECOVERY_PRESENTATION_SCHEMA,
            "state": "not_applicable",
            "code": "H7_RECOVERY_PRESENTATION_SUPPRESSED",
            "event": recovery_event,
            "required": False,
            "openingLine": "",
            "presentationKind": "suppressed",
            "localOnly": True,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return {**body, "payloadHash": canonical_hash(body)}, "H7_RECOVERY_PRESENTATION_SUPPRESSED"
    if recovery_event == "parent_return":
        card = parent_return_state_card if isinstance(parent_return_state_card, dict) else {}
        if str(card.get("state", "")) != "current":
            return None, "H7_PARENT_RETURN_STATE_CARD_REQUIRED"
        source = str(card.get("source", ""))
        phase = str(card.get("currentPhase", ""))
        step = str(card.get("currentStep", ""))
        action = str(card.get("nextAction", ""))
        mapped = card
    else:
        mapped = continuity_mapping if isinstance(continuity_mapping, dict) else {}
        if (
            str(mapped.get("state", "")) != "local_contract_current"
            or str(mapped.get("source", "")) != "scoped_local_contract"
            or mapped.get("visibleContextAvailable") is not False
            or mapped.get("stateCardUsed") is not False
        ):
            return None, "H7_LOCAL_CONTRACT_RECOVERY_REQUIRED"
        source = "scoped_local_contract"
        phase = str(mapped.get("currentPhase", ""))
        step = str(mapped.get("currentStep", ""))
        action = str(mapped.get("nextAction", ""))
    phase = str(mapped.get("currentPhase") or phase)
    step = str(mapped.get("currentStep") or step)
    action = str(mapped.get("nextAction") or action)
    if not phase or not step or not action:
        return None, "H7_RECOVERY_MAPPED_PROGRESS_REQUIRED"
    presentation_line = "\u672c\u5730\u6267\u884c\u5951\u7ea6\uff1a\u8fdb\u5ea6\uff1a{}\uff5c\u5f53\u524d\uff1a{}\uff5c\u4e0b\u4e00\u6b65\uff1a{}".format(
        phase,
        step,
        action,
    )
    body = {
        "schema": RECOVERY_PRESENTATION_SCHEMA,
        "state": "current",
        "code": "H7_LOCAL_RECOVERY_PRESENTATION_CURRENT",
        "event": recovery_event,
        "required": True,
        "openingLine": presentation_line,
        "presentationKind": "local_contract_projection",
        "source": source,
        "currentPhase": phase,
        "currentStep": step,
        "nextAction": action,
        "nonAuthorizing": True,
        "localOnly": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}, "H7_LOCAL_RECOVERY_PRESENTATION_CURRENT"


def _public_recovery_presentation(value: dict[str, Any] | None) -> dict[str, Any]:
    presentation = value if isinstance(value, dict) else {}
    opening_line = str(presentation.get("openingLine", ""))
    return {
        "schema": RECOVERY_PRESENTATION_SCHEMA,
        "state": str(presentation.get("state", "withheld")),
        "code": str(presentation.get("code", "H7_RECOVERY_PRESENTATION_WITHHELD")),
        "event": str(presentation.get("event", "")),
        "required": bool(presentation.get("required") is True),
        "nonAuthorizing": bool(presentation.get("nonAuthorizing") is True),
        "localOnly": bool(presentation.get("localOnly") is True),
        "presentationKind": str(presentation.get("presentationKind", "")),
        "openingLineHash": hashlib.sha256(opening_line.encode("utf-8")).hexdigest() if opening_line else "",
        "payloadHash": str(presentation.get("payloadHash", "")),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _progress_checkpoint_intent_guard(progress_checkpoint: Any, intent: dict[str, Any]) -> str:
    source = str(progress_checkpoint.get("source", "")) if isinstance(progress_checkpoint, dict) else ""
    if source == "user_attested_visible_reply" and str(intent.get("kind", "")) not in {
        "user_correction",
        "super_brain_issue_continuity",
    }:
        return "H7_USER_ATTESTED_VISIBLE_PROGRESS_INTENT_REQUIRED"
    return ""


def _normalize_capability_hashes(
    value: Any,
    *,
    selected_ids: set[str],
    native_contract_ids: set[str] | None = None,
    kind: str,
) -> list[dict[str, str]] | None:
    """Validate one compact per-capability evidence binding.

    H7 receives only hashes and stable native identifiers.  It intentionally
    cannot receive a source path, source body, upstream prompt, or an action
    authorization through this route-receipt channel.
    """

    if not isinstance(value, list) or len(value) > 4:
        return None
    expected_fields = {"capabilityId", "provenanceHash"} if kind == "provenance" else {
        "capabilityId", "contractId", "parityHash"
    }
    result: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != expected_fields:
            return None
        capability_id = _strict_text(item.get("capabilityId"), maximum=160, pattern=CAPABILITY_NATIVE_ID_RE)
        if capability_id is None or capability_id not in selected_ids or capability_id in seen:
            return None
        seen.add(capability_id)
        if kind == "provenance":
            provenance_hash = _strict_hash(item.get("provenanceHash"))
            if provenance_hash is None:
                return None
            result.append({"capabilityId": capability_id, "provenanceHash": provenance_hash})
            continue
        contract_id = _strict_text(item.get("contractId"), maximum=160, pattern=CAPABILITY_NATIVE_CONTRACT_ID_RE)
        parity_hash = _strict_hash(item.get("parityHash"))
        if contract_id is None or parity_hash is None or native_contract_ids is None or contract_id not in native_contract_ids:
            return None
        result.append({"capabilityId": capability_id, "contractId": contract_id, "parityHash": parity_hash})
    if seen != selected_ids:
        return None
    return result


def _normalize_capability_route_receipt(value: Any) -> tuple[dict[str, Any] | None, str]:
    """Validate a route-owned, non-authorizing native capability receipt.

    The router has already made its bounded semantic selection.  This runtime
    only binds that safe projection to H7 evidence; it never re-routes, loads
    a cold source, accepts an upstream path, or elevates authorization.
    """

    if value is None:
        return None, "H7_CAPABILITY_ROUTE_NOT_SUPPLIED"
    if not isinstance(value, dict) or set(value) != CAPABILITY_ROUTE_RECEIPT_FIELDS:
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_FIELDS_INVALID"
    if value.get("schema") != CAPABILITY_ROUTE_RECEIPT_SCHEMA:
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_SCHEMA_INVALID"
    state = str(value.get("state", ""))
    code = _strict_text(value.get("code"), maximum=112, pattern=CAPABILITY_ROUTE_CODE_RE)
    route_hash = _strict_hash(value.get("routeHash"))
    shadow_gate = value.get("shadowGate")
    if (
        state not in CAPABILITY_ROUTE_STATES
        or code is None
        or route_hash is None
        or value.get("nonAuthorizing") is not True
        or value.get("rawPromptStored") is not False
        or value.get("rawTranscriptStored") is not False
        or value.get("sourcePathsOmitted") is not True
        or not shadow_gate_is_valid(shadow_gate)
    ):
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    selected_raw = value.get("selectedNativeCapabilityIds")
    contracts_raw = value.get("nativeContractIds")
    if not isinstance(selected_raw, list) or not isinstance(contracts_raw, list) or len(selected_raw) > 4 or len(contracts_raw) > 4:
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    selected: list[str] = []
    for item in selected_raw:
        capability_id = _strict_text(item, maximum=160, pattern=CAPABILITY_NATIVE_ID_RE)
        if capability_id is None or capability_id in selected:
            return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
        selected.append(capability_id)
    contracts: list[str] = []
    for item in contracts_raw:
        contract_id = _strict_text(item, maximum=160, pattern=CAPABILITY_NATIVE_CONTRACT_ID_RE)
        if contract_id is None or contract_id in contracts:
            return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
        contracts.append(contract_id)
    selected_ids = set(selected)
    contract_ids = set(contracts)
    provenance = _normalize_capability_hashes(
        value.get("provenanceHashes"), selected_ids=selected_ids, kind="provenance"
    )
    parity = _normalize_capability_hashes(
        value.get("parityHashes"), selected_ids=selected_ids, native_contract_ids=contract_ids, kind="parity"
    )
    if provenance is None or parity is None:
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    selected_ready = state == "ready"
    if selected_ready != bool(selected) or (selected_ready and not contracts):
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    if state != "ready" and (selected or contracts or provenance or parity):
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    if code == "CAPABILITY_ROUTE_EVALUATION_WITHHELD" and shadow_gate.get("state") != "withheld":
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    if state == "ready" and shadow_gate.get("state") not in {"ready", "not_applicable"}:
        return None, "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    normalized: dict[str, Any] = {
        "schema": CAPABILITY_ROUTE_RECEIPT_SCHEMA,
        "state": state,
        "code": code,
        "selectedNativeCapabilityIds": selected,
        "nativeContractIds": contracts,
        "provenanceHashes": provenance,
        "parityHashes": parity,
        "routeHash": route_hash,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
        "shadowGate": dict(shadow_gate),
    }
    normalized["selectionHash"] = canonical_hash(normalized)
    return normalized, "H7_CAPABILITY_ROUTE_RECEIPT_CURRENT"


def _capability_route_receipt_valid(value: Any) -> bool:
    """Revalidate a receipt's compact route projection from its own hash."""

    if not isinstance(value, dict):
        return False
    selection_hash = str(value.get("selectionHash", ""))
    candidate = {key: item for key, item in value.items() if key != "selectionHash"}
    normalized, _ = _normalize_capability_route_receipt(candidate)
    return isinstance(normalized, dict) and selection_hash == str(normalized.get("selectionHash", "")) and value == normalized


def _external_capability_route_compatibility(value: Any) -> tuple[dict[str, Any] | None, str]:
    """Accept legacy router input only as non-authorizing compatibility evidence.

    H7 always derives the actual route through ``execution_assist``.  A prior
    adapter may still submit its compact receipt while rolling forward, but it
    is reduced to two hashes and can never choose a capability or alter the
    H7-derived receipt.
    """

    if value is None:
        return None, "H7_CAPABILITY_ROUTE_COMPATIBILITY_NOT_SUPPLIED"
    normalized, code = _normalize_capability_route_receipt(value)
    if normalized is None:
        return None, code or "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    body = {
        "schema": CAPABILITY_ROUTE_COMPATIBILITY_SCHEMA,
        "state": "accepted_compatibility_only",
        "externalRouteHash": str(normalized.get("routeHash", "")),
        "externalSelectionHash": str(normalized.get("selectionHash", "")),
        "nonAuthorizing": True,
        "cannotSelectCapabilities": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {
        **body,
        "payloadHash": canonical_hash(body),
    }, "H7_CAPABILITY_ROUTE_COMPATIBILITY_CURRENT"


def _external_capability_route_compatibility_valid(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != CAPABILITY_ROUTE_COMPATIBILITY_FIELDS:
        return False
    if (
        value.get("schema") != CAPABILITY_ROUTE_COMPATIBILITY_SCHEMA
        or value.get("state") != "accepted_compatibility_only"
        or _strict_hash(value.get("externalRouteHash")) is None
        or _strict_hash(value.get("externalSelectionHash")) is None
        or value.get("nonAuthorizing") is not True
        or value.get("cannotSelectCapabilities") is not True
        or value.get("rawPromptStored") is not False
        or value.get("rawTranscriptStored") is not False
        or _strict_hash(value.get("payloadHash")) is None
    ):
        return False
    return str(value.get("payloadHash", "")) == canonical_hash(
        {key: item for key, item in value.items() if key != "payloadHash"}
    )


def _resolve_execution_assist_for_turn(
    core: BrainCore,
    intent: dict[str, Any],
    execution_assist_request: Any,
    external_capability_route_receipt: Any,
    *,
    apply_phase: str = "planning",
) -> tuple[dict[str, Any] | None, dict[str, Any] | None, dict[str, Any] | None, str]:
    """Create the H7-owned assist receipt and reduce legacy input to hashes.

    The router runs inside the H7 runtime after typed intent is resolved.  It
    receives at most the compact semantic request; raw user text, source paths
    and external route selections remain outside this control-plane path.
    """

    if intent.get("executionAssistAllowed") is not True:
        if execution_assist_request is not None or external_capability_route_receipt is not None:
            return None, None, None, "H7_EXECUTION_ASSIST_NOT_ALLOWED"
        return None, None, None, "H7_EXECUTION_ASSIST_NOT_APPLICABLE"
    execution_assist, code = resolve_execution_assist(
        core.package_root,
        intent,
        execution_assist_request,
        apply_phase=apply_phase,
    )
    if execution_assist is None or not execution_assist_receipt_is_valid(execution_assist):
        return None, None, None, code or "H7_EXECUTION_ASSIST_RECEIPT_INVALID"
    route_input = execution_assist_capability_route_receipt(execution_assist)
    route_receipt, route_code = _normalize_capability_route_receipt(route_input)
    if route_receipt is None:
        return None, None, None, route_code or "H7_EXECUTION_ASSIST_ROUTE_INVALID"
    compatibility, compatibility_code = _external_capability_route_compatibility(
        external_capability_route_receipt
    )
    if external_capability_route_receipt is not None and compatibility is None:
        return None, None, None, compatibility_code or "H7_CAPABILITY_ROUTE_RECEIPT_INVALID"
    return execution_assist, route_receipt, compatibility, "H7_EXECUTION_ASSIST_CURRENT"


def _validated_execution_assist_bundle(value: Any) -> ExecutionAssistBundle | None:
    """Accept only a receipt bundle produced earlier in this same call.

    The bundle is an internal latency optimization, not caller-supplied
    continuation state.  Every component is rechecked before reuse, and an
    invalid value simply falls back to the normal resolver.
    """

    if not isinstance(value, (tuple, list)) or len(value) != 4:
        return None
    execution_assist, route_receipt, compatibility, code = value
    if not isinstance(execution_assist, dict) or not execution_assist_receipt_is_valid(execution_assist):
        return None
    if not isinstance(route_receipt, dict) or not _capability_route_receipt_valid(route_receipt):
        return None
    if compatibility is not None and (
        not isinstance(compatibility, dict) or not _external_capability_route_compatibility_valid(compatibility)
    ):
        return None
    if not isinstance(code, str) or not code:
        return None
    return execution_assist, route_receipt, compatibility, code


def _resolve_project_knowledge_for_turn(
    core: BrainCore,
    contract: dict[str, Any],
    progress_status: dict[str, Any],
    execution_assist: dict[str, Any],
) -> tuple[dict[str, Any] | None, str]:
    """Run the H7-native proof slice only after scope and proof are current.

    The execution-assist receipt contains no project path.  This bridge takes
    the root exclusively from the already-bound local cwd scope and the focus files
    exclusively from the current H7 proof, so an ordinary continuation never
    turns into a tree scan or a user-controlled filesystem query.
    """

    route = execution_assist.get("projectKnowledgeRoute")
    if not project_knowledge_route_is_valid(route):
        return None, "H7_PROJECT_KNOWLEDGE_ROUTE_INVALID"
    result, code = resolve_project_knowledge(
        core._context_project_root(),
        project_progress_proof=(
            contract.get("projectProgressProof") if isinstance(contract.get("projectProgressProof"), dict) else None
        ),
        project_progress_status=progress_status,
        route=route,
        expected_phase=str(contract.get("currentPhase", "")),
        expected_current_step=str(contract.get("currentStep", "")),
        expected_next_action=str(contract.get("nextAction", "")),
        expected_completed_steps=list(contract.get("completedSteps", []) or []),
    )
    if result is None:
        return None, code or "H7_PROJECT_KNOWLEDGE_UNAVAILABLE"
    public = public_project_knowledge(result)
    if not project_knowledge_receipt_is_valid(public):
        return None, "H7_PROJECT_KNOWLEDGE_RECEIPT_INVALID"
    if str(public.get("state", "")) == "withheld":
        return None, code or str(public.get("code", "H7_PROJECT_KNOWLEDGE_WITHHELD"))
    return result, code


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(prefix=".turn-runtime-", suffix=".tmp", dir=str(path.parent))
    temporary = Path(raw_path)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _failure_loop_path(memory_base: Path, scope_ref: str) -> Path:
    safe_scope = re.sub(r"[^A-Za-z0-9._-]+", "-", str(scope_ref or "")).strip("-") or "scope"
    return memory_base / "workspace" / "runtime-state" / "turn-runtime" / "failure-loops" / f"{safe_scope}.json"


def _scope_runtime_lock_path(memory_base: Path, scope_ref: str) -> Path:
    safe_scope = re.sub(r"[^A-Za-z0-9._-]+", "-", str(scope_ref or "")).strip("-") or "scope"
    return memory_base / "workspace" / "runtime-state" / "turn-runtime" / "locks" / f"{safe_scope}.lock"


@contextmanager
def _runtime_scope_lock(path: Path):
    """Take one short cross-process lock for all scope-local journals."""

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        yield False
        return

    # The path is a persistent advisory-lock file, not an ownership marker.
    # Releasing an O_EXCL/token lock by read-then-unlink has an unavoidable
    # replacement race: an old owner can delete a repairer's new lock.  OS
    # advisory locks instead belong to this open handle and are released on
    # unlock/close (including process exit), so an orphaned path is harmless.
    try:
        handle = path.open("a+b")
    except OSError:
        yield False
        return
    try:
        try:
            handle.seek(0, os.SEEK_END)
            if handle.tell() == 0:
                # ``msvcrt.locking`` needs a byte range on Windows.  The
                # constant marker contains no owner or scope metadata.
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
        while time.monotonic() - started < FAILURE_LOOP_LOCK_TIMEOUT_SECONDS:
            try:
                handle.seek(0)
                if os.name == "nt":
                    msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except OSError as error:
                # EACCES/EAGAIN are the cross-platform non-blocking-lock
                # contention signals.  Other I/O failures cannot safely be
                # retried as though another scope owner were merely slow.
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
                    # Closing the handle still releases the advisory lock.
                    pass
    finally:
        handle.close()


@contextmanager
def _failure_loop_lock(path: Path):
    """Compatibility wrapper for the failure-loop journal lock."""

    # All scope-local journals share one lock so receipt, telemetry, and
    # failure-loop read-modify-write operations cannot overwrite one another.
    try:
        memory_base = path.parents[4]
    except IndexError:
        memory_base = path.parent
    scope_ref = path.stem
    with _runtime_scope_lock(_scope_runtime_lock_path(memory_base, scope_ref)) as acquired:
        yield acquired


def _failure_loop_state_valid(value: Any, scope_ref: str) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    required = {
        "schema",
        "scopeRef",
        "revision",
        "history",
        "reservations",
        "updatedAt",
        "rawPromptStored",
        "rawTranscriptStored",
        "payloadHash",
    }
    if set(value) != required:
        return None
    if value.get("schema") != "super-brain.turn-runtime-failure-loop.v1":
        return None
    if str(value.get("scopeRef", "")) != str(scope_ref):
        return None
    revision = value.get("revision")
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
        return None
    updated_at = value.get("updatedAt")
    if _parse_utc_timestamp(updated_at) is None:
        return None
    history = value.get("history", [])
    if not isinstance(history, list) or len(history) > MAX_FAILURE_LOOP_HISTORY:
        return None
    if any(not isinstance(item, dict) or not failure_loop_receipt_is_valid(item) for item in history):
        return None
    reservations = value.get("reservations", [])
    if not isinstance(reservations, list) or len(reservations) > MAX_FAILURE_LOOP_RESERVATIONS:
        return None
    normalized_reservations: list[dict[str, Any]] = []
    digest_names = (
        "failureFingerprintDigest",
        "evidenceFingerprintDigest",
        "actionFingerprintDigest",
        "phaseDigest",
    )
    for reservation in reservations:
        if not isinstance(reservation, dict):
            return None
        legacy_required = {
            "reservationId",
            "failureFingerprintDigest",
            "evidenceFingerprintDigest",
            "actionFingerprintDigest",
            "phaseDigest",
            "contextDigest",
            "userCorrection",
            "guard",
            "createdAt",
        }
        current_required = legacy_required | {"expiresAt"}
        reservation_fields = set(reservation)
        if reservation_fields != legacy_required and reservation_fields != current_required:
            return None
        reservation_id = str(reservation.get("reservationId", ""))
        if not re.fullmatch(r"flr-[0-9a-f]{32}", reservation_id):
            return None
        if not isinstance(reservation.get("userCorrection"), bool):
            return None
        created_at = reservation.get("createdAt")
        if _parse_utc_timestamp(created_at) is None:
            return None
        expires_at = reservation.get("expiresAt")
        if expires_at is not None and _parse_utc_timestamp(expires_at) is None:
            return None
        if not all(
            isinstance(reservation.get(field), str)
            and re.fullmatch(r"[a-f0-9]{64}", str(reservation.get(field)))
            for field in (*digest_names, "contextDigest")
        ):
            return None
        guard = reservation.get("guard")
        if not isinstance(guard, dict) or not failure_loop_receipt_is_valid(guard):
            return None
        if guard.get("state") != "retryable":
            return None
        if any(str(guard.get(field, "")) != str(reservation.get(field, "")) for field in (*digest_names, "contextDigest")):
            return None
        normalized_reservations.append(dict(reservation))
    supplied_hash = value.get("payloadHash")
    if value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return None
    if not isinstance(supplied_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", supplied_hash):
        return None
    body = {key: item for key, item in value.items() if key != "payloadHash"}
    try:
        if supplied_hash != canonical_hash(body):
            return None
    except (TypeError, ValueError):
        return None
    return {
        "schema": "super-brain.turn-runtime-failure-loop.v1",
        "scopeRef": str(scope_ref),
        "revision": revision,
        "history": list(history),
        "reservations": normalized_reservations,
        "updatedAt": updated_at,
        "rawPromptStored": value.get("rawPromptStored") is False,
        "rawTranscriptStored": value.get("rawTranscriptStored") is False,
        "payloadHash": supplied_hash,
    }


def _failure_loop_reservation_is_live(value: dict[str, Any]) -> bool:
    created = _parse_utc_timestamp(value.get("createdAt"))
    if created is None:
        return False
    now = datetime.now(timezone.utc)
    age = (now - created).total_seconds()
    # A future-dated reservation is not evidence of a live retry.  Treat it
    # as stale so a tampered/clock-skewed journal cannot extend the retry
    # window indefinitely; the caller will remove it under the scope lock.
    if age < 0:
        return False
    if "expiresAt" in value:
        expires = _parse_utc_timestamp(value.get("expiresAt"))
        return expires is not None and now <= expires
    return age <= FAILURE_LOOP_RESERVATION_TTL_SECONDS


def _failure_loop_read_state(path: Path, scope_ref: str) -> dict[str, Any] | None:
    raw = _read_json(path)
    if raw is None:
        return {} if not path.exists() else None
    try:
        return _failure_loop_state_valid(raw, scope_ref)
    except (TypeError, ValueError, OverflowError):
        return None


def _failure_loop_write_state(
    path: Path,
    scope_ref: str,
    state: dict[str, Any],
    *,
    expected_revision: int,
    expected_payload_hash: str,
) -> bool:
    current = _failure_loop_read_state(path, scope_ref)
    if current is None:
        return False
    actual_revision = int(current.get("revision", 0) or 0)
    actual_hash = str(current.get("payloadHash", ""))
    if actual_revision != expected_revision or actual_hash != expected_payload_hash:
        return False
    if len(state.get("history", [])) > MAX_FAILURE_LOOP_HISTORY:
        return False
    if len(state.get("reservations", [])) > MAX_FAILURE_LOOP_RESERVATIONS:
        return False
    body = {
        "schema": "super-brain.turn-runtime-failure-loop.v1",
        "scopeRef": str(scope_ref),
        "revision": expected_revision + 1,
        "history": list(state.get("history", [])),
        "reservations": list(state.get("reservations", [])),
        "updatedAt": _utc_now(),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    body["payloadHash"] = canonical_hash(body)
    try:
        _atomic_json(path, body)
    except (OSError, TypeError, ValueError):
        return False
    return True


def _reservation_record(reservation: dict[str, Any]) -> dict[str, Any]:
    return {
        "failureFingerprintDigest": str(reservation.get("failureFingerprintDigest", "")),
        "evidenceFingerprintDigest": str(reservation.get("evidenceFingerprintDigest", "")),
        "actionFingerprintDigest": str(reservation.get("actionFingerprintDigest", "")),
        "phaseDigest": str(reservation.get("phaseDigest", "")),
        "userCorrection": bool(reservation.get("userCorrection") is True),
    }


def _invalid_failure_loop_guard() -> dict[str, Any]:
    """Return a valid, fused receipt for an unreadable guard state."""

    body = {
        "schema": "super-brain.failure-loop-guard.v1",
        "state": "withheld",
        "decision": "withhold",
        "code": "H7_REPAIR_LOOP_GUARD_INVALID",
        "retryAllowed": False,
        "fused": True,
        "contextChanged": False,
        "resetApplied": False,
        "occurrenceCount": 0,
        "retryBudget": 1,
        "retryBudgetRemaining": 0,
        "failureFingerprintDigest": "",
        "evidenceFingerprintDigest": "",
        "actionFingerprintDigest": "",
        "phaseDigest": "",
        "contextDigest": "",
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def _empty_failure_loop_state(scope_ref: str) -> dict[str, Any]:
    body = {
        "schema": "super-brain.turn-runtime-failure-loop.v1",
        "scopeRef": str(scope_ref),
        "revision": 0,
        "history": [],
        "reservations": [],
        "updatedAt": _utc_now(),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def _failure_loop_guard_for_state(
    state: dict[str, Any],
    *,
    failure_fingerprint: str,
    evidence_fingerprint: str,
    action_fingerprint: str,
    phase: str,
    user_correction: bool,
) -> dict[str, Any]:
    prior = list(state.get("history", []))
    prior.extend(
        reservation.get("guard")
        for reservation in state.get("reservations", [])
        if isinstance(reservation, dict) and isinstance(reservation.get("guard"), dict)
    )
    return evaluate_failure_loop(
        failure_fingerprint,
        prior,
        evidence_fingerprint=evidence_fingerprint,
        action_fingerprint=action_fingerprint,
        phase=phase,
        user_correction=user_correction,
    )


def _guard_reservation(
    guard: dict[str, Any],
    *,
    reservation_id: str,
    ttl_seconds: float = FAILURE_LOOP_RESERVATION_TTL_SECONDS,
) -> dict[str, Any]:
    return {
        "reservationId": reservation_id,
        "failureFingerprintDigest": str(guard.get("failureFingerprintDigest", "")),
        "evidenceFingerprintDigest": str(guard.get("evidenceFingerprintDigest", "")),
        "actionFingerprintDigest": str(guard.get("actionFingerprintDigest", "")),
        "phaseDigest": str(guard.get("phaseDigest", "")),
        "contextDigest": str(guard.get("contextDigest", "")),
        "userCorrection": bool(guard.get("resetApplied") is True),
        "guard": guard,
        "createdAt": _utc_now(),
        "expiresAt": _utc_after(ttl_seconds),
    }


def _reserve_failure_loop(
    memory_base: Path,
    scope_ref: str,
    *,
    failure_fingerprint: str,
    evidence_fingerprint: str,
    action_fingerprint: str,
    phase: str,
    user_correction: bool = False,
    side_effect_timeout: float | None = None,
) -> tuple[str, dict[str, Any]]:
    """Reserve one retry slot before an external side effect is attempted."""

    if not str(scope_ref).strip():
        return "", _invalid_failure_loop_guard()
    path = _failure_loop_path(memory_base, scope_ref)
    with _failure_loop_lock(path) as acquired:
        if not acquired:
            return "", _invalid_failure_loop_guard()
        state = _failure_loop_read_state(path, scope_ref)
        if state is None:
            return "", _invalid_failure_loop_guard()
        reservations = [item for item in state.get("reservations", []) if _failure_loop_reservation_is_live(item)]
        if len(reservations) != len(state.get("reservations", [])):
            recovered = {**state, "reservations": reservations}
            if not _failure_loop_write_state(
                path,
                scope_ref,
                recovered,
                expected_revision=int(state.get("revision", 0) or 0),
                expected_payload_hash=str(state.get("payloadHash", "")),
            ):
                return "", _invalid_failure_loop_guard()
            state = _failure_loop_read_state(path, scope_ref)
            if state is None:
                return "", _invalid_failure_loop_guard()
        guard = _failure_loop_guard_for_state(
            state,
            failure_fingerprint=failure_fingerprint,
            evidence_fingerprint=evidence_fingerprint,
            action_fingerprint=action_fingerprint,
            phase=phase,
            user_correction=user_correction,
        )
        if not failure_loop_receipt_is_valid(guard):
            return "", _invalid_failure_loop_guard()
        if guard.get("retryAllowed") is not True:
            return "", guard
        reservation_id = "flr-" + uuid.uuid4().hex
        reservation_ttl = _reservation_ttl_for_timeout(side_effect_timeout)
        next_state = {
            **state,
            "reservations": list(state.get("reservations", [])) + [
                _guard_reservation(
                    guard,
                    reservation_id=reservation_id,
                    ttl_seconds=reservation_ttl,
                )
            ],
        }
        if not _failure_loop_write_state(
            path,
            scope_ref,
            next_state,
            expected_revision=int(state.get("revision", 0) or 0),
            expected_payload_hash=str(state.get("payloadHash", "")),
        ):
            return "", _invalid_failure_loop_guard()
        return reservation_id, guard


def _finish_failure_loop_reservation(
    memory_base: Path,
    scope_ref: str,
    reservation_id: str,
    *,
    commit: bool,
) -> tuple[bool, dict[str, Any] | None]:
    """Commit a failed side effect or release a successful reservation."""

    if not reservation_id:
        return False, None
    path = _failure_loop_path(memory_base, scope_ref)
    with _failure_loop_lock(path) as acquired:
        if not acquired:
            return False, None
        state = _failure_loop_read_state(path, scope_ref)
        if state is None:
            return False, None
        reservations = list(state.get("reservations", []))
        matching = [item for item in reservations if str(item.get("reservationId", "")) == reservation_id]
        if len(matching) != 1:
            return False, None
        reservation = matching[0]
        guard = reservation.get("guard") if isinstance(reservation.get("guard"), dict) else None
        next_reservations = [item for item in reservations if str(item.get("reservationId", "")) != reservation_id]
        next_history = list(state.get("history", []))
        if commit and isinstance(guard, dict):
            if len(next_history) >= MAX_FAILURE_LOOP_HISTORY:
                return False, None
            next_history.append(guard)
        next_state = {**state, "history": next_history, "reservations": next_reservations}
        written = _failure_loop_write_state(
            path,
            scope_ref,
            next_state,
            expected_revision=int(state.get("revision", 0) or 0),
            expected_payload_hash=str(state.get("payloadHash", "")),
        )
        return written, guard if isinstance(guard, dict) else None


def _record_failure_loop(
    memory_base: Path,
    scope_ref: str,
    *,
    failure_fingerprint: str,
    evidence_fingerprint: str,
    action_fingerprint: str,
    phase: str,
    user_correction: bool = False,
) -> dict[str, Any]:
    """Compatibility helper that reserves and immediately commits a failure."""

    reservation_id, guard = _reserve_failure_loop(
        memory_base,
        scope_ref,
        failure_fingerprint=failure_fingerprint,
        evidence_fingerprint=evidence_fingerprint,
        action_fingerprint=action_fingerprint,
        phase=phase,
        user_correction=user_correction,
    )
    if not reservation_id:
        return guard
    committed, committed_guard = _finish_failure_loop_reservation(
        memory_base,
        scope_ref,
        reservation_id,
        commit=True,
    )
    return committed_guard if committed and isinstance(committed_guard, dict) else _invalid_failure_loop_guard()


def _apply_failure_loop_result(
    result: dict[str, Any],
    guard: dict[str, Any],
    *,
    original_code: str,
) -> dict[str, Any]:
    """Attach the guard and replace repeated failures with a fuse code."""

    result["failureLoopGuard"] = guard
    if guard.get("fused") is True:
        result["code"] = "H7_REPAIR_LOOP_FUSE_OPEN"
        result["operationState"] = "fused"
        result["retrySafe"] = False
        result["blockedFailureCode"] = original_code
    return result


def _reservation_release_failed_result(
    phase: str,
    context: dict[str, Any],
    *,
    operation: str,
    checkpoint: dict[str, Any] | None = None,
    dispatch: dict[str, Any] | None = None,
    reservation_id: str = "",
) -> dict[str, Any]:
    """Withhold after an external success whose retry reservation was not cleared.

    The authoritative side effect may already be committed.  Never flatten
    that fact into an ordinary failure: callers must reconcile before retrying
    rather than duplicate an idempotent-but-uncertain transition.
    """

    result = _withheld(phase, context, "H7_REPAIR_LOOP_RESERVATION_RELEASE_FAILED")
    result["operationState"] = "partially_committed"
    result["retrySafe"] = False
    result["reconciliationRequired"] = True
    scope = context.get("scope") if isinstance(context.get("scope"), dict) else {}
    scope_ref = str(scope.get("scopeRef", ""))
    result["reservation"] = {
        "state": "release_failed",
        "operation": operation,
        "scopeRef": scope_ref,
        "reservationId": str(reservation_id or ""),
    }
    # Keep the recovery projection compact and non-authorizing.  It tells the
    # caller exactly which scoped side effect must be re-read before retrying,
    # without echoing checkpoint text or treating the local result as proof.
    result["reconciliation"] = {
        "state": "required",
        "scopeRef": scope_ref,
        "operation": operation,
        "next": "read_current_contract_before_retry",
        "retrySafe": False,
    }
    if isinstance(checkpoint, dict):
        result["checkpoint"] = {
            "code": str(checkpoint.get("code", "")),
            "contractCode": str(checkpoint.get("contractCode", "")),
            "stateMutated": bool(checkpoint.get("stateMutated") is True),
        }
        visible = checkpoint.get("visibleProgress") if isinstance(checkpoint.get("visibleProgress"), dict) else {}
        result["reconciliation"].update(
            {
                "transitionId": str(checkpoint.get("transitionId", "")),
                "stateMutated": bool(checkpoint.get("stateMutated") is True),
                "visibleProgressPayloadHash": str(visible.get("payloadHash", "")),
            }
        )
    if isinstance(dispatch, dict):
        result["dispatch"] = {
            "code": str(dispatch.get("code", "")),
            "contractCode": str(dispatch.get("contractCode", "")),
            "contractReason": str(dispatch.get("contractReason", "")),
            "stateMutated": bool(dispatch.get("stateMutated") is True),
        }
        transition = dispatch.get("transition") if isinstance(dispatch.get("transition"), dict) else {}
        result["reconciliation"].update(
            {
                "transitionId": str(dispatch.get("transitionId", "") or transition.get("transitionId", "")),
                "stateMutated": bool(dispatch.get("stateMutated") is True),
            }
        )
    return result


def _scope_path(memory_base: Path, scope_ref: str, phase: str) -> Path:
    if not re.fullmatch(r"[a-f0-9]{64}", str(scope_ref or "")):
        raise ValueError("H7_RUNTIME_SCOPE_REF_INVALID")
    if phase not in {"open", "close"}:
        raise ValueError("H7_RUNTIME_PHASE_INVALID")
    return memory_base / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref / f"{phase}.json"


def _telemetry_path(memory_base: Path, scope_ref: str) -> Path:
    if not re.fullmatch(r"[a-f0-9]{64}", str(scope_ref or "")):
        raise ValueError("H7_RUNTIME_SCOPE_REF_INVALID")
    return memory_base / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref}.json"


def _refs(typed_memory: Any) -> list[str]:
    if not isinstance(typed_memory, dict):
        return []
    result: list[str] = []
    for item in typed_memory.get("refs", []) or []:
        if not isinstance(item, dict):
            continue
        card_id = _compact(item.get("cardId"), 160)
        if not card_id:
            continue
        try:
            revision = int(item.get("cardRevision", 0) or 0)
        except (TypeError, ValueError):
            revision = 0
        result.append(f"{card_id}@{revision}")
    return result[:8]


def _take_context_turn_runtime_snapshot(context: dict[str, Any]) -> dict[str, Any] | None:
    """Take and validate the one-call private context snapshot.

    The key is popped before any caller can return ``context`` publicly.  A
    malformed or mismatched snapshot is only an optimization miss: the normal
    fresh binding/proof path remains the safe fallback.
    """

    snapshot = context.pop(TURN_RUNTIME_CONTEXT_SNAPSHOT_KEY, None)
    if not isinstance(snapshot, dict) or snapshot.get("schema") != TURN_RUNTIME_CONTEXT_SNAPSHOT_SCHEMA:
        return None
    contract = snapshot.get("contract")
    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    scope = context.get("scope") if isinstance(context.get("scope"), dict) else {}
    progress_status = snapshot.get("projectProgressStatus")
    project_progress = task.get("projectProgress") if isinstance(task.get("projectProgress"), dict) else {}
    if not isinstance(contract, dict) or not isinstance(progress_status, dict):
        return None
    try:
        contract_revision = int(contract.get("revision", -1))
        snapshot_revision = int(snapshot.get("contractRevision", -2))
        task_revision = int(task.get("contractRevision", -3))
    except (TypeError, ValueError):
        return None
    contract_hash = context_hash(contract)
    identity_matches = (
        str(contract.get("taskId", "")) == str(task.get("taskId", ""))
        and str(contract.get("taskInstanceId", "")) == str(task.get("taskInstanceId", ""))
        and str(contract.get("workspaceKey", "")).lower() == str(scope.get("workspaceKey", "")).lower()
        and str(contract.get("ownerSessionKey", "")).lower() == str(scope.get("ownerSessionKey", "")).lower()
    )
    proof_matches = (
        str(project_progress.get("state", "")) == str(progress_status.get("state", ""))
        and str(project_progress.get("payloadHash", "")) == str(progress_status.get("payloadHash", ""))
    )
    if (
        not identity_matches
        or contract_revision != snapshot_revision
        or contract_revision != task_revision
        or not contract_hash
        or contract_hash != str(snapshot.get("contractHash", ""))
        or contract_hash != str(task.get("contractHash", ""))
        or not proof_matches
    ):
        return None
    return {
        "contract": contract,
        "projectProgressStatus": progress_status,
    }


def _contract_binding(
    core: BrainCore,
    context: dict[str, Any],
    *,
    allow_reconciliation_checkpoint: bool = False,
    private_context_snapshot: dict[str, Any] | None = None,
    terminal_finalization_phase: str = "",
) -> tuple[dict[str, Any] | None, str]:
    # A private snapshot is issued only by this call's immediately preceding
    # ``core.context`` read on the normal read-only continuity path.  All
    # checkpoint, close, formal, recovery, and rebind paths leave it absent
    # and retain the existing fresh authority read below.
    snapshot_contract = (
        private_context_snapshot.get("contract")
        if isinstance(private_context_snapshot, dict)
        else None
    )
    if isinstance(snapshot_contract, dict):
        return snapshot_contract, "TURN_RUNTIME_CONTRACT_CURRENT_FROM_CONTEXT_SNAPSHOT"
    scope = context.get("scope") if isinstance(context.get("scope"), dict) else {}
    workspace = str(scope.get("workspaceKey", ""))
    session = str(scope.get("ownerSessionKey", ""))
    # A final checkpoint receives a deliberately non-wake-eligible terminal
    # context.  Preserve that narrow selection when re-reading the contract
    # for binding; otherwise this second read discards the exact candidate
    # that ``open_turn`` already validated and strands terminal finalization.
    terminal_finalization = str(context.get("code", "")) == "BRAIN_CONTEXT_TERMINAL_FINALIZATION_READY"
    contract, code = core._read_context_contract(
        workspace,
        session,
        allow_terminal_finalization=terminal_finalization,
        allow_reconciliation_checkpoint=allow_reconciliation_checkpoint,
        terminal_finalization_phase=terminal_finalization_phase,
    )
    if not isinstance(contract, dict):
        return None, code or "TURN_RUNTIME_CONTRACT_UNAVAILABLE"
    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    if str(task.get("contractHash", "")) != context_hash(contract):
        return None, "TURN_RUNTIME_CONTRACT_CHANGED"
    return contract, "TURN_RUNTIME_CONTRACT_CURRENT"


def _resolve_action_authorization(
    core: BrainCore,
    context: dict[str, Any],
    contract: dict[str, Any],
    intent: dict[str, Any],
    *,
    timeout: float,
) -> dict[str, Any]:
    """Project mutation authorization from the execution-contract authority.

    ``BrainCore.context`` is deliberately a read-side projection and keeps
    executable actions withheld.  A material memory/task-card write needs one
    explicit authority read after local contract/proof binding; otherwise activation
    can silently disagree with the contract (the old hard-coded ``withheld``
    defect).  Only bounded identity/hash fields are retained.
    """

    intent_kind = str(intent.get("kind", ""))
    if intent_kind not in ACTION_AUTHORIZATION_REQUIRED_INTENTS:
        return {
            "required": False,
            "state": "withheld",
            "code": "H7_ACTION_AUTHORIZATION_NOT_REQUESTED",
            "source": "not_requested",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    scope = context.get("scope") if isinstance(context.get("scope"), dict) else {}
    workspace_key = str(scope.get("workspaceKey", ""))
    session_key = str(scope.get("ownerSessionKey", ""))
    task_id = str(contract.get("taskId", ""))
    task_instance_id = str(contract.get("taskInstanceId", ""))
    try:
        bounded_timeout = max(1.0, min(12.0, float(timeout)))
    except (TypeError, ValueError):
        bounded_timeout = 8.0
    return_code, resolution = _invoke_contract(
        core.package_root,
        core.memory_base,
        action="Resolve",
        task_id=task_id,
        workspace_key=workspace_key,
        session_key=session_key,
        timeout=bounded_timeout,
        execution_cwd=core._context_project_root(),
    )
    if return_code != 0 or not isinstance(resolution, dict) or resolution.get("ok") is not True:
        return {
            "required": True,
            "state": "withheld",
            "code": "H7_ACTION_AUTHORIZATION_RESOLVE_UNAVAILABLE",
            "source": "execution_contract",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    authorization = str(resolution.get("actionAuthorization", "withheld"))
    try:
        resolved_revision = int(resolution.get("contractRevision", -1) or -1)
    except (TypeError, ValueError):
        resolved_revision = -1
    try:
        expected_revision = int(contract.get("revision", -2) or -2)
    except (TypeError, ValueError):
        expected_revision = -2
    identity_matches = (
        str(resolution.get("taskId", "")) == task_id
        and str(resolution.get("taskInstanceId", "")) == task_instance_id
        and str(resolution.get("workspaceKey", "")) == workspace_key
        and resolved_revision == expected_revision
    )
    plan = contract.get("planReceipt") if isinstance(contract.get("planReceipt"), dict) else {}
    expected_plan = str(plan.get("planFingerprint", ""))
    plan_matches = not expected_plan or str(resolution.get("planFingerprint", "")) == expected_plan
    allowed_claim = resolution.get("claimAllowed") is True and resolution.get("needsConfirmation") is False
    if (
        authorization not in {"allowed", "withheld"}
        or str(resolution.get("resolutionSource", "")) != "execution_contract"
        or not identity_matches
        or not plan_matches
        or (
        authorization == "allowed" and not allowed_claim
        )
    ):
        authorization = "withheld"
        code = "H7_ACTION_AUTHORIZATION_RESOLVE_INVALID"
    else:
        code = "H7_ACTION_AUTHORIZATION_RESOLVED" if authorization == "allowed" else "H7_ACTION_AUTHORIZATION_WITHHELD"
    safe_resolution = {
        "schema": "super-brain.action-authorization-resolution.v1",
        "required": True,
        "state": authorization,
        "code": code,
        "source": "execution_contract",
        "contractRevision": int(contract.get("revision", 0) or 0),
        "resolutionHash": canonical_hash(
            {
                "actionAuthorization": authorization,
                "claimAllowed": bool(resolution.get("claimAllowed") is True),
                "needsConfirmation": bool(resolution.get("needsConfirmation") is True),
                "taskId": task_id,
                "taskInstanceId": task_instance_id,
                "workspaceKey": workspace_key,
                "contractRevision": int(contract.get("revision", 0) or 0),
                "planFingerprint": expected_plan,
            }
        ),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return safe_resolution


def _activation(
    core: BrainCore,
    context: dict[str, Any],
    contract: dict[str, Any],
    memory_mode: str,
    *,
    action_authorization: str = "withheld",
    intent: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], str, list[str]]:
    scope = context["scope"]
    typed_memory = context.get("typedMemory") if isinstance(context.get("typedMemory"), dict) else {}
    refs = _refs(typed_memory)
    anchor = contract.get("instructionAnchor") if isinstance(contract.get("instructionAnchor"), dict) else {}
    continuation = contract.get("continuationReceipt") if isinstance(contract.get("continuationReceipt"), dict) else {}
    recovery = contract.get("recoveryCheckpoint") or contract.get("checkpoint")
    recovery = recovery if isinstance(recovery, dict) else {}
    route = _activation_route_for_intent(intent)
    if not route:
        return {
            "schema": "super-brain.activation-receipt.v1",
            "activationState": "withheld",
            "activationId": "",
            "activationCode": "H7_TURN_INTENT_ROUTE_MISSING",
            "actionAuthorization": "withheld",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }, "H7_TURN_INTENT_ROUTE_MISSING", refs
    receipt, code = ensure_current(
        core.package_root,
        core.memory_base,
        memory_root=core.memory_root if core.memory_root.exists() else core.memory_base,
        workspace_key=str(scope.get("workspaceKey", "")),
        session_key=str(scope.get("ownerSessionKey", "")),
        task_id=str(contract.get("taskId", "")),
        task_instance_id=str(contract.get("taskInstanceId", "")),
        route=route,
        memory_mode=memory_mode,
        memory_snapshot_hash=str(typed_memory.get("snapshotPayloadHash", "")),
        memory_refs=refs,
        contract=contract,
        instruction_anchor_hash=str(anchor.get("contentHash", "")),
        continuation_receipt_hash=str(
            continuation.get("receiptHash")
            or continuation.get("payloadHash")
            or continuation.get("stateHash")
            or ""
        ),
        recovery_checkpoint_id=str(recovery.get("checkpointId") or recovery.get("id") or ""),
        recovery_state_hash=str(recovery.get("stateHash") or recovery.get("hash") or ""),
        return_point=contract.get("returnPoint") if isinstance(contract.get("returnPoint"), dict) else None,
        action_authorization=action_authorization,
        require_scope=True,
    )
    return receipt, code, refs


def _activation_route_for_intent(intent: dict[str, Any] | None) -> str:
    """Read the route projection emitted by the canonical intent contract."""

    route = str((intent or {}).get("activationRoute", "")).strip()
    return route if re.fullmatch(r"[a-z][a-z0-9_]{2,63}", route) else ""


def _bounded_contract_list(contract: dict[str, Any], field: str, *, limit: int = 8, maximum: int = 180) -> list[str]:
    values = contract.get(field)
    if not isinstance(values, list):
        return []
    result: list[str] = []
    for value in values:
        compact = _compact(value, maximum)
        if compact and compact not in result:
            result.append(compact)
        if len(result) >= limit:
            break
    return result


def _progress_truth(progress_status: dict[str, Any], turn_intent: dict[str, Any] | None) -> dict[str, Any]:
    """Expose only the formal, revalidated project-progress proof summary.

    The regular execution-contract fields are useful task context, but cannot
    alone prove that a phase was actually completed.  H7 therefore reports no
    free-form evidence strings here: callers get a bounded proof state/hash
    and counts, while the underlying project files are rechecked privately.
    """

    intent = turn_intent if isinstance(turn_intent, dict) else {}
    current = bool(progress_status.get("current"))
    completed_count = int(progress_status.get("completedCount", 0) or 0)
    return {
        "state": "current" if current else "withheld",
        "payloadHash": str(progress_status.get("payloadHash", "")),
        "missing": list(progress_status.get("missing", []) or [])[:8],
        "completedCount": max(0, completed_count),
        "evidenceCount": max(0, int(progress_status.get("evidenceCount", 0) or 0)),
        "verificationCount": max(0, int(progress_status.get("verificationCount", 0) or 0)),
        "verificationState": str(progress_status.get("verificationState", "withheld")),
        "projectEvidenceRequired": bool(intent.get("projectEvidenceRequired")),
        "canClaimProjectProgress": current,
        "canClaimVerifiedCompletion": current and completed_count > 0 and str(progress_status.get("verificationState", "")) == "passed",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _visible_progress_truth(value: Any) -> dict[str, Any]:
    """Expose the source-bound recovery anchor without duplicating its text."""

    status = value if isinstance(value, dict) else {}
    current = status.get("state") == "current"
    return {
        "state": "current" if current else "withheld",
        "code": str(status.get("code", "H7_VISIBLE_PROGRESS_RECEIPT_REQUIRED")),
        "missing": list(status.get("missing", []) or [])[:8],
        "source": str(status.get("source", "")),
        "sentenceHash": str(status.get("sentenceHash", "")),
        "payloadHash": str(status.get("payloadHash", "")),
        "projectProgressPayloadHash": str(status.get("projectProgressPayloadHash", "")),
        "scopeBindingHash": str(status.get("scopeBindingHash", "")),
        "continuationEligible": bool(status.get("continuationEligible") is True),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _receipt_body(
    *,
    phase: str,
    context: dict[str, Any],
    contract: dict[str, Any],
    activation: dict[str, Any],
    activation_code: str,
    refs: list[str],
    binding: dict[str, Any],
    continuation: dict[str, Any] | None = None,
    transition: dict[str, Any] | None = None,
    completion_evidence_hash: str = "",
    turn_intent: dict[str, Any] | None = None,
    progress_status: dict[str, Any] | None = None,
    execution_assist: dict[str, Any] | None = None,
    project_knowledge: dict[str, Any] | None = None,
    capability_route_receipt: dict[str, Any] | None = None,
    capability_route_compatibility: dict[str, Any] | None = None,
    recovery_presentation: dict[str, Any] | None = None,
) -> dict[str, Any]:
    scope = context["scope"]
    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    typed_memory = context.get("typedMemory") if isinstance(context.get("typedMemory"), dict) else {}
    core_rules = context.get("coreRules") if isinstance(context.get("coreRules"), dict) else {}
    agent_identity_projection = context.get("agentIdentity") if isinstance(context.get("agentIdentity"), dict) else {}
    authority_model_projection = context.get("authorityModel") if isinstance(context.get("authorityModel"), dict) else {}
    progress_truth = _progress_truth(progress_status if isinstance(progress_status, dict) else {}, turn_intent)
    visible_progress_truth = _visible_progress_truth(task.get("visibleProgress"))
    memory = {
        "state": str(typed_memory.get("state", "")),
        "snapshotPayloadHash": str(typed_memory.get("snapshotPayloadHash", "")),
        "payloadHash": str(typed_memory.get("payloadHash", "")),
        "refs": refs,
        "refsHash": canonical_hash(refs),
    }
    body: dict[str, Any] = {
        "schema": RECEIPT_SCHEMA,
        "mode": MODE,
        "phase": phase,
        "issuedAt": _utc_now(),
        "scope": {
            "workspaceKey": str(scope.get("workspaceKey", "")),
            "scopeRef": str(scope.get("scopeRef", "")),
            "taskId": str(task.get("taskId", "")),
            "taskInstanceId": str(task.get("taskInstanceId", "")),
        },
        "contract": {
            "revision": int(task.get("contractRevision", 0) or 0),
            "stateHash": str(task.get("contractHash", "")),
            "instructionAnchorHash": str(
                (contract.get("instructionAnchor") or {}).get("contentHash", "")
                if isinstance(contract.get("instructionAnchor"), dict)
                else ""
            ),
            "recoveryCheckpointId": str(
                ((contract.get("recoveryCheckpoint") or contract.get("checkpoint") or {}).get("checkpointId", ""))
                if isinstance(contract.get("recoveryCheckpoint") or contract.get("checkpoint"), dict)
                else ""
            ),
            "projectProgressState": str(progress_truth.get("state", "withheld")),
            "projectProgressHash": str(progress_truth.get("payloadHash", "")),
            "visibleProgressState": str(visible_progress_truth.get("state", "withheld")),
            "visibleProgressHash": str(visible_progress_truth.get("payloadHash", "")),
            "visibleProgressSentenceHash": str(visible_progress_truth.get("sentenceHash", "")),
        },
        "activation": {
            "activationId": str(activation.get("activationId", "")),
            "state": str(activation.get("activationState", "withheld")),
            "receiptHash": str(activation.get("receiptHash", "")),
            "code": activation_code,
            # Capability selection is evidence-only.  Preserve the runtime's
            # independently derived authorization state so a receipt can
            # prove that no route card elevated it.
            "actionAuthorization": str(activation.get("actionAuthorization", "withheld")),
        },
        "memory": memory,
        "agentIdentity": agent_identity_projection,
        "authorityModel": authority_model_projection,
        "coreRules": {
            "status": str(core_rules.get("status", "withheld")),
            "code": str(core_rules.get("code", "CORE_RULE_REGISTRY_UNAVAILABLE")),
            "registryVersion": int(core_rules.get("registryVersion", 0) or 0),
            "payloadHash": str(core_rules.get("payloadHash", "")),
            "activeEffectsHash": str(core_rules.get("activeEffectsHash", "")),
            "applicableRuleIds": list(core_rules.get("applicableRuleIds", []) or [])[:12],
            "applicableEffectsHash": str(core_rules.get("applicableEffectsHash", "")),
        },
        "progressTruth": progress_truth,
        "visibleProgress": visible_progress_truth,
        "turnIntent": public_turn_intent(turn_intent),
        "bindingHash": canonical_hash(binding),
        "completionEvidenceHash": completion_evidence_hash,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "rawCompletionEvidenceStored": False,
    }
    if isinstance(recovery_presentation, dict):
        body["recoveryPresentation"] = _public_recovery_presentation(recovery_presentation)
    if isinstance(execution_assist, dict):
        body["executionAssist"] = execution_assist
    if isinstance(project_knowledge, dict):
        body["projectKnowledge"] = project_knowledge
    if isinstance(capability_route_receipt, dict):
        body["capabilityRouteReceipt"] = capability_route_receipt
    if isinstance(capability_route_compatibility, dict):
        body["capabilityRouteCompatibility"] = capability_route_compatibility
    if isinstance(continuation, dict):
        body["continuation"] = {
            "decision": str(continuation.get("decision", "")),
            "code": str(continuation.get("code", "")),
            "terminalReplyAllowed": bool(continuation.get("terminalReplyAllowed", True)),
            "requiresParentResume": bool(continuation.get("requiresParentResume", False)),
        }
    if isinstance(transition, dict):
        body["transition"] = {
            key: transition.get(key)
            for key in ("transitionId", "action", "revision", "focusId", "idempotentReplay")
            if key in transition
        }
    return body


def _write_receipt(memory_base: Path, scope_ref: str, phase: str, body: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    binding_hash = str(body.get("bindingHash", ""))
    path = _scope_path(memory_base, scope_ref, phase)
    with _runtime_scope_lock(_scope_runtime_lock_path(memory_base, scope_ref)) as acquired:
        if not acquired:
            return {"schema": RECEIPT_SCHEMA, "mode": MODE, "phase": phase, "scopeRef": scope_ref, "code": "H7_RUNTIME_SCOPE_LOCK_TIMEOUT"}, False
        existing = _read_json(path)
        path_exists = path.exists()
        if path_exists and not isinstance(existing, dict):
            return {"schema": RECEIPT_SCHEMA, "mode": MODE, "phase": phase, "scopeRef": scope_ref, "code": "H7_RUNTIME_RECEIPT_CORRUPT"}, False
        existing_hash = ""
        if isinstance(existing, dict):
            existing_hash = canonical_hash({key: value for key, value in existing.items() if key != "receiptHash"})
            if (
                existing.get("schema") != RECEIPT_SCHEMA
                or existing.get("mode") != MODE
                or existing.get("phase") != phase
                or not isinstance(existing.get("scope"), dict)
                or str(existing.get("scope", {}).get("scopeRef", "")) != scope_ref
                or not str(existing.get("receiptHash", ""))
                or str(existing.get("receiptHash", "")) != existing_hash
            ):
                return {"schema": RECEIPT_SCHEMA, "mode": MODE, "phase": phase, "scopeRef": scope_ref, "code": "H7_RUNTIME_RECEIPT_CORRUPT"}, False
        if (
            isinstance(existing, dict)
            and existing.get("schema") == RECEIPT_SCHEMA
            and existing.get("mode") == MODE
            and existing.get("phase") == phase
            and str(existing.get("bindingHash", "")) == binding_hash
            and str(existing.get("receiptHash", "")) == existing_hash
        ):
            return existing, True
        value = dict(body)
        value["receiptId"] = f"tr-{phase}-{binding_hash[:24]}"
        value["receiptHash"] = canonical_hash(value)
        try:
            _atomic_json(path, value)
        except (OSError, TypeError, ValueError):
            return {"schema": RECEIPT_SCHEMA, "mode": MODE, "phase": phase, "scopeRef": scope_ref, "code": "H7_RUNTIME_STATE_WRITE_FAILED"}, False
        return value, False


def _record_telemetry(
    memory_base: Path,
    scope_ref: str,
    receipt: dict[str, Any],
    *,
    runtime_duration_ms: int | None = None,
) -> tuple[dict[str, Any], bool]:
    path = _telemetry_path(memory_base, scope_ref)
    with _runtime_scope_lock(_scope_runtime_lock_path(memory_base, scope_ref)) as acquired:
        if not acquired:
            return {"schema": TELEMETRY_SCHEMA, "mode": MODE, "scopeRef": scope_ref, "code": "H7_RUNTIME_SCOPE_LOCK_TIMEOUT", "events": []}, False
        return _record_telemetry_locked(memory_base, scope_ref, receipt, runtime_duration_ms=runtime_duration_ms)


def _record_telemetry_locked(
    memory_base: Path,
    scope_ref: str,
    receipt: dict[str, Any],
    *,
    runtime_duration_ms: int | None = None,
) -> tuple[dict[str, Any], bool]:
    path = _telemetry_path(memory_base, scope_ref)
    prior_raw = _read_json(path)
    path_exists = path.exists()
    if path_exists and (not isinstance(prior_raw, dict) or not prior_raw):
        return {"schema": TELEMETRY_SCHEMA, "mode": MODE, "scopeRef": scope_ref, "code": "H7_RUNTIME_TELEMETRY_CORRUPT", "events": []}, False
    prior = prior_raw or {}
    prior_hash = ""
    if prior:
        prior_hash = canonical_hash({key: item for key, item in prior.items() if key != "payloadHash"})
        if (
            prior.get("schema") != TELEMETRY_SCHEMA
            or prior.get("mode") != MODE
            or str(prior.get("scopeRef", "")) != scope_ref
            or str(prior.get("payloadHash", "")) != prior_hash
        ):
            return {"schema": TELEMETRY_SCHEMA, "mode": MODE, "scopeRef": scope_ref, "code": "H7_RUNTIME_TELEMETRY_CORRUPT", "events": []}, False
    events = prior.get("events") if isinstance(prior.get("events"), list) else None
    if prior and (
        events is None
        or len(events) > MAX_TELEMETRY_EVENTS
        or any(not isinstance(item, dict) for item in events)
    ):
        # Do not silently drop malformed history and append a fresh event:
        # callers must repair the scope-local telemetry journal explicitly.
        return {"schema": TELEMETRY_SCHEMA, "mode": MODE, "scopeRef": scope_ref, "code": "H7_RUNTIME_TELEMETRY_CORRUPT", "events": []}, False
    events = events or []
    event = {
        "eventId": f"te-{str(receipt.get('receiptHash', ''))[:24]}",
        "at": str(receipt.get("issuedAt", "")),
        "phase": str(receipt.get("phase", "")),
        "receiptHash": str(receipt.get("receiptHash", "")),
        "activationReceiptHash": str((receipt.get("activation") or {}).get("receiptHash", "")),
        "contractStateHash": str((receipt.get("contract") or {}).get("stateHash", "")),
        "memorySnapshotHash": str((receipt.get("memory") or {}).get("snapshotPayloadHash", "")),
        "memoryRefsHash": str((receipt.get("memory") or {}).get("refsHash", "")),
        "coreRuleRegistryHash": str((receipt.get("coreRules") or {}).get("payloadHash", "")),
        "coreRuleEffectsHash": str((receipt.get("coreRules") or {}).get("activeEffectsHash", "")),
        "coreRuleApplicableHash": str((receipt.get("coreRules") or {}).get("applicableEffectsHash", "")),
        "turnIntentHash": str((receipt.get("turnIntent") or {}).get("payloadHash", "")),
        "projectProgressState": str((receipt.get("progressTruth") or {}).get("state", "withheld")),
        "projectProgressHash": str((receipt.get("progressTruth") or {}).get("payloadHash", "")),
        "visibleProgressState": str((receipt.get("visibleProgress") or {}).get("state", "withheld")),
        "visibleProgressHash": str((receipt.get("visibleProgress") or {}).get("payloadHash", "")),
        "visibleProgressSentenceHash": str((receipt.get("visibleProgress") or {}).get("sentenceHash", "")),
        "continuationCode": str((receipt.get("continuation") or {}).get("code", "")),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    if runtime_duration_ms is not None:
        event["runtimeDurationMs"] = max(0, min(60_000, int(runtime_duration_ms)))
    capability_route_receipt = receipt.get("capabilityRouteReceipt")
    if isinstance(capability_route_receipt, dict):
        event.update(
            {
                "capabilityRouteState": str(capability_route_receipt.get("state", "")),
                "capabilityRouteHash": str(capability_route_receipt.get("routeHash", "")),
                "capabilitySelectionHash": str(capability_route_receipt.get("selectionHash", "")),
                "capabilityRouteNonAuthorizing": capability_route_receipt.get("nonAuthorizing") is True,
            }
        )
    execution_assist = receipt.get("executionAssist")
    if execution_assist_receipt_is_valid(execution_assist):
        event.update(
            {
                "executionAssistState": str(execution_assist.get("state", "")),
                "executionAssistHash": str(execution_assist.get("payloadHash", "")),
                "executionAssistAutomatic": execution_assist.get("automatic") is True,
                "executionAssistNonAuthorizing": execution_assist.get("nonAuthorizing") is True,
            }
        )
    project_knowledge = receipt.get("projectKnowledge")
    if project_knowledge_receipt_is_valid(project_knowledge):
        event.update(
            {
                "projectKnowledgeState": str(project_knowledge.get("state", "")),
                "projectKnowledgeHash": str(project_knowledge.get("payloadHash", "")),
                "projectKnowledgeCoverage": str(project_knowledge.get("coverage", "")),
                "projectKnowledgeNonAuthorizing": project_knowledge.get("nonAuthorizing") is True,
            }
        )
    compatibility = receipt.get("capabilityRouteCompatibility")
    if _external_capability_route_compatibility_valid(compatibility):
        event.update(
            {
                "capabilityRouteCompatibilityHash": str(compatibility.get("payloadHash", "")),
                "capabilityRouteCompatibilityOnly": compatibility.get("cannotSelectCapabilities") is True,
            }
        )
    if any(isinstance(item, dict) and item.get("eventId") == event["eventId"] for item in events):
        return prior, True
    next_events = events[-(MAX_TELEMETRY_EVENTS - 1) :] + [event]
    value: dict[str, Any] = {
        "schema": TELEMETRY_SCHEMA,
        "mode": MODE,
        "scopeRef": scope_ref,
        "updatedAt": _utc_now(),
        "events": next_events,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    # This is a deterministic projection of the same already-bounded H7
    # telemetry. It does not read a project tree, create a cache, or gain any
    # authority over continuation and execution.
    value["runObservability"] = summarize_run_observability(value, expected_scope_ref=scope_ref)
    value["payloadHash"] = canonical_hash({key: item for key, item in value.items() if key != "payloadHash"})
    try:
        _atomic_json(path, value)
    except (OSError, TypeError, ValueError):
        return {"schema": TELEMETRY_SCHEMA, "mode": MODE, "scopeRef": scope_ref, "code": "H7_RUNTIME_STATE_WRITE_FAILED", "events": []}, False
    return value, False


def _public_receipt(value: dict[str, Any]) -> dict[str, Any]:
    result = {
        "receiptId": str(value.get("receiptId", "")),
        "receiptHash": str(value.get("receiptHash", "")),
        "phase": str(value.get("phase", "")),
        "issuedAt": str(value.get("issuedAt", "")),
        "bindingHash": str(value.get("bindingHash", "")),
        "activation": value.get("activation") if isinstance(value.get("activation"), dict) else {},
        "memory": value.get("memory") if isinstance(value.get("memory"), dict) else {},
        "agentIdentity": value.get("agentIdentity") if isinstance(value.get("agentIdentity"), dict) else {},
        "authorityModel": value.get("authorityModel") if isinstance(value.get("authorityModel"), dict) else {},
        "coreRules": value.get("coreRules") if isinstance(value.get("coreRules"), dict) else {},
        "turnIntent": value.get("turnIntent") if isinstance(value.get("turnIntent"), dict) else {},
        "progressTruth": value.get("progressTruth") if isinstance(value.get("progressTruth"), dict) else {},
        "visibleProgress": value.get("visibleProgress") if isinstance(value.get("visibleProgress"), dict) else {},
        "recoveryPresentation": value.get("recoveryPresentation") if isinstance(value.get("recoveryPresentation"), dict) else {},
        "continuation": value.get("continuation") if isinstance(value.get("continuation"), dict) else {},
    }
    if _capability_route_receipt_valid(value.get("capabilityRouteReceipt")):
        result["capabilityRouteReceipt"] = value["capabilityRouteReceipt"]
    if execution_assist_receipt_is_valid(value.get("executionAssist")):
        result["executionAssist"] = public_execution_assist(value["executionAssist"])
    if project_knowledge_receipt_is_valid(value.get("projectKnowledge")):
        result["projectKnowledge"] = value["projectKnowledge"]
    if _external_capability_route_compatibility_valid(value.get("capabilityRouteCompatibility")):
        result["capabilityRouteCompatibility"] = value["capabilityRouteCompatibility"]
    return result


def _receipt_valid(
    value: dict[str, Any] | None,
    *,
    phase: str,
    scope_ref: str,
    contract_hash: str,
    core_rules: dict[str, Any],
    project_progress: dict[str, Any] | None = None,
    visible_progress: dict[str, Any] | None = None,
    project_knowledge: dict[str, Any] | None = None,
) -> bool:
    if not isinstance(value, dict):
        return False
    if value.get("schema") != RECEIPT_SCHEMA or value.get("mode") != MODE or value.get("phase") != phase:
        return False
    scope = value.get("scope") if isinstance(value.get("scope"), dict) else {}
    contract = value.get("contract") if isinstance(value.get("contract"), dict) else {}
    if str(scope.get("scopeRef", "")) != scope_ref or str(contract.get("stateHash", "")) != contract_hash:
        return False
    expected_progress = project_progress if isinstance(project_progress, dict) else {}
    if expected_progress:
        if (
            str(contract.get("projectProgressState", "withheld")) != str(expected_progress.get("state", "withheld"))
            or str(contract.get("projectProgressHash", "")) != str(expected_progress.get("payloadHash", ""))
        ):
            return False
    expected_visible = visible_progress if isinstance(visible_progress, dict) else {}
    if expected_visible:
        receipt_visible = value.get("visibleProgress") if isinstance(value.get("visibleProgress"), dict) else {}
        if (
            str(receipt_visible.get("state", "withheld")) != str(expected_visible.get("state", "withheld"))
            or str(receipt_visible.get("payloadHash", "")) != str(expected_visible.get("payloadHash", ""))
            or str(receipt_visible.get("sentenceHash", "")) != str(expected_visible.get("sentenceHash", ""))
            or str(receipt_visible.get("projectProgressPayloadHash", "")) != str(expected_visible.get("projectProgressPayloadHash", ""))
        ):
            return False
    capability_route_receipt = value.get("capabilityRouteReceipt")
    if capability_route_receipt is not None and not _capability_route_receipt_valid(capability_route_receipt):
        return False
    execution_assist = value.get("executionAssist")
    if not execution_assist_receipt_is_valid(execution_assist):
        return False
    expected_knowledge = public_project_knowledge(project_knowledge) if isinstance(project_knowledge, dict) else None
    receipt_knowledge = value.get("projectKnowledge")
    if expected_knowledge is not None:
        if not project_knowledge_receipt_is_valid(receipt_knowledge):
            return False
        if str(receipt_knowledge.get("payloadHash", "")) != str(expected_knowledge.get("payloadHash", "")):
            return False
    compatibility = value.get("capabilityRouteCompatibility")
    if compatibility is not None and not _external_capability_route_compatibility_valid(compatibility):
        return False
    receipt_rules = value.get("coreRules") if isinstance(value.get("coreRules"), dict) else {}
    if (
        core_rules.get("status") != "current"
        or str(receipt_rules.get("payloadHash", "")) != str(core_rules.get("payloadHash", ""))
        or str(receipt_rules.get("activeEffectsHash", "")) != str(core_rules.get("activeEffectsHash", ""))
    ):
        return False
    intent = value.get("turnIntent") if isinstance(value.get("turnIntent"), dict) else {}
    if (
        intent.get("ok") is not True
        or not str(intent.get("payloadHash", ""))
        or str(intent.get("payloadHash", "")) != context_hash({key: item for key, item in intent.items() if key not in {"payloadHash", "ok", "code"}})
    ):
        return False
    expected = canonical_hash({key: item for key, item in value.items() if key != "receiptHash"})
    return str(value.get("receiptHash", "")) == expected


def _telemetry_valid(
    value: dict[str, Any] | None,
    *,
    scope_ref: str,
    core_rules: dict[str, Any],
    intent_hash: str = "",
    project_progress: dict[str, Any] | None = None,
    visible_progress: dict[str, Any] | None = None,
    execution_assist: dict[str, Any] | None = None,
    project_knowledge: dict[str, Any] | None = None,
    capability_route_receipt: dict[str, Any] | None = None,
) -> bool:
    if not isinstance(value, dict):
        return False
    if value.get("schema") != TELEMETRY_SCHEMA or value.get("mode") != MODE or str(value.get("scopeRef", "")) != scope_ref:
        return False
    expected = canonical_hash({key: item for key, item in value.items() if key != "payloadHash"})
    events = value.get("events") if isinstance(value.get("events"), list) else []
    latest = events[-1] if events and isinstance(events[-1], dict) else {}
    expected_progress = project_progress if isinstance(project_progress, dict) else {}
    progress_current = (
        not expected_progress
        or (
            str(latest.get("projectProgressState", "withheld")) == str(expected_progress.get("state", "withheld"))
            and str(latest.get("projectProgressHash", "")) == str(expected_progress.get("payloadHash", ""))
        )
    )
    expected_visible = visible_progress if isinstance(visible_progress, dict) else {}
    visible_current = (
        not expected_visible
        or (
            str(latest.get("visibleProgressState", "withheld")) == str(expected_visible.get("state", "withheld"))
            and str(latest.get("visibleProgressHash", "")) == str(expected_visible.get("payloadHash", ""))
            and str(latest.get("visibleProgressSentenceHash", "")) == str(expected_visible.get("sentenceHash", ""))
        )
    )
    capability_route_current = (
        capability_route_receipt is None
        or (
            str(latest.get("capabilityRouteState", "")) == str(capability_route_receipt.get("state", ""))
            and str(latest.get("capabilityRouteHash", "")) == str(capability_route_receipt.get("routeHash", ""))
            and str(latest.get("capabilitySelectionHash", "")) == str(capability_route_receipt.get("selectionHash", ""))
            and latest.get("capabilityRouteNonAuthorizing") is True
        )
    )
    expected_execution_assist = execution_assist if execution_assist_receipt_is_valid(execution_assist) else None
    execution_assist_current = (
        expected_execution_assist is None
        or (
            str(latest.get("executionAssistState", "")) == str(expected_execution_assist.get("state", ""))
            and str(latest.get("executionAssistHash", "")) == str(expected_execution_assist.get("payloadHash", ""))
            and latest.get("executionAssistAutomatic") is True
            and latest.get("executionAssistNonAuthorizing") is True
        )
    )
    expected_knowledge = public_project_knowledge(project_knowledge) if isinstance(project_knowledge, dict) else None
    knowledge_current = (
        expected_knowledge is None
        or (
            project_knowledge_receipt_is_valid(expected_knowledge)
            and str(latest.get("projectKnowledgeState", "")) == str(expected_knowledge.get("state", ""))
            and str(latest.get("projectKnowledgeHash", "")) == str(expected_knowledge.get("payloadHash", ""))
            and latest.get("projectKnowledgeNonAuthorizing") is True
        )
    )
    observability = value.get("runObservability")
    observability_current = True
    if observability is not None:
        expected_observability = summarize_run_observability(value, expected_scope_ref=scope_ref)
        observability_current = (
            run_observability_receipt_is_valid(observability, expected_scope_ref=scope_ref)
            and str(observability.get("payloadHash", ""))
            == str(expected_observability.get("payloadHash", ""))
        )
    elif any(isinstance(item, dict) and "runtimeDurationMs" in item for item in events):
        # New measured events must carry the matching compact summary. Old
        # telemetry remains readable as historical compatibility evidence.
        observability_current = False
    return (
        str(value.get("payloadHash", "")) == expected
        and core_rules.get("status") == "current"
        and str(latest.get("coreRuleRegistryHash", "")) == str(core_rules.get("payloadHash", ""))
        and str(latest.get("coreRuleEffectsHash", "")) == str(core_rules.get("activeEffectsHash", ""))
        and (not intent_hash or str(latest.get("turnIntentHash", "")) == intent_hash)
        and progress_current
        and visible_current
        and execution_assist_current
        and knowledge_current
        and capability_route_current
        and observability_current
    )


def _withheld(phase: str, context: dict[str, Any], code: str) -> dict[str, Any]:
    return {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": phase,
        "available": False,
        "code": code,
        "context": context,
        "terminalReplyAllowed": True,
        "mustContinue": False,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _scope_authorization_guard(
    core: BrainCore,
    *,
    phase: str,
    write: bool,
    context: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Require the provider lease before any turn-runtime side effect.

    MCP performs an early read-side binding check for friendly diagnostics,
    but that adapter check is not an authority boundary.  The runtime itself
    must refresh the provider lease immediately before activation, receipt,
    telemetry, checkpoint, or close writes so direct CLI/internal callers
    cannot bypass the broker by calling ``turn_runtime`` directly.
    """

    try:
        authorization = core.authorize_scope(write=write)
    except Exception:
        authorization = {
            "ok": False,
            "state": "withheld",
            "code": "H7_SCOPE_PROVIDER_UNAVAILABLE",
        }
    if isinstance(authorization, dict) and authorization.get("ok") is True:
        # A trusted control surface may explicitly detach and re-pair a live
        # channel between the read-side context build and this write-side lease
        # check.  Never use the fresh lease for a context produced by the old
        # workline.  Broker projections carry task/instance/contract fields;
        # legacy CLI providers simply omit those extra comparisons.
        expected_scope = context.get("scope") if isinstance(context, dict) and isinstance(context.get("scope"), dict) else {}
        expected_task = context.get("task") if isinstance(context, dict) and isinstance(context.get("task"), dict) else {}
        actual_scope = (
            authorization.get("scope")
            if isinstance(authorization.get("scope"), dict)
            else authorization.get("h7Scope")
            if isinstance(authorization.get("h7Scope"), dict)
            else authorization
        )
        expected = {
            "workspaceKey": str(expected_scope.get("workspaceKey", "")).strip().lower(),
            "ownerSessionKey": str(expected_scope.get("ownerSessionKey", "")).strip().lower(),
            "taskId": str(expected_task.get("taskId", "")).strip(),
            "taskInstanceId": str(expected_task.get("taskInstanceId", "")).strip().lower(),
            "contractHash": str(expected_task.get("contractHash", "")).strip().lower(),
        }
        actual = {
            "workspaceKey": str(actual_scope.get("workspaceKey", "")).strip().lower(),
            "ownerSessionKey": str(actual_scope.get("ownerSessionKey", "")).strip().lower(),
            "taskId": str(actual_scope.get("taskId", "")).strip(),
            "taskInstanceId": str(actual_scope.get("taskInstanceId", "")).strip().lower(),
            "contractHash": str(actual_scope.get("contractHash", "")).strip().lower(),
        }
        # There is no context to bind for checkpoint/close's first preflight;
        # ``open_turn`` will repeat the same check after it has constructed one.
        # If a provider does expose a field, it must agree exactly.  A Broker
        # provider exposes all five, so a same-workspace re-pair cannot slip
        # through merely because workspace/session happen to match.
        mismatch = any(
            expected[key]
            and actual[key]
            and expected[key] != actual[key]
            for key in expected
        )
        broker_provider = str(getattr(getattr(core, "_scope_provider", None), "provider_kind", "")) == "scope_broker_channel"
        broker_missing = broker_provider and any(expected[key] and not actual[key] for key in expected)
        if not mismatch and not broker_missing:
            return None
        result = _withheld(
            phase,
            context if isinstance(context, dict) else {},
            "H7_SCOPE_REBIND_DURING_OPERATION",
        )
        result["scopeAuthorization"] = {
            "state": "withheld",
            "code": "H7_SCOPE_REBIND_DURING_OPERATION",
            "accessMode": str(authorization.get("accessMode", "write" if write else "read")),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        try:
            result["scopeBinding"] = core.scope_status()
        except Exception:
            result["scopeBinding"] = {
                "state": "withheld",
                "code": "H7_SCOPE_PROVIDER_UNAVAILABLE",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        return result
    value = authorization if isinstance(authorization, dict) else {}
    result = _withheld(
        phase,
        context if isinstance(context, dict) else {},
        str(value.get("code", "H7_SCOPE_AUTHORIZATION_REQUIRED")),
    )
    # Keep the denial bounded and diagnostic; never copy a pairing token,
    # lease id, contract body, or other private provider material into the
    # runtime response.
    result["scopeAuthorization"] = {
        "state": str(value.get("state", "withheld")),
        "code": str(value.get("code", "H7_SCOPE_AUTHORIZATION_REQUIRED")),
        "accessMode": str(value.get("accessMode", "write" if write else "read")),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    try:
        result["scopeBinding"] = core.scope_status()
    except Exception:
        result["scopeBinding"] = {
            "state": "withheld",
            "code": "H7_SCOPE_PROVIDER_UNAVAILABLE",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    return result


_RETIRED_HOST_TRANSPORT_FIELDS = frozenset(
    {
        "host_readback_projection",
        "host_thread_payload",
        "host_visible_context",
        "visible_progress_assertion",
    }
)


def _retired_host_transport_result(phase: str, **values: Any) -> dict[str, Any] | None:
    """Reject legacy Host payloads without inspecting or normalizing them."""

    supplied = sorted(
        field
        for field in _RETIRED_HOST_TRANSPORT_FIELDS
        if values.get(field) is not None
    )
    if not supplied:
        return None
    result = _withheld(phase, {}, "H7_HOST_TRANSPORT_RETIRED")
    result["retiredInputs"] = supplied
    return result


def _public_continuity_mapping(mapping: dict[str, Any] | None) -> dict[str, Any]:
    """Return a compact non-sensitive local continuity projection.

    It makes the normal continuation decision observable without leaking the
    visible reply, raw task id, workspace path, or a private contract body.
    The mapping is a read-only diagnostic bridge, never a second task card.
    """

    value = mapping if isinstance(mapping, dict) else {}
    source_state = str(value.get("state", "unavailable"))
    # ``BrainCore`` keeps the read-side state deliberately small.  The public
    # runtime projection spells out that a mapped record belongs to the active
    # local contract, so callers do not mistake it for a task selected from an
    # external message or transport.
    state = "mapped_current_workline" if source_state == "mapped" else source_state
    project_progress_state = str(value.get("projectProgressState", value.get("projectProofState", "not_checked")))
    visible_progress_state = str(value.get("visibleProgressState", "not_checked"))
    stage_advance_allowed = bool(value.get("stageAdvanceAllowed") is True or value.get("formalActionAllowed") is True)
    duplicate_action_blocked = bool(
        value.get("duplicateActionBlocked") is True
        or value.get("duplicateActionPrevented") is True
    )
    result = {
        "schema": "super-brain.continuity-mapping.v1",
        "state": state,
        "code": str(value.get("code", "H7_LOCAL_CONTRACT_MAPPING_REQUIRED")),
        "source": str(value.get("source", "scoped_local_contract")),
        "visibleContextAvailable": bool(value.get("visibleContextAvailable") is True),
        "stateCardUsed": bool(value.get("stateCardUsed") is True),
        "taskIdHash": str(value.get("taskIdHash", "")),
        "taskInstanceId": str(value.get("taskInstanceId", "")),
        "contractRevision": int(value.get("contractRevision", 0) or 0),
        "contractHash": str(value.get("contractHash", "")),
        "currentPhase": _compact(value.get("currentPhase"), 160),
        "currentStep": _compact(value.get("currentStep"), 240),
        "nextAction": _compact(value.get("nextAction"), 360),
        # The first three names are the canonical R6 contract.  The following
        # three are retained as non-authorizing compatibility projections for
        # already-installed adapters while they refresh.
        "projectProgressState": project_progress_state,
        "stageAdvanceAllowed": stage_advance_allowed,
        "duplicateActionBlocked": duplicate_action_blocked,
        "projectProofState": project_progress_state,
        "visibleProgressState": visible_progress_state,
        "formalActionAllowed": stage_advance_allowed,
        "duplicateActionPrevented": duplicate_action_blocked,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    result["payloadHash"] = canonical_hash({key: item for key, item in result.items() if key != "payloadHash"})
    return result


def _withheld_continuity_mapping(
    context: dict[str, Any],
    code: str,
    mapping: dict[str, Any] | None,
) -> dict[str, Any]:
    """Return one fail-closed result with local mapping diagnostics."""

    public_mapping = _public_continuity_mapping(mapping)
    projected_context = dict(context) if isinstance(context, dict) else {}
    projected_context["continuityMapping"] = public_mapping
    result = _withheld("open", projected_context, code)
    result["continuityMapping"] = public_mapping
    return result


def _is_nonblocking_continuity_intent(intent: dict[str, Any]) -> bool:
    """Return whether this open may report current mapping before strict proof.

    This does not grant an action.  It merely lets a continuation/status or
    correction response report that the live proof needs repair instead of
    falling back to an old card or pretending the task has no current state.
    Checkpoint, close, formal stage, design, and high-impact paths retain their
    existing proof gates.
    """

    return str(intent.get("kind", "")) in {
        "continuity",
        "task_status",
        "super_brain_issue_continuity",
        "user_correction",
    }


def _ordinary_no_task_open(
    core: BrainCore,
    *,
    intent: dict[str, Any],
    mapping: dict[str, Any],
    normalized_recovery_event: str,
) -> dict[str, Any]:
    """Return the governed, taskless path without allocating a task/card.

    A Super Brain route may participate in ordinary conversation and correctly
    continue it without inventing a task.  This result creates no execution
    contract, local progress card, telemetry, task card, or memory body.  It
    does retain the ordinary H7 activation receipt: the brain is active, but
    there is no workline state to resume.
    """

    core_rules = core.core_rules(tuple(["control_plane_agent"] + [str(item) for item in (intent.get("ruleSignals") or [])]))
    # A no-task continuation is a controller readback, not a lifecycle turn.
    # Do not create an activation receipt, runtime-state file, task card, or
    # telemetry just because a user continued ordinary prose.
    activation = {
        "state": "not_applicable",
        "code": "H7_NO_TASK_NO_RUNTIME_STATE",
        "activationId": "",
        "receiptHash": "",
        "scopeRef": "",
        "coreReady": True,
        "task": {"state": "none"},
        "actionAuthorization": "not_applicable",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    ready = True
    result = {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": "open",
        "available": ready,
        "code": "TURN_RUNTIME_OPEN_NO_TASK_READY" if ready else "H7_NO_TASK_ACTIVATION_WITHHELD",
        "context": {
            "schema": "super-brain.context.v1",
            "available": ready,
            "code": "BRAIN_CONTEXT_NO_ACTIVE_CONTRACT",
            "agentIdentity": agent_identity(),
            "coreRules": core_rules,
            "scope": {
                "workspaceKey": str(mapping.get("workspaceKey", "")),
                "ownerSessionKey": str(mapping.get("ownerSessionKey", "")),
            },
            "task": {"state": "none", "actionAuthorization": "not_applicable"},
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        },
        "activation": activation,
        "continuityMapping": _public_continuity_mapping(
            {
                **mapping,
                "projectProgressState": "not_applicable",
                "visibleProgressState": "not_applicable",
                "stageAdvanceAllowed": False,
                "duplicateActionBlocked": True,
            }
        ),
        "recoveryPresentation": {
            "schema": RECOVERY_PRESENTATION_SCHEMA,
            "state": "not_applicable",
            "code": "H7_RECOVERY_PRESENTATION_NO_TASK",
            "event": normalized_recovery_event,
            "required": False,
            "openingLine": "",
            "nonAuthorizing": True,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        },
        "terminalReplyAllowed": True,
        "mustContinue": False,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return result


def _lightweight_task_pointer_probe(core: BrainCore) -> dict[str, Any]:
    """Read only the current local task pointer before a governed open.

    Continuation and status routes need to distinguish a taskless turn from a
    broken local scope, but they do not need the full core-rules, identity,
    memory, project-proof, or capability pipeline to make that distinction.
    The probe deliberately uses the runtime-owned current pointer and returns
    opaque scope metadata only.
    """

    try:
        workspace_key = str(core._current_workspace_key())
        session_key = str(core._current_session_key())
    except (AttributeError, OSError, RuntimeError):
        return {"state": "unavailable", "code": "H7_LOCAL_TASK_POINTER_UNAVAILABLE"}
    if not workspace_key:
        return {"state": "unavailable", "code": "H7_WORKSPACE_UNAVAILABLE"}
    if not session_key:
        return {
            "state": "unavailable",
            "code": "H7_LOCAL_SESSION_MISSING",
            "workspaceKey": workspace_key,
        }
    # A current-task pointer is a derived, non-authorizing hint, but a valid
    # one is enough to avoid proving tasklessness here.  The caller performs
    # the authoritative fresh contract read immediately afterwards through
    # ``core.context``.  Checking this hint first therefore avoids parsing
    # the hot index and contract twice on the common active-continuation path,
    # without allowing a pointer to authorize a task or a transition.
    try:
        pointer = core._read_current_context_pointer(workspace_key, session_key)
    except (AttributeError, OSError, RuntimeError, ValueError):
        pointer = None
    if isinstance(pointer, dict):
        return {
            "state": "active",
            "code": "H7_LOCAL_SCOPE_ACTIVE_TASK_POINTER",
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "taskId": str(pointer.get("taskId", "")),
            "taskInstanceId": str(pointer.get("taskInstanceId", "")),
            "currentStep": str(pointer.get("currentStep", "")),
            "nextAction": str(pointer.get("nextAction", "")),
        }
    try:
        current, contract_code = core._read_context_contract(workspace_key, session_key)
    except (AttributeError, OSError, RuntimeError, ValueError):
        return {
            "state": "unavailable",
            "code": "H7_LOCAL_TASK_POINTER_UNAVAILABLE",
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
        }
    if isinstance(current, dict):
        return {
            "state": "active",
            "code": "H7_LOCAL_SCOPE_ACTIVE_TASK",
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "taskId": str(current.get("taskId", "")),
            "taskInstanceId": str(current.get("taskInstanceId", "")),
            "currentStep": str(current.get("currentStep", "")),
            "nextAction": str(current.get("nextAction", "")),
        }
    # A pending reconciliation is still an active task.  It must reach the
    # existing reconciliation gate instead of being mistaken for a taskless
    # continuation and silently downgraded.
    if str(contract_code) == "BRAIN_CONTEXT_RECONCILIATION_REQUIRED":
        return {
            "state": "active",
            "code": str(contract_code),
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
        }
    # Only the contract reader's explicit no-contract result proves that the
    # current local scope is genuinely taskless.  A missing or mismatched hot
    # index is a broken derived binding and must remain fail-closed; treating
    # it as an empty task scope would silently downgrade repair to taskless.
    if str(contract_code) != "BRAIN_CONTEXT_NO_ACTIVE_CONTRACT":
        return {
            "state": "unavailable",
            "code": str(contract_code or "H7_LOCAL_TASK_POINTER_UNAVAILABLE"),
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
        }
    if not isinstance(pointer, dict):
        return {
            "state": "none",
            "code": "H7_LOCAL_SCOPE_NO_ACTIVE_TASK",
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
        }


def _direct_local_path(phase: str, intent: dict[str, Any]) -> dict[str, Any]:
    return {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": phase,
        "available": False,
        "code": "TURN_INTENT_DIRECT_PATH",
        "turnIntent": public_turn_intent(intent),
        "continuityMapping": _public_continuity_mapping(
            {
                "state": "ordinary_no_task",
                "source": "none",
                "visibleContextAvailable": False,
                "stateCardUsed": False,
                "projectProgressState": "not_applicable",
                "visibleProgressState": "not_applicable",
                "stageAdvanceAllowed": False,
                "duplicateActionBlocked": True,
            }
        ),
        "terminalReplyAllowed": True,
        "mustContinue": False,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _current_contract_policy_resolution(contract: dict[str, Any]) -> dict[str, Any]:
    """Build the same bounded no-mutation policy input as ``BrainCore``.

    This never grants a mutation.  It exists solely for the strict
    ``continue_current_turn`` fast close below, where the authority would
    otherwise launch PowerShell just to return a pure policy result.
    """

    canonical_plan = contract.get("canonicalPlan") if isinstance(contract.get("canonicalPlan"), dict) else {}
    items = canonical_plan.get("items") if isinstance(canonical_plan.get("items"), list) else []
    statuses = [str(item.get("status", "")) for item in items if isinstance(item, dict)]
    canonical_summary = (
        {
            "itemCount": len(items),
            "completedCount": sum(status == "completed" for status in statuses),
            "pendingCount": sum(status in {"pending", "in_progress"} for status in statuses),
            "cancelledCount": sum(status == "cancelled" for status in statuses),
        }
        if items and len(statuses) == len(items)
        else {}
    )
    return {
        "ok": True,
        "actionAuthorization": "allowed",
        "claimAllowed": True,
        "needsConfirmation": False,
        "blockers": list(contract.get("blockers", []) or []),
        "nextAction": str(contract.get("nextAction", "")),
        "currentPhase": str(contract.get("currentPhase", "")),
        "canonicalPlan": canonical_summary,
        "canResumeParent": bool(contract.get("returnStack")),
    }


def _policy_only_fast_close(
    context: dict[str, Any],
    contract: dict[str, Any],
    progress_status: dict[str, Any],
    close_intent: dict[str, Any],
    *,
    turn_outcome: str,
    user_control: str,
    completion_evidence_present: bool,
    checkpoint_present: bool,
) -> dict[str, Any] | None:
    """Return a safe in-process close policy, or ``None`` for full authority.

    The guard is intentionally narrower than a generic close.  It allows only
    an ordinary, non-terminal, non-formal no-op close after the current
    contract and proof have just been re-read in this call.  Every mutation,
    parent return, checkpoint, formal closeout, stale proof, or ambiguity
    remains on the existing PowerShell authority path.
    """

    if checkpoint_present or completion_evidence_present:
        return None
    if user_control != "none" or turn_outcome not in {"ephemeral_insertion", "active_work_progressed"}:
        return None
    if contract.get("needsReconciliation") is True or is_formal_phase(str(contract.get("currentPhase", ""))):
        return None
    if progress_status.get("current") is not True:
        return None
    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    visible = task.get("visibleProgress") if isinstance(task.get("visibleProgress"), dict) else {}
    if visible.get("state") != "current" or visible.get("continuationEligible") is not True:
        return None
    if close_intent.get("governed") is not True:
        return None
    policy = decide_turn_close(
        _current_contract_policy_resolution(contract),
        turn_outcome=turn_outcome,
        user_control=user_control,
        completion_evidence_present=False,
    )
    return policy if policy.get("decision") == "continue_current_turn" else None


def open_turn(
    core: BrainCore,
    *,
    memory_mode: str = "auto",
    record_telemetry: bool = True,
    persist_receipt: bool = True,
    turn_intent: str = "direct",
    recovery_event: str = "none",
    execution_assist_request: Any = None,
    capability_route_receipt: Any = None,
    _execution_assist_bundle: Any = None,
    user_control: str = "unknown",
    execution_apply_phase: str = "planning",
    allow_terminal_finalization: bool = False,
    allow_reconciliation_checkpoint: bool = False,
    terminal_finalization_phase: str = "",
    return_private_bundle: bool = False,
    timeout: float = 8.0,
    **legacy_transport: Any,
) -> dict[str, Any]:
    """Build one scope-bound memory/continuity packet and receipt.

    The context projection is still the source of truth; this function merely
    binds that projection to a governed activation and a bounded receipt.

    Internal preflights may need an ephemeral receipt while verifying a later
    checkpoint or close transition.  Those calls must not replace the last
    persisted open receipt unless they also record matching telemetry: doing so
    would make otherwise-current H7 evidence look torn after a rejected
    preflight.
    """

    retired = _retired_host_transport_result("open", **legacy_transport)
    if retired is not None:
        return retired
    if any(value is not None for value in legacy_transport.values()):
        return _withheld("open", {}, "TURN_RUNTIME_ARGUMENTS_INVALID")

    started_at = time.perf_counter()
    intent = resolve_turn_intent(turn_intent, memory_mode=memory_mode)
    if intent.get("ok") is not True:
        return _withheld("open", {"turnIntent": public_turn_intent(intent)}, str(intent.get("code", "TURN_INTENT_INVALID")))
    if intent.get("governed") is not True:
        return _direct_local_path("open", intent)
    # A telemetry event is evidence for a durable H7 entry.  Writing one for
    # an ephemeral preflight receipt would recreate the exact split-brain
    # state this runtime is designed to reject: telemetry points at an entry
    # that cannot be read back from ``receipts/<scope>/open.json``.
    if record_telemetry and not persist_receipt:
        return _withheld(
            "open",
            {"turnIntent": public_turn_intent(intent)},
            "H7_OPEN_TELEMETRY_WITHOUT_PERSISTED_ENTRY_FORBIDDEN",
        )
    normalized_recovery_event = str(recovery_event or "none")
    if normalized_recovery_event not in RECOVERY_EVENTS:
        return _withheld("open", {"turnIntent": public_turn_intent(intent)}, "H7_RECOVERY_EVENT_INVALID")

    # Continuation/status is allowed to stop at the current task pointer.  A
    # taskless scope must not pay for capability routing or a full context
    # open just to discover that there is nothing to resume.
    normal_continuity = str(intent.get("kind", "")) in NORMAL_CONTINUITY_INTENTS
    if normal_continuity:
        pointer = _lightweight_task_pointer_probe(core)
        if pointer.get("state") == "none":
            return _ordinary_no_task_open(
                core,
                intent=intent,
                mapping={
                    "state": "ordinary_no_task",
                    "code": str(pointer.get("code", "H7_LOCAL_SCOPE_NO_ACTIVE_TASK")),
                    "source": "scoped_local_task_pointer",
                    "visibleContextAvailable": False,
                    "stateCardUsed": False,
                    "workspaceKey": str(pointer.get("workspaceKey", "")),
                    "ownerSessionKey": str(pointer.get("ownerSessionKey", "")),
                },
                normalized_recovery_event=normalized_recovery_event,
            )
    if (
        str(intent.get("kind", "")) == "direct"
        and str(intent.get("memoryMode", memory_mode)) in {"auto", "off"}
        and execution_assist_request is None
        and capability_route_receipt is None
        and _execution_assist_bundle is None
    ):
        pointer = _lightweight_task_pointer_probe(core)
        if pointer.get("state") == "none":
            return _direct_local_path("open", intent)
    reused_execution_assist = _validated_execution_assist_bundle(_execution_assist_bundle)
    if reused_execution_assist is not None:
        execution_assist, normalized_capability_route_receipt, capability_route_compatibility, execution_assist_code = (
            reused_execution_assist
        )
    else:
        execution_assist, normalized_capability_route_receipt, capability_route_compatibility, execution_assist_code = (
            _resolve_execution_assist_for_turn(
                core,
                intent,
                execution_assist_request,
                capability_route_receipt,
                apply_phase=execution_apply_phase,
            )
        )
    if execution_assist is None or normalized_capability_route_receipt is None:
        return _withheld(
            "open",
            {"turnIntent": public_turn_intent(intent)},
            execution_assist_code or "H7_EXECUTION_ASSIST_UNAVAILABLE",
        )
    # Local-only continuity ---------------------------------------------------------
    #
    # External transport is permanently retired.  The current cwd/session scope,
    # execution contract, project proof, and local progress receipt are the
    # only continuity inputs.  Legacy Host fields were rejected above before
    # normalization, so this branch cannot accidentally reintroduce a tail
    # parser or a retrying bridge.
    # A normal read-only continuation asks ``core.context`` for the exact local
    # contract and proof once. The private snapshot is call-local and avoids a
    # duplicate read/hash cycle without becoming durable authority.
    normal_context_snapshot_requested = (
        str(intent.get("kind", "")) in {"continuity", "task_status"}
        and normalized_recovery_event == "none"
        and record_telemetry is True
        and persist_receipt is True
        and not allow_terminal_finalization
        and not allow_reconciliation_checkpoint
    )
    continuity_mapping: dict[str, Any] | None = None
    effective_memory_mode = str(intent.get("memoryMode", memory_mode))
    governed_rule_signals = tuple(
        dict.fromkeys(
            ["control_plane_agent"]
            + [str(item) for item in (intent.get("ruleSignals") or ()) if str(item).strip()]
            + (
                ["four_quadrant", "native_capability"]
                if str(execution_assist.get("state", "")) != "not_applicable"
                else []
            )
        )
    )
    context = core.context(
        effective_memory_mode,
        "unknown",
        "unknown",
        False,
        governed_rule_signals,
        terminal_finalization=allow_terminal_finalization,
        reconciliation_checkpoint=allow_reconciliation_checkpoint,
        turn_runtime_snapshot=normal_context_snapshot_requested,
        terminal_finalization_phase=terminal_finalization_phase,
    )
    # Remove private contract/proof data before any branch can return the
    # public context. A malformed snapshot simply falls back to the fresh
    # binding path; it never changes the governed result.
    private_context_snapshot = (
        _take_context_turn_runtime_snapshot(context)
        if isinstance(context, dict)
        else None
    )
    if (
        isinstance(context, dict)
        and context.get("ok") is True
        and context.get("available") is not True
        and str(context.get("code", "")) == "BRAIN_CONTEXT_NO_ACTIVE_CONTRACT"
        and normal_continuity
    ):
        return _ordinary_no_task_open(
            core,
            intent=intent,
            mapping={
                "state": "ordinary_no_task",
                "code": "H7_LOCAL_SCOPE_NO_ACTIVE_TASK",
                "source": "scoped_local_contract",
                "visibleContextAvailable": False,
                "stateCardUsed": False,
                "workspaceKey": core._context_workspace_key(),
                "ownerSessionKey": core._context_session_key(),
            },
            normalized_recovery_event=normalized_recovery_event,
        )
    if not isinstance(context, dict) or context.get("ok") is not True or context.get("available") is not True:
        return _withheld_continuity_mapping(
            context if isinstance(context, dict) else {},
            str((context or {}).get("code", "TURN_RUNTIME_CONTEXT_INVALID")),
            continuity_mapping,
        )
    context["turnIntent"] = public_turn_intent(intent)
    context["executionAssist"] = public_execution_assist(execution_assist)
    if capability_route_compatibility is not None:
        context["capabilityRouteCompatibility"] = capability_route_compatibility
    contract, contract_code = _contract_binding(
        core,
        context,
        allow_reconciliation_checkpoint=allow_reconciliation_checkpoint,
        private_context_snapshot=private_context_snapshot,
        terminal_finalization_phase=terminal_finalization_phase,
    )
    if contract is None:
        return _withheld_continuity_mapping(context, contract_code, continuity_mapping)
    if context.get("reconciliationCheckpointOnly") is True:
        # A pending instruction is never an ordinary runnable context.  The
        # explicit checkpoint caller receives this exact, scope-bound packet
        # only long enough to atomically bind its current instruction, proof,
        # and progress through the existing CAS authority below.
        return _withheld(
            "open",
            context,
            "H7_RECONCILIATION_CHECKPOINT_REQUIRED",
        )
    snapshot_contract = (
        private_context_snapshot.get("contract")
        if isinstance(private_context_snapshot, dict)
        else None
    )
    snapshot_progress_status = (
        private_context_snapshot.get("projectProgressStatus")
        if isinstance(private_context_snapshot, dict)
        else None
    )
    progress_status = (
        snapshot_progress_status
        if contract is snapshot_contract and isinstance(snapshot_progress_status, dict)
        else core._project_progress_status(contract)
    )
    strict_open = str(intent.get("kind", "")) in FORMAL_OPEN_INTENTS
    # Formal opens and non-continuation turns retain the strict local proof
    # gates; ordinary local continuity may report stale proof for repair.
    strict_state_preflight = strict_open or (
        not normal_continuity and normalized_recovery_event == "none"
    )
    if strict_state_preflight and intent.get("projectEvidenceRequired") is True and progress_status.get("current") is not True:
        return _withheld("open", context, "H7_PROJECT_PROGRESS_WITHHELD")
    visible_progress_status = (
        (context.get("task") or {}).get("visibleProgress")
        if isinstance(context.get("task"), dict)
        else {}
    )
    if strict_state_preflight and (
        not isinstance(visible_progress_status, dict)
        or visible_progress_status.get("state") != "current"
    ):
        return _withheld(
            "open",
            context,
            str((visible_progress_status or {}).get("code", "H7_VISIBLE_PROGRESS_RECEIPT_REQUIRED")),
        )
    if strict_state_preflight and (
        isinstance(visible_progress_status, dict)
        and visible_progress_status.get("continuationEligible") is not True
    ):
        # ``user_attested_visible_reply`` is deliberately a one-way
        # reconciliation bridge: it can repair a missing/stale anchor, but
        # cannot by itself authorize ordinary work.  A following H7
        # checkpoint must be sourced from the exact assistant-visible progress
        # sentence that will be shown to the user.
        return _withheld("open", context, "H7_VISIBLE_PROGRESS_ASSISTANT_REPLY_REQUIRED")
    # A verified parent return may use its existing state card. Every other
    # continuity/recovery projection is built from the current local contract.
    parent_return_state_card: dict[str, Any] | None = None
    if normalized_recovery_event == "parent_return":
        parent_return_state_card, parent_return_code = _parent_return_state_card(context, contract)
        if parent_return_state_card is None:
            return _withheld("open", context, parent_return_code)
        # This is the sole legal state-card selector.  It maps the already
        # approved parent after a verified ResumeParent transition; normal
        # Local continuation never allows an unrelated card to displace the
        # current contract.
        continuity_mapping = {
            "state": "mapped_parent_return",
            "code": parent_return_code,
            "source": "verified_parent_return",
            "visibleContextAvailable": False,
            "stateCardUsed": True,
            "taskIdHash": hashlib.sha256(str(contract.get("taskId", "")).encode("utf-8")).hexdigest(),
            "taskInstanceId": str(contract.get("taskInstanceId", "")),
            "contractRevision": int(contract.get("revision", 0) or 0),
            "contractHash": context_hash(contract),
            "currentPhase": str(parent_return_state_card.get("currentPhase", "")),
            "currentStep": str(parent_return_state_card.get("currentStep", "")),
            "nextAction": str(parent_return_state_card.get("nextAction", "")),
            "projectProgressState": str(progress_status.get("state", "withheld")),
            "visibleProgressState": str((visible_progress_status or {}).get("state", "withheld")),
            "stageAdvanceAllowed": False,
            "duplicateActionBlocked": True,
        }
        context["continuityMapping"] = _public_continuity_mapping(continuity_mapping)
        context["parentReturnStateCard"] = {
            "state": "current",
            "code": parent_return_code,
            "payloadHash": str(parent_return_state_card.get("payloadHash", "")),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    elif normal_continuity or normalized_recovery_event != "none":
        # Local continuity/recovery is a projection of the one validated local
        # contract and its current project/visible-progress proof.  It does
        # not read a summary, old memory, an unrelated state card, or an
        # external locator, and
        # the presentation itself never authorizes an action.
        continuity_mapping = {
            "state": "local_contract_current",
            "code": "H7_LOCAL_CONTRACT_RECOVERY_CURRENT",
            "source": "scoped_local_contract",
            "visibleContextAvailable": False,
            "stateCardUsed": False,
            "taskIdHash": hashlib.sha256(str(contract.get("taskId", "")).encode("utf-8")).hexdigest(),
            "taskInstanceId": str(contract.get("taskInstanceId", "")),
            "contractRevision": int(contract.get("revision", 0) or 0),
            "contractHash": context_hash(contract),
            "currentPhase": str(contract.get("currentPhase", "")),
            "currentStep": str(contract.get("currentStep", "")),
            "nextAction": str(contract.get("nextAction", "")),
            "projectProgressState": str(progress_status.get("state", "withheld")),
            "visibleProgressState": str((visible_progress_status or {}).get("state", "withheld")),
            "stageAdvanceAllowed": False,
            "duplicateActionBlocked": True,
        }
        context["continuityMapping"] = _public_continuity_mapping(continuity_mapping)
    elif continuity_mapping is None:
        # This is a fresh governed issue, not a failed continuation lookup.
        # Make that distinction explicit instead of projecting an invented
        # continuation failure merely because no active task was selected.
        continuity_mapping = {
            "state": "not_requested",
            "code": "H7_LOCAL_CONTRACT_MAPPING_NOT_REQUESTED",
            "source": "none",
            "visibleContextAvailable": False,
            "stateCardUsed": False,
            "projectProgressState": "not_checked",
            "visibleProgressState": "not_checked",
            "stageAdvanceAllowed": False,
            "duplicateActionBlocked": False,
        }
        context["continuityMapping"] = _public_continuity_mapping(continuity_mapping)
    recovery_presentation, recovery_presentation_code = _recovery_presentation(
        normalized_recovery_event,
        parent_return_state_card,
        continuity_mapping,
    )
    if recovery_presentation is None:
        return _withheld("open", context, recovery_presentation_code)
    context["recoveryPresentation"] = recovery_presentation
    contract_authorization = _resolve_action_authorization(
        core,
        context,
        contract,
        intent,
        timeout=timeout,
    )
    if contract_authorization.get("required") is True:
        context["contractAuthorization"] = contract_authorization
        task_context = context.get("task") if isinstance(context.get("task"), dict) else {}
        task_context["actionAuthorization"] = str(contract_authorization.get("state", "withheld"))
        context["task"] = task_context
        if contract_authorization.get("state") != "allowed":
            return _withheld("open", context, str(contract_authorization.get("code", "H7_ACTION_AUTHORIZATION_WITHHELD")))
    project_knowledge, project_knowledge_code = _resolve_project_knowledge_for_turn(
        core,
        contract,
        progress_status,
        execution_assist,
    )
    if project_knowledge is None:
        return _withheld("open", context, project_knowledge_code or "H7_PROJECT_KNOWLEDGE_WITHHELD")
    context["projectKnowledge"] = public_project_knowledge(project_knowledge)
    # ``_activation`` writes/refreshes the scope-bound activation receipt even
    # when this open is an internal preflight.  Require a provider-backed write
    # lease here rather than trusting the MCP adapter's earlier read check.
    scope_guard = _scope_authorization_guard(core, phase="open", write=True, context=context)
    if scope_guard is not None:
        return scope_guard
    activation, activation_code, refs = _activation(
        core,
        context,
        contract,
        effective_memory_mode,
        action_authorization=str(contract_authorization.get("state", "withheld")),
        intent=intent,
    )
    if activation.get("activationState") != "full_brain_active":
        return _withheld("open", context, activation_code or "H7_ACTIVATION_WITHHELD")
    binding = {
        "phase": "open",
        "scopeRef": str(context["scope"].get("scopeRef", "")),
        "contractHash": str(context["task"].get("contractHash", "")),
        "activationReceiptHash": str(activation.get("receiptHash", "")),
        "agentIdentityHash": canonical_hash(context.get("agentIdentity") if isinstance(context.get("agentIdentity"), dict) else {}),
        "authorityModelHash": canonical_hash(context.get("authorityModel") if isinstance(context.get("authorityModel"), dict) else {}),
        "memoryPayloadHash": str((context.get("typedMemory") or {}).get("payloadHash", "")),
        "memoryRefs": refs,
        "coreRuleRegistryHash": str((context.get("coreRules") or {}).get("payloadHash", "")),
        "coreRuleEffectsHash": str((context.get("coreRules") or {}).get("activeEffectsHash", "")),
        "coreRuleApplicableHash": str((context.get("coreRules") or {}).get("applicableEffectsHash", "")),
        "turnIntentHash": str(intent.get("payloadHash", "")),
        "executionAssistHash": str(execution_assist.get("payloadHash", "")),
        "projectKnowledgeHash": str(project_knowledge.get("payloadHash", "")),
        "projectKnowledgeState": str(project_knowledge.get("state", "withheld")),
        "projectProgressState": str(progress_status.get("state", "withheld")),
        "projectProgressHash": str(progress_status.get("payloadHash", "")),
        "visibleProgressState": str(visible_progress_status.get("state", "withheld")),
        "visibleProgressHash": str(visible_progress_status.get("payloadHash", "")),
        "visibleProgressSentenceHash": str(visible_progress_status.get("sentenceHash", "")),
        "parentReturnStateCardHash": str((parent_return_state_card or {}).get("payloadHash", "")),
        "recoveryEvent": normalized_recovery_event,
        "recoveryPresentationHash": str(recovery_presentation.get("payloadHash", "")),
        "capabilityRouteHash": str((normalized_capability_route_receipt or {}).get("routeHash", "")),
        "capabilitySelectionHash": str((normalized_capability_route_receipt or {}).get("selectionHash", "")),
        "capabilityRouteCompatibilityHash": str((capability_route_compatibility or {}).get("payloadHash", "")),
        "actionAuthorization": str(contract_authorization.get("state", "withheld")),
        "actionAuthorizationResolutionHash": str(contract_authorization.get("resolutionHash", "")),
    }
    body = _receipt_body(
        phase="open",
        context=context,
        contract=contract,
        activation=activation,
        activation_code=activation_code,
        refs=refs,
        binding=binding,
        turn_intent=intent,
        progress_status=progress_status,
        execution_assist=execution_assist,
        project_knowledge=public_project_knowledge(project_knowledge),
        capability_route_receipt=normalized_capability_route_receipt,
        capability_route_compatibility=capability_route_compatibility,
        recovery_presentation=recovery_presentation,
    )
    scope_ref = str(context["scope"].get("scopeRef", ""))
    if persist_receipt:
        receipt, reused = _write_receipt(core.memory_base, scope_ref, "open", body)
        if str(receipt.get("code", "")) in {"H7_RUNTIME_SCOPE_LOCK_TIMEOUT", "H7_RUNTIME_RECEIPT_CORRUPT", "H7_RUNTIME_STATE_WRITE_FAILED"}:
            return _withheld("open", context, str(receipt.get("code")))
    else:
        receipt = dict(body)
        binding_hash = str(receipt.get("bindingHash", ""))
        receipt["receiptId"] = f"tr-open-{binding_hash[:24]}"
        receipt["receiptHash"] = canonical_hash(receipt)
        reused = False
    telemetry: dict[str, Any] | None = None
    telemetry_reused = True
    if record_telemetry:
        telemetry, telemetry_reused = _record_telemetry(
            core.memory_base,
            scope_ref,
            receipt,
            runtime_duration_ms=round((time.perf_counter() - started_at) * 1000),
        )
        if str((telemetry or {}).get("code", "")) in {"H7_RUNTIME_SCOPE_LOCK_TIMEOUT", "H7_RUNTIME_TELEMETRY_CORRUPT", "H7_RUNTIME_STATE_WRITE_FAILED"}:
            return _withheld("open", context, str((telemetry or {}).get("code")))
    result = {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": "open",
        "available": True,
        "code": "TURN_RUNTIME_OPEN_READY",
        "context": context,
        "activation": _public_receipt(receipt)["activation"],
        "runtimeReceipt": _public_receipt(receipt),
        "continuityMapping": _public_continuity_mapping(continuity_mapping),
        "recoveryPresentation": recovery_presentation,
        "projectKnowledge": public_project_knowledge(project_knowledge),
        "receiptReused": reused,
        "telemetry": {
            "path": str(_telemetry_path(core.memory_base, scope_ref)),
            "payloadHash": str((telemetry or {}).get("payloadHash", "")),
            "reused": telemetry_reused,
        },
        "runObservability": (telemetry or {}).get("runObservability", {}),
        "terminalReplyAllowed": False,
        "mustContinue": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    if return_private_bundle:
        # Same-call-only handoff for ``close_turn``.  This is deliberately
        # opt-in, never persisted, and never returned by the MCP/CLI-facing
        # open path.  A no-op close can then publish its close receipt from
        # the exact pre-dispatch proof instead of re-reading and re-hashing an
        # unchanged contract/project slice.
        result["_privateCloseBundle"] = {
            "contract": contract,
            "progressStatus": progress_status,
            "projectKnowledge": project_knowledge,
            "activation": activation,
            "activationCode": activation_code,
            "memoryRefs": refs,
        }
    return result


def checkpoint_turn(
    core: BrainCore,
    *,
    memory_mode: str = "auto",
    progress_checkpoint: dict[str, Any] | None = None,
    project_progress_proof: dict[str, Any] | None = None,
    transition_id: str = "",
    timeout: float = 8.0,
    turn_intent: str = "continuity",
    execution_assist_request: Any = None,
    capability_route_receipt: Any = None,
    latest_user_instruction: str | None = None,
    **legacy_transport: Any,
) -> dict[str, Any]:
    """Persist one latest-assistant-progress checkpoint through H7 authority.

    A compaction summary is historical context, not an execution source.  This
    operation records the current assistant's bounded state atomically before a
    material progress update so the next governed turn can recover it exactly.
    """

    retired = _retired_host_transport_result("checkpoint", **legacy_transport)
    if retired is not None:
        return retired
    if any(value is not None for value in legacy_transport.values()):
        return _withheld("checkpoint", {}, "TURN_RUNTIME_ARGUMENTS_INVALID")

    requested_intent = resolve_turn_intent(turn_intent, memory_mode=memory_mode)
    checkpoint_intent_code = _progress_checkpoint_intent_guard(progress_checkpoint, requested_intent)
    if checkpoint_intent_code:
        return _withheld("checkpoint", {}, checkpoint_intent_code)
    # Checkpoint performs an activation refresh and a CAS mutation.  Acquire
    # the write lease before the preflight can reach either side effect.
    scope_guard = _scope_authorization_guard(core, phase="checkpoint", write=True)
    if scope_guard is not None:
        return scope_guard

    checkpoint_phase = str(progress_checkpoint.get("current_phase", "")).strip() if isinstance(progress_checkpoint, dict) else ""
    checkpoint_next_action = str(progress_checkpoint.get("next_action", "")).strip() if isinstance(progress_checkpoint, dict) else ""
    terminal_finalization_checkpoint = (
        isinstance(progress_checkpoint, dict)
        and str(progress_checkpoint.get("source", "")) == "assistant_visible_reply"
        and (
            checkpoint_phase.casefold() in {"complete", "completed", "done"}
            or (
                is_formal_phase(checkpoint_phase)
                and checkpoint_next_action
                and not checkpoint_next_action.casefold().startswith("no automatic action:")
            )
        )
    )
    opened = open_turn(
        core,
        memory_mode=memory_mode,
        record_telemetry=False,
        persist_receipt=False,
        turn_intent=turn_intent,
        execution_assist_request=execution_assist_request,
        capability_route_receipt=capability_route_receipt,
        execution_apply_phase="execution",
        allow_terminal_finalization=terminal_finalization_checkpoint,
        allow_reconciliation_checkpoint=True,
        terminal_finalization_phase=checkpoint_phase,
        return_private_bundle=True,
    )
    checkpoint_reconcile = False
    checkpoint_reconcile_code = ""
    if opened.get("available") is not True:
        # A live project file can legitimately change after its last bound
        # proof, and older contracts can predate the visible-progress receipt.
        # Neither condition may send callers around H7.  This narrow branch
        # accepts the same bounded checkpoint/proof as the normal route,
        # rechecks the current scope and activation, writes one atomic H7
        # reconciliation, then reopens through the ordinary governed path.
        open_code = str(opened.get("code", ""))
        repairable_visible_anchor = open_code in {
            "H7_VISIBLE_PROGRESS_RECEIPT_REQUIRED",
            "H7_VISIBLE_PROGRESS_RECEIPT_INVALID",
            "H7_VISIBLE_PROGRESS_RECEIPT_HASH_MISMATCH",
            "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH",
            "H7_VISIBLE_PROGRESS_RECEIPT_PROJECT_PROOF_MISMATCH",
            "H7_VISIBLE_PROGRESS_ASSISTANT_REPLY_REQUIRED",
        }
        reconciliation_checkpoint_required = open_code == "H7_RECONCILIATION_CHECKPOINT_REQUIRED"
        if (
            reconciliation_checkpoint_required
            and (
                progress_checkpoint is None
                or project_progress_proof is None
                or not isinstance(latest_user_instruction, str)
                or not latest_user_instruction.strip()
            )
        ):
            return _withheld(
                "checkpoint",
                opened.get("context") if isinstance(opened.get("context"), dict) else {},
                "H7_RECONCILIATION_CHECKPOINT_INPUT_REQUIRED",
            )
        if (
            (
                open_code != "H7_PROJECT_PROGRESS_WITHHELD"
                and not repairable_visible_anchor
                and not reconciliation_checkpoint_required
            )
            or progress_checkpoint is None
            or (
                open_code in {
                    "H7_PROJECT_PROGRESS_WITHHELD",
                    "H7_RECONCILIATION_CHECKPOINT_REQUIRED",
                }
                and project_progress_proof is None
            )
        ):
            return _withheld(
                "checkpoint",
                opened.get("context") if isinstance(opened.get("context"), dict) else {},
                str(opened.get("code", "TURN_RUNTIME_OPEN_REQUIRED")),
            )
        context = opened.get("context") if isinstance(opened.get("context"), dict) else {}
        intent = resolve_turn_intent(turn_intent, memory_mode=memory_mode)
        checkpoint_source = str(progress_checkpoint.get("source", "")) if isinstance(progress_checkpoint, dict) else ""
        if (
            intent.get("ok") is not True
            or intent.get("governed") is not True
            or context.get("ok") is not True
            or context.get("available") is not True
            or (
                repairable_visible_anchor
                and str(((context.get("task") or {}).get("projectProgress") or {}).get("state", "withheld")) != "current"
                and project_progress_proof is None
            )
            or (
                checkpoint_source == "user_attested_visible_reply"
                and str(intent.get("kind", "")) not in {"user_correction", "super_brain_issue_continuity"}
            )
        ):
            return _withheld("checkpoint", context, "H7_PROGRESS_CHECKPOINT_RECONCILIATION_CONTEXT_INVALID")
        contract, contract_code = _contract_binding(
            core,
            context,
            allow_reconciliation_checkpoint=reconciliation_checkpoint_required,
            terminal_finalization_phase=checkpoint_phase,
        )
        if contract is None:
            return _withheld("checkpoint", context, contract_code)
        if (
            reconciliation_checkpoint_required
            and (
                contract.get("needsReconciliation") is not True
                or not str(contract.get("focusId", "")).strip()
            )
        ):
            return _withheld(
                "checkpoint",
                context,
                "H7_RECONCILIATION_CHECKPOINT_CONTEXT_INVALID",
            )
        activation, _, _ = _activation(core, context, contract, str(intent.get("memoryMode", memory_mode)), intent=intent)
        capabilities = activation.get("capabilities") if isinstance(activation.get("capabilities"), dict) else {}
        if (
            activation.get("activationState") != "full_brain_active"
            or capabilities.get("coreReady") is not True
            or str((context.get("coreRules") or {}).get("status", "")) != "current"
        ):
            return _withheld("checkpoint", context, "H7_PROGRESS_CHECKPOINT_RECONCILIATION_ACTIVATION_WITHHELD")
        checkpoint_reconcile = True
        checkpoint_reconcile_code = (
            "H7_RECONCILIATION_CHECKPOINT_READY"
            if reconciliation_checkpoint_required
            else (
                "H7_PROJECT_PROGRESS_REFRESH_READY"
                if open_code == "H7_PROJECT_PROGRESS_WITHHELD"
                else "H7_VISIBLE_PROGRESS_RECEIPT_RECONCILED_READY"
            )
        )
    context = opened["context"]
    scope = context["scope"]
    task = context["task"]
    private_open_bundle = opened.get("_privateCloseBundle")
    current_contract = (
        private_open_bundle.get("contract")
        if isinstance(private_open_bundle, dict) and isinstance(private_open_bundle.get("contract"), dict)
        else None
    )
    failure_evidence_fingerprint = context_hash(
        {
            "contractHash": str(task.get("contractHash", "")),
            "projectProgressHash": str((task.get("projectProgress") or {}).get("payloadHash", "")),
        }
    )
    failure_action_fingerprint = context_hash(
        {"operation": "checkpoint", "transitionId": str(transition_id)},
    )
    checkpoint_reservation_id, checkpoint_reservation_guard = _reserve_failure_loop(
        core.memory_base,
        str(scope.get("scopeRef", "")),
        failure_fingerprint="H7_PROGRESS_CHECKPOINT_FAILED",
        evidence_fingerprint=failure_evidence_fingerprint,
        action_fingerprint=failure_action_fingerprint,
        phase=str(task.get("currentPhase", "")),
        user_correction=str(requested_intent.get("kind", "")) == "user_correction",
        side_effect_timeout=timeout,
    )
    if not checkpoint_reservation_id:
        failed = _withheld("checkpoint", context, "H7_REPAIR_LOOP_FUSE_OPEN")
        return _apply_failure_loop_result(
            failed,
            checkpoint_reservation_guard,
            original_code="H7_PROGRESS_CHECKPOINT_FAILED",
        )
    checkpoint = record_progress_checkpoint(
        core.package_root,
        core.memory_base,
        task_id=str(task.get("taskId", "")),
        workspace_key=str(scope.get("workspaceKey", "")),
        session_key=str(scope.get("ownerSessionKey", "")),
        progress_checkpoint=progress_checkpoint,
        project_progress_proof=project_progress_proof,
        latest_user_instruction=latest_user_instruction,
        project_root=core._context_project_root(),
        current_contract=current_contract,
        transition_id=transition_id,
        timeout=timeout,
    )
    if checkpoint.get("ok") is not True:
        failure_code = str(checkpoint.get("contractCode") or checkpoint.get("code") or "H7_PROGRESS_CHECKPOINT_FAILED")
        failed = _withheld("checkpoint", context, failure_code)
        failed["checkpoint"] = {
            "code": str(checkpoint.get("code", "H7_PROGRESS_CHECKPOINT_FAILED")),
            "contractCode": str(checkpoint.get("contractCode", "")),
            "contractReason": str(checkpoint.get("contractReason", "")),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        committed, guard = _finish_failure_loop_reservation(
            core.memory_base,
            str(scope.get("scopeRef", "")),
            checkpoint_reservation_id,
            commit=True,
        )
        if not committed or not isinstance(guard, dict):
            return _apply_failure_loop_result(
                failed,
                _invalid_failure_loop_guard(),
                original_code=failure_code,
            )
        return _apply_failure_loop_result(failed, guard, original_code=failure_code)
    released, _ = _finish_failure_loop_reservation(
        core.memory_base,
        str(scope.get("scopeRef", "")),
        checkpoint_reservation_id,
        commit=False,
    )
    if not released:
            return _reservation_release_failed_result(
                "checkpoint",
                context,
                operation="progress_checkpoint",
                checkpoint=checkpoint,
                reservation_id=checkpoint_reservation_id,
            )
    refreshed = open_turn(
        core,
        memory_mode=memory_mode,
        record_telemetry=True,
        turn_intent=turn_intent,
        execution_assist_request=execution_assist_request,
        capability_route_receipt=capability_route_receipt,
        execution_apply_phase="execution",
    )
    if refreshed.get("available") is not True:
        refreshed_code = str(refreshed.get("code", "H7_PROGRESS_CHECKPOINT_REOPEN_FAILED"))
        # Preserve the successful user-attested reconciliation in the result,
        # while refusing to present it as a normal continuation.  The caller
        # must publish one exact assistant-visible progress checkpoint next.
        if (
            refreshed_code == "H7_VISIBLE_PROGRESS_ASSISTANT_REPLY_REQUIRED"
            and str((checkpoint.get("visibleProgress") or {}).get("source", "")) == "user_attested_visible_reply"
        ):
            return {
                "ok": True,
                "schema": SCHEMA,
                "mode": MODE,
                "phase": "checkpoint",
                "available": False,
                "code": refreshed_code,
                "context": refreshed.get("context") if isinstance(refreshed.get("context"), dict) else context,
                "checkpoint": checkpoint,
                "runtimeReceipt": refreshed.get("runtimeReceipt"),
                "receiptReused": bool(refreshed.get("receiptReused")),
                "telemetry": refreshed.get("telemetry") if isinstance(refreshed.get("telemetry"), dict) else {},
                "terminalReplyAllowed": False,
                "mustContinue": True,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        return _withheld(
            "checkpoint",
            refreshed.get("context") if isinstance(refreshed.get("context"), dict) else context,
            refreshed_code,
        )
    return {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": "checkpoint",
        "available": True,
        "code": checkpoint_reconcile_code if checkpoint_reconcile else "H7_PROGRESS_CHECKPOINT_READY",
        "context": refreshed["context"],
        "checkpoint": checkpoint,
        "runtimeReceipt": refreshed.get("runtimeReceipt"),
        "receiptReused": bool(refreshed.get("receiptReused")),
        "telemetry": refreshed.get("telemetry") if isinstance(refreshed.get("telemetry"), dict) else {},
        "terminalReplyAllowed": False,
        "mustContinue": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def close_turn(
    core: BrainCore,
    *,
    memory_mode: str = "auto",
    turn_outcome: str = "unknown",
    user_control: str = "unknown",
    completion_evidence_ref: str = "",
    progress_checkpoint: dict[str, Any] | None = None,
    project_progress_proof: dict[str, Any] | None = None,
    transition_id: str = "",
    timeout: float = 8.0,
    turn_intent: str = "direct",
    execution_assist_request: Any = None,
    capability_route_receipt: Any = None,
    latest_user_instruction: str | None = None,
    **legacy_transport: Any,
) -> dict[str, Any]:
    """Close a governed turn and execute a safe parent-resume transition."""

    retired = _retired_host_transport_result("close", **legacy_transport)
    if retired is not None:
        return retired
    if any(value is not None for value in legacy_transport.values()):
        return _withheld("close", {}, "TURN_RUNTIME_ARGUMENTS_INVALID")

    started_at = time.perf_counter()
    close_intent = resolve_turn_intent(turn_intent, memory_mode=memory_mode)
    checkpoint_intent_code = _progress_checkpoint_intent_guard(progress_checkpoint, close_intent)
    if checkpoint_intent_code:
        return _withheld("close", {}, checkpoint_intent_code)
    # Close may checkpoint, dispatch a parent transition, publish a close
    # receipt, and append telemetry.  Its own write authorization is therefore
    # mandatory even when called outside the MCP adapter.
    scope_guard = _scope_authorization_guard(core, phase="close", write=True)
    if scope_guard is not None:
        return scope_guard

    execution_assist, normalized_capability_route_receipt, capability_route_compatibility, execution_assist_code = (
        _resolve_execution_assist_for_turn(
            core,
            close_intent,
            execution_assist_request,
            capability_route_receipt,
            apply_phase="verification",
        )
    )
    if execution_assist is None or normalized_capability_route_receipt is None:
        return _withheld("close", {}, execution_assist_code or "H7_EXECUTION_ASSIST_UNAVAILABLE")
    # An explicit close transition id belongs to the CloseTurn dispatcher.
    # Its optional progress checkpoint is a distinct Set transaction; sharing
    # the id would make an otherwise-safe Set look like a close replay.
    close_transition_id = _compact(transition_id, 120)
    checkpoint_transition_id = (
        f"{close_transition_id[:109]}:checkpoint" if close_transition_id else ""
    )
    checkpoint: dict[str, Any] | None = None
    opened = open_turn(
        core,
        memory_mode=memory_mode,
        record_telemetry=False,
        persist_receipt=False,
        turn_intent=turn_intent,
        execution_assist_request=execution_assist_request,
        capability_route_receipt=capability_route_receipt,
        _execution_assist_bundle=(
            execution_assist,
            normalized_capability_route_receipt,
            capability_route_compatibility,
            execution_assist_code,
        ),
        execution_apply_phase="verification",
        return_private_bundle=True,
    )
    if opened.get("available") is not True:
        # A close carrying the exact current checkpoint may perform the same
        # narrow H7-only migration as checkpoint_turn.  It must never fall
        # back to closing from an old contract or summary.
        if progress_checkpoint is not None:
            migrated = checkpoint_turn(
                core,
                memory_mode=memory_mode,
                progress_checkpoint=progress_checkpoint,
                project_progress_proof=project_progress_proof,
                transition_id=checkpoint_transition_id,
                timeout=timeout,
                turn_intent=turn_intent,
                execution_assist_request=execution_assist_request,
                capability_route_receipt=capability_route_receipt,
                latest_user_instruction=latest_user_instruction,
            )
            if migrated.get("available") is not True:
                return _withheld(
                    "close",
                    migrated.get("context") if isinstance(migrated.get("context"), dict) else {},
                    str(migrated.get("code", "TURN_RUNTIME_OPEN_REQUIRED")),
                )
            checkpoint = migrated.get("checkpoint") if isinstance(migrated.get("checkpoint"), dict) else None
            opened = {
                "context": migrated["context"],
                "runtimeReceipt": migrated.get("runtimeReceipt"),
                "available": True,
            }
            progress_checkpoint = None
            project_progress_proof = None
        else:
            return _withheld("close", opened.get("context") if isinstance(opened.get("context"), dict) else {}, str(opened.get("code", "TURN_RUNTIME_OPEN_REQUIRED")))
    if progress_checkpoint is not None:
        initial_context = opened["context"]
        initial_scope = initial_context["scope"]
        initial_task = initial_context["task"]
        close_checkpoint_evidence = context_hash(
            {
                "contractHash": str(initial_task.get("contractHash", "")),
                "projectProgressHash": str((initial_task.get("projectProgress") or {}).get("payloadHash", "")),
            }
        )
        close_checkpoint_action = context_hash(
            {"operation": "close_checkpoint", "transitionId": str(checkpoint_transition_id)},
        )
        checkpoint_reservation_id, checkpoint_reservation_guard = _reserve_failure_loop(
            core.memory_base,
            str(initial_scope.get("scopeRef", "")),
            failure_fingerprint="H7_PROGRESS_CHECKPOINT_FAILED",
            evidence_fingerprint=close_checkpoint_evidence,
            action_fingerprint=close_checkpoint_action,
            phase=str(initial_task.get("currentPhase", "")),
            user_correction=str(close_intent.get("kind", "")) == "user_correction",
            side_effect_timeout=timeout,
        )
        if not checkpoint_reservation_id:
            return _apply_failure_loop_result(
                _withheld("close", initial_context, "H7_REPAIR_LOOP_FUSE_OPEN"),
                checkpoint_reservation_guard,
                original_code="H7_PROGRESS_CHECKPOINT_FAILED",
            )
        checkpoint = record_progress_checkpoint(
            core.package_root,
            core.memory_base,
            task_id=str(initial_task.get("taskId", "")),
            workspace_key=str(initial_scope.get("workspaceKey", "")),
            session_key=str(initial_scope.get("ownerSessionKey", "")),
            progress_checkpoint=progress_checkpoint,
            project_progress_proof=project_progress_proof,
            latest_user_instruction=latest_user_instruction,
            project_root=core._context_project_root(),
            current_contract=(
                opened.get("_privateCloseBundle", {}).get("contract")
                if isinstance(opened.get("_privateCloseBundle"), dict)
                and isinstance(opened.get("_privateCloseBundle", {}).get("contract"), dict)
                else None
            ),
            transition_id=checkpoint_transition_id,
            timeout=timeout,
        )
        if checkpoint.get("ok") is not True:
            failure_code = str(checkpoint.get("contractCode") or checkpoint.get("code") or "H7_PROGRESS_CHECKPOINT_FAILED")
            failed = _withheld(
                "close",
                initial_context,
                failure_code,
            )
            committed, guard = _finish_failure_loop_reservation(
                core.memory_base,
                str(initial_scope.get("scopeRef", "")),
                checkpoint_reservation_id,
                commit=True,
            )
            if not committed or not isinstance(guard, dict):
                return _apply_failure_loop_result(failed, _invalid_failure_loop_guard(), original_code=failure_code)
            return _apply_failure_loop_result(failed, guard, original_code=failure_code)
        released, _ = _finish_failure_loop_reservation(
            core.memory_base,
            str(initial_scope.get("scopeRef", "")),
            checkpoint_reservation_id,
            commit=False,
        )
        if not released:
            return _reservation_release_failed_result(
                "close",
                initial_context,
                operation="close_progress_checkpoint",
                checkpoint=checkpoint,
                reservation_id=checkpoint_reservation_id,
            )
        opened = open_turn(
            core,
            memory_mode=memory_mode,
            record_telemetry=False,
            persist_receipt=False,
            turn_intent=turn_intent,
            execution_assist_request=execution_assist_request,
            capability_route_receipt=capability_route_receipt,
            _execution_assist_bundle=(
                execution_assist,
                normalized_capability_route_receipt,
                capability_route_compatibility,
                execution_assist_code,
            ),
            execution_apply_phase="verification",
            return_private_bundle=True,
        )
        if opened.get("available") is not True:
            return _withheld(
                "close",
                opened.get("context") if isinstance(opened.get("context"), dict) else initial_context,
                str(opened.get("code", "H7_PROGRESS_CHECKPOINT_REOPEN_FAILED")),
            )
    context = opened["context"]
    scope = context["scope"]
    task = context["task"]
    evidence = _compact(completion_evidence_ref)
    evidence_hash = hashlib.sha256(evidence.encode("utf-8")).hexdigest() if evidence else ""
    safe_evidence_ref = f"turn-runtime:{evidence_hash[:32]}" if evidence_hash else ""
    # Routine active-work closes are often policy-only: after a verified
    # preflight, they simply say "continue this turn" and do not touch the
    # contract.  Re-check the same contract/proof once in-process to close the
    # race window, then avoid launching PowerShell solely to compute that pure
    # policy.  Any mismatch falls through to the authoritative dispatcher.
    dispatched: dict[str, Any] | None = None
    dispatch_reservation_id = ""
    dispatch_reservation_guard: dict[str, Any] = _invalid_failure_loop_guard()
    preflight_bundle = opened.get("_privateCloseBundle")
    if isinstance(preflight_bundle, dict):
        fresh_contract, fresh_contract_code = _contract_binding(core, context)
        current_task = context.get("task") if isinstance(context.get("task"), dict) else {}
        if (
            isinstance(fresh_contract, dict)
            and context_hash(fresh_contract) == str(current_task.get("contractHash", ""))
        ):
            fresh_progress_status = core._project_progress_status(fresh_contract)
            fast_policy = _policy_only_fast_close(
                context,
                fresh_contract,
                fresh_progress_status,
                close_intent,
                turn_outcome=turn_outcome,
                user_control=user_control,
                completion_evidence_present=bool(evidence),
                checkpoint_present=checkpoint is not None,
            )
            if fast_policy is not None:
                # The final in-process re-read becomes the only reuse source
                # for the later close receipt.  It is still stack-local and
                # discarded before the result leaves ``close_turn``.
                preflight_bundle["contract"] = fresh_contract
                preflight_bundle["progressStatus"] = fresh_progress_status
                dispatched = {
                    "ok": True,
                    "schema": "super-brain.turn-close-dispatch.v1",
                    "code": "TURN_CLOSE_DISPATCH_POLICY_ONLY",
                    "stateMutated": False,
                    "policy": fast_policy,
                    "resolution": _current_contract_policy_resolution(fresh_contract),
                    "transition": None,
                    "contractCode": "H7_CLOSE_POLICY_CURRENT_PRECHECK",
                    "contractReason": "",
                    "fastPath": "current_verified_policy_only",
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }
    if dispatched is None:
        dispatch_reservation_id, dispatch_reservation_guard = _reserve_failure_loop(
            core.memory_base,
            str(scope.get("scopeRef", "")),
            failure_fingerprint="H7_CLOSE_DISPATCH_FAILED",
            evidence_fingerprint=context_hash(
                {
                    "contractHash": str(task.get("contractHash", "")),
                    "projectProgressHash": str((task.get("projectProgress") or {}).get("payloadHash", "")),
                }
            ),
            action_fingerprint=context_hash(
                {
                    "operation": "close",
                    "turnOutcome": str(turn_outcome),
                    "userControl": str(user_control),
                    "transitionId": str(close_transition_id),
                }
            ),
            phase=str(task.get("currentPhase", "")),
            user_correction=str(close_intent.get("kind", "")) == "user_correction",
            side_effect_timeout=timeout,
        )
        if not dispatch_reservation_id:
            return _apply_failure_loop_result(
                _withheld("close", context, "H7_REPAIR_LOOP_FUSE_OPEN"),
                dispatch_reservation_guard,
                original_code="H7_CLOSE_DISPATCH_FAILED",
            )
        dispatched = dispatch_turn_close(
            core.package_root,
            core.memory_base,
            task_id=str(task.get("taskId", "")),
            workspace_key=str(scope.get("workspaceKey", "")),
            session_key=str(scope.get("ownerSessionKey", "")),
            turn_outcome=turn_outcome,
            user_control=user_control,
            completion_evidence_ref=safe_evidence_ref,
            transition_id=close_transition_id,
            project_root=core._context_project_root(),
            timeout=timeout,
        )
    if dispatched.get("ok") is not True:
        # Never report a failed authority transaction as an available close.
        # Preserve the bounded dispatch projection so the caller can
        # reconcile a possible partial commit instead of blindly retrying.
        failure_code = str(dispatched.get("code", "H7_CLOSE_DISPATCH_FAILED"))
        failed = _withheld(
            "close",
            context,
            failure_code,
        )
        failed["dispatch"] = {
            "code": str(dispatched.get("code", "")),
            "contractCode": str(dispatched.get("contractCode", "")),
            "contractReason": str(dispatched.get("contractReason", "")),
            "stateMutated": bool(dispatched.get("stateMutated") is True),
        }
        failed["operationState"] = "partially_committed" if dispatched.get("stateMutated") is True else "failed"
        failed["retrySafe"] = dispatched.get("stateMutated") is not True
        if dispatch_reservation_id:
            committed, guard = _finish_failure_loop_reservation(
                core.memory_base,
                str(scope.get("scopeRef", "")),
                dispatch_reservation_id,
                commit=True,
            )
        else:
            committed, guard = False, None
        if not committed or not isinstance(guard, dict):
            return _apply_failure_loop_result(failed, _invalid_failure_loop_guard(), original_code=failure_code)
        return _apply_failure_loop_result(failed, guard, original_code=failure_code)
    if dispatch_reservation_id:
        released, _ = _finish_failure_loop_reservation(
            core.memory_base,
            str(scope.get("scopeRef", "")),
            dispatch_reservation_id,
            commit=False,
        )
        if not released:
            return _reservation_release_failed_result(
                "close",
                context,
                operation="close_dispatch",
                dispatch=dispatched,
                reservation_id=dispatch_reservation_id,
            )
    # A policy-only close has already run the authority Resolve but did not
    # mutate its contract.  Re-opening it used to repeat the entire context,
    # proof, project-knowledge, activation, receipt, and telemetry pipeline
    # for exactly the same state.  Reuse only the pre-dispatch, stack-local
    # bundle in this branch.  Any real transition (including an idempotent
    # CloseTurn replay) keeps the fresh post-dispatch read below.
    post_open: dict[str, Any] | None = None
    post_context = context
    post_contract: dict[str, Any] | None = None
    post_progress_status: dict[str, Any] | None = None
    post_project_knowledge: dict[str, Any] | None = None
    post_activation: dict[str, Any] | None = None
    activation_code = ""
    refs: list[Any] = []
    preflight_bundle = opened.get("_privateCloseBundle")
    reuse_preflight_bundle = dispatched.get("stateMutated") is not True and isinstance(preflight_bundle, dict)
    if reuse_preflight_bundle:
        candidate_contract = preflight_bundle.get("contract")
        candidate_progress = preflight_bundle.get("progressStatus")
        candidate_knowledge = preflight_bundle.get("projectKnowledge")
        candidate_activation = preflight_bundle.get("activation")
        candidate_activation_code = preflight_bundle.get("activationCode")
        candidate_refs = preflight_bundle.get("memoryRefs")
        if (
            isinstance(candidate_contract, dict)
            and isinstance(candidate_progress, dict)
            and isinstance(candidate_knowledge, dict)
            and project_knowledge_receipt_is_valid(candidate_knowledge)
            and isinstance(candidate_activation, dict)
            and isinstance(candidate_activation_code, str)
            and isinstance(candidate_refs, list)
        ):
            post_contract = candidate_contract
            post_progress_status = candidate_progress
            post_project_knowledge = candidate_knowledge
            post_activation = candidate_activation
            activation_code = candidate_activation_code
            refs = candidate_refs
        else:
            reuse_preflight_bundle = False
    if not reuse_preflight_bundle:
        # Dispatch changed state (or a private bundle was unavailable), so a
        # new live read is mandatory.  The already-validated execution-assist
        # bundle remains valid only inside this same call and avoids a second
        # cold registry/shadow-evaluation pass.
        post_open = open_turn(
            core,
            memory_mode=memory_mode,
            record_telemetry=True,
            persist_receipt=True,
            turn_intent=turn_intent,
            execution_assist_request=execution_assist_request,
            capability_route_receipt=capability_route_receipt,
            _execution_assist_bundle=(
                execution_assist,
                normalized_capability_route_receipt,
                capability_route_compatibility,
                execution_assist_code,
            ),
            execution_apply_phase="verification",
        )
        post_context = post_open.get("context") if isinstance(post_open.get("context"), dict) else context
        if post_open.get("available") is not True:
            # The contract may already be committed.  Surface that fact and
            # force a targeted reconciliation rather than returning a generic
            # close failure that encourages an unsafe blind retry.
            withheld = _withheld("close", post_context, "H7_POST_DISPATCH_OBSERVATION_REQUIRED")
            withheld["dispatch"] = {
                "code": str(dispatched.get("code", "")),
                "contractCode": str(dispatched.get("contractCode", "")),
                "contractReason": str(dispatched.get("contractReason", "")),
                "stateMutated": bool(dispatched.get("stateMutated") is True),
            }
            withheld["postDispatchObservation"] = {
                "state": "withheld",
                "code": str(post_open.get("code", "H7_POST_DISPATCH_OPEN_WITHHELD")),
                "retry": "reconcile_current_contract",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
            return withheld
        post_contract, contract_code = _contract_binding(core, post_context)
        if post_contract is None:
            return _withheld("close", post_context, contract_code)
        post_progress_status = core._project_progress_status(post_contract)
        if close_intent.get("projectEvidenceRequired") is True and post_progress_status.get("current") is not True:
            return _withheld("close", post_context, "H7_PROJECT_PROGRESS_WITHHELD")
        # ``post_open`` has already resolved the proof-bound project slice for
        # the post-dispatch contract.  Re-running the same resolver here added
        # a full proof-file read/hash cycle without changing authorization.
        post_project_knowledge = post_open.get("projectKnowledge")
        if not isinstance(post_project_knowledge, dict) or not project_knowledge_receipt_is_valid(post_project_knowledge):
            return _withheld("close", post_context, "H7_PROJECT_KNOWLEDGE_POST_OPEN_RECEIPT_INVALID")
        post_context["projectKnowledge"] = post_project_knowledge
        post_activation, activation_code, refs = _activation(
            core, post_context, post_contract, memory_mode, intent=close_intent
        )
    if post_activation.get("activationState") != "full_brain_active":
        return _withheld("close", post_context, activation_code or "H7_ACTIVATION_WITHHELD")
    assert isinstance(post_contract, dict)
    assert isinstance(post_progress_status, dict)
    assert isinstance(post_project_knowledge, dict)
    assert isinstance(post_activation, dict)
    post_context["projectKnowledge"] = public_project_knowledge(post_project_knowledge)
    phase_closeout: dict[str, Any] = {
        "state": "not_applicable",
        "code": "H7_PHASE_CLOSEOUT_NOT_APPLICABLE",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    # A formal closeout is now entirely local and H7-owned.  The authority
    # reloads the current execution contract, current project proof, current
    # visible-progress receipt, activation receipt, and telemetry bindings
    # under the same CAS scope.  Host readback is permanently retired.
    if is_formal_phase((post_context.get("task") or {}).get("currentPhase", "")):
        current_task = post_context.get("task") if isinstance(post_context.get("task"), dict) else {}
        plan_receipt = post_contract.get("planReceipt") if isinstance(post_contract.get("planReceipt"), dict) else {}
        phase_closeout = create_phase_closeout(
            core.package_root,
            core.memory_base,
            task_id=str(current_task.get("taskId", "")),
            workspace_key=str((post_context.get("scope") or {}).get("workspaceKey", "")),
            session_key=str((post_context.get("scope") or {}).get("ownerSessionKey", "")),
            project_root=core._context_project_root(),
            expected_revision=int(post_contract.get("revision", 0) or 0),
            expected_plan_fingerprint=str(
                post_contract.get("planFingerprint") or plan_receipt.get("planFingerprint") or ""
            ),
            timeout=timeout,
        )
    policy = dispatched.get("policy") if isinstance(dispatched.get("policy"), dict) else {}
    transition = dispatched.get("transition") if isinstance(dispatched.get("transition"), dict) else None
    binding = {
        "phase": "close",
        "entryReceiptHash": str((opened.get("runtimeReceipt") or {}).get("receiptHash", "")),
        "dispatchCode": str(dispatched.get("code", "")),
        "policy": {key: policy.get(key) for key in ("decision", "code", "terminalReplyAllowed", "requiresParentResume")},
        "transition": transition or {},
        "completionEvidenceHash": evidence_hash,
        "postContractHash": str((post_context.get("task") or {}).get("contractHash", "")),
        "agentIdentityHash": canonical_hash(post_context.get("agentIdentity") if isinstance(post_context.get("agentIdentity"), dict) else {}),
        "authorityModelHash": canonical_hash(post_context.get("authorityModel") if isinstance(post_context.get("authorityModel"), dict) else {}),
        "coreRuleRegistryHash": str((post_context.get("coreRules") or {}).get("payloadHash", "")),
        "coreRuleEffectsHash": str((post_context.get("coreRules") or {}).get("activeEffectsHash", "")),
        "coreRuleApplicableHash": str((post_context.get("coreRules") or {}).get("applicableEffectsHash", "")),
        "turnIntentHash": str((post_context.get("turnIntent") or {}).get("payloadHash", "")),
        "executionAssistHash": str(execution_assist.get("payloadHash", "")),
        "projectKnowledgeHash": str(post_project_knowledge.get("payloadHash", "")),
        "projectKnowledgeState": str(post_project_knowledge.get("state", "withheld")),
        "projectProgressState": str(post_progress_status.get("state", "withheld")),
        "projectProgressHash": str(post_progress_status.get("payloadHash", "")),
        "visibleProgressState": str(((post_context.get("task") or {}).get("visibleProgress") or {}).get("state", "withheld")),
        "visibleProgressHash": str(((post_context.get("task") or {}).get("visibleProgress") or {}).get("payloadHash", "")),
        "visibleProgressSentenceHash": str(((post_context.get("task") or {}).get("visibleProgress") or {}).get("sentenceHash", "")),
        "capabilityRouteHash": str((normalized_capability_route_receipt or {}).get("routeHash", "")),
        "capabilitySelectionHash": str((normalized_capability_route_receipt or {}).get("selectionHash", "")),
        "capabilityRouteCompatibilityHash": str((capability_route_compatibility or {}).get("payloadHash", "")),
    }
    body = _receipt_body(
        phase="close",
        context=post_context,
        contract=post_contract,
        activation=post_activation,
        activation_code=activation_code,
        refs=refs,
        binding=binding,
        continuation=policy,
        transition=transition,
        completion_evidence_hash=evidence_hash,
        turn_intent=(post_context.get("turnIntent") if isinstance(post_context.get("turnIntent"), dict) else {}),
        progress_status=post_progress_status,
        execution_assist=execution_assist,
        project_knowledge=public_project_knowledge(post_project_knowledge),
        capability_route_receipt=normalized_capability_route_receipt,
        capability_route_compatibility=capability_route_compatibility,
    )
    scope_ref = str(post_context["scope"].get("scopeRef", ""))
    receipt, reused = _write_receipt(core.memory_base, scope_ref, "close", body)
    if str(receipt.get("code", "")) in {"H7_RUNTIME_SCOPE_LOCK_TIMEOUT", "H7_RUNTIME_RECEIPT_CORRUPT", "H7_RUNTIME_STATE_WRITE_FAILED"}:
        return _withheld("close", post_context, str(receipt.get("code")))
    telemetry, telemetry_reused = _record_telemetry(
        core.memory_base,
        scope_ref,
        receipt,
        runtime_duration_ms=round((time.perf_counter() - started_at) * 1000),
    )
    if str(telemetry.get("code", "")) in {"H7_RUNTIME_SCOPE_LOCK_TIMEOUT", "H7_RUNTIME_TELEMETRY_CORRUPT", "H7_RUNTIME_STATE_WRITE_FAILED"}:
        return _withheld("close", post_context, str(telemetry.get("code")))
    terminal_allowed = bool(policy.get("terminalReplyAllowed", True))
    return {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": "close",
        "available": True,
        "code": str(dispatched.get("code", "TURN_RUNTIME_CLOSE_DISPATCH_INVALID")),
        "context": post_context,
        "entryReceipt": opened.get("runtimeReceipt"),
        "checkpoint": checkpoint,
        "continuation": policy,
        "transition": transition,
        "dispatch": {
            "code": str(dispatched.get("code", "")),
            "contractCode": str(dispatched.get("contractCode", "")),
            "contractReason": str(dispatched.get("contractReason", "")),
        },
        "runtimeReceipt": _public_receipt(receipt),
        "projectKnowledge": public_project_knowledge(post_project_knowledge),
        "phaseCloseout": phase_closeout,
        "receiptReused": reused,
        "telemetry": {
            "path": str(_telemetry_path(core.memory_base, scope_ref)),
            "payloadHash": str(telemetry.get("payloadHash", "")),
            "reused": telemetry_reused,
        },
        "runObservability": telemetry.get("runObservability", {}),
        "terminalReplyAllowed": terminal_allowed,
        "mustContinue": not terminal_allowed,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def read_evidence(core: BrainCore) -> dict[str, Any]:
    """Read the current H7 evidence chain without activating or mutating state."""

    # Project the same H7-only guard used by the core status surface. Evidence
    # must not independently revive or assess retired prompt transports.
    # Evidence needs only the transport-retirement invariant.  Calling the
    # complete status projection here would additionally rebuild the MCP
    # runtime identity, binding status, activation summary, and contract
    # context immediately before this function reads its own scoped evidence.
    # The dedicated guard has the exact status payload and remains fail-closed.
    retired_transport_guard = core.retired_transport_guard()
    workspace = core._context_workspace_key()
    session = core._context_session_key()
    if not workspace or not session:
        return {
            "ok": True,
            "schema": SCHEMA,
            "mode": MODE,
            "phase": "evidence",
            "available": False,
            "code": "H7_EVIDENCE_SCOPE_MISSING",
            "retiredTransportGuard": retired_transport_guard,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    contract, code = core._read_context_contract(workspace, session)
    if not isinstance(contract, dict):
        return {
            "ok": True,
            "schema": SCHEMA,
            "mode": MODE,
            "phase": "evidence",
            "available": False,
            "code": code or "H7_EVIDENCE_CONTRACT_UNAVAILABLE",
            "retiredTransportGuard": retired_transport_guard,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    scope_ref = context_hash(
        {
            "workspaceKey": workspace,
            "ownerSessionKey": session,
            "taskId": str(contract.get("taskId", "")),
            "taskInstanceId": str(contract.get("taskInstanceId", "")),
        }
    )
    contract_hash = context_hash(contract)
    core_rules = core.core_rules()
    progress_status = core._project_progress_status(contract)
    visible_progress_status = core._visible_progress_status(contract, progress_status)
    open_receipt = _read_json(_scope_path(core.memory_base, scope_ref, "open"))
    close_receipt = _read_json(_scope_path(core.memory_base, scope_ref, "close"))
    telemetry = _read_json(_telemetry_path(core.memory_base, scope_ref))
    open_intent = (open_receipt or {}).get("turnIntent") if isinstance((open_receipt or {}).get("turnIntent"), dict) else {}
    execution_assist_raw = (open_receipt or {}).get("executionAssist")
    execution_assist = execution_assist_raw if execution_assist_receipt_is_valid(execution_assist_raw) else None
    project_knowledge: dict[str, Any] | None = None
    project_knowledge_code = "H7_PROJECT_KNOWLEDGE_RECEIPT_MISSING"
    if execution_assist is not None:
        project_knowledge, project_knowledge_code = _resolve_project_knowledge_for_turn(
            core,
            contract,
            progress_status,
            execution_assist,
        )
    close_execution_assist_raw = (close_receipt or {}).get("executionAssist")
    close_execution_assist = (
        close_execution_assist_raw if execution_assist_receipt_is_valid(close_execution_assist_raw) else None
    )
    close_project_knowledge: dict[str, Any] | None = None
    if close_execution_assist is not None:
        close_project_knowledge, _ = _resolve_project_knowledge_for_turn(
            core,
            contract,
            progress_status,
            close_execution_assist,
        )
    entry_current = _receipt_valid(
        open_receipt,
        phase="open",
        scope_ref=scope_ref,
        contract_hash=contract_hash,
        core_rules=core_rules,
        project_progress=progress_status,
        visible_progress=visible_progress_status,
        project_knowledge=project_knowledge,
    )
    close_current = _receipt_valid(
        close_receipt,
        phase="close",
        scope_ref=scope_ref,
        contract_hash=contract_hash,
        core_rules=core_rules,
        project_progress=progress_status,
        visible_progress=visible_progress_status,
        project_knowledge=close_project_knowledge,
    )
    route_receipt_raw = (open_receipt or {}).get("capabilityRouteReceipt")
    capability_route_receipt = route_receipt_raw if _capability_route_receipt_valid(route_receipt_raw) else None
    project_evidence_required = open_intent.get("projectEvidenceRequired") is True
    telemetry_events = (telemetry or {}).get("events", []) if isinstance((telemetry or {}).get("events", []), list) else []
    latest_telemetry = telemetry_events[-1] if telemetry_events and isinstance(telemetry_events[-1], dict) else {}
    telemetry_is_close = str(latest_telemetry.get("phase", "")) == "close"
    expected_telemetry_receipt_hash = str(
        ((close_receipt if telemetry_is_close else open_receipt) or {}).get("receiptHash", "")
    )
    telemetry_receipt_bound = bool(
        expected_telemetry_receipt_hash
        and str(latest_telemetry.get("receiptHash", "")) == expected_telemetry_receipt_hash
        and (close_current if telemetry_is_close else entry_current)
    )
    telemetry_execution_assist = close_execution_assist if telemetry_is_close else execution_assist
    telemetry_project_knowledge = close_project_knowledge if telemetry_is_close else project_knowledge
    telemetry_intent = (close_receipt or {}).get("turnIntent") if telemetry_is_close and isinstance((close_receipt or {}).get("turnIntent"), dict) else open_intent
    telemetry_route_raw = (close_receipt or {}).get("capabilityRouteReceipt") if telemetry_is_close else route_receipt_raw
    telemetry_capability_route = telemetry_route_raw if _capability_route_receipt_valid(telemetry_route_raw) else None
    telemetry_current = _telemetry_valid(
        telemetry,
        scope_ref=scope_ref,
        core_rules=core_rules,
        intent_hash=str((telemetry_intent or {}).get("payloadHash", "")),
        project_progress=progress_status,
        visible_progress=visible_progress_status,
        execution_assist=telemetry_execution_assist,
        project_knowledge=telemetry_project_knowledge,
        capability_route_receipt=telemetry_capability_route,
    )
    telemetry_current = telemetry_current and telemetry_receipt_bound
    observed_run_observability = (
        (telemetry or {}).get("runObservability")
        if isinstance((telemetry or {}).get("runObservability"), dict)
        else summarize_run_observability(telemetry, expected_scope_ref=scope_ref)
    )
    if not run_observability_receipt_is_valid(observed_run_observability, expected_scope_ref=scope_ref):
        observed_run_observability = summarize_run_observability(telemetry, expected_scope_ref=scope_ref)
    memory = (open_receipt or {}).get("memory") if isinstance((open_receipt or {}).get("memory"), dict) else {}
    return {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": "evidence",
        "available": entry_current and telemetry_current and project_knowledge is not None and visible_progress_status.get("current") is True and visible_progress_status.get("continuationEligible") is True and (not project_evidence_required or progress_status.get("current") is True),
        "code": (
            "H7_EVIDENCE_CORE_RULES_WITHHELD"
            if core_rules.get("status") != "current"
            else "H7_PROJECT_PROGRESS_WITHHELD"
            if project_evidence_required and progress_status.get("current") is not True
            else str(visible_progress_status.get("code", "H7_VISIBLE_PROGRESS_RECEIPT_REQUIRED"))
            if visible_progress_status.get("current") is not True
            else "H7_VISIBLE_PROGRESS_ASSISTANT_REPLY_REQUIRED"
            if visible_progress_status.get("continuationEligible") is not True
            else project_knowledge_code
            if project_knowledge is None
            else "H7_EVIDENCE_CURRENT" if entry_current and telemetry_current else "H7_EVIDENCE_INCOMPLETE"
        ),
        "scope": {
            "workspaceKey": workspace,
            "scopeRef": scope_ref,
            "taskId": str(contract.get("taskId", "")),
            "taskInstanceId": str(contract.get("taskInstanceId", "")),
            "contractRevision": int(contract.get("revision", 0) or 0),
            "contractHash": contract_hash,
        },
        "entry": {"current": entry_current, "receipt": _public_receipt(open_receipt) if isinstance(open_receipt, dict) else None},
        "oneShotReceipt": {"current": close_current, "receipt": _public_receipt(close_receipt) if isinstance(close_receipt, dict) else None},
        "telemetry": {
            "current": telemetry_current,
            "payloadHash": str((telemetry or {}).get("payloadHash", "")),
            "eventCount": len((telemetry or {}).get("events", []) or []),
        },
        "runObservability": observed_run_observability,
        "coreRules": core_rules,
        "projectProgress": {
            "state": str(progress_status.get("state", "withheld")),
            "payloadHash": str(progress_status.get("payloadHash", "")),
            "missing": list(progress_status.get("missing", []) or [])[:8],
            "completedCount": int(progress_status.get("completedCount", 0) or 0),
            "evidenceCount": int(progress_status.get("evidenceCount", 0) or 0),
            "verificationCount": int(progress_status.get("verificationCount", 0) or 0),
            "verificationState": str(progress_status.get("verificationState", "withheld")),
        },
        "visibleProgress": _visible_progress_truth(visible_progress_status),
        "turnIntent": _public_receipt(open_receipt).get("turnIntent", {}) if isinstance(open_receipt, dict) else {},
        "executionAssist": public_execution_assist(execution_assist),
        "projectKnowledge": public_project_knowledge(project_knowledge),
        "capabilityRouteReceipt": capability_route_receipt,
        "memoryInjection": {
            "snapshotPayloadHash": str(memory.get("snapshotPayloadHash", "")),
            "payloadHash": str(memory.get("payloadHash", "")),
            "refs": list(memory.get("refs", []) or []),
            "refsHash": str(memory.get("refsHash", "")),
        },
        "retiredTransportGuard": retired_transport_guard,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
def run_turn(core: BrainCore, *, phase: str = "open", **kwargs: Any) -> dict[str, Any]:
    """Small public interface used by CLI and MCP adapters."""

    retired = _retired_host_transport_result(
        phase if isinstance(phase, str) and phase else "open",
        **{key: kwargs.get(key) for key in _RETIRED_HOST_TRANSPORT_FIELDS if key in kwargs},
    )
    if retired is not None:
        return retired

    # The offline stdio replay is a parser/schema harness, not a local H7
    # transport.  Keep the guard here (rather than only in ``brain_mcp``) so
    # direct callers cannot invoke a governed lifecycle through an injected
    # replay core either.
    if getattr(core, "runtime_mode", "") == MCP_RUNTIME_MODE_OFFLINE_REPLAY:
        return _withheld(
            str(phase or "open"),
            {},
            "H7_MCP_OFFLINE_REPLAY_NOT_LIVE",
        )

    # External continuation state cannot prove the current local contract.
    # Reject the retired field explicitly instead of silently dropping it or
    # letting an old contract masquerade as current progress.
    if "continuation_capsule" in kwargs:
        return _withheld(
            str(phase or "open"),
            {},
            "H7_EXTERNAL_CONTINUATION_STATE_FORBIDDEN",
        )

    if phase == "open":
        return open_turn(
            core,
            memory_mode=str(kwargs.get("memory_mode", "auto")),
            turn_intent=str(kwargs.get("turn_intent", kwargs.get("intent", "direct"))),
            recovery_event=str(kwargs.get("recovery_event", "none")),
            execution_assist_request=kwargs.get("execution_assist_request"),
            capability_route_receipt=kwargs.get("capability_route_receipt"),
            user_control=str(kwargs.get("user_control", "unknown")),
            timeout=float(kwargs.get("timeout", 8.0)),
        )
    if phase == "close":
        return close_turn(
            core,
            memory_mode=str(kwargs.get("memory_mode", "auto")),
            turn_outcome=str(kwargs.get("turn_outcome", "unknown")),
            user_control=str(kwargs.get("user_control", "unknown")),
            completion_evidence_ref=str(kwargs.get("completion_evidence_ref", "")),
            progress_checkpoint=kwargs.get("progress_checkpoint") if isinstance(kwargs.get("progress_checkpoint"), dict) else None,
            project_progress_proof=kwargs.get("project_progress_proof") if isinstance(kwargs.get("project_progress_proof"), dict) else None,
            transition_id=str(kwargs.get("transition_id", "")),
            timeout=float(kwargs.get("timeout", 8.0)),
            turn_intent=str(kwargs.get("turn_intent", kwargs.get("intent", "direct"))),
            execution_assist_request=kwargs.get("execution_assist_request"),
            capability_route_receipt=kwargs.get("capability_route_receipt"),
            latest_user_instruction=(
                kwargs.get("latest_user_instruction")
                if isinstance(kwargs.get("latest_user_instruction"), str)
                else None
            ),
        )
    if phase == "checkpoint":
        return checkpoint_turn(
            core,
            memory_mode=str(kwargs.get("memory_mode", "auto")),
            progress_checkpoint=kwargs.get("progress_checkpoint") if isinstance(kwargs.get("progress_checkpoint"), dict) else None,
            project_progress_proof=kwargs.get("project_progress_proof") if isinstance(kwargs.get("project_progress_proof"), dict) else None,
            transition_id=str(kwargs.get("transition_id", "")),
            timeout=float(kwargs.get("timeout", 8.0)),
            turn_intent=str(kwargs.get("turn_intent", kwargs.get("intent", "continuity"))),
            execution_assist_request=kwargs.get("execution_assist_request"),
            capability_route_receipt=kwargs.get("capability_route_receipt"),
            latest_user_instruction=(
                kwargs.get("latest_user_instruction")
                if isinstance(kwargs.get("latest_user_instruction"), str)
                else None
            ),
        )
    if phase == "evidence":
        return read_evidence(core)
    return {
        "ok": False,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": str(phase),
        "available": False,
        "code": "TURN_RUNTIME_PHASE_INVALID",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


__all__ = ["MODE", "SCHEMA", "TELEMETRY_SCHEMA", "checkpoint_turn", "close_turn", "open_turn", "read_evidence", "run_turn"]
