from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))
sys.path.insert(0, str(ROOT / "tests"))

from brain_core import BrainCore
from turn_runtime import run_turn
import turn_close_dispatcher

from runtime_turn_runtime_regression import local_scope, write_context_contract, write_native_memory_snapshot


def run_chain(index: int) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix=f"super-brain-chain-bench-{index}-") as raw:
        base = Path(raw)
        state_root = base / "state"
        memory_root = state_root / "shared"
        project_root = base / "project"
        memory_root.mkdir(parents=True)
        project_root.mkdir()
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        session_key = "sid-" + f"{index:024d}"[-24:]
        task_id = f"task-chain-benchmark-{index}"
        write_native_memory_snapshot(state_root / "workspace")
        write_context_contract(state_root, project_root, session_key, task_id=task_id)
        core = BrainCore(ROOT, memory_root)
        checkpoint = {
            "last_confirmed_sentence": "Checkpoint is verified locally.",
            "source": "assistant_visible_reply",
            "current_phase": "Fixture",
            "current_step": "Open the governed turn.",
            "next_action": "Run the local runtime verification.",
        }
        result: dict[str, object] = {"index": index, "stateRoot": str(state_root)}
        with local_scope(project_root, session_key):
            started = time.perf_counter()
            opened = run_turn(core, phase="open", turn_intent="design_evaluate")
            result["openMs"] = round((time.perf_counter() - started) * 1000, 3)
            started = time.perf_counter()
            checkpointed = run_turn(
                core,
                phase="checkpoint",
                turn_intent="design_evaluate",
                progress_checkpoint=checkpoint,
                transition_id=f"chain-benchmark-checkpoint-{index}",
            )
            result["checkpointMs"] = round((time.perf_counter() - started) * 1000, 3)
            started = time.perf_counter()
            closed = run_turn(
                core,
                phase="close",
                turn_intent="design_evaluate",
                turn_outcome="active_work_progressed",
                user_control="none",
                completion_evidence_ref=f"fixture:chain-benchmark:{index}",
            )
            result["closeMs"] = round((time.perf_counter() - started) * 1000, 3)
        result["codes"] = [opened.get("code"), checkpointed.get("code"), closed.get("code")]
        result["available"] = [opened.get("available"), checkpointed.get("available"), closed.get("available")]
        result["closeDispatch"] = (closed.get("dispatch") or {}).get("code") if isinstance(closed.get("dispatch"), dict) else ""
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("resident", "cold"), default="resident")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    repeat = max(1, min(int(args.repeat), 8))
    previous_transport = os.environ.get("SUPER_BRAIN_MCP_TRANSPORT")
    turn_close_dispatcher._shutdown_authority_channel()
    if args.mode == "resident":
        os.environ["SUPER_BRAIN_MCP_TRANSPORT"] = "codex_registered_v1"
    else:
        os.environ.pop("SUPER_BRAIN_MCP_TRANSPORT", None)
    try:
        started = time.perf_counter()
        rows = [run_chain(index) for index in range(repeat)]
        elapsed = round((time.perf_counter() - started) * 1000, 3)
        print(json.dumps({"mode": args.mode, "repeat": repeat, "wallMs": elapsed, "rows": rows}, ensure_ascii=False))
        return 0
    finally:
        turn_close_dispatcher._shutdown_authority_channel()
        if previous_transport is None:
            os.environ.pop("SUPER_BRAIN_MCP_TRANSPORT", None)
        else:
            os.environ["SUPER_BRAIN_MCP_TRANSPORT"] = previous_transport


if __name__ == "__main__":
    raise SystemExit(main())
