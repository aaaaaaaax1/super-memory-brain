"""Regression checks for the bounded Codex Stop-hook continuation decision."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "runtime" / "codex_stop_hook.py"
SPEC = importlib.util.spec_from_file_location("codex_stop_hook", MODULE_PATH)
assert SPEC and SPEC.loader
HOOK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOOK)


def resolution(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "ok": True,
        "actionAuthorization": "allowed",
        "claimAllowed": True,
        "needsConfirmation": False,
        "blockers": [],
        "taskId": "task-main",
        "focusId": "approved-main",
        "focusLabel": "Approved main line",
        "nextAction": "run the next local verification",
        "latestUserInstruction": "what is the current progress?",
    }
    value.update(overrides)
    return value


def test_blocks_a_status_only_stop_when_local_work_remains() -> None:
    result = HOOK.decide_stop({"stop_hook_active": False}, resolution())
    assert result["decision"] == "block"
    assert "run the next local verification" in result["reason"]
    assert "status-only" in result["reason"]


def test_never_reblocks_an_already_continued_stop_turn() -> None:
    assert HOOK.decide_stop({"stop_hook_active": True}, resolution()) == {}


def test_withheld_or_user_blocked_work_never_continues() -> None:
    assert HOOK.decide_stop({}, resolution(actionAuthorization="withheld")) == {}
    assert HOOK.decide_stop({}, resolution(needsConfirmation=True)) == {}
    assert HOOK.decide_stop({}, resolution(blockers=["waiting for the user to choose"])) == {}
    assert HOOK.decide_stop({}, resolution(nextAction="No automatic action: waiting for the user's choice.")) == {}
    assert HOOK.decide_stop({}, resolution(nextAction="等待用户确认后再继续。")) == {}


def test_explicitly_nonblocking_evidence_does_not_hold_the_current_workline() -> None:
    result = HOOK.decide_stop(
        {},
        resolution(blockers=["P7 is awaiting a real host receipt; it does not block core continuity."]),
    )
    assert result["decision"] == "block"
    assert HOOK.decide_stop({}, resolution(blockers=["P7 仍等待真实 Host 证据；它不阻断核心主线。"]))["decision"] == "block"


def test_explicit_stop_or_replace_wins_over_old_mainline() -> None:
    assert HOOK.decide_stop({}, resolution(latestUserInstruction="stop")) == {}
    assert HOOK.decide_stop({}, resolution(latestUserInstruction="暂停")) == {}
    assert HOOK.decide_stop({}, resolution(latestUserInstruction="停止当前主线")) == {}
    assert HOOK.decide_stop({}, resolution(latestUserInstruction="do not continue the task")) == {}


def test_reason_never_echoes_secret_shaped_action_content() -> None:
    result = HOOK.decide_stop({}, resolution(nextAction="verify token=abc123secret then continue"))
    assert result["decision"] == "block"
    assert "token=[REDACTED]" in result["reason"]
    assert "abc123secret" not in result["reason"]


def main() -> None:
    tests = [
        test_blocks_a_status_only_stop_when_local_work_remains,
        test_never_reblocks_an_already_continued_stop_turn,
        test_withheld_or_user_blocked_work_never_continues,
        test_explicitly_nonblocking_evidence_does_not_hold_the_current_workline,
        test_explicit_stop_or_replace_wins_over_old_mainline,
        test_reason_never_echoes_secret_shaped_action_content,
    ]
    for test in tests:
        test()
    print("RUNTIME_STOP_HOOK_REGRESSION_OK")


if __name__ == "__main__":
    main()
