from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from brain_core import BrainCore


def _contains_all(text: str, values: list[Any]) -> bool:
    return all(str(value) in text for value in values or [])


def _contains_none(text: str, values: list[Any]) -> bool:
    return all(str(value) not in text for value in values or [])


def _percentile(values: list[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * percentile) - 1))
    return ordered[index]


def _mcp_replay(root: Path, memory_root: str, require_recall_result: bool = True) -> dict[str, Any]:
    """Replay the narrow stdio contract, including the nested tool payload JSON."""
    script = root / "runtime" / "brain_mcp.py"
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "brain_recall",
                "arguments": {
                    "query": "当前 super-memory-brain 版本是多少？",
                    "top_k": 3,
                    "max_tokens": 500,
                },
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "brain_status", "arguments": {}},
        },
        {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {"name": "brain_recent", "arguments": {"limit": 3}},
        },
    ]
    payload = "\n".join(json.dumps(item, ensure_ascii=False) for item in requests) + "\n"
    checks: list[dict[str, Any]] = []
    errors: list[str] = []

    try:
        completed = subprocess.run(
            [
                sys.executable,
                str(script),
                "--package-root",
                str(root),
                "--memory-root",
                memory_root,
            ],
            input=payload,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="strict",
            timeout=15,
            check=False,
        )
    except (OSError, UnicodeError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "checks": [], "errors": [f"process:{exc}"]}

    lines = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if completed.returncode != 0:
        errors.append(f"process_exit:{completed.returncode}")
    if len(lines) != len(requests):
        errors.append(f"response_count:{len(lines)} expected:{len(requests)}")

    responses: list[dict[str, Any]] = []
    for index, line in enumerate(lines):
        try:
            envelope = json.loads(line)
            if not isinstance(envelope, dict):
                raise ValueError("response is not an object")
            responses.append(envelope)
        except (TypeError, ValueError, json.JSONDecodeError) as exc:
            errors.append(f"response_json:{index}:{exc}")

    def take(index: int, expected_id: int) -> dict[str, Any] | None:
        if index >= len(responses):
            return None
        envelope = responses[index]
        if envelope.get("id") != expected_id:
            errors.append(f"response_id:{expected_id}:{envelope.get('id')}")
        if "error" in envelope:
            errors.append(f"rpc_error:{expected_id}:{envelope['error']}")
        return envelope

    initialize = take(0, 1)
    initialized_ok = bool(
        initialize
        and isinstance(initialize.get("result"), dict)
        and initialize["result"].get("protocolVersion")
        and initialize["result"].get("serverInfo", {}).get("name") == "super-memory-brain"
    )
    checks.append({"name": "initialize", "ok": initialized_ok})
    if not initialized_ok:
        errors.append("initialize_contract")

    listed = take(1, 2)
    listed_tools = []
    if listed and isinstance(listed.get("result"), dict):
        listed_tools = [str(item.get("name")) for item in listed["result"].get("tools", []) if isinstance(item, dict)]
    tools_ok = set(listed_tools) == {"brain_recall", "brain_status", "brain_recent"}
    checks.append({"name": "tools_list", "ok": tools_ok, "tools": listed_tools})
    if not tools_ok:
        errors.append("tools_list_contract")

    for index, expected_id, tool_name, expected_type in (
        (2, 3, "brain_recall", list),
        (3, 4, "brain_status", dict),
        (4, 5, "brain_recent", list),
    ):
        envelope = take(index, expected_id)
        nested: Any = None
        nested_ok = False
        if envelope and isinstance(envelope.get("result"), dict):
            content = envelope["result"].get("content", [])
            if content and isinstance(content[0], dict) and isinstance(content[0].get("text"), str):
                try:
                    nested = json.loads(content[0]["text"])
                    nested_ok = isinstance(nested, expected_type)
                    if tool_name == "brain_recall":
                        nested_ok = nested_ok and (not require_recall_result or len(nested) > 0)
                    if tool_name == "brain_status":
                        nested_ok = nested_ok and nested.get("runtime") == "super-brain-core-python"
                except (TypeError, ValueError, json.JSONDecodeError) as exc:
                    errors.append(f"nested_json:{tool_name}:{exc}")
        checks.append({"name": f"call_{tool_name}", "ok": nested_ok})
        if not nested_ok:
            errors.append(f"tool_payload_contract:{tool_name}")

    stderr = completed.stderr.strip()
    return {
        "ok": not errors,
        "checks": checks,
        "errors": errors,
        "responseCount": len(lines),
        "stderr": stderr[:240],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Super Brain runtime recall contract replay")
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--memory-root", default="")
    parser.add_argument("--tests", default="")
    parser.add_argument("--mcp-replay", action="store_true")
    parser.add_argument("--contract-only", action="store_true")
    args = parser.parse_args()

    root = Path(args.package_root).expanduser().resolve()
    tests_path = Path(args.tests).expanduser().resolve() if args.tests else root / "tests" / "memory-eval-tests.json"
    cases = json.loads(tests_path.read_text(encoding="utf-8-sig"))
    core = BrainCore(root, args.memory_root or None)
    results: list[dict[str, Any]] = []
    latencies: list[float] = []

    for case in ([] if args.contract_only else cases):
        if case.get("mode") != "recallSearch":
            continue
        query = str(case.get("query", case.get("question", "")))
        start = time.perf_counter()
        items = core.recall(
            query,
            int(case.get("topK", 3)),
            int(case.get("maxTokens", 1200)),
            str(case.get("layer", "all")),
        )
        latency_ms = (time.perf_counter() - start) * 1000.0
        latencies.append(latency_ms)
        serialized = json.dumps(items, ensure_ascii=False)
        first = json.dumps(items[0], ensure_ascii=False) if items else ""
        confidences = [float(item.get("confidence", 0.0)) for item in items]
        max_confidence = max(confidences or [0.0])
        max_results = int(case.get("maxResults", -1))
        ok = (
            len(items) >= int(case.get("minResults", 0))
            and (max_results < 0 or len(items) <= max_results)
            and max_confidence >= float(case.get("minConfidence", 0.0))
            and _contains_all(serialized, case.get("mustContain", []))
            and _contains_none(serialized, case.get("mustNotContain", []))
            and _contains_all(first, case.get("firstMustContain", []))
            and _contains_none(first, case.get("firstMustNotContain", []))
        )
        results.append(
            {
                "id": str(case.get("id", query)),
                "ok": ok,
                "resultCount": len(items),
                "maxConfidence": round(max_confidence, 4),
                "latencyMs": round(latency_ms, 3),
            }
        )

    failed = [item for item in results if not item["ok"]]
    warm_latencies = latencies[1:] if len(latencies) > 1 else latencies
    report = {
        "ok": not failed,
        "suite": "super-brain-runtime-recall",
        "total": len(results),
        "passed": len(results) - len(failed),
        "failed": len(failed),
        "latency": {
            "sampleCount": len(latencies),
            "coldStartMs": round(latencies[0], 3) if latencies else 0.0,
            "p50Ms": round(_percentile(latencies, 0.50), 3),
            "p95Ms": round(_percentile(latencies, 0.95), 3),
            "maxMs": round(max(latencies or [0.0]), 3),
            "warmP50Ms": round(_percentile(warm_latencies, 0.50), 3),
            "warmP95Ms": round(_percentile(warm_latencies, 0.95), 3),
            "warmMaxMs": round(max(warm_latencies or [0.0]), 3),
        },
        "cases": results,
        "contractOnly": bool(args.contract_only),
    }
    if args.mcp_replay:
        report["mcpReplay"] = _mcp_replay(
            root,
            args.memory_root or str(core.memory_root),
            require_recall_result=not args.contract_only,
        )
        report["ok"] = report["ok"] and report["mcpReplay"]["ok"]
    print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
