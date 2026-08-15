import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from brain_control import BrainControl
from brain_context import canonical_hash, intent_context_projection_path, scope_ref
from brain_core import BrainCore, Candidate, GraphEdge
from brain_mcp import TOOLS as MCP_TOOLS, handle_tool
from continuation_policy import decide_turn_close
from layout_paths import resolve_layout_path, state_root
from turn_close_dispatcher import _normalize_progress_checkpoint
from turn_intent import resolve_turn_intent


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def make_core(workspace: Path) -> BrainCore:
    core = BrainCore(ROOT, ROOT / "memory" / "shared")
    core.workspace = workspace
    return core


def package_version() -> str:
    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    return str(manifest["version"])


def host_workspace_key(path: Path) -> str:
    source = os.path.abspath(str(path)).rstrip("/\\").lower()
    return "ws-" + hashlib.sha256(source.encode("utf-8")).hexdigest()[:24]


def file_hashes(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def write_native_memory_snapshot(workspace: Path) -> None:
    body = {
        "schema": "super-brain.native-memory-influence-snapshot.v1",
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "entryCount": 2,
        "entries": [
            {
                "kind": "preference",
                "bucket": "behaviorGuidance",
                "scopeKind": "global",
                "scopeRef": scope_ref("user"),
                "item": {
                    "cardId": "card-context-preference",
                    "cardRevision": 1,
                    "title": "Keep verified context bounded",
                    "effect": "shape_behavior",
                    "statement": "Use the active execution contract but keep action authorization withheld.",
                    "conditions": ["A unique Host scope is verified."],
                    "confidence": 99,
                    "strength": "strong",
                },
            },
            {
                "kind": "note",
                "bucket": "references",
                "scopeKind": "session",
                "scopeRef": scope_ref("sid-foreign-session"),
                "item": {
                    "cardId": "card-foreign-session",
                    "cardRevision": 1,
                    "title": "Foreign session marker",
                    "effect": "reference_only",
                    "body": "FOREIGN_SESSION_MUST_NOT_INJECT",
                    "links": [],
                },
            },
        ],
        "omitted": {"invalid": 0, "expired": 0, "notReady": 0, "unsafe": 0},
        "truncated": False,
        "scopeRefAlgorithm": "sha256(canonical-json:{scopeKey})",
        "activeOnly": True,
        "decisionConstraintsStored": False,
        "focusStored": False,
        "rawPromptStored": False,
        "rawSessionIdStored": False,
    }
    write_json(workspace / "native-memory-influence-snapshot.json", {**body, "payloadHash": canonical_hash(body)})


def write_authoritative_task_contract(
    workspace: Path,
    workspace_key: str,
    thread_id: str,
    task_id: str,
    *,
    task_name: str,
    current_step: str,
    next_action: str,
    revision: int = 1,
    updated_at: str | None = None,
) -> str:
    session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
    timestamp = updated_at or datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    contract_name = f"{task_id}--fixture.json"
    focus_id = f"{task_id}-focus"
    write_json(
        workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
        {
            "schema": "super-brain.execution-hot-index.v1",
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "entries": [
                {
                    "taskId": task_id,
                    "status": "active",
                    "packageVersion": package_version(),
                    "revision": revision,
                    "updatedAt": timestamp,
                    "contractFileName": contract_name,
                }
            ],
        },
    )
    write_json(
        workspace / "runtime-state" / "execution-contracts" / contract_name,
        {
            "schema": "super-brain.execution-contract.v1",
            "taskId": task_id,
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "packageVersion": package_version(),
            "status": "active",
            "revision": revision,
            "focusId": focus_id,
            "focusLabel": task_name,
            "currentStep": current_step,
            "nextAction": next_action,
            "needsReconciliation": False,
            "planReceiptRequired": True,
            "planReceipt": {
                "focusId": focus_id,
                "contractRevision": revision,
                "planFingerprint": f"fixture-{task_id}-{revision}",
            },
            "updatedAt": timestamp,
        },
    )
    return session_key


def make_isolated_recall_core(workspace: Path) -> BrainCore:
    core = make_core(workspace)
    core._graph_candidates = lambda terms: []
    core._experience_candidates = lambda query, terms: []
    core._profile_card_candidates = lambda query, terms: []
    core._recent_candidates = lambda terms, limit: []
    return core


def copy_policy(core: BrainCore) -> dict[str, object]:
    return json.loads(json.dumps(core.policy))


def provenance_sender(role: str, **values: str) -> str:
    payload = {
        "schema": "super-brain.memory-provenance.v1",
        **{key: value for key, value in values.items() if value},
    }
    encoded = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode("utf-8")
    ).decode("ascii").rstrip("=")
    return f"{role};sm1:{encoded}"


def test_adaptive_sparse_recall_uses_fts_before_heavier_backends() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-adaptive-fts-") as directory:
        core = make_core(Path(directory))
        policy = copy_policy(core)
        dynamic = policy["retrieval"]["dynamic"]
        dynamic["fullScanFallback"] = False
        dynamic["adaptiveSparse"] = {
            "enabled": True,
            "fallbackCandidateCount": 1,
            "legacyFallbackOnMiss": True,
            "legacyFallbackMaxQueries": 1,
        }
        core.policy = policy

        searches: list[tuple[str, int]] = []

        def read_only_fts(query: str, limit: int) -> list[tuple[int, str, str]]:
            searches.append((query, limit))
            return [(7, "2026-07-18", "browser automation uses Playwright first")]

        core._read_only_fts_rows = read_only_fts

        results = core._sandglass_candidates("browser automation", top_k=3)

        assert results
        assert results[0].reason == "sandglass_fts5_readonly"
        assert searches


def test_adaptive_sparse_recall_uses_bounded_scan_after_fts_miss() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-adaptive-idx-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        (memory_root / "sandglass.txt").write_text(
            "2026-07-18 09:00:00 | user | fuzzy indexed memory\n",
            encoding="utf-8",
        )
        core = BrainCore(ROOT, memory_root)
        core.workspace = state_root / "workspace"
        policy = copy_policy(core)
        dynamic = policy["retrieval"]["dynamic"]
        dynamic["fullScanFallback"] = True
        dynamic["adaptiveSparse"] = {
            "enabled": True,
            "fallbackCandidateCount": 1,
            "legacyFallbackOnMiss": True,
            "legacyFallbackMaxQueries": 1,
        }
        core.policy = policy

        core._read_only_fts_rows = lambda query, limit: []

        results = core._sandglass_candidates("fuzzy memory", top_k=3)

        assert results
        assert results[0].reason == "sandglass_anchor_scan"


def test_brain_core_keeps_memory_roots_process_isolated() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-root-isolation-") as directory:
        base = Path(directory)
        first_root = base / "first" / "shared"
        second_root = base / "second" / "shared"
        first_root.mkdir(parents=True)
        second_root.mkdir(parents=True)
        (first_root / "sandglass.txt").write_text(
            "2026-07-18 09:00:00 | user | first-root-only-marker\n",
            encoding="utf-8",
        )
        (second_root / "sandglass.txt").write_text(
            "2026-07-18 09:00:00 | user | second-root-only-marker\n",
            encoding="utf-8",
        )
        original_home = os.environ.get("NEXSANDBASE_HOME")
        original_path = list(sys.path)
        first = BrainCore(ROOT, first_root)
        second = BrainCore(ROOT, second_root)

        first_results = first.recall("first-root-only-marker", top_k=1, max_tokens=300)
        second_results = second.recall("second-root-only-marker", top_k=1, max_tokens=300)

        assert first_results and "first-root-only-marker" in first_results[0]["text"]
        assert second_results and "second-root-only-marker" in second_results[0]["text"]
        assert os.environ.get("NEXSANDBASE_HOME") == original_home
        assert sys.path == original_path


def test_brain_core_projects_retired_agent_and_group_roots_to_shared() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-canonical-root-") as directory:
        state_root = Path(directory)
        agent_core = BrainCore(ROOT, state_root / "agents" / "zcode")
        group_core = BrainCore(ROOT, state_root / "groups" / "builders")

        assert agent_core.memory_root == (state_root / "shared").resolve()
        assert group_core.memory_root == (state_root / "shared").resolve()
        assert agent_core.memory_base == state_root.resolve()
        assert group_core.memory_base == state_root.resolve()


def test_runtime_layout_beats_a_stale_nexsandbase_environment_root() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-stale-env-root-") as directory:
        stale_root = Path(directory) / "agents" / "zcode"
        original_home = os.environ.get("NEXSANDBASE_HOME")
        try:
            os.environ["NEXSANDBASE_HOME"] = str(stale_root)
            core = BrainCore(ROOT)
            expected = state_root(ROOT) / "shared"
            assert core.memory_root == expected
        finally:
            if original_home is None:
                os.environ.pop("NEXSANDBASE_HOME", None)
            else:
                os.environ["NEXSANDBASE_HOME"] = original_home


def test_runtime_layout_paths_are_core_relative_and_workspace_bounded() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-core-layout-") as directory:
        workspace = Path(directory) / "workspace"
        core = workspace / "CORE"
        core.mkdir(parents=True)
        (core / "runtime-layout.json").write_text(
            json.dumps(
                {
                    "schema": "super-brain.runtime-layout.v1",
                    "sourceRoot": "..",
                    "runtimeRoot": ".",
                    "stateRoot": "../private-state",
                    "archiveRoot": "../private-archive",
                }
            ),
            encoding="utf-8",
        )

        assert state_root(core) == (workspace / "private-state")
        assert resolve_layout_path(core, "../private-archive") == workspace / "private-archive"
        assert resolve_layout_path(core, "../../unrelated-state") is None


def test_current_task_recall_rejects_stale_global_checkpoint() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-task-recall-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        memory_root.mkdir(parents=True)
        workspace_key = "ws-111111111111111111111111"
        task_id = "task-current-20260717"
        thread_id = "task-recall-stale-global-thread"
        write_json(
            workspace / "status-card.json",
            {
                "workspaceKey": workspace_key,
                "version": package_version(),
                "continuity": {"nextAction": "wrong stale status action"},
            },
        )
        write_json(
            workspace / "current-task-context.json",
            {
                "status": "active",
                "stale": False,
                "taskId": task_id,
                "workspaceKey": workspace_key,
                "version": package_version(),
                "expiresAt": (datetime.now() + timedelta(hours=1)).isoformat(sep=" "),
                "acceptedGoal": "修复当前召回链路",
                "currentStep": "验证任务身份隔离",
                "nextAction": "运行任务召回回归",
            },
        )
        write_authoritative_task_contract(
            workspace,
            workspace_key,
            thread_id,
            task_id,
            task_name="修复当前召回链路",
            current_step="验证任务身份隔离",
            next_action="运行任务召回回归",
        )
        write_json(
            workspace / "active-checkpoint.json",
            {
                "status": "active",
                "taskId": "task-stale-global",
                "workspaceKey": workspace_key,
                "nextAction": "wrong stale checkpoint action",
            },
        )
        write_json(
            workspace / "runtime-state" / "checkpoints" / "active" / f"{task_id}.json",
            {
                "status": "active",
                "taskId": task_id,
                "workspaceKey": workspace_key,
                "currentStep": "验证任务身份隔离",
                "nextAction": "运行任务召回回归",
            },
        )

        previous_workspace = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        os.environ["CODEX_THREAD_ID"] = thread_id
        try:
            core = make_isolated_recall_core(workspace)
            core._sandglass_candidates = lambda query, top_k, query_date="": []
            results = core.recall("当前任务下一步是什么？", top_k=3, max_tokens=500)
        finally:
            if previous_workspace is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread
            if previous_session is not None:
                os.environ["SUPER_BRAIN_SESSION_ID"] = previous_session
        serialized = json.dumps(results, ensure_ascii=False)

        assert results
        assert "运行任务召回回归" in serialized
        assert "wrong stale" not in serialized
        assert all(item["layer"] == "task" for item in results)


