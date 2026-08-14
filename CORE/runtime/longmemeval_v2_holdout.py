"""Create private, stratified LongMemEval-V2 holdout inputs without using labels.

The selector only reads ids, domains, question types, and haystack membership
while choosing cases. Full question objects are copied solely into the private
official-harness input directory after selection; public receipts contain hashes
and aggregate counts only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SELECTION_SCHEMA = "super-brain.longmemeval-v2-holdout-selection.v1"
REGISTRY_SCHEMA = "super-brain.longmemeval-v2-holdout-registry.v1"


class HoldoutError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _case_id_hash(case_id: str) -> str:
    return _sha256_bytes(("longmemeval-v2-case-id-v1\0" + case_id).encode("utf-8"))


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise HoldoutError("HOLDOUT_INPUT_INVALID", "The private holdout input is unreadable.") from exc


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise HoldoutError("HOLDOUT_INPUT_INVALID", "The private questions source is unreadable.") from exc
    for line in lines:
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise HoldoutError("HOLDOUT_INPUT_INVALID", "The private questions source contains invalid JSONL.") from exc
        if not isinstance(value, dict):
            raise HoldoutError("HOLDOUT_INPUT_INVALID", "The private questions source must contain objects.")
        rows.append(value)
    return rows


def _atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp-" + secrets.token_hex(6))
    temporary.write_bytes(_canonical_json(value) + b"\n")
    os.replace(temporary, path)


def _question_ids_from_path(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    if path.suffix.lower() == ".jsonl":
        rows = _read_jsonl(path)
    else:
        value = _read_json(path)
        if isinstance(value, list):
            rows = [item for item in value if isinstance(item, dict)]
        elif isinstance(value, dict):
            if isinstance(value.get("questions"), list):
                rows = [item for item in value["questions"] if isinstance(item, dict)]
            else:
                direct_ids = value.get("questionIds", value.get("questionId", []))
                if isinstance(direct_ids, str):
                    direct_ids = [direct_ids]
                if isinstance(direct_ids, list):
                    return {str(item).strip() for item in direct_ids if isinstance(item, str) and str(item).strip()}
                return set()
        else:
            return set()
    return {
        str(row.get("id", "")).strip()
        for row in rows
        if isinstance(row.get("id"), str) and str(row.get("id", "")).strip()
    }


def _load_registry(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schema": REGISTRY_SCHEMA, "reservations": []}
    value = _read_json(path)
    if not isinstance(value, dict) or value.get("schema") != REGISTRY_SCHEMA:
        raise HoldoutError("HOLDOUT_REGISTRY_INVALID", "The private holdout registry is invalid.")
    reservations = value.get("reservations")
    if not isinstance(reservations, list) or not all(isinstance(item, dict) for item in reservations):
        raise HoldoutError("HOLDOUT_REGISTRY_INVALID", "The private holdout registry has invalid reservations.")
    return value


def _reserved_case_hashes(registry: dict[str, Any]) -> set[str]:
    values: set[str] = set()
    for reservation in registry.get("reservations", []):
        for case_hash in reservation.get("caseIdHashes", []):
            if isinstance(case_hash, str) and len(case_hash) == 64:
                values.add(case_hash.lower())
    return values


def _valid_set_hash(value: str) -> bool:
    return len(value) == 64 and all(character in "0123456789abcdef" for character in value.lower())


def _selection_rank(seed: str, case_id: str) -> str:
    return _sha256_bytes((seed + "\0" + case_id).encode("utf-8"))


def _select_cases(
    questions: list[dict[str, Any]],
    haystacks: dict[str, Any],
    *,
    domain: str,
    per_question_type: int,
    excluded_hashes: set[str],
    seed: str,
) -> tuple[list[dict[str, Any]], dict[str, int], int]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    excluded_count = 0
    for row in questions:
        case_id = str(row.get("id", "")).strip()
        row_domain = str(row.get("domain", "")).strip()
        question_type = str(row.get("question_type", "")).strip()
        if not case_id or row_domain != domain or not question_type or case_id not in haystacks:
            continue
        if _case_id_hash(case_id) in excluded_hashes:
            excluded_count += 1
            continue
        grouped.setdefault(question_type, []).append(row)

    if not grouped:
        raise HoldoutError("HOLDOUT_NO_CANDIDATES", "No unreserved private holdout candidates remain for this domain.")
    selected: list[dict[str, Any]] = []
    candidate_counts: dict[str, int] = {}
    for question_type in sorted(grouped):
        candidates = grouped[question_type]
        candidate_counts[question_type] = len(candidates)
        if len(candidates) < per_question_type:
            raise HoldoutError(
                "HOLDOUT_INSUFFICIENT_CATEGORY_CAPACITY",
                f"Private holdout category {question_type!r} does not have enough fresh cases.",
            )
        candidates.sort(key=lambda row: _selection_rank(seed, str(row["id"])))
        selected.extend(candidates[:per_question_type])
    selected.sort(key=lambda row: (str(row["question_type"]), _case_id_hash(str(row["id"]))))
    return selected, candidate_counts, excluded_count


def _selection_manifest(
    selected: list[dict[str, Any]],
    *,
    domain: str,
    per_question_type: int,
    source_question_hash: str,
    source_haystack_hash: str,
    source_manifest_hash: str,
    candidate_counts: dict[str, int],
    excluded_count: int,
    registry_reserved_count: int,
) -> dict[str, Any]:
    case_summary = [
        {
            "caseIdHash": _case_id_hash(str(row["id"])),
            "questionType": str(row["question_type"]),
        }
        for row in selected
    ]
    case_summary.sort(key=lambda item: (item["questionType"], item["caseIdHash"]))
    type_counts: dict[str, int] = {}
    for item in case_summary:
        type_counts[item["questionType"]] = type_counts.get(item["questionType"], 0) + 1
    set_hash = _sha256_bytes(_canonical_json(case_summary))
    return {
        "schema": SELECTION_SCHEMA,
        "status": "sealed_unconsumed",
        "createdAtUtc": _utc_now(),
        "domain": domain,
        "caseCount": len(case_summary),
        "perQuestionType": per_question_type,
        "questionTypeCounts": type_counts,
        "candidateCountsBeforeSelection": candidate_counts,
        "excludedExistingCaseCount": excluded_count,
        "registryReservedCaseCount": registry_reserved_count,
        "setHash": set_hash,
        "caseIdHashes": [item["caseIdHash"] for item in case_summary],
        "source": {
            "questionsSha256": source_question_hash,
            "haystacksSha256": source_haystack_hash,
            "sourceManifestSha256": source_manifest_hash,
        },
        "selectionUsesQuestionOrAnswerText": False,
        "rawPromptStored": False,
        "rawAnswerStored": False,
        "officialScoreClaimed": False,
    }


def prepare_holdout(
    *,
    questions_path: Path,
    haystacks_path: Path,
    source_manifest_path: Path,
    output_dir: Path,
    registry_path: Path,
    domain: str,
    per_question_type: int,
    exclude_question_paths: list[Path],
    apply: bool,
) -> dict[str, Any]:
    if domain not in {"web", "enterprise"}:
        raise HoldoutError("HOLDOUT_DOMAIN_INVALID", "The holdout domain must be web or enterprise.")
    if not 1 <= per_question_type <= 12:
        raise HoldoutError("HOLDOUT_COUNT_INVALID", "The per-question-type count must be between 1 and 12.")
    if not questions_path.is_file() or not haystacks_path.is_file() or not source_manifest_path.is_file():
        raise HoldoutError("HOLDOUT_SOURCE_REQUIRED", "The pinned private LongMemEval-V2 text source is incomplete.")
    questions = _read_jsonl(questions_path)
    haystacks = _read_json(haystacks_path)
    if not isinstance(haystacks, dict):
        raise HoldoutError("HOLDOUT_INPUT_INVALID", "The private haystack source must be an object.")
    registry = _load_registry(registry_path)
    existing_ids: set[str] = set()
    for path in exclude_question_paths:
        existing_ids.update(_question_ids_from_path(path))
    excluded_hashes = {_case_id_hash(case_id) for case_id in existing_ids}
    reserved_hashes = _reserved_case_hashes(registry)
    excluded_hashes.update(reserved_hashes)
    selected, candidate_counts, excluded_count = _select_cases(
        questions,
        haystacks,
        domain=domain,
        per_question_type=per_question_type,
        excluded_hashes=excluded_hashes,
        seed=secrets.token_hex(32),
    )
    manifest = _selection_manifest(
        selected,
        domain=domain,
        per_question_type=per_question_type,
        source_question_hash=_sha256_file(questions_path),
        source_haystack_hash=_sha256_file(haystacks_path),
        source_manifest_hash=_sha256_file(source_manifest_path),
        candidate_counts=candidate_counts,
        excluded_count=excluded_count,
        registry_reserved_count=len(reserved_hashes),
    )
    preview = {
        "ok": True,
        "schema": SELECTION_SCHEMA,
        "status": "preview_only" if not apply else "prepared",
        "domain": domain,
        "caseCount": manifest["caseCount"],
        "questionTypeCounts": manifest["questionTypeCounts"],
        "candidateCountsBeforeSelection": candidate_counts,
        "excludedExistingCaseCount": excluded_count,
        "registryReservedCaseCount": len(reserved_hashes),
        "setHash": manifest["setHash"] if apply else "",
        "selectionDeferred": not apply,
        "rawPromptStored": False,
        "rawAnswerStored": False,
        "officialScoreClaimed": False,
    }
    if not apply:
        return preview
    if output_dir.exists():
        raise HoldoutError("HOLDOUT_OUTPUT_EXISTS", "The requested private holdout output directory already exists.")

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_dir.with_name(output_dir.name + ".tmp-" + secrets.token_hex(6))
    try:
        temporary.mkdir(parents=False, exist_ok=False)
        _atomic_write_json(temporary / "questions.json", selected)
        _atomic_write_json(
            temporary / "haystack.json",
            {str(row["id"]): haystacks[str(row["id"])] for row in selected},
        )
        _atomic_write_json(temporary / "selection-manifest.json", manifest)
        os.replace(temporary, output_dir)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise

    reservations = list(registry["reservations"])
    reservations.append(
        {
            "setHash": manifest["setHash"],
            "domain": domain,
            "caseCount": manifest["caseCount"],
            "caseIdHashes": manifest["caseIdHashes"],
            "createdAtUtc": manifest["createdAtUtc"],
            "status": "reserved_unconsumed",
        }
    )
    _atomic_write_json(registry_path, {"schema": REGISTRY_SCHEMA, "reservations": reservations})
    return {**preview, "outputDir": str(output_dir), "registryPath": str(registry_path)}


def registry_status(registry_path: Path) -> dict[str, Any]:
    registry = _load_registry(registry_path)
    reservations = list(registry["reservations"])
    status_counts: dict[str, int] = {}
    for reservation in reservations:
        status = str(reservation.get("status", "unknown"))
        status_counts[status] = status_counts.get(status, 0) + 1
    return {
        "ok": True,
        "schema": REGISTRY_SCHEMA,
        "reservationCount": len(reservations),
        "reservedCaseCount": len(_reserved_case_hashes(registry)),
        "setHashes": [str(item.get("setHash", "")) for item in reservations],
        "statusCounts": status_counts,
        "rawPromptStored": False,
        "rawAnswerStored": False,
    }


def mark_incomplete_diagnostic(registry_path: Path, *, set_hash: str, reason: str) -> dict[str, Any]:
    if not _valid_set_hash(set_hash):
        raise HoldoutError("HOLDOUT_SET_HASH_INVALID", "The private holdout set hash is invalid.")
    normalized_reason = str(reason or "").strip().lower()
    if not normalized_reason or not all(character.islower() or character.isdigit() or character in "_-" for character in normalized_reason):
        raise HoldoutError("HOLDOUT_REASON_INVALID", "The incomplete diagnostic reason is invalid.")
    registry = _load_registry(registry_path)
    for reservation in registry["reservations"]:
        if str(reservation.get("setHash", "")) != set_hash:
            continue
        if reservation.get("status") != "reserved_unconsumed":
            raise HoldoutError("HOLDOUT_LIFECYCLE_INVALID", "The private holdout is not available for incomplete-diagnostic marking.")
        reservation["status"] = "consumed_incomplete_diagnostic"
        reservation["consumedAtUtc"] = _utc_now()
        reservation["incompleteReason"] = normalized_reason
        _atomic_write_json(registry_path, registry)
        return {
            "ok": True,
            "schema": REGISTRY_SCHEMA,
            "setHash": set_hash,
            "status": "consumed_incomplete_diagnostic",
            "rawPromptStored": False,
            "rawAnswerStored": False,
        }
    raise HoldoutError("HOLDOUT_SET_NOT_FOUND", "The private holdout set is not registered.")


def mark_completed_diagnostic(registry_path: Path, *, set_hash: str, evidence_hash: str) -> dict[str, Any]:
    if not _valid_set_hash(set_hash) or not _valid_set_hash(evidence_hash):
        raise HoldoutError("HOLDOUT_HASH_INVALID", "The private holdout or evidence hash is invalid.")
    registry = _load_registry(registry_path)
    for reservation in registry["reservations"]:
        if str(reservation.get("setHash", "")) != set_hash:
            continue
        if reservation.get("status") != "reserved_unconsumed":
            raise HoldoutError("HOLDOUT_LIFECYCLE_INVALID", "The private holdout is not available for completed-diagnostic marking.")
        reservation["status"] = "consumed_completed_diagnostic"
        reservation["consumedAtUtc"] = _utc_now()
        reservation["evidenceSha256"] = evidence_hash
        _atomic_write_json(registry_path, registry)
        return {
            "ok": True,
            "schema": REGISTRY_SCHEMA,
            "setHash": set_hash,
            "status": "consumed_completed_diagnostic",
            "evidenceSha256": evidence_hash,
            "rawPromptStored": False,
            "rawAnswerStored": False,
        }
    raise HoldoutError("HOLDOUT_SET_NOT_FOUND", "The private holdout set is not registered.")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="action", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--questions-path", required=True)
    prepare.add_argument("--haystacks-path", required=True)
    prepare.add_argument("--source-manifest-path", required=True)
    prepare.add_argument("--output-dir", required=True)
    prepare.add_argument("--registry-path", required=True)
    prepare.add_argument("--domain", required=True, choices=("web", "enterprise"))
    prepare.add_argument("--per-question-type", required=True, type=int)
    prepare.add_argument("--exclude-question-path", action="append", default=[])
    prepare.add_argument("--apply", action="store_true")
    status = subparsers.add_parser("status")
    status.add_argument("--registry-path", required=True)
    mark_incomplete = subparsers.add_parser("mark-incomplete")
    mark_incomplete.add_argument("--registry-path", required=True)
    mark_incomplete.add_argument("--set-hash", required=True)
    mark_incomplete.add_argument("--reason", required=True)
    mark_complete = subparsers.add_parser("mark-complete")
    mark_complete.add_argument("--registry-path", required=True)
    mark_complete.add_argument("--set-hash", required=True)
    mark_complete.add_argument("--evidence-hash", required=True)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            result = prepare_holdout(
                questions_path=Path(args.questions_path).expanduser().resolve(),
                haystacks_path=Path(args.haystacks_path).expanduser().resolve(),
                source_manifest_path=Path(args.source_manifest_path).expanduser().resolve(),
                output_dir=Path(args.output_dir).expanduser().resolve(),
                registry_path=Path(args.registry_path).expanduser().resolve(),
                domain=str(args.domain),
                per_question_type=int(args.per_question_type),
                exclude_question_paths=[Path(value).expanduser().resolve() for value in args.exclude_question_path],
                apply=bool(args.apply),
            )
        elif args.action == "status":
            result = registry_status(Path(args.registry_path).expanduser().resolve())
        elif args.action == "mark-incomplete":
            result = mark_incomplete_diagnostic(
                Path(args.registry_path).expanduser().resolve(),
                set_hash=str(args.set_hash),
                reason=str(args.reason),
            )
        else:
            result = mark_completed_diagnostic(
                Path(args.registry_path).expanduser().resolve(),
                set_hash=str(args.set_hash),
                evidence_hash=str(args.evidence_hash),
            )
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
        return 0
    except HoldoutError as exc:
        print(json.dumps({"ok": False, "code": exc.code}, ensure_ascii=True, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
