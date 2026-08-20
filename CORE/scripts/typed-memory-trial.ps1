[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet('Start','Resolve')]
  [string]$Action = 'Resolve',
  [string]$TaskId = '',
  [string]$TaskInstanceId = '',
  [string]$WorkspaceKey = '',
  [string]$SessionKey = '',
  [string]$CognitiveEvidencePath = '',
  [string]$SnapshotPath = '',
  [int]$MaxAgeMinutes = 60,
  [switch]$Json,
  [switch]$NoExit
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
$workspaceKeyValue = Get-SuperBrainWorkspaceKey $WorkspaceKey
$sessionKeyValue = Get-SuperBrainLocalSessionKey $SessionKey
$snapshotRoot = Join-Path $workspace 'runtime-state\typed-memory-trial-snapshots'
$receiptRoot = Join-Path $workspace 'runtime-state\typed-memory-trial-receipts'
$manifest = Get-SuperBrainManifest $Root

function Read-JsonFile([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-Sha256Text([string]$Value) {
  if ($null -eq $Value) { $Value = '' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return (-join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Value)) | ForEach-Object { $_.ToString('x2') })).ToLowerInvariant()
  } finally { $sha.Dispose() }
}

function Get-SafeTaskInstanceId([string]$Value) {
  if ([string]$Value -match '^ti-[a-f0-9]{32}$') { return $Value.ToLowerInvariant() }
  return ''
}

function Get-TaskInstancePath([string]$RootPath,[string]$InstanceId) {
  $safeInstance = Get-SafeTaskInstanceId $InstanceId
  if ([string]::IsNullOrWhiteSpace($safeInstance)) { return '' }
  return Join-Path ([System.IO.Path]::GetFullPath($RootPath)) ((Get-Sha256Text $safeInstance) + '.json')
}

