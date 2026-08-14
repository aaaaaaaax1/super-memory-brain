param(
  [string]$Query = '',
  [ValidateSet('auto','force','off')]
  [string]$MemoryMode = 'auto',
  [int]$MaxTokens = 600,
  [int]$TopK = 2,
  # A bounded lower test/transport budget. Zero preserves the production
  # default; callers cannot raise the normal 24k packet ceiling.
  [int]$MaxPacketChars = 0,
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
$manifest = Get-SuperBrainManifest $Root
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$statusPath = Join-Path $workspace 'last-session-restore.json'
$RestoreMaxTokens = 4000
$RestoreMaxTopK = 8
$RestoreMaxPacketChars = 24000
if ($MaxPacketChars -gt 0) {
  $RestoreMaxPacketChars = [Math]::Max(2048,[Math]::Min(24000,$MaxPacketChars))
}

function Limit-RestoreText([string]$Value,[int]$Max=220) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = (([string]$Value).Trim() -replace '\s+',' ')
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Limit-RestoreList([object[]]$Items,[int]$MaxItems=8,[int]$MaxChars=160) {
  return @($Items | Select-Object -First $MaxItems | ForEach-Object { Limit-RestoreText ([string]$_) $MaxChars })
}

function Add-RestorePacketTruncationStage([object]$Packet,[string]$Stage) {
  if (-not $Packet -or -not $Packet.packetLimits -or [string]::IsNullOrWhiteSpace($Stage)) { return }
  $stages = @()
  if ($Packet.packetLimits.PSObject.Properties['truncationStages']) { $stages = @($Packet.packetLimits.truncationStages) }
  if (-not ($stages -contains $Stage)) { $stages += $Stage }
  $Packet.packetLimits.truncationStages = @($stages)
}

function Set-RestorePacketEvidenceCount([object]$Packet) {
  if (-not $Packet -or -not $Packet.packetLimits) { return }
  $Packet.packetLimits.evidenceCardsRetained = @($Packet.evidenceCards).Count
}

function New-TruncatedRestoreExecutionResolution([object]$Resolution) {
  if (-not $Resolution) { return $null }
  return [pscustomobject]@{
    ok = [bool]$Resolution.ok
    resumeFrom = Limit-RestoreText ([string]$Resolution.resumeFrom) 48
    resolutionSource = Limit-RestoreText ([string]$Resolution.resolutionSource) 64
    claimAllowed = [bool]$Resolution.claimAllowed
    needsConfirmation = [bool]$Resolution.needsConfirmation
    taskId = Limit-RestoreText ([string]$Resolution.taskId) 160
    workspaceKey = Limit-RestoreText ([string]$Resolution.workspaceKey) 64
    focusId = Limit-RestoreText ([string]$Resolution.focusId) 120
    focusLabel = Limit-RestoreText ([string]$Resolution.focusLabel) 100
    instructionMode = Limit-RestoreText ([string]$Resolution.instructionMode) 48
    nextAction = Limit-RestoreText ([string]$Resolution.nextAction) 160
    contractRevision = [int]$Resolution.contractRevision
    planFingerprint = Limit-RestoreText ([string]$Resolution.planFingerprint) 32
    actionAuthorization = Limit-RestoreText ([string]$Resolution.actionAuthorization) 24
  }
}

function New-TruncatedRestoreResumeReceipt([object]$Receipt) {
  if (-not $Receipt) { return $null }
  $progress = $Receipt.assistantProgress
  return [pscustomobject]@{
    schema = Limit-RestoreText ([string]$Receipt.schema) 64
    state = Limit-RestoreText ([string]$Receipt.state) 80
    latestUserInstruction = Limit-RestoreText ([string]$Receipt.latestUserInstruction) 180
    assistantProgress = if ($progress) { [pscustomobject]@{
      available = [bool]$progress.available
      state = Limit-RestoreText ([string]$progress.state) 64
      scopeCurrent = [bool]$progress.scopeCurrent
      current = [bool]$progress.current
      lastConfirmedSentence = Limit-RestoreText ([string]$progress.lastConfirmedSentence) 160
      currentPhase = Limit-RestoreText ([string]$progress.currentPhase) 96
      currentStep = Limit-RestoreText ([string]$progress.currentStep) 160
      priorNextAction = Limit-RestoreText ([string]$progress.priorNextAction) 160
      priorNextActionState = Limit-RestoreText ([string]$progress.priorNextActionState) 48
    } } else { $null }
    lastConfirmedSentence = Limit-RestoreText ([string]$Receipt.lastConfirmedSentence) 160
    currentPhase = Limit-RestoreText ([string]$Receipt.currentPhase) 96
    currentStep = Limit-RestoreText ([string]$Receipt.currentStep) 160
    nextAction = Limit-RestoreText ([string]$Receipt.nextAction) 160
    returnPoint = if ($Receipt.returnPoint) { [pscustomobject]@{
      taskId = Limit-RestoreText ([string]$Receipt.returnPoint.taskId) 160
      focusId = Limit-RestoreText ([string]$Receipt.returnPoint.focusId) 120
      focusLabel = Limit-RestoreText ([string]$Receipt.returnPoint.focusLabel) 100
      resumeFrom = Limit-RestoreText ([string]$Receipt.returnPoint.resumeFrom) 64
    } } else { $null }
  }
}

function New-TruncatedRestoreRecoveryPoint([object]$Point) {
  if (-not $Point) { return $null }
  return [pscustomobject]@{
    source = Limit-RestoreText ([string]$Point.source) 120
    taskId = Limit-RestoreText ([string]$Point.taskId) 160
    workspaceKey = Limit-RestoreText ([string]$Point.workspaceKey) 64
    focusId = Limit-RestoreText ([string]$Point.focusId) 120
    focusLabel = Limit-RestoreText ([string]$Point.focusLabel) 100
    resumeFrom = Limit-RestoreText ([string]$Point.resumeFrom) 64
    nextAction = Limit-RestoreText ([string]$Point.nextAction) 160
    planAvailable = [bool]$Point.planAvailable
    planAuthorized = [bool]$Point.planAuthorized
    claimAllowed = [bool]$Point.claimAllowed
    needsConfirmation = [bool]$Point.needsConfirmation
  }
}

function New-TruncatedRestoreCheckpoint([object]$Checkpoint) {
  if (-not $Checkpoint) { return $null }
  return [pscustomobject]@{
    checkpointId = Limit-RestoreText ([string]$Checkpoint.checkpointId) 96
    checkpointRevision = [int]$Checkpoint.checkpointRevision
    contractRevision = [int]$Checkpoint.contractRevision
    currentPhase = Limit-RestoreText ([string]$Checkpoint.currentPhase) 96
    currentStep = Limit-RestoreText ([string]$Checkpoint.currentStep) 160
    nextAction = Limit-RestoreText ([string]$Checkpoint.nextAction) 160
    returnPoint = $Checkpoint.returnPoint
  }
}

function Get-RestoreInstructionAnchor([string]$MemoryBase,[string]$WorkspaceKey,[string]$SessionKey,[string]$TaskId='') {
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{ok=$false;available=$false;status='error';code='SESSION_RESTORE_INSTRUCTION_ANCHOR_RUNTIME_MISSING';anchor=$null}
  }
  try {
    $request = @{ workspaceKey=$WorkspaceKey; ownerSessionKey=$SessionKey }
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $request.taskId = $TaskId }
    $payload = $request | ConvertTo-Json -Depth 6 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $raw = @(& python -X utf8 $runtime --state-root $MemoryBase get-instruction-anchor --request-base64 $encoded 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) { throw 'instruction anchor protocol returned no JSON' }
    $result = $text.Substring($start,$end-$start+1) | ConvertFrom-Json
    if ($exitCode -ne 0 -or -not $result -or $result.ok -ne $true) {
      return [pscustomobject]@{ok=$false;available=$false;status='error';code=if($result -and $result.code){[string]$result.code}else{'SESSION_RESTORE_INSTRUCTION_ANCHOR_LOOKUP_FAILED'};anchor=$null}
    }
    return $result
  } catch {
    return [pscustomobject]@{ok=$false;available=$false;status='error';code='SESSION_RESTORE_INSTRUCTION_ANCHOR_LOOKUP_FAILED';anchor=$null}
  }
}

