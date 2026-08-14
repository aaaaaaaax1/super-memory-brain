"""Bounded, ephemeral Host bridge for Super Brain continuation observations.

The Codex host owns ``read_thread``.  H7 never receives a transcript: this
module invokes one Host-supplied reader with a small, fixed read budget,
compacts only the current tail in memory, and forwards the extractor's bounded
observation.  It deliberately has no filesystem writes and no fallback to a
summary, contract, memory, or a previous thread page.
"""

from __future__ import annotations

from queue import Queue
from threading import Lock
from threading import Thread
from time import monotonic
from typing import Any, Callable

from host_visible_tail import (
    SCHEMA,
    SELECTION_CURRENT_VISIBLE_ASSISTANT,
    SELECTION_LATEST_ASSISTANT,
    SELECTION_LATEST_DURABLE_ASSISTANT,
    select_current_visible_assistant,
    select_latest_assistant,
    select_latest_durable_assistant,
    observe_visible_context_message,
)


HOST_VISIBLE_TAIL_READ_TIMEOUT_SECONDS = 5.0
HOST_VISIBLE_TAIL_MAX_OUTPUT_CHARS = 480
HOST_VISIBLE_TAIL_MAX_COMPACT_CHARS = 700
HOST_VISIBLE_TAIL_MAX_NONEMPTY_LINES = 3
PURPOSE_NORMAL_SAME_WORKLINE = "normal_same_workline"
# Strict durable classification of the *current* latest assistant message.
# It is not a recovery selector and never authorizes a backward search for an
# older v4 publication.
PURPOSE_STRICT_RECOVERY = "strict_recovery"
PURPOSE_DRIFT_DIAGNOSIS = "drift_diagnosis"
_RETRYABLE_EMPTY_CODES = {
    "HOST_VISIBLE_TAIL_CURRENT_ASSISTANT_PROGRESS_REQUIRED",
    "HOST_VISIBLE_TAIL_DURABLE_PROGRESS_REQUIRED",
}
_READ_LOCK = Lock()
_READ_INFLIGHT = False


