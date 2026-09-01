"""Platform-neutral launcher for one locally injected Super Brain MCP worker.

This process is deliberately small: it preserves the stdio channel and passes
only two caller-owned facts to :mod:`brain_mcp` before that worker accepts a
single MCP request:

* the actual process cwd, which is the project's local root; and
* an explicit random ``SUPER_BRAIN_LOCAL_SESSION_ID`` supplied by the local
  embedding adapter that owns the user interaction.

The launcher never derives a session from Host/Codex identifiers, request
payloads, a saved configuration, or a task selector.  A static MCP
registration may start this launcher for health discovery, but it intentionally
remains unbound until a host capable of supplying both local facts launches it.
That is a fail-closed integration boundary, not a fallback to global state.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path


LOCAL_SESSION_ENV = "SUPER_BRAIN_LOCAL_SESSION_ID"
_SESSION_RE = re.compile(r"^sid-[a-f0-9]{16,64}$", re.IGNORECASE)
_WORKER_ENV_KEYS = (
    # Keep only process/runtime essentials.  In particular, do not relay
    # arbitrary embedding-host variables (thread ids, context snapshots, or
    # other Host metadata) into the H7 worker simply because the launcher
    # shares a process boundary with that host.
    "APPDATA",
    "COMSPEC",
    "ComSpec",
    "HOME",
    "LANG",
    "LC_ALL",
    "LOCALAPPDATA",
    "OS",
    "PATH",
    "PATHEXT",
    "PROCESSOR_ARCHITECTURE",
    "PROGRAMDATA",
    "PYTHONIOENCODING",
    "PYTHONUTF8",
    "SystemRoot",
    "SYSTEMROOT",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "WINDIR",
)


def _normalized_directory(value: str | Path) -> Path | None:
    try:
        candidate = Path(value).expanduser().resolve()
    except (OSError, RuntimeError, ValueError):
        return None
    return candidate if candidate.is_dir() else None


def _worker_arguments(package_root: Path, memory_root: str) -> list[str]:
    """Build the worker's ``sys.argv`` without accepting a scope selector.

    The launcher imports :mod:`brain_mcp` in-process so the stdio stream and
    process lifetime remain owned by one local adapter.  Consequently these
    are *worker argv* values only; the executable, ``-B`` switch, and launcher
    script path must not be inserted here because ``argparse`` would treat
    them as MCP worker options.
    """

    arguments = [
        str(package_root / "runtime" / "brain_mcp.py"),
        "--package-root",
        str(package_root),
        "--local-launcher",
    ]
    if memory_root:
        arguments.extend(["--memory-root", memory_root])
    return arguments


def _worker_environment(session: str, *, source: dict[str, str] | None = None) -> dict[str, str]:
    """Return the bounded environment inherited by the H7 MCP worker.

    ``SUPER_BRAIN_LOCAL_SESSION_ID`` is the sole scope-bearing input.  The
    other values are ordinary interpreter/OS requirements; all host-specific
    identifiers, context, and metadata are deliberately omitted.
    """

    inherited = os.environ if source is None else source
    environment = {
        name: value
        for name in _WORKER_ENV_KEYS
        if isinstance((value := inherited.get(name)), str) and value
    }
    if _SESSION_RE.fullmatch(session):
        environment[LOCAL_SESSION_ENV] = session.lower()
    return environment


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--memory-root", default="")
    args = parser.parse_args()

    package_root = _normalized_directory(args.package_root)
    if package_root is None or not (package_root / "runtime" / "brain_mcp.py").is_file():
        sys.stderr.write("H7_LOCAL_MCP_LAUNCHER_PACKAGE_INVALID\n")
        return 64
    workspace_root = _normalized_directory(Path.cwd())
    if workspace_root is None:
        sys.stderr.write("H7_LOCAL_MCP_LAUNCHER_WORKSPACE_INVALID\n")
        return 64

    # Preserve one valid process-local sid only for the immediate worker
    # bootstrap. It never appears in argv; brain_mcp consumes and removes it
    # before it serves MCP. The worker derives workspace only from this
    # inherited process's real cwd.
    session = str(os.environ.get(LOCAL_SESSION_ENV, "")).strip()
    child_environment = _worker_environment(session)
    # Run the worker in this same process. This preserves the caller's stdio,
    # avoids a child that could outlive a terminated launcher on Windows, and
    # keeps the sid out of argv entirely.
    try:
        runtime_dir = package_root / "runtime"
        sys.path.insert(0, str(runtime_dir))
        import brain_mcp

        sys.argv = _worker_arguments(package_root, str(args.memory_root or ""))
        os.environ.clear()
        os.environ.update(child_environment)
        return int(brain_mcp.main())
    except (ImportError, OSError, RuntimeError, ValueError):
        sys.stderr.write("H7_LOCAL_MCP_LAUNCHER_START_FAILED\n")
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
