"""Authoritative no-Hook Super Brain turn lifecycle.

This module is deliberately the only write-side entry point for the normal
MCP/CLI turn lifecycle.  It composes the existing execution contract,
typed-memory context, activation receipt, and continuation dispatcher without
introducing a worker, a second state store, or prompt persistence.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from activation_receipt import canonical_hash, ensure_current
from brain_context import canonical_hash as context_hash
from brain_core import BrainCore, agent_identity
from capability_shadow_eval import shadow_gate_is_valid
from execution_assist import capability_route_receipt as execution_assist_capability_route_receipt
from execution_assist import public_projection as public_execution_assist
from execution_assist import project_knowledge_route_is_valid
from execution_assist import receipt_is_valid as execution_assist_receipt_is_valid
from execution_assist import resolve_execution_assist
from project_knowledge import public_projection as public_project_knowledge
from project_knowledge import receipt_is_valid as project_knowledge_receipt_is_valid
from project_knowledge import resolve_project_knowledge
from run_observability import receipt_is_valid as run_observability_receipt_is_valid
from run_observability import summarize_telemetry as summarize_run_observability
from turn_close_dispatcher import _invoke_contract, dispatch_turn_close, record_progress_checkpoint
from turn_intent import public_projection as public_turn_intent
from turn_intent import resolve_turn_intent


SCHEMA = "super-brain.turn-runtime.v1"
RECEIPT_SCHEMA = "super-brain.turn-runtime-receipt.v1"
TELEMETRY_SCHEMA = "super-brain.turn-runtime-telemetry.v1"
MODE = "hookless_turn_runtime"
MAX_TELEMETRY_EVENTS = 16
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
VISIBLE_TAIL_ASSERTION_SCHEMA_V2 = "super-brain.visible-tail-observation.v2"
VISIBLE_TAIL_ASSERTION_SCHEMA_V3 = "super-brain.visible-tail-observation.v3"
VISIBLE_TAIL_ASSERTION_SCHEMA_V4 = "super-brain.visible-tail-observation.v4"
VISIBLE_TAIL_ASSERTION_PAYLOAD_PARSE_INVALID = "H7_VISIBLE_TAIL_ASSERTION_PAYLOAD_PARSE_INVALID"
VISIBLE_TAIL_ASSERTION_FIELDS_V2 = {
    "schema",
    "observation_source",
    "selection",
    "host_thread_id",
    "host_turn_id",
    "host_message_id",
    "message_phase",
    "last_confirmed_sentence",
    "source",
    "raw_prompt_stored",
    "raw_transcript_stored",
}
VISIBLE_TAIL_ASSERTION_FIELDS_V3 = VISIBLE_TAIL_ASSERTION_FIELDS_V2 | {"publication_kind"}
VISIBLE_TAIL_ASSERTION_FIELDS_V4_BASE = VISIBLE_TAIL_ASSERTION_FIELDS_V3 | {"envelope_version"}
VISIBLE_TAIL_ASSERTION_FIELDS_V4_DURABLE = VISIBLE_TAIL_ASSERTION_FIELDS_V4_BASE | {"h7_receipt_hash"}
VISIBLE_TAIL_OBSERVATION_SOURCE = "codex_app_read_thread"
VISIBLE_TAIL_OBSERVATION_SOURCES = {
    VISIBLE_TAIL_OBSERVATION_SOURCE,
    "codex_visible_context",
}
VISIBLE_TAIL_VISIBLE_CONTEXT_SOURCE = "codex_visible_context"
# Normal same-workline tail observation.  It always means the newest actual
# assistant message, never a backward scan for a nicer-looking old receipt.
VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION = "current_visible_assistant"
VISIBLE_TAIL_CONTINUATION_SELECTION = "latest_durable_assistant"
# A mismatch-only diagnostic selector.  It cannot be used as the normal
# visible-context path or as a silent repair input.
VISIBLE_TAIL_AUTO_FINALIZE_SELECTION = "latest_assistant"
VISIBLE_TAIL_CHECKPOINT_SELECTION = "latest_assistant"
VISIBLE_TAIL_SELECTIONS = {
    VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION,
    VISIBLE_TAIL_CONTINUATION_SELECTION,
    VISIBLE_TAIL_AUTO_FINALIZE_SELECTION,
    VISIBLE_TAIL_CHECKPOINT_SELECTION,
}
VISIBLE_TAIL_HOST_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$")
VISIBLE_TAIL_MESSAGE_PHASES = {"commentary", "final"}
VISIBLE_TAIL_PUBLICATION_KIND_DURABLE = "h7_durable_progress"
VISIBLE_TAIL_PUBLICATION_KIND_LEGACY_WITHHELD = "legacy_h7_progress_withheld"
VISIBLE_TAIL_PUBLICATION_KIND_UNCLASSIFIED = "unclassified_assistant_reply"
VISIBLE_TAIL_ENVELOPE_VERSION_V4 = "v4"
VISIBLE_TAIL_ENVELOPE_VERSION_LEGACY_V3 = "legacy_v3"
VISIBLE_TAIL_ENVELOPE_VERSION_LEGACY_V2 = "legacy_v2"
VISIBLE_TAIL_ENVELOPE_VERSION_NONE = "none"
VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR = "durable_anchor"
VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY = "display_only"
VISIBLE_TAIL_ASSERTION_REQUIRED_INTENTS = {
    "task_status",
    "continuity",
    "super_brain_issue_continuity",
}
RECOVERY_PRESENTATION_SCHEMA = "super-brain.recovery-presentation.v1"
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

NORMAL_CONTINUITY_INTENTS = {
    "task_status",
    "continuity",
    "super_brain_issue_continuity",
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


def _strict_visible_text(value: Any, maximum: int) -> str | None:
    if not isinstance(value, str) or not value or len(value) > maximum or value != value.strip():
        return None
    if "\n" in value or "\r" in value or any(ord(character) < 32 for character in value):
        return None
    return value


def _normalize_visible_tail_assertion(value: Any) -> tuple[dict[str, Any] | None, str]:
    """Validate one transient observation from Codex's current thread tail.

    Raw Host ids are used only to prove the current scope and are never copied
    into a receipt or telemetry event.  The public projection retains hashes.
    """

    if value is None:
        return None, "H7_VISIBLE_TAIL_ASSERTION_REQUIRED"
    if not isinstance(value, dict):
        return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
    # ``host_visible_tail`` returns a transient helper result with one
    # transport-status field (``ok: true``).  H7's durable input shape has no
    # such field and remains exact-schema-only.  Accept this one wrapper only
    # when it is an actual successful helper result, strip it once, and let the
    # existing per-schema exact-field validation below reject every extra field.
    # In particular, ``ok: false`` is never an observation and caller-invented
    # fields cannot ride through the helper wrapper.
    if "ok" in value:
        if value.get("ok") is not True:
            return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
        value = {key: item for key, item in value.items() if key != "ok"}
    schema = str(value.get("schema", ""))
    publication_kind = VISIBLE_TAIL_PUBLICATION_KIND_UNCLASSIFIED
    envelope_version = VISIBLE_TAIL_ENVELOPE_VERSION_NONE
    h7_receipt_hash = ""
    if schema == VISIBLE_TAIL_ASSERTION_SCHEMA_V2:
        if set(value) != VISIBLE_TAIL_ASSERTION_FIELDS_V2:
            return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
        envelope_version = VISIBLE_TAIL_ENVELOPE_VERSION_LEGACY_V2
    elif schema == VISIBLE_TAIL_ASSERTION_SCHEMA_V3:
        if set(value) != VISIBLE_TAIL_ASSERTION_FIELDS_V3:
            return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
        publication_kind = str(value.get("publication_kind", ""))
        if publication_kind not in {
            VISIBLE_TAIL_PUBLICATION_KIND_DURABLE,
            VISIBLE_TAIL_PUBLICATION_KIND_UNCLASSIFIED,
        }:
            return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
        envelope_version = VISIBLE_TAIL_ENVELOPE_VERSION_LEGACY_V3
    elif schema == VISIBLE_TAIL_ASSERTION_SCHEMA_V4:
        publication_kind = str(value.get("publication_kind", ""))
        envelope_version = str(value.get("envelope_version", ""))
        if publication_kind == VISIBLE_TAIL_PUBLICATION_KIND_DURABLE:
            if set(value) != VISIBLE_TAIL_ASSERTION_FIELDS_V4_DURABLE:
                return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
            h7_receipt_hash = _strict_hash(value.get("h7_receipt_hash")) or ""
            if envelope_version != VISIBLE_TAIL_ENVELOPE_VERSION_V4 or not h7_receipt_hash:
                return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
        elif publication_kind in {
            VISIBLE_TAIL_PUBLICATION_KIND_LEGACY_WITHHELD,
            VISIBLE_TAIL_PUBLICATION_KIND_UNCLASSIFIED,
        }:
            if set(value) != VISIBLE_TAIL_ASSERTION_FIELDS_V4_BASE:
                return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
            expected_version = (
                VISIBLE_TAIL_ENVELOPE_VERSION_LEGACY_V3
                if publication_kind == VISIBLE_TAIL_PUBLICATION_KIND_LEGACY_WITHHELD
                else VISIBLE_TAIL_ENVELOPE_VERSION_NONE
            )
            if envelope_version != expected_version:
                return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
        else:
            return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
    else:
        return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
    observation_source = str(value.get("observation_source", ""))
    selection = str(value.get("selection", ""))
    host_thread_id = _strict_text(value.get("host_thread_id"), maximum=200, pattern=VISIBLE_TAIL_HOST_ID_RE)
    host_turn_id = _strict_text(value.get("host_turn_id"), maximum=200, pattern=VISIBLE_TAIL_HOST_ID_RE)
    host_message_id = _strict_text(value.get("host_message_id"), maximum=200, pattern=VISIBLE_TAIL_HOST_ID_RE)
    message_phase = str(value.get("message_phase", ""))
    sentence = _strict_visible_text(value.get("last_confirmed_sentence"), 320)
    source = str(value.get("source", ""))
    if (
        observation_source not in VISIBLE_TAIL_OBSERVATION_SOURCES
        or selection not in VISIBLE_TAIL_SELECTIONS
        or host_thread_id is None
        or host_turn_id is None
        or host_message_id is None
        or message_phase not in VISIBLE_TAIL_MESSAGE_PHASES
        or sentence is None
        or source != "assistant_visible_reply"
        or value.get("raw_prompt_stored") is not False
        or value.get("raw_transcript_stored") is not False
    ):
        return None, "H7_VISIBLE_TAIL_ASSERTION_INVALID"
    normalized = {
        "schema": schema,
        "observationSource": observation_source,
        "selection": selection,
        "hostThreadId": host_thread_id,
        "hostTurnId": host_turn_id,
        "hostMessageId": host_message_id,
        "messagePhase": message_phase,
        "lastConfirmedSentence": sentence,
        "source": source,
        "publicationKind": publication_kind,
        "envelopeVersion": envelope_version,
        "h7ReceiptHash": h7_receipt_hash,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    normalized["payloadHash"] = canonical_hash(normalized)
    return normalized, "H7_VISIBLE_TAIL_ASSERTION_CURRENT"


def _public_visible_tail_assertion(value: dict[str, Any] | None) -> dict[str, Any]:
    assertion = value if isinstance(value, dict) else {}
    if not assertion:
        return {
            "state": "withheld",
            "code": "H7_VISIBLE_TAIL_ASSERTION_REQUIRED",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    continuation_role = str(assertion.get("continuationRole", ""))
    if continuation_role not in {
        VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR,
        VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY,
    }:
        continuation_role = (
            VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR
            if _is_v4_durable_progress(assertion)
            else VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY
        )
    display_only = continuation_role == VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY
    return {
        "state": "observed_display_only" if display_only else "current",
        "code": "H7_VISIBLE_TAIL_DISPLAY_ONLY_CURRENT" if display_only else "H7_VISIBLE_TAIL_ASSERTION_CURRENT",
        "observationSource": str(assertion.get("observationSource", "")),
        "selection": str(assertion.get("selection", "")),
        "messagePhase": str(assertion.get("messagePhase", "")),
        "publicationKind": str(assertion.get("publicationKind", "")),
        "envelopeVersion": str(assertion.get("envelopeVersion", "")),
        "continuationRole": continuation_role,
        "nonAuthorizing": display_only,
        "h7ReceiptHash": str(assertion.get("h7ReceiptHash", "")),
        "hostThreadHash": hashlib.sha256(str(assertion.get("hostThreadId", "")).encode("utf-8")).hexdigest(),
        "hostTurnHash": hashlib.sha256(str(assertion.get("hostTurnId", "")).encode("utf-8")).hexdigest(),
        "hostMessageHash": hashlib.sha256(str(assertion.get("hostMessageId", "")).encode("utf-8")).hexdigest(),
        "sentenceHash": hashlib.sha256(str(assertion.get("lastConfirmedSentence", "")).encode("utf-8")).hexdigest(),
        "payloadHash": str(assertion.get("payloadHash", "")),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _is_v4_durable_progress(assertion: dict[str, Any]) -> bool:
    """Return whether the Host observation is the strict, receipt-bound v4 envelope."""

    return (
        str(assertion.get("schema", "")) == VISIBLE_TAIL_ASSERTION_SCHEMA_V4
        and str(assertion.get("publicationKind", "")) == VISIBLE_TAIL_PUBLICATION_KIND_DURABLE
        and str(assertion.get("envelopeVersion", "")) == VISIBLE_TAIL_ENVELOPE_VERSION_V4
        and _strict_hash(assertion.get("h7ReceiptHash")) is not None
    )


def _is_display_only_visible_tail(assertion: dict[str, Any]) -> bool:
    """Return whether the latest current tail may be acknowledged, not promoted.

    The Host must still prove that it observed this newest message.  An
    unclassified message *or a retired loose-H7/v3-shaped marker* is visible
    continuity evidence only when it is the current same-workline candidate.
    Neither form has a v4 receipt binding, so neither may become an H7 progress
    anchor, stage update, project proof, authorization, or contract mutation.
    """

    if (
        str(assertion.get("schema", "")) != VISIBLE_TAIL_ASSERTION_SCHEMA_V4
        or str(assertion.get("selection", "")) != VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION
        or str(assertion.get("h7ReceiptHash", ""))
    ):
        return False
    publication_kind = str(assertion.get("publicationKind", ""))
    envelope_version = str(assertion.get("envelopeVersion", ""))
    return (
        publication_kind == VISIBLE_TAIL_PUBLICATION_KIND_UNCLASSIFIED
        and envelope_version == VISIBLE_TAIL_ENVELOPE_VERSION_NONE
    ) or (
        publication_kind == VISIBLE_TAIL_PUBLICATION_KIND_LEGACY_WITHHELD
        and envelope_version == VISIBLE_TAIL_ENVELOPE_VERSION_LEGACY_V3
    )


def _is_current_visible_tail(assertion: dict[str, Any]) -> bool:
    """Return whether this is the exact newest same-workline Host candidate.

    The normal continuation selector is independent from durability.  A
    receipt-bound v4 message and ordinary/legacy visible prose can both be
    the latest actual assistant reply; only the former can prove a formal
    phase, completion, or high-impact action.  This small predicate keeps
    that split explicit and prevents a stale contract receipt from deciding
    what the user just saw.
    """

    return (
        str(assertion.get("schema", "")) == VISIBLE_TAIL_ASSERTION_SCHEMA_V4
        and str(assertion.get("selection", "")) == VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION
        and str(assertion.get("publicationKind", ""))
        in {
            VISIBLE_TAIL_PUBLICATION_KIND_DURABLE,
            VISIBLE_TAIL_PUBLICATION_KIND_LEGACY_WITHHELD,
            VISIBLE_TAIL_PUBLICATION_KIND_UNCLASSIFIED,
        }
    )


def _matches_current_visible_receipt(task: dict[str, Any], assertion: dict[str, Any]) -> bool:
    """Bind a Host v4 envelope to H7's stable visible-progress receipt hash."""

    visible = task.get("visibleProgress") if isinstance(task.get("visibleProgress"), dict) else {}
    return (
        _is_v4_durable_progress(assertion)
        and str(assertion.get("h7ReceiptHash", "")) == str(visible.get("payloadHash", ""))
        and bool(str(visible.get("payloadHash", "")))
    )


