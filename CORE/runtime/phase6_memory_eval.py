from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from brain_core import BrainCore
from layout_paths import state_root as resolve_state_root


SOURCE_SCHEMA = "super-brain.memory-e2e-source.v1"
SEALED_SCHEMA = "super-brain.memory-e2e-holdout.sealed.v1"
ANSWER_SCHEMA = "super-brain.memory-e2e-answer-artifact.v1"
ANSWER_INPUT_SCHEMA = "super-brain.memory-e2e-answer-input.v1"
ANSWER_PROVENANCE_SCHEMA = "super-brain.memory-e2e-answer-provenance.v2"
HOST_NATIVE_AGENT_PROVENANCE_KIND = "host_native_agent_blinded_input"
BLINDED_ANSWER_PROVENANCE_KINDS = {"external_blinded_input", HOST_NATIVE_AGENT_PROVENANCE_KIND}
REPORT_SCHEMA = "super-brain.memory-e2e-evaluation-report.v1"
AGGREGATE_SCHEMA = "super-brain.memory-e2e-aggregate.v1"
CONSUMPTION_SCHEMA = "super-brain.memory-e2e-consumption.v1"
MAX_CASES = 200
MAX_RECORDS_PER_CASE = 32
MAX_FAMILY_HASHES = 2000
MAX_RANK = 10
ANSWER_INPUT_RANK = 4
FRESHNESS_HOURS = 72
MIN_CASES_PER_REAL_SET = 20
MIN_CATEGORIES_PER_REAL_SET = 4
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
RECORD_MARKER_RE = re.compile(r"\[EVAL_RECORD:([A-Za-z0-9][A-Za-z0-9_.:-]{0,119})\]")
THRESHOLDS = {
    "oracle": 0.95,
    "recallAt4": 0.95,
    "recallAt10": 0.95,
    "e2e": 0.90,
    "category": 0.85,
    "unsupported": 1,
}