function Get-RelativePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  try { return ([System.IO.Path]::GetFullPath($Path).Substring(([System.IO.Path]::GetFullPath($workspace)).Length).TrimStart('\','/') -replace '\\','/') } catch { return '' }
}

function Test-Fresh([object]$Value,[int]$LimitMinutes) {
  if (-not $Value) { return $false }
  $raw = if ($Value.PSObject.Properties['checkedAt']) { [string]$Value.checkedAt } elseif ($Value.PSObject.Properties['recordedAt']) { [string]$Value.recordedAt } else { '' }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
  try {
    $when = [datetime]::Parse($raw)
    if ($when -gt (Get-Date).AddMinutes(5)) { return $false }
    return (((Get-Date) - $when).TotalMinutes -le $LimitMinutes)
  } catch { return $false }
}

function New-TrialResult([string]$Status,[string]$Verdict,[string]$Code,[hashtable]$Extra = @{}) {
  $result = [ordered]@{
    ok = $true
    schema = 'super-brain.typed-memory-trial-receipt.v1'
    status = $Status
    verdict = $Verdict
    code = $Code
    taskId = $TaskId
    taskInstanceId = $TaskInstanceId
    workspaceKey = $workspaceKeyValue
    ownerSessionKey = $sessionKeyValue
    packageVersion = [string]$manifest.version
    rawPromptStored = $false
    rawSummaryStored = $false
    rawTranscriptStored = $false
    memoryBodyStored = $false
  }
  foreach ($key in $Extra.Keys) { $result[$key] = $Extra[$key] }
  return [pscustomobject]$result
}

function Get-MemoryRefs([object]$Influence) {
  $bucketKinds = @(
    [pscustomobject]@{ name='behaviorGuidance'; kind='preference'; effect='shape_behavior' },
    [pscustomobject]@{ name='reusableAdvice'; kind='experience'; effect='reuse_as_advice' },
    [pscustomobject]@{ name='procedureSteps'; kind='procedure'; effect='follow_governed_steps' },
    [pscustomobject]@{ name='references'; kind='note'; effect='reference_only' },
    [pscustomobject]@{ name='learningCandidates'; kind='reflection'; effect='learning_candidate_only' }
  )
  $seen = @{}
  $refs = @()
  foreach ($bucket in $bucketKinds) {
    $items = if ($Influence.PSObject.Properties[$bucket.name]) { @($Influence.($bucket.name)) } else { @() }
    foreach ($item in $items) {
      if (-not $item) { continue }
      $cardId = if ($item.PSObject.Properties['cardId']) { [string]$item.cardId } else { '' }
      $revision = if ($item.PSObject.Properties['cardRevision']) { [int]$item.cardRevision } else { 0 }
      $effect = if ($item.PSObject.Properties['effect'] -and -not [string]::IsNullOrWhiteSpace([string]$item.effect)) { [string]$item.effect } else { [string]$bucket.effect }
      if ([string]::IsNullOrWhiteSpace($cardId) -or $revision -lt 1) { continue }
      $key = '{0}|{1}|{2}|{3}' -f $cardId,$revision,$bucket.kind,$effect
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      $refs += [pscustomobject]@{ cardId=$cardId; cardRevision=$revision; kind=$bucket.kind; effect=$effect }
    }
  }
  return @($refs | Sort-Object cardId,cardRevision,kind,effect)
}

function Get-SourceHash([object]$Scope,[object[]]$Refs) {
  $material = [ordered]@{
    taskId = [string]$Scope.taskId
    taskInstanceId = [string]$Scope.taskInstanceId
    workspaceKey = [string]$Scope.workspaceKey
    ownerSessionKey = [string]$Scope.ownerSessionKey
    refs = @($Refs)
    privacy = [ordered]@{ rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false }
  }
  return Get-Sha256Text ($material | ConvertTo-Json -Depth 10 -Compress)
}

function Get-CanonicalSnapshotPath([string]$InstanceId) { return Get-TaskInstancePath $snapshotRoot $InstanceId }
function Get-CanonicalReceiptPath([string]$InstanceId) { return Get-TaskInstancePath $receiptRoot $InstanceId }

function Test-ScopedIdentity([object]$Value,[string]$ExpectedTask,[string]$ExpectedInstance,[string]$ExpectedWorkspace,[string]$ExpectedSession) {
  if (-not $Value) { return $false }
  if ([string]$Value.taskId -ne $ExpectedTask -or [string]$Value.taskInstanceId -ne $ExpectedInstance) { return $false }
  if (-not (Test-SuperBrainWorkspaceKey ([string]$Value.workspaceKey) $ExpectedWorkspace)) { return $false }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSession) -and [string]$Value.ownerSessionKey -ne $ExpectedSession) { return $false }
  return $true
}

function Publish-ImmutableJson([string]$Path,[object]$Value,[string]$CollisionCode) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $pending = Join-Path $directory ('.pending-' + [guid]::NewGuid().ToString('n') + '.json')
  try {
    Write-JsonUtf8NoBom $pending $Value 14
    $hash = Get-SuperBrainFileSha256 $pending
    $published = Publish-SuperBrainImmutableFile -SourcePath $pending -DestinationPath $Path -ExpectedSha256 $hash -CollisionCode $CollisionCode -SourceMismatchCode 'TYPED_MEMORY_TRIAL_SOURCE_MISMATCH'
    return [pscustomobject]@{ ok=$true; path=$Path; sha256=$hash; replayed=[bool]$published.replayed }
  } finally { if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue } }
}

function Mark-NativeMemorySnapshotDirty([string]$Reason) {
  $path = Join-Path $workspace 'native-memory-influence-snapshot.dirty.json'
  try {
    Write-JsonUtf8NoBom $path ([ordered]@{
      schema='super-brain.native-memory-influence-snapshot-dirty.v1'
      invalidatedAt=(Get-Date).ToUniversalTime().ToString('o')
      reason=$Reason
      cachePending=$true
      rawPromptStored=$false
      rawSessionIdStored=$false
    }) 8
    return [pscustomobject]@{ ok=$true; path=$path }
  } catch {
    return [pscustomobject]@{ ok=$false; path=$path }
  }
}

