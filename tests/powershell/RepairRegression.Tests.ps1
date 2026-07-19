$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Describe 'Super Brain repair regression guards' {
  It 'keeps first-load bootstrap able to detect and repair the formal MCP binding' {
    $bootstrap = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\first-load-bootstrap.ps1')
    foreach ($marker in @('super-brain.first-load-bootstrap.v1','-RepairMcp','mcpBindingOk','memory-root.txt','rawPromptStored = $false','needsNewTask')) { $bootstrap.Contains($marker) | Should Be $true }
  }

  It 'isolates Codex home during runtime registration and rejects mismatched roots' {
    $runtime = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\install-runtime.ps1')
    foreach ($marker in @('$env:CODEX_HOME = $CodexHome','MCP_BINDING_MISMATCH','Assert-McpBinding','NEXSANDBASE_HOME')) { $runtime.Contains($marker) | Should Be $true }
  }

  It 'makes bootstrap the single non-interactive install orchestrator' {
    $bootstrap = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\bootstrap.ps1')
    foreach ($marker in @('one-click-install','first-load-bootstrap.ps1','verify-package.ps1','Open a new Codex task')) { $bootstrap.Contains($marker) | Should Be $true }
    $bat = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\install.bat')
    $bat.Contains('goto bootstrap') | Should Be $true
    $ui = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\install-ui.ps1')
    $menu = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\install-menu.ps1')
    $ui.Contains("Invoke-SuperBrainScript 'bootstrap.ps1' @('-MemoryMode','Shared')") | Should Be $true
    $menu.Contains("Invoke-SuperBrainScript 'bootstrap.ps1' @('-MemoryMode','Shared')") | Should Be $true
    $ui.Contains("`$globalInstallButton.Add_Click({ Invoke-SuperBrainScript 'install.ps1'") | Should Be $false
  }

  It 'routes every required completion audit role explicitly' {
    $json = & (Join-Path $Root 'scripts\smart-next.ps1') -Text 'completion skill audit verify test regression before completion' -Json
    if ($LASTEXITCODE -ne 0) { throw 'smart-next completion audit failed' }
    $result = $json | ConvertFrom-Json
    $expected = @('pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair')
    $result.completionSkillAudit.auditRequested | Should Be $true
    @($result.completionSkillAudit.missingRoles).Count | Should Be 0
    foreach ($role in $expected) { @($result.completionSkillAudit.presentRoles) -contains $role | Should Be $true }
    $result.completionSkillAudit.postMutationReview.artifact | Should Be 'task-scoped causal-change-review.ps1 result'
    $result.completionSkillAudit.postMutationReview.acceptance | Should Match 'decision=keep'
  }

  It 'keeps status snapshots aligned with dashboard and latest verification' {
    $writer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\status-snapshot-writer.ps1')
    $verify = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\verify-package.ps1')
    $writer.Contains('ok = ($dashboard.ok -eq $true)') | Should Be $true
    $writer.Contains('verifyCheckedAt') | Should Be $true
    $writer.Contains('[switch]$AllowActiveCheckpoint') | Should Be $true
    $writer.Contains('$dashboardParameters.AllowActiveCheckpoint = $true') | Should Be $true
    $verify.Contains('verify-package final status') | Should Be $true
    $verify.Contains('final status snapshot matches latest verification') | Should Be $true
    $verify.Contains('-AllowActiveCheckpoint -Json') | Should Be $true
  }

  It 'uses the active checkpoint for status continuity without mutating it' {
    . (Join-Path $Root 'scripts\common.ps1')
    $stateRoot = Join-Path $TestDrive 'scoped-status-state'
    $workspace = Join-Path $stateRoot 'workspace'
    $checkpointRoot = Join-Path $workspace 'runtime-state\checkpoints\active'
    New-Item -ItemType Directory -Force -Path $checkpointRoot | Out-Null
    $workspaceKey = Get-SuperBrainWorkspaceKey (Join-Path $TestDrive 'scoped-project')
    $taskId = 'scoped-status-task'
    $checkpointPath = Join-Path $checkpointRoot ($taskId + '.json')
    $contextPath = Join-Path $workspace 'current-task-context.json'
    $checkpoint = [pscustomobject]@{ taskId=$taskId; status='active'; workspaceKey=$workspaceKey; currentStep='keep scoped state'; nextAction='continue scoped state'; blockers=@(); evidence=@('scoped evidence') }
    $context = [pscustomobject]@{ taskId=$taskId; status='active'; stale=$false; workspaceKey=$workspaceKey; expiresAt=(Get-Date).AddHours(1).ToString('o'); acceptedGoal='scoped goal' }
    [IO.File]::WriteAllText($checkpointPath,($checkpoint|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($contextPath,($context|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $version = [string](Get-SuperBrainManifest $Root).version
    [IO.File]::WriteAllText((Join-Path $workspace 'last-verify-package.json'),([pscustomobject]@{ok=$true;version=$version;checkedAt='test'}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $workspace 'last-hot-refresh.json'),'{"ok":true,"checkedAt":"test"}',[Text.UTF8Encoding]::new($false))
    $beforeHash = (Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& (Join-Path $Root 'scripts\status-snapshot-writer.ps1') -WorkspaceKey $workspaceKey -AllowActiveCheckpoint -Json)
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.continuity.taskId | Should Be $taskId
      $result.continuity.source | Should Be 'runtime-state/checkpoints/active'
      $result.continuity.consistency | Should Be 'consistent'
      (Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash | Should Be $beforeHash
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
  }

  It 'ranks live status evidence ahead of changelog history' {
    $raw = @(& (Join-Path $Root 'scripts\recall-search.ps1') -Query 'current super-memory-brain version and status' -TopK 3 -MaxTokens 1200 -Json)
    $parsed = (($raw -join "`n") | ConvertFrom-Json)
    $items = @(foreach ($item in $parsed) { $item })
    $items.Count -ge 1 | Should Be $true
    @('memory\workspace\status-card.json','memory\workspace\super-brain-state.json') -contains [string]$items[0].source | Should Be $true
    $items[0].reason | Should Be 'state_recall_priority'
    ([double]$items[0].ageDays -lt 2) | Should Be $true
    ([int]$items[0].sourcePriority -le 20) | Should Be $true
    ([int]$items[0].sourcePriority -lt [int]$items[-1].sourcePriority) | Should Be $true
  }

  It 'rejects a memory evaluation fixture that cites itself as evidence' {
    $fixtureName = '.tmp-self-referential-memory-eval.json'
    $fixturePath = Join-Path (Join-Path $Root 'tests') $fixtureName
    $fixture = @([pscustomobject]@{
      id = 'self-reference-must-fail'
      question = 'self reference'
      mode = 'staticSources'
      sources = @('tests/' + $fixtureName)
      mustContain = @('self-reference-must-fail')
      mustNotContain = @()
    }) | ConvertTo-Json -Depth 6
    try {
      [IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($false))
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\memory-eval.ps1') -TestsPath $fixturePath -Mode static -Json 2>$null)
      $LASTEXITCODE | Should Be 1
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $result.ok | Should Be $false
      @($result.cases[0].invalidSources).Count | Should Be 1
    } finally {
      if (Test-Path -LiteralPath $fixturePath) { Remove-Item -LiteralPath $fixturePath -Force }
    }
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

  It 'treats nullable doctor values as present aggregation fields' {
    $verify = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\verify-package.ps1')
    $verify.Contains("@('riskSummary','risks','lastMemoryEval','lastTaskVerification'") | Should Be $true
    $verify.Contains('$doctorFields -notcontains $_') | Should Be $true
  }

  It 'keeps Pester state isolated and task lifecycle findings visible' {
    $runner = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\test-pester.ps1')
    foreach ($marker in @('super-brain-pester-','SUPER_BRAIN_STATE_ROOT','Copy-Item','Remove-Item')) { $runner.Contains($marker) | Should Be $true }
    $index = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\task-index.ps1')
    foreach ($marker in @('[switch]$IncludeDiagnostic','Test-DiagnosticTaskId')) { $index.Contains($marker) | Should Be $true }
    $audit = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\task-lifecycle-audit.ps1')
    foreach ($marker in @('super-brain.task-lifecycle-audit.v1','diagnosticCards','zeroPendingActiveCards','staleUnboundActiveCards','automaticContinuationSafe')) { $audit.Contains($marker) | Should Be $true }
    $doctor = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\doctor.ps1')
    foreach ($marker in @('task-lifecycle-audit.ps1','diagnostic_task_state_present','zero_pending_active_tasks','stale_unbound_active_tasks','task_pointer_divergence')) { $doctor.Contains($marker) | Should Be $true }
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

  It 'keeps package self-verification detached from stale task pointers' {
    $verify = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\verify-package.ps1')
    $workspaceInit = '$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) ''workspace'''
    $verify.IndexOf($workspaceInit) -ge 0 | Should Be $true
    $verify.Contains('$lastTaskForGuardPath') | Should Be $false
    $verify.Contains('completion guard failed taskId=') | Should Be $true
    $verify.Contains('-AllowActiveCheckpoint -ContractOnly -PackageVerificationInProgress') | Should Be $true
    $guard = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\completion-guard.ps1')
    $guard.Contains('[switch]$ContractOnly') | Should Be $true
    $guard.Contains("if (`$PackageVerificationInProgress) { `$TaskId = '' }") | Should Be $true
    $guard.Contains('-not $ContractOnly -and [string]::IsNullOrWhiteSpace($TaskId)') | Should Be $true
  }

  It 'runs the CI completion guard as a task-neutral contract check' {
    $ci = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\ci.ps1')
    foreach ($marker in @('$completionGuardArgs','-AllowActiveCheckpoint','-ContractOnly','-PackageVerificationInProgress')) { $ci.Contains($marker) | Should Be $true }
    foreach ($forbidden in @('completion_guard_task_lookup_failed','$completionGuardTaskFound')) { $ci.Contains($forbidden) | Should Be $false }
    $ci.IndexOf('$completionGuardArgs') -lt $ci.IndexOf("Run-Step 'completion-guard'") | Should Be $true
    foreach ($step in @('super-brain-dashboard','status-snapshot-writer','health-summary','brain-status')) {
      ([regex]::Match($ci,"Run-Step '$step'.*",'Multiline').Value).Contains('-AllowActiveCheckpoint') | Should Be $true
    }
    $health = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\health-summary.ps1')
    $brain = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\brain.ps1')
    $health.Contains('[switch]$AllowActiveCheckpoint') | Should Be $true
    $health.Contains('$dashboardArgs.AllowActiveCheckpoint = $true') | Should Be $true
    $brain.Contains('-AllowActiveCheckpoint:$AllowActiveCheckpoint') | Should Be $true
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

  It 'keeps runtime state and backups on the four-layer layout contract' {
    $common = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\common.ps1')
    $backup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\backup.ps1')
    $lifecycle = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\workspace-lifecycle-manager.ps1')
    $share = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\prepare-share.ps1')
    foreach ($marker in @('runtime-layout.json','SUPER_BRAIN_STATE_ROOT','Get-SuperBrainArchiveRoot','Get-SuperBrainInstallBackupRoot')) { $common.Contains($marker) | Should Be $true }
    foreach ($marker in @('[switch]$IncludeWorkspace','generatedWorkspaceExcluded','workspace_critical','backup-manifest.json')) { $backup.Contains($marker) | Should Be $true }
    $lifecycle.Contains('oversized_workspace_json') | Should Be $true
    foreach ($marker in @('Invoke-SuperBrainTaskStateStore','Reconcile','Compact','blocked_pending_transaction','archiveTaskStateJournalsBehindSnapshots')) { $lifecycle.Contains($marker) | Should Be $true }
    foreach ($item in @('maintenance-policy.json','route-map.json','capabilities.json','runtime-layout.example.json')) { $share.Contains("'$item'") | Should Be $true }
    $share.Contains('Generated source/share trees never need local edit backups') | Should Be $true
    $share.Contains('Remove-Item -LiteralPath $generated.FullName -Force') | Should Be $true
    foreach ($scriptName in @('install.ps1','install-agent.ps1','hot-refresh-skills.ps1','cleanup-install-backups.ps1','install-ui.ps1')) {
      (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root "scripts\$scriptName")).Contains('Get-SuperBrainInstallBackupRoot') | Should Be $true
    }
    (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\verify-package.ps1')).Contains('four-layer runtime layout') | Should Be $true
    (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\verify-share.ps1')).Contains('runtime-layout.example.json') | Should Be $true
  }

  It 'surfaces bounded memory pressure through hygiene and optimization advice' {
    $hygiene = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\auto-hygiene-runner.ps1')
    $advisor = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\optimize-advisor.ps1')
    foreach ($marker in @('Get-SuperBrainMemoryLifecyclePolicy','stale_history','memoryLifecycle','budgetOverflow','Invoke-RebuildMemoryIndexes','lineMap','indexRebuild','derivedIndexes')) { $hygiene.Contains($marker) | Should Be $true }
    foreach ($marker in @('memory_budget_exceeded','memory_budget_near_limit','memoryBudgetStatus','memory-health.ps1')) { $advisor.Contains($marker) | Should Be $true }
  }

  It 'keeps optimize advisor Json free of nested backup retention output' {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\optimize-advisor.ps1') -Json 2>$null)
    $text = ($raw -join "`n").Trim()
    $result = $text | ConvertFrom-Json
    $text.Contains('BACKUP_RETENTION_') | Should Be $false
    $null -ne $result.ok | Should Be $true
    $null -ne $result.signals.backupRetentionOk | Should Be $true
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
    foreach ($file in @('sandglass_paths.py','sandglass_lock.py','sandglass_vault.py','sandglass_sqlite.py','shadow_sand.py','sandglass_archive.py')) {
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

  It 'binds intent-router text correctly for named and positional callers' {
    $named = (& (Join-Path $Root 'scripts\intent-router.ps1') -Text 'fix broken cache' -Workspace $Root -Json | ConvertFrom-Json)
    $positional = (& (Join-Path $Root 'scripts\intent-router.ps1') 'fix broken cache' -Workspace $Root -Json | ConvertFrom-Json)
    $named.intent | Should Be 'fix_bug'
    $positional.intent | Should Be 'fix_bug'
    $positional.input | Should Be 'fix broken cache'
    $positional.workspace | Should Be $Root
  }

  It 'keeps generic agent role questions on the direct path' {
    $howConfigure = 'agent ' + (-join (@(24590,20040,37197,32622) | ForEach-Object { [char]$_ }))
    $whatCanDo = 'agent ' + (-join (@(33021,20570,20160,20040) | ForEach-Object { [char]$_ }))
    foreach ($query in @($howConfigure,$whatCanDo)) {
      $result = (& (Join-Path $Root 'scripts\intent-router.ps1') -Text $query -Json | ConvertFrom-Json)
      $result.intent | Should Be 'general_task'
      @($result.dispatchHints) -contains 'negative_agent_trigger' | Should Be $true
    }
  }

  It 'keeps routing policy aligned with strict production behavior' {
    $routeMap = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'route-map.json') | ConvertFrom-Json
    $routeMap.phase | Should Be 'phase6-strict-routing'
    @($routeMap.routes | Where-Object { $_.PSObject.Properties['knownBaselineGaps'] }).Count | Should Be 0
    $system = @($routeMap.routes | Where-Object { $_.route -eq 'system_status' }) | Select-Object -First 1
    @($system.read) -contains 'references/install-refresh.md' | Should Be $false
    @($system.read) -contains 'memory/workspace/status-card.json' | Should Be $true
    $capabilities = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'capabilities.json') | ConvertFrom-Json
    $capabilities.phase | Should Be 'phase6-strict-capabilities'
  }

  It 'does not let privacy authorization bypass package verification' {
    $guardText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\completion-guard.ps1')
    $guardText.Contains('if ($AllowPrivacyRisk -and -not $verifyOk)') | Should Be $false

    . (Join-Path $Root 'scripts\common.ps1')
    $verifyPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-verify-package.json'
    $backup = if (Test-Path -LiteralPath $verifyPath) { [IO.File]::ReadAllText($verifyPath,[Text.Encoding]::UTF8) } else { $null }
    try {
      $fake = [pscustomobject]@{ ok=$false; version='test'; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json
      [IO.File]::WriteAllText($verifyPath,$fake,[Text.UTF8Encoding]::new($false))
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\completion-guard.ps1') -ContractOnly -AllowPrivacyRisk -AllowActiveCheckpoint -Json 2>$null)
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $verifyCheck = @($result.checks | Where-Object { $_.name -eq 'verify-package' }) | Select-Object -First 1
      $verifyCheck.ok | Should Be $false
      $result.allowPrivacyRisk | Should Be $true
      $result.packageVerificationInProgress | Should Be $false
    } finally {
      if ($null -eq $backup) { Remove-Item -LiteralPath $verifyPath -Force -ErrorAction SilentlyContinue }
      else { [IO.File]::WriteAllText($verifyPath,$backup,[Text.UTF8Encoding]::new($false)) }
    }
  }

  It 'limits package self-verification bypass to contract-only validation' {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\completion-guard.ps1') -PackageVerificationInProgress -Json 2>&1)
    $LASTEXITCODE | Should Be 1
    ($raw -join "`n").Contains('PACKAGE_VERIFICATION_IN_PROGRESS_REQUIRES_CONTRACT_ONLY') | Should Be $true
  }

  It 'never authorizes task completion during package self-verification' {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\completion-guard.ps1') -ContractOnly -PackageVerificationInProgress -TaskId 'task-stale-foreign' -AllowPrivacyRisk -AllowActiveCheckpoint -Json 2>$null)
    $result = (($raw -join "`n") | ConvertFrom-Json)
    $result.packageVerificationInProgress | Should Be $true
    $result.completionAuthorized | Should Be $false
    $result.taskId | Should Be ''
  }

  It 'keeps internal intent-router calls on the named Text contract' {
    $result = (& (Join-Path $Root 'scripts\script-call-contract.ps1') -Json | ConvertFrom-Json)
    $result.ok | Should Be $true
    $result.violationCount | Should Be 0
    $result.checkedCalls -gt 0 | Should Be $true
  }

  It 'tracks new routing and hook files in install UI regression inputs' {
    $regression = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\install-ui-regression.ps1')
    foreach ($path in @(
      'modules\skill-pool-router\SKILL.md',
      'modules\skill-pool-router\scripts\manage-skill-pool.ps1',
      'modules\skill-pool-router\scripts\skill-catalog.ps1',
      'scripts\install-codex-user-prompt-hook.ps1',
      'scripts\codex-user-prompt-hook.ps1',
      'scripts\routing-kernel.ps1',
      'scripts\task-link-store.ps1',
      'scripts\task-state-store.ps1',
      'scripts\script-call-contract.ps1',
      'scripts\completion-guard.ps1',
      'scripts\status-snapshot-writer.ps1',
      'scripts\health-summary.ps1',
      'scripts\brain.ps1',
      'scripts\smoke-test.ps1',
      'scripts\verify-package.ps1',
      'scripts\ci.ps1'
    )) {
      $regression.Contains("'$path'") | Should Be $true
    }
  }

  It 'keeps named-skill lookup on the compact index fast path' {
    $manager = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'modules\skill-pool-router\scripts\manage-skill-pool.ps1')
    foreach ($marker in @("skill-name-index.tsv","Write-TextAtomic `$lookupPath","Write-Index 'reindex'","Write-Index 'activate'","Write-Index 'apply'")) {
      $manager.Contains($marker) | Should Be $true
    }
    $manager.Contains("skill-catalog.ps1") | Should Be $true
    $manager.Contains("Get-SkillCatalogFiles `$active") | Should Be $true
    $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'modules\skill-pool-router\scripts\skill-catalog.ps1')
    $catalog.Contains("Get-ChildItem -LiteralPath `$Root -Directory -Force") | Should Be $true
    $catalog.Contains("Get-ChildItem -LiteralPath `$directory.FullName -Recurse -Filter 'SKILL.md'") | Should Be $true

    $hook = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\codex-user-prompt-hook.ps1')
    $compactLookup = $hook.IndexOf("skill-name-index.tsv")
    $fallbackScan = $hook.IndexOf('if($entries.Count-eq0)')
    $compactLookup -ge 0 | Should Be $true
    $fallbackScan -gt $compactLookup | Should Be $true
    $hook.Contains('Select-Object -Skip 1') | Should Be $true
    $hook.Contains('if($parts.Count-ne5){continue}') | Should Be $true
    $hook.Contains('if($usedCompactIndex)') | Should Be $true
  }

  It 'keeps the explicit free-image skill in the protected hot profile' {
    $manager = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'modules\skill-pool-router\scripts\manage-skill-pool.ps1')
    $manager.Contains('$freeImageFolder = -join (@(20813,36153,29983,22270)') | Should Be $true
    ([regex]::Matches($manager,'\$freeImageFolder')).Count | Should Be 3
  }

  It 'counts a linked skill through the shared catalog enumerator' {
    $active = Join-Path $TestDrive 'linked-active'
    $target = Join-Path $TestDrive 'linked-target'
    New-Item -ItemType Directory -Force -Path $active,$target | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'SKILL.md'),"---`nname: linked-skill`ndescription: Linked skill test.`n---`n",[Text.UTF8Encoding]::new($false))
    $link = Join-Path $active 'linked-skill'
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    . (Join-Path $Root 'modules\skill-pool-router\scripts\skill-catalog.ps1')
    $files = @(Get-SkillCatalogFiles $active)
    $files.Count | Should Be 1
    $files[0].FullName.Contains('linked-skill') | Should Be $true
  }

  It 'resolves an active linked skill by its declared name before checking cold storage' {
    $active = Join-Path $TestDrive 'resolve-linked-active'
    $target = Join-Path $TestDrive 'resolve-linked-target'
    $cold = Join-Path $TestDrive 'resolve-linked-cold'
    New-Item -ItemType Directory -Force -Path $active,$target | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'SKILL.md'),"---`nname: Smag`ndescription: Linked active resolver test.`n---`n",[Text.UTF8Encoding]::new($false))
    New-Item -ItemType Junction -Path (Join-Path $active 'share-mini-imagegen') -Target $target | Out-Null

    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'modules\skill-pool-router\scripts\manage-skill-pool.ps1') -Action Resolve -ActiveRoot $active -ColdRoot $cold -SkillName Smag -Json 2>$null)
    $LASTEXITCODE | Should Be 0
    $result = (($raw -join "`n") | ConvertFrom-Json)
    $result.status | Should Be 'resolved_active_in_place'
    $result.skill.name | Should Be 'Smag'
    $result.skill.skillFile.Contains('share-mini-imagegen') | Should Be $true
    $result.checkedColdIndex | Should Be $false
  }

  It 'exposes and hides a cold skill through a reversible active junction' {
    $active = Join-Path $TestDrive 'expose-active'
    $cold = Join-Path $TestDrive 'expose-cold'
    $skillRoot = Join-Path $cold 'exact-skill'
    New-Item -ItemType Directory -Force -Path $active,$skillRoot | Out-Null
    $skillFile = Join-Path $skillRoot 'SKILL.md'
    $skillText = "---`nname: exact-skill`ndescription: Exact skill exposure test.`n---`n"
    [IO.File]::WriteAllText($skillFile,$skillText,[Text.UTF8Encoding]::new($true))

    $manager = Join-Path $Root 'modules\skill-pool-router\scripts\manage-skill-pool.ps1'
    $invalid = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Action Expose -ActiveRoot $active -ColdRoot $cold -SkillName exact-skill -Json 2>&1)
    $LASTEXITCODE | Should Be 1
    ($invalid -join "`n").Contains('SKILL_POOL_CODEX_FRONTMATTER_INVALID') | Should Be $true
    Test-Path -LiteralPath (Join-Path $active 'exact-skill') | Should Be $false

    [IO.File]::WriteAllText($skillFile,$skillText,[Text.UTF8Encoding]::new($false))
    $exposed = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Action Expose -ActiveRoot $active -ColdRoot $cold -SkillName exact-skill -Json 2>$null) -join "`n") | ConvertFrom-Json)
    $exposed.ok | Should Be $true
    $exposed.coldPreserved | Should Be $true
    (Get-Item -LiteralPath (Join-Path $active 'exact-skill') -Force).LinkType | Should Be 'Junction'
    Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md') | Should Be $true

    $hidden = ((@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $manager -Action Hide -ActiveRoot $active -ColdRoot $cold -SkillName exact-skill -Json 2>$null) -join "`n") | ConvertFrom-Json)
    $hidden.ok | Should Be $true
    $hidden.coldPreserved | Should Be $true
    Test-Path -LiteralPath (Join-Path $active 'exact-skill') | Should Be $false
    Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md') | Should Be $true
  }

  It 'backs up hook configuration and trusts only the discovered hook hash' {
    $installer = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\install-codex-user-prompt-hook.ps1')
    foreach ($marker in @(
      'Backup-File $hooksPath;Backup-File $configPath',
      "Send-Rpc 2 'hooks/list'",
      "EnvironmentVariables['CODEX_HOME']=`$ProtocolCodexHome",
      "Where-Object{[string]`$_.sourcePath-eq`$hooksPath}",
      'trusted_hash=[string]$hook.currentHash',
      "Send-Rpc 3 'config/batchWrite'",
      'CODEX_HOOK_WINDOWS_POWERSHELL_BOM_PRIME',
      'if(-not$ReportOnly){Restore-Backups}'
    )) {
      $installer.Contains($marker) | Should Be $true
    }
  }

  It 'keeps optional extensions opt-in during normal installation' {
    $install = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\install.ps1')
    ([regex]::Matches($install,'if \(\$Extensions\.Count -gt 0\)')).Count | Should Be 2
    $rollback = [regex]::Match($install,'function Restore-Backups.*?^}',[Text.RegularExpressions.RegexOptions]'Singleline, Multiline').Value
    $rollback.Contains('Remove-Item -LiteralPath $entry.dest -Recurse -Force') | Should Be $true
    $rollback.Contains('elseif ($entry.created)') | Should Be $true
    $rollback.Contains('Removed newly created skill during rollback') | Should Be $true
    $common = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\common.ps1')
    $sourceBlock = [regex]::Match($common,'function Get-SuperBrainSourceItems.*?return @\(\$items\)','Singleline').Value
    $sourceBlock.Contains("name='agent-bridge'") | Should Be $false
    $sourceBlock.Contains('if ($Extensions.Count -gt 0)') | Should Be $true
    $install.Contains('$targetCodexSkills.Equals($defaultCodexSkills,[StringComparison]::OrdinalIgnoreCase)') | Should Be $true
    $install.Contains("-Action Reindex -ActiveRoot `$CodexSkills -ColdRoot `$coldSkillRoot") | Should Be $true
    $install.Contains("throw 'SKILL_POOL_REINDEX_FAILED'") | Should Be $true
    $smoke = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\smoke-test.ps1')
    $smoke.Contains('if ($Extensions.Count -gt 0)') | Should Be $true
  }

  It 'requires explicit install-backup pruning and refreshes governed memory markers' {
    $install = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\install.ps1')
    foreach ($marker in @(
      '[CmdletBinding(PositionalBinding=$false)]',
      '[switch]$PruneBackups',
      'if (-not $PruneBackups) { return }',
      'if ($PruneBackups)',
      'cleanup-install-backups.ps1 -Apply',
      'function Refresh-InstalledMemoryRootMarkers',
      "package-root.txt",
      'Refresh-InstalledMemoryRootMarkers $ZCodeSkills $ZCodeMemoryRoot',
      'Refresh-InstalledMemoryRootMarkers $CodexSkills $CodexMemoryRoot'
    )) {
      $install.Contains($marker) | Should Be $true
    }
    $verify = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'scripts\verify-package.ps1')
    foreach ($marker in @('runtime backup residue absent','invalid script install roots absent',"`$_.Name -match '\.bak-'")) {
      $verify.Contains($marker) | Should Be $true
    }
  }

  It 'does not fabricate unknown or superseded decisions' {
    $unknown = @((& (Join-Path $Root 'scripts\decision-search.ps1') -Key 'nonexistent-decision-repair-regression-7f3a9c2e' -CurrentOnly -Relation decides -Json | ConvertFrom-Json) | Where-Object { $_ -ne $null })
    @($unknown).Count | Should Be 0

    $stale = @((& (Join-Path $Root 'scripts\decision-search.ps1') -Key 'codex-g1-first-line-display-rule-v2' -CurrentOnly -Relation decides -Json | ConvertFrom-Json) | Where-Object { $_ -ne $null })
    $current = @((& (Join-Path $Root 'scripts\decision-search.ps1') -Key 'codex-g1-first-line-display-rule-v3' -CurrentOnly -Relation decides -Json | ConvertFrom-Json) | Where-Object { $_ -ne $null })
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
      $card.relevanceStatus | Should Be 'anchor_matched'
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

  It 'requires current task post-mutation review evidence instead of reusing a foreign task' {
    $stateRoot = Join-Path $TestDrive 'post-mutation-review-state'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-post-mutation-review'
    $version = [string]((Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)
    $writeJson = {
      param([string]$Path,[object]$Value)
      $parent = Split-Path -Parent $Path
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
      [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    }
    & $writeJson (Join-Path $workspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version=$version;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')})
    & $writeJson (Join-Path $workspace 'last-hot-refresh.json') ([pscustomobject]@{ok=$true;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')})
    & $writeJson (Join-Path $workspace 'last-task-verification.json') ([pscustomobject]@{ok=$true;taskId=$taskId;version=$version;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');summary='updated one file';changed=@('scripts/example.ps1');commands=@('focused test');constraintsPreserved=$true})
    & $writeJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{ok=$true;version=$version;status='active';stale=$false;expiresAt=(Get-Date).AddHours(1).ToString('yyyy-MM-dd HH:mm:ss');taskId=$taskId;acceptedGoal='update a file';acceptedRoute=@('execute -> verify')})
    $roles = @('pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair')
    $capabilities = @($roles | ForEach-Object { [pscustomobject]@{name="test-$($_)";category='rule';role=$_;canDo=@('focused verification');cannotDo=@();triggers=@('completion');applyAt=@('before_completion');verification=@('test evidence')} })
    & $writeJson (Join-Path $workspace 'skill-capability-map.json') ([pscustomobject]@{capabilities=$capabilities})
    & $writeJson (Join-Path (Join-Path $workspace 'guard-state\change-causality-reviews') 'foreign-task\review.json') ([pscustomobject]@{ok=$true;taskId='foreign-task';gaps=@();actualResult='foreign verification passed';evidence=@('foreign regression');expectedVsActual=[pscustomobject]@{decision='keep';expectedPresent=$true;actualPresent=$true}})
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\completion-guard.ps1') -TaskId $taskId -AllowPrivacyRisk -AllowActiveCheckpoint -Json 2>$null)
      $missingReview = (($raw -join "`n") | ConvertFrom-Json)
      $missingCheck = @($missingReview.checks | Where-Object { $_.name -eq 'post-mutation-review' }) | Select-Object -First 1
      $missingReview.postMutationReviewRequired | Should Be $true
      $missingCheck.ok | Should Be $false
      $missingCheck.evidence | Should Match 'missing task-scoped causal review'

      $planPath = Join-Path (Join-Path $workspace 'guard-state\change-causality') $taskId
      & $writeJson (Join-Path $planPath 'plan.json') ([pscustomobject]@{ok=$true;version=$version;taskId=$taskId;planId='current-plan';expectedOptimization='focused verification remains task scoped';verificationMethod='run targeted regression'})
      $reviewPath = Join-Path (Join-Path $workspace 'guard-state\change-causality-reviews') $taskId
      & $writeJson (Join-Path $reviewPath 'review.json') ([pscustomobject]@{ok=$true;version=$version;taskId=$taskId;planTaskId=$taskId;planTaskMatch=$true;planVersion=$version;verificationMethod='run targeted regression';gaps=@();actualResult='focused verification remains task scoped';evidence=@('targeted regression');expectedVsActual=[pscustomobject]@{decision='keep';expectedPresent=$true;actualPresent=$true;weakTermMatch=$true}})
      $rawAfterReview = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\completion-guard.ps1') -TaskId $taskId -AllowPrivacyRisk -AllowActiveCheckpoint -Json 2>$null)
      $withReview = (($rawAfterReview -join "`n") | ConvertFrom-Json)
      $withReviewCheck = @($withReview.checks | Where-Object { $_.name -eq 'post-mutation-review' }) | Select-Object -First 1
      $withReviewCheck.ok | Should Be $true
      $withReview.postMutationReview.decision | Should Be 'keep'
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
  }

  It 'rejects a current task review when only a foreign global causal plan exists' {
    $stateRoot = Join-Path $TestDrive 'foreign-global-causal-plan-state'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-causal-plan-isolation'
    $foreignTaskId = 'task-causal-plan-foreign'
    $version = [string]((Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)
    $writeJson = {
      param([string]$Path,[object]$Value)
      $parent = Split-Path -Parent $Path
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
      [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    }
    & $writeJson (Join-Path $workspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version=$version;packageRoot=$Root;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')})
    & $writeJson (Join-Path $workspace 'last-hot-refresh.json') ([pscustomobject]@{ok=$true;version=$version;packageRoot=$Root;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')})
    & $writeJson (Join-Path $workspace 'last-task-verification.json') ([pscustomobject]@{ok=$true;taskId=$taskId;version=$version;packageRoot=$Root;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');summary='updated one file';changed=@('scripts/example.ps1');commands=@('focused test');constraintsPreserved=$true})
    & $writeJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{ok=$true;version=$version;status='active';stale=$false;expiresAt=(Get-Date).AddHours(1).ToString('yyyy-MM-dd HH:mm:ss');taskId=$taskId;acceptedGoal='update a file';acceptedRoute=@('execute -> verify')})
    & $writeJson (Join-Path $workspace 'skill-capability-map.json') ([pscustomobject]@{capabilities=@()})
    & $writeJson (Join-Path (Join-Path $workspace 'change-causality') 'foreign-plan.json') ([pscustomobject]@{ok=$true;version=$version;taskId=$foreignTaskId;planId='foreign-plan';expectedOptimization='foreign optimization evidence';verificationMethod='foreign verification'})
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\causal-change-review.ps1') -TaskId $taskId -ActualResult 'foreign optimization evidence' -Evidence 'foreign plan should not be accepted' -Decision keep -Json 2>$null)
      $exitCode = $LASTEXITCODE
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $exitCode | Should Be 1
      $result.ok | Should Be $false
      $result.planSelection | Should Be 'none'
      $result.planTaskMatch | Should Be $false
      @($result.gaps | Where-Object { $_.code -eq 'missing_causal_change_plan' }).Count | Should Be 1
      Test-Path -LiteralPath (Join-Path (Join-Path $workspace 'guard-state\change-causality') $taskId) | Should Be $false
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
  }

  It 'rejects an explicit cross-task causal plan and reports the binding fields' {
    $stateRoot = Join-Path $TestDrive 'explicit-cross-task-causal-plan-state'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-causal-plan-current'
    $foreignTaskId = 'task-causal-plan-foreign-explicit'
    $version = [string]((Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version)
    $planPath = Join-Path $TestDrive 'foreign-explicit-plan.json'
    $plan = [pscustomobject]@{ok=$true;version=$version;taskId=$foreignTaskId;planId='foreign-explicit-plan';expectedOptimization='current optimization evidence';verificationMethod='current verification'}
    [IO.File]::WriteAllText($planPath,($plan | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\causal-change-review.ps1') -TaskId $taskId -PlanPath $planPath -ActualResult 'current optimization evidence' -Evidence 'explicit plan binding regression' -Decision keep -Json 2>$null)
      $exitCode = $LASTEXITCODE
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $exitCode | Should Be 1
      $result.ok | Should Be $false
      $result.planSelection | Should Be 'explicit_path'
      $result.planTaskId | Should Be $foreignTaskId
      $result.planTaskMatch | Should Be $false
      $result.planVersion | Should Be $version
      @($result.gaps | Where-Object { $_.code -eq 'causal_plan_task_mismatch' }).Count | Should Be 1
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
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

  It 'stays silent for marginal optimization opportunities' {
    $result = (& (Join-Path $Root 'scripts\engineering-decision-gate.ps1') -Action AssessIntervention -ExpectedBenefitLevel marginal -RiskLevel low -EvidenceStrength verified -ExpectedDelta 'small formatting improvement' -Recommendation 'defer' -Json | ConvertFrom-Json)
    $result.ok | Should Be $true
    $result.shouldIntervene | Should Be $false
    $result.mode | Should Be 'silent'
  }

  It 'intervenes for material evidence-backed risk' {
    $result = (& (Join-Path $Root 'scripts\engineering-decision-gate.ps1') -Action AssessIntervention -RiskLevel material -EvidenceStrength inference -Facts @('the current write path can lose an update') -FactEvidence @('live write-path inspection') -Recommendation 'pause and verify before mutation' -Json | ConvertFrom-Json)
    $result.ok | Should Be $true
    $result.shouldIntervene | Should Be $true
    $result.mode | Should Be 'recommend'
  }

  It 'normalizes duplicate current decisions by retaining only the latest current record' {
    $scriptText = Get-Content -LiteralPath (Join-Path $Root 'scripts\graph-normalize.ps1') -Raw -Encoding UTF8
    foreach($marker in @('outIndex','Select-Object -First ($ordered.Count - 1)',"-replace '\[CURRENT\]', '[HISTORY]'")) { $scriptText.Contains($marker) | Should Be $true }
  }
}
