from __future__ import annotations

import argparse
import gc
import json
import math
import os
import random
import shutil
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "vendor" / "NexSandglass-Agent-DedicatedMemory"
sys.path.insert(0, str(ROOT / "runtime"))

from brain_core import BrainCore


QUERY_DATE = "2026-07-18"
WORKSPACE_KEY = "ws-diagnostic-recall-59600000"


def percentile(values: list[float], ratio: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * ratio) - 1))
    return ordered[index]


def records() -> list[dict[str, str]]:
    return [
        {"id": "long-ember", "timestamp": "2024-01-03 09:00:00", "text": "[PROJECT][VERIFIED][SUMMARY] Ember archive recovery uses dual parity segments and a seven-day verification sweep."},
        {"id": "long-lantern", "timestamp": "2024-02-11 09:00:00", "text": "[PROFILE][VERIFIED][SUMMARY] The user prefers release reports with the decision first, evidence second, and residual risk last."},
        {"id": "long-harbor", "timestamp": "2024-03-20 09:00:00", "text": "[DECISION][VERIFIED][SUMMARY] decision:harbor-retry-policy Harbor retries use capped exponential delay with a ninety-second ceiling."},
        {"id": "long-cascade", "timestamp": "2024-04-17 09:00:00", "text": "[SESSION][VERIFIED][SUMMARY] Cascade migration completed with checksum manifest cdx-481 and no missing objects."},
        {"id": "exact-quartz", "timestamp": "2026-07-17 09:00:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] decision:quartz-cache-policy Quartz cache TTL is thirty-seven minutes."},
        {"id": "exact-borealis", "timestamp": "2026-07-17 09:01:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] Borealis deployment target is edge cluster Helios-7."},
        {"id": "exact-orchid", "timestamp": "2026-07-17 09:02:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] Orchid audit log retention is forty-five days."},
        {"id": "exact-citadel", "timestamp": "2026-07-17 09:03:00", "text": "[DECISION][CURRENT][VERIFIED][SUMMARY] decision:citadel-signing-mode Citadel signing mode is offline threshold approval."},
        {"id": "alias-browser", "timestamp": "2026-07-17 09:10:00", "text": "[DECISION][CURRENT][VERIFIED][SUMMARY] key=browser-automation-tool-priority Playwright is primary; browser-act is fallback only when Playwright cannot reliably finish."},
        {"id": "alias-engineering", "timestamp": "2026-07-17 09:11:00", "text": "[PROFILE][CURRENT][VERIFIED][SUMMARY] Evidence-bounded engineering judgment separates FACT, INFERENCE, and UNKNOWN before choosing a solution."},
        {"id": "alias-proactive", "timestamp": "2026-07-17 09:12:00", "text": "[DECISION][CURRENT][VERIFIED][SUMMARY] key=proactive-engineering-intervention-threshold Intervene only for material benefit or material risk."},
        {"id": "alias-hygiene", "timestamp": "2026-07-17 09:13:00", "text": "[PROFILE][CURRENT][VERIFIED][SUMMARY] Memory hygiene is maintained proactively with bounded pruning and conflict replacement."},
        {"id": "fuzzy-telemetry", "timestamp": "2026-07-17 09:20:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] Telemetry traces remain searchable for forty-five days before cold deletion."},
        {"id": "fuzzy-nimbus", "timestamp": "2026-07-17 09:21:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] The Nimbus exporter batches metrics every seventeen seconds."},
        {"id": "fuzzy-phoenix", "timestamp": "2026-07-17 09:22:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] 凤凰模块的故障转移等待时间为二十三秒。"},
        {"id": "fuzzy-redwood", "timestamp": "2026-07-17 09:23:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] Redwood reports are encrypted with XChaCha20 before upload."},
        {"id": "fuzzy-delta", "timestamp": "2026-07-17 09:24:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] Delta sensor calibration runs at local midnight."},
        {"id": "fuzzy-aurora", "timestamp": "2026-07-17 09:25:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] Aurora queue rejects payloads larger than eight MiB."},
        {"id": "temporal-atlas-old", "timestamp": "2026-07-04 10:00:00", "text": "[SESSION][VERIFIED][SUMMARY] session_date=2026-07-04 I switched the Atlas build runner to cobalt-3."},
        {"id": "temporal-atlas-current", "timestamp": "2026-07-17 10:00:00", "text": "[SESSION][CURRENT][VERIFIED][SUMMARY] session_date=2026-07-17 I switched the Atlas build runner to cobalt-9."},
        {"id": "temporal-meridian-old", "timestamp": "2026-06-18 10:00:00", "text": "[SESSION][VERIFIED][SUMMARY] session_date=2026-06-18 I changed the Meridian backup window to 02:30."},
        {"id": "temporal-meridian-current", "timestamp": "2026-07-17 10:01:00", "text": "[SESSION][CURRENT][VERIFIED][SUMMARY] session_date=2026-07-17 I changed the Meridian backup window to 04:45."},
        {"id": "temporal-galaxy-old", "timestamp": "2026-07-11 10:00:00", "text": "[SESSION][VERIFIED][SUMMARY] session_date=2026-07-11 我把星河项目的发布通道改成了灰度二组。"},
        {"id": "temporal-galaxy-current", "timestamp": "2026-07-17 10:02:00", "text": "[SESSION][CURRENT][VERIFIED][SUMMARY] session_date=2026-07-17 我把星河项目的发布通道改成了蓝色四组。"},
        {"id": "temporal-raven-old", "timestamp": "2025-07-18 10:00:00", "text": "[SESSION][VERIFIED][SUMMARY] session_date=2025-07-18 Raven release approval moved to team amber."},
        {"id": "temporal-raven-current", "timestamp": "2026-07-17 10:03:00", "text": "[SESSION][CURRENT][VERIFIED][SUMMARY] session_date=2026-07-17 Raven release approval moved to team violet."},
        {"id": "profile-review", "timestamp": "2026-07-17 11:00:00", "text": "[PROFILE][CURRENT][VERIFIED][SUMMARY] My preferred code-review format is severity first with file evidence."},
        {"id": "profile-ide", "timestamp": "2026-07-17 11:01:00", "text": "[PROFILE][CURRENT][VERIFIED][SUMMARY] My favorite IDE is JetBrains Rider."},
        {"id": "profile-frontend", "timestamp": "2026-07-17 11:02:00", "text": "[PROFILE][CURRENT][VERIFIED][SUMMARY] 我的前端框架偏好是 Vue 3。"},
        {"id": "profile-major", "timestamp": "2026-07-17 11:03:00", "text": "[PROFILE][CURRENT][VERIFIED][SUMMARY] 我的大学专业是机械工程。"},
        {"id": "profile-language", "timestamp": "2026-07-17 11:04:00", "text": "[PROFILE][CURRENT][VERIFIED][SUMMARY] My favorite programming language is Rust."},
        {"id": "conflict-ion-old", "timestamp": "2025-01-01 12:00:00", "text": "[DECISION][VERIFIED][SUMMARY] decision:ion-throttle-policy Ion throttle limit is twelve requests per second."},
        {"id": "conflict-ion-current", "timestamp": "2026-07-17 12:00:00", "text": "[DECISION][CURRENT][VERIFIED][SUMMARY] decision:ion-throttle-policy Ion throttle limit is forty requests per second."},
        {"id": "conflict-layout-old", "timestamp": "2025-02-01 12:00:00", "text": "[PROFILE][VERIFIED][SUMMARY] Dashboard layout preference is dense cards."},
        {"id": "conflict-layout-current", "timestamp": "2026-07-17 12:01:00", "text": "[PROFILE][CURRENT][VERIFIED][SUMMARY] Dashboard layout preference is a compact table."},
        {"id": "conflict-pegasus-old", "timestamp": "2025-03-01 12:00:00", "text": "[PROJECT][VERIFIED][SUMMARY] Pegasus database engine is SQLite."},
        {"id": "conflict-pegasus-current", "timestamp": "2026-07-17 12:02:00", "text": "[PROJECT][CURRENT][VERIFIED][SUMMARY] Pegasus database engine is PostgreSQL."},
    ]


