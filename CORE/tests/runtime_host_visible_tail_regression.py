from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from host_visible_tail import (
    SCHEMA,
    VISIBLE_CONTEXT_OBSERVATION_SOURCE,
    observe_visible_context_message,
    select_before_latest_user,
    select_current_visible_assistant,
    select_latest_assistant,
    select_latest_durable_assistant,
)


RECEIPT_HASH = "a" * 64
PROGRESS = "Stage 9 external-entry acceptance passed; repair the phase gate before Stage 10."


def v4_envelope(sentence: str = PROGRESS, receipt_hash: str = RECEIPT_HASH) -> str:
    return f"G1\n[H7-PROGRESS-V4 receipt_hash={receipt_hash}]\n{sentence}"


def payload_with(*items: dict[str, object]) -> dict[str, object]:
    return {
        "thread": {"id": "019fe035-b8ac-73e2-947c-6f6fd16cdc65"},
        "page": {"order": "oldest_first"},
        "turns": [{"id": "turn-current", "items": list(items)}],
    }


def agent(item_id: str, text: str, phase: str = "commentary") -> dict[str, object]:
    return {"type": "agentMessage", "id": item_id, "phase": phase, "text": text}


def test_v4_exact_envelope_is_the_only_normal_durable_anchor() -> None:
    result = select_latest_durable_assistant(payload_with(agent("v4", v4_envelope())))
    assert result["ok"] is True, result
    assert result["schema"] == SCHEMA, result
    assert result["selection"] == "latest_durable_assistant", result
    assert result["publication_kind"] == "h7_durable_progress", result
    assert result["envelope_version"] == "v4", result
    assert result["h7_receipt_hash"] == RECEIPT_HASH, result
    assert result["last_confirmed_sentence"] == PROGRESS, result
    assert result["raw_prompt_stored"] is False, result
    assert result["raw_transcript_stored"] is False, result


def test_loose_g1_commentary_without_v4_binding_is_legacy_withheld_not_durable() -> None:
    loose = "G1\nStage 9 passed.\nI will now inspect extra evidence and keep working."
    payload = payload_with(agent("loose-g1", loose))
    observed = select_latest_assistant(payload)
    assert observed["ok"] is True, observed
    assert observed["publication_kind"] == "legacy_h7_progress_withheld", observed
    assert observed["envelope_version"] == "legacy_v3", observed
    assert "h7_receipt_hash" not in observed, observed
    durable = select_latest_durable_assistant(payload)
    assert durable["ok"] is False, durable
    assert durable["code"] == "HOST_VISIBLE_TAIL_NEWER_UNPUBLISHED_ASSISTANT_MESSAGE", durable


def test_v3_looking_recovery_line_is_withheld_and_cannot_walk_back_over_newer_commentary() -> None:
    legacy = "已接上：The old recovery sentence must not be a normal anchor."
    payload = payload_with(
        agent("v4-old", v4_envelope("The old current receipt is still valid.")),
        agent("legacy-new", legacy),
    )
    latest = select_latest_assistant(payload)
    assert latest["ok"] is True, latest
    assert latest["host_message_id"] == "legacy-new", latest
    assert latest["publication_kind"] == "legacy_h7_progress_withheld", latest
    durable = select_latest_durable_assistant(payload)
    assert durable["ok"] is False, durable
    assert durable["code"] == "HOST_VISIBLE_TAIL_NEWER_UNPUBLISHED_ASSISTANT_MESSAGE", durable


def test_current_visible_selector_uses_the_newest_assistant_reply_after_a_user_message() -> None:
    """A user message never creates an old-receipt cutoff for tail selection."""

    payload = payload_with(
        agent("v4-old", v4_envelope("An older durable receipt must not become the start point.")),
        {"type": "userMessage", "id": "user-continue"},
        agent("plain-new", "First map the current task and project evidence before continuing."),
    )
    observed = select_current_visible_assistant(payload)
    assert observed["ok"] is True, observed
    assert observed["selection"] == "current_visible_assistant", observed
    assert observed["host_message_id"] == "plain-new", observed
    assert observed["last_confirmed_sentence"] == "First map the current task and project evidence before continuing.", observed
    assert observed["publication_kind"] == "unclassified_assistant_reply", observed
    assert observed["envelope_version"] == "none", observed
    durable = select_latest_durable_assistant(payload)
    assert durable["ok"] is False, durable
    assert durable["code"] == "HOST_VISIBLE_TAIL_NEWER_UNPUBLISHED_ASSISTANT_MESSAGE", durable