function Refresh-NativeMemoryInfluenceSnapshot {
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    $dirty = Mark-NativeMemorySnapshotDirty 'typed_memory_trial_cache_refresh_unavailable'
    return [pscustomobject]@{ attempted=$true; ok=$false; cachePending=$true; dirty=[bool]$dirty.ok; dirtyPath=[string]$dirty.path; code='TYPED_MEMORY_TRIAL_CACHE_REFRESH_UNAVAILABLE'; path=''; payloadHash='' }
  }
  $pythonPath = [string]$python.Source
  if ([string]::IsNullOrWhiteSpace($pythonPath)) { $pythonPath = [string]$python.Name }
  try {
    $raw = @(& $pythonPath -X utf8 -B $runtime --state-root $memoryBase publish-native-memory-influence-snapshot 2>$null)
    $exitCode = $LASTEXITCODE
    $value = ConvertFrom-SuperBrainJsonOutput (($raw | ForEach-Object { [string]$_ }) -join "`n") 'typed memory trial native snapshot refresh'
    if ($exitCode -eq 0 -and $value -and $value.ok -eq $true) {
      return [pscustomobject]@{ attempted=$true; ok=$true; cachePending=$false; dirty=$false; dirtyPath=''; code='TYPED_MEMORY_TRIAL_CACHE_REFRESHED'; path=[string]$value.path; payloadHash=[string]$value.payloadHash; entryCount=[int]$value.entryCount }
    }
  } catch {}
  $dirty = Mark-NativeMemorySnapshotDirty 'typed_memory_trial_cache_refresh_failed'
  return [pscustomobject]@{ attempted=$true; ok=$false; cachePending=$true; dirty=[bool]$dirty.ok; dirtyPath=[string]$dirty.path; code='TYPED_MEMORY_TRIAL_CACHE_REFRESH_FAILED'; path=''; payloadHash='' }
}