def graph_records() -> list[dict[str, str]]:
    return [
        {"id": "graph-nebula", "subject": "decision:nebula-storage", "relation": "decides", "object": "use append-only segments", "evidence": "verified design record", "tags": "current verified"},
        {"id": "graph-quasar", "subject": "quasar-index", "relation": "affects", "object": "compaction scheduler", "evidence": "verified dependency map", "tags": "current"},
        {"id": "graph-meteor", "subject": "流星部署", "relation": "has_consequence", "object": "回滚窗口缩短到五分钟", "evidence": "已验证决策", "tags": "current"},
    ]


def cases() -> list[dict[str, Any]]:
    return [
        {"id": "exact-1", "category": "exact", "query": "Quartz cache TTL", "expected": ["exact-quartz"]},
        {"id": "exact-2", "category": "exact", "query": "Borealis deployment target", "expected": ["exact-borealis"]},
        {"id": "exact-3", "category": "exact", "query": "Orchid audit log retention", "expected": ["exact-orchid"]},
        {"id": "exact-4", "category": "exact", "query": "citadel-signing-mode", "expected": ["exact-citadel"]},
        {"id": "alias-1", "category": "alias", "query": "浏览器自动化优先工具", "expected": ["alias-browser"]},
        {"id": "alias-2", "category": "alias", "query": "工程设计师判断方式", "expected": ["alias-engineering"]},
        {"id": "alias-3", "category": "alias", "query": "主动干预阈值", "expected": ["alias-proactive"]},
        {"id": "alias-4", "category": "alias", "query": "记忆维护策略", "expected": ["alias-hygiene"]},
        {"id": "fuzzy-1", "category": "fuzzy", "query": "How long do we retain telemetry traces?", "expected": ["fuzzy-telemetry"]},
        {"id": "fuzzy-2", "category": "fuzzy", "query": "Nimbus metric batching interval", "expected": ["fuzzy-nimbus"]},
        {"id": "fuzzy-3", "category": "fuzzy", "query": "凤凰组件切换备用节点要等多久？", "expected": ["fuzzy-phoenix"]},
        {"id": "fuzzy-4", "category": "fuzzy", "query": "Which cipher protects Redwood report uploads?", "expected": ["fuzzy-redwood"]},
        {"id": "fuzzy-5", "category": "fuzzy", "query": "When is the Delta probe recalibrated?", "expected": ["fuzzy-delta"]},
        {"id": "fuzzy-6", "category": "fuzzy", "query": "maximum Aurora message size", "expected": ["fuzzy-aurora"]},
        {"id": "temporal-1", "category": "temporal", "query": "Which Atlas runner did I switch to two weeks ago?", "expected": ["temporal-atlas-old"], "queryDate": QUERY_DATE},
        {"id": "temporal-2", "category": "temporal", "query": "What Meridian backup time did I set one month ago?", "expected": ["temporal-meridian-old"], "queryDate": QUERY_DATE},
        {"id": "temporal-3", "category": "temporal", "query": "一周前我把星河项目切到哪个发布通道？", "expected": ["temporal-galaxy-old"], "queryDate": QUERY_DATE},
        {"id": "temporal-4", "category": "temporal", "query": "Which Raven approval team did I choose one year ago?", "expected": ["temporal-raven-old"], "queryDate": QUERY_DATE},
        {"id": "task-1", "category": "task", "query": "current task status", "expected": ["task-current"]},
        {"id": "task-2", "category": "task", "query": "what is the next step?", "expected": ["task-current"]},
        {"id": "task-3", "category": "task", "query": "当前任务状态是什么？", "expected": ["task-current"]},
        {"id": "task-4", "category": "task", "query": "下一步要做什么？", "expected": ["task-current"]},
        {"id": "profile-1", "category": "profile", "query": "What is my code review preference?", "expected": ["profile-review"]},
        {"id": "profile-2", "category": "profile", "query": "What is my favorite IDE?", "expected": ["profile-ide"]},
        {"id": "profile-3", "category": "profile", "query": "我偏好的前端框架是什么？", "expected": ["profile-frontend"]},
        {"id": "profile-4", "category": "profile", "query": "我的大学专业是什么？", "expected": ["profile-major"]},
        {"id": "profile-5", "category": "profile", "query": "What is my favorite programming language?", "expected": ["profile-language"]},
        {"id": "graph-1", "category": "graph", "query": "nebula storage decision", "expected": ["graph-nebula"]},
        {"id": "graph-2", "category": "graph", "query": "what does quasar index affect?", "expected": ["graph-quasar"]},
        {"id": "graph-3", "category": "graph", "query": "流星部署有什么后果？", "expected": ["graph-meteor"]},
        {"id": "long-1", "category": "long_term", "query": "Ember archive recovery parity", "expected": ["long-ember"]},
        {"id": "long-2", "category": "long_term", "query": "release report decision evidence residual risk preference", "expected": ["long-lantern"]},
        {"id": "long-3", "category": "long_term", "query": "harbor-retry-policy", "expected": ["long-harbor"]},
        {"id": "long-4", "category": "long_term", "query": "Cascade checksum manifest", "expected": ["long-cascade"]},
        {"id": "conflict-1", "category": "conflict", "query": "ion-throttle-policy", "expected": ["conflict-ion-current"]},
        {"id": "conflict-2", "category": "conflict", "query": "current dashboard layout preference", "expected": ["conflict-layout-current"]},
        {"id": "conflict-3", "category": "conflict", "query": "current Pegasus database engine", "expected": ["conflict-pegasus-current"]},
        {"id": "conflict-4", "category": "conflict", "query": "current Atlas build runner", "expected": ["temporal-atlas-current"]},
        {"id": "unknown-1", "category": "unknown", "query": "What is my favorite dessert?", "expected": []},
        {"id": "unknown-2", "category": "unknown", "query": "我的生日是哪一天？", "expected": []},
        {"id": "unknown-3", "category": "unknown", "query": "Where is my home address?", "expected": []},
        {"id": "unknown-4", "category": "unknown", "query": "What is my pet's name?", "expected": []},
        {"id": "unknown-5", "category": "unknown", "query": "What is the Zephyr-991 launch code?", "expected": []},
        {"id": "unknown-6", "category": "unknown", "query": "不存在的天琴座密钥编号是多少？", "expected": []},
        {"id": "unknown-7", "category": "unknown", "query": "What is the deployment port?", "expected": []},
        {"id": "unknown-8", "category": "unknown", "query": "What database backs the polar observatory?", "expected": []},
    ]


