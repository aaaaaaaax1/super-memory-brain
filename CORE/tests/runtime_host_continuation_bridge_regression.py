from __future__ import annotations

import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from host_continuation_bridge import (
    HOST_VISIBLE_TAIL_READ_TIMEOUT_SECONDS,
    PURPOSE_STRICT_RECOVERY,
    acquire_current_visible_assertion,
    observe_current_thread,
)


THREAD_ID = "019fe035-b8ac-73e2-947c-6f6fd16cdc65"
RECEIPT_HASH = "b" * 64
PROGRESS = "R6 v4 bridge checks only the current thread tail."


def payload(text: str) -> dict[str, object]:
    return {
        "thread": {"id": THREAD_ID},
        "page": {"order": "newest_first"},
        "turns": [{"id": "turn-current", "items": [{"type": "agentMessage", "id": "item-current", "phase": "commentary", "text": text}]}],
    }


def envelope(sentence: str = PROGRESS) -> str:
    return f"G1\n[H7-PROGRESS-V4 receipt_hash={RECEIPT_HASH}]\n{sentence}"


def test_fast_current_tail_read_uses_one_bounded_call() -> None:
    calls: list[dict[str, object]] = []

    def reader(**kwargs: object) -> dict[str, object]:
        calls.append(kwargs)
        return payload(envelope())

    result = observe_current_thread(reader)
    assert result["ok"] is True, result
    assert result["readAttempts"] == 1, result
    assert result["observation"]["schema"] == "super-brain.visible-tail-observation.v4", result
    assert result["observation"]["h7_receipt_hash"] == RECEIPT_HASH, result
    assert calls == [{"turnLimit": 1, "includeOutputs": False, "maxOutputCharsPerItem": 480}], calls


def test_missing_current_assistant_tail_retries_once_with_turn_limit_two() -> None:
    calls: list[int] = []

    def reader(**kwargs: object) -> dict[str, object]:
        calls.append(int(kwargs["turnLimit"]))
        return {"thread": {"id": THREAD_ID}, "page": {"order": "newest_first"}, "turns": [{"id": "turn-current", "items": []}]} if len(calls) == 1 else payload(envelope())

    result = observe_current_thread(reader)
    assert result["ok"] is True, result
    assert result["readAttempts"] == 2, result
    assert calls == [1, 2], calls


def test_timeout_never_falls_back_or_scans_history() -> None:
    calls: list[int] = []

    def reader(**kwargs: object) -> dict[str, object]:
        calls.append(int(kwargs["turnLimit"]))
        time.sleep(0.08)
        return payload(envelope())

    result = observe_current_thread(reader, timeout_seconds=0.01)
    assert result["ok"] is False, result
    assert result["code"] == "HOST_VISIBLE_TAIL_READ_DEADLINE_EXCEEDED", result
    assert result["transportMayStillRun"] is True, result
    assert calls == [1], calls
    # The reader itself cannot be force-cancelled by this package.  Wait for
    # its daemon call to settle so later independent tests do not observe the
    # one-inflight guard as a false failure.
    time.sleep(0.09)


def test_extra_visible_prose_keeps_the_v4_prefix_durable() -> None:
    def reader(**_kwargs: object) -> dict[str, object]:
        return payload(envelope() + "\nThis must not become a fourth durable line.")

    result = observe_current_thread(reader)
    assert result["ok"] is True, result
    assert result["observation"]["publication_kind"] == "h7_durable_progress", result


def test_default_normal_path_returns_newer_unpublished_assistant_without_retry() -> None:
    calls: list[int] = []

    def reader(**kwargs: object) -> dict[str, object]:
        calls.append(int(kwargs["turnLimit"]))
        return {
            "thread": {"id": THREAD_ID},
            "page": {"order": "newest_first"},
            "turns": [{"id": "turn-current", "items": [
                {"type": "agentMessage", "id": "old", "phase": "commentary", "text": envelope()},
                {"type": "agentMessage", "id": "new", "phase": "commentary", "text": "Current package verification is still blocked."},
            ]}],
        }

    result = observe_current_thread(reader)
    assert result["ok"] is True, result
    assert result["purpose"] == "normal_same_workline", result
    assert result["observation"]["selection"] == "current_visible_assistant", result
    assert result["observation"]["host_message_id"] == "new", result
    assert result["observation"]["publication_kind"] == "unclassified_assistant_reply", result
    assert calls == [1], calls


def test_visible_context_fast_path_never_reads_the_thread() -> None:
    calls: list[dict[str, object]] = []

    def reader(**kwargs: object) -> dict[str, object]:
        calls.append(kwargs)
        return payload(envelope())

    result = acquire_current_visible_assertion(
        visible_context={
            "host_thread_id": THREAD_ID,
            "turn_id": "turn-visible-context",
            "message_id": "item-visible-context",
            "phase": "commentary",
            "text": "The current assistant reply was already exposed by the Host.",
        },
        reader=reader,
    )
    assert result["ok"] is True, result
    assert result["source"] == "codex_visible_context", result
    assert result["readAttempts"] == 0, result
    assert result["observation"]["selection"] == "current_visible_assistant", result
    assert calls == [], calls


def test_recovery_uses_the_same_current_plain_candidate() -> None:
    calls: list[int] = []

    def reader(**kwargs: object) -> dict[str, object]:
        calls.append(int(kwargs["turnLimit"]))
        return payload("A newer ordinary assistant reply must remain the recovery start point.")

    result = observe_current_thread(reader, purpose=PURPOSE_STRICT_RECOVERY)
    assert result["ok"] is True, result
    assert result["observation"]["selection"] == "current_visible_assistant", result
    assert result["observation"]["publication_kind"] == "unclassified_assistant_reply", result
    assert calls == [1], calls


def main() -> int:
    assert HOST_VISIBLE_TAIL_READ_TIMEOUT_SECONDS == 5.0
    test_fast_current_tail_read_uses_one_bounded_call()
    test_missing_current_assistant_tail_retries_once_with_turn_limit_two()
    test_timeout_never_falls_back_or_scans_history()
    test_extra_visible_prose_keeps_the_v4_prefix_durable()
    test_default_normal_path_returns_newer_unpublished_assistant_without_retry()
    test_visible_context_fast_path_never_reads_the_thread()
    test_recovery_uses_the_same_current_plain_candidate()
    print("runtime host-continuation-bridge regression: passed (7/7)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
