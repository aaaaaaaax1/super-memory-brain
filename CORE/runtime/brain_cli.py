from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import sys
from collections.abc import Mapping
from pathlib import Path

from brain_control import BrainControl, BrainControlError
from brain_core import DEFAULT_RECALL_MAX_TOKENS, DEFAULT_RECALL_TOP_K, BrainCore
from activation_receipt import activate as activate_brain, ensure_current
from turn_close_dispatcher import dispatch_turn_close
from turn_runtime import run_turn
from turn_intent import TURN_INTENTS, public_projection as public_turn_intent, resolve_turn_intent
from scope_broker_ipc import ScopeBrokerControlClient


_MCP_CLI_BRIDGE_SCHEMA = "super-brain.mcp-cli-bridge-request.v1"
_MCP_CLI_BRIDGE_MAX_STDIN_BYTES = 96 * 1024
_MCP_CLI_BRIDGE_TURN_ARGUMENTS = frozenset(
    {
        "phase",
        "memory_mode",
        "recovery_event",
        "turn_outcome",
        "user_control",
        "completion_evidence_ref",
        "latest_user_instruction",
        "progress_checkpoint",
        "project_progress_proof",
        "execution_assist_request",
        "capability_route_receipt",
        "transition_id",
        "turn_intent",
    }
)
_RETIRED_HOST_BRIDGE_FIELDS = frozenset(
    {"visible_progress_assertion", "host_visible_context", "host_thread_payload", "host_readback_projection"}
)
_RETIRED_HOST_OPTION_FIELDS = {
    "visible_progress_assertion_json": "visible_progress_assertion",
    "visible_progress_assertion_base64": "visible_progress_assertion",
    "host_thread_json": "host_thread_payload",
    "host_thread_base64": "host_thread_payload",
    "host_visible_context_json": "host_visible_context",
    "host_visible_context_base64": "host_visible_context",
}


