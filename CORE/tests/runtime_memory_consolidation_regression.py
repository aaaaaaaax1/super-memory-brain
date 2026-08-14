from __future__ import annotations

from datetime import UTC, datetime
import hashlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from memory_consolidation import plan


def record(
    card_id: str,
    *,
    source: str,
    subject: str,
    kind: str = "note",
    suggested_kind: str = "experience",
    scope: dict[str, str] | None = None,
    privacy: str = "private",
    created_at: str = "2026-07-01T00:00:00Z",
) -> dict[str, object]:
    return {
        "cardId": card_id,
        "revision": 1,
        "contentHash": hashlib.sha256(card_id.encode("utf-8")).hexdigest(),
        "kind": kind,
        "lifecycle": "proposed" if source == "staged_reflection" else "active",
        "authority": "system" if source == "staged_reflection" else "user_confirmed",
        "privacyClass": privacy,
        "scope": scope or {"kind": "global", "key": "user"},
        "source": source,
        "suggestedKind": suggested_kind,
        "subjectText": subject,
        "createdAt": created_at,
    }


def assert_no_raw_text(value: object, forbidden: list[str]) -> None:
    rendered = repr(value)
    for text in forbidden:
        assert text not in rendered


def main() -> None:
    now = datetime(2026, 7, 31, tzinfo=UTC)
    scope = {"kind": "global", "key": "user"}
    exact_subject = "Release archive must include the installer and verification report"
    near_subject = "Release archive include installer plus verification report before delivery"
    isolated_subject = "Foreign workspace must never join this plan"
    records = [
        record("a", source="quick_capture", subject=exact_subject),
        record("b", source="current", subject=exact_subject, kind="experience", suggested_kind="experience"),
        record("c", source="quick_capture", subject=near_subject),
        record("d", source="current", subject="Release archive verify installer and report before delivery", kind="experience", suggested_kind="experience"),
        record("e", source="quick_capture", subject=isolated_subject, scope={"kind": "workspace", "key": "foreign"}),
        record("f", source="quick_capture", subject="Old pending item", created_at="2025-01-01T00:00:00Z"),
        record("g", source="quick_capture", subject="Receipt-bound decision", suggested_kind="decision"),
        record("h", source="quick_capture", subject="Shared must not join", privacy="shared"),
    ]

    first = plan(records, scope, now)
    assert first["schema"] == "super-brain.memory-consolidation-plan.v1"
    assert first["rawTranscriptStored"] is False
    assert first["rawPromptStored"] is False
    assert first["directDurableWrite"] is False
    assert first["requiresUserConfirmation"] is True
    assert first["privacyClass"] == "private"
    assert [item["recommendation"] for item in first["proposals"]] == [
        "archive_exact_duplicate_candidate",
        "merge_with_active",
        "keep_for_review",
        "keep_for_review",
    ]
    assert first["omitted"]["outOfScope"] >= 2
    assert first["omitted"]["decision"] == 1
    assert all("cardRef" in item["candidate"] and "cardId" not in item["candidate"] for item in first["proposals"])
    assert_no_raw_text(first, [exact_subject, near_subject, isolated_subject, "Old pending item", "Receipt-bound decision"])

    second = plan(records, scope, now, stale_after_days=30)
    old = next(
        item
        for item in second["proposals"]
        if item["candidate"]["contentHash"] == hashlib.sha256(b"f").hexdigest()
    )
    assert old["recommendation"] == "archive_stale_candidate"
    assert second["proposals"][0]["proposalId"] == first["proposals"][0]["proposalId"]

    changed_privacy = [*records, record("i", source="current", subject=exact_subject, kind="experience", suggested_kind="experience", privacy="shared")]
    isolated = plan(changed_privacy, scope, now)
    assert isolated["proposals"][0]["recommendation"] == "archive_exact_duplicate_candidate"
    assert isolated["proposals"][0]["target"]["contentHash"] == hashlib.sha256(b"b").hexdigest()

    print("RUNTIME_MEMORY_CONSOLIDATION_REGRESSION_OK")


if __name__ == "__main__":
    main()
