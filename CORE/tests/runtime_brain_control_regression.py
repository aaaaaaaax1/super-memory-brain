from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
import json
import hashlib
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_VERSION = str(json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["version"])
sys.path.insert(0, str(ROOT / "runtime"))

from brain_control import (
    BrainControl,
    BrainControlError,
    read_card_projection,
    read_mcp_snapshot,
    read_mcp_task_projection,
)
from brain_context import (
    intent_context_pending_root,
    intent_context_projection_path,
    read_intent_context_projection,
)
from instruction_anchor_store import InstructionAnchorStore


def package_identity() -> dict[str, str]:
    raw = (ROOT / "manifest.json").read_bytes()
    manifest = json.loads(raw.decode("utf-8"))
    return {
        "packageVersion": str(manifest["version"]),
        "packageManifestHash": hashlib.sha256(raw).hexdigest(),
    }


def sqlite_artifact_hashes(db_path: Path) -> dict[str, str]:
    return {
        suffix: hashlib.sha256(artifact.read_bytes()).hexdigest()
        for suffix in ("", "-wal", "-shm", "-journal")
        if (artifact := db_path.with_name(db_path.name + suffix)).is_file()
    }


def actor_receipt(*, authorization: str = "test", actor_kind: str = "test") -> dict[str, object]:
    return {
        "schema": "super-brain.actor-receipt.v1",
        "actorKind": actor_kind,
        "actorId": "runtime_brain_control_regression",
        "authorization": authorization,
        "authorizationReceipt": "runtime-regression",
    }


def command(command_id: str, expected_revision: int, title: str = "Release policy") -> dict[str, object]:
    return {
        "commandType": "create_card" if expected_revision == 0 else "edit_card",
        "commandId": command_id,
        "aggregateId": "decision-release-policy",
        "expectedRevision": expected_revision,
        "kind": "decision",
        "scope": {"kind": "project", "key": "super-brain"},
        "lifecycle": "active",
        "authority": "user_confirmed",
        "privacyClass": "private",
        "title": title,
        "payload": {
            "schema": "super-brain.card.decision.v1",
            "summary": title,
            "rationale": "The release policy is verified before delivery.",
            "consequences": ["The release remains reproducible."],
            "applicability": ["release workflow"],
            "acceptanceCriteria": ["release evidence is present"],
            "tags": ["release"],
        },
        "evidenceRefs": ["tests/runtime_brain_control_regression.py"],
        "actorReceipt": actor_receipt(authorization="user_confirmed"),
        "reason": "record the verified release policy",
        "source": "runtime_brain_control_regression",
    }


def intent_contract(material_unknowns: list[str] | None = None) -> dict[str, object]:
    return {
        "schema": "super-brain.intent-contract.v2",
        "literalRequestDigest": "editable notebook without direct database writes",
        "resolvedOutcome": "Users edit notebook entries through governed commands.",
        "productRole": "local notebook UI backed by the command API",
        "integrationObligations": ["local UI edit flow", "governed command API", "mutation receipt"],
        "materialUnknowns": list(material_unknowns or []),
        "compatibilityGuards": ["no browser-side direct SQLite or database writes"],
        "preservedCapabilities": ["editable notebook", "history and rollback"],
        "acceptanceCriteria": ["an edit is visible and produces a receipt"],
        "governedEquivalent": "governed command editing through a loopback API",
        "autonomyTier": "align",
        "integrationMap": {
            "entryPoint": "notebook page",
            "userFlow": "open note, edit, save, observe receipt",
            "domainOwner": "BrainControl command engine",
            "stateOwner": "brain-state SQLite authority",
            "downstreamConsumers": ["notebook query projection", "history view"],
            "failureRecovery": "CAS conflict keeps draft and offers retry",
            "privacyPerformance": "loopback only and bounded payloads",
            "compatibilityMigration": "legacy records remain read-only until migration",
            "verification": "command API and real user edit-flow regression",
            "completionCondition": "edit, history, and rollback path all verified",
        },
        "investigationEvidence": ["runtime/brain_control.py command authority", "approved P-1 plan"],
        "materialBranches": [],
        "focusedQuestion": "",
        "preserveExistingFlow": True,
        "replacementReceipt": "",
        "componentResolution": {
            "requestedComponent": "direct database editor",
            "resolvedComponent": "governed command API",
            "outcomePreserved": True,
            "reason": "the command API preserves editing with receipts and rollback",
        },
    }


def instruction_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def task_request(
    command_id: str,
    *,
    expected_revision: int | None = None,
    initial_revision: int | None = None,
    next_action: str = "materialize the task projection",
) -> dict[str, object]:
    state = {
        "lifecycle": "active",
        "contractRevision": 11,
        "planFingerprint": "plan-task-authority-11",
        "currentPhase": "P0",
        "currentStep": "exercise durable task authority",
        "nextAction": next_action,
        "canonicalPlan": {
            "planId": "plan-task-authority",
            "generation": 1,
            "items": [
                {"itemId": "A", "ordinal": 1, "label": "persist aggregate", "status": "completed"},
                {"itemId": "B", "ordinal": 2, "label": "materialize projection", "status": "pending"},
            ],
        },
    }
    result: dict[str, object] = {
        "commandId": command_id,
        "taskId": "task-sqlite-authority",
        "taskInstanceId": "ti-" + "3" * 32,
        "workspaceKey": "ws-sqlite-authority",
        "ownerSessionKey": "sid-" + "4" * 24,
        "packageVersion": PACKAGE_VERSION,
        "state": state,
        "source": "runtime_brain_control_regression",
    }
    if expected_revision is not None:
        result["expectedRevision"] = expected_revision
    if initial_revision is not None:
        result["initialRevision"] = initial_revision
    return result


def write_task_compatibility_projection(
    control: BrainControl,
    event: dict[str, object],
    *,
    task_id: str | None = None,
    revision: int | None = None,
) -> tuple[Path, str]:
    payload = event["payload"]
    assert isinstance(payload, dict)
    projection = payload["projection"]
    artifact = {
        "schema": "super-brain.task-state-projection.v2",
        "taskId": task_id if task_id is not None else payload["taskId"],
        "revision": revision if revision is not None else payload["revision"],
        "entities": projection.get("entities", {}) if isinstance(projection, dict) else {},
        "lifecycle": projection.get("lifecycle", {}) if isinstance(projection, dict) else {},
    }
    path = control.workspace / "compatibility-projections" / f"{event['eventId']}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(artifact, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    path.write_bytes(raw)
    return path, hashlib.sha256(raw).hexdigest()


def record_task_compatibility_delivery(control: BrainControl, event: dict[str, object]) -> dict[str, object]:
    payload = event["payload"]
    assert isinstance(payload, dict)
    path, payload_hash = write_task_compatibility_projection(control, event)
    return control.record_task_compatibility_delivery(
        {
            "eventId": event["eventId"],
            "taskId": payload["taskId"],
            "workspaceKey": payload["workspaceKey"],
            "revision": payload["revision"],
            "projectionPath": str(path),
            "projectionHash": payload_hash,
            "source": "runtime_brain_control_regression",
        }
    )


def card_payload(kind: str) -> dict[str, object]:
    payloads: dict[str, dict[str, object]] = {
        "decision": {
            "schema": "super-brain.card.decision.v1",
            "summary": "Archive every release deliverable together.",
            "rationale": "A release is not complete until its delivery evidence is complete.",
            "consequences": ["The final release gate checks the archive."],
            "applicability": ["release"],
            "acceptanceCriteria": ["archive contains required artifacts"],
            "tags": ["delivery"],
        },
        "preference": {
            "schema": "super-brain.card.preference.v1",
            "statement": "Use concise progress receipts after each completed phase.",
            "conditions": ["long-running tasks"],
            "confidence": 92,
            "evidenceUses": 3,
            "tags": ["communication"],
        },
        "experience": {
            "schema": "super-brain.card.experience.v1",
            "context": "A release only existed in a tool default output directory.",
            "outcome": "The release was not yet usable by the intended recipient.",
            "lesson": "Check the agreed delivery contract before declaring completion.",
            "reuseConditions": ["build and release work"],
            "tags": ["delivery"],
        },
        "note": {
            "schema": "super-brain.card.note.v1",
            "body": "Keep the notebook editable through governed commands.",
            "tags": ["notebook"],
            "links": ["decision:governed-editing"],
        },
        "procedure": {
            "schema": "super-brain.card.procedure.v1",
            "objective": "Prepare a verified release archive.",
            "preconditions": ["build completed"],
            "steps": ["collect artifacts", "write evidence", "verify archive"],
            "verification": ["archive contains all required deliverables"],
            "tags": ["release"],
        },
        "reflection": {
            "schema": "super-brain.card.reflection.v1",
            "observation": "A local success was previously treated as final delivery.",
            "hypothesis": "The completion gate did not receive the delivery decision.",
            "proposedAction": "Bind verified delivery decisions into the task completion gate.",
            "evidence": ["regression:delivery-contract"],
            "confidence": 88,
            "tags": ["learning"],
        },
    }
    return json.loads(json.dumps(payloads[kind]))


def card_command(
    kind: str,
    command_id: str,
    aggregate_id: str,
    expected_revision: int,
    payload: dict[str, object],
    *,
    title: str | None = None,
    command_type: str | None = None,
) -> dict[str, object]:
    return {
        "commandType": command_type or ("create_card" if expected_revision == 0 else "edit_card"),
        "commandId": command_id,
        "aggregateId": aggregate_id,
        "expectedRevision": expected_revision,
        "kind": kind,
        "scope": {"kind": "regression", "key": aggregate_id},
        "lifecycle": "active",
        "authority": "user_confirmed",
        "privacyClass": "private",
        "title": title or f"{kind} regression card",
        "payload": payload,
        "evidenceRefs": ["tests/runtime_brain_control_regression.py"],
        "actorReceipt": actor_receipt(authorization="user_confirmed"),
        "reason": "exercise the typed card contract",
        "source": "runtime_brain_control_regression",
    }


def completion_decision_payload() -> dict[str, object]:
    return {
        "schema": "super-brain.card.decision.v2",
        "summary": "Archive all release deliverables together.",
        "rationale": "A generated installer alone is not the user-defined release outcome.",
        "consequences": ["Completion waits for delivery evidence."],
        "stageKinds": ["release"],
        "enforcement": "completion_gate",
        "completionCriteria": ["archive executable", "archive installer", "include release notes and test report"],
        "applicability": {"mode": "workspace_stage"},
        "tags": ["release", "delivery"],
    }


def decision_resolution_request(command_id: str | None = None) -> dict[str, object]:
    identity = package_identity()
    request: dict[str, object] = {
        "taskId": "task-decision-resolution",
        "taskInstanceId": "ti-" + "7" * 32,
        "workspaceKey": "ws-decision-resolution",
        "ownerSessionKey": "sid-" + "8" * 24,
        "stageKind": "release",
        "worklineId": "release-main",
        "intentFingerprint": "release-intent",
        "packageVersion": identity["packageVersion"],
        "packageManifestHash": identity["packageManifestHash"],
        "contractRevision": 12,
        "planFingerprint": "plan-decision-resolution-12",
    }
    if command_id is not None:
        request["commandId"] = command_id
        request["source"] = "runtime_brain_control_regression"
    return request


def test_card_contracts(root: Path) -> None:
    control = BrainControl(root / "typed-card-contracts")
    for kind in ("decision", "preference", "experience", "note", "procedure", "reflection"):
        aggregate_id = f"typed-{kind}"
        applied = control.apply(card_command(kind, f"{kind}-create", aggregate_id, 0, card_payload(kind)))
        assert applied["operation"] == "create" and applied["revision"] == 1
        if kind == "decision":
            migrated = control.get_card(aggregate_id)
            assert migrated is not None
            assert migrated["payload"]["schema"] == "super-brain.card.decision.v2"
            assert migrated["payload"]["enforcement"] == "advisory"
        projection = next(item for item in control.pending_outbox() if item["aggregateId"] == aggregate_id)
        assert projection["payload"]["redactedPayload"]["redacted"]
        assert "body" not in projection["payload"]["redactedPayload"]

        malformed = card_command(kind, f"{kind}-malformed", f"malformed-{kind}", 0, card_payload(kind))
        malformed_payload = malformed["payload"]
        assert isinstance(malformed_payload, dict)
        malformed_payload["unsupported"] = "must not become an untyped JSON escape hatch"
        try:
            control.apply(malformed)
            raise AssertionError(f"{kind} payload with an unsupported field must fail")
        except BrainControlError as exc:
            assert exc.code == "BRAIN_CONTROL_CARD_FIELD_UNSUPPORTED"

    untyped = card_command("note", "untyped-card", "untyped-card", 0, {"body": "missing schema"})
    try:
        control.apply(untyped)
        raise AssertionError("untyped card payload must fail")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_CARD_FIELD_REQUIRED"

    sensitive = card_command("note", "sensitive-card", "sensitive-card", 0, card_payload("note"))
    sensitive_payload = sensitive["payload"]
    assert isinstance(sensitive_payload, dict)
    sensitive_payload["body"] = "Bearer sk-abcdefghijk"
    try:
        control.apply(sensitive)
        raise AssertionError("credential-like values must fail admission")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_SENSITIVE_VALUE"


def test_typed_card_edit_supersede_and_rollback(root: Path) -> None:
    control = BrainControl(root / "typed-card-rollback")
    aggregate_id = "typed-procedure"
    initial_payload = card_payload("procedure")
    created = control.apply(card_command("procedure", "procedure-create", aggregate_id, 0, initial_payload))
    assert created["revision"] == 1

    revised_payload = card_payload("procedure")
    revised_steps = revised_payload["steps"]
    assert isinstance(revised_steps, list)
    revised_steps.append("record the final receipt")
    edited_request = card_command("procedure", "procedure-edit", aggregate_id, 1, revised_payload)
    edited = control.apply(edited_request)
    replayed = control.apply(edited_request)
    assert edited["revision"] == 2 and replayed["idempotent"] and replayed["eventId"] == edited["eventId"]

    superseded = control.apply(
        {
            "commandType": "supersede_card",
            "commandId": "procedure-supersede",
            "aggregateId": aggregate_id,
            "expectedRevision": 2,
            "replacementRef": "procedure:replacement-release-archive",
            "actorReceipt": actor_receipt(authorization="user_confirmed"),
            "reason": "replace the procedure with the verified successor",
            "source": "runtime_brain_control_regression",
        }
    )
    assert superseded["operation"] == "supersede" and superseded["lifecycle"] == "superseded"

    rolled_back = control.apply(
        {
            "commandType": "rollback_card",
            "commandId": "procedure-rollback",
            "aggregateId": aggregate_id,
            "expectedRevision": 3,
            "restoreRevision": 1,
            "actorReceipt": actor_receipt(authorization="user_confirmed"),
            "reason": "restore the prior verified procedure as a new revision",
            "source": "runtime_brain_control_regression",
        }
    )
    assert rolled_back["revision"] == 4 and rolled_back["operation"] == "rollback"
    assert rolled_back["rollbackOfRevision"] == 1
    restored = control.get_card(aggregate_id)
    assert restored is not None and restored["lifecycle"] == "active"
    assert restored["payload"]["steps"] == initial_payload["steps"]
    assert restored["revisionState"]["commandType"] == "rollback_card"
    assert restored["revisionState"]["rollbackOfRevision"] == 1

    connection = sqlite3.connect(control.db_path)
    try:
        try:
            connection.execute("UPDATE card_revisions SET state_json='{}' WHERE card_id=?", (aggregate_id,))
            raise AssertionError("card revision state must be immutable")
        except sqlite3.IntegrityError:
            pass
    finally:
        connection.close()


def test_decision_resolution_and_completion_gate(root: Path) -> None:
    control = BrainControl(root / "decision-resolution")
    decision = card_command(
        "decision",
        "release-decision-create",
        "release-decision",
        0,
        completion_decision_payload(),
        title="Release archive decision",
    )
    decision["scope"] = {"kind": "workspace", "key": "ws-decision-resolution"}
    created = control.apply(decision)
    assert created["revision"] == 1
    assert "nativeDecisionIndex" in created
    assert control.native_decision_index_manifest_path.is_file()

    resolved_request = decision_resolution_request("decision-resolve-1")
    resolved = control.resolve_decisions(resolved_request)
    assert resolved["ok"] and resolved["status"] == "bound" and resolved["decisionCount"] == 1
    assert resolved["packageManifestHash"] == package_identity()["packageManifestHash"]
    assert control.resolve_decisions(resolved_request)["idempotent"]

    check_request = decision_resolution_request()
    check_request["receiptId"] = resolved["receiptId"]
    check_request["bindingDigest"] = resolved["bindingDigest"]
    assert control.check_decision_resolution(check_request)["ok"]
    foreign_check = dict(check_request)
    foreign_check["taskId"] = "task-decision-resolution-foreign"
    foreign = control.check_decision_resolution(foreign_check)
    assert not foreign["ok"] and foreign["code"] == "BRAIN_CONTROL_DECISION_RECEIPT_STALE_OR_FOREIGN"
    context = control.get_decision_context(check_request)
    assert context["ok"] and context["constraints"][0]["summary"] == "Archive all release deliverables together."
    withheld = control.validate_decision_completion(check_request)
    assert not withheld["ok"] and withheld["code"] == "BRAIN_CONTROL_DECISION_COMPLETION_UNSATISFIED"

    item = resolved["decisions"][0]
    assert isinstance(item, dict)
    result_request = {
        **decision_resolution_request("decision-result-1"),
        "receiptId": resolved["receiptId"],
        "bindingDigest": resolved["bindingDigest"],
        "cardId": item["cardId"],
        "cardRevision": item["cardRevision"],
        "resultOk": True,
        "evidenceRefs": ["release-archive-manifest", "release-test-report"],
    }
    recorded = control.record_decision_result(result_request)
    assert recorded["ok"] and control.record_decision_result(result_request)["idempotent"]
    validated = control.validate_decision_completion(check_request)
    assert validated["ok"] and validated["completionCurrent"] and validated["results"][0]["resultId"].startswith("dcr-")

    revised = completion_decision_payload()
    criteria = revised["completionCriteria"]
    assert isinstance(criteria, list)
    criteria.append("verify the final archive hash")
    edit = card_command("decision", "release-decision-edit", "release-decision", 1, revised, title="Release archive decision")
    edit["scope"] = {"kind": "workspace", "key": "ws-decision-resolution"}
    control.apply(edit)
    stale = control.check_decision_resolution(check_request)
    assert not stale["ok"] and stale["code"] == "BRAIN_CONTROL_DECISION_RECEIPT_STALE"

    wrong_package = decision_resolution_request("decision-resolve-wrong-package")
    wrong_package["packageManifestHash"] = "0" * 64
    try:
        control.resolve_decisions(wrong_package)
        raise AssertionError("a caller-provided package manifest hash must not be trusted")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_DECISION_PACKAGE_MANIFEST_MISMATCH"

    no_decision_request = decision_resolution_request("decision-resolve-none")
    no_decision_request["workspaceKey"] = "ws-no-decision"
    no_decision = control.resolve_decisions(no_decision_request)
    assert no_decision["ok"] and no_decision["status"] == "none_applicable"

    invalid = card_command("decision", "invalid-gate", "invalid-gate", 0, completion_decision_payload())
    invalid["scope"] = {"kind": "workspace", "key": "ws-decision-resolution"}
    invalid["authority"] = "system"
    invalid["actorReceipt"] = actor_receipt(authorization="system", actor_kind="system")
    try:
        control.apply(invalid)
        raise AssertionError("completion gate without user confirmation must fail")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_DECISION_AUTHORITY_INVALID"

    connection = sqlite3.connect(control.db_path)
    try:
        try:
            connection.execute("UPDATE decision_resolution_receipts SET status='bound'")
            raise AssertionError("decision resolution receipts must be immutable")
        except sqlite3.IntegrityError:
            pass
    finally:
        connection.close()