def _visible_tail_assertion_status(
    core: BrainCore,
    context: dict[str, Any],
    assertion: dict[str, Any],
    *,
    allow_display_only: bool = False,
) -> tuple[dict[str, Any] | None, str]:
    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    selection = str(assertion.get("selection", ""))
    if selection not in {
        VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION,
        VISIBLE_TAIL_CONTINUATION_SELECTION,
        VISIBLE_TAIL_AUTO_FINALIZE_SELECTION,
    }:
        return None, "H7_VISIBLE_TAIL_ASSERTION_SELECTION_INVALID"
    if not _visible_tail_assertion_matches_scope(core, context, assertion):
        return None, "H7_VISIBLE_TAIL_ASSERTION_SCOPE_MISMATCH"
    # The newest ordinary assistant commentary is visible state, but not task
    # progress.  On the uninterrupted same workline, acknowledge it as a
    # display-only readback so H7 never silently walks backward to an older
    # v4 receipt.  It intentionally cannot provide a sentence, phase, step,
    # action, receipt binding, or authorization for the continuation.
    if allow_display_only and _is_display_only_visible_tail(assertion):
        bound = {
            **assertion,
            "continuationRole": VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY,
            "currentPhase": str(task.get("currentPhase", "")),
            "currentStep": str(task.get("currentStep", "")),
            "nextAction": str(task.get("nextAction", "")),
        }
        bound["payloadHash"] = canonical_hash({key: value for key, value in bound.items() if key != "payloadHash"})
        return bound, "H7_VISIBLE_TAIL_DISPLAY_ONLY_CURRENT"
    # A normal anchor and the emergency fallback both begin with exactly the
    # same durable publication contract.  The selector only determines which
    # code path may use it; v2/v3/loose G1 text are observable for diagnosis
    # but cannot become a normal anchor or an auto-finalization input.
    if not _is_v4_durable_progress(assertion):
        return None, "H7_VISIBLE_TAIL_ASSERTION_V4_DURABLE_PROGRESS_REQUIRED"
    if not _matches_current_visible_receipt(task, assertion):
        return None, "H7_VISIBLE_TAIL_ASSERTION_RECEIPT_HASH_MISMATCH"
    if (
        str(assertion.get("lastConfirmedSentence", "")) != str(task.get("lastConfirmedSentence", ""))
        or str(assertion.get("source", "")) != str(task.get("lastConfirmedSource", ""))
    ):
        return None, "H7_VISIBLE_TAIL_ASSERTION_MISMATCH"
    bound = {
        **assertion,
        "continuationRole": VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR,
        "currentPhase": str(task.get("currentPhase", "")),
        "currentStep": str(task.get("currentStep", "")),
        "nextAction": str(task.get("nextAction", "")),
    }
    bound["payloadHash"] = canonical_hash({key: value for key, value in bound.items() if key != "payloadHash"})
    public = _public_visible_tail_assertion(bound)
    visible = task.get("visibleProgress") if isinstance(task.get("visibleProgress"), dict) else {}
    if str(public.get("sentenceHash", "")) != str(visible.get("sentenceHash", "")):
        return None, "H7_VISIBLE_TAIL_ASSERTION_MISMATCH"
    return bound, "H7_VISIBLE_TAIL_ASSERTION_CURRENT"


def _visible_tail_assertion_matches_scope(
    core: BrainCore,
    context: dict[str, Any],
    assertion: dict[str, Any],
) -> bool:
    """Return whether a normalized Host observation belongs to this H7 scope.

    This deliberately checks only Host/session ownership.  Text binding stays
    separate so a newer observed reply can block a stale walk-back without
    treating caller-provided stage fields as authoritative.
    """

    scope = context.get("scope") if isinstance(context.get("scope"), dict) else {}
    return core._session_key_from_host_thread(str(assertion.get("hostThreadId", ""))) == str(
        scope.get("ownerSessionKey", "")
    )


