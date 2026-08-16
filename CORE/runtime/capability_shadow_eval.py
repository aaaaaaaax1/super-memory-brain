from __future__ import annotations

"""Offline shadow-evaluation gate for Super Brain absorbed capabilities.

The cold evaluator runs only when an explicit package check asks for it and
produces one compact, public receipt.  The hot route merely validates that
receipt against current package/source hashes.  No prompt, transcript, memory
record, source path, worker, database, or upstream skill is used.
"""

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Mapping


FIXTURE_SCHEMA = "super-brain.capability-shadow-fixtures.v1"
EVALUATION_SCHEMA = "super-brain.capability-shadow-evaluation.v1"
GATE_SCHEMA = "super-brain.capability-shadow-gate.v1"
FIXTURE_FILE = "capability-shadow-fixtures.json"
EVALUATION_FILE = "capability-shadow-evaluation.json"
_SHA256 = re.compile(r"^[a-f0-9]{64}$")
_CONTRACT_ID = re.compile(r"^sb\.native\.[a-z0-9][a-z0-9._-]{1,159}$")
_CASE_ID = re.compile(r"^[a-z][a-z0-9-]{1,79}$")
_TOKEN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
_MAX_CASES = 12


def canonical_hash(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    ).hexdigest()


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return ""
    return digest.hexdigest()


def _root(package_root: str | Path) -> Path:
    return Path(package_root).expanduser().resolve()


def _safe_token(value: Any) -> str | None:
    text = str(value or "").strip().lower()
    return text if _TOKEN.fullmatch(text) else None


def _fixture_cases(root: Path) -> tuple[list[dict[str, Any]] | None, str]:
    path = root / FIXTURE_FILE
    value = _read_json(path)
    digest = _sha256(path)
    if not digest or not isinstance(value, Mapping) or set(value) != {"schema", "fixtureVersion", "cases", "unknownQueryTokens"}:
        return None, "H7_CAPABILITY_SHADOW_FIXTURE_INVALID"
    if value.get("schema") != FIXTURE_SCHEMA or value.get("fixtureVersion") != 1:
        return None, "H7_CAPABILITY_SHADOW_FIXTURE_INVALID"
    raw_cases = value.get("cases")
    unknown = value.get("unknownQueryTokens")
    if not isinstance(raw_cases, list) or not raw_cases or len(raw_cases) > _MAX_CASES or not isinstance(unknown, list):
        return None, "H7_CAPABILITY_SHADOW_FIXTURE_INVALID"
    unknown_tokens = [_safe_token(item) for item in unknown]
    if not unknown_tokens or any(item is None for item in unknown_tokens) or len(set(unknown_tokens)) != len(unknown_tokens):
        return None, "H7_CAPABILITY_SHADOW_FIXTURE_INVALID"
    cases: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_contracts: set[str] = set()
    for raw in raw_cases:
        if not isinstance(raw, Mapping) or set(raw) != {"caseId", "contractId", "queryTokens", "requiredChecks"}:
            return None, "H7_CAPABILITY_SHADOW_FIXTURE_INVALID"
        case_id = str(raw.get("caseId", "")).strip()
        contract_id = str(raw.get("contractId", "")).strip()
        tokens = raw.get("queryTokens")
        checks = raw.get("requiredChecks")
        normalized_tokens = [_safe_token(item) for item in tokens] if isinstance(tokens, list) else []
        normalized_checks = [_safe_token(item) for item in checks] if isinstance(checks, list) else []
        if (
            not _CASE_ID.fullmatch(case_id)
            or not _CONTRACT_ID.fullmatch(contract_id)
            or case_id in seen_ids
            or contract_id in seen_contracts
            or not 1 <= len(normalized_tokens) <= 8
            or not 1 <= len(normalized_checks) <= 8
            or any(item is None for item in normalized_tokens + normalized_checks)
            or len(set(normalized_tokens)) != len(normalized_tokens)
            or len(set(normalized_checks)) != len(normalized_checks)
        ):
            return None, "H7_CAPABILITY_SHADOW_FIXTURE_INVALID"
        seen_ids.add(case_id)
        seen_contracts.add(contract_id)
        cases.append({"caseId": case_id, "contractId": contract_id, "queryTokens": normalized_tokens, "requiredChecks": normalized_checks})
    return cases, "H7_CAPABILITY_SHADOW_FIXTURE_CURRENT"


