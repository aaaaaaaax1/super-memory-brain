from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from brain_control import read_mcp_snapshot, read_mcp_task_projection
from brain_core import DEFAULT_RECALL_MAX_TOKENS, DEFAULT_RECALL_TOP_K, BrainCore
from activation_receipt import ensure_current
from turn_runtime import run_turn
from turn_intent import TURN_INTENTS


def response(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def tool_result(payload: Any, is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False, separators=(",", ":"))}],
        "isError": is_error,
    }


_CODEX_THREAD_ID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.IGNORECASE)


def _metadata_mappings(request: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    """Return supported MCP metadata envelopes without trusting arguments.

    MCP convention puts request metadata under ``params._meta``.  A few
    transports forward it at the JSON-RPC request level, so accept that
    equivalent envelope as well.  User tool arguments are intentionally never
    considered Host identity.
    """

    candidates: list[Mapping[str, Any]] = []
    params = request.get("params")
    if isinstance(params, Mapping) and isinstance(params.get("_meta"), Mapping):
        candidates.append(params["_meta"])
    if isinstance(request.get("_meta"), Mapping):
        candidates.append(request["_meta"])
    return candidates


def _metadata_string(value: Any, *, maximum: int) -> str:
    if not isinstance(value, str):
        return ""
    compact = value.strip()
    if not compact or len(compact) > maximum or any(ord(char) < 32 for char in compact):
        return ""
    return compact


def _workspace_scope_from_metadata(workspaces: Any) -> tuple[str, Path] | None:
    """Keep one verified Desktop workspace root only for this request."""

    if not isinstance(workspaces, Mapping) or len(workspaces) != 1:
        return None
    raw_root = next(iter(workspaces.keys()))
    root = _metadata_string(raw_root, maximum=2048)
    if not root:
        return None
    try:
        if not os.path.isabs(root):
            return None
        root_path = Path(root).expanduser().resolve()
        normalized = str(root_path).rstrip("/\\").lower()
    except (OSError, ValueError):
        return None
    if not normalized or not root_path.is_dir():
        return None
    return "ws-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24], root_path


def _workspace_key_from_metadata(workspaces: Any) -> str:
    """Hash exactly one Desktop workspace root; ambiguous metadata fails closed."""

    scoped = _workspace_scope_from_metadata(workspaces)
    return scoped[0] if scoped is not None else ""


def host_scope_binding_from_request(request: Mapping[str, Any]) -> tuple[tuple[str, str], Path] | None:
    """Extract the opaque scope plus an ephemeral workspace root for H7 rechecks.

    The raw path is held only while the request is executing.  It is neither
    emitted by MCP nor copied into the runtime's durable state.
    """

    candidates: list[tuple[tuple[str, str], Path]] = []
    for metadata in _metadata_mappings(request):
        turn_metadata = metadata.get("x-codex-turn-metadata")
        if not isinstance(turn_metadata, Mapping):
            continue
        outer_thread = _metadata_string(metadata.get("threadId"), maximum=200)
        inner_thread = _metadata_string(turn_metadata.get("thread_id"), maximum=200)
        thread_values = [value for value in (outer_thread, inner_thread) if value]
        if not thread_values or len({value.lower() for value in thread_values}) != 1:
            return None
        thread_id = thread_values[0]
        if not _CODEX_THREAD_ID_RE.fullmatch(thread_id):
            return None
        workspace = _workspace_scope_from_metadata(turn_metadata.get("workspaces"))
        if workspace is None:
            return None
        candidates.append(((workspace[0], thread_id), workspace[1]))
    if not candidates:
        return None
    first_scope, first_root = candidates[0]
    if any(
        candidate_scope[0] != first_scope[0]
        or candidate_scope[1].lower() != first_scope[1].lower()
        or candidate_root != first_root
        for candidate_scope, candidate_root in candidates[1:]
    ):
        return None
    return first_scope, first_root


def host_scope_from_request(request: Mapping[str, Any]) -> tuple[str, str] | None:
    """Extract one verified Codex Desktop Host scope from request metadata.

    The raw thread id and workspace path are held only for this request.  They
    are converted to the existing opaque scope keys before runtime code sees
    them and are never emitted, logged, or persisted.
    """

    binding = host_scope_binding_from_request(request)
    return binding[0] if binding is not None else None


TOOLS = [
    {
        "name": "brain_recall",
        "description": "Bounded read-only Super Brain recall.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "top_k": {"type": "integer", "minimum": 1, "maximum": 4, "default": DEFAULT_RECALL_TOP_K},
                "max_tokens": {"type": "integer", "minimum": 32, "maximum": 500, "default": DEFAULT_RECALL_MAX_TOKENS},
                "layer": {
                    "type": "string",
                    "enum": ["all", "profile", "project", "decision", "task", "session"],
                    "default": "all",
                },
                "query_date": {"type": "string", "description": "Optional reference date for relative-time recall."},
                "task_scope": {
                    "type": "object",
                    "description": "Optional verified host scope for exact current-task projection; no fallback is allowed.",
                    "properties": {
                        "workspace_key": {"type": "string", "pattern": "^ws-[a-f0-9]{24}$"},
                        "owner_session_key": {"type": "string", "pattern": "^sid-[a-f0-9]{16,64}$"},
                    },
                    "required": ["workspace_key", "owner_session_key"],
                    "additionalProperties": False,
                },
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "brain_status",
        "description": "Read Super Brain runtime state with explicit verification trust.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "brain_turn",
        "description": "Authoritative hookless Super Brain turn lifecycle. Every same-workline continuation starts from one bounded Host-derived observation of the current thread's newest real assistant reply: use already injected current Host-visible context when available, otherwise one bounded current-thread read. current_visible_assistant is the only normal candidate, and v4 only classifies that same candidate for durable progress or formal stages. H7 then maps it to one same-scope task/workline and current live project proof before selecting an action. Ordinary current commentary is display-only and cannot alter contract progress, stage, proof, or authorization. H7 never backscans an old receipt and never allows a process cache, lease, old contract, summary, checkpoint, memory, or caller-provided capsule to bypass the current locator. H7 validates scope and receipt binding but this MCP field is not a cryptographic Host attestation. If no current observation is available, governed continuation withholds and repairs the evidence path. latest_assistant is detected-drift diagnosis only and requires an explicit H7 reconciliation checkpoint plus a fresh v4 publication; it never mutates the contract automatically. parent_return alone may select the already-approved different workline from its verified state card. Normal observation is transient, not a persistent state card. Pass recovery_event only for a verified recovery and show the returned recoveryPresentation.openingLine exactly; none suppresses it. Close before a terminal reply.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "phase": {"type": "string", "enum": ["open", "checkpoint", "close", "evidence"], "default": "open"},
                "memory_mode": {"type": "string", "enum": ["auto", "force", "off"], "default": "auto"},
                "turn_intent": {"type": "string", "enum": list(TURN_INTENTS), "default": "direct"},
                "recovery_event": {
                    "type": "string",
                    "enum": ["none", "compaction", "restart", "model_switch", "cross_session", "pause_resume", "user_correction", "parent_return"],
                    "default": "none",
                    "description": "Explicit verified recovery event. Non-recovery turns use none and suppress the recovery acknowledgement.",
                },
                "turn_outcome": {
                    "type": "string",
                    "enum": [
                        "unknown",
                        "ephemeral_insertion",
                        "active_work_progressed",
                        "side_branch_completed",
                        "side_branch_partial",
                        "blocked",
                    ],
                    "default": "unknown",
                },
                "user_control": {"type": "string", "enum": ["unknown", "none", "stop", "replace"], "default": "unknown"},
                "completion_evidence_ref": {"type": "string", "maxLength": 240},
                "progress_checkpoint": {
                    "type": "object",
                    "description": "Exact visible assistant-progress anchor, source-qualified and bounded; never user prompt or transcript.",
                    "properties": {
                        "last_confirmed_sentence": {"type": "string", "minLength": 1, "maxLength": 320},
                        "source": {"type": "string", "enum": ["assistant_visible_reply", "user_attested_visible_reply"]},
                        "current_phase": {"type": "string", "minLength": 1, "maxLength": 120},
                        "current_step": {"type": "string", "minLength": 1, "maxLength": 220},
                        "next_action": {"type": "string", "minLength": 1, "maxLength": 360},
                    },
                    "required": ["last_confirmed_sentence", "source", "current_phase", "current_step", "next_action"],
                    "additionalProperties": False,
                },
                "visible_progress_assertion": {
                    "type": "object",
                    "description": "Transient exact current-thread observation produced by runtime/host_visible_tail.py. The time-latest actual agentMessage is always the candidate for normal and recovery turns; user messages cannot choose or truncate it, and a newer plain or legacy reply blocks backward selection. H7 maps this same candidate to the scoped task and live project step before any action. A current plain reply is non-authorizing display-only evidence; v4 only validates the same candidate for durable progress/formal stages. Raw Host ids and source thread payload are never persisted.",
                    "properties": {
                        "schema": {"const": "super-brain.visible-tail-observation.v4"},
                        "observation_source": {"enum": ["codex_app_read_thread", "codex_visible_context"]},
                        "selection": {
                            "enum": ["current_visible_assistant", "latest_durable_assistant", "latest_assistant"],
                            "description": "Use current_visible_assistant for every same-workline normal or recovery boundary; v4 validates only this same candidate, while an unclassified current reply remains display-only. latest_durable_assistant is a compatibility classifier for the same candidate, never a separate selection path. latest_assistant is valid only for H7-detected drift diagnosis; recovery still requires an explicit H7 reconciliation checkpoint and a fresh v4 publication before continuation.",
                        },
                        "host_thread_id": {"type": "string", "minLength": 1, "maxLength": 200},
                        "host_turn_id": {"type": "string", "minLength": 1, "maxLength": 200},
                        "host_message_id": {"type": "string", "minLength": 1, "maxLength": 200},
                        "message_phase": {"type": "string", "enum": ["commentary", "final"]},
                        "last_confirmed_sentence": {"type": "string", "minLength": 1, "maxLength": 320},
                        "source": {"const": "assistant_visible_reply"},
                        "raw_prompt_stored": {"const": False},
                        "raw_transcript_stored": {"const": False},
                        "publication_kind": {"enum": ["h7_durable_progress", "unclassified_assistant_reply", "legacy_h7_progress_withheld"]},
                        "envelope_version": {"enum": ["v4", "none", "legacy_v3"]},
                        "h7_receipt_hash": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                    },
                    "required": [
                        "schema", "observation_source", "host_thread_id", "host_turn_id", "host_message_id",
                        "selection", "message_phase", "last_confirmed_sentence", "source", "publication_kind", "envelope_version", "raw_prompt_stored", "raw_transcript_stored"
                    ],
                    "additionalProperties": False,
                },
                "project_progress_proof": {
                    "type": "object",
                    "description": "Structured project-progress evidence for the same checkpoint; contains no prompt or transcript.",
                    "properties": {
                        "schema": {"const": "super-brain.project-progress-input.v1"},
                        "phase": {"type": "string", "minLength": 1, "maxLength": 120},
                        "currentStep": {"type": "string", "minLength": 1, "maxLength": 220},
                        "completedItems": {
                            "type": "array", "maxItems": 24,
                            "items": {
                                "type": "object",
                                "properties": {
                                    "itemKey": {"type": "string", "minLength": 1, "maxLength": 180},
                                    "evidenceRefs": {"type": "array", "minItems": 1, "maxItems": 8, "items": {"type": "string", "maxLength": 400}},
                                    "verificationIds": {"type": "array", "minItems": 1, "maxItems": 8, "items": {"type": "string", "maxLength": 120}},
                                },
                                "required": ["itemKey", "evidenceRefs", "verificationIds"],
                                "additionalProperties": False,
                            },
                        },
                        "projectEvidence": {
                            "type": "array", "maxItems": 16,
                            "items": {
                                "type": "object",
                                "properties": {
                                    "kind": {"const": "project_file"},
                                    "relativePath": {"type": "string", "minLength": 1, "maxLength": 240},
                                    "sha256": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                                },
                                "required": ["kind", "relativePath", "sha256"],
                                "additionalProperties": False,
                            },
                        },
                        "verificationResults": {
                            "type": "array", "maxItems": 16,
                            "items": {
                                "type": "object",
                                "properties": {
                                    "id": {"type": "string", "pattern": "^[A-Za-z0-9._:-]{1,120}$"},
                                    "status": {"type": "string", "enum": ["passed", "failed", "not_run"]},
                                },
                                "required": ["id", "status"],
                                "additionalProperties": False,
                            },
                        },
                        "nextAction": {"type": "string", "minLength": 1, "maxLength": 360},
                    },
                    "required": ["schema", "phase", "currentStep", "completedItems", "projectEvidence", "verificationResults", "nextAction"],
                    "additionalProperties": False,
                },
                "execution_assist_request": {
                    "type": "object",
                    "description": "Optional compact semantic classification for H7-native four-quadrant assistance. It accepts no user prompt, transcript, query, source path, or authorization.",
                    "properties": {
                        "schema": {"const": "super-brain.execution-assist-request.v1"},
                        "taskClass": {"type": "string", "enum": ["engineering", "product", "productivity", "learning", "general"]},
                        "semanticSignals": {
                            "type": "array",
                            "maxItems": 6,
                            "items": {
                                "type": "string",
                                "enum": [
                                    "bug_diagnosis", "engineering_design", "product_planning",
                                    "productivity_workflow", "learning_teaching", "challenge_assumptions",
                                    "testing", "optimization", "implementation",
                                ],
                            },
                        },
                        "materialUnknown": {"type": "boolean"},
                        "clarificationRequired": {"type": "boolean"},
                        "sharedUnknown": {"type": "boolean"},
                        "rawPromptStored": {"const": False},
                        "rawTranscriptStored": {"const": False},
                    },
                    "required": [
                        "schema", "taskClass", "semanticSignals", "materialUnknown", "clarificationRequired",
                        "sharedUnknown", "rawPromptStored", "rawTranscriptStored",
                    ],
                    "additionalProperties": False,
                },
                "capability_route_receipt": {
                    "type": "object",
                    "description": "Legacy compact router receipt. H7 validates it only as compatibility evidence; H7-native execution assistance remains the sole capability selector.",
                    "properties": {
                        "schema": {"const": "super-brain.capability-route-receipt.v1"},
                        "state": {"type": "string", "enum": ["ready", "not_applicable", "withheld"]},
                        "code": {"type": "string", "pattern": "^CAPABILITY_ROUTE_[A-Z0-9_]{3,96}$"},
                        "selectedNativeCapabilityIds": {
                            "type": "array", "maxItems": 4,
                            "items": {"type": "string", "pattern": "^[A-Za-z][A-Za-z0-9._:-]{1,159}$"},
                        },
                        "nativeContractIds": {
                            "type": "array", "maxItems": 4,
                            "items": {"type": "string", "pattern": "^sb\\.native\\.[a-z0-9][a-z0-9._-]{1,159}$"},
                        },
                        "provenanceHashes": {
                            "type": "array", "maxItems": 4,
                            "items": {
                                "type": "object",
                                "properties": {
                                    "capabilityId": {"type": "string", "pattern": "^[A-Za-z][A-Za-z0-9._:-]{1,159}$"},
                                    "provenanceHash": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                                },
                                "required": ["capabilityId", "provenanceHash"],
                                "additionalProperties": False,
                            },
                        },
                        "parityHashes": {
                            "type": "array", "maxItems": 4,
                            "items": {
                                "type": "object",
                                "properties": {
                                    "capabilityId": {"type": "string", "pattern": "^[A-Za-z][A-Za-z0-9._:-]{1,159}$"},
                                    "contractId": {"type": "string", "pattern": "^sb\\.native\\.[a-z0-9][a-z0-9._-]{1,159}$"},
                                    "parityHash": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                                },
                                "required": ["capabilityId", "contractId", "parityHash"],
                                "additionalProperties": False,
                            },
                        },
                        "routeHash": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                        "shadowGate": {
                            "type": "object",
                            "properties": {
                                "schema": {"const": "super-brain.capability-shadow-gate.v1"},
                                "state": {"type": "string", "enum": ["ready", "withheld", "not_applicable"]},
                                "code": {"type": "string", "pattern": "^H7_CAPABILITY_[A-Z0-9_]{3,96}$"},
                                "evaluationPayloadHash": {"type": "string", "pattern": "^$|^[a-f0-9]{64}$"},
                                "selectedContractCount": {"type": "integer", "minimum": 0, "maximum": 4},
                                "activationAllowed": {"type": "boolean"},
                                "nonAuthorizing": {"const": True},
                                "rawPromptStored": {"const": False},
                                "rawTranscriptStored": {"const": False},
                                "payloadHash": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
                            },
                            "required": [
                                "schema", "state", "code", "evaluationPayloadHash", "selectedContractCount",
                                "activationAllowed", "nonAuthorizing", "rawPromptStored", "rawTranscriptStored", "payloadHash",
                            ],
                            "additionalProperties": False,
                        },
                        "nonAuthorizing": {"const": True},
                        "rawPromptStored": {"const": False},
                        "rawTranscriptStored": {"const": False},
                        "sourcePathsOmitted": {"const": True},
                    },
                    "required": [
                        "schema", "state", "code", "selectedNativeCapabilityIds", "nativeContractIds",
                        "provenanceHashes", "parityHashes", "routeHash", "nonAuthorizing", "rawPromptStored",
                        "rawTranscriptStored", "sourcePathsOmitted", "shadowGate",
                    ],
                    "additionalProperties": False,
                },
                "transition_id": {"type": "string", "maxLength": 120},
            },
            "additionalProperties": False,
        },
    },
    {
        "name": "brain_recent",
        "description": "Read a compact recent-memory tail.",
        "inputSchema": {
            "type": "object",
            "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 20, "default": 5}},
            "additionalProperties": False,
        },
    },
]