def test_current_visible_selector_uses_temporal_tail_when_host_returns_newest_first_turns() -> None:
    payload = {
        "thread": {"id": "019fe035-b8ac-73e2-947c-6f6fd16cdc65"},
        "page": {"order": "newest_first"},
        "turns": [
            {"id": "turn-new", "items": [agent("new", "The newest turn is the only continuation start point.")]},
            {"id": "turn-old", "items": [agent("old", v4_envelope("The older receipt is not the current tail."))]},
        ],
    }
    observed = select_current_visible_assistant(payload)
    assert observed["ok"] is True, observed
    assert observed["host_turn_id"] == "turn-new", observed
    assert observed["host_message_id"] == "new", observed
    assert observed["last_confirmed_sentence"] == "The newest turn is the only continuation start point.", observed


def test_malformed_binding_or_extra_line_never_becomes_durable() -> None:
    malformed = [
        "G1\n[H7-PROGRESS-V4 receipt_hash=ABC]\nProgress is not bound.",
        "G1\n[H7-PROGRESS-V4 receipt_hash=" + RECEIPT_HASH.upper() + "]\nUppercase is not canonical.",
        "G1\n[H7-PROGRESS-V4 receipt_hash=" + RECEIPT_HASH + "]\n<host-truncated>",
    ]
    for index, text in enumerate(malformed):
        payload = payload_with(agent(f"malformed-{index}", text))
        observed = select_latest_assistant(payload)
        assert observed["ok"] is True, observed
        assert observed["publication_kind"] != "h7_durable_progress", observed
        durable = select_latest_durable_assistant(payload)
        assert durable["ok"] is False, durable


def test_v4_prefix_remains_durable_when_display_receipt_has_later_prose_or_truncation_marker() -> None:
    for suffix in (
        "\nEvidence: runtime replay passed.\nNext: package verification.",
        "\n<host-truncated>",
        "\n\nEvidence: runtime replay passed.\n\nNext: package verification.",
    ):
        durable = select_latest_durable_assistant(payload_with(agent("v4-prefix", v4_envelope() + suffix)))
        assert durable["ok"] is True, durable
        assert durable["publication_kind"] == "h7_durable_progress", durable
        assert durable["last_confirmed_sentence"] == PROGRESS, durable


def test_v4_uses_the_first_three_nonempty_lines_even_with_internal_blank_lines() -> None:
    text = (
        "G1\n\n"
        f"[H7-PROGRESS-V4 receipt_hash={RECEIPT_HASH}]\n\n"
        f"{PROGRESS}\n\n"
        "Evidence: the later line is display-only."
    )
    durable = select_latest_durable_assistant(payload_with(agent("v4-spaced", text)))
    assert durable["ok"] is True, durable
    assert durable["publication_kind"] == "h7_durable_progress", durable
    assert durable["h7_receipt_hash"] == RECEIPT_HASH, durable
    assert durable["last_confirmed_sentence"] == PROGRESS, durable


def test_visible_context_fast_path_extracts_one_assistant_message_without_thread_read() -> None:
    result = observe_visible_context_message(
        host_thread_id="019fe035-b8ac-73e2-947c-6f6fd16cdc65",
        turn_id="visible-context-current-turn",
        message_id="visible-context-latest-assistant",
        phase="commentary",
        text=v4_envelope(),
    )
    assert result["ok"] is True, result
    assert result["observation_source"] == VISIBLE_CONTEXT_OBSERVATION_SOURCE, result
    assert result["selection"] == "current_visible_assistant", result
    assert result["publication_kind"] == "h7_durable_progress", result
    assert result["last_confirmed_sentence"] == PROGRESS, result
    # The in-process helper result has exactly one transport-status wrapper.
    # H7 may strip only this ``ok: true`` key, then must validate the remaining
    # strict v4 observation shape without accepting arbitrary helper metadata.
    assert set(result) == {
        "ok",
        "schema",
        "observation_source",
        "selection",
        "host_thread_id",
        "host_turn_id",
        "host_message_id",
        "message_phase",
        "last_confirmed_sentence",
        "source",
        "publication_kind",
        "envelope_version",
        "h7_receipt_hash",
        "raw_prompt_stored",
        "raw_transcript_stored",
    }, result


