param(
  [ValidateSet('BeforeAct','BeforeMutation','BeforeCompletion','AfterUserCorrection','Status','Clear')]
  [string]$Phase = 'BeforeAct',
  [string]$ObservedAction = '',
  [string]$Query = '',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [int]$MaxAgeMinutes = 120,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$taskIdValue = if ([string]::IsNullOrWhiteSpace($TaskId)) { '' } else { $TaskId.Trim() }
$workspaceKeyValue = if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { '' } else { Get-SuperBrainWorkspaceKey $WorkspaceKey }
$hasTaskScope = (-not [string]::IsNullOrWhiteSpace($taskIdValue) -and -not [string]::IsNullOrWhiteSpace($workspaceKeyValue))
$legacyStatePath = Join-Path $workspace 'runtime-drift-checkpoint.json'
$scopedStateRoot = Join-Path $workspace 'guard-state\runtime-drift-checkpoints'
$v2ScopedStatePath = if ($hasTaskScope) { Get-SuperBrainCanonicalTaskPath $scopedStateRoot $taskIdValue '.json' } else { '' }
$statePath = if ($hasTaskScope) { Get-SuperBrainTaskWorkspaceArtifactPath $scopedStateRoot $taskIdValue $workspaceKeyValue '.json' } else { $legacyStatePath }
$outPath = if ($hasTaskScope) { $statePath } else { $legacyStatePath }
$schema = if ([string]::IsNullOrWhiteSpace($taskIdValue)) { 'super-brain.runtime-drift-checkpoint.v1' } else { 'super-brain.runtime-drift-checkpoint.v2' }

function Limit-Text([string]$Value, [int]$Max = 260) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}

function Read-JsonPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Read-WorkspaceJson([string]$Name) {
  return Read-JsonPath (Join-Path $workspace $Name)
}

function Test-ExactTaskWorkspace($Value) {
  if (-not $Value -or [string]::IsNullOrWhiteSpace($taskIdValue)) { return $false }
  if (-not $Value.PSObject.Properties['taskId'] -or -not [string]::Equals([string]$Value.taskId, $taskIdValue, [StringComparison]::Ordinal)) { return $false }
  if ([string]::IsNullOrWhiteSpace($workspaceKeyValue)) { return $true }
  if (-not $Value.PSObject.Properties['workspaceKey'] -or [string]::IsNullOrWhiteSpace([string]$Value.workspaceKey)) { return $false }
  return Test-SuperBrainWorkspaceKey ([string]$Value.workspaceKey) $workspaceKeyValue
}

function Read-RelevantLedger {
  $selection = Get-SuperBrainRelevantStepLedger $workspace $taskIdValue $workspaceKeyValue -AllowLegacyRead
  if ($selection -and $selection.ledger -and (Test-ExactTaskWorkspace $selection.ledger)) { return $selection.ledger }
  return $null
}

function Read-RelevantCheckpoint {
  if ([string]::IsNullOrWhiteSpace($taskIdValue)) { return Read-WorkspaceJson 'active-checkpoint.json' }
  $checkpointRoot = Join-Path $workspace 'runtime-state\checkpoints\active'
  $scoped = Read-JsonPath (Get-SuperBrainCanonicalTaskPath $checkpointRoot $taskIdValue '.json')
  if (Test-ExactTaskWorkspace $scoped) { return $scoped }
  $legacyPointer = Read-WorkspaceJson 'active-checkpoint.json'
  if (Test-ExactTaskWorkspace $legacyPointer) { return $legacyPointer }
  return $null
}

function Read-PreviousState {
  $value = Read-JsonPath $statePath
  if ([string]::IsNullOrWhiteSpace($taskIdValue) -or (Test-ExactTaskWorkspace $value)) { return $value }
  if ($hasTaskScope) {
    $legacyScoped = Read-JsonPath $v2ScopedStatePath
    if (Test-ExactTaskWorkspace $legacyScoped) { return $legacyScoped }
  }
  return $null
}

function Is-Fresh($Obj) {
  if (-not $Obj -or -not $Obj.checkedAt) { return $false }
  try { return (((Get-Date) - [datetime]::Parse([string]$Obj.checkedAt)).TotalMinutes -le $MaxAgeMinutes) } catch { return $false }
}

function Add-Violation([System.Collections.ArrayList]$Violations, [string]$Code, [string]$Evidence, [string]$Severity = 'high') {
  [void]$Violations.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $Evidence 360 })
}