def test_unbound_task_pointer_without_current_session_fails_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-unbound-task-pointer-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        workspace_key = "ws-unbound-task-pointer"
        core = BrainCore(ROOT, memory_root)
        write_json(
            core._workspace_context_pointer_path(workspace_key),
            {
                "status": "active",
                "stale": False,
                "taskId": "task-unbound-pointer",
                "workspaceKey": workspace_key,
                "version": package_version(),
                "expiresAt": (datetime.now() + timedelta(hours=1)).isoformat(sep=" "),
                "acceptedGoal": "UNVERIFIED_SCOPE_SENTINEL_BODY",
                "currentStep": "UNVERIFIED_SCOPE_SENTINEL_STEP",
                "nextAction": "UNVERIFIED_SCOPE_SENTINEL_ACTION",
            },
        )
        previous_workspace = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.pop("CODEX_THREAD_ID", None)
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        try:
            assert core._current_task_context() is None
            ordinary = core.recall("current task next step", top_k=1, max_tokens=500, layer="all")
            forced = core.recall("unrelated intent", top_k=1, max_tokens=500, layer="task")
        finally:
            if previous_workspace is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is not None:
                os.environ["CODEX_THREAD_ID"] = previous_thread
            if previous_session is not None:
                os.environ["SUPER_BRAIN_SESSION_ID"] = previous_session

        ordinary_body = json.dumps(ordinary, ensure_ascii=False)
        forced_body = json.dumps(forced, ensure_ascii=False)

        assert ordinary == []
        assert forced == []
        assert "UNVERIFIED_SCOPE_SENTINEL_BODY" not in ordinary_body
        assert "UNVERIFIED_SCOPE_SENTINEL_STEP" not in ordinary_body
        assert "UNVERIFIED_SCOPE_SENTINEL_ACTION" not in ordinary_body
        assert "UNVERIFIED_SCOPE_SENTINEL_BODY" not in forced_body
        assert "UNVERIFIED_SCOPE_SENTINEL_STEP" not in forced_body
        assert "UNVERIFIED_SCOPE_SENTINEL_ACTION" not in forced_body


def test_session_bound_pointer_without_execution_contract_fails_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-bound-pointer-only-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        workspace_key = "ws-bound-pointer-only"
        thread_id = "bound-pointer-only-thread"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        core = BrainCore(ROOT, memory_root)
        write_json(
            core._workspace_context_pointer_path(workspace_key),
            {
                "status": "active",
                "stale": False,
                "taskId": "task-bound-pointer-only",
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "version": package_version(),
                "expiresAt": (datetime.now() + timedelta(hours=1)).isoformat(sep=" "),
                "acceptedGoal": "POINTER_ONLY_SENTINEL_BODY",
                "currentStep": "POINTER_ONLY_SENTINEL_STEP",
                "nextAction": "POINTER_ONLY_SENTINEL_ACTION",
            },
        )
        previous_workspace = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        os.environ["CODEX_THREAD_ID"] = thread_id
        try:
            pointer_context = core._current_task_context()
            assert pointer_context is not None
            assert pointer_context["_trust"] == "context_pointer"
            ordinary = core.recall("current task next step", top_k=1, max_tokens=500, layer="all")
            forced = core.recall("unrelated intent", top_k=1, max_tokens=500, layer="task")
        finally:
            if previous_workspace is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread
            if previous_session is not None:
                os.environ["SUPER_BRAIN_SESSION_ID"] = previous_session

        ordinary_body = json.dumps(ordinary, ensure_ascii=False)
        forced_body = json.dumps(forced, ensure_ascii=False)

        assert ordinary == []
        assert forced == []
        assert "POINTER_ONLY_SENTINEL_BODY" not in ordinary_body
        assert "POINTER_ONLY_SENTINEL_STEP" not in ordinary_body
        assert "POINTER_ONLY_SENTINEL_ACTION" not in ordinary_body
        assert "POINTER_ONLY_SENTINEL_BODY" not in forced_body
        assert "POINTER_ONLY_SENTINEL_STEP" not in forced_body
        assert "POINTER_ONLY_SENTINEL_ACTION" not in forced_body


def test_all_layer_rejects_unverified_current_task_memory_without_contract() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-all-layer-current-task-leak-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        memory_root.mkdir(parents=True)
        workspace_key = "ws-all-layer-current-task-leak"
        thread_id = "all-layer-current-task-leak-thread"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        task_id = "task-all-layer-current-task-leak"
        leak_marker = "UNVERIFIED_ALL_LAYER_TASK_BODY"
        (memory_root / "sandglass.txt").write_text(
            "2026-08-05 10:00:00 | assistant | "
            "[TASK][CURRENT][SUMMARY] "
            f"taskName={leak_marker} nextAction=UNVERIFIED_ALL_LAYER_TASK_ACTION\\n",
            encoding="utf-8",
        )
        core = BrainCore(ROOT, memory_root)
        core.workspace = workspace
        core._graph_candidates = lambda terms: []
        core._experience_candidates = lambda query, terms: []
        core._profile_card_candidates = lambda query, terms: []
        core._recent_candidates = lambda terms, limit: []
        write_json(
            core._workspace_context_pointer_path(workspace_key),
            {
                "status": "active",
                "stale": False,
                "taskId": task_id,
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "version": package_version(),
                "expiresAt": (datetime.now() + timedelta(hours=1)).isoformat(sep=" "),
                "acceptedGoal": leak_marker,
                "currentStep": leak_marker,
                "nextAction": "UNVERIFIED_ALL_LAYER_TASK_ACTION",
            },
        )
        previous_workspace = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        os.environ["CODEX_THREAD_ID"] = thread_id
        try:
            pointer_context = core._current_task_context()
            assert pointer_context is not None
            assert pointer_context["_trust"] == "context_pointer"
            ordinary = core.recall(leak_marker, top_k=1, max_tokens=500, layer="all")
            explicit_without_contract = core.recall("continue approved work", top_k=1, max_tokens=500, layer="task")

            write_authoritative_task_contract(
                workspace,
                workspace_key,
                thread_id,
                task_id,
                task_name="Authoritative current task",
                current_step="verify authoritative task recall",
                next_action="AUTHORITATIVE_TASK_RECALL_ACTION",
            )
            authoritative_context = core._current_task_context()
            explicit_with_contract = core.recall("continue approved work", top_k=1, max_tokens=500, layer="task")
        finally:
            if previous_workspace is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread
            if previous_session is not None:
                os.environ["SUPER_BRAIN_SESSION_ID"] = previous_session

        assert ordinary == []
        assert explicit_without_contract == []
        assert authoritative_context is not None
        assert authoritative_context["_trust"] == "authoritative"
        assert explicit_with_contract
        assert "AUTHORITATIVE_TASK_RECALL_ACTION" in json.dumps(explicit_with_contract, ensure_ascii=False)


def test_bound_context_without_current_session_fails_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-bound-context-no-session-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        memory_root.mkdir(parents=True)
        workspace_key = "ws-" + "d" * 24
        write_json(
            workspace / "current-task-context.json",
            {
                "status": "active",
                "stale": False,
                "taskId": "private-bound-task",
                "workspaceKey": workspace_key,
                "ownerSessionKey": "sid-" + "e" * 24,
                "version": package_version(),
                "expiresAt": (datetime.now() + timedelta(hours=1)).isoformat(sep=" "),
                "currentStep": "must not cross session scope",
                "nextAction": "must remain unavailable",
            },
        )
        previous_workspace = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.pop("CODEX_THREAD_ID", None)
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        try:
            results = BrainCore(ROOT, memory_root).recall("current task next step", top_k=1, max_tokens=500)
        finally:
            if previous_workspace is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is not None:
                os.environ["CODEX_THREAD_ID"] = previous_thread
            if previous_session is not None:
                os.environ["SUPER_BRAIN_SESSION_ID"] = previous_session

        assert results == []


def test_retired_prompt_hook_exports_no_continuity_authority() -> None:
    import codex_prompt_hook

    assert not hasattr(codex_prompt_hook, "_classify")
    assert not hasattr(codex_prompt_hook, "_resume_packet")


def test_h7_turn_intent_is_typed_and_never_parses_prompt_text() -> None:
    for kind, governed in (("continuity", True), ("side_message", False), ("greeting", False)):
        intent = resolve_turn_intent(kind, memory_mode="auto")
        assert intent["ok"] is True, intent
        assert intent["kind"] == kind, intent
        assert intent["governed"] is governed, intent
        assert intent["rawPromptStored"] is False, intent
        assert intent["rawTranscriptStored"] is False, intent


