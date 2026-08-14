from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ROOT = ROOT.parent
TEST_HANDLER_GENERATION = "hg-" + "0" * 64
sys.path.insert(0, str(ROOT / "runtime"))

from brain_control import BrainControl
import codex_prompt_hook as native_prompt_hook
import codex_prompt_hook_dispatcher as stable_prompt_hook_dispatcher
import codex_prompt_hook_launcher as native_hook_launcher
import codex_stop_hook as stop_hook


def _actor_receipt() -> dict[str, object]:
    return {
        "schema": "super-brain.actor-receipt.v1",
        "actorKind": "test",
        "actorId": "runtime_native_memory_prompt_hook_regression",
        "authorization": "user_confirmed",
        "authorizationReceipt": "native-memory-prompt-hook-regression",
    }


def _payload(kind: str) -> dict[str, object]:
    payloads: dict[str, dict[str, object]] = {
        "preference": {
            "schema": "super-brain.card.preference.v1",
            "statement": "Keep release progress concise and evidence-led.",
            "conditions": ["release archive work"],
            "confidence": 92,
            "conflictState": "clear",
            "tags": ["release"],
        },
        "experience": {
            "schema": "super-brain.card.experience.v1",
            "context": "A release archive required delivery evidence.",
            "outcome": "Evidence was checked before declaring completion.",
            "lesson": "Verify the release archive before closeout.",
            "reuseConditions": ["release archive"],
            "prevention": "Keep archive verification in the final check.",
            "validationState": "adopted",
            "tags": ["release"],
        },
        "procedure": {
            "schema": "super-brain.card.procedure.v1",
            "objective": "Prepare a verified release archive.",
            "preconditions": ["build completed"],
            "steps": ["collect artifacts", "write evidence", "verify archive"],
            "verification": ["archive contains the required deliverables"],
            "tags": ["release"],
        },
        "note": {
            "schema": "super-brain.card.note.v1",
            "body": "Reference: the release archive includes the installer and test report.",
            "links": ["release-archive"],
            "tags": ["release", "待学习", "建议：experience"],
        },
        "reflection": {
            "schema": "super-brain.card.reflection.v1",
            "observation": "A release closeout was once declared before archive verification.",
            "hypothesis": "The final verification was not visible at closeout.",
            "proposedAction": "Consider keeping archive verification visible in release work.",
            "evidence": ["native-memory-prompt-hook-regression"],
            "confidence": 88,
            "candidateState": "validated",
            "tags": ["release"],
        },
    }
    return json.loads(json.dumps(payloads[kind]))


def _create(control: BrainControl, kind: str, card_id: str, title: str, payload: dict[str, object], *, scope: dict[str, str] | None = None) -> None:
    control.apply(
        {
            "commandType": "create_card",
            "commandId": f"create-{card_id}",
            "aggregateId": card_id,
            "expectedRevision": 0,
            "kind": kind,
            "scope": scope or {"kind": "global", "key": "user"},
            "lifecycle": "active",
            "authority": "user_confirmed",
            "privacyClass": "private",
            "title": title,
            "payload": payload,
            "evidenceRefs": ["tests/runtime_native_memory_prompt_hook_regression.py"],
            "actorReceipt": _actor_receipt(),
            "reason": "exercise the native memory influence snapshot",
            "source": "runtime_native_memory_prompt_hook_regression",
        }
    )


def _transition(control: BrainControl, command_type: str, card_id: str, revision: int) -> None:
    command: dict[str, object] = {
        "commandType": command_type,
        "commandId": f"{command_type}-{card_id}",
        "aggregateId": card_id,
        "expectedRevision": revision,
        "actorReceipt": _actor_receipt(),
        "reason": "exercise snapshot invalidation after governed card lifecycle transition",
        "source": "runtime_native_memory_prompt_hook_regression",
    }
    if command_type in {"forget_active", "forget_trashed"}:
        command["forgetAcknowledged"] = True
    control.apply(command)


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")), encoding="utf-8")


