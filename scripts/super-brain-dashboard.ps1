param(
  [ValidateSet('Light','Full','Team')]
  [string]$Mode = 'Light',
  [string]$WorkspaceKey = '',
  [string]$SessionKey = '',
  [switch]$Json,
  [switch]$AllowStaleVerify,
  [switch]$AllowActiveCheckpoint
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Invoke-JsonTool([string]$ScriptName) {
  try {
    $output = @(& (Join-Path $PSScriptRoot $ScriptName) -Json 6>$null)
    $jsonStart = -1
    for ($index = 0; $index -lt $output.Count; $index++) {
      if ([string]$output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
    }
    if ($jsonStart -lt 0) { throw "No JSON output from $ScriptName" }
    $jsonText = (@($output[$jsonStart..($output.Count - 1)]) -join "`n")
    return $jsonText | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{ ok=$false; error=$_.Exception.Message }
  }
}

function Limit-Text([string]$Text, [int]$Max = 180) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ([string]$Text).Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}

function Compact-Checkpoint([object]$Checkpoint) {
  if (-not $Checkpoint) { return $null }
  return [pscustomobject]@{
    status = [string]$Checkpoint.status
    taskId = [string]$Checkpoint.taskId
    currentStep = Limit-Text ([string]$Checkpoint.currentStep) 160
    phaseNextAction = Limit-Text ([string]$Checkpoint.nextAction) 220
    blockerCount = @($Checkpoint.blockers).Count
    evidenceCount = @($Checkpoint.evidence).Count
  }
}

function Compact-Snapshot([object]$Snapshot) {
  if (-not $Snapshot) { return $null }
  return [pscustomobject]@{
    checkedAt = [string]$Snapshot.checkedAt
    version = [string]$Snapshot.version
    summary = Limit-Text ([string]$Snapshot.summary) 180
    nextAction = Limit-Text ([string]$Snapshot.nextAction) 220
    risksCount = @($Snapshot.risks).Count
  }
}

function Get-DashboardEvidenceTaskId([object]$Evidence) {
  if (-not $Evidence) { return '' }
  if ($Evidence.PSObject.Properties['taskId'] -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.taskId)) { return [string]$Evidence.taskId }
  if ($Evidence.PSObject.Properties['continuity'] -and $Evidence.continuity -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.continuity.taskId)) { return [string]$Evidence.continuity.taskId }
  if ($Evidence.PSObject.Properties['executionContract'] -and $Evidence.executionContract -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.executionContract.taskId)) { return [string]$Evidence.executionContract.taskId }
  return ''
}

