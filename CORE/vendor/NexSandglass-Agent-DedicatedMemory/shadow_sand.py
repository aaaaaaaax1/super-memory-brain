"""
NexSandglass — 影子沙 (Shadow Sand)
=====================================
轻量SQLite投影层。不碰沙子原文，只存索引元数据。
投石问路之前先查影子沙——脱口而出级速度。
零依赖：sqlite3是Python stdlib。
"""
import sqlite3, os, re
from collections import defaultdict

from sandglass_paths import _NB

_SHADOW_DB = os.path.join(_NB, "shadow_sand.db")


def set_shadow_path(path: str):
    """重定向影子沙路径——基准测试用。"""
    global _SHADOW_DB, _conn
    _SHADOW_DB = path

_SCHEMA = """
CREATE TABLE IF NOT EXISTS trust (
    line_num    INTEGER PRIMARY KEY,  -- 对应sandglass.txt行号
    score       REAL DEFAULT 0.5,     -- 信任分 [0,1]
    helpful     INTEGER DEFAULT 0,    -- 好评次数
    unhelpful   INTEGER DEFAULT 0,    -- 差评次数
    retrievals  INTEGER DEFAULT 0,    -- 被检索次数
    updated_at  TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS entities (
    name        TEXT NOT NULL,
    line_nums   TEXT DEFAULT '',      -- 逗号分隔的行号列表
    created_at  TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_entities_name ON entities(name);

CREATE TABLE IF NOT EXISTS fact_tags (
    line_num    INTEGER PRIMARY KEY,
    category    TEXT DEFAULT 'general',
    tags        TEXT DEFAULT '',
    created_at  TEXT DEFAULT (datetime('now'))
);
"""

_ENTITY_RE = re.compile(
    r'\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)\b|'   # 英文大写多词
    r'"([^"]+)"|'                                   # 双引号
    r"'([^']+)'|"                                   # 单引号
    r'([\u4e00-\u9fff]{2,4})'                     # 中文2-4字（人名/术语）
)

_conn = None

_commit_pending = 0

def _get_conn():
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(_SHADOW_DB, check_same_thread=False)
        _conn.executescript(_SCHEMA)
        _conn.commit()
    return _conn

def _maybe_commit():
    global _commit_pending
    _commit_pending += 1
    if _commit_pending >= 3:
        _get_conn().commit()
        _commit_pending = 0


# ═══════════════════ 查询（脱口而出层） ═══════════════════

def shadow_search(query: str, limit: int = 10) -> list:
    """影子沙优先搜索。返回 [(行号, 信任分), ...]"""
    db = _get_conn()
    words = [w for w in re.findall(r'\w+', query.lower()) if len(w) > 1]
    # 方法1: 实体名匹配（最快）
    results = []
    for w in words:
        rows = db.execute(
            "SELECT line_nums FROM entities WHERE name LIKE ? LIMIT 1",
            (f"%{w}%",)
        ).fetchall()
        for row in rows:
            for ln in row[0].split(","):
                if ln.strip().isdigit():
                    results.append(int(ln.strip()))

    # 方法2: 标签匹配
    tag_rows = db.execute(
        "SELECT line_num FROM fact_tags WHERE tags LIKE ? OR category LIKE ? LIMIT ?",
        (f"%{query}%", f"%{query}%", limit)
    ).fetchall()
    for row in tag_rows:
        results.append(row[0])

    # 去重 + 信任加权排序
    if results:
        unique = list(set(results))
        scored = []
        for ln in unique[:limit * 3]:
            tr = db.execute(
                "SELECT score FROM trust WHERE line_num = ?", (ln,)
            ).fetchone()
            score = tr[0] if tr else 0.5
            scored.append((score, ln))
        scored.sort(key=lambda x: x[0], reverse=True)
        return scored[:limit]

    return []


