"""Ephemeral, host-side extraction of the exact visible progress tail.

The Codex host owns conversation visibility; H7 deliberately does not retain a
raw prompt or transcript.  This module is therefore a narrow adapter: it reads
one already-returned ``codex_app.read_thread`` payload in memory, selects the
actual latest assistant-visible progress line in the current thread, and
returns only the bounded observation that H7 needs.  User messages classify
the current request, but never bracket, truncate, or select the progress
anchor.  The adapter never writes input, thread text, or host identifiers to
disk.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
from typing import Any, Iterable


SCHEMA = "super-brain.visible-tail-observation.v4"
LEGACY_SCHEMA = "super-brain.visible-tail-observation.v3"
OBSERVATION_SOURCE = "codex_app_read_thread"
VISIBLE_CONTEXT_OBSERVATION_SOURCE = "codex_visible_context"
# Retained only as a wire-compatibility name.  It is no longer a selector:
# choosing an assistant reply from before the latest user message lets old
# history replace the current visible tail.
SELECTION_BEFORE_LATEST_USER = "before_latest_user"
# The latest visible assistant message on an uninterrupted same workline.  A
# plain message selected here is only a display/readback observation; H7 must
# never promote it to progress, phase, or authorization.
SELECTION_CURRENT_VISIBLE_ASSISTANT = "current_visible_assistant"
# Reserved for the explicit drift-diagnostic fallback after H7 has already
# detected a mismatch.  It is deliberately not the normal same-workline
# selector so normal observations cannot accidentally enter a repair path.
SELECTION_LATEST_ASSISTANT = "latest_assistant"
SELECTION_LATEST_DURABLE_ASSISTANT = "latest_durable_assistant"
MESSAGE_PHASES = {"commentary", "final"}
MAX_SENTENCE_CHARS = 320
PUBLICATION_KIND_DURABLE = "h7_durable_progress"
PUBLICATION_KIND_LEGACY_WITHHELD = "legacy_h7_progress_withheld"
PUBLICATION_KIND_UNCLASSIFIED = "unclassified_assistant_reply"
ENVELOPE_VERSION_V4 = "v4"
ENVELOPE_VERSION_LEGACY_V3 = "legacy_v3"
ENVELOPE_VERSION_NONE = "none"
_V4_RECEIPT_BINDING = re.compile(r"^\[H7-PROGRESS-V4 receipt_hash=([0-9a-f]{64})\]$")


def _fail(code: str) -> dict[str, Any]:
    return {
        "ok": False,
        "schema": SCHEMA,
        "code": code,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _thread_items(payload: Any) -> Iterable[tuple[str, dict[str, Any]]]:
    if not isinstance(payload, dict):
        return ()
    turns = payload.get("turns")
    if not isinstance(turns, list):
        return ()
    page = payload.get("page") if isinstance(payload.get("page"), dict) else {}
    ordered_turns = list(reversed(turns)) if page.get("order") == "newest_first" else list(turns)
    flattened: list[tuple[str, dict[str, Any]]] = []
    for turn in ordered_turns:
        if not isinstance(turn, dict):
            continue
        turn_id = str(turn.get("id", "")).strip()
        items = turn.get("items")
        if not turn_id or not isinstance(items, list):
            continue
        for item in items:
            if isinstance(item, dict):
                flattened.append((turn_id, item))
    return flattened


def _progress_line(value: Any) -> str | None:
    """Return one H7-compatible visible progress sentence, never a transcript."""

    if not isinstance(value, str):
        return None
    for line in value.splitlines():
        candidate = line.strip()
        if not candidate or candidate == "G1" or candidate == "<thinking>":
            continue
        if candidate.startswith("已接上："):
            candidate = candidate[len("已接上：") :].strip()
        if (
            not candidate
            or candidate == "<host-truncated>"
            or len(candidate) > MAX_SENTENCE_CHARS
            or "\r" in candidate
            or "\n" in candidate
            or any(ord(character) < 32 for character in candidate)
        ):
            return None
        return candidate
    return None


def _legacy_publication_kind(value: Any, *, message_phase: str = "commentary") -> str:
    """Classify retired non-v4 markers without promoting them to progress.

    Every visible assistant message remains observable.  Only a strict v4
    envelope is durable; plain and legacy text may be display-only but can
    never become a continuation anchor merely because it looks like one.
    """

    if not isinstance(value, str):
        return PUBLICATION_KIND_UNCLASSIFIED
    lines = [line.strip() for line in value.splitlines() if line.strip() and line.strip() != "<thinking>"]
    if not lines:
        return PUBLICATION_KIND_UNCLASSIFIED

    # Durability belongs to the first compact progress sentence, not to the
    # whole reply. A real stage receipt may include evidence and a next-step
    # explanation after that sentence, and the Host may append a truncation
    # marker after preserving the bounded first three lines. Skipping such a
    # reply walks recovery back to an older message. H7 still validates the
    # extracted sentence against the current scoped receipt and live project
    # proof; later lines remain transient and non-authorizing.
    if (lines[0] == "G1" or lines[0].startswith("已接上：")) and _progress_line(value) is not None:
        return PUBLICATION_KIND_DURABLE
    return PUBLICATION_KIND_UNCLASSIFIED


def _strict_sentence(value: Any) -> str | None:
    """Validate one bounded display sentence without retaining a transcript."""

    if not isinstance(value, str):
        return None
    sentence = value.strip()
    if (
        not sentence
        or sentence == "<host-truncated>"
        or len(sentence) > MAX_SENTENCE_CHARS
        or "\r" in sentence
        or "\n" in sentence
        or any(ord(character) < 32 for character in sentence)
    ):
        return None
    return sentence


def _v4_envelope(value: Any) -> dict[str, str] | None:
    """Parse the receipt-bound v4 prefix of a visible progress publication.

    A formal user receipt may add evidence or a next-step explanation after
    the three-line H7 envelope.  Those later lines are deliberately ignored:
    they cannot alter the anchor, but their presence must not make the valid
    prefix disappear and force recovery back to an older message.
    """

    if not isinstance(value, str):
        return None
    lines = [line.strip() for line in value.splitlines() if line.strip() and line.strip() != "<thinking>"]
    if len(lines) < 3:
        return None
    heading, binding, sentence_line = lines[:3]
    if heading != "G1":
        return None
    match = _V4_RECEIPT_BINDING.fullmatch(binding)
    sentence = _strict_sentence(sentence_line)
    if match is None or sentence is None:
        return None
    return {"h7_receipt_hash": match.group(1), "last_confirmed_sentence": sentence}


def _legacy_v3_progress(value: Any) -> bool:
    """Recognize old v3-looking content only to label it withheld."""

    return _legacy_publication_kind(value) == PUBLICATION_KIND_DURABLE


def _envelope_metadata(value: Any) -> dict[str, str]:
    envelope = _v4_envelope(value)
    if envelope is not None:
        return {
            "publication_kind": PUBLICATION_KIND_DURABLE,
            "envelope_version": ENVELOPE_VERSION_V4,
            **envelope,
        }
    if _legacy_v3_progress(value):
        return {
            "publication_kind": PUBLICATION_KIND_LEGACY_WITHHELD,
            "envelope_version": ENVELOPE_VERSION_LEGACY_V3,
        }
    return {
        "publication_kind": PUBLICATION_KIND_UNCLASSIFIED,
        "envelope_version": ENVELOPE_VERSION_NONE,
    }


def _publication_kind(value: Any, *, message_phase: str = "commentary") -> str:
    """Return v4 durability; the message phase cannot promote an envelope."""

    del message_phase
    return _envelope_metadata(value)["publication_kind"]


def _message_phase(item: dict[str, Any]) -> str:
    """Normalize the small set of Host phase aliases used by Codex Desktop."""

    phase_value = item.get("phase", "")
    phase = (phase_value.strip() if isinstance(phase_value, str) else "") or "commentary"
    return "final" if phase == "final_answer" else phase


def _observation(
    *,
    host_thread_id: str,
    turn_id: str,
    item: dict[str, Any],
    selection: str,
    observation_source: str = OBSERVATION_SOURCE,
) -> dict[str, Any]:
    message_id = str(item.get("id", "")).strip()
    # Codex currently omits ``phase`` on some visible commentary messages.
    # ``agentMessage`` is already the Host's user-visible message class, so a
    # blank phase is normalized to commentary rather than silently discarding
    # the actual latest agent progress and walking back to an older reply.
    phase = _message_phase(item)
    envelope = _envelope_metadata(item.get("text"))
    sentence = envelope.get("last_confirmed_sentence") or _progress_line(item.get("text"))
    if not message_id:
        return _fail("HOST_VISIBLE_TAIL_MESSAGE_ID_REQUIRED")
    if phase not in MESSAGE_PHASES:
        return _fail("HOST_VISIBLE_TAIL_MESSAGE_PHASE_REQUIRED")
    if sentence is None:
        return _fail("HOST_VISIBLE_TAIL_PROGRESS_LINE_INVALID")
    observation = {
        "ok": True,
        "schema": SCHEMA,
        "observation_source": observation_source,
        "selection": selection,
        "host_thread_id": host_thread_id,
        "host_turn_id": turn_id,
        "host_message_id": message_id,
        "message_phase": phase,
        "last_confirmed_sentence": sentence,
        "source": "assistant_visible_reply",
        "publication_kind": envelope["publication_kind"],
        "envelope_version": envelope["envelope_version"],
        "raw_prompt_stored": False,
        "raw_transcript_stored": False,
    }
    # Missing binding is deliberately not serialized as an empty value: v3
    # text must never be able to masquerade as a receipt-bound v4 envelope.
    if envelope["publication_kind"] == PUBLICATION_KIND_DURABLE:
        observation["h7_receipt_hash"] = envelope["h7_receipt_hash"]
    return observation


def observe_visible_context_message(
    *,
    host_thread_id: str,
    turn_id: str,
    message_id: str,
    phase: str,
    text: str,
) -> dict[str, Any]:
    """Extract one exact assistant message already present in visible context.

    This is the fast path: the Host has already exposed the current assistant
    tail to the caller, so no thread/history read is needed.  The helper keeps
    only the same bounded observation shape used by the current-thread reader.
    """

    item = {"type": "agentMessage", "id": message_id, "phase": phase, "text": text}
    # This is the normal same-workline path, so the latest actual visible
    # assistant message is always the candidate.  Whether its prefix is a
    # durable v4 receipt is a separate H7 validation of this *same* candidate;
    # it must not change the selector into an older-receipt lookup.
    selection = SELECTION_CURRENT_VISIBLE_ASSISTANT
    return _observation(
        host_thread_id=host_thread_id,
        turn_id=turn_id,
        item=item,
        selection=selection,
        observation_source=VISIBLE_CONTEXT_OBSERVATION_SOURCE,
    )


def _host_and_items(payload: Any) -> tuple[str, list[tuple[str, dict[str, Any]]] | None, dict[str, Any] | None]:
    thread = payload.get("thread") if isinstance(payload, dict) else None
    host_thread_id = str((thread or {}).get("id", "")).strip() if isinstance(thread, dict) else ""
    if not host_thread_id:
        return "", None, _fail("HOST_VISIBLE_TAIL_THREAD_ID_REQUIRED")
    return host_thread_id, list(_thread_items(payload)), None


def select_before_latest_user(payload: Any) -> dict[str, Any]:
    """Reject the retired history selector without inspecting older messages.

    A continuation start point is always the current thread's newest actual
    assistant reply.  Keeping a callable compatibility symbol is safer than
    silently walking an old caller back through user messages, summaries, or
    old receipts.  Callers must move to
    :func:`select_current_visible_assistant` (or use
    :func:`select_latest_assistant` only for an already-detected drift).
    """

    del payload
    return _fail("HOST_VISIBLE_TAIL_RETIRED_SELECTOR")


def _latest_actual_assistant(items: Iterable[tuple[str, dict[str, Any]]]) -> tuple[str, dict[str, Any]] | None:
    """Return exactly one temporal candidate: the newest actual agent reply.

    Selection is intentionally separate from v4 classification.  A current
    plain, legacy, malformed, or otherwise non-durable reply remains the
    current candidate; it must never cause a backwards search for an older
    envelope.
    """

    materialized = list(items)
    for turn_id, item in reversed(materialized):
        if item.get("type") == "agentMessage":
            return turn_id, item
    return None


def _select_latest_assistant(payload: Any, *, selection: str) -> dict[str, Any]:
    """Extract the actual latest assistant message without walking backward."""

    host_thread_id, items, failure = _host_and_items(payload)
    if failure is not None or items is None:
        return failure or _fail("HOST_VISIBLE_TAIL_INPUT_INVALID")
    latest = _latest_actual_assistant(items)
    if latest is not None:
        turn_id, item = latest
        return _observation(host_thread_id=host_thread_id, turn_id=turn_id, item=item, selection=selection)
    return _fail("HOST_VISIBLE_TAIL_CURRENT_ASSISTANT_PROGRESS_REQUIRED")


def select_current_visible_assistant(payload: Any) -> dict[str, Any]:
    """Select the latest actual assistant message for normal same-workline use.

    The result proves only what the user can currently see.  Strict H7 runtime
    validation decides whether it is a receipt-bound progress anchor or a
    non-authorizing display-only readback.  User messages never select or
    truncate the candidate.
    """

    return _select_latest_assistant(payload, selection=SELECTION_CURRENT_VISIBLE_ASSISTANT)


def select_latest_assistant(payload: Any) -> dict[str, Any]:
    """Select the latest assistant message for explicit drift diagnosis only.

    Normal same-workline continuation uses
    :func:`select_current_visible_assistant`; this legacy-named selector stays
    narrow so it cannot silently turn an ordinary visible message into a
    fallback repair input.
    """

    return _select_latest_assistant(payload, selection=SELECTION_LATEST_ASSISTANT)


def select_latest_durable_assistant(payload: Any) -> dict[str, Any]:
    """Classify the latest assistant message only when it is a v4 publication.

    A newer plain or legacy assistant message is a real visible-state change.
    It must block recovery rather than allowing a backward scan to revive an
    older durable receipt.  Explicit reconciliation owns that exceptional
    repair path.
    """

    host_thread_id, items, failure = _host_and_items(payload)
    if failure is not None or items is None:
        return failure or _fail("HOST_VISIBLE_TAIL_INPUT_INVALID")
    latest = _latest_actual_assistant(items)
    if latest is not None:
        turn_id, item = latest
        if _publication_kind(item.get("text"), message_phase=_message_phase(item)) != PUBLICATION_KIND_DURABLE:
            return _fail("HOST_VISIBLE_TAIL_NEWER_UNPUBLISHED_ASSISTANT_MESSAGE")
        return _observation(
            host_thread_id=host_thread_id,
            turn_id=turn_id,
            item=item,
            selection=SELECTION_LATEST_DURABLE_ASSISTANT,
        )
    return _fail("HOST_VISIBLE_TAIL_DURABLE_PROGRESS_REQUIRED")


def _parse_input(args: argparse.Namespace) -> Any:
    if bool(args.thread_json) == bool(args.thread_base64):
        raise ValueError("HOST_VISIBLE_TAIL_INPUT_REQUIRED")
    if args.thread_base64:
        decoded = base64.b64decode(args.thread_base64, validate=True).decode("utf-8")
        return json.loads(decoded)
    return json.loads(args.thread_json)


def main(argv: list[str] | None = None) -> int:
    # The host may run under a legacy Windows console code page.  The adapter
    # contract is JSON UTF-8, so make its one transient stdout packet explicit.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Extract one bounded Codex visible-tail observation without persistence.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--thread-json", default="")
    source.add_argument("--thread-base64", default="")
    parser.add_argument(
        "--selection",
        choices=(
            SELECTION_CURRENT_VISIBLE_ASSISTANT,
            SELECTION_LATEST_ASSISTANT,
            SELECTION_LATEST_DURABLE_ASSISTANT,
        ),
        # A command-line caller that does not explicitly ask for a strict
        # classification must observe the current visible assistant tail,
        # never select an older receipt-shaped message by default.
        default=SELECTION_CURRENT_VISIBLE_ASSISTANT,
    )
    args = parser.parse_args(argv)
    try:
        payload = _parse_input(args)
        if args.selection == SELECTION_CURRENT_VISIBLE_ASSISTANT:
            result = select_current_visible_assistant(payload)
        elif args.selection == SELECTION_LATEST_ASSISTANT:
            result = select_latest_assistant(payload)
        else:
            result = select_latest_durable_assistant(payload)
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
        result = _fail("HOST_VISIBLE_TAIL_INPUT_INVALID")
    # A successful CLI result is *exactly* the H7 input shape.  Keeping the
    # status wrapper out of stdout means the host adapter can pipe it directly
    # into ``brain_turn`` without hand-editing a supposedly automatic anchor.
    output = {key: value for key, value in result.items() if key != "ok"} if result.get("ok") is True else result
    print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))
    return 0 if result.get("ok") is True else 2


if __name__ == "__main__":
    raise SystemExit(main())
