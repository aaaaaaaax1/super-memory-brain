"""Portable Super Brain CORE layout resolution.

The shareable runtime lives in ``CORE`` while machine-private state is a
sibling of that directory. Layout entries are resolved relative to the layout
file's directory, never the process working directory.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


RUNTIME_LAYOUT_SCHEMA = "super-brain.runtime-layout.v1"


def package_root(value: str | Path) -> Path:
    return Path(value).expanduser().resolve()


def workspace_root(value: str | Path) -> Path:
    """Return the outer workspace for the established ``CORE`` topology."""

    root = package_root(value)
    return root.parent if root.name.casefold() == "core" else root


def _read_layout(root: Path) -> dict[str, Any]:
    try:
        layout = json.loads((root / "runtime-layout.json").read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    return layout if isinstance(layout, dict) and layout.get("schema") == RUNTIME_LAYOUT_SCHEMA else {}


def resolve_layout_path(value: str | Path, raw_path: Any) -> Path | None:
    """Resolve a layout entry under its workspace boundary.

    Relative values are anchored to ``CORE``. Absolute values remain valid only
    when they stay inside the same outer workspace, preventing an installed
    package from silently selecting an unrelated state store.
    """

    root = package_root(value)
    raw = str(raw_path or "").strip()
    if not raw:
        return None
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = root / candidate
    try:
        resolved = candidate.resolve()
        resolved.relative_to(workspace_root(root))
    except (OSError, ValueError):
        return None
    return resolved


def configured_state_root(value: str | Path) -> Path | None:
    root = package_root(value)
    return resolve_layout_path(root, _read_layout(root).get("stateRoot"))


def state_root(value: str | Path) -> Path:
    root = package_root(value)
    configured = configured_state_root(root)
    if configured is not None:
        return configured
    workspace = workspace_root(root)
    return workspace / "private-state" if workspace != root else root / "memory"


def archive_root(value: str | Path) -> Path:
    root = package_root(value)
    configured = resolve_layout_path(root, _read_layout(root).get("archiveRoot"))
    if configured is not None:
        return configured
    workspace = workspace_root(root)
    return workspace / "private-archive" if workspace != root else root / "archives"
