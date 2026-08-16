from __future__ import annotations

"""Bounded, proof-bound project knowledge for the H7 control plane.

This module is deliberately a query, not an index.  It reads only the
relative files already present in the current H7 project-progress proof and a
small, fixed set of local dependency candidates.  It never walks the tree,
writes a cache, starts a worker, or returns source text.
"""

import ast
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Iterable, Mapping

from brain_context import canonical_hash, project_progress_root_hash, validate_project_progress_proof


SCHEMA = "super-brain.project-knowledge.v1"
MAX_FILES = 16
MAX_HOPS = 1
MAX_RELATIONS = 48
MAX_UNKNOWNS = 24
MAX_FILE_BYTES = 384 * 1024
_SHA256 = re.compile(r"^[a-f0-9]{64}$")
_RELATIVE = re.compile(r"^[^/\\].{0,239}$")
_SOURCE_SUFFIXES = {".py", ".ps1", ".json", ".js", ".jsx", ".ts", ".tsx"}


def _withheld(code: str, *, route: Mapping[str, Any] | None = None) -> dict[str, Any]:
    body = {
        "schema": SCHEMA,
        "state": "withheld",
        "code": code,
        "mode": str((route or {}).get("mode", "impact")),
        "coverage": "proof_bound_slice",
        "projectRootHash": "",
        "projectProgressPayloadHash": "",
        "proofFileCount": 0,
        "filesRead": 0,
        "relationshipCount": 0,
        "relationKinds": [],
        "unknownCount": 0,
        "riskLevel": "unknown",
        "recommendedVerificationIds": [],
        "globalImpactComplete": False,
        "fullTreeScan": False,
        "persistentIndex": False,
        "backgroundWorkers": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
    }
    return {**body, "payloadHash": canonical_hash(body)}


