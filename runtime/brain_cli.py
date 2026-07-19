from __future__ import annotations

import argparse
import base64
import json
import sys

from brain_core import BrainCore


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Super Brain local runtime CLI")
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--memory-root", default="")
    parser.add_argument("--base64", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    recall = sub.add_parser("recall")
    recall.add_argument("--query", required=True)
    recall.add_argument("--top-k", type=int, default=3)
    recall.add_argument("--max-tokens", type=int, default=1200)
    recall.add_argument("--layer", default="all")
    recall.add_argument("--query-date", default="")

    recent = sub.add_parser("recent")
    recent.add_argument("--limit", type=int, default=5)

    sub.add_parser("status")
    sub.add_parser("health")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    core = BrainCore(args.package_root, args.memory_root or None)
    if args.command == "recall":
        result = core.recall(args.query, args.top_k, args.max_tokens, args.layer, args.query_date)
    elif args.command == "recent":
        result = core.recent(args.limit)
    elif args.command == "status":
        result = core.status()
    else:
        result = core.health()
    payload = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if args.base64:
        sys.stdout.write(base64.b64encode(payload).decode("ascii"))
    else:
        sys.stdout.buffer.write(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
