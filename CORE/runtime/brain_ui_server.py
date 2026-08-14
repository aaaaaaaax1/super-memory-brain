from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import threading
import time
import uuid
import webbrowser
from dataclasses import dataclass
from datetime import UTC, datetime
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import urlparse

from brain_control import ACTOR_RECEIPT_SCHEMA, BrainControl, BrainControlError


MAX_BODY_BYTES = 64 * 1024
COOKIE_NAME = "super_brain_control_cap"
LEASE_SCHEMA = "super-brain.ui-service-lease.v1"
API_SCHEMA = "super-brain.ui-api.v1"

# A reflection is not a generic "experience" shortcut.  Only these typed
# memories can be promoted by this small Control Center transaction.  Decisions
# stay on the dedicated receipt-bound path; notes/reflections remain review
# material and must fail closed here.
REFLECTION_PROMOTABLE_KINDS = frozenset({"preference", "experience", "procedure"})
REFLECTION_NON_PROMOTABLE_KINDS = frozenset({"decision", "note", "reflection"})
REFLECTION_KIND_LABELS = {
    "preference": "偏好",
    "experience": "经验",
    "procedure": "流程",
    "decision": "决定",
    "note": "笔记",
    "reflection": "自我学习",
}
TRIAL_VERDICTS = frozenset({"passed", "failed", "inconclusive"})
TRIAL_STATES = frozenset({"not_started", "observed", "closed"})


# Keep the Control Center vocabulary user-facing. Package paths, owners, and
# implementation details remain internal to the local runtime.
USER_CAPABILITY_COPY: dict[str, tuple[str, str]] = {
    "memory_governance": ("记忆管理", "在需要时找回已确认的信息，并保护本地内容不被整段塞进对话。"),
    "status_recovery": ("任务续接", "在中断、压缩或切换后找回当前任务、进度和下一步。"),
    "task_state_consistency": ("计划与状态", "让主线、支线、已完成和待办保持一致，避免只记住最近一句。"),
    "orc_routing": ("任务协作", "遇到复杂工作时选择合适的能力和执行顺序。"),
    "engineering_judgment": ("工程判断", "比较方案、发现风险，并在宣布完成前核对真实结果。"),
    "technology_decision": ("技术选型", "根据环境、性能、维护和团队条件比较技术方案。"),
    "collaborative_intent": ("需求理解", "先理解功能在产品里的作用和影响，再决定怎样实现。"),
    "automatic_evolution_policy": ("学习与改进", "把重复问题转成待验证的改进，不把猜测直接当成规则。"),
    "anti_degradation_guard": ("质量保护", "把事实、推断和未知分开，并在关键产出前做必要验证。"),
}


def _utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _safe_request_id(value: Any) -> str:
    if value in (None, ""):
        return uuid.uuid4().hex
    if not isinstance(value, str) or not value or len(value) > 96:
        raise BrainControlError("BRAIN_UI_REQUEST_ID_INVALID", "requestId is invalid")
    if not all(character.isascii() and (character.isalnum() or character in "_-") for character in value):
        raise BrainControlError("BRAIN_UI_REQUEST_ID_INVALID", "requestId is invalid")
    return value


def _optional_string(value: Any, field: str, maximum: int = 256) -> str:
    if value in (None, ""):
        return ""
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > maximum:
        raise BrainControlError("BRAIN_UI_REQUEST_INVALID", f"{field} is invalid")
    return value.strip()


def _require_mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise BrainControlError("BRAIN_UI_REQUEST_INVALID", f"{field} must be an object")
    return dict(value)


def _require_integer(value: Any, field: str, *, minimum: int = 0, maximum: int = 1_000_000) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum or value > maximum:
        raise BrainControlError("BRAIN_UI_REQUEST_INVALID", f"{field} is invalid")
    return value