$manifest = Get-SuperBrainManifest $Root
$state = Read-WorkspaceJson 'super-brain-state.json'
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$currentTaskContext = Read-WorkspaceJson 'current-task-context.json'
$checkpointSelection = Get-SuperBrainRelevantCheckpoint $workspace $currentTaskContext $WorkspaceKey
$activeCheckpoint = $checkpointSelection.checkpoint
$currentTaskContext = $checkpointSelection.context
$lastStatusSnapshot = Read-WorkspaceJson 'last-status-snapshot.json'
$statusCard = Read-WorkspaceJson 'status-card.json'
$selectedWorkspaceKey = [string]$checkpointSelection.workspaceKey
$hostSessionKey = Get-SuperBrainHostSessionKey $SessionKey
$scopedSnapshot = Read-WorkspaceJson (Join-Path (Join-Path 'runtime-state\workspaces' $selectedWorkspaceKey) 'last-status-snapshot.json')
$scopedStatusCard = Read-WorkspaceJson (Join-Path (Join-Path 'runtime-state\workspaces' $selectedWorkspaceKey) 'status-card.json')
if ($scopedSnapshot) { $lastStatusSnapshot = $scopedSnapshot }
if ($scopedStatusCard) { $statusCard = $scopedStatusCard }
$snapshotWorkspaceMatch = ($lastStatusSnapshot -and $lastStatusSnapshot.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$lastStatusSnapshot.workspaceKey) $selectedWorkspaceKey))
$statusCardWorkspaceMatch = ($statusCard -and $statusCard.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$statusCard.workspaceKey) $selectedWorkspaceKey))
$executionResolution = $null
$executionResolutionFailed = $false
$executionResolutionFailureCode = ''
$executionResolutionNoContract = $false
$activeTaskId = if ($activeCheckpoint) { [string]$activeCheckpoint.taskId } elseif ($currentTaskContext) { [string]$currentTaskContext.taskId } else { '' }
try {
  $contractArgs = @{Action='Resolve';WorkspaceKey=([string]$checkpointSelection.workspaceKey);SessionKey=$hostSessionKey;NoExit=$true;Json=$true}
  $contractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') @contractArgs 2>$null)
  if (-not $contractRaw) { throw 'execution contract returned no JSON' }
  $candidateResolution = (($contractRaw -join "`n") | ConvertFrom-Json)
  if (-not $candidateResolution -or $candidateResolution.ok -ne $true) {
    $executionResolutionFailed = $true
    $executionResolutionFailureCode = if ($candidateResolution) { [string]$candidateResolution.code } else { 'EXECUTION_CONTRACT_EMPTY_RESULT' }
  } else {
    $executionResolutionNoContract = ([string]$candidateResolution.resolutionSource -eq 'none' -and [string]$candidateResolution.actionAuthorization -eq 'not_applicable')
    $executionScopeMatch = ($executionResolutionNoContract -or (-not [string]::IsNullOrWhiteSpace([string]$candidateResolution.taskId) -and (Test-SuperBrainWorkspaceKey ([string]$candidateResolution.workspaceKey) $selectedWorkspaceKey)))
    if ($executionScopeMatch) { $executionResolution = $candidateResolution }
    else { $executionResolutionFailed = $true; $executionResolutionFailureCode = 'EXECUTION_CONTRACT_SCOPE_MISMATCH' }
  }
} catch {
  $executionResolution = $null
  $executionResolutionFailed = $true
  if ([string]::IsNullOrWhiteSpace($executionResolutionFailureCode)) { $executionResolutionFailureCode = 'EXECUTION_CONTRACT_RESOLVE_FAILED' }
}
if ($executionResolution -and [string]$executionResolution.taskId -ne $activeTaskId) {
  $activeTaskId = [string]$executionResolution.taskId
  $checkpointSelection = Get-SuperBrainRelevantCheckpoint $workspace $currentTaskContext $selectedWorkspaceKey $activeTaskId
  $activeCheckpoint = $checkpointSelection.checkpoint
}
$snapshotTaskMatch = ($snapshotWorkspaceMatch -and -not [string]::IsNullOrWhiteSpace($activeTaskId) -and (Get-DashboardEvidenceTaskId $lastStatusSnapshot) -eq $activeTaskId)
$statusCardTaskMatch = ($statusCardWorkspaceMatch -and -not [string]::IsNullOrWhiteSpace($activeTaskId) -and (Get-DashboardEvidenceTaskId $statusCard) -eq $activeTaskId)
$lastTaskTaskMatch = ($lastTask -and $lastTask.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$lastTask.workspaceKey) $selectedWorkspaceKey) -and -not [string]::IsNullOrWhiteSpace($activeTaskId) -and (Get-DashboardEvidenceTaskId $lastTask) -eq $activeTaskId)

$roadmap = [pscustomobject]@{ ok=$null; completedVersions=@(); remainingVersions=@(); roadmapFound=$null }
$taskState = [pscustomobject]@{ ok=$null }
$memoryRegression = [pscustomobject]@{ ok=$null; failed=0; total=0 }
$privacy = [pscustomobject]@{ ok=$null; privatePatternHits=0; shareSafe=$null }
$reviewGate = [pscustomobject]@{ ok=$null; blockerCount=0 }

if ($Mode -in @('Full','Team')) {
  $roadmap = Invoke-JsonTool 'roadmap-manager.ps1'
  $taskState = Invoke-JsonTool 'task-state-reporter.ps1'
  $memoryRegression = Invoke-JsonTool 'memory-regression-checker.ps1'
  $privacy = Invoke-JsonTool 'privacy-sentinel.ps1'
}
if ($Mode -eq 'Team') {
  $reviewGate = Invoke-JsonTool 'team-task-review-gate.ps1'
}

$risks = @()
if (-not ($lastVerify -and $lastVerify.ok -eq $true) -and -not $AllowStaleVerify) { $risks += 'last_verify_not_ok' }
if (-not ($lastHotRefresh -and $lastHotRefresh.ok -eq $true)) { $risks += 'last_hot_refresh_not_ok' }
if ($activeCheckpoint -and [string]$activeCheckpoint.status -eq 'active' -and -not $AllowActiveCheckpoint) { $risks += 'active_checkpoint_present' }
if ($Mode -in @('Full','Team')) {
  if ($privacy -and $privacy.privatePatternHits -gt 0) { $risks += 'privacy_private_pattern_hits' }
  if ($memoryRegression -and $memoryRegression.failed -gt 0) { $risks += 'memory_regression_failed' }
}
if ($Mode -eq 'Team') {
  if ($reviewGate -and $reviewGate.blockerCount -gt 0) { $risks += 'review_gate_blockers' }
}

