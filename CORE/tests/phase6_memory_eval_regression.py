from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

import phase6_memory_eval as phase6


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def expect_error(action, code: str) -> None:
    try:
        action()
    except phase6.Phase6Error as exc:
        assert exc.code == code, (exc.code, str(exc))
        return
    raise AssertionError(f"expected {code}")


def test_self_test_is_diagnostic_only() -> None:
    result = phase6.self_test(ROOT)
    assert result["ok"] is True
    assert result["status"] == "diagnostic_non_publishable"
    assert result["aggregate"]["twoFreshSealedE2EAtLeast90"] is True
    assert result["aggregate"]["status"] == "diagnostic_non_publishable"
    assert result["aggregate"]["objectiveIntelligenceScore"] is False


def test_sealed_families_are_bound_and_calibration_overlap_is_rejected() -> None:
    source = phase6._self_test_source("phase6-family-check", "family")
    sealed = phase6.seal_source(source)
    phase6.verify_sealed(sealed)

    tampered = json.loads(json.dumps(sealed))
    tampered["cases"][0]["payload"]["records"][0]["text"] = "changed after sealing"
    expect_error(lambda: phase6.verify_sealed(tampered), "SEALED_CASE_HASH_MISMATCH")

    overlap = json.loads(json.dumps(source))
    overlap["excludedFamilyHashes"] = [phase6._family_hash("atlas-family-family")]
    expect_error(lambda: phase6.seal_source(overlap), "SOURCE_FAMILY_OVERLAP")


def make_aggregate_report(binding: dict[str, str], set_name: str, family_name: str, marker_name: str) -> dict[str, object]:
    family_hash = phase6._family_hash(family_name)
    gates = [
        {"id": "oracle_at_least_95", "met": True},
        {"id": "recall_at_4_at_least_95", "met": True},
        {"id": "recall_at_10_at_least_95", "met": True},
        {"id": "category_e2e_at_least_85", "met": True},
        {"id": "unsupported_claims_at_most_1", "met": True},
        {"id": "fresh_sealed_e2e_at_least_90", "met": True},
    ]
    return {
        "schema": phase6.REPORT_SCHEMA,
        "status": "internal_acceptance_only",
        "generatedAt": phase6._utc_now(),
        "packageVersion": binding["packageVersion"],
        "evidenceBinding": binding,
        "holdout": {
            "setHash": phase6._sha256(set_name),
            "familySetHash": phase6._family_set_hash([family_hash]),
            "familyHashes": [family_hash],
            "caseCount": 1,
            "rawCasePayloadStored": False,
        },
        "privacy": {"rawCasePayloadStored": False, "rawAnswersStored": False, "realUserMemoryRead": False},
        "answerEvaluation": {
            "present": True,
            "method": "deterministic_required_phrases_and_evidence_links",
            "inputHash": phase6._sha256("input-" + set_name),
            "provenanceKind": "external_blinded_input",
            "provenanceBound": True,
            "provenanceReceiptSha256": phase6._sha256("provenance-" + set_name),
        },
        "gates": gates,
        "consumption": {"requested": True, "consumed": True, "markerFile": marker_name},
        "objectiveIntelligenceScore": False,
    }


def bind_marker(report_path: Path, marker_name: str, set_hash: str) -> None:
    marker = {
        "schema": phase6.CONSUMPTION_SCHEMA,
        "consumedAt": phase6._utc_now(),
        "setHash": set_hash,
        "reportHash": phase6._file_sha256(report_path),
        "rawCasePayloadStored": False,
    }
    write_json(report_path.parent / marker_name, marker)


def bind_registry(registry_root: Path, binding: dict[str, str], report_path: Path, set_hash: str) -> None:
    registry_root.mkdir(parents=True, exist_ok=True)
    write_json(
        registry_root / f"{set_hash}.json",
        {
            "schema": phase6.CONSUMPTION_SCHEMA,
            "status": "consumed",
            "setHash": set_hash,
            "reportHash": phase6._file_sha256(report_path),
            "runtimeBindingHash": phase6._sha256(binding),
            "rawCasePayloadStored": False,
        },
    )