def test_decision_scope_filtering(root: Path) -> None:
    control = BrainControl(root / "decision-scope")
    payload = completion_decision_payload()
    payload["applicability"] = {
        "mode": "scoped",
        "taskIds": ["task-scope-target"],
        "worklineIds": ["release-target"],
        "intentFingerprints": ["intent-scope-target"],
    }
    decision = card_command("decision", "scope-decision-create", "scope-decision", 0, payload)
    decision["scope"] = {"kind": "workspace", "key": "ws-decision-resolution"}
    control.apply(decision)

    matched_request = decision_resolution_request("scope-decision-match")
    matched_request.update(
        {
            "taskId": "task-scope-target",
            "worklineId": "release-target",
            "intentFingerprint": "intent-scope-target",
        }
    )
    assert control.resolve_decisions(matched_request)["status"] == "bound"

    foreign_task = decision_resolution_request("scope-decision-foreign-task")
    foreign_task.update(
        {
            "taskId": "task-scope-foreign",
            "worklineId": "release-target",
            "intentFingerprint": "intent-scope-target",
        }
    )
    assert control.resolve_decisions(foreign_task)["status"] == "none_applicable"

    foreign_workline = decision_resolution_request("scope-decision-foreign-workline")
    foreign_workline.update(
        {
            "taskId": "task-scope-target",
            "worklineId": "release-foreign",
            "intentFingerprint": "intent-scope-target",
        }
    )
    assert control.resolve_decisions(foreign_workline)["status"] == "none_applicable"

    unsafe = completion_decision_payload()
    del unsafe["applicability"]
    unscoped = card_command("decision", "scope-decision-unscoped", "scope-decision-unscoped", 0, unsafe)
    unscoped["scope"] = {"kind": "workspace", "key": "ws-decision-resolution"}
    try:
        control.apply(unscoped)
        raise AssertionError("new completion gates require explicit applicability")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_DECISION_APPLICABILITY_REQUIRED"


def test_memory_influence_uses_typed_cards_without_turning_candidates_into_constraints(root: Path) -> None:
    control = BrainControl(root / "memory-influence")

    def create_global(kind: str, aggregate_id: str, payload: dict[str, object], title: str) -> None:
        request = card_command(kind, f"memory-influence-{aggregate_id}", aggregate_id, 0, payload, title=title)
        request["scope"] = {"kind": "global", "key": "user"}
        control.apply(request)

    preference = card_payload("preference")
    preference.update(
        {
            "statement": "Use concise progress receipts after each completed release phase.",
            "conditions": ["release work"],
            "confidence": 92,
            "conflictState": "clear",
        }
    )
    create_global("preference", "memory-influence-preference", preference, "Release communication preference")

    expired_preference = card_payload("preference")
    expired_preference.update(
        {
            "statement": "This expired preference must not shape behavior.",
            "confidence": 98,
            "revalidateAfter": "2000-01-01",
        }
    )
    create_global("preference", "memory-influence-expired-preference", expired_preference, "Expired preference")

    experience = card_payload("experience")
    experience.update(
        {
            "context": "A release archive was prepared for delivery.",
            "lesson": "Check the agreed archive and evidence before declaring release completion.",
            "reuseConditions": ["release archive"],
            "prevention": "Verify the archive manifest before closeout.",
            "validationState": "adopted",
        }
    )
    create_global("experience", "memory-influence-experience", experience, "Release archive lesson")

    candidate_experience = card_payload("experience")
    candidate_experience.update({"lesson": "Candidate experience must not become advice.", "validationState": "candidate"})
    create_global("experience", "memory-influence-candidate-experience", candidate_experience, "Candidate experience")

    note = card_payload("note")
    note.update({"body": "Reference: the release archive must contain the installer and the test report."})
    create_global("note", "memory-influence-note", note, "Release archive reference")

    corrupted_note = card_payload("note")
    corrupted_note.update({"body": "?????? native prompt probe residue"})
    create_global("note", "memory-influence-corrupted-note", corrupted_note, "??????")

    procedure = card_payload("procedure")
    procedure.update(
        {
            "objective": "Prepare a verified release archive.",
            "preconditions": ["build completed"],
            "steps": ["collect artifacts", "write evidence", "verify archive"],
            "verification": ["archive contains required deliverables"],
        }
    )
    create_global("procedure", "memory-influence-procedure", procedure, "Release archive procedure")

    reflection = card_payload("reflection")
    reflection.update(
        {
            "observation": "Release archive completion was previously declared too early.",
            "proposedAction": "Consider making archive verification a reusable release check.",
            "candidateState": "validated",
        }
    )
    create_global("reflection", "memory-influence-reflection", reflection, "Release archive learning candidate")

    influence_request = {
        "workspaceKey": "ws-memory-influence",
        "taskId": "task-memory-influence",
        "taskInstanceId": "ti-memory-influence",
        "ownerSessionKey": "sid-memory-influence",
        "focus": "prepare release archive",
    }
    influence = control.get_memory_influence(influence_request)
    assert influence["ok"] and influence["schema"] == "super-brain.execution-memory-influence.v1"
    assert influence["kindEffects"] == {
        "note": "reference_only",
        "preference": "behavior_shaping",
        "experience": "advice_and_reuse",
        "decision": "receipt_bound_constraint",
        "procedure": "governed_steps",
        "reflection": "learning_candidate_only",
    }
    assert [item["cardId"] for item in influence["behaviorGuidance"]] == ["memory-influence-preference"]
    assert influence["behaviorGuidance"][0]["effect"] == "shape_behavior"
    assert [item["cardId"] for item in influence["reusableAdvice"]] == ["memory-influence-experience"]
    assert influence["reusableAdvice"][0]["effect"] == "reuse_as_advice"
    assert [item["cardId"] for item in influence["procedureSteps"]] == ["memory-influence-procedure"]
    assert influence["procedureSteps"][0]["steps"] == ["collect artifacts", "write evidence", "verify archive"]
    assert [item["cardId"] for item in influence["references"]] == ["memory-influence-note"]
    assert influence["references"][0]["effect"] == "reference_only"
    assert [item["cardId"] for item in influence["learningCandidates"]] == ["memory-influence-reflection"]
    assert influence["learningCandidates"][0]["directConstraint"] is False
    assert influence["decisionHandling"]["requiresDecisionReceipt"] is True
    assert influence["focusStored"] is False and influence["rawPromptStored"] is False
    assert influence["omitted"]["expired"] >= 1 and influence["omitted"]["notReady"] >= 1
    assert influence["omitted"]["unsafe"] >= 1
    assert "memory-influence-corrupted-note" not in {item["cardId"] for item in influence["references"]}

    no_focus = control.get_memory_influence({key: value for key, value in influence_request.items() if key != "focus"})
    assert no_focus["behaviorGuidance"]
    assert not no_focus["references"] and not no_focus["reusableAdvice"] and not no_focus["procedureSteps"] and not no_focus["learningCandidates"]

    decision = card_command(
        "decision",
        "memory-influence-decision-create",
        "memory-influence-decision",
        0,
        completion_decision_payload(),
        title="Release archive completion decision",
    )
    decision["scope"] = {"kind": "workspace", "key": "ws-memory-influence"}
    control.apply(decision)
    decision_request = decision_resolution_request("memory-influence-resolve")
    decision_request.update(
        {
            "taskId": "task-memory-influence",
            "taskInstanceId": "ti-memory-influence",
            "workspaceKey": "ws-memory-influence",
            "ownerSessionKey": "sid-memory-influence",
            "focus": "prepare release archive",
        }
    )
    resolved = control.resolve_decisions(decision_request)
    assert resolved["status"] == "bound"
    context_request = decision_resolution_request()
    context_request.update(
        {
            "taskId": "task-memory-influence",
            "taskInstanceId": "ti-memory-influence",
            "workspaceKey": "ws-memory-influence",
            "ownerSessionKey": "sid-memory-influence",
            "receiptId": resolved["receiptId"],
            "bindingDigest": resolved["bindingDigest"],
            "focus": "prepare release archive",
        }
    )
    context = control.get_decision_context(context_request)
    assert context["constraints"][0]["enforcement"] == "completion_gate"
    assert context["memoryInfluence"]["procedureSteps"][0]["cardId"] == "memory-influence-procedure"


def test_task_scoped_trial_projection_is_nonbinding_and_hash_bound(root: Path) -> None:
    """A staged reflection only becomes a trial hint after a scoped receipt exists."""

    with tempfile.TemporaryDirectory(prefix="super-brain-typed-memory-trial-projection-") as directory:
        control = BrainControl(Path(directory))
        task_id = "task-typed-memory-trial"
        task_instance_id = "ti-" + "a" * 32
        workspace_key = "ws-" + "b" * 24
        session_key = "sid-" + "c" * 24
        reflection = card_payload("reflection")
        reflection.update(
            {
                "candidateState": "staged",
                "suggestedKind": "experience",
                "tags": ["系统学习候选", "建议：experience"],
            }
        )
        create = card_command(
            "reflection",
            "typed-memory-trial-create",
            "typed-memory-trial-reflection",
            0,
            reflection,
            title="Scoped release learning trial",
        )
        create.update(
            {
                "scope": {"kind": "task_instance", "key": task_instance_id},
                "lifecycle": "proposed",
                "authority": "system",
                "actorReceipt": actor_receipt(authorization="system", actor_kind="system"),
            }
        )
        control.apply(create)
        request = {
            "workspaceKey": workspace_key,
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "ownerSessionKey": session_key,
            "focus": "release archive verification",
        }
        before = control.get_memory_influence(request)
        assert before["learningCandidates"]
        assert before["learningCandidates"][0]["trialState"] == "not_started"
        assert before["learningCandidates"][0]["directConstraint"] is False

        token = hashlib.sha256(task_instance_id.encode("utf-8")).hexdigest()
        snapshot_path = control.workspace / "runtime-state" / "typed-memory-trial-snapshots" / f"{token}.json"
        snapshot = {
            "schema": "super-brain.typed-memory-trial-snapshot.v1",
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "packageVersion": package_identity()["packageVersion"],
            "createdAt": datetime.now(UTC).isoformat(),
            "sourceHash": "d" * 64,
            "memoryRefs": [
                {
                    "cardId": "typed-memory-trial-reflection",
                    "cardRevision": 1,
                    "kind": "reflection",
                    "effect": "learning_candidate_only",
                }
            ],
            "effects": [{"kind": "reflection", "effect": "learning_candidate_only"}],
            "trialState": "observed",
            "privacy": {
                "rawPromptStored": False,
                "rawSummaryStored": False,
                "rawTranscriptStored": False,
                "memoryBodyStored": False,
            },
        }
        snapshot_raw = json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        snapshot_path.parent.mkdir(parents=True, exist_ok=True)
        snapshot_path.write_bytes(snapshot_raw)
        observed = control.get_memory_influence(request)
        trial_item = observed["learningCandidates"][0]
        assert trial_item["trialState"] == "observed"
        assert trial_item["trialVerdict"] == "inconclusive"
        assert trial_item["trialEligible"] is True
        control.publish_native_memory_influence_snapshot()
        native = json.loads(control.native_memory_influence_snapshot_path.read_text(encoding="utf-8"))
        native_item = next(entry["item"] for entry in native["entries"] if entry["item"]["cardId"] == "typed-memory-trial-reflection")
        assert native_item["trialState"] == "observed"

        receipt_path = control.workspace / "runtime-state" / "typed-memory-trial-receipts" / f"{token}.json"
        receipt = {
            "schema": "super-brain.typed-memory-trial-receipt.v1",
            "receiptId": "typed-memory-trial-" + task_instance_id,
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "packageVersion": package_identity()["packageVersion"],
            "createdAt": datetime.now(UTC).isoformat(),
            "verdict": "passed",
            "trialState": "closed",
            "receiptHash": "e" * 64,
            "sourceHashes": {"snapshot": hashlib.sha256(snapshot_raw).hexdigest(), "taskVerification": "f" * 64, "verifiedOutcome": "0" * 64, "completionGuard": "1" * 64},
            "memoryRefs": snapshot["memoryRefs"],
            "effects": snapshot["effects"],
            "checks": {"taskVerification": True, "taskScopedGuard": True, "realUserPath": True, "verifiedOutcome": True, "completionGuard": True},
            "reasonCode": "TYPED_MEMORY_TRIAL_PASSED",
            "privacy": snapshot["privacy"],
        }
        receipt_path.parent.mkdir(parents=True, exist_ok=True)
        receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")), encoding="utf-8")
        passed = control.get_memory_influence(request)["learningCandidates"][0]
        assert passed["trialState"] == "closed" and passed["trialVerdict"] == "passed"
        assert passed["trialReceiptHash"] == hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        snapshot["memoryRefs"][0]["cardRevision"] = 2
        snapshot_path.write_text(json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(",", ":")), encoding="utf-8")
        invalid = control.get_memory_influence(request)["learningCandidates"][0]
        assert invalid["trialState"] == "not_started" and invalid["trialVerdict"] == "absent"


def test_offline_memory_consolidation_is_read_only_and_privacy_bound(root: Path) -> None:
    state_root = root / "offline-memory-consolidation"
    control = BrainControl(state_root)

    def apply_card(request: dict[str, object]) -> None:
        request["scope"] = {"kind": "global", "key": "user"}
        request["privacyClass"] = "private"
        control.apply(request)

    quick_payload = {
        "schema": "super-brain.card.note.v1",
        "body": "Release evidence must be checked before announcing completion.",
        "tags": ["快速记录", "待学习", "建议：note"],
        "links": [],
        "pinned": False,
    }
    apply_card(card_command("note", "consolidation-quick", "consolidation-quick", 0, quick_payload, title="Release evidence"))
    current_payload = {
        "schema": "super-brain.card.note.v1",
        "body": "Release evidence must be checked before announcing completion.",
        "tags": ["release"],
        "links": [],
        "pinned": False,
    }
    apply_card(card_command("note", "consolidation-current", "consolidation-current", 0, current_payload, title="Release evidence"))

    reflection_payload = card_payload("reflection")
    reflection_payload.update(
        {
            "candidateState": "staged",
            "tags": ["系统学习候选", "待用户采纳", "建议：experience"],
        }
    )
    reflection = card_command("reflection", "consolidation-reflection", "consolidation-reflection", 0, reflection_payload, title="Release learning")
    reflection["lifecycle"] = "proposed"
    reflection["authority"] = "system"
    reflection["actorReceipt"] = actor_receipt(authorization="system", actor_kind="system")
    apply_card(reflection)

    status_before = control.status()
    snapshot_before = control.native_memory_influence_snapshot_path.read_bytes()
    connection = sqlite3.connect(control.db_path)
    try:
        counts_before = {
            table: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in ("cards", "card_revisions", "command_log", "events", "outbox")
        }
    finally:
        connection.close()

    result = control.plan_offline_memory_consolidation(
        {"scope": {"kind": "global", "key": "user"}, "privacyClass": "private", "maxProposals": 12}
    )
    assert result["schema"] == "super-brain.memory-consolidation-plan.v1"
    assert result["directDurableWrite"] is False and result["requiresUserConfirmation"] is True
    assert result["rawTranscriptStored"] is False and result["rawPromptStored"] is False
    exact = next(item for item in result["proposals"] if item["recommendation"] == "archive_exact_duplicate_candidate")
    assert "cardId" not in exact["candidate"] and "cardRef" in exact["candidate"]
    assert "cardId" not in exact["target"] and "cardRef" in exact["target"]
    rendered = json.dumps(result, ensure_ascii=False)
    assert "Release evidence must be checked" not in rendered
    assert "Release learning" not in rendered

    status_after = control.status()
    assert status_after == status_before
    assert control.native_memory_influence_snapshot_path.read_bytes() == snapshot_before
    connection = sqlite3.connect(control.db_path)
    try:
        counts_after = {
            table: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in ("cards", "card_revisions", "command_log", "events", "outbox")
        }
    finally:
        connection.close()
    assert counts_after == counts_before