def _snapshot_hash(snapshot: dict[str, object]) -> str:
    body = {key: value for key, value in snapshot.items() if key != "payloadHash"}
    return hashlib.sha256(json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")).hexdigest()


def _package_version() -> str:
    return str(json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["version"])


def _write_active_native_contract(
    state_root: Path,
    workspace_key: str,
    session_key: str,
    *,
    task_id: str = "task-native-memory-prompt-hook",
    task_instance_id: str = "task-instance-native-memory-prompt-hook",
    next_action: str = "verify the next release archive step",
) -> tuple[str, Path]:
    original_instruction = "retain the verified release archive workflow"
    instruction_hash = hashlib.sha256(original_instruction.encode("utf-8")).hexdigest()
    anchor = {
        "schema": "super-brain.instruction-anchor.v1",
        "anchorId": "ia-native-memory-prompt-hook",
        "globalSequence": 7,
        "sequence": 7,
        "taskId": task_id,
        "workspaceKey": workspace_key,
        "ownerSessionKey": session_key,
        "instruction": original_instruction,
        "instructionHash": instruction_hash,
        "contentHash": instruction_hash,
        "classification": {"mode": "continue", "topicAffinity": "active", "confidence": "high"},
        "source": "fixture",
        "rawPromptStored": False,
    }
    contract_name = f"{task_id}--{workspace_key}.json"
    contract_path = state_root / "workspace" / "runtime-state" / "execution-contracts" / contract_name
    _write_json(
        contract_path,
        {
            "schema": "super-brain.execution-contract.v1",
            "status": "active",
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "packageVersion": _package_version(),
            "revision": 3,
            "focusId": "release-archive",
            "focusLabel": "Release archive",
            "latestUserInstruction": original_instruction,
            "nextAction": next_action,
            "blockers": [],
            "instructionAnchor": anchor,
            "needsReconciliation": False,
            "returnStack": [],
            "unfinishedWorkPlans": [],
            "mergeIntents": [],
        },
    )
    _write_json(
        state_root / "workspace" / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
        {
            "schema": "super-brain.execution-hot-index.v1",
            "entries": [
                {
                    "taskId": task_id,
                    "taskInstanceId": task_instance_id,
                    "workspaceKey": workspace_key,
                    "ownerSessionKey": session_key,
                    "packageVersion": _package_version(),
                    "revision": 3,
                    "status": "active",
                    "wakeEligible": True,
                    "updatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                    "contractFileName": contract_name,
                    "lines": [
                        {
                            "focusId": "release-archive",
                            "focusLabel": "Release archive",
                            "role": "active",
                            "topicKeys": ["release", "archive"],
                            "wakeTerms": ["continue", "release archive"],
                        }
                    ],
                }
            ],
        },
    )
    return task_id, contract_path


def test_stop_hook_continuation_reaches_native_hook_without_replacing_user_instruction() -> None:
    """A Stop continuation is internal lifecycle state, not a new user instruction."""

    with tempfile.TemporaryDirectory(prefix="super-brain-stop-native-chain-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "1" * 24
        session_key = "sid-" + "2" * 24
        next_action = "STOP_NATIVE_CHAIN_NEXT_ACTION_SENTINEL"
        task_id, contract_path = _write_active_native_contract(
            state_root,
            workspace_key,
            session_key,
            task_id="task-stop-native-chain",
            task_instance_id="instance-stop-native-chain",
            next_action=next_action,
        )
        resolution = {
            "ok": True,
            "actionAuthorization": "allowed",
            "claimAllowed": True,
            "needsConfirmation": False,
            "blockers": [],
            "taskId": task_id,
            "focusId": "release-archive",
            "focusLabel": "Release archive",
            "nextAction": next_action,
            "latestUserInstruction": "continue the approved release archive work",
        }
        stop_result = stop_hook.decide_stop({"stop_hook_active": False}, resolution)
        assert stop_result["decision"] == "block"
        continuation_prompt = str(stop_result["reason"])
        before_contract = contract_path.read_bytes()
        output, telemetry, _ = _invoke_native_hook(
            state_root,
            workspace_key,
            session_key,
            continuation_prompt,
        )
        after_contract = contract_path.read_bytes()

        context = str(output["hookSpecificOutput"]["additionalContext"])
        assert after_contract == before_contract
        assert "SUPER_BRAIN_LIFECYCLE_CONTINUATION" in context
        assert "actionAuthorization=allowed" in context
        assert f"authorizedNextAction={next_action}" in context
        assert "turnCompletionGate=required" in context
        capture = telemetry["executionContractCapture"]
        assert capture["lifecycleContinuation"] is True
        assert capture["actionAuthorization"] == "allowed"
        assert capture["needsReconciliation"] is False
        assert telemetry["rawPromptStored"] is False


def test_native_issue_prompt_uses_the_same_super_brain_issue_protocol() -> None:
    """An active native continuation must not bypass the issue diagnosis contract."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-issue-protocol-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "8" * 24
        session_key = "sid-" + "9" * 24
        _write_active_native_contract(
            state_root,
            workspace_key,
            session_key,
            task_id="task-native-issue-protocol",
            task_instance_id="instance-native-issue-protocol",
        )
        prompt = "Why does Super Brain continue the approved main workline incorrectly?"
        output, telemetry, _ = _invoke_native_hook(state_root, workspace_key, session_key, prompt)
        context = _context(output)

        assert "SUPER_BRAIN_ISSUE_RESPONSE_GATE" in context
        assert "problemNature=execution_continuity" in context
        assert "responseOrder=essence>evidence>repair>next" in context
        assert "CANONICAL_PLAN_ADMISSION_GATE" not in context
        assert telemetry["superBrainIssue"]["detected"] is True
        assert telemetry["superBrainIssue"]["problemNature"] == "execution_continuity"
        assert telemetry["rawPromptStored"] is False
        assert prompt not in json.dumps(telemetry, ensure_ascii=False)


def test_native_hook_self_heals_activation_for_continuation_without_hot_index() -> None:
    """A cold/no-Hook continuation still receives a bounded brain activation proof."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-cold-activation-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "6" * 24
        session_key = "sid-" + "7" * 24
        output, telemetry, _ = _invoke_native_hook(state_root, workspace_key, session_key, "continue")
        context = _context(output)

        assert "SUPER_BRAIN_ACTIVATION:" in context
        assert "state=full_brain_active" in context
        assert telemetry["activation"]["state"] == "full_brain_active"
        assert telemetry["activation"]["coreReady"] is True
        assert telemetry["activation"]["rawPromptStored"] is False
        assert telemetry["rawPromptStored"] is False
        assert telemetry["rawSessionIdStored"] is False


def _invoke_native_hook(
    state_root: Path,
    workspace_key: str,
    session_key: str,
    prompt: str,
    *,
    synthetic: bool = False,
) -> tuple[dict[str, object], dict[str, object], float]:
    environment = os.environ.copy()
    environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
    environment["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
    environment.setdefault("SUPER_BRAIN_HOOK_HANDLER_GENERATION", TEST_HANDLER_GENERATION)
    environment.setdefault("SUPER_BRAIN_HOOK_EXPECTED_GENERATION", TEST_HANDLER_GENERATION)
    environment.setdefault("SUPER_BRAIN_HOOK_ENTRYPOINT", "stable_dispatcher")
    started = time.perf_counter()
    command = [sys.executable, "-X", "utf8", "-B", str(ROOT / "runtime" / "codex_prompt_hook.py"), "--package-root", str(ROOT)]
    if synthetic:
        command.extend(["--test-prompt", prompt, "--test-session-id", session_key])
    completed = subprocess.run(
        command,
        input=None if synthetic else json.dumps({"session_id": session_key, "prompt": prompt}, ensure_ascii=False).encode("utf-8"),
        capture_output=True,
        env=environment,
        check=False,
        timeout=10,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000
    stderr = completed.stderr.decode("utf-8", errors="replace")
    assert completed.returncode == 0, stderr
    output = json.loads(completed.stdout.decode("utf-8"))
    assert set(output) == {"hookSpecificOutput"}
    hook_output = output["hookSpecificOutput"]
    assert isinstance(hook_output, dict) and hook_output.get("hookEventName") == "UserPromptSubmit"
    telemetry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry" / f"{session_key}--{workspace_key}.json"
    return output, json.loads(telemetry_path.read_text(encoding="utf-8")), elapsed_ms


def _invoke_legacy_cached_hook(
    state_root: Path,
    workspace_key: str,
    session_key: str,
    prompt: str,
    entrypoint_name: str = "codex_prompt_hook.py",
) -> tuple[dict[str, object], dict[str, object], float]:
    """Exercise the package-root command that an older Desktop cache held."""

    environment = os.environ.copy()
    environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
    environment["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
    environment["CODEX_HOME"] = str(state_root / "isolated-codex-home")
    started = time.perf_counter()
    completed = subprocess.run(
        [
            sys.executable,
            "-X",
            "utf8",
            "-B",
            str(PACKAGE_ROOT / "runtime" / entrypoint_name),
            "--package-root",
            str(PACKAGE_ROOT),
            "--fallback-hook",
            str(PACKAGE_ROOT / "scripts" / "codex-user-prompt-hook.ps1"),
        ],
        input=json.dumps({"session_id": session_key, "prompt": prompt}, ensure_ascii=False).encode("utf-8"),
        capture_output=True,
        env=environment,
        check=False,
        timeout=10,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000
    stderr = completed.stderr.decode("utf-8", errors="replace")
    assert completed.returncode == 0, stderr
    output = json.loads(completed.stdout.decode("utf-8"))
    assert set(output) == {"hookSpecificOutput"}
    hook_output = output["hookSpecificOutput"]
    assert isinstance(hook_output, dict) and hook_output.get("hookEventName") == "UserPromptSubmit"
    telemetry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry" / f"{session_key}--{workspace_key}.json"
    return output, json.loads(telemetry_path.read_text(encoding="utf-8")), elapsed_ms


def _invoke_native_hook_with_open_stdin(
    state_root: Path,
    workspace_key: str,
    session_key: str,
    prompt: str,
) -> tuple[dict[str, object], dict[str, object], float]:
    """Send a hook payload but deliberately keep the host stdin pipe open."""

    environment = os.environ.copy()
    environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
    environment["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
    environment.setdefault("SUPER_BRAIN_HOOK_HANDLER_GENERATION", TEST_HANDLER_GENERATION)
    environment.setdefault("SUPER_BRAIN_HOOK_EXPECTED_GENERATION", TEST_HANDLER_GENERATION)
    environment.setdefault("SUPER_BRAIN_HOOK_ENTRYPOINT", "stable_dispatcher")
    command = [sys.executable, "-X", "utf8", "-B", str(ROOT / "runtime" / "codex_prompt_hook.py"), "--package-root", str(ROOT)]
    started = time.perf_counter()
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    assert process.stdin is not None and process.stdout is not None and process.stderr is not None
    try:
        process.stdin.write(json.dumps({"session_id": session_key, "prompt": prompt}, ensure_ascii=False).encode("utf-8"))
        process.stdin.flush()
        try:
            return_code = process.wait(timeout=2)
        except subprocess.TimeoutExpired as error:
            process.kill()
            process.wait(timeout=2)
            raise AssertionError("native hook waited for stdin EOF") from error
        stdout = process.stdout.read()
        stderr = process.stderr.read().decode("utf-8", errors="replace")
    finally:
        try:
            process.stdin.close()
        except OSError:
            pass
    elapsed_ms = (time.perf_counter() - started) * 1000
    assert return_code == 0, stderr
    output = json.loads(stdout.decode("utf-8"))
    assert set(output) == {"hookSpecificOutput"}
    hook_output = output["hookSpecificOutput"]
    assert isinstance(hook_output, dict) and hook_output.get("hookEventName") == "UserPromptSubmit"
    telemetry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry" / f"{session_key}--{workspace_key}.json"
    return output, json.loads(telemetry_path.read_text(encoding="utf-8")), elapsed_ms


def _context(output: dict[str, object]) -> str:
    hook_output = output["hookSpecificOutput"]
    assert isinstance(hook_output, dict)
    return str(hook_output["additionalContext"])


def _write_fake_dispatch_target(package_root: Path, label: str) -> None:
    launcher = package_root / "runtime" / "codex_prompt_hook_launcher.py"
    native = package_root / "runtime" / "codex_prompt_hook.py"
    fallback = package_root / "scripts" / "codex-user-prompt-hook.ps1"
    launcher.parent.mkdir(parents=True, exist_ok=True)
    fallback.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text(
        "\n".join(
            [
                "from __future__ import annotations",
                "import json",
                "import os",
                "import sys",
                f"LABEL = {label!r}",
                "payload = json.loads(sys.stdin.buffer.read().decode('utf-8'))",
                "context = json.dumps({'label': LABEL, 'generation': os.environ.get('SUPER_BRAIN_HOOK_HANDLER_GENERATION', ''), 'promptField': 'prompt' if 'prompt' in payload else 'none'}, separators=(',', ':'))",
                "sys.stdout.write(json.dumps({'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': context}}, separators=(',', ':')))",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    native.write_text(f"# native target {label}\n", encoding="utf-8")
    fallback.write_text(f"# fallback target {label}\n", encoding="utf-8")


def _describe_dispatcher(stable_dispatcher: Path, codex_home: Path) -> dict[str, object]:
    completed = subprocess.run(
        [sys.executable, "-X", "utf8", "-B", str(stable_dispatcher), "--codex-home", str(codex_home), "--describe"],
        capture_output=True,
        check=False,
        timeout=10,
    )
    assert completed.returncode == 0, completed.stderr.decode("utf-8", errors="replace")
    value = json.loads(completed.stdout.decode("utf-8"))
    assert value["ok"] is True
    return value


def _run_stable_dispatcher(stable_dispatcher: Path, codex_home: Path, session_key: str) -> tuple[list[str], dict[str, object]]:
    command = [sys.executable, "-X", "utf8", "-B", str(stable_dispatcher), "--codex-home", str(codex_home)]
    completed = subprocess.run(
        command,
        input=json.dumps({"session_id": session_key, "prompt": "continue release archive"}, ensure_ascii=False).encode("utf-8"),
        capture_output=True,
        check=False,
        timeout=10,
    )
    assert completed.returncode == 0, completed.stderr.decode("utf-8", errors="replace")
    output = json.loads(completed.stdout.decode("utf-8"))
    return command, json.loads(output["hookSpecificOutput"]["additionalContext"])


class _BinaryStdout:
    def __init__(self) -> None:
        self.buffer = io.BytesIO()

    def write(self, value: str) -> int:
        return self.buffer.write(value.encode("utf-8"))

    def flush(self) -> None:
        return None


def test_native_prompt_hook_launcher_relays_valid_output_and_captures_only_failure_metadata() -> None:
    """The outer host command is fail-open while preserving a safe child-failure seam."""

    valid_output = b'{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"fixture"}}'
    with tempfile.TemporaryDirectory(prefix="super-brain-native-launcher-ok-") as directory:
        state_root = Path(directory)
        stdout = _BinaryStdout()
        argv = ["codex_prompt_hook_launcher.py", "--package-root", str(ROOT)]
        completed = subprocess.CompletedProcess(args=["python"], returncode=0, stdout=valid_output, stderr=b"")
        with (
            patch.dict(os.environ, {"SUPER_BRAIN_STATE_ROOT": str(state_root), "SUPER_BRAIN_HOOK_DISPATCHED": "1"}),
            patch.object(native_hook_launcher.sys, "argv", argv),
            patch.object(native_hook_launcher.sys, "stdout", stdout),
            patch.object(native_hook_launcher.subprocess, "run", return_value=completed),
        ):
            assert native_hook_launcher.main() == 0
        assert stdout.buffer.getvalue() == valid_output
        assert not (
            state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "launcher-last-failure.json"
        ).exists()

    with tempfile.TemporaryDirectory(prefix="super-brain-native-launcher-failure-") as directory:
        state_root = Path(directory)
        stdout = _BinaryStdout()
        argv = ["codex_prompt_hook_launcher.py", "--package-root", str(ROOT)]
        stderr_marker = b"PRIVATE_CHILD_STDERR_SENTINEL"
        completed = subprocess.CompletedProcess(args=["python"], returncode=1, stdout=b"", stderr=stderr_marker)
        with (
            patch.dict(os.environ, {"SUPER_BRAIN_STATE_ROOT": str(state_root), "SUPER_BRAIN_HOOK_DISPATCHED": "1"}),
            patch.object(native_hook_launcher.sys, "argv", argv),
            patch.object(native_hook_launcher.sys, "stdout", stdout),
            patch.object(native_hook_launcher.subprocess, "run", return_value=completed),
        ):
            assert native_hook_launcher.main() == 0
        assert json.loads(stdout.buffer.getvalue().decode("utf-8")) == {
            "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}
        }
        status_path = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "launcher-last-failure.json"
        status = json.loads(status_path.read_text(encoding="utf-8"))
        assert status["schema"] == "super-brain.prompt-hook-launcher-failure.v1"
        assert status["targetExitCode"] == 1
        assert status["targetStderrHash"] == hashlib.sha256(stderr_marker).hexdigest()
        assert status["targetStderrLength"] == len(stderr_marker)
        assert status["rawPromptStored"] is False
        assert status["rawSessionIdStored"] is False
        assert status["memoryBodyStored"] is False
        assert stderr_marker.decode("utf-8") not in json.dumps(status, ensure_ascii=False)


def test_stable_prompt_hook_dispatcher_survives_package_root_migration_without_command_change() -> None:
    """A cached Desktop command stays valid while the installed marker moves to a new package root."""

    source_dispatcher = ROOT / "runtime" / "codex_prompt_hook_dispatcher.py"
    assert source_dispatcher.is_file(), "stable prompt-hook dispatcher source is missing"
    with tempfile.TemporaryDirectory(prefix="super-brain-stable-dispatcher-migration-") as directory:
        sandbox = Path(directory)
        codex_home = sandbox / "codex-home"
        stable_root = codex_home / "hooks" / "super-memory-brain"
        stable_dispatcher = stable_root / "codex_prompt_hook_dispatcher.py"
        skill_root = codex_home / "skills" / "super-memory-brain"
        memory_root = sandbox / "memory"
        old_root = sandbox / "old-package"
        new_root = sandbox / "new-package"
        _write_fake_dispatch_target(old_root, "old")
        _write_fake_dispatch_target(new_root, "new")
        stable_root.mkdir(parents=True, exist_ok=True)
        skill_root.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_dispatcher, stable_dispatcher)
        (skill_root / "memory-root.txt").write_text(str(memory_root / "shared"), encoding="utf-8")

        (skill_root / "package-root.txt").write_text(str(old_root), encoding="utf-8")
        old_description = _describe_dispatcher(stable_dispatcher, codex_home)
        (stable_root / "handler.json").write_text(json.dumps(old_description, ensure_ascii=False), encoding="utf-8")
        old_command, old_context = _run_stable_dispatcher(stable_dispatcher, codex_home, "sid-" + "1" * 24)
        assert old_context["label"] == "old"
        assert old_context["generation"] == old_description["generation"]

        (skill_root / "package-root.txt").write_text(str(new_root), encoding="utf-8")
        new_description = _describe_dispatcher(stable_dispatcher, codex_home)
        (stable_root / "handler.json").write_text(json.dumps(new_description, ensure_ascii=False), encoding="utf-8")
        new_command, new_context = _run_stable_dispatcher(stable_dispatcher, codex_home, "sid-" + "2" * 24)
        assert new_command == old_command
        assert new_context["label"] == "new"
        assert new_context["generation"] == new_description["generation"]
        assert new_description["generation"] != old_description["generation"]

        entry_path = memory_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "handler-last-entry.json"
        assert not entry_path.exists(), "a direct Python fixture must not certify a Desktop Host"


def test_stable_dispatcher_direct_windows_command_survives_cmd_shell_and_unicode_paths() -> None:
    """The installed direct Python command remains valid through cmd.exe and a CJK/space path."""

    if os.name != "nt":
        return
    source_dispatcher = ROOT / "runtime" / "codex_prompt_hook_dispatcher.py"
    with tempfile.TemporaryDirectory(prefix="super-brain-windows-direct-hook-") as directory:
        sandbox = Path(directory)
        codex_home = sandbox / "含 中文 空格" / "codex home"
        stable_root = codex_home / "hooks" / "super-memory-brain"
        stable_dispatcher = stable_root / "codex_prompt_hook_dispatcher.py"
        skill_root = codex_home / "skills" / "super-memory-brain"
        memory_root = sandbox / "state"
        package_root = sandbox / "package target"
        _write_fake_dispatch_target(package_root, "windows-direct")
        stable_root.mkdir(parents=True, exist_ok=True)
        skill_root.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_dispatcher, stable_dispatcher)
        (skill_root / "package-root.txt").write_text(str(package_root), encoding="utf-8")
        (skill_root / "memory-root.txt").write_text(str(memory_root / "shared"), encoding="utf-8")
        description = _describe_dispatcher(stable_dispatcher, codex_home)
        (stable_root / "handler.json").write_text(json.dumps(description, ensure_ascii=False), encoding="utf-8")
        direct_command = f'"{sys.executable}" -X utf8 "{stable_dispatcher}" --codex-home "{codex_home}"'
        assert "call " not in direct_command.lower() and ".cmd" not in direct_command.lower()
        cmd_command = f'""{sys.executable}" -X utf8 "{stable_dispatcher}" --codex-home "{codex_home}""'
        completed = subprocess.run(
            f"cmd.exe /d /s /c {cmd_command}",
            input=json.dumps({"session_id": "sid-" + "3" * 24, "prompt": "continue release archive"}).encode("utf-8"),
            capture_output=True,
            check=False,
            shell=True,
            timeout=10,
        )
        assert completed.returncode == 0, completed.stderr.decode("utf-8", errors="replace")
        output = json.loads(completed.stdout.decode("utf-8"))
        context = json.loads(_context(output))
        assert context["label"] == "windows-direct"
        assert context["generation"] == description["generation"]
        assert not (memory_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "handler-last-entry.json").exists()


def test_stable_prompt_hook_dispatcher_missing_binding_is_metadata_only_and_fail_open() -> None:
    """A missing package marker never exposes stdin or turns a prompt into a host-visible failure."""

    source_dispatcher = ROOT / "runtime" / "codex_prompt_hook_dispatcher.py"
    assert source_dispatcher.is_file(), "stable prompt-hook dispatcher source is missing"
    with tempfile.TemporaryDirectory(prefix="super-brain-stable-dispatcher-failure-") as directory:
        sandbox = Path(directory)
        codex_home = sandbox / "codex-home"
        stable_root = codex_home / "hooks" / "super-memory-brain"
        stable_dispatcher = stable_root / "codex_prompt_hook_dispatcher.py"
        skill_root = codex_home / "skills" / "super-memory-brain"
        memory_root = sandbox / "memory"
        stable_root.mkdir(parents=True, exist_ok=True)
        skill_root.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_dispatcher, stable_dispatcher)
        (skill_root / "memory-root.txt").write_text(str(memory_root / "shared"), encoding="utf-8")
        sentinel = "STABLE_DISPATCHER_PRIVATE_PROMPT_SENTINEL"
        environment = os.environ.copy()
        # This fixture verifies the dispatcher marker fallback.  A package-wide
        # verifier may set an unrelated temporary state root, which must not
        # override the fixture's explicit codex-home memory marker.
        environment.pop("SUPER_BRAIN_STATE_ROOT", None)
        environment.pop("SUPER_BRAIN_ARCHIVE_ROOT", None)
        completed = subprocess.run(
            [sys.executable, "-X", "utf8", "-B", str(stable_dispatcher), "--codex-home", str(codex_home)],
            input=json.dumps({"session_id": "sid-" + "3" * 24, "prompt": sentinel}).encode("utf-8"),
            capture_output=True,
            check=False,
            timeout=10,
            env=environment,
        )
        assert completed.returncode == 0
        assert json.loads(completed.stdout.decode("utf-8")) == {
            "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}
        }
        failure_path = memory_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "handler-last-failure.json"
        failure = json.loads(failure_path.read_text(encoding="utf-8"))
        assert failure["schema"] == "super-brain.prompt-hook-handler-failure.v1"
        assert failure["rawPromptStored"] is False and failure["rawSessionIdStored"] is False
        assert sentinel not in json.dumps(failure, ensure_ascii=False)


def test_stable_prompt_hook_dispatcher_launch_receipts_bracket_binding_and_link_the_child() -> None:
    """The Desktop-to-Python boundary is observable before binding but cannot certify P7 alone."""

    valid_output = b'{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"fixture"}}'
    qualified_chain = {
        "verified": True,
        "processId": 4321,
        "processName": "codex-code-mode-host",
        "depth": 2,
        "source": "desktop_windows_command_chain",
    }
    with tempfile.TemporaryDirectory(prefix="super-brain-stable-dispatcher-launch-") as directory:
        state_root = Path(directory)
        codex_home = state_root / "codex-home"
        dispatcher_path = ROOT / "runtime" / "codex_prompt_hook_dispatcher.py"
        binding = {
            "packageRoot": str(ROOT),
            "generation": "hg-" + "a" * 64,
            "_launcherPath": str(ROOT / "runtime" / "codex_prompt_hook_launcher.py"),
            "_fallbackPath": str(ROOT / "scripts" / "codex-user-prompt-hook.ps1"),
        }
        failure_stdout = _BinaryStdout()
        sentinel = "DISPATCHER_BINDING_PRIVATE_SENTINEL"
        with (
            patch.object(stable_prompt_hook_dispatcher, "_binding", side_effect=stable_prompt_hook_dispatcher.HandlerBindingError("PROMPT_HOOK_TARGET_MISSING")),
            patch.object(stable_prompt_hook_dispatcher, "_state_root", return_value=state_root),
            patch.object(stable_prompt_hook_dispatcher, "_expected_generation", return_value=binding["generation"]),
            patch.object(stable_prompt_hook_dispatcher, "_desktop_host_ancestor", return_value=qualified_chain),
            patch.object(stable_prompt_hook_dispatcher.sys, "stdout", failure_stdout),
            patch.object(stable_prompt_hook_dispatcher.sys, "argv", ["codex_prompt_hook_dispatcher.py", "--codex-home", str(codex_home)]),
        ):
            assert stable_prompt_hook_dispatcher.main() == 0
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        launch = json.loads((diagnostic_root / "dispatcher-last-launch.json").read_text(encoding="utf-8"))
        assert launch["schema"] == "super-brain.prompt-hook-dispatcher-launch.v1"
        assert launch["stage"] == "binding_failed"
        assert launch["reason"] == "PROMPT_HOOK_TARGET_MISSING"
        assert re.fullmatch(r"[a-f0-9]{32}", launch["launchId"])
        assert launch["expectedGeneration"] == binding["generation"]
        assert launch["desktopCommandChainVerified"] is True
        assert sentinel not in json.dumps(launch, ensure_ascii=False)
        stable_sidecar = codex_home / "hooks" / "super-memory-brain" / "dispatcher-boundary-last-launch.json"
        assert stable_sidecar.exists()
        assert json.loads(stable_sidecar.read_text(encoding="utf-8"))["launchId"] == launch["launchId"]
        assert not (diagnostic_root / "handler-last-entry.json").exists()

        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope={
                "workspaceKey": "ws-" + "1" * 24,
                "ownerSessionKey": "sid-" + "2" * 24,
                "taskId": "dispatcher-launch-task",
                "taskInstanceId": "dispatcher-launch-instance",
                "contractRevision": 3,
            },
            reason="bind a P7 dispatcher launch to the native evidence chain",
            ttl_seconds=300,
            arm_id="dispatcher-launch-arm",
        )
        success_stdout = _BinaryStdout()
        completed = subprocess.CompletedProcess(args=["python"], returncode=0, stdout=valid_output, stderr=b"")
        with (
            patch.object(stable_prompt_hook_dispatcher, "_binding", return_value=binding),
            patch.object(stable_prompt_hook_dispatcher, "_state_root", return_value=state_root),
            patch.object(stable_prompt_hook_dispatcher, "_expected_generation", return_value=binding["generation"]),
            patch.object(stable_prompt_hook_dispatcher, "_desktop_host_ancestor", return_value=qualified_chain),
            patch.object(stable_prompt_hook_dispatcher.subprocess, "run", return_value=completed) as invoked,
            patch.object(stable_prompt_hook_dispatcher.sys, "stdout", success_stdout),
            patch.object(stable_prompt_hook_dispatcher.sys, "argv", ["codex_prompt_hook_dispatcher.py", "--codex-home", str(codex_home)]),
        ):
            assert stable_prompt_hook_dispatcher.main() == 0
        scoped_launch = json.loads((diagnostic_root / "dispatcher-launches" / f"{arm['armId']}.json").read_text(encoding="utf-8"))
        assert scoped_launch["stage"] == "binding_resolved"
        assert scoped_launch["generation"] == binding["generation"]
        assert scoped_launch["generationMatches"] is True
        child_environment = invoked.call_args.kwargs["env"]
        assert child_environment["SUPER_BRAIN_HOOK_DISPATCH_LAUNCH_ID"] == scoped_launch["launchId"]
        assert re.fullmatch(r"[a-f0-9]{32}", child_environment["SUPER_BRAIN_HOOK_DISPATCH_LAUNCH_ID"])
        assert success_stdout.buffer.getvalue() == valid_output


def test_stable_prompt_hook_dispatcher_requires_a_qualified_desktop_command_chain() -> None:
    """Desktop app-server and Code Mode spines certify a Host; shell tools do not."""

    accepted = {
        500: (400, "python.exe"),
        400: (300, "cmd.exe"),
        300: (200, "codex-command-runner.exe"),
        200: (100, "codex-code-mode-host.exe"),
        100: (1, "codex.exe"),
        1: (0, "ChatGPT.exe"),
    }
    accepted_app_server = {
        500: (400, "python.exe"),
        400: (100, "cmd.exe"),
        100: (1, "codex.exe"),
        1: (0, "ChatGPT.exe"),
    }
    accepted_app_server_powershell_wrapper = {
        500: (400, "python.exe"),
        400: (300, "powershell.exe"),
        300: (200, "codex.exe"),
        200: (100, "ChatGPT.exe"),
        100: (90, "sihost.exe"),
        90: (80, "svchost.exe"),
        80: (70, "services.exe"),
        70: (1, "wininit.exe"),
        1: (0, "System.exe"),
    }
    accepted_app_server_powershell_truncated = {
        500: (400, "python.exe"),
        400: (300, "powershell.exe"),
        300: (200, "codex.exe"),
        200: (0, "ChatGPT.exe"),
    }
    rejected_tool = {
        500: (400, "python.exe"),
        400: (300, "powershell.exe"),
        300: (200, "codex.exe"),
        200: (1, "ChatGPT.exe"),
        1: (0, "explorer.exe"),
    }
    rejected_shell_relay = {
        500: (400, "python.exe"),
        400: (300, "powershell.exe"),
        300: (200, "codex-code-mode-host.exe"),
        200: (100, "codex.exe"),
        100: (1, "ChatGPT.exe"),
        1: (0, "explorer.exe"),
    }
    with patch.object(stable_prompt_hook_dispatcher, "_windows_process_snapshot", return_value=accepted), patch.object(
        stable_prompt_hook_dispatcher.os, "getpid", return_value=500
    ):
        chain = stable_prompt_hook_dispatcher._desktop_command_chain()
    assert chain == {
        "verified": True,
        "processId": 200,
        "processName": "codex-code-mode-host",
        "depth": 3,
        "source": "desktop_windows_command_chain",
    }
    with patch.object(stable_prompt_hook_dispatcher, "_windows_process_snapshot", return_value=accepted_app_server), patch.object(
        stable_prompt_hook_dispatcher.os, "getpid", return_value=500
    ):
        app_server_chain = stable_prompt_hook_dispatcher._desktop_command_chain()
    assert app_server_chain == {
        "verified": True,
        "processId": 100,
        "processName": "codex",
        "depth": 2,
        "source": "desktop_windows_command_chain",
    }
    with patch.object(stable_prompt_hook_dispatcher, "_windows_process_snapshot", return_value=accepted_app_server_powershell_wrapper), patch.object(
        stable_prompt_hook_dispatcher.os, "getpid", return_value=500
    ):
        app_server_powershell_chain = stable_prompt_hook_dispatcher._desktop_command_chain()
    assert app_server_powershell_chain == {
        "verified": True,
        "processId": 300,
        "processName": "codex",
        "depth": 2,
        "source": "desktop_windows_command_chain",
    }
    with patch.object(stable_prompt_hook_dispatcher, "_windows_process_snapshot", return_value=accepted_app_server_powershell_truncated), patch.object(
        stable_prompt_hook_dispatcher.os, "getpid", return_value=500
    ):
        truncated_powershell_chain = stable_prompt_hook_dispatcher._desktop_command_chain()
    assert truncated_powershell_chain == {
        "verified": True,
        "processId": 300,
        "processName": "codex",
        "depth": 2,
        "source": "desktop_windows_command_chain",
    }
    for rows in (rejected_tool, rejected_shell_relay):
        with patch.object(stable_prompt_hook_dispatcher, "_windows_process_snapshot", return_value=rows), patch.object(
            stable_prompt_hook_dispatcher.os, "getpid", return_value=500
        ):
            rejected = stable_prompt_hook_dispatcher._desktop_command_chain()
        assert rejected["verified"] is False
        assert rejected["source"] == "unverified"


def test_stable_prompt_hook_dispatcher_records_unqualified_chain_as_non_acceptance_probe() -> None:
    """An unknown relay is observable without becoming Host or P7 evidence."""

    valid_output = b'{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"fixture"}}'
    unqualified_chain = {"verified": False, "processId": 0, "processName": "", "depth": 0, "source": "unverified"}
    observed_chain = [
        {"processId": 410, "processName": "cmd", "depth": 1},
        {"processId": 310, "processName": "codex-command-runner", "depth": 2},
        {"processId": "not-an-int", "processName": "secret-command-line-sentinel", "depth": 3},
    ]
    with tempfile.TemporaryDirectory(prefix="super-brain-stable-dispatcher-unverified-chain-") as directory:
        state_root = Path(directory)
        codex_home = state_root / "codex-home"
        binding = {
            "packageRoot": str(ROOT),
            "generation": "hg-" + "2" * 64,
            "_launcherPath": str(ROOT / "runtime" / "codex_prompt_hook_launcher.py"),
            "_fallbackPath": str(ROOT / "scripts" / "codex-user-prompt-hook.ps1"),
        }
        stdout = _BinaryStdout()
        completed = subprocess.CompletedProcess(args=["python"], returncode=0, stdout=valid_output, stderr=b"")
        with (
            patch.object(stable_prompt_hook_dispatcher, "_binding", return_value=binding),
            patch.object(stable_prompt_hook_dispatcher, "_state_root", return_value=state_root),
            patch.object(stable_prompt_hook_dispatcher, "_expected_generation", return_value=binding["generation"]),
            patch.object(stable_prompt_hook_dispatcher, "_desktop_host_ancestor", return_value=unqualified_chain),
            patch.object(stable_prompt_hook_dispatcher, "_bounded_windows_parent_chain", return_value=observed_chain),
            patch.object(stable_prompt_hook_dispatcher.subprocess, "run", return_value=completed),
            patch.object(stable_prompt_hook_dispatcher.sys, "stdout", stdout),
            patch.object(
                stable_prompt_hook_dispatcher.sys,
                "argv",
                ["codex_prompt_hook_dispatcher.py", "--codex-home", str(codex_home)],
            ),
        ):
            assert stable_prompt_hook_dispatcher.main() == 0
        assert stdout.buffer.getvalue() == valid_output
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        probe = json.loads((diagnostic_root / "dispatcher-last-unverified-chain.json").read_text(encoding="utf-8"))
        assert probe["schema"] == "super-brain.prompt-hook-unverified-chain.v1"
        assert probe["stage"] == "binding_resolved"
        assert probe["generation"] == binding["generation"] and probe["generationMatches"] is True
        assert probe["processChain"] == observed_chain[:2]
        assert probe["p7AcceptanceEligible"] is False
        assert probe["rawPromptStored"] is False and probe["rawSessionIdStored"] is False
        assert "secret-command-line-sentinel" not in json.dumps(probe, ensure_ascii=False)
        assert not (diagnostic_root / "handler-last-entry.json").exists()
        assert not (diagnostic_root / "dispatcher-launches").exists()
        stable_probe = codex_home / "hooks" / "super-memory-brain" / "dispatcher-boundary-last-unverified-chain.json"
        assert json.loads(stable_probe.read_text(encoding="utf-8"))["launchId"] == probe["launchId"]


def test_native_prompt_hook_records_unverified_stable_input_shape_without_content() -> None:
    """Unknown Desktop relays expose input shape, never body/session/P7 evidence."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-unverified-input-") as directory:
        state_root = Path(directory)
        raw = json.dumps(
            {
                "prompt": "INPUT_PROBE_PROMPT_SENTINEL",
                "session_id": "INPUT_PROBE_SESSION_SENTINEL",
                "agent_id": "agent-marker",
            },
            ensure_ascii=False,
        )
        output = io.StringIO()
        argv = ["codex_prompt_hook.py", "--package-root", str(ROOT)]
        environment = {
            "SUPER_BRAIN_STATE_ROOT": str(state_root),
            "SUPER_BRAIN_HOOK_DISPATCHED": "1",
            "SUPER_BRAIN_HOOK_ENTRYPOINT": "stable_dispatcher",
            "SUPER_BRAIN_HOOK_DESKTOP_COMMAND_CHAIN_VERIFIED": "0",
            "SUPER_BRAIN_HOOK_HOST_PROCESS_SOURCE": "unverified",
        }
        with (
            patch.dict(os.environ, environment),
            patch.object(native_prompt_hook.sys, "argv", argv),
            patch.object(native_prompt_hook, "_read_hook_stdin", return_value=raw),
            redirect_stdout(output),
        ):
            assert native_prompt_hook.main() == 0
        assert json.loads(output.getvalue()) == {
            "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}
        }
        path = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "native-last-unverified-input-shape.json"
        probe = json.loads(path.read_text(encoding="utf-8"))
        assert probe == {
            "schema": "super-brain.prompt-hook-unverified-input-shape.v1",
            "observedAt": probe["observedAt"],
            "stage": "payload_filtered_agent_or_nonobject",
            "stdinReceived": True,
            "stdinByteCount": len(raw.encode("utf-8")),
            "utf8DecodeClean": True,
            "payloadJsonValid": True,
            "payloadIsObject": True,
            "payloadTopLevelKeyCount": 3,
            "hasRecognizedPromptField": True,
            "hasRecognizedSessionField": True,
            "hasAgentMarker": True,
            "nativeTelemetryWritten": False,
            "fallbackInvoked": False,
            "p7AcceptanceEligible": False,
            "rawPromptStored": False,
            "rawSessionIdStored": False,
            "memoryBodyStored": False,
        }
        serialized = json.dumps(probe, ensure_ascii=False)
        assert "INPUT_PROBE_PROMPT_SENTINEL" not in serialized
        assert "INPUT_PROBE_SESSION_SENTINEL" not in serialized
        assert not (state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry").exists()


def test_stable_prompt_hook_dispatcher_writes_entry_only_after_qualified_success() -> None:
    """A child failure or a tool process can never create a canonical Host receipt."""

    valid_output = b'{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"fixture"}}'
    qualified_chain = {
        "verified": True,
        "processId": 4321,
        "processName": "codex-code-mode-host",
        "depth": 2,
        "source": "desktop_windows_command_chain",
    }
    qualified_app_server_chain = {
        "verified": True,
        "processId": 9876,
        "processName": "codex",
        "depth": 2,
        "source": "desktop_windows_command_chain",
    }
    unqualified_chain = {"verified": False, "processId": 0, "processName": "", "depth": 0, "source": "unverified"}
    with tempfile.TemporaryDirectory(prefix="super-brain-stable-dispatcher-entry-order-") as directory:
        state_root = Path(directory)
        codex_home = state_root / "codex-home"
        binding = {
            "packageRoot": str(ROOT),
            "generation": "hg-" + "1" * 64,
            "_launcherPath": str(ROOT / "runtime" / "codex_prompt_hook_launcher.py"),
            "_fallbackPath": str(ROOT / "scripts" / "codex-user-prompt-hook.ps1"),
        }
        entry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "handler-last-entry.json"

        def run_case(chain: dict[str, object], completed: subprocess.CompletedProcess[bytes], extra: list[str]) -> tuple[_BinaryStdout, object]:
            stdout = _BinaryStdout()
            with (
                patch.object(stable_prompt_hook_dispatcher, "_binding", return_value=binding),
                patch.object(stable_prompt_hook_dispatcher, "_state_root", return_value=state_root),
                patch.object(stable_prompt_hook_dispatcher, "_expected_generation", return_value=binding["generation"]),
                patch.object(stable_prompt_hook_dispatcher, "_desktop_host_ancestor", return_value=chain),
                patch.object(stable_prompt_hook_dispatcher.subprocess, "run", return_value=completed) as invoked,
                patch.object(stable_prompt_hook_dispatcher.sys, "stdout", stdout),
                patch.object(
                    stable_prompt_hook_dispatcher.sys,
                    "argv",
                    ["codex_prompt_hook_dispatcher.py", "--codex-home", str(codex_home), *extra],
                ),
            ):
                assert stable_prompt_hook_dispatcher.main() == 0
            return stdout, invoked

        failed = subprocess.CompletedProcess(args=["python"], returncode=2, stdout=b"", stderr=b"usage: native")
        stdout, _ = run_case(qualified_chain, failed, ["--help"])
        assert json.loads(stdout.buffer.getvalue().decode("utf-8"))["hookSpecificOutput"]["additionalContext"] == ""
        assert not entry_path.exists(), "the historical --help/nonzero probe must not certify a Host"

        stdout, _ = run_case(unqualified_chain, subprocess.CompletedProcess(args=["python"], returncode=0, stdout=valid_output, stderr=b""), [])
        assert stdout.buffer.getvalue() == valid_output
        assert not entry_path.exists(), "a valid child output without the Desktop command spine is not Host evidence"

        stdout, invoked = run_case(qualified_chain, subprocess.CompletedProcess(args=["python"], returncode=0, stdout=valid_output, stderr=b""), [])
        assert stdout.buffer.getvalue() == valid_output
        entry = json.loads(entry_path.read_text(encoding="utf-8"))
        assert entry["schema"] == "super-brain.prompt-hook-handler-entry.v2"
        assert entry["generation"] == binding["generation"] and entry["generationMatches"] is True
        assert entry["hostProcessId"] == 4321 and entry["hostProcessName"] == "codex-code-mode-host"
        assert entry["hostProcessSource"] == "desktop_windows_command_chain"
        assert entry["desktopCommandChainVerified"] is True
        environment = invoked.call_args.kwargs["env"]
        assert environment["SUPER_BRAIN_HOOK_DESKTOP_COMMAND_CHAIN_VERIFIED"] == "1"
        assert environment["SUPER_BRAIN_HOOK_HOST_PROCESS_SOURCE"] == "desktop_windows_command_chain"

        entry_path.unlink()
        stdout, invoked = run_case(qualified_app_server_chain, subprocess.CompletedProcess(args=["python"], returncode=0, stdout=valid_output, stderr=b""), [])
        assert stdout.buffer.getvalue() == valid_output
        entry = json.loads(entry_path.read_text(encoding="utf-8"))
        assert entry["hostProcessId"] == 9876 and entry["hostProcessName"] == "codex"
        assert entry["hostProcessSource"] == "desktop_windows_command_chain"
        assert invoked.call_args.kwargs["env"]["SUPER_BRAIN_HOOK_DESKTOP_COMMAND_CHAIN_VERIFIED"] == "1"



def test_stable_dispatcher_management_does_not_create_a_host_entry_receipt() -> None:
    """A diagnostic arm must not masquerade as a Desktop UserPromptSubmit event."""

    with tempfile.TemporaryDirectory(prefix="super-brain-stable-dispatcher-management-") as directory:
        sandbox = Path(directory)
        codex_home = sandbox / "codex-home"
        state_root = sandbox / "state"
        launcher = ROOT / "runtime" / "codex_prompt_hook_launcher.py"
        fallback = ROOT / "scripts" / "codex-user-prompt-hook.ps1"
        binding = {
            "packageRoot": str(ROOT),
            "generation": "hg-" + "7" * 64,
            "_launcherPath": str(launcher),
            "_fallbackPath": str(fallback),
        }
        with (
            patch.object(stable_prompt_hook_dispatcher, "_binding", return_value=binding),
            patch.object(stable_prompt_hook_dispatcher, "_state_root", return_value=state_root),
            patch.object(stable_prompt_hook_dispatcher, "_expected_generation", return_value=binding["generation"]),
            patch.object(stable_prompt_hook_dispatcher, "_write_entry", side_effect=AssertionError("management must not write a host entry")),
            patch.object(stable_prompt_hook_dispatcher.subprocess, "call", return_value=0),
            patch.object(
                stable_prompt_hook_dispatcher.sys,
                "argv",
                [
                    "codex_prompt_hook_dispatcher.py",
                    "--codex-home",
                    str(codex_home),
                    "--arm-diagnostic",
                    "--arm-workspace-key",
                    "ws-management",
                ],
            ),
        ):
            assert stable_prompt_hook_dispatcher.main() == 0
        entry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "handler-last-entry.json"
        assert not entry_path.exists()
        assert not (state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "dispatcher-last-launch.json").exists()


def test_native_prompt_hook_binds_handler_generation_to_trace_receipt_and_telemetry() -> None:
    """P7 evidence identifies the exact stable handler generation that processed the real turn."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-handler-generation-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "4" * 24
        session_key = "sid-" + "5" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        scope = native_prompt_hook._diagnostic_scope_from_contract(contract, session_key, workspace_key)
        assert scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="bind P7 evidence to the stable handler generation",
            ttl_seconds=300,
            arm_id="handler-generation-arm",
        )
        generation = "hg-" + "6" * 64
        with patch.dict(
            os.environ,
            {
                "SUPER_BRAIN_HOOK_HANDLER_GENERATION": generation,
                "SUPER_BRAIN_HOOK_EXPECTED_GENERATION": generation,
                "SUPER_BRAIN_HOOK_ENTRYPOINT": "stable_dispatcher",
                "SUPER_BRAIN_HOOK_DISPATCH_LAUNCH_ID": "a" * 32,
                "SUPER_BRAIN_HOOK_DESKTOP_COMMAND_CHAIN_VERIFIED": "1",
                "SUPER_BRAIN_HOOK_HOST_PROCESS_SOURCE": "desktop_windows_command_chain",
            },
        ):
            _, telemetry, _ = _invoke_native_hook(state_root, workspace_key, session_key, "continue release archive")

        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        trace = json.loads((diagnostic_root / "entry-traces" / f"{arm['armId']}.json").read_text(encoding="utf-8"))
        receipt = json.loads((diagnostic_root / "receipts" / f"{arm['armId']}.json").read_text(encoding="utf-8"))
        expected = {
            "schema": "super-brain.prompt-hook-handler-provenance.v1",
            "generation": generation,
            "expectedGeneration": generation,
            "generationMatches": True,
            "entrypoint": "stable_dispatcher",
            "rawPromptStored": False,
            "rawSessionIdStored": False,
        }
        assert trace["handlerProvenance"] == expected
        assert receipt["handlerProvenance"] == expected
        assert telemetry["handlerProvenance"] == expected
        expected_launch_link = {
            "schema": "super-brain.prompt-hook-dispatch-link.v1",
            "launchId": "a" * 32,
            "launchIdValid": True,
            "desktopCommandChainVerified": True,
            "hostProcessSource": "desktop_windows_command_chain",
            "rawPromptStored": False,
            "rawSessionIdStored": False,
            "memoryBodyStored": False,
        }
        assert trace["dispatcherLaunch"] == expected_launch_link
        assert receipt["dispatcherLaunch"] == expected_launch_link
        assert telemetry["dispatcherLaunch"] == expected_launch_link
        assert trace["scopeRef"] == native_prompt_hook._canonical_hash(scope)
        assert telemetry["p7Diagnostic"] == {"armId": arm["armId"], "scopeRef": native_prompt_hook._canonical_hash(scope)}
        telemetry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry" / f"{session_key}--{workspace_key}.json"
        telemetry_relative_path = telemetry_path.relative_to(state_root / "workspace").as_posix()
        assert receipt["telemetryRelativePathHash"] == native_prompt_hook._canonical_hash({"telemetryRelativePath": telemetry_relative_path})
        assert receipt["telemetryPayloadHash"] == telemetry["payloadHash"]


def test_cached_direct_native_command_hands_off_to_the_installed_stable_dispatcher() -> None:
    """A live Desktop Host holding the pre-dispatcher command upgrades without reading a new hooks.json."""

    with tempfile.TemporaryDirectory(prefix="super-brain-cached-native-handoff-") as directory:
        sandbox = Path(directory)
        state_root = sandbox / "state"
        codex_home = sandbox / "codex-home"
        stable_root = codex_home / "hooks" / "super-memory-brain"
        stable_dispatcher = stable_root / "codex_prompt_hook_dispatcher.py"
        skill_root = codex_home / "skills" / "super-memory-brain"
        stable_root.mkdir(parents=True, exist_ok=True)
        skill_root.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "runtime" / "codex_prompt_hook_dispatcher.py", stable_dispatcher)
        (skill_root / "package-root.txt").write_text(str(ROOT), encoding="utf-8")
        (skill_root / "memory-root.txt").write_text(str(state_root / "shared"), encoding="utf-8")
        description = _describe_dispatcher(stable_dispatcher, codex_home)
        (stable_root / "handler.json").write_text(json.dumps(description, ensure_ascii=False), encoding="utf-8")
        workspace_key = "ws-" + "7" * 24
        session_key = "sid-" + "8" * 24
        _write_active_native_contract(state_root, workspace_key, session_key)
        environment = os.environ.copy()
        environment.pop("SUPER_BRAIN_HOOK_DISPATCHED", None)
        environment.pop("SUPER_BRAIN_HOOK_HANDLER_GENERATION", None)
        environment.pop("SUPER_BRAIN_HOOK_EXPECTED_GENERATION", None)
        environment.pop("SUPER_BRAIN_HOOK_ENTRYPOINT", None)
        environment["CODEX_HOME"] = str(codex_home)
        environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
        environment["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        completed = subprocess.run(
            [
                sys.executable,
                "-X",
                "utf8",
                "-B",
                str(ROOT / "runtime" / "codex_prompt_hook.py"),
                "--package-root",
                str(ROOT),
                "--fallback-hook",
                str(ROOT / "scripts" / "codex-user-prompt-hook.ps1"),
            ],
            input=json.dumps({"session_id": session_key, "prompt": "continue release archive"}).encode("utf-8"),
            capture_output=True,
            env=environment,
            check=False,
            timeout=10,
        )
        assert completed.returncode == 0, completed.stderr.decode("utf-8", errors="replace")
        telemetry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry" / f"{session_key}--{workspace_key}.json"
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        assert telemetry["handlerProvenance"]["entrypoint"] == "stable_dispatcher"
        assert telemetry["handlerProvenance"]["generation"] == description["generation"]
        entry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "handler-last-entry.json"
        assert not entry_path.exists(), "a cached direct-native CLI handoff is not proof of a Desktop user event"


def test_native_prompt_hook_one_shot_dispatch_receipt_is_metadata_only() -> None:
    """A short-lived arm distinguishes a host delivery from an early return without storing input."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-dispatch-receipt-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "e" * 24
        session_key = "sid-" + "f" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        scope = native_prompt_hook._diagnostic_scope_from_contract(
            json.loads(contract_path.read_text(encoding="utf-8")), session_key, workspace_key
        )
        assert scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="test scoped metadata-only receipt",
            ttl_seconds=300,
            arm_id="test-dispatch-arm",
        )

        sentinel = "ONE_SHOT_DISPATCH_SECRET_SENTINEL"
        _invoke_native_hook(state_root, workspace_key, session_key, f"continue release archive {sentinel}")

        receipt_path = diagnostic_root / "receipts" / f"{arm['armId']}.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert receipt["schema"] == "super-brain.prompt-hook-dispatch-diagnostic-receipt.v2"
        assert receipt["consumeState"] == "committed"
        assert receipt["stage"] == "native_telemetry_written"
        assert receipt["recognizedPromptField"] == "prompt"
        assert receipt["recognizedSessionField"] == "session_id"
        assert receipt["nativeTelemetryWritten"] is True
        assert receipt["rawPromptStored"] is False
        assert receipt["rawSessionIdStored"] is False
        assert receipt["memoryBodyStored"] is False
        assert not arm_path.exists()
        serialized = json.dumps(receipt, ensure_ascii=False)
        assert sentinel not in serialized
        assert session_key not in serialized


def test_native_prompt_hook_diagnostic_arm_is_task_owned_and_foreign_turn_cannot_consume_or_replace_it() -> None:
    """A parallel task cannot overwrite or consume the active P7 diagnostic arm."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-owned-dispatch-arm-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "6" * 24
        owner_session = "sid-" + "7" * 24
        foreign_session = "sid-" + "8" * 24
        owner_task, owner_contract_path = _write_active_native_contract(
            state_root,
            workspace_key,
            owner_session,
            task_id="task-owned-native-prompt-hook",
            task_instance_id="instance-owned-native-prompt-hook",
        )
        _write_active_native_contract(
            state_root,
            workspace_key,
            foreign_session,
            task_id="task-foreign-native-prompt-hook",
            task_instance_id="instance-foreign-native-prompt-hook",
        )
        owner_contract = json.loads(owner_contract_path.read_text(encoding="utf-8"))
        owner_scope = native_prompt_hook._diagnostic_scope_from_contract(owner_contract, owner_session, workspace_key)
        assert owner_scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=owner_scope,
            reason="verify owner-only P7 injection",
            ttl_seconds=300,
            arm_id="owned-p7-arm",
        )
        arm_path = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "one-shot-dispatch-arm.json"
        before = arm_path.read_bytes()

        foreign_scope = {
            "workspaceKey": workspace_key,
            "ownerSessionKey": foreign_session,
            "taskId": "task-foreign-native-prompt-hook",
            "taskInstanceId": "instance-foreign-native-prompt-hook",
            "contractRevision": 3,
        }
        try:
            native_prompt_hook._arm_one_shot_dispatch_diagnostic(
                state_root,
                scope=foreign_scope,
                reason="foreign task must not replace owner arm",
                ttl_seconds=300,
                arm_id="foreign-p7-arm",
            )
            raise AssertionError("foreign diagnostic armer unexpectedly replaced the owner arm")
        except native_prompt_hook.PromptHookDiagnosticError as error:
            assert error.code == "PROMPT_HOOK_DIAGNOSTIC_ARM_ACTIVE_FOREIGN_OWNER"
        assert arm_path.read_bytes() == before

        try:
            native_prompt_hook._arm_one_shot_dispatch_diagnostic(
                state_root,
                scope=owner_scope,
                reason="owner must not silently refresh an active arm",
                ttl_seconds=300,
                arm_id="owned-p7-arm-retry",
            )
            raise AssertionError("owner diagnostic armer unexpectedly refreshed an active arm")
        except native_prompt_hook.PromptHookDiagnosticError as error:
            assert error.code == "PROMPT_HOOK_DIAGNOSTIC_ARM_ALREADY_ACTIVE"
        assert arm_path.read_bytes() == before

        _invoke_native_hook(state_root, workspace_key, foreign_session, "continue release archive")
        assert arm_path.read_bytes() == before
        receipt_path = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "receipts" / f"{arm['armId']}.json"
        assert not receipt_path.exists()

        _invoke_native_hook(state_root, workspace_key, owner_session, "continue release archive")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert receipt["armId"] == arm["armId"]
        assert receipt["consumeState"] == "committed"
        assert receipt["stage"] == "native_telemetry_written"
        assert not arm_path.exists()


def test_native_prompt_hook_diagnostic_receipt_is_recoverable_without_a_prepared_orphan() -> None:
    """A failed consume leaves a durable claim, never an arm-less prepared receipt."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-diagnostic-receipt-unlink-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "a" * 24
        session_key = "sid-" + "b" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        scope = native_prompt_hook._diagnostic_scope_from_contract(
            json.loads(contract_path.read_text(encoding="utf-8")), session_key, workspace_key
        )
        assert scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="test prepared receipt after arm unlink failure",
            ttl_seconds=300,
            arm_id="prepared-receipt-arm",
        )
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        receipt_path = diagnostic_root / "receipts" / f"{arm['armId']}.json"
        pointer_path = diagnostic_root / "last-one-shot-dispatch-receipt.json"
        claim_path = diagnostic_root / "claims" / f"{arm['armId']}.json"
        original_unlink = Path.unlink

        def fail_only_the_arm(path: Path, *args: object, **kwargs: object) -> None:
            if path == arm_path:
                raise OSError("fixture arm unlink failure")
            original_unlink(path, *args, **kwargs)

        with patch.object(Path, "unlink", autospec=True, side_effect=fail_only_the_arm):
            assert native_prompt_hook._write_one_shot_dispatch_diagnostic_receipt(
                state_root,
                arm,
                scope=scope,
                stage="native_telemetry_written",
                raw='{"session_id":"fixture","prompt":"continue release archive"}',
                payload={"session_id": session_key, "prompt": "continue release archive"},
                session_key=session_key,
                workspace_key=workspace_key,
                native_telemetry_written=True,
            ) is False

        assert not receipt_path.exists()
        assert arm_path.exists()
        assert not pointer_path.exists()
        assert claim_path.exists()
        assert native_prompt_hook._recover_one_shot_dispatch_diagnostic_claims(state_root) is True
        committed = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert committed["consumeState"] == "committed"
        assert not arm_path.exists()
        assert not claim_path.exists()

    with tempfile.TemporaryDirectory(prefix="super-brain-native-diagnostic-receipt-pointer-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "c" * 24
        session_key = "sid-" + "d" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        scope = native_prompt_hook._diagnostic_scope_from_contract(
            json.loads(contract_path.read_text(encoding="utf-8")), session_key, workspace_key
        )
        assert scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="test compatibility pointer failure after committed receipt",
            ttl_seconds=300,
            arm_id="committed-receipt-arm",
        )
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        receipt_path = diagnostic_root / "receipts" / f"{arm['armId']}.json"
        pointer_path = diagnostic_root / "last-one-shot-dispatch-receipt.json"
        original_atomic_json = native_prompt_hook._atomic_json

        def fail_only_the_pointer(path: Path, value: object) -> None:
            if path == pointer_path:
                raise OSError("fixture compatibility pointer failure")
            original_atomic_json(path, value)

        with patch.object(native_prompt_hook, "_atomic_json", side_effect=fail_only_the_pointer):
            assert native_prompt_hook._write_one_shot_dispatch_diagnostic_receipt(
                state_root,
                arm,
                scope=scope,
                stage="native_telemetry_written",
                raw='{"session_id":"fixture","prompt":"continue release archive"}',
                payload={"session_id": session_key, "prompt": "continue release archive"},
                session_key=session_key,
                workspace_key=workspace_key,
                native_telemetry_written=True,
            ) is True

        committed = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert committed["consumeState"] == "committed"
        assert not arm_path.exists()
        assert not pointer_path.exists()

    with tempfile.TemporaryDirectory(prefix="super-brain-native-diagnostic-receipt-commit-recovery-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "e" * 24
        session_key = "sid-" + "f" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        scope = native_prompt_hook._diagnostic_scope_from_contract(
            json.loads(contract_path.read_text(encoding="utf-8")), session_key, workspace_key
        )
        assert scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="recover a committed receipt after the arm claim has moved",
            ttl_seconds=300,
            arm_id="commit-recovery-arm",
        )
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        receipt_path = diagnostic_root / "receipts" / f"{arm['armId']}.json"
        claim_path = diagnostic_root / "claims" / f"{arm['armId']}.json"
        original_atomic_json = native_prompt_hook._atomic_json
        first_write = True

        def fail_the_first_committed_receipt(path: Path, value: object) -> None:
            nonlocal first_write
            if path == receipt_path and first_write:
                first_write = False
                raise OSError("fixture committed receipt write failure")
            original_atomic_json(path, value)

        first_raw = '{"session_id":"fixture","prompt":"continue release archive first"}'
        with patch.object(native_prompt_hook, "_atomic_json", side_effect=fail_the_first_committed_receipt):
            assert native_prompt_hook._write_one_shot_dispatch_diagnostic_receipt(
                state_root,
                arm,
                scope=scope,
                stage="native_telemetry_written",
                raw=first_raw,
                payload={"session_id": session_key, "prompt": "continue release archive first"},
                session_key=session_key,
                workspace_key=workspace_key,
                native_telemetry_written=True,
            ) is False

        assert not arm_path.exists()
        assert not receipt_path.exists()
        assert claim_path.exists()
        assert native_prompt_hook._recover_one_shot_dispatch_diagnostic_claims(state_root) is True
        committed = json.loads(receipt_path.read_text(encoding="utf-8"))
        assert committed["consumeState"] == "committed"
        assert committed["stdinCharCount"] == len(first_raw)
        assert not arm_path.exists()
        assert not claim_path.exists()
        assert native_prompt_hook._write_one_shot_dispatch_diagnostic_receipt(
            state_root,
            arm,
            scope=scope,
            stage="payload_json_invalid",
            raw="{}",
        ) is False
        assert json.loads(receipt_path.read_text(encoding="utf-8"))["stdinCharCount"] == len(first_raw)


def test_native_prompt_hook_diagnostic_default_ttl_allows_human_desktop_response_delay() -> None:
    """P7 arms must not expire during an ordinary delayed Desktop response."""

    assert native_prompt_hook.ONE_SHOT_DISPATCH_DIAGNOSTIC_DEFAULT_TTL_SECONDS == 60 * 60
    assert native_prompt_hook.ONE_SHOT_DISPATCH_DIAGNOSTIC_MAX_TTL_SECONDS == 2 * 60 * 60

    with tempfile.TemporaryDirectory(prefix="super-brain-native-diagnostic-default-ttl-") as directory:
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            Path(directory),
            scope={
                "workspaceKey": "ws-" + "d" * 24,
                "ownerSessionKey": "sid-" + "e" * 24,
                "taskId": "task-default-ttl",
                "taskInstanceId": "instance-default-ttl",
                "contractRevision": 3,
            },
            reason="verify P7 human response window",
        )
        expiry = datetime.fromisoformat(str(arm["expiresAt"]).replace("Z", "+00:00"))
        remaining_seconds = (expiry - datetime.now(timezone.utc)).total_seconds()
        assert 55 * 60 <= remaining_seconds <= 60 * 60


def test_native_prompt_hook_cli_arms_a_scoped_diagnostic_slot_and_refuses_a_foreign_owner() -> None:
    """The supported arming command is the only writer path used by P7 workflows."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-diagnostic-armer-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "9" * 24
        owner_session = "sid-" + "a" * 24
        foreign_session = "sid-" + "b" * 24
        _write_active_native_contract(
            state_root,
            workspace_key,
            owner_session,
            task_id="task-cli-owner",
            task_instance_id="instance-cli-owner",
        )
        _write_active_native_contract(
            state_root,
            workspace_key,
            foreign_session,
            task_id="task-cli-foreign",
            task_instance_id="instance-cli-foreign",
        )
        environment = os.environ.copy()
        environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
        environment["CODEX_THREAD_ID"] = owner_session
        base_command = [
            sys.executable,
            "-X",
            "utf8",
            "-B",
            str(ROOT / "runtime" / "codex_prompt_hook.py"),
            "--package-root",
            str(ROOT),
            "--arm-diagnostic",
            "--arm-workspace-key",
            workspace_key,
            "--arm-owner-session-key",
            owner_session,
            "--arm-task-id",
            "task-cli-owner",
            "--arm-task-instance-id",
            "instance-cli-owner",
            "--arm-contract-revision",
            "3",
            "--arm-reason",
            "verify supported scoped P7 arming",
            "--arm-ttl-seconds",
            "300",
        ]
        arm_path = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "one-shot-dispatch-arm.json"

        missing_contract = list(base_command)
        missing_contract[missing_contract.index("task-cli-owner")] = "task-cli-missing"
        missing = subprocess.run(missing_contract, capture_output=True, env=environment, check=False, timeout=10)
        assert missing.returncode == 2
        assert json.loads(missing.stdout.decode("utf-8")) == {
            "ok": False,
            "code": "PROMPT_HOOK_DIAGNOSTIC_SCOPE_UNVERIFIED",
        }
        assert not arm_path.exists()

        wrong_instance = list(base_command)
        wrong_instance[wrong_instance.index("instance-cli-owner")] = "instance-cli-wrong"
        mismatch = subprocess.run(wrong_instance, capture_output=True, env=environment, check=False, timeout=10)
        assert mismatch.returncode == 2
        assert json.loads(mismatch.stdout.decode("utf-8")) == {
            "ok": False,
            "code": "PROMPT_HOOK_DIAGNOSTIC_SCOPE_UNVERIFIED",
        }
        assert not arm_path.exists()

        wrong_revision = list(base_command)
        wrong_revision[wrong_revision.index("3")] = "4"
        stale = subprocess.run(wrong_revision, capture_output=True, env=environment, check=False, timeout=10)
        assert stale.returncode == 2
        assert json.loads(stale.stdout.decode("utf-8")) == {
            "ok": False,
            "code": "PROMPT_HOOK_DIAGNOSTIC_SCOPE_UNVERIFIED",
        }
        assert not arm_path.exists()

        foreign_environment = dict(environment)
        foreign_environment["CODEX_THREAD_ID"] = foreign_session
        forged_owner = subprocess.run(base_command, capture_output=True, env=foreign_environment, check=False, timeout=10)
        assert forged_owner.returncode == 2
        assert json.loads(forged_owner.stdout.decode("utf-8")) == {
            "ok": False,
            "code": "PROMPT_HOOK_DIAGNOSTIC_CALLER_SESSION_MISMATCH",
        }
        assert not arm_path.exists()

        owner = subprocess.run(base_command, capture_output=True, env=environment, check=False, timeout=10)
        assert owner.returncode == 0, owner.stderr.decode("utf-8", errors="replace")
        owner_result = json.loads(owner.stdout.decode("utf-8"))
        assert owner_result["ok"] is True and owner_result["schema"] == "super-brain.prompt-hook-dispatch-diagnostic-arm.v2"

        foreign_command = list(base_command)
        foreign_command[foreign_command.index(owner_session)] = foreign_session
        foreign_command[foreign_command.index("task-cli-owner")] = "task-cli-foreign"
        foreign_command[foreign_command.index("instance-cli-owner")] = "instance-cli-foreign"
        foreign = subprocess.run(foreign_command, capture_output=True, env=foreign_environment, check=False, timeout=10)
        assert foreign.returncode == 2
        assert json.loads(foreign.stdout.decode("utf-8")) == {
            "ok": False,
            "code": "PROMPT_HOOK_DIAGNOSTIC_ARM_ACTIVE_FOREIGN_OWNER",
        }


def test_native_prompt_hook_armer_io_failure_is_machine_readable() -> None:
    """Arming must never fall through the host's fail-open output contract."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-diagnostic-armer-io-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "e" * 24
        session_key = "sid-" + "f" * 24
        _write_active_native_contract(
            state_root,
            workspace_key,
            session_key,
            task_id="task-cli-io",
            task_instance_id="instance-cli-io",
        )
        argv = [
            "codex_prompt_hook.py",
            "--package-root",
            str(ROOT),
            "--arm-diagnostic",
            "--arm-workspace-key",
            workspace_key,
            "--arm-owner-session-key",
            session_key,
            "--arm-task-id",
            "task-cli-io",
            "--arm-task-instance-id",
            "instance-cli-io",
            "--arm-contract-revision",
            "3",
            "--arm-reason",
            "verify armer I/O error output",
        ]
        output = io.StringIO()
        with (
            patch.dict(os.environ, {"SUPER_BRAIN_STATE_ROOT": str(state_root), "CODEX_THREAD_ID": session_key}),
            patch.object(native_prompt_hook.sys, "argv", argv),
            patch.object(native_prompt_hook, "_atomic_json", side_effect=OSError("fixture armer I/O failure")),
            redirect_stdout(output),
        ):
            assert native_prompt_hook._run_main_safely() == 2

        assert json.loads(output.getvalue()) == {
            "ok": False,
            "code": "PROMPT_HOOK_DIAGNOSTIC_ARM_IO_FAILED",
        }
        assert not (state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics" / "one-shot-dispatch-arm.json").exists()


def test_native_prompt_hook_verified_arm_scope_checks_contract_owner_binding() -> None:
    """The contract itself must agree with the full scope, not merely its file/index locator."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-diagnostic-contract-scope-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "1" * 24
        session_key = "sid-" + "2" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        scope = native_prompt_hook._diagnostic_scope_from_contract(contract, session_key, workspace_key)
        assert scope is not None
        assert native_prompt_hook._verified_diagnostic_arm_scope(ROOT, state_root, scope) == scope

        contract["ownerSessionKey"] = "sid-" + "3" * 24
        _write_json(contract_path, contract)
        assert native_prompt_hook._verified_diagnostic_arm_scope(ROOT, state_root, scope) is None


def test_native_prompt_hook_ignores_a_legacy_unscoped_arm() -> None:
    """A legacy v1 arm cannot silently become evidence for a scoped P7 task."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-legacy-unscoped-arm-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "c" * 24
        session_key = "sid-" + "d" * 24
        _write_active_native_contract(state_root, workspace_key, session_key)
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        _write_json(
            arm_path,
            {
                "schema": "super-brain.prompt-hook-dispatch-diagnostic-arm.v1",
                "armId": "legacy-unscoped-arm",
                "expiresAt": (datetime.now(timezone.utc) + timedelta(minutes=5)).isoformat().replace("+00:00", "Z"),
                "reason": "legacy arm must not be consumed",
                "rawPromptStored": False,
            },
        )
        before = arm_path.read_bytes()
        _invoke_native_hook(state_root, workspace_key, session_key, "continue release archive")
        assert arm_path.read_bytes() == before
        assert not (diagnostic_root / "receipts" / "legacy-unscoped-arm.json").exists()


def test_legacy_cached_hook_path_delegates_to_core_runtime() -> None:
    """Both historical Python command names remain usable after the package layout move."""

    for index, entrypoint_name in enumerate(("codex_prompt_hook.py", "codex_prompt_hook_launcher.py")):
        wrapper = PACKAGE_ROOT / "runtime" / entrypoint_name
        assert wrapper.is_file(), entrypoint_name
        with tempfile.TemporaryDirectory(prefix=f"super-brain-legacy-cached-hook-{index}-") as directory:
            state_root = Path(directory)
            workspace_key = "ws-" + ("a" if index == 0 else "d") * 24
            session_key = "sid-" + ("b" if index == 0 else "e") * 24
            _write_active_native_contract(state_root, workspace_key, session_key)

            output, telemetry, elapsed_ms = _invoke_legacy_cached_hook(
                state_root,
                workspace_key,
                session_key,
                "continue release archive",
                entrypoint_name,
            )

            assert "EXECUTION_CONTRACT_PENDING:" in _context(output)
            assert telemetry["routeSignalMode"] == "native"
            assert telemetry["scope"]["ownerSessionKey"] == session_key
            assert elapsed_ms < 1500


def test_legacy_cached_powershell_hook_path_delegates_to_core_runtime() -> None:
    """A pre-CORE PowerShell handler remains a valid native bridge after the move."""

    wrapper = PACKAGE_ROOT / "scripts" / "codex-user-prompt-hook.ps1"
    assert wrapper.is_file()
    with tempfile.TemporaryDirectory(prefix="super-brain-legacy-powershell-hook-") as directory:
        state_root = Path(directory)
        codex_home = state_root / "isolated-codex-home"
        workspace_key = "ws-" + "b" * 24
        session_key = "sid-" + "c" * 24
        _write_active_native_contract(state_root, workspace_key, session_key)
        environment = os.environ.copy()
        environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
        environment["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        environment["CODEX_HOME"] = str(codex_home)
        completed = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(wrapper)],
            input=json.dumps({"session_id": session_key, "prompt": "continue release archive"}).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
            timeout=10,
        )

        assert completed.returncode == 0, completed.stderr.decode("utf-8", errors="replace")
        output = json.loads(completed.stdout.decode("utf-8"))
        assert "EXECUTION_CONTRACT_PENDING:" in _context(output)
        telemetry_path = state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry" / f"{session_key}--{workspace_key}.json"
        telemetry = json.loads(telemetry_path.read_text(encoding="utf-8"))
        assert telemetry["routeSignalMode"] == "native"
        assert telemetry["scope"]["ownerSessionKey"] == session_key


def test_native_prompt_hook_accepts_utf8_bom_contract_and_hot_index() -> None:
    """Runtime state written with a UTF-8 BOM must still reach native telemetry."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-bom-runtime-state-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "d" * 24
        session_key = "sid-" + "e" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        hot_index_path = (
            state_root
            / "workspace"
            / "runtime-state"
            / "execution-hot-index"
            / f"{session_key}--{workspace_key}.json"
        )
        for path in (contract_path, hot_index_path):
            path.write_text(path.read_text(encoding="utf-8"), encoding="utf-8-sig")

        output, telemetry, elapsed_ms = _invoke_native_hook(
            state_root,
            workspace_key,
            session_key,
            "continue release archive",
        )

        assert "EXECUTION_CONTRACT_PENDING:" in _context(output)
        assert telemetry["routeSignalMode"] == "native"
        assert telemetry["scope"]["ownerSessionKey"] == session_key
        assert elapsed_ms < 1500


def test_expired_one_shot_dispatch_arm_is_inert() -> None:
    """A stale diagnostic file is inert and only a formal armer may replace it."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-expired-dispatch-arm-") as directory:
        state_root = Path(directory)
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        scope = {
            "workspaceKey": "ws-" + "a" * 24,
            "ownerSessionKey": "sid-" + "b" * 24,
            "taskId": "task-expired-dispatch-arm",
            "taskInstanceId": "instance-expired-dispatch-arm",
            "contractRevision": 1,
        }
        native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="test expired arm cleanup",
            ttl_seconds=300,
            arm_id="expired-dispatch-arm",
        )
        arm = json.loads(arm_path.read_text(encoding="utf-8"))
        arm["expiresAt"] = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat().replace("+00:00", "Z")
        _write_json(arm_path, arm)

        assert native_prompt_hook._read_one_shot_dispatch_diagnostic_arm(state_root) is None
        assert arm_path.exists()


def test_native_prompt_hook_entry_trace_is_metadata_only_and_never_consumes_arm() -> None:
    """A process-start trace distinguishes hook launch from receipt acceptance without retaining input."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-entry-trace-metadata-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "e" * 24
        session_key = "sid-" + "f" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        scope = native_prompt_hook._diagnostic_scope_from_contract(
            json.loads(contract_path.read_text(encoding="utf-8")), session_key, workspace_key
        )
        assert scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="test metadata-only process entry trace",
            ttl_seconds=300,
            arm_id="entry-trace-metadata-arm",
        )
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        trace_path = diagnostic_root / "entry-traces" / f"{arm['armId']}.json"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        receipt_path = diagnostic_root / "receipts" / f"{arm['armId']}.json"
        pointer_path = diagnostic_root / "last-one-shot-dispatch-receipt.json"
        reader_called = False

        def invalid_reader() -> str:
            nonlocal reader_called
            reader_called = True
            assert trace_path.exists()
            assert arm_path.exists()
            assert not receipt_path.exists()
            assert not pointer_path.exists()
            return '{"prompt":"ENTRY_TRACE_SECRET_SENTINEL"'

        output = io.StringIO()
        argv = ["codex_prompt_hook.py", "--package-root", str(ROOT)]
        with (
            patch.dict(os.environ, {"SUPER_BRAIN_STATE_ROOT": str(state_root), "SUPER_BRAIN_WORKSPACE_KEY": workspace_key}),
            patch.object(native_prompt_hook.sys, "argv", argv),
            patch.object(native_prompt_hook, "_read_hook_stdin", side_effect=invalid_reader),
            redirect_stdout(output),
        ):
            assert native_prompt_hook.main() == 0

        assert reader_called is True
        assert json.loads(output.getvalue()) == {
            "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}
        }
        trace = json.loads(trace_path.read_text(encoding="utf-8"))
        assert trace == {
            "schema": "super-brain.prompt-hook-entry-trace.v1",
            "armId": arm["armId"],
            "scopeRef": native_prompt_hook._canonical_hash(scope),
            "stage": "runtime_entered_pre_stdin",
            "handlerProvenance": {
                "schema": "super-brain.prompt-hook-handler-provenance.v1",
                "generation": "unmanaged",
                "expectedGeneration": "",
                "generationMatches": False,
                "entrypoint": "direct_native",
                "rawPromptStored": False,
                "rawSessionIdStored": False,
            },
            "dispatcherLaunch": {
                "schema": "super-brain.prompt-hook-dispatch-link.v1",
                "launchId": "",
                "launchIdValid": False,
                "desktopCommandChainVerified": False,
                "hostProcessSource": "unverified",
                "rawPromptStored": False,
                "rawSessionIdStored": False,
                "memoryBodyStored": False,
            },
            "rawPromptStored": False,
            "rawSessionIdStored": False,
            "memoryBodyStored": False,
            "p7AcceptanceEligible": False,
        } | {"observedAt": trace["observedAt"]}
        serialized = json.dumps(trace, ensure_ascii=False)
        assert session_key not in serialized
        assert "ENTRY_TRACE_SECRET_SENTINEL" not in serialized
        assert arm_path.exists()
        assert not receipt_path.exists()
        assert not pointer_path.exists()


def test_native_prompt_hook_entry_trace_io_failure_is_fail_open() -> None:
    """A trace write failure cannot block stdin handling or consume the P7 arm."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-entry-trace-io-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "1" * 24
        session_key = "sid-" + "2" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        scope = native_prompt_hook._diagnostic_scope_from_contract(
            json.loads(contract_path.read_text(encoding="utf-8")), session_key, workspace_key
        )
        assert scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="test entry trace I/O failure stays fail-open",
            ttl_seconds=300,
            arm_id="entry-trace-io-arm",
        )
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        trace_path = diagnostic_root / "entry-traces" / f"{arm['armId']}.json"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        reader_called = False
        original_atomic_json = native_prompt_hook._atomic_json

        for error_type in (OSError, RuntimeError):
            def fail_only_the_trace(path: Path, value: object, *, _error_type: type[Exception] = error_type) -> None:
                if path == trace_path:
                    raise _error_type("fixture entry trace write failure")
                original_atomic_json(path, value)

            def invalid_reader() -> str:
                nonlocal reader_called
                reader_called = True
                return "{"

            output = io.StringIO()
            argv = ["codex_prompt_hook.py", "--package-root", str(ROOT)]
            with (
                patch.dict(os.environ, {"SUPER_BRAIN_STATE_ROOT": str(state_root), "SUPER_BRAIN_WORKSPACE_KEY": workspace_key}),
                patch.object(native_prompt_hook.sys, "argv", argv),
                patch.object(native_prompt_hook, "_atomic_json", side_effect=fail_only_the_trace),
                patch.object(native_prompt_hook, "_read_hook_stdin", side_effect=invalid_reader),
                redirect_stdout(output),
            ):
                assert native_prompt_hook.main() == 0

            assert json.loads(output.getvalue()) == {
                "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}
            }
            assert not trace_path.exists()
            assert arm_path.exists()
            assert not (diagnostic_root / "receipts" / f"{arm['armId']}.json").exists()

        assert reader_called is True


def test_native_prompt_hook_scoped_arm_is_never_consumed_before_contract_owner_match() -> None:
    """A task-owned P7 arm is consumed only after stdin and contract scope validation."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-entry-trace-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "1" * 24
        session_key = "sid-" + "2" * 24
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        scope = native_prompt_hook._diagnostic_scope_from_contract(
            json.loads(contract_path.read_text(encoding="utf-8")), session_key, workspace_key
        )
        assert scope is not None
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="test post-read contract owner match",
            ttl_seconds=300,
            arm_id="test-entry-trace-arm",
        )

        sentinel = "ENTRY_TRACE_SECRET_SENTINEL"
        _invoke_native_hook(state_root, workspace_key, session_key, f"continue release archive {sentinel}")

        receipt = json.loads((diagnostic_root / "receipts" / f"{arm['armId']}.json").read_text(encoding="utf-8"))
        assert receipt["consumeState"] == "committed"
        assert receipt["stage"] == "native_telemetry_written"
        assert receipt["stdinReceived"] is True
        assert receipt["rawPromptStored"] is False
        assert sentinel not in json.dumps(receipt, ensure_ascii=False)
        assert not arm_path.exists()


def test_native_prompt_hook_does_not_wait_for_host_stdin_eof() -> None:
    """A Desktop-style open stdin pipe must not consume the host timeout."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-open-stdin-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "3" * 24
        session_key = "sid-" + "4" * 24
        _write_active_native_contract(state_root, workspace_key, session_key)

        output, telemetry, elapsed_ms = _invoke_native_hook_with_open_stdin(
            state_root,
            workspace_key,
            session_key,
            "continue release archive",
        )

        assert "EXECUTION_CONTRACT_PENDING:" in _context(output)
        assert telemetry["testObservationOnly"] is False
        assert elapsed_ms < 1500


def test_native_prompt_hook_runtime_exception_is_metadata_only_and_fail_open() -> None:
    """An exception before contract scope validation stays fail-open and preserves the owner arm."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-runtime-error-") as directory:
        state_root = Path(directory)
        diagnostic_root = state_root / "workspace" / "runtime-state" / "prompt-hook-diagnostics"
        arm_path = diagnostic_root / "one-shot-dispatch-arm.json"
        scope = {
            "workspaceKey": "ws-" + "c" * 24,
            "ownerSessionKey": "sid-" + "d" * 24,
            "taskId": "task-runtime-error-arm",
            "taskInstanceId": "instance-runtime-error-arm",
            "contractRevision": 1,
        }
        arm = native_prompt_hook._arm_one_shot_dispatch_diagnostic(
            state_root,
            scope=scope,
            reason="test runtime exception preserves owner arm",
            ttl_seconds=300,
            arm_id="test-runtime-error-arm",
        )

        argv = ["codex_prompt_hook.py", "--package-root", str(ROOT)]
        with patch.dict(os.environ, {"SUPER_BRAIN_STATE_ROOT": str(state_root)}), patch.object(native_prompt_hook.sys, "argv", argv), patch.object(native_prompt_hook, "main", side_effect=RuntimeError("fixture runtime failure")):
            assert native_prompt_hook._run_main_safely() == 0

        assert arm_path.exists()
        assert not (diagnostic_root / "receipts" / f"{arm['armId']}.json").exists()


