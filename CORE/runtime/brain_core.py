from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import re
import sqlite3
from collections import Counter, deque
from contextvars import ContextVar
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping

from brain_context import (
    canonical_hash as context_canonical_hash,
    read_intent_context_projection,
    select_native_memory_entries,
    validate_visible_progress_receipt,
    validate_project_progress_proof,
)
from activation_receipt import read_valid as read_activation_receipt
from continuation_policy import decide_turn_close
from core_rule_registry import load_registry, public_projection as project_core_rules
from mcp_transport_health import McpTransportHealth, inactive_status
from mcp_runtime_identity import runtime_dependency_paths, runtime_identity
from layout_paths import configured_state_root, state_root as resolve_state_root
from scope_provider import LegacyEnvironmentScopeProvider, ScopeProvider


TURN_RUNTIME_CONTEXT_SNAPSHOT_KEY = "_turnRuntimeSnapshot"
TURN_RUNTIME_CONTEXT_SNAPSHOT_SCHEMA = "super-brain.turn-runtime-context-snapshot.v1"

# A recall-local handoff lets the bounded full-scan path share its already
# parsed sandglass prefix with the recent-tail fallback. It is a ContextVar so
# concurrent BrainCore calls do not share mutable request state.
_RECALL_SANDGLASS_CACHE: ContextVar[dict[str, Any] | None] = ContextVar(
    "super_brain_recall_sandglass_cache", default=None
)
_CONTRACT_UNSET = object()
_RUNTIME_SOURCE_PROJECTION_MAX = 8


TAG_RE = re.compile(r"\[[A-Z_]+\]")
WORD_RE = re.compile(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]{1,}")
CJK_RE = re.compile(r"[\u4e00-\u9fff]+")

# Generic question words are useful to the backend searcher but weak evidence
# for deciding whether a returned session answers the user's fact query.
ENGLISH_STOP_TERMS = frozenset(
    "a an and are as at be been but by can could did do does doing for from had has have having how i if in is it many me my of on or our the their them these they this to was were what when where which who why with you your own get got getting tell say said user assistant answer please remember continue previous resume also already about any anything been being both every first give good help just kind last like more most much need needed next now often please recommend recommendations same should some tell than that then there thing things think this time type want way well would"
    .split()
)
CJK_STOP_TERMS = frozenset(
    "\u7684 \u4e86 \u662f \u6211 \u4f60 \u4ed6 \u5979 \u5b83 \u4eec \u4ec0\u4e48 \u600e\u4e48 \u5982\u4f55 \u591a\u5c11 \u54ea \u4e2a \u54ea\u4e9b \u4e3a\u4ec0\u4e48 \u662f\u5426 \u6709 \u6ca1\u6709 \u548c \u4e0e \u6216 \u8005 \u4f46 \u662f \u8bf7 \u5e2e \u6211 \u8bb0\u4f4f \u7ee7\u7eed \u4e0a\u6b21 \u4e4b\u524d \u8fd8\u8bb0\u5f97 \u8fd9\u4e2a \u90a3\u4e2a \u5f53\u524d \u4e0b\u4e00\u6b65".split()
)
NUMBER_WORDS = frozenset(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen twenty thirty forty fifty hundred thousand first second third fourth fifth last"
    .split()
)


WEAK_ENGLISH_TERMS = frozenset(
    "smart hit hits rule rules close closed closing closure boundary task tasks session sessions project projects memory memories history historical current currently".split()
)
WEAK_CJK_TERMS = frozenset(
    "\u89c4\u5219 \u5173\u95ed \u95ed\u89c4 \u95ee\u9898 \u4e8b\u60c5 \u529f\u80fd \u65b9\u6848 \u65b9\u6cd5 \u5185\u5bb9 \u90e8\u5206 \u5730\u65b9 \u60c5\u51b5 \u539f\u56e0 \u7ed3\u679c \u73b0\u5728 \u5df2\u7ecf \u53ef\u4ee5 \u9700\u8981 \u8fdb\u884c \u53d1\u751f \u76f8\u5173 \u600e\u4e48\u5199 \u600e\u4e48\u6837 \u4e48\u6837 \u4e00\u4e0b \u4efb\u52a1 \u4f1a\u8bdd \u9879\u76ee \u8bb0\u5fc6 \u5386\u53f2".split()
)
RECALL_EXCLUDED_TERMS = ENGLISH_STOP_TERMS | CJK_STOP_TERMS | WEAK_ENGLISH_TERMS | WEAK_CJK_TERMS
GENERIC_FACT_TERMS = frozenset(
    "answer answers archive code database decision deployment engine evidence interval language message name port preference release report reports residual risk runner size status target team time value window".split()
)

DEFAULT_RECALL_TOP_K = 3
DEFAULT_RECALL_MAX_TOKENS = 500
MAX_RECALL_TOP_K = 4
MAX_RECALL_TOKENS = 500
MAX_EVALUATION_RANK = 10
MAX_EVALUATION_TOKENS = 2000