def test_cognitive_enforce_projects_typed_memory_into_the_real_pre_mutation_gate(root: Path) -> None:
    """The governed mutation gate must consume typed memory, not merely expose an API."""

    state_root = root / "cognitive-enforce-memory-influence"
    control = BrainControl(state_root)

    def create_global(kind: str, aggregate_id: str, payload: dict[str, object], title: str) -> None:
        request = card_command(kind, f"cognitive-memory-{aggregate_id}", aggregate_id, 0, payload, title=title)
        request["scope"] = {"kind": "global", "key": "user"}
        control.apply(request)

    preference = card_payload("preference")
    preference.update(
        {
            "statement": "Keep delivery updates compact and evidence-led.",
            "conditions": ["release work"],
            "confidence": 92,
            "conflictState": "clear",
        }
    )
    create_global("preference", "gate-preference", preference, "Delivery communication preference")

    experience = card_payload("experience")
    experience.update(
        {
            "context": "A release archive was prepared for delivery.",
            "lesson": "Verify the archive manifest before declaring release completion.",
            "reuseConditions": ["release archive"],
            "prevention": "Check deliverables and test evidence together.",
            "validationState": "adopted",
        }
    )
    create_global("experience", "gate-experience", experience, "Release archive lesson")

    note = card_payload("note")
    note.update({"body": "Reference: the release archive contains the installer and test report."})
    create_global("note", "gate-note", note, "Release archive reference")

    procedure = card_payload("procedure")
    procedure.update(
        {
            "objective": "Prepare a verified release archive.",
            "preconditions": ["build completed"],
            "steps": ["collect artifacts", "write evidence", "verify archive"],
            "verification": ["archive contains required deliverables"],
        }
    )
    create_global("procedure", "gate-procedure", procedure, "Release archive procedure")

    reflection = card_payload("reflection")
    reflection.update(
        {
            "observation": "A release archive was previously declared complete too early.",
            "proposedAction": "Consider adding archive verification to the reusable release process.",
            "candidateState": "validated",
        }
    )
    create_global("reflection", "gate-reflection", reflection, "Release archive learning candidate")

    environment = os.environ.copy()
    environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
    environment["SUPER_BRAIN_WORKSPACE_KEY"] = "ws-cognitive-enforce-memory"
    completed = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(ROOT / "scripts" / "cognitive-enforce.ps1"),
            "-Query",
            "prepare release archive",
            "-TaskId",
            "task-cognitive-enforce-memory",
            "-SessionKey",
            "sid-cognitive-enforce-memory",
            "-Phase",
            "BeforeMutation",
            "-AllowMissingPreflight",
            "-Json",
        ],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )
    assert completed.returncode == 0, completed.stderr or completed.stdout
    result = json.loads(completed.stdout)
    influence = result["memoryInfluence"]
    assert influence["available"] is True and influence["ok"] is True
    assert influence["rawPromptStored"] is False and influence["focusStored"] is False
    assert [item["cardId"] for item in influence["behaviorGuidance"]] == ["gate-preference"]
    assert [item["cardId"] for item in influence["reusableAdvice"]] == ["gate-experience"]
    assert [item["cardId"] for item in influence["procedureSteps"]] == ["gate-procedure"]
    assert [item["cardId"] for item in influence["references"]] == ["gate-note"]
    assert [item["cardId"] for item in influence["learningCandidates"]] == ["gate-reflection"]
    assert influence["learningCandidates"][0]["directConstraint"] is False
    assert influence["decisionHandling"]["requiresDecisionReceipt"] is True


def test_mcp_snapshot_publisher(root: Path) -> None:
    control = BrainControl(root / "mcp-snapshot")
    control.apply(card_command("note", "snapshot-note", "snapshot-note", 0, card_payload("note")))
    imported = control.import_task(task_request("snapshot-task", initial_revision=0))
    try:
        control.publish_mcp_snapshot()
        raise AssertionError("manual MCP publishing must not bypass pending durable deliveries")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_MCP_SNAPSHOT_OUTBOX_PENDING"

    materialized = control.materialize_outbox()
    assert materialized["blockedMcpDeliveryEvents"] == 0
    assert materialized["materializedEventCount"] == 2
    published = materialized["mcpSnapshot"]
    assert isinstance(published, dict)
    assert imported["outboxEventId"]
    assert published["ok"] and Path(published["path"]).is_file()
    snapshot = read_mcp_snapshot(published["path"])
    assert snapshot["ok"] and snapshot["available"]
    assert snapshot["status"]["cards"] == 1
    assert snapshot["status"]["taskAggregates"] == 1
    assert len(snapshot["taskProjectionRefs"]) == 1
    assert "task-sqlite-authority" not in json.dumps(snapshot, ensure_ascii=False)
    assert not control.pending_outbox()

    snapshot_path = Path(published["path"])
    tampered = json.loads(snapshot_path.read_text(encoding="utf-8"))
    tampered["status"]["cards"] = 99
    snapshot_path.write_text(json.dumps(tampered, ensure_ascii=False), encoding="utf-8")
    assert read_mcp_snapshot(snapshot_path)["code"] == "BRAIN_CONTROL_MCP_SNAPSHOT_UNTRUSTED"


def test_mcp_reads_published_control_snapshot(root: Path) -> None:
    state_root = root / "mcp-published-state"
    memory_root = state_root / "shared"
    control = BrainControl(state_root)
    control.apply(card_command("note", "mcp-note", "mcp-note", 0, card_payload("note")))
    materialized = control.materialize_outbox()
    assert materialized["mcpSnapshot"]
    requests = "\n".join(
        [
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {"name": "brain_status", "arguments": {}},
                }
            ),
        ]
    ) + "\n"
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
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    replies = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    status_reply = next(reply for reply in replies if reply.get("id") == 2)
    content = status_reply["result"]["content"][0]["text"]
    status = json.loads(content)
    snapshot = status["controlPlaneSnapshot"]
    assert snapshot["available"] and snapshot["status"]["cards"] == 1


def test_mcp_rejects_future_control_snapshot(root: Path) -> None:
    state_root = root / "mcp-future-state"
    control = BrainControl(state_root)
    control.apply(card_command("note", "future-note", "future-note", 0, card_payload("note")))
    materialized = control.materialize_outbox()
    snapshot_path = Path(materialized["mcpSnapshot"]["path"])
    value = json.loads(snapshot_path.read_text(encoding="utf-8"))
    body = {key: nested for key, nested in value.items() if key != "payloadHash"}
    body["generatedAt"] = (datetime.now(UTC) + timedelta(hours=1)).isoformat().replace("+00:00", "Z")
    value = {
        **body,
        "payloadHash": hashlib.sha256(
            json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
    }
    snapshot_path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    assert read_mcp_snapshot(snapshot_path, now=datetime(2026, 8, 3, 12, tzinfo=UTC))["code"] == "BRAIN_CONTROL_MCP_SNAPSHOT_FUTURE"


def test_mcp_snapshot_withholds_stale_or_pending_delivery(root: Path) -> None:
    state_root = root / "mcp-snapshot-freshness"
    control = BrainControl(state_root)
    control.apply(card_command("note", "mcp-freshness-note", "mcp-freshness-note", 0, card_payload("note")))
    materialized = control.materialize_outbox()
    snapshot_path = Path(materialized["mcpSnapshot"]["path"])

    def rewrite_snapshot(mutator) -> None:
        value = json.loads(snapshot_path.read_text(encoding="utf-8"))
        body = {key: nested for key, nested in value.items() if key != "payloadHash"}
        mutator(body)
        snapshot = {
            **body,
            "payloadHash": hashlib.sha256(
                json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
            ).hexdigest(),
        }
        snapshot_path.write_text(json.dumps(snapshot, ensure_ascii=False), encoding="utf-8")

    rewrite_snapshot(
        lambda body: body.update(
            {
                "generatedAt": (datetime.now(UTC) - timedelta(days=2)).isoformat().replace("+00:00", "Z"),
            }
        )
    )
    stale = read_mcp_snapshot(snapshot_path)
    assert not stale["ok"] and not stale["available"]
    assert stale["status"] == "withheld" and stale["code"] == "BRAIN_CONTROL_MCP_SNAPSHOT_STALE", stale

    # Restore a current timestamp, then emulate a publisher that exposed a
    # non-watermarked snapshot while a durable delivery is still pending.
    rewrite_snapshot(
        lambda body: body.update(
            {
                "generatedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
                "status": {**body["status"], "pendingDeliveryEvents": 1},
                "deliveryWatermark": None,
            }
        )
    )
    pending = read_mcp_snapshot(snapshot_path)
    assert not pending["ok"] and not pending["available"]
    assert pending["status"] == "withheld" and pending["code"] == "BRAIN_CONTROL_MCP_SNAPSHOT_DELIVERY_PENDING", pending


def test_mcp_snapshot_publishes_bounded_scope_bound_task_projection(root: Path) -> None:
    state_root = root / "mcp-task-projection"
    control = BrainControl(state_root)
    request = task_request("mcp-task-projection-import", initial_revision=0)
    request.update(
        {
            "taskId": "private-current-task-id",
            "taskInstanceId": "ti-" + "8" * 32,
            "workspaceKey": "ws-" + "a" * 24,
            "ownerSessionKey": "sid-" + "b" * 24,
        }
    )
    request["state"].update(
        {
            "currentPhase": "autonomous recall repair",
            "currentStep": "publish one bounded current-task projection",
            "nextAction": "verify exact host-scope recall",
            "lastConfirmedSentence": "The hook is optional and core recall remains available.",
            "completedSteps": ["fixed the MCP snapshot root"],
            "pendingSteps": ["verify automatic task recall"],
            "blockers": [],
            "evidence": ["tests/runtime_brain_control_regression.py"],
        }
    )
    control.import_task(request)
    materialized = control.materialize_outbox()
    snapshot_path = Path(materialized["mcpSnapshot"]["path"])
    snapshot = read_mcp_snapshot(snapshot_path)
    assert snapshot["ok"] and snapshot["available"]
    assert len(snapshot["taskProjections"]) == 1
    selected = read_mcp_task_projection(
        snapshot_path,
        workspace_key=str(request["workspaceKey"]),
        owner_session_key=str(request["ownerSessionKey"]),
    )
    assert selected["ok"] and selected["available"] and selected["status"] == "current"
    projection = selected["projection"]
    assert projection["currentPhase"] == "autonomous recall repair"
    assert projection["currentStep"] == "publish one bounded current-task projection"
    assert projection["nextAction"] == "verify exact host-scope recall"
    assert projection["actionAuthorization"] == "withheld"
    assert projection["rawPromptStored"] is False and projection["rawTranscriptStored"] is False
    serialized = json.dumps(snapshot, ensure_ascii=False)
    for private_identity in (
        str(request["taskId"]),
        str(request["taskInstanceId"]),
        str(request["workspaceKey"]),
        str(request["ownerSessionKey"]),
    ):
        assert private_identity not in serialized
    legacy_snapshot = state_root / "shared" / "workspace" / "mcp-snapshot.json"
    assert legacy_snapshot.read_bytes() == snapshot_path.read_bytes()


def test_mcp_snapshot_accepts_allowed_h7_projection_as_display_only(root: Path) -> None:
    """An allowed H7 state is observable, never an MCP execution grant."""

    state_root = root / "mcp-allowed-task-projection"
    control = BrainControl(state_root)
    request = task_request("mcp-allowed-task-projection-import", initial_revision=0)
    request.update(
        {
            "taskId": "private-allowed-task-id",
            "taskInstanceId": "ti-" + "9" * 32,
            "workspaceKey": "ws-" + "e" * 24,
            "ownerSessionKey": "sid-" + "f" * 24,
        }
    )
    control.import_task(request)
    materialized = control.materialize_outbox()
    snapshot_path = Path(materialized["mcpSnapshot"]["path"])
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    snapshot["taskProjections"][0]["actionAuthorization"] = "allowed"
    body = {key: value for key, value in snapshot.items() if key != "payloadHash"}
    snapshot = {
        **body,
        "payloadHash": hashlib.sha256(
            json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
    }
    snapshot_path.write_text(json.dumps(snapshot, ensure_ascii=False), encoding="utf-8")

    selected = read_mcp_task_projection(
        snapshot_path,
        workspace_key=str(request["workspaceKey"]),
        owner_session_key=str(request["ownerSessionKey"]),
    )
    assert selected["ok"] and selected["available"] and selected["status"] == "current", selected
    assert selected["projection"]["actionAuthorization"] == "allowed", selected
    assert selected["projection"]["rawPromptStored"] is False


def test_mcp_task_recall_uses_unique_host_scope_and_fails_closed_when_ambiguous(root: Path) -> None:
    state_root = root / "mcp-task-recall"
    control = BrainControl(state_root)
    thread_id = "019fbc52-79e6-7941-af97-c1c2d40be451"
    owner_session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
    host_project = state_root / "host-project"
    host_project.mkdir(parents=True, exist_ok=True)
    workspace_key = "ws-" + hashlib.sha256(
        str(host_project.resolve()).rstrip("/\\").lower().encode("utf-8")
    ).hexdigest()[:24]

    def import_scoped(command_id: str, task_id: str, instance_digit: str, next_action: str) -> None:
        request = task_request(command_id, initial_revision=0, next_action=next_action)
        request.update(
            {
                "taskId": task_id,
                "taskInstanceId": "ti-" + instance_digit * 32,
                "workspaceKey": workspace_key,
                "ownerSessionKey": owner_session_key,
            }
        )
        request["state"].update(
            {
                "currentPhase": "automatic task recall",
                "currentStep": "match the current Codex thread without user reminders",
                "lastConfirmedSentence": "Visible context stays primary; scoped memory fills only missing evidence.",
            }
        )
        control.import_task(request)

    import_scoped("mcp-task-recall-import", "private-task-one", "6", "return the scoped task projection")
    control.materialize_outbox()

    environment = os.environ.copy()
    environment.update({"SUPER_BRAIN_LOCAL_SESSION_ID": thread_id, "SUPER_BRAIN_WORKSPACE_KEY": workspace_key, "SUPER_BRAIN_MCP_OFFLINE_REPLAY": "1"})

    def call_recall(with_scope: bool = True) -> list[dict[str, object]]:
        arguments: dict[str, object] = {
            "query": "当前任务做到哪里，下一步是什么",
            "layer": "task",
            "top_k": 1,
            "max_tokens": 120,
            "query_date": "2026-08-03",
        }
        if with_scope:
            arguments["task_scope"] = {
                "workspace_key": workspace_key,
                "owner_session_key": owner_session_key,
            }
        requests = "\n".join(
            [
                json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {"name": "brain_recall", "arguments": arguments},
                    }
                ),
            ]
        ) + "\n"
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "brain_mcp.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(state_root / "shared"),
            ],
            input=requests,
            cwd=str(host_project),
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )
        assert completed.returncode == 0, completed.stderr
        replies = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        recall_reply = next(reply for reply in replies if reply.get("id") == 2)
        return json.loads(recall_reply["result"]["content"][0]["text"])

    assert call_recall(with_scope=False) == []
    recalled = call_recall()
    assert len(recalled) == 1
    assert recalled[0]["injectReady"] is True
    assert recalled[0]["sourceType"] == "task_projection"
    assert recalled[0]["taskProjection"]["actionAuthorization"] == "withheld"
    serialized = json.dumps(recalled, ensure_ascii=False)
    for private_identity in (thread_id, owner_session_key, workspace_key, "private-task-one"):
        assert private_identity not in serialized

    import_scoped("mcp-task-recall-ambiguous-import", "private-task-two", "7", "must not be guessed")
    control.materialize_outbox()
    assert call_recall() == []


def test_card_schema_migration_recovery(root: Path) -> None:
    control = BrainControl(root / "card-migration-recovery")
    assert control.status()["schemaVersion"] == 17
    connection = sqlite3.connect(control.db_path)
    try:
        connection.execute("DROP TRIGGER card_revisions_no_update")
        connection.execute("DROP TRIGGER card_revisions_no_delete")
        connection.execute("DROP TRIGGER decision_resolution_receipts_no_update")
        connection.execute("DROP TRIGGER outbox_deliveries_no_update")
        connection.execute("DROP TRIGGER outbox_deliveries_no_delete")
        connection.execute("DROP TRIGGER instruction_anchors_no_update")
        connection.execute("DROP TRIGGER instruction_anchors_no_delete")
        connection.execute("DROP TRIGGER continuation_receipts_no_update")
        connection.execute("DROP TRIGGER continuation_receipts_no_delete")
        connection.execute("DROP TRIGGER migration_events_no_update")
        connection.execute("DROP TRIGGER migration_events_no_delete")
        connection.execute("DROP INDEX idx_decision_resolution_binding_scope")
        connection.execute("DELETE FROM schema_migrations WHERE version=4")
        connection.execute("DELETE FROM schema_migrations WHERE version=5")
        connection.execute("DELETE FROM schema_migrations WHERE version=6")
        connection.execute("DELETE FROM schema_migrations WHERE version=7")
        connection.execute("DELETE FROM schema_migrations WHERE version=12")
        connection.execute("DELETE FROM schema_migrations WHERE version=13")
        connection.execute("DELETE FROM schema_migrations WHERE version=14")
        connection.commit()
    finally:
        connection.close()
    recovered = BrainControl(control.state_root)
    assert recovered.status()["schemaVersion"] == 17
    connection = sqlite3.connect(recovered.db_path)
    try:
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations WHERE version=4").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations WHERE version=5").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations WHERE version=6").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations WHERE version=7").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations WHERE version=12").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations WHERE version=13").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM schema_migrations WHERE version=14").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='card_revisions_no_update'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='decision_resolution_receipts_no_update'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='outbox_deliveries_no_update'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='outbox_deliveries_no_delete'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='instruction_anchors_no_update'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='instruction_anchors_no_delete'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='continuation_receipts_no_update'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='continuation_receipts_no_delete'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='migration_events_no_update'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='migration_events_no_delete'").fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_decision_resolution_binding_scope'").fetchone()[0] == 1
        columns = {row[1] for row in connection.execute("PRAGMA table_info(decision_resolution_receipts)")}
        assert {"workline_id", "intent_fingerprint"}.issubset(columns)
    finally:
        connection.close()