def shadow_boost(candidate_lines: set, limit: int = 10) -> list:
    """对投石问路的候选行号做影子加权排序。
    返回 [(行号, 信任分), ...]"""
    if not candidate_lines:
        return []
    db = _get_conn()
    placeholders = ",".join("?" * len(candidate_lines))
    rows = db.execute(
        f"SELECT line_num, score FROM trust WHERE line_num IN ({placeholders})",
        list(candidate_lines)
    ).fetchall()
    trust_map = {r[0]: r[1] for r in rows}
    scored = [(trust_map.get(ln, 0.5), ln) for ln in candidate_lines]
    scored.sort(key=lambda x: x[0], reverse=True)
    return scored[:limit]


# ═══════════════════ 写入（落沙后同步） ═══════════════════

def shadow_index(text: str, category: str = "general", tags: str = "", line_num: int = 0) -> None:
    try:
        from sandglass_think import scene_mode
        if scene_mode() == 'exam': category = 'exam_' + category
    except: pass
    """落沙后同步——调用方传入实际行号，避免COUNT(*)偏移。"""
    db = _get_conn()
    # 行号由调用方传入（sandglass_log 写入后传实际行号）
    if line_num <= 0:
        line_num = db.execute("SELECT COUNT(*) FROM trust").fetchone()[0] + 1

    # 提取实体
    for m in _ENTITY_RE.finditer(text):
        name = m.group(1) or m.group(2) or m.group(3) or ""
        name = name.strip()
        if name and len(name) > 1:
            row = db.execute(
                "SELECT line_nums FROM entities WHERE name = ?", (name,)
            ).fetchone()
            if row:
                nums = set(row[0].split(",")) | {str(line_num)}
                db.execute(
                    "UPDATE entities SET line_nums = ? WHERE name = ?",
                    (",".join(sorted(nums, key=int)), name)
                )
            else:
                db.execute(
                    "INSERT INTO entities (name, line_nums) VALUES (?, ?)",
                    (name, str(line_num))
                )

    # 写入信任记录
    db.execute(
        "INSERT OR IGNORE INTO trust (line_num, score) VALUES (?, 0.5)",
        (line_num,)
    )

    # 写入标签
    if category != "general" or tags:
        db.execute(
            "INSERT OR REPLACE INTO fact_tags (line_num, category, tags) VALUES (?, ?, ?)",
            (line_num, category, tags)
        )

    _maybe_commit()


def _normalize_line_map(line_map: dict | None) -> dict:
    if line_map is None:
        line_map = {}
    normalized = {}
    for old_line, new_line in line_map.items():
        try:
            old_value = int(old_line)
            new_value = int(new_line)
        except (TypeError, ValueError):
            continue
        if old_value > 0 and new_value > 0:
            normalized[old_value] = new_value
    return normalized


def _map_line_numbers(raw_line_nums: str, line_map: dict) -> list[int]:
    mapped = set()
    for raw_line in str(raw_line_nums or "").split(","):
        try:
            old_line = int(raw_line.strip())
        except (TypeError, ValueError):
            continue
        new_line = line_map.get(old_line)
        if new_line:
            mapped.add(new_line)
    return sorted(mapped)


