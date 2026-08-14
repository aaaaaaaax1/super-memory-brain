"""Isolated LongMemEval-V2 adapter for Super Memory Brain retrieval.

The official LongMemEval-V2 harness loads this module through a small external
entrypoint.  It never touches the user's active memory root: benchmark records
live in a caller-provided, explicitly named LongMemEval-V2 state directory.
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import threading
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from brain_core import BrainCore


ADAPTER_SCHEMA = "super-brain.longmemeval-v2-adapter.v1"
MEMORY_TYPE = "super_brain_lme_v2"
MARKER_NAME = "super-brain-longmemeval-v2-isolated.json"
MAX_RECORD_CHARS_DEFAULT = 6000
MAX_RETRIEVAL_TOKENS_DEFAULT = 500
MAX_RETRIEVAL_TOP_K_DEFAULT = 4
MAX_ATTRIBUTED_EVIDENCE_SNIPPET_CHARS = 320
MAX_TRAJECTORY_CANDIDATE_ROWS = 96
MAX_TRAJECTORY_PACKET_CHARS = 400
MAX_SINGLE_TRAJECTORY_PACKET_CHARS = 480
MAX_TRAJECTORY_HEADER_EVIDENCE_CHARS = 160
MIN_TRAJECTORY_FACT_EVIDENCE_CHARS = 56
MAX_TEXT_CHARS_DEFAULT = 200_000
MAX_TRAJECTORY_METADATA_CHARS = 20_000
MAX_STATE_METADATA_CHARS = 80_000
MAX_ACCESSIBILITY_TREE_CHARS = 1_000_000
MAX_UI_CONTROL_INVENTORY_FIELDS = 64
MAX_UI_CONTROL_TEXT_CHARS = 240
MAX_UI_CONTROL_EVIDENCE_CHARS = 384
CONTEXT_ITEM_TOKEN_OVERHEAD = 4
MIN_RENDERED_EVIDENCE_TOKENS = 12
_BENCHMARK_SOURCE_LINE_RE = re.compile(r"^(?P<line>\d+):")
_BENCHMARK_ATTRIBUTION_FIELDS = ("trajectory_id", "state_position", "field", "field_chunk")
_TRAJECTORY_ID_RE = re.compile(r"\btrajectory_id=([^\s]+)")
_TRAJECTORY_FIELD_RE = re.compile(r"\bfield=([^\s]+)")
_TRAJECTORY_STATE_RE = re.compile(r"\bstate_position=(\d+)")
_GROUNDING_CONTRACT = (
    "[SUPER_BRAIN_LME_V2_GROUNDING] Use only observed records below. Do not infer missing "
    "controls, states, or causes. If a premise is unsupported or contradicted, explain that; "
    "otherwise follow the harness UNKNOWN rule when evidence is insufficient."
)

_ACCESSIBILITY_NODE_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?:\[(?P<ref>[^\]\r\n]+)\]\s+)?"
    r"(?P<role>LabelText|StaticText|textbox|combobox|select)\s+"
    r"'(?P<name>(?:\\.|[^'])*)'(?P<attrs>[^\r\n]*)$",
    re.IGNORECASE,
)
_ACCESSIBILITY_VALUE_RE = re.compile(r"\bvalue='(?P<value>(?:\\.|[^'])*)'", re.IGNORECASE)
_UI_CONTROL_ROLES = frozenset({"textbox", "combobox", "select"})
_UI_QUERY_ROLE_PATTERNS = {
    "textbox": re.compile(r"\b(?:textbox|text box|text field|input field)\b", re.IGNORECASE),
    "combobox": re.compile(r"\b(?:combobox|combo box|dropdown|drop-down)\b", re.IGNORECASE),
    "select": re.compile(r"\bselect(?: box| field| menu)?\b", re.IGNORECASE),
}
_UI_QUERY_ROLE_TERMS = frozenset(
    {"textbox", "text", "box", "field", "input", "combobox", "combo", "dropdown", "drop", "down", "select", "menu"}
)


class LongMemEvalV2AdapterError(RuntimeError):
    """Raised when an evaluation adapter invariant is violated."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise LongMemEvalV2AdapterError(message)


def _text(value: Any, limit: int = MAX_TEXT_CHARS_DEFAULT) -> str:
    if value is None:
        return ""
    result = " ".join(str(value).split()).strip()
    if len(result) > limit:
        raise LongMemEvalV2AdapterError(f"Benchmark field exceeds the allowed size ({limit} characters).")
    return result


def _accessibility_tree_text(value: Any) -> str:
    """Validate a tree while preserving its line structure for anchored parsing."""

    if value is None:
        return ""
    result = str(value).replace("\r\n", "\n").replace("\r", "\n")
    if len(result) > MAX_ACCESSIBILITY_TREE_CHARS:
        raise LongMemEvalV2AdapterError(
            f"Benchmark field exceeds the allowed size ({MAX_ACCESSIBILITY_TREE_CHARS} characters)."
        )
    return result


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _estimated_evidence_tokens(value: str) -> int:
    """Conservatively bound text-only benchmark context without a model tokenizer.

    The official harness tokenizer is intentionally outside this adapter.  The
    estimate therefore uses both UTF-8 density and lexical/punctuation units,
    retaining the larger result so the adapter never treats a dense control or
    non-ASCII payload as free context.
    """

    clean = str(value or "").strip()
    if not clean:
        return 0
    utf8_floor = (len(clean.encode("utf-8")) + 2) // 3
    lexical_units = len(re.findall(r"[A-Za-z0-9_]+|[^\sA-Za-z0-9_]", clean))
    return max(utf8_floor, lexical_units)


def _context_item_token_cost(value: str) -> int:
    """Include a small per-item protocol allowance in the aggregate budget."""

    return _estimated_evidence_tokens(value) + CONTEXT_ITEM_TOKEN_OVERHEAD


