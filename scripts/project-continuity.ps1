param(
  [ValidateSet('Snapshot','Status','StartTask','AddStep','CompleteStep','SkipStep','CompleteTask','ArchiveTask','ClearTask','AddFinding','AdmitFinding','RejectFinding')]
  [string]$Action = 'Snapshot',
  [string]$Goal = '',
  [string]$TaskId = '',
  [string]$Step = '',
  [string]$StepId = '',
  [string]$Evidence = '',
  [string[]]$RelatedFiles = @(),
  [string[]]$VerificationCommands = @(),
  [string[]]$Risks = @(),
  [string]$Agent = '',
  [string]$Finding = '',
  [string]$Source = '',
  [string]$FindingId = '',
  [string]$Reason = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

$manifest = Get-SuperBrainManifest $Root
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$projectGraphPath = Join-Path $workspace 'project-graph.json'
$structureBaselinePath = Join-Path $workspace 'structure-baseline.json'
$taskGraphPath = Join-Path $workspace 'task-graph.json'
$stepLedgerPath = Join-Path $workspace 'step-ledger.json'
$findingsRoot = Join-Path $workspace 'agent-findings'
$taskArchiveRoot = Join-Path $workspace 'task-archive'
$completedTaskPath = Join-Path $workspace 'last-completed-task-graph.json'
$archivedTaskPath = Join-Path $workspace 'last-archived-task-graph.json'
$statusPath = Join-Path $workspace 'last-project-continuity.json'
if (-not (Test-Path $findingsRoot)) { New-Item -ItemType Directory -Force -Path $findingsRoot | Out-Null }
if (-not (Test-Path $taskArchiveRoot)) { New-Item -ItemType Directory -Force -Path $taskArchiveRoot | Out-Null }

function Limit-Value([string]$Value, [int]$Max = 220) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = ($Value -replace '\s+', ' ').Trim()
  if ($v.Length -le $Max) { return $v }
  return $v.Substring(0, $Max) + '...'
}

function Limit-List([string[]]$Values, [int]$MaxItems = 20, [int]$MaxChars = 220) {
  $out = @()
  foreach ($value in @($Values)) {
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    $out += Limit-Value $value $MaxChars
    if ($out.Count -ge $MaxItems) { break }
  }
  return @($out)
}

