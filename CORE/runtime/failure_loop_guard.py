"""Pure, stateless guard for repeated repair/failure attempts.

The caller supplies opaque identifiers for one observed failure and a bounded
sequence of prior metadata records.  The guard owns no persistence and never
accepts prompt or transcript text.  A retry budget is one occurrence per
failure/context tuple; changing evidence, action, or phase creates a new
tuple.  A structured user correction explicitly starts one fresh budget.
"""

from __future__ import annotations

import hashlib
import json
import re
from collections.abc import Mapping, Sequence
from typing import Any


SCHEMA = "super-brain.failure-loop-guard.v1"
RETRY_BUDGET = 1
MAX_TOKEN_LENGTH = 256
MAX_HISTORY = 256

_PRIVACY_KEYS = frozenset(
    {
        "prompt",
        "rawprompt",
        "raw_prompt",
        "transcript",
        "rawtranscript",
        "raw_transcript",
        "sourcepath",
        "source_path",
    }
)
_HEX_DIGEST = re.compile(r"^[a-f0-9]{64}$")
_CODE = re.compile(r"^[A-Z][A-Z0-9_]{2,127}$")


def canonical_hash(value: Any) -> str:
    """Hash deterministic JSON metadata without retaining caller text."""

    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    ).hexdigest()


