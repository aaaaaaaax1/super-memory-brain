from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from failure_loop_guard import SCHEMA, canonical_hash, evaluate_failure_loop, receipt_is_valid
from turn_runtime import _record_failure_loop
import turn_runtime as turn_runtime_module


def test_duplicate_failure_is_withheld_and_fused() -> None:
    first = evaluate_failure_loop(
        "failure:contract-resolution",
        evidence_fingerprint="evidence:stale-proof",
        action_fingerprint="action:resolve",
        phase="repair",
    )
    second = evaluate_failure_loop(
        "failure:contract-resolution",
        [first],
        evidence_fingerprint="evidence:stale-proof",
        action_fingerprint="action:resolve",
        phase="repair",
    )

    assert first["state"] == "retryable" and first["retryAllowed"] is True, first
    assert second["state"] == "withheld" and second["retryAllowed"] is False, second
    assert second["fused"] is True, second
    assert second["code"] == "FAILURE_LOOP_GUARD_DUPLICATE_WITHHELD", second
    assert second["occurrenceCount"] == 2, second
    assert receipt_is_valid(first) and receipt_is_valid(second)


def test_changed_evidence_action_or_phase_opens_a_new_budget() -> None:
    first = evaluate_failure_loop("same-failure", evidence_fingerprint="e1", action_fingerprint="a1", phase="p1")
    for kwargs in (
        {"evidence_fingerprint": "e2", "action_fingerprint": "a1", "phase": "p1"},
        {"evidence_fingerprint": "e1", "action_fingerprint": "a2", "phase": "p1"},
        {"evidence_fingerprint": "e1", "action_fingerprint": "a1", "phase": "p2"},
    ):
        retry = evaluate_failure_loop("same-failure", [first], **kwargs)
        assert retry["state"] == "retryable" and retry["retryAllowed"] is True, retry
        assert retry["contextChanged"] is True, retry
        assert retry["code"] == "FAILURE_LOOP_GUARD_CONTEXT_CHANGED_RETRY", retry


def test_user_correction_resets_exactly_one_budget_without_prompt_storage() -> None:
    first = evaluate_failure_loop(
        "failure-x",
        evidence_fingerprint="evidence-secret",
        action_fingerprint="action-secret",
        phase="phase-secret",
    )
    correction = evaluate_failure_loop(
        "failure-x",
        [first],
        evidence_fingerprint="evidence-secret",
        action_fingerprint="action-secret",
        phase="phase-secret",
        user_correction=True,
    )
    repeated_after_correction = evaluate_failure_loop(
        "failure-x",
        [first, correction],
        evidence_fingerprint="evidence-secret",
        action_fingerprint="action-secret",
        phase="phase-secret",
    )

    assert correction["retryAllowed"] is True and correction["resetApplied"] is True, correction
    assert correction["code"] == "FAILURE_LOOP_GUARD_USER_CORRECTION_RESET", correction
    assert repeated_after_correction["retryAllowed"] is False, repeated_after_correction
    serialized = json.dumps(correction, ensure_ascii=False)
    assert all(token not in serialized for token in ("failure-x", "evidence-secret", "action-secret", "phase-secret"))
    assert correction["rawPromptStored"] is False and correction["rawTranscriptStored"] is False


def test_invalid_or_raw_history_fails_closed() -> None:
    invalid = evaluate_failure_loop("failure", [{"prompt": "do not retain this"}])
    assert invalid["schema"] == SCHEMA and invalid["state"] == "withheld", invalid
    assert invalid["code"] == "FAILURE_LOOP_GUARD_PRIVACY_INVALID", invalid
    assert receipt_is_valid(invalid), invalid


def test_nonfinite_guard_receipt_is_invalid_without_raising() -> None:
    receipt = evaluate_failure_loop("failure", evidence_fingerprint="evidence", action_fingerprint="action", phase="phase")
    receipt["code"] = math.nan
    assert receipt_is_valid(receipt) is False


def test_runtime_persists_only_bounded_guard_receipts() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-failure-loop-runtime-") as directory:
        memory_base = Path(directory)
        first = _record_failure_loop(
            memory_base,
            "scope-1",
            failure_fingerprint="H7_TEST_FAILURE",
            evidence_fingerprint="contract-hash",
            action_fingerprint="close-action",
            phase="Stage 1",
        )
        second = _record_failure_loop(
            memory_base,
            "scope-1",
            failure_fingerprint="H7_TEST_FAILURE",
            evidence_fingerprint="contract-hash",
            action_fingerprint="close-action",
            phase="Stage 1",
        )
        path = memory_base / "workspace" / "runtime-state" / "turn-runtime" / "failure-loops" / "scope-1.json"
        serialized = path.read_text(encoding="utf-8")

    assert first["retryAllowed"] is True, first
    assert second["fused"] is True and second["code"] == "FAILURE_LOOP_GUARD_DUPLICATE_WITHHELD", second
    assert "H7_TEST_FAILURE" not in serialized and "contract-hash" not in serialized, serialized


