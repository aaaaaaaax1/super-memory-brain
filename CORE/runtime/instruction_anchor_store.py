"""Narrow, SQLite-compatible instruction-anchor storage for the prompt hot path.

The full BrainControl module owns migrations, task state, UI projections, and
governance. Prompt-time continuation only needs append-only instruction anchors,
so this module deliberately keeps that one operation small while writing the
same schema consumed by BrainControl's cold-path APIs.
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Mapping, Sequence


INSTRUCTION_ANCHOR_SCHEMA = "super-brain.instruction-anchor.v1"
INSTRUCTION_ANCHOR_MAX_CHARS = 480
INSTRUCTION_ANCHOR_MAX_SOURCE_CHARS = 160
SENSITIVE_VALUE_RE = re.compile(r"(?i)\b(?:bearer\s+[a-z0-9._~+/-]+=*|sk-[a-z0-9_-]{8,})\b")


class InstructionAnchorStoreError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _sha256(value: Any) -> str:
    return hashlib.sha256(_canonical_json(value).encode("utf-8")).hexdigest()


def _require_string(value: Any, field: str, maximum: int = 512) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InstructionAnchorStoreError("BRAIN_CONTROL_FIELD_REQUIRED", f"{field} is required")
    normalized = value.strip()
    if len(normalized) > maximum:
        raise InstructionAnchorStoreError("BRAIN_CONTROL_FIELD_TOO_LONG", f"{field} exceeds {maximum} characters")
    return normalized


def _optional_string(value: Any, field: str, maximum: int = 512) -> str:
    if value in (None, ""):
        return ""
    return _require_string(value, field, maximum)


def _redact_instruction(value: Any) -> str:
    text = _require_string(value, "instruction", INSTRUCTION_ANCHOR_MAX_CHARS)
    text = SENSITIVE_VALUE_RE.sub("[REDACTED]", text)
    return re.sub(
        r"(?i)\b(api[_ -]?key|password|passwd|token|secret|credential|cookie)\s*[:=]\s*[^\s,;]+",
        r"\1=[REDACTED]",
        text,
    )


def _normalize_classification(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        return {}

    def text(field: str, maximum: int) -> str:
        raw = value.get(field, "")
        return _optional_string(raw, f"classification.{field}", maximum) if isinstance(raw, str) else ""

    def text_list(field: str, maximum_items: int, maximum_chars: int) -> list[str]:
        raw = value.get(field, [])
        if isinstance(raw, str) or not isinstance(raw, Sequence):
            return []
        result: list[str] = []
        for item in raw:
            if not isinstance(item, str):
                continue
            normalized = _optional_string(item, f"classification.{field}", maximum_chars)
            if normalized and normalized not in result:
                result.append(normalized)
            if len(result) >= maximum_items:
                break
        return result

    normalized = {
        "mode": text("mode", 48),
        "topicAffinity": text("topicAffinity", 96),
        "targetLineId": text("targetLineId", 160),
        "targetLineLabel": text("targetLineLabel", 160),
        "confidence": text("confidence", 24),
        "matchedKeys": text_list("matchedKeys", 12, 96),
        "candidateLineIds": text_list("candidateLineIds", 8, 160),
        "recommendedInstructionMode": text("recommendedInstructionMode", 48),
        "reason": text("reason", 240),
        "needsClarification": bool(value.get("needsClarification", False)),
    }
    # List fields are part of the public compact schema. Keep empty lists so
    # PowerShell consumers can distinguish "no candidates" from a missing
    # projection field after a prompt-time anchor round trip.
    return {
        key: item
        for key, item in normalized.items()
        if key in {"matchedKeys", "candidateLineIds", "needsClarification"} or item not in ("", [])
    }


def _normalize_signals(value: Any) -> dict[str, bool]:
    if not isinstance(value, Mapping):
        return {}
    return {
        key: bool(value.get(key, False))
        for key in ("deferredMergeRequested", "explicitReplacementRequested", "canonicalPlanSourceRequired")
        if bool(value.get(key, False))
    }


def _anchor_from_row(row: sqlite3.Row) -> dict[str, Any]:
    def read_object(column: str) -> dict[str, Any]:
        try:
            value = json.loads(str(row[column]))
        except (KeyError, TypeError, json.JSONDecodeError):
            return {}
        return dict(value) if isinstance(value, Mapping) else {}

    return {
        "schema": INSTRUCTION_ANCHOR_SCHEMA,
        "anchorId": str(row["anchor_id"]),
        "globalSequence": int(row["global_sequence"]),
        "sequence": int(row["task_sequence"]),
        "taskId": str(row["task_id"]),
        "workspaceKey": str(row["workspace_key"]),
        "ownerSessionKey": str(row["owner_session_key"]),
        "instruction": str(row["instruction_text"]),
        "instructionHash": str(row["instruction_hash"]),
        "contentHash": str(row["content_hash"]),
        "classification": read_object("classification_json"),
        "signals": read_object("signals_json"),
        "source": str(row["source"]),
        "createdAt": str(row["created_at"]),
        "rawPromptStored": False,
    }


def _anchor_is_bound(anchor: Mapping[str, Any], bound_anchor: Any) -> bool:
    if not isinstance(bound_anchor, Mapping):
        return False
    return (
        str(bound_anchor.get("anchorId", "")) == str(anchor.get("anchorId", ""))
        and str(bound_anchor.get("contentHash", "")) == str(anchor.get("contentHash", ""))
        and int(bound_anchor.get("globalSequence", -1)) == int(anchor.get("globalSequence", -2))
    )


class InstructionAnchorStore:
    """Append-only anchor writer compatible with ``BrainControl`` schema v14."""

    def __init__(self, state_root: str | Path) -> None:
        self.workspace = Path(state_root).expanduser().resolve() / "workspace"
        self.db_path = self.workspace / "brain-state.sqlite3"

    @staticmethod
    def _initialize(connection: sqlite3.Connection) -> None:
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS instruction_anchors (
              global_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
              anchor_id TEXT NOT NULL UNIQUE,
              workspace_key TEXT NOT NULL,
              owner_session_key TEXT NOT NULL,
              task_id TEXT NOT NULL,
              task_sequence INTEGER NOT NULL,
              instruction_text TEXT NOT NULL,
              instruction_hash TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              classification_json TEXT NOT NULL,
              signals_json TEXT NOT NULL,
              source TEXT NOT NULL,
              created_at TEXT NOT NULL,
              raw_prompt_stored INTEGER NOT NULL CHECK(raw_prompt_stored IN (0, 1)),
              UNIQUE(workspace_key, owner_session_key, task_id, task_sequence)
            );
            CREATE INDEX IF NOT EXISTS idx_instruction_anchors_scope_latest
              ON instruction_anchors(workspace_key, owner_session_key, task_id, global_sequence DESC);
            CREATE INDEX IF NOT EXISTS idx_instruction_anchors_session_latest
              ON instruction_anchors(workspace_key, owner_session_key, global_sequence DESC);
            CREATE TRIGGER IF NOT EXISTS instruction_anchors_no_update
              BEFORE UPDATE ON instruction_anchors
              BEGIN SELECT RAISE(ABORT, 'instruction anchors are append-only'); END;
            CREATE TRIGGER IF NOT EXISTS instruction_anchors_no_delete
              BEFORE DELETE ON instruction_anchors
              BEGIN SELECT RAISE(ABORT, 'instruction anchors are append-only'); END;
            """
        )

    @staticmethod
    def _latest(
        connection: sqlite3.Connection,
        workspace_key: str,
        owner_session_key: str,
        task_id: str,
    ) -> sqlite3.Row | None:
        return connection.execute(
            """
            SELECT * FROM instruction_anchors
            WHERE workspace_key=? AND owner_session_key=? AND task_id=?
            ORDER BY global_sequence DESC LIMIT 1
            """,
            (workspace_key, owner_session_key, task_id),
        ).fetchone()

    def observe_instruction_anchor(self, request: Mapping[str, Any]) -> dict[str, Any]:
        workspace_key = _require_string(request.get("workspaceKey"), "workspaceKey", 160)
        owner_session_key = _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 200)
        task_id = _optional_string(request.get("taskId"), "taskId", 200)
        if not task_id:
            raise InstructionAnchorStoreError("BRAIN_CONTROL_INSTRUCTION_ANCHOR_TASK_REQUIRED", "taskId is required")
        instruction = _redact_instruction(request.get("instruction"))
        source = _optional_string(
            request.get("source") or "instruction-anchor",
            "source",
            INSTRUCTION_ANCHOR_MAX_SOURCE_CHARS,
        )
        classification = _normalize_classification(request.get("classification"))
        signals = _normalize_signals(request.get("signals"))
        preserve_if_pending = bool(request.get("preserveIfPending", False))
        bound_anchor = request.get("boundAnchor")

        self.workspace.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.db_path, timeout=0.25, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA synchronous=FULL")
            connection.execute("PRAGMA busy_timeout=250")
            self._initialize(connection)
            connection.execute("BEGIN IMMEDIATE")
            existing_row = self._latest(connection, workspace_key, owner_session_key, task_id)
            existing = _anchor_from_row(existing_row) if existing_row is not None else None
            if existing is not None and preserve_if_pending and not _anchor_is_bound(existing, bound_anchor):
                connection.commit()
                return {"ok": True, "created": False, "preservedPending": True, "pending": True, "anchor": existing}

            next_sequence = 1 if existing is None else int(existing["sequence"]) + 1
            anchor_id = "ia-" + uuid.uuid4().hex
            instruction_hash = hashlib.sha256(instruction.encode("utf-8")).hexdigest()
            content_hash = _sha256(
                {
                    "schema": INSTRUCTION_ANCHOR_SCHEMA,
                    "anchorId": anchor_id,
                    "workspaceKey": workspace_key,
                    "ownerSessionKey": owner_session_key,
                    "taskId": task_id,
                    "sequence": next_sequence,
                    "instruction": instruction,
                    "instructionHash": instruction_hash,
                    "classification": classification,
                    "signals": signals,
                    "source": source,
                }
            )
            connection.execute(
                """
                INSERT INTO instruction_anchors(
                  anchor_id,workspace_key,owner_session_key,task_id,task_sequence,
                  instruction_text,instruction_hash,content_hash,classification_json,
                  signals_json,source,created_at,raw_prompt_stored
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    anchor_id,
                    workspace_key,
                    owner_session_key,
                    task_id,
                    next_sequence,
                    instruction,
                    instruction_hash,
                    content_hash,
                    _canonical_json(classification),
                    _canonical_json(signals),
                    source,
                    _utc_now(),
                    0,
                ),
            )
            row = connection.execute("SELECT * FROM instruction_anchors WHERE anchor_id=?", (anchor_id,)).fetchone()
            if row is None:
                raise InstructionAnchorStoreError(
                    "BRAIN_CONTROL_INSTRUCTION_ANCHOR_WRITE_FAILED",
                    "instruction anchor was not readable after insert",
                )
            anchor = _anchor_from_row(row)
            connection.commit()
            return {
                "ok": True,
                "created": True,
                "preservedPending": False,
                "pending": not _anchor_is_bound(anchor, bound_anchor),
                "anchor": anchor,
            }
        except sqlite3.Error as exc:
            try:
                connection.rollback()
            except sqlite3.Error:
                pass
            raise InstructionAnchorStoreError("BRAIN_CONTROL_INSTRUCTION_ANCHOR_STORE_FAILED", str(exc)) from exc
        except BaseException:
            try:
                connection.rollback()
            except sqlite3.Error:
                pass
            raise
        finally:
            connection.close()