def _require_boolean(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise BrainControlError("BRAIN_UI_REQUEST_INVALID", f"{field} is invalid")
    return value


def _capture_title(problem: str) -> str:
    """Derive a short, readable note title without asking the user for one."""

    compact = re.sub(r"\s+", " ", problem).strip()
    first_line = re.split(r"[\r\n。！？!?]", compact, maxsplit=1)[0].strip()
    return (first_line or compact)[:120]


def _capture_suggested_kind(problem: str, desired_action: str) -> str:
    """Return a non-authorizing hint for later governed enrichment.

    The first capture remains a reference note.  This hint can help the
    learning flow decide which typed candidate to prepare later, but it never
    changes behavior, creates a decision receipt, or promotes a rule by itself.
    """

    source = f"{problem}\n{desired_action}".lower()
    if re.search(r"偏好|希望你|以后都|默认|喜欢|习惯|prefer|always|default", source):
        return "preference"
    if re.search(r"经验|教训|踩坑|避免|下次|复用|lesson|avoid|reuse", source):
        return "experience"
    if re.search(r"流程|步骤|先.*再|然后|验收|procedure|step|verify", source):
        return "procedure"
    if re.search(r"决定|选择|采用|定下来|decision|choose", source):
        return "decision"
    if re.search(r"反思|改进|问题|假设|review|improve|hypothesis", source):
        return "reflection"
    return "note"


def _reflection_suggested_kind(payload: Mapping[str, Any]) -> str:
    """Read exactly one persisted ``建议:`` tag from a reflection.

    The native candidate uses ``系统学习候选``/``待用户采纳`` tags rather
    than the quick-capture ``待学习`` tag, so this parser intentionally does
    not reuse BrainControl's note-only suggestion helper.  A missing, duplicate,
    or unknown suggestion is ambiguous and therefore returns an empty value.
    """

    explicit = str(payload.get("suggestedKind", "")).strip().lower()
    if explicit and explicit not in (REFLECTION_PROMOTABLE_KINDS | REFLECTION_NON_PROMOTABLE_KINDS):
        return ""
    tags = payload.get("tags")
    if not isinstance(tags, list):
        return explicit
    suggestions: list[str] = []
    for item in tags:
        if not isinstance(item, str):
            continue
        normalized = item.strip()
        if normalized.startswith("建议："):
            suggestions.append(normalized[len("建议：") :].strip().lower())
        elif normalized.startswith("建议:"):
            suggestions.append(normalized[len("建议:") :].strip().lower())
    if len(suggestions) > 1:
        return ""
    tagged = suggestions[0] if suggestions else ""
    if tagged and tagged not in (REFLECTION_PROMOTABLE_KINDS | REFLECTION_NON_PROMOTABLE_KINDS):
        return ""
    if explicit and tagged and explicit != tagged:
        return ""
    return explicit or tagged


def _reflection_trial_projection(payload: Mapping[str, Any]) -> dict[str, Any]:
    """Return a small, user-safe trial projection without inventing success."""

    nested = payload.get("trial")
    trial = nested if isinstance(nested, Mapping) else {}
    raw_verdict = payload.get("trialVerdict", payload.get("verdict", trial.get("verdict", "")))
    verdict = str(raw_verdict).strip().lower() if raw_verdict is not None else ""
    if verdict not in TRIAL_VERDICTS:
        verdict = "inconclusive"
    raw_state = payload.get("trialState", payload.get("state", trial.get("state", "")))
    state = str(raw_state).strip().lower() if raw_state is not None else ""
    if state not in TRIAL_STATES:
        state = "closed" if verdict in {"passed", "failed"} else "observed"
    has_receipt = bool(payload.get("trialReceiptHash") or payload.get("receiptHash") or trial.get("receiptHash"))
    if verdict == "passed" and not has_receipt:
        verdict = "inconclusive"
        state = "observed"
    elif verdict == "inconclusive" and state == "not_started":
        state = "observed"
    return {
        "verdict": verdict,
        "trialState": state,
        "hasEvidence": bool(payload.get("evidence")),
        "hasReceipt": has_receipt,
    }


@dataclass
class UiService:
    state_root: Path
    assets_root: Path
    idle_seconds: int
    instance_id: str
    capability_token: str
    workspace_key: str = ""

    def __post_init__(self) -> None:
        self.state_root = self.state_root.expanduser().resolve()
        self.assets_root = self.assets_root.expanduser().resolve()
        self.workspace_key = self.workspace_key.strip().lower()
        self.control = BrainControl(self.state_root, ui_workspace_key=self.workspace_key)
        self._capability_secret = self.capability_token.encode("utf-8")
        self._activity_lock = threading.Lock()
        self._last_activity = time.monotonic()
        self.port = 0

    @property
    def lease_path(self) -> Path:
        if self.workspace_key:
            token = hashlib.sha256(self.workspace_key.encode("utf-8")).hexdigest()[:16]
            return self.state_root / "workspace" / "ui-service-leases" / f"{token}.json"
        return self.state_root / "workspace" / "ui-service-lease.json"

    @property
    def origin(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def touch(self) -> None:
        with self._activity_lock:
            self._last_activity = time.monotonic()

    def issue_capability(self) -> str:
        """Issue a bounded, server-verifiable loopback capability cookie."""

        expires_at = int(time.time()) + self.idle_seconds
        nonce = secrets.token_urlsafe(12)
        material = f"{expires_at}.{nonce}".encode("ascii")
        signature = hmac.new(self._capability_secret, material, hashlib.sha256).hexdigest()
        return f"{expires_at}.{nonce}.{signature}"

    def capability_is_valid(self, value: str) -> bool:
        parts = value.split(".")
        if len(parts) != 3:
            return False
        expires_text, nonce, signature = parts
        if not expires_text.isdigit() or len(nonce) < 12 or len(signature) != 64:
            return False
        try:
            expires_at = int(expires_text)
        except ValueError:
            return False
        if expires_at <= int(time.time()):
            return False
        material = f"{expires_text}.{nonce}".encode("ascii")
        expected = hmac.new(self._capability_secret, material, hashlib.sha256).hexdigest()
        return secrets.compare_digest(signature, expected)

    def is_idle(self) -> bool:
        with self._activity_lock:
            return time.monotonic() - self._last_activity >= self.idle_seconds

    def write_lease(self) -> None:
        self.lease_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "schema": LEASE_SCHEMA,
            "instanceId": self.instance_id,
            "pid": os.getpid(),
            "port": self.port,
            "url": self.origin + "/",
            "startedAt": _utc_now(),
            "workspaceKey": self.workspace_key,
        }
        temporary = self.lease_path.with_name(self.lease_path.name + ".tmp-" + uuid.uuid4().hex)
        temporary.write_text(json.dumps(payload, ensure_ascii=True, separators=(",", ":")), encoding="utf-8")
        os.replace(temporary, self.lease_path)

    def remove_lease(self) -> None:
        try:
            current = json.loads(self.lease_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return
        if isinstance(current, Mapping) and current.get("instanceId") == self.instance_id:
            try:
                self.lease_path.unlink()
            except OSError:
                pass

    def actor_receipt(self, command_id: str, action: str) -> dict[str, str]:
        receipt_material = f"{self.instance_id}:{command_id}:{action}".encode("utf-8")
        return {
            "schema": ACTOR_RECEIPT_SCHEMA,
            "actorKind": "user",
            "actorId": "loopback-control-center",
            "authorization": "user_confirmed",
            "authorizationReceipt": hashlib.sha256(receipt_material).hexdigest(),
        }

    def list_capabilities_for_ui(self) -> dict[str, Any]:
        package_root = Path(__file__).resolve().parents[1]
        capability_path = package_root / "capabilities.json"
        try:
            payload = json.loads(capability_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        raw_capabilities = payload.get("capabilities") if isinstance(payload, Mapping) else []
        items: list[dict[str, str]] = []
        if isinstance(raw_capabilities, list):
            for raw in raw_capabilities:
                if not isinstance(raw, Mapping):
                    continue
                capability_id = raw.get("id")
                if not isinstance(capability_id, str) or capability_id not in USER_CAPABILITY_COPY:
                    continue
                title, description = USER_CAPABILITY_COPY[capability_id]
                items.append({"id": capability_id, "title": title, "description": description, "state": "可用"})
        return {"ok": True, "schema": "super-brain.ui-capabilities.v1", "items": items}

    def health_for_ui(self) -> dict[str, Any]:
        status = self.control.status()
        overview = self.control.control_center_overview()
        tasks = overview.get("tasks") if isinstance(overview.get("tasks"), list) else []
        current_task = tasks[0] if tasks and isinstance(tasks[0], Mapping) else {}
        display = current_task.get("display") if isinstance(current_task.get("display"), Mapping) else {}
        card_count = int(status.get("cards", 0))
        pending_outbox = int(overview.get("pendingOutbox", 0))
        task_title = _optional_string(display.get("title"), "health.taskTitle", 160) if display else ""
        task_state = _optional_string(display.get("statusLabel"), "health.taskState", 48) if display else ""
        indicators = [
            {
                "id": "memory",
                "title": "本地记忆",
                "value": f"{card_count} 条已记录内容",
                "state": "normal",
                "description": "内容保存在本机，只有当前工作确实需要时才会参与判断。",
            },
            {
                "id": "task",
                "title": "当前任务",
                "value": task_state or "暂无进行中的任务",
                "state": "normal" if task_state else "quiet",
                "description": task_title or "开始任务后，这里会显示当前进度与下一步。",
            },
            {
                "id": "sync",
                "title": "本地同步",
                "value": "已同步" if pending_outbox == 0 else f"{pending_outbox} 项等待同步",
                "state": "normal" if pending_outbox == 0 else "attention",
                "description": "保存后的本地视图会在受控写入完成后更新。",
            },
            {
                "id": "protection",
                "title": "本地保护",
                "value": "已开启",
                "state": "normal",
                "description": "控制中心只在这台电脑上运行，页面不能直接修改数据库。",
            },
        ]
        return {"ok": True, "schema": "super-brain.ui-health.v1", "indicators": indicators}

    def adopt_reflection_for_ui(
        self,
        *,
        reflection_card_id: str,
        expected_revision: int,
        adopted_card_id: str = "",
        experience_card_id: str = "",
        requested_kind: str = "",
        reason: str,
    ) -> dict[str, Any]:
        """Atomically promote one evidenced reflection into its suggested kind.

        The target is derived from the persisted suggestion tag.  A caller may
        provide ``requested_kind`` as a consistency check, but it never chooses
        a different target.  ``experience_card_id`` remains a compatibility
        alias for older clients that only know the experience path.
        """

        source = self.control.get_card(reflection_card_id)
        if source is None:
            raise BrainControlError("BRAIN_CONTROL_CARD_NOT_FOUND", "reflection card was not found")
        if str(source.get("kind")) != "reflection":
            raise BrainControlError("BRAIN_UI_REFLECTION_KIND_REQUIRED", "only reflection cards can be adopted")
        if int(source.get("revision", 0)) != expected_revision:
            raise BrainControlError("BRAIN_CONTROL_STALE_REVISION", "reflection changed; refresh before adoption")
        if str(source.get("lifecycle")) not in {"active", "proposed"}:
            raise BrainControlError("BRAIN_UI_REFLECTION_LIFECYCLE_INVALID", "reflection is not available for adoption")
        payload = source.get("payload")
        if not isinstance(payload, Mapping):
            raise BrainControlError("BRAIN_UI_REFLECTION_PAYLOAD_INVALID", "reflection payload is invalid")
        state = str(payload.get("candidateState", "")).lower()
        if state not in {"validated", "staged"}:
            raise BrainControlError("BRAIN_UI_REFLECTION_NOT_READY", "reflection must be verified or staged before adoption")
        evidence = [str(item).strip() for item in payload.get("evidence", []) if isinstance(item, str) and item.strip()]
        if not evidence:
            raise BrainControlError("BRAIN_CONTROL_REFLECTION_EVIDENCE_REQUIRED", "reflection needs evidence before adoption")
        scope = source.get("scope")
        if not isinstance(scope, Mapping):
            raise BrainControlError("BRAIN_UI_REFLECTION_SCOPE_INVALID", "reflection scope is invalid")
        authority = str(source.get("authority", ""))
        suggested_kind = _reflection_suggested_kind(payload)
        legacy_experience_fallback = False
        if not suggested_kind:
            # Preserve the pre-typed API for user-authored reflections only.
            # System candidates without a unique suggestion must never silently
            # become experiences.
            if authority == "system" or not experience_card_id or (adopted_card_id and adopted_card_id != experience_card_id):
                raise BrainControlError(
                    "BRAIN_UI_REFLECTION_SUGGESTION_INVALID",
                    "reflection has no unique promotable suggestion",
                )
            suggested_kind = "experience"
            legacy_experience_fallback = True
        requested_kind = requested_kind.strip().lower()
        if requested_kind and requested_kind != suggested_kind:
            raise BrainControlError(
                "BRAIN_UI_REFLECTION_TARGET_MISMATCH",
                "requested target does not match the persisted suggestion",
            )
        if suggested_kind not in REFLECTION_PROMOTABLE_KINDS:
            label = REFLECTION_KIND_LABELS.get(suggested_kind, "此类型")
            raise BrainControlError(
                "BRAIN_UI_REFLECTION_TARGET_NOT_PROMOTABLE",
                f"{label}候选必须通过专门流程确认，不能从这里直接采纳",
            )
        controlled_trial = self.control.get_learning_trial_for_card(reflection_card_id)
        trial = _reflection_trial_projection(controlled_trial)
        if authority == "system" and (trial["verdict"] != "passed" or not trial["hasReceipt"]):
            raise BrainControlError(
                "BRAIN_UI_REFLECTION_TRIAL_NOT_PASSED",
                "system learning candidates require a passed trial receipt before adoption",
            )
        target_card_id = (adopted_card_id or experience_card_id).strip()
        if not target_card_id:
            raise BrainControlError("BRAIN_UI_REFLECTION_TARGET_ID_REQUIRED", "adopted card id is required")
        reflection_title = _optional_string(source.get("title"), "reflection.title", 240)
        target_label = REFLECTION_KIND_LABELS[suggested_kind]
        target_title = (target_label + "：" + reflection_title)[:240]
        tags = list(payload.get("tags", [])) if isinstance(payload.get("tags"), list) else []
        observation = str(payload.get("observation", "")).strip()
        hypothesis = str(payload.get("hypothesis", "")).strip()
        proposed_action = str(payload.get("proposedAction", "")).strip()
        confidence = payload.get("confidence", 0)
        try:
            confidence = max(0, min(100, int(confidence)))
        except (TypeError, ValueError):
            confidence = 0
        if suggested_kind == "experience":
            target_payload = {
                "schema": "super-brain.card.experience.v1",
                "context": observation,
                "outcome": "\n".join(evidence)[:1200],
                "lesson": proposed_action,
                "reuseConditions": [],
                "trigger": reflection_title[:600],
                "rootCause": hypothesis,
                "prevention": proposed_action,
                "recurrence": 0,
                "validationState": "adopted",
                "revalidateAfter": "",
                "tags": tags,
            }
        elif suggested_kind == "preference":
            # A system candidate begins at deliberately low confidence.  Once a
            # task-scoped trial has passed and the user confirms adoption, raise
            # it only to the existing minimum behavior-guidance threshold.
            preference_confidence = max(60, confidence) if authority == "system" and trial["verdict"] == "passed" else confidence
            target_payload = {
                "schema": "super-brain.card.preference.v1",
                "statement": proposed_action,
                "conditions": [observation] if observation else [],
                "confidence": preference_confidence,
                "evidenceUses": 1 if authority == "system" and trial["verdict"] == "passed" else 0,
                "conflictState": "clear",
                "revalidateAfter": "",
                "tags": tags,
            }
        else:  # procedure
            target_payload = {
                "schema": "super-brain.card.procedure.v1",
                "objective": observation or reflection_title,
                "preconditions": [],
                "steps": [proposed_action],
                "verification": evidence[:6],
                "tags": tags,
            }
        adopted_payload = dict(payload)
        adopted_payload["candidateState"] = "adopted"
        adoption_note = f"已整理为{target_label}：{target_title}"
        if adoption_note not in evidence and len(evidence) < 12:
            adopted_payload["evidence"] = evidence + [adoption_note]
        create_command_id = "ui-adopt-reflection-" + target_card_id + "-create"
        update_command_id = "ui-adopt-reflection-" + reflection_card_id + "-update"
        create_command = {
            "commandType": "create_card",
            "commandId": create_command_id,
            "aggregateId": target_card_id,
            "expectedRevision": 0,
            "kind": suggested_kind,
            "scope": dict(scope),
            "lifecycle": "active",
            "authority": "user_confirmed",
            "privacyClass": str(source.get("privacyClass", "private")),
            "title": target_title,
            "payload": target_payload,
            "evidenceRefs": list(source.get("evidenceRefs", [])),
            "actorReceipt": self.actor_receipt(create_command_id, "adopt_reflection_create_" + suggested_kind),
            "reason": reason,
            "source": "loopback_control_center",
        }
        update_command = {
            "commandType": "edit_card",
            "commandId": update_command_id,
            "aggregateId": reflection_card_id,
            "expectedRevision": expected_revision,
            "kind": "reflection",
            "scope": dict(scope),
            "lifecycle": str(source.get("lifecycle")),
            "authority": authority or "user_confirmed",
            "privacyClass": str(source.get("privacyClass", "private")),
            "title": reflection_title,
            "payload": adopted_payload,
            "evidenceRefs": list(source.get("evidenceRefs", [])),
            "actorReceipt": self.actor_receipt(update_command_id, "adopt_reflection_mark_source"),
            "reason": reason,
            "source": "loopback_control_center_reflection_adoption",
        }
        adopted, reflection = self.control.apply_many_atomically([create_command, update_command])
        target_receipt = {
            "cardId": target_card_id,
            "revision": adopted["revision"],
            "kind": suggested_kind,
            "title": target_title,
        }
        result = {
            "ok": True,
            "schema": "super-brain.ui-reflection-adoption.v1",
            "reflection": {"cardId": reflection_card_id, "revision": reflection["revision"], "candidateState": "adopted"},
            "adopted": target_receipt,
            "suggestedKind": suggested_kind,
            "trial": trial,
            "legacyExperienceFallback": legacy_experience_fallback,
        }
        # Keep the old response shape for existing clients when the selected
        # target really is an experience.
        if suggested_kind == "experience":
            result["experience"] = target_receipt
        return result

    def dispatch_read(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        operation = _optional_string(payload.get("operation"), "operation", 48)
        if operation == "cards":
            kinds = payload.get("kinds")
            lifecycles = payload.get("lifecycles")
            if kinds is not None and not isinstance(kinds, list):
                raise BrainControlError("BRAIN_UI_REQUEST_INVALID", "kinds must be a list")
            if lifecycles is not None and not isinstance(lifecycles, list):
                raise BrainControlError("BRAIN_UI_REQUEST_INVALID", "lifecycles must be a list")
            common = {
                "kinds": [str(item) for item in kinds] if isinstance(kinds, list) else None,
                "lifecycles": [str(item) for item in lifecycles] if isinstance(lifecycles, list) else None,
                "scope_kind": _optional_string(payload.get("scopeKind"), "scopeKind", 64),
                "scope_key": _optional_string(payload.get("scopeKey"), "scopeKey", 256),
                "limit": _require_integer(payload.get("limit", 50), "limit", minimum=1, maximum=100),
                "offset": _require_integer(payload.get("offset", 0), "offset", minimum=0, maximum=10_000),
            }
            query = _optional_string(payload.get("query"), "query", 240)
            return self.control.search_cards_for_ui(query, **common) if query else self.control.list_cards_for_ui(**common)
        if operation == "card":
            card_id = _optional_string(payload.get("cardId"), "cardId", 160)
            card_ref = _optional_string(payload.get("cardRef"), "cardRef", 80)
            if card_id and card_ref:
                raise BrainControlError("BRAIN_UI_CARD_REFERENCE_AMBIGUOUS", "provide cardId or cardRef, not both")
            card = self.control.get_card_for_ui_reference(card_ref) if card_ref else self.control.get_card_for_ui(card_id)
            if isinstance(card, Mapping) and str(card.get("kind", "")) == "reflection":
                card = dict(card)
                card["trial"] = _reflection_trial_projection(card.get("trial") if isinstance(card.get("trial"), Mapping) else {})
            return {"ok": True, "schema": "super-brain.ui-card-detail.v1", "card": card}
        if operation == "history":
            return self.control.get_card_history_for_ui(
                _optional_string(payload.get("cardId"), "cardId", 160),
                limit=_require_integer(payload.get("limit", 50), "limit", minimum=1, maximum=100),
                offset=_require_integer(payload.get("offset", 0), "offset", minimum=0, maximum=10_000),
            )
        if operation == "status":
            status = self.control.status()
            return {
                "ok": True,
                "schema": "super-brain.ui-status.v1",
                "schemaVersion": status["schemaVersion"],
                "cards": status["cards"],
                "events": status["events"],
                "pendingOutbox": status["pendingOutbox"],
            }
        if operation == "skills":
            return self.list_capabilities_for_ui()
        if operation == "health":
            return self.health_for_ui()
        if operation == "profile":
            return self.control.profile_for_ui()
        if operation == "overview":
            return self.control.control_center_overview()
        if operation == "task_history":
            return self.control.task_history_for_ui(
                limit=_require_integer(payload.get("limit", 80), "limit", minimum=1, maximum=100),
            )
        if operation == "task_retention_preview":
            return self.control.preview_task_retention_for_ui(
                completed_days=_require_integer(payload.get("completedDays"), "completedDays", minimum=1, maximum=3650),
                trash_days=_require_integer(payload.get("trashDays"), "trashDays", minimum=1, maximum=3650),
            )
        if operation == "timeline":
            return self.control.list_memory_timeline_for_ui(
                limit=_require_integer(payload.get("limit", 100), "limit", minimum=1, maximum=200),
                offset=_require_integer(payload.get("offset", 0), "offset", minimum=0, maximum=10_000),
            )
        if operation == "starmap":
            return self.control.list_memory_starmap_for_ui()
        if operation == "learning_plan":
            scope_kind = _optional_string(payload.get("scopeKind"), "scopeKind", 64) or "global"
            scope_key = _optional_string(payload.get("scopeKey"), "scopeKey", 256) or "user"
            privacy_class = _optional_string(payload.get("privacyClass"), "privacyClass", 32) or "private"
            stale_after_days = payload.get("staleAfterDays")
            if stale_after_days is not None:
                stale_after_days = _require_integer(stale_after_days, "staleAfterDays", minimum=1, maximum=3650)
            return self.control.plan_offline_memory_consolidation(
                {
                    "scope": {"kind": scope_kind, "key": scope_key},
                    "privacyClass": privacy_class,
                    "maxProposals": _require_integer(payload.get("maxProposals", 24), "maxProposals", minimum=1, maximum=64),
                    "staleAfterDays": stale_after_days,
                }
            )
        raise BrainControlError("BRAIN_UI_READ_UNSUPPORTED", "read operation is unsupported")

    def dispatch_command(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        action = _optional_string(payload.get("action"), "action", 48)
        request_id = _safe_request_id(payload.get("requestId"))
        command_id = "ui-" + request_id
        actor = self.actor_receipt(command_id, action)
        capture: dict[str, Any] | None = None

        if action == "capture_memory":
            allowed = {"action", "requestId", "problem", "desiredAction", "reason"}
            if any(key not in allowed for key in payload):
                raise BrainControlError("BRAIN_UI_REQUEST_INVALID", "capture_memory received unsupported fields")
            problem = _optional_string(payload.get("problem"), "problem", 1200)
            desired_action = _optional_string(payload.get("desiredAction"), "desiredAction", 1200)
            if not problem or not desired_action:
                raise BrainControlError("BRAIN_UI_REQUEST_INVALID", "capture_memory requires problem and desiredAction")
            suggested_kind = _capture_suggested_kind(problem, desired_action)
            card_id = "card-capture-" + hashlib.sha256(request_id.encode("utf-8")).hexdigest()
            command: dict[str, Any] = {
                "commandType": "create_card",
                "commandId": command_id,
                "aggregateId": card_id,
                "expectedRevision": 0,
                "kind": "note",
                "scope": {"kind": "global", "key": "user"},
                "lifecycle": "active",
                "authority": "user_confirmed",
                "privacyClass": "private",
                "title": _capture_title(problem),
                "payload": {
                    "schema": "super-brain.card.note.v1",
                    "body": f"问题是什么：{problem}\n\n想怎么做：{desired_action}",
                    "tags": ["快速记录", "待学习", "建议：" + suggested_kind],
                    "links": [],
                    "pinned": False,
                },
                "evidenceRefs": [],
                "actorReceipt": actor,
                "reason": _optional_string(payload.get("reason", "Control Center simple memory capture"), "reason", 480),
                "source": "loopback_control_center_capture",
            }
            source_context = self.control.current_card_source_context_for_ui()
            if source_context is not None:
                command["sourceContext"] = source_context
            receipt = self.control.apply(command)
            capture = {
                "storedKind": "note",
                "suggestedKind": suggested_kind,
                "enrichmentState": "pending_evidence",
                "automaticConstraint": False,
            }
        elif action in {"create", "edit"}:
            card = _require_mapping(payload.get("card"), "card")
            command = {
                "commandType": "create_card" if action == "create" else "edit_card",
                "commandId": command_id,
                "aggregateId": _optional_string(payload.get("cardId") or card.get("cardId"), "cardId", 160),
                "expectedRevision": _require_integer(payload.get("expectedRevision", 0 if action == "create" else -1), "expectedRevision", minimum=0),
                "kind": _optional_string(card.get("kind"), "card.kind", 64),
                "scope": _require_mapping(card.get("scope"), "card.scope"),
                "lifecycle": _optional_string(card.get("lifecycle", "active"), "card.lifecycle", 32),
                "authority": _optional_string(card.get("authority", "user_confirmed"), "card.authority", 32),
                "privacyClass": _optional_string(card.get("privacyClass", "private"), "card.privacyClass", 32),
                "title": _optional_string(card.get("title"), "card.title", 240),
                "payload": _require_mapping(card.get("payload"), "card.payload"),
                "evidenceRefs": card.get("evidenceRefs", []),
                "actorReceipt": actor,
                "reason": _optional_string(payload.get("reason", "Control Center edit"), "reason", 480),
                "source": "loopback_control_center",
            }
            if action == "edit" and command["expectedRevision"] < 1:
                raise BrainControlError("BRAIN_UI_REQUEST_INVALID", "expectedRevision is required for edit")
            if command["authority"] != "user_confirmed":
                raise BrainControlError(
                    "BRAIN_UI_SYSTEM_CARD_READ_ONLY",
                    "the Control Center cannot create or edit system-owned cards directly",
                )
            if action == "create":
                source_context = self.control.current_card_source_context_for_ui()
                if source_context is not None:
                    command["sourceContext"] = source_context
            receipt = self.control.apply(command)
        elif action == "replace":
            card = _require_mapping(payload.get("card"), "card")
            replacement_id = _optional_string(payload.get("cardId") or card.get("cardId"), "cardId", 160)
            previous_id = _optional_string(payload.get("replacedCardId"), "replacedCardId", 160)
            previous_revision = _require_integer(payload.get("replacedExpectedRevision"), "replacedExpectedRevision", minimum=1)
            impact_acknowledged = _require_boolean(payload.get("impactAcknowledged", False), "impactAcknowledged")
            create_command_id = command_id + "-create"
            supersede_command_id = command_id + "-supersede"
            create_command: dict[str, Any] = {
                "commandType": "create_card",
                "commandId": create_command_id,
                "aggregateId": replacement_id,
                "expectedRevision": 0,
                "kind": _optional_string(card.get("kind"), "card.kind", 64),
                "scope": _require_mapping(card.get("scope"), "card.scope"),
                "lifecycle": _optional_string(card.get("lifecycle", "active"), "card.lifecycle", 32),
                "authority": _optional_string(card.get("authority", "user_confirmed"), "card.authority", 32),
                "privacyClass": _optional_string(card.get("privacyClass", "private"), "card.privacyClass", 32),
                "title": _optional_string(card.get("title"), "card.title", 240),
                "payload": _require_mapping(card.get("payload"), "card.payload"),
                "evidenceRefs": card.get("evidenceRefs", []),
                "actorReceipt": self.actor_receipt(create_command_id, "replace_create"),
                "reason": _optional_string(payload.get("reason", "Control Center replace decision"), "reason", 480),
                "source": "loopback_control_center",
            }
            if create_command["kind"] != "decision":
                raise BrainControlError("BRAIN_UI_REPLACE_KIND_INVALID", "only decisions can be replaced through the Control Center")
            source_context = self.control.current_card_source_context_for_ui()
            if source_context is not None:
                create_command["sourceContext"] = source_context
            supersede_command = {
                "commandType": "supersede_card",
                "commandId": supersede_command_id,
                "aggregateId": previous_id,
                "expectedRevision": previous_revision,
                "actorReceipt": self.actor_receipt(supersede_command_id, "replace_supersede"),
                "replacementRef": replacement_id,
                "impactAcknowledged": impact_acknowledged,
                "reason": _optional_string(payload.get("reason", "Control Center replace decision"), "reason", 480),
                "source": "loopback_control_center",
            }
            created, superseded = self.control.apply_many_atomically([create_command, supersede_command])
            receipt = {
                "ok": True,
                "schema": "super-brain.ui-replace-receipt.v1",
                "cardId": replacement_id,
                "revision": created["revision"],
                "replacedCardId": previous_id,
                "replacedRevision": superseded["revision"],
                "created": created,
                "superseded": superseded,
            }
        elif action in {"trash", "restore", "cancel", "forget", "delete_from_trash", "rollback", "supersede"}:
            expected_revision = _require_integer(payload.get("expectedRevision"), "expectedRevision", minimum=1)
            command: dict[str, Any] = {
                "commandId": command_id,
                "aggregateId": _optional_string(payload.get("cardId"), "cardId", 160),
                "expectedRevision": expected_revision,
                "actorReceipt": actor,
                "reason": _optional_string(payload.get("reason", "Control Center lifecycle action"), "reason", 480),
                "source": "loopback_control_center",
            }
            if action == "trash":
                command["commandType"] = "trash_card"
            elif action == "restore":
                command["commandType"] = "restore_card"
            elif action == "cancel":
                command["commandType"] = "cancel_card"
                command["impactAcknowledged"] = _require_boolean(payload.get("impactAcknowledged", False), "impactAcknowledged")
            elif action == "forget":
                command["commandType"] = "forget_active"
                command["forgetAcknowledged"] = _require_boolean(payload.get("forgetAcknowledged", False), "forgetAcknowledged")
            elif action == "delete_from_trash":
                command["commandType"] = "forget_trashed"
                command["forgetAcknowledged"] = _require_boolean(payload.get("deleteAcknowledged", False), "deleteAcknowledged")
            elif action == "rollback":
                command["commandType"] = "rollback_card"
                command["restoreRevision"] = _require_integer(payload.get("restoreRevision"), "restoreRevision", minimum=1)
            else:
                command["commandType"] = "supersede_card"
                command["replacementRef"] = _optional_string(payload.get("replacementRef"), "replacementRef", 240)
                command["impactAcknowledged"] = _require_boolean(payload.get("impactAcknowledged", False), "impactAcknowledged")
            receipt = self.control.apply(command)
        elif action == "delete_trashed_batch":
            selections = payload.get("cards")
            if not isinstance(selections, list):
                raise BrainControlError("BRAIN_UI_REQUEST_INVALID", "cards must be an array")
            if not _require_boolean(payload.get("deleteAcknowledged", False), "deleteAcknowledged"):
                raise BrainControlError(
                    "BRAIN_UI_TRASH_DELETE_ACKNOWLEDGEMENT_REQUIRED",
                    "permanent Trash deletion requires an explicit acknowledgement",
                )
            receipt = self.control.forget_trashed_cards_for_ui(
                selections,
                actor,
                command_id_prefix=command_id + "-trash-delete",
                reason=_optional_string(payload.get("reason", "Control Center permanent Trash delete"), "reason", 480),
                source="loopback_control_center",
            )
        elif action == "purge_preview":
            receipt = self.control.preview_purge_everywhere(
                _optional_string(payload.get("cardId"), "cardId", 160),
                _require_integer(payload.get("expectedRevision"), "expectedRevision", minimum=1),
                actor,
            )
        elif action == "purge_request":
            receipt = self.control.request_purge_everywhere(
                _optional_string(payload.get("previewId"), "previewId", 160),
                _optional_string(payload.get("confirmationPhrase"), "confirmationPhrase", 240),
                actor,
            )
        elif action == "update_task_retention":
            receipt = self.control.update_task_retention_settings(
                completed_days=_require_integer(payload.get("completedDays"), "completedDays", minimum=1, maximum=3650),
                trash_days=_require_integer(payload.get("trashDays"), "trashDays", minimum=1, maximum=3650),
                expected_revision=_require_integer(payload.get("expectedRevision"), "expectedRevision", minimum=1),
                actor_receipt=actor,
            )
        elif action == "restore_task_card":
            receipt = self.control.restore_task_card_for_ui(
                _optional_string(payload.get("taskCardKey"), "taskCardKey", 160),
                actor,
            )
        elif action == "adopt_reflection":
            adopted_card_id = _optional_string(payload.get("adoptedCardId"), "adoptedCardId", 160)
            experience_card_id = _optional_string(payload.get("experienceCardId"), "experienceCardId", 160)
            if adopted_card_id and experience_card_id and adopted_card_id != experience_card_id:
                raise BrainControlError("BRAIN_UI_REFLECTION_TARGET_ID_AMBIGUOUS", "provide one adopted card id")
            receipt = self.adopt_reflection_for_ui(
                reflection_card_id=_optional_string(payload.get("reflectionCardId"), "reflectionCardId", 160),
                expected_revision=_require_integer(payload.get("expectedRevision"), "expectedRevision", minimum=1),
                adopted_card_id=adopted_card_id,
                experience_card_id=experience_card_id,
                requested_kind=_optional_string(payload.get("targetKind"), "targetKind", 32),
                reason=_optional_string(payload.get("reason", "Control Center adopt reflection"), "reason", 480),
            )
        else:
            raise BrainControlError("BRAIN_UI_COMMAND_UNSUPPORTED", "command action is unsupported")

        delivery: dict[str, Any] = {"status": "not_required"}
        if action not in {"purge_preview", "purge_request", "update_task_retention", "restore_task_card"}:
            try:
                materialized = self.control.materialize_outbox()
                delivery = {"status": "materialized", "eventCount": materialized.get("materializedEventCount", 0)}
            except BrainControlError as exc:
                delivery = {"status": "pending", "code": exc.code}
        response = {"ok": True, "schema": API_SCHEMA, "receipt": receipt, "delivery": delivery}
        if capture is not None:
            response["capture"] = capture
        return response

    def dispatch_draft(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        operation = _optional_string(payload.get("operation"), "operation", 24)
        if operation == "save":
            receipt = self.control.save_ui_draft(
                _optional_string(payload.get("cardId"), "cardId", 160),
                _require_integer(payload.get("baseRevision"), "baseRevision", minimum=0),
                _require_mapping(payload.get("draft"), "draft"),
            )
            return {"ok": True, "schema": API_SCHEMA, "receipt": receipt}
        if operation == "get":
            return self.control.get_ui_draft(
                _optional_string(payload.get("cardId"), "cardId", 160),
                _require_integer(payload.get("currentRevision"), "currentRevision", minimum=0),
            )
        if operation == "discard":
            return self.control.discard_ui_draft(_optional_string(payload.get("cardId"), "cardId", 160))
        raise BrainControlError("BRAIN_UI_DRAFT_UNSUPPORTED", "draft operation is unsupported")


class UiRequestHandler(BaseHTTPRequestHandler):
    server: "UiHttpServer"
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:
        return

    @property
    def service(self) -> UiService:
        return self.server.service

    def _set_common_headers(self, *, content_type: str = "application/json; charset=utf-8") -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'; "
            "connect-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self'",
        )

    def _set_capability_cookie(self) -> None:
        capability = self.service.issue_capability()
        self.send_header(
            "Set-Cookie",
            f"{COOKIE_NAME}={capability}; Path=/; HttpOnly; SameSite=Strict; Max-Age={self.service.idle_seconds}",
        )

    def _send_json(self, status: HTTPStatus, body: Mapping[str, Any], *, refresh_capability: bool = False) -> None:
        raw = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self._set_common_headers()
        if refresh_capability:
            self._set_capability_cookie()
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _error(self, status: HTTPStatus, code: str) -> None:
        self._send_json(status, {"ok": False, "schema": API_SCHEMA, "code": code})

    def _host_valid(self) -> bool:
        return self.headers.get("Host", "") == f"127.0.0.1:{self.server.server_port}"

    def _origin_valid(self) -> bool:
        return self.headers.get("Origin", "") == self.service.origin

    def _authorized(self) -> bool:
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
        except (KeyError, ValueError):
            return False
        morsel = cookie.get(COOKIE_NAME)
        return morsel is not None and self.service.capability_is_valid(morsel.value)

    def _read_json_body(self) -> dict[str, Any] | None:
        content_type = self.headers.get("Content-Type", "")
        if content_type.split(";", 1)[0].lower() != "application/json":
            self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "BRAIN_UI_CONTENT_TYPE_REQUIRED")
            return None
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._error(HTTPStatus.LENGTH_REQUIRED, "BRAIN_UI_CONTENT_LENGTH_INVALID")
            return None
        if length < 1 or length > MAX_BODY_BYTES:
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "BRAIN_UI_BODY_TOO_LARGE")
            return None
        try:
            value = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._error(HTTPStatus.BAD_REQUEST, "BRAIN_UI_BODY_INVALID")
            return None
        if not isinstance(value, dict):
            self._error(HTTPStatus.BAD_REQUEST, "BRAIN_UI_BODY_INVALID")
            return None
        return value

    def _discard_request_body(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return
        if 0 < length <= MAX_BODY_BYTES:
            try:
                self.rfile.read(length)
            except OSError:
                pass

    def _serve_asset(self, request_path: str) -> None:
        parsed = urlparse(request_path)
        if parsed.query or parsed.fragment:
            self._error(HTTPStatus.BAD_REQUEST, "BRAIN_UI_STATIC_QUERY_REJECTED")
            return
        relative = "index.html" if parsed.path in {"", "/"} else parsed.path.lstrip("/")
        candidate = (self.service.assets_root / relative).resolve()
        try:
            candidate.relative_to(self.service.assets_root)
        except ValueError:
            self._error(HTTPStatus.NOT_FOUND, "BRAIN_UI_ASSET_NOT_FOUND")
            return
        if not candidate.is_file() or candidate.suffix.lower() == ".map":
            self._error(HTTPStatus.NOT_FOUND, "BRAIN_UI_ASSET_NOT_FOUND")
            return
        try:
            body = candidate.read_bytes()
        except OSError:
            self._error(HTTPStatus.NOT_FOUND, "BRAIN_UI_ASSET_NOT_FOUND")
            return
        content_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        if candidate.suffix.lower() == ".js":
            content_type = "text/javascript; charset=utf-8"
        elif candidate.suffix.lower() == ".css":
            content_type = "text/css; charset=utf-8"
        elif candidate.suffix.lower() == ".html":
            content_type = "text/html; charset=utf-8"
        self.send_response(HTTPStatus.OK)
        self._set_common_headers(content_type=content_type)
        if parsed.path in {"", "/"}:
            self._set_capability_cookie()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.service.touch()

    def do_OPTIONS(self) -> None:
        self._error(HTTPStatus.METHOD_NOT_ALLOWED, "BRAIN_UI_CORS_DISABLED")

    def do_GET(self) -> None:
        if not self._host_valid():
            self._error(HTTPStatus.FORBIDDEN, "BRAIN_UI_HOST_REJECTED")
            return
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            if parsed.query:
                self._error(HTTPStatus.BAD_REQUEST, "BRAIN_UI_STATIC_QUERY_REJECTED")
                return
            self._send_json(HTTPStatus.OK, {"ok": True, "schema": API_SCHEMA, "service": "healthy"})
            return
        if parsed.path.startswith("/api/"):
            self._error(HTTPStatus.METHOD_NOT_ALLOWED, "BRAIN_UI_POST_REQUIRED")
            return
        self._serve_asset(self.path)

    def do_POST(self) -> None:
        if not self._host_valid():
            self._discard_request_body()
            self._error(HTTPStatus.FORBIDDEN, "BRAIN_UI_HOST_REJECTED")
            return
        parsed = urlparse(self.path)
        if parsed.query or parsed.fragment:
            self._discard_request_body()
            self._error(HTTPStatus.BAD_REQUEST, "BRAIN_UI_API_QUERY_REJECTED")
            return
        if not self._origin_valid():
            self._discard_request_body()
            self._error(HTTPStatus.FORBIDDEN, "BRAIN_UI_ORIGIN_REJECTED")
            return
        if not self._authorized():
            self._discard_request_body()
            self._error(HTTPStatus.UNAUTHORIZED, "BRAIN_UI_CAPABILITY_REQUIRED")
            return
        payload = self._read_json_body()
        if payload is None:
            return
        try:
            if parsed.path == "/api/read":
                result = self.service.dispatch_read(payload)
            elif parsed.path == "/api/command":
                result = self.service.dispatch_command(payload)
            elif parsed.path == "/api/draft":
                result = self.service.dispatch_draft(payload)
            else:
                self._error(HTTPStatus.NOT_FOUND, "BRAIN_UI_API_NOT_FOUND")
                return
        except BrainControlError as exc:
            status = HTTPStatus.CONFLICT if exc.code in {
                "BRAIN_CONTROL_STALE_REVISION",
                "BRAIN_CONTROL_PURGE_STATE_STALE",
                "BRAIN_CONTROL_PURGE_PREVIEW_EXPIRED",
            } else HTTPStatus.BAD_REQUEST
            self._error(status, exc.code)
            return
        except Exception:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "BRAIN_UI_INTERNAL_ERROR")
            return
        self.service.touch()
        self._send_json(HTTPStatus.OK, result, refresh_capability=True)


class UiHttpServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, address: tuple[str, int], service: UiService) -> None:
        self.service = service
        super().__init__(address, UiRequestHandler)


def _lease_path(state_root: Path, workspace_key: str) -> Path:
    root = state_root.expanduser().resolve() / "workspace"
    if workspace_key:
        token = hashlib.sha256(workspace_key.encode("utf-8")).hexdigest()[:16]
        return root / "ui-service-leases" / f"{token}.json"
    return root / "ui-service-lease.json"


def _probe_existing_lease(state_root: Path, workspace_key: str = "") -> str:
    lease_path = _lease_path(state_root, workspace_key)
    try:
        value = json.loads(lease_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return ""
    if not isinstance(value, Mapping) or value.get("schema") != LEASE_SCHEMA or not isinstance(value.get("url"), str):
        return ""
    url = str(value["url"])
    try:
        import urllib.request

        request = urllib.request.Request(url.rstrip("/") + "/api/health", method="GET", headers={"Host": urlparse(url).netloc})
        with urllib.request.urlopen(request, timeout=0.8) as response:
            body = json.loads(response.read().decode("utf-8"))
        return url if isinstance(body, Mapping) and body.get("service") == "healthy" else ""
    except Exception:
        return ""


def run_server(state_root: Path, assets_root: Path, port: int, idle_seconds: int, open_browser: bool, workspace_key: str = "") -> int:
    if not assets_root.is_dir() or not (assets_root / "index.html").is_file():
        raise BrainControlError("BRAIN_UI_ASSETS_MISSING", "prebuilt Control Center assets are unavailable")
    existing_url = _probe_existing_lease(state_root, workspace_key)
    if existing_url:
        if open_browser:
            webbrowser.open(existing_url, new=1)
        print(json.dumps({"ok": True, "schema": API_SCHEMA, "existing": True, "url": existing_url}, separators=(",", ":")))
        return 0
    service = UiService(
        state_root=state_root,
        assets_root=assets_root,
        idle_seconds=idle_seconds,
        instance_id="ui-" + uuid.uuid4().hex,
        capability_token=secrets.token_urlsafe(32),
        workspace_key=workspace_key,
    )
    server = UiHttpServer(("127.0.0.1", port), service)
    service.port = server.server_port
    service.write_lease()
    url = service.origin + "/"
    print(json.dumps({"ok": True, "schema": API_SCHEMA, "existing": False, "url": url}, separators=(",", ":")), flush=True)
    if open_browser:
        webbrowser.open(url, new=1)
    server.timeout = 1.0
    try:
        while not service.is_idle():
            server.handle_request()
    finally:
        server.server_close()
        service.remove_lease()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Super Brain loopback Control Center")
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--assets-root", default=str(Path(__file__).resolve().parents[1] / "ui" / "dist"))
    parser.add_argument("--port", type=int, default=0, choices=range(0, 65536))
    parser.add_argument("--idle-seconds", type=int, default=900, choices=range(60, 86_401))
    parser.add_argument("--workspace-key", default="")
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    try:
        return run_server(Path(args.state_root), Path(args.assets_root), args.port, args.idle_seconds, args.open, args.workspace_key)
    except BrainControlError as exc:
        print(json.dumps({"ok": False, "schema": API_SCHEMA, "code": exc.code}, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
