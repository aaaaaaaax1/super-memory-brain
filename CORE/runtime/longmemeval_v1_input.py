"""Prepare isolated paired LongMemEval v1 answer inputs.

This module deliberately stops before any model request.  It validates the
pinned official harness and a locally hashed ``longmemeval_s_cleaned.json``,
then produces private baseline/treatment inputs for the existing blinded
diagnostic runner.  Treatment retrieval is performed in a fresh Sandglass
root for every question, so one benchmark case can never supply context to
another case or to the user's normal memory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


RUNTIME_ROOT = Path(__file__).resolve().parent
if str(RUNTIME_ROOT) not in sys.path:
    sys.path.insert(0, str(RUNTIME_ROOT))

from brain_core import BrainCore
from layout_paths import state_root as resolve_state_root


PREPARER_SCHEMA = "super-brain.longmemeval-v1-input-preparer.v1"
SOURCE_MANIFEST_SCHEMA = "super-brain.longmemeval-v1-source-manifest.v1"
SELECTION_SCHEMA = "super-brain.longmemeval-v1-selection.v1"
PAIR_CONTRACT_SCHEMA = "super-brain.objective-pair-contract.v1"
ANSWER_INPUT_SCHEMA = "super-brain.objective-answer-input.v1"
BENCHMARK_ID = "longmemeval"
BENCHMARK_VARIANT = "s_cleaned"
OFFICIAL_REPO = "https://github.com/xiaowu0162/LongMemEval"
OFFICIAL_COMMIT = "9e0b455f4ef0e2ab8f2e582289761153549043fc"
OFFICIAL_DATA_URL = (
    "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/"
    "longmemeval_s_cleaned.json"
)
EXPECTED_CASE_COUNT = 500
MAX_RETRIEVAL_TOP_K = 10
MAX_RETRIEVAL_TOKENS = 2000
_RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$")
_DATE_RE = re.compile(r"(?P<year>\d{4})[-/](?P<month>\d{1,2})[-/](?P<day>\d{1,2})")
_FORBIDDEN_HISTORY_FIELDS = frozenset(
    {
        "answer",
        "rubric",
        "reference",
        "evaluation",
        "eval_function",
        "autoeval_label",
        "label",
        "grade",
        "target",
        "answer_session_ids",
        "answer_turn_ids",
    }
)


class LongMemEvalV1InputError(RuntimeError):
    """Raised when a paired LongMemEval input cannot be safely prepared."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise LongMemEvalV1InputError(message)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_text(value: str) -> str:
    return _sha256_bytes(value.encode("utf-8"))


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _read_json(path: Path, code: str) -> Any:
    _require(path.is_file(), f"{code}: required file is missing: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise LongMemEvalV1InputError(f"{code}: required JSON file is invalid: {path}") from error


def _write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.{next(tempfile._get_candidate_names())}.tmp")
    try:
        temporary.write_bytes(_canonical_json(value) + b"\n")
        temporary.replace(path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _nonempty_text(value: Any, field: str, maximum: int = 120_000) -> str:
    _require(isinstance(value, str), f"LME_V1_FIELD_INVALID: {field} must be a string.")
    clean = " ".join(value.split()).strip()
    _require(bool(clean), f"LME_V1_FIELD_INVALID: {field} must not be empty.")
    _require(len(clean) <= maximum, f"LME_V1_FIELD_INVALID: {field} exceeds its bounded size.")
    return clean


def _answer_text(value: Any, field: str) -> str:
    """LongMemEval's reference answers are mostly text, with some numeric labels."""

    if isinstance(value, bool):
        raise LongMemEvalV1InputError(f"LME_V1_FIELD_INVALID: {field} must not be Boolean.")
    if isinstance(value, (int, float)):
        return _nonempty_text(str(value), field, 24_000)
    return _nonempty_text(value, field, 24_000)


def _normalise_date(value: Any, field: str) -> str:
    text = _nonempty_text(value, field, 160)
    match = _DATE_RE.search(text)
    _require(match is not None, f"LME_V1_DATE_INVALID: {field} must contain YYYY-MM-DD or YYYY/MM/DD.")
    try:
        return datetime(
            int(match.group("year")), int(match.group("month")), int(match.group("day"))
        ).strftime("%Y-%m-%d")
    except ValueError as error:
        raise LongMemEvalV1InputError(f"LME_V1_DATE_INVALID: {field} is not a calendar date.") from error


def _safe_component(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]


def _run_git(root: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError as error:
        raise LongMemEvalV1InputError("LME_V1_GIT_UNAVAILABLE: git is required to validate the official harness.") from error
    if result.returncode != 0:
        raise LongMemEvalV1InputError(f"LME_V1_HARNESS_INVALID: git {' '.join(arguments)} failed.")
    return result.stdout.strip()


def _harness_binding(harness_root: Path) -> dict[str, str]:
    root = harness_root.expanduser().resolve()
    _require(root.is_dir(), "LME_V1_HARNESS_MISSING: the official LongMemEval checkout is missing.")
    head = _run_git(root, "rev-parse", "HEAD")
    _require(head == OFFICIAL_COMMIT, "LME_V1_HARNESS_PIN_MISMATCH: the checkout is not at the pinned official commit.")
    _require(not _run_git(root, "status", "--porcelain"), "LME_V1_HARNESS_DIRTY: the pinned official checkout must be clean.")
    tree = _run_git(root, "rev-parse", "HEAD^{tree}")
    harness_sha = _sha256_text(f"{OFFICIAL_REPO}\n{head}\n{tree}")
    return {
        "officialRepo": OFFICIAL_REPO,
        "pinnedCommit": head,
        "gitTree": tree,
        "harnessSha256": harness_sha,
    }


def _source_manifest_path(data_path: Path) -> Path:
    return data_path.parent / "super-brain-source-manifest.json"


def _load_source_manifest(data_path: Path) -> dict[str, Any]:
    manifest_path = _source_manifest_path(data_path)
    value = _read_json(manifest_path, "LME_V1_SOURCE_MANIFEST_REQUIRED")
    _require(isinstance(value, dict), "LME_V1_SOURCE_MANIFEST_INVALID: source manifest must be an object.")
    _require(value.get("schema") == SOURCE_MANIFEST_SCHEMA, "LME_V1_SOURCE_MANIFEST_INVALID: unsupported source manifest schema.")
    _require(value.get("benchmarkId") == BENCHMARK_ID, "LME_V1_SOURCE_MANIFEST_INVALID: unexpected benchmark id.")
    _require(value.get("variant") == BENCHMARK_VARIANT, "LME_V1_SOURCE_MANIFEST_INVALID: unexpected benchmark variant.")
    _require(value.get("sourceUrl") == OFFICIAL_DATA_URL, "LME_V1_SOURCE_MANIFEST_INVALID: source URL is not the official s_cleaned endpoint.")
    expected_sha = str(value.get("dataSha256", "")).lower()
    _require(re.fullmatch(r"[0-9a-f]{64}", expected_sha) is not None, "LME_V1_SOURCE_MANIFEST_INVALID: data SHA-256 is missing.")
    actual_sha = _sha256_file(data_path)
    _require(actual_sha == expected_sha, "LME_V1_SOURCE_SHA_MISMATCH: data no longer matches its acquired source manifest.")
    count = value.get("caseCount")
    _require(isinstance(count, int) and count == EXPECTED_CASE_COUNT, "LME_V1_SOURCE_MANIFEST_INVALID: source manifest does not bind a 500-case split.")
    return {
        "path": str(manifest_path.resolve()),
        "sha256": _sha256_file(manifest_path),
        "dataSha256": actual_sha,
        "sourceUrl": OFFICIAL_DATA_URL,
        "caseCount": count,
    }


def _read_dataset(data_path: Path) -> list[dict[str, Any]]:
    value = _read_json(data_path, "LME_V1_DATA_INVALID")
    _require(isinstance(value, list), "LME_V1_DATA_INVALID: s_cleaned must be a JSON array.")
    _require(len(value) == EXPECTED_CASE_COUNT, "LME_V1_CASE_COUNT_INVALID: s_cleaned must contain exactly 500 cases.")
    _require(all(isinstance(item, dict) for item in value), "LME_V1_DATA_INVALID: every benchmark case must be an object.")
    return list(value)


def _case_rubric(question_type: str, question_id: str) -> str:
    if question_id.endswith("_abs"):
        return "The response must correctly state that the requested information is unsupported or unavailable from the history."
    if question_type == "temporal-reasoning":
        return "The response must be correct from the dated history; a one-unit day/week/month off-by-one is acceptable when otherwise correct."
    if question_type == "knowledge-update":
        return "The response must use the latest applicable information; older information may be mentioned only when it does not replace the update."
    if question_type == "single-session-preference":
        return "The response must correctly recall and use the user's relevant personal preference or information."
    return "The response must contain the complete correct answer supported by the chat history."


def _normalise_case(raw: dict[str, Any], position: int) -> dict[str, Any]:
    prefix = f"cases[{position}]"
    question_id = _nonempty_text(raw.get("question_id"), f"{prefix}.question_id", 160)
    question_type = _nonempty_text(raw.get("question_type"), f"{prefix}.question_type", 160)
    question = _nonempty_text(raw.get("question"), f"{prefix}.question", 24_000)
    answer = _answer_text(raw.get("answer"), f"{prefix}.answer")
    question_date = _normalise_date(raw.get("question_date"), f"{prefix}.question_date")
    sessions = raw.get("haystack_sessions")
    dates = raw.get("haystack_dates")
    session_ids = raw.get("haystack_session_ids")
    _require(isinstance(sessions, list) and sessions, f"LME_V1_HISTORY_INVALID: {prefix}.haystack_sessions is required.")
    _require(isinstance(dates, list) and len(dates) == len(sessions), f"LME_V1_HISTORY_INVALID: {prefix}.haystack_dates must align with sessions.")
    _require(isinstance(session_ids, list) and len(session_ids) == len(sessions), f"LME_V1_HISTORY_INVALID: {prefix}.haystack_session_ids must align with sessions.")
    return {
        "id": question_id,
        "questionType": question_type,
        "question": question,
        "answer": answer,
        "questionDate": question_date,
        "sessions": sessions,
        "sessionDates": dates,
        "sessionIds": session_ids,
        "rubric": _case_rubric(question_type, question_id),
    }


def _normalise_cases(data: list[dict[str, Any]]) -> list[dict[str, Any]]:
    cases = [_normalise_case(value, index) for index, value in enumerate(data)]
    seen: set[str] = set()
    for case in cases:
        case_id = str(case["id"])
        _require(case_id not in seen, f"LME_V1_CASE_ID_DUPLICATE: duplicate question_id {case_id}.")
        seen.add(case_id)
    return cases


def _session_turns(case: dict[str, Any]) -> tuple[list[tuple[str, str, str, str]], int, int]:
    """Return allowlisted turns plus stripped-label and skipped-empty counts."""

    turns: list[tuple[str, str, str, str]] = []
    labels_stripped = 0
    empty_turns_skipped = 0
    for session_index, (session, raw_date, raw_session_id) in enumerate(
        zip(case["sessions"], case["sessionDates"], case["sessionIds"]), start=1
    ):
        _require(isinstance(session, list), f"LME_V1_HISTORY_INVALID: {case['id']} session {session_index} must be a turn list.")
        session_date = _normalise_date(raw_date, f"{case['id']}.haystack_dates[{session_index - 1}]")
        session_id = _nonempty_text(raw_session_id, f"{case['id']}.haystack_session_ids[{session_index - 1}]", 240)
        for turn_index, turn in enumerate(session, start=1):
            _require(isinstance(turn, dict), f"LME_V1_HISTORY_INVALID: {case['id']} contains a non-object turn.")
            keys = {str(key).strip().lower() for key in turn.keys()}
            forbidden = keys & _FORBIDDEN_HISTORY_FIELDS
            _require(not forbidden, f"LME_V1_HISTORY_LABEL_LEAK: {case['id']} turn carries forbidden field(s): {','.join(sorted(forbidden))}.")
            if "has_answer" in keys:
                labels_stripped += 1
            role = _nonempty_text(turn.get("role"), f"{case['id']}.turn.role", 32).lower()
            _require(role in {"user", "assistant"}, f"LME_V1_HISTORY_INVALID: {case['id']} has unsupported turn role {role}.")
            if isinstance(turn.get("content"), str) and not str(turn.get("content")).strip():
                empty_turns_skipped += 1
                continue
            content = _nonempty_text(turn.get("content"), f"{case['id']}.turn.content", 120_000)
            turns.append((session_date, session_id, role, content))
    _require(turns, f"LME_V1_HISTORY_INVALID: {case['id']} has no admissible history turns.")
    return turns, labels_stripped, empty_turns_skipped


def _write_case_memory(case_root: Path, case: dict[str, Any]) -> tuple[int, int]:
    memory_root = case_root / "shared"
    memory_root.mkdir(parents=True, exist_ok=True)
    memory_path = memory_root / "sandglass.txt"
    turns, labels_stripped, empty_turns_skipped = _session_turns(case)
    lines: list[str] = []
    previous_date = ""
    sequence = 0
    base_time = datetime(2000, 1, 1, 12, 0, 0)
    for session_date, session_id, role, content in turns:
        try:
            day = datetime.strptime(session_date, "%Y-%m-%d")
        except ValueError:
            day = base_time
        if session_date != previous_date:
            sequence = 0
            previous_date = session_date
        timestamp = day.replace(hour=12, minute=0, second=0) + timedelta(seconds=sequence)
        sequence += 1
        text = (
            "[BENCHMARK][VERIFIED][SESSION] benchmark=longmemeval "
            f"question_id={case['id']} session_id={session_id} session_date={session_date} {content}"
        )
        lines.append(f"{timestamp:%Y-%m-%d %H:%M:%S} | {role} | {text}\n")
    memory_path.write_text("".join(lines), encoding="utf-8", newline="\n")
    return labels_stripped, empty_turns_skipped


def _retrieved_context(package_root: Path, scratch_root: Path, case: dict[str, Any]) -> tuple[str, int, int]:
    case_root = scratch_root / _safe_component(str(case["id"]))
    labels_stripped, empty_turns_skipped = _write_case_memory(case_root, case)
    core = BrainCore(package_root, case_root / "shared")
    evidence = core.recall(
        str(case["question"]),
        top_k=MAX_RETRIEVAL_TOP_K,
        max_tokens=MAX_RETRIEVAL_TOKENS,
        query_date=str(case["questionDate"]),
        _evaluation_top_k=MAX_RETRIEVAL_TOP_K,
    )
    texts = [str(item.get("text", "")).strip() for item in evidence if str(item.get("text", "")).strip()]
    context = ""
    if texts:
        blocks = [
            "[SUPER_BRAIN_LONGMEMEVAL_V1_EVIDENCE]",
            "Use only the isolated dated chat-history snippets below. Do not infer missing facts.",
        ]
        blocks.extend(f"Evidence {index}:\n{text}" for index, text in enumerate(texts, start=1))
        context = "\n\n".join(blocks)
    _require("has_answer" not in context.lower(), "LME_V1_HISTORY_LABEL_LEAK: stripped labels reached retrieved context.")
    return context, labels_stripped, empty_turns_skipped


def _case_shape_hash(case: dict[str, str]) -> str:
    return _sha256_text(f"{case['id']}\n{case['prompt']}\n{case['reference']}\n{case['rubric']}")


def _case_set_hash(cases: list[dict[str, str]]) -> str:
    parts = [f"{case['id']}\n{_case_shape_hash(case)}" for case in sorted(cases, key=lambda item: item["id"])]
    return _sha256_text("\n".join(parts))


def _selection_hash(case_ids: list[str], corpus_sha256: str, harness_sha256: str) -> str:
    return _sha256_bytes(
        _canonical_json(
            {
                "schema": SELECTION_SCHEMA,
                "benchmark": BENCHMARK_ID,
                "variant": BENCHMARK_VARIANT,
                "caseIds": case_ids,
                "corpusSha256": corpus_sha256,
                "harnessSha256": harness_sha256,
            }
        )
    )


def _assert_private_output_root(package_root: Path, output_root: Path) -> None:
    package = package_root.resolve()
    output = output_root.resolve()
    private_root = resolve_state_root(package)
    try:
        output.relative_to(private_root)
    except ValueError as error:
        raise LongMemEvalV1InputError("LME_V1_OUTPUT_NOT_PRIVATE: output root must be under package private-state.") from error


def _preflight(package_root: Path, harness_root: Path, data_path: Path, output_root: Path) -> dict[str, Any]:
    package = package_root.expanduser().resolve()
    data = data_path.expanduser().resolve()
    output = output_root.expanduser().resolve()
    _require((package / "manifest.json").is_file(), "LME_V1_PACKAGE_INVALID: manifest.json is missing.")
    _require((package / "runtime" / "brain_core.py").is_file(), "LME_V1_PACKAGE_INVALID: runtime/brain_core.py is missing.")
    _require(data.is_file(), "LME_V1_DATA_MISSING: longmemeval_s_cleaned.json is missing.")
    _assert_private_output_root(package, output)
    harness = _harness_binding(harness_root)
    source = _load_source_manifest(data)
    cases = _normalise_cases(_read_dataset(data))
    case_ids = [str(case["id"]) for case in cases]
    _require(len(case_ids) == EXPECTED_CASE_COUNT, "LME_V1_CASE_COUNT_INVALID: only a full 500-case split is allowed.")
    return {
        "packageRoot": package,
        "harness": harness,
        "source": source,
        "cases": cases,
        "caseIds": case_ids,
        "outputRoot": output,
    }


def prepare_answer_inputs(
    *,
    package_root: Path,
    harness_root: Path,
    data_path: Path,
    output_root: Path,
    run_id: str,
    model: str,
    reasoning_effort: str,
    max_output_tokens: int,
    timeout_seconds: int,
    batch_size: int,
    max_batch_attempts: int,
) -> dict[str, Any]:
    _require(_RUN_ID_RE.fullmatch(run_id) is not None, "LME_V1_RUN_ID_INVALID: run id must be a short safe identifier.")
    _require(max_batch_attempts == 1, "LME_V1_RETRY_POLICY_INVALID: paired generation must use exactly one attempt per batch.")
    _require(1 <= batch_size <= 20, "LME_V1_BUDGET_INVALID: batch size must be between 1 and 20.")
    _require(64 <= max_output_tokens <= 8192, "LME_V1_BUDGET_INVALID: max output tokens is outside the supported range.")
    _require(5 <= timeout_seconds <= 300, "LME_V1_BUDGET_INVALID: timeout seconds is outside the supported range.")
    state = _preflight(package_root, harness_root, data_path, output_root)
    package = Path(state["packageRoot"])
    root = Path(state["outputRoot"])
    run_root = root / run_id
    _require(not run_root.exists(), "LME_V1_OUTPUT_EXISTS: refusing to overwrite an existing preparation run.")
    run_root.mkdir(parents=True, exist_ok=False)
    scratch_root = Path(tempfile.mkdtemp(prefix="lme-v1-scratch-", dir=str(run_root)))
    try:
        normalized_cases: list[dict[str, str]] = []
        treatment_contexts: dict[str, str] = {}
        evidence_receipts: list[dict[str, Any]] = []
        labels_stripped = 0
        empty_turns_skipped = 0
        for raw_case in state["cases"]:
            prompt = f"Current date: {raw_case['questionDate']}\nQuestion: {raw_case['question']}"
            normalized = {
                "id": str(raw_case["id"]),
                "prompt": prompt,
                "reference": str(raw_case["answer"]),
                "rubric": str(raw_case["rubric"]),
            }
            context, case_labels_stripped, case_empty_turns_skipped = _retrieved_context(package, scratch_root, raw_case)
            labels_stripped += case_labels_stripped
            empty_turns_skipped += case_empty_turns_skipped
            treatment_contexts[normalized["id"]] = context
            evidence_receipts.append(
                {
                    "id": normalized["id"],
                    "retrievedContextSha256": _sha256_text(context),
                    "retrievedEvidenceCount": 0 if not context else context.count("\n\nEvidence "),
                    "labelsStripped": case_labels_stripped,
                    "emptyTurnsSkipped": case_empty_turns_skipped,
                }
            )
            normalized_cases.append(normalized)

        case_set_hash = _case_set_hash(normalized_cases)
        selection_sha = _selection_hash(state["caseIds"], state["source"]["dataSha256"], state["harness"]["harnessSha256"])
        generation_budget = {
            "modelId": model,
            "reasoningEffort": reasoning_effort,
            "maxOutputTokens": max_output_tokens,
            "timeoutSeconds": timeout_seconds,
            "batchSize": batch_size,
            "maxBatchAttempts": max_batch_attempts,
            "retrievalTopK": MAX_RETRIEVAL_TOP_K,
            "retrievalMaxTokens": MAX_RETRIEVAL_TOKENS,
        }
        pair_contract = {
            "schema": PAIR_CONTRACT_SCHEMA,
            "createdAt": _utc_now(),
            "benchmark": {
                "id": BENCHMARK_ID,
                "variant": BENCHMARK_VARIANT,
                **state["harness"],
                "corpusSha256": state["source"]["dataSha256"],
                "sourceManifestSha256": state["source"]["sha256"],
            },
            "selection": {
                "caseCount": EXPECTED_CASE_COUNT,
                "orderedCaseIdsSha256": _sha256_text("\n".join(state["caseIds"])),
                "selectionSha256": selection_sha,
                "caseSetHash": case_set_hash,
            },
            "generationBudget": generation_budget,
            "singleChangedVariable": "super_memory_brain_enabled",
            "baseline": {"superMemoryBrainEnabled": False, "retrievedContext": "must_be_empty"},
            "treatment": {
                "superMemoryBrainEnabled": True,
                "retrievalEngine": "BrainCore",
                "isolatedPerCase": True,
                "historyAllowlist": ["role", "content"],
                "strippedEvaluationLabel": "has_answer",
            },
            "publicationStatus": "source_verified_paired_diagnostic_non_publishable",
        }
        pair_contract_path = run_root / "pair-contract.json"
        _write_json_atomic(pair_contract_path, pair_contract)
        pair_contract_sha = _sha256_file(pair_contract_path)
        benchmark = {
            "id": BENCHMARK_ID,
            "variant": BENCHMARK_VARIANT,
            "corpusSha256": state["source"]["dataSha256"],
            "harnessSha256": state["harness"]["harnessSha256"],
            "selectionSha256": selection_sha,
        }
        pair_ref = {"path": str(pair_contract_path.resolve()), "sha256": pair_contract_sha}
        baseline_input = {
            "schema": ANSWER_INPUT_SCHEMA,
            "benchmark": benchmark,
            "pairContract": pair_ref,
            "condition": {"superMemoryBrainEnabled": False},
            "cases": [{**case, "retrievedContext": ""} for case in normalized_cases],
        }
        treatment_input = {
            "schema": ANSWER_INPUT_SCHEMA,
            "benchmark": benchmark,
            "pairContract": pair_ref,
            "condition": {"superMemoryBrainEnabled": True},
            "cases": [{**case, "retrievedContext": treatment_contexts[case["id"]]} for case in normalized_cases],
        }
        selection_manifest = {
            "schema": SELECTION_SCHEMA,
            "createdAt": _utc_now(),
            "benchmark": benchmark,
            "caseCount": EXPECTED_CASE_COUNT,
            "caseIds": state["caseIds"],
            "caseSetHash": case_set_hash,
            "selectionSha256": selection_sha,
            "sourceManifestSha256": state["source"]["sha256"],
            "evidenceReceipts": evidence_receipts,
            "rawPromptStored": False,
            "rawAnswerStored": False,
        }
        baseline_path = run_root / "baseline-answer-input.json"
        treatment_path = run_root / "treatment-answer-input.json"
        selection_path = run_root / "selection-manifest.json"
        _write_json_atomic(baseline_path, baseline_input)
        _write_json_atomic(treatment_path, treatment_input)
        _write_json_atomic(selection_path, selection_manifest)
        receipt = {
            "schema": PREPARER_SCHEMA,
            "status": "prepared_private_no_model_requests",
            "createdAt": _utc_now(),
            "runId": run_id,
            "benchmark": benchmark,
            "caseCount": EXPECTED_CASE_COUNT,
            "pairContract": {"path": str(pair_contract_path.resolve()), "sha256": pair_contract_sha},
            "baselineInput": {"path": str(baseline_path.resolve()), "sha256": _sha256_file(baseline_path)},
            "treatmentInput": {"path": str(treatment_path.resolve()), "sha256": _sha256_file(treatment_path)},
            "selectionManifest": {"path": str(selection_path.resolve()), "sha256": _sha256_file(selection_path)},
            "generationBudget": generation_budget,
            "labelsStripped": labels_stripped,
            "emptyTurnsSkipped": empty_turns_skipped,
            "isolatedPerCase": True,
            "modelRequestCount": 0,
            "publicationStatus": "source_verified_paired_diagnostic_non_publishable",
        }
        receipt_path = run_root / "prepare-receipt.json"
        _write_json_atomic(receipt_path, receipt)
        return {**receipt, "receiptPath": str(receipt_path.resolve()), "receiptSha256": _sha256_file(receipt_path)}
    finally:
        shutil.rmtree(scratch_root, ignore_errors=True)


def fetch_data(data_path: Path, *, apply: bool) -> dict[str, Any]:
    target = data_path.expanduser().resolve()
    manifest_path = _source_manifest_path(target)
    if target.exists() or manifest_path.exists():
        raise LongMemEvalV1InputError("LME_V1_SOURCE_EXISTS: refusing to overwrite existing benchmark data or source manifest.")
    _require(apply, "LME_V1_APPLY_REQUIRED: fetching the official benchmark data requires --apply.")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f"{target.name}.{next(tempfile._get_candidate_names())}.partial")
    try:
        request = urllib.request.Request(OFFICIAL_DATA_URL, headers={"User-Agent": "super-memory-brain-longmemeval-v1"})
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        _read_dataset(temporary)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary.replace(target)
        manifest = {
            "schema": SOURCE_MANIFEST_SCHEMA,
            "createdAt": _utc_now(),
            "benchmarkId": BENCHMARK_ID,
            "variant": BENCHMARK_VARIANT,
            "sourceUrl": OFFICIAL_DATA_URL,
            "dataFile": target.name,
            "dataSha256": _sha256_file(target),
            "caseCount": EXPECTED_CASE_COUNT,
        }
        _write_json_atomic(manifest_path, manifest)
        return {
            "ok": True,
            "action": "FetchData",
            "status": "source_acquired_private",
            "dataPath": str(target),
            "dataSha256": manifest["dataSha256"],
            "sourceManifestPath": str(manifest_path),
            "sourceManifestSha256": _sha256_file(manifest_path),
            "caseCount": EXPECTED_CASE_COUNT,
            "modelRequestCount": 0,
        }
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _status(package_root: Path, harness_root: Path, data_path: Path, output_root: Path) -> dict[str, Any]:
    package = package_root.expanduser().resolve()
    data = data_path.expanduser().resolve()
    harness = harness_root.expanduser().resolve()
    source_manifest = _source_manifest_path(data)
    harness_state: dict[str, Any] = {"path": str(harness), "present": harness.is_dir(), "pinned": False}
    if harness.is_dir():
        try:
            binding = _harness_binding(harness)
            harness_state = {"path": str(harness), "present": True, "pinned": True, **binding}
        except LongMemEvalV1InputError as error:
            harness_state["error"] = str(error)
    data_state = {"path": str(data), "present": data.is_file(), "sourceManifestPath": str(source_manifest), "sourceManifestPresent": source_manifest.is_file()}
    if data.is_file() and source_manifest.is_file():
        try:
            data_state["source"] = _load_source_manifest(data)
        except LongMemEvalV1InputError as error:
            data_state["error"] = str(error)
    return {
        "ok": True,
        "action": "Status",
        "schema": PREPARER_SCHEMA,
        "status": "ready_for_preflight" if harness_state.get("pinned") and data_state.get("source") else "source_or_harness_required",
        "packageRoot": str(package),
        "harness": harness_state,
        "data": data_state,
        "outputRoot": str(output_root.expanduser().resolve()),
        "modelRequestCount": 0,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Prepare isolated LongMemEval v1 paired answer inputs.")
    parser.add_argument("--action", choices=("status", "preflight", "fetch-data", "prepare"), default="status")
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--harness-root", required=True)
    parser.add_argument("--data-path", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--model", default="gpt-5.6-terra")
    parser.add_argument("--reasoning-effort", choices=("low", "medium", "high", "xhigh", "max"), default="max")
    parser.add_argument("--max-output-tokens", type=int, default=512)
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--batch-size", type=int, default=5)
    parser.add_argument("--max-batch-attempts", type=int, default=1)
    parser.add_argument("--apply", action="store_true")
    return parser


def main() -> int:
    args = _parser().parse_args()
    package_root = Path(args.package_root)
    harness_root = Path(args.harness_root)
    data_path = Path(args.data_path)
    output_root = Path(args.output_root)
    try:
        if args.action == "status":
            result = _status(package_root, harness_root, data_path, output_root)
        elif args.action == "fetch-data":
            result = fetch_data(data_path, apply=args.apply)
        elif args.action == "preflight":
            state = _preflight(package_root, harness_root, data_path, output_root)
            result = {
                "ok": True,
                "action": "Preflight",
                "schema": PREPARER_SCHEMA,
                "status": "preflight_ok_no_model_requests",
                "caseCount": len(state["cases"]),
                "harness": state["harness"],
                "source": state["source"],
                "outputRoot": str(state["outputRoot"]),
                "modelRequestCount": 0,
            }
        else:
            _require(args.apply, "LME_V1_APPLY_REQUIRED: writing private paired inputs requires --apply.")
            _require(bool(args.run_id), "LME_V1_RUN_ID_REQUIRED: prepare requires an explicit run id.")
            result = prepare_answer_inputs(
                package_root=package_root,
                harness_root=harness_root,
                data_path=data_path,
                output_root=output_root,
                run_id=args.run_id,
                model=args.model,
                reasoning_effort=args.reasoning_effort,
                max_output_tokens=args.max_output_tokens,
                timeout_seconds=args.timeout_seconds,
                batch_size=args.batch_size,
                max_batch_attempts=args.max_batch_attempts,
            )
            result["ok"] = True
            result["action"] = "PrepareAnswerInputs"
        print(json.dumps(result, ensure_ascii=True, sort_keys=True))
        return 0
    except LongMemEvalV1InputError as error:
        print(json.dumps({"ok": False, "action": args.action, "code": str(error).split(":", 1)[0], "message": str(error)}, ensure_ascii=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
