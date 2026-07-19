param(
  [string]$Summary = '',
  [string]$NextAction = '',
  [string]$WorkspaceKey = '',
  [string[]]$Evidence = @(),
  [switch]$ClearCheckpoint,
  [switch]$AllowActiveCheckpoint,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
New-Item -ItemType Directory -Force -Path $workspace | Out-Null

function Invoke-JsonTool([string]$ScriptName,[hashtable]$Parameters=@{}) {
  try {
    $output = @(& (Join-Path $PSScriptRoot $ScriptName) @Parameters -Json 6>$null)
    $jsonStart = -1
    for ($index = 0; $index -lt $output.Count; $index++) { if ([string]$output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break } }
    if ($jsonStart -lt 0) { throw "No JSON output from $ScriptName" }
    $jsonText = (@($output[$jsonStart..($output.Count - 1)]) -join "`n")
    return $jsonText | ConvertFrom-Json
  } catch { return [pscustomobject]@{ ok=$false; error=$_.Exception.Message } }
}
function Read-WorkspaceJson([string]$Name) { $p = Join-Path $workspace $Name; if (-not (Test-Path $p)) { return $null }; try { Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
function Limit-Text([string]$Text, [int]$Max = 180) { if ([string]::IsNullOrWhiteSpace($Text)) { return '' }; $value=([string]$Text).Trim(); if ($value.Length -gt $Max) { return $value.Substring(0,$Max)+'...' }; return $value }
function Limit-List([object[]]$Items, [int]$MaxItems = 8, [int]$MaxChars = 160) { @(@($Items) | Select-Object -First $MaxItems | ForEach-Object { Limit-Text ([string]$_) $MaxChars }) }
function ConvertTo-StatusStateCard([object]$Card) {
  if (-not $Card) { return $null }
  return [pscustomobject]@{
    schema = Limit-Text ([string]$Card.schema) 80
    taskId = Limit-Text ([string]$Card.taskId) 160
    workspaceKey = Limit-Text ([string]$Card.workspaceKey) 64
    revision = [int]$Card.revision
    stateFingerprint = Limit-Text ([string]$Card.stateFingerprint) 32
    mainLineId = Limit-Text ([string]$Card.mainLineId) 120
    activeLineId = Limit-Text ([string]$Card.activeLineId) 120
    activeLineLabel = Limit-Text ([string]$Card.activeLineLabel) 100
    parentLineId = Limit-Text ([string]$Card.parentLineId) 120
    lineRole = Limit-Text ([string]$Card.lineRole) 32
    phase = Limit-Text ([string]$Card.phase) 100
    currentStep = Limit-Text ([string]$Card.currentStep) 160
    completedSteps = @(Limit-List @($Card.completedSteps) 4 120)
    pendingSteps = @(Limit-List @($Card.pendingSteps) 4 120)
    blockers = @(Limit-List @($Card.blockers) 3 120)
    priorityOrder = @($Card.priorityOrder | Select-Object -First 4 | ForEach-Object { [pscustomobject]@{ executionRank=[int]$_.executionRank; focusId=Limit-Text ([string]$_.focusId) 100; role=Limit-Text ([string]$_.role) 32 } })
    suspendedLineIds = @(Limit-List @($Card.suspendedLineIds) 4 100)
    unfinishedLineIds = @(Limit-List @($Card.unfinishedLineIds) 4 100)
    nextAction = Limit-Text ([string]$Card.nextAction) 180
    capturedAt = Limit-Text ([string]$Card.capturedAt) 48
  }
}
function Test-SnapshotScopedEvidence([object]$Evidence,[string]$TaskId,[string]$CurrentWorkspaceKey) {
  return ($Evidence -and -not [string]::IsNullOrWhiteSpace($TaskId) -and $Evidence.PSObject.Properties['taskId'] -and [string]$Evidence.taskId -eq $TaskId -and $Evidence.PSObject.Properties['workspaceKey'] -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.workspaceKey) -and (Test-SuperBrainWorkspaceKey ([string]$Evidence.workspaceKey) $CurrentWorkspaceKey))
}

$dashboardParameters = @{}
if ($AllowActiveCheckpoint) { $dashboardParameters.AllowActiveCheckpoint = $true }
if (-not [string]::IsNullOrWhiteSpace($WorkspaceKey)) { $dashboardParameters.WorkspaceKey = $WorkspaceKey }
$dashboard = Invoke-JsonTool 'super-brain-dashboard.ps1' $dashboardParameters
$executionResolution = if ($dashboard -and $dashboard.PSObject.Properties['executionResolution']) { $dashboard.executionResolution } else { $null }
$contractStateCard = if ($executionResolution -and $executionResolution.PSObject.Properties['continuityStateCard']) { ConvertTo-StatusStateCard $executionResolution.continuityStateCard } else { $null }
$workspaceKeyValue = if ($dashboard -and $dashboard.checkpointSelection) { [string]$dashboard.checkpointSelection.workspaceKey } else { Get-SuperBrainWorkspaceKey $WorkspaceKey }
$contractPlan = if ($executionResolution -and $executionResolution.workLineStatus) { $executionResolution.workLineStatus.activePlan } else { $null }
$contractPlanConcrete = ($contractPlan -and $contractPlan.hasConcreteNextAction -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$contractPlan.nextAction))
$contractWorkspaceMatch = ($executionResolution -and $executionResolution.ok -eq $true -and [string]$executionResolution.resumeFrom -in @('visible_conversation','execution_contract','execution_contract_pending_reconciliation','parent_return') -and -not [string]::IsNullOrWhiteSpace([string]$executionResolution.taskId) -and (Test-SuperBrainWorkspaceKey ([string]$executionResolution.workspaceKey) $workspaceKeyValue))
$contractNextAction = if ($contractWorkspaceMatch -and [string]$executionResolution.resumeFrom -eq 'execution_contract_pending_reconciliation') { [string]$executionResolution.nextAction } elseif ($contractWorkspaceMatch -and $contractPlanConcrete) { [string]$contractPlan.nextAction } else { '' }
if ([string]::IsNullOrWhiteSpace($Summary)) { $Summary = if ($dashboard.task -and -not [string]::IsNullOrWhiteSpace([string]$dashboard.task.summary)) { $dashboard.task.summary } else { 'Super Brain status snapshot' } }
if ($contractWorkspaceMatch -and -not [string]::IsNullOrWhiteSpace($contractNextAction)) { $NextAction = $contractNextAction }
elseif ([string]::IsNullOrWhiteSpace($NextAction)) { $NextAction = if ($dashboard.nextAction) { $dashboard.nextAction } else { 'Continue from dashboard state.' } }

$continuityStatus = Read-WorkspaceJson 'last-project-continuity.json'
$currentTaskContext = Read-WorkspaceJson 'current-task-context.json'
$checkpointSelection = Get-SuperBrainRelevantCheckpoint $workspace $currentTaskContext $WorkspaceKey
$activeCheckpoint = $checkpointSelection.checkpoint
$currentTaskContext = $checkpointSelection.context
$workspaceKeyValue = [string]$checkpointSelection.workspaceKey
$contractWorkspaceMatch = ($executionResolution -and $executionResolution.ok -eq $true -and [string]$executionResolution.resumeFrom -in @('visible_conversation','execution_contract','execution_contract_pending_reconciliation','parent_return') -and -not [string]::IsNullOrWhiteSpace([string]$executionResolution.taskId) -and (Test-SuperBrainWorkspaceKey ([string]$executionResolution.workspaceKey) $workspaceKeyValue))
$contractNextAction = if ($contractWorkspaceMatch -and [string]$executionResolution.resumeFrom -eq 'execution_contract_pending_reconciliation') { [string]$executionResolution.nextAction } elseif ($contractWorkspaceMatch -and $contractPlanConcrete) { [string]$contractPlan.nextAction } else { '' }
if ($contractWorkspaceMatch) {
  $NextAction = if (-not [string]::IsNullOrWhiteSpace($contractNextAction)) { $contractNextAction } else { 'Latest execution action is unknown. Confirm or reconcile the current task contract before mutation.' }
}
if ($ClearCheckpoint -and $activeCheckpoint) { try { & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Clear -TaskId ([string]$activeCheckpoint.taskId) -WorkspaceKey $workspaceKeyValue | Out-Null } catch {} }
$taskGraph = Read-WorkspaceJson 'task-graph.json'
$stepLedger = Read-WorkspaceJson 'step-ledger.json'
$impact = Read-WorkspaceJson 'last-impact-advisor.json'
$codegraph = Read-WorkspaceJson 'last-codegraph-index.json'

$activeCheckpointUsable = ($activeCheckpoint -and $checkpointSelection.state -in @('relevant','legacy_compatible') -and [string]$activeCheckpoint.status -eq 'active' -and -not [string]::IsNullOrWhiteSpace([string]$activeCheckpoint.taskId))
$currentTaskContextUsable = ($currentTaskContext -and [string]$currentTaskContext.status -eq 'active' -and $currentTaskContext.stale -ne $true -and -not [string]::IsNullOrWhiteSpace([string]$currentTaskContext.taskId))
if ($currentTaskContextUsable -and $currentTaskContext.expiresAt) {
  try { $currentTaskContextUsable = ([datetime]::Parse([string]$currentTaskContext.expiresAt) -gt (Get-Date)) } catch { $currentTaskContextUsable = $false }
}
$taskGraphWorkspaceMatch = ($taskGraph -and $taskGraph.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$taskGraph.workspaceKey) $workspaceKeyValue))
$stepLedgerWorkspaceMatch = ($stepLedger -and $stepLedger.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$stepLedger.workspaceKey) $workspaceKeyValue))
$continuityStatusWorkspaceMatch = ($continuityStatus -and $continuityStatus.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$continuityStatus.workspaceKey) $workspaceKeyValue))
$activeTaskId = if ($contractWorkspaceMatch) { [string]$executionResolution.taskId } elseif ($activeCheckpointUsable) { [string]$activeCheckpoint.taskId } elseif ($currentTaskContextUsable) { [string]$currentTaskContext.taskId } elseif ($taskGraphWorkspaceMatch) { [string]$taskGraph.taskId } else { '' }
$continuitySource = if ($contractWorkspaceMatch) { 'execution-contract.ps1' } elseif ($activeCheckpointUsable) { $checkpointSelection.source } elseif ($currentTaskContextUsable) { 'current-task-context.json' } elseif ($taskGraphWorkspaceMatch) { 'task-graph.json' } else { 'none' }
$continuityConsistency = if ($contractWorkspaceMatch -and $activeCheckpointUsable -and [string]$activeCheckpoint.taskId -ne $activeTaskId) { 'contract_overrides_checkpoint_conflict' } elseif ($activeCheckpointUsable -and $currentTaskContextUsable -and [string]$activeCheckpoint.taskId -ne [string]$currentTaskContext.taskId) { 'conflict' } elseif ($contractWorkspaceMatch -or ($activeCheckpointUsable -and $currentTaskContextUsable)) { 'consistent' } else { 'single_source' }
$matchingActiveCheckpoint = ($activeCheckpointUsable -and [string]$activeCheckpoint.taskId -eq $activeTaskId)
$matchingCurrentTaskContext = ($currentTaskContextUsable -and [string]$currentTaskContext.taskId -eq $activeTaskId)
$matchingTaskGraph = ($taskGraphWorkspaceMatch -and (Test-SnapshotScopedEvidence $taskGraph $activeTaskId $workspaceKeyValue))
$matchingStepLedger = ($stepLedgerWorkspaceMatch -and (Test-SnapshotScopedEvidence $stepLedger $activeTaskId $workspaceKeyValue))
$matchingContinuityStatus = ($continuityStatusWorkspaceMatch -and (Test-SnapshotScopedEvidence $continuityStatus $activeTaskId $workspaceKeyValue))

