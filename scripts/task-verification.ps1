[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Summary = '',
  [string[]]$Changed = @(),
  [string[]]$Commands = @(),
  [string[]]$Risks = @(),
  [string[]]$Evidence = @(),
  [string[]]$NextSteps = @(),
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$TeamTaskId = '',
  [string[]]$AdaptationSignals = @(),
  [ValidateSet('general','coding','debugging','planning','review','design','release')]
  [string]$AdaptationContext = 'general',
  [ValidateSet('accepted_outcome','user_correction')]
  [string]$AdaptationSource = 'accepted_outcome',
  [string]$AdaptationWorkflowKey = '',
  [string]$CorrectionCandidateId = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$path = Join-Path $workspace 'last-task-verification.json'
$workspaceKeyValue = Get-SuperBrainWorkspaceKey $WorkspaceKey

function Read-WorkspaceJson([string]$Name) { $candidate = Join-Path $workspace $Name; if (-not (Test-Path $candidate)) { return $null }; try { Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } }
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Read-TaskScopedJson([string]$RelativeDir,[string]$FallbackName) {
  $safe = Safe-TaskId $TaskId
  if (-not [string]::IsNullOrWhiteSpace($safe)) {
    $root = Join-Path (Join-Path $workspace 'guard-state') $RelativeDir
    $candidate = Join-Path $root ($safe + '.json')
    if (Test-Path -LiteralPath $candidate) { try { return Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $taskDir = Join-Path $root $safe
      if (Test-Path -LiteralPath $taskDir) { $latest = Get-ChildItem -LiteralPath $taskDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($latest) { try { return Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} } }
  }
  $fallback = Read-WorkspaceJson $FallbackName
  if ([string]::IsNullOrWhiteSpace($TaskId) -or ($fallback -and [string]$fallback.taskId -eq $TaskId)) { return $fallback }
  return $null
}
function Test-TaskScopedEvidence($Obj) { if ([string]::IsNullOrWhiteSpace($TaskId) -or -not $Obj) { return $true }; return ([string]$Obj.taskId -eq $TaskId) }
function Limit-List([object[]]$Items, [int]$Max = 8) { @($Items | Select-Object -First $Max) }
function Get-FileSha256([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }; try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return '' } }
function Read-JsonFile([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }; try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null } }
function Get-CompletedCheckpoint([string]$Id) {
  $safe = Safe-TaskId $Id
  if ([string]::IsNullOrWhiteSpace($safe)) { return $null }
  return Read-JsonFile (Join-Path $workspace "runtime-state\checkpoints\completed\$safe.json")
}
function Get-AutonomyAuthorization([string]$Id,[string]$Key) {
  $safe = Safe-TaskId $Id
  $path = if ([string]::IsNullOrWhiteSpace($safe)) { '' } else { Join-Path $workspace "runtime-state\autonomy-authorizations\$safe.json" }
  $record = if ($path) { Read-JsonFile $path } else { $null }
  $privacyOk = ($record -and $record.PSObject.Properties['rawGoalStored'] -and $record.rawGoalStored -is [bool] -and -not [bool]$record.rawGoalStored -and $record.PSObject.Properties['rawPromptStored'] -and $record.rawPromptStored -is [bool] -and -not [bool]$record.rawPromptStored)
  $valid = ($record -and [string]$record.schema -eq 'super-brain.governed-autonomy-authorization.v1' -and [string]$record.taskId -eq $Id -and (Test-SuperBrainWorkspaceKey ([string]$record.workspaceKey) $Key) -and [string]$record.packageVersion -eq [string](Get-SuperBrainManifest $Root).version -and $record.executionHardGateOk -eq $true -and $record.checkpointCreated -eq $true -and [string]$record.authorizationMode -eq 'approved_plan' -and $privacyOk)
  return [pscustomobject]@{ valid=[bool]$valid; record=$record; path=$path; sha256=if($valid){Get-FileSha256 $path}else{''} }
}
function Get-CorrectionReference([string]$Id,[string]$Key) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return [pscustomobject]@{ valid=$false; candidateId=''; reason='not_requested' } }
  $candidateId = $Id.ToLowerInvariant()
  if ($candidateId -notmatch '^correction-[a-z0-9_-]{1,100}$') { return [pscustomobject]@{ valid=$false; candidateId=''; reason='invalid_id' } }
  $record = Read-JsonFile (Join-Path $workspace "reflection\correction-candidates\$candidateId.json")
  $valid = ($record -and [string]$record.schema -eq 'super-brain.correction-candidate.v1' -and [string]$record.candidateId -eq $candidateId -and (Test-SuperBrainWorkspaceKey ([string]$record.workspaceKey) $Key) -and $record.rawPromptStored -eq $false -and [string]$record.status -in @('pending_verification','analyzed'))
  return [pscustomobject]@{ valid=[bool]$valid; candidateId=if($valid){$candidateId}else{''}; reason=if($valid){'linked'}else{'candidate_not_eligible'} }
}
function Write-VerifiedTaskOutcome($Verification,$CompletedCheckpoint,$Authorization,$CorrectionReference) {
  $taskIdValue = [string]$Verification.taskId
  $safe = Safe-TaskId $taskIdValue
  if ([string]::IsNullOrWhiteSpace($safe)) { return [pscustomobject]@{ written=$false; reason='task_id_missing'; rawPromptStored=$false; rawSummaryStored=$false } }
  $checkpointVerified = ($CompletedCheckpoint -and [string]$CompletedCheckpoint.taskId -eq $taskIdValue -and [string]$CompletedCheckpoint.status -eq 'completed' -and [string]$CompletedCheckpoint.source -eq 'task-verification.ps1')
  $realUserPathVerified = ($Verification.userAcceptanceVerification -and $Verification.userAcceptanceVerification.ok -eq $true -and $Verification.userAcceptanceVerification.realUserPathVerification -eq $true)
  $verificationOk = ($Verification.ok -eq $true -and $Verification.taskScopedGuardOk -eq $true -and $realUserPathVerified -and $checkpointVerified)
  $autonomyVerified = ($verificationOk -and $Authorization.valid -eq $true)
  $outcomeRoot = Join-Path $workspace 'runtime-state\verified-task-outcomes'
  if (-not (Test-Path -LiteralPath $outcomeRoot)) { New-Item -ItemType Directory -Force -Path $outcomeRoot | Out-Null }
  $path = Join-Path $outcomeRoot ($safe + '.json')
  $record = [pscustomobject]@{
    schema = 'super-brain.verified-task-outcome.v1'
    recordId = 'verified-task-' + $safe
    taskId = $taskIdValue
    workspaceKey = [string]$Verification.workspaceKey
    packageVersion = [string](Get-SuperBrainManifest $Root).version
    recordedAt = (Get-Date).ToString('o')
    source = 'task-verification.ps1'
    verification = [pscustomobject]@{
      ok = [bool]($Verification.ok -eq $true)
      taskScopedGuardOk = [bool]($Verification.taskScopedGuardOk -eq $true)
      realUserPathVerified = [bool]$realUserPathVerified
      completedCheckpointVerified = [bool]$checkpointVerified
      packageVerificationOk = [bool]($Verification.lastVerify -and $Verification.lastVerify.ok -eq $true)
      hotRefreshOk = [bool]($Verification.lastHotRefresh -and $Verification.lastHotRefresh.ok -eq $true)
    }
    classification = [pscustomobject]@{
      verifiedRealWorldTask = [bool]$verificationOk
      verifiedAutonomyScenario = [bool]$autonomyVerified
    }
    authorization = if($Authorization.valid){[pscustomobject]@{recordId=[string]$Authorization.record.recordId;sha256=[string]$Authorization.sha256;source=[string]$Authorization.record.source;autonomyTier=[string]$Authorization.record.autonomyTier}}else{$null}
    correctionCandidateId = if($CorrectionReference.valid){[string]$CorrectionReference.candidateId}else{''}
    evidenceRefs = @('task-verification.ps1','completed-checkpoint','last-verify-package.json','last-hot-refresh.json','integration-parity-check')
    privacy = [pscustomobject]@{ rawPromptStored=$false; rawSummaryStored=$false }
  }
  Write-JsonUtf8NoBom $path $record 12
  return [pscustomobject]@{ written=$true; recordId=$record.recordId; taskId=$taskIdValue; sha256=(Get-FileSha256 $path); qualifiesRealWorldTask=$record.classification.verifiedRealWorldTask; qualifiesAutonomyScenario=$record.classification.verifiedAutonomyScenario; correctionCandidateId=$record.correctionCandidateId; path=$path; rawPromptStored=$false; rawSummaryStored=$false }
}

