import json
import os
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from brain_core import BrainCore, Candidate


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


def make_isolated_recall_core(workspace: Path) -> BrainCore:
    core = make_core(workspace)
    core._graph_candidates = lambda terms: []
    core._experience_candidates = lambda query, terms: []
    core._profile_card_candidates = lambda query, terms: []
    core._recent_candidates = lambda terms, limit: []
    return core


def copy_policy(core: BrainCore) -> dict[str, object]:
    return json.loads(json.dumps(core.policy))


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

        class FakeSqlite:
            def __init__(self) -> None:
                self.searches = 0

            def sync_incremental(self) -> None:
                return None

            def search(self, query: str, limit: int) -> list[tuple[int, str, str]]:
                self.searches += 1
                return [(7, "2026-07-18", "browser automation uses Playwright first")]

        class FakeVault:
            idx_searches = 0
            legacy_searches = 0

            def idx_search(self, query: str, limit: int) -> list[object]:
                self.idx_searches += 1
                return []

            def search(self, query: str, limit: int) -> list[object]:
                self.legacy_searches += 1
                return []

        sqlite = FakeSqlite()
        vault = FakeVault()
        modules = {"sandglass_sqlite": sqlite, "sandglass_vault": vault}
        core._module = lambda name: modules[name]

        results = core._sandglass_candidates("browser automation", top_k=3)

        assert results
        assert results[0].reason == "sandglass_fts5"
        assert sqlite.searches >= 1
        assert vault.idx_searches == 0
        assert vault.legacy_searches == 0


def test_adaptive_sparse_recall_uses_idx_only_after_fts_miss() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-adaptive-idx-") as directory:
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

        class EmptySqlite:
            def sync_incremental(self) -> None:
                return None

            def search(self, query: str, limit: int) -> list[object]:
                return []

        class FakeVault:
            def __init__(self) -> None:
                self.idx_searches = 0
                self.legacy_searches = 0

            def idx_search(self, query: str, limit: int) -> list[tuple[int, str, str]]:
                self.idx_searches += 1
                return [(9, "2026-07-18", "fuzzy indexed memory")]

            def search(self, query: str, limit: int) -> list[object]:
                self.legacy_searches += 1
                return []

        vault = FakeVault()
        modules = {"sandglass_sqlite": EmptySqlite(), "sandglass_vault": vault}
        core._module = lambda name: modules[name]

        results = core._sandglass_candidates("fuzzy memory", top_k=3)

        assert results
        assert results[0].reason == "sandglass_idx_fallback"
        assert vault.idx_searches >= 1
        assert vault.legacy_searches == 0


def test_current_task_recall_rejects_stale_global_checkpoint() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-task-recall-") as directory:
        workspace = Path(directory)
        workspace_key = "ws-111111111111111111111111"
        task_id = "task-current-20260717"
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

        core = make_core(workspace)
        results = core.recall("当前任务下一步是什么？", top_k=3, max_tokens=500)
        serialized = json.dumps(results, ensure_ascii=False)

        assert results
        assert "运行任务召回回归" in serialized
        assert "wrong stale" not in serialized
        assert all(item["layer"] == "task" for item in results)


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
                text="[CURRENT][VERIFIED][RULE] key=atoapi-smart-hit-boundary decision=When off, Atoapi must act as transparent forwarding.",
                source="110:2026-07-10",
                source_type="sandglass",
                reason="sandglass_search",
            )
        ]
        core._graph_candidates = lambda terms: [
            Candidate(
                text="decision:atoapi-cache-directed-relay-v1-stage2-canary decides smart-hit enabled cache behavior",
                source="319",
                source_type="graph",
                reason="graph_decision_or_lineage",
                relation_priority=0,
            )
        ]

        results = core.recall("smart-hit关闭规则", top_k=2, max_tokens=500)

        assert results
        assert results[0]["identityKey"] == "decision:atoapi-smart-hit-boundary"
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
        now = datetime.now()
        write_json(
            workspace / "current-task-context.json",
            {
                "status": "active",
                "stale": False,
                "taskId": task_id,
                "workspaceKey": workspace_key,
                "version": package_version(),
                "checkedAt": now.strftime("%Y-%m-%d %H:%M:%S"),
                "currentStep": "use latest verified action",
                "nextAction": "use latest verified action",
            },
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
        os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = workspace_key
        try:
            core = BrainCore(ROOT, memory_root)
            results = core.recall("current task next step", top_k=1, max_tokens=500)
        finally:
            if previous_workspace_key is None:
                os.environ.pop("SUPER_BRAIN_WORKSPACE_KEY", None)
            else:
                os.environ["SUPER_BRAIN_WORKSPACE_KEY"] = previous_workspace_key

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

        assert len(results) == 1
        assert package_version() in results[0]["text"]
        assert "0.0.1-stale" not in results[0]["text"]


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


if __name__ == "__main__":
    test_adaptive_sparse_recall_uses_fts_before_heavier_backends()
    test_adaptive_sparse_recall_uses_idx_only_after_fts_miss()
    test_current_task_recall_rejects_stale_global_checkpoint()
    test_personal_unknown_fact_does_not_use_unrelated_memory()
    test_exact_personal_profile_fact_remains_recallable()
    test_personal_identity_and_education_queries_abstain_from_decisions()
    test_verified_personal_field_requires_a_matching_profile_field()
    test_canonical_decision_key_beats_related_graph_memory()
    test_unknown_historical_topic_does_not_match_generic_task_memory()
    test_token_boundaries_and_identity_anchors_block_unrelated_facts()
    test_temporal_target_beats_current_snapshot_and_suppresses_conflict()
    test_generic_verified_personal_fields_are_recallable()
    test_generic_manifest_word_does_not_force_package_state_route()
    test_runtime_output_policy_uses_safe_defaults_for_malformed_values()
    test_runtime_omits_below_summary_evidence_and_marks_summary_only()
    test_runtime_applies_context_budget_on_primary_recall_path()
    test_missing_self_model_snapshot_is_explicitly_unknown()
    test_fresh_evidence_backed_self_model_is_verified()
    test_shared_memory_root_uses_its_control_plane_workspace_for_self_model()
    test_stale_self_model_snapshot_downgrades_to_unknown()
    test_newer_task_context_beats_an_older_matching_checkpoint()
    test_rejected_memory_is_not_default_recall_evidence()
    test_stale_status_snapshot_cannot_beat_live_manifest_version()
    test_live_status_snapshot_wins_combined_version_and_status_query()
    test_session_snippet_selects_the_turn_that_contains_the_answer()
    print("RUNTIME_BRAIN_REGRESSION_OK")