def test_native_prompt_hook_fail_open_paths_emit_valid_empty_output() -> None:
    """Host-safe early returns still satisfy the hook output protocol."""

    command = [
        sys.executable,
        "-X",
        "utf8",
        "-B",
        str(ROOT / "runtime" / "codex_prompt_hook.py"),
        "--package-root",
        str(ROOT),
        "--test-prompt",
        "hello",
        "--test-session-id",
        "sid-empty-output",
    ]
    completed = subprocess.run(command, capture_output=True, env=os.environ.copy(), check=False, timeout=5)
    assert completed.returncode == 0, completed.stderr.decode("utf-8", errors="replace")
    output = json.loads(completed.stdout.decode("utf-8"))
    assert output == {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}}


def test_native_prompt_hook_output_is_utf8_safe_for_a_cached_non_utf8_command() -> None:
    """A stale Desktop command without ``-X utf8`` cannot turn Unicode context into exit 1."""

    environment = os.environ.copy()
    environment["PYTHONIOENCODING"] = "gbk"
    environment.pop("PYTHONUTF8", None)
    script = "\n".join(
        [
            "import sys",
            f"sys.path.insert(0, {str(ROOT / 'runtime')!r})",
            "import codex_prompt_hook as native_prompt_hook",
            "native_prompt_hook._emit_hook_output('\\ue200')",
        ]
    )
    completed = subprocess.run(
        [sys.executable, "-B", "-c", script],
        capture_output=True,
        env=environment,
        check=False,
        timeout=5,
    )

    assert completed.returncode == 0, completed.stderr.decode("utf-8", errors="replace")
    assert completed.stderr == b""
    assert json.loads(completed.stdout.decode("utf-8")) == {
        "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "\ue200"}
    }


