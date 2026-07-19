param(
  [string]$WorkspaceKey = '',
  [string]$SessionKey = '',
  [string]$VisibleUserInstruction = '',
  [string]$VisibleAssistantCommitment = '',
  [switch]$Json,
  [switch]$AllowStaleVerify
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$hostSessionKey = Get-SuperBrainHostSessionKey $SessionKey

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Invoke-JsonTool([string]$ScriptName, [switch]$UseAllowStaleVerify) {
  try {
    $parameters = @{ Json=$true }
    if ($UseAllowStaleVerify) { $parameters.AllowStaleVerify = $true }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceKey)) { $parameters.WorkspaceKey = $WorkspaceKey }
    if ($ScriptName -eq 'super-brain-dashboard.ps1') { $parameters.SessionKey = $hostSessionKey }
    $output = @(& (Join-Path $PSScriptRoot $ScriptName) @parameters 6>$null)
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

$dashboard = Invoke-JsonTool 'super-brain-dashboard.ps1' -UseAllowStaleVerify:$AllowStaleVerify
$manifest = Get-SuperBrainManifest $Root
$currentTaskContext = Read-WorkspaceJson 'current-task-context.json'
$checkpointSelection = Get-SuperBrainRelevantCheckpoint $workspace $currentTaskContext $WorkspaceKey
$activeCheckpoint = $checkpointSelection.checkpoint
$workspaceKeyValue = [string]$checkpointSelection.workspaceKey
$activeTaskId = if ($activeCheckpoint) { [string]$activeCheckpoint.taskId } elseif ($currentTaskContext -and (Test-SuperBrainWorkspaceKey ([string]$currentTaskContext.workspaceKey) $workspaceKeyValue)) { [string]$currentTaskContext.taskId } else { '' }
$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastStatusSnapshot = Read-WorkspaceJson 'last-status-snapshot.json'
$scopedStatusSnapshot = Read-WorkspaceJson (Join-Path (Join-Path 'runtime-state\workspaces' $workspaceKeyValue) 'last-status-snapshot.json')
if ($scopedStatusSnapshot) { $lastStatusSnapshot = $scopedStatusSnapshot }

$lastTaskStale = $false
$staleReasons = @()
if ($lastTask) {
  if (-not $lastTask.PSObject.Properties['workspaceKey'] -or -not (Test-SuperBrainWorkspaceKey ([string]$lastTask.workspaceKey) $workspaceKeyValue)) {
    $lastTaskStale = $true
    $staleReasons += 'last_task_workspace_mismatch_or_unscoped'
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$lastTask.version) -and [string]$lastTask.version -ne [string]$manifest.version) {
    $lastTaskStale = $true
    $staleReasons += "last_task_version_mismatch:$($lastTask.version)!=$($manifest.version)"
  }
  if ($lastVerify -and -not [string]::IsNullOrWhiteSpace([string]$lastTask.checkedAt) -and -not [string]::IsNullOrWhiteSpace([string]$lastVerify.checkedAt)) {
    try {
      $taskAt = [datetime]::ParseExact([string]$lastTask.checkedAt, 'yyyy-MM-dd HH:mm:ss', $null)
      $verifyAt = [datetime]::ParseExact([string]$lastVerify.checkedAt, 'yyyy-MM-dd HH:mm:ss', $null)
      if ($taskAt -lt $verifyAt) {
        $lastTaskStale = $true
        $staleReasons += 'last_task_older_than_verify'
      }
    } catch {}
  }
}
$lastStatusSnapshotUsable = ($lastStatusSnapshot -and $lastStatusSnapshot.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$lastStatusSnapshot.workspaceKey) $workspaceKeyValue))