def test_aggregate_requires_consumption_and_distinct_families() -> None:
    binding = phase6._current_binding(ROOT)
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-regression-") as directory:
        base = Path(directory)
        first = base / "first.report.json"
        second = base / "second.report.json"
        first_value = make_aggregate_report(binding, "set-first", "family-first", "first.marker.json")
        second_value = make_aggregate_report(binding, "set-second", "family-first", "second.marker.json")
        write_json(first, first_value)
        write_json(second, second_value)

        expect_error(
            lambda: phase6.aggregate_reports(ROOT, [first, second], base / "not-consumed.json", allow_diagnostic_synthetic=True),
            "AGGREGATE_MARKER_MISSING",
        )

        bind_marker(first, "first.marker.json", str(first_value["holdout"]["setHash"]))
        bind_marker(second, "second.marker.json", str(second_value["holdout"]["setHash"]))
        expect_error(
            lambda: phase6.aggregate_reports(ROOT, [first, second], base / "family-reuse.json", allow_diagnostic_synthetic=True),
            "AGGREGATE_FAMILY_REUSE",
        )

        second_family_hash = phase6._family_hash("family-second")
        second_value["holdout"]["familySetHash"] = phase6._family_set_hash([second_family_hash])
        second_value["holdout"]["familyHashes"] = [second_family_hash]
        write_json(second, second_value)
        bind_marker(second, "second.marker.json", str(second_value["holdout"]["setHash"]))
        result = phase6.aggregate_reports(ROOT, [first, second], base / "aggregate.json", allow_diagnostic_synthetic=True)
        assert result["twoFreshSealedE2EAtLeast90"] is True

        first_value["gates"][0]["met"] = False
        write_json(first, first_value)
        expect_error(
            lambda: phase6.aggregate_reports(ROOT, [first, second], base / "tampered.json"),
            "CONSUMPTION_MARKER_MISMATCH",
        )


def test_real_aggregate_rejects_trivial_sample_sizes() -> None:
    binding = phase6._current_binding(ROOT)
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-sample-") as directory:
        base = Path(directory)
        first = base / "first.report.json"
        second = base / "second.report.json"
        first_value = make_aggregate_report(binding, "set-small-first", "family-small-first", "first.marker.json")
        second_value = make_aggregate_report(binding, "set-small-second", "family-small-second", "second.marker.json")
        write_json(first, first_value)
        write_json(second, second_value)
        bind_marker(first, "first.marker.json", str(first_value["holdout"]["setHash"]))
        bind_marker(second, "second.marker.json", str(second_value["holdout"]["setHash"]))
        registry = base / "consumption"
        bind_registry(registry, binding, first, str(first_value["holdout"]["setHash"]))
        bind_registry(registry, binding, second, str(second_value["holdout"]["setHash"]))
        expect_error(
            lambda: phase6.aggregate_reports(
                ROOT, [first, second], base / "aggregate.json", consumption_registry_root=registry
            ),
            "AGGREGATE_SAMPLE_TOO_SMALL",
        )


