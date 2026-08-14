[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Register','Resolve','ValidateReceipt','GetPrivateGuidance','RecordResult','ValidateCompletion','Get','Audit','Repair','PreviewMigration')]
  [string]$Action = 'Audit',
  [string]$DecisionId = '',
  [int]$Revision = 0,
  [ValidateSet('proposed','active','superseded','cancelled','rejected')]
  [string]$Lifecycle = 'active',
  [ValidateSet('user_confirmed','system','legacy','unknown')]
  [string]$Authority = 'unknown',
  [ValidateSet('advisory','completion_gate')]
  [string]$Enforcement = 'advisory',
  [string]$PrivacyClass = 'private',
  [string]$WorkspaceKey = '',
  [string]$TaskId = '',
  [string]$TaskInstanceId = '',
  [string]$WorklineId = '',
  [ValidateSet('','build','package','release','deploy','test')]
  [string[]]$StageKinds = @(),
  [ValidateSet('','build','package','release','deploy','test')]
  [string]$StageKind = '',
  [string]$IntentFingerprint = '',
  [string]$ContentHash = '',
  [string]$CompletionCriteriaDigest = '',
  [string]$PrivateGuidance = '',
  [string]$Supersedes = '',
  [string]$ReceiptPath = '',
  [string]$BindingDigest = '',
  [switch]$ResultOk,
  [string[]]$EvidenceRefs = @(),
  [string]$PlanFingerprint = '',
  [int]$ContractRevision = 0,
  [string]$OwnerSessionKey = '',
  [string]$StateRoot = '',
  [switch]$Apply,
  [switch]$NoExit,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$memoryBase = if ([string]::IsNullOrWhiteSpace($StateRoot)) { Get-SuperBrainMemoryBaseRoot $Root } else { [IO.Path]::GetFullPath($StateRoot) }
$workspaceRoot = Join-Path $memoryBase 'workspace'
# Keep the canonical control-plane path short: this module also runs inside nested
# Pester/state sandboxes on Windows, where long staging names would otherwise fail.
$bindingRoot = Join-Path $workspaceRoot 'db'
$recordRoot = Join-Path $bindingRoot 'records'
$guidanceRoot = Join-Path $bindingRoot 'guidance'
$receiptRoot = Join-Path $bindingRoot 'receipts'
$resultRoot = Join-Path $bindingRoot 'results'
$indexPath = Join-Path $bindingRoot 'index.json'
$typedLookupRoot = Join-Path $bindingRoot 'typed-index'
$typedManifestRoot = Join-Path $bindingRoot 'typed-manifests'
$nativeIndexRoot = Join-Path $workspaceRoot 'native-decision-index'
$nativeIndexManifestPath = Join-Path $nativeIndexRoot 'manifest.json'
foreach ($directory in @($workspaceRoot,$bindingRoot,$recordRoot,$guidanceRoot,$receiptRoot,$resultRoot,$typedLookupRoot,$typedManifestRoot)) {
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
}
$manifest = Get-SuperBrainManifest $Root

function Write-DecisionBindingResult([object]$Value,[int]$ExitCode=0) {
  if ($Json) { $Value | ConvertTo-Json -Depth 14 }
  else { Write-Host "DECISION_BINDING action=$Action ok=$($Value.ok) status=$($Value.status) taskId=$($Value.taskId)" }
  if ($NoExit) { return }
  exit $ExitCode
}

function Limit-DecisionBindingText([string]$Value,[int]$Max=160) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ([string]$Value).Trim() -replace '\s+',' '
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Get-DecisionBindingId([string]$Value) {
  $clean = ([string]$Value).Trim().ToLowerInvariant() -replace '[^a-z0-9._-]+','-'
  $clean = $clean.Trim('-')
  if ([string]::IsNullOrWhiteSpace($clean)) { return '' }
  if ($clean.Length -gt 96) { $clean = $clean.Substring(0,96).Trim('-') }
  return $clean
}

function Get-DecisionBindingTaskToken([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return (Get-SuperBrainCanonicalTaskToken $Value)
}

function Read-DecisionBindingJson([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

# Call only while the caller holds this exact target's Super Brain file lock.
function Write-DecisionBindingJsonUnlocked([string]$Path,[object]$Value,[int]$Depth=12) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $pending = "$Path.~$([guid]::NewGuid().ToString('n').Substring(0,8))"
  try {
    [IO.File]::WriteAllText($pending, ($Value | ConvertTo-Json -Depth $Depth), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $pending -Destination $Path -Force
  } finally {
    if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
  }
}

function Write-DecisionBindingJson([string]$Path,[object]$Value,[int]$Depth=12) {
  return Invoke-SuperBrainFileLock $Path { Write-DecisionBindingJsonUnlocked $Path $Value $Depth }
}

function New-DecisionBindingIndex {
  return [pscustomobject]@{
    schema = 'super-brain.decision-binding-index.v1'
    packageVersion = [string]$manifest.version
    updatedAt = (Get-Date).ToString('o')
    records = @()
    rawDecisionBodyStored = $false
    rawPromptStored = $false
  }
}

function Get-DecisionBindingIndex {
  $index = Read-DecisionBindingJson $indexPath
  if (-not $index) { return New-DecisionBindingIndex }
  if ([string]$index.schema -ne 'super-brain.decision-binding-index.v1') { throw 'DECISION_BINDING_INDEX_SCHEMA_INVALID' }
  if (-not $index.PSObject.Properties['records']) { $index | Add-Member -NotePropertyName records -NotePropertyValue @() -Force }
  return $index
}

function Get-DecisionBindingTypedScopeToken([string]$CandidateWorkspaceKey,[string]$CandidateStageKind) {
  $workspaceValue = Get-SuperBrainWorkspaceKey $CandidateWorkspaceKey
  if ([string]::IsNullOrWhiteSpace($workspaceValue) -or [string]::IsNullOrWhiteSpace($CandidateStageKind)) { return '' }
  return 'w-' + (Get-SuperBrainStableHash $workspaceValue 20) + '-' + (Get-DecisionBindingId $CandidateStageKind)
}

function Get-DecisionBindingTypedLookupPath([string]$CandidateWorkspaceKey,[string]$CandidateStageKind) {
  $token = Get-DecisionBindingTypedScopeToken $CandidateWorkspaceKey $CandidateStageKind
  if ([string]::IsNullOrWhiteSpace($token)) { return '' }
  return Join-Path $typedLookupRoot ($token + '.json')
}

function Get-DecisionBindingTypedManifestPath([string]$CandidateWorkspaceKey,[string]$CandidateStageKind) {
  $token = Get-DecisionBindingTypedScopeToken $CandidateWorkspaceKey $CandidateStageKind
  if ([string]::IsNullOrWhiteSpace($token)) { return '' }
  return Join-Path $typedManifestRoot ($token + '.json')
}

function New-DecisionBindingTypedLookup([object]$Index,[string]$CandidateWorkspaceKey,[string]$CandidateStageKind,[int]$Generation) {
  $workspaceValue = Get-SuperBrainWorkspaceKey $CandidateWorkspaceKey
  $entries = @($Index.records | Where-Object {
    [string]$_.lifecycle -eq 'active' -and
    (Test-SuperBrainWorkspaceKey ([string]$_.workspaceKey) $workspaceValue) -and
    (@($_.stageKinds) -contains $CandidateStageKind)
  })
  return [pscustomobject]@{
    schema = 'super-brain.decision-binding-typed-index.v1'
    workspaceKey = $workspaceValue
    stageKind = $CandidateStageKind
    generation = $Generation
    updatedAt = (Get-Date).ToString('o')
    records = @($entries)
    rawDecisionBodyStored = $false
    rawPromptStored = $false
  }
}

function Get-DecisionBindingTypedLookup([string]$CandidateWorkspaceKey,[string]$CandidateStageKind) {
  $lookupPath = Get-DecisionBindingTypedLookupPath $CandidateWorkspaceKey $CandidateStageKind
  $manifestPath = Get-DecisionBindingTypedManifestPath $CandidateWorkspaceKey $CandidateStageKind
  if ([string]::IsNullOrWhiteSpace($lookupPath) -or [string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $lookupPath -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    return [pscustomobject]@{ found=$false; usable=$false; reason='typed_lookup_missing'; index=$null }
  }
  $manifest = Read-DecisionBindingJson $manifestPath
  $lookup = Read-DecisionBindingJson $lookupPath
  if (-not $manifest -or -not $lookup -or [string]$manifest.schema -ne 'super-brain.decision-binding-typed-manifest.v1' -or [string]$lookup.schema -ne 'super-brain.decision-binding-typed-index.v1') {
    return [pscustomobject]@{ found=$true; usable=$false; reason='typed_lookup_schema_invalid'; index=$null }
  }
  $workspaceValue = Get-SuperBrainWorkspaceKey $CandidateWorkspaceKey
  if (-not (Test-SuperBrainWorkspaceKey ([string]$manifest.workspaceKey) $workspaceValue) -or [string]$manifest.stageKind -ne $CandidateStageKind -or -not (Test-SuperBrainWorkspaceKey ([string]$lookup.workspaceKey) $workspaceValue) -or [string]$lookup.stageKind -ne $CandidateStageKind -or [int]$lookup.generation -ne [int]$manifest.generation) {
    return [pscustomobject]@{ found=$true; usable=$false; reason='typed_lookup_scope_or_generation_mismatch'; index=$null }
  }
  $hash = Get-SuperBrainFileSha256 $lookupPath
  if ([string]::IsNullOrWhiteSpace([string]$manifest.lookupHash) -or -not [string]::Equals($hash,[string]$manifest.lookupHash,[StringComparison]::OrdinalIgnoreCase)) {
    return [pscustomobject]@{ found=$true; usable=$false; reason='typed_lookup_hash_mismatch'; index=$null }
  }
  if (-not $lookup.PSObject.Properties['records']) { $lookup | Add-Member -NotePropertyName records -NotePropertyValue @() -Force }
  return [pscustomobject]@{ found=$true; usable=$true; reason='typed_lookup_current'; index=$lookup }
}

function Get-DecisionBindingPreferredIndex([string]$CandidateWorkspaceKey,[string]$CandidateStageKind) {
  $typed = Get-DecisionBindingTypedLookup $CandidateWorkspaceKey $CandidateStageKind
  if ($typed.usable) { return [pscustomobject]@{ index=$typed.index; source='typed'; fallbackReason='' } }
  return [pscustomobject]@{ index=(Get-DecisionBindingIndex); source='master_fallback'; fallbackReason=[string]$typed.reason }
}

function Get-DecisionBindingTypedScopePairs([object[]]$Entries) {
  $pairs = @{}
  foreach ($entry in @($Entries)) {
    if (-not $entry) { continue }
    $workspaceValue = Get-SuperBrainWorkspaceKey ([string]$entry.workspaceKey)
    foreach ($stage in @($entry.stageKinds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
      $key = $workspaceValue + '|' + [string]$stage
      if (-not $pairs.ContainsKey($key)) { $pairs[$key] = [pscustomobject]@{ workspaceKey=$workspaceValue; stageKind=[string]$stage } }
    }
  }
  return @($pairs.Values)
}

function Write-DecisionBindingTypedLookupBodies([object]$Index,[object[]]$Scopes) {
  $updates = @()
  foreach ($scope in @(Get-DecisionBindingTypedScopePairs $Scopes)) {
    $manifestPath = Get-DecisionBindingTypedManifestPath ([string]$scope.workspaceKey) ([string]$scope.stageKind)
    $lookupPath = Get-DecisionBindingTypedLookupPath ([string]$scope.workspaceKey) ([string]$scope.stageKind)
    $prior = Read-DecisionBindingJson $manifestPath
    $generation = if ($prior -and [string]$prior.schema -eq 'super-brain.decision-binding-typed-manifest.v1') { [int]$prior.generation + 1 } else { 1 }
    $lookup = New-DecisionBindingTypedLookup $Index ([string]$scope.workspaceKey) ([string]$scope.stageKind) $generation
    Write-DecisionBindingJsonUnlocked $lookupPath $lookup 12
    $updates += [pscustomobject]@{
      workspaceKey = [string]$scope.workspaceKey
      stageKind = [string]$scope.stageKind
      generation = $generation
      lookupPath = $lookupPath
      lookupHash = Get-SuperBrainFileSha256 $lookupPath
      manifestPath = $manifestPath
    }
  }
  return @($updates)
}

function Commit-DecisionBindingTypedLookupManifests([object[]]$Updates) {
  foreach ($update in @($Updates)) {
    $manifest = [pscustomobject]@{
      schema = 'super-brain.decision-binding-typed-manifest.v1'
      workspaceKey = [string]$update.workspaceKey
      stageKind = [string]$update.stageKind
      generation = [int]$update.generation
      lookupPath = [string]$update.lookupPath
      lookupHash = [string]$update.lookupHash
      committedAt = (Get-Date).ToString('o')
      rawDecisionBodyStored = $false
      rawPromptStored = $false
    }
    Write-DecisionBindingJsonUnlocked ([string]$update.manifestPath) $manifest 10
  }
}

function Get-DecisionBindingRecordPath([string]$Id,[int]$RecordRevision) {
  $safe = Get-DecisionBindingId $Id
  if ([string]::IsNullOrWhiteSpace($safe) -or $RecordRevision -lt 1) { throw 'DECISION_BINDING_RECORD_ID_OR_REVISION_INVALID' }
  # Record identity remains inside the immutable body; short filenames survive nested test/workspace roots on Windows.
  return Join-Path $recordRoot ('d-' + (Get-SuperBrainStableHash $safe 16) + '.r' + $RecordRevision + '.json')
}

function Get-DecisionBindingGuidancePath([string]$Id,[int]$RecordRevision) {
  $safe = Get-DecisionBindingId $Id
  if ([string]::IsNullOrWhiteSpace($safe) -or $RecordRevision -lt 1) { return '' }
  return Join-Path $guidanceRoot ('g-' + (Get-SuperBrainStableHash $safe 16) + '.r' + $RecordRevision + '.json')
}

function Protect-DecisionBindingGuidance([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ([string]$Value).Trim()
  $clean = $clean -replace '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*','Bearer [REDACTED]'
  $clean = $clean -replace '(?i)\bsk-[A-Za-z0-9_-]{8,}\b','[REDACTED_KEY]'
  $clean = $clean -replace '(?i)\b(api[_ -]?key|password|passwd|token|secret)\s*[:=]\s*[^\s,;]+','$1=[REDACTED]'
  if ($clean.Length -gt 1600) { $clean = $clean.Substring(0,1600) + '...' }
  return $clean
}

function Get-DecisionBindingScopeFingerprint([object]$Record) {
  $material = [ordered]@{
    workspaceKey = [string]$Record.workspaceKey
    taskId = [string]$Record.taskId
    taskInstanceId = [string]$Record.taskInstanceId
    worklineId = [string]$Record.worklineId
    stageKinds = @($Record.stageKinds | Sort-Object -Unique)
    intentFingerprint = [string]$Record.intentFingerprint
  }
  return Get-SuperBrainStableHash ($material | ConvertTo-Json -Depth 6 -Compress) 64
}

function Get-DecisionBindingRecordFingerprint([object]$Record) {
  $material = [ordered]@{
    decisionId = [string]$Record.decisionId
    revision = [int]$Record.revision
    lifecycle = [string]$Record.lifecycle
    authority = [string]$Record.authority
    enforcement = [string]$Record.enforcement
    privacyClass = [string]$Record.privacyClass
    workspaceKey = [string]$Record.workspaceKey
    taskId = [string]$Record.taskId
    taskInstanceId = [string]$Record.taskInstanceId
    worklineId = [string]$Record.worklineId
    stageKinds = @($Record.stageKinds | Sort-Object -Unique)
    intentFingerprint = [string]$Record.intentFingerprint
    contentHash = [string]$Record.contentHash
    completionCriteriaDigest = [string]$Record.completionCriteriaDigest
    supersedes = [string]$Record.supersedes
    privateGuidanceHash = [string]$Record.privateGuidanceHash
  }
  return Get-SuperBrainStableHash ($material | ConvertTo-Json -Depth 8 -Compress) 64
}

function Get-DecisionBindingReceiptPath([string]$Id,[string]$Stage) {
  $taskToken = if ([string]::IsNullOrWhiteSpace($Id)) { '' } else { 't-' + (Get-SuperBrainStableHash $Id 16) }
  if ([string]::IsNullOrWhiteSpace($taskToken) -or [string]::IsNullOrWhiteSpace($Stage)) { return '' }
  $directory = Join-Path $receiptRoot $taskToken
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  return Join-Path $directory ($Stage + '.json')
}

function Get-DecisionBindingResultPath([string]$Id,[string]$Digest,[string]$RecordId,[int]$RecordRevision) {
  $taskToken = if ([string]::IsNullOrWhiteSpace($Id)) { '' } else { 't-' + (Get-SuperBrainStableHash $Id 16) }
  $safeId = Get-DecisionBindingId $RecordId
  if ([string]::IsNullOrWhiteSpace($taskToken) -or [string]::IsNullOrWhiteSpace($Digest) -or [string]::IsNullOrWhiteSpace($safeId)) { return '' }
  # Keep this evidence path well below legacy Windows path limits; identity is verified from the file body.
  $directory = Join-Path (Join-Path $resultRoot $taskToken) ('b-' + $Digest.Substring(0,[Math]::Min(16,$Digest.Length)))
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  return Join-Path $directory ($safeId + '.r' + $RecordRevision + '.json')
}

function Test-DecisionBindingExactScope([object]$Record) {
  if (-not (Test-SuperBrainWorkspaceKey ([string]$Record.workspaceKey) $WorkspaceKey)) { return $false }
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.taskId) -and [string]$Record.taskId -ne $TaskId) { return $false }
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.taskInstanceId) -and [string]$Record.taskInstanceId -ne $TaskInstanceId) { return $false }
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.worklineId) -and [string]$Record.worklineId -ne $WorklineId) { return $false }
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.intentFingerprint) -and [string]$Record.intentFingerprint -ne $IntentFingerprint) { return $false }
  return (@($Record.stageKinds) -contains $StageKind)
}

