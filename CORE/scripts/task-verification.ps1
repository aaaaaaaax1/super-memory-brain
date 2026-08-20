[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$Summary = '',
  [string[]]$Changed = @(),
  [string[]]$Commands = @(),
  [string[]]$Risks = @(),
  [string[]]$Evidence = @(),
  [string]$IntentFulfillmentJson = '',
  [string]$DecisionResultJson = '',
  [string[]]$NextSteps = @(),
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [string]$TeamTaskId = '',
  [string[]]$AdaptationSignals = @(),
  [string[]]$AdaptationMeasurements = @(),
  [ValidateSet('general','coding','debugging','planning','review','design','release')]
  [string]$AdaptationContext = 'general',
  [ValidateSet('accepted_outcome','user_correction')]
  [string]$AdaptationSource = 'accepted_outcome',
  [string]$AdaptationWorkflowKey = '',
  [string]$AdaptationConfirmationReceiptPath = '',
  [string]$AdaptationConfirmationReceiptHash = '',
  [string]$CorrectionCandidateId = '',
  [string]$CorrectionTargetPreferenceId = '',
  [string]$LearningCandidateId = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\user-adaptation-core.ps1')
. (Join-Path $PSScriptRoot 'internal\intent-resolution.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$path = Join-Path $workspace 'last-task-verification.json'
$verificationRoot = Join-Path $workspace 'runtime-state\task-verifications'
$adaptationVerificationRoot = Join-Path $workspace 'runtime-state\user-adaptation-verifications'
$adaptationOutcomeRoot = Join-Path $workspace 'runtime-state\user-adaptation-outcomes'
$learningReceiptRoot = Join-Path $workspace 'runtime-state\learning-verification-receipts'
foreach ($directory in @($verificationRoot,$adaptationVerificationRoot,$adaptationOutcomeRoot,$learningReceiptRoot)) { if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null } }
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
function Test-ExactTaskWorkspaceEvidence($Obj) {
  if (-not $Obj -or [string]::IsNullOrWhiteSpace($TaskId)) { return $false }
  return ($Obj.PSObject.Properties['taskId'] -and [string]$Obj.taskId -eq $TaskId -and $Obj.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$Obj.workspaceKey) $workspaceKeyValue))
}
function Limit-List([object[]]$Items, [int]$Max = 8) { @($Items | Select-Object -First $Max) }
function Get-FileSha256([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }; try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return '' } }
function Read-JsonFile([string]$Path) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }; try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null } }
function Get-CompletedCheckpoint([string]$Id) {
  $safe = Safe-TaskId $Id
  if ([string]::IsNullOrWhiteSpace($safe)) { return $null }
  $root = Join-Path $workspace 'runtime-state\checkpoints\completed'
  $canonical = Get-SuperBrainCanonicalTaskPath $root $Id '.json'
  $record = Read-JsonFile $canonical
  if ($record -and [string]$record.taskId -eq $Id) { return $record }
  $legacy = Read-JsonFile (Join-Path $root ($safe + '.json'))
  if ($legacy -and [string]$legacy.taskId -eq $Id) { return $legacy }
  return $null
}
function Write-CompletedTaskReplayDiagnostic($Verification,$CompletedCheckpoint) {
  $taskIdValue=[string]$Verification.taskId
  $safe=Safe-TaskId $taskIdValue
  $canonicalPath=if([string]::IsNullOrWhiteSpace($taskIdValue)){''}else{Get-SuperBrainCanonicalTaskPath $verificationRoot $taskIdValue '.json'}
  $outcomePath=if([string]::IsNullOrWhiteSpace($safe)){''}else{Join-Path (Join-Path $workspace 'runtime-state\verified-task-outcomes') ($safe+'.json')}
  $canonicalHash=Get-FileSha256 $canonicalPath
  $outcomeHash=Get-FileSha256 $outcomePath
  $attemptMaterial=[ordered]@{taskId=$taskIdValue;workspaceKey=[string]$Verification.workspaceKey;summaryHash=Get-SuperBrainStableHash ([string]$Verification.summary) 32;evidenceHashes=@($Verification.evidence|ForEach-Object{Get-SuperBrainStableHash ([string]$_) 16});adaptationRequested=[bool]$Verification.adaptationObservation.requested}
  $record=[pscustomobject]@{
    ok=$true;schema='super-brain.task-verification-replay-diagnostic.v1';checkedAt=(Get-Date).ToString('o');taskId=$taskIdValue;workspaceKey=[string]$Verification.workspaceKey;reason='completed_task_replay_withheld';attemptHash=Get-SuperBrainStableHash ($attemptMaterial|ConvertTo-Json -Depth 6 -Compress) 64
    completionOutcome=[pscustomobject]@{attempted=$false;completed=$true;reason='existing_verified_checkpoint';transactionId=if($CompletedCheckpoint.PSObject.Properties['completionTransactionId']){[string]$CompletedCheckpoint.completionTransactionId}else{''};taskStateRevision=if($CompletedCheckpoint.PSObject.Properties['taskStateRevision']){[int]$CompletedCheckpoint.taskStateRevision}else{0}}
    canonicalVerification=[pscustomobject]@{preserved=$true;relativePath=if($canonicalPath){$canonicalPath.Substring($workspace.Length).TrimStart('\','/')-replace'\\','/'}else{''};sha256=$canonicalHash;available=($canonicalHash-match'^[a-f0-9]{64}$')}
    verifiedOutcome=[pscustomobject]@{preserved=$true;relativePath=if($outcomePath){$outcomePath.Substring($workspace.Length).TrimStart('\','/')-replace'\\','/'}else{''};sha256=$outcomeHash;available=($outcomeHash-match'^[a-f0-9]{64}$')}
    adaptationObservation=[pscustomobject]@{requested=[bool]$Verification.adaptationObservation.requested;ok=$false;appliedCount=0;reason='USER_ADAPTATION_COMPLETED_TASK_REPLAY_WITHHELD';rawPromptStored=$false}
    rawPromptStored=$false;rawSummaryStored=$false;rawTranscriptStored=$false
  }
  Write-JsonUtf8NoBom (Join-Path $workspace 'last-task-verification-replay.json') $record 10
  return $record
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
function Get-TaskEvidenceBinding([string]$Id,[string]$Key) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return [pscustomobject]@{ binding=$null; status='not_applicable'; contract=$null } }
  try {
    $contractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') -Action Get -TaskId $Id -WorkspaceKey $Key -NoExit -Json 2>&1)
    $contract = ConvertFrom-SuperBrainJsonOutput ($contractRaw -join "`n") 'task verification evidence contract'
    if (-not $contract -or $contract.ok -ne $true -or [string]$contract.taskId -ne $Id -or [string]$contract.status -ne 'active') { return [pscustomobject]@{ binding=$null; status='withheld_contract_unavailable'; contract=$null } }
    if (-not (Test-SuperBrainWorkspaceKey ([string]$contract.workspaceKey) (Get-SuperBrainWorkspaceKey $Key)) -or [string]::IsNullOrWhiteSpace([string]$contract.ownerSessionKey)) { return [pscustomobject]@{ binding=$null; status='withheld_contract_identity_invalid'; contract=$contract } }
    return [pscustomobject]@{ binding=(New-SuperBrainEvidenceBinding -TaskId $Id -WorkspaceKey $Key -OwnerSessionKey ([string]$contract.ownerSessionKey) -Root $Root); status='bound'; contract=$contract }
  } catch {
    return [pscustomobject]@{ binding=$null; status='withheld_contract_read_failed'; contract=$null }
  }
}
function Get-TaskStateProjection([string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
  $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $Id '.json'
  $projection = Read-JsonFile $projectionPath
  if ($projection -and [string]$projection.taskId -eq $Id) { return $projection }
  return $null
}
function Get-CausalReviewBindingStatus([object]$Review,[bool]$Required,[object]$EvidenceInfo) {
  if (-not $Required) { return [pscustomobject]@{ required=$false; ok=$true; code='CAUSAL_REVIEW_BINDING_NOT_REQUIRED'; reason='not_required'; decision=''; reviewId=''; reviewPath=''; reviewArtifactHash=''; reviewFingerprint='' } }
  if (-not $Review) { return [pscustomobject]@{ required=$true; ok=$false; code='CAUSAL_REVIEW_MISSING'; reason='causal_review_missing'; decision=''; reviewId=''; reviewPath=''; reviewArtifactHash=''; reviewFingerprint='' } }
  $status = Test-SuperBrainCausalReviewBinding -Review $Review -ReviewPath ([string]$Review.path) -TaskId $TaskId -Contract $EvidenceInfo.contract -EvidenceBinding $EvidenceInfo.binding -TaskStateProjection (Get-TaskStateProjection $TaskId) -Root $Root
  $decision = if($Review.PSObject.Properties['expectedVsActual'] -and $Review.expectedVsActual){[string]$Review.expectedVsActual.decision}else{''}
  if($status.ok -eq $true -and $decision -ne 'keep'){
    return [pscustomobject]@{ required=$true; ok=$false; code='CAUSAL_REVIEW_DECISION_NOT_KEEP'; reason='causal_review_requires_revision_or_rollback'; decision=$decision; reviewId=[string]$Review.reviewId; reviewPath=[string]$Review.path; reviewArtifactHash=[string]$status.reviewArtifactHash; reviewFingerprint=[string]$status.reviewFingerprint }
  }
  return [pscustomobject]@{ required=$true; ok=[bool]$status.ok; code=[string]$status.code; reason=[string]$status.reason; decision=$decision; reviewId=[string]$Review.reviewId; reviewPath=[string]$Review.path; reviewArtifactHash=[string]$status.reviewArtifactHash; reviewFingerprint=[string]$status.reviewFingerprint }
}

function Get-TaskDecisionBinding([string]$Id,[string]$Key) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return [pscustomobject]@{ required=$false; ok=$true; status='not_required'; code='TASK_DECISION_BINDING_NOT_REQUIRED'; contract=$null; receipt=$null } }
  try {
    $contractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') -Action Get -TaskId $Id -WorkspaceKey $Key -NoExit -Json 2>&1)
    $contract = ConvertFrom-SuperBrainJsonOutput ($contractRaw -join "`n") 'task verification decision contract'
    if (-not $contract -or $contract.ok -ne $true -or [string]$contract.taskId -ne $Id -or [string]$contract.status -ne 'active') { return [pscustomobject]@{ required=$true; ok=$false; status='withheld'; code='TASK_DECISION_BINDING_CONTRACT_UNAVAILABLE'; contract=$null; receipt=$null } }
    $stageKind = if ($contract.PSObject.Properties['stageKind']) { [string]$contract.stageKind } else { '' }
    if ([string]::IsNullOrWhiteSpace($stageKind)) { return [pscustomobject]@{ required=$false; ok=$true; status='not_required'; code='TASK_DECISION_BINDING_NOT_REQUIRED'; contract=$contract; receipt=$null } }
    if (-not $contract.PSObject.Properties['decisionBinding'] -or -not $contract.decisionBinding) { return [pscustomobject]@{ required=$true; ok=$false; status='withheld'; code='TASK_DECISION_BINDING_RECEIPT_MISSING'; contract=$contract; receipt=$null } }
    $bindingScript = Join-Path $PSScriptRoot 'decision-binding.ps1'
    $memoryBase = Split-Path -Parent $workspace
    $intentFingerprint = if ($contract.PSObject.Properties['decisionIntentFingerprint']) { [string]$contract.decisionIntentFingerprint } else { '' }
    $raw = @(& $bindingScript -Action ValidateReceipt -TaskId $Id -TaskInstanceId ([string]$contract.taskInstanceId) -WorkspaceKey $Key -WorklineId ([string]$contract.focusId) -StageKind $stageKind -IntentFingerprint $intentFingerprint -ContractRevision ([int]$contract.revision) -PlanFingerprint ([string]$contract.planReceipt.planFingerprint) -OwnerSessionKey ([string]$contract.ownerSessionKey) -ReceiptPath ([string]$contract.decisionBinding.path) -StateRoot $memoryBase -NoExit -Json 2>&1)
    $receipt = ConvertFrom-SuperBrainJsonOutput ($raw -join "`n") 'task verification decision receipt'
    if (-not $receipt -or $receipt.ok -ne $true -or [string]$receipt.bindingDigest -ne [string]$contract.decisionBinding.bindingDigest) { return [pscustomobject]@{ required=$true; ok=$false; status='withheld'; code='TASK_DECISION_BINDING_RECEIPT_STALE'; contract=$contract; receipt=$receipt } }
    return [pscustomobject]@{ required=$true; ok=$true; status=[string]$receipt.status; code='TASK_DECISION_BINDING_RECEIPT_CURRENT'; contract=$contract; receipt=$receipt }
  } catch {
    return [pscustomobject]@{ required=$true; ok=$false; status='withheld'; code='TASK_DECISION_BINDING_LOOKUP_FAILED'; contract=$null; receipt=$null }
  }
}

function Get-TaskIntentBinding([string]$Id,[string]$Key) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return [pscustomobject]@{ required=$false; ok=$true; current=$true; code='EXECUTION_CONTRACT_INTENT_RECEIPT_NOT_REQUIRED'; contract=$null; receipt=$null } }
  try {
    $contractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') -Action Get -TaskId $Id -WorkspaceKey $Key -NoExit -Json 2>&1)
    $contract = ConvertFrom-SuperBrainJsonOutput ($contractRaw -join "`n") 'task verification intent contract'
    if (-not $contract -or $contract.ok -ne $true -or [string]$contract.taskId -ne $Id -or [string]$contract.status -ne 'active') { return [pscustomobject]@{ required=$true; ok=$false; current=$false; code='TASK_INTENT_CONTRACT_UNAVAILABLE'; contract=$null; receipt=$null } }
    $required = ($contract.PSObject.Properties['intentContractRequired'] -and $contract.intentContractRequired -eq $true)
    if (-not $required) { return [pscustomobject]@{ required=$false; ok=$true; current=$true; code='EXECUTION_CONTRACT_INTENT_RECEIPT_NOT_REQUIRED'; contract=$contract; receipt=$null } }
    $raw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') -Action ValidateIntentReceipt -TaskId $Id -WorkspaceKey $Key -ReceiptContractPath ([string]$contract.path) -NoExit -Json 2>&1)
    $receipt = ConvertFrom-SuperBrainJsonOutput ($raw -join "`n") 'task verification intent receipt'
    if (-not $receipt -or $receipt.ok -ne $true -or $receipt.current -ne $true) { return [pscustomobject]@{ required=$true; ok=$false; current=$false; code=if($receipt){[string]$receipt.code}else{'TASK_INTENT_RECEIPT_VALIDATION_FAILED'}; contract=$contract; receipt=$receipt } }
    return [pscustomobject]@{ required=$true; ok=$true; current=$true; code='EXECUTION_CONTRACT_INTENT_RECEIPT_CURRENT'; contract=$contract; receipt=$receipt }
  } catch {
    return [pscustomobject]@{ required=$true; ok=$false; current=$false; code='TASK_INTENT_RECEIPT_LOOKUP_FAILED'; contract=$null; receipt=$null }
  }
}

function ConvertTo-TaskDecisionResultEntries([string]$Raw,[object]$Receipt) {
  if ([string]::IsNullOrWhiteSpace($Raw)) { return [pscustomobject]@{ ok=$false; code='TASK_DECISION_RESULTS_REQUIRED'; entries=@() } }
  try { $parsed = $Raw | ConvertFrom-Json } catch { return [pscustomobject]@{ ok=$false; code='TASK_DECISION_RESULTS_JSON_INVALID'; entries=@() } }
  $items = if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) { @($parsed) } elseif ($parsed.PSObject.Properties['results']) { @($parsed.results) } else { @($parsed) }
  $expected = @($Receipt.decisions | Where-Object { [string]$_.enforcement -eq 'completion_gate' })
  if ($items.Count -ne $expected.Count) { return [pscustomobject]@{ ok=$false; code='TASK_DECISION_RESULTS_COUNT_MISMATCH'; entries=@() } }
  $entries = @()
  foreach ($decision in $expected) {
    $match = @($items | Where-Object { [string]$_.decisionId -eq [string]$decision.decisionId -and [int]$_.revision -eq [int]$decision.revision } | Select-Object -First 1)
    if ($match.Count -ne 1) { return [pscustomobject]@{ ok=$false; code='TASK_DECISION_RESULT_IDENTITY_MISMATCH'; entries=@() } }
    $item = $match[0]
    if ($item.PSObject.Properties['bindingDigest'] -and [string]$item.bindingDigest -ne [string]$Receipt.bindingDigest) { return [pscustomobject]@{ ok=$false; code='TASK_DECISION_RESULT_BINDING_MISMATCH'; entries=@() } }
    if (-not $item.PSObject.Properties['ok']) { return [pscustomobject]@{ ok=$false; code='TASK_DECISION_RESULT_OK_REQUIRED'; entries=@() } }
    $entries += [pscustomobject]@{ decisionId=[string]$decision.decisionId; revision=[int]$decision.revision; ok=[bool]$item.ok; evidenceRefs=@(if($item.PSObject.Properties['evidenceRefs']){@($item.evidenceRefs | ForEach-Object {[string]$_} | Select-Object -Unique -First 12)}else{@()}) }
  }
  return [pscustomobject]@{ ok=$true; code='TASK_DECISION_RESULTS_PARSED'; entries=@($entries) }
}

function Complete-TaskDecisionBinding([object]$Binding) {
  if (-not $Binding.required) { return [pscustomobject]@{ required=$false; ok=$true; status='not_required'; code='TASK_DECISION_BINDING_NOT_REQUIRED'; stageKind=''; bindingDigest=''; results=@() } }
  if (-not $Binding.ok -or -not $Binding.receipt -or [string]$Binding.status -eq 'withheld') { return [pscustomobject]@{ required=$true; ok=$false; status='withheld'; code=[string]$Binding.code; stageKind=if($Binding.contract){[string]$Binding.contract.stageKind}else{''}; bindingDigest=''; results=@() } }
  if ([string]$Binding.status -eq 'none_applicable') { return [pscustomobject]@{ required=$true; ok=$true; status='none_applicable'; code='TASK_DECISION_BINDING_NONE_APPLICABLE'; stageKind=[string]$Binding.contract.stageKind; bindingDigest=[string]$Binding.receipt.bindingDigest; results=@() } }
  $entries = ConvertTo-TaskDecisionResultEntries $DecisionResultJson $Binding.receipt
  if (-not $entries.ok) { return [pscustomobject]@{ required=$true; ok=$false; status='withheld'; code=[string]$entries.code; stageKind=[string]$Binding.contract.stageKind; bindingDigest=[string]$Binding.receipt.bindingDigest; results=@() } }
  $contract = $Binding.contract
  $bindingScript = Join-Path $PSScriptRoot 'decision-binding.ps1'
  $memoryBase = Split-Path -Parent $workspace
  $resultRefs = @()
  foreach ($entry in @($entries.entries)) {
    $recordArgs = @{
      Action='RecordResult'; TaskId=$TaskId; TaskInstanceId=[string]$contract.taskInstanceId; WorkspaceKey=$workspaceKeyValue; WorklineId=[string]$contract.focusId; StageKind=[string]$contract.stageKind; IntentFingerprint=[string]$contract.decisionIntentFingerprint; ContractRevision=[int]$contract.revision; PlanFingerprint=[string]$contract.planReceipt.planFingerprint; OwnerSessionKey=[string]$contract.ownerSessionKey; ReceiptPath=[string]$contract.decisionBinding.path; BindingDigest=[string]$Binding.receipt.bindingDigest; DecisionId=[string]$entry.decisionId; Revision=[int]$entry.revision; EvidenceRefs=@($entry.evidenceRefs); StateRoot=$memoryBase; NoExit=$true; Json=$true
    }
    if ($entry.ok) { $recordArgs.ResultOk = $true }
    $raw = @(& $bindingScript @recordArgs 2>&1)
    $record = ConvertFrom-SuperBrainJsonOutput ($raw -join "`n") 'task verification decision result'
    if (-not $record -or $record.ok -ne $true) { return [pscustomobject]@{ required=$true; ok=$false; status='withheld'; code='TASK_DECISION_RESULT_RECORD_FAILED'; stageKind=[string]$Binding.contract.stageKind; bindingDigest=[string]$Binding.receipt.bindingDigest; results=@($resultRefs) } }
    $resultRefs += [pscustomobject]@{ decisionId=[string]$record.decisionId; revision=[int]$record.revision; resultPath=[string]$record.resultPath; resultHash=[string]$record.resultHash }
  }
  $validationRaw = @(& $bindingScript -Action ValidateCompletion -TaskId $TaskId -TaskInstanceId ([string]$contract.taskInstanceId) -WorkspaceKey $workspaceKeyValue -WorklineId ([string]$contract.focusId) -StageKind ([string]$contract.stageKind) -IntentFingerprint ([string]$contract.decisionIntentFingerprint) -ContractRevision ([int]$contract.revision) -PlanFingerprint ([string]$contract.planReceipt.planFingerprint) -OwnerSessionKey ([string]$contract.ownerSessionKey) -ReceiptPath ([string]$contract.decisionBinding.path) -StateRoot $memoryBase -NoExit -Json 2>&1)
  $validation = ConvertFrom-SuperBrainJsonOutput ($validationRaw -join "`n") 'task verification decision completion'
  return [pscustomobject]@{ required=$true; ok=($validation.ok -eq $true); status=[string]$validation.status; code=[string]$validation.code; stageKind=[string]$Binding.contract.stageKind; bindingDigest=[string]$Binding.receipt.bindingDigest; results=@($validation.results); rawDecisionBodyStored=$false }
}
function Get-CompletedTaskEvidenceBinding([string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return [pscustomobject]@{ binding=$null; ownerSessionKey=''; status='missing_task_id' } }
  $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $Id '.json'
  $projection = Read-JsonFile $projectionPath
  if (-not $projection -or [string]$projection.taskId -ne $Id -or -not $projection.lifecycle -or [string]$projection.lifecycle.status -ne 'completed') { return [pscustomobject]@{ binding=$null; ownerSessionKey=''; status='terminal_projection_missing' } }
  if (-not $projection.lifecycle.PSObject.Properties['evidenceBinding'] -or -not $projection.lifecycle.evidenceBinding) { return [pscustomobject]@{ binding=$null; ownerSessionKey=[string]$projection.lifecycle.ownerSessionKey; status='historical_evidence_binding_missing' } }
  return [pscustomobject]@{ binding=$projection.lifecycle.evidenceBinding; ownerSessionKey=[string]$projection.lifecycle.ownerSessionKey; status='bound' }
}
function Write-LearningVerificationReceipt($Verification,$CompletedCheckpoint) {
  $taskIdValue = [string]$Verification.taskId
  $safe = Safe-TaskId $taskIdValue
  if ([string]::IsNullOrWhiteSpace($safe)) { return [pscustomobject]@{ ok=$false; reason='task_id_missing'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false } }
  $checkpointVerified = ($CompletedCheckpoint -and [string]$CompletedCheckpoint.taskId -eq $taskIdValue -and [string]$CompletedCheckpoint.status -eq 'completed' -and [string]$CompletedCheckpoint.source -eq 'task-verification.ps1')
  $completedEvidence = Get-CompletedTaskEvidenceBinding $taskIdValue
  $artifactPath = if ($Verification.PSObject.Properties['verificationEvidencePath']) { [string]$Verification.verificationEvidencePath } else { '' }
  $artifactHash = Get-FileSha256 $artifactPath
  $bindingCheck = if($completedEvidence.binding){Test-SuperBrainEvidenceBinding -Binding $completedEvidence.binding -TaskId $taskIdValue -WorkspaceKey ([string]$Verification.workspaceKey) -OwnerSessionKey ([string]$completedEvidence.ownerSessionKey) -ArtifactPath $artifactPath -RequireArtifactHash -Root $Root}else{[pscustomobject]@{ok=$false;reason=[string]$completedEvidence.status}}
  if ($Verification.ok -ne $true -or $Verification.taskScopedGuardOk -ne $true -or -not $checkpointVerified -or -not $bindingCheck.ok -or [string]$artifactHash -notmatch '^[a-f0-9]{64}$') {
    return [pscustomobject]@{ ok=$false; reason='verification_receipt_preconditions_failed'; bindingStatus=[string]$bindingCheck.reason; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
  }
  $transactionId = if($CompletedCheckpoint.PSObject.Properties['completionTransactionId']){[string]$CompletedCheckpoint.completionTransactionId}else{''}
  $receiptId = 'receipt-' + $safe + '-' + $artifactHash.Substring(0,16)
  $receiptPath = Get-SuperBrainCanonicalTaskPath $learningReceiptRoot $taskIdValue '.json'
  $existing = Read-JsonFile $receiptPath
  if ($existing) {
    $same = ([string]$existing.schema -eq 'super-brain.learning-verification-receipt.v1' -and [string]$existing.receiptId -eq $receiptId -and [string]$existing.taskId -eq $taskIdValue -and [string]$existing.verificationArtifactHash -eq $artifactHash)
    if (-not $same) { return [pscustomobject]@{ ok=$false; reason='verification_receipt_conflict'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false } }
    return [pscustomobject]@{ ok=$true; reused=$true; receiptId=$receiptId; path=$receiptPath; sha256=(Get-FileSha256 $receiptPath); evidenceRef=('receipt:' + (Get-FileSha256 $receiptPath)); rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
  }
  $receipt = [pscustomobject]@{
    schema = 'super-brain.learning-verification-receipt.v1'
    receiptId = $receiptId
    taskId = $taskIdValue
    workspaceKey = [string]$Verification.workspaceKey
    ownerSessionKey = [string]$completedEvidence.ownerSessionKey
    packageVersion = [string](Get-SuperBrainManifest $Root).version
    createdAt = (Get-Date).ToString('o')
    completionTransactionId = $transactionId
    verificationArtifactHash = $artifactHash
    evidenceBinding = ($completedEvidence.binding | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    checks = [pscustomobject]@{ taskVerification=$true; taskScopedGuard=$true; completedCheckpoint=$true; evidenceBindingCurrent=$true }
    privacy = [pscustomobject]@{ rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
  }
  Write-JsonUtf8NoBom $receiptPath $receipt 12
  $receiptHash = Get-FileSha256 $receiptPath
  return [pscustomobject]@{ ok=([string]$receiptHash -match '^[a-f0-9]{64}$'); reused=$false; receiptId=$receiptId; path=$receiptPath; sha256=$receiptHash; evidenceRef=('receipt:' + $receiptHash); rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
}
function Record-LearningCandidateReceipt([string]$CandidateId,$Receipt) {
  if ([string]::IsNullOrWhiteSpace($CandidateId)) { return [pscustomobject]@{ requested=$false; ok=$null; reason='not_requested'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false } }
  if (-not $Receipt -or $Receipt.ok -ne $true) { return [pscustomobject]@{ requested=$true; ok=$false; reason='verification_receipt_unavailable'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false } }
  try {
    $raw = @(& (Join-Path $PSScriptRoot 'self-improvement-queue.ps1') -Action RecordVerification -CandidateId $CandidateId -VerificationId ([string]$Receipt.receiptId) -VerificationOutcome pass -VerificationEvidenceRef ([string]$Receipt.evidenceRef) -VerificationTaskId $TaskId -VerificationWorkspaceKey $workspaceKeyValue -VerificationReceiptPath ([string]$Receipt.path) -Json 2>&1)
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ requested=$true; ok=$false; reason='queue_record_failed'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false } }
    $result = $text | ConvertFrom-Json
    if ($result.ok -ne $true -or [int]$result.verificationRecorded -ne 1) { return [pscustomobject]@{ requested=$true; ok=$false; reason='queue_record_rejected'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false } }
    return [pscustomobject]@{ requested=$true; ok=$true; candidateId=$CandidateId; receiptId=[string]$Receipt.receiptId; receiptHash=[string]$Receipt.sha256; autoResolved=([int]$result.autoResolved -eq 1); rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
  } catch {
    return [pscustomobject]@{ requested=$true; ok=$false; reason='queue_record_exception'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
  }
}
function Write-VerifiedTaskOutcome($Verification,$CompletedCheckpoint,$Authorization,$CorrectionReference) {
  $taskIdValue = [string]$Verification.taskId
  $safe = Safe-TaskId $taskIdValue
  if ([string]::IsNullOrWhiteSpace($safe)) { return [pscustomobject]@{ written=$false; reason='task_id_missing'; rawPromptStored=$false; rawSummaryStored=$false } }
  $checkpointVerified = ($CompletedCheckpoint -and [string]$CompletedCheckpoint.taskId -eq $taskIdValue -and [string]$CompletedCheckpoint.status -eq 'completed' -and [string]$CompletedCheckpoint.source -eq 'task-verification.ps1')
  $realUserPathVerified = ($Verification.userAcceptanceVerification -and $Verification.userAcceptanceVerification.ok -eq $true -and $Verification.userAcceptanceVerification.realUserPathVerification -eq $true)
  $completedEvidence = Get-CompletedTaskEvidenceBinding $taskIdValue
  $verificationArtifactPath = if ($Verification.PSObject.Properties['verificationEvidencePath']) { [string]$Verification.verificationEvidencePath } else { '' }
  $evidenceBindingCheck = if($completedEvidence.binding){Test-SuperBrainEvidenceBinding -Binding $completedEvidence.binding -TaskId $taskIdValue -WorkspaceKey ([string]$Verification.workspaceKey) -OwnerSessionKey ([string]$completedEvidence.ownerSessionKey) -ArtifactPath $verificationArtifactPath -RequireArtifactHash -Root $Root}else{[pscustomobject]@{ok=$false;reason=[string]$completedEvidence.status}}
  $verificationOk = ($Verification.ok -eq $true -and $Verification.taskScopedGuardOk -eq $true -and $realUserPathVerified -and $checkpointVerified -and $evidenceBindingCheck.ok)
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
      evidenceBindingCurrent = [bool]$evidenceBindingCheck.ok
      packageVerificationOk = [bool]($Verification.lastVerify -and $Verification.lastVerify.ok -eq $true)
      hotRefreshOk = [bool]($Verification.lastHotRefresh -and $Verification.lastHotRefresh.ok -eq $true)
    }
    classification = [pscustomobject]@{
      verifiedRealWorldTask = [bool]$verificationOk
      verifiedAutonomyScenario = [bool]$autonomyVerified
    }
    authorization = if($Authorization.valid){[pscustomobject]@{recordId=[string]$Authorization.record.recordId;sha256=[string]$Authorization.sha256;source=[string]$Authorization.record.source;autonomyTier=[string]$Authorization.record.autonomyTier}}else{$null}
    correctionCandidateId = if($CorrectionReference.valid){[string]$CorrectionReference.candidateId}else{''}
    evidenceBinding = if($completedEvidence.binding){$completedEvidence.binding | ConvertTo-Json -Depth 6 | ConvertFrom-Json}else{$null}
    evidenceRefs = @('task-verification.ps1','completed-checkpoint','last-verify-package.json','last-hot-refresh.json','integration-parity-check')
    privacy = [pscustomobject]@{ rawPromptStored=$false; rawSummaryStored=$false }
  }
  Write-JsonUtf8NoBom $path $record 12
  return [pscustomobject]@{ written=$true; recordId=$record.recordId; taskId=$taskIdValue; sha256=(Get-FileSha256 $path); qualifiesRealWorldTask=$record.classification.verifiedRealWorldTask; qualifiesAutonomyScenario=$record.classification.verifiedAutonomyScenario; correctionCandidateId=$record.correctionCandidateId; evidenceBindingStatus=[string]$evidenceBindingCheck.reason; path=$path; rawPromptStored=$false; rawSummaryStored=$false }
}

function Get-VerifiedReviewProtocolMeasurement([string]$Measurement,$Contract) {
  return Get-UserAdaptationVerifiedReviewProtocolMeasurement $Measurement $Contract
}

function Get-VerifiedReviewProtocolFromReceipt($Protocol,$Contract) {
  if(-not$Protocol){return [pscustomobject]@{ok=$false;reason='confirmation_protocol_missing';value=''}}
  if(-not$Contract-or-not$Contract.canonicalPlan){return [pscustomobject]@{ok=$false;reason='verified_canonical_plan_required';value=''}}
  $risk=([string]$Protocol.riskFloor).ToLowerInvariant()
  if($risk-notin@('workflow','structural')){return [pscustomobject]@{ok=$false;reason='confirmation_risk_floor_missing';value=''}}
  $value="review_protocol=multi_pass;forwardPasses=$([int]$Protocol.forwardPasses);reversePasses=$([int]$Protocol.reversePasses);riskFloor=$risk"
  if($Protocol.PSObject.Properties['contexts']){$value+=';contexts='+(@($Protocol.contexts|Sort-Object -Unique)-join',')}
  return Get-VerifiedReviewProtocolMeasurement $value $Contract
}

function Test-ExactNormalizedSet([string[]]$Expected,[string[]]$Actual) {
  $left=@($Expected|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
  $right=@($Actual|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
  return (($left|ConvertTo-Json -Compress)-eq($right|ConvertTo-Json -Compress))
}

function Write-UserAdaptationVerificationArtifact($Verification,$Outcome,[string[]]$Signals,[string[]]$Measurements,[string]$Source,[string]$Context,[string]$WorkflowKey,[string]$CorrectionId,[string]$CorrectionTargetId,$ConfirmationReceipt) {
  if(-not$Outcome-or$Outcome.written-ne$true-or$Outcome.qualifiesRealWorldTask-ne$true-or[string]$Outcome.sha256-notmatch'^[a-f0-9]{64}$'-or-not(Test-SuperBrainChildPath (Join-Path $workspace 'runtime-state\verified-task-outcomes') ([string]$Outcome.path))){throw 'USER_ADAPTATION_VERIFIED_OUTCOME_REQUIRED'}
  if((Get-FileSha256 ([string]$Outcome.path))-ne[string]$Outcome.sha256){throw 'USER_ADAPTATION_VERIFIED_OUTCOME_MISMATCH'}
  $outcomeSnapshot=Join-Path $adaptationOutcomeRoot ((Get-SuperBrainCanonicalTaskToken ([string]$Verification.taskId))+'--'+[string]$Outcome.sha256+'.json')
  $outcomePublication=Publish-SuperBrainImmutableFile -SourcePath ([string]$Outcome.path) -DestinationPath $outcomeSnapshot -ExpectedSha256 ([string]$Outcome.sha256) -CollisionCode 'USER_ADAPTATION_OUTCOME_SNAPSHOT_COLLISION' -SourceMismatchCode 'USER_ADAPTATION_VERIFIED_OUTCOME_MISMATCH'
  $outcomeRelative=$outcomeSnapshot.Substring($workspace.Length).TrimStart('\','/')-replace'\\','/'
  $request=[pscustomobject]@{source=$Source;context=$Context;workflowKey=$WorkflowKey.ToLowerInvariant();signals=@($Signals|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique);measurements=@($Measurements|ForEach-Object{(([string]$_).Trim()-replace'\s+','').ToLowerInvariant()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique);correctionCandidateId=$CorrectionId.ToLowerInvariant();correctionTargetPreferenceId=$CorrectionTargetId;rawPromptStored=$false}
  $record=[pscustomobject]@{
    schema='super-brain.user-adaptation-verification.v2';source='task-verification.ps1';packageVersion=[string](Get-SuperBrainManifest $Root).version;checkedAt=(Get-Date).ToString('o');taskId=[string]$Verification.taskId;workspaceKey=[string]$Verification.workspaceKey;eligibleForAdaptation=$true
    verification=[pscustomobject]@{ok=[bool]($Verification.ok-eq$true);taskScopedGuardOk=[bool]($Verification.taskScopedGuardOk-eq$true);realUserPathVerified=[bool]($Verification.userAcceptanceVerification-and$Verification.userAcceptanceVerification.ok-eq$true-and$Verification.userAcceptanceVerification.realUserPathVerification-eq$true)}
    completion=[pscustomobject]@{completed=[bool]($Verification.completionOutcome.completed-eq$true);transactionId=[string]$Verification.completionOutcome.transactionId;taskStateRevision=[int]$Verification.completionOutcome.taskStateRevision}
    verifiedOutcome=[pscustomobject]@{recordId=[string]$Outcome.recordId;relativePath=$outcomeRelative;sha256=[string]$Outcome.sha256}
    confirmationReceipt=if($ConfirmationReceipt){[pscustomobject]@{relativePath=[string]$ConfirmationReceipt.recordRelativePath;sha256=[string]$ConfirmationReceipt.sha256;selectionHash=[string]$ConfirmationReceipt.selectionHash}}else{$null}
    request=$request;requestHash=Get-SuperBrainStableHash ($request|ConvertTo-Json -Depth 8 -Compress) 64;rawPromptStored=$false;rawSummaryStored=$false
  }
  $pending=Join-Path $adaptationVerificationRoot ('.pending-'+[guid]::NewGuid().ToString('n')+'.json')
  Write-JsonUtf8NoBom $pending $record 12
  $hash=Get-FileSha256 $pending
  if($hash-notmatch'^[a-f0-9]{64}$'){throw 'USER_ADAPTATION_VERIFICATION_HASH_FAILED'}
  $final=Join-Path $adaptationVerificationRoot ((Get-SuperBrainCanonicalTaskToken ([string]$Verification.taskId))+'--'+$hash+'.json')
  try{$artifactPublication=Publish-SuperBrainImmutableFile -SourcePath $pending -DestinationPath $final -ExpectedSha256 $hash -CollisionCode 'USER_ADAPTATION_VERIFICATION_COLLISION' -SourceMismatchCode 'USER_ADAPTATION_VERIFICATION_HASH_FAILED'}finally{if(Test-Path -LiteralPath $pending){Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue}}
  return [pscustomobject]@{ok=$true;path=$final;sha256=$hash;requestHash=[string]$record.requestHash;artifactReplayed=[bool]$artifactPublication.replayed;outcomeReplayed=[bool]$outcomePublication.replayed;rawPromptStored=$false;rawSummaryStored=$false}
}

function Write-DeferredCorrectionAdaptationRequest($Artifact,[string[]]$Signals,[string]$Context,[string]$WorkflowKey,[string]$CandidateId,[string]$TargetPreferenceId) {
  $candidate=$CandidateId.ToLowerInvariant()
  if($candidate-notmatch'^correction-[a-z0-9_-]{1,100}$'-or[string]::IsNullOrWhiteSpace($TargetPreferenceId)-or@($Signals).Count-ne1){throw 'USER_ADAPTATION_CORRECTION_REQUEST_INVALID'}
  $root=Join-Path $workspace 'runtime-state\user-adaptation-correction-requests'
  if(-not(Test-Path -LiteralPath $root)){New-Item -ItemType Directory -Force -Path $root|Out-Null}
  $artifactRelative=([string]$Artifact.path).Substring($workspace.Length).TrimStart('\','/')-replace'\\','/'
  $semanticPayload=[ordered]@{candidateId=$candidate;taskId=$TaskId;workspaceKey=$workspaceKeyValue;context=$Context;workflowKey=$WorkflowKey.ToLowerInvariant();signals=@($Signals|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Sort-Object -Unique);targetPreferenceId=$TargetPreferenceId}
  $semanticHash=Get-SuperBrainStableHash ($semanticPayload|ConvertTo-Json -Depth 8 -Compress) 64
  $request=[pscustomobject]@{schema='super-brain.user-adaptation-correction-request.v1';candidateId=$candidate;taskId=$TaskId;workspaceKey=$workspaceKeyValue;context=$Context;workflowKey=$WorkflowKey.ToLowerInvariant();signals=@($semanticPayload.signals);targetPreferenceId=$TargetPreferenceId;verificationArtifactRelativePath=$artifactRelative;verificationHash=[string]$Artifact.sha256;status='pending_correction_close';createdAt=(Get-Date).ToString('o');requestHash=$semanticHash;rawPromptStored=$false;rawSummaryStored=$false}
  $path=Join-Path $root ($candidate+'.json')
  if(Test-Path -LiteralPath $path){$existing=Read-JsonFile $path;if(-not$existing-or[string]$existing.requestHash-ne$semanticHash){throw 'USER_ADAPTATION_CORRECTION_REQUEST_CONFLICT'};return [pscustomobject]@{ok=$true;replayed=$true;path=$path;requestHash=$semanticHash;verificationHash=[string]$existing.verificationHash;rawPromptStored=$false}}
  Write-JsonUtf8NoBom $path $request 10
  return [pscustomobject]@{ok=$true;replayed=$false;path=$path;requestHash=$semanticHash;verificationHash=[string]$request.verificationHash;rawPromptStored=$false}
}

$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$constraintPreflight = Read-WorkspaceJson 'last-accepted-constraints-preflight.json'
$legacyTaskGraph = Read-WorkspaceJson 'task-graph.json'
$taskGraph = if (Test-ExactTaskWorkspaceEvidence $legacyTaskGraph) { $legacyTaskGraph } else { $null }
$stepLedgerSelection = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Get-SuperBrainRelevantStepLedger $workspace $TaskId $workspaceKeyValue -AllowLegacyRead } else { $null }
$stepLedger = if ($stepLedgerSelection) { $stepLedgerSelection.ledger } else { $null }
$legacyProjectContinuity = Read-WorkspaceJson 'last-project-continuity.json'
$projectContinuity = if (Test-ExactTaskWorkspaceEvidence $legacyProjectContinuity) { $legacyProjectContinuity } else { $null }
$impact = Read-WorkspaceJson 'last-impact-advisor.json'
$teamTask = $null
if ($TeamTaskId) { $teamPath = Join-Path (Join-Path $workspace 'team-tasks') "$TeamTaskId.json"; if (Test-Path $teamPath) { try { $teamTask = Get-Content -LiteralPath $teamPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $teamTask = $null } } }
$lastDoctor = $null; $doctorRiskSummary = $null; $doctorRisks = @()
try { $doctorJson = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json; if ($LASTEXITCODE -eq 0) { $lastDoctor = $doctorJson | ConvertFrom-Json; $doctorRiskSummary = $lastDoctor.riskSummary; $doctorRisks = @($lastDoctor.risks) } } catch {}
$constraintConflicts = if ($constraintPreflight) { @($constraintPreflight.conflicts) } else { @() }
$constraintsPreserved = (-not $constraintPreflight) -or ($constraintPreflight.ok -eq $true -and $constraintConflicts.Count -eq 0)
$scopedCheckpoint = $null
if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
  try { $scopedCheckpoint = & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Get -TaskId $TaskId -WorkspaceKey $workspaceKeyValue -Json | ConvertFrom-Json } catch {}
}
$matchingCheckpoint = $scopedCheckpoint -and [string]$scopedCheckpoint.taskId -eq $TaskId
$legacyContinuityTaskMatch = ([string]::IsNullOrWhiteSpace($TaskId) -or ($taskGraph -and $stepLedger -and [string]$taskGraph.taskId -eq $TaskId -and [string]$stepLedger.taskId -eq $TaskId))
$continuityTaskMatch = ($matchingCheckpoint -or $legacyContinuityTaskMatch)
$openSteps = if($matchingCheckpoint){@($scopedCheckpoint.pendingSteps)}elseif($stepLedger){@($stepLedger.openSteps)}else{@()}
$continuitySummary = [pscustomobject]@{ source=if($matchingCheckpoint){'scoped_checkpoint'}elseif($legacyContinuityTaskMatch){'legacy_task_graph'}else{'none'}; taskId=if($matchingCheckpoint){$scopedCheckpoint.taskId}elseif($taskGraph){$taskGraph.taskId}else{''}; taskStatus=if($matchingCheckpoint){$scopedCheckpoint.status}elseif($taskGraph){$taskGraph.status}else{''}; taskScoped=$continuityTaskMatch; goal=if($matchingCheckpoint){$scopedCheckpoint.goal}elseif($taskGraph){$taskGraph.goal}else{''}; openStepCount=@($openSteps).Count; completedCount=if($matchingCheckpoint){@($scopedCheckpoint.completedSteps).Count}elseif($stepLedger){@($stepLedger.completedSteps).Count}else{0}; skippedCount=if($stepLedger){@($stepLedger.skippedSteps).Count}else{0}; candidateFindings=if($projectContinuity -and $projectContinuity.findingCounts){[int]$projectContinuity.findingCounts.candidate}else{0}; nextAction=if($matchingCheckpoint){$scopedCheckpoint.nextAction}elseif($projectContinuity){$projectContinuity.nextAction}else{''} }
$impactSummary = [pscustomobject]@{ riskLevel=if($impact){$impact.riskLevel}else{''}; affectedScripts=if($impact){@(Limit-List @($impact.affectedScripts) 10)}else{@()}; recommendedChecks=if($impact){@(Limit-List @($impact.recommendedChecks) 10)}else{@()} }
$integrationParity = Read-TaskScopedJson 'integration-parity-check' 'last-integration-parity-check.json'
$causalReview = Read-TaskScopedJson 'change-causality-reviews' 'last-causal-change-review.json'
$contractReplay = Read-TaskScopedJson 'integration-contract-replay' 'last-integration-contract-replay.json'
$taskScopedGuardOk = (Test-TaskScopedEvidence $causalReview) -and (Test-TaskScopedEvidence $contractReplay) -and (Test-TaskScopedEvidence $integrationParity)
$taskEvidenceBinding = Get-TaskEvidenceBinding $TaskId $workspaceKeyValue
$causalReviewRequired = (-not [string]::IsNullOrWhiteSpace($TaskId) -and (@($Changed | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0 -or $null -ne $causalReview))
$causalReviewBinding = Get-CausalReviewBindingStatus $causalReview $causalReviewRequired $taskEvidenceBinding
$taskScopedGuardOk = ($taskScopedGuardOk -and $causalReviewBinding.ok)
$taskDecisionBinding = Get-TaskDecisionBinding $TaskId $workspaceKeyValue
$taskIntentBinding = Get-TaskIntentBinding $TaskId $workspaceKeyValue
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
  evidenceBinding = $taskEvidenceBinding.binding
  evidenceBindingStatus = [string]$taskEvidenceBinding.status
  causalReviewBinding = $causalReviewBinding
  decisionBinding = [pscustomobject]@{ required=[bool]$taskDecisionBinding.required; ok=$null; status=[string]$taskDecisionBinding.status; code=[string]$taskDecisionBinding.code; bindingDigest=if($taskDecisionBinding.receipt){[string]$taskDecisionBinding.receipt.bindingDigest}else{''}; results=@(); rawDecisionBodyStored=$false }
  intentFulfillment = [pscustomobject]@{ schema='super-brain.intent-fulfillment.v1'; required=[bool]$taskIntentBinding.required; ok=$null; code='TASK_INTENT_FULFILLMENT_NOT_EVALUATED'; items=@(); missing=@(); rawPromptStored=$false; rawTranscriptStored=$false }
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
  lastHotRefresh = if ($lastHotRefresh) { [pscustomobject]@{ ok=$lastHotRefresh.ok; checkedAt=$lastHotRefresh.checkedAt } } else { $null }
  adaptationObservation = [pscustomobject]@{ requested=((@($AdaptationSignals).Count+@($AdaptationMeasurements).Count)-gt0-or-not[string]::IsNullOrWhiteSpace($AdaptationConfirmationReceiptPath)); ok=$null; appliedCount=0; rawPromptStored=$false }
  autonomyEvidenceOutcome = [pscustomobject]@{ written=$false; reason='verification_not_yet_completed'; rawPromptStored=$false; rawSummaryStored=$false }
  learningVerification = [pscustomobject]@{ requested=(-not [string]::IsNullOrWhiteSpace($LearningCandidateId)); ok=$null; reason='not_evaluated'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
  completionOutcome = [pscustomobject]@{ attempted=$false; completed=$false; reason='not_evaluated'; transactionId=''; taskStateRevision=0 }
  typedMemoryTrial = [pscustomobject]@{ attempted=$false; ok=$true; status='not_requested'; verdict='inconclusive'; code='TYPED_MEMORY_TRIAL_NOT_COMPLETED'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false }
}
if ($causalReviewRequired -and $causalReviewBinding.ok -ne $true) {
  $verification.ok = $false
  $verification.risks = @($verification.risks + @('causal review is missing, stale, not bound to the current source tree, plan, and execution contract, or does not authorize decision=keep'))
}
$intentFulfillmentResult = if (-not $taskIntentBinding.required) {
  New-SuperBrainIntentFulfillment $taskIntentBinding.contract $null
} elseif (-not $taskIntentBinding.ok -or -not $taskIntentBinding.contract) {
  [pscustomobject]@{ ok=$false; required=$true; code=[string]$taskIntentBinding.code; record=[pscustomobject]@{ schema='super-brain.intent-fulfillment.v1'; required=$true; ok=$false; code=[string]$taskIntentBinding.code; items=@(); missing=@('current intent receipt'); fulfillmentFingerprint=''; rawPromptStored=$false; rawTranscriptStored=$false }; missing=@('current intent receipt') }
} else {
  New-SuperBrainIntentFulfillment $taskIntentBinding.contract $IntentFulfillmentJson
}
$verification.intentFulfillment = $intentFulfillmentResult.record
if ($verification.intentFulfillment) { $verification.intentFulfillment | Add-Member -NotePropertyName code -NotePropertyValue ([string]$intentFulfillmentResult.code) -Force }
if ($taskIntentBinding.required -and $intentFulfillmentResult.ok -ne $true) {
  $verification.ok = $false
  $verification.risks = @($verification.risks + @('intent fulfillment is missing, stale, or does not prove every product obligation'))
}
$decisionVerification = if ($verification.ok -eq $true) { Complete-TaskDecisionBinding $taskDecisionBinding } else { [pscustomobject]@{ required=[bool]$taskDecisionBinding.required; ok=if($taskDecisionBinding.required){$false}else{$true}; status=if($taskDecisionBinding.required){'withheld'}else{'not_required'}; code=if($taskDecisionBinding.required){'TASK_DECISION_BINDING_BASE_VERIFICATION_FAILED'}else{'TASK_DECISION_BINDING_NOT_REQUIRED'}; stageKind=if($taskDecisionBinding.contract){[string]$taskDecisionBinding.contract.stageKind}else{''}; bindingDigest=if($taskDecisionBinding.receipt){[string]$taskDecisionBinding.receipt.bindingDigest}else{''}; results=@(); rawDecisionBodyStored=$false } }
$verification.decisionBinding = $decisionVerification
if ($taskDecisionBinding.required -and $decisionVerification.ok -ne $true) {
  $verification.ok = $false
  $verification.risks = @($verification.risks + @('decision completion evidence is missing, stale, or unsatisfied'))
}
$completedBeforeWrite=if(-not[string]::IsNullOrWhiteSpace($TaskId)){Get-CompletedCheckpoint $TaskId}else{$null}
if($completedBeforeWrite-and[string]$completedBeforeWrite.taskId-eq$TaskId-and[string]$completedBeforeWrite.status-eq'completed'-and[string]$completedBeforeWrite.source-eq'task-verification.ps1'){
  $replayDiagnostic=Write-CompletedTaskReplayDiagnostic $verification $completedBeforeWrite
  if($Json){Get-Content -LiteralPath (Join-Path $workspace 'last-task-verification-replay.json') -Raw -Encoding UTF8}else{Write-Host "TASK_VERIFICATION_REPLAY_WITHHELD task=$TaskId canonicalPreserved=$($replayDiagnostic.canonicalVerification.preserved)"}
  exit 0
}
$verificationEvidencePath = if([string]::IsNullOrWhiteSpace($TaskId)){''}else{Get-SuperBrainCanonicalTaskPath $verificationRoot $TaskId '.json'}
if ($verificationEvidencePath) {
  $verification | Add-Member -NotePropertyName verificationEvidencePath -NotePropertyValue $verificationEvidencePath -Force
  Write-JsonUtf8NoBom $verificationEvidencePath $verification 12
}
Write-JsonUtf8NoBom $path $verification 10
$completionContract = $null
if ($verification.ok) {
  $completedCheckpoint = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { Get-CompletedCheckpoint $TaskId } else { $null }
  try {
    $activeCheckpoint = $scopedCheckpoint
    if (-not $activeCheckpoint -and -not [string]::IsNullOrWhiteSpace($TaskId)) { $activeCheckpoint = & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Get -TaskId $TaskId -WorkspaceKey $workspaceKeyValue -Json | ConvertFrom-Json }
    $matchingCheckpoint = $activeCheckpoint -and ([string]::IsNullOrWhiteSpace($TaskId) -or [string]$activeCheckpoint.taskId -eq $TaskId)
    $alreadyVerifiedCheckpoint = ($completedCheckpoint -and [string]$completedCheckpoint.taskId -eq $TaskId -and [string]$completedCheckpoint.status -eq 'completed' -and [string]$completedCheckpoint.source -eq 'task-verification.ps1')
    if ($alreadyVerifiedCheckpoint) {
      $verification.completionOutcome = [pscustomobject]@{ attempted=$false; completed=$true; reason='existing_verified_checkpoint'; transactionId=if($completedCheckpoint.PSObject.Properties['completionTransactionId']){[string]$completedCheckpoint.completionTransactionId}else{''}; taskStateRevision=if($completedCheckpoint.PSObject.Properties['taskStateRevision']){[int]$completedCheckpoint.taskStateRevision}else{0} }
    } elseif ($matchingCheckpoint -and (@($openSteps).Count -eq 0) -and (@($NextSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0)) {
      $contractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') -Action Get -TaskId $TaskId -WorkspaceKey $workspaceKeyValue -NoExit -Json 2>&1)
      $contract = ConvertFrom-SuperBrainJsonOutput ($contractRaw -join "`n") 'task verification execution contract'
      if (-not $contract -or $contract.ok -ne $true -or [string]$contract.status -ne 'active') { throw 'TASK_VERIFICATION_EXECUTION_CONTRACT_REQUIRED' }
      $completionContract = $contract
      $completionRaw = @(& (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Complete -TaskId ([string]$activeCheckpoint.taskId) -Source 'task-verification.ps1' -CurrentStep $Summary -NextAction '' -Evidence @($Evidence) -ExecutionContractPath ([string]$contract.path) -VerificationPath $verificationEvidencePath -ExpectedPlanFingerprint ([string]$contract.planReceipt.planFingerprint) -ExpectedContractRevision ([int]$contract.revision) -OwnerSessionKey ([string]$contract.ownerSessionKey) -CallerSessionKey (Get-SuperBrainLocalSessionKey) -Json 2>&1)
      if ($LASTEXITCODE -ne 0) { throw (($completionRaw | ForEach-Object { [string]$_ }) -join "`n") }
      $completionResult = ConvertFrom-SuperBrainJsonOutput ($completionRaw -join "`n") 'task completion transaction'
      $verification.completionOutcome = [pscustomobject]@{ attempted=$true; completed=$true; reason='atomic_completion_committed'; transactionId=[string]$completionResult.completionTransactionId; taskStateRevision=[int]$completionResult.taskStateRevision }
      $completedCheckpoint = Get-CompletedCheckpoint ([string]$activeCheckpoint.taskId)
    } elseif ($matchingCheckpoint) {
      $verification.completionOutcome = [pscustomobject]@{ attempted=$false; completed=$false; reason='pending_work_preserved'; openStepCount=@($openSteps).Count; nextStepCount=@($NextSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count; transactionId=''; taskStateRevision=0 }
    }
  } catch {
    $verification.ok = $false
    $verification.completionOutcome = [pscustomobject]@{ attempted=$true; completed=$false; reason='atomic_completion_failed'; error=Limit-List @($_.Exception.Message) 1; transactionId=''; taskStateRevision=0 }
  }
  try {
    $authorization = Get-AutonomyAuthorization ([string]$verification.taskId) $workspaceKeyValue
    $correctionReference = Get-CorrectionReference $CorrectionCandidateId $workspaceKeyValue
    $verification.autonomyEvidenceOutcome = Write-VerifiedTaskOutcome $verification $completedCheckpoint $authorization $correctionReference
  } catch {
    $verification.autonomyEvidenceOutcome = [pscustomobject]@{ written=$false; reason='outcome_record_write_failed'; rawPromptStored=$false; rawSummaryStored=$false }
  }
  if (((@($AdaptationSignals).Count + @($AdaptationMeasurements).Count) -gt 0 -or -not[string]::IsNullOrWhiteSpace($AdaptationConfirmationReceiptPath)) -and -not [string]::IsNullOrWhiteSpace($TaskId)) {
    try {
      if ($verification.ok -ne $true -or $verification.completionOutcome.completed -ne $true) { throw 'USER_ADAPTATION_COMPLETED_TASK_REQUIRED' }
      $effectiveSignals=@($AdaptationSignals);$verifiedMeasurements=@();$effectiveContext=$AdaptationContext;$effectiveWorkflowKey=$AdaptationWorkflowKey;$confirmationReceipt=$null
      if($AdaptationSource-eq'accepted_outcome'){
        if([string]::IsNullOrWhiteSpace($AdaptationConfirmationReceiptPath)-or$AdaptationConfirmationReceiptHash-notmatch'^[a-f0-9]{64}$'){throw 'USER_ADAPTATION_CONFIRMATION_RECEIPT_REQUIRED'}
        $confirmationReceipt=Get-UserAdaptationConfirmationReceipt -Root $Root -WorkspaceRoot $workspace -ReceiptPath $AdaptationConfirmationReceiptPath -ExpectedSha256 $AdaptationConfirmationReceiptHash -TaskId $TaskId -WorkspaceKey $workspaceKeyValue
        $confirmationBinding=Test-UserAdaptationConfirmationContractBinding $confirmationReceipt $completionContract
        if($confirmationBinding.ok-ne$true){throw ('USER_ADAPTATION_CONFIRMATION_CONTRACT_MISMATCH issues='+(@($confirmationBinding.issues)-join','))}
        $effectiveSignals=@($confirmationReceipt.signals|ForEach-Object{"$($_.habitKey)=$($_.value)"})
        if(@($AdaptationSignals).Count-gt0-and-not(Test-ExactNormalizedSet @($effectiveSignals) @($AdaptationSignals))){throw 'USER_ADAPTATION_CONFIRMATION_SIGNAL_MISMATCH'}
        $effectiveContext=[string]$confirmationReceipt.context
        if($AdaptationContext-ne'general'-and$AdaptationContext-ne$effectiveContext){throw 'USER_ADAPTATION_CONFIRMATION_CONTEXT_MISMATCH'}
        $effectiveWorkflowKey=[string]$confirmationReceipt.workflowKey
        if(-not[string]::IsNullOrWhiteSpace($AdaptationWorkflowKey)-and$AdaptationWorkflowKey.ToLowerInvariant()-ne$effectiveWorkflowKey){throw 'USER_ADAPTATION_CONFIRMATION_WORKFLOW_MISMATCH'}
        if($confirmationReceipt.protocolBinding){
          $measurementResult=Get-VerifiedReviewProtocolFromReceipt $confirmationReceipt.protocolBinding $completionContract
          if($measurementResult.ok-ne$true){throw ('USER_ADAPTATION_MEASUREMENT_UNVERIFIED reason='+[string]$measurementResult.reason)}
          $verifiedMeasurements=@([string]$measurementResult.value)
          if(@($AdaptationMeasurements).Count-gt0-and-not(Test-ExactNormalizedSet @($verifiedMeasurements) @($AdaptationMeasurements))){throw 'USER_ADAPTATION_CONFIRMATION_MEASUREMENT_MISMATCH'}
        }elseif(@($AdaptationMeasurements).Count-gt0){throw 'USER_ADAPTATION_CONFIRMATION_PROTOCOL_REQUIRED'}
      }else{
        foreach($measurement in @($AdaptationMeasurements)){
          $measurementResult=Get-VerifiedReviewProtocolMeasurement ([string]$measurement) $completionContract
          if($measurementResult.ok-ne$true){throw ('USER_ADAPTATION_MEASUREMENT_UNVERIFIED reason='+[string]$measurementResult.reason)}
          $verifiedMeasurements+=[string]$measurementResult.value
        }
      }
      $artifact=Write-UserAdaptationVerificationArtifact $verification $verification.autonomyEvidenceOutcome @($effectiveSignals) @($verifiedMeasurements) $AdaptationSource $effectiveContext $effectiveWorkflowKey $CorrectionCandidateId $CorrectionTargetPreferenceId $confirmationReceipt
      if($AdaptationSource-eq'user_correction'){
        $deferred=Write-DeferredCorrectionAdaptationRequest $artifact @($effectiveSignals) $effectiveContext $effectiveWorkflowKey $CorrectionCandidateId $CorrectionTargetPreferenceId
        $verification.adaptationObservation=[pscustomobject]@{requested=$true;ok=$null;deferred=$true;appliedCount=0;reason='closed_correction_required_after_verified_outcome';requestHash=[string]$deferred.requestHash;verificationHash=[string]$deferred.verificationHash;replayed=[bool]$deferred.replayed;rawPromptStored=$false}
      }else{
        $observerArgs=@{Mode='Apply';TaskId=$TaskId;WorkspaceKey=$workspaceKeyValue;Context=$effectiveContext;Source=$AdaptationSource;Signals=@($effectiveSignals);Measurements=@($verifiedMeasurements);VerificationArtifactPath=[string]$artifact.path;NoExit=$true;Json=$true}
        if(-not[string]::IsNullOrWhiteSpace($effectiveWorkflowKey)){$observerArgs.WorkflowKey=$effectiveWorkflowKey}
        $observerRaw=@(& (Join-Path $PSScriptRoot 'user-adaptation-observer.ps1') @observerArgs 2>$null)
        $observer=(($observerRaw-join"`n")|ConvertFrom-Json)
        if($observer.ok-ne$true){throw ([string]$observer.error)}
        $verification.adaptationObservation=[pscustomobject]@{requested=$true;ok=$true;deferred=$false;appliedCount=[int]$observer.appliedCount;duplicateCount=[int]$observer.duplicateCount;source=$observer.source;scope=$observer.scope;context=$observer.context;verificationHash=[string]$artifact.sha256;rawPromptStored=$false}
      }
    }catch{
      $verification.adaptationObservation=[pscustomobject]@{requested=$true;ok=$false;deferred=$false;appliedCount=0;errorCode='USER_ADAPTATION_OBSERVER_FAILED';reason=[string]$_.Exception.Message;rawPromptStored=$false}
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($LearningCandidateId)) {
    try {
      $learningReceipt = Write-LearningVerificationReceipt $verification $completedCheckpoint
      $verification.learningVerification = Record-LearningCandidateReceipt $LearningCandidateId $learningReceipt
    } catch {
      $verification.learningVerification = [pscustomobject]@{ requested=$true; ok=$false; reason='learning_receipt_or_link_exception'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false }
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($TaskId) -and $verification.completionOutcome.completed -eq $true) {
    try {
      $trialTaskInstanceId = if ($completionContract -and $completionContract.PSObject.Properties['taskInstanceId']) { [string]$completionContract.taskInstanceId } else { '' }
      if ([string]::IsNullOrWhiteSpace($trialTaskInstanceId)) {
        $trialContractRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') -Action Get -TaskId $TaskId -WorkspaceKey $workspaceKeyValue -NoExit -Json 2>$null)
        if ($trialContractRaw) {
          $trialContract = ConvertFrom-SuperBrainJsonOutput (($trialContractRaw -join "`n") ) 'task verification typed memory trial contract'
          if ($trialContract -and $trialContract.PSObject.Properties['taskInstanceId']) { $trialTaskInstanceId = [string]$trialContract.taskInstanceId }
        }
      }
      $trialScript = Join-Path $PSScriptRoot 'typed-memory-trial.ps1'
      $trialRaw = @(& $trialScript -Action Resolve -TaskId $TaskId -TaskInstanceId $trialTaskInstanceId -WorkspaceKey $workspaceKeyValue -SessionKey (Get-SuperBrainLocalSessionKey) -NoExit -Json 2>$null)
      $trialValue = ConvertFrom-SuperBrainJsonOutput (($trialRaw | ForEach-Object { [string]$_ }) -join "`n") 'task verification typed memory trial'
      $verification.typedMemoryTrial = $trialValue
      $verification.typedMemoryTrial | Add-Member -NotePropertyName attempted -NotePropertyValue $true -Force
    } catch {
      $verification.typedMemoryTrial = [pscustomobject]@{ attempted=$true; ok=$true; status='inconclusive'; verdict='inconclusive'; code='TYPED_MEMORY_TRIAL_RESOLVE_UNAVAILABLE'; rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false }
    }
  }
  # P5: task completion is already committed by the canonical task-state
  # transaction above. The retired project-continuity writer must not create a
  # second global task graph or ledger after verification.
  try { & (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') -WorkspaceKey $workspaceKeyValue -Summary $Summary -NextAction ((@($NextSteps) -join '; ')) -Evidence @($Evidence + @('task-verification.ps1')) -Json | Out-Null } catch {}
  try { & (Join-Path $PSScriptRoot 'post-task-maintenance.ps1') -Summary $Summary -TaskId $TaskId -Evidence @($Evidence + @('task-verification.ps1')) -Json | Out-Null } catch {}
}
if (-not [string]::IsNullOrWhiteSpace($TaskId) -and $verification.completionOutcome -and $verification.completionOutcome.completed -ne $true -and [string]$verification.completionOutcome.reason -eq 'not_evaluated') {
  try {
    $pendingCheckpoint = $scopedCheckpoint
    if (-not $pendingCheckpoint) { $pendingCheckpoint = & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Get -TaskId $TaskId -WorkspaceKey $workspaceKeyValue -Json | ConvertFrom-Json }
    $matchingPendingCheckpoint = $pendingCheckpoint -and [string]$pendingCheckpoint.taskId -eq $TaskId
    if ($matchingPendingCheckpoint) {
      $pendingOpenStepCount = @($openSteps).Count
      $pendingNextStepCount = @($NextSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
      if ($pendingOpenStepCount -gt 0 -or $pendingNextStepCount -gt 0) {
        $verification.completionOutcome = [pscustomobject]@{ attempted=$false; completed=$false; reason='pending_work_preserved'; openStepCount=$pendingOpenStepCount; nextStepCount=$pendingNextStepCount; transactionId=''; taskStateRevision=0 }
      }
    }
  } catch {}
}
$adaptationRequested = ((@($AdaptationSignals).Count + @($AdaptationMeasurements).Count) -gt 0 -or -not [string]::IsNullOrWhiteSpace($AdaptationConfirmationReceiptPath))
if ($adaptationRequested -and -not [string]::IsNullOrWhiteSpace($TaskId) -and ($verification.ok -ne $true -or $verification.completionOutcome.completed -ne $true)) {
  $verification.adaptationObservation = [pscustomobject]@{ requested=$true; ok=$false; deferred=$false; appliedCount=0; errorCode='USER_ADAPTATION_COMPLETED_TASK_REQUIRED'; reason='USER_ADAPTATION_COMPLETED_TASK_REQUIRED'; rawPromptStored=$false }
}
Write-JsonUtf8NoBom $path $verification 10
if ($Json) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 } else { Write-Host "TASK_VERIFICATION_OK path=$path ok=$($verification.ok)" }
if (-not $verification.ok) { exit 1 }
exit 0