function Read-JsonOrNull([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function New-Id([string]$Prefix) {
  return $Prefix + '-' + ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
}

function New-TaskGraph([string]$Id, [string]$TaskGoal) {
  if ([string]::IsNullOrWhiteSpace($Id)) { $Id = New-Id 'task' }
  return [pscustomobject]@{
    schema = 'super-brain.task-graph.v1'
    taskId = $Id
    goal = Limit-Value $TaskGoal 360
    status = if ([string]::IsNullOrWhiteSpace($TaskGoal)) { 'idle' } else { 'active' }
    steps = @()
    relatedFiles = @(Limit-List $RelatedFiles 30 220)
    verification = @(Limit-List $VerificationCommands 20 220)
    risks = @(Limit-List $Risks 20 220)
    evidence = @()
    updatedAt = $now
  }
}

function Ensure-Array($Value) {
  if ($null -eq $Value) { return @() }
  return @($Value)
}

$keyFiles = @(
  'super-memory-brain/SKILL.md',
  'modules/skill-orchestrator/SKILL.md',
  'modules/plusunm-g1/SKILL.md',
  'modules/nexsandglass-dedicated-memory/SKILL.md',
  'memory-policy.json',
  'manifest.json',
  'CURRENT_BASELINE.md',
  'CHANGELOG.md',
  'scripts/session-restore.ps1',
  'scripts/session-binding.ps1',
  'scripts/learn-memory.ps1',
  'scripts/write-memory.ps1',
  'scripts/accepted-constraints-preflight.ps1',
  'scripts/evidence-freshness.ps1',
  'scripts/project-continuity.ps1',
  'scripts/codegraph-index.ps1',
  'scripts/impact-advisor.ps1',
  'memory/workspace/project-graph.json',
  'memory/workspace/task-graph.json',
  'memory/workspace/codegraph-index.json',
  'memory/workspace/last-codegraph-index.json',
  'memory/workspace/last-impact-advisor.json',
  'memory/workspace/task-archive',
  'memory/workspace/structure-baseline.json',
  'memory/workspace/step-ledger.json',
  'memory/workspace/agent-findings'
)

$projectGraph = [pscustomobject]@{
  schema = 'super-brain.project-graph.v2'
  updatedAt = $now
  packageRoot = $Root
  version = [string]$manifest.version
  nodes = @(
    [pscustomobject]@{ id='entry:super-memory-brain'; type='entrySkill'; path='super-memory-brain/SKILL.md'; role='public entry and rule router' },
    [pscustomobject]@{ id='module:orc'; type='module'; path='modules/skill-orchestrator/SKILL.md'; role='routing' },
    [pscustomobject]@{ id='module:g1'; type='module'; path='modules/plusunm-g1/SKILL.md'; role='memory governance' },
    [pscustomobject]@{ id='module:nexsandglass'; type='module'; path='modules/nexsandglass-dedicated-memory/SKILL.md'; role='local memory and recall' },
    [pscustomobject]@{ id='policy:memory'; type='policy'; path='memory-policy.json'; role='write/read governance' },
    [pscustomobject]@{ id='continuity:project-graph'; type='workspace'; path='memory/workspace/project-graph.json'; role='code/project continuity anchor' },
    [pscustomobject]@{ id='continuity:task-graph'; type='workspace'; path='memory/workspace/task-graph.json'; role='active task graph and recovery facts' },
    [pscustomobject]@{ id='continuity:structure-baseline'; type='workspace'; path='memory/workspace/structure-baseline.json'; role='must-preserve structure constraints' },
    [pscustomobject]@{ id='continuity:step-ledger'; type='workspace'; path='memory/workspace/step-ledger.json'; role='step ledger to prevent omissions' },
    [pscustomobject]@{ id='continuity:agent-findings'; type='workspace'; path='memory/workspace/agent-findings'; role='candidate-only subagent findings before Commander admission' },
    [pscustomobject]@{ id='codegraph:index'; type='workspace'; path='memory/workspace/codegraph-index.json'; role='lightweight script/function/call graph for impact analysis' },
    [pscustomobject]@{ id='impact:advisor'; type='script'; path='scripts/impact-advisor.ps1'; role='change impact, risk, and verification recommendation advisor' },
    [pscustomobject]@{ id='verification:verify-package'; type='script'; path='scripts/verify-package.ps1'; role='package integrity verification' },
    [pscustomobject]@{ id='verification:ci'; type='script'; path='scripts/ci.ps1'; role='stability verification' },
    [pscustomobject]@{ id='verification:memory-eval'; type='script'; path='scripts/memory-eval.ps1'; role='recall quality verification' },
    [pscustomobject]@{ id='verification:trigger-simulation'; type='script'; path='scripts/trigger-simulation.ps1'; role='routing trigger verification' },
    [pscustomobject]@{ id='verification:accepted-constraints'; type='script'; path='scripts/accepted-constraints-preflight.ps1'; role='structure and accepted-decision preflight' },
    [pscustomobject]@{ id='team:review-gate'; type='script'; path='scripts/team-task-review-gate.ps1'; role='Commander review gate' },
    [pscustomobject]@{ id='team:decision'; type='script'; path='scripts/team-task-decision.ps1'; role='Commander finding adoption and memory admission decision' }
  )
  keyFiles = @($keyFiles | ForEach-Object {
    $full = Join-Path $Root ($_ -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    [pscustomobject]@{ path=$_; exists=(Test-Path -LiteralPath $full); lastWriteTime=if (Test-Path -LiteralPath $full) { (Get-Item -LiteralPath $full).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' } }
  })
  scripts = @($manifest.scripts)
  relations = @(
    [pscustomobject]@{ from='entry:super-memory-brain'; relation='routes_to'; to='module:orc,module:g1,module:nexsandglass'; guard='must not replace bottom modules' },
    [pscustomobject]@{ from='scripts/project-continuity.ps1'; relation='writes'; to='project-graph.json,task-graph.json,structure-baseline.json,step-ledger.json,last-project-continuity.json'; guard='write via atomic JSON helper' },
    [pscustomobject]@{ from='continuity:agent-findings'; relation='requires'; to='team:decision'; guard='candidate findings need Commander admission before formal memory' },
    [pscustomobject]@{ from='continuity:structure-baseline'; relation='gates'; to='structure-affecting edits'; guard='run preflight and targeted verification' },
    [pscustomobject]@{ from='continuity:step-ledger'; relation='gates'; to='completion claims'; guard='open steps must be completed or explicitly skipped/reported' },
    [pscustomobject]@{ from='scripts/codegraph-index.ps1'; relation='scans'; to='scripts/*.ps1'; guard='lightweight Parser]::ParseFile index for impact analysis' },
    [pscustomobject]@{ from='codegraph:index'; relation='informs'; to='continuity:project-graph'; guard='use before structure-affecting script edits' },
    [pscustomobject]@{ from='codegraph:index'; relation='supports'; to='impact analysis before script edits'; guard='script_call edges are advisory and literal-reference based' },
    [pscustomobject]@{ from='scripts/impact-advisor.ps1'; relation='consumes'; to='codegraph-index.json,structure-baseline.json,step-ledger.json,last-project-continuity.json'; guard='recommend checks before completion claims' },
    [pscustomobject]@{ from='impact:advisor'; relation='recommends'; to='verification before completion'; guard='riskLevel and recommendedChecks must be reviewed for changed scripts' },
    [pscustomobject]@{ from='verification:accepted-constraints'; relation='supports'; to='continuity:structure-baseline'; guard='accepted constraints cannot be overridden by stale chat memory' },
    [pscustomobject]@{ from='verification:memory-eval,verification:trigger-simulation,verification:verify-package'; relation='verify'; to='routing/recall/package continuity'; guard='report failures, do not claim verified when skipped' }
  )
  relationHints = @(
    'super-memory-brain routes ORC/G1/NexSandglass; it must not replace them',
    'session-restore and session-binding own continuation packets',
    'learn-memory/write-memory own governed memory admission',
    'project-continuity writes task-graph and step-ledger for recoverable task state',
    'codegraph-index scans scripts/*.ps1 for functions, params, script_call edges, and mutation risk',
    'impact-advisor consumes codegraph and continuity artifacts to recommend verification before completion',
    'agent-findings require Commander admission before formal memory',
    'accepted-constraints-preflight and structure-baseline guard edits',
    'evidence-freshness guards current-state conclusions from stale logs',
    'step-ledger guards multi-step work from omissions'
  )
}

$structureBaseline = [pscustomobject]@{
  schema = 'super-brain.structure-baseline.v2'
  updatedAt = $now
  version = [string]$manifest.version
  mustPreserve = @(
    'super-memory-brain is the entry and coordinator, not a replacement for ORC/G1/NexSandglass',
    'Shared memory writes must use governed scripts with locking/atomic-write helpers',
    'Multi-agent findings stay candidate/advisory/private until Commander review admits them into formal memory',
    'Agent findings in memory/workspace/agent-findings are not formal memory and must not be treated as accepted facts before AdmitFinding/Commander decision',
    'Current-state conclusions require fresh evidence; stale logs/snapshots cannot be treated as live truth',
    'Long-context learning must use compact summaries or -TextFile drafts, not raw chat tails',
    'Stateful work must maintain task-graph and step-ledger/checkpoint before and during execution',
    'Open step-ledger items block completion claims unless explicitly completed, skipped with reason, or reported as remaining',
    'Structure-affecting edits must run project-continuity status, accepted-constraints preflight, and targeted verification'
  )
  mustNotViolate = @(
    'Do not let unrelated old memory override current visible user instructions',
    'Do not let subagents write durable shared memory directly without Commander admission',
    'Do not claim current status from old snapshots without version/time freshness checks',
    'Do not skip verification or leave unreported skipped steps after modifying memory/routing/structure',
    'Do not inject raw long transcripts into restore packets, status cards, checkpoints, task graphs, or memory writes',
    'Do not treat candidate agent-findings as verified facts or current project truth'
  )
  criticalFiles = @($keyFiles)
  requiredChecks = @(
    'scripts/project-continuity.ps1 -Action Status -Json',
    'scripts/codegraph-index.ps1 -Json',
    'scripts/impact-advisor.ps1 -ChangedFiles scripts/project-continuity.ps1 -Json',
    'scripts/accepted-constraints-preflight.ps1 -Json',
    'scripts/evidence-freshness.ps1 -Json',
    'scripts/memory-eval.ps1 -Json',
    'scripts/trigger-simulation.ps1 -Json',
    'scripts/verify-package.ps1'
  )
}

$ledger = Read-JsonOrNull $stepLedgerPath
if ($null -eq $ledger) {
  $ledger = [pscustomobject]@{
    schema = 'super-brain.step-ledger.v2'
    updatedAt = $now
    version = [string]$manifest.version
    taskId = ''
    goal = ''
    steps = @()
    openSteps = @()
    completedSteps = @()
    skippedSteps = @()
    guard = 'Before reporting completion, openSteps must be empty or explicitly reported as remaining/skipped with reason.'
  }
}
if (-not $ledger.PSObject.Properties['schema']) { $ledger | Add-Member -NotePropertyName schema -NotePropertyValue 'super-brain.step-ledger.v2' -Force }
if (-not $ledger.PSObject.Properties['taskId']) { $ledger | Add-Member -NotePropertyName taskId -NotePropertyValue '' -Force }

$taskGraph = Read-JsonOrNull $taskGraphPath
if ($null -eq $taskGraph) { $taskGraph = New-TaskGraph $TaskId $Goal }
if (-not $taskGraph.PSObject.Properties['schema']) { $taskGraph | Add-Member -NotePropertyName schema -NotePropertyValue 'super-brain.task-graph.v1' -Force }
if (-not $taskGraph.PSObject.Properties['steps']) { $taskGraph | Add-Member -NotePropertyName steps -NotePropertyValue @() -Force }
if (-not $taskGraph.PSObject.Properties['evidence']) { $taskGraph | Add-Member -NotePropertyName evidence -NotePropertyValue @() -Force }

if ($Action -eq 'StartTask') {
  $taskGraph = New-TaskGraph $TaskId $Goal
  $ledger.taskId = $taskGraph.taskId
  if (-not [string]::IsNullOrWhiteSpace($Goal)) { $ledger.goal = Limit-Value $Goal 360 }
  $ledger.steps = @()
}

if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
  $taskGraph.taskId = Limit-Value $TaskId 120
  $ledger.taskId = $taskGraph.taskId
}
if (-not [string]::IsNullOrWhiteSpace($Goal)) {
  $ledger.goal = Limit-Value $Goal 360
  $taskGraph.goal = Limit-Value $Goal 360
  if ($taskGraph.status -eq 'idle') { $taskGraph.status = 'active' }
}
if (@($RelatedFiles).Count -gt 0) { $taskGraph.relatedFiles = @(Limit-List @($taskGraph.relatedFiles + $RelatedFiles) 40 220 | Select-Object -Unique) }
if (@($VerificationCommands).Count -gt 0) { $taskGraph.verification = @(Limit-List @($taskGraph.verification + $VerificationCommands) 30 220 | Select-Object -Unique) }
if (@($Risks).Count -gt 0) { $taskGraph.risks = @(Limit-List @($taskGraph.risks + $Risks) 30 220 | Select-Object -Unique) }

$normalizedStep = Limit-Value $Step 260
if ($Action -eq 'AddStep' -and -not [string]::IsNullOrWhiteSpace($normalizedStep)) {
  $id = if ([string]::IsNullOrWhiteSpace($StepId)) { New-Id 'step' } else { Limit-Value $StepId 120 }
  $entry = [pscustomobject]@{ id=$id; step=$normalizedStep; status='open'; evidence=Limit-Value $Evidence 220; reason=''; updatedAt=$now }
  $ledger.steps = @(Ensure-Array $ledger.steps) + @($entry)
  $taskGraph.steps = @(Ensure-Array $taskGraph.steps) + @($entry)
}

if ($Action -eq 'CompleteStep' -and (-not [string]::IsNullOrWhiteSpace($normalizedStep) -or -not [string]::IsNullOrWhiteSpace($StepId))) {
  $matched = $false
  $ledger.steps = @(Ensure-Array $ledger.steps | ForEach-Object {
    if (-not $matched -and ((-not [string]::IsNullOrWhiteSpace($StepId) -and [string]$_.id -eq $StepId) -or ([string]$_.step -eq $normalizedStep))) {
      $_.status = 'completed'; $_.evidence = Limit-Value $Evidence 220; $_.updatedAt = $now; $matched = $true
    }
    $_
  })
  $taskGraph.steps = @(Ensure-Array $ledger.steps)
  if (-not $matched -and -not [string]::IsNullOrWhiteSpace($normalizedStep)) {
    $entry = [pscustomobject]@{ id=(if ([string]::IsNullOrWhiteSpace($StepId)) { New-Id 'step' } else { Limit-Value $StepId 120 }); step=$normalizedStep; status='completed'; evidence=Limit-Value $Evidence 220; reason=''; updatedAt=$now }
    $ledger.steps = @(Ensure-Array $ledger.steps) + @($entry)
    $taskGraph.steps = @(Ensure-Array $ledger.steps)
  }
}

if ($Action -eq 'SkipStep' -and (-not [string]::IsNullOrWhiteSpace($normalizedStep) -or -not [string]::IsNullOrWhiteSpace($StepId))) {
  if ([string]::IsNullOrWhiteSpace($Reason) -and [string]::IsNullOrWhiteSpace($Evidence)) { throw 'SkipStep requires -Reason or -Evidence.' }
  $matched = $false
  $ledger.steps = @(Ensure-Array $ledger.steps | ForEach-Object {
    if (-not $matched -and ((-not [string]::IsNullOrWhiteSpace($StepId) -and [string]$_.id -eq $StepId) -or ([string]$_.step -eq $normalizedStep))) {
      $_.status = 'skipped'; $_.evidence = Limit-Value $Evidence 220; $_.reason = Limit-Value $Reason 220; $_.updatedAt = $now; $matched = $true
    }
    $_
  })
  if (-not $matched -and -not [string]::IsNullOrWhiteSpace($normalizedStep)) {
    $entry = [pscustomobject]@{ id=(if ([string]::IsNullOrWhiteSpace($StepId)) { New-Id 'step' } else { Limit-Value $StepId 120 }); step=$normalizedStep; status='skipped'; evidence=Limit-Value $Evidence 220; reason=Limit-Value $Reason 220; updatedAt=$now }
    $ledger.steps = @(Ensure-Array $ledger.steps) + @($entry)
  }
  $taskGraph.steps = @(Ensure-Array $ledger.steps)
}

if ($Action -eq 'CompleteTask') {
  $openNow = @(Ensure-Array $ledger.steps | Where-Object { $_.status -eq 'open' })
  if (@($openNow).Count -gt 0) { throw "CompleteTask blocked: openSteps=$(@($openNow).Count). Complete or SkipStep first." }
  $taskGraph.status = 'completed'
  $taskGraph | Add-Member -NotePropertyName completedAt -NotePropertyValue $now -Force
  if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $taskGraph.evidence = @(Limit-List @($taskGraph.evidence + $Evidence) 30 220 | Select-Object -Unique) }
  Write-JsonUtf8NoBom $completedTaskPath $taskGraph 12
}

if ($Action -eq 'ArchiveTask') {
  $safeId = if ([string]::IsNullOrWhiteSpace([string]$taskGraph.taskId)) { 'task' } else { ([string]$taskGraph.taskId -replace '[^A-Za-z0-9_.-]', '-') }
  $archivePath = Join-Path $taskArchiveRoot ("$safeId-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).json")
  $archive = [pscustomobject]@{
    schema = 'super-brain.task-archive.v1'
    archivedAt = $now
    archivePath = $archivePath
    taskGraph = $taskGraph
    stepLedger = $ledger
    evidence = Limit-Value $Evidence 220
  }
  $taskGraph.status = if ($taskGraph.status -eq 'completed') { 'archived' } else { $taskGraph.status }
  $taskGraph | Add-Member -NotePropertyName archivedAt -NotePropertyValue $now -Force
  $taskGraph | Add-Member -NotePropertyName archivePath -NotePropertyValue $archivePath -Force
  Write-JsonUtf8NoBom $archivePath $archive 14
  Write-JsonUtf8NoBom $archivedTaskPath $archive 14
}

if ($Action -eq 'ClearTask') {
  $openNow = @(Ensure-Array $ledger.steps | Where-Object { $_.status -eq 'open' })
  if (@($openNow).Count -gt 0 -and $taskGraph.status -notin @('completed','archived','idle')) { throw "ClearTask blocked: active task has openSteps=$(@($openNow).Count)." }
  $taskGraph = New-TaskGraph '' ''
  $taskGraph.status = 'idle'
  $ledger = [pscustomobject]@{
    schema = 'super-brain.step-ledger.v2'
    updatedAt = $now
    version = [string]$manifest.version
    taskId = ''
    goal = ''
    steps = @()
    openSteps = @()
    completedSteps = @()
    skippedSteps = @()
    guard = 'Before reporting completion, openSteps must be empty or explicitly reported as remaining/skipped with reason.'
  }
}

$findingRecord = $null
if ($Action -eq 'AddFinding') {
  if ([string]::IsNullOrWhiteSpace($Finding)) { throw 'AddFinding requires -Finding.' }
  $fid = if ([string]::IsNullOrWhiteSpace($FindingId)) { New-Id 'finding' } else { Limit-Value $FindingId 120 }
  $findingPath = Join-Path $findingsRoot "$fid.json"
  $findingRecord = [pscustomobject]@{
    schema = 'super-brain.agent-finding.v1'
    findingId = $fid
    agent = Limit-Value $(if ([string]::IsNullOrWhiteSpace($Agent)) { 'unknown-agent' } else { $Agent }) 120
    taskId = if ([string]::IsNullOrWhiteSpace($TaskId)) { [string]$taskGraph.taskId } else { Limit-Value $TaskId 120 }
    finding = Limit-Value $Finding 700
    source = Limit-Value $Source 260
    evidence = @(Limit-List @($Evidence) 8 220)
    status = 'candidate'
    admission = 'pending'
    admittedBy = ''
    admittedAt = ''
    rejectionReason = ''
    createdAt = $now
    updatedAt = $now
    guard = 'Candidate only: not formal memory until Commander/G1 admission through governed scripts.'
  }
  Write-JsonUtf8NoBom $findingPath $findingRecord 10
}

if ($Action -in @('AdmitFinding','RejectFinding')) {
  if ([string]::IsNullOrWhiteSpace($FindingId)) { throw "$Action requires -FindingId." }
  $findingPath = Join-Path $findingsRoot "$FindingId.json"
  if (-not (Test-Path -LiteralPath $findingPath)) { throw "Finding not found: $FindingId" }
  $findingRecord = Read-JsonOrNull $findingPath
  if ($null -eq $findingRecord) { throw "Finding is not valid JSON: $FindingId" }
  if ($Action -eq 'AdmitFinding') {
    $findingRecord.status = 'admitted'
    $findingRecord.admission = 'commander_admitted_candidate_only'
    $findingRecord.admittedBy = 'Commander'
    $findingRecord.admittedAt = $now
    $findingRecord.rejectionReason = ''
    $findingRecord.guard = 'Admitted for Commander summary; durable memory still requires learn-memory/write-memory governed admission.'
  } else {
    $findingRecord.status = 'rejected'
    $findingRecord.admission = 'rejected'
    $findingRecord.rejectionReason = Limit-Value $Reason 260
    $findingRecord.guard = 'Rejected candidate; do not use as formal memory.'
  }
  $findingRecord.updatedAt = $now
  Write-JsonUtf8NoBom $findingPath $findingRecord 10
}

$ledger.updatedAt = $now
$ledger.version = [string]$manifest.version
$ledger.schema = 'super-brain.step-ledger.v2'
$ledger.openSteps = @(Ensure-Array $ledger.steps | Where-Object { $_.status -eq 'open' })
$ledger.completedSteps = @(Ensure-Array $ledger.steps | Where-Object { $_.status -eq 'completed' })
$ledger.skippedSteps = @(Ensure-Array $ledger.steps | Where-Object { $_.status -eq 'skipped' })
$taskGraph.updatedAt = $now
if (@($ledger.openSteps).Count -eq 0 -and @($ledger.completedSteps).Count -gt 0 -and $taskGraph.status -eq 'active') { $taskGraph.status = 'active' }
$taskGraph.steps = @(Ensure-Array $ledger.steps)
if (-not [string]::IsNullOrWhiteSpace($Evidence)) { $taskGraph.evidence = @(Limit-List @($taskGraph.evidence + $Evidence) 30 220 | Select-Object -Unique) }

if ($Action -ne 'Status') {
  Write-JsonUtf8NoBom $projectGraphPath $projectGraph 12
  Write-JsonUtf8NoBom $structureBaselinePath $structureBaseline 12
  Write-JsonUtf8NoBom $taskGraphPath $taskGraph 12
  Write-JsonUtf8NoBom $stepLedgerPath $ledger 12
}

$findingFiles = @(Get-ChildItem -LiteralPath $findingsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
$candidateFindings = @()
$admittedFindings = @()
$rejectedFindings = @()
foreach ($file in $findingFiles) {
  $f = Read-JsonOrNull $file.FullName
  if ($null -eq $f) { continue }
  if ($f.status -eq 'candidate') { $candidateFindings += $f }
  elseif ($f.status -eq 'admitted') { $admittedFindings += $f }
  elseif ($f.status -eq 'rejected') { $rejectedFindings += $f }
}

$criticalMissing = @($keyFiles | Where-Object {
  $full = Join-Path $Root ($_ -replace '/', [System.IO.Path]::DirectorySeparatorChar)
  -not (Test-Path -LiteralPath $full)
})
$openCount = @($ledger.openSteps).Count
$statusOk = ($criticalMissing.Count -eq 0)
$result = [pscustomobject]@{
  ok = $statusOk
  checkedAt = $now
  action = $Action
  version = [string]$manifest.version
  paths = [pscustomobject]@{ projectGraph=$projectGraphPath; taskGraph=$taskGraphPath; structureBaseline=$structureBaselinePath; stepLedger=$stepLedgerPath; agentFindings=$findingsRoot; taskArchive=$taskArchiveRoot; completedTask=$completedTaskPath; archivedTask=$archivedTaskPath; status=$statusPath }
  graphNodes = @($projectGraph.nodes).Count
  graphRelations = @($projectGraph.relations).Count
  criticalFilesMissing = @($criticalMissing)
  mustPreserve = @($structureBaseline.mustPreserve)
  mustNotViolate = @($structureBaseline.mustNotViolate)
  task = [pscustomobject]@{ taskId=$taskGraph.taskId; status=$taskGraph.status; goal=$taskGraph.goal; relatedFiles=@($taskGraph.relatedFiles); verification=@($taskGraph.verification); risks=@($taskGraph.risks); completedAt=if ($taskGraph.PSObject.Properties['completedAt']) { $taskGraph.completedAt } else { '' }; archivedAt=if ($taskGraph.PSObject.Properties['archivedAt']) { $taskGraph.archivedAt } else { '' }; archivePath=if ($taskGraph.PSObject.Properties['archivePath']) { $taskGraph.archivePath } else { '' } }
  goal = $ledger.goal
  openSteps = @($ledger.openSteps)
  completedCount = @($ledger.completedSteps).Count
  skippedCount = @($ledger.skippedSteps).Count
  findingCounts = [pscustomobject]@{ candidate=@($candidateFindings).Count; admitted=@($admittedFindings).Count; rejected=@($rejectedFindings).Count }
  latestFinding = $findingRecord
  guard = 'Use project-graph + task-graph + structure-baseline + step-ledger before current-state, multi-agent, or structure-affecting work. Agent findings are candidate-only until Commander admission.'
  blockers = @(
    @($criticalMissing | ForEach-Object { "critical_file_missing:$_" }) +
    $(if ($openCount -gt 0) { @("open_steps:$openCount") } else { @() }) +
    $(if (@($candidateFindings).Count -gt 0) { @("candidate_findings_pending:$(@($candidateFindings).Count)") } else { @() })
  )
  nextAction = if ($criticalMissing.Count -gt 0) { 'Restore or account for missing critical continuity files.' } elseif ($openCount -gt 0) { 'Continue the first open step or explicitly mark skipped with reason.' } elseif (@($candidateFindings).Count -gt 0) { 'Review candidate agent findings; admit/reject before using them as durable facts.' } elseif ($taskGraph.status -eq 'completed') { 'Task completed; archive or start the next task.' } elseif ($taskGraph.status -eq 'archived') { 'Task archived; clear task or start the next task.' } elseif ($taskGraph.status -eq 'idle') { 'No active task; start a task before long/multi-step work.' } else { 'No open steps in ledger; add steps before long/multi-step work.' }
}
Write-JsonUtf8NoBom $statusPath $result 12
if ($Json) { Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 } else { Write-Host "PROJECT_CONTINUITY_OK action=$Action status=$statusPath openSteps=$openCount candidateFindings=$(@($candidateFindings).Count)" }