$dashboardNextAction = ''
$dashboardNextActionSource = 'none'
$activeExecutionPlan = if ($executionResolution -and $executionResolution.workLineStatus) { $executionResolution.workLineStatus.activePlan } else { $null }
$executionResolutionUnavailable = ($executionResolutionFailed -or (-not $executionResolutionNoContract -and -not [string]::IsNullOrWhiteSpace($activeTaskId) -and -not $executionResolution))
$executionAuthorizationWithheld = ($executionResolutionFailed -or (-not $executionResolutionNoContract -and $executionResolution -and ($executionResolution.actionAuthorization -ne 'allowed' -or $executionResolution.claimAllowed -ne $true -or $executionResolution.needsConfirmation -eq $true)))
$hasConcreteExecutionPlan = (-not $executionAuthorizationWithheld -and $activeExecutionPlan -and $activeExecutionPlan.hasConcreteNextAction -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$activeExecutionPlan.nextAction))
if ($executionAuthorizationWithheld -or $executionResolutionNoContract) {
  $activeCheckpoint = Remove-SuperBrainExecutableActions $activeCheckpoint
  $statusCard = Remove-SuperBrainExecutableActions $statusCard
  $lastStatusSnapshot = Remove-SuperBrainExecutableActions $lastStatusSnapshot
  $lastTask = Remove-SuperBrainExecutableActions $lastTask
}
if ($executionAuthorizationWithheld) {
  $dashboardNextAction = if ($executionResolutionFailed) { 'Execution contract resolution failed. Repair or re-run the resolver before mutation.' } elseif (-not [string]::IsNullOrWhiteSpace([string]$executionResolution.nextAction)) { [string]$executionResolution.nextAction } else { 'Execution action is withheld. Reconcile session ownership or the latest instruction before mutation.' }
  $dashboardNextActionSource = if ($executionResolutionFailed) { 'execution_resolution_failed' } elseif ($executionResolution) { [string]$executionResolution.resumeFrom } else { 'execution_resolution_unavailable' }
} elseif ($executionResolution -and [string]$executionResolution.resumeFrom -eq 'execution_contract_pending_reconciliation') {
  $dashboardNextAction = [string]$executionResolution.nextAction
  $dashboardNextActionSource = 'execution_contract_reconciliation'
} elseif ($executionResolution -and [string]$executionResolution.resumeFrom -in @('execution_contract','parent_return','visible_conversation') -and $hasConcreteExecutionPlan) {
  $dashboardNextAction = [string]$activeExecutionPlan.nextAction
  $dashboardNextActionSource = [string]$executionResolution.resumeFrom
} elseif ($executionResolution -and [string]$executionResolution.resumeFrom -in @('execution_contract','parent_return','visible_conversation','checkpoint_state_only','unknown')) {
  $dashboardNextAction = 'Latest execution action is unknown. Confirm or reconcile the current task contract before mutation.'
  $dashboardNextActionSource = 'execution_plan_missing'
} elseif ($activeCheckpoint) {
  $dashboardNextAction = 'Latest execution action is unknown. Confirm or reconcile the current task contract before mutation.'
  $dashboardNextActionSource = 'checkpoint_state_only'
} elseif ($snapshotTaskMatch -and -not [string]::IsNullOrWhiteSpace([string]$lastStatusSnapshot.nextAction)) {
  $dashboardNextAction = [string]$lastStatusSnapshot.nextAction
  $dashboardNextActionSource = 'task_workspace_snapshot'
} elseif ($risks.Count -eq 0) {
  $dashboardNextAction = 'Ready for next roadmap item or user task.'
  $dashboardNextActionSource = 'dashboard_default'
} else {
  $dashboardNextAction = 'Resolve dashboard risks before declaring completion.'
  $dashboardNextActionSource = 'dashboard_risks'
}
$dashboardNextAction = Limit-Text $dashboardNextAction 220
$compactExecutionResolution = ConvertTo-SuperBrainCompactExecutionResolution $executionResolution

