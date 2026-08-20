from __future__ import annotations

import hashlib
import os
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from brain_core import BrainCore


LOCAL_SESSION_ENV = "SUPER_BRAIN_LOCAL_SESSION_ID"
RETIRED_HOST_SESSION_ENV = "CODEX_THREAD_ID"


def session_key(value: str) -> str:
    return "sid-" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]


def test_local_session_is_the_only_runtime_identity_source() -> None:
    previous = {name: os.environ.get(name) for name in (LOCAL_SESSION_ENV, RETIRED_HOST_SESSION_ENV)}
    try:
        os.environ[LOCAL_SESSION_ENV] = "local-session-regression"
        os.environ[RETIRED_HOST_SESSION_ENV] = "retired-host-session-must-not-win"
        with tempfile.TemporaryDirectory(prefix="super-brain-local-session-") as directory:
            memory_root = Path(directory) / "shared"
            memory_root.mkdir()
            core = BrainCore(ROOT, memory_root)
            expected = session_key("local-session-regression")
            assert core._current_session_key() == expected
            assert core._context_session_key() == expected

            os.environ.pop(LOCAL_SESSION_ENV)
            assert core._current_session_key() == ""
            assert core._context_session_key() == ""
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def test_brain_core_has_no_host_thread_identity_fallback() -> None:
    source = (ROOT / "runtime" / "brain_core.py").read_text(encoding="utf-8")
    assert RETIRED_HOST_SESSION_ENV not in source
    assert "BRAIN_CONTEXT_LOCAL_SESSION_MISSING" in source


def main() -> int:
    test_local_session_is_the_only_runtime_identity_source()
    test_brain_core_has_no_host_thread_identity_fallback()
    print("local session identity regression: 2 passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
