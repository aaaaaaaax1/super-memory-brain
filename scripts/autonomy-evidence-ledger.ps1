[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet('Audit')]
  [string]$Action = 'Audit',
  [string]$WorkspaceRoot = '',
  [string]$WorkspaceKey = '',
  [string]$OutputPath = '',
  [switch]$WriteReport,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
  Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
} else {
  [IO.Path]::GetFullPath($WorkspaceRoot)
}
$effectiveWorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
$outcomeRoot = Join-Path $workspace 'runtime-state\verified-task-outcomes'
$authorizationRoot = Join-Path $workspace 'runtime-state\autonomy-authorizations'
$correctionRoot = Join-Path $workspace 'reflection\correction-candidates'

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
  if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
  return $Object.PSObject.Properties[$Name].Value
}

function Get-SafeTaskId([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $safe = (($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ($safe.Length -gt 120) { $safe = $safe.Substring(0,120) }
  return $safe
}

function Read-JsonFile([string]$Path) {
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { return $null }
}

function Get-FileSha256([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
  catch { return '' }
}

function Test-True($Object, [string]$Name) {
  return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $Object.PSObject.Properties[$Name].Value -is [bool] -and [bool]$Object.PSObject.Properties[$Name].Value)
}

function Test-False($Object, [string]$Name) {
  return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $Object.PSObject.Properties[$Name].Value -is [bool] -and -not [bool]$Object.PSObject.Properties[$Name].Value)
}

function Add-Rejection($List, [string]$Kind, [string]$FileName, [string[]]$Reasons) {
  [void]$List.Add([pscustomobject]@{
    kind = $Kind
    file = $FileName
    reasons = @($Reasons | Select-Object -Unique -First 12)
  })
}

function Get-OutcomeAssessment($Record, [string]$Path) {
  $reasons = New-Object Collections.ArrayList
  $taskId = [string](Get-PropertyValue $Record 'taskId' '')
  $safeTaskId = Get-SafeTaskId $taskId
  $fileTaskId = [IO.Path]::GetFileNameWithoutExtension($Path).ToLowerInvariant()
  $verification = Get-PropertyValue $Record 'verification' $null
  $privacy = Get-PropertyValue $Record 'privacy' $null
  $classification = Get-PropertyValue $Record 'classification' $null

  if ([string](Get-PropertyValue $Record 'schema' '') -ne 'super-brain.verified-task-outcome.v1') { [void]$reasons.Add('schema_invalid') }
  if ([string]::IsNullOrWhiteSpace($taskId) -or $safeTaskId -ne $fileTaskId) { [void]$reasons.Add('task_identity_invalid') }
  if (-not (Test-SuperBrainWorkspaceKey ([string](Get-PropertyValue $Record 'workspaceKey' '')) $effectiveWorkspaceKey)) { [void]$reasons.Add('workspace_mismatch') }
  if ([string](Get-PropertyValue $Record 'packageVersion' '') -ne [string]$manifest.version) { [void]$reasons.Add('package_version_mismatch') }
  if (-not (Test-False $privacy 'rawPromptStored') -or -not (Test-False $privacy 'rawSummaryStored')) { [void]$reasons.Add('privacy_invariant_failed') }
  if (-not (Test-True $verification 'ok')) { [void]$reasons.Add('verification_not_ok') }
  if (-not (Test-True $verification 'taskScopedGuardOk')) { [void]$reasons.Add('task_scope_guard_missing') }
  if (-not (Test-True $verification 'realUserPathVerified')) { [void]$reasons.Add('real_user_path_not_verified') }
  if (-not (Test-True $verification 'completedCheckpointVerified')) { [void]$reasons.Add('completed_checkpoint_not_verified') }
  if (-not (Test-True $verification 'packageVerificationOk')) { [void]$reasons.Add('package_verification_missing') }
  if (-not (Test-True $verification 'hotRefreshOk')) { [void]$reasons.Add('hot_refresh_verification_missing') }
  if (-not (Test-True $classification 'verifiedRealWorldTask')) { [void]$reasons.Add('real_world_eligibility_not_proven') }
  try { [void][DateTimeOffset]::Parse([string](Get-PropertyValue $Record 'recordedAt' '')) } catch { [void]$reasons.Add('recorded_at_invalid') }
  $completedCheckpoint = Read-JsonFile (Join-Path $workspace ("runtime-state\checkpoints\completed\" + $safeTaskId + '.json'))
  if (-not $completedCheckpoint -or [string](Get-PropertyValue $completedCheckpoint 'taskId' '') -ne $taskId -or [string](Get-PropertyValue $completedCheckpoint 'status' '') -ne 'completed' -or [string](Get-PropertyValue $completedCheckpoint 'source' '') -ne 'task-verification.ps1') { [void]$reasons.Add('completed_checkpoint_chain_invalid') }

  $validRealWorld = ($reasons.Count -eq 0)
  $autonomyReasons = New-Object Collections.ArrayList
  if (-not $validRealWorld) { [void]$autonomyReasons.Add('base_outcome_invalid') }
  if (-not (Test-True $classification 'verifiedAutonomyScenario')) { [void]$autonomyReasons.Add('autonomy_eligibility_not_proven') }

  $authorization = Get-PropertyValue $Record 'authorization' $null
  if ($authorization) {
    $authorizationPath = Join-Path $authorizationRoot ($safeTaskId + '.json')
    $authorizationRecord = Read-JsonFile $authorizationPath
    $actualAuthorizationHash = Get-FileSha256 $authorizationPath
    if (-not $authorizationRecord) { [void]$autonomyReasons.Add('authorization_record_missing') }
    else {
      if ([string](Get-PropertyValue $authorizationRecord 'schema' '') -ne 'super-brain.governed-autonomy-authorization.v1') { [void]$autonomyReasons.Add('authorization_schema_invalid') }
      if ([string](Get-PropertyValue $authorizationRecord 'taskId' '') -ne $taskId) { [void]$autonomyReasons.Add('authorization_task_mismatch') }
      if (-not (Test-SuperBrainWorkspaceKey ([string](Get-PropertyValue $authorizationRecord 'workspaceKey' '')) $effectiveWorkspaceKey)) { [void]$autonomyReasons.Add('authorization_workspace_mismatch') }
      if ([string](Get-PropertyValue $authorizationRecord 'packageVersion' '') -ne [string]$manifest.version) { [void]$autonomyReasons.Add('authorization_package_version_mismatch') }
      if (-not (Test-True $authorizationRecord 'executionHardGateOk') -or -not (Test-True $authorizationRecord 'checkpointCreated')) { [void]$autonomyReasons.Add('authorization_gate_not_verified') }
      if ([string](Get-PropertyValue $authorizationRecord 'authorizationMode' '') -ne 'approved_plan') { [void]$autonomyReasons.Add('authorization_mode_invalid') }
      if (-not (Test-False $authorizationRecord 'rawGoalStored') -or -not (Test-False $authorizationRecord 'rawPromptStored')) { [void]$autonomyReasons.Add('authorization_privacy_invariant_failed') }
      if ([string](Get-PropertyValue $authorization 'sha256' '') -ne $actualAuthorizationHash) { [void]$autonomyReasons.Add('authorization_hash_mismatch') }
    }
  } else {
    [void]$autonomyReasons.Add('authorization_missing')
  }

  return [pscustomobject]@{
    taskId = $taskId
    recordId = [string](Get-PropertyValue $Record 'recordId' '')
    path = $Path
    sha256 = Get-FileSha256 $Path
    record = $Record
    validRealWorld = $validRealWorld
    validAutonomy = ($autonomyReasons.Count -eq 0)
    reasons = @($reasons)
    autonomyReasons = @($autonomyReasons)
  }
}

try {
  $rejections = New-Object Collections.ArrayList
  $assessments = New-Object Collections.ArrayList
  $outcomeFiles = @(Get-ChildItem -LiteralPath $outcomeRoot -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
  foreach ($file in $outcomeFiles) {
    $record = Read-JsonFile $file.FullName
    if (-not $record) {
      Add-Rejection $rejections 'outcome' $file.Name @('json_invalid')
      continue
    }
    [void]$assessments.Add((Get-OutcomeAssessment $record $file.FullName))
  }

  $duplicateTaskIds = @($assessments | Group-Object taskId | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) -and $_.Count -gt 1 } | ForEach-Object { [string]$_.Name })
  $validOutcomes = @()
  foreach ($assessment in $assessments) {
    if ($duplicateTaskIds -contains [string]$assessment.taskId) {
      Add-Rejection $rejections 'outcome' ([IO.Path]::GetFileName($assessment.path)) @('duplicate_task_id')
    } elseif ($assessment.validRealWorld) {
      $validOutcomes += $assessment
    } else {
      Add-Rejection $rejections 'outcome' ([IO.Path]::GetFileName($assessment.path)) @($assessment.reasons)
    }
  }
  $validAutonomyOutcomes = @($validOutcomes | Where-Object { $_.validAutonomy })
  foreach ($assessment in @($validOutcomes | Where-Object { -not $_.validAutonomy })) {
    Add-Rejection $rejections 'autonomy' ([IO.Path]::GetFileName($assessment.path)) @($assessment.autonomyReasons)
  }

  $outcomesByRecordId = @{}
  foreach ($assessment in $validOutcomes) {
    if (-not [string]::IsNullOrWhiteSpace([string]$assessment.recordId)) { $outcomesByRecordId[[string]$assessment.recordId] = $assessment }
  }
  $validCorrectionIds = New-Object Collections.ArrayList
  $correctionFiles = @(Get-ChildItem -LiteralPath $correctionRoot -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
  foreach ($file in $correctionFiles) {
    $correction = Read-JsonFile $file.FullName
    if (-not $correction) {
      Add-Rejection $rejections 'correction' $file.Name @('json_invalid')
      continue
    }
    $correctionReasons = New-Object Collections.ArrayList
    $candidateId = [string](Get-PropertyValue $correction 'candidateId' '')
    $link = Get-PropertyValue $correction 'autonomyEvidenceLink' $null
    if ([string](Get-PropertyValue $correction 'schema' '') -ne 'super-brain.correction-candidate.v1') { [void]$correctionReasons.Add('schema_invalid') }
    if ([string](Get-PropertyValue $correction 'status' '') -ne 'closed') { [void]$correctionReasons.Add('not_closed') }
    if ([string]::IsNullOrWhiteSpace($candidateId)) { [void]$correctionReasons.Add('candidate_identity_invalid') }
    if (-not (Test-SuperBrainWorkspaceKey ([string](Get-PropertyValue $correction 'workspaceKey' '')) $effectiveWorkspaceKey)) { [void]$correctionReasons.Add('workspace_mismatch') }
    if (-not (Test-False $correction 'rawPromptStored')) { [void]$correctionReasons.Add('privacy_invariant_failed') }
    if (-not $link -or -not (Test-True $link 'eligible')) {
      [void]$correctionReasons.Add('verified_outcome_link_missing')
    } else {
      $recordId = [string](Get-PropertyValue $link 'verifiedOutcomeRecordId' '')
      $outcome = if ($outcomesByRecordId.ContainsKey($recordId)) { $outcomesByRecordId[$recordId] } else { $null }
      if (-not $outcome) { [void]$correctionReasons.Add('verified_outcome_not_eligible') }
      else {
        if ([string](Get-PropertyValue $link 'taskId' '') -ne [string]$outcome.taskId) { [void]$correctionReasons.Add('linked_task_mismatch') }
        if ([string](Get-PropertyValue $link 'verifiedOutcomeSha256' '') -ne [string]$outcome.sha256) { [void]$correctionReasons.Add('linked_outcome_hash_mismatch') }
        if ([string](Get-PropertyValue $outcome.record 'correctionCandidateId' '') -ne $candidateId) { [void]$correctionReasons.Add('outcome_correction_mismatch') }
      }
    }
    if ($correctionReasons.Count -eq 0) { [void]$validCorrectionIds.Add($candidateId) }
    else { Add-Rejection $rejections 'correction' $file.Name @($correctionReasons) }
  }
  $duplicateCorrectionIds = @($validCorrectionIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { [string]$_.Name })
  $closedCorrectionLoops = @($validCorrectionIds | Where-Object { $duplicateCorrectionIds -notcontains [string]$_ }).Count
  foreach ($id in $duplicateCorrectionIds) { Add-Rejection $rejections 'correction' ($id + '.json') @('duplicate_candidate_id') }

  $result = [pscustomobject]@{
    ok = $true
    action = $Action
    schema = 'super-brain.autonomy-evidence-ledger.v1'
    checkedAt = (Get-Date).ToString('o')
    packageVersion = [string]$manifest.version
    workspaceKey = $effectiveWorkspaceKey
    evidenceCounts = [pscustomobject]@{
      verifiedRealWorldTasks = @($validOutcomes).Count
      verifiedAutonomyScenarios = @($validAutonomyOutcomes).Count
      closedCorrectionLoops = $closedCorrectionLoops
    }
    provenance = [pscustomobject]@{
      completedCheckpointOrTaskCardAloneCounts = $false
      callerSuppliedCountsAccepted = $false
      rawPromptStored = $false
      rawSummaryStored = $false
      recordSchemas = @('super-brain.verified-task-outcome.v1','super-brain.governed-autonomy-authorization.v1','super-brain.correction-candidate.v1')
      guard = 'Only a current-version, task-scoped verified outcome can count; autonomy additionally requires a matching governed authorization, and correction closure additionally requires an immutable link to that outcome.'
    }
    records = [pscustomobject]@{
      outcomeFilesScanned = $outcomeFiles.Count
      validVerifiedOutcomes = @($validOutcomes | ForEach-Object { [pscustomobject]@{ taskId=$_.taskId; recordId=$_.recordId; sha256=$_.sha256 } })
      validAutonomyOutcomes = @($validAutonomyOutcomes | ForEach-Object { [pscustomobject]@{ taskId=$_.taskId; recordId=$_.recordId; sha256=$_.sha256 } })
      correctionFilesScanned = $correctionFiles.Count
      qualifyingCorrectionCandidateIds = @($validCorrectionIds | Where-Object { $duplicateCorrectionIds -notcontains [string]$_ } | Select-Object -Unique)
      rejectedCount = $rejections.Count
      rejections = @($rejections | Select-Object -First 100)
    }
    path = if ($WriteReport -or -not [string]::IsNullOrWhiteSpace($OutputPath)) { if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $workspace 'last-autonomy-evidence-ledger.json' } else { [IO.Path]::GetFullPath($OutputPath) } } else { '' }
  }
  if (-not [string]::IsNullOrWhiteSpace($result.path)) { Write-JsonUtf8NoBom $result.path $result 16 }
  if ($Json) { $result | ConvertTo-Json -Depth 20 }
  else { Write-Host "AUTONOMY_EVIDENCE_LEDGER tasks=$($result.evidenceCounts.verifiedRealWorldTasks) autonomy=$($result.evidenceCounts.verifiedAutonomyScenarios) corrections=$($result.evidenceCounts.closedCorrectionLoops) rejected=$($result.records.rejectedCount)" }
  exit 0
} catch {
  $failure = [pscustomobject]@{
    ok = $false
    action = $Action
    schema = 'super-brain.autonomy-evidence-ledger-error.v1'
    error = $_.Exception.Message
    rawPromptStored = $false
  }
  if ($Json) { $failure | ConvertTo-Json -Depth 8 } else { Write-Host "AUTONOMY_EVIDENCE_LEDGER_FAILED $($_.Exception.Message)" }
  exit 1
}