def _truncate_evidence_to_token_budget(value: str, budget: int) -> str:
    """Return a deterministic, observed-only prefix that fits ``budget``."""

    clean = str(value or "").strip()
    if budget < MIN_RENDERED_EVIDENCE_TOKENS or not clean:
        return ""
    if _context_item_token_cost(clean) <= budget:
        return clean

    low = 0
    high = len(clean)
    best = ""
    while low <= high:
        middle = (low + high) // 2
        candidate = clean[:middle].rstrip()
        if middle < len(clean):
            candidate = candidate.rstrip(".") + "..."
        if candidate and _context_item_token_cost(candidate) <= budget:
            best = candidate
            low = middle + 1
        else:
            high = middle - 1
    return best


def _write_json_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=True, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _chunk_text(
    value: Any,
    limit: int,
    *,
    source_limit: int = MAX_TEXT_CHARS_DEFAULT,
) -> list[str]:
    _require(limit >= 1, "Benchmark chunk limit must be positive.")
    clean = _text(value, source_limit)
    if not clean:
        return []
    if len(clean) <= limit:
        return [clean]
    chunks: list[str] = []
    remaining = clean
    while remaining:
        if len(remaining) <= limit:
            chunks.append(remaining)
            break
        boundary = remaining.rfind(" ", 0, limit)
        if boundary < max(64, limit // 2):
            boundary = limit
        chunks.append(remaining[:boundary].strip())
        remaining = remaining[boundary:].strip()
    return [chunk for chunk in chunks if chunk]


def _compact_accessibility_text(value: str) -> str:
    """Keep a single observed control label/name bounded without inventing fields."""

    clean = " ".join(value.replace("\\'", "'").split()).strip()
    return clean[:MAX_UI_CONTROL_TEXT_CHARS]


def _accessibility_node(line: str) -> tuple[int, str, str, str] | None:
    """Parse only anchored accessibility-tree role/name lines."""

    match = _ACCESSIBILITY_NODE_RE.match(line)
    if match is None:
        return None
    return (
        len(match.group("indent").expandtabs(2)),
        match.group("role").lower(),
        _compact_accessibility_text(match.group("name")),
        match.group("attrs"),
    )


def _ui_control_inventory(accessibility_tree: str) -> list[dict[str, str]]:
    """Extract observed label/control pairs without treating omitted nodes as absent.

    A label is eligible only when its next structural sibling control is a
    textbox, combobox, or select.  We intentionally do not search free text or
    infer properties that the accessibility snapshot did not expose.
    """

    lines = accessibility_tree.splitlines()
    inventory: list[dict[str, str]] = []
    for index, line in enumerate(lines):
        label_node = _accessibility_node(line)
        if label_node is None or label_node[1] != "labeltext":
            continue
        label_indent, _, label_name, _ = label_node
        label_parts = [label_name] if label_name else []
        control: tuple[int, str, str, str] | None = None
        for candidate_line in lines[index + 1 :]:
            candidate = _accessibility_node(candidate_line)
            if candidate is None:
                continue
            candidate_indent, role, name, attrs = candidate
            if role == "labeltext" and candidate_indent <= label_indent:
                break
            if role == "statictext" and candidate_indent > label_indent:
                if name:
                    label_parts.append(name)
                continue
            if role in _UI_CONTROL_ROLES:
                control = candidate
                break
            if candidate_indent <= label_indent:
                break
        label = _compact_accessibility_text(" ".join(label_parts))
        if not label or control is None:
            continue
        _, role, name, attrs = control
        field: dict[str, str] = {"label": label, "controlRole": role}
        if name:
            field["controlName"] = name
        value_match = _ACCESSIBILITY_VALUE_RE.search(attrs)
        if value_match is not None:
            value = _compact_accessibility_text(value_match.group("value"))
            if value:
                field["value"] = value
        inventory.append(field)
        if len(inventory) >= MAX_UI_CONTROL_INVENTORY_FIELDS:
            break
    return inventory


def _ui_query_roles(query: str) -> set[str]:
    """Return explicit control-role intent; generic prose does not activate it."""

    return {role for role, pattern in _UI_QUERY_ROLE_PATTERNS.items() if pattern.search(query)}


def _is_isolated_lme_v2_path(path: Path) -> bool:
    return any(part.lower() in {"longmemeval-v2", "lme-v2", "phase8-longmemeval-v2"} for part in path.parts)


def _benchmark_record_directory(record: str) -> tuple[str, int | None, str, bool] | None:
    """Return the observed trajectory relation for one isolated record."""

    trajectory_id = _TRAJECTORY_ID_RE.search(record)
    field = _TRAJECTORY_FIELD_RE.search(record)
    if trajectory_id is None or field is None:
        return None
    state_position = _TRAJECTORY_STATE_RE.search(record)
    return (
        trajectory_id.group(1),
        int(state_position.group(1)) if state_position is not None else None,
        field.group(1),
        "trajectory_header=true" in record,
    )


def _observed_record_body(record: str) -> str:
    """Remove only the adapter envelope before producing a bounded evidence window."""

    match = re.search(r"\bfield_chunk=\d+/\d+\s+(.*)$", record, re.DOTALL)
    return match.group(1).strip() if match is not None else record


class IsolatedLongMemEvalV2Store:
    """Write official trajectory observations into an isolated Sandglass store.

    This adapter intentionally stores only trajectory observations.  It rejects
    question, answer, and evaluator fields so the memory condition cannot leak
    labels into the reader prompt.
    """

    def __init__(
        self,
        *,
        package_root: str | Path,
        state_root: str | Path,
        run_id: str,
        domain: str,
        corpus_sha256: str,
        corpus_path: str | Path,
        harness_commit: str,
        dataset_revision: str,
        max_record_chars: int = MAX_RECORD_CHARS_DEFAULT,
        retrieval_top_k: int = MAX_RETRIEVAL_TOP_K_DEFAULT,
        retrieval_max_tokens: int = MAX_RETRIEVAL_TOKENS_DEFAULT,
    ) -> None:
        self.package_root = Path(package_root).expanduser().resolve()
        self.state_root = Path(state_root).expanduser().resolve()
        _require(self.package_root.is_dir(), "Super Brain package root is missing.")
        _require(_is_isolated_lme_v2_path(self.state_root), "Evaluation state root must be inside a LongMemEval-V2-isolated directory.")
        _require(_text(run_id, 120), "A stable benchmark run id is required.")
        _require(domain in {"web", "enterprise"}, "LongMemEval-V2 domain must be web or enterprise.")
        _require(len(corpus_sha256) == 64 and all(char in "0123456789abcdef" for char in corpus_sha256.lower()), "A corpus SHA-256 is required.")
        corpus_path_text = _text(corpus_path, 4096)
        _require(corpus_path_text, "A readable LongMemEval-V2 corpus_path is required.")
        self.corpus_path = Path(corpus_path_text).expanduser().resolve()
        _require(self.corpus_path.is_file(), "A readable LongMemEval-V2 corpus_path is required.")
        _require(len(harness_commit) >= 12, "An official harness commit is required.")
        _require(len(dataset_revision) >= 12, "An official dataset revision is required.")
        _require(512 <= int(max_record_chars) <= 12000, "max_record_chars must be between 512 and 12000.")
        _require(1 <= int(retrieval_top_k) <= 4, "retrieval_top_k must be between 1 and 4.")
        _require(32 <= int(retrieval_max_tokens) <= 500, "retrieval_max_tokens must be between 32 and 500.")

        self.run_id = run_id
        self.domain = domain
        self.corpus_sha256 = corpus_sha256.lower()
        self.verified_corpus_sha256 = _sha256_file(self.corpus_path)
        _require(
            self.verified_corpus_sha256 == self.corpus_sha256,
            "LongMemEval-V2 corpus_path SHA-256 does not match corpus_sha256.",
        )
        self.harness_commit = harness_commit
        self.dataset_revision = dataset_revision
        self.max_record_chars = int(max_record_chars)
        self.retrieval_top_k = int(retrieval_top_k)
        self.retrieval_max_tokens = int(retrieval_max_tokens)
        self.memory_root = self.state_root / "shared"
        self.workspace_root = self.state_root / "workspace"
        self.marker_path = self.state_root / MARKER_NAME
        self.memory_file = self.memory_root / "sandglass.txt"
        self.database_path = self.memory_root / "sandglass.db"
        self.metadata_path = self.state_root / "adapter-metadata.json"
        self._trajectory_ids: set[str] = set()
        self._record_count = 0
        self._image_omission_count = 0
        self._ui_control_inventory_count = 0
        self._ui_control_inventory_field_count = 0
        self._ui_control_inventory_duplicate_suppressed = 0
        self._index_ready = False
        self._index_lock = threading.Lock()
        self._core: BrainCore | None = None
        self._initialize_root()

    def _marker_payload(self) -> dict[str, Any]:
        return {
            "schema": ADAPTER_SCHEMA,
            "runId": self.run_id,
            "domain": self.domain,
            "corpusSha256": self.corpus_sha256,
            "corpusBindingVerified": True,
            "harnessCommit": self.harness_commit,
            "datasetRevision": self.dataset_revision,
            "textOnlyTrajectoryMemory": True,
            "rawPromptStored": False,
        }

    def _initialize_root(self) -> None:
        if self.state_root.exists() and any(self.state_root.iterdir()):
            marker = _read_json(self.marker_path)
            _require(marker == self._marker_payload(), "Evaluation state root already exists and is not an exact empty LongMemEval-V2 run.")
            _require(not self.memory_file.exists() and not self.database_path.exists(), "Refusing to reuse an existing benchmark memory store.")
        self.memory_root.mkdir(parents=True, exist_ok=True)
        self.workspace_root.mkdir(parents=True, exist_ok=True)
        _write_json_atomic(self.marker_path, self._marker_payload())
        self._write_metadata()

    def _write_metadata(self) -> None:
        manifest_path = self.package_root / "manifest.json"
        policy_path = self.package_root / "memory-policy.json"
        payload = {
            **self._marker_payload(),
            "recordCount": self._record_count,
            "trajectoryCount": len(self._trajectory_ids),
            "trajectoryImagesOmitted": self._image_omission_count,
            "uiControlInventoryCount": self._ui_control_inventory_count,
            "uiControlInventoryFieldCount": self._ui_control_inventory_field_count,
            "uiControlInventoryDuplicateSuppressed": self._ui_control_inventory_duplicate_suppressed,
            "retrievalStrategy": "trajectory_first",
            "retrievalMaxTokens": self.retrieval_max_tokens,
            "contextTokenEstimator": "utf8_div_3_or_lexical_units_plus_item_overhead.v1",
            "indexReady": self._index_ready,
            "packageManifestSha256": _sha256_file(manifest_path) if manifest_path.is_file() else "",
            "memoryPolicySha256": _sha256_file(policy_path) if policy_path.is_file() else "",
            "brainCoreSha256": _sha256_file(self.package_root / "runtime" / "brain_core.py"),
            "rawPromptStored": False,
            "rawAnswerStored": False,
        }
        _write_json_atomic(self.metadata_path, payload)

    @staticmethod
    def _metadata_body(
        trajectory_id: str,
        trajectory: dict[str, Any],
        state: dict[str, Any] | None = None,
    ) -> str:
        """Return bounded state metadata; large observations are written separately."""

        fields: list[tuple[str, Any, int]] = [
            ("trajectory_id", trajectory_id, 160),
            ("domain", trajectory.get("domain", ""), 32),
            ("environment", trajectory.get("environment", ""), 1_024),
            ("outcome", trajectory.get("outcome", ""), 1_024),
            ("goal", trajectory.get("goal", ""), 12_000),
        ]
        if state is not None:
            fields.extend(
                [
                    ("state_index", state.get("state_index", ""), 128),
                    ("step", state.get("step", ""), 128),
                    ("url", state.get("url", ""), 12_000),
                    ("action", state.get("action", ""), 12_000),
                    ("thought", state.get("thought", ""), 32_000),
                ]
            )
        parts: list[str] = []
        for key, value, limit in fields:
            clean = _text(value, limit)
            if clean:
                parts.append(f"{key}={clean}")
        return " ".join(parts)

    def _append_field_chunks(
        self,
        *,
        trajectory_id: str,
        field: str,
        value: Any,
        source_limit: int,
        state_position: int | None = None,
        trajectory_header: bool = False,
    ) -> None:
        """Write every large-field fragment with durable retrieval attribution."""

        prefix_parts = [
            "[SESSION][VERIFIED][BENCHMARK]",
            "benchmark=longmemeval-v2",
        ]
        if trajectory_header:
            prefix_parts.append("trajectory_header=true")
        prefix_parts.append(f"trajectory_id={trajectory_id}")
        if state_position is not None:
            prefix_parts.append(f"state_position={state_position}")
        prefix_parts.append(f"field={field}")
        prefix = " ".join(prefix_parts)
        # Reserve enough room for the chunk marker even at the minimum record size.
        content_limit = self.max_record_chars - len(prefix) - 48
        _require(content_limit >= 64, "Benchmark record limit leaves insufficient room for attributed field content.")
        chunks = _chunk_text(value, content_limit, source_limit=source_limit)
        _require(chunks, f"Trajectory {trajectory_id} field {field} has no textual observation.")
        total = len(chunks)
        for chunk_index, chunk in enumerate(chunks, start=1):
            record = f"{prefix} field_chunk={chunk_index}/{total} {chunk}"
            _require(len(record) <= self.max_record_chars, "Attributed benchmark field chunk exceeds max_record_chars.")
            self._append_record(record)

    def _append_ui_control_inventory(
        self,
        *,
        trajectory_id: str,
        state_position: int,
        inventory: list[dict[str, str]],
        context: str,
    ) -> None:
        """Persist a compact, positive-only control projection for retrieval."""

        rendered_inventory = json.dumps(inventory, ensure_ascii=True, separators=(",", ":"))
        inventory_sha256 = hashlib.sha256(rendered_inventory.encode("utf-8")).hexdigest()
        self._append_field_chunks(
            trajectory_id=trajectory_id,
            state_position=state_position,
            field="ui_control_inventory",
            value=f"inventory_sha256={inventory_sha256} {context} controls={rendered_inventory}",
            source_limit=MAX_UI_CONTROL_INVENTORY_FIELDS * (MAX_UI_CONTROL_TEXT_CHARS * 3 + 96),
        )
        self._ui_control_inventory_count += 1
        self._ui_control_inventory_field_count += len(inventory)

    @staticmethod
    def _ui_control_context(trajectory: dict[str, Any], state: dict[str, Any]) -> str:
        """Attach only observed state context so a control is not detached from its screen."""

        fields = (
            ("state_url", state.get("url", "")),
            ("state_action", state.get("action", "")),
            ("trajectory_goal", trajectory.get("goal", "")),
        )
        parts: list[str] = []
        for key, value in fields:
            clean = _compact_accessibility_text(str(value))
            if clean:
                parts.append(f"{key}={clean}")
        return " ".join(parts)

    def _append_record(self, text: str) -> None:
        timestamp = datetime(2020, 1, 1) + timedelta(seconds=self._record_count)
        line = f"{timestamp:%Y-%m-%d %H:%M:%S} | benchmark | {text}\n"
        self.memory_root.mkdir(parents=True, exist_ok=True)
        with self.memory_file.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(line)
        self._record_count += 1
        self._index_ready = False

    def insert(self, trajectory: dict[str, Any]) -> None:
        _require(isinstance(trajectory, dict), "LongMemEval-V2 trajectory must be an object.")
        _require(not any(key in trajectory for key in ("answer", "question", "eval_function")), "Trajectory input contains a forbidden evaluation label field.")
        trajectory_id = _text(trajectory.get("id"), 160)
        _require(trajectory_id, "LongMemEval-V2 trajectory id is required.")
        _require(trajectory_id not in self._trajectory_ids, f"Duplicate LongMemEval-V2 trajectory id: {trajectory_id}")
        _require(_text(trajectory.get("domain"), 32) == self.domain, "Trajectory domain does not match this isolated benchmark run.")
        states = trajectory.get("states")
        _require(isinstance(states, list), "LongMemEval-V2 trajectory states must be a list.")

        self._append_field_chunks(
            trajectory_id=trajectory_id,
            field="trajectory_metadata",
            value=self._metadata_body(trajectory_id, trajectory),
            source_limit=MAX_TRAJECTORY_METADATA_CHARS,
            trajectory_header=True,
        )

        seen_ui_control_inventories: set[str] = set()
        for state_position, state in enumerate(states):
            _require(isinstance(state, dict), f"Trajectory {trajectory_id} has an invalid state.")
            if _text(state.get("screenshot"), 4096):
                self._image_omission_count += 1
            metadata = self._metadata_body(trajectory_id, trajectory, state)
            self._append_field_chunks(
                trajectory_id=trajectory_id,
                state_position=state_position,
                field="state_metadata",
                value=metadata,
                source_limit=MAX_STATE_METADATA_CHARS,
            )
            accessibility_tree = _accessibility_tree_text(state.get("accessibility_tree"))
            if accessibility_tree:
                inventory = _ui_control_inventory(accessibility_tree)
                if inventory:
                    inventory_hash = hashlib.sha256(
                        json.dumps(inventory, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
                    ).hexdigest()
                    if inventory_hash in seen_ui_control_inventories:
                        self._ui_control_inventory_duplicate_suppressed += 1
                    else:
                        seen_ui_control_inventories.add(inventory_hash)
                        self._append_ui_control_inventory(
                            trajectory_id=trajectory_id,
                            state_position=state_position,
                            inventory=inventory,
                            context=self._ui_control_context(trajectory, state),
                        )
                self._append_field_chunks(
                    trajectory_id=trajectory_id,
                    state_position=state_position,
                    field="accessibility_tree",
                    value=accessibility_tree,
                    source_limit=MAX_ACCESSIBILITY_TREE_CHARS,
                )

        self._trajectory_ids.add(trajectory_id)
        self._write_metadata()

    def _core_instance(self) -> BrainCore:
        if self._core is None:
            self._core = BrainCore(self.package_root, self.memory_root)
        return self._core

    def _build_index(self) -> None:
        _require(self.memory_file.is_file(), "No benchmark trajectory records were ingested.")
        core = self._core_instance()
        connection: sqlite3.Connection | None = None
        try:
            connection = sqlite3.connect(self.database_path)
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.execute("PRAGMA synchronous=FULL")
            connection.execute("CREATE TABLE IF NOT EXISTS sandglass (id INTEGER PRIMARY KEY, ts TEXT, sender TEXT, text TEXT)")
            connection.execute("CREATE VIRTUAL TABLE IF NOT EXISTS sandglass_fts USING fts5(tokens)")
            connection.execute(
                "CREATE TABLE IF NOT EXISTS lme_trajectory_records "
                "(record_id INTEGER PRIMARY KEY, trajectory_id TEXT NOT NULL, state_position INTEGER, field TEXT NOT NULL, is_header INTEGER NOT NULL)"
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS lme_trajectory_records_by_trajectory "
                "ON lme_trajectory_records(trajectory_id, is_header DESC, record_id)"
            )
            connection.execute("DELETE FROM sandglass")
            connection.execute("DELETE FROM sandglass_fts")
            connection.execute("DELETE FROM lme_trajectory_records")
            rows: list[tuple[int, str, str, str]] = []
            fts_rows: list[tuple[int, str]] = []
            trajectory_rows: list[tuple[int, str, int | None, str, int]] = []
            with self.memory_file.open("r", encoding="utf-8", errors="strict") as handle:
                for line_number, line in enumerate(handle, start=1):
                    parts = line.rstrip("\r\n").split(" | ", 2)
                    _require(len(parts) == 3, "Benchmark Sandglass record is malformed.")
                    timestamp, sender, text = parts
                    rows.append((line_number, timestamp, sender, text))
                    fts_rows.append((line_number, core._fts_tokens(text)))
                    directory = _benchmark_record_directory(text)
                    if directory is not None:
                        trajectory_id, state_position, field, is_header = directory
                        trajectory_rows.append((line_number, trajectory_id, state_position, field, int(is_header)))
                    if len(rows) >= 500:
                        connection.executemany("INSERT INTO sandglass VALUES(?,?,?,?)", rows)
                        connection.executemany("INSERT INTO sandglass_fts(rowid, tokens) VALUES(?,?)", fts_rows)
                        if trajectory_rows:
                            connection.executemany(
                                "INSERT INTO lme_trajectory_records(record_id, trajectory_id, state_position, field, is_header) VALUES(?,?,?,?,?)",
                                trajectory_rows,
                            )
                        rows.clear()
                        fts_rows.clear()
                        trajectory_rows.clear()
            if rows:
                connection.executemany("INSERT INTO sandglass VALUES(?,?,?,?)", rows)
                connection.executemany("INSERT INTO sandglass_fts(rowid, tokens) VALUES(?,?)", fts_rows)
            if trajectory_rows:
                connection.executemany(
                    "INSERT INTO lme_trajectory_records(record_id, trajectory_id, state_position, field, is_header) VALUES(?,?,?,?,?)",
                    trajectory_rows,
                )
            connection.commit()
        except sqlite3.Error as exc:
            raise LongMemEvalV2AdapterError(f"Unable to build isolated benchmark FTS index: {exc}") from exc
        finally:
            if connection is not None:
                connection.close()
        self._index_ready = True
        self._write_metadata()

    def _ensure_index(self) -> None:
        if self._index_ready:
            return
        with self._index_lock:
            if not self._index_ready:
                self._build_index()

    @staticmethod
    def _source_line_number(source: object) -> int | None:
        match = _BENCHMARK_SOURCE_LINE_RE.match(str(source or "").strip())
        if match is None:
            return None
        try:
            return int(match.group("line"))
        except ValueError:
            return None

    @staticmethod
    def _benchmark_record_attribution(record: str) -> str:
        """Return only stable source metadata from one benchmark record."""

        if "[BENCHMARK]" not in record:
            return ""
        values: list[str] = []
        for field in _BENCHMARK_ATTRIBUTION_FIELDS:
            match = re.search(rf"\b{re.escape(field)}=([^\s]+)", record)
            if match is None:
                continue
            value = _compact_accessibility_text(match.group(1))
            if value:
                values.append(f"{field}={value}")
        if not values:
            return ""
        return "[OBSERVED " + " ".join(values) + "]"

    def _benchmark_attributions(self, sources: list[object]) -> dict[str, str]:
        """Look up source-only provenance without expanding benchmark evidence."""

        source_lines: dict[str, int] = {}
        for source in sources:
            line_number = self._source_line_number(source)
            if line_number is not None:
                source_lines[str(source)] = line_number
        if not source_lines or not self.database_path.is_file():
            return {}

        connection: sqlite3.Connection | None = None
        try:
            connection = sqlite3.connect(self.database_path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
            connection.execute("PRAGMA query_only=ON")
            placeholders = ",".join("?" for _ in source_lines.values())
            rows = connection.execute(
                f"SELECT id, text FROM sandglass WHERE id IN ({placeholders})",
                tuple(source_lines.values()),
            ).fetchall()
        except (OSError, sqlite3.Error, ValueError):
            return {}
        finally:
            if connection is not None:
                connection.close()

        by_line = {
            int(row[0]): self._benchmark_record_attribution(str(row[1]))
            for row in rows
            if len(row) >= 2
        }
        return {
            source: attribution
            for source, line_number in source_lines.items()
            if (attribution := by_line.get(line_number))
        }

    @staticmethod
    def _compact_trajectory_attribution(record: str) -> str:
        """Keep trajectory/state provenance while leaving room for observed facts."""

        directory = _benchmark_record_directory(record)
        if directory is None:
            return "[OBSERVED benchmark_record]"
        trajectory_id, state_position, field, _ = directory
        parts = [f"trajectory_id={trajectory_id}"]
        if state_position is not None:
            parts.append(f"state_position={state_position}")
        parts.append(f"field={field}")
        return "[OBSERVED " + " ".join(parts) + "]"

    def _trajectory_candidate_rows(self, query: str) -> list[dict[str, object]]:
        """Read a bounded FTS pool, retaining the observed trajectory relation."""

        core = self._core_instance()
        candidates: dict[int, dict[str, object]] = {}
        for variant_index, search_query in enumerate(core._search_queries(query)):
            rows = core._read_only_fts_rows(search_query, MAX_TRAJECTORY_CANDIDATE_ROWS)
            for fts_rank, row in enumerate(rows, start=1):
                record_id, _, _, record = row
                directory = _benchmark_record_directory(record)
                if directory is None:
                    continue
                trajectory_id, state_position, field, is_header = directory
                existing = candidates.get(record_id)
                candidate = {
                    "recordId": record_id,
                    "record": record,
                    "trajectoryId": trajectory_id,
                    "statePosition": state_position,
                    "field": field,
                    "isHeader": is_header,
                    "ftsRank": fts_rank,
                    "variantIndex": variant_index,
                }
                if existing is None or (fts_rank, variant_index) < (
                    int(existing["ftsRank"]),
                    int(existing["variantIndex"]),
                ):
                    candidates[record_id] = candidate
        return sorted(
            candidates.values(),
            key=lambda item: (int(item["ftsRank"]), int(item["variantIndex"]), int(item["recordId"])),
        )

    def _trajectory_headers(self, trajectory_ids: list[str]) -> dict[str, str]:
        """Fetch one recorded metadata header per selected trajectory."""

        if not trajectory_ids or not self.database_path.is_file():
            return {}
        connection: sqlite3.Connection | None = None
        try:
            connection = sqlite3.connect(self.database_path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
            connection.execute("PRAGMA query_only=ON")
            placeholders = ",".join("?" for _ in trajectory_ids)
            rows = connection.execute(
                "SELECT r.trajectory_id, s.text "
                "FROM lme_trajectory_records r JOIN sandglass s ON s.id=r.record_id "
                f"WHERE r.trajectory_id IN ({placeholders}) AND r.is_header=1 "
                "ORDER BY r.trajectory_id ASC, r.record_id ASC",
                tuple(trajectory_ids),
            ).fetchall()
        except (OSError, sqlite3.Error, ValueError):
            return {}
        finally:
            if connection is not None:
                connection.close()
        headers: dict[str, str] = {}
        for trajectory_id, record in rows:
            headers.setdefault(str(trajectory_id), str(record))
        return headers

    @staticmethod
    def _observed_trajectory_metadata(record: str) -> str:
        """Render only bounded, observed trajectory context from the header."""

        values: dict[str, str] = {}
        for field, pattern, limit in (
            ("goal", r"\bgoal=(.*)$", 100),
            ("outcome", r"\boutcome=(.*?)(?=\s+goal=|$)", 40),
        ):
            match = re.search(pattern, record)
            if match is None:
                continue
            value = _compact_accessibility_text(match.group(1))
            if value:
                values[field] = _compact_accessibility_text(value)[:limit]
        if not values:
            return ""
        return "observed " + " ".join(
            f"{field}={values[field]}" for field in ("goal", "outcome") if field in values
        )

    def _trajectory_evidence(self, query: str) -> list[str]:
        """Return top-k trajectory packets, not competing flat state fragments."""

        core = self._core_instance()
        terms = core._query_terms(query)
        anchors = core._query_anchors(query, terms)
        groups: dict[str, dict[str, object]] = {}
        for candidate in self._trajectory_candidate_rows(query):
            record = str(candidate["record"])
            lowered = record.lower()
            matched_terms = {term for term in terms if term.lower() in lowered}
            matched_anchors = {term for term in anchors if term.lower() in lowered}
            field = str(candidate["field"])
            field_weight = {
                "trajectory_metadata": 1.15,
                "state_metadata": 1.0,
                "ui_control_inventory": 1.05,
                "accessibility_tree": 0.9,
            }.get(field, 0.5)
            score = (
                len(matched_anchors) * 3.0
                + len(matched_terms) * 1.0
                + field_weight
                + 1.0 / max(1.0, float(candidate["ftsRank"]) ** 0.5)
            )
            candidate["score"] = score
            candidate["matchedTerms"] = matched_terms
            candidate["matchedAnchors"] = matched_anchors
            trajectory_id = str(candidate["trajectoryId"])
            group = groups.setdefault(
                trajectory_id,
                {
                    "trajectoryId": trajectory_id,
                    "records": [],
                    "terms": set(),
                    "anchors": set(),
                    "fields": set(),
                    "bestScore": 0.0,
                },
            )
            records = group["records"]
            assert isinstance(records, list)
            records.append(candidate)
            group["terms"].update(matched_terms)
            group["anchors"].update(matched_anchors)
            group["fields"].add(field)
            group["bestScore"] = max(float(group["bestScore"]), score)

        ranked_groups: list[dict[str, object]] = []
        for group in groups.values():
            score = (
                float(group["bestScore"])
                + len(group["anchors"]) * 1.5
                + min(3, len(group["terms"])) * 0.35
                + min(2, len(group["fields"])) * 0.15
            )
            group["score"] = score
            records = group["records"]
            assert isinstance(records, list)
            records.sort(
                key=lambda item: (
                    -float(item["score"]),
                    int(item["ftsRank"]),
                    int(item["recordId"]),
                )
            )
            ranked_groups.append(group)
        ranked_groups.sort(
            key=lambda group: (-float(group["score"]), str(group["trajectoryId"]))
        )
        selected_groups = ranked_groups[: self.retrieval_top_k]
        headers = self._trajectory_headers([str(group["trajectoryId"]) for group in selected_groups])
        evidence: list[str] = []
        fact_count = 2 if len(selected_groups) == 1 else 1
        packet_limit = MAX_SINGLE_TRAJECTORY_PACKET_CHARS if fact_count > 1 else MAX_TRAJECTORY_PACKET_CHARS
        for group in selected_groups:
            trajectory_id = str(group["trajectoryId"])
            header_record = headers.get(trajectory_id, "")
            pieces: list[str] = []
            if header_record:
                header_attribution = self._compact_trajectory_attribution(header_record)
                header_metadata = self._observed_trajectory_metadata(header_record)
                if header_metadata:
                    header_piece = header_attribution + "\n" + header_metadata
                    header_limit = 152 if fact_count > 1 else MAX_TRAJECTORY_HEADER_EVIDENCE_CHARS
                    pieces.append(header_piece[:header_limit].rstrip())

            records = group["records"]
            assert isinstance(records, list)
            fact_candidates = [item for item in records if str(item["field"]) != "trajectory_metadata"] or records
            seen_state_fields: set[tuple[str, object]] = set()
            facts_added = 0
            for candidate in fact_candidates:
                if facts_added >= fact_count:
                    break
                signature = (str(candidate["field"]), candidate["statePosition"])
                if signature in seen_state_fields:
                    continue
                remaining = packet_limit - sum(len(item) + 1 for item in pieces)
                attribution = self._compact_trajectory_attribution(str(candidate["record"]))
                slots_remaining = fact_count - facts_added
                snippet_budget = min(160, (remaining // max(1, slots_remaining)) - len(attribution) - 1)
                if snippet_budget < MIN_TRAJECTORY_FACT_EVIDENCE_CHARS:
                    break
                snippet = core._candidate_snippet(
                    "[SESSION][BENCHMARK] " + _observed_record_body(str(candidate["record"])),
                    query,
                    terms,
                    snippet_budget,
                )
                snippet = re.sub(r"^\[SESSION\]\[BENCHMARK\]\s*", "", snippet)
                if not snippet:
                    continue
                pieces.append(attribution + "\n" + snippet)
                seen_state_fields.add(signature)
                facts_added += 1
            packet = "\n".join(pieces).strip()
            if packet:
                evidence.append(packet[:packet_limit].rstrip())
        return evidence

    def _render_retrieved_evidence(self, retrieved: list[dict[str, object]]) -> list[str]:
        """Keep normal retrieval selection while restoring compact source attribution."""

        attributions = self._benchmark_attributions([item.get("source") for item in retrieved])
        evidence: list[str] = []
        for item in retrieved:
            snippet = _text(item.get("text"))
            if not snippet:
                continue
            if len(snippet) > MAX_ATTRIBUTED_EVIDENCE_SNIPPET_CHARS:
                prefix_length = (MAX_ATTRIBUTED_EVIDENCE_SNIPPET_CHARS - 3) // 2
                suffix_length = MAX_ATTRIBUTED_EVIDENCE_SNIPPET_CHARS - 3 - prefix_length
                snippet = snippet[:prefix_length].rstrip() + "..." + snippet[-suffix_length:].lstrip()
            attribution = attributions.get(str(item.get("source", "")), "[OBSERVED benchmark_record]")
            evidence.append(attribution + "\n" + snippet)
        return evidence

    def _ui_control_inventory_evidence(self, query: str) -> str:
        """Surface one matching positive UI projection without outranking arbitrary prose.

        This narrow path activates only for an explicit role query and requires
        a second query-term match when one exists.  It does not infer a missing
        control and does not alter the benchmark store while reading.
        """

        requested_roles = _ui_query_roles(query)
        if not requested_roles or not self.database_path.is_file():
            return ""
        query_terms = {
            term.lower()
            for term in re.findall(r"[a-zA-Z0-9_]{2,}", query)
            if term.lower() not in _UI_QUERY_ROLE_TERMS
        }
        rows = self._ui_control_inventory_candidate_rows(query)
        best: tuple[tuple[int, int, int, int], str, list[dict[str, str]]] | None = None
        for candidate in rows:
            record = str(candidate["record"])
            _, marker, serialized = record.partition(" controls=")
            if not marker:
                continue
            try:
                inventory = json.loads(serialized)
            except json.JSONDecodeError:
                continue
            if not isinstance(inventory, list) or not all(isinstance(item, dict) for item in inventory):
                continue
            roles = {str(item.get("controlRole", "")).lower() for item in inventory}
            role_matches = len(requested_roles.intersection(roles))
            if role_matches == 0:
                continue
            searchable = record.lower()
            term_matches = sum(1 for term in query_terms if term in searchable)
            if query_terms and term_matches == 0:
                continue
            score = (role_matches, term_matches, -int(candidate["ftsRank"]), -len(record))
            if best is None or score > best[0]:
                best = (score, record, [dict(item) for item in inventory])
        if best is None:
            return ""

        _, record, inventory = best
        role_and_term_matches = [
            item
            for item in inventory
            if str(item.get("controlRole", "")).lower() in requested_roles
            and (
                not query_terms
                or any(term in " ".join(map(str, item.values())).lower() for term in query_terms)
            )
        ]
        role_matches = [
            item for item in inventory if str(item.get("controlRole", "")).lower() in requested_roles
        ]
        rendered_inventory = role_and_term_matches or role_matches or inventory
        controls: list[str] = []
        for item in rendered_inventory[:4]:
            parts = [f"label={item.get('label', '')}", f"role={item.get('controlRole', '')}"]
            if item.get("controlName"):
                parts.append(f"name={item['controlName']}")
            if item.get("value"):
                parts.append(f"value={item['value']}")
            controls.append(" ".join(parts))
        trajectory_id = re.search(r"\btrajectory_id=([^\s]+)", record)
        state_position = re.search(r"\bstate_position=(\d+)", record)
        evidence = (
            "[SUPER_BRAIN_LME_V2_UI_EVIDENCE] "
            f"trajectory_id={trajectory_id.group(1) if trajectory_id else 'unknown'} "
            f"state_position={state_position.group(1) if state_position else 'unknown'} "
            "observed_controls=" + " ; ".join(controls)
        )
        if len(evidence) > MAX_UI_CONTROL_EVIDENCE_CHARS:
            evidence = evidence[: MAX_UI_CONTROL_EVIDENCE_CHARS - 3].rstrip() + "..."
        return evidence

    def _ui_control_inventory_candidate_rows(self, query: str) -> list[dict[str, object]]:
        """Read UI inventory candidates through FTS plus the trajectory directory.

        A positional ``LIKE ... LIMIT 1024`` scan silently lost late records.
        Restricting the FTS join to the indexed inventory field keeps the scan
        bounded while allowing any matching trajectory position to participate.
        """

        core = self._core_instance()
        candidates: dict[int, dict[str, object]] = {}
        connection: sqlite3.Connection | None = None
        try:
            connection = sqlite3.connect(self.database_path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
            connection.execute("PRAGMA query_only=ON")
            for variant_index, search_query in enumerate(core._search_queries(query)):
                tokens = core._fts_tokens(search_query)
                if not tokens:
                    continue
                if any(character.isascii() and character.isalpha() for character in search_query):
                    tokens = " OR ".join(tokens.split())
                rows = connection.execute(
                    "SELECT s.id, s.text FROM sandglass_fts f "
                    "JOIN sandglass s ON s.id=f.rowid "
                    "JOIN lme_trajectory_records r ON r.record_id=s.id "
                    "WHERE sandglass_fts MATCH ? AND r.field='ui_control_inventory' "
                    "ORDER BY rank, s.id LIMIT ?",
                    (tokens, MAX_TRAJECTORY_CANDIDATE_ROWS),
                ).fetchall()
                for fts_rank, row in enumerate(rows, start=1):
                    record_id = int(row[0])
                    candidate = {
                        "recordId": record_id,
                        "record": str(row[1]),
                        "ftsRank": fts_rank,
                        "variantIndex": variant_index,
                    }
                    existing = candidates.get(record_id)
                    if existing is None or (fts_rank, variant_index) < (
                        int(existing["ftsRank"]),
                        int(existing["variantIndex"]),
                    ):
                        candidates[record_id] = candidate
        except (OSError, sqlite3.Error, ValueError):
            return []
        finally:
            if connection is not None:
                connection.close()
        return sorted(
            candidates.values(),
            key=lambda item: (int(item["ftsRank"]), int(item["variantIndex"]), int(item["recordId"])),
        )

    def _bounded_context_items(self, evidence: list[str]) -> list[str]:
        """Enforce one aggregate evidence budget across grounding and UI packets."""

        grounding = "[SUPER_BRAIN_LME_V2_EVIDENCE]\n" + _GROUNDING_CONTRACT
        used_tokens = _context_item_token_cost(grounding)
        _require(
            used_tokens <= self.retrieval_max_tokens,
            "retrieval_max_tokens is too small for the mandatory LongMemEval-V2 grounding contract.",
        )
        context_items = [grounding]
        for item in evidence:
            remaining = self.retrieval_max_tokens - used_tokens
            bounded = _truncate_evidence_to_token_budget(item, remaining)
            if not bounded:
                continue
            item_cost = _context_item_token_cost(bounded)
            if item_cost > remaining:
                continue
            context_items.append(bounded)
            used_tokens += item_cost
        return context_items if len(context_items) > 1 else []

    def query(self, query: str) -> list[dict[str, str]]:
        _require(_text(query, 12000), "LongMemEval-V2 query is required.")
        self._ensure_index()
        evidence = self._trajectory_evidence(query)
        if not evidence:
            retrieved = self._core_instance().recall(
                query,
                top_k=self.retrieval_top_k,
                max_tokens=self.retrieval_max_tokens,
                layer="all",
            )
            retrieval_items = [item for item in retrieved if isinstance(item, dict)]
            evidence = self._render_retrieved_evidence(retrieval_items)
        ui_evidence = self._ui_control_inventory_evidence(query)
        if ui_evidence and not any("[SUPER_BRAIN_LME_V2_UI_EVIDENCE]" in item for item in evidence):
            if len(evidence) >= self.retrieval_top_k:
                evidence[-1] = ui_evidence
            else:
                evidence.append(ui_evidence)
        if not evidence:
            return []
        context_items = self._bounded_context_items(evidence)
        return [{"type": "text", "value": item} for item in context_items]

    def status(self) -> dict[str, Any]:
        return {
            "schema": ADAPTER_SCHEMA,
            "runId": self.run_id,
            "domain": self.domain,
            "corpusSha256": self.verified_corpus_sha256,
            "trajectoryCount": len(self._trajectory_ids),
            "recordCount": self._record_count,
            "indexReady": self._index_ready,
            "textOnlyTrajectoryMemory": True,
            "trajectoryImagesOmitted": self._image_omission_count,
            "uiControlInventoryCount": self._ui_control_inventory_count,
            "uiControlInventoryFieldCount": self._ui_control_inventory_field_count,
            "uiControlInventoryDuplicateSuppressed": self._ui_control_inventory_duplicate_suppressed,
            "retrievalStrategy": "trajectory_first",
            "rawPromptStored": False,
        }


def register_lme_v2_memory() -> type[Any]:
    """Register the adapter with a loaded official LongMemEval-V2 harness."""

    from memory_modules.memory import MEMORY_TYPES, Memory, register_memory

    existing = MEMORY_TYPES.get(MEMORY_TYPE)
    if existing is not None:
        if getattr(existing, "__module__", "") == __name__:
            return existing
        raise LongMemEvalV2AdapterError(f"LongMemEval-V2 memory type is already owned by {existing.__module__}.")

    @register_memory
    class SuperBrainLongMemEvalV2Memory(Memory):
        memory_type = MEMORY_TYPE

        def __init__(self, memory_params: dict[str, object]) -> None:
            super().__init__(memory_params)
            params = dict(memory_params)
            required = (
                "package_root",
                "state_root",
                "run_id",
                "domain",
                "corpus_sha256",
                "corpus_path",
                "harness_commit",
                "dataset_revision",
            )
            for key in required:
                _require(_text(params.get(key), 4096), f"LongMemEval-V2 Super Brain config is missing {key}.")
            self._store = IsolatedLongMemEvalV2Store(
                package_root=_text(params["package_root"], 4096),
                state_root=_text(params["state_root"], 4096),
                run_id=_text(params["run_id"], 120),
                domain=_text(params["domain"], 32),
                corpus_sha256=_text(params["corpus_sha256"], 64),
                corpus_path=_text(params["corpus_path"], 4096),
                harness_commit=_text(params["harness_commit"], 80),
                dataset_revision=_text(params["dataset_revision"], 80),
                max_record_chars=int(params.get("max_record_chars", MAX_RECORD_CHARS_DEFAULT)),
                retrieval_top_k=int(params.get("retrieval_top_k", MAX_RETRIEVAL_TOP_K_DEFAULT)),
                retrieval_max_tokens=int(params.get("retrieval_max_tokens", MAX_RETRIEVAL_TOKENS_DEFAULT)),
            )

        def insert(self, trajectory: dict[str, object]) -> None:
            self._store.insert(dict(trajectory))

        def query(self, query: str, query_image: str | None = None) -> list[dict[str, str]]:
            del query_image
            return self._store.query(query)

        def post_query_hook(
            self,
            *,
            query: str,
            query_image: str | None,
            memory_context: list[dict[str, str]],
        ) -> dict[str, object]:
            del query, query_image, memory_context
            return self._store.status()

    return SuperBrainLongMemEvalV2Memory
