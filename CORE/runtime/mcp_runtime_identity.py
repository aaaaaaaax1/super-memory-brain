from __future__ import annotations

"""One identity compiler for the long-lived Super Brain MCP transport.

The served MCP is a Python import graph, not a hand-maintained shortlist of
files.  Both Python and PowerShell therefore use this module to hash the
manifest, the reachable local ``runtime`` modules from the MCP entrypoint, and
the small set of declared non-Python behavior assets.  Any source update that
can change a resident MCP's behavior changes its identity and requires a
verified rebind instead of silently serving mixed code.
"""

import argparse
import ast
import hashlib
import json
import re
from pathlib import Path
from typing import Any


ROOTS_KEY = "mcpRuntimeIdentityRoots"
ASSETS_KEY = "mcpRuntimeIdentityAssets"
MAX_PATHS = 64
_DRIVE_PATH = re.compile(r"^[A-Za-z]:")
_IDENTITY_CACHE: dict[str, tuple[tuple[str, ...], tuple[tuple[str, int, int], ...], str]] = {}
_MAX_IDENTITY_CACHE_ENTRIES = 8


def _path_stamps(
    package: Path, paths: tuple[str, ...]
) -> tuple[tuple[str, int, int], ...] | None:
    """Read one filesystem stamp per identity path."""

    stamps: list[tuple[str, int, int]] = []
    for relative in paths:
        try:
            stat = (package / relative).stat()
        except OSError:
            return None
        stamps.append((relative, stat.st_mtime_ns, stat.st_size))
    return tuple(stamps)


def _identity_cache_get(
    key: str,
) -> tuple[tuple[str, ...], tuple[tuple[str, int, int], ...], str] | None:
    value = _IDENTITY_CACHE.get(key)
    if value is not None:
        _IDENTITY_CACHE.pop(key, None)
        _IDENTITY_CACHE[key] = value
    return value


def _identity_cache_put(
    key: str,
    value: tuple[tuple[str, ...], tuple[tuple[str, int, int], ...], str],
) -> None:
    _IDENTITY_CACHE.pop(key, None)
    _IDENTITY_CACHE[key] = value
    while len(_IDENTITY_CACHE) > _MAX_IDENTITY_CACHE_ENTRIES:
        _IDENTITY_CACHE.pop(next(iter(_IDENTITY_CACHE)))


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None


def _normal_relative_path(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    normalized = value.strip().replace("\\", "/")
    parts = normalized.split("/")
    if (
        not normalized
        or "\x00" in normalized
        or normalized.startswith("/")
        or _DRIVE_PATH.match(normalized)
        or any(part in {"", ".", ".."} for part in parts)
    ):
        return ""
    return normalized


def _manifest_paths(manifest: Any, key: str) -> tuple[str, ...]:
    raw = manifest.get(key) if isinstance(manifest, dict) else None
    if not isinstance(raw, list) or not raw or len(raw) > MAX_PATHS:
        return ()
    result: list[str] = []
    seen: set[str] = set()
    for item in raw:
        relative = _normal_relative_path(item)
        if not relative or relative in seen:
            return ()
        seen.add(relative)
        result.append(relative)
    return tuple(result)


def _local_module_candidates(current: str, node: ast.AST) -> tuple[str, ...]:
    """Map a Python import node to same-package ``runtime`` module candidates."""

    current_path = Path(current)
    directory = current_path.parent
    candidates: list[str] = []
    if isinstance(node, ast.Import):
        for alias in node.names:
            candidates.append((directory / (alias.name.replace(".", "/") + ".py")).as_posix())
    elif isinstance(node, ast.ImportFrom):
        base = directory
        if node.level:
            for _ in range(max(0, node.level - 1)):
                base = base.parent
            module = node.module.replace(".", "/") if node.module else ""
            if module:
                candidates.append((base / (module + ".py")).as_posix())
            else:
                for alias in node.names:
                    candidates.append((base / (alias.name.replace(".", "/") + ".py")).as_posix())
        elif node.module:
            candidates.append((directory / (node.module.replace(".", "/") + ".py")).as_posix())
    return tuple(candidates)


def runtime_dependency_paths(package_root: str | Path, manifest: Any | None = None) -> tuple[str, ...]:
    """Return a sorted, verified local import closure plus declared assets."""

    package = Path(package_root).expanduser().resolve()
    source_manifest = manifest if isinstance(manifest, dict) else _read_json(package / "manifest.json")
    roots = _manifest_paths(source_manifest, ROOTS_KEY)
    assets = _manifest_paths(source_manifest, ASSETS_KEY)
    if not roots or not assets:
        return ()
    if any(not path.startswith("runtime/") or not path.endswith(".py") for path in roots):
        return ()
    runtime_paths: set[str] = set()
    pending = list(roots)
    while pending:
        relative = pending.pop()
        if relative in runtime_paths:
            continue
        path = package / relative
        if not path.is_file():
            return ()
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        except (OSError, UnicodeError, SyntaxError):
            return ()
        runtime_paths.add(relative)
        for node in ast.walk(tree):
            if not isinstance(node, (ast.Import, ast.ImportFrom)):
                continue
            for candidate in _local_module_candidates(relative, node):
                normalized = _normal_relative_path(candidate)
                if not normalized or not normalized.startswith("runtime/") or not normalized.endswith(".py"):
                    continue
                if (package / normalized).is_file() and normalized not in runtime_paths:
                    pending.append(normalized)
    combined = {"manifest.json", *runtime_paths, *assets}
    if len(combined) > MAX_PATHS:
        return ()
    for relative in combined:
        if not (package / relative).is_file():
            return ()
    return tuple(sorted(combined))


def runtime_identity(
    package_root: str | Path,
    manifest: Any | None = None,
) -> str:
    """Hash the one complete, local behavior surface of the resident MCP."""

    package = Path(package_root).expanduser().resolve()
    cache_key = str(package).lower()
    if manifest is None:
        cached = _identity_cache_get(cache_key)
        if cached is not None:
            cached_paths, cached_stamp, cached_identity = cached
            current_stamp = _path_stamps(package, cached_paths)
            if current_stamp == cached_stamp:
                return cached_identity
    source_manifest = manifest if isinstance(manifest, dict) else _read_json(package / "manifest.json")
    version = str((source_manifest or {}).get("version", "")).strip() if isinstance(source_manifest, dict) else ""
    paths = runtime_dependency_paths(package, source_manifest)
    if not version or not paths:
        return ""
    stamp = _path_stamps(package, paths)
    if stamp is None:
        return ""
    # Runtime identity is queried on every MCP request.  Cache only while all
    # source stamps match; a changed dependency or a new import (which changes
    # its importer) rebuilds the closure before any request is considered
    # current.
    parts = ["version=" + version]
    try:
        for relative in paths:
            parts.append(relative + "=" + hashlib.sha256((package / relative).read_bytes()).hexdigest())
    except OSError:
        return ""
    identity = hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()
    if manifest is None:
        _identity_cache_put(cache_key, (paths, stamp, identity))
    return identity


def main() -> int:
    parser = argparse.ArgumentParser(description="Compile Super Brain MCP runtime identity")
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--paths-json", action="store_true")
    args = parser.parse_args()
    package = Path(args.package_root).expanduser().resolve()
    paths = runtime_dependency_paths(package)
    identity = runtime_identity(package)
    if not identity:
        return 1
    if args.paths_json:
        print(json.dumps({"identity": identity, "paths": list(paths)}, ensure_ascii=False, separators=(",", ":")))
    else:
        print(identity)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