function Get-DecisionBindingCurrentRecords([object]$Index,[string]$CandidateWorkspaceKey='',[string]$CandidateStageKind='',[string[]]$ExactDecisionKeys=@()) {
  $records = @()
  $errors = @()
  $entries = @($Index.records | Where-Object {
    if ([string]$_.lifecycle -ne 'active') { return $false }
    if (@($ExactDecisionKeys).Count -gt 0) { return (@($ExactDecisionKeys) -contains ([string]$_.decisionId + ':' + [int]$_.revision)) }
    if (-not [string]::IsNullOrWhiteSpace($CandidateWorkspaceKey) -and -not (Test-SuperBrainWorkspaceKey ([string]$_.workspaceKey) $CandidateWorkspaceKey)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($CandidateStageKind) -and -not (@($_.stageKinds) -contains $CandidateStageKind)) { return $false }
    return $true
  })
  foreach ($entry in $entries) {
    if ([string]$entry.lifecycle -ne 'active') { continue }
    $recordPath = [string]$entry.path
    $record = Read-DecisionBindingJson $recordPath
    if (-not $record) { $errors += ('record_missing_or_invalid:' + [string]$entry.decisionId); continue }
    if ([string]$record.schema -ne 'super-brain.decision-record.v1' -or [string]$record.decisionId -ne [string]$entry.decisionId -or [int]$record.revision -ne [int]$entry.revision) { $errors += ('record_identity_invalid:' + [string]$entry.decisionId); continue }
    $fingerprint = Get-DecisionBindingRecordFingerprint $record
    if ([string]$record.recordFingerprint -ne $fingerprint -or [string]$entry.recordFingerprint -ne $fingerprint) { $errors += ('record_fingerprint_invalid:' + [string]$entry.decisionId); continue }
    if ([string]$entry.fileHash -ne (Get-SuperBrainFileSha256 $recordPath)) { $errors += ('record_file_hash_invalid:' + [string]$entry.decisionId); continue }
    $records += $record
  }
  return [pscustomobject]@{ records=@($records); errors=@($errors) }
}

