"""Regression coverage for private LongMemEval-V2 holdout selection."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from longmemeval_v2_holdout import HoldoutError, mark_completed_diagnostic, mark_incomplete_diagnostic, prepare_holdout, registry_status


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def write_jsonl(path: Path, values: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(value) for value in values) + "\n", encoding="utf-8")


def case_id_hash(case_id: str) -> str:
    return hashlib.sha256(("longmemeval-v2-case-id-v1\0" + case_id).encode("utf-8")).hexdigest()


def test_private_stratified_holdout_excludes_prior_cases_and_reserves_results() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-holdout-") as directory:
        root = Path(directory)
        questions_path = root / "source" / "questions.jsonl"
        haystacks_path = root / "source" / "haystacks.json"
        source_manifest_path = root / "source" / "source-manifest.json"
        previous_path = root / "previous" / "questions.json"
        contract_path = root / "previous" / "run-contract.json"
        registry_path = root / "registry" / "holdouts.json"
        output_dir = root / "holdout-web"
        questions: list[dict[str, object]] = []
        haystacks: dict[str, list[str]] = {}
        for question_type in ("dynamic-environment", "procedure"):
            for index in range(3):
                case_id = f"web-{question_type}-{index}"
                questions.append(
                    {
                        "id": case_id,
                        "domain": "web",
                        "question_type": question_type,
                        "question": {"text": "private question"},
                        "answer": "private answer",
                        "eval_function": "norm_phrase_set_match",
                    }
                )
                haystacks[case_id] = [f"trajectory-{case_id}"]
        write_jsonl(questions_path, questions)
        write_json(haystacks_path, haystacks)
        write_json(source_manifest_path, {"revision": "pinned"})
        write_json(previous_path, [questions[0]])
        write_json(contract_path, {"questionIds": [questions[3]["id"]]})

        preview = prepare_holdout(
            questions_path=questions_path,
            haystacks_path=haystacks_path,
            source_manifest_path=source_manifest_path,
            output_dir=output_dir,
            registry_path=registry_path,
            domain="web",
            per_question_type=2,
            exclude_question_paths=[previous_path, contract_path],
            apply=False,
        )
        assert preview["status"] == "preview_only"
        assert not output_dir.exists()
        assert preview["caseCount"] == 4
        assert preview["setHash"] == ""
        assert preview["selectionDeferred"] is True

        result = prepare_holdout(
            questions_path=questions_path,
            haystacks_path=haystacks_path,
            source_manifest_path=source_manifest_path,
            output_dir=output_dir,
            registry_path=registry_path,
            domain="web",
            per_question_type=2,
            exclude_question_paths=[previous_path, contract_path],
            apply=True,
        )
        assert result["status"] == "prepared"
        assert len(result["setHash"]) == 64
        assert result["selectionDeferred"] is False
        manifest = json.loads((output_dir / "selection-manifest.json").read_text(encoding="utf-8"))
        selected = json.loads((output_dir / "questions.json").read_text(encoding="utf-8"))
        assert manifest["schema"] == "super-brain.longmemeval-v2-holdout-selection.v1"
        assert manifest["caseCount"] == 4
        assert manifest["questionTypeCounts"] == {"dynamic-environment": 2, "procedure": 2}
        assert "answer" not in manifest
        assert questions[0]["id"] not in {row["id"] for row in selected}
        assert case_id_hash(str(questions[0]["id"])) not in manifest["caseIdHashes"]
        assert case_id_hash(str(questions[3]["id"])) not in manifest["caseIdHashes"]
        assert registry_status(registry_path)["reservedCaseCount"] == 4
        marked = mark_incomplete_diagnostic(
            registry_path,
            set_hash=result["setHash"],
            reason="bridge_incomplete_response",
        )
        assert marked["status"] == "consumed_incomplete_diagnostic"
        assert registry_status(registry_path)["statusCounts"] == {"consumed_incomplete_diagnostic": 1}

        try:
            prepare_holdout(
                questions_path=questions_path,
                haystacks_path=haystacks_path,
                source_manifest_path=source_manifest_path,
                output_dir=output_dir,
                registry_path=registry_path,
                domain="web",
                per_question_type=2,
                exclude_question_paths=[previous_path, contract_path],
                apply=True,
            )
        except HoldoutError as exc:
            assert exc.code in {"HOLDOUT_INSUFFICIENT_CATEGORY_CAPACITY", "HOLDOUT_NO_CANDIDATES", "HOLDOUT_OUTPUT_EXISTS"}
        else:
            raise AssertionError("Holdout selector reused a reserved or existing output.")


def test_completed_holdout_requires_a_bound_evidence_hash() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-lme-holdout-") as directory:
        root = Path(directory)
        questions_path = root / "source" / "questions.jsonl"
        haystacks_path = root / "source" / "haystacks.json"
        source_manifest_path = root / "source" / "source-manifest.json"
        registry_path = root / "registry" / "holdouts.json"
        output_dir = root / "holdout-web"
        rows = [
            {
                "id": f"web-case-{index}",
                "domain": "web",
                "question_type": "procedure",
                "question": {"text": "private question"},
                "answer": "private answer",
                "eval_function": "norm_phrase_set_match",
            }
            for index in range(2)
        ]
        write_jsonl(questions_path, rows)
        write_json(haystacks_path, {str(row["id"]): ["trajectory"] for row in rows})
        write_json(source_manifest_path, {"revision": "pinned"})
        result = prepare_holdout(
            questions_path=questions_path,
            haystacks_path=haystacks_path,
            source_manifest_path=source_manifest_path,
            output_dir=output_dir,
            registry_path=registry_path,
            domain="web",
            per_question_type=2,
            exclude_question_paths=[],
            apply=True,
        )
        completed = mark_completed_diagnostic(
            registry_path,
            set_hash=result["setHash"],
            evidence_hash="b" * 64,
        )
        assert completed["status"] == "consumed_completed_diagnostic"
        assert registry_status(registry_path)["statusCounts"] == {"consumed_completed_diagnostic": 1}


def main() -> None:
    test_private_stratified_holdout_excludes_prior_cases_and_reserves_results()
    test_completed_holdout_requires_a_bound_evidence_hash()
    print("runtime_longmemeval_v2_holdout_regression: PASS")


if __name__ == "__main__":
    main()