def test_legacy_migration_is_hash_bound_and_adapter_reversible(root: Path) -> None:
    source = root / "legacy-migration-source"
    source.mkdir(parents=True)
    (source / "notes.md").write_text("Keep the verified release notes together.", encoding="utf-8")
    (source / "preference.json").write_text(
        json.dumps(
            {
                "kind": "preference",
                "title": "Review preference",
                "payload": {
                    "schema": "super-brain.card.preference.v1",
                    "statement": "Review structural changes before completion.",
                    "conditions": ["structural change"],
                    "confidence": 90,
                    "tags": ["review"],
                },
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    control = BrainControl(root / "legacy-migration-state")
    plan = control.migration_plan({"sourceRoots": [str(source)]})
    assert plan["plannedCount"] == 2 and plan["quarantinedCount"] == 0
    staged = control.migration_stage(
        {
            "epochId": "migration-clean-001",
            "sourceRoots": [str(source)],
            "expectedPlanFingerprint": plan["planFingerprint"],
        }
    )
    assert staged["status"] == "staged"
    assert Path(staged["archiveRoot"]).is_dir()
    assert (source / "notes.md").is_file(), "staging must not delete or move the source"

    imported = control.migration_import(
        {"epochId": staged["epochId"], "expectedManifestHash": staged["manifestHash"]}
    )
    assert imported["recordCounts"].get("imported") == 2
    verified = control.migration_verify(
        {"epochId": staged["epochId"], "expectedManifestHash": staged["manifestHash"]}
    )
    assert verified["ok"] is True and verified["cutoverEligible"] is True
    cutover = control.migration_cutover(
        {
            "epochId": staged["epochId"],
            "expectedManifestHash": staged["manifestHash"],
            "adapterName": "legacy-memory-layout",
        }
    )
    assert cutover["status"] == "cutover"
    assert cutover["adapters"][0]["status"] == "forwarder"
    rollback = control.migration_rollback_adapter(
        {
            "epochId": staged["epochId"],
            "expectedManifestHash": staged["manifestHash"],
            "adapterName": "legacy-memory-layout",
        }
    )
    assert rollback["status"] == "adapter_rolled_back"
    assert rollback["adapters"][0]["status"] == "read_only"
    assert control.status()["cards"] == 2, "adapter rollback must not erase canonical imported cards"

    changed_source = root / "legacy-migration-changed"
    changed_source.mkdir(parents=True)
    changed_file = changed_source / "state.txt"
    changed_file.write_text("original bytes", encoding="utf-8")
    changed_plan = control.migration_plan({"sourceRoots": [str(changed_source)]})
    changed_stage = control.migration_stage(
        {
            "epochId": "migration-changed-001",
            "sourceRoots": [str(changed_source)],
            "expectedPlanFingerprint": changed_plan["planFingerprint"],
        }
    )
    changed_file.write_text("changed bytes", encoding="utf-8")
    try:
        control.migration_import(
            {"epochId": changed_stage["epochId"], "expectedManifestHash": changed_stage["manifestHash"]}
        )
        raise AssertionError("source mutation must block a staged import")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED"


def _write_sandglass_fixture(root: Path, lines: list[str]) -> tuple[Path, Path]:
    shared = root / "shared"
    shared.mkdir(parents=True, exist_ok=True)
    text_path = shared / "sandglass.txt"
    sqlite_path = shared / "sandglass.db"
    text_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    connection = sqlite3.connect(sqlite_path)
    try:
        connection.execute("CREATE TABLE sandglass (id INTEGER PRIMARY KEY, ts TEXT, sender TEXT, text TEXT)")
        for line_number, line in enumerate(lines, start=1):
            timestamp, sender, text = line.split(" | ", 2)
            connection.execute("INSERT INTO sandglass(id,ts,sender,text) VALUES (?,?,?,?)", (line_number, timestamp, sender, text))
        connection.commit()
    finally:
        connection.close()
    return text_path, sqlite_path


def test_sandglass_history_migration_is_source_bound_private_and_logically_reversible(root: Path) -> None:
    source_root = root / "sandglass-source"
    secret = "sk-test-sandglass-secret-123456789"
    text_path, sqlite_path = _write_sandglass_fixture(
        source_root,
        [
            "2026-07-01 09:00:00 | user | 用户希望交付保持简洁、可维护。",
            "2026-07-01 09:01:00 | user | Super Brain 应保持记忆连续性。",
            "2026-07-01 09:02:00 | user | 修复后要有自动测试和验收。",
            "2026-07-01 09:03:00 | user | UI 和星图应该清晰可读。",
            "2026-07-01 09:04:00 | user | Hook 和 P7 状态需要稳定。",
            f"2026-07-01 09:05:00 | user | 不要保存凭据 {secret}",
            "2026-07-01 09:06:00 | assistant | This is source evidence only.",
            "2026-07-01 09:07:00 | user | 为什么这里需要重启？",
        ],
    )
    target_root = root / "sandglass-target"
    control = BrainControl(target_root)
    request = {
        "sourceTxtPath": str(text_path),
        "sourceSqlitePath": str(sqlite_path),
        "targetScope": {"kind": "global", "key": "user"},
        "targetLifecycle": "proposed",
        "privacyClass": "private",
    }
    before_text_hash = hashlib.sha256(text_path.read_bytes()).hexdigest()
    before_sqlite_hash = hashlib.sha256(sqlite_path.read_bytes()).hexdigest()
    plan = control.sandglass_migration_plan(request)
    assert plan["sourceLineCount"] == 8
    assert plan["validRecordCount"] == 8
    assert plan["candidateCardCount"] == 5
    assert plan["candidateSourceCount"] == 5
    assert plan["quarantinedCount"] == 1
    assert plan["sourceIndexParity"] is True
    assert secret not in json.dumps(plan, ensure_ascii=False)

    staged = control.sandglass_migration_stage(
        {**request, "epochId": "sandglass-fixture-001", "expectedPlanFingerprint": plan["planFingerprint"]}
    )
    assert staged["status"] == "staged"
    epoch_root = target_root / "workspace" / "legacy-migrations" / "sandglass-fixture-001"
    manifest_text = (epoch_root / "manifest.json").read_text(encoding="utf-8")
    assert secret not in manifest_text
    assert not (epoch_root / "archive" / "sources").exists()
    assert json.loads((epoch_root / "archive" / "source-integrity.json").read_text(encoding="utf-8"))["rawTranscriptStored"] is False

    imported = control.sandglass_migration_import(
        {"epochId": "sandglass-fixture-001", "expectedManifestHash": staged["manifestHash"]}
    )
    assert imported["recordCounts"].get("imported") == 5
    assert imported["recordCounts"].get("quarantined") == 1
    verified = control.sandglass_migration_verify(
        {"epochId": "sandglass-fixture-001", "expectedManifestHash": staged["manifestHash"]}
    )
    assert verified["ok"] is True
    assert verified["reviewReady"] is True
    assert verified["nativeSnapshotExcludesProposed"] is True
    assert control._native_memory_influence_snapshot()["entryCount"] == 0
    candidates = control.list_cards_for_ui(lifecycles=["proposed"], limit=20)["items"]
    assert len(candidates) == 5
    for candidate in candidates:
        detail = control.get_card(candidate["cardId"])
        assert detail is not None and detail["lifecycle"] == "proposed" and detail["authority"] == "legacy"
        assert secret not in json.dumps(detail, ensure_ascii=False)

    # A verified legacy migration is visible as read-only candidate groups,
    # not as active/injectable memory.  Its only added star-map relation is
    # the historical source membership; do not invent semantic card links.
    starmap = control.list_memory_starmap_for_ui()
    candidate_nodes = [node for node in starmap["nodes"] if node.get("isCandidate")]
    history_sources = [node for node in starmap["nodes"] if node.get("isHistorySource")]
    assert len(candidate_nodes) == 5
    assert all(node["kindLabel"] == "历史候选" and node["stateLabel"] == "待审核" for node in candidate_nodes)
    assert all(node["candidateSource"] == "旧 Sandglass 历史" for node in candidate_nodes)
    assert sum(int(node["candidateSourceCount"]) for node in candidate_nodes) == 5
    assert len(history_sources) == 1
    assert history_sources[0]["title"] == "旧 Sandglass 历史（8 条）"
    assert starmap["counts"]["candidateMemory"] == 5
    assert starmap["counts"]["historySourceRecords"] == 8
    history_source_edges = [edge for edge in starmap["edges"] if edge["relation"] == "history_source"]
    assert len(history_source_edges) == 5
    assert not any(edge["relation"] == "migration_source" for edge in starmap["edges"])
    assert control._native_memory_influence_snapshot()["entryCount"] == 0

    imported_again = control.sandglass_migration_import(
        {"epochId": "sandglass-fixture-001", "expectedManifestHash": staged["manifestHash"]}
    )
    assert imported_again["recordCounts"].get("imported") == 5
    rollback = control.sandglass_migration_rollback(
        {"epochId": "sandglass-fixture-001", "expectedManifestHash": staged["manifestHash"], "userConfirmed": True}
    )
    assert rollback["status"] == "rolled_back"
    assert rollback["recordCounts"].get("rolled_back") == 5
    assert len(control.list_cards_for_ui(lifecycles=["trashed"], limit=20)["items"]) == 5
    assert hashlib.sha256(text_path.read_bytes()).hexdigest() == before_text_hash
    assert hashlib.sha256(sqlite_path.read_bytes()).hexdigest() == before_sqlite_hash

    try:
        BrainControl(source_root).migration_plan({"sourceRoots": [str(source_root / "shared")]})
        raise AssertionError("generic migration must retain its active-state overlap guard")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_MIGRATION_SOURCE_OVERLAP"

    stale_target = root / "sandglass-stale-target"
    stale = BrainControl(stale_target)
    stale_plan = stale.sandglass_migration_plan(request)
    stale_stage = stale.sandglass_migration_stage(
        {**request, "epochId": "sandglass-fixture-002", "expectedPlanFingerprint": stale_plan["planFingerprint"]}
    )
    text_path.write_text(text_path.read_text(encoding="utf-8") + "2026-07-01 09:08:00 | user | 这是追加的历史记录。\n", encoding="utf-8")
    try:
        stale.sandglass_migration_import(
            {"epochId": "sandglass-fixture-002", "expectedManifestHash": stale_stage["manifestHash"]}
        )
        raise AssertionError("source mutation after stage must block Sandglass import")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_MIGRATION_SOURCE_CHANGED"


def test_task_authority(root: Path) -> None:
    control = BrainControl(root / "task-state")
    seed = task_request("task-import-1", initial_revision=7)
    prepared_empty = control.prepare_task(seed)
    assert prepared_empty["expectedRevision"] == 0 and prepared_empty["state"] is None
    imported = control.import_task(seed)
    assert imported["revision"] == 7 and not imported["idempotent"]
    assert imported["outboxEventId"] == imported["eventId"]
    assert control.import_task(seed)["idempotent"]

    prepared = control.prepare_task(seed)
    assert prepared["expectedRevision"] == 7
    assert prepared["state"]["taskStateRevision"] == 7
    applied = control.apply_task(task_request("task-apply-1", expected_revision=7, next_action="verify materialized task projection"))
    assert applied["revision"] == 8 and applied["previousRevision"] == 7
    assert control.apply_task(task_request("task-apply-1", expected_revision=7, next_action="verify materialized task projection"))["idempotent"]

    current = control.get_task(task_request("task-read", initial_revision=0))
    assert current["current"] and current["revision"] == 8
    assert current["state"]["nextAction"] == "verify materialized task projection"
    assert current["state"]["canonicalPlan"]["items"][1]["label"] == "materialize projection"
    located = control.locate_task({"taskId": "task-sqlite-authority", "workspaceKey": "ws-sqlite-authority"})
    assert located["found"] and located["revision"] == 8
    assert located["taskInstanceId"] == "ti-" + "3" * 32
    assert control.locate_task({"taskId": "task-sqlite-authority"})["found"]

    outbox = control.pending_task_outbox()
    assert len(outbox) == 1
    assert outbox[0]["payload"]["stateHash"] == applied["stateHash"]
    assert outbox[0]["payload"]["state"]["taskStateRevision"] == 8
    try:
        control.publish_mcp_snapshot()
        raise AssertionError("manual MCP publishing must not bypass the task compatibility receipt")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_MCP_SNAPSHOT_OUTBOX_PENDING"

    blocked = control.materialize_outbox()
    assert blocked["blockedMcpDeliveryEvents"] == 1
    assert blocked["mcpSnapshot"] is None
    assert not blocked["snapshotDeliveries"]
    assert len(control.pending_task_outbox()) == 1

    malformed_path, malformed_hash = write_task_compatibility_projection(
        control,
        outbox[0],
        task_id="foreign-task",
    )
    payload = outbox[0]["payload"]
    assert isinstance(payload, dict)
    try:
        control.record_task_compatibility_delivery(
            {
                "eventId": outbox[0]["eventId"],
                "taskId": payload["taskId"],
                "workspaceKey": payload["workspaceKey"],
                "revision": payload["revision"],
                "projectionPath": str(malformed_path),
                "projectionHash": malformed_hash,
                "source": "runtime_brain_control_regression",
            }
        )
        raise AssertionError("foreign task projection must not create a delivery receipt")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_TASK_DELIVERY_ARTIFACT_SCOPE_MISMATCH"

    first_delivery = record_task_compatibility_delivery(control, outbox[0])
    assert not first_delivery["idempotent"] and not first_delivery["complete"]
    second_delivery = record_task_compatibility_delivery(control, outbox[0])
    assert second_delivery["idempotent"] and not second_delivery["complete"]
    materialized = control.materialize_outbox()
    assert materialized["blockedMcpDeliveryEvents"] == 0
    assert materialized["materializedEventCount"] == 2
    assert not control.pending_task_outbox()
    snapshots = control.task_projection_snapshots()
    assert len(snapshots) == 1 and snapshots[0]["status"] == "materialized"
    assert control.materialize_outbox()["materializedEventCount"] == 0

    try:
        control.apply_task(task_request("task-apply-stale", expected_revision=7))
        raise AssertionError("stale task CAS must fail")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_TASK_STALE_REVISION"
    foreign = task_request("task-read-foreign", initial_revision=0)
    foreign["ownerSessionKey"] = "sid-" + "9" * 24
    assert control.get_task(foreign)["code"] == "BRAIN_CONTROL_TASK_SCOPE_STALE"

    connection = sqlite3.connect(control.db_path)
    try:
        try:
            connection.execute("UPDATE task_state_revisions SET state_hash='x' WHERE task_revision=8")
            raise AssertionError("task state revisions must be immutable")
        except sqlite3.IntegrityError:
            pass
        assert connection.execute("SELECT COUNT(*) FROM task_state_revisions").fetchone()[0] == 2
    finally:
        connection.close()

    second_scope = task_request("task-import-second-scope", initial_revision=0)
    second_scope["workspaceKey"] = "ws-sqlite-authority-second"
    second_scope["taskInstanceId"] = "ti-" + "8" * 32
    control.import_task(second_scope)
    ambiguous = control.locate_task({"taskId": "task-sqlite-authority"})
    assert ambiguous["ambiguous"] and ambiguous["code"] == "BRAIN_CONTROL_TASK_SCOPE_AMBIGUOUS"


def test_task_session_rebind_receipt_authorizes_owner_transfer(root: Path) -> None:
    control = BrainControl(root / "task-session-rebind")
    seed = task_request("task-session-rebind-import", initial_revision=7)
    imported = control.import_task(seed)
    assert imported["revision"] == 7

    new_owner = "sid-" + "8" * 24
    receipt_request = {
        "commandId": "task-session-rebind-authorize-1",
        "taskId": seed["taskId"],
        "taskInstanceId": seed["taskInstanceId"],
        "workspaceKey": seed["workspaceKey"],
        "previousOwnerSessionKey": seed["ownerSessionKey"],
        "newOwnerSessionKey": new_owner,
        "packageVersion": seed["packageVersion"],
        "expectedTaskRevision": 7,
        "expectedContractRevision": 11,
        "expectedPlanFingerprint": "plan-task-authority-11",
        "source": "runtime_brain_control_regression",
    }
    receipt = control.issue_task_session_rebind(receipt_request)
    assert receipt["ok"] and receipt["schema"] == "super-brain.task-session-rebind-receipt.v1"
    assert receipt["previousOwnerSessionKey"] == seed["ownerSessionKey"]
    assert receipt["newOwnerSessionKey"] == new_owner
    assert receipt["taskRevision"] == 7
    assert control.issue_task_session_rebind(receipt_request)["idempotent"] is True

    continued = task_request("task-session-rebind-apply", expected_revision=7, next_action="continue under verified new owner")
    continued["ownerSessionKey"] = new_owner
    continued["taskSessionRebind"] = receipt
    applied = control.apply_task(continued)
    assert applied["revision"] == 8 and applied["taskSessionRebind"] is True
    current = control.get_task({**continued, "commandId": "task-session-rebind-read"})
    assert current["current"] and current["state"]["nextAction"] == "continue under verified new owner"

    connection = sqlite3.connect(control.db_path)
    try:
        row = connection.execute(
            "SELECT previous_owner_session_key,new_owner_session_key,task_revision,task_state_hash FROM task_session_rebinds WHERE rebind_id=?",
            (receipt["rebindId"],),
        ).fetchone()
        assert row == (seed["ownerSessionKey"], new_owner, 7, receipt["taskStateHash"])
        try:
            connection.execute(
                "UPDATE task_session_rebinds SET new_owner_session_key=? WHERE rebind_id=?",
                ("sid-tampered", receipt["rebindId"]),
            )
            raise AssertionError("task session rebind receipts must be immutable")
        except sqlite3.IntegrityError:
            pass
    finally:
        connection.close()

    stale = task_request("task-session-rebind-stale", expected_revision=8)
    stale["ownerSessionKey"] = "sid-" + "9" * 24
    stale["taskSessionRebind"] = receipt
    try:
        control.apply_task(stale)
        raise AssertionError("a consumed task session rebind receipt must not authorize another owner transfer")
    except BrainControlError as exc:
        assert exc.code in {"BRAIN_CONTROL_TASK_SESSION_REBIND_SCOPE_MISMATCH", "BRAIN_CONTROL_TASK_SESSION_REBIND_STALE"}


def test_control_center_overview_isolates_current_execution_scope(root: Path) -> None:
    control = BrainControl(root / "control-center-task-isolation")

    def scoped_task(
        command_id: str,
        *,
        task_id: str,
        task_instance_id: str,
        workspace_key: str,
        owner_session_key: str,
        phase: str,
        step: str,
        next_action: str,
    ) -> dict[str, object]:
        request = task_request(command_id, initial_revision=0, next_action=next_action)
        request.update(
            {
                "taskId": task_id,
                "taskInstanceId": task_instance_id,
                "workspaceKey": workspace_key,
                "ownerSessionKey": owner_session_key,
            }
        )
        state = request["state"]
        assert isinstance(state, dict)
        state["currentPhase"] = phase
        state["currentStep"] = step
        state["focusLabel"] = "当前控制中心任务" if task_id == "task-control-center-current" else task_id
        state["taskSummary"] = (
            "只展示当前任务，并让用户看见完整的完成清单。"
            if task_id == "task-control-center-current"
            else f"{task_id} 的任务内容不得跨作用域显示。"
        )
        return request

    current = scoped_task(
        "overview-current-import",
        task_id="task-control-center-current",
        task_instance_id="ti-" + "1" * 32,
        workspace_key="ws-control-center-current",
        owner_session_key="sid-" + "2" * 24,
        phase="P4 current phase",
        step="Show only the active current task.",
        next_action="Verify current-scope isolation.",
    )
    foreign_workspace = scoped_task(
        "overview-foreign-workspace-import",
        task_id="task-control-center-foreign-workspace",
        task_instance_id="ti-" + "3" * 32,
        workspace_key="ws-control-center-foreign",
        owner_session_key="sid-" + "4" * 24,
        phase="Foreign workspace phase",
        step="Foreign workspace task content must not be exposed.",
        next_action="Do not reveal this foreign workspace action.",
    )
    foreign_session = scoped_task(
        "overview-foreign-session-import",
        task_id="task-control-center-foreign-session",
        task_instance_id="ti-" + "5" * 32,
        workspace_key="ws-control-center-current",
        owner_session_key="sid-" + "6" * 24,
        phase="Foreign session phase",
        step="Foreign session task content must not be exposed.",
        next_action="Do not reveal this foreign session action.",
    )
    control.import_task(current)
    control.import_task(foreign_workspace)
    control.import_task(foreign_session)

    withheld = control.control_center_overview()
    assert withheld["taskScope"]["status"] == "withheld"
    assert withheld["tasks"] == []

    compatibility_contract = {
        "schema": "super-brain.execution-contract.v1",
        "taskId": "task-control-center-foreign-compatibility",
        "taskInstanceId": "ti-" + "7" * 32,
        "workspaceKey": "ws-control-center-foreign-compatibility",
        "ownerSessionKey": "sid-" + "8" * 24,
        "status": "active",
        "revision": 9,
        "currentPhase": "Foreign compatibility phase",
        "currentStep": "Foreign compatibility task content must not be exposed.",
        "nextAction": "Do not reveal this foreign compatibility action.",
        "updatedAt": "2026-07-28T10:00:00Z",
    }
    compatibility_path = control.workspace / "runtime-state" / "execution-contracts" / "foreign-compatibility.json"
    compatibility_path.parent.mkdir(parents=True, exist_ok=True)
    compatibility_path.write_text(json.dumps(compatibility_contract), encoding="utf-8")

    current_state = current["state"]
    assert isinstance(current_state, dict)
    current_contract = {
        "schema": "super-brain.execution-contract.v1",
        "taskId": current["taskId"],
        "taskInstanceId": current["taskInstanceId"],
        "workspaceKey": current["workspaceKey"],
        "ownerSessionKey": current["ownerSessionKey"],
        "status": "active",
        "revision": 4,
        "currentPhase": current_state["currentPhase"],
        "currentStep": current_state["currentStep"],
        "nextAction": current_state["nextAction"],
        "updatedAt": "2026-07-28T10:01:00Z",
    }
    (control.workspace / "last-execution-contract.json").write_text(
        json.dumps(current_contract), encoding="utf-8"
    )

    overview = control.control_center_overview()
    assert overview["taskScope"]["status"] == "bound"
    assert [task["taskId"] for task in overview["tasks"]] == [current["taskId"]]
    assert overview["tasks"][0]["currentPhase"] == "P4 current phase"
    display = overview["tasks"][0]["display"]
    assert display["title"] == "当前控制中心任务"
    assert display["summary"] == "只展示当前任务，并让用户看见完整的完成清单。"
    assert display["statusLabel"] == "进行中"
    assert display["completedCount"] == 1 and display["pendingCount"] == 1
    assert display["phase"].startswith("P4：构建可编辑的本地记忆与控制中心")
    serialized = json.dumps(overview, ensure_ascii=False)
    for private_foreign_value in (
        "task-control-center-foreign-workspace",
        "Foreign workspace task content must not be exposed.",
        "task-control-center-foreign-workspace 的任务内容不得跨作用域显示。",
        "task-control-center-foreign-session",
        "Foreign session task content must not be exposed.",
        "task-control-center-foreign-session 的任务内容不得跨作用域显示。",
        "task-control-center-foreign-compatibility",
        "Foreign compatibility task content must not be exposed.",
    ):
        assert private_foreign_value not in serialized


def test_task_concurrent_cas(root: Path) -> None:
    state_root = root / "task-concurrent-state"
    control = BrainControl(state_root)
    imported = control.import_task(task_request("task-concurrent-import", initial_revision=0))
    barrier = threading.Barrier(2)
    requests = [
        task_request("task-concurrent-a", expected_revision=0, next_action="winner a"),
        task_request("task-concurrent-b", expected_revision=0, next_action="winner b"),
    ]

    def attempt(request: dict[str, object]) -> dict[str, object]:
        actor = BrainControl(state_root)
        barrier.wait(timeout=5)
        try:
            result = actor.apply_task(request)
            return {"status": "applied", "commandId": request["commandId"], "result": result}
        except BrainControlError as exc:
            return {"status": "rejected", "commandId": request["commandId"], "code": exc.code}

    with ThreadPoolExecutor(max_workers=2) as executor:
        outcomes = list(executor.map(attempt, requests))

    applied = [item for item in outcomes if item["status"] == "applied"]
    rejected = [item for item in outcomes if item["status"] == "rejected"]
    assert len(applied) == 1 and applied[0]["result"]["revision"] == 1
    assert len(rejected) == 1 and rejected[0]["code"] == "BRAIN_CONTROL_TASK_STALE_REVISION"

    current = control.get_task(task_request("task-concurrent-read", initial_revision=0))
    assert current["revision"] == 1 and current["state"]["nextAction"] in {"winner a", "winner b"}
    winner_request = next(request for request in requests if request["commandId"] == applied[0]["commandId"])
    assert control.apply_task(winner_request)["idempotent"]

    connection = sqlite3.connect(control.db_path)
    try:
        aggregate_id = imported["aggregateId"]
        assert connection.execute("SELECT COUNT(*) FROM task_state_revisions WHERE aggregate_id=?", (aggregate_id,)).fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM command_log WHERE aggregate_id=?", (aggregate_id,)).fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM outbox WHERE aggregate_id=?", (aggregate_id,)).fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM command_log WHERE command_id=?", (rejected[0]["commandId"],)).fetchone()[0] == 0
    finally:
        connection.close()


def test_task_concurrent_idempotent_replay(root: Path) -> None:
    state_root = root / "task-concurrent-idempotent-state"
    control = BrainControl(state_root)
    imported = control.import_task(task_request("task-concurrent-idempotent-import", initial_revision=0))
    request = task_request("task-concurrent-idempotent-apply", expected_revision=0, next_action="one durable result")
    barrier = threading.Barrier(2)

    def replay() -> dict[str, object]:
        actor = BrainControl(state_root)
        barrier.wait(timeout=5)
        return actor.apply_task(dict(request))

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda _: replay(), range(2)))

    assert sorted(result["idempotent"] for result in results) == [False, True]
    for field in ("revision", "previousRevision", "stateHash", "eventId", "outboxEventId"):
        assert results[0][field] == results[1][field]
    assert control.get_task(task_request("task-concurrent-idempotent-read", initial_revision=0))["revision"] == 1

    connection = sqlite3.connect(control.db_path)
    try:
        aggregate_id = imported["aggregateId"]
        command_id = request["commandId"]
        assert connection.execute("SELECT COUNT(*) FROM task_state_revisions WHERE aggregate_id=?", (aggregate_id,)).fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM command_log WHERE command_id=?", (command_id,)).fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM events WHERE command_id=?", (command_id,)).fetchone()[0] == 1
        assert connection.execute("SELECT COUNT(*) FROM outbox WHERE aggregate_id=?", (aggregate_id,)).fetchone()[0] == 2
    finally:
        connection.close()


