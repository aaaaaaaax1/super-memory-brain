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
from host_visible_tail import observe_visible_context_message, select_latest_assistant, select_latest_durable_assistant
from turn_runtime import MODE, RECEIPT_SCHEMA, TELEMETRY_SCHEMA, run_turn
import turn_close_dispatcher as turn_close_dispatcher


VISIBLE_RECEIPT_HASH_BY_HOST_SESSION: dict[str, str] = {}


def v4_progress_message(sentence: str, receipt_hash: str) -> str:
    return f"G1\n[H7-PROGRESS-V4 receipt_hash={receipt_hash}]\n{sentence}"


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def package_version() -> str:
    return str(json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["version"])


def host_workspace_key(path: Path) -> str:
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

    selected = ["sb.native.engineering.diagnosing-bugs.v1"] if state == "ready" else []
    contracts = ["sb.native.engineering.diagnosing-bugs.contract.v1"] if state == "ready" else []
    provenance: list[dict[str, str]] = (
        [{"capabilityId": selected[0], "provenanceHash": "a" * 64}] if selected else []
    )
    parity: list[dict[str, str]] = (
        [{"capabilityId": selected[0], "contractId": contracts[0], "parityHash": "b" * 64}] if selected else []
    )
    code = {
        "ready": "CAPABILITY_ROUTE_READY",
        "not_applicable": "CAPABILITY_ROUTE_NOT_APPLICABLE",
        "withheld": "CAPABILITY_ROUTE_WITHHELD",
    }[state]
    route_input = {
        "schema": "super-brain.capability-route-receipt.v1",
        "state": state,
        "code": code,
        "selectedNativeCapabilityIds": selected,
        "nativeContractIds": contracts,
        "provenanceHashes": provenance,
        "parityHashes": parity,
        # The router owns the exact routeHash recipe. H7 treats this as an
        # opaque, 64-hex identity and binds it to its own selection hash.
        "routeHash": canonical_hash({"routerFixture": "native-capability-route", "state": state}),
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
    }
    return route_input


def visible_tail_assertion(
    *,
    host_thread_id: str,
    sentence: str,
    phase: str,
    current_step: str,
    next_action: str,
    host_turn_id: str = "019fe035-b8ac-73e2-947c-6f6fd16cdc65",
    host_message_id: str = "item-visible-progress-fixture",
    message_phase: str = "commentary",
    selection: str = "current_visible_assistant",
    publication_kind: str = "",
    receipt_hash: str = "",
    legacy: bool = False,
    observation_source: str = "codex_app_read_thread",
) -> dict[str, object]:
    # Host extraction owns which visible item is latest.  H7 derives phase,
    # step, and next action from its current scoped contract, so fixtures may
    # not smuggle those values through the observation.
    resolved_receipt_hash = receipt_hash or VISIBLE_RECEIPT_HASH_BY_HOST_SESSION.get(host_thread_id, "")
    if not legacy and resolved_receipt_hash:
        return {
            "schema": "super-brain.visible-tail-observation.v4",
            "observation_source": observation_source,
            "selection": selection,
            "host_thread_id": host_thread_id,
            "host_turn_id": host_turn_id,
            "host_message_id": host_message_id,
            "message_phase": message_phase,
            "last_confirmed_sentence": sentence,
            "source": "assistant_visible_reply",
            "publication_kind": "h7_durable_progress",
            "envelope_version": "v4",
            "h7_receipt_hash": resolved_receipt_hash,
            "raw_prompt_stored": False,
            "raw_transcript_stored": False,
        }
    observation = {
        "schema": "super-brain.visible-tail-observation.v3" if publication_kind else "super-brain.visible-tail-observation.v2",
        "observation_source": observation_source,
        "selection": selection,
        "host_thread_id": host_thread_id,
        "host_turn_id": host_turn_id,
        "host_message_id": host_message_id,
        "message_phase": message_phase,
        "last_confirmed_sentence": sentence,
        "source": "assistant_visible_reply",
        "raw_prompt_stored": False,
        "raw_transcript_stored": False,
    }
    if publication_kind:
        observation["publication_kind"] = publication_kind
    return observation


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
                    "conditions": ["A unique Host scope is verified."],
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


def write_context_contract(state_root: Path, host_root: Path, session_key: str, task_id: str = "task-turn-runtime") -> None:
    workspace = state_root / "workspace"
    workspace_key = host_workspace_key(host_root)
    timestamp = now()
    contract_name = contract_file_name(task_id, workspace_key)
    evidence_path = host_root / "project-progress-evidence.txt"
    evidence_path.write_text("project progress proof fixture\n", encoding="utf-8")
    evidence = {"kind": "project_file", "relativePath": evidence_path.name, "sha256": file_sha256(evidence_path)}
    sentence = "R0 is verified; return to the source-evidence parent workline."
    phase = "Fixture"
    current_step = "Open the governed turn."
    next_action = "Run the local runtime verification."
    proof = project_progress_proof(
        host_root,
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
    VISIBLE_RECEIPT_HASH_BY_HOST_SESSION[session_key] = str(contract["visibleProgressReceipt"]["payloadHash"])


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


def with_host_scope(host_root: Path, session_key: str):
    class Scope:
        def __enter__(self):
            self.previous_thread = os.environ.get("CODEX_THREAD_ID")
            self.previous_cwd = Path.cwd()
            os.environ["CODEX_THREAD_ID"] = session_key
            os.chdir(host_root)

        def __exit__(self, *_: object) -> None:
            os.chdir(self.previous_cwd)
            if self.previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = self.previous_thread

    return Scope()


def test_open_is_idempotent_and_binds_typed_memory() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-open-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "2" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key)
        core = BrainCore(ROOT, memory_root)

        with with_host_scope(host_root, session_key):
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
        assert first["context"]["coreRules"]["applicableRuleIds"] == [
            "SB-PROJECT-GROUNDED-DESIGN-001",
            "SB-PROGRESS-TRUTH-001",
            "SB-PROPOSAL-GATE-001",
            "SB-INDEPENDENT-CONTROL-PLANE-AGENT-001",
        ]
        assert first["runtimeReceipt"]["memory"]["snapshotPayloadHash"]
        assert first["runtimeReceipt"]["activation"]["receiptHash"]
        assert first["context"]["agentIdentity"]["kind"] == "independent_control_plane_agent"
        assert first["context"]["authorityModel"]["objectiveAuthority"] == "latest_user_instruction"
        assert first["context"]["authorityModel"]["executionAuthority"] == "h7_scope_bound_execution_contract"
        assert first["context"]["authorityModel"]["progressAuthority"] == "assistant_visible_reply_plus_current_project_progress_proof"
        assert first["context"]["authorityModel"]["supplementalOnly"] == [
            "typed_memory", "absorbed_capabilities", "bounded_collaborator_agents"
        ]
        assert first["context"]["authorityModel"]["hostAdapterAuthority"] == "entry_only_non_authorizing"
        assert first["runtimeReceipt"]["agentIdentity"] == first["context"]["agentIdentity"]
        assert first["runtimeReceipt"]["authorityModel"] == first["context"]["authorityModel"]
        assert "capabilityRouteReceipt" not in first["runtimeReceipt"]
        assert first["runtimeReceipt"]["coreRules"]["applicableRuleIds"] == [
            "SB-PROJECT-GROUNDED-DESIGN-001",
            "SB-PROGRESS-TRUTH-001",
            "SB-PROPOSAL-GATE-001",
            "SB-INDEPENDENT-CONTROL-PLANE-AGENT-001",
        ]
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
        serialized = json.dumps({"receipt": receipt, "telemetry": telemetry}, ensure_ascii=False)
        assert "rawPromptStored\":true" not in serialized
        assert "rawTranscriptStored\":true" not in serialized


