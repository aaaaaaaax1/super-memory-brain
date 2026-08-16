from __future__ import annotations

"""Regression coverage for H7's pure, bounded run-observability receipt."""

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from run_observability import SCHEMA, receipt_is_valid, summarize_telemetry


SCOPE_REF = "a" * 64
OTHER_SCOPE_REF = "b" * 64


def _event(
    phase: str,
    receipt_seed: str,
    runtime_duration_ms: int | None = None,
    **extra: object,
) -> dict[str, object]:
    event: dict[str, object] = {
        "phase": phase,
        "receiptHash": receipt_seed * 64,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    if runtime_duration_ms is not None:
        event["runtimeDurationMs"] = runtime_duration_ms
    return {**event, **extra}


def _telemetry(*events: dict[str, object], **extra: object) -> dict[str, object]:
    return {
        "schema": "super-brain.turn-runtime-telemetry.v1",
        "scopeRef": SCOPE_REF,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "events": list(events),
        **extra,
    }


def _assert_withheld(value: dict[str, object], code: str) -> None:
    assert value["schema"] == SCHEMA, value
    assert value["state"] == "withheld", value
    assert value["code"] == code, value
    assert receipt_is_valid(value), value


def test_aggregation_uses_only_allowlisted_measured_runtime_durations() -> None:
    telemetry = _telemetry(
        _event("open", "1", 10),
        # Old telemetry has no H7 runtime measurement.  It remains observable
        # as an event but may never affect a latency statistic or budget.
        _event("checkpoint", "2", durationMs=99_999, estimatedDurationMs=99_999),
        _event("close", "3", 30),
        _event("close", "4", 50),
    )
    receipt = summarize_telemetry(telemetry, expected_scope_ref=SCOPE_REF)

    assert receipt["state"] == "current", receipt
    assert receipt["code"] == "H7_RUN_OBSERVABILITY_CURRENT", receipt
    assert receipt["eventCount"] == 4 and receipt["measuredSampleCount"] == 3, receipt
    assert receipt["phaseCounts"] == {"open": 1, "checkpoint": 1, "close": 2, "evidence": 0, "other": 0}
    assert receipt["runtimeLatency"] == {"p50Ms": 30.0, "p95Ms": 50.0, "maxMs": 50.0}
    assert receipt["budget"]["state"] == "within_budget", receipt
    assert receipt["persistentIndex"] is False and receipt["backgroundWorkers"] is False
    assert receipt["nonAuthorizing"] is True
    assert receipt_is_valid(receipt, expected_scope_ref=SCOPE_REF), receipt


def test_legacy_events_without_runtime_measurements_are_not_applicable_not_estimated() -> None:
    receipt = summarize_telemetry(
        _telemetry(
            _event("open", "1", durationMs=1),
            _event("close", "2", estimatedDurationMs=9_999),
        ),
        expected_scope_ref=SCOPE_REF,
    )

    assert receipt["state"] == "not_applicable", receipt
    assert receipt["code"] == "H7_RUN_OBSERVABILITY_NO_MEASURED_SAMPLES", receipt
    assert receipt["eventCount"] == 2 and receipt["measuredSampleCount"] == 0, receipt
    assert receipt["runtimeLatency"] == {"p50Ms": 0.0, "p95Ms": 0.0, "maxMs": 0.0}
    assert receipt["budget"]["state"] == "not_applicable", receipt
    assert receipt_is_valid(receipt, expected_scope_ref=SCOPE_REF), receipt


def test_budget_exceeded_is_reported_from_real_measured_samples() -> None:
    receipt = summarize_telemetry(
        _telemetry(
            _event("open", "1", 1_201),
            _event("checkpoint", "2", 4_001),
        ),
        expected_scope_ref=SCOPE_REF,
    )

    assert receipt["state"] == "budget_exceeded", receipt
    assert receipt["code"] == "H7_RUN_BUDGET_EXCEEDED", receipt
    assert receipt["runtimeLatency"] == {"p50Ms": 1_201.0, "p95Ms": 4_001.0, "maxMs": 4_001.0}
    assert receipt["budget"]["state"] == "budget_exceeded", receipt
    assert receipt["budget"]["p95Ok"] is False and receipt["budget"]["maxOk"] is False, receipt
    assert receipt_is_valid(receipt, expected_scope_ref=SCOPE_REF), receipt


def test_privacy_projection_never_returns_prompt_transcript_or_machine_path() -> None:
    prompt = "private prompt should never enter the observability receipt"
    transcript = "private transcript should never enter the observability receipt"
    path = "C:/private-user/workspace/secret-project.py"
    receipt = summarize_telemetry(
        _telemetry(
            _event(
                "evidence",
                "1",
                21,
                rawPrompt=prompt,
                transcript=transcript,
                sourcePath=path,
                nested={"path": path, "prompt": prompt},
            ),
            hostPath=path,
        ),
        expected_scope_ref=SCOPE_REF,
    )

    serialized = json.dumps(receipt, ensure_ascii=False)
    assert prompt not in serialized and transcript not in serialized and path not in serialized, receipt
    assert '"sourcePath"' not in serialized and '"rawPrompt":' not in serialized and '"transcript":' not in serialized, receipt
    assert receipt["rawPromptStored"] is False and receipt["rawTranscriptStored"] is False, receipt


def test_scope_privacy_and_duration_tampering_fail_closed() -> None:
    current = _telemetry(_event("open", "1", 10))
    _assert_withheld(
        summarize_telemetry(current, expected_scope_ref=OTHER_SCOPE_REF),
        "H7_RUN_OBSERVABILITY_SCOPE_INVALID",
    )
    _assert_withheld(
        summarize_telemetry(
            _telemetry(_event("open", "1", 10, rawPromptStored=True)),
            expected_scope_ref=SCOPE_REF,
        ),
        "H7_RUN_OBSERVABILITY_PRIVACY_INVALID",
    )
    _assert_withheld(
        summarize_telemetry(
            _telemetry(_event("open", "1", 60_001)),
            expected_scope_ref=SCOPE_REF,
        ),
        "H7_RUN_OBSERVABILITY_DURATION_INVALID",
    )
    _assert_withheld(
        summarize_telemetry(
            _telemetry(_event("open", "1", "10")),
            expected_scope_ref=SCOPE_REF,
        ),
        "H7_RUN_OBSERVABILITY_DURATION_INVALID",
    )
    _assert_withheld(
        summarize_telemetry(
            _telemetry(_event("open", "1", 10.5)),
            expected_scope_ref=SCOPE_REF,
        ),
        "H7_RUN_OBSERVABILITY_DURATION_INVALID",
    )
    _assert_withheld(
        summarize_telemetry(
            _telemetry(_event("open", "z", 10)),
            expected_scope_ref=SCOPE_REF,
        ),
        "H7_RUN_OBSERVABILITY_EVENT_INVALID",
    )


def test_receipts_are_deterministic_and_hash_validation_detects_mutation() -> None:
    telemetry = _telemetry(
        _event("OPEN", "1", 5),
        _event("not-a-h7-phase", "2", 11),
        _event("evidence", "3", 17),
    )
    first = summarize_telemetry(telemetry, expected_scope_ref=SCOPE_REF)
    second = summarize_telemetry(telemetry, expected_scope_ref=SCOPE_REF)

    assert first == second, (first, second)
    assert first["phaseCounts"] == {"open": 1, "checkpoint": 0, "close": 0, "evidence": 1, "other": 1}
    assert receipt_is_valid(first, expected_scope_ref=SCOPE_REF), first
    mutated = dict(first)
    mutated["runtimeLatency"] = {"p50Ms": 999.0, "p95Ms": 999.0, "maxMs": 999.0}
    assert receipt_is_valid(mutated, expected_scope_ref=SCOPE_REF) is False


def main() -> None:
    test_aggregation_uses_only_allowlisted_measured_runtime_durations()
    test_legacy_events_without_runtime_measurements_are_not_applicable_not_estimated()
    test_budget_exceeded_is_reported_from_real_measured_samples()
    test_privacy_projection_never_returns_prompt_transcript_or_machine_path()
    test_scope_privacy_and_duration_tampering_fail_closed()
    test_receipts_are_deterministic_and_hash_validation_detects_mutation()
    print("runtime_run_observability_regression: PASS")


if __name__ == "__main__":
    main()
