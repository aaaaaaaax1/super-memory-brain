param(
  [string]$Query = '',
  [ValidateSet('auto','force','off')]
  [string]$MemoryMode = 'auto',
  [int]$MaxTokens = 600,
  [int]$TopK = 2,
  [string]$WorkspaceKey = '',
  [string]$SessionId = '',
  [string]$SessionKey = '',
  [string]$TaskId = '',
  [int]$TtlMinutes = 180,
  [switch]$BindSession,
  [switch]$Deep,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$statusPath = Join-Path $workspace 'last-session-restore.json'
$RestoreMaxTokens = 4000
$RestoreMaxTopK = 8
$RestoreMaxPacketChars = 24000

function Limit-RestoreText([string]$Value,[int]$Max=220) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = (([string]$Value).Trim() -replace '\s+',' ')
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Limit-RestoreList([object[]]$Items,[int]$MaxItems=8,[int]$MaxChars=160) {
  return @($Items | Select-Object -First $MaxItems | ForEach-Object { Limit-RestoreText ([string]$_) $MaxChars })
}

function Get-RestoreEvidenceTaskId([object]$Evidence) {
  if (-not $Evidence) { return '' }
  if ($Evidence.PSObject.Properties['taskId'] -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.taskId)) { return [string]$Evidence.taskId }
  if ($Evidence.PSObject.Properties['continuity'] -and $Evidence.continuity -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.continuity.taskId)) { return [string]$Evidence.continuity.taskId }
  if ($Evidence.PSObject.Properties['executionContract'] -and $Evidence.executionContract -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.executionContract.taskId)) { return [string]$Evidence.executionContract.taskId }
  return ''
}

function Test-RestoreEvidenceWorkspace([object]$Evidence,[string]$ExpectedWorkspaceKey) {
  return ($Evidence -and $Evidence.PSObject.Properties['workspaceKey'] -and -not [string]::IsNullOrWhiteSpace([string]$Evidence.workspaceKey) -and (Test-SuperBrainWorkspaceKey ([string]$Evidence.workspaceKey) $ExpectedWorkspaceKey))
}

function Test-RestoreScopedEvidence([object]$Evidence,[string]$ExpectedTaskId,[string]$ExpectedWorkspaceKey) {
  if ([string]::IsNullOrWhiteSpace($ExpectedTaskId) -or -not (Test-RestoreEvidenceWorkspace $Evidence $ExpectedWorkspaceKey)) { return $false }
  return (Get-RestoreEvidenceTaskId $Evidence) -eq $ExpectedTaskId
}

$policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($MaxTokens -le 0) { $MaxTokens = 600 }
else { $MaxTokens = [Math]::Max(200,[Math]::Min($RestoreMaxTokens,$MaxTokens)) }
if ($TopK -le 0) { $TopK = 2 }
else { $TopK = [Math]::Max(1,[Math]::Min($RestoreMaxTopK,$TopK)) }
if ($MemoryMode -eq 'off') {
  $result = [pscustomobject]@{
    ok = $true
    memoryMode = $MemoryMode
    skipped = $true
    reason = 'memory:off'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    tokenBudget = 0
    topK = 0
    packetLimits = [pscustomobject]@{ maxChars=$RestoreMaxPacketChars; maxEvidenceCards=$RestoreMaxTopK; truncated=$false }
    sessionBinding = [pscustomobject]@{ ok=$true; status='skipped'; reason='memory:off' }
  }
  Write-JsonUtf8NoBom $statusPath $result 8 -Compress
  if ($Json) { $result | ConvertTo-Json -Depth 8 -Compress } else { Write-Host "SESSION_RESTORE_SKIPPED memory=off status=$statusPath" }
  exit 0
}

$routeIntent = ''
if (-not [string]::IsNullOrWhiteSpace($Query)) {
  try {
    $intentOutput = @(& (Join-Path $PSScriptRoot 'intent-router.ps1') -Text $Query -Json 6>$null)
    $intentResult = (($intentOutput -join "`n") | ConvertFrom-Json)
    $routeIntent = [string]$intentResult.intent
  } catch {}
}
$historicalRecoveryIntent = ($routeIntent -eq 'historical_recovery')

