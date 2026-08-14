"""Pure, scope-bound Super Brain context projection helpers.

This module is intentionally file-read-only: it never creates directories,
opens SQLite, writes telemetry, or receives a raw prompt for persistence.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
SECRET_RE = re.compile(r"(?i)\b(?P<name>api[_ -]?key|password|passwd|token|secret)\s*[:=]\s*[^\s,;]+")
BEARER_RE = re.compile(r"(?i)\bbearer\s+[a-z0-9._~+/-]+=*")
SK_RE = re.compile(r"(?i)\bsk-[a-z0-9_-]{8,}\b")

NATIVE_MEMORY_INFLUENCE_SNAPSHOT_SCHEMA = "super-brain.native-memory-influence-snapshot.v1"
NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_BYTES = 128 * 1024
NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
INTENT_CONTEXT_PROJECTION_SCHEMA = "super-brain.intent-context-projection.v1"
INTENT_CONTEXT_PROJECTION_MAX_BYTES = 16 * 1024
INTENT_CONTEXT_PROJECTION_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
INTENT_CONTEXT_PENDING_SCHEMA = "super-brain.intent-context-pending.v1"
INTENT_CONTEXT_PATH_TOKEN_LENGTH = 20
PROJECT_PROGRESS_PROOF_SCHEMA = "super-brain.project-progress-proof.v1"
PROJECT_PROGRESS_PROOF_MAX_BYTES = 32 * 1024
PROJECT_PROGRESS_MAX_COMPLETED_ITEMS = 24
PROJECT_PROGRESS_MAX_EVIDENCE = 16
PROJECT_PROGRESS_MAX_VERIFICATIONS = 16
PROJECT_PROGRESS_VERIFICATION_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,119}$")
PROJECT_PROGRESS_EVIDENCE_REF_RE = re.compile(r"^project:file:([^@]+)@sha256:([a-f0-9]{64})$")
VISIBLE_PROGRESS_RECEIPT_SCHEMA = "super-brain.visible-progress-receipt.v1"
VISIBLE_PROGRESS_RECEIPT_MAX_BYTES = 8 * 1024
VISIBLE_PROGRESS_SENTENCE_MAX_CHARS = 320
VISIBLE_PROGRESS_PHASE_MAX_CHARS = 120
VISIBLE_PROGRESS_STEP_MAX_CHARS = 220
VISIBLE_PROGRESS_NEXT_ACTION_MAX_CHARS = 360
VISIBLE_PROGRESS_TRANSITION_RE = re.compile(r"^[A-Za-z0-9._:-]{1,120}$")
VISIBLE_PROGRESS_SOURCES = frozenset({"assistant_visible_reply", "user_attested_visible_reply"})


def project_progress_root_hash(project_root: Path | str | None) -> str:
    """Hash one normalized host project root without exposing its path."""

    if project_root is None:
        return ""
    try:
        normalized = str(Path(project_root).expanduser().resolve()).rstrip("/\\").replace("\\", "/").lower()
    except (OSError, ValueError):
        return ""
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest() if normalized else ""


def project_progress_item_key(value: Any) -> str:
    """Normalize a contract checklist label for a proof-only identity match."""

    return " ".join(str(value or "").split()).strip().lower()


def _project_progress_withheld(
    code: str,
    missing: list[str] | tuple[str, ...],
    *,
    payload_hash: str = "",
    completed_count: int = 0,
    evidence_count: int = 0,
    verification_count: int = 0,
    verification_state: str = "withheld",
) -> dict[str, Any]:
    return {
        "ok": True,
        "current": False,
        "state": "withheld",
        "code": code,
        "payloadHash": payload_hash,
        "missing": list(dict.fromkeys(str(item) for item in missing if str(item)))[:8],
        "completedCount": max(0, int(completed_count)),
        "evidenceCount": max(0, int(evidence_count)),
        "verificationCount": max(0, int(verification_count)),
        "verificationState": verification_state,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _visible_progress_withheld(
    code: str,
    missing: list[str] | tuple[str, ...],
    *,
    source: str = "",
    sentence_hash: str = "",
    payload_hash: str = "",
    project_progress_hash: str = "",
) -> dict[str, Any]:
    """Return a privacy-safe, non-authorizing visible-progress projection."""

    return {
        "ok": True,
        "current": False,
        "state": "withheld",
        "code": code,
        "missing": list(dict.fromkeys(str(item) for item in missing if str(item)))[:8],
        "source": source if source in VISIBLE_PROGRESS_SOURCES else "",
        "sentenceHash": sentence_hash if SHA256_RE.fullmatch(sentence_hash) else "",
        "payloadHash": payload_hash if SHA256_RE.fullmatch(payload_hash) else "",
        "projectProgressPayloadHash": project_progress_hash if SHA256_RE.fullmatch(project_progress_hash) else "",
        # A withheld receipt can never authorize a continuation.  Keep this
        # explicit so callers do not have to infer it from a status string.
        "continuationEligible": False,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _project_progress_relative_path(value: Any) -> str | None:
    """Validate a portable, non-escaping project-relative proof path."""

    raw = str(value or "").strip().replace("\\", "/")
    if not raw or len(raw) > 240 or raw.startswith("/") or ":" in raw:
        return None
    parts = raw.split("/")
    if any(not part or part in {".", ".."} for part in parts):
        return None
    return "/".join(parts)


def _project_progress_file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    except OSError:
        return ""
    return digest.hexdigest()


def validate_project_progress_proof(
    proof: Any,
    *,
    project_root: Path | str | None,
    expected_phase: Any = "",
    expected_current_step: Any = "",
    expected_next_action: Any = "",
    expected_completed_steps: Any = (),
) -> dict[str, Any]:
    """Validate one contract-owned, hash-bound project-progress proof.

    The return value is deliberately a safe projection: it never returns raw
    proof text, project paths, prompt text, or file contents.  It reads only
    the bounded project files named by the proof to recheck their SHA-256
    values; it never writes project or runtime state.
    """

    if not isinstance(proof, dict):
        return _project_progress_withheld("H7_PROJECT_PROGRESS_PROOF_MISSING", ["project_progress_proof"])
    try:
        encoded = json.dumps(proof, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        return _project_progress_withheld("H7_PROJECT_PROGRESS_PROOF_INVALID", ["project_progress_proof"])
    if len(encoded) > PROJECT_PROGRESS_PROOF_MAX_BYTES:
        return _project_progress_withheld("H7_PROJECT_PROGRESS_PROOF_TOO_LARGE", ["project_progress_proof"])

    expected_fields = {
        "schema",
        "state",
        "phase",
        "currentStep",
        "completedItems",
        "projectEvidence",
        "verificationResults",
        "nextAction",
        "missing",
        "projectRootHash",
        "rawPromptStored",
        "rawTranscriptStored",
        "payloadHash",
    }
    if set(proof) != expected_fields or proof.get("schema") != PROJECT_PROGRESS_PROOF_SCHEMA:
        return _project_progress_withheld("H7_PROJECT_PROGRESS_PROOF_INVALID", ["project_progress_schema"])
    payload_hash = proof.get("payloadHash")
    body = {key: value for key, value in proof.items() if key != "payloadHash"}
    if not isinstance(payload_hash, str) or not SHA256_RE.fullmatch(payload_hash) or canonical_hash(body) != payload_hash:
        return _project_progress_withheld("H7_PROJECT_PROGRESS_PROOF_HASH_MISMATCH", ["project_progress_payload_hash"])
    sensitive_body = {
        key: value
        for key, value in body.items()
        if key not in {"rawPromptStored", "rawTranscriptStored"}
    }
    if proof.get("rawPromptStored") is not False or proof.get("rawTranscriptStored") is not False or _contains_unsafe_memory_value(sensitive_body):
        return _project_progress_withheld("H7_PROJECT_PROGRESS_PROOF_UNSAFE", ["project_progress_privacy"])

    state = proof.get("state")
    phase = proof.get("phase")
    current_step = proof.get("currentStep")
    next_action = proof.get("nextAction")
    root_hash = proof.get("projectRootHash")
    completed_items = proof.get("completedItems")
    project_evidence = proof.get("projectEvidence")
    verification_results = proof.get("verificationResults")
    declared_missing = proof.get("missing")
    if (
        state not in {"current", "withheld"}
        or not all(isinstance(value, str) for value in (phase, current_step, next_action, root_hash))
        or not isinstance(completed_items, list)
        or not isinstance(project_evidence, list)
        or not isinstance(verification_results, list)
        or not isinstance(declared_missing, list)
        or len(completed_items) > PROJECT_PROGRESS_MAX_COMPLETED_ITEMS
        or len(project_evidence) > PROJECT_PROGRESS_MAX_EVIDENCE
        or len(verification_results) > PROJECT_PROGRESS_MAX_VERIFICATIONS
    ):
        return _project_progress_withheld("H7_PROJECT_PROGRESS_PROOF_INVALID", ["project_progress_fields"], payload_hash=payload_hash)
    if (
        len(phase) > 120
        or len(current_step) > 220
        or len(next_action) > 360
        or not SHA256_RE.fullmatch(root_hash)
        or any(not isinstance(item, str) or not re.fullmatch(r"[a-z0-9_]{1,80}", item) for item in declared_missing)
        or len(set(declared_missing)) != len(declared_missing)
    ):
        return _project_progress_withheld("H7_PROJECT_PROGRESS_PROOF_INVALID", ["project_progress_fields"], payload_hash=payload_hash)

    expected_phase_value = " ".join(str(expected_phase or "").split())
    expected_step_value = " ".join(str(expected_current_step or "").split())
    expected_next_value = " ".join(str(expected_next_action or "").split())
    expected_items = [project_progress_item_key(value) for value in (expected_completed_steps or [])]
    expected_items = sorted(value for value in expected_items if value)
    root_value: Path | None
    try:
        root_value = Path(project_root).expanduser().resolve() if project_root is not None else None
    except (OSError, ValueError):
        root_value = None
    if root_value is None or not root_value.is_dir():
        return _project_progress_withheld(
            "H7_PROJECT_PROGRESS_ROOT_UNAVAILABLE",
            ["project_root"],
            payload_hash=payload_hash,
            completed_count=len(completed_items),
            evidence_count=len(project_evidence),
            verification_count=len(verification_results),
        )
    if project_progress_root_hash(root_value) != root_hash:
        return _project_progress_withheld(
            "H7_PROJECT_PROGRESS_ROOT_MISMATCH",
            ["project_root_hash"],
            payload_hash=payload_hash,
            completed_count=len(completed_items),
            evidence_count=len(project_evidence),
            verification_count=len(verification_results),
        )

    evidence_refs: set[str] = set()
    evidence_by_ref: dict[str, dict[str, str]] = {}
    for item in project_evidence:
        if not isinstance(item, dict) or set(item) != {"kind", "relativePath", "sha256"}:
            return _project_progress_withheld("H7_PROJECT_PROGRESS_EVIDENCE_INVALID", ["project_evidence"], payload_hash=payload_hash)
        relative_path = _project_progress_relative_path(item.get("relativePath"))
        expected_hash = item.get("sha256")
        if item.get("kind") != "project_file" or relative_path is None or not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
            return _project_progress_withheld("H7_PROJECT_PROGRESS_EVIDENCE_INVALID", ["project_evidence"], payload_hash=payload_hash)
        reference = f"project:file:{relative_path}@sha256:{expected_hash}"
        if reference in evidence_refs:
            return _project_progress_withheld("H7_PROJECT_PROGRESS_EVIDENCE_INVALID", ["project_evidence"], payload_hash=payload_hash)
        evidence_refs.add(reference)
        evidence_by_ref[reference] = {"relativePath": relative_path, "sha256": expected_hash}

    verification_by_id: dict[str, str] = {}
    for item in verification_results:
        if not isinstance(item, dict) or set(item) != {"id", "status"}:
            return _project_progress_withheld("H7_PROJECT_PROGRESS_VERIFICATION_INVALID", ["verification_result"], payload_hash=payload_hash)
        verification_id = item.get("id")
        status = item.get("status")
        if (
            not isinstance(verification_id, str)
            or not PROJECT_PROGRESS_VERIFICATION_ID_RE.fullmatch(verification_id)
            or status not in {"passed", "failed", "not_run"}
            or verification_id in verification_by_id
        ):
            return _project_progress_withheld("H7_PROJECT_PROGRESS_VERIFICATION_INVALID", ["verification_result"], payload_hash=payload_hash)
        verification_by_id[verification_id] = status

    actual_items: list[str] = []
    for item in completed_items:
        if not isinstance(item, dict) or set(item) != {"itemKey", "evidenceRefs", "verificationIds"}:
            return _project_progress_withheld("H7_PROJECT_PROGRESS_COMPLETED_ITEM_INVALID", ["completed_item"], payload_hash=payload_hash)
        item_key = item.get("itemKey")
        item_refs = item.get("evidenceRefs")
        verification_ids = item.get("verificationIds")
        if (
            not isinstance(item_key, str)
            or not item_key.strip()
            or len(item_key) > 180
            or any(ord(character) < 32 for character in item_key)
            or not isinstance(item_refs, list)
            or not isinstance(verification_ids, list)
            or not item_refs
            or not verification_ids
            or len(item_refs) > PROJECT_PROGRESS_MAX_EVIDENCE
            or len(verification_ids) > PROJECT_PROGRESS_MAX_VERIFICATIONS
        ):
            return _project_progress_withheld("H7_PROJECT_PROGRESS_COMPLETED_ITEM_INVALID", ["completed_item"], payload_hash=payload_hash)
        normalized_key = project_progress_item_key(item_key)
        if not normalized_key or normalized_key in actual_items:
            return _project_progress_withheld("H7_PROJECT_PROGRESS_COMPLETED_ITEM_INVALID", ["completed_item"], payload_hash=payload_hash)
        actual_items.append(normalized_key)
        if (
            any(not isinstance(reference, str) or reference not in evidence_by_ref for reference in item_refs)
            or len(set(item_refs)) != len(item_refs)
            or any(not isinstance(identifier, str) or identifier not in verification_by_id for identifier in verification_ids)
            or len(set(verification_ids)) != len(verification_ids)
        ):
            return _project_progress_withheld("H7_PROJECT_PROGRESS_COMPLETED_ITEM_INVALID", ["completed_item_binding"], payload_hash=payload_hash)
        if any(verification_by_id[identifier] != "passed" for identifier in verification_ids):
            return _project_progress_withheld(
                "H7_PROJECT_PROGRESS_VERIFICATION_NOT_PASSED",
                ["verification_result"],
                payload_hash=payload_hash,
                completed_count=len(completed_items),
                evidence_count=len(project_evidence),
                verification_count=len(verification_results),
                verification_state="not_passed",
            )

    if sorted(actual_items) != expected_items or phase != expected_phase_value or current_step != expected_step_value or next_action != expected_next_value:
        return _project_progress_withheld(
            "H7_PROJECT_PROGRESS_BINDING_MISMATCH",
            ["contract_progress_binding"],
            payload_hash=payload_hash,
            completed_count=len(completed_items),
            evidence_count=len(project_evidence),
            verification_count=len(verification_results),
        )
    if not evidence_by_ref:
        return _project_progress_withheld(
            "H7_PROJECT_PROGRESS_EVIDENCE_MISSING",
            ["project_evidence"],
            payload_hash=payload_hash,
            completed_count=len(completed_items),
            evidence_count=0,
            verification_count=len(verification_results),
        )
    for evidence in evidence_by_ref.values():
        candidate = (root_value / evidence["relativePath"]).resolve()
        try:
            candidate.relative_to(root_value)
        except ValueError:
            return _project_progress_withheld("H7_PROJECT_PROGRESS_EVIDENCE_INVALID", ["project_evidence"], payload_hash=payload_hash)
        if not candidate.is_file() or _project_progress_file_hash(candidate) != evidence["sha256"]:
            return _project_progress_withheld(
                "H7_PROJECT_PROGRESS_EVIDENCE_HASH_MISMATCH",
                ["project_evidence_hash"],
                payload_hash=payload_hash,
                completed_count=len(completed_items),
                evidence_count=len(project_evidence),
                verification_count=len(verification_results),
            )

    verification_state = "passed" if completed_items else "not_required"
    if state != "current" or declared_missing:
        return _project_progress_withheld(
            "H7_PROJECT_PROGRESS_DECLARED_WITHHELD",
            declared_missing or ["project_progress_proof"],
            payload_hash=payload_hash,
            completed_count=len(completed_items),
            evidence_count=len(project_evidence),
            verification_count=len(verification_results),
            verification_state=verification_state,
        )
    return {
        "ok": True,
        "current": True,
        "state": "current",
        "code": "H7_PROJECT_PROGRESS_CURRENT",
        "payloadHash": payload_hash,
        "missing": [],
        "completedCount": len(completed_items),
        "evidenceCount": len(project_evidence),
        "verificationCount": len(verification_results),
        "verificationState": verification_state,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def visible_progress_scope_binding_hash(
    *,
    task_id: Any,
    task_instance_id: Any,
    workspace_key: Any,
    owner_session_key: Any,
    package_version: Any,
) -> str:
    """Bind a visible-progress receipt to one exact execution identity."""

    body = {
        "schema": "super-brain.visible-progress-scope-binding.v1",
        "taskId": str(task_id or ""),
        "taskInstanceId": str(task_instance_id or ""),
        "workspaceKey": str(workspace_key or "").lower(),
        "ownerSessionKey": str(owner_session_key or "").lower(),
        "packageVersion": str(package_version or ""),
    }
    return canonical_hash(body) if all(body[key] for key in body if key != "schema") else ""


def _strict_visible_progress_text(value: Any, maximum: int) -> str | None:
    """Accept an already-visible compact progress field without rewriting it.

    A recovery anchor is an exact source-bound sentence.  Normalizing,
    trimming, redacting, or truncating it here would make a later reply appear
    to resume from text that was never actually shown to the user.
    """

    if not isinstance(value, str) or not value or len(value) > maximum or value != value.strip():
        return None
    if "\n" in value or "\r" in value or any(ord(character) < 32 for character in value):
        return None
    return value


def validate_visible_progress_receipt(
    receipt: Any,
    *,
    last_confirmed_sentence: Any,
    last_confirmed_source: Any,
    current_phase: Any,
    current_step: Any,
    next_action: Any,
    project_progress_status: Any,
    task_id: Any,
    task_instance_id: Any,
    workspace_key: Any,
    owner_session_key: Any,
    package_version: Any,
) -> dict[str, Any]:
    """Validate the one recovery anchor that may authorize H7 continuation.

    The receipt deliberately stores a hash of the compact assistant progress
    sentence rather than another transcript copy.  It must match the current
    contract fields and the revalidated project-progress proof exactly.  Older
    summaries, memory, and a stale contract field therefore cannot quietly win
    a continuation decision.
    """

    sentence = _strict_visible_progress_text(last_confirmed_sentence, VISIBLE_PROGRESS_SENTENCE_MAX_CHARS)
    source = str(last_confirmed_source or "")
    phase = _strict_visible_progress_text(current_phase, VISIBLE_PROGRESS_PHASE_MAX_CHARS)
    step = _strict_visible_progress_text(current_step, VISIBLE_PROGRESS_STEP_MAX_CHARS)
    action = _strict_visible_progress_text(next_action, VISIBLE_PROGRESS_NEXT_ACTION_MAX_CHARS)
    progress = project_progress_status if isinstance(project_progress_status, dict) else {}
    project_hash = str(progress.get("payloadHash", ""))
    if not isinstance(receipt, dict):
        return _visible_progress_withheld(
            "H7_VISIBLE_PROGRESS_RECEIPT_REQUIRED",
            ["visible_progress_receipt"],
            project_progress_hash=project_hash,
        )
    try:
        encoded = json.dumps(receipt, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        return _visible_progress_withheld(
            "H7_VISIBLE_PROGRESS_RECEIPT_INVALID",
            ["visible_progress_receipt"],
            project_progress_hash=project_hash,
        )
    if len(encoded) > VISIBLE_PROGRESS_RECEIPT_MAX_BYTES:
        return _visible_progress_withheld(
            "H7_VISIBLE_PROGRESS_RECEIPT_INVALID",
            ["visible_progress_receipt_size"],
            project_progress_hash=project_hash,
        )
    expected_fields = {
        "schema",
        "source",
        "sentenceHash",
        "currentPhase",
        "currentStep",
        "nextAction",
        "projectProgressPayloadHash",
        "scopeBindingHash",
        "transitionId",
        "rawPromptStored",
        "rawTranscriptStored",
        "payloadHash",
    }
    if set(receipt) != expected_fields or receipt.get("schema") != VISIBLE_PROGRESS_RECEIPT_SCHEMA:
        return _visible_progress_withheld(
            "H7_VISIBLE_PROGRESS_RECEIPT_INVALID",
            ["visible_progress_receipt_schema"],
            project_progress_hash=project_hash,
        )
    receipt_source = receipt.get("source")
    sentence_hash = receipt.get("sentenceHash")
    receipt_phase = receipt.get("currentPhase")
    receipt_step = receipt.get("currentStep")
    receipt_action = receipt.get("nextAction")
    receipt_project_hash = receipt.get("projectProgressPayloadHash")
    receipt_scope_binding_hash = receipt.get("scopeBindingHash")
    transition_id = receipt.get("transitionId")
    payload_hash = receipt.get("payloadHash")
    expected_scope_binding_hash = visible_progress_scope_binding_hash(
        task_id=task_id,
        task_instance_id=task_instance_id,
        workspace_key=workspace_key,
        owner_session_key=owner_session_key,
        package_version=package_version,
    )
    if (
        receipt_source not in VISIBLE_PROGRESS_SOURCES
        or not isinstance(sentence_hash, str)
        or not SHA256_RE.fullmatch(sentence_hash)
        or _strict_visible_progress_text(receipt_phase, VISIBLE_PROGRESS_PHASE_MAX_CHARS) is None
        or _strict_visible_progress_text(receipt_step, VISIBLE_PROGRESS_STEP_MAX_CHARS) is None
        or _strict_visible_progress_text(receipt_action, VISIBLE_PROGRESS_NEXT_ACTION_MAX_CHARS) is None
        or not isinstance(receipt_project_hash, str)
        or not SHA256_RE.fullmatch(receipt_project_hash)
        or not isinstance(receipt_scope_binding_hash, str)
        or not SHA256_RE.fullmatch(receipt_scope_binding_hash)
        or not expected_scope_binding_hash
        or not isinstance(transition_id, str)
        or not VISIBLE_PROGRESS_TRANSITION_RE.fullmatch(transition_id)
        or not isinstance(payload_hash, str)
        or not SHA256_RE.fullmatch(payload_hash)
        or receipt.get("rawPromptStored") is not False
        or receipt.get("rawTranscriptStored") is not False
    ):
        return _visible_progress_withheld(
            "H7_VISIBLE_PROGRESS_RECEIPT_INVALID",
            ["visible_progress_receipt_fields"],
            project_progress_hash=project_hash,
        )
    body = {key: value for key, value in receipt.items() if key != "payloadHash"}
    if canonical_hash(body) != payload_hash:
        return _visible_progress_withheld(
            "H7_VISIBLE_PROGRESS_RECEIPT_HASH_MISMATCH",
            ["visible_progress_receipt_hash"],
            source=str(receipt_source),
            sentence_hash=sentence_hash,
            project_progress_hash=project_hash,
        )
    if (
        sentence is None
        or source not in VISIBLE_PROGRESS_SOURCES
        or phase is None
        or step is None
        or action is None
        or source != receipt_source
        or hashlib.sha256(sentence.encode("utf-8")).hexdigest() != sentence_hash
        or phase != receipt_phase
        or step != receipt_step
        or action != receipt_action
        or receipt_scope_binding_hash != expected_scope_binding_hash
    ):
        return _visible_progress_withheld(
            "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH",
            ["latest_visible_progress_binding"],
            source=str(receipt_source),
            sentence_hash=sentence_hash,
            payload_hash=payload_hash,
            project_progress_hash=project_hash,
        )
    if progress.get("current") is not True or receipt_project_hash != project_hash:
        return _visible_progress_withheld(
            "H7_VISIBLE_PROGRESS_RECEIPT_PROJECT_PROOF_MISMATCH",
            ["visible_progress_project_proof"],
            source=str(receipt_source),
            sentence_hash=sentence_hash,
            payload_hash=payload_hash,
            project_progress_hash=project_hash,
        )
    # A user may accurately point out the latest visible assistant progress
    # after compaction or a lost host tail.  That attestation is useful for
    # reconciling the contract, but it is not a substitute for the next real
    # assistant-visible publication.  Otherwise an attested old sentence
    # could become a durable normal-resume source without the host ever
    # emitting it as the current progress reply.
    continuation_eligible = receipt_source == "assistant_visible_reply"
    return {
        "ok": True,
        "current": True,
        "state": "current",
        "code": "H7_VISIBLE_PROGRESS_RECEIPT_CURRENT",
        "missing": [],
        "source": receipt_source,
        "sentenceHash": sentence_hash,
        "payloadHash": payload_hash,
        "projectProgressPayloadHash": receipt_project_hash,
        "scopeBindingHash": receipt_scope_binding_hash,
        "continuationEligible": continuation_eligible,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def scope_ref(value: str) -> str:
    return canonical_hash({"scopeKey": str(value)})


def native_memory_snapshot_path(memory_base: Path) -> Path:
    return memory_base / "workspace" / "native-memory-influence-snapshot.json"


def native_memory_snapshot_dirty_path(memory_base: Path) -> Path:
    return memory_base / "workspace" / "native-memory-influence-snapshot.dirty.json"


def intent_context_aggregate_ref(*, task_id: str, task_instance_id: str, workspace_key: str) -> str:
    """Hash the aggregate identity without exposing it in a filename."""

    return canonical_hash(
        {
            "taskId": str(task_id),
            "taskInstanceId": str(task_instance_id),
            "workspaceKey": str(workspace_key),
        }
    )


def intent_context_projection_root(memory_base: Path) -> Path:
    return memory_base / "workspace" / "runtime-state" / "intent-context-projections"


def _intent_context_path_token(value: str) -> str:
    """Keep Windows temp paths below MAX_PATH while retaining 80-bit identity."""

    return str(value)[:INTENT_CONTEXT_PATH_TOKEN_LENGTH]


def intent_context_projection_path(
    memory_base: Path,
    *,
    task_id: str,
    task_instance_id: str,
    workspace_key: str,
) -> Path:
    """Return the non-reversible, aggregate-scoped path for an intent proof."""

    aggregate_ref = intent_context_aggregate_ref(
        task_id=task_id,
        task_instance_id=task_instance_id,
        workspace_key=workspace_key,
    )
    return intent_context_projection_root(memory_base) / "heads" / f"{_intent_context_path_token(aggregate_ref)}.json"


def intent_context_pending_root(
    memory_base: Path,
    *,
    task_id: str,
    task_instance_id: str,
    workspace_key: str,
) -> Path:
    aggregate_ref = intent_context_aggregate_ref(
        task_id=task_id,
        task_instance_id=task_instance_id,
        workspace_key=workspace_key,
    )
    return intent_context_projection_root(memory_base) / "pending" / _intent_context_path_token(aggregate_ref)


def intent_context_pending_marker_path(
    memory_base: Path,
    *,
    task_id: str,
    task_instance_id: str,
    workspace_key: str,
    mutation_id: str,
) -> Path:
    mutation_ref = canonical_hash({"mutationId": str(mutation_id)})
    return intent_context_pending_root(
        memory_base,
        task_id=task_id,
        task_instance_id=task_instance_id,
        workspace_key=workspace_key,
    ) / f"{_intent_context_path_token(mutation_ref)}.json"
    return memory_base / "workspace" / "runtime-state" / "intent-context-projections" / f"{aggregate_ref}.json"


def _current_timestamp(value: Any, *, now: datetime, max_age_seconds: int) -> bool:
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return False
    if parsed.tzinfo is None:
        return False
    reference = now if now.tzinfo is not None else now.replace(tzinfo=timezone.utc)
    age_seconds = (reference.astimezone(timezone.utc) - parsed.astimezone(timezone.utc)).total_seconds()
    return 0 <= age_seconds <= max_age_seconds


def read_intent_context_projection(
    memory_base: Path,
    request: dict[str, Any],
    *,
    now: datetime | None = None,
    allow_pending: bool = False,
) -> dict[str, Any]:
    """Verify one current intent receipt from its atomic JSON projection.

    This is the no-Hook context proof seam: it validates only a redacted,
    command-side projection and never opens the writable SQLite authority.
    """

    required_request_fields = {
        "taskId",
        "taskInstanceId",
        "workspaceKey",
        "ownerSessionKey",
        "packageVersion",
        "contractRevision",
        "intentRevision",
        "planFingerprint",
        "latestInstructionHash",
        "intentContractFingerprint",
        "receiptId",
        "payloadHash",
    }
    if not isinstance(request, dict) or set(request) != required_request_fields:
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_REQUEST_INVALID"}
    path = intent_context_projection_path(
        memory_base,
        task_id=str(request["taskId"]),
        task_instance_id=str(request["taskInstanceId"]),
        workspace_key=str(request["workspaceKey"]),
    )
    pending_root = intent_context_pending_root(
        memory_base,
        task_id=str(request["taskId"]),
        task_instance_id=str(request["taskInstanceId"]),
        workspace_key=str(request["workspaceKey"]),
    )
    if not allow_pending:
        try:
            if pending_root.is_dir() and any(candidate.is_file() for candidate in pending_root.glob("*.json")):
                return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_PENDING"}
        except OSError:
            return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_PENDING_UNAVAILABLE"}
    try:
        raw = path.read_bytes()
    except OSError:
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_MISSING"}
    if not raw or len(raw) > INTENT_CONTEXT_PROJECTION_MAX_BYTES:
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_INVALID"}
    try:
        projection = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_INVALID"}
    if not isinstance(projection, dict):
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_INVALID"}
    expected_fields = {
        "schema",
        "generatedAt",
        "aggregateRef",
        "bindingHash",
        "ready",
        "intentContractBodyStored",
        "rawPromptStored",
        "rawTranscriptStored",
        "payloadHash",
    }
    if set(projection) != expected_fields:
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_INVALID"}
    payload_hash = projection.get("payloadHash")
    body = {key: value for key, value in projection.items() if key != "payloadHash"}
    sensitive_body = {
        key: value
        for key, value in body.items()
        if key not in {"intentContractBodyStored", "rawPromptStored", "rawTranscriptStored"}
    }
    if (
        not isinstance(payload_hash, str)
        or not SHA256_RE.fullmatch(payload_hash)
        or canonical_hash(body) != payload_hash
        or _contains_unsafe_memory_value(sensitive_body)
        or projection.get("schema") != INTENT_CONTEXT_PROJECTION_SCHEMA
        or not isinstance(projection.get("ready"), bool)
        or projection.get("intentContractBodyStored") is not False
        or projection.get("rawPromptStored") is not False
        or projection.get("rawTranscriptStored") is not False
    ):
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_INVALID"}
    reference_now = now or datetime.now(timezone.utc)
    if not _current_timestamp(
        projection.get("generatedAt"),
        now=reference_now,
        max_age_seconds=INTENT_CONTEXT_PROJECTION_MAX_AGE_SECONDS,
    ):
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_STALE_OR_FUTURE"}
    aggregate_ref = intent_context_aggregate_ref(
        task_id=str(request["taskId"]),
        task_instance_id=str(request["taskInstanceId"]),
        workspace_key=str(request["workspaceKey"]),
    )
    if projection.get("aggregateRef") != aggregate_ref:
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_SCOPE_MISMATCH"}
    binding_hash = projection.get("bindingHash")
    if (
        not isinstance(binding_hash, str)
        or not SHA256_RE.fullmatch(binding_hash)
        or binding_hash != canonical_hash(request)
    ):
        return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_NOT_CURRENT"}
    for field in ("aggregateRef", "bindingHash"):
        if not isinstance(projection.get(field), str) or not SHA256_RE.fullmatch(str(projection[field])):
            return {"ok": False, "current": False, "code": "BRAIN_CONTEXT_INTENT_PROJECTION_INVALID"}
    ready = bool(projection["ready"])
    return {
        "ok": True,
        "current": True,
        "ready": ready,
        "code": "BRAIN_CONTEXT_INTENT_PROJECTION_CURRENT" if ready else "BRAIN_CONTEXT_INTENT_PROJECTION_MATERIAL_UNKNOWN",
    }


def _contains_unsafe_memory_value(value: Any) -> bool:
    if isinstance(value, dict):
        for key, nested in value.items():
            lowered = str(key).lower()
            if any(part in lowered for part in ("password", "passwd", "secret", "api_key", "apikey", "credential", "cookie", "raw_prompt", "transcript")):
                return True
            if _contains_unsafe_memory_value(nested):
                return True
        return False
    if isinstance(value, list):
        return any(_contains_unsafe_memory_value(item) for item in value)
    if isinstance(value, str):
        return bool(BEARER_RE.search(value) or SK_RE.search(value) or SECRET_RE.search(value))
    return False


def _valid_native_memory_item(kind: str, item: Any) -> bool:
    if not isinstance(item, dict):
        return False
    expected_fields = {
        "preference": {"cardId", "cardRevision", "title", "effect", "statement", "conditions", "confidence", "strength"},
        "experience": {"cardId", "cardRevision", "title", "effect", "lesson", "reuseConditions", "prevention"},
        "procedure": {"cardId", "cardRevision", "title", "effect", "objective", "preconditions", "steps", "verification"},
        "note": {"cardId", "cardRevision", "title", "effect", "body", "links"},
        "reflection": {"cardId", "cardRevision", "title", "effect", "proposedAction", "candidateState", "confidence", "evidenceCount", "directConstraint"},
    }
    effects = {
        "preference": "shape_behavior",
        "experience": "reuse_as_advice",
        "procedure": "follow_governed_steps",
        "note": "reference_only",
        "reflection": "learning_candidate_only",
    }
    if kind not in expected_fields or item.get("effect") != effects[kind]:
        return False
    if kind != "reflection" and set(item) != expected_fields[kind]:
        return False
    if kind == "reflection":
        legacy_fields = expected_fields[kind]
        extended_fields = legacy_fields | {"suggestedKind", "trialEligible", "trialState", "trialVerdict", "trialReceiptRef", "trialReceiptHash", "trialReason"}
        if set(item) != legacy_fields and set(item) != extended_fields:
            return False
    if not isinstance(item.get("cardId"), str) or not item["cardId"] or len(item["cardId"]) > 160:
        return False
    if isinstance(item.get("cardRevision"), bool) or not isinstance(item.get("cardRevision"), int) or item["cardRevision"] < 1:
        return False
    if not isinstance(item.get("title"), str) or len(item["title"]) > 180:
        return False
    list_fields = {
        "preference": ("conditions",),
        "experience": ("reuseConditions",),
        "procedure": ("preconditions", "steps", "verification"),
        "note": ("links",),
        "reflection": (),
    }[kind]
    for field in list_fields:
        value = item.get(field)
        if not isinstance(value, list) or len(value) > 12 or any(not isinstance(part, str) or len(part) > 480 for part in value):
            return False
    body_fields = {
        "preference": ("statement",),
        "experience": ("lesson", "prevention"),
        "procedure": ("objective",),
        "note": ("body",),
        "reflection": ("proposedAction", "candidateState"),
    }[kind]
    for field in body_fields:
        if not isinstance(item.get(field), str) or len(str(item[field])) > 600:
            return False
    if kind in {"preference", "reflection"} and (isinstance(item.get("confidence"), bool) or not isinstance(item.get("confidence"), int) or not 0 <= item["confidence"] <= 100):
        return False
    if kind == "preference" and item.get("strength") not in {"normal", "strong"}:
        return False
    if kind == "reflection":
        if item.get("candidateState") not in {"validated", "staged", "adopted"} or item.get("directConstraint") is not False:
            return False
        if isinstance(item.get("evidenceCount"), bool) or not isinstance(item.get("evidenceCount"), int) or item["evidenceCount"] < 1:
            return False
        if "suggestedKind" in item and item.get("suggestedKind") not in {"", "preference", "experience", "decision", "procedure", "reflection", "note"}:
            return False
        if "trialEligible" in item and not isinstance(item.get("trialEligible"), bool):
            return False
        if "trialState" in item and item.get("trialState") not in {"not_started", "observed", "closed"}:
            return False
        if "trialVerdict" in item and item.get("trialVerdict") not in {"absent", "inconclusive", "passed", "failed"}:
            return False
        for field in ("trialReceiptRef", "trialReceiptHash", "trialReason"):
            if field in item and (not isinstance(item.get(field), str) or len(item[field]) > 240):
                return False
        if "trialReceiptHash" in item and item.get("trialReceiptHash") and not SHA256_RE.fullmatch(str(item["trialReceiptHash"])):
            return False
    return not _contains_unsafe_memory_value(item)


def read_native_memory_snapshot(
    memory_base: Path,
    *,
    now: datetime | None = None,
) -> tuple[list[dict[str, Any]] | None, str, str]:
    """Return validated entries, state, and snapshot payload hash without writes."""

    if native_memory_snapshot_dirty_path(memory_base).exists():
        return None, "dirty", ""
    try:
        raw = native_memory_snapshot_path(memory_base).read_bytes()
    except OSError:
        return None, "missing", ""
    if not raw or len(raw) > NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_BYTES:
        return None, "oversize", ""
    try:
        snapshot = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None, "invalid", ""
    if not isinstance(snapshot, dict):
        return None, "invalid", ""
    expected_snapshot_fields = {
        "schema", "generatedAt", "entryCount", "entries", "omitted", "truncated", "scopeRefAlgorithm",
        "activeOnly", "decisionConstraintsStored", "focusStored", "rawPromptStored", "rawSessionIdStored", "payloadHash",
    }
    fields = set(snapshot)
    if fields != expected_snapshot_fields and fields != expected_snapshot_fields | {"stagedReflectionProjection"}:
        return None, "invalid", ""
    payload_hash = snapshot.get("payloadHash")
    body = {key: value for key, value in snapshot.items() if key != "payloadHash"}
    if not isinstance(payload_hash, str) or not SHA256_RE.fullmatch(payload_hash) or canonical_hash(body) != payload_hash:
        return None, "hash_mismatch", ""
    if (
        snapshot.get("schema") != NATIVE_MEMORY_INFLUENCE_SNAPSHOT_SCHEMA
        or snapshot.get("activeOnly") is not True
        or snapshot.get("decisionConstraintsStored") is not False
        or snapshot.get("focusStored") is not False
        or snapshot.get("rawPromptStored") is not False
        or snapshot.get("rawSessionIdStored") is not False
        or snapshot.get("scopeRefAlgorithm") != "sha256(canonical-json:{scopeKey})"
        or not isinstance(snapshot.get("truncated"), bool)
        or ("stagedReflectionProjection" in snapshot and snapshot.get("stagedReflectionProjection") is not True)
    ):
        return None, "invalid", ""
    try:
        generated = datetime.fromisoformat(str(snapshot.get("generatedAt", "")).replace("Z", "+00:00"))
    except ValueError:
        return None, "invalid", ""
    if generated.tzinfo is None:
        return None, "invalid", ""
    reference_now = now or datetime.now(timezone.utc)
    if reference_now.tzinfo is None:
        reference_now = reference_now.replace(tzinfo=timezone.utc)
    age_seconds = (reference_now.astimezone(timezone.utc) - generated.astimezone(timezone.utc)).total_seconds()
    if age_seconds < 0:
        return None, "future", ""
    if age_seconds > NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_AGE_SECONDS:
        return None, "stale", ""
    entries = snapshot.get("entries")
    omitted = snapshot.get("omitted")
    if (
        isinstance(snapshot.get("entryCount"), bool)
        or not isinstance(snapshot.get("entryCount"), int)
        or not isinstance(entries, list)
        or snapshot["entryCount"] != len(entries)
        or len(entries) > 96
        or not isinstance(omitted, dict)
        or set(omitted) != {"invalid", "expired", "notReady", "unsafe"}
        or any(isinstance(value, bool) or not isinstance(value, int) or value < 0 for value in omitted.values())
        or _contains_unsafe_memory_value(omitted)
    ):
        return None, "invalid", ""
    expected_buckets = {
        "preference": "behaviorGuidance", "experience": "reusableAdvice", "procedure": "procedureSteps",
        "note": "references", "reflection": "learningCandidates",
    }
    priority = {"preference": 0, "experience": 1, "procedure": 2, "note": 3, "reflection": 4}
    valid: list[dict[str, Any]] = []
    for entry in sorted(entries, key=lambda value: (priority.get(str(value.get("kind", "")), 99), str(value.get("item", {}).get("cardId", "")))):
        if not isinstance(entry, dict) or set(entry) != {"kind", "bucket", "scopeKind", "scopeRef", "item"}:
            return None, "invalid", ""
        kind = str(entry.get("kind", ""))
        if kind not in expected_buckets or entry.get("bucket") != expected_buckets[kind]:
            return None, "invalid", ""
        if entry.get("scopeKind") not in {"global", "workspace", "task", "task_instance", "session"}:
            return None, "invalid", ""
        if not isinstance(entry.get("scopeRef"), str) or not SHA256_RE.fullmatch(str(entry["scopeRef"])):
            return None, "invalid", ""
        if not _valid_native_memory_item(kind, entry.get("item")):
            return None, "unsafe", ""
        valid.append(entry)
    return valid, "ready", payload_hash


def _memory_tokens(value: str) -> set[str]:
    lowered = re.sub(r"\s+", " ", value).strip().lower()
    tokens = set(re.findall(r"[a-z0-9][a-z0-9_-]{1,}", lowered))
    for run in re.findall(r"[\u4e00-\u9fff]+", lowered):
        if len(run) <= 16:
            tokens.add(run)
        tokens.update(run[index:index + 2] for index in range(max(0, len(run) - 1)))
    return tokens


def memory_item_matches_focus(item: dict[str, Any], focus: str) -> bool:
    if not focus:
        return False
    values: list[str] = []
    for value in item.values():
        if isinstance(value, str):
            values.append(value)
        elif isinstance(value, list):
            values.extend(part for part in value if isinstance(part, str))
    searchable = re.sub(r"\s+", " ", " ".join(values)).strip().lower()
    normalized_focus = re.sub(r"\s+", " ", focus).strip().lower()
    if len(normalized_focus) >= 4 and normalized_focus in searchable:
        return True
    if len(searchable) >= 4 and len(searchable) <= 160 and searchable in normalized_focus:
        return True
    return bool(_memory_tokens(normalized_focus) & _memory_tokens(searchable))


def select_native_memory_entries(
    memory_base: Path,
    scope_values: dict[str, str],
    focus: str,
    *,
    now: datetime | None = None,
    max_items: int = 5,
    matcher: Callable[[dict[str, Any], str], bool] = memory_item_matches_focus,
) -> dict[str, Any]:
    """Select at most one safe card per kind for a trusted host scope."""

    entries, state, snapshot_payload_hash = read_native_memory_snapshot(memory_base, now=now)
    result: dict[str, Any] = {
        "state": state,
        "snapshotLoaded": entries is not None,
        "snapshotPayloadHash": snapshot_payload_hash,
        "entries": [],
        "refs": [],
    }
    if entries is None:
        return result
    seen: set[str] = set()
    for entry in entries:
        kind = str(entry["kind"])
        if kind in seen:
            continue
        scope_value = str(scope_values.get(str(entry["scopeKind"]), ""))
        if not scope_value or entry["scopeRef"] != scope_ref(scope_value):
            continue
        item = entry["item"]
        if kind != "preference" and not matcher(item, focus):
            continue
        seen.add(kind)
        result["entries"].append(entry)
        result["refs"].append({"cardId": str(item["cardId"]), "cardRevision": int(item["cardRevision"]), "kind": kind})
        if len(result["entries"]) >= max_items:
            break
    if result["entries"]:
        result["state"] = "selected"
    return result