def control_plane_status(snapshot_path: Path | None) -> dict[str, Any]:
    if snapshot_path is None:
        return {"available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_UNCONFIGURED"}
    snapshot = read_mcp_snapshot(snapshot_path)
    if not snapshot.get("ok") or not snapshot.get("available"):
        return {"available": False, "code": str(snapshot.get("code", "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"))}
    return {
        "available": True,
        "schema": snapshot["schema"],
        "payloadHash": snapshot["payloadHash"],
        "generatedAt": snapshot["generatedAt"],
        "status": snapshot["status"],
        "taskProjectionRefs": snapshot["taskProjectionRefs"],
        "taskProjectionOverflow": snapshot.get("taskProjectionOverflow", False),
    }


def _task_scope(arguments: dict[str, Any]) -> tuple[str, str] | None:
    value = arguments.get("task_scope")
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("task_scope must be an object")
    workspace_key = str(value.get("workspace_key", "")).strip().lower()
    owner_session_key = str(value.get("owner_session_key", "")).strip().lower()
    if not re.fullmatch(r"ws-[a-f0-9]{24}", workspace_key) or not re.fullmatch(
        r"sid-[a-f0-9]{16,64}", owner_session_key
    ):
        raise ValueError("task_scope is invalid")
    return workspace_key, owner_session_key


