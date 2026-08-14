from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sqlite3
import sys
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Sequence

from brain_context import (
    INTENT_CONTEXT_PROJECTION_SCHEMA,
    INTENT_CONTEXT_PENDING_SCHEMA,
    intent_context_aggregate_ref,
    intent_context_pending_marker_path,
    intent_context_pending_root,
    intent_context_projection_path,
    read_intent_context_projection,
)
from migration_control import LegacyMigrationControl, MigrationControlError
from memory_consolidation import plan as plan_memory_consolidation


SCHEMA_VERSION = 16
CARD_KINDS = frozenset({"decision", "preference", "experience", "note", "procedure", "reflection"})
LIFECYCLES = frozenset({"proposed", "active", "superseded", "cancelled", "rejected", "archived", "trashed", "forgotten"})
AUTHORITIES = frozenset({"user_confirmed", "system", "legacy", "unknown"})
PRIVACY_CLASSES = frozenset({"private", "shared", "public"})
CARD_COMMAND_TYPES = frozenset(
    {
        "create_card",
        "edit_card",
        "supersede_card",
        "rollback_card",
        "trash_card",
        "restore_card",
        "cancel_card",
        "forget_active",
        "forget_trashed",
        "upsert_card",
    }
)
CARD_REVISION_STATE_SCHEMA = "super-brain.card-revision-state.v1"
ACTOR_RECEIPT_SCHEMA = "super-brain.actor-receipt.v1"
MCP_SNAPSHOT_SCHEMA = "super-brain.mcp-snapshot.v1"
MCP_SNAPSHOT_MAX_BYTES = 256 * 1024
MCP_TASK_REFERENCE_MAX_ITEMS = 64
MCP_TASK_PROJECTION_MAX_ITEMS = 16
MCP_CURRENT_TASK_LIFECYCLES = frozenset({"planned", "active", "paused", "blocked"})
CARD_PROJECTION_SCHEMA = "super-brain.card-projection.v1"
TIMELINE_SOURCE_CONTEXT_SCHEMA = "super-brain.card-source-context.v1"
OUTBOX_DELIVERY_SCHEMA = "super-brain.outbox-delivery-receipt.v1"
OUTBOX_DELIVERY_TARGETS = {
    "card_projection": ("compatibility_projection", "mcp_snapshot"),
    "task_projection": ("compatibility_projection", "mcp_snapshot"),
    "task_state_snapshot": ("mcp_snapshot",),
}
DECISION_RESOLUTION_SCHEMA = "super-brain.decision-resolution-receipt.v1"
DECISION_COMPLETION_RESULT_SCHEMA = "super-brain.decision-completion-result.v1"
NATIVE_DECISION_INDEX_MANIFEST_SCHEMA = "super-brain.native-decision-index-manifest.v1"
NATIVE_DECISION_INDEX_SHARD_SCHEMA = "super-brain.native-decision-index-shard.v1"
NATIVE_DECISION_CONTEXT_SCHEMA = "super-brain.native-decision-context.v1"
MEMORY_INFLUENCE_SCHEMA = "super-brain.execution-memory-influence.v1"
NATIVE_MEMORY_INFLUENCE_SNAPSHOT_SCHEMA = "super-brain.native-memory-influence-snapshot.v1"
NATIVE_MEMORY_INFLUENCE_SNAPSHOT_DIRTY_SCHEMA = "super-brain.native-memory-influence-snapshot-dirty.v1"
NATIVE_PROMPT_HOOK_TELEMETRY_SCHEMA = "super-brain.codex-user-prompt-hook.v1"
NATIVE_MEMORY_LEARNING_CANDIDATE_SCHEMA = "super-brain.native-memory-learning-candidate.v1"
H7_MEMORY_LEARNING_CANDIDATE_SCHEMA = "super-brain.h7-memory-learning-candidate.v1"
H7_TURN_RUNTIME_RECEIPT_SCHEMA = "super-brain.turn-runtime-receipt.v1"
H7_TURN_RUNTIME_TELEMETRY_SCHEMA = "super-brain.turn-runtime-telemetry.v1"
TYPED_MEMORY_TRIAL_RECEIPT_SCHEMA = "super-brain.typed-memory-trial-receipt.v1"
TYPED_MEMORY_TRIAL_SNAPSHOT_SCHEMA = "super-brain.typed-memory-trial-snapshot.v1"
TYPED_MEMORY_TRIAL_VERDICTS = frozenset({"absent", "inconclusive", "passed", "failed"})
TYPED_MEMORY_TRIAL_STATES = frozenset({"not_started", "observed", "closed"})
TYPED_MEMORY_TRIAL_PROMOTABLE_KINDS = frozenset({"preference", "experience", "procedure", "decision"})
NATIVE_DECISION_INDEX_MAX_BYTES = 4 * 1024 * 1024
NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_BYTES = 128 * 1024
NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_CARDS = 96
NATIVE_MEMORY_LEARNING_CANDIDATE_MAX_AGE_MINUTES = 180
MEMORY_CONSOLIDATION_CARD_SCAN_LIMIT = 192
MEMORY_INFLUENCE_CARD_SCAN_LIMIT = 160
MEMORY_INFLUENCE_DEFAULT_MAX_PER_KIND = 4
MEMORY_INFLUENCE_MAX_PER_KIND = 8
SENSITIVE_KEY_PARTS = ("password", "passwd", "secret", "api_key", "apikey", "credential", "cookie", "raw_prompt", "transcript")
SENSITIVE_VALUE_RE = re.compile(r"(?i)\b(?:bearer\s+[a-z0-9._~+/-]+=*|sk-[a-z0-9_-]{8,})\b")
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
DECISION_GRAPH_SCOPE = "decision_graph"
DECISION_GRAPH_CARD_PREFIX = "decision-graph:"
DECISION_GRAPH_SCHEMA = "super-brain.decision-graph-projection.v1"
DECISION_GRAPH_CURRENT_ADR_STATUSES = frozenset({"proposed", "accepted"})
DECISION_GRAPH_VALID_ADR_STATUSES = frozenset({"proposed", "accepted", "deprecated", "superseded", "rejected"})
DECISION_GRAPH_ADR_RELATIONS = frozenset({"decides", "has_title", "has_status", "has_context", "has_consequence"})
DECISION_STAGE_KINDS = frozenset({"build", "package", "release", "deploy", "test"})
DECISION_ENFORCEMENTS = frozenset({"advisory", "completion_gate"})
INTENT_CONTRACT_SCHEMA = "super-brain.intent-contract.v2"
INTENT_CONTRACT_SCHEMAS = frozenset({"super-brain.intent-contract.v1", INTENT_CONTRACT_SCHEMA})
INTENT_RECEIPT_SCHEMA = "super-brain.intent-resolution-receipt.v2"
INTENT_AUTONOMY_TIERS = frozenset({"direct", "align", "discuss"})
INTENT_CONTRACT_FIELDS = frozenset(
    {
        "literalRequestDigest",
        "resolvedOutcome",
        "productRole",
        "integrationObligations",
        "materialUnknowns",
        "compatibilityGuards",
        "preservedCapabilities",
        "acceptanceCriteria",
        "governedEquivalent",
        "autonomyTier",
    }
)
INTENT_INTEGRATION_FIELDS = (
    "entryPoint",
    "userFlow",
    "domainOwner",
    "stateOwner",
    "failureRecovery",
    "privacyPerformance",
    "compatibilityMigration",
    "verification",
    "completionCondition",
)
TASK_AGGREGATE_SCHEMA = "super-brain.task-aggregate.v1"
TASK_PROJECTION_SCHEMA = "super-brain.task-projection.v1"
TASK_LIFECYCLES = frozenset({"planned", "active", "paused", "blocked", "completed", "cancelled", "archived", "quarantined"})
TASK_UI_STATUS_LABELS = {
    "planned": "待开始",
    "active": "进行中",
    "paused": "已暂停",
    "blocked": "被阻塞",
    "completed": "已完成",
    "cancelled": "已取消",
    "archived": "已归档",
    "quarantined": "待核对",
    "pending": "待完成",
    "in_progress": "进行中",
}
TASK_UI_PLAN_LABELS = {
    "B0": "B0：锁定 0.6 基线、主计划与回滚证据",
    "B1": "B1：修复启动、共享、缓存与旧界面问题",
    "P-1": "P-1：把需求理解与产品连贯性检查接入执行",
    "P0": "P0：建立唯一任务状态、原子完成与连续性",
    "P1": "P1：建立本地控制平面与统一状态契约",
    "P2": "P2：让已确认决策在执行时自动生效",
    "P3": "P3：实现受控学习、反思与用户适配",
    "P4": "P4：构建可编辑的本地记忆与控制中心",
    "P5": "P5：迁移旧状态并停止旧写入路径",
    "P6": "P6：通过功能、隐私、性能与安装验证",
    "P7": "P7：执行全新密封客观评测",
    "P8": "P8：完成发布准备、反审计与正式收口",
}
TASK_UI_STEP_LABELS = {
    "P4.3": "P4.3：完善控制中心的中文界面、任务可读性与真实用户路径验证",
    "P4.4": "P4.4：补全总记忆记录、任务历史与可恢复整理规则",
}
CARD_UI_KIND_LABELS = {
    "note": "笔记",
    "preference": "偏好",
    "experience": "经验",
    "decision": "决策",
    "procedure": "流程",
    "reflection": "反思",
}
CARD_UI_LIFECYCLE_LABELS = {
    "proposed": "草稿",
    "active": "当前",
    "superseded": "已替换",
    "cancelled": "已取消",
    "rejected": "未采用",
    "archived": "已归档",
    "trashed": "回收站",
    "forgotten": "已忘记",
}
TASK_CARD_UI_STATUS_LABELS = {
    "active": "进行中",
    "planned": "待开始",
    "paused": "已暂停",
    "blocked": "被阻塞",
    "completed": "已完成",
    "cancelled": "已取消",
    "archived": "已归档",
    "quarantined": "待核对",
}
TASK_CARD_RETENTION_LABELS = {
    "visible": "任务记录",
    "trashed": "回收站",
    "cleanup_preview": "待整理",
}
TASK_RETENTION_SETTINGS_SCHEMA = "super-brain.task-retention-settings.v1"
TASK_RETENTION_RECEIPT_SCHEMA = "super-brain.task-retention-receipt.v1"
TASK_RETENTION_PREVIEW_SCHEMA = "super-brain.task-retention-preview.v1"
TASK_TIMELINE_SCHEMA = "super-brain.ui-memory-timeline.v1"
TASK_HISTORY_SCHEMA = "super-brain.ui-task-history.v1"
MEMORY_STARMAP_SCHEMA = "super-brain.ui-memory-starmap.v1"
MEMORY_STARMAP_MAX_MEMORY_NODES = 160
MEMORY_STARMAP_MAX_TASK_NODES = 24
MEMORY_STARMAP_MAX_EDGES = 480
TASK_RETENTION_DEFAULT_COMPLETED_DAYS = 15
TASK_RETENTION_DEFAULT_TRASH_DAYS = 30
TASK_RETENTION_MAX_DAYS = 3650
INSTRUCTION_ANCHOR_SCHEMA = "super-brain.instruction-anchor.v1"
INSTRUCTION_ANCHOR_MAX_CHARS = 480
INSTRUCTION_ANCHOR_MAX_SOURCE_CHARS = 160
CONTINUATION_RECEIPT_SCHEMA = "super-brain.continuation-receipt.v1"
CONTINUATION_RECEIPT_MAX_TEXT = 480
NATIVE_MEMORY_LEARNING_SUGGESTED_KINDS = frozenset({"preference", "experience", "decision", "procedure", "reflection", "note"})
NATIVE_MEMORY_LEARNING_KIND_LABELS = {
    "preference": "偏好",
    "experience": "经验",
    "decision": "决策",
    "procedure": "流程",
    "reflection": "自我学习",
    "note": "笔记",
}


class BrainControlError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _parse_utc_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(UTC)


def _utc_timestamp(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _sha256(value: Any) -> str:
    return hashlib.sha256(_canonical_json(value).encode("utf-8")).hexdigest()


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _raw_sha256(value: Any) -> str:
    """Hash a bounded identity string shared with the PowerShell trial writer."""

    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()


def _require_string(value: Any, field: str, maximum: int = 512) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BrainControlError("BRAIN_CONTROL_FIELD_REQUIRED", f"{field} is required")
    normalized = value.strip()
    if len(normalized) > maximum:
        raise BrainControlError("BRAIN_CONTROL_FIELD_TOO_LONG", f"{field} exceeds {maximum} characters")
    return normalized


def _optional_string(value: Any, field: str, maximum: int = 512) -> str:
    if value in (None, ""):
        return ""
    return _require_string(value, field, maximum)


def _redact_instruction_anchor(value: Any) -> str:
    """Store only a bounded, credential-safe instruction summary in the anchor log."""

    text = _require_string(value, "instruction", INSTRUCTION_ANCHOR_MAX_CHARS)
    text = SENSITIVE_VALUE_RE.sub("[REDACTED]", text)
    text = re.sub(
        r"(?i)\b(api[_ -]?key|password|passwd|token|secret|credential|cookie)\s*[:=]\s*[^\s,;]+",
        r"\1=[REDACTED]",
        text,
    )
    return text


def _require_sha256(value: Any, field: str) -> str:
    normalized = _require_string(value, field, 64).lower()
    if not SHA256_RE.fullmatch(normalized):
        raise BrainControlError("BRAIN_CONTROL_DIGEST_INVALID", f"{field} must be a SHA-256 digest")
    return normalized


def _ensure_safe(value: Any, path: str = "payload") -> None:
    if isinstance(value, Mapping):
        for raw_key, nested in value.items():
            key = str(raw_key).lower()
            if any(part in key for part in SENSITIVE_KEY_PARTS):
                if isinstance(nested, bool) and not nested and key.endswith("stored"):
                    continue
                raise BrainControlError("BRAIN_CONTROL_SENSITIVE_FIELD", f"{path}.{raw_key} is not admissible")
            _ensure_safe(nested, f"{path}.{raw_key}")
        return
    if isinstance(value, (list, tuple)):
        for index, nested in enumerate(value):
            _ensure_safe(nested, f"{path}[{index}]")
        return
    if isinstance(value, str) and SENSITIVE_VALUE_RE.search(value):
        raise BrainControlError("BRAIN_CONTROL_SENSITIVE_VALUE", f"{path} contains a credential-like value")


def _normalize_task_list(value: Any, field: str, *, maximum: int = 256) -> list[Any]:
    """Accept the few JSON shapes emitted by Windows PowerShell 5 arrays.

    PowerShell can serialize an empty array as `{}` and a one-item array as a
    scalar when an object crosses a JSON boundary.  These shapes are accepted
    only at task-state list fields and are normalized before hashing; arbitrary
    non-empty objects remain one list item instead of being silently flattened.
    """
    if value is None:
        items: list[Any] = []
    elif isinstance(value, list):
        items = list(value)
    elif isinstance(value, tuple):
        items = list(value)
    elif isinstance(value, Mapping):
        items = [] if not value else [dict(value)]
    else:
        items = [value]
    if len(items) > maximum:
        raise BrainControlError("BRAIN_CONTROL_TASK_LIST_TOO_LARGE", f"{field} exceeds {maximum} items")
    _ensure_safe(items, field)
    return items


def _bounded_text(value: Any, field: str, maximum: int, *, required: bool = True) -> str:
    if value is None or not str(value).strip():
        if required:
            raise BrainControlError("BRAIN_CONTROL_INTENT_INCOMPLETE", f"{field} is required")
        return ""
    normalized = re.sub(r"\s+", " ", str(value)).strip()
    if len(normalized) > maximum:
        raise BrainControlError("BRAIN_CONTROL_FIELD_TOO_LONG", f"{field} exceeds {maximum} characters")
    return normalized


def _bounded_list(value: Any, field: str, maximum_items: int, maximum_chars: int, *, required: bool = True) -> list[str]:
    if not isinstance(value, list):
        if required:
            raise BrainControlError("BRAIN_CONTROL_INTENT_INCOMPLETE", f"{field} must be a list")
        return []
    result: list[str] = []
    for item in value:
        text = _bounded_text(item, field, maximum_chars)
        if text not in result:
            result.append(text)
    if required and not result:
        raise BrainControlError("BRAIN_CONTROL_INTENT_INCOMPLETE", f"{field} requires at least one item")
    if len(result) > maximum_items:
        raise BrainControlError("BRAIN_CONTROL_INTENT_TOO_LARGE", f"{field} exceeds {maximum_items} items")
    return result


@dataclass(frozen=True)
class CardContract:
    """The versioned payload and transition policy for one durable card kind."""

    kind: str
    schema: str
    normalizer: Callable[[Mapping[str, Any]], dict[str, Any]]
    allowed_commands: frozenset[str]
    allowed_lifecycles: frozenset[str]
    projection_fields: tuple[str, ...]


def _card_text(value: Any, field: str, maximum: int, *, required: bool = True) -> str:
    if value is None or value == "":
        if required:
            raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_REQUIRED", f"{field} is required")
        return ""
    if not isinstance(value, str):
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", f"{field} must be a string")
    return _bounded_text(value, field, maximum, required=required)


def _card_list(
    value: Any,
    field: str,
    maximum_items: int,
    maximum_chars: int,
    *,
    required: bool = False,
) -> list[str]:
    if value is None:
        if required:
            raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_REQUIRED", f"{field} is required")
        return []
    if not isinstance(value, list):
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", f"{field} must be a list")
    result: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", f"{field} must contain strings")
        text = _card_text(item, field, maximum_chars)
        if text not in result:
            result.append(text)
    if required and not result:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_REQUIRED", f"{field} requires at least one item")
    if len(result) > maximum_items:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_TOO_LARGE", f"{field} exceeds {maximum_items} items")
    return result


def _card_integer(value: Any, field: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum or value > maximum:
        raise BrainControlError(
            "BRAIN_CONTROL_CARD_FIELD_INVALID",
            f"{field} must be an integer between {minimum} and {maximum}",
        )
    return value


def _card_boolean(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", f"{field} must be boolean")
    return value


def _card_exact_fields(value: Mapping[str, Any], allowed: set[str], required: set[str], field: str) -> None:
    unknown = sorted(str(key) for key in value if key not in allowed)
    if unknown:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_UNSUPPORTED", f"{field} contains unsupported fields: {', '.join(unknown)}")
    missing = sorted(name for name in required if name not in value)
    if missing:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_REQUIRED", f"{field} is missing required fields: {', '.join(missing)}")


def _normalize_decision_graph_payload(value: Mapping[str, Any]) -> dict[str, Any]:
    allowed = {
        "schema", "subjectHash", "sourceEventCount", "sourceFirstLine", "sourceLastLine", "sourceEventChainDigest",
        "sourceProjectionDigest", "adr", "adrStatus", "isCurrent", "executionEligible", "supersedesDigest",
        "supersededByDigest", "rawDecisionBodyStored", "rawPromptStored",
    }
    _card_exact_fields(value, allowed, allowed, "decision graph payload")
    first_line = _card_integer(value["sourceFirstLine"], "sourceFirstLine", 1, 10_000_000)
    last_line = _card_integer(value["sourceLastLine"], "sourceLastLine", first_line, 10_000_000)
    adr_status = _card_text(value["adrStatus"], "adrStatus", 24).lower()
    if adr_status not in DECISION_GRAPH_VALID_ADR_STATUSES:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", f"unsupported adrStatus: {adr_status}")
    normalized = {
        "schema": DECISION_GRAPH_SCHEMA,
        "subjectHash": _require_sha256(value["subjectHash"], "subjectHash"),
        "sourceEventCount": _card_integer(value["sourceEventCount"], "sourceEventCount", 1, 1_000_000),
        "sourceFirstLine": first_line,
        "sourceLastLine": last_line,
        "sourceEventChainDigest": _require_sha256(value["sourceEventChainDigest"], "sourceEventChainDigest"),
        "sourceProjectionDigest": _require_sha256(value["sourceProjectionDigest"], "sourceProjectionDigest"),
        "adr": _card_boolean(value["adr"], "adr"),
        "adrStatus": adr_status,
        "isCurrent": _card_boolean(value["isCurrent"], "isCurrent"),
        "executionEligible": _card_boolean(value["executionEligible"], "executionEligible"),
        "supersedesDigest": _require_sha256(value["supersedesDigest"], "supersedesDigest"),
        "supersededByDigest": _require_sha256(value["supersededByDigest"], "supersededByDigest"),
        "rawDecisionBodyStored": _card_boolean(value["rawDecisionBodyStored"], "rawDecisionBodyStored"),
        "rawPromptStored": _card_boolean(value["rawPromptStored"], "rawPromptStored"),
    }
    if normalized["rawDecisionBodyStored"] or normalized["rawPromptStored"]:
        raise BrainControlError("BRAIN_CONTROL_CARD_PRIVACY_INVALID", "decision graph projections cannot store raw bodies")
    return normalized


def _normalize_decision_applicability(value: Any, enforcement: str) -> dict[str, Any]:
    if value is None:
        return {
            "mode": "legacy_unspecified" if enforcement == "completion_gate" else "workspace_stage",
            "taskIds": [],
            "taskInstanceIds": [],
            "worklineIds": [],
            "intentFingerprints": [],
        }
    if not isinstance(value, Mapping):
        raise BrainControlError("BRAIN_CONTROL_DECISION_APPLICABILITY_INVALID", "decision applicability must be an object")
    allowed = {"mode", "taskIds", "taskInstanceIds", "worklineIds", "intentFingerprints"}
    _card_exact_fields(value, allowed, {"mode"}, "decision applicability")
    mode = _card_text(value["mode"], "decision.applicability.mode", 32).lower()
    if mode not in {"workspace_stage", "scoped", "legacy_unspecified"}:
        raise BrainControlError("BRAIN_CONTROL_DECISION_APPLICABILITY_INVALID", "decision applicability mode is invalid")
    task_ids = _card_list(value.get("taskIds"), "decision.applicability.taskIds", 12, 160)
    task_instance_ids = _card_list(value.get("taskInstanceIds"), "decision.applicability.taskInstanceIds", 12, 80)
    workline_ids = _card_list(value.get("worklineIds"), "decision.applicability.worklineIds", 12, 120)
    intent_fingerprints = _card_list(value.get("intentFingerprints"), "decision.applicability.intentFingerprints", 12, 128)
    if mode == "scoped" and not any((task_ids, task_instance_ids, workline_ids, intent_fingerprints)):
        raise BrainControlError("BRAIN_CONTROL_DECISION_APPLICABILITY_INVALID", "scoped applicability requires at least one exact selector")
    return {
        "mode": mode,
        "taskIds": task_ids,
        "taskInstanceIds": task_instance_ids,
        "worklineIds": workline_ids,
        "intentFingerprints": intent_fingerprints,
    }


def _decision_applicability_matches_scope(applicability: Mapping[str, Any], scope: Mapping[str, Any]) -> bool:
    if str(applicability.get("mode", "")) == "legacy_unspecified":
        return False
    selectors = (
        ("taskIds", "taskId"),
        ("taskInstanceIds", "taskInstanceId"),
        ("worklineIds", "worklineId"),
        ("intentFingerprints", "intentFingerprint"),
    )
    for decision_field, scope_field in selectors:
        values = applicability.get(decision_field, [])
        if values and str(scope.get(scope_field, "")) not in values:
            return False
    return True


def _normalize_decision_payload(value: Mapping[str, Any]) -> dict[str, Any]:
    if value.get("schema") == DECISION_GRAPH_SCHEMA:
        return _normalize_decision_graph_payload(value)
    schema = _card_text(value.get("schema"), "decision.schema", 96)
    if schema == "super-brain.card.decision.v1":
        allowed = {"schema", "summary", "rationale", "consequences", "applicability", "acceptanceCriteria", "tags"}
        _card_exact_fields(value, allowed, {"schema", "summary", "rationale"}, "decision payload")
        applicability = _card_list(value.get("applicability"), "decision.applicability", 12, 240)
        return {
            "schema": "super-brain.card.decision.v2",
            "summary": _card_text(value["summary"], "decision.summary", 600),
            "rationale": _card_text(value["rationale"], "decision.rationale", 2400),
            "consequences": _card_list(value.get("consequences"), "decision.consequences", 12, 320),
            "stageKinds": [stage for stage in applicability if stage in DECISION_STAGE_KINDS],
            "enforcement": "advisory",
            "completionCriteria": _card_list(value.get("acceptanceCriteria"), "decision.acceptanceCriteria", 12, 320),
            "applicability": _normalize_decision_applicability({"mode": "workspace_stage"}, "advisory"),
            "tags": _card_list(value.get("tags"), "decision.tags", 12, 64),
        }
    allowed = {"schema", "summary", "rationale", "consequences", "stageKinds", "enforcement", "completionCriteria", "applicability", "tags"}
    _card_exact_fields(value, allowed, {"schema", "summary", "rationale", "enforcement"}, "decision payload")
    if schema != "super-brain.card.decision.v2":
        raise BrainControlError("BRAIN_CONTROL_CARD_SCHEMA_INVALID", "decision payload requires super-brain.card.decision.v2")
    stages = _card_list(value.get("stageKinds"), "decision.stageKinds", 5, 24)
    if any(stage not in DECISION_STAGE_KINDS for stage in stages):
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", "decision.stageKinds contains an unsupported stage")
    enforcement = _card_text(value["enforcement"], "decision.enforcement", 32).lower()
    if enforcement not in DECISION_ENFORCEMENTS:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", f"unsupported decision enforcement: {enforcement}")
    completion_criteria = _card_list(value.get("completionCriteria"), "decision.completionCriteria", 12, 320)
    if enforcement == "completion_gate" and (not stages or not completion_criteria):
        raise BrainControlError(
            "BRAIN_CONTROL_CARD_FIELD_REQUIRED",
            "completion-gate decisions require stageKinds and completionCriteria",
        )
    applicability = _normalize_decision_applicability(value.get("applicability"), enforcement)
    return {
        "schema": "super-brain.card.decision.v2",
        "summary": _card_text(value["summary"], "decision.summary", 600),
        "rationale": _card_text(value["rationale"], "decision.rationale", 2400),
        "consequences": _card_list(value.get("consequences"), "decision.consequences", 12, 320),
        "stageKinds": stages,
        "enforcement": enforcement,
        "completionCriteria": completion_criteria,
        "applicability": applicability,
        "tags": _card_list(value.get("tags"), "decision.tags", 12, 64),
    }


def _normalize_preference_payload(value: Mapping[str, Any]) -> dict[str, Any]:
    allowed = {"schema", "statement", "conditions", "confidence", "evidenceUses", "conflictState", "revalidateAfter", "tags"}
    _card_exact_fields(value, allowed, {"schema", "statement", "confidence"}, "preference payload")
    conflict_state = _card_text(value.get("conflictState", "clear"), "preference.conflictState", 24).lower()
    if conflict_state not in {"clear", "conflicted", "suppressed"}:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", "preference.conflictState is invalid")
    return {
        "schema": "super-brain.card.preference.v1",
        "statement": _card_text(value["statement"], "preference.statement", 600),
        "conditions": _card_list(value.get("conditions"), "preference.conditions", 12, 240),
        "confidence": _card_integer(value["confidence"], "preference.confidence", 0, 100),
        "evidenceUses": _card_integer(value.get("evidenceUses", 0), "preference.evidenceUses", 0, 10_000),
        "conflictState": conflict_state,
        "revalidateAfter": _card_text(value.get("revalidateAfter"), "preference.revalidateAfter", 40, required=False),
        "tags": _card_list(value.get("tags"), "preference.tags", 12, 64),
    }


def _normalize_experience_payload(value: Mapping[str, Any]) -> dict[str, Any]:
    allowed = {
        "schema", "context", "outcome", "lesson", "reuseConditions", "trigger", "rootCause", "prevention",
        "recurrence", "validationState", "revalidateAfter", "tags",
    }
    _card_exact_fields(value, allowed, {"schema", "context", "outcome", "lesson"}, "experience payload")
    validation_state = _card_text(value.get("validationState", "candidate"), "experience.validationState", 24).lower()
    if validation_state not in {"candidate", "validated", "adopted", "rejected", "resolved"}:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", "experience.validationState is invalid")
    return {
        "schema": "super-brain.card.experience.v1",
        "context": _card_text(value["context"], "experience.context", 1200),
        "outcome": _card_text(value["outcome"], "experience.outcome", 1200),
        "lesson": _card_text(value["lesson"], "experience.lesson", 1200),
        "reuseConditions": _card_list(value.get("reuseConditions"), "experience.reuseConditions", 12, 240),
        "trigger": _card_text(value.get("trigger"), "experience.trigger", 600, required=False),
        "rootCause": _card_text(value.get("rootCause"), "experience.rootCause", 1200, required=False),
        "prevention": _card_text(value.get("prevention"), "experience.prevention", 1200, required=False),
        "recurrence": _card_integer(value.get("recurrence", 0), "experience.recurrence", 0, 10_000),
        "validationState": validation_state,
        "revalidateAfter": _card_text(value.get("revalidateAfter"), "experience.revalidateAfter", 40, required=False),
        "tags": _card_list(value.get("tags"), "experience.tags", 12, 64),
    }


def _normalize_note_payload(value: Mapping[str, Any]) -> dict[str, Any]:
    allowed = {"schema", "body", "tags", "links", "pinned"}
    _card_exact_fields(value, allowed, {"schema", "body"}, "note payload")
    return {
        "schema": "super-brain.card.note.v1",
        "body": _card_text(value["body"], "note.body", 6000),
        "tags": _card_list(value.get("tags"), "note.tags", 12, 64),
        "links": _card_list(value.get("links"), "note.links", 16, 320),
        "pinned": _card_boolean(value.get("pinned", False), "note.pinned"),
    }


def _normalize_procedure_payload(value: Mapping[str, Any]) -> dict[str, Any]:
    allowed = {"schema", "objective", "preconditions", "steps", "verification", "tags"}
    _card_exact_fields(value, allowed, {"schema", "objective", "steps"}, "procedure payload")
    return {
        "schema": "super-brain.card.procedure.v1",
        "objective": _card_text(value["objective"], "procedure.objective", 600),
        "preconditions": _card_list(value.get("preconditions"), "procedure.preconditions", 12, 320),
        "steps": _card_list(value["steps"], "procedure.steps", 24, 800, required=True),
        "verification": _card_list(value.get("verification"), "procedure.verification", 12, 320),
        "tags": _card_list(value.get("tags"), "procedure.tags", 12, 64),
    }


def _normalize_reflection_payload(value: Mapping[str, Any]) -> dict[str, Any]:
    allowed = {"schema", "observation", "hypothesis", "proposedAction", "evidence", "confidence", "candidateState", "suggestedKind", "tags"}
    _card_exact_fields(value, allowed, {"schema", "observation", "hypothesis", "proposedAction", "confidence"}, "reflection payload")
    candidate_state = _card_text(value.get("candidateState", "candidate"), "reflection.candidateState", 24).lower()
    if candidate_state not in {"candidate", "validated", "staged", "adopted", "rejected", "resolved"}:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", "reflection.candidateState is invalid")
    evidence = _card_list(value.get("evidence"), "reflection.evidence", 12, 320)
    if candidate_state != "candidate" and not evidence:
        raise BrainControlError("BRAIN_CONTROL_REFLECTION_EVIDENCE_REQUIRED", "non-candidate reflection states require evidence")
    suggested_kind = _card_text(value.get("suggestedKind", ""), "reflection.suggestedKind", 32, required=False).lower()
    if suggested_kind and suggested_kind not in NATIVE_MEMORY_LEARNING_SUGGESTED_KINDS:
        raise BrainControlError("BRAIN_CONTROL_CARD_FIELD_INVALID", "reflection.suggestedKind is invalid")
    return {
        "schema": "super-brain.card.reflection.v1",
        "observation": _card_text(value["observation"], "reflection.observation", 1200),
        "hypothesis": _card_text(value["hypothesis"], "reflection.hypothesis", 1200),
        "proposedAction": _card_text(value["proposedAction"], "reflection.proposedAction", 1200),
        "evidence": evidence,
        "confidence": _card_integer(value["confidence"], "reflection.confidence", 0, 100),
        "candidateState": candidate_state,
        "suggestedKind": suggested_kind,
        "tags": _card_list(value.get("tags"), "reflection.tags", 12, 64),
    }


CARD_CONTRACTS: dict[str, CardContract] = {
    "decision": CardContract(
        "decision", "super-brain.card.decision.v2", _normalize_decision_payload,
        frozenset({"create_card", "edit_card", "supersede_card", "rollback_card", "trash_card", "restore_card", "cancel_card", "forget_active", "forget_trashed", "upsert_card"}),
        LIFECYCLES, ("summary", "stageKinds", "enforcement", "completionCriteria", "applicability", "tags"),
    ),
    "preference": CardContract(
        "preference", "super-brain.card.preference.v1", _normalize_preference_payload,
        frozenset({"create_card", "edit_card", "supersede_card", "rollback_card", "trash_card", "restore_card", "cancel_card", "forget_active", "forget_trashed", "upsert_card"}),
        LIFECYCLES, ("statement", "conditions", "confidence", "tags"),
    ),
    "experience": CardContract(
        "experience", "super-brain.card.experience.v1", _normalize_experience_payload,
        frozenset({"create_card", "edit_card", "supersede_card", "rollback_card", "trash_card", "restore_card", "cancel_card", "forget_active", "forget_trashed", "upsert_card"}),
        LIFECYCLES, ("lesson", "reuseConditions", "tags"),
    ),
    "note": CardContract(
        "note", "super-brain.card.note.v1", _normalize_note_payload,
        frozenset({"create_card", "edit_card", "rollback_card", "trash_card", "restore_card", "cancel_card", "forget_active", "forget_trashed", "upsert_card"}),
        LIFECYCLES, ("tags", "links", "pinned"),
    ),
    "procedure": CardContract(
        "procedure", "super-brain.card.procedure.v1", _normalize_procedure_payload,
        frozenset({"create_card", "edit_card", "supersede_card", "rollback_card", "trash_card", "restore_card", "cancel_card", "forget_active", "forget_trashed", "upsert_card"}),
        LIFECYCLES, ("objective", "verification", "tags"),
    ),
    "reflection": CardContract(
        "reflection", "super-brain.card.reflection.v1", _normalize_reflection_payload,
        frozenset({"create_card", "edit_card", "supersede_card", "rollback_card", "trash_card", "restore_card", "cancel_card", "forget_active", "forget_trashed", "upsert_card"}),
        LIFECYCLES, ("observation", "proposedAction", "confidence", "tags"),
    ),
}


def _card_search_text(title: str, payload: Mapping[str, Any]) -> str:
    """Return the bounded private text indexed only inside the local SQLite authority."""

    fragments: list[str] = [title]

    def visit(value: Any) -> None:
        if isinstance(value, Mapping):
            for key, nested in value.items():
                if key == "schema":
                    continue
                visit(nested)
        elif isinstance(value, (list, tuple)):
            for nested in value:
                visit(nested)
        elif isinstance(value, str) and value:
            fragments.append(value)

    visit(payload)
    return "\n".join(fragments)[:12_000]


def _fts_query(value: Any) -> str:
    raw = _card_text(value, "query", 240, required=False)
    tokens = re.findall(r"[\w\u4e00-\u9fff]+", raw, flags=re.UNICODE)
    if not tokens:
        return ""
    return " AND ".join(f'"{token}"' for token in tokens[:12])


def _normalize_card_payload(kind: str, value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise BrainControlError("BRAIN_CONTROL_PAYLOAD_INVALID", "payload must be an object")
    _ensure_safe(value, "payload")
    contract = CARD_CONTRACTS.get(kind)
    if contract is None:
        raise BrainControlError("BRAIN_CONTROL_CARD_KIND_INVALID", f"unsupported card kind: {kind}")
    schema = _card_text(value.get("schema"), "payload.schema", 96)
    if kind == "decision" and schema == DECISION_GRAPH_SCHEMA:
        return _normalize_decision_graph_payload(value)
    if kind == "decision" and schema == "super-brain.card.decision.v1":
        return _normalize_decision_payload(value)
    if schema != contract.schema:
        raise BrainControlError(
            "BRAIN_CONTROL_CARD_SCHEMA_INVALID",
            f"{kind} payload requires {contract.schema}; unsupported schemas must be migrated explicitly",
        )
    return contract.normalizer(value)


def _normalize_actor_receipt(value: Any) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", "actorReceipt must be an object")
    allowed = {"schema", "actorKind", "actorId", "authorization", "authorizationReceipt"}
    _card_exact_fields(value, allowed, {"schema", "actorKind", "authorization"}, "actorReceipt")
    if _card_text(value["schema"], "actorReceipt.schema", 96) != ACTOR_RECEIPT_SCHEMA:
        raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", f"actorReceipt requires {ACTOR_RECEIPT_SCHEMA}")
    actor_kind = _card_text(value["actorKind"], "actorReceipt.actorKind", 48).lower()
    authorization = _card_text(value["authorization"], "actorReceipt.authorization", 48).lower()
    if actor_kind not in {"user", "system", "migration", "test", "legacy"}:
        raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", f"unsupported actorKind: {actor_kind}")
    if authorization not in {"user_confirmed", "system", "legacy", "test"}:
        raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", f"unsupported authorization: {authorization}")
    return {
        "schema": ACTOR_RECEIPT_SCHEMA,
        "actorKind": actor_kind,
        "actorId": _card_text(value.get("actorId"), "actorReceipt.actorId", 160, required=False),
        "authorization": authorization,
        "authorizationReceipt": _card_text(value.get("authorizationReceipt"), "actorReceipt.authorizationReceipt", 240, required=False),
    }


def _normalize_timeline_source_context(value: Any) -> dict[str, str] | None:
    """Accept only a bounded, server-derived task/conversation source for a new card."""

    if value is None:
        return None
    if not isinstance(value, Mapping):
        raise BrainControlError("BRAIN_CONTROL_CARD_SOURCE_INVALID", "sourceContext must be an object")
    allowed = {
        "schema",
        "taskId",
        "taskInstanceId",
        "workspaceKey",
        "ownerSessionKey",
        "conversationTitle",
    }
    try:
        _card_exact_fields(
            value,
            allowed,
            {"schema", "taskId", "workspaceKey", "ownerSessionKey"},
            "sourceContext",
        )
    except BrainControlError as exc:
        raise BrainControlError("BRAIN_CONTROL_CARD_SOURCE_INVALID", "sourceContext is incomplete or unsupported") from exc
    if _card_text(value.get("schema"), "sourceContext.schema", 96) != TIMELINE_SOURCE_CONTEXT_SCHEMA:
        raise BrainControlError("BRAIN_CONTROL_CARD_SOURCE_INVALID", "sourceContext schema is invalid")
    return {
        "taskId": _card_text(value.get("taskId"), "sourceContext.taskId", 160),
        "taskInstanceId": _card_text(value.get("taskInstanceId"), "sourceContext.taskInstanceId", 80, required=False),
        "workspaceKey": _card_text(value.get("workspaceKey"), "sourceContext.workspaceKey", 120),
        "ownerSessionKey": _card_text(value.get("ownerSessionKey"), "sourceContext.ownerSessionKey", 120),
        "conversationTitle": _card_text(value.get("conversationTitle"), "sourceContext.conversationTitle", 160, required=False),
    }


def _redact_card_payload(kind: str, payload: Mapping[str, Any], privacy_class: str) -> dict[str, Any]:
    """Create the only payload form suitable for a downstream read projection."""

    schema = str(payload.get("schema", ""))
    if privacy_class == "private":
        return {"schema": schema, "redacted": True, "reason": "private_card"}
    contract = CARD_CONTRACTS[kind]
    projection = {"schema": schema}
    for field in contract.projection_fields:
        if field in payload:
            projection[field] = payload[field]
    projection["redacted"] = True
    return projection


def mcp_host_scope_ref(workspace_key: str, owner_session_key: str) -> str:
    """Hash the exact host scope without publishing either raw identifier."""

    workspace = str(workspace_key or "").strip().lower()
    session = str(owner_session_key or "").strip().lower()
    if not workspace or not session:
        return ""
    return _sha256({"workspaceKey": workspace, "ownerSessionKey": session})


def _mcp_projection_text(value: Any, maximum: int) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    if len(text) <= maximum:
        return text
    return text[: max(0, maximum - 3)].rstrip() + "..."


def _mcp_projection_list(value: Any, maximum_items: int = 4, maximum_chars: int = 180) -> list[str]:
    if not isinstance(value, (list, tuple)):
        return []
    result: list[str] = []
    for item in value:
        if not isinstance(item, str):
            continue
        text = _mcp_projection_text(item, maximum_chars)
        if text and text not in result:
            result.append(text)
        if len(result) >= maximum_items:
            break
    return result


def _normalize_mcp_task_projection(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, Mapping):
        return None
    digests = {}
    for name in ("taskRef", "scopeRef", "hostScopeRef", "stateHash"):
        digest = value.get(name)
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            return None
        digests[name] = digest
    revision = value.get("revision")
    contract_revision = value.get("contractRevision")
    if (
        isinstance(revision, bool)
        or not isinstance(revision, int)
        or revision < 0
        or isinstance(contract_revision, bool)
        or not isinstance(contract_revision, int)
        or contract_revision < 0
    ):
        return None
    lifecycle = value.get("lifecycle")
    if lifecycle not in TASK_LIFECYCLES:
        return None
    if value.get("actionAuthorization") != "withheld":
        return None
    if value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return None
    package_version = value.get("packageVersion", "")
    plan_fingerprint = value.get("planFingerprint", "")
    updated_at = value.get("updatedAt", "")
    if not isinstance(package_version, str) or len(package_version) > 48:
        return None
    if not isinstance(plan_fingerprint, str) or len(plan_fingerprint) > 128:
        return None
    if not isinstance(updated_at, str) or len(updated_at) > 48:
        return None
    text_limits = {
        "lastConfirmedSentence": 280,
        "lastConfirmedSource": 80,
        "currentPhase": 180,
        "currentStep": 260,
        "nextAction": 360,
    }
    texts: dict[str, str] = {}
    for name, maximum in text_limits.items():
        text = value.get(name, "")
        if not isinstance(text, str) or len(text) > maximum:
            return None
        texts[name] = text
    lists: dict[str, list[str]] = {}
    for name in ("completedSteps", "pendingSteps", "blockers", "evidenceRefs", "verificationResults"):
        items = value.get(name, [])
        if not isinstance(items, list) or len(items) > 4 or any(not isinstance(item, str) or len(item) > 180 for item in items):
            return None
        lists[name] = list(items)
    return {
        **digests,
        "revision": revision,
        "stateHash": digests["stateHash"],
        "packageVersion": package_version,
        "lifecycle": lifecycle,
        "contractRevision": contract_revision,
        "planFingerprint": plan_fingerprint,
        **texts,
        **lists,
        "updatedAt": updated_at,
        "actionAuthorization": "withheld",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def read_mcp_snapshot(path: str | Path, *, now: datetime | None = None) -> dict[str, Any]:
    """Read and validate a publisher-produced MCP snapshot without opening SQLite."""

    snapshot_path = Path(path)
    if not snapshot_path.is_file():
        return {"ok": True, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_MISSING"}
    try:
        if snapshot_path.stat().st_size > MCP_SNAPSHOT_MAX_BYTES:
            return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_TOO_LARGE"}
        raw = snapshot_path.read_text(encoding="utf-8")
        value = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
    if not isinstance(value, Mapping):
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
    supplied_hash = value.get("payloadHash")
    body = {key: nested for key, nested in value.items() if key != "payloadHash"}
    if value.get("schema") != MCP_SNAPSHOT_SCHEMA or not isinstance(supplied_hash, str) or _sha256(body) != supplied_hash:
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_UNTRUSTED"}
    generated_at = _parse_utc_timestamp(value.get("generatedAt"))
    if generated_at is None:
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_TIMESTAMP_INVALID"}
    if now is None:
        effective_now = datetime.now(UTC)
    elif now.tzinfo is None:
        effective_now = now.replace(tzinfo=UTC)
    else:
        effective_now = now.astimezone(UTC)
    if generated_at > effective_now:
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_FUTURE"}
    status = value.get("status")
    refs = value.get("taskProjectionRefs", [])
    task_projections = value.get("taskProjections", [])
    if (
        not isinstance(status, Mapping)
        or not isinstance(refs, list)
        or len(refs) > MCP_TASK_REFERENCE_MAX_ITEMS
        or not isinstance(task_projections, list)
        or len(task_projections) > MCP_TASK_PROJECTION_MAX_ITEMS
    ):
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
    required_status_counts = {
        "schemaVersion", "cards", "events", "pendingOutbox", "intentAggregates", "intentReceipts", "taskAggregates", "taskRevisions"
    }
    if not required_status_counts.issubset(status) or any(
        isinstance(status[name], bool) or not isinstance(status[name], int) or status[name] < 0
        for name in required_status_counts
    ):
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
    normalized_refs: list[dict[str, Any]] = []
    for item in refs:
        if not isinstance(item, Mapping):
            return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
        aggregate_ref = item.get("aggregateRef")
        revision = item.get("revision")
        lifecycle = item.get("lifecycle")
        if (
            not isinstance(aggregate_ref, str)
            or not SHA256_RE.fullmatch(aggregate_ref)
            or isinstance(revision, bool)
            or not isinstance(revision, int)
            or revision < 0
            or lifecycle not in TASK_LIFECYCLES
        ):
            return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
        normalized_refs.append({"aggregateRef": aggregate_ref, "revision": revision, "lifecycle": lifecycle})
    normalized_task_projections: list[dict[str, Any]] = []
    seen_scope_refs: set[str] = set()
    for item in task_projections:
        projection = _normalize_mcp_task_projection(item)
        if projection is None or projection["scopeRef"] in seen_scope_refs:
            return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
        seen_scope_refs.add(projection["scopeRef"])
        normalized_task_projections.append(projection)
    delivery_watermark = value.get("deliveryWatermark")
    task_projection_overflow = value.get("taskProjectionOverflow", False)
    if not isinstance(task_projection_overflow, bool):
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
    if delivery_watermark is not None:
        if not isinstance(delivery_watermark, Mapping):
            return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
        event_count = delivery_watermark.get("eventCount")
        event_set_hash = delivery_watermark.get("eventSetHash")
        if (
            isinstance(event_count, bool)
            or not isinstance(event_count, int)
            or event_count < 0
            or not isinstance(event_set_hash, str)
            or not SHA256_RE.fullmatch(event_set_hash)
        ):
            return {"ok": False, "available": False, "code": "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID"}
        delivery_watermark = {"eventCount": event_count, "eventSetHash": event_set_hash}
    return {
        "ok": True,
        "available": True,
        "schema": MCP_SNAPSHOT_SCHEMA,
        "payloadHash": supplied_hash,
        "generatedAt": value.get("generatedAt", ""),
        "status": dict(status),
        "taskProjectionRefs": normalized_refs,
        "taskProjections": normalized_task_projections,
        "taskProjectionOverflow": task_projection_overflow,
        "deliveryWatermark": delivery_watermark,
    }


def read_mcp_task_projection(
    path: str | Path,
    *,
    workspace_key: str,
    owner_session_key: str,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Return one exact host-bound current task projection or fail closed."""

    host_scope_ref = mcp_host_scope_ref(workspace_key, owner_session_key)
    if not host_scope_ref:
        return {"ok": False, "available": False, "status": "invalid_scope", "code": "BRAIN_CONTROL_MCP_TASK_SCOPE_INVALID"}
    snapshot = read_mcp_snapshot(path, now=now)
    if not snapshot.get("ok") or not snapshot.get("available"):
        return {
            "ok": bool(snapshot.get("ok")),
            "available": False,
            "status": "unavailable",
            "code": str(snapshot.get("code", "BRAIN_CONTROL_MCP_SNAPSHOT_INVALID")),
        }
    if snapshot.get("taskProjectionOverflow") is True:
        return {"ok": True, "available": False, "status": "overflow", "code": "BRAIN_CONTROL_MCP_TASK_PROJECTION_OVERFLOW"}
    matches = [
        item
        for item in snapshot.get("taskProjections", [])
        if item.get("hostScopeRef") == host_scope_ref and item.get("lifecycle") in MCP_CURRENT_TASK_LIFECYCLES
    ]
    if not matches:
        return {"ok": True, "available": False, "status": "missing", "code": "BRAIN_CONTROL_MCP_TASK_SCOPE_MISSING"}
    if len(matches) != 1:
        return {
            "ok": True,
            "available": False,
            "status": "ambiguous",
            "code": "BRAIN_CONTROL_MCP_TASK_SCOPE_AMBIGUOUS",
            "matchCount": len(matches),
        }
    return {
        "ok": True,
        "available": True,
        "status": "current",
        "code": "BRAIN_CONTROL_MCP_TASK_SCOPE_CURRENT",
        "snapshotHash": snapshot["payloadHash"],
        "generatedAt": snapshot["generatedAt"],
        "projection": matches[0],
    }


def read_card_projection(path: str | Path) -> dict[str, Any]:
    """Read a redacted card compatibility projection without opening SQLite."""

    projection_path = Path(path)
    if not projection_path.is_file():
        return {"ok": True, "available": False, "code": "BRAIN_CONTROL_CARD_PROJECTION_MISSING"}
    try:
        if projection_path.stat().st_size > MCP_SNAPSHOT_MAX_BYTES:
            return {"ok": False, "available": False, "code": "BRAIN_CONTROL_CARD_PROJECTION_TOO_LARGE"}
        value = json.loads(projection_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_CARD_PROJECTION_INVALID"}
    if not isinstance(value, Mapping):
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_CARD_PROJECTION_INVALID"}
    supplied_hash = value.get("payloadHash")
    body = {key: nested for key, nested in value.items() if key != "payloadHash"}
    cards = value.get("cards")
    if (
        value.get("schema") != CARD_PROJECTION_SCHEMA
        or not isinstance(supplied_hash, str)
        or _sha256(body) != supplied_hash
        or not isinstance(cards, list)
        or len(cards) > 512
    ):
        return {"ok": False, "available": False, "code": "BRAIN_CONTROL_CARD_PROJECTION_UNTRUSTED"}
    return {
        "ok": True,
        "available": True,
        "schema": CARD_PROJECTION_SCHEMA,
        "payloadHash": supplied_hash,
        "generatedAt": value.get("generatedAt", ""),
        "lastEventSequence": value.get("lastEventSequence", 0),
        "cards": cards,
    }


def _normalize_intent_contract(value: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise BrainControlError("BRAIN_CONTROL_INTENT_INVALID", "intentContract must be an object")
    _ensure_safe(value, "intentContract")
    schema = str(value.get("schema", INTENT_CONTRACT_SCHEMA)).strip()
    if schema != INTENT_CONTRACT_SCHEMA:
        raise BrainControlError("BRAIN_CONTROL_INTENT_SCHEMA_INVALID", f"new intent resolution requires {INTENT_CONTRACT_SCHEMA}")

    integration = value.get("integrationMap")
    if not isinstance(integration, Mapping):
        raise BrainControlError("BRAIN_CONTROL_INTENT_INTEGRATION_MAP_REQUIRED", "integrationMap is required")
    normalized_integration: dict[str, Any] = {
        name: _bounded_text(integration.get(name), f"integrationMap.{name}", 240)
        for name in INTENT_INTEGRATION_FIELDS
    }
    normalized_integration["downstreamConsumers"] = _bounded_list(
        integration.get("downstreamConsumers"),
        "integrationMap.downstreamConsumers",
        8,
        180,
    )

    autonomy_tier = _bounded_text(value.get("autonomyTier"), "autonomyTier", 24).lower()
    if autonomy_tier not in INTENT_AUTONOMY_TIERS:
        raise BrainControlError("BRAIN_CONTROL_INTENT_AUTONOMY_INVALID", f"unsupported autonomyTier: {autonomy_tier}")
    material_branches = _bounded_list(value.get("materialBranches", []), "materialBranches", 4, 180, required=False)
    focused_question = _bounded_text(value.get("focusedQuestion", ""), "focusedQuestion", 240, required=False)
    if len(material_branches) >= 2 and not focused_question:
        raise BrainControlError("BRAIN_CONTROL_INTENT_FOCUSED_QUESTION_REQUIRED", "material branches require one focused question")

    preserve_existing_flow = value.get("preserveExistingFlow")
    if not isinstance(preserve_existing_flow, bool):
        raise BrainControlError("BRAIN_CONTROL_INTENT_PRESERVATION_REQUIRED", "preserveExistingFlow must be boolean")
    replacement_receipt = _bounded_text(value.get("replacementReceipt", ""), "replacementReceipt", 180, required=False)
    if not preserve_existing_flow and not replacement_receipt:
        raise BrainControlError("BRAIN_CONTROL_INTENT_REPLACEMENT_RECEIPT_REQUIRED", "flow replacement requires an explicit receipt")

    component_resolution_value = value.get("componentResolution", {})
    if component_resolution_value is None:
        component_resolution_value = {}
    if not isinstance(component_resolution_value, Mapping):
        raise BrainControlError("BRAIN_CONTROL_INTENT_COMPONENT_RESOLUTION_INVALID", "componentResolution must be an object")
    requested_component = _bounded_text(
        component_resolution_value.get("requestedComponent", ""),
        "componentResolution.requestedComponent",
        160,
        required=False,
    )
    resolved_component = _bounded_text(
        component_resolution_value.get("resolvedComponent", ""),
        "componentResolution.resolvedComponent",
        160,
        required=False,
    )
    component_reason = _bounded_text(
        component_resolution_value.get("reason", ""),
        "componentResolution.reason",
        220,
        required=False,
    )
    outcome_preserved = component_resolution_value.get("outcomePreserved", True)
    if not isinstance(outcome_preserved, bool):
        raise BrainControlError("BRAIN_CONTROL_INTENT_COMPONENT_RESOLUTION_INVALID", "outcomePreserved must be boolean")
    if requested_component and resolved_component and requested_component != resolved_component:
        if not outcome_preserved or not component_reason:
            raise BrainControlError("BRAIN_CONTROL_INTENT_COMPONENT_REMAP_INVALID", "component remap must preserve the outcome and state its reason")

    normalized = {
        "schema": INTENT_CONTRACT_SCHEMA,
        "literalRequestDigest": _bounded_text(value.get("literalRequestDigest"), "literalRequestDigest", 240),
        "resolvedOutcome": _bounded_text(value.get("resolvedOutcome"), "resolvedOutcome", 280),
        "productRole": _bounded_text(value.get("productRole"), "productRole", 220),
        "integrationObligations": _bounded_list(value.get("integrationObligations"), "integrationObligations", 8, 180),
        "materialUnknowns": _bounded_list(value.get("materialUnknowns", []), "materialUnknowns", 4, 180, required=False),
        "compatibilityGuards": _bounded_list(value.get("compatibilityGuards"), "compatibilityGuards", 8, 180),
        "preservedCapabilities": _bounded_list(value.get("preservedCapabilities"), "preservedCapabilities", 8, 180),
        "acceptanceCriteria": _bounded_list(value.get("acceptanceCriteria"), "acceptanceCriteria", 8, 180),
        "governedEquivalent": _bounded_text(value.get("governedEquivalent"), "governedEquivalent", 220),
        "autonomyTier": autonomy_tier,
        "integrationMap": normalized_integration,
        "investigationEvidence": _bounded_list(value.get("investigationEvidence"), "investigationEvidence", 8, 220),
        "materialBranches": material_branches,
        "focusedQuestion": focused_question,
        "questionCount": 1 if focused_question else 0,
        "preserveExistingFlow": preserve_existing_flow,
        "replacementReceipt": replacement_receipt,
        "componentResolution": {
            "requestedComponent": requested_component,
            "resolvedComponent": resolved_component,
            "outcomePreserved": outcome_preserved,
            "reason": component_reason,
        },
        "rawTranscriptStored": False,
    }
    editable_request = re.search(r"(?i)\b(editable|edit)\b", normalized["literalRequestDigest"]) is not None
    blocks_direct_db = re.search(r"(?i)(no|without).{0,24}(direct).{0,24}(database|db|sqlite)", normalized["literalRequestDigest"]) is not None
    if editable_request and blocks_direct_db:
        combined = _canonical_json(normalized).lower()
        capability_text = " ".join(
            [
                normalized["resolvedOutcome"],
                normalized["productRole"],
                normalized["governedEquivalent"],
                *normalized["preservedCapabilities"],
            ]
        )
        if not re.search(r"(?i)(governed|command|api|service)", combined) or re.search(r"(?i)read[ -]?only", capability_text):
            raise BrainControlError("BRAIN_CONTROL_INTENT_GOVERNED_EQUIVALENT_REQUIRED", "editable access needs a governed mutation path")
        if not any(re.search(r"(?i)(no|without).{0,24}(browser|ui|client).{0,24}(direct).{0,24}(database|db|sqlite)", item) for item in normalized["compatibilityGuards"]):
            raise BrainControlError("BRAIN_CONTROL_INTENT_DIRECT_DATABASE_GUARD_REQUIRED", "editable UI intent must explicitly block browser-side database writes")
    if len(_canonical_json(normalized).encode("utf-8")) > 16384:
        raise BrainControlError("BRAIN_CONTROL_INTENT_TOO_LARGE", "normalized intent exceeds 16 KiB")
    return normalized


class BrainControl:
    """Typed, transactional local state authority with a small command interface."""

    def __init__(self, state_root: str | Path, *, ui_workspace_key: str = "") -> None:
        self.state_root = Path(state_root).expanduser().resolve()
        self.workspace = self.state_root / "workspace"
        self.db_path = self.workspace / "brain-state.sqlite3"
        self.package_root = Path(__file__).resolve().parents[1]
        self.ui_workspace_key = str(ui_workspace_key).strip().lower()
        if self.ui_workspace_key and re.fullmatch(r"ws-[0-9a-f]{24}", self.ui_workspace_key) is None:
            raise BrainControlError("BRAIN_CONTROL_UI_WORKSPACE_INVALID", "ui workspace key is invalid")

    @property
    def mcp_snapshot_path(self) -> Path:
        return self.workspace / "mcp-snapshot.json"

    @property
    def legacy_mcp_snapshot_path(self) -> Path:
        """Compatibility mirror for workers started before the state-root fix."""

        return self.state_root / "shared" / "workspace" / "mcp-snapshot.json"

    @property
    def card_projection_path(self) -> Path:
        return self.workspace / "card-projections.json"

    @property
    def native_decision_index_root(self) -> Path:
        return self.workspace / "native-decision-index"

    @property
    def native_decision_index_manifest_path(self) -> Path:
        return self.native_decision_index_root / "manifest.json"

    @property
    def native_memory_influence_snapshot_path(self) -> Path:
        """A bounded read-only projection consumed by the native prompt hook."""

        return self.workspace / "native-memory-influence-snapshot.json"

    @property
    def native_memory_influence_snapshot_dirty_path(self) -> Path:
        """Fail closed while a card mutation has not published a fresh projection."""

        return self.workspace / "native-memory-influence-snapshot.dirty.json"

    @property
    def typed_memory_trial_root(self) -> Path:
        return self.workspace / "runtime-state" / "typed-memory-trial-receipts"

    @property
    def typed_memory_trial_snapshot_root(self) -> Path:
        return self.workspace / "runtime-state" / "typed-memory-trial-snapshots"

    @staticmethod
    def _typed_memory_trial_token(task_id: str, task_instance_id: str) -> str:
        safe = re.sub(r"[^A-Za-z0-9._-]+", "-", str(task_id)).strip("-").lower() or "task"
        safe = safe[:96].rstrip("-") or "task"
        return f"{safe}--{_raw_sha256(task_id)[:16]}--ti-{_raw_sha256(task_instance_id)[:16]}"

    def _typed_memory_trial_path(self, task_id: str, task_instance_id: str) -> Path:
        del task_id
        return self.typed_memory_trial_root / (_raw_sha256(task_instance_id.lower()) + ".json")

    def _typed_memory_trial_snapshot_path(self, task_id: str, task_instance_id: str) -> Path:
        del task_id
        return self.typed_memory_trial_snapshot_root / (_raw_sha256(task_instance_id.lower()) + ".json")

    @staticmethod
    def _typed_memory_trial_absent() -> dict[str, Any]:
        return {
            "trialState": "not_started",
            "trialVerdict": "absent",
            "trialReceiptRef": "",
            "trialReceiptHash": "",
            "trialReason": "no_current_trial_receipt",
        }

    def _typed_memory_trial_projection_for_card(
        self,
        card: Mapping[str, Any],
        scope: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Read one task-instance-bound trial without exposing prompt/body data.

        A reflection is eligible for automatic trial display only when its card
        scope is the exact task instance.  Global/workspace reflections remain
        review material and cannot silently become a cross-task behavior rule.
        """

        if str(card.get("kind", "")) != "reflection":
            return self._typed_memory_trial_absent()
        card_scope = card.get("scope")
        if not isinstance(card_scope, Mapping) or str(card_scope.get("kind", "")) != "task_instance":
            return self._typed_memory_trial_absent()
        task_instance_id = str(card_scope.get("key", ""))
        if not re.fullmatch(r"ti-[0-9a-f]{16,80}", task_instance_id, re.IGNORECASE):
            return self._typed_memory_trial_absent()
        if scope is not None and str(scope.get("taskInstanceId", "")) != task_instance_id:
            return self._typed_memory_trial_absent()
        task_id = str(scope.get("taskId", "")) if scope is not None else ""
        workspace_key = str(scope.get("workspaceKey", "")) if scope is not None else self.ui_workspace_key
        if scope is not None and (not task_id or not workspace_key):
            return self._typed_memory_trial_absent()
        snapshot_path = self._typed_memory_trial_snapshot_path(task_id, task_instance_id)
        try:
            snapshot_raw = snapshot_path.read_bytes()
            snapshot = json.loads(snapshot_raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return self._typed_memory_trial_absent()
        if not isinstance(snapshot, Mapping) or snapshot.get("schema") != TYPED_MEMORY_TRIAL_SNAPSHOT_SCHEMA:
            return self._typed_memory_trial_absent()
        snapshot_task_id = str(snapshot.get("taskId", ""))
        snapshot_workspace_key = str(snapshot.get("workspaceKey", ""))
        privacy = snapshot.get("privacy")
        if (
            not snapshot_task_id
            or snapshot.get("taskInstanceId") != task_instance_id
            or (task_id and snapshot_task_id != task_id)
            or (workspace_key and snapshot_workspace_key != workspace_key)
            or snapshot.get("trialState") != "observed"
            or not isinstance(privacy, Mapping)
            or any(privacy.get(field) is not False for field in ("rawPromptStored", "rawSummaryStored", "rawTranscriptStored", "memoryBodyStored"))
        ):
            return self._typed_memory_trial_absent()
        refs = snapshot.get("memoryRefs")
        if not isinstance(refs, list) or not 1 <= len(refs) <= 8:
            return self._typed_memory_trial_absent()
        matched = False
        for ref in refs:
            if not isinstance(ref, Mapping):
                return self._typed_memory_trial_absent()
            try:
                if (
                    str(ref.get("cardId", "")) == str(card.get("cardId", ""))
                    and int(ref.get("cardRevision", 0)) == int(card.get("revision", 0))
                    and str(ref.get("kind", "")) == "reflection"
                ):
                    matched = True
            except (TypeError, ValueError):
                return self._typed_memory_trial_absent()
        if not matched:
            return self._typed_memory_trial_absent()
        receipt_path = self._typed_memory_trial_path(snapshot_task_id, task_instance_id)
        try:
            receipt_raw = receipt_path.read_bytes()
            receipt = json.loads(receipt_raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return {
                "trialState": "observed",
                "trialVerdict": "inconclusive",
                "trialReceiptRef": "",
                "trialReceiptHash": "",
                "trialReason": "trial_evidence_pending",
            }
        receipt_privacy = receipt.get("privacy") if isinstance(receipt, Mapping) else None
        source_hashes = receipt.get("sourceHashes") if isinstance(receipt, Mapping) else None
        verdict = str(receipt.get("verdict", "")) if isinstance(receipt, Mapping) else ""
        if (
            not isinstance(receipt, Mapping)
            or receipt.get("schema") != TYPED_MEMORY_TRIAL_RECEIPT_SCHEMA
            or receipt.get("taskId") != snapshot_task_id
            or receipt.get("taskInstanceId") != task_instance_id
            or receipt.get("workspaceKey") != snapshot_workspace_key
            or receipt.get("trialState") != "closed"
            or verdict not in TYPED_MEMORY_TRIAL_VERDICTS - {"absent"}
            or not isinstance(receipt_privacy, Mapping)
            or any(receipt_privacy.get(field) is not False for field in ("rawPromptStored", "rawSummaryStored", "rawTranscriptStored", "memoryBodyStored"))
            or not isinstance(source_hashes, Mapping)
            or source_hashes.get("snapshot") != _sha256_bytes(snapshot_raw)
        ):
            return self._typed_memory_trial_absent()
        return {
            "trialState": "closed",
            "trialVerdict": verdict,
            "trialReceiptRef": "typed-memory-trial:" + str(receipt.get("receiptId", "")),
            "trialReceiptHash": _sha256_bytes(receipt_raw),
            "trialReason": str(receipt.get("reasonCode", "trial_closed"))[:160],
        }

    def get_learning_trial_for_card(self, card_id: str) -> dict[str, Any]:
        card = self.get_card(_require_string(card_id, "cardId", 160))
        if card is None:
            return self._typed_memory_trial_absent()
        if not self.ui_workspace_key:
            return self._typed_memory_trial_absent()
        return self._typed_memory_trial_projection_for_card(card)

    def _package_identity(self) -> dict[str, str]:
        manifest_path = self.package_root / "manifest.json"
        try:
            raw = manifest_path.read_bytes()
            manifest = json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BrainControlError("BRAIN_CONTROL_PACKAGE_IDENTITY_UNAVAILABLE", "package manifest is unavailable") from exc
        if not isinstance(manifest, Mapping):
            raise BrainControlError("BRAIN_CONTROL_PACKAGE_IDENTITY_INVALID", "package manifest must be an object")
        version = _require_string(manifest.get("version"), "manifest.version", 48)
        return {
            "packageVersion": version,
            "packageManifestHash": _sha256_bytes(raw),
        }

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        self.workspace.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.db_path, timeout=5.0, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA synchronous=FULL")
            connection.execute("PRAGMA busy_timeout=5000")
            self._migrate(connection)
            yield connection
        finally:
            connection.close()

    @contextmanager
    def _read_only_connection(self) -> Iterator[sqlite3.Connection]:
        """Open a strict immutable SQLite snapshot or fail closed.

        SQLite ``mode=ro`` can still update WAL shared-memory metadata.  This
        helper therefore refuses a live WAL/journal and uses ``immutable=1``
        only after taking a byte-level artifact snapshot.  Context uses JSON
        projections instead; this remains a safe diagnostic/read API.
        """

        before = self._read_only_artifact_hashes()
        if "-wal" in before or "-journal" in before:
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_READ_ONLY_MUTABLE_JOURNAL_PRESENT",
                "a live SQLite journal cannot be inspected without side effects",
            )
        try:
            database_uri = self.db_path.resolve().as_uri() + "?mode=ro&immutable=1"
        except OSError as exc:
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_READ_ONLY_DATABASE_UNAVAILABLE",
                "intent authority database cannot be opened read-only",
            ) from exc

        connection: sqlite3.Connection | None = None
        try:
            connection = sqlite3.connect(database_uri, uri=True, timeout=0.0, isolation_level=None)
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA query_only=ON")
            yield connection
        finally:
            if connection is not None:
                connection.close()
            after = self._read_only_artifact_hashes()
            if after != before:
                raise BrainControlError(
                    "BRAIN_CONTROL_INTENT_READ_ONLY_ARTIFACT_CHANGED",
                    "read-only intent inspection observed mutable SQLite artifacts",
                )

    def _read_only_artifact_hashes(self) -> dict[str, str]:
        """Fingerprint the only SQLite artifacts a read path could disturb."""

        try:
            if not self.db_path.is_file():
                raise BrainControlError(
                    "BRAIN_CONTROL_INTENT_READ_ONLY_DATABASE_MISSING",
                    "intent authority database is unavailable for read-only verification",
                )
            result: dict[str, str] = {}
            for suffix in ("", "-wal", "-shm", "-journal"):
                artifact = self.db_path.with_name(self.db_path.name + suffix)
                if artifact.is_file():
                    result[suffix] = _sha256_bytes(artifact.read_bytes())
            return result
        except OSError as exc:
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_READ_ONLY_DATABASE_UNAVAILABLE",
                "intent authority artifacts cannot be inspected read-only",
            ) from exc

    def _migrate(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
        )
        applied = {int(row[0]) for row in connection.execute("SELECT version FROM schema_migrations")}
        if 1 not in applied:
            connection.executescript(
                """
                CREATE TABLE cards (
                  card_id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  scope_kind TEXT NOT NULL,
                  scope_key TEXT NOT NULL,
                  lifecycle TEXT NOT NULL,
                  authority TEXT NOT NULL,
                  privacy_class TEXT NOT NULL,
                  head_revision INTEGER NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE card_revisions (
                  card_id TEXT NOT NULL,
                  revision INTEGER NOT NULL,
                  predecessor_hash TEXT NOT NULL,
                  content_hash TEXT NOT NULL,
                  title TEXT NOT NULL,
                  structured_payload TEXT NOT NULL,
                  evidence_refs TEXT NOT NULL,
                  actor_receipt TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  PRIMARY KEY (card_id, revision),
                  FOREIGN KEY (card_id) REFERENCES cards(card_id) ON DELETE CASCADE
                );
                CREATE TABLE command_log (
                  command_id TEXT PRIMARY KEY,
                  command_type TEXT NOT NULL,
                  aggregate_id TEXT NOT NULL,
                  expected_revision INTEGER NOT NULL,
                  payload_hash TEXT NOT NULL,
                  result_json TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );
                CREATE TABLE events (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                  event_id TEXT UNIQUE NOT NULL,
                  command_id TEXT NOT NULL,
                  command_type TEXT NOT NULL,
                  aggregate_id TEXT NOT NULL,
                  revision INTEGER NOT NULL,
                  expected_revision INTEGER NOT NULL,
                  result_code TEXT NOT NULL,
                  reason_code TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (command_id) REFERENCES command_log(command_id)
                );
                CREATE TABLE outbox (
                  event_id TEXT PRIMARY KEY,
                  aggregate_id TEXT NOT NULL,
                  revision INTEGER NOT NULL,
                  projection_kind TEXT NOT NULL,
                  payload_json TEXT NOT NULL,
                  status TEXT NOT NULL,
                  delivery_version INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL,
                  materialized_at TEXT NOT NULL DEFAULT '',
                  FOREIGN KEY (event_id) REFERENCES events(event_id)
                );
                CREATE INDEX idx_cards_kind_scope ON cards(kind, scope_kind, scope_key);
                CREATE INDEX idx_revisions_card ON card_revisions(card_id, revision DESC);
                CREATE INDEX idx_outbox_status ON outbox(status, created_at);
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (1, _utc_now())
            )
        if 2 not in applied:
            connection.executescript(
                """
                CREATE TABLE intent_aggregates (
                  aggregate_id TEXT PRIMARY KEY,
                  task_id TEXT NOT NULL,
                  task_instance_id TEXT NOT NULL,
                  workspace_key TEXT NOT NULL,
                  owner_session_key TEXT NOT NULL,
                  head_revision INTEGER NOT NULL,
                  latest_receipt_id TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  UNIQUE(task_id, task_instance_id, workspace_key)
                );
                CREATE TABLE intent_contract_revisions (
                  aggregate_id TEXT NOT NULL,
                  intent_revision INTEGER NOT NULL,
                  predecessor_contract_hash TEXT NOT NULL,
                  contract_fingerprint TEXT NOT NULL,
                  contract_json TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  PRIMARY KEY (aggregate_id, intent_revision),
                  FOREIGN KEY (aggregate_id) REFERENCES intent_aggregates(aggregate_id)
                );
                CREATE TABLE intent_receipts (
                  receipt_id TEXT PRIMARY KEY,
                  aggregate_id TEXT NOT NULL,
                  intent_revision INTEGER NOT NULL,
                  command_id TEXT UNIQUE NOT NULL,
                  task_id TEXT NOT NULL,
                  task_instance_id TEXT NOT NULL,
                  workspace_key TEXT NOT NULL,
                  owner_session_key TEXT NOT NULL,
                  package_version TEXT NOT NULL,
                  contract_revision INTEGER NOT NULL,
                  plan_fingerprint TEXT NOT NULL,
                  latest_instruction_hash TEXT NOT NULL,
                  contract_fingerprint TEXT NOT NULL,
                  payload_hash TEXT NOT NULL,
                  ready INTEGER NOT NULL CHECK(ready IN (0, 1)),
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (aggregate_id) REFERENCES intent_aggregates(aggregate_id),
                  FOREIGN KEY (aggregate_id, intent_revision) REFERENCES intent_contract_revisions(aggregate_id, intent_revision),
                  FOREIGN KEY (command_id) REFERENCES command_log(command_id)
                );
                CREATE INDEX idx_intent_aggregate_scope
                  ON intent_aggregates(task_id, task_instance_id, workspace_key);
                CREATE INDEX idx_intent_receipts_head
                  ON intent_receipts(aggregate_id, intent_revision DESC);
                CREATE TRIGGER intent_contract_revisions_no_update
                  BEFORE UPDATE ON intent_contract_revisions
                  BEGIN SELECT RAISE(ABORT, 'intent contract revisions are immutable'); END;
                CREATE TRIGGER intent_contract_revisions_no_delete
                  BEFORE DELETE ON intent_contract_revisions
                  BEGIN SELECT RAISE(ABORT, 'intent contract revisions are immutable'); END;
                CREATE TRIGGER intent_receipts_no_update
                  BEFORE UPDATE ON intent_receipts
                  BEGIN SELECT RAISE(ABORT, 'intent receipts are immutable'); END;
                CREATE TRIGGER intent_receipts_no_delete
                  BEFORE DELETE ON intent_receipts
                  BEGIN SELECT RAISE(ABORT, 'intent receipts are immutable'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (2, _utc_now())
            )
        if 3 not in applied:
            connection.executescript(
                """
                CREATE TABLE task_aggregates (
                  aggregate_id TEXT PRIMARY KEY,
                  task_id TEXT NOT NULL,
                  task_instance_id TEXT NOT NULL,
                  workspace_key TEXT NOT NULL,
                  owner_session_key TEXT NOT NULL,
                  package_version TEXT NOT NULL,
                  lifecycle TEXT NOT NULL,
                  head_revision INTEGER NOT NULL,
                  head_state_hash TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  UNIQUE(task_id, workspace_key)
                );
                CREATE TABLE task_state_revisions (
                  aggregate_id TEXT NOT NULL,
                  task_revision INTEGER NOT NULL,
                  predecessor_state_hash TEXT NOT NULL,
                  state_hash TEXT NOT NULL,
                  state_json TEXT NOT NULL,
                  command_id TEXT NOT NULL UNIQUE,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  PRIMARY KEY (aggregate_id, task_revision),
                  FOREIGN KEY (aggregate_id) REFERENCES task_aggregates(aggregate_id)
                );
                CREATE INDEX idx_task_aggregate_scope ON task_aggregates(task_id, workspace_key);
                CREATE INDEX idx_task_state_revision_head ON task_state_revisions(aggregate_id, task_revision DESC);
                CREATE TRIGGER task_state_revisions_no_update
                  BEFORE UPDATE ON task_state_revisions
                  BEGIN SELECT RAISE(ABORT, 'task state revisions are immutable'); END;
                CREATE TRIGGER task_state_revisions_no_delete
                  BEFORE DELETE ON task_state_revisions
                  BEGIN SELECT RAISE(ABORT, 'task state revisions are immutable'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (3, _utc_now())
            )
        revision_columns = {str(row[1]) for row in connection.execute("PRAGMA table_info(card_revisions)")}
        if "state_json" not in revision_columns:
            connection.execute("ALTER TABLE card_revisions ADD COLUMN state_json TEXT NOT NULL DEFAULT '{}'")
        connection.executescript(
            """
            CREATE TRIGGER IF NOT EXISTS card_revisions_no_update
              BEFORE UPDATE ON card_revisions
              BEGIN SELECT RAISE(ABORT, 'card revisions are immutable'); END;
            CREATE TRIGGER IF NOT EXISTS card_revisions_no_delete
              BEFORE DELETE ON card_revisions
              BEGIN SELECT RAISE(ABORT, 'card revisions are immutable'); END;
            """
        )
        if 4 not in applied:
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (4, _utc_now())
            )
        connection.executescript(
            """
                CREATE TABLE IF NOT EXISTS decision_resolution_receipts (
                  receipt_id TEXT PRIMARY KEY,
                  command_id TEXT NOT NULL UNIQUE,
                  aggregate_id TEXT NOT NULL,
                  task_id TEXT NOT NULL,
                  task_instance_id TEXT NOT NULL,
                  workspace_key TEXT NOT NULL,
                  owner_session_key TEXT NOT NULL,
                  stage_kind TEXT NOT NULL,
                  workline_id TEXT NOT NULL DEFAULT '',
                  intent_fingerprint TEXT NOT NULL DEFAULT '',
                  package_version TEXT NOT NULL,
                  contract_revision INTEGER NOT NULL,
                  plan_fingerprint TEXT NOT NULL,
                  status TEXT NOT NULL CHECK(status IN ('bound','none_applicable','withheld')),
                  binding_digest TEXT NOT NULL,
                  payload_hash TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (command_id) REFERENCES command_log(command_id)
                );
                CREATE TABLE IF NOT EXISTS decision_resolution_items (
                  receipt_id TEXT NOT NULL,
                  card_id TEXT NOT NULL,
                  card_revision INTEGER NOT NULL,
                  content_hash TEXT NOT NULL,
                  enforcement TEXT NOT NULL CHECK(enforcement IN ('advisory','completion_gate')),
                  completion_criteria_digest TEXT NOT NULL,
                  PRIMARY KEY (receipt_id, card_id, card_revision),
                  FOREIGN KEY (receipt_id) REFERENCES decision_resolution_receipts(receipt_id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS decision_completion_results (
                  result_id TEXT PRIMARY KEY,
                  command_id TEXT NOT NULL UNIQUE,
                  receipt_id TEXT NOT NULL,
                  card_id TEXT NOT NULL,
                  card_revision INTEGER NOT NULL,
                  content_hash TEXT NOT NULL,
                  completion_criteria_digest TEXT NOT NULL,
                  result_ok INTEGER NOT NULL CHECK(result_ok IN (0,1)),
                  evidence_refs TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  UNIQUE(receipt_id, card_id, card_revision),
                  FOREIGN KEY (receipt_id, card_id, card_revision)
                    REFERENCES decision_resolution_items(receipt_id, card_id, card_revision),
                  FOREIGN KEY (command_id) REFERENCES command_log(command_id)
                );
                CREATE INDEX IF NOT EXISTS idx_decision_resolution_scope
                  ON decision_resolution_receipts(task_id, task_instance_id, workspace_key, stage_kind, created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_decision_completion_receipt
                  ON decision_completion_results(receipt_id, card_id, card_revision);
                CREATE TRIGGER IF NOT EXISTS decision_resolution_receipts_no_update
                  BEFORE UPDATE ON decision_resolution_receipts
                  BEGIN SELECT RAISE(ABORT, 'decision resolution receipts are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS decision_resolution_receipts_no_delete
                  BEFORE DELETE ON decision_resolution_receipts
                  BEGIN SELECT RAISE(ABORT, 'decision resolution receipts are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS decision_resolution_items_no_update
                  BEFORE UPDATE ON decision_resolution_items
                  BEGIN SELECT RAISE(ABORT, 'decision resolution items are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS decision_resolution_items_no_delete
                  BEFORE DELETE ON decision_resolution_items
                  BEGIN SELECT RAISE(ABORT, 'decision resolution items are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS decision_completion_results_no_update
                  BEFORE UPDATE ON decision_completion_results
                  BEGIN SELECT RAISE(ABORT, 'decision completion results are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS decision_completion_results_no_delete
                  BEFORE DELETE ON decision_completion_results
                  BEGIN SELECT RAISE(ABORT, 'decision completion results are immutable'); END;
            """
        )
        if 5 not in applied:
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (5, _utc_now())
            )
        outbox_columns = {str(row[1]) for row in connection.execute("PRAGMA table_info(outbox)")}
        if "delivery_version" not in outbox_columns:
            connection.execute("ALTER TABLE outbox ADD COLUMN delivery_version INTEGER NOT NULL DEFAULT 0")
        if 6 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS outbox_deliveries (
                  event_id TEXT NOT NULL,
                  target TEXT NOT NULL,
                  artifact_path TEXT NOT NULL,
                  artifact_hash TEXT NOT NULL,
                  receipt_hash TEXT NOT NULL,
                  receipt_json TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  PRIMARY KEY (event_id, target),
                  FOREIGN KEY (event_id) REFERENCES outbox(event_id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_outbox_deliveries_target ON outbox_deliveries(target, created_at);
                CREATE TRIGGER IF NOT EXISTS outbox_deliveries_no_update
                  BEFORE UPDATE ON outbox_deliveries
                  BEGIN SELECT RAISE(ABORT, 'outbox delivery receipts are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS outbox_deliveries_no_delete
                  BEFORE DELETE ON outbox_deliveries
                  BEGIN SELECT RAISE(ABORT, 'outbox delivery receipts are immutable'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (6, _utc_now())
            )
        decision_receipt_columns = {str(row[1]) for row in connection.execute("PRAGMA table_info(decision_resolution_receipts)")}
        if "workline_id" not in decision_receipt_columns:
            connection.execute("ALTER TABLE decision_resolution_receipts ADD COLUMN workline_id TEXT NOT NULL DEFAULT ''")
        if "intent_fingerprint" not in decision_receipt_columns:
            connection.execute("ALTER TABLE decision_resolution_receipts ADD COLUMN intent_fingerprint TEXT NOT NULL DEFAULT ''")
        if 7 not in applied:
            connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_decision_resolution_binding_scope ON decision_resolution_receipts(task_id, task_instance_id, workspace_key, stage_kind, workline_id, intent_fingerprint, created_at DESC)"
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (7, _utc_now())
            )
        if 8 not in applied:
            connection.executescript(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS card_search USING fts5(
                  card_id UNINDEXED,
                  revision UNINDEXED,
                  title,
                  search_text,
                  tokenize='unicode61'
                );
                CREATE TABLE IF NOT EXISTS card_privacy_tombstones (
                  card_id TEXT PRIMARY KEY,
                  forgotten_revision INTEGER NOT NULL,
                  tombstone_hash TEXT NOT NULL,
                  forgotten_at TEXT NOT NULL,
                  purge_state TEXT NOT NULL CHECK(purge_state IN ('none','previewed','requested')),
                  purge_preview_id TEXT NOT NULL DEFAULT '',
                  FOREIGN KEY(card_id) REFERENCES cards(card_id)
                );
                CREATE TABLE IF NOT EXISTS ui_purge_previews (
                  preview_id TEXT PRIMARY KEY,
                  card_id TEXT NOT NULL,
                  expected_revision INTEGER NOT NULL,
                  confirmation_hash TEXT NOT NULL,
                  preview_json TEXT NOT NULL,
                  status TEXT NOT NULL CHECK(status IN ('previewed','requested','expired')),
                  created_at TEXT NOT NULL,
                  expires_at TEXT NOT NULL,
                  requested_at TEXT NOT NULL DEFAULT '',
                  FOREIGN KEY(card_id) REFERENCES cards(card_id)
                );
                CREATE TABLE IF NOT EXISTS ui_purge_requests (
                  request_id TEXT PRIMARY KEY,
                  preview_id TEXT NOT NULL UNIQUE,
                  card_id TEXT NOT NULL,
                  revision INTEGER NOT NULL,
                  actor_receipt TEXT NOT NULL,
                  result_json TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY(preview_id) REFERENCES ui_purge_previews(preview_id),
                  FOREIGN KEY(card_id) REFERENCES cards(card_id)
                );
                CREATE INDEX IF NOT EXISTS idx_ui_purge_previews_card ON ui_purge_previews(card_id, created_at DESC);
                CREATE TRIGGER IF NOT EXISTS ui_purge_requests_no_update
                  BEFORE UPDATE ON ui_purge_requests
                  BEGIN SELECT RAISE(ABORT, 'purge request receipts are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS ui_purge_requests_no_delete
                  BEFORE DELETE ON ui_purge_requests
                  BEGIN SELECT RAISE(ABORT, 'purge request receipts are immutable'); END;
                """
            )
            self._rebuild_card_search_in_transaction(connection)
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (8, _utc_now())
            )
        if 9 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS ui_drafts (
                  card_id TEXT PRIMARY KEY,
                  base_revision INTEGER NOT NULL,
                  draft_json TEXT NOT NULL,
                  draft_hash TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  expires_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_ui_drafts_expiry ON ui_drafts(expires_at);
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (9, _utc_now())
            )
        if 10 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS ui_task_retention_settings (
                  settings_key TEXT PRIMARY KEY CHECK(settings_key='default'),
                  completed_days INTEGER NOT NULL CHECK(completed_days BETWEEN 1 AND 3650),
                  trash_days INTEGER NOT NULL CHECK(trash_days BETWEEN 1 AND 3650),
                  revision INTEGER NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS ui_task_card_retention (
                  task_key TEXT PRIMARY KEY,
                  aggregate_id TEXT NOT NULL,
                  workspace_key TEXT NOT NULL,
                  owner_session_key TEXT NOT NULL,
                  task_revision INTEGER NOT NULL,
                  state_hash TEXT NOT NULL,
                  retention_state TEXT NOT NULL CHECK(retention_state IN ('visible','trashed','cleanup_preview')),
                  effective_completed_at TEXT NOT NULL,
                  state_changed_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS ui_task_retention_receipts (
                  receipt_id TEXT PRIMARY KEY,
                  task_key TEXT NOT NULL,
                  aggregate_id TEXT NOT NULL,
                  task_revision INTEGER NOT NULL,
                  state_hash TEXT NOT NULL,
                  action TEXT NOT NULL CHECK(action IN ('settings_updated','moved_to_trash','marked_for_cleanup','restored','reopened')),
                  from_state TEXT NOT NULL,
                  to_state TEXT NOT NULL,
                  effective_completed_at TEXT NOT NULL,
                  settings_json TEXT NOT NULL,
                  actor_receipt TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_ui_task_retention_state
                  ON ui_task_card_retention(retention_state, updated_at DESC);
                CREATE INDEX IF NOT EXISTS idx_ui_task_retention_receipts_task
                  ON ui_task_retention_receipts(task_key, created_at DESC);
                CREATE TRIGGER IF NOT EXISTS ui_task_retention_receipts_no_update
                  BEFORE UPDATE ON ui_task_retention_receipts
                  BEGIN SELECT RAISE(ABORT, 'task retention receipts are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS ui_task_retention_receipts_no_delete
                  BEFORE DELETE ON ui_task_retention_receipts
                  BEGIN SELECT RAISE(ABORT, 'task retention receipts are immutable'); END;
                """
            )
            connection.execute(
                """
                INSERT OR IGNORE INTO ui_task_retention_settings(settings_key,completed_days,trash_days,revision,updated_at)
                VALUES ('default',?,?,?,?)
                """,
                (TASK_RETENTION_DEFAULT_COMPLETED_DAYS, TASK_RETENTION_DEFAULT_TRASH_DAYS, 1, _utc_now()),
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (10, _utc_now())
            )
        if 11 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS card_source_links (
                  card_id TEXT PRIMARY KEY,
                  task_id TEXT NOT NULL,
                  task_instance_id TEXT NOT NULL,
                  workspace_key TEXT NOT NULL,
                  owner_session_key TEXT NOT NULL,
                  conversation_title TEXT NOT NULL DEFAULT '',
                  created_at TEXT NOT NULL,
                  FOREIGN KEY(card_id) REFERENCES cards(card_id)
                );
                CREATE INDEX IF NOT EXISTS idx_card_source_links_task
                  ON card_source_links(task_id, workspace_key, owner_session_key);
                CREATE TRIGGER IF NOT EXISTS card_source_links_no_update
                  BEFORE UPDATE ON card_source_links
                  BEGIN SELECT RAISE(ABORT, 'card source links are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS card_source_links_no_delete
                  BEFORE DELETE ON card_source_links
                  BEGIN SELECT RAISE(ABORT, 'card source links are immutable'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (11, _utc_now())
            )
        if 12 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS instruction_anchors (
                  global_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                  anchor_id TEXT NOT NULL UNIQUE,
                  workspace_key TEXT NOT NULL,
                  owner_session_key TEXT NOT NULL,
                  task_id TEXT NOT NULL,
                  task_sequence INTEGER NOT NULL,
                  instruction_text TEXT NOT NULL,
                  instruction_hash TEXT NOT NULL,
                  content_hash TEXT NOT NULL,
                  classification_json TEXT NOT NULL,
                  signals_json TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  raw_prompt_stored INTEGER NOT NULL CHECK(raw_prompt_stored IN (0, 1)),
                  UNIQUE(workspace_key, owner_session_key, task_id, task_sequence)
                );
                CREATE INDEX IF NOT EXISTS idx_instruction_anchors_scope_latest
                  ON instruction_anchors(workspace_key, owner_session_key, task_id, global_sequence DESC);
                CREATE INDEX IF NOT EXISTS idx_instruction_anchors_session_latest
                  ON instruction_anchors(workspace_key, owner_session_key, global_sequence DESC);
                CREATE TRIGGER IF NOT EXISTS instruction_anchors_no_update
                  BEFORE UPDATE ON instruction_anchors
                  BEGIN SELECT RAISE(ABORT, 'instruction anchors are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS instruction_anchors_no_delete
                  BEFORE DELETE ON instruction_anchors
                  BEGIN SELECT RAISE(ABORT, 'instruction anchors are append-only'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (12, _utc_now())
            )
        if 13 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS continuation_receipts (
                  global_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                  receipt_id TEXT NOT NULL UNIQUE,
                  workspace_key TEXT NOT NULL,
                  owner_session_key TEXT NOT NULL,
                  task_id TEXT NOT NULL,
                  task_instance_id TEXT NOT NULL,
                  package_version TEXT NOT NULL,
                  contract_revision INTEGER NOT NULL,
                  plan_fingerprint TEXT NOT NULL,
                  instruction_anchor_id TEXT NOT NULL DEFAULT '',
                  instruction_anchor_hash TEXT NOT NULL DEFAULT '',
                  state_hash TEXT NOT NULL,
                  state_json TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  UNIQUE(workspace_key, owner_session_key, task_id, contract_revision, state_hash)
                );
                CREATE INDEX IF NOT EXISTS idx_continuation_receipts_scope_latest
                  ON continuation_receipts(workspace_key, owner_session_key, task_id, global_sequence DESC);
                CREATE INDEX IF NOT EXISTS idx_continuation_receipts_session_latest
                  ON continuation_receipts(workspace_key, owner_session_key, global_sequence DESC);
                CREATE TRIGGER IF NOT EXISTS continuation_receipts_no_update
                  BEFORE UPDATE ON continuation_receipts
                  BEGIN SELECT RAISE(ABORT, 'continuation receipts are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS continuation_receipts_no_delete
                  BEFORE DELETE ON continuation_receipts
                  BEGIN SELECT RAISE(ABORT, 'continuation receipts are append-only'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (13, _utc_now())
            )
        if 14 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS migration_epochs (
                  epoch_id TEXT PRIMARY KEY,
                  status TEXT NOT NULL,
                  importer_version TEXT NOT NULL,
                  record_schema_version TEXT NOT NULL,
                  manifest_path TEXT NOT NULL,
                  manifest_hash TEXT NOT NULL,
                  plan_fingerprint TEXT NOT NULL,
                  source_roots_json TEXT NOT NULL,
                  backup_path TEXT NOT NULL,
                  backup_hash TEXT NOT NULL,
                  archive_root TEXT NOT NULL,
                  cutover_watermark INTEGER NOT NULL DEFAULT 0,
                  adapter_generation INTEGER NOT NULL DEFAULT 0,
                  created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS migration_records (
                  epoch_id TEXT NOT NULL,
                  record_key TEXT NOT NULL,
                  source_id TEXT NOT NULL,
                  relative_path TEXT NOT NULL,
                  source_hash TEXT NOT NULL,
                  source_identity TEXT NOT NULL,
                  source_format TEXT NOT NULL,
                  source_locator TEXT NOT NULL,
                  card_kind TEXT NOT NULL,
                  title TEXT NOT NULL,
                  content_hash TEXT NOT NULL,
                  status TEXT NOT NULL,
                  reason TEXT NOT NULL DEFAULT '',
                  archive_path TEXT NOT NULL DEFAULT '',
                  archive_hash TEXT NOT NULL DEFAULT '',
                  target_card_id TEXT NOT NULL DEFAULT '',
                  target_revision INTEGER NOT NULL DEFAULT 0,
                  imported_at TEXT NOT NULL DEFAULT '',
                  PRIMARY KEY(epoch_id, record_key),
                  FOREIGN KEY(epoch_id) REFERENCES migration_epochs(epoch_id) ON DELETE RESTRICT
                );
                CREATE TABLE IF NOT EXISTS migration_events (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                  event_id TEXT NOT NULL UNIQUE,
                  epoch_id TEXT NOT NULL,
                  action TEXT NOT NULL,
                  payload_hash TEXT NOT NULL,
                  result_json TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY(epoch_id) REFERENCES migration_epochs(epoch_id) ON DELETE RESTRICT
                );
                CREATE TABLE IF NOT EXISTS migration_adapters (
                  epoch_id TEXT NOT NULL,
                  adapter_name TEXT NOT NULL,
                  status TEXT NOT NULL,
                  generation INTEGER NOT NULL,
                  watermark INTEGER NOT NULL,
                  projection_path TEXT NOT NULL,
                  projection_hash TEXT NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY(epoch_id, adapter_name),
                  FOREIGN KEY(epoch_id) REFERENCES migration_epochs(epoch_id) ON DELETE RESTRICT
                );
                CREATE INDEX IF NOT EXISTS idx_migration_records_status
                  ON migration_records(epoch_id, status, record_key);
                CREATE INDEX IF NOT EXISTS idx_migration_events_epoch
                  ON migration_events(epoch_id, sequence DESC);
                CREATE TRIGGER IF NOT EXISTS migration_events_no_update
                  BEFORE UPDATE ON migration_events
                  BEGIN SELECT RAISE(ABORT, 'migration events are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS migration_events_no_delete
                  BEFORE DELETE ON migration_events
                  BEGIN SELECT RAISE(ABORT, 'migration events are append-only'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (14, _utc_now())
            )
        if 15 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS intent_session_rebinds (
                  rebind_id TEXT PRIMARY KEY,
                  command_id TEXT NOT NULL UNIQUE,
                  aggregate_id TEXT NOT NULL,
                  task_id TEXT NOT NULL,
                  task_instance_id TEXT NOT NULL,
                  workspace_key TEXT NOT NULL,
                  previous_owner_session_key TEXT NOT NULL,
                  new_owner_session_key TEXT NOT NULL,
                  intent_revision INTEGER NOT NULL,
                  latest_receipt_id TEXT NOT NULL,
                  latest_receipt_payload_hash TEXT NOT NULL,
                  payload_hash TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (aggregate_id) REFERENCES intent_aggregates(aggregate_id),
                  FOREIGN KEY (latest_receipt_id) REFERENCES intent_receipts(receipt_id),
                  FOREIGN KEY (command_id) REFERENCES command_log(command_id)
                );
                CREATE INDEX IF NOT EXISTS idx_intent_session_rebinds_aggregate
                  ON intent_session_rebinds(aggregate_id, created_at DESC);
                CREATE TRIGGER IF NOT EXISTS intent_session_rebinds_no_update
                  BEFORE UPDATE ON intent_session_rebinds
                  BEGIN SELECT RAISE(ABORT, 'intent session rebinds are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS intent_session_rebinds_no_delete
                  BEFORE DELETE ON intent_session_rebinds
                  BEGIN SELECT RAISE(ABORT, 'intent session rebinds are immutable'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (15, _utc_now())
            )
        if 16 not in applied:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS task_session_rebinds (
                  rebind_id TEXT PRIMARY KEY,
                  command_id TEXT NOT NULL UNIQUE,
                  aggregate_id TEXT NOT NULL,
                  task_id TEXT NOT NULL,
                  task_instance_id TEXT NOT NULL,
                  workspace_key TEXT NOT NULL,
                  previous_owner_session_key TEXT NOT NULL,
                  new_owner_session_key TEXT NOT NULL,
                  package_version TEXT NOT NULL,
                  task_revision INTEGER NOT NULL,
                  task_state_hash TEXT NOT NULL,
                  contract_revision INTEGER NOT NULL,
                  plan_fingerprint TEXT NOT NULL,
                  payload_hash TEXT NOT NULL,
                  source TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  FOREIGN KEY (aggregate_id) REFERENCES task_aggregates(aggregate_id),
                  FOREIGN KEY (aggregate_id, task_revision) REFERENCES task_state_revisions(aggregate_id, task_revision),
                  FOREIGN KEY (command_id) REFERENCES command_log(command_id)
                );
                CREATE INDEX IF NOT EXISTS idx_task_session_rebinds_aggregate
                  ON task_session_rebinds(aggregate_id, created_at DESC);
                CREATE TRIGGER IF NOT EXISTS task_session_rebinds_no_update
                  BEFORE UPDATE ON task_session_rebinds
                  BEGIN SELECT RAISE(ABORT, 'task session rebinds are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS task_session_rebinds_no_delete
                  BEFORE DELETE ON task_session_rebinds
                  BEGIN SELECT RAISE(ABORT, 'task session rebinds are immutable'); END;
                """
            )
            connection.execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)", (16, _utc_now())
            )

    @staticmethod
    def _write_card_search_row(
        connection: sqlite3.Connection,
        card_id: str,
        revision: int,
        title: str,
        payload: Mapping[str, Any],
        lifecycle: str,
    ) -> None:
        connection.execute("DELETE FROM card_search WHERE card_id=?", (card_id,))
        if lifecycle == "forgotten":
            return
        connection.execute(
            "INSERT INTO card_search(card_id,revision,title,search_text) VALUES (?,?,?,?)",
            (card_id, revision, title, _card_search_text(title, payload)),
        )

    def _rebuild_card_search_in_transaction(self, connection: sqlite3.Connection) -> None:
        connection.execute("DELETE FROM card_search")
        rows = connection.execute(
            """
            SELECT c.card_id,c.head_revision,c.lifecycle,r.title,r.structured_payload
            FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
            ORDER BY c.card_id
            """
        ).fetchall()
        for row in rows:
            try:
                payload = json.loads(str(row["structured_payload"]))
            except json.JSONDecodeError as exc:
                raise BrainControlError("BRAIN_CONTROL_CARD_CONTENT_CORRUPT", "card payload cannot be indexed") from exc
            if not isinstance(payload, Mapping):
                raise BrainControlError("BRAIN_CONTROL_CARD_CONTENT_CORRUPT", "card payload cannot be indexed")
            self._write_card_search_row(
                connection,
                str(row["card_id"]),
                int(row["head_revision"]),
                str(row["title"]),
                payload,
                str(row["lifecycle"]),
            )

    def status(self) -> dict[str, Any]:
        with self._connection() as connection:
            cards = int(connection.execute("SELECT COUNT(*) FROM cards").fetchone()[0])
            events = int(connection.execute("SELECT COUNT(*) FROM events").fetchone()[0])
            pending = int(connection.execute("SELECT COUNT(*) FROM outbox WHERE status='pending'").fetchone()[0])
            pending_delivery_events = int(
                connection.execute("SELECT COUNT(*) FROM outbox WHERE delivery_version=1 AND status='pending'").fetchone()[0]
            )
            intent_aggregates = int(connection.execute("SELECT COUNT(*) FROM intent_aggregates").fetchone()[0])
            intent_receipts = int(connection.execute("SELECT COUNT(*) FROM intent_receipts").fetchone()[0])
            task_aggregates = int(connection.execute("SELECT COUNT(*) FROM task_aggregates").fetchone()[0])
            task_revisions = int(connection.execute("SELECT COUNT(*) FROM task_state_revisions").fetchone()[0])
            decision_receipts = int(connection.execute("SELECT COUNT(*) FROM decision_resolution_receipts").fetchone()[0])
            decision_results = int(connection.execute("SELECT COUNT(*) FROM decision_completion_results").fetchone()[0])
            instruction_anchors = int(connection.execute("SELECT COUNT(*) FROM instruction_anchors").fetchone()[0])
            continuation_receipts = int(connection.execute("SELECT COUNT(*) FROM continuation_receipts").fetchone()[0])
            migration_epochs = int(connection.execute("SELECT COUNT(*) FROM migration_epochs").fetchone()[0])
            active_migration_epochs = int(
                connection.execute(
                    "SELECT COUNT(*) FROM migration_epochs WHERE status IN ('staged','imported','verified','cutover')"
                ).fetchone()[0]
            )
        return {
            "ok": True,
            "schema": "super-brain.brain-control-status.v1",
            "databasePath": str(self.db_path),
            "schemaVersion": SCHEMA_VERSION,
            "cards": cards,
            "events": events,
            "pendingOutbox": pending,
            "pendingDeliveryEvents": pending_delivery_events,
            "intentAggregates": intent_aggregates,
            "intentReceipts": intent_receipts,
            "taskAggregates": task_aggregates,
            "taskRevisions": task_revisions,
            "decisionResolutionReceipts": decision_receipts,
            "decisionCompletionResults": decision_results,
            "instructionAnchors": instruction_anchors,
            "continuationReceipts": continuation_receipts,
            "migrationEpochs": migration_epochs,
            "activeMigrationEpochs": active_migration_epochs,
        }

    def _legacy_migration(self) -> LegacyMigrationControl:
        return LegacyMigrationControl(self)

    @staticmethod
    def _migration_call(action: Callable[[], dict[str, Any]]) -> dict[str, Any]:
        try:
            return action()
        except MigrationControlError as exc:
            raise BrainControlError(exc.code, str(exc)) from exc

    def migration_plan(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().plan(request))

    def migration_stage(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().stage(request))

    def migration_import(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().import_epoch(request))

    def migration_verify(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().verify(request))

    def migration_cutover(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().cutover(request))

    def migration_rollback_adapter(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().rollback_adapter(request))

    def migration_status(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().status(request))

    def sandglass_migration_plan(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().sandglass_plan(request))

    def sandglass_migration_stage(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().sandglass_stage(request))

    def sandglass_migration_import(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().sandglass_import(request))

    def sandglass_migration_verify(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().sandglass_verify(request))

    def sandglass_migration_rollback(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().sandglass_rollback(request))

    def sandglass_migration_status(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return self._migration_call(lambda: self._legacy_migration().sandglass_status(request))

    @staticmethod
    def _instruction_anchor_from_row(row: sqlite3.Row) -> dict[str, Any]:
        def read_object(column: str) -> dict[str, Any]:
            try:
                value = json.loads(str(row[column]))
            except (KeyError, TypeError, json.JSONDecodeError):
                return {}
            return dict(value) if isinstance(value, Mapping) else {}

        return {
            "schema": INSTRUCTION_ANCHOR_SCHEMA,
            "anchorId": str(row["anchor_id"]),
            "globalSequence": int(row["global_sequence"]),
            "sequence": int(row["task_sequence"]),
            "taskId": str(row["task_id"]),
            "workspaceKey": str(row["workspace_key"]),
            "ownerSessionKey": str(row["owner_session_key"]),
            "instruction": str(row["instruction_text"]),
            "instructionHash": str(row["instruction_hash"]),
            "contentHash": str(row["content_hash"]),
            "classification": read_object("classification_json"),
            "signals": read_object("signals_json"),
            "source": str(row["source"]),
            "createdAt": str(row["created_at"]),
            "rawPromptStored": False,
        }

    @staticmethod
    def _normalize_instruction_anchor_classification(value: Any) -> dict[str, Any]:
        if not isinstance(value, Mapping):
            return {}

        def text(field: str, maximum: int) -> str:
            raw = value.get(field, "")
            if not isinstance(raw, str):
                return ""
            return _optional_string(raw, f"classification.{field}", maximum)

        def text_list(field: str, maximum_items: int, maximum_chars: int) -> list[str]:
            raw = value.get(field, [])
            if isinstance(raw, str) or not isinstance(raw, Sequence):
                return []
            result: list[str] = []
            for item in raw:
                if not isinstance(item, str):
                    continue
                item_text = _optional_string(item, f"classification.{field}", maximum_chars)
                if item_text and item_text not in result:
                    result.append(item_text)
                if len(result) >= maximum_items:
                    break
            return result

        normalized = {
            "mode": text("mode", 48),
            "topicAffinity": text("topicAffinity", 96),
            "targetLineId": text("targetLineId", 160),
            "targetLineLabel": text("targetLineLabel", 160),
            "confidence": text("confidence", 24),
            "matchedKeys": text_list("matchedKeys", 12, 96),
            "candidateLineIds": text_list("candidateLineIds", 8, 160),
            "recommendedInstructionMode": text("recommendedInstructionMode", 48),
            "reason": text("reason", 240),
            "needsClarification": bool(value.get("needsClarification", False)),
        }
        return {
            key: item
            for key, item in normalized.items()
            if key in {"matchedKeys", "candidateLineIds", "needsClarification"} or item not in ("", [])
        }

    @staticmethod
    def _normalize_instruction_anchor_signals(value: Any) -> dict[str, bool]:
        if not isinstance(value, Mapping):
            return {}
        return {
            key: bool(value.get(key, False))
            for key in ("deferredMergeRequested", "explicitReplacementRequested", "canonicalPlanSourceRequired")
            if bool(value.get(key, False))
        }

    @staticmethod
    def _instruction_anchor_scope(request: Mapping[str, Any], *, task_required: bool) -> tuple[str, str, str]:
        workspace_key = _require_string(request.get("workspaceKey"), "workspaceKey", 160)
        owner_session_key = _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 200)
        task_id = _optional_string(request.get("taskId"), "taskId", 200)
        if task_required and not task_id:
            raise BrainControlError("BRAIN_CONTROL_INSTRUCTION_ANCHOR_TASK_REQUIRED", "taskId is required")
        return workspace_key, owner_session_key, task_id

    @staticmethod
    def _instruction_anchor_bound(anchor: Mapping[str, Any], bound_anchor: Any) -> bool:
        if not isinstance(bound_anchor, Mapping):
            return False
        return (
            str(bound_anchor.get("anchorId", "")) == str(anchor.get("anchorId", ""))
            and str(bound_anchor.get("contentHash", "")) == str(anchor.get("contentHash", ""))
            and int(bound_anchor.get("globalSequence", -1)) == int(anchor.get("globalSequence", -2))
        )

    @staticmethod
    def _latest_instruction_anchor(
        connection: sqlite3.Connection,
        workspace_key: str,
        owner_session_key: str,
        task_id: str = "",
    ) -> sqlite3.Row | None:
        if task_id:
            return connection.execute(
                """
                SELECT * FROM instruction_anchors
                WHERE workspace_key=? AND owner_session_key=? AND task_id=?
                ORDER BY global_sequence DESC LIMIT 1
                """,
                (workspace_key, owner_session_key, task_id),
            ).fetchone()
        return connection.execute(
            """
            SELECT * FROM instruction_anchors
            WHERE workspace_key=? AND owner_session_key=?
            ORDER BY global_sequence DESC LIMIT 1
            """,
            (workspace_key, owner_session_key),
        ).fetchone()

    def observe_instruction_anchor(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Append one durable, redacted user-instruction anchor for an active task."""

        workspace_key, owner_session_key, task_id = self._instruction_anchor_scope(request, task_required=True)
        instruction = _redact_instruction_anchor(request.get("instruction"))
        source = _optional_string(request.get("source") or "instruction-anchor", "source", INSTRUCTION_ANCHOR_MAX_SOURCE_CHARS)
        classification = self._normalize_instruction_anchor_classification(request.get("classification"))
        signals = self._normalize_instruction_anchor_signals(request.get("signals"))
        preserve_if_pending = bool(request.get("preserveIfPending", False))
        bound_anchor = request.get("boundAnchor")

        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                existing_row = self._latest_instruction_anchor(connection, workspace_key, owner_session_key, task_id)
                existing = self._instruction_anchor_from_row(existing_row) if existing_row is not None else None
                if existing is not None and preserve_if_pending and not self._instruction_anchor_bound(existing, bound_anchor):
                    connection.commit()
                    return {
                        "ok": True,
                        "created": False,
                        "preservedPending": True,
                        "pending": True,
                        "anchor": existing,
                    }

                next_sequence = 1 if existing is None else int(existing["sequence"]) + 1
                anchor_id = "ia-" + uuid.uuid4().hex
                instruction_hash = hashlib.sha256(instruction.encode("utf-8")).hexdigest()
                content_hash = _sha256(
                    {
                        "schema": INSTRUCTION_ANCHOR_SCHEMA,
                        "anchorId": anchor_id,
                        "workspaceKey": workspace_key,
                        "ownerSessionKey": owner_session_key,
                        "taskId": task_id,
                        "sequence": next_sequence,
                        "instruction": instruction,
                        "instructionHash": instruction_hash,
                        "classification": classification,
                        "signals": signals,
                        "source": source,
                    }
                )
                connection.execute(
                    """
                    INSERT INTO instruction_anchors(
                      anchor_id,workspace_key,owner_session_key,task_id,task_sequence,
                      instruction_text,instruction_hash,content_hash,classification_json,
                      signals_json,source,created_at,raw_prompt_stored
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        anchor_id,
                        workspace_key,
                        owner_session_key,
                        task_id,
                        next_sequence,
                        instruction,
                        instruction_hash,
                        content_hash,
                        _canonical_json(classification),
                        _canonical_json(signals),
                        source,
                        _utc_now(),
                        0,
                    ),
                )
                row = connection.execute("SELECT * FROM instruction_anchors WHERE anchor_id=?", (anchor_id,)).fetchone()
                if row is None:
                    raise BrainControlError("BRAIN_CONTROL_INSTRUCTION_ANCHOR_WRITE_FAILED", "instruction anchor was not readable after insert")
                anchor = self._instruction_anchor_from_row(row)
                connection.commit()
            except BaseException:
                connection.rollback()
                raise
        return {
            "ok": True,
            "created": True,
            "preservedPending": False,
            "pending": not self._instruction_anchor_bound(anchor, bound_anchor),
            "anchor": anchor,
        }

    def get_instruction_anchor(self, request: Mapping[str, Any]) -> dict[str, Any]:
        workspace_key, owner_session_key, task_id = self._instruction_anchor_scope(request, task_required=False)
        with self._connection() as connection:
            row = self._latest_instruction_anchor(connection, workspace_key, owner_session_key, task_id)
        if row is None:
            return {
                "ok": True,
                "available": False,
                "status": "none",
                "anchor": None,
            }
        return {
            "ok": True,
            "available": True,
            "status": "current",
            "anchor": self._instruction_anchor_from_row(row),
        }

    def check_instruction_anchor(self, request: Mapping[str, Any]) -> dict[str, Any]:
        workspace_key, owner_session_key, task_id = self._instruction_anchor_scope(request, task_required=True)
        with self._connection() as connection:
            row = self._latest_instruction_anchor(connection, workspace_key, owner_session_key, task_id)
        if row is None:
            return {
                "ok": True,
                "required": False,
                "current": True,
                "code": "INSTRUCTION_ANCHOR_NONE",
                "anchor": None,
            }
        anchor = self._instruction_anchor_from_row(row)
        current = self._instruction_anchor_bound(anchor, request.get("boundAnchor"))
        return {
            "ok": True,
            "required": True,
            "current": current,
            "code": "INSTRUCTION_ANCHOR_CURRENT" if current else "INSTRUCTION_ANCHOR_RECONCILIATION_REQUIRED",
            "anchor": anchor,
        }

    @staticmethod
    def _continuation_text(value: Any, field: str, maximum: int) -> str:
        if value in (None, ""):
            return ""
        if not isinstance(value, str):
            raise BrainControlError("BRAIN_CONTROL_CONTINUATION_RECEIPT_INVALID", f"{field} must be text")
        text = re.sub(r"\s+", " ", value).strip()
        text = SENSITIVE_VALUE_RE.sub("[REDACTED]", text)
        text = re.sub(
            r"(?i)\b(api[_ -]?key|password|passwd|token|secret|credential|cookie)\s*[:=]\s*[^\s,;]+",
            r"\1=[REDACTED]",
            text,
        )
        return text[:maximum]

    @classmethod
    def _normalize_continuation_state(cls, value: Any) -> dict[str, Any]:
        if not isinstance(value, Mapping):
            raise BrainControlError("BRAIN_CONTROL_CONTINUATION_RECEIPT_INVALID", "state must be an object")

        def text_list(field: str, maximum_items: int, maximum_chars: int) -> list[str]:
            raw = value.get(field, [])
            if isinstance(raw, str) or not isinstance(raw, Sequence):
                return []
            result: list[str] = []
            for item in raw:
                item_text = cls._continuation_text(item, f"state.{field}", maximum_chars)
                if item_text and item_text not in result:
                    result.append(item_text)
                if len(result) >= maximum_items:
                    break
            return result

        return_point = value.get("returnPoint")
        if not isinstance(return_point, Mapping):
            return_point = {}
        canonical_plan = value.get("canonicalPlan")
        if not isinstance(canonical_plan, Mapping):
            canonical_plan = {}
        normalized = {
            "latestUserInstruction": cls._continuation_text(value.get("latestUserInstruction"), "state.latestUserInstruction", 320),
            "lastConfirmedSentence": cls._continuation_text(value.get("lastConfirmedSentence"), "state.lastConfirmedSentence", 320),
            "lastConfirmedSource": cls._continuation_text(value.get("lastConfirmedSource"), "state.lastConfirmedSource", 64),
            "mainLine": cls._continuation_text(value.get("mainLine"), "state.mainLine", 160),
            "activeLine": cls._continuation_text(value.get("activeLine"), "state.activeLine", 160),
            "currentPhase": cls._continuation_text(value.get("currentPhase"), "state.currentPhase", 120),
            "currentStep": cls._continuation_text(value.get("currentStep"), "state.currentStep", 240),
            "completedSteps": text_list("completedSteps", 16, 180),
            "pendingSteps": text_list("pendingSteps", 24, 180),
            "nextAction": cls._continuation_text(value.get("nextAction"), "state.nextAction", CONTINUATION_RECEIPT_MAX_TEXT),
            "evidence": text_list("evidence", 8, 180),
            "returnPoint": {
                "focusId": cls._continuation_text(return_point.get("focusId"), "state.returnPoint.focusId", 160),
                "focusLabel": cls._continuation_text(return_point.get("focusLabel"), "state.returnPoint.focusLabel", 160),
                "resumeFrom": cls._continuation_text(return_point.get("resumeFrom"), "state.returnPoint.resumeFrom", 80),
            },
            "canonicalPlan": {
                "planId": cls._continuation_text(canonical_plan.get("planId"), "state.canonicalPlan.planId", 160),
                "generation": int(canonical_plan.get("generation", 0)) if not isinstance(canonical_plan.get("generation", 0), bool) else 0,
                "fingerprint": cls._continuation_text(canonical_plan.get("fingerprint"), "state.canonicalPlan.fingerprint", 96),
                "completedCount": int(canonical_plan.get("completedCount", 0)) if not isinstance(canonical_plan.get("completedCount", 0), bool) else 0,
                "pendingCount": int(canonical_plan.get("pendingCount", 0)) if not isinstance(canonical_plan.get("pendingCount", 0), bool) else 0,
            },
            "completedHistoryIsCurrent": False,
        }
        if any(value < 0 for value in normalized["canonicalPlan"].values() if isinstance(value, int)):
            raise BrainControlError("BRAIN_CONTROL_CONTINUATION_RECEIPT_INVALID", "canonical plan counters cannot be negative")
        return normalized

    @staticmethod
    def _continuation_receipt_from_row(row: sqlite3.Row) -> dict[str, Any]:
        try:
            state = json.loads(str(row["state_json"]))
        except (TypeError, json.JSONDecodeError):
            state = {}
        return {
            "schema": CONTINUATION_RECEIPT_SCHEMA,
            "receiptId": str(row["receipt_id"]),
            "globalSequence": int(row["global_sequence"]),
            "taskId": str(row["task_id"]),
            "taskInstanceId": str(row["task_instance_id"]),
            "workspaceKey": str(row["workspace_key"]),
            "ownerSessionKey": str(row["owner_session_key"]),
            "packageVersion": str(row["package_version"]),
            "contractRevision": int(row["contract_revision"]),
            "planFingerprint": str(row["plan_fingerprint"]),
            "instructionAnchor": {
                "anchorId": str(row["instruction_anchor_id"]),
                "contentHash": str(row["instruction_anchor_hash"]),
            }
            if str(row["instruction_anchor_id"])
            else None,
            "state": state if isinstance(state, Mapping) else {},
            "stateHash": str(row["state_hash"]),
            "source": str(row["source"]),
            "createdAt": str(row["created_at"]),
        }

    @staticmethod
    def _continuation_receipt_binding_status(
        receipt: Mapping[str, Any] | None,
        latest_anchor: Mapping[str, Any] | None,
    ) -> dict[str, Any]:
        """Describe whether a progress receipt still belongs to the latest instruction.

        A receipt is the authoritative record of the assistant's latest verified
        progress.  It must remain visible after a newer user instruction arrives,
        but its old next action must not be reused until that newer instruction is
        reconciled.  Returning the relation here keeps that distinction out of
        individual restore callers.
        """

        if not isinstance(receipt, Mapping):
            return {
                "state": "no_receipt",
                "current": False,
                "code": "CONTINUATION_RECEIPT_NOT_AVAILABLE",
                "guard": "No assistant progress receipt is available for this scoped task.",
            }

        receipt_anchor = receipt.get("instructionAnchor")
        if not isinstance(receipt_anchor, Mapping) or not str(receipt_anchor.get("anchorId", "")):
            return {
                "state": "unbound_receipt",
                "current": False,
                "code": "CONTINUATION_RECEIPT_ANCHOR_UNBOUND",
                "guard": "The latest assistant progress is retained, but it is not bound to a durable user instruction anchor.",
            }

        if not isinstance(latest_anchor, Mapping):
            return {
                "state": "anchor_unavailable",
                "current": False,
                "code": "CONTINUATION_RECEIPT_ANCHOR_UNAVAILABLE",
                "guard": "The latest user instruction anchor is unavailable, so the recorded progress cannot authorize an action.",
            }

        receipt_id = str(receipt_anchor.get("anchorId", ""))
        receipt_hash = str(receipt_anchor.get("contentHash", ""))
        anchor_id = str(latest_anchor.get("anchorId", ""))
        anchor_hash = str(latest_anchor.get("contentHash", ""))
        if receipt_id == anchor_id and receipt_hash == anchor_hash:
            return {
                "state": "current",
                "current": True,
                "code": "CONTINUATION_RECEIPT_CURRENT",
                "guard": "The latest assistant progress receipt is bound to the current user instruction anchor.",
            }

        return {
            "state": "newer_instruction_pending",
            "current": False,
            "code": "CONTINUATION_RECEIPT_RECONCILIATION_REQUIRED",
            "guard": "A newer user instruction exists. Preserve the assistant progress receipt, but reconcile before reusing its old next action.",
        }

    def record_continuation_receipt(self, request: Mapping[str, Any]) -> dict[str, Any]:
        workspace_key, owner_session_key, task_id = self._instruction_anchor_scope(request, task_required=True)
        task_instance_id = _require_string(request.get("taskInstanceId"), "taskInstanceId", 80)
        package_version = _require_string(request.get("packageVersion"), "packageVersion", 64)
        raw_revision = request.get("contractRevision")
        if isinstance(raw_revision, bool) or not isinstance(raw_revision, int) or raw_revision < 1:
            raise BrainControlError("BRAIN_CONTROL_CONTINUATION_RECEIPT_INVALID", "contractRevision must be a positive integer")
        plan_fingerprint = _optional_string(request.get("planFingerprint"), "planFingerprint", 128)
        source = _optional_string(request.get("source") or "continuation-receipt", "source", INSTRUCTION_ANCHOR_MAX_SOURCE_CHARS)
        state = self._normalize_continuation_state(request.get("state"))
        raw_anchor = request.get("instructionAnchor")
        if raw_anchor is not None and not isinstance(raw_anchor, Mapping):
            raise BrainControlError("BRAIN_CONTROL_CONTINUATION_RECEIPT_INVALID", "instructionAnchor must be an object")
        anchor_id = _optional_string(raw_anchor.get("anchorId") if isinstance(raw_anchor, Mapping) else "", "instructionAnchor.anchorId", 80)
        anchor_hash = _optional_string(raw_anchor.get("contentHash") if isinstance(raw_anchor, Mapping) else "", "instructionAnchor.contentHash", 64).lower()
        if anchor_hash and not SHA256_RE.fullmatch(anchor_hash):
            raise BrainControlError("BRAIN_CONTROL_CONTINUATION_RECEIPT_INVALID", "instructionAnchor.contentHash must be a SHA-256 digest")
        state_hash = _sha256(state)
        with self._connection() as connection:
            existing = connection.execute(
                """
                SELECT * FROM continuation_receipts
                WHERE workspace_key=? AND owner_session_key=? AND task_id=?
                  AND contract_revision=? AND state_hash=?
                """,
                (workspace_key, owner_session_key, task_id, raw_revision, state_hash),
            ).fetchone()
            if existing is not None:
                return {"ok": True, "created": False, "receipt": self._continuation_receipt_from_row(existing)}
            receipt_id = "cr-" + uuid.uuid4().hex
            connection.execute(
                """
                INSERT INTO continuation_receipts(
                  receipt_id,workspace_key,owner_session_key,task_id,task_instance_id,
                  package_version,contract_revision,plan_fingerprint,instruction_anchor_id,
                  instruction_anchor_hash,state_hash,state_json,source,created_at
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    receipt_id,
                    workspace_key,
                    owner_session_key,
                    task_id,
                    task_instance_id,
                    package_version,
                    raw_revision,
                    plan_fingerprint,
                    anchor_id,
                    anchor_hash,
                    state_hash,
                    _canonical_json(state),
                    source,
                    _utc_now(),
                ),
            )
            row = connection.execute("SELECT * FROM continuation_receipts WHERE receipt_id=?", (receipt_id,)).fetchone()
        if row is None:
            raise BrainControlError("BRAIN_CONTROL_CONTINUATION_RECEIPT_WRITE_FAILED", "receipt was not readable after insert")
        return {"ok": True, "created": True, "receipt": self._continuation_receipt_from_row(row)}

    def get_continuation_receipt(self, request: Mapping[str, Any]) -> dict[str, Any]:
        workspace_key, owner_session_key, task_id = self._instruction_anchor_scope(request, task_required=False)
        with self._connection() as connection:
            if task_id:
                row = connection.execute(
                    """
                    SELECT * FROM continuation_receipts
                    WHERE workspace_key=? AND owner_session_key=? AND task_id=?
                    ORDER BY global_sequence DESC LIMIT 1
                    """,
                    (workspace_key, owner_session_key, task_id),
                ).fetchone()
            else:
                row = connection.execute(
                    """
                    SELECT * FROM continuation_receipts
                    WHERE workspace_key=? AND owner_session_key=?
                    ORDER BY global_sequence DESC LIMIT 1
                    """,
                    (workspace_key, owner_session_key),
                ).fetchone()
            anchor_row = self._latest_instruction_anchor(connection, workspace_key, owner_session_key, task_id)
        receipt = self._continuation_receipt_from_row(row) if row is not None else None
        latest_anchor = self._instruction_anchor_from_row(anchor_row) if anchor_row is not None else None
        binding = self._continuation_receipt_binding_status(receipt, latest_anchor)
        return {
            "ok": True,
            "available": row is not None,
            "status": "current" if row is not None else "none",
            "receipt": receipt,
            "latestInstructionAnchor": latest_anchor,
            "binding": binding,
        }

    def publish_mcp_snapshot(self, *, delivery_watermark: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """Publish an atomic, redacted status projection for the read-only MCP."""

        with self._connection() as connection:
            pending_delivery_events = int(
                connection.execute("SELECT COUNT(*) FROM outbox WHERE delivery_version=1 AND status='pending'").fetchone()[0]
            )
            if delivery_watermark is None and pending_delivery_events:
                raise BrainControlError(
                    "BRAIN_CONTROL_MCP_SNAPSHOT_OUTBOX_PENDING",
                    "pending durable deliveries must be materialized before publishing an MCP snapshot",
                )
            status = {
                "schemaVersion": SCHEMA_VERSION,
                "cards": int(connection.execute("SELECT COUNT(*) FROM cards").fetchone()[0]),
                "events": int(connection.execute("SELECT COUNT(*) FROM events").fetchone()[0]),
                "pendingOutbox": int(connection.execute("SELECT COUNT(*) FROM outbox WHERE status='pending'").fetchone()[0]),
                "pendingDeliveryEvents": pending_delivery_events,
                "intentAggregates": int(connection.execute("SELECT COUNT(*) FROM intent_aggregates").fetchone()[0]),
                "intentReceipts": int(connection.execute("SELECT COUNT(*) FROM intent_receipts").fetchone()[0]),
                "taskAggregates": int(connection.execute("SELECT COUNT(*) FROM task_aggregates").fetchone()[0]),
                "taskRevisions": int(connection.execute("SELECT COUNT(*) FROM task_state_revisions").fetchone()[0]),
                "decisionResolutionReceipts": int(connection.execute("SELECT COUNT(*) FROM decision_resolution_receipts").fetchone()[0]),
                "decisionCompletionResults": int(connection.execute("SELECT COUNT(*) FROM decision_completion_results").fetchone()[0]),
            }
            task_rows = connection.execute(
                """
                SELECT a.aggregate_id,a.task_id,a.task_instance_id,a.workspace_key,a.owner_session_key,
                  a.package_version,a.lifecycle,a.head_revision,a.head_state_hash,a.updated_at,r.state_json
                FROM task_aggregates a
                JOIN task_state_revisions r
                  ON r.aggregate_id=a.aggregate_id AND r.task_revision=a.head_revision
                ORDER BY a.aggregate_id
                LIMIT ?
                """,
                (MCP_TASK_REFERENCE_MAX_ITEMS,),
            ).fetchall()
            latest_event = connection.execute("SELECT COALESCE(MAX(sequence), 0) FROM events").fetchone()[0]
            active_projection_count = int(
                connection.execute(
                    "SELECT COUNT(*) FROM task_aggregates WHERE lifecycle IN (?,?,?,?)",
                    tuple(sorted(MCP_CURRENT_TASK_LIFECYCLES)),
                ).fetchone()[0]
            )
        task_projection_overflow = active_projection_count > MCP_TASK_PROJECTION_MAX_ITEMS
        task_projections: list[dict[str, Any]] = []
        for row in task_rows:
            if task_projection_overflow or str(row["lifecycle"]) not in MCP_CURRENT_TASK_LIFECYCLES:
                continue
            try:
                state = json.loads(str(row["state_json"]))
            except json.JSONDecodeError as exc:
                raise BrainControlError("BRAIN_CONTROL_TASK_STATE_CORRUPT", "task state cannot be projected") from exc
            if not isinstance(state, Mapping):
                raise BrainControlError("BRAIN_CONTROL_TASK_STATE_CORRUPT", "task state cannot be projected")
            scope_seed = {
                "taskId": str(row["task_id"]),
                "taskInstanceId": str(row["task_instance_id"]),
                "workspaceKey": str(row["workspace_key"]).lower(),
                "ownerSessionKey": str(row["owner_session_key"]).lower(),
                "packageVersion": str(row["package_version"]),
            }
            task_projections.append(
                {
                    "taskRef": _sha256({"taskId": scope_seed["taskId"]}),
                    "scopeRef": _sha256(scope_seed),
                    "hostScopeRef": mcp_host_scope_ref(scope_seed["workspaceKey"], scope_seed["ownerSessionKey"]),
                    "revision": int(row["head_revision"]),
                    "stateHash": str(row["head_state_hash"]),
                    "packageVersion": scope_seed["packageVersion"],
                    "lifecycle": str(row["lifecycle"]),
                    "contractRevision": max(0, int(state.get("contractRevision", 0) or 0)),
                    "planFingerprint": _mcp_projection_text(state.get("planFingerprint", ""), 128),
                    "lastConfirmedSentence": _mcp_projection_text(state.get("lastConfirmedSentence", ""), 280),
                    "lastConfirmedSource": _mcp_projection_text(state.get("lastConfirmedSource", ""), 80),
                    "currentPhase": _mcp_projection_text(state.get("currentPhase", ""), 180),
                    "currentStep": _mcp_projection_text(state.get("currentStep", ""), 260),
                    "nextAction": _mcp_projection_text(state.get("nextAction", ""), 360),
                    "completedSteps": _mcp_projection_list(state.get("completedSteps", [])),
                    "pendingSteps": _mcp_projection_list(state.get("pendingSteps", [])),
                    "blockers": _mcp_projection_list(state.get("blockers", [])),
                    "evidenceRefs": _mcp_projection_list(state.get("evidence", [])),
                    "verificationResults": _mcp_projection_list(state.get("verificationResults", [])),
                    "updatedAt": _mcp_projection_text(row["updated_at"], 48),
                    "actionAuthorization": "withheld",
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }
            )
        body = {
            "schema": MCP_SNAPSHOT_SCHEMA,
            "generatedAt": _utc_now(),
            "lastEventSequence": int(latest_event),
            "status": status,
            "taskProjectionRefs": [
                {
                    "aggregateRef": _sha256({"aggregateId": str(row["aggregate_id"])}),
                    "revision": int(row["head_revision"]),
                    "lifecycle": str(row["lifecycle"]),
                }
                for row in task_rows
            ],
            "taskProjections": task_projections,
            "taskProjectionOverflow": task_projection_overflow,
        }
        if delivery_watermark is not None:
            _ensure_safe(delivery_watermark, "deliveryWatermark")
            event_count = delivery_watermark.get("eventCount")
            event_set_hash = delivery_watermark.get("eventSetHash")
            if (
                isinstance(event_count, bool)
                or not isinstance(event_count, int)
                or event_count < 0
                or not isinstance(event_set_hash, str)
                or not SHA256_RE.fullmatch(event_set_hash)
            ):
                raise BrainControlError("BRAIN_CONTROL_DELIVERY_WATERMARK_INVALID", "delivery watermark is invalid")
            body["deliveryWatermark"] = {"eventCount": event_count, "eventSetHash": event_set_hash}
        snapshot = {**body, "payloadHash": _sha256(body)}
        destination = self.mcp_snapshot_path
        temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary.write_text(_canonical_json(snapshot), encoding="utf-8")
            os.replace(temporary, destination)
            if self.legacy_mcp_snapshot_path != destination:
                self._write_json_atomic(
                    self.legacy_mcp_snapshot_path,
                    snapshot,
                    "BRAIN_CONTROL_MCP_SNAPSHOT_COMPATIBILITY_WRITE_FAILED",
                )
        except OSError as exc:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            raise BrainControlError("BRAIN_CONTROL_MCP_SNAPSHOT_WRITE_FAILED", str(exc)) from exc
        legacy_verified = read_mcp_snapshot(self.legacy_mcp_snapshot_path)
        if not legacy_verified.get("ok") or legacy_verified.get("payloadHash") != snapshot["payloadHash"]:
            raise BrainControlError(
                "BRAIN_CONTROL_MCP_SNAPSHOT_COMPATIBILITY_VERIFY_FAILED",
                "legacy MCP snapshot mirror is unreadable",
            )
        return {
            "ok": True,
            "schema": MCP_SNAPSHOT_SCHEMA,
            "path": str(destination),
            "payloadHash": snapshot["payloadHash"],
            "lastEventSequence": body["lastEventSequence"],
            "taskProjectionCount": len(body["taskProjectionRefs"]),
        }

    @staticmethod
    def _write_json_atomic(destination: Path, value: Mapping[str, Any], code: str) -> None:
        temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary.write_text(_canonical_json(value), encoding="utf-8")
            os.replace(temporary, destination)
        except OSError as exc:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            raise BrainControlError(code, str(exc)) from exc

    @staticmethod
    def _delivery_targets(projection_kind: str, delivery_version: int) -> tuple[str, ...]:
        if delivery_version != 1:
            return ()
        targets = OUTBOX_DELIVERY_TARGETS.get(projection_kind)
        if targets is None:
            raise BrainControlError("BRAIN_CONTROL_OUTBOX_KIND_INVALID", f"unsupported outbox projection kind: {projection_kind}")
        return targets

    def _workspace_relative_path(self, value: Path) -> str:
        try:
            return value.resolve().relative_to(self.workspace.resolve()).as_posix()
        except ValueError as exc:
            raise BrainControlError("BRAIN_CONTROL_OUTBOX_ARTIFACT_SCOPE_INVALID", "delivery artifact must stay inside workspace") from exc

    def _current_card_projection(self) -> dict[str, Any]:
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
                  r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
                  r.state_json,r.created_at
                FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
                ORDER BY c.card_id
                """
            ).fetchall()
            latest_event = int(connection.execute("SELECT COALESCE(MAX(sequence), 0) FROM events").fetchone()[0])
        cards = []
        for row in rows:
            card = self._card_from_row(row)
            cards.append(
                {
                    "cardRef": _sha256({"cardId": card["cardId"]}),
                    "kind": card["kind"],
                    "scopeKind": card["scope"]["kind"],
                    "scopeRef": _sha256({"scopeKey": card["scope"]["key"]}),
                    "lifecycle": card["lifecycle"],
                    "authority": card["authority"],
                    "privacyClass": card["privacyClass"],
                    "revision": card["revision"],
                    "contentHash": card["contentHash"],
                    "redactedPayload": _redact_card_payload(card["kind"], card["payload"], card["privacyClass"]),
                }
            )
        body = {
            "schema": CARD_PROJECTION_SCHEMA,
            "generatedAt": _utc_now(),
            "lastEventSequence": latest_event,
            "cards": cards,
        }
        return {**body, "payloadHash": _sha256(body)}

    def publish_card_projection(self) -> dict[str, Any]:
        projection = self._current_card_projection()
        self._write_json_atomic(
            self.card_projection_path,
            projection,
            "BRAIN_CONTROL_CARD_PROJECTION_WRITE_FAILED",
        )
        verified = read_card_projection(self.card_projection_path)
        if not verified.get("ok") or verified.get("payloadHash") != projection["payloadHash"]:
            raise BrainControlError("BRAIN_CONTROL_CARD_PROJECTION_VERIFY_FAILED", "card projection verification failed")
        return {
            "ok": True,
            "schema": CARD_PROJECTION_SCHEMA,
            "path": str(self.card_projection_path),
            "payloadHash": projection["payloadHash"],
            "cardCount": len(projection["cards"]),
            "lastEventSequence": projection["lastEventSequence"],
        }

    def _record_outbox_delivery(
        self,
        connection: sqlite3.Connection,
        event: sqlite3.Row,
        target: str,
        artifact_path: Path,
        artifact_hash: str,
        receipt: Mapping[str, Any],
    ) -> dict[str, Any]:
        event_id = str(event["event_id"])
        expected_targets = self._delivery_targets(str(event["projection_kind"]), int(event["delivery_version"]))
        if target not in expected_targets:
            raise BrainControlError("BRAIN_CONTROL_OUTBOX_DELIVERY_TARGET_INVALID", f"target {target} is not valid for this event")
        if not SHA256_RE.fullmatch(artifact_hash):
            raise BrainControlError("BRAIN_CONTROL_OUTBOX_ARTIFACT_HASH_INVALID", "artifact hash is invalid")
        _ensure_safe(receipt, "outboxDeliveryReceipt")
        relative_path = self._workspace_relative_path(artifact_path)
        receipt_body = {
            "schema": OUTBOX_DELIVERY_SCHEMA,
            "eventId": event_id,
            "target": target,
            "artifactPath": relative_path,
            "artifactHash": artifact_hash,
            "receipt": json.loads(_canonical_json(dict(receipt))),
        }
        receipt_hash = _sha256(receipt_body)
        existing = connection.execute(
            "SELECT artifact_hash,receipt_hash FROM outbox_deliveries WHERE event_id=? AND target=?",
            (event_id, target),
        ).fetchone()
        if existing is not None:
            if str(existing["artifact_hash"]) != artifact_hash or str(existing["receipt_hash"]) != receipt_hash:
                raise BrainControlError("BRAIN_CONTROL_OUTBOX_DELIVERY_CONFLICT", "delivery receipt conflicts with an immutable prior receipt")
            idempotent = True
        else:
            connection.execute(
                "INSERT INTO outbox_deliveries(event_id,target,artifact_path,artifact_hash,receipt_hash,receipt_json,created_at) VALUES (?,?,?,?,?,?,?)",
                (event_id, target, relative_path, artifact_hash, receipt_hash, _canonical_json(receipt_body), _utc_now()),
            )
            idempotent = False
        delivered = {
            str(row["target"])
            for row in connection.execute("SELECT target FROM outbox_deliveries WHERE event_id=?", (event_id,)).fetchall()
        }
        complete = set(expected_targets).issubset(delivered)
        connection.execute(
            "UPDATE outbox SET status=?, materialized_at=? WHERE event_id=?",
            ("materialized" if complete else "pending", _utc_now() if complete else "", event_id),
        )
        return {
            "eventId": event_id,
            "target": target,
            "idempotent": idempotent,
            "complete": complete,
            "deliveryCount": len(delivered),
            "requiredDeliveryCount": len(expected_targets),
        }

    def _pending_delivery_events(
        self,
        target: str,
        *,
        projection_kind: str | None = None,
        maximum: int = 64,
    ) -> list[sqlite3.Row]:
        query = (
            "SELECT o.* FROM outbox o LEFT JOIN outbox_deliveries d "
            "ON d.event_id=o.event_id AND d.target=? "
            "WHERE o.delivery_version=1 AND o.status='pending' AND d.event_id IS NULL"
        )
        parameters: list[Any] = [target]
        if target == "mcp_snapshot":
            # A task/card snapshot may not get ahead of its compatibility projection.
            # The import-only task snapshot has no compatibility artifact by design.
            query += (
                " AND (o.projection_kind='task_state_snapshot' OR EXISTS ("
                "SELECT 1 FROM outbox_deliveries prerequisite "
                "WHERE prerequisite.event_id=o.event_id AND prerequisite.target='compatibility_projection'"
                "))"
            )
        if projection_kind is not None:
            query += " AND o.projection_kind=?"
            parameters.append(projection_kind)
        query += " ORDER BY o.created_at,o.event_id LIMIT ?"
        parameters.append(max(1, min(int(maximum), 128)))
        with self._connection() as connection:
            return list(connection.execute(query, parameters).fetchall())

    def _blocked_mcp_delivery_count(self) -> int:
        """Count events whose MCP receipt must wait for a compatibility artifact."""

        with self._connection() as connection:
            return int(
                connection.execute(
                    """
                    SELECT COUNT(*) FROM outbox o
                    WHERE o.delivery_version=1
                      AND o.status='pending'
                      AND o.projection_kind IN ('card_projection','task_projection')
                      AND NOT EXISTS (
                        SELECT 1 FROM outbox_deliveries prerequisite
                        WHERE prerequisite.event_id=o.event_id
                          AND prerequisite.target='compatibility_projection'
                      )
                    """
                ).fetchone()[0]
            )

    def record_task_compatibility_delivery(self, request: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_DELIVERY_INVALID", "task delivery request must be an object")
        _ensure_safe(request, "taskDelivery")
        event_id = _require_string(request.get("eventId"), "eventId", 96)
        task_id = _require_string(request.get("taskId"), "taskId", 160)
        workspace_key = _require_string(request.get("workspaceKey"), "workspaceKey", 120)
        revision = request.get("revision")
        if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
            raise BrainControlError("BRAIN_CONTROL_TASK_DELIVERY_REVISION_INVALID", "task delivery revision is invalid")
        raw_path = _require_string(request.get("projectionPath"), "projectionPath", 1024)
        supplied_hash = _require_string(request.get("projectionHash"), "projectionHash", 64).lower()
        if not SHA256_RE.fullmatch(supplied_hash):
            raise BrainControlError("BRAIN_CONTROL_TASK_DELIVERY_HASH_INVALID", "task projection hash is invalid")
        artifact_path = Path(raw_path).expanduser().resolve()
        if not artifact_path.is_file():
            raise BrainControlError("BRAIN_CONTROL_TASK_DELIVERY_ARTIFACT_MISSING", "task projection artifact is missing")
        artifact_bytes = artifact_path.read_bytes()
        actual_hash = _sha256_bytes(artifact_bytes)
        if actual_hash != supplied_hash:
            raise BrainControlError("BRAIN_CONTROL_TASK_DELIVERY_ARTIFACT_CHANGED", "task projection artifact hash changed")
        try:
            artifact = json.loads(artifact_bytes.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BrainControlError(
                "BRAIN_CONTROL_TASK_DELIVERY_ARTIFACT_INVALID",
                "task projection artifact must be UTF-8 JSON",
            ) from exc
        if (
            not isinstance(artifact, Mapping)
            or str(artifact.get("taskId", "")) != task_id
            or isinstance(artifact.get("revision"), bool)
            or not isinstance(artifact.get("revision"), int)
            or int(artifact["revision"]) != revision
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_TASK_DELIVERY_ARTIFACT_SCOPE_MISMATCH",
                "task projection artifact does not match the delivered task revision",
            )
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                event = connection.execute("SELECT * FROM outbox WHERE event_id=?", (event_id,)).fetchone()
                if event is None or str(event["projection_kind"]) != "task_projection" or int(event["delivery_version"]) != 1:
                    raise BrainControlError("BRAIN_CONTROL_TASK_DELIVERY_EVENT_INVALID", "task delivery event is not eligible")
                payload = json.loads(str(event["payload_json"]))
                if (
                    str(payload.get("taskId", "")) != task_id
                    or str(payload.get("workspaceKey", "")) != workspace_key
                    or int(payload.get("revision", -1)) != revision
                ):
                    raise BrainControlError("BRAIN_CONTROL_TASK_DELIVERY_BINDING_MISMATCH", "task delivery does not match the authoritative outbox event")
                result = self._record_outbox_delivery(
                    connection,
                    event,
                    "compatibility_projection",
                    artifact_path,
                    actual_hash,
                    {
                        "taskId": task_id,
                        "workspaceKey": workspace_key,
                        "revision": revision,
                        "source": _bounded_text(request.get("source", "task-state-store"), "source", 160),
                    },
                )
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return {"ok": True, "schema": OUTBOX_DELIVERY_SCHEMA, **result}

    def materialize_outbox(self, maximum: int = 64) -> dict[str, Any]:
        if isinstance(maximum, bool) or not isinstance(maximum, int) or maximum < 1 or maximum > 128:
            raise BrainControlError("BRAIN_CONTROL_OUTBOX_BATCH_INVALID", "outbox batch size must be between 1 and 128")
        compatibility_events = self._pending_delivery_events(
            "compatibility_projection",
            projection_kind="card_projection",
            maximum=maximum,
        )
        compatibility_results: list[dict[str, Any]] = []
        card_projection: dict[str, Any] | None = None
        if compatibility_events:
            card_projection = self.publish_card_projection()
            artifact_path = Path(str(card_projection["path"])).resolve()
            artifact_hash = str(card_projection["payloadHash"])
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    for pending in compatibility_events:
                        event = connection.execute("SELECT * FROM outbox WHERE event_id=?", (str(pending["event_id"]),)).fetchone()
                        if event is None:
                            continue
                        compatibility_results.append(
                            self._record_outbox_delivery(
                                connection,
                                event,
                                "compatibility_projection",
                                artifact_path,
                                artifact_hash,
                                {
                                    "projectionSchema": CARD_PROJECTION_SCHEMA,
                                    "projectionHash": artifact_hash,
                                    "eventSetHash": _sha256(sorted(str(item["event_id"]) for item in compatibility_events)),
                                },
                            )
                        )
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
        blocked_mcp_delivery_events = self._blocked_mcp_delivery_count()
        snapshot_events = (
            []
            if blocked_mcp_delivery_events
            else self._pending_delivery_events("mcp_snapshot", maximum=maximum)
        )
        snapshot_results: list[dict[str, Any]] = []
        mcp_snapshot: dict[str, Any] | None = None
        if snapshot_events:
            event_ids = [str(item["event_id"]) for item in snapshot_events]
            watermark = {"eventCount": len(event_ids), "eventSetHash": _sha256(sorted(event_ids))}
            mcp_snapshot = self.publish_mcp_snapshot(delivery_watermark=watermark)
            artifact_path = Path(str(mcp_snapshot["path"])).resolve()
            artifact_hash = str(mcp_snapshot["payloadHash"])
            verified = read_mcp_snapshot(artifact_path)
            if not verified.get("ok") or verified.get("payloadHash") != artifact_hash:
                raise BrainControlError("BRAIN_CONTROL_MCP_SNAPSHOT_VERIFY_FAILED", "MCP snapshot verification failed")
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    for pending in snapshot_events:
                        event = connection.execute("SELECT * FROM outbox WHERE event_id=?", (str(pending["event_id"]),)).fetchone()
                        if event is None:
                            continue
                        snapshot_results.append(
                            self._record_outbox_delivery(
                                connection,
                                event,
                                "mcp_snapshot",
                                artifact_path,
                                artifact_hash,
                                {"watermark": watermark, "snapshotHash": artifact_hash},
                            )
                        )
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
        return {
            "ok": True,
            "schema": "super-brain.outbox-materialization.v1",
            "cardProjection": card_projection,
            "mcpSnapshot": mcp_snapshot,
            "compatibilityDeliveries": compatibility_results,
            "snapshotDeliveries": snapshot_results,
            "materializedEventCount": len({item["eventId"] for item in [*compatibility_results, *snapshot_results] if item.get("complete")}),
            "blockedMcpDeliveryEvents": blocked_mcp_delivery_events,
            "pendingOutbox": self.status()["pendingOutbox"],
        }

    def _native_decision_index_entries(self, connection: sqlite3.Connection) -> dict[tuple[str, str], list[dict[str, Any]]]:
        rows = connection.execute(
            """
            SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
              r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
              r.state_json,r.created_at
            FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
            WHERE c.kind='decision' AND c.scope_kind='workspace' AND c.lifecycle='active'
            ORDER BY c.scope_key,c.card_id
            """
        ).fetchall()
        shards: dict[tuple[str, str], list[dict[str, Any]]] = {}
        for row in rows:
            card = self._card_from_row(row)
            if _sha256(self._card_content(card)) != card["contentHash"]:
                raise BrainControlError("BRAIN_CONTROL_NATIVE_DECISION_INDEX_CARD_INVALID", "decision card content hash is invalid")
            payload = _normalize_decision_payload(card["payload"])
            if payload.get("schema") != "super-brain.card.decision.v2":
                continue
            if payload["enforcement"] == "completion_gate" and card["authority"] != "user_confirmed":
                raise BrainControlError("BRAIN_CONTROL_NATIVE_DECISION_INDEX_AUTHORITY_INVALID", "completion gate is not user confirmed")
            entry = {
                "cardId": card["cardId"],
                "cardRevision": card["revision"],
                "contentHash": card["contentHash"],
                "enforcement": payload["enforcement"],
                "completionCriteriaDigest": _sha256(payload["completionCriteria"]),
                "applicability": payload["applicability"],
            }
            for stage_kind in payload["stageKinds"]:
                shards.setdefault((str(card["scope"]["key"]), stage_kind), []).append(dict(entry))
        for entries in shards.values():
            entries.sort(key=lambda item: (str(item["cardId"]), int(item["cardRevision"])))
        return shards

    def publish_native_decision_index(self) -> dict[str, Any]:
        package_identity = self._package_identity()
        with self._connection() as connection:
            shards = self._native_decision_index_entries(connection)
        manifest_entries: list[dict[str, Any]] = []
        for (workspace_key, stage_kind), entries in sorted(shards.items()):
            source_digest = _sha256(entries)
            shard_body = {
                "schema": NATIVE_DECISION_INDEX_SHARD_SCHEMA,
                "packageVersion": package_identity["packageVersion"],
                "packageManifestHash": package_identity["packageManifestHash"],
                "workspaceKey": workspace_key,
                "stageKind": stage_kind,
                "sourceDigest": source_digest,
                "entries": entries,
                "rawDecisionBodyStored": False,
                "rawPromptStored": False,
            }
            shard = {**shard_body, "payloadHash": _sha256(shard_body)}
            encoded = _canonical_json(shard).encode("utf-8")
            if len(encoded) > NATIVE_DECISION_INDEX_MAX_BYTES:
                raise BrainControlError("BRAIN_CONTROL_NATIVE_DECISION_INDEX_TOO_LARGE", "native decision index shard exceeds its bounded size")
            filename = _sha256({"workspaceKey": workspace_key, "stageKind": stage_kind})[:40] + ".json"
            self._write_json_atomic(self.native_decision_index_root / "shards" / filename, shard, "BRAIN_CONTROL_NATIVE_DECISION_INDEX_WRITE_FAILED")
            manifest_entries.append(
                {
                    "workspaceKey": workspace_key,
                    "stageKind": stage_kind,
                    "path": "shards/" + filename,
                    "entryCount": len(entries),
                    "sourceDigest": source_digest,
                    "payloadHash": shard["payloadHash"],
                }
            )
        manifest_body = {
            "schema": NATIVE_DECISION_INDEX_MANIFEST_SCHEMA,
            "packageVersion": package_identity["packageVersion"],
            "packageManifestHash": package_identity["packageManifestHash"],
            "sourceDigest": _sha256(manifest_entries),
            "shards": manifest_entries,
            "rawDecisionBodyStored": False,
            "rawPromptStored": False,
        }
        manifest = {**manifest_body, "payloadHash": _sha256(manifest_body)}
        self._write_json_atomic(self.native_decision_index_manifest_path, manifest, "BRAIN_CONTROL_NATIVE_DECISION_INDEX_WRITE_FAILED")
        return {
            "ok": True,
            "schema": NATIVE_DECISION_INDEX_MANIFEST_SCHEMA,
            "manifestPath": str(self.native_decision_index_manifest_path),
            "payloadHash": manifest["payloadHash"],
            "shardCount": len(manifest_entries),
            "decisionCount": sum(int(entry["entryCount"]) for entry in manifest_entries),
        }

    @staticmethod
    def _intent_aggregate_id(task_id: str, task_instance_id: str, workspace_key: str) -> str:
        return "intent-" + _sha256(
            {"taskId": task_id, "taskInstanceId": task_instance_id, "workspaceKey": workspace_key}
        )

    @staticmethod
    def _task_aggregate_id(task_id: str, workspace_key: str) -> str:
        return "task-" + _sha256({"taskId": task_id, "workspaceKey": workspace_key})

    @staticmethod
    def _normalize_intent_resolution_request(request: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_INTENT_REQUEST_INVALID", "intent request must be an object")
        _ensure_safe(request, "intentRequest")
        expected_revision = request.get("expectedIntentRevision")
        contract_revision = request.get("contractRevision")
        if not isinstance(expected_revision, int) or expected_revision < 0:
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_EXPECTED_REVISION_INVALID",
                "expectedIntentRevision must be a non-negative integer",
            )
        if not isinstance(contract_revision, int) or contract_revision < 1:
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_CONTRACT_REVISION_INVALID",
                "contractRevision must be a positive integer",
            )
        contract = request.get("intentContract")
        if not isinstance(contract, Mapping):
            raise BrainControlError("BRAIN_CONTROL_INTENT_INVALID", "intentContract must be an object")
        return {
            "commandId": _require_string(request.get("commandId"), "commandId", 160),
            "expectedIntentRevision": expected_revision,
            "taskId": _require_string(request.get("taskId"), "taskId", 160),
            "taskInstanceId": _require_string(request.get("taskInstanceId"), "taskInstanceId", 80),
            "workspaceKey": _require_string(request.get("workspaceKey"), "workspaceKey", 120),
            "ownerSessionKey": _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 120),
            "packageVersion": _require_string(request.get("packageVersion"), "packageVersion", 48),
            "contractRevision": contract_revision,
            "planFingerprint": _require_string(request.get("planFingerprint"), "planFingerprint", 64),
            "latestInstructionHash": _require_sha256(request.get("latestInstructionHash"), "latestInstructionHash"),
            "intentContract": _normalize_intent_contract(contract),
            "source": _require_string(request.get("source", "brain_control.resolve_intent"), "source", 160),
        }

    @staticmethod
    def _normalize_intent_session_rebind_request(request: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_INTENT_REBIND_REQUEST_INVALID", "intent rebind request must be an object")
        _ensure_safe(request, "intentSessionRebind")
        expected_revision = request.get("expectedIntentRevision")
        if not isinstance(expected_revision, int) or expected_revision < 1:
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_EXPECTED_REVISION_INVALID",
                "expectedIntentRevision must be a positive integer for session rebind",
            )
        return {
            "commandId": _require_string(request.get("commandId"), "commandId", 160),
            "taskId": _require_string(request.get("taskId"), "taskId", 160),
            "taskInstanceId": _require_string(request.get("taskInstanceId"), "taskInstanceId", 80),
            "workspaceKey": _require_string(request.get("workspaceKey"), "workspaceKey", 120),
            "previousOwnerSessionKey": _require_string(request.get("previousOwnerSessionKey"), "previousOwnerSessionKey", 120),
            "newOwnerSessionKey": _require_string(request.get("newOwnerSessionKey"), "newOwnerSessionKey", 120),
            "expectedIntentRevision": expected_revision,
            "latestReceiptId": _require_string(request.get("latestReceiptId"), "latestReceiptId", 80),
            "latestReceiptPayloadHash": _require_sha256(request.get("latestReceiptPayloadHash"), "latestReceiptPayloadHash"),
            "source": _require_string(request.get("source", "brain_control.rebind_intent"), "source", 160),
        }

    @staticmethod
    def _normalize_task_session_rebind_request(request: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_REQUEST_INVALID", "task rebind request must be an object")
        _ensure_safe(request, "taskSessionRebindRequest")
        expected_task_revision = request.get("expectedTaskRevision")
        expected_contract_revision = request.get("expectedContractRevision")
        if not isinstance(expected_task_revision, int) or expected_task_revision < 0:
            raise BrainControlError(
                "BRAIN_CONTROL_TASK_SESSION_REBIND_REVISION_INVALID",
                "expectedTaskRevision must be a non-negative integer",
            )
        if not isinstance(expected_contract_revision, int) or expected_contract_revision < 1:
            raise BrainControlError(
                "BRAIN_CONTROL_TASK_SESSION_REBIND_CONTRACT_REVISION_INVALID",
                "expectedContractRevision must be a positive integer",
            )
        previous_owner = _require_string(request.get("previousOwnerSessionKey"), "previousOwnerSessionKey", 120)
        new_owner = _require_string(request.get("newOwnerSessionKey"), "newOwnerSessionKey", 120)
        if previous_owner == new_owner:
            raise BrainControlError(
                "BRAIN_CONTROL_TASK_SESSION_REBIND_OWNER_UNCHANGED",
                "task session rebind requires a different new owner",
            )
        return {
            "commandId": _require_string(request.get("commandId"), "commandId", 160),
            "taskId": _require_string(request.get("taskId"), "taskId", 160),
            "taskInstanceId": _require_string(request.get("taskInstanceId"), "taskInstanceId", 80),
            "workspaceKey": _require_string(request.get("workspaceKey"), "workspaceKey", 120),
            "previousOwnerSessionKey": previous_owner,
            "newOwnerSessionKey": new_owner,
            "packageVersion": _require_string(request.get("packageVersion"), "packageVersion", 48),
            "expectedTaskRevision": expected_task_revision,
            "expectedContractRevision": expected_contract_revision,
            "expectedPlanFingerprint": _require_string(request.get("expectedPlanFingerprint"), "expectedPlanFingerprint", 64),
            "source": _require_string(request.get("source", "brain_control.issue_task_session_rebind"), "source", 160),
        }

    @staticmethod
    def _intent_receipt_payload(request: Mapping[str, Any], intent_revision: int, contract_fingerprint: str) -> dict[str, Any]:
        return {
            "schema": INTENT_RECEIPT_SCHEMA,
            "taskId": request["taskId"],
            "taskInstanceId": request["taskInstanceId"],
            "workspaceKey": request["workspaceKey"],
            "ownerSessionKey": request["ownerSessionKey"],
            "packageVersion": request["packageVersion"],
            "contractRevision": request["contractRevision"],
            "intentRevision": intent_revision,
            "planFingerprint": request["planFingerprint"],
            "latestInstructionHash": request["latestInstructionHash"],
            "intentContractFingerprint": contract_fingerprint,
            "ready": not bool(request["intentContract"]["materialUnknowns"]),
            "rawTranscriptStored": False,
        }

    def _begin_intent_context_projection_pending(
        self,
        *,
        task_id: str,
        task_instance_id: str,
        workspace_key: str,
        mutation_id: str,
    ) -> Path:
        """Make an uncommitted/unfinished intent mutation unreadable to context."""

        aggregate_ref = intent_context_aggregate_ref(
            task_id=task_id,
            task_instance_id=task_instance_id,
            workspace_key=workspace_key,
        )
        mutation_ref = _sha256({"mutationId": mutation_id})
        body = {
            "schema": INTENT_CONTEXT_PENDING_SCHEMA,
            "aggregateRef": aggregate_ref,
            "mutationRef": mutation_ref,
            "createdAt": _utc_now(),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        marker = intent_context_pending_marker_path(
            self.state_root,
            task_id=task_id,
            task_instance_id=task_instance_id,
            workspace_key=workspace_key,
            mutation_id=mutation_id,
        )
        self._write_json_atomic(
            marker,
            {**body, "payloadHash": _sha256(body)},
            "BRAIN_CONTROL_INTENT_CONTEXT_PENDING_WRITE_FAILED",
        )
        return marker

    @staticmethod
    def _remove_intent_context_marker(marker: Path) -> None:
        try:
            marker.unlink(missing_ok=True)
        except FileNotFoundError:
            return
        except OSError as exc:
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_CONTEXT_PENDING_CLEAR_FAILED",
                "intent context pending marker cannot be cleared",
            ) from exc
        try:
            marker.parent.rmdir()
        except OSError:
            # Other pending mutations must remain visible to the reader.
            pass

    def _finalize_intent_context_projection(
        self,
        connection: sqlite3.Connection,
        result: Mapping[str, Any],
        marker: Path,
    ) -> None:
        """Clear safe pending markers while serializing against the next writer."""

        receipt = result.get("intentResolutionReceipt")
        if not isinstance(receipt, Mapping):
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_CONTEXT_PROJECTION_INVALID",
                "intent result has no receipt to finalize",
            )
        aggregate_id = _require_string(result.get("aggregateId"), "intentResult.aggregateId", 128)
        receipt_id = _require_string(receipt.get("receiptId"), "intentReceipt.receiptId", 80)
        connection.execute("BEGIN IMMEDIATE")
        try:
            row = connection.execute(
                "SELECT latest_receipt_id FROM intent_aggregates WHERE aggregate_id=?",
                (aggregate_id,),
            ).fetchone()
            current_head = row is not None and str(row["latest_receipt_id"]) == receipt_id
            if current_head:
                pending_root = intent_context_pending_root(
                    self.state_root,
                    task_id=str(receipt["taskId"]),
                    task_instance_id=str(receipt["taskInstanceId"]),
                    workspace_key=str(receipt["workspaceKey"]),
                )
                for candidate in pending_root.glob("*.json"):
                    if candidate.is_file():
                        candidate.unlink()
                try:
                    pending_root.rmdir()
                except FileNotFoundError:
                    pass
                except OSError:
                    # Another unexpected file means the conservative reader
                    # will remain blocked; do not remove it by guess.
                    pass
            else:
                self._remove_intent_context_marker(marker)
            connection.execute("COMMIT")
        except Exception:
            try:
                connection.execute("ROLLBACK")
            except sqlite3.Error:
                pass
            raise

    def _publish_intent_context_projection(
        self,
        result: Mapping[str, Any],
        *,
        pending_marker: Path,
        connection: sqlite3.Connection,
    ) -> dict[str, Any]:
        """Publish the redacted proof consumed by the pure context reader.

        The authority transaction has already committed when this runs.  A
        failed projection is therefore retriable through the idempotent intent
        command, while the reader remains entirely outside SQLite/WAL.
        """

        receipt = result.get("intentResolutionReceipt")
        if not isinstance(receipt, Mapping):
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_CONTEXT_PROJECTION_INVALID",
                "intent result has no receipt to project",
            )
        try:
            task_id = _require_string(receipt.get("taskId"), "intentReceipt.taskId", 160)
            task_instance_id = _require_string(receipt.get("taskInstanceId"), "intentReceipt.taskInstanceId", 80)
            workspace_key = _require_string(receipt.get("workspaceKey"), "intentReceipt.workspaceKey", 120)
            owner_session_key = _require_string(receipt.get("ownerSessionKey"), "intentReceipt.ownerSessionKey", 120)
            package_version = _require_string(receipt.get("packageVersion"), "intentReceipt.packageVersion", 48)
            plan_fingerprint = _require_string(receipt.get("planFingerprint"), "intentReceipt.planFingerprint", 64)
            latest_instruction_hash = _require_sha256(receipt.get("latestInstructionHash"), "intentReceipt.latestInstructionHash")
            intent_contract_fingerprint = _require_sha256(receipt.get("intentContractFingerprint"), "intentReceipt.intentContractFingerprint")
            receipt_id = _require_string(receipt.get("receiptId"), "intentReceipt.receiptId", 80)
            receipt_payload_hash = _require_sha256(receipt.get("payloadHash"), "intentReceipt.payloadHash")
            generated_at = _require_string(receipt.get("capturedAt"), "intentReceipt.capturedAt", 64)
            contract_revision = receipt.get("contractRevision")
            intent_revision = receipt.get("intentRevision")
            if (
                isinstance(contract_revision, bool)
                or not isinstance(contract_revision, int)
                or contract_revision < 1
                or isinstance(intent_revision, bool)
                or not isinstance(intent_revision, int)
                or intent_revision < 1
                or not isinstance(receipt.get("ready"), bool)
            ):
                raise BrainControlError(
                    "BRAIN_CONTROL_INTENT_CONTEXT_PROJECTION_INVALID",
                    "intent receipt revision or readiness is invalid",
                )
        except BrainControlError:
            raise

        aggregate_ref = intent_context_aggregate_ref(
            task_id=task_id,
            task_instance_id=task_instance_id,
            workspace_key=workspace_key,
        )
        binding_request = {
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "workspaceKey": workspace_key,
            "ownerSessionKey": owner_session_key,
            "packageVersion": package_version,
            "contractRevision": contract_revision,
            "intentRevision": intent_revision,
            "planFingerprint": plan_fingerprint,
            "latestInstructionHash": latest_instruction_hash,
            "intentContractFingerprint": intent_contract_fingerprint,
            "receiptId": receipt_id,
            "payloadHash": receipt_payload_hash,
        }
        body = {
            "schema": INTENT_CONTEXT_PROJECTION_SCHEMA,
            "generatedAt": generated_at,
            "aggregateRef": aggregate_ref,
            "bindingHash": _sha256(binding_request),
            "ready": receipt["ready"],
            "intentContractBodyStored": False,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        projection = {**body, "payloadHash": _sha256(body)}
        destination = intent_context_projection_path(
            self.state_root,
            task_id=task_id,
            task_instance_id=task_instance_id,
            workspace_key=workspace_key,
        )
        self._write_json_atomic(
            destination,
            projection,
            "BRAIN_CONTROL_INTENT_CONTEXT_PROJECTION_WRITE_FAILED",
        )
        verification = read_intent_context_projection(
            self.state_root,
            binding_request,
            allow_pending=True,
        )
        if not verification.get("ok") or not verification.get("current"):
            raise BrainControlError(
                "BRAIN_CONTROL_INTENT_CONTEXT_PROJECTION_VERIFY_FAILED",
                "intent context projection is not readable as current",
            )
        self._finalize_intent_context_projection(connection, result, pending_marker)
        return dict(result)

    def prepare_intent(self, request: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_INTENT_REQUEST_INVALID", "intent prepare request must be an object")
        _ensure_safe(request, "intentPrepare")
        task_id = _require_string(request.get("taskId"), "taskId", 160)
        task_instance_id = _require_string(request.get("taskInstanceId"), "taskInstanceId", 80)
        workspace_key = _require_string(request.get("workspaceKey"), "workspaceKey", 120)
        owner_session_key = _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 120)
        contract_value = request.get("intentContract")
        if not isinstance(contract_value, Mapping):
            raise BrainControlError("BRAIN_CONTROL_INTENT_INVALID", "intentContract must be an object")
        contract = _normalize_intent_contract(contract_value)
        contract_fingerprint = _sha256(contract)
        aggregate_id = self._intent_aggregate_id(task_id, task_instance_id, workspace_key)
        with self._connection() as connection:
            aggregate = connection.execute(
                "SELECT * FROM intent_aggregates WHERE aggregate_id=?", (aggregate_id,)
            ).fetchone()
            actual_revision = int(aggregate["head_revision"]) if aggregate is not None else 0
            if aggregate is not None and str(aggregate["owner_session_key"]) != owner_session_key:
                raise BrainControlError(
                    "BRAIN_CONTROL_INTENT_SESSION_MISMATCH",
                    "intent aggregate belongs to another root session",
                )
            previous = None
            if actual_revision > 0:
                previous = connection.execute(
                    "SELECT contract_fingerprint FROM intent_contract_revisions WHERE aggregate_id=? AND intent_revision=?",
                    (aggregate_id, actual_revision),
                ).fetchone()
        changed = previous is None or str(previous["contract_fingerprint"]) != contract_fingerprint
        return {
            "ok": True,
            "code": "BRAIN_CONTROL_INTENT_PREPARED",
            "schema": "super-brain.intent-prepare-result.v2",
            "aggregateId": aggregate_id,
            "expectedIntentRevision": actual_revision,
            "intentRevision": actual_revision + 1 if changed else actual_revision,
            "contractChanged": changed,
            "intentContractFingerprint": contract_fingerprint,
            "intentContract": contract,
            "ready": not bool(contract["materialUnknowns"]),
        }

    def rebind_intent_session(self, request: Mapping[str, Any]) -> dict[str, Any]:
        normalized = self._normalize_intent_session_rebind_request(request)
        request_hash = _sha256(normalized)
        aggregate_id = self._intent_aggregate_id(
            normalized["taskId"], normalized["taskInstanceId"], normalized["workspaceKey"]
        )
        now = _utc_now()
        pending_marker: Path | None = None
        committed = False
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                # A rebind changes aggregate ownership but deliberately does
                # not mint a fresh receipt.  Keep context blocked until the
                # next resolve_intent publishes one for the new owner.
                pending_marker = self._begin_intent_context_projection_pending(
                    task_id=normalized["taskId"],
                    task_instance_id=normalized["taskInstanceId"],
                    workspace_key=normalized["workspaceKey"],
                    mutation_id=normalized["commandId"],
                )
                replay = connection.execute(
                    "SELECT payload_hash,result_json FROM command_log WHERE command_id=?",
                    (normalized["commandId"],),
                ).fetchone()
                if replay is not None:
                    if str(replay["payload_hash"]) != request_hash:
                        raise BrainControlError(
                            "BRAIN_CONTROL_COMMAND_ID_REUSED",
                            "commandId was already used with a different intent session rebind payload",
                        )
                    result = json.loads(str(replay["result_json"]))
                    result["idempotent"] = True
                    connection.execute("COMMIT")
                    committed = True
                    return result

                aggregate = connection.execute(
                    "SELECT * FROM intent_aggregates WHERE aggregate_id=?", (aggregate_id,)
                ).fetchone()
                if aggregate is None:
                    raise BrainControlError("BRAIN_CONTROL_INTENT_NOT_FOUND", "intent aggregate is missing")
                if str(aggregate["owner_session_key"]) != normalized["previousOwnerSessionKey"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_REBIND_OWNER_MISMATCH",
                        "intent aggregate owner does not match the verified previous session",
                    )
                if int(aggregate["head_revision"]) != normalized["expectedIntentRevision"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_STALE_REVISION",
                        "intent aggregate revision changed before session rebind",
                    )
                if str(aggregate["latest_receipt_id"]) != normalized["latestReceiptId"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_REBIND_RECEIPT_MISMATCH",
                        "intent aggregate head receipt changed before session rebind",
                    )
                receipt = connection.execute(
                    "SELECT * FROM intent_receipts WHERE receipt_id=?", (normalized["latestReceiptId"],)
                ).fetchone()
                if receipt is None or str(receipt["aggregate_id"]) != aggregate_id:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_REBIND_RECEIPT_MISMATCH",
                        "verified previous intent receipt is missing or belongs to another aggregate",
                    )
                if int(receipt["intent_revision"]) != normalized["expectedIntentRevision"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_REBIND_RECEIPT_MISMATCH",
                        "verified previous intent receipt is not the aggregate head revision",
                    )
                if str(receipt["owner_session_key"]) != normalized["previousOwnerSessionKey"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_REBIND_OWNER_MISMATCH",
                        "verified previous intent receipt belongs to another session",
                    )
                if str(receipt["payload_hash"]) != normalized["latestReceiptPayloadHash"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_REBIND_RECEIPT_MISMATCH",
                        "verified previous intent receipt payload hash does not match",
                    )

                rebind_id = "irb-" + uuid.uuid4().hex
                result = {
                    "ok": True,
                    "schema": "super-brain.intent-session-rebind-result.v1",
                    "rebindId": rebind_id,
                    "aggregateId": aggregate_id,
                    "taskId": normalized["taskId"],
                    "taskInstanceId": normalized["taskInstanceId"],
                    "workspaceKey": normalized["workspaceKey"],
                    "previousOwnerSessionKey": normalized["previousOwnerSessionKey"],
                    "newOwnerSessionKey": normalized["newOwnerSessionKey"],
                    "intentRevision": normalized["expectedIntentRevision"],
                    "latestReceiptId": normalized["latestReceiptId"],
                    "latestReceiptPayloadHash": normalized["latestReceiptPayloadHash"],
                    "source": normalized["source"],
                    "idempotent": False,
                }
                connection.execute(
                    "UPDATE intent_aggregates SET owner_session_key=?,updated_at=? WHERE aggregate_id=?",
                    (normalized["newOwnerSessionKey"], now, aggregate_id),
                )
                connection.execute(
                    """
                    INSERT INTO command_log(command_id,command_type,aggregate_id,expected_revision,payload_hash,result_json,created_at)
                    VALUES (?,?,?,?,?,?,?)
                    """,
                    (
                        normalized["commandId"], "rebind_intent_session", aggregate_id,
                        normalized["expectedIntentRevision"], request_hash, _canonical_json(result), now,
                    ),
                )
                connection.execute(
                    """
                    INSERT INTO intent_session_rebinds(rebind_id,command_id,aggregate_id,task_id,task_instance_id,workspace_key,previous_owner_session_key,new_owner_session_key,intent_revision,latest_receipt_id,latest_receipt_payload_hash,payload_hash,source,created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        rebind_id, normalized["commandId"], aggregate_id, normalized["taskId"],
                        normalized["taskInstanceId"], normalized["workspaceKey"],
                        normalized["previousOwnerSessionKey"], normalized["newOwnerSessionKey"],
                        normalized["expectedIntentRevision"], normalized["latestReceiptId"],
                        normalized["latestReceiptPayloadHash"], request_hash, normalized["source"], now,
                    ),
                )
                connection.execute(
                    """
                    INSERT INTO events(event_id,command_id,command_type,aggregate_id,revision,expected_revision,result_code,reason_code,source,created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        "evt-" + uuid.uuid4().hex, normalized["commandId"], "rebind_intent_session", aggregate_id,
                        normalized["expectedIntentRevision"], normalized["expectedIntentRevision"], "applied",
                        "session_rebound", normalized["source"], now,
                    ),
                )
                connection.execute("COMMIT")
                committed = True
                return result
            except Exception:
                try:
                    connection.execute("ROLLBACK")
                except sqlite3.Error:
                    pass
                if pending_marker is not None and not committed:
                    try:
                        self._remove_intent_context_marker(pending_marker)
                    except BrainControlError:
                        pass
                raise

    def issue_task_session_rebind(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Issue immutable authority for one future task-owner transfer.

        Unlike an intent rebind, this receipt deliberately does not update the
        task aggregate. The consuming ``apply_task`` mutation verifies the
        receipt against the still-current aggregate and performs the owner
        change atomically with the next task-state revision.
        """

        normalized = self._normalize_task_session_rebind_request(request)
        request_hash = _sha256(normalized)
        aggregate_id = self._task_aggregate_id(normalized["taskId"], normalized["workspaceKey"])
        now = _utc_now()
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                replay = connection.execute(
                    "SELECT payload_hash,result_json FROM command_log WHERE command_id=?",
                    (normalized["commandId"],),
                ).fetchone()
                if replay is not None:
                    if str(replay["payload_hash"]) != request_hash:
                        raise BrainControlError(
                            "BRAIN_CONTROL_COMMAND_ID_REUSED",
                            "commandId was already used with a different task session rebind payload",
                        )
                    result = json.loads(str(replay["result_json"]))
                    result["idempotent"] = True
                    connection.execute("COMMIT")
                    return result

                aggregate = connection.execute(
                    "SELECT * FROM task_aggregates WHERE aggregate_id=?", (aggregate_id,)
                ).fetchone()
                if aggregate is None:
                    raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_NOT_FOUND", "task aggregate is missing")
                if str(aggregate["task_instance_id"]) != normalized["taskInstanceId"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_TASK_SESSION_REBIND_INSTANCE_MISMATCH",
                        "task aggregate belongs to another task instance",
                    )
                if str(aggregate["owner_session_key"]) != normalized["previousOwnerSessionKey"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_TASK_SESSION_REBIND_OWNER_MISMATCH",
                        "task aggregate owner does not match the verified previous session",
                    )
                if str(aggregate["package_version"]) != normalized["packageVersion"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_TASK_SESSION_REBIND_PACKAGE_MISMATCH",
                        "task aggregate package version does not match the requesting contract",
                    )
                if int(aggregate["head_revision"]) != normalized["expectedTaskRevision"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_TASK_SESSION_REBIND_STALE",
                        "task aggregate revision changed before session rebind",
                    )
                state_row = connection.execute(
                    "SELECT state_hash,state_json FROM task_state_revisions WHERE aggregate_id=? AND task_revision=?",
                    (aggregate_id, normalized["expectedTaskRevision"]),
                ).fetchone()
                if state_row is None or str(state_row["state_hash"]) != str(aggregate["head_state_hash"]):
                    raise BrainControlError(
                        "BRAIN_CONTROL_TASK_SESSION_REBIND_STATE_MISMATCH",
                        "task aggregate head state is unavailable or inconsistent",
                    )
                state = json.loads(str(state_row["state_json"]))
                if int(state.get("contractRevision", -1)) != normalized["expectedContractRevision"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_TASK_SESSION_REBIND_CONTRACT_MISMATCH",
                        "task state contract revision does not match the prior execution contract",
                    )
                if str(state.get("planFingerprint", "")) != normalized["expectedPlanFingerprint"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_TASK_SESSION_REBIND_PLAN_MISMATCH",
                        "task state plan fingerprint does not match the prior execution contract",
                    )

                rebind_id = "trb-" + uuid.uuid4().hex
                result = {
                    "ok": True,
                    "schema": "super-brain.task-session-rebind-receipt.v1",
                    "rebindId": rebind_id,
                    "aggregateId": aggregate_id,
                    "taskId": normalized["taskId"],
                    "taskInstanceId": normalized["taskInstanceId"],
                    "workspaceKey": normalized["workspaceKey"],
                    "previousOwnerSessionKey": normalized["previousOwnerSessionKey"],
                    "newOwnerSessionKey": normalized["newOwnerSessionKey"],
                    "packageVersion": normalized["packageVersion"],
                    "taskRevision": normalized["expectedTaskRevision"],
                    "taskStateHash": str(state_row["state_hash"]),
                    "contractRevision": normalized["expectedContractRevision"],
                    "planFingerprint": normalized["expectedPlanFingerprint"],
                    "source": normalized["source"],
                    "idempotent": False,
                }
                connection.execute(
                    """
                    INSERT INTO command_log(command_id,command_type,aggregate_id,expected_revision,payload_hash,result_json,created_at)
                    VALUES (?,?,?,?,?,?,?)
                    """,
                    (
                        normalized["commandId"], "issue_task_session_rebind", aggregate_id,
                        normalized["expectedTaskRevision"], request_hash, _canonical_json(result), now,
                    ),
                )
                connection.execute(
                    """
                    INSERT INTO task_session_rebinds(rebind_id,command_id,aggregate_id,task_id,task_instance_id,workspace_key,previous_owner_session_key,new_owner_session_key,package_version,task_revision,task_state_hash,contract_revision,plan_fingerprint,payload_hash,source,created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        rebind_id, normalized["commandId"], aggregate_id, normalized["taskId"],
                        normalized["taskInstanceId"], normalized["workspaceKey"],
                        normalized["previousOwnerSessionKey"], normalized["newOwnerSessionKey"],
                        normalized["packageVersion"], normalized["expectedTaskRevision"], str(state_row["state_hash"]),
                        normalized["expectedContractRevision"], normalized["expectedPlanFingerprint"], request_hash,
                        normalized["source"], now,
                    ),
                )
                connection.execute(
                    """
                    INSERT INTO events(event_id,command_id,command_type,aggregate_id,revision,expected_revision,result_code,reason_code,source,created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        "evt-" + uuid.uuid4().hex, normalized["commandId"], "issue_task_session_rebind", aggregate_id,
                        normalized["expectedTaskRevision"], normalized["expectedTaskRevision"], "prepared",
                        "session_rebind_authorized", normalized["source"], now,
                    ),
                )
                connection.execute("COMMIT")
                return result
            except Exception:
                connection.execute("ROLLBACK")
                raise

    def resolve_intent(self, request: Mapping[str, Any]) -> dict[str, Any]:
        normalized = self._normalize_intent_resolution_request(request)
        request_hash = _sha256(normalized)
        aggregate_id = self._intent_aggregate_id(
            normalized["taskId"], normalized["taskInstanceId"], normalized["workspaceKey"]
        )
        normalized["aggregateId"] = aggregate_id
        pending_marker: Path | None = None
        committed = False
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                pending_marker = self._begin_intent_context_projection_pending(
                    task_id=normalized["taskId"],
                    task_instance_id=normalized["taskInstanceId"],
                    workspace_key=normalized["workspaceKey"],
                    mutation_id=normalized["commandId"],
                )
                replay = connection.execute(
                    "SELECT payload_hash,result_json FROM command_log WHERE command_id=?",
                    (normalized["commandId"],),
                ).fetchone()
                if replay is not None:
                    if str(replay["payload_hash"]) != request_hash:
                        raise BrainControlError(
                            "BRAIN_CONTROL_COMMAND_ID_REUSED",
                            "commandId was already used with a different intent payload",
                        )
                    result = json.loads(str(replay["result_json"]))
                    result["idempotent"] = True
                    connection.execute("COMMIT")
                    committed = True
                    return self._publish_intent_context_projection(
                        result,
                        pending_marker=pending_marker,
                        connection=connection,
                    )

                aggregate = connection.execute(
                    "SELECT * FROM intent_aggregates WHERE aggregate_id=?", (aggregate_id,)
                ).fetchone()
                actual_revision = int(aggregate["head_revision"]) if aggregate is not None else 0
                if actual_revision != normalized["expectedIntentRevision"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_STALE_REVISION",
                        f"expected intent revision {normalized['expectedIntentRevision']}, found {actual_revision}",
                    )
                if aggregate is not None and str(aggregate["owner_session_key"]) != normalized["ownerSessionKey"]:
                    raise BrainControlError(
                        "BRAIN_CONTROL_INTENT_SESSION_MISMATCH",
                        "intent aggregate belongs to another root session",
                    )

                contract_fingerprint = _sha256(normalized["intentContract"])
                previous = None
                if actual_revision > 0:
                    previous = connection.execute(
                        "SELECT contract_fingerprint FROM intent_contract_revisions WHERE aggregate_id=? AND intent_revision=?",
                        (aggregate_id, actual_revision),
                    ).fetchone()
                contract_changed = previous is None or str(previous["contract_fingerprint"]) != contract_fingerprint
                intent_revision = actual_revision + 1 if contract_changed else actual_revision
                now = _utc_now()
                receipt_id = "ir-" + uuid.uuid4().hex
                receipt_payload = self._intent_receipt_payload(normalized, intent_revision, contract_fingerprint)
                receipt_payload_hash = _sha256(receipt_payload)
                receipt = {
                    **receipt_payload,
                    "receiptId": receipt_id,
                    "payloadHash": receipt_payload_hash,
                    "source": normalized["source"],
                    "capturedAt": now,
                }
                result = {
                    "ok": True,
                    "code": "BRAIN_CONTROL_INTENT_RESOLVED" if receipt["ready"] else "BRAIN_CONTROL_INTENT_MATERIAL_UNKNOWN",
                    "schema": "super-brain.intent-resolution-result.v2",
                    "aggregateId": aggregate_id,
                    "intentRevision": intent_revision,
                    "contractChanged": contract_changed,
                    "intentContract": normalized["intentContract"],
                    "intentResolutionReceipt": receipt,
                    "idempotent": False,
                }

                if aggregate is None:
                    connection.execute(
                        """
                        INSERT INTO intent_aggregates(aggregate_id,task_id,task_instance_id,workspace_key,owner_session_key,head_revision,latest_receipt_id,created_at,updated_at)
                        VALUES (?,?,?,?,?,?,?,?,?)
                        """,
                        (
                            aggregate_id, normalized["taskId"], normalized["taskInstanceId"],
                            normalized["workspaceKey"], normalized["ownerSessionKey"], intent_revision,
                            receipt_id, now, now,
                        ),
                    )
                if contract_changed:
                    predecessor_hash = str(previous["contract_fingerprint"]) if previous is not None else ""
                    connection.execute(
                        """
                        INSERT INTO intent_contract_revisions(aggregate_id,intent_revision,predecessor_contract_hash,contract_fingerprint,contract_json,source,created_at)
                        VALUES (?,?,?,?,?,?,?)
                        """,
                        (
                            aggregate_id, intent_revision, predecessor_hash, contract_fingerprint,
                            _canonical_json(normalized["intentContract"]), normalized["source"], now,
                        ),
                    )
                connection.execute(
                    """
                    INSERT INTO command_log(command_id,command_type,aggregate_id,expected_revision,payload_hash,result_json,created_at)
                    VALUES (?,?,?,?,?,?,?)
                    """,
                    (
                        normalized["commandId"], "resolve_intent", aggregate_id,
                        normalized["expectedIntentRevision"], request_hash, _canonical_json(result), now,
                    ),
                )
                connection.execute(
                    """
                    INSERT INTO intent_receipts(receipt_id,aggregate_id,intent_revision,command_id,task_id,task_instance_id,workspace_key,owner_session_key,package_version,contract_revision,plan_fingerprint,latest_instruction_hash,contract_fingerprint,payload_hash,ready,source,created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        receipt_id, aggregate_id, intent_revision, normalized["commandId"], normalized["taskId"],
                        normalized["taskInstanceId"], normalized["workspaceKey"], normalized["ownerSessionKey"],
                        normalized["packageVersion"], normalized["contractRevision"], normalized["planFingerprint"],
                        normalized["latestInstructionHash"], contract_fingerprint, receipt_payload_hash,
                        1 if receipt["ready"] else 0, normalized["source"], now,
                    ),
                )
                event_id = "evt-" + uuid.uuid4().hex
                connection.execute(
                    """
                    INSERT INTO events(event_id,command_id,command_type,aggregate_id,revision,expected_revision,result_code,reason_code,source,created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        event_id, normalized["commandId"], "resolve_intent", aggregate_id, intent_revision,
                        normalized["expectedIntentRevision"], "applied",
                        "" if receipt["ready"] else "material_unknown", normalized["source"], now,
                    ),
                )
                connection.execute(
                    "UPDATE intent_aggregates SET head_revision=?,latest_receipt_id=?,updated_at=? WHERE aggregate_id=?",
                    (intent_revision, receipt_id, now, aggregate_id),
                )
                connection.execute("COMMIT")
                committed = True
                return self._publish_intent_context_projection(
                    result,
                    pending_marker=pending_marker,
                    connection=connection,
                )
            except Exception:
                try:
                    connection.execute("ROLLBACK")
                except sqlite3.Error:
                    # A post-commit projection failure is intentionally not
                    # rolled back: the durable command is still recoverable by
                    # replaying the same command id, which republishes it.
                    pass
                if pending_marker is not None and not committed:
                    try:
                        self._remove_intent_context_marker(pending_marker)
                    except BrainControlError:
                        pass
                raise

    def check_intent(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Verify an intent receipt through the normal command-side connection."""

        return self._check_intent(request, read_only=False)

    def check_intent_read_only(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Verify an intent receipt without migrations, WAL writes, or repair.

        This is deliberately a total, fail-closed read API for the Host context
        path.  A missing, locked, malformed, or unavailable authority returns a
        structured non-current result rather than causing the context command to
        fail with a process error.
        """

        try:
            return self._check_intent(request, read_only=True)
        except BrainControlError as exc:
            return {
                "ok": False,
                "current": False,
                "code": exc.code,
                "missing": ["readOnlyIntentAuthority"],
            }
        except (OSError, sqlite3.Error, TypeError, ValueError):
            return {
                "ok": False,
                "current": False,
                "code": "BRAIN_CONTROL_INTENT_READ_ONLY_UNAVAILABLE",
                "missing": ["readOnlyIntentAuthority"],
            }

    def _check_intent(self, request: Mapping[str, Any], *, read_only: bool) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_INTENT_REQUEST_INVALID", "intent check must be an object")
        _ensure_safe(request, "intentCheck")
        task_id = _require_string(request.get("taskId"), "taskId", 160)
        task_instance_id = _require_string(request.get("taskInstanceId"), "taskInstanceId", 80)
        workspace_key = _require_string(request.get("workspaceKey"), "workspaceKey", 120)
        aggregate_id = self._intent_aggregate_id(task_id, task_instance_id, workspace_key)
        expected = {
            "owner_session_key": _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 120),
            "package_version": _require_string(request.get("packageVersion"), "packageVersion", 48),
            "plan_fingerprint": _require_string(request.get("planFingerprint"), "planFingerprint", 64),
            "latest_instruction_hash": _require_sha256(request.get("latestInstructionHash"), "latestInstructionHash"),
        }
        contract_revision = request.get("contractRevision")
        intent_revision = request.get("intentRevision")
        if not isinstance(contract_revision, int) or contract_revision < 1:
            raise BrainControlError("BRAIN_CONTROL_INTENT_CONTRACT_REVISION_INVALID", "contractRevision is invalid")
        if not isinstance(intent_revision, int) or intent_revision < 1:
            raise BrainControlError("BRAIN_CONTROL_INTENT_REVISION_INVALID", "intentRevision is invalid")
        receipt_id = _require_string(request.get("receiptId"), "receiptId", 80)
        connection_context = self._read_only_connection() if read_only else self._connection()
        with connection_context as connection:
            aggregate = connection.execute(
                "SELECT * FROM intent_aggregates WHERE aggregate_id=?", (aggregate_id,)
            ).fetchone()
            if aggregate is None:
                return {"ok": False, "current": False, "code": "BRAIN_CONTROL_INTENT_NOT_FOUND", "missing": ["intentAggregate"]}
            # Look up the immutable receipt independently from the requested
            # aggregate so a receipt replayed from another task is reported as
            # a scope mismatch instead of being mistaken for missing state.
            receipt_row = connection.execute(
                "SELECT * FROM intent_receipts WHERE receipt_id=?", (receipt_id,)
            ).fetchone()
            revision_row = None
            if receipt_row is not None:
                revision_row = connection.execute(
                    "SELECT * FROM intent_contract_revisions WHERE aggregate_id=? AND intent_revision=?",
                    (str(receipt_row["aggregate_id"]), int(receipt_row["intent_revision"])),
                ).fetchone()
        if receipt_row is None or revision_row is None:
            return {"ok": False, "current": False, "code": "BRAIN_CONTROL_INTENT_RECEIPT_NOT_FOUND", "missing": ["intentResolutionReceipt"]}

        mismatches: list[str] = []
        bindings = {
            "taskId": (str(receipt_row["task_id"]), task_id),
            "taskInstanceId": (str(receipt_row["task_instance_id"]), task_instance_id),
            "workspaceKey": (str(receipt_row["workspace_key"]), workspace_key),
            "ownerSessionKey": (str(receipt_row["owner_session_key"]), expected["owner_session_key"]),
            "packageVersion": (str(receipt_row["package_version"]), expected["package_version"]),
            "contractRevision": (int(receipt_row["contract_revision"]), contract_revision),
            "intentRevision": (int(receipt_row["intent_revision"]), intent_revision),
            "planFingerprint": (str(receipt_row["plan_fingerprint"]), expected["plan_fingerprint"]),
            "latestInstructionHash": (str(receipt_row["latest_instruction_hash"]), expected["latest_instruction_hash"]),
        }
        for name, (actual, wanted) in bindings.items():
            if actual != wanted:
                mismatches.append(name)
        try:
            contract = json.loads(str(revision_row["contract_json"]))
        except json.JSONDecodeError:
            contract = None
        if not isinstance(contract, dict) or _sha256(contract) != str(revision_row["contract_fingerprint"]):
            mismatches.append("intentContractFingerprint")
            contract = None
        elif str(receipt_row["contract_fingerprint"]) != str(revision_row["contract_fingerprint"]):
            mismatches.append("intentContractFingerprint")
        if request.get("intentContractFingerprint") and str(request.get("intentContractFingerprint")) != str(receipt_row["contract_fingerprint"]):
            mismatches.append("intentContractFingerprint")
        receipt_payload = {
            "schema": INTENT_RECEIPT_SCHEMA,
            "taskId": str(receipt_row["task_id"]),
            "taskInstanceId": str(receipt_row["task_instance_id"]),
            "workspaceKey": str(receipt_row["workspace_key"]),
            "ownerSessionKey": str(receipt_row["owner_session_key"]),
            "packageVersion": str(receipt_row["package_version"]),
            "contractRevision": int(receipt_row["contract_revision"]),
            "intentRevision": int(receipt_row["intent_revision"]),
            "planFingerprint": str(receipt_row["plan_fingerprint"]),
            "latestInstructionHash": str(receipt_row["latest_instruction_hash"]),
            "intentContractFingerprint": str(receipt_row["contract_fingerprint"]),
            "ready": bool(receipt_row["ready"]),
            "rawTranscriptStored": False,
        }
        calculated_payload_hash = _sha256(receipt_payload)
        if calculated_payload_hash != str(receipt_row["payload_hash"]):
            mismatches.append("payloadHash")
        if request.get("payloadHash") and str(request.get("payloadHash")) != calculated_payload_hash:
            mismatches.append("payloadHash")
        if int(aggregate["head_revision"]) != intent_revision or str(aggregate["latest_receipt_id"]) != receipt_id:
            mismatches.append("currentHead")
        if mismatches:
            return {
                "ok": False,
                "current": False,
                "code": "BRAIN_CONTROL_INTENT_RECEIPT_STALE",
                "missing": sorted(set(mismatches)),
            }
        if not bool(receipt_row["ready"]) or (contract and contract.get("materialUnknowns")):
            return {
                "ok": False,
                "current": False,
                "code": "BRAIN_CONTROL_INTENT_MATERIAL_UNKNOWN",
                "missing": list(contract.get("materialUnknowns", [])) if contract else ["materialUnknowns"],
            }
        return {
            "ok": True,
            "current": True,
            "code": "BRAIN_CONTROL_INTENT_RECEIPT_CURRENT",
            "aggregateId": aggregate_id,
            "intentContract": contract,
            "intentResolutionReceipt": {
                **receipt_payload,
                "receiptId": receipt_id,
                "payloadHash": calculated_payload_hash,
                "source": str(receipt_row["source"]),
                "capturedAt": str(receipt_row["created_at"]),
            },
            "missing": [],
        }

    @staticmethod
    def _decision_resolution_aggregate_id(scope: Mapping[str, Any]) -> str:
        return "decision-resolution-" + _sha256(
            {
                "taskId": scope["taskId"],
                "taskInstanceId": scope["taskInstanceId"],
                "workspaceKey": scope["workspaceKey"],
                "ownerSessionKey": scope["ownerSessionKey"],
                "stageKind": scope["stageKind"],
                "worklineId": scope["worklineId"],
                "intentFingerprint": scope["intentFingerprint"],
            }
        )

    def _normalize_decision_resolution_scope(self, request: Mapping[str, Any], *, command_required: bool) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_DECISION_REQUEST_INVALID", "decision resolution request must be an object")
        _ensure_safe(request, "decisionResolutionRequest")
        contract_revision = request.get("contractRevision")
        if isinstance(contract_revision, bool) or not isinstance(contract_revision, int) or contract_revision < 1:
            raise BrainControlError("BRAIN_CONTROL_DECISION_CONTRACT_REVISION_INVALID", "contractRevision must be a positive integer")
        stage_kind = _require_string(request.get("stageKind"), "stageKind", 24).lower()
        if stage_kind not in DECISION_STAGE_KINDS:
            raise BrainControlError("BRAIN_CONTROL_DECISION_STAGE_INVALID", f"unsupported stageKind: {stage_kind}")
        package_identity = self._package_identity()
        requested_version = _require_string(request.get("packageVersion"), "packageVersion", 48)
        requested_manifest_hash = _require_sha256(request.get("packageManifestHash"), "packageManifestHash")
        if requested_version != package_identity["packageVersion"]:
            raise BrainControlError("BRAIN_CONTROL_DECISION_PACKAGE_VERSION_MISMATCH", "packageVersion does not match the executing package")
        if requested_manifest_hash != package_identity["packageManifestHash"]:
            raise BrainControlError("BRAIN_CONTROL_DECISION_PACKAGE_MANIFEST_MISMATCH", "packageManifestHash does not match the executing package")
        normalized: dict[str, Any] = {
            "taskId": _require_string(request.get("taskId"), "taskId", 160),
            "taskInstanceId": _require_string(request.get("taskInstanceId"), "taskInstanceId", 80),
            "workspaceKey": _require_string(request.get("workspaceKey"), "workspaceKey", 120),
            "ownerSessionKey": _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 120),
            "stageKind": stage_kind,
            "worklineId": _optional_string(request.get("worklineId"), "worklineId", 120),
            "intentFingerprint": _optional_string(request.get("intentFingerprint"), "intentFingerprint", 128),
            "packageVersion": requested_version,
            "packageManifestHash": requested_manifest_hash,
            "contractRevision": contract_revision,
            "planFingerprint": _require_string(request.get("planFingerprint"), "planFingerprint", 64),
        }
        if command_required:
            normalized["commandId"] = _require_string(request.get("commandId"), "commandId", 160)
            normalized["source"] = _require_string(request.get("source", "brain_control.decision_resolution"), "source", 160)
        return normalized

    def _current_decision_resolution_items(
        self,
        connection: sqlite3.Connection,
        scope: Mapping[str, Any],
    ) -> tuple[list[dict[str, Any]], list[str]]:
        rows = connection.execute(
            """
            SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
              r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
              r.state_json,r.created_at
            FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
            WHERE c.kind='decision' AND c.scope_kind='workspace' AND c.scope_key=? AND c.lifecycle='active'
            ORDER BY c.card_id
            """,
            (scope["workspaceKey"],),
        ).fetchall()
        items: list[dict[str, Any]] = []
        errors: list[str] = []
        for row in rows:
            card = self._card_from_row(row)
            if _sha256(self._card_content(card)) != card["contentHash"]:
                errors.append(f"card_content_hash_invalid:{card['cardId']}")
                continue
            try:
                payload = _normalize_decision_payload(card["payload"])
            except BrainControlError as exc:
                errors.append(f"card_payload_invalid:{card['cardId']}:{exc.code}")
                continue
            if payload.get("schema") != "super-brain.card.decision.v2":
                continue
            if scope["stageKind"] not in payload["stageKinds"]:
                continue
            if not _decision_applicability_matches_scope(payload["applicability"], scope):
                continue
            enforcement = str(payload["enforcement"])
            if enforcement == "completion_gate" and card["authority"] != "user_confirmed":
                errors.append(f"completion_gate_authority_invalid:{card['cardId']}")
                continue
            items.append(
                {
                    "cardId": card["cardId"],
                    "cardRevision": card["revision"],
                    "contentHash": card["contentHash"],
                    "enforcement": enforcement,
                    "completionCriteriaDigest": _sha256(payload["completionCriteria"]),
                }
            )
        completion_gates = [item for item in items if item["enforcement"] == "completion_gate"]
        if len(completion_gates) > 1:
            errors.append("overlapping_completion_gate_decisions")
        return items, errors

    @staticmethod
    def _decision_resolution_digest(scope: Mapping[str, Any], status: str, items: Sequence[Mapping[str, Any]]) -> str:
        return _sha256(
            {
                "taskId": scope["taskId"],
                "taskInstanceId": scope["taskInstanceId"],
                "workspaceKey": scope["workspaceKey"],
                "ownerSessionKey": scope["ownerSessionKey"],
                "stageKind": scope["stageKind"],
                "worklineId": scope["worklineId"],
                "intentFingerprint": scope["intentFingerprint"],
                "packageVersion": scope["packageVersion"],
                "packageManifestHash": scope["packageManifestHash"],
                "contractRevision": scope["contractRevision"],
                "planFingerprint": scope["planFingerprint"],
                "status": status,
                "items": list(items),
            }
        )

    @staticmethod
    def _decision_receipt_matches_scope(receipt: sqlite3.Row, scope: Mapping[str, Any]) -> bool:
        pairs = (
            ("task_id", "taskId"),
            ("task_instance_id", "taskInstanceId"),
            ("workspace_key", "workspaceKey"),
            ("owner_session_key", "ownerSessionKey"),
            ("stage_kind", "stageKind"),
            ("workline_id", "worklineId"),
            ("intent_fingerprint", "intentFingerprint"),
            ("package_version", "packageVersion"),
            ("plan_fingerprint", "planFingerprint"),
        )
        return all(str(receipt[column]) == str(scope[key]) for column, key in pairs) and int(receipt["contract_revision"]) == int(scope["contractRevision"])

    def resolve_decisions(self, request: Mapping[str, Any]) -> dict[str, Any]:
        scope = self._normalize_decision_resolution_scope(request, command_required=True)
        aggregate_id = self._decision_resolution_aggregate_id(scope)
        normalized = {**scope, "aggregateId": aggregate_id}
        payload_hash = _sha256(normalized)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                existing = connection.execute(
                    "SELECT command_type,payload_hash,result_json FROM command_log WHERE command_id=?", (scope["commandId"],)
                ).fetchone()
                if existing is not None:
                    if str(existing["command_type"]) != "resolve_decisions" or str(existing["payload_hash"]) != payload_hash:
                        raise BrainControlError("BRAIN_CONTROL_COMMAND_ID_REUSED", "commandId was already used with a different payload")
                    result = json.loads(str(existing["result_json"]))
                    result["idempotent"] = True
                    connection.execute("COMMIT")
                    return result
                items, errors = self._current_decision_resolution_items(connection, scope)
                status = "withheld" if errors else ("bound" if items else "none_applicable")
                binding_digest = self._decision_resolution_digest(scope, status, items)
                now = _utc_now()
                receipt_id = "dr-" + uuid.uuid4().hex
                event_id = "evt-" + uuid.uuid4().hex
                result = {
                    "ok": status != "withheld",
                    "schema": DECISION_RESOLUTION_SCHEMA,
                    "receiptId": receipt_id,
                    "aggregateId": aggregate_id,
                    "status": status,
                    "bindingDigest": binding_digest,
                    "packageVersion": scope["packageVersion"],
                    "packageManifestHash": scope["packageManifestHash"],
                    "decisionCount": len(items),
                    "decisions": items,
                    "reasons": errors,
                    "idempotent": False,
                }
                connection.execute(
                    "INSERT INTO command_log(command_id,command_type,aggregate_id,expected_revision,payload_hash,result_json,created_at) VALUES (?,?,?,?,?,?,?)",
                    (scope["commandId"], "resolve_decisions", aggregate_id, scope["contractRevision"], payload_hash, _canonical_json(result), now),
                )
                connection.execute(
                    """
                    INSERT INTO decision_resolution_receipts(
                      receipt_id,command_id,aggregate_id,task_id,task_instance_id,workspace_key,owner_session_key,stage_kind,
                      workline_id,intent_fingerprint,package_version,contract_revision,plan_fingerprint,status,binding_digest,payload_hash,source,created_at
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        receipt_id, scope["commandId"], aggregate_id, scope["taskId"], scope["taskInstanceId"],
                        scope["workspaceKey"], scope["ownerSessionKey"], scope["stageKind"], scope["worklineId"],
                        scope["intentFingerprint"], scope["packageVersion"], scope["contractRevision"],
                        scope["planFingerprint"], status, binding_digest, payload_hash, scope["source"], now,
                    ),
                )
                for item in items:
                    connection.execute(
                        "INSERT INTO decision_resolution_items(receipt_id,card_id,card_revision,content_hash,enforcement,completion_criteria_digest) VALUES (?,?,?,?,?,?)",
                        (
                            receipt_id, item["cardId"], item["cardRevision"], item["contentHash"], item["enforcement"],
                            item["completionCriteriaDigest"],
                        ),
                    )
                connection.execute(
                    "INSERT INTO events(event_id,command_id,command_type,aggregate_id,revision,expected_revision,result_code,reason_code,source,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (
                        event_id, scope["commandId"], "resolve_decisions", aggregate_id, scope["contractRevision"],
                        scope["contractRevision"], "applied", status, scope["source"], now,
                    ),
                )
                connection.execute("COMMIT")
                return result
            except Exception:
                connection.execute("ROLLBACK")
                raise

    def _checked_decision_receipt(
        self,
        connection: sqlite3.Connection,
        scope: Mapping[str, Any],
        receipt_id: str,
        binding_digest: str,
    ) -> tuple[sqlite3.Row | None, dict[str, Any]]:
        receipt = connection.execute("SELECT * FROM decision_resolution_receipts WHERE receipt_id=?", (receipt_id,)).fetchone()
        if receipt is None or not self._decision_receipt_matches_scope(receipt, scope):
            return None, {"ok": False, "status": "withheld", "code": "BRAIN_CONTROL_DECISION_RECEIPT_STALE_OR_FOREIGN"}
        if str(receipt["binding_digest"]) != binding_digest:
            return None, {"ok": False, "status": "withheld", "code": "BRAIN_CONTROL_DECISION_BINDING_DIGEST_MISMATCH"}
        items, errors = self._current_decision_resolution_items(connection, scope)
        status = "withheld" if errors else ("bound" if items else "none_applicable")
        current_digest = self._decision_resolution_digest(scope, status, items)
        if status != str(receipt["status"]) or current_digest != str(receipt["binding_digest"]):
            return None, {"ok": False, "status": "withheld", "code": "BRAIN_CONTROL_DECISION_RECEIPT_STALE", "reasons": errors}
        return receipt, {
            "ok": status != "withheld",
            "schema": DECISION_RESOLUTION_SCHEMA,
            "receiptId": receipt_id,
            "status": status,
            "bindingDigest": current_digest,
            "packageVersion": scope["packageVersion"],
            "packageManifestHash": scope["packageManifestHash"],
            "decisionCount": len(items),
            "decisions": items,
        }

    def check_decision_resolution(self, request: Mapping[str, Any]) -> dict[str, Any]:
        scope = self._normalize_decision_resolution_scope(request, command_required=False)
        receipt_id = _require_string(request.get("receiptId"), "receiptId", 80)
        binding_digest = _require_sha256(request.get("bindingDigest"), "bindingDigest")
        with self._connection() as connection:
            _, result = self._checked_decision_receipt(connection, scope, receipt_id, binding_digest)
        return result

    def record_decision_result(self, request: Mapping[str, Any]) -> dict[str, Any]:
        scope = self._normalize_decision_resolution_scope(request, command_required=True)
        receipt_id = _require_string(request.get("receiptId"), "receiptId", 80)
        binding_digest = _require_sha256(request.get("bindingDigest"), "bindingDigest")
        card_id = _require_string(request.get("cardId"), "cardId", 160)
        card_revision = request.get("cardRevision")
        if isinstance(card_revision, bool) or not isinstance(card_revision, int) or card_revision < 1:
            raise BrainControlError("BRAIN_CONTROL_DECISION_RESULT_INVALID", "cardRevision must be a positive integer")
        result_ok = request.get("resultOk")
        if not isinstance(result_ok, bool):
            raise BrainControlError("BRAIN_CONTROL_DECISION_RESULT_INVALID", "resultOk must be boolean")
        evidence_refs = _card_list(request.get("evidenceRefs", []), "evidenceRefs", 12, 320)
        normalized = {
            **scope,
            "receiptId": receipt_id,
            "bindingDigest": binding_digest,
            "cardId": card_id,
            "cardRevision": card_revision,
            "resultOk": result_ok,
            "evidenceRefs": evidence_refs,
        }
        payload_hash = _sha256(normalized)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                existing = connection.execute(
                    "SELECT command_type,payload_hash,result_json FROM command_log WHERE command_id=?", (scope["commandId"],)
                ).fetchone()
                if existing is not None:
                    if str(existing["command_type"]) != "record_decision_result" or str(existing["payload_hash"]) != payload_hash:
                        raise BrainControlError("BRAIN_CONTROL_COMMAND_ID_REUSED", "commandId was already used with a different payload")
                    result = json.loads(str(existing["result_json"]))
                    result["idempotent"] = True
                    connection.execute("COMMIT")
                    return result
                receipt, checked = self._checked_decision_receipt(connection, scope, receipt_id, binding_digest)
                if receipt is None or checked["status"] != "bound":
                    raise BrainControlError("BRAIN_CONTROL_DECISION_RECEIPT_STALE", "decision result requires a current bound receipt")
                item = connection.execute(
                    "SELECT * FROM decision_resolution_items WHERE receipt_id=? AND card_id=? AND card_revision=?",
                    (receipt_id, card_id, card_revision),
                ).fetchone()
                if item is None:
                    raise BrainControlError("BRAIN_CONTROL_DECISION_RESULT_FOREIGN", "decision is not bound by this receipt")
                if str(item["enforcement"]) == "completion_gate" and not evidence_refs:
                    raise BrainControlError("BRAIN_CONTROL_DECISION_EVIDENCE_REQUIRED", "completion-gate result requires evidenceRefs")
                prior = connection.execute(
                    "SELECT result_id FROM decision_completion_results WHERE receipt_id=? AND card_id=? AND card_revision=?",
                    (receipt_id, card_id, card_revision),
                ).fetchone()
                if prior is not None:
                    raise BrainControlError("BRAIN_CONTROL_DECISION_RESULT_ALREADY_RECORDED", "decision result already exists for this receipt")
                now = _utc_now()
                result_id = "dcr-" + uuid.uuid4().hex
                event_id = "evt-" + uuid.uuid4().hex
                result = {
                    "ok": True,
                    "schema": DECISION_COMPLETION_RESULT_SCHEMA,
                    "resultId": result_id,
                    "receiptId": receipt_id,
                    "cardId": card_id,
                    "cardRevision": card_revision,
                    "resultOk": result_ok,
                    "idempotent": False,
                }
                connection.execute(
                    "INSERT INTO command_log(command_id,command_type,aggregate_id,expected_revision,payload_hash,result_json,created_at) VALUES (?,?,?,?,?,?,?)",
                    (scope["commandId"], "record_decision_result", str(receipt["aggregate_id"]), card_revision, payload_hash, _canonical_json(result), now),
                )
                connection.execute(
                    """
                    INSERT INTO decision_completion_results(result_id,command_id,receipt_id,card_id,card_revision,content_hash,completion_criteria_digest,result_ok,evidence_refs,source,created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        result_id, scope["commandId"], receipt_id, card_id, card_revision, item["content_hash"],
                        item["completion_criteria_digest"], int(result_ok), _canonical_json(evidence_refs), scope["source"], now,
                    ),
                )
                connection.execute(
                    "INSERT INTO events(event_id,command_id,command_type,aggregate_id,revision,expected_revision,result_code,reason_code,source,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (event_id, scope["commandId"], "record_decision_result", str(receipt["aggregate_id"]), card_revision, card_revision, "applied", "decision_result", scope["source"], now),
                )
                connection.execute("COMMIT")
                return result
            except Exception:
                connection.execute("ROLLBACK")
                raise

    def validate_decision_completion(self, request: Mapping[str, Any]) -> dict[str, Any]:
        scope = self._normalize_decision_resolution_scope(request, command_required=False)
        receipt_id = _require_string(request.get("receiptId"), "receiptId", 80)
        binding_digest = _require_sha256(request.get("bindingDigest"), "bindingDigest")
        with self._connection() as connection:
            receipt, checked = self._checked_decision_receipt(connection, scope, receipt_id, binding_digest)
            if receipt is None:
                return checked
            if checked["status"] == "none_applicable":
                return {**checked, "completionCurrent": True, "results": []}
            missing: list[str] = []
            results: list[dict[str, Any]] = []
            for item in checked["decisions"]:
                if item["enforcement"] != "completion_gate":
                    continue
                result = connection.execute(
                    "SELECT result_id,result_ok,evidence_refs,content_hash,completion_criteria_digest FROM decision_completion_results WHERE receipt_id=? AND card_id=? AND card_revision=?",
                    (receipt_id, item["cardId"], item["cardRevision"]),
                ).fetchone()
                if result is None:
                    missing.append(str(item["cardId"]))
                    continue
                try:
                    evidence_refs = json.loads(str(result["evidence_refs"]))
                except json.JSONDecodeError:
                    evidence_refs = []
                if (
                    int(result["result_ok"]) != 1
                    or str(result["content_hash"]) != item["contentHash"]
                    or str(result["completion_criteria_digest"]) != item["completionCriteriaDigest"]
                    or not isinstance(evidence_refs, list)
                    or not evidence_refs
                ):
                    missing.append(str(item["cardId"]))
                    continue
                results.append(
                    {
                        "cardId": item["cardId"],
                        "cardRevision": item["cardRevision"],
                        "resultId": str(result["result_id"]),
                    }
                )
        if missing:
            return {
                **checked,
                "ok": False,
                "status": "withheld",
                "code": "BRAIN_CONTROL_DECISION_COMPLETION_UNSATISFIED",
                "missingDecisionResults": missing,
                "results": results,
            }
        return {**checked, "completionCurrent": True, "results": results}

    @staticmethod
    def _normalize_memory_influence_request(request: Mapping[str, Any]) -> dict[str, Any]:
        """Normalize a read-only execution context without retaining its focus text."""

        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_MEMORY_INFLUENCE_REQUEST_INVALID", "memory influence request must be an object")
        _ensure_safe(request, "memoryInfluenceRequest")
        allowed = {"workspaceKey", "taskId", "taskInstanceId", "ownerSessionKey", "focus", "maxPerKind"}
        _card_exact_fields(request, allowed, {"workspaceKey"}, "memory influence request")
        max_per_kind = request.get("maxPerKind", MEMORY_INFLUENCE_DEFAULT_MAX_PER_KIND)
        if isinstance(max_per_kind, bool) or not isinstance(max_per_kind, int) or not 1 <= max_per_kind <= MEMORY_INFLUENCE_MAX_PER_KIND:
            raise BrainControlError(
                "BRAIN_CONTROL_MEMORY_INFLUENCE_REQUEST_INVALID",
                f"maxPerKind must be between 1 and {MEMORY_INFLUENCE_MAX_PER_KIND}",
            )
        return {
            "workspaceKey": _require_string(request.get("workspaceKey"), "workspaceKey", 120),
            "taskId": _optional_string(request.get("taskId"), "taskId", 160),
            "taskInstanceId": _optional_string(request.get("taskInstanceId"), "taskInstanceId", 80),
            "ownerSessionKey": _optional_string(request.get("ownerSessionKey"), "ownerSessionKey", 120),
            "focus": _optional_string(request.get("focus"), "focus", 480),
            "maxPerKind": max_per_kind,
        }

    @staticmethod
    def _memory_influence_scope_matches(card: Mapping[str, Any], scope: Mapping[str, Any]) -> bool:
        card_scope = card.get("scope")
        if not isinstance(card_scope, Mapping):
            return False
        scope_kind = str(card_scope.get("kind", ""))
        scope_key = str(card_scope.get("key", ""))
        if scope_kind == "global":
            # The Control Center creates user-owned cards in this durable global scope.
            return scope_key == "user"
        expected_by_kind = {
            "workspace": str(scope.get("workspaceKey", "")),
            "task": str(scope.get("taskId", "")),
            "task_instance": str(scope.get("taskInstanceId", "")),
            "session": str(scope.get("ownerSessionKey", "")),
        }
        expected = expected_by_kind.get(scope_kind, "")
        return bool(expected) and scope_key == expected

    @staticmethod
    def _memory_influence_tokens(value: str) -> set[str]:
        lowered = re.sub(r"\s+", " ", value).strip().lower()
        tokens = set(re.findall(r"[a-z0-9][a-z0-9_-]{1,}", lowered))
        for run in re.findall(r"[\u4e00-\u9fff]+", lowered):
            if len(run) <= 16:
                tokens.add(run)
            tokens.update(run[index:index + 2] for index in range(max(0, len(run) - 1)))
        return tokens

    @classmethod
    def _memory_influence_matches_focus(cls, card: Mapping[str, Any], payload: Mapping[str, Any], focus: str) -> bool:
        if not focus:
            return False
        searchable = _card_search_text(str(card.get("title", "")), payload)
        compact_focus = re.sub(r"\s+", " ", focus).strip().lower()
        compact_searchable = re.sub(r"\s+", " ", searchable).strip().lower()
        if len(compact_focus) >= 4 and compact_focus in compact_searchable:
            return True
        if len(compact_searchable) >= 4 and len(compact_searchable) <= 160 and compact_searchable in compact_focus:
            return True
        return bool(cls._memory_influence_tokens(compact_focus) & cls._memory_influence_tokens(compact_searchable))

    @staticmethod
    def _memory_influence_expired(value: Any) -> bool:
        if not isinstance(value, str) or not value.strip():
            return False
        try:
            parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        except ValueError:
            # Non-date text is a human revalidation note, not an automatic expiry.
            return False
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return parsed.astimezone(UTC) <= datetime.now(UTC)

    @staticmethod
    def _memory_influence_item(card: Mapping[str, Any], effect: str) -> dict[str, Any]:
        return {
            "cardId": str(card["cardId"]),
            "cardRevision": int(card["revision"]),
            "title": _bounded_text(card["title"], "memoryInfluence.title", 180),
            "effect": effect,
        }

    @staticmethod
    def _reflection_suggested_kind(payload: Mapping[str, Any]) -> str:
        explicit = str(payload.get("suggestedKind", "")).strip().lower()
        if explicit in NATIVE_MEMORY_LEARNING_SUGGESTED_KINDS:
            return explicit
        tags = payload.get("tags")
        suggestions: list[str] = []
        if isinstance(tags, list):
            for tag in tags:
                if not isinstance(tag, str):
                    continue
                normalized = tag.strip()
                for prefix in ("建议：", "建议:"):
                    if normalized.startswith(prefix):
                        candidate = normalized[len(prefix):].strip().lower()
                        if candidate in NATIVE_MEMORY_LEARNING_SUGGESTED_KINDS and candidate not in suggestions:
                            suggestions.append(candidate)
                        break
        return suggestions[0] if len(suggestions) == 1 else ""

    @staticmethod
    def _memory_influence_has_text_integrity_issue(card: Mapping[str, Any], payload: Mapping[str, Any]) -> bool:
        """Reject unmistakably corrupted text before it can become runtime context.

        This is deliberately narrower than presentation cleanup: a memory is
        blocked only for irreversible loss markers (replacement characters or
        a long run of literal question marks) and repeated mojibake patterns.
        The card remains governed, recoverable, and visible to its owner.
        """

        kind = str(card.get("kind", ""))
        fields_by_kind = {
            "preference": ("statement", "conditions"),
            "experience": ("context", "outcome", "lesson", "reuseConditions", "trigger", "rootCause", "prevention"),
            "note": ("body", "links"),
            "procedure": ("objective", "preconditions", "steps", "verification"),
            "reflection": ("observation", "hypothesis", "proposedAction", "evidence"),
        }
        values: list[str] = [str(card.get("title", ""))]
        for field in fields_by_kind.get(kind, ()):
            value = payload.get(field)
            if isinstance(value, str):
                values.append(value)
            elif isinstance(value, list):
                values.extend(item for item in value if isinstance(item, str))
        for value in values:
            normalized = re.sub(r"\s+", " ", value).strip()
            if "\ufffd" in normalized or re.search(r"\?{4,}", normalized):
                return True
            if re.search(r"(?:Ã.|Â.|â.|æ.|å.|ç.|ä.){4,}", normalized):
                return True
        return False

    def _current_memory_influence_cards(
        self,
        connection: sqlite3.Connection,
        scope: Mapping[str, Any],
    ) -> tuple[list[tuple[dict[str, Any], dict[str, Any]]], int]:
        selectors: list[tuple[str, str]] = [("global", "user"), ("workspace", str(scope["workspaceKey"]))]
        for scope_kind, field in (("task", "taskId"), ("task_instance", "taskInstanceId"), ("session", "ownerSessionKey")):
            value = str(scope.get(field, ""))
            if value:
                selectors.append((scope_kind, value))
        clauses = ["(c.scope_kind=? AND c.scope_key=?)" for _ in selectors]
        parameters: list[Any] = [value for pair in selectors for value in pair]
        rows = connection.execute(
            """
            SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
              r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
              r.state_json,r.created_at
            FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
            WHERE (c.lifecycle='active' OR (c.lifecycle='proposed' AND c.kind='reflection' AND c.authority='system')) AND ("""
            + " OR ".join(clauses)
            + ") ORDER BY c.updated_at DESC,c.card_id ASC LIMIT ?",
            [*parameters, MEMORY_INFLUENCE_CARD_SCAN_LIMIT],
        ).fetchall()
        valid: list[tuple[dict[str, Any], dict[str, Any]]] = []
        invalid_count = 0
        for row in rows:
            try:
                card = self._card_from_row(row)
                if _sha256(self._card_content(card)) != card["contentHash"]:
                    raise BrainControlError("BRAIN_CONTROL_CARD_CONTENT_CORRUPT", "card content hash does not match")
                payload = _normalize_card_payload(str(card["kind"]), card["payload"])
                if not self._memory_influence_scope_matches(card, scope):
                    continue
            except (BrainControlError, KeyError, TypeError, json.JSONDecodeError):
                invalid_count += 1
                continue
            valid.append((card, payload))
        return valid, invalid_count

    def _memory_influence_eligible_item(
        self,
        card: Mapping[str, Any],
        payload: Mapping[str, Any],
        *,
        native_snapshot: bool = False,
    ) -> tuple[str | None, dict[str, Any] | None, str]:
        """Project one typed card after static governance checks.

        Scope and focus matching intentionally remain with the caller: the
        SQLite execution gate has a full request scope, while the native hook
        only receives a short-lived prompt and a hash-verified hot snapshot.
        Keeping the eligibility rules here prevents those two paths from
        drifting into different memory semantics.
        """

        kind = str(card.get("kind", ""))
        if self._memory_influence_has_text_integrity_issue(card, payload):
            return None, None, "unsafe"
        if kind == "preference":
            if card.get("authority") != "user_confirmed" or payload.get("conflictState") != "clear" or int(payload.get("confidence", 0)) < 60:
                return None, None, "notReady"
            if self._memory_influence_expired(payload.get("revalidateAfter")):
                return None, None, "expired"
            return (
                "behaviorGuidance",
                {
                    **self._memory_influence_item(card, "shape_behavior"),
                    "statement": _bounded_text(payload["statement"], "preference.statement", 360),
                    "conditions": [_bounded_text(item, "preference.condition", 160) for item in payload["conditions"][:6]],
                    "confidence": int(payload["confidence"]),
                    "strength": "strong" if int(payload["confidence"]) >= 80 else "normal",
                },
                "ready",
            )
        if kind == "experience":
            if card.get("authority") != "user_confirmed" or payload.get("validationState") not in {"validated", "adopted"}:
                return None, None, "notReady"
            if self._memory_influence_expired(payload.get("revalidateAfter")):
                return None, None, "expired"
            return (
                "reusableAdvice",
                {
                    **self._memory_influence_item(card, "reuse_as_advice"),
                    "lesson": _bounded_text(payload["lesson"], "experience.lesson", 480),
                    "reuseConditions": [_bounded_text(item, "experience.reuseCondition", 160) for item in payload["reuseConditions"][:6]],
                    "prevention": _bounded_text(payload.get("prevention"), "experience.prevention", 360, required=False),
                },
                "ready",
            )
        if kind == "procedure":
            if card.get("authority") != "user_confirmed":
                return None, None, "notReady"
            return (
                "procedureSteps",
                {
                    **self._memory_influence_item(card, "follow_governed_steps"),
                    "objective": _bounded_text(payload["objective"], "procedure.objective", 360),
                    "preconditions": [_bounded_text(item, "procedure.precondition", 180) for item in payload["preconditions"][:6]],
                    "steps": [_bounded_text(item, "procedure.step", 360) for item in payload["steps"][:12]],
                    "verification": [_bounded_text(item, "procedure.verification", 180) for item in payload["verification"][:6]],
                },
                "ready",
            )
        if kind == "note":
            return (
                "references",
                {
                    **self._memory_influence_item(card, "reference_only"),
                    "body": _bounded_text(payload["body"], "note.body", 480),
                    "links": [_bounded_text(item, "note.link", 180) for item in payload["links"][:4]],
                },
                "ready",
            )
        if kind == "reflection":
            candidate_state = str(payload.get("candidateState", ""))
            # Candidate reflections remain review material.  The native prompt
            # hook only projects reviewed learning candidates and still marks
            # them non-binding below.
            blocked_states = {"candidate", "rejected", "resolved"}
            if candidate_state in blocked_states:
                return None, None, "notReady"
            return (
                "learningCandidates",
                {
                    **self._memory_influence_item(card, "learning_candidate_only"),
                    "proposedAction": _bounded_text(payload["proposedAction"], "reflection.proposedAction", 360),
                    "candidateState": candidate_state,
                    "confidence": int(payload["confidence"]),
                    "evidenceCount": len(payload["evidence"]),
                    "directConstraint": False,
                },
                "ready",
            )
        # Decisions stay receipt-bound and are deliberately absent from this
        # generic typed-memory projection.
        return None, None, "ignored"

    def _memory_influence_for_scope(
        self,
        connection: sqlite3.Connection,
        scope: Mapping[str, Any],
    ) -> dict[str, Any]:
        """Project typed active cards into their limited execution effects.

        This is deliberately a read-only boundary.  Decision enforcement remains
        owned by the receipt-bound decision context; a note or reflection can
        never become a hidden constraint merely by being returned here.
        """

        cards, invalid_count = self._current_memory_influence_cards(connection, scope)
        max_per_kind = int(scope["maxPerKind"])
        behavior_guidance: list[dict[str, Any]] = []
        reusable_advice: list[dict[str, Any]] = []
        procedure_steps: list[dict[str, Any]] = []
        references: list[dict[str, Any]] = []
        learning_candidates: list[dict[str, Any]] = []
        omitted = {"invalid": invalid_count, "expired": 0, "notReady": 0, "unsafe": 0, "unmatched": 0}
        focus = str(scope["focus"])
        targets: dict[str, list[dict[str, Any]]] = {
            "behaviorGuidance": behavior_guidance,
            "reusableAdvice": reusable_advice,
            "procedureSteps": procedure_steps,
            "references": references,
            "learningCandidates": learning_candidates,
        }

        for card, payload in cards:
            kind = str(card.get("kind", ""))
            bucket, item, state = self._memory_influence_eligible_item(card, payload)
            if item is None or bucket is None:
                if state in omitted:
                    omitted[state] += 1
                continue
            if bucket != "behaviorGuidance" and not self._memory_influence_matches_focus(card, payload, focus):
                omitted["unmatched"] += 1
                continue
            if kind == "reflection" and item is not None:
                item = {
                    **item,
                    "suggestedKind": self._reflection_suggested_kind(payload),
                    "trialEligible": bool(
                        str(card.get("scope", {}).get("kind", "")) == "task_instance"
                        and str(payload.get("candidateState", "")) in {"staged", "validated"}
                    ),
                    **self._typed_memory_trial_projection_for_card(card, scope),
                }
            target = targets[bucket]
            if len(target) >= max_per_kind:
                continue
            target.append(item)

        return {
            "ok": True,
            "schema": MEMORY_INFLUENCE_SCHEMA,
            "status": "ready",
            "scope": {
                "workspaceKey": str(scope["workspaceKey"]),
                "taskId": str(scope["taskId"]),
                "taskInstanceId": str(scope["taskInstanceId"]),
                "ownerSessionKey": str(scope["ownerSessionKey"]),
            },
            "kindEffects": {
                "note": "reference_only",
                "preference": "behavior_shaping",
                "experience": "advice_and_reuse",
                "decision": "receipt_bound_constraint",
                "procedure": "governed_steps",
                "reflection": "learning_candidate_only",
            },
            "behaviorGuidance": behavior_guidance,
            "reusableAdvice": reusable_advice,
            "procedureSteps": procedure_steps,
            "references": references,
            "learningCandidates": learning_candidates,
            "decisionHandling": {
                "effect": "receipt_bound_constraint",
                "source": "get_decision_context.constraints",
                "requiresDecisionReceipt": True,
            },
            "omitted": omitted,
            "focusStored": False,
            "rawPromptStored": False,
        }

    def get_memory_influence(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Read the current bounded effects of typed memory for one execution scope."""

        scope = self._normalize_memory_influence_request(request)
        with self._connection() as connection:
            return self._memory_influence_for_scope(connection, scope)

    @staticmethod
    def _normalize_memory_consolidation_request(request: Mapping[str, Any]) -> dict[str, Any]:
        """Validate a cold, read-only consolidation request.

        This intentionally has a smaller shape than execution-memory lookup:
        an offline review is scoped to one concrete card scope and privacy
        class, rather than to a live prompt/session context.
        """

        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_MEMORY_CONSOLIDATION_REQUEST_INVALID", "consolidation request must be an object")
        _ensure_safe(request, "memoryConsolidationRequest")
        _card_exact_fields(
            request,
            {"scope", "privacyClass", "maxProposals", "staleAfterDays"},
            {"scope"},
            "memory consolidation request",
        )
        scope = request.get("scope")
        if not isinstance(scope, Mapping):
            raise BrainControlError("BRAIN_CONTROL_MEMORY_CONSOLIDATION_SCOPE_INVALID", "scope must be an object")
        _card_exact_fields(scope, {"kind", "key"}, {"kind", "key"}, "memory consolidation scope")
        scope_kind = _require_string(scope.get("kind"), "scope.kind", 64)
        scope_key = _require_string(scope.get("key"), "scope.key", 256)
        privacy_class = _require_string(request.get("privacyClass", "private"), "privacyClass", 32)
        if privacy_class not in PRIVACY_CLASSES:
            raise BrainControlError("BRAIN_CONTROL_PRIVACY_INVALID", f"unsupported privacyClass: {privacy_class}")
        max_proposals = request.get("maxProposals", 24)
        if isinstance(max_proposals, bool) or not isinstance(max_proposals, int) or not 1 <= max_proposals <= 64:
            raise BrainControlError("BRAIN_CONTROL_MEMORY_CONSOLIDATION_PAGE_INVALID", "maxProposals must be between 1 and 64")
        stale_after_days = request.get("staleAfterDays")
        if stale_after_days is not None and (
            isinstance(stale_after_days, bool) or not isinstance(stale_after_days, int) or not 1 <= stale_after_days <= 3650
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_MEMORY_CONSOLIDATION_RETENTION_INVALID",
                "staleAfterDays must be between 1 and 3650 when supplied",
            )
        return {
            "scope": {"kind": scope_kind, "key": scope_key},
            "privacyClass": privacy_class,
            "maxProposals": max_proposals,
            "staleAfterDays": stale_after_days,
        }

    @staticmethod
    def _memory_consolidation_subject(card: Mapping[str, Any], payload: Mapping[str, Any]) -> str:
        """Build an in-process comparison subject; it is never returned or persisted."""

        fragments = [str(card.get("title", ""))]
        kind = str(card.get("kind", ""))
        fields_by_kind = {
            "preference": ("statement", "conditions"),
            "experience": ("context", "outcome", "lesson", "reuseConditions", "prevention"),
            "note": ("body", "links"),
            "procedure": ("objective", "preconditions", "steps", "verification"),
            "reflection": ("observation", "hypothesis", "proposedAction", "evidence"),
        }
        for field in fields_by_kind.get(kind, ()):
            value = payload.get(field)
            if isinstance(value, str):
                fragments.append(value)
            elif isinstance(value, list):
                fragments.extend(item for item in value if isinstance(item, str))
        return _bounded_text("\n".join(fragments), "memoryConsolidation.subject", 4_000)

    @classmethod
    def _memory_consolidation_record(
        cls,
        card: Mapping[str, Any],
        payload: Mapping[str, Any],
    ) -> dict[str, Any] | None:
        """Project only one qualified source/target into the pure planner."""

        kind = str(card.get("kind", ""))
        lifecycle = str(card.get("lifecycle", ""))
        source = ""
        suggested_kind = kind
        tags = payload.get("tags")
        tag_values = [str(item) for item in tags] if isinstance(tags, list) else []
        quick_capture = kind == "note" and lifecycle == "active" and "快速记录" in tag_values and "待学习" in tag_values
        staged_reflection = (
            kind == "reflection"
            and lifecycle == "proposed"
            and str(card.get("authority", "")) == "system"
            and str(payload.get("candidateState", "")) == "staged"
        )
        if quick_capture:
            source = "quick_capture"
            suggested_kind = cls._native_memory_learning_suggestion(payload) or "note"
        elif staged_reflection:
            source = "staged_reflection"
            suggested_kind = cls._native_memory_learning_suggestion(payload) or "reflection"
        elif lifecycle == "active" and kind in CARD_KINDS and kind != "decision":
            # A quick capture stays a candidate, never its own merge target.
            source = "current"
        else:
            return None
        scope = card.get("scope")
        if not isinstance(scope, Mapping):
            return None
        subject = cls._memory_consolidation_subject(card, payload)
        if not subject:
            return None
        return {
            "cardId": str(card["cardId"]),
            "revision": int(card["revision"]),
            "contentHash": str(card["contentHash"]),
            "kind": kind,
            "lifecycle": lifecycle,
            "authority": str(card.get("authority", "")),
            "privacyClass": str(card.get("privacyClass", "")),
            "scope": {"kind": str(scope.get("kind", "")), "key": str(scope.get("key", ""))},
            "source": source,
            "suggestedKind": suggested_kind,
            "subjectText": subject,
            "createdAt": str(card.get("createdAt", "")),
        }

    def plan_offline_memory_consolidation(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Return a privacy-bound, user-review-only memory consolidation plan.

        The database is read solely for a bounded projection.  No card, event,
        outbox item, native snapshot, task state, or hook artifact is changed.
        """

        normalized = self._normalize_memory_consolidation_request(request)
        scope = normalized["scope"]
        rows: Sequence[sqlite3.Row]
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
                  r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
                  r.state_json,r.created_at
                FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
                WHERE c.scope_kind=? AND c.scope_key=? AND c.privacy_class=?
                  AND c.lifecycle IN ('active','proposed')
                  AND c.kind IN ('preference','experience','note','procedure','reflection','decision')
                ORDER BY c.updated_at DESC,c.card_id ASC LIMIT ?
                """,
                (scope["kind"], scope["key"], normalized["privacyClass"], MEMORY_CONSOLIDATION_CARD_SCAN_LIMIT),
            ).fetchall()
        records: list[dict[str, Any]] = []
        invalid = 0
        for row in rows:
            try:
                card = self._card_from_row(row)
                if _sha256(self._card_content(card)) != card["contentHash"]:
                    raise BrainControlError("BRAIN_CONTROL_CARD_CONTENT_CORRUPT", "card content hash does not match")
                payload = _normalize_card_payload(str(card["kind"]), card["payload"])
                projected = self._memory_consolidation_record(card, payload)
                if projected is not None:
                    records.append(projected)
            except (BrainControlError, KeyError, TypeError, json.JSONDecodeError):
                invalid += 1
        result = plan_memory_consolidation(
            records,
            {**scope, "privacyClass": normalized["privacyClass"]},
            datetime.now(UTC),
            max_proposals=int(normalized["maxProposals"]),
            stale_after_days=normalized["staleAfterDays"],
        )
        omitted = result.get("omitted")
        if isinstance(omitted, dict):
            omitted["invalid"] = int(omitted.get("invalid", 0)) + invalid
            omitted["scanBounded"] = len(rows) >= MEMORY_CONSOLIDATION_CARD_SCAN_LIMIT
        return result

    def _native_memory_influence_snapshot_entries(
        self,
        connection: sqlite3.Connection,
    ) -> tuple[list[dict[str, Any]], dict[str, int], bool]:
        """Build the compact source for the prompt-hook hot read.

        This runs only on the cold, governed writer path.  The prompt hook
        never opens this SQLite database; it verifies and reads the resulting
        JSON artifact instead.
        """

        rows = connection.execute(
            """
            SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
              r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
              r.state_json,r.created_at
            FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
            WHERE (c.lifecycle='active' OR (c.lifecycle='proposed' AND c.kind='reflection' AND c.authority='system'))
              AND c.kind IN ('preference','experience','note','procedure','reflection')
            ORDER BY c.updated_at DESC,c.card_id ASC LIMIT ?
            """,
            (NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_CARDS + 1,),
        ).fetchall()
        entries: list[dict[str, Any]] = []
        omitted = {"invalid": 0, "expired": 0, "notReady": 0, "unsafe": 0}
        truncated = len(rows) > NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_CARDS
        for row in rows[:NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_CARDS]:
            try:
                card = self._card_from_row(row)
                if _sha256(self._card_content(card)) != card["contentHash"]:
                    raise BrainControlError("BRAIN_CONTROL_CARD_CONTENT_CORRUPT", "card content hash does not match")
                payload = _normalize_card_payload(str(card["kind"]), card["payload"])
                if (
                    str(card.get("kind", "")) == "reflection"
                    and str(card.get("lifecycle", "")) == "proposed"
                    and str(card.get("authority", "")) == "system"
                    and self._typed_memory_trial_projection_for_card(card).get("trialState") == "not_started"
                ):
                    # A staged system reflection becomes a native trial hint only
                    # after the guarded cold path records that it is actually
                    # being tried.  Until then it stays visible in the control
                    # center but is not injected by the hot hook.
                    omitted["notReady"] += 1
                    continue
                bucket, item, state = self._memory_influence_eligible_item(card, payload, native_snapshot=True)
                if item is None or bucket is None:
                    if state in omitted:
                        omitted[state] += 1
                    continue
                if str(card.get("kind", "")) == "reflection":
                    item = {
                        **item,
                        "suggestedKind": self._reflection_suggested_kind(payload),
                        "trialEligible": bool(
                            str(card.get("scope", {}).get("kind", "")) == "task_instance"
                            and str(payload.get("candidateState", "")) in {"staged", "validated"}
                        ),
                        **self._typed_memory_trial_projection_for_card(card),
                    }
                # This projection is intentionally narrow: no decision content,
                # prompt/focus/session input, event history, or unbounded card
                # payloads are allowed into the hot artifact.
                _ensure_safe(item, "nativeMemoryInfluenceSnapshot.item")
                scope = card["scope"]
                entries.append(
                    {
                        "kind": str(card["kind"]),
                        "bucket": bucket,
                        "scopeKind": str(scope["kind"]),
                        "scopeRef": _sha256({"scopeKey": str(scope["key"])}),
                        "item": item,
                    }
                )
            except (BrainControlError, KeyError, TypeError, json.JSONDecodeError):
                omitted["invalid"] += 1
        return entries, omitted, truncated

    def _native_memory_influence_snapshot(self) -> dict[str, Any]:
        with self._connection() as connection:
            entries, omitted, truncated = self._native_memory_influence_snapshot_entries(connection)
        body = {
            "schema": NATIVE_MEMORY_INFLUENCE_SNAPSHOT_SCHEMA,
            "generatedAt": _utc_now(),
            "entryCount": len(entries),
            "entries": entries,
            "omitted": omitted,
            "truncated": truncated,
            "scopeRefAlgorithm": "sha256(canonical-json:{scopeKey})",
            "activeOnly": True,
            "stagedReflectionProjection": True,
            "decisionConstraintsStored": False,
            "focusStored": False,
            "rawPromptStored": False,
            "rawSessionIdStored": False,
        }
        encoded = _canonical_json(body).encode("utf-8")
        if len(encoded) > NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_BYTES:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_SNAPSHOT_TOO_LARGE",
                "native memory influence snapshot exceeds its bounded size",
            )
        return {**body, "payloadHash": _sha256(body)}

    def _mark_native_memory_influence_snapshot_dirty(self) -> bool:
        path = self.native_memory_influence_snapshot_dirty_path
        already_dirty = path.exists()
        self._write_json_atomic(
            path,
            {
                "schema": NATIVE_MEMORY_INFLUENCE_SNAPSHOT_DIRTY_SCHEMA,
                "invalidatedAt": _utc_now(),
                "reason": "governed_card_mutation",
                "rawPromptStored": False,
                "rawSessionIdStored": False,
            },
            "BRAIN_CONTROL_NATIVE_MEMORY_SNAPSHOT_DIRTY_WRITE_FAILED",
        )
        return not already_dirty

    def _clear_native_memory_influence_snapshot_dirty(self) -> None:
        try:
            self.native_memory_influence_snapshot_dirty_path.unlink()
        except FileNotFoundError:
            return
        except OSError as exc:
            raise BrainControlError("BRAIN_CONTROL_NATIVE_MEMORY_SNAPSHOT_DIRTY_CLEAR_FAILED", str(exc)) from exc

    def publish_native_memory_influence_snapshot(self) -> dict[str, Any]:
        """Publish and verify the only memory source allowed on the hot hook path."""

        snapshot = self._native_memory_influence_snapshot()
        destination = self.native_memory_influence_snapshot_path
        self._write_json_atomic(
            destination,
            snapshot,
            "BRAIN_CONTROL_NATIVE_MEMORY_SNAPSHOT_WRITE_FAILED",
        )
        try:
            raw = destination.read_bytes()
            verified = json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BrainControlError("BRAIN_CONTROL_NATIVE_MEMORY_SNAPSHOT_VERIFY_FAILED", "native memory snapshot is unreadable") from exc
        if (
            not isinstance(verified, Mapping)
            or len(raw) > NATIVE_MEMORY_INFLUENCE_SNAPSHOT_MAX_BYTES
            or verified.get("schema") != NATIVE_MEMORY_INFLUENCE_SNAPSHOT_SCHEMA
            or verified.get("payloadHash") != snapshot["payloadHash"]
            or _sha256({key: value for key, value in verified.items() if key != "payloadHash"}) != verified.get("payloadHash")
        ):
            raise BrainControlError("BRAIN_CONTROL_NATIVE_MEMORY_SNAPSHOT_VERIFY_FAILED", "native memory snapshot verification failed")
        self._clear_native_memory_influence_snapshot_dirty()
        return {
            "ok": True,
            "schema": NATIVE_MEMORY_INFLUENCE_SNAPSHOT_SCHEMA,
            "path": str(destination),
            "payloadHash": str(snapshot["payloadHash"]),
            "entryCount": len(snapshot["entries"]),
            "truncated": bool(snapshot["truncated"]),
        }

    def _refresh_native_memory_influence_snapshot_after_mutation(self) -> None:
        # The committed card transaction stays authoritative even if a derived
        # cache cannot be regenerated.  Leaving the dirty marker in place makes
        # the prompt hook fail closed until a later governed refresh succeeds.
        try:
            self.publish_native_memory_influence_snapshot()
        except BrainControlError:
            return

    @staticmethod
    def _native_prompt_hook_telemetry_scope(
        workspace_key: str,
        owner_session_key: str,
    ) -> tuple[str, str]:
        """Accept only the normalized, non-reversible scope keys written by the hook."""

        workspace = _require_string(workspace_key, "workspaceKey", 120).lower()
        session = _require_string(owner_session_key, "ownerSessionKey", 120).lower()
        if not re.fullmatch(r"ws-[0-9a-f]{24}", workspace):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_SCOPE_INVALID",
                "workspaceKey is not a native prompt-hook workspace key",
            )
        if not re.fullmatch(r"sid-[0-9a-f]{16,64}", session):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_SCOPE_INVALID",
                "ownerSessionKey is not a native prompt-hook session key",
            )
        return workspace, session

    def _normalize_native_memory_learning_candidate_request(self, request: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_REQUEST_INVALID",
                "native memory learning request must be an object",
            )
        _ensure_safe(request, "nativeMemoryLearningRequest")
        _card_exact_fields(
            request,
            {"workspaceKey", "ownerSessionKey", "taskId", "taskInstanceId", "maxAgeMinutes"},
            {"workspaceKey", "ownerSessionKey", "taskId"},
            "native memory learning request",
        )
        workspace_key, owner_session_key = self._native_prompt_hook_telemetry_scope(
            _require_string(request.get("workspaceKey"), "workspaceKey", 120),
            _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 120),
        )
        max_age_minutes = request.get("maxAgeMinutes", NATIVE_MEMORY_LEARNING_CANDIDATE_MAX_AGE_MINUTES)
        if (
            isinstance(max_age_minutes, bool)
            or not isinstance(max_age_minutes, int)
            or not 1 <= max_age_minutes <= 24 * 60
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_AGE_INVALID",
                "maxAgeMinutes must be between 1 and 1440",
            )
        return {
            "workspaceKey": workspace_key,
            "ownerSessionKey": owner_session_key,
            "taskId": _require_string(request.get("taskId"), "taskId", 160),
            "taskInstanceId": _optional_string(request.get("taskInstanceId"), "taskInstanceId", 80),
            "maxAgeMinutes": max_age_minutes,
        }

    def _native_prompt_hook_telemetry_path(self, workspace_key: str, owner_session_key: str) -> Path:
        return (
            self.workspace
            / "runtime-state"
            / "prompt-hook-telemetry"
            / f"{owner_session_key}--{workspace_key}.json"
        )

    @staticmethod
    def _native_prompt_hook_injected_note_refs(value: Any) -> list[dict[str, Any]]:
        if not isinstance(value, list) or not value or len(value) > 5:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native telemetry has no bounded injected card references",
            )
        notes: list[dict[str, Any]] = []
        seen: set[tuple[str, int, str]] = set()
        for entry in value:
            if not isinstance(entry, Mapping):
                raise BrainControlError(
                    "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                    "native telemetry injected card reference is invalid",
                )
            _card_exact_fields(entry, {"cardId", "cardRevision", "kind"}, {"cardId", "cardRevision", "kind"}, "native telemetry injected card reference")
            card_id = _require_string(entry.get("cardId"), "injectedCard.cardId", 160)
            revision = entry.get("cardRevision")
            kind = _require_string(entry.get("kind"), "injectedCard.kind", 64).lower()
            if isinstance(revision, bool) or not isinstance(revision, int) or revision < 1 or kind not in CARD_KINDS:
                raise BrainControlError(
                    "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                    "native telemetry injected card reference is invalid",
                )
            identity = (card_id, revision, kind)
            if identity in seen:
                raise BrainControlError(
                    "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                    "native telemetry repeats an injected card reference",
                )
            seen.add(identity)
            if kind == "note":
                notes.append({"cardId": card_id, "cardRevision": revision, "kind": kind})
        return notes

    @staticmethod
    def _native_memory_learning_suggestion(note_payload: Mapping[str, Any]) -> str:
        tags = note_payload.get("tags")
        if not isinstance(tags, list) or "待学习" not in tags:
            return ""
        suggestions: list[str] = []
        for tag in tags:
            if not isinstance(tag, str):
                continue
            normalized = tag.strip()
            for prefix in ("建议：", "建议:"):
                if normalized.startswith(prefix):
                    suggestion = normalized[len(prefix) :].strip().lower()
                    if suggestion in NATIVE_MEMORY_LEARNING_SUGGESTED_KINDS and suggestion not in suggestions:
                        suggestions.append(suggestion)
                    break
        if len(suggestions) != 1:
            return ""
        return suggestions[0]

    @staticmethod
    def _normalize_h7_memory_learning_candidate_request(request: Mapping[str, Any]) -> dict[str, Any]:
        """Accept only compact, receipt-bound H7 learning evidence."""

        if not isinstance(request, Mapping):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_REQUEST_INVALID",
                "H7 memory learning request must be an object",
            )
        _ensure_safe(request, "h7MemoryLearningRequest")
        _card_exact_fields(
            request,
            {
                "workspaceKey",
                "ownerSessionKey",
                "taskId",
                "taskInstanceId",
                "scopeRef",
                "entryReceiptHash",
                "telemetryHash",
                "typedMemoryRefsHash",
                "maxAgeMinutes",
            },
            {
                "workspaceKey",
                "ownerSessionKey",
                "taskId",
                "taskInstanceId",
                "scopeRef",
                "entryReceiptHash",
                "telemetryHash",
                "typedMemoryRefsHash",
            },
            "H7 memory learning request",
        )
        workspace_key = _require_string(request.get("workspaceKey"), "workspaceKey", 120).lower()
        owner_session_key = _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 120).lower()
        if re.fullmatch(r"ws-[0-9a-f]{24}", workspace_key) is None:
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_SCOPE_INVALID",
                "workspaceKey is not an H7 workspace key",
            )
        if re.fullmatch(r"sid-[0-9a-f]{16,64}", owner_session_key) is None:
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_SCOPE_INVALID",
                "ownerSessionKey is not an H7 owner session key",
            )
        max_age_minutes = request.get("maxAgeMinutes", NATIVE_MEMORY_LEARNING_CANDIDATE_MAX_AGE_MINUTES)
        if (
            isinstance(max_age_minutes, bool)
            or not isinstance(max_age_minutes, int)
            or not 1 <= max_age_minutes <= 24 * 60
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_AGE_INVALID",
                "maxAgeMinutes must be between 1 and 1440",
            )
        return {
            "workspaceKey": workspace_key,
            "ownerSessionKey": owner_session_key,
            "taskId": _require_string(request.get("taskId"), "taskId", 160),
            "taskInstanceId": _require_string(request.get("taskInstanceId"), "taskInstanceId", 80),
            "scopeRef": _require_sha256(request.get("scopeRef"), "scopeRef"),
            "entryReceiptHash": _require_sha256(request.get("entryReceiptHash"), "entryReceiptHash"),
            "telemetryHash": _require_sha256(request.get("telemetryHash"), "telemetryHash"),
            "typedMemoryRefsHash": _require_sha256(request.get("typedMemoryRefsHash"), "typedMemoryRefsHash"),
            "maxAgeMinutes": max_age_minutes,
        }

    @staticmethod
    def _read_h7_memory_learning_json(path: Path, code: str) -> dict[str, Any]:
        try:
            raw = path.read_bytes()
            if not raw or len(raw) > 128 * 1024:
                raise ValueError("bounded H7 evidence is missing or oversized")
            value = json.loads(raw.decode("utf-8-sig"))
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            raise BrainControlError(code, "current H7 evidence is unavailable or invalid") from exc
        if not isinstance(value, dict):
            raise BrainControlError(code, "current H7 evidence is not an object")
        return value

    @staticmethod
    def _h7_memory_learning_refs(value: Any) -> list[dict[str, Any]]:
        if not isinstance(value, list) or not value or len(value) > 8:
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_NO_TYPED_MEMORY",
                "H7 receipt has no bounded typed-memory references",
            )
        refs: list[dict[str, Any]] = []
        seen: set[tuple[str, int]] = set()
        for raw_ref in value:
            if not isinstance(raw_ref, str) or len(raw_ref) > 200:
                raise BrainControlError(
                    "BRAIN_CONTROL_H7_MEMORY_LEARNING_RECEIPT_INVALID",
                    "H7 typed-memory reference is invalid",
                )
            card_id, separator, revision_text = raw_ref.rpartition("@")
            if not separator:
                raise BrainControlError(
                    "BRAIN_CONTROL_H7_MEMORY_LEARNING_RECEIPT_INVALID",
                    "H7 typed-memory reference is invalid",
                )
            card_id = _require_string(card_id, "typedMemory.cardId", 160)
            try:
                revision = int(revision_text)
            except (TypeError, ValueError) as exc:
                raise BrainControlError(
                    "BRAIN_CONTROL_H7_MEMORY_LEARNING_RECEIPT_INVALID",
                    "H7 typed-memory reference revision is invalid",
                ) from exc
            if revision < 1 or (card_id, revision) in seen:
                raise BrainControlError(
                    "BRAIN_CONTROL_H7_MEMORY_LEARNING_RECEIPT_INVALID",
                    "H7 typed-memory references are invalid or repeated",
                )
            seen.add((card_id, revision))
            refs.append({"cardId": card_id, "cardRevision": revision})
        return refs

    def _read_h7_memory_learning_evidence(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Reverify current H7 evidence without reading Hook/P7 state."""

        scope_ref = _sha256(
            {
                "workspaceKey": str(request["workspaceKey"]),
                "ownerSessionKey": str(request["ownerSessionKey"]),
                "taskId": str(request["taskId"]),
                "taskInstanceId": str(request["taskInstanceId"]),
            }
        )
        if scope_ref != str(request["scopeRef"]):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_SCOPE_MISMATCH",
                "the supplied H7 scope does not match the current task scope",
            )
        receipt_root = self.workspace / "runtime-state" / "turn-runtime" / "receipts" / scope_ref
        receipt = self._read_h7_memory_learning_json(
            receipt_root / "open.json",
            "BRAIN_CONTROL_H7_MEMORY_LEARNING_OPEN_RECEIPT_UNAVAILABLE",
        )
        if (
            receipt.get("schema") != H7_TURN_RUNTIME_RECEIPT_SCHEMA
            or receipt.get("mode") != "hookless_turn_runtime"
            or receipt.get("phase") != "open"
            or receipt.get("rawPromptStored") is not False
            or receipt.get("rawTranscriptStored") is not False
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_RECEIPT_INVALID",
                "H7 open receipt is not a safe hookless receipt",
            )
        receipt_hash = _require_sha256(receipt.get("receiptHash"), "h7OpenReceipt.receiptHash")
        if receipt_hash != _sha256({key: value for key, value in receipt.items() if key != "receiptHash"}):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_RECEIPT_INVALID",
                "H7 open receipt hash does not match",
            )
        if receipt_hash != str(request["entryReceiptHash"]):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_ENTRY_STALE",
                "the supplied H7 entry receipt is no longer current",
            )
        issued_at = _parse_utc_timestamp(receipt.get("issuedAt"))
        if (
            issued_at is None
            or issued_at > datetime.now(UTC) + timedelta(minutes=5)
            or datetime.now(UTC) - issued_at > timedelta(minutes=int(request["maxAgeMinutes"]))
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_ENTRY_STALE",
                "H7 open receipt is not current enough for learning capture",
            )
        scope = receipt.get("scope")
        if not isinstance(scope, Mapping) or (
            str(scope.get("workspaceKey", "")).lower() != str(request["workspaceKey"])
            or str(scope.get("scopeRef", "")) != scope_ref
            or str(scope.get("taskId", "")) != str(request["taskId"])
            or str(scope.get("taskInstanceId", "")) != str(request["taskInstanceId"])
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_SCOPE_MISMATCH",
                "H7 open receipt belongs to a different task scope",
            )

        index_path = self.workspace / "runtime-state" / "execution-hot-index" / f"{request['ownerSessionKey']}--{request['workspaceKey']}.json"
        index = self._read_h7_memory_learning_json(
            index_path,
            "BRAIN_CONTROL_H7_MEMORY_LEARNING_CONTRACT_UNAVAILABLE",
        )
        entries = index.get("entries") if isinstance(index.get("entries"), list) else []
        matching_entries = [
            item
            for item in entries
            if isinstance(item, Mapping)
            and str(item.get("status", "")) == "active"
            and str(item.get("taskId", "")) == str(request["taskId"])
            and (
                not str(item.get("taskInstanceId", ""))
                or str(item.get("taskInstanceId", "")) == str(request["taskInstanceId"])
            )
            and str(item.get("workspaceKey", "")).lower() == str(request["workspaceKey"])
            and str(item.get("ownerSessionKey", "")).lower() == str(request["ownerSessionKey"])
        ]
        if index.get("schema") != "super-brain.execution-hot-index.v1" or len(matching_entries) != 1:
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_CONTRACT_STALE",
                "there is no unique current H7 execution contract for this task",
            )
        entry = matching_entries[0]
        contract_file_name = Path(str(entry.get("contractFileName", ""))).name
        if not contract_file_name or contract_file_name != str(entry.get("contractFileName", "")):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_CONTRACT_INVALID",
                "H7 contract file identity is invalid",
            )
        contract = self._read_h7_memory_learning_json(
            self.workspace / "runtime-state" / "execution-contracts" / contract_file_name,
            "BRAIN_CONTROL_H7_MEMORY_LEARNING_CONTRACT_UNAVAILABLE",
        )
        contract_hash = _sha256(contract)
        contract_binding = receipt.get("contract")
        if (
            contract.get("schema") != "super-brain.execution-contract.v1"
            or str(contract.get("status", "")) != "active"
            or contract.get("needsReconciliation") is True
            or str(contract.get("taskId", "")) != str(request["taskId"])
            or str(contract.get("taskInstanceId", "")) != str(request["taskInstanceId"])
            or str(contract.get("workspaceKey", "")).lower() != str(request["workspaceKey"])
            or str(contract.get("ownerSessionKey", "")).lower() != str(request["ownerSessionKey"])
            or not isinstance(contract_binding, Mapping)
            or str(contract_binding.get("stateHash", "")) != contract_hash
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_CONTRACT_STALE",
                "H7 open receipt does not bind the current execution contract",
            )
        try:
            entry_revision = int(entry.get("revision", -1))
            contract_revision = int(contract.get("revision", -2))
            receipt_revision = int(contract_binding.get("revision", -3))
        except (TypeError, ValueError) as exc:
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_CONTRACT_INVALID",
                "H7 contract revision is invalid",
            ) from exc
        if entry_revision != contract_revision or receipt_revision != contract_revision:
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_CONTRACT_STALE",
                "H7 execution contract revision changed",
            )

        memory = receipt.get("memory")
        if not isinstance(memory, Mapping):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_RECEIPT_INVALID",
                "H7 open receipt has no typed-memory binding",
            )
        raw_refs = memory.get("refs")
        refs = self._h7_memory_learning_refs(raw_refs)
        refs_hash = _require_sha256(memory.get("refsHash"), "h7OpenReceipt.memory.refsHash")
        if refs_hash != _sha256(raw_refs) or refs_hash != str(request["typedMemoryRefsHash"]):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_TYPED_MEMORY_STALE",
                "H7 typed-memory references do not match the current evidence",
            )
        if not _require_sha256(memory.get("payloadHash"), "h7OpenReceipt.memory.payloadHash"):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_NO_TYPED_MEMORY",
                "H7 open receipt did not bind typed-memory content",
            )
        activation = receipt.get("activation")
        core_rules = receipt.get("coreRules")
        if (
            not isinstance(activation, Mapping)
            or not _require_sha256(activation.get("receiptHash"), "h7OpenReceipt.activation.receiptHash")
            or str(activation.get("state", "")) != "full_brain_active"
            or not isinstance(core_rules, Mapping)
            or str(core_rules.get("status", "")) != "current"
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_ACTIVATION_INVALID",
                "H7 activation or core rules are not current",
            )

        telemetry = self._read_h7_memory_learning_json(
            self.workspace / "runtime-state" / "turn-runtime" / "telemetry" / f"{scope_ref}.json",
            "BRAIN_CONTROL_H7_MEMORY_LEARNING_TELEMETRY_UNAVAILABLE",
        )
        telemetry_hash = _require_sha256(telemetry.get("payloadHash"), "h7Telemetry.payloadHash")
        if (
            telemetry.get("schema") != H7_TURN_RUNTIME_TELEMETRY_SCHEMA
            or telemetry.get("mode") != "hookless_turn_runtime"
            or str(telemetry.get("scopeRef", "")) != scope_ref
            or telemetry.get("rawPromptStored") is not False
            or telemetry.get("rawTranscriptStored") is not False
            or telemetry_hash != _sha256({key: value for key, value in telemetry.items() if key != "payloadHash"})
            or telemetry_hash != str(request["telemetryHash"])
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_TELEMETRY_INVALID",
                "H7 telemetry is invalid or no longer current",
            )
        telemetry_updated = _parse_utc_timestamp(telemetry.get("updatedAt"))
        if (
            telemetry_updated is None
            or telemetry_updated > datetime.now(UTC) + timedelta(minutes=5)
            or datetime.now(UTC) - telemetry_updated > timedelta(minutes=int(request["maxAgeMinutes"]))
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_TELEMETRY_STALE",
                "H7 telemetry is not current enough for learning capture",
            )
        events = telemetry.get("events")
        latest_event = events[-1] if isinstance(events, list) and events and isinstance(events[-1], Mapping) else None
        if (
            latest_event is None
            or str(latest_event.get("receiptHash", "")) != receipt_hash
            or str(latest_event.get("contractStateHash", "")) != contract_hash
            or str(latest_event.get("memoryRefsHash", "")) != refs_hash
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_TELEMETRY_STALE",
                "H7 telemetry does not bind the current open receipt",
            )
        return {
            "scopeRef": scope_ref,
            "entryReceiptHash": receipt_hash,
            "telemetryHash": telemetry_hash,
            "typedMemoryRefsHash": refs_hash,
            "refs": refs,
        }

    def record_h7_memory_learning_candidate(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Stage one non-binding reflection from verified H7 typed-memory evidence."""

        normalized_request = self._normalize_h7_memory_learning_candidate_request(request)
        evidence = self._read_h7_memory_learning_evidence(normalized_request)
        scope_for_note = {
            "workspaceKey": normalized_request["workspaceKey"],
            "taskId": normalized_request["taskId"],
            "taskInstanceId": normalized_request["taskInstanceId"],
            "ownerSessionKey": normalized_request["ownerSessionKey"],
        }
        dirty_marker_created = self._mark_native_memory_influence_snapshot_dirty()
        applied: dict[str, Any] | None = None
        source_card_id = ""
        source_revision = 0
        suggestion = ""
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    source_card: dict[str, Any] | None = None
                    for note_ref in evidence["refs"]:
                        row = connection.execute(
                            "SELECT head_revision,lifecycle FROM cards WHERE card_id=?", (note_ref["cardId"],)
                        ).fetchone()
                        if row is None or int(row["head_revision"]) != int(note_ref["cardRevision"]) or str(row["lifecycle"]) != "active":
                            continue
                        candidate = self._read_card_revision(connection, str(note_ref["cardId"]), int(note_ref["cardRevision"]))
                        if candidate.get("kind") != "note" or not self._memory_influence_scope_matches(candidate, scope_for_note):
                            continue
                        payload = candidate.get("payload")
                        if not isinstance(payload, Mapping):
                            continue
                        found_suggestion = self._native_memory_learning_suggestion(payload)
                        if not found_suggestion:
                            continue
                        source_card = candidate
                        suggestion = found_suggestion
                        break
                    if source_card is None:
                        raise BrainControlError(
                            "BRAIN_CONTROL_H7_MEMORY_LEARNING_NOTE_INELIGIBLE",
                            "no active H7 typed-memory note is tagged as a learning candidate",
                        )
                    source_card_id = str(source_card["cardId"])
                    source_revision = int(source_card["revision"])
                    if suggestion == "note":
                        connection.execute("COMMIT")
                        if dirty_marker_created:
                            self._clear_native_memory_influence_snapshot_dirty()
                        return {
                            "ok": True,
                            "schema": H7_MEMORY_LEARNING_CANDIDATE_SCHEMA,
                            "status": "not_applicable",
                            "code": "BRAIN_CONTROL_H7_MEMORY_LEARNING_NO_ENRICHMENT_NEEDED",
                            "candidate": None,
                            "source": {"cardId": source_card_id, "cardRevision": source_revision, "suggestedKind": suggestion},
                            "h7Evidence": {key: evidence[key] for key in ("scopeRef", "entryReceiptHash", "telemetryHash", "typedMemoryRefsHash")},
                            "rawPromptStored": False,
                            "rawTranscriptStored": False,
                            "memoryBodyStored": False,
                        }
                    candidate_id = "reflection-h7-use-" + _sha256(
                        {
                            "workspaceKey": normalized_request["workspaceKey"],
                            "ownerSessionKey": normalized_request["ownerSessionKey"],
                            "taskId": normalized_request["taskId"],
                            "taskInstanceId": normalized_request["taskInstanceId"],
                            "entryReceiptHash": evidence["entryReceiptHash"],
                            "telemetryHash": evidence["telemetryHash"],
                            "typedMemoryRefsHash": evidence["typedMemoryRefsHash"],
                            "sourceCardId": source_card_id,
                            "sourceRevision": source_revision,
                        }
                    )[:40]
                    kind_label = NATIVE_MEMORY_LEARNING_KIND_LABELS[suggestion]
                    evidence_refs = [
                        f"h7-open-receipt-sha256:{evidence['entryReceiptHash']}",
                        f"h7-turn-runtime-telemetry-sha256:{evidence['telemetryHash']}",
                        f"h7-typed-memory-refs-sha256:{evidence['typedMemoryRefsHash']}",
                        f"memory-card:{source_card_id}@{source_revision}",
                    ]
                    command = {
                        "commandType": "create_card",
                        "commandId": "h7-memory-learning-" + candidate_id,
                        "aggregateId": candidate_id,
                        "expectedRevision": 0,
                        "kind": "reflection",
                        "scope": {"kind": "task_instance", "key": normalized_request["taskInstanceId"]},
                        "lifecycle": "proposed",
                        "authority": "system",
                        "privacyClass": str(source_card["privacyClass"]),
                        "title": f"Pending learning: {kind_label}",
                        "payload": {
                            "schema": "super-brain.card.reflection.v1",
                            "observation": "A current H7 typed-memory note reference was used by the active task.",
                            "hypothesis": f"The source note may be suitable for a {kind_label} record, pending user adoption.",
                            "proposedAction": f"Review whether to adopt the source note as {kind_label}; adoption is required before any behavior changes.",
                            "evidence": evidence_refs,
                            "confidence": 35,
                            "candidateState": "staged",
                            "suggestedKind": suggestion,
                            "tags": ["system-learning-candidate", "non-binding", "awaiting-user-adoption", "suggested:" + suggestion, "h7-turn-runtime"],
                        },
                        "evidenceRefs": evidence_refs,
                        "actorReceipt": {
                            "schema": ACTOR_RECEIPT_SCHEMA,
                            "actorKind": "system",
                            "actorId": "h7_memory_learning_capture",
                            "authorization": "system",
                            "authorizationReceipt": evidence["entryReceiptHash"],
                        },
                        "reason": "Create a non-binding learning candidate from current H7 typed-memory evidence.",
                        "source": "h7_memory_learning_capture",
                    }
                    normalized_command = self._validate_command(command)
                    applied = self._apply_in_transaction(connection, normalized_command, _sha256(normalized_command))
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
        except Exception:
            if dirty_marker_created:
                self._clear_native_memory_influence_snapshot_dirty()
            raise
        if applied is None:
            if dirty_marker_created:
                self._clear_native_memory_influence_snapshot_dirty()
            raise BrainControlError(
                "BRAIN_CONTROL_H7_MEMORY_LEARNING_INTERNAL",
                "H7 memory learning candidate was not created",
            )
        if applied.get("idempotent") is not True:
            self._refresh_native_memory_influence_snapshot_after_mutation()
        elif dirty_marker_created:
            self._clear_native_memory_influence_snapshot_dirty()
        return {
            "ok": True,
            "schema": H7_MEMORY_LEARNING_CANDIDATE_SCHEMA,
            "status": "reused" if applied.get("idempotent") is True else "captured",
            "code": "BRAIN_CONTROL_H7_MEMORY_LEARNING_CANDIDATE_REUSED" if applied.get("idempotent") is True else "BRAIN_CONTROL_H7_MEMORY_LEARNING_CANDIDATE_CAPTURED",
            "candidate": {
                "cardId": str(applied["aggregateId"]),
                "cardRevision": int(applied["revision"]),
                "kind": "reflection",
                "lifecycle": "proposed",
                "candidateState": "staged",
                "directConstraint": False,
            },
            "source": {"cardId": source_card_id, "cardRevision": source_revision, "suggestedKind": suggestion},
            "h7Evidence": {key: evidence[key] for key in ("scopeRef", "entryReceiptHash", "telemetryHash", "typedMemoryRefsHash")},
            "rawPromptStored": False,
            "rawTranscriptStored": False,
            "memoryBodyStored": False,
        }

    def _read_native_prompt_hook_telemetry(self, request: Mapping[str, Any]) -> tuple[dict[str, Any], str, list[dict[str, Any]], dict[str, Any]]:
        """Verify the bounded hook receipt without reading a prompt or card body."""

        path = self._native_prompt_hook_telemetry_path(str(request["workspaceKey"]), str(request["ownerSessionKey"]))
        try:
            raw = path.read_bytes()
            telemetry = json.loads(raw.decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_UNAVAILABLE",
                "current native prompt-hook telemetry is unavailable",
            ) from exc
        if not isinstance(telemetry, Mapping):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook telemetry is invalid",
            )
        legacy_allowed = {
            "ok", "schema", "checkedAt", "promptHash", "promptLength", "rawPromptStored", "testObservationOnly",
            "candidate", "routeTier", "routeSignalMode", "durationMs", "phaseMs", "runtimeWake",
            "executionContractCapture", "deliveryProvenance", "handlerProvenance", "dispatcherLaunch", "p7Diagnostic",
            "scope", "activation", "rawSessionIdStored", "payloadHash",
        }
        allowed = legacy_allowed | {"superBrainIssue"}
        telemetry_fields = set(telemetry)
        if telemetry_fields != legacy_allowed and telemetry_fields != allowed:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook telemetry fields are not the governed schema",
            )
        issue = telemetry.get("superBrainIssue")
        if issue is not None:
            issue_fields = {
                "detected", "problemNature", "rootCauseState", "responseOrder", "repairMode", "repairScope",
                "learningClass", "learningKey", "rawPromptStored",
            }
            if (
                not isinstance(issue, Mapping)
                or set(issue) != issue_fields
                or not isinstance(issue.get("detected"), bool)
                or issue.get("problemNature") not in {"execution_continuity", "hook_transport", "memory_recall_effect", "ui_projection", "health_status", "unknown"}
                or issue.get("rootCauseState") not in {"evidence_required", "not_applicable"}
                or issue.get("responseOrder") != "essence>evidence>repair>next"
                or issue.get("repairMode") not in {"not_applicable", "plan_for_approval", "diagnose_and_repair"}
                or issue.get("repairScope") not in {"current_authorized_local_scope", "governed_scope_check_required"}
                or issue.get("learningClass") not in {"task_memory", "experience", "execution_rule", "user_preference", "system_rule"}
                or not isinstance(issue.get("learningKey"), str)
                or len(str(issue.get("learningKey"))) > 96
                or issue.get("rawPromptStored") is not False
            ):
                raise BrainControlError(
                    "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                    "native prompt-hook Super Brain issue protocol is invalid",
                )
        activation = telemetry.get("activation")
        if not isinstance(activation, Mapping) or set(activation) != {
            "state", "activationId", "receiptHash", "scopeRef", "coreReady", "actionAuthorization", "rawPromptStored",
        }:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook activation proof is invalid",
            )
        if (
            activation.get("state") not in {"full_brain_active", "withheld", "failed"}
            or not isinstance(activation.get("activationId"), str)
            or len(str(activation.get("activationId"))) > 96
            or not isinstance(activation.get("receiptHash"), str)
            or (activation.get("receiptHash") and re.fullmatch(r"[a-f0-9]{64}", str(activation.get("receiptHash"))) is None)
            or not isinstance(activation.get("scopeRef"), str)
            or (activation.get("scopeRef") and re.fullmatch(r"[a-f0-9]{64}", str(activation.get("scopeRef"))) is None)
            or not isinstance(activation.get("coreReady"), bool)
            or activation.get("actionAuthorization") not in {"allowed", "withheld", "not_applicable"}
            or activation.get("rawPromptStored") is not False
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook activation proof is unsafe",
            )
        supplied_hash = _require_sha256(telemetry.get("payloadHash"), "telemetry.payloadHash")
        body = {key: value for key, value in telemetry.items() if key != "payloadHash"}
        if _sha256(body) != supplied_hash:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook telemetry hash does not match",
            )
        dispatcher_launch = telemetry.get("dispatcherLaunch")
        if not isinstance(dispatcher_launch, Mapping) or set(dispatcher_launch) != {
            "schema", "launchId", "launchIdValid", "desktopCommandChainVerified", "hostProcessSource",
            "rawPromptStored", "rawSessionIdStored", "memoryBodyStored",
        }:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook dispatcher link is invalid",
            )
        launch_id = dispatcher_launch.get("launchId")
        launch_id_valid = dispatcher_launch.get("launchIdValid")
        command_chain_verified = dispatcher_launch.get("desktopCommandChainVerified")
        host_process_source = dispatcher_launch.get("hostProcessSource")
        if (
            dispatcher_launch.get("schema") != "super-brain.prompt-hook-dispatch-link.v1"
            or not isinstance(launch_id, str)
            or not isinstance(launch_id_valid, bool)
            or launch_id_valid != bool(re.fullmatch(r"[a-f0-9]{32}", launch_id))
            or not isinstance(command_chain_verified, bool)
            or host_process_source not in {"desktop_windows_command_chain", "unverified"}
            or (command_chain_verified and host_process_source != "desktop_windows_command_chain")
            or (not command_chain_verified and host_process_source != "unverified")
            or dispatcher_launch.get("rawPromptStored") is not False
            or dispatcher_launch.get("rawSessionIdStored") is not False
            or dispatcher_launch.get("memoryBodyStored") is not False
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook dispatcher link is unsafe",
            )
        p7_diagnostic = telemetry.get("p7Diagnostic")
        if not isinstance(p7_diagnostic, Mapping) or set(p7_diagnostic) != {"armId", "scopeRef"}:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook P7 diagnostic link is invalid",
            )
        arm_id = p7_diagnostic.get("armId")
        scope_ref = p7_diagnostic.get("scopeRef")
        if (
            not isinstance(arm_id, str)
            or not isinstance(scope_ref, str)
            or bool(arm_id) != bool(scope_ref)
            or (arm_id and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}", arm_id) is None)
            or (scope_ref and re.fullmatch(r"[a-f0-9]{64}", scope_ref) is None)
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook P7 diagnostic link is unsafe",
            )
        _ensure_safe(body, "nativePromptHookTelemetry")
        if (
            telemetry.get("schema") != NATIVE_PROMPT_HOOK_TELEMETRY_SCHEMA
            or telemetry.get("ok") is not True
            or telemetry.get("candidate") is not True
            or telemetry.get("routeSignalMode") != "native"
            or telemetry.get("rawPromptStored") is not False
            or telemetry.get("rawSessionIdStored") is not False
            or telemetry.get("testObservationOnly") is not False
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook telemetry is not an eligible live capture",
            )
        checked_at = _parse_utc_timestamp(telemetry.get("checkedAt"))
        if checked_at is None or checked_at > datetime.now(UTC) + timedelta(minutes=5) or datetime.now(UTC) - checked_at > timedelta(minutes=int(request["maxAgeMinutes"])):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_STALE",
                "native prompt-hook telemetry is not current",
            )
        scope = telemetry.get("scope")
        if not isinstance(scope, Mapping) or set(scope) != {"workspaceKey", "ownerSessionKey", "taskId"}:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook telemetry scope is invalid",
            )
        if (
            str(scope.get("workspaceKey", "")).lower() != str(request["workspaceKey"])
            or str(scope.get("ownerSessionKey", "")).lower() != str(request["ownerSessionKey"])
            or str(scope.get("taskId", "")) != str(request["taskId"])
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_SCOPE_STALE",
                "native prompt-hook telemetry belongs to a different active task scope",
            )
        provenance = telemetry.get("deliveryProvenance")
        if not isinstance(provenance, Mapping):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook delivery provenance is invalid",
            )
        origin = str(provenance.get("origin", ""))
        input_mode = str(provenance.get("inputMode", ""))
        if origin == "synthetic_cli" or input_mode == "synthetic":
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_SYNTHETIC_REJECTED",
                "synthetic prompt-hook telemetry cannot create a learning candidate",
            )
        if origin not in {"configured_hook_stdin_unattested", "host_user_attested"}:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_PROVENANCE_INVALID",
                "native prompt-hook delivery provenance is not eligible",
            )
        handler = telemetry.get("handlerProvenance")
        if (
            not isinstance(handler, Mapping)
            or set(handler) != {
                "schema", "generation", "expectedGeneration", "generationMatches", "entrypoint", "rawPromptStored", "rawSessionIdStored"
            }
            or handler.get("schema") != "super-brain.prompt-hook-handler-provenance.v1"
            or not re.fullmatch(r"hg-[a-f0-9]{64}", str(handler.get("generation", "")))
            or str(handler.get("expectedGeneration", "")) != str(handler.get("generation", ""))
            or handler.get("generationMatches") is not True
            or handler.get("entrypoint") != "stable_dispatcher"
            or handler.get("rawPromptStored") is not False
            or handler.get("rawSessionIdStored") is not False
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_HANDLER_INVALID",
                "native prompt-hook telemetry is not bound to the installed stable handler generation",
            )
        runtime_wake = telemetry.get("runtimeWake")
        capture = telemetry.get("executionContractCapture")
        if not isinstance(runtime_wake, Mapping) or not isinstance(capture, Mapping):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_TELEMETRY_INVALID",
                "native prompt-hook runtime capture is invalid",
            )
        if (
            runtime_wake.get("active") is not True
            or runtime_wake.get("memoryBodyLoaded") is not True
            or str(capture.get("taskId", "")) != str(request["taskId"])
            or str(capture.get("sessionAccess", "")) != "owner"
            or capture.get("foreignContextDetected") is not False
        ):
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_SCOPE_STALE",
                "native prompt-hook capture is not current owner-task evidence",
            )
        projection = runtime_wake.get("memoryProjection")
        if not isinstance(projection, Mapping) or projection.get("state") != "injected":
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_NO_INJECTION",
                "native prompt-hook telemetry did not inject governed memory",
            )
        note_refs = self._native_prompt_hook_injected_note_refs(projection.get("injectedCardRefs"))
        if not note_refs:
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_NO_NOTE",
                "native prompt-hook telemetry did not inject a note eligible for learning",
            )
        return dict(telemetry), supplied_hash, note_refs, dict(provenance)

    def record_native_memory_learning_candidate(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Turn one current, injected quick-note reference into a non-binding review candidate.

        The hook itself stays read-only.  This controlled action checks its
        hash-verified telemetry and the live card revision, then creates only a
        proposed system reflection.  It deliberately cannot create a behavior
        preference, procedure, experience, or decision automatically.
        """

        # Compatibility only.  The former command is retired with P7/Hook;
        # deliberately return before any legacy telemetry reader can run.
        return {
            "ok": True,
            "schema": NATIVE_MEMORY_LEARNING_CANDIDATE_SCHEMA,
            "status": "withheld",
            "code": "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_RETIRED_H7_REQUIRED",
            "replacement": "record-h7-memory-learning-candidate",
            "candidate": None,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
            "memoryBodyStored": False,
        }

        normalized_request = self._normalize_native_memory_learning_candidate_request(request)
        _, telemetry_hash, note_refs, provenance = self._read_native_prompt_hook_telemetry(normalized_request)
        scope_for_note = {
            "workspaceKey": normalized_request["workspaceKey"],
            "taskId": normalized_request["taskId"],
            "taskInstanceId": normalized_request["taskInstanceId"],
            "ownerSessionKey": normalized_request["ownerSessionKey"],
        }
        dirty_marker_created = self._mark_native_memory_influence_snapshot_dirty()
        applied: dict[str, Any] | None = None
        source_card_id = ""
        source_revision = 0
        suggestion = ""
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    source_card: dict[str, Any] | None = None
                    for note_ref in note_refs:
                        row = connection.execute(
                            "SELECT head_revision,lifecycle FROM cards WHERE card_id=?", (note_ref["cardId"],)
                        ).fetchone()
                        if row is None:
                            continue
                        if int(row["head_revision"]) != int(note_ref["cardRevision"]) or str(row["lifecycle"]) != "active":
                            continue
                        candidate = self._read_card_revision(connection, str(note_ref["cardId"]), int(note_ref["cardRevision"]))
                        if candidate.get("kind") != "note" or not self._memory_influence_scope_matches(candidate, scope_for_note):
                            continue
                        payload = candidate.get("payload")
                        if not isinstance(payload, Mapping):
                            continue
                        found_suggestion = self._native_memory_learning_suggestion(payload)
                        if not found_suggestion:
                            continue
                        source_card = candidate
                        suggestion = found_suggestion
                        break
                    if source_card is None:
                        raise BrainControlError(
                            "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_NOTE_INELIGIBLE",
                            "no current injected note is tagged as a learning candidate",
                        )
                    source_card_id = str(source_card["cardId"])
                    source_revision = int(source_card["revision"])
                    if suggestion == "note":
                        connection.execute("COMMIT")
                        if dirty_marker_created:
                            self._clear_native_memory_influence_snapshot_dirty()
                        return {
                            "ok": True,
                            "schema": NATIVE_MEMORY_LEARNING_CANDIDATE_SCHEMA,
                            "status": "not_applicable",
                            "code": "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_NO_ENRICHMENT_NEEDED",
                            "candidate": None,
                            "source": {"cardId": source_card_id, "cardRevision": source_revision, "suggestedKind": suggestion},
                            "telemetryHash": telemetry_hash,
                            "deliveryProvenance": {"origin": provenance.get("origin", ""), "humanOrHostPathVerified": bool(provenance.get("humanOrHostPathVerified", False))},
                            "rawPromptStored": False,
                            "memoryBodyStored": False,
                        }
                    candidate_id = "reflection-native-use-" + _sha256(
                        {
                            "workspaceKey": normalized_request["workspaceKey"],
                            "ownerSessionKey": normalized_request["ownerSessionKey"],
                            "taskId": normalized_request["taskId"],
                            "telemetryHash": telemetry_hash,
                            "sourceCardId": source_card_id,
                            "sourceRevision": source_revision,
                        }
                    )[:40]
                    kind_label = NATIVE_MEMORY_LEARNING_KIND_LABELS[suggestion]
                    command = {
                        "commandType": "create_card",
                        "commandId": "native-memory-learning-" + candidate_id,
                        "aggregateId": candidate_id,
                        "expectedRevision": 0,
                        "kind": "reflection",
                        "scope": {
                            "kind": "task_instance" if normalized_request["taskInstanceId"] else "task",
                            "key": normalized_request["taskInstanceId"] or normalized_request["taskId"],
                        },
                        "lifecycle": "proposed",
                        "authority": "system",
                        "privacyClass": str(source_card["privacyClass"]),
                        "title": f"待确认学习：{kind_label}",
                        "payload": {
                            "schema": "super-brain.card.reflection.v1",
                            "observation": "一次符合范围的参考记忆已由本机 native prompt-hook 注入当前任务。",
                            "hypothesis": f"来源记忆可能适合整理为{kind_label}，但尚未获得用户采纳。",
                            "proposedAction": f"请确认是否将来源记忆整理为{kind_label}；采纳前不会改变偏好、流程、经验或决策。",
                            "evidence": [
                                f"native-hook-telemetry-sha256:{telemetry_hash}",
                                f"memory-card:{source_card_id}@{source_revision}",
                            ],
                            "confidence": 35,
                            "candidateState": "staged",
                            "suggestedKind": suggestion,
                            "tags": ["系统学习候选", "非绑定", "待用户采纳", "建议：" + suggestion, "native-prompt-hook"],
                        },
                        "evidenceRefs": [
                            f"native-hook-telemetry-sha256:{telemetry_hash}",
                            f"memory-card:{source_card_id}@{source_revision}",
                        ],
                        "actorReceipt": {
                            "schema": ACTOR_RECEIPT_SCHEMA,
                            "actorKind": "system",
                            "actorId": "native_memory_learning_capture",
                            "authorization": "system",
                            "authorizationReceipt": telemetry_hash,
                        },
                        "reason": "Create a non-binding learning candidate from current native memory injection evidence.",
                        "source": "native_prompt_hook_learning_capture",
                    }
                    normalized_command = self._validate_command(command)
                    applied = self._apply_in_transaction(connection, normalized_command, _sha256(normalized_command))
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
        except Exception:
            if dirty_marker_created:
                self._clear_native_memory_influence_snapshot_dirty()
            raise
        if applied is None:
            if dirty_marker_created:
                self._clear_native_memory_influence_snapshot_dirty()
            raise BrainControlError(
                "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_INTERNAL",
                "native memory learning candidate was not created",
            )
        if applied.get("idempotent") is not True:
            self._refresh_native_memory_influence_snapshot_after_mutation()
        elif dirty_marker_created:
            self._clear_native_memory_influence_snapshot_dirty()
        return {
            "ok": True,
            "schema": NATIVE_MEMORY_LEARNING_CANDIDATE_SCHEMA,
            "status": "reused" if applied.get("idempotent") is True else "captured",
            "code": "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_CANDIDATE_REUSED" if applied.get("idempotent") is True else "BRAIN_CONTROL_NATIVE_MEMORY_LEARNING_CANDIDATE_CAPTURED",
            "candidate": {
                "cardId": str(applied["aggregateId"]),
                "cardRevision": int(applied["revision"]),
                "kind": "reflection",
                "lifecycle": "proposed",
                "candidateState": "staged",
                "directConstraint": False,
            },
            "source": {"cardId": source_card_id, "cardRevision": source_revision, "suggestedKind": suggestion},
            "telemetryHash": telemetry_hash,
            "deliveryProvenance": {"origin": provenance.get("origin", ""), "humanOrHostPathVerified": bool(provenance.get("humanOrHostPathVerified", False))},
            "rawPromptStored": False,
            "memoryBodyStored": False,
        }

    def get_decision_context(self, request: Mapping[str, Any]) -> dict[str, Any]:
        """Return bounded, current decision guidance only after receipt validation."""

        scope = self._normalize_decision_resolution_scope(request, command_required=False)
        memory_scope = self._normalize_memory_influence_request(
            {
                "workspaceKey": scope["workspaceKey"],
                "taskId": scope["taskId"],
                "taskInstanceId": scope["taskInstanceId"],
                "ownerSessionKey": scope["ownerSessionKey"],
                "focus": request.get("focus", ""),
                "maxPerKind": request.get("maxPerKind", MEMORY_INFLUENCE_DEFAULT_MAX_PER_KIND),
            }
        )
        receipt_id = _require_string(request.get("receiptId"), "receiptId", 80)
        binding_digest = _require_sha256(request.get("bindingDigest"), "bindingDigest")
        with self._connection() as connection:
            receipt, checked = self._checked_decision_receipt(connection, scope, receipt_id, binding_digest)
            if receipt is None:
                return checked
            memory_influence = self._memory_influence_for_scope(connection, memory_scope)
            if checked["status"] == "none_applicable":
                return {
                    **checked,
                    "schema": NATIVE_DECISION_CONTEXT_SCHEMA,
                    "constraints": [],
                    "memoryInfluence": memory_influence,
                    "rawDecisionBodyStored": False,
                    "rawPromptStored": False,
                }
            constraints: list[dict[str, Any]] = []
            for item in checked["decisions"]:
                card = self._read_card_revision(connection, str(item["cardId"]), int(item["cardRevision"]))
                payload = _normalize_decision_payload(card["payload"])
                if payload.get("schema") != "super-brain.card.decision.v2":
                    return {
                        "ok": False,
                        "status": "withheld",
                        "code": "BRAIN_CONTROL_DECISION_CONTEXT_CARD_INVALID",
                    }
                constraints.append(
                    {
                        "cardId": item["cardId"],
                        "cardRevision": item["cardRevision"],
                        "enforcement": item["enforcement"],
                        "summary": _bounded_text(payload["summary"], "decision.summary", 360),
                        "consequences": [_bounded_text(value, "decision.consequence", 180) for value in payload["consequences"][:4]],
                        "completionCriteria": [_bounded_text(value, "decision.completionCriteria", 180) for value in payload["completionCriteria"][:6]],
                        "evidenceRefs": [_bounded_text(value, "decision.evidenceRefs", 180) for value in card["evidenceRefs"][:4]],
                    }
                )
        body = {
            "ok": True,
            "schema": NATIVE_DECISION_CONTEXT_SCHEMA,
            "status": checked["status"],
            "receiptId": receipt_id,
            "bindingDigest": checked["bindingDigest"],
            "constraints": constraints,
            "memoryInfluence": memory_influence,
            "rawDecisionBodyStored": False,
            "rawPromptStored": False,
        }
        if len(_canonical_json(body).encode("utf-8")) > 16384:
            return {
                "ok": False,
                "status": "withheld",
                "code": "BRAIN_CONTROL_DECISION_CONTEXT_TOO_LARGE",
            }
        return body

    @staticmethod
    def _task_scope(request: Mapping[str, Any], *, command_required: bool) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_REQUEST_INVALID", "task request must be an object")
        _ensure_safe(request, "taskRequest")
        scope = {
            "taskId": _require_string(request.get("taskId"), "taskId", 160),
            "taskInstanceId": _require_string(request.get("taskInstanceId"), "taskInstanceId", 80),
            "workspaceKey": _require_string(request.get("workspaceKey"), "workspaceKey", 120),
            "ownerSessionKey": _require_string(request.get("ownerSessionKey"), "ownerSessionKey", 120),
            "packageVersion": _require_string(request.get("packageVersion"), "packageVersion", 48),
        }
        if command_required:
            scope["commandId"] = _require_string(request.get("commandId"), "commandId", 160)
            scope["source"] = _require_string(request.get("source", "brain_control.task"), "source", 160)
        scope["aggregateId"] = BrainControl._task_aggregate_id(scope["taskId"], scope["workspaceKey"])
        return scope

    @staticmethod
    def _normalize_task_session_rebind(value: Any, scope: Mapping[str, Any]) -> dict[str, Any] | None:
        if value is None:
            return None
        if not isinstance(value, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_INVALID", "taskSessionRebind must be an object")
        _ensure_safe(value, "taskSessionRebind")
        normalized = {
            "schema": _require_string(value.get("schema"), "taskSessionRebind.schema", 120),
            "aggregateId": _require_string(value.get("aggregateId"), "taskSessionRebind.aggregateId", 160),
            "rebindId": _require_string(value.get("rebindId"), "taskSessionRebind.rebindId", 160),
            "taskId": _require_string(value.get("taskId"), "taskSessionRebind.taskId", 160),
            "taskInstanceId": _require_string(value.get("taskInstanceId"), "taskSessionRebind.taskInstanceId", 80),
            "workspaceKey": _require_string(value.get("workspaceKey"), "taskSessionRebind.workspaceKey", 120),
            "previousOwnerSessionKey": _require_string(value.get("previousOwnerSessionKey"), "taskSessionRebind.previousOwnerSessionKey", 120),
            "newOwnerSessionKey": _require_string(value.get("newOwnerSessionKey"), "taskSessionRebind.newOwnerSessionKey", 120),
        }
        if normalized["schema"] == "super-brain.intent-session-rebind-result.v1":
            normalized.update(
                {
                    "intentRevision": value.get("intentRevision"),
                    "latestReceiptId": _require_string(value.get("latestReceiptId"), "taskSessionRebind.latestReceiptId", 160),
                    "latestReceiptPayloadHash": _require_string(value.get("latestReceiptPayloadHash"), "taskSessionRebind.latestReceiptPayloadHash", 128).lower(),
                }
            )
            if not isinstance(normalized["intentRevision"], int) or normalized["intentRevision"] < 1:
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_INVALID", "taskSessionRebind intentRevision is invalid")
            if not SHA256_RE.fullmatch(normalized["latestReceiptPayloadHash"]):
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_INVALID", "taskSessionRebind receipt hash is invalid")
        elif normalized["schema"] == "super-brain.task-session-rebind-receipt.v1":
            normalized.update(
                {
                    "packageVersion": _require_string(value.get("packageVersion"), "taskSessionRebind.packageVersion", 48),
                    "taskRevision": value.get("taskRevision"),
                    "taskStateHash": _require_string(value.get("taskStateHash"), "taskSessionRebind.taskStateHash", 128).lower(),
                    "contractRevision": value.get("contractRevision"),
                    "planFingerprint": _require_string(value.get("planFingerprint"), "taskSessionRebind.planFingerprint", 64),
                }
            )
            if not isinstance(normalized["taskRevision"], int) or normalized["taskRevision"] < 0:
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_INVALID", "taskSessionRebind taskRevision is invalid")
            if not isinstance(normalized["contractRevision"], int) or normalized["contractRevision"] < 1:
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_INVALID", "taskSessionRebind contractRevision is invalid")
            if not SHA256_RE.fullmatch(normalized["taskStateHash"]):
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_INVALID", "taskSessionRebind task state hash is invalid")
        else:
            raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_INVALID", "taskSessionRebind schema is invalid")
        for name in ("taskId", "taskInstanceId", "workspaceKey"):
            if normalized[name] != str(scope[name]):
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_SCOPE_MISMATCH", f"taskSessionRebind.{name} does not match task scope")
        if normalized["newOwnerSessionKey"] != str(scope["ownerSessionKey"]):
            raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_SCOPE_MISMATCH", "taskSessionRebind new owner does not match task scope")
        return normalized

    @staticmethod
    def _verify_task_session_rebind(
        connection: sqlite3.Connection,
        scope: Mapping[str, Any],
        previous_owner_session_key: str,
        evidence: Mapping[str, Any] | None,
    ) -> dict[str, Any] | None:
        if previous_owner_session_key == str(scope["ownerSessionKey"]):
            if evidence is not None:
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_UNEXPECTED", "taskSessionRebind was supplied without an owner change")
            return None
        if evidence is None:
            raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_REQUIRED", "task ownership changed without a verified session rebind")
        if str(evidence["previousOwnerSessionKey"]) != previous_owner_session_key:
            raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_SCOPE_MISMATCH", "taskSessionRebind previous owner does not match task aggregate")
        if str(evidence["schema"]) == "super-brain.intent-session-rebind-result.v1":
            row = connection.execute(
                """
                SELECT rebind_id,aggregate_id,task_id,task_instance_id,workspace_key,
                  previous_owner_session_key,new_owner_session_key,intent_revision,
                  latest_receipt_id,latest_receipt_payload_hash
                FROM intent_session_rebinds
                WHERE rebind_id=? AND aggregate_id=?
                """,
                (str(evidence["rebindId"]), str(evidence["aggregateId"])),
            ).fetchone()
            if row is None:
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_UNVERIFIED", "referenced intent session rebind is unavailable")
            expected = {
                "task_id": str(scope["taskId"]),
                "task_instance_id": str(scope["taskInstanceId"]),
                "workspace_key": str(scope["workspaceKey"]),
                "previous_owner_session_key": previous_owner_session_key,
                "new_owner_session_key": str(scope["ownerSessionKey"]),
                "intent_revision": int(evidence["intentRevision"]),
                "latest_receipt_id": str(evidence["latestReceiptId"]),
                "latest_receipt_payload_hash": str(evidence["latestReceiptPayloadHash"]),
            }
            for column, value in expected.items():
                if str(row[column]) != str(value):
                    raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_UNVERIFIED", f"intent session rebind {column} does not match")
        else:
            row = connection.execute(
                """
                SELECT rebind_id,aggregate_id,task_id,task_instance_id,workspace_key,
                  previous_owner_session_key,new_owner_session_key,package_version,
                  task_revision,task_state_hash,contract_revision,plan_fingerprint
                FROM task_session_rebinds
                WHERE rebind_id=? AND aggregate_id=?
                """,
                (str(evidence["rebindId"]), str(evidence["aggregateId"])),
            ).fetchone()
            if row is None:
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_UNVERIFIED", "referenced task session rebind is unavailable")
            expected = {
                "task_id": str(scope["taskId"]),
                "task_instance_id": str(scope["taskInstanceId"]),
                "workspace_key": str(scope["workspaceKey"]),
                "previous_owner_session_key": previous_owner_session_key,
                "new_owner_session_key": str(scope["ownerSessionKey"]),
                "package_version": str(scope["packageVersion"]),
                "task_revision": int(evidence["taskRevision"]),
                "task_state_hash": str(evidence["taskStateHash"]),
                "contract_revision": int(evidence["contractRevision"]),
                "plan_fingerprint": str(evidence["planFingerprint"]),
            }
            for column, value in expected.items():
                if str(row[column]) != str(value):
                    raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_UNVERIFIED", f"task session rebind {column} does not match")
            aggregate = connection.execute(
                "SELECT head_revision,head_state_hash FROM task_aggregates WHERE aggregate_id=?",
                (str(evidence["aggregateId"]),),
            ).fetchone()
            if aggregate is None or int(aggregate["head_revision"]) != int(evidence["taskRevision"]) or str(aggregate["head_state_hash"]) != str(evidence["taskStateHash"]):
                raise BrainControlError("BRAIN_CONTROL_TASK_SESSION_REBIND_STALE", "task aggregate advanced after session rebind authorization")
        return dict(evidence)

    @staticmethod
    def _normalize_task_state(state: Any, scope: Mapping[str, Any], revision: int) -> dict[str, Any]:
        if not isinstance(state, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_STATE_INVALID", "state must be an object")
        _ensure_safe(state, "taskState")
        normalized = json.loads(_canonical_json(dict(state)))
        normalized.pop("compatibilityProjection", None)
        for name in ("taskId", "taskInstanceId", "workspaceKey", "ownerSessionKey", "packageVersion"):
            supplied = normalized.get(name)
            if supplied not in (None, "") and str(supplied) != str(scope[name]):
                raise BrainControlError("BRAIN_CONTROL_TASK_SCOPE_MISMATCH", f"state.{name} does not match task scope")
        lifecycle = str(normalized.get("lifecycle", "active")).strip().lower()
        if lifecycle not in TASK_LIFECYCLES:
            raise BrainControlError("BRAIN_CONTROL_TASK_LIFECYCLE_INVALID", f"unsupported lifecycle: {lifecycle}")
        canonical_plan = normalized.get("canonicalPlan")
        if canonical_plan is not None:
            if not isinstance(canonical_plan, Mapping):
                raise BrainControlError("BRAIN_CONTROL_TASK_PLAN_INVALID", "canonicalPlan must be an object")
            canonical_plan = dict(canonical_plan)
            items = _normalize_task_list(canonical_plan.get("items", []), "taskState.canonicalPlan.items", maximum=24)
            if any(not isinstance(item, Mapping) for item in items):
                raise BrainControlError("BRAIN_CONTROL_TASK_PLAN_INVALID", "canonicalPlan.items must contain objects")
            canonical_plan["items"] = items
            normalized["canonicalPlan"] = canonical_plan
        for field in ("completedSteps", "pendingSteps", "blockers", "evidence", "verificationResults", "constraints", "acceptanceCriteria"):
            if field in normalized:
                normalized[field] = _normalize_task_list(normalized.get(field), f"taskState.{field}")
        normalized.update(
            {
                "schema": TASK_AGGREGATE_SCHEMA,
                "taskId": scope["taskId"],
                "taskInstanceId": scope["taskInstanceId"],
                "workspaceKey": scope["workspaceKey"],
                "ownerSessionKey": scope["ownerSessionKey"],
                "packageVersion": scope["packageVersion"],
                "lifecycle": lifecycle,
                "taskStateRevision": revision,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        )
        if len(_canonical_json(normalized).encode("utf-8")) > 65536:
            raise BrainControlError("BRAIN_CONTROL_TASK_STATE_TOO_LARGE", "task state exceeds 64 KiB")
        return normalized

    @staticmethod
    def _normalize_task_projection(value: Any, scope: Mapping[str, Any], revision: int) -> dict[str, Any] | None:
        if value is None:
            return None
        if not isinstance(value, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_INVALID", "projection must be an object")
        _ensure_safe(value, "taskProjection")
        normalized = json.loads(_canonical_json(dict(value)))
        schema = str(normalized.get("schema", TASK_PROJECTION_SCHEMA)).strip()
        if schema != TASK_PROJECTION_SCHEMA:
            raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_SCHEMA_INVALID", f"projection requires {TASK_PROJECTION_SCHEMA}")
        task_id = normalized.get("taskId")
        if task_id not in (None, "") and str(task_id) != str(scope["taskId"]):
            raise BrainControlError("BRAIN_CONTROL_TASK_SCOPE_MISMATCH", "projection.taskId does not match task scope")
        workspace_key = normalized.get("workspaceKey")
        if workspace_key not in (None, "") and str(workspace_key) != str(scope["workspaceKey"]):
            raise BrainControlError("BRAIN_CONTROL_TASK_SCOPE_MISMATCH", "projection.workspaceKey does not match task scope")
        entities = normalized.get("entities")
        lifecycle = normalized.get("lifecycle")
        if not isinstance(entities, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_INVALID", "projection.entities must be an object")
        if not isinstance(lifecycle, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_INVALID", "projection.lifecycle must be an object")
        recovery_evidence = normalized.get("recoveryEvidence")
        if recovery_evidence is not None and not isinstance(recovery_evidence, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_INVALID", "projection.recoveryEvidence must be an object")
        commands = _normalize_task_list(normalized.get("commands", []), "taskProjection.commands", maximum=128)
        normalized_commands: list[dict[str, Any]] = []
        for index, raw_command in enumerate(commands):
            if not isinstance(raw_command, Mapping):
                raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_COMMAND_INVALID", f"command {index} must be an object")
            command = json.loads(_canonical_json(dict(raw_command)))
            for field in ("role", "operation", "targetPath"):
                if not isinstance(command.get(field), str) or not command[field].strip():
                    raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_COMMAND_INVALID", f"command {index}.{field} is required")
            payload_hash = str(command.get("payloadHash", "")).strip().lower()
            if payload_hash and not SHA256_RE.fullmatch(payload_hash):
                raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_PAYLOAD_HASH_INVALID", f"command {index}.payloadHash is invalid")
            command["payloadHash"] = payload_hash
            payload_text = command.get("payloadText")
            payload = command.get("payload")
            if payload_text not in (None, ""):
                if not isinstance(payload_text, str):
                    raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_PAYLOAD_INVALID", f"command {index}.payloadText must be text")
                if len(payload_text.encode("utf-8")) > 262144:
                    raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_PAYLOAD_TOO_LARGE", f"command {index} payload exceeds 256 KiB")
                try:
                    parsed_payload = json.loads(payload_text)
                except json.JSONDecodeError as exc:
                    raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_PAYLOAD_INVALID", f"command {index}.payloadText is not JSON") from exc
                _ensure_safe(parsed_payload, f"taskProjection.commands[{index}].payloadText")
                exact_hash = _sha256_bytes(payload_text.encode("utf-8"))
                if payload_hash and payload_hash != exact_hash:
                    raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_PAYLOAD_HASH_MISMATCH", f"command {index} payload bytes do not match payloadHash")
                command["payloadHash"] = exact_hash
                command["payloadCanonicalHash"] = _sha256(parsed_payload)
                command.pop("payload", None)
            elif payload is not None:
                _ensure_safe(payload, f"taskProjection.commands[{index}].payload")
                payload_digest = _sha256(payload)
                supplied_digest = str(command.get("payloadCanonicalHash", "")).strip().lower()
                if supplied_digest and supplied_digest != payload_digest:
                    raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_PAYLOAD_DIGEST_MISMATCH", f"command {index} payload digest does not match")
                command["payloadCanonicalHash"] = payload_digest
            elif payload_hash:
                raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_PAYLOAD_MISSING", f"command {index} has a payload hash but no payload")
            command.pop("payloadPath", None)
            normalized_commands.append(command)
        normalized.update(
            {
                "schema": TASK_PROJECTION_SCHEMA,
                "taskId": scope["taskId"],
                "workspaceKey": scope["workspaceKey"],
                "taskStateRevision": revision,
                "commands": normalized_commands,
            }
        )
        if len(_canonical_json(normalized).encode("utf-8")) > 1048576:
            raise BrainControlError("BRAIN_CONTROL_TASK_PROJECTION_TOO_LARGE", "task projection exceeds 1 MiB")
        return normalized

    @staticmethod
    def _task_row_state(connection: sqlite3.Connection, aggregate_id: str, revision: int) -> dict[str, Any] | None:
        row = connection.execute(
            "SELECT state_json FROM task_state_revisions WHERE aggregate_id=? AND task_revision=?",
            (aggregate_id, revision),
        ).fetchone()
        if row is None:
            return None
        return json.loads(str(row["state_json"]))

    def prepare_task(self, request: Mapping[str, Any]) -> dict[str, Any]:
        scope = self._task_scope(request, command_required=False)
        session_rebind = self._normalize_task_session_rebind(request.get("taskSessionRebind"), scope)
        with self._connection() as connection:
            aggregate = connection.execute(
                "SELECT * FROM task_aggregates WHERE aggregate_id=?", (scope["aggregateId"],)
            ).fetchone()
            if aggregate is None:
                return {
                    "ok": True,
                    "code": "BRAIN_CONTROL_TASK_PREPARED_EMPTY",
                    "aggregateId": scope["aggregateId"],
                    "expectedRevision": 0,
                    "state": None,
                }
            if str(aggregate["task_instance_id"]) != scope["taskInstanceId"]:
                raise BrainControlError("BRAIN_CONTROL_TASK_INSTANCE_MISMATCH", "task aggregate belongs to another task instance")
            task_session_rebound = self._verify_task_session_rebind(connection, scope, str(aggregate["owner_session_key"]), session_rebind)
            state = self._task_row_state(connection, scope["aggregateId"], int(aggregate["head_revision"]))
        return {
            "ok": True,
            "code": "BRAIN_CONTROL_TASK_PREPARED",
            "aggregateId": scope["aggregateId"],
            "expectedRevision": int(aggregate["head_revision"]),
            "state": state,
            "taskSessionRebind": task_session_rebound is not None,
        }

    def import_task(self, request: Mapping[str, Any]) -> dict[str, Any]:
        scope = self._task_scope(request, command_required=True)
        initial_revision = request.get("initialRevision")
        if not isinstance(initial_revision, int) or initial_revision < 0:
            raise BrainControlError("BRAIN_CONTROL_TASK_INITIAL_REVISION_INVALID", "initialRevision must be non-negative")
        state = self._normalize_task_state(request.get("state"), scope, initial_revision)
        payload = {**scope, "initialRevision": initial_revision, "state": state}
        payload_hash = _sha256(payload)
        state_hash = _sha256(state)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                replay = connection.execute(
                    "SELECT payload_hash,result_json FROM command_log WHERE command_id=?", (scope["commandId"],)
                ).fetchone()
                if replay is not None:
                    if str(replay["payload_hash"]) != payload_hash:
                        raise BrainControlError("BRAIN_CONTROL_COMMAND_ID_REUSED", "commandId was already used with a different task import")
                    result = json.loads(str(replay["result_json"]))
                    result["idempotent"] = True
                    connection.execute("COMMIT")
                    return result
                existing = connection.execute(
                    "SELECT * FROM task_aggregates WHERE aggregate_id=?", (scope["aggregateId"],)
                ).fetchone()
                if existing is not None:
                    raise BrainControlError("BRAIN_CONTROL_TASK_ALREADY_IMPORTED", "task aggregate already exists")
                now = _utc_now()
                connection.execute(
                    """
                    INSERT INTO task_aggregates(aggregate_id,task_id,task_instance_id,workspace_key,owner_session_key,package_version,lifecycle,head_revision,head_state_hash,created_at,updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        scope["aggregateId"], scope["taskId"], scope["taskInstanceId"], scope["workspaceKey"],
                        scope["ownerSessionKey"], scope["packageVersion"], state["lifecycle"], initial_revision,
                        state_hash, now, now,
                    ),
                )
                connection.execute(
                    """
                    INSERT INTO task_state_revisions(aggregate_id,task_revision,predecessor_state_hash,state_hash,state_json,command_id,source,created_at)
                    VALUES (?,?,?,?,?,?,?,?)
                    """,
                    (scope["aggregateId"], initial_revision, "", state_hash, _canonical_json(state), scope["commandId"], scope["source"], now),
                )
                event_id = "evt-" + uuid.uuid4().hex
                outbox_payload = {
                    "schema": "super-brain.task-state-snapshot-outbox.v1",
                    "eventId": event_id,
                    "aggregateId": scope["aggregateId"],
                    "taskId": scope["taskId"],
                    "workspaceKey": scope["workspaceKey"],
                    "revision": initial_revision,
                    "stateHash": state_hash,
                }
                result = {
                    "ok": True,
                    "schema": "super-brain.task-import-receipt.v1",
                    "aggregateId": scope["aggregateId"],
                    "revision": initial_revision,
                    "stateHash": state_hash,
                    "eventId": event_id,
                    "outboxEventId": event_id,
                    "idempotent": False,
                }
                connection.execute(
                    "INSERT INTO command_log(command_id,command_type,aggregate_id,expected_revision,payload_hash,result_json,created_at) VALUES (?,?,?,?,?,?,?)",
                    (scope["commandId"], "import_task", scope["aggregateId"], initial_revision, payload_hash, _canonical_json(result), now),
                )
                connection.execute(
                    "INSERT INTO events(event_id,command_id,command_type,aggregate_id,revision,expected_revision,result_code,reason_code,source,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (event_id, scope["commandId"], "import_task", scope["aggregateId"], initial_revision, initial_revision, "applied", "historical_import", scope["source"], now),
                )
                connection.execute(
                    "INSERT INTO outbox(event_id,aggregate_id,revision,projection_kind,payload_json,status,delivery_version,created_at) VALUES (?,?,?,?,?,?,?,?)",
                    (event_id, scope["aggregateId"], initial_revision, "task_state_snapshot", _canonical_json(outbox_payload), "pending", 1, now),
                )
                connection.execute("COMMIT")
                return result
            except Exception:
                connection.execute("ROLLBACK")
                raise

    def apply_task(self, request: Mapping[str, Any]) -> dict[str, Any]:
        scope = self._task_scope(request, command_required=True)
        session_rebind = self._normalize_task_session_rebind(request.get("taskSessionRebind"), scope)
        expected_revision = request.get("expectedRevision")
        if not isinstance(expected_revision, int) or expected_revision < 0:
            raise BrainControlError("BRAIN_CONTROL_TASK_EXPECTED_REVISION_INVALID", "expectedRevision must be non-negative")
        request_state = request.get("state")
        request_projection = request.get("projection")
        if request_projection is None and isinstance(request_state, Mapping):
            request_projection = request_state.get("compatibilityProjection")
        normalized_request_state = self._normalize_task_state(request_state, scope, expected_revision + 1)
        normalized_request_projection = self._normalize_task_projection(request_projection, scope, expected_revision + 1)
        payload_seed = {
            **scope,
            "expectedRevision": expected_revision,
            "state": normalized_request_state,
            "projection": normalized_request_projection,
            "taskSessionRebind": session_rebind,
        }
        payload_hash = _sha256(payload_seed)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                replay = connection.execute(
                    "SELECT payload_hash,result_json FROM command_log WHERE command_id=?", (scope["commandId"],)
                ).fetchone()
                if replay is not None:
                    if str(replay["payload_hash"]) != payload_hash:
                        raise BrainControlError("BRAIN_CONTROL_COMMAND_ID_REUSED", "commandId was already used with a different task payload")
                    result = json.loads(str(replay["result_json"]))
                    result["idempotent"] = True
                    connection.execute("COMMIT")
                    return result
                aggregate = connection.execute(
                    "SELECT * FROM task_aggregates WHERE aggregate_id=?", (scope["aggregateId"],)
                ).fetchone()
                if aggregate is None:
                    raise BrainControlError("BRAIN_CONTROL_TASK_NOT_IMPORTED", "task aggregate must be imported before mutation")
                actual_revision = int(aggregate["head_revision"])
                if actual_revision != expected_revision:
                    raise BrainControlError("BRAIN_CONTROL_TASK_STALE_REVISION", f"expected task revision {expected_revision}, found {actual_revision}")
                if str(aggregate["task_instance_id"]) != scope["taskInstanceId"]:
                    raise BrainControlError("BRAIN_CONTROL_TASK_INSTANCE_MISMATCH", "task aggregate belongs to another task instance")
                task_session_rebind = self._verify_task_session_rebind(connection, scope, str(aggregate["owner_session_key"]), session_rebind)
                next_revision = actual_revision + 1
                state = self._normalize_task_state(request_state, scope, next_revision)
                projection = self._normalize_task_projection(request_projection, scope, next_revision)
                state_hash = _sha256(state)
                now = _utc_now()
                event_id = "evt-" + uuid.uuid4().hex
                predecessor_hash = str(aggregate["head_state_hash"])
                outbox_payload = {
                    "schema": "super-brain.task-projection-outbox.v1",
                    "eventId": event_id,
                    "aggregateId": scope["aggregateId"],
                    "taskId": scope["taskId"],
                    "workspaceKey": scope["workspaceKey"],
                    "revision": next_revision,
                    "stateHash": state_hash,
                    "state": state,
                    "projection": projection,
                }
                result = {
                    "ok": True,
                    "schema": "super-brain.task-apply-receipt.v1",
                    "aggregateId": scope["aggregateId"],
                    "revision": next_revision,
                    "previousRevision": actual_revision,
                    "stateHash": state_hash,
                    "eventId": event_id,
                    "outboxEventId": event_id,
                    "taskSessionRebind": task_session_rebind is not None,
                    "idempotent": False,
                }
                connection.execute(
                    "UPDATE task_aggregates SET owner_session_key=?,package_version=?,lifecycle=?,head_revision=?,head_state_hash=?,updated_at=? WHERE aggregate_id=?",
                    (scope["ownerSessionKey"], scope["packageVersion"], state["lifecycle"], next_revision, state_hash, now, scope["aggregateId"]),
                )
                connection.execute(
                    "INSERT INTO task_state_revisions(aggregate_id,task_revision,predecessor_state_hash,state_hash,state_json,command_id,source,created_at) VALUES (?,?,?,?,?,?,?,?)",
                    (scope["aggregateId"], next_revision, predecessor_hash, state_hash, _canonical_json(state), scope["commandId"], scope["source"], now),
                )
                connection.execute(
                    "INSERT INTO command_log(command_id,command_type,aggregate_id,expected_revision,payload_hash,result_json,created_at) VALUES (?,?,?,?,?,?,?)",
                    (scope["commandId"], "apply_task", scope["aggregateId"], expected_revision, payload_hash, _canonical_json(result), now),
                )
                connection.execute(
                    "INSERT INTO events(event_id,command_id,command_type,aggregate_id,revision,expected_revision,result_code,reason_code,source,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (event_id, scope["commandId"], "apply_task", scope["aggregateId"], next_revision, expected_revision, "applied", "session_rebound" if task_session_rebind is not None else "", scope["source"], now),
                )
                connection.execute(
                    "INSERT INTO outbox(event_id,aggregate_id,revision,projection_kind,payload_json,status,delivery_version,created_at) VALUES (?,?,?,?,?,?,?,?)",
                    (event_id, scope["aggregateId"], next_revision, "task_projection", _canonical_json(outbox_payload), "pending", 1, now),
                )
                connection.execute("COMMIT")
                return result
            except Exception:
                connection.execute("ROLLBACK")
                raise

    def get_task(self, request: Mapping[str, Any]) -> dict[str, Any]:
        scope = self._task_scope(request, command_required=False)
        with self._connection() as connection:
            aggregate = connection.execute("SELECT * FROM task_aggregates WHERE aggregate_id=?", (scope["aggregateId"],)).fetchone()
            if aggregate is None:
                return {"ok": True, "found": False, "aggregateId": scope["aggregateId"], "state": None}
            if str(aggregate["task_instance_id"]) != scope["taskInstanceId"] or str(aggregate["owner_session_key"]) != scope["ownerSessionKey"]:
                return {"ok": False, "found": True, "current": False, "code": "BRAIN_CONTROL_TASK_SCOPE_STALE", "aggregateId": scope["aggregateId"], "state": None}
            state = self._task_row_state(connection, scope["aggregateId"], int(aggregate["head_revision"]))
        return {
            "ok": True,
            "found": True,
            "current": True,
            "aggregateId": scope["aggregateId"],
            "revision": int(aggregate["head_revision"]),
            "stateHash": str(aggregate["head_state_hash"]),
            "state": state,
        }

    def locate_task(self, request: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(request, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_REQUEST_INVALID", "task request must be an object")
        _ensure_safe(request, "taskLocateRequest")
        task_id = _require_string(request.get("taskId"), "taskId", 160)
        workspace_value = request.get("workspaceKey")
        workspace_key = ""
        if workspace_value not in (None, ""):
            workspace_key = _require_string(workspace_value, "workspaceKey", 120)
        with self._connection() as connection:
            if workspace_key:
                aggregate_id = self._task_aggregate_id(task_id, workspace_key)
                aggregate = connection.execute("SELECT * FROM task_aggregates WHERE aggregate_id=?", (aggregate_id,)).fetchone()
            else:
                matches = connection.execute(
                    "SELECT * FROM task_aggregates WHERE task_id=? ORDER BY workspace_key,aggregate_id", (task_id,)
                ).fetchall()
                if len(matches) > 1:
                    return {
                        "ok": True,
                        "found": False,
                        "ambiguous": True,
                        "code": "BRAIN_CONTROL_TASK_SCOPE_AMBIGUOUS",
                        "taskId": task_id,
                        "matchCount": len(matches),
                        "workspaceKeys": [str(row["workspace_key"]) for row in matches[:16]],
                        "state": None,
                    }
                aggregate = matches[0] if matches else None
                aggregate_id = str(aggregate["aggregate_id"]) if aggregate is not None else ""
            if aggregate is None:
                return {"ok": True, "found": False, "aggregateId": aggregate_id, "state": None}
            state = self._task_row_state(connection, aggregate_id, int(aggregate["head_revision"]))
        return {
            "ok": True,
            "found": True,
            "aggregateId": aggregate_id,
            "taskId": str(aggregate["task_id"]),
            "taskInstanceId": str(aggregate["task_instance_id"]),
            "workspaceKey": str(aggregate["workspace_key"]),
            "ownerSessionKey": str(aggregate["owner_session_key"]),
            "packageVersion": str(aggregate["package_version"]),
            "revision": int(aggregate["head_revision"]),
            "stateHash": str(aggregate["head_state_hash"]),
            "state": state,
        }

    def pending_task_outbox(self) -> list[dict[str, Any]]:
        with self._connection() as connection:
            rows = connection.execute(
                "SELECT event_id,aggregate_id,revision,payload_json,delivery_version,created_at FROM outbox WHERE status='pending' AND projection_kind='task_projection' ORDER BY created_at,event_id"
            ).fetchall()
        return [
            {
                "eventId": str(row["event_id"]),
                "aggregateId": str(row["aggregate_id"]),
                "revision": int(row["revision"]),
                "deliveryVersion": int(row["delivery_version"]),
                "payload": json.loads(str(row["payload_json"])),
                "createdAt": str(row["created_at"]),
            }
            for row in rows
        ]

    def task_projection_snapshots(self) -> list[dict[str, Any]]:
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT o.event_id,o.aggregate_id,o.revision,o.payload_json,o.status,o.created_at,o.materialized_at
                FROM outbox o
                JOIN (
                  SELECT aggregate_id,MAX(rowid) AS row_id
                  FROM outbox
                  WHERE projection_kind='task_projection'
                  GROUP BY aggregate_id
                ) latest ON latest.row_id=o.rowid
                WHERE o.projection_kind='task_projection'
                ORDER BY o.aggregate_id
                """
            ).fetchall()
        return [
            {
                "eventId": str(row["event_id"]),
                "aggregateId": str(row["aggregate_id"]),
                "revision": int(row["revision"]),
                "status": str(row["status"]),
                "createdAt": str(row["created_at"]),
                "materializedAt": str(row["materialized_at"]),
                "payload": json.loads(str(row["payload_json"])),
            }
            for row in rows
        ]

    def apply(self, command: Mapping[str, Any]) -> dict[str, Any]:
        normalized = self._validate_command(command)
        payload_hash = _sha256(normalized)
        dirty_marker_created = self._mark_native_memory_influence_snapshot_dirty()
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    result = self._apply_in_transaction(connection, normalized, payload_hash)
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
        except Exception:
            if dirty_marker_created:
                self._clear_native_memory_influence_snapshot_dirty()
            raise
        self._refresh_native_memory_influence_snapshot_after_mutation()
        if result.get("kind") == "decision":
            index = self.publish_native_decision_index()
            result = {
                **result,
                "nativeDecisionIndex": {
                    "payloadHash": index["payloadHash"],
                    "shardCount": index["shardCount"],
                    "decisionCount": index["decisionCount"],
                },
            }
        return result

    def apply_many_atomically(self, commands: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
        """Apply a small, user-authorized card workflow as one SQLite transaction."""
        if not commands or len(commands) > 100:
            raise BrainControlError("BRAIN_CONTROL_COMMAND_BATCH_INVALID", "command batch must contain between 1 and 100 commands")
        normalized = [self._validate_command(command) for command in commands]
        command_ids = [str(command["commandId"]) for command in normalized]
        if len(set(command_ids)) != len(command_ids):
            raise BrainControlError("BRAIN_CONTROL_COMMAND_BATCH_INVALID", "command batch contains duplicate command IDs")
        payload_hashes = [_sha256(command) for command in normalized]
        dirty_marker_created = self._mark_native_memory_influence_snapshot_dirty()
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    results = [
                        self._apply_in_transaction(connection, command, payload_hash)
                        for command, payload_hash in zip(normalized, payload_hashes)
                    ]
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise
        except Exception:
            if dirty_marker_created:
                self._clear_native_memory_influence_snapshot_dirty()
            raise
        self._refresh_native_memory_influence_snapshot_after_mutation()
        if any(result.get("kind") == "decision" for result in results):
            index = self.publish_native_decision_index()
            index_summary = {
                "payloadHash": index["payloadHash"],
                "shardCount": index["shardCount"],
                "decisionCount": index["decisionCount"],
            }
            results = [{**result, "nativeDecisionIndex": index_summary} if result.get("kind") == "decision" else result for result in results]
        return results

    def forget_trashed_cards_for_ui(
        self,
        cards: Sequence[Mapping[str, Any]],
        actor_receipt: Mapping[str, Any],
        *,
        command_id_prefix: str,
        reason: str,
        source: str = "loopback_control_center",
    ) -> dict[str, Any]:
        """Tombstone one bounded Trash selection as a single user-confirmed transaction.

        The card rows remain as privacy tombstones. Their title, payload, search
        content, and user-facing visibility are removed by the governed
        ``forget_trashed`` transition; this deliberately does not claim secure
        physical erasure of retained storage.
        """

        if isinstance(cards, (str, bytes)) or not isinstance(cards, Sequence) or not 1 <= len(cards) <= 100:
            raise BrainControlError("BRAIN_CONTROL_TRASH_DELETE_BATCH_INVALID", "Trash delete requires between 1 and 100 selected cards")
        actor = _normalize_actor_receipt(actor_receipt)
        if actor["authorization"] not in {"user_confirmed", "test"}:
            raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", "Trash delete requires a user-confirmed receipt")
        prefix = _require_string(command_id_prefix, "commandIdPrefix", 160)
        normalized_reason = _card_text(reason, "reason", 480)
        normalized_source = _require_string(source, "source", 160)
        commands: list[dict[str, Any]] = []
        card_ids: set[str] = set()
        for index, item in enumerate(cards):
            if not isinstance(item, Mapping):
                raise BrainControlError("BRAIN_CONTROL_TRASH_DELETE_BATCH_INVALID", "each selected Trash card must be an object")
            _card_exact_fields(item, {"cardId", "expectedRevision"}, {"cardId", "expectedRevision"}, "trash delete selection")
            card_id = _require_string(item.get("cardId"), "trashDelete.cardId", 160)
            revision = item.get("expectedRevision")
            if isinstance(revision, bool) or not isinstance(revision, int) or revision < 1:
                raise BrainControlError("BRAIN_CONTROL_TRASH_DELETE_BATCH_INVALID", "each selected Trash card requires a positive expectedRevision")
            if card_id in card_ids:
                raise BrainControlError("BRAIN_CONTROL_TRASH_DELETE_BATCH_INVALID", "Trash delete selection contains a duplicate card")
            card_ids.add(card_id)
            commands.append(
                {
                    "commandType": "forget_trashed",
                    "commandId": f"{prefix}-{index + 1}",
                    "aggregateId": card_id,
                    "expectedRevision": revision,
                    "forgetAcknowledged": True,
                    "actorReceipt": actor,
                    "reason": normalized_reason,
                    "source": normalized_source,
                }
            )
        results = self.apply_many_atomically(commands)
        return {
            "ok": True,
            "schema": "super-brain.ui-trash-delete-receipt.v1",
            "deletedCount": len(results),
            "results": results,
            "physicalSecureErasureClaim": False,
        }

    @staticmethod
    def _revision_state(command: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "schema": CARD_REVISION_STATE_SCHEMA,
            "commandType": command["commandType"],
            "operation": command["operation"],
            "reason": command["reason"],
            "kind": command["kind"],
            "scope": command["scope"],
            "lifecycle": command["lifecycle"],
            "authority": command["authority"],
            "privacyClass": command["privacyClass"],
            "payloadSchema": command["payload"]["schema"],
            "rollbackOfRevision": command.get("rollbackOfRevision"),
            "replacementRef": command.get("replacementRef", ""),
            "trashedFromLifecycle": command.get("trashedFromLifecycle", ""),
            "forgottenFromRevision": command.get("forgottenFromRevision"),
        }

    @staticmethod
    def _card_from_row(row: sqlite3.Row) -> dict[str, Any]:
        raw_state = str(row["state_json"] or "{}") if "state_json" in row.keys() else "{}"
        try:
            revision_state = json.loads(raw_state)
        except json.JSONDecodeError:
            revision_state = {}
        if not isinstance(revision_state, Mapping):
            revision_state = {}
        return {
            "cardId": str(row["card_id"]),
            "kind": str(row["kind"]),
            "scope": {"kind": str(row["scope_kind"]), "key": str(row["scope_key"])},
            "lifecycle": str(row["lifecycle"]),
            "authority": str(row["authority"]),
            "privacyClass": str(row["privacy_class"]),
            "revision": int(row["revision"] if "revision" in row.keys() else row["head_revision"]),
            "predecessorHash": str(row["predecessor_hash"]),
            "contentHash": str(row["content_hash"]),
            "title": str(row["title"]),
            "payload": json.loads(str(row["structured_payload"])),
            "evidenceRefs": json.loads(str(row["evidence_refs"])),
            "actorReceipt": json.loads(str(row["actor_receipt"])),
            "revisionState": dict(revision_state),
            "createdAt": str(row["created_at"]),
        }

    def _read_card_revision(
        self,
        connection: sqlite3.Connection,
        card_id: str,
        revision: int,
        *,
        require_typed_state: bool = False,
    ) -> dict[str, Any]:
        row = connection.execute(
            """
            SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
              r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
              r.state_json,r.created_at
            FROM cards c JOIN card_revisions r ON r.card_id=c.card_id
            WHERE c.card_id=? AND r.revision=?
            """,
            (card_id, revision),
        ).fetchone()
        if row is None:
            raise BrainControlError("BRAIN_CONTROL_CARD_REVISION_NOT_FOUND", f"card revision {revision} was not found")
        card = self._card_from_row(row)
        state = card["revisionState"]
        historical_fields = {"schema", "kind", "scope", "lifecycle", "authority", "privacyClass", "payloadSchema"}
        if state.get("schema") == CARD_REVISION_STATE_SCHEMA and historical_fields.issubset(state):
            scope = state["scope"]
            if not isinstance(scope, Mapping) or not isinstance(scope.get("kind"), str) or not isinstance(scope.get("key"), str):
                raise BrainControlError("BRAIN_CONTROL_CARD_CONTENT_CORRUPT", "typed card revision state has an invalid scope")
            card.update(
                {
                    "kind": str(state["kind"]),
                    "scope": {"kind": scope["kind"], "key": scope["key"]},
                    "lifecycle": str(state["lifecycle"]),
                    "authority": str(state["authority"]),
                    "privacyClass": str(state["privacyClass"]),
                }
            )
        if _sha256(self._card_content(card)) != card["contentHash"]:
            raise BrainControlError("BRAIN_CONTROL_CARD_CONTENT_CORRUPT", "card revision content hash does not match")
        if require_typed_state:
            required = {"schema", "kind", "scope", "lifecycle", "authority", "privacyClass", "payloadSchema"}
            if state.get("schema") != CARD_REVISION_STATE_SCHEMA or not required.issubset(state):
                raise BrainControlError(
                    "BRAIN_CONTROL_CARD_ROLLBACK_UNAVAILABLE",
                    "rollback requires a revision written by the typed card contract",
                )
        return card

    @staticmethod
    def _require_same_card_identity(current: sqlite3.Row, command: Mapping[str, Any]) -> None:
        if str(current["kind"]) != command["kind"]:
            raise BrainControlError("BRAIN_CONTROL_CARD_KIND_IMMUTABLE", "card kind cannot change after creation")
        if str(current["scope_kind"]) != command["scope"]["kind"] or str(current["scope_key"]) != command["scope"]["key"]:
            raise BrainControlError("BRAIN_CONTROL_CARD_SCOPE_IMMUTABLE", "card scope cannot change after creation")

    def _resolve_card_mutation(
        self,
        connection: sqlite3.Connection,
        normalized: Mapping[str, Any],
        current: sqlite3.Row | None,
        actual_revision: int,
    ) -> dict[str, Any]:
        command_type = str(normalized["commandType"])
        if command_type == "create_card":
            if current is not None:
                raise BrainControlError("BRAIN_CONTROL_CARD_ALREADY_EXISTS", "create_card requires a new aggregateId")
            return dict(normalized)
        if command_type == "edit_card":
            if current is None:
                raise BrainControlError("BRAIN_CONTROL_CARD_NOT_FOUND", "edit_card requires an existing card")
            self._require_same_card_identity(current, normalized)
            if str(current["lifecycle"]) in {"trashed", "forgotten"}:
                raise BrainControlError(
                    "BRAIN_CONTROL_CARD_EDIT_UNAVAILABLE",
                    "trashed or forgotten cards must be restored or left forgotten before editing",
                )
            if str(current["lifecycle"]) != normalized["lifecycle"]:
                raise BrainControlError("BRAIN_CONTROL_CARD_LIFECYCLE_TRANSITION_INVALID", "edit_card cannot change lifecycle")
            if str(current["authority"]) != normalized["authority"]:
                raise BrainControlError("BRAIN_CONTROL_CARD_AUTHORITY_IMMUTABLE", "edit_card cannot change authority")
            return dict(normalized)
        if command_type == "upsert_card":
            if current is not None:
                self._require_same_card_identity(current, normalized)
            return dict(normalized)
        if current is None:
            raise BrainControlError("BRAIN_CONTROL_CARD_NOT_FOUND", f"{command_type} requires an existing card")
        current_card = self._read_card_revision(connection, str(normalized["aggregateId"]), actual_revision)
        contract = CARD_CONTRACTS[current_card["kind"]]
        if command_type not in contract.allowed_commands:
            raise BrainControlError(
                "BRAIN_CONTROL_CARD_COMMAND_INVALID",
                f"{command_type} is not allowed for {current_card['kind']}",
            )
        if current_card["authority"] == "user_confirmed" and normalized["actorReceipt"]["authorization"] not in {"user_confirmed", "test"}:
            raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", "user-confirmed cards require a user-confirmed receipt")
        if command_type in {"trash_card", "restore_card", "cancel_card", "forget_active", "forget_trashed"} and normalized["actorReceipt"]["authorization"] not in {"user_confirmed", "test"}:
            raise BrainControlError(
                "BRAIN_CONTROL_ACTOR_RECEIPT_INVALID",
                "privacy or lifecycle transitions require a user-confirmed receipt",
            )

        payload = current_card["payload"]
        hard_completion_decision = (
            current_card["kind"] == "decision"
            and isinstance(payload, Mapping)
            and payload.get("schema") == "super-brain.card.decision.v2"
            and payload.get("enforcement") == "completion_gate"
        )
        if command_type == "supersede_card":
            if hard_completion_decision and not normalized.get("impactAcknowledged", False):
                raise BrainControlError(
                    "BRAIN_CONTROL_DECISION_IMPACT_ACKNOWLEDGEMENT_REQUIRED",
                    "superseding a completion-gate decision requires an explicit impact acknowledgement",
                )
            return {
                **dict(normalized),
                "kind": current_card["kind"],
                "scope": current_card["scope"],
                "lifecycle": "superseded",
                "authority": current_card["authority"],
                "privacyClass": current_card["privacyClass"],
                "title": current_card["title"],
                "payload": current_card["payload"],
                "evidenceRefs": current_card["evidenceRefs"],
            }
        if command_type == "trash_card":
            if current_card["lifecycle"] not in {"proposed", "active"}:
                raise BrainControlError("BRAIN_CONTROL_CARD_TRASH_UNAVAILABLE", "only active or proposed cards can enter Trash")
            if hard_completion_decision:
                raise BrainControlError(
                    "BRAIN_CONTROL_DECISION_TRASH_UNAVAILABLE",
                    "a completion-gate decision must be explicitly superseded or cancelled, not hidden in Trash",
                )
            return {
                **dict(normalized),
                "kind": current_card["kind"],
                "scope": current_card["scope"],
                "lifecycle": "trashed",
                "authority": current_card["authority"],
                "privacyClass": current_card["privacyClass"],
                "title": current_card["title"],
                "payload": current_card["payload"],
                "evidenceRefs": current_card["evidenceRefs"],
                "trashedFromLifecycle": current_card["lifecycle"],
            }
        if command_type == "restore_card":
            if current_card["lifecycle"] != "trashed":
                raise BrainControlError("BRAIN_CONTROL_CARD_RESTORE_UNAVAILABLE", "only trashed cards can be restored")
            restore_lifecycle = str(current_card["revisionState"].get("trashedFromLifecycle", ""))
            if restore_lifecycle not in {"proposed", "active"}:
                raise BrainControlError("BRAIN_CONTROL_CARD_RESTORE_UNAVAILABLE", "the original lifecycle is unavailable")
            return {
                **dict(normalized),
                "kind": current_card["kind"],
                "scope": current_card["scope"],
                "lifecycle": restore_lifecycle,
                "authority": current_card["authority"],
                "privacyClass": current_card["privacyClass"],
                "title": current_card["title"],
                "payload": current_card["payload"],
                "evidenceRefs": current_card["evidenceRefs"],
            }
        if command_type == "cancel_card":
            if current_card["lifecycle"] not in {"proposed", "active"}:
                raise BrainControlError("BRAIN_CONTROL_CARD_CANCEL_UNAVAILABLE", "only active or proposed cards can be cancelled")
            if hard_completion_decision and not normalized.get("impactAcknowledged", False):
                raise BrainControlError(
                    "BRAIN_CONTROL_DECISION_IMPACT_ACKNOWLEDGEMENT_REQUIRED",
                    "cancelling a completion-gate decision requires an explicit impact acknowledgement",
                )
            return {
                **dict(normalized),
                "kind": current_card["kind"],
                "scope": current_card["scope"],
                "lifecycle": "cancelled",
                "authority": current_card["authority"],
                "privacyClass": current_card["privacyClass"],
                "title": current_card["title"],
                "payload": current_card["payload"],
                "evidenceRefs": current_card["evidenceRefs"],
            }
        if command_type == "forget_active":
            if current_card["lifecycle"] not in {"proposed", "active"}:
                raise BrainControlError("BRAIN_CONTROL_CARD_FORGET_UNAVAILABLE", "only active or proposed cards can be forgotten")
            if hard_completion_decision:
                raise BrainControlError(
                    "BRAIN_CONTROL_DECISION_FORGET_UNAVAILABLE",
                    "a completion-gate decision must be explicitly superseded or cancelled before it can be forgotten",
                )
            return {
                **dict(normalized),
                "kind": current_card["kind"],
                "scope": current_card["scope"],
                "lifecycle": "forgotten",
                "authority": current_card["authority"],
                "privacyClass": current_card["privacyClass"],
                "title": "Forgotten card",
                "payload": {
                    "schema": "super-brain.card.tombstone.v1",
                    "forgotten": True,
                    "originalKind": current_card["kind"],
                },
                "evidenceRefs": [],
                "forgottenFromRevision": actual_revision,
            }
        if command_type == "forget_trashed":
            if current_card["lifecycle"] != "trashed":
                raise BrainControlError("BRAIN_CONTROL_CARD_TRASH_DELETE_UNAVAILABLE", "only trashed cards can be permanently deleted from the recycle bin")
            return {
                **dict(normalized),
                "kind": current_card["kind"],
                "scope": current_card["scope"],
                "lifecycle": "forgotten",
                "authority": current_card["authority"],
                "privacyClass": current_card["privacyClass"],
                "title": "Forgotten card",
                "payload": {
                    "schema": "super-brain.card.tombstone.v1",
                    "forgotten": True,
                    "originalKind": current_card["kind"],
                },
                "evidenceRefs": [],
                "forgottenFromRevision": actual_revision,
            }
        if command_type == "rollback_card":
            if current_card["lifecycle"] in {"trashed", "forgotten"}:
                raise BrainControlError(
                    "BRAIN_CONTROL_CARD_ROLLBACK_UNAVAILABLE",
                    "trashed or forgotten cards cannot be restored by rollback",
                )
            restore_revision = int(normalized["restoreRevision"])
            if restore_revision >= actual_revision:
                raise BrainControlError(
                    "BRAIN_CONTROL_CARD_ROLLBACK_TARGET_INVALID",
                    "rollback target must be an earlier revision",
                )
            restored = self._read_card_revision(
                connection,
                str(normalized["aggregateId"]),
                restore_revision,
                require_typed_state=True,
            )
            state = restored["revisionState"]
            lifecycle = str(state["lifecycle"])
            if lifecycle not in {"proposed", "active"}:
                raise BrainControlError(
                    "BRAIN_CONTROL_CARD_ROLLBACK_TARGET_INVALID",
                    "rollback can only restore a proposed or active revision",
                )
            return {
                **dict(normalized),
                "kind": str(state["kind"]),
                "scope": dict(state["scope"]),
                "lifecycle": lifecycle,
                "authority": str(state["authority"]),
                "privacyClass": str(state["privacyClass"]),
                "title": restored["title"],
                "payload": restored["payload"],
                "evidenceRefs": restored["evidenceRefs"],
                "rollbackOfRevision": restore_revision,
            }
        raise BrainControlError("BRAIN_CONTROL_COMMAND_UNSUPPORTED", f"unsupported commandType: {command_type}")

    def _apply_in_transaction(
        self,
        connection: sqlite3.Connection,
        normalized: Mapping[str, Any],
        payload_hash: str,
    ) -> dict[str, Any]:
        existing = connection.execute(
            "SELECT payload_hash, result_json FROM command_log WHERE command_id=?", (normalized["commandId"],)
        ).fetchone()
        if existing is not None:
            if str(existing["payload_hash"]) != payload_hash:
                raise BrainControlError(
                    "BRAIN_CONTROL_COMMAND_ID_REUSED", "commandId was already used with a different payload"
                )
            result = json.loads(str(existing["result_json"]))
            result["idempotent"] = True
            return result

        current = connection.execute(
            "SELECT card_id,kind,scope_kind,scope_key,lifecycle,authority,privacy_class,head_revision FROM cards WHERE card_id=?",
            (normalized["aggregateId"],),
        ).fetchone()
        actual_revision = int(current["head_revision"]) if current is not None else 0
        if actual_revision != normalized["expectedRevision"]:
            raise BrainControlError(
                "BRAIN_CONTROL_STALE_REVISION",
                f"expected revision {normalized['expectedRevision']}, found {actual_revision}",
            )
        effective = self._resolve_card_mutation(connection, normalized, current, actual_revision)
        next_revision = actual_revision + 1
        previous = connection.execute(
            "SELECT content_hash FROM card_revisions WHERE card_id=? AND revision=?",
            (normalized["aggregateId"], actual_revision),
        ).fetchone()
        predecessor_hash = str(previous["content_hash"]) if previous is not None else ""
        content = self._command_content(effective)
        content_hash = _sha256(content)
        now = _utc_now()
        if current is None:
            connection.execute(
                """
                INSERT INTO cards(card_id,kind,scope_kind,scope_key,lifecycle,authority,privacy_class,head_revision,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    effective["aggregateId"], effective["kind"], effective["scope"]["kind"],
                    effective["scope"]["key"], effective["lifecycle"], effective["authority"],
                    effective["privacyClass"], next_revision, now, now,
                ),
            )
        else:
            connection.execute(
                """
                UPDATE cards SET kind=?, scope_kind=?, scope_key=?, lifecycle=?, authority=?, privacy_class=?,
                  head_revision=?, updated_at=? WHERE card_id=?
                """,
                (
                    effective["kind"], effective["scope"]["kind"], effective["scope"]["key"],
                    effective["lifecycle"], effective["authority"], effective["privacyClass"],
                    next_revision, now, effective["aggregateId"],
                ),
            )
        source_context = effective.get("sourceContext")
        if current is None and isinstance(source_context, Mapping):
            connection.execute(
                """
                INSERT INTO card_source_links(
                  card_id,task_id,task_instance_id,workspace_key,owner_session_key,conversation_title,created_at
                ) VALUES (?,?,?,?,?,?,?)
                """,
                (
                    effective["aggregateId"],
                    str(source_context["taskId"]),
                    str(source_context.get("taskInstanceId", "")),
                    str(source_context["workspaceKey"]),
                    str(source_context["ownerSessionKey"]),
                    str(source_context.get("conversationTitle", "")),
                    now,
                ),
            )
        connection.execute(
            """
            INSERT INTO card_revisions(card_id,revision,predecessor_hash,content_hash,title,structured_payload,evidence_refs,actor_receipt,state_json,created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            (
                effective["aggregateId"], next_revision, predecessor_hash, content_hash, effective["title"],
                _canonical_json(effective["payload"]), _canonical_json(effective["evidenceRefs"]),
                _canonical_json(effective["actorReceipt"]), _canonical_json(self._revision_state(effective)), now,
            ),
        )
        event_id = "evt-" + uuid.uuid4().hex
        result = {
            "ok": True,
            "schema": "super-brain.brain-control-receipt.v1",
            "commandId": normalized["commandId"],
            "aggregateId": normalized["aggregateId"],
            "revision": next_revision,
            "contentHash": content_hash,
            "eventId": event_id,
            "operation": effective["operation"],
            "kind": effective["kind"],
            "lifecycle": effective["lifecycle"],
            "rollbackOfRevision": effective.get("rollbackOfRevision"),
            "idempotent": False,
        }
        connection.execute(
            """
            INSERT INTO command_log(command_id,command_type,aggregate_id,expected_revision,payload_hash,result_json,created_at)
            VALUES (?,?,?,?,?,?,?)
            """,
            (
                normalized["commandId"], normalized["commandType"], normalized["aggregateId"],
                normalized["expectedRevision"], payload_hash, _canonical_json(result), now,
            ),
        )
        connection.execute(
            """
            INSERT INTO events(event_id,command_id,command_type,aggregate_id,revision,expected_revision,result_code,reason_code,source,created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """,
            (
                event_id, normalized["commandId"], normalized["commandType"], normalized["aggregateId"],
                next_revision, normalized["expectedRevision"], "applied", effective["operation"], normalized["source"], now,
            ),
        )
        projection = {
            "eventId": event_id,
            "aggregateId": effective["aggregateId"],
            "revision": next_revision,
            "kind": effective["kind"],
            "contentHash": content_hash,
            "lifecycle": effective["lifecycle"],
            "operation": effective["operation"],
            "privacyClass": effective["privacyClass"],
            "redactedPayload": _redact_card_payload(effective["kind"], effective["payload"], effective["privacyClass"]),
        }
        connection.execute(
            """
            INSERT INTO outbox(event_id,aggregate_id,revision,projection_kind,payload_json,status,delivery_version,created_at)
            VALUES (?,?,?,?,?,?,?,?)
            """,
            (event_id, normalized["aggregateId"], next_revision, "card_projection", _canonical_json(projection), "pending", 1, now),
        )
        self._write_card_search_row(
            connection,
            str(effective["aggregateId"]),
            next_revision,
            str(effective["title"]),
            effective["payload"],
            str(effective["lifecycle"]),
        )
        connection.execute("DELETE FROM ui_drafts WHERE card_id=?", (str(effective["aggregateId"]),))
        if effective["operation"] == "forget":
            tombstone = {
                "schema": "super-brain.card-privacy-tombstone.v1",
                "cardId": effective["aggregateId"],
                "forgottenRevision": next_revision,
                "forgottenFromRevision": effective.get("forgottenFromRevision"),
                "kind": effective["kind"],
            }
            connection.execute(
                """
                INSERT INTO card_privacy_tombstones(card_id,forgotten_revision,tombstone_hash,forgotten_at,purge_state,purge_preview_id)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(card_id) DO UPDATE SET
                  forgotten_revision=excluded.forgotten_revision,
                  tombstone_hash=excluded.tombstone_hash,
                  forgotten_at=excluded.forgotten_at,
                  purge_state='none',
                  purge_preview_id=''
                """,
                (effective["aggregateId"], next_revision, _sha256(tombstone), now, "none", ""),
            )
        return result

    @staticmethod
    def _command_content(command: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "kind": command["kind"],
            "scope": command["scope"],
            "lifecycle": command["lifecycle"],
            "authority": command["authority"],
            "privacyClass": command["privacyClass"],
            "title": command["title"],
            "payload": command["payload"],
            "evidenceRefs": command["evidenceRefs"],
            "actorReceipt": command["actorReceipt"],
        }

    def get_card(self, card_id: str) -> dict[str, Any] | None:
        with self._connection() as connection:
            row = connection.execute(
                """
                SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
                  r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
                  r.state_json,r.created_at
                FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
                WHERE c.card_id=?
                """,
                (card_id,),
            ).fetchone()
        if row is None:
            return None
        return self._card_from_row(row)

    @staticmethod
    def _ui_card_summary(card: Mapping[str, Any]) -> str:
        if card.get("lifecycle") == "forgotten":
            return "这条记录已忘记，当前正文不再显示。"
        payload = card.get("payload")
        if not isinstance(payload, Mapping):
            return ""
        preferred_fields = (
            "body",
            "statement",
            "lesson",
            "summary",
            "objective",
            "observation",
            "context",
            "outcome",
        )
        for field in preferred_fields:
            value = payload.get(field)
            if isinstance(value, str) and value:
                return re.sub(r"\s+", " ", value).strip()[:320]
        return ""

    @classmethod
    def _ui_card_view(cls, card: Mapping[str, Any], *, include_payload: bool) -> dict[str, Any]:
        payload = card.get("payload")
        lifecycle = str(card.get("lifecycle", ""))
        view: dict[str, Any] = {
            "cardId": str(card["cardId"]),
            "kind": str(card["kind"]),
            "scope": dict(card["scope"]),
            "lifecycle": lifecycle,
            "authority": str(card["authority"]),
            "privacyClass": str(card["privacyClass"]),
            "revision": int(card["revision"]),
            "contentHash": str(card["contentHash"]),
            "createdAt": str(card["createdAt"]),
        }
        if lifecycle == "forgotten":
            view.update(
                {
                    "title": "已忘记的卡片",
                    "summary": cls._ui_card_summary(card),
                    "forgotten": True,
                    "payload": {"schema": "super-brain.card.tombstone.v1", "forgotten": True} if include_payload else None,
                }
            )
            return view
        view.update(
            {
                "title": str(card["title"]),
                "summary": cls._ui_card_summary(card),
                "forgotten": False,
            }
        )
        if include_payload:
            view["payload"] = dict(payload) if isinstance(payload, Mapping) else {}
            view["evidenceRefs"] = list(card.get("evidenceRefs", []))
            view["revisionState"] = dict(card.get("revisionState", {}))
        return view

    def _ui_card_view_with_trial(self, card: Mapping[str, Any], *, include_payload: bool) -> dict[str, Any]:
        view = self._ui_card_view(card, include_payload=include_payload)
        if str(card.get("kind", "")) == "reflection":
            payload = card.get("payload") if isinstance(card.get("payload"), Mapping) else {}
            view["suggestedKind"] = self._reflection_suggested_kind(payload)
            trial = self._typed_memory_trial_projection_for_card(card)
            view["trial"] = {
                "verdict": trial["trialVerdict"],
                "trialState": trial["trialState"],
                "receiptHash": trial["trialReceiptHash"],
                "receiptRef": trial["trialReceiptRef"],
                "reason": trial["trialReason"],
            }
        return view

    @staticmethod
    def _ui_filter_values(values: Sequence[str] | None, field: str, allowed: frozenset[str]) -> list[str]:
        if values is None:
            return []
        normalized: list[str] = []
        for value in values:
            candidate = _require_string(value, field, 64).lower()
            if candidate not in allowed:
                raise BrainControlError("BRAIN_CONTROL_UI_FILTER_INVALID", f"unsupported {field}: {candidate}")
            if candidate not in normalized:
                normalized.append(candidate)
        if len(normalized) > 12:
            raise BrainControlError("BRAIN_CONTROL_UI_FILTER_INVALID", f"{field} exceeds 12 values")
        return normalized

    def _query_ui_cards(
        self,
        *,
        kinds: Sequence[str] | None = None,
        lifecycles: Sequence[str] | None = None,
        scope_kind: str = "",
        scope_key: str = "",
        limit: int = 50,
        offset: int = 0,
        fts: str = "",
    ) -> tuple[list[dict[str, Any]], bool]:
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1 or limit > 100:
            raise BrainControlError("BRAIN_CONTROL_UI_PAGE_INVALID", "limit must be between 1 and 100")
        if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0 or offset > 10_000:
            raise BrainControlError("BRAIN_CONTROL_UI_PAGE_INVALID", "offset must be between 0 and 10000")
        normalized_kinds = self._ui_filter_values(kinds, "kind", CARD_KINDS)
        normalized_lifecycles = self._ui_filter_values(lifecycles, "lifecycle", LIFECYCLES)
        normalized_scope_kind = _card_text(scope_kind, "scopeKind", 64, required=False)
        normalized_scope_key = _card_text(scope_key, "scopeKey", 256, required=False)
        clauses: list[str] = []
        params: list[Any] = []
        if fts:
            clauses.append("s.search_text MATCH ?")
            params.append(fts)
        if normalized_kinds:
            placeholders = ",".join("?" for _ in normalized_kinds)
            clauses.append(f"c.kind IN ({placeholders})")
            params.extend(normalized_kinds)
        if normalized_lifecycles:
            placeholders = ",".join("?" for _ in normalized_lifecycles)
            clauses.append(f"c.lifecycle IN ({placeholders})")
            params.extend(normalized_lifecycles)
        else:
            clauses.append("c.lifecycle IN ('active','proposed')")
        if normalized_scope_kind:
            clauses.append("c.scope_kind=?")
            params.append(normalized_scope_kind)
        if normalized_scope_key:
            clauses.append("c.scope_key=?")
            params.append(normalized_scope_key)
        from_clause = (
            "FROM card_search s JOIN cards c ON c.card_id=s.card_id AND c.head_revision=s.revision "
            "JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision"
            if fts
            else "FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision"
        )
        where_clause = " WHERE " + " AND ".join(clauses) if clauses else ""
        sql = (
            "SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,"
            "r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,"
            "r.state_json,r.created_at "
            + from_clause
            + where_clause
            + " ORDER BY c.updated_at DESC,c.card_id ASC LIMIT ? OFFSET ?"
        )
        params.extend([limit + 1, offset])
        with self._connection() as connection:
            rows = connection.execute(sql, params).fetchall()
        has_more = len(rows) > limit
        return [self._ui_card_view_with_trial(self._card_from_row(row), include_payload=False) for row in rows[:limit]], has_more

    def list_cards_for_ui(
        self,
        *,
        kinds: Sequence[str] | None = None,
        lifecycles: Sequence[str] | None = None,
        scope_kind: str = "",
        scope_key: str = "",
        limit: int = 50,
        offset: int = 0,
    ) -> dict[str, Any]:
        items, has_more = self._query_ui_cards(
            kinds=kinds,
            lifecycles=lifecycles,
            scope_kind=scope_kind,
            scope_key=scope_key,
            limit=limit,
            offset=offset,
        )
        return {
            "ok": True,
            "schema": "super-brain.ui-card-list.v1",
            "items": items,
            "nextOffset": offset + len(items) if has_more else None,
        }

    def search_cards_for_ui(
        self,
        query: str,
        *,
        kinds: Sequence[str] | None = None,
        lifecycles: Sequence[str] | None = None,
        scope_kind: str = "",
        scope_key: str = "",
        limit: int = 50,
        offset: int = 0,
    ) -> dict[str, Any]:
        normalized_query = _fts_query(query)
        if not normalized_query:
            return self.list_cards_for_ui(
                kinds=kinds,
                lifecycles=lifecycles,
                scope_kind=scope_kind,
                scope_key=scope_key,
                limit=limit,
                offset=offset,
            )
        items, has_more = self._query_ui_cards(
            kinds=kinds,
            lifecycles=lifecycles,
            scope_kind=scope_kind,
            scope_key=scope_key,
            limit=limit,
            offset=offset,
            fts=normalized_query,
        )
        return {
            "ok": True,
            "schema": "super-brain.ui-card-search.v1",
            "items": items,
            "nextOffset": offset + len(items) if has_more else None,
        }

    @staticmethod
    def _task_card_ui_text(value: Any, maximum: int) -> str:
        if not isinstance(value, str):
            return ""
        return re.sub(r"\s+", " ", value).strip()[:maximum]

    @classmethod
    def _task_card_ui_list(cls, value: Any, maximum: int = 12) -> list[str]:
        if not isinstance(value, list):
            return []
        return [
            normalized
            for item in value[:maximum]
            if (normalized := cls._task_card_ui_text(item, 240))
        ]

    @staticmethod
    def _task_completed_at(state: Mapping[str, Any]) -> str:
        candidates: list[Any] = [state.get("completedAt"), state.get("completed_at")]
        lifecycle = state.get("lifecycle")
        if isinstance(lifecycle, Mapping):
            candidates.extend([lifecycle.get("completedAt"), lifecycle.get("completed_at")])
        for candidate in candidates:
            if isinstance(candidate, str) and _parse_utc_timestamp(candidate) is not None:
                return candidate.strip()
        return ""

    def _task_history_records_for_ui(self, scope: Mapping[str, Any] | None) -> list[dict[str, Any]]:
        if not isinstance(scope, Mapping):
            return []
        workspace_key = _optional_string(scope.get("workspaceKey"), "taskHistory.workspaceKey", 120)
        current_task_id = _optional_string(scope.get("taskId"), "taskHistory.taskId", 160)
        current_owner_session = _optional_string(scope.get("ownerSessionKey"), "taskHistory.ownerSessionKey", 120)
        if not workspace_key:
            return []
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT a.aggregate_id,a.task_id,a.task_instance_id,a.workspace_key,a.owner_session_key,
                  a.lifecycle,a.head_revision,a.head_state_hash,a.updated_at,r.state_json
                FROM task_aggregates a
                JOIN task_state_revisions r ON r.aggregate_id=a.aggregate_id AND r.task_revision=a.head_revision
                WHERE a.workspace_key=?
                ORDER BY a.updated_at DESC,a.task_id ASC
                LIMIT 100
                """,
                (workspace_key,),
            ).fetchall()
        records: list[dict[str, Any]] = []
        active_lifecycles = {"planned", "active", "paused", "blocked"}
        for row in rows:
            lifecycle = str(row["lifecycle"])
            if lifecycle in active_lifecycles and (
                str(row["task_id"]) != current_task_id or str(row["owner_session_key"]) != current_owner_session
            ):
                continue
            try:
                state = json.loads(str(row["state_json"]))
            except json.JSONDecodeError:
                state = {}
            if not isinstance(state, Mapping):
                state = {}
            title = self._task_ui_title(str(row["task_id"]), state, None)
            content = self._task_ui_summary(state, None, state.get("canonicalPlan") if isinstance(state.get("canonicalPlan"), Mapping) else None, [])
            records.append(
                {
                    "taskKey": _sha256({"aggregateId": str(row["aggregate_id"])}),
                    "aggregateId": str(row["aggregate_id"]),
                    "workspaceKey": str(row["workspace_key"]),
                    "ownerSessionKey": str(row["owner_session_key"]),
                    "taskRevision": int(row["head_revision"]),
                    "stateHash": str(row["head_state_hash"]),
                    "status": lifecycle,
                    "title": title,
                    "content": content,
                    "currentStep": self._task_ui_plan_label(_optional_string(state.get("currentStep"), "taskHistory.currentStep", 240)),
                    "nextAction": self._task_ui_plan_label(_optional_string(state.get("nextAction"), "taskHistory.nextAction", 240)),
                    "completedSteps": self._task_card_ui_list(state.get("completedSteps")),
                    "pendingSteps": self._task_card_ui_list(state.get("pendingSteps")),
                    "completedAt": self._task_completed_at(state),
                    "updatedAt": str(row["updated_at"]),
                    "eligibleForRetention": lifecycle == "completed" and bool(self._task_completed_at(state)),
                }
            )
        return records

    @staticmethod
    def _task_retention_settings_in_transaction(connection: sqlite3.Connection) -> dict[str, Any]:
        row = connection.execute(
            "SELECT completed_days,trash_days,revision,updated_at FROM ui_task_retention_settings WHERE settings_key='default'"
        ).fetchone()
        if row is None:
            now = _utc_now()
            connection.execute(
                """
                INSERT INTO ui_task_retention_settings(settings_key,completed_days,trash_days,revision,updated_at)
                VALUES ('default',?,?,?,?)
                """,
                (TASK_RETENTION_DEFAULT_COMPLETED_DAYS, TASK_RETENTION_DEFAULT_TRASH_DAYS, 1, now),
            )
            return {
                "completedDays": TASK_RETENTION_DEFAULT_COMPLETED_DAYS,
                "trashDays": TASK_RETENTION_DEFAULT_TRASH_DAYS,
                "revision": 1,
                "updatedAt": now,
            }
        return {
            "completedDays": int(row["completed_days"]),
            "trashDays": int(row["trash_days"]),
            "revision": int(row["revision"]),
            "updatedAt": str(row["updated_at"]),
        }

    @staticmethod
    def _task_retention_actor(actor_receipt: Mapping[str, Any] | None) -> dict[str, Any]:
        if isinstance(actor_receipt, Mapping):
            return dict(actor_receipt)
        return {
            "schema": ACTOR_RECEIPT_SCHEMA,
            "actorKind": "system",
            "actorId": "local_task_retention",
            "authorization": "system",
            "authorizationReceipt": "",
        }

    @staticmethod
    def _task_retention_target_state(completed_at: datetime, now: datetime, settings: Mapping[str, Any]) -> tuple[str, datetime]:
        trash_at = completed_at + timedelta(days=int(settings["completedDays"]))
        cleanup_at = trash_at + timedelta(days=int(settings["trashDays"]))
        if now >= cleanup_at:
            return "cleanup_preview", cleanup_at
        if now >= trash_at:
            return "trashed", trash_at
        return "visible", completed_at

    @staticmethod
    def _record_task_retention_receipt(
        connection: sqlite3.Connection,
        record: Mapping[str, Any],
        *,
        action: str,
        from_state: str,
        to_state: str,
        effective_completed_at: str,
        settings: Mapping[str, Any],
        actor_receipt: Mapping[str, Any] | None,
        now: str,
    ) -> None:
        connection.execute(
            """
            INSERT INTO ui_task_retention_receipts(
              receipt_id,task_key,aggregate_id,task_revision,state_hash,action,from_state,to_state,
              effective_completed_at,settings_json,actor_receipt,created_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                "task-retention-" + uuid.uuid4().hex,
                str(record["taskKey"]),
                str(record["aggregateId"]),
                int(record["taskRevision"]),
                str(record["stateHash"]),
                action,
                from_state,
                to_state,
                effective_completed_at,
                _canonical_json(settings),
                _canonical_json(BrainControl._task_retention_actor(actor_receipt)),
                now,
            ),
        )

    def _sweep_task_retention_in_transaction(
        self,
        connection: sqlite3.Connection,
        records: Sequence[Mapping[str, Any]],
        *,
        now: datetime,
        actor_receipt: Mapping[str, Any] | None = None,
    ) -> tuple[dict[str, str], dict[str, int], dict[str, Any]]:
        settings = self._task_retention_settings_in_transaction(connection)
        state_by_task: dict[str, str] = {}
        changes = {"movedToTrash": 0, "markedForCleanup": 0, "restored": 0, "needsReview": 0}
        now_text = _utc_timestamp(now)
        for record in records:
            task_key = str(record["taskKey"])
            row = connection.execute(
                """
                SELECT aggregate_id,workspace_key,owner_session_key,task_revision,state_hash,retention_state,
                  effective_completed_at,state_changed_at
                FROM ui_task_card_retention WHERE task_key=?
                """,
                (task_key,),
            ).fetchone()
            binding_matches = row is None or (
                str(row["aggregate_id"]) == str(record["aggregateId"])
                and str(row["workspace_key"]) == str(record["workspaceKey"])
                and str(row["owner_session_key"]) == str(record["ownerSessionKey"])
                and int(row["task_revision"]) == int(record["taskRevision"])
                and str(row["state_hash"]) == str(record["stateHash"])
            )
            if not binding_matches:
                state_by_task[task_key] = "needs_review"
                changes["needsReview"] += 1
                continue
            if str(record["status"]) != "completed":
                if row is not None and str(row["retention_state"]) != "visible":
                    connection.execute(
                        """
                        UPDATE ui_task_card_retention
                        SET retention_state='visible',state_changed_at=?,updated_at=? WHERE task_key=?
                        """,
                        (now_text, now_text, task_key),
                    )
                    self._record_task_retention_receipt(
                        connection,
                        record,
                        action="reopened",
                        from_state=str(row["retention_state"]),
                        to_state="visible",
                        effective_completed_at=str(row["effective_completed_at"]),
                        settings=settings,
                        actor_receipt=actor_receipt,
                        now=now_text,
                    )
                state_by_task[task_key] = "visible"
                continue
            completed_at = _parse_utc_timestamp(record.get("completedAt")) if bool(record.get("eligibleForRetention")) else None
            if completed_at is None:
                state_by_task[task_key] = "needs_review"
                changes["needsReview"] += 1
                continue
            effective_completed_at = completed_at
            if row is not None:
                parsed_effective = _parse_utc_timestamp(str(row["effective_completed_at"]))
                if parsed_effective is None:
                    state_by_task[task_key] = "needs_review"
                    changes["needsReview"] += 1
                    continue
                effective_completed_at = parsed_effective
            target_state, state_changed_at = self._task_retention_target_state(effective_completed_at, now, settings)
            if row is None:
                connection.execute(
                    """
                    INSERT INTO ui_task_card_retention(
                      task_key,aggregate_id,workspace_key,owner_session_key,task_revision,state_hash,
                      retention_state,effective_completed_at,state_changed_at,updated_at
                    ) VALUES (?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        task_key,
                        str(record["aggregateId"]),
                        str(record["workspaceKey"]),
                        str(record["ownerSessionKey"]),
                        int(record["taskRevision"]),
                        str(record["stateHash"]),
                        target_state,
                        _utc_timestamp(effective_completed_at),
                        _utc_timestamp(state_changed_at),
                        now_text,
                    ),
                )
                if target_state != "visible":
                    action = "marked_for_cleanup" if target_state == "cleanup_preview" else "moved_to_trash"
                    self._record_task_retention_receipt(
                        connection,
                        record,
                        action=action,
                        from_state="visible",
                        to_state=target_state,
                        effective_completed_at=_utc_timestamp(effective_completed_at),
                        settings=settings,
                        actor_receipt=actor_receipt,
                        now=now_text,
                    )
                    changes["markedForCleanup" if target_state == "cleanup_preview" else "movedToTrash"] += 1
                state_by_task[task_key] = target_state
                continue
            current_state = str(row["retention_state"])
            order = {"visible": 0, "trashed": 1, "cleanup_preview": 2}
            if order[target_state] > order.get(current_state, -1):
                connection.execute(
                    """
                    UPDATE ui_task_card_retention
                    SET retention_state=?,state_changed_at=?,updated_at=? WHERE task_key=?
                    """,
                    (target_state, _utc_timestamp(state_changed_at), now_text, task_key),
                )
                action = "marked_for_cleanup" if target_state == "cleanup_preview" else "moved_to_trash"
                self._record_task_retention_receipt(
                    connection,
                    record,
                    action=action,
                    from_state=current_state,
                    to_state=target_state,
                    effective_completed_at=_utc_timestamp(effective_completed_at),
                    settings=settings,
                    actor_receipt=actor_receipt,
                    now=now_text,
                )
                changes["markedForCleanup" if target_state == "cleanup_preview" else "movedToTrash"] += 1
                current_state = target_state
            state_by_task[task_key] = current_state
        return state_by_task, changes, settings

    def task_history_for_ui(self, *, scope: Mapping[str, Any] | None = None, limit: int = 80) -> dict[str, Any]:
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1 or limit > 100:
            raise BrainControlError("BRAIN_CONTROL_UI_PAGE_INVALID", "limit must be between 1 and 100")
        effective_scope = scope
        if effective_scope is None:
            effective_scope, _ = self._current_execution_scope_for_ui()
        records = self._task_history_records_for_ui(effective_scope)
        now = datetime.now(UTC)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                state_by_task, changes, settings = self._sweep_task_retention_in_transaction(connection, records, now=now)
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        counts = {"visible": 0, "trashed": 0, "cleanupPreview": 0, "needsReview": 0}
        items: list[dict[str, Any]] = []
        for record in records[:limit]:
            retention_state = state_by_task.get(str(record["taskKey"]), "visible")
            if retention_state == "needs_review":
                counts["needsReview"] += 1
            elif retention_state == "cleanup_preview":
                counts["cleanupPreview"] += 1
            else:
                counts[retention_state] += 1
            status = str(record["status"])
            items.append(
                {
                    "taskCardKey": str(record["taskKey"]),
                    "title": str(record["title"]),
                    "content": str(record["content"]),
                    "statusLabel": TASK_CARD_UI_STATUS_LABELS.get(status, "待核对"),
                    "isCompleted": status == "completed",
                    "retentionLabel": "待核对" if retention_state == "needs_review" else TASK_CARD_RETENTION_LABELS.get(retention_state, "任务记录"),
                    "retentionState": retention_state,
                    "completedSteps": list(record["completedSteps"]),
                    "pendingSteps": list(record["pendingSteps"]),
                    "currentStep": str(record["currentStep"]),
                    "nextAction": str(record["nextAction"]),
                    "date": str(record["completedAt"] or record["updatedAt"]),
                    "sourceLabel": "当前项目",
                    "canRestore": retention_state in {"trashed", "cleanup_preview"},
                    "retentionHint": (
                        "完成时间或验证信息不完整，暂不自动整理。"
                        if retention_state == "needs_review"
                        else ""
                    ),
                }
            )
        return {
            "ok": True,
            "schema": TASK_HISTORY_SCHEMA,
            "scopeBound": isinstance(effective_scope, Mapping),
            "items": items,
            "counts": counts,
            "settings": settings,
            "maintenance": changes,
        }

    def preview_task_retention_for_ui(
        self,
        *,
        completed_days: int,
        trash_days: int,
        scope: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Preview task-card visibility changes without updating retention state."""

        if isinstance(completed_days, bool) or not isinstance(completed_days, int) or not 1 <= completed_days <= TASK_RETENTION_MAX_DAYS:
            raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_DAYS_INVALID", "completedDays must be between 1 and 3650")
        if isinstance(trash_days, bool) or not isinstance(trash_days, int) or not 1 <= trash_days <= TASK_RETENTION_MAX_DAYS:
            raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_DAYS_INVALID", "trashDays must be between 1 and 3650")
        effective_scope = scope
        if effective_scope is None:
            effective_scope, _ = self._current_execution_scope_for_ui()
        records = self._task_history_records_for_ui(effective_scope)
        settings = {"completedDays": completed_days, "trashDays": trash_days}
        counts = {"visible": 0, "trashed": 0, "cleanupPreview": 0, "needsReview": 0}
        impacts: dict[str, list[dict[str, str]]] = {"toTrash": [], "cleanupPreview": [], "needsReview": []}
        now = datetime.now(UTC)
        for record in records:
            if str(record.get("status")) != "completed":
                counts["visible"] += 1
                continue
            completed_at = _parse_utc_timestamp(record.get("completedAt")) if bool(record.get("eligibleForRetention")) else None
            if completed_at is None:
                counts["needsReview"] += 1
                if len(impacts["needsReview"]) < 12:
                    impacts["needsReview"].append({"title": str(record.get("title") or "未命名任务")})
                continue
            target_state, _ = self._task_retention_target_state(completed_at, now, settings)
            if target_state == "cleanup_preview":
                counts["cleanupPreview"] += 1
                if len(impacts["cleanupPreview"]) < 12:
                    impacts["cleanupPreview"].append({"title": str(record.get("title") or "未命名任务")})
            elif target_state == "trashed":
                counts["trashed"] += 1
                if len(impacts["toTrash"]) < 12:
                    impacts["toTrash"].append({"title": str(record.get("title") or "未命名任务")})
            else:
                counts["visible"] += 1
        return {
            "ok": True,
            "schema": TASK_RETENTION_PREVIEW_SCHEMA,
            "scopeBound": isinstance(effective_scope, Mapping),
            "settings": settings,
            "counts": counts,
            "impacts": impacts,
            "summary": "这是预览，不会移动、删除或修改任何任务卡和个人记忆。",
        }

    def update_task_retention_settings(
        self,
        *,
        completed_days: int,
        trash_days: int,
        expected_revision: int,
        actor_receipt: Mapping[str, Any],
    ) -> dict[str, Any]:
        if isinstance(completed_days, bool) or not isinstance(completed_days, int) or not 1 <= completed_days <= TASK_RETENTION_MAX_DAYS:
            raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_DAYS_INVALID", "completedDays must be between 1 and 3650")
        if isinstance(trash_days, bool) or not isinstance(trash_days, int) or not 1 <= trash_days <= TASK_RETENTION_MAX_DAYS:
            raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_DAYS_INVALID", "trashDays must be between 1 and 3650")
        if isinstance(expected_revision, bool) or not isinstance(expected_revision, int) or expected_revision < 1:
            raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_REVISION_INVALID", "expectedRevision must be positive")
        actor = _normalize_actor_receipt(actor_receipt)
        if actor["authorization"] not in {"user_confirmed", "test"}:
            raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", "task retention settings require user confirmation")
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                current = self._task_retention_settings_in_transaction(connection)
                if int(current["revision"]) != expected_revision:
                    raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_STALE", "task retention settings changed; refresh before saving")
                now = _utc_now()
                updated = {
                    "completedDays": completed_days,
                    "trashDays": trash_days,
                    "revision": expected_revision + 1,
                    "updatedAt": now,
                }
                connection.execute(
                    """
                    UPDATE ui_task_retention_settings
                    SET completed_days=?,trash_days=?,revision=?,updated_at=? WHERE settings_key='default'
                    """,
                    (completed_days, trash_days, updated["revision"], now),
                )
                settings_record = {
                    "taskKey": "settings",
                    "aggregateId": "settings",
                    "taskRevision": updated["revision"],
                    "stateHash": _sha256(updated),
                }
                self._record_task_retention_receipt(
                    connection,
                    settings_record,
                    action="settings_updated",
                    from_state="settings",
                    to_state="settings",
                    effective_completed_at="",
                    settings=updated,
                    actor_receipt=actor,
                    now=now,
                )
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return {"ok": True, "schema": TASK_RETENTION_SETTINGS_SCHEMA, "settings": updated}

    def restore_task_card_for_ui(self, task_card_key: str, actor_receipt: Mapping[str, Any]) -> dict[str, Any]:
        normalized_key = _require_sha256(task_card_key, "taskCardKey")
        actor = _normalize_actor_receipt(actor_receipt)
        if actor["authorization"] not in {"user_confirmed", "test"}:
            raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", "restoring a task card requires user confirmation")
        current_scope, _ = self._current_execution_scope_for_ui()
        if not isinstance(current_scope, Mapping):
            raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_SCOPE_WITHHELD", "current workspace scope is unavailable")
        workspace_key = _require_string(current_scope.get("workspaceKey"), "taskRetention.workspaceKey", 120)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                row = connection.execute(
                    """
                    SELECT task_key,aggregate_id,workspace_key,owner_session_key,task_revision,state_hash,retention_state
                    FROM ui_task_card_retention WHERE task_key=?
                    """,
                    (normalized_key,),
                ).fetchone()
                if row is None or str(row["workspace_key"]) != workspace_key:
                    raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_NOT_FOUND", "task card is not available in this workspace")
                if str(row["retention_state"]) not in {"trashed", "cleanup_preview"}:
                    raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_RESTORE_INVALID", "task card is not in the recycle bin or cleanup preview")
                aggregate = connection.execute(
                    """
                    SELECT head_revision,head_state_hash,lifecycle FROM task_aggregates WHERE aggregate_id=?
                    """,
                    (str(row["aggregate_id"]),),
                ).fetchone()
                if (
                    aggregate is None
                    or str(aggregate["lifecycle"]) != "completed"
                    or int(aggregate["head_revision"]) != int(row["task_revision"])
                    or str(aggregate["head_state_hash"]) != str(row["state_hash"])
                ):
                    raise BrainControlError("BRAIN_CONTROL_TASK_RETENTION_STALE", "task completion evidence changed; refresh before restoring")
                now = _utc_now()
                settings = self._task_retention_settings_in_transaction(connection)
                connection.execute(
                    """
                    UPDATE ui_task_card_retention
                    SET retention_state='visible',effective_completed_at=?,state_changed_at=?,updated_at=? WHERE task_key=?
                    """,
                    (now, now, now, normalized_key),
                )
                record = {
                    "taskKey": normalized_key,
                    "aggregateId": str(row["aggregate_id"]),
                    "taskRevision": int(row["task_revision"]),
                    "stateHash": str(row["state_hash"]),
                }
                self._record_task_retention_receipt(
                    connection,
                    record,
                    action="restored",
                    from_state=str(row["retention_state"]),
                    to_state="visible",
                    effective_completed_at=now,
                    settings=settings,
                    actor_receipt=actor,
                    now=now,
                )
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return {
            "ok": True,
            "schema": TASK_RETENTION_RECEIPT_SCHEMA,
            "taskCardKey": normalized_key,
            "retentionState": "visible",
            "protectionRestartedAt": now,
        }

    def get_card_for_ui(self, card_id: str) -> dict[str, Any] | None:
        card = self.get_card(_require_string(card_id, "cardId", 160))
        return self._ui_card_view_with_trial(card, include_payload=True) if card is not None else None

    @staticmethod
    def _ui_card_reference(card_id: str) -> str:
        """Create a non-reversible, UI-safe reference for a local card."""

        return "card-" + _sha256({"cardId": card_id})

    def get_card_for_ui_reference(self, card_ref: Any) -> dict[str, Any] | None:
        """Resolve an opaque timeline/profile reference without returning an ID to the caller."""

        normalized_ref = _require_string(card_ref, "cardRef", 80)
        if not re.fullmatch(r"card-[a-f0-9]{64}", normalized_ref):
            raise BrainControlError("BRAIN_CONTROL_UI_CARD_REF_INVALID", "cardRef is invalid")
        with self._connection() as connection:
            rows = connection.execute("SELECT card_id FROM cards").fetchall()
        for row in rows:
            card_id = str(row["card_id"])
            if self._ui_card_reference(card_id) == normalized_ref:
                return self.get_card_for_ui(card_id)
        return None

    def get_card_history_for_ui(self, card_id: str, *, limit: int = 50, offset: int = 0) -> dict[str, Any]:
        normalized_card_id = _require_string(card_id, "cardId", 160)
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1 or limit > 100:
            raise BrainControlError("BRAIN_CONTROL_UI_PAGE_INVALID", "limit must be between 1 and 100")
        if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
            raise BrainControlError("BRAIN_CONTROL_UI_PAGE_INVALID", "offset must be non-negative")
        with self._connection() as connection:
            head_row = connection.execute(
                "SELECT head_revision FROM cards WHERE card_id=?", (normalized_card_id,)
            ).fetchone()
            if head_row is None:
                return {"ok": True, "schema": "super-brain.ui-card-history.v1", "items": [], "nextOffset": None}
            head = self._read_card_revision(connection, normalized_card_id, int(head_row["head_revision"]))
            rows = connection.execute(
                "SELECT revision,created_at FROM card_revisions WHERE card_id=? ORDER BY revision DESC LIMIT ? OFFSET ?",
                (normalized_card_id, limit + 1, offset),
            ).fetchall()
            if head["lifecycle"] == "forgotten":
                items = [
                    {
                        "cardId": normalized_card_id,
                        "revision": int(row["revision"]),
                        "createdAt": str(row["created_at"]),
                        "forgotten": True,
                        "title": "Forgotten card",
                    }
                    for row in rows[:limit]
                ]
            else:
                items = [
                    self._ui_card_view(
                        self._read_card_revision(connection, normalized_card_id, int(row["revision"])),
                        include_payload=True,
                    )
                    for row in rows[:limit]
                ]
        return {
            "ok": True,
            "schema": "super-brain.ui-card-history.v1",
            "items": items,
            "nextOffset": offset + len(items) if len(rows) > limit else None,
        }

    @staticmethod
    def _task_ui_plan_label(value: Any) -> str:
        raw = value.strip() if isinstance(value, str) else ""
        if not raw:
            return "未命名步骤"
        match = re.match(r"^(B\d+|P-1|P\d+(?:\.\d+)?)\b", raw)
        if match is None:
            return raw[:240]
        code = match.group(1)
        if code in TASK_UI_STEP_LABELS:
            return TASK_UI_STEP_LABELS[code]
        if code in TASK_UI_PLAN_LABELS:
            return TASK_UI_PLAN_LABELS[code]
        parent_code = code.split(".", 1)[0]
        return TASK_UI_PLAN_LABELS.get(parent_code, raw[:240])

    @staticmethod
    def _task_ui_title(task_id: str, state: Mapping[str, Any], contract: Mapping[str, Any] | None) -> str:
        candidates: list[Any] = [
            state.get("focusLabel"),
            state.get("title"),
        ]
        plan_value = state.get("canonicalPlan")
        if not isinstance(plan_value, Mapping) and isinstance(contract, Mapping):
            plan_value = contract.get("canonicalPlan")
        if isinstance(plan_value, Mapping):
            candidates.extend([plan_value.get("title"), plan_value.get("name"), plan_value.get("label")])
        work_line_status = state.get("workLineStatus")
        if isinstance(work_line_status, Mapping):
            active_work_package = work_line_status.get("activeWorkPackage")
            if isinstance(active_work_package, Mapping):
                candidates.append(active_work_package.get("focusLabel"))
        if isinstance(contract, Mapping):
            candidates.append(contract.get("focusLabel"))
        for candidate in candidates:
            if not isinstance(candidate, str) or not candidate.strip():
                continue
            normalized = candidate.strip()
            if normalized == "Super Brain 0.6 integrated execution":
                return "超级大脑 0.6 集成实施"
            return normalized[:160]
        return "当前任务" if task_id else "未命名任务"

    @staticmethod
    def _task_ui_summary(
        state: Mapping[str, Any],
        contract: Mapping[str, Any] | None,
        plan_value: Mapping[str, Any] | None,
        items: list[dict[str, Any]],
    ) -> str:
        """Return a compact user-facing task description without leaking internal identifiers."""

        candidates: list[Any] = []
        for source in (state, contract, plan_value):
            if not isinstance(source, Mapping):
                continue
            for field in ("taskSummary", "summary", "description", "objective", "goal", "deliveryGoal"):
                candidates.append(source.get(field))
        work_line_status = state.get("workLineStatus")
        if isinstance(work_line_status, Mapping):
            active_work_package = work_line_status.get("activeWorkPackage")
            if isinstance(active_work_package, Mapping):
                for field in ("summary", "description", "objective", "goal"):
                    candidates.append(active_work_package.get(field))
        for candidate in candidates:
            if not isinstance(candidate, str) or not candidate.strip():
                continue
            return candidate.strip()[:600]
        labels = [str(item.get("label", "")).strip() for item in items if str(item.get("label", "")).strip()]
        if labels:
            return f"本任务将按清单依次完成：{'；'.join(labels[:3])}{'等' if len(labels) > 3 else ''}。"
        return "任务内容正在同步，先按下方清单推进。"

    @classmethod
    def _task_ui_display(
        cls,
        task_id: str,
        lifecycle: str,
        state: Mapping[str, Any],
        updated_at: str,
        contract: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        plan_value = state.get("canonicalPlan")
        if not isinstance(plan_value, Mapping) and isinstance(contract, Mapping):
            plan_value = contract.get("canonicalPlan")
        plan_items = plan_value.get("items") if isinstance(plan_value, Mapping) else []
        items: list[dict[str, Any]] = []
        if isinstance(plan_items, list):
            for item in plan_items[:32]:
                if not isinstance(item, Mapping):
                    continue
                status = _optional_string(item.get("status"), "task.plan.status", 32).lower() or "pending"
                label = cls._task_ui_plan_label(item.get("label"))
                items.append(
                    {
                        "itemId": _optional_string(item.get("itemId"), "task.plan.itemId", 160),
                        "ordinal": int(item.get("ordinal", 0)) if isinstance(item.get("ordinal", 0), int) else 0,
                        "label": label,
                        "status": status,
                        "statusLabel": TASK_UI_STATUS_LABELS.get(status, "待完成"),
                    }
                )
        completed = [item for item in items if item["status"] == "completed"]
        in_progress = [item for item in items if item["status"] == "in_progress"]
        pending = [item for item in items if item["status"] not in {"completed", "in_progress"}]
        current_phase = _optional_string(state.get("currentPhase"), "task.currentPhase", 160)
        current_step = _optional_string(state.get("currentStep"), "task.currentStep", 240)
        next_action = _optional_string(state.get("nextAction"), "task.nextAction", 240)
        if isinstance(contract, Mapping):
            current_phase = current_phase or _optional_string(contract.get("currentPhase"), "task.currentPhase", 160)
            current_step = current_step or _optional_string(contract.get("currentStep"), "task.currentStep", 240)
            next_action = next_action or _optional_string(contract.get("nextAction"), "task.nextAction", 240)
        return {
            "title": cls._task_ui_title(task_id, state, contract),
            "summary": cls._task_ui_summary(state, contract, plan_value if isinstance(plan_value, Mapping) else None, items),
            "statusLabel": TASK_UI_STATUS_LABELS.get(lifecycle, "待核对"),
            "phase": cls._task_ui_plan_label(current_phase) if current_phase else "尚未开始阶段",
            "currentStep": cls._task_ui_plan_label(current_step) if current_step else "等待下一步安排",
            "nextAction": cls._task_ui_plan_label(next_action) if next_action else "暂无下一步",
            "updatedAt": updated_at,
            "completedCount": len(completed),
            "inProgressCount": len(in_progress),
            "pendingCount": len(pending),
            "totalCount": len(items),
            "completedItems": completed,
            "inProgressItems": in_progress,
            "pendingItems": pending,
        }

    @staticmethod
    def _ui_execution_scope_from_contract(contract: Any) -> dict[str, Any] | None:
        try:
            if not isinstance(contract, Mapping) or contract.get("schema") != "super-brain.execution-contract.v1":
                return None
            return {
                "taskId": _require_string(contract.get("taskId"), "executionContract.taskId", 160),
                "taskInstanceId": _optional_string(contract.get("taskInstanceId"), "executionContract.taskInstanceId", 80),
                "workspaceKey": _require_string(contract.get("workspaceKey"), "executionContract.workspaceKey", 120),
                "ownerSessionKey": _require_string(contract.get("ownerSessionKey"), "executionContract.ownerSessionKey", 120),
                "contract": dict(contract),
            }
        except BrainControlError:
            return None

    @staticmethod
    def _read_ui_execution_json(path: Path) -> Mapping[str, Any] | None:
        try:
            if not path.is_file() or path.stat().st_size > 256 * 1024:
                return None
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return None
        return value if isinstance(value, Mapping) else None

    def _current_execution_scope_for_ui_workspace(self) -> tuple[dict[str, Any] | None, dict[str, str]]:
        """Resolve a Control Center scope from its own workspace pointer only."""

        workspace_key = self.ui_workspace_key
        pointer_hash = hashlib.sha256(workspace_key.encode("utf-8")).hexdigest()[:16]
        pointer_path = self.workspace / "guard-state" / "current-task-context-pointers" / f"{workspace_key}--{pointer_hash}.json"
        pointer = self._read_ui_execution_json(pointer_path)
        try:
            if (
                pointer is None
                or pointer.get("schema") != "super-brain.current-task-context.v1"
                or pointer.get("status") != "active"
                or pointer.get("stale") is True
                or _require_string(pointer.get("workspaceKey"), "currentTaskContext.workspaceKey", 120).lower() != workspace_key
            ):
                raise ValueError("workspace pointer is unavailable")
            expires_at = _optional_string(pointer.get("expiresAt"), "currentTaskContext.expiresAt", 64)
            if expires_at:
                expiry = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
                if expiry.tzinfo is None or expiry <= datetime.now(UTC):
                    raise ValueError("workspace pointer is stale")
            task_id = _require_string(pointer.get("taskId"), "currentTaskContext.taskId", 160)
            task_instance_id = _optional_string(pointer.get("taskInstanceId"), "currentTaskContext.taskInstanceId", 80)
            owner_session_key = _require_string(pointer.get("ownerSessionKey"), "currentTaskContext.ownerSessionKey", 120)
        except (BrainControlError, TypeError, ValueError):
            return None, {"status": "withheld", "reason": "workspace_scoped_current_task_unavailable"}

        contract_root = self.workspace / "runtime-state" / "execution-contracts"
        matches: list[dict[str, Any]] = []
        try:
            candidates = sorted(contract_root.glob(f"*--{workspace_key}.json"))
        except OSError:
            candidates = []
        if len(candidates) > 64:
            return None, {"status": "withheld", "reason": "workspace_scoped_contract_ambiguous"}
        for contract_path in candidates:
            scope = self._ui_execution_scope_from_contract(self._read_ui_execution_json(contract_path))
            if scope is None:
                continue
            if (
                scope["taskId"] != task_id
                or scope["workspaceKey"].lower() != workspace_key
                or scope["ownerSessionKey"] != owner_session_key
                or (task_instance_id and scope["taskInstanceId"] != task_instance_id)
            ):
                continue
            matches.append(scope)
        if len(matches) != 1:
            return None, {"status": "withheld", "reason": "workspace_scoped_contract_unavailable"}
        return matches[0], {"status": "bound", "source": "workspace_scoped_current_task_context"}

    def _current_execution_scope_for_ui(self) -> tuple[dict[str, Any] | None, dict[str, str]]:
        """Bind the runtime view to one current contract, or withhold it."""

        if self.ui_workspace_key:
            return self._current_execution_scope_for_ui_workspace()
        contract = self._read_ui_execution_json(self.workspace / "last-execution-contract.json")
        scope = self._ui_execution_scope_from_contract(contract)
        if scope is None:
            return None, {"status": "withheld", "reason": "current_execution_contract_unavailable"}
        return scope, {"status": "bound", "source": "last_execution_contract"}

    def current_card_source_context_for_ui(self) -> dict[str, str] | None:
        """Return a server-derived source binding for a newly created memory card."""

        current_scope, _ = self._current_execution_scope_for_ui()
        if current_scope is None:
            return None
        contract = current_scope["contract"]
        assert isinstance(contract, Mapping)
        conversation_title = ""
        for field in ("conversationTitle", "sessionName", "sessionTitle"):
            candidate = contract.get(field)
            if not isinstance(candidate, str):
                continue
            candidate = candidate.strip()
            if candidate and len(candidate) <= 160 and not SENSITIVE_VALUE_RE.search(candidate):
                conversation_title = candidate
                break
        return {
            "schema": TIMELINE_SOURCE_CONTEXT_SCHEMA,
            "taskId": str(current_scope["taskId"]),
            "taskInstanceId": str(current_scope["taskInstanceId"]),
            "workspaceKey": str(current_scope["workspaceKey"]),
            "ownerSessionKey": str(current_scope["ownerSessionKey"]),
            "conversationTitle": conversation_title,
        }

    def control_center_overview(self) -> dict[str, Any]:
        """Return a bounded operational read model without exposing paths or foreign task state."""

        current_scope, task_scope = self._current_execution_scope_for_ui()
        task_rows: list[sqlite3.Row] = []
        current_task_aggregate_id = ""
        with self._connection() as connection:
            kind_rows = connection.execute(
                "SELECT kind,COUNT(*) AS count FROM cards GROUP BY kind ORDER BY kind"
            ).fetchall()
            lifecycle_rows = connection.execute(
                "SELECT lifecycle,COUNT(*) AS count FROM cards GROUP BY lifecycle ORDER BY lifecycle"
            ).fetchall()
            if current_scope is not None:
                task_query = """
                    SELECT a.aggregate_id,a.task_id,a.task_instance_id,a.lifecycle,a.head_revision,r.state_json,a.updated_at
                    FROM task_aggregates a
                    JOIN task_state_revisions r ON r.aggregate_id=a.aggregate_id AND r.task_revision=a.head_revision
                    WHERE a.task_id=? AND a.workspace_key=? AND a.owner_session_key=?
                """
                task_parameters: list[str] = [
                    str(current_scope["taskId"]),
                    str(current_scope["workspaceKey"]),
                    str(current_scope["ownerSessionKey"]),
                ]
                if current_scope["taskInstanceId"]:
                    task_query += " AND a.task_instance_id=?"
                    task_parameters.append(str(current_scope["taskInstanceId"]))
                task_query += " ORDER BY a.updated_at DESC,a.task_id ASC LIMIT 1"
                task_rows = connection.execute(task_query, tuple(task_parameters)).fetchall()
                if task_rows:
                    current_task_aggregate_id = str(task_rows[0]["aggregate_id"])
            if current_task_aggregate_id:
                event_rows = connection.execute(
                    """
                    SELECT e.event_id,e.command_type,e.aggregate_id,e.revision,e.result_code,e.reason_code,e.created_at
                    FROM events e
                    WHERE NOT EXISTS (SELECT 1 FROM task_aggregates a WHERE a.aggregate_id=e.aggregate_id)
                       OR e.aggregate_id=?
                    ORDER BY e.sequence DESC LIMIT 30
                    """,
                    (current_task_aggregate_id,),
                ).fetchall()
                pending_outbox = int(
                    connection.execute(
                        """
                        SELECT COUNT(*) FROM outbox
                        WHERE status='pending' AND (projection_kind<>'task_projection' OR aggregate_id=?)
                        """,
                        (current_task_aggregate_id,),
                    ).fetchone()[0]
                )
            else:
                event_rows = connection.execute(
                    """
                    SELECT e.event_id,e.command_type,e.aggregate_id,e.revision,e.result_code,e.reason_code,e.created_at
                    FROM events e
                    WHERE NOT EXISTS (SELECT 1 FROM task_aggregates a WHERE a.aggregate_id=e.aggregate_id)
                    ORDER BY e.sequence DESC LIMIT 30
                    """
                ).fetchall()
                pending_outbox = int(
                    connection.execute(
                        "SELECT COUNT(*) FROM outbox WHERE status='pending' AND projection_kind<>'task_projection'"
                    ).fetchone()[0]
                )
        tasks: list[dict[str, Any]] = []
        for row in task_rows:
            try:
                state = json.loads(str(row["state_json"]))
            except json.JSONDecodeError:
                state = {}
            if not isinstance(state, Mapping):
                state = {}
            task_contract = current_scope.get("contract") if current_scope is not None else None
            if not isinstance(task_contract, Mapping):
                task_contract = None
            tasks.append(
                {
                    "taskId": str(row["task_id"]),
                    "taskInstanceId": str(row["task_instance_id"]),
                    "lifecycle": str(row["lifecycle"]),
                    "revision": int(row["head_revision"]),
                    "currentPhase": _optional_string(state.get("currentPhase"), "task.currentPhase", 160),
                    "currentStep": _optional_string(state.get("currentStep"), "task.currentStep", 240),
                    "nextAction": _optional_string(state.get("nextAction"), "task.nextAction", 240),
                    "updatedAt": str(row["updated_at"]),
                    "display": self._task_ui_display(
                        str(row["task_id"]),
                        str(row["lifecycle"]),
                        state,
                        str(row["updated_at"]),
                        task_contract,
                    ),
                }
            )
        if current_scope is not None and not tasks:
            contract = current_scope["contract"]
            assert isinstance(contract, Mapping)
            tasks.append(
                {
                    "taskId": str(current_scope["taskId"]),
                    "taskInstanceId": str(current_scope["taskInstanceId"]),
                    "lifecycle": _optional_string(contract.get("status"), "task.lifecycle", 32),
                    "revision": int(contract.get("revision", 0)) if isinstance(contract.get("revision", 0), int) else 0,
                    "currentPhase": _optional_string(contract.get("currentPhase"), "task.currentPhase", 160),
                    "currentStep": _optional_string(contract.get("currentStep"), "task.currentStep", 240),
                    "nextAction": _optional_string(contract.get("nextAction"), "task.nextAction", 240),
                    "updatedAt": _optional_string(contract.get("updatedAt"), "task.updatedAt", 64),
                    "source": "current_execution_contract",
                    "display": self._task_ui_display(
                        str(current_scope["taskId"]),
                        _optional_string(contract.get("status"), "task.lifecycle", 32),
                        contract,
                        _optional_string(contract.get("updatedAt"), "task.updatedAt", 64),
                        contract,
                    ),
                }
            )
        task_history = self.task_history_for_ui(scope=current_scope)
        return {
            "ok": True,
            "schema": "super-brain.control-center-overview.v1",
            "taskScope": task_scope,
            "cardsByKind": {str(row["kind"]): int(row["count"]) for row in kind_rows},
            "cardsByLifecycle": {str(row["lifecycle"]): int(row["count"]) for row in lifecycle_rows},
            "pendingOutbox": pending_outbox,
            "tasks": tasks,
            "taskHistory": task_history,
            "recentEvents": [
                {
                    "eventId": str(row["event_id"]),
                    "commandType": str(row["command_type"]),
                    "aggregateId": str(row["aggregate_id"]),
                    "revision": int(row["revision"]),
                    "result": str(row["result_code"]),
                    "reasonCode": str(row["reason_code"]),
                    "createdAt": str(row["created_at"]),
                }
                for row in event_rows
            ],
        }

    def _source_task_titles_for_ui(
        self,
        connection: sqlite3.Connection,
        rows: Sequence[sqlite3.Row],
    ) -> dict[tuple[str, str, str, str], str]:
        """Resolve source task titles without putting source identifiers in a UI projection."""

        task_titles: dict[tuple[str, str, str, str], str] = {}
        for row in rows:
            task_id = str(row["source_task_id"] or "")
            workspace_key = str(row["source_workspace_key"] or "")
            owner_session_key = str(row["source_owner_session_key"] or "")
            task_instance_id = str(row["source_task_instance_id"] or "")
            source_key = (task_id, task_instance_id, workspace_key, owner_session_key)
            if not task_id or not workspace_key or not owner_session_key or source_key in task_titles:
                continue
            task_query = """
                SELECT a.task_id,a.lifecycle,r.state_json
                FROM task_aggregates a
                JOIN task_state_revisions r ON r.aggregate_id=a.aggregate_id AND r.task_revision=a.head_revision
                WHERE a.task_id=? AND a.workspace_key=? AND a.owner_session_key=?
            """
            task_params: list[str] = [task_id, workspace_key, owner_session_key]
            if task_instance_id:
                task_query += " AND a.task_instance_id=?"
                task_params.append(task_instance_id)
            task_query += " ORDER BY a.updated_at DESC,a.task_id ASC LIMIT 1"
            task_row = connection.execute(task_query, tuple(task_params)).fetchone()
            if task_row is None:
                task_titles[source_key] = ""
                continue
            try:
                task_state = json.loads(str(task_row["state_json"]))
            except json.JSONDecodeError:
                task_state = {}
            if not isinstance(task_state, Mapping):
                task_titles[source_key] = ""
                continue
            title = self._task_ui_title(str(task_row["task_id"]), task_state, None)
            task_titles[source_key] = "" if title in {"当前任务", "未命名任务"} else title
        return task_titles

    @staticmethod
    def _profile_ui_text(value: Any, maximum: int) -> str:
        if not isinstance(value, str):
            return ""
        return re.sub(r"\s+", " ", value).strip()[:maximum]

    def profile_for_ui(self) -> dict[str, Any]:
        """Project confirmed collaboration preferences without exposing runtime internals."""

        sql = """
            SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
              r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
              r.state_json,r.created_at
            FROM cards c
            JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
            WHERE c.kind='preference' AND c.lifecycle IN ('active','proposed')
            ORDER BY c.updated_at DESC,c.card_id ASC
            LIMIT 48
        """
        with self._connection() as connection:
            rows = connection.execute(sql).fetchall()

        long_term: list[dict[str, Any]] = []
        current_project: list[dict[str, Any]] = []
        for row in rows:
            card = self._card_from_row(row)
            payload = card.get("payload")
            if not isinstance(payload, Mapping):
                continue
            statement = self._profile_ui_text(payload.get("statement"), 520)
            if not statement:
                continue
            conditions = [
                normalized
                for raw in payload.get("conditions", []) if isinstance(payload.get("conditions"), list)
                if (normalized := self._profile_ui_text(raw, 180))
            ][:6]
            item = {
                "cardRef": self._ui_card_reference(str(card["cardId"])),
                "title": self._profile_ui_text(card.get("title"), 160) or "未命名偏好",
                "statement": statement,
                "conditions": conditions,
                "confidence": int(payload.get("confidence", 0)) if isinstance(payload.get("confidence"), int) else 0,
            }
            scope = card.get("scope")
            if isinstance(scope, Mapping) and scope.get("kind") == "global":
                long_term.append(item)
            else:
                current_project.append(item)

        total = len(long_term) + len(current_project)
        return {
            "ok": True,
            "schema": "super-brain.ui-profile.v1",
            "total": total,
            "summary": (
                f"已确认 {total} 条协作偏好。它们会在相关任务中作为可验证的工作方式被引用。"
                if total else
                "还没有已确认的协作偏好。你可以从日常协作方式开始记录，之后再随时修改。"
            ),
            "longTerm": long_term,
            "currentProject": current_project,
        }

    def list_memory_timeline_for_ui(self, *, limit: int = 100, offset: int = 0) -> dict[str, Any]:
        """Project all user memory cards with opaque references, never internal identifiers."""

        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 1 or limit > 200:
            raise BrainControlError("BRAIN_CONTROL_UI_PAGE_INVALID", "limit must be between 1 and 200")
        if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0 or offset > 10_000:
            raise BrainControlError("BRAIN_CONTROL_UI_PAGE_INVALID", "offset must be between 0 and 10000")
        sql = """
            SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
              r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
              r.state_json,r.created_at,c.created_at AS card_created_at,
              s.task_id AS source_task_id,s.task_instance_id AS source_task_instance_id,
              s.workspace_key AS source_workspace_key,s.owner_session_key AS source_owner_session_key,
              s.conversation_title AS source_conversation_title
            FROM cards c
            JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
            LEFT JOIN card_source_links s ON s.card_id=c.card_id
            WHERE c.lifecycle NOT IN ('trashed','forgotten')
            ORDER BY c.created_at DESC,c.card_id ASC
            LIMIT ? OFFSET ?
        """
        with self._connection() as connection:
            rows = connection.execute(sql, (limit + 1, offset)).fetchall()
            task_titles = self._source_task_titles_for_ui(connection, rows[:limit])

        items: list[dict[str, Any]] = []
        for row in rows[:limit]:
            card = self._card_from_row(row)
            forgotten = str(card["lifecycle"]) == "forgotten"
            created_at = str(row["card_created_at"])
            item: dict[str, Any] = {
                "cardRef": self._ui_card_reference(str(card["cardId"])),
                "date": created_at[:10] if re.fullmatch(r"\d{4}-\d{2}-\d{2}.*", created_at) else "",
                "kind": str(card["kind"]),
                "kindLabel": CARD_UI_KIND_LABELS.get(str(card["kind"]), "记忆"),
                "title": "已忘记的记忆" if forgotten else str(card["title"]),
                "summary": "这条记忆的正文已被忘记" if forgotten else self._ui_card_summary(card),
            }
            if not forgotten:
                source_key = (
                    str(row["source_task_id"] or ""),
                    str(row["source_task_instance_id"] or ""),
                    str(row["source_workspace_key"] or ""),
                    str(row["source_owner_session_key"] or ""),
                )
                source: dict[str, str] = {}
                task_title = task_titles.get(source_key, "")
                if task_title:
                    source["taskTitle"] = task_title
                conversation_title = str(row["source_conversation_title"] or "").strip()
                if conversation_title:
                    source["conversationTitle"] = conversation_title
                if source:
                    item["source"] = source
            items.append(item)
        return {
            "ok": True,
            "schema": TASK_TIMELINE_SCHEMA,
            "items": items,
            "nextOffset": offset + len(items) if len(rows) > limit else None,
        }

    @staticmethod
    def _starmap_node_key(kind: str, value: Any) -> str:
        return f"{kind}-{_sha256({'kind': kind, 'value': value})[:24]}"

    @staticmethod
    def _starmap_tags(payload: Mapping[str, Any]) -> list[str]:
        raw_tags = payload.get("tags")
        if not isinstance(raw_tags, list):
            return []
        tags: list[str] = []
        for raw_tag in raw_tags[:12]:
            if not isinstance(raw_tag, str):
                continue
            tag = re.sub(r"\s+", " ", raw_tag).strip()[:64]
            if not tag or SENSITIVE_VALUE_RE.search(tag) or tag in tags:
                continue
            tags.append(tag)
        return tags

    @staticmethod
    def _starmap_migration_epoch(evidence_refs: Any) -> str:
        """Return one verified migration epoch without exposing it to the UI."""

        if not isinstance(evidence_refs, list):
            return ""
        epochs: set[str] = set()
        for raw_reference in evidence_refs:
            if not isinstance(raw_reference, str):
                continue
            match = re.fullmatch(r"migration:([a-z0-9][a-z0-9-]{7,95}):[a-f0-9]{64}", raw_reference)
            if match is not None:
                epochs.add(match.group(1))
        return next(iter(epochs)) if len(epochs) == 1 else ""

    @staticmethod
    def _starmap_legacy_candidate_projection(
        connection: sqlite3.Connection,
    ) -> tuple[dict[str, dict[str, Any]], dict[str, Any] | None]:
        """Read the verified migration index as a bounded, read-only UI seam.

        Legacy history is intentionally not re-imported here.  The canonical
        cards remain the only editable memory authority; this helper only adds
        enough provenance to distinguish grouped history candidates from real
        memories and to draw one human-readable source node.
        """

        try:
            epoch = connection.execute(
                """
                SELECT epoch_id,updated_at
                FROM migration_epochs
                WHERE status='verified'
                ORDER BY updated_at DESC,epoch_id ASC
                LIMIT 1
                """
            ).fetchone()
        except sqlite3.OperationalError:
            return {}, None
        if epoch is None:
            return {}, None
        epoch_id = str(epoch["epoch_id"] or "")
        if not epoch_id:
            return {}, None

        try:
            imported = connection.execute(
                """
                SELECT record_key,title,reason,source_locator,target_card_id
                FROM migration_records
                WHERE epoch_id=? AND status='imported' AND target_card_id<>''
                ORDER BY title ASC,record_key ASC
                """,
                (epoch_id,),
            ).fetchall()
            raw_count_row = connection.execute(
                """
                SELECT COUNT(*) AS count
                FROM migration_records
                WHERE epoch_id=? AND status IN ('ignored','quarantined')
                """,
                (epoch_id,),
            ).fetchone()
        except sqlite3.OperationalError:
            return {}, None

        candidate_rows: list[tuple[sqlite3.Row, str]] = []
        for row in imported:
            locator = str(row["source_locator"] or "")
            match = re.fullmatch(r"#candidate=([a-z0-9][a-z0-9_-]{0,63})", locator)
            if match is None:
                continue
            candidate_rows.append((row, match.group(1)))
        if not candidate_rows:
            return {}, None

        candidate_counts: dict[str, int] = {}
        for _, group in candidate_rows:
            try:
                count_row = connection.execute(
                    """
                    SELECT COUNT(*) AS count
                    FROM migration_records
                    WHERE epoch_id=? AND status='ignored' AND reason=?
                    """,
                    (epoch_id, f"aggregated_into_candidate:{group}"),
                ).fetchone()
                candidate_counts[group] = int(count_row["count"] if count_row is not None else 0)
            except sqlite3.OperationalError:
                candidate_counts[group] = 0

        metadata: dict[str, dict[str, Any]] = {}
        for row, group in candidate_rows:
            card_id = str(row["target_card_id"] or "")
            if not card_id:
                continue
            metadata[card_id] = {
                "candidateGroup": group,
                "candidateStatus": "待审核",
                "candidateSource": "旧 Sandglass 历史",
                "candidateSourceCount": candidate_counts.get(group, 0),
                "candidateReason": "历史内容只做候选，不自动采用",
                "candidateRecordKey": str(row["record_key"] or ""),
            }

        source_node = {
            "epochId": epoch_id,
            "updatedAt": str(epoch["updated_at"] or ""),
            "sourceRecordCount": int(raw_count_row["count"] if raw_count_row is not None else 0),
            "candidateGroupCount": len(metadata),
        }
        return metadata, source_node

    @staticmethod
    def _starmap_weight(
        kind: str,
        lifecycle: str,
        payload: Mapping[str, Any],
        *,
        is_current: bool,
    ) -> float:
        base = {
            "decision": 0.88,
            "preference": 0.80,
            "experience": 0.69,
            "procedure": 0.65,
            "note": 0.52,
            "reflection": 0.45,
        }.get(kind, 0.45)
        if kind == "note" and payload.get("pinned") is True:
            base += 0.13
        if kind == "preference" and isinstance(payload.get("evidenceUses"), int):
            base += min(int(payload["evidenceUses"]), 20) / 160
        if kind in {"preference", "reflection"} and isinstance(payload.get("confidence"), int):
            base += max(0, min(int(payload["confidence"]), 100) - 50) / 500
        if kind == "experience" and payload.get("validationState") in {"validated", "adopted", "resolved"}:
            base += 0.08
        if kind == "reflection" and payload.get("candidateState") in {"validated", "staged", "adopted", "resolved"}:
            base += 0.05
        if lifecycle in {"archived", "trashed", "forgotten", "cancelled", "rejected"}:
            base -= 0.24
        if is_current:
            base += 0.14
        return round(max(0.22, min(base, 1.0)), 3)

    def list_memory_starmap_for_ui(self) -> dict[str, Any]:
        """Build a bounded, read-only 3D graph from only explicit local memory relationships."""

        scan_limit = MEMORY_STARMAP_MAX_MEMORY_NODES * 2
        sql = """
            SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
              r.revision,r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,
              r.state_json,r.created_at,c.created_at AS card_created_at,
              s.task_id AS source_task_id,s.task_instance_id AS source_task_instance_id,
              s.workspace_key AS source_workspace_key,s.owner_session_key AS source_owner_session_key,
              s.conversation_title AS source_conversation_title
            FROM cards c
            JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
            LEFT JOIN card_source_links s ON s.card_id=c.card_id
            WHERE c.lifecycle IN ('active','proposed')
            ORDER BY c.updated_at DESC,c.card_id ASC
            LIMIT ?
        """
        current_scope, _ = self._current_execution_scope_for_ui()
        current_source_key: tuple[str, str, str, str] | None = None
        current_task_node: dict[str, Any] | None = None
        legacy_candidate_meta: dict[str, dict[str, Any]] = {}
        legacy_source_meta: dict[str, Any] | None = None
        with self._connection() as connection:
            rows = connection.execute(sql, (scan_limit,)).fetchall()
            legacy_candidate_meta, legacy_source_meta = self._starmap_legacy_candidate_projection(connection)
            kind_counts = {
                str(row["kind"]): int(row["count"])
                for row in connection.execute(
                    "SELECT kind,COUNT(*) AS count FROM cards WHERE lifecycle IN ('active','proposed') GROUP BY kind"
                ).fetchall()
            }
            lifecycle_counts = {
                str(row["lifecycle"]): int(row["count"])
                for row in connection.execute(
                    "SELECT lifecycle,COUNT(*) AS count FROM cards GROUP BY lifecycle"
                ).fetchall()
            }
            task_titles = self._source_task_titles_for_ui(connection, rows)
            if current_scope is not None:
                task_query = """
                    SELECT a.task_id,a.task_instance_id,a.workspace_key,a.owner_session_key,a.lifecycle,a.updated_at,r.state_json
                    FROM task_aggregates a
                    JOIN task_state_revisions r ON r.aggregate_id=a.aggregate_id AND r.task_revision=a.head_revision
                    WHERE a.task_id=? AND a.workspace_key=? AND a.owner_session_key=?
                """
                task_parameters: list[str] = [
                    str(current_scope["taskId"]),
                    str(current_scope["workspaceKey"]),
                    str(current_scope["ownerSessionKey"]),
                ]
                if current_scope["taskInstanceId"]:
                    task_query += " AND a.task_instance_id=?"
                    task_parameters.append(str(current_scope["taskInstanceId"]))
                task_query += " ORDER BY a.updated_at DESC,a.task_id ASC LIMIT 1"
                current_row = connection.execute(task_query, tuple(task_parameters)).fetchone()
                if current_row is not None:
                    try:
                        state = json.loads(str(current_row["state_json"]))
                    except json.JSONDecodeError:
                        state = {}
                    if isinstance(state, Mapping):
                        current_source_key = (
                            str(current_row["task_id"]),
                            str(current_row["task_instance_id"]),
                            str(current_row["workspace_key"]),
                            str(current_row["owner_session_key"]),
                        )
                        contract = current_scope.get("contract")
                        current_task_node = {
                            "nodeKey": self._starmap_node_key("task", current_source_key),
                            "kind": "task",
                            "kindLabel": "当前任务",
                            "title": self._task_ui_title(str(current_row["task_id"]), state, contract if isinstance(contract, Mapping) else None),
                            "summary": self._task_ui_summary(state, contract if isinstance(contract, Mapping) else None, state.get("canonicalPlan") if isinstance(state.get("canonicalPlan"), Mapping) else None, []),
                            "stateLabel": TASK_UI_STATUS_LABELS.get(str(current_row["lifecycle"]), "进行中"),
                            "date": str(current_row["updated_at"]),
                            "weight": 1.0,
                            "isCurrent": True,
                            "isPinned": True,
                            "isCluster": False,
                            "tags": [],
                            "source": {},
                            "_sourceKey": current_source_key,
                        }
                else:
                    contract = current_scope.get("contract")
                    if isinstance(contract, Mapping):
                        current_source_key = (
                            str(current_scope["taskId"]),
                            str(current_scope["taskInstanceId"]),
                            str(current_scope["workspaceKey"]),
                            str(current_scope["ownerSessionKey"]),
                        )
                        lifecycle = str(contract.get("status") or "active")
                        current_task_node = {
                            "nodeKey": self._starmap_node_key("task", current_source_key),
                            "kind": "task",
                            "kindLabel": "当前任务",
                            "title": self._task_ui_title(str(current_scope["taskId"]), contract, contract),
                            "summary": self._task_ui_summary(
                                contract,
                                contract,
                                contract.get("canonicalPlan") if isinstance(contract.get("canonicalPlan"), Mapping) else None,
                                [],
                            ),
                            "stateLabel": TASK_UI_STATUS_LABELS.get(lifecycle, "进行中"),
                            "date": str(contract.get("updatedAt") or ""),
                            "weight": 1.0,
                            "isCurrent": True,
                            "isPinned": True,
                            "isCluster": False,
                            "tags": [],
                            "source": {},
                            "_sourceKey": current_source_key,
                        }

        memory_candidates: list[dict[str, Any]] = []
        for row in rows:
            card = self._card_from_row(row)
            card_id = str(card["cardId"])
            kind = str(card["kind"])
            lifecycle = str(card["lifecycle"])
            forgotten = lifecycle == "forgotten"
            payload = card.get("payload")
            if not isinstance(payload, Mapping):
                payload = {}
            source_key = (
                str(row["source_task_id"] or ""),
                str(row["source_task_instance_id"] or ""),
                str(row["source_workspace_key"] or ""),
                str(row["source_owner_session_key"] or ""),
            )
            has_source = bool(source_key[0] and source_key[2] and source_key[3])
            source: dict[str, str] = {}
            task_title = task_titles.get(source_key, "") if has_source else ""
            if task_title:
                source["taskTitle"] = task_title
            conversation_title = str(row["source_conversation_title"] or "").strip()
            if conversation_title and not SENSITIVE_VALUE_RE.search(conversation_title):
                source["conversationTitle"] = conversation_title[:160]
            is_current = current_source_key is not None and source_key == current_source_key
            is_pinned = bool(payload.get("pinned") is True)
            candidate_meta = legacy_candidate_meta.get(card_id, {})
            is_candidate = bool(candidate_meta)
            node = {
                "nodeKey": self._starmap_node_key("memory", card_id),
                "kind": kind,
                "kindLabel": "历史候选" if is_candidate else CARD_UI_KIND_LABELS.get(kind, "记忆"),
                "title": "已忘记的记忆" if forgotten else str(card["title"]),
                "summary": "这条记忆的正文已被忘记" if forgotten else self._ui_card_summary(card),
                "stateLabel": candidate_meta.get("candidateStatus") if is_candidate else CARD_UI_LIFECYCLE_LABELS.get(lifecycle, "记忆"),
                "date": str(row["card_created_at"]),
                "weight": self._starmap_weight(kind, lifecycle, payload, is_current=is_current),
                "isCurrent": is_current,
                "isPinned": is_pinned,
                "isCluster": False,
                "isCandidate": is_candidate,
                "candidateGroup": candidate_meta.get("candidateGroup", "") if is_candidate else "",
                "candidateSource": candidate_meta.get("candidateSource", "") if is_candidate else "",
                "candidateSourceCount": int(candidate_meta.get("candidateSourceCount", 0)) if is_candidate else 0,
                "candidateReason": candidate_meta.get("candidateReason", "") if is_candidate else "",
                "tags": [] if forgotten else self._starmap_tags(payload),
                "source": source,
                "_cardId": card_id,
                "_sourceKey": source_key if has_source else None,
                "_authority": str(card["authority"]),
                "_lifecycle": lifecycle,
                "_isCandidate": is_candidate,
                "_candidateGroup": candidate_meta.get("candidateGroup", "") if is_candidate else "",
                "_links": list(payload.get("links", [])) if kind == "note" and isinstance(payload.get("links"), list) else [],
                "_migrationEpoch": self._starmap_migration_epoch(card.get("evidenceRefs")),
            }
            memory_candidates.append(node)

        kind_rank = {"decision": 0, "preference": 1, "experience": 2, "procedure": 3, "note": 4, "reflection": 5}
        memory_candidates.sort(
            key=lambda item: (
                not bool(item["isCurrent"]),
                not bool(item["isPinned"]),
                -float(item["weight"]),
                kind_rank.get(str(item["kind"]), 99),
                str(item["title"]),
            )
        )
        # Keep the bounded history candidates visible even when a workspace has
        # many ordinary cards.  They remain proposed/read-only; reserving a
        # small part of the projection prevents them from disappearing behind
        # newer active notes.
        candidate_nodes = [node for node in memory_candidates if node.get("_isCandidate")]
        regular_nodes = [node for node in memory_candidates if not node.get("_isCandidate")]
        candidate_nodes = candidate_nodes[:MEMORY_STARMAP_MAX_MEMORY_NODES]
        regular_limit = max(0, MEMORY_STARMAP_MAX_MEMORY_NODES - len(candidate_nodes))
        memory_nodes = regular_nodes[:regular_limit] + candidate_nodes
        shown_by_kind: dict[str, int] = {}
        for node in memory_nodes:
            shown_by_kind[str(node["kind"])] = shown_by_kind.get(str(node["kind"]), 0) + 1

        task_nodes: list[dict[str, Any]] = []
        task_nodes_by_source: dict[tuple[str, str, str, str], str] = {}
        history_source_node_key = ""
        if current_task_node is not None:
            current_key = current_task_node["_sourceKey"]
            assert isinstance(current_key, tuple)
            task_nodes.append(current_task_node)
            task_nodes_by_source[current_key] = str(current_task_node["nodeKey"])
        for memory in memory_nodes:
            source_key = memory["_sourceKey"]
            if not isinstance(source_key, tuple) or source_key in task_nodes_by_source:
                continue
            title = task_titles.get(source_key, "")
            if len(task_nodes) >= MEMORY_STARMAP_MAX_TASK_NODES:
                continue
            node_key = self._starmap_node_key("task", source_key)
            task_nodes_by_source[source_key] = node_key
            is_archived_source = not bool(title)
            task_nodes.append(
                {
                    "nodeKey": node_key,
                    "kind": "task",
                    "kindLabel": "已归档任务" if is_archived_source else "关联任务",
                    "title": "已归档任务" if is_archived_source else title,
                    "summary": "该记忆保留可验证来源，但关联任务详情已归档。" if is_archived_source else "由已验证来源关联的任务。",
                    "stateLabel": "已归档" if is_archived_source else "关联任务",
                    "date": "",
                    "weight": 0.72,
                    "isCurrent": False,
                    "isPinned": False,
                    "isCluster": False,
                    "tags": [],
                    "source": {},
                    "_sourceKey": source_key,
                }
            )
        if legacy_source_meta is not None and any(node.get("_isCandidate") for node in memory_nodes):
            history_source_node_key = self._starmap_node_key("history-source", legacy_source_meta.get("epochId", ""))
            task_nodes.append(
                {
                    "nodeKey": history_source_node_key,
                    "kind": "task",
                    "taskRole": "history_source",
                    "kindLabel": "历史来源",
                    "title": f"旧 Sandglass 历史（{int(legacy_source_meta.get('sourceRecordCount', 0))} 条）",
                    "summary": f"已整理为 {int(legacy_source_meta.get('candidateGroupCount', 0))} 个候选群；这里只读展示，不会自动注入。",
                    "stateLabel": "只读来源",
                    "date": str(legacy_source_meta.get("updatedAt", "")),
                    "weight": 0.66,
                    "isCurrent": False,
                    "isPinned": False,
                    "isCluster": True,
                    "isHistorySource": True,
                    "tags": ["历史候选", "只读"],
                    "source": {},
                    "_sourceKey": None,
                }
            )

        edges: list[dict[str, Any]] = []
        edge_keys: set[tuple[str, str]] = set()

        def add_edge(source: str, target: str, relation: str, strength: float) -> None:
            if source == target or len(edges) >= MEMORY_STARMAP_MAX_EDGES:
                return
            key = tuple(sorted((source, target)))
            if key in edge_keys:
                return
            edge_keys.add(key)
            edges.append({"source": source, "target": target, "relation": relation, "strength": strength})

        memory_key_by_card_id = {str(node["_cardId"]): str(node["nodeKey"]) for node in memory_nodes}
        nodes_by_tag: dict[str, list[str]] = {}
        nodes_by_migration_epoch: dict[str, list[str]] = {}
        for memory in memory_nodes:
            node_key = str(memory["nodeKey"])
            source_key = memory["_sourceKey"]
            if history_source_node_key and memory.get("_isCandidate"):
                add_edge(history_source_node_key, node_key, "history_source", 0.74)
            if isinstance(source_key, tuple) and source_key in task_nodes_by_source:
                add_edge(task_nodes_by_source[source_key], node_key, "source", 0.95)
            if str(memory["_authority"]) == "user_confirmed":
                for tag in memory["tags"]:
                    nodes_by_tag.setdefault(str(tag).casefold(), []).append(node_key)
            if (
                str(memory["_authority"]) == "legacy"
                and str(memory["_lifecycle"]) == "proposed"
                and not memory.get("_isCandidate")
            ):
                epoch = str(memory["_migrationEpoch"])
                if epoch:
                    nodes_by_migration_epoch.setdefault(epoch, []).append(node_key)
            for raw_link in memory["_links"]:
                if not isinstance(raw_link, str):
                    continue
                prefix, separator, target_card_id = raw_link.partition(":")
                if separator and prefix.casefold() in {"card", "memory"} and target_card_id in memory_key_by_card_id:
                    add_edge(node_key, memory_key_by_card_id[target_card_id], "explicit", 0.84)
        for linked_nodes in nodes_by_tag.values():
            unique_nodes = sorted(set(linked_nodes))
            for source, target in zip(unique_nodes, unique_nodes[1:]):
                add_edge(source, target, "shared_tag", 0.46)
        for linked_nodes in nodes_by_migration_epoch.values():
            unique_nodes = sorted(set(linked_nodes))
            for source, target in zip(unique_nodes, unique_nodes[1:]):
                add_edge(source, target, "migration_source", 0.58)

        cluster_nodes: list[dict[str, Any]] = []
        for kind, count in sorted(kind_counts.items(), key=lambda item: kind_rank.get(item[0], 99)):
            hidden_count = max(0, count - shown_by_kind.get(kind, 0))
            if hidden_count < 1:
                continue
            cluster_nodes.append(
                {
                    "nodeKey": self._starmap_node_key("cluster", {"kind": kind, "count": hidden_count}),
                    "kind": "cluster",
                    "clusterKind": kind,
                    "representedCount": hidden_count,
                    "kindLabel": "记忆群",
                    "title": f"还有 {hidden_count} 条{CARD_UI_KIND_LABELS.get(kind, '记忆')}",
                    "summary": "为保持星图清晰，这些记忆暂未逐颗展开。",
                    "stateLabel": "已聚合",
                    "date": "",
                    "weight": min(0.82, 0.42 + hidden_count / 500),
                    "isCurrent": False,
                    "isPinned": False,
                    "isCluster": True,
                    "tags": [],
                    "source": {},
                    "_kind": kind,
                }
            )

        all_nodes = task_nodes + memory_nodes + cluster_nodes
        for cluster in cluster_nodes:
            same_kind = next((node for node in memory_nodes if node["kind"] == cluster["_kind"]), None)
            if same_kind is not None:
                add_edge(str(cluster["nodeKey"]), str(same_kind["nodeKey"]), "cluster", 0.28)

        public_nodes = []
        for node in all_nodes:
            public_nodes.append({key: value for key, value in node.items() if not key.startswith("_")})
        candidate_count = sum(1 for node in memory_nodes if node.get("_isCandidate"))
        history_source_records = int(legacy_source_meta.get("sourceRecordCount", 0)) if legacy_source_meta else 0
        history_candidate_groups = int(legacy_source_meta.get("candidateGroupCount", 0)) if legacy_source_meta else 0
        body = {
            "ok": True,
            "schema": MEMORY_STARMAP_SCHEMA,
            "nodes": public_nodes,
            "edges": edges,
            "counts": {
                "totalMemory": sum(kind_counts.values()),
                "shownMemory": len(memory_nodes),
                "hiddenMemory": max(0, sum(kind_counts.values()) - len(memory_nodes)),
                "individualMemory": len(memory_nodes),
                "groupedMemory": max(0, sum(kind_counts.values()) - len(memory_nodes)),
                "candidateMemory": candidate_count,
                "shownCandidates": candidate_count,
                "historySourceRecords": history_source_records,
                "historyCandidateGroups": history_candidate_groups,
                "projectionLimit": MEMORY_STARMAP_MAX_MEMORY_NODES,
                "eligibleByKind": kind_counts,
                "individualByKind": shown_by_kind,
                "excludedMemory": sum(
                    count for lifecycle, count in lifecycle_counts.items() if lifecycle not in {"active", "proposed"}
                ),
                "excludedByLifecycle": {
                    lifecycle: count
                    for lifecycle, count in sorted(lifecycle_counts.items())
                    if lifecycle not in {"active", "proposed"}
                },
                "tasks": len(task_nodes),
                "relationships": len(edges),
            },
            "relationshipPolicyLabel": "仅显示已验证记忆关联；历史候选仅展示来源关系",
            "historyCandidatePolicyLabel": "历史候选只读、待审核，不会自动注入",
            "currentTaskPresent": current_task_node is not None,
        }
        if len(_canonical_json(body).encode("utf-8")) > 256 * 1024:
            raise BrainControlError("BRAIN_CONTROL_UI_STARMAP_TOO_LARGE", "starmap projection exceeded its bounded payload")
        return body

    @staticmethod
    def _normalize_ui_draft(card_id: Any, base_revision: Any, draft: Any) -> tuple[str, int, dict[str, Any]]:
        normalized_card_id = _require_string(card_id, "cardId", 160)
        if isinstance(base_revision, bool) or not isinstance(base_revision, int) or base_revision < 0:
            raise BrainControlError("BRAIN_CONTROL_UI_DRAFT_INVALID", "baseRevision must be a non-negative integer")
        if not isinstance(draft, Mapping):
            raise BrainControlError("BRAIN_CONTROL_UI_DRAFT_INVALID", "draft must be an object")
        normalized_draft = dict(draft)
        _ensure_safe(normalized_draft, "uiDraft")
        if len(_canonical_json(normalized_draft)) > 32_768:
            raise BrainControlError("BRAIN_CONTROL_UI_DRAFT_TOO_LARGE", "draft exceeds the 32 KiB bounded control payload")
        return normalized_card_id, base_revision, normalized_draft

    @staticmethod
    def _delete_expired_ui_drafts(connection: sqlite3.Connection) -> None:
        connection.execute("DELETE FROM ui_drafts WHERE expires_at<=?", (_utc_now(),))

    def save_ui_draft(self, card_id: Any, base_revision: Any, draft: Any) -> dict[str, Any]:
        normalized_card_id, normalized_revision, normalized_draft = self._normalize_ui_draft(card_id, base_revision, draft)
        now = _utc_now()
        expires_at = (datetime.now(UTC) + timedelta(days=7)).isoformat().replace("+00:00", "Z")
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                self._delete_expired_ui_drafts(connection)
                card = connection.execute("SELECT head_revision FROM cards WHERE card_id=?", (normalized_card_id,)).fetchone()
                if card is None and normalized_revision != 0:
                    raise BrainControlError("BRAIN_CONTROL_CARD_NOT_FOUND", "draft base card no longer exists")
                if card is not None and int(card["head_revision"]) != normalized_revision:
                    raise BrainControlError("BRAIN_CONTROL_STALE_REVISION", "draft base revision is stale")
                payload_hash = _sha256({"cardId": normalized_card_id, "baseRevision": normalized_revision, "draft": normalized_draft})
                connection.execute(
                    """
                    INSERT INTO ui_drafts(card_id,base_revision,draft_json,draft_hash,updated_at,expires_at)
                    VALUES (?,?,?,?,?,?)
                    ON CONFLICT(card_id) DO UPDATE SET
                      base_revision=excluded.base_revision,
                      draft_json=excluded.draft_json,
                      draft_hash=excluded.draft_hash,
                      updated_at=excluded.updated_at,
                      expires_at=excluded.expires_at
                    """,
                    (normalized_card_id, normalized_revision, _canonical_json(normalized_draft), payload_hash, now, expires_at),
                )
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return {
            "ok": True,
            "schema": "super-brain.ui-draft-receipt.v1",
            "cardId": normalized_card_id,
            "baseRevision": normalized_revision,
            "draftHash": payload_hash,
            "updatedAt": now,
            "expiresAt": expires_at,
        }

    def get_ui_draft(self, card_id: Any, current_revision: Any) -> dict[str, Any]:
        normalized_card_id = _require_string(card_id, "cardId", 160)
        if isinstance(current_revision, bool) or not isinstance(current_revision, int) or current_revision < 0:
            raise BrainControlError("BRAIN_CONTROL_UI_DRAFT_INVALID", "currentRevision must be a non-negative integer")
        with self._connection() as connection:
            # A browser draft read happens alongside timeline and star-map reads.
            # Do not acquire a write lock just to prune expired drafts; save/discard
            # paths perform that bounded cleanup before their own writes.
            row = connection.execute(
                "SELECT base_revision,draft_json,draft_hash,updated_at,expires_at FROM ui_drafts WHERE card_id=? AND expires_at>?",
                (normalized_card_id, _utc_now()),
            ).fetchone()
        if row is None:
            return {"ok": True, "schema": "super-brain.ui-draft-read.v1", "available": False, "stale": False}
        base_revision = int(row["base_revision"])
        if base_revision != current_revision:
            return {
                "ok": True,
                "schema": "super-brain.ui-draft-read.v1",
                "available": False,
                "stale": True,
                "baseRevision": base_revision,
            }
        try:
            draft = json.loads(str(row["draft_json"]))
        except json.JSONDecodeError as exc:
            raise BrainControlError("BRAIN_CONTROL_UI_DRAFT_CORRUPT", "stored UI draft is invalid") from exc
        if not isinstance(draft, Mapping):
            raise BrainControlError("BRAIN_CONTROL_UI_DRAFT_CORRUPT", "stored UI draft is invalid")
        return {
            "ok": True,
            "schema": "super-brain.ui-draft-read.v1",
            "available": True,
            "stale": False,
            "baseRevision": base_revision,
            "draft": dict(draft),
            "draftHash": str(row["draft_hash"]),
            "updatedAt": str(row["updated_at"]),
            "expiresAt": str(row["expires_at"]),
        }

    def discard_ui_draft(self, card_id: Any) -> dict[str, Any]:
        normalized_card_id = _require_string(card_id, "cardId", 160)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                self._delete_expired_ui_drafts(connection)
                removed = int(connection.execute("DELETE FROM ui_drafts WHERE card_id=?", (normalized_card_id,)).rowcount)
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return {"ok": True, "schema": "super-brain.ui-draft-discard.v1", "cardId": normalized_card_id, "removed": bool(removed)}

    def _purge_surface_summary(self, card_id: str) -> list[dict[str, Any]]:
        def contains_card_id(path: Path) -> bool | None:
            try:
                if not path.is_file():
                    return False
                if path.stat().st_size > 4 * 1024 * 1024:
                    return None
                return card_id.encode("utf-8") in path.read_bytes()
            except OSError:
                return None

        projection_paths = (self.mcp_snapshot_path, self.card_projection_path)
        projection_matches = sum(1 for path in projection_paths if contains_card_id(path) is True)
        archive_roots = (self.state_root / "backups", self.workspace / "backups", self.state_root / "archive", self.workspace / "archive")
        archive_files = 0
        for root in archive_roots:
            if not root.is_dir():
                continue
            for _ in root.rglob("*"):
                archive_files += 1
                if archive_files >= 10_000:
                    break
        return [
            {"surface": "canonical_database", "present": self.db_path.exists(), "scope": "current card authority"},
            {"surface": "sqlite_wal", "present": self.db_path.with_name(self.db_path.name + "-wal").exists(), "scope": "recent SQLite pages"},
            {"surface": "sqlite_shm", "present": self.db_path.with_name(self.db_path.name + "-shm").exists(), "scope": "SQLite shared-memory metadata"},
            {"surface": "read_projections", "matchingArtifacts": projection_matches, "scope": "MCP and compatibility projections"},
            {"surface": "backups_and_archives", "candidateArtifacts": archive_files, "scope": "retention-governed historical copies"},
        ]

    def preview_purge_everywhere(self, card_id: str, expected_revision: int, actor_receipt: Mapping[str, Any]) -> dict[str, Any]:
        normalized_card_id = _require_string(card_id, "cardId", 160)
        receipt = _normalize_actor_receipt(actor_receipt)
        if receipt["authorization"] not in {"user_confirmed", "test"}:
            raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", "purge preview requires a user-confirmed receipt")
        if isinstance(expected_revision, bool) or not isinstance(expected_revision, int) or expected_revision < 1:
            raise BrainControlError("BRAIN_CONTROL_EXPECTED_REVISION_INVALID", "expectedRevision must be positive")
        with self._connection() as connection:
            head = connection.execute("SELECT head_revision,lifecycle FROM cards WHERE card_id=?", (normalized_card_id,)).fetchone()
            if head is None:
                raise BrainControlError("BRAIN_CONTROL_CARD_NOT_FOUND", "purge preview requires an existing card")
            if int(head["head_revision"]) != expected_revision:
                raise BrainControlError("BRAIN_CONTROL_STALE_REVISION", "purge preview revision is stale")
            if str(head["lifecycle"]) != "forgotten":
                raise BrainControlError("BRAIN_CONTROL_PURGE_FORGET_REQUIRED", "ForgetActive must complete before PurgeEverywhere can be previewed")
            tombstone = connection.execute(
                "SELECT forgotten_revision FROM card_privacy_tombstones WHERE card_id=?", (normalized_card_id,)
            ).fetchone()
            if tombstone is None or int(tombstone["forgotten_revision"]) != expected_revision:
                raise BrainControlError("BRAIN_CONTROL_PURGE_TOMBSTONE_REQUIRED", "the current forgotten tombstone is missing")
            preview_id = "purge-preview-" + uuid.uuid4().hex
            confirmation_phrase = f"PURGE {normalized_card_id}"
            preview = {
                "schema": "super-brain.purge-preview.v1",
                "previewId": preview_id,
                "cardId": normalized_card_id,
                "revision": expected_revision,
                "surfaces": self._purge_surface_summary(normalized_card_id),
                "physicalSecureErasureClaim": False,
                "nextEffect": "A confirmed request is retained for P5 retention governance; the active body is already unavailable after ForgetActive.",
            }
            now = _utc_now()
            expires_at = (datetime.now(UTC) + timedelta(minutes=10)).isoformat().replace("+00:00", "Z")
            confirmation_hash = _sha256({"previewId": preview_id, "phrase": confirmation_phrase})
            connection.execute("BEGIN IMMEDIATE")
            try:
                connection.execute(
                    """
                    INSERT INTO ui_purge_previews(preview_id,card_id,expected_revision,confirmation_hash,preview_json,status,created_at,expires_at)
                    VALUES (?,?,?,?,?,?,?,?)
                    """,
                    (preview_id, normalized_card_id, expected_revision, confirmation_hash, _canonical_json(preview), "previewed", now, expires_at),
                )
                connection.execute(
                    "UPDATE card_privacy_tombstones SET purge_state='previewed',purge_preview_id=? WHERE card_id=?",
                    (preview_id, normalized_card_id),
                )
                connection.execute("COMMIT")
            except Exception:
                connection.execute("ROLLBACK")
                raise
        return {**preview, "confirmationPhrase": confirmation_phrase, "expiresAt": expires_at}

    def request_purge_everywhere(
        self,
        preview_id: str,
        confirmation_phrase: str,
        actor_receipt: Mapping[str, Any],
    ) -> dict[str, Any]:
        normalized_preview_id = _require_string(preview_id, "previewId", 160)
        receipt = _normalize_actor_receipt(actor_receipt)
        if receipt["authorization"] not in {"user_confirmed", "test"}:
            raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", "purge confirmation requires a user-confirmed receipt")
        phrase = _card_text(confirmation_phrase, "confirmationPhrase", 240)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                existing = connection.execute(
                    "SELECT result_json FROM ui_purge_requests WHERE preview_id=?", (normalized_preview_id,)
                ).fetchone()
                if existing is not None:
                    result = json.loads(str(existing["result_json"]))
                    connection.execute("COMMIT")
                    return {**result, "idempotent": True}
                preview_row = connection.execute(
                    "SELECT card_id,expected_revision,confirmation_hash,status,expires_at FROM ui_purge_previews WHERE preview_id=?",
                    (normalized_preview_id,),
                ).fetchone()
                if preview_row is None:
                    raise BrainControlError("BRAIN_CONTROL_PURGE_PREVIEW_NOT_FOUND", "purge preview was not found")
                if str(preview_row["status"]) != "previewed" or str(preview_row["expires_at"]) <= _utc_now():
                    connection.execute("UPDATE ui_purge_previews SET status='expired' WHERE preview_id=?", (normalized_preview_id,))
                    raise BrainControlError("BRAIN_CONTROL_PURGE_PREVIEW_EXPIRED", "purge preview has expired; create a fresh preview")
                expected_hash = _sha256({"previewId": normalized_preview_id, "phrase": phrase})
                if expected_hash != str(preview_row["confirmation_hash"]):
                    raise BrainControlError("BRAIN_CONTROL_PURGE_CONFIRMATION_INVALID", "purge confirmation phrase does not match the preview")
                card_id = str(preview_row["card_id"])
                revision = int(preview_row["expected_revision"])
                head = connection.execute("SELECT head_revision,lifecycle FROM cards WHERE card_id=?", (card_id,)).fetchone()
                if head is None or int(head["head_revision"]) != revision or str(head["lifecycle"]) != "forgotten":
                    raise BrainControlError("BRAIN_CONTROL_PURGE_STATE_STALE", "the forgotten card changed; create a fresh preview")
                request_id = "purge-request-" + uuid.uuid4().hex
                result = {
                    "ok": True,
                    "schema": "super-brain.purge-request-receipt.v1",
                    "requestId": request_id,
                    "previewId": normalized_preview_id,
                    "cardId": card_id,
                    "revision": revision,
                    "status": "requested_for_p5_retention_governance",
                    "physicalSecureErasureClaim": False,
                    "activeBodyState": "forgotten",
                }
                now = _utc_now()
                connection.execute(
                    """
                    INSERT INTO ui_purge_requests(request_id,preview_id,card_id,revision,actor_receipt,result_json,created_at)
                    VALUES (?,?,?,?,?,?,?)
                    """,
                    (request_id, normalized_preview_id, card_id, revision, _canonical_json(receipt), _canonical_json(result), now),
                )
                connection.execute("UPDATE ui_purge_previews SET status='requested',requested_at=? WHERE preview_id=?", (now, normalized_preview_id))
                connection.execute(
                    "UPDATE card_privacy_tombstones SET purge_state='requested',purge_preview_id=? WHERE card_id=?",
                    (normalized_preview_id, card_id),
                )
                connection.execute("COMMIT")
                return {**result, "idempotent": False}
            except Exception:
                connection.execute("ROLLBACK")
                raise

    def pending_outbox(self) -> list[dict[str, Any]]:
        with self._connection() as connection:
            rows = connection.execute(
                "SELECT event_id,aggregate_id,revision,projection_kind,payload_json,delivery_version,created_at FROM outbox WHERE status='pending' ORDER BY created_at,event_id"
            ).fetchall()
        return [
            {
                "eventId": str(row["event_id"]),
                "aggregateId": str(row["aggregate_id"]),
                "revision": int(row["revision"]),
                "projectionKind": str(row["projection_kind"]),
                "deliveryVersion": int(row["delivery_version"]),
                "deliveryTargets": list(self._delivery_targets(str(row["projection_kind"]), int(row["delivery_version"]))),
                "payload": json.loads(str(row["payload_json"])),
                "createdAt": str(row["created_at"]),
            }
            for row in rows
        ]

    def acknowledge_legacy_task_outbox(self, event_ids: Sequence[str]) -> int:
        """Compatibility bridge for pre-v6 task outbox events only."""

        ids = [event_id for event_id in event_ids if isinstance(event_id, str) and event_id]
        if not ids:
            return 0
        placeholders = ",".join("?" for _ in ids)
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                cursor = connection.execute(
                    f"UPDATE outbox SET status='materialized', materialized_at=? WHERE status='pending' AND delivery_version=0 AND projection_kind='task_projection' AND event_id IN ({placeholders})",
                    [_utc_now(), *ids],
                )
                connection.execute("COMMIT")
                return int(cursor.rowcount)
            except Exception:
                connection.execute("ROLLBACK")
                raise

    def preview_decision_graph_shadow(self, source_graph: str | Path) -> dict[str, Any]:
        graph_hash, projections = self._load_decision_graph_projections(source_graph)
        return {
            "ok": True,
            "schema": "super-brain.decision-graph-shadow-preview.v1",
            "sourceGraphHash": graph_hash,
            "sourceSubjectCount": len(projections),
            "currentSubjectCount": sum(1 for projection in projections if projection["isCurrent"]),
            "executionEligibleCount": sum(1 for projection in projections if projection["executionEligible"]),
            "rawDecisionBodyStored": False,
            "rawPromptStored": False,
        }

    def sync_decision_graph_shadow(self, source_graph: str | Path) -> dict[str, Any]:
        graph_hash, projections = self._load_decision_graph_projections(source_graph)
        source_ids = {str(projection["aggregateId"]) for projection in projections}
        existing = self._get_decision_graph_cards()
        extra = sorted(set(existing) - source_ids)
        if extra:
            raise BrainControlError(
                "BRAIN_CONTROL_SHADOW_EXTRA_CARD",
                "shadow contains graph-decision cards that are not present in the source graph",
            )

        commands: list[dict[str, Any]] = []
        unchanged = 0
        for projection in projections:
            aggregate_id = str(projection["aggregateId"])
            base = self._validate_command(self._decision_graph_command(projection, 0))
            current = existing.get(aggregate_id)
            if current is None:
                commands.append(base)
                continue

            if not self._is_consistent_decision_graph_card(current):
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_EXISTING_CARD_INVALID",
                    "existing graph-decision shadow card is structurally invalid",
                )
            expected_content_hash = _sha256(self._command_content(base))
            current_digest = current["payload"]["sourceProjectionDigest"]
            if current_digest == projection["sourceProjectionDigest"]:
                if (
                    current["contentHash"] != expected_content_hash
                    or _sha256(self._card_content(current)) != expected_content_hash
                ):
                    raise BrainControlError(
                        "BRAIN_CONTROL_SHADOW_EXISTING_CARD_MISMATCH",
                        "existing graph-decision shadow card does not match its source projection",
                    )
                unchanged += 1
                continue

            commands.append(self._validate_command(self._decision_graph_command(projection, int(current["revision"]))))

        receipts: list[dict[str, Any]] = []
        if commands:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                try:
                    for command in commands:
                        receipts.append(self._apply_in_transaction(connection, command, _sha256(command)))
                    connection.execute("COMMIT")
                except Exception:
                    connection.execute("ROLLBACK")
                    raise

        audit = self.audit_decision_graph_shadow(source_graph)
        return {
            "ok": bool(audit["ok"]),
            "schema": "super-brain.decision-graph-shadow-sync.v1",
            "atomic": True,
            "sourceGraphHash": graph_hash,
            "sourceSubjectCount": len(projections),
            "writtenCount": len(receipts),
            "unchangedCount": unchanged,
            "idempotentCount": sum(1 for receipt in receipts if receipt["idempotent"]),
            "audit": audit,
            "rawDecisionBodyStored": False,
            "rawPromptStored": False,
        }

    def audit_decision_graph_shadow(self, source_graph: str | Path) -> dict[str, Any]:
        graph_hash, projections = self._load_decision_graph_projections(source_graph)
        existing = self._get_decision_graph_cards()
        expected_ids = {str(projection["aggregateId"]) for projection in projections}
        missing: list[str] = []
        mismatched: list[str] = []
        matched = 0

        for projection in projections:
            aggregate_id = str(projection["aggregateId"])
            current = existing.get(aggregate_id)
            if current is None:
                missing.append(str(projection["subjectHash"]))
                continue
            expected = self._validate_command(self._decision_graph_command(projection, 0))
            expected_content_hash = _sha256(self._command_content(expected))
            if (
                not self._is_consistent_decision_graph_card(current)
                or current["contentHash"] != expected_content_hash
                or _sha256(self._card_content(current)) != expected_content_hash
                or current["payload"].get("sourceProjectionDigest") != projection["sourceProjectionDigest"]
            ):
                mismatched.append(str(projection["subjectHash"]))
                continue
            matched += 1

        extra = sorted(set(existing) - expected_ids)
        return {
            "ok": not missing and not mismatched and not extra,
            "schema": "super-brain.decision-graph-shadow-audit.v1",
            "sourceGraphHash": graph_hash,
            "sourceSubjectCount": len(projections),
            "shadowSubjectCount": len(existing),
            "matchedCount": matched,
            "missingSubjectHashes": sorted(missing),
            "mismatchedSubjectHashes": sorted(mismatched),
            "extraCardIds": extra,
            "rawDecisionBodyStored": False,
            "rawPromptStored": False,
        }

    def _load_decision_graph_projections(self, source_graph: str | Path) -> tuple[str, list[dict[str, Any]]]:
        graph_path = Path(source_graph).expanduser().resolve()
        try:
            raw_graph = graph_path.read_bytes()
        except OSError as exc:
            raise BrainControlError("BRAIN_CONTROL_SHADOW_GRAPH_MISSING", "cannot read source graph") from exc
        try:
            lines = raw_graph.decode("utf-8-sig").splitlines()
        except UnicodeDecodeError as exc:
            raise BrainControlError("BRAIN_CONTROL_SHADOW_GRAPH_INVALID", "source graph is not UTF-8") from exc

        by_subject: dict[str, dict[str, Any]] = {}
        for line_number, raw_line in enumerate(lines, start=1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                node = json.loads(line)
            except json.JSONDecodeError as exc:
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_GRAPH_INVALID",
                    f"source graph contains invalid JSON at line {line_number}",
                ) from exc
            if not isinstance(node, Mapping):
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_GRAPH_INVALID",
                    f"source graph contains a non-object at line {line_number}",
                )
            subject = node.get("subject")
            tags = node.get("tags", "")
            if not all(isinstance(value, str) for value in (subject, tags)):
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_GRAPH_INVALID",
                    f"source graph has an invalid subject or tag field at line {line_number}",
                )
            is_decision = "[DECISION]" in tags or "[ADR]" in tags or subject.startswith("decision:")
            if not is_decision:
                continue
            relation = node.get("relation")
            object_value = node.get("object")
            if not all(isinstance(value, str) for value in (relation, object_value)):
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_GRAPH_INVALID",
                    f"source graph has an invalid decision field at line {line_number}",
                )
            event_hash = _sha256(dict(node))
            state = by_subject.setdefault(
                subject,
                {
                    "subject": subject,
                    "events": [],
                    "decisions": [],
                    "isAdr": False,
                    "title": "",
                    "status": "",
                    "context": "",
                    "consequence": "",
                    "owner": "",
                    "scope": "",
                    "alternatives": [],
                    "supersedes": [],
                    "supersededBy": [],
                },
            )
            event = {
                "line": line_number,
                "eventHash": event_hash,
                "relation": relation,
                "tags": tags,
            }
            state["events"].append(event)
            if "[ADR]" in tags:
                state["isAdr"] = True
            if relation == "decides":
                state["decisions"].append({"line": line_number, "object": object_value, "tags": tags})
            elif relation == "has_title":
                state["title"] = object_value
                state["isAdr"] = True
            elif relation == "has_status":
                state["status"] = object_value
                state["isAdr"] = True
            elif relation == "has_context":
                state["context"] = object_value
                state["isAdr"] = True
            elif relation == "has_consequence":
                state["consequence"] = object_value
                state["isAdr"] = True
            elif relation == "has_owner":
                state["owner"] = object_value
                state["isAdr"] = True
            elif relation == "affects":
                state["scope"] = object_value
                state["isAdr"] = True
            elif relation == "has_alternative":
                state["alternatives"].append(object_value)
                state["isAdr"] = True
            elif relation == "supersedes":
                state["supersedes"].append(object_value)
            elif relation == "superseded_by":
                state["supersededBy"].append(object_value)

        for state in by_subject.values():
            for superseded_subject in state["supersedes"]:
                target = by_subject.get(superseded_subject)
                if target is None:
                    raise BrainControlError(
                        "BRAIN_CONTROL_SHADOW_SUPERSESSION_TARGET_MISSING",
                        "a decision supersession target is absent from the source graph",
                    )
                target["supersededBy"].append(str(state["subject"]))

        projections: list[dict[str, Any]] = []
        for subject, state in sorted(by_subject.items()):
            if not state["decisions"]:
                relation_names = {str(event["relation"]) for event in state["events"]}
                if relation_names.issubset({"superseded_by"}):
                    # Graph writers keep inverse supersession links for some legacy
                    # subjects that have no decision body to project.
                    continue
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_DECISION_MISSING",
                    "a decision subject has no decides event",
                )
            if not all("[VERIFIED]" in str(event["tags"]) for event in state["decisions"]):
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_DECISION_UNVERIFIED",
                    "a decision subject contains an unverified decides event",
                )
            current_decisions = [
                event
                for event in state["decisions"]
                if "[CURRENT]" in str(event["tags"]) and "[STALE]" not in str(event["tags"])
            ]
            if len(current_decisions) > 1:
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_DECISION_CONFLICT",
                    "a decision subject has multiple current decides events",
                )
            non_stale_decisions = [
                event for event in state["decisions"] if "[STALE]" not in str(event["tags"])
            ]
            effective_decision = (
                current_decisions[-1]
                if current_decisions
                else (non_stale_decisions[-1] if non_stale_decisions else state["decisions"][-1])
            )
            decision_tags = str(effective_decision["tags"])
            status = str(state["status"])
            if state["isAdr"]:
                relation_names = {str(event["relation"]) for event in state["events"]}
                if not DECISION_GRAPH_ADR_RELATIONS.issubset(relation_names):
                    raise BrainControlError(
                        "BRAIN_CONTROL_SHADOW_ADR_SCHEMA_INVALID",
                        "an ADR decision is missing required graph relations",
                    )
                if status not in DECISION_GRAPH_VALID_ADR_STATUSES:
                    raise BrainControlError(
                        "BRAIN_CONTROL_SHADOW_ADR_STATUS_INVALID",
                        "an ADR decision has an invalid status",
                    )

            superseded = bool(state["supersededBy"])
            stale = "[STALE]" in decision_tags
            current_tagged = "[CURRENT]" in decision_tags
            is_current = (
                not superseded
                and not stale
                and (current_tagged or status in DECISION_GRAPH_CURRENT_ADR_STATUSES)
            )
            if superseded or stale or status in {"deprecated", "superseded"}:
                lifecycle = "superseded"
            elif status == "rejected":
                lifecycle = "rejected"
            elif status == "proposed":
                lifecycle = "proposed"
            elif is_current:
                lifecycle = "active"
            else:
                lifecycle = "archived"

            event_chain = [{"line": event["line"], "eventHash": event["eventHash"]} for event in state["events"]]
            projection_material = {
                "subject": subject,
                "events": event_chain,
                "decision": str(effective_decision["object"]),
                "title": state["title"],
                "status": status,
                "context": state["context"],
                "consequence": state["consequence"],
                "owner": state["owner"],
                "scope": state["scope"],
                "alternatives": state["alternatives"],
                "supersedes": sorted(set(state["supersedes"])),
                "supersededBy": sorted(set(state["supersededBy"])),
                "isAdr": bool(state["isAdr"]),
                "lifecycle": lifecycle,
                "isCurrent": is_current,
            }
            projection_digest = _sha256(projection_material)
            subject_hash = _sha256({"subject": subject})
            projections.append(
                {
                    "aggregateId": DECISION_GRAPH_CARD_PREFIX + subject_hash,
                    "subjectHash": subject_hash,
                    "lifecycle": lifecycle,
                    "isCurrent": is_current,
                    "executionEligible": bool(state["isAdr"] and status == "accepted" and is_current),
                    "sourceEventCount": len(event_chain),
                    "sourceFirstLine": event_chain[0]["line"],
                    "sourceLastLine": event_chain[-1]["line"],
                    "sourceEventChainDigest": _sha256(event_chain),
                    "sourceProjectionDigest": projection_digest,
                    "adr": bool(state["isAdr"]),
                    "adrStatus": status,
                    "supersedesDigest": _sha256(sorted(set(state["supersedes"]))),
                    "supersededByDigest": _sha256(sorted(set(state["supersededBy"]))),
                }
            )
        return _sha256_bytes(raw_graph), projections

    def _decision_graph_command(self, projection: Mapping[str, Any], expected_revision: int) -> dict[str, Any]:
        projection_digest = _require_sha256(projection["sourceProjectionDigest"], "sourceProjectionDigest")
        subject_hash = _require_sha256(projection["subjectHash"], "subjectHash")
        payload = {
            "schema": DECISION_GRAPH_SCHEMA,
            "subjectHash": subject_hash,
            "sourceEventCount": int(projection["sourceEventCount"]),
            "sourceFirstLine": int(projection["sourceFirstLine"]),
            "sourceLastLine": int(projection["sourceLastLine"]),
            "sourceEventChainDigest": _require_sha256(projection["sourceEventChainDigest"], "sourceEventChainDigest"),
            "sourceProjectionDigest": projection_digest,
            "adr": bool(projection["adr"]),
            "adrStatus": str(projection["adrStatus"]),
            "isCurrent": bool(projection["isCurrent"]),
            "executionEligible": bool(projection["executionEligible"]),
            "supersedesDigest": _require_sha256(projection["supersedesDigest"], "supersedesDigest"),
            "supersededByDigest": _require_sha256(projection["supersededByDigest"], "supersededByDigest"),
            "rawDecisionBodyStored": False,
            "rawPromptStored": False,
        }
        command_identity = _sha256({"subjectHash": subject_hash, "projectionDigest": projection_digest})
        return {
            "commandType": "upsert_card",
            "commandId": "shadow-graph-" + command_identity,
            "aggregateId": str(projection["aggregateId"]),
            "expectedRevision": expected_revision,
            "kind": "decision",
            "scope": {"kind": DECISION_GRAPH_SCOPE, "key": subject_hash},
            "lifecycle": str(projection["lifecycle"]),
            "authority": "legacy",
            "privacyClass": "private",
            "title": "Decision graph projection",
            "payload": payload,
            "evidenceRefs": [f"graph.jsonl:L{payload['sourceFirstLine']}-L{payload['sourceLastLine']}"],
            "actorReceipt": {
                "schema": ACTOR_RECEIPT_SCHEMA,
                "actorKind": "legacy",
                "actorId": "decision_graph_shadow",
                "authorization": "legacy",
                "authorizationReceipt": projection_digest,
            },
            "reason": "synchronize sanitized decision-graph projection",
            "source": "decision_graph_shadow",
        }

    def _get_decision_graph_cards(self) -> dict[str, dict[str, Any]]:
        with self._connection() as connection:
            rows = connection.execute(
                """
                SELECT c.card_id,c.kind,c.scope_kind,c.scope_key,c.lifecycle,c.authority,c.privacy_class,c.head_revision,
                  r.predecessor_hash,r.content_hash,r.title,r.structured_payload,r.evidence_refs,r.actor_receipt,r.created_at
                FROM cards c JOIN card_revisions r ON r.card_id=c.card_id AND r.revision=c.head_revision
                WHERE c.scope_kind=? AND c.card_id LIKE ?
                """,
                (DECISION_GRAPH_SCOPE, DECISION_GRAPH_CARD_PREFIX + "%"),
            ).fetchall()
        cards: dict[str, dict[str, Any]] = {}
        for row in rows:
            card = {
                "cardId": str(row["card_id"]),
                "kind": str(row["kind"]),
                "scope": {"kind": str(row["scope_kind"]), "key": str(row["scope_key"])},
                "lifecycle": str(row["lifecycle"]),
                "authority": str(row["authority"]),
                "privacyClass": str(row["privacy_class"]),
                "revision": int(row["head_revision"]),
                "predecessorHash": str(row["predecessor_hash"]),
                "contentHash": str(row["content_hash"]),
                "title": str(row["title"]),
                "payload": json.loads(str(row["structured_payload"])),
                "evidenceRefs": json.loads(str(row["evidence_refs"])),
                "actorReceipt": json.loads(str(row["actor_receipt"])),
                "createdAt": str(row["created_at"]),
            }
            cards[card["cardId"]] = card
        return cards

    @staticmethod
    def _card_content(card: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "kind": card["kind"],
            "scope": card["scope"],
            "lifecycle": card["lifecycle"],
            "authority": card["authority"],
            "privacyClass": card["privacyClass"],
            "title": card["title"],
            "payload": card["payload"],
            "evidenceRefs": card["evidenceRefs"],
            "actorReceipt": card["actorReceipt"],
        }

    @classmethod
    def _is_consistent_decision_graph_card(cls, card: Mapping[str, Any]) -> bool:
        try:
            payload = card.get("payload")
            if not isinstance(payload, Mapping):
                return False
            if payload.get("schema") != DECISION_GRAPH_SCHEMA:
                return False
            if not isinstance(payload.get("sourceProjectionDigest"), str):
                return False
            _require_sha256(payload["sourceProjectionDigest"], "sourceProjectionDigest")
            if card.get("kind") != "decision":
                return False
            scope = card.get("scope")
            if not isinstance(scope, Mapping) or scope.get("kind") != DECISION_GRAPH_SCOPE:
                return False
            content_hash = card.get("contentHash")
            if not isinstance(content_hash, str):
                return False
            return _sha256(cls._card_content(card)) == content_hash
        except (BrainControlError, KeyError, TypeError):
            return False

    def _validate_command(self, command: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(command, Mapping):
            raise BrainControlError("BRAIN_CONTROL_COMMAND_INVALID", "command must be an object")
        _ensure_safe(command, "command")
        command_type = _require_string(command.get("commandType"), "commandType", 80)
        if command_type not in CARD_COMMAND_TYPES:
            raise BrainControlError("BRAIN_CONTROL_COMMAND_UNSUPPORTED", f"unsupported commandType: {command_type}")
        base_fields = {"commandType", "commandId", "aggregateId", "expectedRevision", "actorReceipt", "reason", "source"}
        content_fields = {"kind", "scope", "lifecycle", "authority", "privacyClass", "title", "payload", "evidenceRefs"}
        transition_fields = {
            "supersede_card": {"replacementRef", "impactAcknowledged"},
            "rollback_card": {"restoreRevision"},
            "trash_card": set(),
            "restore_card": set(),
            "cancel_card": {"impactAcknowledged"},
            "forget_active": {"forgetAcknowledged"},
            "forget_trashed": {"forgetAcknowledged"},
        }
        allowed_fields = base_fields | (content_fields if command_type in {"create_card", "edit_card", "upsert_card"} else transition_fields[command_type])
        if command_type == "create_card":
            allowed_fields = allowed_fields | {"sourceContext"}
        _card_exact_fields(command, allowed_fields, {"commandType", "commandId", "aggregateId", "expectedRevision", "actorReceipt", "reason"}, "command")
        command_id = _require_string(command.get("commandId"), "commandId", 160)
        aggregate_id = _require_string(command.get("aggregateId"), "aggregateId", 160)
        expected_revision = command.get("expectedRevision")
        if not isinstance(expected_revision, int) or expected_revision < 0:
            raise BrainControlError("BRAIN_CONTROL_EXPECTED_REVISION_INVALID", "expectedRevision must be a non-negative integer")
        actor_receipt = _normalize_actor_receipt(command.get("actorReceipt"))
        reason = _card_text(command.get("reason"), "reason", 480)
        source = _require_string(command.get("source", "brain_control"), "source", 160)
        normalized: dict[str, Any] = {
            "commandType": command_type,
            "commandId": command_id,
            "aggregateId": aggregate_id,
            "expectedRevision": expected_revision,
            "actorReceipt": actor_receipt,
            "reason": reason,
            "source": source,
        }
        if command_type == "supersede_card":
            normalized.update(
                {
                    "operation": "supersede",
                    "replacementRef": _card_text(command.get("replacementRef"), "replacementRef", 240),
                    "impactAcknowledged": _card_boolean(command.get("impactAcknowledged", False), "impactAcknowledged"),
                }
            )
        elif command_type == "rollback_card":
            restore_revision = command.get("restoreRevision")
            if isinstance(restore_revision, bool) or not isinstance(restore_revision, int) or restore_revision < 1:
                raise BrainControlError("BRAIN_CONTROL_CARD_ROLLBACK_TARGET_INVALID", "restoreRevision must be a positive integer")
            normalized.update({"operation": "rollback", "restoreRevision": restore_revision})
        elif command_type == "trash_card":
            normalized.update({"operation": "trash"})
        elif command_type == "restore_card":
            normalized.update({"operation": "restore"})
        elif command_type == "cancel_card":
            normalized.update(
                {
                    "operation": "cancel",
                    "impactAcknowledged": _card_boolean(command.get("impactAcknowledged", False), "impactAcknowledged"),
                }
            )
        elif command_type in {"forget_active", "forget_trashed"}:
            if not _card_boolean(command.get("forgetAcknowledged", False), "forgetAcknowledged"):
                raise BrainControlError(
                    "BRAIN_CONTROL_CARD_FORGET_ACKNOWLEDGEMENT_REQUIRED",
                    f"{command_type} requires an explicit acknowledgement",
                )
            normalized.update({"operation": "forget", "forgetFromTrash": command_type == "forget_trashed"})
        else:
            kind = _require_string(command.get("kind"), "kind", 64)
            if kind not in CARD_KINDS:
                raise BrainControlError("BRAIN_CONTROL_CARD_KIND_INVALID", f"unsupported card kind: {kind}")
            contract = CARD_CONTRACTS[kind]
            if command_type not in contract.allowed_commands:
                raise BrainControlError("BRAIN_CONTROL_CARD_COMMAND_INVALID", f"{command_type} is not allowed for {kind}")
            scope = command.get("scope")
            if not isinstance(scope, Mapping):
                raise BrainControlError("BRAIN_CONTROL_SCOPE_INVALID", "scope must be an object")
            _card_exact_fields(scope, {"kind", "key"}, {"kind", "key"}, "scope")
            scope_kind = _require_string(scope.get("kind"), "scope.kind", 64)
            scope_key = _require_string(scope.get("key"), "scope.key", 256)
            lifecycle = _require_string(command.get("lifecycle"), "lifecycle", 32)
            if lifecycle not in contract.allowed_lifecycles:
                raise BrainControlError("BRAIN_CONTROL_LIFECYCLE_INVALID", f"unsupported lifecycle for {kind}: {lifecycle}")
            if lifecycle in {"trashed", "forgotten"}:
                raise BrainControlError(
                    "BRAIN_CONTROL_CARD_LIFECYCLE_TRANSITION_INVALID",
                    "Trash and Forget require their dedicated governed commands",
                )
            if command_type == "create_card" and lifecycle not in {"proposed", "active"}:
                raise BrainControlError("BRAIN_CONTROL_CARD_LIFECYCLE_TRANSITION_INVALID", "create_card requires proposed or active lifecycle")
            if command_type == "create_card" and expected_revision != 0:
                raise BrainControlError("BRAIN_CONTROL_EXPECTED_REVISION_INVALID", "create_card requires expectedRevision 0")
            if command_type == "edit_card" and expected_revision < 1:
                raise BrainControlError("BRAIN_CONTROL_EXPECTED_REVISION_INVALID", "edit_card requires an existing revision")
            authority = _require_string(command.get("authority"), "authority", 32)
            if authority not in AUTHORITIES:
                raise BrainControlError("BRAIN_CONTROL_AUTHORITY_INVALID", f"unsupported authority: {authority}")
            if authority == "user_confirmed" and actor_receipt["authorization"] not in {"user_confirmed", "test"}:
                raise BrainControlError("BRAIN_CONTROL_ACTOR_RECEIPT_INVALID", "user-confirmed cards require a user-confirmed receipt")
            privacy_class = _require_string(command.get("privacyClass"), "privacyClass", 32)
            if privacy_class not in PRIVACY_CLASSES:
                raise BrainControlError("BRAIN_CONTROL_PRIVACY_INVALID", f"unsupported privacyClass: {privacy_class}")
            title = _require_string(command.get("title"), "title", 240)
            payload = _normalize_card_payload(kind, command.get("payload"))
            if kind == "reflection" and payload.get("candidateState") == "adopted":
                if command_type != "edit_card" or source != "loopback_control_center_reflection_adoption":
                    raise BrainControlError(
                        "BRAIN_CONTROL_REFLECTION_ADOPTION_REQUIRED",
                        "adopted reflections require the controlled adoption transaction",
                    )
            if kind == "decision" and payload.get("schema") == "super-brain.card.decision.v2" and payload.get("enforcement") == "completion_gate":
                if authority != "user_confirmed":
                    raise BrainControlError(
                        "BRAIN_CONTROL_DECISION_AUTHORITY_INVALID",
                        "completion-gate decisions require user_confirmed authority",
                    )
                if scope_kind != "workspace":
                    raise BrainControlError(
                        "BRAIN_CONTROL_DECISION_SCOPE_INVALID",
                        "completion-gate decisions require an exact workspace scope",
                    )
                if payload["applicability"]["mode"] == "legacy_unspecified":
                    raise BrainControlError(
                        "BRAIN_CONTROL_DECISION_APPLICABILITY_REQUIRED",
                        "completion-gate decisions require explicit applicability",
                    )
            evidence_refs = _card_list(command.get("evidenceRefs", []), "evidenceRefs", 32, 320)
            source_context = _normalize_timeline_source_context(command.get("sourceContext")) if command_type == "create_card" else None
            if command_type == "upsert_card":
                if not (kind == "decision" and scope_kind == DECISION_GRAPH_SCOPE and authority == "legacy"):
                    raise BrainControlError(
                        "BRAIN_CONTROL_LEGACY_COMMAND_RETIRED",
                        "upsert_card is reserved for the decision-graph compatibility projection",
                    )
                operation = "compatibility_upsert"
            else:
                operation = "create" if command_type == "create_card" else "edit"
            normalized.update(
                {
                    "operation": operation,
                    "kind": kind,
                    "scope": {"kind": scope_kind, "key": scope_key},
                    "lifecycle": lifecycle,
                    "authority": authority,
                    "privacyClass": privacy_class,
                    "title": title,
                    "payload": payload,
                    "evidenceRefs": evidence_refs,
                }
            )
            if source_context is not None:
                normalized["sourceContext"] = source_context
        if len(_canonical_json(normalized)) > 32768:
            raise BrainControlError("BRAIN_CONTROL_COMMAND_TOO_LARGE", "command exceeds the 32 KiB bounded control payload")
        return normalized


def _read_command(argument: str) -> dict[str, Any]:
    raw = (argument if argument else sys.stdin.buffer.read().decode("utf-8-sig")).lstrip("\ufeff")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BrainControlError("BRAIN_CONTROL_COMMAND_JSON_INVALID", str(exc)) from exc
    if not isinstance(value, dict):
        raise BrainControlError("BRAIN_CONTROL_COMMAND_INVALID", "command JSON must be an object")
    return value


def _read_encoded_command(encoded: str) -> dict[str, Any]:
    if not encoded:
        return _read_command("")
    try:
        raw = base64.b64decode(encoded, validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as exc:
        raise BrainControlError("BRAIN_CONTROL_COMMAND_BASE64_INVALID", str(exc)) from exc
    return _read_command(raw)


def main() -> int:
    parser = argparse.ArgumentParser(description="Super Brain local control-plane command engine")
    parser.add_argument("--state-root", required=True)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("status")
    sub.add_parser("publish-mcp-snapshot")
    sub.add_parser("publish-native-memory-influence-snapshot")
    materialize = sub.add_parser("materialize-outbox")
    materialize.add_argument("--max-events", type=int, default=64, choices=range(1, 129))
    sub.add_parser("publish-decision-index")
    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--command-json", default="")
    get_parser = sub.add_parser("get-card")
    get_parser.add_argument("--card-id", required=True)
    sub.add_parser("pending-outbox")
    acknowledge = sub.add_parser("acknowledge-legacy-task-outbox")
    acknowledge.add_argument("--event-id", action="append", default=[])
    task_delivery = sub.add_parser("record-task-delivery")
    task_delivery.add_argument("--request-json", default="")
    task_delivery.add_argument("--request-base64", default="")
    graph_preview = sub.add_parser("shadow-preview-decision-graph")
    graph_preview.add_argument("--source-graph", required=True)
    graph_sync = sub.add_parser("shadow-sync-decision-graph")
    graph_sync.add_argument("--source-graph", required=True)
    graph_sync.add_argument("--apply", action="store_true")
    graph_audit = sub.add_parser("shadow-audit-decision-graph")
    graph_audit.add_argument("--source-graph", required=True)
    resolve_intent = sub.add_parser("resolve-intent")
    resolve_intent.add_argument("--request-json", default="")
    resolve_intent.add_argument("--request-base64", default="")
    rebind_intent = sub.add_parser("rebind-intent")
    rebind_intent.add_argument("--request-json", default="")
    rebind_intent.add_argument("--request-base64", default="")
    rebind_task_session = sub.add_parser("rebind-task-session")
    rebind_task_session.add_argument("--request-json", default="")
    rebind_task_session.add_argument("--request-base64", default="")
    check_intent = sub.add_parser("check-intent")
    check_intent.add_argument("--request-json", default="")
    check_intent.add_argument("--request-base64", default="")
    for decision_action in ("resolve-decisions", "check-decision-resolution", "record-decision-result", "validate-decision-completion", "get-decision-context"):
        decision_parser = sub.add_parser(decision_action)
        decision_parser.add_argument("--request-json", default="")
        decision_parser.add_argument("--request-base64", default="")
    memory_influence = sub.add_parser("get-memory-influence")
    memory_influence.add_argument("--request-json", default="")
    memory_influence.add_argument("--request-base64", default="")
    native_memory_learning = sub.add_parser("record-native-memory-learning-candidate")
    native_memory_learning.add_argument("--request-json", default="")
    native_memory_learning.add_argument("--request-base64", default="")
    h7_memory_learning = sub.add_parser("record-h7-memory-learning-candidate")
    h7_memory_learning.add_argument("--request-json", default="")
    h7_memory_learning.add_argument("--request-base64", default="")
    prepare_intent = sub.add_parser("prepare-intent")
    prepare_intent.add_argument("--request-json", default="")
    prepare_intent.add_argument("--request-base64", default="")
    for control_action in (
        "observe-instruction-anchor",
        "get-instruction-anchor",
        "check-instruction-anchor",
        "record-continuation-receipt",
        "get-continuation-receipt",
    ):
        control_parser = sub.add_parser(control_action)
        control_parser.add_argument("--request-json", default="")
        control_parser.add_argument("--request-base64", default="")
    for task_action in ("prepare-task", "import-task", "apply-task", "get-task", "locate-task"):
        task_parser = sub.add_parser(task_action)
        task_parser.add_argument("--request-json", default="")
        task_parser.add_argument("--request-base64", default="")
    for migration_action in (
        "migration-plan",
        "migration-stage",
        "migration-import",
        "migration-verify",
        "migration-cutover",
        "migration-rollback-adapter",
        "migration-status",
        "migration-sandglass-plan",
        "migration-sandglass-stage",
        "migration-sandglass-import",
        "migration-sandglass-verify",
        "migration-sandglass-rollback",
        "migration-sandglass-status",
    ):
        migration_parser = sub.add_parser(migration_action)
        migration_parser.add_argument("--request-json", default="")
        migration_parser.add_argument("--request-base64", default="")
    sub.add_parser("pending-task-outbox")
    sub.add_parser("task-projection-snapshots")
    args = parser.parse_args()
    control = BrainControl(args.state_root)
    try:
        if args.action == "status":
            result = control.status()
        elif args.action == "publish-mcp-snapshot":
            result = control.publish_mcp_snapshot()
        elif args.action == "publish-native-memory-influence-snapshot":
            result = control.publish_native_memory_influence_snapshot()
        elif args.action == "materialize-outbox":
            result = control.materialize_outbox(args.max_events)
        elif args.action == "publish-decision-index":
            result = control.publish_native_decision_index()
        elif args.action == "apply":
            result = control.apply(_read_command(args.command_json))
        elif args.action == "get-card":
            result = {"ok": True, "card": control.get_card(args.card_id)}
        elif args.action == "pending-outbox":
            result = {"ok": True, "events": control.pending_outbox()}
        elif args.action == "acknowledge-legacy-task-outbox":
            result = {"ok": True, "materialized": control.acknowledge_legacy_task_outbox(args.event_id)}
        elif args.action == "record-task-delivery":
            result = control.record_task_compatibility_delivery(
                _read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json)
            )
        elif args.action == "shadow-preview-decision-graph":
            result = control.preview_decision_graph_shadow(args.source_graph)
        elif args.action == "shadow-sync-decision-graph":
            if not args.apply:
                raise BrainControlError(
                    "BRAIN_CONTROL_SHADOW_APPLY_REQUIRED",
                    "shadow sync requires --apply and never runs as an implicit default",
                )
            result = control.sync_decision_graph_shadow(args.source_graph)
        elif args.action == "resolve-intent":
            result = control.resolve_intent(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "rebind-intent":
            result = control.rebind_intent_session(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "rebind-task-session":
            result = control.issue_task_session_rebind(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "check-intent":
            result = control.check_intent(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "resolve-decisions":
            result = control.resolve_decisions(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "check-decision-resolution":
            result = control.check_decision_resolution(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "record-decision-result":
            result = control.record_decision_result(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "validate-decision-completion":
            result = control.validate_decision_completion(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "get-decision-context":
            result = control.get_decision_context(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "get-memory-influence":
            result = control.get_memory_influence(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "record-native-memory-learning-candidate":
            result = control.record_native_memory_learning_candidate(
                _read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json)
            )
        elif args.action == "record-h7-memory-learning-candidate":
            result = control.record_h7_memory_learning_candidate(
                _read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json)
            )
        elif args.action == "prepare-intent":
            result = control.prepare_intent(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "observe-instruction-anchor":
            result = control.observe_instruction_anchor(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "get-instruction-anchor":
            result = control.get_instruction_anchor(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "check-instruction-anchor":
            result = control.check_instruction_anchor(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "record-continuation-receipt":
            result = control.record_continuation_receipt(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "get-continuation-receipt":
            result = control.get_continuation_receipt(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "prepare-task":
            result = control.prepare_task(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "import-task":
            result = control.import_task(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "apply-task":
            result = control.apply_task(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "get-task":
            result = control.get_task(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "locate-task":
            result = control.locate_task(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-plan":
            result = control.migration_plan(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-stage":
            result = control.migration_stage(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-import":
            result = control.migration_import(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-verify":
            result = control.migration_verify(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-cutover":
            result = control.migration_cutover(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-rollback-adapter":
            result = control.migration_rollback_adapter(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-status":
            result = control.migration_status(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-sandglass-plan":
            result = control.sandglass_migration_plan(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-sandglass-stage":
            result = control.sandglass_migration_stage(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-sandglass-import":
            result = control.sandglass_migration_import(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-sandglass-verify":
            result = control.sandglass_migration_verify(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-sandglass-rollback":
            result = control.sandglass_migration_rollback(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "migration-sandglass-status":
            result = control.sandglass_migration_status(_read_encoded_command(args.request_base64) if args.request_base64 else _read_command(args.request_json))
        elif args.action == "pending-task-outbox":
            result = {"ok": True, "events": control.pending_task_outbox()}
        elif args.action == "task-projection-snapshots":
            result = {"ok": True, "snapshots": control.task_projection_snapshots()}
        else:
            result = control.audit_decision_graph_shadow(args.source_graph)
    except BrainControlError as exc:
        result = {"ok": False, "code": exc.code, "error": str(exc)}
    sys.stdout.buffer.write(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