$openStepCount = if ($matchingActiveCheckpoint) { @($activeCheckpoint.pendingSteps).Count } elseif ($matchingStepLedger) { @($stepLedger.openSteps).Count } else { 0 }
$completedStepCount = if ($matchingActiveCheckpoint) { @($activeCheckpoint.completedSteps).Count } elseif ($matchingStepLedger) { @($stepLedger.completedSteps).Count } else { 0 }
$blockedStepCount = if ($matchingActiveCheckpoint) { @($activeCheckpoint.blockers).Count } elseif ($matchingStepLedger) { @($stepLedger.blockedSteps).Count } else { 0 }
$skippedStepCount = if ($matchingStepLedger) { @($stepLedger.skippedSteps).Count } else { 0 }
$continuityNextAction = if ($contractWorkspaceMatch -and -not [string]::IsNullOrWhiteSpace($contractNextAction)) { $contractNextAction } else { '' }

$continuitySummary = [pscustomobject]@{
  taskId = $activeTaskId
  workspaceKey = $workspaceKeyValue
  taskStatus = if ($contractWorkspaceMatch) { 'active' } elseif ($matchingActiveCheckpoint) { [string]$activeCheckpoint.status } elseif ($matchingCurrentTaskContext) { [string]$currentTaskContext.status } elseif ($matchingTaskGraph) { [string]$taskGraph.status } else { '' }
  taskName = if ($contractWorkspaceMatch -and $executionResolution.workLineStatus -and $executionResolution.workLineStatus.activePlan) { Limit-Text ([string]$executionResolution.workLineStatus.activePlan.focusLabel) 180 } elseif ($matchingActiveCheckpoint) { Limit-Text ([string]$activeCheckpoint.taskName) 180 } elseif ($matchingTaskGraph) { Limit-Text ([string]$taskGraph.goal) 180 } else { '' }
  goal = if ($matchingActiveCheckpoint) { Limit-Text ([string]$activeCheckpoint.goal) 220 } elseif ($matchingCurrentTaskContext) { Limit-Text ([string]$currentTaskContext.acceptedGoal) 220 } elseif ($matchingTaskGraph) { Limit-Text ([string]$taskGraph.goal) 220 } else { '' }
  currentPhase = if ($matchingActiveCheckpoint) { Limit-Text ([string]$activeCheckpoint.currentPhase) 160 } else { '' }
  currentStep = if ($contractWorkspaceMatch -and $executionResolution.workLineStatus -and $executionResolution.workLineStatus.activePlan) { Limit-Text ([string]$executionResolution.workLineStatus.activePlan.nextAction) 220 } elseif ($matchingActiveCheckpoint) { Limit-Text ([string]$activeCheckpoint.currentStep) 220 } elseif ($matchingStepLedger -and @($stepLedger.openSteps).Count -gt 0) { Limit-Text ([string]$stepLedger.openSteps[0].step) 220 } else { '' }
  waitingForUser = (($contractWorkspaceMatch -and $executionResolution.needsConfirmation -eq $true) -or ($matchingActiveCheckpoint -and $activeCheckpoint.waitingForUser -eq $true))
  openStepCount = $openStepCount
  completedCount = $completedStepCount
  blockedCount = $blockedStepCount
  skippedCount = $skippedStepCount
  candidateFindings = if ($matchingContinuityStatus -and $continuityStatus.findingCounts) { [int]$continuityStatus.findingCounts.candidate } else { 0 }
  nextAction = Limit-Text $continuityNextAction 220
  executionContract = if ($contractWorkspaceMatch) { [pscustomobject]@{ taskId=[string]$executionResolution.taskId; workspaceKey=$workspaceKeyValue; focusId=Limit-Text ([string]$executionResolution.focusId) 120; focusLabel=Limit-Text ([string]$executionResolution.focusLabel) 100; nextAction=Limit-Text $contractNextAction 220; revision=[int]$executionResolution.contractRevision; resumeFrom=[string]$executionResolution.resumeFrom; claimAllowed=[bool]$executionResolution.claimAllowed; needsConfirmation=[bool]$executionResolution.needsConfirmation; workLineStatus=$executionResolution.workLineStatus; latestMessageClassification=$executionResolution.latestMessageClassification } } else { $null }
  continuityStateCard = $contractStateCard
  source = $continuitySource
  consistency = $continuityConsistency
  conflictingTaskId = if ($continuityConsistency -in @('conflict','contract_overrides_checkpoint_conflict')) { if($matchingActiveCheckpoint){[string]$currentTaskContext.taskId}else{[string]$activeCheckpoint.taskId} } else { '' }
  selection = [pscustomobject]@{ state=$checkpointSelection.state; contextState=$checkpointSelection.contextState; candidateTaskId=$checkpointSelection.candidateTaskId; ignoredTaskId=$checkpointSelection.ignoredTaskId }
}
$impactSummary = [pscustomobject]@{
  riskLevel = if ($impact) { [string]$impact.riskLevel } else { '' }
  affectedScripts = if ($impact) { @(Limit-List @($impact.affectedScripts) 10 120) } else { @() }
  recommendedChecks = if ($impact) { @(Limit-List @($impact.recommendedChecks) 10 160) } else { @() }
}
$codegraphSummary = [pscustomobject]@{
  schema = if ($codegraph) { [string]$codegraph.schema } else { '' }
  scriptCount = if ($codegraph -and $codegraph.summary) { [int]$codegraph.summary.scriptCount } else { 0 }
  dynamicCallUnknownCount = if ($codegraph -and $codegraph.summary) { [int]$codegraph.summary.dynamicCallUnknownCount } else { 0 }
  workspaceFileCount = if ($codegraph -and $codegraph.summary) { [int]$codegraph.summary.workspaceFileCount } else { 0 }
}
$compactWorkLineStatus = if ($contractWorkspaceMatch -and $executionResolution.workLineStatus) {
  [pscustomobject]@{
    mainLine = [string]$executionResolution.workLineStatus.mainLine
    activeLine = [string]$executionResolution.workLineStatus.activeLine
    suspendedLines = @($executionResolution.workLineStatus.suspendedLines | Select-Object -First 4)
    unfinishedLines = @($executionResolution.workLineStatus.unfinishedLines | Select-Object -First 6)
    priorityOrder = @($executionResolution.workLineStatus.priorityOrder | Select-Object -First 4 | ForEach-Object { [pscustomobject]@{ executionRank=$_.executionRank; focusId=$_.focusId; focusLabel=Limit-Text ([string]$_.focusLabel) 80; source=$_.source } })
    mainPlan = [pscustomobject]@{ focusId=[string]$executionResolution.workLineStatus.mainPlan.focusId; focusLabel=Limit-Text ([string]$executionResolution.workLineStatus.mainPlan.focusLabel) 80; nextAction=Limit-Text ([string]$executionResolution.workLineStatus.mainPlan.nextAction) 180 }
    activePlan = [pscustomobject]@{ focusId=[string]$executionResolution.workLineStatus.activePlan.focusId; focusLabel=Limit-Text ([string]$executionResolution.workLineStatus.activePlan.focusLabel) 80; nextAction=Limit-Text ([string]$executionResolution.workLineStatus.activePlan.nextAction) 180 }
    nextPlan = [pscustomobject]@{ focusId=[string]$executionResolution.workLineStatus.nextPlan.focusId; focusLabel=Limit-Text ([string]$executionResolution.workLineStatus.nextPlan.focusLabel) 80; nextAction=Limit-Text ([string]$executionResolution.workLineStatus.nextPlan.nextAction) 180 }
    suspendedPlans = @($executionResolution.workLineStatus.suspendedPlans | Select-Object -First 4 | ForEach-Object { [pscustomobject]@{ focusId=$_.focusId; focusLabel=Limit-Text ([string]$_.focusLabel) 80; nextAction=Limit-Text ([string]$_.nextAction) 140 } })
    unfinishedPlans = @($executionResolution.workLineStatus.unfinishedPlans | Select-Object -First 6 | ForEach-Object { [pscustomobject]@{ focusId=$_.focusId; focusLabel=Limit-Text ([string]$_.focusLabel) 80; nextAction=Limit-Text ([string]$_.nextAction) 140 } })
    latestMessageClassification = $executionResolution.latestMessageClassification
  }
} else { $null }
if ($contractWorkspaceMatch -and $continuitySummary.executionContract) { $continuitySummary.executionContract.workLineStatus = $compactWorkLineStatus }
$statusCardContinuity = [pscustomobject]@{
  taskId = $continuitySummary.taskId
  workspaceKey = $workspaceKeyValue
  taskStatus = $continuitySummary.taskStatus
  nextAction = $continuitySummary.nextAction
  source = $continuitySummary.source
  consistency = $continuitySummary.consistency
  executionContract = if ($contractWorkspaceMatch) { [pscustomobject]@{ taskId=[string]$executionResolution.taskId; workspaceKey=$workspaceKeyValue; focusId=Limit-Text ([string]$executionResolution.focusId) 120; focusLabel=Limit-Text ([string]$executionResolution.focusLabel) 100; nextAction=Limit-Text $contractNextAction 220; revision=[int]$executionResolution.contractRevision; resumeFrom=[string]$executionResolution.resumeFrom; claimAllowed=[bool]$executionResolution.claimAllowed; needsConfirmation=[bool]$executionResolution.needsConfirmation; workLineStatus=$compactWorkLineStatus } } else { $null }
  continuityStateCard = $contractStateCard
}

