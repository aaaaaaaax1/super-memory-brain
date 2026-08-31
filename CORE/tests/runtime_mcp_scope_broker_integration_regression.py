"""Real stdio MCP -> local Broker channel integration checks."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

import brain_mcp
from brain_control import BrainControl
from brain_context import canonical_hash, project_progress_root_hash, scope_ref, visible_progress_scope_binding_hash
from brain_core import BrainCore
from mcp_transport_health import LocalBrokerStdioTransportHealth
from scope_broker import ScopeBroker
from scope_broker_ipc import ScopeBrokerControlClient, ScopeBrokerServer
from scope_provider import BrokerScopeProvider


def _valid_intent_contract() -> dict[str, object]:
    """Return the smallest product intent accepted by BrainControl."""

    return {
        "schema": "super-brain.intent-contract.v2",
        "literalRequestDigest": "editable notebook without direct database writes",
        "resolvedOutcome": "Users edit notebook entries through governed commands.",
        "productRole": "local notebook UI backed by the command API",
        "integrationObligations": ["governed command API"],
        "materialUnknowns": [],
        "compatibilityGuards": ["no browser-side direct SQLite or database writes"],
        "preservedCapabilities": ["editable notebook"],
        "acceptanceCriteria": ["an edit is visible and produces a receipt"],
        "governedEquivalent": "governed command editing through a loopback API",
        "autonomyTier": "align",
        "integrationMap": {
            "entryPoint": "notebook page",
            "userFlow": "open note, edit, save, observe receipt",
            "domainOwner": "BrainControl command engine",
            "stateOwner": "brain-state SQLite authority",
            "downstreamConsumers": ["notebook query projection"],
            "failureRecovery": "CAS conflict keeps draft and offers retry",
            "privacyPerformance": "loopback only and bounded payloads",
            "compatibilityMigration": "legacy records remain read-only until migration",
            "verification": "MCP local rebind regression",
            "completionCondition": "edit and receipt path verified",
        },
        "investigationEvidence": ["runtime/brain_control.py"],
        "materialBranches": [],
        "focusedQuestion": "",
        "preserveExistingFlow": True,
        "replacementReceipt": "",
        "componentResolution": {
            "requestedComponent": "direct database editor",
            "resolvedComponent": "governed command API",
            "outcomePreserved": True,
            "reason": "the command API preserves editing with receipts",
        },
    }


def _workspace_key(root: Path) -> str:
    normalized = str(root.resolve()).rstrip("/\\").lower()
    return "ws-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24]


def _contract(project: Path, suffix: str) -> dict[str, object]:
    return {
        "schema": "super-brain.execution-contract.v1",
        "status": "active",
        "taskId": "mcp-broker-" + suffix,
        "taskInstanceId": "ti-" + suffix * 32,
        "workspaceKey": _workspace_key(project),
        "ownerSessionKey": "sid-" + suffix * 24,
        "packageVersion": "0.6.0",
        "revision": 1,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _rebind_contract(project: Path, task_id: str, task_instance_id: str, session_key: str, revision: int) -> dict[str, object]:
    return {
        "schema": "super-brain.execution-contract.v1",
        "status": "active",
        "taskId": task_id,
        "taskInstanceId": task_instance_id,
        "workspaceKey": _workspace_key(project),
        "ownerSessionKey": session_key,
        "packageVersion": _package_version(),
        "revision": revision,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _hash(value: dict[str, object]) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def _timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _package_version() -> str:
    return str(json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["version"])


def _contract_file_name(task_id: str, workspace_key: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", task_id).strip("-").lower()[:36].rstrip("-") or "task"
    return f"{safe}-{hashlib.sha256(task_id.encode('utf-8')).hexdigest()[:16]}--{workspace_key}.json"


def _file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_native_memory_snapshot(workspace: Path) -> None:
    """Seed only the bounded native memory projection required by H7 open."""

    body = {
        "schema": "super-brain.native-memory-influence-snapshot.v1",
        "generatedAt": _timestamp(),
        "entryCount": 1,
        "entries": [
            {
                "kind": "preference",
                "bucket": "behaviorGuidance",
                "scopeKind": "global",
                "scopeRef": scope_ref("user"),
                "item": {
                    "cardId": "card-mcp-write-continuation",
                    "cardRevision": 1,
                    "title": "Keep live MCP continuation scoped",
                    "effect": "shape_behavior",
                    "statement": "Use the current H7 execution contract without retaining raw prompts.",
                    "conditions": ["A unique local scope is verified."],
                    "confidence": 99,
                    "strength": "strong",
                },
            }
        ],
        "omitted": {"invalid": 0, "expired": 0, "notReady": 0, "unsafe": 0},
        "truncated": False,
        "scopeRefAlgorithm": "sha256(canonical-json:{scopeKey})",
        "activeOnly": True,
        "decisionConstraintsStored": False,
        "focusStored": False,
        "rawPromptStored": False,
        "rawSessionIdStored": False,
    }
    _write_json(workspace / "native-memory-influence-snapshot.json", {**body, "payloadHash": canonical_hash(body)})


def _write_live_contract(state_root: Path, project: Path, session_key: str, task_id: str) -> tuple[dict[str, object], Path]:
    """Create one complete current H7 contract without any host input."""

    workspace = state_root / "workspace"
    workspace_key = _workspace_key(project)
    package_version = _package_version()
    evidence_path = project / "project-progress-evidence.txt"
    evidence_path.write_text("live MCP continuation evidence\n", encoding="utf-8")
    evidence = {"kind": "project_file", "relativePath": evidence_path.name, "sha256": _file_hash(evidence_path)}
    phase = "Fixture"
    current_step = "Open the broker-bound governed turn."
    next_action = "Write a verified live MCP checkpoint."
    proof_body = {
        "schema": "super-brain.project-progress-proof.v1",
        "state": "current",
        "phase": phase,
        "currentStep": current_step,
        "completedItems": [],
        "projectEvidence": [evidence],
        "verificationResults": [],
        "nextAction": next_action,
        "missing": [],
        "projectRootHash": project_progress_root_hash(project),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    proof = {**proof_body, "payloadHash": canonical_hash(proof_body)}
    sentence = "The live MCP scope is bound and ready for a verified checkpoint."
    visible_body = {
        "schema": "super-brain.visible-progress-receipt.v1",
        "source": "assistant_visible_reply",
        "sentenceHash": hashlib.sha256(sentence.encode("utf-8")).hexdigest(),
        "currentPhase": phase,
        "currentStep": current_step,
        "nextAction": next_action,
        "projectProgressPayloadHash": str(proof["payloadHash"]),
        "scopeBindingHash": visible_progress_scope_binding_hash(
            task_id=task_id,
            task_instance_id="ti-" + "1" * 32,
            workspace_key=workspace_key,
            owner_session_key=session_key,
            package_version=package_version,
        ),
        "transitionId": "mcp-live-visible-fixture",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    contract = {
        "ok": True,
        "schema": "super-brain.execution-contract.v1",
        "taskId": task_id,
        "taskInstanceId": "ti-" + "1" * 32,
        "workspaceKey": workspace_key,
        "ownerSessionKey": session_key,
        "packageVersion": package_version,
        "status": "active",
        "revision": 7,
        "focusId": "mcp-live-continuation",
        "focusLabel": "Live MCP continuation fixture",
        "lastConfirmedSentence": sentence,
        "lastConfirmedSource": "assistant_visible_reply",
        "currentPhase": phase,
        "currentStep": current_step,
        "nextAction": next_action,
        "returnStack": [],
        "blockers": [],
        "needsReconciliation": False,
        "planReceiptRequired": True,
        "planReceipt": {
            "focusId": "mcp-live-continuation",
            "contractRevision": 7,
            "planFingerprint": "mcp-live-plan-7",
        },
        "instructionAnchor": {"contentHash": "a" * 64},
        "recoveryCheckpoint": {"checkpointId": "mcp-live-checkpoint", "stateHash": "b" * 64},
        "projectProgressProof": proof,
        "visibleProgressReceipt": {**visible_body, "payloadHash": canonical_hash(visible_body)},
        "updatedAt": _timestamp(),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    contract_path = workspace / "runtime-state" / "execution-contracts" / _contract_file_name(task_id, workspace_key)
    _write_json(contract_path, contract)
    _write_json(
        workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
        {
            "schema": "super-brain.execution-hot-index.v1",
            "packageVersion": package_version,
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "entries": [
                {
                    "taskId": task_id,
                    "workspaceKey": workspace_key,
                    "ownerSessionKey": session_key,
                    "packageVersion": package_version,
                    "revision": 7,
                    "status": "active",
                    "updatedAt": str(contract["updatedAt"]),
                    "contractFileName": contract_path.name,
                }
            ],
        },
    )
    return contract, contract_path


def _checkpoint_proof(project: Path, *, phase: str, current_step: str, next_action: str) -> dict[str, object]:
    evidence_path = project / "project-progress-evidence.txt"
    return {
        "schema": "super-brain.project-progress-input.v1",
        "phase": phase,
        "currentStep": current_step,
        "completedItems": [],
        "projectEvidence": [{"kind": "project_file", "relativePath": evidence_path.name, "sha256": _file_hash(evidence_path)}],
        "verificationResults": [],
        "nextAction": next_action,
    }


def _live_mcp_environment() -> dict[str, str]:
    """Ensure this is a real Broker-backed stdio process, never replay."""

    environment = dict(os.environ)
    # Deliberately poison retired deployment variables.  The injected local
    # stdio transport must neither read their binding file nor let them alter
    # its runtime identity/health.
    environment.pop("SUPER_BRAIN_MCP_OFFLINE_REPLAY", None)
    environment["SUPER_BRAIN_PACKAGE_ROOT"] = str(Path(__file__).resolve().parent / "not-the-package")
    environment["SUPER_BRAIN_RUNTIME_IDENTITY"] = "stale-deployment-identity"
    environment["SUPER_BRAIN_MCP_TRANSPORT"] = "codex_registered_v1"
    environment["SUPER_BRAIN_MCP_REGISTRATION_EPOCH"] = "stale-deployment-epoch"
    return environment


def _send(process: subprocess.Popen[str], value: dict[str, object]) -> dict[str, object]:
    assert process.stdin is not None and process.stdout is not None
    process.stdin.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    process.stdin.flush()
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if line:
            return json.loads(line)
    raise AssertionError("MCP response timeout")


def _status_payload(response: dict[str, object]) -> dict[str, object]:
    result = response.get("result") or {}
    content = result.get("content") if isinstance(result, dict) else None
    assert isinstance(content, list) and content and isinstance(content[0], dict)
    return json.loads(str(content[0]["text"]))


def test_bound_task_layer_uses_the_channel_projection() -> None:
    """Task/session recall must use the bound channel, never generic recall."""

    with tempfile.TemporaryDirectory(prefix="super-brain-broker-task-recall-") as directory:
        state = Path(directory) / "state"
        memory = state / "shared"
        project = Path(directory) / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        contract = _contract(project, "c")
        broker = ScopeBroker(state)
        registered = broker.register_workline(contract, expected_contract_hash=_hash(contract))
        assert registered.ok and registered.context is not None
        channel = broker.open_channel()
        paired = broker.pair_channel(channel, registered.context.workline_id, access_mode="read")
        assert paired.ok
        core = BrainCore(
            ROOT,
            memory,
            scope_provider=BrokerScopeProvider(broker, channel),
            runtime_mode="local_stdio_scope_broker",
            transport_health=LocalBrokerStdioTransportHealth(broker, channel),
        )
        projection = {
            "scopeRef": "f" * 64,
            "stateHash": "e" * 64,
            "revision": 1,
            "packageVersion": "0.6.0",
            "lifecycle": "active",
            "contractRevision": 1,
            "planFingerprint": "plan-current",
            "lastConfirmedSentence": "bound task recall is projected from the channel",
            "lastConfirmedSource": "assistant_visible_reply",
            "currentPhase": "verification",
            "currentStep": "read the exact current task projection",
            "nextAction": "continue with the broker-bound workline",
            "completedSteps": [],
            "pendingSteps": ["continue"],
            "blockers": [],
            "evidenceRefs": [],
            "verificationResults": [],
            "updatedAt": "2026-08-29T00:00:00Z",
            "actionAuthorization": "withheld",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        expected = {
            "ok": True,
            "available": True,
            "snapshotHash": "d" * 64,
            "projection": projection,
        }
        with mock.patch.object(brain_mcp, "read_mcp_task_projection", return_value=expected) as reader:
            with mock.patch.object(core, "recall", side_effect=AssertionError("generic recall must not run")):
                result = brain_mcp.handle_tool(
                    core,
                    "brain_recall",
                    {"query": "当前任务", "layer": "task", "top_k": 1, "max_tokens": 120},
                    state / "workspace" / "mcp-snapshot.json",
                )
        body = _status_payload({"result": result})
        assert result["isError"] is False, result
        assert body and body[0]["sourceType"] == "task_projection", body
        reader.assert_called_once_with(
            state / "workspace" / "mcp-snapshot.json",
            workspace_key=contract["workspaceKey"],
            owner_session_key=contract["ownerSessionKey"],
        )


def test_live_write_checkpoint_refreshes_projection_before_reopen() -> None:
    """A normal live MCP checkpoint must not poison its own next open."""

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-write-continuation-") as directory:
        state = Path(directory) / "state"
        memory = state / "shared"
        project = Path(directory) / "project"
        state.mkdir()
        memory.mkdir()
        project.mkdir()
        session_key = "sid-" + "c" * 24
        task_id = "mcp-live-write-continuation"
        _write_native_memory_snapshot(state / "workspace")
        original_contract, contract_path = _write_live_contract(state, project, session_key, task_id)
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        process: subprocess.Popen[str] | None = None
        try:
            registration = control.register_workline(
                original_contract,
                expected_contract_hash=_hash(original_contract),
                project_root=project,
            )
            assert registration.get("ok") is True, registration
            workline_id = str(registration["scope"]["worklineId"])
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-B",
                    str(ROOT / "runtime" / "brain_mcp.py"),
                    "--package-root",
                    str(ROOT),
                    "--memory-root",
                    str(memory),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                env=_live_mcp_environment(),
            )
            initialized = _send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            pairing_ref = str(
                ((initialized.get("result", {}) or {}).get("liveMcpHandshake", {}) or {}).get("scope", {}).get("pairingRequestRef", "")
            )
            assert pairing_ref.startswith("sbpr-"), initialized
            paired = control.pair_request(pairing_ref, workline_id, access_mode="write")
            assert paired.get("ok") is True, paired

            opened = _status_payload(
                _send(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {"name": "brain_turn", "arguments": {"phase": "open", "turn_intent": "continuity"}},
                    },
                )
            )
            assert opened.get("available") is True and opened.get("code") == "TURN_RUNTIME_OPEN_READY", opened

            checkpoint_phase = "Fixture"
            checkpoint_step = "Persist the current live MCP checkpoint and synchronize its Broker projection."
            checkpoint_action = "Reopen the current local workline from the synchronized H7 contract."
            checkpoint = _status_payload(
                _send(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 3,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_turn",
                            "arguments": {
                                "phase": "checkpoint",
                                "turn_intent": "continuity",
                                "transition_id": "mcp-live-write-checkpoint",
                                "progress_checkpoint": {
                                    "last_confirmed_sentence": "The live MCP checkpoint committed and synchronized the local scope projection.",
                                    "source": "assistant_visible_reply",
                                    "current_phase": checkpoint_phase,
                                    "current_step": checkpoint_step,
                                    "next_action": checkpoint_action,
                                },
                                "project_progress_proof": _checkpoint_proof(
                                    project,
                                    phase=checkpoint_phase,
                                    current_step=checkpoint_step,
                                    next_action=checkpoint_action,
                                ),
                            },
                        },
                    },
                )
            )
            assert checkpoint.get("available") is True, checkpoint
            assert checkpoint.get("code") == "H7_PROGRESS_CHECKPOINT_READY", checkpoint
            assert checkpoint.get("checkpoint", {}).get("scopeRefresh", {}).get("code") == "H7_SCOPE_CONTRACT_PROJECTION_REFRESHED", checkpoint

            persisted = json.loads(contract_path.read_text(encoding="utf-8"))
            assert int(persisted["revision"]) > int(original_contract["revision"]), persisted
            workline = control.get_workline(workline_id)
            assert workline.get("ok") is True, workline
            assert int(workline.get("scope", {}).get("contractRevision", -1)) == int(persisted["revision"]), workline
            assert workline.get("scope", {}).get("contractHash") == _hash(persisted), workline

            reopened = _status_payload(
                _send(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 4,
                        "method": "tools/call",
                        "params": {"name": "brain_turn", "arguments": {"phase": "open", "turn_intent": "continuity"}},
                    },
                )
            )
            assert reopened.get("available") is True and reopened.get("code") == "TURN_RUNTIME_OPEN_READY", reopened
            restarted = _status_payload(
                _send(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 5,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_turn",
                            "arguments": {
                                "phase": "open",
                                "turn_intent": "continuity",
                                "recovery_event": "restart",
                            },
                        },
                    },
                )
            )
            assert restarted.get("available") is True and restarted.get("code") == "TURN_RUNTIME_OPEN_READY", restarted
            presentation = restarted.get("recoveryPresentation", {})
            assert presentation.get("state") == "current" and str(presentation.get("openingLine", "")).startswith("本地执行契约："), restarted
            serialized = json.dumps({"opened": opened, "checkpoint": checkpoint, "reopened": reopened, "restarted": restarted}, ensure_ascii=False)
            for private_marker in (str(project.resolve()), str(state.resolve()), "leaseId", "pairingToken", "sbpg-v1.", "sbl-"):
                assert private_marker not in serialized, serialized
        finally:
            if process is not None:
                try:
                    if process.stdin:
                        process.stdin.close()
                    process.terminate()
                    process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    process.kill()
            server.stop()
            control.close()


def test_live_mcp_rebind_allows_successor_without_retiring_contract() -> None:
    """Exercise issue -> consume -> finalize through two real MCP channels."""

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-local-rebind-") as directory:
        base = Path(directory)
        state = base / "state"
        memory = state / "shared"
        project = base / "project"
        state.mkdir(parents=True)
        memory.mkdir(parents=True)
        project.mkdir()
        task_id = "mcp-local-rebind-successor"
        task_instance_id = "ti-" + "1" * 32
        workspace_key = _workspace_key(project)
        old_session = "sid-" + "a" * 24
        successor_session = "sid-" + "b" * 24
        old_contract = _rebind_contract(project, task_id, task_instance_id, old_session, 1)
        successor_contract = _rebind_contract(project, task_id, task_instance_id, successor_session, 2)

        # Seed the authoritative intent head directly through BrainControl;
        # neither MCP process receives or reads an old execution-contract file.
        control_plane = BrainControl(state)
        instruction = "continue the governed MCP local rebind"
        resolved = control_plane.resolve_intent(
            {
                "commandId": "mcp-local-rebind-seed",
                "expectedIntentRevision": 0,
                "taskId": task_id,
                "taskInstanceId": task_instance_id,
                "workspaceKey": workspace_key,
                "ownerSessionKey": old_session,
                "packageVersion": _package_version(),
                "contractRevision": 1,
                "planFingerprint": "mcp-local-rebind-plan",
                "latestInstructionHash": hashlib.sha256(instruction.encode("utf-8")).hexdigest(),
                "intentContract": _valid_intent_contract(),
                "source": "runtime_mcp_scope_broker_integration_regression",
            }
        )
        assert resolved.get("ok") is True
        seed_receipt = resolved.get("intentResolutionReceipt")
        assert isinstance(seed_receipt, dict)

        server = ScopeBrokerServer(state)
        server.start()
        broker = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        processes: list[subprocess.Popen[str]] = []

        def stop(process: subprocess.Popen[str]) -> None:
            try:
                if process.stdin:
                    process.stdin.close()
                process.terminate()
                process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    process.kill()
                except OSError:
                    pass

        def start_bound(contract: dict[str, object]) -> subprocess.Popen[str]:
            registration = broker.register_workline(
                contract,
                expected_contract_hash=_hash(contract),
                project_root=project,
            )
            assert registration.get("ok") is True, registration
            process = subprocess.Popen(
                [sys.executable, "-B", str(ROOT / "runtime" / "brain_mcp.py"), "--package-root", str(ROOT), "--memory-root", str(memory)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                env=_live_mcp_environment(),
            )
            processes.append(process)
            initialized = _send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            handshake = initialized.get("result", {}).get("liveMcpHandshake", {})
            pairing_ref = str(handshake.get("scope", {}).get("pairingRequestRef", ""))
            assert pairing_ref.startswith("sbpr-"), initialized
            paired = broker.pair_request(pairing_ref, str(registration["scope"]["worklineId"]), access_mode="write")
            assert paired.get("ok") is True, paired
            return process

        try:
            issuer = start_bound(old_contract)
            issued = _status_payload(
                _send(
                    issuer,
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_rebind_local_session",
                            "arguments": {
                                "action": "issue",
                                "command_id": "mcp-local-rebind-issue",
                                "aggregate_kind": "intent",
                                "expected_revision": int(resolved["intentRevision"]),
                                "plan_fingerprint": "mcp-local-rebind-plan",
                            },
                        },
                    },
                )
            )
            assert issued.get("ok") is True and issued.get("status") == "issued", issued
            recovery_ref = str(issued.get("recoveryRef", ""))
            assert recovery_ref.startswith("rr-"), issued
            stop(issuer)

            successor = start_bound(successor_contract)
            wrong_kind = _status_payload(
                _send(
                    successor,
                    {
                        "jsonrpc": "2.0",
                        "id": 3,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_rebind_local_session",
                            "arguments": {
                                "action": "query",
                                "command_id": "mcp-local-rebind-wrong-kind",
                                "recovery_ref": recovery_ref,
                                "aggregate_kind": "task",
                            },
                        },
                    },
                )
            )
            assert wrong_kind.get("code") == "BRAIN_CONTROL_LOCAL_REBIND_KIND_MISMATCH", wrong_kind

            consumed = _status_payload(
                _send(
                    successor,
                    {
                        "jsonrpc": "2.0",
                        "id": 4,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_rebind_local_session",
                            "arguments": {
                                "action": "consume",
                                "command_id": "mcp-local-rebind-consume",
                                "recovery_ref": recovery_ref,
                            },
                        },
                    },
                )
            )
            assert consumed.get("ok") is True and consumed.get("status") == "consumed", consumed

            finalized = _status_payload(
                _send(
                    successor,
                    {
                        "jsonrpc": "2.0",
                        "id": 5,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_rebind_local_session",
                            "arguments": {
                                "action": "finalize",
                                "command_id": "mcp-local-rebind-finalize",
                                "recovery_ref": recovery_ref,
                            },
                        },
                    },
                )
            )
            assert finalized.get("ok") is True and finalized.get("status") == "finalized", finalized
            assert finalized.get("newOwnerSessionKey") == successor_session

            queried = _status_payload(
                _send(
                    successor,
                    {
                        "jsonrpc": "2.0",
                        "id": 6,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_rebind_local_session",
                            "arguments": {
                                "action": "query",
                                "command_id": "mcp-local-rebind-query",
                                "target_command_id": "mcp-local-rebind-issue",
                            },
                        },
                    },
                )
            )
            assert queried.get("status") == "finalized", queried
            assert queried.get("recoveryRef", "") == "" and queried.get("recoveryRefAvailable") is False, queried
        finally:
            for process in processes:
                stop(process)
            server.stop()
            broker.close()


def main() -> None:
    test_bound_task_layer_uses_the_channel_projection()
    test_live_write_checkpoint_refreshes_projection_before_reopen()
    test_live_mcp_rebind_allows_successor_without_retiring_contract()
    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-broker-") as directory:
        state = Path(directory) / "state"
        state.mkdir()
        project_a = Path(directory) / "project-a"
        project_b = Path(directory) / "project-b"
        project_a.mkdir()
        project_b.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        poisoned_binding = state / "workspace/runtime-state/mcp-runtime-binding.json"
        poisoned_binding.parent.mkdir(parents=True, exist_ok=True)
        poisoned_binding.write_text('{"poison":"deployment-adapter"}', encoding="utf-8")
        poisoned_binding_before = poisoned_binding.read_bytes()
        contracts = [_contract(project_a, "a"), _contract(project_b, "b")]
        registrations = [
            control.register_workline(contract, expected_contract_hash=_hash(contract), project_root=project)
            for contract, project in zip(contracts, (project_a, project_b))
        ]
        assert all(item.get("ok") is True for item in registrations)
        processes: list[subprocess.Popen[str]] = []
        try:
            for index, registration in enumerate(registrations):
                process = subprocess.Popen(
                    [sys.executable, "-B", str(ROOT / "runtime" / "brain_mcp.py"), "--package-root", str(ROOT), "--memory-root", str(state / "shared")],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    env=_live_mcp_environment(),
                )
                processes.append(process)
                # MCP requires a real initialize before tool discovery or
                # calls.  This guards the process-local handshake state rather
                # than a host/deployment registration marker.
                pre_init = _send(process, {"jsonrpc": "2.0", "id": 900 + index, "method": "tools/list", "params": {}})
                assert pre_init.get("error", {}).get("message") == "H7_MCP_INITIALIZE_REQUIRED", pre_init
                initialize = _send(process, {"jsonrpc": "2.0", "id": index + 1, "method": "initialize", "params": {}})
                assert initialize.get("result", {}).get("serverInfo", {}).get("name") == "super-memory-brain"
                initialize_handshake = initialize.get("result", {}).get("liveMcpHandshake", {})
                assert initialize_handshake.get("schema") == "super-brain.mcp-live-handshake.v2", initialize
                assert initialize_handshake.get("state") == "current", initialize
                assert initialize_handshake.get("code") == "H7_MCP_LOCAL_STDIO_CURRENT", initialize
                assert initialize_handshake.get("transport") == "local_scope_broker_stdio", initialize
                assert initialize_handshake.get("scope", {}).get("provider") == "scope_broker_channel", initialize
                assert initialize_handshake.get("scope", {}).get("state") == "unbound", initialize
                initialize_pairing_ref = str(initialize_handshake.get("scope", {}).get("pairingRequestRef", ""))
                assert initialize_pairing_ref.startswith("sbpr-"), initialize
                assert initialize_handshake.get("packageVersion"), initialize
                initialize_serialized = json.dumps(initialize, ensure_ascii=False)
                for secret_marker in ("leaseId", "pairingToken", "sbpg-v1.", "sbl-"):
                    assert secret_marker not in initialize_serialized, initialize
                initial_status = _status_payload(
                    _send(
                        process,
                        {"jsonrpc": "2.0", "id": 25 + index, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}},
                    )
                )
                assert initial_status.get("scopeBinding", {}).get("provider") == "scope_broker_channel", initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("schema") == "super-brain.mcp-live-handshake.v2", initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("state") == "current", initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("transport") == "local_scope_broker_stdio", initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("scope", {}).get("state") == "unbound", initial_status
                assert initial_status.get("scopeBinding", {}).get("pairingRequestRef") == initialize_pairing_ref, initial_status
                assert initial_status.get("liveMcpHandshake", {}).get("scope", {}).get("pairingRequestRef") == initialize_pairing_ref, initial_status
                assert initial_status.get("mcpRuntimeBinding", {}).get("deploymentAdapter", {}).get("state") == "not_applicable", initial_status
                assert poisoned_binding.read_bytes() == poisoned_binding_before
                assert initial_status.get("localPathsExposed") is False, initial_status
                initial_serialized = json.dumps(initial_status, ensure_ascii=False)
                assert str(ROOT.resolve()) not in initial_serialized, initial_status
                assert str(state.resolve()) not in initial_serialized, initial_status
                tools = _send(process, {"jsonrpc": "2.0", "id": 30 + index, "method": "tools/list", "params": {}})
                declared = tools.get("result", {}).get("tools", [])
                recall = next(item for item in declared if item.get("name") == "brain_recall")
                assert "task_scope" not in recall.get("inputSchema", {}).get("properties", {})

                # An unbound stdio connection cannot run even a checkpoint.
                # This proves that no request argument, cwd, or environment
                # value silently selects a workline before Broker binding.
                unbound_turn = _status_payload(
                    _send(
                        process,
                        {
                            "jsonrpc": "2.0",
                            "id": 40 + index,
                            "method": "tools/call",
                            "params": {"name": "brain_turn", "arguments": {"phase": "checkpoint"}},
                        },
                    )
                )
                assert unbound_turn.get("code") == "H7_SCOPE_CHANNEL_UNBOUND", unbound_turn
                # The MCP status projection identifies this exact connection
                # with a short-lived opaque ref.  Pair by that ref instead
                # of guessing among globally listed unbound channel IDs.
                pairing_ref = str(initial_status.get("scopeBinding", {}).get("pairingRequestRef", ""))
                assert pairing_ref.startswith("sbpr-"), initial_status
                attached = control.pair_request(
                    pairing_ref,
                    str(registration["scope"]["worklineId"]),
                    access_mode="read",
                )
                assert attached.get("ok") is True
                for secret_marker in ("leaseId", "pairingToken", "sbpg-v1.", "sbl-", "h7Scope"):
                    assert secret_marker not in json.dumps(attached, ensure_ascii=False), attached
                status = _status_payload(_send(process, {"jsonrpc": "2.0", "id": 10 + index, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}}))
                binding = status.get("scopeBinding")
                assert isinstance(binding, dict)
                assert binding.get("state") == "bound"
                assert binding.get("scope", {}).get("taskId") == contracts[index]["taskId"]
                assert binding.get("scope", {}).get("workspaceKey") == contracts[index]["workspaceKey"]
                assert status.get("liveMcpHandshake", {}).get("state") == "current", status
                assert status.get("liveMcpHandshake", {}).get("scope", {}).get("state") == "bound", status
                status_serialized = json.dumps(status, ensure_ascii=False)
                for secret_marker in ("leaseId", "pairingToken", "sbpg-v1.", "sbl-"):
                    assert secret_marker not in status_serialized, status
                assert str((project_a if index == 0 else project_b).resolve()) not in status_serialized, status

                # Raw selectors are rejected for every production Broker tool,
                # not merely ignored outside brain_recall.
                selector = _status_payload(
                    _send(
                        process,
                        {
                            "jsonrpc": "2.0",
                            "id": 70 + index,
                            "method": "tools/call",
                            "params": {
                                "name": "brain_status",
                                "arguments": {
                                    "task_scope": {
                                        "workspace_key": contracts[index]["workspaceKey"],
                                        "owner_session_key": contracts[index]["ownerSessionKey"],
                                    }
                                },
                            },
                        },
                    )
                )
                assert selector.get("code") == "H7_SCOPE_SELECTOR_FORBIDDEN", selector

                # A read attachment can inspect its own binding, but the
                # write check inside turn_runtime still blocks checkpoint
                # mutations.  This guards direct runtime callers as well as
                # the MCP adapter's friendly early read check.
                read_lease_turn = _status_payload(
                    _send(
                        process,
                        {
                            "jsonrpc": "2.0",
                            "id": 50 + index,
                            "method": "tools/call",
                            "params": {"name": "brain_turn", "arguments": {"phase": "checkpoint"}},
                        },
                    )
                )
                assert read_lease_turn.get("code") == "H7_SCOPE_WRITE_LEASE_REQUIRED", read_lease_turn

            # A fresh connection is never implicitly attached, even though
            # the durable workline registry already exists.
            fresh = subprocess.Popen(
                [sys.executable, "-B", str(ROOT / "runtime" / "brain_mcp.py"), "--package-root", str(ROOT), "--memory-root", str(state / "shared")],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                env=_live_mcp_environment(),
            )
            processes.append(fresh)
            _send(fresh, {"jsonrpc": "2.0", "id": 20, "method": "initialize", "params": {}})
            unbound_status = _status_payload(_send(fresh, {"jsonrpc": "2.0", "id": 21, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}}))
            assert unbound_status.get("scopeBinding", {}).get("state") == "unbound"
            assert unbound_status.get("scopeBinding", {}).get("code") == "H7_SCOPE_CHANNEL_UNBOUND"
            assert str(unbound_status.get("scopeBinding", {}).get("pairingRequestRef", "")).startswith("sbpr-")
            assert unbound_status.get("liveMcpHandshake", {}).get("state") == "current", unbound_status
            assert unbound_status.get("liveMcpHandshake", {}).get("scope", {}).get("state") == "unbound", unbound_status
        finally:
            for process in processes:
                try:
                    if process.stdin:
                        process.stdin.close()
                    process.terminate()
                    process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    process.kill()
            server.stop()
    print("runtime_mcp_scope_broker_integration_regression: PASS")


if __name__ == "__main__":
    main()