if ($Phase -ne 'Status' -and -not $hasTaskScope) {
  $scopeRequired = [pscustomobject]@{
    ok = $false
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    schema = 'super-brain.runtime-drift-checkpoint.v2'
    version = (Get-SuperBrainManifest $Root).version
    phase = $Phase
    status = 'scope_required'
    unresolvedDrift = $true
    taskId = Limit-Text $taskIdValue 120
    workspaceKey = $workspaceKeyValue
    violations = @([pscustomobject]@{ code='missing_task_scope'; severity='high'; evidence='TaskId and WorkspaceKey are required before a runtime drift checkpoint may write state.' })
    blockers = @('DRIFT_TASK_SCOPE_REQUIRED')
    guard = 'Unscoped runtime drift writes are retired. Status may read legacy state, but every mutation must target one task and workspace.'
    nextAction = 'Resolve the current task and workspace key, then re-run the checkpoint with both values.'
    path = ''
  }
  if ($Json) { $scopeRequired | ConvertTo-Json -Depth 10 } else { Write-Host 'RUNTIME_DRIFT_CHECKPOINT ok=False status=scope_required code=DRIFT_TASK_SCOPE_REQUIRED' }
  exit 1
}

if ($Phase -ne 'Status' -and -not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

if ($Phase -eq 'Status') {
  $stored = Read-PreviousState
  if ($stored) {
    if ($Json) { $stored | ConvertTo-Json -Depth 10 } else { Write-Host "RUNTIME_DRIFT_CHECKPOINT ok=$($stored.ok) phase=$($stored.phase) status=$($stored.status) path=$statePath" }
    if ($stored.ok -eq $true) { exit 0 }
    exit 1
  }
  $result = [pscustomobject]@{
    ok = $false
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    schema = $schema
    version = (Get-SuperBrainManifest $Root).version
    phase = $Phase
    status = 'missing'
    unresolvedDrift = $false
    taskId = Limit-Text $taskIdValue 120
    workspaceKey = $workspaceKeyValue
    violations = @()
    blockers = @()
    guard = 'Status is read-only and does not evaluate or create runtime drift state.'
    nextAction = 'Run a runtime drift checkpoint before the next guarded action.'
    path = $statePath
  }
  if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "RUNTIME_DRIFT_CHECKPOINT ok=False phase=Status status=missing path=$statePath" }
  exit 1
}

if ($Phase -eq 'Clear') {
  $result = [pscustomobject]@{
    ok = $true
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    schema = $schema
    version = (Get-SuperBrainManifest $Root).version
    phase = $Phase
    status = 'resolved'
    unresolvedDrift = $false
    taskId = Limit-Text $taskIdValue 120
    workspaceKey = $workspaceKeyValue
    violations = @()
    blockers = @()
    guard = 'DRIFT_DETECTED issues were cleared after correction.'
    nextAction = 'Continue with a fresh cognitive preflight before new high-risk actions.'
    path = $statePath
  }
  Write-JsonUtf8NoBom $statePath $result 10
  Write-JsonUtf8NoBom $outPath $result 10
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "RUNTIME_DRIFT_CHECKPOINT ok=True status=resolved path=$statePath" }
  exit 0
}

$preflight = Read-WorkspaceJson 'last-cognitive-preflight.json'
$enforce = Read-WorkspaceJson 'last-cognitive-enforce.json'
$constraints = Read-WorkspaceJson 'last-accepted-constraints-preflight.json'
$ledger = Read-RelevantLedger
$activeCheckpoint = Read-RelevantCheckpoint
$previous = Read-PreviousState

$violations = New-Object System.Collections.ArrayList
$blockers = New-Object System.Collections.ArrayList
$lowerAction = ($ObservedAction + ' ' + $Query).ToLowerInvariant()

if (-not (Is-Fresh $preflight)) { Add-Violation $violations 'missing_or_stale_cognitive_preflight' 'cognitive-preflight missing or stale before runtime action' }
$enforceTaskId = if($enforce -and $enforce.engineeringJudgment -and $enforce.engineeringJudgment.PSObject.Properties['taskId']){[string]$enforce.engineeringJudgment.taskId}else{''}
$enforceTaskMatch = [string]::IsNullOrWhiteSpace($taskIdValue) -or [string]::IsNullOrWhiteSpace($enforceTaskId) -or [string]::Equals($enforceTaskId,$taskIdValue,[StringComparison]::Ordinal)
$enforceApplies = $enforce -and (Is-Fresh $enforce) -and $enforceTaskMatch -and ([string]::IsNullOrWhiteSpace($Query) -or [string]$enforce.query -eq $Query)
if ($enforceApplies -and $enforce.ok -ne $true) { Add-Violation $violations 'cognitive_enforce_failed' "violations=$(@($enforce.violations).Count) query=$($enforce.query)" }
$constraintsApply = $constraints -and ([string]::IsNullOrWhiteSpace($Query) -or -not $constraints.PSObject.Properties['query'] -or [string]$constraints.query -eq $Query)
if ($constraintsApply -and @($constraints.conflicts).Count -gt 0) { Add-Violation $violations 'accepted_constraint_conflict' "conflicts=$(@($constraints.conflicts).Count) guardHash=$($constraints.guardHash)" }

