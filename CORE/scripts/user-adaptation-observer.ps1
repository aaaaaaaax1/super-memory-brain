[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Preview','Apply')]
  [string]$Mode = 'Preview',
  [string[]]$Signals = @(),
  [string[]]$Measurements = @(),
  [ValidateSet('general','coding','debugging','planning','review','design','release')]
  [string]$Context = 'general',
  [ValidateSet('accepted_outcome','user_correction')]
  [string]$Source = 'accepted_outcome',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$WorkflowKey = '',
  [string]$VerificationArtifactPath = '',
  [string]$CorrectionCandidateId = '',
  [string]$CorrectionTargetPreferenceId = '',
  [string]$WorkspaceRoot = '',
  [switch]$NoExit,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\user-adaptation-core.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' } else { [IO.Path]::GetFullPath($WorkspaceRoot) }
$outPath = Join-Path $workspace 'last-user-adaptation-observer.json'

function Write-ObserverResult($Value,[int]$ExitCode=0) {
  if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
  Write-JsonUtf8NoBom $outPath $Value 14
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 }
  else { Write-Host "USER_ADAPTATION_OBSERVER mode=$($Value.mode) ok=$($Value.ok) applied=$($Value.appliedCount)" }
  $script:ObserverExitCode = $ExitCode
}

