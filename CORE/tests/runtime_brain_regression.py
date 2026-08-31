import base64
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "runtime"))

from brain_control import BrainControl
from brain_context import canonical_hash, intent_context_projection_path, scope_ref
import brain_core as brain_core_module
from brain_core import BrainCore, Candidate, GraphEdge
from brain_mcp import TOOLS as MCP_TOOLS, handle_tool
from continuation_policy import decide_turn_close
from layout_paths import resolve_layout_path, state_root
from mcp_runtime_identity import runtime_dependency_paths
from turn_close_dispatcher import _normalize_progress_checkpoint
from turn_intent import resolve_turn_intent
from turn_runtime import _contract_binding


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


def cwd_workspace_key(path: Path) -> str:
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
                    "conditions": ["A unique local project scope is verified."],
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

        core._read_only_fts_rows_batch = lambda queries, limit: [
            read_only_fts(query, limit) for query in queries
        ]

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

        core._read_only_fts_rows_batch = lambda queries, limit: [[] for _ in queries]

        results = core._sandglass_candidates("fuzzy memory", top_k=3)

        assert results
        assert results[0].reason == "sandglass_anchor_scan"


def test_adaptive_sparse_recall_reuses_one_read_only_sqlite_connection() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-adaptive-fts-batch-") as directory:
        memory_root = Path(directory) / "shared"
        memory_root.mkdir(parents=True)
        database = memory_root / "sandglass.db"
        connection = sqlite3.connect(database)
        try:
            connection.execute(
                "CREATE TABLE sandglass (id INTEGER PRIMARY KEY, ts TEXT, sender TEXT, text TEXT)"
            )
            connection.execute("CREATE VIRTUAL TABLE sandglass_fts USING fts5(tokens)")
            connection.execute(
                "INSERT INTO sandglass (id, ts, sender, text) VALUES (1, '2026-07-18', 'user', 'alpha marker')"
            )
            connection.execute(
                "INSERT INTO sandglass (id, ts, sender, text) VALUES (2, '2026-07-18', 'user', 'beta marker')"
            )
            connection.execute("INSERT INTO sandglass_fts (rowid, tokens) VALUES (1, 'alpha marker')")
            connection.execute("INSERT INTO sandglass_fts (rowid, tokens) VALUES (2, 'beta marker')")
            connection.commit()
        finally:
            connection.close()

        core = BrainCore(ROOT, memory_root)
        policy = copy_policy(core)
        policy["retrieval"]["dynamic"]["fullScanFallback"] = False
        core.policy = policy
        core._search_queries = lambda query: ["alpha", "beta", "alpha"]
        original_connect = sqlite3.connect
        with mock.patch.object(sqlite3, "connect", wraps=original_connect) as connect:
            candidates = core._sandglass_candidates("irrelevant query", top_k=3)

        assert connect.call_count == 1
        assert [candidate.text for candidate in candidates] == ["alpha marker", "beta marker"]
    assert [candidate.reason for candidate in candidates] == [
        "sandglass_fts5_readonly",
        "sandglass_fts5_variant",
    ]


def test_adaptive_sparse_recall_retries_variants_after_transient_batch_connect_failure() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-adaptive-fts-retry-") as directory:
        memory_root = Path(directory) / "shared"
        memory_root.mkdir(parents=True)
        database = memory_root / "sandglass.db"
        connection = sqlite3.connect(database)
        try:
            connection.execute("CREATE TABLE sandglass (id INTEGER PRIMARY KEY, ts TEXT, sender TEXT, text TEXT)")
            connection.execute("CREATE VIRTUAL TABLE sandglass_fts USING fts5(tokens)")
            connection.execute(
                "INSERT INTO sandglass (id, ts, sender, text) VALUES (1, '2026-07-18', 'user', 'alpha marker')"
            )
            connection.execute(
                "INSERT INTO sandglass (id, ts, sender, text) VALUES (2, '2026-07-18', 'user', 'beta marker')"
            )
            connection.execute("INSERT INTO sandglass_fts (rowid, tokens) VALUES (1, 'alpha marker')")
            connection.execute("INSERT INTO sandglass_fts (rowid, tokens) VALUES (2, 'beta marker')")
            connection.commit()
        finally:
            connection.close()

        core = BrainCore(ROOT, memory_root)
        original_connect = sqlite3.connect
        calls = 0

        def flaky_connect(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise sqlite3.OperationalError("transient batch connection failure")
            return original_connect(*args, **kwargs)

        with mock.patch.object(sqlite3, "connect", side_effect=flaky_connect):
            rows = core._read_only_fts_rows_batch(["alpha", "beta"], 3)

        assert calls == 3
        assert rows[0][0][3] == "alpha marker"
        assert rows[1][0][3] == "beta marker"


def test_recall_lexical_match_cache_is_call_scoped_and_score_equivalent() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-recall-lexical-cache-") as directory:
        core = make_isolated_recall_core(Path(directory))
        query = "alpha marker"
        terms = core._query_terms(query)
        anchors = core._query_anchors(query, terms)
        aliases: set[str] = set()
        identity_terms = core._query_identity_terms(query, terms)
        text = "[VERIFIED] alpha marker evidence remains exact."

        # The cached matcher is an exact memoization of the existing function;
        # score projections must stay byte-for-byte equivalent to the direct
        # matcher before it is used by the full recall path.
        direct = core._score(
            Candidate(text=text, source="direct", source_type="sandglass", reason="fixture"),
            query, terms, False, {}, 1, None,
            anchors=anchors, alias_terms=aliases, identity_terms=identity_terms,
        )
        score_cache: dict[tuple[str, str], bool] = {}

        def cached_match(value: str, term: str) -> bool:
            key = (value, term)
            if key not in score_cache:
                score_cache[key] = brain_core_module._contains_term(value, term)
            return score_cache[key]

        cached = core._score(
            Candidate(text=text, source="direct", source_type="sandglass", reason="fixture"),
            query, terms, False, {}, 1, None,
            anchors=anchors, alias_terms=aliases, identity_terms=identity_terms,
            contains_term=cached_match,
        )
        assert direct is not None and cached is not None
        assert vars(cached) == vars(direct)

        # Duplicate candidate text exercises document-frequency plus both score
        # passes.  One recall must invoke the boundary matcher once per unique
        # (text, term), while emitting the same deduplicated result.
        def fixture_candidates(_query: str, _top_k: int, _query_date: str = "") -> list[Candidate]:
            return [
                Candidate(text=text, source="1", source_type="sandglass", reason="fixture"),
                Candidate(text=text, source="2", source_type="sandglass", reason="fixture"),
            ]

        core._sandglass_candidates = fixture_candidates
        original_contains = brain_core_module._contains_term
        with mock.patch.object(brain_core_module, "_contains_term", wraps=original_contains) as contains:
            results = core.recall(query, top_k=2, max_tokens=200)
        assert contains.call_count == len(terms)
        assert len(results) == 1
        assert results[0]["text"] == text
        assert results[0]["matchedTerms"] == sorted(terms)

        # Force a reference recall to keep direct matching inside ``_score``.
        # It receives the same candidates and query but intentionally discards
        # the call-local matcher injection; public output must not change.
        reference = make_isolated_recall_core(Path(directory) / "reference")
        reference._sandglass_candidates = fixture_candidates
        direct_score = BrainCore._score

        def score_without_cache(*args, **kwargs):
            kwargs.pop("contains_term", None)
            return direct_score(reference, *args, **kwargs)

        reference._score = score_without_cache
        assert reference.recall(query, top_k=2, max_tokens=200) == results


def test_recall_scan_and_recent_fallback_share_request_local_sandglass_read() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-recall-sandglass-cache-") as directory:
        root = Path(directory)
        memory_root = root / "shared"
        memory_root.mkdir(parents=True)
        sandglass = memory_root / "sandglass.txt"
        sandglass.write_text(
            "2026-07-18 09:00:00 | user | fallback-anchor evidence\n",
            encoding="utf-8",
        )
        core = BrainCore(ROOT, memory_root)
        core.workspace = root / "workspace"
        core._graph_candidates = lambda terms: []
        core._experience_candidates = lambda query, terms: []
        core._profile_card_candidates = lambda query, terms: []
        core._read_only_fts_rows_batch = lambda queries, limit: [[] for _ in queries]

        cache_ids: list[int] = []

        def full_scan(query: str, top_k: int, query_date: str = "") -> list[Candidate]:
            cache_ids.append(id(brain_core_module._RECALL_SANDGLASS_CACHE.get()))
            # Populate the same request-local raw-line cache used by the real
            # sandglass candidate path, then return no scored candidates so the
            # recent fallback is exercised.
            core._scan_sandglass_candidates(
                {"fallback-anchor"},
                {"fallback-anchor"},
                None,
                set(),
                100,
            )
            return []

        def recent_fallback(terms: set[str], limit: int) -> list[Candidate]:
            cache_ids.append(id(brain_core_module._RECALL_SANDGLASS_CACHE.get()))
            rows = core._recent_sandglass_rows(limit)
            return [
                Candidate(
                    text=str(row[3]),
                    source=f"{row[0]}:{row[1]}",
                    source_type="recent",
                    reason="recent_fallback",
                    timestamp=str(row[1]),
                    sender=str(row[2]),
                    session_key=str(row[4]),
                    task_key=str(row[5]),
                    workspace_key=str(row[6]),
                )
                for row in rows
            ]

        core._sandglass_candidates = full_scan
        core._recent_candidates = recent_fallback
        original_open = Path.open
        open_count = 0

        def counting_open(path: Path, *args, **kwargs):
            nonlocal open_count
            if path == sandglass:
                open_count += 1
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, "open", counting_open):
            results = core.recall("fallback-anchor", top_k=2, max_tokens=300)

        assert open_count == 1
        assert len(cache_ids) == 2 and cache_ids[0] == cache_ids[1]
        assert results and "fallback-anchor evidence" in results[0]["text"]
        assert brain_core_module._RECALL_SANDGLASS_CACHE.get() is None