def test_task_shape_normalization(root: Path) -> None:
    control = BrainControl(root / "task-shape-state")
    scope = {
        "taskId": "task-shape-normalization",
        "taskInstanceId": "ti-" + "5" * 32,
        "workspaceKey": "ws-task-shape-normalization",
        "ownerSessionKey": "sid-" + "6" * 24,
        "packageVersion": PACKAGE_VERSION,
        "source": "runtime_brain_control_regression",
    }
    seed = {
        **scope,
        "commandId": "task-shape-import",
        "initialRevision": 0,
        "state": {"lifecycle": "active", "completedSteps": {}, "pendingSteps": None},
    }
    control.import_task(seed)
    payload_text = '{"status":"active","taskId":"task-shape-normalization","workspaceKey":"ws-task-shape-normalization"}'
    payload_hash = hashlib.sha256(payload_text.encode("utf-8")).hexdigest()
    projection = {
        "schema": "super-brain.task-projection.v1",
        "taskId": scope["taskId"],
        "workspaceKey": scope["workspaceKey"],
        "transactionKind": "contract_continuity",
        "taskStateRevision": 1,
        "entities": {"context": None, "checkpoint": None, "task_card": None},
        "lifecycle": {"status": "active", "workspaceKey": scope["workspaceKey"]},
        "commands": {
            "role": "current_context",
            "operation": "replace_if_hash",
            "targetPath": "C:\\task-shape-normalization.json",
            "payloadHash": payload_hash,
            "payloadText": payload_text,
        },
    }
    applied = control.apply_task(
        {
            **scope,
            "commandId": "task-shape-apply",
            "expectedRevision": 0,
            "state": {
                "lifecycle": "active",
                "completedSteps": {},
                "pendingSteps": "materialize projection",
                "blockers": None,
                "evidence": {"kind": "regression"},
                "canonicalPlan": {
                    "planId": "plan-task-shape",
                    "items": {"itemId": "A", "ordinal": 1, "label": "normalize arrays", "status": "pending"},
                },
                "compatibilityProjection": projection,
            },
        }
    )
    assert applied["revision"] == 1
    current = control.get_task({**scope})
    state = current["state"]
    assert state["completedSteps"] == []
    assert state["pendingSteps"] == ["materialize projection"]
    assert state["blockers"] == []
    assert state["evidence"] == [{"kind": "regression"}]
    assert state["canonicalPlan"]["items"][0]["itemId"] == "A"
    assert "compatibilityProjection" not in state
    outbox = control.pending_task_outbox()
    assert len(outbox) == 1
    assert isinstance(outbox[0]["payload"]["projection"]["commands"], list)
    assert outbox[0]["payload"]["projection"]["commands"][0]["payloadHash"] == payload_hash
    assert outbox[0]["payload"]["projection"]["commands"][0]["payloadText"] == payload_text


def intent_request(
    command_id: str,
    expected_revision: int,
    *,
    task_id: str = "task-intent-native",
    task_instance_id: str = "ti-" + "1" * 32,
    session_key: str = "sid-" + "2" * 24,
    instruction: str = "add editable notebook without direct database writes",
    contract_revision: int = 7,
    plan_fingerprint: str = "plan-fingerprint-7",
    contract: dict[str, object] | None = None,
) -> dict[str, object]:
    return {
        "commandId": command_id,
        "expectedIntentRevision": expected_revision,
        "taskId": task_id,
        "taskInstanceId": task_instance_id,
        "workspaceKey": "ws-intent-native",
        "ownerSessionKey": session_key,
        "packageVersion": PACKAGE_VERSION,
        "contractRevision": contract_revision,
        "planFingerprint": plan_fingerprint,
        "latestInstructionHash": instruction_hash(instruction),
        "intentContract": contract or intent_contract(),
        "source": "runtime_brain_control_regression",
    }


def intent_check_request(resolved: dict[str, object], request: dict[str, object]) -> dict[str, object]:
    receipt = resolved["intentResolutionReceipt"]
    assert isinstance(receipt, dict)
    return {
        "taskId": request["taskId"],
        "taskInstanceId": request["taskInstanceId"],
        "workspaceKey": request["workspaceKey"],
        "ownerSessionKey": request["ownerSessionKey"],
        "packageVersion": request["packageVersion"],
        "contractRevision": request["contractRevision"],
        "intentRevision": resolved["intentRevision"],
        "planFingerprint": request["planFingerprint"],
        "latestInstructionHash": request["latestInstructionHash"],
        "intentContractFingerprint": receipt["intentContractFingerprint"],
        "receiptId": receipt["receiptId"],
        "payloadHash": receipt["payloadHash"],
    }


def test_intent_authority(root: Path) -> None:
    control = BrainControl(root / "intent-state")
    request = intent_request("intent-cmd-1", 0)
    resolved = control.resolve_intent(request)
    assert resolved["ok"] and resolved["intentRevision"] == 1 and resolved["contractChanged"]
    assert len(resolved["intentResolutionReceipt"]["latestInstructionHash"]) == 64
    assert len(resolved["intentResolutionReceipt"]["intentContractFingerprint"]) == 64
    current_request = intent_check_request(resolved, request)
    projection_path = intent_context_projection_path(
        control.state_root,
        task_id=str(request["taskId"]),
        task_instance_id=str(request["taskInstanceId"]),
        workspace_key=str(request["workspaceKey"]),
    )
    projection_text = projection_path.read_text(encoding="utf-8")
    projection = json.loads(projection_text)
    assert set(projection) == {
        "schema", "generatedAt", "aggregateRef", "bindingHash", "ready",
        "intentContractBodyStored", "rawPromptStored", "rawTranscriptStored", "payloadHash",
    }
    assert str(request["taskId"]) not in projection_text
    assert "literalRequestDigest" not in projection_text
    assert projection["intentContractBodyStored"] is False
    before_read = sqlite_artifact_hashes(control.db_path)
    projected_current = read_intent_context_projection(control.state_root, current_request)
    after_read = sqlite_artifact_hashes(control.db_path)
    assert projected_current["ok"] and projected_current["current"] and projected_current["ready"]
    assert before_read == after_read
    current = control.check_intent(current_request)
    assert current["ok"] and current["current"]

    live_wal = sqlite3.connect(control.db_path, isolation_level=None)
    try:
        live_wal.execute("PRAGMA journal_mode=WAL")
        live_wal.execute("CREATE TABLE read_only_intent_probe (value INTEGER)")
        before_wal_read = sqlite_artifact_hashes(control.db_path)
        strict_read = control.check_intent_read_only(current_request)
        after_wal_read = sqlite_artifact_hashes(control.db_path)
        assert strict_read["code"] == "BRAIN_CONTROL_INTENT_READ_ONLY_MUTABLE_JOURNAL_PRESENT"
        assert before_wal_read == after_wal_read
    finally:
        live_wal.close()

    control._begin_intent_context_projection_pending(
        task_id=str(request["taskId"]),
        task_instance_id=str(request["taskInstanceId"]),
        workspace_key=str(request["workspaceKey"]),
        mutation_id="intent-projection-repair-fixture",
    )
    assert read_intent_context_projection(control.state_root, current_request)["code"] == "BRAIN_CONTEXT_INTENT_PROJECTION_PENDING"

    replay = control.resolve_intent(request)
    assert replay["idempotent"] and replay["intentResolutionReceipt"]["receiptId"] == resolved["intentResolutionReceipt"]["receiptId"]
    assert read_intent_context_projection(control.state_root, current_request)["current"]
    try:
        reused = dict(request)
        reused["planFingerprint"] = "different-plan"
        control.resolve_intent(reused)
        raise AssertionError("intent command id reuse with another payload must fail")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_COMMAND_ID_REUSED"

    stale_instruction = dict(current_request)
    stale_instruction["latestInstructionHash"] = instruction_hash("also export the notebook")
    assert control.check_intent(stale_instruction)["code"] == "BRAIN_CONTROL_INTENT_RECEIPT_STALE"
    foreign_session = dict(current_request)
    foreign_session["ownerSessionKey"] = "sid-" + "9" * 24
    assert control.check_intent(foreign_session)["code"] == "BRAIN_CONTROL_INTENT_RECEIPT_STALE"
    foreign_task = dict(current_request)
    foreign_task["taskId"] = "task-foreign"
    assert control.check_intent(foreign_task)["code"] == "BRAIN_CONTROL_INTENT_NOT_FOUND"

    try:
        control.resolve_intent(intent_request("intent-cmd-stale", 0))
        raise AssertionError("stale intent CAS must fail")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_INTENT_STALE_REVISION"

    rebound_request = intent_request(
        "intent-cmd-2",
        1,
        instruction="bind the same outcome to the revised implementation plan",
        contract_revision=8,
        plan_fingerprint="plan-fingerprint-8",
    )
    rebound = control.resolve_intent(rebound_request)
    assert rebound["intentRevision"] == 1 and not rebound["contractChanged"]
    assert control.check_intent(current_request)["code"] == "BRAIN_CONTROL_INTENT_RECEIPT_STALE"
    assert control.check_intent(intent_check_request(rebound, rebound_request))["current"]

    unknown_request = intent_request(
        "intent-cmd-3",
        1,
        instruction="choose retention ownership before implementation",
        contract_revision=9,
        plan_fingerprint="plan-fingerprint-9",
        contract=intent_contract(["choose retention owner"]),
    )
    unknown = control.resolve_intent(unknown_request)
    assert unknown["intentRevision"] == 2 and unknown["code"] == "BRAIN_CONTROL_INTENT_MATERIAL_UNKNOWN"
    unknown_check = control.check_intent(intent_check_request(unknown, unknown_request))
    assert not unknown_check["ok"] and unknown_check["code"] == "BRAIN_CONTROL_INTENT_MATERIAL_UNKNOWN"

    connection = sqlite3.connect(control.db_path)
    try:
        try:
            connection.execute("UPDATE intent_receipts SET ready=1 WHERE receipt_id=?", (unknown["intentResolutionReceipt"]["receiptId"],))
            raise AssertionError("intent receipt update must be blocked by the immutable trigger")
        except sqlite3.IntegrityError:
            pass
        assert connection.execute("SELECT COUNT(*) FROM intent_contract_revisions").fetchone()[0] == 2
        assert connection.execute("SELECT COUNT(*) FROM intent_receipts").fetchone()[0] == 3
    finally:
        connection.close()