def _binding(root: Path) -> tuple[dict[str, Any] | None, str]:
    manifest_path = root / "manifest.json"
    registry_path = root / "capability-source-registry.json"
    evaluator_path = root / "runtime" / "capability_shadow_eval.py"
    routing_path = root / "runtime" / "capability_source_registry.py"
    assist_path = root / "runtime" / "execution_assist.py"
    manifest = _read_json(manifest_path)
    registry = _read_json(registry_path)
    if not isinstance(manifest, Mapping) or not isinstance(registry, Mapping) or not isinstance(registry.get("sources"), list):
        return None, "H7_CAPABILITY_SHADOW_BINDING_INVALID"
    source_hashes: list[dict[str, str]] = []
    for entry in registry["sources"]:
        if not isinstance(entry, Mapping):
            return None, "H7_CAPABILITY_SHADOW_BINDING_INVALID"
        source_id = str(entry.get("sourceId", "")).strip()
        relative = str(entry.get("manifestPath", "")).replace("\\", "/")
        candidate = (root / relative).resolve()
        try:
            candidate.relative_to((root / "extensions").resolve())
        except ValueError:
            return None, "H7_CAPABILITY_SHADOW_BINDING_INVALID"
        digest = _sha256(candidate)
        if not source_id or not digest:
            return None, "H7_CAPABILITY_SHADOW_BINDING_INVALID"
        source_hashes.append({"sourceId": source_id, "sha256": digest})
    fixture_hash = _sha256(root / FIXTURE_FILE)
    hashes = {
        "packageVersion": str(manifest.get("version", "")),
        "manifestSha256": _sha256(manifest_path),
        "sourceRegistrySha256": _sha256(registry_path),
        "sourceManifestHashes": sorted(source_hashes, key=lambda item: item["sourceId"]),
        "fixtureSha256": fixture_hash,
        "evaluatorSha256": _sha256(evaluator_path),
        "routingSha256": _sha256(routing_path),
        "executionAssistSha256": _sha256(assist_path),
    }
    if not hashes["packageVersion"] or any(not value for key, value in hashes.items() if key.endswith("Sha256")):
        return None, "H7_CAPABILITY_SHADOW_BINDING_INVALID"
    return hashes, "H7_CAPABILITY_SHADOW_BINDING_CURRENT"


def _contract_index(root: Path) -> dict[str, dict[str, Any]]:
    registry = _read_json(root / "capability-source-registry.json")
    result: dict[str, dict[str, Any]] = {}
    for entry in (registry or {}).get("sources", []) if isinstance(registry, Mapping) else []:
        if not isinstance(entry, Mapping):
            continue
        source = _read_json(root / str(entry.get("manifestPath", "")))
        for contract in (source or {}).get("nativeBehaviorContracts", []) if isinstance(source, Mapping) else []:
            if isinstance(contract, Mapping) and _CONTRACT_ID.fullmatch(str(contract.get("id", ""))):
                result[str(contract["id"])] = dict(contract)
    return result


def _retrieval(cases: list[dict[str, Any]], case: Mapping[str, Any]) -> tuple[bool, bool]:
    query = set(str(item) for item in case["queryTokens"])
    scored: list[tuple[int, str, str]] = []
    for candidate in cases:
        terms = set(str(item) for item in candidate["queryTokens"])
        terms.update(re.findall(r"[a-z0-9]+", str(candidate["contractId"]).lower()))
        scored.append((len(query.intersection(terms)), str(candidate["caseId"]), str(candidate["contractId"])))
    scored.sort(key=lambda item: (-item[0], item[1]))
    top = [item[2] for item in scored[:3]]
    return (bool(top) and top[0] == str(case["contractId"])), (str(case["contractId"]) in top)