def _fail(code: str, *, transport_may_still_run: bool = False) -> dict[str, Any]:
    result = {
        "ok": False,
        "schema": "super-brain.host-continuation-bridge.v1",
        "code": code,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    if transport_may_still_run:
        result["transportMayStillRun"] = True
    return result


def _compact_agent_text(value: Any) -> str:
    """Retain only a strict v4-sized visible envelope in transient memory."""

    if not isinstance(value, str):
        return ""
    lines = [line.strip() for line in value.splitlines() if line.strip()]
    kept = lines[:HOST_VISIBLE_TAIL_MAX_NONEMPTY_LINES]
    compact = "\n".join(kept)
    if len(compact) > HOST_VISIBLE_TAIL_MAX_COMPACT_CHARS:
        compact = compact[:HOST_VISIBLE_TAIL_MAX_COMPACT_CHARS]
        if "\n" in compact:
            compact = compact.rsplit("\n", 1)[0]
    if len(lines) > HOST_VISIBLE_TAIL_MAX_NONEMPTY_LINES or len("\n".join(kept)) > HOST_VISIBLE_TAIL_MAX_COMPACT_CHARS:
        return (compact + "\n" if compact else "") + "<host-truncated>"
    return compact


def compact_current_tail_payload(payload: Any) -> dict[str, Any] | None:
    """Copy only fields needed by the Host extractor; omit user text entirely."""

    if not isinstance(payload, dict):
        return None
    thread = payload.get("thread") if isinstance(payload.get("thread"), dict) else {}
    thread_id = thread.get("id") if isinstance(thread.get("id"), str) else ""
    turns = payload.get("turns")
    if not thread_id or not isinstance(turns, list):
        return None
    compact_turns: list[dict[str, Any]] = []
    for turn in turns:
        if not isinstance(turn, dict):
            continue
        turn_id = turn.get("id") if isinstance(turn.get("id"), str) else ""
        items = turn.get("items")
        if not turn_id or not isinstance(items, list):
            continue
        compact_items: list[dict[str, Any]] = []
        for item in items:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type") if isinstance(item.get("type"), str) else ""
            item_id = item.get("id") if isinstance(item.get("id"), str) else ""
            if item_type == "agentMessage":
                compact_items.append(
                    {
                        "type": item_type,
                        "id": item_id,
                        "phase": item.get("phase") if isinstance(item.get("phase"), str) else "commentary",
                        "text": _compact_agent_text(item.get("text")),
                    }
                )
            elif item_type == "userMessage":
                # User text is neither an anchor nor needed for this selector.
                compact_items.append({"type": item_type, "id": item_id})
        compact_turns.append({"id": turn_id, "items": compact_items})
    page = payload.get("page") if isinstance(payload.get("page"), dict) else {}
    return {
        "thread": {"id": thread_id},
        "page": {"order": page.get("order") if isinstance(page.get("order"), str) else "newest_first"},
        "turns": compact_turns,
    }


def _read_with_timeout(
    reader: Callable[..., Any],
    *,
    turn_limit: int,
    timeout_seconds: float,
) -> tuple[Any | None, str]:
    """Run one Host read to a caller deadline without claiming cancellation.

    A desktop tool call cannot be force-cancelled from this Python process.
    The returned timeout therefore means the caller deadline elapsed, *not*
    that history is unavailable or that the Host call stopped.  A single
    in-flight latch avoids spawning a growing set of daemon readers when a
    Host transport is slow.
    """

    global _READ_INFLIGHT
    with _READ_LOCK:
        if _READ_INFLIGHT:
            return None, "HOST_VISIBLE_TAIL_READ_INFLIGHT"
        _READ_INFLIGHT = True

    result_queue: Queue[tuple[bool, Any]] = Queue(maxsize=1)

    def invoke() -> None:
        global _READ_INFLIGHT
        try:
            result_queue.put(
                (
                    True,
                    reader(
                        turnLimit=turn_limit,
                        includeOutputs=False,
                        maxOutputCharsPerItem=HOST_VISIBLE_TAIL_MAX_OUTPUT_CHARS,
                    ),
                )
            )
        except BaseException as error:  # Host tool errors are untrusted transport failures.
            result_queue.put((False, type(error).__name__))
        finally:
            with _READ_LOCK:
                _READ_INFLIGHT = False

    thread = Thread(target=invoke, name="super-brain-host-tail", daemon=True)
    thread.start()
    thread.join(timeout_seconds)
    if thread.is_alive():
        return None, "HOST_VISIBLE_TAIL_READ_DEADLINE_EXCEEDED"
    try:
        ok, value = result_queue.get_nowait()
    except Exception:
        return None, "HOST_VISIBLE_TAIL_READ_FAILED"
    return (value, "HOST_VISIBLE_TAIL_READ_CURRENT") if ok else (None, "HOST_VISIBLE_TAIL_READ_FAILED")


def acquire_current_visible_assertion(
    *,
    visible_context: dict[str, Any] | None = None,
    reader: Callable[..., Any] | None = None,
    timeout_seconds: float = HOST_VISIBLE_TAIL_READ_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Produce the single normal same-workline observation for H7.

    If the Host has already exposed the current real assistant message, this
    is a zero-read path.  Otherwise it performs the bounded current-thread
    lookup.  Both paths always produce ``current_visible_assistant``; v4 is a
    classification of that same candidate, never a different history selector.
    """

    if isinstance(visible_context, dict):
        required = ("host_thread_id", "turn_id", "message_id", "phase", "text")
        if not all(isinstance(visible_context.get(key), str) and str(visible_context.get(key)).strip() for key in required):
            return _fail("HOST_VISIBLE_CONTEXT_INPUT_INVALID")
        observation = observe_visible_context_message(
            host_thread_id=str(visible_context["host_thread_id"]),
            turn_id=str(visible_context["turn_id"]),
            message_id=str(visible_context["message_id"]),
            phase=str(visible_context["phase"]),
            text=str(visible_context["text"]),
        )
        if observation.get("ok") is not True:
            return _fail(str(observation.get("code", "HOST_VISIBLE_CONTEXT_OBSERVATION_WITHHELD")))
        return {
            "ok": True,
            "schema": "super-brain.host-continuation-acquisition.v1",
            "code": "HOST_VISIBLE_CONTEXT_CURRENT",
            "source": "codex_visible_context",
            "readAttempts": 0,
            "readDeadlineSeconds": 0.0,
            "observation": {key: value for key, value in observation.items() if key != "ok"},
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    if not callable(reader):
        return _fail("HOST_VISIBLE_TAIL_READER_REQUIRED")
    result = observe_current_thread(reader, purpose=PURPOSE_NORMAL_SAME_WORKLINE, timeout_seconds=timeout_seconds)
    if result.get("ok") is not True:
        return result
    return {
        **result,
        "schema": "super-brain.host-continuation-acquisition.v1",
        "source": "codex_app_read_thread",
        "readDeadlineSeconds": float(result.get("readDeadlineSeconds", timeout_seconds)),
    }


def observe_current_thread(
    reader: Callable[..., Any],
    *,
    purpose: str = PURPOSE_NORMAL_SAME_WORKLINE,
    timeout_seconds: float = HOST_VISIBLE_TAIL_READ_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Read only the current Host tail, at most once plus one bounded retry.

    ``reader`` must be the host's current-thread ``read_thread`` callable.
    No historic cursor, user-anchor selector, caller-selected phase, or state
    fallback is accepted.  The success payload's ``observation`` is the only
    value that may be passed to H7 ``brain_turn``.  ``normal_same_workline``
    returns the newest visible assistant observation (which may later be
    display-only).  ``strict_recovery`` classifies that same newest message
    as durable only when it is a receipt-bound v4 prefix; it never walks
    backward to an older publication.  ``drift_diagnosis`` is not a normal
    continuation path.
    """

    if purpose not in {
        PURPOSE_NORMAL_SAME_WORKLINE,
        PURPOSE_STRICT_RECOVERY,
        PURPOSE_DRIFT_DIAGNOSIS,
    }:
        return _fail("HOST_VISIBLE_TAIL_SELECTION_INVALID")
    if not callable(reader) or timeout_seconds <= 0 or timeout_seconds > HOST_VISIBLE_TAIL_READ_TIMEOUT_SECONDS:
        return _fail("HOST_VISIBLE_TAIL_READ_CONFIGURATION_INVALID")
    # Every normal/recovery event starts with the same current assistant tail.
    # ``strict_recovery`` is retained as a compatibility purpose, but v4 is
    # classified later by H7 against this exact candidate rather than selected
    # by a separate, backwards-looking path.
    extractor = {
        PURPOSE_NORMAL_SAME_WORKLINE: select_current_visible_assistant,
        PURPOSE_STRICT_RECOVERY: select_current_visible_assistant,
        PURPOSE_DRIFT_DIAGNOSIS: select_latest_assistant,
    }[purpose]
    deadline = monotonic() + timeout_seconds
    attempts = (1, 2)
    for attempt_index, turn_limit in enumerate(attempts, start=1):
        remaining = deadline - monotonic()
        if remaining <= 0:
            return _fail("HOST_VISIBLE_TAIL_READ_DEADLINE_EXCEEDED")
        payload, read_code = _read_with_timeout(reader, turn_limit=turn_limit, timeout_seconds=remaining)
        if payload is None:
            return _fail(
                read_code,
                transport_may_still_run=read_code in {
                    "HOST_VISIBLE_TAIL_READ_DEADLINE_EXCEEDED",
                    "HOST_VISIBLE_TAIL_READ_INFLIGHT",
                },
            )
        compact_payload = compact_current_tail_payload(payload)
        if compact_payload is None:
            return _fail("HOST_VISIBLE_TAIL_READ_PAYLOAD_INVALID")
        observation = extractor(compact_payload)
        if observation.get("ok") is True:
            return {
                "ok": True,
                "schema": "super-brain.host-continuation-bridge.v1",
                "code": "HOST_VISIBLE_TAIL_OBSERVATION_CURRENT",
                "purpose": purpose,
                "readAttempts": attempt_index,
                "readDeadlineSeconds": timeout_seconds,
                "transportMayStillRun": False,
                "observation": {key: value for key, value in observation.items() if key != "ok"},
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        if attempt_index == 1 and str(observation.get("code", "")) in _RETRYABLE_EMPTY_CODES:
            continue
        return _fail(str(observation.get("code", "HOST_VISIBLE_TAIL_OBSERVATION_WITHHELD")))
    return _fail("HOST_VISIBLE_TAIL_OBSERVATION_WITHHELD")
