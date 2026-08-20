from __future__ import annotations

import tempfile
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

import turn_close_dispatcher


def test_resolve_transition_projection_skips_redundant_get() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-close-dispatch-dedupe-") as directory:
        project_root = Path(directory)
        calls: list[str] = []
        resolution = {
            "ok": True,
            "schema": "super-brain.execution-resolution.v1",
            "taskId": "task-close-dispatch-dedupe",
            "actionAuthorization": "allowed",
            "claimAllowed": True,
            "needsConfirmation": False,
            "blockers": [],
            "nextAction": "implement the approved fix",
            "canResumeParent": True,
            "contractRevision": 7,
            "planFingerprint": "plan-dedupe",
            "returnStack": [{"focusId": "parent"}],
            "transitionReceipts": [],
        }
        closed = {
            "ok": True,
            "idempotentReplay": False,
            "transitionAction": "ResumeParent",
            "taskId": resolution["taskId"],
            "revision": 8,
            "fromRevision": 7,
            "focusId": "parent",
            "transitionId": "close-dispatch-dedupe",
        }
        original_invoke = turn_close_dispatcher._invoke_contract
        original_project_root = turn_close_dispatcher._normalize_project_root

        def invoke(*_args: object, action: str, **_kwargs: object):
            calls.append(action)
            if action == "Resolve":
                return 0, resolution
            if action == "CloseTurn":
                return 0, closed
            raise AssertionError(f"unexpected authority action: {action}")

        turn_close_dispatcher._invoke_contract = invoke
        turn_close_dispatcher._normalize_project_root = lambda _value: project_root
        try:
            result = turn_close_dispatcher.dispatch_turn_close(
                ROOT,
                project_root / "state",
                task_id=str(resolution["taskId"]),
                workspace_key="ws-" + "1" * 24,
                session_key="sid-" + "2" * 24,
                turn_outcome="side_branch_completed",
                user_control="none",
                completion_evidence_ref="fixture:close-dispatch-dedupe",
                transition_id="close-dispatch-dedupe",
            )
        finally:
            turn_close_dispatcher._invoke_contract = original_invoke
            turn_close_dispatcher._normalize_project_root = original_project_root

        assert result["code"] == "TURN_CLOSE_DISPATCH_RESUMED_PARENT", result
        assert calls == ["Resolve", "CloseTurn"], calls


def main() -> int:
    test_resolve_transition_projection_skips_redundant_get()
    print("TURN_CLOSE_DEDUPE_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