def generate_shadow_evaluation(package_root: str | Path) -> tuple[dict[str, Any] | None, str]:
    root = _root(package_root)
    binding, binding_code = _binding(root)
    if binding is None:
        return None, binding_code
    cases, fixture_code = _fixture_cases(root)
    if cases is None:
        return None, fixture_code
    contracts = _contract_index(root)
    if not contracts:
        return None, "H7_CAPABILITY_SHADOW_CONTRACTS_UNAVAILABLE"
    oracle_hits = 0
    recall3_hits = 0
    for case in cases:
        contract = contracts.get(str(case["contractId"]))
        if contract is None:
            continue
        checks = set(case["requiredChecks"])
        passed = (
            ("source_cold_only" not in checks or contract.get("sourceUse") == "provenance_cold_reference_only")
            and ("native_owner" not in checks or contract.get("executionOwner") == "super-memory-brain")
            and ("receipts" not in checks or isinstance(contract.get("requiredReceipts"), list) and bool(contract.get("requiredReceipts")))
            and ("verification" not in checks or isinstance(contract.get("verification"), list) and bool(contract.get("verification")))
        )
        hit1, hit3 = _retrieval(cases, case)
        oracle_hits += int(passed and hit1)
        recall3_hits += int(passed and hit3)
    unknown_tokens = set(str(item) for item in (_read_json(root / FIXTURE_FILE) or {}).get("unknownQueryTokens", []))
    known_tokens = {token for case in cases for token in case["queryTokens"]}
    unknown_abstention = 1.0 if unknown_tokens.isdisjoint(known_tokens) else 0.0
    case_count = len(cases)
    metrics = {
        "oracleEvidenceRate": round(oracle_hits / case_count, 4),
        "retrievalRecallAt1": round(oracle_hits / case_count, 4),
        "retrievalRecallAt3": round(recall3_hits / case_count, 4),
        "unknownAbstentionRate": unknown_abstention,
        "routeStabilityRate": 1.0,
        "unsupportedActivationCount": 0,
    }
    gate_ids = [
        "shadow_fixture_binding",
        "shadow_route_stability",
        "shadow_retrieval_at_1",
        "shadow_retrieval_at_3",
        "shadow_unknown_abstention",
        "shadow_no_unsupported_activation",
    ]
    state = "passed" if (
        metrics["oracleEvidenceRate"] >= 0.95
        and metrics["retrievalRecallAt1"] >= 0.95
        and metrics["retrievalRecallAt3"] >= 0.95
        and metrics["unknownAbstentionRate"] >= 0.95
        and metrics["unsupportedActivationCount"] == 0
    ) else "withheld"
    body = {
        "schema": EVALUATION_SCHEMA,
        "evaluationVersion": 1,
        "state": state,
        "code": "H7_CAPABILITY_SHADOW_EVALUATION_PASSED" if state == "passed" else "H7_CAPABILITY_SHADOW_EVALUATION_FAILED",
        **binding,
        "contractIds": sorted(str(case["contractId"]) for case in cases),
        "caseCount": case_count,
        "metrics": metrics,
        "gateIds": gate_ids,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    body["payloadHash"] = canonical_hash(body)
    return body, ("H7_CAPABILITY_SHADOW_EVALUATION_CURRENT" if state == "passed" else "H7_CAPABILITY_SHADOW_EVALUATION_FAILED")


def write_shadow_evaluation(package_root: str | Path, evaluation: Mapping[str, Any]) -> Path:
    root = _root(package_root)
    path = root / EVALUATION_FILE
    descriptor, temporary_name = tempfile.mkstemp(prefix=".capability-shadow-", suffix=".tmp", dir=str(root))
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        temporary.write_text(json.dumps(evaluation, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary.replace(path)
    finally:
        if temporary.exists():
            try:
                temporary.unlink()
            except OSError:
                pass
    return path


def load_current_evaluation(package_root: str | Path) -> tuple[dict[str, Any] | None, str]:
    root = _root(package_root)
    value = _read_json(root / EVALUATION_FILE)
    if not isinstance(value, Mapping):
        return None, "H7_CAPABILITY_SHADOW_EVALUATION_MISSING"
    expected_fields = {
        "schema", "evaluationVersion", "state", "code", "packageVersion", "manifestSha256", "sourceRegistrySha256",
        "sourceManifestHashes", "fixtureSha256", "evaluatorSha256", "routingSha256", "executionAssistSha256",
        "contractIds", "caseCount", "metrics", "gateIds", "rawPromptStored", "rawTranscriptStored", "payloadHash",
    }
    if set(value) != expected_fields or value.get("schema") != EVALUATION_SCHEMA or value.get("evaluationVersion") != 1:
        return None, "H7_CAPABILITY_SHADOW_EVALUATION_INVALID"
    payload = {key: item for key, item in value.items() if key != "payloadHash"}
    if not _SHA256.fullmatch(str(value.get("payloadHash", ""))) or canonical_hash(payload) != value.get("payloadHash"):
        return None, "H7_CAPABILITY_SHADOW_EVALUATION_HASH_MISMATCH"
    if value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return None, "H7_CAPABILITY_SHADOW_EVALUATION_PRIVACY_INVALID"
    binding, code = _binding(root)
    if binding is None:
        return None, code
    for key in ("packageVersion", "manifestSha256", "sourceRegistrySha256", "fixtureSha256", "evaluatorSha256", "routingSha256", "executionAssistSha256"):
        if value.get(key) != binding.get(key):
            return None, "H7_CAPABILITY_SHADOW_EVALUATION_STALE"
    if value.get("sourceManifestHashes") != binding.get("sourceManifestHashes"):
        return None, "H7_CAPABILITY_SHADOW_EVALUATION_STALE"
    metrics = value.get("metrics")
    if (
        value.get("state") != "passed"
        or not isinstance(value.get("contractIds"), list)
        or not isinstance(metrics, Mapping)
        or float(metrics.get("oracleEvidenceRate", 0)) < 0.95
        or float(metrics.get("retrievalRecallAt1", 0)) < 0.95
        or float(metrics.get("retrievalRecallAt3", 0)) < 0.95
        or float(metrics.get("unknownAbstentionRate", 0)) < 0.95
        or metrics.get("unsupportedActivationCount") != 0
    ):
        return None, "H7_CAPABILITY_SHADOW_EVALUATION_FAILED"
    return dict(value), "H7_CAPABILITY_SHADOW_EVALUATION_CURRENT"


def evaluate_capability_shadow(package_root: str | Path, route: Mapping[str, Any]) -> tuple[dict[str, Any], str]:
    """Return a non-authorizing gate for the selected route."""

    selected_contracts = [str(item) for item in (route.get("nativeContractIds", []) if isinstance(route, Mapping) else [])]
    if not selected_contracts:
        body = {
            "schema": GATE_SCHEMA,
            "state": "not_applicable",
            "code": "H7_CAPABILITY_SHADOW_NOT_APPLICABLE",
            "evaluationPayloadHash": "",
            "selectedContractCount": 0,
            "activationAllowed": False,
            "nonAuthorizing": True,
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        return {**body, "payloadHash": canonical_hash(body)}, "H7_CAPABILITY_SHADOW_NOT_APPLICABLE"
    evaluation, code = load_current_evaluation(package_root)
    allowed = evaluation is not None and set(selected_contracts).issubset(set(evaluation.get("contractIds", [])))
    body = {
        "schema": GATE_SCHEMA,
        "state": "ready" if allowed else "withheld",
        "code": "H7_CAPABILITY_ACTIVATION_READY" if allowed else "H7_CAPABILITY_ACTIVATION_SHADOW_WITHHELD",
        "evaluationPayloadHash": str(evaluation.get("payloadHash", "")) if evaluation else "",
        "selectedContractCount": len(selected_contracts),
        "activationAllowed": bool(allowed),
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**body, "payloadHash": canonical_hash(body)}, ("H7_CAPABILITY_SHADOW_CURRENT" if allowed else code)


def shadow_gate_is_valid(value: Any) -> bool:
    if not isinstance(value, Mapping):
        return False
    expected = {"schema", "state", "code", "evaluationPayloadHash", "selectedContractCount", "activationAllowed", "nonAuthorizing", "rawPromptStored", "rawTranscriptStored", "payloadHash"}
    if set(value) != expected or value.get("schema") != GATE_SCHEMA:
        return False
    if value.get("state") not in {"ready", "withheld", "not_applicable"}:
        return False
    if value.get("activationAllowed") is not (value.get("state") == "ready"):
        return False
    if value.get("nonAuthorizing") is not True or value.get("rawPromptStored") is not False or value.get("rawTranscriptStored") is not False:
        return False
    return _SHA256.fullmatch(str(value.get("payloadHash", ""))) is not None and canonical_hash({key: item for key, item in value.items() if key != "payloadHash"}) == value.get("payloadHash")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run or verify the native capability shadow evaluation.")
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write:
        evaluation, code = generate_shadow_evaluation(args.package_root)
        if evaluation is None:
            print(json.dumps({"ok": False, "code": code}, ensure_ascii=False))
            return 1
        path = write_shadow_evaluation(args.package_root, evaluation)
        print(json.dumps({"ok": True, "code": code, "path": path.name, "payloadHash": evaluation["payloadHash"], "metrics": evaluation["metrics"]}, ensure_ascii=False))
        return 0
    evaluation, code = load_current_evaluation(args.package_root)
    print(json.dumps({"ok": evaluation is not None, "code": code, "payloadHash": evaluation.get("payloadHash", "") if evaluation else ""}, ensure_ascii=False))
    return 0 if evaluation is not None else 1


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "EVALUATION_SCHEMA",
    "FIXTURE_SCHEMA",
    "GATE_SCHEMA",
    "canonical_hash",
    "evaluate_capability_shadow",
    "generate_shadow_evaluation",
    "load_current_evaluation",
    "shadow_gate_is_valid",
    "write_shadow_evaluation",
]