def _auto_finalize_observed_visible_tail(
    core: BrainCore,
    context: dict[str, Any],
    contract: dict[str, Any],
    assertion: dict[str, Any],
    *,
    project_progress_status: dict[str, Any] | None = None,
    user_control: str = "unknown",
    timeout: float = 8.0,
) -> tuple[dict[str, Any] | None, str]:
    """Validate the emergency drift fallback without mutating H7 state.

    A newer v4-looking message must block a walk-back to an older receipt, but
    its text is not execution authority.  This function verifies enough to
    distinguish a genuine scope-bound drift signal from an unrelated message,
    then requires the explicit correction checkpoint and a fresh publication.
    """

    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    scope = context.get("scope") if isinstance(context.get("scope"), dict) else {}
    if str(assertion.get("selection", "")) != VISIBLE_TAIL_AUTO_FINALIZE_SELECTION:
        return None, "H7_VISIBLE_TAIL_ASSERTION_SELECTION_INVALID"
    if not _visible_tail_assertion_matches_scope(core, context, assertion):
        return None, "H7_VISIBLE_TAIL_ASSERTION_SCOPE_MISMATCH"
    if not _is_v4_durable_progress(assertion):
        return None, "H7_VISIBLE_TAIL_AUTOFINALIZE_V4_DURABLE_PUBLICATION_REQUIRED"
    if not _matches_current_visible_receipt(task, assertion):
        return None, "H7_VISIBLE_TAIL_AUTOFINALIZE_RECEIPT_HASH_MISMATCH"
    if str(user_control or "unknown") in {"stop", "replace"}:
        return None, "H7_VISIBLE_TAIL_ASSERTION_MISMATCH"
    if (
        str(assertion.get("lastConfirmedSentence", "")) == str(task.get("lastConfirmedSentence", ""))
        and str(assertion.get("source", "")) == str(task.get("lastConfirmedSource", ""))
    ):
        return {
            "state": "not_required",
            "code": "H7_VISIBLE_TAIL_AUTOFINALIZE_NOT_REQUIRED",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }, "H7_VISIBLE_TAIL_AUTOFINALIZE_NOT_REQUIRED"

    # A v4 envelope proves only that the Host observed a bounded assistant
    # message after the *previous* H7 receipt.  It does not pre-authorize a
    # different sentence.  Automatically writing that sentence would let an
    # accidental or stale-but-well-formed envelope mutate the continuation
    # anchor.  Detection remains useful as a fast fallback, but repair now
    # requires the explicit H7 correction checkpoint, which rebinds the exact
    # Host sentence and current project proof before a fresh v4 publication.
    del core, contract, project_progress_status, scope, timeout
    return None, "H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED"


def _checkpoint_visible_tail_assertion_status(
    core: BrainCore,
    context: dict[str, Any],
    assertion: dict[str, Any],
    progress_checkpoint: dict[str, Any] | None,
    *,
    allow_legacy_correction: bool = False,
) -> tuple[dict[str, Any] | None, str]:
    """Validate one post-publication correction before it can replace H7 state.

    A normal checkpoint is prepared before its response is shown, so it cannot
    carry a Host observation yet.  A repair after a visible-tail mismatch is
    different: its candidate must be the actual latest Host observation and
    must exactly match the sentence being written.  This prevents a model from
    silently replacing a stale anchor with a guessed progress sentence.
    """

    scope = context.get("scope") if isinstance(context.get("scope"), dict) else {}
    if str(assertion.get("selection", "")) != VISIBLE_TAIL_CHECKPOINT_SELECTION:
        return None, "H7_VISIBLE_TAIL_ASSERTION_SELECTION_INVALID"
    if core._session_key_from_host_thread(str(assertion.get("hostThreadId", ""))) != str(scope.get("ownerSessionKey", "")):
        return None, "H7_VISIBLE_TAIL_ASSERTION_SCOPE_MISMATCH"
    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    if _is_v4_durable_progress(assertion):
        if not _matches_current_visible_receipt(task, assertion):
            return None, "H7_VISIBLE_TAIL_ASSERTION_RECEIPT_HASH_MISMATCH"
    elif not allow_legacy_correction:
        return None, "H7_VISIBLE_TAIL_ASSERTION_V4_DURABLE_PROGRESS_REQUIRED"
    checkpoint = progress_checkpoint if isinstance(progress_checkpoint, dict) else {}
    sentence = _strict_visible_text(checkpoint.get("last_confirmed_sentence"), 320)
    phase = _strict_visible_text(checkpoint.get("current_phase"), 120)
    step = _strict_visible_text(checkpoint.get("current_step"), 220)
    action = _strict_visible_text(checkpoint.get("next_action"), 360)
    if (
        sentence is None
        or phase is None
        or step is None
        or action is None
        or checkpoint.get("source") != "assistant_visible_reply"
        or sentence != str(assertion.get("lastConfirmedSentence", ""))
    ):
        return None, "H7_VISIBLE_TAIL_ASSERTION_CHECKPOINT_MISMATCH"
    bound = {
        **assertion,
        "currentPhase": phase,
        "currentStep": step,
        "nextAction": action,
    }
    bound["payloadHash"] = canonical_hash({key: value for key, value in bound.items() if key != "payloadHash"})
    return bound, "H7_VISIBLE_TAIL_ASSERTION_CURRENT"


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
    assertion: dict[str, Any] | None,
    recovery_event: str,
    parent_return_state_card: dict[str, Any] | None = None,
) -> tuple[dict[str, Any] | None, str]:
    """Build the exact, event-bound first recovery line for the Host.

    The full line is returned only in the transient runtime response.  The
    durable H7 receipt stores hashes through ``_public_recovery_presentation``
    so a compact progress sentence never becomes a prompt/transcript channel.
    """

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
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return {**body, "payloadHash": canonical_hash(body)}, "H7_RECOVERY_PRESENTATION_SUPPRESSED"
    display_only = False
    if recovery_event == "parent_return":
        card = parent_return_state_card if isinstance(parent_return_state_card, dict) else {}
        if str(card.get("state", "")) != "current":
            return None, "H7_PARENT_RETURN_STATE_CARD_REQUIRED"
        source = str(card.get("source", ""))
        sentence = str(card.get("lastConfirmedSentence", ""))
        phase = str(card.get("currentPhase", ""))
        step = str(card.get("currentStep", ""))
        action = str(card.get("nextAction", ""))
    else:
        if not isinstance(assertion, dict):
            return None, "H7_VISIBLE_TAIL_ASSERTION_REQUIRED"
        source = str(assertion.get("source", ""))
        sentence = str(assertion.get("lastConfirmedSentence", ""))
        phase = str(assertion.get("currentPhase", ""))
        step = str(assertion.get("currentStep", ""))
        action = str(assertion.get("nextAction", ""))
        display_only = (
            str(assertion.get("continuationRole", ""))
            == VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY
        )
    body = {
        "schema": RECOVERY_PRESENTATION_SCHEMA,
        # A boundary must acknowledge the current visible assistant tail even
        # when it is ordinary prose.  That acknowledgement is explicitly
        # non-authorizing: its sentence cannot replace the H7 durable
        # progress receipt, phase, proof, or action.
        "state": "display_only" if display_only else "current",
        "code": (
            "H7_RECOVERY_PRESENTATION_DISPLAY_ONLY_CURRENT"
            if display_only
            else "H7_RECOVERY_PRESENTATION_CURRENT"
        ),
        "event": recovery_event,
        "required": True,
        "openingLine": "已接上：" + sentence,
        "lastConfirmedSentence": sentence,
        "source": source,
        "currentPhase": phase,
        "currentStep": step,
        "nextAction": action,
        "nonAuthorizing": display_only,
        "hostVisibleReadback": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}, "H7_RECOVERY_PRESENTATION_CURRENT"