def test_runtime_corrupt_history_fuses_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-failure-loop-corrupt-") as directory:
        memory_base = Path(directory)
        path = memory_base / "workspace" / "runtime-state" / "turn-runtime" / "failure-loops" / "scope-1.json"
        path.parent.mkdir(parents=True)
        path.write_text('{"history":["malformed"]}', encoding="utf-8")

        guard = _record_failure_loop(
            memory_base,
            "scope-1",
            failure_fingerprint="H7_TEST_FAILURE",
            evidence_fingerprint="contract-hash",
            action_fingerprint="close-action",
            phase="Stage 1",
        )

    assert guard["fused"] is True, guard
    assert guard["code"] == "H7_REPAIR_LOOP_GUARD_INVALID", guard
    assert guard["retryAllowed"] is False, guard
    assert receipt_is_valid(guard), guard


def test_runtime_nonfinite_history_fuses_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-failure-loop-nonfinite-") as directory:
        memory_base = Path(directory)
        path = memory_base / "workspace" / "runtime-state" / "turn-runtime" / "failure-loops" / "scope-1.json"
        path.parent.mkdir(parents=True)
        receipt = evaluate_failure_loop("old", evidence_fingerprint="evidence", action_fingerprint="action", phase="phase")
        receipt["code"] = math.nan
        state = {
            "schema": "super-brain.turn-runtime-failure-loop.v1",
            "scopeRef": "scope-1",
            "revision": 1,
            "history": [receipt],
            "reservations": [],
            "updatedAt": "2026-08-23T00:00:00Z",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
            "payloadHash": "0" * 64,
        }
        path.write_text(json.dumps(state), encoding="utf-8")
        guard = _record_failure_loop(
            memory_base,
            "scope-1",
            failure_fingerprint="H7_TEST_FAILURE",
            evidence_fingerprint="contract-hash",
            action_fingerprint="close-action",
            phase="Stage 1",
        )

    assert guard["fused"] is True, guard
    assert guard["code"] == "H7_REPAIR_LOOP_GUARD_INVALID", guard


def test_runtime_journal_with_raw_extra_field_fuses_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-failure-loop-privacy-") as directory:
        memory_base = Path(directory)
        path = memory_base / "workspace" / "runtime-state" / "turn-runtime" / "failure-loops" / "scope-1.json"
        path.parent.mkdir(parents=True)
        state = {
            "schema": "super-brain.turn-runtime-failure-loop.v1",
            "scopeRef": "scope-1",
            "revision": 1,
            "history": [],
            "reservations": [],
            "updatedAt": "2026-08-23T00:00:00Z",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
            "prompt": "raw text must fail closed",
        }
        state["payloadHash"] = canonical_hash(state)
        path.write_text(json.dumps(state), encoding="utf-8")
        guard = _record_failure_loop(
            memory_base,
            "scope-1",
            failure_fingerprint="H7_TEST_FAILURE",
            evidence_fingerprint="contract-hash",
            action_fingerprint="close-action",
            phase="Stage 1",
        )

    assert guard["fused"] is True, guard
    assert guard["code"] == "H7_REPAIR_LOOP_GUARD_INVALID", guard