def test_native_capability_route_receipt_is_h7_bound_without_authorization() -> None:
    """H7 binds only the router's safe native-capability proof and its hashes."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-capability-route-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "c" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id="task-native-capability-route")
        core = BrainCore(ROOT, memory_root)
        route_receipt = native_capability_route_receipt()

        with with_host_scope(host_root, session_key):
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
        assert selection["selectedNativeCapabilityIds"] == ["sb.native.engineering.diagnosing-bugs.v1"], selection
        assert selection["nativeContractIds"] == ["sb.native.engineering.diagnosing-bugs.contract.v1"], selection
        assert selection["provenanceHashes"][0]["provenanceHash"] == "a" * 64, selection
        assert selection["parityHashes"][0]["parityHash"] == "b" * 64, selection
        assert selection["selectionHash"] == canonical_hash(route_receipt), selection
        assert selection["nonAuthorizing"] is True, selection
        assert "actionAuthorization" not in selection, selection
        assert opened["runtimeReceipt"]["activation"]["actionAuthorization"] == "withheld", opened
        assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
        assert evidence["capabilityRouteReceipt"] == selection, evidence

        scope_ref_value = opened["context"]["scope"]["scopeRef"]
        receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "open.json"
        telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        assert receipt["capabilityRouteReceipt"] == selection, receipt
        latest = telemetry["events"][-1]
        assert latest["capabilityRouteHash"] == route_receipt["routeHash"], latest
        assert latest["capabilitySelectionHash"] == selection["selectionHash"], latest
        assert latest["capabilityRouteNonAuthorizing"] is True, latest
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
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
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
                str(host_root),
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
            "rawTranscriptStored", "sourcePathsOmitted",
        }, route_receipt
        assert route_receipt["state"] == "ready", route_receipt
        assert route_receipt["selectedNativeCapabilityIds"], route_receipt
        assert len(route_receipt["provenanceHashes"]) == len(route_receipt["selectedNativeCapabilityIds"]), route_receipt
        assert len(route_receipt["parityHashes"]) == len(route_receipt["selectedNativeCapabilityIds"]), route_receipt

        session_key = "sid-" + "f" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id="task-router-to-h7")
        core = BrainCore(ROOT, memory_root)
        with with_host_scope(host_root, session_key):
            opened = run_turn(
                core,
                phase="open",
                turn_intent="design_evaluate",
                capability_route_receipt=route_receipt,
            )
            evidence = run_turn(core, phase="evidence")

        assert opened["available"] is True, opened
        selection = opened["runtimeReceipt"]["capabilityRouteReceipt"]
        assert selection["selectionHash"] == canonical_hash(route_receipt), selection
        assert selection["parityHashes"] == route_receipt["parityHashes"], selection
        assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
        serialized = json.dumps({"selection": selection, "evidence": evidence}, ensure_ascii=False)
        assert router_query not in serialized
        assert str(host_root) not in serialized
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
            host_root = Path(directory) / "host"
            memory_root.mkdir(parents=True)
            host_root.mkdir()
            (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
            session_key = "sid-" + "d" * 24
            write_native_memory_snapshot(state_root / "workspace")
            write_context_contract(state_root, host_root, session_key, task_id=f"task-capability-route-{field.lower()}")
            route_receipt = native_capability_route_receipt()
            route_receipt[field] = value
            core = BrainCore(ROOT, memory_root)
            with with_host_scope(host_root, session_key):
                result = run_turn(
                    core,
                    phase="open",
                    turn_intent="design_evaluate",
                    capability_route_receipt=route_receipt,
                )
            assert result["available"] is False, result
            assert result["code"] == "H7_CAPABILITY_ROUTE_RECEIPT_FIELDS_INVALID", result
            assert not (state_root / "workspace" / "runtime-state" / "turn-runtime").exists(), result


def test_capability_route_hash_mismatch_withholds_h7_evidence() -> None:
    """Receipt and telemetry must agree on the H7-computed selection hash."""

    with tempfile.TemporaryDirectory(prefix="super-brain-capability-route-mismatch-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "e" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id="task-capability-route-mismatch")
        core = BrainCore(ROOT, memory_root)
        route_receipt = native_capability_route_receipt()

        with with_host_scope(host_root, session_key):
            opened = run_turn(core, phase="open", turn_intent="design_evaluate", capability_route_receipt=route_receipt)
        scope_ref_value = opened["context"]["scope"]["scopeRef"]
        receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "open.json"
        telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        pristine_telemetry = json.loads(json.dumps(telemetry))
        telemetry["events"][-1]["capabilitySelectionHash"] = "0" * 64
        telemetry["payloadHash"] = canonical_hash({key: item for key, item in telemetry.items() if key != "payloadHash"})
        write_json(telemetry_path, telemetry)
        with with_host_scope(host_root, session_key):
            telemetry_mismatch = run_turn(core, phase="evidence")
        assert telemetry_mismatch["code"] == "H7_EVIDENCE_INCOMPLETE", telemetry_mismatch
        assert telemetry_mismatch["entry"]["current"] is True, telemetry_mismatch
        assert telemetry_mismatch["telemetry"]["current"] is False, telemetry_mismatch

        write_json(telemetry_path, pristine_telemetry)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["capabilityRouteReceipt"]["selectionHash"] = "0" * 64
        receipt["receiptHash"] = canonical_hash({key: item for key, item in receipt.items() if key != "receiptHash"})
        write_json(receipt_path, receipt)
        with with_host_scope(host_root, session_key):
            receipt_mismatch = run_turn(core, phase="evidence")
        assert receipt_mismatch["code"] == "H7_EVIDENCE_INCOMPLETE", receipt_mismatch
        assert receipt_mismatch["entry"]["current"] is False, receipt_mismatch


def test_project_progress_proof_fails_closed_on_missing_or_drift() -> None:
    """A project claim needs a current proof every time, not just at receipt creation."""

    with tempfile.TemporaryDirectory(prefix="super-brain-project-progress-proof-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "a" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id="task-project-progress-proof")
        core = BrainCore(ROOT, memory_root)

        with with_host_scope(host_root, session_key):
            opened = run_turn(core, phase="open", turn_intent="design_evaluate")
            assert opened["available"] is True, opened
            proof = opened["runtimeReceipt"]["progressTruth"]
            assert proof["state"] == "current", proof
            evidence = run_turn(core, phase="evidence")
            assert evidence["code"] == "H7_EVIDENCE_CURRENT", evidence
            (host_root / "project-progress-evidence.txt").write_text("drifted after receipt\n", encoding="utf-8")
            drifted = run_turn(core, phase="evidence")

        assert drifted["available"] is False, drifted
        assert drifted["code"] == "H7_PROJECT_PROGRESS_WITHHELD", drifted
        assert drifted["projectProgress"]["state"] == "withheld", drifted
        assert "project_evidence_hash" in drifted["projectProgress"]["missing"], drifted
        serialized = json.dumps({"opened": opened, "drifted": drifted}, ensure_ascii=False)
        assert str(host_root) not in serialized
        assert str(ROOT) not in serialized

    with tempfile.TemporaryDirectory(prefix="super-brain-project-progress-missing-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "b" * 24
        write_native_memory_snapshot(state_root / "workspace")
        task_id = "task-project-progress-missing"
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        workspace_key = host_workspace_key(host_root)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, workspace_key)
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        contract.pop("projectProgressProof", None)
        write_json(contract_path, contract)
        core = BrainCore(ROOT, memory_root)

        with with_host_scope(host_root, session_key):
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
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "c" * 24
        workspace_key = host_workspace_key(host_root)
        task_id = "task-project-progress-refresh"
        evidence_path = host_root / "project-progress-evidence.txt"
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
                "-PendingSteps", "Run the local runtime verification.", "-ProjectRoot", str(host_root),
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

        with with_host_scope(host_root, session_key):
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
        assert str(host_root) not in serialized
        assert "rawPromptStored\":true" not in serialized
        assert "rawTranscriptStored\":true" not in serialized


def test_observed_visible_tail_must_match_the_checkpoint_before_reconcile() -> None:
    """Correct the current anchor first, without accepting a guessed sentence."""

    with tempfile.TemporaryDirectory(prefix="super-brain-visible-tail-checkpoint-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "f" * 24
        task_id = "task-observed-visible-tail-checkpoint"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        evidence_path = host_root / "project-progress-evidence.txt"
        progress = {
            "last_confirmed_sentence": "The observed current tail is now the only valid continuation anchor.",
            "source": "assistant_visible_reply",
            "current_phase": "Continuation repair",
            "current_step": "Bind the observed Host tail before accepting the corrected progress state.",
            "next_action": "Run the automatic tail-selection replay before resuming the main line.",
        }
        proof = {
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
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, host_workspace_key(host_root))
        before = json.loads(contract_path.read_text(encoding="utf-8"))
        core = BrainCore(ROOT, memory_root)
        correct_tail = visible_tail_assertion(
            host_thread_id=session_key,
            sentence=progress["last_confirmed_sentence"],
            phase=progress["current_phase"],
            current_step=progress["current_step"],
            next_action=progress["next_action"],
            host_message_id="item-observed-current-tail",
            selection="current_visible_assistant",
            observation_source="codex_visible_context",
        )
        wrong_tail = {**correct_tail, "last_confirmed_sentence": "A guessed sentence must not rewrite the anchor."}

        with with_host_scope(host_root, session_key):
            rejected = run_turn(
                core,
                phase="checkpoint",
                turn_intent="super_brain_issue_continuity",
                progress_checkpoint=progress,
                project_progress_proof=proof,
                visible_progress_assertion=wrong_tail,
                transition_id="observed-tail-reject-fixture",
            )
            after_rejected = json.loads(contract_path.read_text(encoding="utf-8"))
            corrected = run_turn(
                core,
                phase="checkpoint",
                turn_intent="super_brain_issue_continuity",
                progress_checkpoint=progress,
                project_progress_proof=proof,
                visible_progress_assertion=correct_tail,
                transition_id="observed-tail-correct-fixture",
            )
            recovery_tail = {
                **correct_tail,
                "h7_receipt_hash": str((corrected.get("checkpoint") or {}).get("visibleProgress", {}).get("payloadHash", "")),
                "host_message_id": "item-observed-current-tail-republished",
            }
            recovered = run_turn(
                core,
                phase="open",
                turn_intent="continuity",
                recovery_event="user_correction",
                visible_progress_assertion=recovery_tail,
            )

        assert rejected["available"] is False, rejected
        assert rejected["code"] == "H7_VISIBLE_TAIL_ASSERTION_CHECKPOINT_MISMATCH", rejected
        assert after_rejected["revision"] == before["revision"], (before, after_rejected)
        assert corrected["available"] is True, corrected
        assert corrected["visibleTailAssertion"]["state"] == "current", corrected
        assert "current_phase" not in correct_tail, correct_tail
        assert "current_step" not in correct_tail, correct_tail
        assert "next_action" not in correct_tail, correct_tail
        assert recovered["available"] is True, recovered
        assert recovered["context"]["task"]["lastConfirmedSentence"] == progress["last_confirmed_sentence"], recovered
        assert recovered["recoveryPresentation"]["openingLine"] == "已接上：" + progress["last_confirmed_sentence"], recovered


def test_latest_assistant_progress_reconciles_without_user_anchor_selection() -> None:
    """A recovery binds the actual latest agent reply, not a pre-user anchor."""

    with tempfile.TemporaryDirectory(prefix="super-brain-preopen-anchor-block-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "9" * 24
        task_id = "task-preopen-anchor-block"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        evidence_path = host_root / "project-progress-evidence.txt"
        corrected_sentence = "The newer visible reply must be checkpointed before any recovery can continue."
        payload = {
            "thread": {"id": session_key},
            "page": {"order": "newest_first"},
            "turns": [
                {
                    "id": "turn-preopen-anchor",
                    "items": [
                        {"type": "userMessage", "id": "user-start"},
                        {
                            "type": "agentMessage",
                            "id": "item-old-anchor",
                            "phase": "commentary",
                            "text": "The old anchor must never replace a newer visible reply.",
                        },
                        {"type": "userMessage", "id": "user-current"},
                        {
                            "type": "agentMessage",
                            "id": "item-newer-unbound-reply",
                            "phase": "commentary",
                            "text": corrected_sentence,
                        },
                    ],
                }
            ],
        }
        observed_result = select_latest_assistant(payload)
        assert observed_result["ok"] is True, observed_result
        assert observed_result["last_confirmed_sentence"] == corrected_sentence, observed_result
        observed = {key: value for key, value in observed_result.items() if key != "ok"}
        progress = {
            "last_confirmed_sentence": corrected_sentence,
            "source": "assistant_visible_reply",
            "current_phase": "Continuation correction",
            "current_step": "Bind the visible reply before any normal recovery selection.",
            "next_action": "Run the fresh-tail recovery replay from the H7-corrected receipt.",
        }
        proof = {
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
        core = BrainCore(ROOT, memory_root)
        with with_host_scope(host_root, session_key):
            corrected = run_turn(
                core,
                phase="checkpoint",
                turn_intent="super_brain_issue_continuity",
                progress_checkpoint=progress,
                project_progress_proof=proof,
                visible_progress_assertion=observed,
                transition_id="preopen-anchor-correction-fixture",
            )
            corrected_receipt_hash = str((corrected.get("checkpoint") or {}).get("visibleProgress", {}).get("payloadHash", ""))
            payload["turns"][0]["items"].append(
                {
                    "type": "agentMessage",
                    "id": "item-newer-republished-v4",
                    "phase": "commentary",
                    "text": f"G1\n[H7-PROGRESS-V4 receipt_hash={corrected_receipt_hash}]\n{corrected_sentence}",
                }
            )
            payload["turns"][0]["items"].append({"type": "userMessage", "id": "user-after-correction"})
            recovered_result = select_latest_durable_assistant(payload)
            assert recovered_result["ok"] is True, recovered_result
            recovered_assertion = {key: value for key, value in recovered_result.items() if key != "ok"}
            recovered = run_turn(
                core,
                phase="open",
                turn_intent="continuity",
                recovery_event="compaction",
                visible_progress_assertion=recovered_assertion,
            )

        assert corrected["available"] is True, corrected
        assert recovered_assertion["host_message_id"] == "item-newer-republished-v4", recovered_assertion
        assert recovered["available"] is True, recovered
        assert recovered["context"]["task"]["lastConfirmedSentence"] == corrected_sentence, recovered
        assert recovered["recoveryPresentation"]["openingLine"] == "\u5df2\u63a5\u4e0a\uff1a" + corrected_sentence, recovered


def test_newer_preopen_assistant_message_blocks_walkback_to_older_durable_tail() -> None:
    """A newer visible assistant message must block, never revive an older v4 tail."""

    with tempfile.TemporaryDirectory(prefix="super-brain-durable-tail-preopen-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "d" * 24
        task_id = "task-durable-tail-preopen"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        payload = {
            "thread": {"id": session_key},
            "page": {"order": "newest_first"},
            "turns": [{
                "id": "turn-durable-tail-preopen",
                "items": [
                    {"type": "userMessage", "id": "user-continue"},
                    {
                        "type": "agentMessage",
                        "id": "item-current-durable",
                        "phase": "commentary",
                        "text": v4_progress_message(
                            "R0 is verified; return to the source-evidence parent workline.",
                            VISIBLE_RECEIPT_HASH_BY_HOST_SESSION[session_key],
                        ),
                    },
                    {
                        "type": "agentMessage",
                        "id": "item-preopen-commentary",
                        "phase": "commentary",
                        "text": "I will first inspect the current H7 receipt before continuing.",
                    },
                ],
            }],
        }
        observed = select_latest_durable_assistant(payload)
        assert observed["ok"] is False, observed
        assert observed["code"] == "HOST_VISIBLE_TAIL_NEWER_UNPUBLISHED_ASSISTANT_MESSAGE", observed
        return


def test_open_auto_finalizes_latest_durable_visible_tail_without_walkback() -> None:
    """A real newer H7-marked reply is finalized before normal recovery.

    This is the user-level replay for the historical drift: the contract still
    contains an older receipt, but the Host's deterministic tail has a newer
    assistant-visible reply before the new user instruction.  H7 may move only
    the sentence; stage, step, action, and verified project proof remain the
    current contract's values.
    """

    with tempfile.TemporaryDirectory(prefix="super-brain-auto-visible-tail-finalize-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "c" * 24
        task_id = "task-auto-visible-tail-finalize"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = (
            state_root
            / "workspace"
            / "runtime-state"
            / "execution-contracts"
            / contract_file_name(task_id, host_workspace_key(host_root))
        )
        before = json.loads(contract_path.read_text(encoding="utf-8"))
        newer_sentence = "The exact latest durable assistant-visible reply is finalized before continuation."
        payload = {
            "thread": {"id": session_key},
            "page": {"order": "oldest_first"},
            "turns": [
                {
                    "id": "turn-auto-finalize",
                    "items": [
                        {"type": "userMessage", "id": "user-before-progress"},
                        {
                            "type": "agentMessage",
                            "id": "item-old-contract-progress",
                            "phase": "commentary",
                            "text": v4_progress_message(
                                str(before["lastConfirmedSentence"]),
                                str(before["visibleProgressReceipt"]["payloadHash"]),
                            ),
                        },
                        {
                            "type": "agentMessage",
                            "id": "item-new-durable-progress",
                            "phase": "commentary",
                            "text": v4_progress_message(
                                newer_sentence,
                                str(before["visibleProgressReceipt"]["payloadHash"]),
                            ),
                        },
                        {"type": "userMessage", "id": "user-resume"},
                    ],
                }
            ],
        }
        observed = select_latest_assistant(payload)
        assert observed["ok"] is True, observed
        assert observed["host_message_id"] == "item-new-durable-progress", observed
        assert observed["publication_kind"] == "h7_durable_progress", observed
        assertion = {key: value for key, value in observed.items() if key != "ok"}

        with with_host_scope(host_root, session_key):
            recovered = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="restart",
                visible_progress_assertion=assertion,
            )

        after = json.loads(contract_path.read_text(encoding="utf-8"))
        assert recovered["available"] is False, recovered
        assert recovered["code"] == "H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED", recovered
        assert int(after["revision"]) == int(before["revision"]), (before, after)
        assert after["visibleProgressReceipt"]["sentenceHash"] == before["visibleProgressReceipt"]["sentenceHash"], after


def test_normal_durable_selection_never_auto_aligns_and_explicit_fallback_does() -> None:
    """Keep auto receipt alignment as a drift fallback, never the normal route."""

    with tempfile.TemporaryDirectory(prefix="super-brain-durable-fallback-boundary-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "e" * 24
        task_id = "task-durable-fallback-boundary"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = (
            state_root
            / "workspace"
            / "runtime-state"
            / "execution-contracts"
            / contract_file_name(task_id, host_workspace_key(host_root))
        )
        before = json.loads(contract_path.read_text(encoding="utf-8"))
        old_sentence = str(before["lastConfirmedSentence"])
        newer_sentence = "A newer durable reply is adopted only by the explicit drift fallback."
        payload = {
            "thread": {"id": session_key},
            "page": {"order": "oldest_first"},
            "turns": [
                {
                    "id": "turn-durable-boundary",
                    "items": [
                        {"type": "userMessage", "id": "user-before"},
                        {
                            "type": "agentMessage",
                            "id": "item-current-durable",
                            "phase": "commentary",
                            "text": v4_progress_message(
                                old_sentence,
                                str(before["visibleProgressReceipt"]["payloadHash"]),
                            ),
                        },
                        {"type": "userMessage", "id": "user-resume"},
                    ],
                }
            ],
        }

        normal_observed = select_latest_durable_assistant(payload)
        assert normal_observed["ok"] is True, normal_observed
        normal_assertion = {key: value for key, value in normal_observed.items() if key != "ok"}
        with with_host_scope(host_root, session_key):
            normal = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="restart",
                visible_progress_assertion=normal_assertion,
            )
        assert normal["available"] is True, normal
        assert normal["autoVisibleTailFinalization"] == {}, normal

        payload["turns"][0]["items"].insert(
            3,
            {
                "type": "agentMessage",
                "id": "item-newer-durable",
                "phase": "commentary",
                "text": v4_progress_message(
                    newer_sentence,
                    str(before["visibleProgressReceipt"]["payloadHash"]),
                ),
            },
        )
        drift_observed = select_latest_durable_assistant(payload)
        assert drift_observed["ok"] is True, drift_observed
        assert drift_observed["host_message_id"] == "item-newer-durable", drift_observed
        drift_assertion = {key: value for key, value in drift_observed.items() if key != "ok"}
        before_drift = json.loads(contract_path.read_text(encoding="utf-8"))
        with with_host_scope(host_root, session_key):
            normal_path_drift = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="restart",
                visible_progress_assertion=drift_assertion,
            )
        after_drift = json.loads(contract_path.read_text(encoding="utf-8"))
        assert normal_path_drift["available"] is False, normal_path_drift
        assert normal_path_drift["code"] == "H7_VISIBLE_TAIL_ASSERTION_MISMATCH", normal_path_drift
        assert int(after_drift["revision"]) == int(before_drift["revision"]), (before_drift, after_drift)

        fallback_observed = select_latest_assistant(payload)
        assert fallback_observed["ok"] is True, fallback_observed
        assert fallback_observed["selection"] == "latest_assistant", fallback_observed
        fallback_assertion = {key: value for key, value in fallback_observed.items() if key != "ok"}
        with with_host_scope(host_root, session_key):
            fallback = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="restart",
                visible_progress_assertion=fallback_assertion,
            )
        assert fallback["available"] is False, fallback
        assert fallback["code"] == "H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED", fallback


def test_close_resumes_parent_and_hashes_completion_reference() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-close-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "3" * 24
        workspace_key = host_workspace_key(host_root)
        task_id = "task-turn-runtime-close"
        evidence_path = host_root / "close-progress-evidence.txt"
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
                "-ProjectRoot", str(host_root), "-ProjectProgressProofBase64", parent_proof_base64,
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
                "-ProjectRoot", str(host_root), "-ProjectProgressProofBase64", side_proof_base64,
                "-ProgressCheckpointBase64", side_checkpoint_base64,
                "-TransitionId", "open-turn-runtime-side", "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert side["ok"] is True
        write_native_memory_snapshot(state_root / "workspace")
        core = BrainCore(ROOT, memory_root)
        marker = "raw-user-text-must-not-be-persisted"

        with with_host_scope(host_root, session_key):
            opened = run_turn(core, phase="open")
            closed = run_turn(
                core,
                phase="close",
                turn_outcome="side_branch_completed",
                user_control="none",
                completion_evidence_ref=marker,
                transition_id="turn-runtime-close-side",
            )
            parent_task = closed["context"]["task"]
            parent_recovered = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="parent_return",
            )

        assert opened["available"] is True
        assert closed["ok"] is True
        assert closed["continuation"]["decision"] == "resume_parent_required", closed
        assert closed["transition"]["action"] == "ResumeParent"
        assert closed["mustContinue"] is True
        assert closed["terminalReplyAllowed"] is False
        assert parent_recovered["available"] is True, parent_recovered
        assert parent_recovered["context"]["parentReturnStateCard"]["state"] == "current", parent_recovered
        assert parent_recovered["visibleTailAssertion"] == {}, parent_recovered
        assert parent_recovered["recoveryPresentation"]["event"] == "parent_return", parent_recovered
        assert parent_recovered["recoveryPresentation"]["openingLine"] == (
            "已接上：" + parent_task["lastConfirmedSentence"]
        ), parent_recovered
        scope_ref_value = closed["context"]["scope"]["scopeRef"]
        receipt_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "receipts" / scope_ref_value / "close.json"
        telemetry_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref_value}.json"
        receipt_text = receipt_path.read_text(encoding="utf-8")
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        assert marker not in receipt_text
        assert marker not in telemetry_path.read_text(encoding="utf-8")
        assert marker not in (state_root / "workspace" / "last-execution-contract.json").read_text(encoding="utf-8")
        assert [event["phase"] for event in telemetry["events"]] == ["open", "close", "open"]


def test_checkpoint_binds_latest_assistant_progress_across_restart() -> None:
    """The durable H7 checkpoint, not a stale summary, wins after recovery.

    This replays the exact continuity failure: an older task projection says
    ``R0`` while the most recent assistant progress moved the work back to the
    H7 repair route.  A non-state insertion must not overwrite that checkpoint,
    and a fresh runtime instance must recover the newer progress verbatim.
    """

    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-progress-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "6" * 24
        write_native_memory_snapshot(state_root / "workspace")
        workspace_key = host_workspace_key(host_root)
        task_id = "task-turn-runtime-progress"
        evidence_path = host_root / "continuity-progress-evidence.txt"
        evidence_path.write_text("continuity progress proof fixture\n", encoding="utf-8")
        evidence = {"kind": "project_file", "relativePath": evidence_path.name, "sha256": file_sha256(evidence_path)}
        initial_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": "R0 source audit",
            "currentStep": "read the older source record",
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": "read the source-evidence parent record",
        }
        initial_proof_base64 = base64.b64encode(
            json.dumps(initial_proof, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        seeded = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", "hookless-continuity", "-FocusLabel", "Hookless continuity", "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue the approved H7 continuity repair", "-CurrentPhase", "R0 source audit",
                "-CurrentStep", "read the older source record", "-LastConfirmedSentence", "R0 is verified; return to the source-evidence parent workline.",
                "-LastConfirmedSource", "assistant_commitment", "-NextAction", "read the source-evidence parent record",
                "-PendingSteps", "read the source-evidence parent record", "-ProjectRoot", str(host_root),
                "-ProjectProgressProofBase64", initial_proof_base64, "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert seeded["ok"] is True
        progress = {
            "last_confirmed_sentence": (
                "旧 Hook 兼容补丁已撤回；续接仅走 H7 无 Hook 权威路径。"
            ),
            "source": "assistant_visible_reply",
            "current_phase": "H7 无 Hook 续接修复",
            "current_step": "先持久化最新助手进度，再解释下一条用户消息。",
            "next_action": "运行 H7 检查点恢复回归，然后回到无 Hook 修复主线。",
        }
        refreshed_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": progress["current_phase"],
            "currentStep": progress["current_step"],
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": progress["next_action"],
        }
        core = BrainCore(ROOT, memory_root)

        with with_host_scope(host_root, session_key):
            checkpointed = run_turn(
                core,
                phase="checkpoint",
                turn_intent="continuity",
                progress_checkpoint=progress,
                project_progress_proof=refreshed_proof,
            )
            side = run_turn(core, phase="open", turn_intent="side_message")

        restarted_core = BrainCore(ROOT, memory_root)
        with with_host_scope(host_root, session_key):
            recovered = run_turn(
                restarted_core,
                phase="open",
                turn_intent="continuity",
                recovery_event="restart",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=progress["last_confirmed_sentence"],
                    phase=progress["current_phase"],
                    current_step=progress["current_step"],
                    next_action=progress["next_action"],
                    selection="current_visible_assistant",
                    receipt_hash=str((checkpointed.get("checkpoint") or {}).get("visibleProgress", {}).get("payloadHash", "")),
                ),
            )

        assert checkpointed["available"] is True, checkpointed
        assert checkpointed["code"] == "H7_VISIBLE_PROGRESS_RECEIPT_RECONCILED_READY", checkpointed
        assert checkpointed["checkpoint"]["stateMutated"] is True, checkpointed
        assert side["code"] == "TURN_INTENT_DIRECT_HOST_PATH", side
        assert recovered["context"]["task"]["lastConfirmedSentence"] == progress["last_confirmed_sentence"], recovered
        assert recovered["context"]["task"]["lastConfirmedSource"] == "assistant_visible_reply", recovered
        assert recovered["context"]["task"]["currentPhase"] == progress["current_phase"], recovered
        assert recovered["context"]["task"]["currentStep"] == progress["current_step"], recovered
        assert recovered["context"]["task"]["nextAction"] == progress["next_action"], recovered
        assert recovered["recoveryPresentation"]["event"] == "restart", recovered
        assert recovered["recoveryPresentation"]["openingLine"] == (
            "已接上：" + progress["last_confirmed_sentence"]
        ), recovered
        assert recovered["runtimeReceipt"]["coreRules"]["applicableRuleIds"] == [
            "SB-LATEST-STATE-001",
            "SB-VISIBLE-PROGRESS-ANCHOR-001",
            "SB-PROGRESS-TRUTH-001",
            "SB-PROPOSAL-GATE-001",
            "SB-AUTO-RESUME-001",
            "SB-H7-ACTIVATION-001",
            "SB-INDEPENDENT-CONTROL-PLANE-AGENT-001",
        ], recovered
        persisted = (state_root / "workspace" / "last-execution-contract.json").read_text(encoding="utf-8")
        assert progress["last_confirmed_sentence"] in persisted
        assert "raw-user-text-must-not-be-persisted" not in persisted


def test_model_switch_reopens_same_scoped_h7_anchor_without_model_state() -> None:
    """A model replacement is a fresh runtime, not a new continuation state.

    The host keeps the same Codex thread/workspace/session while the runtime
    object is recreated, which is the observable contract of a model switch.
    H7 must recover the exact visible sentence in both processes and must not
    persist either host message id or any model-specific state.
    """

    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-model-switch-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "b" * 24
        task_id = "task-turn-runtime-model-switch"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = (
            state_root
            / "workspace"
            / "runtime-state"
            / "execution-contracts"
            / contract_file_name(task_id, host_workspace_key(host_root))
        )
        before_contract = contract_path.read_bytes()
        contract = json.loads(before_contract)
        progress = {
            "sentence": str(contract["lastConfirmedSentence"]),
            "phase": str(contract["currentPhase"]),
            "step": str(contract["currentStep"]),
            "action": str(contract["nextAction"]),
        }

        with with_host_scope(host_root, session_key):
            model_a = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="model_switch",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=progress["sentence"],
                    phase=progress["phase"],
                    current_step=progress["step"],
                    next_action=progress["action"],
                    host_message_id="item-model-a-visible-tail",
                    selection="current_visible_assistant",
                ),
            )
            # Recreating BrainCore represents switching models while the
            # Codex thread and scoped contract remain unchanged.
            model_b = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="model_switch",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=progress["sentence"],
                    phase=progress["phase"],
                    current_step=progress["step"],
                    next_action=progress["action"],
                    host_message_id="item-model-b-visible-tail",
                    selection="current_visible_assistant",
                ),
            )
            continuous = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=progress["sentence"],
                    phase=progress["phase"],
                    current_step=progress["step"],
                    next_action=progress["action"],
                    host_message_id="item-continuous-visible-tail",
                    selection="current_visible_assistant",
                ),
            )
            invalid = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="summary_guess",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=progress["sentence"],
                    phase=progress["phase"],
                    current_step=progress["step"],
                    next_action=progress["action"],
                    host_message_id="item-invalid-recovery-event",
                    selection="current_visible_assistant",
                ),
            )

        assert model_a["available"] is True, model_a
        assert model_b["available"] is True, model_b
        for result in (model_a, model_b):
            task = result["context"]["task"]
            assert task["lastConfirmedSentence"] == progress["sentence"], result
            assert task["currentPhase"] == progress["phase"], result
            assert task["currentStep"] == progress["step"], result
            assert task["nextAction"] == progress["action"], result
            assert result["visibleTailAssertion"]["state"] == "current", result
            assert result["recoveryPresentation"]["openingLine"] == "已接上：" + progress["sentence"], result
            assert result["runtimeReceipt"]["recoveryPresentation"]["required"] is True, result
            assert "openingLine" not in result["runtimeReceipt"]["recoveryPresentation"], result
        assert (
            model_a["visibleTailAssertion"]["hostMessageHash"]
            != model_b["visibleTailAssertion"]["hostMessageHash"]
        ), (model_a, model_b)
        assert continuous["available"] is True, continuous
        assert continuous["recoveryPresentation"]["code"] == "H7_RECOVERY_PRESENTATION_SUPPRESSED", continuous
        assert continuous["recoveryPresentation"]["required"] is False, continuous
        assert continuous["recoveryPresentation"]["openingLine"] == "", continuous
        assert invalid["available"] is False, invalid
        assert invalid["code"] == "H7_RECOVERY_EVENT_INVALID", invalid
        assert contract_path.read_bytes() == before_contract
        serialized = json.dumps(
            {"modelA": model_a, "modelB": model_b, "continuous": continuous, "invalid": invalid},
            ensure_ascii=False,
        )
        assert "item-model-a-visible-tail" not in serialized
        assert "item-model-b-visible-tail" not in serialized


def test_same_workline_visible_context_is_required_and_observation_stays_transient() -> None:
    """Visible tails bind this turn only; normal work never writes a card."""

    with tempfile.TemporaryDirectory(prefix="super-brain-visible-readback-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "e" * 24
        task_id = "task-visible-readback"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, host_workspace_key(host_root))
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        assertion = visible_tail_assertion(
            host_thread_id=session_key,
            sentence=str(contract["lastConfirmedSentence"]),
            phase=str(contract["currentPhase"]),
            current_step=str(contract["currentStep"]),
            next_action=str(contract["nextAction"]),
            host_message_id="item-visible-context-current",
            selection="current_visible_assistant",
            observation_source="codex_visible_context",
        )
        core = BrainCore(ROOT, memory_root)
        with with_host_scope(host_root, session_key):
            missing = run_turn(core, phase="open", turn_intent="continuity")
            opened = run_turn(core, phase="open", turn_intent="continuity", visible_progress_assertion=assertion)
            repeated = run_turn(core, phase="open", turn_intent="continuity", visible_progress_assertion=assertion)
            pause_missing = run_turn(core, phase="open", turn_intent="continuity", recovery_event="pause_resume")
            paused = run_turn(
                core,
                phase="open",
                turn_intent="continuity",
                recovery_event="pause_resume",
                visible_progress_assertion={**assertion, "host_message_id": "item-visible-context-after-pause"},
            )

        assert missing["available"] is False and missing["code"] == "H7_VISIBLE_TAIL_ASSERTION_REQUIRED", missing
        assert opened["available"] is True, opened
        assert opened["context"]["visibleProgressObservation"]["state"] == "observed", opened
        assert repeated["available"] is True, repeated
        assert repeated["context"]["visibleProgressObservation"]["payloadHash"] == opened["context"]["visibleProgressObservation"]["payloadHash"], repeated
        assert pause_missing["available"] is False and pause_missing["code"] == "H7_VISIBLE_TAIL_ASSERTION_REQUIRED", pause_missing
        assert paused["available"] is True, paused
        assert paused["recoveryPresentation"]["event"] == "pause_resume", paused
        assert paused["context"]["visibleProgressObservation"]["hostMessageHash"] != opened["context"]["visibleProgressObservation"]["hostMessageHash"], paused
        scope = opened["context"]["scope"]["scopeRef"]
        card_path = state_root / "workspace" / "runtime-state" / "turn-runtime" / "visible-progress-readbacks" / f"{scope}.json"
        assert not card_path.exists(), card_path
        serialized = json.dumps({"opened": opened, "paused": paused}, ensure_ascii=False)
        # The scoped task projection may show its legitimate current progress
        # sentence to the current caller.  The privacy boundary is that normal
        # continuation does not persist a second readback card or leak raw
        # Host ids into the receipt/telemetry projection.
        assert "item-visible-context-current" not in serialized
        assert "item-visible-context-after-pause" not in serialized


def test_real_session_compaction_then_fresh_h7_open_preserves_exact_progress() -> None:
    """Real session compaction writes a checkpoint before a fresh H7 open."""

    with tempfile.TemporaryDirectory(prefix="super-brain-real-compaction-h7-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        archive_root = Path(directory) / "archive"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        archive_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "c" * 24
        task_id = "task-real-compaction-h7"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        workspace_key = host_workspace_key(host_root)
        contract_path = (
            state_root
            / "workspace"
            / "runtime-state"
            / "execution-contracts"
            / contract_file_name(task_id, workspace_key)
        )
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        environment = os.environ.copy()
        environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
        environment["SUPER_BRAIN_ARCHIVE_ROOT"] = str(archive_root)
        environment["CODEX_THREAD_ID"] = session_key
        compacted = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ROOT / "scripts" / "session-compact.ps1"),
                "-InputText",
                "verified: the exact H7 progress remains current\nNext: reopen H7 after compaction",
                "-Title",
                "Stage 3 real compaction",
                "-TaskId",
                task_id,
                "-WorkspaceKey",
                workspace_key,
                "-SessionId",
                session_key,
                "-Json",
            ],
            cwd=str(host_root),
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
        )
        assert compacted.returncode == 0, compacted.stderr or compacted.stdout
        compact_result = json.loads(compacted.stdout)
        assert compact_result["ok"] is True, compact_result
        assert compact_result["historicalOnly"] is True, compact_result
        assert compact_result["nonAuthorizing"] is True, compact_result
        assert compact_result["recoveryCheckpoint"]["checkpointHash"], compact_result

        with with_host_scope(host_root, session_key):
            recovered = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="compaction",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=str(contract["lastConfirmedSentence"]),
                    phase=str(contract["currentPhase"]),
                    current_step=str(contract["currentStep"]),
                    next_action=str(contract["nextAction"]),
                    host_message_id="item-real-compaction-visible-tail",
                    receipt_hash=str(contract["visibleProgressReceipt"]["payloadHash"]),
                ),
            )

        assert recovered["available"] is True, recovered
        assert recovered["recoveryPresentation"]["openingLine"] == (
            "已接上：" + contract["lastConfirmedSentence"]
        ), recovered
        assert recovered["context"]["task"]["nextAction"] == contract["nextAction"], recovered


def test_public_cross_session_rebind_then_fresh_h7_open_preserves_exact_progress() -> None:
    """The public CAS rebind publishes a new scope receipt before recovery."""

    with tempfile.TemporaryDirectory(prefix="super-brain-public-rebind-h7-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        old_session = "sid-" + "d" * 24
        new_session = "sid-" + "e" * 24
        task_id = "task-public-rebind-h7"
        workspace_key = host_workspace_key(host_root)
        evidence_path = host_root / "public-rebind-proof.txt"
        evidence_path.write_text("public rebind proof\n", encoding="utf-8")
        progress = {
            "last_confirmed_sentence": "Cross-session rebind keeps this exact progress.",
            "source": "assistant_visible_reply",
            "current_phase": "Stage 3",
            "current_step": "rebind the owner session",
            "next_action": "open H7 under the rebound session",
        }
        proof = {
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
        progress_b64 = base64.b64encode(json.dumps(progress, separators=(",", ":")).encode("utf-8")).decode("ascii")
        proof_b64 = base64.b64encode(json.dumps(proof, separators=(",", ":")).encode("utf-8")).decode("ascii")
        created = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", old_session,
                "-FocusId", "main", "-FocusLabel", "Main", "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue after reconnect", "-CurrentPhase", progress["current_phase"],
                "-CurrentStep", progress["current_step"], "-LastConfirmedSentence", progress["last_confirmed_sentence"],
                "-LastConfirmedSource", "assistant_commitment", "-NextAction", progress["next_action"],
                "-PendingSteps", progress["next_action"], "-ProjectRoot", str(host_root),
                "-ProjectProgressProofBase64", proof_b64, "-ProgressCheckpointBase64", progress_b64,
                "-TransitionId", "seed-public-rebind-h7", "-StateRoot", str(state_root), "-Json",
            ]
        )
        rebound = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", new_session,
                "-RebindSession", "-FocusId", "main", "-FocusLabel", "Main", "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue after reconnect", "-CurrentPhase", progress["current_phase"],
                "-CurrentStep", progress["current_step"], "-LastConfirmedSentence", progress["last_confirmed_sentence"],
                "-LastConfirmedSource", "assistant_commitment", "-NextAction", progress["next_action"],
                "-PendingSteps", progress["next_action"], "-ExpectedRevision", str(created["revision"]),
                "-ExpectedPlanFingerprint", str(created["planReceipt"]["planFingerprint"]),
                "-ProjectRoot", str(host_root), "-ProjectProgressProofBase64", proof_b64,
                "-ProgressCheckpointBase64", progress_b64, "-TransitionId", "public-rebind-h7",
                "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert rebound["ownerSessionKey"] == new_session, rebound
        assert rebound["taskInstanceId"] == created["taskInstanceId"], rebound
        assert rebound["visibleProgressReceipt"]["scopeBindingHash"] != created["visibleProgressReceipt"]["scopeBindingHash"], rebound
        write_native_memory_snapshot(state_root / "workspace")

        with with_host_scope(host_root, new_session):
            recovered = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="cross_session",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=new_session,
                    sentence=progress["last_confirmed_sentence"],
                    phase=progress["current_phase"],
                    current_step=progress["current_step"],
                    next_action=progress["next_action"],
                    host_message_id="item-public-rebind-visible-tail",
                    receipt_hash=str(rebound["visibleProgressReceipt"]["payloadHash"]),
                ),
            )

        assert recovered["available"] is True, recovered
        assert recovered["context"]["task"]["taskInstanceId"] == created["taskInstanceId"], recovered
        assert recovered["recoveryPresentation"]["openingLine"] == (
            "已接上：" + progress["last_confirmed_sentence"]
        ), recovered


def test_h7_open_atomically_rebinds_one_unique_contract_from_the_exact_current_tail() -> None:
    """A fresh Codex task recovers without an old-summary/manual-anchor gap."""

    with tempfile.TemporaryDirectory(prefix="super-brain-atomic-session-rebind-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        old_session = "sid-" + "b" * 24
        new_thread_id = "019ff0bd-654b-7e73-adce-ca1ce9443e4e"
        new_session = BrainCore._session_key_from_host_thread(new_thread_id)
        task_id = "task-atomic-session-rebind"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, old_session, task_id=task_id)
        contract_path = (
            state_root / "workspace" / "runtime-state" / "execution-contracts"
            / contract_file_name(task_id, host_workspace_key(host_root))
        )
        before = json.loads(contract_path.read_text(encoding="utf-8"))
        assertion = visible_tail_assertion(
            host_thread_id=new_thread_id,
            sentence=str(before["lastConfirmedSentence"]),
            phase=str(before["currentPhase"]),
            current_step=str(before["currentStep"]),
            next_action=str(before["nextAction"]),
            host_message_id="item-atomic-session-rebind",
            selection="latest_durable_assistant",
            publication_kind="h7_durable_progress",
            receipt_hash=str(before["visibleProgressReceipt"]["payloadHash"]),
        )

        with with_host_scope(host_root, new_thread_id):
            rebound_open = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="super_brain_issue_continuity",
                recovery_event="cross_session",
                visible_progress_assertion=assertion,
            )
            republished = visible_tail_assertion(
                host_thread_id=new_thread_id,
                sentence=str(before["lastConfirmedSentence"]),
                phase=str(before["currentPhase"]),
                current_step=str(before["currentStep"]),
                next_action=str(before["nextAction"]),
                host_message_id="item-atomic-session-rebind-republished",
                selection="latest_durable_assistant",
                receipt_hash=str((rebound_open.get("sessionRebind") or {}).get("visibleProgressReceiptHash", "")),
            )
            recovered = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="super_brain_issue_continuity",
                recovery_event="cross_session",
                visible_progress_assertion=republished,
            )

        after = json.loads(contract_path.read_text(encoding="utf-8"))
        assert rebound_open["available"] is False, rebound_open
        assert rebound_open["code"] == "H7_SESSION_REBOUND_REPUBLISH_REQUIRED", rebound_open
        assert rebound_open["sessionRebind"]["code"] == "H7_SESSION_REBOUND", rebound_open
        assert rebound_open["sessionRebind"]["republishRequired"] is True, rebound_open
        assert recovered["available"] is True, recovered
        assert after["ownerSessionKey"] == new_session, after
        assert after["taskInstanceId"] == before["taskInstanceId"], after
        assert after["lastConfirmedSentence"] == before["lastConfirmedSentence"], after
        assert after["currentPhase"] == before["currentPhase"], after
        assert after["currentStep"] == before["currentStep"], after
        assert after["nextAction"] == before["nextAction"], after
        assert after["projectProgressProof"]["payloadHash"] == before["projectProgressProof"]["payloadHash"], after
        assert recovered["recoveryPresentation"]["openingLine"] == (
            "已接上：" + str(before["lastConfirmedSentence"])
        ), recovered


def test_h7_open_never_rebinds_an_ambiguous_workspace_contract_set() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ambiguous-session-rebind-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, "sid-" + "c" * 24, task_id="task-rebind-a")
        write_context_contract(state_root, host_root, "sid-" + "d" * 24, task_id="task-rebind-b")
        assertion = visible_tail_assertion(
            host_thread_id="019ff0bd-654b-7e73-adce-ca1ce9443e4e",
            sentence="R0 is verified; return to the source-evidence parent workline.",
            phase="Fixture",
            current_step="Open the governed turn.",
            next_action="Run the local runtime verification.",
            selection="latest_durable_assistant",
            publication_kind="h7_durable_progress",
            receipt_hash="a" * 64,
        )
        with with_host_scope(host_root, "019ff0bd-654b-7e73-adce-ca1ce9443e4e"):
            blocked = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="cross_session",
                visible_progress_assertion=assertion,
            )
        assert blocked["available"] is False, blocked
        assert blocked["code"] == "H7_TAIL_FIRST_REBIND_TASK_AMBIGUOUS", blocked


def test_observed_user_correction_then_fresh_h7_open_uses_corrected_progress() -> None:
    """ObserveUser withholds the old action until a new H7 progress receipt exists."""

    with tempfile.TemporaryDirectory(prefix="super-brain-observed-correction-h7-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "f" * 24
        task_id = "task-observed-correction-h7"
        workspace_key = host_workspace_key(host_root)
        evidence_path = host_root / "observed-correction-proof.txt"
        evidence_path.write_text("observed correction proof\n", encoding="utf-8")

        def encode(value: dict[str, object]) -> str:
            return base64.b64encode(json.dumps(value, separators=(",", ":")).encode("utf-8")).decode("ascii")

        old = {
            "last_confirmed_sentence": "Old progress is current before correction.",
            "source": "assistant_visible_reply",
            "current_phase": "Stage 3",
            "current_step": "old step",
            "next_action": "old action",
        }
        old_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": old["current_phase"],
            "currentStep": old["current_step"],
            "completedItems": [],
            "projectEvidence": [
                {"kind": "project_file", "relativePath": evidence_path.name, "sha256": file_sha256(evidence_path)}
            ],
            "verificationResults": [],
            "nextAction": old["next_action"],
        }
        created = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", "main", "-FocusLabel", "Main", "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue old action", "-CurrentPhase", old["current_phase"],
                "-CurrentStep", old["current_step"], "-LastConfirmedSentence", old["last_confirmed_sentence"],
                "-LastConfirmedSource", "assistant_commitment", "-NextAction", old["next_action"],
                "-PendingSteps", old["next_action"], "-ProjectRoot", str(host_root),
                "-ProjectProgressProofBase64", encode(old_proof), "-ProgressCheckpointBase64", encode(old),
                "-TransitionId", "seed-observed-correction-h7", "-StateRoot", str(state_root), "-Json",
            ]
        )
        corrected_instruction = "replace old action with corrected action"
        observed = invoke_contract(
            [
                "-Action", "ObserveUser", "-TaskId", task_id, "-WorkspaceKey", workspace_key,
                "-SessionKey", session_key, "-UserInstruction", corrected_instruction,
                "-RequiresReconciliation", "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert observed["needsReconciliation"] is True, observed
        assert observed["latestUserInstruction"] == corrected_instruction, observed

        corrected = {
            "last_confirmed_sentence": "User correction is reconciled; the corrected action is current.",
            "source": "assistant_visible_reply",
            "current_phase": "Stage 3",
            "current_step": "publish the corrected progress",
            "next_action": "run the corrected action",
        }
        corrected_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": corrected["current_phase"],
            "currentStep": corrected["current_step"],
            "completedItems": [],
            "projectEvidence": [
                {"kind": "project_file", "relativePath": evidence_path.name, "sha256": file_sha256(evidence_path)}
            ],
            "verificationResults": [],
            "nextAction": corrected["next_action"],
        }
        reconciled = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", "main", "-FocusLabel", "Main", "-InstructionMode", "continue",
                "-LatestUserInstruction", corrected_instruction, "-CurrentPhase", corrected["current_phase"],
                "-CurrentStep", corrected["current_step"], "-LastConfirmedSentence", corrected["last_confirmed_sentence"],
                "-LastConfirmedSource", "assistant_commitment", "-NextAction", corrected["next_action"],
                "-PendingSteps", corrected["next_action"], "-ExpectedRevision", str(observed["revision"]),
                "-ExpectedPlanFingerprint", str(created["planReceipt"]["planFingerprint"]),
                "-ProjectRoot", str(host_root), "-ProjectProgressProofBase64", encode(corrected_proof),
                "-ProgressCheckpointBase64", encode(corrected), "-TransitionId", "reconcile-observed-correction-h7",
                "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert reconciled["needsReconciliation"] is False, reconciled
        write_native_memory_snapshot(state_root / "workspace")

        with with_host_scope(host_root, session_key):
            recovered = run_turn(
                BrainCore(ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="user_correction",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=corrected["last_confirmed_sentence"],
                    phase=corrected["current_phase"],
                    current_step=corrected["current_step"],
                    next_action=corrected["next_action"],
                    host_message_id="item-observed-correction-visible-tail",
                    receipt_hash=str(reconciled["visibleProgressReceipt"]["payloadHash"]),
                ),
            )

        assert recovered["available"] is True, recovered
        assert recovered["recoveryPresentation"]["openingLine"] == (
            "已接上：" + corrected["last_confirmed_sentence"]
        ), recovered
        serialized_task = json.dumps(recovered["context"]["task"], ensure_ascii=False)
        assert old["next_action"] not in serialized_task, recovered
        assert recovered["context"]["task"]["nextAction"] == corrected["next_action"], recovered


def test_stale_handoff_summary_legacy_contract_and_memory_never_select_recovery_anchor() -> None:
    """Only the current scope-bound assistant receipt may select recovery.

    Replays the hostile combination that previously encouraged progress drift:
    a lagging hot index, a newer-looking legacy global contract, and a selected
    memory note that calls itself a handoff summary.  None may replace the
    exact assistant-visible progress bound to the current scoped contract.
    """

    with tempfile.TemporaryDirectory(prefix="super-brain-visible-progress-conflict-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "f" * 24
        task_id = "task-visible-progress-conflict"
        write_native_memory_snapshot(workspace)
        write_context_contract(state_root, host_root, session_key, task_id=task_id)

        snapshot_path = workspace / "native-memory-influence-snapshot.json"
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
        snapshot_body = {key: value for key, value in snapshot.items() if key != "payloadHash"}
        snapshot_body["entries"].append(
            {
                "kind": "note",
                "bucket": "references",
                "scopeKind": "global",
                "scopeRef": scope_ref("user"),
                "item": {
                    "cardId": "card-stale-handoff-summary",
                    "cardRevision": 1,
                    "title": "Hookless runtime handoff summary",
                    "effect": "reference_only",
                    "body": "Handoff summary: Stage 0 is current and the old action should resume.",
                    "links": [],
                },
            }
        )
        snapshot_body["entryCount"] = len(snapshot_body["entries"])
        write_json(snapshot_path, {**snapshot_body, "payloadHash": canonical_hash(snapshot_body)})

        contract_path = workspace / "runtime-state" / "execution-contracts" / contract_file_name(task_id, host_workspace_key(host_root))
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        current_sentence = "R5 Stage 2 conflict replay passed; keep the exact current assistant progress."
        current_phase = "R5 Stage 2"
        current_step = "Reject stale summaries, legacy pointers, and memory as continuation anchors."
        current_action = "Run the exact visible-progress conflict matrix."
        evidence_path = host_root / "project-progress-evidence.txt"
        evidence = {
            "kind": "project_file",
            "relativePath": evidence_path.name,
            "sha256": file_sha256(evidence_path),
        }
        proof = project_progress_proof(
            host_root,
            phase=current_phase,
            current_step=current_step,
            next_action=current_action,
            project_evidence=[evidence],
        )
        contract.update(
            {
                "revision": 8,
                "lastConfirmedSentence": current_sentence,
                "lastConfirmedSource": "assistant_visible_reply",
                "currentPhase": current_phase,
                "currentStep": current_step,
                "nextAction": current_action,
                "projectProgressProof": proof,
                "visibleProgressReceipt": visible_progress_receipt(
                    sentence=current_sentence,
                    source="assistant_visible_reply",
                    phase=current_phase,
                    current_step=current_step,
                    next_action=current_action,
                    project_proof=proof,
                    scope_binding_hash=visible_progress_scope_binding_hash(
                        task_id=task_id,
                        task_instance_id=str(contract["taskInstanceId"]),
                        workspace_key=str(contract["workspaceKey"]),
                        owner_session_key=str(contract["ownerSessionKey"]),
                        package_version=str(contract["packageVersion"]),
                    ),
                    transition_id="r5-stage2-current-assistant-progress",
                ),
                "updatedAt": now(),
            }
        )
        contract["planReceipt"]["contractRevision"] = 8
        write_json(contract_path, contract)
        VISIBLE_RECEIPT_HASH_BY_HOST_SESSION[session_key] = str(contract["visibleProgressReceipt"]["payloadHash"])

        stale_sentence = "Stage 0 is current; resume the old action from the handoff summary."
        write_json(
            workspace / "last-execution-contract.json",
            {
                "schema": "super-brain.execution-contract.v1",
                "taskId": "legacy-global-pointer",
                "revision": 999,
                "lastConfirmedSentence": stale_sentence,
                "lastConfirmedSource": "checkpoint_summary",
                "currentPhase": "Stage 0",
                "currentStep": "Use a stale global projection.",
                "nextAction": "Resume the old action.",
            },
        )

        contract_before_open = contract_path.read_bytes()
        restarted_core = BrainCore(ROOT, memory_root)
        with with_host_scope(host_root, session_key):
            missing_assertion = run_turn(
                restarted_core,
                phase="open",
                turn_intent="continuity",
                recovery_event="compaction",
            )
            stale_assertion = run_turn(
                restarted_core,
                phase="open",
                turn_intent="continuity",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=stale_sentence,
                    phase="Stage 0",
                    current_step="Use a stale global projection.",
                    next_action="Resume the old action.",
                    host_message_id="item-stale-handoff-summary",
                    selection="latest_assistant",
                    receipt_hash=str(contract["visibleProgressReceipt"]["payloadHash"]),
                ),
            )
            foreign_scope_assertion = run_turn(
                restarted_core,
                phase="open",
                turn_intent="continuity",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id="sid-" + "0" * 24,
                    sentence=current_sentence,
                    phase=current_phase,
                    current_step=current_step,
                    next_action=current_action,
                    host_message_id="item-foreign-visible-progress",
                    receipt_hash=str(contract["visibleProgressReceipt"]["payloadHash"]),
                ),
            )
            recovered = run_turn(
                restarted_core,
                phase="open",
                turn_intent="continuity",
                recovery_event="compaction",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=current_sentence,
                    phase=current_phase,
                    current_step=current_step,
                    next_action=current_action,
                ),
            )

        assert missing_assertion["available"] is False, missing_assertion
        assert missing_assertion["code"] == "H7_VISIBLE_TAIL_ASSERTION_REQUIRED", missing_assertion
        assert stale_assertion["available"] is False, stale_assertion
        assert stale_assertion["code"] == "H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED", stale_assertion
        assert foreign_scope_assertion["available"] is False, foreign_scope_assertion
        # Tail-first mapping rejects a foreign Host scope before the later
        # assertion verifier.  This is the same fail-closed boundary, now with
        # an explicit diagnostic that no foreign task mapping was attempted.
        assert foreign_scope_assertion["code"] == "H7_TAIL_FIRST_VISIBLE_SCOPE_MISMATCH", foreign_scope_assertion
        assert contract_path.read_bytes() == contract_before_open
        assert recovered["available"] is True, recovered
        assert recovered["context"]["code"] == "BRAIN_CONTEXT_HOT_INDEX_LAGGING_FALLBACK", recovered
        task = recovered["context"]["task"]
        assert task["lastConfirmedSentence"] == current_sentence, recovered
        assert task["lastConfirmedSource"] == "assistant_visible_reply", recovered
        assert task["currentPhase"] == current_phase, recovered
        assert task["currentStep"] == current_step, recovered
        assert task["nextAction"] == current_action, recovered
        assert task["visibleProgress"]["continuationEligible"] is True, recovered
        assert recovered["visibleTailAssertion"]["state"] == "current", recovered
        assert recovered["recoveryPresentation"]["event"] == "compaction", recovered
        assert recovered["recoveryPresentation"]["openingLine"] == "已接上：" + current_sentence, recovered
        assert {entry["cardId"] for entry in recovered["context"]["typedMemory"]["refs"]} == {
            "card-turn-runtime-preference",
            "card-stale-handoff-summary",
        }, recovered
        assert stale_sentence not in json.dumps(task, ensure_ascii=False), recovered


def test_visible_progress_receipt_requires_exact_latest_anchor_and_user_attested_reconcile() -> None:
    """A user attestation reconciles state but cannot itself resume work."""

    with tempfile.TemporaryDirectory(prefix="super-brain-visible-progress-anchor-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "d" * 24
        task_id = "task-visible-progress-anchor"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, host_workspace_key(host_root))
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        contract.pop("visibleProgressReceipt", None)
        contract["lastConfirmedSource"] = "assistant_commitment"
        write_json(contract_path, contract)
        core = BrainCore(ROOT, memory_root)
        progress = {
            "last_confirmed_sentence": "R0 is verified; return to the source-evidence parent workline.",
            "source": "user_attested_visible_reply",
            "current_phase": "Fixture",
            "current_step": "Open the governed turn.",
            "next_action": "Run the local runtime verification.",
        }

        with with_host_scope(host_root, session_key):
            blocked = run_turn(core, phase="open", turn_intent="continuity")
            repaired = run_turn(
                core,
                phase="checkpoint",
                turn_intent="user_correction",
                progress_checkpoint=progress,
                transition_id="visible-progress-user-attested-fixture",
            )
            attested = run_turn(core, phase="open", turn_intent="continuity")
            published_progress = {
                **progress,
                "last_confirmed_sentence": "R0 reconciliation is published; run the local runtime verification.",
                "source": "assistant_visible_reply",
            }
            published = run_turn(
                core,
                phase="checkpoint",
                turn_intent="continuity",
                progress_checkpoint=published_progress,
                transition_id="visible-progress-assistant-publication-fixture",
            )
            recovered = run_turn(
                core,
                phase="open",
                turn_intent="continuity",
                recovery_event="user_correction",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=published_progress["last_confirmed_sentence"],
                    phase=published_progress["current_phase"],
                    current_step=published_progress["current_step"],
                    next_action=published_progress["next_action"],
                    receipt_hash=str((published.get("checkpoint") or {}).get("visibleProgress", {}).get("payloadHash", "")),
                ),
            )

        assert blocked["available"] is False, blocked
        # A governed same-workline open now requires the visible locator first;
        # it cannot inspect the missing receipt before knowing which current
        # assistant reply the user actually saw.
        assert blocked["code"] == "H7_VISIBLE_TAIL_ASSERTION_REQUIRED", blocked
        assert repaired["ok"] is True, repaired
        assert repaired["available"] is False, repaired
        assert repaired["code"] == "H7_VISIBLE_PROGRESS_ASSISTANT_REPLY_REQUIRED", repaired
        assert repaired["checkpoint"]["stateMutated"] is True, repaired
        assert attested["available"] is False, attested
        assert attested["code"] == "H7_VISIBLE_TAIL_ASSERTION_REQUIRED", attested
        assert published["available"] is True, published
        assert recovered["available"] is True, recovered
        visible = recovered["context"]["task"]["visibleProgress"]
        assert recovered["context"]["task"]["lastConfirmedSentence"] == published_progress["last_confirmed_sentence"], recovered
        assert recovered["context"]["task"]["lastConfirmedSource"] == "assistant_visible_reply", recovered
        assert visible["state"] == "current", visible
        assert visible["source"] == "assistant_visible_reply", visible
        assert visible["continuationEligible"] is True, visible
        assert visible["sentenceHash"] == hashlib.sha256(published_progress["last_confirmed_sentence"].encode("utf-8")).hexdigest(), visible
        assert recovered["recoveryPresentation"]["event"] == "user_correction", recovered
        assert recovered["recoveryPresentation"]["openingLine"] == (
            "已接上：" + published_progress["last_confirmed_sentence"]
        ), recovered

        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        contract["lastConfirmedSentence"] = "An older summary must never become the recovery anchor."
        write_json(contract_path, contract)
        with with_host_scope(host_root, session_key):
            stale = run_turn(
                core,
                phase="open",
                turn_intent="continuity",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=published_progress["last_confirmed_sentence"],
                    phase=published_progress["current_phase"],
                    current_step=published_progress["current_step"],
                    next_action=published_progress["next_action"],
                    host_message_id="item-visible-progress-stale-contract",
                    receipt_hash=str((published.get("checkpoint") or {}).get("visibleProgress", {}).get("payloadHash", "")),
                ),
            )

        assert stale["available"] is False, stale
        assert stale["code"] == "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH", stale


def test_strict_current_v4_tail_with_stale_project_proof_is_withheld_without_mutation() -> None:
    """A current v4 locator cannot mask proof drift or mutate the contract."""

    with tempfile.TemporaryDirectory(prefix="super-brain-strict-v4-stale-proof-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "e" * 24
        task_id = "task-strict-v4-stale-proof"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = (
            state_root
            / "workspace"
            / "runtime-state"
            / "execution-contracts"
            / contract_file_name(task_id, host_workspace_key(host_root))
        )
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        before = contract_path.read_bytes()
        evidence_path = host_root / "project-progress-evidence.txt"
        evidence_path.write_text("project progress proof changed after receipt\n", encoding="utf-8")
        core = BrainCore(ROOT, memory_root)

        with with_host_scope(host_root, session_key):
            result = run_turn(
                core,
                phase="open",
                turn_intent="continuity",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=session_key,
                    sentence=str(contract["lastConfirmedSentence"]),
                    phase=str(contract["currentPhase"]),
                    current_step=str(contract["currentStep"]),
                    next_action=str(contract["nextAction"]),
                    host_message_id="item-strict-v4-stale-project-proof",
                    receipt_hash=str((contract.get("visibleProgressReceipt") or {}).get("payloadHash", "")),
                ),
            )

        assert result["available"] is False, result
        assert result["code"] == "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH", result
        assert result["continuityMapping"]["projectProgressState"] == "withheld", result
        assert result["continuityMapping"]["duplicateActionBlocked"] is True, result
        assert contract_path.read_bytes() == before


def test_each_visible_progress_scope_field_drift_is_withheld() -> None:
    """Sentence, source, phase, step, and action are one atomic anchor."""

    with tempfile.TemporaryDirectory(prefix="super-brain-visible-progress-field-drift-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "7" * 24
        task_id = "task-visible-progress-field-drift"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, host_workspace_key(host_root))
        original = json.loads(contract_path.read_text(encoding="utf-8"))
        drifts = {
            "lastConfirmedSentence": (
                "A different visible sentence must not inherit the old receipt.",
                "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH",
            ),
            "lastConfirmedSource": ("assistant_commitment", "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH"),
            # The Host tail contains only its exact visible sentence/hash;
            # phase, step and action are derived from the mapped contract.
            # Their drift therefore invalidates the contract's own v4 receipt
            # and must fail closed before TURN_RUNTIME_OPEN_READY.
            "currentPhase": ("A different phase", "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH"),
            "currentStep": ("A different current step.", "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH"),
            "nextAction": ("A different next action.", "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH"),
        }

        for field, (value, expected_code) in drifts.items():
            drifted = json.loads(json.dumps(original))
            drifted[field] = value
            write_json(contract_path, drifted)
            with with_host_scope(host_root, session_key):
                result = run_turn(
                    BrainCore(ROOT, memory_root),
                    phase="open",
                    turn_intent="continuity",
                    visible_progress_assertion=visible_tail_assertion(
                        host_thread_id=session_key,
                        sentence=str(original["lastConfirmedSentence"]),
                        phase=str(original["currentPhase"]),
                        current_step=str(original["currentStep"]),
                        next_action=str(original["nextAction"]),
                        host_message_id=f"item-visible-progress-field-drift-{field}",
                        receipt_hash=str((original.get("visibleProgressReceipt") or {}).get("payloadHash", "")),
                    ),
            )
            assert result["available"] is False, (field, result)
            assert result["code"] == expected_code, (field, result)


def test_close_rejects_user_attested_checkpoint_outside_correction_without_mutation() -> None:
    """The close path must not bypass the correction-only source guard."""

    with tempfile.TemporaryDirectory(prefix="super-brain-close-user-attested-guard-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "8" * 24
        task_id = "task-close-user-attested-guard"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, host_workspace_key(host_root))
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        before = contract_path.read_bytes()
        progress = {
            "last_confirmed_sentence": str(contract["lastConfirmedSentence"]),
            "source": "user_attested_visible_reply",
            "current_phase": str(contract["currentPhase"]),
            "current_step": str(contract["currentStep"]),
            "next_action": str(contract["nextAction"]),
        }

        with with_host_scope(host_root, session_key):
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


def test_visible_progress_receipt_is_scope_bound_across_session_rebind() -> None:
    """A copied receipt cannot authorize a different root session."""

    with tempfile.TemporaryDirectory(prefix="super-brain-visible-progress-scope-rebind-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        original_session = "sid-" + "9" * 24
        rebound_session = "sid-" + "a" * 24
        task_id = "task-visible-progress-scope-rebind"
        write_native_memory_snapshot(workspace)
        write_context_contract(state_root, host_root, original_session, task_id=task_id)
        workspace_key = host_workspace_key(host_root)
        contract_path = workspace / "runtime-state" / "execution-contracts" / contract_file_name(task_id, workspace_key)
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        old_scope_hash = str(contract["visibleProgressReceipt"]["scopeBindingHash"])
        contract["ownerSessionKey"] = rebound_session
        contract["updatedAt"] = now()
        write_json(contract_path, contract)
        write_json(
            workspace / "runtime-state" / "execution-hot-index" / f"{rebound_session}--{workspace_key}.json",
            {
                "schema": "super-brain.execution-hot-index.v1",
                "packageVersion": package_version(),
                "workspaceKey": workspace_key,
                "ownerSessionKey": rebound_session,
                "entries": [
                    {
                        "taskId": task_id,
                        "workspaceKey": workspace_key,
                        "ownerSessionKey": rebound_session,
                        "packageVersion": package_version(),
                        "revision": int(contract["revision"]),
                        "status": "active",
                        "updatedAt": str(contract["updatedAt"]),
                        "contractFileName": contract_path.name,
                    }
                ],
            },
        )
        progress = {
            "last_confirmed_sentence": str(contract["lastConfirmedSentence"]),
            "source": "assistant_visible_reply",
            "current_phase": str(contract["currentPhase"]),
            "current_step": str(contract["currentStep"]),
            "next_action": str(contract["nextAction"]),
        }
        core = BrainCore(ROOT, memory_root)

        with with_host_scope(host_root, rebound_session):
            # The current Host tail is always required before H7 interprets
            # the stale receipt.  Supply the old receipt-bound tail so this
            # test reaches the scope-binding mismatch rather than testing the
            # independent missing-tail gate.
            blocked = run_turn(
                core,
                phase="open",
                turn_intent="continuity",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=rebound_session,
                    sentence=progress["last_confirmed_sentence"],
                    phase=progress["current_phase"],
                    current_step=progress["current_step"],
                    next_action=progress["next_action"],
                    host_message_id="item-scope-rebind-stale",
                    receipt_hash=str((contract.get("visibleProgressReceipt") or {}).get("payloadHash", "")),
                ),
            )
            republished = run_turn(
                core,
                phase="checkpoint",
                turn_intent="continuity",
                progress_checkpoint=progress,
                transition_id="visible-progress-scope-rebind-republish",
            )
            recovered = run_turn(
                core,
                phase="open",
                turn_intent="continuity",
                recovery_event="cross_session",
                visible_progress_assertion=visible_tail_assertion(
                    host_thread_id=rebound_session,
                    sentence=progress["last_confirmed_sentence"],
                    phase=progress["current_phase"],
                    current_step=progress["current_step"],
                    next_action=progress["next_action"],
                    host_message_id="item-scope-rebind-republished",
                    receipt_hash=str((republished.get("checkpoint") or {}).get("visibleProgress", {}).get("payloadHash", "")),
                ),
            )

        assert blocked["available"] is False, blocked
        assert blocked["code"] == "H7_VISIBLE_PROGRESS_RECEIPT_MISMATCH", blocked
        assert republished["available"] is True, republished
        assert recovered["available"] is True, recovered
        assert recovered["recoveryPresentation"]["event"] == "cross_session", recovered
        assert recovered["recoveryPresentation"]["openingLine"] == (
            "已接上：" + progress["last_confirmed_sentence"]
        ), recovered
        updated = json.loads(contract_path.read_text(encoding="utf-8"))
        assert updated["visibleProgressReceipt"]["scopeBindingHash"] != old_scope_hash, updated
        assert updated["visibleProgressReceipt"]["scopeBindingHash"] == visible_progress_scope_binding_hash(
            task_id=task_id,
            task_instance_id=str(updated["taskInstanceId"]),
            workspace_key=workspace_key,
            owner_session_key=rebound_session,
            package_version=package_version(),
        ), updated


def test_checkpoint_scope_change_without_fresh_proof_fails_atomically() -> None:
    """A new progress sentence/action may not replace a current proof alone."""

    with tempfile.TemporaryDirectory(prefix="super-brain-checkpoint-proof-atomic-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "e" * 24
        task_id = "task-checkpoint-proof-atomic"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id=task_id)
        contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_file_name(task_id, host_workspace_key(host_root))
        before = json.loads(contract_path.read_text(encoding="utf-8"))
        core = BrainCore(ROOT, memory_root)
        progress = {
            "last_confirmed_sentence": "R0 has a new next action, but no fresh proof was supplied.",
            "source": "assistant_visible_reply",
            "current_phase": "Fixture",
            "current_step": "Open the governed turn.",
            "next_action": "Run a different verification that needs a fresh proof.",
        }

        with with_host_scope(host_root, session_key):
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


def test_greeting_stays_on_direct_host_path() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-greeting-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        core = BrainCore(ROOT, memory_root)
        result = run_turn(core, phase="open", turn_intent="greeting")
        assert result["available"] is False, result
        assert result["code"] == "TURN_INTENT_DIRECT_HOST_PATH", result
        assert result["turnIntent"]["memoryMode"] == "off", result
        assert not (state_root / "workspace" / "runtime-state" / "turn-runtime").exists()


def test_side_message_stays_on_direct_host_path() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-side-message-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        core = BrainCore(ROOT, memory_root)
        result = run_turn(core, phase="open", turn_intent="side_message")
        assert result["available"] is False, result
        assert result["code"] == "TURN_INTENT_DIRECT_HOST_PATH", result
        assert result["turnIntent"]["kind"] == "side_message", result
        assert result["turnIntent"]["memoryMode"] == "off", result
        assert result["rawPromptStored"] is False, result
        assert result["rawTranscriptStored"] is False, result
        assert not (state_root / "workspace" / "runtime-state" / "turn-runtime").exists()


def test_super_brain_issue_projects_root_rule_and_protocol() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-turn-runtime-issue-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "5" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id="task-turn-runtime-issue")
        core = BrainCore(ROOT, memory_root)
        with with_host_scope(host_root, session_key):
            result = run_turn(core, phase="open", turn_intent="super_brain_issue_runtime")
        assert result["available"] is True, result
        assert result["context"]["turnIntent"]["problemNature"] == "hookless_runtime", result
        assert result["context"]["turnIntent"]["responseOrder"] == "essence>fact_inference_unknown>repair>next", result
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
        environment["CODEX_THREAD_ID"] = session_key
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
            cwd=str(host_root),
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
        host_root = Path(directory) / "host"
        package_root = Path(directory) / "package"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        package_root.mkdir()
        for name in ("manifest.json", "route-map.json", "capabilities.json", "super-brain-rules.json"):
            (package_root / name).write_bytes((ROOT / name).read_bytes())
        for relative_path in (
            "runtime/brain_mcp.py",
            "runtime/brain_core.py",
            "runtime/turn_runtime.py",
            "runtime/core_rule_registry.py",
        ):
            destination = package_root / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((ROOT / relative_path).read_bytes())
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "4" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id="task-turn-runtime-registry")
        core = BrainCore(package_root, memory_root)

        with with_host_scope(host_root, session_key):
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
        with with_host_scope(host_root, session_key):
            stale_worker = run_turn(core, phase="open")
        assert stale_worker["available"] is False, stale_worker
        assert stale_worker["code"] == "BRAIN_CONTEXT_RUNTIME_IDENTITY_WITHHELD", stale_worker
        assert stale_worker["context"]["runtimeIdentity"]["code"] == "H7_MCP_RUNTIME_RULE_REGISTRY_STALE", stale_worker

        refreshed_core = BrainCore(package_root, memory_root)
        with with_host_scope(host_root, session_key):
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
        with with_host_scope(host_root, session_key):
            withheld = run_turn(invalid_core, phase="open")
        assert withheld["available"] is False, withheld
        assert withheld["code"] == "BRAIN_CONTEXT_CORE_RULES_WITHHELD", withheld
        assert withheld["context"]["coreRules"]["code"] == "CORE_RULE_REGISTRY_BOM_FORBIDDEN", withheld


def test_mcp_turn_binds_only_codex_request_metadata_scope() -> None:
    """Desktop MCP metadata must bind H7 without inherited process scope.

    A stdio MCP server is long-lived and cannot trust its own cwd or inherited
    environment as the current Codex task.  The real Desktop client supplies a
    request-scoped thread id and workspace map in MCP metadata.  This is the
    narrow regression for the old ``ACTIVATION_SCOPE_MISSING`` failure.
    """

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-host-metadata-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host-workspace"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        thread_id = "019fbc52-79e6-7941-af97-c1c2d40be451"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id="task-mcp-host-metadata")

        metadata = {
            "threadId": thread_id,
            "x-codex-turn-metadata": {
                "thread_id": thread_id,
                "session_id": "session-fixture-not-persisted",
                "workspace_kind": "project",
                "workspaces": {str(host_root): {}},
            },
        }
        requests = "\n".join(
            [
                json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_turn",
                            "arguments": {"phase": "open", "turn_intent": "design_evaluate"},
                            "_meta": metadata,
                        },
                    }
                ),
                # A later request without metadata must not inherit the prior
                # request's scope from the long-lived MCP process.
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 3,
                        "method": "tools/call",
                        "params": {"name": "brain_turn", "arguments": {"phase": "evidence"}},
                    }
                ),
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 4,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_turn",
                            "arguments": {"phase": "evidence"},
                            "_meta": {
                                "threadId": thread_id,
                                "x-codex-turn-metadata": {
                                    "thread_id": "019fbc52-79e6-7941-af97-c1c2d40adad0",
                                    "workspaces": {str(host_root): {}},
                                },
                            },
                        },
                    }
                ),
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 5,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_turn",
                            "arguments": {"phase": "evidence"},
                            "_meta": {
                                "threadId": thread_id,
                                "x-codex-turn-metadata": {
                                    "thread_id": thread_id,
                                    "workspaces": {str(host_root): {}, str(host_root / "other"): {}},
                                },
                            },
                        },
                    }
                ),
            ]
        ) + "\n"
        environment = os.environ.copy()
        for name in ("CODEX_THREAD_ID", "SUPER_BRAIN_SESSION_ID", "SUPER_BRAIN_WORKSPACE_KEY"):
            environment.pop(name, None)
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "brain_mcp.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(memory_root),
            ],
            input=requests,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
            env=environment,
        )
        assert completed.returncode == 0, completed.stderr
        replies = {reply["id"]: reply for reply in (json.loads(line) for line in completed.stdout.splitlines() if line.strip())}
        opened = json.loads(replies[2]["result"]["content"][0]["text"])
        missing = json.loads(replies[3]["result"]["content"][0]["text"])
        conflicting = json.loads(replies[4]["result"]["content"][0]["text"])
        ambiguous = json.loads(replies[5]["result"]["content"][0]["text"])

        assert opened["available"] is True, opened
        assert opened["code"] == "TURN_RUNTIME_OPEN_READY", opened
        assert opened["runtimeReceipt"]["memory"]["refs"] == ["card-turn-runtime-preference@3"], opened
        assert missing["available"] is False, missing
        assert missing["code"] == "H7_EVIDENCE_SCOPE_MISSING", missing
        assert conflicting["available"] is False, conflicting
        assert conflicting["code"] == "H7_EVIDENCE_SCOPE_MISSING", conflicting
        assert ambiguous["available"] is False, ambiguous
        assert ambiguous["code"] == "H7_EVIDENCE_SCOPE_MISSING", ambiguous
        serialized = json.dumps(
            {"opened": opened, "missing": missing, "conflicting": conflicting, "ambiguous": ambiguous},
            ensure_ascii=False,
        )
        assert thread_id not in serialized
        assert str(host_root) not in serialized


def test_mcp_checkpoint_recovers_latest_progress_after_visible_state_change() -> None:
    """The real stdio H7 adapter must expose and persist the checkpoint path."""

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-progress-checkpoint-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host-workspace"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        thread_id = "019fbc52-79e6-7941-af97-c1c2d40be451"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        workspace_key = host_workspace_key(host_root)
        task_id = "task-mcp-progress-checkpoint"
        write_native_memory_snapshot(state_root / "workspace")
        seeded = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", "hookless-continuity", "-FocusLabel", "Hookless continuity", "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue the approved H7 continuity repair", "-CurrentPhase", "old phase",
                "-CurrentStep", "old step", "-LastConfirmedSentence", "Old progress must not win after compaction.",
                "-LastConfirmedSource", "assistant_commitment", "-NextAction", "old next action",
                "-PendingSteps", "old next action", "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert seeded["ok"] is True
        metadata = {
            "threadId": thread_id,
            "x-codex-turn-metadata": {"thread_id": thread_id, "workspaces": {str(host_root): {}}},
        }
        progress = {
            "last_confirmed_sentence": "The legacy Hook patch was withdrawn; continue only through the H7 authority path.",
            "source": "assistant_visible_reply",
            "current_phase": "H7 continuity repair",
            "current_step": "Persist exact latest assistant progress before interpreting the next message.",
            "next_action": "Run the checkpoint recovery regression, then resume the hookless repair line.",
        }
        proof_path = host_root / "mcp-progress-evidence.txt"
        proof_path.write_text("mcp proof evidence\n", encoding="utf-8")
        project_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": progress["current_phase"],
            "currentStep": progress["current_step"],
            "completedItems": [],
            "projectEvidence": [{"kind": "project_file", "relativePath": proof_path.name, "sha256": file_sha256(proof_path)}],
            "verificationResults": [],
            "nextAction": progress["next_action"],
        }
        route_receipt = native_capability_route_receipt()
        tail_assertion = visible_tail_assertion(
            host_thread_id=thread_id,
            sentence=progress["last_confirmed_sentence"],
            phase=progress["current_phase"],
            current_step=progress["current_step"],
            next_action=progress["next_action"],
            host_message_id="item-mcp-visible-progress",
        )
        normal_tail_assertion = visible_tail_assertion(
            host_thread_id=thread_id,
            sentence=progress["last_confirmed_sentence"],
            phase=progress["current_phase"],
            current_step=progress["current_step"],
            next_action=progress["next_action"],
            host_message_id="item-mcp-visible-progress-durable",
            selection="latest_durable_assistant",
            publication_kind="h7_durable_progress",
        )
        requests = "\n".join(
            [
                json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}),
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_turn",
                            "arguments": {
                                "phase": "checkpoint",
                                "turn_intent": "continuity",
                                "progress_checkpoint": progress,
                                "project_progress_proof": project_proof,
                                "capability_route_receipt": route_receipt,
                            },
                            "_meta": metadata,
                        },
                    }
                ),
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 3,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_turn",
                            "arguments": {
                                "phase": "open",
                                "turn_intent": "continuity",
                                "capability_route_receipt": route_receipt,
                                "visible_progress_assertion": tail_assertion,
                            },
                            "_meta": metadata,
                        },
                    }
                ),
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 4,
                        "method": "tools/call",
                        "params": {
                            "name": "brain_turn",
                            "arguments": {
                                "phase": "open",
                                "turn_intent": "continuity",
                                "capability_route_receipt": route_receipt,
                                "visible_progress_assertion": normal_tail_assertion,
                            },
                            "_meta": metadata,
                        },
                    }
                ),
            ]
        ) + "\n"
        environment = os.environ.copy()
        for name in ("CODEX_THREAD_ID", "SUPER_BRAIN_SESSION_ID", "SUPER_BRAIN_WORKSPACE_KEY"):
            environment.pop(name, None)
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "brain_mcp.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(memory_root),
            ],
            input=requests,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
            env=environment,
        )
        assert completed.returncode == 0, completed.stderr
        replies = {reply["id"]: reply for reply in (json.loads(line) for line in completed.stdout.splitlines() if line.strip())}
        listed = replies[1]["result"]["tools"]
        turn_tool = next(tool for tool in listed if tool["name"] == "brain_turn")
        assert "checkpoint" in turn_tool["inputSchema"]["properties"]["phase"]["enum"], turn_tool
        assert turn_tool["inputSchema"]["properties"]["recovery_event"]["enum"] == [
            "none", "compaction", "restart", "model_switch", "cross_session", "pause_resume", "user_correction", "parent_return"
        ], turn_tool
        assert set(turn_tool["inputSchema"]["properties"]["progress_checkpoint"]["required"]) == set(progress), turn_tool
        assert "project_progress_proof" in turn_tool["inputSchema"]["properties"], turn_tool
        assert "capability_route_receipt" in turn_tool["inputSchema"]["properties"], turn_tool
        assert set(turn_tool["inputSchema"]["properties"]["visible_progress_assertion"]["required"]) == {
            "schema", "observation_source", "host_thread_id", "host_turn_id", "host_message_id",
            "selection", "message_phase", "last_confirmed_sentence", "source", "publication_kind",
            "envelope_version", "raw_prompt_stored", "raw_transcript_stored",
        }, turn_tool
        selector_schema = turn_tool["inputSchema"]["properties"]["visible_progress_assertion"]["properties"]["selection"]
        assert selector_schema["enum"] == [
            "current_visible_assistant", "latest_durable_assistant", "latest_assistant"
        ], turn_tool
        selector_description = str(selector_schema["description"])
        assert "current_visible_assistant" in selector_description, selector_schema
        assert "display-only" in selector_description, selector_schema
        assert "latest_durable_assistant" in selector_description, selector_schema
        assert "latest_assistant" in selector_description, selector_schema
        turn_description = str(turn_tool["description"])
        assert "current_visible_assistant" in turn_description, turn_tool
        assert "same-workline" in turn_description, turn_tool
        assert "caller-provided capsule" in turn_description, turn_tool
        assert "continuation_capsule" not in turn_tool["inputSchema"]["properties"], turn_tool
        assert "latest_assistant" in turn_description, turn_tool
        checkpointed = json.loads(replies[2]["result"]["content"][0]["text"])
        recovered = json.loads(replies[3]["result"]["content"][0]["text"])
        normal_recovered = json.loads(replies[4]["result"]["content"][0]["text"])
        assert checkpointed["available"] is True, checkpointed
        assert checkpointed["code"] == "H7_VISIBLE_PROGRESS_RECEIPT_RECONCILED_READY", checkpointed
        receipt_hash = str((checkpointed.get("checkpoint") or {}).get("visibleProgress", {}).get("payloadHash", ""))
        v4_tail_assertion = visible_tail_assertion(
            host_thread_id=thread_id,
            sentence=progress["last_confirmed_sentence"],
            phase=progress["current_phase"],
            current_step=progress["current_step"],
            next_action=progress["next_action"],
            host_message_id="item-mcp-visible-progress-v4",
            receipt_hash=receipt_hash,
        )
        v4_normal_tail_assertion = {
            **v4_tail_assertion,
            "host_message_id": "item-mcp-visible-progress-v4-durable",
            "selection": "latest_durable_assistant",
        }
        followup_requests = "\n".join(
            [
                json.dumps(
                    {
                        "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                            "name": "brain_turn",
                            "arguments": {
                                "phase": "open", "turn_intent": "continuity",
                                "capability_route_receipt": route_receipt,
                                "visible_progress_assertion": v4_tail_assertion,
                            },
                            "_meta": metadata,
                        },
                    }
                ),
                json.dumps(
                    {
                        "jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
                            "name": "brain_turn",
                            "arguments": {
                                "phase": "open", "turn_intent": "continuity",
                                "capability_route_receipt": route_receipt,
                                "visible_progress_assertion": v4_normal_tail_assertion,
                            },
                            "_meta": metadata,
                        },
                    }
                ),
            ]
        ) + "\n"
        followup = subprocess.run(
            [
                sys.executable, "-B", str(ROOT / "runtime" / "brain_mcp.py"),
                "--package-root", str(ROOT), "--memory-root", str(memory_root),
            ],
            input=followup_requests,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
            env=environment,
        )
        assert followup.returncode == 0, followup.stderr
        followup_replies = {reply["id"]: reply for reply in (json.loads(line) for line in followup.stdout.splitlines() if line.strip())}
        recovered = json.loads(followup_replies[3]["result"]["content"][0]["text"])
        normal_recovered = json.loads(followup_replies[4]["result"]["content"][0]["text"])
        assert recovered["context"]["task"]["lastConfirmedSentence"] == progress["last_confirmed_sentence"], recovered
        assert recovered["context"]["task"]["currentPhase"] == progress["current_phase"], recovered
        assert recovered["context"]["task"]["nextAction"] == progress["next_action"], recovered
        assert recovered["context"]["task"]["projectProgress"]["state"] == "current", recovered
        assert normal_recovered["available"] is True, normal_recovered
        assert normal_recovered["visibleTailAssertion"]["selection"] == "current_visible_assistant", normal_recovered
        assert normal_recovered["autoVisibleTailFinalization"] == {}, normal_recovered
        assert checkpointed["runtimeReceipt"]["capabilityRouteReceipt"]["routeHash"] == route_receipt["routeHash"], checkpointed
        assert recovered["runtimeReceipt"]["capabilityRouteReceipt"]["selectionHash"] == canonical_hash(route_receipt), recovered
        serialized = json.dumps({"checkpointed": checkpointed, "recovered": recovered}, ensure_ascii=False)
        assert thread_id not in serialized
        assert str(host_root) not in serialized
        assert "rawPromptStored\":true" not in serialized
        assert "rawTranscriptStored\":true" not in serialized


def test_cli_utf8_checkpoint_fallback_preserves_h7_authority() -> None:
    """A dead MCP transport must not force a Hook revival or Desktop restart."""

    with tempfile.TemporaryDirectory(prefix="super-brain-cli-progress-checkpoint-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "7" * 24
        workspace_key = host_workspace_key(host_root)
        task_id = "task-cli-progress-checkpoint"
        write_native_memory_snapshot(state_root / "workspace")
        seeded = invoke_contract(
            [
                "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
                "-FocusId", "hookless-fallback", "-FocusLabel", "Hookless fallback", "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue the H7 repair", "-CurrentPhase", "old phase", "-CurrentStep", "old step",
                "-LastConfirmedSentence", "Old checkpoint.", "-LastConfirmedSource", "assistant_commitment",
                "-NextAction", "old next action", "-PendingSteps", "old next action", "-StateRoot", str(state_root), "-Json",
            ]
        )
        assert seeded["ok"] is True
        progress = {
            "last_confirmed_sentence": "MCP 传输不可用时，H7 仍通过受控 CLI 检查点继续。",
            "source": "assistant_visible_reply",
            "current_phase": "H7 CLI 回退验证",
            "current_step": "用 UTF-8 Base64 写入助手进度。",
            "next_action": "读取 H7 证据并恢复主线。",
        }
        encoded = base64.b64encode(json.dumps(progress, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).decode("ascii")
        proof_path = host_root / "cli-progress-evidence.txt"
        proof_path.write_text("cli progress proof evidence\n", encoding="utf-8")
        project_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": progress["current_phase"],
            "currentStep": progress["current_step"],
            "completedItems": [],
            "projectEvidence": [{"kind": "project_file", "relativePath": proof_path.name, "sha256": file_sha256(proof_path)}],
            "verificationResults": [],
            "nextAction": progress["next_action"],
        }
        encoded_project_proof = base64.b64encode(
            json.dumps(project_proof, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        route_receipt = native_capability_route_receipt()
        encoded_route_receipt = base64.b64encode(
            json.dumps(route_receipt, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        environment = os.environ.copy()
        environment["CODEX_THREAD_ID"] = session_key
        completed = subprocess.run(
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
                "checkpoint",
                "--turn-intent",
                "continuity",
                "--progress-checkpoint-base64",
                encoded,
                "--project-progress-proof-base64",
                encoded_project_proof,
                "--capability-route-receipt-base64",
                encoded_route_receipt,
            ],
            cwd=str(host_root),
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
        )
        assert completed.returncode == 0, completed.stderr
        checkpointed = json.loads(completed.stdout)
        assert checkpointed["available"] is True, checkpointed
        assert checkpointed["code"] == "H7_VISIBLE_PROGRESS_RECEIPT_RECONCILED_READY", checkpointed
        assert checkpointed["context"]["task"]["lastConfirmedSentence"] == progress["last_confirmed_sentence"], checkpointed
        assert checkpointed["context"]["task"]["currentStep"] == progress["current_step"], checkpointed
        assert checkpointed["runtimeReceipt"]["capabilityRouteReceipt"]["routeHash"] == route_receipt["routeHash"], checkpointed
        restart_assertion = visible_tail_assertion(
            host_thread_id=session_key,
            sentence=progress["last_confirmed_sentence"],
            phase=progress["current_phase"],
            current_step=progress["current_step"],
            next_action=progress["next_action"],
            host_message_id="item-cli-process-restart-visible-tail",
            receipt_hash=str((checkpointed.get("checkpoint") or {}).get("visibleProgress", {}).get("payloadHash", "")),
        )
        encoded_restart_assertion = base64.b64encode(
            json.dumps(restart_assertion, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        restarted = subprocess.run(
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
                "continuity",
                "--recovery-event",
                "restart",
                "--visible-progress-assertion-base64",
                encoded_restart_assertion,
            ],
            cwd=str(host_root),
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
        )
        assert restarted.returncode == 0, restarted.stderr
        restarted_result = json.loads(restarted.stdout)
        assert restarted_result["available"] is True, restarted_result
        assert restarted_result["recoveryPresentation"]["openingLine"] == (
            "已接上：" + progress["last_confirmed_sentence"]
        ), restarted_result
        assert restarted_result["runtimeReceipt"]["recoveryPresentation"]["required"] is True, restarted_result
        assert "openingLine" not in restarted_result["runtimeReceipt"]["recoveryPresentation"], restarted_result
        evidence = subprocess.run(
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
                "evidence",
            ],
            cwd=str(host_root),
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
        )
        assert evidence.returncode == 0, evidence.stderr
        assert json.loads(evidence.stdout)["code"] == "H7_EVIDENCE_CURRENT", evidence.stdout


def test_cli_visible_tail_transport_unwraps_helper_and_reports_parse_errors() -> None:
    """CLI transport keeps helper status wrapping separate from H7 schema checks."""

    with tempfile.TemporaryDirectory(prefix="super-brain-cli-visible-tail-") as directory:
        state_root = Path(directory) / "state"
        memory_root = state_root / "shared"
        host_root = Path(directory) / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + "8" * 24
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, host_root, session_key, task_id="task-cli-visible-tail")
        contract_path = (
            state_root
            / "workspace"
            / "runtime-state"
            / "execution-contracts"
            / contract_file_name("task-cli-visible-tail", host_workspace_key(host_root))
        )
        before_contract = contract_path.read_bytes()
        environment = os.environ.copy()
        environment["CODEX_THREAD_ID"] = session_key
        command_prefix = [
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
            "continuity",
        ]

        raw_helper = observe_visible_context_message(
            host_thread_id=session_key,
            turn_id="turn-cli-helper-raw",
            message_id="message-cli-helper-raw",
            phase="commentary",
            text="The raw current-tail helper result must cross the CLI as one exact Base64 payload.",
        )
        assert raw_helper["ok"] is True, raw_helper
        raw_helper_base64 = base64.b64encode(
            json.dumps(raw_helper, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        accepted = subprocess.run(
            command_prefix + ["--visible-progress-assertion-base64", raw_helper_base64],
            cwd=str(host_root),
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
        )
        assert accepted.returncode == 0, accepted.stderr
        accepted_result = json.loads(accepted.stdout)
        assert accepted_result["available"] is True, accepted_result
        assert accepted_result["visibleTailAssertion"]["continuationRole"] == "display_only", accepted_result
        assert accepted_result["continuityMapping"]["source"] == "current_visible_assistant", accepted_result
        assert contract_path.read_bytes() == before_contract

        valid_json = json.dumps(raw_helper, ensure_ascii=False, separators=(",", ":"))
        invalid_invocations = (
            ["--visible-progress-assertion-base64", "not-valid-base64!"],
            ["--visible-progress-assertion-json", "{"],
            ["--visible-progress-assertion-json", "[]"],
            [
                "--visible-progress-assertion-json",
                valid_json,
                "--visible-progress-assertion-base64",
                raw_helper_base64,
            ],
        )
        for arguments in invalid_invocations:
            rejected = subprocess.run(
                command_prefix + list(arguments),
                cwd=str(host_root),
                env=environment,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="strict",
                check=False,
            )
            assert rejected.returncode == 0, rejected.stderr
            rejected_result = json.loads(rejected.stdout)
            assert rejected_result["available"] is False, rejected_result
            assert rejected_result["code"] == "H7_VISIBLE_TAIL_ASSERTION_PAYLOAD_PARSE_INVALID", rejected_result
            assert contract_path.read_bytes() == before_contract


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
    test_native_capability_route_receipt_is_h7_bound_without_authorization()
    test_capability_route_receipt_rejects_paths_prompts_and_authorization()
    test_capability_route_hash_mismatch_withholds_h7_evidence()
    test_h7_accepts_the_actual_compact_router_receipt()
    test_project_progress_proof_fails_closed_on_missing_or_drift()
    test_checkpoint_refreshes_only_a_stale_project_progress_proof_through_h7()
    test_observed_visible_tail_must_match_the_checkpoint_before_reconcile()
    test_latest_assistant_progress_reconciles_without_user_anchor_selection()
    test_newer_preopen_assistant_message_blocks_walkback_to_older_durable_tail()
    test_open_auto_finalizes_latest_durable_visible_tail_without_walkback()
    test_normal_durable_selection_never_auto_aligns_and_explicit_fallback_does()
    test_close_resumes_parent_and_hashes_completion_reference()
    test_checkpoint_binds_latest_assistant_progress_across_restart()
    test_model_switch_reopens_same_scoped_h7_anchor_without_model_state()
    test_same_workline_visible_context_is_required_and_observation_stays_transient()
    test_real_session_compaction_then_fresh_h7_open_preserves_exact_progress()
    test_public_cross_session_rebind_then_fresh_h7_open_preserves_exact_progress()
    test_h7_open_atomically_rebinds_one_unique_contract_from_the_exact_current_tail()
    test_h7_open_never_rebinds_an_ambiguous_workspace_contract_set()
    test_observed_user_correction_then_fresh_h7_open_uses_corrected_progress()
    test_stale_handoff_summary_legacy_contract_and_memory_never_select_recovery_anchor()
    test_visible_progress_receipt_requires_exact_latest_anchor_and_user_attested_reconcile()
    test_strict_current_v4_tail_with_stale_project_proof_is_withheld_without_mutation()
    test_each_visible_progress_scope_field_drift_is_withheld()
    test_close_rejects_user_attested_checkpoint_outside_correction_without_mutation()
    test_visible_progress_receipt_is_scope_bound_across_session_rebind()
    test_checkpoint_scope_change_without_fresh_proof_fails_atomically()
    test_invalid_phase_fails_without_state_write()
    test_greeting_stays_on_direct_host_path()
    test_side_message_stays_on_direct_host_path()
    test_super_brain_issue_projects_root_rule_and_protocol()
    test_registry_change_stales_h7_evidence_until_reopened()
    test_mcp_turn_binds_only_codex_request_metadata_scope()
    test_mcp_checkpoint_recovers_latest_progress_after_visible_state_change()
    test_cli_utf8_checkpoint_fallback_preserves_h7_authority()
    test_cli_visible_tail_transport_unwraps_helper_and_reports_parse_errors()
    test_checkpoint_reconciles_after_uncertain_set_result()
    test_checkpoint_retries_one_unacknowledged_transport_with_same_transition_id_and_timeout_floor()
    test_checkpoint_does_not_retry_a_rejected_cas_transaction()
    test_checkpoint_set_replay_is_never_misreported_as_a_parent_return()
    print("runtime turn-runtime regression: passed (37/37)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