def test_current_task_recall_prefers_session_bound_execution_contract() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-contract-task-recall-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        workspace_key = "ws-222222222222222222222222"
        thread_id = "brain-core-session-bound-thread"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        task_id = "task-session-bound-current"
        revision = 17
        updated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        contract_name = "task-session-bound-current--fixture.json"

        write_json(
            workspace / "current-task-context.json",
            {
                "status": "active",
                "stale": False,
                "taskId": "task-foreign-legacy",
                "workspaceKey": workspace_key,
                "version": package_version(),
                "nextAction": "foreign legacy action must not be recalled",
            },
        )
        write_json(
            workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
            {
                "schema": "super-brain.execution-hot-index.v1",
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "entries": [
                    {
                        "taskId": task_id,
                        "status": "active",
                        "packageVersion": package_version(),
                        "revision": revision,
                        "updatedAt": updated_at,
                        "contractFileName": contract_name,
                    }
                ],
            },
        )
        write_json(
            workspace / "runtime-state" / "execution-contracts" / contract_name,
            {
                "schema": "super-brain.execution-contract.v1",
                "taskId": task_id,
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "packageVersion": package_version(),
                "status": "active",
                "revision": revision,
                "focusId": "session-bound-main-line",
                "focusLabel": "Session bound main line",
                "currentStep": "verify the session bound contract",
                "nextAction": "continue the authorized session action",
                "needsReconciliation": False,
                "planReceiptRequired": True,
                "planReceipt": {
                    "focusId": "session-bound-main-line",
                    "contractRevision": revision,
                    "planFingerprint": "fixture-plan-fingerprint",
                },
                "updatedAt": updated_at,
            },
        )

        previous_workspace = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.get("CODEX_THREAD_ID")
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        os.environ["CODEX_THREAD_ID"] = thread_id
        try:
            core = make_isolated_recall_core(workspace)
            core._sandglass_candidates = lambda query, top_k, query_date="": []
            contract_context = core._current_task_context()
            assert contract_context is not None
            assert contract_context["_trust"] == "authoritative"
            results = core.recall("current task next step", top_k=1, max_tokens=500)
            implicit_query = "use the approved approach"
            assert core._is_task_query(implicit_query) is False
            forced_results = core.recall(implicit_query, top_k=1, max_tokens=500, layer="task")
            direct_results = core.recall(implicit_query, top_k=1, max_tokens=500, layer="all")
            cli_completed = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(ROOT / "runtime" / "brain_cli.py"),
                    "--package-root",
                    str(ROOT),
                    "--memory-root",
                    str(state_root / "shared"),
                    "recall",
                    "--query",
                    implicit_query,
                    "--top-k",
                    "1",
                    "--max-tokens",
                    "120",
                    "--layer",
                    "task",
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                check=False,
                env=os.environ.copy(),
                timeout=30,
            )
            index_path = workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json"
            ambiguous_index = json.loads(index_path.read_text(encoding="utf-8"))
            ambiguous_index["entries"].append(
                {
                    "taskId": "task-session-bound-ambiguous",
                    "status": "active",
                    "packageVersion": package_version(),
                    "revision": revision,
                    "updatedAt": updated_at,
                    "contractFileName": "task-session-bound-ambiguous.json",
                }
            )
            write_json(index_path, ambiguous_index)
            ambiguous_results = core.recall(implicit_query, top_k=1, max_tokens=500, layer="task")
        finally:
            if previous_workspace is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread

        serialized = json.dumps(results, ensure_ascii=False)
        assert results
        assert "continue the authorized session action" in serialized
        assert "foreign legacy action" not in serialized
        assert results[0]["source"] == "memory\\workspace\\runtime-state\\execution-contracts"
        assert direct_results == []
        assert forced_results and "continue the authorized session action" in json.dumps(forced_results, ensure_ascii=False)
        assert forced_results[0]["injectReady"] is True
        assert cli_completed.returncode == 0, cli_completed.stderr
        cli_results = json.loads(cli_completed.stdout)
        assert cli_results and "continue the authorized session action" in json.dumps(cli_results, ensure_ascii=False)
        assert cli_results[0]["injectReady"] is True
        assert ambiguous_results == []


def test_current_workspace_scope_uses_host_cwd_not_derived_status_card() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-cwd-scope-") as directory:
        base = Path(directory)
        state_root = base / "state"
        workspace = state_root / "workspace"
        host_project = base / "host-project"
        host_project.mkdir(parents=True)
        normalized_host = str(host_project.resolve()).rstrip("/\\").lower()
        workspace_key = "ws-" + hashlib.sha256(normalized_host.encode("utf-8")).hexdigest()[:24]
        thread_id = "brain-core-cwd-scope-thread"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        task_id = "task-cwd-scope-current"
        revision = 3
        updated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        contract_name = f"{task_id}--cwd-scope.json"

        write_json(workspace / "status-card.json", {"workspaceKey": "ws-" + "f" * 24, "nextAction": "foreign derived card"})
        write_json(
            workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
            {
                "schema": "super-brain.execution-hot-index.v1",
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "entries": [
                    {
                        "taskId": task_id,
                        "status": "active",
                        "packageVersion": package_version(),
                        "revision": revision,
                        "updatedAt": updated_at,
                        "contractFileName": contract_name,
                    }
                ],
            },
        )
        write_json(
            workspace / "runtime-state" / "execution-contracts" / contract_name,
            {
                "schema": "super-brain.execution-contract.v1",
                "taskId": task_id,
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "packageVersion": package_version(),
                "status": "active",
                "revision": revision,
                "focusId": "cwd-scope",
                "focusLabel": "Host cwd scope",
                "currentStep": "use the host project directory",
                "nextAction": "continue the cwd-bound task",
                "needsReconciliation": False,
                "planReceiptRequired": False,
                "updatedAt": updated_at,
            },
        )

        previous_workspace = os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_cwd = Path.cwd()
        os.environ["CODEX_THREAD_ID"] = thread_id
        os.chdir(host_project)
        try:
            core = make_core(workspace)
            assert core._current_workspace_key() == workspace_key
            context = core._execution_contract_context()
        finally:
            os.chdir(previous_cwd)
            if previous_workspace is not None:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread

        assert context is not None
        assert context["taskId"] == task_id
        assert context["workspaceKey"] == workspace_key