def _ensure_scoped_activation(core: BrainCore) -> None:
    """Self-heal activation only when MCP has a verified Host scope."""

    workspace_key = core._context_workspace_key()
    session_key = core._context_session_key()
    if not workspace_key or not session_key:
        return
    contract, _ = core._read_context_contract(workspace_key, session_key)
    if not isinstance(contract, dict):
        return
    memory_root = core.memory_root if core.memory_root.exists() else core.memory_base
    anchor = contract.get("instructionAnchor") if isinstance(contract.get("instructionAnchor"), dict) else {}
    continuation = contract.get("continuationReceipt") if isinstance(contract.get("continuationReceipt"), dict) else {}
    recovery = contract.get("recoveryCheckpoint") or contract.get("checkpoint")
    recovery = recovery if isinstance(recovery, dict) else {}
    ensure_current(
        core.package_root,
        core.memory_base,
        memory_root=memory_root,
        workspace_key=workspace_key,
        session_key=session_key,
        task_id=str(contract.get("taskId", "")),
        task_instance_id=str(contract.get("taskInstanceId", "")),
        route="current_task_status",
        action_authorization="withheld",
        contract=contract,
        instruction_anchor_hash=str(anchor.get("contentHash", "")),
        continuation_receipt_hash=str(
            continuation.get("receiptHash")
            or continuation.get("payloadHash")
            or continuation.get("stateHash")
            or ""
        ),
        recovery_checkpoint_id=str(recovery.get("checkpointId") or recovery.get("id") or ""),
        recovery_state_hash=str(recovery.get("stateHash") or recovery.get("hash") or ""),
        return_point=contract.get("returnPoint") if isinstance(contract.get("returnPoint"), dict) else None,
        require_scope=True,
    )


