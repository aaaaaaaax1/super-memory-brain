$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'Super Brain repair regression guards' {
  It 'routes every required completion audit role explicitly' {
    $json = & (Join-Path $Root 'scripts\smart-next.ps1') -Text 'completion skill audit verify test regression before completion' -Json
    if ($LASTEXITCODE -ne 0) { throw 'smart-next completion audit failed' }
    $result = $json | ConvertFrom-Json
    $expected = @('pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair')
    $result.completionSkillAudit.auditRequested | Should Be $true
    @($result.completionSkillAudit.missingRoles).Count | Should Be 0
    foreach ($role in $expected) { @($result.completionSkillAudit.presentRoles) -contains $role | Should Be $true }
  }

  It 'keeps status snapshots aligned with dashboard and latest verification' {
    $writer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\status-snapshot-writer.ps1')
    $verify = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\verify-package.ps1')
    $writer.Contains('ok = ($dashboard.ok -eq $true)') | Should Be $true
    $writer.Contains('verifyCheckedAt') | Should Be $true
    $verify.Contains('verify-package final status') | Should Be $true
    $verify.Contains('final status snapshot matches latest verification') | Should Be $true
  }

  It 'persists hot refresh apply status even in Json mode' {
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\hot-refresh-skills.ps1')
    $writeStatusStart = $text.IndexOf('function Write-Status')
    $writeStatusEnd = $text.IndexOf('try {', $writeStatusStart)
    $writeStatus = $text.Substring($writeStatusStart, $writeStatusEnd - $writeStatusStart)
    $writeIndex = $writeStatus.IndexOf('Write-JsonUtf8NoBom $StatusPath $Status 8')
    $jsonIndex = $writeStatus.IndexOf('if ($Json)')
    $writeIndex -ge 0 | Should Be $true
    $jsonIndex -gt $writeIndex | Should Be $true
    $text.Contains('Write-JsonUtf8NoBom $StatusPath $status 8') | Should Be $true
  }

  It 'tracks route regression and install UI report writes at correct tiers' {
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'manifest.json') | ConvertFrom-Json
    @($manifest.scripts) -contains 'route-regression.ps1' | Should Be $true
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'route-regression.ps1' }).tier | Should Be 'T0'
    ($manifest.scriptMetadata | Where-Object { $_.path -eq 'install-ui-regression.ps1' }).tier | Should Be 'T1'
  }

  It 'keeps successful decision search from leaking an earlier exit code' {
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\decision-search.ps1')
    $text.TrimEnd().EndsWith('exit 0') | Should Be $true
  }

  It 'keeps completion guard input binding and version-owned recall fixtures current' {
    $guard = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\completion-guard.ps1')
    $bump = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\version-bump.ps1')
    $guard.Contains("-Text 'completion skill audit verify test regression before completion'") | Should Be $true
    $bump.Contains("'README.md'") | Should Be $true
    $bump.Contains("'tests\memory-recall-tests.json'") | Should Be $true
    $bump.Contains("[regex]::Escape(`$Supersedes)") | Should Be $true
    $bump.Contains("Replace(`$Text, `$Replacement, 1)") | Should Be $true
    $bump.Contains("'`${1}' + `$Version + '`${2}'") | Should Be $true
    $bump.Contains("'(?s)(## '") | Should Be $true
    $bump.Contains("'`${1} [CURRENT][VERIFIED]'") | Should Be $true
    @($bump.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should Be 0
  }

  It 'initializes completion guard workspace before selecting the verified task' {
    $verify = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\verify-package.ps1')
    $workspaceInit = '$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) ''workspace'''
    $taskLookup = '$lastTaskForGuardPath = Join-Path $workspace ''last-task-verification.json'''
    $verify.IndexOf($workspaceInit) -ge 0 | Should Be $true
    $verify.IndexOf($taskLookup) -gt $verify.IndexOf($workspaceInit) | Should Be $true
    $verify.Contains('completion guard failed taskId=') | Should Be $true
  }

  It 'runs the CI completion guard against the last verified task' {
    $ci = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\ci.ps1')
    foreach ($marker in @('last-task-verification.json','$completionGuardArgs','-TaskId','completion_guard_task_lookup_failed')) { $ci.Contains($marker) | Should Be $true }
    $ci.IndexOf('$completionGuardArgs') -lt $ci.IndexOf("Run-Step 'completion-guard'") | Should Be $true
  }

  It 'keeps bounded memory lifecycle policy and admission enforcement current' {
    $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'memory-policy.json') | ConvertFrom-Json
    $policy.lifecycle.enabled | Should Be $true
    $policy.lifecycle.maxLines | Should Be 240
    $policy.lifecycle.maxChars | Should Be 180000
    $policy.lifecycle.warnAt | Should Be 0.8
    $health = (& (Join-Path $Root 'scripts\memory-health.ps1') -Json | ConvertFrom-Json)
    $health.memoryLifecycle.status | Should Be 'ok'
    $health.memoryLifecycle.currentLines | Should BeLessThan $health.memoryLifecycle.maxLines
    $health.memoryLifecycle.currentChars | Should BeLessThan $health.memoryLifecycle.maxChars
    $write = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\write-memory.ps1')
    foreach ($marker in @('Get-SuperBrainMemoryBudget','MEMORY_BUDGET_CHECK_FAILED','memory budget blocked')) { $write.Contains($marker) | Should Be $true }
  }

  It 'surfaces bounded memory pressure through hygiene and optimization advice' {
    $hygiene = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\auto-hygiene-runner.ps1')
    $advisor = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\optimize-advisor.ps1')
    foreach ($marker in @('Get-SuperBrainMemoryLifecyclePolicy','stale_history','memoryLifecycle','budgetOverflow','Invoke-RebuildMemoryIndexes','lineMap','indexRebuild','derivedIndexes')) { $hygiene.Contains($marker) | Should Be $true }
    foreach ($marker in @('memory_budget_exceeded','memory_budget_near_limit','memoryBudgetStatus','memory-health.ps1')) { $advisor.Contains($marker) | Should Be $true }
  }

  It 'enumerates Sandglass JSON rows before candidate parsing and keeps profile recall narrow' {
    $recall = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\recall-search.ps1')
    $profile = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\profile-card.ps1')
    foreach($marker in @('$parsedSearch = $result | ConvertFrom-Json','foreach ($item in @($parsedSearch))','$parsedRecent = $recentResult | ConvertFrom-Json','foreach ($item in @($parsedRecent))')) { $recall.Contains($marker) | Should Be $true }
    $profile.Contains("'profile preference'") | Should Be $true
    $profile.Contains('$parsedRecall =') | Should Be $true
    $profile.Contains('PreferredQuery') | Should Be $true
    $learn = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\learn-memory.ps1')
    $learn.Contains('-PreferredQuery $Title') | Should Be $true
  }

  It 'keeps NexSandglass recent windows correct across long line chunk boundaries' {
    $memoryScripts = Join-Path $Root 'memory\shared\scripts'
    $python = @'
import json
import os
import tempfile
import sandglass_vault

fd, path = tempfile.mkstemp(prefix="sandglass-recent-", suffix=".txt")
os.close(fd)
try:
    with open(path, "w", encoding="utf-8") as handle:
        for index in range(1, 25):
            payload = ("x" * 700) + " record-%02d" % index
            handle.write("2026-07-13 00:00:%02d | user | %s\n" % (index, payload))
    sandglass_vault._SANDGLASS = path
    rows = sandglass_vault.recent(16)
    print(json.dumps({"count": len(rows), "first": rows[0][2][-9:], "last": rows[-1][2][-9:]}))
finally:
    os.remove(path)
'@
    $oldHome = $env:NEXSANDBASE_HOME
    $oldPythonPath = $env:PYTHONPATH
    try {
      $env:NEXSANDBASE_HOME = Join-Path $Root 'memory\shared'
      $env:PYTHONPATH = $memoryScripts
      $result = ($python | python -) | ConvertFrom-Json
      $LASTEXITCODE | Should Be 0
      $result.count | Should Be 16
      $result.first | Should Be 'record-09'
      $result.last | Should Be 'record-24'
    } finally {
      $env:NEXSANDBASE_HOME = $oldHome
      $env:PYTHONPATH = $oldPythonPath
    }
  }

  It 'rebuilds Sandglass derived indexes after physical line removal' {
    $tempMemory = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-index-' + [guid]::NewGuid().ToString('N'))
    $tempScripts = Join-Path $tempMemory 'scripts'
    New-Item -ItemType Directory -Force -Path $tempScripts | Out-Null
    $vendor = Join-Path $Root 'vendor\NexSandglass-Agent-DedicatedMemory'
    foreach ($file in @('sandglass_paths.py','sandglass_vault.py','sandglass_sqlite.py','shadow_sand.py','sandglass_archive.py')) {
      Copy-Item -LiteralPath (Join-Path $vendor $file) -Destination (Join-Path $tempScripts $file) -Force
    }
    $python = @'
import json
import os

from sandglass_archive import rebuild_indexes
from sandglass_sqlite import search as sqlite_search
from sandglass_vault import rebuild_index
from shadow_sand import _get_conn, shadow_feedback, shadow_index, shadow_search

memory_root = os.environ["NEXSANDBASE_HOME"]
memory_path = os.path.join(memory_root, "sandglass.txt")
index_path = os.path.join(memory_root, "sandglass.idx")
old_lines = [
    "2026-07-13 00:00:01 | user | alpha anchor",
    "2026-07-13 00:00:02 | user | removed record",
    "2026-07-13 00:00:03 | user | beta anchor",
    "2026-07-13 00:00:04 | user | Test Device stable",
]
with open(memory_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(old_lines) + "\n")

for line_number, text in enumerate(("alpha", "removed", "beta", "Test Device"), 1):
    shadow_index(text, category="decision", tags=text, line_num=line_number)
shadow_feedback(1, True)
connection = _get_conn()
connection.execute("CREATE TABLE wthread_triples (id INTEGER PRIMARY KEY AUTOINCREMENT, source_line INTEGER)")
connection.execute("INSERT INTO wthread_triples (source_line) VALUES (3)")
connection.execute("INSERT INTO wthread_triples (source_line) VALUES (2)")
connection.commit()
rebuild_index()

new_lines = [old_lines[0], old_lines[2], old_lines[3]]
with open(memory_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(new_lines) + "\n")
report = rebuild_indexes({"1": 1, "3": 2, "4": 3})
sqlite_beta = sqlite_search("beta", 10)
shadow_beta = shadow_search("beta", 10)
shadow_removed = shadow_search("removed", 10)
with open(index_path, "r", encoding="utf-8") as handle:
    index_lines = [line.strip() for line in handle if ":" in line and not line.startswith("#")]
index_max = max((int(value) for line in index_lines for value in line.split(":", 1)[1].split(",") if value), default=0)
trust_helpful = _get_conn().execute("SELECT helpful FROM trust WHERE line_num = 1").fetchone()[0]
graph_lines = [row[0] for row in _get_conn().execute("SELECT source_line FROM wthread_triples ORDER BY id").fetchall()]
print(json.dumps({
    "reportOk": report["ok"],
    "sqliteRows": report["sqliteFts"]["rows"],
    "sqliteBetaLines": [row[0] for row in sqlite_beta],
    "shadowBetaLines": [row[1] for row in shadow_beta],
    "shadowRemovedCount": len(shadow_removed),
    "indexMax": index_max,
    "trustHelpful": trust_helpful,
    "graphLines": graph_lines,
}, ensure_ascii=False))
'@
    $oldHome = $env:NEXSANDBASE_HOME
    $oldPythonPath = $env:PYTHONPATH
    try {
      $env:NEXSANDBASE_HOME = $tempMemory
      $env:PYTHONPATH = $tempScripts
      $result = ($python | python -) | ConvertFrom-Json
      $LASTEXITCODE | Should Be 0
      $result.reportOk | Should Be $true
      $result.sqliteRows | Should Be 3
      (@($result.sqliteBetaLines) -contains 2) | Should Be $true
      (@($result.shadowBetaLines) -contains 2) | Should Be $true
      $result.shadowRemovedCount | Should Be 0
      $result.indexMax | Should BeLessThan 4
      $result.trustHelpful | Should Be 1
      @($result.graphLines).Count | Should Be 1
      (@($result.graphLines) -contains 2) | Should Be $true
    } finally {
      $env:NEXSANDBASE_HOME = $oldHome
      $env:PYTHONPATH = $oldPythonPath
      Remove-Item -LiteralPath $tempMemory -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'routes standalone historical references consistently' {
    $zhLastTask = -join (@(19978,27425,30340,20219,21153) | ForEach-Object { [char]$_ })
    $zhAnotherSession = -join (@(21478,19968,20010,20250,35805) | ForEach-Object { [char]$_ })
    foreach ($query in @('continue previous task from last time','previous session','remember last task',$zhLastTask,$zhAnotherSession)) {
      $json = & (Join-Path $Root 'scripts\intent-router.ps1') -Text $query -Json
      if ($LASTEXITCODE -ne 0) { throw "intent-router failed for $query" }
      ($json | ConvertFrom-Json).intent | Should Be 'historical_recovery'
    }
  }

  It 'routes natural Super Brain refresh wording to maintenance' {
    foreach ($query in @('refresh Super Brain','hot-refresh Super Brain')) {
      $json = & (Join-Path $Root 'scripts\intent-router.ps1') -Text $query -Json
      if ($LASTEXITCODE -ne 0) { throw "intent-router failed for $query" }
      ($json | ConvertFrom-Json).intent | Should Be 'maintenance_hot_refresh'
    }
  }

  It 'does not fabricate unknown or superseded decisions' {
    $unknown = @((& (Join-Path $Root 'scripts\decision-search.ps1') -Key 'nonexistent-decision-repair-regression-7f3a9c2e' -CurrentOnly -Relation decides -Json | ConvertFrom-Json) | Where-Object { $_ -ne $null })
    @($unknown).Count | Should Be 0

    $stale = @((& (Join-Path $Root 'scripts\decision-search.ps1') -Key 'codex-g1-first-line-display-rule' -CurrentOnly -Relation decides -Json | ConvertFrom-Json) | Where-Object { $_ -ne $null })
    $current = @((& (Join-Path $Root 'scripts\decision-search.ps1') -Key 'codex-g1-first-line-display-rule-v2' -CurrentOnly -Relation decides -Json | ConvertFrom-Json) | Where-Object { $_ -ne $null })
    @($stale).Count | Should Be 0
    @($current).Count | Should Be 1
    ([string]$current[0].tags).Contains('[CURRENT]') | Should Be $true
    ([string]$current[0].tags).Contains('[VERIFIED]') | Should Be $true
    $current[0].adr.superseded | Should Be $false
  }

  It 'hard-stops historical recovery when no relevant evidence exists' {
    $query = 'continue previous task about nonexistent-nebula-archive-7f3a9c2e'
    $json = & (Join-Path $Root 'scripts\session-restore.ps1') -Query $query -Json
    if ($LASTEXITCODE -ne 0) { throw 'session-restore missing-evidence case failed' }
    $result = $json | ConvertFrom-Json
    $result.recallTriggered | Should Be $true
    $result.routeIntent | Should Be 'historical_recovery'
    $result.historicalEvidenceStatus | Should Be 'missing'
    $result.evidenceStatus.claimAllowed | Should Be $false
    @($result.evidenceCards).Count | Should Be 0
    ([string]$result.nextAction).Contains('do not infer') | Should Be $true
  }

  It 'restores only current verified relevant evidence for a known historical topic' {
    $json = & (Join-Path $Root 'scripts\session-restore.ps1') -Query 'continue previous task agent subagent roadmap' -TopK 4 -MaxTokens 900 -Json
    if ($LASTEXITCODE -ne 0) { throw 'session-restore known-history case failed' }
    $result = $json | ConvertFrom-Json
    $result.historicalEvidenceStatus | Should Be 'found'
    $result.evidenceStatus.claimAllowed | Should Be $true
    @($result.evidenceCards).Count -gt 0 | Should Be $true
    foreach ($card in @($result.evidenceCards)) {
      @($card.tags) -contains '[CURRENT]' | Should Be $true
      @($card.tags) -contains '[VERIFIED]' | Should Be $true
      $card.relevanceStatus | Should Be 'matched'
    }
  }

  It 'keeps ordinary continue on the light current-session path' {
    $json = & (Join-Path $Root 'scripts\session-restore.ps1') -Query 'continue' -Json
    if ($LASTEXITCODE -ne 0) { throw 'session-restore current continuation failed' }
    $result = $json | ConvertFrom-Json
    $result.recallTriggered | Should Be $false
    $result.historicalEvidenceStatus | Should Be 'not_requested'
  }

  It 'blocks unsupported optimal engineering decisions' {
    $raw = @(& (Join-Path $Root 'scripts\engineering-decision-gate.ps1') -Action Create -TaskId 'pester-engineering-unsupported-optimal' -Problem 'choose storage' -PainPoint 'write latency exceeds budget' -Objective 'select the optimal store' -Facts @('writes are slow') -FactEvidence @() -RootCauseStatus hypothesis -RootCause 'the current database is slow' -Options @('replace database') -SelectedOption 'replace database' -ClaimsOptimal -Json 2>$null)
    $exitCode = $LASTEXITCODE
    $result = (($raw -join "`n") | ConvertFrom-Json)
    $exitCode | Should Be 1
    $result.ok | Should Be $false
    @($result.gaps.code) -contains 'fact_without_evidence' | Should Be $true
    @($result.gaps.code) -contains 'unsupported_optimal_claim' | Should Be $true
  }

  It 'requires a discriminating test for a root cause hypothesis' {
    $raw = @(& (Join-Path $Root 'scripts\engineering-decision-gate.ps1') -Action Create -TaskId 'pester-engineering-root-cause-hypothesis' -Problem 'intermittent timeout' -PainPoint 'requests fail unpredictably' -Objective 'restore request reliability' -Facts @('timeouts occur under load') -FactEvidence @('load-test request log') -RootCauseStatus hypothesis -RootCause 'connection pool exhaustion' -Constraints @('no downtime') -Options @('increase pool','instrument pool') -Tradeoffs @('may mask a leak','adds evidence before mutation') -Criteria @('diagnostic certainty') -SelectedOption 'instrument pool' -ExecutionSteps @('instrument pool') -StepInputs @('service metrics') -StepOutputs @('pool trace') -StepAcceptance @('trace captures saturation') -StepStopConditions @('instrumentation changes behavior') -AcceptanceCriteria @('cause is discriminated') -Risks @('small observability overhead') -Json 2>$null)
    $exitCode = $LASTEXITCODE
    $result = (($raw -join "`n") | ConvertFrom-Json)
    $exitCode | Should Be 1
    $result.ok | Should Be $false
    @($result.gaps.code) -contains 'untested_root_cause_hypothesis' | Should Be $true
  }

  It 'admits a fully grounded engineering decision' {
    $raw = @(& (Join-Path $Root 'scripts\engineering-decision-gate.ps1') -Action Create -TaskId 'pester-engineering-valid' -Problem 'recall latency exceeds the accepted continuation budget and causes repeated operator delay across sessions' -PainPoint 'slow recall delays continuation' -Objective 'minimize p95 latency without reducing accuracy' -Facts @('p95 is 900 ms','index lookup is 700 ms') -FactEvidence @('benchmark run','trace sample 42') -Assumptions @('compaction may reduce lookup time') -RootCauseStatus verified -RootCause 'index lookup dominates p95' -RootCauseEvidence 'trace sample 42 attributes 700 ms to index lookup' -Constraints @('preserve recall accuracy','no new service') -Options @('compact existing index','add remote cache') -Tradeoffs @('low complexity; maintenance window required','lower warm latency; adds network dependency') -Criteria @('p95 latency','accuracy','operational complexity') -SelectedOption 'compact existing index' -DecisionClaim 'recommended under current evidence' -ExecutionSteps @('capture baseline','compact index','rerun benchmark') -StepInputs @('current benchmark','baseline and index','compacted index') -StepOutputs @('baseline report','compacted index','comparison report') -StepAcceptance @('p95 and accuracy recorded','integrity check passes','p95 improves and accuracy is unchanged') -StepStopConditions @('benchmark invalid','integrity check fails','accuracy regresses') -AcceptanceCriteria @('p95 below 700 ms','no accuracy regression') -Risks @('maintenance window may delay writes') -Json)
    $exitCode = $LASTEXITCODE
    $result = (($raw -join "`n") | ConvertFrom-Json)
    $exitCode | Should Be 0
    $result.ok | Should Be $true
    @($result.gaps).Count | Should Be 0
    $result.epistemicGrounding.factsSupported | Should Be $true
    @($result.executionChain).Count | Should Be 3
  }

  It 'keeps long task-scoped causal evidence paths writable on Windows' {
    $raw = @(& (Join-Path $Root 'scripts\causal-change-plan.ps1') -Action Create -TaskId 'pester-long-causal-evidence-path' -ObservedProblem 'engineering conclusions can exceed current evidence and create repeated downstream decision rework across long-running sessions' -RootCause 'the evidence contract was incomplete' -KnownFacts @('the package uses atomic temporary files') -ProposedChange 'keep a short readable slug plus hash identity' -ExpectedOptimization 'task-scoped evidence remains writable under legacy Windows path limits' -VerificationMethod 'create the plan and verify its path exists' -Risks @('shorter slug carries less title text') -Json)
    $exitCode = $LASTEXITCODE
    $result = (($raw -join "`n") | ConvertFrom-Json)
    $exitCode | Should Be 0
    $result.ok | Should Be $true
    Test-Path -LiteralPath $result.path | Should Be $true
  }

  It 'allows a tested hypothesis plan before mutation but blocks completion without test evidence' {
    $query = 'debug intermittent timeout root cause'
    $null = & (Join-Path $Root 'scripts\cognitive-preflight.ps1') -Query $query -Json
    $null = & (Join-Path $Root 'scripts\engineering-decision-gate.ps1') -Action Create -TaskId 'pester-engineering-phase-gate' -Problem 'intermittent timeout' -PainPoint 'requests fail unpredictably' -Objective 'identify and remove timeout cause' -Facts @('timeouts occur under load') -FactEvidence @('load-test request log') -Unknowns @('pool saturation is not yet observed') -CriticalUnknowns @('pool saturation is not yet observed') -RootCauseStatus hypothesis -RootCause 'connection pool exhaustion' -DiscriminatingTest 'capture pool occupancy during the same load test' -Constraints @('no production downtime') -Options @('increase pool','instrument pool first') -Tradeoffs @('fast mitigation but may mask leak','slower change but discriminates cause') -Criteria @('causal certainty','risk') -SelectedOption 'instrument pool first' -DecisionClaim 'recommended under current evidence' -ExecutionSteps @('instrument pool','repeat load test') -StepInputs @('service metrics','instrumented service') -StepOutputs @('pool telemetry','correlated trace') -StepAcceptance @('telemetry records occupancy','trace distinguishes saturation') -StepStopConditions @('instrumentation changes behavior','test load differs from baseline') -AcceptanceCriteria @('root cause is discriminated') -Risks @('small observability overhead') -Json
    $LASTEXITCODE | Should Be 0

    $beforeMutationRaw = @(& (Join-Path $Root 'scripts\cognitive-enforce.ps1') -Query $query -TaskId 'pester-engineering-phase-gate' -Phase BeforeMutation -Json)
    $beforeMutationCode = $LASTEXITCODE
    $beforeMutation = (($beforeMutationRaw -join "`n") | ConvertFrom-Json)
    $beforeMutationCode | Should Be 0
    $beforeMutation.ok | Should Be $true

    $beforeCompletionRaw = @(& (Join-Path $Root 'scripts\cognitive-enforce.ps1') -Query $query -TaskId 'pester-engineering-phase-gate' -Phase BeforeCompletion -Json 2>$null)
    $beforeCompletionCode = $LASTEXITCODE
    $beforeCompletion = (($beforeCompletionRaw -join "`n") | ConvertFrom-Json)
    $beforeCompletionCode | Should Be 1
    $beforeCompletion.ok | Should Be $false
    $beforeCompletion.engineeringJudgment.completionEvidenceOk | Should Be $false
    @($beforeCompletion.violations) -contains 'engineering-decision-gate' | Should Be $true
  }

  It 'activates engineering judgment for engineering work but not greetings' {
    $hello = (& (Join-Path $Root 'scripts\smart-next.ps1') -Text 'hello' -Json | ConvertFrom-Json)
    $hello.engineeringJudgment.required | Should Be $false
    foreach ($query in @('fix intermittent API failure','optimize memory recall latency','architecture decision for task evidence')) {
      $result = (& (Join-Path $Root 'scripts\smart-next.ps1') -Text $query -Json | ConvertFrom-Json)
      $result.engineeringJudgment.required | Should Be $true
      $result.engineeringJudgment.decisionGate | Should Be 'engineering-decision-gate.ps1'
    }
  }
}