def rebuild_line_index(line_map: dict | None = None) -> dict:
    """重写行号投影，保留信任、标签、实体和织线数据。"""
    db = _get_conn()
    normalized = _normalize_line_map(line_map)
    if line_map is None:
        try:
            with open(os.path.join(_NB, "sandglass.txt"), "r", encoding="utf-8") as handle:
                line_count = sum(1 for _ in handle)
        except OSError:
            line_count = 0
        normalized = {line: line for line in range(1, line_count + 1)}

    try:
        db.commit()
        trust_rows = db.execute(
            "SELECT line_num, score, helpful, unhelpful, retrievals, updated_at FROM trust"
        ).fetchall()
        entity_rows = db.execute(
            "SELECT name, line_nums, created_at FROM entities"
        ).fetchall()
        tag_rows = db.execute(
            "SELECT line_num, category, tags, created_at FROM fact_tags"
        ).fetchall()
        graph_exists = db.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='wthread_triples'"
        ).fetchone() is not None
        graph_rows = []
        if graph_exists:
            graph_rows = db.execute(
                "SELECT id, source_line FROM wthread_triples"
            ).fetchall()

        db.execute("BEGIN")
        db.execute("DELETE FROM trust")
        db.execute("DELETE FROM entities")
        db.execute("DELETE FROM fact_tags")

        trust_count = 0
        for row in trust_rows:
            new_line = normalized.get(int(row[0]))
            if not new_line:
                continue
            db.execute(
                "INSERT INTO trust (line_num, score, helpful, unhelpful, retrievals, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                (new_line, row[1], row[2], row[3], row[4], row[5])
            )
            trust_count += 1

        entity_count = 0
        for row in entity_rows:
            mapped_lines = _map_line_numbers(row[1], normalized)
            if not mapped_lines:
                continue
            db.execute(
                "INSERT INTO entities (name, line_nums, created_at) VALUES (?, ?, ?)",
                (row[0], ",".join(str(line) for line in mapped_lines), row[2])
            )
            entity_count += 1

        tag_count = 0
        for row in tag_rows:
            new_line = normalized.get(int(row[0]))
            if not new_line:
                continue
            db.execute(
                "INSERT INTO fact_tags (line_num, category, tags, created_at) VALUES (?, ?, ?, ?)",
                (new_line, row[1], row[2], row[3])
            )
            tag_count += 1

        graph_updated = 0
        graph_removed = 0
        if graph_exists:
            for graph_id, source_line in graph_rows:
                if not source_line:
                    continue
                new_line = normalized.get(int(source_line))
                if not new_line:
                    db.execute("DELETE FROM wthread_triples WHERE id = ?", (graph_id,))
                    graph_removed += 1
                elif new_line != source_line:
                    db.execute(
                        "UPDATE wthread_triples SET source_line = ? WHERE id = ?",
                        (new_line, graph_id)
                    )
                    graph_updated += 1

        db.commit()
        global _commit_pending
        _commit_pending = 0
        return {
            "ok": True,
            "mappedLines": len(normalized),
            "trustRows": trust_count,
            "entityRows": entity_count,
            "tagRows": tag_count,
            "graphUpdated": graph_updated,
            "graphRemoved": graph_removed,
        }
    except Exception as exc:
        try:
            db.rollback()
        except Exception:
            pass
        return {"ok": False, "error": str(exc)}


# ═══════════════════ 反馈 ═══════════════════

def shadow_feedback(line_num: int, helpful: bool) -> dict:
    """信任评分反馈。"""
    db = _get_conn()
    row = db.execute(
        "SELECT score, helpful, unhelpful FROM trust WHERE line_num = ?",
        (line_num,)
    ).fetchone()
    if not row:
        db.execute("INSERT INTO trust (line_num, score) VALUES (?, 0.5)", (line_num,))
        old_score = 0.5
    else:
        old_score = row[0]

    delta = 0.05 if helpful else -0.10
    new_score = max(0.0, min(1.0, old_score + delta))
    col = "helpful" if helpful else "unhelpful"

    db.execute(
        f"UPDATE trust SET score = ?, {col} = {col} + 1, updated_at = datetime('now') WHERE line_num = ?",
        (new_score, line_num)
    )
    _maybe_commit()
    return {"line_num": line_num, "old_trust": old_score, "new_trust": new_score}


def shadow_retrieval_bump(line_nums: list) -> None:
    """标记检索——增加retrievals计数。"""
    if not line_nums:
        return
    db = _get_conn()
    placeholders = ",".join("?" * len(line_nums))
    db.execute(
        f"UPDATE trust SET retrievals = retrievals + 1 WHERE line_num IN ({placeholders})",
        line_nums
    )
    _maybe_commit()
