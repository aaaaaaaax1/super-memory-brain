from __future__ import annotations

import json
import hashlib
import io
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))

from activation_receipt import ACTIVE_RECEIPTS_DIRECTORY, activate, ensure_current, read_valid, receipt_path
import activation_receipt as activation_module
import brain_cli
from brain_cli import _explicit_scope_matches_local
from brain_core import BrainCore
from core_rule_registry import canonical_hash


def _probe_activation_lock(lock_path: Path) -> bool:
    runtime_path = Path(__file__).resolve().parents[1] / "runtime"
    probe = "\n".join(
        (
            "import sys",
            f"sys.path.insert(0, {str(runtime_path)!r})",
            "import activation_receipt as activation",
            "activation.ACTIVATION_LOCK_TIMEOUT_SECONDS = 0.05",
            "with activation._activation_lock(sys.argv[1], sys.argv[2]) as acquired:",
            "    print('1' if acquired else '0')",
        )
    )
    completed = subprocess.run(
        [sys.executable, "-c", probe, str(lock_path.parent.parent.parent.parent), lock_path.stem],
        capture_output=True,
        check=False,
        text=True,
        timeout=10,
    )
    assert completed.returncode == 0, completed.stderr
    return completed.stdout.strip() == "1"


def main() -> int:
    package_root = Path(__file__).resolve().parents[1]
    package_version = str(json.loads((package_root / "manifest.json").read_text(encoding="utf-8"))["version"])
    with tempfile.TemporaryDirectory(prefix="super-brain-activation-") as raw:
        state_root = Path(raw)
        memory_base = state_root / "state"
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)

        # A historical host-owned ``receipts`` target may be unavailable.  It
        # cannot be the active receipt root: activation must still be local,
        # writable, and bounded.
        legacy_receipts = memory_base / "workspace" / "runtime-state" / "activation" / "receipts"
        legacy_receipts.parent.mkdir(parents=True, exist_ok=True)
        legacy_receipts.write_text("legacy read-only evidence", encoding="utf-8")

        full = activate(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-regression",
            session_key="sid-activation-regression",
            route="bare_wake",
            action_authorization="not_applicable",
            memory_snapshot_hash="a" * 64,
            memory_refs=["card-one@1", "card-two@2"],
        )
        assert full["activationState"] == "full_brain_active", full
        assert full["capabilities"]["coreReady"] is True
        assert full["checks"]["coreRules"] is True
        assert full["coreRules"]["payloadHash"]
        assert full["actionAuthorization"] == "not_applicable"
        assert full["memory"]["refsHash"]
        assert full["route"]["routeClass"] == "continuity", full
        assert full["route"]["activationTier"] == "continuity_light", full
        assert full["route"]["requiresTaskPointer"] is False, full
        assert full["route"]["requiresProjectProof"] is False, full
        assert full["route"]["requiresCapabilityRoute"] is False, full
        assert full["route"]["userVisibleState"] == "continuity", full
        assert full["rawPromptStored"] is False
        assert full["rawTranscriptStored"] is False

        # A partial activation is withheld, never a degraded permission to
        # continue a governed turn.
        withheld_partial = activate(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-partial",
            session_key="sid-activation-partial",
            route="current_session_continue",
            action_authorization="allowed",
            degraded_reasons=["transport-not-current"],
        )
        assert withheld_partial["activationState"] == "withheld", withheld_partial
        assert withheld_partial["actionAuthorization"] == "withheld", withheld_partial

        current, code = read_valid(
            memory_base,
            workspace_key="ws-activation-regression",
            session_key="sid-activation-regression",
            package_root=package_root,
        )
        assert code == "ACTIVATION_RECEIPT_CURRENT", code
        assert current and current["receiptHash"] == full["receiptHash"]

        # A route change in the same scope must not reuse a receipt carrying
        # the old activation tier and evidence requirements.
        changed_route, changed_route_code = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-regression",
            session_key="sid-activation-regression",
            route="current_session_continue",
            action_authorization="not_applicable",
            memory_snapshot_hash="a" * 64,
            memory_refs=["card-one@1", "card-two@2"],
        )
        assert changed_route_code == "ACTIVATION_RECEIPT_REISSUED", changed_route_code
        assert changed_route["route"]["name"] == "current_session_continue", changed_route
        assert changed_route["route"]["routeClass"] == "continuity", changed_route
        assert changed_route["route"]["requiresTaskPointer"] is True, changed_route
        assert changed_route["route"]["requiresProjectProof"] is True, changed_route

        withheld = activate(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="",
            session_key="",
            route="current_session_continue",
            action_authorization="allowed",
            require_scope=True,
        )
        assert withheld["activationState"] == "withheld", withheld
        assert withheld["actionAuthorization"] == "withheld"

        failed = activate(
            package_root,
            state_root / "missing-state",
            memory_root=state_root / "missing-memory",
            workspace_key="ws-activation-regression-failed",
            session_key="sid-activation-regression-failed",
            route="bare_wake",
            action_authorization="not_applicable",
        )
        assert failed["activationState"] == "failed", failed
        assert failed["capabilities"]["coreReady"] is False

        active_receipt_dir = memory_base / "workspace" / "runtime-state" / "activation" / ACTIVE_RECEIPTS_DIRECTORY
        receipt_file = next(active_receipt_dir.glob("*.json"))
        parsed = json.loads(receipt_file.read_text(encoding="utf-8"))
        assert parsed["schema"] == "super-brain.activation-receipt.v1"
        assert receipt_path(memory_base, "scope-fixture").parent == active_receipt_dir
        assert legacy_receipts.is_file(), "legacy receipts evidence must not be reactivated"

        # Status is observational: it must report a missing scope receipt,
        # never create one merely because the user inspected the system.
        receipts_before_status = sorted(
            path.name for path in active_receipt_dir.glob("*.json")
        )
        cli_environment = os.environ.copy()
        cli_environment["SUPER_BRAIN_LOCAL_SESSION_ID"] = "sid-activation-cli-regression"
        cli = subprocess.run(
            [
                sys.executable,
                "-X",
                "utf8",
                str(package_root / "runtime" / "brain_cli.py"),
                "--package-root",
                str(package_root),
                "--memory-root",
                str(memory_root),
                "status",
            ],
            cwd=str(package_root),
            env=cli_environment,
            capture_output=True,
            text=True,
            check=False,
        )
        assert cli.returncode == 0, cli.stderr
        status = json.loads(cli.stdout)
        assert status["activation"]["state"] == "withheld", status
        assert status["activation"]["code"] == "ACTIVATION_RECEIPT_MISSING", status
        assert status["fullBrainActive"] is False, status
        assert status["coreRules"]["status"] == "current", status
        assert status["activation"]["rawPromptStored"] is False, status
        assert status["activation"]["rawTranscriptStored"] is False, status
        receipts_after_status = sorted(
            path.name for path in active_receipt_dir.glob("*.json")
        )
        assert receipts_after_status == receipts_before_status

        # Explicit CLI scope is an assertion against the current local session,
        # never a selector.  A missing process session must reject even a
        # matching workspace plus an arbitrary explicit session.
        scope_core = BrainCore(package_root, memory_root)
        local_workspace = scope_core._context_workspace_key()
        previous_local_session = os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
        try:
            assert not _explicit_scope_matches_local(
                scope_core,
                local_workspace,
                "sid-explicit-without-local-binding",
            )
        finally:
            if previous_local_session is not None:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_local_session

        # ``turn-close`` must reject every partially or wholly foreign
        # explicit scope before either the dispatcher or activation can run.
        # This is intentionally exercised through ``brain_cli.main`` so the
        # ordering remains covered even if the dispatcher accepts a foreign
        # scope for its own lower-level reconciliation tests.
        class _BinaryStdout:
            def __init__(self) -> None:
                self.buffer = io.BytesIO()

            def write(self, value: str) -> int:
                return len(value)

            def flush(self) -> None:
                return None

        cli_scope_core = BrainCore(package_root, memory_root)
        cli_local_workspace = cli_scope_core._context_workspace_key()
        previous_cwd = Path.cwd()
        previous_argv = list(sys.argv)
        previous_stdout = sys.stdout
        previous_session = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        dispatch_calls: list[tuple[tuple[object, ...], dict[str, object]]] = []
        activation_calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

        def unexpected_dispatch(*args: object, **kwargs: object) -> dict[str, object]:
            dispatch_calls.append((args, kwargs))
            return {"ok": True}

        def unexpected_activation(*args: object, **kwargs: object) -> dict[str, object]:
            activation_calls.append((args, kwargs))
            return {"activationState": "full_brain_active"}

        original_dispatch = brain_cli.dispatch_turn_close
        original_activation = brain_cli._ensure_core_activation
        brain_cli.dispatch_turn_close = unexpected_dispatch
        brain_cli._ensure_core_activation = unexpected_activation
        try:
            os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = "sid-cli-local-scope"
            os.chdir(package_root)
            for workspace_key, session_key in (
                ("ws-cli-foreign-scope", "sid-cli-local-scope"),
                (cli_local_workspace, "sid-cli-foreign-scope"),
                (cli_local_workspace, ""),
            ):
                output = _BinaryStdout()
                sys.stdout = output
                sys.argv = [
                    str(package_root / "runtime" / "brain_cli.py"),
                    "--package-root",
                    str(package_root),
                    "--memory-root",
                    str(memory_root),
                    "turn-close",
                    "--task-id",
                    "task-cli-foreign-scope",
                    "--workspace-key",
                    workspace_key,
                    "--session-key",
                    session_key,
                    "--turn-outcome",
                    "side_branch_completed",
                    "--completion-evidence-ref",
                    "test:cli-foreign-scope",
                ]
                assert brain_cli.main() == 0
                payload = json.loads(output.buffer.getvalue().decode("utf-8"))
                assert payload["code"] == "H7_CLI_FOREIGN_SCOPE_FORBIDDEN", payload
                assert payload["stateMutated"] is False, payload
        finally:
            brain_cli.dispatch_turn_close = original_dispatch
            brain_cli._ensure_core_activation = original_activation
            sys.stdout = previous_stdout
            sys.argv = previous_argv
            os.chdir(previous_cwd)
            if previous_session is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_session
        assert dispatch_calls == [], dispatch_calls
        assert activation_calls == [], activation_calls

        # The activation lock is handle-owned across processes.  A resident
        # writer blocks a second writer, while process exit releases the OS
        # lock without a dangerous stale-file unlink race.
        lock_scope = "scope-lock-regression"
        lock_path = (
            memory_base
            / "workspace"
            / "runtime-state"
            / "activation"
            / f"{lock_scope}.lock"
        )
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        original_timeout = activation_module.ACTIVATION_LOCK_TIMEOUT_SECONDS
        activation_module.ACTIVATION_LOCK_TIMEOUT_SECONDS = 0.05
        try:
            lock_path.write_text("legacy-owner", encoding="ascii")
            with activation_module._activation_lock(memory_base, lock_scope) as acquired:
                assert acquired is False
            assert lock_path.read_text(encoding="ascii") == "legacy-owner"
            lock_path.unlink()
            with activation_module._activation_lock(memory_base, lock_scope) as acquired:
                assert acquired is True
                assert _probe_activation_lock(lock_path) is False
            assert lock_path.exists()
            assert lock_path.read_bytes() == b"0"
            assert _probe_activation_lock(lock_path) is True
        finally:
            activation_module.ACTIVATION_LOCK_TIMEOUT_SECONDS = original_timeout
            lock_path.unlink(missing_ok=True)

        contract = {
            "taskId": "task-activation-refresh",
            "taskInstanceId": "ti-activation-refresh",
            "revision": 1,
            "status": "active",
            "nextAction": "continue the governed action",
        }
        first, first_code = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-refresh",
            session_key="sid-activation-refresh",
            task_id=contract["taskId"],
            task_instance_id=contract["taskInstanceId"],
            contract=contract,
            action_authorization="withheld",
            require_scope=True,
        )
        assert first_code == "ACTIVATION_RECEIPT_CREATED", first_code
        keyword_receipt, keyword_code = ensure_current(
            package_root=package_root,
            memory_base=memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-keyword",
            session_key="sid-activation-keyword",
            contract=contract,
            action_authorization="withheld",
            require_scope=True,
        )
        assert keyword_code == "ACTIVATION_RECEIPT_CREATED", keyword_code
        assert keyword_receipt["activationState"] == "full_brain_active", keyword_receipt
        second, second_code = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-refresh",
            session_key="sid-activation-refresh",
            task_id=contract["taskId"],
            task_instance_id=contract["taskInstanceId"],
            contract=contract,
            action_authorization="withheld",
            require_scope=True,
        )
        assert second_code == "ACTIVATION_RECEIPT_CURRENT", second_code
        assert second["receiptHash"] == first["receiptHash"]
        refreshed_contract = {**contract, "revision": 2, "nextAction": "continue the refreshed governed action"}
        refreshed, refreshed_code = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-refresh",
            session_key="sid-activation-refresh",
            task_id=contract["taskId"],
            task_instance_id=contract["taskInstanceId"],
            contract=refreshed_contract,
            action_authorization="withheld",
            require_scope=True,
        )
        assert refreshed_code == "ACTIVATION_RECEIPT_REISSUED", refreshed_code
        assert refreshed["task"]["contractRevision"] == 2, refreshed
        assert refreshed["receiptHash"] != first["receiptHash"]

        # Authorization must be revalidated in both directions.  A previous
        # allowed receipt must never survive a later contract resolution that
        # is withheld for the same scope.
        authorized_contract = {
            **contract,
            "taskId": "task-activation-authorization",
            "taskInstanceId": "ti-activation-authorization",
        }
        authorized, authorized_code = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-authorization",
            session_key="sid-activation-authorization",
            task_id=authorized_contract["taskId"],
            task_instance_id=authorized_contract["taskInstanceId"],
            contract=authorized_contract,
            action_authorization="allowed",
            require_scope=True,
        )
        assert authorized_code == "ACTIVATION_RECEIPT_CREATED", authorized_code
        assert authorized["actionAuthorization"] == "allowed", authorized
        withheld_authorized, withheld_authorized_code = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-authorization",
            session_key="sid-activation-authorization",
            task_id=authorized_contract["taskId"],
            task_instance_id=authorized_contract["taskInstanceId"],
            contract=authorized_contract,
            action_authorization="withheld",
            require_scope=True,
        )
        assert withheld_authorized_code == "ACTIVATION_RECEIPT_REISSUED", withheld_authorized_code
        assert withheld_authorized["actionAuthorization"] == "withheld", withheld_authorized
        assert withheld_authorized["receiptHash"] != authorized["receiptHash"]

        # A prior degraded receipt must self-heal once the caller removes the
        # explicit degradation reason; it must not remain permanently withheld.
        degraded, degraded_code = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-degraded",
            session_key="sid-activation-degraded",
            route="bare_wake",
            degraded_reasons=["temporary-repair-needed"],
        )
        assert degraded_code == "ACTIVATION_RECEIPT_CREATED", degraded_code
        assert degraded["activationState"] == "withheld", degraded
        healed, healed_code = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-degraded",
            session_key="sid-activation-degraded",
            route="bare_wake",
        )
        assert healed_code == "ACTIVATION_RECEIPT_REISSUED", healed_code
        assert healed["activationState"] == "full_brain_active", healed
        assert healed["receiptHash"] != degraded["receiptHash"]

        # A structurally malformed but correctly rehashed receipt must fail
        # closed rather than raising while inspecting nested scope fields.
        malformed_contract = {
            **contract,
            "taskId": "task-activation-malformed",
            "taskInstanceId": "ti-activation-malformed",
        }
        malformed, _ = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-malformed",
            session_key="sid-activation-malformed",
            task_id=malformed_contract["taskId"],
            task_instance_id=malformed_contract["taskInstanceId"],
            contract=malformed_contract,
            action_authorization="withheld",
            require_scope=True,
        )
        malformed_path = receipt_path(
            memory_base,
            malformed["scope"]["scopeRef"],
        )
        malformed_value = json.loads(malformed_path.read_text(encoding="utf-8"))
        malformed_value["scope"] = []
        malformed_value["receiptHash"] = activation_module._receipt_hash(malformed_value)
        malformed_path.write_text(json.dumps(malformed_value), encoding="utf-8")
        malformed_read, malformed_code = read_valid(
            memory_base,
            workspace_key="ws-activation-malformed",
            session_key="sid-activation-malformed",
            task_id=malformed_contract["taskId"],
            task_instance_id=malformed_contract["taskInstanceId"],
            package_root=package_root,
        )
        assert malformed_read is None
        assert malformed_code == "ACTIVATION_RECEIPT_SCOPE_INVALID", malformed_code

        # A correctly rehashed receipt with an unknown activation state or
        # authorization must still fail closed; the hash only protects
        # consistency, not the receipt schema or policy enum.
        invalid_state, _ = ensure_current(
            package_root,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-invalid-state",
            session_key="sid-activation-invalid-state",
            route="bare_wake",
        )
        invalid_state_path = receipt_path(memory_base, invalid_state["scope"]["scopeRef"])
        invalid_state_value = json.loads(invalid_state_path.read_text(encoding="utf-8"))
        invalid_state_value["activationState"] = "degraded"
        invalid_state_value["receiptHash"] = activation_module._receipt_hash(invalid_state_value)
        invalid_state_path.write_text(json.dumps(invalid_state_value), encoding="utf-8")
        invalid_state_read, invalid_state_code = read_valid(
            memory_base,
            workspace_key="ws-activation-invalid-state",
            session_key="sid-activation-invalid-state",
            package_root=package_root,
        )
        assert invalid_state_read is None
        assert invalid_state_code == "ACTIVATION_RECEIPT_STATE_INVALID", invalid_state_code

        # A signed registry change invalidates the old activation identity even
        # when the package manifest itself did not change.  The next governed
        # activation reissues a receipt rather than silently trusting stale
        # rule effects.
        registry_package = state_root / "registry-package"
        registry_package.mkdir()
        for name in ("manifest.json", "route-map.json", "capabilities.json", "super-brain-rules.json"):
            (registry_package / name).write_bytes((package_root / name).read_bytes())
        registry_contract = {**contract, "taskId": "task-activation-registry", "taskInstanceId": "ti-activation-registry"}
        registry_first, registry_first_code = ensure_current(
            registry_package,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-registry",
            session_key="sid-activation-registry",
            task_id=registry_contract["taskId"],
            task_instance_id=registry_contract["taskInstanceId"],
            contract=registry_contract,
            action_authorization="withheld",
            require_scope=True,
        )
        assert registry_first_code == "ACTIVATION_RECEIPT_CREATED", registry_first_code
        registry_document = json.loads((registry_package / "super-brain-rules.json").read_text(encoding="utf-8"))
        registry_document["rules"][0]["revision"] = 2
        registry_document["payloadHash"] = canonical_hash(
            {key: value for key, value in registry_document.items() if key != "payloadHash"}
        )
        (registry_package / "super-brain-rules.json").write_text(
            json.dumps(registry_document, ensure_ascii=False), encoding="utf-8"
        )
        stale, stale_code = read_valid(
            memory_base,
            workspace_key="ws-activation-registry",
            session_key="sid-activation-registry",
            task_id=registry_contract["taskId"],
            task_instance_id=registry_contract["taskInstanceId"],
            package_root=registry_package,
        )
        assert stale is None
        assert stale_code == "ACTIVATION_RECEIPT_CORE_RULE_REGISTRY_STALE", stale_code
        registry_refreshed, registry_refreshed_code = ensure_current(
            registry_package,
            memory_base,
            memory_root=memory_root,
            workspace_key="ws-activation-registry",
            session_key="sid-activation-registry",
            task_id=registry_contract["taskId"],
            task_instance_id=registry_contract["taskInstanceId"],
            contract=registry_contract,
            action_authorization="withheld",
            require_scope=True,
        )
        assert registry_refreshed_code == "ACTIVATION_RECEIPT_REISSUED", registry_refreshed_code
        assert registry_refreshed["receiptHash"] != registry_first["receiptHash"]
        assert registry_refreshed["coreRules"]["payloadHash"] == registry_document["payloadHash"]

        # status() must carry taskInstanceId from the active contract into its
        # activation lookup.  A task-only lookup would miss the current scoped
        # receipt and falsely report that the full brain is absent.
        scoped_session = "sid-a11ce7a7105c0fea11ce7a70"
        scoped_workspace = "ws-" + hashlib.sha256(
            str(package_root.resolve()).rstrip("/\\").lower().encode("utf-8")
        ).hexdigest()[:24]
        scoped_contract = {
            "schema": "super-brain.execution-contract.v1",
            "taskId": "task-activation-status-scope",
            "taskInstanceId": "ti-activation-status-scope",
            "workspaceKey": scoped_workspace,
            "ownerSessionKey": scoped_session,
                "packageVersion": package_version,
            "revision": 1,
            "status": "active",
            "updatedAt": datetime.now(timezone.utc).isoformat(),
            "needsReconciliation": False,
        }
        # The CLI resolves its state base from the shared memory root's parent.
        # Keep this scoped fixture on that same base rather than the separate
        # low-level receipt fixture above.
        scoped_memory_base = memory_root.parent
        contract_dir = scoped_memory_base / "workspace" / "runtime-state" / "execution-contracts"
        index_dir = scoped_memory_base / "workspace" / "runtime-state" / "execution-hot-index"
        contract_dir.mkdir(parents=True, exist_ok=True)
        index_dir.mkdir(parents=True, exist_ok=True)
        contract_name = "task-activation-status-scope.json"
        (contract_dir / contract_name).write_text(json.dumps(scoped_contract), encoding="utf-8")
        (index_dir / f"{scoped_session}--{scoped_workspace}.json").write_text(
            json.dumps(
                {
                    "schema": "super-brain.execution-hot-index.v1",
                    "workspaceKey": scoped_workspace,
                    "ownerSessionKey": scoped_session,
                    "entries": [
                        {
                            "taskId": scoped_contract["taskId"],
                            "packageVersion": scoped_contract["packageVersion"],
                            "status": "active",
                            "revision": scoped_contract["revision"],
                            "updatedAt": scoped_contract["updatedAt"],
                            "contractFileName": contract_name,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        receipt, receipt_code = ensure_current(
            package_root,
            scoped_memory_base,
            memory_root=memory_root,
            workspace_key=scoped_workspace,
            session_key=scoped_session,
            task_id=scoped_contract["taskId"],
            task_instance_id=scoped_contract["taskInstanceId"],
            contract=scoped_contract,
            action_authorization="withheld",
            require_scope=True,
        )
        assert receipt_code == "ACTIVATION_RECEIPT_CREATED", receipt_code
        scoped_core = BrainCore(package_root, memory_root)
        scoped_context, scoped_context_code = scoped_core._read_context_contract(
            scoped_workspace, scoped_session
        )
        assert scoped_context_code == "BRAIN_CONTEXT_READY", scoped_context_code
        assert scoped_context and scoped_context["taskInstanceId"] == scoped_contract["taskInstanceId"]
        scoped_environment = os.environ.copy()
        scoped_environment["SUPER_BRAIN_LOCAL_SESSION_ID"] = scoped_session
        scoped_cli = subprocess.run(
            [
                sys.executable,
                "-X",
                "utf8",
                str(package_root / "runtime" / "brain_cli.py"),
                "--package-root",
                str(package_root),
                "--memory-root",
                str(memory_root),
                "status",
            ],
            cwd=str(package_root),
            env=scoped_environment,
            capture_output=True,
            text=True,
            check=False,
        )
        assert scoped_cli.returncode == 0, scoped_cli.stderr
        scoped_status = json.loads(scoped_cli.stdout)
        assert scoped_status["activation"]["task"]["taskId"] == scoped_contract["taskId"], scoped_status
        assert scoped_status["activation"]["task"]["taskInstanceId"] == scoped_contract["taskInstanceId"], scoped_status
        assert scoped_status["fullBrainActive"] is True, scoped_status
    print("RUNTIME_ACTIVATION_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
