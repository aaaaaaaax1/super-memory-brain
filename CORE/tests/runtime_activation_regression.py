from __future__ import annotations

import json
import hashlib
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))

from activation_receipt import ACTIVE_RECEIPTS_DIRECTORY, activate, ensure_current, read_valid, receipt_path
from brain_core import BrainCore
from core_rule_registry import canonical_hash


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
