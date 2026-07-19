from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from brain_core import BrainCore


def response(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def tool_result(payload: Any, is_error: bool = False) -> dict[str, Any]:
    return {
        "content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False, separators=(",", ":"))}],
        "isError": is_error,
    }


TOOLS = [
    {
        "name": "brain_recall",
        "description": "Bounded read-only Super Brain recall.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "top_k": {"type": "integer", "minimum": 1, "maximum": 10, "default": 3},
                "max_tokens": {"type": "integer", "minimum": 32, "maximum": 4000, "default": 1200},
                "layer": {
                    "type": "string",
                    "enum": ["all", "profile", "project", "decision", "task", "session"],
                    "default": "all",
                },
                "query_date": {"type": "string", "description": "Optional reference date for relative-time recall."},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "brain_status",
        "description": "Read Super Brain runtime and verified state.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "brain_recent",
        "description": "Read a compact recent-memory tail.",
        "inputSchema": {
            "type": "object",
            "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 20, "default": 5}},
            "additionalProperties": False,
        },
    },
]


def handle_tool(core: BrainCore, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name == "brain_recall":
        return tool_result(
            core.recall(
                str(arguments.get("query", "")),
                int(arguments.get("top_k", 3)),
                int(arguments.get("max_tokens", 1200)),
                str(arguments.get("layer", "all")),
                str(arguments.get("query_date", "")),
            )
        )
    if name == "brain_status":
        return tool_result(core.status())
    if name == "brain_recent":
        return tool_result(core.recent(int(arguments.get("limit", 5))))
    return tool_result({"error": f"unknown tool: {name}"}, True)


def serve(core: BrainCore) -> int:
    for raw in sys.stdin:
        raw = raw.lstrip("\ufeff").strip()
        if not raw:
            continue
        try:
            request = json.loads(raw)
        except json.JSONDecodeError:
            print(json.dumps(error(None, -32700, "parse error"), separators=(",", ":")), flush=True)
            continue
        if "id" not in request:
            continue
        request_id = request.get("id")
        method = request.get("method", "")
        try:
            if method == "initialize":
                result = {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "super-memory-brain", "version": str(core.status().get("version", "0"))},
                }
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                params = request.get("params", {}) or {}
                result = handle_tool(core, str(params.get("name", "")), params.get("arguments", {}) or {})
            elif method == "ping":
                result = {}
            else:
                print(json.dumps(error(request_id, -32601, f"unknown method: {method}"), separators=(",", ":")), flush=True)
                continue
            print(json.dumps(response(request_id, result), ensure_ascii=False, separators=(",", ":")), flush=True)
        except Exception as exc:
            print(json.dumps(error(request_id, -32000, str(exc)), ensure_ascii=False, separators=(",", ":")), flush=True)
    return 0


def main() -> int:
    if hasattr(sys.stdin, "reconfigure"):
        sys.stdin.reconfigure(encoding="utf-8", errors="strict")
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="strict")
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--memory-root", default="")
    args = parser.parse_args()
    return serve(BrainCore(args.package_root, args.memory_root or None))


if __name__ == "__main__":
    raise SystemExit(main())