def test_runtime_journal_with_invalid_timestamp_fuses_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-failure-loop-timestamp-") as directory:
        memory_base = Path(directory)
        path = memory_base / "workspace" / "runtime-state" / "turn-runtime" / "failure-loops" / "scope-1.json"
        path.parent.mkdir(parents=True)
        state = {
            "schema": "super-brain.turn-runtime-failure-loop.v1",
            "scopeRef": "scope-1",
            "revision": 1,
            "history": [],
            "reservations": [],
            "updatedAt": "raw timestamp text",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        state["payloadHash"] = canonical_hash(state)
        path.write_text(json.dumps(state), encoding="utf-8")
        guard = _record_failure_loop(
            memory_base,
            "scope-1",
            failure_fingerprint="H7_TEST_FAILURE",
            evidence_fingerprint="contract-hash",
            action_fingerprint="close-action",
            phase="Stage 1",
        )

    assert guard["fused"] is True, guard
    assert guard["code"] == "H7_REPAIR_LOOP_GUARD_INVALID", guard


def test_runtime_scope_lock_leaves_a_nonsecret_persistent_marker() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-lock-marker-") as directory:
        memory_base = Path(directory)
        lock_path = turn_runtime_module._scope_runtime_lock_path(memory_base, "scope-marker")
        with turn_runtime_module._runtime_scope_lock(lock_path) as acquired:
            assert acquired is True
        assert lock_path.exists()
        assert lock_path.read_bytes() == b"0"


def _probe_runtime_scope_lock(lock_path: Path) -> bool:
    runtime_path = ROOT / "runtime"
    probe = "\n".join(
        (
            "import sys",
            "from pathlib import Path",
            f"sys.path.insert(0, {str(runtime_path)!r})",
            "import turn_runtime as runtime",
            "runtime.FAILURE_LOOP_LOCK_TIMEOUT_SECONDS = 0.05",
            "with runtime._runtime_scope_lock(Path(sys.argv[1])) as acquired:",
            "    print('1' if acquired else '0')",
        )
    )
    completed = subprocess.run(
        [sys.executable, "-c", probe, str(lock_path)],
        capture_output=True,
        check=False,
        text=True,
        timeout=10,
    )
    assert completed.returncode == 0, completed.stderr
    return completed.stdout.strip() == "1"


def test_runtime_scope_lock_is_handle_owned_across_processes() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scope-lock-advisory-") as directory:
        memory_base = Path(directory)
        lock_path = turn_runtime_module._scope_runtime_lock_path(memory_base, "scope-advisory")
        with turn_runtime_module._runtime_scope_lock(lock_path) as acquired:
            assert acquired is True
            assert _probe_runtime_scope_lock(lock_path) is False
        assert lock_path.exists()
        assert lock_path.read_bytes() == b"0"
        assert _probe_runtime_scope_lock(lock_path) is True


def test_future_dated_reservation_is_not_live() -> None:
    future = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat().replace("+00:00", "Z")
    assert turn_runtime_module._failure_loop_reservation_is_live({"createdAt": future}) is False


def test_reservation_ttl_tracks_bounded_timeout_without_overflow() -> None:
    base = turn_runtime_module.FAILURE_LOOP_RESERVATION_TTL_SECONDS
    assert turn_runtime_module._reservation_ttl_for_timeout(None) == base
    assert turn_runtime_module._reservation_ttl_for_timeout(float("nan")) == base
    assert turn_runtime_module._reservation_ttl_for_timeout(1.0) == base
    assert turn_runtime_module._reservation_ttl_for_timeout(100.0) > base
    assert turn_runtime_module._reservation_ttl_for_timeout(10**300) > base
    saturated = turn_runtime_module._utc_after(10**300)
    assert saturated.startswith("9999-12-31T"), saturated


def test_release_failure_exposes_scoped_reconciliation_projection() -> None:
    result = turn_runtime_module._reservation_release_failed_result(
        "close",
        {"scope": {"scopeRef": "a" * 64}},
        operation="close_dispatch",
        reservation_id="flr-" + "b" * 32,
        dispatch={
            "code": "H7_CLOSE_DISPATCH_WRITTEN",
            "stateMutated": True,
            "transition": {"transitionId": "close-transition"},
        },
    )
    assert result["operationState"] == "partially_committed", result
    assert result["retrySafe"] is False, result
    assert result["reconciliationRequired"] is True, result
    assert result["reservation"]["scopeRef"] == "a" * 64, result
    assert result["reservation"]["reservationId"] == "flr-" + "b" * 32, result
    assert result["reconciliation"]["transitionId"] == "close-transition", result
    assert result["reconciliation"]["stateMutated"] is True, result


def main() -> int:
    test_duplicate_failure_is_withheld_and_fused()
    test_changed_evidence_action_or_phase_opens_a_new_budget()
    test_user_correction_resets_exactly_one_budget_without_prompt_storage()
    test_invalid_or_raw_history_fails_closed()
    test_nonfinite_guard_receipt_is_invalid_without_raising()
    test_runtime_persists_only_bounded_guard_receipts()
    test_runtime_corrupt_history_fuses_closed()
    test_runtime_nonfinite_history_fuses_closed()
    test_runtime_journal_with_raw_extra_field_fuses_closed()
    test_runtime_journal_with_invalid_timestamp_fuses_closed()
    test_runtime_scope_lock_leaves_a_nonsecret_persistent_marker()
    test_runtime_scope_lock_is_handle_owned_across_processes()
    test_future_dated_reservation_is_not_live()
    test_reservation_ttl_tracks_bounded_timeout_without_overflow()
    test_release_failure_exposes_scoped_reconciliation_projection()
    print("FAILURE_LOOP_GUARD_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
