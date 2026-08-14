"""
NexSandglass V2.1.1 — 冷热分层存储
热沙(sandglass.txt): 最近30天完整对话
冷沙(archive/): 超过30天，按月分文件，AI低价值丢弃
"""
import os, re, shutil
from sandglass_paths import _NB
from datetime import datetime, timedelta

_VAULT = _NB
_ARCHIVE = os.path.join(_VAULT, "archive")
_HOT_DAYS = 30


def archive_path(month: str) -> str:
    """冷沙文件路径。month='2026-06'。"""
    os.makedirs(_ARCHIVE, exist_ok=True)
    return os.path.join(_ARCHIVE, f"sandglass_{month}.txt")


def parse_ts(line: str) -> str:
    """从沙漏行提取时间戳。"""
    return line[:19] if len(line) >= 19 else ""


def is_old(ts: str, cutoff_days: int = _HOT_DAYS) -> bool:
    """时间戳是否超过cutoff天。"""
    try:
        dt = datetime.strptime(ts[:10], "%Y-%m-%d")
        return (datetime.now() - dt).days > cutoff_days
    except Exception:
        return False


def cold_migration(dry_run: bool = False) -> dict:
    """Return a migration plan without rewriting private history.

    Hash-verified rewrites belong to the package maintenance transaction. A
    runtime pulse must never silently archive or discard a user's memory.
    """
    hot_file = os.path.join(_VAULT, "sandglass.txt")
    if not os.path.exists(hot_file):
        return {"moved": 0, "dropped": 0, "kept": 0}

    planned = 0
    kept = 0

    with open(hot_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            ts = parse_ts(line)
            if not is_old(ts):
                kept += 1
                continue
            planned += 1

    return {
        "moved": 0,
        "dropped": 0,
        "kept": kept,
        "planned": planned,
        "dryRun": True,
        "requiresConfirmation": planned > 0,
        "reason": "cold_migration_preview_only",
    }


def rebuild_indexes(line_map: dict | None = None) -> dict:
    """重建物理删改后的 Sandglass、SQLite FTS 和 Shadow Sand 行号索引。"""
    result = {"ok": True, "lineMapEntries": len(line_map or {})}

    try:
        from sandglass_vault import rebuild_index
        from sandglass_paths import _SANDGLASS, _SANDGLASS_IDX
        token_count = rebuild_index()
        result["sandglassIndex"] = {"ok": token_count >= 0 and (os.path.exists(_SANDGLASS_IDX) or not os.path.exists(_SANDGLASS)), "tokens": token_count}
    except Exception as exc:
        result["sandglassIndex"] = {"ok": False, "error": str(exc)}

    try:
        from sandglass_sqlite import sync_all
        row_count = sync_all()
        result["sqliteFts"] = {"ok": row_count >= 0, "rows": row_count}
    except Exception as exc:
        result["sqliteFts"] = {"ok": False, "error": str(exc)}

    try:
        from shadow_sand import rebuild_line_index
        result["shadowSand"] = rebuild_line_index(line_map)
    except Exception as exc:
        result["shadowSand"] = {"ok": False, "error": str(exc)}

    result["ok"] = all(
        bool(result.get(name, {}).get("ok"))
        for name in ("sandglassIndex", "sqliteFts", "shadowSand")
    )
    return result


def search_archive(query: str, limit: int = 10) -> list:
    """搜索冷沙。返回 [(line_no, ts, text), ...]"""
    if not os.path.exists(_ARCHIVE):
        return []

    results = []
    for fname in sorted(os.listdir(_ARCHIVE)):
        if not fname.startswith("sandglass_"):
            continue
        fpath = os.path.join(_ARCHIVE, fname)
        with open(fpath, "r", encoding="utf-8") as f:
            for i, line in enumerate(f):
                if query.lower() in line.lower():
                    parts = line.split(" | ", 2)
                    ts = parts[0] if len(parts) > 0 else ""
                    text = parts[2] if len(parts) > 2 else ""
                    results.append((i + 1, ts, text[:300]))
        if len(results) >= limit:
            break

    return results[:limit]


def archive_stats() -> dict:
    """冷沙统计。"""
    if not os.path.exists(_ARCHIVE):
        return {"files": 0, "total_lines": 0}
    files = [f for f in os.listdir(_ARCHIVE) if f.startswith("sandglass_")]
    total = 0
    for f in files:
        with open(os.path.join(_ARCHIVE, f), "r", encoding="utf-8") as fh:
            total += sum(1 for _ in fh)
    return {"files": len(files), "total_lines": total}