$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastRelease = Read-WorkspaceJson 'last-release.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$constraintPreflight = Read-WorkspaceJson 'last-accepted-constraints-preflight.json'
$taskGraph = Read-WorkspaceJson 'task-graph.json'
$stepLedger = Read-WorkspaceJson 'step-ledger.json'
$projectContinuity = Read-WorkspaceJson 'last-project-continuity.json'
$impact = Read-WorkspaceJson 'last-impact-advisor.json'
$teamTask = $null
if ($TeamTaskId) { $teamPath = Join-Path (Join-Path $workspace 'team-tasks') "$TeamTaskId.json"; if (Test-Path $teamPath) { try { $teamTask = Get-Content -LiteralPath $teamPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $teamTask = $null } } }
$lastDoctor = $null; $doctorRiskSummary = $null; $doctorRisks = @()
try { $doctorJson = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json; if ($LASTEXITCODE -eq 0) { $lastDoctor = $doctorJson | ConvertFrom-Json; $doctorRiskSummary = $lastDoctor.riskSummary; $doctorRisks = @($lastDoctor.risks) } } catch {}
$constraintConflicts = if ($constraintPreflight) { @($constraintPreflight.conflicts) } else { @() }
$constraintsPreserved = (-not $constraintPreflight) -or ($constraintPreflight.ok -eq $true -and $constraintConflicts.Count -eq 0)
$scopedCheckpoint = $null
if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
  try { $scopedCheckpoint = & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Get -TaskId $TaskId -Json | ConvertFrom-Json } catch {}
}
$matchingCheckpoint = $scopedCheckpoint -and [string]$scopedCheckpoint.taskId -eq $TaskId
$legacyContinuityTaskMatch = ([string]::IsNullOrWhiteSpace($TaskId) -or ($taskGraph -and $stepLedger -and [string]$taskGraph.taskId -eq $TaskId -and [string]$stepLedger.taskId -eq $TaskId))
$continuityTaskMatch = ($matchingCheckpoint -or $legacyContinuityTaskMatch)
$openSteps = if($matchingCheckpoint){@($scopedCheckpoint.pendingSteps)}elseif($stepLedger){@($stepLedger.openSteps)}else{@()}
$continuitySummary = [pscustomobject]@{ source=if($matchingCheckpoint){'scoped_checkpoint'}elseif($legacyContinuityTaskMatch){'legacy_task_graph'}else{'none'}; taskId=if($matchingCheckpoint){$scopedCheckpoint.taskId}elseif($taskGraph){$taskGraph.taskId}else{''}; taskStatus=if($matchingCheckpoint){$scopedCheckpoint.status}elseif($taskGraph){$taskGraph.status}else{''}; taskScoped=$continuityTaskMatch; goal=if($matchingCheckpoint){$scopedCheckpoint.goal}elseif($taskGraph){$taskGraph.goal}else{''}; openStepCount=@($openSteps).Count; completedCount=if($matchingCheckpoint){@($scopedCheckpoint.completedSteps).Count}elseif($stepLedger){@($stepLedger.completedSteps).Count}else{0}; skippedCount=if($stepLedger){@($stepLedger.skippedSteps).Count}else{0}; candidateFindings=if($projectContinuity -and $projectContinuity.findingCounts){[int]$projectContinuity.findingCounts.candidate}else{0}; nextAction=if($matchingCheckpoint){$scopedCheckpoint.nextAction}elseif($projectContinuity){$projectContinuity.nextAction}else{''} }
$impactSummary = [pscustomobject]@{ riskLevel=if($impact){$impact.riskLevel}else{''}; affectedScripts=if($impact){@(Limit-List @($impact.affectedScripts) 10)}else{@()}; recommendedChecks=if($impact){@(Limit-List @($impact.recommendedChecks) 10)}else{@()} }
$integrationParity = Read-WorkspaceJson 'last-integration-parity-check.json'
$causalReview = Read-TaskScopedJson 'change-causality-reviews' 'last-causal-change-review.json'
$contractReplay = Read-TaskScopedJson 'integration-contract-replay' 'last-integration-contract-replay.json'
$taskScopedGuardOk = (Test-TaskScopedEvidence $causalReview) -and (Test-TaskScopedEvidence $contractReplay)
$moduleVerification = if ($integrationParity -and $integrationParity.moduleVerification) { $integrationParity.moduleVerification } else { [pscustomobject]@{ status='unknown module smoke OK'; ok=$null } }
$integrationVerification = if ($integrationParity -and $integrationParity.integrationVerification) { $integrationParity.integrationVerification } else { [pscustomobject]@{ status='unknown integration smoke OK'; ok=$null } }
$userAcceptanceVerification = if ($integrationParity -and $integrationParity.userAcceptanceVerification) { $integrationParity.userAcceptanceVerification } else { [pscustomobject]@{ status='unknown user-facing acceptance OK'; ok=$null; realUserPathVerification=$false } }
$verification = [pscustomobject]@{
  ok = (((($lastVerify -and $lastVerify.ok -eq $true) -or $taskScopedGuardOk) -and ($lastHotRefresh -and $lastHotRefresh.ok -eq $true) -and ($null -eq $lastDoctor -or $lastDoctor.ok -eq $true -or $taskScopedGuardOk) -and $constraintsPreserved -and $taskScopedGuardOk))
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  version = (Get-SuperBrainManifest $Root).version
  taskId = $TaskId
  workspaceKey = $workspaceKeyValue
  summary = $Summary
  changed = @($Changed)
  commands = @($Commands)
  risks = @($Risks)
  evidence = @($Evidence)
  nextSteps = @($NextSteps)
  continuity = $continuitySummary
  impact = $impactSummary
  moduleVerification = $moduleVerification
  integrationVerification = $integrationVerification
  userAcceptanceVerification = $userAcceptanceVerification
  integrationParity = if ($integrationParity) { [pscustomobject]@{ ok=$integrationParity.ok; unresolvedIntegrationDrift=$integrationParity.unresolvedIntegrationDrift; drifts=@($integrationParity.drifts | Select-Object -First 10) } } else { $null }
  causalReview = if ($causalReview) { [pscustomobject]@{ ok=$causalReview.ok; taskId=$causalReview.taskId; taskScoped=(Test-TaskScopedEvidence $causalReview); gaps=@($causalReview.gaps).Count; decision=$causalReview.expectedVsActual.decision } } else { $null }
  integrationContractReplay = if ($contractReplay) { [pscustomobject]@{ ok=$contractReplay.ok; taskId=$contractReplay.taskId; taskScoped=(Test-TaskScopedEvidence $contractReplay); unresolvedBehaviorMismatch=$contractReplay.unresolvedBehaviorMismatch; mismatches=@($contractReplay.mismatches).Count } } else { $null }
  taskScopedGuardOk = $taskScopedGuardOk
  teamTask = if ($teamTask) { [pscustomobject]@{ teamTaskId=$teamTask.teamTaskId; dispatchLevel=$teamTask.dispatchLevel; delegationCount=@($teamTask.delegations).Count; decisionStatus=$teamTask.commanderDecision.status; verificationStatus=$teamTask.verification.status } } else { $null }
  constraintPreflight = if ($constraintPreflight) { [pscustomobject]@{ ok=$constraintPreflight.ok; checkedAt=$constraintPreflight.checkedAt; required=$constraintPreflight.required; guardHash=$constraintPreflight.guardHash; constraintCount=@($constraintPreflight.constraints).Count } } else { $null }
  constraintsPreserved = $constraintsPreserved
  constraintConflicts = @($constraintConflicts | Select-Object -First 10)
  doctor = if ($lastDoctor) { [pscustomobject]@{ ok=$lastDoctor.ok; riskSummary=$doctorRiskSummary; risks=@($doctorRisks | Select-Object -First 10) } } else { $null }
  lastVerify = if ($lastVerify) { [pscustomobject]@{ ok=$lastVerify.ok; checkedAt=$lastVerify.checkedAt; version=$lastVerify.version } } else { $null }
  lastRelease = if ($lastRelease) { [pscustomobject]@{ ok=$lastRelease.ok; checkedAt=$lastRelease.checkedAt; destination=$lastRelease.destination } } else { $null }
  lastHotRefresh = if ($lastHotRefresh) { [pscustomobject]@{ ok=$lastHotRefresh.ok; checkedAt=$lastHotRefresh.checkedAt } } else { $null }
  adaptationObservation = [pscustomobject]@{ requested=(@($AdaptationSignals).Count-gt0); ok=$null; appliedCount=0; rawPromptStored=$false }
  autonomyEvidenceOutcome = [pscustomobject]@{ written=$false; reason='verification_not_yet_completed'; rawPromptStored=$false; rawSummaryStored=$false }
}
Write-JsonUtf8NoBom $path $verification 10
if ($verification.ok) {
  if (@($AdaptationSignals).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($TaskId)) {
    try {
      $observerArgs = @{Mode='Apply';TaskId=$TaskId;WorkspaceKey=$workspaceKeyValue;Context=$AdaptationContext;Source=$AdaptationSource;Signals=@($AdaptationSignals);NoExit=$true;Json=$true}
      if (-not [string]::IsNullOrWhiteSpace($AdaptationWorkflowKey)) { $observerArgs.WorkflowKey = $AdaptationWorkflowKey }
      if (-not [string]::IsNullOrWhiteSpace($CorrectionCandidateId)) { $observerArgs.CorrectionCandidateId = $CorrectionCandidateId }
      $observerRaw = @(& (Join-Path $PSScriptRoot 'user-adaptation-observer.ps1') @observerArgs 2>$null)
      $observer = (($observerRaw -join "`n") | ConvertFrom-Json)
      $verification.adaptationObservation = [pscustomobject]@{requested=$true;ok=$observer.ok;appliedCount=[int]$observer.appliedCount;duplicateCount=[int]$observer.duplicateCount;source=$observer.source;scope=$observer.scope;context=$observer.context;rawPromptStored=$false}
    } catch {
      $verification.adaptationObservation = [pscustomobject]@{requested=$true;ok=$false;appliedCount=0;errorCode='USER_ADAPTATION_OBSERVER_FAILED';rawPromptStored=$false}
    }
  }
  $completedCheckpoint = $null
  try {
    $activeCheckpoint = $scopedCheckpoint
    if (-not $activeCheckpoint -and -not [string]::IsNullOrWhiteSpace($TaskId)) { $activeCheckpoint = & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Get -TaskId $TaskId -Json | ConvertFrom-Json }
    $matchingCheckpoint = $activeCheckpoint -and ([string]::IsNullOrWhiteSpace($TaskId) -or [string]$activeCheckpoint.taskId -eq $TaskId)
    if ($matchingCheckpoint) {
      & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Complete -TaskId ([string]$activeCheckpoint.taskId) -Source 'task-verification.ps1' -CurrentStep $Summary -NextAction ((@($NextSteps) -join '; ')) -Evidence @($Evidence) -Json | Out-Null
      $completedCheckpoint = Get-CompletedCheckpoint ([string]$activeCheckpoint.taskId)
    }
  } catch {}
  try {
    $authorization = Get-AutonomyAuthorization ([string]$verification.taskId) $workspaceKeyValue
    $correctionReference = Get-CorrectionReference $CorrectionCandidateId $workspaceKeyValue
    $verification.autonomyEvidenceOutcome = Write-VerifiedTaskOutcome $verification $completedCheckpoint $authorization $correctionReference
  } catch {
    $verification.autonomyEvidenceOutcome = [pscustomobject]@{ written=$false; reason='outcome_record_write_failed'; rawPromptStored=$false; rawSummaryStored=$false }
  }
  if ($continuityTaskMatch -and @($openSteps).Count -eq 0 -and $taskGraph -and $taskGraph.status -eq 'active') { try { & (Join-Path $PSScriptRoot 'project-continuity.ps1') -Action CompleteTask -Evidence (($Evidence + @($Summary)) -join '; ') | Out-Null } catch {} }
  try { & (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') -WorkspaceKey $workspaceKeyValue -Summary $Summary -NextAction ((@($NextSteps) -join '; ')) -Evidence @($Evidence + @('task-verification.ps1')) -Json | Out-Null } catch {}
  try { & (Join-Path $PSScriptRoot 'post-task-maintenance.ps1') -ApplySafe -Summary $Summary -TaskId $TaskId -Evidence @($Evidence + @('task-verification.ps1')) -Json | Out-Null } catch {}
}
Write-JsonUtf8NoBom $path $verification 10
if ($Json) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 } else { Write-Host "TASK_VERIFICATION_OK path=$path ok=$($verification.ok)" }
if (-not $verification.ok) { exit 1 }
exit 0
