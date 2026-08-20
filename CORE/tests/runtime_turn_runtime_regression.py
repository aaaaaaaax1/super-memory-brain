from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from brain_context import canonical_hash, project_progress_root_hash, scope_ref, visible_progress_scope_binding_hash
from brain_core import BrainCore
from mcp_runtime_identity import runtime_dependency_paths
from run_observability import receipt_is_valid as run_observability_receipt_is_valid
from turn_runtime import MODE, RECEIPT_SCHEMA, TELEMETRY_SCHEMA, run_turn
import turn_close_dispatcher as turn_close_dispatcher
import turn_runtime as turn_runtime


def recovery_progress_line(task: dict[str, object]) -> str:
    """The local recovery UI presents contract state without a transport tail."""

    phase = str(task.get("currentPhase", ""))
    step = str(task.get("currentStep", ""))
    action = str(task.get("nextAction", ""))
    return f"本地执行契约：进度：{phase}｜当前：{step}｜下一步：{action}"


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def package_version() -> str:
    return str(json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["version"])


def workspace_key_for(path: Path) -> str:
    source = os.path.abspath(str(path)).rstrip("/\\").lower()
    return "ws-" + hashlib.sha256(source.encode("utf-8")).hexdigest()[:24]


def contract_file_name(task_id: str, workspace_key: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", task_id).strip("-").lower() or "task"
    safe = safe[:36].rstrip("-")
    task_hash = hashlib.sha256(task_id.encode("utf-8")).hexdigest()[:16]
    return f"{safe}-{task_hash}--{workspace_key}.json"


def now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def project_progress_proof(
    project_root: Path,
    *,
    phase: str,
    current_step: str,
    next_action: str,
    completed_items: list[dict[str, object]] | None = None,
    project_evidence: list[dict[str, str]] | None = None,
    verification_results: list[dict[str, str]] | None = None,
) -> dict[str, object]:
    body: dict[str, object] = {
        "schema": "super-brain.project-progress-proof.v1",
        "state": "current",
        "phase": phase,
        "currentStep": current_step,
        "completedItems": completed_items or [],
        "projectEvidence": project_evidence or [],
        "verificationResults": verification_results or [],
        "nextAction": next_action,
        "missing": [],
        "projectRootHash": project_progress_root_hash(project_root),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def visible_progress_receipt(
    *,
    sentence: str,
    source: str,
    phase: str,
    current_step: str,
    next_action: str,
    project_proof: dict[str, object],
    scope_binding_hash: str,
    transition_id: str = "fixture-visible-progress",
) -> dict[str, object]:
    body: dict[str, object] = {
        "schema": "super-brain.visible-progress-receipt.v1",
        "source": source,
        "sentenceHash": hashlib.sha256(sentence.encode("utf-8")).hexdigest(),
        "currentPhase": phase,
        "currentStep": current_step,
        "nextAction": next_action,
        "projectProgressPayloadHash": str(project_proof["payloadHash"]),
        "scopeBindingHash": scope_binding_hash,
        "transitionId": transition_id,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def native_capability_route_receipt(*, state: str = "ready") -> dict[str, object]:
    """Create the compact router-to-H7 proof; no upstream path/body is present."""

    selected_count = 1 if state == "ready" else 0
    shadow_state = "withheld" if selected_count else "not_applicable"
    shadow_body = {
        "schema": "super-brain.capability-shadow-gate.v1",
        "state": shadow_state,
        "code": (
            "H7_CAPABILITY_ACTIVATION_SHADOW_WITHHELD"
            if selected_count
            else "H7_CAPABILITY_SHADOW_NOT_APPLICABLE"
        ),
        "evaluationPayloadHash": "",
        "selectedContractCount": selected_count,
        "activationAllowed": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    shadow_gate = {**shadow_body, "payloadHash": canonical_hash(shadow_body)}
    external_state = "withheld" if selected_count else "not_applicable"
    code = (
        "CAPABILITY_ROUTE_EVALUATION_WITHHELD"
        if selected_count
        else "CAPABILITY_ROUTE_NOT_APPLICABLE"
    )
    route_input = {
        "schema": "super-brain.capability-route-receipt.v1",
        "state": external_state,
        "code": code,
        # External routes cannot claim a native shadow evaluation. H7 derives
        # the actual selected native procedure and current gate itself.
        "selectedNativeCapabilityIds": [],
        "nativeContractIds": [],
        "provenanceHashes": [],
        "parityHashes": [],
        "routeHash": canonical_hash(
            {
                "routerFixture": "native-capability-route",
                "state": external_state,
                "shadowGate": shadow_gate,
            }
        ),
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
        "shadowGate": shadow_gate,
    }
    return route_input


def native_execution_assist_request(
    *,
    signals: list[str] | None = None,
    clarification_required: bool = False,
    shared_unknown: bool = False,
) -> dict[str, object]:
    """Compact semantic input only; user text and paths are intentionally absent."""

    return {
        "schema": "super-brain.execution-assist-request.v1",
        "taskClass": "engineering",
        "semanticSignals": signals or ["challenge_assumptions", "implementation"],
        "materialUnknown": clarification_required,
        "clarificationRequired": clarification_required,
        "sharedUnknown": shared_unknown,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def write_native_memory_snapshot(workspace: Path) -> None:
    body = {
        "schema": "super-brain.native-memory-influence-snapshot.v1",
        "generatedAt": now(),
        "entryCount": 1,
        "entries": [
            {
                "kind": "preference",
                "bucket": "behaviorGuidance",
                "scopeKind": "global",
                "scopeRef": scope_ref("user"),
                "item": {
                    "cardId": "card-turn-runtime-preference",
                    "cardRevision": 3,
                    "title": "Keep turn runtime scoped",
                    "effect": "shape_behavior",
                    "statement": "Use the current execution contract and retain no raw prompt.",
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
    write_json(workspace / "native-memory-influence-snapshot.json", {**body, "payloadHash": canonical_hash(body)})


def write_context_contract(state_root: Path, project_root: Path, session_key: str, task_id: str = "task-turn-runtime") -> None:
    workspace = state_root / "workspace"
    workspace_key = workspace_key_for(project_root)
    timestamp = now()
    contract_name = contract_file_name(task_id, workspace_key)
    evidence_path = project_root / "project-progress-evidence.txt"
    evidence_path.write_text("project progress proof fixture\n", encoding="utf-8")
    evidence = {"kind": "project_file", "relativePath": evidence_path.name, "sha256": file_sha256(evidence_path)}
    sentence = "R0 is verified; return to the source-evidence parent workline."
    phase = "Fixture"
    current_step = "Open the governed turn."
    next_action = "Run the local runtime verification."
    proof = project_progress_proof(
        project_root,
        phase=phase,
        current_step=current_step,
        next_action=next_action,
        project_evidence=[evidence],
    )
    contract = {
        "ok": True,
        "schema": "super-brain.execution-contract.v1",
        "taskId": task_id,
        "taskInstanceId": "ti-" + "1" * 32,
        "workspaceKey": workspace_key,
        "ownerSessionKey": session_key,
        "packageVersion": package_version(),
        "status": "active",
        "revision": 7,
        "focusId": "hookless-runtime",
        "focusLabel": "Hookless runtime fixture",
        "lastConfirmedSentence": sentence,
        "lastConfirmedSource": "assistant_visible_reply",
        "currentPhase": phase,
        "currentStep": current_step,
        "nextAction": next_action,
        "returnStack": [],
        "blockers": [],
        "needsReconciliation": False,
        "planReceiptRequired": True,
        "planReceipt": {"focusId": "hookless-runtime", "contractRevision": 7, "planFingerprint": "fixture-plan-7"},
        "instructionAnchor": {"contentHash": "a" * 64},
        "recoveryCheckpoint": {"checkpointId": "checkpoint-fixture", "stateHash": "b" * 64},
        "projectProgressProof": proof,
        "visibleProgressReceipt": visible_progress_receipt(
            sentence=sentence,
            source="assistant_visible_reply",
            phase=phase,
            current_step=current_step,
            next_action=next_action,
            project_proof=proof,
            scope_binding_hash=visible_progress_scope_binding_hash(
                task_id=task_id,
                task_instance_id="ti-" + "1" * 32,
                workspace_key=workspace_key,
                owner_session_key=session_key,
                package_version=package_version(),
            ),
        ),
        "updatedAt": timestamp,
    }
    write_json(
        workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
        {
            "schema": "super-brain.execution-hot-index.v1",
            "packageVersion": package_version(),
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "entries": [
                {
                    "taskId": task_id,
                    "workspaceKey": workspace_key,
                    "ownerSessionKey": session_key,
                    "packageVersion": package_version(),
                    "revision": 7,
                    "status": "active",
                    "updatedAt": timestamp,
                    "contractFileName": contract_name,
                }
            ],
        },
    )
    write_json(workspace / "runtime-state" / "execution-contracts" / contract_name, contract)


def invoke_contract(arguments: list[str]) -> dict[str, object]:
    completed = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "scripts" / "execution-contract.ps1"), *arguments],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(completed.stderr or completed.stdout)
    value = json.loads(completed.stdout)
    assert value.get("ok") is True, value
    return value


def local_scope(project_root: Path, session_key: str):
    class Scope:
        def __enter__(self):
            self.previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
            self.previous_cwd = Path.cwd()
            os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = session_key
            os.chdir(project_root)

        def __exit__(self, *_: object) -> None:
            os.chdir(self.previous_cwd)
            if self.previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = self.previous_thread

    return Scope()


def test_open_is_idempotent_and_binds_typed_memory() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-open-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "2" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key)
        core = BrainCore(ROOT, memory_root)

        with local_scope(project_root, session_key):
            first = run_turn(core, phase="open", turn_intent="design_evaluate")
            second = run_turn(core, phase="open", turn_intent="design_evaluate")
            evidence = run_turn(core, phase="evidence")

        assert first["ok"] is True
        assert first["mode"] == MODE
        assert first["available"] is True
        assert first["context"]["task"]["lastConfirmedSentence"] == "R0 is verified; return to the source-evidence parent workline."
        assert first["context"]["task"]["lastConfirmedSource"] == "assistant_visible_reply"
        assert first["runtimeReceipt"]["memory"]["refs"] == ["card-turn-runtime-preference@3"]
        assert "coreRules" not in first["context"]["typedMemory"]
        applicable_rules = first["context"]["coreRules"]["applicableRuleIds"]
        assert applicable_rules == [
            "SB-PROJECT-GROUNDED-DESIGN-001",
            "SB-ABILITY-ABSORPTION-001",
            "SB-FOUR-QUADRANT-EXECUTION-001",
            "SB-PROGRESS-TRUTH-001",
            "SB-PROPOSAL-GATE-001",
            "SB-INDEPENDENT-CONTROL-PLANE-AGENT-001",
            "SB-ON-DEMAND-PROJECT-KNOWLEDGE-001",
        ]
        assert first["runtimeReceipt"]["memory"]["snapshotPayloadHash"]
        assert first["runtimeReceipt"]["activation"]["receiptHash"]
        assert first["context"]["projectKnowledge"]["state"] == "ready", first
        assert first["context"]["projectKnowledge"]["coverage"] == "proof_bound_slice", first
        assert first["context"]["projectKnowledge"]["fullTreeScan"] is False, first
        assert first["runtimeReceipt"]["projectKnowledge"]["payloadHash"] == first["context"]["projectKnowledge"]["payloadHash"], first
        assert evidence["projectKnowledge"]["payloadHash"] == first["context"]["projectKnowledge"]["payloadHash"], evidence
        assert first["context"]["agentIdentity"]["kind"] == "independent_control_plane_agent"
        assert first["context"]["authorityModel"]["objectiveAuthority"] == "latest_user_instruction"
        assert first["context"]["authorityModel"]["executionAuthority"] == "h7_scope_bound_execution_contract"
        assert first["context"]["authorityModel"]["progressAuthority"] == "assistant_visible_reply_plus_current_project_progress_proof"
        assert first["context"]["authorityModel"]["supplementalOnly"] == [
            "typed_memory", "absorbed_capabilities", "bounded_collaborator_agents"
        ]
        assert first["runtimeReceipt"]["agentIdentity"] == first["context"]["agentIdentity"]
        assert first["runtimeReceipt"]["authorityModel"] == first["context"]["authorityModel"]
        execution_assist = first["runtimeReceipt"]["executionAssist"]
        selection = first["runtimeReceipt"]["capabilityRouteReceipt"]
        assert execution_assist["state"] == "ready", execution_assist
        assert execution_assist["automatic"] is True and execution_assist["nonAuthorizing"] is True, execution_assist
        assert selection["state"] == "ready", selection
        assert selection["selectedNativeCapabilityIds"], selection
        assert first["runtimeReceipt"]["coreRules"]["applicableRuleIds"] == applicable_rules
        progress_truth = first["runtimeReceipt"]["progressTruth"]
        assert progress_truth["state"] == "current"
        assert progress_truth["payloadHash"]
        assert progress_truth["missing"] == []
        assert progress_truth["completedCount"] == 0
        assert progress_truth["evidenceCount"] == 1
        assert progress_truth["verificationState"] == "not_required"
        assert progress_truth["projectEvidenceRequired"] is True
        assert progress_truth["canClaimProjectProgress"] is True
        assert progress_truth["canClaimVerifiedCompletion"] is False
        assert progress_truth["rawPromptStored"] is False
        assert progress_truth["rawTranscriptStored"] is False
        assert first["runtimeReceipt"]["coreRules"]["payloadHash"]
        assert second["receiptReused"] is True
        assert evidence["code"] == "H7_EVIDENCE_CURRENT"
        assert evidence["entry"]["current"] is True
        assert evidence["telemetry"]["current"] is True
        assert evidence["memoryInjection"]["refs"] == ["card-turn-runtime-preference@3"]
        assert core.core_rules(("greeting",))["applicableRuleIds"] == []
        scope_ref_value = first["context"]["scope"]["scopeRef"]
        receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "open.json"
        telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        assert receipt["schema"] == RECEIPT_SCHEMA
        assert telemetry["schema"] == TELEMETRY_SCHEMA
        assert len(telemetry["events"]) == 1
        run_observability = telemetry["runObservability"]
        assert run_observability_receipt_is_valid(run_observability, expected_scope_ref=scope_ref_value), run_observability
        assert run_observability["measuredSampleCount"] == 1, run_observability
        assert run_observability["budget"]["state"] == "within_budget", run_observability
        assert first["runObservability"] == run_observability, first
        assert evidence["runObservability"] == run_observability, evidence
        serialized = json.dumps({"receipt": receipt, "telemetry": telemetry}, ensure_ascii=False)
        assert "rawPromptStored\":true" not in serialized
        assert "rawTranscriptStored\":true" not in serialized


def test_memory_write_projects_exact_contract_authorization_and_fails_closed() -> None:
    """A material write follows Resolve; generic context remains non-authorizing."""

    with tempfile.TemporaryDirectory(prefix="super-brain-memory-write-auth-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "d" * 24
        task_id = "task-memory-write-authorization"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id=task_id)
        workspace_key = workspace_key_for(project_root)
        core = BrainCore(ROOT, memory_root)
        original = turn_runtime._invoke_contract

        def resolve_allowed(*_args: object, action: str, **_kwargs: object) -> tuple[int, dict[str, object] | None]:
            assert action == "Resolve"
            return 0, {
                "ok": True,
                "resolutionSource": "execution_contract",
                "actionAuthorization": "allowed",
                "claimAllowed": True,
                "needsConfirmation": False,
                "taskId": task_id,
                "taskInstanceId": "ti-" + "1" * 32,
                "workspaceKey": workspace_key,
                "contractRevision": 7,
                "planFingerprint": "fixture-plan-7",
            }

        turn_runtime._invoke_contract = resolve_allowed
        try:
            with local_scope(project_root, session_key):
                allowed = run_turn(core, phase="open", turn_intent="memory_write")
        finally:
            turn_runtime._invoke_contract = original

        assert allowed["available"] is True, allowed
        assert allowed["activation"]["actionAuthorization"] == "allowed", allowed
        assert allowed["context"]["task"]["actionAuthorization"] == "allowed", allowed
        authorization = allowed["context"]["contractAuthorization"]
        assert authorization["state"] == "allowed" and authorization["source"] == "execution_contract", authorization
        assert authorization["resolutionHash"], authorization

        def resolve_withheld(*_args: object, action: str, **_kwargs: object) -> tuple[int, dict[str, object] | None]:
            assert action == "Resolve"
            return 0, {
                "ok": True,
                "resolutionSource": "execution_contract",
                "actionAuthorization": "withheld",
                "claimAllowed": False,
                "needsConfirmation": True,
                "taskId": task_id,
                "taskInstanceId": "ti-" + "1" * 32,
                "workspaceKey": workspace_key,
                "contractRevision": 7,
                "planFingerprint": "fixture-plan-7",
            }

        turn_runtime._invoke_contract = resolve_withheld
        try:
            with local_scope(project_root, session_key):
                withheld = run_turn(core, phase="open", turn_intent="memory_write")
        finally:
            turn_runtime._invoke_contract = original

        assert withheld["available"] is False, withheld
        assert withheld["code"] == "H7_ACTION_AUTHORIZATION_WITHHELD", withheld
        assert withheld["context"]["contractAuthorization"]["state"] == "withheld", withheld


def test_native_capability_route_receipt_is_h7_bound_without_authorization() -> None:
    """Legacy router input is retained only as compatibility evidence."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-capability-route-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "c" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-native-capability-route")
        core = BrainCore(ROOT, memory_root)
        route_receipt = native_capability_route_receipt()

        with local_scope(project_root, session_key):
            opened = run_turn(
                core,
                phase="open",
                turn_intent="design_evaluate",
                capability_route_receipt=route_receipt,
            )
            evidence = run_turn(core, phase="evidence")

        assert opened["available"] is True, opened
        selection = opened["runtimeReceipt"]["capabilityRouteReceipt"]
        assert selection["state"] == "ready", selection
        assert "sb.native.mattpocock.codebase-design.v1" in selection["selectedNativeCapabilityIds"], selection
        assert selection["routeHash"] != route_receipt["routeHash"], selection
        assert selection["nonAuthorizing"] is True, selection
        assert "actionAuthorization" not in selection, selection
        compatibility = opened["runtimeReceipt"]["capabilityRouteCompatibility"]
        assert compatibility["state"] == "accepted_compatibility_only", compatibility
        assert compatibility["externalRouteHash"] == route_receipt["routeHash"], compatibility
        assert compatibility["cannotSelectCapabilities"] is True, compatibility
        assert opened["runtimeReceipt"]["activation"]["actionAuthorization"] == "withheld", opened
        assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
        assert evidence["capabilityRouteReceipt"] == selection, evidence

        scope_ref_value = opened["context"]["scope"]["scopeRef"]
        receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "open.json"
        telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        assert receipt["capabilityRouteReceipt"] == selection, receipt
        assert receipt["capabilityRouteCompatibility"] == compatibility, receipt
        latest = telemetry["events"][-1]
        assert latest["capabilityRouteHash"] == selection["routeHash"], latest
        assert latest["capabilitySelectionHash"] == selection["selectionHash"], latest
        assert latest["capabilityRouteNonAuthorizing"] is True, latest
        assert latest["capabilityRouteCompatibilityHash"] == compatibility["payloadHash"], latest
        assert latest["capabilityRouteCompatibilityOnly"] is True, latest
        serialized = json.dumps({"receipt": receipt, "telemetry": telemetry}, ensure_ascii=False)
        assert '"sourcePath":' not in serialized
        assert '"upstreamPath":' not in serialized
        assert "rawPromptStored\":true" not in serialized
        assert "rawTranscriptStored\":true" not in serialized


def test_h7_accepts_the_actual_compact_router_receipt() -> None:
    """Keep the router/H7 boundary exact as native parity receipts evolve."""

    with tempfile.TemporaryDirectory(prefix="super-brain-router-to-h7-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        router_query = "设计产品需求，并对关键假设做严格挑战。"
        routed = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / "scripts" / "intent-router.ps1"),
                "-Text",
                router_query,
                "-Workspace",
                str(project_root),
                "-Json",
            ],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
        )
        assert routed.returncode == 0, routed.stderr or routed.stdout
        route_receipt = json.loads(routed.stdout)["capabilityRouteReceipt"]
        assert set(route_receipt) == {
            "schema", "state", "code", "selectedNativeCapabilityIds", "nativeContractIds",
            "provenanceHashes", "parityHashes", "routeHash", "nonAuthorizing", "rawPromptStored",
            "rawTranscriptStored", "sourcePathsOmitted", "shadowGate",
        }, route_receipt
        assert route_receipt["state"] == "withheld", route_receipt
        assert route_receipt["code"] == "CAPABILITY_ROUTE_EVALUATION_WITHHELD", route_receipt
        assert route_receipt["selectedNativeCapabilityIds"] == [], route_receipt
        assert route_receipt["nativeContractIds"] == [], route_receipt
        assert route_receipt["shadowGate"]["state"] == "withheld", route_receipt
        assert route_receipt["shadowGate"]["activationAllowed"] is False, route_receipt
        assert route_receipt["shadowGate"]["payloadHash"] == canonical_hash(
            {key: value for key, value in route_receipt["shadowGate"].items() if key != "payloadHash"}
        ), route_receipt

        session_key = "sid-" + "f" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-router-to-h7")
        core = BrainCore(ROOT, memory_root)
        with local_scope(project_root, session_key):
            opened = run_turn(
                core,
                phase="open",
                turn_intent="design_evaluate",
                capability_route_receipt=route_receipt,
            )
            evidence = run_turn(core, phase="evidence")

        assert opened["available"] is True, opened
        selection = opened["runtimeReceipt"]["capabilityRouteReceipt"]
        compatibility = opened["runtimeReceipt"]["capabilityRouteCompatibility"]
        assert selection["routeHash"] != route_receipt["routeHash"], selection
        assert compatibility["externalRouteHash"] == route_receipt["routeHash"], compatibility
        assert compatibility["externalSelectionHash"] == canonical_hash(route_receipt), compatibility
        assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
        serialized = json.dumps({"selection": selection, "evidence": evidence}, ensure_ascii=False)
        assert router_query not in serialized
        assert str(project_root) not in serialized
        assert '"sourcePath":' not in serialized


def test_capability_route_receipt_rejects_paths_prompts_and_authorization() -> None:
    """The H7 boundary rejects fields that could smuggle a source or authority."""

    forbidden = {
        "sourcePath": "C:\\not-a-capability-source",
        "rawPrompt": "do not persist this",
        "rawTranscript": "do not persist this either",
        "actionAuthorization": "allowed",
    }
    for field, value in forbidden.items():
        with tempfile.TemporaryDirectory(prefix="super-brain-capability-route-reject-") as directory:
            state_root = Path(directory) / "state"
            memory_root = state_root / "shared"
            project_root = Path(directory) / "project"
            memory_root.mkdir(parents=True)
            project_root.mkdir()
            (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
            session_key = "sid-" + "d" * 24
            write_native_memory_snapshot(state_root / "workspace")
            write_context_contract(state_root, project_root, session_key, task_id=f"task-capability-route-{field.lower()}")
            route_receipt = native_capability_route_receipt()
            route_receipt[field] = value
            core = BrainCore(ROOT, memory_root)
            with local_scope(project_root, session_key):
                result = run_turn(
                    core,
                    phase="open",
                    turn_intent="design_evaluate",
                    capability_route_receipt=route_receipt,
                )
            assert result["available"] is False, result
            assert result["code"] == "H7_CAPABILITY_ROUTE_RECEIPT_FIELDS_INVALID", result
            assert not (state_root / "workspace" / "runtime-state" / "turn-runtime").exists(), result


def test_direct_execution_assist_is_h7_native_and_private() -> None:
    """A compact semantic request activates one H7-owned native procedure."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-execution-assist-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "9" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-native-execution-assist")
        core = BrainCore(ROOT, memory_root)

        with local_scope(project_root, session_key):
            opened = run_turn(
                core,
                phase="open",
                turn_intent="direct",
                execution_assist_request=native_execution_assist_request(),
            )
            evidence = run_turn(core, phase="evidence")

        assert opened["available"] is True, opened
        assist = opened["runtimeReceipt"]["executionAssist"]
        route = opened["runtimeReceipt"]["capabilityRouteReceipt"]
        assert assist["state"] == "ready", assist
        assert assist["selectedNativeCapabilityIds"] == ["sb.native.mattpocock.grill-me.v1"], assist
        assert assist["capabilityApplyPhase"] == "planning", assist
        assert assist["activeNativeCapabilityIds"] == ["sb.native.mattpocock.grill-me.v1"], assist
        assert assist["deferredNativeCapabilityIds"] == [], assist
        assert assist["automatic"] is True and assist["nonAuthorizing"] is True, assist
        assert route["selectedNativeCapabilityIds"] == assist["selectedNativeCapabilityIds"], route
        assert "SB-FOUR-QUADRANT-EXECUTION-001" in opened["context"]["coreRules"]["applicableRuleIds"], opened
        assert "SB-ABILITY-ABSORPTION-001" in opened["context"]["coreRules"]["applicableRuleIds"], opened
        assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
        assert evidence["executionAssist"] == assist, evidence
        serialized = json.dumps({"opened": opened, "evidence": evidence}, ensure_ascii=False)
        assert '"sourcePath"' not in serialized and '"rawPrompt"' not in serialized
        assert '"rawTranscript"' not in serialized and str(project_root) not in serialized


def test_execution_assist_request_rejects_raw_fields_without_runtime_write() -> None:
    """H7 rejects accidental prompt/path transport before creating a receipt."""

    for field, value in {
        "rawPrompt": "must never reach H7",
        "rawTranscript": "must never reach H7",
        "sourcePath": "C:\\private\\source",
        "query": "must never reach H7",
    }.items():
        with tempfile.TemporaryDirectory(prefix="super-brain-execution-assist-reject-") as directory:
            state_root = Path(directory) / "state"
            memory_root = state_root / "shared"
            project_root = Path(directory) / "project"
            memory_root.mkdir(parents=True)
            project_root.mkdir()
            (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
            session_key = "sid-" + "a" * 24
            write_native_memory_snapshot(state_root / "workspace")
            write_context_contract(state_root, project_root, session_key, task_id=f"task-execution-assist-{field.lower()}")
            request = native_execution_assist_request()
            request[field] = value
            core = BrainCore(ROOT, memory_root)
            with local_scope(project_root, session_key):
                result = run_turn(
                    core,
                    phase="open",
                    turn_intent="direct",
                    execution_assist_request=request,
                )
            assert result["available"] is False, result
            assert result["code"] == "H7_EXECUTION_ASSIST_REQUEST_FIELDS_INVALID", result
            assert not (state_root / "workspace" / "runtime-state" / "turn-runtime").exists(), result


def test_capability_route_hash_mismatch_withholds_h7_evidence() -> None:
    """Receipt and telemetry must agree on the H7-computed selection hash."""

    with tempfile.TemporaryDirectory(prefix="super-brain-capability-route-mismatch-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "e" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-capability-route-mismatch")
        core = BrainCore(ROOT, memory_root)
        route_receipt = native_capability_route_receipt()

        with local_scope(project_root, session_key):
            opened = run_turn(core, phase="open", turn_intent="design_evaluate", capability_route_receipt=route_receipt)
        scope_ref_value = opened["context"]["scope"]["scopeRef"]
        receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "open.json"
        telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        pristine_telemetry = json.loads(json.dumps(telemetry))
        telemetry["events"][-1]["capabilitySelectionHash"] = "0" * 64
        telemetry["payloadHash"] = canonical_hash({key: item for key, item in telemetry.items() if key != "payloadHash"})
        write_json(telemetry_path, telemetry)
        with local_scope(project_root, session_key):
            telemetry_mismatch = run_turn(core, phase="evidence")
        assert telemetry_mismatch["code"] == "H7_EVIDENCE_INCOMPLETE", telemetry_mismatch
        assert telemetry_mismatch["entry"]["current"] is True, telemetry_mismatch
        assert telemetry_mismatch["telemetry"]["current"] is False, telemetry_mismatch

        write_json(telemetry_path, pristine_telemetry)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["capabilityRouteReceipt"]["selectionHash"] = "0" * 64
        receipt["receiptHash"] = canonical_hash({key: item for key, item in receipt.items() if key != "receiptHash"})
        write_json(receipt_path, receipt)
        with local_scope(project_root, session_key):
            receipt_mismatch = run_turn(core, phase="evidence")
        assert receipt_mismatch["code"] == "H7_EVIDENCE_INCOMPLETE", receipt_mismatch
        assert receipt_mismatch["entry"]["current"] is False, receipt_mismatch


def test_run_observability_tamper_withholds_h7_evidence() -> None:
    """The compact runtime summary is evidence-bound, not display-only telemetry."""

    with tempfile.TemporaryDirectory(prefix="super-brain-run-observability-tamper-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "f" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-run-observability-tamper")
        core = BrainCore(ROOT, memory_root)

        with local_scope(project_root, session_key):
            opened = run_turn(core, phase="open", turn_intent="design_evaluate")
            assert opened["available"] is True, opened
            scope_ref_value = opened["context"]["scope"]["scopeRef"]
            telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
            telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
            telemetry["runObservability"]["runtimeLatency"]["p95Ms"] = 999.0
            telemetry["runObservability"]["payloadHash"] = canonical_hash(
                {key: item for key, item in telemetry["runObservability"].items() if key != "payloadHash"}
            )
            telemetry["payloadHash"] = canonical_hash({key: item for key, item in telemetry.items() if key != "payloadHash"})
            write_json(telemetry_path, telemetry)
            evidence = run_turn(core, phase="evidence")

    assert evidence["code"] == "H7_EVIDENCE_INCOMPLETE", evidence
    assert evidence["telemetry"]["current"] is False, evidence
    assert evidence["runObservability"]["payloadHash"] == telemetry["runObservability"]["payloadHash"], evidence


def test_internal_unrecorded_open_preserves_current_h7_evidence() -> None:
    """A failed close/checkpoint preflight must not tear open receipt from telemetry."""

    with tempfile.TemporaryDirectory(prefix="super-brain-internal-open-telemetry-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "b" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-internal-open-telemetry")
        core = BrainCore(ROOT, memory_root)

        with local_scope(project_root, session_key):
            opened = run_turn(core, phase="open", turn_intent="design_evaluate")
            assert opened["available"] is True, opened
            scope_ref_value = opened["context"]["scope"]["scopeRef"]
            receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "open.json"
            telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
            persisted_receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            persisted_telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))

            preflight = turn_runtime.open_turn(
                core,
                turn_intent="design_evaluate",
                record_telemetry=False,
                persist_receipt=False,
                execution_apply_phase="verification",
            )
            evidence = run_turn(core, phase="evidence")

        assert preflight["available"] is True, preflight
        assert json.loads(receipt_path.read_text(encoding="utf-8")) == persisted_receipt
        assert json.loads(telemetry_path.read_text(encoding="utf-8")) == persisted_telemetry
        assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence


def test_telemetry_requires_a_persisted_open_entry() -> None:
    """Telemetry may never name an entry that H7 cannot read back."""

    with tempfile.TemporaryDirectory(prefix="super-brain-open-telemetry-entry-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        core = BrainCore(ROOT, memory_root)

        invalid = turn_runtime.open_turn(
            core,
            turn_intent="design_evaluate",
            record_telemetry=True,
            persist_receipt=False,
        )

    assert invalid["available"] is False, invalid
    assert invalid["code"] == "H7_OPEN_TELEMETRY_WITHOUT_PERSISTED_ENTRY_FORBIDDEN", invalid
    assert not (state_root / "workspace" / "runtime-state" / "turn-runtime").exists()


def test_close_checkpoint_preflight_failure_preserves_current_h7_evidence() -> None:
    """A rejected close checkpoint cannot tear the pre-existing H7 evidence."""

    with tempfile.TemporaryDirectory(prefix="super-brain-close-preflight-telemetry-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "c" * 24
        task_id = "task-close-preflight-telemetry"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id=task_id)
        core = BrainCore(ROOT, memory_root)
        workspace_key = workspace_key_for(project_root)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, workspace_key)
        evidence_path = project_root / "project-progress-evidence.txt"
        checkpoint = {
            "last_confirmed_sentence": "The rejected close checkpoint must preserve the prior H7 evidence.",
            "source": "assistant_visible_reply",
            "current_phase": "Fixture",
            "current_step": "Validate the rejected close checkpoint.",
            "next_action": "Keep the previously verified entry and telemetry pair current.",
        }
        proof = project_progress_proof(
            project_root,
            phase=checkpoint["current_phase"],
            current_step=checkpoint["current_step"],
            next_action=checkpoint["next_action"],
            project_evidence=[
                {
                    "kind": "project_file",
                    "relativePath": evidence_path.name,
                    "sha256": file_sha256(evidence_path),
                }
            ],
        )

        with local_scope(project_root, session_key):
            opened = run_turn(core, phase="open", turn_intent="design_evaluate")
            assert opened["available"] is True, opened
            scope_ref_value = opened["context"]["scope"]["scopeRef"]
            receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "open.json"
            close_path = receipt_path.parent / "close.json"
            telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
            before_receipt = receipt_path.read_bytes()
            before_telemetry = telemetry_path.read_bytes()
            before_contract = contract_path.read_bytes()
            original = turn_runtime.record_progress_checkpoint

            def reject_checkpoint(*_args: object, **_kwargs: object) -> dict[str, object]:
                return {"ok": False, "code": "H7_TEST_CLOSE_CHECKPOINT_REJECTED"}

            turn_runtime.record_progress_checkpoint = reject_checkpoint
            try:
                failed = run_turn(
                    core,
                    phase="close",
                    turn_intent="design_evaluate",
                    progress_checkpoint=checkpoint,
                    project_progress_proof=proof,
                    transition_id="close-preflight-rejected",
                )
            finally:
                turn_runtime.record_progress_checkpoint = original
            evidence = run_turn(core, phase="evidence")

        assert failed["available"] is False, failed
        assert failed["code"] == "H7_TEST_CLOSE_CHECKPOINT_REJECTED", failed
        assert receipt_path.read_bytes() == before_receipt
        assert telemetry_path.read_bytes() == before_telemetry
        assert contract_path.read_bytes() == before_contract
        assert not close_path.exists()
        assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
        assert evidence["entry"]["current"] is True, evidence
        assert evidence["telemetry"]["current"] is True, evidence


def test_project_progress_proof_fails_closed_on_missing_or_drift() -> None:
    """A project claim needs a current proof every time, not just at receipt creation."""

    with tempfile.TemporaryDirectory(prefix="super-brain-project-progress-proof-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "a" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-project-progress-proof")
        core = BrainCore(ROOT, memory_root)

        with local_scope(project_root, session_key):
            opened = run_turn(core, phase="open", turn_intent="design_evaluate")
            assert opened["available"] is True, opened
            proof = opened["runtimeReceipt"]["progressTruth"]
            assert proof["state"] == "current", proof
            evidence = run_turn(core, phase="evidence")
            assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
            (project_root / "project-progress-evidence.txt").write_text("drifted after receipt\n", encoding="utf-8")
            drifted = run_turn(core, phase="evidence")

        assert drifted["available"] is False, drifted
        assert drifted["code"] == "H7_PROJECT_PROGRESS_WITHHELD", drifted
        assert drifted["projectProgress"]["state"] == "withheld", drifted
        assert "project_evidence_hash" in drifted["projectProgress"]["missing"], drifted
        serialized = json.dumps({"opened": opened, "drifted": drifted}, ensure_ascii=False)
        assert str(project_root) not in serialized
        assert str(ROOT) not in serialized

    with tempfile.TemporaryDirectory(prefix="super-brain-project-progress-missing-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "b" * 24
        write_native_memory_snapshot(state_root / "workspace")
        task_id = "task-project-progress-missing"
        write_context_contract(state_root, project_root, session_key, task_id=task_id)
        workspace_key = workspace_key_for(project_root)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, workspace_key)
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        contract.pop("projectProgressProof", None)
        write_json(contract_path, contract)
        core = BrainCore(ROOT, memory_root)

        with local_scope(project_root, session_key):
            missing = run_turn(core, phase="open", turn_intent="design_evaluate")

        assert workspace_key
        assert missing["available"] is False, missing
        assert missing["code"] == "H7_PROJECT_PROGRESS_WITHHELD", missing
        safe_task = missing["context"]["task"]["projectProgress"]
        assert safe_task["state"] == "withheld", safe_task
        assert safe_task["payloadHash"] == "", safe_task
        assert safe_task["missing"] == ["project_progress_proof"], safe_task


def test_checkpoint_refreshes_only_a_stale_project_progress_proof_through_h7() -> None:
    """Proof drift has a governed H7 repair route, never a direct contract bypass."""

    with tempfile.TemporaryDirectory(prefix="super-brain-project-progress-refresh-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "c" * 24
        workspace_key = workspace_key_for(project_root)
        task_id = "task-project-progress-refresh"
        evidence_path = project_root / "project-progress-evidence.txt"
        evidence_path.write_text("project progress proof fixture\n", encoding="utf-8")
        initial_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": "Fixture",
            "currentStep": "Open the governed turn.",
            "completedItems": [],
            "projectEvidence": [
                {"kind": "project_file", "relativePath": evidence_path.name, "sha256": file_sha256(evidence_path)}
            ],
            "verificationResults": [],
            "nextAction": "Run the local runtime verification.",
        }
        initial_proof_base64 = base64.b64encode(
            json.dumps(initial_proof, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        seeded = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", "hookless-runtime", "-FocusLabel", "Hookless runtime fixture", "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue the H7 project-proof repair", "-CurrentPhase", "Fixture",
                "-CurrentStep", "Open the governed turn.", "-LastConfirmedSentence", "R0 is verified; return to the source-evidence parent workline.",
                "-LastConfirmedSource", "assistant_commitment", "-NextAction", "Run the local runtime verification.",
                "-PendingSteps", "Run the local runtime verification.", "-ProjectRoot", str(project_root),
                "-ProjectProgressProofBase64", initial_proof_base64, "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert seeded["ok"] is True, seeded
        write_native_memory_snapshot(state_root / "workspace")
        core = BrainCore(ROOT, memory_root)
        initial_progress = {
            "last_confirmed_sentence": "R0 is verified; return to the source-evidence parent workline.",
            "source": "assistant_visible_reply",
            "current_phase": "Fixture",
            "current_step": "Open the governed turn.",
            "next_action": "Run the local runtime verification.",
        }
        progress = {
            "last_confirmed_sentence": "The stale project proof is being refreshed through the H7 checkpoint authority.",
            "source": "assistant_visible_reply",
            "current_phase": "H7 project proof refresh",
            "current_step": "Bind fresh live-file evidence before reporting the repaired progress state.",
            "next_action": "Read H7 evidence and continue only after the user's current proof is verified.",
        }

        with local_scope(project_root, session_key):
            initial_checkpoint = run_turn(
                core,
                phase="checkpoint",
                turn_intent="design_evaluate",
                progress_checkpoint=initial_progress,
                transition_id="fixture-visible-progress-initial",
            )
            assert initial_checkpoint["available"] is True, initial_checkpoint
            first = run_turn(core, phase="open", turn_intent="design_evaluate")
            assert first["available"] is True, first
            evidence_path.write_text("fresh proof evidence after source drift\n", encoding="utf-8")
            withheld = run_turn(core, phase="open", turn_intent="design_evaluate")
            assert withheld["available"] is False, withheld
            assert withheld["code"] == "H7_PROJECT_PROGRESS_WITHHELD", withheld
            refreshed_proof = {
                "schema": "super-brain.project-progress-input.v1",
                "phase": progress["current_phase"],
                "currentStep": progress["current_step"],
                "completedItems": [],
                "projectEvidence": [
                    {"kind": "project_file", "relativePath": evidence_path.name, "sha256": file_sha256(evidence_path)}
                ],
                "verificationResults": [],
                "nextAction": progress["next_action"],
            }
            checkpointed = run_turn(
                core,
                phase="checkpoint",
                turn_intent="design_evaluate",
                progress_checkpoint=progress,
                project_progress_proof=refreshed_proof,
                transition_id="project-proof-refresh-fixture",
            )
            evidence = run_turn(core, phase="evidence")

        assert checkpointed["available"] is True, checkpointed
        assert checkpointed["code"] == "H7_PROJECT_PROGRESS_REFRESH_READY", checkpointed
        assert checkpointed["checkpoint"]["projectProgress"]["state"] == "current", checkpointed
        assert checkpointed["context"]["task"]["currentPhase"] == progress["current_phase"], checkpointed
        assert evidence["available"] is True, evidence
        assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
        serialized = json.dumps({"checkpointed": checkpointed, "evidence": evidence}, ensure_ascii=False)
        assert str(project_root) not in serialized
        assert "rawPromptStored\":true" not in serialized
        assert "rawTranscriptStored\":true" not in serialized


def test_close_resumes_parent_and_hashes_completion_reference() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-close-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "3" * 24
        workspace_key = workspace_key_for(project_root)
        task_id = "task-turn-runtime-close"
        evidence_path = project_root / "close-progress-evidence.txt"
        evidence_path.write_text("close progress proof fixture\n", encoding="utf-8")
        evidence = {"kind": "project_file", "relativePath": evidence_path.name, "sha256": file_sha256(evidence_path)}
        parent_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": "Stage 1",
            "currentStep": "run local verification",
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": "run local verification",
        }
        parent_proof_base64 = base64.b64encode(
            json.dumps(parent_proof, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        parent_checkpoint = {
            "last_confirmed_sentence": "The approved main is ready.",
            "source": "assistant_visible_reply",
            "current_phase": "Stage 1",
            "current_step": "run local verification",
            "next_action": "run local verification",
        }
        parent_checkpoint_base64 = base64.b64encode(
            json.dumps(parent_checkpoint, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        parent = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", "approved-main", "-FocusLabel", "Approved main", "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue approved main", "-CurrentPhase", "Stage 1", "-CurrentStep", "run local verification",
                "-LastConfirmedSentence", "The approved main is ready.", "-LastConfirmedSource", "assistant_commitment",
                "-NextAction", "run local verification", "-PendingSteps", "run local verification",
                "-ProjectRoot", str(project_root), "-ProjectProgressProofBase64", parent_proof_base64,
                "-ProgressCheckpointBase64", parent_checkpoint_base64, "-TransitionId", "seed-turn-runtime-parent",
                "-StateRoot", str(state_root), "-Json",
            ]
        )
        side_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": "Stage 1",
            "currentStep": "answer status",
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": "finish status insertion",
        }
        side_proof_base64 = base64.b64encode(
            json.dumps(side_proof, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        side_checkpoint = {
            "last_confirmed_sentence": "The status insertion is handled.",
            "source": "assistant_visible_reply",
            "current_phase": "Stage 1",
            "current_step": "answer status",
            "next_action": "finish status insertion",
        }
        side_checkpoint_base64 = base64.b64encode(
            json.dumps(side_checkpoint, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        side = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", "status-insertion", "-FocusLabel", "Status insertion", "-InstructionMode", "side_branch",
                "-LatestUserInstruction", "answer status then return to approved main", "-CurrentPhase", "Stage 1", "-CurrentStep", "answer status",
                "-LastConfirmedSentence", "The status insertion is handled.", "-LastConfirmedSource", "assistant_commitment",
                "-NextAction", "finish status insertion", "-PendingSteps", "finish status insertion",
                "-ExpectedRevision", str(parent["revision"]), "-ExpectedPlanFingerprint", str(parent["planReceipt"]["planFingerprint"]),
                "-ProjectRoot", str(project_root), "-ProjectProgressProofBase64", side_proof_base64,
                "-ProgressCheckpointBase64", side_checkpoint_base64,
                "-TransitionId", "open-turn-runtime-side", "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert side["ok"] is True
        write_native_memory_snapshot(state_root / "workspace")
        core = BrainCore(ROOT, memory_root)
        marker = "raw-user-text-must-not-be-persisted"

        assist_calls = 0
        project_knowledge_calls = 0
        original_assist_resolver = turn_runtime._resolve_execution_assist_for_turn
        original_project_knowledge_resolver = turn_runtime._resolve_project_knowledge_for_turn

        def counted_assist(*args, **kwargs):
            nonlocal assist_calls
            assist_calls += 1
            return original_assist_resolver(*args, **kwargs)

        def counted_project_knowledge(*args, **kwargs):
            nonlocal project_knowledge_calls
            project_knowledge_calls += 1
            return original_project_knowledge_resolver(*args, **kwargs)

        turn_runtime._resolve_execution_assist_for_turn = counted_assist
        turn_runtime._resolve_project_knowledge_for_turn = counted_project_knowledge
        try:
            with local_scope(project_root, session_key):
                opened = run_turn(core, phase="open")
                assist_calls = 0
                project_knowledge_calls = 0
                closed = run_turn(
                    core,
                    phase="close",
                    turn_outcome="side_branch_completed",
                    user_control="none",
                    completion_evidence_ref=marker,
                    transition_id="turn-runtime-close-side",
                )
                close_assist_calls = assist_calls
                close_project_knowledge_calls = project_knowledge_calls
                evidence_after_close = run_turn(core, phase="evidence")
                parent_task = closed["context"]["task"]
                parent_recovered = run_turn(
                    BrainCore(ROOT, memory_root),
                    phase="open",
                    turn_intent="continuity",
                    recovery_event="parent_return",
                )
        finally:
            turn_runtime._resolve_execution_assist_for_turn = original_assist_resolver
            turn_runtime._resolve_project_knowledge_for_turn = original_project_knowledge_resolver

        assert opened["available"] is True
        assert closed["ok"] is True
        assert closed["continuation"]["decision"] == "resume_parent_required", closed
        assert closed["transition"]["action"] == "ResumeParent"
        assert closed["mustContinue"] is True
        assert closed["terminalReplyAllowed"] is False
        assert evidence_after_close["code"] == "H7_EVIDENCE_CURRENT", evidence_after_close
        assert evidence_after_close["entry"]["current"] is True, evidence_after_close
        assert evidence_after_close["telemetry"]["current"] is True, evidence_after_close
        assert parent_recovered["available"] is True, parent_recovered
        assert parent_recovered["context"]["parentReturnStateCard"]["state"] == "current", parent_recovered
        assert parent_recovered["recoveryPresentation"]["event"] == "parent_return", parent_recovered
        assert parent_recovered["recoveryPresentation"]["openingLine"] == recovery_progress_line(parent_recovered["context"]["task"]), parent_recovered
        # The post-dispatch open is still required after ResumeParent, but it
        # reuses the same call-local execution-assist bundle rather than
        # re-reading the cold capability registry/shadow evaluation.
        assert close_assist_calls == 1, close_assist_calls
        assert close_project_knowledge_calls == 2, close_project_knowledge_calls
        scope_ref_value = closed["context"]["scope"]["scopeRef"]
        receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "close.json"
        telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
        receipt_text = receipt_path.read_text(encoding="utf-8")
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        assert marker not in receipt_text
        assert marker not in telemetry_path.read_text(encoding="utf-8")
        assert marker not in (state_root / "workspace" / "last-execution-contract.json").read_text(encoding="utf-8")
        assert [event["phase"] for event in telemetry["events"]] == ["open", "open", "close", "open"]


def test_close_rejects_user_attested_checkpoint_outside_correction_without_mutation() -> None:
    """The close path must not bypass the correction-only source guard."""

    with tempfile.TemporaryDirectory(prefix="super-brain-close-user-attested-guard-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "8" * 24
        task_id = "task-close-user-attested-guard"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id=task_id)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, workspace_key_for(project_root))
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        before = contract_path.read_bytes()
        progress = {
            "last_confirmed_sentence": str(contract["lastConfirmedSentence"]),
            "source": "user_attested_visible_reply",
            "current_phase": str(contract["currentPhase"]),
            "current_step": str(contract["currentStep"]),
            "next_action": str(contract["nextAction"]),
        }

        with local_scope(project_root, session_key):
            result = run_turn(
                BrainCore(ROOT, memory_root),
                phase="close",
                turn_intent="continuity",
                turn_outcome="active_work_progressed",
                progress_checkpoint=progress,
                transition_id="close-user-attested-guard-fixture",
            )

        assert result["available"] is False, result
        assert result["code"] == "H7_USER_ATTESTED_VISIBLE_PROGRESS_INTENT_REQUIRED", result
        assert contract_path.read_bytes() == before


def test_checkpoint_scope_change_without_fresh_proof_fails_atomically() -> None:
    """A new progress sentence/action may not replace a current proof alone."""

    with tempfile.TemporaryDirectory(prefix="super-brain-checkpoint-proof-atomic-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "e" * 24
        task_id = "task-checkpoint-proof-atomic"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id=task_id)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, workspace_key_for(project_root))
        before = json.loads(contract_path.read_text(encoding="utf-8"))
        core = BrainCore(ROOT, memory_root)
        progress = {
            "last_confirmed_sentence": "R0 has a new next action, but no fresh proof was supplied.",
            "source": "assistant_visible_reply",
            "current_phase": "Fixture",
            "current_step": "Open the governed turn.",
            "next_action": "Run a different verification that needs a fresh proof.",
        }

        with local_scope(project_root, session_key):
            result = run_turn(
                core,
                phase="checkpoint",
                turn_intent="continuity",
                progress_checkpoint=progress,
                transition_id="checkpoint-proof-atomic-fixture",
            )

        after = json.loads(contract_path.read_text(encoding="utf-8"))
        assert result["available"] is False, result
        assert result["code"] == "EXECUTION_CONTRACT_PROGRESS_CHECKPOINT_PROJECT_PROOF_REQUIRED", result
        assert after["revision"] == before["revision"], (before, after)
        assert after["lastConfirmedSentence"] == before["lastConfirmedSentence"], (before, after)
        assert after["nextAction"] == before["nextAction"], (before, after)


def test_invalid_phase_fails_without_state_write() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-invalid-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        core = BrainCore(ROOT, memory_root)
        result = run_turn(core, phase="invalid")
        assert result["ok"] is False
        assert result["code"] == "TURN_RUNTIME_PHASE_INVALID"
        assert not (state_root / "workspace" / "runtime-state" / "turn-runtime").exists()


def test_super_brain_issue_projects_root_rule_and_protocol() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-issue-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "5" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-turn-runtime-issue")
        core = BrainCore(ROOT, memory_root)
        with local_scope(project_root, session_key):
            result = run_turn(core, phase="open", turn_intent="super_brain_issue_runtime")
        assert result["available"] is True, result
        assert result["context"]["turnIntent"]["problemNature"] == "hookless_runtime", result
        assert result["context"]["turnIntent"]["responseOrder"] == "essence>fact_inference_unknown>repair>next", result
        assert result["continuityMapping"]["state"] == "not_requested", result
        assert {
            "SB-PROJECT-GROUNDED-DESIGN-001",
            "SB-DEFECT-ROOT-REPAIR-001",
            "SB-RULE-MEMORY-SPLIT-001",
            "SB-PROGRESS-TRUTH-001",
            "SB-NO-REPEAT-FAILED-ROUTE-001",
            "SB-H7-ACTIVATION-001",
        }.issubset(set(result["context"]["coreRules"]["applicableRuleIds"])), result
        assert result["runtimeReceipt"]["turnIntent"]["learningWriteAllowed"] is False, result

        environment = os.environ.copy()
        environment["SUPER_BRAIN_LOCAL_SESSION_ID"] = session_key
        cli = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "brain_cli.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(memory_root),
                "turn-runtime",
                "--phase",
                "open",
                "--turn-intent",
                "super_brain_issue_runtime",
            ],
            cwd=str(project_root),
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        assert cli.returncode == 0, cli.stderr
        cli_result = json.loads(cli.stdout)
        assert cli_result["runtimeReceipt"]["turnIntent"]["kind"] == "super_brain_issue_runtime", cli_result
        assert cli_result["runtimeReceipt"]["coreRules"]["payloadHash"], cli_result


def test_registry_change_stales_h7_evidence_until_reopened() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-registry-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        package_root = Path(directory) / "package"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        package_root.mkdir()
        for name in (
            "manifest.json",
            "route-map.json",
            "capabilities.json",
            "super-brain-rules.json",
            "capability-source-registry.json",
            "capability-shadow-fixtures.json",
            "capability-shadow-evaluation.json",
        ):
            (package_root / name).write_bytes((ROOT / name).read_bytes())
        for relative_path in runtime_dependency_paths(ROOT):
            destination = package_root / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((ROOT / relative_path).read_bytes())
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "4" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id="task-turn-runtime-registry")
        core = BrainCore(package_root, memory_root)

        with local_scope(project_root, session_key):
            opened = run_turn(core, phase="open")
            before = run_turn(core, phase="evidence")
        assert opened["available"] is True, opened
        assert before["code"] == "H7_EVIDENCE_CURRENT", before
        previous_hash = opened["runtimeReceipt"]["coreRules"]["payloadHash"]

        registry_path = package_root / "super-brain-rules.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        registry["rules"][0]["revision"] = 2
        registry["payloadHash"] = canonical_hash({key: value for key, value in registry.items() if key != "payloadHash"})
        write_json(registry_path, registry)

        # The same object models a long-lived MCP stdio worker.  It must not
        # silently keep serving the startup registry after an in-place package
        # update; only a fresh worker may adopt the new source.
        with local_scope(project_root, session_key):
            stale_worker = run_turn(core, phase="open")
        assert stale_worker["available"] is False, stale_worker
        assert stale_worker["code"] == "BRAIN_CONTEXT_RUNTIME_IDENTITY_WITHHELD", stale_worker
        assert stale_worker["context"]["runtimeIdentity"]["code"] == "H7_MCP_RUNTIME_RULE_REGISTRY_STALE", stale_worker

        refreshed_core = BrainCore(package_root, memory_root)
        with local_scope(project_root, session_key):
            stale = run_turn(refreshed_core, phase="evidence")
            reopened = run_turn(refreshed_core, phase="open")
            recovered = run_turn(refreshed_core, phase="evidence")
        assert stale["code"] == "H7_EVIDENCE_INCOMPLETE", stale
        assert stale["entry"]["current"] is False, stale
        assert stale["telemetry"]["current"] is False, stale
        assert stale["coreRules"]["payloadHash"] != previous_hash, stale
        assert reopened["runtimeReceipt"]["coreRules"]["payloadHash"] == stale["coreRules"]["payloadHash"], reopened
        assert recovered["code"] == "H7_EVIDENCE_CURRENT", recovered

        registry_path.write_bytes(b"\xef\xbb\xbf" + registry_path.read_bytes())
        invalid_core = BrainCore(package_root, memory_root)
        with local_scope(project_root, session_key):
            withheld = run_turn(invalid_core, phase="open")
        assert withheld["available"] is False, withheld
        assert withheld["code"] == "BRAIN_CONTEXT_CORE_RULES_WITHHELD", withheld
        assert withheld["context"]["coreRules"]["code"] == "CORE_RULE_REGISTRY_BOM_FORBIDDEN", withheld


def test_checkpoint_reconciles_after_uncertain_set_result() -> None:
    """A timeout after the authority commits must not strand H7 as failed."""

    checkpoint = {
        "last_confirmed_sentence": "The authority committed before the launcher timed out.",
        "source": "assistant_visible_reply",
        "current_phase": "H7 recovery",
        "current_step": "Reconcile the committed transition once.",
        "next_action": "Reopen the H7 receipt after reconciliation.",
    }
    calls: list[str] = []
    captured_transition = ""
    original = turn_close_dispatcher._invoke_contract

    current = {
        "ok": True,
        "taskId": "task-timeout-reconcile",
        "revision": 7,
        "planFingerprint": "fixture-plan-timeout",
    }

    def uncertain_invoke(*_args: object, action: str, extra: list[str] | None = None, **_kwargs: object) -> tuple[int, dict[str, object] | None]:
        nonlocal captured_transition
        calls.append(action)
        if action == "Set":
            assert extra is not None
            captured_transition = extra[extra.index("-TransitionId") + 1]
            return 1, None
        if action == "Get" and captured_transition:
            return 0, {
                **current,
                "revision": 8,
                "lastConfirmedSentence": checkpoint["last_confirmed_sentence"],
                "lastConfirmedSource": checkpoint["source"],
                "currentPhase": checkpoint["current_phase"],
                "currentStep": checkpoint["current_step"],
                "nextAction": checkpoint["next_action"],
                "visibleProgressReceipt": {
                    "source": checkpoint["source"],
                    "sentenceHash": hashlib.sha256(checkpoint["last_confirmed_sentence"].encode("utf-8")).hexdigest(),
                    "currentPhase": checkpoint["current_phase"],
                    "currentStep": checkpoint["current_step"],
                    "nextAction": checkpoint["next_action"],
                    "transitionId": captured_transition,
                    "payloadHash": "c" * 64,
                    "projectProgressPayloadHash": "d" * 64,
                },
                "transitionReceipts": [{"transitionId": captured_transition, "action": "Set", "resultRevision": 8}],
            }
        return 0, current

    turn_close_dispatcher._invoke_contract = uncertain_invoke
    try:
        result = turn_close_dispatcher.record_progress_checkpoint(
            ROOT,
            ROOT / "private-state",
            task_id="task-timeout-reconcile",
            workspace_key="ws-" + "1" * 24,
            session_key="sid-" + "2" * 24,
            progress_checkpoint=checkpoint,
        )
    finally:
        turn_close_dispatcher._invoke_contract = original

    assert result["ok"] is True, result
    assert result["code"] == "H7_PROGRESS_CHECKPOINT_RECONCILED", result
    assert result["stateMutated"] is True, result
    assert result["revision"] == 8, result
    assert calls == ["Get", "Set", "Get"], calls


def test_checkpoint_retries_one_unacknowledged_transport_with_same_transition_id_and_timeout_floor() -> None:
    """One missing Set acknowledgement retries safely without weakening CAS."""

    checkpoint = {
        "last_confirmed_sentence": "The retry keeps the exact H7 checkpoint transition.",
        "source": "assistant_visible_reply",
        "current_phase": "H7 transport repair",
        "current_step": "Replay the same deterministic checkpoint once.",
        "next_action": "Reopen H7 only after the authority acknowledges it.",
    }
    calls: list[tuple[str, str, float]] = []
    captured_transition = ""
    original = turn_close_dispatcher._invoke_contract
    current = {
        "ok": True,
        "taskId": "task-transport-retry",
        "revision": 7,
        "planFingerprint": "fixture-plan-transport-retry",
    }

    def retrying_invoke(
        *_args: object,
        action: str,
        extra: list[str] | None = None,
        timeout: float,
        **_kwargs: object,
    ) -> tuple[int, dict[str, object] | None]:
        nonlocal captured_transition
        transition = ""
        if extra and "-TransitionId" in extra:
            transition = str(extra[extra.index("-TransitionId") + 1])
            captured_transition = transition
        calls.append((action, transition, timeout))
        if action == "Get":
            return 0, current
        assert action == "Set"
        assert transition
        set_calls = sum(1 for call, _, _ in calls if call == "Set")
        if set_calls == 1:
            return 1, None
        return 0, {
            **current,
            "revision": 8,
            "idempotentReplay": False,
            "projectProgressProof": {"state": "current", "payloadHash": "e" * 64},
            "visibleProgressReceipt": {
                "source": checkpoint["source"],
                "sentenceHash": hashlib.sha256(checkpoint["last_confirmed_sentence"].encode("utf-8")).hexdigest(),
                "payloadHash": "f" * 64,
                "projectProgressPayloadHash": "e" * 64,
            },
        }

    turn_close_dispatcher._invoke_contract = retrying_invoke
    try:
        result = turn_close_dispatcher.record_progress_checkpoint(
            ROOT,
            ROOT / "private-state",
            task_id="task-transport-retry",
            workspace_key="ws-" + "3" * 24,
            session_key="sid-" + "4" * 24,
            progress_checkpoint=checkpoint,
            timeout=0.25,
        )
    finally:
        turn_close_dispatcher._invoke_contract = original

    assert result["ok"] is True, result
    assert result["code"] == "H7_PROGRESS_CHECKPOINT_WRITTEN", result
    assert [call for call, _, _ in calls] == ["Get", "Set", "Get", "Set"], calls
    set_transitions = [transition for call, transition, _ in calls if call == "Set"]
    assert set_transitions == [captured_transition, captured_transition], calls
    assert all(timeout >= 12.0 for _, _, timeout in calls), calls


def test_checkpoint_uses_verified_open_contract_as_cas_hint() -> None:
    """A validated same-call contract avoids a redundant authority Get."""

    checkpoint = {
        "last_confirmed_sentence": "The verified open contract supplies the CAS hint.",
        "source": "assistant_visible_reply",
        "current_phase": "H7 transport repair",
        "current_step": "Reuse the validated local contract revision.",
        "next_action": "Reopen the H7 receipt after the checkpoint.",
    }
    workspace_key = "ws-" + "a" * 24
    session_key = "sid-" + "b" * 24
    current = {
        "ok": True,
        "taskId": "task-contract-hint",
        "workspaceKey": workspace_key,
        "ownerSessionKey": session_key,
        "revision": 7,
        "planFingerprint": "fixture-plan-contract-hint",
    }
    calls: list[str] = []
    original = turn_close_dispatcher._invoke_contract

    def hinted_invoke(*_args: object, action: str, extra: list[str] | None = None, **_kwargs: object) -> tuple[int, dict[str, object] | None]:
        calls.append(action)
        assert action == "Set"
        assert extra is not None
        assert extra[extra.index("-ExpectedRevision") + 1] == "7"
        return 0, {
            **current,
            "revision": 8,
            "idempotentReplay": False,
            "projectProgressProof": {"state": "current", "payloadHash": "a" * 64},
            "visibleProgressReceipt": {
                "source": checkpoint["source"],
                "sentenceHash": hashlib.sha256(checkpoint["last_confirmed_sentence"].encode("utf-8")).hexdigest(),
                "payloadHash": "b" * 64,
            },
        }

    turn_close_dispatcher._invoke_contract = hinted_invoke
    try:
        with tempfile.TemporaryDirectory(prefix="super-brain-contract-hint-") as directory:
            result = turn_close_dispatcher.record_progress_checkpoint(
                ROOT,
                Path(directory),
                task_id="task-contract-hint",
                workspace_key=workspace_key,
                session_key=session_key,
                progress_checkpoint=checkpoint,
                project_root=ROOT,
                current_contract=current,
                transition_id="contract-hint-checkpoint",
            )
    finally:
        turn_close_dispatcher._invoke_contract = original

    assert result["ok"] is True, result
    assert result["contractReadPath"] == "in_process_hint", result
    assert calls == ["Set"], calls


def test_checkpoint_does_not_retry_a_rejected_cas_transaction() -> None:
    """A definite authority rejection remains fail-closed, not transport-retried."""

    checkpoint = {
        "last_confirmed_sentence": "The CAS mismatch stays blocked.",
        "source": "assistant_visible_reply",
        "current_phase": "H7 CAS guard",
        "current_step": "Reject a changed contract revision.",
        "next_action": "Resolve the current contract before another checkpoint.",
    }
    calls: list[str] = []
    original = turn_close_dispatcher._invoke_contract

    def rejected_invoke(*_args: object, action: str, **_kwargs: object) -> tuple[int, dict[str, object] | None]:
        calls.append(action)
        if action == "Get":
            return 0, {
                "ok": True,
                "taskId": "task-cas-rejection",
                "revision": 7,
                "planFingerprint": "fixture-plan-cas-rejection",
            }
        return 1, {"ok": False, "code": "EXECUTION_CONTRACT_REVISION_MISMATCH", "reason": "changed"}

    turn_close_dispatcher._invoke_contract = rejected_invoke
    try:
        result = turn_close_dispatcher.record_progress_checkpoint(
            ROOT,
            ROOT / "private-state",
            task_id="task-cas-rejection",
            workspace_key="ws-" + "5" * 24,
            session_key="sid-" + "6" * 24,
            progress_checkpoint=checkpoint,
        )
    finally:
        turn_close_dispatcher._invoke_contract = original

    assert result["ok"] is False, result
    assert result["code"] == "H7_PROGRESS_CHECKPOINT_TRANSACTION_FAILED", result
    assert result["contractCode"] == "EXECUTION_CONTRACT_REVISION_MISMATCH", result
    assert calls == ["Get", "Set", "Get"], calls


def test_checkpoint_binds_current_instruction_and_projects_verified_canonical_completion() -> None:
    """A verified checkpoint must not leave the matching plan item pending."""

    evidence_path = ROOT / "runtime" / "turn_close_dispatcher.py"
    evidence_hash = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
    evidence_ref = f"project:file:runtime/turn_close_dispatcher.py@sha256:{evidence_hash}"
    instruction = "Continue the approved entry repair after the verified MCP replay."
    checkpoint = {
        "last_confirmed_sentence": "The MCP replay passed and the entry repair is complete.",
        "source": "assistant_visible_reply",
        "current_phase": "Stage 4",
        "current_step": "Bind the verified runtime handoff to the canonical task plan.",
        "next_action": "Publish the stage receipt and close the completed entry repair.",
    }
    proof = {
        "schema": "super-brain.project-progress-input.v1",
        "phase": checkpoint["current_phase"],
        "currentStep": checkpoint["current_step"],
        "completedItems": [
            {
                "itemKey": "Stage 4 runtime validation and handoff",
                "evidenceRefs": [evidence_ref],
                "verificationIds": ["mcp_protocol_replay"],
            }
        ],
        "projectEvidence": [
            {
                "kind": "project_file",
                "relativePath": "runtime/turn_close_dispatcher.py",
                "sha256": evidence_hash,
            }
        ],
        "verificationResults": [{"id": "mcp_protocol_replay", "status": "passed"}],
        "nextAction": checkpoint["next_action"],
    }
    current = {
        "ok": True,
        "taskId": "task-canonical-checkpoint",
        "taskInstanceId": "ti-canonical-checkpoint-11111111111111111111111111111111",
        "workspaceKey": "ws-" + "7" * 24,
        "ownerSessionKey": "sid-" + "8" * 24,
        "revision": 7,
        "planFingerprint": "fixture-plan-canonical",
        "latestUserInstruction": "The older task instruction.",
        "focusId": "entry-repair-main",
        "focusLabel": "Fresh task Super Brain routing and G1 visibility",
        "assistantCommitment": "Repair the entry path through one package-owned adapter and verify the active transport.",
        "canonicalPlan": {
            "planId": "plan-canonical-checkpoint",
            "generation": 1,
            "currentFingerprint": "fixture-canonical-fingerprint",
            "items": [
                {
                    "itemId": "item-stage-4",
                    "label": "Stage 4 runtime validation and handoff",
                    "status": "pending",
                }
            ],
        },
    }
    captured: dict[str, object] = {}
    original = turn_close_dispatcher._invoke_contract

    def invoke(*_args: object, action: str, extra: list[str] | None = None, **_kwargs: object) -> tuple[int, dict[str, object] | None]:
        if action == "Get":
            return 0, current
        assert action == "Set"
        assert extra is not None
        captured["extra"] = list(extra)
        mutation_path = Path(extra[extra.index("-CanonicalMutationPath") + 1])
        captured["mutation"] = json.loads(mutation_path.read_text(encoding="utf-8"))
        return 0, {
            **current,
            "revision": 8,
            "projectProgressProof": {"state": "current", "payloadHash": "a" * 64},
            "visibleProgressReceipt": {
                "source": checkpoint["source"],
                "sentenceHash": hashlib.sha256(checkpoint["last_confirmed_sentence"].encode("utf-8")).hexdigest(),
                "payloadHash": "b" * 64,
                "projectProgressPayloadHash": "a" * 64,
            },
        }

    turn_close_dispatcher._invoke_contract = invoke
    try:
        with tempfile.TemporaryDirectory() as temporary:
            result = turn_close_dispatcher.record_progress_checkpoint(
                ROOT,
                Path(temporary),
                task_id="task-canonical-checkpoint",
                workspace_key="ws-" + "7" * 24,
                session_key="sid-" + "8" * 24,
                progress_checkpoint=checkpoint,
                project_progress_proof=proof,
                latest_user_instruction=instruction,
                project_root=ROOT,
            )
    finally:
        turn_close_dispatcher._invoke_contract = original

    assert result["ok"] is True, result
    assert result["canonicalStatusProjection"] == "H7_CANONICAL_STATUS_MUTATION_READY", result
    assert result["instructionMappingBound"] is True, result
    extras = captured["extra"]
    assert extras[extras.index("-LatestUserInstruction") + 1] == instruction
    assert extras[extras.index("-InstructionMode") + 1] == "continue"
    assert extras[extras.index("-FocusId") + 1] == "entry-repair-main"
    assert extras[extras.index("-FocusLabel") + 1] == "Fresh task Super Brain routing and G1 visibility"
    mutation = captured["mutation"]
    assert mutation["approvalSource"] == "verified_status_transition"
    assert mutation["targetItemIds"] == ["item-stage-4"]
    assert mutation["userInstructionFingerprint"] == hashlib.sha256(instruction.encode("utf-8")).hexdigest()[:16]


def test_canonical_status_mutation_uses_four_key_scope_and_conflict_replay() -> None:
    """Same transition IDs must never collide across task/session instances."""

    def current(task_id: str, task_instance_id: str, workspace_key: str, session_key: str) -> dict[str, object]:
        return {
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "revision": 7,
            "latestUserInstruction": "Bind the verified canonical completion.",
            "canonicalPlan": {
                "planId": f"plan-{task_id}",
                "generation": 1,
                "currentFingerprint": "f" * 32,
                "items": [{"itemId": "item-stage", "label": "Stage item", "status": "pending"}],
            },
        }

    def proof(reference: str) -> dict[str, object]:
        return {
            "completedItems": [{"itemKey": "Stage item", "evidenceRefs": [reference]}],
        }

    with tempfile.TemporaryDirectory(prefix="super-brain-canonical-four-key-") as directory:
        state_root = Path(directory)
        shared_transition = "canonical-four-key-shared-transition"
        first = current(
            "task-four-key-a",
            "ti-" + "a" * 32,
            "ws-" + "a" * 24,
            "sid-" + "a" * 24,
        )
        second = current(
            "task-four-key-b",
            "ti-" + "b" * 32,
            "ws-" + "b" * 24,
            "sid-" + "b" * 24,
        )
        first_path, first_code = turn_close_dispatcher._write_canonical_status_mutation(
            state_root=state_root,
            current=first,
            proof=proof("project:file:a@sha256:" + "a" * 64),
            transition_id=shared_transition,
            latest_user_instruction="Bind the verified canonical completion.",
            task_id=str(first["taskId"]),
            workspace_key=str(first["workspaceKey"]),
            session_key=str(first["ownerSessionKey"]),
        )
        second_path, second_code = turn_close_dispatcher._write_canonical_status_mutation(
            state_root=state_root,
            current=second,
            proof=proof("project:file:b@sha256:" + "b" * 64),
            transition_id=shared_transition,
            latest_user_instruction="Bind the verified canonical completion.",
            task_id=str(second["taskId"]),
            workspace_key=str(second["workspaceKey"]),
            session_key=str(second["ownerSessionKey"]),
        )
        replay_path, replay_code = turn_close_dispatcher._write_canonical_status_mutation(
            state_root=state_root,
            current=first,
            proof=proof("project:file:a@sha256:" + "a" * 64),
            transition_id=shared_transition,
            latest_user_instruction="Bind the verified canonical completion.",
            task_id=str(first["taskId"]),
            workspace_key=str(first["workspaceKey"]),
            session_key=str(first["ownerSessionKey"]),
        )
        conflict_path, conflict_code = turn_close_dispatcher._write_canonical_status_mutation(
            state_root=state_root,
            current=first,
            proof=proof("project:file:changed@sha256:" + "c" * 64),
            transition_id=shared_transition,
            latest_user_instruction="Bind the verified canonical completion.",
            task_id=str(first["taskId"]),
            workspace_key=str(first["workspaceKey"]),
            session_key=str(first["ownerSessionKey"]),
        )

        assert first_code == "H7_CANONICAL_STATUS_MUTATION_READY"
        assert second_code == "H7_CANONICAL_STATUS_MUTATION_READY"
        assert first_path and second_path and first_path != second_path
        assert replay_code == "H7_CANONICAL_STATUS_MUTATION_READY" and replay_path == first_path
        assert conflict_path is None and conflict_code == "H7_CANONICAL_STATUS_MUTATION_CONFLICT"
        first_envelope = json.loads(Path(first_path).read_text(encoding="utf-8"))
        second_envelope = json.loads(Path(second_path).read_text(encoding="utf-8"))
        assert first_envelope["schema"] == "super-brain.canonical-plan-mutation.v2"
        assert first_envelope["scope"] == {
            "taskId": first["taskId"],
            "taskInstanceId": first["taskInstanceId"],
            "workspaceKey": first["workspaceKey"],
            "ownerSessionKey": first["ownerSessionKey"],
        }
        assert second_envelope["scope"]["taskInstanceId"] != first_envelope["scope"]["taskInstanceId"]


def test_checkpoint_instruction_mapping_uses_real_powershell_authority_and_replays_idempotently() -> None:
    """The live Set/Get authority must bind the current focus with a new instruction.

    The nearby unit regression intentionally inspects the Python-to-PowerShell
    command mapping.  This integration replay covers the authority boundary
    itself: a new latest user instruction must keep the active focus, clear
    reconciliation, and permit only an exact idempotent checkpoint replay.
    """

    with tempfile.TemporaryDirectory(prefix="super-brain-checkpoint-authority-") as directory:
        state_root = Path(directory) / "state"
        project_root = Path(directory) / "project"
        state_root.mkdir()
        project_root.mkdir()
        session_key = "sid-" + "9" * 24
        workspace_key = workspace_key_for(project_root)
        task_id = "task-checkpoint-authority-instruction-map"
        focus_id = "checkpoint-authority-main"
        focus_label = "Checkpoint authority main line"
        initial_instruction = "Continue the initial checkpoint authority workline."
        latest_instruction = "Continue the verified checkpoint authority repair on the active main line."
        evidence_path = project_root / "checkpoint-authority-evidence.txt"
        evidence_path.write_text("checkpoint authority evidence\n", encoding="utf-8")
        evidence = {
            "kind": "project_file",
            "relativePath": evidence_path.name,
            "sha256": file_sha256(evidence_path),
        }

        def encode(value: dict[str, object]) -> str:
            return base64.b64encode(
                json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            ).decode("ascii")

        seeded_checkpoint = {
            "last_confirmed_sentence": "The checkpoint authority fixture is ready.",
            "source": "assistant_visible_reply",
            "current_phase": "Checkpoint authority setup",
            "current_step": "Create the scoped H7 contract.",
            "next_action": "Bind the current verified checkpoint.",
        }
        seeded_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": seeded_checkpoint["current_phase"],
            "currentStep": seeded_checkpoint["current_step"],
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": seeded_checkpoint["next_action"],
        }
        seeded = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", focus_id, "-FocusLabel", focus_label, "-InstructionMode", "continue",
                "-LatestUserInstruction", initial_instruction,
                "-AssistantCommitment", "Keep the checkpoint authority workline scoped and verified.",
                "-ProjectRoot", str(project_root), "-ProjectProgressProofBase64", encode(seeded_proof),
                "-ProgressCheckpointBase64", encode(seeded_checkpoint), "-TransitionId", "checkpoint-authority-seed",
                "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert seeded["needsReconciliation"] is False, seeded
        assert seeded["focusId"] == focus_id, seeded

        checkpoint = {
            "last_confirmed_sentence": "The live checkpoint authority bound the latest instruction to the active focus.",
            "source": "assistant_visible_reply",
            "current_phase": "Checkpoint authority repair",
            "current_step": "Write the exact latest instruction through the H7 CAS transaction.",
            "next_action": "Read the authority state and continue the verified main workline.",
        }
        proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": checkpoint["current_phase"],
            "currentStep": checkpoint["current_step"],
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": checkpoint["next_action"],
        }
        transition_id = "checkpoint-authority-instruction-map"

        with local_scope(project_root, session_key):
            written = turn_close_dispatcher.record_progress_checkpoint(
                ROOT,
                state_root,
                task_id=task_id,
                workspace_key=workspace_key,
                session_key=session_key,
                progress_checkpoint=checkpoint,
                project_progress_proof=proof,
                latest_user_instruction=latest_instruction,
                project_root=project_root,
                transition_id=transition_id,
            )
            after_write = invoke_contract(
                [
                    "-Action", "Get", "-TaskId", task_id, "-WorkspaceKey", workspace_key,
                    "-SessionKey", session_key, "-StateRoot", str(state_root), "-Json",
                ]
            )
            replayed = turn_close_dispatcher.record_progress_checkpoint(
                ROOT,
                state_root,
                task_id=task_id,
                workspace_key=workspace_key,
                session_key=session_key,
                progress_checkpoint=checkpoint,
                project_progress_proof=proof,
                latest_user_instruction=latest_instruction,
                project_root=project_root,
                transition_id=transition_id,
            )
            after_replay = invoke_contract(
                [
                    "-Action", "Get", "-TaskId", task_id, "-WorkspaceKey", workspace_key,
                    "-SessionKey", session_key, "-StateRoot", str(state_root), "-Json",
                ]
            )

    assert written["ok"] is True, written
    assert written["code"] == "H7_PROGRESS_CHECKPOINT_WRITTEN", written
    assert written["instructionAnchorBound"] is True, written
    assert written["instructionMappingBound"] is True, written
    assert after_write["latestUserInstruction"] == latest_instruction, after_write
    assert after_write["instructionMode"] == "continue", after_write
    assert after_write["focusId"] == focus_id, after_write
    assert after_write["focusLabel"] == focus_label, after_write
    assert after_write["needsReconciliation"] is False, after_write
    assert after_write["lastConfirmedSentence"] == checkpoint["last_confirmed_sentence"], after_write
    assert replayed["ok"] is True, replayed
    assert replayed["code"] == "H7_PROGRESS_CHECKPOINT_REPLAYED", replayed
    assert replayed["stateMutated"] is False, replayed
    assert replayed["revision"] == after_write["revision"], replayed
    assert after_replay["revision"] == after_write["revision"], after_replay
    assert after_replay["needsReconciliation"] is False, after_replay


def test_checkpoint_is_the_only_h7_path_that_clears_a_pending_same_scope_contract() -> None:
    """A pending same-scope contract is repairable only by its explicit H7 checkpoint.

    This covers the authority gap that used to strand a contract after its
    latest instruction was marked for reconciliation: ordinary H7 open stays
    withheld, while the checkpoint reads the same scoped contract solely to
    bind the current instruction, current focus, project proof, and assistant
    progress through the existing CAS ``Set`` transaction.
    """

    with tempfile.TemporaryDirectory(prefix="super-brain-reconciliation-checkpoint-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        project_root = Path(directory) / "project"
        state_root.mkdir()
        memory_root.mkdir()
        project_root.mkdir()
        session_key = "sid-" + "6" * 24
        workspace_key = workspace_key_for(project_root)
        task_id = "task-reconciliation-checkpoint"
        focus_id = "reconciliation-main"
        focus_label = "H7 reconciliation main line"
        initial_instruction = "Prepare the scoped reconciliation checkpoint."
        latest_instruction = "Continue the verified reconciliation repair on the active main line."
        evidence_path = project_root / "reconciliation-evidence.txt"
        evidence_path.write_text("reconciliation fixture evidence\n", encoding="utf-8")
        evidence = {
            "kind": "project_file",
            "relativePath": evidence_path.name,
            "sha256": file_sha256(evidence_path),
        }

        def encode(value: dict[str, object]) -> str:
            return base64.b64encode(
                json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            ).decode("ascii")

        seed_checkpoint = {
            "last_confirmed_sentence": "The scoped reconciliation fixture is ready.",
            "source": "assistant_visible_reply",
            "current_phase": "Reconciliation setup",
            "current_step": "Create the current H7 contract.",
            "next_action": "Bind the latest instruction through H7.",
        }
        seed_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": seed_checkpoint["current_phase"],
            "currentStep": seed_checkpoint["current_step"],
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": seed_checkpoint["next_action"],
        }
        seeded = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key,
                "-SessionKey", session_key, "-FocusId", focus_id, "-FocusLabel", focus_label,
                "-InstructionMode", "continue", "-LatestUserInstruction", initial_instruction,
                "-AssistantCommitment", "Keep the same scoped reconciliation workline verified.",
                "-ProjectRoot", str(project_root), "-ProjectProgressProofBase64", encode(seed_proof),
                "-ProgressCheckpointBase64", encode(seed_checkpoint), "-TransitionId", "reconciliation-seed",
                "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert seeded["needsReconciliation"] is False, seeded

        pending = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key,
                "-SessionKey", session_key, "-FocusId", focus_id, "-InstructionMode", "continue",
                "-LatestUserInstruction", latest_instruction, "-RequiresReconciliation",
                "-ExpectedRevision", str(seeded["revision"]),
                "-ExpectedPlanFingerprint", str(seeded["planReceipt"]["planFingerprint"]),
                "-TransitionId", "reconciliation-pending", "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert pending["needsReconciliation"] is True, pending

        checkpoint = {
            "last_confirmed_sentence": "The H7 checkpoint reconciled the current instruction and verified progress.",
            "source": "assistant_visible_reply",
            "current_phase": "Reconciliation repair",
            "current_step": "Bind the current instruction, focus, and project proof in one CAS transaction.",
            "next_action": "Reopen the reconciled main workline from current evidence.",
        }
        proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": checkpoint["current_phase"],
            "currentStep": checkpoint["current_step"],
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": checkpoint["next_action"],
        }

        core = BrainCore(ROOT, memory_root)
        with local_scope(project_root, session_key):
            ordinary_open = turn_runtime.open_turn(
                core,
                turn_intent="continuity",
            )
            missing_input = turn_runtime.checkpoint_turn(
                core,
                turn_intent="continuity",
                progress_checkpoint=checkpoint,
                project_progress_proof=proof,
                transition_id="reconciliation-checkpoint-missing-instruction",
            )
            after_missing_input = invoke_contract(
                [
                    "-Action", "Get", "-TaskId", task_id, "-WorkspaceKey", workspace_key,
                    "-SessionKey", session_key, "-StateRoot", str(state_root), "-Json",
                ]
            )
            checkpointed = turn_runtime.checkpoint_turn(
                core,
                turn_intent="continuity",
                progress_checkpoint=checkpoint,
                project_progress_proof=proof,
                latest_user_instruction=latest_instruction,
                transition_id="reconciliation-checkpoint",
            )
            after_checkpoint = invoke_contract(
                [
                    "-Action", "Get", "-TaskId", task_id, "-WorkspaceKey", workspace_key,
                    "-SessionKey", session_key, "-StateRoot", str(state_root), "-Json",
                ]
            )
            replayed = turn_runtime.checkpoint_turn(
                core,
                turn_intent="continuity",
                progress_checkpoint=checkpoint,
                project_progress_proof=proof,
                latest_user_instruction=latest_instruction,
                transition_id="reconciliation-checkpoint",
            )

    assert ordinary_open["available"] is False, ordinary_open
    assert ordinary_open["code"] == "BRAIN_CONTEXT_RECONCILIATION_REQUIRED", ordinary_open
    assert missing_input["available"] is False, missing_input
    assert missing_input["code"] == "H7_RECONCILIATION_CHECKPOINT_INPUT_REQUIRED", missing_input
    assert after_missing_input["needsReconciliation"] is True, after_missing_input
    assert after_missing_input["revision"] == pending["revision"], after_missing_input
    assert checkpointed["available"] is True, checkpointed
    assert checkpointed["code"] == "H7_RECONCILIATION_CHECKPOINT_READY", checkpointed
    assert checkpointed["checkpoint"]["ok"] is True, checkpointed
    assert after_checkpoint["needsReconciliation"] is False, after_checkpoint
    assert after_checkpoint["latestUserInstruction"] == latest_instruction, after_checkpoint
    assert after_checkpoint["focusId"] == focus_id, after_checkpoint
    assert after_checkpoint["lastConfirmedSentence"] == checkpoint["last_confirmed_sentence"], after_checkpoint
    assert replayed["available"] is True, replayed
    assert replayed["checkpoint"]["code"] == "H7_PROGRESS_CHECKPOINT_REPLAYED", replayed


def test_checkpoint_set_replay_is_never_misreported_as_a_parent_return() -> None:
    """A checkpoint and close must not share parent-return semantics."""

    calls: list[str] = []
    original = turn_close_dispatcher._invoke_contract

    def resolve_checkpoint_set_replay(*_args: object, action: str, **_kwargs: object) -> tuple[int, dict[str, object] | None]:
        calls.append(action)
        assert action == "Resolve", calls
        return 0, {
            "ok": True,
            "taskId": "task-close-checkpoint-collision",
            "actionAuthorization": "allowed",
            "claimAllowed": True,
            "needsConfirmation": False,
            "blockers": [],
            "nextAction": "No automatic action: await the user.",
            "canResumeParent": False,
            "transitionReceipts": [
                {"transitionId": "close-checkpoint-collision", "action": "Set", "resultRevision": 7}
            ],
        }

    turn_close_dispatcher._invoke_contract = resolve_checkpoint_set_replay
    try:
        result = turn_close_dispatcher.dispatch_turn_close(
            ROOT,
            ROOT / "private-state",
            task_id="task-close-checkpoint-collision",
            workspace_key="ws-" + "7" * 24,
            session_key="sid-" + "8" * 24,
            turn_outcome="active_work_progressed",
            user_control="none",
            completion_evidence_ref="fixture:checkpoint-set",
            transition_id="close-checkpoint-collision",
        )
    finally:
        turn_close_dispatcher._invoke_contract = original

    assert result["code"] == "TURN_CLOSE_DISPATCH_POLICY_ONLY", result
    assert result["policy"]["decision"] == "pause_with_blocker", result
    assert result["policy"]["requiresParentResume"] is False, result
    assert result["transition"] is None, result
    assert calls == ["Resolve"], calls


def main() -> int:
    test_open_is_idempotent_and_binds_typed_memory()
    test_memory_write_projects_exact_contract_authorization_and_fails_closed()
    test_native_capability_route_receipt_is_h7_bound_without_authorization()
    test_capability_route_receipt_rejects_paths_prompts_and_authorization()
    test_direct_execution_assist_is_h7_native_and_private()
    test_execution_assist_request_rejects_raw_fields_without_runtime_write()
    test_capability_route_hash_mismatch_withholds_h7_evidence()
    test_run_observability_tamper_withholds_h7_evidence()
    test_internal_unrecorded_open_preserves_current_h7_evidence()
    test_telemetry_requires_a_persisted_open_entry()
    test_close_checkpoint_preflight_failure_preserves_current_h7_evidence()
    test_h7_accepts_the_actual_compact_router_receipt()
    test_project_progress_proof_fails_closed_on_missing_or_drift()
    test_checkpoint_refreshes_only_a_stale_project_progress_proof_through_h7()
    test_close_resumes_parent_and_hashes_completion_reference()
    test_close_rejects_user_attested_checkpoint_outside_correction_without_mutation()
    test_checkpoint_scope_change_without_fresh_proof_fails_atomically()
    test_invalid_phase_fails_without_state_write()
    test_super_brain_issue_projects_root_rule_and_protocol()
    test_registry_change_stales_h7_evidence_until_reopened()
    test_checkpoint_reconciles_after_uncertain_set_result()
    test_checkpoint_retries_one_unacknowledged_transport_with_same_transition_id_and_timeout_floor()
    test_checkpoint_does_not_retry_a_rejected_cas_transaction()
    test_checkpoint_binds_current_instruction_and_projects_verified_canonical_completion()
    test_canonical_status_mutation_uses_four_key_scope_and_conflict_replay()
    test_checkpoint_instruction_mapping_uses_real_powershell_authority_and_replays_idempotently()
    test_checkpoint_is_the_only_h7_path_that_clears_a_pending_same_scope_contract()
    test_checkpoint_set_replay_is_never_misreported_as_a_parent_return()
    print("runtime turn-runtime regression: passed (29/29)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