def test_execution_contract_context_ignores_non_wake_eligible_terminal_contracts() -> None:
    """A completed terminal card must not make the runnable workline ambiguous."""

    with tempfile.TemporaryDirectory(prefix="super-brain-wake-eligible-context-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = host_workspace_key(host_project)
        thread_id = "brain-core-wake-eligible-thread"
        updated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        session_key = write_authoritative_task_contract(
            workspace,
            workspace_key,
            thread_id,
            "task-runnable-current",
            task_name="Runnable current task",
            current_step="bind the current H7 task",
            next_action="continue the runnable task",
            updated_at=updated_at,
        )
        index_path = workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json"
        index = json.loads(index_path.read_text(encoding="utf-8"))
        index["entries"][0]["wakeEligible"] = True
        contract_path = workspace / "runtime-state" / "execution-contracts" / "task-runnable-current--fixture.json"
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        contract["taskInstanceId"] = "ti-" + "a" * 32
        write_json(contract_path, contract)
        index["entries"].append(
            {
                "taskId": "task-terminal-history",
                "status": "active",
                "wakeEligible": False,
                "packageVersion": package_version(),
                "revision": 8,
                "updatedAt": updated_at,
                "contractFileName": "task-terminal-history--fixture.json",
            }
        )
        write_json(index_path, index)

        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_cwd = Path.cwd()
        os.environ["CODEX_THREAD_ID"] = thread_id
        os.chdir(host_project)
        try:
            core = make_core(workspace)
            context = core._execution_contract_context()
            routed_contract, routed_code = core._read_context_contract(workspace_key, session_key)
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread

        assert context is not None
        assert context["taskId"] == "task-runnable-current"
        assert routed_code == "BRAIN_CONTEXT_READY"
        assert routed_contract is not None
        assert routed_contract["taskId"] == "task-runnable-current"


def test_execution_contract_context_requires_current_native_intent_receipt() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-contract-intent-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = host_workspace_key(host_project)
        thread_id = "brain-core-intent-bound-thread"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        task_id = "task-intent-bound-current"
        task_instance_id = "ti-" + "3" * 32
        revision = 23
        instruction = "add editable notebook without direct database writes"
        plan_fingerprint = "intent-bound-plan-fingerprint"
        updated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        contract_name = "task-intent-bound-current--fixture.json"
        intent_contract = {
            "schema": "super-brain.intent-contract.v2",
            "literalRequestDigest": "editable notebook, but no direct database writes",
            "resolvedOutcome": "Users can edit notebook entries through governed commands.",
            "productRole": "local notebook UI backed by a governed command API",
            "integrationObligations": ["local UI", "governed command API", "task receipt"],
            "materialUnknowns": [],
            "compatibilityGuards": ["no browser-side direct SQLite or database writes"],
            "preservedCapabilities": ["editable notebook"],
            "acceptanceCriteria": ["an edit produces a receipt"],
            "governedEquivalent": "governed command editing through a local API",
            "autonomyTier": "align",
            "integrationMap": {
                "entryPoint": "notebook page",
                "userFlow": "open note, edit, save, observe receipt",
                "domainOwner": "BrainControl command engine",
                "stateOwner": "brain-state SQLite authority",
                "downstreamConsumers": ["notebook query projection", "history view"],
                "failureRecovery": "CAS conflict keeps the draft and offers retry",
                "privacyPerformance": "loopback only and bounded payloads",
                "compatibilityMigration": "legacy records remain read-only until migration",
                "verification": "command API and real user edit-flow regression",
                "completionCondition": "edit, history, and rollback path are verified",
            },
            "investigationEvidence": ["runtime/brain_control.py command authority"],
            "materialBranches": [],
            "focusedQuestion": "",
            "preserveExistingFlow": True,
            "replacementReceipt": "",
            "componentResolution": {
                "requestedComponent": "direct database editor",
                "resolvedComponent": "governed command API",
                "outcomePreserved": True,
                "reason": "the governed command path preserves editing with receipts and rollback",
            },
        }
        resolved = BrainControl(state_root).resolve_intent(
            {
                "commandId": "intent-brain-core-current",
                "expectedIntentRevision": 0,
                "taskId": task_id,
                "taskInstanceId": task_instance_id,
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "packageVersion": package_version(),
                "contractRevision": revision,
                "planFingerprint": plan_fingerprint,
                "latestInstructionHash": hashlib.sha256(instruction.encode("utf-8")).hexdigest(),
                "intentContract": intent_contract,
                "source": "runtime brain regression",
            }
        )
        receipt = resolved["intentResolutionReceipt"]
        projection_path = intent_context_projection_path(
            state_root,
            task_id=task_id,
            task_instance_id=task_instance_id,
            workspace_key=workspace_key,
        )
        projection_text = projection_path.read_text(encoding="utf-8")
        assert instruction not in projection_text
        assert task_id not in projection_text
        assert "intentContractBodyStored\":false" in projection_text
        bound_contract = dict(resolved["intentContract"])
        bound_contract["contractFingerprint"] = receipt["intentContractFingerprint"]
        intent_binding = {
            "intentRevision": resolved["intentRevision"],
            "intentContractFingerprint": receipt["intentContractFingerprint"],
        }
        execution_contract = {
            "schema": "super-brain.execution-contract.v1",
            "taskId": task_id,
            "taskInstanceId": task_instance_id,
            "workspaceKey": workspace_key,
            "ownerSessionKey": session_key,
            "packageVersion": package_version(),
            "status": "active",
            "revision": revision,
            "focusId": "intent-bound-main-line",
            "focusLabel": "Intent bound main line",
            "currentStep": "verify the native intent receipt",
            "nextAction": "continue only with the current intent",
            "latestUserInstruction": instruction,
            "needsReconciliation": False,
            "planReceiptRequired": True,
            "planReceipt": {
                "focusId": "intent-bound-main-line",
                "contractRevision": revision,
                "planFingerprint": plan_fingerprint,
                "intentBinding": intent_binding,
            },
            "intentContractRequired": True,
            "intentRevision": resolved["intentRevision"],
            "intentContract": bound_contract,
            "intentResolutionReceipt": receipt,
            "updatedAt": updated_at,
        }
        write_json(
            workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
            {
                "schema": "super-brain.execution-hot-index.v1",
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "entries": [
                    {
                        "taskId": task_id,
                        "status": "active",
                        "packageVersion": package_version(),
                        "revision": revision,
                        "updatedAt": updated_at,
                        "contractFileName": contract_name,
                    }
                ],
            },
        )
        contract_path = workspace / "runtime-state" / "execution-contracts" / contract_name
        write_json(contract_path, execution_contract)

        previous_workspace = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_cwd = Path.cwd()
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        os.environ["CODEX_THREAD_ID"] = thread_id
        os.chdir(host_project)
        try:
            core = make_core(workspace)
            assert core._execution_contract_context() is not None
            before = file_hashes(state_root)
            packet = core.context("auto")
            after = file_hashes(state_root)
            assert packet["available"] is True
            assert packet["code"] == "BRAIN_CONTEXT_READY"
            assert packet["task"]["actionAuthorization"] == "withheld"
            assert before == after
            execution_contract["latestUserInstruction"] = "also export the notebook"
            write_json(contract_path, execution_contract)
            assert core._execution_contract_context() is None
            rejected = core.context("auto")
            assert rejected["available"] is False
            assert rejected["code"] == "BRAIN_CONTEXT_INTENT_RECEIPT_NOT_CURRENT"
        finally:
            os.chdir(previous_cwd)
            if previous_workspace is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread


def test_no_hook_context_uses_real_host_scope_and_stays_read_only() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-no-hook-context-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = host_workspace_key(host_project)
        thread_id = "no-hook-context-thread"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        task_id = "task-no-hook-context"
        task_instance_id = "ti-" + "4" * 32
        revision = 9
        contract_name = "task-no-hook-context--fixture.json"
        updated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        write_json(
            workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json",
            {
                "schema": "super-brain.execution-hot-index.v1",
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "entries": [
                    {
                        "taskId": task_id,
                        "status": "active",
                        "packageVersion": package_version(),
                        "revision": revision,
                        "updatedAt": updated_at,
                        "contractFileName": contract_name,
                    }
                ],
            },
        )
        write_json(
            workspace / "runtime-state" / "execution-contracts" / contract_name,
            {
                "schema": "super-brain.execution-contract.v1",
                "taskId": task_id,
                "taskInstanceId": task_instance_id,
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "packageVersion": package_version(),
                "status": "active",
                "revision": revision,
                "focusId": "no-hook-context",
                "focusLabel": "No Hook context recovery",
                "assistantCommitment": "Read a bounded context packet without authorizing an old action.",
                "lastConfirmedSentence": "The no-Hook context packet must expose the latest verified progress receipt.",
                "currentPhase": "P2",
                "currentStep": "verify pure Host context",
                "nextAction": "continue only after the visible instruction is reconciled",
                "needsReconciliation": False,
                "planReceiptRequired": False,
                "updatedAt": updated_at,
            },
        )
        write_native_memory_snapshot(workspace)

        previous_workspace = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_legacy_session = os.environ.get("SUPER_BRAIN_SESSION_ID")
        previous_cwd = Path.cwd()
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = "ws-" + "f" * 24
        os.environ["CODEX_THREAD_ID"] = thread_id
        os.environ["SUPER_BRAIN_SESSION_ID"] = "legacy-session-must-not-be-used"
        os.chdir(host_project)
        try:
            core = make_core(workspace)
            before = file_hashes(state_root)
            packet = core.context("auto")
            after = file_hashes(state_root)
            assert packet["available"] is True
            assert packet["code"] == "BRAIN_CONTEXT_READY"
            assert packet["scope"]["workspaceKey"] == workspace_key
            assert packet["scope"]["ownerSessionKey"] == session_key
            assert packet["task"]["actionAuthorization"] == "withheld"
            assert packet["task"]["lastConfirmedSentence"] == "The no-Hook context packet must expose the latest verified progress receipt."
            assert packet["continuation"]["decision"] == "withhold_reconcile"
            assert packet["continuation"]["code"] == "CONTINUATION_POLICY_CURRENT_TURN_UNATTESTED"
            assert packet["task"]["nextAction"] == "continue only after the visible instruction is reconciled"
            assert packet["typedMemory"]["state"] == "selected"
            assert packet["typedMemory"]["refs"] == [
                {"cardId": "card-context-preference", "cardRevision": 1, "kind": "preference"}
            ]
            assert "FOREIGN_SESSION_MUST_NOT_INJECT" not in json.dumps(packet, ensure_ascii=False)
            assert before == after

            continuation_before = file_hashes(state_root)
            continuation_packet = core.context("auto", "ephemeral_insertion", "none")
            continuation_after = file_hashes(state_root)
            assert continuation_packet["task"]["actionAuthorization"] == "withheld"
            assert continuation_packet["continuation"]["decision"] == "continue_current_turn"
            assert continuation_packet["continuation"]["terminalReplyAllowed"] is False
            assert continuation_before == continuation_after

            cli_environment = os.environ.copy()
            cli_environment["CODEX_THREAD_ID"] = thread_id
            cli = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "runtime" / "brain_cli.py"),
                    "--package-root",
                    str(ROOT),
                    "--memory-root",
                    str(state_root / "shared"),
                    "context",
                    "--memory-mode",
                    "auto",
                ],
                cwd=host_project,
                env=cli_environment,
                capture_output=True,
                check=False,
                timeout=10,
            )
            assert cli.returncode == 0, cli.stderr.decode("utf-8", errors="replace")
            cli_packet = json.loads(cli.stdout.decode("utf-8"))
            assert cli_packet["code"] == "BRAIN_CONTEXT_READY"
            assert cli_packet["task"]["actionAuthorization"] == "withheld"
            assert cli_packet["activation"]["state"] == "full_brain_active"
            assert cli_packet["activation"]["coreReady"] is True
            assert cli_packet["activation"]["memory"]["snapshotHash"] == cli_packet["typedMemory"]["snapshotPayloadHash"]
            assert cli_packet["activation"]["memory"]["refs"] == ["card-context-preference@1"]
            assert cli_packet["activation"]["rawPromptStored"] is False
            assert cli_packet["activation"]["rawTranscriptStored"] is False

            off_core = make_core(workspace)
            off_core._context_session_key = lambda: (_ for _ in ()).throw(AssertionError("memory:off must not inspect Host scope"))
            off_packet = off_core.context("off")
            assert off_packet["code"] == "BRAIN_CONTEXT_MEMORY_OFF"

            snapshot_path = workspace / "native-memory-influence-snapshot.json"
            dirty_path = workspace / "native-memory-influence-snapshot.dirty.json"
            original_snapshot = snapshot_path.read_bytes()
            write_json(dirty_path, {"schema": "fixture", "pending": True})
            dirty_packet = core.context("auto")
            assert dirty_packet["available"] is True
            assert dirty_packet["typedMemory"]["state"] == "dirty"
            assert dirty_packet["typedMemory"]["refs"] == []
            dirty_path.unlink()

            future_snapshot = json.loads(original_snapshot.decode("utf-8"))
            future_snapshot["generatedAt"] = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat().replace("+00:00", "Z")
            future_body = {key: value for key, value in future_snapshot.items() if key != "payloadHash"}
            future_snapshot["payloadHash"] = canonical_hash(future_body)
            write_json(snapshot_path, future_snapshot)
            future_packet = core.context("auto")
            assert future_packet["available"] is True
            assert future_packet["typedMemory"]["state"] == "future"
            assert future_packet["typedMemory"]["refs"] == []

            invalid_snapshot = json.loads(original_snapshot.decode("utf-8"))
            invalid_snapshot["payloadHash"] = "0" * 64
            write_json(snapshot_path, invalid_snapshot)
            invalid_packet = core.context("auto")
            assert invalid_packet["available"] is True
            assert invalid_packet["typedMemory"]["state"] == "hash_mismatch"
            assert invalid_packet["typedMemory"]["refs"] == []
            snapshot_path.write_bytes(original_snapshot)

            os.environ.pop("CODEX_THREAD_ID", None)
            missing_thread = core.context("auto")
            assert missing_thread["code"] == "BRAIN_CONTEXT_THREAD_ID_MISSING"
            os.environ["CODEX_THREAD_ID"] = thread_id

            index_path = workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json"
            index = json.loads(index_path.read_text(encoding="utf-8"))
            index["entries"].append({**index["entries"][0], "taskId": "task-no-hook-context-ambiguous"})
            write_json(index_path, index)
            ambiguous = core.context("auto")
            assert ambiguous["code"] == "BRAIN_CONTEXT_AMBIGUOUS_ACTIVE_CONTRACT"
        finally:
            os.chdir(previous_cwd)
            if previous_workspace is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread
            if previous_legacy_session is None:
                os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_SESSION_ID"] = previous_legacy_session


