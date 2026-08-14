from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def invoke(script: str, state_root: Path) -> None:
    environment = os.environ.copy()
    environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
    request = json.dumps({"session_id": "stale-host", "prompt": "replace the old task"})
    completed = subprocess.run(
        [sys.executable, "-B", str(ROOT / "runtime" / script), "--package-root", str(ROOT)],
        input=request,
        text=True,
        encoding="utf-8",
        errors="strict",
        capture_output=True,
        check=False,
        env=environment,
    )
    assert completed.returncode == 0, completed.stderr
    assert "replace the old task" not in completed.stdout
    if completed.stdout.strip():
        value = json.loads(completed.stdout)
        if script.startswith("codex_prompt_"):
            assert value.get("hookSpecificOutput", {}).get("additionalContext", "") == ""
        else:
            assert value == {}
    assert not state_root.exists(), (script, list(state_root.rglob("*")) if state_root.exists() else [])


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="super-brain-retired-p7-") as directory:
        state_root = Path(directory) / "state"
        for script in (
            "codex_prompt_hook.py",
            "codex_prompt_hook_launcher.py",
            "codex_prompt_hook_dispatcher.py",
            "codex_stop_hook.py",
            "codex_stop_hook_dispatcher.py",
        ):
            invoke(script, state_root)
    print("LEGACY_PROMPT_HOOK_RETIREMENT_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
