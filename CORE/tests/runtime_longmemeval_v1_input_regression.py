"""Regression coverage for LongMemEval v1 paired input preparation."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

import longmemeval_v1_input as lme


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=True), encoding="utf-8")


def dataset(count: int = 500) -> list[dict[str, object]]:
    values: list[dict[str, object]] = []
    for index in range(count):
        marker = f"unique-marker-{index:03d}"
        values.append(
            {
                "question_id": f"case-{index:03d}",
                "question_type": "single-session-user",
                "question": f"What value was recorded for {marker}?",
                "answer": index if index == 1 else f"value-{index:03d}",
                "question_date": "2025-01-02",
                "haystack_session_ids": [f"session-{index:03d}"],
                "haystack_dates": ["2025-01-01"],
                "haystack_sessions": [
                    ([{"role": "user", "content": "   "}] if index == 2 else []) + [
                        {"role": "user", "content": f"Please remember {marker}."},
                        {
                            "role": "assistant",
                            "content": f"The value for {marker} is value-{index:03d}.",
                            "has_answer": True,
                        },
                    ]
                ],
                "answer_session_ids": [f"session-{index:03d}"],
            }
        )
    return values


def make_package(root: Path) -> Path:
    package = root / "package"
    (package / "runtime").mkdir(parents=True)
    shutil.copy2(ROOT / "manifest.json", package / "manifest.json")
    shutil.copy2(ROOT / "memory-policy.json", package / "memory-policy.json")
    shutil.copy2(ROOT / "runtime" / "brain_core.py", package / "runtime" / "brain_core.py")
    return package


def make_harness(root: Path) -> tuple[Path, str]:
    harness = root / "LongMemEval"
    harness.mkdir()
    (harness / "README.md").write_text("fixture", encoding="utf-8")
    for command in (
        ("git", "init"),
        ("git", "config", "user.email", "test@example.invalid"),
        ("git", "config", "user.name", "LongMemEval test"),
        ("git", "add", "README.md"),
        ("git", "commit", "-m", "fixture"),
    ):
        subprocess.run(command, cwd=harness, check=True, capture_output=True, text=True)
    head = subprocess.run(("git", "rev-parse", "HEAD"), cwd=harness, check=True, capture_output=True, text=True).stdout.strip()
    return harness, head


def make_source(data_path: Path, cases: list[dict[str, object]]) -> None:
    write_json(data_path, cases)
    write_json(
        data_path.parent / "super-brain-source-manifest.json",
        {
            "schema": lme.SOURCE_MANIFEST_SCHEMA,
            "benchmarkId": lme.BENCHMARK_ID,
            "variant": lme.BENCHMARK_VARIANT,
            "sourceUrl": lme.OFFICIAL_DATA_URL,
            "dataSha256": sha256_file(data_path),
            "caseCount": lme.EXPECTED_CASE_COUNT,
        },
    )


def assert_raises(expected: str, callback) -> None:
    try:
        callback()
    except lme.LongMemEvalV1InputError as error:
        assert expected in str(error), str(error)
    else:
        raise AssertionError(f"Expected LongMemEvalV1InputError containing {expected!r}.")


def test_prepares_full_private_pair_without_label_or_cross_case_leakage() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v1-") as directory:
        root = Path(directory)
        package = make_package(root)
        harness, head = make_harness(root)
        data_path = root / "source" / "longmemeval_s_cleaned.json"
        make_source(data_path, dataset())
        original_commit = lme.OFFICIAL_COMMIT
        lme.OFFICIAL_COMMIT = head
        try:
            output_root = package / "private-state" / "workspace" / "phase8-longmemeval-v1"
            result = lme.prepare_answer_inputs(
                package_root=package,
                harness_root=harness,
                data_path=data_path,
                output_root=output_root,
                run_id="regression-full",
                model="gpt-5.6-terra",
                reasoning_effort="max",
                max_output_tokens=512,
                timeout_seconds=30,
                batch_size=5,
                max_batch_attempts=1,
            )
        finally:
            lme.OFFICIAL_COMMIT = original_commit

        assert result["caseCount"] == 500
        assert result["modelRequestCount"] == 0
        assert result["labelsStripped"] == 500
        assert result["emptyTurnsSkipped"] == 1
        run_root = output_root / "regression-full"
        baseline = json.loads((run_root / "baseline-answer-input.json").read_text(encoding="utf-8"))
        treatment = json.loads((run_root / "treatment-answer-input.json").read_text(encoding="utf-8"))
        contract = json.loads((run_root / "pair-contract.json").read_text(encoding="utf-8"))
        selection = json.loads((run_root / "selection-manifest.json").read_text(encoding="utf-8"))
        assert len(baseline["cases"]) == 500
        assert len(treatment["cases"]) == 500
        assert all(case["retrievedContext"] == "" for case in baseline["cases"])
        assert contract["generationBudget"]["maxBatchAttempts"] == 1
        assert contract["generationBudget"]["retrievalTopK"] == 10
        assert selection["caseCount"] == 500
        first_context = treatment["cases"][0]["retrievedContext"]
        second_context = treatment["cases"][1]["retrievedContext"]
        assert "unique-marker-000" in first_context
        assert "has_answer" not in first_context.lower()
        assert "unique-marker-000" not in second_context
        assert treatment["cases"][1]["reference"] == "1"
        assert not list(run_root.glob("lme-v1-scratch-*"))


def test_preflight_rejects_dirty_harness_bad_source_count_duplicate_and_reordered_data() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v1-guards-") as directory:
        root = Path(directory)
        package = make_package(root)
        harness, head = make_harness(root)
        data_path = root / "source" / "longmemeval_s_cleaned.json"
        output_root = package / "private-state" / "workspace" / "phase8-longmemeval-v1"
        original_commit = lme.OFFICIAL_COMMIT
        lme.OFFICIAL_COMMIT = head
        try:
            make_source(data_path, dataset(499))
            assert_raises("LME_V1_CASE_COUNT_INVALID", lambda: lme._preflight(package, harness, data_path, output_root))

            cases = dataset()
            cases[-1]["question_id"] = cases[0]["question_id"]
            make_source(data_path, cases)
            assert_raises("LME_V1_CASE_ID_DUPLICATE", lambda: lme._preflight(package, harness, data_path, output_root))

            cases = dataset()
            make_source(data_path, cases)
            cases.reverse()
            write_json(data_path, cases)
            assert_raises("LME_V1_SOURCE_SHA_MISMATCH", lambda: lme._preflight(package, harness, data_path, output_root))

            make_source(data_path, dataset())
            (harness / "untracked.txt").write_text("dirty", encoding="utf-8")
            assert_raises("LME_V1_HARNESS_DIRTY", lambda: lme._preflight(package, harness, data_path, output_root))
        finally:
            lme.OFFICIAL_COMMIT = original_commit


def test_prepare_rejects_history_evaluation_labels_other_than_has_answer() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-v1-label-") as directory:
        root = Path(directory)
        package = make_package(root)
        harness, head = make_harness(root)
        cases = dataset()
        cases[0]["haystack_sessions"][0][0]["answer"] = "leak"
        data_path = root / "source" / "longmemeval_s_cleaned.json"
        make_source(data_path, cases)
        original_commit = lme.OFFICIAL_COMMIT
        lme.OFFICIAL_COMMIT = head
        try:
            output_root = package / "private-state" / "workspace" / "phase8-longmemeval-v1"
            assert_raises(
                "LME_V1_HISTORY_LABEL_LEAK",
                lambda: lme.prepare_answer_inputs(
                    package_root=package,
                    harness_root=harness,
                    data_path=data_path,
                    output_root=output_root,
                    run_id="label-leak",
                    model="gpt-5.6-terra",
                    reasoning_effort="max",
                    max_output_tokens=512,
                    timeout_seconds=30,
                    batch_size=5,
                    max_batch_attempts=1,
                ),
            )
        finally:
            lme.OFFICIAL_COMMIT = original_commit


if __name__ == "__main__":
    test_prepares_full_private_pair_without_label_or_cross_case_leakage()
    test_preflight_rejects_dirty_harness_bad_source_count_duplicate_and_reordered_data()
    test_prepare_rejects_history_evaluation_labels_other_than_has_answer()
    print("runtime_longmemeval_v1_input_regression: ok")