function Start-Trial {
  $safeInstance = Get-SafeTaskInstanceId $TaskInstanceId
  if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($safeInstance) -or [string]::IsNullOrWhiteSpace($sessionKeyValue)) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SCOPE_REQUIRED'
  }
  $sourcePath = if ([string]::IsNullOrWhiteSpace($CognitiveEvidencePath)) { Join-Path $workspace 'last-cognitive-enforce.json' } else { $CognitiveEvidencePath }
  try {
    if (-not (Test-SuperBrainChildPath $workspace $sourcePath)) { return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SOURCE_OUTSIDE_WORKSPACE' }
  } catch { return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SOURCE_PATH_INVALID' }
  $evidence = Read-JsonFile $sourcePath
  if (-not $evidence -or [string]$evidence.schema -ne 'super-brain.cognitive-enforce.v1') {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_COGNITIVE_EVIDENCE_MISSING'
  }
  $influence = $evidence.memoryInfluence
  if (-not $influence -or $influence.ok -ne $true -or [string]$influence.status -ne 'ready' -or -not $influence.scope) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_MEMORY_INFLUENCE_UNAVAILABLE'
  }
  $scope = [pscustomobject]@{ taskId=[string]$influence.scope.taskId; taskInstanceId=[string]$influence.scope.taskInstanceId; workspaceKey=[string]$influence.scope.workspaceKey; ownerSessionKey=[string]$influence.scope.ownerSessionKey }
  if (-not (Test-ScopedIdentity $scope $TaskId $safeInstance $workspaceKeyValue $sessionKeyValue)) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SCOPE_MISMATCH'
  }
  $refs = Get-MemoryRefs $influence
  if (@($refs).Count -eq 0) {
    return New-TrialResult 'not_applicable' 'inconclusive' 'TYPED_MEMORY_TRIAL_NO_TYPED_REFS'
  }
  $sourceHash = Get-SourceHash $scope $refs
  $path = if ([string]::IsNullOrWhiteSpace($SnapshotPath)) { Get-CanonicalSnapshotPath $safeInstance } else { $SnapshotPath }
  try { if (-not (Test-SuperBrainChildPath $snapshotRoot $path)) { return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_OUTSIDE_ROOT' } } catch { return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_PATH_INVALID' }
  $existing = Read-JsonFile $path
  if ($existing) {
    if ([string]$existing.schema -ne 'super-brain.typed-memory-trial-snapshot.v1' -or [string]$existing.taskInstanceId -ne $safeInstance -or [string]$existing.sourceHash -ne $sourceHash) {
      return New-TrialResult 'conflict' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_CONFLICT' @{ path=$path }
    }
    return New-TrialResult 'reused' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_REUSED' @{ path=$path; sha256=(Get-SuperBrainFileSha256 $path); snapshotHash=$sourceHash; memoryRefs=@($existing.memoryRefs); effects=@($existing.effects); trialState=[string]$existing.trialState }
  }
  $effects = @($refs | ForEach-Object { [pscustomobject]@{ kind=[string]$_.kind; effect=[string]$_.effect } } | Sort-Object kind,effect -Unique)
  $record = [ordered]@{
    schema='super-brain.typed-memory-trial-snapshot.v1'
    taskId=$TaskId
    taskInstanceId=$safeInstance
    workspaceKey=$workspaceKeyValue
    ownerSessionKey=$sessionKeyValue
    packageVersion=[string]$manifest.version
    createdAt=(Get-Date).ToString('o')
    sourceHash=$sourceHash
    memoryRefs=@($refs)
    effects=@($effects)
    trialState='observed'
    privacy=[ordered]@{ rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false }
  }
  try {
    $published = Publish-ImmutableJson $path $record 'TYPED_MEMORY_TRIAL_SNAPSHOT_COLLISION'
    $cache = Refresh-NativeMemoryInfluenceSnapshot
    return New-TrialResult 'captured' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_CAPTURED' @{ path=$path; sha256=[string]$published.sha256; snapshotHash=$sourceHash; memoryRefs=@($refs); effects=@($effects); trialState='observed'; replayed=[bool]$published.replayed; cachePending=[bool]$cache.cachePending; nativeMemorySnapshot=$cache }
  } catch { return New-TrialResult 'conflict' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_WRITE_FAILED' @{ path=$path } }
}

function Get-TaskVerificationPath([string]$Id) { return Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\task-verifications') $Id '.json' }
function Get-VerifiedOutcomePath([string]$Id) {
  $safe = (($Id -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { return '' }
  return Join-Path (Join-Path $workspace 'runtime-state\verified-task-outcomes') ($safe + '.json')
}

function Get-GuardSnapshot([string]$Id) {
  $guardPath = Join-Path $PSScriptRoot 'completion-guard.ps1'
  if (-not (Test-Path -LiteralPath $guardPath -PathType Leaf)) { return [pscustomobject]@{ ok=$false; code='TYPED_MEMORY_TRIAL_COMPLETION_GUARD_MISSING' } }
  try {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guardPath -TaskId $Id -MaxEvidenceAgeMinutes $MaxAgeMinutes -Json 2>$null)
    $exitCode = $LASTEXITCODE
    $value = ConvertFrom-SuperBrainJsonOutput (($raw | ForEach-Object { [string]$_ }) -join "`n") 'typed memory trial completion guard'
    $stable = [ordered]@{ ok=$value.ok; completionAuthorized=$value.completionAuthorized; taskId=[string]$value.taskId; failed=[int]$value.failed; checks=@($value.checks | ForEach-Object { [pscustomobject]@{ name=[string]$_.name; ok=[bool]$_.ok } } | Sort-Object name) }
    return [pscustomobject]@{ ok=($exitCode -eq 0 -and $value.ok -eq $true); available=$true; value=$value; stableHash=(Get-Sha256Text ($stable | ConvertTo-Json -Depth 10 -Compress)); checkedAt=[string]$value.checkedAt; exitCode=$exitCode }
  } catch { return [pscustomobject]@{ ok=$false; code='TYPED_MEMORY_TRIAL_COMPLETION_GUARD_UNAVAILABLE' } }
}

function Resolve-Trial {
  $safeInstance = Get-SafeTaskInstanceId $TaskInstanceId
  if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($safeInstance) -or [string]::IsNullOrWhiteSpace($sessionKeyValue)) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SCOPE_REQUIRED'
  }
  $snapshotPath = if ([string]::IsNullOrWhiteSpace($SnapshotPath)) { Get-CanonicalSnapshotPath $safeInstance } else { $SnapshotPath }
  $snapshot = Read-JsonFile $snapshotPath
  if (-not $snapshot -or [string]$snapshot.schema -ne 'super-brain.typed-memory-trial-snapshot.v1') {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_MISSING' @{ path=$snapshotPath }
  }
  if (-not (Test-ScopedIdentity $snapshot $TaskId $safeInstance $workspaceKeyValue $sessionKeyValue) -or [string]$snapshot.trialState -ne 'observed') {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_SCOPE_INVALID' @{ path=$snapshotPath }
  }
  if (-not $snapshot.privacy -or $snapshot.privacy.rawPromptStored -ne $false -or $snapshot.privacy.rawSummaryStored -ne $false -or $snapshot.privacy.rawTranscriptStored -ne $false -or $snapshot.privacy.memoryBodyStored -ne $false) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_PRIVACY_INVALID' @{ path=$snapshotPath }
  }
  $snapshotRefs = @($snapshot.memoryRefs)
  if (@($snapshotRefs).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$snapshot.sourceHash)) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_CONTENT_MISSING' @{ path=$snapshotPath }
  }
  $recomputedSnapshotHash = Get-SourceHash $snapshot $snapshotRefs
  if ([string]$snapshot.sourceHash -ne $recomputedSnapshotHash) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_SNAPSHOT_HASH_MISMATCH' @{ path=$snapshotPath }
  }
  $expectedEffects = @($snapshotRefs | ForEach-Object { [pscustomobject]@{ kind=[string]$_.kind; effect=[string]$_.effect } } | Sort-Object kind,effect -Unique)
  $actualEffectsJson = @($snapshot.effects | ForEach-Object { [pscustomobject]@{ kind=[string]$_.kind; effect=[string]$_.effect } } | Sort-Object kind,effect -Unique | ConvertTo-Json -Depth 6 -Compress)
  $expectedEffectsJson = @($expectedEffects | ConvertTo-Json -Depth 6 -Compress)
  if (($actualEffectsJson -join '') -ne ($expectedEffectsJson -join '')) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_EFFECTS_MISMATCH' @{ path=$snapshotPath }
  }
  $taskVerificationPath = Get-TaskVerificationPath $TaskId
  $taskVerification = Read-JsonFile $taskVerificationPath
  $outcomePath = Get-VerifiedOutcomePath $TaskId
  $outcome = Read-JsonFile $outcomePath
  if (-not $taskVerification -or [string]$taskVerification.taskId -ne $TaskId -or -not (Test-SuperBrainWorkspaceKey ([string]$taskVerification.workspaceKey) $workspaceKeyValue)) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_TASK_VERIFICATION_MISSING' @{ snapshotPath=$snapshotPath; taskVerificationPath=$taskVerificationPath }
  }
  if (-not $outcome -or [string]$outcome.schema -ne 'super-brain.verified-task-outcome.v1' -or [string]$outcome.taskId -ne $TaskId -or -not (Test-SuperBrainWorkspaceKey ([string]$outcome.workspaceKey) $workspaceKeyValue)) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_VERIFIED_OUTCOME_MISSING' @{ snapshotPath=$snapshotPath; verifiedOutcomePath=$outcomePath }
  }
  if ($taskVerification.PSObject.Properties['evidenceBinding'] -and $taskVerification.evidenceBinding) {
    $bindingStatus = Test-SuperBrainEvidenceBinding -Binding $taskVerification.evidenceBinding -TaskId $TaskId -WorkspaceKey $workspaceKeyValue -OwnerSessionKey $sessionKeyValue -Root $Root
    if ($bindingStatus.ok -ne $true) {
      return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_TASK_EVIDENCE_BINDING_INVALID' @{ reason=[string]$bindingStatus.reason }
    }
  } else {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_TASK_EVIDENCE_BINDING_MISSING'
  }
  if ($outcome.PSObject.Properties['privacy'] -and $outcome.privacy -and ($outcome.privacy.rawPromptStored -ne $false -or $outcome.privacy.rawSummaryStored -ne $false -or ($outcome.privacy.PSObject.Properties['rawTranscriptStored'] -and $outcome.privacy.rawTranscriptStored -ne $false))) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_OUTCOME_PRIVACY_INVALID'
  }
  if (-not $outcome.PSObject.Properties['evidenceBinding'] -or -not $outcome.evidenceBinding) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_OUTCOME_EVIDENCE_BINDING_MISSING'
  }
  $outcomeBindingStatus = Test-SuperBrainEvidenceBinding -Binding $outcome.evidenceBinding -TaskId $TaskId -WorkspaceKey $workspaceKeyValue -OwnerSessionKey $sessionKeyValue -Root $Root
  if ($outcomeBindingStatus.ok -ne $true) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_OUTCOME_EVIDENCE_BINDING_INVALID' @{ reason=[string]$outcomeBindingStatus.reason }
  }
  if (-not (Test-Fresh $taskVerification $MaxAgeMinutes) -or -not (Test-Fresh $outcome $MaxAgeMinutes)) {
    return New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_EVIDENCE_STALE' @{ snapshotPath=$snapshotPath }
  }
  $guard = Get-GuardSnapshot $TaskId
  $guardFresh = ($guard -and $guard.available -eq $true -and $guard.value -and [string]$guard.value.taskId -eq $TaskId -and (Test-Fresh $guard.value $MaxAgeMinutes))
  $guardPass = ($guardFresh -and $guard.ok -eq $true -and $guard.value.ok -eq $true -and $guard.value.completionAuthorized -eq $true)
  $basePositive = (
    $taskVerification.ok -eq $true -and
    $taskVerification.taskScopedGuardOk -eq $true -and
    $taskVerification.userAcceptanceVerification -and
    $taskVerification.userAcceptanceVerification.ok -eq $true -and
    $taskVerification.userAcceptanceVerification.realUserPathVerification -eq $true -and
    $outcome.classification -and $outcome.classification.verifiedRealWorldTask -eq $true -and
    $guardPass
  )
  $explicitNegative = (
    ($taskVerification.userAcceptanceVerification -and ($taskVerification.userAcceptanceVerification.ok -eq $false -or $taskVerification.userAcceptanceVerification.realUserPathVerification -eq $false)) -or
    ($taskVerification.integrationParity -and $taskVerification.integrationParity.unresolvedIntegrationDrift -eq $true) -or
    ($taskVerification.causalReview -and [string]$taskVerification.causalReview.decision -in @('revise','rollback')) -or
    ($taskVerification.completionOutcome -and [string]$taskVerification.completionOutcome.reason -eq 'atomic_completion_failed') -or
    ($outcome.classification -and $outcome.classification.verifiedRealWorldTask -eq $false)
  )
  $verdict = if ($basePositive) { 'passed' } elseif ($explicitNegative -and $guardFresh) { 'failed' } else { 'inconclusive' }
  $code = switch ($verdict) { 'passed' { 'TYPED_MEMORY_TRIAL_PASSED' } 'failed' { 'TYPED_MEMORY_TRIAL_FAILED' } default { 'TYPED_MEMORY_TRIAL_INCONCLUSIVE' } }
  $receiptPath = Get-CanonicalReceiptPath $safeInstance
  $taskHash = Get-SuperBrainFileSha256 $taskVerificationPath
  $outcomeHash = Get-SuperBrainFileSha256 $outcomePath
  $snapshotHash = Get-SuperBrainFileSha256 $snapshotPath
  $guardHash = if ($guardFresh) { [string]$guard.stableHash } else { '' }
  $receiptMaterial = [ordered]@{ taskId=$TaskId; taskInstanceId=$safeInstance; workspaceKey=$workspaceKeyValue; ownerSessionKey=$sessionKeyValue; snapshotHash=$snapshotHash; taskVerificationHash=$taskHash; verifiedOutcomeHash=$outcomeHash; completionGuardHash=$guardHash; verdict=$verdict }
  $receiptHash = Get-Sha256Text ($receiptMaterial | ConvertTo-Json -Depth 10 -Compress)
  $receipt = [ordered]@{
    schema='super-brain.typed-memory-trial-receipt.v1'
    receiptId='typed-memory-trial-' + $safeInstance
    taskId=$TaskId
    taskInstanceId=$safeInstance
    workspaceKey=$workspaceKeyValue
    ownerSessionKey=$sessionKeyValue
    packageVersion=[string]$manifest.version
    createdAt=(Get-Date).ToString('o')
    verdict=$verdict
    trialState='closed'
    receiptHash=$receiptHash
    sourceHashes=[ordered]@{ snapshot=$snapshotHash; taskVerification=$taskHash; verifiedOutcome=$outcomeHash; completionGuard=$guardHash }
    memoryRefs=@($snapshot.memoryRefs)
    effects=@($snapshot.effects)
    checks=[ordered]@{ taskVerification=($taskVerification.ok -eq $true); taskScopedGuard=($taskVerification.taskScopedGuardOk -eq $true); realUserPath=($taskVerification.userAcceptanceVerification -and $taskVerification.userAcceptanceVerification.realUserPathVerification -eq $true); verifiedOutcome=($outcome.classification -and $outcome.classification.verifiedRealWorldTask -eq $true); completionGuard=$guardPass }
    reasonCode=$code
    privacy=[ordered]@{ rawPromptStored=$false; rawSummaryStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false }
  }
  $existing = Read-JsonFile $receiptPath
  if ($existing) {
    if ([string]$existing.schema -ne 'super-brain.typed-memory-trial-receipt.v1' -or [string]$existing.receiptHash -ne $receiptHash) {
      return New-TrialResult 'conflict' 'inconclusive' 'TYPED_MEMORY_TRIAL_RECEIPT_CONFLICT' @{ path=$receiptPath }
    }
    return New-TrialResult 'reused' ([string]$existing.verdict) 'TYPED_MEMORY_TRIAL_RECEIPT_REUSED' @{ path=$receiptPath; sha256=(Get-SuperBrainFileSha256 $receiptPath); receiptId=[string]$existing.receiptId; trialState=[string]$existing.trialState; memoryRefs=@($existing.memoryRefs); effects=@($existing.effects) }
  }
  try {
    $published = Publish-ImmutableJson $receiptPath $receipt 'TYPED_MEMORY_TRIAL_RECEIPT_COLLISION'
    $cache = Refresh-NativeMemoryInfluenceSnapshot
    return New-TrialResult 'evaluated' $verdict $code @{ path=$receiptPath; sha256=[string]$published.sha256; receiptId=[string]$receipt.receiptId; trialState='closed'; memoryRefs=@($receipt.memoryRefs); effects=@($receipt.effects); checks=$receipt.checks; sourceHashes=$receipt.sourceHashes; cachePending=[bool]$cache.cachePending; nativeMemorySnapshot=$cache }
  } catch { return New-TrialResult 'conflict' 'inconclusive' 'TYPED_MEMORY_TRIAL_RECEIPT_WRITE_FAILED' @{ path=$receiptPath } }
}

$result = try {
  if ($Action -eq 'Start') { Start-Trial } else { Resolve-Trial }
} catch {
  New-TrialResult 'inconclusive' 'inconclusive' 'TYPED_MEMORY_TRIAL_INTERNAL_ERROR' @{ error=[string]$_.Exception.Message }
}

if ($Json) { $result | ConvertTo-Json -Depth 14 } else { Write-Host ("TYPED_MEMORY_TRIAL status={0} verdict={1} code={2}" -f $result.status,$result.verdict,$result.code) }
if (-not $NoExit -and $result.status -eq 'conflict') { exit 1 }
exit 0