function New-CompactRestoreInstructionAnchor([object]$Anchor) {
  if (-not $Anchor) { return $null }
  return [pscustomobject]@{
    available = $true
    taskId = Limit-RestoreText ([string]$Anchor.taskId) 160
    workspaceKey = Limit-RestoreText ([string]$Anchor.workspaceKey) 64
    sequence = [int]$Anchor.sequence
    globalSequence = [int]$Anchor.globalSequence
    contentHash = Limit-RestoreText ([string]$Anchor.contentHash) 64
    latestUserInstruction = Limit-RestoreText ([string]$Anchor.instruction) 320
    source = Limit-RestoreText ([string]$Anchor.source) 120
    createdAt = Limit-RestoreText ([string]$Anchor.createdAt) 48
    classification = if ($Anchor.classification) { [pscustomobject]@{ mode=Limit-RestoreText ([string]$Anchor.classification.mode) 48; topicAffinity=Limit-RestoreText ([string]$Anchor.classification.topicAffinity) 96; confidence=Limit-RestoreText ([string]$Anchor.classification.confidence) 24; needsClarification=[bool]$Anchor.classification.needsClarification } } else { $null }
  }
}

function Get-RestoreContinuationReceipt([string]$MemoryBase,[string]$WorkspaceKey,[string]$SessionKey,[string]$TaskId='') {
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{ok=$false;available=$false;status='error';code='SESSION_RESTORE_CONTINUATION_RECEIPT_RUNTIME_MISSING';receipt=$null}
  }
  try {
    $request = @{ workspaceKey=$WorkspaceKey; ownerSessionKey=$SessionKey }
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $request.taskId = $TaskId }
    $payload = $request | ConvertTo-Json -Depth 6 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $raw = @(& python -X utf8 $runtime --state-root $MemoryBase get-continuation-receipt --request-base64 $encoded 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) { throw 'continuation receipt protocol returned no JSON' }
    $result = $text.Substring($start,$end-$start+1) | ConvertFrom-Json
    if ($exitCode -ne 0 -or -not $result -or $result.ok -ne $true) {
      return [pscustomobject]@{ok=$false;available=$false;status='error';code=if($result -and $result.code){[string]$result.code}else{'SESSION_RESTORE_CONTINUATION_RECEIPT_LOOKUP_FAILED'};receipt=$null}
    }
    return $result
  } catch {
    return [pscustomobject]@{ok=$false;available=$false;status='error';code='SESSION_RESTORE_CONTINUATION_RECEIPT_LOOKUP_FAILED';receipt=$null}
  }
}

function Get-RestoreRecoveryCheckpoint([string]$MemoryBase,[string]$WorkspaceKey,[string]$SessionKey,[string]$TaskId='') {
  if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($SessionKey)) {
    return [pscustomobject]@{ok=$false;available=$false;status='not_requested';code='RECOVERY_CHECKPOINT_NOT_REQUESTED';checkpoint=$null}
  }
  $runtime = Join-Path $PSScriptRoot 'recovery-checkpoint.ps1'
  if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{ok=$false;available=$false;status='error';code='RECOVERY_CHECKPOINT_RUNTIME_MISSING';checkpoint=$null}
  }
  try {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtime -Action Validate -StateRoot $MemoryBase -TaskId $TaskId -WorkspaceKey $WorkspaceKey -SessionKey $SessionKey -Json 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $result = if ($text) { ConvertFrom-SuperBrainJsonOutput $text 'recovery checkpoint validation' } else { $null }
    if ($exitCode -ne 0 -or -not $result -or $result.ok -ne $true) {
      return [pscustomobject]@{ok=$false;available=$false;status=if($result){[string]$result.status}else{'error'};code=if($result -and $result.code){[string]$result.code}else{'RECOVERY_CHECKPOINT_VALIDATE_FAILED'};checkpoint=if($result){$result.checkpoint}else{$null}}
    }
    return [pscustomobject]@{ok=$true;available=$true;status='current';code='RECOVERY_CHECKPOINT_CURRENT';checkpoint=$result.checkpoint;path=[string]$result.path}
  } catch {
    return [pscustomobject]@{ok=$false;available=$false;status='error';code='RECOVERY_CHECKPOINT_VALIDATE_FAILED';checkpoint=$null}
  }
}

