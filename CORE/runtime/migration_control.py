from __future__ import annotations

import hashlib
import json
import re
import shutil
import sqlite3
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any, Iterable, Mapping

if TYPE_CHECKING:
    from brain_control import BrainControl


MIGRATION_SCHEMA = "super-brain.legacy-migration.v1"
MIGRATION_MANIFEST_SCHEMA = "super-brain.legacy-migration-manifest.v1"
MIGRATION_ADAPTER_SCHEMA = "super-brain.legacy-migration-adapter.v1"
MIGRATION_IMPORTER_VERSION = "p5-legacy-migration-1"
MIGRATION_RECORD_SCHEMA_VERSION = "1"
MAX_SOURCE_FILE_BYTES = 1_048_576
MAX_NOTE_CHARS = 6_000
SUPPORTED_SUFFIXES = frozenset({".json", ".jsonl", ".md", ".txt", ".log"})
SENSITIVE_VALUE_RE = re.compile(
    r"(?i)(?:\bbearer\s+[a-z0-9._~+/-]+=*\b|\bsk-[a-z0-9_-]{8,}\b|\b(?:api[_ -]?key|password|passwd|token|secret)\s*[:=])"
)
SANDGLASS_MIGRATION_SCHEMA = "super-brain.sandglass-card-migration.v1"
SANDGLASS_IMPORTER_VERSION = "p5-sandglass-card-migration-1"
SANDGLASS_RECORD_SCHEMA_VERSION = "1"
SANDGLASS_MAX_CANDIDATE_CARDS = 12
SANDGLASS_LINE_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")
SANDGLASS_SENSITIVE_VALUE_RE = re.compile(
    r"(?i)(?:bearer\s+[a-z0-9._~+/-]+=*|sk-[a-z0-9_-]{8,}|(?:api[_ -]?key|password|passwd|token|secret)\s*[:=])"
)
SANDGLASS_COMMAND_OR_LOG_RE = re.compile(r"```|(?:^|\n)\s*(?:PS>|\$|Traceback|Exception|Error:|npm\s|python\s|git\s|curl\s)", re.IGNORECASE)
SANDGLASS_QUESTION_RE = re.compile(r"[?？]|^\s*(?:为什么|怎么|是否|能否|可以吗|请问)")
SANDGLASS_CANDIDATE_GROUPS = (
    ("collaboration", "协作方式与交付偏好", re.compile(r"简洁|简单|臃肿|维护|性能|速度|自动验证|不要|用户", re.IGNORECASE)),
    ("memory", "记忆与连续性", re.compile(r"记忆|回忆|连续|主动|自主|注入|沙漏|Sandglass|超级大脑|Super Brain", re.IGNORECASE)),
    ("engineering", "工程执行与验证", re.compile(r"修复|重构|测试|验收|计划|实现|迁移|检查|完成|结构", re.IGNORECASE)),
    ("ui", "界面与记忆星图", re.compile(r"界面|星图|控制中心|乱码|UI|显示|3D|可视", re.IGNORECASE)),
    ("runtime", "运行稳定性与 Hook", re.compile(r"Hook|P7|MCP|启动|重启|会话|缓存|调度|稳定", re.IGNORECASE)),
)


class MigrationControlError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _utc_now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _sha256(value: Any) -> str:
    return hashlib.sha256(_canonical_json(value).encode("utf-8")).hexdigest()


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _bounded(value: Any, maximum: int) -> str:
    if not isinstance(value, str):
        return ""
    return re.sub(r"\s+", " ", value).strip()[:maximum]