def _withheld(code: str) -> dict[str, Any]:
    body: dict[str, Any] = {
        "schema": SCHEMA,
        "state": "withheld",
        "decision": "withhold",
        "code": code,
        "retryAllowed": False,
        "fused": False,
        "contextChanged": False,
        "resetApplied": False,
        "occurrenceCount": 0,
        "retryBudget": RETRY_BUDGET,
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


def _token(value: Any, *, required: bool) -> str | None:
    if value is None and not required:
        return ""
    if not isinstance(value, str):
        return None
    normalized = " ".join(value.strip().split())
    if not normalized and required:
        return None
    if len(normalized) > MAX_TOKEN_LENGTH or "\x00" in normalized:
        return None
    return normalized


def _digest(kind: str, value: str) -> str:
    return hashlib.sha256(f"failure-loop:{kind}:{value}".encode("utf-8")).hexdigest()


def _privacy_key_present(value: Any) -> bool:
    """Reject raw-text-bearing metadata before any value can be projected."""

    if isinstance(value, Mapping):
        for key, item in value.items():
            if str(key).replace("-", "_").casefold() in _PRIVACY_KEYS:
                return True
            if _privacy_key_present(item):
                return True
    elif isinstance(value, (list, tuple)):
        return any(_privacy_key_present(item) for item in value)
    return False


def _record_tokens(value: Any) -> tuple[tuple[str, str, str, str], bool] | None:
    if not isinstance(value, Mapping) or _privacy_key_present(value):
        return None

    # Accept the JSON receipt spelling and the Python-call spelling.  The
    # digest spelling lets callers feed a prior guard receipt back directly.
    def pick(*names: str) -> Any:
        for name in names:
            if name in value:
                return value[name]
        return None

    failure = pick("failureFingerprint", "failure_fingerprint", "fingerprint")
    evidence = pick("evidenceFingerprint", "evidence_fingerprint", "evidence")
    action = pick("actionFingerprint", "action_fingerprint", "action")
    phase = pick("phase")
    digest_fields = (
        pick("failureFingerprintDigest", "failure_fingerprint_digest"),
        pick("evidenceFingerprintDigest", "evidence_fingerprint_digest"),
        pick("actionFingerprintDigest", "action_fingerprint_digest"),
        pick("phaseDigest", "phase_digest"),
    )
    if all(isinstance(item, str) and _HEX_DIGEST.fullmatch(item) for item in digest_fields):
        # Prior receipts contain digests only and therefore remain safe to
        # replay without exposing the original opaque identifiers.
        correction = pick("userCorrection", "user_correction")
        if correction is not None and not isinstance(correction, bool):
            return None
        return tuple(digest_fields), bool(correction)  # type: ignore[return-value]

    normalized = (
        _token(failure, required=True),
        _token(evidence, required=False),
        _token(action, required=False),
        _token(phase, required=False),
    )
    if any(item is None for item in normalized):
        return None
    correction = pick("userCorrection", "user_correction")
    if correction is not None and not isinstance(correction, bool):
        return None
    return (
        (
            _digest("failure", normalized[0] or ""),
            _digest("evidence", normalized[1] or ""),
            _digest("action", normalized[2] or ""),
            _digest("phase", normalized[3] or ""),
        ),
        bool(correction),
    )


def _context_digest(digests: tuple[str, str, str, str]) -> str:
    return canonical_hash(
        {
            "failure": digests[0],
            "evidence": digests[1],
            "action": digests[2],
            "phase": digests[3],
        }
    )


def evaluate_failure_loop(
    failure_fingerprint: Any,
    history: Sequence[Mapping[str, Any]] | None = None,
    *,
    evidence_fingerprint: Any = "",
    action_fingerprint: Any = "",
    phase: Any = "",
    user_correction: Any = False,
) -> dict[str, Any]:
    """Decide whether one bounded repair retry is still eligible.

    ``history`` is caller-owned metadata and is not mutated.  A matching
    failure/context tuple consumes the single retry budget.  A second match is
    withheld and marked ``fused``.  A changed evidence, action, or phase does
    not match the old tuple.  ``user_correction=True`` starts one fresh budget
    for the current tuple, without inspecting any free-form instruction.
    """

    if _privacy_key_present(failure_fingerprint) or _privacy_key_present(history):
        return _withheld("FAILURE_LOOP_GUARD_PRIVACY_INVALID")
    failure = _token(failure_fingerprint, required=True)
    evidence = _token(evidence_fingerprint, required=False)
    action = _token(action_fingerprint, required=False)
    current_phase = _token(phase, required=False)
    if any(item is None for item in (failure, evidence, action, current_phase)):
        return _withheld("FAILURE_LOOP_GUARD_INPUT_INVALID")
    if not isinstance(user_correction, bool):
        return _withheld("FAILURE_LOOP_GUARD_INPUT_INVALID")
    if history is None:
        prior_items: list[Mapping[str, Any]] = []
    elif isinstance(history, Sequence) and not isinstance(history, (str, bytes, bytearray)) and len(history) <= MAX_HISTORY:
        prior_items = list(history)
    else:
        return _withheld("FAILURE_LOOP_GUARD_HISTORY_INVALID")

    current_digests = (
        _digest("failure", failure or ""),
        _digest("evidence", evidence or ""),
        _digest("action", action or ""),
        _digest("phase", current_phase or ""),
    )
    current_context = current_digests[1:]
    matching: list[tuple[tuple[str, str, str, str], bool]] = []
    for item in prior_items:
        parsed = _record_tokens(item)
        if parsed is None:
            return _withheld("FAILURE_LOOP_GUARD_HISTORY_INVALID")
        if parsed[0] == current_digests:
            matching.append(parsed)

    prior_same_context = len(matching)
    parsed_history = [
        _record_tokens(record)
        for record in prior_items
    ]
    # The first pass above has already rejected malformed records; retain the
    # defensive check because this helper is intentionally pure and reusable.
    if any(item is None for item in parsed_history):
        return _withheld("FAILURE_LOOP_GUARD_HISTORY_INVALID")
    context_changed = any(
        item[0][0] == current_digests[0] and item[0][1:] != current_context
        for item in parsed_history
        if item is not None
    )
    # An explicit correction is a single structured reset.  A repeated
    # correction receipt for the same tuple must not keep reopening the budget.
    prior_corrections = sum(1 for item in matching if item[1])
    reset_applied = user_correction and prior_corrections == 0
    occurrence_count = 1 if reset_applied else prior_same_context + 1
    retry_allowed = occurrence_count <= RETRY_BUDGET
    if retry_allowed:
        if reset_applied:
            code = "FAILURE_LOOP_GUARD_USER_CORRECTION_RESET"
        elif context_changed:
            code = "FAILURE_LOOP_GUARD_CONTEXT_CHANGED_RETRY"
        else:
            code = "FAILURE_LOOP_GUARD_RETRY"
        state, decision, fused = "retryable", "retry", False
    else:
        code = "FAILURE_LOOP_GUARD_DUPLICATE_WITHHELD"
        state, decision, fused = "withheld", "withhold", True

    body: dict[str, Any] = {
        "schema": SCHEMA,
        "state": state,
        "decision": decision,
        "code": code,
        "retryAllowed": retry_allowed,
        "fused": fused,
        "contextChanged": context_changed,
        "resetApplied": reset_applied,
        "occurrenceCount": occurrence_count,
        "retryBudget": RETRY_BUDGET,
        "retryBudgetRemaining": max(0, RETRY_BUDGET - occurrence_count),
        "failureFingerprintDigest": current_digests[0],
        "evidenceFingerprintDigest": current_digests[1],
        "actionFingerprintDigest": current_digests[2],
        "phaseDigest": current_digests[3],
        "contextDigest": _context_digest(current_digests),
        "userCorrection": bool(reset_applied),
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}


# Short aliases make the policy easy to discover without duplicating logic.
guard_failure_retry = evaluate_failure_loop
decide_failure_retry = evaluate_failure_loop


def receipt_is_valid(value: Any) -> bool:
    """Validate an unmodified guard receipt without reading or writing state."""

    if not isinstance(value, Mapping):
        return False
    required = {
        "schema",
        "state",
        "decision",
        "code",
        "retryAllowed",
        "fused",
        "contextChanged",
        "resetApplied",
        "occurrenceCount",
        "retryBudget",
        "retryBudgetRemaining",
        "failureFingerprintDigest",
        "evidenceFingerprintDigest",
        "actionFingerprintDigest",
        "phaseDigest",
        "contextDigest",
        "userCorrection",
        "nonAuthorizing",
        "rawPromptStored",
        "rawTranscriptStored",
        "payloadHash",
    }
    legacy_required = required - {"userCorrection"}
    if set(value) not in (required, legacy_required) or value.get("schema") != SCHEMA:
        return False
    if value.get("state") not in {"retryable", "withheld"}:
        return False
    if value.get("decision") not in {"retry", "withhold"}:
        return False
    if not isinstance(value.get("code"), str) or _CODE.fullmatch(str(value.get("code"))) is None:
        return False
    if value.get("retryBudget") != RETRY_BUDGET or value.get("nonAuthorizing") is not True:
        return False
    if value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return False
    digest_names = (
        "failureFingerprintDigest",
        "evidenceFingerprintDigest",
        "actionFingerprintDigest",
        "phaseDigest",
        "contextDigest",
    )
    if not all(
        isinstance(value.get(field), str)
        and (value.get(field) == "" or _HEX_DIGEST.fullmatch(str(value.get(field))) is not None)
        for field in digest_names
    ):
        return False
    if value.get("state") == "retryable" and not all(len(str(value.get(field))) == 64 for field in digest_names):
        return False
    if not isinstance(value.get("payloadHash"), str) or _HEX_DIGEST.fullmatch(str(value.get("payloadHash"))) is None:
        return False
    if not isinstance(value.get("retryAllowed"), bool) or not isinstance(value.get("fused"), bool):
        return False
    if not isinstance(value.get("contextChanged"), bool) or not isinstance(value.get("resetApplied"), bool):
        return False
    if not isinstance(value.get("occurrenceCount"), int) or isinstance(value.get("occurrenceCount"), bool):
        return False
    if not isinstance(value.get("retryBudgetRemaining"), int) or isinstance(value.get("retryBudgetRemaining"), bool):
        return False
    if value.get("occurrenceCount") < 0:
        return False
    expected_remaining = (
        0
        if value.get("occurrenceCount") == 0
        else max(0, RETRY_BUDGET - value.get("occurrenceCount"))
    )
    if value.get("retryBudgetRemaining") != expected_remaining:
        return False
    if value.get("state") == "retryable":
        if (
            value.get("decision") != "retry"
            or value.get("retryAllowed") is not True
            or value.get("fused") is not False
            or value.get("occurrenceCount") != 1
        ):
            return False
        if value.get("resetApplied") is True and value.get("code") != "FAILURE_LOOP_GUARD_USER_CORRECTION_RESET":
            return False
        if value.get("contextChanged") is True and value.get("code") != "FAILURE_LOOP_GUARD_CONTEXT_CHANGED_RETRY":
            return False
        if (
            value.get("resetApplied") is not True
            and value.get("contextChanged") is not True
            and value.get("code") != "FAILURE_LOOP_GUARD_RETRY"
        ):
            return False
        if value.get("contextDigest") != _context_digest(
            (
                value.get("failureFingerprintDigest", ""),
                value.get("evidenceFingerprintDigest", ""),
                value.get("actionFingerprintDigest", ""),
                value.get("phaseDigest", ""),
            )
        ):
            return False
    elif value.get("decision") != "withhold" or value.get("retryAllowed") is not False:
        return False
    if "userCorrection" in value and not isinstance(value.get("userCorrection"), bool):
        return False
    body = {key: item for key, item in value.items() if key != "payloadHash"}
    try:
        return str(value.get("payloadHash")) == canonical_hash(body)
    except (TypeError, ValueError):
        return False


__all__ = [
    "MAX_HISTORY",
    "MAX_TOKEN_LENGTH",
    "RETRY_BUDGET",
    "SCHEMA",
    "canonical_hash",
    "decide_failure_retry",
    "evaluate_failure_loop",
    "guard_failure_retry",
    "receipt_is_valid",
]