def test_context_recovers_from_a_lagging_hot_index_after_a_committed_transition() -> None:
    """The read-only H7 path may use a newer identity-matched contract only."""

    with tempfile.TemporaryDirectory(prefix="super-brain-hot-index-lag-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = host_workspace_key(host_project)
        thread_id = "hot-index-lag-thread"
        session_key = "sid-" + hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
        task_id = "task-hot-index-lag"
        contract_name = "task-hot-index-lag--fixture.json"
        updated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        index_path = workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json"
        write_json(
            index_path,
            {
                "schema": "super-brain.execution-hot-index.v1",
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "entries": [{
                    "taskId": task_id,
                    "status": "active",
                    "packageVersion": package_version(),
                    "revision": 7,
                    "updatedAt": updated_at,
                    "contractFileName": contract_name,
                }],
            },
        )
        write_json(
            workspace / "runtime-state" / "execution-contracts" / contract_name,
            {
                "schema": "super-brain.execution-contract.v1",
                "taskId": task_id,
                "taskInstanceId": "ti-" + "5" * 32,
                "workspaceKey": workspace_key,
                "ownerSessionKey": session_key,
                "packageVersion": package_version(),
                "status": "active",
                "revision": 8,
                "focusId": "hot-index-lag",
                "focusLabel": "Committed H7 transition",
                "lastConfirmedSentence": "The contract committed before its derived hot index refreshed.",
                "lastConfirmedSource": "assistant_commitment",
                "currentPhase": "H7 recovery",
                "currentStep": "Recover from a lagging derived index without writes.",
                "nextAction": "Refresh the derived index on the next authoritative mutation.",
                "needsReconciliation": False,
                "planReceiptRequired": False,
                "updatedAt": updated_at,
            },
        )
        write_native_memory_snapshot(workspace)

        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_cwd = Path.cwd()
        os.environ["CODEX_THREAD_ID"] = thread_id
        os.chdir(host_project)
        try:
            core = make_core(workspace)
            before = file_hashes(state_root)
            packet = core.context("auto")
            after = file_hashes(state_root)
            assert packet["available"] is True, packet
            assert packet["code"] == "BRAIN_CONTEXT_HOT_INDEX_LAGGING_FALLBACK", packet
            assert packet["task"]["contractRevision"] == 8, packet
            assert packet["task"]["lastConfirmedSentence"] == "The contract committed before its derived hot index refreshed.", packet
            assert before == after

            index = json.loads(index_path.read_text(encoding="utf-8"))
            index["entries"][0]["revision"] = 9
            write_json(index_path, index)
            ahead = core.context("auto")
            assert ahead["available"] is False, ahead
            assert ahead["code"] == "BRAIN_CONTEXT_CONTRACT_REVISION_MISMATCH", ahead
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread


def test_mcp_does_not_expose_untrusted_host_context() -> None:
    tool_names = {str(tool.get("name", "")) for tool in MCP_TOOLS}
    assert "brain_context" not in tool_names
    assert tool_names == {"brain_recall", "brain_status", "brain_recent", "brain_turn"}


def test_mcp_status_and_tools_withhold_a_stale_long_lived_runtime() -> None:
    """An in-place rule update must not leave an old MCP worker usable."""

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-runtime-identity-") as directory:
        package_root = Path(directory) / "package"
        memory_root = Path(directory) / "state" / "shared"
        package_root.mkdir(parents=True)
        memory_root.mkdir(parents=True)
        for name in ("manifest.json", "route-map.json", "capabilities.json", "super-brain-rules.json"):
            (package_root / name).write_bytes((ROOT / name).read_bytes())
        for relative_path in (
            "runtime/brain_mcp.py",
            "runtime/brain_core.py",
            "runtime/turn_runtime.py",
            "runtime/core_rule_registry.py",
        ):
            destination = package_root / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((ROOT / relative_path).read_bytes())
        (memory_root / "sandglass.txt").write_text("", encoding="utf-8")
        core = BrainCore(package_root, memory_root)
        assert core.runtime_identity_status()["state"] == "current"

        registry_path = package_root / "super-brain-rules.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        registry["rules"][0]["revision"] = int(registry["rules"][0]["revision"]) + 1
        registry["payloadHash"] = canonical_hash({key: value for key, value in registry.items() if key != "payloadHash"})
        write_json(registry_path, registry)

        status_result = handle_tool(core, "brain_status", {})
        status = json.loads(status_result["content"][0]["text"])
        assert status["runtimeIdentity"]["state"] == "withheld", status
        assert status["runtimeIdentity"]["code"] == "H7_MCP_RUNTIME_RULE_REGISTRY_STALE", status
        assert status["operational"]["state"] == "withheld", status

        denied = handle_tool(core, "brain_recent", {})
        assert denied["isError"] is True, denied
        denied_payload = json.loads(denied["content"][0]["text"])
        assert denied_payload["code"] == "H7_MCP_RUNTIME_RULE_REGISTRY_STALE", denied_payload


def test_turn_close_policy_requires_current_turn_attestation_and_never_echoes_input() -> None:
    resolution = {
        "ok": True,
        "actionAuthorization": "allowed",
        "claimAllowed": True,
        "needsConfirmation": False,
        "blockers": [],
        "nextAction": "verify token=CONTINUATION_SECRET_SENTINEL then continue",
        "canResumeParent": True,
    }
    unknown = decide_turn_close(
        resolution,
        turn_outcome="side_branch_completed",
        user_control="unknown",
        completion_evidence_present=True,
    )
    assert unknown["decision"] == "withhold_reconcile"
    assert unknown["code"] == "CONTINUATION_POLICY_CURRENT_TURN_UNATTESTED"

    completed = decide_turn_close(
        resolution,
        turn_outcome="side_branch_completed",
        user_control="none",
        completion_evidence_present=True,
    )
    assert completed["decision"] == "resume_parent_required"
    assert completed["branchStatus"] == "completed"
    assert completed["requiresParentResume"] is True

    missing_evidence = decide_turn_close(
        resolution,
        turn_outcome="side_branch_completed",
        user_control="none",
        completion_evidence_present=False,
    )
    assert missing_evidence["decision"] == "withhold_reconcile"
    assert missing_evidence["code"] == "CONTINUATION_POLICY_COMPLETION_EVIDENCE_REQUIRED"

    partial = decide_turn_close(
        resolution,
        turn_outcome="side_branch_partial",
        user_control="none",
        completion_evidence_present=True,
    )
    assert partial["decision"] == "resume_parent_required"
    assert partial["branchStatus"] == "partial"

    paused = decide_turn_close(
        resolution,
        turn_outcome="ephemeral_insertion",
        user_control="stop",
    )
    assert paused["decision"] == "pause_with_blocker"
    assert paused["terminalReplyAllowed"] is True

    blocked = decide_turn_close(
        {**resolution, "blockers": ["waiting for the user to choose"]},
        turn_outcome="ephemeral_insertion",
        user_control="none",
    )
    assert blocked["decision"] == "pause_with_blocker"
    serialized = json.dumps([unknown, completed, missing_evidence, partial, paused, blocked], ensure_ascii=False)
    assert "CONTINUATION_SECRET_SENTINEL" not in serialized


def test_personal_unknown_fact_does_not_use_unrelated_memory() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-unknown-fact-") as directory:
        core = make_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[PROFILE][CURRENT][VERIFIED][SUMMARY] 用户偏好：回复要简洁。",
                source="1:2026-07-17",
                source_type="sandglass",
                reason="sandglass_search",
            )
        ]

        results = core.recall("我住在哪里？", top_k=3, max_tokens=500)

        assert results == []


def test_exact_personal_profile_fact_remains_recallable() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-known-fact-") as directory:
        core = make_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[PROFILE][CURRENT][VERIFIED] 我住在哪里？这个事实需要谨慎使用。",
                source="2:2026-07-17",
                source_type="sandglass",
                reason="sandglass_search",
            )
        ]

        results = core.recall("我住在哪里？", top_k=3, max_tokens=500)

        assert len(results) == 1
        assert results[0]["exactMatch"] is True


def test_personal_identity_and_education_queries_abstain_from_decisions() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-personal-abstain-") as directory:
        core = make_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[DECISION][CURRENT][VERIFIED] project cache decision and implementation notes",
                source="3:2026-07-17",
                source_type="sandglass",
                reason="sandglass_search",
            )
        ]
        for query in ("\u6211\u7684\u8eab\u4efd\u8bc1\u53f7\u662f\u4ec0\u4e48\uff1f", "\u6211\u7684\u5927\u5b66\u4e13\u4e1a\u662f\u4ec0\u4e48\uff1f", "What is my degree?"):
            assert core.recall(query, top_k=3, max_tokens=500) == []


def test_verified_personal_field_requires_a_matching_profile_field() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-profile-field-") as directory:
        core = make_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[PROFILE][CURRENT][VERIFIED] 我的大学专业是机械工程。",
                source="4:2026-07-17",
                source_type="sandglass",
                reason="sandglass_search",
            ),
            Candidate(
                text="[PROFILE][CURRENT][VERIFIED] 我的身份证号码已经记录。",
                source="5:2026-07-17",
                source_type="sandglass",
                reason="sandglass_search",
            ),
        ]

        results = core.recall("我的大学专业是什么？", top_k=3, max_tokens=500)
        serialized = json.dumps(results, ensure_ascii=False)

        assert results
        assert "机械工程" in serialized
        assert "身份证" not in serialized


def test_canonical_decision_key_beats_related_graph_memory() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-canonical-key-") as directory:
        core = make_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[CURRENT][VERIFIED][RULE] key=continuation-visible-tail-boundary decision=When current, routing must use the newest visible tail.",
                source="110:2026-07-10",
                source_type="sandglass",
                reason="sandglass_search",
            )
        ]
        core._graph_candidates = lambda terms: [
            Candidate(
                text="decision:continuation-cache-directed-relay-v1-stage2-canary decides cached continuation behavior",
                source="319",
                source_type="graph",
                reason="graph_decision_or_lineage",
                relation_priority=0,
            )
        ]

        # This case exercises the explicit canonical-key path.  Natural-language
        # relatedness is covered separately and must not be labeled canonical.
        results = core.recall("continuation-visible-tail-boundary", top_k=2, max_tokens=500)

        assert results
        assert results[0]["identityKey"] == "decision:continuation-visible-tail-boundary"
        assert results[0]["canonicalMatch"] is True


def test_unknown_historical_topic_does_not_match_generic_task_memory() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-historical-abstain-") as directory:
        core = make_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": []
        core._graph_candidates = lambda terms: [
            Candidate(
                text="[TASK][CURRENT][VERIFIED] generic task checkpoint without the requested topic",
                source="memory\\graph.jsonl:1",
                source_type="graph",
                reason="graph_decision_or_lineage",
            )
        ]

        results = core.recall(
            "continue previous task about nonexistent-nebula-archive-7f3a9c2e",
            top_k=3,
            max_tokens=500,
        )

        assert results == []


def test_token_boundaries_and_identity_anchors_block_unrelated_facts() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-boundary-admission-") as directory:
        core = make_isolated_recall_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[PROJECT][CURRENT][VERIFIED][SUMMARY] Pegasus database engine is PostgreSQL.",
                source="1:2026-07-18",
                source_type="sandglass",
                reason="fixture",
            ),
            Candidate(
                text="[PROFILE][CURRENT][VERIFIED][SUMMARY] Evidence-bounded engineering judgment.",
                source="2:2026-07-18",
                source_type="sandglass",
                reason="fixture",
            ),
        ]

        related = core.recall("current Pegasus database engine", top_k=3, max_tokens=500)
        unrelated = core.recall("What database backs the polar observatory?", top_k=3, max_tokens=500)

        assert related
        assert "PostgreSQL" in related[0]["text"]
        assert unrelated == []


def test_multi_fact_identity_survives_trailing_punctuation_and_alias_expansion() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-multi-fact-identity-") as directory:
        core = make_isolated_recall_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[PROJECT][CURRENT][VERIFIED] Calibration-Beta deployment zone is cal-zone-42.",
                source="1:2026-07-22",
                source_type="sandglass",
                reason="fixture",
            ),
            Candidate(
                text="[TASK][CURRENT][VERIFIED] Calibration-Beta review group is cal-team-43.",
                source="2:2026-07-22",
                source_type="sandglass",
                reason="fixture",
            ),
            Candidate(
                text="[TASK][CURRENT][VERIFIED] Unrelated-Delta review group is wrong-team.",
                source="3:2026-07-22",
                source_type="sandglass",
                reason="fixture",
            ),
        ]

        results = core.recall(
            "Give both the current deployment zone and review group for Calibration-Beta.",
            top_k=4,
            max_tokens=500,
        )
        serialized = json.dumps(results, ensure_ascii=False)

        assert len(results) == 2
        assert "cal-zone-42" in serialized
        assert "cal-team-43" in serialized
        assert "wrong-team" not in serialized