def test_report_does_not_copy_raw_memory_or_absolute_marker_paths() -> None:
    source = {
        "schema": phase6.SOURCE_SCHEMA,
        "setId": "phase6-privacy-check",
        "cases": [
            {
                "id": "privacy-case",
                "familyId": "privacy-family",
                "category": "information_extraction",
                "records": [{"id": "privacy-record", "text": "PHASE6_RAW_MEMORY_SENTINEL", "layer": "project"}],
                "query": "PHASE6_RAW_MEMORY_SENTINEL",
                "expected": {
                    "evidenceIds": ["privacy-record"],
                    "answer": {"mode": "answer", "requiredPhrases": ["PHASE6_RAW_MEMORY_SENTINEL"]},
                },
            }
        ],
    }
    sealed = phase6.seal_source(source)
    answers = phase6._synthetic_answers(sealed)
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-privacy-") as directory:
        output = Path(directory) / "privacy.report.json"
        report = phase6.run_evaluation(
            ROOT,
            sealed,
            answers,
            True,
            output,
            None,
            allow_diagnostic_synthetic=True,
            consumption_registry_root=Path(directory) / "consumption",
        )
        serialized = output.read_text(encoding="utf-8")
        assert "PHASE6_RAW_MEMORY_SENTINEL" not in serialized
        assert report["status"] == "diagnostic_non_publishable"
        assert report["consumption"]["markerFile"] == "privacy.report.json.phase6-consumed.json"
        assert str(Path(directory)) not in serialized


def test_abstention_with_irrelevant_retrieval_is_a_valid_e2e_negative_case() -> None:
    source = {
        "schema": phase6.SOURCE_SCHEMA,
        "setId": "phase6-abstention-irrelevant-retrieval",
        "cases": [
            {
                "id": "abstention-case",
                "familyId": "abstention-family",
                "category": "unsupported_unknown",
                "records": [
                    {
                        "id": "abstention-unrelated",
                        "text": "[CURRENT][VERIFIED] Evaluation note abstention-case contains no assigned unavailable value.",
                        "layer": "project",
                    }
                ],
                "query": "What unavailable value is assigned to abstention-case?",
                "expected": {"evidenceIds": [], "answer": {"mode": "abstain", "requiredPhrases": []}},
            }
        ],
    }
    sealed = phase6.seal_source(source)
    answers = phase6._synthetic_answers(sealed)
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-abstention-") as directory:
        report = phase6.run_evaluation(
            ROOT,
            sealed,
            answers,
            False,
            Path(directory) / "abstention.report.json",
            None,
            allow_diagnostic_synthetic=True,
        )
    row = report["cases"][0]
    assert row["retrieval"]["expectedEvidenceCount"] == 0
    assert row["retrieval"]["retrievedEvidenceIds"]
    assert row["retrieval"]["hitAt4"] is True
    assert row["retrieval"]["hitAt10"] is True
    assert row["retrieval"]["evidenceSufficient"] is True
    assert row["answer"]["correct"] is True
    assert row["answer"]["grounded"] is True
    assert row["e2ePass"] is True
    assert report["overall"]["e2eRate"] == 1.0


def test_answer_case_requires_expected_evidence() -> None:
    source = {
        "schema": phase6.SOURCE_SCHEMA,
        "setId": "phase6-answer-needs-evidence",
        "cases": [
            {
                "id": "answer-without-evidence",
                "familyId": "answer-without-evidence-family",
                "category": "information_extraction",
                "records": [
                    {
                        "id": "unbound-record",
                        "text": "[CURRENT][VERIFIED] An unbound value is present.",
                        "layer": "project",
                    }
                ],
                "query": "What is the unbound value?",
                "expected": {"evidenceIds": [], "answer": {"mode": "answer", "requiredPhrases": ["unbound"]}},
            }
        ],
    }
    expect_error(lambda: phase6.seal_source(source), "CASE_ANSWER_EVIDENCE_REQUIRED")


