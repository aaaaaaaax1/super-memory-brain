"""Regression coverage for the isolated LongMemEval-V2 Super Brain adapter."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from longmemeval_v2_adapter import (
    IsolatedLongMemEvalV2Store,
    LongMemEvalV2AdapterError,
    _context_item_token_cost,
)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def trajectory() -> dict[str, object]:
    return {
        "id": "web-atlas-001",
        "domain": "web",
        "environment": "atlas",
        "goal": "Configure the Atlas deployment terminal.",
        "outcome": "success",
        "start_url": "https://atlas.example/start",
        "states": [
            {
                "state_index": 0,
                "step": 0,
                "url": "https://atlas.example/start",
                "action": None,
                "thought": "Inspect the deployment settings.",
                "accessibility_tree": "Atlas deployment terminal uses the northstar channel.",
                "screenshot": "screenshots/web-atlas-001/0.png",
            },
            {
                "state_index": 1,
                "step": 1,
                "url": "https://atlas.example/deploy",
                "action": "select northstar",
                "thought": "Apply the verified terminal channel.",
                "accessibility_tree": "Deployment confirmation: northstar is selected.",
                "screenshot": "screenshots/web-atlas-001/1.png",
            },
        ],
    }


def write_test_corpus(state_root: Path) -> Path:
    corpus_path = state_root.parent / "official-trajectories.jsonl"
    corpus_path.parent.mkdir(parents=True, exist_ok=True)
    corpus_path.write_text('{"fixture":"longmemeval-v2-trajectory-only"}\n', encoding="utf-8")
    return corpus_path


def build_store(
    state_root: Path,
    *,
    corpus_path: Path | None = None,
    corpus_sha256: str | None = None,
    retrieval_max_tokens: int = 500,
) -> IsolatedLongMemEvalV2Store:
    corpus_path = corpus_path or write_test_corpus(state_root)
    return IsolatedLongMemEvalV2Store(
        package_root=ROOT,
        state_root=state_root,
        run_id="adapter-regression",
        domain="web",
        corpus_sha256=corpus_sha256 or sha256_file(corpus_path),
        corpus_path=corpus_path,
        harness_commit="6f020ac2fc3275e46c706d3406e02c3ed79b7be2",
        dataset_revision="f152293e235517d504809563c833d7190b8c713b",
        retrieval_max_tokens=retrieval_max_tokens,
    )


def observed_trajectory(trajectory_id: str, goal: str, observations: list[str]) -> dict[str, object]:
    return {
        "id": trajectory_id,
        "domain": "web",
        "environment": "regression",
        "goal": goal,
        "outcome": "success",
        "states": [
            {
                "state_index": index,
                "step": index,
                "url": f"https://example.test/{trajectory_id}/{index}",
                "action": "inspect observed state",
                "thought": "Record the observed state without evaluator labels.",
                "accessibility_tree": observation,
            }
            for index, observation in enumerate(observations)
        ],
    }


def test_isolated_ingestion_and_recall() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        active_memory = ROOT / "private-state" / "shared" / "sandglass.txt"
        active_before = sha256_file(active_memory) if active_memory.is_file() else ""
        store = build_store(state_root)
        store.insert(trajectory())
        before_query = sha256_file(state_root / "shared" / "sandglass.txt")
        context = store.query("Which Atlas deployment terminal channel is selected?")
        after_query = sha256_file(state_root / "shared" / "sandglass.txt")
        context_text = "\n".join(item["value"] for item in context)

        assert context and context[0]["type"] == "text"
        assert len(context) >= 2
        assert "[SUPER_BRAIN_LME_V2_GROUNDING]" in context_text
        assert "[OBSERVED trajectory_id=web-atlas-001" in context_text
        assert "field=" in context_text
        assert "northstar" in context_text.lower()
        assert before_query == after_query
        assert (state_root / "shared" / "sandglass.db").is_file()
        connection = sqlite3.connect(state_root / "shared" / "sandglass.db")
        try:
            directory_count = int(connection.execute("SELECT COUNT(*) FROM lme_trajectory_records").fetchone()[0])
        finally:
            connection.close()
        metadata = json.loads((state_root / "adapter-metadata.json").read_text(encoding="utf-8"))
        assert metadata["trajectoryCount"] == 1
        assert metadata["recordCount"] >= 3
        assert directory_count == metadata["recordCount"]
        assert metadata["retrievalStrategy"] == "trajectory_first"
        assert metadata["trajectoryImagesOmitted"] == 2
        assert metadata["corpusBindingVerified"] is True
        assert metadata["retrievalMaxTokens"] == 500
        assert metadata["rawPromptStored"] is False
        assert metadata["rawAnswerStored"] is False
        active_after = sha256_file(active_memory) if active_memory.is_file() else ""
        assert active_after == active_before


def test_adapter_rejects_label_leakage_and_root_reuse() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        store = build_store(state_root)
        labeled = trajectory()
        labeled["answer"] = "northstar"
        try:
            store.insert(labeled)
        except LongMemEvalV2AdapterError as exc:
            assert "forbidden evaluation label" in str(exc)
        else:
            raise AssertionError("Adapter accepted a trajectory carrying an answer label.")

        store.insert(trajectory())
        try:
            build_store(state_root)
        except LongMemEvalV2AdapterError as exc:
            assert "Refusing to reuse" in str(exc)
        else:
            raise AssertionError("Adapter reused an existing benchmark memory store.")


def test_adapter_rejects_mismatched_corpus_binding() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        corpus_path = write_test_corpus(state_root)
        try:
            build_store(state_root, corpus_path=corpus_path, corpus_sha256="0" * 64)
        except LongMemEvalV2AdapterError as exc:
            assert "corpus_path SHA-256" in str(exc)
        else:
            raise AssertionError("Adapter accepted a corpus path whose hash did not match the configuration.")
        try:
            IsolatedLongMemEvalV2Store(
                package_root=ROOT,
                state_root=state_root,
                run_id="missing-corpus-path",
                domain="web",
                corpus_sha256=sha256_file(corpus_path),
                corpus_path=None,
                harness_commit="6f020ac2fc3275e46c706d3406e02c3ed79b7be2",
                dataset_revision="f152293e235517d504809563c833d7190b8c713b",
            )
        except LongMemEvalV2AdapterError as exc:
            assert "corpus_path" in str(exc)
        else:
            raise AssertionError("Adapter accepted a missing corpus path.")


def test_adapter_field_chunks_oversized_accessibility_tree_and_recalls_evidence() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        store = build_store(state_root)
        oversized = trajectory()
        oversized["id"] = "web-atlas-oversized"
        oversized["states"] = [
            {
                "state_index": 99,
                "step": 99,
                "url": "https://atlas.example/oversized",
                "action": "inspect oversized accessibility tree",
                "thought": "Keep the field attribution on every fragment.",
                "accessibility_tree": ("ordinary-node " * 16_000)
                + "oversized-evidence-marker northstar-terminal",
            }
        ]

        store.insert(oversized)
        records = [
            line.rstrip("\r\n").split(" | ", 2)[2]
            for line in (state_root / "shared" / "sandglass.txt").read_text(encoding="utf-8").splitlines()
        ]
        tree_records = [record for record in records if "field=accessibility_tree" in record]
        assert len(tree_records) > 1
        assert all("trajectory_id=web-atlas-oversized" in record for record in tree_records)
        assert all("state_position=0" in record and "field_chunk=" in record for record in tree_records)
        assert all(len(record) <= store.max_record_chars for record in records)
        assert "oversized-evidence-marker" in "\n".join(tree_records)

        context = store.query("Where is the oversized evidence marker?")
        assert context and "oversized-evidence-marker" in "\n".join(item["value"] for item in context)


def test_adapter_projects_observed_ui_control_inventory_without_absence_claims() -> None:
    tree = "\n".join(
        (
            "[136] LabelText '', visible",
            "  StaticText 'Title'",
            "[138] textbox 'Title This field is required.', visible, required",
            "[141] LabelText '', visible",
            "  StaticText 'Body'",
            "[143] textbox 'Body', visible, describedby='submission_body_help'",
            "[277] LabelText '', visible",
            "  StaticText 'Forum'",
            "[380] combobox 'funny' value='funny', clickable, visible, hasPopup='menu', expanded=False",
        )
    )
    changed_tree = tree.replace("'funny' value='funny'", "'serious' value='serious'")
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        store = build_store(state_root)
        observed = trajectory()
        observed["id"] = "web-form-inventory"
        observed["states"] = [
            {
                "state_index": 0,
                "step": 0,
                "action": "open a forum post submission form",
                "accessibility_tree": tree,
            },
            {"state_index": 1, "step": 1, "accessibility_tree": tree},
            {"state_index": 2, "step": 2, "accessibility_tree": changed_tree},
        ]

        store.insert(observed)
        records = [
            line.rstrip("\r\n").split(" | ", 2)[2]
            for line in (state_root / "shared" / "sandglass.txt").read_text(encoding="utf-8").splitlines()
        ]
        inventory_records = [record for record in records if "field=ui_control_inventory" in record]
        inventory_text = "\n".join(inventory_records)
        metadata = json.loads((state_root / "adapter-metadata.json").read_text(encoding="utf-8"))

        assert len(inventory_records) == 2
        assert '"label":"Title","controlRole":"textbox"' in inventory_text
        assert '"label":"Body","controlRole":"textbox","controlName":"Body"' in inventory_text
        assert '"label":"Forum","controlRole":"combobox","controlName":"funny","value":"funny"' in inventory_text
        assert '"value":null' not in inventory_text
        assert "absent" not in inventory_text.lower()
        assert metadata["uiControlInventoryCount"] == 2
        assert metadata["uiControlInventoryFieldCount"] == 6
        assert metadata["uiControlInventoryDuplicateSuppressed"] == 1
        context = store.query("Which Forum combobox has funny selected?")
        context_text = "\n".join(item["value"] for item in context)
        assert context and "[SUPER_BRAIN_LME_V2_UI_EVIDENCE]" in context_text
        assert "label=Forum role=combobox name=funny value=funny" in context_text


def test_adapter_pairs_trajectory_metadata_with_state_evidence_and_keeps_diversity() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        store = build_store(state_root)
        store.insert(
            observed_trajectory(
                "web-northbridge",
                "Complete the Northbridge migration.",
                ["Northbridge migration requires the cobalt proof token."],
            )
        )
        store.insert(
            observed_trajectory(
                "web-ember",
                "Complete the Ember rollback.",
                ["Ember rollback requires the amber courier gate."],
            )
        )

        context = store.query(
            "Which proof token is required for the Northbridge migration and which gate is required for the Ember rollback?"
        )
        evidence = [item["value"] for item in context[1:]]
        text = "\n".join(evidence)
        selected_trajectories = set(re.findall(r"trajectory_id=([^\s\]]+)", text))

        assert len(evidence) <= 4
        assert len("\n".join(item["value"] for item in context)) <= 2_000
        assert {"web-northbridge", "web-ember"}.issubset(selected_trajectories)
        assert "goal=Complete the Northbridge migration." in text
        assert "goal=Complete the Ember rollback." in text
        assert "cobalt proof token" in text
        assert "amber courier gate" in text
        assert all("[OBSERVED trajectory_id=" in item for item in evidence)


def test_adapter_keeps_multiple_state_facts_when_one_trajectory_is_sufficient() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        store = build_store(state_root)
        store.insert(
            observed_trajectory(
                "web-northbridge-release",
                "Document the Northbridge release change.",
                [
                    "Northbridge release change observed value cobalt-stage.",
                    "Northbridge release change observed value amber-gate.",
                ],
            )
        )

        context = store.query("Which observed values are recorded for the Northbridge release change?")
        text = "\n".join(item["value"] for item in context)

        assert "goal=Document the Northbridge release change." in text
        assert "cobalt-stage" in text
        assert "amber-gate" in text
        assert text.count("trajectory_id=web-northbridge-release") >= 3


def test_adapter_enforces_aggregate_context_token_budget() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        store = build_store(state_root, retrieval_max_tokens=220)
        store.insert(
            observed_trajectory(
                "web-budgeted-evidence",
                "Inspect the budgeted evidence packet.",
                [
                    "Budgeted evidence marker " + ("cobalt signal " * 48),
                    "Second budgeted evidence marker " + ("amber signal " * 48),
                ],
            )
        )

        context = store.query("Which budgeted evidence markers were observed?")
        total_cost = sum(_context_item_token_cost(item["value"]) for item in context)

        assert len(context) >= 2
        assert total_cost <= store.retrieval_max_tokens
        assert any("[OBSERVED trajectory_id=web-budgeted-evidence" in item["value"] for item in context[1:])


def _ui_inventory_record(trajectory_id: str, label: str, value: str) -> str:
    inventory = json.dumps(
        [{"label": label, "controlRole": "combobox", "controlName": value, "value": value}],
        ensure_ascii=True,
        separators=(",", ":"),
    )
    return (
        "[SESSION][VERIFIED][BENCHMARK] benchmark=longmemeval-v2 "
        f"trajectory_id={trajectory_id} state_position=0 field=ui_control_inventory "
        f"field_chunk=1/1 controls={inventory}"
    )


def test_adapter_recalls_late_ui_inventory_records_through_fts() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        store = build_store(state_root)
        for index in range(1024):
            store._append_record(_ui_inventory_record(f"web-early-{index}", f"Early {index}", "quiet"))
        store._append_record(_ui_inventory_record("web-late-event", "Event", "afterglow"))

        context = store.query("Which Event combobox has afterglow selected?")
        text = "\n".join(item["value"] for item in context)

        assert "[SUPER_BRAIN_LME_V2_UI_EVIDENCE]" in text
        assert "trajectory_id=web-late-event" in text
        assert "label=Event role=combobox name=afterglow value=afterglow" in text


def test_adapter_builds_a_shared_index_once_under_parallel_queries() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v2-") as directory:
        state_root = Path(directory) / "phase8-longmemeval-v2" / "run-web"
        store = build_store(state_root)
        store.insert(trajectory())
        query = "Which Atlas deployment terminal channel is selected?"
        with ThreadPoolExecutor(max_workers=4) as executor:
            contexts = list(executor.map(store.query, [query] * 8))
        assert all(contexts)
        assert store.status()["indexReady"] is True
        assert all(len(context) >= 2 for context in contexts)


def main() -> None:
    test_isolated_ingestion_and_recall()
    test_adapter_rejects_label_leakage_and_root_reuse()
    test_adapter_rejects_mismatched_corpus_binding()
    test_adapter_field_chunks_oversized_accessibility_tree_and_recalls_evidence()
    test_adapter_projects_observed_ui_control_inventory_without_absence_claims()
    test_adapter_pairs_trajectory_metadata_with_state_evidence_and_keeps_diversity()
    test_adapter_keeps_multiple_state_facts_when_one_trajectory_is_sufficient()
    test_adapter_enforces_aggregate_context_token_budget()
    test_adapter_recalls_late_ui_inventory_records_through_fts()
    test_adapter_builds_a_shared_index_once_under_parallel_queries()
    print("runtime_longmemeval_v2_adapter_regression: PASS")


if __name__ == "__main__":
    main()