class Phase6Error(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _sha256(value: Any) -> str:
    if not isinstance(value, str):
        value = _canonical_json(value)
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _directory_tree_sha256(path: Path) -> str:
    if not path.is_dir():
        raise Phase6Error("BINDING_FILE_MISSING", "A required Phase 6 runtime directory is missing.")
    entries: list[str] = []
    for child in sorted(path.rglob("*"), key=lambda value: value.as_posix()):
        if child.is_file():
            entries.append(child.relative_to(path).as_posix() + "\n" + _file_sha256(child))
    if not entries:
        raise Phase6Error("BINDING_FILE_MISSING", "A required Phase 6 runtime directory is empty.")
    return _sha256("\n".join(entries))


def _read_json(path: Path, code: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise Phase6Error(code, "Required JSON artifact is missing or invalid.") from exc


def _write_json(path: Path, value: Any, overwrite: bool = False) -> None:
    if path.exists() and not overwrite:
        raise Phase6Error("OUTPUT_EXISTS", "Refusing to overwrite an existing evaluation artifact.")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def _safe_id(value: Any, field: str) -> str:
    text = str(value or "").strip()
    if not ID_RE.fullmatch(text):
        raise Phase6Error("CASE_IDENTIFIER_INVALID", f"{field} must use a compact non-secret identifier.")
    return text


def _safe_category(value: Any) -> str:
    return _safe_id(value, "category")


def _safe_hash(value: Any, field: str) -> str:
    text = str(value or "").strip().lower()
    if not HASH_RE.fullmatch(text):
        raise Phase6Error("HASH_INVALID", f"{field} must be a SHA-256 hex value.")
    return text


def _family_hash(family_id: str) -> str:
    return _sha256(family_id)


def _family_set_hash(family_hashes: list[str]) -> str:
    return _sha256(sorted(set(family_hashes)))


def _excluded_family_hashes(value: Any) -> list[str]:
    values = [_safe_hash(item, "excluded family hash") for item in _as_list(value)]
    if len(values) > MAX_FAMILY_HASHES:
        raise Phase6Error("FAMILY_HASH_LIMIT", "Too many excluded family hashes.")
    if len(set(values)) != len(values):
        raise Phase6Error("FAMILY_HASH_DUPLICATE", "Excluded family hashes must be unique.")
    return sorted(values)


def _as_list(value: Any) -> list[Any]:
    return list(value) if isinstance(value, list) else []


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _package_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _current_binding(root: Path) -> dict[str, str]:
    manifest = _read_json(root / "manifest.json", "MANIFEST_INVALID")
    files = {
        "manifestSha256": root / "manifest.json",
        "brainCoreSha256": root / "runtime" / "brain_core.py",
        "phase6RuntimeSha256": root / "runtime" / "phase6_memory_eval.py",
        "writeMemorySha256": root / "scripts" / "write-memory.ps1",
        "memoryPolicySha256": root / "memory-policy.json",
    }
    result = {
        "schema": "super-brain.memory-e2e-binding.v1",
        "packageVersion": str(manifest.get("version", "")),
    }
    for key, path in files.items():
        if not path.is_file():
            raise Phase6Error("BINDING_FILE_MISSING", "A required Phase 6 source file is missing.")
        result[key] = _file_sha256(path)
    result["memoryRuntimeTreeSha256"] = _directory_tree_sha256(root / "memory" / "shared" / "scripts")
    return result


def _validate_case_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise Phase6Error("CASE_PAYLOAD_INVALID", "A holdout case payload must be an object.")
    case_id = _safe_id(payload.get("id"), "case id")
    family_id = _safe_id(payload.get("familyId"), "family id")
    category = _safe_category(payload.get("category"))
    query = str(payload.get("query", "")).strip()
    if not query or len(query) > 2000:
        raise Phase6Error("CASE_QUERY_INVALID", "A case query is required and must be bounded.")
    records = _as_list(payload.get("records"))
    if len(records) > MAX_RECORDS_PER_CASE:
        raise Phase6Error("CASE_RECORD_LIMIT", "A case has too many records.")
    seen_records: set[str] = set()
    normalized_records: list[dict[str, str]] = []
    for raw in records:
        if not isinstance(raw, dict):
            raise Phase6Error("CASE_RECORD_INVALID", "Each record must be an object.")
        record_id = _safe_id(raw.get("id"), "record id")
        if record_id in seen_records:
            raise Phase6Error("CASE_RECORD_DUPLICATE", "Record ids must be unique within a case.")
        seen_records.add(record_id)
        text = str(raw.get("text", "")).strip()
        if not text or len(text) > 6000:
            raise Phase6Error("CASE_RECORD_TEXT_INVALID", "A record text is required and must be bounded.")
        layer = str(raw.get("layer", "project")).strip().lower() or "project"
        if layer not in {"profile", "project", "decision", "task", "session"}:
            raise Phase6Error("CASE_RECORD_LAYER_INVALID", "A record layer is unsupported.")
        sender = str(raw.get("sender", "user")).strip().lower() or "user"
        if sender not in {"user", "assistant", "system"}:
            raise Phase6Error("CASE_RECORD_SENDER_INVALID", "A record sender is unsupported.")
        normalized_records.append({"id": record_id, "text": text, "layer": layer, "sender": sender})

    expected = payload.get("expected")
    if not isinstance(expected, dict):
        raise Phase6Error("CASE_EXPECTED_INVALID", "A case expected result must be an object.")
    expected_ids = [_safe_id(value, "expected evidence id") for value in _as_list(expected.get("evidenceIds"))]
    if len(set(expected_ids)) != len(expected_ids):
        raise Phase6Error("CASE_EXPECTED_DUPLICATE", "Expected evidence ids must be unique.")
    if any(value not in seen_records for value in expected_ids):
        raise Phase6Error("CASE_EXPECTED_UNKNOWN_RECORD", "Expected evidence must reference a case record.")
    answer = expected.get("answer", {})
    answer = answer if isinstance(answer, dict) else {}
    answer_mode = str(answer.get("mode", "answer" if expected_ids else "abstain")).strip().lower()
    if answer_mode not in {"answer", "abstain"}:
        raise Phase6Error("CASE_ANSWER_MODE_INVALID", "Expected answer mode is unsupported.")
    if answer_mode == "abstain" and expected_ids:
        raise Phase6Error("CASE_ABSTAIN_EVIDENCE_CONFLICT", "An abstention case cannot require evidence.")
    phrases = [str(value).strip() for value in _as_list(answer.get("requiredPhrases")) if str(value).strip()]
    if answer_mode == "answer" and not phrases:
        raise Phase6Error("CASE_ANSWER_PHRASES_REQUIRED", "Answer cases need compact required phrases.")
    if answer_mode == "answer" and not expected_ids:
        raise Phase6Error("CASE_ANSWER_EVIDENCE_REQUIRED", "Answer cases need expected evidence.")
    if any(len(value) > 240 for value in phrases):
        raise Phase6Error("CASE_ANSWER_PHRASE_INVALID", "Required answer phrases are too long.")
    query_date = str(payload.get("queryDate", "")).strip()
    return {
        "id": case_id,
        "familyId": family_id,
        "category": category,
        "query": query,
        "queryDate": query_date,
        "records": normalized_records,
        "expected": {
            "evidenceIds": expected_ids,
            "answer": {"mode": answer_mode, "requiredPhrases": phrases},
        },
    }


def _sealed_descriptor(sealed: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": str(sealed.get("schema", "")),
        "setId": str(sealed.get("setId", "")),
        "caseCount": int(sealed.get("caseCount", 0)),
        "familySetHash": str(sealed.get("familySetHash", "")),
        "familyHashes": sorted(str(value) for value in _as_list(sealed.get("familyHashes"))),
        "excludedFamilyHashes": sorted(str(value) for value in _as_list(sealed.get("excludedFamilyHashes"))),
        "cases": [
            {"id": str(case.get("id", "")), "caseHash": str(case.get("caseHash", ""))}
            for case in _as_list(sealed.get("cases"))
        ],
    }


def seal_source(source: dict[str, Any]) -> dict[str, Any]:
    if str(source.get("schema", "")) != SOURCE_SCHEMA:
        raise Phase6Error("SOURCE_SCHEMA_INVALID", "Unsupported memory E2E source schema.")
    set_id = _safe_id(source.get("setId"), "set id")
    excluded_family_hashes = _excluded_family_hashes(source.get("excludedFamilyHashes", []))
    raw_cases = _as_list(source.get("cases"))
    if not raw_cases or len(raw_cases) > MAX_CASES:
        raise Phase6Error("SOURCE_CASE_COUNT_INVALID", "The source needs a bounded non-empty case set.")
    cases: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for raw in raw_cases:
        payload = _validate_case_payload(raw)
        if payload["id"] in seen_ids:
            raise Phase6Error("SOURCE_CASE_DUPLICATE", "Case ids must be unique.")
        seen_ids.add(payload["id"])
        cases.append({"id": payload["id"], "caseHash": _sha256(payload), "payload": payload})
    family_hashes = sorted({_family_hash(str(case["payload"]["familyId"])) for case in cases})
    if set(family_hashes).intersection(excluded_family_hashes):
        raise Phase6Error("SOURCE_FAMILY_OVERLAP", "A holdout family overlaps the excluded calibration families.")
    sealed = {
        "schema": SEALED_SCHEMA,
        "setId": set_id,
        "sealedAt": _utc_now(),
        "caseCount": len(cases),
        "familySetHash": _family_set_hash(family_hashes),
        "familyHashes": family_hashes,
        "excludedFamilyHashes": excluded_family_hashes,
        "cases": cases,
        "setHash": "",
    }
    sealed["setHash"] = _sha256(_sealed_descriptor(sealed))
    return sealed


def verify_sealed(sealed: Any) -> dict[str, Any]:
    if not isinstance(sealed, dict) or str(sealed.get("schema", "")) != SEALED_SCHEMA:
        raise Phase6Error("SEALED_SCHEMA_INVALID", "Unsupported Phase 6 sealed holdout.")
    _safe_id(sealed.get("setId"), "set id")
    excluded_family_hashes = _excluded_family_hashes(sealed.get("excludedFamilyHashes", []))
    cases = _as_list(sealed.get("cases"))
    if not cases or len(cases) > MAX_CASES or int(sealed.get("caseCount", 0)) != len(cases):
        raise Phase6Error("SEALED_CASE_COUNT_INVALID", "The sealed case count is invalid.")
    seen: set[str] = set()
    for item in cases:
        if not isinstance(item, dict):
            raise Phase6Error("SEALED_CASE_INVALID", "A sealed case is invalid.")
        case_id = _safe_id(item.get("id"), "case id")
        if case_id in seen:
            raise Phase6Error("SEALED_CASE_DUPLICATE", "A sealed case id is duplicated.")
        seen.add(case_id)
        payload = _validate_case_payload(item.get("payload"))
        if payload["id"] != case_id or _sha256(payload) != str(item.get("caseHash", "")):
            raise Phase6Error("SEALED_CASE_HASH_MISMATCH", "A sealed case payload was modified.")
    family_hashes = sorted({_family_hash(str(item["payload"]["familyId"])) for item in cases})
    declared_family_hashes = [_safe_hash(value, "family hash") for value in _as_list(sealed.get("familyHashes"))]
    if declared_family_hashes != family_hashes:
        raise Phase6Error("SEALED_FAMILY_HASHES_MISMATCH", "The sealed family membership index was modified.")
    if str(sealed.get("familySetHash", "")) != _family_set_hash(family_hashes):
        raise Phase6Error("SEALED_FAMILY_SET_HASH_MISMATCH", "The sealed family index was modified.")
    if set(family_hashes).intersection(excluded_family_hashes):
        raise Phase6Error("SEALED_FAMILY_OVERLAP", "A sealed holdout overlaps excluded calibration families.")
    if _sha256(_sealed_descriptor(sealed)) != str(sealed.get("setHash", "")):
        raise Phase6Error("SEALED_SET_HASH_MISMATCH", "The sealed set index was modified.")
    return sealed


def _initialize_isolated_state(root: Path, state_root: Path) -> None:
    runtime_source = root / "memory" / "shared" / "scripts"
    runtime_destination = state_root / "shared" / "scripts"
    if not runtime_source.is_dir():
        raise Phase6Error("MEMORY_RUNTIME_MISSING", "The isolated memory runtime source is missing.")
    shutil.copytree(runtime_source, runtime_destination, dirs_exist_ok=True)
    (state_root / "workspace").mkdir(parents=True, exist_ok=True)


def _write_record(root: Path, state_root: Path, workspace_key: str, record: dict[str, str]) -> bool:
    text = record["text"]
    if f"[EVAL_RECORD:{record['id']}]" not in text:
        text = f"[EVAL_RECORD:{record['id']}] {text}"
    environment = os.environ.copy()
    environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
    environment["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(root / "scripts" / "write-memory.ps1"),
        "-Text",
        text,
        "-Sender",
        record["sender"],
        "-Layer",
        record["layer"],
        "-WorkspaceKey",
        workspace_key,
    ]
    completed = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True, timeout=45)
    return completed.returncode == 0 and "WRITE_OK" in completed.stdout


def _source_record_ids(state_root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    database = state_root / "shared" / "sandglass.db"
    if database.is_file():
        connection: sqlite3.Connection | None = None
        try:
            connection = sqlite3.connect(database)
            for row_id, timestamp, text in connection.execute("SELECT id, ts, text FROM sandglass ORDER BY id"):
                match = RECORD_MARKER_RE.search(str(text))
                if match:
                    result[f"{int(row_id)}:{timestamp}"] = match.group(1)
        except sqlite3.Error:
            pass
        finally:
            if connection is not None:
                connection.close()
    memory_file = state_root / "shared" / "sandglass.txt"
    if memory_file.is_file():
        for line_number, line in enumerate(memory_file.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            parts = line.split(" | ", 2)
            if len(parts) != 3:
                continue
            match = RECORD_MARKER_RE.search(parts[2])
            if match:
                result.setdefault(f"{line_number}:{parts[0]}", match.group(1))
    return result


def _answer_input_descriptor(answer_input: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": str(answer_input.get("schema", "")),
        "setHash": str(answer_input.get("setHash", "")),
        "evidenceBinding": answer_input.get("evidenceBinding", {}),
        "cases": _as_list(answer_input.get("cases")),
    }


def _require_provenance_text(value: Any, field: str) -> str:
    text = str(value or "").strip()
    if not text or len(text) > 160:
        raise Phase6Error("ANSWER_PROVENANCE_INVALID", f"Answer provenance requires bounded {field}.")
    return text


def _validate_private_answer_input(root: Path, answer_input: Any) -> tuple[str, dict[str, dict[str, Any]]]:
    if not isinstance(answer_input, dict) or str(answer_input.get("schema", "")) != ANSWER_INPUT_SCHEMA:
        raise Phase6Error("ANSWER_INPUT_SCHEMA_INVALID", "Unsupported blinded answer input schema.")
    _safe_hash(answer_input.get("setHash"), "answer input set hash")
    input_hash = str(answer_input.get("inputHash", ""))
    if not HASH_RE.fullmatch(input_hash) or input_hash != _sha256(_answer_input_descriptor(answer_input)):
        raise Phase6Error("ANSWER_INPUT_HASH_MISMATCH", "Blinded answer input hash is invalid.")
    if _sha256(answer_input.get("evidenceBinding", {})) != _sha256(_current_binding(root)):
        raise Phase6Error("ANSWER_INPUT_BINDING_STALE", "Blinded answer input is not bound to the current Phase 6 runtime.")
    input_ids: dict[str, dict[str, Any]] = {}
    for item in _as_list(answer_input.get("cases")):
        if not isinstance(item, dict) or "expected" in item or "records" in item:
            raise Phase6Error("ANSWER_INPUT_CASE_INVALID", "Blinded answer input must not contain expected answers or full records.")
        case_id = _safe_id(item.get("id"), "answer input case id")
        if case_id in input_ids:
            raise Phase6Error("ANSWER_INPUT_CASE_INVALID", "Blinded answer input case ids must be unique.")
        _safe_hash(item.get("caseHash"), "answer input case hash")
        if item.get("ingestionReady") is not True:
            raise Phase6Error(
                "ANSWER_INPUT_INGESTION_FAILED",
                "Every blinded answer-input case requires complete isolated-memory ingestion.",
            )
        query = str(item.get("query", "")).strip()
        if not query or len(query) > 2000:
            raise Phase6Error("ANSWER_INPUT_CASE_INVALID", "Blinded answer input needs a bounded query.")
        evidence_ids: set[str] = set()
        evidence = _as_list(item.get("retrievedEvidence"))
        if len(evidence) > ANSWER_INPUT_RANK:
            raise Phase6Error("ANSWER_INPUT_EVIDENCE_LIMIT", "Blinded answer input exceeds the normal recall evidence limit.")
        for entry in evidence:
            if not isinstance(entry, dict):
                raise Phase6Error("ANSWER_INPUT_EVIDENCE_INVALID", "Blinded answer input evidence is invalid.")
            evidence_id = _safe_id(entry.get("id"), "answer input evidence id")
            text = str(entry.get("text", "")).strip()
            if evidence_id in evidence_ids or not text or len(text) > 6000:
                raise Phase6Error("ANSWER_INPUT_EVIDENCE_INVALID", "Blinded answer input evidence is invalid.")
            evidence_ids.add(evidence_id)
        input_ids[case_id] = item
    if not input_ids:
        raise Phase6Error("ANSWER_INPUT_CASE_INVALID", "Blinded answer input needs at least one case.")
    return input_hash, input_ids


def _validate_answer_input(root: Path, sealed: dict[str, Any], answer_input: Any) -> str:
    input_hash, input_ids = _validate_private_answer_input(root, answer_input)
    if str(answer_input.get("setHash", "")) != str(sealed.get("setHash", "")):
        raise Phase6Error("ANSWER_INPUT_SET_MISMATCH", "Blinded answer input does not bind the sealed set.")
    sealed_ids = {str(item["id"]): str(item["caseHash"]) for item in sealed["cases"]}
    for case_id, item in input_ids.items():
        if str(item.get("caseHash", "")) != sealed_ids.get(case_id, ""):
            raise Phase6Error("ANSWER_INPUT_CASE_INVALID", "Blinded answer input case binding is invalid.")
    if set(input_ids) != set(sealed_ids):
        raise Phase6Error("ANSWER_INPUT_CASE_SET_MISMATCH", "Blinded answer input must cover exactly the sealed cases.")
    return input_hash


def _answer_provenance_kind(
    answer_artifact: dict[str, Any], input_hash: str, allow_diagnostic_synthetic: bool
) -> str:
    provenance = answer_artifact.get("provenance")
    if not isinstance(provenance, dict):
        raise Phase6Error("ANSWER_PROVENANCE_REQUIRED", "Answer artifacts require blinded-input provenance.")
    kind = str(provenance.get("kind", ""))
    if kind == "synthetic_test_adapter":
        if not allow_diagnostic_synthetic:
            raise Phase6Error("ANSWER_PROVENANCE_NOT_EXTERNAL", "Synthetic answer artifacts are diagnostic only and cannot consume a real holdout.")
        return kind
    if kind not in BLINDED_ANSWER_PROVENANCE_KINDS or str(provenance.get("schema", "")) != ANSWER_PROVENANCE_SCHEMA:
        raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer artifacts must declare blinded-input provenance.")
    for field in ("generatorId", "generatorVersion", "runId", "modelId", "modelVersion"):
        _require_provenance_text(provenance.get(field), field)
    if str(provenance.get("modelId")) != str(provenance.get("modelVersion")):
        raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer provenance must bind one reported model identity.")
    for field in ("generatorSha256", "endpointSha256", "responseReceiptSha256", "responseModelEvidenceSha256"):
        if not HASH_RE.fullmatch(str(provenance.get(field, ""))):
            raise Phase6Error("ANSWER_PROVENANCE_INVALID", f"Answer provenance requires a SHA-256 {field}.")
    response_count = provenance.get("responseCount")
    if isinstance(response_count, bool) or not isinstance(response_count, int) or not 1 <= response_count <= MAX_CASES:
        raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer provenance requires a bounded response count.")
    case_count = provenance.get("caseCount")
    if isinstance(case_count, bool) or not isinstance(case_count, int) or not 1 <= case_count <= MAX_CASES:
        raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer provenance requires a bounded case count.")
    if provenance.get("independentExecution") is not True or provenance.get("expectedAnswerDataAvailable") is not False:
        raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer provenance must attest independent execution without expected-answer data.")
    if provenance.get("rawResponseStored") is not False:
        raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer provenance must not retain raw model responses.")
    if str(provenance.get("inputSchema", "")) != ANSWER_INPUT_SCHEMA or str(provenance.get("inputHash", "")) != input_hash:
        raise Phase6Error("ANSWER_PROVENANCE_INPUT_MISMATCH", "Answer provenance does not bind the supplied blinded answer input.")
    if kind == HOST_NATIVE_AGENT_PROVENANCE_KIND:
        _require_provenance_text(provenance.get("hostAgentId"), "hostAgentId")
        if provenance.get("hostedNativeAgent") is not True or provenance.get("modelIdentityVerified") is not True:
            raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Host-native answer provenance must attest a verified hosted agent dispatch.")
        if not HASH_RE.fullmatch(str(provenance.get("hostDispatchReceiptSha256", ""))):
            raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Host-native answer provenance requires a dispatch receipt hash.")
    return kind


def _answer_response_model_evidence_hash(values: dict[str, dict[str, Any]]) -> str:
    parts = [f"{case_id}\n{values[case_id]['responseModel']}" for case_id in sorted(values)]
    return _sha256("\n".join(parts))


def _answer_index(
    root: Path,
    answer_artifact: Any,
    sealed: dict[str, Any],
    answer_input: Any = None,
    allow_diagnostic_synthetic: bool = False,
) -> tuple[dict[str, dict[str, Any]] | None, str, str]:
    if answer_artifact is None:
        return None, "not_run", ""
    if not isinstance(answer_artifact, dict) or str(answer_artifact.get("schema", "")) != ANSWER_SCHEMA:
        raise Phase6Error("ANSWER_ARTIFACT_SCHEMA_INVALID", "Unsupported answer artifact schema.")
    if str(answer_artifact.get("setHash", "")) != str(sealed.get("setHash", "")):
        raise Phase6Error("ANSWER_ARTIFACT_SET_MISMATCH", "Answer artifact does not bind the sealed set.")
    provenance = answer_artifact.get("provenance")
    synthetic = isinstance(provenance, dict) and str(provenance.get("kind", "")) == "synthetic_test_adapter"
    input_hash = ""
    if synthetic:
        provenance_kind = _answer_provenance_kind(answer_artifact, "", allow_diagnostic_synthetic)
    else:
        if answer_input is None:
            raise Phase6Error("ANSWER_INPUT_REQUIRED", "A real answer artifact requires its blinded answer input.")
        input_hash = _validate_answer_input(root, sealed, answer_input)
        provenance_kind = _answer_provenance_kind(answer_artifact, input_hash, allow_diagnostic_synthetic)
    values: dict[str, dict[str, Any]] = {}
    for item in _as_list(answer_artifact.get("cases")):
        if not isinstance(item, dict):
            raise Phase6Error("ANSWER_CASE_INVALID", "An answer artifact case is invalid.")
        case_id = _safe_id(item.get("id"), "answer case id")
        if case_id in values:
            raise Phase6Error("ANSWER_CASE_DUPLICATE", "Answer artifact has duplicated case ids.")
        values[case_id] = item
    sealed_ids = {str(item["id"]): str(item["caseHash"]) for item in sealed["cases"]}
    if set(values) != set(sealed_ids):
        raise Phase6Error("ANSWER_CASE_SET_MISMATCH", "Answer artifact must cover exactly the sealed cases.")
    for case_id, item in values.items():
        if str(item.get("caseHash", "")) != sealed_ids[case_id]:
            raise Phase6Error("ANSWER_CASE_HASH_MISMATCH", "Answer artifact case hash does not match the sealed case.")
    if provenance_kind in BLINDED_ANSWER_PROVENANCE_KINDS:
        assert isinstance(provenance, dict)
        if int(provenance["caseCount"]) != len(values) or int(provenance["responseCount"]) > len(values):
            raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer provenance response/case coverage is invalid.")
        for case_id, item in values.items():
            response_model = _require_provenance_text(item.get("responseModel"), f"responseModel for {case_id}")
            if response_model != str(provenance["modelVersion"]):
                raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer case model identity differs from provenance.")
            item["responseModel"] = response_model
        if str(provenance["responseModelEvidenceSha256"]) != _answer_response_model_evidence_hash(values):
            raise Phase6Error("ANSWER_PROVENANCE_INVALID", "Answer provenance model evidence does not match its cases.")
    return values, provenance_kind, input_hash


def prepare_answer_input(root: Path, sealed: dict[str, Any]) -> dict[str, Any]:
    binding = _current_binding(root)
    cases: list[dict[str, Any]] = []
    for sealed_case in sealed["cases"]:
        payload = sealed_case["payload"]
        workspace_key = "phase6-answer-" + _sha256(str(sealed_case["caseHash"]))[:16]
        with tempfile.TemporaryDirectory(prefix="super-brain-phase6-answer-") as directory:
            state_root = Path(directory) / "state"
            _initialize_isolated_state(root, state_root)
            writes = [
                _write_record(root, state_root, workspace_key, record)
                for record in payload["records"]
            ]
            if not all(writes) or len(writes) != len(payload["records"]):
                raise Phase6Error(
                    "ANSWER_INPUT_INGESTION_FAILED",
                    "Every sealed source record must enter the isolated memory path before blinded generation.",
                )
            record_sources = _source_record_ids(state_root)
            records_by_id = {str(record["id"]): record for record in payload["records"]}
            core = BrainCore(root, state_root / "shared")
            ranked = core.evaluation_ranked_evidence(
                payload["query"], rank_limit=ANSWER_INPUT_RANK, query_date=payload["queryDate"]
            )
            retrieved: list[dict[str, str]] = []
            seen_ids: set[str] = set()
            for ranked_item in ranked:
                record_id = record_sources.get(str(ranked_item.get("source", "")), "")
                record = records_by_id.get(record_id)
                if not record or record_id in seen_ids:
                    continue
                seen_ids.add(record_id)
                retrieved.append(
                    {"id": record_id, "text": str(record["text"]), "layer": str(record["layer"])}
                )
                if len(retrieved) >= ANSWER_INPUT_RANK:
                    break
            cases.append(
                {
                    "id": str(sealed_case["id"]),
                    "caseHash": str(sealed_case["caseHash"]),
                    "query": str(payload["query"]),
                    "queryDate": str(payload["queryDate"]),
                    "retrievedEvidence": retrieved,
                    "ingestionReady": True,
                }
            )
    result = {
        "schema": ANSWER_INPUT_SCHEMA,
        "generatedAt": _utc_now(),
        "setHash": str(sealed["setHash"]),
        "evidenceBinding": binding,
        "privateArtifact": True,
        "rawExpectedDataStored": False,
        "cases": cases,
        "inputHash": "",
    }
    result["inputHash"] = _sha256(_answer_input_descriptor(result))
    _validate_answer_input(root, sealed, result)
    return result


def _consumption_registry_path(root: Path, set_hash: str, registry_root: Path | None = None) -> Path:
    base = registry_root if registry_root is not None else resolve_state_root(root) / "workspace" / "phase6-consumption"
    return base / f"{set_hash}.json"


def _reserve_consumption(
    root: Path, sealed: dict[str, Any], binding: dict[str, str], registry_root: Path | None = None
) -> Path:
    set_hash = str(sealed["setHash"])
    registry_path = _consumption_registry_path(root, set_hash, registry_root)
    if registry_path.exists():
        raise Phase6Error("HOLDOUT_ALREADY_RESERVED", "This Phase 6 sealed holdout is already reserved or consumed.")
    _write_json(
        registry_path,
        {
            "schema": CONSUMPTION_SCHEMA,
            "status": "reserved",
            "reservedAt": _utc_now(),
            "setHash": set_hash,
            "runtimeBindingHash": _sha256(binding),
            "rawCasePayloadStored": False,
        },
    )
    return registry_path


def _complete_consumption(
    registry_path: Path, sealed: dict[str, Any], binding: dict[str, str], report_hash: str
) -> None:
    _write_json(
        registry_path,
        {
            "schema": CONSUMPTION_SCHEMA,
            "status": "consumed",
            "consumedAt": _utc_now(),
            "setHash": str(sealed["setHash"]),
            "reportHash": report_hash,
            "runtimeBindingHash": _sha256(binding),
            "rawCasePayloadStored": False,
        },
        overwrite=True,
    )


def _resolve_consumption_marker(output_path: Path, marker_path: Path | None) -> Path:
    output = output_path.resolve()
    marker = (marker_path.resolve() if marker_path is not None else output.with_name(output.name + ".phase6-consumed.json"))
    if marker.parent != output.parent:
        raise Phase6Error("CONSUMPTION_MARKER_OUTSIDE_REPORT", "A consumption marker must sit beside its report.")
    if marker == output or marker.name in {"", ".", ".."}:
        raise Phase6Error("CONSUMPTION_MARKER_INVALID", "A consumption marker must be a separate file.")
    return marker


def _assert_consumed_report(
    root: Path,
    report_path: Path,
    report: dict[str, Any],
    allow_diagnostic_synthetic: bool = False,
    consumption_registry_root: Path | None = None,
) -> dict[str, Any]:
    allowed_statuses = {"internal_acceptance_only"}
    if allow_diagnostic_synthetic:
        allowed_statuses.add("diagnostic_non_publishable")
    if str(report.get("status", "")) not in allowed_statuses:
        raise Phase6Error("AGGREGATE_REPORT_NOT_ACCEPTANCE", "Only answer-evaluated internal reports can be aggregated.")
    answer_evaluation = report.get("answerEvaluation", {})
    if not isinstance(answer_evaluation, dict) or answer_evaluation.get("present") is not True:
        raise Phase6Error("AGGREGATE_ANSWER_MISSING", "An aggregate report must include final-answer evaluation.")
    if not allow_diagnostic_synthetic and (
        str(answer_evaluation.get("provenanceKind", "")) not in BLINDED_ANSWER_PROVENANCE_KINDS
        or answer_evaluation.get("provenanceBound") is not True
        or not HASH_RE.fullmatch(str(answer_evaluation.get("inputHash", "")))
        or not HASH_RE.fullmatch(str(answer_evaluation.get("provenanceReceiptSha256", "")))
    ):
        raise Phase6Error("AGGREGATE_ANSWER_PROVENANCE_INVALID", "A real aggregate requires blinded independently generated answers.")
    binding = _current_binding(root)
    if _sha256(report.get("evidenceBinding", {})) != _sha256(binding):
        raise Phase6Error("AGGREGATE_BINDING_STALE", "A report is not bound to the current runtime revision.")
    holdout = report.get("holdout", {})
    if not isinstance(holdout, dict):
        raise Phase6Error("AGGREGATE_HOLDOUT_INVALID", "An aggregate report has invalid holdout metadata.")
    set_hash = _safe_hash(holdout.get("setHash"), "holdout set hash")
    family_set_hash = _safe_hash(holdout.get("familySetHash"), "family set hash")
    family_hashes = {_safe_hash(value, "family hash") for value in _as_list(holdout.get("familyHashes"))}
    if not family_hashes or _family_set_hash(sorted(family_hashes)) != family_set_hash:
        raise Phase6Error("AGGREGATE_FAMILY_MEMBERSHIP_INVALID", "An aggregate report needs a valid hashed family membership index.")
    consumption = report.get("consumption", {})
    if not isinstance(consumption, dict):
        raise Phase6Error("AGGREGATE_REPORT_NOT_CONSUMED", "A fresh aggregate input must be explicitly consumed.")
    marker_name = str(consumption.get("markerFile", ""))
    privacy = report.get("privacy", {})
    if not isinstance(privacy, dict) or any(privacy.get(key) is not False for key in ("rawCasePayloadStored", "rawAnswersStored", "realUserMemoryRead")):
        raise Phase6Error("AGGREGATE_PRIVACY_INVALID", "An aggregate report must preserve the Phase 6 privacy contract.")
    if not marker_name or consumption.get("requested") is not True or consumption.get("consumed") is not True or Path(marker_name).name != marker_name:
        raise Phase6Error("AGGREGATE_REPORT_NOT_CONSUMED", "A fresh aggregate input must be explicitly consumed.")
    marker_path = report_path.resolve().parent / marker_name
    if not marker_path.is_file():
        raise Phase6Error("AGGREGATE_MARKER_MISSING", "The report's consumption marker is missing.")
    marker = _read_json(marker_path, "CONSUMPTION_MARKER_INVALID")
    if (
        str(marker.get("schema", "")) != CONSUMPTION_SCHEMA
        or str(marker.get("setHash", "")) != str(holdout.get("setHash", ""))
        or str(marker.get("reportHash", "")) != _file_sha256(report_path)
        or marker.get("rawCasePayloadStored") is not False
    ):
        raise Phase6Error("CONSUMPTION_MARKER_MISMATCH", "The consumption marker does not bind the report contents.")
    if not allow_diagnostic_synthetic:
        registry_path = _consumption_registry_path(root, set_hash, consumption_registry_root)
        registry = _read_json(registry_path, "CONSUMPTION_REGISTRY_MISSING")
        if (
            str(registry.get("schema", "")) != CONSUMPTION_SCHEMA
            or str(registry.get("status", "")) != "consumed"
            or str(registry.get("setHash", "")) != set_hash
            or str(registry.get("reportHash", "")) != _file_sha256(report_path)
            or str(registry.get("runtimeBindingHash", "")) != _sha256(_current_binding(root))
            or registry.get("rawCasePayloadStored") is not False
        ):
            raise Phase6Error("CONSUMPTION_REGISTRY_MISMATCH", "The package-private consumption registry does not bind this report.")
    return {
        "familySetHash": family_set_hash,
        "familyHashes": family_hashes,
        "marker": marker_name,
        "provenanceReceiptSha256": str(answer_evaluation.get("provenanceReceiptSha256", "")),
    }


def _score_answer(answer: dict[str, Any] | None, expected: dict[str, Any], retrieved: set[str]) -> dict[str, Any]:
    if answer is None:
        return {"status": "not_run", "correct": None, "grounded": None, "unsupportedClaims": 0, "claimsDeclared": False}
    expected_answer = expected["answer"]
    mode = expected_answer["mode"]
    abstained = bool(answer.get("abstained", False))
    answer_text = str(answer.get("answerText", ""))
    claims = _as_list(answer.get("claims"))
    declared_count = answer.get("claimCount")
    try:
        claims_declared = int(declared_count) == len(claims)
    except (TypeError, ValueError):
        claims_declared = False
    unsupported = 0
    for claim in claims:
        if not isinstance(claim, dict):
            unsupported += 1
            continue
        evidence_ids = {_safe_id(value, "claim evidence id") for value in _as_list(claim.get("evidenceIds"))}
        if not evidence_ids or not evidence_ids.issubset(retrieved):
            unsupported += 1
    if mode == "abstain":
        correct = abstained and not answer_text.strip() and len(claims) == 0 and claims_declared
        grounded = correct
        unsupported += 0 if grounded else 1
    else:
        phrase_matches = [phrase.casefold() in answer_text.casefold() for phrase in expected_answer["requiredPhrases"]]
        correct = (not abstained) and bool(phrase_matches) and all(phrase_matches)
        grounded = claims_declared and len(claims) > 0 and unsupported == 0
    return {
        "status": "scored",
        "correct": bool(correct),
        "grounded": bool(grounded),
        "unsupportedClaims": unsupported,
        "claimsDeclared": claims_declared,
    }


def _rate(values: list[bool]) -> float | None:
    if not values:
        return None
    return round(sum(1 for value in values if value) / len(values), 6)


def _gate(gate_id: str, observed: Any, required: Any, met: bool | None) -> dict[str, Any]:
    return {"id": gate_id, "observed": observed, "required": required, "met": met}


def run_evaluation(
    root: Path,
    sealed: dict[str, Any],
    answer_artifact: dict[str, Any] | None,
    consume: bool,
    output_path: Path,
    marker_path: Path | None,
    answer_input: dict[str, Any] | None = None,
    allow_diagnostic_synthetic: bool = False,
    consumption_registry_root: Path | None = None,
) -> dict[str, Any]:
    output_path = output_path.resolve()
    if output_path.exists():
        raise Phase6Error("OUTPUT_EXISTS", "Refusing to overwrite an existing evaluation artifact.")
    marker_path = _resolve_consumption_marker(output_path, marker_path) if consume else None
    if consume and marker_path is not None and marker_path.exists():
        raise Phase6Error("HOLDOUT_ALREADY_CONSUMED", "This Phase 6 sealed holdout has already been consumed.")
    answers, provenance_kind, answer_input_hash = _answer_index(
        root, answer_artifact, sealed, answer_input, allow_diagnostic_synthetic
    )
    binding = _current_binding(root)
    if consume and answers is None:
        raise Phase6Error("ANSWER_ARTIFACT_REQUIRED_FOR_CONSUME", "A consumed Phase 6 holdout requires a scored answer artifact.")
    registry_path = _reserve_consumption(root, sealed, binding, consumption_registry_root) if consume else None
    case_rows: list[dict[str, Any]] = []
    for sealed_case in sealed["cases"]:
        payload = sealed_case["payload"]
        workspace_key = "phase6-" + _sha256(str(sealed_case["caseHash"]))[:16]
        with tempfile.TemporaryDirectory(prefix="super-brain-phase6-") as directory:
            state_root = Path(directory) / "state"
            _initialize_isolated_state(root, state_root)
            writes = [
                _write_record(root, state_root, workspace_key, record)
                for record in payload["records"]
            ]
            record_sources = _source_record_ids(state_root)
            expected_ids = set(payload["expected"]["evidenceIds"])
            written_ids = set(record_sources.values())
            ingestion_ok = all(writes) and len(writes) == len(payload["records"])
            oracle_available = expected_ids.issubset(written_ids)
            core = BrainCore(root, state_root / "shared")
            ranked = core.evaluation_ranked_evidence(
                payload["query"], rank_limit=MAX_RANK, query_date=payload["queryDate"]
            )
            retrieved = [record_sources.get(str(item.get("source", "")), "") for item in ranked]
            retrieved = [value for value in retrieved if value]
            retrieved_at_4 = set(retrieved[:4])
            retrieved_at_10 = set(retrieved[:10])
            answer_mode = str(payload["expected"]["answer"]["mode"])
            if expected_ids:
                hit_at_4 = expected_ids.issubset(retrieved_at_4)
                hit_at_10 = expected_ids.issubset(retrieved_at_10)
                evidence_sufficient = hit_at_4
            elif answer_mode == "abstain":
                # Abstention cases have no positive evidence target.  A normal
                # top-N recall can still contain unrelated context, so it must
                # not turn a correct, grounded abstention into a false recall
                # or E2E failure.  The no-claim abstention check in
                # _score_answer is the negative-evidence guard for this case.
                hit_at_4 = True
                hit_at_10 = True
                evidence_sufficient = True
            else:
                # New sources reject this shape, while legacy sealed payloads
                # remain fail-closed instead of receiving abstention semantics.
                hit_at_4 = False
                hit_at_10 = False
                evidence_sufficient = False
            answer = _score_answer(answers[str(sealed_case["id"])] if answers else None, payload["expected"], retrieved_at_4)
            e2e_pass = bool(ingestion_ok and oracle_available and evidence_sufficient and answer["correct"] and answer["grounded"])
            case_rows.append(
                {
                    "caseId": str(sealed_case["id"]),
                    "caseHash": str(sealed_case["caseHash"]),
                    "category": payload["category"],
                    "recordCount": len(payload["records"]),
                    "ingestion": {"ok": ingestion_ok, "writtenRecordCount": len(written_ids)},
                    "oracleEvidenceAvailable": oracle_available,
                    "retrieval": {
                        "expectedEvidenceCount": len(expected_ids),
                        "retrievedEvidenceIds": retrieved[:MAX_RANK],
                        "hitAt4": hit_at_4,
                        "hitAt10": hit_at_10,
                        "evidenceSufficient": evidence_sufficient,
                    },
                    "answer": answer,
                    "e2ePass": e2e_pass if answer["status"] == "scored" else None,
                }
            )

    category_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in case_rows:
        category_rows[str(row["category"])].append(row)
    answer_scored = all(row["answer"]["status"] == "scored" for row in case_rows)
    answer_provenance_receipt = (
        _sha256(answer_artifact.get("provenance", {}))
        if answer_scored and isinstance(answer_artifact, dict) and provenance_kind in BLINDED_ANSWER_PROVENANCE_KINDS
        else ""
    )
    categories: dict[str, dict[str, Any]] = {}
    for category, rows in sorted(category_rows.items()):
        category_e2e = _rate([bool(row["e2ePass"]) for row in rows]) if answer_scored else None
        categories[category] = {
            "caseCount": len(rows),
            "oracleRate": _rate([bool(row["oracleEvidenceAvailable"]) for row in rows]),
            "recallAt4": _rate([bool(row["retrieval"]["hitAt4"]) for row in rows]),
            "recallAt10": _rate([bool(row["retrieval"]["hitAt10"]) for row in rows]),
            "e2eRate": category_e2e,
            "meetsCategoryGate": None if category_e2e is None else category_e2e >= THRESHOLDS["category"],
        }
    unsupported = sum(int(row["answer"]["unsupportedClaims"]) for row in case_rows)
    overall = {
        "caseCount": len(case_rows),
        "ingestionRate": _rate([bool(row["ingestion"]["ok"]) for row in case_rows]),
        "oracleRate": _rate([bool(row["oracleEvidenceAvailable"]) for row in case_rows]),
        "recallAt4": _rate([bool(row["retrieval"]["hitAt4"]) for row in case_rows]),
        "recallAt10": _rate([bool(row["retrieval"]["hitAt10"]) for row in case_rows]),
        "evidenceSufficiencyRate": _rate([bool(row["retrieval"]["evidenceSufficient"]) for row in case_rows]),
        "groundingRate": _rate([bool(row["answer"]["grounded"]) for row in case_rows]) if answer_scored else None,
        "answerCorrectRate": _rate([bool(row["answer"]["correct"]) for row in case_rows]) if answer_scored else None,
        "e2eRate": _rate([bool(row["e2ePass"]) for row in case_rows]) if answer_scored else None,
        "unsupportedClaimCount": unsupported if answer_scored else None,
    }
    category_gate = None if not answer_scored else all(value["meetsCategoryGate"] for value in categories.values())
    gates = [
        _gate("oracle_at_least_95", overall["oracleRate"], THRESHOLDS["oracle"], overall["oracleRate"] >= THRESHOLDS["oracle"]),
        _gate("recall_at_4_at_least_95", overall["recallAt4"], THRESHOLDS["recallAt4"], overall["recallAt4"] >= THRESHOLDS["recallAt4"]),
        _gate("recall_at_10_at_least_95", overall["recallAt10"], THRESHOLDS["recallAt10"], overall["recallAt10"] >= THRESHOLDS["recallAt10"]),
        _gate("category_e2e_at_least_85", {key: value["e2eRate"] for key, value in categories.items()}, THRESHOLDS["category"], category_gate),
        _gate("unsupported_claims_at_most_1", overall["unsupportedClaimCount"], THRESHOLDS["unsupported"], None if not answer_scored else unsupported <= THRESHOLDS["unsupported"]),
        _gate("fresh_sealed_e2e_at_least_90", overall["e2eRate"], THRESHOLDS["e2e"], None if not answer_scored else overall["e2eRate"] >= THRESHOLDS["e2e"]),
    ]
    report_status = "retrieval_only_not_scored"
    if answer_scored:
        report_status = "diagnostic_non_publishable" if provenance_kind == "synthetic_test_adapter" else "internal_acceptance_only"
    report = {
        "schema": REPORT_SCHEMA,
        "status": report_status,
        "generatedAt": _utc_now(),
        "packageVersion": binding["packageVersion"],
        "evidenceBinding": binding,
        "holdout": {
            "setHash": sealed["setHash"],
            "familySetHash": sealed["familySetHash"],
            "familyHashes": list(sealed["familyHashes"]),
            "caseCount": sealed["caseCount"],
            "rawCasePayloadStored": False,
        },
        "privacy": {"rawCasePayloadStored": False, "rawAnswersStored": False, "realUserMemoryRead": False},
        "answerEvaluation": {
            "present": answer_scored,
            "artifactHash": _sha256(answer_artifact) if answer_artifact else "",
            "inputHash": answer_input_hash,
            "provenanceKind": provenance_kind,
            "provenanceBound": bool(answer_scored and provenance_kind in BLINDED_ANSWER_PROVENANCE_KINDS),
            "provenanceReceiptSha256": answer_provenance_receipt,
            "claimCoverage": "declared_claims_only" if answer_scored else "not_run",
            "method": "deterministic_required_phrases_and_evidence_links" if answer_scored else "not_run",
        },
        "thresholds": THRESHOLDS,
        "overall": overall,
        "categories": categories,
        "gates": gates,
        "cases": case_rows,
        "consumption": {
            "requested": consume,
            "consumed": consume,
            "markerFile": marker_path.name if marker_path is not None else "",
            "registryFile": registry_path.name if registry_path is not None else "",
        },
        "objectiveIntelligenceScore": False,
        "guard": "No raw case payload, answer text, or user memory is emitted. A separate aggregate of two fresh consumed sealed runs is required for the E2E gate.",
    }
    _write_json(output_path, report)
    report_hash = _file_sha256(output_path)
    if consume:
        assert marker_path is not None
        assert registry_path is not None
        marker = {
            "schema": CONSUMPTION_SCHEMA,
            "consumedAt": _utc_now(),
            "setHash": sealed["setHash"],
            "reportHash": report_hash,
            "rawCasePayloadStored": False,
        }
        _write_json(marker_path, marker)
        _complete_consumption(registry_path, sealed, binding, report_hash)
    report["reportHash"] = report_hash
    return report


def aggregate_reports(
    root: Path,
    paths: list[Path],
    output_path: Path,
    allow_diagnostic_synthetic: bool = False,
    consumption_registry_root: Path | None = None,
) -> dict[str, Any]:
    if len(paths) < 2:
        raise Phase6Error("AGGREGATE_REPORT_COUNT", "Two fresh sealed E2E reports are required.")
    reports = [_read_json(path, "REPORT_INVALID") for path in paths]
    if any(str(item.get("schema", "")) != REPORT_SCHEMA for item in reports):
        raise Phase6Error("AGGREGATE_REPORT_SCHEMA", "A report has an unsupported schema.")
    report_paths = [path.resolve() for path in paths]
    consumption = [
        _assert_consumed_report(root, path, item, allow_diagnostic_synthetic, consumption_registry_root)
        for path, item in zip(report_paths, reports)
    ]
    set_hashes = [str(item.get("holdout", {}).get("setHash", "")) for item in reports]
    if len(set(set_hashes)) != len(set_hashes):
        raise Phase6Error("AGGREGATE_HOLDOUT_REUSE", "Fresh E2E reports must use distinct sealed holdouts.")
    family_set_hashes = [item["familySetHash"] for item in consumption]
    if len(set(family_set_hashes)) != len(family_set_hashes):
        raise Phase6Error("AGGREGATE_FAMILY_REUSE", "Fresh E2E reports must use distinct memory families.")
    for index, left in enumerate(consumption):
        for right in consumption[index + 1 :]:
            if left["familyHashes"].intersection(right["familyHashes"]):
                raise Phase6Error("AGGREGATE_FAMILY_OVERLAP", "Fresh E2E reports must not overlap any memory family.")
    if not allow_diagnostic_synthetic:
        provenance_receipts = [str(item["provenanceReceiptSha256"]) for item in consumption]
        if len(set(provenance_receipts)) != len(provenance_receipts):
            raise Phase6Error("AGGREGATE_GENERATOR_RUN_REUSE", "Fresh E2E reports must use distinct external generator provenance receipts.")
    binding_hashes = {_sha256(item.get("evidenceBinding", {})) for item in reports}
    if len(binding_hashes) != 1:
        raise Phase6Error("AGGREGATE_BINDING_MISMATCH", "Fresh runs must bind the same runtime revision.")
    current_binding = _current_binding(root)
    now = datetime.now(timezone.utc)
    fresh = True
    individual_gate_results: list[bool] = []
    unmet_gate_ids: set[str] = set()
    for report in reports:
        try:
            generated = datetime.fromisoformat(str(report.get("generatedAt", "")).replace("Z", "+00:00"))
            age_seconds = (now - generated.astimezone(timezone.utc)).total_seconds()
            fresh = fresh and 0 <= age_seconds <= FRESHNESS_HOURS * 3600
        except (TypeError, ValueError):
            fresh = False
        required = {
            "oracle_at_least_95",
            "recall_at_4_at_least_95",
            "recall_at_10_at_least_95",
            "category_e2e_at_least_85",
            "unsupported_claims_at_most_1",
            "fresh_sealed_e2e_at_least_90",
        }
        gates = {str(item.get("id")): item.get("met") for item in _as_list(report.get("gates")) if isinstance(item, dict)}
        unmet_gate_ids.update(gate_id for gate_id in required if gates.get(gate_id) is not True)
        individual_gate_results.append(all(gates.get(gate_id) is True for gate_id in required))
        if not allow_diagnostic_synthetic:
            if int(report.get("holdout", {}).get("caseCount", 0)) < MIN_CASES_PER_REAL_SET:
                raise Phase6Error("AGGREGATE_SAMPLE_TOO_SMALL", "Each real Phase 6 set needs enough cases for an aggregate claim.")
            if len(report.get("categories", {})) < MIN_CATEGORIES_PER_REAL_SET:
                raise Phase6Error("AGGREGATE_CATEGORY_COVERAGE_INSUFFICIENT", "Each real Phase 6 set needs broad category coverage.")
    result = {
        "schema": AGGREGATE_SCHEMA,
        "status": "diagnostic_non_publishable" if allow_diagnostic_synthetic else "internal_acceptance_only",
        "generatedAt": _utc_now(),
        "reportCount": len(reports),
        "holdoutSetHashes": set_hashes,
        "familySetHashes": family_set_hashes,
        "evidenceBinding": current_binding,
        "bindingHash": _sha256(current_binding),
        "fresh": fresh,
        "twoFreshSealedE2EAtLeast90": len(reports) >= 2 and fresh and all(individual_gate_results),
        "unmetGateIds": sorted(unmet_gate_ids),
        "rawCasePayloadStored": False,
        "minimumCasesPerRealSet": MIN_CASES_PER_REAL_SET,
        "minimumCategoriesPerRealSet": MIN_CATEGORIES_PER_REAL_SET,
        "objectiveIntelligenceScore": False,
    }
    _write_json(output_path, result)
    return result


def _self_test_source(set_id: str, suffix: str) -> dict[str, Any]:
    return {
        "schema": SOURCE_SCHEMA,
        "setId": set_id,
        "cases": [
            {
                "id": f"retrieval-{suffix}",
                "category": "information_extraction",
                "familyId": f"atlas-family-{suffix}",
                "records": [{"id": f"atlas-{suffix}", "text": "[CURRENT][VERIFIED] Atlas delivery channel is aurora.", "layer": "project"}],
                "query": "Atlas delivery channel",
                "expected": {"evidenceIds": [f"atlas-{suffix}"], "answer": {"mode": "answer", "requiredPhrases": ["aurora"]}},
            },
            {
                "id": f"multi-{suffix}",
                "familyId": f"helios-family-{suffix}",
                "category": "multi_session_reasoning",
                "records": [
                    {"id": f"helios-a-{suffix}", "text": "[CURRENT][VERIFIED] Helios uses signed manifests.", "layer": "project"},
                    {"id": f"helios-b-{suffix}", "text": "[CURRENT][VERIFIED] Helios review owner is delta team.", "layer": "project"},
                ],
                "query": "Helios signed manifests review owner",
                "expected": {"evidenceIds": [f"helios-a-{suffix}", f"helios-b-{suffix}"], "answer": {"mode": "answer", "requiredPhrases": ["signed", "delta"]}},
            },
            {
                "id": f"update-{suffix}",
                "familyId": f"meridian-family-{suffix}",
                "category": "knowledge_update",
                "records": [
                    {"id": f"meridian-old-{suffix}", "text": "[HISTORY][VERIFIED] Meridian backup channel was cobalt.", "layer": "project"},
                    {"id": f"meridian-new-{suffix}", "text": "[CURRENT][VERIFIED] Meridian backup channel is amber.", "layer": "project"},
                ],
                "query": "current Meridian backup channel",
                "expected": {"evidenceIds": [f"meridian-new-{suffix}"], "answer": {"mode": "answer", "requiredPhrases": ["amber"]}},
            },
            {
                "id": f"unknown-{suffix}",
                "familyId": f"orion-family-{suffix}",
                "category": "unsupported_unknown",
                "records": [],
                "query": "What is the unavailable Orion secret code",
                "expected": {"evidenceIds": [], "answer": {"mode": "abstain", "requiredPhrases": []}},
            },
        ],
    }


def _synthetic_answers(sealed: dict[str, Any]) -> dict[str, Any]:
    cases: list[dict[str, Any]] = []
    for item in sealed["cases"]:
        payload = item["payload"]
        answer = payload["expected"]["answer"]
        evidence = payload["expected"]["evidenceIds"]
        if answer["mode"] == "abstain":
            cases.append({"id": item["id"], "caseHash": item["caseHash"], "abstained": True, "answerText": "", "claimCount": 0, "claims": []})
        else:
            cases.append({"id": item["id"], "caseHash": item["caseHash"], "abstained": False, "answerText": " ".join(answer["requiredPhrases"]), "claimCount": 1, "claims": [{"id": "claim-1", "evidenceIds": evidence}]})
    return {"schema": ANSWER_SCHEMA, "setHash": sealed["setHash"], "cases": cases, "provenance": {"kind": "synthetic_test_adapter", "independentJudge": False}}


def self_test(root: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-self-test-") as directory:
        base = Path(directory)
        reports: list[Path] = []
        for suffix in ("a", "b"):
            sealed = seal_source(_self_test_source(f"phase6-self-test-{suffix}", suffix))
            sealed_path = base / f"{suffix}.sealed.json"
            report_path = base / f"{suffix}.report.json"
            marker_path = base / f"{suffix}.consumed.json"
            _write_json(sealed_path, sealed)
            run_evaluation(
                root,
                sealed,
                _synthetic_answers(sealed),
                True,
                report_path,
                marker_path,
                allow_diagnostic_synthetic=True,
                consumption_registry_root=base / "consumption",
            )
            reports.append(report_path)
        aggregate_path = base / "aggregate.json"
        aggregate = aggregate_reports(root, reports, aggregate_path, allow_diagnostic_synthetic=True)
        return {
            "ok": bool(aggregate["twoFreshSealedE2EAtLeast90"]),
            "schema": "super-brain.memory-e2e-self-test.v1",
            "status": "diagnostic_non_publishable",
            "aggregate": aggregate,
            "rawCasePayloadStored": False,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="Super Brain Phase 6 memory E2E evaluator")
    subparsers = parser.add_subparsers(dest="action", required=True)
    seal_parser = subparsers.add_parser("seal")
    seal_parser.add_argument("--source", required=True)
    seal_parser.add_argument("--output", required=True)
    answer_input_parser = subparsers.add_parser("prepare-answer-input")
    answer_input_parser.add_argument("--sealed", required=True)
    answer_input_parser.add_argument("--output", required=True)
    validate_answer_input_parser = subparsers.add_parser("validate-answer-input")
    validate_answer_input_parser.add_argument("--answer-input", required=True)
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--sealed", required=True)
    run_parser.add_argument("--output", required=True)
    run_parser.add_argument("--answer-artifact", default="")
    run_parser.add_argument("--answer-input", default="")
    run_parser.add_argument("--consume", action="store_true")
    run_parser.add_argument("--consumed-marker", default="")
    aggregate_parser = subparsers.add_parser("aggregate")
    aggregate_parser.add_argument("--reports", nargs="+", required=True)
    aggregate_parser.add_argument("--output", required=True)
    subparsers.add_parser("self-test")
    args = parser.parse_args()
    root = _package_root()
    try:
        if args.action == "seal":
            source = _read_json(Path(args.source), "SOURCE_INVALID")
            sealed = seal_source(source)
            _write_json(Path(args.output), sealed)
            result = {"ok": True, "action": "seal", "setHash": sealed["setHash"], "caseCount": sealed["caseCount"], "rawCasePayloadStored": False}
        elif args.action == "prepare-answer-input":
            sealed = verify_sealed(_read_json(Path(args.sealed), "SEALED_INVALID"))
            answer_input = prepare_answer_input(root, sealed)
            _write_json(Path(args.output), answer_input)
            result = {
                "ok": True,
                "action": "prepare-answer-input",
                "setHash": sealed["setHash"],
                "inputHash": answer_input["inputHash"],
                "caseCount": sealed["caseCount"],
                "privateArtifact": True,
                "rawExpectedDataStored": False,
            }
        elif args.action == "validate-answer-input":
            answer_input = _read_json(Path(args.answer_input), "ANSWER_INPUT_INVALID")
            input_hash, cases = _validate_private_answer_input(root, answer_input)
            result = {
                "ok": True,
                "action": "validate-answer-input",
                "setHash": str(answer_input["setHash"]),
                "inputHash": input_hash,
                "caseCount": len(cases),
                "privateArtifact": True,
                "rawExpectedDataStored": False,
            }
        elif args.action == "run":
            sealed_path = Path(args.sealed)
            sealed = verify_sealed(_read_json(sealed_path, "SEALED_INVALID"))
            marker_path = Path(args.consumed_marker) if args.consumed_marker else None
            answer = _read_json(Path(args.answer_artifact), "ANSWER_ARTIFACT_INVALID") if args.answer_artifact else None
            answer_input = _read_json(Path(args.answer_input), "ANSWER_INPUT_INVALID") if args.answer_input else None
            result = run_evaluation(root, sealed, answer, bool(args.consume), Path(args.output), marker_path, answer_input)
            result["ok"] = True
        elif args.action == "aggregate":
            result = aggregate_reports(root, [Path(value) for value in args.reports], Path(args.output))
            result["ok"] = True
        else:
            result = self_test(root)
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0 if result.get("ok", True) else 1
    except Phase6Error as exc:
        print(json.dumps({"ok": False, "code": exc.code, "error": str(exc), "rawCasePayloadStored": False}, ensure_ascii=False, separators=(",", ":")))
        return 1
    except (OSError, subprocess.SubprocessError, sqlite3.Error) as exc:
        print(json.dumps({"ok": False, "code": "PHASE6_RUNTIME_FAILURE", "error": type(exc).__name__, "rawCasePayloadStored": False}, ensure_ascii=False, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