def test_temporal_target_beats_current_snapshot_and_suppresses_conflict() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-temporal-order-") as directory:
        core = make_isolated_recall_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[SESSION][VERIFIED][SUMMARY] session_date=2026-07-04 Atlas runner was cobalt-3.",
                source="1:2026-07-04",
                source_type="sandglass",
                reason="fixture",
                timestamp="2026-07-04 10:00:00",
            ),
            Candidate(
                text="[SESSION][CURRENT][VERIFIED][SUMMARY] session_date=2026-07-17 Atlas runner is cobalt-9.",
                source="2:2026-07-17",
                source_type="sandglass",
                reason="fixture",
                timestamp="2026-07-17 10:00:00",
            ),
        ]

        results = core.recall(
            "Which Atlas runner did I switch to two weeks ago?",
            top_k=3,
            max_tokens=500,
            query_date="2026-07-18",
        )

        assert len(results) == 1
        assert "cobalt-3" in results[0]["text"]
        assert results[0]["temporalMatch"] is True


def test_generic_verified_personal_fields_are_recallable() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-personal-coverage-") as directory:
        core = make_isolated_recall_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[PROFILE][CURRENT][VERIFIED][SUMMARY] My favorite IDE is JetBrains Rider.",
                source="1:2026-07-18",
                source_type="sandglass",
                reason="fixture",
            ),
            Candidate(
                text="[PROFILE][CURRENT][VERIFIED][SUMMARY] My favorite programming language is Rust.",
                source="2:2026-07-18",
                source_type="sandglass",
                reason="fixture",
            ),
        ]

        ide = core.recall("What is my favorite IDE?", top_k=1, max_tokens=500)
        language = core.recall("What is my favorite programming language?", top_k=1, max_tokens=500)

        assert ide and "JetBrains Rider" in ide[0]["text"]
        assert language and "Rust" in language[0]["text"]


def test_generic_manifest_word_does_not_force_package_state_route() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-state-intent-") as directory:
        core = make_isolated_recall_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="[PROJECT][CURRENT][VERIFIED][SUMMARY] Cascade checksum manifest is cdx-481.",
                source="1:2026-07-18",
                source_type="sandglass",
                reason="fixture",
            )
        ]

        results = core.recall("Cascade checksum manifest", top_k=1, max_tokens=500)

        assert results
        assert "cdx-481" in results[0]["text"]
        assert results[0]["sourceType"] == "sandglass"


def test_runtime_output_policy_uses_safe_defaults_for_malformed_values() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-output-policy-defaults-") as directory:
        core = make_core(Path(directory))
        core.policy = {
            "retrieval": {
                "confidence": {"inject": "bad", "summaryOnly": "bad"},
                "contextBudget": {
                    "enabled": True,
                    "maxEvidenceCards": "bad",
                    "evidenceTokens": "bad",
                    "cardSnippetTokens": "bad",
                },
            }
        }

        policy = core._retrieval_output_policy(10, 1200)

        assert policy.max_results == 4
        assert policy.max_tokens == 500
        assert policy.card_max_chars == 224
        assert policy.summary_confidence == 0.2
        assert policy.inject_confidence == 0.6


def test_runtime_omits_below_summary_evidence_and_marks_summary_only() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-output-disposition-") as directory:
        core = make_isolated_recall_core(Path(directory))
        policy = copy_policy(core)
        retrieval = policy["retrieval"]
        assert isinstance(retrieval, dict)
        retrieval["confidence"] = {"summaryOnly": 0.3, "inject": 0.8}
        retrieval["hybrid"] = {"sourceWeights": {"recent": 0.35}, "fallbackRecentWhenBelowTopK": False}
        core.policy = policy
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text="orbital evidence is bounded",
                source="1:2026-07-18",
                source_type="recent",
                reason="temporary_fixture",
            )
        ]

        summary_only = core.recall("orbital archive", top_k=1, max_tokens=500)

        assert len(summary_only) == 1
        assert summary_only[0]["recallDisposition"] == "summary_only"
        assert summary_only[0]["injectReady"] is False
        assert summary_only[0]["relevanceOk"] is False
        assert summary_only[0]["evidenceCard"]["recallDisposition"] == "summary_only"
        assert summary_only[0]["evidenceCard"]["injectReady"] is False
        assert summary_only[0]["evidenceCard"]["relevanceStatus"] == "summary_only"

        retrieval["confidence"] = {"summaryOnly": 0.5, "inject": 0.8}

        assert core.recall("orbital archive", top_k=1, max_tokens=500) == []


def test_runtime_applies_context_budget_on_primary_recall_path() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-output-budget-") as directory:
        core = make_isolated_recall_core(Path(directory))
        policy = copy_policy(core)
        retrieval = policy["retrieval"]
        assert isinstance(retrieval, dict)
        context_budget = retrieval["contextBudget"]
        assert isinstance(context_budget, dict)
        context_budget.update(
            {
                "enabled": True,
                "maxEvidenceCards": 2,
                "evidenceTokens": 30,
                "cardSnippetTokens": 96,
            }
        )
        retrieval["hybrid"] = {"sourceWeights": {"sandglass": 0.55}, "fallbackRecentWhenBelowTopK": False}
        core.policy = policy
        requested_top_k: list[int] = []

        def candidates(query: str, top_k: int, query_date: str = "") -> list[Candidate]:
            requested_top_k.append(top_k)
            return [
                Candidate(
                    text=f"[CURRENT][VERIFIED][SUMMARY] budget-anchor-{index}",
                    source=f"{index}:2026-07-18",
                    source_type="sandglass",
                    reason="temporary_fixture",
                )
                for index in range(3)
            ]

        core._sandglass_candidates = candidates

        results = core.recall("budget-anchor", top_k=10, max_tokens=1200)

        assert len(results) == 2
        assert requested_top_k == [2]
        assert sum(item["tokenEstimate"] for item in results) <= 30
        assert all(item["injectReady"] is True for item in results)
        assert all(item["relevanceOk"] is True for item in results)
        assert all(item["recallDisposition"] == "inject" for item in results)


def test_runtime_hard_output_ceiling_survives_disabled_context_budget() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-hard-output-ceiling-") as directory:
        core = make_isolated_recall_core(Path(directory))
        policy = copy_policy(core)
        retrieval = policy["retrieval"]
        assert isinstance(retrieval, dict)
        context_budget = retrieval["contextBudget"]
        assert isinstance(context_budget, dict)
        context_budget["enabled"] = False
        core.policy = policy
        core._sandglass_candidates = lambda query, top_k, query_date="": [
            Candidate(
                text=f"[CURRENT][VERIFIED][SUMMARY] output-ceiling-anchor-{index} " + ("detail " * 80),
                source=f"{index}:2026-07-20",
                source_type="sandglass",
                reason="temporary_fixture",
            )
            for index in range(10)
        ]

        results = core.recall("output-ceiling-anchor", top_k=999, max_tokens=4000)

        assert len(results) == 4
        assert sum(item["tokenEstimate"] for item in results) <= 500