$snapshot = [pscustomobject]@{
  ok = ($dashboard.ok -eq $true)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  workspaceKey = $workspaceKeyValue
  summary = Limit-Text $Summary 180
  nextAction = Limit-Text $NextAction 220
  nextActionSource = if ($contractWorkspaceMatch) { 'execution_contract' } else { 'dashboard_or_explicit_status' }
  executionContract = if ($contractWorkspaceMatch) { [pscustomobject]@{ taskId=[string]$executionResolution.taskId; workspaceKey=$workspaceKeyValue; focusId=Limit-Text ([string]$executionResolution.focusId) 120; focusLabel=Limit-Text ([string]$executionResolution.focusLabel) 100; nextAction=Limit-Text $contractNextAction 220; revision=[int]$executionResolution.contractRevision; resumeFrom=[string]$executionResolution.resumeFrom; claimAllowed=[bool]$executionResolution.claimAllowed; needsConfirmation=[bool]$executionResolution.needsConfirmation; workLineStatus=$compactWorkLineStatus; latestMessageClassification=$executionResolution.latestMessageClassification } } else { $null }
  continuityStateCard = $contractStateCard
  roadmapCompletedVersions = @($dashboard.roadmap.completedVersions)
  roadmapRemainingVersions = @($dashboard.roadmap.remainingVersions)
  verifyOk = $dashboard.verify.ok
  verifyCheckedAt = $dashboard.verify.checkedAt
  hotRefreshOk = $dashboard.hotRefresh.ok
  memoryRegressionOk = $dashboard.memoryRegression.ok
  reviewGateOk = $dashboard.reviewGate.ok
  privacyOk = $dashboard.privacy.ok
  risks = @(Limit-List @($dashboard.risks) 8 120)
  continuity = $continuitySummary
  impact = $impactSummary
  codegraph = $codegraphSummary
  evidence = @(Limit-List @($Evidence + @('super-brain-dashboard.ps1','last-verify-package.json','last-task-verification.json','active-checkpoint.json','current-task-context.json','last-project-continuity.json','task-graph.json','step-ledger.json','last-impact-advisor.json','last-codegraph-index.json')) 12 160)
}