$state = $null
$statePath = Join-Path $workspace 'super-brain-state.json'
if (Test-Path $statePath) {
  try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$lastSnapshot = $null
$snapshotPath = Join-Path $workspace 'last-status-snapshot.json'
if (Test-Path $snapshotPath) {
  try { $lastSnapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$statusCard = $null
$statusCardPath = Join-Path $workspace 'status-card.json'
if (Test-Path $statusCardPath) {
  try { $statusCard = Get-Content -LiteralPath $statusCardPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$currentWorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
$hostSessionKey = Get-SuperBrainHostSessionKey $SessionKey
$scopedWorkspaceState = Join-Path $workspace (Join-Path 'runtime-state\workspaces' $currentWorkspaceKey)
$scopedSnapshotPath = Join-Path $scopedWorkspaceState 'last-status-snapshot.json'
$scopedStatusCardPath = Join-Path $scopedWorkspaceState 'status-card.json'
if (Test-Path -LiteralPath $scopedSnapshotPath) {
  try { $lastSnapshot = Get-Content -LiteralPath $scopedSnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
if (Test-Path -LiteralPath $scopedStatusCardPath) {
  try { $statusCard = Get-Content -LiteralPath $scopedStatusCardPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$currentTaskContext = $null
$currentTaskContextPath = Join-Path $workspace 'current-task-context.json'
if (Test-Path -LiteralPath $currentTaskContextPath) {
  try { $currentTaskContext = Get-Content -LiteralPath $currentTaskContextPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$checkpointSelection = Get-SuperBrainRelevantCheckpoint $workspace $currentTaskContext $currentWorkspaceKey $TaskId
$activeCheckpoint = $checkpointSelection.checkpoint
$currentTaskContext = $checkpointSelection.context
$statusCardTaskId = Get-RestoreEvidenceTaskId $statusCard
$snapshotTaskId = Get-RestoreEvidenceTaskId $lastSnapshot
$statusCardWorkspaceMatch = Test-RestoreEvidenceWorkspace $statusCard $currentWorkspaceKey
$snapshotWorkspaceMatch = Test-RestoreEvidenceWorkspace $lastSnapshot $currentWorkspaceKey
$recoveryTaskId = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $TaskId.Trim() } elseif ($activeCheckpoint) { [string]$activeCheckpoint.taskId } elseif ($currentTaskContext) { [string]$currentTaskContext.taskId } elseif ($statusCardWorkspaceMatch -and -not [string]::IsNullOrWhiteSpace($statusCardTaskId)) { $statusCardTaskId } elseif ($snapshotWorkspaceMatch -and -not [string]::IsNullOrWhiteSpace($snapshotTaskId)) { $snapshotTaskId } else { '' }
$executionResolution = $null
$executionResolutionFailed = $false
$executionResolutionFailureCode = ''
$executionResolutionNoContract = $false
try {
  $contractArgs = @{Action='Resolve';WorkspaceKey=$currentWorkspaceKey;SessionKey=$hostSessionKey;NoExit=$true;Json=$true}
  if (-not [string]::IsNullOrWhiteSpace($recoveryTaskId)) { $contractArgs.TaskId = $recoveryTaskId }
  $contractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') @contractArgs 2>$null)
  if (-not $contractRaw) { throw 'execution contract returned no JSON' }
  $candidateResolution = (($contractRaw -join "`n") | ConvertFrom-Json)
  if (-not $candidateResolution -or $candidateResolution.ok -ne $true) {
    $executionResolutionFailed = $true
    $executionResolutionFailureCode = if($candidateResolution){[string]$candidateResolution.code}else{'EXECUTION_CONTRACT_EMPTY_RESULT'}
  } else {
    $executionResolutionNoContract = ([string]$candidateResolution.resolutionSource -eq 'none' -and [string]$candidateResolution.actionAuthorization -eq 'not_applicable')
    $executionScopeMatch = ($executionResolutionNoContract -or (-not [string]::IsNullOrWhiteSpace([string]$candidateResolution.taskId) -and (Test-SuperBrainWorkspaceKey ([string]$candidateResolution.workspaceKey) $currentWorkspaceKey) -and ([string]::IsNullOrWhiteSpace($recoveryTaskId) -or [string]$candidateResolution.taskId -eq $recoveryTaskId)))
    if ($executionScopeMatch) {
      $executionResolution = $candidateResolution
      if (-not $executionResolutionNoContract) { $recoveryTaskId = [string]$candidateResolution.taskId }
    } else {
      $executionResolutionFailed = $true
      $executionResolutionFailureCode = 'EXECUTION_CONTRACT_SCOPE_MISMATCH'
    }
  }
} catch {
  $executionResolution = $null
  $executionResolutionFailed = $true
  if ([string]::IsNullOrWhiteSpace($executionResolutionFailureCode)) { $executionResolutionFailureCode = 'EXECUTION_CONTRACT_RESOLVE_FAILED' }
}
if ($activeCheckpoint -and ([string]$activeCheckpoint.taskId -ne $recoveryTaskId -or ($checkpointSelection.state -notin @('relevant','legacy_compatible')))) { $activeCheckpoint = $null }
if ($currentTaskContext -and [string]$currentTaskContext.taskId -ne $recoveryTaskId) { $currentTaskContext = $null }
$statusCardActionRelevant = Test-RestoreScopedEvidence $statusCard $recoveryTaskId $currentWorkspaceKey
$snapshotActionRelevant = Test-RestoreScopedEvidence $lastSnapshot $recoveryTaskId $currentWorkspaceKey
$contractPlan = if ($executionResolution -and $executionResolution.workLineStatus -and $executionResolution.workLineStatus.PSObject.Properties['activePlan']) { $executionResolution.workLineStatus.activePlan } else { $null }
$contractPlanAvailable = ($contractPlan -and $contractPlan.PSObject.Properties['hasConcreteNextAction'] -and $contractPlan.hasConcreteNextAction -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$contractPlan.nextAction))
$contractPlanRelevant = ($contractPlanAvailable -and $executionResolution -and [string]$executionResolution.resumeFrom -in @('execution_contract','execution_contract_pending_reconciliation','parent_return','visible_conversation') -and -not $historicalRecoveryIntent)
$contractPlanAuthorized = ($contractPlanRelevant -and $executionResolution -and $executionResolution.claimAllowed -eq $true -and $executionResolution.needsConfirmation -ne $true)
$executionResolutionUnavailable = ($executionResolutionFailed -or (-not $executionResolutionNoContract -and -not [string]::IsNullOrWhiteSpace($recoveryTaskId) -and -not $executionResolution))
$executionAuthorizationWithheld = ($executionResolutionFailed -or (-not $executionResolutionNoContract -and $executionResolution -and ($executionResolution.actionAuthorization -ne 'allowed' -or $executionResolution.claimAllowed -ne $true -or $executionResolution.needsConfirmation -eq $true)))
$experienceIndex = ''
$experienceIndexPath = Join-Path $workspace 'experience-index.md'
$experienceIndexCount = 0
if (Test-Path $experienceIndexPath) {
  $experienceTitles = @()
  foreach ($line in Get-Content -LiteralPath $experienceIndexPath -Encoding UTF8) {
    if ($line -match '^###\s+(.+)$') {
      $experienceIndexCount += 1
      if ($experienceTitles.Count -lt 3) { $experienceTitles += (Limit-RestoreText ([string]$Matches[1]) 120) }
    }
  }
  if ($experienceTitles.Count -gt 0) {
    $experienceIndex = 'experience-index available: ' + ($experienceTitles -join '; ')
  } elseif ($experienceIndexCount -gt 0) {
    $experienceIndex = "experience-index entries=$experienceIndexCount"
  }
}
$profileCard = $null
$profileCardPath = Join-Path $workspace 'profile-card.json'
if (Test-Path $profileCardPath) {
  try { $profileCard = Get-Content -LiteralPath $profileCardPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$profileIntent = $false
if (-not [string]::IsNullOrWhiteSpace($Query)) {
  $lowerForProfile = $Query.ToLowerInvariant()
  foreach ($trigger in @($policy.retrieval.hybrid.profileIntentTriggers + $policy.retrieval.hybrid.personaIntentTriggers)) {
    if ($lowerForProfile.Contains(([string]$trigger).ToLowerInvariant())) { $profileIntent = $true; break }
  }
}
if ($profileIntent -and -not $profileCard) {
  try {
    $profileOutput = @(& (Join-Path $PSScriptRoot 'profile-card.ps1') -Refresh -MaxTokens 180 -Json 2>&1)
    $profileCard = (($profileOutput -join "`n") | ConvertFrom-Json)
  } catch {}
}

$shouldRecall = $Deep -or $MemoryMode -eq 'force'
$hasExplicitSessionId = -not [string]::IsNullOrWhiteSpace($SessionId)
$hasExplicitTaskId = -not [string]::IsNullOrWhiteSpace($TaskId)
$continuationOnly = $false
$targetedPlanRecall = $false
function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
$continueWord = U @(0x7EE7,0x7EED)
$connectWord = U @(0x63A5,0x7740)
$fastResumeWord = U @(0x5FEB,0x901F,0x7EED,0x63A5)
$continueDoingWord = $continueWord + (U @(0x505A))
$fastSessionPattern = '(?i)(^|\s)(' + [regex]::Escape($continueWord) + '|' + [regex]::Escape($connectWord) + '|' + [regex]::Escape($fastResumeWord) + '|resume|continue)\s+#?sess[_-][A-Za-z0-9._-]+|(^|\s)#?sess[_-][A-Za-z0-9._-]+'
$fastSessionResume = $hasExplicitSessionId -and ($Query -match $fastSessionPattern)
if ($fastSessionResume -and -not $BindSession) { $BindSession = $true }
if (-not [string]::IsNullOrWhiteSpace($Query) -and -not $fastSessionResume) {
  $lower = $Query.ToLowerInvariant()
  $continuationOnly = $lower.Trim() -in @($continueWord,$connectWord,$continueDoingWord,'continue','resume')
  foreach ($trigger in @($policy.retrieval.keywordTriggers + $policy.retrieval.semanticTriggers)) {
    if ($lower.Contains(([string]$trigger).ToLowerInvariant())) { $shouldRecall = $true; break }
  }
}
if ($historicalRecoveryIntent) { $shouldRecall = $true }
if ($fastSessionResume -and -not $Deep -and $MemoryMode -ne 'force') { $shouldRecall = $false }
if ($continuationOnly -and -not $Deep -and $MemoryMode -ne 'force') {
  if ($contractPlanRelevant) {
    $shouldRecall = $false
  } elseif ($hasExplicitTaskId) {
    $shouldRecall = $true
    $targetedPlanRecall = $true
  } else {
    $shouldRecall = $false
  }
}

$recall = @()
if ($shouldRecall) {
  $defaultRecallQuery = $continueWord + ' ' + (U @(0x4E0A,0x6B21)) + ' ' + (U @(0x6700,0x8FD1)) + ' ' + (U @(0x4F1A,0x8BDD)) + ' ' + (U @(0x8BB0,0x5FC6)) + ' ' + (U @(0x504F,0x597D)) + ' ' + (U @(0x9879,0x76EE))
  $recallQuery = if ($targetedPlanRecall -and -not [string]::IsNullOrWhiteSpace($recoveryTaskId)) { 'task ' + $recoveryTaskId + ' ' + [string]$executionResolution.focusId + ' next action plan' } elseif ([string]::IsNullOrWhiteSpace($Query)) { $defaultRecallQuery } else { $Query }
  $recallOutput = @(& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $recallQuery -TopK $TopK -MaxTokens ([Math]::Max(200, $MaxTokens - 300)) -MemoryMode $MemoryMode -Json 2>&1)
  try { $recall = @((($recallOutput -join "`n") | ConvertFrom-Json) | Where-Object { $_ -ne $null }) } catch { $recall = @() }
}

if ($targetedPlanRecall) {
  $taskNeedle = ([string]$recoveryTaskId).ToLowerInvariant()
  $workspaceNeedle = ([string]$currentWorkspaceKey).ToLowerInvariant()
  $recall = @($recall | Where-Object {
    $card = if ($_.evidenceCard) { $_.evidenceCard } else { $_ }
    $taskScopedText = (([string]$card.claim + ' ' + [string]$card.snippet + ' ' + [string]$card.source + ' ' + [string]$_.source).ToLowerInvariant())
    -not [string]::IsNullOrWhiteSpace($taskNeedle) -and
    -not [string]::IsNullOrWhiteSpace($workspaceNeedle) -and
    $taskScopedText.Contains($taskNeedle) -and
    $taskScopedText.Contains($workspaceNeedle)
  })
}

if ($historicalRecoveryIntent) {
  $recall = @($recall | Where-Object {
    $card = if ($_.evidenceCard) { $_.evidenceCard } else { $_ }
    $tags = @($card.tags)
    $verified = ([string]$card.lastVerified -eq 'verified' -or $tags -contains '[VERIFIED]')
    $current = ($tags -contains '[CURRENT]')
    $relevant = ([string]$card.relevanceStatus -eq 'matched' -or $_.relevanceOk -eq $true)
    $verified -and $current -and $relevant -and -not ($tags -contains '[STALE]')
  })
}
$historicalEvidenceStatus = if (-not $historicalRecoveryIntent) { 'not_requested' } elseif (@($recall).Count -gt 0) { 'found' } else { 'missing' }
$evidenceClaimAllowed = (-not $historicalRecoveryIntent -or $historicalEvidenceStatus -eq 'found')

$sessionBinding = $null
if ($BindSession) {
  try {
    $bindingOutput = @(& (Join-Path $PSScriptRoot 'session-binding.ps1') -Action Bind -MemoryMode $MemoryMode -TtlMinutes $TtlMinutes -MaxTokens $MaxTokens -TopK $TopK -Query $Query -SessionId $SessionId -TaskId $recoveryTaskId -Json 2>&1)
    $sessionBinding = (($bindingOutput -join "`n") | ConvertFrom-Json)
  } catch {
    $sessionBinding = [pscustomobject]@{ ok=$false; status='error'; reason=$_.Exception.Message }
  }
} else {
  try {
    $bindingOutput = @(& (Join-Path $PSScriptRoot 'session-binding.ps1') -Action Get -Json 2>&1)
    $loadedBinding = (($bindingOutput -join "`n") | ConvertFrom-Json)
    if ($loadedBinding.binding -and $loadedBinding.binding.health -and $loadedBinding.binding.health.active -eq $true) { $sessionBinding = $loadedBinding }
  } catch {}
}

if ($executionAuthorizationWithheld) {
  $activeCheckpoint = Remove-SuperBrainExecutableActions $activeCheckpoint
  $statusCard = Remove-SuperBrainExecutableActions $statusCard
  $lastSnapshot = Remove-SuperBrainExecutableActions $lastSnapshot
  $sessionBinding = Remove-SuperBrainExecutableActions $sessionBinding
}

function New-CompactEvidenceCard([object]$Card) {
  if (-not $Card) { return $null }
  $claim = Limit-RestoreText ([string]$Card.claim) 220
  $evidenceCard = [ordered]@{
    source = Limit-RestoreText ([string]$Card.source) 240
    sourceType = Limit-RestoreText ([string]$Card.sourceType) 64
    claim = $claim
    whyRelevant = Limit-RestoreText ([string]$Card.whyRelevant) 160
    confidence = $Card.confidence
    lastVerified = Limit-RestoreText ([string]$Card.lastVerified) 32
    relevanceStatus = Limit-RestoreText ([string]$Card.relevanceStatus) 48
    matchedTerms = @(Limit-RestoreList @($Card.matchedTerms) 8 48)
    requiredMatchCount = $Card.requiredMatchCount
    tags = @(Limit-RestoreList @($Card.tags) 8 32)
    tokenEstimate = $Card.tokenEstimate
  }
  if ($Deep) {
    $snippet = [string]$Card.snippet
    if ([string]::IsNullOrWhiteSpace($snippet)) { $snippet = $claim }
    $evidenceCard.snippet = Limit-RestoreText $snippet 260
  }
  return [pscustomobject]$evidenceCard
}

function New-CompactCheckpoint([object]$Checkpoint) {
  if (-not $Checkpoint) { return $null }
  return [pscustomobject]@{
    taskId = Limit-RestoreText ([string]$Checkpoint.taskId) 160
    workspaceKey = Limit-RestoreText ([string]$Checkpoint.workspaceKey) 64
    workspaceConfidence = if ([string]::IsNullOrWhiteSpace([string]$Checkpoint.workspaceKey)) { 'legacy_low' } else { 'exact' }
    sessionId = Limit-RestoreText ([string]$Checkpoint.sessionId) 160
    status = Limit-RestoreText ([string]$Checkpoint.status) 32
    goal = Limit-RestoreText ([string]$Checkpoint.goal) 260
    currentPhase = Limit-RestoreText ([string]$Checkpoint.currentPhase) 120
    completedSteps = @(Limit-RestoreList @($Checkpoint.completedSteps) 6 180)
    pendingSteps = @(Limit-RestoreList @($Checkpoint.pendingSteps) 6 180)
    currentStep = Limit-RestoreText ([string]$Checkpoint.currentStep) 220
    nextAction = Limit-RestoreText ([string]$Checkpoint.nextAction) 220
    changedFiles = @(Limit-RestoreList @($Checkpoint.changedFiles) 6 200)
    verificationCommands = @(Limit-RestoreList @($Checkpoint.verificationCommands) 4 220)
    verificationResults = @(Limit-RestoreList @($Checkpoint.verificationResults) 4 220)
    waitingForUser = [bool]$Checkpoint.waitingForUser
    updatedAt = Limit-RestoreText $(if ($Checkpoint.updatedAt) { [string]$Checkpoint.updatedAt } else { [string]$Checkpoint.timestamp }) 48
    checkedAt = Limit-RestoreText ([string]$Checkpoint.checkedAt) 48
    blockers = @(Limit-RestoreList @($Checkpoint.blockers) 2 180)
  }
}

function New-CompactProfileCard([object]$Card) {
  if (-not $Card) { return $null }
  return [pscustomobject]@{
    ok = [bool]$Card.ok
    checkedAt = Limit-RestoreText ([string]$Card.checkedAt) 48
    tokenBudget = $(try { [Math]::Min(720,[Math]::Max(0,[int]$Card.tokenBudget)) } catch { 0 })
    source = Limit-RestoreText ([string]$Card.source) 80
    profileSummary = Limit-RestoreText ([string]$Card.profileSummary) 600
    evidenceCards = @($Card.evidenceCards | Select-Object -First 3 | ForEach-Object { New-CompactEvidenceCard $_ } | Where-Object { $_ -ne $null })
    nextAction = Limit-RestoreText ([string]$Card.nextAction) 220
  }
}

function New-CompactSessionBinding([object]$Result,[string]$ExpectedTaskId,[string]$ExpectedWorkspaceKey) {
  if (-not $Result) { return $null }
  $binding = $Result.binding
  $bindingScopeMatch = ($binding -and -not [string]::IsNullOrWhiteSpace($ExpectedTaskId) -and [string]$binding.taskId -eq $ExpectedTaskId -and $binding.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$binding.workspaceKey) $ExpectedWorkspaceKey))
  return [pscustomobject]@{
    ok = [bool]$Result.ok
    action = Limit-RestoreText ([string]$Result.action) 32
    status = Limit-RestoreText ([string]$Result.status) 32
    reason = Limit-RestoreText ([string]$Result.reason) 120
    binding = if ($binding) { [pscustomobject]@{
      bindingId=Limit-RestoreText ([string]$binding.bindingId) 120
      sessionId=Limit-RestoreText ([string]$binding.sessionId) 160
      taskId=Limit-RestoreText ([string]$binding.taskId) 160
      workspaceKey=Limit-RestoreText ([string]$binding.workspaceKey) 64
      status=Limit-RestoreText ([string]$binding.status) 32
      memoryMode=Limit-RestoreText ([string]$binding.memoryMode) 16
      updatedAt=Limit-RestoreText ([string]$binding.updatedAt) 48
      expiresAt=Limit-RestoreText ([string]$binding.expiresAt) 48
      scopeMatch=[bool]$bindingScopeMatch
      currentStep=if($bindingScopeMatch){Limit-RestoreText ([string]$binding.currentStep) 180}else{''}
      nextAction=if($bindingScopeMatch){Limit-RestoreText ([string]$binding.nextAction) 220}else{''}
      health=if($binding.health){[pscustomobject]@{active=[bool]$binding.health.active;expired=[bool]$binding.health.expired;packageVersionMatch=[bool]$binding.health.packageVersionMatch;memoryRootMatch=[bool]$binding.health.memoryRootMatch;rawContentRisk=[bool]$binding.health.rawContentRisk}}else{$null}
    } } else { $null }
  }
}

$statusCardNextAction = ''
if ($executionAuthorizationWithheld) {
  $statusCardNextAction = ''
} elseif ($contractPlanRelevant) {
  $statusCardNextAction = [string]$contractPlan.nextAction
} elseif ($activeCheckpoint -and -not [string]::IsNullOrWhiteSpace([string]$activeCheckpoint.nextAction)) {
  $statusCardNextAction = [string]$activeCheckpoint.nextAction
} elseif ($statusCard -and $statusCardActionRelevant) {
  $statusCardNextAction = [string]$statusCard.nextAction
}
$compactExecutionResolution = ConvertTo-SuperBrainCompactExecutionResolution $executionResolution
$compactWorkLineStatus = if ($compactExecutionResolution) { $compactExecutionResolution.workLineStatus } else { $null }
$compactContinuityStateCard = if ($compactExecutionResolution) { $compactExecutionResolution.continuityStateCard } else { $null }
$compactContractPlan = if ($contractPlanRelevant) { ConvertTo-SuperBrainCompactPlan $contractPlan 220 } else { $null }
$compactParentPlan = if ($contractPlanRelevant -and $executionResolution -and $executionResolution.workLineStatus -and $executionResolution.workLineStatus.PSObject.Properties['nextPlan']) { ConvertTo-SuperBrainCompactPlan $executionResolution.workLineStatus.nextPlan 180 } else { $null }

$recoveryPoint = [pscustomobject]@{
  source = if ($executionResolutionFailed) { 'execution_contract_resolution_failed' } elseif ($executionAuthorizationWithheld) { 'execution_contract_action_withheld' } elseif ($contractPlanRelevant) { 'execution_contract_plan' } elseif ($historicalRecoveryIntent) { 'historical_evidence_only' } elseif ($executionResolution -and [string]$executionResolution.resumeFrom -in @('execution_contract','execution_contract_pending_reconciliation','parent_return','visible_conversation')) { 'execution_contract_plan_missing' } elseif ($activeCheckpoint) { 'active_checkpoint' } elseif ($statusCardActionRelevant) { 'status_card' } elseif ($snapshotActionRelevant) { 'status_snapshot' } else { 'none' }
  taskId = Limit-RestoreText $recoveryTaskId 160
  workspaceKey = $currentWorkspaceKey
  focusId = if ($executionResolution) { Limit-RestoreText ([string]$executionResolution.focusId) 120 } else { '' }
  focusLabel = if ($executionResolution) { Limit-RestoreText ([string]$executionResolution.focusLabel) 100 } else { '' }
  resumeFrom = if ($executionResolution) { Limit-RestoreText ([string]$executionResolution.resumeFrom) 48 } else { '' }
  nextAction = if ($contractPlanRelevant) { Limit-RestoreText ([string]$contractPlan.nextAction) 220 } else { '' }
  plan = $compactContractPlan
  parentPlan = $compactParentPlan
  continuityStateCard = $compactContinuityStateCard
  workLineStatus = if ($historicalRecoveryIntent) { $null } else { $compactWorkLineStatus }
  latestMessageClassification = if ($historicalRecoveryIntent) { $null } elseif ($compactExecutionResolution) { $compactExecutionResolution.latestMessageClassification } else { $null }
  planAvailable = $contractPlanRelevant
  planAuthorized = $contractPlanAuthorized
  claimAllowed = if ($executionResolution) { [bool]$executionResolution.claimAllowed } else { $false }
  needsConfirmation = if ($executionResolution) { [bool]$executionResolution.needsConfirmation } else { $true }
  priorityOrder = @('task_scoped_execution_contract','bound_return_card_plan','task_scoped_checkpoint','bounded_memory_evidence_if_plan_missing')
  memoryFallback = if ($contractPlanRelevant) { 'not_required' } elseif ($targetedPlanRecall -and @($recall).Count -gt 0) { 'task_and_workspace_scoped_evidence_found' } elseif ($targetedPlanRecall) { 'task_and_workspace_scoped_evidence_missing' } else { 'not_requested' }
}

$packetNextAction = if ($historicalEvidenceStatus -eq 'missing') { 'Historical evidence is missing/unknown; report that explicitly and do not infer prior task details.' } elseif ($historicalEvidenceStatus -eq 'found') { 'Use only the current verified relevant evidenceCards; do not infer details beyond their evidence.' } elseif ($executionResolutionFailed) { 'Execution contract resolution failed; repair or re-run the resolver before mutation.' } elseif ($executionResolutionUnavailable) { 'Latest execution action is unavailable; use scoped state only to locate the task, then reconcile a current execution contract before mutation.' } elseif ($executionAuthorizationWithheld) { [string]$executionResolution.nextAction } elseif ($contractPlanAuthorized) { [string]$contractPlan.nextAction } elseif ($contractPlanRelevant) { 'The plan is known but is not authorized until the latest instruction and topic affinity are reconciled.' } elseif ($targetedPlanRecall -and @($recall).Count -eq 0) { 'Task-and-workspace-scoped plan evidence is missing; do not use generic status memory or infer a plan.' } elseif ($targetedPlanRecall) { 'Use only the bounded evidence cards that contain both the exact task id and workspace key; do not infer beyond them.' } elseif ($activeCheckpoint -or $statusCardActionRelevant -or $snapshotActionRelevant -or $fastSessionResume) { 'Latest execution action is unknown; use the scoped status only to locate the task, then reconcile a current execution contract before mutation.' } elseif ($shouldRecall) { 'Use evidenceCards only if relevant; do not inject raw memory beyond the token budget.' } else { 'No deep recall needed unless the user asks for continuity, memory, preferences, or previous-session context.' }
$boundedEvidenceCards = @($recall | Select-Object -First $RestoreMaxTopK | ForEach-Object {
  $card = if ($_.evidenceCard) { $_.evidenceCard } else { $_ }
  New-CompactEvidenceCard $card
} | Where-Object { $_ -ne $null })
$lightPacket = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  memoryMode = $MemoryMode
  packageRoot = Limit-RestoreText $Root 512
  memoryRoot = Limit-RestoreText $MemoryRoot 512
  workspaceKey = $currentWorkspaceKey
  tokenBudget = $MaxTokens
  topK = $TopK
  recallTriggered = $shouldRecall
  routeIntent = Limit-RestoreText $routeIntent 64
  historicalEvidenceStatus = $historicalEvidenceStatus
  evidenceStatus = [pscustomobject]@{
    status = $historicalEvidenceStatus
    historicalRecovery = $historicalRecoveryIntent
    claimAllowed = $evidenceClaimAllowed
    verifiedCurrentCount = [Math]::Min($RestoreMaxTopK,@($recall).Count)
    reason = if ($historicalEvidenceStatus -eq 'missing') { 'No current verified relevant historical evidence matched the request.' } elseif ($historicalEvidenceStatus -eq 'found') { 'Current verified relevant historical evidence is available.' } else { 'Historical recovery was not requested.' }
  }
  state = if ($state) { [pscustomobject]@{ version=Limit-RestoreText ([string]$state.version) 64; ok=$state.ok; hookOk=$state.hookOk; lastVerifyOk=$state.lastVerifyOk; updatedAt=Limit-RestoreText ([string]$state.updatedAt) 48 } } else { $null }
  executionResolution = if ($historicalRecoveryIntent) { $null } else { $compactExecutionResolution }
  executionResolutionStatus = if($executionResolutionFailed){'failed'}elseif($executionResolutionNoContract){'no_contract'}elseif($executionAuthorizationWithheld){'withheld'}else{'allowed'}
  executionResolutionFailureCode = $executionResolutionFailureCode
  recoveryPoint = $recoveryPoint
  continuityStateCard = $compactContinuityStateCard
  statusCard = if ($statusCardActionRelevant) { [pscustomobject]@{ taskId=$recoveryTaskId; workspaceKey=$currentWorkspaceKey; version=Limit-RestoreText ([string]$statusCard.version) 64; ok=$statusCard.ok; packageOk=$statusCard.packageOk; verifyOk=$statusCard.verifyOk; updatedAt=Limit-RestoreText ([string]$statusCard.updatedAt) 48; risksCount=$statusCard.risksCount; nextAction=Limit-RestoreText $statusCardNextAction 220 } } elseif ($statusCard) { [pscustomobject]@{ nextAction='' } } else { $null }
  checkpointSelection = [pscustomobject]@{ state=$checkpointSelection.state; contextState=$checkpointSelection.contextState; workspaceKey=$checkpointSelection.workspaceKey; source=Limit-RestoreText ([string]$checkpointSelection.source) 120; confidence=$checkpointSelection.confidence; legacyCompatibility=[bool]$checkpointSelection.legacyCompatibility; candidateTaskId=Limit-RestoreText ([string]$checkpointSelection.candidateTaskId) 160; ignoredTaskId=Limit-RestoreText ([string]$checkpointSelection.ignoredTaskId) 160 }
  activeCheckpoint = if ($activeCheckpoint) { New-CompactCheckpoint $activeCheckpoint } else { $null }
  lastSnapshot = if ($snapshotActionRelevant) { [pscustomobject]@{ taskId=$recoveryTaskId; workspaceKey=$currentWorkspaceKey; summary=Limit-RestoreText ([string]$lastSnapshot.summary) 220; nextAction=Limit-RestoreText ([string]$lastSnapshot.nextAction) 220; checkedAt=Limit-RestoreText ([string]$lastSnapshot.checkedAt) 48 } } elseif ($lastSnapshot) { [pscustomobject]@{ nextAction='' } } else { $null }
  experienceIndexPreview = Limit-RestoreText $experienceIndex 420
  profileCard = if ($profileIntent) { New-CompactProfileCard $profileCard } else { $null }
  sessionBinding = New-CompactSessionBinding $sessionBinding $recoveryTaskId $currentWorkspaceKey
  fastSessionResume = $fastSessionResume
  resumePriority = if ($fastSessionResume) { @('currentVisibleContext','currentTodoCheckpoint','explicitSessionBinding','statusCard','superBrainState','lastSnapshots') } else { @() }
  evidenceCards = $boundedEvidenceCards
  nextAction = Limit-RestoreText $packetNextAction 320
  packetLimits = [pscustomobject]@{ maxChars=$RestoreMaxPacketChars; maxEvidenceCards=$RestoreMaxTopK; maxCheckpointSteps=6; maxWorkLines=6; effectiveMaxTokens=$MaxTokens; effectiveTopK=$TopK; serializedChars=0; truncated=$false }
}

$packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
if ($packetJson.Length -gt $RestoreMaxPacketChars) {
  $lightPacket.packetLimits.truncated = $true
  $lightPacket.profileCard = $null
  $lightPacket.experienceIndexPreview = ''
  $lightPacket.evidenceCards = @($lightPacket.evidenceCards | Select-Object -First 2)
  $packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
}
if ($packetJson.Length -gt $RestoreMaxPacketChars) {
  $lightPacket.evidenceCards = @()
  $lightPacket.sessionBinding = $null
  $lightPacket.state = $null
  $lightPacket.statusCard = $null
  $lightPacket.lastSnapshot = $null
  $lightPacket.activeCheckpoint = $null
  $packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
}
if ($packetJson.Length -gt $RestoreMaxPacketChars) {
  $minimalExecution = if ($compactExecutionResolution) { [pscustomobject]@{ ok=$compactExecutionResolution.ok; resumeFrom=$compactExecutionResolution.resumeFrom; claimAllowed=$compactExecutionResolution.claimAllowed; needsConfirmation=$compactExecutionResolution.needsConfirmation; taskId=$compactExecutionResolution.taskId; workspaceKey=$compactExecutionResolution.workspaceKey; focusId=$compactExecutionResolution.focusId; focusLabel=$compactExecutionResolution.focusLabel; instructionMode=$compactExecutionResolution.instructionMode; nextAction=$compactExecutionResolution.nextAction; contractRevision=$compactExecutionResolution.contractRevision; workLineStatus=if($compactExecutionResolution.workLineStatus){[pscustomobject]@{activePlan=$compactExecutionResolution.workLineStatus.activePlan;mainPlan=$compactExecutionResolution.workLineStatus.mainPlan}}else{$null} } } else { $null }
  $lightPacket = [pscustomobject]@{
    ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); memoryMode=$MemoryMode; workspaceKey=$currentWorkspaceKey; tokenBudget=$MaxTokens; topK=$TopK; recallTriggered=$shouldRecall; historicalEvidenceStatus=$historicalEvidenceStatus
    executionResolution=if($historicalRecoveryIntent){$null}else{$minimalExecution}
    recoveryPoint=[pscustomobject]@{source=$recoveryPoint.source;taskId=$recoveryPoint.taskId;workspaceKey=$currentWorkspaceKey;focusId=$recoveryPoint.focusId;focusLabel=$recoveryPoint.focusLabel;resumeFrom=$recoveryPoint.resumeFrom;nextAction=$recoveryPoint.nextAction;plan=$compactContractPlan;continuityStateCard=$compactContinuityStateCard;planAvailable=$recoveryPoint.planAvailable;planAuthorized=$recoveryPoint.planAuthorized;claimAllowed=$recoveryPoint.claimAllowed;needsConfirmation=$recoveryPoint.needsConfirmation}
    checkpointSelection=$lightPacket.checkpointSelection; evidenceCards=@(); nextAction=Limit-RestoreText $packetNextAction 320
    packetLimits=[pscustomobject]@{maxChars=$RestoreMaxPacketChars;maxEvidenceCards=$RestoreMaxTopK;maxCheckpointSteps=6;maxWorkLines=6;effectiveMaxTokens=$MaxTokens;effectiveTopK=$TopK;serializedChars=0;truncated=$true}
  }
  $packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
}
for ($packetPass = 0; $packetPass -lt 3; $packetPass++) {
  $lightPacket.packetLimits.serializedChars = $packetJson.Length
  $packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
}
if ($packetJson.Length -gt $RestoreMaxPacketChars) { throw 'SESSION_RESTORE_PACKET_LIMIT_EXCEEDED' }
Write-JsonUtf8NoBom $statusPath $lightPacket 12 -Compress

if ($Json) {
  $packetJson
} else {
  Write-Host "SESSION_RESTORE_OK triggered=$shouldRecall budget=$MaxTokens cards=$(@($lightPacket.evidenceCards).Count) status=$statusPath"
}