def _parse_object_payload(json_payload: str, base64_payload: str) -> tuple[object | None, bool]:
    """Decode one compact object transport without accepting arbitrary text."""

    if json_payload and base64_payload:
        return {"invalid": True}, True
    try:
        decoded = (
            base64.b64decode(base64_payload, validate=True).decode("utf-8")
            if base64_payload
            else json_payload
        )
        if not decoded:
            return None, False
        value = json.loads(decoded)
    except (TypeError, ValueError, binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        return {"invalid": True}, True
    return (value, False) if isinstance(value, dict) else ({"invalid": True}, True)


def _parse_text_base64(payload: str, *, maximum: int = 480) -> tuple[str | None, bool]:
    """Decode one transient current-user instruction without shell encoding loss."""

    if not payload:
        return None, False
    try:
        value = base64.b64decode(payload, validate=True).decode("utf-8")
    except (TypeError, ValueError, binascii.Error, UnicodeDecodeError):
        return None, True
    if not value or len(value) > maximum or "\r" in value or "\n" in value:
        return None, True
    return value, False


def _retired_host_transport_payload(args: argparse.Namespace) -> dict[str, object] | None:
    """Refuse legacy Host flags before decoding, importing, or retrying them."""

    supplied = sorted(
        {retired_name for field, retired_name in _RETIRED_HOST_OPTION_FIELDS.items() if str(getattr(args, field, "") or "")}
    )
    if not supplied:
        return None
    return {
        "ok": False,
        "schema": "super-brain.host-transport-retirement.v1",
        "available": False,
        "code": "H7_HOST_TRANSPORT_RETIRED",
        "retiredInputs": supplied,
        "next": "Remove Host payloads and use the current local cwd/session scope with H7 contract and project proof.",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Super Brain local runtime CLI")
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--memory-root", default="")
    parser.add_argument("--workspace-root", default="")
    parser.add_argument("--base64", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    recall = sub.add_parser("recall")
    recall.add_argument("--query", required=True)
    recall.add_argument("--top-k", type=int, default=DEFAULT_RECALL_TOP_K, choices=range(1, 5))
    recall.add_argument("--max-tokens", type=int, default=DEFAULT_RECALL_MAX_TOKENS, choices=range(32, 501))
    recall.add_argument("--layer", default="all")
    recall.add_argument("--query-date", default="")

    recent = sub.add_parser("recent")
    recent.add_argument("--limit", type=int, default=5)

    context = sub.add_parser("context")
    context.add_argument("--memory-mode", default="auto", choices=("auto", "force", "off"))
    context.add_argument(
        "--turn-outcome",
        default="unknown",
        choices=(
            "unknown",
            "ephemeral_insertion",
            "active_work_progressed",
            "side_branch_completed",
            "side_branch_partial",
            "blocked",
        ),
    )
    context.add_argument("--user-control", default="unknown", choices=("unknown", "none", "stop", "replace"))
    context.add_argument("--completion-evidence-present", action="store_true")
    context.add_argument("--turn-intent", choices=TURN_INTENTS, default="direct")

    turn_close = sub.add_parser("turn-close")
    turn_close.add_argument("--task-id", default="")
    turn_close.add_argument("--workspace-key", default="")
    turn_close.add_argument("--session-key", default="")
    turn_close.add_argument(
        "--turn-outcome",
        default="unknown",
        choices=(
            "unknown",
            "ephemeral_insertion",
            "active_work_progressed",
            "side_branch_completed",
            "side_branch_partial",
            "blocked",
        ),
    )
    turn_close.add_argument("--user-control", default="unknown", choices=("unknown", "none", "stop", "replace"))
    turn_close.add_argument("--completion-evidence-ref", default="")
    turn_close.add_argument("--transition-id", default="")
    turn_close.add_argument("--timeout-seconds", type=float, default=8.0)

    rebind_local = sub.add_parser("rebind-local", help="Local one-time session recovery")
    rebind_local.add_argument("--action", choices=("issue", "consume", "finalize", "query", "revoke"), required=True)
    rebind_local.add_argument("--command-id", required=True)
    rebind_local.add_argument("--target-command-id", default="")
    rebind_local.add_argument("--recovery-ref", default="")
    rebind_local.add_argument("--aggregate-kind", choices=("intent", "task"), default=None)
    rebind_local.add_argument("--expected-revision", type=int, default=None)
    rebind_local.add_argument("--expected-state-hash", default="")
    rebind_local.add_argument("--contract-revision", type=int, default=None)
    rebind_local.add_argument("--contract-hash", default="")
    rebind_local.add_argument("--plan-fingerprint", default="")
    rebind_local.add_argument("--previous-receipt-id", default="")
    rebind_local.add_argument("--previous-receipt-hash", default="")
    rebind_local.add_argument("--project-proof-hash", default="")
    rebind_local.add_argument("--ttl-seconds", type=int, default=300)
    rebind_local.add_argument("--source", default="brain_cli.rebind_local")

    turn_runtime = sub.add_parser("turn-runtime")
    turn_runtime.add_argument("--phase", default="open", choices=("open", "checkpoint", "close", "evidence"))
    turn_runtime.add_argument("--memory-mode", default="auto", choices=("auto", "force", "off"))
    turn_runtime.add_argument(
        "--recovery-event",
        default="none",
        choices=("none", "compaction", "restart", "model_switch", "cross_session", "pause_resume", "user_correction", "parent_return"),
    )
    turn_runtime.add_argument(
        "--turn-outcome",
        default="unknown",
        choices=(
            "unknown",
            "ephemeral_insertion",
            "active_work_progressed",
            "side_branch_completed",
            "side_branch_partial",
            "blocked",
        ),
    )
    turn_runtime.add_argument("--user-control", default="unknown", choices=("unknown", "none", "stop", "replace"))
    turn_runtime.add_argument("--completion-evidence-ref", default="")
    turn_runtime.add_argument("--visible-progress-assertion-json", default="")
    turn_runtime.add_argument("--visible-progress-assertion-base64", default="")
    turn_runtime.add_argument("--host-thread-json", default="")
    turn_runtime.add_argument("--host-thread-base64", default="")
    turn_runtime.add_argument("--host-visible-context-json", default="")
    turn_runtime.add_argument("--host-visible-context-base64", default="")
    turn_runtime.add_argument("--progress-checkpoint-json", default="")
    turn_runtime.add_argument("--progress-checkpoint-base64", default="")
    turn_runtime.add_argument("--project-progress-proof-json", default="")
    turn_runtime.add_argument("--project-progress-proof-base64", default="")
    turn_runtime.add_argument("--execution-assist-request-json", default="")
    turn_runtime.add_argument("--execution-assist-request-base64", default="")
    turn_runtime.add_argument("--capability-route-receipt-json", default="")
    turn_runtime.add_argument("--capability-route-receipt-base64", default="")
    turn_runtime.add_argument("--latest-user-instruction-base64", default="")
    turn_runtime.add_argument("--transition-id", default="")
    turn_runtime.add_argument("--timeout-seconds", type=float, default=8.0)
    turn_runtime.add_argument("--turn-intent", choices=TURN_INTENTS, default="direct")

    # Internal stdio bridge used only when an already-running MCP worker is
    # stale. Its bounded JSON body stays process-memory-only and is never
    # written to a temporary file.
    sub.add_parser("mcp-bridge", help=argparse.SUPPRESS)

    sub.add_parser("status")
    sub.add_parser("health")
    scope = sub.add_parser("scope", help="Local Scope Broker control surface")
    scope.add_argument(
        "--action",
        choices=("list", "status", "register", "bind"),
        default="list",
    )
    scope.add_argument("--channel-id", default="")
    scope.add_argument("--pairing-request-ref", default="")
    scope.add_argument("--workline-id", default="")
    scope.add_argument("--contract-file", default="")
    scope.add_argument("--project-root", default="")
    scope.add_argument("--access-mode", choices=("read", "write"), default="write")
    scope.add_argument("--ttl-seconds", type=int, default=60)
    scope.add_argument("--lease-seconds", type=int, default=300)
    activate = sub.add_parser("activate")
    activate.add_argument("--route", default="bare_wake")
    activate.add_argument("--workspace-key", default="")
    activate.add_argument("--session-key", default="")
    activate.add_argument("--task-id", default="")
    activate.add_argument("--task-instance-id", default="")
    activate.add_argument("--action-authorization", default="not_applicable", choices=("allowed", "withheld", "not_applicable"))
    activate.add_argument("--require-scope", action="store_true")
    return parser


def _ensure_core_activation(
    core: BrainCore,
    *,
    route: str,
    action_authorization: str = "withheld",
    task_id: str = "",
    task_instance_id: str = "",
    workspace_key: str = "",
    session_key: str = "",
    memory_snapshot_hash: str = "",
    memory_refs: list[str] | None = None,
) -> dict[str, object]:
    """Keep the no-Hook core path activation-bound and idempotent."""

    resolved_workspace = workspace_key or core._context_workspace_key()
    resolved_session = session_key or core._context_session_key()
    contract = {}
    if resolved_workspace and resolved_session:
        full_contract, _ = core._read_context_contract(resolved_workspace, resolved_session)
        if isinstance(full_contract, dict):
            contract = full_contract
    if not contract:
        contract = core._execution_contract_context() or {}
    resolved_task = task_id or str(contract.get("taskId", ""))
    resolved_instance = task_instance_id or str(contract.get("taskInstanceId", ""))
    anchor = contract.get("instructionAnchor") if isinstance(contract.get("instructionAnchor"), dict) else {}
    continuation = contract.get("continuationReceipt") if isinstance(contract.get("continuationReceipt"), dict) else {}
    recovery = contract.get("recoveryCheckpoint") or contract.get("checkpoint")
    recovery = recovery if isinstance(recovery, dict) else {}
    activation_memory_root = core.memory_root if core.memory_root.exists() else core.memory_base
    receipt, _ = ensure_current(
        core.package_root,
        core.memory_base,
        memory_root=activation_memory_root,
        workspace_key=resolved_workspace,
        session_key=resolved_session,
        task_id=resolved_task,
        task_instance_id=resolved_instance,
        route=route,
        memory_snapshot_hash=memory_snapshot_hash,
        memory_refs=memory_refs or [],
        action_authorization=action_authorization,
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
        require_scope=bool(resolved_workspace and resolved_session and (resolved_task or resolved_instance)),
    )
    return receipt


def _explicit_scope_matches_local(core: BrainCore, workspace_key: str, session_key: str) -> bool:
    """Treat CLI scope flags as assertions, never as foreign-scope selectors."""

    supplied_workspace = str(workspace_key or "").strip().lower()
    supplied_session = str(session_key or "").strip().lower()
    if not supplied_workspace and not supplied_session:
        return True
    current_workspace = str(core._context_workspace_key()).strip().lower()
    current_session = str(core._context_session_key()).lower()
    if not supplied_workspace or not supplied_session or supplied_workspace != current_workspace:
        return False
    # An explicit scope is a local assertion, never a session selector.  A
    # missing process session therefore cannot authorize any explicit session,
    # even when the workspace key matches.
    return bool(current_session) and supplied_session == current_session


def _mcp_bridge_failure(code: str) -> dict[str, object]:
    """Return a bounded, non-durable bridge failure without echoing input."""

    return {
        "ok": False,
        "schema": "super-brain.mcp-cli-bridge.v1",
        "available": False,
        "code": code,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _read_mcp_bridge_request() -> tuple[str, dict[str, object] | None, str]:
    """Read one bounded local MCP-to-CLI request from stdin."""

    try:
        payload = sys.stdin.buffer.read(_MCP_CLI_BRIDGE_MAX_STDIN_BYTES + 1)
    except OSError:
        return "", None, "H7_MCP_CLI_BRIDGE_STDIN_UNAVAILABLE"
    if not payload or len(payload) > _MCP_CLI_BRIDGE_MAX_STDIN_BYTES:
        return "", None, "H7_MCP_CLI_BRIDGE_INPUT_INVALID"
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "", None, "H7_MCP_CLI_BRIDGE_INPUT_INVALID"
    if not isinstance(value, Mapping) or set(value) != {"schema", "name", "arguments"}:
        return "", None, "H7_MCP_CLI_BRIDGE_INPUT_INVALID"
    name = value.get("name")
    arguments = value.get("arguments")
    if value.get("schema") != _MCP_CLI_BRIDGE_SCHEMA or not isinstance(name, str) or not isinstance(arguments, Mapping):
        return "", None, "H7_MCP_CLI_BRIDGE_INPUT_INVALID"
    return name, dict(arguments), ""


def _mcp_bridge_object_json(arguments: Mapping[str, object], field: str) -> tuple[str, str]:
    if field not in arguments:
        return "", ""
    value = arguments.get(field)
    if not isinstance(value, Mapping):
        return "", "H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID"
    try:
        return json.dumps(dict(value), ensure_ascii=False, separators=(",", ":")), ""
    except (TypeError, ValueError):
        return "", "H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID"


def _mcp_bridge_turn_runtime_args(arguments: Mapping[str, object]) -> tuple[argparse.Namespace | None, str]:
    """Translate a strict bridge body into the existing CLI turn contract."""

    if set(arguments).intersection(_RETIRED_HOST_BRIDGE_FIELDS):
        return None, "H7_HOST_TRANSPORT_RETIRED"
    if set(arguments).difference(_MCP_CLI_BRIDGE_TURN_ARGUMENTS):
        return None, "H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID"

    def enum_value(field: str, default: str, allowed: tuple[str, ...] | list[str]) -> tuple[str, str]:
        value = arguments.get(field, default)
        if not isinstance(value, str) or value not in allowed:
            return "", "H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID"
        return value, ""

    phase, code = enum_value("phase", "open", ("open", "checkpoint", "close", "evidence"))
    if code:
        return None, code
    memory_mode, code = enum_value("memory_mode", "auto", ("auto", "force", "off"))
    if code:
        return None, code
    recovery_event, code = enum_value(
        "recovery_event",
        "none",
        ("none", "compaction", "restart", "model_switch", "cross_session", "pause_resume", "user_correction", "parent_return"),
    )
    if code:
        return None, code
    turn_outcome, code = enum_value(
        "turn_outcome",
        "unknown",
        ("unknown", "ephemeral_insertion", "active_work_progressed", "side_branch_completed", "side_branch_partial", "blocked"),
    )
    if code:
        return None, code
    user_control, code = enum_value("user_control", "unknown", ("unknown", "none", "stop", "replace"))
    if code:
        return None, code
    turn_intent, code = enum_value("turn_intent", "direct", list(TURN_INTENTS))
    if code:
        return None, code

    completion_evidence_ref = arguments.get("completion_evidence_ref", "")
    transition_id = arguments.get("transition_id", "")
    if (
        not isinstance(completion_evidence_ref, str)
        or len(completion_evidence_ref) > 240
        or not isinstance(transition_id, str)
        or len(transition_id) > 120
    ):
        return None, "H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID"

    latest_user_instruction = arguments.get("latest_user_instruction")
    if latest_user_instruction is None:
        latest_user_instruction_base64 = ""
    elif (
        not isinstance(latest_user_instruction, str)
        or not latest_user_instruction
        or len(latest_user_instruction) > 480
        or "\r" in latest_user_instruction
        or "\n" in latest_user_instruction
    ):
        return None, "H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID"
    else:
        latest_user_instruction_base64 = base64.b64encode(latest_user_instruction.encode("utf-8")).decode("ascii")

    objects: dict[str, str] = {}
    for field in (
        "progress_checkpoint",
        "project_progress_proof",
        "execution_assist_request",
        "capability_route_receipt",
    ):
        encoded, code = _mcp_bridge_object_json(arguments, field)
        if code:
            return None, code
        objects[field] = encoded

    return (
        argparse.Namespace(
            phase=phase,
            memory_mode=memory_mode,
            recovery_event=recovery_event,
            turn_outcome=turn_outcome,
            user_control=user_control,
            completion_evidence_ref=completion_evidence_ref,
            visible_progress_assertion_json="",
            visible_progress_assertion_base64="",
            host_thread_json="",
            host_thread_base64="",
            host_visible_context_json="",
            host_visible_context_base64="",
            progress_checkpoint_json=objects["progress_checkpoint"],
            progress_checkpoint_base64="",
            project_progress_proof_json=objects["project_progress_proof"],
            project_progress_proof_base64="",
            execution_assist_request_json=objects["execution_assist_request"],
            execution_assist_request_base64="",
            capability_route_receipt_json=objects["capability_route_receipt"],
            capability_route_receipt_base64="",
            latest_user_instruction_base64=latest_user_instruction_base64,
            transition_id=transition_id,
            timeout_seconds=8.0,
            turn_intent=turn_intent,
        ),
        "",
    )


def _run_turn_runtime_command(
    core: BrainCore,
    args: argparse.Namespace,
) -> dict[str, object]:
    """Run the normal turn-runtime implementation from parsed CLI arguments."""

    retired_host = _retired_host_transport_payload(args)
    if retired_host is not None:
        return retired_host

    progress_checkpoint, _ = _parse_object_payload(
        args.progress_checkpoint_json,
        args.progress_checkpoint_base64,
    )
    project_progress_proof, _ = _parse_object_payload(
        args.project_progress_proof_json,
        args.project_progress_proof_base64,
    )
    execution_assist_request, _ = _parse_object_payload(
        args.execution_assist_request_json,
        args.execution_assist_request_base64,
    )
    capability_route_receipt, _ = _parse_object_payload(
        args.capability_route_receipt_json,
        args.capability_route_receipt_base64,
    )
    latest_user_instruction, latest_user_instruction_parse_failed = _parse_text_base64(
        args.latest_user_instruction_base64
    )
    if latest_user_instruction_parse_failed:
        return {
            "ok": False,
            "schema": "super-brain.turn-runtime.v1",
            "available": False,
            "code": "H7_LATEST_INSTRUCTION_PAYLOAD_INVALID",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    # ``--workspace-root`` changes cwd in ``main``. BrainCore derives the local
    # workspace key and local session identity directly.
    return run_turn(
        core,
        phase=args.phase,
        memory_mode=args.memory_mode,
        recovery_event=args.recovery_event,
        turn_outcome=args.turn_outcome,
        user_control=args.user_control,
        completion_evidence_ref=args.completion_evidence_ref,
        visible_progress_assertion=None,
        progress_checkpoint=progress_checkpoint,
        project_progress_proof=project_progress_proof,
        execution_assist_request=execution_assist_request,
        capability_route_receipt=capability_route_receipt,
        latest_user_instruction=latest_user_instruction,
        transition_id=args.transition_id,
        timeout=args.timeout_seconds,
        turn_intent=args.turn_intent,
        require_visible_tail_assertion=False,
    )


def _run_local_rebind_command(core: BrainCore, args: argparse.Namespace) -> dict[str, object]:
    """Execute local session recovery from cwd + SUPER_BRAIN_LOCAL_SESSION_ID.

    The CLI is a transport-equivalent fallback.  Issue snapshots the current
    task from the local execution contract; successor lookup/repair actions
    use only the current cwd/session identity and refuse foreign selectors.
    """

    action = str(args.action or "").strip().lower()
    scope = core.authorize_scope(write=action in {"issue", "consume", "finalize", "revoke"})
    if scope.get("ok") is not True:
        return {
            "ok": False,
            "schema": "super-brain.local-session-rebind-result.v1",
            "available": False,
            "code": str(scope.get("code", "H7_SCOPE_LOCAL_SESSION_REQUIRED")),
            "state": str(scope.get("state", "withheld")),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    workspace_key = core._context_workspace_key()
    session_key = core._context_session_key()
    if not workspace_key or not session_key:
        return {
            "ok": False,
            "schema": "super-brain.local-session-rebind-result.v1",
            "available": False,
            "code": "H7_SCOPE_LOCAL_SESSION_REQUIRED",
            "state": "withheld",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
    request: dict[str, object] = {
        "action": action,
        "commandId": str(args.command_id),
        "requestingSessionKey": session_key,
        "workspaceKey": workspace_key,
        "source": str(args.source),
    }
    if action == "issue":
        # Issuing a recovery transaction snapshots the current aggregate and
        # therefore still requires the complete local execution contract.
        contract = core._execution_contract_context() or {}
        task_id = str(contract.get("taskId", "")).strip()
        task_instance_id = str(contract.get("taskInstanceId", "")).strip()
        package_version = str(core.manifest.get("version", "")).strip()
        if not task_id or not task_instance_id or not package_version:
            return {
                "ok": False,
                "schema": "super-brain.local-session-rebind-result.v1",
                "available": False,
                "code": "H7_SCOPE_LOCAL_TASK_REQUIRED",
                "state": "withheld",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        contract_revision = args.contract_revision
        if contract_revision is None:
            try:
                contract_revision = int(contract.get("revision", 0))
            except (TypeError, ValueError):
                contract_revision = 0
        plan_receipt = contract.get("planReceipt") if isinstance(contract.get("planReceipt"), dict) else {}
        plan_fingerprint = args.plan_fingerprint or str(plan_receipt.get("planFingerprint", ""))
        contract_hash = args.contract_hash or str(contract.get("continuityContractHash") or contract.get("contractHash") or "").strip().lower()
        if not re.fullmatch(r"^[a-f0-9]{64}$", contract_hash):
            contract_hash = hashlib.sha256(
                json.dumps(contract, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
            ).hexdigest()
        inferred_kind = "task"
        try:
            if int(contract.get("intentRevision", 0) or 0) > 0 and str(contract.get("intentAggregateId", "")).strip():
                inferred_kind = "intent"
        except (TypeError, ValueError):
            pass
        aggregate_kind = args.aggregate_kind or inferred_kind
        expected_revision = args.expected_revision
        if expected_revision is None and aggregate_kind == "intent":
            try:
                expected_revision = int(contract.get("intentRevision", 0) or 0)
            except (TypeError, ValueError):
                expected_revision = None
        intent_receipt = contract.get("intentResolutionReceipt") if isinstance(contract.get("intentResolutionReceipt"), dict) else {}
        request.update(
            {
                "taskId": task_id,
                "taskInstanceId": task_instance_id,
                "packageVersion": package_version,
                "aggregateKind": aggregate_kind,
                "contractRevision": contract_revision,
                "contractHash": contract_hash,
                "planFingerprint": plan_fingerprint,
            }
        )
        if expected_revision is not None:
            request["expectedRevision"] = expected_revision
        if aggregate_kind == "intent" and intent_receipt:
            if not args.previous_receipt_id and intent_receipt.get("receiptId"):
                request["previousReceiptId"] = str(intent_receipt["receiptId"])
            if not args.previous_receipt_hash and intent_receipt.get("payloadHash"):
                request["previousReceiptHash"] = str(intent_receipt["payloadHash"])
    elif args.aggregate_kind:
        # For lookup/repair actions the kind is an optional assertion.  Do
        # not inject the parser's issue default, otherwise an intent lookup
        # is silently interpreted as a task lookup.
        request["aggregateKind"] = args.aggregate_kind
    values = {
        "target-command-id": "targetCommandId",
        "recovery-ref": "recoveryRef",
        "expected-revision": "expectedRevision",
        "expected-state-hash": "expectedStateHash",
        "contract-revision": "contractRevision",
        "contract-hash": "contractHash",
        "plan-fingerprint": "planFingerprint",
        "previous-receipt-id": "previousReceiptId",
        "previous-receipt-hash": "previousReceiptHash",
        "project-proof-hash": "projectProofHash",
        "ttl-seconds": "ttlSeconds",
    }
    for source, target in values.items():
        value = getattr(args, source.replace("-", "_"))
        if value not in (None, ""):
            request[target] = value
    try:
        return BrainControl(core.memory_base).local_rebind(request)
    except BrainControlError as exc:
        return {
            "ok": False,
            "schema": "super-brain.local-session-rebind-result.v1",
            "available": False,
            "code": exc.code,
            "message": str(exc),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }


def _run_mcp_bridge(core: BrainCore, workspace_root: Path | None) -> object:
    """Serve one equivalent H7 call from a stale MCP worker's child process."""

    name, arguments, code = _read_mcp_bridge_request()
    if code:
        return _mcp_bridge_failure(code)
    assert arguments is not None
    if name == "brain_turn":
        if workspace_root is None:
            return _mcp_bridge_failure("H7_MCP_CLI_BRIDGE_LOCAL_SCOPE_REQUIRED")
        turn_args, code = _mcp_bridge_turn_runtime_args(arguments)
        if code or turn_args is None:
            return _mcp_bridge_failure(code or "H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID")
        return _run_turn_runtime_command(
            core,
            turn_args,
        )
    if name == "brain_recall":
        if set(arguments).difference({"query", "top_k", "max_tokens", "layer", "query_date"}):
            return _mcp_bridge_failure("H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID")
        query = arguments.get("query")
        top_k = arguments.get("top_k", DEFAULT_RECALL_TOP_K)
        max_tokens = arguments.get("max_tokens", DEFAULT_RECALL_MAX_TOKENS)
        layer = arguments.get("layer", "all")
        query_date = arguments.get("query_date", "")
        if (
            not isinstance(query, str)
            or not query.strip()
            or len(query) > 2000
            or isinstance(top_k, bool)
            or not isinstance(top_k, int)
            or top_k < 1
            or top_k > 4
            or isinstance(max_tokens, bool)
            or not isinstance(max_tokens, int)
            or max_tokens < 32
            or max_tokens > 500
            or not isinstance(layer, str)
            or layer not in {"all", "profile", "project", "decision"}
            or not isinstance(query_date, str)
            or len(query_date) > 120
        ):
            return _mcp_bridge_failure("H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID")
        return core.recall(query, top_k, max_tokens, layer, query_date)
    if name == "brain_recent":
        if set(arguments).difference({"limit"}):
            return _mcp_bridge_failure("H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID")
        limit = arguments.get("limit", 5)
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1 or limit > 20:
            return _mcp_bridge_failure("H7_MCP_CLI_BRIDGE_ARGUMENTS_INVALID")
        # The stale-MCP bridge is always a scoped runtime path.  Passing an
        # empty local session deliberately yields [] rather than reviving the
        # ordinary unscoped CLI compatibility behaviour.
        return core.recent(limit, session_key=core._context_session_key())
    return _mcp_bridge_failure("H7_MCP_CLI_BRIDGE_TOOL_UNSUPPORTED")


def main() -> int:
    args = build_parser().parse_args()
    workspace_root: Path | None = None
    original_cwd = Path.cwd().resolve()
    if args.workspace_root:
        candidate = Path(args.workspace_root).expanduser().resolve()
        if not candidate.is_dir():
            result = {
                "ok": False,
                "schema": "super-brain.turn-runtime.v1",
                "available": False,
                "code": "H7_WORKSPACE_ROOT_INVALID",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
            payload = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            sys.stdout.write(base64.b64encode(payload).decode("ascii") if args.base64 else payload.decode("utf-8"))
            return 2
        if args.command != "mcp-bridge" and candidate != original_cwd:
            result = {
                "ok": False,
                "schema": "super-brain.turn-runtime.v1",
                "available": False,
                "code": "H7_WORKSPACE_ROOT_REBIND_REQUIRED",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
            payload = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            sys.stdout.write(base64.b64encode(payload).decode("ascii") if args.base64 else payload.decode("utf-8"))
            return 2
        workspace_root = candidate
        # ``--workspace-root`` is also the Host-independent local scope for
        # CLI and stale-MCP bridge calls.  Changing cwd inside this one-shot
        # process lets BrainCore derive the exact same workspace key without
        # manufacturing Host metadata or persisting a machine path.
        try:
            os.chdir(workspace_root)
        except OSError:
            result = {
                "ok": False,
                "schema": "super-brain.turn-runtime.v1",
                "available": False,
                "code": "H7_WORKSPACE_ROOT_INVALID",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
            payload = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            sys.stdout.write(base64.b64encode(payload).decode("ascii") if args.base64 else payload.decode("utf-8"))
            return 2
    core = BrainCore(args.package_root, args.memory_root or None)
    activation = None
    # Status and health are observational.  They must never create an
    # activation receipt merely because a user asked to inspect the system.
    if args.command not in {"activate", "turn-runtime", "mcp-bridge", "context", "status", "health", "turn-close", "scope", "rebind-local"}:
        route = {
            "recall": "memory_recall",
            "recent": "memory_recall",
            "context": "current_session_continue",
            "turn-close": "current_session_continue",
            "status": "current_task_status",
            "health": "bare_wake",
        }.get(args.command, "bare_wake")
        activation = _ensure_core_activation(core, route=route, action_authorization="withheld")
    if args.command == "scope":
        control = ScopeBrokerControlClient(core.memory_base, runtime_path=Path(__file__).with_name("scope_broker_ipc.py"))
        if args.action == "list":
            result = control.list_channels()
        elif args.action == "status":
            result = control.status(args.channel_id)
        elif args.action == "register":
            if not args.contract_file:
                result = {"ok": False, "code": "H7_SCOPE_CONTRACT_FILE_REQUIRED", "state": "withheld"}
            else:
                try:
                    contract_path = Path(args.contract_file).expanduser().resolve()
                    contract = json.loads(contract_path.read_text(encoding="utf-8"))
                    encoded = json.dumps(contract, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
                    result = control.register_workline(
                        contract,
                        expected_contract_hash=hashlib.sha256(encoded).hexdigest(),
                        project_root=args.project_root or None,
                    )
                except (OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
                    result = {"ok": False, "code": "H7_SCOPE_CONTRACT_FILE_INVALID", "state": "withheld"}
        elif args.action == "bind":
            if args.pairing_request_ref:
                result = control.pair_request(
                    args.pairing_request_ref,
                    args.workline_id,
                    access_mode=args.access_mode,
                    ttl_seconds=args.ttl_seconds,
                    lease_seconds=args.lease_seconds,
                )
            elif args.channel_id:
                # Keep the channel-ID form as a narrow compatibility path.
                # New callers should use the per-connection pairing ref so a
                # global channel list is never used as a selector.
                result = control.pair_channel(
                    args.channel_id,
                    args.workline_id,
                    access_mode=args.access_mode,
                    ttl_seconds=args.ttl_seconds,
                    lease_seconds=args.lease_seconds,
                )
            else:
                result = {
                    "ok": False,
                    "code": "H7_SCOPE_PAIRING_REQUEST_REF_REQUIRED",
                    "state": "withheld",
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }
        else:
            # Keep the result shape defensive if a future parser extension
            # accidentally reaches an unsupported action.
            result = {
                "ok": False,
                "code": "H7_SCOPE_CONTROL_ACTION_UNSUPPORTED",
                "state": "withheld",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        control.close()
    elif args.command == "recall":
        result = core.recall(args.query, args.top_k, args.max_tokens, args.layer, args.query_date)
    elif args.command == "recent":
        result = core.recent(args.limit)
    elif args.command == "context":
        context_intent = resolve_turn_intent(args.turn_intent, memory_mode=args.memory_mode)
        if context_intent.get("ok") is not True:
            result = {
                "ok": False,
                "schema": "super-brain.context.v1",
                "available": False,
                "code": str(context_intent.get("code", "TURN_INTENT_INVALID")),
                "turnIntent": public_turn_intent(context_intent),
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        else:
            effective_context_memory_mode = str(context_intent.get("memoryMode", args.memory_mode))
            context_signals = tuple(
                str(item) for item in (context_intent.get("ruleSignals") or ()) if str(item).strip()
            )
            result = core.context(
                effective_context_memory_mode,
                args.turn_outcome,
                args.user_control,
                args.completion_evidence_present,
                context_signals,
            )
            result["turnIntent"] = public_turn_intent(context_intent)
        typed_memory = result.get("typedMemory") if isinstance(result, dict) else None
        if isinstance(typed_memory, dict) and result.get("available") is True:
            contract = {}
            context_workspace = core._context_workspace_key()
            context_session = core._context_session_key()
            if context_workspace and context_session:
                full_contract, _ = core._read_context_contract(context_workspace, context_session)
                if isinstance(full_contract, dict):
                    contract = full_contract
            if not contract:
                contract = core._execution_contract_context() or {}
            refs = []
            for item in typed_memory.get("refs", []) or []:
                if isinstance(item, dict) and item.get("cardId"):
                    refs.append(f"{item.get('cardId')}@{int(item.get('cardRevision', 0) or 0)}")
            _ensure_core_activation(
                core,
                route="current_session_continue",
                action_authorization="withheld",
                task_id=str(contract.get("taskId", "")),
                task_instance_id=str(contract.get("taskInstanceId", "")),
                memory_snapshot_hash=str(typed_memory.get("snapshotPayloadHash", "")),
                memory_refs=refs,
            )
            result["activation"] = core._activation_summary(
                str(contract.get("taskId", "")),
                str(contract.get("taskInstanceId", "")),
            )
    elif args.command == "turn-close":
        # Explicit CLI scope is a local assertion, never a selector for a
        # foreign contract.  Check it before the dispatcher so Resolve,
        # ResumeParent, and CloseTurn cannot mutate another scope before the
        # CLI rejects the request.  Keep the post-dispatch check as a
        # defensive race guard around the process-local scope binding.
        explicit_scope = bool(args.workspace_key or args.session_key)
        if explicit_scope and not _explicit_scope_matches_local(core, args.workspace_key, args.session_key):
            result = {
                "ok": False,
                "schema": "super-brain.turn-close.v1",
                "available": False,
                "code": "H7_CLI_FOREIGN_SCOPE_FORBIDDEN",
                "stateMutated": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        else:
            result = dispatch_turn_close(
                core.package_root,
                core.memory_base,
                task_id=args.task_id,
                workspace_key=args.workspace_key or core._context_workspace_key(),
                session_key=args.session_key or core._context_session_key(),
                turn_outcome=args.turn_outcome,
                user_control=args.user_control,
                completion_evidence_ref=args.completion_evidence_ref,
                transition_id=args.transition_id,
                project_root=core._context_project_root(),
                timeout=args.timeout_seconds,
            )
        # A dispatcher policy packet can be ``ok=true`` while withholding on
        # a missing scope.  Never turn that observational response into an
        # unscoped activation receipt; only a fully bound local workspace and
        # session may refresh activation here.
        local_workspace = core._context_workspace_key()
        local_session = core._context_session_key()
        if (
            result.get("ok") is True
            and local_workspace
            and local_session
            and _explicit_scope_matches_local(core, args.workspace_key, args.session_key)
        ):
            _ensure_core_activation(
                core,
                route="current_session_continue",
                action_authorization="withheld",
                task_id=args.task_id,
                workspace_key=args.workspace_key,
                session_key=args.session_key,
            )
    elif args.command == "rebind-local":
        result = _run_local_rebind_command(core, args)
    elif args.command == "turn-runtime":
        result = _run_turn_runtime_command(core, args)
    elif args.command == "mcp-bridge":
        result = _run_mcp_bridge(core, workspace_root)
    elif args.command == "status":
        result = core.status()
    elif args.command == "activate":
        explicit_scope = bool(args.workspace_key or args.session_key)
        effective_require_scope = bool(args.require_scope or explicit_scope)
        if explicit_scope and not _explicit_scope_matches_local(core, args.workspace_key, args.session_key):
            result = {
                "ok": False,
                "schema": "super-brain.activation-receipt.v1",
                "available": False,
                "code": "H7_CLI_FOREIGN_SCOPE_FORBIDDEN",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        else:
            result = activate_brain(
                args.package_root,
                core.memory_base,
                memory_root=core.memory_root,
                workspace_key=args.workspace_key or core._context_workspace_key(),
                session_key=args.session_key or core._context_session_key(),
                task_id=args.task_id,
                task_instance_id=args.task_instance_id,
                route=args.route,
                action_authorization=args.action_authorization,
                require_scope=effective_require_scope,
            )
    else:
        result = core.health()
    payload = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if args.base64:
        sys.stdout.write(base64.b64encode(payload).decode("ascii"))
    else:
        sys.stdout.buffer.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