function New-DecisionBindingReceipt([string]$Status,[object[]]$Decisions,[string[]]$Reasons=@()) {
  $decisionViews = @($Decisions | Sort-Object decisionId,revision | ForEach-Object {
    [pscustomobject]@{
      decisionId = [string]$_.decisionId
      revision = [int]$_.revision
      contentHash = [string]$_.contentHash
      enforcement = [string]$_.enforcement
      completionCriteriaDigest = [string]$_.completionCriteriaDigest
      recordFingerprint = [string]$_.recordFingerprint
    }
  })
  $material = [ordered]@{
    taskId = $TaskId
    taskInstanceId = $TaskInstanceId
    workspaceKey = $WorkspaceKey
    worklineId = $WorklineId
    stageKind = $StageKind
    intentFingerprint = $IntentFingerprint
    contractRevision = $ContractRevision
    planFingerprint = $PlanFingerprint
    packageVersion = [string]$manifest.version
    status = $Status
    decisions = @($decisionViews)
  }
  $digest = Get-SuperBrainStableHash ($material | ConvertTo-Json -Depth 10 -Compress) 64
  return [pscustomobject]@{
    ok = ($Status -ne 'withheld')
    schema = 'super-brain.decision-resolution-receipt.v1'
    receiptId = 'decision-receipt-' + $digest.Substring(0,16)
    taskId = $TaskId
    taskInstanceId = $TaskInstanceId
    workspaceKey = $WorkspaceKey
    worklineId = $WorklineId
    stageKind = $StageKind
    intentFingerprint = $IntentFingerprint
    ownerSessionKey = $OwnerSessionKey
    contractRevision = $ContractRevision
    planFingerprint = $PlanFingerprint
    packageVersion = [string]$manifest.version
    status = $Status
    bindingDigest = $digest
    decisions = @($decisionViews)
    reasons = @($Reasons | Select-Object -First 8)
    createdAt = (Get-Date).ToString('o')
    path = ''
    rawDecisionBodyStored = $false
    rawPromptStored = $false
  }
}

