from __future__ import annotations

"""Pure, read-only planning for bounded offline memory consolidation.

The planner deliberately has no knowledge of SQLite, the prompt hook, or the
card command engine.  It receives short-lived projections from ``BrainControl``
and produces only human-reviewable suggestions.  Calling it can never mutate a
memory card, a derived snapshot, or a transcript store.
"""

import hashlib
import json
import re
from datetime import UTC, datetime, timedelta
from typing import Any, Mapping, Sequence


SCHEMA = "super-brain.memory-consolidation-plan.v1"
_CANDIDATE_SOURCES = frozenset({"quick_capture", "staged_reflection"})
_CURRENT_SOURCE = "current"
_ALLOWED_KINDS = frozenset({"preference", "experience", "note", "procedure", "reflection", "decision"})
_RECOMMENDATIONS = frozenset(
    {
        "keep_for_review",
        "merge_with_active",
        "archive_exact_duplicate_candidate",
        "archive_stale_candidate",
    }
)


def _canonical_hash(value: Any) -> str:
    raw = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def _compact(value: Any, maximum: int = 4_000) -> str:
    if not isinstance(value, str):
        return ""
    return re.sub(r"\s+", " ", value).strip()[:maximum]


def _tokens(value: str) -> set[str]:
    lowered = re.sub(r"\s+", " ", value).strip().lower()
    result = set(re.findall(r"[a-z0-9][a-z0-9_-]{1,}", lowered))
    for run in re.findall(r"[\u4e00-\u9fff]+", lowered):
        if len(run) <= 16:
            result.add(run)
        result.update(run[index : index + 2] for index in range(max(0, len(run) - 1)))
    return result


def _opaque_card_ref(card_id: str) -> str:
    return "card-" + _canonical_hash({"cardId": card_id})


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(UTC)


def _normalize_now(value: datetime | str) -> datetime:
    parsed = value.astimezone(UTC) if isinstance(value, datetime) and value.tzinfo is not None else _parse_time(value)
    if parsed is None:
        raise ValueError("now must be an ISO-8601 UTC timestamp")
    return parsed


def _scope(value: Any) -> tuple[str, str]:
    if not isinstance(value, Mapping):
        raise ValueError("scope must be an object")
    kind = _compact(value.get("kind"), 64)
    key = _compact(value.get("key"), 256)
    if not kind or not key:
        raise ValueError("scope.kind and scope.key are required")
    return kind, key


def _requested_privacy(value: Any) -> str:
    if not isinstance(value, Mapping):
        return "private"
    privacy = _compact(value.get("privacyClass"), 64).lower() or "private"
    if privacy not in {"private", "shared", "public"}:
        raise ValueError("scope.privacyClass is invalid")
    return privacy


