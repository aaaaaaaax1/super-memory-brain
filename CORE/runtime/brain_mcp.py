from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from brain_control import read_mcp_snapshot, read_mcp_task_projection
from brain_core import (
    DEFAULT_RECALL_MAX_TOKENS,
    DEFAULT_RECALL_TOP_K,
    MCP_RUNTIME_MODE_OFFLINE_REPLAY,
    BrainCore,
)
from activation_receipt import ensure_current
from turn_runtime import run_turn
from turn_intent import TURN_INTENTS
from mcp_transport_health import LocalBrokerStdioTransportHealth, OfflineReplayMcpTransportHealth
from scope_provider import BrokerChannelHandle, BrokerScopeProvider, OfflineReplayScopeProvider
from scope_broker_ipc import ScopeBrokerClient


def response(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def tool_result(payload: Any, is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False, separators=(",", ":"))}],
        "isError": is_error,
    }


def _retired_host_transport_payload(arguments: Mapping[str, Any]) -> dict[str, Any] | None:
    """Reject retired Host inputs before any bridge, bind, retry, or read occurs."""

    supplied = sorted(key for key in _RETIRED_HOST_ARGUMENTS if key in arguments)
    if not supplied:
        return None
    return {
        "schema": "super-brain.host-transport-retirement.v1",
        "available": False,
        "code": "H7_HOST_TRANSPORT_RETIRED",
        "retiredInputs": supplied,
        "next": "Remove Host payloads and use the current local cwd/session scope with H7 contract and project proof.",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


_LOCAL_MCP_RUNTIME_ENV = "SUPER_BRAIN_LOCAL_MCP_RUNTIME"
_LOCAL_SESSION_ENV = "SUPER_BRAIN_LOCAL_SESSION_ID"
_MCP_CLI_BRIDGE_SCHEMA = "super-brain.mcp-cli-bridge-request.v1"
_MCP_CLI_BRIDGE_MAX_STDIN_BYTES = 512 * 1024
_MCP_CLI_BRIDGE_MAX_STDOUT_BYTES = 512 * 1024
_MCP_CLI_BRIDGE_TIMEOUT_SECONDS = 16
_RETIRED_HOST_ARGUMENTS = frozenset(
    {
        "host_readback_projection",
        "host_visible_context",
        "host_thread_payload",
        "visible_progress_assertion",
    }
)
_MCP_CLI_CHILD_ENV_KEYS = (
    "APPDATA",
    "COMSPEC",
    "ComSpec",
    "HOME",
    "LANG",
    "LC_ALL",
    "LOCALAPPDATA",
    "OS",
    "PATH",
    "PATHEXT",
    "PROCESSOR_ARCHITECTURE",
    "PROGRAMDATA",
    "SystemRoot",
    "SYSTEMROOT",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "WINDIR",
)


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
        "description": "Authoritative local-only turn lifecycle. Every governed continuation starts from the current cwd/session scope, the current H7 execution contract, current project proof, and current visible progress receipt. No Host transport, metadata, thread payload, readback, summary, cache, or external continuation capsule is read, retried, or persisted. H7 maps the local scope to one task/workline and live project proof before selecting an action. Ordinary commentary is display-only and cannot alter contract progress, stage, proof, or authorization. If the local contract or proof is unavailable, continuation withholds and repairs the local evidence path. Close before a terminal reply.",
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
                "latest_user_instruction": {
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 480,
                    "description": "One compact current-user instruction for a pending H7 reconciliation. It is redacted and bound as a task instruction anchor; raw prompts and transcripts are never retained.",
                },
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


def _task_scope(arguments: dict[str, Any], core: BrainCore) -> tuple[str, str] | None:
    value = arguments.get("task_scope")
    if value is None:
        return None
    # A production Broker channel cannot be redirected by a request selector.
    # Keep the old assertion-only form for direct legacy CLI/test adapters so
    # existing callers receive the historical scoped projection without
    # weakening the new MCP path.
    if getattr(getattr(core, "_scope_provider", None), "provider_kind", "") == "scope_broker_channel":
        raise ValueError("H7_SCOPE_SELECTOR_FORBIDDEN")
    if not isinstance(value, dict):
        raise ValueError("task_scope must be an object")
    workspace_key = str(value.get("workspace_key", "")).strip().lower()
    owner_session_key = str(value.get("owner_session_key", "")).strip().lower()
    if not re.fullmatch(r"ws-[a-f0-9]{24}", workspace_key) or not re.fullmatch(
        r"sid-[a-f0-9]{16,64}", owner_session_key
    ):
        raise ValueError("task_scope is invalid")
    current_workspace = str(core._context_workspace_key()).strip().lower()
    current_session = str(core._context_session_key()).strip().lower()
    if not current_workspace or not current_session:
        raise ValueError("H7_TASK_SCOPE_LOCAL_SCOPE_REQUIRED")
    if workspace_key != current_workspace or owner_session_key != current_session:
        raise ValueError("H7_TASK_SCOPE_FOREIGN_SCOPE")
    return workspace_key, owner_session_key


def _ensure_scoped_activation(core: BrainCore) -> None:
    """Self-heal activation only for the current local scope."""

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


def _live_mcp_handshake(
    core: BrainCore,
    *,
    runtime_identity: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return this process's injected local MCP transport health.

    Deployment registration is intentionally not consulted here.  A generic
    stdio process is healthy when its own runtime identity and private Broker
    channel are healthy; host adapters publish their separate diagnostics via
    ``mcpRuntimeBinding.deploymentAdapter``.
    """

    runtime = runtime_identity if isinstance(runtime_identity, dict) else core.runtime_identity_status()
    return dict(core.mcp_transport_status(runtime))


def _public_mcp_status(status: Mapping[str, Any]) -> dict[str, Any]:
    """Remove local filesystem locators from the public stdio status view.

    The core/CLI diagnostic object may legitimately name local paths.  A
    portable MCP capability needs only state, hashes, and scope projections;
    returning machine paths adds no authorization value and weakens the
    transport's privacy boundary.
    """

    result = dict(status)
    for key in ("packageRoot", "memoryRoot", "memoryBase"):
        result.pop(key, None)
    result["localPathsExposed"] = False
    return result


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
        "whyRelevant": "exact_local_scope_current_task",
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
            "reason": "exact_local_scope_current_task",
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


def _mcp_transport_problem(core: BrainCore) -> tuple[dict[str, Any], dict[str, Any] | None]:
    """Return only a code-identity problem that can make this worker unsafe.

    MCP registration epochs and live handshakes remain visible through
    ``brain_status``. They are deployment diagnostics, not a per-request local
    gate.  Keeping them off the hot path prevents a missing/stale binding from
    spawning a fresh Python process for every otherwise-valid request.
    """

    runtime_identity = core.runtime_identity_status()
    return runtime_identity, None


def _mcp_cli_child_environment(*, local_session_key: str = "") -> dict[str, str]:
    """Build a minimal child environment that cannot inherit stale MCP state."""

    environment = {
        key: value
        for key in _MCP_CLI_CHILD_ENV_KEYS
        if isinstance((value := os.environ.get(key)), str) and value
    }
    if re.fullmatch(r"sid-[0-9a-f]{16,64}", local_session_key, re.IGNORECASE):
        # Only the already-normalized local session key crosses the process
        # boundary; no ambient legacy or Host identity is copied.
        environment[_LOCAL_SESSION_ENV] = local_session_key.lower()
    environment["PYTHONUTF8"] = "1"
    environment["PYTHONIOENCODING"] = "utf-8"
    return environment


def _mcp_cli_bridge_workspace_root(core: BrainCore) -> Path | None:
    """Return the resident process's current local project root only."""

    try:
        candidate = core._context_project_root()
    except (OSError, ValueError):
        return None
    return candidate if isinstance(candidate, Path) and candidate.is_dir() else None


def _mcp_cli_bridge_is_safe(name: str, arguments: Mapping[str, Any]) -> bool:
    """Allow only equivalent H7 operations whose scope cannot be invented."""

    if name in {"brain_turn", "brain_recent"}:
        return True
    if name != "brain_recall":
        return False
    # Task/session recall is an MCP snapshot projection bound to the current
    # local scope. A fresh CLI can safely perform only ordinary bounded memory
    # recall; it must not substitute its own view for that projection.
    if "task_scope" in arguments:
        return False
    return str(arguments.get("layer", "all")) not in {"task", "session"}


def _mcp_cli_bridge_failure(code: str) -> dict[str, Any]:
    return {
        "schema": "super-brain.mcp-cli-bridge.v1",
        "available": False,
        "code": "H7_RUNTIME_UNAVAILABLE",
        "failureCode": code,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _run_current_cli_bridge(
    core: BrainCore,
    name: str,
    arguments: Mapping[str, Any],
) -> dict[str, Any]:
    """Use a fresh package-owned CLI process when the resident MCP is stale.

    The old worker stays honestly stale: it transfers only a bounded local
    request to the package currently on disk. Host transport is not bridged.
    """

    retired_host = _retired_host_transport_payload(arguments)
    if retired_host is not None:
        return tool_result(retired_host, True)
    if not _mcp_cli_bridge_is_safe(name, arguments):
        return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_OPERATION_UNSAFE"), True)
    bridge_workspace_root: Path | None = None
    local_session_key = ""
    if name in {"brain_turn", "brain_recent"}:
        # Pass only the already-normalized local session to a fresh CLI.  An
        # absent session is intentionally propagated as empty so brain_recent
        # fails closed instead of reading another conversation's tail.
        local_session_key = core._context_session_key()
    if name in {"brain_turn", "brain_recent"}:
        bridge_workspace_root = _mcp_cli_bridge_workspace_root(core)
        # ``brain_recent`` is workspace-scoped as well as session-scoped.
        # The child CLI otherwise starts in ``core.package_root`` and derives
        # a different workspace key, causing a stale MCP worker to return an
        # empty (or unrelated) recent tail after a package refresh.
        if bridge_workspace_root is None:
            return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_LOCAL_SCOPE_REQUIRED"), True)
    if name == "brain_turn":
        if not local_session_key:
            return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_LOCAL_SESSION_REQUIRED"), True)
    cli_path = core.package_root / "runtime" / "brain_cli.py"
    if not cli_path.is_file():
        return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_ENTRYPOINT_MISSING"), True)
    bridge_arguments = dict(arguments)
    try:
        body = json.dumps(
            {"schema": _MCP_CLI_BRIDGE_SCHEMA, "name": name, "arguments": bridge_arguments},
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError):
        return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_INPUT_INVALID"), True)
    if not body or len(body) > _MCP_CLI_BRIDGE_MAX_STDIN_BYTES:
        return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_INPUT_INVALID"), True)

    command = [
        sys.executable,
        "-X",
        "utf8",
        str(cli_path),
        "--package-root",
        str(core.package_root),
        "--memory-root",
        str(core.memory_root),
    ]
    if name in {"brain_turn", "brain_recent"}:
        assert bridge_workspace_root is not None
        command.extend(("--workspace-root", str(bridge_workspace_root)))
    command.append("mcp-bridge")
    try:
        completed = subprocess.run(
            command,
            cwd=str(core.package_root),
            env=_mcp_cli_child_environment(local_session_key=local_session_key),
            input=body,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=_MCP_CLI_BRIDGE_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_EXECUTION_FAILED"), True)
    if completed.returncode != 0 or len(completed.stdout) > _MCP_CLI_BRIDGE_MAX_STDOUT_BYTES:
        return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_EXECUTION_FAILED"), True)
    try:
        result = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_OUTPUT_INVALID"), True)
    if not isinstance(result, (dict, list)):
        return tool_result(_mcp_cli_bridge_failure("H7_MCP_CLI_BRIDGE_OUTPUT_INVALID"), True)
    # Success intentionally returns the ordinary tool shape.  It does not say
    # the stale MCP is current; ``brain_status`` remains the source of truth
    # for that explicit transport-health question.
    return tool_result(result)


def handle_tool(
    core: BrainCore,
    name: str,
    arguments: dict[str, Any],
    snapshot_path: Path | None = None,
) -> dict[str, Any]:
    retired_host = _retired_host_transport_payload(arguments)
    if retired_host is not None:
        return tool_result(retired_host, True)
    # The offline replay exists solely to test stdio framing and response
    # schemas.  A governed lifecycle call must be visibly withheld before it
    # reaches activation, a CLI bridge, or any scope-derived state path.
    if core.runtime_mode == MCP_RUNTIME_MODE_OFFLINE_REPLAY and name == "brain_turn":
        return tool_result(
            run_turn(core, phase=str(arguments.get("phase", "open"))),
            True,
        )
    broker_bound_adapter = getattr(getattr(core, "_scope_provider", None), "provider_kind", "") == "scope_broker_channel"
    if broker_bound_adapter and "task_scope" in arguments:
        # A production channel is already bound to one broker-owned scope;
        # accepting a second selector would make the API appear to support a
        # redirect path even though the selector is intentionally not part of
        # the MCP schema.
        return tool_result(
            {
                "ok": False,
                "schema": "super-brain.scope-binding.v1",
                "available": False,
                "code": "H7_SCOPE_SELECTOR_FORBIDDEN",
                "state": "withheld",
                "scopeBinding": core.scope_status(),
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            },
            True,
        )
    # A broker-backed MCP must never downgrade to a cwd/env CLI bridge when
    # its package identity is stale.  The bridge would create a second scope
    # authority and could silently lose the channel binding.
    if broker_bound_adapter and name != "brain_status":
        runtime_identity = core.runtime_identity_status()
        if runtime_identity.get("state") != "current":
            return tool_result(
                {
                    "ok": False,
                    "schema": "super-brain.mcp-runtime-identity.v1",
                    "available": False,
                    "code": str(runtime_identity.get("code", "H7_MCP_RUNTIME_IDENTITY_STALE")),
                    "scopeBinding": core.scope_status(),
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                },
                True,
            )
    if name == "brain_turn" and "continuation_capsule" in arguments:
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
    if name != "brain_status":
        runtime_identity, binding_problem = _mcp_transport_problem(core)
        if runtime_identity.get("state") != "current" or binding_problem is not None:
            return _run_current_cli_bridge(
                core,
                name,
                arguments,
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
        scope = core.authorize_scope(write=False)
        if broker_bound_adapter and scope.get("ok") is not True:
            return tool_result(
                {
                    "ok": False,
                    "schema": "super-brain.scope-binding.v1",
                    "available": False,
                    "code": str(scope.get("code", "H7_SCOPE_CHANNEL_UNBOUND")),
                    "state": str(scope.get("state", "unbound")),
                    "scopeBinding": core.scope_status(),
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
                visible_progress_assertion=None,
                project_progress_proof=arguments.get("project_progress_proof") if isinstance(arguments.get("project_progress_proof"), dict) else None,
                execution_assist_request=arguments.get("execution_assist_request"),
                capability_route_receipt=arguments.get("capability_route_receipt"),
                latest_user_instruction=(
                    arguments.get("latest_user_instruction")
                    if isinstance(arguments.get("latest_user_instruction"), str)
                    else None
                ),
                transition_id=str(arguments.get("transition_id", "")),
                turn_intent=str(arguments.get("turn_intent", "direct")),
                require_visible_tail_assertion=False,
            )
        )
    if name == "brain_recall":
        _ensure_scoped_activation(core)
        try:
            scope = _task_scope(arguments, core)
        except ValueError as exc:
            code = str(exc) or "H7_TASK_SCOPE_INVALID"
            if code == "task_scope is invalid":
                code = "H7_TASK_SCOPE_INVALID"
            return tool_result(
                {
                    "schema": "super-brain.mcp-task-projection.v1",
                    "available": False,
                    "code": code,
                    "projection": [],
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                },
                True,
            )
        layer = str(arguments.get("layer", "all"))
        if scope is None and layer in {"task", "session"}:
            if broker_bound_adapter:
                # Derive the projection from this channel's current broker
                # authorization.  Never use cwd, ambient session variables, or
                # a request selector to choose the task/session.
                authorized = core.authorize_scope(write=False)
                if authorized.get("ok") is not True:
                    return tool_result(
                        {
                            "ok": False,
                            "schema": "super-brain.scope-binding.v1",
                            "available": False,
                            "code": str(authorized.get("code", "H7_SCOPE_CHANNEL_UNBOUND")),
                            "state": str(authorized.get("state", "unbound")),
                            "scopeBinding": core.scope_status(),
                            "rawPromptStored": False,
                            "rawTranscriptStored": False,
                        },
                        True,
                    )
                bound = authorized.get("scope") if isinstance(authorized.get("scope"), Mapping) else authorized
                workspace_key = str((bound or {}).get("workspaceKey", "")).strip().lower()
                owner_session_key = str((bound or {}).get("ownerSessionKey", "")).strip().lower()
                if not workspace_key or not owner_session_key:
                    return tool_result(
                        {
                            "ok": False,
                            "schema": "super-brain.scope-binding.v1",
                            "available": False,
                            "code": "H7_SCOPE_BROKER_CONTEXT_MISSING",
                            "state": "withheld",
                            "scopeBinding": core.scope_status(),
                            "rawPromptStored": False,
                            "rawTranscriptStored": False,
                        },
                        True,
                    )
                scope = (workspace_key, owner_session_key)
            else:
                # Long-lived legacy workers do not reliably inherit the
                # caller's task/session identity.  Keep the compatibility
                # behavior bounded to an empty result.
                return tool_result([])
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
        status = _public_mcp_status(core.status())
        status["scopeBinding"] = core.scope_status()
        status["controlPlaneSnapshot"] = control_plane_status(snapshot_path)
        status["liveMcpHandshake"] = _live_mcp_handshake(
            core,
            runtime_identity=(status.get("runtimeIdentity") if isinstance(status.get("runtimeIdentity"), dict) else None),
        )
        return tool_result(status)
    if name == "brain_recent":
        scope = core.authorize_scope(write=False)
        if broker_bound_adapter and scope.get("ok") is not True:
            return tool_result(
                {
                    "ok": False,
                    "schema": "super-brain.scope-binding.v1",
                    "available": False,
                    "code": str(scope.get("code", "H7_SCOPE_CHANNEL_UNBOUND")),
                    "state": str(scope.get("state", "unbound")),
                    "scopeBinding": core.scope_status(),
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                },
                True,
            )
        return tool_result(
            core.recent(
                int(arguments.get("limit", 5)),
                session_key=core._context_session_key(),
            )
        )
    return tool_result({"error": f"unknown tool: {name}"}, True)


def serve(core: BrainCore, snapshot_path: Path | None = None) -> int:
    initialized = False
    for raw in sys.stdin:
        raw = raw.lstrip("\ufeff").strip()
        if not raw:
            continue
        try:
            request = json.loads(raw)
        except json.JSONDecodeError:
            print(json.dumps(error(None, -32700, "parse error"), separators=(",", ":")), flush=True)
            continue
        if not isinstance(request, dict):
            # JSON-RPC requests are objects.  A scalar/array must not escape
            # the protocol loop as a Python TypeError and take down the MCP
            # worker; return one bounded invalid-request envelope instead.
            print(json.dumps(error(None, -32600, "invalid request"), separators=(",", ":")), flush=True)
            continue
        if "id" not in request:
            continue
        request_id = request.get("id")
        method = request.get("method", "")
        try:
            if not initialized and method not in {"initialize", "ping"}:
                print(
                    json.dumps(
                        error(request_id, -32002, "H7_MCP_INITIALIZE_REQUIRED"),
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ),
                    flush=True,
                )
                continue
            if method == "initialize":
                live_handshake = core.record_mcp_live_handshake()
                initialized = True
                result = {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    # Initialization must stay cheap.  Version is package data;
                    # calling status() here performed a full identity, binding,
                    # hook and active-task scan before the first tool request.
                    "serverInfo": {"name": "super-memory-brain", "version": str(core.manifest.get("version", "0"))},
                    "liveMcpHandshake": live_handshake,
                    "instructions": "Use the local H7 runtime only. Host binding, visible context, thread payloads, metadata, and readback are permanently retired and are never read, retried, or persisted. Bind the current local cwd/session scope, use the scoped H7 contract and project proof, call phase=checkpoint before material progress changes, and call phase=close before a terminal reply. Never persist raw prompts or transcripts.",
                }
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = request.get("params", {}) or {}
                result = handle_tool(
                    core,
                    str(params.get("name", "")),
                    params.get("arguments", {}) or {},
                    snapshot_path,
                )
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
    # Offline replay is an explicit test harness mode.  Do not let a stale or
    # inherited environment variable silently turn a real local MCP server
    # into a non-live transport.
    parser.add_argument("--offline-replay", action="store_true")
    args = parser.parse_args()
    memory_root = Path(args.memory_root).expanduser().resolve() if args.memory_root else None
    # Every live MCP stdio process owns one private broker channel.  The only
    # exception is the package's explicit offline protocol replay, which is a
    # test-only compatibility transport and never represents a live adapter.
    broker_client = None
    transport_health = None
    previous_local_runtime_marker = os.environ.get(_LOCAL_MCP_RUNTIME_ENV)
    channel_handle = None
    # Construct the core once.  The transport/provider are dependency
    # injection seams, so rebinding this instance avoids a second manifest,
    # rule-registry, and runtime-identity scan during every MCP startup.
    core = BrainCore(args.package_root, str(memory_root) if memory_root is not None else None)
    if args.offline_replay:
        transport_health = OfflineReplayMcpTransportHealth()
        core.inject_runtime_transport(
            runtime_mode="offline_mcp_replay",
            scope_provider=OfflineReplayScopeProvider(),
            transport_health=transport_health,
        )
    else:
        # This process-local marker enables the bounded warm authority worker
        # without making performance depend on a host's registration format.
        os.environ[_LOCAL_MCP_RUNTIME_ENV] = "1"
        broker_client = ScopeBrokerClient(
            core.memory_base,
            runtime_path=Path(__file__).with_name("scope_broker_ipc.py"),
        )
        channel_handle = BrokerChannelHandle(broker_client, broker_client.open_channel())
        transport_health = LocalBrokerStdioTransportHealth(broker_client, channel_handle)
        core.inject_runtime_transport(
            runtime_mode="local_stdio_scope_broker",
            scope_provider=BrokerScopeProvider(broker_client, channel_handle),
            transport_health=transport_health,
        )
    snapshot_path = core.workspace / "mcp-snapshot.json" if memory_root is not None else None
    try:
        return serve(core, snapshot_path)
    finally:
        if previous_local_runtime_marker is None:
            os.environ.pop(_LOCAL_MCP_RUNTIME_ENV, None)
        else:
            os.environ[_LOCAL_MCP_RUNTIME_ENV] = previous_local_runtime_marker
        if transport_health is not None:
            try:
                transport_health.close()
            except Exception:
                pass
        if channel_handle is not None:
            channel_handle.close_channel()
        if broker_client is not None:
            # ``ScopeBrokerClient`` only terminates a child it started itself;
            # shared resident brokers stay alive for other MCP connections.
            # This eagerly releases auto-started state instead of waiting for
            # the idle reaper and avoids pinning temporary package state.
            try:
                broker_client.close()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