def test_temporal_recall_requires_identity_evidence() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-temporal-identity-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        (memory_root / "sandglass.txt").write_text(
            "\n".join(
                [
                    "2026-07-13 09:00:00 | user | [SESSION][VERIFIED] session_date=2026-07-13 unrelated rainfall observation",
                    "2026-07-13 09:01:00 | user | [SESSION][VERIFIED] session_date=2026-07-13 Project Juniper release route used the blue gate",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        core = BrainCore(ROOT, memory_root)

        results = core.recall(
            "What was Project Juniper one week ago?",
            top_k=3,
            max_tokens=500,
            query_date="2026-07-20",
        )

        assert results
        serialized = json.dumps(results, ensure_ascii=False)
        assert "Project Juniper" in serialized
        assert "rainfall observation" not in serialized
        assert all(item["temporalMatch"] is True for item in results)


def test_generic_conflicts_abstain_without_current_evidence() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-generic-conflict-") as directory:
        core = make_isolated_recall_core(Path(directory))
        candidates = [
            Candidate(
                text="[PROJECT][VERIFIED][SUMMARY] Project Juniper engine is Alpha.",
                source="1:2026-07-10",
                source_type="sandglass",
                reason="fixture",
            ),
            Candidate(
                text="[PROJECT][VERIFIED][SUMMARY] Project Juniper engine is Beta.",
                source="2:2026-07-11",
                source_type="sandglass",
                reason="fixture",
            ),
        ]
        core._sandglass_candidates = lambda query, top_k, query_date="": candidates

        assert core.recall("Project Juniper engine", top_k=3, max_tokens=500) == []

        candidates[1].text = "[PROJECT][CURRENT][VERIFIED][SUMMARY] Project Juniper engine is Beta."
        results = core.recall("Project Juniper engine", top_k=3, max_tokens=500)

        assert len(results) == 1
        assert "Beta" in results[0]["text"]


def test_graph_decision_facets_keep_the_current_decides_edge() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-graph-decision-facets-") as directory:
        core = make_isolated_recall_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": []
        core._graph_candidates = lambda terms: [
            Candidate(
                text=(
                    "[CURRENT][VERIFIED] subject=decision:control-mode relation=decides "
                    "object=use safe-mode evidence=verified tags=[DECISION][CURRENT]"
                ),
                source="memory\\graph.jsonl:1",
                source_type="graph",
                reason="graph_evidence_seed",
                relation_priority=0,
                identity_key="decision:control-mode",
                claim_value="use safe-mode",
            ),
            Candidate(
                text=(
                    "[CURRENT][VERIFIED] subject=decision:control-mode relation=has_title "
                    "object=Control mode evidence=verified tags=[DECISION][CURRENT]"
                ),
                source="memory\\graph.jsonl:2",
                source_type="graph",
                reason="graph_evidence_seed",
                relation_priority=10,
                identity_key="decision:control-mode",
                claim_value="control mode",
            ),
            Candidate(
                text=(
                    "[HISTORY][VERIFIED] subject=decision:control-mode relation=decides "
                    "object=use legacy-mode evidence=old tags=[DECISION][HISTORY]"
                ),
                source="memory\\graph.jsonl:3",
                source_type="graph",
                reason="graph_evidence_seed",
                relation_priority=0,
                identity_key="decision:control-mode",
                claim_value="use legacy-mode",
            ),
        ]

        results = core.recall("control mode", top_k=3, max_tokens=500)

        assert len(results) == 1
        assert "safe-mode" in results[0]["text"]
        assert "legacy-mode" not in results[0]["text"]


def test_conflicting_current_graph_decisions_abstain() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-graph-decision-conflict-") as directory:
        core = make_isolated_recall_core(Path(directory))
        core._sandglass_candidates = lambda query, top_k, query_date="": []
        core._graph_candidates = lambda terms: [
            Candidate(
                text=(
                    "[CURRENT][VERIFIED] subject=decision:control-mode relation=decides "
                    "object=use safe-mode evidence=verified tags=[DECISION][CURRENT]"
                ),
                source="memory\\graph.jsonl:1",
                source_type="graph",
                reason="graph_evidence_seed",
                relation_priority=0,
                identity_key="decision:control-mode",
                claim_value="use safe-mode",
            ),
            Candidate(
                text=(
                    "[CURRENT][VERIFIED] subject=decision:control-mode relation=decides "
                    "object=use fast-mode evidence=verified tags=[DECISION][CURRENT]"
                ),
                source="memory\\graph.jsonl:2",
                source_type="graph",
                reason="graph_evidence_seed",
                relation_priority=0,
                identity_key="decision:control-mode",
                claim_value="use fast-mode",
            ),
        ]

        assert core.recall("control mode", top_k=3, max_tokens=500) == []


def test_graph_expansion_is_one_hop_and_skips_stale_edges() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-graph-expansion-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        graph = [
            {
                "subject": "Nebula storage",
                "relation": "decides",
                "object": "sector-77",
                "evidence": "verified seed",
                "tags": "current verified",
            },
            {
                "subject": "sector-77",
                "relation": "affects",
                "object": "retention policy",
                "evidence": "verified dependency",
                "tags": "current verified",
            },
            {
                "subject": "sector-77",
                "relation": "affects",
                "object": "retired route",
                "evidence": "stale dependency",
                "tags": "stale",
            },
            {
                "subject": "retention policy",
                "relation": "affects",
                "object": "third hop must not appear",
                "evidence": "outside bounded expansion",
                "tags": "current",
            },
        ]
        (state_root / "graph.jsonl").write_text(
            "\n".join(json.dumps(item) for item in graph) + "\n",
            encoding="utf-8",
        )
        core = BrainCore(ROOT, memory_root)
        core._sandglass_candidates = lambda query, top_k, query_date="": []
        core._experience_candidates = lambda query, terms: []
        core._profile_card_candidates = lambda query, terms: []

        results = core.recall("Nebula storage", top_k=4, max_tokens=500)
        serialized = json.dumps(results, ensure_ascii=False)

        assert "retention policy" in serialized
        assert "retired route" not in serialized
        assert "third hop must not appear" not in serialized
        assert any(item["reason"] == "graph_evidence_expansion" for item in results)


def test_graph_subject_prefilter_avoids_materializing_unrelated_edges() -> None:
    """Graph evidence still permits cross-field matching, but rejects unrelated subjects early."""
    with tempfile.TemporaryDirectory(prefix="super-brain-graph-subject-prefilter-") as directory:
        core = make_core(Path(directory))
        unrelated = GraphEdge(
            subject="unrelated node",
            relation="affects",
            object="anchor needle distractor",
            evidence="contains every query term outside the subject",
            tags="current verified",
            source="memory\\graph.jsonl:1",
            relation_priority=40,
        )
        relevant = GraphEdge(
            subject="anchor system",
            relation="affects",
            object="needle retention policy",
            evidence="verified dependency",
            tags="current verified",
            source="memory\\graph.jsonl:2",
            relation_priority=40,
        )
        core._graph_rows = lambda: [unrelated, relevant]
        materialized: list[str] = []
        original_graph_text = core._graph_text

        def record_graph_text(edge: GraphEdge) -> str:
            materialized.append(edge.source)
            return original_graph_text(edge)

        core._graph_text = record_graph_text
        candidates = core._graph_candidates({"anchor", "needle"})

        assert [candidate.source for candidate in candidates] == [relevant.source]
        assert unrelated.source not in materialized
        assert relevant.source in materialized


def test_scoped_session_provenance_preserves_assistant_role_and_isolates_sessions() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-scoped-session-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True)
        local_sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash("session-local"),
            taskKey=BrainCore._scope_hash("task-local"),
            workspaceKey=BrainCore._scope_hash("workspace-local"),
        )
        foreign_sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash("session-foreign"),
            taskKey=BrainCore._scope_hash("task-foreign"),
            workspaceKey=BrainCore._scope_hash("workspace-local"),
        )
        (memory_root / "sandglass.txt").write_text(
            "\n".join(
                [
                    f"2026-07-20 09:00:00 | {local_sender} | [SESSION][VERIFIED] assistant route recommendation is local-route",
                    f"2026-07-20 09:01:00 | {foreign_sender} | [SESSION][VERIFIED] assistant route recommendation is foreign-route",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        original_session = os.environ.get("SUPER_BRAIN_SESSION_ID")
        os.environ["SUPER_BRAIN_SESSION_ID"] = "session-local"
        try:
            core = BrainCore(ROOT, memory_root)
            results = core.recall("what did you recommend route?", top_k=3, max_tokens=500, layer="session")
        finally:
            if original_session is None:
                os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_SESSION_ID"] = original_session

        assert len(results) == 1
        assert "local-route" in results[0]["text"]
        assert "foreign-route" not in results[0]["text"]
        assert results[0]["evidenceCard"]["senderRole"] == "assistant"
        assert results[0]["evidenceCard"]["provenanceScope"] == "scoped"


def test_missing_self_model_snapshot_is_explicitly_unknown() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-self-model-missing-") as directory:
        core = make_core(Path(directory))

        results = core.recall("你是谁，你现在做过什么？", top_k=1, max_tokens=500)

        assert results
        card = results[0]["evidenceCard"]
        assert "[VERIFIED]" not in results[0]["text"]
        assert card["lastVerified"] == "unverified"
        assert card["relevanceStatus"] == "self_model_missing"
        assert "current state is unknown" in results[0]["text"]


def test_fresh_evidence_backed_self_model_is_verified() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-self-model-fresh-") as directory:
        workspace = Path(directory)
        write_json(
            workspace / "self-model.json",
            {
                "schema": "super-brain.self-model.v1",
                "packageVersion": package_version(),
                "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "evidenceStatus": "verified",
                "identity": "Super Memory Brain / G1 local control plane",
                "role": "route and verify from governed local evidence",
                "verifiedCapabilities": ["bounded memory recall"],
                "currentState": "Package verification is current.",
                "userModel": "Governed preferences are available.",
                "knownLimits": ["memory is evidence, not authority"],
                "nextAction": "Continue the current verified task.",
                "evidence": ["last-verify-package.json:ok"],
                "rawPromptStored": False,
            },
        )
        core = make_core(workspace)

        results = core.recall("你是谁，你会做什么？", top_k=1, max_tokens=500)

        assert results
        card = results[0]["evidenceCard"]
        assert "[VERIFIED]" in results[0]["text"]
        assert card["lastVerified"] == "verified"
        assert card["relevanceStatus"] == "authoritative"
        assert card["verificationStatus"] == "verified"


def test_shared_memory_root_uses_its_control_plane_workspace_for_self_model() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-self-model-shared-root-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        memory_root.mkdir(parents=True, exist_ok=True)
        write_json(
            workspace / "self-model.json",
            {
                "schema": "super-brain.self-model.v1",
                "packageVersion": package_version(),
                "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "evidenceStatus": "verified",
                "identity": "shared-root control plane",
                "role": "verified shared-memory self-model",
                "evidence": ["control-plane verification"],
                "rawPromptStored": False,
            },
        )
        core = BrainCore(ROOT, memory_root)

        assert core.workspace == workspace
        results = core.recall("who are you", top_k=1, max_tokens=500)

        assert results
        assert "shared-root control plane" in results[0]["text"]
        assert results[0]["evidenceCard"]["selfModelStatus"] == "verified"


def test_status_projects_current_h7_retired_transport_guard() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-health-axes-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        memory_root.mkdir(parents=True)
        codex_home = state_root / "codex-home"
        codex_home.mkdir()
        previous_codex_home = os.environ.get("CODEX_HOME")
        os.environ["CODEX_HOME"] = str(codex_home)
        try:
            write_json(
                workspace / "super-brain-state.json",
                {
                    "ok": True,
                    "coreAvailable": True,
                    "version": package_version(),
                    "lastVerifyOk": True,
                    "updatedAt": "2026-08-03 12:00:00",
                },
            )
            status = BrainCore(ROOT, memory_root).status()

            assert status["ok"] is True and status["coreAvailable"] is True
            assert status["agentIdentity"] == {
                "schema": "super-brain.agent-identity.v1",
                "kind": "independent_control_plane_agent",
                "authority": "h7_rules_contract_and_project_evidence",
                "hostAdapterRole": "entry_only",
                "collaborationRole": "other_agents_are_bounded_workers_reviewers_or_verifiers",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
            assert status["authorityModel"] == {
                "schema": "super-brain.authority-model.v1",
                "systemRole": "independent_control_plane_agent",
                "objectiveAuthority": "latest_user_instruction",
                "executionAuthority": "h7_scope_bound_execution_contract",
                "progressAuthority": "assistant_visible_reply_plus_current_project_progress_proof",
                "factAuthority": "live_project_evidence",
                "behaviorAuthority": "versioned_core_rule_registry",
                "supplementalOnly": ["typed_memory", "absorbed_capabilities", "bounded_collaborator_agents"],
                "hostAdapterAuthority": "entry_only_non_authorizing",
                "conflictPolicy": "withhold_reconcile",
                "rawPromptStored": False,
                "rawTranscriptStored": False,
            }
            assert "hookAcceleration" not in status
            assert "p7" not in status
            assert status["turnRuntime"]["mode"] == "hookless_turn_runtime"
            assert status["retiredTransportGuard"]["state"] == "ready"
            assert status["retiredTransportGuard"]["code"] == "H7_RETIRED_TRANSPORT_GUARD_CURRENT"
            assert status["retiredTransportGuard"]["actionAuthorization"] == "not_authorizing"
        finally:
            if previous_codex_home is None:
                os.environ.pop("CODEX_HOME", None)
            else:
                os.environ["CODEX_HOME"] = previous_codex_home


def test_status_separates_core_availability_from_failed_verification() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-status-axes-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        memory_root.mkdir(parents=True)
        write_json(
            workspace / "super-brain-state.json",
            {
                "schema": "super-brain.state.v2",
                "ok": False,
                "okScope": "legacy_strict_core_and_current_verification",
                "coreAvailable": True,
                "operational": {"state": "available", "available": True},
                "verification": {
                    "state": "failed",
                    "passed": False,
                    "checkedAt": "2026-08-05T00:00:00+00:00",
                    "requiredForCore": False,
                },
                "version": package_version(),
            },
        )
        status = BrainCore(ROOT, memory_root).status()

        assert status["ok"] is False and status["coreAvailable"] is True
        assert status["okScope"] == "legacy_strict_core_and_current_verification"
        assert status["operational"]["state"] == "available"
        assert status["verification"]["state"] == "failed"
        assert status["verification"]["passed"] is False
        assert status["verifyOk"] is False
        assert status["stateTrust"] == "source_qualified"


def test_stale_self_model_snapshot_downgrades_to_unknown() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-self-model-stale-") as directory:
        workspace = Path(directory)
        write_json(
            workspace / "self-model.json",
            {
                "schema": "super-brain.self-model.v1",
                "packageVersion": package_version(),
                "updatedAt": (datetime.now() - timedelta(hours=25)).strftime("%Y-%m-%d %H:%M:%S"),
                "evidenceStatus": "verified",
                "identity": "stale snapshot",
                "evidence": ["last-verify-package.json:ok"],
                "rawPromptStored": False,
            },
        )
        core = make_core(workspace)

        results = core.recall("你是谁，你现在状态如何？", top_k=1, max_tokens=500)

        assert results
        card = results[0]["evidenceCard"]
        assert "[VERIFIED]" not in results[0]["text"]
        assert card["relevanceStatus"] == "self_model_stale"
        assert card["verificationStatus"] == "unknown"


def test_newer_task_context_beats_an_older_matching_checkpoint() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-stale-checkpoint-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        memory_root.mkdir(parents=True, exist_ok=True)
        workspace_key = "ws-runtime-stale-checkpoint"
        task_id = "task-runtime-stale-checkpoint"
        thread_id = "runtime-stale-checkpoint-thread"
        now = datetime.now()
        write_authoritative_task_contract(
            workspace,
            workspace_key,
            thread_id,
            task_id,
            task_name="Runtime stale checkpoint",
            current_step="use latest verified action",
            next_action="use latest verified action",
            updated_at=now.strftime("%Y-%m-%d %H:%M:%S"),
        )
        write_json(
            workspace / "runtime-state" / "checkpoints" / "active" / f"{task_id}.json",
            {
                "status": "active",
                "taskId": task_id,
                "workspaceKey": workspace_key,
                "version": package_version(),
                "timestamp": (now - timedelta(days=2)).strftime("%Y-%m-%d %H:%M:%S"),
                "nextAction": "repeat obsolete mutation",
            },
        )
        previous_workspace_key = os.environ.get("SUPER_BRAIN_WORKSPACE_KEY")
        previous_thread = os.environ.get("CODEX_THREAD_ID")
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        os.environ["CODEX_THREAD_ID"] = thread_id
        try:
            core = BrainCore(ROOT, memory_root)
            results = core.recall("current task next step", top_k=1, max_tokens=500)
        finally:
            if previous_workspace_key is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace_key
            if previous_thread is None:
                os.environ.pop("CODEX_THREAD_ID", None)
            else:
                os.environ["CODEX_THREAD_ID"] = previous_thread
            if previous_session is not None:
                os.environ["SUPER_BRAIN_SESSION_ID"] = previous_session

        assert results
        assert "use latest verified action" in results[0]["text"]
        assert "repeat obsolete mutation" not in results[0]["text"]


def test_rejected_memory_is_not_default_recall_evidence() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-rejected-memory-") as directory:
        core = make_core(Path(directory))
        query = "database engine decision"
        candidate = Candidate(
            text="[DECISION][CURRENT][VERIFIED][NEGATIVE_FEEDBACK] database engine decision: use SQLite",
            source="fixture",
            source_type="sandglass",
            reason="fixture",
        )

        scored = core._score(candidate, query, core._query_terms(query), False, {}, 1)

        assert scored is None


def test_stale_status_snapshot_cannot_beat_live_manifest_version() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-stale-status-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True, exist_ok=True)
        write_json(
            state_root / "workspace" / "status-card.json",
            {
                "version": "0.0.1-stale",
                "packageOk": True,
                "verifyOk": True,
                "hotRefreshOk": True,
            },
        )
        core = BrainCore(ROOT, memory_root)

        results = core.recall("current super-memory-brain version", top_k=1, max_tokens=300)
        status = core.status()

        assert len(results) == 1
        assert package_version() in results[0]["text"]
        assert "0.0.1-stale" not in results[0]["text"]
        assert status["ok"] is False
        assert status["stateTrust"] == "unknown"
        assert status["stateSource"] == "unavailable_or_version_mismatch"


def test_live_status_snapshot_wins_combined_version_and_status_query() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-live-status-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        memory_root.mkdir(parents=True, exist_ok=True)
        write_json(
            state_root / "workspace" / "status-card.json",
            {
                "version": package_version(),
                "packageOk": True,
                "verifyOk": True,
                "hotRefreshOk": True,
                "risksCount": 0,
            },
        )
        core = BrainCore(ROOT, memory_root)

        results = core.recall("current super-memory-brain version and status", top_k=1, max_tokens=300)

        assert len(results) == 1
        assert results[0]["source"] == "memory\\workspace\\status-card.json"
        assert '"verifyOk":true' in results[0]["text"]


def test_session_snippet_selects_the_turn_that_contains_the_answer() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-session-snippet-") as directory:
        core = make_core(Path(directory))
        query = "What is my database preference?"
        session = {
            "messages": [
                {
                    "role": "user",
                    "content": "I have 42 unrelated notes. " + "Noise without the answer. " * 20,
                },
                {
                    "role": "assistant",
                    "content": "Your database preference is PostgreSQL.",
                },
            ]
        }
        text = "[SESSION] session_content=" + json.dumps(session)

        snippet = core._candidate_snippet(text, query, core._query_terms(query), max_chars=180)

        assert "PostgreSQL" in snippet
        assert snippet.index("assistant:") < snippet.index("user:")


def test_mcp_only_probe_replays_the_narrow_stdio_contract() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-only-") as directory:
        memory_root = Path(directory) / "shared"
        memory_root.mkdir(parents=True)
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "brain_eval.py"),
                "--package-root",
                str(ROOT),
                "--memory-root",
                str(memory_root),
                "--mcp-only",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=30,
        )
        report = json.loads(completed.stdout)

        assert completed.returncode == 0, completed.stderr
        assert report["ok"] is True
        assert report["suite"] == "super-brain-mcp-smoke"
        assert report["memoryEmpty"] is True
        assert [item["name"] for item in report["mcpReplay"]["checks"]] == [
            "initialize",
            "tools_list",
            "call_brain_recall",
            "call_brain_status",
            "call_brain_recent",
            "brain_turn_metadata_scope",
            "brain_turn_missing_metadata_fails_closed",
        ]


def test_retired_prompt_hook_never_observes_or_mutates_state() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-native-observe-only-") as directory:
        state_root = Path(directory)
        sentinel = "PROMPT_SENTINEL_MUST_NOT_BE_READ_OR_STORED"
        before = file_hashes(state_root)
        environment = os.environ.copy()
        environment["SUPER_BRAIN_STATE_ROOT"] = str(state_root)
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                str(ROOT / "runtime" / "codex_prompt_hook.py"),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=environment,
            input=sentinel,
            check=False,
            timeout=10,
        )

        assert completed.returncode == 0, completed.stderr
        payload = json.loads(completed.stdout)
        assert payload == {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ""}}
        assert sentinel not in completed.stdout
        assert before == file_hashes(state_root)