def expanded_cases(include_variants: bool) -> list[dict[str, Any]]:
    base = cases()
    if not include_variants:
        return base
    expanded: list[dict[str, Any]] = []
    for item in base:
        expanded.append(item)
        query = str(item["query"])
        variants: list[str] = []
        if any("\u4e00" <= character <= "\u9fff" for character in query):
            variants.append("\u8bf7\u95ee" + query.rstrip("？！?。") + "？")
        else:
            lowered = query.lower()
            if lowered != query:
                variants.append(lowered)
            variants.append("Please tell me " + query.rstrip("?!.") + ".")
        for index, variant in enumerate(dict.fromkeys(variants), 1):
            clone = dict(item)
            clone["id"] = f"{item['id']}::variant-{index}"
            clone["query"] = variant
            clone["variantOf"] = item["id"]
            expanded.append(clone)
    return expanded


def write_fixture(state_root: Path) -> tuple[dict[int, str], dict[int, str]]:
    memory_root = state_root / "shared"
    scripts = memory_root / "scripts"
    scripts.mkdir(parents=True)
    for name in ("sandglass_paths.py", "sandglass_lock.py", "sandglass_vault.py", "sandglass_sqlite.py"):
        shutil.copy2(VENDOR / name, scripts / name)

    memory_records = records()
    distractors = [
        {
            "id": f"distractor-{index:03d}",
            "timestamp": f"2026-05-{(index % 28) + 1:02d} 08:00:00",
            "text": f"[SESSION][SUMMARY] Routine diagnostic note {index}: generic deployment review completed with ordinary status evidence.",
        }
        for index in range(1, 181)
    ]
    all_records = [*memory_records, *distractors]
    lines = [f"{item['timestamp']} | user | {item['text']}" for item in all_records]
    (memory_root / "sandglass.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    line_ids = {index: item["id"] for index, item in enumerate(all_records, 1)}

    graphs = graph_records()
    graph_lines = [json.dumps({key: value for key, value in item.items() if key != "id"}, ensure_ascii=False) for item in graphs]
    (state_root / "graph.jsonl").write_text("\n".join(graph_lines) + "\n", encoding="utf-8")
    graph_ids = {index: item["id"] for index, item in enumerate(graphs, 1)}

    workspace = state_root / "workspace"
    task_id = "task-diagnostic-recall"
    version = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))["version"]
    task_context = {
        "status": "active",
        "stale": False,
        "taskId": task_id,
        "taskName": "Recall diagnostic task",
        "workspaceKey": WORKSPACE_KEY,
        "version": version,
        "expiresAt": "2099-01-01 00:00:00",
        "acceptedGoal": "Measure category recall without hidden memory",
        "currentStep": "Run isolated quality cases",
        "nextAction": "Report category recall and abstention",
    }
    checkpoint = {
        "status": "active",
        "taskId": task_id,
        "taskName": "Recall diagnostic task",
        "workspaceKey": WORKSPACE_KEY,
        "goal": "Measure category recall without hidden memory",
        "currentStep": "Run isolated quality cases",
        "nextAction": "Report category recall and abstention",
    }
    workspace.mkdir(parents=True)
    (workspace / "current-task-context.json").write_text(json.dumps(task_context), encoding="utf-8")
    checkpoint_path = workspace / "runtime-state" / "checkpoints" / "active" / f"{task_id}.json"
    checkpoint_path.parent.mkdir(parents=True)
    checkpoint_path.write_text(json.dumps(checkpoint), encoding="utf-8")
    return line_ids, graph_ids