$blockers = @()
if (-not ($lastVerify -and $lastVerify.ok -eq $true) -and -not $AllowStaleVerify) { $blockers += 'Run or fix scripts/verify-package.ps1.' }
if ($dashboard.reviewGate -and $dashboard.reviewGate.blockerCount -gt 0) { $blockers += 'Resolve team-task review gate blockers.' }
if ($dashboard.memoryRegression -and $dashboard.memoryRegression.failed -gt 0) { $blockers += 'Fix memory-regression-checker failed cases.' }
if ($dashboard.privacy -and $dashboard.privacy.privatePatternHits -gt 0) { $blockers += 'Review privacy-sentinel private-pattern hits before sharing.' }

function Limit-Text([string]$Text, [int]$Max = 180) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = (([string]$Text).Trim() -replace '\s+',' ')
  if ($Max -le 0) { return '' }
  if ($value.Length -gt $Max) {
    if ($Max -le 3) { return $value.Substring(0, $Max) }
    return $value.Substring(0, $Max - 3).TrimEnd() + '...'
  }
  return $value
}

function Limit-StringItems([object[]]$Items,[int]$MaxItems,[int]$MaxChars) {
  return @($Items | Select-Object -First $MaxItems | ForEach-Object { Limit-Text ([string]$_) $MaxChars } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Protect-CompactResolution([object]$Resolution,[string]$GuardText) {
  if (-not $Resolution) { return $null }
  $protected = Remove-SuperBrainExecutableActions $Resolution
  $protected.nextAction = $GuardText
  $protected.guard = $GuardText
  return $protected
}

function Protect-Classification([object]$Classification) {
  if (-not $Classification) { return $null }
  return [pscustomobject]@{
    mode = Limit-Text ([string]$Classification.mode) 40
    topicAffinity = Limit-Text ([string]$Classification.topicAffinity) 120
    targetLineId = Limit-Text ([string]$Classification.targetLineId) 120
    targetLineLabel = Limit-Text ([string]$Classification.targetLineLabel) 100
    confidence = Limit-Text ([string]$Classification.confidence) 20
    matchedKeys = @(Limit-StringItems @($Classification.matchedKeys) 6 48)
    candidateLineIds = @(Limit-StringItems @($Classification.candidateLineIds) 6 120)
    needsClarification = [bool]$Classification.needsClarification
    recommendedInstructionMode = Limit-Text ([string]$Classification.recommendedInstructionMode) 40
    reason = Limit-Text ([string]$Classification.reason) 180
    rawInstructionStored = $false
  }
}

$nextAction = 'Ask for the next user task or define the next roadmap item.'
$resumeFrom = ''
$stateOnlyFallback = $false
$executionResolution = $null
$executionResolutionFailed = $false
$executionResolutionFailureCode = ''
$executionResolutionNoContract = $false
try {
  $contractParameters = @{Action='Resolve';WorkspaceKey=$workspaceKeyValue;SessionKey=$hostSessionKey;VisibleUserInstruction=$VisibleUserInstruction;VisibleAssistantCommitment=$VisibleAssistantCommitment;NoExit=$true;Json=$true}
  $contractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') @contractParameters 2>$null)
  if (-not $contractRaw) { throw 'execution contract returned no JSON' }
  $candidateResolution = (($contractRaw -join "`n") | ConvertFrom-Json)
  if (-not $candidateResolution -or $candidateResolution.ok -ne $true) {
    $executionResolutionFailed = $true
    $executionResolutionFailureCode = if($candidateResolution){[string]$candidateResolution.code}else{'EXECUTION_CONTRACT_EMPTY_RESULT'}
  } elseif (-not (Test-SuperBrainWorkspaceKey ([string]$candidateResolution.workspaceKey) $workspaceKeyValue)) {
    $executionResolutionFailed = $true
    $executionResolutionFailureCode = 'EXECUTION_CONTRACT_SCOPE_MISMATCH'
  } else {
    $executionResolution = $candidateResolution
    $executionResolutionNoContract = ([string]$candidateResolution.resolutionSource -eq 'none' -and [string]$candidateResolution.actionAuthorization -eq 'not_applicable')
  }
} catch {
  $executionResolution = $null
  $executionResolutionFailed = $true
  if ([string]::IsNullOrWhiteSpace($executionResolutionFailureCode)) { $executionResolutionFailureCode = 'EXECUTION_CONTRACT_RESOLVE_FAILED' }
}
if ($executionResolution -and -not [string]::IsNullOrWhiteSpace([string]$executionResolution.taskId) -and [string]$executionResolution.taskId -ne $activeTaskId) {
  $activeTaskId = [string]$executionResolution.taskId
  $safeTaskId = (($activeTaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  $scopedCheckpointPath = Join-Path (Join-Path $workspace 'runtime-state\checkpoints\active') ($safeTaskId + '.json')
  $scopedCheckpoint = Read-WorkspaceJson "runtime-state\checkpoints\active\$safeTaskId.json"
  if ($scopedCheckpoint -and [string]$scopedCheckpoint.workspaceKey -and (Test-SuperBrainWorkspaceKey ([string]$scopedCheckpoint.workspaceKey) $workspaceKeyValue)) { $activeCheckpoint = $scopedCheckpoint }
}
if ($executionResolutionFailed) {
  $nextAction = 'Execution contract resolution failed. Repair or re-run the resolver before mutation.'
  $resumeFrom = 'execution_resolution_failed'
} elseif ($executionResolutionNoContract -and $activeCheckpoint -and -not [string]::IsNullOrWhiteSpace([string]$activeCheckpoint.nextAction)) {
  $nextAction = 'Latest execution action is unknown. Use the checkpoint only to locate task state, then reconcile a current execution contract before mutation.'
  $resumeFrom = 'checkpoint_state_only'
  $stateOnlyFallback = $true
} elseif ($executionResolutionNoContract) {
  $resumeFrom = 'none'
} elseif ($executionResolution -and ($executionResolution.actionAuthorization -ne 'allowed' -or $executionResolution.claimAllowed -ne $true -or $executionResolution.needsConfirmation -eq $true)) {
  $nextAction = if (-not [string]::IsNullOrWhiteSpace([string]$executionResolution.nextAction)) { [string]$executionResolution.nextAction } else { 'Action withheld: reconcile session ownership or the latest instruction before mutation.' }
  $resumeFrom = [string]$executionResolution.resumeFrom
} elseif ($executionResolution -and [string]$executionResolution.resumeFrom -in @('visible_conversation','execution_contract','execution_contract_pending_reconciliation','parent_return')) {
  $nextAction = [string]$executionResolution.nextAction
  $resumeFrom = [string]$executionResolution.resumeFrom
} elseif ($executionResolution -and [string]$executionResolution.resumeFrom -in @('checkpoint_state_only','unknown')) {
  $nextAction = 'Latest execution action is unknown. Reconcile the visible conversation or confirm the next action before mutation.'
  $resumeFrom = [string]$executionResolution.resumeFrom
} elseif ($activeCheckpoint -and -not [string]::IsNullOrWhiteSpace([string]$activeCheckpoint.nextAction)) {
  $nextAction = 'Latest execution action is unknown. Use the checkpoint only to locate task state, then reconcile a current execution contract before mutation.'
  $resumeFrom = 'checkpoint_state_only'
  $stateOnlyFallback = $true
} elseif ($lastStatusSnapshotUsable -and -not [string]::IsNullOrWhiteSpace([string]$lastStatusSnapshot.nextAction)) {
  $nextAction = 'Latest execution action is unknown. Use the status snapshot only to locate task state, then reconcile a current execution contract before mutation.'
  $resumeFrom = 'last_status_snapshot_state_only'
  $stateOnlyFallback = $true
} elseif ($lastTask -and -not $lastTaskStale -and @($lastTask.nextSteps).Count -gt 0) {
  $nextAction = 'Latest execution action is unknown. Use the task verification only as completed-state evidence, then reconcile a current execution contract before mutation.'
  $resumeFrom = 'last_task_verification_state_only'
  $stateOnlyFallback = $true
}
$blockerNextAction = if ($blockers.Count -gt 0) { [string]$blockers[0] } else { '' }
$compactExecutionResolution = ConvertTo-SuperBrainCompactExecutionResolution $executionResolution
$classification = if ($executionResolution -and $executionResolution.PSObject.Properties['latestMessageClassification']) { $executionResolution.latestMessageClassification } elseif ($executionResolution -and $executionResolution.workLineStatus) { $executionResolution.workLineStatus.latestMessageClassification } else { $null }
$topicAffinity = if ($classification) { [string]$classification.topicAffinity } else { '' }
$hasLatestInstruction = (-not [string]::IsNullOrWhiteSpace($VisibleUserInstruction)) -or ($executionResolution -and -not [string]::IsNullOrWhiteSpace([string]$executionResolution.latestUserInstruction))
$needsConfirmation = ($executionResolution -and $executionResolution.needsConfirmation -eq $true)
$requiresUserDisambiguation = ($classification -and $classification.needsClarification -eq $true) -or ($executionResolution -and $executionResolution.workLineStatus -and $executionResolution.workLineStatus.requiresUserDisambiguation -eq $true)
$unknownAffinity = ($hasLatestInstruction -and ([string]::IsNullOrWhiteSpace($topicAffinity) -or $topicAffinity -eq 'unknown'))
$ambiguousAffinity = ($topicAffinity -eq 'ambiguous')
$actionWithheld = ($executionResolutionFailed -or $stateOnlyFallback -or $needsConfirmation -or (-not $executionResolutionNoContract -and $executionResolution -and $executionResolution.actionAuthorization -ne 'allowed') -or $requiresUserDisambiguation -or $unknownAffinity -or $ambiguousAffinity)
$continuationState = if ($executionResolutionFailed) { 'resolver_failed' } elseif ($executionResolutionNoContract) { 'no_contract' } elseif ($ambiguousAffinity -or $requiresUserDisambiguation) { 'requires_user_disambiguation' } elseif ($unknownAffinity) { 'unknown_affinity' } elseif ($stateOnlyFallback -or $needsConfirmation) { 'needs_confirmation' } else { 'actionable' }
$withheldAction = 'Action withheld: the latest execution action is unknown; confirm or reconcile how the user instruction maps to the active work line before mutation.'
if ($actionWithheld) {
  $nextAction = $withheldAction
  $compactExecutionResolution = Protect-CompactResolution $compactExecutionResolution $withheldAction
}
if ($compactExecutionResolution -and $compactExecutionResolution.latestMessageClassification) {
  $compactExecutionResolution.latestMessageClassification = Protect-Classification $compactExecutionResolution.latestMessageClassification
}
if ($compactExecutionResolution -and $compactExecutionResolution.workLineStatus -and $compactExecutionResolution.workLineStatus.latestMessageClassification) {
  $compactExecutionResolution.workLineStatus.latestMessageClassification = Protect-Classification $compactExecutionResolution.workLineStatus.latestMessageClassification
}
$taskStateVisible = (-not $actionWithheld -and -not $executionResolutionNoContract -and $activeCheckpoint)
$checkpointLocationVisible = ($activeCheckpoint -and ($taskStateVisible -or $stateOnlyFallback))
$summaryStateVisible = (-not $actionWithheld -and -not $executionResolutionNoContract)

$result = [pscustomobject]@{
  ok = ($blockers.Count -eq 0 -and -not $executionResolutionFailed)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  workspaceKey = $workspaceKeyValue
  checkpointSelection = [pscustomobject]@{ state=$checkpointSelection.state; contextState=$checkpointSelection.contextState; source=$checkpointSelection.source; candidateTaskId=$checkpointSelection.candidateTaskId; ignoredTaskId=$checkpointSelection.ignoredTaskId }
  executionResolution = $compactExecutionResolution
  executionResolutionStatus = if($executionResolutionFailed){'failed'}elseif($executionResolutionNoContract){'no_contract'}elseif($actionWithheld){'withheld'}else{'allowed'}
  executionResolutionFailureCode = $executionResolutionFailureCode
  instructionMode = if ($executionResolution) { [string]$executionResolution.instructionMode } else { '' }
  returnTo = if ($compactExecutionResolution) { $compactExecutionResolution.returnTo } else { $null }
  canResumeParent = if ($executionResolution -and -not $actionWithheld) { [bool]$executionResolution.canResumeParent } else { $false }
  latestInstructionRecovered = ($executionResolution -and -not [string]::IsNullOrWhiteSpace([string]$executionResolution.latestUserInstruction))
  needsConfirmation = [bool]$needsConfirmation
  requiresUserDisambiguation = [bool]$requiresUserDisambiguation
  topicAffinity = Limit-Text $topicAffinity 120
  continuationState = $continuationState
  actionWithheld = [bool]$actionWithheld
  mutationAuthorized = ($blockers.Count -eq 0 -and -not $actionWithheld -and $executionResolution -and $executionResolution.actionAuthorization -eq 'allowed' -and $executionResolution.claimAllowed -eq $true -and $executionResolution.needsConfirmation -ne $true)
  resumeFrom = $resumeFrom
  workLineStatus = if ($compactExecutionResolution) { $compactExecutionResolution.workLineStatus } else { $null }
  continuityStateCard = if ($compactExecutionResolution) { $compactExecutionResolution.continuityStateCard } else { $null }
  unfinishedLines = if ($executionResolution -and $executionResolution.PSObject.Properties['unfinishedWorkLines']) { @(Limit-StringItems @($executionResolution.unfinishedWorkLines) 6 120) } else { @() }
  taskGoal = if ($taskStateVisible) { Limit-Text ([string]$activeCheckpoint.goal) 180 } else { '' }
  currentPhase = if ($checkpointLocationVisible) { Limit-Text ([string]$activeCheckpoint.currentPhase) 120 } else { '' }
  completedSteps = if ($taskStateVisible) { @(Limit-StringItems @($activeCheckpoint.completedSteps) 8 160) } else { @() }
  pendingSteps = if ($taskStateVisible) { @(Limit-StringItems @($activeCheckpoint.pendingSteps) 8 160) } else { @() }
  changedFiles = if ($taskStateVisible) { @(Limit-StringItems @($activeCheckpoint.changedFiles) 8 200) } else { @() }
  waitingForUser = if ($taskStateVisible) { [bool]$activeCheckpoint.waitingForUser } else { $false }
  lastSummary = if ($summaryStateVisible -and $lastTask -and -not $lastTaskStale) { Limit-Text ([string]$lastTask.summary) 180 } elseif ($summaryStateVisible -and $lastStatusSnapshotUsable) { Limit-Text ([string]$lastStatusSnapshot.summary) 180 } else { '' }
  lastTaskStale = [bool]$lastTaskStale
  staleReasons = @(Limit-StringItems @($staleReasons) 8 160)
  currentStep = if ($taskStateVisible) { Limit-Text ([string]$activeCheckpoint.currentStep) 160 } else { '' }
  checkpointStatus = if ($checkpointLocationVisible) { Limit-Text ([string]$activeCheckpoint.status) 40 } else { '' }
  nextAction = Limit-Text ([string]$nextAction) 220
  blockerNextAction = Limit-Text $blockerNextAction 220
  blockers = @(Limit-StringItems @($blockers) 8 180)
  evidence = @('visible-conversation','execution-contract.ps1','active-checkpoint.json','last-task-verification.json','last-status-snapshot.json','last-verify-package.json')
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "AUTO_CONTINUATION ok=$($result.ok) version=$($result.version) resumeFrom=$($result.resumeFrom)"
  Write-Host "AUTO_CONTINUATION_LAST $($result.lastSummary)"
  Write-Host "AUTO_CONTINUATION_NEXT $($result.nextAction)"
  foreach ($blocker in @($blockers)) { Write-Host "AUTO_CONTINUATION_BLOCKER $blocker" }
}
if (-not $result.ok) { exit 1 }
exit 0