def _integer(value: Any, default: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        return default
    return value


def _record(value: Mapping[str, Any]) -> dict[str, Any] | None:
    card_id = _compact(value.get("cardId"), 160)
    content_hash = _compact(value.get("contentHash"), 80).lower()
    kind = _compact(value.get("kind"), 64).lower()
    lifecycle = _compact(value.get("lifecycle"), 64).lower()
    authority = _compact(value.get("authority"), 64).lower()
    privacy = _compact(value.get("privacyClass"), 64).lower()
    source = _compact(value.get("source"), 64).lower()
    subject = _compact(value.get("subjectText"), 4_000)
    suggested_kind = _compact(value.get("suggestedKind"), 64).lower() or kind
    revision = _integer(value.get("revision"))
    try:
        scope_kind, scope_key = _scope(value.get("scope"))
    except ValueError:
        return None
    if (
        not card_id
        or not re.fullmatch(r"[a-f0-9]{64}", content_hash)
        or kind not in _ALLOWED_KINDS
        or suggested_kind not in _ALLOWED_KINDS
        or lifecycle not in {"active", "proposed"}
        or authority not in {"user_confirmed", "system", "legacy", "unknown"}
        or privacy not in {"private", "shared", "public"}
        or source not in (_CANDIDATE_SOURCES | {_CURRENT_SOURCE})
        or not subject
        or revision < 1
    ):
        return None
    normalized_subject = re.sub(r"\s+", " ", subject).strip().lower()
    if not normalized_subject:
        return None
    return {
        "cardId": card_id,
        "revision": revision,
        "contentHash": content_hash,
        "kind": kind,
        "lifecycle": lifecycle,
        "authority": authority,
        "privacyClass": privacy,
        "scope": {"kind": scope_kind, "key": scope_key},
        "source": source,
        "suggestedKind": suggested_kind,
        "subjectDigest": _canonical_hash({"subject": normalized_subject}),
        "tokens": _tokens(normalized_subject),
        "createdAt": _parse_time(value.get("createdAt")),
    }


def _safe_ref(record: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "cardRef": _opaque_card_ref(str(record["cardId"])),
        "revision": int(record["revision"]),
        "contentHash": str(record["contentHash"]),
        "kind": str(record["kind"]),
    }


def _same_scope_and_privacy(left: Mapping[str, Any], right: Mapping[str, Any]) -> bool:
    return left["scope"] == right["scope"] and left["privacyClass"] == right["privacyClass"]


def _near_score(left: Mapping[str, Any], right: Mapping[str, Any]) -> tuple[float, int]:
    overlap = set(left["tokens"]) & set(right["tokens"])
    if not overlap:
        return 0.0, 0
    union = set(left["tokens"]) | set(right["tokens"])
    return len(overlap) / max(1, len(union)), len(overlap)


def _proposal(
    candidate: Mapping[str, Any],
    recommendation: str,
    *,
    confidence: int,
    reason: str,
    target: Mapping[str, Any] | None = None,
    matching_token_count: int = 0,
) -> dict[str, Any]:
    if recommendation not in _RECOMMENDATIONS:
        raise ValueError("unsupported recommendation")
    material = {
        "candidate": [candidate["cardId"], candidate["revision"], candidate["contentHash"]],
        "recommendation": recommendation,
        "target": [target["cardId"], target["revision"], target["contentHash"]] if target else None,
    }
    item: dict[str, Any] = {
        "proposalId": "consolidation-" + _canonical_hash(material)[:40],
        "recommendation": recommendation,
        "candidate": _safe_ref(candidate),
        "suggestedKind": str(candidate["suggestedKind"]),
        "confidence": max(0, min(100, int(confidence))),
        "reason": reason,
        "evidence": {
            "candidateSubjectDigest": str(candidate["subjectDigest"]),
            "matchingTokenCount": int(matching_token_count),
        },
    }
    if target is not None:
        item["target"] = _safe_ref(target)
        item["evidence"]["targetSubjectDigest"] = str(target["subjectDigest"])
    return item


def plan(
    records: Sequence[Mapping[str, Any]],
    scope: Mapping[str, Any],
    now: datetime | str,
    *,
    max_proposals: int = 24,
    stale_after_days: int | None = None,
) -> dict[str, Any]:
    """Return bounded suggestions without performing or scheduling a mutation.

    ``records`` may contain full card text in-process only.  The returned plan
    intentionally exposes no title, body, prompt, session, or scope key.
    """

    scope_kind, scope_key = _scope(scope)
    privacy_class = _requested_privacy(scope)
    current_time = _normalize_now(now)
    if isinstance(max_proposals, bool) or not isinstance(max_proposals, int) or not 1 <= max_proposals <= 64:
        raise ValueError("max_proposals must be between 1 and 64")
    if stale_after_days is not None and (
        isinstance(stale_after_days, bool) or not isinstance(stale_after_days, int) or not 1 <= stale_after_days <= 3650
    ):
        raise ValueError("stale_after_days must be between 1 and 3650 when supplied")

    normalized = [item for value in records if isinstance(value, Mapping) if (item := _record(value)) is not None]
    in_scope = [
        item
        for item in normalized
        if item["scope"] == {"kind": scope_kind, "key": scope_key} and item["privacyClass"] == privacy_class
    ]
    candidates = sorted(
        (item for item in in_scope if item["source"] in _CANDIDATE_SOURCES and item["kind"] != "decision"),
        key=lambda item: item["cardId"],
    )
    current = sorted(
        (
            item
            for item in in_scope
            if item["source"] == _CURRENT_SOURCE and item["kind"] != "decision" and item["suggestedKind"] != "decision"
        ),
        key=lambda item: (item["cardId"], item["revision"]),
    )
    proposals: list[dict[str, Any]] = []
    omitted = {"invalid": len(records) - len(normalized), "outOfScope": len(normalized) - len(in_scope), "decision": 0, "bounded": 0}
    stale_cutoff = current_time - timedelta(days=stale_after_days) if stale_after_days is not None else None

    for candidate in candidates:
        if len(proposals) >= max_proposals:
            omitted["bounded"] += 1
            continue
        if candidate["suggestedKind"] == "decision":
            omitted["decision"] += 1
            proposals.append(
                _proposal(
                    candidate,
                    "keep_for_review",
                    confidence=50,
                    reason="decision suggestions remain receipt-bound and are excluded from automatic consolidation",
                )
            )
            continue
        eligible = [
            target
            for target in current
            if target["suggestedKind"] == candidate["suggestedKind"] and _same_scope_and_privacy(candidate, target)
        ]
        exact = next((target for target in eligible if target["subjectDigest"] == candidate["subjectDigest"]), None)
        if exact is not None:
            proposals.append(
                _proposal(
                    candidate,
                    "archive_exact_duplicate_candidate",
                    confidence=98,
                    reason="same normalized subject, scope, privacy class, and intended memory kind as an active record",
                    target=exact,
                )
            )
            continue
        near_matches = [(_near_score(candidate, target), target) for target in eligible]
        near_matches = [item for item in near_matches if item[0][1] >= 2 and item[0][0] >= 0.34]
        if near_matches:
            (score, overlap), target = max(near_matches, key=lambda item: (item[0][0], item[0][1], item[1]["cardId"]))
            proposals.append(
                _proposal(
                    candidate,
                    "merge_with_active",
                    confidence=round(min(88, 48 + score * 60)),
                    reason="similar subject in the same scope and privacy class; review before any merge or edit",
                    target=target,
                    matching_token_count=overlap,
                )
            )
            continue
        if stale_cutoff is not None and candidate["createdAt"] is not None and candidate["createdAt"] <= stale_cutoff:
            proposals.append(
                _proposal(
                    candidate,
                    "archive_stale_candidate",
                    confidence=62,
                    reason="candidate exceeds the explicitly requested review age; moving it requires user confirmation",
                )
            )
            continue
        proposals.append(
            _proposal(
                candidate,
                "keep_for_review",
                confidence=50,
                reason="no safe duplicate or merge target was found; keep it available for review",
            )
        )

    return {
        "ok": True,
        "schema": SCHEMA,
        "scope": {"kind": scope_kind, "scopeRef": _canonical_hash({"scopeKey": scope_key})},
        "privacyClass": privacy_class,
        "proposals": proposals,
        "omitted": omitted,
        "rawTranscriptStored": False,
        "rawPromptStored": False,
        "directDurableWrite": False,
        "requiresUserConfirmation": True,
        "decisionHandling": "receipt_bound_excluded_from_automatic_consolidation",
    }