def result_id(source: str, line_ids: dict[int, str], graph_ids: dict[int, str]) -> str:
    if source == "memory\\workspace\\current-task-context.json":
        return "task-current"
    if source.startswith("memory\\graph.jsonl:"):
        try:
            return graph_ids.get(int(source.rsplit(":", 1)[1]), source)
        except ValueError:
            return source
    try:
        return line_ids.get(int(source.split(":", 1)[0]), source)
    except ValueError:
        return source


def evaluate(core: BrainCore, line_ids: dict[int, str], graph_ids: dict[int, str], include_variants: bool) -> dict[str, Any]:
    suite = expanded_cases(include_variants)
    random.Random(596).shuffle(suite)
    cold_start = time.perf_counter()
    core.recall("Quartz cache TTL", top_k=3, max_tokens=500)
    cold_start_ms = (time.perf_counter() - cold_start) * 1000.0

    case_results: list[dict[str, Any]] = []
    latencies: list[float] = []
    for case in suite:
        started = time.perf_counter()
        items = core.recall(
            case["query"],
            top_k=3,
            max_tokens=500,
            query_date=str(case.get("queryDate", "")),
        )
        latency_ms = (time.perf_counter() - started) * 1000.0
        latencies.append(latency_ms)
        returned = [result_id(str(item.get("source", "")), line_ids, graph_ids) for item in items]
        expected = list(case["expected"])
        positive = bool(expected)
        hit_at_1 = positive and bool(returned) and returned[0] in expected
        hit_at_3 = positive and any(item in expected for item in returned[:3])
        relevant_count = sum(item in expected for item in returned[:3])
        false_count = sum(item not in expected for item in returned[:3])
        case_results.append(
            {
                "id": case["id"],
                "category": case["category"],
                "query": case["query"],
                "expected": expected,
                "returned": returned,
                "hitAt1": hit_at_1,
                "hitAt3": hit_at_3,
                "abstained": not returned,
                "relevantReturned": relevant_count,
                "falseReturned": false_count,
                "latencyMs": round(latency_ms, 3),
            }
        )

    category_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in case_results:
        category_rows[item["category"]].append(item)
    categories: dict[str, Any] = {}
    for category, rows in sorted(category_rows.items()):
        positives = [row for row in rows if row["expected"]]
        returned_count = sum(len(row["returned"][:3]) for row in rows)
        relevant_count = sum(row["relevantReturned"] for row in rows)
        if positives:
            categories[category] = {
                "cases": len(rows),
                "recallAt1": round(sum(row["hitAt1"] for row in positives) / len(positives), 4),
                "recallAt3": round(sum(row["hitAt3"] for row in positives) / len(positives), 4),
                "precisionAt3": round(relevant_count / max(returned_count, 1), 4),
                "falseRecallRate": round((returned_count - relevant_count) / max(returned_count, 1), 4),
            }
        else:
            categories[category] = {
                "cases": len(rows),
                "abstentionRate": round(sum(row["abstained"] for row in rows) / len(rows), 4),
                "falseRecallRate": round(sum(not row["abstained"] for row in rows) / len(rows), 4),
            }

    positives = [row for row in case_results if row["expected"]]
    unknowns = [row for row in case_results if not row["expected"]]
    returned_count = sum(len(row["returned"][:3]) for row in positives)
    relevant_count = sum(row["relevantReturned"] for row in positives)
    return {
        "schema": "super-brain.recall-quality-diagnostic.v1",
        "status": "diagnostic_non_publishable",
        "packageVersion": str(core.manifest.get("version", "")),
        "corpus": {
            "positiveCases": len(positives),
            "unknownCases": len(unknowns),
            "variantCases": sum(1 for item in suite if item.get("variantOf")),
            "categories": sorted(categories),
            "sealedHoldoutsRead": False,
            "realUserMemoryRead": False,
        },
        "overall": {
            "recallAt1": round(sum(row["hitAt1"] for row in positives) / max(len(positives), 1), 4),
            "recallAt3": round(sum(row["hitAt3"] for row in positives) / max(len(positives), 1), 4),
            "precisionAt3": round(relevant_count / max(returned_count, 1), 4),
            "falseRecallRate": round((returned_count - relevant_count) / max(returned_count, 1), 4),
            "unknownAbstentionRate": round(sum(row["abstained"] for row in unknowns) / max(len(unknowns), 1), 4),
        },
        "latency": {
            "coldStartMs": round(cold_start_ms, 3),
            "warmP50Ms": round(percentile(latencies, 0.50), 3),
            "warmP95Ms": round(percentile(latencies, 0.95), 3),
            "warmMaxMs": round(max(latencies or [0.0]), 3),
        },
        "categories": categories,
        "failures": [
            item
            for item in case_results
            if (item["expected"] and not item["hitAt3"]) or (not item["expected"] and not item["abstained"])
        ],
        "cases": case_results,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Isolated non-publishable Super Brain recall quality diagnostic")
    parser.add_argument("--output", default="")
    parser.add_argument("--gate", action="store_true")
    parser.add_argument("--variants", action="store_true")
    args = parser.parse_args()

    old_workspace_key = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
    old_memory_home = os.environ.get("NEXSANDBASE_HOME")
    try:
        with tempfile.TemporaryDirectory(prefix="super-brain-recall-quality-") as directory:
            state_root = Path(directory) / "state"
            line_ids, graph_ids = write_fixture(state_root)
            os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = WORKSPACE_KEY
            core = BrainCore(ROOT, state_root / "shared")
            report = evaluate(core, line_ids, graph_ids, args.variants)
            core._memory_modules.clear()
            gc.collect()
    finally:
        if old_workspace_key is None:
            os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
        else:
            os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = old_workspace_key
        if old_memory_home is None:
            os.environ.pop("NEXSANDBASE_HOME", None)
        else:
            os.environ["NEXSANDBASE_HOME"] = old_memory_home

    if args.output:
        output = Path(args.output).expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))

    if not args.gate:
        return 0
    overall = report["overall"]
    gate_ok = (
        overall["recallAt3"] >= 0.90
        and overall["unknownAbstentionRate"] >= 0.95
        and report["latency"]["warmP95Ms"] < 100.0
    )
    return 0 if gate_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