def test_intent_session_rebind_preserves_original_task_intent(root: Path) -> None:
    control = BrainControl(root / "intent-session-rebind")
    original = intent_request("intent-rebind-original", 0)
    resolved = control.resolve_intent(original)
    old_receipt = resolved["intentResolutionReceipt"]
    assert isinstance(old_receipt, dict)

    new_owner = "sid-" + "b" * 24
    rebind_request = {
        "commandId": "intent-rebind-transfer-1",
        "taskId": original["taskId"],
        "taskInstanceId": original["taskInstanceId"],
        "workspaceKey": original["workspaceKey"],
        "previousOwnerSessionKey": original["ownerSessionKey"],
        "newOwnerSessionKey": new_owner,
        "expectedIntentRevision": resolved["intentRevision"],
        "latestReceiptId": old_receipt["receiptId"],
        "latestReceiptPayloadHash": old_receipt["payloadHash"],
        "source": "runtime_brain_control_regression",
    }
    transferred = control.rebind_intent_session(rebind_request)
    assert transferred["ok"] and not transferred["idempotent"]
    assert transferred["previousOwnerSessionKey"] == original["ownerSessionKey"]
    assert transferred["newOwnerSessionKey"] == new_owner
    assert transferred["latestReceiptId"] == old_receipt["receiptId"]
    assert control.rebind_intent_session(rebind_request)["idempotent"] is True
    pending_root = intent_context_pending_root(
        control.state_root,
        task_id=str(original["taskId"]),
        task_instance_id=str(original["taskInstanceId"]),
        workspace_key=str(original["workspaceKey"]),
    )
    assert any(pending_root.glob("*.json"))
    assert read_intent_context_projection(
        control.state_root,
        intent_check_request(resolved, original),
    )["code"] == "BRAIN_CONTEXT_INTENT_PROJECTION_PENDING"

    continued = intent_request(
        "intent-rebind-continued",
        resolved["intentRevision"],
        instruction="continue the same verified task after reconnect",
        contract_revision=8,
        plan_fingerprint="plan-rebind-continuation-8",
    )
    continued["ownerSessionKey"] = new_owner
    resumed = control.resolve_intent(continued)
    assert resumed["ok"] and resumed["intentRevision"] == resolved["intentRevision"]
    assert resumed["intentResolutionReceipt"]["ownerSessionKey"] == new_owner
    assert resumed["intentResolutionReceipt"]["receiptId"] != old_receipt["receiptId"]
    assert control.check_intent(intent_check_request(resumed, continued))["current"] is True
    assert not any(pending_root.glob("*.json"))
    assert read_intent_context_projection(
        control.state_root,
        intent_check_request(resumed, continued),
    )["current"] is True

    connection = sqlite3.connect(control.db_path)
    try:
        aggregate = connection.execute(
            "SELECT owner_session_key FROM intent_aggregates WHERE aggregate_id=?", (transferred["aggregateId"],)
        ).fetchone()
        old_receipt_owner = connection.execute(
            "SELECT owner_session_key FROM intent_receipts WHERE receipt_id=?", (old_receipt["receiptId"],)
        ).fetchone()
        rebind_row = connection.execute(
            "SELECT previous_owner_session_key,new_owner_session_key,latest_receipt_id FROM intent_session_rebinds WHERE rebind_id=?",
            (transferred["rebindId"],),
        ).fetchone()
        assert aggregate == (new_owner,)
        assert old_receipt_owner == (original["ownerSessionKey"],)
        assert rebind_row == (original["ownerSessionKey"], new_owner, old_receipt["receiptId"])
        try:
            connection.execute(
                "UPDATE intent_session_rebinds SET new_owner_session_key=? WHERE rebind_id=?",
                ("sid-tampered", transferred["rebindId"]),
            )
            raise AssertionError("intent session rebinds must be immutable")
        except sqlite3.IntegrityError:
            pass
    finally:
        connection.close()

    stale_rebind = dict(rebind_request)
    stale_rebind["commandId"] = "intent-rebind-transfer-stale"
    try:
        control.rebind_intent_session(stale_rebind)
        raise AssertionError("a stale previous owner must not reclaim the intent aggregate")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_INTENT_REBIND_OWNER_MISMATCH"


def decision_graph_record(subject: str, relation: str, object_value: str) -> dict[str, str]:
    return {
        "time": "2026-07-26T00:00:00Z",
        "subject": subject,
        "relation": relation,
        "object": object_value,
        "evidence": "tests/runtime_brain_control_regression.py",
        "tags": "[DECISION][ADR][CURRENT][VERIFIED]",
    }


def write_decision_graph(path: Path) -> None:
    records: list[dict[str, str]] = []
    for subject, decision, title in (
        ("decision:legacy-release", "Ship the legacy release format.", "Legacy release format"),
        ("decision:current-release", "Ship the current release format.", "Current release format"),
    ):
        records.extend(
            [
                decision_graph_record(subject, "decides", decision),
                decision_graph_record(subject, "has_title", title),
                decision_graph_record(subject, "has_status", "accepted"),
                decision_graph_record(subject, "has_context", "The package needs a release contract."),
                decision_graph_record(subject, "has_consequence", "Completion checks use the release contract."),
            ]
        )
    records.append(
        decision_graph_record("decision:current-release", "supersedes", "decision:legacy-release")
    )
    path.write_text(
        "\n".join(json.dumps(record, ensure_ascii=False, sort_keys=True) for record in records) + "\n",
        encoding="utf-8",
    )


def test_decision_graph_shadow(root: Path) -> None:
    graph_path = root / "decision-graph.jsonl"
    write_decision_graph(graph_path)
    shadow_root = root / "shadow-state"
    control = BrainControl(shadow_root)

    preview = control.preview_decision_graph_shadow(graph_path)
    assert preview["sourceSubjectCount"] == 2
    assert preview["currentSubjectCount"] == 1
    assert preview["executionEligibleCount"] == 1
    assert not shadow_root.exists()

    cli_preview = subprocess.run(
        [
            sys.executable,
            str(ROOT / "runtime" / "brain_control.py"),
            "--state-root",
            str(root / "cli-state"),
            "shadow-preview-decision-graph",
            "--source-graph",
            str(graph_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert cli_preview.returncode == 0
    assert json.loads(cli_preview.stdout)["sourceSubjectCount"] == 2

    cli_without_apply = subprocess.run(
        [
            sys.executable,
            str(ROOT / "runtime" / "brain_control.py"),
            "--state-root",
            str(root / "cli-state"),
            "shadow-sync-decision-graph",
            "--source-graph",
            str(graph_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert cli_without_apply.returncode == 1
    assert json.loads(cli_without_apply.stdout)["code"] == "BRAIN_CONTROL_SHADOW_APPLY_REQUIRED"

    initial_audit = control.audit_decision_graph_shadow(graph_path)
    assert not initial_audit["ok"] and len(initial_audit["missingSubjectHashes"]) == 2
    synced = control.sync_decision_graph_shadow(graph_path)
    assert synced["ok"] and synced["atomic"]
    assert synced["writtenCount"] == 2 and synced["unchangedCount"] == 0
    assert synced["audit"]["matchedCount"] == 2

    repeated = control.sync_decision_graph_shadow(graph_path)
    assert repeated["ok"]
    assert repeated["writtenCount"] == 0 and repeated["unchangedCount"] == 2

    connection = sqlite3.connect(control.db_path)
    try:
        payloads = [row[0] for row in connection.execute("SELECT structured_payload FROM card_revisions")]
        assert all("Ship the current release format." not in payload for payload in payloads)
        assert all("Ship the legacy release format." not in payload for payload in payloads)
    finally:
        connection.close()

    invalid_graph = root / "invalid-decision-graph.jsonl"
    invalid_graph.write_text(
        graph_path.read_text(encoding="utf-8")
        + json.dumps(decision_graph_record("decision:current-release", "decides", "Conflicting decision."))
        + "\n",
        encoding="utf-8",
    )
    before = control.status()["events"]
    try:
        control.sync_decision_graph_shadow(invalid_graph)
        raise AssertionError("conflicting graph decisions must fail closed")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_SHADOW_DECISION_CONFLICT"
    assert control.status()["events"] == before


def test_control_center_card_queries_and_privacy(root: Path) -> None:
    control = BrainControl(root / "control-center-card-queries")
    aggregate_id = "notebook-local-edit"
    created = control.apply(
        card_command(
            "note",
            "notebook-create",
            aggregate_id,
            0,
            {
                "schema": "super-brain.card.note.v1",
                "body": "Keep delivery criteria visible before declaring a project complete.",
                "tags": ["delivery", "notebook"],
                "links": [],
                "pinned": True,
            },
            title="Delivery checklist",
        )
    )
    assert created["revision"] == 1

    listed = control.list_cards_for_ui(kinds=["note"])
    assert [item["cardId"] for item in listed["items"]] == [aggregate_id]
    assert listed["items"][0]["summary"].startswith("Keep delivery criteria")
    overview = control.control_center_overview()
    assert overview["cardsByKind"]["note"] == 1
    assert overview["recentEvents"] and overview["recentEvents"][0]["aggregateId"] == aggregate_id
    searched = control.search_cards_for_ui("delivery criteria", kinds=["note"])
    assert [item["cardId"] for item in searched["items"]] == [aggregate_id]
    detail = control.get_card_for_ui(aggregate_id)
    assert detail is not None and detail["payload"]["pinned"] is True
    draft_body = {
        "cardId": aggregate_id,
        "kind": "note",
        "title": "Delivery checklist draft",
        "payload": {"schema": "super-brain.card.note.v1", "body": "The unsaved draft survives a browser refresh."},
    }
    draft_receipt = control.save_ui_draft(aggregate_id, 1, draft_body)
    assert draft_receipt["baseRevision"] == 1
    recovered_draft = control.get_ui_draft(aggregate_id, 1)
    assert recovered_draft["available"] and recovered_draft["draft"]["title"] == "Delivery checklist draft"
    lock_connection = sqlite3.connect(control.db_path, timeout=0.1, isolation_level=None)
    try:
        lock_connection.execute("BEGIN IMMEDIATE")
        locked_read = control.get_ui_draft(aggregate_id, 1)
        assert locked_read["available"] and locked_read["draftHash"] == recovered_draft["draftHash"]
    finally:
        lock_connection.execute("ROLLBACK")
        lock_connection.close()

    trashed = control.apply(
        {
            "commandType": "trash_card",
            "commandId": "notebook-trash",
            "aggregateId": aggregate_id,
            "expectedRevision": 1,
            "actorReceipt": actor_receipt(authorization="user_confirmed"),
            "reason": "move the obsolete note to Trash",
            "source": "runtime_brain_control_regression",
        }
    )
    assert trashed["operation"] == "trash" and trashed["lifecycle"] == "trashed"
    assert not control.get_ui_draft(aggregate_id, 2)["available"]
    try:
        control.save_ui_draft(aggregate_id, 1, draft_body)
        raise AssertionError("UI drafts must reject a stale base revision")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_STALE_REVISION"
    assert not control.list_cards_for_ui(kinds=["note"])["items"]
    in_trash = control.list_cards_for_ui(kinds=["note"], lifecycles=["trashed"])
    assert [item["cardId"] for item in in_trash["items"]] == [aggregate_id]

    restored = control.apply(
        {
            "commandType": "restore_card",
            "commandId": "notebook-restore",
            "aggregateId": aggregate_id,
            "expectedRevision": 2,
            "actorReceipt": actor_receipt(authorization="user_confirmed"),
            "reason": "restore the note from Trash",
            "source": "runtime_brain_control_regression",
        }
    )
    assert restored["operation"] == "restore" and restored["lifecycle"] == "active"

    try:
        control.apply(
            {
                "commandType": "forget_active",
                "commandId": "notebook-forget-missing-ack",
                "aggregateId": aggregate_id,
                "expectedRevision": 3,
                "forgetAcknowledged": False,
                "actorReceipt": actor_receipt(authorization="user_confirmed"),
                "reason": "attempt a forget without acknowledgement",
                "source": "runtime_brain_control_regression",
            }
        )
        raise AssertionError("ForgetActive must require an explicit acknowledgement")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_CARD_FORGET_ACKNOWLEDGEMENT_REQUIRED"

    forgotten = control.apply(
        {
            "commandType": "forget_active",
            "commandId": "notebook-forget",
            "aggregateId": aggregate_id,
            "expectedRevision": 3,
            "forgetAcknowledged": True,
            "actorReceipt": actor_receipt(authorization="user_confirmed"),
            "reason": "forget the active note body",
            "source": "runtime_brain_control_regression",
        }
    )
    assert forgotten["operation"] == "forget" and forgotten["lifecycle"] == "forgotten"
    assert not control.search_cards_for_ui("delivery criteria", kinds=["note"])["items"]
    forgotten_detail = control.get_card_for_ui(aggregate_id)
    assert forgotten_detail is not None and forgotten_detail["forgotten"]
    assert forgotten_detail["payload"] == {"schema": "super-brain.card.tombstone.v1", "forgotten": True}
    history = control.get_card_history_for_ui(aggregate_id)
    assert history["items"] and all(item["forgotten"] for item in history["items"])

    preview = control.preview_purge_everywhere(aggregate_id, 4, actor_receipt(authorization="user_confirmed"))
    assert preview["physicalSecureErasureClaim"] is False
    try:
        control.request_purge_everywhere(preview["previewId"], "PURGE wrong-card", actor_receipt(authorization="user_confirmed"))
        raise AssertionError("PurgeEverywhere must validate the preview-bound confirmation phrase")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_PURGE_CONFIRMATION_INVALID"
    requested = control.request_purge_everywhere(
        preview["previewId"], preview["confirmationPhrase"], actor_receipt(authorization="user_confirmed")
    )
    assert requested["status"] == "requested_for_p5_retention_governance"
    replayed = control.request_purge_everywhere(
        preview["previewId"], preview["confirmationPhrase"], actor_receipt(authorization="user_confirmed")
    )
    assert replayed["idempotent"] is True

    hard_decision = card_command(
        "decision",
        "hard-decision-create",
        "hard-decision",
        0,
        completion_decision_payload(),
        title="Hard delivery decision",
    )
    hard_decision["scope"] = {"kind": "workspace", "key": "ws-control-center"}
    control.apply(hard_decision)
    try:
        control.apply(
            {
                "commandType": "trash_card",
                "commandId": "hard-decision-trash",
                "aggregateId": "hard-decision",
                "expectedRevision": 1,
                "actorReceipt": actor_receipt(authorization="user_confirmed"),
                "reason": "attempt to hide a completion gate",
                "source": "runtime_brain_control_regression",
            }
        )
        raise AssertionError("completion gates must not enter Trash")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_DECISION_TRASH_UNAVAILABLE"


def test_memory_timeline_projects_only_verified_sources(root: Path) -> None:
    control = BrainControl(root / "memory-timeline")
    task = task_request("timeline-task-import", initial_revision=0)
    task.update(
        {
            "taskId": "task-timeline-private-id",
            "taskInstanceId": "ti-" + "9" * 32,
            "workspaceKey": "ws-timeline-private-key",
            "ownerSessionKey": "sid-" + "7" * 24,
        }
    )
    state = task["state"]
    assert isinstance(state, dict)
    state["focusLabel"] = "发布归档检查"
    control.import_task(task)
    contract = {
        "schema": "super-brain.execution-contract.v1",
        "taskId": task["taskId"],
        "taskInstanceId": task["taskInstanceId"],
        "workspaceKey": task["workspaceKey"],
        "ownerSessionKey": task["ownerSessionKey"],
        "status": "active",
        "revision": 1,
        "conversationTitle": "发布归档讨论",
    }
    (control.workspace / "last-execution-contract.json").write_text(json.dumps(contract), encoding="utf-8")
    source_context = control.current_card_source_context_for_ui()
    assert source_context is not None and source_context["conversationTitle"] == "发布归档讨论"

    bound_command = card_command(
        "note",
        "timeline-bound-create",
        "timeline-bound-card-private-id",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "发布完成前，检查归档目录和交付清单。",
            "tags": [],
            "links": [],
            "pinned": False,
        },
        title="发布归档提醒",
    )
    bound_command["sourceContext"] = source_context
    control.apply(bound_command)

    control.apply(
        card_command(
            "note",
            "timeline-unbound-create",
            "timeline-unbound-card-private-id",
            0,
            {
                "schema": "super-brain.card.note.v1",
                "body": "独立的本地笔记不应被猜测为来自当前任务。",
                "tags": [],
                "links": [],
                "pinned": False,
            },
            title="独立笔记",
        )
    )

    trashed = card_command(
        "note",
        "timeline-trashed-create",
        "timeline-trashed-card-private-id",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "This deleted record must stay in the recycle bin, not the timeline.",
            "tags": [],
            "links": [],
            "pinned": False,
        },
        title="已删除的时间线记录",
    )
    control.apply(trashed)
    control.apply(
        {
            "commandType": "trash_card",
            "commandId": "timeline-trashed-trash",
            "aggregateId": "timeline-trashed-card-private-id",
            "expectedRevision": 1,
            "actorReceipt": actor_receipt(authorization="user_confirmed"),
            "reason": "keep deleted records out of the timeline",
            "source": "runtime_brain_control_regression",
        }
    )

    timeline = control.list_memory_timeline_for_ui()
    assert timeline["schema"] == "super-brain.ui-memory-timeline.v1"
    bound = next(item for item in timeline["items"] if item["title"] == "发布归档提醒")
    assert bound["date"] and bound["kindLabel"] == "笔记"
    assert isinstance(bound.get("cardRef"), str) and bound["cardRef"].startswith("card-")
    assert bound["summary"].startswith("发布完成前")
    assert bound["source"] == {"taskTitle": "发布归档检查", "conversationTitle": "发布归档讨论"}
    opened = control.get_card_for_ui_reference(str(bound["cardRef"]))
    assert opened is not None and opened["title"] == "发布归档提醒"
    unbound = next(item for item in timeline["items"] if item["title"] == "独立笔记")
    assert isinstance(unbound.get("cardRef"), str) and unbound["cardRef"].startswith("card-")
    assert "source" not in unbound
    assert not any(item["title"] == "已删除的时间线记录" for item in timeline["items"])
    serialized = json.dumps(timeline, ensure_ascii=False)
    for private_value in (
        "timeline-bound-card-private-id",
        "task-timeline-private-id",
        "ws-timeline-private-key",
        "sid-" + "7" * 24,
        str(control.workspace),
    ):
        assert private_value not in serialized

    invalid = card_command(
        "note",
        "timeline-invalid-source",
        "timeline-invalid-source-card",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "This source context must be rejected.",
            "tags": [],
            "links": [],
            "pinned": False,
        },
    )
    invalid["sourceContext"] = {"taskId": "missing required provenance"}
    try:
        control.apply(invalid)
        raise AssertionError("timeline source context must be typed and complete")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_CARD_SOURCE_INVALID"


def test_memory_starmap_projects_only_explicit_relations(root: Path) -> None:
    control = BrainControl(root / "memory-starmap")
    task = task_request("starmap-task-import", initial_revision=0)
    task.update(
        {
            "taskId": "task-starmap-private-id",
            "taskInstanceId": "ti-" + "1" * 32,
            "workspaceKey": "ws-starmap-private-key",
            "ownerSessionKey": "sid-" + "2" * 24,
        }
    )
    state = task["state"]
    assert isinstance(state, dict)
    state["focusLabel"] = "记忆星图关联回归"
    control.import_task(task)
    contract = {
        "schema": "super-brain.execution-contract.v1",
        "taskId": task["taskId"],
        "taskInstanceId": task["taskInstanceId"],
        "workspaceKey": task["workspaceKey"],
        "ownerSessionKey": task["ownerSessionKey"],
        "status": "active",
        "revision": 1,
        "conversationTitle": "记忆星图讨论",
    }
    (control.workspace / "last-execution-contract.json").write_text(json.dumps(contract), encoding="utf-8")
    source_context = control.current_card_source_context_for_ui()
    assert source_context is not None

    note_a = card_command(
        "note",
        "starmap-note-a-create",
        "starmap-note-a-private-id",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "发布完成前检查归档目录和交付清单。",
            "tags": ["发布"],
            "links": [],
            "pinned": True,
        },
        title="发布归档提醒",
    )
    note_a["sourceContext"] = source_context
    control.apply(note_a)

    note_b = card_command(
        "note",
        "starmap-note-b-create",
        "starmap-note-b-private-id",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "安装包生成后还需要把交付文件归档到版本目录。",
            "tags": ["发布"],
            "links": ["card:starmap-note-a-private-id"],
            "pinned": False,
        },
        title="发布归档后续动作",
    )
    note_b["sourceContext"] = source_context
    control.apply(note_b)

    note_c = card_command(
        "note",
        "starmap-note-c-create",
        "starmap-note-c-private-id",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "发布完成后需要保留测试报告和更新说明。",
            "tags": ["发布"],
            "links": [],
            "pinned": False,
        },
        title="发布交付补充",
    )
    note_c["sourceContext"] = source_context
    control.apply(note_c)

    preference = card_command(
        "preference",
        "starmap-preference-create",
        "starmap-preference-private-id",
        0,
        {
            "schema": "super-brain.card.preference.v1",
            "statement": "长任务每完成一个阶段都要汇报进度。",
            "conditions": ["长任务"],
            "confidence": 92,
            "evidenceUses": 4,
            "conflictState": "clear",
            "revalidateAfter": "",
            "tags": ["协作"],
        },
        title="阶段汇报偏好",
    )
    control.apply(preference)

    forgotten = card_command(
        "note",
        "starmap-forgotten-create",
        "starmap-forgotten-private-id",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "This forgotten body must not reach the star map.",
            "tags": ["发布"],
            "links": [],
            "pinned": False,
        },
        title="待忘记的星图记录",
    )
    control.apply(forgotten)
    trashed = card_command(
        "note",
        "starmap-trashed-create",
        "starmap-trashed-private-id",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "This trashed body must not reach the star map.",
            "tags": ["发布"],
            "links": [],
            "pinned": False,
        },
        title="已放入回收站的星图记录",
    )
    control.apply(trashed)
    control.apply(
        {
            "commandType": "trash_card",
            "commandId": "starmap-trashed-trash",
            "aggregateId": "starmap-trashed-private-id",
            "expectedRevision": 1,
            "actorReceipt": actor_receipt(authorization="user_confirmed"),
            "reason": "verify trashed starmap exclusion",
            "source": "runtime_brain_control_regression",
        }
    )
    control.apply(
        {
            "commandType": "forget_active",
            "commandId": "starmap-forgotten-forget",
            "aggregateId": "starmap-forgotten-private-id",
            "expectedRevision": 1,
            "actorReceipt": actor_receipt(authorization="user_confirmed"),
            "forgetAcknowledged": True,
            "reason": "verify forgotten starmap redaction",
            "source": "runtime_brain_control_regression",
        }
    )

    starmap = control.list_memory_starmap_for_ui()
    assert starmap["schema"] == "super-brain.ui-memory-starmap.v1"
    assert starmap["currentTaskPresent"] is True
    assert any(node["kind"] == "task" and node["title"] == "记忆星图关联回归" for node in starmap["nodes"])
    assert any(node["title"] == "发布归档提醒" and node["isPinned"] is True for node in starmap["nodes"])
    assert starmap["counts"]["totalMemory"] == 4
    assert starmap["counts"]["shownMemory"] == 4
    assert starmap["counts"]["hiddenMemory"] == 0
    assert starmap["counts"]["individualMemory"] == 4
    assert starmap["counts"]["groupedMemory"] == 0
    assert starmap["counts"]["excludedByLifecycle"]["forgotten"] == 1
    assert starmap["counts"]["excludedByLifecycle"]["trashed"] == 1
    assert not any(node["title"] == "已忘记的记忆" for node in starmap["nodes"])
    assert not any(node["title"] == "已放入回收站的星图记录" for node in starmap["nodes"])
    assert not any(node.get("stateLabel") in {"回收站", "已忘记"} for node in starmap["nodes"])
    relations = {edge["relation"] for edge in starmap["edges"]}
    assert {"source", "explicit", "shared_tag"}.issubset(relations)
    assert relations.issubset({"source", "explicit", "shared_tag", "cluster"})
    serialized = json.dumps(starmap, ensure_ascii=False)
    for private_value in (
        "starmap-note-a-private-id",
        "starmap-note-b-private-id",
        "starmap-note-c-private-id",
        "starmap-trashed-private-id",
        "task-starmap-private-id",
        "ws-starmap-private-key",
        "sid-" + "2" * 24,
        "This forgotten body must not reach the star map.",
        "This trashed body must not reach the star map.",
        str(control.workspace),
    ):
        assert private_value not in serialized