def _is_inside(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _read_json(path: Path) -> Mapping[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, Mapping) else None


class LegacyMigrationControl:
    """Hash-bound, staged import for legacy memory/state roots.

    It deliberately stores only source metadata in SQLite. Raw legacy bytes live
    only in the private epoch archive and are re-read with a source-hash check
    before import. This keeps migration planning searchable and auditable without
    turning the control database into a second raw transcript store.
    """

    def __init__(self, control: BrainControl):
        self.control = control

    @property
    def root(self) -> Path:
        return self.control.workspace / "legacy-migrations"

    def _epoch_root(self, epoch_id: str) -> Path:
        return self.root / epoch_id

    @staticmethod
    def _require_object(request: Any) -> Mapping[str, Any]:
        if not isinstance(request, Mapping):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_REQUEST_INVALID", "migration request must be an object")
        return request

    @staticmethod
    def _require_text(request: Mapping[str, Any], key: str, maximum: int = 240) -> str:
        value = request.get(key)
        if not isinstance(value, str) or not value.strip():
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_FIELD_REQUIRED", f"{key} is required")
        normalized = value.strip()
        if len(normalized) > maximum:
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_FIELD_INVALID", f"{key} is too long")
        return normalized

    def _source_roots(self, request: Mapping[str, Any]) -> list[dict[str, str]]:
        values = request.get("sourceRoots")
        if isinstance(values, str):
            values = [values]
        if not isinstance(values, list) or not values:
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_REQUIRED", "sourceRoots requires at least one directory")
        sources: list[dict[str, str]] = []
        seen: set[str] = set()
        state_root = self.control.state_root.resolve()
        for raw in values:
            if not isinstance(raw, str) or not raw.strip():
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_INVALID", "sourceRoots must contain paths")
            source = Path(raw).expanduser().resolve()
            key = str(source).casefold()
            if key in seen:
                continue
            seen.add(key)
            if not source.is_dir():
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_MISSING", f"source root is not a directory: {source}")
            if _is_inside(source, state_root) or _is_inside(state_root, source):
                raise MigrationControlError(
                    "BRAIN_CONTROL_MIGRATION_SOURCE_OVERLAP",
                    "source root cannot equal, contain, or be inside the active private state root",
                )
            source_id = _sha256({"sourceRoot": str(source).casefold()})[:32]
            sources.append({"sourceId": source_id, "path": str(source)})
        return sorted(sources, key=lambda item: item["path"].casefold())

    @staticmethod
    def _sandglass_role(sender: str) -> str:
        return sender.split(";", 1)[0].strip().casefold()

    @staticmethod
    def _parse_sandglass_line(line: str) -> tuple[str, str, str] | None:
        parts = line.strip().split(" | ", 2)
        if len(parts) != 3:
            return None
        timestamp, sender, text = (part.strip() for part in parts)
        if not SANDGLASS_LINE_RE.fullmatch(timestamp) or not sender or not text:
            return None
        return timestamp, sender, text

    @staticmethod
    def _sandglass_line_digest(timestamp: str, sender: str, text: str) -> str:
        return _sha256({"timestamp": timestamp, "sender": sender, "text": text})

    def _sandglass_source_spec(self, request: Mapping[str, Any]) -> dict[str, Any]:
        text_value = self._require_text(request, "sourceTxtPath", 2048)
        sqlite_value = self._require_text(request, "sourceSqlitePath", 2048)
        text_input = Path(text_value).expanduser()
        sqlite_input = Path(sqlite_value).expanduser()
        try:
            text_path = text_input.resolve()
            sqlite_path = sqlite_input.resolve()
        except OSError as exc:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SOURCE_INVALID", "Sandglass source path cannot be resolved") from exc
        if (
            text_input.is_symlink()
            or sqlite_input.is_symlink()
            or text_path.name != "sandglass.txt"
            or sqlite_path.name != "sandglass.db"
            or text_path.parent != sqlite_path.parent
            or not text_path.is_file()
            or not sqlite_path.is_file()
        ):
            raise MigrationControlError(
                "BRAIN_CONTROL_SANDGLASS_SOURCE_INVALID",
                "Sandglass migration accepts only a direct sandglass.txt plus sibling sandglass.db pair",
            )
        target_scope = request.get("targetScope", {"kind": "global", "key": "user"})
        if not isinstance(target_scope, Mapping):
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SCOPE_INVALID", "targetScope must be an object")
        scope_kind = _bounded(target_scope.get("kind"), 64)
        scope_key = _bounded(target_scope.get("key"), 256)
        if (scope_kind, scope_key) != ("global", "user"):
            raise MigrationControlError(
                "BRAIN_CONTROL_SANDGLASS_SCOPE_INVALID",
                "Sandglass history may only enter the private global/user review scope",
            )
        if str(request.get("targetLifecycle", "proposed")).strip().lower() != "proposed":
            raise MigrationControlError(
                "BRAIN_CONTROL_SANDGLASS_LIFECYCLE_INVALID",
                "Sandglass migration creates proposed cards only; activation is a separate reviewed action",
            )
        if str(request.get("privacyClass", "private")).strip().lower() != "private":
            raise MigrationControlError(
                "BRAIN_CONTROL_SANDGLASS_PRIVACY_INVALID",
                "Sandglass migration creates private cards only",
            )
        return {
            "textPath": text_path,
            "sqlitePath": sqlite_path,
            "scope": {"kind": scope_kind, "key": scope_key},
        }

    @staticmethod
    def _sandglass_candidate_group(text: str) -> tuple[str, str] | None:
        for key, title, pattern in SANDGLASS_CANDIDATE_GROUPS:
            if pattern.search(text):
                return key, title
        return None

    def _sandglass_sqlite_parity(
        self,
        sqlite_path: Path,
        parsed_lines: list[tuple[str, str, str]],
    ) -> dict[str, Any]:
        try:
            uri = "file:" + sqlite_path.as_posix() + "?mode=ro"
            connection = sqlite3.connect(uri, uri=True)
            try:
                rows = connection.execute("SELECT id,ts,sender,text FROM sandglass ORDER BY id").fetchall()
            finally:
                connection.close()
        except sqlite3.Error as exc:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_INDEX_INVALID", "Sandglass SQLite index is unreadable") from exc
        if len(rows) != len(parsed_lines):
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SOURCE_INDEX_PARITY", "Sandglass text and SQLite row counts differ")
        line_digests: list[str] = []
        for line_number, (row, parsed) in enumerate(zip(rows, parsed_lines), start=1):
            if int(row[0]) != line_number:
                raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SOURCE_INDEX_PARITY", "Sandglass SQLite row ids are not line-addressable")
            indexed = (str(row[1] or "").strip(), str(row[2] or "").strip(), str(row[3] or "").strip())
            if indexed != parsed:
                raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SOURCE_INDEX_PARITY", "Sandglass SQLite contents differ from the text authority")
            line_digests.append(self._sandglass_line_digest(*parsed))
        return {
            "sqliteRowCount": len(rows),
            "sqliteRecordDigest": _sha256({"lineDigests": line_digests}),
        }

    @staticmethod
    def _sandglass_candidate_payload(
        group_title: str,
        source_count: int,
        first_timestamp: str,
        last_timestamp: str,
        source_digest: str,
    ) -> dict[str, Any]:
        body = (
            f"这是由旧 Sandglass 历史记录整理出的“{group_title}”候选。"
            f"它汇总了 {source_count} 条用户来源，时间范围为 {first_timestamp} 至 {last_timestamp}。"
            "本卡不保存原文，不会自动注入、覆盖当前偏好、配置或任务状态；请审核后再整理为当前记忆。"
        )
        return {
            "schema": "super-brain.card.note.v1",
            "body": body,
            "tags": ["legacy-sandglass", "history", "review-required", "source:" + source_digest[:16]],
            "links": [],
            "pinned": False,
        }

    def _scan_sandglass(self, spec: Mapping[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any], list[dict[str, str]]]:
        text_path = Path(spec["textPath"])
        sqlite_path = Path(spec["sqlitePath"])
        try:
            raw = text_path.read_bytes()
        except OSError as exc:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SOURCE_INVALID", "Sandglass text source is unreadable") from exc
        if not raw or len(raw) > MAX_SOURCE_FILE_BYTES:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SOURCE_INVALID", "Sandglass text source is empty or exceeds the migration size limit")
        try:
            source_text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SOURCE_INVALID", "Sandglass text source is not UTF-8") from exc
        lines = source_text.splitlines()
        parsed_lines: list[tuple[str, str, str]] = []
        for line in lines:
            parsed = self._parse_sandglass_line(line)
            if parsed is None:
                raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_SOURCE_INVALID", "Sandglass text contains a malformed record")
            parsed_lines.append(parsed)
        parity = self._sandglass_sqlite_parity(sqlite_path, parsed_lines)
        source_hash = _sha256_bytes(raw)
        sqlite_hash = _sha256_bytes(sqlite_path.read_bytes())
        source_id = _sha256({"sandglassTextPath": str(text_path).casefold()})[:32]
        source = {"sourceId": source_id, "path": str(text_path.parent)}
        records: list[dict[str, Any]] = []
        source_records: list[dict[str, Any]] = []
        candidate_groups: dict[str, dict[str, Any]] = {}
        sensitive_count = 0
        ignored_count = 0
        for line_number, (timestamp, sender, text) in enumerate(parsed_lines, start=1):
            line_digest = self._sandglass_line_digest(timestamp, sender, text)
            role = self._sandglass_role(sender)
            state = "ignored"
            reason = "non_user_source_evidence_only"
            group: tuple[str, str] | None = None
            if SANDGLASS_SENSITIVE_VALUE_RE.search(sender + "\n" + text):
                state = "quarantined"
                reason = "sensitive_content_quarantined"
                sensitive_count += 1
            elif role != "user":
                ignored_count += 1
            elif SANDGLASS_COMMAND_OR_LOG_RE.search(text):
                reason = "command_or_log_source"
                ignored_count += 1
            elif SANDGLASS_QUESTION_RE.search(text):
                reason = "question_source_not_durable"
                ignored_count += 1
            else:
                group = self._sandglass_candidate_group(text)
                if group is None:
                    reason = "no_stable_candidate_signal"
                    ignored_count += 1
                else:
                    reason = "aggregated_into_candidate:" + group[0]
                    bucket = candidate_groups.setdefault(group[0], {"key": group[0], "title": group[1], "items": []})
                    bucket["items"].append(
                        {"lineNumber": line_number, "timestamp": timestamp, "lineDigest": line_digest}
                    )
                    ignored_count += 1
            source_record = self._record(
                source_id=source_id,
                relative_path="sandglass.txt",
                source_hash=source_hash,
                source_format="sandglass-source-v1",
                locator="#line=" + str(line_number),
                kind="",
                title="",
                payload=None,
                state=state,
                reason=reason,
            )
            source_record["contentHash"] = line_digest
            source_record["sourceMetadata"] = {
                "lineNumber": line_number,
                "timestamp": timestamp,
                "senderRole": role or "unknown",
                "lineDigest": line_digest,
            }
            records.append(source_record)
            source_records.append(source_record)
        candidate_source_count = 0
        for key in sorted(candidate_groups):
            group = candidate_groups[key]
            items = list(group["items"])
            candidate_source_count += len(items)
            source_digest = _sha256({"group": key, "lineDigests": [item["lineDigest"] for item in items]})
            first_timestamp = min(str(item["timestamp"]) for item in items)
            last_timestamp = max(str(item["timestamp"]) for item in items)
            payload = self._sandglass_candidate_payload(
                str(group["title"]), len(items), first_timestamp, last_timestamp, source_digest
            )
            candidate = self._record(
                source_id=source_id,
                relative_path="sandglass.txt",
                source_hash=source_hash,
                source_format="sandglass-candidate-v1",
                locator="#candidate=" + key,
                kind="note",
                title="历史候选：" + str(group["title"]),
                payload=payload,
                state="planned",
                reason="conservative_grouped_history_candidate",
            )
            candidate["payload"] = payload
            candidate["sourceMetadata"] = {
                "sourceCount": len(items),
                "sourceFirstLine": min(int(item["lineNumber"]) for item in items),
                "sourceLastLine": max(int(item["lineNumber"]) for item in items),
                "firstTimestamp": first_timestamp,
                "lastTimestamp": last_timestamp,
                "sourceDigest": source_digest,
            }
            records.append(candidate)
        if len(candidate_groups) > SANDGLASS_MAX_CANDIDATE_CARDS:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_CANDIDATE_BOUND", "Sandglass candidate grouping exceeded the safe card bound")
        records.sort(key=lambda item: str(item["recordKey"]))
        source_files = [
            {"sourceId": source_id, "relativePath": "sandglass.txt", "sourceHash": source_hash, "recordCount": len(source_records), "sourceRole": "authority"},
            {"sourceId": source_id, "relativePath": "sandglass.db", "sourceHash": sqlite_hash, "recordCount": 0, "sourceRole": "derived_index"},
        ]
        metadata = {
            "sourceTxtPath": str(text_path),
            "sourceSqlitePath": str(sqlite_path),
            "sourceTxtHash": source_hash,
            "sourceSqliteHash": sqlite_hash,
            "sourceLineCount": len(parsed_lines),
            "validRecordCount": len(parsed_lines),
            "sourceRecordDigest": _sha256({"lineDigests": [self._sandglass_line_digest(*item) for item in parsed_lines]}),
            "sourceIndexParity": True,
            **parity,
            "candidateSourceCount": candidate_source_count,
            "candidateCardCount": len(candidate_groups),
            "quarantinedSourceCount": sensitive_count,
            "ignoredSourceCount": ignored_count,
            "rawTranscriptStored": False,
            "sourceArchiveCopied": False,
            "targetScope": dict(spec["scope"]),
            "targetLifecycle": "proposed",
            "privacyClass": "private",
        }
        return records, source_files, metadata, [source]

    def _sandglass_plan(self, request: Mapping[str, Any], *, epoch_id: str = "") -> dict[str, Any]:
        spec = self._sandglass_source_spec(request)
        records, source_files, metadata, sources = self._scan_sandglass(spec)
        body = {
            "schema": MIGRATION_MANIFEST_SCHEMA,
            "epochId": epoch_id,
            "sourceMode": "sandglass",
            "importerVersion": SANDGLASS_IMPORTER_VERSION,
            "recordSchemaVersion": SANDGLASS_RECORD_SCHEMA_VERSION,
            "sources": sources,
            "sourceFiles": source_files,
            "records": records,
            "sandglass": metadata,
        }
        plan_body = {key: value for key, value in body.items() if key != "epochId"}
        return {
            **body,
            "manifestHash": _sha256(body),
            "planFingerprint": _sha256(plan_body),
            "plannedCount": sum(1 for record in records if record["state"] == "planned"),
            "quarantinedCount": sum(1 for record in records if record["state"] == "quarantined"),
            "ignoredCount": sum(1 for record in records if record["state"] == "ignored"),
        }

    @staticmethod
    def _note_payload(text: str, source_identity: str) -> tuple[str, str, dict[str, Any]]:
        body = text.strip()
        title_suffix = source_identity.rsplit("/", 1)[-1].replace("#", " ")
        return (
            "note",
            _bounded("旧记录 " + title_suffix, 240) or "旧记录",
            {
                "schema": "super-brain.card.note.v1",
                "body": body,
                "tags": ["legacy-import"],
                "links": [],
                "pinned": False,
            },
        )

    @staticmethod
    def _explicit_card(value: Mapping[str, Any], source_identity: str) -> tuple[str, str, dict[str, Any]] | None:
        kind = value.get("kind")
        payload = value.get("payload")
        title = value.get("title")
        if isinstance(kind, str) and isinstance(payload, Mapping) and isinstance(title, str):
            return kind, _bounded(title, 240), dict(payload)
        schema = value.get("schema")
        if not isinstance(schema, str):
            return None
        schema_to_kind = {
            "super-brain.card.decision.v2": "decision",
            "super-brain.card.preference.v1": "preference",
            "super-brain.card.experience.v1": "experience",
            "super-brain.card.note.v1": "note",
            "super-brain.card.procedure.v1": "procedure",
            "super-brain.card.reflection.v1": "reflection",
        }
        mapped = schema_to_kind.get(schema)
        if not mapped:
            return None
        title_value = value.get("title")
        if not isinstance(title_value, str) or not title_value.strip():
            title_value = "旧记录 " + source_identity.rsplit("/", 1)[-1]
        return mapped, _bounded(title_value, 240), dict(value)

    @staticmethod
    def _text_chunks(value: str) -> Iterable[str]:
        text = value.strip()
        if not text:
            return []
        return [text[offset:offset + MAX_NOTE_CHARS] for offset in range(0, len(text), MAX_NOTE_CHARS)]

    def _record(
        self,
        *,
        source_id: str,
        relative_path: str,
        source_hash: str,
        source_format: str,
        locator: str,
        kind: str,
        title: str,
        payload: Mapping[str, Any] | None,
        state: str,
        reason: str = "",
    ) -> dict[str, Any]:
        source_identity = source_id + ":" + relative_path + locator
        record_key = _sha256(
            {
                "sourceHash": source_hash,
                "importerVersion": MIGRATION_IMPORTER_VERSION,
                "schemaVersion": MIGRATION_RECORD_SCHEMA_VERSION,
                "sourceIdentity": source_identity,
            }
        )
        content_hash = _sha256({"kind": kind, "title": title, "payload": payload}) if payload is not None else ""
        return {
            "recordKey": record_key,
            "sourceId": source_id,
            "relativePath": relative_path,
            "sourceHash": source_hash,
            "sourceIdentity": source_identity,
            "sourceFormat": source_format,
            "sourceLocator": locator,
            "kind": kind,
            "title": title,
            "contentHash": content_hash,
            "state": state,
            "reason": reason,
        }

    def _records_for_file(self, source_id: str, root: Path, file_path: Path) -> list[dict[str, Any]]:
        resolved = file_path.resolve()
        if not _is_inside(resolved, root):
            return [
                self._record(
                    source_id=source_id,
                    relative_path=file_path.name,
                    source_hash="",
                    source_format="unsafe_path",
                    locator="",
                    kind="",
                    title="",
                    payload=None,
                    state="quarantined",
                    reason="source_path_escapes_root",
                )
            ]
        relative_path = resolved.relative_to(root).as_posix()
        try:
            raw = resolved.read_bytes()
        except OSError:
            return [
                self._record(source_id=source_id, relative_path=relative_path, source_hash="", source_format="unreadable", locator="", kind="", title="", payload=None, state="quarantined", reason="source_read_failed")
            ]
        source_hash = _sha256_bytes(raw)
        suffix = resolved.suffix.lower()
        if len(raw) > MAX_SOURCE_FILE_BYTES:
            return [
                self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format=suffix.lstrip(".") or "binary", locator="", kind="", title="", payload=None, state="quarantined", reason="source_file_too_large")
            ]
        if suffix not in SUPPORTED_SUFFIXES:
            return [
                self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format=suffix.lstrip(".") or "binary", locator="", kind="", title="", payload=None, state="ignored", reason="unsupported_file_type")
            ]
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return [
                self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format=suffix.lstrip("."), locator="", kind="", title="", payload=None, state="quarantined", reason="source_not_utf8")
            ]
        if SENSITIVE_VALUE_RE.search(text):
            return [
                self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format=suffix.lstrip("."), locator="", kind="", title="", payload=None, state="quarantined", reason="sensitive_content_requires_manual_review")
            ]
        records: list[dict[str, Any]] = []
        if suffix == ".json":
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                return [
                    self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format="json", locator="", kind="", title="", payload=None, state="quarantined", reason="json_parse_failed")
                ]
            values = parsed if isinstance(parsed, list) else [parsed]
            for index, value in enumerate(values, start=1):
                locator = "#item=" + str(index)
                if isinstance(value, Mapping):
                    typed = self._explicit_card(value, relative_path + locator)
                    if typed:
                        kind, title, payload = typed
                    else:
                        kind, title, payload = self._note_payload(_canonical_json(value), relative_path + locator)
                else:
                    kind, title, payload = self._note_payload(_canonical_json(value), relative_path + locator)
                records.append(self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format="json", locator=locator, kind=kind, title=title, payload=payload, state="planned"))
            return records
        if suffix == ".jsonl":
            for line_number, line in enumerate(text.splitlines(), start=1):
                if not line.strip():
                    continue
                locator = "#line=" + str(line_number)
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    records.append(self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format="jsonl", locator=locator, kind="", title="", payload=None, state="quarantined", reason="jsonl_parse_failed"))
                    continue
                if isinstance(value, Mapping):
                    typed = self._explicit_card(value, relative_path + locator)
                    if typed:
                        kind, title, payload = typed
                    else:
                        kind, title, payload = self._note_payload(_canonical_json(value), relative_path + locator)
                else:
                    kind, title, payload = self._note_payload(_canonical_json(value), relative_path + locator)
                records.append(self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format="jsonl", locator=locator, kind=kind, title=title, payload=payload, state="planned"))
            return records or [self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format="jsonl", locator="", kind="", title="", payload=None, state="ignored", reason="empty_source")]
        for index, chunk in enumerate(self._text_chunks(text), start=1):
            locator = "#chunk=" + str(index)
            kind, title, payload = self._note_payload(chunk, relative_path + locator)
            records.append(self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format=suffix.lstrip("."), locator=locator, kind=kind, title=title, payload=payload, state="planned"))
        return records or [self._record(source_id=source_id, relative_path=relative_path, source_hash=source_hash, source_format=suffix.lstrip("."), locator="", kind="", title="", payload=None, state="ignored", reason="empty_source")]

    def _scan(self, sources: list[dict[str, str]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        records: list[dict[str, Any]] = []
        source_files: list[dict[str, Any]] = []
        for source in sources:
            root = Path(source["path"]).resolve()
            files = sorted((item for item in root.rglob("*") if item.is_file() and not item.is_symlink()), key=lambda item: str(item).casefold())
            for file_path in files:
                file_records = self._records_for_file(source["sourceId"], root, file_path)
                records.extend(file_records)
                relative = file_path.resolve().relative_to(root).as_posix()
                source_hashes = {str(record["sourceHash"]) for record in file_records if record.get("sourceHash")}
                source_files.append({"sourceId": source["sourceId"], "relativePath": relative, "sourceHash": next(iter(source_hashes), ""), "recordCount": len(file_records)})
        records.sort(key=lambda item: str(item["recordKey"]))
        source_files.sort(key=lambda item: (str(item["sourceId"]), str(item["relativePath"])))
        return records, source_files

    def _plan(self, request: Mapping[str, Any], *, epoch_id: str = "") -> dict[str, Any]:
        sources = self._source_roots(request)
        records, source_files = self._scan(sources)
        body = {
            "schema": MIGRATION_MANIFEST_SCHEMA,
            "epochId": epoch_id,
            "importerVersion": MIGRATION_IMPORTER_VERSION,
            "recordSchemaVersion": MIGRATION_RECORD_SCHEMA_VERSION,
            "sources": sources,
            "sourceFiles": source_files,
            "records": records,
        }
        manifest_hash = _sha256(body)
        plan_body = {
            "importerVersion": MIGRATION_IMPORTER_VERSION,
            "recordSchemaVersion": MIGRATION_RECORD_SCHEMA_VERSION,
            "sources": sources,
            "sourceFiles": source_files,
            "records": records,
        }
        return {
            **body,
            "manifestHash": manifest_hash,
            "planFingerprint": _sha256(plan_body),
            "plannedCount": sum(1 for record in records if record["state"] == "planned"),
            "quarantinedCount": sum(1 for record in records if record["state"] == "quarantined"),
            "ignoredCount": sum(1 for record in records if record["state"] == "ignored"),
        }

    @staticmethod
    def _write_json_atomic(path: Path, value: Mapping[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = _canonical_json(value).encode("utf-8")
        temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
        try:
            temporary.write_bytes(data)
            temporary.replace(path)
        finally:
            if temporary.exists():
                temporary.unlink(missing_ok=True)

    def _copy_archive(self, plan: Mapping[str, Any], epoch_root: Path) -> dict[str, dict[str, str]]:
        archive_root = epoch_root / "archive" / "sources"
        copied: dict[str, dict[str, str]] = {}
        source_paths = {str(source["sourceId"]): Path(str(source["path"])).resolve() for source in plan["sources"]}
        for file_info in plan["sourceFiles"]:
            source_id = str(file_info["sourceId"])
            relative = str(file_info["relativePath"])
            expected_hash = str(file_info["sourceHash"])
            if not expected_hash:
                # An unreadable source remains visible as a quarantined record.
                # There is intentionally no invented archive copy for bytes we
                # could not read and hash during planning.
                continue
            source_path = (source_paths[source_id] / relative).resolve()
            if not _is_inside(source_path, source_paths[source_id]):
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_ARCHIVE_INVALID", "archive source escaped its declared root")
            raw = source_path.read_bytes()
            source_hash = _sha256_bytes(raw)
            if source_hash != expected_hash:
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED", "source bytes changed before staging")
            destination = archive_root / source_id / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)
            copied[source_id + ":" + relative] = {
                "path": str(destination),
                "hash": _sha256_bytes(destination.read_bytes()),
            }
            if copied[source_id + ":" + relative]["hash"] != source_hash:
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_ARCHIVE_VERIFY_FAILED", "private archive hash did not match source")
        return copied

    def _backup_database(self, destination: Path) -> str:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            destination.unlink()
        with self.control._connection() as source:
            backup = sqlite3.connect(destination)
            try:
                source.backup(backup)
            finally:
                backup.close()
        return _sha256_bytes(destination.read_bytes())

    @staticmethod
    def _record_row(record: Mapping[str, Any], archive: Mapping[str, Mapping[str, str]]) -> tuple[Any, ...]:
        archive_info = archive.get(str(record["sourceId"]) + ":" + str(record["relativePath"]), {})
        return (
            str(record["recordKey"]),
            str(record["sourceId"]),
            str(record["relativePath"]),
            str(record["sourceHash"]),
            str(record["sourceIdentity"]),
            str(record["sourceFormat"]),
            str(record["sourceLocator"]),
            str(record["kind"]),
            str(record["title"]),
            str(record["contentHash"]),
            str(record["state"]),
            str(record["reason"]),
            str(archive_info.get("path", "")),
            str(archive_info.get("hash", "")),
        )

    def plan(self, request: Mapping[str, Any]) -> dict[str, Any]:
        plan = self._plan(self._require_object(request))
        return {
            "ok": True,
            "schema": MIGRATION_SCHEMA,
            "action": "plan",
            "applied": False,
            "planFingerprint": plan["planFingerprint"],
            "manifestHash": plan["manifestHash"],
            "sourceCount": len(plan["sources"]),
            "sourceFileCount": len(plan["sourceFiles"]),
            "plannedCount": plan["plannedCount"],
            "quarantinedCount": plan["quarantinedCount"],
            "ignoredCount": plan["ignoredCount"],
            "guard": "Plan is read-only. No source, private state, card, adapter, or legacy writer was changed.",
        }

    def sandglass_plan(self, request: Mapping[str, Any]) -> dict[str, Any]:
        plan = self._sandglass_plan(self._require_object(request))
        metadata = plan["sandglass"]
        return {
            "ok": True,
            "schema": SANDGLASS_MIGRATION_SCHEMA,
            "action": "sandglass_plan",
            "applied": False,
            "planFingerprint": plan["planFingerprint"],
            "manifestHash": plan["manifestHash"],
            "sourceLineCount": int(metadata["sourceLineCount"]),
            "validRecordCount": int(metadata["validRecordCount"]),
            "candidateSourceCount": int(metadata["candidateSourceCount"]),
            "candidateCardCount": int(metadata["candidateCardCount"]),
            "plannedCount": int(plan["plannedCount"]),
            "quarantinedCount": int(plan["quarantinedCount"]),
            "ignoredCount": int(plan["ignoredCount"]),
            "sourceIndexParity": bool(metadata["sourceIndexParity"]),
            "rawTranscriptStored": False,
            "guard": "The text file is the only authority. SQLite is read-only parity evidence; no raw transcript, secret, active card, injection snapshot, or writer was changed.",
        }

    def _load_sandglass_manifest(self, epoch: Mapping[str, Any], expected_manifest_hash: str) -> Mapping[str, Any]:
        manifest = self._load_verified_manifest(epoch, expected_manifest_hash)
        if str(manifest.get("sourceMode", "")) != "sandglass" or not isinstance(manifest.get("sandglass"), Mapping):
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_EPOCH_INVALID", "epoch is not a Sandglass card migration")
        return manifest

    def sandglass_stage(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        expected = self._require_text(request, "expectedPlanFingerprint", 128)
        epoch_id = str(request.get("epochId", "")).strip() or "sandglass-" + uuid.uuid4().hex
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{7,95}", epoch_id):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_EPOCH_INVALID", "epochId must be a lower-case migration identifier")
        plan = self._sandglass_plan(request, epoch_id=epoch_id)
        if expected != str(plan["planFingerprint"]):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_PLAN_STALE", "stage requires the exact current Sandglass plan fingerprint")
        epoch_root = self._epoch_root(epoch_id)
        manifest_path = epoch_root / "manifest.json"
        integrity_path = epoch_root / "archive" / "source-integrity.json"
        backup_path = epoch_root / "backup" / "brain-state.sqlite3"
        if manifest_path.exists():
            existing = _read_json(manifest_path)
            if existing and existing.get("manifestHash") == plan["manifestHash"]:
                return self.sandglass_status({"epochId": epoch_id})
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_EPOCH_EXISTS", "epoch already exists with a different manifest")
        integrity = {
            "schema": SANDGLASS_MIGRATION_SCHEMA,
            "epochId": epoch_id,
            "sourceTxtHash": plan["sandglass"]["sourceTxtHash"],
            "sourceSqliteHash": plan["sandglass"]["sourceSqliteHash"],
            "sourceLineCount": plan["sandglass"]["sourceLineCount"],
            "sourceRecordDigest": plan["sandglass"]["sourceRecordDigest"],
            "sourceIndexParity": plan["sandglass"]["sourceIndexParity"],
            "rawTranscriptStored": False,
            "sourceArchiveCopied": False,
        }
        self._write_json_atomic(integrity_path, integrity)
        backup_hash = self._backup_database(backup_path)
        manifest = {
            **plan,
            "createdAt": _utc_now(),
            "backupPath": str(backup_path),
            "backupHash": backup_hash,
            "archiveRoot": str(integrity_path.parent),
        }
        self._write_json_atomic(manifest_path, manifest)
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute(
                    """
                    INSERT INTO migration_epochs(
                      epoch_id,status,importer_version,record_schema_version,manifest_path,manifest_hash,
                      plan_fingerprint,source_roots_json,backup_path,backup_hash,archive_root,cutover_watermark,
                      adapter_generation,created_at,updated_at
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        epoch_id, "staged", SANDGLASS_IMPORTER_VERSION, SANDGLASS_RECORD_SCHEMA_VERSION,
                        str(manifest_path), str(plan["manifestHash"]), str(plan["planFingerprint"]),
                        _canonical_json(plan["sources"]), str(backup_path), backup_hash, str(integrity_path.parent),
                        0, 0, _utc_now(), _utc_now(),
                    ),
                )
                for record in plan["records"]:
                    connection.execute(
                        """
                        INSERT INTO migration_records(
                          epoch_id,record_key,source_id,relative_path,source_hash,source_identity,source_format,
                          source_locator,card_kind,title,content_hash,status,reason,archive_path,archive_hash
                        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                        (epoch_id, *self._record_row(record, {})),
                    )
                self._record_event(
                    connection,
                    epoch_id,
                    "sandglass_staged",
                    {
                        "manifestHash": plan["manifestHash"],
                        "backupHash": backup_hash,
                        "candidateCardCount": plan["sandglass"]["candidateCardCount"],
                        "quarantinedSourceCount": plan["sandglass"]["quarantinedSourceCount"],
                        "rawTranscriptStored": False,
                    },
                )
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return self.sandglass_status({"epochId": epoch_id})

    @staticmethod
    def _sandglass_candidate_records(records: Mapping[str, Mapping[str, Any]]) -> dict[str, Mapping[str, Any]]:
        return {
            key: record
            for key, record in records.items()
            if str(record.get("state", "")) == "planned"
            and str(record.get("kind", "")) == "note"
            and isinstance(record.get("payload"), Mapping)
        }

    def _find_exact_sandglass_duplicate(self, record: Mapping[str, Any], scope: Mapping[str, str]) -> Mapping[str, Any] | None:
        payload = record.get("payload")
        if not isinstance(payload, Mapping):
            return None
        with self.control._connection() as connection:
            row = connection.execute(
                """
                SELECT c.card_id,c.head_revision,c.lifecycle,r.content_hash
                FROM cards c
                JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
                WHERE c.kind='note' AND c.scope_kind=? AND c.scope_key=? AND c.lifecycle IN ('active','proposed')
                  AND c.authority='legacy' AND c.privacy_class='private' AND r.title=? AND r.structured_payload=?
                ORDER BY c.card_id ASC LIMIT 1
                """,
                (scope["kind"], scope["key"], str(record["title"]), _canonical_json(payload)),
            ).fetchone()
        return dict(row) if row is not None else None

    def sandglass_import(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        expected_manifest_hash = self._require_text(request, "expectedManifestHash", 128)
        epoch = self._epoch(epoch_id)
        if str(epoch["status"]) not in {"staged", "imported", "verified"}:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_IMPORT_BLOCKED", "Sandglass epoch is not eligible for import")
        manifest = self._load_sandglass_manifest(epoch, expected_manifest_hash)
        current_records = self._cards_for_import(manifest)
        candidates = self._sandglass_candidate_records(current_records)
        scope = manifest["sandglass"]["targetScope"]
        imported = 0
        unchanged = 0
        deduplicated = 0
        for key, record in sorted(candidates.items()):
            duplicate = self._find_exact_sandglass_duplicate(record, scope)
            if duplicate is not None and str(duplicate["card_id"]) != "sandglass-migration-card-" + key:
                with self.control._connection() as connection:
                    connection.execute("BEGIN IMMEDIATE")
                    try:
                        connection.execute(
                            "UPDATE migration_records SET status='deduplicated',reason=?,target_card_id=?,target_revision=?,imported_at=? WHERE epoch_id=? AND record_key=?",
                            ("canonical_exact_content_match", str(duplicate["card_id"]), int(duplicate["head_revision"]), _utc_now(), epoch_id, key),
                        )
                        self._record_event(connection, epoch_id, "sandglass_record_deduplicated", {"recordKey": key, "cardId": str(duplicate["card_id"]), "revision": int(duplicate["head_revision"])})
                        connection.execute("COMMIT")
                    except Exception:
                        connection.execute("ROLLBACK")
                        raise
                deduplicated += 1
                continue
            command = {
                "commandType": "create_card",
                "commandId": "sandglass-migration-command-" + key,
                "aggregateId": "sandglass-migration-card-" + key,
                "expectedRevision": 0,
                "actorReceipt": {
                    "schema": "super-brain.actor-receipt.v1",
                    "actorKind": "migration",
                    "actorId": epoch_id,
                    "authorization": "legacy",
                    "authorizationReceipt": str(epoch["manifest_hash"]),
                },
                "reason": "Import a grouped, non-injecting Sandglass history candidate into the private canonical card store.",
                "source": "sandglass_card_migration",
                "kind": "note",
                "scope": dict(scope),
                "lifecycle": "proposed",
                "authority": "legacy",
                "privacyClass": "private",
                "title": str(record["title"]),
                "payload": dict(record["payload"]),
                "evidenceRefs": ["migration:" + epoch_id + ":" + key],
            }
            try:
                applied = self.control.apply(command)
            except Exception as exc:
                with self.control._connection() as connection:
                    connection.execute("BEGIN IMMEDIATE")
                    try:
                        connection.execute(
                            "UPDATE migration_records SET status='quarantined',reason=? WHERE epoch_id=? AND record_key=?",
                            ("card_contract_rejected:" + type(exc).__name__, epoch_id, key),
                        )
                        self._record_event(connection, epoch_id, "sandglass_record_quarantined", {"recordKey": key, "reason": "card_contract_rejected"})
                        connection.execute("COMMIT")
                    except Exception:
                        connection.execute("ROLLBACK")
                        raise
                continue
            if bool(applied.get("idempotent")):
                unchanged += 1
            else:
                imported += 1
            with self.control._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    connection.execute(
                        "UPDATE migration_records SET status='imported',target_card_id=?,target_revision=?,imported_at=? WHERE epoch_id=? AND record_key=?",
                        (str(command["aggregateId"]), int(applied["revision"]), _utc_now(), epoch_id, key),
                    )
                    self._record_event(connection, epoch_id, "sandglass_record_imported", {"recordKey": key, "cardId": command["aggregateId"], "revision": int(applied["revision"]), "idempotent": bool(applied.get("idempotent"))})
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute("UPDATE migration_epochs SET status='imported',updated_at=? WHERE epoch_id=?", (_utc_now(), epoch_id))
                self._record_event(connection, epoch_id, "sandglass_imported", {"imported": imported, "unchanged": unchanged, "deduplicated": deduplicated})
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return self.sandglass_status({"epochId": epoch_id})

    def sandglass_verify(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        expected_manifest_hash = self._require_text(request, "expectedManifestHash", 128)
        epoch = self._epoch(epoch_id)
        manifest = self._load_sandglass_manifest(epoch, expected_manifest_hash)
        current_records = self._cards_for_import(manifest)
        candidates = self._sandglass_candidate_records(current_records)
        metadata = manifest["sandglass"]
        integrity_path = Path(str(epoch["archive_root"])) / "source-integrity.json"
        integrity = _read_json(integrity_path)
        if (
            integrity is None
            or integrity.get("sourceTxtHash") != metadata.get("sourceTxtHash")
            or integrity.get("sourceRecordDigest") != metadata.get("sourceRecordDigest")
            or integrity.get("rawTranscriptStored") is not False
        ):
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_INTEGRITY_INVALID", "Sandglass source integrity receipt is missing or altered")
        with self.control._connection() as connection:
            rows = connection.execute("SELECT * FROM migration_records WHERE epoch_id=? ORDER BY record_key", (epoch_id,)).fetchall()
        by_key = {str(row["record_key"]): dict(row) for row in rows}
        invalid: list[str] = []
        mapped = 0
        for key, candidate in candidates.items():
            row = by_key.get(key)
            if row is None or str(row.get("status", "")) not in {"imported", "deduplicated"}:
                invalid.append(key)
                continue
            card_id = str(row.get("target_card_id") or "")
            card = self.control.get_card(card_id) if card_id else None
            if card is None or int(card.get("revision", -1)) != int(row.get("target_revision") or -1):
                invalid.append(key)
                continue
            if card.get("kind") != "note" or card.get("lifecycle") != "proposed" or card.get("authority") != "legacy":
                invalid.append(key)
                continue
            if card.get("scope") != metadata.get("targetScope") or card.get("privacyClass") != "private":
                invalid.append(key)
                continue
            if _canonical_json(card.get("payload")) != _canonical_json(candidate.get("payload")):
                invalid.append(key)
                continue
            if str(row.get("status")) == "imported" and "migration:" + epoch_id + ":" + key not in card.get("evidenceRefs", []):
                invalid.append(key)
                continue
            mapped += 1
        source_rows = [row for row in by_key.values() if str(row.get("source_format")) == "sandglass-source-v1"]
        quarantined = [row for row in source_rows if str(row.get("status")) == "quarantined"]
        source_integrity = (
            len(source_rows) == int(metadata.get("sourceLineCount", -1))
            and len(quarantined) == int(metadata.get("quarantinedSourceCount", -1))
            and bool(metadata.get("sourceIndexParity"))
        )
        manifest_text = _canonical_json(manifest)
        raw_safe = not SANDGLASS_SENSITIVE_VALUE_RE.search(manifest_text) and bool(metadata.get("rawTranscriptStored") is False)
        result = {
            "epochId": epoch_id,
            "manifestHash": str(epoch["manifest_hash"]),
            "sourceIntegrity": source_integrity,
            "sourceIndexParity": bool(metadata.get("sourceIndexParity")),
            "sourceLineCount": int(metadata.get("sourceLineCount", 0)),
            "candidateCoverage": {"source": len(candidates), "target": mapped, "exact": mapped == len(candidates) and not invalid},
            "quarantinedSourceCount": len(quarantined),
            "invalidTargetRecordKeys": invalid,
            "rawTranscriptStored": False,
            "nativeSnapshotExcludesProposed": not invalid,
            "reviewReady": source_integrity and raw_safe and mapped == len(candidates) and not invalid,
            "activation": "Migration never activates Sandglass history. Promote an individual reviewed candidate through the normal card workflow.",
        }
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                next_status = "verified" if result["reviewReady"] else "imported"
                connection.execute("UPDATE migration_epochs SET status=?,updated_at=? WHERE epoch_id=?", (next_status, _utc_now(), epoch_id))
                self._record_event(connection, epoch_id, "sandglass_verified", result)
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return {"ok": bool(result["reviewReady"]), "schema": SANDGLASS_MIGRATION_SCHEMA, "action": "sandglass_verify", **result}

    def sandglass_rollback(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        expected_manifest_hash = self._require_text(request, "expectedManifestHash", 128)
        if request.get("userConfirmed") is not True:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_ROLLBACK_CONFIRMATION_REQUIRED", "logical rollback requires explicit userConfirmed=true")
        epoch = self._epoch(epoch_id)
        self._load_sandglass_manifest(epoch, expected_manifest_hash)
        if str(epoch["status"]) not in {"imported", "verified"}:
            raise MigrationControlError("BRAIN_CONTROL_SANDGLASS_ROLLBACK_BLOCKED", "only imported or verified Sandglass epochs can be rolled back")
        with self.control._connection() as connection:
            rows = connection.execute(
                "SELECT record_key,target_card_id,target_revision,status FROM migration_records WHERE epoch_id=? AND status='imported' ORDER BY record_key",
                (epoch_id,),
            ).fetchall()
        commands: list[dict[str, Any]] = []
        for row in rows:
            record_key = str(row["record_key"])
            card_id = str(row["target_card_id"] or "")
            card = self.control.get_card(card_id) if card_id else None
            if (
                card is None
                or int(card.get("revision", -1)) != int(row["target_revision"])
                or card.get("lifecycle") != "proposed"
                or "migration:" + epoch_id + ":" + record_key not in card.get("evidenceRefs", [])
            ):
                raise MigrationControlError(
                    "BRAIN_CONTROL_SANDGLASS_ROLLBACK_STALE",
                    "a candidate was edited, promoted, removed, or no longer belongs solely to this migration; rollback is blocked",
                )
            commands.append(
                {
                    "commandType": "trash_card",
                    "commandId": "sandglass-migration-rollback-" + epoch_id + "-" + record_key,
                    "aggregateId": card_id,
                    "expectedRevision": int(card["revision"]),
                    "actorReceipt": {
                        "schema": "super-brain.actor-receipt.v1",
                        "actorKind": "migration",
                        "actorId": epoch_id,
                        "authorization": "user_confirmed",
                        "authorizationReceipt": str(epoch["manifest_hash"]),
                    },
                    "reason": "User-confirmed logical rollback of a proposed Sandglass history candidate.",
                    "source": "sandglass_card_migration",
                }
            )
        results = self.control.apply_many_atomically(commands) if commands else []
        revisions = {str(result.get("cardId")): int(result.get("revision", 0)) for result in results}
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                for row in rows:
                    card_id = str(row["target_card_id"])
                    connection.execute(
                        "UPDATE migration_records SET status='rolled_back',target_revision=?,imported_at=? WHERE epoch_id=? AND record_key=?",
                        (revisions.get(card_id, int(row["target_revision"])), _utc_now(), epoch_id, str(row["record_key"])),
                    )
                connection.execute("UPDATE migration_epochs SET status='rolled_back',updated_at=? WHERE epoch_id=?", (_utc_now(), epoch_id))
                self._record_event(connection, epoch_id, "sandglass_rolled_back", {"trashedCardCount": len(results), "rawTranscriptDeleted": False, "restorePath": "normal restore_card workflow"})
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return self.sandglass_status({"epochId": epoch_id})

    def sandglass_status(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        epoch = self._epoch(epoch_id)
        manifest = self._load_sandglass_manifest(epoch, str(epoch["manifest_hash"]))
        status = self.status({"epochId": epoch_id})
        metadata = manifest["sandglass"]
        return {
            **status,
            "schema": SANDGLASS_MIGRATION_SCHEMA,
            "action": "sandglass_status",
            "source": {
                "sourceLineCount": int(metadata["sourceLineCount"]),
                "validRecordCount": int(metadata["validRecordCount"]),
                "candidateSourceCount": int(metadata["candidateSourceCount"]),
                "candidateCardCount": int(metadata["candidateCardCount"]),
                "quarantinedSourceCount": int(metadata["quarantinedSourceCount"]),
                "sourceIndexParity": bool(metadata["sourceIndexParity"]),
                "rawTranscriptStored": False,
                "sourceArchiveCopied": False,
            },
            "guard": "Sandglass history remains a read-only source. Imported cards are historical proposals; no automatic activation or writer cutover exists.",
        }

    def stage(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        expected = self._require_text(request, "expectedPlanFingerprint", 128)
        epoch_id = str(request.get("epochId", "")).strip() or "migration-" + uuid.uuid4().hex
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{7,95}", epoch_id):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_EPOCH_INVALID", "epochId must be a lower-case migration identifier")
        plan = self._plan(request, epoch_id=epoch_id)
        if expected != str(plan["planFingerprint"]):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_PLAN_STALE", "stage requires the exact current plan fingerprint")
        epoch_root = self._epoch_root(epoch_id)
        manifest_path = epoch_root / "manifest.json"
        backup_path = epoch_root / "backup" / "brain-state.sqlite3"
        if manifest_path.exists():
            existing = _read_json(manifest_path)
            if existing and existing.get("manifestHash") == plan["manifestHash"]:
                return self.status({"epochId": epoch_id})
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_EPOCH_EXISTS", "epoch already exists with a different manifest")
        archive = self._copy_archive(plan, epoch_root)
        backup_hash = self._backup_database(backup_path)
        manifest = {
            **plan,
            "createdAt": _utc_now(),
            "backupPath": str(backup_path),
            "backupHash": backup_hash,
            "archiveRoot": str(epoch_root / "archive"),
        }
        self._write_json_atomic(manifest_path, manifest)
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute(
                    """
                    INSERT INTO migration_epochs(
                      epoch_id,status,importer_version,record_schema_version,manifest_path,manifest_hash,
                      plan_fingerprint,source_roots_json,backup_path,backup_hash,archive_root,cutover_watermark,
                      adapter_generation,created_at,updated_at
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        epoch_id, "staged", MIGRATION_IMPORTER_VERSION, MIGRATION_RECORD_SCHEMA_VERSION,
                        str(manifest_path), str(plan["manifestHash"]), str(plan["planFingerprint"]),
                        _canonical_json(plan["sources"]), str(backup_path), backup_hash, str(epoch_root / "archive"),
                        0, 0, _utc_now(), _utc_now(),
                    ),
                )
                for record in plan["records"]:
                    connection.execute(
                        """
                        INSERT INTO migration_records(
                          epoch_id,record_key,source_id,relative_path,source_hash,source_identity,source_format,
                          source_locator,card_kind,title,content_hash,status,reason,archive_path,archive_hash
                        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """,
                        (epoch_id, *self._record_row(record, archive)),
                    )
                self._record_event(connection, epoch_id, "staged", {"manifestHash": plan["manifestHash"], "backupHash": backup_hash})
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return self.status({"epochId": epoch_id})

    @staticmethod
    def _record_event(connection: sqlite3.Connection, epoch_id: str, action: str, result: Mapping[str, Any]) -> None:
        payload_hash = _sha256(result)
        connection.execute(
            "INSERT INTO migration_events(event_id,epoch_id,action,payload_hash,result_json,created_at) VALUES (?,?,?,?,?,?)",
            ("migration-event-" + uuid.uuid4().hex, epoch_id, action, payload_hash, _canonical_json(result), _utc_now()),
        )

    def _epoch(self, epoch_id: str) -> Mapping[str, Any]:
        with self.control._connection() as connection:
            row = connection.execute("SELECT * FROM migration_epochs WHERE epoch_id=?", (epoch_id,)).fetchone()
        if row is None:
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_EPOCH_NOT_FOUND", "migration epoch was not found")
        return dict(row)

    def _load_verified_manifest(self, epoch: Mapping[str, Any], expected_manifest_hash: str) -> Mapping[str, Any]:
        if expected_manifest_hash != str(epoch["manifest_hash"]):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_MANIFEST_STALE", "request does not bind the current epoch manifest")
        manifest_path = Path(str(epoch["manifest_path"]))
        manifest = _read_json(manifest_path)
        if manifest is None or str(manifest.get("manifestHash", "")) != str(epoch["manifest_hash"]):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_MANIFEST_INVALID", "epoch manifest is unavailable or altered")
        keys = ["schema", "epochId", "importerVersion", "recordSchemaVersion", "sources", "sourceFiles", "records"]
        if str(manifest.get("sourceMode", "")) == "sandglass":
            keys.extend(["sourceMode", "sandglass"])
        body = {key: manifest.get(key) for key in keys}
        if _sha256(body) != str(epoch["manifest_hash"]):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_MANIFEST_INVALID", "epoch manifest hash verification failed")
        backup_path = Path(str(epoch["backup_path"]))
        if not backup_path.is_file() or _sha256_bytes(backup_path.read_bytes()) != str(epoch["backup_hash"]):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_BACKUP_INVALID", "epoch SQLite backup is missing or altered")
        return manifest

    def _rebuild_current_records(self, manifest: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
        if str(manifest.get("sourceMode", "")) == "sandglass":
            metadata = manifest.get("sandglass")
            if not isinstance(metadata, Mapping):
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_MANIFEST_INVALID", "Sandglass migration metadata is invalid")
            text_path = Path(str(metadata.get("sourceTxtPath", "")))
            sqlite_path = Path(str(metadata.get("sourceSqlitePath", "")))
            try:
                current_text_hash = _sha256_bytes(text_path.read_bytes())
                current_sqlite_hash = _sha256_bytes(sqlite_path.read_bytes())
            except OSError as exc:
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED", "Sandglass source disappeared after stage") from exc
            if current_text_hash != str(metadata.get("sourceTxtHash", "")) or current_sqlite_hash != str(metadata.get("sourceSqliteHash", "")):
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED", "Sandglass source bytes changed after stage")
            records, _, _, _ = self._scan_sandglass(
                self._sandglass_source_spec(
                    {
                        "sourceTxtPath": metadata.get("sourceTxtPath"),
                        "sourceSqlitePath": metadata.get("sourceSqlitePath"),
                        "targetScope": metadata.get("targetScope"),
                        "targetLifecycle": metadata.get("targetLifecycle"),
                        "privacyClass": metadata.get("privacyClass"),
                    }
                )
            )
            return {str(record["recordKey"]): record for record in records}
        sources = manifest.get("sources")
        if not isinstance(sources, list):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_MANIFEST_INVALID", "manifest source list is invalid")
        current_sources = self._source_roots({"sourceRoots": [str(item.get("path", "")) for item in sources if isinstance(item, Mapping)]})
        current, _ = self._scan(current_sources)
        return {str(record["recordKey"]): record for record in current}

    def _cards_for_import(self, manifest: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
        current = self._rebuild_current_records(manifest)
        expected = {str(record["recordKey"]): record for record in manifest.get("records", []) if isinstance(record, Mapping)}
        if set(current) != set(expected):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED", "source inventory changed after stage")
        result: dict[str, dict[str, Any]] = {}
        for key, expected_record in expected.items():
            current_record = current[key]
            for field in ("sourceHash", "contentHash", "state", "reason"):
                if str(current_record.get(field, "")) != str(expected_record.get(field, "")):
                    raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED", "source record changed after stage")
            result[key] = current_record
        return result

    @staticmethod
    def _migration_scope(record: Mapping[str, Any]) -> dict[str, str]:
        return {"kind": "workspace", "key": "legacy-import-" + str(record["sourceId"])[:20]}

    def import_epoch(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        expected_manifest_hash = self._require_text(request, "expectedManifestHash", 128)
        epoch = self._epoch(epoch_id)
        if str(epoch["status"]) not in {"staged", "imported", "verified"}:
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_IMPORT_BLOCKED", "epoch is not eligible for import")
        manifest = self._load_verified_manifest(epoch, expected_manifest_hash)
        current_records = self._cards_for_import(manifest)
        imported = 0
        unchanged = 0
        quarantined = 0
        for key, record in sorted(current_records.items()):
            if str(record["state"]) != "planned":
                continue
            command = {
                "commandType": "create_card",
                "commandId": "legacy-migration-command-" + key,
                "aggregateId": "legacy-migration-card-" + key,
                "expectedRevision": 0,
                "actorReceipt": {
                    "schema": "super-brain.actor-receipt.v1",
                    "actorKind": "migration",
                    "actorId": epoch_id,
                    "authorization": "legacy",
                    "authorizationReceipt": str(epoch["manifest_hash"]),
                },
                "reason": "Import a hash-bound legacy record into the private canonical card store.",
                "source": "migration_control",
                "kind": str(record["kind"]),
                "scope": self._migration_scope(record),
                "lifecycle": "active",
                "authority": "legacy",
                "privacyClass": "private",
                "title": str(record["title"]),
                "payload": self._payload_for_record(manifest, key),
                "evidenceRefs": ["migration:" + epoch_id + ":" + key],
            }
            try:
                applied = self.control.apply(command)
            except Exception as exc:
                with self.control._connection() as connection:
                    connection.execute("BEGIN IMMEDIATE")
                    try:
                        connection.execute(
                            "UPDATE migration_records SET status='quarantined',reason=? WHERE epoch_id=? AND record_key=?",
                            ("card_contract_rejected:" + type(exc).__name__, epoch_id, key),
                        )
                        self._record_event(connection, epoch_id, "record_quarantined", {"recordKey": key, "reason": "card_contract_rejected"})
                        connection.execute("COMMIT")
                    except Exception:
                        connection.execute("ROLLBACK")
                        raise
                quarantined += 1
                continue
            if bool(applied.get("idempotent")):
                unchanged += 1
            else:
                imported += 1
            with self.control._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    connection.execute(
                        "UPDATE migration_records SET status='imported',target_card_id=?,target_revision=?,imported_at=? WHERE epoch_id=? AND record_key=?",
                        (str(command["aggregateId"]), int(applied["revision"]), _utc_now(), epoch_id, key),
                    )
                    self._record_event(connection, epoch_id, "record_imported", {"recordKey": key, "cardId": command["aggregateId"], "revision": int(applied["revision"]), "idempotent": bool(applied.get("idempotent"))})
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute("UPDATE migration_epochs SET status='imported',updated_at=? WHERE epoch_id=?", (_utc_now(), epoch_id))
                self._record_event(connection, epoch_id, "imported", {"imported": imported, "unchanged": unchanged, "quarantined": quarantined})
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return self.status({"epochId": epoch_id})

    def _payload_for_record(self, manifest: Mapping[str, Any], record_key: str) -> Mapping[str, Any]:
        sources = manifest.get("sources", [])
        source_map = {str(item.get("sourceId")): Path(str(item.get("path", ""))).resolve() for item in sources if isinstance(item, Mapping)}
        current = self._rebuild_current_records(manifest)
        record = current.get(record_key)
        if record is None:
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED", "record disappeared before import")
        source_id = str(record["sourceId"])
        source_root = source_map.get(source_id)
        if source_root is None:
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_MANIFEST_INVALID", "record source root is unavailable")
        source_path = (source_root / str(record["relativePath"])).resolve()
        if not _is_inside(source_path, source_root):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED", "record source path escaped root")
        raw = source_path.read_bytes()
        if _sha256_bytes(raw) != str(record["sourceHash"]):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED", "record source hash changed")
        suffix = source_path.suffix.lower()
        locator = str(record["sourceLocator"])
        if suffix == ".json":
            parsed = json.loads(raw.decode("utf-8"))
            values = parsed if isinstance(parsed, list) else [parsed]
            index = int(locator.split("=", 1)[1]) - 1
            value = values[index]
            if isinstance(value, Mapping):
                typed = self._explicit_card(value, str(record["relativePath"]) + locator)
                if typed:
                    return typed[2]
            return self._note_payload(_canonical_json(value), str(record["relativePath"]) + locator)[2]
        if suffix == ".jsonl":
            line_number = int(locator.split("=", 1)[1])
            line = raw.decode("utf-8").splitlines()[line_number - 1]
            value = json.loads(line)
            if isinstance(value, Mapping):
                typed = self._explicit_card(value, str(record["relativePath"]) + locator)
                if typed:
                    return typed[2]
            return self._note_payload(_canonical_json(value), str(record["relativePath"]) + locator)[2]
        chunk_index = int(locator.split("=", 1)[1]) - 1
        chunks = list(self._text_chunks(raw.decode("utf-8")))
        return self._note_payload(chunks[chunk_index], str(record["relativePath"]) + locator)[2]

    def verify(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        expected_manifest_hash = self._require_text(request, "expectedManifestHash", 128)
        epoch = self._epoch(epoch_id)
        manifest = self._load_verified_manifest(epoch, expected_manifest_hash)
        self._cards_for_import(manifest)
        with self.control._connection() as connection:
            rows = connection.execute("SELECT * FROM migration_records WHERE epoch_id=? ORDER BY record_key", (epoch_id,)).fetchall()
        candidate_rows = [dict(row) for row in rows if str(row["card_kind"])]
        imported = [row for row in candidate_rows if str(row["status"]) == "imported"]
        invalid_targets: list[str] = []
        for row in imported:
            card = self.control.get_card(str(row["target_card_id"])) if row.get("target_card_id") else None
            if card is None or int(card.get("revision", -1)) != int(row["target_revision"]):
                invalid_targets.append(str(row["record_key"]))
                continue
            if "migration:" + epoch_id + ":" + str(row["record_key"]) not in card.get("evidenceRefs", []):
                invalid_targets.append(str(row["record_key"]))
        quarantined = [dict(row) for row in rows if str(row["status"]) == "quarantined"]
        active_total = len(candidate_rows)
        active_exact = len(imported) == active_total and not invalid_targets
        historical_parity = (len(imported) / active_total) if active_total else 1.0
        result = {
            "epochId": epoch_id,
            "manifestHash": str(epoch["manifest_hash"]),
            "activeCurrentVerified": {"source": active_total, "target": len(imported), "exact": active_exact},
            "historicalSearchParity": {"source": active_total, "target": len(imported), "ratio": historical_parity, "threshold": 0.99},
            "quarantinedCount": len(quarantined),
            "invalidTargetRecordKeys": invalid_targets,
            "cutoverEligible": active_exact and historical_parity >= 0.99 and not quarantined,
        }
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                next_status = "verified" if result["cutoverEligible"] else "imported"
                connection.execute("UPDATE migration_epochs SET status=?,updated_at=? WHERE epoch_id=?", (next_status, _utc_now(), epoch_id))
                self._record_event(connection, epoch_id, "verified", result)
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return {"ok": result["cutoverEligible"], "schema": MIGRATION_SCHEMA, "action": "verify", **result}

    def cutover(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        expected_manifest_hash = self._require_text(request, "expectedManifestHash", 128)
        adapter_name = self._require_text(request, "adapterName", 96)
        epoch = self._epoch(epoch_id)
        self._load_verified_manifest(epoch, expected_manifest_hash)
        if str(epoch["status"]) != "verified":
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_CUTOVER_BLOCKED", "cutover requires a fully verified epoch")
        with self.control._connection() as connection:
            rows = connection.execute("SELECT record_key,target_card_id,target_revision,status FROM migration_records WHERE epoch_id=? ORDER BY record_key", (epoch_id,)).fetchall()
            watermark = int(connection.execute("SELECT COUNT(*) FROM events").fetchone()[0])
            generation = int(epoch["adapter_generation"]) + 1
        adapter_body = {
            "schema": MIGRATION_ADAPTER_SCHEMA,
            "epochId": epoch_id,
            "adapterName": adapter_name,
            "generation": generation,
            "mode": "forwarder",
            "watermark": watermark,
            "records": [
                {"recordKey": str(row["record_key"]), "cardId": str(row["target_card_id"]), "revision": int(row["target_revision"])}
                for row in rows if str(row["status"]) == "imported"
            ],
        }
        adapter_body["payloadHash"] = _sha256(adapter_body)
        projection_path = self._epoch_root(epoch_id) / "adapters" / (adapter_name + ".json")
        self._write_json_atomic(projection_path, adapter_body)
        projection_hash = _sha256_bytes(projection_path.read_bytes())
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute(
                    """
                    INSERT INTO migration_adapters(epoch_id,adapter_name,status,generation,watermark,projection_path,projection_hash,updated_at)
                    VALUES (?,?,?,?,?,?,?,?)
                    ON CONFLICT(epoch_id,adapter_name) DO UPDATE SET
                      status=excluded.status,generation=excluded.generation,watermark=excluded.watermark,
                      projection_path=excluded.projection_path,projection_hash=excluded.projection_hash,updated_at=excluded.updated_at
                    """,
                    (epoch_id, adapter_name, "forwarder", generation, watermark, str(projection_path), projection_hash, _utc_now()),
                )
                connection.execute("UPDATE migration_epochs SET status='cutover',cutover_watermark=?,adapter_generation=?,updated_at=? WHERE epoch_id=?", (watermark, generation, _utc_now(), epoch_id))
                self._record_event(connection, epoch_id, "cutover", {"adapterName": adapter_name, "generation": generation, "watermark": watermark, "projectionHash": projection_hash})
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return self.status({"epochId": epoch_id})

    def rollback_adapter(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        expected_manifest_hash = self._require_text(request, "expectedManifestHash", 128)
        adapter_name = self._require_text(request, "adapterName", 96)
        epoch = self._epoch(epoch_id)
        self._load_verified_manifest(epoch, expected_manifest_hash)
        with self.control._connection() as connection:
            adapter = connection.execute("SELECT * FROM migration_adapters WHERE epoch_id=? AND adapter_name=?", (epoch_id, adapter_name)).fetchone()
            if adapter is None or str(adapter["status"]) != "forwarder":
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_ROLLBACK_BLOCKED", "only a live forwarder adapter can be rolled back")
            projection_path = Path(str(adapter["projection_path"]))
        if not projection_path.is_file() or _sha256_bytes(projection_path.read_bytes()) != str(adapter["projection_hash"]):
            raise MigrationControlError("BRAIN_CONTROL_MIGRATION_ADAPTER_INVALID", "adapter projection is missing or altered")
        with self.control._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute("UPDATE migration_adapters SET status='read_only',updated_at=? WHERE epoch_id=? AND adapter_name=?", (_utc_now(), epoch_id, adapter_name))
                connection.execute("UPDATE migration_epochs SET status='adapter_rolled_back',updated_at=? WHERE epoch_id=?", (_utc_now(), epoch_id))
                self._record_event(connection, epoch_id, "rollback_adapter", {"adapterName": adapter_name, "mode": "read_only", "databaseRestored": False})
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return self.status({"epochId": epoch_id})

    def status(self, request: Mapping[str, Any]) -> dict[str, Any]:
        request = self._require_object(request)
        epoch_id = self._require_text(request, "epochId", 96)
        with self.control._connection() as connection:
            epoch = connection.execute("SELECT * FROM migration_epochs WHERE epoch_id=?", (epoch_id,)).fetchone()
            if epoch is None:
                raise MigrationControlError("BRAIN_CONTROL_MIGRATION_EPOCH_NOT_FOUND", "migration epoch was not found")
            rows = connection.execute("SELECT status,COUNT(*) AS count FROM migration_records WHERE epoch_id=? GROUP BY status", (epoch_id,)).fetchall()
            adapters = connection.execute("SELECT adapter_name,status,generation,watermark,projection_path,projection_hash,updated_at FROM migration_adapters WHERE epoch_id=? ORDER BY adapter_name", (epoch_id,)).fetchall()
        counts = {str(row["status"]): int(row["count"]) for row in rows}
        return {
            "ok": True,
            "schema": MIGRATION_SCHEMA,
            "action": "status",
            "epochId": str(epoch["epoch_id"]),
            "status": str(epoch["status"]),
            "manifestHash": str(epoch["manifest_hash"]),
            "planFingerprint": str(epoch["plan_fingerprint"]),
            "backupHash": str(epoch["backup_hash"]),
            "archiveRoot": str(epoch["archive_root"]),
            "cutoverWatermark": int(epoch["cutover_watermark"]),
            "recordCounts": counts,
            "adapters": [
                {
                    "adapterName": str(row["adapter_name"]), "status": str(row["status"]), "generation": int(row["generation"]),
                    "watermark": int(row["watermark"]), "projectionPath": str(row["projection_path"]), "projectionHash": str(row["projection_hash"]), "updatedAt": str(row["updated_at"]),
                }
                for row in adapters
            ],
            "guard": "Epoch operations are hash-bound. Rollback disables only the adapter; it never restores or deletes canonical SQLite data.",
        }