try {
  $policy = Get-UserAdaptationPolicy $Root
  $observerPolicy = $policy.verifiedOutcomeObservation
  if (-not $observerPolicy -or $observerPolicy.enabled -ne $true) { throw 'USER_ADAPTATION_OBSERVER_POLICY_MISSING_OR_DISABLED' }
  if (@($observerPolicy.allowedSources) -notcontains $Source) { throw 'USER_ADAPTATION_OBSERVER_SOURCE_BLOCKED' }
  if ([string]::IsNullOrWhiteSpace($TaskId) -or $TaskId -notmatch '^[A-Za-z0-9._-]{1,120}$') { throw 'USER_ADAPTATION_OBSERVER_TASK_ID_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { $WorkspaceKey = Get-SuperBrainWorkspaceKey }
  $WorkspaceKey = $WorkspaceKey.ToLowerInvariant()
  if ($WorkspaceKey -notmatch '^ws-[0-9a-f]{24}$') { throw 'USER_ADAPTATION_OBSERVER_WORKSPACE_KEY_INVALID' }
  if (-not [string]::IsNullOrWhiteSpace($WorkflowKey) -and $WorkflowKey -notmatch '^[A-Za-z0-9._-]{1,48}$') { throw 'USER_ADAPTATION_OBSERVER_WORKFLOW_KEY_INVALID' }

  $signalItems = New-Object Collections.ArrayList
  foreach ($rawSignal in @($Signals | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
    $normalized = ([string]$rawSignal).Trim().ToLowerInvariant()
    if ($normalized -notmatch '^([a-z_]+)=([a-z_]+)$') { throw 'USER_ADAPTATION_OBSERVER_SIGNAL_INVALID' }
    $rule = Get-UserAdaptationHabitRule $policy $Matches[1] $Matches[2]
    [void]$signalItems.Add([pscustomobject]@{habitKey=$rule.habitKey;value=$rule.value;valueKind='enum';parameters=$null;evidenceKind=if($Source-eq'user_correction'){'verified_correction'}else{'verified_outcome'};producer=if($Source-eq'user_correction'){'closed_correction'}else{'task_verification'}})
  }
  foreach ($rawMeasurement in @($Measurements | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
    $normalized = (([string]$rawMeasurement).Trim() -replace '\s+','').ToLowerInvariant()
    if ($normalized -notmatch '^review_protocol=multi_pass;forwardpasses=([1-5]);reversepasses=([0-3]);riskfloor=(workflow|structural)(?:;contexts=([a-z,]+))?$') { throw 'USER_ADAPTATION_OBSERVER_MEASUREMENT_INVALID' }
    if ($Source -ne 'accepted_outcome' -or [string]::IsNullOrWhiteSpace($WorkflowKey)) { throw 'USER_ADAPTATION_OBSERVER_MEASUREMENT_SCOPE_INVALID' }
    $forwardPasses=[int]$Matches[1];$reversePasses=[int]$Matches[2];$riskFloor=[string]$Matches[3];$measurementContexts=if([string]::IsNullOrWhiteSpace([string]$Matches[4])){@()}else{@(([string]$Matches[4]-split',')|Select-Object -Unique)}
    $parameters=[pscustomobject]@{forwardPasses=$forwardPasses;reversePasses=$reversePasses;riskFloor=$riskFloor}
    if($measurementContexts.Count-gt0){$parameters|Add-Member -NotePropertyName contexts -NotePropertyValue @($measurementContexts) -Force}
    $typed=ConvertTo-UserAdaptationTypedValue -Root $Root -HabitKey review_protocol -Value multi_pass -Parameters $parameters
    [void]$signalItems.Add([pscustomobject]@{habitKey=$typed.habitKey;value=$typed.value;valueKind=$typed.valueKind;parameters=$typed.parameters;evidenceKind='workflow_measurement';producer='verified_task_protocol'})
  }
  if ($signalItems.Count -eq 0) { throw 'USER_ADAPTATION_OBSERVER_SIGNALS_REQUIRED' }
  if ($signalItems.Count -gt [int]$observerPolicy.maxSignalsPerTask) { throw 'USER_ADAPTATION_OBSERVER_SIGNAL_BUDGET_EXCEEDED' }
  if ($Source -eq 'user_correction' -and $signalItems.Count -ne 1) { throw 'USER_ADAPTATION_OBSERVER_CORRECTION_SIGNAL_COUNT_INVALID' }

  $verificationPath = if(-not[string]::IsNullOrWhiteSpace($VerificationArtifactPath)){[IO.Path]::GetFullPath($VerificationArtifactPath)}else{Join-Path $workspace 'last-task-verification.json'}
  $verification = $null
  if (Test-Path -LiteralPath $verificationPath) { try { $verification = Get-Content -LiteralPath $verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  $verificationHash = Get-SuperBrainFileSha256 $verificationPath
  $verificationStable = (-not [string]::IsNullOrWhiteSpace($verificationHash) -and (Get-SuperBrainFileSha256 $verificationPath) -eq $verificationHash)
  $verificationSchemaOk=if($Source-eq'user_correction'){[string]$verification.schema-in@('super-brain.user-adaptation-verification.v1','super-brain.user-adaptation-verification.v2')}else{[string]$verification.schema-eq'super-brain.user-adaptation-verification.v2'}
  $verificationMatch = ($verification -and $verificationSchemaOk -and [string]$verification.source -eq 'task-verification.ps1' -and $verification.eligibleForAdaptation -eq $true -and $verification.verification.ok -eq $true -and $verification.completion.completed -eq $true -and [string]$verification.taskId -eq $TaskId -and [string]$verification.workspaceKey -eq $WorkspaceKey -and $verificationStable)
  if ($Mode -eq 'Apply' -and -not $verificationMatch) { throw 'USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED' }

  $correctionVerified = $true
  $correctionHash = ''
  if ($Source -eq 'user_correction') {
    if ([string]::IsNullOrWhiteSpace($CorrectionCandidateId) -or $CorrectionCandidateId -notmatch '^correction-[a-z0-9_-]{1,100}$') { throw 'USER_ADAPTATION_OBSERVER_CLOSED_CORRECTION_REQUIRED' }
    $correctionPath = Join-Path $workspace "reflection\correction-candidates\$($CorrectionCandidateId.ToLowerInvariant()).json"
    $correction = $null
    if (Test-Path -LiteralPath $correctionPath) { try { $correction = Get-Content -LiteralPath $correctionPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $correctionHash = Get-SuperBrainFileSha256 $correctionPath
    $correctionStatus=[string]$correction.status
    $correctionLifecycleOk=($correctionStatus-in@('closing','closed')-and$(if($correctionStatus-eq'closing'){-not[string]::IsNullOrWhiteSpace([string]$correction.closingAt)}else{-not[string]::IsNullOrWhiteSpace([string]$correction.closedAt)}))
    $correctionVerified = ($correction -and [string]$correction.schema -eq 'super-brain.correction-candidate.v1' -and [string]$correction.candidateId -eq $CorrectionCandidateId.ToLowerInvariant() -and (Test-SuperBrainWorkspaceKey ([string]$correction.workspaceKey) $WorkspaceKey) -and $correctionLifecycleOk -and [string]$correction.closureReason -eq 'verified_fix_outcome' -and $correction.rawPromptStored -eq $false -and $correction.durablePromotionAllowed -eq $true -and $correction.autonomyEvidenceLink -and $correction.autonomyEvidenceLink.eligible -eq $true -and -not [string]::IsNullOrWhiteSpace($correctionHash))
    if ($Mode -eq 'Apply' -and -not $correctionVerified) { throw 'USER_ADAPTATION_OBSERVER_CLOSED_CORRECTION_REQUIRED' }
  }

  $scope = if ([string]::IsNullOrWhiteSpace($WorkflowKey)) { 'project' } else { 'workflow' }
  $scopeKey = if ($scope -eq 'project') { $WorkspaceKey } else { "$WorkspaceKey`:$($WorkflowKey.ToLowerInvariant())" }
  $batchResult = $null
  if ($Mode -eq 'Apply') {
    $status=Get-UserAdaptationStatus -Root $Root -WorkspaceRoot $workspace
    $revision=if([string]$status.schema-eq'super-brain.user-adaptation-status.v2'){[int]$status.revision}else{-1}
    if($revision-lt0){throw 'USER_ADAPTATION_OBSERVER_V2_REQUIRED'}
    $canonicalRoot=Join-Path $workspace 'runtime-state\user-adaptation-verifications';$canonicalName=(Get-SuperBrainCanonicalTaskToken $TaskId)+'--'+$verificationHash+'.json';if(-not(Test-SuperBrainChildPath $canonicalRoot $verificationPath)-or-not[string]::Equals([IO.Path]::GetFileName([IO.Path]::GetFullPath($verificationPath)),$canonicalName,[StringComparison]::OrdinalIgnoreCase)){throw 'USER_ADAPTATION_OBSERVER_IMMUTABLE_VERIFICATION_REQUIRED'};if($Source-eq'user_correction'-and[string]::IsNullOrWhiteSpace($CorrectionTargetPreferenceId)){throw 'USER_ADAPTATION_OBSERVER_CORRECTION_TARGET_REQUIRED'}
    $batchItems=@($signalItems|ForEach-Object{[pscustomobject]@{habitKey=$_.habitKey;value=$_.value;parameters=$_.parameters}})
    $batchTransition='observer-batch-'+(Get-UserAdaptationHash "$TaskId|$verificationHash|$(@($batchItems|ForEach-Object{"$($_.habitKey)=$($_.value)"}|Sort-Object)-join'|')" 8)
    $batchResult=Add-UserAdaptationObservationBatchV2 -Root $Root -Items $batchItems -Source $Source -Scope $scope -ScopeKey $scopeKey -Context $Context -TaskId $TaskId -WorkspaceRoot $workspace -ExpectedRevision $revision -TransitionId $batchTransition -CorrectionCandidateId $CorrectionCandidateId -CorrectionCandidateHash $correctionHash -VerificationArtifactPath $verificationPath -VerificationHash $verificationHash -CorrectionTargetPreferenceId $CorrectionTargetPreferenceId
  }
  $result = [pscustomobject]@{
    ok=$true;schema='super-brain.user-adaptation-observer.v2';checkedAt=(Get-Date).ToString('o');mode=$Mode;taskId=$TaskId;workspaceKey=$WorkspaceKey;verificationMatch=[bool]$verificationMatch;verificationHash=if($verificationMatch){$verificationHash}else{''};correctionVerified=[bool]$correctionVerified;source=$Source;scope=$scope;scopeKey=$scopeKey;context=$Context;signalCount=$signalItems.Count;signals=@($signalItems|ForEach-Object{[pscustomobject]@{habitKey=$_.habitKey;value=$_.value;valueKind=$_.valueKind;evidenceKind=$_.evidenceKind}});appliedCount=if($batchResult){[int]$batchResult.appliedCount}else{0};duplicateCount=if($batchResult){[int]$batchResult.duplicateCount}else{0};batchRevision=if($batchResult){[int]$batchResult.revision}else{-1};batchReceiptId=if($batchResult){[string]$batchResult.receiptId}else{''};rawPromptStored=$false;inference=[pscustomobject]@{fromSummary=$false;fromTranscript=$false;fromAppliedPacket=$false;modelExtraction=$false}
  }
  Write-ObserverResult $result 0
} catch {
  Write-ObserverResult ([pscustomobject]@{ok=$false;schema='super-brain.user-adaptation-observer-error.v2';mode=$Mode;taskId=$TaskId;appliedCount=0;error=$_.Exception.Message;rawPromptStored=$false}) 1
}
if (-not $NoExit) { exit $script:ObserverExitCode }
