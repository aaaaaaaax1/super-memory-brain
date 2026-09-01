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
from local_mcp_launcher import _worker_environment
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


def _write_live_contract(
    state_root: Path,
    project: Path,
    session_key: str,
    task_id: str,
    *,
    revision: int = 7,
    plan_fingerprint: str = "",
) -> tuple[dict[str, object], Path]:
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
    effective_plan_fingerprint = plan_fingerprint or f"mcp-live-plan-{revision}"
    contract = {
        "ok": True,
        "schema": "super-brain.execution-contract.v1",
        "taskId": task_id,
        "taskInstanceId": "ti-" + "1" * 32,
        "workspaceKey": workspace_key,
        "ownerSessionKey": session_key,
        "packageVersion": package_version,
        "status": "active",
        "revision": revision,
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
            "contractRevision": revision,
            "planFingerprint": effective_plan_fingerprint,
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
                    "revision": revision,
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


def test_local_launcher_relays_only_runtime_environment_and_explicit_sid() -> None:
    """A local embedding adapter cannot smuggle Host metadata into H7."""

    environment = _worker_environment(
        "sid-" + "a" * 24,
        source={
            "PATH": "runtime-path",
            "SystemRoot": "runtime-root",
            "CODEX_THREAD_ID": "host-thread-must-not-cross",
            "HOST_VISIBLE_CONTEXT": "host-context-must-not-cross",
            "SUPER_BRAIN_WORKSPACE_KEY": "ambient-selector-must-not-cross",
            "SUPER_BRAIN_LOCAL_SESSION_ID": "sid-" + "b" * 24,
        },
    )
    assert environment["SUPER_BRAIN_LOCAL_SESSION_ID"] == "sid-" + "a" * 24, environment
    assert environment["PATH"] == "runtime-path" and environment["SystemRoot"] == "runtime-root", environment
    for forbidden in ("CODEX_THREAD_ID", "HOST_VISIBLE_CONTEXT", "SUPER_BRAIN_WORKSPACE_KEY"):
        assert forbidden not in environment, environment


def _start_local_launcher(
    memory: Path,
    project: Path,
    *,
    session_key: str = "",
) -> subprocess.Popen[str]:
    """Start the package-owned stdio launcher as a local user adapter would."""

    environment = _live_mcp_environment()
    if session_key:
        environment["SUPER_BRAIN_LOCAL_SESSION_ID"] = session_key
    else:
        environment.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
    return subprocess.Popen(
        [
            sys.executable,
            "-B",
            str(ROOT / "runtime" / "local_mcp_launcher.py"),
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
        env=environment,
        cwd=str(project),
    )


def _stop(process: subprocess.Popen[str] | None) -> None:
    if process is None:
        return
    try:
        if process.stdin:
            process.stdin.close()
        process.wait(timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        try:
            process.terminate()
            process.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            try:
                process.kill()
            except OSError:
                pass
        except OSError:
            pass


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
            process = _start_local_launcher(memory, project, session_key=session_key)
            initialized = _send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            handshake = ((initialized.get("result", {}) or {}).get("liveMcpHandshake", {}) or {})
            assert handshake.get("scope", {}).get("state") == "bound", initialized
            assert handshake.get("scopeInjection", {}).get("code") == "H7_SCOPE_BOOTSTRAP_BOUND", initialized
            assert "sbpr-" not in json.dumps(initialized, ensure_ascii=False), initialized

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
            refreshed = control.register_workline(
                persisted,
                expected_contract_hash=_hash(persisted),
                project_root=project,
            )
            assert refreshed.get("ok") is True, refreshed
            assert int(refreshed.get("scope", {}).get("contractRevision", -1)) == int(persisted["revision"]), refreshed
            assert refreshed.get("scope", {}).get("contractHash") == _hash(persisted), refreshed

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
            _stop(process)
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
        _write_native_memory_snapshot(state / "workspace")
        old_contract, _ = _write_live_contract(
            state,
            project,
            old_session,
            task_id,
            revision=7,
            plan_fingerprint="mcp-local-rebind-plan",
        )

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
                "contractRevision": int(old_contract["revision"]),
                "planFingerprint": str(old_contract["planReceipt"]["planFingerprint"]),
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
            process = _start_local_launcher(memory, project, session_key=str(contract["ownerSessionKey"]))
            processes.append(process)
            initialized = _send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            handshake = initialized.get("result", {}).get("liveMcpHandshake", {})
            assert handshake.get("scope", {}).get("state") == "bound", initialized
            assert handshake.get("scopeInjection", {}).get("code") == "H7_SCOPE_BOOTSTRAP_BOUND", initialized
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

            successor_contract, _ = _write_live_contract(
                state,
                project,
                successor_session,
                task_id,
                revision=8,
                plan_fingerprint="mcp-local-rebind-plan",
            )
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
            # The successor binding is owned by the private Broker channel;
            # MCP egress must not return the new owner's session identity.
            assert "newOwnerSessionKey" not in finalized, finalized
            assert "ownerSessionKey" not in json.dumps(finalized, ensure_ascii=False), finalized

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


def test_injected_mcp_scope_bootstrap_pairs_the_current_local_contract_without_host_identity() -> None:
    """The local launcher injection binds before the model sees MCP output."""

    with tempfile.TemporaryDirectory(prefix="super-brain-local-scope-bootstrap-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        session_key = "sid-" + "f" * 24
        _write_native_memory_snapshot(state / "workspace")
        contract, _ = _write_live_contract(state, project, session_key, "mcp-local-bootstrap")
        server = ScopeBrokerServer(state)
        server.start()
        process: subprocess.Popen[str] | None = None
        foreign: subprocess.Popen[str] | None = None
        try:
            process = _start_local_launcher(memory, project, session_key=session_key)
            initialized = _send(process, {"jsonrpc": "2.0", "id": 101, "method": "initialize", "params": {}})
            handshake = ((initialized.get("result", {}) or {}).get("liveMcpHandshake", {}) or {})
            assert handshake.get("scope", {}).get("state") == "bound", initialized
            assert handshake.get("scope", {}).get("scopeReady") is True, initialized
            assert handshake.get("scopeInjection", {}).get("code") == "H7_SCOPE_BOOTSTRAP_BOUND", initialized
            serialized_initialize = json.dumps(initialized, ensure_ascii=False)
            for private_marker in ("sbpr-", "sid-", "sbs-", "sbw-", str(project.resolve())):
                assert private_marker not in serialized_initialize, initialized

            bound_status = _status_payload(
                _send(
                    process,
                    {"jsonrpc": "2.0", "id": 102, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}},
                )
            )
            assert bound_status.get("scopeBinding", {}).get("state") == "bound", bound_status
            assert bound_status.get("scopeBinding", {}).get("scopeAuthorized") is True, bound_status
            assert "pairingRequestRef" not in bound_status.get("scopeBinding", {}), bound_status
            assert "scope" not in bound_status.get("scopeBinding", {}), bound_status
            opened = _status_payload(
                _send(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 103,
                        "method": "tools/call",
                        "params": {"name": "brain_turn", "arguments": {"phase": "open", "turn_intent": "continuity"}},
                    },
                )
            )
            assert opened.get("available") is True and opened.get("code") == "TURN_RUNTIME_OPEN_READY", opened
            opened_serialized = json.dumps(opened, ensure_ascii=False)
            for private_marker in ("sbpr-", "sid-", "sbs-", "sbw-", str(project.resolve())):
                assert private_marker not in opened_serialized, opened

            # A different locally injected sid has no current contract. It
            # cannot seize an already-bound connection, and its failed
            # bootstrap must stay inert rather than opening an unbound
            # pairing channel.
            foreign = _start_local_launcher(memory, project, session_key="sid-" + "e" * 24)
            foreign_initialized = _send(foreign, {"jsonrpc": "2.0", "id": 104, "method": "initialize", "params": {}})
            foreign_handshake = ((foreign_initialized.get("result", {}) or {}).get("liveMcpHandshake", {}) or {})
            assert foreign_handshake.get("scope", {}).get("state") == "withheld", foreign_initialized
            assert foreign_handshake.get("scopeInjection", {}).get("state") == "withheld", foreign_initialized
            assert foreign_handshake.get("scopeInjection", {}).get("code") == "H7_SCOPE_BOOTSTRAP_CURRENT_CONTRACT_REQUIRED", foreign_initialized
            assert "sbpr-" not in json.dumps(foreign_initialized, ensure_ascii=False), foreign_initialized
            after_foreign = _status_payload(
                _send(process, {"jsonrpc": "2.0", "id": 105, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}})
            )
            assert after_foreign.get("scopeBinding", {}).get("state") == "bound", after_foreign
            assert after_foreign.get("scopeBinding", {}).get("scopeAuthorized") is True, after_foreign
        finally:
            for item in (foreign, process):
                _stop(item)
            server.stop()


def test_first_local_launcher_starts_and_binds_its_own_broker() -> None:
    """A real local adapter must not depend on a pre-started Broker process."""

    with tempfile.TemporaryDirectory(prefix="super-brain-local-first-launch-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        session_key = "sid-" + "d" * 24
        _write_native_memory_snapshot(state / "workspace")
        _write_live_contract(state, project, session_key, "mcp-local-first-launch")
        process: subprocess.Popen[str] | None = None
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        try:
            # No ``ScopeBrokerServer`` is started here.  The launcher must
            # establish the resident local endpoint before its atomic bind.
            process = _start_local_launcher(memory, project, session_key=session_key)
            initialized = _send(process, {"jsonrpc": "2.0", "id": 201, "method": "initialize", "params": {}})
            handshake = ((initialized.get("result", {}) or {}).get("liveMcpHandshake", {}) or {})
            assert handshake.get("scope", {}).get("state") == "bound", initialized
            assert handshake.get("scopeInjection", {}).get("code") == "H7_SCOPE_BOOTSTRAP_BOUND", initialized
            status = _status_payload(
                _send(
                    process,
                    {"jsonrpc": "2.0", "id": 202, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}},
                )
            )
            assert status.get("scopeBinding", {}).get("scopeAuthorized") is True, status
            serialized = json.dumps({"initialize": initialized, "status": status}, ensure_ascii=False)
            for private_marker in ("sbpr-", "sid-", "sbs-", "sbw-", str(project.resolve())):
                assert private_marker not in serialized, serialized
        finally:
            _stop(process)
            try:
                control.shutdown_if_idle()
            except Exception:
                pass
            control.close()


def test_injected_launcher_requires_process_restart_after_broker_restart() -> None:
    """A restarted Broker cannot silently regain an injected user scope."""

    with tempfile.TemporaryDirectory(prefix="super-brain-local-launcher-restart-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        session_key = "sid-" + "9" * 24
        _write_native_memory_snapshot(state / "workspace")
        _write_live_contract(state, project, session_key, "mcp-local-launcher-restart")
        server = ScopeBrokerServer(state)
        replacement: ScopeBrokerServer | None = None
        process: subprocess.Popen[str] | None = None
        server.start()
        try:
            process = _start_local_launcher(memory, project, session_key=session_key)
            initialized = _send(process, {"jsonrpc": "2.0", "id": 301, "method": "initialize", "params": {}})
            assert ((initialized.get("result", {}) or {}).get("liveMcpHandshake", {}) or {}).get("scope", {}).get("state") == "bound", initialized

            server.stop()
            replacement = ScopeBrokerServer(state)
            replacement.start()

            status = _status_payload(
                _send(
                    process,
                    {"jsonrpc": "2.0", "id": 302, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}},
                )
            )
            handshake = status.get("liveMcpHandshake", {})
            assert handshake.get("code") == "H7_SCOPE_LAUNCH_RESTART_REQUIRED", status
            assert handshake.get("scope", {}).get("scopeReady") is False, status
            assert handshake.get("scopeInjection", {}).get("scopeAuthorized") is False, status

            turn = _status_payload(
                _send(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 303,
                        "method": "tools/call",
                        "params": {"name": "brain_turn", "arguments": {"phase": "open", "turn_intent": "continuity"}},
                    },
                )
            )
            assert turn.get("code") == "H7_SCOPE_LAUNCH_RESTART_REQUIRED", turn
            assert turn.get("available") is False, turn
            serialized = json.dumps({"status": status, "turn": turn}, ensure_ascii=False)
            for private_marker in ("sbpr-", "sid-", "sbs-", "sbw-", str(project.resolve())):
                assert private_marker not in serialized, serialized
        finally:
            _stop(process)
            if replacement is not None:
                replacement.stop()
            else:
                server.stop()


