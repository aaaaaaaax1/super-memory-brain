"""Dynamic R6 continuation control-plane replay.

This is deliberately an isolated, temporary-state suite.  It validates the
new distinction between a same-workline visible *display* observation and a
strict v4 recovery anchor without touching a user's H7 contract or memory.
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))
sys.path.insert(0, str(ROOT / "tests"))

import runtime_turn_runtime_regression as fixture
from brain_core import BrainCore
from host_continuation_bridge import (
    PURPOSE_DRIFT_DIAGNOSIS,
    PURPOSE_NORMAL_SAME_WORKLINE,
    PURPOSE_STRICT_RECOVERY,
    observe_current_thread,
)
from host_visible_tail import observe_visible_context_message
from turn_runtime import run_turn


PACKAGE_ROOT = ROOT
THREAD_ID = "sid-" + "6" * 24
PLAIN_TAIL = "I am checking the current project proof before continuing."
CONTINUITY_MAPPING_FIELDS = {
    "schema",
    "state",
    "code",
    "source",
    "visibleContextAvailable",
    "stateCardUsed",
    "taskIdHash",
    "taskInstanceId",
    "contractRevision",
    "contractHash",
    "currentPhase",
    "currentStep",
    "nextAction",
    "projectProofState",
    "visibleProgressState",
    "formalActionAllowed",
    "duplicateActionPrevented",
}


def _continuity_mapping(result: dict[str, object]) -> dict[str, object]:
    """Require the compact public mapping, not a hidden contract inference.

    The visible tail answers where the controller starts looking.  This packet
    makes the subsequent authoritative task/step/proof mapping explicit so a
    caller cannot accidentally treat ordinary prose, a stale card, or an old
    receipt as the actual next action.
    """

    mapping = result.get("continuityMapping")
    assert isinstance(mapping, dict), result
    missing = CONTINUITY_MAPPING_FIELDS - set(mapping)
    assert not missing, (missing, mapping)
    assert mapping["schema"] == "super-brain.continuity-mapping.v1", mapping
    return mapping


def _tree_bytes(root: Path) -> dict[str, bytes]:
    """Capture persistent state exactly; no state mutation may hide in a test."""

    if not root.exists():
        return {}
    return {
        str(path.relative_to(root)).replace("\\", "/"): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def _fixture() -> tuple[tempfile.TemporaryDirectory[str], Path, Path, Path, Path]:
    temporary = tempfile.TemporaryDirectory(prefix="super-brain-r6-dynamic-")
    root = Path(temporary.name)
    state_root = root / "state"
    memory_root = state_root / "shared"
    host_root = root / "host"
    memory_root.mkdir(parents=True)
    host_root.mkdir()
    (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
    fixture.write_native_memory_snapshot(state_root / "workspace")
    fixture.write_context_contract(state_root, host_root, THREAD_ID, task_id="task-r6-dynamic")
    contract_path = (
        state_root
        / "workspace"
        / "runtime-state"
        / "execution-contracts"
        / fixture.contract_file_name("task-r6-dynamic", fixture.host_workspace_key(host_root))
    )
    return temporary, state_root, memory_root, host_root, contract_path


def _plain_observation() -> dict[str, object]:
    result = observe_visible_context_message(
        host_thread_id=THREAD_ID,
        turn_id="turn-r6-current",
        message_id="message-r6-plain",
        phase="commentary",
        text=PLAIN_TAIL,
    )
    assert result["ok"] is True, result
    assert result["selection"] == "current_visible_assistant", result
    assert result["publication_kind"] == "unclassified_assistant_reply", result
    return {key: value for key, value in result.items() if key != "ok"}


def _durable_observation(
    contract: dict[str, object],
    *,
    sentence: str | None = None,
    selection: str = "current_visible_assistant",
) -> dict[str, object]:
    result = fixture.visible_tail_assertion(
        host_thread_id=THREAD_ID,
        sentence=sentence or str(contract["lastConfirmedSentence"]),
        phase=str(contract["currentPhase"]),
        current_step=str(contract["currentStep"]),
        next_action=str(contract["nextAction"]),
        host_turn_id="turn-r6-current",
        host_message_id="message-r6-durable",
        selection=selection,
        receipt_hash=str((contract.get("visibleProgressReceipt") or {}).get("payloadHash", "")),
    )
    assert result["schema"] == "super-brain.visible-tail-observation.v4", result
    return result


def test_normal_same_workline_plain_tail_is_display_only_and_contract_unchanged() -> None:
    temporary, state_root, memory_root, host_root, contract_path = _fixture()
    try:
        before_contract = contract_path.read_bytes()
        with fixture.with_host_scope(host_root, THREAD_ID):
            result = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion=_plain_observation(),
            )
        assert result["available"] is True, result
        # Public mapping is introduced by the tail-first runtime change; this
        # pre-existing regression intentionally goes red until then.
        tail = result["visibleTailAssertion"]
        assert tail["state"] == "observed_display_only", tail
        assert tail["continuationRole"] == "display_only", tail
        assert tail["nonAuthorizing"] is True, tail
        assert result["recoveryPresentation"]["code"] == "H7_RECOVERY_PRESENTATION_SUPPRESSED", result
        assert contract_path.read_bytes() == before_contract
        observation = result["context"]["visibleProgressObservation"]
        assert observation["displaySentenceHash"] == hashlib.sha256(PLAIN_TAIL.encode("utf-8")).hexdigest(), observation
        assert observation["sentenceHash"] != observation["displaySentenceHash"], observation
        assert not (state_root / "workspace" / "runtime-state" / "turn-runtime" / "visible-progress-readbacks").exists()
    finally:
        temporary.cleanup()


def test_raw_helper_observation_unwraps_once_but_bad_wrappers_fail_closed() -> None:
    """The Host helper may be passed directly without weakening H7 validation."""

    temporary, state_root, memory_root, host_root, _contract_path = _fixture()
    try:
        raw = observe_visible_context_message(
            host_thread_id=THREAD_ID,
            turn_id="turn-r6-helper-raw",
            message_id="message-r6-helper-raw",
            phase="commentary",
            text="The raw helper result should map the current workline without a hand-edited wrapper.",
        )
        assert raw["ok"] is True, raw
        with fixture.with_host_scope(host_root, THREAD_ID):
            accepted = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion=raw,
            )
        assert accepted["available"] is True, accepted
        assert accepted["visibleTailAssertion"]["continuationRole"] == "display_only", accepted
        after_accepted = _tree_bytes(state_root)

        with fixture.with_host_scope(host_root, THREAD_ID):
            unknown_field = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                visible_progress_assertion={**raw, "unexpected": True},
            )
            failed_helper = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                visible_progress_assertion={**raw, "ok": False},
            )

        for rejected in (unknown_field, failed_helper):
            assert rejected["available"] is False, rejected
            assert rejected["code"] == "H7_VISIBLE_TAIL_ASSERTION_INVALID", rejected
        assert _tree_bytes(state_root) == after_accepted
    finally:
        temporary.cleanup()


def test_plain_tail_remains_display_only_when_durable_progress_is_withheld() -> None:
    """Entering a stage with no durable receipt must not block tail mapping.

    A plain newest assistant tail is only a locator.  It must still map the
    current task while the contract's durable visible-progress receipt is
    withheld; the observation cannot authorize an action or mutate the
    contract.  This covers the Stage 10 transition window where the next
    checkpoint has not been published yet.
    """

    temporary, state_root, memory_root, host_root, contract_path = _fixture()
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        contract.pop("visibleProgressReceipt", None)
        contract_path.write_text(json.dumps(contract), encoding="utf-8")
        before_contract = contract_path.read_bytes()
        with fixture.with_host_scope(host_root, THREAD_ID):
            result = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion=_plain_observation(),
            )

        assert result["available"] is True, result
        tail = result["visibleTailAssertion"]
        assert tail["continuationRole"] == "display_only", tail
        assert tail["nonAuthorizing"] is True, tail
        mapping = _continuity_mapping(result)
        assert mapping["visibleProgressState"] == "withheld", mapping
        assert mapping["formalActionAllowed"] is False, mapping
        assert mapping["stageAdvanceAllowed"] is False, mapping
        observation = result["context"]["visibleProgressObservation"]
        assert observation["continuationRole"] == "display_only", observation
        assert observation["visibleProgressReceiptHash"] == "", observation
        assert observation["sentenceHash"] == "", observation
        assert observation["displaySentenceHash"] == hashlib.sha256(PLAIN_TAIL.encode("utf-8")).hexdigest(), observation
        assert contract_path.read_bytes() == before_contract
    finally:
        temporary.cleanup()


def test_every_same_workline_turn_requires_the_current_visible_locator() -> None:
    """No cache, receipt, or same-process state may bypass the latest tail.

    This is the direct regression for the former internal lease route.  A
    strict v4 observation, a later plain observation, and even a rejected
    mismatched v4 observation must all leave the next no-observation turn
    withheld.  That prevents an old durable point from quietly resuming after
    the user has already seen something newer.
    """

    temporary, _state_root, memory_root, host_root, contract_path = _fixture()
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        before_contract = contract_path.read_bytes()
        durable = _durable_observation(contract)
        mismatched = _durable_observation(
            contract,
            sentence="A newer mismatched v4 sentence must not revive old progress.",
        )
        with fixture.with_host_scope(host_root, THREAD_ID):
            opened = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion=durable,
            )
            missing_after_durable = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
            )
            plain = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion=_plain_observation(),
            )
            missing_after_plain = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
            )
            rejected = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion=mismatched,
            )
            missing_after_mismatch = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
            )
            missing_boundaries = {
                event: run_turn(
                    BrainCore(PACKAGE_ROOT, memory_root),
                    phase="open",
                    turn_intent="continuity",
                    recovery_event=event,
                )
                for event in ("compaction", "pause_resume", "restart", "model_switch", "cross_session", "user_correction")
            }

        assert opened["available"] is True, opened
        assert plain["available"] is True, plain
        assert plain["visibleTailAssertion"]["continuationRole"] == "display_only", plain
        assert rejected["available"] is False, rejected
        assert rejected["code"] == "H7_VISIBLE_TAIL_ASSERTION_MISMATCH", rejected
        for result in (missing_after_durable, missing_after_plain, missing_after_mismatch, *missing_boundaries.values()):
            assert result["available"] is False, result
            assert result["code"] == "H7_VISIBLE_TAIL_ASSERTION_REQUIRED", result
        assert contract_path.read_bytes() == before_contract
    finally:
        temporary.cleanup()


def test_continuity_mapping_current_tail_maps_unique_active_task_before_action_claim() -> None:
    """The newest visible reply locates the line; H7 maps real task facts.

    The text is deliberately ordinary prose, so it may not smuggle a phase or
    next action into H7.  The runtime must instead expose the unique active
    task and its live project proof from the scoped contract.  This is the
    user-visible distinction between knowing *where to resume* and knowing
    *what actually remains to do*.
    """

    temporary, _state_root, memory_root, host_root, contract_path = _fixture()
    try:
        before = json.loads(contract_path.read_text(encoding="utf-8"))
        observed = observe_visible_context_message(
            host_thread_id=THREAD_ID,
            turn_id="turn-r6-map-current",
            message_id="message-r6-map-current",
            phase="commentary",
            text="The latest reply only locates the active workline; verify the real task state next.",
        )
        assert observed["ok"] is True, observed
        assert observed["selection"] == "current_visible_assistant", observed
        with fixture.with_host_scope(host_root, THREAD_ID):
            result = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion={key: value for key, value in observed.items() if key != "ok"},
            )

        assert result["available"] is True, result
        mapping = _continuity_mapping(result)
        assert mapping["state"] == "mapped_current_workline", mapping
        assert mapping["source"] == "current_visible_assistant", mapping
        assert mapping["visibleContextAvailable"] is True, mapping
        assert mapping["stateCardUsed"] is False, mapping
        assert mapping["taskIdHash"] == hashlib.sha256(before["taskId"].encode("utf-8")).hexdigest(), mapping
        assert mapping["taskInstanceId"] == before["taskInstanceId"], mapping
        assert mapping["contractRevision"] == before["revision"], mapping
        assert mapping["contractHash"], mapping
        assert mapping["currentPhase"] == before["currentPhase"], mapping
        assert mapping["currentStep"] == before["currentStep"], mapping
        assert mapping["nextAction"] == before["nextAction"], mapping
        assert mapping["projectProofState"] == "current", mapping
        assert mapping["visibleProgressState"] == "current", mapping
        assert mapping["formalActionAllowed"] is False, mapping
        assert mapping["duplicateActionPrevented"] is True, mapping
        # The tail is a location signal only.  The task/phase/step/action must
        # come from the uniquely mapped contract, never from ordinary prose.
        task = result["context"]["task"]
        assert task["taskId"] == before["taskId"], task
        assert task["currentPhase"] == before["currentPhase"], task
        assert task["currentStep"] == before["currentStep"], task
        assert task["nextAction"] == before["nextAction"], task
        assert task["projectProgress"]["state"] == "current", task
        assert result["visibleTailAssertion"]["continuationRole"] == "display_only", result
        assert json.loads(contract_path.read_text(encoding="utf-8")) == before
    finally:
        temporary.cleanup()


def test_continuity_mapping_stale_proof_prevents_repeat_or_advance() -> None:
    """A drift repair starts from live task/proof facts, not an old action.

    The current visible tail remains the continuation location.  Once H7 sees
    that current project evidence is stale, it may present the mapped task for
    diagnosis, but it must not mutate the contract, advance a stage, or replay
    the old next action merely because a stale state card says one exists.
    """

    temporary, _state_root, memory_root, host_root, contract_path = _fixture()
    try:
        before_bytes = contract_path.read_bytes()
        before = json.loads(before_bytes)
        # Invalidate the exact proof file after the contract/receipt was made.
        (host_root / "project-progress-evidence.txt").write_text("proof changed after the old receipt\n", encoding="utf-8")
        observed = observe_visible_context_message(
            host_thread_id=THREAD_ID,
            turn_id="turn-r6-stale-proof",
            message_id="message-r6-stale-proof",
            phase="commentary",
            text="Read the current task and project state before retrying any previous action.",
        )
        assert observed["ok"] is True, observed
        with fixture.with_host_scope(host_root, THREAD_ID):
            result = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion={key: value for key, value in observed.items() if key != "ok"},
            )

        assert result["available"] is True, result
        mapping = _continuity_mapping(result)
        assert mapping["state"] == "mapped_current_workline", mapping
        assert mapping["source"] == "current_visible_assistant", mapping
        assert mapping["visibleContextAvailable"] is True, mapping
        assert mapping["stateCardUsed"] is False, mapping
        assert mapping["taskIdHash"] == hashlib.sha256(before["taskId"].encode("utf-8")).hexdigest(), mapping
        assert mapping["taskInstanceId"] == before["taskInstanceId"], mapping
        assert mapping["contractRevision"] == before["revision"], mapping
        assert mapping["contractHash"], mapping
        assert mapping["currentPhase"] == before["currentPhase"], mapping
        assert mapping["currentStep"] == before["currentStep"], mapping
        assert mapping["nextAction"] == before["nextAction"], mapping
        assert mapping["projectProofState"] == "withheld", mapping
        assert mapping["visibleProgressState"] == "withheld", mapping
        assert mapping["formalActionAllowed"] is False, mapping
        assert mapping["duplicateActionPrevented"] is True, mapping
        task = result["context"]["task"]
        assert task["taskId"] == before["taskId"], task
        assert task["projectProgress"]["state"] == "withheld", task
        assert "project_evidence_hash" in task["projectProgress"]["missing"], task
        assert result["runtimeReceipt"]["progressTruth"]["state"] == "withheld", result
        assert contract_path.read_bytes() == before_bytes
    finally:
        temporary.cleanup()


def test_continuity_mapping_ordinary_no_task_never_creates_runtime_state() -> None:
    """Ordinary no-task prose stays card-free; state cards are not a fallback."""

    temporary = tempfile.TemporaryDirectory(prefix="super-brain-r6-no-task-")
    try:
        root = Path(temporary.name)
        state_root = root / "state"
        memory_root = state_root / "shared"
        host_root = root / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        before = _tree_bytes(state_root)
        with fixture.with_host_scope(host_root, THREAD_ID):
            direct = run_turn(BrainCore(PACKAGE_ROOT, memory_root), phase="open", turn_intent="greeting")
            missing_task = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion=_plain_observation(),
            )

        assert direct["code"] == "TURN_INTENT_DIRECT_HOST_PATH", direct
        direct_mapping = _continuity_mapping(direct)
        assert direct_mapping["state"] == "ordinary_no_task", direct_mapping
        assert direct_mapping["source"] == "none", direct_mapping
        assert direct_mapping["visibleContextAvailable"] is False, direct_mapping
        assert direct_mapping["stateCardUsed"] is False, direct_mapping
        assert direct_mapping["taskIdHash"] == "", direct_mapping
        assert direct_mapping["taskInstanceId"] == "", direct_mapping
        assert direct_mapping["contractRevision"] == 0, direct_mapping
        assert direct_mapping["contractHash"] == "", direct_mapping
        assert direct_mapping["currentPhase"] == "", direct_mapping
        assert direct_mapping["currentStep"] == "", direct_mapping
        assert direct_mapping["nextAction"] == "", direct_mapping
        assert direct_mapping["projectProofState"] == "not_applicable", direct_mapping
        assert direct_mapping["visibleProgressState"] == "not_applicable", direct_mapping
        assert direct_mapping["formalActionAllowed"] is False, direct_mapping
        assert direct_mapping["duplicateActionPrevented"] is True, direct_mapping
        # A governed "continue" with no active scoped task is still an
        # ordinary no-task turn.  It must not turn absence into a fake repair
        # task, scan stale contracts, or allocate a task/state card.
        missing_mapping = _continuity_mapping(missing_task)
        assert missing_mapping["state"] == "ordinary_no_task", missing_mapping
        assert missing_mapping["source"] == "current_visible_assistant", missing_mapping
        assert missing_mapping["visibleContextAvailable"] is True, missing_mapping
        assert missing_mapping["stateCardUsed"] is False, missing_mapping
        assert missing_mapping["taskIdHash"] == "", missing_mapping
        assert missing_mapping["taskInstanceId"] == "", missing_mapping
        assert missing_mapping["contractRevision"] == 0, missing_mapping
        assert missing_mapping["contractHash"] == "", missing_mapping
        assert missing_mapping["currentPhase"] == "", missing_mapping
        assert missing_mapping["currentStep"] == "", missing_mapping
        assert missing_mapping["nextAction"] == "", missing_mapping
        assert missing_mapping["projectProofState"] == "not_applicable", missing_mapping
        assert missing_mapping["visibleProgressState"] == "not_applicable", missing_mapping
        assert missing_mapping["formalActionAllowed"] is False, missing_mapping
        assert missing_mapping["duplicateActionPrevented"] is True, missing_mapping
        assert _tree_bytes(state_root) == before
    finally:
        temporary.cleanup()


def test_continuity_mapping_state_card_is_not_a_same_workline_fallback() -> None:
    """Only a verified parent return may select a state card over the tail."""

    temporary, state_root, memory_root, host_root, contract_path = _fixture()
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        # A same-workline card is deliberately made attractive but wrong.  A
        # normal open must still take the current visible tail and ignore it.
        contract["continuityStateCard"] = {
            "activeLineId": str(contract["focusId"]),
            "phase": "Wrong card phase",
            "currentStep": "Wrong card step",
            "nextAction": "Repeat a stale action",
            "lastConfirmedSentence": "Wrong card sentence",
            "lastConfirmedSource": "assistant_visible_reply",
        }
        fixture.write_json(contract_path, contract)
        observed = _plain_observation()
        with fixture.with_host_scope(host_root, THREAD_ID):
            same_line = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="none",
                visible_progress_assertion=observed,
            )

        assert same_line["available"] is True, same_line
        mapping = _continuity_mapping(same_line)
        assert mapping["state"] == "mapped_current_workline", mapping
        assert mapping["source"] == "current_visible_assistant", mapping
        assert mapping["visibleContextAvailable"] is True, mapping
        assert mapping["stateCardUsed"] is False, mapping
        assert same_line["visibleTailAssertion"]["selection"] == "current_visible_assistant", same_line
        task = same_line["context"]["task"]
        assert task["currentPhase"] != "Wrong card phase", task
        assert task["currentStep"] != "Wrong card step", task
        assert task["nextAction"] != "Repeat a stale action", task
        assert "parentReturnStateCard" not in same_line["context"], same_line

        # The state card becomes selectable only after the contract records a
        # real ResumeParent transition.  A forged/mismatched card is rejected
        # rather than becoming a general fallback for lost visible context.
        with fixture.with_host_scope(host_root, THREAD_ID):
            forged_parent = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="parent_return",
            )
        assert forged_parent["available"] is False, forged_parent
        assert forged_parent["code"] == "H7_PARENT_RETURN_STATE_CARD_REQUIRED", forged_parent
        assert _tree_bytes(state_root)[str(contract_path.relative_to(state_root)).replace("\\", "/")] == contract_path.read_bytes()
    finally:
        temporary.cleanup()


def test_continuity_mapping_verified_parent_return_uses_state_card() -> None:
    """The one exception is an actual ResumeParent transition, never a guess."""

    temporary = tempfile.TemporaryDirectory(prefix="super-brain-r6-parent-map-")
    try:
        root = Path(temporary.name)
        state_root = root / "state"
        memory_root = state_root / "shared"
        host_root = root / "host"
        memory_root.mkdir(parents=True)
        host_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        fixture.write_native_memory_snapshot(state_root / "workspace")
        session_key = "sid-" + "3" * 24
        workspace_key = fixture.host_workspace_key(host_root)
        task_id = "task-r6-parent-mapping"
        evidence_path = host_root / "parent-map-evidence.txt"
        evidence_path.write_text("parent map proof\n", encoding="utf-8")
        evidence = {"kind": "project_file", "relativePath": evidence_path.name, "sha256": fixture.file_sha256(evidence_path)}

        def encode(value: dict[str, object]) -> str:
            return base64.b64encode(
                json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            ).decode("ascii")

        parent_checkpoint = {
            "last_confirmed_sentence": "The parent workline is ready after the side branch.",
            "source": "assistant_visible_reply",
            "current_phase": "Parent stage",
            "current_step": "Verify the parent result.",
            "next_action": "Run the parent acceptance replay.",
        }
        parent_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": parent_checkpoint["current_phase"],
            "currentStep": parent_checkpoint["current_step"],
            "completedItems": [],
            "projectEvidence": [evidence],
            "verificationResults": [],
            "nextAction": parent_checkpoint["next_action"],
        }
        parent = fixture.invoke_contract([
            "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
            "-FocusId", "parent-line", "-FocusLabel", "Parent line", "-InstructionMode", "continue",
            "-LatestUserInstruction", "continue parent", "-CurrentPhase", parent_checkpoint["current_phase"],
            "-CurrentStep", parent_checkpoint["current_step"], "-LastConfirmedSentence", parent_checkpoint["last_confirmed_sentence"],
            "-LastConfirmedSource", "assistant_commitment", "-NextAction", parent_checkpoint["next_action"],
            "-PendingSteps", parent_checkpoint["next_action"], "-ProjectRoot", str(host_root),
            "-ProjectProgressProofBase64", encode(parent_proof), "-ProgressCheckpointBase64", encode(parent_checkpoint),
            "-TransitionId", "r6-parent-map-seed", "-StateRoot", str(state_root), "-Json",
        ])
        side_checkpoint = {
            "last_confirmed_sentence": "The side branch is complete.",
            "source": "assistant_visible_reply",
            "current_phase": "Side stage",
            "current_step": "Complete the bounded side task.",
            "next_action": "Return to parent.",
        }
        side_proof = {
            "schema": "super-brain.project-progress-input.v1",
            "phase": side_checkpoint["current_phase"], "currentStep": side_checkpoint["current_step"],
            "completedItems": [], "projectEvidence": [evidence], "verificationResults": [],
            "nextAction": side_checkpoint["next_action"],
        }
        fixture.invoke_contract([
            "-Action", "Set", "-TaskId", task_id, "-WorkspaceKey", workspace_key, "-SessionKey", session_key,
            "-FocusId", "side-line", "-FocusLabel", "Side line", "-InstructionMode", "side_branch",
            "-LatestUserInstruction", "do side then return", "-CurrentPhase", side_checkpoint["current_phase"],
            "-CurrentStep", side_checkpoint["current_step"], "-LastConfirmedSentence", side_checkpoint["last_confirmed_sentence"],
            "-LastConfirmedSource", "assistant_commitment", "-NextAction", side_checkpoint["next_action"],
            "-PendingSteps", side_checkpoint["next_action"], "-ExpectedRevision", str(parent["revision"]),
            "-ExpectedPlanFingerprint", str(parent["planReceipt"]["planFingerprint"]), "-ProjectRoot", str(host_root),
            "-ProjectProgressProofBase64", encode(side_proof), "-ProgressCheckpointBase64", encode(side_checkpoint),
            "-TransitionId", "r6-parent-map-side", "-StateRoot", str(state_root), "-Json",
        ])
        core = BrainCore(PACKAGE_ROOT, memory_root)
        with fixture.with_host_scope(host_root, session_key):
            closed = run_turn(
                core, phase="close", turn_outcome="side_branch_completed", user_control="none",
                completion_evidence_ref="side branch acceptance passed", transition_id="r6-parent-map-close",
            )
            recovered = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root), phase="open", turn_intent="continuity", recovery_event="parent_return",
            )

        assert closed["transition"]["action"] == "ResumeParent", closed
        assert recovered["available"] is True, recovered
        mapping = _continuity_mapping(recovered)
        assert mapping["state"] == "mapped_parent_return", mapping
        assert mapping["source"] == "verified_parent_return", mapping
        assert mapping["visibleContextAvailable"] is False, mapping
        assert mapping["stateCardUsed"] is True, mapping
        assert mapping["taskIdHash"] == hashlib.sha256(task_id.encode("utf-8")).hexdigest(), mapping
        assert mapping["currentPhase"] == parent_checkpoint["current_phase"], mapping
        assert mapping["currentStep"] == parent_checkpoint["current_step"], mapping
        assert mapping["nextAction"] == parent_checkpoint["next_action"], mapping
        assert mapping["projectProofState"] == "current", mapping
        assert mapping["visibleProgressState"] == "current", mapping
        assert mapping["formalActionAllowed"] is False, mapping
        assert mapping["duplicateActionPrevented"] is True, mapping
    finally:
        temporary.cleanup()


def continuity_mapping_contract_main() -> int:
    """Run only the tail-first public-contract cases after runtime exposure."""

    test_continuity_mapping_current_tail_maps_unique_active_task_before_action_claim()
    test_continuity_mapping_stale_proof_prevents_repeat_or_advance()
    test_continuity_mapping_ordinary_no_task_never_creates_runtime_state()
    test_continuity_mapping_state_card_is_not_a_same_workline_fallback()
    test_continuity_mapping_verified_parent_return_uses_state_card()
    print("runtime R6 continuityMapping contract: passed (5/5)")
    return 0


def _legacy_main() -> int:
    """Run the complete R6 dynamic continuation regression gate."""

    test_normal_same_workline_plain_tail_is_display_only_and_contract_unchanged()
    test_raw_helper_observation_unwraps_once_but_bad_wrappers_fail_closed()
    test_plain_tail_remains_display_only_when_durable_progress_is_withheld()
    test_every_same_workline_turn_requires_the_current_visible_locator()
    test_continuity_mapping_current_tail_maps_unique_active_task_before_action_claim()
    test_continuity_mapping_stale_proof_prevents_repeat_or_advance()
    test_continuity_mapping_ordinary_no_task_never_creates_runtime_state()
    test_continuity_mapping_state_card_is_not_a_same_workline_fallback()
    test_continuity_mapping_verified_parent_return_uses_state_card()
    test_boundary_recovery_keeps_same_plain_tail_display_only_without_contract_write()
    test_legacy_current_tail_is_display_only_but_mismatched_v4_stays_fail_closed()
    test_bridge_uses_distinct_normal_strict_and_drift_paths()
    test_boundary_v4_prefix_with_later_display_prose_remains_exact_anchor()
    print("runtime R6 dynamic continuation regression: passed (13/13)")
    return 0


def test_boundary_recovery_keeps_same_plain_tail_display_only_without_contract_write() -> None:
    for event in ("compaction", "pause_resume", "restart", "model_switch", "cross_session", "user_correction"):
        temporary, state_root, memory_root, host_root, _contract_path = _fixture()
        try:
            before = _tree_bytes(state_root)
            with fixture.with_host_scope(host_root, THREAD_ID):
                result = run_turn(
                    BrainCore(PACKAGE_ROOT, memory_root),
                    phase="open",
                    turn_intent="continuity",
                    recovery_event=event,
                    visible_progress_assertion=_plain_observation(),
                )
            assert result["available"] is True, (event, result)
            tail = result["visibleTailAssertion"]
            assert tail["state"] == "observed_display_only", (event, tail)
            assert tail["continuationRole"] == "display_only", (event, tail)
            presentation = result["recoveryPresentation"]
            # A true boundary must visibly acknowledge the newest actual
            # assistant message.  Plain text is not promoted: the explicit
            # non-authorizing projection prevents it from replacing durable
            # H7 progress, the contract phase, proof, or next action.
            assert presentation["state"] == "display_only", (event, presentation)
            assert presentation["code"] == "H7_RECOVERY_PRESENTATION_DISPLAY_ONLY_CURRENT", (event, presentation)
            assert presentation["event"] == event, (event, presentation)
            assert presentation["required"] is True, (event, presentation)
            assert presentation["nonAuthorizing"] is True, (event, presentation)
            assert presentation["openingLine"] == "已接上：" + PLAIN_TAIL, (event, presentation)
            # The readback card is the only permitted durable effect; the
            # authoritative contract itself must not be changed by plain
            # visible prose at a compaction/restart/pause boundary.
            after = _tree_bytes(state_root)
            contract_path = _contract_path
            assert after[str(contract_path.relative_to(state_root)).replace("\\", "/")] == before[str(contract_path.relative_to(state_root)).replace("\\", "/")], event
        finally:
            temporary.cleanup()


def test_legacy_current_tail_is_display_only_but_mismatched_v4_stays_fail_closed() -> None:
    temporary, state_root, memory_root, host_root, contract_path = _fixture()
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        legacy_inputs = {
            "loose_g1": observe_visible_context_message(
                host_thread_id=THREAD_ID,
                turn_id="turn-r6-loose",
                message_id="message-r6-loose",
                phase="commentary",
                text="G1\nThis looks like progress but has no v4 receipt binding.",
            ),
            "legacy_recovery": observe_visible_context_message(
                host_thread_id=THREAD_ID,
                turn_id="turn-r6-legacy",
                message_id="message-r6-legacy",
                phase="commentary",
                text="已接上：A legacy recovery line cannot be a durable anchor.",
            ),
        }
        for name, observed in legacy_inputs.items():
            assert observed.get("ok", True) is True, (name, observed)
            assert observed["selection"] == "current_visible_assistant", (name, observed)
            assert observed["publication_kind"] == "legacy_h7_progress_withheld", (name, observed)
            assert observed["envelope_version"] == "legacy_v3", (name, observed)
            assertion = {key: value for key, value in observed.items() if key != "ok"}
            before_contract = contract_path.read_bytes()
            with fixture.with_host_scope(host_root, THREAD_ID):
                result = run_turn(
                    BrainCore(PACKAGE_ROOT, memory_root),
                    phase="open",
                    turn_intent="continuity",
                    recovery_event="restart",
                    visible_progress_assertion=assertion,
                )
            assert result["available"] is True, (name, result)
            tail = result["visibleTailAssertion"]
            assert tail["continuationRole"] == "display_only", (name, tail)
            assert tail["publicationKind"] == "legacy_h7_progress_withheld", (name, tail)
            assert tail["envelopeVersion"] == "legacy_v3", (name, tail)
            assert tail["h7ReceiptHash"] == "", (name, tail)
            presentation = result["recoveryPresentation"]
            assert presentation["state"] == "display_only", (name, presentation)
            assert presentation["nonAuthorizing"] is True, (name, presentation)
            assert contract_path.read_bytes() == before_contract, name

        mismatch = _durable_observation(
            contract,
            sentence="A newer durable-looking sentence must not mutate the current contract.",
        )
        before_contract = contract_path.read_bytes()
        before_state = _tree_bytes(state_root)
        with fixture.with_host_scope(host_root, THREAD_ID):
            result = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="restart",
                visible_progress_assertion=mismatch,
            )
        assert result["available"] is False, result
        assert result["code"] == "H7_VISIBLE_TAIL_ASSERTION_MISMATCH", result
        assert contract_path.read_bytes() == before_contract
        assert _tree_bytes(state_root) == before_state
    finally:
        temporary.cleanup()


def test_bridge_uses_distinct_normal_strict_and_drift_paths() -> None:
    receipt = "c" * 64

    def plain_reader(**_kwargs: object) -> dict[str, object]:
        return {
            "thread": {"id": THREAD_ID},
            "page": {"order": "newest_first"},
            "turns": [{"id": "turn-r6-bridge", "items": [{
                "type": "agentMessage", "id": "message-r6-plain", "phase": "commentary", "text": PLAIN_TAIL,
            }]}],
        }

    normal = observe_current_thread(plain_reader, purpose=PURPOSE_NORMAL_SAME_WORKLINE)
    strict = observe_current_thread(plain_reader, purpose=PURPOSE_STRICT_RECOVERY)
    drift = observe_current_thread(plain_reader, purpose=PURPOSE_DRIFT_DIAGNOSIS)
    assert normal["ok"] is True and normal["observation"]["selection"] == "current_visible_assistant", normal
    assert normal["observation"]["publication_kind"] == "unclassified_assistant_reply", normal
    # A recovery boundary reads the same newest visible assistant reply as an
    # uninterrupted continuation.  v4 is a later classification of that one
    # candidate, not a second selector that walks backward to an older
    # receipt or rejects ordinary current prose before task mapping.
    assert strict["ok"] is True and strict["observation"]["selection"] == "current_visible_assistant", strict
    assert strict["observation"]["publication_kind"] == "unclassified_assistant_reply", strict
    assert drift["ok"] is True and drift["observation"]["selection"] == "latest_assistant", drift

    def durable_reader(**_kwargs: object) -> dict[str, object]:
        return {
            "thread": {"id": THREAD_ID},
            "page": {"order": "newest_first"},
            "turns": [{"id": "turn-r6-bridge", "items": [{
                "type": "agentMessage", "id": "message-r6-v4", "phase": "commentary",
                "text": f"G1\n[H7-PROGRESS-V4 receipt_hash={receipt}]\nR6 bridge v4 path is exact.",
            }]}],
        }

    strict_v4 = observe_current_thread(durable_reader, purpose=PURPOSE_STRICT_RECOVERY)
    assert strict_v4["ok"] is True, strict_v4
    assert strict_v4["observation"]["selection"] == "current_visible_assistant", strict_v4
    assert strict_v4["observation"]["h7_receipt_hash"] == receipt, strict_v4


def test_boundary_v4_prefix_with_later_display_prose_remains_exact_anchor() -> None:
    temporary, _state_root, memory_root, host_root, contract_path = _fixture()
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        sentence = str(contract["lastConfirmedSentence"])
        receipt_hash = str((contract.get("visibleProgressReceipt") or {}).get("payloadHash", ""))
        observed = observe_visible_context_message(
            host_thread_id=THREAD_ID,
            turn_id="turn-r6-v4-prefix",
            message_id="message-r6-v4-prefix",
            phase="commentary",
            text=(
                f"G1\n[H7-PROGRESS-V4 receipt_hash={receipt_hash}]\n{sentence}"
                "\nEvidence: later display-only detail.\nNext: continue the verified action."
            ),
        )
        assert observed["ok"] is True, observed
        assert observed["selection"] == "current_visible_assistant", observed
        assert observed["publication_kind"] == "h7_durable_progress", observed
        assert observed["last_confirmed_sentence"] == sentence, observed
        with fixture.with_host_scope(host_root, THREAD_ID):
            result = run_turn(
                BrainCore(PACKAGE_ROOT, memory_root),
                phase="open",
                turn_intent="continuity",
                recovery_event="restart",
                visible_progress_assertion={key: value for key, value in observed.items() if key != "ok"},
            )
        assert result["available"] is True, result
        assert result["visibleTailAssertion"]["continuationRole"] == "durable_anchor", result
        presentation = result["recoveryPresentation"]
        assert presentation["state"] == "current", presentation
        assert presentation["nonAuthorizing"] is False, presentation
        assert presentation["openingLine"] == "已接上：" + sentence, presentation
    finally:
        temporary.cleanup()


def main() -> int:
    return _legacy_main()


if __name__ == "__main__":
    raise SystemExit(
        continuity_mapping_contract_main() if "--continuity-mapping-contract" in sys.argv else main()
    )