def test_memory_starmap_falls_back_to_current_contract_and_keeps_anonymized_source_edges(root: Path) -> None:
    state_root = root / "memory-starmap-contract-fallback"
    contract = {
        "schema": "super-brain.execution-contract.v1",
        "taskId": "task-current-private-id",
        "taskInstanceId": "ti-" + "c" * 32,
        "workspaceKey": "ws-" + "a" * 24,
        "ownerSessionKey": "sid-" + "d" * 24,
        "status": "active",
        "revision": 3,
        "focusLabel": "Contract-backed starmap task",
        "currentStep": "project verified source relationships",
        "nextAction": "show safe relationship edges",
    }
    control = BrainControl(state_root, ui_workspace_key=str(contract["workspaceKey"]))
    control.workspace.mkdir(parents=True, exist_ok=True)
    contract_root = control.workspace / "runtime-state" / "execution-contracts"
    contract_root.mkdir(parents=True, exist_ok=True)
    (contract_root / f"current-contract--{contract['workspaceKey']}.json").write_text(json.dumps(contract), encoding="utf-8")
    pointer_hash = hashlib.sha256(str(contract["workspaceKey"]).encode("utf-8")).hexdigest()[:16]
    pointer_path = control.workspace / "guard-state" / "current-task-context-pointers" / f"{contract['workspaceKey']}--{pointer_hash}.json"
    pointer_path.parent.mkdir(parents=True, exist_ok=True)
    pointer_path.write_text(
        json.dumps(
            {
                "schema": "super-brain.current-task-context.v1",
                "status": "active",
                "taskId": contract["taskId"],
                "taskInstanceId": contract["taskInstanceId"],
                "workspaceKey": contract["workspaceKey"],
                "ownerSessionKey": contract["ownerSessionKey"],
                "expiresAt": "2099-01-01T00:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    (control.workspace / "last-execution-contract.json").write_text(
        json.dumps(
            {
                "schema": "super-brain.execution-contract.v1",
                "taskId": "foreign-global-pointer",
                "workspaceKey": "ws-" + "0" * 24,
                "ownerSessionKey": "sid-" + "0" * 24,
                "status": "active",
            }
        ),
        encoding="utf-8",
    )
    current_source = control.current_card_source_context_for_ui()
    assert current_source is not None

    current_note = card_command(
        "note",
        "starmap-contract-current-note",
        "starmap-contract-current-private-card",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "This card has the current contract as verified provenance.",
            "tags": [],
            "links": [],
            "pinned": False,
        },
        title="Contract source card",
    )
    current_note["sourceContext"] = current_source
    control.apply(current_note)

    archived_note = card_command(
        "note",
        "starmap-contract-archived-note",
        "starmap-contract-archived-private-card",
        0,
        {
            "schema": "super-brain.card.note.v1",
            "body": "This card retains provenance after its source task was archived.",
            "tags": [],
            "links": [],
            "pinned": False,
        },
        title="Archived source card",
    )
    archived_note["sourceContext"] = {
        "schema": "super-brain.card-source-context.v1",
        "taskId": "task-archived-private-id",
        "taskInstanceId": "ti-" + "e" * 32,
        "workspaceKey": "ws-" + "b" * 24,
        "ownerSessionKey": "sid-" + "f" * 24,
        "conversationTitle": "Archived conversation",
    }
    control.apply(archived_note)

    starmap = control.list_memory_starmap_for_ui()
    assert starmap["currentTaskPresent"] is True
    assert any(node["kind"] == "task" and node["isCurrent"] and node["title"] == "Contract-backed starmap task" for node in starmap["nodes"])
    assert len([node for node in starmap["nodes"] if node["kind"] == "task" and not node["isCurrent"]]) == 1
    assert sum(1 for edge in starmap["edges"] if edge["relation"] == "source") == 2
    serialized = json.dumps(starmap, ensure_ascii=False)
    for private_value in (
        "task-current-private-id",
        "task-archived-private-id",
        "starmap-contract-current-private-card",
        "starmap-contract-archived-private-card",
        "ws-" + "a" * 24,
        "ws-" + "b" * 24,
        "sid-" + "d" * 24,
        "sid-" + "f" * 24,
    ):
        assert private_value not in serialized


def test_memory_starmap_connects_legacy_candidates_only_by_shared_migration_source(root: Path) -> None:
    control = BrainControl(root / "memory-starmap-migration-source")
    epoch_id = "migration-20260805"
    for index in range(3):
        command_value = card_command(
            "note",
            f"starmap-migration-card-{index}-create",
            f"starmap-migration-private-card-{index}",
            0,
            {
                "schema": "super-brain.card.note.v1",
                "body": f"Legacy candidate {index} remains proposed.",
                "tags": [],
                "links": [],
                "pinned": False,
            },
            title=f"Legacy migration candidate {index}",
        )
        command_value["lifecycle"] = "proposed"
        command_value["authority"] = "legacy"
        command_value["actorReceipt"] = actor_receipt(authorization="legacy", actor_kind="legacy")
        command_value["evidenceRefs"] = [f"migration:{epoch_id}:{index + 1:064x}"]
        control.apply(command_value)

    starmap = control.list_memory_starmap_for_ui()
    migration_edges = [edge for edge in starmap["edges"] if edge["relation"] == "migration_source"]
    assert len(migration_edges) == 2
    assert not any(edge["relation"] == "shared_tag" for edge in starmap["edges"])
    assert starmap["counts"]["shownMemory"] == 3
    serialized = json.dumps(starmap, ensure_ascii=False)
    assert epoch_id not in serialized
    for index in range(3):
        assert f"starmap-migration-private-card-{index}" not in serialized


def test_memory_starmap_aggregation_preserves_filterable_kind_counts(root: Path) -> None:
    control = BrainControl(root / "memory-starmap-aggregation")
    projection_limit = 160

    for index in range(projection_limit + 2):
        card_id = f"starmap-aggregation-note-{index:03d}"
        control.apply(
            card_command(
                "note",
                f"starmap-aggregation-note-create-{index:03d}",
                card_id,
                0,
                {
                    "schema": "super-brain.card.note.v1",
                    "body": f"Aggregation regression note {index}.",
                    "tags": ["aggregation"],
                    "links": [],
                    "pinned": False,
                },
                title=f"Aggregation regression note {index:03d}",
            )
        )

    for index in range(2):
        command = card_command(
            "preference",
            f"starmap-aggregation-preference-create-{index}",
            f"starmap-aggregation-preference-{index}",
            0,
            {
                "schema": "super-brain.card.preference.v1",
                "statement": f"Keep aggregation evidence {index} visible.",
                "conditions": ["starmap aggregation regression"],
                "confidence": 92,
                "evidenceUses": 3,
                "tags": ["aggregation"],
            },
            title=f"Aggregation proposed preference {index}",
        )
        command["lifecycle"] = "proposed"
        control.apply(command)

    starmap = control.list_memory_starmap_for_ui()
    counts = starmap["counts"]
    assert counts["projectionLimit"] == projection_limit
    assert counts["totalMemory"] == projection_limit + 4
    assert counts["shownMemory"] == projection_limit
    assert counts["hiddenMemory"] == 4
    assert counts["individualMemory"] == projection_limit
    assert counts["groupedMemory"] == 4
    assert counts["eligibleByKind"] == {"note": projection_limit + 2, "preference": 2}
    assert counts["individualByKind"] == {"note": projection_limit - 2, "preference": 2}

    clusters = [node for node in starmap["nodes"] if node["kind"] == "cluster"]
    assert len(clusters) == 1
    assert clusters[0]["clusterKind"] == "note"
    assert clusters[0]["representedCount"] == 4

    represented_by_kind: dict[str, int] = {}
    for node in starmap["nodes"]:
        if node["kind"] == "task":
            continue
        node_kind = node["clusterKind"] if node["kind"] == "cluster" else node["kind"]
        represented_by_kind[node_kind] = represented_by_kind.get(node_kind, 0) + (
            int(node["representedCount"]) if node["kind"] == "cluster" else 1
        )
    assert represented_by_kind == counts["eligibleByKind"]


def test_task_history_retention_is_logical_reversible_and_scope_bound(root: Path) -> None:
    control = BrainControl(root / "task-history-retention")
    completed = task_request("task-history-completed-import", initial_revision=0)
    completed.update(
        {
            "taskId": "task-history-completed-private-id",
            "taskInstanceId": "ti-" + "a" * 32,
            "workspaceKey": "ws-task-history-current",
            "ownerSessionKey": "sid-" + "b" * 24,
        }
    )
    completed_state = completed["state"]
    assert isinstance(completed_state, dict)
    completed_state.update(
        {
            "lifecycle": "completed",
            "focusLabel": "完成归档任务",
            "currentStep": "完成并等待整理",
            "nextAction": "保留历史证据",
            "completedAt": (datetime.now(UTC) - timedelta(days=46)).isoformat().replace("+00:00", "Z"),
        }
    )
    control.import_task(completed)

    trashed = task_request("task-history-trash-import", initial_revision=0)
    trashed.update(
        {
            "taskId": "task-history-trash-private-id",
            "taskInstanceId": "ti-" + "b" * 32,
            "workspaceKey": "ws-task-history-current",
            "ownerSessionKey": "sid-" + "b" * 24,
        }
    )
    trashed_state = trashed["state"]
    assert isinstance(trashed_state, dict)
    trashed_state.update(
        {
            "lifecycle": "completed",
            "focusLabel": "应进入回收站的任务",
            "completedAt": (datetime.now(UTC) - timedelta(days=16)).isoformat().replace("+00:00", "Z"),
        }
    )
    control.import_task(trashed)

    sealed = task_request("task-history-sealed-import", initial_revision=0)
    sealed.update(
        {
            "taskId": "task-history-sealed-private-id",
            "taskInstanceId": "ti-" + "d" * 32,
            "workspaceKey": "ws-task-history-current",
            "ownerSessionKey": "sid-" + "b" * 24,
        }
    )
    sealed_state = sealed["state"]
    assert isinstance(sealed_state, dict)
    sealed_state.update(
        {
            "lifecycle": "completed",
            "focusLabel": "等待紧凑证据的任务",
            "completedAt": (datetime.now(UTC) - timedelta(days=24)).isoformat().replace("+00:00", "Z"),
        }
    )
    control.import_task(sealed)

    missing_evidence = task_request("task-history-missing-evidence-import", initial_revision=0)
    missing_evidence.update(
        {
            "taskId": "task-history-missing-evidence-private-id",
            "taskInstanceId": "ti-" + "c" * 32,
            "workspaceKey": "ws-task-history-current",
            "ownerSessionKey": "sid-" + "d" * 24,
        }
    )
    missing_state = missing_evidence["state"]
    assert isinstance(missing_state, dict)
    missing_state.update({"lifecycle": "completed", "focusLabel": "缺少完成时间的旧任务"})
    control.import_task(missing_evidence)

    foreign = task_request("task-history-foreign-import", initial_revision=0)
    foreign.update(
        {
            "taskId": "task-history-foreign-private-id",
            "taskInstanceId": "ti-" + "e" * 32,
            "workspaceKey": "ws-task-history-foreign",
            "ownerSessionKey": "sid-" + "f" * 24,
        }
    )
    foreign_state = foreign["state"]
    assert isinstance(foreign_state, dict)
    foreign_state.update(
        {
            "lifecycle": "completed",
            "focusLabel": "Foreign task details must never enter task history.",
            "completedAt": (datetime.now(UTC) - timedelta(days=90)).isoformat().replace("+00:00", "Z"),
        }
    )
    control.import_task(foreign)

    contract = {
        "schema": "super-brain.execution-contract.v1",
        "taskId": completed["taskId"],
        "taskInstanceId": completed["taskInstanceId"],
        "workspaceKey": completed["workspaceKey"],
        "ownerSessionKey": completed["ownerSessionKey"],
        "status": "active",
        "revision": 1,
    }
    (control.workspace / "last-execution-contract.json").write_text(json.dumps(contract), encoding="utf-8")

    history = control.task_history_for_ui()
    assert history["settings"]["completedDays"] == 7
    assert history["settings"]["trashDays"] == 15
    assert history["settings"]["compactEvidenceDays"] == 30
    trashed_item = next(item for item in history["items"] if item["title"] == "应进入回收站的任务")
    missing_item = next(item for item in history["items"] if item["title"] == "缺少完成时间的旧任务")
    assert all(item["title"] != "完成归档任务" for item in history["items"])
    assert all(item["title"] != "等待紧凑证据的任务" for item in history["items"])
    assert history["counts"]["evidenceOnly"] == 1
    assert history["counts"]["sealed"] == 1
    assert history["completionEvidence"]["count"] == 1
    assert history["completionEvidence"]["detailedTaskCardsVisible"] is False
    assert trashed_item["retentionState"] == "trashed" and trashed_item["canRestore"] is True
    assert missing_item["retentionState"] == "needs_review" and missing_item["canRestore"] is False
    history_json = json.dumps(history, ensure_ascii=False)
    assert "Foreign task details must never enter task history." not in history_json
    assert "task-history-completed-private-id" not in history_json
    assert "完成归档任务" not in history_json
    assert "ws-task-history-current" not in history_json
    connection = sqlite3.connect(control.db_path)
    try:
        automatic_receipt = connection.execute(
            "SELECT actor_receipt FROM ui_task_retention_receipts WHERE action='moved_to_trash' ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
        compact_evidence = connection.execute(
            "SELECT payload_json FROM ui_task_completion_evidence ORDER BY created_at DESC LIMIT 1"
        ).fetchone()
    finally:
        connection.close()
    assert automatic_receipt is not None
    assert json.loads(automatic_receipt[0])["authorization"] == "system"
    assert compact_evidence is not None
    compact_payload = json.loads(compact_evidence[0])
    assert compact_payload["schema"] == "super-brain.task-completion-evidence.v1"
    assert compact_payload["completedStepCount"] >= 0
    assert compact_payload["rawPromptStored"] is False and compact_payload["rawTranscriptStored"] is False

    try:
        control.update_task_retention_settings(
            completed_days=15,
            trash_days=30,
            expected_revision=int(history["settings"]["revision"]),
            actor_receipt=actor_receipt(),
        )
        raise AssertionError("retention window beyond the day-30 cutoff must fail")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_TASK_RETENTION_WINDOW_INVALID"

    settings = control.update_task_retention_settings(
        completed_days=8,
        trash_days=15,
        expected_revision=int(history["settings"]["revision"]),
        actor_receipt=actor_receipt(),
    )
    assert settings["settings"]["completedDays"] == 8 and settings["settings"]["trashDays"] == 15
    assert settings["settings"]["compactEvidenceDays"] == 30
    try:
        control.update_task_retention_settings(
            completed_days=7,
            trash_days=15,
            expected_revision=int(history["settings"]["revision"]),
            actor_receipt=actor_receipt(),
        )
        raise AssertionError("stale retention settings CAS must fail")
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_TASK_RETENTION_STALE"

    restored = control.restore_task_card_for_ui(trashed_item["taskCardKey"], actor_receipt())
    assert restored["retentionState"] == "visible"
    after_restore = control.task_history_for_ui()
    restored_item = next(item for item in after_restore["items"] if item["title"] == "应进入回收站的任务")
    assert restored_item["retentionState"] == "visible" and restored_item["canRestore"] is False
    connection = sqlite3.connect(control.db_path)
    try:
        lifecycle = connection.execute(
            "SELECT lifecycle FROM task_aggregates WHERE task_id=?", (completed["taskId"],)
        ).fetchone()
    finally:
        connection.close()
    assert lifecycle == ("completed",)

    # A compacted card is intentionally not restorable: its task UI content is
    # gone and only the minimal completion evidence remains.
    connection = sqlite3.connect(control.db_path)
    try:
        compacted_key_row = connection.execute(
            "SELECT task_key FROM ui_task_card_retention WHERE retention_state='evidence_only' LIMIT 1"
        ).fetchone()
    finally:
        connection.close()
    assert compacted_key_row is not None
    try:
        control.restore_task_card_for_ui(
            str(compacted_key_row[0]),
            actor_receipt(),
        )
    except BrainControlError as exc:
        assert exc.code == "BRAIN_CONTROL_TASK_RETENTION_RESTORE_INVALID"
    else:
        raise AssertionError("a compacted task card must not be restorable")


def test_instruction_anchor_and_continuation_receipt_preserve_latest_progress(root: Path) -> None:
    state_root = root / "instruction-anchor-continuation"
    control = BrainControl(state_root)
    scope = {
        "taskId": "task-anchor-continuation",
        "workspaceKey": "ws-anchor-continuation",
        "ownerSessionKey": "sid-anchor-continuation",
    }
    initial = control.observe_instruction_anchor(
        {
            **scope,
            "instruction": "Confirm A through G as the approved main plan.",
            "classification": {"mode": "continue", "topicAffinity": "active", "confidence": "high"},
            "source": "runtime_brain_control_regression",
        }
    )
    receipt = control.record_continuation_receipt(
        {
            **scope,
            "taskInstanceId": "ti-" + "a" * 32,
            "packageVersion": PACKAGE_VERSION,
            "contractRevision": 7,
            "planFingerprint": "plan-anchor-continuation",
            "instructionAnchor": initial["anchor"],
            "source": "runtime_brain_control_regression",
            "state": {
                "latestUserInstruction": "Confirm A through G as the approved main plan.",
                "lastConfirmedSentence": "A is complete; B through G remain.",
                "lastConfirmedSource": "assistant_commitment",
                "mainLine": "canonical-main",
                "activeLine": "canonical-main",
                "currentPhase": "P0",
                "currentStep": "A completed; B through G pending",
                "completedSteps": ["A"],
                "pendingSteps": ["B", "C", "D", "E", "F", "G"],
                "nextAction": "execute B through G in order",
                "evidence": ["tests/runtime_brain_control_regression.py"],
                "returnPoint": {"focusId": "canonical-main", "focusLabel": "Canonical main", "resumeFrom": "Set"},
                "canonicalPlan": {"planId": "plan-anchor-continuation", "generation": 1, "fingerprint": "plan-anchor-continuation", "completedCount": 1, "pendingCount": 6},
            },
        }
    )
    assert receipt["created"] is True
    bound_receipt = control.get_continuation_receipt(scope)
    assert bound_receipt["binding"]["state"] == "current"
    assert bound_receipt["binding"]["current"] is True

    appended = control.observe_instruction_anchor(
        {
            **scope,
            "instruction": "Also add H and I; do not replace A through G.",
            "source": "runtime_brain_control_regression",
            "preserveIfPending": False,
            "boundAnchor": initial["anchor"],
        }
    )
    anchor_status = control.check_instruction_anchor({**scope, "boundAnchor": initial["anchor"]})
    restored_receipt = control.get_continuation_receipt(scope)
    assert appended["anchor"]["globalSequence"] > initial["anchor"]["globalSequence"]
    assert anchor_status["current"] is False
    assert anchor_status["anchor"]["instruction"] == "Also add H and I; do not replace A through G."
    assert restored_receipt["available"] is True
    assert restored_receipt["receipt"]["state"]["lastConfirmedSentence"] == "A is complete; B through G remain."
    assert restored_receipt["receipt"]["state"]["pendingSteps"] == ["B", "C", "D", "E", "F", "G"]
    assert restored_receipt["latestInstructionAnchor"]["instruction"] == "Also add H and I; do not replace A through G."
    assert restored_receipt["binding"]["state"] == "newer_instruction_pending"
    assert restored_receipt["binding"]["current"] is False
    assert "Preserve the assistant progress receipt" in restored_receipt["binding"]["guard"]

    connection = sqlite3.connect(control.db_path)
    try:
        try:
            connection.execute("UPDATE instruction_anchors SET instruction_text='stale' WHERE global_sequence=1")
            raise AssertionError("instruction anchors must be append-only")
        except sqlite3.IntegrityError:
            pass
        try:
            connection.execute("DELETE FROM continuation_receipts WHERE global_sequence=1")
            raise AssertionError("continuation receipts must be append-only")
        except sqlite3.IntegrityError:
            pass
    finally:
        connection.close()


def test_hot_instruction_anchor_store_interoperates_with_brain_control(root: Path) -> None:
    state_root = root / "hot-instruction-anchor-store"
    scope = {
        "taskId": "task-hot-anchor-store",
        "workspaceKey": "ws-hot-anchor-store",
        "ownerSessionKey": "sid-hot-anchor-store",
    }
    store = InstructionAnchorStore(state_root)
    first = store.observe_instruction_anchor(
        {
            **scope,
            "instruction": "Keep the approved release acceptance criteria active.",
            "classification": {
                "mode": "continue",
                "topicAffinity": "active",
                "confidence": "high",
                "matchedKeys": [],
                "candidateLineIds": [],
                "recommendedInstructionMode": "continue",
                "reason": "the current contract is the only matched line",
            },
            "source": "runtime_brain_control_regression",
        }
    )
    assert first["created"] is True
    assert first["anchor"]["classification"]["matchedKeys"] == []
    assert first["anchor"]["classification"]["candidateLineIds"] == []
    assert first["anchor"]["classification"]["recommendedInstructionMode"] == "continue"
    assert first["anchor"]["classification"]["reason"] == "the current contract is the only matched line"

    control = BrainControl(state_root)
    visible = control.get_instruction_anchor(scope)
    assert visible["available"] is True
    assert visible["anchor"]["anchorId"] == first["anchor"]["anchorId"]

    second = control.observe_instruction_anchor(
        {
            **scope,
            "instruction": "Also retain the rollback proof before release.",
            "classification": {
                "mode": "line_reference",
                "topicAffinity": "suspended:release-main",
                "confidence": "high",
                "matchedKeys": [],
                "candidateLineIds": [],
                "recommendedInstructionMode": "resume_parent",
                "reason": "the release main line is suspended",
            },
            "source": "runtime_brain_control_regression",
            "boundAnchor": first["anchor"],
        }
    )
    preserved = store.observe_instruction_anchor(
        {
            **scope,
            "instruction": "continue",
            "source": "runtime_brain_control_regression",
            "preserveIfPending": True,
            "boundAnchor": first["anchor"],
        }
    )
    assert second["anchor"]["globalSequence"] > first["anchor"]["globalSequence"]
    assert second["anchor"]["classification"]["candidateLineIds"] == []
    assert second["anchor"]["classification"]["recommendedInstructionMode"] == "resume_parent"
    assert second["anchor"]["classification"]["reason"] == "the release main line is suspended"
    assert preserved["created"] is False
    assert preserved["preservedPending"] is True
    assert preserved["anchor"]["anchorId"] == second["anchor"]["anchorId"]


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-control-") as directory:
        root = Path(directory)
        control = BrainControl(root)
        assert control.status()["schemaVersion"] == 17

        first = control.apply(command("cmd-1", 0))
        assert first["revision"] == 1 and not first["idempotent"]
        repeated = control.apply(command("cmd-1", 0))
        assert repeated["revision"] == 1 and repeated["idempotent"]

        try:
            control.apply(command("cmd-1", 0, "Different release policy"))
            raise AssertionError("command id reuse must fail")
        except BrainControlError as exc:
            assert exc.code == "BRAIN_CONTROL_COMMAND_ID_REUSED"

        try:
            control.apply(command("cmd-stale", 0))
            raise AssertionError("stale revision must fail")
        except BrainControlError as exc:
            assert exc.code == "BRAIN_CONTROL_STALE_REVISION"

        second = control.apply(command("cmd-2", 1, "Release policy revised"))
        assert second["revision"] == 2
        card = control.get_card("decision-release-policy")
        assert card is not None and card["revision"] == 2 and card["predecessorHash"]
        events = control.pending_outbox()
        assert len(events) == 2
        assert "payload" not in events[0]["payload"]
        materialized = control.materialize_outbox()
        assert materialized["materializedEventCount"] == 2
        card_projection = materialized["cardProjection"]
        assert isinstance(card_projection, dict)
        assert read_card_projection(card_projection["path"])["ok"]
        assert not control.pending_outbox()

        try:
            unsafe = command("cmd-secret", 2)
            unsafe["payload"] = {"api_key": "should-not-enter"}
            control.apply(unsafe)
            raise AssertionError("sensitive admission must fail")
        except BrainControlError as exc:
            assert exc.code == "BRAIN_CONTROL_SENSITIVE_FIELD"

        connection = sqlite3.connect(control.db_path)
        try:
            assert connection.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
            assert connection.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 2
        finally:
            connection.close()

        test_decision_graph_shadow(root)
        test_intent_authority(root)
        test_intent_session_rebind_preserves_original_task_intent(root)
        test_task_authority(root)
        test_task_session_rebind_receipt_authorizes_owner_transfer(root)
        test_control_center_overview_isolates_current_execution_scope(root)
        test_task_concurrent_cas(root)
        test_task_concurrent_idempotent_replay(root)
        test_task_shape_normalization(root)
        test_card_contracts(root)
        test_typed_card_edit_supersede_and_rollback(root)
        test_decision_resolution_and_completion_gate(root)
        test_decision_scope_filtering(root)
        test_memory_influence_uses_typed_cards_without_turning_candidates_into_constraints(root)
        test_task_scoped_trial_projection_is_nonbinding_and_hash_bound(root)
        test_offline_memory_consolidation_is_read_only_and_privacy_bound(root)
        test_cognitive_enforce_projects_typed_memory_into_the_real_pre_mutation_gate(root)
        test_mcp_snapshot_publisher(root)
        test_mcp_reads_published_control_snapshot(root)
        test_mcp_rejects_future_control_snapshot(root)
        test_mcp_snapshot_withholds_stale_or_pending_delivery(root)
        test_mcp_snapshot_publishes_bounded_scope_bound_task_projection(root)
        test_mcp_snapshot_accepts_allowed_h7_projection_as_display_only(root)
        test_mcp_task_recall_uses_unique_host_scope_and_fails_closed_when_ambiguous(root)
        test_card_schema_migration_recovery(root)
        test_control_center_card_queries_and_privacy(root)
        test_memory_timeline_projects_only_verified_sources(root)
        test_memory_starmap_projects_only_explicit_relations(root)
        test_memory_starmap_falls_back_to_current_contract_and_keeps_anonymized_source_edges(root)
        test_memory_starmap_connects_legacy_candidates_only_by_shared_migration_source(root)
        test_memory_starmap_aggregation_preserves_filterable_kind_counts(root)
        test_task_history_retention_is_logical_reversible_and_scope_bound(root)
        test_instruction_anchor_and_continuation_receipt_preserve_latest_progress(root)
        test_hot_instruction_anchor_store_interoperates_with_brain_control(root)
        test_legacy_migration_is_hash_bound_and_adapter_reversible(root)
        test_sandglass_history_migration_is_source_bound_private_and_logically_reversible(root)

    print("RUNTIME_BRAIN_CONTROL_REGRESSION_OK")


if __name__ == "__main__":
    main()