def test_recall_sandglass_reuse_requires_complete_unchanged_scan() -> None:
    """The fallback may reuse only a complete scan of the same file stamp."""

    with tempfile.TemporaryDirectory(prefix="super-brain-recall-sandglass-reuse-guards-") as directory:
        root = Path(directory)
        memory_root = root / "shared"
        memory_root.mkdir(parents=True)
        sandglass = memory_root / "sandglass.txt"
        sandglass.write_text(
            "\n".join(
                [
                    "2026-07-18 09:00:00 | user | first marker",
                    "2026-07-18 09:01:00 | user | second marker",
                    "2026-07-18 09:02:00 | user | third marker",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        core = BrainCore(ROOT, memory_root)
        original_content = sandglass.read_text(encoding="utf-8")
        original_open = Path.open
        open_count = 0
        count_opens = True

        def counting_open(path: Path, *args, **kwargs):
            nonlocal open_count
            if count_opens and path == sandglass:
                open_count += 1
            return original_open(path, *args, **kwargs)

        token = brain_core_module._RECALL_SANDGLASS_CACHE.set({})
        try:
            with mock.patch.object(Path, "open", counting_open):
                core._scan_sandglass_candidates(set(), {"marker"}, None, set(), 10)
                rows = core._recent_sandglass_rows(2)
                assert len(rows) == 2
                assert open_count == 1

                # A file stamp change invalidates the request-local replay.
                count_opens = False
                sandglass.write_text(
                    original_content + "2026-07-18 09:03:00 | user | changed marker\n",
                    encoding="utf-8",
                )
                count_opens = True
                changed_rows = core._recent_sandglass_rows(2)
                assert open_count == 2, open_count
                assert any(row[3] == "changed marker" for row in changed_rows)
        finally:
            brain_core_module._RECALL_SANDGLASS_CACHE.reset(token)

        # A bounded prefix that stops at scan_limit cannot represent the real
        # tail, so the fallback must perform its own complete pass.
        sandglass.write_text(
            "\n".join(
                [
                    "2026-07-18 09:00:00 | user | first marker",
                    "2026-07-18 09:01:00 | user | second marker",
                    "2026-07-18 09:02:00 | user | third marker",
                    "2026-07-18 09:03:00 | user | fourth marker",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        open_count = 0
        token = brain_core_module._RECALL_SANDGLASS_CACHE.set({})
        try:
            with mock.patch.object(Path, "open", counting_open):
                core._scan_sandglass_candidates(set(), {"marker"}, None, set(), 2)
                count_opens = False
                sandglass.write_text(
                    "2026-07-18 09:00:00 | user | replaced first marker\n"
                    "2026-07-18 09:01:00 | user | replaced second marker\n"
                    "2026-07-18 09:02:00 | user | replaced third marker\n"
                    "2026-07-18 09:03:00 | user | replaced fourth marker\n",
                    encoding="utf-8",
                )
                count_opens = True
                fresh_rows = core._recent_sandglass_rows(4)
                assert open_count == 2, open_count
                assert any(row[3] == "replaced first marker" for row in fresh_rows)
        finally:
            brain_core_module._RECALL_SANDGLASS_CACHE.reset(token)


def test_recall_json_projection_caches_are_stamp_aware_and_fail_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-recall-json-cache-") as directory:
        root = Path(directory)
        workspace = root / "workspace"
        package_version_value = package_version()
        now = datetime.now().isoformat(timespec="seconds")
        self_model = workspace / "self-model.json"
        profile_card = workspace / "profile-card.json"
        experience = workspace / "experiences" / "fixture.json"
        write_json(
            self_model,
            {
                "schema": "super-brain.self-model.v1",
                "updatedAt": now,
                "packageVersion": package_version_value,
                "evidence": ["fixture evidence"],
                "evidenceStatus": "verified",
                "rawPromptStored": False,
                "verifiedCapabilities": ["bounded recall"],
                "currentState": "ready",
            },
        )
        write_json(
            profile_card,
            {"evidenceCards": [{"claim": "[PROFILE][VERIFIED] preference fixture"}]},
        )
        write_json(
            experience,
            {
                "id": "fixture",
                "title": "deploy lesson",
                "status": "current",
                "recallQuery": "deploy lesson",
                "updatedAt": now,
                "evidence": ["fixture"],
            },
        )
        core = BrainCore(ROOT, root / "shared")
        core.workspace = workspace
        original_read_json = brain_core_module._read_json
        with mock.patch.object(brain_core_module, "_read_json", wraps=original_read_json) as reader:
            assert core._self_model_candidates("who are you")
            assert core._profile_card_candidates("my preference", {"preference"})
            assert core._experience_candidates("deploy lesson", {"deploy", "lesson"})
            first_count = reader.call_count
            assert first_count == 3

            # Same (mtime_ns, size) stamps reuse the parsed objects.
            core._self_model_candidates("who are you")
            core._profile_card_candidates("my preference", {"preference"})
            core._experience_candidates("deploy lesson", {"deploy", "lesson"})
            assert reader.call_count == first_count

            def bump(path: Path) -> None:
                stat = path.stat()
                os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000))

            write_json(profile_card, {"evidenceCards": [{"claim": "[PROFILE][VERIFIED] changed preference"}]})
            bump(profile_card)
            assert core._profile_card_candidates("my preference", {"preference"})
            assert reader.call_count == first_count + 1

            # A damaged source is read again but never reuses the prior
            # authority; repairing it then reads the replacement once more.
            self_model.write_text("{not-json", encoding="utf-8")
            bump(self_model)
            assert core._self_model_candidates("who are you")[0].snapshot_status == "missing"
            assert reader.call_count == first_count + 2
            write_json(
                self_model,
                {
                    "schema": "super-brain.self-model.v1",
                    "updatedAt": now,
                    "packageVersion": package_version_value,
                    "evidence": ["repaired"],
                    "evidenceStatus": "verified",
                    "rawPromptStored": False,
                },
            )
            bump(self_model)
            assert core._self_model_candidates("who are you")[0].snapshot_status == "verified"
            assert reader.call_count == first_count + 3


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
        workspace_key = cwd_workspace_key(workspace)
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

        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        previous_cwd = Path.cwd()
        os.chdir(workspace)
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
        try:
            core = make_isolated_recall_core(workspace)
            core._sandglass_candidates = lambda query, top_k, query_date="": []
            results = core.recall("当前任务下一步是什么？", top_k=3, max_tokens=500)
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread
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
        workspace_key = cwd_workspace_key(state_root / "workspace")
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
        previous_thread = os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        previous_cwd = Path.cwd()
        os.chdir(state_root / "workspace")
        try:
            assert core._current_task_context() is None
            ordinary = core.recall("current task next step", top_k=1, max_tokens=500, layer="all")
            forced = core.recall("unrelated intent", top_k=1, max_tokens=500, layer="task")
        finally:
            os.chdir(previous_cwd)
            if previous_thread is not None:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread
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
        workspace_key = cwd_workspace_key(state_root / "workspace")
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
        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        previous_cwd = Path.cwd()
        os.chdir(state_root / "workspace")
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
        try:
            pointer_context = core._current_task_context()
            assert pointer_context is not None
            assert pointer_context["_trust"] == "context_pointer"
            ordinary = core.recall("current task next step", top_k=1, max_tokens=500, layer="all")
            forced = core.recall("unrelated intent", top_k=1, max_tokens=500, layer="task")
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread
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
        workspace_key = cwd_workspace_key(workspace)
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
        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        previous_cwd = Path.cwd()
        os.chdir(workspace)
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
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
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread
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
        workspace_key = cwd_workspace_key(workspace)
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
        previous_thread = os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        previous_cwd = Path.cwd()
        os.chdir(workspace)
        try:
            results = BrainCore(ROOT, memory_root).recall("current task next step", top_k=1, max_tokens=500)
        finally:
            os.chdir(previous_cwd)
            if previous_thread is not None:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread
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
        workspace_key = cwd_workspace_key(workspace)
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

        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_cwd = Path.cwd()
        os.chdir(workspace)
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
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
                cwd=str(workspace),
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
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread

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


def test_current_workspace_scope_uses_cwd_not_derived_status_card() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-cwd-scope-") as directory:
        base = Path(directory)
        state_root = base / "state"
        workspace = state_root / "workspace"
        project_root = base / "project-root"
        project_root.mkdir(parents=True)
        workspace_key = cwd_workspace_key(project_root)
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
                "focusLabel": "Local cwd scope",
                "currentStep": "use the local project directory",
                "nextAction": "continue the cwd-bound task",
                "needsReconciliation": False,
                "planReceiptRequired": False,
                "updatedAt": updated_at,
            },
        )

        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_cwd = Path.cwd()
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
        os.chdir(project_root)
        try:
            core = make_core(workspace)
            assert core._current_workspace_key() == workspace_key
            context = core._execution_contract_context()
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread

        assert context is not None
        assert context["taskId"] == task_id
        assert context["workspaceKey"] == workspace_key


def test_execution_contract_context_filters_misprojected_completed_terminal_contracts() -> None:
    """A stale wake flag cannot make a completed terminal card ambiguous."""

    with tempfile.TemporaryDirectory(prefix="super-brain-wake-eligible-context-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = cwd_workspace_key(host_project)
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
        terminal_contract = json.loads(json.dumps(contract))
        terminal_contract.update(
            {
                "taskId": "task-terminal-history",
                "taskInstanceId": "ti-" + "b" * 32,
                "revision": 8,
                "focusId": "terminal-history",
                "focusLabel": "Terminal history",
                "currentPhase": "Complete",
                "currentStep": "Final H7 closeout is complete.",
                "nextAction": "No remaining task action; await the user's next instruction.",
                "pendingSteps": [],
                "returnStack": [],
                "canonicalPlan": {
                    "items": [
                        {"itemId": "terminal-item", "ordinal": 1, "label": "completed work", "status": "completed"}
                    ]
                },
                "planReceipt": {
                    "focusId": "terminal-history",
                    "contractRevision": 8,
                    "planFingerprint": "fixture-terminal-history",
                },
            }
        )
        write_json(
            workspace / "runtime-state" / "execution-contracts" / "task-terminal-history--fixture.json",
            terminal_contract,
        )
        index["entries"].append(
            {
                "taskId": "task-terminal-history",
                "status": "active",
                # Simulate an interrupted terminalization transaction: the
                # contract is structurally complete but the derived index has
                # not yet dropped its wake flag.
                "wakeEligible": True,
                "packageVersion": package_version(),
                "revision": 8,
                "updatedAt": updated_at,
                "contractFileName": "task-terminal-history--fixture.json",
            }
        )
        write_json(index_path, index)

        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_cwd = Path.cwd()
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
        os.chdir(host_project)
        try:
            core = make_core(workspace)
            context = core._execution_contract_context()
            routed_contract, routed_code = core._read_context_contract(workspace_key, session_key)
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread

        assert context is not None
        assert context["taskId"] == "task-runnable-current"
        assert routed_code == "BRAIN_CONTEXT_READY"
        assert routed_contract is not None
        assert routed_contract["taskId"] == "task-runnable-current"


def test_contract_screening_cache_never_authorizes_a_replaced_contract() -> None:
    """The final contract read must observe an atomic replacement after screening."""

    with tempfile.TemporaryDirectory(prefix="super-brain-contract-fresh-read-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = cwd_workspace_key(host_project)
        thread_id = "brain-core-contract-fresh-read-thread"
        task_id = "task-contract-fresh-read"
        session_key = write_authoritative_task_contract(
            workspace,
            workspace_key,
            thread_id,
            task_id,
            task_name="Fresh contract read",
            current_step="screen the current contract",
            next_action="return only the freshly validated contract",
            updated_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        contract_name = f"{task_id}--fixture.json"
        original_read_json = brain_core_module._read_json

        def run_with_replacement(reader):
            reads = 0

            def replacing_read(path):
                nonlocal reads
                value = original_read_json(path)
                if Path(path).name != contract_name:
                    return value
                reads += 1
                if reads < 2 or not isinstance(value, dict):
                    return value
                replacement = dict(value)
                replacement["taskId"] = "foreign-replaced-contract"
                return replacement

            with mock.patch.object(brain_core_module, "_read_json", side_effect=replacing_read):
                return reader(), reads

        core = make_core(workspace)
        context, context_reads = run_with_replacement(
            lambda: core._read_context_contract(workspace_key, session_key)
        )
        assert context[0] is None
        assert context[1] == "BRAIN_CONTEXT_CONTRACT_SCOPE_MISMATCH"
        assert context_reads == 2

        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_cwd = Path.cwd()
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
        os.chdir(host_project)
        try:
            execution_context, execution_reads = run_with_replacement(
                core._execution_contract_context
            )
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread
        assert execution_context is None
        assert execution_reads == 2


def test_context_contract_reader_rejects_path_like_scope_values() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-context-scope-guard-") as directory:
        state_root = Path(directory)
        core = BrainCore(ROOT, state_root / "shared")
        contract, code = core._read_context_contract(
            "../../foreign-workspace",
            "sid-" + "a" * 24,
        )
        assert contract is None
        assert code == "BRAIN_CONTEXT_SCOPE_INVALID"
        assert not (state_root / "foreign-workspace").exists()


def test_terminal_finalization_context_is_opt_in_unique_and_never_auto_wakes() -> None:
    """One verified terminal task may re-enter H7 only to publish its final close."""

    with tempfile.TemporaryDirectory(prefix="super-brain-terminal-finalization-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = cwd_workspace_key(host_project)
        thread_id = "brain-core-terminal-finalization-thread"
        updated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        task_id = "task-terminal-finalization"
        session_key = write_authoritative_task_contract(
            workspace,
            workspace_key,
            thread_id,
            task_id,
            task_name="Terminal finalization task",
            current_step="Prepare the final H7 close.",
            next_action="No automatic action: terminal close is pending.",
            updated_at=updated_at,
        )
        index_path = workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json"
        contract_path = workspace / "runtime-state" / "execution-contracts" / f"{task_id}--fixture.json"
        index = json.loads(index_path.read_text(encoding="utf-8"))
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        contract.update(
            {
                "taskInstanceId": "ti-" + "c" * 32,
                "currentPhase": "Complete",
                "currentStep": "Prepare the final H7 close.",
                "nextAction": "No automatic action: terminal close is pending.",
                "returnStack": [],
                # The final H7 checkpoint is responsible for refreshing this
                # proof atomically.  A withheld proof must still be selectable
                # only through the explicit terminal-finalization path.
                "projectProgressProof": {"state": "withheld"},
                "canonicalPlan": {
                    "items": [
                        {"itemId": "item-terminal", "ordinal": 1, "label": "terminal work", "status": "completed"}
                    ]
                },
            }
        )
        contract.pop("visibleProgressReceipt", None)
        index["entries"][0]["wakeEligible"] = False
        write_json(contract_path, contract)
        write_json(index_path, index)

        core = make_core(workspace)
        ordinary, ordinary_code = core._read_context_contract(workspace_key, session_key)
        terminal, terminal_code = core._read_context_contract(
            workspace_key,
            session_key,
            allow_terminal_finalization=True,
        )

        assert ordinary is None
        assert ordinary_code == "BRAIN_CONTEXT_NO_ACTIVE_CONTRACT"
        assert terminal is not None
        assert terminal_code == "BRAIN_CONTEXT_TERMINAL_FINALIZATION_READY"
        assert terminal["taskId"] == task_id
        terminal_bound, terminal_binding_code = _contract_binding(
            core,
            {
                "code": "BRAIN_CONTEXT_TERMINAL_FINALIZATION_READY",
                "scope": {"workspaceKey": workspace_key, "ownerSessionKey": session_key},
                "task": {"contractHash": canonical_hash(terminal)},
            },
        )
        assert terminal_binding_code == "TURN_RUNTIME_CONTRACT_CURRENT"
        assert terminal_bound is not None
        assert terminal_bound["taskId"] == task_id

        second_task = "task-terminal-finalization-second"
        second_name = f"{second_task}--fixture.json"
        second = json.loads(json.dumps(contract))
        second.update(
            {
                "taskId": second_task,
                "taskInstanceId": "ti-" + "d" * 32,
                "focusId": f"{second_task}-focus",
                "focusLabel": "Second terminal finalization task",
                "planReceipt": {
                    "focusId": f"{second_task}-focus",
                    "contractRevision": 1,
                    "planFingerprint": "fixture-terminal-second",
                },
            }
        )
        index["entries"].append(
            {
                "taskId": second_task,
                "status": "active",
                "wakeEligible": False,
                "packageVersion": package_version(),
                "revision": 1,
                "updatedAt": updated_at,
                "contractFileName": second_name,
            }
        )
        write_json(workspace / "runtime-state" / "execution-contracts" / second_name, second)
        write_json(index_path, index)

        ambiguous, ambiguous_code = core._read_context_contract(
            workspace_key,
            session_key,
            allow_terminal_finalization=True,
        )
        assert ambiguous is None
        assert ambiguous_code == "BRAIN_CONTEXT_TERMINAL_FINALIZATION_AMBIGUOUS"


def test_terminal_finalization_allows_missing_formal_closeout_with_existing_v4_receipt() -> None:
    """A terminal plan with a current v4 receipt remains repairable until its phase closeout exists."""

    with tempfile.TemporaryDirectory(prefix="super-brain-terminal-closeout-repair-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = cwd_workspace_key(host_project)
        thread_id = "brain-core-terminal-closeout-repair-thread"
        updated_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        task_id = "task-terminal-closeout-repair"
        session_key = write_authoritative_task_contract(
            workspace,
            workspace_key,
            thread_id,
            task_id,
            task_name="Terminal closeout repair task",
            current_step="Stage 4 closeout is still missing.",
            next_action="No automatic action: await the next instruction.",
            updated_at=updated_at,
        )
        contract_path = workspace / "runtime-state" / "execution-contracts" / f"{task_id}--fixture.json"
        index_path = workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json"
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        contract.update(
            {
                "taskInstanceId": "ti-" + "e" * 32,
                "currentPhase": "Stage 4 runtime validation and handoff",
                "currentStep": "Stage 4 closeout is still missing.",
                "nextAction": "No automatic action: await the next instruction.",
                "pendingSteps": [],
                "returnStack": [],
                "canonicalPlan": {
                    "items": [
                        {"itemId": "terminal-item", "ordinal": 1, "label": "completed work", "status": "completed"}
                    ]
                },
                "phaseCloseouts": [],
                "projectProgressProof": {"state": "withheld"},
                "visibleProgressReceipt": {
                    "schema": "super-brain.visible-progress-receipt.v1",
                    "source": "assistant_visible_reply",
                    "payloadHash": "a" * 64,
                },
            }
        )
        index = json.loads(index_path.read_text(encoding="utf-8"))
        index["entries"][0]["wakeEligible"] = False
        write_json(contract_path, contract)
        write_json(index_path, index)

        core = make_core(workspace)
        ordinary, ordinary_code = core._read_context_contract(workspace_key, session_key)
        terminal, terminal_code = core._read_context_contract(
            workspace_key,
            session_key,
            allow_terminal_finalization=True,
        )

        assert ordinary is None
        assert ordinary_code == "BRAIN_CONTEXT_NO_ACTIVE_CONTRACT"
        assert terminal is not None
        assert terminal_code == "BRAIN_CONTEXT_TERMINAL_FINALIZATION_READY"
        assert terminal["taskId"] == task_id

        # A same-session workspace can retain other terminal cards.  The
        # explicit checkpoint carries its formal phase, so H7 may use that
        # bounded phase token to select the matching terminal workline without
        # guessing from recency or a stale state card.
        second_task = "task-terminal-closeout-repair-other"
        second_name = f"{second_task}--fixture.json"
        second = json.loads(json.dumps(contract))
        second.update(
            {
                "taskId": second_task,
                "taskInstanceId": "ti-" + "f" * 32,
                "focusId": f"{second_task}-focus",
                "focusLabel": "Other terminal workline",
                "currentPhase": "Complete",
                "currentStep": "Other terminal work is complete.",
                "nextAction": "No automatic action: await the next instruction.",
                "planReceipt": {
                    "focusId": f"{second_task}-focus",
                    "contractRevision": 1,
                    "planFingerprint": "fixture-other-terminal",
                },
            }
        )
        second.pop("visibleProgressReceipt", None)
        index["entries"].append(
            {
                "taskId": second_task,
                "status": "active",
                "wakeEligible": False,
                "packageVersion": package_version(),
                "revision": 1,
                "updatedAt": updated_at,
                "contractFileName": second_name,
            }
        )
        write_json(workspace / "runtime-state" / "execution-contracts" / second_name, second)
        write_json(index_path, index)

        unhinted, unhinted_code = core._read_context_contract(
            workspace_key,
            session_key,
            allow_terminal_finalization=True,
        )
        hinted, hinted_code = core._read_context_contract(
            workspace_key,
            session_key,
            allow_terminal_finalization=True,
            terminal_finalization_phase="Stage 4 runtime validation and handoff",
        )
        assert unhinted is None
        assert unhinted_code == "BRAIN_CONTEXT_TERMINAL_FINALIZATION_AMBIGUOUS"
        assert hinted is not None
        assert hinted_code == "BRAIN_CONTEXT_TERMINAL_FINALIZATION_READY"
        assert hinted["taskId"] == task_id


def test_execution_contract_context_requires_current_native_intent_receipt() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-contract-intent-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = cwd_workspace_key(host_project)
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

        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_cwd = Path.cwd()
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
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
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread


def test_local_context_uses_cwd_scope_and_stays_read_only() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-no-hook-context-") as directory:
        state_root = Path(directory)
        workspace = state_root / "workspace"
        host_project = state_root / "host-project"
        host_project.mkdir()
        workspace_key = cwd_workspace_key(host_project)
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
                "currentStep": "verify pure local context",
                "nextAction": "continue only after the visible instruction is reconciled",
                "needsReconciliation": False,
                "planReceiptRequired": False,
                "updatedAt": updated_at,
            },
        )
        write_native_memory_snapshot(workspace)

        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_legacy_session = os.environ.get("SUPER_BRAIN_SESSION_ID")
        previous_cwd = Path.cwd()
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
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
            cli_environment["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
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
            off_core._context_session_key = lambda: (_ for _ in ()).throw(AssertionError("memory:off must not inspect local scope"))
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

            os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            missing_thread = core.context("auto")
            assert missing_thread["code"] == "BRAIN_CONTEXT_LOCAL_SESSION_MISSING"
            os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id

            index_path = workspace / "runtime-state" / "execution-hot-index" / f"{session_key}--{workspace_key}.json"
            index = json.loads(index_path.read_text(encoding="utf-8"))
            index["entries"].append({**index["entries"][0], "taskId": "task-no-hook-context-ambiguous"})
            write_json(index_path, index)
            ambiguous = core.context("auto")
            assert ambiguous["code"] == "BRAIN_CONTEXT_AMBIGUOUS_ACTIVE_CONTRACT"
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread
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
        workspace_key = cwd_workspace_key(host_project)
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

        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_cwd = Path.cwd()
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
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
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread


def test_mcp_does_not_expose_untrusted_host_context() -> None:
    tool_names = {str(tool.get("name", "")) for tool in MCP_TOOLS}
    assert "brain_context" not in tool_names
    assert tool_names == {
        "brain_recall",
        "brain_status",
        "brain_recent",
        "brain_turn",
        "brain_rebind_local_session",
    }


def test_mcp_status_stays_truthful_while_stale_worker_uses_current_cli() -> None:
    """An in-place update keeps MCP health stale but preserves H7 availability."""

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-runtime-identity-") as directory:
        package_root = Path(directory) / "package"
        memory_root = Path(directory) / "state" / "shared"
        package_root.mkdir(parents=True)
        memory_root.mkdir(parents=True)
        for name in ("manifest.json", "route-map.json", "capabilities.json", "super-brain-rules.json"):
            (package_root / name).write_bytes((ROOT / name).read_bytes())
        for relative_path in (*runtime_dependency_paths(ROOT), "runtime/brain_cli.py"):
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

        bridged_recent = handle_tool(core, "brain_recent", {})
        assert bridged_recent["isError"] is False, bridged_recent
        assert json.loads(bridged_recent["content"][0]["text"]) == [], bridged_recent


def test_stale_mcp_recent_bridge_preserves_local_workspace_scope() -> None:
    """A fresh CLI child must inherit the resident MCP's cwd for scoped recent."""

    with tempfile.TemporaryDirectory(prefix="super-brain-mcp-recent-scope-") as directory:
        root = Path(directory)
        package_root = root / "package"
        memory_root = root / "state" / "shared"
        workspace_root = root / "project"
        package_root.mkdir(parents=True)
        memory_root.mkdir(parents=True)
        workspace_root.mkdir(parents=True)
        for name in ("manifest.json", "route-map.json", "capabilities.json", "super-brain-rules.json"):
            (package_root / name).write_bytes((ROOT / name).read_bytes())
        for relative_path in (*runtime_dependency_paths(ROOT), "runtime/brain_cli.py"):
            destination = package_root / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((ROOT / relative_path).read_bytes())

        session = "stale-mcp-local-session"
        workspace_key = cwd_workspace_key(workspace_root)
        sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash(session),
            workspaceKey=workspace_key,
        )
        marker = "stale MCP local workspace recent marker"
        (memory_root / "sandglass.txt").write_text(
            f"2026-07-20 09:00:00 | {sender} | [SESSION][VERIFIED] {marker}\n",
            encoding="utf-8",
        )
        registry_path = package_root / "super-brain-rules.json"
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        registry["rules"][0]["revision"] = int(registry["rules"][0]["revision"]) + 1
        registry["payloadHash"] = canonical_hash(
            {key: value for key, value in registry.items() if key != "payloadHash"}
        )
        write_json(registry_path, registry)

        previous_cwd = Path.cwd()
        previous_session = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        os.chdir(workspace_root)
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = session
        try:
            core = BrainCore(package_root, memory_root)
            result = handle_tool(core, "brain_recent", {})
            assert result["isError"] is False, result
            payload = json.loads(result["content"][0]["text"])
            assert [item["text"] for item in payload] == [f"[SESSION][VERIFIED] {marker}"], payload
        finally:
            os.chdir(previous_cwd)
            if previous_session is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_session


def test_runtime_identity_source_projection_cache_is_stamp_aware() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-runtime-source-cache-") as directory:
        core = BrainCore(ROOT, Path(directory) / "shared")
        original_stamps = brain_core_module._runtime_source_stamps(core.package_root)
        assert original_stamps is not None

        with mock.patch.object(
            brain_core_module,
            "load_registry",
            wraps=brain_core_module.load_registry,
        ) as loader:
            first = core.runtime_identity_status(signals=("control_plane_agent",))
            second = core.runtime_identity_status(signals=("control_plane_agent",))
            assert first == second
            # BrainCore.__init__ happened before patching; unchanged source
            # stamps therefore reuse the one cached source registry.
            assert loader.call_count == 1

            changed_stamps = (
                (original_stamps[0][0] + 1, original_stamps[0][1]),
                original_stamps[1],
            )
            with mock.patch.object(
                brain_core_module,
                "_runtime_source_stamps",
                side_effect=[original_stamps, changed_stamps],
            ):
                core.runtime_identity_status()
                core.runtime_identity_status()
            assert loader.call_count == 2

        with mock.patch.object(brain_core_module, "_runtime_source_stamps", return_value=None):
            withheld = core.runtime_identity_status()
        assert withheld["state"] == "withheld"
        assert withheld["code"] == "H7_MCP_RUNTIME_SOURCE_RULES_WITHHELD"


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

    terminal = decide_turn_close(
        {
            **resolution,
            "nextAction": "No further work; the verified task is complete.",
            "currentPhase": "Complete",
            "canonicalPlan": {"itemCount": 8, "completedCount": 8, "pendingCount": 0, "cancelledCount": 0},
            "canResumeParent": False,
        },
        turn_outcome="active_work_progressed",
        user_control="none",
        completion_evidence_present=True,
    )
    assert terminal["decision"] == "pause_with_blocker"
    assert terminal["code"] == "CONTINUATION_POLICY_VERIFIED_TASK_COMPLETE"
    assert terminal["terminalReplyAllowed"] is True

    incomplete = decide_turn_close(
        {
            **resolution,
            "currentPhase": "Complete",
            "canonicalPlan": {"itemCount": 8, "completedCount": 7, "pendingCount": 1, "cancelledCount": 0},
            "canResumeParent": False,
        },
        turn_outcome="active_work_progressed",
        user_control="none",
        completion_evidence_present=True,
    )
    assert incomplete["decision"] == "continue_current_turn"

    serialized = json.dumps([unknown, completed, missing_evidence, partial, paused, blocked, terminal, incomplete], ensure_ascii=False)
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
        local_workspace = "ws-" + hashlib.sha256(
            str(Path.cwd().resolve()).rstrip("/\\").lower().encode("utf-8")
        ).hexdigest()[:24]
        local_sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash("session-local"),
            taskKey=BrainCore._scope_hash("task-local"),
            workspaceKey=local_workspace,
        )
        foreign_sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash("session-foreign"),
            taskKey=BrainCore._scope_hash("task-foreign"),
            workspaceKey="ws-foreign-workspace",
        )
        same_session_foreign_workspace_sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash("session-local"),
            taskKey=BrainCore._scope_hash("task-foreign-workspace"),
            workspaceKey="ws-foreign-workspace",
        )
        (memory_root / "sandglass.txt").write_text(
            "\n".join(
                [
                    f"2026-07-20 09:00:00 | {local_sender} | [SESSION][VERIFIED] assistant route recommendation is local-route",
                    f"2026-07-20 09:01:00 | {foreign_sender} | [SESSION][VERIFIED] assistant route recommendation is foreign-route",
                    f"2026-07-20 09:02:00 | {same_session_foreign_workspace_sender} | [SESSION][VERIFIED] assistant route recommendation is same-session-foreign-workspace",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        original_session = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = "session-local"
        try:
            core = BrainCore(ROOT, memory_root)
            results = core.recall("what did you recommend route?", top_k=3, max_tokens=500, layer="session")
            all_results = core.recall("what did you recommend route?", top_k=3, max_tokens=500, layer="all")
        finally:
            if original_session is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = original_session

        assert len(results) == 1
        assert "local-route" in results[0]["text"]
        assert "foreign-route" not in results[0]["text"]
        assert all("same-session-foreign-workspace" not in item["text"] for item in all_results)
        assert results[0]["evidenceCard"]["senderRole"] == "assistant"
        assert results[0]["evidenceCard"]["provenanceScope"] == "scoped"


def test_session_scope_accepts_current_sid_provenance_form() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-session-sid-scope-") as directory:
        previous = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = "modern-session"
        try:
            core = BrainCore(ROOT, Path(directory) / "shared")
            candidate = Candidate(
                text="[SESSION][VERIFIED] modern session evidence",
                source="fixture",
                source_type="sandglass",
                reason="fixture",
                session_key=core._session_key_from_value("modern-session"),
            )
            assert core._session_scope_allowed(candidate, "modern session evidence", "session") is True
        finally:
            if previous is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous


def test_session_scope_fails_closed_without_current_session_even_for_cross_session_query() -> None:
    """A missing local session is not a wildcard for shared session memory."""

    with tempfile.TemporaryDirectory(prefix="super-brain-session-missing-identity-") as directory:
        previous = os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
        try:
            core = BrainCore(ROOT, Path(directory) / "shared")
            candidate = Candidate(
                text="[SESSION][VERIFIED] foreign session evidence",
                source="fixture",
                source_type="sandglass",
                reason="fixture",
                session_key=BrainCore._scope_hash("foreign-session"),
                workspace_key=core._context_workspace_key(),
            )
            assert core._session_scope_allowed(candidate, "previous session", "all") is False
        finally:
            if previous is not None:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous


def test_session_scope_rejects_explicit_foreign_workspace() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-session-workspace-scope-") as directory:
        previous = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = "modern-session"
        try:
            core = BrainCore(ROOT, Path(directory) / "shared")
            local = Candidate(
                text="[SESSION][VERIFIED] local workspace evidence",
                source="fixture",
                source_type="sandglass",
                reason="fixture",
                session_key=core._session_key_from_value("modern-session"),
                workspace_key=core._context_workspace_key(),
            )
            foreign = Candidate(
                text="[SESSION][VERIFIED] foreign workspace evidence",
                source="fixture",
                source_type="sandglass",
                reason="fixture",
                session_key=core._session_key_from_value("modern-session"),
                workspace_key="ws-foreign-workspace",
            )
            legacy_local = Candidate(
                text="[SESSION][VERIFIED] legacy local workspace evidence",
                source="fixture",
                source_type="sandglass",
                reason="fixture",
                session_key=core._session_key_from_value("modern-session"),
                workspace_key=BrainCore._scope_hash(core._context_workspace_key()),
            )
            assert core._session_scope_allowed(local, "workspace evidence", "session") is True
            assert core._session_scope_allowed(legacy_local, "workspace evidence", "session") is True
            assert core._session_scope_allowed(foreign, "workspace evidence", "session") is False
        finally:
            if previous is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous


def test_session_scope_fails_closed_when_current_workspace_is_unavailable() -> None:
    """A missing cwd scope must not widen session evidence to every workspace."""

    with tempfile.TemporaryDirectory(prefix="super-brain-session-workspace-unavailable-") as directory:
        memory_root = Path(directory) / "shared"
        memory_root.mkdir(parents=True)
        local_session = "session-local"
        sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash(local_session),
            workspaceKey="ws-foreign-workspace",
        )
        marker = "workspace-unavailable-session-marker"
        (memory_root / "sandglass.txt").write_text(
            f"2026-07-20 09:00:00 | {sender} | [SESSION][VERIFIED] {marker}\n",
            encoding="utf-8",
        )
        previous = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = local_session
        try:
            core = BrainCore(ROOT, memory_root)
            core._context_workspace_key = lambda: ""
            candidate = Candidate(
                text=f"[SESSION][VERIFIED] {marker}",
                source="fixture",
                source_type="sandglass",
                reason="fixture",
                session_key=BrainCore._scope_hash(local_session),
                workspace_key="ws-foreign-workspace",
            )

            assert core._session_scope_allowed(candidate, marker, "all") is False
            assert core.recall(marker, top_k=1, max_tokens=300, layer="all") == []
            assert core._recent_sandglass_rows(
                5,
                session_keys=core._session_provenance_keys(core._context_session_key()),
                workspace_keys=set(),
            ) == []
            assert core.recent(5, session_key=core._context_session_key()) == []
        finally:
            if previous is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous


def test_brain_recent_isolated_to_current_session_and_fail_closed_without_one() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-recent-session-") as directory:
        memory_root = Path(directory) / "shared"
        memory_root.mkdir(parents=True)
        local_session = "session-local"
        foreign_session = "session-foreign"
        local_workspace = "ws-" + hashlib.sha256(
            str(Path.cwd().resolve()).rstrip("/\\").lower().encode("utf-8")
        ).hexdigest()[:24]
        local_sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash(local_session),
            workspaceKey=local_workspace,
        )
        foreign_sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash(foreign_session),
            workspaceKey=local_workspace,
        )
        same_session_foreign_workspace_sender = provenance_sender(
            "assistant",
            sessionKey=BrainCore._scope_hash(local_session),
            workspaceKey="ws-foreign-workspace",
        )
        (memory_root / "sandglass.txt").write_text(
            "\n".join(
                [
                    "2026-07-20 09:00:00 | user | legacy tail must stay hidden",
                    f"2026-07-20 09:00:30 | {local_sender} | [SESSION][VERIFIED] session-only legacy marker",
                    f"2026-07-20 09:01:00 | {local_sender} | [SESSION][VERIFIED] local recent marker",
                    f"2026-07-20 09:02:00 | {foreign_sender} | [SESSION][VERIFIED] foreign recent marker",
                    f"2026-07-20 09:03:00 | {same_session_foreign_workspace_sender} | [SESSION][VERIFIED] same session foreign workspace recent marker",
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        original_session = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = local_session
        try:
            core = BrainCore(ROOT, memory_root)
            scoped = core.recent(5, session_key=core._context_session_key())
            assert [item["text"] for item in scoped] == ["[SESSION][VERIFIED] local recent marker"]
            # A matching session marker without a workspace marker is legacy
            # compatibility data, not proof for the current workspace.
            assert all("session-only legacy marker" not in item["text"] for item in scoped)
            # ``recent`` is current-session only.  An internal caller cannot
            # repurpose its optional scope parameter to read a foreign tail.
            assert core.recent(5, session_key=foreign_session) == []

            mcp_result = handle_tool(core, "brain_recent", {})
            mcp_payload = json.loads(mcp_result["content"][0]["text"])
            assert [item["text"] for item in mcp_payload] == ["[SESSION][VERIFIED] local recent marker"]

            # The MCP path must never turn a missing local identity into a
            # global tail read, even when the shared file has foreign records.
            os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            assert core.recent(5, session_key=core._context_session_key()) == []

            # Ordinary CLI compatibility remains available only when the
            # caller intentionally omits the scope argument altogether.
            unscoped = core.recent(5)
            assert len(unscoped) == 5
        finally:
            if original_session is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = original_session


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


def test_recall_json_projection_caches_reuse_and_invalidate_on_source_stamp() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-recall-json-cache-") as directory:
        workspace = Path(directory)
        self_model_path = workspace / "self-model.json"
        profile_path = workspace / "profile-card.json"
        experience_path = workspace / "experiences" / "cache-fixture.json"

        write_json(
            self_model_path,
            {
                "schema": "super-brain.self-model.v1",
                "packageVersion": package_version(),
                "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "evidenceStatus": "verified",
                "identity": "cache identity",
                "role": "cache role",
                "evidence": ["cache-fixture"],
                "rawPromptStored": False,
            },
        )
        write_json(
            profile_path,
            {
                "evidenceCards": [
                    {
                        "claim": "cache marker preference",
                    }
                ]
            },
        )
        write_json(
            experience_path,
            {
                "id": "cache-fixture",
                "title": "cache marker experience",
                "status": "verified",
                "recallQuery": "cache marker",
                "updatedAt": "2026-08-23 12:00:00",
                "evidence": ["cache-fixture"],
            },
        )
        core = make_core(workspace)
        original_read_json = brain_core_module._read_json

        with mock.patch.object(
            brain_core_module,
            "_read_json",
            wraps=original_read_json,
        ) as read_json:
            first_self = core._self_model_candidates("who are you")
            second_self = core._self_model_candidates("who are you")
            assert read_json.call_count == 1
            assert first_self == second_self

            write_json(
                self_model_path,
                {
                    "schema": "super-brain.self-model.v1",
                    "packageVersion": package_version(),
                    "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                    "evidenceStatus": "verified",
                    "identity": "cache identity updated",
                    "role": "cache role updated",
                    "evidence": ["cache-fixture"],
                    "rawPromptStored": False,
                },
            )
            updated_self = core._self_model_candidates("who are you")
            assert read_json.call_count == 2
            assert "cache identity updated" in updated_self[0].text

            first_profile = core._profile_card_candidates("my preference cache marker", {"cache", "marker"})
            second_profile = core._profile_card_candidates("my preference cache marker", {"cache", "marker"})
            assert read_json.call_count == 3
            assert first_profile == second_profile

            write_json(
                profile_path,
                {
                    "evidenceCards": [
                        {
                            "claim": "cache marker preference updated",
                        }
                    ]
                },
            )
            updated_profile = core._profile_card_candidates("my preference cache marker", {"cache", "marker"})
            assert read_json.call_count == 4
            assert updated_profile[0].text == "cache marker preference updated"

            first_experience = core._experience_candidates("cache marker", {"cache", "marker"})
            second_experience = core._experience_candidates("cache marker", {"cache", "marker"})
            assert read_json.call_count == 5
            assert first_experience == second_experience

            write_json(
                experience_path,
                {
                    "id": "cache-fixture",
                    "title": "cache marker experience updated",
                    "status": "verified",
                    "recallQuery": "cache marker",
                    "updatedAt": "2026-08-23 12:00:00",
                    "evidence": ["cache-fixture"],
                },
            )
            updated_experience = core._experience_candidates("cache marker", {"cache", "marker"})
            assert read_json.call_count == 6
            assert "cache marker experience updated" in updated_experience[0].text

            experience_path.unlink()
            assert core._experience_candidates("cache marker", {"cache", "marker"}) == []
            assert core._experience_json_cache == {}


def test_newer_task_context_beats_an_older_matching_checkpoint() -> None:
    with tempfile.TemporaryDirectory(prefix="super-brain-stale-checkpoint-") as directory:
        state_root = Path(directory)
        memory_root = state_root / "shared"
        workspace = state_root / "workspace"
        memory_root.mkdir(parents=True, exist_ok=True)
        workspace_key = cwd_workspace_key(workspace)
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
        previous_thread = os.environ.get("SUPER_BRAIN_LOCAL_SESSION_ID")
        previous_session = os.environ.pop("SUPER_BRAIN_SESSION_ID", None)
        previous_cwd = Path.cwd()
        os.chdir(workspace)
        os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = thread_id
        try:
            core = BrainCore(ROOT, memory_root)
            results = core.recall("current task next step", top_k=1, max_tokens=500)
        finally:
            os.chdir(previous_cwd)
            if previous_thread is None:
                os.environ.pop("SUPER_BRAIN_LOCAL_SESSION_ID", None)
            else:
                os.environ["SUPER_BRAIN_LOCAL_SESSION_ID"] = previous_thread
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
            "brain_turn_metadata_ignored",
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


def test_h7_control_plane_is_host_model_neutral() -> None:
    """Production H7 control paths must not choose a host model/provider."""

    production_paths = [
        ROOT / "runtime" / "brain_core.py",
        ROOT / "runtime" / "brain_mcp.py",
        ROOT / "runtime" / "brain_cli.py",
        ROOT / "runtime" / "turn_runtime.py",
        ROOT / "runtime" / "turn_close_dispatcher.py",
        ROOT / "scripts" / "execution-contract.ps1",
        ROOT / "scripts" / "common.ps1",
        ROOT / "scripts" / "first-load-bootstrap.ps1",
        ROOT / "scripts" / "install-runtime.ps1",
        ROOT / "scripts" / "startup-check.ps1",
    ]
    forbidden = re.compile(r"gpt-\d|judgemodel|modelid|approval[_ -]?provider", re.IGNORECASE)
    hits = {
        path.relative_to(ROOT).as_posix(): forbidden.findall(path.read_text(encoding="utf-8"))
        for path in production_paths
        if forbidden.search(path.read_text(encoding="utf-8"))
    }
    assert not hits, hits


if __name__ == "__main__":
    test_adaptive_sparse_recall_uses_fts_before_heavier_backends()
    test_adaptive_sparse_recall_uses_bounded_scan_after_fts_miss()
    test_adaptive_sparse_recall_reuses_one_read_only_sqlite_connection()
    test_adaptive_sparse_recall_retries_variants_after_transient_batch_connect_failure()
    test_recall_lexical_match_cache_is_call_scoped_and_score_equivalent()
    test_recall_scan_and_recent_fallback_share_request_local_sandglass_read()
    test_recall_sandglass_reuse_requires_complete_unchanged_scan()
    test_brain_core_keeps_memory_roots_process_isolated()
    test_brain_core_projects_retired_agent_and_group_roots_to_shared()
    test_runtime_layout_beats_a_stale_nexsandbase_environment_root()
    test_execution_contract_context_filters_misprojected_completed_terminal_contracts()
    test_contract_screening_cache_never_authorizes_a_replaced_contract()
    test_context_contract_reader_rejects_path_like_scope_values()
    test_current_task_recall_rejects_stale_global_checkpoint()
    test_current_workspace_scope_uses_cwd_not_derived_status_card()
    test_terminal_finalization_context_is_opt_in_unique_and_never_auto_wakes()
    test_terminal_finalization_allows_missing_formal_closeout_with_existing_v4_receipt()
    test_execution_contract_context_requires_current_native_intent_receipt()
    test_local_context_uses_cwd_scope_and_stays_read_only()
    test_context_recovers_from_a_lagging_hot_index_after_a_committed_transition()
    test_turn_close_policy_requires_current_turn_attestation_and_never_echoes_input()
    test_mcp_does_not_expose_untrusted_host_context()
    test_stale_mcp_recent_bridge_preserves_local_workspace_scope()
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
    test_session_scope_accepts_current_sid_provenance_form()
    test_session_scope_fails_closed_without_current_session_even_for_cross_session_query()
    test_session_scope_fails_closed_when_current_workspace_is_unavailable()
    test_missing_self_model_snapshot_is_explicitly_unknown()
    test_fresh_evidence_backed_self_model_is_verified()
    test_shared_memory_root_uses_its_control_plane_workspace_for_self_model()
    test_status_projects_current_h7_retired_transport_guard()
    test_stale_self_model_snapshot_downgrades_to_unknown()
    test_recall_json_projection_caches_are_stamp_aware_and_fail_closed()
    test_recall_json_projection_caches_reuse_and_invalidate_on_source_stamp()
    test_newer_task_context_beats_an_older_matching_checkpoint()
    test_rejected_memory_is_not_default_recall_evidence()
    test_stale_status_snapshot_cannot_beat_live_manifest_version()
    test_live_status_snapshot_wins_combined_version_and_status_query()
    test_runtime_identity_source_projection_cache_is_stamp_aware()
    test_session_snippet_selects_the_turn_that_contains_the_answer()
    test_mcp_only_probe_replays_the_narrow_stdio_contract()
    test_retired_prompt_hook_never_observes_or_mutates_state()
    test_h7_progress_checkpoint_refuses_truncation_without_a_prompt_packet()
    test_h7_control_plane_is_host_model_neutral()
    print("RUNTIME_BRAIN_REGRESSION_OK")