function New-CompactRestoreContinuationReceipt([object]$Receipt,[object]$Binding=$null,[object]$Compatibility=$null) {
  if (-not $Receipt) { return $null }
  $state = if ($Receipt.state) { $Receipt.state } else { $null }
  return [pscustomobject]@{
    available = $true
    taskId = Limit-RestoreText ([string]$Receipt.taskId) 160
    workspaceKey = Limit-RestoreText ([string]$Receipt.workspaceKey) 64
    taskInstanceId = Limit-RestoreText ([string]$Receipt.taskInstanceId) 80
    packageVersion = Limit-RestoreText ([string]$Receipt.packageVersion) 64
    globalSequence = [int]$Receipt.globalSequence
    contractRevision = [int]$Receipt.contractRevision
    planFingerprint = Limit-RestoreText ([string]$Receipt.planFingerprint) 96
    source = Limit-RestoreText ([string]$Receipt.source) 120
    createdAt = Limit-RestoreText ([string]$Receipt.createdAt) 48
    binding = if ($Binding) { [pscustomobject]@{
      state=Limit-RestoreText ([string]$Binding.state) 64
      current=[bool]$Binding.current
      code=Limit-RestoreText ([string]$Binding.code) 96
      guard=Limit-RestoreText ([string]$Binding.guard) 220
    } } else { [pscustomobject]@{state='not_checked';current=$false;code='CONTINUATION_RECEIPT_BINDING_NOT_CHECKED';guard='The receipt binding was not checked.'} }
    compatibility = if ($Compatibility) { [pscustomobject]@{
      state=Limit-RestoreText ([string]$Compatibility.state) 64
      scopeCurrent=[bool]$Compatibility.scopeCurrent
      current=[bool]$Compatibility.current
      code=Limit-RestoreText ([string]$Compatibility.code) 96
      guard=Limit-RestoreText ([string]$Compatibility.guard) 220
      reasons=@(Limit-RestoreList @($Compatibility.reasons) 4 120)
    } } else { [pscustomobject]@{state='not_checked';scopeCurrent=$false;current=$false;code='CONTINUATION_RECEIPT_COMPATIBILITY_NOT_CHECKED';guard='The receipt compatibility was not checked.';reasons=@()} }
    instructionAnchor = if($Receipt.instructionAnchor){[pscustomobject]@{anchorId=Limit-RestoreText ([string]$Receipt.instructionAnchor.anchorId) 80;contentHash=Limit-RestoreText ([string]$Receipt.instructionAnchor.contentHash) 64}}else{$null}
    receiptHash = Limit-RestoreText ([string]$Receipt.receiptHash) 64
    payloadHash = Limit-RestoreText ([string]$Receipt.payloadHash) 64
    stateHash = Limit-RestoreText ([string]$Receipt.stateHash) 64
    state = if ($state) { [pscustomobject]@{
      latestUserInstruction=Limit-RestoreText ([string]$state.latestUserInstruction) 320
      lastConfirmedSentence=Limit-RestoreText ([string]$state.lastConfirmedSentence) 320
      lastConfirmedSource=Limit-RestoreText ([string]$state.lastConfirmedSource) 64
      mainLine=Limit-RestoreText ([string]$state.mainLine) 160
      activeLine=Limit-RestoreText ([string]$state.activeLine) 160
      currentPhase=Limit-RestoreText ([string]$state.currentPhase) 120
      currentStep=Limit-RestoreText ([string]$state.currentStep) 220
      completedSteps=@(Limit-RestoreList @($state.completedSteps) 6 160)
      pendingSteps=@(Limit-RestoreList @($state.pendingSteps) 6 160)
      nextAction=Limit-RestoreText ([string]$state.nextAction) 220
      evidence=@(Limit-RestoreList @($state.evidence) 4 160)
      returnPoint=if($state.returnPoint){[pscustomobject]@{focusId=Limit-RestoreText ([string]$state.returnPoint.focusId) 120;focusLabel=Limit-RestoreText ([string]$state.returnPoint.focusLabel) 120;resumeFrom=Limit-RestoreText ([string]$state.returnPoint.resumeFrom) 80}}else{$null}
      canonicalPlan=if($state.canonicalPlan){[pscustomobject]@{planId=Limit-RestoreText ([string]$state.canonicalPlan.planId) 120;generation=[int]$state.canonicalPlan.generation;fingerprint=Limit-RestoreText ([string]$state.canonicalPlan.fingerprint) 96;completedCount=[int]$state.canonicalPlan.completedCount;pendingCount=[int]$state.canonicalPlan.pendingCount}}else{$null}
    } } else { $null }
  }
}