function Assert-DecisionBindingResolutionInput {
  foreach ($pair in @(@('TaskId',$TaskId),@('TaskInstanceId',$TaskInstanceId),@('WorkspaceKey',$WorkspaceKey),@('StageKind',$StageKind),@('PlanFingerprint',$PlanFingerprint),@('OwnerSessionKey',$OwnerSessionKey))) {
    if ([string]::IsNullOrWhiteSpace([string]$pair[1])) { throw ('DECISION_BINDING_' + $pair[0].ToUpperInvariant() + '_REQUIRED') }
  }
  if ($TaskInstanceId -notmatch '^ti-[a-f0-9]{32}$') { throw 'DECISION_BINDING_TASK_INSTANCE_INVALID' }
  if ($ContractRevision -lt 1) { throw 'DECISION_BINDING_CONTRACT_REVISION_REQUIRED' }
}

function Register-DecisionBindingRecord {
  $id = Get-DecisionBindingId $DecisionId
  if ([string]::IsNullOrWhiteSpace($id)) { throw 'DECISION_BINDING_DECISION_ID_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { throw 'DECISION_BINDING_WORKSPACE_REQUIRED' }
  $stages = @($StageKinds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
  if ($stages.Count -eq 0) { throw 'DECISION_BINDING_STAGE_KINDS_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace($ContentHash) -or $ContentHash -notmatch '^[a-fA-F0-9]{32,64}$') { throw 'DECISION_BINDING_CONTENT_HASH_REQUIRED' }
  if ($Enforcement -eq 'completion_gate') {
    if ($Lifecycle -ne 'active' -or $Authority -ne 'user_confirmed') { throw 'DECISION_BINDING_COMPLETION_GATE_USER_CONFIRMATION_REQUIRED' }
    if ([string]::IsNullOrWhiteSpace($CompletionCriteriaDigest) -or $CompletionCriteriaDigest -notmatch '^[a-fA-F0-9]{32,64}$') { throw 'DECISION_BINDING_COMPLETION_CRITERIA_REQUIRED' }
  }
  return Invoke-SuperBrainFileLock $indexPath {
    $index = Get-DecisionBindingIndex
    $same = @($index.records | Where-Object { [string]$_.decisionId -eq $id } | Sort-Object revision -Descending)
    $affectedEntries = New-Object System.Collections.ArrayList
    foreach ($existingEntry in @($same)) { [void]$affectedEntries.Add($existingEntry) }
    $recordRevision = if ($Revision -gt 0) { $Revision } elseif ($same.Count -gt 0) { [int]$same[0].revision + 1 } else { 1 }
    if (@($same | Where-Object { [int]$_.revision -eq $recordRevision }).Count -gt 0) { throw 'DECISION_BINDING_REVISION_EXISTS' }
    if (-not [string]::IsNullOrWhiteSpace($Supersedes)) {
      foreach ($entry in @($index.records | Where-Object { [string]$_.decisionId -eq (Get-DecisionBindingId $Supersedes) -and [string]$_.lifecycle -eq 'active' })) {
        [void]$affectedEntries.Add($entry)
        $entry.lifecycle = 'superseded'
      }
    }
    foreach ($entry in @($index.records | Where-Object { [string]$_.decisionId -eq $id -and [string]$_.lifecycle -eq 'active' })) { $entry.lifecycle = 'superseded' }
    $guidanceText = Protect-DecisionBindingGuidance $PrivateGuidance
    $guidanceHash = if ([string]::IsNullOrWhiteSpace($guidanceText)) { '' } else { Get-SuperBrainStableHash $guidanceText 64 }
    $guidancePath = if ([string]::IsNullOrWhiteSpace($guidanceText)) { '' } else { Get-DecisionBindingGuidancePath $id $recordRevision }
    $record = [pscustomobject]@{
      schema = 'super-brain.decision-record.v1'
      decisionId = $id
      revision = $recordRevision
      lifecycle = $Lifecycle
      authority = $Authority
      privacyClass = Limit-DecisionBindingText $PrivacyClass 64
      workspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
      taskId = Limit-DecisionBindingText $TaskId 120
      taskInstanceId = Limit-DecisionBindingText $TaskInstanceId 64
      worklineId = Limit-DecisionBindingText $WorklineId 120
      stageKinds = @($stages)
      intentFingerprint = Limit-DecisionBindingText $IntentFingerprint 128
      enforcement = $Enforcement
      contentHash = $ContentHash.ToLowerInvariant()
      completionCriteriaDigest = $CompletionCriteriaDigest.ToLowerInvariant()
      supersedes = Get-DecisionBindingId $Supersedes
      privateGuidancePath = $guidancePath
      privateGuidanceHash = $guidanceHash
      createdAt = (Get-Date).ToString('o')
      rawDecisionBodyStored = $false
      rawPromptStored = $false
    }
    $record | Add-Member -NotePropertyName scopeFingerprint -NotePropertyValue (Get-DecisionBindingScopeFingerprint $record) -Force
    $record | Add-Member -NotePropertyName recordFingerprint -NotePropertyValue (Get-DecisionBindingRecordFingerprint $record) -Force
    $recordPath = Get-DecisionBindingRecordPath $id $recordRevision
    if (-not [string]::IsNullOrWhiteSpace($guidancePath)) {
      $guidance = [pscustomobject]@{ schema='super-brain.private-decision-guidance.v1'; decisionId=$id; revision=$recordRevision; contentHash=$record.contentHash; guidanceHash=$guidanceHash; text=$guidanceText; createdAt=(Get-Date).ToString('o'); rawPromptStored=$false }
      Write-DecisionBindingJson $guidancePath $guidance 10
    }
    Write-DecisionBindingJson $recordPath $record 12
    $entry = [pscustomobject]@{
      decisionId = $record.decisionId
      revision = $record.revision
      lifecycle = $record.lifecycle
      authority = $record.authority
      enforcement = $record.enforcement
      workspaceKey = $record.workspaceKey
      taskId = $record.taskId
      taskInstanceId = $record.taskInstanceId
      worklineId = $record.worklineId
      stageKinds = @($record.stageKinds)
      intentFingerprint = $record.intentFingerprint
      scopeFingerprint = $record.scopeFingerprint
      recordFingerprint = $record.recordFingerprint
      fileHash = Get-SuperBrainFileSha256 $recordPath
      path = $recordPath
    }
    $index.records = @($index.records + @($entry))
    $index.updatedAt = (Get-Date).ToString('o')
    $index.packageVersion = [string]$manifest.version
    [void]$affectedEntries.Add($entry)
    # Lookup bodies are written before the authoritative index; their manifests publish only after that index commit.
    $typedUpdates = Write-DecisionBindingTypedLookupBodies $index ([object[]]$affectedEntries.ToArray())
    Write-DecisionBindingJsonUnlocked $indexPath $index 12
    Commit-DecisionBindingTypedLookupManifests $typedUpdates
    return [pscustomobject]@{ ok=$true; status='registered'; decisionId=$id; revision=$recordRevision; recordFingerprint=$record.recordFingerprint; recordPath=$recordPath; rawDecisionBodyStored=$false }
  }
}

function Get-DecisionBindingPrivateGuidance {
  $receiptStatus = Validate-DecisionBindingReceipt
  if ($receiptStatus.ok -ne $true) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_GUIDANCE_RECEIPT_INVALID'; guidance=@(); rawPromptStored=$false } }
  if ([string]$receiptStatus.status -eq 'none_applicable') { return [pscustomobject]@{ ok=$true; status='none_applicable'; code='DECISION_BINDING_GUIDANCE_NONE_APPLICABLE'; guidance=@(); rawPromptStored=$false } }
  $keys = @($receiptStatus.decisions | ForEach-Object { [string]$_.decisionId + ':' + [int]$_.revision })
  $preferred = Get-DecisionBindingPreferredIndex $WorkspaceKey $StageKind
  $loaded = Get-DecisionBindingCurrentRecords $preferred.index '' '' $keys
  if (@($loaded.errors).Count -gt 0) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_GUIDANCE_INDEX_INVALID'; guidance=@(); reasons=@($loaded.errors); rawPromptStored=$false } }
  $guidance = @()
  foreach ($decision in @($receiptStatus.decisions)) {
    $record = @($loaded.records | Where-Object { [string]$_.decisionId -eq [string]$decision.decisionId -and [int]$_.revision -eq [int]$decision.revision } | Select-Object -First 1)
    if ($record.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$record[0].privateGuidancePath)) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_GUIDANCE_MISSING'; guidance=@(); rawPromptStored=$false } }
    $private = Read-DecisionBindingJson ([string]$record[0].privateGuidancePath)
    if (-not $private -or [string]$private.schema -ne 'super-brain.private-decision-guidance.v1' -or [string]$private.decisionId -ne [string]$decision.decisionId -or [int]$private.revision -ne [int]$decision.revision -or [string]$private.contentHash -ne [string]$decision.contentHash -or [string]$private.guidanceHash -ne [string]$record[0].privateGuidanceHash) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_GUIDANCE_INVALID'; guidance=@(); rawPromptStored=$false } }
    $guidance += [pscustomobject]@{ decisionId=[string]$decision.decisionId; revision=[int]$decision.revision; text=Limit-DecisionBindingText ([string]$private.text) 720; guidanceHash=[string]$private.guidanceHash }
  }
  return [pscustomobject]@{ ok=$true; status='bound'; code='DECISION_BINDING_GUIDANCE_READY'; bindingDigest=[string]$receiptStatus.bindingDigest; guidance=@($guidance); rawPromptStored=$false; rawDecisionBodyPersistedInReceipt=$false }
}

function Resolve-DecisionBinding {
  Assert-DecisionBindingResolutionInput
  return Invoke-SuperBrainFileLock $indexPath {
    $preferred = Get-DecisionBindingPreferredIndex $WorkspaceKey $StageKind
    $loaded = Get-DecisionBindingCurrentRecords $preferred.index $WorkspaceKey $StageKind
    if (@($loaded.errors).Count -gt 0) {
      $receipt = New-DecisionBindingReceipt 'withheld' @() @($loaded.errors)
      $receipt.path = Get-DecisionBindingReceiptPath $TaskId $StageKind
      Write-DecisionBindingJson $receipt.path $receipt 12
      return $receipt
    }
    $scoped = @($loaded.records | Where-Object { Test-DecisionBindingExactScope $_ })
    $invalid = @($scoped | Where-Object { [string]$_.enforcement -eq 'completion_gate' -and ([string]$_.authority -ne 'user_confirmed' -or [string]$_.lifecycle -ne 'active') })
    if ($invalid.Count -gt 0) {
      $receipt = New-DecisionBindingReceipt 'withheld' @() @('completion_gate_authority_or_lifecycle_invalid')
      $receipt.path = Get-DecisionBindingReceiptPath $TaskId $StageKind
      Write-DecisionBindingJson $receipt.path $receipt 12
      return $receipt
    }
    $gates = @($scoped | Where-Object { [string]$_.enforcement -eq 'completion_gate' })
    $conflicts = @($gates | Group-Object scopeFingerprint | Where-Object { $_.Count -gt 1 })
    if ($conflicts.Count -gt 0) {
      $receipt = New-DecisionBindingReceipt 'withheld' @() @('overlapping_completion_gate_decisions')
      $receipt.path = Get-DecisionBindingReceiptPath $TaskId $StageKind
      Write-JsonUtf8NoBom $receipt.path $receipt 12
      return $receipt
    }
    $status = if ($gates.Count -gt 0) { 'bound' } else { 'none_applicable' }
    $receipt = New-DecisionBindingReceipt $status $gates @()
    $receipt.path = Get-DecisionBindingReceiptPath $TaskId $StageKind
    Write-DecisionBindingJson $receipt.path $receipt 12
    return $receipt
  }
}

function Get-DecisionBindingReceipt([string]$RequestedPath = '') {
  $path = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { Get-DecisionBindingReceiptPath $TaskId $StageKind } else { [IO.Path]::GetFullPath($RequestedPath) }
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_MISSING'; path=$path } }
  $receipt = Read-DecisionBindingJson $path
  if (-not $receipt -or [string]$receipt.schema -ne 'super-brain.decision-resolution-receipt.v1') { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_INVALID'; path=$path } }
  $receipt | Add-Member -NotePropertyName path -NotePropertyValue $path -Force
  return $receipt
}

function Validate-DecisionBindingReceipt {
  Assert-DecisionBindingResolutionInput
  $receipt = Get-DecisionBindingReceipt $ReceiptPath
  if ($receipt.ok -ne $true -and [string]$receipt.code) { return $receipt }
  foreach ($pair in @(@('taskId',$TaskId),@('taskInstanceId',$TaskInstanceId),@('workspaceKey',$WorkspaceKey),@('worklineId',$WorklineId),@('stageKind',$StageKind),@('intentFingerprint',$IntentFingerprint),@('ownerSessionKey',$OwnerSessionKey),@('planFingerprint',$PlanFingerprint))) {
    if ([string]$receipt.$($pair[0]) -ne [string]$pair[1]) { return [pscustomobject]@{ ok=$false; status='withheld'; code=('DECISION_BINDING_RECEIPT_' + $pair[0].ToUpperInvariant() + '_MISMATCH'); path=$receipt.path } }
  }
  if ([int]$receipt.contractRevision -ne $ContractRevision -or [string]$receipt.packageVersion -ne [string]$manifest.version) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_VERSION_OR_REVISION_MISMATCH'; path=$receipt.path } }
  $decisionKeys = @($receipt.decisions | ForEach-Object { [string]$_.decisionId + ':' + [int]$_.revision })
  $preferred = Get-DecisionBindingPreferredIndex $WorkspaceKey $StageKind
  $loaded = Get-DecisionBindingCurrentRecords $preferred.index '' '' $decisionKeys
  if (@($loaded.errors).Count -gt 0) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_INDEX_CORRUPT'; reasons=@($loaded.errors); path=$receipt.path } }
  $byId = @{}
  foreach ($record in @($loaded.records)) { $byId[([string]$record.decisionId + ':' + [int]$record.revision)] = $record }
  foreach ($decision in @($receipt.decisions)) {
    $key = [string]$decision.decisionId + ':' + [int]$decision.revision
    $record = $byId[$key]
    if (-not $record -or [string]$record.contentHash -ne [string]$decision.contentHash -or [string]$record.recordFingerprint -ne [string]$decision.recordFingerprint -or -not (Test-DecisionBindingExactScope $record)) {
      return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_STALE_OR_FOREIGN'; path=$receipt.path }
    }
  }
  $expected = New-DecisionBindingReceipt ([string]$receipt.status) @($receipt.decisions | ForEach-Object {
    [pscustomobject]@{ decisionId=$_.decisionId; revision=$_.revision; contentHash=$_.contentHash; enforcement=$_.enforcement; completionCriteriaDigest=$_.completionCriteriaDigest; recordFingerprint=$_.recordFingerprint }
  }) @()
  if ([string]$expected.bindingDigest -ne [string]$receipt.bindingDigest) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RECEIPT_DIGEST_INVALID'; path=$receipt.path } }
  return [pscustomobject]@{ ok=([string]$receipt.status -ne 'withheld'); status=[string]$receipt.status; code='DECISION_BINDING_RECEIPT_CURRENT'; bindingDigest=[string]$receipt.bindingDigest; decisions=@($receipt.decisions); path=$receipt.path }
}

function Record-DecisionBindingResult {
  if ([string]::IsNullOrWhiteSpace($DecisionId) -or $Revision -lt 1 -or [string]::IsNullOrWhiteSpace($BindingDigest)) { throw 'DECISION_BINDING_RESULT_IDENTITY_REQUIRED' }
  $receiptStatus = Validate-DecisionBindingReceipt
  if ($receiptStatus.ok -ne $true -or [string]$receiptStatus.status -ne 'bound') { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RESULT_RECEIPT_NOT_CURRENT'; receipt=$receiptStatus } }
  $decision = @($receiptStatus.decisions | Where-Object { [string]$_.decisionId -eq (Get-DecisionBindingId $DecisionId) -and [int]$_.revision -eq $Revision } | Select-Object -First 1)
  if ($decision.Count -ne 1 -or [string]$BindingDigest -ne [string]$receiptStatus.bindingDigest) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_RESULT_FOREIGN_OR_STALE' } }
  $resultPath = Get-DecisionBindingResultPath $TaskId $BindingDigest ([string]$decision[0].decisionId) ([int]$decision[0].revision)
  $record = [pscustomobject]@{
    schema = 'super-brain.decision-completion-result.v1'
    taskId = $TaskId
    taskInstanceId = $TaskInstanceId
    workspaceKey = $WorkspaceKey
    worklineId = $WorklineId
    stageKind = $StageKind
    intentFingerprint = $IntentFingerprint
    ownerSessionKey = $OwnerSessionKey
    contractRevision = $ContractRevision
    planFingerprint = $PlanFingerprint
    packageVersion = [string]$manifest.version
    bindingDigest = $BindingDigest
    decisionId = [string]$decision[0].decisionId
    revision = [int]$decision[0].revision
    contentHash = [string]$decision[0].contentHash
    completionCriteriaDigest = [string]$decision[0].completionCriteriaDigest
    ok = [bool]$ResultOk
    evidenceRefs = @($EvidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { Limit-DecisionBindingText ([string]$_) 180 } | Select-Object -Unique -First 12)
    recordedAt = (Get-Date).ToString('o')
    rawDecisionBodyStored = $false
    rawPromptStored = $false
  }
  Write-DecisionBindingJson $resultPath $record 12
  return [pscustomobject]@{ ok=$true; status='recorded'; bindingDigest=$BindingDigest; decisionId=$record.decisionId; revision=$record.revision; resultPath=$resultPath; resultHash=Get-SuperBrainFileSha256 $resultPath }
}

function Validate-DecisionBindingCompletion {
  $receiptStatus = Validate-DecisionBindingReceipt
  if ($receiptStatus.ok -ne $true) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_COMPLETION_RECEIPT_INVALID'; receipt=$receiptStatus } }
  if ([string]$receiptStatus.status -eq 'none_applicable') { return [pscustomobject]@{ ok=$true; status='none_applicable'; code='DECISION_BINDING_COMPLETION_NONE_APPLICABLE'; bindingDigest=[string]$receiptStatus.bindingDigest; decisionCount=0; results=@() } }
  if ([string]$receiptStatus.status -ne 'bound') { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_COMPLETION_WITHHELD'; receipt=$receiptStatus } }
  $results = @()
  $failures = @()
  foreach ($decision in @($receiptStatus.decisions | Where-Object { [string]$_.enforcement -eq 'completion_gate' })) {
    $path = Get-DecisionBindingResultPath $TaskId ([string]$receiptStatus.bindingDigest) ([string]$decision.decisionId) ([int]$decision.revision)
    $result = Read-DecisionBindingJson $path
    if (-not $result) { $failures += ('missing_result:' + [string]$decision.decisionId); continue }
    $valid = ([string]$result.schema -eq 'super-brain.decision-completion-result.v1' -and [string]$result.taskId -eq $TaskId -and [string]$result.taskInstanceId -eq $TaskInstanceId -and (Test-SuperBrainWorkspaceKey ([string]$result.workspaceKey) $WorkspaceKey) -and [string]$result.stageKind -eq $StageKind -and [string]$result.ownerSessionKey -eq $OwnerSessionKey -and [int]$result.contractRevision -eq $ContractRevision -and [string]$result.planFingerprint -eq $PlanFingerprint -and [string]$result.packageVersion -eq [string]$manifest.version -and [string]$result.bindingDigest -eq [string]$receiptStatus.bindingDigest -and [string]$result.decisionId -eq [string]$decision.decisionId -and [int]$result.revision -eq [int]$decision.revision -and [string]$result.contentHash -eq [string]$decision.contentHash -and [string]$result.completionCriteriaDigest -eq [string]$decision.completionCriteriaDigest -and $result.ok -eq $true)
    if (-not $valid) { $failures += ('invalid_or_failed_result:' + [string]$decision.decisionId); continue }
    $results += [pscustomobject]@{ decisionId=[string]$decision.decisionId; revision=[int]$decision.revision; resultPath=$path; resultHash=Get-SuperBrainFileSha256 $path }
  }
  if ($failures.Count -gt 0) { return [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_COMPLETION_RESULTS_UNSATISFIED'; bindingDigest=[string]$receiptStatus.bindingDigest; failures=@($failures); results=@($results) } }
  return [pscustomobject]@{ ok=$true; status='bound'; code='DECISION_BINDING_COMPLETION_RESULTS_CURRENT'; bindingDigest=[string]$receiptStatus.bindingDigest; decisionCount=@($receiptStatus.decisions).Count; results=@($results) }
}

function Get-DecisionBindingAudit {
  $index = Get-DecisionBindingIndex
  $loaded = Get-DecisionBindingCurrentRecords $index
  return [pscustomobject]@{
    ok = (@($loaded.errors).Count -eq 0)
    schema = 'super-brain.decision-binding-audit.v1'
    checkedAt = (Get-Date).ToString('o')
    packageVersion = [string]$manifest.version
    recordCount = @($index.records).Count
    activeRecordCount = @($loaded.records).Count
    errors = @($loaded.errors)
    indexPath = $indexPath
    rawDecisionBodyStored = $false
  }
}

function Repair-DecisionBindingIndex {
  $files = @(Get-ChildItem -LiteralPath $recordRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
  $entries = @()
  $errors = @()
  foreach ($file in $files) {
    $record = Read-DecisionBindingJson $file.FullName
    if (-not $record -or [string]$record.schema -ne 'super-brain.decision-record.v1') { $errors += ('invalid_record:' + $file.Name); continue }
    $fingerprint = Get-DecisionBindingRecordFingerprint $record
    if ([string]$record.recordFingerprint -ne $fingerprint) { $errors += ('fingerprint_invalid:' + $file.Name); continue }
    $entries += [pscustomobject]@{ decisionId=[string]$record.decisionId; revision=[int]$record.revision; lifecycle=[string]$record.lifecycle; authority=[string]$record.authority; enforcement=[string]$record.enforcement; workspaceKey=[string]$record.workspaceKey; taskId=[string]$record.taskId; taskInstanceId=[string]$record.taskInstanceId; worklineId=[string]$record.worklineId; stageKinds=@($record.stageKinds); intentFingerprint=[string]$record.intentFingerprint; scopeFingerprint=[string]$record.scopeFingerprint; recordFingerprint=$fingerprint; fileHash=Get-SuperBrainFileSha256 $file.FullName; path=$file.FullName }
  }
  $preview = [pscustomobject]@{ ok=($errors.Count -eq 0); status=if($Apply){'repaired'}else{'preview'}; recordCount=@($entries).Count; errors=@($errors); indexPath=$indexPath }
  if ($Apply -and $errors.Count -eq 0) {
    return Invoke-SuperBrainFileLock $indexPath {
      $newIndex = New-DecisionBindingIndex
      $newIndex.records = @($entries | Sort-Object decisionId,revision)
      $typedScopes = Get-DecisionBindingTypedScopePairs ([object[]]@($newIndex.records))
      $typedUpdates = Write-DecisionBindingTypedLookupBodies $newIndex ([object[]]$typedScopes)
      Write-DecisionBindingJsonUnlocked $indexPath $newIndex 12
      Commit-DecisionBindingTypedLookupManifests $typedUpdates
      return $preview
    }
  }
  return $preview
}

# Preserve the v1 registry as a compatibility source. The adapter below owns
# the composite v2 receipt without changing legacy record or result formats.
$script:LegacyResolveDecisionBinding = ${function:Resolve-DecisionBinding}
$script:LegacyGetDecisionBindingReceipt = ${function:Get-DecisionBindingReceipt}
$script:LegacyValidateDecisionBindingReceipt = ${function:Validate-DecisionBindingReceipt}
$script:LegacyGetDecisionBindingPrivateGuidance = ${function:Get-DecisionBindingPrivateGuidance}
$script:LegacyRecordDecisionBindingResult = ${function:Record-DecisionBindingResult}
$script:LegacyValidateDecisionBindingCompletion = ${function:Validate-DecisionBindingCompletion}
$nativeAdapterPath = Join-Path $PSScriptRoot 'internal\native-decision-binding.ps1'
if (-not (Test-Path -LiteralPath $nativeAdapterPath -PathType Leaf)) { throw 'DECISION_BINDING_NATIVE_ADAPTER_MISSING' }
. $nativeAdapterPath

try {
  $result = switch ($Action) {
    'Register' { Register-DecisionBindingRecord }
    'Resolve' { Resolve-DecisionBinding }
    'ValidateReceipt' { Validate-DecisionBindingReceipt }
    'GetPrivateGuidance' { Get-DecisionBindingPrivateGuidance }
    'RecordResult' { Record-DecisionBindingResult }
    'ValidateCompletion' { Validate-DecisionBindingCompletion }
    'Get' { Get-DecisionBindingReceipt $ReceiptPath }
    'Audit' { Get-DecisionBindingAudit }
    'Repair' { Repair-DecisionBindingIndex }
    'PreviewMigration' { [pscustomobject]@{ ok=$true; status='preview_only'; code='DECISION_BINDING_LEGACY_MIGRATION_REQUIRES_EXPLICIT_USER_CONFIRMATION'; rawDecisionBodyStored=$false } }
  }
  Write-DecisionBindingResult $result $(if($result.ok -eq $true){0}else{1})
} catch {
  $failure = [pscustomobject]@{ ok=$false; status='withheld'; code='DECISION_BINDING_EXCEPTION'; error=Limit-DecisionBindingText $_.Exception.Message 240; taskId=$TaskId; workspaceKey=$WorkspaceKey; rawDecisionBodyStored=$false }
  Write-DecisionBindingResult $failure 1
}