$path = Join-Path $workspace 'last-status-snapshot.json'
Write-JsonUtf8NoBom $path $snapshot 12 -Compress
$statusCard = [pscustomobject]@{ ok=$snapshot.ok; updatedAt=$snapshot.checkedAt; version=$snapshot.version; taskId=$continuitySummary.taskId; workspaceKey=$workspaceKeyValue; packageOk=$dashboard.ok; verifyOk=$snapshot.verifyOk; verifyCheckedAt=$snapshot.verifyCheckedAt; hotRefreshOk=$snapshot.hotRefreshOk; memoryRegressionOk=$snapshot.memoryRegressionOk; reviewGateOk=$snapshot.reviewGateOk; privacyOk=$snapshot.privacyOk; risksCount=@($snapshot.risks).Count; nextAction=$snapshot.nextAction; nextActionSource=$snapshot.nextActionSource; executionContractRevision=if($contractWorkspaceMatch){[int]$executionResolution.contractRevision}else{0}; continuity=$statusCardContinuity; impact=$impactSummary; codegraph=$codegraphSummary; source='status-snapshot-writer.ps1' }
$statusCardPath = Join-Path $workspace 'status-card.json'
Write-JsonUtf8NoBom $statusCardPath $statusCard 10 -Compress
$scopedStateRoot = Join-Path $workspace (Join-Path 'runtime-state\workspaces' $workspaceKeyValue)
if (-not (Test-Path -LiteralPath $scopedStateRoot)) { New-Item -ItemType Directory -Force -Path $scopedStateRoot | Out-Null }
$scopedSnapshotPath = Join-Path $scopedStateRoot 'last-status-snapshot.json'
$scopedStatusCardPath = Join-Path $scopedStateRoot 'status-card.json'
Write-JsonUtf8NoBom $scopedSnapshotPath $snapshot 12 -Compress
Write-JsonUtf8NoBom $scopedStatusCardPath $statusCard 10 -Compress
if ($Json) { $snapshot | Add-Member -NotePropertyName statusCardPath -NotePropertyValue $statusCardPath -Force; $snapshot | Add-Member -NotePropertyName scopedSnapshotPath -NotePropertyValue $scopedSnapshotPath -Force; $snapshot | Add-Member -NotePropertyName scopedStatusCardPath -NotePropertyValue $scopedStatusCardPath -Force; $snapshot | ConvertTo-Json -Depth 12 } else { Write-Host "STATUS_SNAPSHOT_WRITER ok=$($snapshot.ok) path=$path version=$($snapshot.version) statusCard=$statusCardPath scoped=$scopedSnapshotPath"; Write-Host "STATUS_SNAPSHOT_SUMMARY $($snapshot.summary)"; Write-Host "STATUS_SNAPSHOT_NEXT $($snapshot.nextAction)" }
exit 0