function Get-RestoreContinuationReceiptCompatibility(
  [object]$Receipt,
  [object]$Binding,
  [object]$ExecutionResolution,
  [string]$ExpectedTaskId,
  [string]$ExpectedWorkspaceKey,
  [string]$ExpectedPackageVersion
) {
  if (-not $Receipt) {
    return [pscustomobject]@{state='no_receipt';scopeCurrent=$false;current=$false;code='CONTINUATION_RECEIPT_NOT_AVAILABLE';guard='No assistant progress receipt is available for this scoped task.';reasons=@('receipt_missing')}
  }
  $reasons = @()
  if ([string]::IsNullOrWhiteSpace([string]$ExpectedTaskId) -or [string]$Receipt.taskId -ne [string]$ExpectedTaskId) { $reasons += 'task_mismatch' }
  if (-not (Test-SuperBrainWorkspaceKey ([string]$Receipt.workspaceKey) $ExpectedWorkspaceKey)) { $reasons += 'workspace_mismatch' }
  if ([string]::IsNullOrWhiteSpace([string]$Receipt.packageVersion) -or [string]$Receipt.packageVersion -ne [string]$ExpectedPackageVersion) { $reasons += 'package_version_mismatch' }
  if ($ExecutionResolution -and -not [string]::IsNullOrWhiteSpace([string]$ExecutionResolution.taskInstanceId) -and -not [string]::IsNullOrWhiteSpace([string]$Receipt.taskInstanceId) -and [string]$ExecutionResolution.taskInstanceId -ne [string]$Receipt.taskInstanceId) { $reasons += 'task_instance_mismatch' }
  if ($ExecutionResolution -and -not [string]::IsNullOrWhiteSpace([string]$ExecutionResolution.packageVersion) -and [string]$ExecutionResolution.packageVersion -ne [string]$Receipt.packageVersion) { $reasons += 'contract_version_mismatch' }
  $scopeCurrent = ($reasons.Count -eq 0)
  $bindingCurrent = ($Binding -and $Binding.current -eq $true)
  if (-not $scopeCurrent) {
    return [pscustomobject]@{state='scope_mismatch';scopeCurrent=$false;current=$false;code='CONTINUATION_RECEIPT_SCOPE_MISMATCH';guard='The assistant progress receipt does not match the current task, workspace, task instance, or package version. Do not display it as current or resume from it.';reasons=@($reasons)}
  }
  if (-not $bindingCurrent) {
    return [pscustomobject]@{state='newer_instruction_pending';scopeCurrent=$true;current=$false;code='CONTINUATION_RECEIPT_RECONCILIATION_REQUIRED';guard='The latest user instruction is newer than the assistant progress receipt. Preserve progress for the user, but reconcile before reusing the old next action.';reasons=@()}
  }
  return [pscustomobject]@{state='current';scopeCurrent=$true;current=$true;code='CONTINUATION_RECEIPT_CURRENT';guard='The latest assistant progress receipt matches the active task and current user instruction.';reasons=@()}
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

function Get-RestoreCheckpointFreshness([object]$Checkpoint,[string]$ExpectedPackageVersion) {
  # Compatibility checkpoints are locator evidence only.  Once they carry an
  # explicit package/version or timestamp, that binding must still be current;
  # otherwise a resumed packet could expose an obsolete executable action.
  if (-not $Checkpoint) {
    return [pscustomobject]@{ current=$true; state='not_present'; reason='' }
  }
  $version = ''
  foreach ($property in @('packageVersion','version')) {
    if ($Checkpoint.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace([string]$Checkpoint.$property)) {
      $version = [string]$Checkpoint.$property
      break
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($version) -and $version -ne [string]$ExpectedPackageVersion) {
    return [pscustomobject]@{ current=$false; state='stale'; reason='package_version_mismatch'; observedVersion=$version; expectedVersion=[string]$ExpectedPackageVersion }
  }

  $timestamp = ''
  foreach ($property in @('updatedAt','timestamp','checkedAt')) {
    if ($Checkpoint.PSObject.Properties[$property] -and -not [string]::IsNullOrWhiteSpace([string]$Checkpoint.$property)) {
      $timestamp = [string]$Checkpoint.$property
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($timestamp)) {
    return [pscustomobject]@{ current=$true; state='current'; reason='' }
  }
  try {
    $when = [DateTimeOffset]::Parse($timestamp)
    $ageHours = ([DateTimeOffset]::UtcNow - $when.ToUniversalTime()).TotalHours
    if ($ageHours -gt 168) {
      return [pscustomobject]@{ current=$false; state='stale'; reason='expired'; observedAt=$timestamp; ageHours=[math]::Round($ageHours,2) }
    }
    if ($ageHours -lt -0.25) {
      return [pscustomobject]@{ current=$false; state='stale'; reason='future_timestamp'; observedAt=$timestamp; ageHours=[math]::Round($ageHours,2) }
    }
  } catch {
    return [pscustomobject]@{ current=$false; state='stale'; reason='timestamp_invalid'; observedAt=$timestamp }
  }
  return [pscustomobject]@{ current=$true; state='current'; reason='' }
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
    packetLimits = [pscustomobject]@{ maxChars=$RestoreMaxPacketChars; maxEvidenceCards=$RestoreMaxTopK; truncated=$false; truncationStages=@(); evidenceCardsBefore=0; evidenceCardsRetained=0 }
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
$sessionCandidate = if (-not [string]::IsNullOrWhiteSpace($SessionKey)) { $SessionKey } else { $SessionId }
$hostSessionKey = Get-SuperBrainHostSessionKey $sessionCandidate
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$requestedAnchorTaskId = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $TaskId.Trim() } else { '' }
$instructionAnchorLookup = Get-RestoreInstructionAnchor $memoryBase $currentWorkspaceKey $hostSessionKey $requestedAnchorTaskId
$instructionAnchorLookupFailed = (-not $instructionAnchorLookup.ok)
$instructionAnchor = if ($instructionAnchorLookup.ok -and $instructionAnchorLookup.available -eq $true -and $instructionAnchorLookup.anchor) { $instructionAnchorLookup.anchor } else { $null }
$anchorTaskId = if ($instructionAnchor) { [string]$instructionAnchor.taskId } else { '' }
$continuationReceiptRequestedTaskId = if (-not [string]::IsNullOrWhiteSpace($requestedAnchorTaskId)) { $requestedAnchorTaskId } elseif (-not [string]::IsNullOrWhiteSpace($anchorTaskId)) { $anchorTaskId } else { '' }
$continuationReceiptLookup = Get-RestoreContinuationReceipt $memoryBase $currentWorkspaceKey $hostSessionKey $continuationReceiptRequestedTaskId
$continuationReceiptLookupFailed = (-not $continuationReceiptLookup.ok)
$continuationReceipt = if ($continuationReceiptLookup.ok -and $continuationReceiptLookup.available -eq $true -and $continuationReceiptLookup.receipt) { $continuationReceiptLookup.receipt } else { $null }
$receiptTaskId = if ($continuationReceipt) { [string]$continuationReceipt.taskId } else { '' }
$scopedWorkspaceState = Join-Path $workspace (Join-Path 'runtime-state\workspaces' $currentWorkspaceKey)
$scopedSnapshotPath = Join-Path $scopedWorkspaceState 'last-status-snapshot.json'
$scopedStatusCardPath = Join-Path $scopedWorkspaceState 'status-card.json'
if (Test-Path -LiteralPath $scopedSnapshotPath) {
  try { $lastSnapshot = Get-Content -LiteralPath $scopedSnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
if (Test-Path -LiteralPath $scopedStatusCardPath) {
  try { $statusCard = Get-Content -LiteralPath $scopedStatusCardPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$currentTaskContext = Get-SuperBrainCurrentTaskContext $workspace $currentWorkspaceKey
$checkpointRequestedTaskId = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $TaskId } elseif (-not [string]::IsNullOrWhiteSpace($anchorTaskId)) { $anchorTaskId } elseif (-not [string]::IsNullOrWhiteSpace($receiptTaskId)) { $receiptTaskId } else { '' }
$checkpointSelection = Get-SuperBrainRelevantCheckpoint $workspace $currentTaskContext $currentWorkspaceKey $checkpointRequestedTaskId
$activeCheckpoint = $checkpointSelection.checkpoint
$checkpointFreshness = Get-RestoreCheckpointFreshness $activeCheckpoint ([string]$manifest.version)
if ($activeCheckpoint -and $checkpointFreshness.current -ne $true) {
  # Keep only bounded diagnostics; never carry stale checkpoint actions into a
  # restore packet where they could be mistaken for the current next action.
  $staleTaskId = [string]$activeCheckpoint.taskId
  $stalePhase = Limit-RestoreText ([string]$activeCheckpoint.currentPhase) 120
  $checkpointSelection | Add-Member -NotePropertyName state -NotePropertyValue 'stale' -Force
  $checkpointSelection | Add-Member -NotePropertyName confidence -NotePropertyValue 'none' -Force
  $checkpointSelection | Add-Member -NotePropertyName legacyCompatibility -NotePropertyValue $false -Force
  $checkpointSelection | Add-Member -NotePropertyName ignoredTaskId -NotePropertyValue $staleTaskId -Force
  $checkpointSelection | Add-Member -NotePropertyName staleReason -NotePropertyValue ([string]$checkpointFreshness.reason) -Force
  $checkpointSelection | Add-Member -NotePropertyName stalePhase -NotePropertyValue $stalePhase -Force
  $activeCheckpoint = $null
}
$currentTaskContext = $checkpointSelection.context
$statusCardTaskId = Get-RestoreEvidenceTaskId $statusCard
$snapshotTaskId = Get-RestoreEvidenceTaskId $lastSnapshot
$statusCardWorkspaceMatch = Test-RestoreEvidenceWorkspace $statusCard $currentWorkspaceKey
$snapshotWorkspaceMatch = Test-RestoreEvidenceWorkspace $lastSnapshot $currentWorkspaceKey
$recoveryTaskId = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $TaskId.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($anchorTaskId)) { $anchorTaskId } elseif (-not [string]::IsNullOrWhiteSpace($receiptTaskId)) { $receiptTaskId } elseif ($activeCheckpoint) { [string]$activeCheckpoint.taskId } elseif ($currentTaskContext) { [string]$currentTaskContext.taskId } elseif ($statusCardWorkspaceMatch -and -not [string]::IsNullOrWhiteSpace($statusCardTaskId)) { $statusCardTaskId } elseif ($snapshotWorkspaceMatch -and -not [string]::IsNullOrWhiteSpace($snapshotTaskId)) { $snapshotTaskId } else { '' }
$recoveryCheckpointLookup = Get-RestoreRecoveryCheckpoint $memoryBase $currentWorkspaceKey $hostSessionKey $recoveryTaskId
$recoveryCheckpoint = if ($recoveryCheckpointLookup.ok -and $recoveryCheckpointLookup.checkpoint) { $recoveryCheckpointLookup.checkpoint } else { $null }
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
if ($instructionAnchorLookupFailed) {
  $executionResolution = $null
  $executionResolutionFailed = $true
  $executionResolutionFailureCode = [string]$instructionAnchorLookup.code
}
if ($continuationReceiptLookupFailed) {
  $executionResolution = $null
  $executionResolutionFailed = $true
  $executionResolutionFailureCode = [string]$continuationReceiptLookup.code
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
$continuationReceiptCompatibility = Get-RestoreContinuationReceiptCompatibility $continuationReceipt $continuationReceiptLookup.binding $executionResolution $recoveryTaskId $currentWorkspaceKey ([string]$manifest.version)
$continuationReceiptScopeInvalid = ($continuationReceipt -and $continuationReceiptCompatibility.scopeCurrent -ne $true)
if ($continuationReceiptScopeInvalid -and $executionResolution -and -not $executionResolutionNoContract) {
  $executionResolution | Add-Member -NotePropertyName actionAuthorization -NotePropertyValue 'withheld' -Force
  $executionResolution | Add-Member -NotePropertyName claimAllowed -NotePropertyValue $false -Force
  $executionResolution | Add-Member -NotePropertyName needsConfirmation -NotePropertyValue $true -Force
  $executionResolution | Add-Member -NotePropertyName resumeFrom -NotePropertyValue 'continuation_receipt_scope_invalid' -Force
  $executionResolution | Add-Member -NotePropertyName nextAction -NotePropertyValue 'Continuation receipt scope is invalid; reconcile the current task before action.' -Force
  $executionAuthorizationWithheld = $true
  $contractPlanAuthorized = $false
}
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
$compactInstructionAnchor = New-CompactRestoreInstructionAnchor $instructionAnchor
$continuationReceiptBinding = if ($continuationReceiptLookup -and $continuationReceiptLookup.PSObject.Properties['binding']) { $continuationReceiptLookup.binding } else { $null }
$compactContinuationReceipt = New-CompactRestoreContinuationReceipt $continuationReceipt $continuationReceiptBinding $continuationReceiptCompatibility
if ($executionResolutionFailed) {
  # A malformed or unresolvable contract is a fail-closed boundary. Do not let
  # a prior assistant progress receipt leak stale actions into the packet.
  $compactContinuationReceipt = [pscustomobject]@{
    available = $false
    status = 'withheld'
    code = 'SESSION_RESTORE_EXECUTION_RESOLUTION_FAILED'
    taskId = Limit-RestoreText $recoveryTaskId 160
    workspaceKey = $currentWorkspaceKey
    guard = 'Assistant progress is withheld because the current execution contract could not be resolved. Reconcile the task before exposing a prior action.'
  }
}
$receiptState = if ($compactContinuationReceipt -and $compactContinuationReceipt.state) { $compactContinuationReceipt.state } else { $null }
$assistantProgressState = if ($compactContinuationReceipt -and $compactContinuationReceipt.compatibility -and -not [string]::IsNullOrWhiteSpace([string]$compactContinuationReceipt.compatibility.state)) { [string]$compactContinuationReceipt.compatibility.state } elseif ($receiptState) { 'not_checked' } else { 'no_receipt' }
$assistantProgressScopeCurrent = ($compactContinuationReceipt -and $compactContinuationReceipt.compatibility -and $compactContinuationReceipt.compatibility.scopeCurrent -eq $true)
$assistantProgressCurrent = ($compactContinuationReceipt -and $compactContinuationReceipt.compatibility -and $compactContinuationReceipt.compatibility.current -eq $true)
$assistantProgressActionAvailable = ($assistantProgressCurrent -and -not $executionAuthorizationWithheld -and -not $executionResolutionFailed)
if ($receiptState -and -not $assistantProgressActionAvailable) {
  $receiptState | Add-Member -NotePropertyName priorNextActionState -NotePropertyValue 'withheld_pending_reconciliation' -Force
  $receiptState | Add-Member -NotePropertyName nextAction -NotePropertyValue '' -Force
}
$assistantProgress = [pscustomobject]@{
  available = ($null -ne $receiptState)
  state = $assistantProgressState
  scopeCurrent = [bool]$assistantProgressScopeCurrent
  current = [bool]$assistantProgressCurrent
  guard = if($compactContinuationReceipt -and $compactContinuationReceipt.compatibility){Limit-RestoreText ([string]$compactContinuationReceipt.compatibility.guard) 220}else{'No assistant progress receipt is available.'}
  lastConfirmedSentence = if($receiptState){Limit-RestoreText ([string]$receiptState.lastConfirmedSentence) 260}else{''}
  lastConfirmedSource = if($receiptState){Limit-RestoreText ([string]$receiptState.lastConfirmedSource) 64}else{''}
  currentPhase = if($receiptState){Limit-RestoreText ([string]$receiptState.currentPhase) 120}else{''}
  currentStep = if($receiptState){Limit-RestoreText ([string]$receiptState.currentStep) 220}else{''}
  completedSteps = if($receiptState){@($receiptState.completedSteps)}else{@()}
  pendingSteps = if($receiptState){@($receiptState.pendingSteps)}else{@()}
  priorNextAction = if($receiptState -and $assistantProgressActionAvailable){Limit-RestoreText ([string]$receiptState.nextAction) 220}else{''}
  priorNextActionState = if($assistantProgressActionAvailable){'available'}elseif($receiptState){'withheld_pending_reconciliation'}else{'unavailable'}
  evidence = if($receiptState){@($receiptState.evidence)}else{@()}
  returnPoint = if($receiptState){$receiptState.returnPoint}else{$null}
}
$latestRestoreInstruction = if ($compactInstructionAnchor) { [string]$compactInstructionAnchor.latestUserInstruction } elseif ($receiptState -and -not [string]::IsNullOrWhiteSpace([string]$receiptState.latestUserInstruction)) { [string]$receiptState.latestUserInstruction } elseif ($compactExecutionResolution -and -not [string]::IsNullOrWhiteSpace([string]$compactExecutionResolution.latestUserInstruction)) { [string]$compactExecutionResolution.latestUserInstruction } else { '' }
$resumeReceipt = [pscustomobject]@{
  schema = 'super-brain.resume-receipt.v2'
  state = if ($executionResolutionFailed) { 'reconcile_latest_instruction' } elseif ($executionAuthorizationWithheld -and $assistantProgressState -eq 'newer_instruction_pending') { 'reconcile_newest_instruction_preserve_assistant_progress' } elseif ($executionAuthorizationWithheld) { 'reconcile_before_action' } elseif ($contractPlanAuthorized -and $assistantProgressCurrent) { 'resume_verified_assistant_progress' } elseif ($contractPlanAuthorized) { 'ready_to_continue' } else { 'locate_or_reconcile' }
  latestUserInstruction = Limit-RestoreText $latestRestoreInstruction 320
  assistantProgress = $assistantProgress
  lastConfirmedSentence = if ($receiptState) { Limit-RestoreText ([string]$receiptState.lastConfirmedSentence) 260 } elseif ($compactContinuityStateCard) { Limit-RestoreText ([string]$compactContinuityStateCard.lastConfirmedSentence) 260 } else { '' }
  mainLine = if ($receiptState) { Limit-RestoreText ([string]$receiptState.mainLine) 120 } elseif ($compactWorkLineStatus -and $compactWorkLineStatus.userView) { Limit-RestoreText ([string]$compactWorkLineStatus.userView.main.label) 120 } else { '' }
  activeLine = if ($receiptState) { Limit-RestoreText ([string]$receiptState.activeLine) 120 } elseif ($compactWorkLineStatus -and $compactWorkLineStatus.userView) { Limit-RestoreText ([string]$compactWorkLineStatus.userView.current.label) 120 } else { '' }
  currentPhase = if ($receiptState) { Limit-RestoreText ([string]$receiptState.currentPhase) 120 } elseif ($compactContinuityStateCard) { Limit-RestoreText ([string]$compactContinuityStateCard.phase) 120 } elseif ($recoveryCheckpoint) { Limit-RestoreText ([string]$recoveryCheckpoint.currentPhase) 120 } else { '' }
  currentStep = if ($receiptState) { Limit-RestoreText ([string]$receiptState.currentStep) 220 } elseif ($compactContinuityStateCard) { Limit-RestoreText ([string]$compactContinuityStateCard.currentStep) 220 } elseif ($recoveryCheckpoint) { Limit-RestoreText ([string]$recoveryCheckpoint.currentStep) 220 } else { '' }
  completedSteps = if ($receiptState) { @($receiptState.completedSteps) } elseif ($compactContinuityStateCard) { @(Limit-RestoreList @($compactContinuityStateCard.completedSteps) 6 160) } else { @() }
  pendingSteps = if ($receiptState) { @($receiptState.pendingSteps) } elseif ($compactContinuityStateCard) { @(Limit-RestoreList @($compactContinuityStateCard.pendingSteps) 6 160) } else { @() }
  nextAction = if ($executionAuthorizationWithheld -or $executionResolutionFailed) { '' } elseif ($contractPlanAuthorized) { Limit-RestoreText ([string]$contractPlan.nextAction) 220 } else { '' }
  evidence = if ($receiptState) { @($receiptState.evidence) } elseif ($compactContinuityStateCard) { @(Limit-RestoreList @($compactContinuityStateCard.evidence) 4 160) } else { @() }
  returnPoint = if ($receiptState -and $receiptState.returnPoint) { [pscustomobject]@{ taskId=Limit-RestoreText $recoveryTaskId 160; focusId=Limit-RestoreText ([string]$receiptState.returnPoint.focusId) 120; focusLabel=Limit-RestoreText ([string]$receiptState.returnPoint.focusLabel) 120; resumeFrom=Limit-RestoreText ([string]$receiptState.returnPoint.resumeFrom) 64 } } elseif ($compactExecutionResolution) { [pscustomobject]@{ taskId=Limit-RestoreText ([string]$compactExecutionResolution.taskId) 160; focusId=Limit-RestoreText ([string]$compactExecutionResolution.focusId) 120; focusLabel=Limit-RestoreText ([string]$compactExecutionResolution.focusLabel) 120; resumeFrom=Limit-RestoreText ([string]$compactExecutionResolution.resumeFrom) 64 } } elseif ($recoveryCheckpoint -and $recoveryCheckpoint.returnPoint) { [pscustomobject]@{ taskId=Limit-RestoreText $recoveryTaskId 160; focusId=Limit-RestoreText ([string]$recoveryCheckpoint.returnPoint.focusId) 120; focusLabel=Limit-RestoreText ([string]$recoveryCheckpoint.returnPoint.focusLabel) 120; resumeFrom=Limit-RestoreText ([string]$recoveryCheckpoint.returnPoint.resumeFrom) 64 } } else { $null }
  completedHistoryIsCurrent = $false
}

$recoveryPoint = [pscustomobject]@{
  source = if ($instructionAnchorLookupFailed) { 'instruction_anchor_lookup_failed' } elseif ($continuationReceiptLookupFailed) { 'continuation_receipt_lookup_failed' } elseif ($executionResolutionFailed) { 'execution_contract_resolution_failed' } elseif ($executionAuthorizationWithheld) { 'execution_contract_action_withheld' } elseif ($compactInstructionAnchor -and $compactContinuationReceipt -and $assistantProgressCurrent) { 'current_instruction_with_latest_assistant_progress' } elseif ($compactInstructionAnchor -and $compactContinuationReceipt -and $assistantProgressState -eq 'newer_instruction_pending') { 'new_instruction_requires_reconciliation_preserve_assistant_progress' } elseif ($compactInstructionAnchor) { 'latest_instruction_anchor' } elseif ($compactContinuationReceipt) { 'latest_assistant_progress_receipt' } elseif ($contractPlanRelevant) { 'execution_contract_plan' } elseif ($historicalRecoveryIntent) { 'historical_evidence_only' } elseif ($executionResolution -and [string]$executionResolution.resumeFrom -in @('execution_contract','execution_contract_pending_reconciliation','execution_contract_instruction_anchor_pending','parent_return','visible_conversation')) { 'execution_contract_plan_missing' } elseif ($recoveryCheckpoint) { 'recovery_checkpoint' } elseif ($activeCheckpoint) { 'active_checkpoint' } elseif ($statusCardActionRelevant) { 'status_card' } elseif ($snapshotActionRelevant) { 'status_snapshot' } else { 'none' }
  taskId = Limit-RestoreText $recoveryTaskId 160
  workspaceKey = $currentWorkspaceKey
  focusId = if ($executionResolution) { Limit-RestoreText ([string]$executionResolution.focusId) 120 } else { '' }
  focusLabel = if ($executionResolution) { Limit-RestoreText ([string]$executionResolution.focusLabel) 100 } else { '' }
  resumeFrom = if ($executionResolution) { Limit-RestoreText ([string]$executionResolution.resumeFrom) 48 } else { '' }
  nextAction = if ($contractPlanAuthorized) { Limit-RestoreText ([string]$contractPlan.nextAction) 220 } elseif ($recoveryCheckpoint) { Limit-RestoreText ([string]$recoveryCheckpoint.nextAction) 220 } else { '' }
  plan = $compactContractPlan
  parentPlan = $compactParentPlan
  continuityStateCard = $compactContinuityStateCard
  workLineStatus = if ($historicalRecoveryIntent) { $null } else { $compactWorkLineStatus }
  latestMessageClassification = if ($historicalRecoveryIntent) { $null } elseif ($compactExecutionResolution) { $compactExecutionResolution.latestMessageClassification } else { $null }
  planAvailable = $contractPlanRelevant
  planAuthorized = $contractPlanAuthorized
  claimAllowed = if ($executionResolution) { [bool]$executionResolution.claimAllowed } else { $false }
  needsConfirmation = if ($executionResolution) { [bool]$executionResolution.needsConfirmation } else { $true }
  latestUserInstruction = Limit-RestoreText $latestRestoreInstruction 320
  priorityOrder = @('current_user_instruction_authority','latest_assistant_progress_receipt','task_scoped_execution_contract','bound_return_card_plan','atomic_recovery_checkpoint','task_scoped_checkpoint','bounded_memory_evidence_if_plan_missing')
  memoryFallback = if ($contractPlanRelevant) { 'not_required' } elseif ($targetedPlanRecall -and @($recall).Count -gt 0) { 'task_and_workspace_scoped_evidence_found' } elseif ($targetedPlanRecall) { 'task_and_workspace_scoped_evidence_missing' } else { 'not_requested' }
}

$packetNextAction = if ($historicalEvidenceStatus -eq 'missing') { 'Historical evidence is missing/unknown; report that explicitly and do not infer prior task details.' } elseif ($historicalEvidenceStatus -eq 'found') { 'Use only the current verified relevant evidenceCards; do not infer details beyond their evidence.' } elseif ($continuationReceiptScopeInvalid) { 'Assistant progress receipt scope is invalid; reconcile the current task before action.' } elseif ($executionResolutionFailed) { 'Execution contract resolution failed; repair or re-run the resolver before mutation.' } elseif ($executionResolutionUnavailable) { 'Latest execution action is unavailable; use scoped state only to locate the task, then reconcile a current execution contract before mutation.' } elseif ($executionAuthorizationWithheld) { [string]$executionResolution.nextAction } elseif ($contractPlanAuthorized) { [string]$contractPlan.nextAction } elseif ($contractPlanRelevant) { 'The plan is known but is not authorized until the latest instruction and topic affinity are reconciled.' } elseif ($targetedPlanRecall -and @($recall).Count -eq 0) { 'Task-and-workspace-scoped plan evidence is missing; do not use generic status memory or infer a plan.' } elseif ($targetedPlanRecall) { 'Use only the bounded evidence cards that contain both the exact task id and workspace key; do not infer beyond them.' } elseif ($activeCheckpoint -or $statusCardActionRelevant -or $snapshotActionRelevant -or $fastSessionResume) { 'Latest execution action is unknown; use the scoped status only to locate the task, then reconcile a current execution contract before mutation.' } elseif ($shouldRecall) { 'Use evidenceCards only if relevant; do not inject raw memory beyond the token budget.' } else { 'No deep recall needed unless the user asks for continuity, memory, preferences, or previous-session context.' }
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
  instructionAnchor = if ($instructionAnchorLookupFailed) { [pscustomobject]@{available=$false;status='error';code=[string]$instructionAnchorLookup.code} } else { $compactInstructionAnchor }
  continuationReceipt = if ($continuationReceiptLookupFailed) { [pscustomobject]@{available=$false;status='error';code=[string]$continuationReceiptLookup.code} } else { $compactContinuationReceipt }
  resumeReceipt = $resumeReceipt
  recoveryPoint = $recoveryPoint
  recoveryCheckpoint = if ($recoveryCheckpoint) { [pscustomobject]@{ checkpointId=Limit-RestoreText ([string]$recoveryCheckpoint.checkpointId) 96; checkpointRevision=[int]$recoveryCheckpoint.checkpointRevision; checkpointHash=Limit-RestoreText ([string]$recoveryCheckpoint.checkpointHash) 64; stateHash=Limit-RestoreText ([string]$recoveryCheckpoint.stateHash) 64; contractRevision=[int]$recoveryCheckpoint.contractRevision; planFingerprint=Limit-RestoreText ([string]$recoveryCheckpoint.planFingerprint) 96; latestInstructionHash=Limit-RestoreText ([string]$recoveryCheckpoint.latestInstructionHash) 64; assistantProgressHash=Limit-RestoreText ([string]$recoveryCheckpoint.assistantProgressHash) 64; currentPhase=Limit-RestoreText ([string]$recoveryCheckpoint.currentPhase) 120; currentStep=Limit-RestoreText ([string]$recoveryCheckpoint.currentStep) 220; nextAction=Limit-RestoreText ([string]$recoveryCheckpoint.nextAction) 220; returnPoint=$recoveryCheckpoint.returnPoint; source=Limit-RestoreText ([string]$recoveryCheckpoint.source) 120 } } else { $null }
  recoveryCheckpointLookup = [pscustomobject]@{ ok=[bool]$recoveryCheckpointLookup.ok; status=Limit-RestoreText ([string]$recoveryCheckpointLookup.status) 32; code=Limit-RestoreText ([string]$recoveryCheckpointLookup.code) 96; available=[bool]$recoveryCheckpointLookup.available }
  continuityStateCard = $compactContinuityStateCard
  statusCard = if ($statusCardActionRelevant) { [pscustomobject]@{ taskId=$recoveryTaskId; workspaceKey=$currentWorkspaceKey; version=Limit-RestoreText ([string]$statusCard.version) 64; ok=$statusCard.ok; packageOk=$statusCard.packageOk; verifyOk=$statusCard.verifyOk; updatedAt=Limit-RestoreText ([string]$statusCard.updatedAt) 48; risksCount=$statusCard.risksCount; nextAction=Limit-RestoreText $statusCardNextAction 220 } } elseif ($statusCard) { [pscustomobject]@{ nextAction='' } } else { $null }
  checkpointSelection = [pscustomobject]@{ state=$checkpointSelection.state; contextState=$checkpointSelection.contextState; workspaceKey=$checkpointSelection.workspaceKey; source=Limit-RestoreText ([string]$checkpointSelection.source) 120; confidence=$checkpointSelection.confidence; legacyCompatibility=[bool]$checkpointSelection.legacyCompatibility; candidateTaskId=Limit-RestoreText ([string]$checkpointSelection.candidateTaskId) 160; ignoredTaskId=Limit-RestoreText ([string]$checkpointSelection.ignoredTaskId) 160; staleReason=Limit-RestoreText ([string]$checkpointSelection.staleReason) 80; stalePhase=Limit-RestoreText ([string]$checkpointSelection.stalePhase) 120 }
  activeCheckpoint = if ($activeCheckpoint) { New-CompactCheckpoint $activeCheckpoint } else { $null }
  lastSnapshot = if ($snapshotActionRelevant) { [pscustomobject]@{ taskId=$recoveryTaskId; workspaceKey=$currentWorkspaceKey; summary=Limit-RestoreText ([string]$lastSnapshot.summary) 220; nextAction=Limit-RestoreText ([string]$lastSnapshot.nextAction) 220; checkedAt=Limit-RestoreText ([string]$lastSnapshot.checkedAt) 48 } } elseif ($lastSnapshot) { [pscustomobject]@{ nextAction='' } } else { $null }
  experienceIndexPreview = Limit-RestoreText $experienceIndex 420
  profileCard = if ($profileIntent) { New-CompactProfileCard $profileCard } else { $null }
  sessionBinding = New-CompactSessionBinding $sessionBinding $recoveryTaskId $currentWorkspaceKey
  fastSessionResume = $fastSessionResume
  resumePriority = if ($fastSessionResume) { @('currentUserInstructionAuthority','latestAssistantProgressReceipt','currentVisibleContext','currentExecutionContract','currentTodoCheckpoint','explicitSessionBinding','statusCard','superBrainState','lastSnapshots') } else { @('currentUserInstructionAuthority','latestAssistantProgressReceipt','currentExecutionContract','currentTodoCheckpoint','boundedEvidence') }
  evidenceCards = $boundedEvidenceCards
  nextAction = Limit-RestoreText $packetNextAction 320
  packetLimits = [pscustomobject]@{ maxChars=$RestoreMaxPacketChars; maxEvidenceCards=$RestoreMaxTopK; maxCheckpointSteps=6; maxWorkLines=6; effectiveMaxTokens=$MaxTokens; effectiveTopK=$TopK; serializedChars=0; truncated=$false; truncationStages=@(); evidenceCardsBefore=@($boundedEvidenceCards).Count; evidenceCardsRetained=@($boundedEvidenceCards).Count }
}

$packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
if ($packetJson.Length -gt $RestoreMaxPacketChars) {
  $lightPacket.packetLimits.truncated = $true
  Add-RestorePacketTruncationStage $lightPacket 'auxiliary_projection_compaction'
  $lightPacket.profileCard = $null
  $lightPacket.experienceIndexPreview = ''
  $lightPacket.sessionBinding = $null
  $lightPacket.state = $null
  $lightPacket.statusCard = $null
  $lightPacket.lastSnapshot = $null
  Set-RestorePacketEvidenceCount $lightPacket
  $packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
}
if ($packetJson.Length -gt $RestoreMaxPacketChars) {
  # Keep bounded, verified recall evidence.  The duplicate verbose recovery
  # and contract views are the next material to compact, not the evidence that
  # proves a historical claim.
  Add-RestorePacketTruncationStage $lightPacket 'recovery_contract_projection_compaction'
  $lightPacket.executionResolution = if ($historicalRecoveryIntent) { $null } else { New-TruncatedRestoreExecutionResolution $lightPacket.executionResolution }
  $lightPacket.continuationReceipt = $null
  $lightPacket.resumeReceipt = New-TruncatedRestoreResumeReceipt $lightPacket.resumeReceipt
  $lightPacket.recoveryPoint = New-TruncatedRestoreRecoveryPoint $lightPacket.recoveryPoint
  $lightPacket.recoveryCheckpoint = New-TruncatedRestoreCheckpoint $lightPacket.recoveryCheckpoint
  $lightPacket.recoveryCheckpointLookup = $null
  $lightPacket.continuityStateCard = $null
  $lightPacket.activeCheckpoint = $null
  Set-RestorePacketEvidenceCount $lightPacket
  $packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
}
if ($packetJson.Length -gt $RestoreMaxPacketChars) {
  # Lower evidence quantity only after all verbose projections are compacted.
  # Never make a found, verified evidence set disappear merely to fit a packet.
  Add-RestorePacketTruncationStage $lightPacket 'evidence_card_reduction'
  if (@($lightPacket.evidenceCards).Count -gt 2) { $lightPacket.evidenceCards = @($lightPacket.evidenceCards | Select-Object -First 2) }
  Set-RestorePacketEvidenceCount $lightPacket
  $packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
}
if ($packetJson.Length -gt $RestoreMaxPacketChars) {
  $retainedEvidenceCards = @($lightPacket.evidenceCards | Select-Object -First 1)
  Add-RestorePacketTruncationStage $lightPacket 'minimal_verified_evidence_packet'
  $minimalExecution = if ($historicalRecoveryIntent) { $null } else { New-TruncatedRestoreExecutionResolution $compactExecutionResolution }
  $lightPacket = [pscustomobject]@{
    ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); memoryMode=$MemoryMode; workspaceKey=$currentWorkspaceKey; tokenBudget=$MaxTokens; topK=$TopK; recallTriggered=$shouldRecall; historicalEvidenceStatus=$historicalEvidenceStatus
    executionResolution=if($historicalRecoveryIntent){$null}else{$minimalExecution}
    instructionAnchor=$compactInstructionAnchor
    resumeReceipt=New-TruncatedRestoreResumeReceipt $resumeReceipt
    recoveryPoint=New-TruncatedRestoreRecoveryPoint $recoveryPoint
    evidenceCards=$retainedEvidenceCards; nextAction=Limit-RestoreText $packetNextAction 320
    packetLimits=[pscustomobject]@{maxChars=$RestoreMaxPacketChars;maxEvidenceCards=$RestoreMaxTopK;maxCheckpointSteps=6;maxWorkLines=6;effectiveMaxTokens=$MaxTokens;effectiveTopK=$TopK;serializedChars=0;truncated=$true;truncationStages=@($lightPacket.packetLimits.truncationStages);evidenceCardsBefore=@($boundedEvidenceCards).Count;evidenceCardsRetained=@($retainedEvidenceCards).Count}
  }
  $packetJson = $lightPacket | ConvertTo-Json -Depth 12 -Compress
}
for ($packetPass = 0; $packetPass -lt 3; $packetPass++) {
  Set-RestorePacketEvidenceCount $lightPacket
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
