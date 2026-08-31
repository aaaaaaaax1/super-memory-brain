"""Regression checks for the retired Stop-hook compatibility shim.

H7 ``brain_turn`` owns lifecycle continuation now.  The old Stop hook remains
only as a fail-open, no-op compatibility entry so an installed legacy hook
cannot resume work or read host state.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STOP_HOOK = ROOT / "runtime" / "codex_stop_hook.py"
DISPATCHER = ROOT / "runtime" / "codex_stop_hook_dispatcher.py"


def _run(path: Path, *arguments: str, stdin: str = "") -> dict[str, object]:
    completed = subprocess.run(
        [sys.executable, str(path), *arguments],
        input=stdin,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    )
    value = json.loads(completed.stdout)
    assert isinstance(value, dict)
    return value


def test_retired_stop_hook_is_fail_open_noop() -> None:
    assert _run(STOP_HOOK, stdin=json.dumps({"legacy_host_payload": "must not be read"})) == {}


def test_retired_dispatcher_declares_h7_replacement() -> None:
    assert _run(DISPATCHER, "--describe") == {
        "ok": True,
        "state": "retired",
        "replacement": "H7 brain_turn",
    }


def test_retired_dispatcher_is_fail_open_noop() -> None:
    assert _run(DISPATCHER, stdin=json.dumps({"legacy_host_payload": "must not be read"})) == {}


def main() -> None:
    tests = [
        test_retired_stop_hook_is_fail_open_noop,
        test_retired_dispatcher_declares_h7_replacement,
        test_retired_dispatcher_is_fail_open_noop,
    ]
    for test in tests:
        test()
    print("RUNTIME_STOP_HOOK_REGRESSION_OK")


if __name__ == "__main__":
    main()
