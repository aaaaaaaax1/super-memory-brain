"""Independent, delivery-first repair lane for the Super Brain package.

This module is deliberately outside the H7 runtime graph.  It does not import
``brain_core``, ``turn_runtime``, ``execution_assist``, ``project_knowledge``
or an MCP adapter, and it never creates a task card, memory record, capability
route, or project-knowledge receipt.  Its job is limited to static inspection,
an explicit delivery profile, and an allow-listed deterministic test loop.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Iterable, Mapping


SCHEMA = "super-brain.external-repair.v1"
PROFILE_NAMES = ("rapid", "standard", "critical")
PROFILE_POLICY: dict[str, dict[str, Any]] = {
    "rapid": {
        "budgetSeconds": 900,
        "failureLimit": 2,
        "artifactTargetMinutes": 15,
        "description": "最小补丁、最快定点验证，先形成可运行产物。",
        "defaultTests": (
            "runtime_mcp_identity",
            "runtime_mcp_live_handshake",
            "runtime_run_observability",
        ),
    },
    "standard": {
        "budgetSeconds": 1800,
        "failureLimit": 2,
        "artifactTargetMinutes": 30,
        "description": "先做 vertical slice，再做受影响路径的集成回归。",
        "defaultTests": (
            "runtime_mcp_identity",
            "runtime_mcp_live_handshake",
            "runtime_run_observability",
            "runtime_core_rule_registry",
            "runtime_turn_close_dedupe",
        ),
    },
    "critical": {
        "budgetSeconds": 3600,
        "failureLimit": 2,
        "artifactTargetMinutes": 60,
        "description": "完整协议门禁、回滚证据和受影响路径回归。",
        "defaultTests": (
            "runtime_mcp_identity",
            "runtime_mcp_live_handshake",
            "runtime_run_observability",
            "runtime_core_rule_registry",
            "runtime_turn_close_dedupe",
            "brain_eval_contract",
        ),
    },
}

_TEST_COMMANDS: dict[str, tuple[str, ...]] = {
    "runtime_mcp_identity": ("tests/runtime_mcp_identity_regression.py",),
    "runtime_mcp_live_handshake": ("tests/runtime_mcp_live_handshake_regression.py",),
    "runtime_run_observability": ("tests/runtime_run_observability_regression.py",),
    "runtime_core_rule_registry": ("tests/runtime_core_rule_registry_regression.py",),
    "runtime_turn_runtime": ("tests/runtime_turn_runtime_regression.py",),
    "runtime_turn_close_dedupe": ("tests/runtime_turn_close_dedupe_regression.py",),
    "brain_eval_contract": ("runtime/brain_eval.py", "--mcp-replay", "--contract-only"),
}

_INSPECT_FILES = (
    "manifest.json",
    "runtime/brain_mcp.py",
    "runtime/turn_runtime.py",
    "runtime/brain_core.py",
    "runtime/execution_assist.py",
    "runtime/project_knowledge.py",
    "super-brain-rules.json",
)


def canonical_hash(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    ).hexdigest()


def _bounded_text(value: Any, maximum: int = 1200) -> str:
    if not isinstance(value, str):
        return ""
    value = value.replace("\x00", "")
    return value if len(value) <= maximum else value[:maximum] + "\n<truncated>"


def _package_root(value: str | Path) -> Path:
    root = Path(value).expanduser().resolve()
    if not root.is_dir():
        raise ValueError("external repair package root is not a directory")
    if not (root / "manifest.json").is_file():
        raise ValueError("external repair package root is missing manifest.json")
    return root


def _safe_file(root: Path, relative: str) -> Path:
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise ValueError("external repair target escaped package root") from exc
    return candidate


def _file_projection(root: Path, relative: str) -> dict[str, Any]:
    path = _safe_file(root, relative)
    if not path.is_file():
        return {"path": relative, "state": "missing"}
    try:
        raw = path.read_bytes()
    except OSError:
        return {"path": relative, "state": "unreadable"}
    return {
        "path": relative,
        "state": "current",
        "size": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def _authority_projection() -> dict[str, Any]:
    return {
        "controlPlane": "external_repair_controller",
        "h7Called": False,
        "memoryRead": False,
        "memoryWrite": False,
        "taskStateRead": False,
        "taskStateWrite": False,
        "capabilityRoute": False,
        "projectKnowledge": False,
        "mcpDispatch": False,
        "nonAuthorizing": True,
    }


def inspect_package(package_root: str | Path) -> dict[str, Any]:
    root = _package_root(package_root)
    manifest: dict[str, Any] = {}
    try:
        parsed = json.loads((root / "manifest.json").read_text(encoding="utf-8-sig"))
        if isinstance(parsed, dict):
            manifest = parsed
    except (OSError, UnicodeError, json.JSONDecodeError):
        manifest = {}
    payload = {
        "schema": SCHEMA,
        "action": "inspect",
        "state": "current",
        "controllerMode": "super_brain_external_repair",
        "authority": _authority_projection(),
        "package": {
            "root": str(root),
            "version": str(manifest.get("version", "")),
            "runtimeMode": str(manifest.get("runtimeMode", "")),
            "mcpIdentityRootCount": len(manifest.get("mcpRuntimeIdentityRoots", []) or []),
        },
        "files": [_file_projection(root, relative) for relative in _INSPECT_FILES],
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**payload, "payloadHash": canonical_hash(payload)}


def classify_scope(paths: Iterable[str]) -> str:
    normalized = [str(item).replace("\\", "/").lower() for item in paths if str(item).strip()]
    if any(
        item.endswith(("runtime/brain_mcp.py", "runtime/turn_runtime.py", "runtime/brain_core.py"))
        or item.endswith("super-brain-rules.json")
        or "migration" in item
        for item in normalized
    ):
        return "critical"
    if any(item.startswith("runtime/") or item.startswith("scripts/") for item in normalized):
        return "standard"
    return "rapid"


def plan_delivery(package_root: str | Path, paths: Iterable[str]) -> dict[str, Any]:
    root = _package_root(package_root)
    del root  # validation is intentional; planning must use a real package root.
    mode = classify_scope(paths)
    policy = PROFILE_POLICY[mode]
    payload = {
        "schema": SCHEMA,
        "action": "plan",
        "state": "ready",
        "controllerMode": "super_brain_external_repair",
        "mode": mode,
        "profile": policy,
        "changedPaths": [str(item).replace("\\", "/")[:240] for item in paths][:32],
        "authority": _authority_projection(),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**payload, "payloadHash": canonical_hash(payload)}


def _test_environment() -> dict[str, str]:
    # Do not let a repair subprocess inherit a Codex thread/session identity.
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("CODEX_", "OPENAI_", "SUPER_BRAIN_", "NEXSANDBASE_"))
    }
    environment["PYTHONUTF8"] = "1"
    environment["PYTHONIOENCODING"] = "utf-8"
    return environment


def _run_one(root: Path, label: str, command: tuple[str, ...], timeout: float) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        completed = subprocess.run(
            [sys.executable, *command],
            cwd=str(root),
            env=_test_environment(),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=max(0.1, timeout),
            check=False,
        )
        return {
            "label": label,
            "state": "passed" if completed.returncode == 0 else "failed",
            "exitCode": int(completed.returncode),
            "durationMs": round((time.perf_counter() - started) * 1000),
            "stdout": _bounded_text(completed.stdout),
            "stderr": _bounded_text(completed.stderr),
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "label": label,
            "state": "timeout",
            "exitCode": None,
            "durationMs": round((time.perf_counter() - started) * 1000),
            "stdout": _bounded_text(exc.stdout),
            "stderr": _bounded_text(exc.stderr),
        }
    except OSError as exc:
        return {
            "label": label,
            "state": "failed",
            "exitCode": None,
            "durationMs": round((time.perf_counter() - started) * 1000),
            "stdout": "",
            "stderr": _bounded_text(type(exc).__name__ + ": " + str(exc)),
        }


def run_verification(
    package_root: str | Path,
    *,
    mode: str = "rapid",
    tests: Iterable[str] | None = None,
) -> dict[str, Any]:
    root = _package_root(package_root)
    if mode not in PROFILE_POLICY:
        raise ValueError("unknown external repair delivery profile")
    policy = PROFILE_POLICY[mode]
    labels = tuple(str(item) for item in (tests if tests is not None else policy["defaultTests"]))
    if not labels:
        raise ValueError("external repair verification requires at least one test")
    unknown = [label for label in labels if label not in _TEST_COMMANDS]
    if unknown:
        raise ValueError("unknown or non-allow-listed external repair test: " + ",".join(unknown))
    started = time.perf_counter()
    deadline = started + float(policy["budgetSeconds"])
    results: list[dict[str, Any]] = []
    failures = 0
    changed_hypothesis = False
    stop_reason = "completed"
    for label in labels:
        if failures >= int(policy["failureLimit"]):
            changed_hypothesis = True
            stop_reason = "failure_budget_exhausted_change_hypothesis"
            break
        remaining = deadline - time.perf_counter()
        if remaining <= 0:
            stop_reason = "time_budget_exhausted"
            break
        result = _run_one(root, label, _TEST_COMMANDS[label], remaining)
        results.append(result)
        if result["state"] != "passed":
            failures += 1
    if failures >= int(policy["failureLimit"]) and len(results) < len(labels):
        changed_hypothesis = True
        stop_reason = "failure_budget_exhausted_change_hypothesis"
    elapsed_ms = round((time.perf_counter() - started) * 1000)
    passed = bool(results) and all(result["state"] == "passed" for result in results) and len(results) == len(labels)
    payload = {
        "schema": SCHEMA,
        "action": "verify",
        "state": "passed" if passed else "blocked" if changed_hypothesis else "failed",
        "controllerMode": "super_brain_external_repair",
        "mode": mode,
        "budgetSeconds": int(policy["budgetSeconds"]),
        "elapsedMs": elapsed_ms,
        "failureCount": failures,
        "changedHypothesisRequired": changed_hypothesis,
        "stopReason": stop_reason,
        "tests": results,
        "authority": _authority_projection(),
        "rawPromptStored": False,
        "rawTranscriptStored": False,
    }
    return {**payload, "payloadHash": canonical_hash(payload)}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Independent Super Brain external repair lane")
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--action", choices=("inspect", "plan", "verify"), default="inspect")
    parser.add_argument("--mode", choices=PROFILE_NAMES, default="rapid")
    parser.add_argument("--path", action="append", default=[])
    parser.add_argument("--test", action="append", default=[])
    parser.add_argument("--json", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.action == "inspect":
            result = inspect_package(args.package_root)
        elif args.action == "plan":
            result = plan_delivery(args.package_root, args.path)
        else:
            result = run_verification(args.package_root, mode=args.mode, tests=args.test or None)
    except (OSError, ValueError) as exc:
        result = {
            "schema": SCHEMA,
            "action": args.action,
            "state": "blocked",
            "controllerMode": "super_brain_external_repair",
            "code": "EXTERNAL_REPAIR_INPUT_INVALID",
            "error": _bounded_text(str(exc), 320),
            "authority": _authority_projection(),
            "rawPromptStored": False,
            "rawTranscriptStored": False,
        }
        result["payloadHash"] = canonical_hash(result)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0 if result.get("state") in {"current", "ready", "passed"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
