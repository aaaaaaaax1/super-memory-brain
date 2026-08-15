from __future__ import annotations

import http.cookiejar
from datetime import UTC, datetime, timedelta
import json
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import HTTPCookieProcessor, Request, build_opener, urlopen


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_VERSION = str(json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["version"])
sys.path.insert(0, str(ROOT / "runtime"))

from brain_ui_server import COOKIE_NAME, UiHttpServer, UiService, _reflection_trial_projection


def request_json(opener, url: str, path: str, payload: dict[str, object], *, origin: str, extra_headers: dict[str, str] | None = None) -> tuple[int, dict[str, object], dict[str, str]]:
    raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    headers = {"Content-Type": "application/json", "Origin": origin}
    if extra_headers:
        headers.update(extra_headers)
    request = Request(
        url + path,
        data=raw,
        method="POST",
        headers=headers,
    )
    with opener.open(request, timeout=3) as response:
        body = json.loads(response.read().decode("utf-8"))
        return response.status, body, dict(response.headers.items())


def expect_http_error(callable_, status: int) -> tuple[dict[str, object], dict[str, str]]:
    try:
        callable_()
        raise AssertionError(f"expected HTTP {status}")
    except HTTPError as error:
        assert error.code == status
        return json.loads(error.read().decode("utf-8")), dict(error.headers.items())


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-ui-server-") as directory:
        root = Path(directory)
        assets = root / "assets"
        assets.mkdir()
        (assets / "index.html").write_text("<!doctype html><title>Control Center</title>", encoding="utf-8")
        service = UiService(
            state_root=root,
            assets_root=assets,
            idle_seconds=60,
            instance_id="ui-test-instance",
            capability_token="test-capability-token",
        )
        server = UiHttpServer(("127.0.0.1", 0), service)
        service.port = server.server_port
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = service.origin
        try:
            with urlopen(base + "/", timeout=3) as response:
                root_body = response.read().decode("utf-8")
                set_cookie = response.headers.get("Set-Cookie", "")
                assert response.status == 200 and "Control Center" in root_body
                assert "HttpOnly" in set_cookie and "test-capability-token" not in set_cookie
                assert "Access-Control-Allow-Origin" not in response.headers

            with urlopen(base + "/api/health", timeout=3) as response:
                public_health = json.loads(response.read().decode("utf-8"))
                assert response.status == 200
            assert public_health == {"ok": True, "schema": "super-brain.ui-api.v1", "service": "healthy"}

            no_cookie = build_opener()
            unauthorized, unauthorized_headers = expect_http_error(
                lambda: request_json(no_cookie, base, "/api/read", {"operation": "cards"}, origin=base),
                401,
            )
            assert unauthorized["code"] == "BRAIN_UI_CAPABILITY_REQUIRED"
            assert "Access-Control-Allow-Origin" not in unauthorized_headers

            jar = http.cookiejar.CookieJar()
            opener = build_opener(HTTPCookieProcessor(jar))
            with opener.open(base + "/", timeout=3) as response:
                response.read()
            assert len(jar) == 1
            issued_capability = next(cookie.value for cookie in jar if cookie.name == COOKIE_NAME)
            with patch("brain_ui_server.time.time", return_value=time.time() + 61):
                expired, _ = expect_http_error(
                    lambda: request_json(
                        no_cookie,
                        base,
                        "/api/read",
                        {"operation": "cards"},
                        origin=base,
                        extra_headers={"Cookie": f"{COOKIE_NAME}={issued_capability}"},
                    ),
                    401,
                )
            assert expired["code"] == "BRAIN_UI_CAPABILITY_REQUIRED"

            wrong_origin, _ = expect_http_error(
                lambda: request_json(opener, base, "/api/read", {"operation": "cards"}, origin="http://127.0.0.1:9"),
                403,
            )
            assert wrong_origin["code"] == "BRAIN_UI_ORIGIN_REJECTED"

            card = {
                "cardId": "ui-note-card",
                "kind": "note",
                "scope": {"kind": "global", "key": "user"},
                "lifecycle": "active",
                "authority": "user_confirmed",
                "privacyClass": "private",
                "title": "Loopback note",
                "payload": {
                    "schema": "super-brain.card.note.v1",
                    "body": "The UI must save through a governed command and never open SQLite in the browser.",
                    "tags": ["ui"],
                    "links": [],
                    "pinned": True,
                },
                "evidenceRefs": [],
            }
            status, created, headers = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-note", "cardId": "ui-note-card", "expectedRevision": 0, "card": card},
                origin=base,
            )
            assert status == 200 and created["receipt"]["revision"] == 1
            assert created["delivery"]["status"] in {"materialized", "pending"}
            assert "test-capability-token" not in json.dumps(created) and str(root) not in json.dumps(created)
            assert "Cache-Control" in headers
            assert "test-capability-token" not in headers.get("Set-Cookie", "")
            assert "Max-Age=60" in headers.get("Set-Cookie", "")

            _, captured_memory, _ = request_json(
                opener,
                base,
                "/api/command",
                {
                    "action": "capture_memory",
                    "requestId": "ui-capture-memory",
                    "problem": "发布前总会漏掉验收材料。",
                    "desiredAction": "下次准备发布时，提醒我核对验收材料。",
                },
                origin=base,
            )
            capture_receipt = captured_memory["receipt"]
            capture_meta = captured_memory["capture"]
            assert capture_receipt["kind"] == "note" and capture_receipt["revision"] == 1
            assert capture_meta == {
                "storedKind": "note",
                "suggestedKind": "experience",
                "enrichmentState": "pending_evidence",
                "automaticConstraint": False,
            }
            capture_card_id = str(capture_receipt["aggregateId"])
            _, captured_card, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "card", "cardId": capture_card_id},
                origin=base,
            )
            assert captured_card["card"]["kind"] == "note"
            assert captured_card["card"]["payload"]["body"] == "问题是什么：发布前总会漏掉验收材料。 想怎么做：下次准备发布时，提醒我核对验收材料。"
            assert "建议：experience" in captured_card["card"]["payload"]["tags"]
            status_before_plan = service.control.status()
            snapshot_before_plan = service.control.native_memory_influence_snapshot_path.read_bytes()
            _, learning_plan, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "learning_plan", "maxProposals": 12},
                origin=base,
            )
            assert learning_plan["schema"] == "super-brain.memory-consolidation-plan.v1"
            assert learning_plan["directDurableWrite"] is False
            assert learning_plan["requiresUserConfirmation"] is True
            assert learning_plan["rawTranscriptStored"] is False
            assert captured_card["card"]["payload"]["body"] not in json.dumps(learning_plan, ensure_ascii=False)
            assert service.control.status() == status_before_plan
            assert service.control.native_memory_influence_snapshot_path.read_bytes() == snapshot_before_plan
            _, captured_idempotent, _ = request_json(
                opener,
                base,
                "/api/command",
                {
                    "action": "capture_memory",
                    "requestId": "ui-capture-memory",
                    "problem": "发布前总会漏掉验收材料。",
                    "desiredAction": "下次准备发布时，提醒我核对验收材料。",
                },
                origin=base,
            )
            assert captured_idempotent["receipt"]["aggregateId"] == capture_card_id
            assert captured_idempotent["receipt"]["idempotent"] is True
            invalid_capture, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {"action": "capture_memory", "requestId": "ui-empty-capture", "problem": "", "desiredAction": "要做什么"},
                    origin=base,
                ),
                400,
            )
            assert invalid_capture["code"] == "BRAIN_UI_REQUEST_INVALID", invalid_capture

            preference = {
                "cardId": "ui-profile-preference",
                "kind": "preference",
                "scope": {"kind": "global", "key": "user"},
                "lifecycle": "active",
                "authority": "user_confirmed",
                "privacyClass": "private",
                "title": "Review depth",
                "payload": {
                    "schema": "super-brain.card.preference.v1",
                    "statement": "For engineering changes, review the whole user path before declaring completion.",
                    "conditions": ["Use this for code and release work."],
                    "confidence": 92,
                    "evidenceUses": 2,
                    "conflictState": "clear",
                    "revalidateAfter": "",
                    "tags": ["review"],
                },
                "evidenceRefs": [],
            }
            _, preference_receipt, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-profile-preference", "cardId": "ui-profile-preference", "expectedRevision": 0, "card": preference},
                origin=base,
            )
            assert preference_receipt["receipt"]["revision"] == 1
            _, profile, _ = request_json(opener, base, "/api/read", {"operation": "profile"}, origin=base)
            assert profile["schema"] == "super-brain.ui-profile.v1"
            assert profile["total"] == 1
            assert profile["longTerm"][0]["cardRef"].startswith("card-")
            assert profile["longTerm"][0]["confidence"] == 92
            assert "whole user path" in profile["longTerm"][0]["statement"]
            profile_json = json.dumps(profile, ensure_ascii=False)
            for private_value in ("ui-profile-preference", "test-capability-token", str(root), "owner", "task-ui-private-control-id"):
                assert private_value not in profile_json

            reflection = {
                "cardId": "ui-reflection-card",
                "kind": "reflection",
                "scope": {"kind": "workspace", "key": "workspace"},
                "lifecycle": "active",
                "authority": "user_confirmed",
                "privacyClass": "private",
                "title": "Reflection for tested repair",
                "payload": {
                    "schema": "super-brain.card.reflection.v1",
                    "observation": "A repair was not ready to close until its user path was checked.",
                    "hypothesis": "A local command result alone did not prove the delivery result.",
                    "proposedAction": "Verify the full user path before completion.",
                    "evidence": ["Browser path and regression both passed."],
                    "confidence": 88,
                    "candidateState": "staged",
                    "tags": ["verification"],
                },
                "evidenceRefs": [],
            }
            _, reflection_created, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-reflection", "cardId": "ui-reflection-card", "expectedRevision": 0, "card": reflection},
                origin=base,
            )
            assert reflection_created["receipt"]["revision"] == 1

            forged_reflection = json.loads(json.dumps(reflection))
            forged_reflection["cardId"] = "ui-forged-adopted-reflection"
            forged_reflection["title"] = "Forged adopted reflection"
            forged_reflection["payload"]["candidateState"] = "adopted"
            forged_create, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {"action": "create", "requestId": "ui-forge-adopted-create", "cardId": "ui-forged-adopted-reflection", "expectedRevision": 0, "card": forged_reflection},
                    origin=base,
                ),
                400,
            )
            assert forged_create["code"] == "BRAIN_CONTROL_REFLECTION_ADOPTION_REQUIRED"

            forged_system = json.loads(json.dumps(reflection))
            forged_system["cardId"] = "ui-forged-system-reflection"
            forged_system["authority"] = "system"
            system_create, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {"action": "create", "requestId": "ui-forge-system-create", "cardId": "ui-forged-system-reflection", "expectedRevision": 0, "card": forged_system},
                    origin=base,
                ),
                400,
            )
            assert system_create["code"] == "BRAIN_UI_SYSTEM_CARD_READ_ONLY"

            direct_adopt = json.loads(json.dumps(reflection))
            direct_adopt["payload"]["candidateState"] = "adopted"
            forged_edit, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {"action": "edit", "requestId": "ui-forge-adopted-edit", "cardId": "ui-reflection-card", "expectedRevision": 1, "card": direct_adopt},
                    origin=base,
                ),
                400,
            )
            assert forged_edit["code"] == "BRAIN_CONTROL_REFLECTION_ADOPTION_REQUIRED"

            _, adopted_reflection, _ = request_json(
                opener,
                base,
                "/api/command",
                {
                    "action": "adopt_reflection",
                    "requestId": "ui-adopt-reflection",
                    "reflectionCardId": "ui-reflection-card",
                    "expectedRevision": 1,
                    "experienceCardId": "ui-reflection-experience",
                    "reason": "Control Center adopt an evidenced reflection",
                },
                origin=base,
            )
            assert adopted_reflection["receipt"]["reflection"]["candidateState"] == "adopted"
            assert adopted_reflection["receipt"]["experience"]["cardId"] == "ui-reflection-experience"
            _, reflected_source, _ = request_json(opener, base, "/api/read", {"operation": "card", "cardId": "ui-reflection-card"}, origin=base)
            _, reflected_experience, _ = request_json(opener, base, "/api/read", {"operation": "card", "cardId": "ui-reflection-experience"}, origin=base)
            assert reflected_source["card"]["payload"]["candidateState"] == "adopted"
            assert reflected_source["card"]["trial"]["verdict"] == "inconclusive"
            assert reflected_source["card"]["trial"]["trialState"] == "observed"
            assert reflected_experience["card"]["kind"] == "experience"
            assert reflected_experience["card"]["payload"]["lesson"] == "Verify the full user path before completion."
            assert _reflection_trial_projection({"trialVerdict": "passed", "trialState": "closed", "trialReceiptHash": "receipt"}) == {
                "verdict": "passed", "trialState": "closed", "hasEvidence": False, "hasReceipt": True
            }
            assert _reflection_trial_projection({"trialVerdict": "passed"})["verdict"] == "inconclusive"
            assert _reflection_trial_projection({"trialVerdict": "failed", "trialState": "closed"})["verdict"] == "failed"
            assert _reflection_trial_projection({"trialVerdict": "bogus"})["verdict"] == "inconclusive"

            # Typed reflection adoption must follow the persisted suggestion;
            # it must not silently create another experience card.
            typed_preference = json.loads(json.dumps(reflection))
            typed_preference["cardId"] = "ui-reflection-preference"
            typed_preference["title"] = "Preference candidate"
            typed_preference["payload"]["tags"] = ["建议：preference"]
            typed_preference["payload"]["proposedAction"] = "Prefer a full user-path verification before completion."
            _, typed_preference_created, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-reflection-preference", "cardId": typed_preference["cardId"], "expectedRevision": 0, "card": typed_preference},
                origin=base,
            )
            assert typed_preference_created["receipt"]["revision"] == 1
            _, typed_preference_adopted, _ = request_json(
                opener,
                base,
                "/api/command",
                {
                    "action": "adopt_reflection",
                    "requestId": "ui-adopt-reflection-preference",
                    "reflectionCardId": typed_preference["cardId"],
                    "expectedRevision": 1,
                    "adoptedCardId": "ui-reflection-preference-target",
                    "targetKind": "preference",
                    "reason": "Control Center adopt typed preference",
                },
                origin=base,
            )
            assert typed_preference_adopted["receipt"]["adopted"]["kind"] == "preference"
            _, typed_preference_card, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "card", "cardId": "ui-reflection-preference-target"},
                origin=base,
            )
            assert typed_preference_card["card"]["kind"] == "preference"
            assert typed_preference_card["card"]["payload"]["statement"] == typed_preference["payload"]["proposedAction"]

            typed_procedure = json.loads(json.dumps(reflection))
            typed_procedure["cardId"] = "ui-reflection-procedure"
            typed_procedure["title"] = "Procedure candidate"
            typed_procedure["payload"]["tags"] = ["建议：procedure"]
            typed_procedure["payload"]["proposedAction"] = "Run the release verification checklist."
            _, typed_procedure_created, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-reflection-procedure", "cardId": typed_procedure["cardId"], "expectedRevision": 0, "card": typed_procedure},
                origin=base,
            )
            assert typed_procedure_created["receipt"]["revision"] == 1
            _, typed_procedure_adopted, _ = request_json(
                opener,
                base,
                "/api/command",
                {
                    "action": "adopt_reflection",
                    "requestId": "ui-adopt-reflection-procedure",
                    "reflectionCardId": typed_procedure["cardId"],
                    "expectedRevision": 1,
                    "adoptedCardId": "ui-reflection-procedure-target",
                    "targetKind": "procedure",
                    "reason": "Control Center adopt typed procedure",
                },
                origin=base,
            )
            assert typed_procedure_adopted["receipt"]["adopted"]["kind"] == "procedure"
            _, typed_procedure_card, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "card", "cardId": "ui-reflection-procedure-target"},
                origin=base,
            )
            assert typed_procedure_card["card"]["kind"] == "procedure"
            assert typed_procedure_card["card"]["payload"]["steps"] == [typed_procedure["payload"]["proposedAction"]]

            typed_decision = json.loads(json.dumps(reflection))
            typed_decision["cardId"] = "ui-reflection-decision"
            typed_decision["title"] = "Decision candidate"
            typed_decision["payload"]["tags"] = ["建议：decision"]
            # The candidate itself is valid; only the generic adoption route is
            # forbidden for decisions.
            _, typed_decision_created, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-reflection-decision", "cardId": typed_decision["cardId"], "expectedRevision": 0, "card": typed_decision},
                origin=base,
            )
            assert typed_decision_created["receipt"]["revision"] == 1
            decision_adopt_error, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {
                        "action": "adopt_reflection",
                        "requestId": "ui-adopt-reflection-decision",
                        "reflectionCardId": typed_decision["cardId"],
                        "expectedRevision": 1,
                        "adoptedCardId": "ui-reflection-decision-target",
                        "targetKind": "decision",
                        "reason": "Control Center must not bypass decision receipts",
                    },
                    origin=base,
                ),
                400,
            )
            assert decision_adopt_error["code"] == "BRAIN_UI_REFLECTION_TARGET_NOT_PROMOTABLE"
            _, decision_target_missing, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "card", "cardId": "ui-reflection-decision-target"},
                origin=base,
            )
            assert decision_target_missing["card"] is None

            invalid_suggestion = json.loads(json.dumps(reflection))
            invalid_suggestion["cardId"] = "ui-reflection-invalid-suggestion"
            invalid_suggestion["payload"]["tags"] = ["建议：unknown-kind"]
            _, invalid_suggestion_created, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-reflection-invalid-suggestion", "cardId": invalid_suggestion["cardId"], "expectedRevision": 0, "card": invalid_suggestion},
                origin=base,
            )
            assert invalid_suggestion_created["receipt"]["revision"] == 1
            invalid_adopt_error, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {
                        "action": "adopt_reflection",
                        "requestId": "ui-adopt-reflection-invalid-suggestion",
                        "reflectionCardId": invalid_suggestion["cardId"],
                        "expectedRevision": 1,
                        "adoptedCardId": "ui-reflection-invalid-target",
                        "targetKind": "experience",
                        "reason": "Do not guess an invalid typed suggestion",
                    },
                    origin=base,
                ),
                400,
            )
            assert invalid_adopt_error["code"] == "BRAIN_UI_REFLECTION_SUGGESTION_INVALID"

            original_decision = {
                "cardId": "ui-replace-original",
                "kind": "decision",
                "scope": {"kind": "workspace", "key": "workspace"},
                "lifecycle": "active",
                "authority": "user_confirmed",
                "privacyClass": "private",
                "title": "Original release gate",
                "payload": {
                    "schema": "super-brain.card.decision.v2",
                    "summary": "Archive every release deliverable together.",
                    "rationale": "A generated installer alone is not the agreed delivery result.",
                    "consequences": ["Release completion waits for the archive."],
                    "stageKinds": ["release"],
                    "enforcement": "completion_gate",
                    "completionCriteria": ["archive installer", "include release notes"],
                    "applicability": {"mode": "workspace_stage", "taskIds": [], "taskInstanceIds": [], "worklineIds": [], "intentFingerprints": []},
                    "tags": ["release"],
                },
                "evidenceRefs": [],
            }
            _, original_receipt, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-replace-original", "cardId": "ui-replace-original", "expectedRevision": 0, "card": original_decision},
                origin=base,
            )
            assert original_receipt["receipt"]["revision"] == 1
            replacement = json.loads(json.dumps(original_decision))
            replacement["cardId"] = "ui-replace-new"
            replacement["title"] = "Replacement release gate"
            replacement["payload"]["summary"] = "Archive and verify every release deliverable together."
            _, replacement_receipt, _ = request_json(
                opener,
                base,
                "/api/command",
                {
                    "action": "replace",
                    "requestId": "ui-replace-decision",
                    "cardId": "ui-replace-new",
                    "card": replacement,
                    "replacedCardId": "ui-replace-original",
                    "replacedExpectedRevision": 1,
                    "impactAcknowledged": True,
                },
                origin=base,
            )
            replace_body = replacement_receipt["receipt"]
            assert replace_body["cardId"] == "ui-replace-new" and replace_body["replacedCardId"] == "ui-replace-original"
            assert replace_body["created"]["lifecycle"] == "active" and replace_body["superseded"]["lifecycle"] == "superseded"
            _, replaced_old, _ = request_json(opener, base, "/api/read", {"operation": "card", "cardId": "ui-replace-original"}, origin=base)
            _, replaced_new, _ = request_json(opener, base, "/api/read", {"operation": "card", "cardId": "ui-replace-new"}, origin=base)
            assert replaced_old["card"]["lifecycle"] == "superseded" and replaced_new["card"]["lifecycle"] == "active"

            _, card_history, history_headers = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "history", "cardId": "ui-note-card", "limit": 20, "offset": 0},
                origin=base,
            )
            assert len(card_history["items"]) == 1 and card_history["items"][0]["revision"] == 1
            assert "test-capability-token" not in history_headers.get("Set-Cookie", "")

            draft_payload = {"cardId": "ui-note-card", "title": "Recovered browser draft", "payload": {"body": "draft body"}}
            _, saved_draft, _ = request_json(
                opener,
                base,
                "/api/draft",
                {"operation": "save", "cardId": "ui-note-card", "baseRevision": 1, "draft": draft_payload},
                origin=base,
            )
            assert saved_draft["receipt"]["baseRevision"] == 1
            _, loaded_draft, _ = request_json(
                opener,
                base,
                "/api/draft",
                {"operation": "get", "cardId": "ui-note-card", "currentRevision": 1},
                origin=base,
            )
            assert loaded_draft["available"] is True and loaded_draft["draft"]["title"] == "Recovered browser draft"

            _, cards, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "cards", "kinds": ["note"], "query": "governed command", "limit": 20, "offset": 0},
                origin=base,
            )
            assert cards["items"][0]["cardId"] == "ui-note-card"

            _, overview, _ = request_json(opener, base, "/api/read", {"operation": "overview"}, origin=base)
            assert overview["cardsByKind"]["note"] == 2
            assert any(item["aggregateId"] == "ui-note-card" for item in overview["recentEvents"])
            assert overview["taskScope"]["status"] == "withheld"

            _, skills, _ = request_json(opener, base, "/api/read", {"operation": "skills"}, origin=base)
            assert skills["schema"] == "super-brain.ui-capabilities.v1"
            assert any(item["title"] == "任务续接" for item in skills["items"])
            skills_json = json.dumps(skills, ensure_ascii=False)
            for private_value in ("test-capability-token", str(root), "owner", "hotEntry", "coldReferencePath", "task-ui-private-control-id"):
                assert private_value not in skills_json

            _, health, _ = request_json(opener, base, "/api/read", {"operation": "health"}, origin=base)
            assert health["schema"] == "super-brain.ui-health.v1"
            assert any(item["id"] == "memory" and str(item["value"]).endswith("条已记录内容") for item in health["indicators"])
            health_json = json.dumps(health, ensure_ascii=False)
            for private_value in ("test-capability-token", str(root), "owner", "hotEntry", "coldReferencePath", "task-ui-private-control-id"):
                assert private_value not in health_json

            current_task = {
                "commandId": "ui-overview-current-task-import",
                "taskId": "task-ui-overview-current",
                "taskInstanceId": "ti-" + "1" * 32,
                "workspaceKey": "ws-ui-overview-current",
                "ownerSessionKey": "sid-" + "2" * 24,
                "packageVersion": PACKAGE_VERSION,
                "initialRevision": 0,
                "state": {
                    "lifecycle": "active",
                    "contractRevision": 1,
                    "planFingerprint": "plan-ui-overview-current",
                    "focusLabel": "当前界面回归任务",
                    "currentPhase": "P4 current UI phase",
                    "currentStep": "Display the current task only.",
                    "nextAction": "Verify the scoped UI API response.",
                    "canonicalPlan": {
                        "planId": "plan-ui-overview-current",
                        "generation": 1,
                        "items": [{"itemId": "P4", "ordinal": 1, "label": "scope runtime view", "status": "in_progress"}],
                    },
                },
                "source": "runtime_brain_ui_server_regression",
            }
            foreign_task = json.loads(json.dumps(current_task))
            foreign_task.update(
                {
                    "commandId": "ui-overview-foreign-task-import",
                    "taskId": "task-ui-overview-foreign",
                    "taskInstanceId": "ti-" + "3" * 32,
                    "workspaceKey": "ws-ui-overview-foreign",
                    "ownerSessionKey": "sid-" + "4" * 24,
                }
            )
            foreign_state = foreign_task["state"]
            assert isinstance(foreign_state, dict)
            foreign_state.update(
                {
                    "currentPhase": "Foreign UI phase",
                    "currentStep": "Foreign task details must never reach the Control Center.",
                    "nextAction": "Do not reveal this foreign UI action.",
                }
            )
            service.control.import_task(current_task)
            service.control.import_task(foreign_task)
            current_contract = {
                "schema": "super-brain.execution-contract.v1",
                "taskId": current_task["taskId"],
                "taskInstanceId": current_task["taskInstanceId"],
                "workspaceKey": current_task["workspaceKey"],
                "ownerSessionKey": current_task["ownerSessionKey"],
                "status": "active",
                "revision": 1,
                "currentPhase": "P4 current UI phase",
                "currentStep": "Display the current task only.",
                "nextAction": "Verify the scoped UI API response.",
                "conversationTitle": "控制中心页面回归",
                "updatedAt": "2026-07-28T10:02:00Z",
            }
            (service.control.workspace / "last-execution-contract.json").write_text(
                json.dumps(current_contract), encoding="utf-8"
            )

            completed_task = json.loads(json.dumps(current_task))
            completed_task.update(
                {
                    "commandId": "ui-task-history-completed-import",
                    "taskId": "task-ui-history-completed-private-id",
                    "taskInstanceId": "ti-" + "5" * 32,
                    "ownerSessionKey": "sid-" + "6" * 24,
                }
            )
            completed_state = completed_task["state"]
            assert isinstance(completed_state, dict)
            completed_state.update(
                {
                    "lifecycle": "completed",
                    "focusLabel": "界面历史完成任务",
                    "currentStep": "任务已完成，等待整理",
                    "nextAction": "保留任务证据",
                    "completedAt": (datetime.now(UTC) - timedelta(days=46)).isoformat().replace("+00:00", "Z"),
                }
            )
            service.control.import_task(completed_task)
            trashed_task = json.loads(json.dumps(current_task))
            trashed_task.update(
                {
                    "commandId": "ui-task-history-trash-import",
                    "taskId": "task-ui-history-trash-private-id",
                    "taskInstanceId": "ti-" + "7" * 32,
                    "ownerSessionKey": "sid-" + "8" * 24,
                }
            )
            trashed_state = trashed_task["state"]
            assert isinstance(trashed_state, dict)
            trashed_state.update(
                {
                    "lifecycle": "completed",
                    "focusLabel": "界面历史回收站任务",
                    "currentStep": "任务已完成，等待恢复或过期",
                    "nextAction": "保留任务证据",
                    "completedAt": (datetime.now(UTC) - timedelta(days=16)).isoformat().replace("+00:00", "Z"),
                }
            )
            service.control.import_task(trashed_task)
            _, scoped_overview, _ = request_json(opener, base, "/api/read", {"operation": "overview"}, origin=base)
            assert scoped_overview["taskScope"]["status"] == "bound"
            assert [task["taskId"] for task in scoped_overview["tasks"]] == ["task-ui-overview-current"]
            assert "task-ui-overview-foreign" not in json.dumps(scoped_overview)
            assert "Foreign task details must never reach the Control Center." not in json.dumps(scoped_overview)

            _, task_history, _ = request_json(opener, base, "/api/read", {"operation": "task_history", "limit": 20}, origin=base)
            history_item = next(item for item in task_history["items"] if item["title"] == "界面历史回收站任务")
            assert history_item["statusLabel"] == "已完成" and history_item["retentionState"] == "trashed"
            assert all(item["title"] != "界面历史完成任务" for item in task_history["items"])
            assert task_history["counts"]["evidenceOnly"] >= 1
            assert task_history["completionEvidence"]["count"] >= 1
            assert "task-ui-history-completed-private-id" not in json.dumps(task_history)
            _, retention_preview, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "task_retention_preview", "completedDays": 7, "trashDays": 15},
                origin=base,
            )
            assert retention_preview["schema"] == "super-brain.task-retention-preview.v2"
            assert retention_preview["counts"]["evidenceOnly"] >= 1
            assert any(item["title"] == "界面历史完成任务" for item in retention_preview["impacts"]["compactEvidence"])
            assert "task-ui-history-completed-private-id" not in json.dumps(retention_preview)
            _, saved_retention, _ = request_json(
                opener,
                base,
                "/api/command",
                {
                    "action": "update_task_retention",
                    "requestId": "ui-save-task-retention",
                    "completedDays": 8,
                    "trashDays": 15,
                    "expectedRevision": task_history["settings"]["revision"],
                },
                origin=base,
            )
            assert saved_retention["receipt"]["settings"]["completedDays"] == 8
            assert saved_retention["receipt"]["settings"]["compactEvidenceDays"] == 30
            assert saved_retention["delivery"]["status"] == "not_required"
            _, restored_task_card, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "restore_task_card", "requestId": "ui-restore-task-card", "taskCardKey": history_item["taskCardKey"]},
                origin=base,
            )
            assert restored_task_card["receipt"]["retentionState"] == "visible"
            _, refreshed_history, _ = request_json(opener, base, "/api/read", {"operation": "task_history", "limit": 20}, origin=base)
            refreshed_item = next(item for item in refreshed_history["items"] if item["title"] == "界面历史回收站任务")
            assert refreshed_item["retentionState"] == "visible" and refreshed_item["canRestore"] is False

            timeline_card = {
                **card,
                "cardId": "ui-timeline-card-private-id",
                "title": "Timeline source note",
                "payload": {
                    "schema": "super-brain.card.note.v1",
                    "body": "This memory should retain only its verified task and conversation source.",
                    "tags": [],
                    "links": [],
                    "pinned": False,
                },
            }
            _, timeline_created, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "create", "requestId": "ui-create-timeline-note", "cardId": "ui-timeline-card-private-id", "expectedRevision": 0, "card": timeline_card},
                origin=base,
            )
            assert timeline_created["receipt"]["revision"] == 1
            _, timeline, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "timeline", "limit": 20, "offset": 0},
                origin=base,
            )
            entry = next(item for item in timeline["items"] if item["title"] == "Timeline source note")
            assert entry["kindLabel"] == "笔记" and entry["date"]
            assert entry["cardRef"].startswith("card-")
            assert entry["source"] == {"taskTitle": "当前界面回归任务", "conversationTitle": "控制中心页面回归"}
            timeline_json = json.dumps(timeline, ensure_ascii=False)
            for private_value in ("ui-timeline-card-private-id", "task-ui-overview-current", "ws-ui-overview-current", "sid-" + "2" * 24, str(root)):
                assert private_value not in timeline_json
            _, timeline_detail, _ = request_json(opener, base, "/api/read", {"operation": "card", "cardRef": entry["cardRef"]}, origin=base)
            assert timeline_detail["card"]["title"] == "Timeline source note"

            _, starmap, _ = request_json(opener, base, "/api/read", {"operation": "starmap"}, origin=base)
            assert starmap["schema"] == "super-brain.ui-memory-starmap.v1"
            assert any(node["title"] == "Timeline source note" for node in starmap["nodes"])
            assert any(node["kind"] == "task" for node in starmap["nodes"])
            starmap_json = json.dumps(starmap, ensure_ascii=False)
            for private_value in ("ui-timeline-card-private-id", "task-ui-overview-current", "ws-ui-overview-current", "sid-" + "2" * 24, str(root)):
                assert private_value not in starmap_json

            _, detail, _ = request_json(opener, base, "/api/read", {"operation": "card", "cardId": "ui-note-card"}, origin=base)
            assert detail["card"]["payload"]["body"].startswith("The UI must save")

            stale, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {"action": "edit", "requestId": "ui-stale-edit", "cardId": "ui-note-card", "expectedRevision": 2, "card": card},
                    origin=base,
                ),
                409,
            )
            assert stale["code"] == "BRAIN_CONTROL_STALE_REVISION"
            assert str(root) not in json.dumps(stale)

            _, forgotten, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "forget", "requestId": "ui-forget-note", "cardId": "ui-note-card", "expectedRevision": 1, "forgetAcknowledged": True},
                origin=base,
            )
            assert forgotten["receipt"]["lifecycle"] == "forgotten"
            _, discarded_draft, _ = request_json(
                opener,
                base,
                "/api/draft",
                {"operation": "get", "cardId": "ui-note-card", "currentRevision": 2},
                origin=base,
            )
            assert discarded_draft["available"] is False
            _, forgotten_detail, _ = request_json(opener, base, "/api/read", {"operation": "card", "cardId": "ui-note-card"}, origin=base)
            assert forgotten_detail["card"]["forgotten"] is True
            assert "body" not in forgotten_detail["card"]["payload"]

            trash_delete_cards = []
            for suffix in ("one", "two"):
                trash_delete_card = {
                    **card,
                    "cardId": f"ui-trash-delete-{suffix}",
                    "title": f"Trash deletion {suffix}",
                    "payload": {
                        "schema": "super-brain.card.note.v1",
                        "body": f"This private body must disappear after permanent Trash deletion ({suffix}).",
                        "tags": ["trash-delete"],
                        "links": [],
                        "pinned": False,
                    },
                }
                _, trash_created, _ = request_json(
                    opener,
                    base,
                    "/api/command",
                    {"action": "create", "requestId": f"ui-create-trash-delete-{suffix}", "cardId": trash_delete_card["cardId"], "expectedRevision": 0, "card": trash_delete_card},
                    origin=base,
                )
                assert trash_created["receipt"]["revision"] == 1
                _, trashed, _ = request_json(
                    opener,
                    base,
                    "/api/command",
                    {"action": "trash", "requestId": f"ui-trash-delete-{suffix}", "cardId": trash_delete_card["cardId"], "expectedRevision": 1},
                    origin=base,
                )
                assert trashed["receipt"]["lifecycle"] == "trashed" and trashed["receipt"]["revision"] == 2
                trash_delete_cards.append({"cardId": trash_delete_card["cardId"], "expectedRevision": 2})

            _, trash_listing, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "cards", "lifecycles": ["trashed"], "limit": 100, "offset": 0},
                origin=base,
            )
            trash_rows = {item["cardId"]: item for item in trash_listing["items"]}
            assert all(item["cardId"] in trash_rows and trash_rows[item["cardId"]]["revision"] == item["expectedRevision"] for item in trash_delete_cards)

            missing_trash_acknowledgement, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {"action": "delete_trashed_batch", "requestId": "ui-delete-trash-batch-unacknowledged", "cards": [trash_delete_cards[0]]},
                    origin=base,
                ),
                400,
            )
            assert missing_trash_acknowledgement["code"] == "BRAIN_UI_TRASH_DELETE_ACKNOWLEDGEMENT_REQUIRED"

            stale_trash_delete, _ = expect_http_error(
                lambda: request_json(
                    opener,
                    base,
                    "/api/command",
                    {
                        "action": "delete_trashed_batch",
                        "requestId": "ui-delete-trash-batch-stale",
                        "cards": [trash_delete_cards[0], {**trash_delete_cards[1], "expectedRevision": 1}],
                        "deleteAcknowledged": True,
                    },
                    origin=base,
                ),
                409,
            )
            assert stale_trash_delete["code"] == "BRAIN_CONTROL_STALE_REVISION"
            _, still_trashed, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "cards", "lifecycles": ["trashed"], "limit": 100, "offset": 0},
                origin=base,
            )
            assert {item["cardId"] for item in trash_delete_cards}.issubset({item["cardId"] for item in still_trashed["items"]})

            _, trash_deleted, _ = request_json(
                opener,
                base,
                "/api/command",
                {"action": "delete_trashed_batch", "requestId": "ui-delete-trash-batch", "cards": trash_delete_cards, "deleteAcknowledged": True},
                origin=base,
            )
            assert trash_deleted["receipt"]["schema"] == "super-brain.ui-trash-delete-receipt.v1"
            assert trash_deleted["receipt"]["deletedCount"] == 2
            assert trash_deleted["receipt"]["physicalSecureErasureClaim"] is False
            _, empty_trash_rows, _ = request_json(
                opener,
                base,
                "/api/read",
                {"operation": "cards", "lifecycles": ["trashed"], "limit": 100, "offset": 0},
                origin=base,
            )
            assert not {item["cardId"] for item in trash_delete_cards}.intersection({item["cardId"] for item in empty_trash_rows["items"]})
            _, trash_tombstone, _ = request_json(opener, base, "/api/read", {"operation": "card", "cardId": "ui-trash-delete-one"}, origin=base)
            assert trash_tombstone["card"]["forgotten"] is True
            assert "body" not in trash_tombstone["card"]["payload"]

            query_request = Request(base + "/api/read?private=body", method="GET")
            invalid_query, _ = expect_http_error(lambda: urlopen(query_request, timeout=3), 405)
            assert invalid_query["code"] == "BRAIN_UI_POST_REQUIRED"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    print("RUNTIME_BRAIN_UI_SERVER_REGRESSION_OK")


if __name__ == "__main__":
    main()
