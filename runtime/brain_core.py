from __future__ import annotations

import importlib
import json
import math
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterable


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


@dataclass(frozen=True)
class RetrievalOutputPolicy:
    max_results: int
    max_tokens: int
    card_max_chars: int
    summary_confidence: float
    inject_confidence: float


class BrainCore:
    def __init__(self, package_root: str | Path, memory_root: str | Path | None = None):
        self.package_root = Path(package_root).expanduser().resolve()
        self.memory_root = self._resolve_memory_root(memory_root)
        self.memory_base = self._resolve_memory_base()
        self.workspace = self.memory_base / "workspace"
        self.policy = _read_json(self.package_root / "memory-policy.json") or {}
        self.manifest = _read_json(self.package_root / "manifest.json") or {}
        self._graph_cache_key: tuple[int, int] | None = None
        self._graph_cache: list[tuple[str, str, int]] = []
        self._memory_modules: dict[str, Any] = {}
        self._configure_memory_runtime()

    def _resolve_memory_root(self, supplied: str | Path | None) -> Path:
        if supplied:
            return Path(supplied).expanduser().resolve()
        env_root = os.environ.get("NEXSANDBASE_HOME", "").strip()
        if env_root:
            return Path(env_root).expanduser().resolve()
        layout = _read_json(self.package_root / "runtime-layout.json") or {}
        state_root = str(layout.get("stateRoot", "")).strip()
        if state_root:
            return (Path(state_root).expanduser().resolve() / "shared")
        return (self.package_root / "memory" / "shared").resolve()

    def _resolve_memory_base(self) -> Path:
        layout = _read_json(self.package_root / "runtime-layout.json") or {}
        state_root = str(layout.get("stateRoot", "")).strip()
        if state_root:
            resolved = Path(state_root).expanduser().resolve()
            try:
                self.memory_root.relative_to(resolved)
                return resolved
            except ValueError:
                pass
        parent = self.memory_root.parent
        if parent.name.lower() in {"agents", "groups"}:
            return parent.parent
        if self.memory_root.name.lower() == "shared":
            return parent
        return parent

    def _configure_memory_runtime(self) -> None:
        scripts = self.memory_root / "scripts"
        os.environ["NEXSANDBASE_HOME"] = str(self.memory_root)
        script_text = str(scripts)
        if script_text not in sys.path:
            sys.path.insert(0, script_text)

    def _module(self, name: str) -> Any:
        if name not in self._memory_modules:
            self._memory_modules[name] = importlib.import_module(name)
        return self._memory_modules[name]

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
    ) -> RetrievalOutputPolicy:
        context_budget = self.retrieval.get("contextBudget", {})
        context_budget = context_budget if isinstance(context_budget, dict) else {}
        budget_enabled = bool(context_budget.get("enabled", True))
        max_results = self._bounded_int(requested_top_k, 3, 1, 10)
        max_tokens = self._bounded_int(requested_max_tokens, 1200, 32, 4000)
        card_tokens = self._bounded_int(context_budget.get("cardSnippetTokens"), 56, 20, 1000)

        if budget_enabled:
            max_results = min(
                max_results,
                self._bounded_int(context_budget.get("maxEvidenceCards"), 4, 1, 10),
            )
            max_tokens = min(
                max_tokens,
                self._bounded_int(context_budget.get("evidenceTokens"), 500, 32, 4000),
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

    def _query_terms(self, query: str) -> set[str]:
        return _meaningful_terms(" ".join([query, *self._matched_aliases(query)]))

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
            lowered = token.lower()
            if any(character.isdigit() for character in token) or "-" in token:
                identities.add(lowered)
            elif token[:1].isupper() and lowered not in leading_question_words:
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
        explicit = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY", "").strip()
        if explicit:
            return explicit
        status = _read_json(self.workspace / "status-card.json")
        if isinstance(status, dict):
            return str(status.get("workspaceKey", "")).strip()
        return ""

    def _current_task_context(self) -> dict[str, Any] | None:
        context = _read_json(self.workspace / "current-task-context.json")
        if not isinstance(context, dict):
            return None
        if str(context.get("status", "")) != "active" or context.get("stale") is True:
            return None
        task_id = str(context.get("taskId", "")).strip()
        context_key = str(context.get("workspaceKey", "")).strip()
        current_key = self._current_workspace_key()
        if not task_id or not context_key or not current_key:
            return None
        if context_key.lower() != current_key.lower():
            return None
        if str(context.get("version", self.manifest.get("version", ""))) != str(self.manifest.get("version", "")):
            return None
        expires_at = _parse_dt(str(context.get("expiresAt", "")))
        if expires_at is not None and expires_at <= datetime.now():
            return None
        return context

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
        try:
            revision = int(value.get("revision"))
        except (TypeError, ValueError):
            return None
        return revision if revision >= 0 else None

    def _task_candidates(self, query: str, terms: set[str]) -> list[Candidate]:
        context = self._current_task_context()
        if context is None:
            return []
        checkpoint = self._current_task_checkpoint(context) or {}
        task_id = str(context.get("taskId", ""))
        task_name = str(checkpoint.get("taskName", context.get("taskName", "")))
        goal = str(checkpoint.get("goal", context.get("acceptedGoal", "")))
        current_step = str(checkpoint.get("currentStep", context.get("currentStep", "")))
        next_action = str(checkpoint.get("nextAction", context.get("nextAction", "")))
        text = (
            f"[TASK][CURRENT][VERIFIED][SUMMARY] current task taskId={task_id} "
            f"taskName={task_name} goal={goal} currentStep={current_step} nextAction={next_action}"
        )
        return [
            Candidate(
                text=text,
                source="memory\\workspace\\current-task-context.json",
                source_type="task",
                reason="current_task_identity_priority",
                timestamp=str(context.get("checkedAt", "")),
                source_priority=5,
                authoritative=True,
            )
        ]

    def _state_candidates(self, query: str, terms: set[str]) -> list[Candidate]:
        sources = [
            (self.workspace / "status-card.json", "memory\\workspace\\status-card.json", 10),
            (self.workspace / "super-brain-state.json", "memory\\workspace\\super-brain-state.json", 20),
            (self.package_root / "CURRENT_BASELINE.md", "CURRENT_BASELINE.md", 30),
            (self.package_root / "manifest.json", "manifest.json", 40),
            (self.package_root / "CHANGELOG.md", "CHANGELOG.md", 50),
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
        for path, source, priority in sources:
            raw = _read_text(path)
            text = raw
            if path.name == "status-card.json":
                status = _read_json(path)
                if isinstance(status, dict):
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
                    if self._is_task_query(query):
                        task = self._current_task_context()
                        if task is not None:
                            safe_status["taskId"] = task.get("taskId", "")
                            safe_status["currentStep"] = task.get("currentStep", "")
                            safe_status["nextTaskAction"] = task.get("nextAction", "")
                    text = json.dumps(safe_status, ensure_ascii=False, separators=(",", ":"))
                    if status_query:
                        priority = 0
            elif path.name == "super-brain-state.json":
                state = _read_json(path)
                if isinstance(state, dict):
                    state_version = str(state.get("version", ""))
                    if state_version and state_version != manifest_version:
                        continue
                    if status_query:
                        priority = 1
            elif path.name == "manifest.json" and version_query:
                priority = 3 if status_query else 1
                text = json.dumps({"version": manifest_version}, ensure_ascii=False, separators=(",", ":"))
            elif path.name == "CURRENT_BASELINE.md" and version_query:
                priority = 4 if status_query else 2
            if not text:
                continue
            lowered = text.lower()
            indexes = [lowered.find(term.lower()) for term in terms if term and lowered.find(term.lower()) >= 0]
            index = min(indexes) if indexes else 0
            start = max(0, index - 220)
            snippet = text[start : start + 600].strip()
            timestamp = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
            value = f"[PROJECT][CURRENT][VERIFIED][SUMMARY] subject=super-memory-brain {source} timestamp={timestamp} {snippet}"
            candidates.append(
                Candidate(
                    text=value,
                    source=source,
                    source_type="state",
                    reason="state_recall_priority",
                    timestamp=timestamp,
                    source_priority=priority,
                    authoritative=True,
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
            values.append(
                Candidate(
                    text=str(item[2]),
                    source=f"{line_number}:{item[1]}",
                    source_type="sandglass",
                    reason=reason,
                    timestamp=str(item[1]),
                )
            )

    def _sandglass_candidates(self, query: str, top_k: int, query_date: str = "") -> list[Candidate]:
        vault = self._module("sandglass_vault")
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

        if adaptive_enabled:
            try:
                sqlite_search = self._module("sandglass_sqlite")
                sqlite_search.sync_incremental()
                for search_query in search_queries:
                    self._append_sandglass_rows(
                        values,
                        seen,
                        sqlite_search.search(search_query, limit),
                        "sandglass_fts5",
                    )
            except Exception:
                pass

            if len(values) < fallback_count:
                for search_query in search_queries:
                    try:
                        rows = vault.idx_search(search_query, limit=limit)
                    except Exception:
                        rows = []
                    self._append_sandglass_rows(values, seen, rows, "sandglass_idx_fallback")
                    if len(values) >= fallback_count:
                        break

            if len(values) < fallback_count and bool(adaptive.get("legacyFallbackOnMiss", True)):
                legacy_count = self._bounded_int(adaptive.get("legacyFallbackMaxQueries"), 1, 1, len(search_queries))
                for search_query in reversed(search_queries[-legacy_count:]):
                    try:
                        rows = vault.search(search_query, limit=limit)
                    except Exception:
                        rows = []
                    self._append_sandglass_rows(values, seen, rows, "sandglass_router_fallback")
                    if len(values) >= fallback_count:
                        break
        else:
            for search_query in search_queries:
                try:
                    rows = vault.search(search_query, limit=limit)
                except Exception:
                    rows = []
                self._append_sandglass_rows(values, seen, rows, "sandglass_search")

        # Search backends can rank common question words above the factual turn.
        # For bounded local logs, scan only lines containing a real query anchor
        # so a backend miss cannot hide an otherwise searchable memory.
        scan_enabled = bool(dynamic.get("fullScanFallback", True)) if isinstance(dynamic, dict) else True
        query_terms = self._query_terms(query)
        anchors = self._query_anchors(query, query_terms)
        temporal_target = self._temporal_target_date(query, query_date)
        scan_limit = int(dynamic.get("fullScanMaxLines", 2000)) if isinstance(dynamic, dict) else 2000
        path = self.memory_root / "sandglass.txt"
        has_anchor_candidate = any(
            any(_contains_term(candidate.text, anchor) for anchor in anchors)
            for candidate in values
        )
        if scan_enabled and (anchors or temporal_target is not None) and path.exists() and (
            temporal_target is not None or not values or not has_anchor_candidate
        ):
            try:
                with path.open("r", encoding="utf-8", errors="replace") as handle:
                    for line_number, line in enumerate(handle, 1):
                        if line_number > scan_limit:
                            break
                        if line_number in seen:
                            continue
                        lowered = line.lower()
                        session_date = self._session_date(line)
                        anchor_hit = any(_contains_term(line, anchor) for anchor in anchors)
                        temporal_hit = (
                            temporal_target is not None
                            and session_date is not None
                            and abs((session_date.date() - temporal_target[0].date()).days) <= temporal_target[1]
                        )
                        if not anchor_hit and not temporal_hit:
                            continue
                        pieces = line.rstrip("\r\n").split(" | ", 2)
                        timestamp = pieces[0] if pieces else ""
                        text = pieces[2] if len(pieces) >= 3 else line.rstrip("\r\n")
                        values.append(
                            Candidate(
                                text=text,
                                source=f"{line_number}:{timestamp}",
                                source_type="sandglass",
                                reason="sandglass_anchor_scan",
                                timestamp=timestamp,
                            )
                        )
                        seen.add(line_number)
            except (OSError, UnicodeError):
                pass
        return values

    def _self_model_candidates(self, query: str) -> list[Candidate]:
        policy = self.policy.get("selfModel", {})
        policy = policy if isinstance(policy, dict) else {}
        try:
            max_age_hours = max(1, int(policy.get("maxAgeHours", 24)))
        except (TypeError, ValueError):
            max_age_hours = 24

        item = _read_json(self.workspace / "self-model.json")
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
            if "[SESSION]" in text and "session_content=" in text:
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

    def _graph_rows(self) -> list[tuple[str, str, int]]:
        path = self.memory_base / "graph.jsonl"
        try:
            stat = path.stat()
            key = (stat.st_mtime_ns, stat.st_size)
        except OSError:
            return []
        if key == self._graph_cache_key:
            return self._graph_cache
        rows: list[tuple[str, str, int]] = []
        try:
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if not line.strip():
                    continue
                try:
                    node = json.loads(line.lstrip("\ufeff"))
                except json.JSONDecodeError:
                    continue
                text = " ".join(
                    str(node.get(name, ""))
                    for name in ("subject", "relation", "object", "evidence", "tags")
                ).strip()
                relation = str(node.get("relation", ""))
                priority = {"decides": 0, "has_title": 10, "has_context": 20, "has_consequence": 30, "affects": 40}.get(relation, 45)
                rows.append((text, f"memory\\graph.jsonl:{number}", priority))
        except (OSError, UnicodeError):
            rows = []
        self._graph_cache_key = key
        self._graph_cache = rows
        return rows

    def _graph_candidates(self, terms: set[str]) -> list[Candidate]:
        values: list[Candidate] = []
        for text, source, priority in self._graph_rows():
            lowered = text.lower()
            matched = [term for term in terms if _contains_term(text, term)]
            required = max(1, min(2, self._required_matches(len(terms))))
            if len(matched) < required:
                continue
            values.append(
                Candidate(
                    text=text,
                    source=source,
                    source_type="graph",
                    reason="graph_decision_or_lineage",
                    relation_priority=priority,
                )
            )
        return values

    def _experience_candidates(self, query: str, terms: set[str]) -> list[Candidate]:
        values: list[Candidate] = []
        root = self.workspace / "experiences"
        if not root.exists():
            return values
        for path in root.glob("*.json"):
            item = _read_json(path)
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
        item = _read_json(self.workspace / "profile-card.json")
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

    def _score(
        self,
        candidate: Candidate,
        query: str,
        terms: set[str],
        profile_query: bool,
        document_frequency: dict[str, int] | None = None,
        corpus_size: int = 0,
        temporal_target: tuple[datetime, int] | None = None,
    ) -> Candidate | None:
        text = candidate.text
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
        candidate.matched_terms = sorted(term for term in terms if _contains_term(text, term))
        anchors = self._query_anchors(query, terms)
        candidate.anchor_matches = sorted(term for term in anchors if _contains_term(text, term))
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
        identity_terms = self._query_identity_terms(query, terms)
        identity_anchor_match = any(term in candidate.anchor_matches for term in identity_terms)
        frequency_limit = max(1, math.ceil(max(corpus_size, 1) * 0.08))
        specific_terms = {
            term
            for term in anchors
            if term not in GENERIC_FACT_TERMS
            and (not document_frequency or int(document_frequency.get(term, 0)) <= frequency_limit)
        }
        specific_anchor_match = any(term in candidate.anchor_matches for term in specific_terms)
        alias_terms = _meaningful_terms(" ".join(self._matched_aliases(query)))
        alias_match_count = sum(_contains_term(text, term) for term in alias_terms)
        alias_required = min(3, max(2, math.ceil(len(alias_terms) * 0.2))) if alias_terms else 0
        alias_supported = bool(alias_terms) and alias_match_count >= alias_required
        generic_only = bool(candidate.matched_terms) and not candidate.anchor_matches
        relevant = (
            candidate.authoritative
            or candidate.exact_match
            or candidate.canonical_match
            or bool(candidate.anchor_matches)
            or candidate.temporal_match
        )
        if not anchors:
            relevant = candidate.authoritative or candidate.exact_match or candidate.canonical_match or candidate.temporal_match or (
                required > 0 and len(candidate.matched_terms) >= required
            )
        elif generic_only and candidate.source_type in {"sandglass", "recent"}:
            relevant = False
        if (
            anchors
            and (candidate.source_type != "recent" or candidate.reason == "recent_fallback")
            and not candidate.authoritative
            and not candidate.exact_match
            and not candidate.canonical_match
            and not candidate.temporal_match
        ):
            relevant = relevant and (
                alias_supported
                or (not alias_terms and identity_anchor_match)
                or (not alias_terms and specific_anchor_match)
                or (profile_query and "[PROFILE]" in text and len(candidate.matched_terms) >= max(1, min(required, 2)))
                or len(candidate.matched_terms) >= required
            )
        personal_fact_query = self._is_personal_fact_query(query)
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

    def _recent_candidates(self, terms: set[str], limit: int) -> list[Candidate]:
        vault = self._module("sandglass_vault")
        try:
            rows = vault.recent(limit)
        except Exception:
            rows = []
        return [
            Candidate(
                text=str(row[2]),
                source=f"{row[0]}:{row[1]}",
                source_type="recent",
                reason="recent_fallback",
                timestamp=str(row[1]),
            )
            for row in rows or []
            if len(row) >= 3
        ]

    def recall(
        self,
        query: str,
        top_k: int = 3,
        max_tokens: int = 1200,
        layer: str = "all",
        query_date: str = "",
    ) -> list[dict[str, Any]]:
        query = query.strip()
        if not query or top_k <= 0 or max_tokens <= 0:
            return []
        top_k = min(max(1, int(top_k)), 10)
        max_tokens = min(max(32, int(max_tokens)), 4000)
        if layer not in {"all", "profile", "project", "decision", "task", "session"}:
            raise ValueError(f"unsupported layer: {layer}")

        output_policy = self._retrieval_output_policy(top_k, max_tokens)
        effective_top_k = output_policy.max_results
        terms = self._query_terms(query)
        temporal_target = self._temporal_target_date(query, query_date)
        profile_query = self._is_profile_query(query)
        state_query = self._is_state_query(query, terms)
        self_model_query = self._is_self_model_query(query)
        candidates: list[Candidate]
        task_query = self._is_task_query(query)
        if self_model_query:
            candidates = self._self_model_candidates(query)
        elif task_query:
            candidates = self._task_candidates(query, terms)
        elif state_query:
            candidates = self._state_candidates(query, terms)
        else:
            candidates = self._sandglass_candidates(query, effective_top_k, query_date)
            candidates.extend(self._graph_candidates(terms))
            candidates.extend(self._experience_candidates(query, terms))
            candidates.extend(self._profile_card_candidates(query, terms))

        scored: list[Candidate] = []
        seen_text: set[str] = set()
        document_frequency = Counter(
            term
            for term in terms
            for candidate in candidates
            if _contains_term(candidate.text, term)
        )
        corpus_size = len(candidates)
        for candidate in candidates:
            value = self._score(candidate, query, terms, profile_query, document_frequency, corpus_size, temporal_target)
            if value is None:
                continue
            value.injection_disposition = self._evidence_disposition(value, output_policy)
            if value.injection_disposition == "omit":
                continue
            if layer != "all" and _layer(value.text) != layer:
                continue
            key = re.sub(r"\s+", " ", value.text).strip().lower()
            if key in seen_text:
                continue
            seen_text.add(key)
            scored.append(value)

        if not self_model_query and not task_query and not state_query and len(scored) < effective_top_k and self.hybrid.get("fallbackRecentWhenBelowTopK", True) and self._query_anchors(query, terms):
            for candidate in self._recent_candidates(terms, max(effective_top_k * 4, effective_top_k)):
                value = self._score(candidate, query, terms, profile_query, document_frequency, corpus_size, temporal_target)
                if value is None:
                    continue
                value.injection_disposition = self._evidence_disposition(value, output_policy)
                if value.injection_disposition == "omit":
                    continue
                if layer != "all" and _layer(value.text) != layer:
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

    def status(self) -> dict[str, Any]:
        state = _read_json(self.workspace / "super-brain-state.json") or {}
        status = _read_json(self.workspace / "status-card.json") or {}
        return {
            "ok": bool(state.get("ok", True)),
            "version": str(self.manifest.get("version", state.get("version", "unknown"))),
            "packageRoot": str(self.package_root),
            "memoryRoot": str(self.memory_root),
            "memoryBase": str(self.memory_base),
            "verifyOk": state.get("lastVerifyOk", status.get("verifyOk")),
            "updatedAt": state.get("updatedAt", status.get("updatedAt")),
            "runtime": "super-brain-core-python",
            "transport": "mcp-stdio-or-cli",
        }

    def recent(self, limit: int = 5) -> list[dict[str, Any]]:
        limit = min(max(1, int(limit)), 20)
        vault = self._module("sandglass_vault")
        try:
            rows = vault.recent(limit)
        except Exception:
            rows = []
        return [
            {"line": int(row[0]), "timestamp": str(row[1]), "text": _compact(str(row[2]), 320)}
            for row in rows or []
            if len(row) >= 3 and not _looks_corrupt(str(row[2]))
        ]

    def health(self) -> dict[str, Any]:
        checks = {
            "packageRoot": self.package_root.exists(),
            "memoryRoot": self.memory_root.exists(),
            "memoryScripts": (self.memory_root / "scripts" / "sandglass_vault.py").exists(),
            "policy": (self.package_root / "memory-policy.json").exists(),
        }
        try:
            count = int(self._module("sandglass_vault").count())
            checks["memoryImport"] = True
        except Exception:
            count = -1
            checks["memoryImport"] = False
        return {
            "ok": all(checks.values()),
            "checks": checks,
            "memoryCount": count,
            "status": self.status(),
        }