def _public_recovery_presentation(value: dict[str, Any] | None) -> dict[str, Any]:
    presentation = value if isinstance(value, dict) else {}
    opening_line = str(presentation.get("openingLine", ""))
    sentence = str(presentation.get("lastConfirmedSentence", ""))
    return {
        "schema": RECOVERY_PRESENTATION_SCHEMA,
        "state": str(presentation.get("state", "withheld")),
        "code": str(presentation.get("code", "H7_RECOVERY_PRESENTATION_WITHHELD")),
        "event": str(presentation.get("event", "")),
        "required": bool(presentation.get("required") is True),
        "nonAuthorizing": bool(presentation.get("nonAuthorizing") is True),
        "hostVisibleReadback": bool(presentation.get("hostVisibleReadback") is True),
        "openingLineHash": hashlib.sha256(opening_line.encode("utf-8")).hexdigest() if opening_line else "",
        "sentenceHash": hashlib.sha256(sentence.encode("utf-8")).hexdigest() if sentence else "",
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


def _resolve_project_knowledge_for_turn(
    core: BrainCore,
    contract: dict[str, Any],
    progress_status: dict[str, Any],
    execution_assist: dict[str, Any],
) -> tuple[dict[str, Any] | None, str]:
    """Run the H7-native proof slice only after scope and proof are current.

    The execution-assist receipt contains no project path.  This bridge takes
    the root exclusively from the already-bound Host scope and the focus files
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


def _scope_path(memory_base: Path, scope_ref: str, phase: str) -> Path:
    return memory_base / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref / f"{phase}.json"


def _telemetry_path(memory_base: Path, scope_ref: str) -> Path:
    return memory_base / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref}.json"


def _visible_progress_observation(
    context: dict[str, Any],
    assertion: dict[str, Any],
) -> dict[str, Any] | None:
    """Build one transient, non-authorizing visible-tail observation.

    Normal same-workline continuity already has the current visible assistant
    reply in hand.  Retaining a second durable readback card for every turn
    made that synchronization artifact look like a competing continuation
    authority.  The runtime receipt below is enough: it binds only hashes to
    this one invocation and never writes a task/state card.
    """

    scope = context.get("scope") if isinstance(context.get("scope"), dict) else {}
    task = context.get("task") if isinstance(context.get("task"), dict) else {}
    visible = task.get("visibleProgress") if isinstance(task.get("visibleProgress"), dict) else {}
    scope_ref = str(scope.get("scopeRef", ""))
    contract_hash = str(task.get("contractHash", ""))
    visible_receipt_hash = str(visible.get("payloadHash", ""))
    sentence_hash = str(visible.get("sentenceHash", ""))
    try:
        contract_revision = int(task.get("contractRevision", 0) or 0)
    except (TypeError, ValueError):
        return None
    continuation_role = str(assertion.get("continuationRole", ""))
    if continuation_role not in {
        VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR,
        VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY,
    }:
        return None
    # A durable v4 anchor must carry the scope-bound visible-progress receipt
    # and sentence hashes.  Ordinary current-tail prose is a different class:
    # it is a transient, non-authorizing locator and remains valid while the
    # durable receipt is withheld (for example immediately after entering a
    # new stage).  Requiring the old durable hashes here would turn a correct
    # display-only observation into an unrelated input-invalid blocker.
    if (
        not scope_ref
        or not _strict_hash(contract_hash)
        or contract_revision < 1
        or (
            continuation_role == VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR
            and (
                not _strict_hash(visible_receipt_hash)
                or not _strict_hash(sentence_hash)
            )
        )
    ):
        return None
    if continuation_role == VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR:
        if str(assertion.get("lastConfirmedSentence", "")) != str(task.get("lastConfirmedSentence", "")):
            return None
    elif not _is_display_only_visible_tail(assertion):
        return None
    body = {
        "schema": "super-brain.visible-progress-observation.v1",
        "scopeRef": scope_ref,
        "contractHash": contract_hash,
        "contractRevision": contract_revision,
        # ``visibleProgressReceiptHash`` / ``sentenceHash`` bind the durable
        # task-progress authority.  A display-only tail is deliberately kept
        # separate: it proves which *newest visible message* H7 observed but
        # cannot make that ordinary prose look like the durable progress
        # sentence in a readback consumer.
        "visibleProgressReceiptHash": visible_receipt_hash,
        "sentenceHash": sentence_hash,
        "displaySentenceHash": (
            hashlib.sha256(str(assertion.get("lastConfirmedSentence", "")).encode("utf-8")).hexdigest()
            if continuation_role == VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY
            else ""
        ),
        "hostThreadHash": hashlib.sha256(str(assertion.get("hostThreadId", "")).encode("utf-8")).hexdigest(),
        "hostTurnHash": hashlib.sha256(str(assertion.get("hostTurnId", "")).encode("utf-8")).hexdigest(),
        "hostMessageHash": hashlib.sha256(str(assertion.get("hostMessageId", "")).encode("utf-8")).hexdigest(),
        "observationSource": str(assertion.get("observationSource", "")),
        "selection": str(assertion.get("selection", "")),
        "continuationRole": continuation_role,
        "tailAssertionHash": str(assertion.get("payloadHash", "")),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    if (
        body["observationSource"] not in VISIBLE_TAIL_OBSERVATION_SOURCES
        or body["selection"] not in VISIBLE_TAIL_SELECTIONS
        or body["continuationRole"] not in {
            VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR,
            VISIBLE_TAIL_CONTINUATION_ROLE_DISPLAY_ONLY,
        }
        or not _strict_hash(str(body["tailAssertionHash"]))
    ):
        return None
    body["payloadHash"] = canonical_hash(body)
    return body


def _public_visible_progress_observation(value: dict[str, Any] | None) -> dict[str, Any]:
    observation = value if isinstance(value, dict) else {}
    if not observation:
        return {
            "state": "withheld",
            "code": "H7_VISIBLE_PROGRESS_OBSERVATION_REQUIRED",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    return {
        "schema": "super-brain.visible-progress-observation.v1",
        "state": "observed",
        "code": "H7_VISIBLE_PROGRESS_OBSERVATION_CURRENT",
        "contractRevision": int(observation.get("contractRevision", 0) or 0),
        "visibleProgressReceiptHash": str(observation.get("visibleProgressReceiptHash", "")),
        "sentenceHash": str(observation.get("sentenceHash", "")),
        "displaySentenceHash": str(observation.get("displaySentenceHash", "")),
        "hostThreadHash": str(observation.get("hostThreadHash", "")),
        "hostTurnHash": str(observation.get("hostTurnHash", "")),
        "hostMessageHash": str(observation.get("hostMessageHash", "")),
        "observationSource": str(observation.get("observationSource", "")),
        "selection": str(observation.get("selection", "")),
        "continuationRole": str(observation.get("continuationRole", "")),
        "payloadHash": str(observation.get("payloadHash", "")),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


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


def _contract_binding(core: BrainCore, context: dict[str, Any]) -> tuple[dict[str, Any] | None, str]:
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
    explicit authority read after current-tail mapping; otherwise activation
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


def _rebind_contract_to_current_host_session(
    core: BrainCore,
    contract: dict[str, Any],
    assertion: dict[str, Any],
    *,
    timeout: float,
) -> tuple[dict[str, Any] | None, str]:
    """CAS-rebind one unique contract after exact visible-tail proof.

    A new Codex task receives a new Host thread id. H7 may transfer the one
    unique recent contract in the same workspace only when the current Host
    tail proves the exact latest assistant progress and the old contract's
    project proof is still current. No summary, global pointer, memory entry,
    or caller-supplied phase/step/action participates.
    """

    current_session = core._context_session_key()
    workspace_key = core._context_workspace_key()
    old_session = str(contract.get("ownerSessionKey", ""))
    if (
        not current_session
        or not workspace_key
        or not old_session
        or current_session == old_session
        or str(contract.get("workspaceKey", "")).lower() != workspace_key.lower()
        or core._session_key_from_host_thread(str(assertion.get("hostThreadId", ""))) != current_session
        # Tail-first normalizes the exact newest v4 observation to
        # current_visible_assistant before this boundary rebind.  Keep the
        # legacy strict selector compatible, but never accept drift-only
        # latest_assistant here.
        or str(assertion.get("selection", "")) not in {
            VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION,
            VISIBLE_TAIL_CONTINUATION_SELECTION,
        }
        or not _is_v4_durable_progress(assertion)
        or str(assertion.get("h7ReceiptHash", ""))
        != str((contract.get("visibleProgressReceipt") or {}).get("payloadHash", ""))
        or str(assertion.get("lastConfirmedSentence", "")) != str(contract.get("lastConfirmedSentence", ""))
        or str(contract.get("lastConfirmedSource", "")) != "assistant_visible_reply"
    ):
        return None, "H7_SESSION_REBIND_VISIBLE_PROGRESS_MISMATCH"
    progress_status = core._project_progress_status(contract)
    if progress_status.get("current") is not True:
        return None, "H7_SESSION_REBIND_PROJECT_PROOF_WITHHELD"
    progress = {
        "source": "assistant_visible_reply",
        "last_confirmed_sentence": str(contract.get("lastConfirmedSentence", "")),
        "current_phase": str(contract.get("currentPhase", "")),
        "current_step": str(contract.get("currentStep", "")),
        "next_action": str(contract.get("nextAction", "")),
    }
    progress_base64 = base64.b64encode(
        json.dumps(progress, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")
    code, rebound = _invoke_contract(
        core.package_root,
        core.memory_base,
        action="Set",
        task_id=str(contract.get("taskId", "")),
        workspace_key=workspace_key,
        session_key=current_session,
        timeout=timeout,
        extra=[
            "-RebindSession",
            "-FocusId", str(contract.get("focusId", "")),
            "-InstructionMode", str(contract.get("instructionMode", "continue")),
            "-CurrentPhase", str(contract.get("currentPhase", "")),
            "-CurrentStep", str(contract.get("currentStep", "")),
            "-NextAction", str(contract.get("nextAction", "")),
            "-ProgressCheckpointBase64", progress_base64,
            "-ExpectedRevision", str(int(contract.get("revision", 0) or 0)),
            "-ExpectedPlanFingerprint", str((contract.get("planReceipt") or {}).get("planFingerprint", "")),
            "-TransitionId", "h7-session-rebind-" + hashlib.sha256(
                (str(contract.get("taskId", "")) + "|" + old_session + "|" + current_session).encode("utf-8")
            ).hexdigest()[:24],
            "-Source", "turn-runtime:verified-visible-tail-session-rebind",
        ],
    )
    if code != 0 or not isinstance(rebound, dict) or rebound.get("ok") is not True:
        return None, str((rebound or {}).get("code", "H7_SESSION_REBIND_FAILED"))
    if (
        str(rebound.get("ownerSessionKey", "")) != current_session
        or str(rebound.get("taskInstanceId", "")) != str(contract.get("taskInstanceId", ""))
        or str(rebound.get("lastConfirmedSentence", "")) != progress["last_confirmed_sentence"]
        or str((rebound.get("projectProgressProof") or {}).get("payloadHash", ""))
        != str((contract.get("projectProgressProof") or {}).get("payloadHash", ""))
        or _strict_hash(str((rebound.get("visibleProgressReceipt") or {}).get("payloadHash", ""))) is None
        or str((rebound.get("visibleProgressReceipt") or {}).get("payloadHash", ""))
        == str(assertion.get("h7ReceiptHash", ""))
    ):
        return None, "H7_SESSION_REBIND_RESULT_INVALID"
    # The contract mutation must rebuild the derived current-session index in
    # the same handover.  A valid contract without this projection used to
    # strand H7 after a hot update until an unrelated retry happened.
    indexed, index_code = core._read_context_contract(workspace_key, current_session)
    if not isinstance(indexed, dict) or str(indexed.get("taskInstanceId", "")) != str(rebound.get("taskInstanceId", "")):
        return None, "H7_SESSION_REBIND_HOT_INDEX_REBUILD_REQUIRED:" + str(index_code)
    return rebound, "H7_SESSION_REBOUND"


def _activation(
    core: BrainCore,
    context: dict[str, Any],
    contract: dict[str, Any],
    memory_mode: str,
    *,
    action_authorization: str = "withheld",
) -> tuple[dict[str, Any], str, list[str]]:
    scope = context["scope"]
    typed_memory = context.get("typedMemory") if isinstance(context.get("typedMemory"), dict) else {}
    refs = _refs(typed_memory)
    anchor = contract.get("instructionAnchor") if isinstance(contract.get("instructionAnchor"), dict) else {}
    continuation = contract.get("continuationReceipt") if isinstance(contract.get("continuationReceipt"), dict) else {}
    recovery = contract.get("recoveryCheckpoint") or contract.get("checkpoint")
    recovery = recovery if isinstance(recovery, dict) else {}
    receipt, code = ensure_current(
        core.package_root,
        core.memory_base,
        memory_root=core.memory_root if core.memory_root.exists() else core.memory_base,
        workspace_key=str(scope.get("workspaceKey", "")),
        session_key=str(scope.get("ownerSessionKey", "")),
        task_id=str(contract.get("taskId", "")),
        task_instance_id=str(contract.get("taskInstanceId", "")),
        route="current_session_continue",
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
    visible_tail_assertion: dict[str, Any] | None = None,
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
    if isinstance(visible_tail_assertion, dict) and visible_tail_assertion.get("state") == "current":
        body["visibleTailAssertion"] = visible_tail_assertion
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
    existing = _read_json(path)
    if (
        isinstance(existing, dict)
        and existing.get("schema") == RECEIPT_SCHEMA
        and existing.get("mode") == MODE
        and existing.get("phase") == phase
        and str(existing.get("bindingHash", "")) == binding_hash
        and str(existing.get("receiptHash", "")) == canonical_hash({key: value for key, value in existing.items() if key != "receiptHash"})
    ):
        return existing, True
    value = dict(body)
    value["receiptId"] = f"tr-{phase}-{binding_hash[:24]}"
    value["receiptHash"] = canonical_hash(value)
    _atomic_json(path, value)
    return value, False


def _record_telemetry(
    memory_base: Path,
    scope_ref: str,
    receipt: dict[str, Any],
    *,
    runtime_duration_ms: int | None = None,
) -> tuple[dict[str, Any], bool]:
    path = _telemetry_path(memory_base, scope_ref)
    prior = _read_json(path) or {}
    events = prior.get("events") if isinstance(prior.get("events"), list) else []
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
        "visibleTailAssertionHash": str((receipt.get("visibleTailAssertion") or {}).get("payloadHash", "")),
        "visibleTailHostMessageHash": str((receipt.get("visibleTailAssertion") or {}).get("hostMessageHash", "")),
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
    if events and isinstance(events[-1], dict) and events[-1].get("receiptHash") == event["receiptHash"]:
        return prior, True
    next_events = [item for item in events if isinstance(item, dict)][-(MAX_TELEMETRY_EVENTS - 1) :] + [event]
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
    _atomic_json(path, value)
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
        "visibleTailAssertion": value.get("visibleTailAssertion") if isinstance(value.get("visibleTailAssertion"), dict) else {},
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


def visible_tail_assertion_payload_parse_invalid(phase: str) -> dict[str, Any]:
    """Return the stable fail-closed result for a malformed CLI tail payload.

    Transport decoding is distinct from H7 observation-schema validation.  The
    CLI uses this small public adapter so Windows argument quoting, malformed
    Base64, non-object JSON, and mutually supplied encodings do not masquerade
    as a validly transported but schema-invalid Host observation.
    """

    return _withheld(
        str(phase or "open"),
        {},
        VISIBLE_TAIL_ASSERTION_PAYLOAD_PARSE_INVALID,
    )


def _public_tail_first_mapping(mapping: dict[str, Any] | None) -> dict[str, Any]:
    """Return a compact non-sensitive continuation mapping projection.

    It makes the normal continuation decision observable without leaking the
    visible reply, raw task id, workspace path, or a private contract body.
    The mapping is a read-only diagnostic bridge, never a second task card.
    """

    value = mapping if isinstance(mapping, dict) else {}
    source_state = str(value.get("state", "unavailable"))
    # ``BrainCore`` keeps the read-side state deliberately small.  The public
    # runtime projection spells out that a mapped record belongs to the active
    # same workline, so callers do not mistake it for a task selected from the
    # assistant message itself.
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
        "code": str(value.get("code", "H7_TAIL_FIRST_MAPPING_REQUIRED")),
        "source": str(value.get("source", "current_visible_assistant")),
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


def _withheld_tail_first_mapping(
    context: dict[str, Any],
    code: str,
    mapping: dict[str, Any] | None,
) -> dict[str, Any]:
    """Return one fail-closed result without hiding tail-first diagnostics."""

    public_mapping = _public_tail_first_mapping(mapping)
    projected_context = dict(context) if isinstance(context, dict) else {}
    projected_context["continuityMapping"] = public_mapping
    result = _withheld("open", projected_context, code)
    result["continuityMapping"] = public_mapping
    return result


def _same_workline_assertion(
    assertion: dict[str, Any] | None,
) -> tuple[dict[str, Any] | None, str]:
    """Canonicalize the one current-tail selector used by normal recovery.

    Earlier H7 adapters named strict classification of the *same newest* item
    ``latest_durable_assistant``.  It is safe to retain that wire shape only
    when it is a strict v4 observation, then canonicalize it to
    ``current_visible_assistant`` before task mapping.  ``latest_assistant``
    remains drift-diagnosis-only and cannot enter this path.
    """

    if not isinstance(assertion, dict):
        return None, "H7_VISIBLE_TAIL_ASSERTION_REQUIRED"
    selection = str(assertion.get("selection", ""))
    if selection == VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION:
        return assertion, "H7_VISIBLE_TAIL_ASSERTION_CURRENT"
    if selection == VISIBLE_TAIL_CONTINUATION_SELECTION and _is_v4_durable_progress(assertion):
        current = {**assertion, "selection": VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION}
        current["payloadHash"] = canonical_hash({key: value for key, value in current.items() if key != "payloadHash"})
        return current, "H7_VISIBLE_TAIL_LEGACY_SELECTOR_CANONICALIZED"
    return None, "H7_VISIBLE_TAIL_CURRENT_ASSISTANT_REQUIRED"


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
    contract, visible-tail card, telemetry, task card, or memory body.  It
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
        "continuityMapping": _public_tail_first_mapping(
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


def _direct_host_path(phase: str, intent: dict[str, Any]) -> dict[str, Any]:
    return {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": phase,
        "available": False,
        "code": "TURN_INTENT_DIRECT_HOST_PATH",
        "turnIntent": public_turn_intent(intent),
        "continuityMapping": _public_tail_first_mapping(
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


def open_turn(
    core: BrainCore,
    *,
    memory_mode: str = "auto",
    record_telemetry: bool = True,
    turn_intent: str = "direct",
    recovery_event: str = "none",
    execution_assist_request: Any = None,
    capability_route_receipt: Any = None,
    visible_progress_assertion: Any = None,
    require_visible_tail_assertion: bool = True,
    user_control: str = "unknown",
    execution_apply_phase: str = "planning",
    allow_terminal_finalization: bool = False,
    timeout: float = 8.0,
) -> dict[str, Any]:
    """Build one scope-bound memory/continuity packet and receipt.

    The context projection is still the source of truth; this function merely
    binds that projection to a governed activation and a bounded receipt.
    """

    started_at = time.perf_counter()
    intent = resolve_turn_intent(turn_intent, memory_mode=memory_mode)
    if intent.get("ok") is not True:
        return _withheld("open", {"turnIntent": public_turn_intent(intent)}, str(intent.get("code", "TURN_INTENT_INVALID")))
    if intent.get("governed") is not True:
        return _direct_host_path("open", intent)
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
    normalized_recovery_event = str(recovery_event or "none")
    if normalized_recovery_event not in RECOVERY_EVENTS:
        return _withheld("open", {"turnIntent": public_turn_intent(intent)}, "H7_RECOVERY_EVENT_INVALID")
    normalized_visible_tail_assertion: dict[str, str] | None = None
    visible_tail_assertion_code = ""
    if visible_progress_assertion is not None:
        normalized_visible_tail_assertion, visible_tail_assertion_code = _normalize_visible_tail_assertion(
            visible_progress_assertion
        )
        if normalized_visible_tail_assertion is None:
            return _withheld("open", {"turnIntent": public_turn_intent(intent)}, visible_tail_assertion_code)
    # Tail-first normal continuation -------------------------------------------------
    #
    # The newest visible assistant reply answers only "where do we resume?".
    # Before old H7 context/proof/receipt data may influence an action, map that
    # exact current Host tail to one scoped task and its live contract step.
    # This keeps a stale contract from winning merely because it was checked
    # earlier than the message the user actually saw.
    normal_continuity = str(intent.get("kind", "")) in NORMAL_CONTINUITY_INTENTS
    tail_first_mapping: dict[str, Any] | None = None
    if normalized_recovery_event != "parent_return" and normal_continuity:
        if require_visible_tail_assertion and normalized_visible_tail_assertion is None:
            # Every same-workline continuation begins with the current visible
            # assistant tail.  A process-local cache, prior receipt, contract,
            # or rule/proof hash cannot bypass that locator, including within
            # one long-lived H7 process.  This keeps a newer plain or drifted
            # visible reply from being followed by stale unseen progress.
            return _withheld_tail_first_mapping(
                {"turnIntent": public_turn_intent(intent)},
                "H7_VISIBLE_TAIL_ASSERTION_REQUIRED",
                {
                    "state": "unavailable",
                    "code": "H7_VISIBLE_TAIL_ASSERTION_REQUIRED",
                    "source": "current_visible_assistant",
                    "visibleContextAvailable": False,
                    "stateCardUsed": False,
                },
            )
        if normalized_visible_tail_assertion is not None:
            # `latest_assistant` is not a normal selector.  It means the
            # controller has already detected a visible-tail drift and is
            # deliberately entering the emergency fallback.  Map the current
            # scoped task for diagnosis (so an old action cannot be repeated),
            # but require an explicit H7 checkpoint/replay before it can
            # continue.  Never canonicalize it into normal continuation.
            if str(normalized_visible_tail_assertion.get("selection", "")) == VISIBLE_TAIL_AUTO_FINALIZE_SELECTION:
                drift_mapping = core.tail_first_task_mapping(
                    str(normalized_visible_tail_assertion.get("hostThreadId", ""))
                )
                if str(drift_mapping.get("state", "")) == "mapped":
                    drift_mapping = {**drift_mapping, "duplicateActionBlocked": True}
                return _withheld_tail_first_mapping(
                    {"turnIntent": public_turn_intent(intent)},
                    "H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED",
                    drift_mapping,
                )
            normalized_visible_tail_assertion, tail_selector_code = _same_workline_assertion(normalized_visible_tail_assertion)
            if normalized_visible_tail_assertion is None:
                return _withheld_tail_first_mapping(
                    {"turnIntent": public_turn_intent(intent)},
                    tail_selector_code,
                    {
                        "state": "unavailable",
                        "code": tail_selector_code,
                        "source": "current_visible_assistant",
                        "visibleContextAvailable": True,
                        "stateCardUsed": False,
                    },
                )
            tail_first_mapping = core.tail_first_task_mapping(
                str(normalized_visible_tail_assertion.get("hostThreadId", ""))
            )
            mapping_state = str(tail_first_mapping.get("state", "unavailable"))
            if mapping_state == "ordinary_no_task":
                return _ordinary_no_task_open(
                    core,
                    intent=intent,
                    mapping=tail_first_mapping,
                    normalized_recovery_event=normalized_recovery_event,
                )
            if mapping_state == "rebind_required":
                # Do not turn a cross-session candidate into an ordinary
                # current task.  The existing strict CAS rebind below will
                # prove identity, exact v4 visibility, and project proof.
                pass
            elif mapping_state != "mapped":
                return _withheld_tail_first_mapping(
                    {"turnIntent": public_turn_intent(intent)},
                    str(tail_first_mapping.get("code", "H7_TAIL_FIRST_TASK_MAPPING_UNAVAILABLE")),
                    tail_first_mapping,
                )
    elif normalized_recovery_event != "parent_return" and normalized_visible_tail_assertion is not None:
        # Checkpoint/close may carry the drift-only ``latest_assistant``
        # observation used to bind an exact corrective checkpoint.  It is not
        # a normal continuation selector, so leave it untouched here.
        pass
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
    )
    session_rebind: dict[str, Any] | None = None
    if (
        isinstance(context, dict)
        and context.get("ok") is True
        and context.get("available") is not True
        and str(context.get("code", "")) == "BRAIN_CONTEXT_HOT_INDEX_MISSING"
        and isinstance(tail_first_mapping, dict)
        and str(tail_first_mapping.get("state", "")) == "rebind_required"
        and normalized_visible_tail_assertion is not None
        and normalized_recovery_event in {"restart", "model_switch", "cross_session", "pause_resume", "user_correction", "compaction"}
    ):
        candidate = tail_first_mapping.get("_contract") if isinstance(tail_first_mapping.get("_contract"), dict) else None
        if candidate is None:
            return _withheld("open", context, "H7_TAIL_FIRST_SESSION_REBIND_CANDIDATE_REQUIRED")
        rebound, rebind_code = _rebind_contract_to_current_host_session(
            core,
            candidate,
            normalized_visible_tail_assertion,
            timeout=timeout,
        )
        if rebound is None:
            return _withheld("open", context, rebind_code)
        session_rebind = {
            "state": "rebound",
            "code": rebind_code,
            "taskIdHash": hashlib.sha256(str(rebound.get("taskId", "")).encode("utf-8")).hexdigest(),
            "taskInstanceId": str(rebound.get("taskInstanceId", "")),
            "revision": int(rebound.get("revision", 0) or 0),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        context = core.context(
            effective_memory_mode,
            "unknown",
            "unknown",
            False,
            governed_rule_signals,
        )
    if not isinstance(context, dict) or context.get("ok") is not True or context.get("available") is not True:
        return _withheld_tail_first_mapping(
            context if isinstance(context, dict) else {},
            str((context or {}).get("code", "TURN_RUNTIME_CONTEXT_INVALID")),
            tail_first_mapping,
        )
    context["turnIntent"] = public_turn_intent(intent)
    context["executionAssist"] = public_execution_assist(execution_assist)
    if capability_route_compatibility is not None:
        context["capabilityRouteCompatibility"] = capability_route_compatibility
    contract, contract_code = _contract_binding(core, context)
    if contract is None:
        return _withheld_tail_first_mapping(context, contract_code, tail_first_mapping)
    if isinstance(tail_first_mapping, dict) and str(tail_first_mapping.get("state", "")) == "mapped":
        if (
            str(tail_first_mapping.get("contractHash", "")) != context_hash(contract)
            or str(tail_first_mapping.get("taskInstanceId", "")) != str(contract.get("taskInstanceId", ""))
        ):
            mapping = {**tail_first_mapping, "duplicateActionBlocked": True}
            return _withheld_tail_first_mapping(context, "H7_TAIL_FIRST_TASK_MAPPING_CHANGED", mapping)
    progress_status = core._project_progress_status(contract)
    strict_open = str(intent.get("kind", "")) in FORMAL_OPEN_INTENTS
    # `checkpoint_turn` opens internally with `require_visible_tail_assertion`
    # disabled so it can reconcile/write the exact checkpoint itself.  That is
    # still a formal mutation preflight, not a normal display-only
    # continuation, therefore it must retain the durable visible-progress
    # gates that trigger the existing H7 reconciliation path.
    strict_state_preflight = strict_open or not require_visible_tail_assertion
    if strict_state_preflight and intent.get("projectEvidenceRequired") is True and progress_status.get("current") is not True:
        return _withheld("open", context, "H7_PROJECT_PROGRESS_WITHHELD")
    visible_progress_status = (
        (context.get("task") or {}).get("visibleProgress")
        if isinstance(context.get("task"), dict)
        else {}
    )
    # A plain current reply is allowed to locate the current workline while
    # H7 silently reports stale proof as diagnostic-only state.  A strict v4
    # reply is different: it asserts that this exact visible sentence is the
    # durable, scope-bound progress publication.  If the contract's own
    # visible-progress receipt or project proof no longer validates, letting a
    # normal continuity open succeed would expose that stale v4 claim as a
    # usable anchor despite its broken phase/step/action/proof binding.
    #
    # Keep this gate deliberately narrow.  It does not promote a plain tail,
    # does not inspect an older anchor, and does not mutate the contract.  It
    # only fail-closes a *current strict-v4* candidate whose durable binding is
    # already known to be invalid, leaving the explicit H7 checkpoint/replay
    # route as the sole repair path.
    strict_current_v4_tail = (
        normal_continuity
        and isinstance(normalized_visible_tail_assertion, dict)
        and str(normalized_visible_tail_assertion.get("selection", ""))
        == VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION
        and _is_v4_durable_progress(normalized_visible_tail_assertion)
    )
    if strict_current_v4_tail and (
        progress_status.get("current") is not True
        or not isinstance(visible_progress_status, dict)
        or visible_progress_status.get("state") != "current"
        or visible_progress_status.get("continuationEligible") is not True
    ):
        strict_mapping = (
            {
                **tail_first_mapping,
                "projectProgressState": str(progress_status.get("state", "withheld")),
                "visibleProgressState": str((visible_progress_status or {}).get("state", "withheld")),
                "stageAdvanceAllowed": False,
                "duplicateActionBlocked": True,
            }
            if isinstance(tail_first_mapping, dict)
            else tail_first_mapping
        )
        return _withheld_tail_first_mapping(
            context,
            "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH",
            strict_mapping,
        )
    display_only_tail_supplied = (
        isinstance(normalized_visible_tail_assertion, dict)
        and _is_display_only_visible_tail(normalized_visible_tail_assertion)
        and normal_continuity
    )
    if strict_state_preflight and (
        (not isinstance(visible_progress_status, dict) or visible_progress_status.get("state") != "current")
        and not display_only_tail_supplied
    ):
        return _withheld(
            "open",
            context,
            str((visible_progress_status or {}).get("code", "H7_VISIBLE_PROGRESS_RECEIPT_REQUIRED")),
        )
    if strict_state_preflight and (
        isinstance(visible_progress_status, dict)
        and visible_progress_status.get("continuationEligible") is not True
        and not display_only_tail_supplied
    ):
        # ``user_attested_visible_reply`` is deliberately a one-way
        # reconciliation bridge: it can repair a missing/stale anchor, but
        # cannot by itself authorize ordinary work.  A following H7
        # checkpoint must be sourced from the exact assistant-visible progress
        # sentence that will be shown to the user.
        return _withheld("open", context, "H7_VISIBLE_PROGRESS_ASSISTANT_REPLY_REQUIRED")
    # Mapping is produced after the current tail and before H7 context.  Add
    # the background validation result only now.  A normal continuity/status
    # turn remains available when those checks are stale, but cannot use that
    # fact to advance a stage, repeat an old action, or make a progress claim.
    if isinstance(tail_first_mapping, dict):
        mapping = {
            **tail_first_mapping,
            "projectProgressState": str(progress_status.get("state", "withheld")),
            "visibleProgressState": str((visible_progress_status or {}).get("state", "withheld")),
            "stageAdvanceAllowed": bool(
                strict_open
                and progress_status.get("current") is True
                and isinstance(visible_progress_status, dict)
                and visible_progress_status.get("state") == "current"
                and visible_progress_status.get("continuationEligible") is True
            ),
            # Any normal continuation begins diagnostic/read-only until a
            # separate checkpoint supplies fresh proof.  This is the direct
            # duplicate-action guard requested for drift handling.
            "duplicateActionBlocked": _is_nonblocking_continuity_intent(intent),
        }
        tail_first_mapping = mapping
        context["continuityMapping"] = _public_tail_first_mapping(mapping)
    if session_rebind is not None:
        # A cross-session rebind changes the scope-bound visible-progress
        # receipt hash.  The old-thread v4 envelope is sufficient to prove
        # the one CAS transfer, but it must never be reused as the new
        # session's normal anchor.  Rebuild activation now, expose only the
        # new receipt hash, and require the Host to publish the exact same
        # H7 sentence in a fresh v4 envelope before continuation.
        rebound_activation, rebound_activation_code, _ = _activation(
            core,
            context,
            contract,
            effective_memory_mode,
        )
        capabilities = rebound_activation.get("capabilities") if isinstance(rebound_activation.get("capabilities"), dict) else {}
        if (
            rebound_activation.get("activationState") != "full_brain_active"
            or capabilities.get("coreReady") is not True
        ):
            return _withheld("open", context, "H7_SESSION_REBIND_ACTIVATION_REBUILD_REQUIRED")
        session_rebind["activationReceiptHash"] = str(rebound_activation.get("receiptHash", ""))
        session_rebind["visibleProgressReceiptHash"] = str(visible_progress_status.get("payloadHash", ""))
        session_rebind["republishRequired"] = True
        withheld = _withheld("open", context, "H7_SESSION_REBOUND_REPUBLISH_REQUIRED")
        withheld["sessionRebind"] = session_rebind
        return withheld
    # The current visible assistant message is always read first on the same
    # workline: ordinary continuation, compaction/restart recovery, and a
    # pause followed by continue all require it.  A plain latest message is a
    # display-only fact: it cannot change the durable progress, phase, proof,
    # or authorization, but it also must not make H7 walk backward to an old
    # v4 anchor.  ``parent_return`` is the one bounded exception because its
    # visible tail belongs to the completed child line; H7 selects the
    # already-approved parent through its current state card instead.
    parent_return_state_card: dict[str, Any] | None = None
    if normalized_recovery_event == "parent_return":
        parent_return_state_card, parent_return_code = _parent_return_state_card(context, contract)
        if parent_return_state_card is None:
            return _withheld("open", context, parent_return_code)
        # This is the sole legal state-card selector.  It maps the already
        # approved parent after a verified ResumeParent transition; normal
        # same-workline continuation never allows a card to displace the
        # current visible assistant tail.
        tail_first_mapping = {
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
        context["continuityMapping"] = _public_tail_first_mapping(tail_first_mapping)
        context["parentReturnStateCard"] = {
            "state": "current",
            "code": parent_return_code,
            "payloadHash": str(parent_return_state_card.get("payloadHash", "")),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    assertion_required = (
        require_visible_tail_assertion
        and normalized_recovery_event != "parent_return"
        and (
        str(intent.get("kind", "")) in VISIBLE_TAIL_ASSERTION_REQUIRED_INTENTS
        or normalized_recovery_event != "none"
        )
    )
    if assertion_required and normalized_visible_tail_assertion is None:
        return _withheld("open", context, "H7_VISIBLE_TAIL_ASSERTION_REQUIRED")
    visible_tail_assertion: dict[str, Any] | None = None
    public_visible_tail_assertion: dict[str, Any] | None = None
    visible_progress_observation: dict[str, Any] | None = None
    if normalized_visible_tail_assertion is not None and normalized_recovery_event != "parent_return":
        visible_tail_assertion, visible_tail_assertion_code = _visible_tail_assertion_status(
            core,
            context,
            normalized_visible_tail_assertion,
            # A same-workline tail is always first-class visible evidence.
            # At a recovery boundary normal prose remains display-only rather
            # than becoming an implicit old-v4 fallback or an avoidable
            # blocker.  Only a genuine recovery presentation requires a
            # durable anchor; below it is suppressed for this observation.
            allow_display_only=True,
        )
        if visible_tail_assertion is None:
            # A newer Host-visible assistant reply is not an excuse to walk
            # back to the old receipt.  The fallback is detection-only: it
            # returns an explicit reconciliation requirement and never writes
            # a sentence, phase, step, action, or proof by itself.
            if (
                visible_tail_assertion_code == "H7_VISIBLE_TAIL_ASSERTION_MISMATCH"
                and str(normalized_visible_tail_assertion.get("selection", ""))
                == VISIBLE_TAIL_AUTO_FINALIZE_SELECTION
            ):
                _unused_finalization, auto_code = _auto_finalize_observed_visible_tail(
                    core,
                    context,
                    contract,
                    normalized_visible_tail_assertion,
                    project_progress_status=progress_status,
                    user_control=user_control,
                    timeout=timeout,
                )
                return _withheld("open", context, auto_code)
            else:
                return _withheld("open", context, visible_tail_assertion_code)
        public_visible_tail_assertion = _public_visible_tail_assertion(visible_tail_assertion)
        context["visibleTailAssertion"] = public_visible_tail_assertion
        # A v4 tail has made an exact, receipt-bound claim about the task's
        # phase/step/action and project proof.  Validate that claim *after*
        # binding the current observed tail, so sentence/source drift keeps
        # its more specific tail-mismatch error while phase/step/action/proof
        # drift cannot escape as TURN_RUNTIME_OPEN_READY.  Plain/legacy tails
        # remain display-only: they locate the current workline for diagnosis
        # but do not turn an older published receipt into a continuation.
        if (
            normal_continuity
            and str(visible_tail_assertion.get("continuationRole", ""))
            == VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR
            and (
                not isinstance(visible_progress_status, dict)
                or visible_progress_status.get("state") != "current"
                or visible_progress_status.get("continuationEligible") is not True
            )
        ):
            mapping = {
                **(tail_first_mapping or {}),
                "projectProgressState": str(progress_status.get("state", "withheld")),
                "visibleProgressState": str((visible_progress_status or {}).get("state", "withheld")),
                "stageAdvanceAllowed": False,
                "duplicateActionBlocked": True,
            }
            return _withheld_tail_first_mapping(
                context,
                str((visible_progress_status or {}).get("code", "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH")),
                mapping,
            )
        if (
            normal_continuity
            and str(visible_tail_assertion.get("continuationRole", ""))
            == VISIBLE_TAIL_CONTINUATION_ROLE_ANCHOR
            and progress_status.get("current") is not True
        ):
            mapping = {
                **(tail_first_mapping or {}),
                "projectProgressState": str(progress_status.get("state", "withheld")),
                "visibleProgressState": str((visible_progress_status or {}).get("state", "withheld")),
                "stageAdvanceAllowed": False,
                "duplicateActionBlocked": True,
            }
            return _withheld_tail_first_mapping(context, "H7_PROJECT_PROGRESS_WITHHELD", mapping)
        # The current visible tail has already been observed by the Host.  Bind
        # its compact hashes only to this runtime receipt; normal continuation
        # must not create or rewrite a persistent state/readback card.
        visible_progress_observation = _visible_progress_observation(
            context,
            visible_tail_assertion,
        )
        if visible_progress_observation is None:
            return _withheld("open", context, "H7_VISIBLE_PROGRESS_OBSERVATION_INPUT_INVALID")
        context["visibleProgressObservation"] = _public_visible_progress_observation(visible_progress_observation)
    recovery_presentation, recovery_presentation_code = _recovery_presentation(
        visible_tail_assertion,
        normalized_recovery_event,
        parent_return_state_card,
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
    activation, activation_code, refs = _activation(
        core,
        context,
        contract,
        effective_memory_mode,
        action_authorization=str(contract_authorization.get("state", "withheld")),
    )
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
        "visibleTailAssertionHash": str((public_visible_tail_assertion or {}).get("payloadHash", "")),
        "visibleTailHostMessageHash": str((public_visible_tail_assertion or {}).get("hostMessageHash", "")),
        "visibleProgressObservationHash": str((visible_progress_observation or {}).get("payloadHash", "")),
        "parentReturnStateCardHash": str((parent_return_state_card or {}).get("payloadHash", "")),
        "autoVisibleTailFinalizationHash": "",
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
        visible_tail_assertion=public_visible_tail_assertion,
        recovery_presentation=recovery_presentation,
    )
    scope_ref = str(context["scope"].get("scopeRef", ""))
    receipt, reused = _write_receipt(core.memory_base, scope_ref, "open", body)
    telemetry: dict[str, Any] | None = None
    telemetry_reused = True
    if record_telemetry:
        telemetry, telemetry_reused = _record_telemetry(
            core.memory_base,
            scope_ref,
            receipt,
            runtime_duration_ms=round((time.perf_counter() - started_at) * 1000),
        )
    return {
        "ok": True,
        "schema": SCHEMA,
        "mode": MODE,
        "phase": "open",
        "available": True,
        "code": "TURN_RUNTIME_OPEN_READY",
        "context": context,
        "activation": _public_receipt(receipt)["activation"],
        "runtimeReceipt": _public_receipt(receipt),
        "continuityMapping": _public_tail_first_mapping(tail_first_mapping),
        "visibleTailAssertion": public_visible_tail_assertion or {},
        "autoVisibleTailFinalization": {},
        "sessionRebind": session_rebind or {},
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


def checkpoint_turn(
    core: BrainCore,
    *,
    memory_mode: str = "auto",
    progress_checkpoint: dict[str, Any] | None = None,
    project_progress_proof: dict[str, Any] | None = None,
    visible_progress_assertion: Any = None,
    transition_id: str = "",
    timeout: float = 8.0,
    turn_intent: str = "continuity",
    execution_assist_request: Any = None,
    capability_route_receipt: Any = None,
) -> dict[str, Any]:
    """Persist one latest-assistant-progress checkpoint through H7 authority.

    A compaction summary is historical context, not an execution source.  This
    operation records the current assistant's bounded state atomically before a
    material progress update so the next governed turn can recover it exactly.
    """

    requested_intent = resolve_turn_intent(turn_intent, memory_mode=memory_mode)
    checkpoint_intent_code = _progress_checkpoint_intent_guard(progress_checkpoint, requested_intent)
    if checkpoint_intent_code:
        return _withheld("checkpoint", {}, checkpoint_intent_code)

    normalized_checkpoint_tail: dict[str, Any] | None = None
    if visible_progress_assertion is not None:
        normalized_checkpoint_tail, visible_tail_assertion_code = _normalize_visible_tail_assertion(
            visible_progress_assertion
        )
        if normalized_checkpoint_tail is None:
            return _withheld("checkpoint", {"turnIntent": public_turn_intent(requested_intent)}, visible_tail_assertion_code)
    terminal_finalization_checkpoint = (
        isinstance(progress_checkpoint, dict)
        and str(progress_checkpoint.get("source", "")) == "assistant_visible_reply"
        and str(progress_checkpoint.get("current_phase", "")).strip().casefold()
        in {"complete", "completed", "done"}
    )
    opened = open_turn(
        core,
        memory_mode=memory_mode,
        record_telemetry=False,
        turn_intent=turn_intent,
        execution_assist_request=execution_assist_request,
        capability_route_receipt=capability_route_receipt,
        execution_apply_phase="execution",
        require_visible_tail_assertion=False,
        allow_terminal_finalization=terminal_finalization_checkpoint,
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
        if (
            (open_code != "H7_PROJECT_PROGRESS_WITHHELD" and not repairable_visible_anchor)
            or progress_checkpoint is None
            or (open_code == "H7_PROJECT_PROGRESS_WITHHELD" and project_progress_proof is None)
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
        contract, contract_code = _contract_binding(core, context)
        if contract is None:
            return _withheld("checkpoint", context, contract_code)
        activation, _, _ = _activation(core, context, contract, str(intent.get("memoryMode", memory_mode)))
        capabilities = activation.get("capabilities") if isinstance(activation.get("capabilities"), dict) else {}
        if (
            activation.get("activationState") != "full_brain_active"
            or capabilities.get("coreReady") is not True
            or str((context.get("coreRules") or {}).get("status", "")) != "current"
        ):
            return _withheld("checkpoint", context, "H7_PROGRESS_CHECKPOINT_RECONCILIATION_ACTIVATION_WITHHELD")
        checkpoint_reconcile = True
        checkpoint_reconcile_code = (
            "H7_PROJECT_PROGRESS_REFRESH_READY"
            if open_code == "H7_PROJECT_PROGRESS_WITHHELD"
            else "H7_VISIBLE_PROGRESS_RECEIPT_RECONCILED_READY"
        )
    context = opened["context"]
    checkpoint_tail_assertion: dict[str, Any] | None = None
    if normalized_checkpoint_tail is not None:
        # Checkpoint reconciliation is a drift-repair path.  It must preserve
        # the historical diagnostic selector until the checkpoint verifier
        # compares its exact observed sentence with the proposed progress;
        # only normal open() canonicalizes legacy strict-v4 selection to the
        # current-tail selector.
        checkpoint_tail_input = normalized_checkpoint_tail
        if str(checkpoint_tail_input.get("selection", "")) == VISIBLE_TAIL_CURRENT_VISIBLE_SELECTION:
            checkpoint_tail_input = {
                **checkpoint_tail_input,
                "selection": VISIBLE_TAIL_CHECKPOINT_SELECTION,
            }
            checkpoint_tail_input["payloadHash"] = canonical_hash(
                {key: value for key, value in checkpoint_tail_input.items() if key != "payloadHash"}
            )
        checkpoint_tail_assertion, visible_tail_assertion_code = _checkpoint_visible_tail_assertion_status(
            core,
            context,
            checkpoint_tail_input,
            progress_checkpoint,
            allow_legacy_correction=str(requested_intent.get("kind", "")) in {
                "user_correction",
                "super_brain_issue_continuity",
            },
        )
        if checkpoint_tail_assertion is None:
            return _withheld("checkpoint", context, visible_tail_assertion_code)
    scope = context["scope"]
    task = context["task"]
    checkpoint = record_progress_checkpoint(
        core.package_root,
        core.memory_base,
        task_id=str(task.get("taskId", "")),
        workspace_key=str(scope.get("workspaceKey", "")),
        session_key=str(scope.get("ownerSessionKey", "")),
        progress_checkpoint=progress_checkpoint,
        project_progress_proof=project_progress_proof,
        project_root=core._context_project_root(),
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
        return failed
    refreshed = open_turn(
        core,
        memory_mode=memory_mode,
        record_telemetry=True,
        turn_intent=turn_intent,
        execution_assist_request=execution_assist_request,
        capability_route_receipt=capability_route_receipt,
        execution_apply_phase="execution",
        require_visible_tail_assertion=False,
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
                "visibleTailAssertion": _public_visible_tail_assertion(checkpoint_tail_assertion) if checkpoint_tail_assertion else {},
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
        "visibleTailAssertion": _public_visible_tail_assertion(checkpoint_tail_assertion) if checkpoint_tail_assertion else {},
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
    visible_progress_assertion: Any = None,
) -> dict[str, Any]:
    """Close a governed turn and execute a safe parent-resume transition."""

    started_at = time.perf_counter()
    close_intent = resolve_turn_intent(turn_intent, memory_mode=memory_mode)
    checkpoint_intent_code = _progress_checkpoint_intent_guard(progress_checkpoint, close_intent)
    if checkpoint_intent_code:
        return _withheld("close", {}, checkpoint_intent_code)

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
        turn_intent=turn_intent,
        execution_assist_request=execution_assist_request,
        capability_route_receipt=capability_route_receipt,
        visible_progress_assertion=visible_progress_assertion,
        execution_apply_phase="verification",
    )
    entry_visible_tail_assertion = (
        opened.get("visibleTailAssertion")
        if isinstance(opened.get("visibleTailAssertion"), dict)
        else {}
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
        checkpoint = record_progress_checkpoint(
            core.package_root,
            core.memory_base,
            task_id=str(initial_task.get("taskId", "")),
            workspace_key=str(initial_scope.get("workspaceKey", "")),
            session_key=str(initial_scope.get("ownerSessionKey", "")),
            progress_checkpoint=progress_checkpoint,
            project_progress_proof=project_progress_proof,
            project_root=core._context_project_root(),
            transition_id=checkpoint_transition_id,
            timeout=timeout,
        )
        if checkpoint.get("ok") is not True:
            return _withheld(
                "close",
                initial_context,
                str(checkpoint.get("contractCode") or checkpoint.get("code") or "H7_PROGRESS_CHECKPOINT_FAILED"),
            )
        opened = open_turn(
            core,
            memory_mode=memory_mode,
            record_telemetry=False,
            turn_intent=turn_intent,
            execution_assist_request=execution_assist_request,
            capability_route_receipt=capability_route_receipt,
            execution_apply_phase="verification",
            require_visible_tail_assertion=False,
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
        timeout=timeout,
    )
    post_open = open_turn(
        core,
        memory_mode=memory_mode,
        record_telemetry=False,
        turn_intent=turn_intent,
        execution_assist_request=execution_assist_request,
        capability_route_receipt=capability_route_receipt,
        execution_apply_phase="verification",
        require_visible_tail_assertion=False,
    )
    post_context = post_open.get("context") if isinstance(post_open.get("context"), dict) else context
    post_contract, contract_code = _contract_binding(core, post_context)
    if post_contract is None:
        return _withheld("close", post_context, contract_code)
    post_progress_status = core._project_progress_status(post_contract)
    if close_intent.get("projectEvidenceRequired") is True and post_progress_status.get("current") is not True:
        return _withheld("close", post_context, "H7_PROJECT_PROGRESS_WITHHELD")
    post_project_knowledge, post_project_knowledge_code = _resolve_project_knowledge_for_turn(
        core,
        post_contract,
        post_progress_status,
        execution_assist,
    )
    if post_project_knowledge is None:
        return _withheld("close", post_context, post_project_knowledge_code or "H7_PROJECT_KNOWLEDGE_WITHHELD")
    post_context["projectKnowledge"] = public_project_knowledge(post_project_knowledge)
    post_activation, activation_code, refs = _activation(core, post_context, post_contract, memory_mode)
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
        "visibleTailAssertionHash": str(entry_visible_tail_assertion.get("payloadHash", "")),
        "visibleTailHostMessageHash": str(entry_visible_tail_assertion.get("hostMessageHash", "")),
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
        visible_tail_assertion=entry_visible_tail_assertion,
    )
    scope_ref = str(post_context["scope"].get("scopeRef", ""))
    receipt, reused = _write_receipt(core.memory_base, scope_ref, "close", body)
    telemetry, telemetry_reused = _record_telemetry(
        core.memory_base,
        scope_ref,
        receipt,
        runtime_duration_ms=round((time.perf_counter() - started_at) * 1000),
    )
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
    retired_transport_guard = core.status().get("retiredTransportGuard", {})
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

    # External continuation state cannot prove that the current visible
    # assistant tail was read.  Reject the retired field explicitly instead of
    # silently dropping it or letting an old contract masquerade as current
    # visible progress.
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
            visible_progress_assertion=kwargs.get("visible_progress_assertion"),
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
            visible_progress_assertion=kwargs.get("visible_progress_assertion"),
        )
    if phase == "checkpoint":
        return checkpoint_turn(
            core,
            memory_mode=str(kwargs.get("memory_mode", "auto")),
            progress_checkpoint=kwargs.get("progress_checkpoint") if isinstance(kwargs.get("progress_checkpoint"), dict) else None,
            project_progress_proof=kwargs.get("project_progress_proof") if isinstance(kwargs.get("project_progress_proof"), dict) else None,
            visible_progress_assertion=kwargs.get("visible_progress_assertion"),
            transition_id=str(kwargs.get("transition_id", "")),
            timeout=float(kwargs.get("timeout", 8.0)),
            turn_intent=str(kwargs.get("turn_intent", kwargs.get("intent", "continuity"))),
            execution_assist_request=kwargs.get("execution_assist_request"),
            capability_route_receipt=kwargs.get("capability_route_receipt"),
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
