from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import sys
from contextlib import nullcontext
from pathlib import Path

from brain_core import DEFAULT_RECALL_MAX_TOKENS, DEFAULT_RECALL_TOP_K, BrainCore
from activation_receipt import activate as activate_brain, ensure_current
from turn_close_dispatcher import dispatch_turn_close
from turn_runtime import run_turn, visible_tail_assertion_payload_parse_invalid
from turn_intent import TURN_INTENTS, public_projection as public_turn_intent, resolve_turn_intent


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


def _cli_host_scope(workspace_root: Path) -> tuple[str, str] | None:
    """Convert an explicit CLI workspace into the same ephemeral Host scope as MCP."""

    thread_id = os.environ.get("CODEX_THREAD_ID", "").strip()
    source = str(workspace_root).rstrip("/\\").lower()
    if not thread_id or not source:
        return None
    return "ws-" + hashlib.sha256(source.encode("utf-8")).hexdigest()[:24], thread_id


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
    turn_runtime.add_argument("--progress-checkpoint-json", default="")
    turn_runtime.add_argument("--progress-checkpoint-base64", default="")
    turn_runtime.add_argument("--project-progress-proof-json", default="")
    turn_runtime.add_argument("--project-progress-proof-base64", default="")
    turn_runtime.add_argument("--execution-assist-request-json", default="")
    turn_runtime.add_argument("--execution-assist-request-base64", default="")
    turn_runtime.add_argument("--capability-route-receipt-json", default="")
    turn_runtime.add_argument("--capability-route-receipt-base64", default="")
    turn_runtime.add_argument("--transition-id", default="")
    turn_runtime.add_argument("--timeout-seconds", type=float, default=8.0)
    turn_runtime.add_argument("--turn-intent", choices=TURN_INTENTS, default="direct")

    sub.add_parser("status")
    sub.add_parser("health")
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


def main() -> int:
    args = build_parser().parse_args()
    workspace_root: Path | None = None
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
        workspace_root = candidate
    core = BrainCore(args.package_root, args.memory_root or None)
    activation = None
    # Status and health are observational.  They must never create an
    # activation receipt merely because a user asked to inspect the system.
    if args.command not in {"activate", "turn-runtime", "context", "status", "health"}:
        route = {
            "recall": "memory_recall",
            "recent": "memory_recall",
            "context": "current_session_continue",
            "turn-close": "current_session_continue",
            "status": "current_task_status",
            "health": "bare_wake",
        }.get(args.command, "bare_wake")
        activation = _ensure_core_activation(core, route=route, action_authorization="withheld")
    if args.command == "recall":
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
            timeout=args.timeout_seconds,
        )
        _ensure_core_activation(
            core,
            route="current_session_continue",
            action_authorization="withheld",
            task_id=args.task_id,
            workspace_key=args.workspace_key,
            session_key=args.session_key,
        )
    elif args.command == "turn-runtime":
        visible_progress_assertion, visible_progress_assertion_parse_failed = _parse_object_payload(
            args.visible_progress_assertion_json,
            args.visible_progress_assertion_base64,
        )
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
        if visible_progress_assertion_parse_failed:
            result = visible_tail_assertion_payload_parse_invalid(args.phase)
        else:
            scope_context = (
                core.bind_host_scope(_cli_host_scope(workspace_root), workspace_root=workspace_root)
                if workspace_root is not None
                else nullcontext()
            )
            with scope_context:
                result = run_turn(
                    core,
                    phase=args.phase,
                    memory_mode=args.memory_mode,
                    recovery_event=args.recovery_event,
                    turn_outcome=args.turn_outcome,
                    user_control=args.user_control,
                    completion_evidence_ref=args.completion_evidence_ref,
                    visible_progress_assertion=visible_progress_assertion,
                    progress_checkpoint=progress_checkpoint,
                    project_progress_proof=project_progress_proof,
                    execution_assist_request=execution_assist_request,
                    capability_route_receipt=capability_route_receipt,
                    transition_id=args.transition_id,
                    timeout=args.timeout_seconds,
                    turn_intent=args.turn_intent,
                )
    elif args.command == "status":
        result = core.status()
    elif args.command == "activate":
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
            require_scope=args.require_scope,
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
