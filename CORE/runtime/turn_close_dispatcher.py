"""Public, no-Hook turn-close dispatcher.

The execution contract remains the only writer/authority.  This adapter does
only three things: resolve the current scoped contract, apply the pure
turn-close policy, and (when the policy authorizes it) call the contract's
CloseTurn transaction with CAS fields.  Hooks may accelerate this path but are
not required for the state transition.
"""

from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import re
import subprocess
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from continuation_policy import decide_turn_close


SCHEMA = "super-brain.turn-close-dispatch.v1"
MAX_REFERENCE_CHARS = 240
MAX_PROGRESS_SENTENCE_CHARS = 320
MAX_PROGRESS_PHASE_CHARS = 120
MAX_PROGRESS_STEP_CHARS = 220
MAX_PROGRESS_NEXT_ACTION_CHARS = 360
MAX_PROJECT_PROGRESS_PROOF_BYTES = 32 * 1024
MAX_PROJECT_PROGRESS_ITEMS = 24
MAX_PROJECT_PROGRESS_EVIDENCE = 16
MAX_PROJECT_PROGRESS_VERIFICATIONS = 16
# Every governed H7 mutation crosses the Python-to-PowerShell authority
# boundary at least twice (Resolve/Get plus CAS Set). Under a parallel verifier
# run, an 8-second process budget can expire just before a healthy authority
# returns. Keep the public default compact, but enforce one bounded 12-second
# floor for each transaction; callers may still request more.
MIN_AUTHORITY_TRANSACTION_TIMEOUT_SECONDS = 12.0
DEFAULT_TIMEOUT_SECONDS = 8.0
VISIBLE_PROGRESS_SOURCES = {"assistant_visible_reply", "user_attested_visible_reply"}


def _compact(value: Any, maximum: int = MAX_REFERENCE_CHARS) -> str:
    text = " ".join(str(value or "").strip().split())
    text = re.sub(r"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*", "Bearer [REDACTED]", text)
    text = re.sub(r"(?i)\bsk-[A-Za-z0-9_-]{8,}\b", "[REDACTED_KEY]", text)
    text = re.sub(
        r"(?i)\b(api[_ -]?key|password|passwd|token|secret)\s*[:=]\s*[^\s,;]+",
        r"\1=[REDACTED]",
        text,
    )
    if len(text) > maximum:
        return text[: maximum - 3].rstrip() + "..."
    return text


