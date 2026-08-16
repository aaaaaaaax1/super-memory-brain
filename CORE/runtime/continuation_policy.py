"""Pure turn-close policy for Super Brain work-line continuation.

The policy owns no state and never receives a raw prompt.  Adapters provide a
verified execution resolution plus two small current-turn attestations:
``turn_outcome`` and ``user_control``.  This keeps the same decision usable by
the no-Hook context path, the write-side turn-close dispatcher, and the
optional Stop-hook accelerator without making any of them a second authority.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


SCHEMA = "super-brain.continuation-policy.v1"
TURN_OUTCOMES = frozenset(
    {
        "unknown",
        "ephemeral_insertion",
        "active_work_progressed",
        "side_branch_completed",
        "side_branch_partial",
        "blocked",
    }
)
USER_CONTROLS = frozenset({"unknown", "none", "stop", "replace"})

_NONBLOCKING_MARKERS = (
    "not blocking",
    "does not block",
    "non-blocking",
    "nonblocking",
    "\u4e0d\u963b\u65ad",
    "\u4e0d\u5f71\u54cd\u6838\u5fc3",
    "\u4e0d\u5f71\u54cd\u5f53\u524d",
)
_USER_INPUT_MARKERS = (
    "awaiting user",
    "wait for user",
    "requires user",
    "needs user",
    "real desktop host",
    "\u7b49\u5f85\u7528\u6237",
    "\u9700\u8981\u7528\u6237",
    "\u9700\u8981\u4f60\u786e\u8ba4",
    "\u8bf7\u7528\u6237",
    "\u771f\u5b9e desktop",
    "\u771f\u5b9e\u5bbf\u4e3b",
)


def _result(
    decision: str,
    code: str,
    *,
    requires_parent_resume: bool = False,
    branch_status: str = "",
) -> dict[str, Any]:
    terminal_reply_allowed = decision in {"pause_with_blocker", "withhold_reconcile"}
    return {
        "ok": True,
        "schema": SCHEMA,
        "decision": decision,
        "code": code,
        "terminalReplyAllowed": terminal_reply_allowed,
        "requiresParentResume": requires_parent_resume,
        "branchStatus": branch_status,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _withhold(code: str) -> dict[str, Any]:
    return _result("withhold_reconcile", code)


def _blockers(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, (list, tuple, set)):
        return [str(item) for item in value]
    if isinstance(value, dict):
        return [str(item) for item in value.values()]
    return []


def _has_blocking_blocker(value: Any) -> bool:
    for item in _blockers(value):
        compact = " ".join(item.strip().lower().split())
        if compact and not any(marker in compact for marker in _NONBLOCKING_MARKERS):
            return True
    return False


def _requires_user_input(next_action: Any) -> bool:
    compact = " ".join(str(next_action or "").strip().lower().split())
    if not compact or compact.startswith("no automatic action:"):
        return True
    return any(marker in compact for marker in _USER_INPUT_MARKERS)


def _canonical_plan_counts(value: Any) -> tuple[int, int, int, int] | None:
    """Return trusted canonical-plan counts without relying on prose."""

    if not isinstance(value, dict):
        return None
    expected = ("itemCount", "completedCount", "pendingCount", "cancelledCount")
    if all(name in value for name in expected):
        counts = tuple(value[name] for name in expected)
        if all(isinstance(count, int) and not isinstance(count, bool) and count >= 0 for count in counts):
            return counts  # type: ignore[return-value]
        return None
    items = value.get("items")
    if not isinstance(items, list) or not items:
        return None
    statuses = [str(item.get("status", "")) for item in items if isinstance(item, dict)]
    if len(statuses) != len(items) or any(status not in {"pending", "in_progress", "completed", "cancelled"} for status in statuses):
        return None
    return (
        len(items),
        sum(status == "completed" for status in statuses),
        sum(status in {"pending", "in_progress"} for status in statuses),
        sum(status == "cancelled" for status in statuses),
    )


def _has_verified_terminal_completion(resolution: dict[str, Any]) -> bool:
    """Allow a root workline to finish only on explicit structural evidence."""

    if str(resolution.get("currentPhase", "")).strip().casefold() not in {"complete", "completed", "done"}:
        return False
    if resolution.get("canResumeParent") is True:
        return False
    counts = _canonical_plan_counts(resolution.get("canonicalPlan"))
    if counts is None:
        return False
    item_count, completed_count, pending_count, cancelled_count = counts
    return item_count > 0 and pending_count == 0 and completed_count + cancelled_count == item_count


def decide_turn_close(
    resolution: dict[str, Any] | None,
    *,
    turn_outcome: str = "unknown",
    user_control: str = "unknown",
    completion_evidence_present: bool = False,
) -> dict[str, Any]:
    """Return a deterministic continuation decision without reading or writing state.

    ``resolution`` must already be scope- and receipt-validated by the
    execution contract. ``user_control`` is a structured attestation of the
    current visible user instruction; the policy deliberately refuses to infer
    that instruction from historical contract text.
    """

    if not isinstance(resolution, dict):
        return _withhold("CONTINUATION_POLICY_RESOLUTION_INVALID")
    if turn_outcome not in TURN_OUTCOMES or user_control not in USER_CONTROLS:
        return _withhold("CONTINUATION_POLICY_INPUT_INVALID")
    if resolution.get("ok") is not True:
        return _withhold("CONTINUATION_POLICY_RESOLUTION_UNAVAILABLE")
    if resolution.get("actionAuthorization") != "allowed":
        return _withhold("CONTINUATION_POLICY_ACTION_WITHHELD")
    if resolution.get("claimAllowed") is not True or resolution.get("needsConfirmation") is True:
        return _withhold("CONTINUATION_POLICY_RECONCILIATION_REQUIRED")
    if user_control == "unknown":
        return _withhold("CONTINUATION_POLICY_CURRENT_TURN_UNATTESTED")
    if user_control in {"stop", "replace"}:
        return _result("pause_with_blocker", "CONTINUATION_POLICY_USER_TERMINAL_CONTROL")
    if _has_blocking_blocker(resolution.get("blockers")):
        return _result("pause_with_blocker", "CONTINUATION_POLICY_RECORDED_BLOCKER")
    if _requires_user_input(resolution.get("nextAction")):
        return _result("pause_with_blocker", "CONTINUATION_POLICY_NO_AUTOMATIC_ACTION")
    if turn_outcome == "unknown":
        return _withhold("CONTINUATION_POLICY_TURN_OUTCOME_REQUIRED")
    if turn_outcome == "blocked":
        return _result("pause_with_blocker", "CONTINUATION_POLICY_TURN_BLOCKED")
    if turn_outcome in {"ephemeral_insertion", "active_work_progressed"} and _has_verified_terminal_completion(resolution):
        if not completion_evidence_present:
            return _withhold("CONTINUATION_POLICY_COMPLETION_EVIDENCE_REQUIRED")
        return _result("pause_with_blocker", "CONTINUATION_POLICY_VERIFIED_TASK_COMPLETE")
    if turn_outcome in {"ephemeral_insertion", "active_work_progressed"}:
        return _result("continue_current_turn", "CONTINUATION_POLICY_CONTINUE_CURRENT_TURN")
    if not completion_evidence_present:
        return _withhold("CONTINUATION_POLICY_COMPLETION_EVIDENCE_REQUIRED")
    if resolution.get("canResumeParent") is not True:
        return _withhold("CONTINUATION_POLICY_PARENT_UNAVAILABLE")
    branch_status = "completed" if turn_outcome == "side_branch_completed" else "partial"
    return _result(
        "resume_parent_required",
        "CONTINUATION_POLICY_RESUME_PARENT_REQUIRED",
        requires_parent_resume=True,
        branch_status=branch_status,
    )


def _read_request() -> dict[str, Any] | None:
    try:
        value = json.loads(sys.stdin.buffer.read().decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Pure Super Brain turn-close continuation policy")
    parser.add_argument("--stdin", action="store_true")
    args = parser.parse_args(argv)
    if not args.stdin:
        return 2
    request = _read_request()
    if not isinstance(request, dict) or set(request) != {
        "resolution",
        "turnOutcome",
        "userControl",
        "completionEvidencePresent",
    }:
        result = _withhold("CONTINUATION_POLICY_INPUT_INVALID")
    else:
        result = decide_turn_close(
            request.get("resolution") if isinstance(request.get("resolution"), dict) else None,
            turn_outcome=str(request.get("turnOutcome", "")),
            user_control=str(request.get("userControl", "")),
            completion_evidence_present=request.get("completionEvidencePresent") is True,
        )
    sys.stdout.buffer.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