if ($Phase -eq 'BeforeCompletion') {
  $openCount = if ($ledger) { @($ledger.openSteps | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) }).Count } elseif ($activeCheckpoint) { @($activeCheckpoint.pendingSteps | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) }).Count } else { 0 }
  $blockedCount = if ($ledger) { @($ledger.blockedSteps | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) }).Count } elseif ($activeCheckpoint) { @($activeCheckpoint.blockers | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) }).Count } else { 0 }
  if ($openCount -gt 0 -or $blockedCount -gt 0) { Add-Violation $violations 'completion_with_open_or_blocked_steps' "openSteps=$openCount blockedSteps=$blockedCount" }
  if ($activeCheckpoint -and [string]$activeCheckpoint.status -eq 'active') { Add-Violation $violations 'completion_with_active_checkpoint' "taskId=$($activeCheckpoint.taskId) status=$($activeCheckpoint.status)" 'medium' }
}

$guards = if ($preflight) { @($preflight.driftGuards) } else { @() }
if ($guards -contains 'nested_agent_launch' -and ($lowerAction -match 'nested|worker|explorer|helper|tesla|launch agent|create agent')) { Add-Violation $violations 'nested_agent_launch' 'AgentBridge target-mode command must not launch nested agents/workers/helpers/Tesla.' }
if ($guards -contains 'old_channel_reuse' -and ($lowerAction -match 'reuse|last channel|active channel|old channel')) { Add-Violation $violations 'old_channel_reuse' 'Open must create a fresh channel unless user explicitly supplies ChannelId.' }
if ($guards -contains 'open_as_completion' -and ($lowerAction -match 'open.*complete|goal completed|目标完成')) { Add-Violation $violations 'open_as_completion' 'AgentBridge Open is persistent target-mode wait state, not completion.' }
if ($guards -contains 'idle_as_blocked' -and ($lowerAction -match 'idle.*blocked|timeout.*blocked|paused|failed')) { Add-Violation $violations 'idle_as_blocked' 'WaitConnect/WaitInbox idle is quiet waiting, not blocked/paused/failed.' }
if ($guards -contains 'reply_as_goal_completed' -and ($lowerAction -match 'reply.*complete|goal completed|目标完成')) { Add-Violation $violations 'reply_as_goal_completed' 'One reply must return to WaitInbox, not mark goal complete.' }
if ($guards -contains 'auto_close_without_explicit_close' -and ($lowerAction -match 'auto.?close|close.*without')) { Add-Violation $violations 'auto_close_without_explicit_close' 'AgentBridge channel closes only on explicit close.' }

foreach ($v in @($violations)) { [void]$blockers.Add("$($v.code): $($v.evidence)") }
$status = if ($violations.Count -gt 0) { 'drift_detected' } elseif ($previous -and $previous.unresolvedDrift -eq $true) { 'drift_detected' } else { 'clean' }
$unresolved = ($status -eq 'drift_detected')

$result = [pscustomobject]@{
  ok = (-not $unresolved)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = $schema
  version = (Get-SuperBrainManifest $Root).version
  phase = $Phase
  status = $status
  unresolvedDrift = $unresolved
  taskId = Limit-Text $taskIdValue 120
  workspaceKey = $workspaceKeyValue
  query = Limit-Text $Query 260
  observedAction = Limit-Text $ObservedAction 260
  intent = if ($preflight) { $preflight.intent } else { 'unknown' }
  guardHash = if ($constraints) { $constraints.guardHash } else { '' }
  expectedGuards = @($guards)
  violations = @($violations)
  blockers = @($blockers)
  candidateSignals = @($violations | ForEach-Object { [pscustomobject]@{ candidateType='logic_breakpoint'; breakpointKind=if($_.code -eq 'completion_with_open_or_blocked_steps'){'false_completion'}elseif($_.code -eq 'missing_or_stale_cognitive_preflight'){'missing_preflight'}else{'guard_recalled_but_not_applied'}; severity=$_.severity; code=$_.code; expectedInvariant='Runtime action must obey cognitive preflight, accepted constraints, open-step state, and drift guards.'; observedViolation=$_.evidence; evidence=@('last-runtime-drift-checkpoint.json','last-cognitive-preflight.json') } })
  guard = 'DRIFT_DETECTED means stop, return to accepted constraints, correct the action, then continue only after a clean checkpoint.'
  nextAction = if ($unresolved) { 'Report DRIFT_DETECTED, stop the unsafe action, refresh cognitive preflight/constraints, and resolve with -Phase Clear only after correction.' } else { 'No runtime drift detected; continue and re-check before mutation/completion.' }
  path = $statePath
}

Write-JsonUtf8NoBom $statePath $result 12
Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "RUNTIME_DRIFT_CHECKPOINT ok=$($result.ok) phase=$Phase status=$status violations=$(@($result.violations).Count) path=$statePath" }
if (-not $result.ok) { exit 1 }
exit 0
