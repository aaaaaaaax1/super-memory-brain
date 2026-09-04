"""Hookless H7 lifecycle regression coverage.

The former prompt/stop Hook implementation is retired. This file keeps only
the compatibility no-op checks and exercises the current lifecycle through the
native runtime, the CLI transport, and the MCP-equivalent CLI bridge.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime"
CLI = RUNTIME / "brain_cli.py"
DISPATCHER = RUNTIME / "codex_prompt_hook_dispatcher.py"
sys.path.insert(0, str(RUNTIME))

from brain_context import canonical_hash, project_progress_root_hash, visible_progress_scope_binding_hash
from brain_core import BrainCore
from turn_runtime import run_turn


def _package_version() -> str:
    return str(json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["version"])


def _workspace_key(project_root: Path) -> str:
    normalized = os.path.abspath(str(project_root)).rstrip("/\\").lower()
    return "ws-" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:24]


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )


def _seed_h7_scope(state_root: Path, project_root: Path, session_key: str) -> dict[str, str]:
    """Create one current contract and its derived pointer in isolated state."""

    workspace_key = _workspace_key(project_root)
    task_id = "task-hookless-h7"
    task_instance_id = "instance-hookless-h7"
    phase = "verification"
    current_step = "Open the current H7 turn."
    next_action = "Read current H7 evidence."
    sentence = "The hookless H7 fixture is ready."
    evidence_path = project_root / "h7-progress-evidence.txt"
    evidence_path.write_text("hookless H7 progress evidence\n", encoding="utf-8")
    evidence = {
        "kind": "project_file",
        "relativePath": evidence_path.name,
        "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest(),
    }
    proof_body: dict[str, object] = {
        "schema": "super-brain.project-progress-proof.v1",
        "state": "current",
        "phase": phase,
        "currentStep": current_step,
        "completedItems": [],
        "projectEvidence": [evidence],
        "verificationResults": [],
        "nextAction": next_action,
        "missing": [],
        "projectRootHash": project_progress_root_hash(project_root),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    proof = {**proof_body, "payloadHash": canonical_hash(proof_body)}
    scope_binding = visible_progress_scope_binding_hash(
        task_id=task_id,
        task_instance_id=task_instance_id,
        workspace_key=workspace_key,
        owner_session_key=session_key,
        package_version=_package_version(),
    )
    receipt_body = {
        "schema": "super-brain.visible-progress-receipt.v1",
        "source": "assistant_visible_reply",
        "sentenceHash": hashlib.sha256(sentence.encode("utf-8")).hexdigest(),
        "currentPhase": phase,
        "currentStep": current_step,
        "nextAction": next_action,
        "projectProgressPayloadHash": proof["payloadHash"],
        "scopeBindingHash": scope_binding,
        "transitionId": "hookless-h7-fixture",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    receipt = {**receipt_body, "payloadHash": canonical_hash(receipt_body)}
    contract_name = f"{task_id}--{workspace_key}.json"
    contract = {
        "ok": True,
        "schema": "super-brain.execution-contract.v1",
        "taskId": task_id,
        "taskInstanceId": task_instance_id,
        "workspaceKey": workspace_key,
        "ownerSessionKey": session_key,
        "packageVersion": _package_version(),
        "status": "active",
        "revision": 7,
        "focusId": "hookless-h7",
        "focusLabel": "Hookless H7 fixture",
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
            "focusId": "hookless-h7",
            "contractRevision": 7,
            "planFingerprint": "hookless-h7-plan",
        },
        "instructionAnchor": {"contentHash": "a" * 64},
        "recoveryCheckpoint": {"checkpointId": "hookless-h7-checkpoint", "stateHash": "b" * 64},
        "projectProgressProof": proof,
        "visibleProgressReceipt": receipt,
        "updatedAt": "2026-09-01T00:00:00Z",
    }
    _write_json(
        state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_name,
        contract,
    )
    _write_json(
        state_root / "workspace" / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
        {
            "schema": "super-brain.execution-hot-index.v1",
            "packageVersion": _package_version(),
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "entries": [
                {
                    "taskId": task_id,
                    "taskInstanceId": task_instance_id,
                    "workspaceKey": workspace_key,
                    "ownerSessionKey": session_key,
                    "packageVersion": _package_version(),
                    "revision": 7,
                    "status": "active",
                    "updatedAt": "2026-09-01T00:00:00Z",
                    "contractFileName": contract_name,
                }
            ],
        },
    )
    return {
        "task_id": task_id,
        "workspace_key": workspace_key,
        "session_key": session_key,
    }


@contextmanager
def _local_scope(project_root: Path, state_root: Path, session_key: str) -> Iterator[None]:
    previous_cwd = Path.cwd()
    previous_state = os.environ.get("SUPER_BRAIN_STATE_ROOT")
    previous_session = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
    previous_workspace = os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
    os.environ["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
    os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = session_key
    os.chdir(project_root)
    try:
        yield
    finally:
        os.chdir(previous_cwd)
        if previous_state is None:
            os.environ.pop("SUPER_BRAIN_STATE_ROOT", None)
        else:
            os.environ["SUPER_BRAIN_STATE_ROOT"] = previous_state
        if previous_session is None:
            os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
        else:
            os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_session
        if previous_workspace is not None:
            os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace


def _run_cli(
    state_root: Path,
    project_root: Path,
    session_key: str,
    *arguments: str,
    input_value: bytes | None = None,
) -> dict[str, object]:
    environment = os.environ.copy()
    environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
    environment["SUPER_BRAIN_LOCAL_SESSION_ID"] = session_key
    environment.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
    completed = subprocess.run(
        [
            sys.executable,
            "-X",
            "utf8",
            str(CLI),
            "--package-root",
            str(ROOT),
            "--memory-root",
            str(state_root / "shared"),
            *arguments,
        ],
        cwd=project_root,
        env=environment,
        input=input_value,
        capture_output=True,
        check=False,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stderr.decode("utf-8", errors="replace")
    try:
        value = json.loads(completed.stdout.decode("utf-8"))
    except json.JSONDecodeError as error:
        raise AssertionError(completed.stdout.decode("utf-8", errors="replace")) from error
    assert isinstance(value, dict)
    return value


def test_retired_dispatcher_declares_h7_replacement() -> None:
    completed = subprocess.run(
        [sys.executable, str(DISPATCHER), "--describe"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    )
    assert json.loads(completed.stdout) == {
        "ok": True,
        "state": "retired",
        "replacement": "H7 brain_turn",
    }


def test_retired_dispatcher_is_a_noop_with_no_state_side_effects() -> None:
    with tempfile.TemporaryDirectory(prefix="h7-retired-dispatcher-") as directory:
        state_root = Path(directory) / "state"
        environment = os.environ.copy()
        environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
        completed = subprocess.run(
            [sys.executable, str(DISPATCHER)],
            input=b'{"legacy_payload":"ignored"}',
            capture_output=True,
            env=environment,
            check=True,
        )
        assert json.loads(completed.stdout.decode("utf-8")) == {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": "",
            }
        }
        assert not state_root.exists()


def test_h7_native_turn_runtime_uses_current_scope_and_recovery_presentation() -> None:
    with tempfile.TemporaryDirectory(prefix="h7-native-turn-runtime-") as directory:
        root = Path(directory)
        state_root = root / "state"
        project_root = root / "project"
        project_root.mkdir()
        session_key = "sid-" + "a" * 24
        scope = _seed_h7_scope(state_root, project_root, session_key)
        with _local_scope(project_root, state_root, session_key):
            result = run_turn(
                BrainCore(ROOT, state_root / "shared"),
                phase="open",
                recovery_event="compaction",
                turn_intent="continuity",
            )
        assert result["available"] is True, result
        assert result["code"] == "TURN_RUNTIME_OPEN_READY", result
        assert result["mode"] == "hookless_turn_runtime", result
        assert result["context"]["scope"]["workspaceKey"] == scope["workspace_key"], result
        assert result["context"]["scope"]["ownerSessionKey"] == session_key, result
        assert result["recoveryPresentation"]["openingLine"].startswith("本地执行契约：进度："), result
        assert result["rawPromptStored"] is False
        assert result["rawTranscriptStored"] is False


def test_h7_cli_turn_runtime_reads_cwd_and_local_session_only() -> None:
    with tempfile.TemporaryDirectory(prefix="h7-cli-turn-runtime-") as directory:
        root = Path(directory)
        state_root = root / "state"
        project_root = root / "project"
        project_root.mkdir()
        session_key = "sid-" + "b" * 24
        scope = _seed_h7_scope(state_root, project_root, session_key)
        result = _run_cli(
            state_root,
            project_root,
            session_key,
            "turn-runtime",
            "--phase",
            "open",
            "--recovery-event",
            "restart",
            "--turn-intent",
            "continuity",
        )
        assert result["available"] is True, result
        assert result["code"] == "TURN_RUNTIME_OPEN_READY", result
        assert result["context"]["scope"]["workspaceKey"] == scope["workspace_key"], result
        assert result["context"]["scope"]["ownerSessionKey"] == session_key, result
        assert result["recoveryPresentation"]["openingLine"].startswith("本地执行契约：进度："), result


def test_h7_mcp_equivalent_bridge_reaches_the_same_runtime() -> None:
    with tempfile.TemporaryDirectory(prefix="h7-mcp-bridge-") as directory:
        root = Path(directory)
        state_root = root / "state"
        project_root = root / "project"
        project_root.mkdir()
        session_key = "sid-" + "c" * 24
        scope = _seed_h7_scope(state_root, project_root, session_key)
        request = {
            "schema": "super-brain.mcp-cli-bridge-request.v1",
            "name": "brain_turn",
            "arguments": {
                "phase": "open",
                "recovery_event": "model_switch",
                "turn_intent": "continuity",
            },
        }
        result = _run_cli(
            state_root,
            project_root,
            session_key,
            "--workspace-root",
            str(project_root),
            "mcp-bridge",
            input_value=json.dumps(request, separators=(",", ":")).encode("utf-8"),
        )
        assert result["available"] is True, result
        assert result["code"] == "TURN_RUNTIME_OPEN_READY", result
        assert result["context"]["scope"]["workspaceKey"] == scope["workspace_key"], result
        assert result["context"]["scope"]["ownerSessionKey"] == session_key, result


def test_h7_cli_rejects_retired_transport_fields_before_scope_access() -> None:
    with tempfile.TemporaryDirectory(prefix="h7-retired-transport-") as directory:
        root = Path(directory)
        state_root = root / "state"
        project_root = root / "project"
        project_root.mkdir()
        result = _run_cli(
            state_root,
            project_root,
            "",
            "turn-runtime",
            "--phase",
            "open",
            "--host-visible-context-json",
            "{}",
            "--turn-intent",
            "continuity",
        )
        assert result["code"] == "H7_HOST_TRANSPORT_RETIRED", result
        assert result["rawPromptStored"] is False
        assert result["rawTranscriptStored"] is False
        assert not state_root.exists()


def main() -> None:
    tests = [
        test_retired_dispatcher_declares_h7_replacement,
        test_retired_dispatcher_is_a_noop_with_no_state_side_effects,
        test_h7_native_turn_runtime_uses_current_scope_and_recovery_presentation,
        test_h7_cli_turn_runtime_reads_cwd_and_local_session_only,
        test_h7_mcp_equivalent_bridge_reaches_the_same_runtime,
        test_h7_cli_rejects_retired_transport_fields_before_scope_access,
    ]
    for test in tests:
        test()
    print("RUNTIME_H7_HOOKLESS_RETIREMENT_REGRESSION_OK")


if __name__ == "__main__":
    main()
