from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

import turn_runtime


class _DeniedScopeCore:
    def __init__(self) -> None:
        self.calls: list[bool] = []

    def authorize_scope(self, *, write: bool = False) -> dict[str, object]:
        self.calls.append(bool(write))
        return {
            "ok": False,
            "state": "unbound",
            "code": "H7_SCOPE_CHANNEL_UNBOUND",
            "accessMode": "write" if write else "read",
        }

    def scope_status(self) -> dict[str, object]:
        return {"state": "unbound", "code": "H7_SCOPE_CHANNEL_UNBOUND"}


class _ReboundScopeCore:
    class _Provider:
        provider_kind = "scope_broker_channel"

    def __init__(self) -> None:
        self._scope_provider = self._Provider()

    def authorize_scope(self, *, write: bool = False) -> dict[str, object]:
        return {
            "ok": True,
            "state": "authorized",
            "code": "H7_SCOPE_AUTHORIZED",
            "accessMode": "write" if write else "read",
            "scope": {
                "workspaceKey": "ws-" + "b" * 24,
                "ownerSessionKey": "sid-" + "c" * 24,
                "taskId": "new-workline",
                "taskInstanceId": "ti-" + "d" * 32,
                "contractHash": "e" * 64,
            },
        }

    def scope_status(self) -> dict[str, object]:
        return {"state": "bound", "code": "H7_SCOPE_CHANNEL_BOUND"}


def test_checkpoint_enforces_write_scope_inside_runtime() -> None:
    core = _DeniedScopeCore()
    result = turn_runtime.checkpoint_turn(
        core,  # type: ignore[arg-type]
        progress_checkpoint={"source": "assistant_visible_reply"},
    )
    assert result["available"] is False, result
    assert result["code"] == "H7_SCOPE_CHANNEL_UNBOUND", result
    assert core.calls == [True], core.calls


def test_close_enforces_write_scope_inside_runtime() -> None:
    core = _DeniedScopeCore()
    result = turn_runtime.close_turn(core)  # type: ignore[arg-type]
    assert result["available"] is False, result
    assert result["code"] == "H7_SCOPE_CHANNEL_UNBOUND", result
    assert core.calls == [True], core.calls


def test_scope_guard_projection_is_bounded() -> None:
    core = _DeniedScopeCore()
    result = turn_runtime._scope_authorization_guard(
        core,  # type: ignore[arg-type]
        phase="open",
        write=True,
        context={"private": "must-not-escape"},
    )
    assert result is not None
    assert result["scopeAuthorization"]["code"] == "H7_SCOPE_CHANNEL_UNBOUND"
    assert result["scopeBinding"]["state"] == "unbound"
    assert "private" not in result


def test_scope_guard_rejects_a_rebind_between_context_and_write_lease() -> None:
    core = _ReboundScopeCore()
    result = turn_runtime._scope_authorization_guard(
        core,  # type: ignore[arg-type]
        phase="open",
        write=True,
        context={
            "scope": {
                "workspaceKey": "ws-" + "b" * 24,
                "ownerSessionKey": "sid-" + "c" * 24,
            },
            "task": {
                "taskId": "old-workline",
                "taskInstanceId": "ti-" + "a" * 32,
                "contractHash": "f" * 64,
            },
        },
    )
    assert result is not None
    assert result["available"] is False, result
    assert result["code"] == "H7_SCOPE_REBIND_DURING_OPERATION", result
    assert result["scopeAuthorization"]["code"] == "H7_SCOPE_REBIND_DURING_OPERATION"


def test_production_turn_paths_do_not_use_ambient_scope_identity() -> None:
    for relative in (
        "runtime/brain_core.py",
        "runtime/turn_runtime.py",
        "runtime/turn_close_dispatcher.py",
    ):
        source = (ROOT / relative).read_text(encoding="utf-8")
        assert "CODEX_THREAD_ID" not in source
        assert "os.getcwd" not in source
        assert "Path.cwd" not in source
        assert 'environment["SUPER_BRAIN_LOCAL_SESSION_ID"] =' not in source


def main() -> int:
    test_checkpoint_enforces_write_scope_inside_runtime()
    test_close_enforces_write_scope_inside_runtime()
    test_scope_guard_projection_is_bounded()
    test_scope_guard_rejects_a_rebind_between_context_and_write_lease()
    test_production_turn_paths_do_not_use_ambient_scope_identity()
    print("runtime turn scope authorization regression: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