def test_native_prompt_hook_legacy_fallback_failure_is_fail_open() -> None:
    """A slow or failed legacy fallback must never fail the Desktop hook."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-fallback-") as directory:
        fallback = Path(directory) / "legacy-fallback.ps1"
        fallback.write_text("# fixture", encoding="utf-8")
        failed = subprocess.CompletedProcess(
            args=["powershell.exe"],
            returncode=1,
            stdout=b"",
            stderr=b"fixture failure",
        )
        with patch.object(native_prompt_hook.subprocess, "run", return_value=failed) as invoked:
            assert native_prompt_hook._fallback(fallback, '{"prompt":"fixture"}') == 0
        assert invoked.call_args.kwargs["timeout"] < 3


def test_native_prompt_hook_accepts_bounded_mixed_confirmation_reply() -> None:
    """A compact bilingual confirmation can resume an already-bound native task."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-confirmation-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "c" * 24
        session_key = "sid-" + "d" * 24
        control = BrainControl(state_root)
        _create(control, "note", "confirmation-note", "Release archive reference", _payload("note"))
        _write_active_native_contract(state_root, workspace_key, session_key)

        output, telemetry, _ = _invoke_native_hook(state_root, workspace_key, session_key, "ok，是吧")

        assert telemetry["deliveryProvenance"]["origin"] == "configured_hook_stdin_unattested"
        assert telemetry["testObservationOnly"] is False
        assert telemetry["runtimeWake"]["memoryProjection"]["state"] == "injected"
        assert "MEMORY_REFERENCE:" in _context(output)