def test_registered_launcher_without_local_injection_is_inert_discovery_only() -> None:
    """The installed static launcher never leaves an unbound pairing channel.

    A generic MCP registration cannot invent per-user scope facts.  It may
    start the package launcher for discovery/status, but without the local
    embedding adapter's actual cwd plus random session id it must remain
    explicitly withheld and create no Broker channel at all.
    """

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-static-launcher-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        process: subprocess.Popen[str] | None = None
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        try:
            # This is the exact installed launcher command, without an
            # embedding adapter injecting the current session id.
            process = _start_local_launcher(memory, project)
            initialized = _send(process, {"jsonrpc": "2.0", "id": 401, "method": "initialize", "params": {}})
            handshake = ((initialized.get("result", {}) or {}).get("liveMcpHandshake", {}) or {})
            assert handshake.get("state") == "withheld", initialized
            assert handshake.get("code") == "H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED", initialized
            assert handshake.get("scope", {}).get("state") == "withheld", initialized
            assert handshake.get("scope", {}).get("scopeReady") is False, initialized
            assert handshake.get("scopeInjection", {}).get("requested") is True, initialized
            assert handshake.get("scopeInjection", {}).get("code") == "H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED", initialized

            status = _status_payload(
                _send(
                    process,
                    {"jsonrpc": "2.0", "id": 402, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}},
                )
            )
            assert status.get("scopeBinding", {}).get("state") == "withheld", status
            assert status.get("scopeBinding", {}).get("code") == "H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED", status
            turn = _status_payload(
                _send(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 403,
                        "method": "tools/call",
                        "params": {"name": "brain_turn", "arguments": {"phase": "open", "turn_intent": "continuity"}},
                    },
                )
            )
            assert turn.get("available") is False, turn
            assert turn.get("code") == "H7_SCOPE_INJECTION_LOCAL_SESSION_REQUIRED", turn
            # The static discovery worker must not have opened a channel or
            # caused the Broker to issue a private pairing reference.
            listed = control.list_channels()
            assert listed.get("ok") is True and listed.get("channels") == [], listed
            serialized = json.dumps({"initialize": initialized, "status": status, "turn": turn, "listed": listed}, ensure_ascii=False)
            for private_marker in ("sbpr-", "sid-", "sbs-", "sbw-", str(project.resolve())):
                assert private_marker not in serialized, serialized
        finally:
            _stop(process)
            control.close()
            server.stop()