$result = [pscustomobject]@{
  ok = ($risks.Count -eq 0)
  mode = $Mode
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $manifest.version
  packageRoot = $Root
  stateOk = if ($state) { $state.ok } else { $null }
  verify = [pscustomobject]@{ ok=if ($lastVerify) { $lastVerify.ok } else { $null }; checkedAt=if ($lastVerify) { $lastVerify.checkedAt } else { '' }; version=if ($lastVerify) { $lastVerify.version } else { '' } }
  hotRefresh = [pscustomobject]@{ ok=if ($lastHotRefresh) { $lastHotRefresh.ok } else { $null }; checkedAt=if ($lastHotRefresh) { $lastHotRefresh.checkedAt } else { '' } }
  roadmap = [pscustomobject]@{ ok=$roadmap.ok; completedVersions=@($roadmap.completedVersions); remainingVersions=@($roadmap.remainingVersions); found=$roadmap.roadmapFound }
  task = [pscustomobject]@{ summary=if ($lastTaskTaskMatch) { Limit-Text ([string]$lastTask.summary) 180 } else { '' }; ok=if ($lastTaskTaskMatch) { $lastTask.ok } else { $null }; teamTask=if ($lastTaskTaskMatch) { $lastTask.teamTask } else { $null } }
  memoryRegression = [pscustomobject]@{ ok=$memoryRegression.ok; failed=$memoryRegression.failed; total=$memoryRegression.total }
  privacy = [pscustomobject]@{ ok=$privacy.ok; privatePatternHits=$privacy.privatePatternHits; shareSafe=$privacy.shareSafe }
  reviewGate = [pscustomobject]@{ ok=$reviewGate.ok; blockerCount=$reviewGate.blockerCount }
  statusCard = if ($statusCardTaskMatch) { [pscustomobject]@{ ok=$statusCard.ok; updatedAt=$statusCard.updatedAt; taskId=$activeTaskId; nextAction=Limit-Text ([string]$statusCard.nextAction) 220 } } else { $null }
  checkpointSelection = [pscustomobject]@{ state=$checkpointSelection.state; contextState=$checkpointSelection.contextState; workspaceKey=$checkpointSelection.workspaceKey; source=$checkpointSelection.source; candidateTaskId=$checkpointSelection.candidateTaskId; ignoredTaskId=$checkpointSelection.ignoredTaskId }
  activeCheckpoint = Compact-Checkpoint $activeCheckpoint
  executionResolution = $compactExecutionResolution
  continuityStateCard = if ($compactExecutionResolution) { $compactExecutionResolution.continuityStateCard } else { $null }
  executionResolutionStatus = if($executionResolutionFailed){'failed'}elseif($executionResolutionNoContract){'no_contract'}elseif($executionAuthorizationWithheld){'withheld'}else{'allowed'}
  executionResolutionFailureCode = $executionResolutionFailureCode
  workLineStatus = if ($compactExecutionResolution) { $compactExecutionResolution.workLineStatus } else { $null }
  latestMessageClassification = if ($compactExecutionResolution) { $compactExecutionResolution.latestMessageClassification } else { $null }
  mutationAuthorized = ($executionResolution -and $executionResolution.actionAuthorization -eq 'allowed' -and $executionResolution.claimAllowed -eq $true -and $executionResolution.needsConfirmation -ne $true)
  lastStatusSnapshot = if ($snapshotTaskMatch) { Compact-Snapshot $lastStatusSnapshot } else { $null }
  risks = @($risks)
  nextAction = $dashboardNextAction
  nextActionSource = $dashboardNextActionSource
}

if ($Json) {
  $result | ConvertTo-Json -Depth 12
} else {
  Write-Host "SUPER_BRAIN_DASHBOARD mode=$($result.mode) ok=$($result.ok) version=$($result.version) risks=$($risks.Count)"
  Write-Host "STATE version=$($result.version) verify=$($result.verify.ok) hotRefresh=$($result.hotRefresh.ok) memoryRegression=$($result.memoryRegression.ok) privacy=$($result.privacy.ok) reviewGate=$($result.reviewGate.ok)"
  Write-Host "ROADMAP completed=$(@($result.roadmap.completedVersions) -join ',') remaining=$(@($result.roadmap.remainingVersions) -join ',')"
  Write-Host "TASK $($result.task.summary)"
  if ($risks.Count -gt 0) { Write-Host "RISKS $($risks -join ',')" } else { Write-Host "RISKS none" }
  Write-Host "NEXT $($result.nextAction)"
}
if (-not $result.ok) { exit 1 }
exit 0