def external_answers(sealed: dict[str, object], answer_input: dict[str, object]) -> dict[str, object]:
    answers = phase6._synthetic_answers(sealed)
    for case in answers["cases"]:
        case["responseModel"] = "test-model"
    case_index = {str(case["id"]): case for case in answers["cases"]}
    answers["provenance"] = {
        "schema": phase6.ANSWER_PROVENANCE_SCHEMA,
        "kind": "external_blinded_input",
        "generatorId": "phase6-regression-generator",
        "runId": "phase6-regression-run",
        "modelId": "test-model",
        "modelVersion": "test-model",
        "generatorVersion": "phase6-regression-generator-v2",
        "generatorSha256": phase6._sha256("phase6-regression-generator-v2"),
        "endpointSha256": phase6._sha256("phase6-regression-endpoint"),
        "responseReceiptSha256": phase6._sha256("phase6-regression-receipt"),
        "responseCount": len(case_index),
        "caseCount": len(case_index),
        "responseModelEvidenceSha256": phase6._answer_response_model_evidence_hash(case_index),
        "independentExecution": True,
        "expectedAnswerDataAvailable": False,
        "inputSchema": phase6.ANSWER_INPUT_SCHEMA,
        "inputHash": answer_input["inputHash"],
        "rawResponseStored": False,
    }
    return answers


def test_blinded_input_recalls_split_facts_with_aliases_and_trailing_identity_punctuation() -> None:
    source = {
        "schema": phase6.SOURCE_SCHEMA,
        "setId": "phase6-multi-fact-identity-regression",
        "cases": [
            {
                "id": "multi-fact-identity",
                "familyId": "multi-fact-identity-family",
                "category": "multi_session_reasoning",
                "records": [
                    {
                        "id": "multi-zone",
                        "text": "[CURRENT][VERIFIED] Calibration-Beta deployment zone is cal-zone-42.",
                        "layer": "decision",
                    },
                    {
                        "id": "multi-group",
                        "text": "[CURRENT][VERIFIED] Calibration-Beta review group is cal-team-43.",
                        "layer": "task",
                    },
                    {
                        "id": "multi-decoy",
                        "text": "[CURRENT][VERIFIED] Unrelated-Delta review group is wrong-team.",
                        "layer": "task",
                    },
                ],
                "query": "Give both the current deployment zone and review group for Calibration-Beta.",
                "expected": {
                    "evidenceIds": ["multi-zone", "multi-group"],
                    "answer": {"mode": "answer", "requiredPhrases": ["cal-zone-42", "cal-team-43"]},
                },
            }
        ],
    }
    sealed = phase6.seal_source(source)
    answer_input = phase6.prepare_answer_input(ROOT, sealed)
    evidence_ids = {item["id"] for item in answer_input["cases"][0]["retrievedEvidence"]}

    assert {"multi-zone", "multi-group"}.issubset(evidence_ids)
    assert "multi-decoy" not in evidence_ids


def test_blinded_input_fails_closed_when_record_ingestion_fails() -> None:
    sealed = phase6.seal_source(phase6._self_test_source("phase6-ingestion-failure", "ingestion-failure"))
    original_write_record = phase6._write_record

    def reject_record(*args, **kwargs) -> bool:
        return False

    phase6._write_record = reject_record
    try:
        expect_error(
            lambda: phase6.prepare_answer_input(ROOT, sealed),
            "ANSWER_INPUT_INGESTION_FAILED",
        )
    finally:
        phase6._write_record = original_write_record


def test_real_answer_artifact_requires_blinded_input_provenance() -> None:
    sealed = phase6.seal_source(phase6._self_test_source("phase6-provenance-check", "provenance"))
    answer_input = phase6.prepare_answer_input(ROOT, sealed)
    serialized_input = json.dumps(answer_input, ensure_ascii=False)
    assert "requiredPhrases" not in serialized_input
    assert "expected" not in serialized_input
    answers = external_answers(sealed, answer_input)
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-provenance-") as directory:
        base = Path(directory)
        expect_error(
            lambda: phase6.run_evaluation(ROOT, sealed, answers, True, base / "missing-input.json", None),
            "ANSWER_INPUT_REQUIRED",
        )
        report = phase6.run_evaluation(
            ROOT,
            sealed,
            answers,
            True,
            base / "report.json",
            None,
            answer_input,
            consumption_registry_root=base / "consumption",
        )
        assert report["status"] == "internal_acceptance_only"
        assert report["answerEvaluation"]["provenanceBound"] is True
        tampered = json.loads(json.dumps(answer_input))
        tampered["inputHash"] = "0" * 64
        expect_error(
            lambda: phase6.run_evaluation(ROOT, sealed, answers, False, base / "tampered.json", None, tampered),
            "ANSWER_INPUT_HASH_MISMATCH",
        )