def test_native_prompt_hook_reserves_memory_budget_from_a_long_resume_packet() -> None:
    """Long continuity state must not starve qualified memory influence."""

    with tempfile.TemporaryDirectory(prefix="super-brain-native-long-resume-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "6" * 24
        session_key = "sid-" + "7" * 24
        control = BrainControl(state_root)
        _create(control, "note", "long-resume-note", "Release archive reference", _payload("note"))
        _, contract_path = _write_active_native_contract(state_root, workspace_key, session_key)
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        long_instruction = "continue release archive " + ("verified continuity detail " * 40)
        contract["latestUserInstruction"] = long_instruction
        contract["instructionAnchor"]["instruction"] = long_instruction
        contract["lastConfirmedSource"] = "assistant_commitment"
        contract["lastConfirmedSentence"] = "verified progress " + ("state detail " * 40)
        contract["focusId"] = "release-archive-" + ("focus-" * 30)
        contract["focusLabel"] = "Release archive " + ("continuity " * 30)
        contract["workLineStatus"] = {
            "mainLine": contract["focusId"],
            "activeLine": contract["focusId"],
            "userView": {
                "main": {"label": "Main " + ("release " * 30)},
                "current": {"label": "Current " + ("archive " * 30)},
            },
            "suspendedPlans": [{"focusLabel": "Suspended " + ("item " * 30)} for _ in range(3)],
            "unfinishedPlans": [{"focusLabel": "Unfinished " + ("item " * 30), "priority": {"executionRank": 2}} for _ in range(3)],
            "priorityOrder": [{"focusLabel": "Priority " + ("item " * 30), "executionRank": index + 1} for index in range(4)],
        }
        _write_json(contract_path, contract)

        packet = native_prompt_hook._resume_packet(
            contract,
            {"topicAffinity": "active", "confidence": "high", "targetLineId": contract["focusId"], "needsClarification": False},
            "continue release archive",
            560,
        )
        assert len(packet) <= 560

        output, telemetry, _ = _invoke_native_hook(state_root, workspace_key, session_key, "continue release archive")
        assert "MEMORY_REFERENCE:" in _context(output)
        assert telemetry["runtimeWake"]["memoryProjection"]["state"] == "injected"
        assert telemetry["executionContractCapture"]["contextBudget"]["memoryProjectionIncluded"] is True


def test_native_prompt_hook_reads_only_the_qualified_memory_snapshot() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-native-memory-hook-") as directory:
        state_root = Path(directory)
        workspace_key = "ws-" + "a" * 24
        session_key = "sid-" + "b" * 24
        control = BrainControl(state_root)

        for kind in ("preference", "experience", "procedure", "note", "reflection"):
            _create(control, kind, f"active-{kind}", f"Active {kind} release archive", _payload(kind))

        candidate = _payload("experience")
        candidate["lesson"] = "CANDIDATE_SENTINEL"
        candidate["validationState"] = "candidate"
        _create(control, "experience", "candidate-experience", "Candidate experience", candidate)

        expired = _payload("preference")
        expired["statement"] = "EXPIRED_SENTINEL"
        expired["revalidateAfter"] = "2000-01-01"
        _create(control, "preference", "expired-preference", "Expired preference", expired)

        foreign = _payload("note")
        foreign["body"] = "FOREIGN_SCOPE_SENTINEL"
        _create(control, "note", "foreign-note", "Foreign scope note", foreign, scope={"kind": "workspace", "key": "ws-" + "c" * 24})

        trashed = _payload("note")
        trashed["body"] = "TRASHED_SENTINEL"
        _create(control, "note", "trashed-note", "Trashed note", trashed)
        _transition(control, "trash_card", "trashed-note", 1)

        forgotten = _payload("note")
        forgotten["body"] = "FORGOTTEN_SENTINEL"
        _create(control, "note", "forgotten-note", "Forgotten note", forgotten)
        _transition(control, "forget_active", "forgotten-note", 1)

        _write_active_native_contract(state_root, workspace_key, session_key)
        snapshot_path = state_root / "workspace" / "native-memory-influence-snapshot.json"
        snapshot_text = snapshot_path.read_text(encoding="utf-8")
        valid_snapshot = json.loads(snapshot_text)
        for sentinel in ("CANDIDATE_SENTINEL", "EXPIRED_SENTINEL", "TRASHED_SENTINEL", "FORGOTTEN_SENTINEL"):
            assert sentinel not in snapshot_text

        raw_prompt = "continue prepare release archive USER_PROMPT_SENTINEL"
        output, telemetry, elapsed_ms = _invoke_native_hook(state_root, workspace_key, session_key, raw_prompt)
        context = _context(output)
        assert context.startswith("EXECUTION_CONTRACT_PENDING:")
        assert "EXECUTION_CONTRACT_RESUME_PACKET:" in context
        for marker in (
            "MEMORY_PREFERENCE:",
            "MEMORY_EXPERIENCE_ADVICE:",
            "MEMORY_PROCEDURE:",
            "MEMORY_REFERENCE:",
            "MEMORY_REFLECTION_CANDIDATE:",
        ):
            assert marker in context, context
        assert "non-binding" in context
        assert "MEMORY_DECISION_CONSTRAINT:" not in context
        for sentinel in ("CANDIDATE_SENTINEL", "EXPIRED_SENTINEL", "TRASHED_SENTINEL", "FORGOTTEN_SENTINEL", "FOREIGN_SCOPE_SENTINEL"):
            assert sentinel not in context
        assert telemetry["runtimeWake"]["memoryBodyLoaded"] is True
        projection = telemetry["runtimeWake"]["memoryProjection"]
        assert projection["state"] == "injected" and projection["injectedCount"] == 5
        assert projection["injectedCardRefs"] == [
            {"cardId": "active-preference", "cardRevision": 1, "kind": "preference"},
            {"cardId": "active-experience", "cardRevision": 1, "kind": "experience"},
            {"cardId": "active-procedure", "cardRevision": 1, "kind": "procedure"},
            {"cardId": "active-note", "cardRevision": 1, "kind": "note"},
            {"cardId": "active-reflection", "cardRevision": 1, "kind": "reflection"},
        ]
        assert telemetry["scope"] == {"workspaceKey": workspace_key, "ownerSessionKey": session_key, "taskId": "task-native-memory-prompt-hook"}
        assert telemetry["payloadHash"] == _snapshot_hash(telemetry)
        telemetry_text = json.dumps(telemetry, ensure_ascii=False)
        assert raw_prompt not in telemetry_text
        assert "USER_PROMPT_SENTINEL" not in telemetry_text
        assert "FORGOTTEN_SENTINEL" not in telemetry_text
        assert elapsed_ms < 1000

        retired = control.record_native_memory_learning_candidate(
            {
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "taskId": "task-native-memory-prompt-hook",
                "maxAgeMinutes": 30,
            }
        )
        assert retired == {
            "ok": True,
            "schema": "super-brain.native-memory-learning-candidate.v1",
            "status": "withheld",
            "code": "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_RETIRED_H7_REQUIRED",
            "replacement": "record-h7-memory-learning-candidate",
            "candidate": None,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
            "memoryBodyStored": False,
        }

        _invoke_native_hook(state_root, workspace_key, session_key, "continue prepare release archive", synthetic=True)
        retired_synthetic = control.record_native_memory_learning_candidate(
            {
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "taskId": "task-native-memory-prompt-hook",
                "maxAgeMinutes": 30,
            }
        )
        assert retired_synthetic["status"] == "withheld"
        assert retired_synthetic["code"] == "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_RETIRED_H7_REQUIRED"

        unsafe_snapshot = json.loads(json.dumps(valid_snapshot))
        unsafe_note = next(
            entry
            for entry in unsafe_snapshot["entries"]
            if entry["kind"] == "note" and entry["scopeKind"] == "global"
        )
        unsafe_note["item"]["body"] = "api_key=SECRET_MEMORY_BODY_SENTINEL"
        unsafe_snapshot["payloadHash"] = _snapshot_hash(unsafe_snapshot)
        _write_json(snapshot_path, unsafe_snapshot)
        output, telemetry, _ = _invoke_native_hook(state_root, workspace_key, session_key, "continue prepare release archive")
        assert "MEMORY_PREFERENCE:" not in _context(output)
        assert "SECRET_MEMORY_BODY_SENTINEL" not in _context(output)
        assert telemetry["runtimeWake"]["memoryProjection"]["state"] == "unsafe"
        assert "SECRET_MEMORY_BODY_SENTINEL" not in json.dumps(telemetry, ensure_ascii=False)

        corrupt_snapshot = json.loads(json.dumps(valid_snapshot))
        corrupt_snapshot["payloadHash"] = "0" * 64
        _write_json(snapshot_path, corrupt_snapshot)
        output, telemetry, _ = _invoke_native_hook(state_root, workspace_key, session_key, "continue prepare release archive")
        assert "MEMORY_PREFERENCE:" not in _context(output)
        assert telemetry["runtimeWake"]["memoryProjection"]["state"] == "hash_mismatch"

        _write_json(snapshot_path, valid_snapshot)

        dirty_path = state_root / "workspace" / "native-memory-influence-snapshot.dirty.json"
        _write_json(dirty_path, {"schema": "fixture"})
        output, telemetry, _ = _invoke_native_hook(state_root, workspace_key, session_key, "continue prepare release archive")
        assert "MEMORY_PREFERENCE:" not in _context(output)
        assert telemetry["runtimeWake"]["memoryProjection"]["state"] == "dirty"
        dirty_path.unlink()

        snapshot_path.write_bytes(b"{" + b"x" * (128 * 1024))
        output, telemetry, elapsed_ms = _invoke_native_hook(state_root, workspace_key, session_key, "continue prepare release archive")
        assert "MEMORY_PREFERENCE:" not in _context(output)
        assert telemetry["runtimeWake"]["memoryProjection"]["state"] == "oversize"
        assert elapsed_ms < 1000


def test_cognitive_enforce_captures_only_current_h7_note_use() -> None:
    """Completion learning requires current H7 evidence and never falls back to Hook telemetry."""

    with tempfile.TemporaryDirectory(prefix="super-brain-h7-learning-candidate-") as directory:
        state_root = Path(directory)
        host_root = state_root / "host-workspace"
        host_root.mkdir()
        workspace_key = "ws-" + hashlib.sha256(os.path.abspath(host_root).rstrip("/\\").lower().encode("utf-8")).hexdigest()[:24]
        session_key = "sid-" + "e" * 24
        task_id = "task-h7-learning-candidate"
        control = BrainControl(state_root)
        note = _payload("note")
        note["body"] = "Reference: H7 learning candidates must stay non-binding until the user adopts them."
        _create(control, "note", "learning-candidate-source", "H7 learning source", note)

        environment = os.environ.copy()
        environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
        environment["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        environment["CODEX_THREAD_ID"] = session_key
        contract = subprocess.run(
            [
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                str(ROOT / "scripts" / "execution-contract.ps1"),
                "-Action", "Set",
                "-TaskId", task_id,
                "-WorkspaceKey", workspace_key,
                "-SessionKey", session_key,
                "-FocusId", "h7-learning",
                "-FocusLabel", "H7 learning candidate",
                "-TopicKeys", "h7-learning",
                "-InstructionMode", "continue",
                "-LatestUserInstruction", "continue H7 learning candidate",
                "-AssistantCommitment", "capture only H7-governed non-binding learning evidence",
                "-NextAction", "verify the H7 learning candidate",
                "-CurrentPhase", "completion",
                "-CurrentStep", "capture H7-governed learning evidence",
                "-StateRoot", str(state_root),
                "-NoExit", "-Json",
            ],
            cwd=host_root,
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
        assert contract.returncode == 0, contract.stderr or contract.stdout
        assert json.loads(contract.stdout)["ok"] is True

        opened = subprocess.run(
            [
                sys.executable, "-X", "utf8", str(ROOT / "runtime" / "brain_cli.py"),
                "--package-root", str(ROOT),
                "--memory-root", str(state_root / "shared"),
                "turn-runtime", "--phase", "open", "--memory-mode", "auto",
                "--turn-intent", "memory_write", "--timeout-seconds", "12",
            ],
            cwd=host_root,
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
        assert opened.returncode == 0, opened.stderr or opened.stdout
        assert json.loads(opened.stdout)["available"] is True

        evidence = subprocess.run(
            [
                sys.executable, "-X", "utf8", str(ROOT / "runtime" / "brain_cli.py"),
                "--package-root", str(ROOT),
                "--memory-root", str(state_root / "shared"),
                "turn-runtime", "--phase", "evidence", "--memory-mode", "auto",
                "--turn-intent", "memory_write", "--timeout-seconds", "12",
            ],
            cwd=host_root,
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
        assert evidence.returncode == 0, evidence.stderr or evidence.stdout
        h7_evidence = json.loads(evidence.stdout)
        assert h7_evidence["available"] is True and h7_evidence["code"] == "H7_EVIDENCE_CURRENT"
        assert h7_evidence["entry"]["current"] is True and h7_evidence["telemetry"]["current"] is True
        assert h7_evidence["memoryInjection"]["refs"] == ["learning-candidate-source@1"]
        assert not (state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry").exists()

        completed = subprocess.run(
            [
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                str(ROOT / "scripts" / "cognitive-enforce.ps1"),
                "-Query", "continue H7 learning candidate",
                "-TaskId", task_id,
                "-SessionKey", session_key,
                "-Phase", "BeforeCompletion",
                "-AllowMissingPreflight", "-Json",
            ],
            cwd=host_root,
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=45,
        )
        assert completed.returncode == 0, completed.stderr or completed.stdout
        result = json.loads(completed.stdout)
        learning = result["learningCandidate"]
        assert learning["attempted"] is True and learning["ok"] is True and learning["status"] == "captured", learning
        assert learning["schema"] == "super-brain.h7-memory-learning-candidate.v1"
        assert learning["candidate"]["lifecycle"] == "proposed"
        assert learning["candidate"]["directConstraint"] is False
        assert learning["h7Evidence"] == {
            "scopeRef": h7_evidence["scope"]["scopeRef"],
            "entryReceiptHash": h7_evidence["entry"]["receipt"]["receiptHash"],
            "telemetryHash": h7_evidence["telemetry"]["payloadHash"],
            "typedMemoryRefsHash": h7_evidence["memoryInjection"]["refsHash"],
        }
        candidate_card = control.get_card(learning["candidate"]["cardId"])
        assert candidate_card is not None
        assert candidate_card["authority"] == "system" and candidate_card["lifecycle"] == "proposed"
        assert candidate_card["payload"]["candidateState"] == "staged"
        assert candidate_card["payload"]["tags"][-1] == "h7-turn-runtime"
        serialized_candidate = json.dumps(candidate_card, ensure_ascii=False)
        assert "Reference: H7 learning candidates" not in serialized_candidate
        assert "prompt-hook-telemetry" not in serialized_candidate
        assert not (state_root / "workspace" / "runtime-state" / "prompt-hook-telemetry").exists()


def test_retired_dispatcher_declares_h7_replacement() -> None:
    completed = subprocess.run(
        [sys.executable, str(ROOT / "runtime" / "codex_prompt_hook_dispatcher.py"), "--describe"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    )
    assert json.loads(completed.stdout) == {"ok": True, "state": "retired", "replacement": "H7 brain_turn"}


def test_retired_dispatcher_remains_fail_open_for_a_cached_host_command() -> None:
    completed = subprocess.run(
        [sys.executable, str(ROOT / "runtime" / "codex_prompt_hook_dispatcher.py")],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    )
    assert json.loads(completed.stdout) == {
        "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}
    }


def main() -> None:
    test_retired_dispatcher_declares_h7_replacement()
    test_retired_dispatcher_remains_fail_open_for_a_cached_host_command()
    print("RUNTIME_H7_HOOKLESS_RETIREMENT_REGRESSION_OK")


if __name__ == "__main__":
    main()