def _safe_relative(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    raw = value.strip().replace("\\", "/")
    if not raw or raw.startswith("/") or ":" in raw[:3] or not _RELATIVE.fullmatch(raw):
        return None
    parts = [item for item in raw.split("/") if item not in ("", ".")]
    if not parts or any(item == ".." for item in parts):
        return None
    return "/".join(parts)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(64 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _resolve(root: Path, relative: str) -> Path | None:
    try:
        candidate = (root / relative).resolve()
        candidate.relative_to(root)
    except (OSError, ValueError):
        return None
    return candidate


def _candidate_relative(root: Path, path: Path) -> str | None:
    try:
        return path.resolve().relative_to(root).as_posix()
    except (OSError, ValueError):
        return None


def _local_candidates(root: Path, base: Path, reference: str) -> list[str]:
    raw = reference.strip().replace("\\", "/")
    if not raw or raw.startswith(("http:", "https:", "npm:", "@")):
        return []
    if raw.startswith("."):
        target = (base / raw).resolve()
    else:
        target = (root / raw.lstrip("/")).resolve()
    candidates = [target]
    if target.suffix == "":
        candidates.extend((target.with_suffix(suffix) for suffix in (".py", ".ps1", ".json", ".js", ".ts")))
        candidates.extend((target / name for name in ("__init__.py", "index.js", "index.ts")))
    return [relative for candidate in candidates if (relative := _candidate_relative(root, candidate))]


def _proof_file_set(proof: Mapping[str, Any]) -> tuple[dict[str, str], str | None]:
    evidence = proof.get("projectEvidence")
    if not isinstance(evidence, list) or not evidence or len(evidence) > MAX_FILES:
        return {}, "H7_PROJECT_KNOWLEDGE_PROOF_EVIDENCE_INVALID"
    files: dict[str, str] = {}
    for item in evidence:
        if not isinstance(item, Mapping) or set(item) != {"kind", "relativePath", "sha256"}:
            return {}, "H7_PROJECT_KNOWLEDGE_PROOF_EVIDENCE_INVALID"
        relative = _safe_relative(item.get("relativePath"))
        digest = item.get("sha256")
        if item.get("kind") != "project_file" or relative is None or not isinstance(digest, str) or not _SHA256.fullmatch(digest):
            return {}, "H7_PROJECT_KNOWLEDGE_PROOF_EVIDENCE_INVALID"
        if relative in files:
            return {}, "H7_PROJECT_KNOWLEDGE_PROOF_EVIDENCE_DUPLICATE"
        files[relative] = digest
    return files, None


def _read_text(path: Path) -> tuple[str | None, str | None]:
    try:
        if path.stat().st_size > MAX_FILE_BYTES:
            return None, "file_too_large"
        return path.read_text(encoding="utf-8-sig"), None
    except (OSError, UnicodeError):
        return None, "file_unreadable"


def _parse_python(text: str, current: str) -> tuple[list[tuple[str, str]], list[str]]:
    edges: list[tuple[str, str]] = []
    unknowns: list[str] = []
    try:
        tree = ast.parse(text, filename=current)
    except SyntaxError:
        return [], ["python_syntax_unknown"]
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                edges.append(("python_import", alias.name.replace(".", "/")))
        elif isinstance(node, ast.ImportFrom):
            level = int(node.level or 0)
            module = str(node.module or "").replace(".", "/")
            if level:
                prefix = "./" if level == 1 else "../" * (level - 1)
                if module:
                    edges.append(("python_import", prefix + module))
                else:
                    edges.extend(("python_import", prefix + alias.name.replace(".", "/")) for alias in node.names)
            elif module:
                edges.append(("python_import", module))
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "__import__":
            unknowns.append("python_dynamic_import")
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "import_module":
            unknowns.append("python_dynamic_import")
    return edges, unknowns


def _parse_powershell(text: str) -> tuple[list[tuple[str, str]], list[str]]:
    edges: list[tuple[str, str]] = []
    unknowns: list[str] = []
    dot_pattern = re.compile(r"(?im)^\s*\.\s+['\"]?\$PSScriptRoot[\\/]([^'\"\s;]+)")
    call_pattern = re.compile(r"(?im)&\s*['\"]?\$PSScriptRoot[\\/]([^'\"\s;]+)")
    for match in dot_pattern.finditer(text):
        edges.append(("powershell_dot_source", match.group(1)))
    for match in call_pattern.finditer(text):
        edges.append(("powershell_script_call", match.group(1)))
    if re.search(r"(?i)Invoke-Expression|&\s*\$[A-Za-z_][A-Za-z0-9_]*", text):
        unknowns.append("powershell_dynamic_call")
    return edges, unknowns


def _parse_json(text: str) -> tuple[list[tuple[str, str]], list[str]]:
    try:
        value = json.loads(text)
    except (TypeError, ValueError):
        return [], ["json_parse_unknown"]
    edges: list[tuple[str, str]] = []

    def visit(item: Any) -> None:
        if isinstance(item, str) and (item.startswith(".") or Path(item).suffix.lower() in _SOURCE_SUFFIXES):
            edges.append(("json_local_reference", item))
        elif isinstance(item, Mapping):
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)

    visit(value)
    return edges, []


def _parse_javascript(text: str) -> tuple[list[tuple[str, str]], list[str]]:
    edges = [
        ("javascript_local_import", value)
        for value in re.findall(r"(?:from\s*|import\s*|require\s*\()\s*['\"](\.[^'\"]+)", text)
    ]
    unknowns = ["javascript_dynamic_import"] if re.search(r"import\s*\(|require\s*\([^'\"]", text) else []
    return edges, unknowns


def _parse_file(path: Path, relative: str, text: str) -> tuple[list[tuple[str, str]], list[str]]:
    suffix = path.suffix.lower()
    if suffix == ".py":
        return _parse_python(text, relative)
    if suffix == ".ps1":
        return _parse_powershell(text)
    if suffix == ".json":
        return _parse_json(text)
    if suffix in {".js", ".jsx", ".ts", ".tsx"}:
        return _parse_javascript(text)
    return [], ["unsupported_file_type"]


def _recommended_checks(nodes: Iterable[Mapping[str, Any]]) -> list[str]:
    suffixes = {Path(str(node.get("path", ""))).suffix.lower() for node in nodes}
    checks: list[str] = []
    if ".py" in suffixes:
        checks.append("python_compile_focused")
    if ".ps1" in suffixes:
        checks.append("powershell_parse_focused")
    if ".json" in suffixes:
        checks.append("json_parse_focused")
    if suffixes & {".js", ".jsx", ".ts", ".tsx"}:
        checks.append("javascript_typecheck_or_test_focused")
    return checks


def _public(value: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "state": str(value.get("state", "withheld")),
        "code": str(value.get("code", "H7_PROJECT_KNOWLEDGE_UNAVAILABLE")),
        "mode": str(value.get("mode", "impact")),
        "coverage": str(value.get("coverage", "proof_bound_slice")),
        "projectRootHash": str(value.get("projectRootHash", "")),
        "projectProgressPayloadHash": str(value.get("projectProgressPayloadHash", "")),
        "proofFileCount": int(value.get("proofFileCount", 0) or 0),
        "filesRead": int(value.get("filesRead", 0) or 0),
        "relationshipCount": int(value.get("relationshipCount", 0) or 0),
        "relationKinds": list(value.get("relationKinds", []) or [])[:12],
        "unknownCount": int(value.get("unknownCount", 0) or 0),
        "riskLevel": str(value.get("riskLevel", "unknown")),
        "recommendedVerificationIds": list(value.get("recommendedVerificationIds", []) or [])[:12],
        "globalImpactComplete": value.get("globalImpactComplete") is True,
        "fullTreeScan": value.get("fullTreeScan") is True,
        "persistentIndex": value.get("persistentIndex") is True,
        "backgroundWorkers": value.get("backgroundWorkers") is True,
        "nonAuthorizing": value.get("nonAuthorizing") is True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
        "payloadHash": str(value.get("payloadHash", "")),
    }


def receipt_is_valid(value: Any) -> bool:
    if not isinstance(value, Mapping):
        return False
    required = {
        "schema", "state", "code", "mode", "coverage", "projectRootHash", "projectProgressPayloadHash",
        "proofFileCount", "filesRead", "relationshipCount", "relationKinds", "unknownCount", "riskLevel",
        "recommendedVerificationIds", "globalImpactComplete", "fullTreeScan", "persistentIndex",
        "backgroundWorkers", "nonAuthorizing", "rawPromptStored", "rawTranscriptStored", "sourcePathsOmitted",
        "payloadHash",
    }
    if set(value) != required or value.get("schema") != SCHEMA:
        return False
    if value.get("state") not in {"ready", "withheld", "not_applicable"} or value.get("nonAuthorizing") is not True:
        return False
    if any(value.get(key) is not False for key in ("globalImpactComplete", "fullTreeScan", "persistentIndex", "backgroundWorkers", "rawPromptStored", "rawTranscriptStored")):
        return False
    if value.get("sourcePathsOmitted") is not True:
        return False
    if not all(isinstance(value.get(key), int) and 0 <= value.get(key) <= MAX_RELATIONS for key in ("proofFileCount", "filesRead", "relationshipCount", "unknownCount")):
        return False
    digest_fields = ("projectRootHash", "projectProgressPayloadHash", "payloadHash")
    if any(not isinstance(value.get(key), str) or (value.get(key) and not _SHA256.fullmatch(value.get(key))) for key in digest_fields):
        return False
    return True


def resolve_project_knowledge(
    project_root: Path | str | None,
    *,
    project_progress_proof: Mapping[str, Any] | None,
    project_progress_status: Mapping[str, Any] | None,
    route: Mapping[str, Any] | None,
    expected_phase: str = "",
    expected_current_step: str = "",
    expected_next_action: str = "",
    expected_completed_steps: Iterable[Any] = (),
) -> tuple[dict[str, Any] | None, str]:
    """Resolve a proof-bound project slice after H7 has selected the route."""

    route_value = route if isinstance(route, Mapping) else {}
    if str(route_value.get("state", "")) == "not_applicable":
        result = _withheld("H7_PROJECT_KNOWLEDGE_NOT_APPLICABLE", route=route_value)
        result["state"] = "not_applicable"
        result["mode"] = "not_applicable"
        result["payloadHash"] = canonical_hash({key: item for key, item in result.items() if key != "payloadHash"})
        return result, "H7_PROJECT_KNOWLEDGE_NOT_APPLICABLE"
    if str(route_value.get("state", "")) != "ready":
        return _withheld("H7_PROJECT_KNOWLEDGE_ROUTE_WITHHELD", route=route_value), "H7_PROJECT_KNOWLEDGE_ROUTE_WITHHELD"
    try:
        root = Path(project_root).expanduser().resolve() if project_root is not None else None
    except (OSError, ValueError):
        root = None
    if root is None or not root.is_dir():
        return _withheld("H7_PROJECT_KNOWLEDGE_ROOT_UNAVAILABLE", route=route_value), "H7_PROJECT_KNOWLEDGE_ROOT_UNAVAILABLE"
    proof = dict(project_progress_proof) if isinstance(project_progress_proof, Mapping) else None
    if not isinstance(proof, dict):
        return _withheld("H7_PROJECT_KNOWLEDGE_PROOF_MISSING", route=route_value), "H7_PROJECT_KNOWLEDGE_PROOF_MISSING"
    status = project_progress_status if isinstance(project_progress_status, Mapping) else {}
    if status.get("current") is not True or str(status.get("state", "")) != "current":
        return _withheld("H7_PROJECT_KNOWLEDGE_PROOF_WITHHELD", route=route_value), "H7_PROJECT_KNOWLEDGE_PROOF_WITHHELD"
    validated = validate_project_progress_proof(
        proof,
        project_root=root,
        expected_phase=expected_phase,
        expected_current_step=expected_current_step,
        expected_next_action=expected_next_action,
        expected_completed_steps=list(expected_completed_steps),
    )
    if validated.get("current") is not True:
        return _withheld("H7_PROJECT_KNOWLEDGE_PROOF_RECHECK_FAILED", route=route_value), "H7_PROJECT_KNOWLEDGE_PROOF_RECHECK_FAILED"
    files, error = _proof_file_set(proof)
    if error:
        return _withheld(error, route=route_value), error
    root_hash = project_progress_root_hash(root)
    if str(proof.get("projectRootHash", "")) != root_hash:
        return _withheld("H7_PROJECT_KNOWLEDGE_ROOT_MISMATCH", route=route_value), "H7_PROJECT_KNOWLEDGE_ROOT_MISMATCH"

    nodes: list[dict[str, Any]] = []
    unknowns: list[dict[str, str]] = []
    all_relations: list[dict[str, str]] = []
    proof_paths = set(files)
    texts: dict[str, str] = {}
    for relative, expected_digest in sorted(files.items()):
        path = _resolve(root, relative)
        if path is None or not path.is_file():
            return _withheld("H7_PROJECT_KNOWLEDGE_EVIDENCE_PATH_INVALID", route=route_value), "H7_PROJECT_KNOWLEDGE_EVIDENCE_PATH_INVALID"
        try:
            digest = _sha256(path)
        except OSError:
            return _withheld("H7_PROJECT_KNOWLEDGE_EVIDENCE_READ_FAILED", route=route_value), "H7_PROJECT_KNOWLEDGE_EVIDENCE_READ_FAILED"
        if digest != expected_digest:
            return _withheld("H7_PROJECT_KNOWLEDGE_EVIDENCE_HASH_MISMATCH", route=route_value), "H7_PROJECT_KNOWLEDGE_EVIDENCE_HASH_MISMATCH"
        node = {"path": relative, "sha256": digest, "kind": "proof_file"}
        nodes.append(node)
        text, read_error = _read_text(path)
        if read_error:
            unknowns.append({"path": relative, "code": read_error, "verification": "inspect the focused file directly"})
        elif text is not None and path.suffix.lower() in _SOURCE_SUFFIXES:
            texts[relative] = text

    for relative, text in texts.items():
        path = _resolve(root, relative)
        if path is None:
            continue
        edges, dynamic = _parse_file(path, relative, text)
        for unknown in dynamic:
            if len(unknowns) < MAX_UNKNOWNS:
                unknowns.append({"path": relative, "code": unknown, "verification": "run a focused test or inspect dynamic resolution"})
        for relation, reference in edges:
            candidates = _local_candidates(root, path.parent, reference)
            target = next((candidate for candidate in candidates if candidate in proof_paths), None)
            if target is None:
                if candidates and len(unknowns) < MAX_UNKNOWNS:
                    unknowns.append({"path": relative, "code": "dependency_outside_proof_slice", "verification": "add the target to the next H7 project proof"})
                continue
            if len(all_relations) < MAX_RELATIONS:
                all_relations.append({"from": relative, "to": target, "relation": relation})

    relation_kinds = sorted({str(item["relation"]) for item in all_relations})
    unknown_count = len(unknowns)
    risk_level = "unknown" if unknown_count else ("medium" if len(all_relations) > 8 else "low")
    body: dict[str, Any] = {
        "schema": SCHEMA,
        "state": "ready",
        "code": "H7_PROJECT_KNOWLEDGE_READY",
        "mode": str(route_value.get("mode", "impact")),
        "coverage": "proof_bound_slice",
        "projectRootHash": root_hash,
        "projectProgressPayloadHash": str(proof.get("payloadHash", "")),
        "proofFileCount": len(files),
        "filesRead": len(nodes),
        "relationshipCount": len(all_relations),
        "relationKinds": relation_kinds,
        "unknownCount": unknown_count,
        "riskLevel": risk_level,
        "recommendedVerificationIds": _recommended_checks(nodes),
        "globalImpactComplete": False,
        "fullTreeScan": False,
        "persistentIndex": False,
        "backgroundWorkers": False,
        "nonAuthorizing": True,
        "rawPromptStored": False,
        "rawTranscriptStored": False,
        "sourcePathsOmitted": True,
        "nodes": nodes,
        "relations": all_relations,
        "unknowns": unknowns[:MAX_UNKNOWNS],
    }
    result = {**body, "payloadHash": canonical_hash(body)}
    return result, "H7_PROJECT_KNOWLEDGE_READY"


def public_projection(value: Mapping[str, Any] | None) -> dict[str, Any]:
    if not isinstance(value, Mapping) or not receipt_is_valid({key: value.get(key) for key in {
        "schema", "state", "code", "mode", "coverage", "projectRootHash", "projectProgressPayloadHash", "proofFileCount", "filesRead", "relationshipCount", "relationKinds", "unknownCount", "riskLevel", "recommendedVerificationIds", "globalImpactComplete", "fullTreeScan", "persistentIndex", "backgroundWorkers", "nonAuthorizing", "rawPromptStored", "rawTranscriptStored", "sourcePathsOmitted", "payloadHash"
    }}):
        return _withheld("H7_PROJECT_KNOWLEDGE_RECEIPT_INVALID")
    return _public(value)


__all__ = ["SCHEMA", "MAX_FILES", "MAX_HOPS", "public_projection", "receipt_is_valid", "resolve_project_knowledge"]