def test_consumption_registry_blocks_alternate_report_paths() -> None:
    sealed = phase6.seal_source(phase6._self_test_source("phase6-consumption-check", "consumption"))
    answer_input = phase6.prepare_answer_input(ROOT, sealed)
    answers = external_answers(sealed, answer_input)
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-consumption-") as directory:
        base = Path(directory)
        registry = base / "consumption"
        phase6.run_evaluation(ROOT, sealed, answers, True, base / "first.report.json", None, answer_input, consumption_registry_root=registry)
        expect_error(
            lambda: phase6.run_evaluation(
                ROOT,
                sealed,
                answers,
                True,
                base / "alternate.report.json",
                None,
                answer_input,
                consumption_registry_root=registry,
            ),
            "HOLDOUT_ALREADY_RESERVED",
        )


def test_existing_output_does_not_reserve_holdout() -> None:
    sealed = phase6.seal_source(phase6._self_test_source("phase6-output-collision", "collision"))
    answer_input = phase6.prepare_answer_input(ROOT, sealed)
    answers = external_answers(sealed, answer_input)
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-output-") as directory:
        base = Path(directory)
        output = base / "existing.report.json"
        write_json(output, {"existing": True})
        registry = base / "consumption"
        expect_error(
            lambda: phase6.run_evaluation(
                ROOT,
                sealed,
                answers,
                True,
                output,
                None,
                answer_input,
                consumption_registry_root=registry,
            ),
            "OUTPUT_EXISTS",
        )
        assert not registry.exists()


def test_private_answer_input_preflight_rejects_expected_data() -> None:
    sealed = phase6.seal_source(phase6._self_test_source("phase6-private-preflight", "private-preflight"))
    answer_input = phase6.prepare_answer_input(ROOT, sealed)
    input_hash, cases = phase6._validate_private_answer_input(ROOT, answer_input)
    assert input_hash == answer_input["inputHash"]
    assert len(cases) == len(sealed["cases"])

    tampered = json.loads(json.dumps(answer_input))
    tampered["cases"][0]["expected"] = {"answer": "hidden"}
    tampered["inputHash"] = phase6._sha256(phase6._answer_input_descriptor(tampered))
    expect_error(lambda: phase6._validate_private_answer_input(ROOT, tampered), "ANSWER_INPUT_CASE_INVALID")


def test_private_answer_input_preflight_rejects_rehashed_unready_ingestion() -> None:
    sealed = phase6.seal_source(phase6._self_test_source("phase6-unready-ingestion", "unready-ingestion"))
    answer_input = phase6.prepare_answer_input(ROOT, sealed)
    tampered = json.loads(json.dumps(answer_input))
    tampered["cases"][0]["ingestionReady"] = False
    tampered["inputHash"] = phase6._sha256(phase6._answer_input_descriptor(tampered))
    expect_error(lambda: phase6._validate_private_answer_input(ROOT, tampered), "ANSWER_INPUT_INGESTION_FAILED")


def test_external_answer_artifact_rejects_model_provenance_drift() -> None:
    sealed = phase6.seal_source(phase6._self_test_source("phase6-model-drift", "model-drift"))
    answer_input = phase6.prepare_answer_input(ROOT, sealed)
    answers = external_answers(sealed, answer_input)
    answers["cases"][0]["responseModel"] = "unexpected-model"
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-model-drift-") as directory:
        expect_error(
            lambda: phase6.run_evaluation(ROOT, sealed, answers, False, Path(directory) / "report.json", None, answer_input),
            "ANSWER_PROVENANCE_INVALID",
        )