def test_visible_context_plain_newer_message_is_a_current_display_only_observation() -> None:
    result = observe_visible_context_message(
        host_thread_id="019fe035-b8ac-73e2-947c-6f6fd16cdc65",
        turn_id="visible-context-current-turn",
        message_id="visible-context-newer-plain",
        phase="commentary",
        text="The current response is not a durable progress publication yet.",
    )
    assert result["ok"] is True, result
    # A plain current message on an uninterrupted workline must be observable
    # without being promoted into the legacy drift-repair selector.  H7 then
    # treats this as display-only; a recovery boundary remains strict v4.
    assert result["selection"] == "current_visible_assistant", result
    assert result["publication_kind"] == "unclassified_assistant_reply", result


def test_latest_assistant_remains_visible_even_when_unclassified() -> None:
    payload = payload_with(
        agent("official", v4_envelope()),
        {"type": "userMessage", "id": "user-correction"},
        agent("ordinary", "I am checking current project proof before acting."),
    )
    result = select_latest_assistant(payload)
    assert result["ok"] is True, result
    assert result["host_message_id"] == "ordinary", result
    assert result["publication_kind"] == "unclassified_assistant_reply", result
    durable = select_latest_durable_assistant(payload)
    assert durable["ok"] is False, durable
    assert durable["code"] == "HOST_VISIBLE_TAIL_NEWER_UNPUBLISHED_ASSISTANT_MESSAGE", durable


def test_cli_never_persists_the_thread_input() -> None:
    payload = json.dumps(payload_with(agent("v4", v4_envelope())), ensure_ascii=False, separators=(",", ":"))
    command = [sys.executable, str(ROOT / "runtime" / "host_visible_tail.py"), "--thread-json", payload]
    with tempfile.TemporaryDirectory(prefix="super-brain-visible-tail-cli-") as directory:
        completed = subprocess.run(command, cwd=directory, text=True, capture_output=True, encoding="utf-8", check=False)
        assert completed.returncode == 0, completed.stderr
        result = json.loads(completed.stdout)
        assert result["schema"] == SCHEMA, result
        assert "ok" not in result, result
        assert result["h7_receipt_hash"] == RECEIPT_HASH, result
        assert not list(Path(directory).iterdir()), list(Path(directory).iterdir())


def test_cli_default_uses_current_visible_assistant_not_an_older_durable_reply() -> None:
    payload = json.dumps(
        payload_with(
            agent("v4-old", v4_envelope("An old receipt must not be selected by the default.")),
            agent("plain-new", "The actual current assistant reply is ordinary prose."),
        ),
        ensure_ascii=False,
        separators=(",", ":"),
    )
    command = [sys.executable, str(ROOT / "runtime" / "host_visible_tail.py"), "--thread-json", payload]
    completed = subprocess.run(command, text=True, capture_output=True, encoding="utf-8", check=False)
    assert completed.returncode == 0, completed.stderr
    result = json.loads(completed.stdout)
    assert result["selection"] == "current_visible_assistant", result
    assert result["host_message_id"] == "plain-new", result
    assert result["publication_kind"] == "unclassified_assistant_reply", result
    assert "h7_receipt_hash" not in result, result


def test_retired_before_user_selector_never_scans_back_to_an_old_reply() -> None:
    payload = payload_with(
        agent("old", v4_envelope("A previous current receipt.")),
        {"type": "userMessage", "id": "user"},
    )
    legacy = select_before_latest_user(payload)
    assert legacy["ok"] is False, legacy
    assert legacy["code"] == "HOST_VISIBLE_TAIL_RETIRED_SELECTOR", legacy


def main() -> int:
    test_v4_exact_envelope_is_the_only_normal_durable_anchor()
    test_loose_g1_commentary_without_v4_binding_is_legacy_withheld_not_durable()
    test_v3_looking_recovery_line_is_withheld_and_cannot_walk_back_over_newer_commentary()
    test_current_visible_selector_uses_the_newest_assistant_reply_after_a_user_message()
    test_current_visible_selector_uses_temporal_tail_when_host_returns_newest_first_turns()
    test_malformed_binding_or_extra_line_never_becomes_durable()
    test_v4_prefix_remains_durable_when_display_receipt_has_later_prose_or_truncation_marker()
    test_v4_uses_the_first_three_nonempty_lines_even_with_internal_blank_lines()
    test_visible_context_fast_path_extracts_one_assistant_message_without_thread_read()
    test_visible_context_plain_newer_message_is_a_current_display_only_observation()
    test_latest_assistant_remains_visible_even_when_unclassified()
    test_cli_never_persists_the_thread_input()
    test_cli_default_uses_current_visible_assistant_not_an_older_durable_reply()
    test_retired_before_user_selector_never_scans_back_to_an_old_reply()
    print("runtime host-visible-tail regression: passed (14/14)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
