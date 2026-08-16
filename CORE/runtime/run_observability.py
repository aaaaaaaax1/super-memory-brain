"""Bounded, privacy-safe measurements for H7 turn-runtime telemetry.

This module is deliberately pure: it receives the already-bounded telemetry
events that H7 owns, derives compact measured metrics, and never opens files,
starts work, rebuilds an index, or makes an execution decision.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from typing import Any, Mapping, Sequence


SCHEMA = "super-brain.run-observability.v1"
TELEMETRY_SCHEMA = "super-brain.turn-runtime-telemetry.v1"
MAX_EVENTS = 16
MAX_DURATION_MS = 60_000
DEFAULT_MAX_P95_RUNTIME_MS = 1_200
DEFAULT_MAX_EVENT_RUNTIME_MS = 4_000
HASH_RE = re.compile(r"^[a-f0-9]{64}$")
PHASES = ("open", "checkpoint", "close", "evidence", "other")
TOP_LEVEL_FIELDS = {
    "schema",
    "state",
    "code",
    "scopeRef",
    "eventCount",
    "measuredSampleCount",
    "phaseCounts",
    "runtimeLatency",
    "budget",
    "eventDigest",
    "persistentIndex",
    "backgroundWorkers",
    "nonAuthorizing",
    "rawPromptStored",
    "rawTranscriptStored",
    "payloadHash",
}


def canonical_hash(value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _percentile(values: Sequence[int], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * percentile) - 1))
    return round(float(ordered[index]), 3)


def _normalized_phase(value: Any) -> str:
    phase = str(value or "").strip().lower()
    return phase if phase in PHASES[:-1] else "other"


def _bounded_positive_int(value: Any) -> int | None:
    # Telemetry writes this field as a JSON integer.  Reject strings and
    # fractional values instead of silently coercing a tampered measurement.
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if 0 <= value <= MAX_DURATION_MS else None


def _event_projection(value: Any) -> tuple[dict[str, Any] | None, str]:
    if not isinstance(value, Mapping):
        return None, "H7_RUN_OBSERVABILITY_EVENT_INVALID"
    receipt_hash = str(value.get("receiptHash", "")).strip().lower()
    if not HASH_RE.fullmatch(receipt_hash):
        return None, "H7_RUN_OBSERVABILITY_EVENT_INVALID"
    if value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return None, "H7_RUN_OBSERVABILITY_PRIVACY_INVALID"
    duration_present = "runtimeDurationMs" in value
    duration = _bounded_positive_int(value.get("runtimeDurationMs")) if duration_present else None
    if duration_present and duration is None:
        return None, "H7_RUN_OBSERVABILITY_DURATION_INVALID"
    return {
        "phase": _normalized_phase(value.get("phase")),
        "receiptHash": receipt_hash,
        "runtimeDurationMs": duration,
    }, "H7_RUN_OBSERVABILITY_CURRENT"


def _budget_projection(durations: list[int], event_count: int) -> dict[str, Any]:
    p95 = _percentile(durations, 0.95)
    maximum = round(float(max(durations or [0])), 3)
    event_count_ok = event_count <= MAX_EVENTS
    p95_ok = not durations or p95 <= DEFAULT_MAX_P95_RUNTIME_MS
    max_ok = not durations or maximum <= DEFAULT_MAX_EVENT_RUNTIME_MS
    if not durations:
        state = "not_applicable"
    elif event_count_ok and p95_ok and max_ok:
        state = "within_budget"
    else:
        state = "budget_exceeded"
    return {
        "maxEventCount": MAX_EVENTS,
        "maxP95RuntimeMs": DEFAULT_MAX_P95_RUNTIME_MS,
        "maxEventRuntimeMs": DEFAULT_MAX_EVENT_RUNTIME_MS,
        "eventCountOk": event_count_ok,
        "p95Ok": p95_ok,
        "maxOk": max_ok,
        "state": state,
    }


def _withheld(code: str) -> dict[str, Any]:
    body = {
        "schema": SCHEMA,
        "state": "withheld",
        "code": code,
        "scopeRef": "",
        "eventCount": 0,
        "measuredSampleCount": 0,
        "phaseCounts": {phase: 0 for phase in PHASES},
        "runtimeLatency": {"p50Ms": 0.0, "p95Ms": 0.0, "maxMs": 0.0},
        "budget": {
            "maxEventCount": MAX_EVENTS,
            "maxP95RuntimeMs": DEFAULT_MAX_P95_RUNTIME_MS,
            "maxEventRuntimeMs": DEFAULT_MAX_EVENT_RUNTIME_MS,
            "eventCountOk": False,
            "p95Ok": False,
            "maxOk": False,
            "state": "withheld",
        },
        "eventDigest": "",
        "persistentIndex": False,
        "backgroundWorkers": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def summarize_telemetry(telemetry: Any, *, expected_scope_ref: str = "") -> dict[str, Any]:
    """Return an exact, compact summary from one bounded H7 telemetry record."""

    if not isinstance(telemetry, Mapping) or telemetry.get("schema") != TELEMETRY_SCHEMA:
        return _withheld("H7_RUN_OBSERVABILITY_TELEMETRY_INVALID")
    scope_ref = str(telemetry.get("scopeRef", "")).strip().lower()
    if not HASH_RE.fullmatch(scope_ref) or (expected_scope_ref and scope_ref != expected_scope_ref):
        return _withheld("H7_RUN_OBSERVABILITY_SCOPE_INVALID")
    if telemetry.get("rawPromptStored") is not False or telemetry.get("rawTranscriptStored") is not False:
        return _withheld("H7_RUN_OBSERVABILITY_PRIVACY_INVALID")
    events = telemetry.get("events")
    if not isinstance(events, list) or not events or len(events) > MAX_EVENTS:
        return _withheld("H7_RUN_OBSERVABILITY_EVENT_LIMIT_INVALID")

    projections: list[dict[str, Any]] = []
    for event in events:
        projection, code = _event_projection(event)
        if projection is None:
            return _withheld(code)
        projections.append(projection)

    durations = [int(item["runtimeDurationMs"]) for item in projections if item["runtimeDurationMs"] is not None]
    phase_counts = {phase: 0 for phase in PHASES}
    for item in projections:
        phase_counts[str(item["phase"])] += 1
    budget = _budget_projection(durations, len(projections))
    if budget["state"] == "budget_exceeded":
        state, code = "budget_exceeded", "H7_RUN_BUDGET_EXCEEDED"
    elif budget["state"] == "not_applicable":
        state, code = "not_applicable", "H7_RUN_OBSERVABILITY_NO_MEASURED_SAMPLES"
    else:
        state, code = "current", "H7_RUN_OBSERVABILITY_CURRENT"
    body = {
        "schema": SCHEMA,
        "state": state,
        "code": code,
        "scopeRef": scope_ref,
        "eventCount": len(projections),
        "measuredSampleCount": len(durations),
        "phaseCounts": phase_counts,
        "runtimeLatency": {
            "p50Ms": _percentile(durations, 0.50),
            "p95Ms": _percentile(durations, 0.95),
            "maxMs": round(float(max(durations or [0])), 3),
        },
        "budget": budget,
        "eventDigest": canonical_hash(projections),
        "persistentIndex": False,
        "backgroundWorkers": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def receipt_is_valid(value: Any, *, expected_scope_ref: str = "") -> bool:
    if not isinstance(value, Mapping) or set(value) != TOP_LEVEL_FIELDS:
        return False
    if str(value.get("schema", "")) != SCHEMA:
        return False
    if value.get("state") not in {"current", "budget_exceeded", "not_applicable", "withheld"}:
        return False
    if not isinstance(value.get("eventCount"), int) or not isinstance(value.get("measuredSampleCount"), int):
        return False
    scope_ref = str(value.get("scopeRef", ""))
    if value.get("state") != "withheld" and (not HASH_RE.fullmatch(scope_ref) or (expected_scope_ref and scope_ref != expected_scope_ref)):
        return False
    if value.get("persistentIndex") is not False or value.get("backgroundWorkers") is not False:
        return False
    if value.get("nonAuthorizing") is not True or value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return False
    body = {key: item for key, item in value.items() if key != "payloadHash"}
    return str(value.get("payloadHash", "")) == canonical_hash(body)


__all__ = ["SCHEMA", "MAX_EVENTS", "canonical_hash", "receipt_is_valid", "summarize_telemetry"]