def main() -> None:
    test_bound_task_layer_uses_the_channel_projection()
    test_live_write_checkpoint_refreshes_projection_before_reopen()
    test_live_mcp_rebind_allows_successor_without_retiring_contract()
    test_injected_mcp_scope_bootstrap_pairs_the_current_local_contract_without_host_identity()
    test_first_local_launcher_starts_and_binds_its_own_broker()
    test_injected_launcher_requires_process_restart_after_broker_restart()
    test_registered_launcher_without_local_injection_is_inert_discovery_only()
    test_static_mcp_remains_unbound_and_pairing_controls_are_retired()
    print("runtime_mcp_scope_broker_integration_regression: PASS")


def test_static_mcp_remains_unbound_and_pairing_controls_are_retired() -> None:
    """A static registration is healthy transport, but has no user scope."""

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-static-") as directory:
        root = Path(directory)
        state = root / "state"
        memory = state / "shared"
        project = root / "project"
        memory.mkdir(parents=True)
        project.mkdir()
        server = ScopeBrokerServer(state)
        server.start()
        process: subprocess.Popen[str] | None = None
        control = ScopeBrokerControlClient(state, auto_start=False, runtime_path=ROOT / "runtime" / "scope_broker_ipc.py")
        try:
            process = subprocess.Popen(
                [sys.executable, "-B", str(ROOT / "runtime" / "brain_mcp.py"), "--package-root", str(ROOT), "--memory-root", str(memory)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                env=_live_mcp_environment(),
                cwd=str(project),
            )
            initialized = _send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
            handshake = initialized["result"]["liveMcpHandshake"]
            assert handshake["scope"]["state"] == "unbound", initialized
            assert handshake["scopeInjection"]["requested"] is False, initialized
            assert "pairingRequestRef" not in json.dumps(initialized, ensure_ascii=False), initialized
            status = _status_payload(_send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "brain_status", "arguments": {}}}))
            assert status["scopeBinding"]["state"] == "unbound", status
            assert status["scopeBinding"]["scopeAuthorized"] is False, status
            assert "scope" not in status["scopeBinding"], status
            turn = _status_payload(_send(process, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "brain_turn", "arguments": {"phase": "checkpoint"}}}))
            assert turn["code"] == "H7_SCOPE_CHANNEL_UNBOUND", turn
            retired = control.pair_channel("sbc-" + "a" * 32, "sbw-" + "b" * 32)
            assert retired.get("code") == "H7_SCOPE_PAIRING_CONTROL_RETIRED", retired
        finally:
            _stop(process)
            control.close()
            server.stop()


if __name__ == "__main__":
    main()