def _parse_json_output(text: str) -> dict[str, Any] | None:
    cleaned = str(text or "").lstrip("\ufeff").strip()
    if not cleaned:
        return None
    try:
        value = json.loads(cleaned)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        pass
    for line in reversed(cleaned.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start < 0 or end < start:
        return None
    try:
        value = json.loads(cleaned[start : end + 1])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def _powershell() -> str:
    return "powershell.exe" if os.name == "nt" else "powershell"


def _stable_hash(value: str, length: int = 24) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def _normalize_session_key(value: str) -> str:
    candidate = str(value or "").strip()
    if not candidate:
        return ""
    if re.fullmatch(r"sid-[0-9a-f]{16,64}", candidate, re.IGNORECASE):
        return candidate.lower()
    return "sid-" + _stable_hash(candidate, 24)


def _normalize_workspace_key(value: str, *, base: Path) -> str:
    candidate = str(value or "").strip()
    if not candidate:
        return ""
    if re.fullmatch(r"ws-[0-9a-f]{24}", candidate, re.IGNORECASE):
        return candidate.lower()
    try:
        path = Path(candidate).expanduser()
        if not path.is_absolute():
            path = base / path
        normalized = str(path.resolve()).rstrip("\\/").lower()
    except OSError:
        normalized = candidate.lower()
    return "ws-" + _stable_hash(normalized, 24)


def _authority_transaction_timeout(value: float) -> float:
    """Return the bounded authority-process budget for one H7 transaction.

    This is deliberately a floor rather than a retry loop that relaxes CAS or
    proof checks.  A slow process may be retried only with the same deterministic
    transition id; the execution-contract authority still verifies revision,
    plan fingerprint, project proof, and idempotent-replay payload equality.
    """

    try:
        requested = float(value)
    except (TypeError, ValueError):
        requested = DEFAULT_TIMEOUT_SECONDS
    if not math.isfinite(requested):
        requested = DEFAULT_TIMEOUT_SECONDS
    return max(MIN_AUTHORITY_TRANSACTION_TIMEOUT_SECONDS, requested)


def _invoke_contract(
    package_root: Path,
    state_root: Path,
    *,
    action: str,
    task_id: str,
    workspace_key: str,
    session_key: str,
    timeout: float,
    extra: list[str] | None = None,
) -> tuple[int, dict[str, Any] | None]:
    script = package_root / "scripts" / "execution-contract.ps1"
    if not script.is_file():
        return 1, None
    command = [
        _powershell(),
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-Action",
        action,
        "-WorkspaceKey",
        workspace_key,
        "-SessionKey",
        session_key,
        "-StateRoot",
        str(state_root),
        "-NoExit",
        "-Json",
    ]
    if task_id:
        command.extend(["-TaskId", task_id])
    command.extend(extra or [])
    environment = os.environ.copy()
    environment["CODEX_THREAD_ID"] = session_key
    environment.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
    environment.pop("SUPER_BRAIN_STATE_ROOT", None)
    try:
        completed = subprocess.run(
            command,
        # Preserve the real host workspace cwd.  The PowerShell authority
        # normalizes non-canonical workspace inputs relative to that cwd;
        # forcing the package directory here would bind a valid host task to
        # a different workspace key.
        cwd=os.getcwd(),
            env=environment,
            input="",
            text=True,
            # execution-contract.ps1 explicitly emits UTF-8.  Relying on the
            # Windows ANSI locale turns a valid Chinese progress checkpoint
            # into a false transaction failure before the authority sees it.
            encoding="utf-8",
            errors="strict",
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=max(0.25, float(timeout)),
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return 1, None
    return completed.returncode, _parse_json_output(completed.stdout)


def _base_result(
    *,
    policy: dict[str, Any],
    resolution: dict[str, Any] | None,
    code: str = "",
    state_mutated: bool = False,
) -> dict[str, Any]:
    return {
        "ok": True,
        "schema": SCHEMA,
        "code": code or "TURN_CLOSE_DISPATCH_POLICY_ONLY",
        "stateMutated": bool(state_mutated),
        "policy": policy,
        "resolution": {
            "taskId": _compact((resolution or {}).get("taskId"), 120),
            "focusId": _compact((resolution or {}).get("focusId"), 120),
            "focusLabel": _compact((resolution or {}).get("focusLabel"), 140),
            "contractRevision": int((resolution or {}).get("contractRevision", 0) or 0),
            "planFingerprint": _compact((resolution or {}).get("planFingerprint"), 96),
            "sessionAccess": _compact((resolution or {}).get("sessionAccess"), 48),
            "actionAuthorization": _compact((resolution or {}).get("actionAuthorization"), 32),
        },
        "transition": None,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _transition_summary(value: dict[str, Any] | None, *, transition_id: str = "") -> dict[str, Any]:
    value = value if isinstance(value, dict) else {}
    last = value.get("lastTransition") if isinstance(value.get("lastTransition"), dict) else {}
    resolved_id = _compact(
        value.get("replayedTransitionId") or value.get("transitionId") or last.get("transitionId") or transition_id,
        120,
    )
    return {
        "ok": value.get("ok") is True,
        "schema": _compact(value.get("schema") or "super-brain.execution-contract.v1", 96),
        "action": _compact(value.get("transitionAction") or last.get("action") or "ResumeParent", 48),
        "transitionId": resolved_id,
        "revision": int(value.get("revision", value.get("originalResultRevision", 0)) or 0),
        "taskId": _compact(value.get("taskId"), 160),
        "focusId": _compact(value.get("focusId"), 120),
        "focusLabel": _compact(value.get("focusLabel"), 140),
        "nextAction": _compact(value.get("nextAction"), 280),
        "currentStep": _compact(value.get("currentStep"), 240),
        "idempotentReplay": bool(value.get("idempotentReplay")),
        "resumedBranchStatus": _compact(value.get("resumedBranchStatus"), 32),
        "decision": _compact(value.get("decision"), 64),
        "policyDecision": _compact(value.get("policyDecision"), 96),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _normalize_progress_checkpoint(value: Any) -> tuple[dict[str, str] | None, str]:
    """Accept one bounded assistant-authored state checkpoint.

    This is intentionally not a prompt or transcript channel.  The host must
    provide an already-visible summary of the assistant's own progress, with
    exactly the fields needed to restore the active workline.  H7 rejects
    normalization here: a recovery anchor must never become text the user did
    not actually see.
    """

    if not isinstance(value, Mapping):
        return None, "H7_PROGRESS_CHECKPOINT_INVALID"
    required = {
        "last_confirmed_sentence": MAX_PROGRESS_SENTENCE_CHARS,
        "current_phase": MAX_PROGRESS_PHASE_CHARS,
        "current_step": MAX_PROGRESS_STEP_CHARS,
        "next_action": MAX_PROGRESS_NEXT_ACTION_CHARS,
        "source": 64,
    }
    if set(value) != set(required):
        return None, "H7_PROGRESS_CHECKPOINT_FIELDS_INVALID"
    normalized: dict[str, str] = {}
    for field, maximum in required.items():
        raw = value.get(field)
        if not isinstance(raw, str):
            return None, "H7_PROGRESS_CHECKPOINT_FIELDS_INVALID"
        if field == "source":
            if raw not in VISIBLE_PROGRESS_SOURCES:
                return None, "H7_PROGRESS_CHECKPOINT_SOURCE_INVALID"
            normalized[field] = raw
            continue
        compact = _compact(raw, maximum)
        if not compact or compact != raw or "\n" in raw or "\r" in raw:
            return None, "H7_PROGRESS_CHECKPOINT_FIELDS_INVALID"
        normalized[field] = compact
    return normalized, "H7_PROGRESS_CHECKPOINT_CURRENT"


def _project_progress_text(value: Any, maximum: int) -> str | None:
    if not isinstance(value, str):
        return None
    compact = _compact(value, maximum)
    # The input is a structured assistant proof, not a lossy prompt transport.
    # Reject values that need normalization/redaction instead of changing the
    # material the contract will hash and bind.
    return compact if compact and compact == value else None


def _normalize_project_progress_proof(value: Any) -> tuple[dict[str, Any] | None, str]:
    """Validate bounded H7 project-progress input before Base64 transport.

    The PowerShell authority performs the live project-file/hash validation and
    emits the final proof.  This boundary only accepts the fixed, non-prompt
    input shape so a malformed or secret-bearing object never reaches durable
    state through the command line.
    """

    if not isinstance(value, Mapping):
        return None, "H7_PROJECT_PROGRESS_INPUT_INVALID"
    expected = {
        "schema",
        "phase",
        "currentStep",
        "completedItems",
        "projectEvidence",
        "verificationResults",
        "nextAction",
    }
    if set(value) != expected or value.get("schema") != "super-brain.project-progress-input.v1":
        return None, "H7_PROJECT_PROGRESS_INPUT_FIELDS_INVALID"
    phase = _project_progress_text(value.get("phase"), MAX_PROGRESS_PHASE_CHARS)
    current_step = _project_progress_text(value.get("currentStep"), MAX_PROGRESS_STEP_CHARS)
    next_action = _project_progress_text(value.get("nextAction"), MAX_PROGRESS_NEXT_ACTION_CHARS)
    completed_items = value.get("completedItems")
    project_evidence = value.get("projectEvidence")
    verification_results = value.get("verificationResults")
    if (
        not phase
        or not current_step
        or not next_action
        or not isinstance(completed_items, list)
        or not isinstance(project_evidence, list)
        or not isinstance(verification_results, list)
        or len(completed_items) > MAX_PROJECT_PROGRESS_ITEMS
        or len(project_evidence) > MAX_PROJECT_PROGRESS_EVIDENCE
        or len(verification_results) > MAX_PROJECT_PROGRESS_VERIFICATIONS
    ):
        return None, "H7_PROJECT_PROGRESS_INPUT_FIELDS_INVALID"
    evidence_refs: set[str] = set()
    normalized_evidence: list[dict[str, str]] = []
    for item in project_evidence:
        if not isinstance(item, Mapping) or set(item) != {"kind", "relativePath", "sha256"}:
            return None, "H7_PROJECT_PROGRESS_INPUT_EVIDENCE_INVALID"
        relative_path = item.get("relativePath")
        digest = item.get("sha256")
        if (
            item.get("kind") != "project_file"
            or not isinstance(relative_path, str)
            or not isinstance(digest, str)
            or len(relative_path) > 240
            or not relative_path
            or relative_path.startswith(("/", "\\"))
            or ":" in relative_path
            or any(part in {"", ".", ".."} for part in relative_path.replace("\\", "/").split("/"))
            or not re.fullmatch(r"[a-f0-9]{64}", digest)
        ):
            return None, "H7_PROJECT_PROGRESS_INPUT_EVIDENCE_INVALID"
        normalized_path = relative_path.replace("\\", "/")
        reference = f"project:file:{normalized_path}@sha256:{digest}"
        if reference in evidence_refs:
            return None, "H7_PROJECT_PROGRESS_INPUT_EVIDENCE_INVALID"
        evidence_refs.add(reference)
        normalized_evidence.append({"kind": "project_file", "relativePath": normalized_path, "sha256": digest})
    verification_by_id: dict[str, str] = {}
    normalized_verifications: list[dict[str, str]] = []
    for item in verification_results:
        if not isinstance(item, Mapping) or set(item) != {"id", "status"}:
            return None, "H7_PROJECT_PROGRESS_INPUT_VERIFICATION_INVALID"
        identifier = item.get("id")
        status = item.get("status")
        if (
            not isinstance(identifier, str)
            or not re.fullmatch(r"[A-Za-z0-9._:-]{1,120}", identifier)
            or status not in {"passed", "failed", "not_run"}
            or identifier in verification_by_id
        ):
            return None, "H7_PROJECT_PROGRESS_INPUT_VERIFICATION_INVALID"
        verification_by_id[identifier] = str(status)
        normalized_verifications.append({"id": identifier, "status": str(status)})
    seen_items: set[str] = set()
    normalized_items: list[dict[str, Any]] = []
    for item in completed_items:
        if not isinstance(item, Mapping) or set(item) != {"itemKey", "evidenceRefs", "verificationIds"}:
            return None, "H7_PROJECT_PROGRESS_INPUT_COMPLETED_ITEM_INVALID"
        item_key = _project_progress_text(item.get("itemKey"), 180)
        item_refs = item.get("evidenceRefs")
        verification_ids = item.get("verificationIds")
        normalized_key = " ".join(str(item_key or "").split()).lower()
        if (
            not item_key
            or not normalized_key
            or normalized_key in seen_items
            or not isinstance(item_refs, list)
            or not isinstance(verification_ids, list)
            or not item_refs
            or not verification_ids
            or len(item_refs) > 8
            or len(verification_ids) > 8
            or any(not isinstance(reference, str) or reference not in evidence_refs for reference in item_refs)
            or any(not isinstance(identifier, str) or verification_by_id.get(identifier) != "passed" for identifier in verification_ids)
            or len(set(item_refs)) != len(item_refs)
            or len(set(verification_ids)) != len(verification_ids)
        ):
            return None, "H7_PROJECT_PROGRESS_INPUT_COMPLETED_ITEM_INVALID"
        seen_items.add(normalized_key)
        normalized_items.append(
            {"itemKey": normalized_key, "evidenceRefs": list(item_refs), "verificationIds": list(verification_ids)}
        )
    normalized: dict[str, Any] = {
        "schema": "super-brain.project-progress-input.v1",
        "phase": phase,
        "currentStep": current_step,
        "completedItems": normalized_items,
        "projectEvidence": normalized_evidence,
        "verificationResults": normalized_verifications,
        "nextAction": next_action,
    }
    try:
        serialized = json.dumps(normalized, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        return None, "H7_PROJECT_PROGRESS_INPUT_INVALID"
    if len(serialized) > MAX_PROJECT_PROGRESS_PROOF_BYTES:
        return None, "H7_PROJECT_PROGRESS_INPUT_TOO_LARGE"
    return normalized, "H7_PROJECT_PROGRESS_INPUT_CURRENT"


def _normalize_project_root(value: str | Path | None) -> Path | None:
    try:
        root = Path(value).expanduser().resolve() if value is not None else Path.cwd().resolve()
    except (OSError, ValueError):
        return None
    return root if root.is_dir() else None


def _reconcile_progress_checkpoint(
    package_root: Path,
    state_root: Path,
    *,
    task_id: str,
    workspace_key: str,
    session_key: str,
    checkpoint: Mapping[str, str],
    transition_id: str,
    previous_revision: int,
    timeout: float,
) -> dict[str, Any] | None:
    """Recognize the narrow case where a timed-out Set already committed.

    A Windows PowerShell child may finish the atomic write just after the
    launcher times out.  Treat that as success only when the authoritative
    contract contains the deterministic transition id, all five exact
    source-qualified checkpoint fields, and its visible-progress receipt.
    Any other uncertain result remains failed closed.
    """

    get_code, reconciled = _invoke_contract(
        package_root,
        state_root,
        action="Get",
        task_id=task_id,
        workspace_key=workspace_key,
        session_key=session_key,
        timeout=timeout,
    )
    if get_code != 0 or not isinstance(reconciled, dict) or reconciled.get("ok") is not True:
        return None
    receipts = reconciled.get("transitionReceipts")
    has_transition = isinstance(receipts, list) and any(
        isinstance(receipt, Mapping) and str(receipt.get("transitionId", "")) == transition_id
        for receipt in receipts
    )
    matches_checkpoint = (
        str(reconciled.get("lastConfirmedSentence", "")) == checkpoint["last_confirmed_sentence"]
        and str(reconciled.get("lastConfirmedSource", "")) == checkpoint["source"]
        and str(reconciled.get("currentPhase", "")) == checkpoint["current_phase"]
        and str(reconciled.get("currentStep", "")) == checkpoint["current_step"]
        and str(reconciled.get("nextAction", "")) == checkpoint["next_action"]
    )
    visible = reconciled.get("visibleProgressReceipt") if isinstance(reconciled.get("visibleProgressReceipt"), Mapping) else {}
    receipt_matches = (
        str(visible.get("source", "")) == checkpoint["source"]
        and str(visible.get("sentenceHash", "")) == hashlib.sha256(checkpoint["last_confirmed_sentence"].encode("utf-8")).hexdigest()
        and str(visible.get("currentPhase", "")) == checkpoint["current_phase"]
        and str(visible.get("currentStep", "")) == checkpoint["current_step"]
        and str(visible.get("nextAction", "")) == checkpoint["next_action"]
        and str(visible.get("transitionId", "")) == transition_id
    )
    if not has_transition or not matches_checkpoint or not receipt_matches:
        return None
    try:
        reconciled_revision = int(reconciled.get("revision", previous_revision) or previous_revision)
    except (TypeError, ValueError):
        reconciled_revision = previous_revision
    return {
        "ok": True,
        "schema": SCHEMA,
        "code": "H7_PROGRESS_CHECKPOINT_RECONCILED",
        "stateMutated": reconciled_revision > previous_revision,
        "taskId": _compact(reconciled.get("taskId") or task_id, 160),
        "revision": reconciled_revision,
        "transitionId": transition_id,
        "lastConfirmedSource": checkpoint["source"],
        "visibleProgress": {
            "state": "current",
            "source": checkpoint["source"],
            "sentenceHash": hashlib.sha256(checkpoint["last_confirmed_sentence"].encode("utf-8")).hexdigest(),
            "payloadHash": str(visible.get("payloadHash", "")),
            "projectProgressPayloadHash": str(visible.get("projectProgressPayloadHash", "")),
        },
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def record_progress_checkpoint(
    package_root: str | Path,
    state_root: str | Path,
    *,
    task_id: str = "",
    workspace_key: str = "",
    session_key: str = "",
    progress_checkpoint: Mapping[str, Any] | None = None,
    project_progress_proof: Mapping[str, Any] | None = None,
    project_root: str | Path | None = None,
    transition_id: str = "",
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Atomically bind latest assistant progress to the active H7 contract.

    The old prompt hook could infer arbitrary user text.  H7 must not do that:
    it accepts only a five-field, source-qualified assistant checkpoint and writes it
    through the existing CAS-protected execution-contract authority.
    """

    package = Path(package_root).expanduser().resolve()
    state = Path(state_root).expanduser().resolve()
    transaction_timeout = _authority_transaction_timeout(timeout)
    workspace = _normalize_workspace_key(workspace_key, base=Path.cwd())
    session = _normalize_session_key(session_key)
    checkpoint, checkpoint_code = _normalize_progress_checkpoint(progress_checkpoint)
    if checkpoint is None:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": checkpoint_code,
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    proof: dict[str, Any] | None = None
    proof_serialized = ""
    if project_progress_proof is not None:
        proof, proof_code = _normalize_project_progress_proof(project_progress_proof)
        if proof is None:
            return {
                "ok": False,
                "schema": SCHEMA,
                "code": proof_code,
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        proof_serialized = json.dumps(proof, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    root = _normalize_project_root(project_root)
    if root is None:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "H7_PROJECT_PROGRESS_ROOT_REQUIRED",
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    if not workspace or not session:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "H7_PROGRESS_CHECKPOINT_SCOPE_REQUIRED",
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    requested_task = _compact(task_id, 160)
    get_code, current = _invoke_contract(
        package,
        state,
        action="Get",
        task_id=requested_task,
        workspace_key=workspace,
        session_key=session,
        timeout=transaction_timeout,
    )
    if get_code != 0 or not isinstance(current, dict) or current.get("ok") is not True:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "H7_PROGRESS_CHECKPOINT_CONTRACT_UNAVAILABLE",
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    resolved_task = _compact(current.get("taskId") or requested_task, 160)
    try:
        revision = int(current.get("revision", current.get("contractRevision", 0)) or 0)
    except (TypeError, ValueError):
        revision = 0
    plan_receipt = current.get("planReceipt") if isinstance(current.get("planReceipt"), Mapping) else {}
    fingerprint = _compact(current.get("planFingerprint") or plan_receipt.get("planFingerprint"), 96)
    if not resolved_task or revision <= 0 or not fingerprint:
        return {
            "ok": False,
            "schema": SCHEMA,
            "code": "H7_PROGRESS_CHECKPOINT_CAS_FIELDS_MISSING",
            "stateMutated": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    stable_payload = json.dumps(
        {
            "taskId": resolved_task,
            "workspaceKey": workspace,
            "ownerSessionKey": session,
            "checkpoint": checkpoint,
            "projectProgressInputHash": hashlib.sha256(proof_serialized.encode("utf-8")).hexdigest() if proof_serialized else "",
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    resolved_transition = _compact(transition_id, 120) or (
        "h7-progress-" + hashlib.sha256(stable_payload.encode("utf-8")).hexdigest()[:32]
    )
    transport_checkpoint = base64.b64encode(
        json.dumps(checkpoint, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")
    transport_proof = base64.b64encode(proof_serialized.encode("utf-8")).decode("ascii") if proof_serialized else ""
    set_extra = [
        "-ProgressCheckpointBase64", transport_checkpoint,
        "-ProjectRoot", str(root),
        "-ExpectedRevision", str(revision),
        "-ExpectedPlanFingerprint", fingerprint,
        "-TransitionId", resolved_transition,
        "-Source", "turn-runtime:assistant-progress-checkpoint",
    ]
    if transport_proof:
        set_extra.extend(["-ProjectProgressProofBase64", transport_proof])
    set_code, updated = _invoke_contract(
        package,
        state,
        action="Set",
        task_id=resolved_task,
        workspace_key=workspace,
        session_key=session,
        timeout=transaction_timeout,
        extra=set_extra,
    )
    if set_code != 0 or not isinstance(updated, dict) or updated.get("ok") is not True:
        reconciled = _reconcile_progress_checkpoint(
            package,
            state,
            task_id=resolved_task,
            workspace_key=workspace,
            session_key=session,
            checkpoint=checkpoint,
            transition_id=resolved_transition,
            previous_revision=revision,
            timeout=transaction_timeout,
        )
        if reconciled is not None:
            return reconciled
        if updated is not None:
            return {
                "ok": False,
                "schema": SCHEMA,
                "code": "H7_PROGRESS_CHECKPOINT_TRANSACTION_FAILED",
                "contractCode": str(updated.get("code", "")),
                "contractReason": _compact(updated.get("reason", ""), 160),
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        # A transport failure may happen before PowerShell starts or after it
        # commits.  Retry once with the *same* deterministic transition id and
        # payload.  The authority treats an already committed matching Set as
        # an idempotent replay; any changed revision/proof/fingerprint remains
        # rejected by its normal CAS guards.  This adds no weaker mutation path.
        retry_code, retried = _invoke_contract(
            package,
            state,
            action="Set",
            task_id=resolved_task,
            workspace_key=workspace,
            session_key=session,
            timeout=transaction_timeout,
            extra=set_extra,
        )
        if retry_code == 0 and isinstance(retried, dict) and retried.get("ok") is True:
            updated = retried
        else:
            reconciled = _reconcile_progress_checkpoint(
                package,
                state,
                task_id=resolved_task,
                workspace_key=workspace,
                session_key=session,
                checkpoint=checkpoint,
                transition_id=resolved_transition,
                previous_revision=revision,
                timeout=transaction_timeout,
            )
            if reconciled is not None:
                return reconciled
            failure = retried if isinstance(retried, dict) else updated
            return {
                "ok": False,
                "schema": SCHEMA,
                "code": "H7_PROGRESS_CHECKPOINT_TRANSACTION_FAILED",
                "contractCode": str((failure or {}).get("code", "")) if isinstance(failure, dict) else "",
                "contractReason": _compact((failure or {}).get("reason", ""), 160) if isinstance(failure, dict) else "",
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
    return {
        "ok": True,
        "schema": SCHEMA,
        "code": "H7_PROGRESS_CHECKPOINT_REPLAYED" if bool(updated.get("idempotentReplay")) else "H7_PROGRESS_CHECKPOINT_WRITTEN",
        "stateMutated": not bool(updated.get("idempotentReplay")),
        "taskId": _compact(updated.get("taskId") or resolved_task, 160),
        "revision": int(updated.get("revision", revision) or revision),
        "transitionId": resolved_transition,
        "lastConfirmedSource": checkpoint["source"],
        "projectProgress": {
            "state": str(((updated.get("projectProgressProof") or {}) if isinstance(updated.get("projectProgressProof"), dict) else {}).get("state", "withheld")),
            "payloadHash": str(((updated.get("projectProgressProof") or {}) if isinstance(updated.get("projectProgressProof"), dict) else {}).get("payloadHash", "")),
        },
        "visibleProgress": {
            "state": "current",
            "source": str(((updated.get("visibleProgressReceipt") or {}) if isinstance(updated.get("visibleProgressReceipt"), dict) else {}).get("source", "")),
            "sentenceHash": str(((updated.get("visibleProgressReceipt") or {}) if isinstance(updated.get("visibleProgressReceipt"), dict) else {}).get("sentenceHash", "")),
            "payloadHash": str(((updated.get("visibleProgressReceipt") or {}) if isinstance(updated.get("visibleProgressReceipt"), dict) else {}).get("payloadHash", "")),
            "projectProgressPayloadHash": str(((updated.get("visibleProgressReceipt") or {}) if isinstance(updated.get("visibleProgressReceipt"), dict) else {}).get("projectProgressPayloadHash", "")),
        },
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def dispatch_turn_close(
    package_root: str | Path,
    state_root: str | Path,
    *,
    task_id: str = "",
    workspace_key: str = "",
    session_key: str = "",
    turn_outcome: str = "unknown",
    user_control: str = "unknown",
    completion_evidence_ref: str = "",
    transition_id: str = "",
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Resolve and, if safe, execute one CAS-bound CloseTurn transition."""

    package = Path(package_root).expanduser().resolve()
    state = Path(state_root).expanduser().resolve()
    transaction_timeout = _authority_transaction_timeout(timeout)
    task = _compact(task_id, 160)
    workspace = _normalize_workspace_key(workspace_key, base=Path.cwd())
    session = _normalize_session_key(session_key)
    evidence = _compact(completion_evidence_ref, MAX_REFERENCE_CHARS)
    if not workspace or not session:
        policy = {
            "ok": True,
            "schema": "super-brain.continuation-policy.v1",
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_SCOPE_REQUIRED",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
            "branchStatus": "",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return _base_result(policy=policy, resolution=None, code="TURN_CLOSE_DISPATCH_SCOPE_REQUIRED")

    resolve_code, resolution = _invoke_contract(
        package,
        state,
        action="Resolve",
        task_id=task,
        workspace_key=workspace,
        session_key=session,
        timeout=transaction_timeout,
    )
    if resolve_code != 0 or not isinstance(resolution, dict):
        policy = {
            "ok": True,
            "schema": "super-brain.continuation-policy.v1",
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_RESOLUTION_UNAVAILABLE",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
            "branchStatus": "",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return _base_result(policy=policy, resolution=resolution, code="TURN_CLOSE_DISPATCH_RESOLUTION_UNAVAILABLE")

    stable_seed = "|".join((str(resolution.get("taskId") or task), workspace, session, str(turn_outcome), evidence))
    transition = _compact(transition_id, 120) or "turn-close-" + hashlib.sha256(stable_seed.encode("utf-8")).hexdigest()[:32]
    prior_receipts = resolution.get("transitionReceipts")
    if not isinstance(prior_receipts, list):
        # Resolve intentionally returns a compact packet.  Read the same
        # scoped contract once more only to inspect the bounded transition
        # ledger for an idempotent replay; no raw prompt or transcript is
        # opened or returned.
        get_code, full_contract = _invoke_contract(
            package,
            state,
            action="Get",
            task_id=_compact(resolution.get("taskId") or task, 160),
            workspace_key=workspace,
            session_key=session,
            timeout=transaction_timeout,
        )
        if get_code == 0 and isinstance(full_contract, dict):
            prior_receipts = full_contract.get("transitionReceipts")
    if isinstance(prior_receipts, list):
        replay = next((item for item in prior_receipts if isinstance(item, dict) and str(item.get("transitionId", "")) == transition), None)
        # A close may carry a progress checkpoint in the same outer turn.  A
        # checkpoint is a normal ``Set`` transition, never evidence that a
        # parent was resumed.  Only a real ResumeParent ledger entry may be
        # replayed as a parent-return outcome.
        if replay and str(replay.get("action", "")) == "ResumeParent":
            result = _base_result(
                policy={
                    "ok": True,
                    "schema": "super-brain.continuation-policy.v1",
                    "decision": "resume_parent_required",
                    "code": "CONTINUATION_POLICY_RESUME_PARENT_REQUIRED",
                    "terminalReplyAllowed": False,
                    "requiresParentResume": True,
                    "branchStatus": "completed" if str(turn_outcome) == "side_branch_completed" else "partial",
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                },
                resolution=resolution,
                code="TURN_CLOSE_DISPATCH_IDEMPOTENT_REPLAY",
            )
            result["transition"] = _transition_summary(
                {
                    "ok": True,
                    "schema": "super-brain.execution-contract.v1",
                    "transitionAction": str(replay.get("action") or "ResumeParent"),
                    "replayedTransitionId": transition,
                    "originalResultRevision": replay.get("resultRevision", 0),
                    "taskId": resolution.get("taskId"),
                    "focusId": resolution.get("focusId"),
                    "focusLabel": resolution.get("focusLabel"),
                    "idempotentReplay": True,
                },
                transition_id=transition,
            )
            return result

    policy = decide_turn_close(
        resolution,
        turn_outcome=str(turn_outcome or "unknown"),
        user_control=str(user_control or "unknown"),
        completion_evidence_present=bool(evidence),
    )
    result = _base_result(policy=policy, resolution=resolution)
    if policy.get("decision") != "resume_parent_required":
        result["code"] = "TURN_CLOSE_DISPATCH_POLICY_ONLY"
        return result

    resolved_task = _compact(resolution.get("taskId") or task, 160)
    try:
        revision = int(resolution.get("contractRevision", 0) or 0)
    except (TypeError, ValueError):
        revision = 0
    fingerprint = _compact(resolution.get("planFingerprint"), 96)
    if not resolved_task or revision <= 0 or not fingerprint:
        result["code"] = "TURN_CLOSE_DISPATCH_CAS_FIELDS_MISSING"
        result["policy"] = {
            **policy,
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_CAS_FIELDS_MISSING",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
        }
        return result

    close_args = [
        "-TurnOutcome",
        str(turn_outcome),
        "-UserControl",
        str(user_control),
        "-CompletionEvidence",
        evidence,
        "-ExpectedRevision",
        str(revision),
        "-ExpectedPlanFingerprint",
        fingerprint,
        "-TransitionId",
        transition,
    ]
    project_root = _normalize_project_root(None)
    if project_root is None:
        result["code"] = "TURN_CLOSE_DISPATCH_PROJECT_ROOT_UNAVAILABLE"
        result["policy"] = {
            **policy,
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_PROJECT_ROOT_UNAVAILABLE",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
        }
        return result
    close_args.extend(["-ProjectRoot", str(project_root)])
    close_code, closed = _invoke_contract(
        package,
        state,
        action="CloseTurn",
        task_id=resolved_task,
        workspace_key=workspace,
        session_key=session,
        timeout=transaction_timeout,
        extra=close_args,
    )
    if close_code != 0 or not isinstance(closed, dict) or closed.get("ok") is not True:
        result["code"] = "TURN_CLOSE_DISPATCH_TRANSACTION_FAILED"
        result["contractCode"] = str((closed or {}).get("code", "")) if isinstance(closed, dict) else ""
        result["contractReason"] = _compact((closed or {}).get("reason", ""), 160) if isinstance(closed, dict) else ""
        result["policy"] = {
            **policy,
            "decision": "withhold_reconcile",
            "code": "CONTINUATION_POLICY_TRANSACTION_FAILED",
            "terminalReplyAllowed": True,
            "requiresParentResume": False,
        }
        result["transition"] = {"transitionId": transition, "action": "ResumeParent", "error": "transaction_failed", "rawPromptStored": False, "rawTranscriptStored": False}
        return result

    result["code"] = "TURN_CLOSE_DISPATCH_RESUMED_PARENT"
    result["stateMutated"] = not bool(closed.get("idempotentReplay"))
    result["transition"] = _transition_summary(closed, transition_id=transition)
    return result


__all__ = ["dispatch_turn_close", "record_progress_checkpoint", "SCHEMA"]