def test_h7_progress_checkpoint_refuses_truncation_without_a_prompt_packet() -> None:
    checkpoint, code = _normalize_progress_checkpoint(
        {
            "last_confirmed_sentence": "progress " + "x" * 600,
            "current_phase": "phase " + "y" * 200,
            "current_step": "step " + "z" * 300,
            "next_action": "next " + "q" * 500,
            "source": "assistant_visible_reply",
        }
    )

    # A visible-progress anchor must be exact. Truncating it to fit an old
    # budget would create a new sentence and let recovery drift from what the
    # user actually saw, so H7 rejects the packet instead.
    assert code == "H7_PROGRESS_CHECKPOINT_FIELDS_INVALID"
    assert checkpoint is None


if __name__ == "__main__":
    test_adaptive_sparse_recall_uses_fts_before_heavier_backends()
    test_adaptive_sparse_recall_uses_bounded_scan_after_fts_miss()
    test_brain_core_keeps_memory_roots_process_isolated()
    test_brain_core_projects_retired_agent_and_group_roots_to_shared()
    test_runtime_layout_beats_a_stale_nexsandbase_environment_root()
    test_current_task_recall_rejects_stale_global_checkpoint()
    test_current_workspace_scope_uses_host_cwd_not_derived_status_card()
    test_execution_contract_context_requires_current_native_intent_receipt()
    test_no_hook_context_uses_real_host_scope_and_stays_read_only()
    test_context_recovers_from_a_lagging_hot_index_after_a_committed_transition()
    test_turn_close_policy_requires_current_turn_attestation_and_never_echoes_input()
    test_mcp_does_not_expose_untrusted_host_context()
    test_unbound_task_pointer_without_current_session_fails_closed()
    test_session_bound_pointer_without_execution_contract_fails_closed()
    test_bound_context_without_current_session_fails_closed()
    test_retired_prompt_hook_exports_no_continuity_authority()
    test_h7_turn_intent_is_typed_and_never_parses_prompt_text()
    test_current_task_recall_prefers_session_bound_execution_contract()
    test_personal_unknown_fact_does_not_use_unrelated_memory()
    test_exact_personal_profile_fact_remains_recallable()
    test_personal_identity_and_education_queries_abstain_from_decisions()
    test_verified_personal_field_requires_a_matching_profile_field()
    test_canonical_decision_key_beats_related_graph_memory()
    test_unknown_historical_topic_does_not_match_generic_task_memory()
    test_token_boundaries_and_identity_anchors_block_unrelated_facts()
    test_multi_fact_identity_survives_trailing_punctuation_and_alias_expansion()
    test_temporal_target_beats_current_snapshot_and_suppresses_conflict()
    test_generic_verified_personal_fields_are_recallable()
    test_generic_manifest_word_does_not_force_package_state_route()
    test_runtime_output_policy_uses_safe_defaults_for_malformed_values()
    test_runtime_omits_below_summary_evidence_and_marks_summary_only()
    test_runtime_applies_context_budget_on_primary_recall_path()
    test_runtime_hard_output_ceiling_survives_disabled_context_budget()
    test_temporal_recall_requires_identity_evidence()
    test_generic_conflicts_abstain_without_current_evidence()
    test_graph_decision_facets_keep_the_current_decides_edge()
    test_conflicting_current_graph_decisions_abstain()
    test_graph_expansion_is_one_hop_and_skips_stale_edges()
    test_graph_subject_prefilter_avoids_materializing_unrelated_edges()
    test_scoped_session_provenance_preserves_assistant_role_and_isolates_sessions()
    test_missing_self_model_snapshot_is_explicitly_unknown()
    test_fresh_evidence_backed_self_model_is_verified()
    test_shared_memory_root_uses_its_control_plane_workspace_for_self_model()
    test_status_projects_current_h7_retired_transport_guard()
    test_stale_self_model_snapshot_downgrades_to_unknown()
    test_newer_task_context_beats_an_older_matching_checkpoint()
    test_rejected_memory_is_not_default_recall_evidence()
    test_stale_status_snapshot_cannot_beat_live_manifest_version()
    test_live_status_snapshot_wins_combined_version_and_status_query()
    test_session_snippet_selects_the_turn_that_contains_the_answer()
    test_mcp_only_probe_replays_the_narrow_stdio_contract()
    test_retired_prompt_hook_never_observes_or_mutates_state()
    test_h7_progress_checkpoint_refuses_truncation_without_a_prompt_packet()
    print("RUNTIME_BRAIN_REGRESSION_OK")