def test_host_native_answer_artifact_requires_dispatch_receipt() -> None:
    sealed = phase6.seal_source(phase6._self_test_source("phase6-host-native", "host-native"))
    answer_input = phase6.prepare_answer_input(ROOT, sealed)
    answers = external_answers(sealed, answer_input)
    provenance = answers["provenance"]
    provenance.update(
        {
            "kind": phase6.HOST_NATIVE_AGENT_PROVENANCE_KIND,
            "hostedNativeAgent": True,
            "modelIdentityVerified": True,
            "hostAgentId": "native-agent-regression",
            "hostDispatchReceiptSha256": phase6._sha256("native-dispatch-receipt"),
        }
    )
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-host-native-") as directory:
        base = Path(directory)
        report = phase6.run_evaluation(ROOT, sealed, answers, False, base / "accepted.json", None, answer_input)
        assert report["answerEvaluation"]["provenanceKind"] == phase6.HOST_NATIVE_AGENT_PROVENANCE_KIND
        missing_receipt = json.loads(json.dumps(answers))
        missing_receipt["provenance"].pop("hostDispatchReceiptSha256")
        expect_error(
            lambda: phase6.run_evaluation(ROOT, sealed, missing_receipt, False, base / "rejected.json", None, answer_input),
            "ANSWER_PROVENANCE_INVALID",
        )


def test_aggregate_rejects_reused_external_generator_receipt() -> None:
    binding = phase6._current_binding(ROOT)
    with tempfile.TemporaryDirectory(prefix="super-brain-phase6-receipt-reuse-") as directory:
        base = Path(directory)
        first = base / "first.report.json"
        second = base / "second.report.json"
        first_value = make_aggregate_report(binding, "set-receipt-first", "family-receipt-first", "first.marker.json")
        second_value = make_aggregate_report(binding, "set-receipt-second", "family-receipt-second", "second.marker.json")
        second_value["answerEvaluation"]["provenanceReceiptSha256"] = first_value["answerEvaluation"]["provenanceReceiptSha256"]
        write_json(first, first_value)
        write_json(second, second_value)
        bind_marker(first, "first.marker.json", str(first_value["holdout"]["setHash"]))
        bind_marker(second, "second.marker.json", str(second_value["holdout"]["setHash"]))
        registry = base / "consumption"
        bind_registry(registry, binding, first, str(first_value["holdout"]["setHash"]))
        bind_registry(registry, binding, second, str(second_value["holdout"]["setHash"]))
        expect_error(
            lambda: phase6.aggregate_reports(ROOT, [first, second], base / "aggregate.json", consumption_registry_root=registry),
            "AGGREGATE_GENERATOR_RUN_REUSE",
        )


def main() -> int:
    test_self_test_is_diagnostic_only()
    test_sealed_families_are_bound_and_calibration_overlap_is_rejected()
    test_aggregate_requires_consumption_and_distinct_families()
    test_real_aggregate_rejects_trivial_sample_sizes()
    test_report_does_not_copy_raw_memory_or_absolute_marker_paths()
    test_abstention_with_irrelevant_retrieval_is_a_valid_e2e_negative_case()
    test_answer_case_requires_expected_evidence()
    test_blinded_input_recalls_split_facts_with_aliases_and_trailing_identity_punctuation()
    test_blinded_input_fails_closed_when_record_ingestion_fails()
    test_real_answer_artifact_requires_blinded_input_provenance()
    test_consumption_registry_blocks_alternate_report_paths()
    test_existing_output_does_not_reserve_holdout()
    test_private_answer_input_preflight_rejects_expected_data()
    test_private_answer_input_preflight_rejects_rehashed_unready_ingestion()
    test_external_answer_artifact_rejects_model_provenance_drift()
    test_host_native_answer_artifact_requires_dispatch_receipt()
    test_aggregate_rejects_reused_external_generator_receipt()
    print("PHASE6_MEMORY_EVAL_REGRESSION_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