def _task_projection_result(
    projection_result: dict[str, Any],
    *,
    query: str,
    max_tokens: int,
) -> list[dict[str, Any]]:
    if not projection_result.get("available"):
        return []
    projection = projection_result["projection"]
    parts = []
    for label, field in (
        ("phase", "currentPhase"),
        ("step", "currentStep"),
        ("next", "nextAction"),
        ("last", "lastConfirmedSentence"),
    ):
        value = str(projection.get(field, "")).strip()
        if value:
            parts.append(f"{label}={value}")
    claim = "[TASK][CURRENT][VERIFIED] " + " ".join(parts)
    claim = claim[: max(128, max(32, int(max_tokens)) * 4)]
    projection_view = {
        key: projection.get(key)
        for key in (
            "revision",
            "stateHash",
            "packageVersion",
            "lifecycle",
            "contractRevision",
            "planFingerprint",
            "lastConfirmedSentence",
            "lastConfirmedSource",
            "currentPhase",
            "currentStep",
            "nextAction",
            "completedSteps",
            "pendingSteps",
            "blockers",
            "evidenceRefs",
            "verificationResults",
            "updatedAt",
            "actionAuthorization",
            "rawPromptStored",
            "rawTranscriptStored",
        )
    }
    source = f"mcp-snapshot:{projection_result['snapshotHash']}"
    card = {
        "source": source,
        "sourceType": "task_projection",
        "claim": claim,
        "whyRelevant": "exact_host_scope_current_task",
        "confidence": 1.0,
        "lastVerified": "verified",
        "layer": "task",
        "tags": ["TASK", "CURRENT", "VERIFIED"],
        "ageDays": 0.0,
        "recallPriority": "task_projection",
        "snippet": claim,
        "tokenEstimate": max(1, (len(claim) + 3) // 4),
        "injectReady": True,
        "recallDisposition": "inject",
        "relevanceStatus": "authoritative_state_withheld_action",
        "matchedTerms": [],
        "canonicalMatch": True,
        "anchorTerms": [],
        "provenanceScope": "scoped",
        "snapshotHash": projection_result["snapshotHash"],
        "scopeRef": projection["scopeRef"],
        "taskStateHash": projection["stateHash"],
        "actionAuthorization": "withheld",
    }
    return [
        {
            "text": claim,
            "evidenceCard": card,
            "source": source,
            "sourceType": "task_projection",
            "layer": "task",
            "tags": card["tags"],
            "score": 1.0,
            "confidence": 1.0,
            "reason": "exact_host_scope_current_task",
            "ageDays": 0.0,
            "recallPriority": "task_projection",
            "tokenEstimate": card["tokenEstimate"],
            "relevanceOk": True,
            "injectReady": True,
            "recallDisposition": "inject",
            "matchedTerms": [],
            "anchorTerms": [],
            "temporalMatch": False,
            "temporalDistanceDays": None,
            "requiredMatchCount": 0,
            "matchedTermCount": 0,
            "exactMatch": True,
            "canonicalMatch": True,
            "identityKey": projection["scopeRef"],
            "relationPriority": 0,
            "selfModelStatus": "",
            "verificationStatus": "verified",
            "sourcePriority": 0,
            "taskProjection": projection_view,
        }
    ]


def handle_tool(core: BrainCore, name: str, arguments: dict[str, Any], snapshot_path: Path | None = None) -> dict[str, Any]:
    if name != "brain_status":
        runtime_identity = core.runtime_identity_status()
        if runtime_identity.get("state") != "current":
            return tool_result(
                {
                    "schema": "super-brain.mcp-runtime-identity.v1",
                    "available": False,
                    "code": str(runtime_identity.get("code", "H7_MCP_RUNTIME_IDENTITY_STALE")),
                    "runtimeIdentity": runtime_identity,
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                },
                True,
            )
    if name == "brain_turn":
        if "continuation_capsule" in arguments:
            return tool_result(
                {
                    "schema": "super-brain.continuation-control.v1",
                    "available": False,
                    "code": "H7_EXTERNAL_CONTINUATION_STATE_FORBIDDEN",
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                },
                True,
            )
        return tool_result(
            run_turn(
                core,
                phase=str(arguments.get("phase", "open")),
                memory_mode=str(arguments.get("memory_mode", "auto")),
                recovery_event=str(arguments.get("recovery_event", "none")),
                turn_outcome=str(arguments.get("turn_outcome", "unknown")),
                user_control=str(arguments.get("user_control", "unknown")),
                completion_evidence_ref=str(arguments.get("completion_evidence_ref", "")),
                progress_checkpoint=arguments.get("progress_checkpoint") if isinstance(arguments.get("progress_checkpoint"), dict) else None,
                visible_progress_assertion=arguments.get("visible_progress_assertion") if isinstance(arguments.get("visible_progress_assertion"), dict) else None,
                project_progress_proof=arguments.get("project_progress_proof") if isinstance(arguments.get("project_progress_proof"), dict) else None,
                execution_assist_request=arguments.get("execution_assist_request"),
                capability_route_receipt=arguments.get("capability_route_receipt"),
                transition_id=str(arguments.get("transition_id", "")),
                turn_intent=str(arguments.get("turn_intent", "direct")),
            )
        )
    if name == "brain_recall":
        _ensure_scoped_activation(core)
        scope = _task_scope(arguments)
        if scope is not None:
            if snapshot_path is None:
                return tool_result([])
            projection_result = read_mcp_task_projection(
                snapshot_path,
                workspace_key=scope[0],
                owner_session_key=scope[1],
            )
            return tool_result(
                _task_projection_result(
                    projection_result,
                    query=str(arguments.get("query", "")),
                    max_tokens=int(arguments.get("max_tokens", 120)),
                )
            )
        if str(arguments.get("layer", "all")) in {"task", "session"}:
            # Long-lived MCP workers do not reliably inherit the caller's
            # thread identity.  Never turn a worker-local cwd or stale env into
            # cross-session task/session context.
            return tool_result([])
        return tool_result(
            core.recall(
                str(arguments.get("query", "")),
                int(arguments.get("top_k", DEFAULT_RECALL_TOP_K)),
                int(arguments.get("max_tokens", DEFAULT_RECALL_MAX_TOKENS)),
                str(arguments.get("layer", "all")),
                str(arguments.get("query_date", "")),
            )
        )
    if name == "brain_status":
        status = core.status()
        status["controlPlaneSnapshot"] = control_plane_status(snapshot_path)
        return tool_result(status)
    if name == "brain_recent":
        return tool_result(core.recent(int(arguments.get("limit", 5))))
    return tool_result({"error": f"unknown tool: {name}"}, True)


def serve(core: BrainCore, snapshot_path: Path | None = None) -> int:
    for raw in sys.stdin:
        raw = raw.lstrip("\ufeff").strip()
        if not raw:
            continue
        try:
            request = json.loads(raw)
        except json.JSONDecodeError:
            print(json.dumps(error(None, -32700, "parse error"), separators=(",", ":")), flush=True)
            continue
        if "id" not in request:
            continue
        request_id = request.get("id")
        method = request.get("method", "")
        try:
            if method == "initialize":
                result = {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "super-memory-brain", "version": str(core.status().get("version", "0"))},
                    "instructions": "For every same-workline governed turn, including compaction/restart/pause-resume/model-switch/cross-session/correction, first observe the newest visible assistant reply: use codex_visible_context when already exposed, otherwise one bounded current-thread observation. Always use current_visible_assistant; a v4 prefix classifies that same candidate but never selects an older reply. H7 maps it to one scoped task/workline and live project phase/step before action. An ordinary current reply is display-only and cannot alter contract progress, stage, proof, or authorization. latest_assistant is drift diagnosis only and requires an explicit H7 reconciliation checkpoint plus a fresh v4 publication. Normal observation is transient H7 receipt binding, not a persistent readback card; only a verified parent return selects the already-approved alternate workline from its state card. Before each material assistant progress/status update, call phase=checkpoint with the exact source-qualified visible assistant progress checkpoint and matching project proof. Call phase=close before a terminal reply; if close says mustContinue, continue or ResumeParent. Never persist raw prompts or transcripts.",
                }
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = request.get("params", {}) or {}
                host_binding = host_scope_binding_from_request(request)
                scope = host_binding[0] if host_binding is not None else None
                workspace_root = host_binding[1] if host_binding is not None else None
                with core.bind_host_scope(scope, workspace_root=workspace_root):
                    result = handle_tool(core, str(params.get("name", "")), params.get("arguments", {}) or {}, snapshot_path)
            elif method == "ping":
                result = {}
            else:
                print(json.dumps(error(request_id, -32601, f"unknown method: {method}"), separators=(",", ":")), flush=True)
                continue
            print(json.dumps(response(request_id, result), ensure_ascii=False, separators=(",", ":")), flush=True)
        except Exception as exc:
            print(json.dumps(error(request_id, -32000, str(exc)), ensure_ascii=False, separators=(",", ":")), flush=True)
    return 0


def main() -> int:
    if hasattr(sys.stdin, "reconfigure"):
        sys.stdin.reconfigure(encoding="utf-8", errors="strict")
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="strict")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--memory-root", default="")
    args = parser.parse_args()
    memory_root = Path(args.memory_root).expanduser().resolve() if args.memory_root else None
    core = BrainCore(args.package_root, str(memory_root) if memory_root is not None else None)
    snapshot_path = core.workspace / "mcp-snapshot.json" if memory_root is not None else None
    return serve(core, snapshot_path)


if __name__ == "__main__":
    raise SystemExit(main())