def agent_identity() -> dict[str, object]:
    """The stable public identity of the Super Brain control plane."""

    return {
        "schema": "super-brain.agent-identity.v1",
        "kind": "independent_control_plane_agent",
        "authority": "h7_rules_contract_and_project_evidence",
        "hostAdapterRole": "entry_only",
        "collaborationRole": "other_agents_are_bounded_workers_reviewers_or_verifiers",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def authority_model() -> dict[str, object]:
    """Expose role-separated authority without pretending it is one ranking."""

    return {
        "schema": "super-brain.authority-model.v1",
        "systemRole": "independent_control_plane_agent",
        "objectiveAuthority": "latest_user_instruction",
        "executionAuthority": "h7_scope_bound_execution_contract",
        "progressAuthority": "assistant_visible_reply_plus_current_project_progress_proof",
        "factAuthority": "live_project_evidence",
        "behaviorAuthority": "versioned_core_rule_registry",
        "supplementalOnly": [
            "typed_memory",
            "absorbed_capabilities",
            "bounded_collaborator_agents",
        ],
        "hostAdapterAuthority": "entry_only_non_authorizing",
        "conflictPolicy": "withhold_reconcile",
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return ""


def _runtime_source_stamps(package_root: Path) -> tuple[tuple[int, int], tuple[int, int]] | None:
    """Return the manifest/registry stamps used by the source-rule cache."""

    paths = (package_root / "manifest.json", package_root / "super-brain-rules.json")
    stamps: list[tuple[int, int]] = []
    for path in paths:
        try:
            stat = path.stat()
        except OSError:
            return None
        stamps.append((stat.st_mtime_ns, stat.st_size))
    return stamps[0], stamps[1]


def _mcp_runtime_identity(package_root: Path) -> str:
    """Return the complete local behavior identity served by a resident MCP.

    Identity compilation uses only a bounded in-process stamp cache. It never
    creates runtime-state directories or leaves machine-local cache artifacts.
    """
    return runtime_identity(package_root)


def _mcp_runtime_identity_paths(package_root: Path) -> tuple[str, ...]:
    """Expose the compiled local dependency closure for regression coverage."""

    return runtime_dependency_paths(package_root)


MCP_RUNTIME_BINDING_SCHEMA = "super-brain.mcp-runtime-binding.v1"
MCP_RUNTIME_TRANSPORT_ENV = "SUPER_BRAIN_MCP_TRANSPORT"
MCP_RUNTIME_EPOCH_ENV = "SUPER_BRAIN_MCP_REGISTRATION_EPOCH"
MCP_RUNTIME_MODE_CLI = "local_cli"
MCP_RUNTIME_MODE_STDIO = "local_stdio_scope_broker"
MCP_RUNTIME_MODE_OFFLINE_REPLAY = "offline_mcp_replay"
_MCP_RUNTIME_MODES = frozenset(
    {
        MCP_RUNTIME_MODE_CLI,
        MCP_RUNTIME_MODE_STDIO,
        MCP_RUNTIME_MODE_OFFLINE_REPLAY,
    }
)
MCP_RUNTIME_BINDING_FIELDS = (
    "schema",
    "state",
    "registrationEpoch",
    "packageVersion",
    "runtimeIdentity",
    "packageRootHash",
    "memoryRootHash",
    "configuredAt",
    "liveHandshake",
    "rawPromptStored",
    "rawTranscriptStored",
)


def _mcp_binding_payload_hash(value: dict[str, Any]) -> str:
    body = {key: value.get(key) for key in MCP_RUNTIME_BINDING_FIELDS}
    return hashlib.sha256(json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()


def _mcp_path_hash(path: Path) -> str:
    normalized = str(path.expanduser().resolve()).rstrip("/\\").lower()
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def _adapter_handshake_transport(adapter_transport: str) -> str:
    """Return the persisted label for an optional external deployment adapter.

    The local MCP runtime does not need a host registration label.  This small
    compatibility mapping only lets pre-existing registered adapters validate
    their own persisted handshakes without becoming core runtime authority.
    """

    if adapter_transport == "codex_registered_v1":
        return "codex_registered_mcp_stdio"
    return "external_registered_mcp_stdio"


@dataclass(frozen=True)
class SandglassRecord:
    timestamp: str
    sender: str
    text: str
    session_key: str = ""
    task_key: str = ""
    workspace_key: str = ""


def _parse_sender(sender: str) -> tuple[str, dict[str, str]]:
    raw = sender.strip()
    role, marker, encoded = raw.partition(";sm1:")
    normalized_role = role.strip().lower()
    if normalized_role == "agent":
        normalized_role = "assistant"
    if not marker or not encoded:
        return normalized_role, {}
    try:
        padding = "=" * (-len(encoded) % 4)
        value = json.loads(base64.urlsafe_b64decode(encoded + padding).decode("utf-8"))
    except (ValueError, UnicodeError, json.JSONDecodeError):
        return normalized_role, {}
    if not isinstance(value, dict) or value.get("schema") != "super-brain.memory-provenance.v1":
        return normalized_role, {}
    return normalized_role, {
        key: str(value.get(key, "")).strip()
        for key in ("sessionKey", "taskKey", "workspaceKey")
        if str(value.get(key, "")).strip()
    }


def _parse_sandglass_record_details(line: str) -> SandglassRecord | None:
    parts = line.rstrip("\r\n").split(" | ", 2)
    if len(parts) != 3:
        return None
    timestamp, raw_sender, text = parts
    if not timestamp or not text:
        return None
    sender, provenance = _parse_sender(raw_sender)
    return SandglassRecord(
        timestamp=timestamp,
        sender=sender,
        text=text,
        session_key=provenance.get("sessionKey", ""),
        task_key=provenance.get("taskKey", ""),
        workspace_key=provenance.get("workspaceKey", ""),
    )


def _parse_sandglass_record(line: str) -> tuple[str, str] | None:
    record = _parse_sandglass_record_details(line)
    if record is None:
        return None
    return record.timestamp, record.text


def _compact(text: str, max_chars: int) -> str:
    value = re.sub(r"\s+", " ", text).strip()
    if len(value) <= max_chars:
        return value
    return value[:max_chars].rstrip() + "..."


def _compact_around(text: str, terms: Iterable[str], max_chars: int) -> str:
    """Keep the evidence window around the strongest query occurrence."""
    value = re.sub(r"\s+", " ", text).strip()
    if len(value) <= max_chars:
        return value
    if max_chars <= 32:
        return value[:max_chars].rstrip() + "..."

    lowered = value.lower()
    centers: list[tuple[int, int]] = []
    for term in dict.fromkeys(str(item).strip() for item in terms if str(item).strip()):
        needle = term.lower()
        start = 0
        while True:
            position = lowered.find(needle, start)
            if position < 0:
                break
            centers.append((position, len(needle)))
            start = position + max(1, len(needle))
    if not centers:
        return value[:max_chars].rstrip() + "..."

    half = max(16, (max_chars - 3) // 2)
    best_window = ""
    best_score: tuple[int, int, int] | None = None
    query_terms = [str(item).lower() for item in terms if str(item).strip()]
    for position, length in centers:
        center = position + max(1, length // 2)
        start = max(0, center - half)
        if start + max_chars > len(value):
            start = max(0, len(value) - max_chars)
        window = value[start : start + max_chars]
        window_lower = window.lower()
        matched = sum(1 for term in query_terms if term in window_lower)
        score = (matched, len(window), start)
        if best_score is None or score > best_score:
            best_score = score
            best_window = window
    if best_window and best_score:
        prefix = "..." if best_score[2] > 0 else ""
        suffix = "..." if best_score[2] + len(best_window) < len(value) else ""
        return prefix + best_window.rstrip() + suffix
    return value[:max_chars].rstrip() + "..."


def _looks_corrupt(text: str) -> bool:
    if not text:
        return False
    return "\ufffd" in text or text.count("?") > max(8, len(text) // 8)


def _tags(text: str) -> list[str]:
    return list(dict.fromkeys(TAG_RE.findall(text)))


def _layer(text: str) -> str:
    if "[PROFILE]" in text:
        return "profile"
    if "[SESSION]" in text:
        return "session"
    if "[TASK]" in text:
        return "task"
    if "[DECISION]" in text or "[ADR]" in text:
        return "decision"
    return "project"


def _meaningful_terms(text: str) -> set[str]:
    terms = {
        word.lower().strip("._-")
        for word in WORD_RE.findall(text)
        if len(word.strip("._-")) >= 3
    }
    for chunk in CJK_RE.findall(text):
        if len(chunk) == 1:
            terms.add(chunk)
            continue
        for index in range(len(chunk) - 1):
            terms.add(chunk[index : index + 2])
    return {
        term
        for term in terms
        if term not in RECALL_EXCLUDED_TERMS
    }


def _contains_term(text: str, term: str) -> bool:
    """Match lexical evidence without treating engine as engineering or port as report."""
    value = str(term).strip().lower()
    if not value:
        return False
    lowered = text.lower()
    if any("\u4e00" <= character <= "\u9fff" for character in value):
        return value in lowered
    return re.search(
        rf"(?<![a-z0-9_]){re.escape(value)}(?![a-z0-9_])",
        lowered,
        re.IGNORECASE,
    ) is not None


def _is_anchor_term(term: str) -> bool:
    """Return whether a term carries enough identity to support a recall hit."""
    if term in RECALL_EXCLUDED_TERMS:
        return False
    if any(character.isdigit() for character in term):
        return True
    if any("\u4e00" <= character <= "\u9fff" for character in term):
        return len(term) >= 2
    return len(term) >= 4


def _parse_dt(value: str) -> datetime | None:
    if not value:
        return None
    normalized = re.sub(r"\s*\([^)]*\)", "", value.replace("T", " ")).strip()
    for fmt in (
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%Y/%m/%d",
    ):
        try:
            return datetime.strptime(normalized[:19], fmt)
        except (TypeError, ValueError):
            continue
    return None


def _age_days(value: str) -> float:
    parsed = _parse_dt(value)
    if parsed is None:
        return 9999.0
    return max(0.0, (datetime.now() - parsed).total_seconds() / 86400.0)


@dataclass
class Candidate:
    text: str
    source: str
    source_type: str
    reason: str
    timestamp: str = ""
    source_priority: int = 1000
    relation_priority: int = 50
    authoritative: bool = False
    matched_terms: list[str] = field(default_factory=list)
    anchor_matches: list[str] = field(default_factory=list)
    exact_match: bool = False
    canonical_match: bool = False
    canonical_explicit: bool = False
    score: float = 0.0
    confidence: float = 0.0
    identity_key: str = ""
    temporal_match: bool = False
    temporal_distance_days: float = 9999.0
    personal_claim: bool = False
    historical_claim: bool = False
    historical_specific: bool = False
    rank_score: float = 0.0
    snapshot_status: str = ""
    verification_status: str = ""
    injection_disposition: str = ""
    rejected_record: bool = False
    sender: str = ""
    session_key: str = ""
    task_key: str = ""
    workspace_key: str = ""
    graph_expansion: bool = False
    claim_value: str = ""


@dataclass(frozen=True)
class GraphEdge:
    subject: str
    relation: str
    object: str
    evidence: str
    tags: str
    source: str
    relation_priority: int


@dataclass(frozen=True)
class RetrievalOutputPolicy:
    max_results: int
    max_tokens: int
    card_max_chars: int
    summary_confidence: float
    inject_confidence: float


class BrainCore:
    def __init__(
        self,
        package_root: str | Path,
        memory_root: str | Path | None = None,
        *,
        scope_provider: ScopeProvider | None = None,
        runtime_mode: str = MCP_RUNTIME_MODE_CLI,
        transport_health: McpTransportHealth | None = None,
    ):
        mode = str(runtime_mode or "").strip()
        if mode not in _MCP_RUNTIME_MODES:
            raise ValueError("H7_MCP_RUNTIME_MODE_INVALID")
        # A non-CLI core is an explicit transport construction.  Do not let a
        # caller label a legacy environment-backed core as local MCP (or
        # offline replay) merely by setting ``runtime_mode``; both injected
        # seams are required before the object can serve requests.
        if mode != MCP_RUNTIME_MODE_CLI:
            if scope_provider is None:
                raise ValueError("H7_SCOPE_PROVIDER_REQUIRED")
            if transport_health is None:
                raise ValueError("H7_MCP_TRANSPORT_HEALTH_REQUIRED")
        self.package_root = Path(package_root).expanduser().resolve()
        self.memory_root = self._resolve_memory_root(memory_root)
        self.memory_base = self._resolve_memory_base()
        self.workspace = self.memory_base / "workspace"
        self.policy = _read_json(self.package_root / "memory-policy.json") or {}
        self.manifest = _read_json(self.package_root / "manifest.json") or {}
        # Execution rules are package-owned, read once, and intentionally kept
        # outside typed memory/recall.  A later registry update is adopted by
        # the explicit hot-refresh lifecycle rather than by a hidden watcher.
        # A long-lived worker must nevertheless fail closed when the on-disk
        # package changes underneath this startup snapshot.
        self._core_rule_registry = load_registry(self.package_root, manifest=self.manifest)
        self._mcp_runtime_identity_startup = _mcp_runtime_identity(self.package_root)
        # Recall-side JSON projections are immutable within one request and
        # cheap to invalidate with the source file stamp.  Keep each source
        # family separate so a malformed file can never poison another one.
        self._experience_json_cache: dict[str, Any] = {}
        self._profile_card_json_cache: dict[str, Any] = {}
        self._self_model_json_cache: dict[str, Any] = {}
        # One bounded, process-local source projection cache.  Every lookup
        # still stats manifest.json and super-brain-rules.json; the cache only
        # avoids reparsing/revalidating unchanged package-owned rule inputs.
        self._runtime_source_projection_cache: dict[str, Any] | None = None
        self._graph_cache_key: tuple[int, int] | None = None
        self._graph_cache: list[GraphEdge] = []
        self.runtime_mode = mode
        self._transport_health = transport_health
        # CLI/test callers retain the explicitly task-local compatibility
        # provider.  Production MCP constructs BrainCore with a broker-backed
        # provider, so no host/cwd/env identity can enter that path.
        self._scope_provider: ScopeProvider = scope_provider or LegacyEnvironmentScopeProvider()

    @property
    def is_local_mcp_runtime(self) -> bool:
        """Whether this core was explicitly constructed by the local MCP entry."""

        return self.runtime_mode == MCP_RUNTIME_MODE_STDIO

    def inject_runtime_transport(
        self,
        *,
        runtime_mode: str,
        transport_health: McpTransportHealth,
        scope_provider: ScopeProvider | None = None,
    ) -> None:
        """Attach one process-owned MCP transport before serving requests.

        This is a construction-time dependency-injection seam, not a runtime
        rebind API.  It lets a stdio entry resolve state once, then inject its
        private channel/provider without reconstructing the package/rules
        core.  A served core cannot be switched to another transport.
        """

        mode = str(runtime_mode or "").strip()
        if mode not in _MCP_RUNTIME_MODES or mode == MCP_RUNTIME_MODE_CLI:
            raise ValueError("H7_MCP_RUNTIME_MODE_INVALID")
        if transport_health is None:
            raise ValueError("H7_MCP_TRANSPORT_HEALTH_REQUIRED")
        if mode != MCP_RUNTIME_MODE_CLI and scope_provider is None:
            raise ValueError("H7_SCOPE_PROVIDER_REQUIRED")
        if self._transport_health is not None or self.runtime_mode != MCP_RUNTIME_MODE_CLI:
            raise RuntimeError("H7_MCP_TRANSPORT_ALREADY_INJECTED")
        if scope_provider is not None:
            self._scope_provider = scope_provider
        self.runtime_mode = mode
        self._transport_health = transport_health

    def scope_status(self) -> dict[str, Any]:
        """Return the current provider binding without selecting a scope."""

        try:
            value = self._scope_provider.status()
        except Exception:
            value = {"state": "withheld", "code": "H7_SCOPE_PROVIDER_UNAVAILABLE"}
        result = dict(value) if isinstance(value, Mapping) else {}
        # A pairing ref is a connection-owned, one-shot control capability.
        # Status is language-model-visible in the MCP route, so it must never
        # disclose a value that could bind an unbound channel.  Lease/channel
        # internals are likewise process-private; normal callers need only
        # the bounded binding state below.
        for private_key in ("pairingRequestRef", "channelId", "leaseId", "leaseExpiresAt"):
            result.pop(private_key, None)
        nested_scope = result.get("scope")
        scope_authorized = bool(
            isinstance(nested_scope, Mapping)
            and str(nested_scope.get("workspaceKey", "")).strip()
            and str(nested_scope.get("ownerSessionKey", "")).strip()
        )
        # A live channel's scope projection contains stable workspace/session/
        # workline identifiers. Status is model-visible and needs only the
        # binding boolean below, never any identity that could be reused as a
        # cross-scope selector or correlation handle.
        result.pop("scope", None)
        result.setdefault("state", "unbound")
        result.setdefault("code", "H7_SCOPE_PROVIDER_UNBOUND")
        result["provider"] = str(result.get("provider") or type(self._scope_provider).__name__)
        # ``ok`` on a broker status is intentionally a query-success bit: an
        # unbound channel is healthy enough to inspect but cannot authorize a
        # tool call.  Make that distinction explicit for MCP consumers rather
        # than relying on every caller to infer it from code/state.
        state = str(result.get("state", "")).strip()
        result["channelAvailable"] = bool(result.get("ok") is True and state in {"unbound", "bound"})
        result["scopeAuthorized"] = bool(state == "bound" and scope_authorized)
        result["rawPromptStored"] = False
        result["rawTranscriptStored"] = False
        return result

    def authorize_scope(self, *, write: bool = False) -> dict[str, Any]:
        """Refresh provider authorization for an operation."""

        try:
            value = self._scope_provider.authorize(write=write)
        except Exception:
            value = {"ok": False, "state": "withheld", "code": "H7_SCOPE_PROVIDER_UNAVAILABLE"}
        return dict(value) if isinstance(value, Mapping) else {"ok": False, "state": "withheld", "code": "H7_SCOPE_PROVIDER_INVALID"}

    def refresh_scope_contract(self, contract: Mapping[str, Any]) -> dict[str, Any]:
        """Refresh a broker projection after the local H7 contract commits.

        The provider owns the channel-private lease and may expose this seam
        only to the turn runtime.  Legacy CLI providers intentionally return a
        non-authorizing not-applicable result.
        """

        refresher = getattr(self._scope_provider, "refresh_contract", None)
        if not callable(refresher):
            return {
                "ok": True,
                "state": "not_applicable",
                "code": "H7_SCOPE_CONTRACT_REFRESH_NOT_APPLICABLE",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        try:
            value = refresher(contract)
        except Exception:
            value = {"ok": False, "state": "withheld", "code": "H7_SCOPE_CONTRACT_REFRESH_FAILED"}
        return dict(value) if isinstance(value, Mapping) else {
            "ok": False,
            "state": "withheld",
            "code": "H7_SCOPE_CONTRACT_REFRESH_INVALID",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def _scope_snapshot(self, *, force: bool = False) -> dict[str, Any]:
        try:
            value = self._scope_provider.snapshot(force=force)
        except Exception:
            return {}
        return dict(value) if isinstance(value, Mapping) else {}

    def core_rules(self, signals: Iterable[Any] = ()) -> dict[str, Any]:
        """Return a bounded rule projection without reading memory or storing signals."""

        return project_core_rules(self._core_rule_registry, signals=signals)

    def runtime_identity_status(
        self,
        signals: Iterable[Any] = (),
        *,
        served_core_rules: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Prove that this process still serves the current H7 package.

        This is deliberately a guard, not a hot reloader.  Reloading an MCP
        worker's rules or Python modules halfway through a governed turn could
        create mixed behavior.  A mismatch is therefore withheld and the host
        must restart/re-register the one MCP transport or use the same H7 CLI.
        """

        signal_values = tuple(signals)
        served = served_core_rules if isinstance(served_core_rules, dict) else self.core_rules(signal_values)
        source_stamps = _runtime_source_stamps(self.package_root)
        source: dict[str, Any]
        cache = self._runtime_source_projection_cache
        if source_stamps is not None and isinstance(cache, dict) and cache.get("stamps") == source_stamps:
            source_manifest = cache.get("manifest")
            registry = cache.get("registry")
            projections = cache.get("projections")
            signal_key = tuple(str(item) for item in signal_values)
            source = projections.get(signal_key) if isinstance(projections, dict) else None
            if not isinstance(source, dict):
                source = project_core_rules(registry, signals=signal_values)
                if isinstance(projections, dict) and source.get("status") == "current":
                    projections.pop(signal_key, None)
                    projections[signal_key] = source
                    while len(projections) > _RUNTIME_SOURCE_PROJECTION_MAX:
                        projections.pop(next(iter(projections)))
        elif source_stamps is None:
            # A missing/unstatable source input is itself a currentness
            # failure. Do not optimistically parse through a transient race;
            # the next request will retry after the package is readable.
            source_manifest = None
            registry = {"status": "withheld", "code": "H7_RUNTIME_SOURCE_RULES_UNAVAILABLE"}
            source = project_core_rules(registry, signals=signal_values)
        else:
            source_manifest = _read_json(self.package_root / "manifest.json")
            if isinstance(source_manifest, dict):
                registry = load_registry(self.package_root, manifest=source_manifest)
                source = project_core_rules(registry, signals=signal_values)
            else:
                registry = {"status": "withheld", "code": "H7_RUNTIME_MANIFEST_UNAVAILABLE"}
                source = project_core_rules(registry, signals=signal_values)
            # Never cache missing, malformed, or withheld inputs. A repaired
            # package must be retried on the very next request.
            if (
                source_stamps is not None
                and isinstance(source_manifest, dict)
                and isinstance(registry, dict)
                and registry.get("status") == "current"
                and source.get("status") == "current"
            ):
                self._runtime_source_projection_cache = {
                    "stamps": source_stamps,
                    "manifest": source_manifest,
                    "registry": registry,
                    "projections": {tuple(str(item) for item in signal_values): source},
                }
        startup_identity = str(self._mcp_runtime_identity_startup or "")
        source_identity = _mcp_runtime_identity(self.package_root)

        # Platform deployment registrations are deliberately not part of the
        # process identity.  A local injected stdio runtime must be current
        # based solely on its startup package/rules closure, even when an
        # embedding host happens to leave stale adapter variables behind.
        registered_root = ""
        registered_identity = ""
        registered_for_this_package = False
        if not self.is_local_mcp_runtime:
            registered_root = str(os.environ.get("SUPER_BRAIN_PACKAGE_ROOT", "")).strip()
            registered_identity = str(os.environ.get("SUPER_BRAIN_RUNTIME_IDENTITY", "")).strip()
            if registered_root:
                try:
                    registered_for_this_package = Path(registered_root).expanduser().resolve() == self.package_root
                except OSError:
                    registered_for_this_package = False

        comparison_fields = ("status", "registryVersion", "payloadHash", "activeEffectsHash", "fileSha256", "packageVersion")
        same_rules = all(str(served.get(field, "")) == str(source.get(field, "")) for field in comparison_fields)
        code = "H7_MCP_RUNTIME_IDENTITY_CURRENT"
        if source.get("status") != "current":
            code = "H7_MCP_RUNTIME_SOURCE_RULES_WITHHELD"
        elif served.get("status") != "current":
            code = "H7_MCP_RUNTIME_SERVED_RULES_WITHHELD"
        elif not same_rules:
            code = "H7_MCP_RUNTIME_RULE_REGISTRY_STALE"
        elif not startup_identity or not source_identity or startup_identity != source_identity:
            code = "H7_MCP_RUNTIME_IDENTITY_STALE"
        state = "current" if code == "H7_MCP_RUNTIME_IDENTITY_CURRENT" else "withheld"
        return {
            "schema": "super-brain.mcp-runtime-identity.v1",
            "state": state,
            "code": code,
            "startupIdentity": startup_identity,
            "sourceIdentity": source_identity,
            "registeredIdentity": registered_identity if registered_for_this_package else "",
            "registeredIdentityChecked": registered_for_this_package,
            # An external adapter's configured identity is diagnostic only.
            # A verified local process must not become stale merely because a
            # particular platform registration has not been refreshed.
            "registeredIdentityMatches": (not registered_for_this_package) or registered_identity == startup_identity,
            "servedCoreRules": served,
            "sourceCoreRules": source,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def _mcp_runtime_binding_path(self) -> Path:
        return self.workspace / "runtime-state" / "mcp-runtime-binding.json"

    def _mcp_adapter_binding_status(
        self,
        runtime_identity: Mapping[str, Any],
    ) -> dict[str, Any]:
        """Validate an optional external deployment adapter, never core health.

        Installer-owned registrations remain useful deployment diagnostics, but
        they are not evidence that an injected local MCP is live.  Avoid even
        reading the adapter-owned binding file unless an adapter has explicitly
        supplied its own configuration markers.
        """

        epoch = str(os.environ.get(MCP_RUNTIME_EPOCH_ENV, "")).strip()
        configured_identity = str(os.environ.get("SUPER_BRAIN_RUNTIME_IDENTITY", "")).strip()
        configured_root = str(os.environ.get("SUPER_BRAIN_PACKAGE_ROOT", "")).strip()
        configured_transport = str(os.environ.get(MCP_RUNTIME_TRANSPORT_ENV, "")).strip()
        configured = bool(epoch or configured_identity or configured_root or configured_transport)
        if not configured:
            return {
                "schema": "super-brain.mcp-deployment-adapter-status.v1",
                "state": "not_configured",
                "code": "H7_MCP_ADAPTER_NOT_CONFIGURED",
                "transport": "",
                "registrationEpochHash": "",
                "runtimeIdentity": "",
                "liveHandshake": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        binding = _read_json(self._mcp_runtime_binding_path())
        try:
            configured_root_matches = bool(configured_root) and Path(configured_root).expanduser().resolve() == self.package_root
        except OSError:
            configured_root_matches = False
        source_identity = str(runtime_identity.get("sourceIdentity", ""))
        package_hash = _mcp_path_hash(self.package_root)
        memory_hash = _mcp_path_hash(self.memory_base)
        binding_epoch = str(binding.get("registrationEpoch", "")).strip() if isinstance(binding, dict) else ""
        binding_identity = str(binding.get("runtimeIdentity", "")).strip() if isinstance(binding, dict) else ""
        binding_hash_current = bool(
            isinstance(binding, dict)
            and str(binding.get("payloadHash", "")) == _mcp_binding_payload_hash(binding)
        )
        base_ok = bool(
            isinstance(binding, dict)
            and binding.get("schema") == MCP_RUNTIME_BINDING_SCHEMA
            and binding_hash_current
            and binding_epoch
            and binding_identity == source_identity
            and str(binding.get("packageRootHash", "")) == package_hash
            and str(binding.get("memoryRootHash", "")) == memory_hash
            and runtime_identity.get("state") == "current"
            and bool(configured_transport)
            and configured_root_matches
            and configured_identity == source_identity
            and epoch == binding_epoch
        )
        handshake = binding.get("liveHandshake") if isinstance(binding, dict) else None
        expected_transport = _adapter_handshake_transport(configured_transport)
        live_ok = bool(
            base_ok
            and isinstance(handshake, Mapping)
            and handshake.get("schema") == "super-brain.mcp-live-handshake.v1"
            and str(handshake.get("registrationEpoch", "")) == binding_epoch
            and str(handshake.get("runtimeIdentity", "")) == source_identity
            and str(handshake.get("transport", "")) == expected_transport
            and (
                expected_transport != "external_registered_mcp_stdio"
                or str(handshake.get("adapterTransport", "")) == configured_transport
            )
        )
        if live_ok:
            state, code = "current", "H7_MCP_ADAPTER_LIVE_HANDSHAKE_CURRENT"
        elif not base_ok:
            state, code = "restart_required", "H7_MCP_ADAPTER_REBIND_REQUIRED"
        else:
            state, code = "restart_required", "H7_MCP_ADAPTER_LIVE_HANDSHAKE_REQUIRED"
        return {
            "schema": "super-brain.mcp-deployment-adapter-status.v1",
            "state": state,
            "code": code,
            "transport": configured_transport,
            "registrationEpochHash": hashlib.sha256(binding_epoch.encode("utf-8")).hexdigest() if binding_epoch else "",
            "runtimeIdentity": source_identity if live_ok else "",
            "liveHandshake": live_ok,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def _record_mcp_adapter_handshake(self, runtime_identity: Mapping[str, Any]) -> dict[str, Any]:
        """Record optional adapter liveness without affecting local MCP health."""

        before = self._mcp_adapter_binding_status(runtime_identity)
        if before.get("state") != "restart_required" or before.get("code") != "H7_MCP_ADAPTER_LIVE_HANDSHAKE_REQUIRED":
            return before
        path = self._mcp_runtime_binding_path()
        binding = _read_json(path)
        if not isinstance(binding, dict):
            return before
        epoch = str(binding.get("registrationEpoch", "")).strip()
        identity = str(runtime_identity.get("sourceIdentity", ""))
        adapter_transport = str(os.environ.get(MCP_RUNTIME_TRANSPORT_ENV, "")).strip()
        handshake: dict[str, Any] = {
            "schema": "super-brain.mcp-live-handshake.v1",
            "registrationEpoch": epoch,
            "runtimeIdentity": identity,
            "transport": _adapter_handshake_transport(adapter_transport),
            "checkedAt": datetime.now(timezone.utc).isoformat(),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        if handshake["transport"] == "external_registered_mcp_stdio":
            handshake["adapterTransport"] = adapter_transport
        binding["state"] = "current"
        binding["liveHandshake"] = handshake
        binding["payloadHash"] = _mcp_binding_payload_hash(binding)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        try:
            temporary.write_text(json.dumps(binding, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
            os.replace(temporary, path)
        except OSError:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            return {**before, "state": "restart_required", "code": "H7_MCP_ADAPTER_LIVE_HANDSHAKE_WRITE_FAILED"}
        return self._mcp_adapter_binding_status(runtime_identity)

    def mcp_transport_status(
        self,
        runtime_identity: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Return platform-neutral health of this process's MCP transport."""

        runtime = runtime_identity if isinstance(runtime_identity, Mapping) else self.runtime_identity_status()
        # An explicit injected transport owns its lifecycle.  Only the
        # legacy, un-injected compatibility core may opt into the historical
        # environment-driven offline replay switch.
        if self._transport_health is None and (
            self.runtime_mode == MCP_RUNTIME_MODE_OFFLINE_REPLAY
            or os.environ.get("SUPER_BRAIN_MCP_OFFLINE_REPLAY") == "1"
        ):
            from mcp_transport_health import OfflineReplayMcpTransportHealth

            return dict(OfflineReplayMcpTransportHealth().status(runtime))
        if self._transport_health is None and self.runtime_mode in {
            MCP_RUNTIME_MODE_STDIO,
            MCP_RUNTIME_MODE_OFFLINE_REPLAY,
        }:
            # An explicitly selected injected mode without its health object
            # is incomplete; never fall back to a deployment adapter just to
            # manufacture a status result.
            return inactive_status(runtime)
        if self._transport_health is None:
            # Keep the optional legacy deployment adapter observable for
            # existing CLI/install diagnostics.  It is deliberately not used
            # by the injected local stdio path and never authorizes work.
            adapter = self._mcp_adapter_binding_status(runtime)
            if adapter.get("state") != "not_configured":
                legacy_code = {
                    "H7_MCP_ADAPTER_LIVE_HANDSHAKE_CURRENT": "H7_MCP_LIVE_HANDSHAKE_CURRENT",
                    "H7_MCP_ADAPTER_LIVE_HANDSHAKE_REQUIRED": "H7_MCP_LIVE_HANDSHAKE_REQUIRED",
                    "H7_MCP_ADAPTER_REBIND_REQUIRED": "H7_MCP_RUNTIME_REBIND_REQUIRED",
                    "H7_MCP_ADAPTER_LIVE_HANDSHAKE_WRITE_FAILED": "H7_MCP_LIVE_HANDSHAKE_WRITE_FAILED",
                }.get(str(adapter.get("code", "")), str(adapter.get("code", "H7_MCP_RUNTIME_REBIND_REQUIRED")))
                configured_transport = str(adapter.get("transport", ""))
                return {
                    "schema": "super-brain.mcp-live-handshake.v1",
                    "state": "current" if adapter.get("state") == "current" else "withheld",
                    "code": legacy_code,
                    "transport": "codex_registered_mcp_stdio" if configured_transport == "codex_registered_v1" else "external_registered_mcp_stdio",
                    "runtimeIdentity": str(adapter.get("runtimeIdentity", "")),
                    "registryVersion": int((runtime.get("servedCoreRules") or {}).get("registryVersion", 0) or 0),
                    "rawPromptStored": False,
                    "rawTranscriptStored": False,
                }
            return inactive_status(runtime)
        try:
            value = self._transport_health.status(runtime)
        except Exception:
            value = {
                "schema": "super-brain.mcp-live-handshake.v2",
                "state": "withheld",
                "code": "H7_MCP_LOCAL_TRANSPORT_UNAVAILABLE",
                "transport": "local_scope_broker_stdio",
                "runtimeIdentity": "",
                "broker": {"state": "withheld", "code": "H7_SCOPE_BROKER_UNAVAILABLE", "available": False},
                "scope": {"provider": "scope_broker_channel", "state": "withheld", "code": "H7_SCOPE_BROKER_UNAVAILABLE", "accessMode": ""},
                "packageVersion": str(self.manifest.get("version", "")),
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        return dict(value) if isinstance(value, Mapping) else inactive_status(runtime)

    def mcp_runtime_binding_status(
        self,
        runtime_identity: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Combine core-local transport state with optional adapter diagnostics."""

        runtime = runtime_identity if isinstance(runtime_identity, Mapping) else self.runtime_identity_status()
        transport = self.mcp_transport_status(runtime)
        adapter = (
            {
                "schema": "super-brain.mcp-deployment-adapter-status.v1",
                "state": "not_applicable",
                "code": "H7_MCP_ADAPTER_NOT_APPLICABLE",
                "transport": "",
                "registrationEpochHash": "",
                "runtimeIdentity": "",
                "liveHandshake": False,
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
            if self.is_local_mcp_runtime or self.runtime_mode == MCP_RUNTIME_MODE_OFFLINE_REPLAY
            else self._mcp_adapter_binding_status(runtime)
        )
        return {
            "schema": "super-brain.mcp-runtime-binding-status.v2",
            "state": str(transport.get("state", "withheld")),
            "code": str(transport.get("code", "H7_MCP_LOCAL_TRANSPORT_UNAVAILABLE")),
            "runtimeMode": self.runtime_mode,
            "transport": str(transport.get("transport", "")),
            "registrationEpochHash": str(adapter.get("registrationEpochHash", "")),
            "runtimeIdentity": str(transport.get("runtimeIdentity", "")),
            "packageVersion": str(self.manifest.get("version", "")),
            "liveHandshake": transport.get("state") == "current",
            "deploymentAdapter": adapter,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def record_mcp_live_handshake(self) -> dict[str, Any]:
        """Mark the injected local transport initialized; record adapters separately.

        Retained under its historical name for callers that already invoke it.
        The returned value is always the local transport handshake, never a
        platform registration record.
        """

        runtime = self.runtime_identity_status()
        if self._transport_health is not None:
            try:
                self._transport_health.mark_initialized(runtime)
            except Exception:
                pass
        # The local Broker transport owns its own process-local lifecycle and
        # must never mutate a host/deployment adapter's global binding file.
        # Only the compatibility CLI/adapter path may record that legacy
        # handshake.
        if self._transport_health is None and self.runtime_mode == MCP_RUNTIME_MODE_CLI:
            self._record_mcp_adapter_handshake(runtime)
        return self.mcp_transport_status(runtime)

    def _resolve_memory_root(self, supplied: str | Path | None) -> Path:
        if supplied:
            # ``supplied`` remains an explicit dependency-injection seam for
            # bounded runtime fixtures.  Host install/bootstrap entry points
            # validate it against stateRoot/shared before constructing the
            # core.  Even here, retired agent/group roots are projected back
            # to their state root's shared child and can never become live.
            return self._project_legacy_memory_root(Path(supplied).expanduser().resolve())
        state_override = os.environ.get("SUPER_BRAIN_STATE_ROOT", "").strip()
        if state_override:
            return (Path(state_override).expanduser().resolve() / "shared")
        configured_state = configured_state_root(self.package_root)
        if configured_state is not None:
            return configured_state / "shared"
        # NEXSANDBASE_HOME is a compatibility input for public/portable
        # packages that do not yet have a runtime layout.  A package layout or
        # explicit state root always wins, so a stale host environment cannot
        # reactivate a different memory tree.
        env_root = os.environ.get("NEXSANDBASE_HOME", "").strip()
        if env_root:
            return self._project_legacy_memory_root(Path(env_root).expanduser().resolve())
        return (resolve_state_root(self.package_root) / "shared").resolve()

    @staticmethod
    def _project_legacy_memory_root(candidate: Path) -> Path:
        """Map retired agent/group roots to the one shared child of their state root."""

        name = candidate.name.lower()
        parent_name = candidate.parent.name.lower()
        if name in {"agents", "groups"}:
            return (candidate.parent / "shared").resolve()
        if parent_name in {"agents", "groups"}:
            return (candidate.parent.parent / "shared").resolve()
        return candidate

    def _resolve_memory_base(self) -> Path:
        resolved = resolve_state_root(self.package_root)
        try:
            self.memory_root.relative_to(resolved)
            return resolved
        except ValueError:
            pass
        return self.memory_root.parent

    @property
    def retrieval(self) -> dict[str, Any]:
        value = self.policy.get("retrieval", {})
        return value if isinstance(value, dict) else {}

    @property
    def hybrid(self) -> dict[str, Any]:
        value = self.retrieval.get("hybrid", {})
        return value if isinstance(value, dict) else {}

    @staticmethod
    def _bounded_int(value: Any, default: int, minimum: int, maximum: int) -> int:
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            parsed = default
        return min(maximum, max(minimum, parsed))

    @staticmethod
    def _bounded_confidence(value: Any, default: float) -> float:
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            parsed = default
        if not math.isfinite(parsed):
            parsed = default
        return min(1.0, max(0.0, parsed))

    def _retrieval_output_policy(
        self,
        requested_top_k: int,
        requested_max_tokens: int,
        evaluation_mode: bool = False,
    ) -> RetrievalOutputPolicy:
        context_budget = self.retrieval.get("contextBudget", {})
        context_budget = context_budget if isinstance(context_budget, dict) else {}
        budget_enabled = bool(context_budget.get("enabled", True))
        result_cap = MAX_EVALUATION_RANK if evaluation_mode else MAX_RECALL_TOP_K
        token_cap = MAX_EVALUATION_TOKENS if evaluation_mode else MAX_RECALL_TOKENS
        max_results = self._bounded_int(requested_top_k, DEFAULT_RECALL_TOP_K, 1, result_cap)
        max_tokens = self._bounded_int(requested_max_tokens, DEFAULT_RECALL_MAX_TOKENS, 32, token_cap)
        card_tokens = self._bounded_int(context_budget.get("cardSnippetTokens"), 56, 20, 1000)

        if budget_enabled and not evaluation_mode:
            max_results = min(
                max_results,
                self._bounded_int(context_budget.get("maxEvidenceCards"), 4, 1, MAX_RECALL_TOP_K),
            )
            max_tokens = min(
                max_tokens,
                self._bounded_int(context_budget.get("evidenceTokens"), 500, 32, MAX_RECALL_TOKENS),
            )

        confidence_policy = self.retrieval.get("confidence", {})
        confidence_policy = confidence_policy if isinstance(confidence_policy, dict) else {}
        summary_confidence = self._bounded_confidence(
            confidence_policy.get("summaryOnly"), 0.2
        )
        inject_confidence = max(
            summary_confidence,
            self._bounded_confidence(confidence_policy.get("inject"), 0.6),
        )
        card_max_chars = max(80, card_tokens * 4)
        if budget_enabled:
            card_max_chars = min(card_max_chars, max_tokens * 4)

        return RetrievalOutputPolicy(
            max_results=max_results,
            max_tokens=max_tokens,
            card_max_chars=card_max_chars,
            summary_confidence=summary_confidence,
            inject_confidence=inject_confidence,
        )

    @staticmethod
    def _limit_output_chars(text: str, max_chars: int) -> str:
        if len(text) <= max_chars:
            return text
        if max_chars <= 3:
            return text[:max_chars]
        return text[: max_chars - 3].rstrip() + "..."

    @staticmethod
    def _evidence_disposition(
        candidate: Candidate,
        output_policy: RetrievalOutputPolicy,
    ) -> str:
        if candidate.confidence < output_policy.summary_confidence:
            return "omit"
        if candidate.verification_status == "unverified":
            return "summary_only"
        if candidate.rejected_record:
            return "summary_only"
        if candidate.source_type == "self_model" and candidate.verification_status != "verified":
            return "summary_only"
        if candidate.confidence < output_policy.inject_confidence:
            return "summary_only"
        return "inject"

    @staticmethod
    def _compatible_aliases(query: str, values: Iterable[str]) -> list[str]:
        """Avoid injecting a different script's aliases into lexical terms."""
        aliases = [str(value).strip() for value in values if str(value).strip()]
        if not re.search(r"[\u4e00-\u9fff]", query):
            aliases = [value for value in aliases if not re.search(r"[\u4e00-\u9fff]", value)]
        return aliases

    def _matched_aliases(self, query: str) -> list[str]:
        lowered = query.lower()
        aliases: list[str] = []
        for key in ("aliasNormalization", "semanticAliasGroups"):
            section = self.retrieval.get(key, {}) if key == "aliasNormalization" else self.retrieval.get(key, [])
            groups = section.get("groups", []) if isinstance(section, dict) else section
            for group in groups or []:
                values = [str(item) for item in group if str(item).strip()]
                if any(value.lower() in lowered for value in values):
                    aliases.extend(self._compatible_aliases(query, values))
        return list(dict.fromkeys(aliases))

    def _query_terms(self, query: str, aliases: Iterable[str] | None = None) -> set[str]:
        return _meaningful_terms(" ".join([query, *(aliases if aliases is not None else self._matched_aliases(query))]))

    def _query_anchors(self, query: str, terms: set[str]) -> set[str]:
        anchors = {term for term in terms if _is_anchor_term(term)}
        dynamic = self.retrieval.get("dynamic", {})
        minimum_length = int(dynamic.get("anchorMinLength", 4)) if isinstance(dynamic, dict) else 4
        if not anchors:
            anchors = {term for term in terms if len(term) >= minimum_length}
        return anchors

    def _query_identity_terms(self, query: str, terms: set[str]) -> set[str]:
        identities: set[str] = set()
        leading_question_words = {
            "what", "when", "where", "which", "who", "why", "how", "current",
            "maximum", "minimum", "does", "did", "is", "are", "can", "could",
        }
        for token in WORD_RE.findall(query):
            normalized = token.strip("._-")
            if not normalized:
                continue
            lowered = normalized.lower()
            if any(character.isdigit() for character in normalized) or "-" in normalized:
                identities.add(lowered)
            elif normalized[:1].isupper() and lowered not in leading_question_words:
                identities.add(lowered)

        cjk = "".join(CJK_RE.findall(query))
        for prefix in (
            "\u8bf7\u95ee", "\u6211\u60f3\u77e5\u9053", "\u6211\u60f3\u95ee", "\u6211\u7684",
            "\u6211", "\u5f53\u524d", "\u73b0\u5728", "\u5173\u4e8e",
        ):
            if cjk.startswith(prefix):
                cjk = cjk[len(prefix) :]
                break
        if len(cjk) >= 2:
            identities.add(cjk[:2])
        return identities.intersection(terms)

    @staticmethod
    def _relative_number(value: str) -> int | None:
        if value.isdigit():
            return int(value)
        return {
            "one": 1,
            "two": 2,
            "three": 3,
            "four": 4,
            "five": 5,
            "six": 6,
            "seven": 7,
            "eight": 8,
            "nine": 9,
            "ten": 10,
            "一": 1,
            "两": 2,
            "二": 2,
            "三": 3,
            "四": 4,
            "五": 5,
            "六": 6,
            "七": 7,
            "八": 8,
            "九": 9,
            "十": 10,
        }.get(value)

    def _temporal_target_date(self, query: str, query_date: str) -> tuple[datetime, int] | None:
        base = _parse_dt(query_date)
        if base is None:
            return None
        lowered = query.lower()
        match = re.search(
            r"\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s+"
            r"(day|days|week|weeks|month|months|year|years)\s+ago\b",
            lowered,
        )
        if match:
            amount = self._relative_number(match.group(1))
            unit = match.group(2)
        else:
            match = re.search(r"\b(last|previous)\s+(day|week|month|year)\b", lowered)
            if match:
                amount = 1
                unit = match.group(2)
            else:
                match = re.search(
                    r"(\d+|一|两|二|三|四|五|六|七|八|九|十)\s*"
                    r"(天|日|周|星期|个月|月|年)\s*(前|以前)",
                    query,
                )
                if not match:
                    return None
                amount = self._relative_number(match.group(1))
                unit = match.group(2)
        if amount is None:
            return None
        if unit in {"day", "days", "天", "日"}:
            days = amount
            tolerance = max(1, min(3, amount // 7 + 1))
        elif unit in {"week", "weeks", "周", "星期"}:
            days = amount * 7
            tolerance = max(2, min(5, amount))
        elif unit in {"month", "months", "个月", "月"}:
            days = amount * 30
            tolerance = max(4, min(10, amount * 2))
        else:
            days = amount * 365
            tolerance = max(14, min(30, amount * 5))
        return base - timedelta(days=days), tolerance

    @staticmethod
    def _session_date(text: str) -> datetime | None:
        match = re.search(
            r"session_date=([0-9]{4}[/-][0-9]{2}[/-][0-9]{2}"
            r"(?:\s+\([^)]*\))?(?:\s+[0-9]{1,2}:[0-9]{2})?)",
            text,
            re.IGNORECASE,
        )
        return _parse_dt(match.group(1)) if match else None

    def _search_queries(self, query: str) -> list[str]:
        queries = [query]
        lowered = query.lower()
        groups = self.retrieval.get("semanticAliasGroups", [])
        for group in groups if isinstance(groups, list) else []:
            values = [str(item) for item in group if str(item).strip()]
            if any(value.lower() in lowered for value in values):
                compatible = self._compatible_aliases(query, values)
                if compatible:
                    queries.append(" ".join(compatible))
                break
        terms = self._query_terms(query)
        anchors = self._query_anchors(query, terms)
        if anchors:
            queries.append(" ".join(sorted(anchors, key=lambda value: (-len(value), value))))
        if terms and anchors and len(anchors) < len(terms):
            focused = anchors | {term for term in terms if len(term) >= 6}
            queries.append(" ".join(sorted(focused, key=lambda value: (-len(value), value))))
        dynamic = self.retrieval.get("dynamic", {})
        max_variants = int(dynamic.get("maxQueryVariants", 4)) if isinstance(dynamic, dict) else 4
        return list(dict.fromkeys(item.strip() for item in queries if item.strip()))[:max(1, max_variants)]

    def _is_self_model_query(self, query: str) -> bool:
        lowered = query.lower()
        triggers = [
            "\u4f60\u662f\u8c01",
            "\u4f60\u505a\u8fc7\u4ec0\u4e48",
            "\u4f60\u4f1a\u505a\u4ec0\u4e48",
            "\u81ea\u6211\u8ba4\u77e5",
            "\u81ea\u6211\u603b\u7ed3",
            "\u81ea\u6211\u5b66\u4e60",
            "\u4f60\u4e86\u89e3\u6211",
            "\u61c2\u7528\u6237",
            "who are you",
            "what have you done",
            "what can you do",
            "self model",
            "self-awareness",
            "self learning",
        ]
        policy_triggers = self.hybrid.get("selfModelIntentTriggers", [])
        return any(trigger.lower() in lowered for trigger in [*triggers, *map(str, policy_triggers)])

    def _is_state_query(self, query: str, terms: set[str]) -> bool:
        lowered = query.lower()
        if "package version" in lowered:
            return True
        subject = any(token in lowered for token in ("super-memory-brain", "super brain", "superbrain", "超级大脑"))
        if not subject:
            return False
        if terms.intersection({"version", "baseline", "manifest", "changelog"}):
            return True
        triggers = [str(item).lower() for item in self.hybrid.get("stateTriggers", [])]
        return any(trigger in lowered for trigger in triggers)

    def _is_profile_query(self, query: str) -> bool:
        lowered = query.lower()
        triggers: list[str] = []
        for key in ("profileIntentTriggers", "personaIntentTriggers"):
            triggers.extend(str(item).lower() for item in self.hybrid.get(key, []))
        triggers.extend(["偏好", "习惯", "风格", "性格", "preference", "persona"])
        return any(trigger in lowered for trigger in triggers)

    def _is_task_query(self, query: str) -> bool:
        lowered = query.lower()
        triggers = (
            "当前任务",
            "任务状态",
            "当前进度",
            "下一步",
            "做到哪",
            "接下来",
            "current task",
            "task status",
            "progress",
            "next step",
        )
        return any(trigger in lowered for trigger in triggers)

    def _is_personal_fact_query(self, query: str) -> bool:
        lowered = query.lower()
        chinese_subject = "\u6211" in lowered
        chinese_fields = (
            "\u4f4f\u5740", "\u5730\u5740", "\u751f\u65e5", "\u5e74\u9f84", "\u804c\u4e1a", "\u516c\u53f8",
            "\u7535\u8bdd", "\u624b\u673a\u53f7", "\u5bb6\u5ead", "\u5bb6\u4eba", "\u56fd\u7c4d", "\u8eab\u4efd\u8bc1",
            "\u5b66\u5386", "\u4e13\u4e1a", "\u5b66\u6821", "\u8001\u5e08", "\u8bba\u6587", "\u6bd5\u4e1a\u8bba\u6587", "\u7236\u4eb2", "\u6bcd\u4eb2", "\u5ba0\u7269",
            "\u6700\u559c\u6b22", "\u6765\u81ea\u54ea\u91cc", "\u5728\u54ea\u91cc\u5de5\u4f5c",
        )
        english_fields = (
            "my favorite", "where do i live", "my address", "my birthday", "my age", "my job",
            "my company", "my phone", "my family", "my nationality", "my identity", "my major",
            "my degree", "my school", "my teacher", "my father", "my mother", "my pet",
        )
        if (chinese_subject and any(field in lowered for field in chinese_fields)) or any(
            field in lowered for field in english_fields
        ):
            return True
        autobiographical_patterns = (
            r"\u6211(?=.*(?:\u642c\u5bb6|\u642c\u8fc7\u5bb6))(?=.*(?:\u54ea|\u4f55\u65f6|\u4ec0\u4e48\u65f6\u5019|\u51e0\u5e74|\u5e74\u4efd|\u5e74))",
            r"\u6211.*(?:\u4f7f\u7528|\u7528\u8fc7|\u8d2d\u4e70|\u4e70\u8fc7).*(?:\u624b\u673a|\u7535\u8111).*(?:\u4ec0\u4e48|\u54ea|\u578b\u53f7|\u54c1\u724c)",
            r"when did i (?:last )?move",
            r"what (?:phone|computer|device) (?:did i|have i) (?:first )?(?:use|own|buy)",
        )
        if any(re.search(pattern, lowered) for pattern in autobiographical_patterns):
            return True
        markers = (
            "我住",
            "我的住址",
            "我的地址",
            "我的生日",
            "我的年龄",
            "我几岁",
            "我的职业",
            "我在哪里工作",
            "我的公司",
            "我的电话",
            "我的手机号",
            "我的家庭",
            "我的家人",
            "我来自哪里",
            "我的国籍",
            "我最喜欢的颜色",
            "我最喜欢的配色",
            "我最喜欢的食物",
            "我最喜欢的编程语言",
            "my favorite",
            "where do i live",
            "my address",
            "my birthday",
            "my age",
            "my job",
            "my company",
        )
        return any(marker in lowered for marker in markers)

    def _personal_fact_candidate_markers(self, query: str) -> tuple[str, ...]:
        lowered = query.lower()
        groups = (
            (("我住", "住址", "地址", "where do i live", "my address"), ("我住", "住址", "地址", "住在")),
            (("生日", "birthday"), ("生日", "出生")),
            (("年龄", "几岁", "my age"), ("年龄", "岁")),
            (("职业", "哪里工作", "my job"), ("职业", "工作", "岗位")),
            (("公司", "my company"), ("公司", "单位")),
            (("电话", "手机号"), ("电话", "手机", "号码")),
            (("家庭", "家人"), ("家庭", "家人")),
            (("来自哪里", "国籍"), ("来自", "国籍")),
            (("身份证", "my identity"), ("身份证", "身份号码", "identity")),
            (("学历", "my degree"), ("学历", "学位", "degree")),
            (("专业", "my major"), ("专业", "主修", "major")),
            (("学校", "my school"), ("学校", "院校", "school")),
            (("老师", "my teacher"), ("老师", "导师", "teacher")),
            (("论文", "毕业论文", "my thesis"), ("论文", "毕业论文", "题目", "标题", "thesis")),
            (("父亲", "my father"), ("父亲", "爸爸", "father")),
            (("母亲", "my mother"), ("母亲", "妈妈", "mother")),
            (("宠物", "my pet"), ("宠物", "pet")),
            (("搬家", "搬过家", "when did i move"), ("搬家", "迁居", "move")),
            (("手机", "电脑", "phone", "computer", "device"), ("手机", "电脑", "型号", "品牌", "device")),
            (("最喜欢的颜色", "最喜欢的配色"), ("颜色", "配色")),
            (("最喜欢的食物",), ("食物", "喜欢吃")),
            (("最喜欢的编程语言",), ("编程语言", "语言")),
        )
        for query_markers, candidate_markers in groups:
            if any(marker in lowered for marker in query_markers):
                return candidate_markers
        return ()

    def _current_workspace_key(self) -> str:
        value = self._scope_snapshot().get("workspaceKey", "")
        return str(value or "").strip().lower()

    def _current_session_key(self) -> str:
        """Return the session bound by the configured scope provider.

        The broker-backed MCP provider is the production identity source.  The
        legacy ``SUPER_BRAIN_LOCAL_SESSION_ID`` environment provider remains
        available only for the standalone CLI/test seam, so this core path
        never reads ambient process identity directly and cannot accidentally
        fall back to a host thread id.
        """

        value = self._scope_snapshot().get("ownerSessionKey", "")
        return str(value or "").strip().lower()

    @staticmethod
    def _session_key_from_value(candidate: str) -> str:
        value = str(candidate or "").strip()
        if not value:
            return ""
        if re.fullmatch(r"sid-[0-9a-f]{16,64}", value, re.IGNORECASE):
            return value.lower()
        return "sid-" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]

    def _workspace_context_pointer_path(self, workspace_key: str) -> Path | None:
        normalized = str(workspace_key or "").strip()
        if not normalized:
            return None
        safe = re.sub(r"[^A-Za-z0-9._-]+", "-", normalized).strip("-").lower() or "workspace"
        token = safe + "--" + hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:16]
        return self.workspace / "guard-state" / "current-task-context-pointers" / f"{token}.json"

    def _intent_receipt_request(self, contract: dict[str, Any]) -> dict[str, Any] | None:
        """Build the bounded intent proof request, or ``None`` if it is malformed.

        An empty mapping means the execution contract does not require an
        intent receipt.  The request is deliberately derived locally and its
        raw instruction is reduced to a digest before leaving this method.
        """

        intent_required = (
            contract.get("intentContractRequired") is True
            or isinstance(contract.get("intentContract"), dict)
            or isinstance(contract.get("intentResolutionReceipt"), dict)
        )
        if not intent_required:
            return {}

        intent_contract = contract.get("intentContract")
        receipt = contract.get("intentResolutionReceipt")
        plan_receipt = contract.get("planReceipt")
        if not all(isinstance(value, dict) for value in (intent_contract, receipt, plan_receipt)):
            return None

        latest_instruction = str(contract.get("latestUserInstruction", ""))
        return {
            "taskId": str(contract.get("taskId", "")),
            "taskInstanceId": str(contract.get("taskInstanceId", "")),
            "workspaceKey": str(contract.get("workspaceKey", "")),
            "ownerSessionKey": str(contract.get("ownerSessionKey", "")),
            "packageVersion": str(contract.get("packageVersion", "")),
            "contractRevision": contract.get("revision"),
            "intentRevision": contract.get("intentRevision"),
            "planFingerprint": str(plan_receipt.get("planFingerprint", "")),
            "latestInstructionHash": hashlib.sha256(latest_instruction.encode("utf-8")).hexdigest(),
            "intentContractFingerprint": str(intent_contract.get("contractFingerprint", "")),
            "receiptId": str(receipt.get("receiptId", "")),
            "payloadHash": str(receipt.get("payloadHash", "")),
        }

    def _intent_receipt_current(self, contract: dict[str, Any]) -> bool:
        request = self._intent_receipt_request(contract)
        if request == {}:
            return True
        if request is None:
            return False
        status = read_intent_context_projection(self.workspace.parent, request)
        return bool(status.get("ok")) and bool(status.get("current"))

    def _execution_contract_context(self) -> dict[str, Any] | None:
        workspace_key = self._current_workspace_key()
        session_key = self._current_session_key()
        if not workspace_key or not session_key:
            return None

        index_path = (
            self.workspace
            / "runtime-state"
            / "execution-hot-index"
            / f"{session_key}--{workspace_key}.json"
        )
        index = _read_json(index_path)
        if (
            not isinstance(index, dict)
            or index.get("schema") != "super-brain.execution-hot-index.v1"
            or str(index.get("workspaceKey", "")).lower() != workspace_key.lower()
            or str(index.get("ownerSessionKey", "")).lower() != session_key
        ):
            return None

        package_version = str(self.manifest.get("version", ""))
        contract_cache: dict[str, Any] = {}

        def cached_contract(contract_name: str) -> Any:
            if contract_name not in contract_cache:
                contract_cache[contract_name] = _read_json(
                    self.workspace / "runtime-state" / "execution-contracts" / contract_name
                )
            return contract_cache[contract_name]

        def entry_contract(entry: dict[str, Any]) -> Any:
            contract_name = Path(str(entry.get("contractFileName", ""))).name
            return cached_contract(contract_name) if contract_name else None

        def selected_contract(contract_name: str) -> Any:
            # Candidate filtering may reuse a request-local read, but the
            # contract that authorizes this return must be read fresh.  A
            # contract can be atomically replaced between the terminal scan
            # and final selection; reusing the screening value would hide that
            # change and could return stale task/proof/authorization fields.
            return _read_json(
                self.workspace / "runtime-state" / "execution-contracts" / contract_name
            )

        entries = [
            entry
            for entry in index.get("entries", []) or []
            if isinstance(entry, dict)
            and str(entry.get("status", "")) == "active"
            # A terminal contract remains durable for history and exact
            # recovery proof, but it must not compete with the one runnable
            # workline.  Runtime-wake already projects this distinction as
            # ``wakeEligible=false``; honour it here before the unique-entry
            # guard.  Missing legacy values remain eligible for backwards
            # compatibility, while a literal false is authoritative.
            and entry.get("wakeEligible", True) is not False
            and str(entry.get("packageVersion", "")) == package_version
        ]
        # A hot index is a derived acceleration structure.  If a completion
        # transaction was interrupted after the contract reached its strict
        # terminal shape, the entry can still say ``wakeEligible=true``.  Do
        # not let that stale projection compete with a runnable task.
        entries = [
            entry
            for entry in entries
            if not self._entry_is_structurally_completed_terminal(
                entry,
                workspace_key=workspace_key,
                session_key=session_key,
                package_version=package_version,
                contract=entry_contract(entry),
            )
        ]
        if len(entries) != 1:
            return None
        entry = entries[0]
        updated_at = _parse_dt(str(entry.get("updatedAt", "")))
        if updated_at is None or (datetime.now() - updated_at).total_seconds() > 168 * 3600:
            return None

        contract_name = Path(str(entry.get("contractFileName", ""))).name
        if not contract_name:
            return None
        contract = selected_contract(contract_name)
        if (
            not isinstance(contract, dict)
            or contract.get("schema") != "super-brain.execution-contract.v1"
            or str(contract.get("status", "")) != "active"
            or str(contract.get("taskId", "")) != str(entry.get("taskId", ""))
            or str(contract.get("workspaceKey", "")).lower() != workspace_key.lower()
            or str(contract.get("ownerSessionKey", "")).lower() != session_key
            or str(contract.get("packageVersion", "")) != package_version
        ):
            return None
        try:
            if int(contract.get("revision", -1)) != int(entry.get("revision", -2)):
                return None
        except (TypeError, ValueError):
            return None
        if contract.get("needsReconciliation") is True:
            return None

        receipt_required = contract.get("planReceiptRequired") is True
        receipt = contract.get("planReceipt")
        receipt_revision = self._record_revision(receipt) if isinstance(receipt, dict) else None
        contract_revision = self._record_revision(contract)
        if receipt_required and (
            not isinstance(receipt, dict)
            or str(receipt.get("focusId", "")) != str(contract.get("focusId", ""))
            or receipt_revision != contract_revision
            or not str(receipt.get("planFingerprint", ""))
        ):
            return None
        if not self._intent_receipt_current(contract):
            return None

        return {
            "status": "active",
            "stale": False,
            "taskId": str(contract.get("taskId", "")),
            "taskInstanceId": str(contract.get("taskInstanceId", "")),
            "workspaceKey": workspace_key,
            "version": package_version,
            "checkedAt": str(contract.get("updatedAt", "")),
            "revision": contract.get("revision"),
            "taskName": str(contract.get("focusLabel", "")),
            "acceptedGoal": str(contract.get("focusLabel", "")),
            "currentStep": str(contract.get("currentStep", "")),
            "nextAction": str(contract.get("nextAction", "")),
            # Keep the compact context projection useful to the local CLI
            # recovery seam. These are typed identity/proof fields only; no
            # raw instruction or transcript is added to the projection.
            "contractHash": context_canonical_hash(contract),
            "intentRevision": contract.get("intentRevision", 0),
            "intentAggregateId": str(contract.get("intentAggregateId", "")),
            "intentContractRequired": contract.get("intentContractRequired") is True,
            "intentResolutionReceipt": contract.get("intentResolutionReceipt") if isinstance(contract.get("intentResolutionReceipt"), dict) else None,
            "_source": "memory\\workspace\\runtime-state\\execution-contracts",
            "_trust": "authoritative",
        }

    def _context_workspace_key(self) -> str:
        """Resolve workspace identity from the configured scope provider."""

        return self._current_workspace_key()

    def _context_project_root(self) -> Path | None:
        """Return the current local project root for proof rechecks."""
        try:
            root = self._scope_provider.project_root()
        except Exception:
            root = None
        if isinstance(root, Path) and root.is_dir():
            return root
        return None

    def _context_session_key(self) -> str:
        """Resolve the owner session from the configured scope provider."""

        value = self._scope_snapshot().get("ownerSessionKey", "")
        return str(value or "").strip().lower()

    def _project_progress_status(self, contract: dict[str, Any]) -> dict[str, Any]:
        """Read and recheck the formal proof without exposing its raw body."""

        return validate_project_progress_proof(
            contract.get("projectProgressProof"),
            project_root=self._context_project_root(),
            expected_phase=contract.get("currentPhase", ""),
            expected_current_step=contract.get("currentStep", ""),
            expected_next_action=contract.get("nextAction", ""),
            expected_completed_steps=contract.get("completedSteps", []),
        )

    def _visible_progress_status(
        self,
        contract: dict[str, Any],
        project_progress_status: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Recheck the exact latest-visible progress anchor for H7 recovery.

        This is intentionally separate from project proof validation: a proof
        can show that files and tests are current, but it cannot establish
        which assistant progress statement a resumed task is allowed to use.
        """

        progress = project_progress_status if isinstance(project_progress_status, dict) else self._project_progress_status(contract)
        return validate_visible_progress_receipt(
            contract.get("visibleProgressReceipt"),
            last_confirmed_sentence=contract.get("lastConfirmedSentence", ""),
            last_confirmed_source=contract.get("lastConfirmedSource", ""),
            current_phase=contract.get("currentPhase", ""),
            current_step=contract.get("currentStep", ""),
            next_action=contract.get("nextAction", ""),
            project_progress_status=progress,
            task_id=contract.get("taskId", ""),
            task_instance_id=contract.get("taskInstanceId", ""),
            workspace_key=contract.get("workspaceKey", ""),
            owner_session_key=contract.get("ownerSessionKey", ""),
            package_version=contract.get("packageVersion", ""),
        )

    @staticmethod
    def _context_timestamp_current(value: Any, max_age_seconds: int = 168 * 3600) -> bool:
        try:
            parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return False
        if parsed.tzinfo is None:
            return False
        age = (datetime.now(timezone.utc) - parsed.astimezone(timezone.utc)).total_seconds()
        return 0 <= age <= max_age_seconds

    def _activation_summary(self, task_id: str = "", task_instance_id: str = "") -> dict[str, Any]:
        session_key = self._context_session_key()
        workspace_key = self._context_workspace_key()
        core_rules = self.core_rules()
        if not session_key or not workspace_key:
            return {
                "state": "withheld",
                "code": "ACTIVATION_SCOPE_MISSING",
                "activationId": "",
                "receiptHash": "",
                "scopeRef": "",
                "coreReady": False,
                "coreRules": core_rules,
                "actionAuthorization": "withheld",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        receipt, code = read_activation_receipt(
            self.memory_base,
            workspace_key=workspace_key,
            session_key=session_key,
            task_id=task_id,
            task_instance_id=task_instance_id,
            package_root=self.package_root,
        )
        if not receipt:
            return {
                "state": "withheld",
                "code": code,
                "activationId": "",
                "receiptHash": "",
                "scopeRef": "",
                "coreReady": False,
                "coreRules": core_rules,
                "actionAuthorization": "withheld",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
        capabilities = receipt.get("capabilities") or {}
        return {
            "state": str(receipt.get("activationState", "withheld")),
            "code": code,
            "activationId": str(receipt.get("activationId", "")),
            "receiptHash": str(receipt.get("receiptHash", "")),
            "scopeRef": str((receipt.get("scope") or {}).get("scopeRef", "")),
            "coreReady": bool(capabilities.get("coreReady", False)),
            "actionAuthorization": str(receipt.get("actionAuthorization", "withheld")),
            "packageVersion": str((receipt.get("package") or {}).get("version", "")),
            "routeMapHash": str((receipt.get("route") or {}).get("routeMapHash", "")),
            "memory": receipt.get("memory") or {},
            "task": receipt.get("task") or {},
            "recovery": receipt.get("recovery") or {},
            "coreRules": receipt.get("coreRules") if isinstance(receipt.get("coreRules"), dict) else core_rules,
            "degradedReasons": list(receipt.get("degradedReasons", []) or [])[:4],
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    @staticmethod
    def _is_completed_terminal_contract(contract: dict[str, Any]) -> bool:
        """Recognize a strict completed workline independently of hot-index flags.

        The terminal lifecycle transaction normally projects ``wakeEligible``
        as false.  A process interruption may leave that projection behind an
        already-complete contract, however.  This predicate is intentionally
        structural: no completed phase with pending work, a parent return, or
        an incomplete canonical plan can be hidden by it.
        """

        if bool(contract.get("returnStack")):
            return False
        pending_steps = contract.get("pendingSteps")
        if isinstance(pending_steps, list) and any(str(item).strip() for item in pending_steps):
            return False
        canonical_plan = contract.get("canonicalPlan")
        items = canonical_plan.get("items") if isinstance(canonical_plan, dict) else None
        if not isinstance(items, list) or not items:
            return False
        statuses = [str(item.get("status", "")) for item in items if isinstance(item, dict)]
        if len(statuses) != len(items) or not all(status in {"completed", "cancelled"} for status in statuses):
            return False

        # Some older closeout transactions completed the canonical plan and
        # deliberately left the human-readable phase name (for example
        # ``R5 Stage 10`` or ``Stage 8 - ... completed``) instead of rewriting
        # it to the literal ``Complete`` token.  Their ``No automatic action``
        # projection is still terminal and must not become a cross-session
        # rebind candidate.  Keep the explicit phase check for legacy cards
        # that use a terminal token without a canonical plan, while accepting
        # this structurally complete/no-auto shape as the equivalent terminal
        # lifecycle state.
        phase = str(contract.get("currentPhase", "")).strip().casefold()
        if phase in {"complete", "completed", "done"}:
            return True
        next_action = str(contract.get("nextAction", "")).strip().casefold()
        return next_action.startswith("no automatic action:")

    @staticmethod
    def _formal_phase_token(value: Any) -> str:
        """Normalize the small formal phase vocabulary used by closeouts.

        This intentionally stays local to the read-side terminal-finalization
        guard so ``brain_core`` does not import the closeout dispatcher and
        create a second lifecycle authority.
        """

        text = str(value or "").strip().casefold()
        match = re.search(r"(?:^|[^a-z0-9])stage\s*(\d+(?:\.\d+)*)", text)
        if match:
            return "stage" + match.group(1)
        match = re.search(r"(?:^|[^a-z0-9])r(\d+)\s*[- ]?\s*stage\s*(\d+(?:\.\d+)*)", text)
        if match:
            return "r" + match.group(1) + "-stage" + match.group(2)
        return ""

    @classmethod
    def _terminal_phase_closeout_missing(cls, contract: dict[str, Any]) -> bool:
        """Return whether a completed terminal card still lacks its own closeout.

        A terminal contract with a current visible-progress receipt used to be
        excluded from the one-shot H7 finalization selector.  When a prior
        Set/aggregate write completed the canonical plan before publishing the
        phase-closeout artifact, that left a real task with no legal repair
        path.  Keep normal wake and ordinary continuation blocked, but allow
        the explicit finalization path to select this exact card until the
        closeout for its current formal phase exists.
        """

        phase = cls._formal_phase_token(contract.get("currentPhase"))
        if not phase:
            return False
        closeouts = contract.get("phaseCloseouts")
        if not isinstance(closeouts, list):
            return True
        revision = int(contract.get("revision", 0) or 0)
        plan = contract.get("planReceipt") if isinstance(contract.get("planReceipt"), dict) else {}
        fingerprint = str(contract.get("planFingerprint") or plan.get("planFingerprint") or "")
        for closeout in closeouts:
            if not isinstance(closeout, dict):
                continue
            closeout_phase = cls._formal_phase_token(closeout.get("phase")) or str(closeout.get("phase", "")).strip().casefold()
            if (
                closeout_phase == phase
                and int(closeout.get("contractRevision", -1) or -1) == revision
                and str(closeout.get("planFingerprint", "")) == fingerprint
                and str(closeout.get("schema", "")) == "super-brain.phase-closeout.v4"
            ):
                return False
        return True

    def _entry_is_structurally_completed_terminal(
        self,
        entry: dict[str, Any],
        *,
        workspace_key: str,
        session_key: str,
        package_version: str,
        contract: Any = _CONTRACT_UNSET,
    ) -> bool:
        """Return whether one active-looking index entry is terminal in authority.

        This is read-only recovery isolation.  It never changes the stale
        entry or promotes a completion; the normal completion transaction
        remains responsible for terminalizing the lifecycle projection.
        """

        contract_name = Path(str(entry.get("contractFileName", ""))).name
        if not contract_name:
            return False
        if contract is _CONTRACT_UNSET:
            contract = _read_json(self.workspace / "runtime-state" / "execution-contracts" / contract_name)
        return bool(
            isinstance(contract, dict)
            and str(contract.get("schema", "")) == "super-brain.execution-contract.v1"
            and str(contract.get("status", "")) == "active"
            and str(contract.get("taskId", "")) == str(entry.get("taskId", ""))
            and str(contract.get("workspaceKey", "")).lower() == workspace_key.lower()
            and str(contract.get("ownerSessionKey", "")).lower() == session_key
            and str(contract.get("packageVersion", "")) == package_version
            and contract.get("needsReconciliation") is not True
            and self._is_completed_terminal_contract(contract)
        )

    @staticmethod
    def _is_terminal_finalization_contract(contract: dict[str, Any]) -> bool:
        """Allow one completed task back into H7 only for its final close.

        A terminal task is deliberately removed from normal auto-wake selection
        when its next action becomes ``No automatic action: ...``.  That must
        not strand the mandatory final H7 checkpoint/close transaction.  This
        predicate is intentionally stricter than a terminal-looking sentence:
        it requires the structural completion state and an absent durable
        receipt, so it cannot revive an already-closed task for ordinary work.
        """

        if not BrainCore._is_completed_terminal_contract(contract):
            return False
        if not str(contract.get("nextAction", "")).strip().casefold().startswith("no automatic action:"):
            return False
        # A current visible receipt normally means the finalization checkpoint
        # already ran.  One interrupted route, however, can publish that
        # receipt and terminalize the canonical plan before the formal phase
        # closeout is persisted.  Keep that card available only to the
        # explicit finalization selector until its matching closeout exists;
        # ordinary wake/continuation still filters it out.
        if (
            isinstance(contract.get("visibleProgressReceipt"), dict)
            and contract.get("visibleProgressReceipt")
            and not BrainCore._terminal_phase_closeout_missing(contract)
        ):
            return False
        proof = contract.get("projectProgressProof")
        # The final checkpoint is the one governed path allowed to repair a
        # missing/stale project proof.  A terminal contract is deliberately
        # non-wake-eligible, so requiring an already-current proof here would
        # strand the checkpoint before it can bind the fresh proof supplied in
        # that same H7 transaction.  Ordinary context reads still pass
        # ``allow_terminal_finalization=False`` and therefore never select it.
        if not isinstance(proof, dict) or str(proof.get("state", "")) not in {"current", "withheld"}:
            return False
        return True

    def _read_context_contract(
        self,
        workspace_key: str,
        session_key: str,
        *,
        allow_terminal_finalization: bool = False,
        allow_reconciliation_checkpoint: bool = False,
        terminal_finalization_phase: str = "",
    ) -> tuple[dict[str, Any] | None, str]:
        """Read one unique current execution contract without touching SQLite or pointers."""

        # Scope values become filename components below.  Keep this reader
        # fail-closed even when an internal adapter hands it malformed or
        # path-like input; public adapters normally pre-validate the same
        # H7 keys, but the authority boundary should not rely on every caller
        # remembering that check.
        workspace_key = str(workspace_key or "").strip().lower()
        session_key = str(session_key or "").strip().lower()
        if not re.fullmatch(r"ws-[0-9a-f]{24}", workspace_key) or not re.fullmatch(
            r"sid-[0-9a-f]{16,64}", session_key
        ):
            return None, "BRAIN_CONTEXT_SCOPE_INVALID"
        index_path = self.workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json"
        index = _read_json(index_path)
        if not isinstance(index, dict):
            return None, "BRAIN_CONTEXT_HOT_INDEX_MISSING"
        if (
            index.get("schema") != "super-brain.execution-hot-index.v1"
            or str(index.get("workspaceKey", "")).lower() != workspace_key.lower()
            or str(index.get("ownerSessionKey", "")).lower() != session_key
        ):
            return None, "BRAIN_CONTEXT_HOT_INDEX_SCOPE_MISMATCH"
        package_version = str(self.manifest.get("version", ""))
        contract_cache: dict[str, Any] = {}

        def cached_contract(contract_name: str) -> Any:
            if contract_name not in contract_cache:
                contract_cache[contract_name] = _read_json(
                    self.workspace / "runtime-state" / "execution-contracts" / contract_name
                )
            return contract_cache[contract_name]

        def entry_contract(entry: dict[str, Any]) -> Any:
            contract_name = Path(str(entry.get("contractFileName", ""))).name
            return cached_contract(contract_name) if contract_name else None

        def selected_contract(contract_name: str) -> Any:
            # Keep the fast request-local screening cache, but never use it for
            # the final authority read.  This preserves the old freshness
            # boundary when a contract is replaced during selection.
            return _read_json(
                self.workspace / "runtime-state" / "execution-contracts" / contract_name
            )

        scoped_entries = [
            entry
            for entry in index.get("entries", []) or []
            if isinstance(entry, dict)
            and str(entry.get("status", "")) == "active"
            # Terminal cards intentionally remain in the index for bounded
            # history, but runtime context must choose only a runnable
            # workline.  A stale context pointer is merely an ambiguity hint;
            # it must never revive an explicitly non-wake-eligible entry.
            # Missing legacy values remain eligible for compatibility.
            and str(entry.get("packageVersion", "")) == package_version
        ]
        entries = [
            entry
            for entry in scoped_entries
            if entry.get("wakeEligible", True) is not False
            and not self._entry_is_structurally_completed_terminal(
                entry,
                workspace_key=workspace_key,
                session_key=session_key,
                package_version=package_version,
                contract=entry_contract(entry),
            )
        ]
        terminal_finalization = False
        if not entries:
            if not allow_terminal_finalization:
                return None, "BRAIN_CONTEXT_NO_ACTIVE_CONTRACT"
            phase_hint = self._formal_phase_token(terminal_finalization_phase)
            terminal_entries: list[dict[str, Any]] = []
            for candidate in scoped_entries:
                if not self._context_timestamp_current(candidate.get("updatedAt", "")):
                    continue
                contract_name = Path(str(candidate.get("contractFileName", ""))).name
                if not contract_name:
                    continue
                terminal_contract = cached_contract(contract_name)
                if (
                    isinstance(terminal_contract, dict)
                    and str(terminal_contract.get("schema", "")) == "super-brain.execution-contract.v1"
                    and str(terminal_contract.get("status", "")) == "active"
                    and str(terminal_contract.get("taskId", "")) == str(candidate.get("taskId", ""))
                    and str(terminal_contract.get("workspaceKey", "")).lower() == workspace_key.lower()
                    and str(terminal_contract.get("ownerSessionKey", "")).lower() == session_key
                    and str(terminal_contract.get("packageVersion", "")) == package_version
                    and terminal_contract.get("needsReconciliation") is not True
                    and (
                        not phase_hint
                        or self._formal_phase_token(terminal_contract.get("currentPhase")) == phase_hint
                    )
                    and self._is_terminal_finalization_contract(terminal_contract)
                ):
                    terminal_entries.append(candidate)
            if len(terminal_entries) != 1:
                return None, (
                    "BRAIN_CONTEXT_TERMINAL_FINALIZATION_AMBIGUOUS"
                    if terminal_entries
                    else "BRAIN_CONTEXT_NO_ACTIVE_CONTRACT"
                )
            entries = terminal_entries
            terminal_finalization = True
        context_hint = self._read_current_context_pointer(workspace_key, session_key)
        if context_hint is not None:
            hinted_entries = [
                entry
                for entry in entries
                if str(entry.get("taskId", "")) == str(context_hint.get("taskId", ""))
            ]
            if len(hinted_entries) == 1:
                entries = hinted_entries
        if len(entries) != 1:
            return None, "BRAIN_CONTEXT_AMBIGUOUS_ACTIVE_CONTRACT"
        entry = entries[0]
        if not self._context_timestamp_current(entry.get("updatedAt", "")):
            return None, "BRAIN_CONTEXT_HOT_INDEX_STALE_OR_FUTURE"
        contract_name = Path(str(entry.get("contractFileName", ""))).name
        if not contract_name:
            return None, "BRAIN_CONTEXT_CONTRACT_NAME_INVALID"
        contract = selected_contract(contract_name)
        if (
            not isinstance(contract, dict)
            or contract.get("schema") != "super-brain.execution-contract.v1"
            or str(contract.get("status", "")) != "active"
            or str(contract.get("taskId", "")) != str(entry.get("taskId", ""))
            or not str(contract.get("taskId", ""))
            or not str(contract.get("taskInstanceId", ""))
            or str(contract.get("workspaceKey", "")).lower() != workspace_key.lower()
            or str(contract.get("ownerSessionKey", "")).lower() != session_key
            or str(contract.get("packageVersion", "")) != package_version
        ):
            return None, "BRAIN_CONTEXT_CONTRACT_SCOPE_MISMATCH"
        # A broker-bound provider may carry the exact contract hash that was
        # authorized when its channel was paired.  Re-read and compare it
        # here so a stale/replaced contract cannot be used through an otherwise
        # valid channel.  Legacy CLI providers intentionally have no hash and
        # continue through the existing H7 validation path.
        expected_contract_hash = str(self._scope_snapshot().get("contractHash", "")).strip().lower()
        if expected_contract_hash:
            actual_contract_hash = context_canonical_hash(contract)
            if expected_contract_hash != actual_contract_hash:
                return None, "BRAIN_CONTEXT_SCOPE_CONTRACT_HASH_MISMATCH"
        try:
            contract_revision_value = int(contract.get("revision", -1))
            index_revision_value = int(entry.get("revision", -2))
        except (TypeError, ValueError):
            return None, "BRAIN_CONTEXT_CONTRACT_REVISION_INVALID"
        hot_index_lagging = contract_revision_value > index_revision_value
        if contract_revision_value != index_revision_value and not hot_index_lagging:
            return None, "BRAIN_CONTEXT_CONTRACT_REVISION_MISMATCH"
        reconciliation_checkpoint = contract.get("needsReconciliation") is True
        if reconciliation_checkpoint and not allow_reconciliation_checkpoint:
            return None, "BRAIN_CONTEXT_RECONCILIATION_REQUIRED"
        if not self._context_timestamp_current(contract.get("updatedAt", "")):
            return None, "BRAIN_CONTEXT_CONTRACT_STALE_OR_FUTURE"
        receipt_required = contract.get("planReceiptRequired") is True
        receipt = contract.get("planReceipt")
        receipt_revision = self._record_revision(receipt) if isinstance(receipt, dict) else None
        contract_revision = self._record_revision(contract)
        if receipt_required and (
            not isinstance(receipt, dict)
            or str(receipt.get("focusId", "")) != str(contract.get("focusId", ""))
            or receipt_revision != contract_revision
            or not str(receipt.get("planFingerprint", ""))
        ):
            return None, "BRAIN_CONTEXT_PLAN_RECEIPT_INVALID"
        if not self._intent_receipt_current(contract):
            return None, "BRAIN_CONTEXT_INTENT_RECEIPT_NOT_CURRENT"
        # The hot index is a derived acceleration artifact, not an authority.
        # A killed/timed-out PowerShell launcher can leave it one or more
        # revisions behind an otherwise current, identity-matched contract.
        # Recover read-only from that strictly one-way condition; an index that
        # is ahead still fails closed because its contract may not have landed.
        if reconciliation_checkpoint:
            # A pending instruction normally makes this contract unavailable
            # to every continuation path.  H7's explicit checkpoint is the
            # sole exception: it needs the same scope-bound contract in order
            # to bind the current instruction, project proof, and visible
            # progress in one CAS transaction.  The caller is required to
            # expose this as a checkpoint-only preflight; it is never a
            # runnable ordinary context.
            return contract, "BRAIN_CONTEXT_RECONCILIATION_CHECKPOINT_READY"
        if terminal_finalization:
            return contract, "BRAIN_CONTEXT_TERMINAL_FINALIZATION_READY"
        return contract, "BRAIN_CONTEXT_HOT_INDEX_LAGGING_FALLBACK" if hot_index_lagging else "BRAIN_CONTEXT_READY"

    def _read_current_context_pointer(
        self, workspace_key: str = "", session_key: str = ""
    ) -> dict[str, Any] | None:
        """Read one fresh, scope-bound context pointer as an ambiguity hint.

        The hot index can legitimately contain a completed predecessor and the
        newly approved current workline during a same-session handoff.  A
        current-task context pointer is the only permitted selector in that
        case; it is not a fallback to an old summary or a global pointer.
        """

        current_key = str(workspace_key or self._current_workspace_key()).strip()
        current_session = str(session_key or self._current_session_key()).strip()
        if not current_key or not current_session:
            return None
        pointer_path = self._workspace_context_pointer_path(current_key)
        context = _read_json(pointer_path) if pointer_path is not None else None
        if not isinstance(context, dict):
            context = _read_json(self.workspace / "current-task-context.json")
        if not isinstance(context, dict):
            return None
        if str(context.get("status", "")) != "active" or context.get("stale") is True:
            return None
        task_id = str(context.get("taskId", "")).strip()
        context_key = str(context.get("workspaceKey", "")).strip()
        owner_session = str(context.get("ownerSessionKey", "")).strip()
        if (
            not task_id
            or not context_key
            or context_key.lower() != current_key.lower()
            or not owner_session
            or owner_session.lower() != current_session.lower()
        ):
            return None
        if str(context.get("version", self.manifest.get("version", ""))) != str(
            self.manifest.get("version", "")
        ):
            return None
        expires_at = _parse_dt(str(context.get("expiresAt", "")))
        if expires_at is not None and expires_at <= datetime.now():
            return None
        return context

    @staticmethod
    def _context_memory_effect(entry: dict[str, Any]) -> dict[str, Any]:
        kind = str(entry["kind"])
        item = entry["item"]
        result: dict[str, Any] = {
            "kind": kind,
            "effect": str(item["effect"]),
            "title": _compact(str(item["title"]), 180),
        }
        if kind == "preference":
            result["guidance"] = _compact(str(item["statement"]), 360)
            result["conditions"] = [_compact(str(value), 120) for value in item["conditions"][:3]]
        elif kind == "experience":
            result["guidance"] = _compact(str(item["lesson"]), 360)
            result["prevention"] = _compact(str(item["prevention"]), 240)
        elif kind == "procedure":
            result["objective"] = _compact(str(item["objective"]), 240)
            result["steps"] = [_compact(str(value), 160) for value in item["steps"][:4]]
            result["verification"] = [_compact(str(value), 140) for value in item["verification"][:2]]
        elif kind == "note":
            result["reference"] = _compact(str(item["body"]), 320)
        else:
            result["candidateState"] = str(item["candidateState"])
            result["proposal"] = _compact(str(item["proposedAction"]), 280)
            result["trialState"] = str(item.get("trialState", "not_started"))
            result["trialVerdict"] = str(item.get("trialVerdict", "absent"))
        return result

    def context(
        self,
        memory_mode: str = "auto",
        turn_outcome: str = "unknown",
        user_control: str = "unknown",
        completion_evidence_present: bool = False,
        rule_signals: Iterable[Any] = (),
        terminal_finalization: bool = False,
        reconciliation_checkpoint: bool = False,
        turn_runtime_snapshot: bool = False,
        terminal_finalization_phase: str = "",
    ) -> dict[str, Any]:
        """Return a bounded, pure-read context packet for the current local turn.

        ``turn_runtime_snapshot`` is an internal, one-call optimization seam.
        It carries the contract and its already-revalidated project-proof
        status only from this call to ``turn_runtime.open_turn``. It is not a
        cache or durable record, and the runtime removes it before any result
        can reach an adapter.
        """

        mode = str(memory_mode or "auto").lower()
        core_rules = self.core_rules(rule_signals)
        runtime_identity = self.runtime_identity_status(rule_signals, served_core_rules=core_rules)
        if mode not in {"auto", "force", "off"}:
            return {
                "ok": False, "schema": "super-brain.context.v1", "available": False,
                "code": "BRAIN_CONTEXT_MEMORY_MODE_INVALID", "memoryMode": mode,
                "coreRules": core_rules,
                "rawPromptStored": False, "rawTranscriptStored": False,
            }
        if core_rules.get("status") != "current":
            return {
                "ok": True, "schema": "super-brain.context.v1", "available": False,
                "code": "BRAIN_CONTEXT_CORE_RULES_WITHHELD", "memoryMode": mode,
                "coreRules": core_rules,
                "rawPromptStored": False, "rawTranscriptStored": False,
            }
        if runtime_identity.get("state") != "current":
            return {
                "ok": True, "schema": "super-brain.context.v1", "available": False,
                "code": "BRAIN_CONTEXT_RUNTIME_IDENTITY_WITHHELD", "memoryMode": mode,
                "coreRules": core_rules, "runtimeIdentity": runtime_identity,
                "rawPromptStored": False, "rawTranscriptStored": False,
            }
        if mode == "off":
            return {
                "ok": True, "schema": "super-brain.context.v1", "available": False,
                "code": "BRAIN_CONTEXT_MEMORY_OFF", "memoryMode": mode,
                "coreRules": core_rules,
                "typedMemory": {"state": "disabled", "refs": [], "payloadHash": ""},
                "rawPromptStored": False, "rawTranscriptStored": False,
            }
        session_key = self._context_session_key()
        if not session_key:
            return {
                "ok": True, "schema": "super-brain.context.v1", "available": False,
                "code": "BRAIN_CONTEXT_LOCAL_SESSION_MISSING", "memoryMode": mode,
                "coreRules": core_rules,
                "rawPromptStored": False, "rawTranscriptStored": False,
            }
        workspace_key = self._context_workspace_key()
        if not workspace_key:
            return {
                "ok": True, "schema": "super-brain.context.v1", "available": False,
                "code": "BRAIN_CONTEXT_WORKSPACE_UNAVAILABLE", "memoryMode": mode,
                "coreRules": core_rules,
                "rawPromptStored": False, "rawTranscriptStored": False,
            }
        contract, code = self._read_context_contract(
            workspace_key,
            session_key,
            allow_terminal_finalization=terminal_finalization,
            allow_reconciliation_checkpoint=reconciliation_checkpoint,
            terminal_finalization_phase=terminal_finalization_phase,
        )
        if contract is None:
            return {
                "ok": True, "schema": "super-brain.context.v1", "available": False,
                "code": code, "memoryMode": mode,
                "coreRules": core_rules,
                "activation": self._activation_summary(),
                "rawPromptStored": False, "rawTranscriptStored": False,
            }
        activation = self._activation_summary(str(contract.get("taskId", "")), str(contract.get("taskInstanceId", "")))
        scope = {
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "scopeRef": context_canonical_hash({
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "taskId": str(contract["taskId"]),
                "taskInstanceId": str(contract["taskInstanceId"]),
            }),
        }
        focus = " ".join(value for value in (str(contract.get("focusId", "")).strip(), str(contract.get("focusLabel", "")).strip()) if value)
        selection = select_native_memory_entries(
            self.workspace.parent,
            {
                "global": "user",
                "workspace": workspace_key,
                "task": str(contract["taskId"]),
                "task_instance": str(contract["taskInstanceId"]),
                "session": session_key,
            },
            focus,
        )
        effects = [self._context_memory_effect(entry) for entry in selection["entries"]]
        refs = selection["refs"]
        typed_payload_hash = context_canonical_hash({
            "scopeRef": scope["scopeRef"],
            "snapshotPayloadHash": selection["snapshotPayloadHash"],
            "refs": refs,
            "effects": effects,
        }) if effects else ""
        progress_status = self._project_progress_status(contract)
        visible_progress_status = self._visible_progress_status(contract, progress_status)
        task = {
            "taskId": str(contract["taskId"]),
            "taskInstanceId": str(contract["taskInstanceId"]),
            "contractRevision": int(contract.get("revision", 0)),
            "contractHash": context_canonical_hash(contract),
            "lastConfirmedSentence": _compact(str(contract.get("lastConfirmedSentence", "")), 360),
            "lastConfirmedSource": _compact(str(contract.get("lastConfirmedSource", "")), 64),
            "currentPhase": _compact(str(contract.get("currentPhase", "")), 160),
            "currentStep": _compact(str(contract.get("currentStep", "")), 240),
            "nextAction": _compact(str(contract.get("nextAction", "")), 360),
            "projectProgress": {
                "state": str(progress_status.get("state", "withheld")),
                "payloadHash": str(progress_status.get("payloadHash", "")),
                "missing": list(progress_status.get("missing", []) or [])[:8],
                "completedCount": int(progress_status.get("completedCount", 0) or 0),
                "evidenceCount": int(progress_status.get("evidenceCount", 0) or 0),
                "verificationCount": int(progress_status.get("verificationCount", 0) or 0),
                "verificationState": str(progress_status.get("verificationState", "withheld")),
            },
            "visibleProgress": {
                "state": str(visible_progress_status.get("state", "withheld")),
                "code": str(visible_progress_status.get("code", "H7_VISIBLE_PROGRESS_RECEIPT_REQUIRED")),
                "missing": list(visible_progress_status.get("missing", []) or [])[:8],
                "source": str(visible_progress_status.get("source", "")),
                "sentenceHash": str(visible_progress_status.get("sentenceHash", "")),
                "payloadHash": str(visible_progress_status.get("payloadHash", "")),
                "projectProgressPayloadHash": str(visible_progress_status.get("projectProgressPayloadHash", "")),
                "scopeBindingHash": str(visible_progress_status.get("scopeBindingHash", "")),
                "continuationEligible": bool(visible_progress_status.get("continuationEligible") is True),
            },
            "canResumeParent": bool(contract.get("returnStack")),
            "actionAuthorization": "withheld",
        }
        canonical_plan = contract.get("canonicalPlan") if isinstance(contract.get("canonicalPlan"), dict) else {}
        canonical_items = canonical_plan.get("items") if isinstance(canonical_plan.get("items"), list) else []
        canonical_statuses = [str(item.get("status", "")) for item in canonical_items if isinstance(item, dict)]
        canonical_plan_summary = (
            {
                "itemCount": len(canonical_items),
                "completedCount": sum(status == "completed" for status in canonical_statuses),
                "pendingCount": sum(status in {"pending", "in_progress"} for status in canonical_statuses),
                "cancelledCount": sum(status == "cancelled" for status in canonical_statuses),
            }
            if len(canonical_statuses) == len(canonical_items) and canonical_items
            else {}
        )
        continuation_resolution = {
            "ok": True,
            "actionAuthorization": "allowed",
            "claimAllowed": True,
            "needsConfirmation": False,
            "blockers": list(contract.get("blockers", []) or []),
            "nextAction": str(contract.get("nextAction", "")),
            "currentPhase": str(contract.get("currentPhase", "")),
            "canonicalPlan": canonical_plan_summary,
            "canResumeParent": bool(contract.get("returnStack")),
        }
        continuation = decide_turn_close(
            continuation_resolution,
            turn_outcome=turn_outcome,
            user_control=user_control,
            completion_evidence_present=completion_evidence_present,
        )
        result = {
            "ok": True,
            "schema": "super-brain.context.v1",
            "available": True,
            "code": code,
            "reconciliationCheckpointOnly": bool(
                code == "BRAIN_CONTEXT_RECONCILIATION_CHECKPOINT_READY"
            ),
            "memoryMode": mode,
            "scope": scope,
            "activation": activation,
            "agentIdentity": agent_identity(),
            "authorityModel": authority_model(),
            "task": task,
            "continuation": continuation,
            "coreRules": core_rules,
            "typedMemory": {
                "state": str(selection["state"]),
                "snapshotPayloadHash": str(selection["snapshotPayloadHash"]),
                "refs": refs,
                "effects": effects,
                "payloadHash": typed_payload_hash,
            },
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        if turn_runtime_snapshot:
            # This object is private to the current Python call stack. It
            # avoids only the immediately duplicated read by turn_runtime;
            # it never reaches receipts, telemetry, memory, or public output.
            result[TURN_RUNTIME_CONTEXT_SNAPSHOT_KEY] = {
                "schema": TURN_RUNTIME_CONTEXT_SNAPSHOT_SCHEMA,
                "contract": contract,
                "contractHash": str(task.get("contractHash", "")),
                "contractRevision": int(task.get("contractRevision", 0) or 0),
                "projectProgressStatus": progress_status,
            }
        return result

    def _current_task_context(self) -> dict[str, Any] | None:
        contract_context = self._execution_contract_context()
        if contract_context is not None:
            return contract_context

        current_key = self._current_workspace_key()
        context = self._read_current_context_pointer(current_key, self._current_session_key())
        source = "memory\\workspace\\guard-state\\current-task-context-pointers"
        if not isinstance(context, dict):
            context = _read_json(self.workspace / "current-task-context.json")
            source = "memory\\workspace\\current-task-context.json"
        if not isinstance(context, dict):
            return None
        if str(context.get("status", "")) != "active" or context.get("stale") is True:
            return None
        task_id = str(context.get("taskId", "")).strip()
        context_key = str(context.get("workspaceKey", "")).strip()
        if not task_id or not context_key or not current_key:
            return None
        if context_key.lower() != current_key.lower():
            return None
        context_owner = str(context.get("ownerSessionKey", "")).strip().lower()
        current_session = self._current_session_key()
        if not current_session or not context_owner or current_session.lower() != context_owner:
            return None
        if str(context.get("version", self.manifest.get("version", ""))) != str(self.manifest.get("version", "")):
            return None
        expires_at = _parse_dt(str(context.get("expiresAt", "")))
        if expires_at is not None and expires_at <= datetime.now():
            return None
        trust = "context_pointer" if source.endswith("current-task-context-pointers") else "legacy_context"
        return {**context, "_source": source, "_trust": trust}

    @staticmethod
    def _safe_task_id(value: str) -> str:
        safe = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-").lower()
        return safe[:120]

    def _current_task_checkpoint(self, context: dict[str, Any]) -> dict[str, Any] | None:
        task_id = self._safe_task_id(str(context.get("taskId", "")))
        if not task_id:
            return None
        path = self.workspace / "runtime-state" / "checkpoints" / "active" / f"{task_id}.json"
        checkpoint = _read_json(path)
        if not isinstance(checkpoint, dict):
            return None
        if str(checkpoint.get("status", "")) != "active":
            return None
        if str(checkpoint.get("taskId", "")) != str(context.get("taskId", "")):
            return None
        if str(checkpoint.get("workspaceKey", "")).lower() != str(context.get("workspaceKey", "")).lower():
            return None
        current_version = str(self.manifest.get("version", ""))
        context_version = str(context.get("version", current_version))
        checkpoint_version = str(checkpoint.get("version", ""))
        if not checkpoint_version or checkpoint_version != current_version or checkpoint_version != context_version:
            return None
        checkpoint_time = self._record_timestamp(checkpoint)
        context_time = self._record_timestamp(context)
        if checkpoint_time is None or (context_time is not None and checkpoint_time < context_time):
            return None
        checkpoint_revision = self._record_revision(checkpoint)
        context_revision = self._record_revision(context)
        if context_revision is not None and (checkpoint_revision is None or checkpoint_revision < context_revision):
            return None
        return checkpoint

    @staticmethod
    def _record_timestamp(value: dict[str, Any]) -> datetime | None:
        for key in ("updatedAt", "checkedAt", "timestamp", "createdAt"):
            parsed = _parse_dt(str(value.get(key, "")))
            if parsed is not None:
                return parsed
        return None

    @staticmethod
    def _record_revision(value: dict[str, Any]) -> int | None:
        for key in ("revision", "contractRevision"):
            try:
                revision = int(value.get(key))
            except (TypeError, ValueError):
                continue
            if revision >= 0:
                return revision
        return None

    def _task_candidates(
        self,
        query: str,
        terms: set[str],
        context: dict[str, Any] | None = None,
    ) -> list[Candidate]:
        if context is None:
            context = self._current_task_context()
        if context is None or str(context.get("_trust", "")) != "authoritative":
            return []
        checkpoint = self._current_task_checkpoint(context) or {}
        task_id = str(context.get("taskId", ""))
        task_name = str(checkpoint.get("taskName", context.get("taskName", "")))
        goal = str(checkpoint.get("goal", context.get("acceptedGoal", "")))
        current_step = str(checkpoint.get("currentStep", context.get("currentStep", "")))
        next_action = str(checkpoint.get("nextAction", context.get("nextAction", "")))
        authoritative = True
        verification_tag = "[VERIFIED]"
        text = (
            f"[TASK][CURRENT]{verification_tag}[SUMMARY] current task taskId={task_id} "
            f"taskName={task_name} goal={goal} currentStep={current_step} nextAction={next_action}"
        )
        return [
            Candidate(
                text=text,
                source=str(context.get("_source", "memory\\workspace\\current-task-context.json")),
                source_type="task",
                reason="current_task_identity_priority",
                timestamp=str(context.get("checkedAt", "")),
                source_priority=5,
                authoritative=True,
                verification_status="verified",
            )
        ]

    def _state_candidates(self, query: str, terms: set[str]) -> list[Candidate]:
        sources = [
            ("status", self.workspace / "status-card.json", "memory\\workspace\\status-card.json", 10),
            ("runtime", self.workspace / "super-brain-state.json", "memory\\workspace\\super-brain-state.json", 20),
            ("baseline", self.package_root / "CURRENT_BASELINE.md", "CURRENT_BASELINE.md", 30),
            ("manifest", self.package_root / "manifest.json", "manifest.json", 40),
            ("changelog", self.package_root / "CHANGELOG.md", "CHANGELOG.md", 50),
        ]
        candidates: list[Candidate] = []
        version_query = bool(
            "version" in terms
            or "version" in query.lower()
            or "\u7248\u672c" in query
        )
        status_query = bool(
            "status" in terms
            or "status" in query.lower()
            or "\u72b6\u6001" in query
        )
        manifest_version = str(self.manifest.get("version", ""))
        for kind, path, source, priority in sources:
            raw = _read_text(path)
            if not raw:
                continue
            text = raw
            authoritative = False
            verification_status = "unverified"
            if kind == "status":
                try:
                    status = json.loads(raw)
                except (UnicodeError, json.JSONDecodeError):
                    status = None
                if not isinstance(status, dict):
                    continue
                snapshot_version = str(status.get("version", ""))
                if not snapshot_version or snapshot_version != manifest_version:
                    continue
                safe_status = {
                    "version": snapshot_version,
                    "packageOk": status.get("packageOk"),
                    "verifyOk": status.get("verifyOk"),
                    "hotRefreshOk": status.get("hotRefreshOk"),
                    "risksCount": status.get("risksCount", 0),
                    "nextAction": status.get("nextAction", ""),
                }
                text = json.dumps(safe_status, ensure_ascii=False, separators=(",", ":"))
                authoritative = True
                verification_status = "verified"
                if status_query:
                    priority = 0
            elif kind == "runtime":
                try:
                    state = json.loads(raw)
                except (UnicodeError, json.JSONDecodeError):
                    state = None
                if not isinstance(state, dict):
                    continue
                state_version = str(state.get("version", ""))
                if not state_version or state_version != manifest_version:
                    continue
                text = json.dumps(
                    {
                        "version": state_version,
                        "ok": state.get("ok"),
                        "coreAvailable": state.get("coreAvailable", state.get("ok")),
                        "verification": state.get("verification"),
                        "hookOk": state.get("hookOk"),
                        "lastVerifyOk": state.get("lastVerifyOk"),
                        "updatedAt": state.get("updatedAt", ""),
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                authoritative = True
                verification_status = "verified"
                if status_query:
                    priority = 1
            elif kind == "manifest":
                if not version_query:
                    continue
                priority = 3 if status_query else 1
                text = json.dumps({"version": manifest_version}, ensure_ascii=False, separators=(",", ":"))
                authoritative = True
                verification_status = "verified"
            elif kind == "baseline":
                if not version_query:
                    continue
                priority = 4 if status_query else 2
            elif kind == "changelog":
                if not version_query:
                    continue
            lowered = text.lower()
            indexes = [lowered.find(term.lower()) for term in terms if term and lowered.find(term.lower()) >= 0]
            index = min(indexes) if indexes else 0
            start = max(0, index - 220)
            snippet = text[start : start + 600].strip()
            # A package/state file can be atomically replaced between the
            # bounded read above and this metadata lookup.  Keep recall
            # fail-closed for that candidate instead of leaking an OSError
            # through the whole state query.
            try:
                timestamp = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
            except (OSError, OverflowError, ValueError):
                continue
            tags = "[PROJECT][CURRENT][VERIFIED][SUMMARY]" if authoritative else "[PROJECT][HISTORICAL][UNVERIFIED][SUMMARY]"
            value = f"{tags} subject=super-memory-brain {source} timestamp={timestamp} {snippet}"
            candidates.append(
                Candidate(
                    text=value,
                    source=source,
                    source_type="state",
                    reason="state_recall_priority",
                    timestamp=timestamp,
                    source_priority=priority,
                    authoritative=authoritative,
                    verification_status=verification_status,
                )
            )
        return candidates

    @staticmethod
    def _append_sandglass_rows(
        values: list[Candidate],
        seen: set[int],
        rows: Iterable[Any],
        reason: str,
    ) -> None:
        for item in rows or []:
            if len(item) < 3:
                continue
            try:
                line_number = int(item[0])
            except (TypeError, ValueError):
                continue
            if line_number in seen:
                continue
            seen.add(line_number)
            if len(item) >= 4:
                timestamp = str(item[1])
                sender, provenance = _parse_sender(str(item[2]))
                text = str(item[3])
            else:
                timestamp = str(item[1])
                sender = ""
                provenance = {}
                text = str(item[2])
            values.append(
                Candidate(
                    text=text,
                    source=f"{line_number}:{timestamp}",
                    source_type="sandglass",
                    reason=reason,
                    timestamp=timestamp,
                    sender=sender,
                    session_key=provenance.get("sessionKey", ""),
                    task_key=provenance.get("taskKey", ""),
                    workspace_key=provenance.get("workspaceKey", ""),
                )
            )

    @staticmethod
    def _fts_tokens(query: str) -> str:
        tokens = set(re.findall(r"[a-zA-Z0-9_]{2,}", query.lower()))
        chars = "".join(re.findall(r"[\u4e00-\u9fff]", query))
        tokens.update(chars[index : index + 2] for index in range(max(0, len(chars) - 1)))
        return " ".join(sorted(token for token in tokens if token))

    @classmethod
    def _fts_match_query(cls, query: str) -> str:
        """Build one safe FTS expression without opening the database."""

        tokens = cls._fts_tokens(query)
        if not tokens:
            return ""
        if any(character.isascii() and character.isalpha() for character in query):
            return " OR ".join(tokens.split())
        return tokens

    @staticmethod
    def _fts_rows_from_connection(
        connection: sqlite3.Connection,
        match_query: str,
        limit: int,
    ) -> list[tuple[int, str, str, str]]:
        statement = (
            "SELECT s.id, s.ts, s.sender, s.text "
            "FROM sandglass_fts f JOIN sandglass s ON s.id=f.rowid "
            "WHERE sandglass_fts MATCH ? ORDER BY rank LIMIT ?"
        )
        rows = connection.execute(statement, (match_query, limit)).fetchall()
        return [(int(row[0]), str(row[1]), str(row[2]), str(row[3])) for row in rows]

    def _read_only_fts_rows_batch(
        self,
        queries: Iterable[str],
        limit: int,
    ) -> list[list[tuple[int, str, str, str]]]:
        """Read multiple recall variants through one immutable SQLite handle.

        A normal semantic recall can construct several equivalent query
        variants.  They all target the same immutable snapshot, so opening a
        separate connection for each is pure overhead.  This helper is scoped
        to one call and closes the handle before returning; it neither caches
        result rows nor weakens the existing read-only behavior.
        """

        source_queries = list(queries)
        results: list[list[tuple[int, str, str, str]]] = [[] for _ in source_queries]
        if not source_queries:
            return results
        db_path = self.memory_root / "sandglass.db"
        if not db_path.is_file():
            return results
        match_queries = [self._fts_match_query(query) for query in source_queries]
        if not any(match_queries):
            return results

        def retry_variants_individually() -> list[list[tuple[int, str, str, str]]]:
            # The old implementation opened one connection per variant. Keep
            # that behavior as a failure-only fallback so a transient first
            # connection error does not suppress later valid variants, while
            # the healthy path still pays for one immutable handle.
            for index, match_query in enumerate(match_queries):
                if not match_query:
                    continue
                retry_connection: sqlite3.Connection | None = None
                try:
                    retry_connection = sqlite3.connect(
                        db_path.resolve().as_uri() + "?mode=ro&immutable=1",
                        uri=True,
                    )
                    retry_connection.execute("PRAGMA query_only=ON")
                    results[index] = self._fts_rows_from_connection(
                        retry_connection,
                        match_query,
                        limit,
                    )
                except (OSError, sqlite3.Error, ValueError):
                    continue
                finally:
                    if retry_connection is not None:
                        retry_connection.close()
            return results

        connection: sqlite3.Connection | None = None
        batch_ready = False
        retry_after_close = False
        try:
            connection = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
            connection.execute("PRAGMA query_only=ON")
            batch_ready = True
            rows_by_match: dict[str, list[tuple[int, str, str, str]]] = {}
            for index, match_query in enumerate(match_queries):
                if not match_query:
                    continue
                rows = rows_by_match.get(match_query)
                if rows is not None:
                    # Query variants that compile to the same FTS expression
                    # are exactly equivalent against this immutable snapshot.
                    results[index] = rows
                    continue
                try:
                    rows = self._fts_rows_from_connection(connection, match_query, limit)
                except (sqlite3.Error, ValueError):
                    # Preserve the former per-variant fail-closed behavior:
                    # one malformed/unavailable FTS lookup must not suppress
                    # independently valid variants in the same recall.
                    continue
                rows_by_match[match_query] = rows
                results[index] = rows
        except (OSError, sqlite3.Error, ValueError):
            retry_after_close = not batch_ready
        finally:
            if connection is not None:
                connection.close()
        if retry_after_close:
            return retry_variants_individually()
        return results

    def _read_only_fts_rows(self, query: str, limit: int) -> list[tuple[int, str, str, str]]:
        """Read one FTS variant through the same bounded batch implementation."""

        return self._read_only_fts_rows_batch((query,), limit)[0]

    def _scan_sandglass_candidates(
        self,
        query_terms: set[str],
        anchors: set[str],
        temporal_target: tuple[datetime, int] | None,
        seen: set[int],
        scan_limit: int,
    ) -> list[Candidate]:
        scan_terms = anchors or query_terms
        path = self.memory_root / "sandglass.txt"
        if not scan_terms or not path.is_file():
            return []
        values: list[Candidate] = []
        recall_cache = _RECALL_SANDGLASS_CACHE.get()
        cached_lines: dict[int, str] | None = None
        cached_records: dict[int, SandglassRecord | None] | None = None
        cached_stamp: tuple[int, int] | None = None
        if isinstance(recall_cache, dict):
            try:
                stat = path.stat()
                cached_stamp = (stat.st_mtime_ns, stat.st_size)
                cached_lines = {}
                cached_records = {}
                recall_cache["sandglass"] = {
                    "path": path,
                    "stamp": cached_stamp,
                    "lines": cached_lines,
                    "records": cached_records,
                    "scanComplete": False,
                }
            except OSError:
                recall_cache.pop("sandglass", None)
        scan_complete = False
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for line_number, line in enumerate(handle, 1):
                    if line_number > scan_limit:
                        break
                    if cached_lines is not None:
                        # Keep raw lines, including malformed/empty records, so
                        # the recent-tail projection preserves its historical
                        # physical-line semantics when it reuses this prefix.
                        cached_lines[line_number] = line
                    record = _parse_sandglass_record_details(line)
                    if cached_records is not None:
                        cached_records[line_number] = record
                    if line_number in seen:
                        continue
                    if record is None:
                        continue
                    timestamp, text = record.timestamp, record.text
                    # Date parsing is only relevant for a temporal query.
                    # Avoid a regex pass for every scanned record on the
                    # ordinary lexical fallback path.
                    session_date = self._session_date(line) if temporal_target is not None else None
                    query_hit = any(_contains_term(text, term) for term in scan_terms)
                    temporal_hit = (
                        temporal_target is not None
                        and session_date is not None
                        and abs((session_date.date() - temporal_target[0].date()).days) <= temporal_target[1]
                    )
                    if not query_hit and not temporal_hit:
                        continue
                    values.append(
                        Candidate(
                            text=text,
                            source=f"{line_number}:{timestamp}",
                            source_type="sandglass",
                            reason="sandglass_anchor_scan",
                            timestamp=timestamp,
                            sender=record.sender,
                            session_key=record.session_key,
                            task_key=record.task_key,
                            workspace_key=record.workspace_key,
                        )
                    )
                    seen.add(line_number)
                else:
                    scan_complete = True
        except (OSError, UnicodeError):
            if isinstance(recall_cache, dict):
                recall_cache.pop("sandglass", None)
            return []
        if isinstance(recall_cache, dict) and cached_lines is not None and cached_stamp is not None:
            entry = recall_cache.get("sandglass")
            if isinstance(entry, dict):
                entry["scanComplete"] = scan_complete
        return values

    def _sandglass_candidates(self, query: str, top_k: int, query_date: str = "") -> list[Candidate]:
        dynamic = self.retrieval.get("dynamic", {})
        multiplier = int(dynamic.get("candidateMultiplier", 16)) if isinstance(dynamic, dict) else 16
        minimum = int(dynamic.get("minCandidatePool", 64)) if isinstance(dynamic, dict) else 64
        maximum = int(dynamic.get("maxCandidatePool", 180)) if isinstance(dynamic, dict) else 180
        limit = min(max(top_k * multiplier, minimum), maximum)
        seen: set[int] = set()
        values: list[Candidate] = []
        search_queries = self._search_queries(query)
        adaptive = dynamic.get("adaptiveSparse", {}) if isinstance(dynamic, dict) else {}
        adaptive = adaptive if isinstance(adaptive, dict) else {}
        adaptive_enabled = bool(adaptive.get("enabled", True))
        fallback_count = self._bounded_int(
            adaptive.get("fallbackCandidateCount"),
            max(top_k * 2, 6),
            1,
            limit,
        )

        if adaptive_enabled and search_queries:
            fts_rows = self._read_only_fts_rows_batch(search_queries, limit)
            for index, rows in enumerate(fts_rows):
                self._append_sandglass_rows(
                    values,
                    seen,
                    rows,
                    "sandglass_fts5_readonly" if index == 0 else "sandglass_fts5_variant",
                )

        # The retrieval path never rebuilds derived indexes. Accepted memory
        # writes refresh FTS; this bounded scan preserves recall during a stale
        # or unavailable derived-index window.
        scan_enabled = bool(dynamic.get("fullScanFallback", True)) if isinstance(dynamic, dict) else True
        query_terms = self._query_terms(query)
        anchors = self._query_anchors(query, query_terms)
        temporal_target = self._temporal_target_date(query, query_date)
        scan_limit = int(dynamic.get("fullScanMaxLines", 2000)) if isinstance(dynamic, dict) else 2000
        has_anchor_candidate = any(
            any(_contains_term(candidate.text, anchor) for anchor in anchors)
            for candidate in values
        )
        if scan_enabled and (anchors or query_terms or temporal_target is not None) and (
            temporal_target is not None or len(values) < fallback_count or not has_anchor_candidate
        ):
            values.extend(
                self._scan_sandglass_candidates(query_terms, anchors, temporal_target, seen, scan_limit)
            )
        return values

    @staticmethod
    def _cached_json_dict(path: Path, cache: dict[str, Any]) -> dict[str, Any] | None:
        """Read one JSON object with a stamp-aware, fail-closed cache."""

        try:
            absolute_path = path.expanduser().resolve()
        except RuntimeError:
            # A symlink loop or otherwise unresolvable path cannot be an
            # authority.  The cache key may not be canonical in this branch,
            # so evict the caller-visible spelling as a best effort.
            cache.pop(str(path.expanduser()), None)
            return None

        key = str(absolute_path)
        try:
            stat = absolute_path.stat()
        except OSError:
            # Missing/unreadable inputs cannot remain an authority.
            # Evict the canonical key (the normal cache key).  Previously this
            # used the unresolved spelling and could leave a stale entry after
            # deletion, causing unnecessary memory growth and risking reuse if
            # a path was later recreated with the same stamp.
            cache.pop(key, None)
            return None

        stamp = (stat.st_mtime_ns, stat.st_size)
        cached = cache.get(key)
        if (
            isinstance(cached, dict)
            and cached.get("stamp") == stamp
            and isinstance(cached.get("value"), dict)
        ):
            return cached["value"]

        item = _read_json(absolute_path)
        if not isinstance(item, dict):
            # Do not cache missing, malformed, or non-object JSON.  In
            # particular, a repaired file must be reread on the next call.
            cache.pop(key, None)
            return None
        cache[key] = {"stamp": stamp, "value": item}
        return item

    def _self_model_candidates(self, query: str) -> list[Candidate]:
        policy = self.policy.get("selfModel", {})
        policy = policy if isinstance(policy, dict) else {}
        try:
            max_age_hours = max(1, int(policy.get("maxAgeHours", 24)))
        except (TypeError, ValueError):
            max_age_hours = 24

        item = self._cached_json_dict(self.workspace / "self-model.json", self._self_model_json_cache)
        snapshot_status = "missing"
        verification_status = "unknown"
        valid_snapshot = False
        if isinstance(item, dict):
            updated_at = _parse_dt(str(item.get("updatedAt", "")))
            age_seconds = (
                (datetime.now() - updated_at).total_seconds()
                if updated_at is not None
                else float("inf")
            )
            schema_ok = item.get("schema") == "super-brain.self-model.v1"
            version_ok = str(item.get("packageVersion", "")) == str(self.manifest.get("version", ""))
            evidence = item.get("evidence", [])
            evidence_ok = isinstance(evidence, list) and any(str(value).strip() for value in evidence)
            privacy_ok = item.get("rawPromptStored") is False
            declared_status = str(item.get("evidenceStatus", "")).lower()
            fresh = -300.0 <= age_seconds <= max_age_hours * 3600
            if schema_ok and version_ok and evidence_ok and privacy_ok and fresh and declared_status in {"verified", "degraded"}:
                valid_snapshot = True
                snapshot_status = declared_status
                verification_status = declared_status
            elif schema_ok and privacy_ok and declared_status:
                snapshot_status = "stale" if not fresh else "invalid"
            else:
                snapshot_status = "invalid"

        if valid_snapshot:
            identity = item.get("identity", "Super Memory Brain / G1 local control plane")
            role = item.get("role", "")
            capabilities = ", ".join(map(str, item.get("verifiedCapabilities", []) or []))
            state = item.get("currentState", "")
            user_model = item.get("userModel", "")
            limits = ", ".join(map(str, item.get("knownLimits", []) or []))
            next_action = item.get("nextAction", "")
            tags = "[SELF_MODEL][CURRENT][SUMMARY]"
            if verification_status == "verified":
                tags += "[VERIFIED]"
            else:
                tags += "[KNOWN_LIMITATION]"
            text = (
                f"{tags} snapshotStatus={snapshot_status} "
                f"identity={_compact(str(identity), 180)} role={_compact(str(role), 240)} "
                f"capabilities={_compact(capabilities or 'No verified capability claim.', 360)} "
                f"currentState={_compact(str(state), 360)} userModel={_compact(str(user_model), 280)} "
                f"limits={_compact(limits, 260)} nextAction={_compact(str(next_action), 220)}"
            )
        else:
            identity = "Super Memory Brain / G1 local control plane"
            role = "bounded local control plane; current claims require live evidence"
            text = (
                "[SELF_MODEL][SUMMARY][KNOWN_LIMITATION] "
                f"snapshotStatus={snapshot_status} identity={identity} role={role} "
                "capabilities=No verified capability snapshot. "
                "currentState=No evidence-backed self-model snapshot exists; current state is unknown. "
                "userModel=No governed user-model snapshot is available. "
                "limits=Memory is evidence, not authority; stale or missing evidence must remain unknown; "
                "unknown personal facts must remain unknown. "
                "nextAction=Refresh after a verified task outcome or safe maintenance."
            )
        return [
            Candidate(
                text=text,
                source="memory\\workspace\\self-model.json",
                source_type="self_model",
                reason="self_model_snapshot" if valid_snapshot else f"self_model_snapshot_{snapshot_status}",
                timestamp=str(item.get("updatedAt", "")) if valid_snapshot else "",
                source_priority=2,
                authoritative=True,
                snapshot_status=snapshot_status,
                verification_status=verification_status,
            )
        ]

    @staticmethod
    def _session_messages(text: str) -> tuple[str, list[tuple[str, str]]]:
        marker = "session_content="
        marker_index = text.find(marker)
        if marker_index < 0:
            return "", []
        header = text[:marker_index].strip() or "[SESSION]"
        payload = text[marker_index + len(marker) :].strip()
        try:
            parsed = json.loads(payload)
        except (TypeError, json.JSONDecodeError):
            return header, []
        if isinstance(parsed, dict):
            parsed = parsed.get("messages", [])
        if not isinstance(parsed, list):
            return header, []
        messages: list[tuple[str, str]] = []
        for item in parsed:
            if not isinstance(item, dict):
                continue
            role = str(item.get("role", "message")).strip() or "message"
            content = item.get("content", "")
            if isinstance(content, (dict, list)):
                content = json.dumps(content, ensure_ascii=False, separators=(",", ":"))
            content = str(content).strip()
            if content:
                messages.append((role, content))
        return header, messages

    def _candidate_snippet(self, text: str, query: str, terms: set[str], max_chars: int) -> str:
        """Return a bounded, query-centered evidence window instead of a raw prefix."""
        header, messages = self._session_messages(text)
        anchors = self._query_anchors(query, terms)
        focus_terms = [query, *sorted(anchors, key=lambda value: (-len(value), value)), *sorted(terms)]
        if not messages:
            if "[SESSION]" in text and ("session_content=" in text or "[BENCHMARK]" in text):
                return _compact_around(text, focus_terms, max_chars)
            return _compact(text, max_chars)

        ranked: list[tuple[tuple[int, int, int], int]] = []
        lowered_query = query.lower()
        quantity_query = any(
            marker in lowered_query
            for marker in ("how many", "how much", "number of", "count", "多少", "几")
        )
        personal_query = bool(re.search(r"\b(?:i|my|me|have i|did i|do i)\b", lowered_query))
        assistant_attribution_query = any(
            marker in lowered_query
            for marker in ("you said", "you told", "you recommended", "what did you", "did you say")
        )
        fact_signal_query = quantity_query or (personal_query and not assistant_attribution_query)
        for index, (role, content) in enumerate(messages):
            lowered = content.lower()
            matched = [term for term in terms if _contains_term(content, term)]
            matched_anchors = [term for term in anchors if _contains_term(content, term)]
            exact = bool(query.strip()) and query.lower() in lowered
            if not matched and not exact:
                continue
            anchor_occurrences = sum(lowered.count(term.lower()) for term in matched_anchors)
            numeric_matches = list(re.finditer(r"\b\d+(?:[.,]\d+)?\b", lowered))
            numeric_matches.extend(
                re.finditer(r"\b(?:" + "|".join(sorted(NUMBER_WORDS, key=len, reverse=True)) + r")\b", lowered)
            )
            near_numeric = 0
            for anchor in matched_anchors:
                anchor_position = lowered.find(anchor.lower())
                if anchor_position < 0:
                    continue
                if any(abs(match.start() - anchor_position) <= 120 for match in numeric_matches):
                    near_numeric += 1
            personal_signal = int(
                personal_query
                and not assistant_attribution_query
                and role.lower() == "user"
                and any(
                    marker in lowered
                    for marker in (
                        "i have",
                        "i've",
                        "i own",
                        "i just",
                        "i recently",
                        "i bought",
                        "i got",
                        "i visited",
                        "i planted",
                        "i joined",
                        "my ",
                    )
                )
            )
            list_penalty = 0
            if quantity_query and role.lower() == "assistant" and not personal_signal:
                list_penalty = min(12, max(0, len(numeric_matches) - 4) * 2)
            score = (
                (20 if exact else 0)
                + len(matched_anchors) * 5
                + min(8, anchor_occurrences * 2)
                + len(matched)
                + (8 * near_numeric if fact_signal_query else 0)
                + (3 * min(1, len(numeric_matches)) if fact_signal_query else 0)
                + (15 * personal_signal if personal_query else 0)
                - list_penalty
            )
            role_priority = 2 if personal_query and role.lower() == "user" else (1 if role.lower() in {"user", "assistant"} else 0)
            ranked.append(((score, near_numeric, anchor_occurrences, role_priority, index), index))
        if not ranked:
            return _compact_around(text, focus_terms, max_chars)

        ranked.sort(reverse=True)
        best_index = ranked[0][1]
        body_budget = max(80, max_chars - min(len(header), max_chars // 3) - 1)
        best_role, best_content = messages[best_index]
        best_fragment = _compact_around(best_content, focus_terms, body_budget)
        parts = [f"{best_role}: {best_fragment}"]

        # A neighboring turn often contains the answer to the matched user turn.
        neighbor_index = best_index + 1 if best_index + 1 < len(messages) else best_index - 1
        if neighbor_index >= 0 and neighbor_index < len(messages) and len(best_fragment) < body_budget * 0.72:
            neighbor_role, neighbor_content = messages[neighbor_index]
            remaining = max(72, body_budget - len(best_fragment) - 3)
            neighbor_fragment = _compact_around(neighbor_content, focus_terms, remaining)
            parts.append(f"{neighbor_role}: {neighbor_fragment}")

        prefix = _compact(header, max(40, max_chars // 3))
        result = f"{prefix} {' | '.join(parts)}"
        if len(result) <= max_chars:
            return result
        return _compact_around(result, focus_terms, max_chars)

    @staticmethod
    def _graph_node(value: str) -> str:
        return re.sub(r"\s+", " ", value.strip().lower())

    @staticmethod
    def _graph_text(edge: GraphEdge) -> str:
        tags = edge.tags.lower()
        markers = []
        if "current" in tags:
            markers.append("[CURRENT]")
        if "verified" in tags:
            markers.append("[VERIFIED]")
        if "summary" in tags:
            markers.append("[SUMMARY]")
        prefix = "".join(markers)
        return (
            f"{prefix} subject={edge.subject} relation={edge.relation} "
            f"object={edge.object} evidence={edge.evidence} tags={edge.tags}"
        ).strip()

    @staticmethod
    def _graph_identity(edge: GraphEdge) -> str:
        subject = BrainCore._graph_node(edge.subject)
        relation = BrainCore._graph_node(edge.relation)
        if subject.startswith("decision:"):
            return subject
        return f"graph:{subject}|{relation}"

    def _graph_rows(self) -> list[GraphEdge]:
        path = self.memory_base / "graph.jsonl"
        try:
            stat = path.stat()
            key = (stat.st_mtime_ns, stat.st_size)
        except OSError:
            return []
        if key == self._graph_cache_key:
            return self._graph_cache
        rows: list[GraphEdge] = []
        try:
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if not line.strip():
                    continue
                try:
                    node = json.loads(line.lstrip("\ufeff"))
                except json.JSONDecodeError:
                    continue
                relation = str(node.get("relation", ""))
                priority = {"decides": 0, "has_title": 10, "has_context": 20, "has_consequence": 30, "affects": 40}.get(relation, 45)
                rows.append(
                    GraphEdge(
                        subject=str(node.get("subject", "")).strip(),
                        relation=relation.strip(),
                        object=str(node.get("object", "")).strip(),
                        evidence=str(node.get("evidence", "")).strip(),
                        tags=str(node.get("tags", "")).strip(),
                        source=f"memory\\graph.jsonl:{number}",
                        relation_priority=priority,
                    )
                )
        except (OSError, UnicodeError):
            rows = []
        self._graph_cache_key = key
        self._graph_cache = rows
        return rows

    def _graph_candidates(self, terms: set[str]) -> list[Candidate]:
        edges = self._graph_rows()
        values: list[Candidate] = []
        seeded: list[GraphEdge] = []
        required = max(1, min(2, self._required_matches(len(terms))))
        for edge in edges:
            subject_matches = [term for term in terms if _contains_term(edge.subject, term)]
            if not subject_matches:
                continue
            text = self._graph_text(edge)
            matched = [term for term in terms if _contains_term(text, term)]
            if len(matched) < required:
                continue
            seeded.append(edge)
            values.append(
                Candidate(
                    text=text,
                    source=edge.source,
                    source_type="graph",
                    reason="graph_evidence_seed",
                    relation_priority=edge.relation_priority,
                    identity_key=self._graph_identity(edge),
                    claim_value=self._graph_node(edge.object),
                )
            )

        # Expand exactly one edge from evidence already matched to the query.
        # This is bounded graph reasoning, not a second broad keyword search.
        connected_nodes = {
            self._graph_node(edge.object)
            for edge in seeded
            if edge.object.strip()
        }
        seeded_sources = {edge.source for edge in seeded}
        max_expansions = min(8, max(2, len(seeded) * 2))
        expansions = 0
        for edge in edges:
            if expansions >= max_expansions:
                break
            if edge.source in seeded_sources:
                continue
            tags = f"{edge.tags} {edge.evidence}".lower()
            if any(marker in tags for marker in ("stale", "superseded", "rejected", "negative_feedback")):
                continue
            subject = self._graph_node(edge.subject)
            object_value = self._graph_node(edge.object)
            if subject not in connected_nodes:
                continue
            values.append(
                Candidate(
                    text=self._graph_text(edge),
                    source=edge.source,
                    source_type="graph",
                    reason="graph_evidence_expansion",
                    relation_priority=edge.relation_priority + 8,
                    identity_key=self._graph_identity(edge),
                    claim_value=object_value,
                    graph_expansion=True,
                )
            )
            expansions += 1
        return values

    def _experience_candidates(self, query: str, terms: set[str]) -> list[Candidate]:
        values: list[Candidate] = []
        root = self.workspace / "experiences"
        if not root.exists():
            # The cache is process-local and keyed by canonical path.  Remove
            # entries whose source family disappeared so repeated workspace
            # repairs do not grow the cache without bound.
            self._experience_json_cache.clear()
            return values
        paths = list(root.glob("*.json"))
        active_keys: set[str] = set()
        for path in paths:
            try:
                active_keys.add(str(path.expanduser().resolve()))
            except RuntimeError:
                continue
        for key in tuple(self._experience_json_cache):
            if key not in active_keys:
                self._experience_json_cache.pop(key, None)

        for path in paths:
            item = self._cached_json_dict(path, self._experience_json_cache)
            if not isinstance(item, dict):
                continue
            searchable = " ".join(
                [
                    str(item.get("id", "")),
                    str(item.get("title", "")),
                    str(item.get("status", "")),
                    str(item.get("scope", "")),
                    " ".join(map(str, item.get("triggers", []) or [])),
                    " ".join(map(str, item.get("symptoms", []) or [])),
                    str(item.get("recallQuery", "")),
                ]
            )
            lowered = searchable.lower()
            matched = [term for term in terms if _contains_term(searchable, term)]
            if query.lower() not in lowered and len(matched) < max(1, min(2, self._required_matches(len(terms)))):
                continue
            text = (
                f"[PROJECT][CURRENT][VERIFIED][SUMMARY] experience {item.get('id', path.stem)} "
                f"title={item.get('title', '')} status={item.get('status', '')} "
                f"confidence={item.get('confidence', '')} recallQuery={item.get('recallQuery', '')} "
                f"updatedAt={item.get('updatedAt', '')} evidence={','.join(map(str, item.get('evidence', []) or []))}"
            )
            values.append(
                Candidate(
                    text=text,
                    source=f"memory\\workspace\\experiences\\{path.name}",
                    source_type="state",
                    reason="experience_index_recall",
                    timestamp=str(item.get("updatedAt", "")),
                )
            )
        return values

    def _profile_card_candidates(self, query: str, terms: set[str]) -> list[Candidate]:
        if not self._is_profile_query(query):
            return []
        item = self._cached_json_dict(
            self.workspace / "profile-card.json",
            self._profile_card_json_cache,
        )
        if not isinstance(item, dict):
            return []
        values: list[Candidate] = []
        for index, card in enumerate(item.get("evidenceCards", []) or []):
            if not isinstance(card, dict):
                continue
            text = str(card.get("claim", ""))
            if not text or _looks_corrupt(text):
                continue
            lowered = text.lower()
            matched = [term for term in terms if _contains_term(text, term)]
            if len(matched) < max(1, min(2, self._required_matches(len(terms)))):
                continue
            values.append(
                Candidate(
                    text=text,
                    source=f"memory\\workspace\\profile-card.json:{index + 1}",
                    source_type="persona",
                    reason="persona_recall_priority",
                    authoritative=True,
                )
            )
        return values

    @staticmethod
    def _required_matches(term_count: int) -> int:
        if term_count <= 0:
            return 0
        if term_count <= 2:
            return term_count
        return min(4, max(2, math.ceil(term_count * 0.35)))

    @staticmethod
    def _claim_identity(text: str) -> tuple[str, str]:
        value = TAG_RE.sub("", text)
        value = re.sub(r"(?i)\bsession_date=[^\s]+", "", value)
        match = re.search(
            r"(?i)\b([a-z][a-z0-9 _-]{2,80}?)\s+"
            r"(?:is|are|uses|use|was|were|equals|means|has)\s+"
            r"([^.;\n]{2,160})",
            value,
        )
        if not match:
            return "", ""
        subject = re.sub(r"\s+", " ", match.group(1)).strip().lower()
        answer = re.sub(r"\s+", " ", match.group(2)).strip().lower()
        if not subject or not answer:
            return "", ""
        return f"claim:{subject}", answer

    @staticmethod
    def _is_assistant_attribution_query(query: str) -> bool:
        lowered = query.lower()
        return any(
            marker in lowered
            for marker in ("you said", "you told", "you recommended", "what did you", "did you say")
        ) or any(marker in query for marker in ("\u4f60\u8bf4\u8fc7", "\u4f60\u5efa\u8bae\u8fc7", "\u4f60\u4e4b\u524d\u8bf4"))

    @staticmethod
    def _scope_hash(value: str) -> str:
        return hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]

    @staticmethod
    def _is_cross_session_query(query: str) -> bool:
        lowered = query.lower()
        return any(
            marker in lowered
            for marker in ("another session", "previous session", "last session", "other session")
        ) or any(marker in query for marker in ("\u53e6\u4e00\u4e2a\u4f1a\u8bdd", "\u4e0a\u4e2a\u4f1a\u8bdd", "\u4e4b\u524d\u4f1a\u8bdd"))

    def _session_scope_allowed(self, candidate: Candidate, query: str, layer: str) -> bool:
        # The request's ``layer=all`` is not permission to merge a
        # session-scoped record into another cwd/session scope. Scope the
        # candidate by its own declared layer instead.
        if _layer(candidate.text) != "session" or not candidate.session_key:
            return True
        current_workspace = self._context_workspace_key()
        # Session provenance is subordinate to the current local workspace.
        # Keep legacy records without a workspace marker readable for backward
        # compatibility, but never admit an explicitly foreign workspace.
        if candidate.workspace_key:
            # A scoped record cannot become cross-workspace evidence merely
            # because the caller's cwd is currently unavailable.  Keep only
            # genuinely legacy records (without a workspace marker) readable
            # in that degraded local-state condition.
            if not current_workspace:
                return False
            if candidate.workspace_key.lower() not in self._workspace_provenance_keys(current_workspace):
                return False
        # A session-scoped record is never readable without a current local
        # session identity.  In particular, an explicit "previous session"
        # query must not turn a missing identity into a wildcard over every
        # session in the shared sandglass.
        current = self._context_session_key()
        if not current:
            return False
        if self._is_cross_session_query(query):
            return True
        # Sandglass writers have used both the legacy 16-hex hash and the
        # current ``sid-<24-hex>`` provenance form. Reuse the same bounded
        # compatibility set as ``recent()`` instead of rejecting a valid
        # current-session record merely because its writer format changed.
        return candidate.session_key.lower() in self._session_provenance_keys(current)

    @staticmethod
    def _is_unverified_current_task_memory(candidate: Candidate) -> bool:
        tags = set(_tags(candidate.text))
        return "[TASK]" in tags and "[CURRENT]" in tags and "[VERIFIED]" not in tags

    @staticmethod
    def _resolve_conflicting_candidates(candidates: list[Candidate]) -> list[Candidate]:
        groups: dict[str, list[Candidate]] = {}
        for candidate in candidates:
            if candidate.identity_key:
                groups.setdefault(candidate.identity_key, []).append(candidate)

        rejected_ids: set[int] = set()
        for group in groups.values():
            values = {
                candidate.claim_value
                or re.sub(r"\s+", " ", TAG_RE.sub("", candidate.text)).strip().lower()
                for candidate in group
            }
            if len(values) <= 1:
                continue

            # A graph decision is represented as several structured facets
            # (decides, title, consequence, owner, ...). Those facets are not
            # competing answers. Prefer its single current `decides` edge;
            # two different current `decides` edges remain an abstention.
            decision_edges = [
                candidate
                for candidate in group
                if (
                    candidate.source_type == "graph"
                    and candidate.identity_key.startswith("decision:")
                    and candidate.relation_priority == 0
                    and not candidate.graph_expansion
                )
            ]
            if decision_edges:
                current_decisions = [
                    candidate for candidate in decision_edges if "[CURRENT]" in candidate.text
                ]
                if len(current_decisions) == 1:
                    winner = current_decisions[0]
                    rejected_ids.update(id(candidate) for candidate in group if candidate is not winner)
                    continue
                if len(current_decisions) > 1:
                    decision_values = {
                        candidate.claim_value
                        or re.sub(r"\s+", " ", TAG_RE.sub("", candidate.text)).strip().lower()
                        for candidate in current_decisions
                    }
                    if len(decision_values) == 1:
                        winner = current_decisions[0]
                        rejected_ids.update(id(candidate) for candidate in group if candidate is not winner)
                        continue
                    rejected_ids.update(id(candidate) for candidate in group)
                    continue

            temporal = [candidate for candidate in group if candidate.temporal_match]
            if len(temporal) == 1:
                rejected_ids.update(id(candidate) for candidate in group if candidate is not temporal[0])
                continue
            if len(temporal) > 1:
                rejected_ids.update(id(candidate) for candidate in group)
                continue
            current = [candidate for candidate in group if "[CURRENT]" in candidate.text]
            if len(current) == 1:
                rejected_ids.update(id(candidate) for candidate in group if candidate is not current[0])
            else:
                rejected_ids.update(id(candidate) for candidate in group)
        return [candidate for candidate in candidates if id(candidate) not in rejected_ids]

    def _score(
        self,
        candidate: Candidate,
        query: str,
        terms: set[str],
        profile_query: bool,
        document_frequency: dict[str, int] | None = None,
        corpus_size: int = 0,
        temporal_target: tuple[datetime, int] | None = None,
        *,
        anchors: set[str] | None = None,
        alias_terms: set[str] | None = None,
        identity_terms: set[str] | None = None,
        contains_term: Callable[[str, str], bool] | None = None,
    ) -> Candidate | None:
        text = candidate.text
        # Resolve the default at call time so ordinary callers preserve the
        # existing module-global lookup behavior (including focused test
        # instrumentation).  ``recall`` explicitly supplies its call-local
        # memoizer below.
        matcher = contains_term if contains_term is not None else _contains_term
        if not text or _looks_corrupt(text) or "[STALE]" in text:
            return None
        lowered = text.lower()
        candidate.rejected_record = any(
            tag in text
            for tag in ("[NEGATIVE_FEEDBACK]", "[REJECTED]", "[SUPERSEDED]")
        )
        historical_request = any(
            marker in query.lower()
            for marker in ("historical", "history", "previous", "rejected", "superseded")
        ) or any(marker in query for marker in ("\u5386\u53f2", "\u4ee5\u524d", "\u5df2\u62d2\u7edd", "\u88ab\u66ff\u4ee3"))
        if candidate.rejected_record and not historical_request:
            return None
        candidate.matched_terms = sorted(term for term in terms if matcher(text, term))
        anchors = anchors if anchors is not None else self._query_anchors(query, terms)
        candidate.anchor_matches = sorted(term for term in anchors if matcher(text, term))
        candidate.exact_match = bool(query.strip()) and query.lower() in lowered
        identity_match = re.search(
            r"(?i)\bdecision:([a-z0-9._-]+)|\b(?:decision_key|key)=([a-z0-9._-]+)",
            text,
        )
        if identity_match:
            candidate.identity_key = "decision:" + (identity_match.group(1) or identity_match.group(2)).lower()
        identity_body = candidate.identity_key.removeprefix("decision:") if candidate.identity_key else ""
        identity_parts = [part for part in identity_body.split("-") if len(part) >= 3]
        normalized_terms = {term.lower() for term in terms}
        explicit_identity = bool(
            identity_body
            and (
                identity_body in query.lower()
                or identity_body in normalized_terms
                or any(
                    "-".join(identity_parts[index : index + 2]) in query.lower()
                    or "-".join(identity_parts[index : index + 2]) in normalized_terms
                    for index in range(max(0, len(identity_parts) - 1))
                )
            )
        )
        candidate.canonical_match = bool(
            explicit_identity
            and identity_body in normalized_terms
        )
        candidate.canonical_explicit = bool(
            identity_body
            and (
                identity_body in query.lower()
                or any(
                    "-".join(identity_parts[index : index + 2]) in query.lower()
                    for index in range(max(0, len(identity_parts) - 1))
                )
            )
        )
        if not candidate.identity_key:
            candidate.identity_key, candidate.claim_value = self._claim_identity(text)
        elif not candidate.claim_value:
            candidate.claim_value = re.sub(r"\s+", " ", TAG_RE.sub("", text)).strip().lower()
        history_markers = ("previous", "prior", "former", "earlier", "before", "last")
        candidate.historical_claim = any(marker in query.lower() for marker in history_markers) and any(
            marker in lowered for marker in history_markers
        )
        candidate.historical_specific = candidate.historical_claim and bool(
            re.search(
                r"\b(?:previous|prior|former|earlier)\s+(?:role|job|occupation|profession|career|work)\b",
                lowered,
            )
        )
        candidate.temporal_match = False
        candidate.temporal_distance_days = 9999.0
        if temporal_target is not None:
            session_date = self._session_date(text)
            if session_date is not None:
                candidate.temporal_distance_days = abs((session_date.date() - temporal_target[0].date()).days)
                candidate.temporal_match = candidate.temporal_distance_days <= temporal_target[1]
        required = self._required_matches(len(terms))
        identity_terms = identity_terms if identity_terms is not None else self._query_identity_terms(query, terms)
        identity_anchor_match = any(term in candidate.anchor_matches for term in identity_terms)
        frequency_limit = max(1, math.ceil(max(corpus_size, 1) * 0.08))
        specific_terms = {
            term
            for term in anchors
            if term not in GENERIC_FACT_TERMS
            and (not document_frequency or int(document_frequency.get(term, 0)) <= frequency_limit)
        }
        specific_anchor_match = any(term in candidate.anchor_matches for term in specific_terms)
        alias_terms = alias_terms if alias_terms is not None else _meaningful_terms(" ".join(self._matched_aliases(query)))
        alias_match_count = sum(matcher(text, term) for term in alias_terms)
        alias_required = min(3, max(2, math.ceil(len(alias_terms) * 0.2))) if alias_terms else 0
        alias_supported = bool(alias_terms) and alias_match_count >= alias_required
        generic_only = bool(candidate.matched_terms) and not candidate.anchor_matches
        context_only_task = (
            candidate.source_type == "task"
            and candidate.verification_status == "unverified"
            and self._is_task_query(query)
        )
        temporal_evidence_match = candidate.temporal_match and (
            candidate.exact_match
            or candidate.canonical_match
            or bool(candidate.anchor_matches)
            or (not anchors and required > 0 and len(candidate.matched_terms) >= required)
        )
        relevant = (
            candidate.authoritative
            or context_only_task
            or candidate.exact_match
            or candidate.canonical_match
            or bool(candidate.anchor_matches)
            or temporal_evidence_match
            or candidate.graph_expansion
        )
        if not anchors:
            relevant = candidate.authoritative or candidate.exact_match or candidate.canonical_match or temporal_evidence_match or candidate.graph_expansion or (
                required > 0 and len(candidate.matched_terms) >= required
            )
        elif generic_only and candidate.source_type in {"sandglass", "recent"}:
            relevant = False
        if (
            anchors
            and (candidate.source_type != "recent" or candidate.reason == "recent_fallback")
            and not candidate.authoritative
            and not context_only_task
            and not candidate.exact_match
            and not candidate.canonical_match
            and not temporal_evidence_match
            and not candidate.graph_expansion
        ):
            relevant = relevant and (
                alias_supported
                or identity_anchor_match
                or (not alias_terms and specific_anchor_match)
                or (profile_query and "[PROFILE]" in text and len(candidate.matched_terms) >= max(1, min(required, 2)))
                or len(candidate.matched_terms) >= required
            )
        personal_fact_query = self._is_personal_fact_query(query)
        assistant_attribution_query = self._is_assistant_attribution_query(query)
        candidate.personal_claim = bool(re.search(r"\b(?:i|my|me)\b", query.lower())) and any(
            marker in lowered
            for marker in (
                "i just got",
                "i bought",
                "i purchased",
                "i have",
                "i've got",
                "i've used",
                "i was",
                "i worked",
                "my previous",
                "my role",
            )
        )
        personal_unknown_probe = personal_fact_query or any(
            marker in query.lower() for marker in ("我最喜欢", "我是否", "my favorite")
        )
        if personal_fact_query and "[PROFILE]" not in text:
            return None
        if personal_fact_query and candidate.sender == "assistant" and not assistant_attribution_query:
            return None
        if personal_unknown_probe and not candidate.exact_match:
            candidate_markers = self._personal_fact_candidate_markers(query)
            strong_profile_match = (
                "[PROFILE]" in text
                and "[VERIFIED]" in text
                and len(candidate.matched_terms) >= max(required, math.ceil(max(len(terms), 1) * 0.5))
            )
            if personal_fact_query and candidate_markers:
                strong_profile_match = strong_profile_match and any(marker in lowered for marker in candidate_markers)
            relevant = relevant and strong_profile_match
        if not relevant:
            return None

        weights = self.hybrid.get("sourceWeights", {}) if isinstance(self.hybrid.get("sourceWeights", {}), dict) else {}
        boosts = self.hybrid.get("boosts", {}) if isinstance(self.hybrid.get("boosts", {}), dict) else {}
        source_weight = float(weights.get(candidate.source_type, 0.4))
        if candidate.source_type == "self_model" and "self_model" not in weights:
            source_weight = 0.9
        score = source_weight
        if "[SUMMARY]" in text:
            score += float(boosts.get("summary", 0.12))
        if "[CURRENT]" in text:
            score += float(boosts.get("current", 0.10))
        if "[VERIFIED]" in text:
            score += float(boosts.get("verified", 0.08))
        if "[ADR]" in text:
            score += float(boosts.get("adr", 0.08))
        if "[DECISION]" in text:
            score += float(boosts.get("decision", 0.06))
        if "[PROFILE]" in text:
            score += float(boosts.get("profile", 0.08))
        if candidate.exact_match:
            score += float(boosts.get("exactQuery", 0.15))
        if candidate.canonical_match:
            score += float(boosts.get("canonicalMatch", 0.35))
        score += len(candidate.matched_terms) * float(boosts.get("termMatch", 0.04))
        score += min(0.30, len(candidate.anchor_matches) * 0.14)
        if candidate.temporal_match:
            temporal_boost = float(boosts.get("temporalMatch", 0.34))
            score += max(0.08, temporal_boost - min(0.18, candidate.temporal_distance_days * 0.04))
        if candidate.personal_claim:
            score += float(boosts.get("personalClaim", 0.12))
        if assistant_attribution_query:
            score += 0.10 if candidate.sender == "assistant" else -0.08 if candidate.sender == "user" else 0.0
        if candidate.historical_claim:
            score += float(boosts.get("historicalClaim", 0.16))
        if candidate.historical_specific:
            score += float(boosts.get("historicalSpecific", 0.35))
        if document_frequency and corpus_size:
            rarity = 0.0
            for term in candidate.anchor_matches:
                frequency = max(1, int(document_frequency.get(term, 1)))
                rarity += math.log((corpus_size + 1) / (frequency + 1))
            score += min(0.24, rarity / max(1, len(candidate.anchor_matches)) * 0.08)
        candidate.rank_score = round(max(0.0, score), 4)
        candidate.score = round(min(1.0, max(0.0, score)), 4)

        confidence = source_weight * 0.35
        if "[CURRENT]" in text:
            confidence += 0.08
        if "[VERIFIED]" in text:
            confidence += 0.08
        if "[SUMMARY]" in text:
            confidence += 0.04
        if "[DECISION]" in text or "[ADR]" in text:
            confidence += 0.05
        if "[PROFILE]" in text:
            confidence += 0.04
        if candidate.exact_match:
            confidence += 0.35
        if candidate.canonical_match:
            confidence += 0.12
        if candidate.matched_terms:
            confidence += min(0.30, len(candidate.matched_terms) * 0.10)
            confidence_required = 1 if candidate.source_type == "recent" else required
            confidence += 0.12 * min(1.0, len(candidate.matched_terms) / max(1, confidence_required))
        elif candidate.authoritative:
            confidence += 0.18
        if candidate.temporal_match:
            confidence += 0.14
        if candidate.personal_claim:
            confidence += 0.04
        if candidate.historical_claim:
            confidence += 0.04
        if candidate.historical_specific:
            confidence += 0.05
        candidate.confidence = round(min(0.98, max(0.0, confidence)), 4)

        return candidate

    def _recent_sandglass_rows(
        self,
        limit: int,
        *,
        session_keys: set[str] | None = None,
        workspace_keys: set[str] | None = None,
        include_legacy: bool = False,
    ) -> list[tuple[int, str, str, str, str, str, str]]:
        """Read a bounded recent tail, optionally restricted to provenance.

        The unscoped path intentionally keeps its historical behaviour for the
        ordinary CLI helper.  A scoped caller supplies the normalized session
        provenance keys and receives only records that carry a matching
        session marker; legacy unscoped lines are excluded unless explicitly
        opted in by an internal caller.  Filtering while scanning (rather than
        filtering only the last ``limit`` physical lines) is important when
        several conversations append to the same shared sandglass.
        """
        path = self.memory_root / "sandglass.txt"
        if not path.is_file():
            return []
        # ``None`` means that dimension is intentionally unscoped.  An empty
        # supplied set instead means its required local provenance could not
        # be derived, which must fail closed rather than widen to every
        # workspace/session in the shared tail.
        if (session_keys is not None and not session_keys) or (workspace_keys is not None and not workspace_keys):
            return []
        recall_cache = _RECALL_SANDGLASS_CACHE.get()
        cached_entry = recall_cache.get("sandglass") if isinstance(recall_cache, dict) else None
        cached_records = cached_entry.get("records") if isinstance(cached_entry, dict) else None

        def rows_from_tail(
            tail: deque[tuple[int, str]],
            record_cache: dict[int, SandglassRecord | None] | None = None,
        ) -> list[tuple[int, str, str, str, str, str, str]]:
            rows: list[tuple[int, str, str, str, str, str, str]] = []
            for line_number, line in tail:
                if isinstance(record_cache, dict) and line_number in record_cache:
                    record = record_cache[line_number]
                else:
                    record = _parse_sandglass_record_details(line)
                if record is None:
                    continue
                rows.append(
                    (
                        line_number,
                        record.timestamp,
                        record.sender,
                        record.text,
                        record.session_key,
                        record.task_key,
                        record.workspace_key,
                    )
                )
            return rows

        if isinstance(cached_entry, dict) and cached_entry.get("scanComplete") is True:
            cached_path = cached_entry.get("path")
            cached_stamp = cached_entry.get("stamp")
            cached_lines = cached_entry.get("lines")
            try:
                current_stat = path.stat()
                current_stamp = (current_stat.st_mtime_ns, current_stat.st_size)
            except OSError:
                current_stamp = None
            if (
                isinstance(cached_path, Path)
                and cached_path == path
                and isinstance(cached_stamp, tuple)
                and current_stamp == cached_stamp
                and isinstance(cached_lines, dict)
            ):
                # Replay physical lines, including malformed/empty records,
                # so deque(maxlen=limit) has exactly the same tail semantics as
                # a fresh file pass.  Scope filtering remains unchanged.
                tail = deque(maxlen=limit)
                # `_scan_sandglass_candidates` inserts physical lines in
                # ascending order; preserve that order directly instead of
                # sorting the bounded prefix on every fallback.
                for line_number, line in cached_lines.items():
                    if not isinstance(line_number, int) or not isinstance(line, str):
                        continue
                    if session_keys is not None:
                        if isinstance(cached_records, dict) and line_number in cached_records:
                            record = cached_records[line_number]
                        else:
                            record = _parse_sandglass_record_details(line)
                        if record is None:
                            continue
                        if record.session_key:
                            if record.session_key.lower() not in session_keys:
                                continue
                        elif not include_legacy:
                            continue
                        if workspace_keys and (
                            not record.workspace_key
                            or record.workspace_key.lower() not in workspace_keys
                        ):
                            # A scoped recent read requires both provenance
                            # dimensions.  Session-only legacy lines remain
                            # readable through the unscoped compatibility
                            # path, but must never enter a workspace-bound
                            # projection.
                            continue
                    tail.append((line_number, line))
                return rows_from_tail(tail, cached_records if isinstance(cached_records, dict) else None)

        tail: deque[tuple[int, str]] = deque(maxlen=limit)
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for line_number, line in enumerate(handle, 1):
                    if session_keys is not None:
                        record = _parse_sandglass_record_details(line)
                        if record is None:
                            continue
                        if record.session_key:
                            if record.session_key.lower() not in session_keys:
                                continue
                        elif not include_legacy:
                            continue
                        if workspace_keys and (
                            not record.workspace_key
                            or record.workspace_key.lower() not in workspace_keys
                        ):
                            continue
                    tail.append((line_number, line))
        except (OSError, UnicodeError):
            return []
        # A partial/invalid prior scan cannot supply authority for this fresh
        # pass. Parse the lines just read, even when their physical numbers
        # overlap stale entries in the request-local cache.
        return rows_from_tail(tail)

    def _recent_candidates(self, terms: set[str], limit: int) -> list[Candidate]:
        rows = self._recent_sandglass_rows(limit)
        return [
            Candidate(
                text=str(row[3]),
                source=f"{row[0]}:{row[1]}",
                source_type="recent",
                reason="recent_fallback",
                timestamp=str(row[1]),
                sender=str(row[2]),
                session_key=str(row[4]),
                task_key=str(row[5]),
                workspace_key=str(row[6]),
            )
            for row in rows or []
            if len(row) >= 7
        ]

    def recall(
        self,
        query: str,
        top_k: int = 3,
        max_tokens: int = DEFAULT_RECALL_MAX_TOKENS,
        layer: str = "all",
        query_date: str = "",
        _evaluation_top_k: int = 0,
    ) -> list[dict[str, Any]]:
        sandglass_cache: dict[str, Any] = {}
        token = _RECALL_SANDGLASS_CACHE.set(sandglass_cache)
        try:
            return self._recall_impl(
                query,
                top_k=top_k,
                max_tokens=max_tokens,
                layer=layer,
                query_date=query_date,
                _evaluation_top_k=_evaluation_top_k,
            )
        finally:
            _RECALL_SANDGLASS_CACHE.reset(token)

    def _recall_impl(
        self,
        query: str,
        top_k: int = 3,
        max_tokens: int = DEFAULT_RECALL_MAX_TOKENS,
        layer: str = "all",
        query_date: str = "",
        _evaluation_top_k: int = 0,
    ) -> list[dict[str, Any]]:
        query = query.strip()
        if not query or top_k <= 0 or max_tokens <= 0:
            return []
        try:
            evaluation_limit = int(_evaluation_top_k)
        except (TypeError, ValueError):
            evaluation_limit = 0
        evaluation_mode = evaluation_limit > 0
        if evaluation_mode:
            top_k = min(max(1, evaluation_limit), MAX_EVALUATION_RANK)
            max_tokens = min(max(32, int(max_tokens)), MAX_EVALUATION_TOKENS)
        else:
            top_k = min(max(1, int(top_k)), MAX_RECALL_TOP_K)
            max_tokens = min(max(32, int(max_tokens)), MAX_RECALL_TOKENS)
        if layer not in {"all", "profile", "project", "decision", "task", "session"}:
            raise ValueError(f"unsupported layer: {layer}")

        output_policy = self._retrieval_output_policy(top_k, max_tokens, evaluation_mode=evaluation_mode)
        effective_top_k = output_policy.max_results
        matched_aliases = self._matched_aliases(query)
        terms = self._query_terms(query, matched_aliases)
        temporal_target = self._temporal_target_date(query, query_date)
        profile_query = self._is_profile_query(query)
        state_query = self._is_state_query(query, terms)
        self_model_query = self._is_self_model_query(query)
        candidates: list[Candidate]
        forced_task_query = layer == "task"
        task_query = forced_task_query or self._is_task_query(query)
        task_context = self._current_task_context() if task_query else None
        task_context_is_authoritative = bool(
            task_context is not None
            and str(task_context.get("_trust", "")) == "authoritative"
        )
        if forced_task_query:
            candidates = (
                [
                    candidate
                    for candidate in self._task_candidates(query, terms, task_context)
                    if candidate.authoritative
                ]
                if task_context_is_authoritative
                else []
            )
        elif self_model_query:
            candidates = self._self_model_candidates(query)
        elif task_query:
            candidates = (
                self._task_candidates(query, terms, task_context)
                if task_context_is_authoritative
                else []
            )
        elif state_query:
            candidates = self._state_candidates(query, terms)
        else:
            candidates = self._sandglass_candidates(query, effective_top_k, query_date)
            candidates.extend(self._graph_candidates(terms))
            candidates.extend(self._experience_candidates(query, terms))
            candidates.extend(self._profile_card_candidates(query, terms))

        # A recall ranks the same bounded candidate texts more than once:
        # first for document frequency and then for terms, anchors, and
        # aliases in ``_score``.  Cache only this call's exact
        # ``_contains_term`` results.  The underlying matcher remains the
        # authority for lexical/boundary semantics; no state escapes recall.
        lexical_matches: dict[tuple[str, str], bool] = {}

        def contains_term_once(text: str, term: str) -> bool:
            key = (text, term)
            matched = lexical_matches.get(key)
            if matched is None:
                matched = _contains_term(text, term)
                lexical_matches[key] = matched
            return matched

        scored: list[Candidate] = []
        seen_text: set[str] = set()
        document_frequency = Counter(
            term
            for term in terms
            for candidate in candidates
            if contains_term_once(candidate.text, term)
        )
        corpus_size = len(candidates)
        scoring_anchors = self._query_anchors(query, terms)
        scoring_alias_terms = _meaningful_terms(" ".join(matched_aliases))
        scoring_identity_terms = self._query_identity_terms(query, terms)
        for candidate in candidates:
            value = self._score(
                candidate,
                query,
                terms,
                profile_query,
                document_frequency,
                corpus_size,
                temporal_target,
                anchors=scoring_anchors,
                alias_terms=scoring_alias_terms,
                identity_terms=scoring_identity_terms,
                contains_term=contains_term_once,
            )
            if value is None:
                continue
            # A current-task claim cached as ordinary memory cannot establish
            # its own session/workspace authority.  The dedicated task route only
            # emits a current task from an authoritative execution contract;
            # keep unverified current-task bodies out of broad semantic recall.
            if layer == "all" and self._is_unverified_current_task_memory(value):
                continue
            value.injection_disposition = self._evidence_disposition(value, output_policy)
            if value.injection_disposition == "omit":
                continue
            if layer != "all" and _layer(value.text) != layer:
                continue
            if not self._session_scope_allowed(value, query, layer):
                continue
            key = re.sub(r"\s+", " ", value.text).strip().lower()
            if key in seen_text:
                continue
            seen_text.add(key)
            scored.append(value)

        if not self_model_query and not task_query and not state_query and len(scored) < effective_top_k and self.hybrid.get("fallbackRecentWhenBelowTopK", True) and scoring_anchors:
            for candidate in self._recent_candidates(terms, max(effective_top_k * 4, effective_top_k)):
                value = self._score(
                    candidate,
                    query,
                    terms,
                    profile_query,
                    document_frequency,
                    corpus_size,
                    temporal_target,
                    anchors=scoring_anchors,
                    alias_terms=scoring_alias_terms,
                    identity_terms=scoring_identity_terms,
                    contains_term=contains_term_once,
                )
                if value is None:
                    continue
                if layer == "all" and self._is_unverified_current_task_memory(value):
                    continue
                value.injection_disposition = self._evidence_disposition(value, output_policy)
                if value.injection_disposition == "omit":
                    continue
                if layer != "all" and _layer(value.text) != layer:
                    continue
                if not self._session_scope_allowed(value, query, layer):
                    continue
                key = re.sub(r"\s+", " ", value.text).strip().lower()
                if key in seen_text:
                    continue
                seen_text.add(key)
                scored.append(value)

        if self_model_query:
            scored.sort(key=lambda item: (item.source_priority, -item.confidence, -item.score))
        elif task_query:
            scored.sort(key=lambda item: (item.source_priority, -item.confidence, -item.score))
        elif state_query:
            scored.sort(key=lambda item: (item.source_priority, -item.confidence, -item.score))
        else:
            scored.sort(
                key=lambda item: (
                    0 if temporal_target is not None and item.temporal_match else 1,
                    0 if item.exact_match else 1,
                    0 if item.canonical_match and item.canonical_explicit else 1,
                    0 if not item.graph_expansion else 1,
                    0 if profile_query and "[PROFILE]" in item.text else 1,
                    -len(item.matched_terms)
                    if item.source_type != "sandglass" or "[PROFILE]" in item.text
                    else 0,
                    0 if "[CURRENT]" in item.text else 1,
                    item.relation_priority,
                    0 if "[SUMMARY]" in item.text else 1,
                    0 if item.personal_claim else 1,
                    0 if item.historical_specific else 1,
                    0 if item.historical_claim else 1,
                    -item.rank_score,
                    -len(item.anchor_matches),
                    -len(item.matched_terms),
                    -item.confidence,
                    item.source,
                )
            )
            scored = self._resolve_conflicting_candidates(scored)
            temporal_answers = [item for item in scored if item.temporal_match]
            current_intent = bool(
                re.search(r"\b(?:current|currently|latest)\b", query.lower())
                or "当前" in query
                or "现在" in query
            )
            if temporal_target is not None and temporal_answers:
                scored = temporal_answers
            elif current_intent:
                current_answers = [item for item in scored if "[CURRENT]" in item.text]
                if current_answers:
                    scored = current_answers

        selected: list[dict[str, Any]] = []
        selected_ids: set[str] = set()
        used_tokens = 0
        for item in scored:
            if len(selected) >= output_policy.max_results:
                break
            if item.identity_key and item.identity_key in selected_ids:
                continue
            snippet = self._candidate_snippet(item.text, query, terms, output_policy.card_max_chars)
            snippet = self._limit_output_chars(snippet, output_policy.card_max_chars)
            token_estimate = math.ceil(len(snippet) / 4)
            if used_tokens + token_estimate > output_policy.max_tokens and selected:
                break
            tags = _tags(item.text)
            age = _age_days(item.timestamp)
            layer_name = _layer(item.text)
            inject_ready = item.injection_disposition == "inject"
            relevance_status = (
                f"self_model_{item.snapshot_status or 'unknown'}"
                if item.source_type == "self_model" and item.verification_status != "verified"
                else "summary_only"
                if not inject_ready
                else "authoritative"
                if item.authoritative
                else ("anchor_matched" if item.anchor_matches else "matched")
            )
            card = {
                "source": item.source,
                "sourceType": item.source_type,
                "claim": snippet,
                "whyRelevant": item.reason,
                "confidence": item.confidence,
                "lastVerified": "verified" if "[VERIFIED]" in item.text else "unverified",
                "layer": layer_name,
                "tags": tags,
                "ageDays": round(age, 2),
                "recallPriority": "profile" if "[PROFILE]" in item.text else item.source_type,
                "snippet": snippet,
                "tokenEstimate": token_estimate,
                "injectReady": inject_ready,
                "recallDisposition": item.injection_disposition,
                "relevanceStatus": relevance_status,
                "matchedTerms": item.matched_terms,
                "canonicalMatch": item.canonical_match,
                "anchorTerms": item.anchor_matches,
                "selfModelStatus": item.snapshot_status if item.source_type == "self_model" else "",
                    "verificationStatus": item.verification_status if item.source_type == "self_model" else "",
                    "senderRole": item.sender or "unknown",
                    "provenanceScope": "scoped" if any((item.session_key, item.task_key, item.workspace_key)) else "legacy",
                    "snippetMode": "query_centered_session_turn" if item.source_type == "sandglass" else "bounded_prefix",
                    "temporalMatch": item.temporal_match,
                    "temporalDistanceDays": item.temporal_distance_days if item.temporal_match else None,
                    "requiredMatchCount": self._required_matches(len(terms)),
                "sourcePriority": item.source_priority,
            }
            selected.append(
                {
                    "text": snippet,
                    "evidenceCard": card,
                    "source": item.source,
                    "sourceType": item.source_type,
                    "layer": layer_name,
                    "tags": tags,
                    "score": item.score,
                    "confidence": item.confidence,
                    "reason": item.reason,
                    "ageDays": round(age, 2),
                    "recallPriority": card["recallPriority"],
                    "tokenEstimate": card["tokenEstimate"],
                    "relevanceOk": inject_ready,
                    "injectReady": card["injectReady"],
                    "recallDisposition": card["recallDisposition"],
                    "matchedTerms": item.matched_terms,
                    "anchorTerms": item.anchor_matches,
                    "temporalMatch": item.temporal_match,
                    "temporalDistanceDays": item.temporal_distance_days if item.temporal_match else None,
                    "requiredMatchCount": card["requiredMatchCount"],
                    "matchedTermCount": len(item.matched_terms),
                    "exactMatch": item.exact_match,
                    "canonicalMatch": item.canonical_match,
                    "identityKey": item.identity_key,
                    "relationPriority": item.relation_priority,
                    "selfModelStatus": item.snapshot_status if item.source_type == "self_model" else "",
                    "verificationStatus": item.verification_status if item.source_type == "self_model" else "",
                    "sourcePriority": item.source_priority,
                }
            )
            used_tokens += token_estimate
            if item.identity_key:
                selected_ids.add(item.identity_key)
        return selected

    def evaluation_ranked_evidence(
        self,
        query: str,
        rank_limit: int = MAX_EVALUATION_RANK,
        layer: str = "all",
        query_date: str = "",
    ) -> list[dict[str, Any]]:
        """Return bounded metadata for the isolated Phase 6 evaluator only.

        This is intentionally not exposed through the CLI or MCP. Normal recall
        keeps its public four-card / 500-token contract; the evaluator needs a
        ten-item ranking to measure retrieval independently of that user-facing cap.
        """
        try:
            rank_limit = min(max(1, int(rank_limit)), MAX_EVALUATION_RANK)
        except (TypeError, ValueError):
            rank_limit = MAX_EVALUATION_RANK
        items = self.recall(
            query,
            top_k=MAX_RECALL_TOP_K,
            max_tokens=MAX_EVALUATION_TOKENS,
            layer=layer,
            query_date=query_date,
            _evaluation_top_k=rank_limit,
        )
        return [
            {
                "rank": index,
                "source": str(item.get("source", "")),
                "sourceType": str(item.get("sourceType", "")),
                "layer": str(item.get("layer", "")),
                "score": float(item.get("score", 0.0)),
                "confidence": float(item.get("confidence", 0.0)),
                "reason": str(item.get("reason", "")),
                "injectReady": bool(item.get("injectReady", False)),
                "recallDisposition": str(item.get("recallDisposition", "")),
                "identityKey": str(item.get("identityKey", "")),
                "matchedTerms": list(item.get("matchedTerms", [])),
                "anchorTerms": list(item.get("anchorTerms", [])),
                "temporalMatch": bool(item.get("temporalMatch", False)),
                "canonicalMatch": bool(item.get("canonicalMatch", False)),
            }
            for index, item in enumerate(items, 1)
        ]

    def retired_transport_guard(self) -> dict[str, Any]:
        """Return the narrow retired-transport invariant without status work.

        Evidence reads need this guard but do not need a status projection.
        Keeping it independent avoids a duplicate MCP identity, binding,
        activation, and contract pass while preserving the same fail-closed
        check and public payload used by :meth:`status`.
        """
        # H7-only transport is a runtime invariant, not a host-registration
        # hint.  The injected local MCP path must not touch CODEX_HOME at all;
        # an optional legacy adapter diagnostic remains available for the
        # compatibility CLI/status path.
        runtime_file = self.package_root / "runtime" / "turn_runtime.py"
        hook_registered = False
        hook_config_readable = True
        hook_checked = False
        if not self.is_local_mcp_runtime:
            codex_home = Path(os.environ.get("CODEX_HOME", "").strip() or (Path.home() / ".codex"))
            hook_config = codex_home / "hooks.json"
            hook_checked = True
            if hook_config.exists():
                try:
                    hook_text = hook_config.read_text(encoding="utf-8-sig").lower()
                    hook_registered = any(marker in hook_text for marker in ("super-memory-brain", "codex_prompt_hook", "codex_stop_hook"))
                except (OSError, UnicodeError):
                    hook_config_readable = False
        transport_ready = runtime_file.exists() and (self.is_local_mcp_runtime or (hook_config_readable and not hook_registered))
        turn_runtime = {
            "available": transport_ready,
            "state": "available" if transport_ready else "withheld",
            "mode": "hookless_turn_runtime",
            "requiredForCore": True,
            "hookRegistrationAbsent": not hook_registered,
            "configurationReadable": hook_config_readable,
        }
        guard_code = (
            "H7_RUNTIME_ENTRY_MISSING"
            if not runtime_file.exists()
            else "H7_SUPER_BRAIN_HOOK_REGISTRATION_UNVERIFIABLE"
            if not hook_config_readable
            else "H7_SUPER_BRAIN_HOOK_REGISTRATION_CONFLICT"
            if hook_registered
            else "H7_RETIRED_TRANSPORT_GUARD_CURRENT"
        )
        return {
            "schema": "super-brain.retired-transport-guard.v1",
            "state": "ready" if guard_code == "H7_RETIRED_TRANSPORT_GUARD_CURRENT" else "withheld",
            "code": guard_code,
            "requiredForCore": True,
            "h7Transport": {
                "mode": "hookless_turn_runtime",
                "primary": "mcp",
                "fallback": "same_h7_cli",
                "entryAvailable": runtime_file.exists(),
            },
            "superBrainHookRegistration": {
                "state": "not_applicable" if self.is_local_mcp_runtime else "absent" if not hook_registered and hook_config_readable else "conflict" if hook_registered else "unverifiable",
                "registered": None if self.is_local_mcp_runtime else hook_registered if hook_config_readable else None,
                "configurationReadable": hook_config_readable,
                "checked": hook_checked,
            },
            "actionAuthorization": "not_authorizing",
            "legacyDependency": "none",
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }

    def status(self) -> dict[str, Any]:
        state = _read_json(self.workspace / "super-brain-state.json") or {}
        status_card = _read_json(self.workspace / "status-card.json") or {}
        version = str(self.manifest.get("version", "unknown"))
        active_contract = self._execution_contract_context()
        activation = self._activation_summary(
            str((active_contract or {}).get("taskId", "")),
            str((active_contract or {}).get("taskInstanceId", "")),
        )
        core_rules = self.core_rules()
        runtime_identity = self.runtime_identity_status(served_core_rules=core_rules)
        # One fresh identity proof per status request is enough.  The binding
        # check consumes that exact proof instead of stat/hash-scanning the
        # 31-file MCP identity closure a second time.
        mcp_runtime_binding = self.mcp_runtime_binding_status(runtime_identity=runtime_identity)
        retired_transport_guard = self.retired_transport_guard()
        hook_registration = retired_transport_guard.get("superBrainHookRegistration", {})
        turn_runtime = {
            "available": retired_transport_guard.get("state") == "ready",
            "state": "available" if retired_transport_guard.get("state") == "ready" else "withheld",
            "mode": "hookless_turn_runtime",
            "requiredForCore": True,
            "hookRegistrationAbsent": hook_registration.get("state") == "absent",
            "configurationReadable": hook_registration.get("state") != "unverifiable",
        }

        def verification_axis(payload: dict[str, Any], fallback: Any = None) -> dict[str, Any]:
            value = payload.get("verification")
            if isinstance(value, dict):
                passed = bool(value.get("passed", value.get("state") == "passed"))
                return {
                    "state": str(value.get("state", "passed" if passed else "failed")),
                    "passed": passed,
                    "lastResultOk": bool(value.get("lastResultOk", passed)),
                    "checkedAt": value.get("checkedAt"),
                    "requiredForCore": bool(value.get("requiredForCore", False)),
                }
            passed = bool(fallback)
            return {
                "state": "passed" if passed else "failed",
                "passed": passed,
                "lastResultOk": passed,
                "checkedAt": payload.get("lastVerifyAt", payload.get("verifyCheckedAt")),
                "requiredForCore": False,
            }

        trusted: dict[str, Any] | None = None
        if isinstance(state, dict) and str(state.get("version", "")) == version:
            core_available = bool(state.get("coreAvailable", state.get("ok", False)))
            verification = verification_axis(state, state.get("lastVerifyOk"))
            trusted = {
                "ok": bool(core_available and verification["passed"]),
                "okScope": "legacy_strict_core_and_current_verification",
                "coreAvailable": core_available,
                "operational": state.get(
                    "operational",
                    {"state": "available" if core_available else "unavailable", "available": core_available},
                ),
                "verification": verification,
                "retiredTransportGuard": retired_transport_guard,
                "turnRuntime": turn_runtime,
                "verifyOk": verification["passed"],
                "updatedAt": state.get("updatedAt"),
                "stateSource": "memory\\workspace\\super-brain-state.json",
            }
        elif isinstance(status_card, dict) and str(status_card.get("version", "")) == version and "coreAvailable" in status_card:
            core_available = bool(status_card.get("coreAvailable"))
            verification = verification_axis(status_card, status_card.get("verifyOk"))
            trusted = {
                "ok": bool(core_available and verification["passed"]),
                "okScope": "legacy_strict_core_and_current_verification",
                "coreAvailable": core_available,
                "operational": {"state": "available" if core_available else "unavailable", "available": core_available},
                "verification": verification,
                "retiredTransportGuard": retired_transport_guard,
                "turnRuntime": turn_runtime,
                "verifyOk": verification["passed"],
                "updatedAt": status_card.get("updatedAt"),
                "stateSource": "memory\\workspace\\status-card.json",
            }
        if trusted is None:
            trusted = {
                "ok": False,
                "okScope": "legacy_strict_core_and_current_verification",
                "coreAvailable": False,
                "operational": {"state": "unknown", "available": False},
                "verification": {"state": "unknown", "passed": False, "lastResultOk": False, "checkedAt": None, "requiredForCore": False},
                "retiredTransportGuard": retired_transport_guard,
                "turnRuntime": turn_runtime,
                "verifyOk": None,
                "updatedAt": None,
                "stateSource": "unavailable_or_version_mismatch",
            }
        runtime_current = runtime_identity.get("state") == "current"
        operational = trusted["operational"] if runtime_current else {
            "state": "withheld",
            "available": False,
            "code": str(runtime_identity.get("code", "H7_MCP_RUNTIME_IDENTITY_STALE")),
        }
        return {
            "ok": bool(trusted["ok"] and runtime_current),
            "okScope": trusted["okScope"],
            "agentIdentity": agent_identity(),
            "authorityModel": authority_model(),
            "coreAvailable": bool(trusted["coreAvailable"] and runtime_current),
            "operational": operational,
            "verification": trusted["verification"],
            "retiredTransportGuard": trusted["retiredTransportGuard"],
            "turnRuntime": trusted["turnRuntime"],
            "activation": activation,
            "coreRules": core_rules,
            "runtimeIdentity": runtime_identity,
            "mcpRuntimeBinding": mcp_runtime_binding,
            "fullBrainActive": bool(
                activation.get("state") == "full_brain_active"
                and core_rules.get("status") == "current"
                and runtime_current
            ),
            "version": version,
            "packageRoot": str(self.package_root),
            "memoryRoot": str(self.memory_root),
            "memoryBase": str(self.memory_base),
            "verifyOk": trusted["verifyOk"],
            "updatedAt": trusted["updatedAt"],
            "stateTrust": "source_qualified" if trusted["stateSource"] != "unavailable_or_version_mismatch" else "unknown",
            "stateSource": trusted["stateSource"],
            "runtime": "super-brain-core-python",
            "transport": "mcp-stdio-or-cli",
        }

    @classmethod
    def _session_provenance_keys(cls, session_key: str) -> set[str]:
        """Return compatible provenance forms for one local session.

        Older writers persisted the first 16 hex characters of the session
        hash, while the current runtime carries a ``sid-`` key.  Accept both
        forms, plus the hash of an already-normalized key, without accepting a
        missing session as a wildcard.
        """

        raw = str(session_key or "").strip().lower()
        if not raw:
            return set()
        normalized = cls._session_key_from_value(raw).lower()
        keys = {normalized}
        if normalized.startswith("sid-"):
            keys.add(normalized[4:20])
        if re.fullmatch(r"[0-9a-f]{16,64}", raw):
            keys.add(raw)
        keys.add(hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16])
        keys.add(hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:16])
        return {item for item in keys if item}

    @staticmethod
    def _workspace_provenance_keys(workspace_key: str) -> set[str]:
        """Accept current and legacy opaque workspace provenance forms."""

        normalized = str(workspace_key or "").strip().lower()
        if not normalized:
            return set()
        keys = {normalized}
        if normalized.startswith("ws-") and re.fullmatch(r"ws-[0-9a-f]{16,64}", normalized):
            keys.add(normalized[3:])
        keys.add(hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:16])
        return {item for item in keys if item}

    def recent(self, limit: int = 5, *, session_key: str | None = None) -> list[dict[str, Any]]:
        """Return recent memory, fail-closed when a scoped session is absent.

        ``session_key=None`` preserves the ordinary CLI's legacy unscoped
        read.  A scoped caller must name the current local session (or an
        explicit empty string); an absent or foreign scoped value returns no
        records and can never fall back to another conversation's tail.
        """

        limit = min(max(1, int(limit)), 20)
        if session_key is None:
            rows = self._recent_sandglass_rows(limit)
        else:
            requested = str(session_key or "").strip()
            if not requested:
                return []
            current_session = self._context_session_key()
            requested_session_keys = self._session_provenance_keys(requested)
            if not current_session or not requested_session_keys.intersection(
                self._session_provenance_keys(current_session)
            ):
                return []
            current_workspace = self._context_workspace_key()
            if not current_workspace:
                return []
            rows = self._recent_sandglass_rows(
                limit,
                session_keys=requested_session_keys,
                workspace_keys=self._workspace_provenance_keys(current_workspace),
            )
        return [
            {"line": int(row[0]), "timestamp": str(row[1]), "text": _compact(str(row[3]), 320)}
            for row in rows or []
            if len(row) >= 4 and not _looks_corrupt(str(row[3]))
        ]

    def health(self) -> dict[str, Any]:
        memory_path = self.memory_root / "sandglass.txt"
        memory_count = 0
        memory_readable = True
        try:
            if memory_path.is_file():
                with memory_path.open("r", encoding="utf-8", errors="replace") as handle:
                    memory_count = sum(1 for _ in handle)
        except (OSError, UnicodeError):
            memory_readable = False
        runtime_source_relative = str(self.manifest.get("runtimeSourceRoot", "")).strip().replace("\\", "/")
        runtime_source = self.package_root / runtime_source_relative if runtime_source_relative else Path()
        checks = {
            "packageRoot": self.package_root.exists(),
            "memoryRoot": self.memory_root.exists(),
            "memoryScripts": bool(runtime_source_relative) and (runtime_source / "sandglass_vault.py").exists(),
            "policy": (self.package_root / "memory-policy.json").exists(),
            "memoryRead": memory_readable,
        }
        return {
            "ok": all(checks.values()),
            "okScope": "local_runtime_health",
            "checks": checks,
            "memoryCount": memory_count,
            "status": self.status(),
        }
