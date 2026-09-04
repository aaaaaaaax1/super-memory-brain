[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Record','Commit','CompleteTask','CommitContinuity','CommitActiveBundle','Get','Audit','Rebuild','Reconcile','ReconcileResiduals','ReconcileAmbiguousState','RebindProjectionPaths','Compact','Import')]
  [string]$Action = 'Audit',
  [string]$TaskId = '',
  [ValidateSet('context','checkpoint','task_card')]
  [string]$EntityKind = 'task_card',
  [ValidateSet('upsert','clear')]
  [string]$Operation = 'upsert',
  [string]$EntityPath = '',
  [string]$PayloadPath = '',
  [string]$CompletionManifestPath = '',
  [string]$ContinuityManifestPath = '',
  [string]$ActiveBundleManifestPath = '',
  [int]$ExpectedRevision = -1,
  [string]$Source = 'task-state-store.ps1',
  [string]$OwnerAgentId = '',
  [string]$OwnerSessionId = '',
  [string]$CallerSessionKey = '',
  [string]$OwnerPlatform = '',
  [string]$OwnerWorkspace = '',
  [switch]$MaintenanceOverride,
  [string]$MaintenanceReason = '',
  [string]$LegacyStateRoot = '',
  [string]$ExpectedPlanFingerprint = '',
  [int]$LeaseSeconds = 86400,
  [int]$MaxEventsPerTask = 200,
  [long]$MaxBytesPerTask = 1048576,
  [ValidateSet('none','after_authority','after_prepare','after_materialize','after_commit')]
  [string]$FaultPoint = 'none',
  [int]$FaultAfterMaterialization = 0,
  [string]$WorkspaceRoot = '',
  [string]$SharedRoot = '',
  [switch]$Apply,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$intentResolutionCore = Join-Path $PSScriptRoot 'internal\intent-resolution.ps1'
if (Test-Path -LiteralPath $intentResolutionCore -PathType Leaf) { . $intentResolutionCore }
$phaseCloseoutCore = Join-Path $PSScriptRoot 'internal\phase-closeout-core.ps1'
if (-not (Test-Path -LiteralPath $phaseCloseoutCore -PathType Leaf)) { throw 'TASK_STATE_PHASE_CLOSEOUT_CORE_MISSING' }
. $phaseCloseoutCore

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace' }
if ([string]::IsNullOrWhiteSpace($SharedRoot)) { $SharedRoot = Get-SuperBrainSharedMemoryRoot $Root }
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
$SharedRoot = [IO.Path]::GetFullPath($SharedRoot)
$storeRoot = Join-Path $WorkspaceRoot 'task-state-store'
$eventRoot = Join-Path $storeRoot 'events'
$projectionRoot = Join-Path $storeRoot 'projections'
$stagingRoot = Join-Path $storeRoot 'staging'
$snapshotRoot = Join-Path $storeRoot 'snapshots'
$archiveRoot = Join-Path $storeRoot 'archive'
$completionArchiveRoot = Join-Path $storeRoot 'completion-archive'
$quarantineRoot = Join-Path $storeRoot 'quarantine'
$rebindReceiptRoot = Join-Path $storeRoot 'projection-path-rebinds'
$indexPath = Join-Path $storeRoot 'index.json'
$mutationGate = Join-Path $storeRoot 'mutation-gate'
foreach ($dir in @($WorkspaceRoot,$SharedRoot,$storeRoot,$eventRoot,$projectionRoot,$stagingRoot,$snapshotRoot,$archiveRoot,$rebindReceiptRoot)) {
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

function Limit-Text([string]$Value,[int]$Max=300) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = $Value.Trim() -replace '\s+',' '
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Get-ShortHash([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Value))[0..7] | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Read-JsonFile([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-FileSha256([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return '' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return '' }
}

function Invoke-TaskAuthorityControl([ValidateSet('prepare-task','import-task','apply-task','locate-task','pending-task-outbox','task-projection-snapshots','acknowledge-legacy-task-outbox','record-task-delivery','materialize-outbox')][string]$Action,[object]$Request) {
  $python = Get-Command python -ErrorAction SilentlyContinue
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  if (-not $python -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_UNAVAILABLE'; error='BrainControl Python runtime is unavailable.' }
  }
  $pythonPath = [string]$python.Source
  if ([string]::IsNullOrWhiteSpace($pythonPath)) { $pythonPath = [string]$python.Name }
  $stateRoot = Split-Path -Parent $WorkspaceRoot
  try {
    if ($Action -in @('pending-task-outbox','task-projection-snapshots','materialize-outbox')) {
      $raw = @(& $pythonPath -X utf8 -B $runtime --state-root $stateRoot $Action 2>&1)
    } elseif ($Action -eq 'acknowledge-legacy-task-outbox') {
      $arguments = @('-B',$runtime,'--state-root',$stateRoot,$Action)
      foreach ($eventId in @($Request.eventId)) { if (-not [string]::IsNullOrWhiteSpace([string]$eventId)) { $arguments += @('--event-id',[string]$eventId) } }
      $raw = @(& $pythonPath -X utf8 @arguments 2>&1)
    } else {
      $json = $Request | ConvertTo-Json -Depth 24 -Compress
      $raw = @($json | & $pythonPath -X utf8 -B $runtime --state-root $stateRoot $Action 2>&1)
    }
    $exitCode = $LASTEXITCODE
    $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
    if (-not $value) { return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_EMPTY_RESPONSE'; error=$text } }
    if ($exitCode -ne 0 -or $value.ok -ne $true) { return [pscustomobject]@{ ok=$false; code=if($value.PSObject.Properties['code']){[string]$value.code}else{'TASK_STATE_SQLITE_AUTHORITY_FAILED'}; error=if($value.PSObject.Properties['error']){[string]$value.error}else{$text}; value=$value } }
    return $value
  } catch {
    return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_FAILED'; error=$_.Exception.Message }
  }
}

function New-TaskAuthorityProjectionEnvelope([string]$Id,[string]$WorkspaceKey,[object]$Entities,[object]$Lifecycle,[object[]]$Commands,[int]$TaskRevision,[string]$TransactionKind,[object]$RecoveryEvidence=$null) {
  $bundle = @()
  foreach ($command in @($Commands)) {
    $payloadText = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$command.payloadPath) -and (Test-Path -LiteralPath ([string]$command.payloadPath) -PathType Leaf)) {
      $payloadText = [IO.File]::ReadAllText([string]$command.payloadPath,[Text.UTF8Encoding]::new($false))
    }
    $entry = [ordered]@{}
    foreach ($property in @($command.PSObject.Properties)) {
      if ([string]$property.Name -eq 'payloadPath') { continue }
      $entry[[string]$property.Name] = $property.Value
    }
    $entry['payloadText'] = $payloadText
    $bundle += [pscustomobject]$entry
  }
  return [pscustomobject]@{
    schema='super-brain.task-projection.v1'; taskId=$Id; workspaceKey=$WorkspaceKey; transactionKind=$TransactionKind; taskStateRevision=$TaskRevision; entities=$Entities; lifecycle=$Lifecycle; recoveryEvidence=$RecoveryEvidence; commands=@($bundle)
  }
}

function New-TaskAuthorityProjectionState([string]$Id,[object]$Contract,[object]$Entities,[object]$Lifecycle,[int]$TaskRevision) {
  return [pscustomobject]@{
    lifecycle=[string]$Lifecycle.status; contractRevision=if($Contract){[int]$Contract.revision}else{[int]$Lifecycle.contractRevision}; planFingerprint=if($Contract){[string]$Contract.planReceipt.planFingerprint}else{[string]$Lifecycle.planFingerprint}
    currentPhase=if($Contract){[string]$Contract.currentPhase}else{''}; currentStep=if($Contract){[string]$Contract.currentStep}else{''}; nextAction=if($Contract){[string]$Contract.nextAction}else{''}
    completedSteps=if($Contract){@($Contract.completedSteps)}else{@()}; pendingSteps=if($Contract){@($Contract.pendingSteps)}else{@()}; blockers=if($Contract){@($Contract.blockers)}else{@()}; evidence=if($Contract){@($Contract.evidence)}else{@()}
    verificationResults=if($Contract -and $Contract.PSObject.Properties['verificationResults']){@($Contract.verificationResults)}else{@()}; constraints=if($Contract -and $Contract.PSObject.Properties['constraints']){@($Contract.constraints)}else{@()}; acceptanceCriteria=if($Contract -and $Contract.PSObject.Properties['acceptanceCriteria']){@($Contract.acceptanceCriteria)}else{@()}
    canonicalPlan=if($Contract -and $Contract.PSObject.Properties['canonicalPlan']){$Contract.canonicalPlan}else{$null}; workLineStatus=if($Contract -and $Contract.PSObject.Properties['workLineStatus']){$Contract.workLineStatus}else{$null}
    entities=$Entities; taskStateRevision=$TaskRevision
  }
}

function Ensure-TaskAuthorityAggregate([string]$Id,[object]$Contract,[object]$Projection,[int]$Revision,[string]$Source,[object]$TaskSessionRebind=$null) {
  $scope = [ordered]@{
    taskId=$Id; taskInstanceId=[string]$Contract.taskInstanceId; workspaceKey=[string]$Contract.workspaceKey; ownerSessionKey=[string]$Contract.ownerSessionKey; packageVersion=[string]$Contract.packageVersion
  }
  if ($TaskSessionRebind) { $scope.taskSessionRebind = $TaskSessionRebind }
  $prepared = Invoke-TaskAuthorityControl 'prepare-task' $scope
  if (-not $prepared.ok) { return $prepared }
  if ($null -eq $prepared.state) {
    $state = New-TaskAuthorityProjectionState $Id $Contract $Projection.entities $Projection.lifecycle $Revision
    $seed = [ordered]@{
      commandId=('task-import-' + (Get-SuperBrainStableHash ($Id + '|' + $scope.workspaceKey + '|' + $Revision + '|' + [string]$Projection.lastEventId) 48)); initialRevision=$Revision; source=(Limit-Text $Source 120); state=$state
    }
    foreach ($key in $scope.Keys) { $seed[$key]=$scope[$key] }
    $imported = Invoke-TaskAuthorityControl 'import-task' $seed
    if (-not $imported.ok) { return $imported }
    $prepared = Invoke-TaskAuthorityControl 'prepare-task' $scope
  }
  if (-not $prepared.ok -or [int]$prepared.expectedRevision -ne $Revision) {
    return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_REVISION_MISMATCH'; expectedRevision=$Revision; actualRevision=if($prepared){[int]$prepared.expectedRevision}else{-1} }
  }
  return $prepared
}

function Apply-TaskAuthorityTransition([string]$Id,[object]$Contract,[object]$Projection,[object]$Entities,[object]$Lifecycle,[object[]]$Commands,[int]$ActualRevision,[string]$Source,[string]$TransactionKind,[string]$TransactionSeed,[object]$RecoveryEvidence=$null,[object]$TaskSessionRebind=$null) {
  $ready = Ensure-TaskAuthorityAggregate $Id $Contract $Projection $ActualRevision $Source $TaskSessionRebind
  if (-not $ready.ok) { return $ready }
  $state = New-TaskAuthorityProjectionState $Id $Contract $Entities $Lifecycle ($ActualRevision+1)
  $projectionEnvelope = New-TaskAuthorityProjectionEnvelope $Id ([string]$Contract.workspaceKey) $Entities $Lifecycle $Commands ($ActualRevision+1) $TransactionKind $RecoveryEvidence
  $scope = [ordered]@{
    commandId=('task-apply-' + (Get-SuperBrainStableHash ($Id + '|' + [string]$Contract.workspaceKey + '|' + $ActualRevision + '|' + $TransactionSeed) 48)); expectedRevision=$ActualRevision
    taskId=$Id; taskInstanceId=[string]$Contract.taskInstanceId; workspaceKey=[string]$Contract.workspaceKey; ownerSessionKey=[string]$Contract.ownerSessionKey; packageVersion=[string]$Contract.packageVersion
    source=(Limit-Text $Source 120); state=$state; projection=$projectionEnvelope
  }
  if ($TaskSessionRebind) { $scope.taskSessionRebind = $TaskSessionRebind }
  return Invoke-TaskAuthorityControl 'apply-task' $scope
}

function Acknowledge-TaskAuthorityOutbox([string]$EventId) {
  if ([string]::IsNullOrWhiteSpace($EventId)) { return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_OUTBOX_REQUIRED' } }
  $pending = @((Get-PendingTaskAuthorityOutbox) | Where-Object { [string]$_.eventId -eq $EventId })
  if ($pending.Count -eq 0) {
    $known = @((Get-TaskAuthorityProjectionSnapshots) | Where-Object { [string]$_.eventId -eq $EventId })
    if ($known.Count -eq 1 -and [string]$known[0].status -eq 'materialized') {
      return [pscustomobject]@{ ok=$true; materialized=1; idempotent=$true; eventId=$EventId }
    }
    return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_OUTBOX_NOT_PENDING'; eventId=$EventId }
  }
  if ($pending.Count -ne 1) { return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_OUTBOX_AMBIGUOUS'; eventId=$EventId } }
  $outbox = $pending[0]
  if ([int]$outbox.deliveryVersion -eq 0) {
    return Invoke-TaskAuthorityControl 'acknowledge-legacy-task-outbox' ([ordered]@{ eventId=@($EventId) })
  }
  $payload = $outbox.payload
  $taskId = [string]$payload.taskId
  $projectionPath = Get-ProjectionPath $taskId
  $projectionHash = Get-FileSha256 $projectionPath
  if ([string]::IsNullOrWhiteSpace($taskId) -or [string]::IsNullOrWhiteSpace($projectionHash)) {
    return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_PROJECTION_RECEIPT_MISSING'; eventId=$EventId }
  }
  $delivery = Invoke-TaskAuthorityControl 'record-task-delivery' ([ordered]@{
    eventId=$EventId; taskId=$taskId; workspaceKey=[string]$payload.workspaceKey; revision=[int]$payload.revision
    projectionPath=$projectionPath; projectionHash=$projectionHash; source='task-state-store.ps1'
  })
  if (-not $delivery.ok) { return $delivery }
  $snapshot = Invoke-TaskAuthorityControl 'materialize-outbox' $null
  if (-not $snapshot.ok) { return $snapshot }
  $confirmed = @((Get-TaskAuthorityProjectionSnapshots) | Where-Object { [string]$_.eventId -eq $EventId })
  if ($confirmed.Count -ne 1 -or [string]$confirmed[0].status -ne 'materialized') {
    return [pscustomobject]@{ ok=$false; code='TASK_STATE_SQLITE_AUTHORITY_OUTBOX_SNAPSHOT_PENDING'; eventId=$EventId; delivery=$delivery; snapshot=$snapshot }
  }
  return [pscustomobject]@{ ok=$true; materialized=1; idempotent=[bool]$delivery.idempotent; eventId=$EventId; delivery=$delivery; snapshot=$snapshot }
}

function Get-PendingTaskAuthorityOutbox {
  $result = Invoke-TaskAuthorityControl 'pending-task-outbox' $null
  if (-not $result.ok) { throw ('TASK_STATE_SQLITE_AUTHORITY_OUTBOX_READ_FAILED code=' + [string]$result.code + ' error=' + (Limit-Text ([string]$result.error) 240)) }
  return @($result.events)
}

function Get-TaskAuthorityProjectionSnapshots {
  $result = Invoke-TaskAuthorityControl 'task-projection-snapshots' $null
  if (-not $result.ok) {
    if ([string]$result.code -eq 'TASK_STATE_SQLITE_AUTHORITY_UNAVAILABLE') { return @() }
    throw ('TASK_STATE_SQLITE_AUTHORITY_SNAPSHOT_READ_FAILED code=' + [string]$result.code + ' error=' + (Limit-Text ([string]$result.error) 240))
  }
  return @($result.snapshots)
}

function Get-ExistingTaskAuthorityContract([string]$Id,[string]$WorkspaceKey,[object]$ProgressSource=$null) {
  $lookupKeys = [System.Collections.Generic.List[string]]::new()
  foreach ($candidate in @($WorkspaceKey, $(if($ProgressSource -and $ProgressSource.PSObject.Properties['workspaceKey']){[string]$ProgressSource.workspaceKey}else{''}))) {
    $value = ([string]$candidate).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    if (-not @($lookupKeys | Where-Object { [string]::Equals($_,$value,[StringComparison]::OrdinalIgnoreCase) }).Count) { [void]$lookupKeys.Add($value) }
  }
  $matches = @()
  foreach ($lookupKey in @($lookupKeys)) {
    $request = [ordered]@{ taskId=$Id; workspaceKey=$lookupKey }
    $located = Invoke-TaskAuthorityControl 'locate-task' $request
    if (-not $located.ok) {
      throw ('TASK_STATE_SQLITE_AUTHORITY_LOCATE_FAILED code=' + [string]$located.code + ' error=' + (Limit-Text ([string]$located.error) 240))
    }
    if ($located.PSObject.Properties['ambiguous'] -and $located.ambiguous -eq $true) { throw ('TASK_STATE_SQLITE_AUTHORITY_AMBIGUOUS taskId=' + $Id + ' matchCount=' + [string]$located.matchCount) }
    if ($located.found -and $located.state) { $matches += [pscustomobject]@{ lookupKey=$lookupKey; located=$located } }
  }
  if ($matches.Count -eq 0) { return $null }
  $aggregateIds = @($matches | ForEach-Object { [string]$_.located.aggregateId } | Select-Object -Unique)
  if ($aggregateIds.Count -ne 1) { throw ('TASK_STATE_SQLITE_AUTHORITY_WORKSPACE_ALIAS_CONFLICT taskId=' + $Id + ' aggregateCount=' + [string]$aggregateIds.Count) }
  $located = $matches[0].located
  $state = $located.state
  $contract = [pscustomobject]@{
    taskId=$Id; taskInstanceId=[string]$located.taskInstanceId; workspaceKey=[string]$located.workspaceKey; ownerSessionKey=[string]$located.ownerSessionKey; packageVersion=[string]$located.packageVersion
    revision=[int]$state.contractRevision; planReceipt=[pscustomobject]@{ planFingerprint=[string]$state.planFingerprint }
    currentPhase=[string]$state.currentPhase; currentStep=[string]$state.currentStep; nextAction=[string]$state.nextAction
    completedSteps=@($state.completedSteps); pendingSteps=@($state.pendingSteps); blockers=@($state.blockers); evidence=@($state.evidence); verificationResults=@($state.verificationResults); constraints=@($state.constraints); acceptanceCriteria=@($state.acceptanceCriteria)
    canonicalPlan=if($state.PSObject.Properties['canonicalPlan']){$state.canonicalPlan}else{$null}; workLineStatus=if($state.PSObject.Properties['workLineStatus']){$state.workLineStatus}else{$null}
  }
  if ($ProgressSource) {
    foreach ($field in @('currentPhase','currentStep','nextAction','completedSteps','pendingSteps','blockers','evidence','verificationResults')) {
      if ($ProgressSource.PSObject.Properties[$field]) { $contract.$field = $ProgressSource.$field }
    }
  }
  return [pscustomobject]@{ contract=$contract; revision=[int]$located.revision; stateHash=[string]$located.stateHash; aggregateId=[string]$located.aggregateId; state=$state }
}

function New-CompatibilityCompletionAuthorityContract(
  [string]$Id,
  [string]$WorkspaceKey,
  [object]$Manifest,
  [object]$CompletedCheckpoint,
  [object]$CompletedTaskCard
) {
  # Legacy checkpoint completion is allowed only behind an explicit maintenance
  # override. It still needs a stable identity before it can enter SQLite authority.
  $checkpoint = if ($CompletedCheckpoint -and $CompletedCheckpoint.PSObject.Properties['value']) { $CompletedCheckpoint.value } else { $null }
  $taskCard = if ($CompletedTaskCard -and $CompletedTaskCard.PSObject.Properties['value']) { $CompletedTaskCard.value } else { $null }
  $sessionCandidate = if ($checkpoint -and $checkpoint.PSObject.Properties['sessionId']) { [string]$checkpoint.sessionId } elseif ($taskCard -and $taskCard.PSObject.Properties['sessionId']) { [string]$taskCard.sessionId } else { '' }
  $ownerSessionKey = Get-SuperBrainLocalSessionKey $sessionCandidate
  if ([string]::IsNullOrWhiteSpace($ownerSessionKey)) { throw 'TASK_STATE_COMPATIBILITY_AUTHORITY_SESSION_REQUIRED' }
  $resolvedWorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  $instanceCandidate = if ($Manifest -and $Manifest.PSObject.Properties['expectedTaskInstanceId']) { [string]$Manifest.expectedTaskInstanceId } else { '' }
  $taskInstanceId = if ($instanceCandidate -match '^ti-[a-f0-9]{32}$') { $instanceCandidate } else { 'ti-' + (Get-SuperBrainStableHash ('compatibility-completion|' + $Id + '|' + $resolvedWorkspaceKey + '|' + $ownerSessionKey) 32) }
  $planCandidate = if ($Manifest -and $Manifest.PSObject.Properties['expectedPlanFingerprint']) { [string]$Manifest.expectedPlanFingerprint } else { '' }
  $planFingerprint = if ($planCandidate -match '^[a-f0-9]{64}$') { $planCandidate } else { Get-SuperBrainStableHash ('compatibility-plan|' + $Id + '|' + $resolvedWorkspaceKey + '|' + $taskInstanceId) 64 }
  $source = if ($checkpoint) { $checkpoint } else { $taskCard }
  return [pscustomobject]@{
    taskId = $Id
    taskInstanceId = $taskInstanceId
    workspaceKey = $resolvedWorkspaceKey
    ownerSessionKey = $ownerSessionKey
    packageVersion = [string](Get-SuperBrainManifest $Root).version
    revision = 0
    planReceipt = [pscustomobject]@{ planFingerprint=$planFingerprint }
    currentPhase = if ($source -and $source.PSObject.Properties['currentPhase']) { [string]$source.currentPhase } else { '' }
    currentStep = if ($source -and $source.PSObject.Properties['currentStep']) { [string]$source.currentStep } else { '' }
    nextAction = if ($source -and $source.PSObject.Properties['nextAction']) { [string]$source.nextAction } else { '' }
    completedSteps = if ($source -and $source.PSObject.Properties['completedSteps']) { @($source.completedSteps) } else { @() }
    pendingSteps = @()
    blockers = @()
    evidence = if ($source -and $source.PSObject.Properties['evidence']) { @($source.evidence) } else { @() }
    verificationResults = @()
    constraints = if ($source -and $source.PSObject.Properties['acceptedConstraints']) { @($source.acceptedConstraints) } else { @() }
    acceptanceCriteria = @()
    canonicalPlan = $null
    workLineStatus = $null
    compatibilityAuthority = $true
  }
}

function Test-TaskAuthorityEntityParity([object]$AuthorityState,[string]$Kind,[object]$Entity) {
  $expected = Get-EntityValue $AuthorityState $Kind
  if (($null -eq $expected) -xor ($null -eq $Entity)) { return $false }
  if ($null -eq $expected) { return $true }
  foreach ($field in @('path','hash','status')) {
    if (-not [string]::Equals([string]$expected.$field,[string]$Entity.$field,[StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
}

function Test-TaskAuthorityProjectionStateParity([object]$Projection,[object]$AuthorityBinding) {
  if (-not $Projection -or -not $AuthorityBinding -or -not $AuthorityBinding.state) { return $false }
  $projection = Ensure-ProjectionShape $Projection ([string]$Projection.taskId)
  $state = $AuthorityBinding.state
  if ([int]$projection.revision -ne [int]$AuthorityBinding.revision -or [int]$state.taskStateRevision -ne [int]$projection.revision) { return $false }
  foreach ($kind in @('context','checkpoint','task_card')) {
    if (-not (Test-TaskAuthorityEntityParity $state $kind (Get-EntityValue $projection $kind))) { return $false }
  }
  foreach ($pair in @(
    @([string]$projection.lifecycle.status,[string]$state.lifecycle),
    @([string]$projection.lifecycle.workspaceKey,[string]$state.workspaceKey),
    @([string]$projection.lifecycle.ownerSessionKey,[string]$state.ownerSessionKey),
    @([string]$projection.lifecycle.planFingerprint,[string]$state.planFingerprint),
    @([string]$projection.lifecycle.contractRevision,[string]$state.contractRevision)
  )) {
    if (-not [string]::Equals([string]$pair[0],[string]$pair[1],[StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
}

function Test-ChildPath([string]$Parent,[string]$Child) {
  try {
    $prefix = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    return [IO.Path]::GetFullPath($Child).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function Assert-EntityTarget([string]$Kind,[string]$Path,[string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'TASK_STATE_ENTITY_PATH_REQUIRED' }
  return Get-SuperBrainCanonicalTaskStateEntityPath $Id $Kind $WorkspaceRoot $SharedRoot $Path -RequireCanonical
}

function Get-ProjectionPath([string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
  return Get-SuperBrainCanonicalTaskPath $projectionRoot $Id '.json'
}

function Get-EventPath([string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
  return Get-SuperBrainCanonicalTaskPath $eventRoot $Id '.jsonl'
}

function New-Projection([string]$Id) {
  return [pscustomobject]@{
    schema = 'super-brain.task-state-projection.v2'
    taskId = $Id
    revision = 0
    updatedAt = ''
    lastEventId = ''
    entities = [pscustomobject]@{ context=$null; checkpoint=$null; task_card=$null }
    lifecycle = [pscustomobject]@{
      status = 'unknown'
      workspaceKey = ''
      ownerSessionKey = ''
      planFingerprint = ''
      contractRevision = 0
      completionTransactionId = ''
      completedAt = ''
      evidenceBinding = $null
      quarantineTransactionId = ''
      quarantinedAt = ''
      quarantineReason = ''
      quarantineManifestPath = ''
      quarantineManifestHash = ''
      source = ''
    }
  }
}

function Ensure-ProjectionShape([object]$Projection,[string]$Id) {
  if (-not $Projection) { return New-Projection $Id }
  if ($Projection.PSObject.Properties['taskId'] -and [string]$Projection.taskId -ne $Id) { throw "TASK_STATE_IDENTITY_MISMATCH expected=$Id actual=$($Projection.taskId)" }
  if (-not $Projection.PSObject.Properties['taskId']) { $Projection | Add-Member -NotePropertyName taskId -NotePropertyValue $Id -Force }
  if (-not $Projection.PSObject.Properties['entities']) { $Projection | Add-Member -NotePropertyName entities -NotePropertyValue ([pscustomobject]@{}) -Force }
  foreach ($name in @('context','checkpoint','task_card')) {
    if (-not $Projection.entities.PSObject.Properties[$name]) { $Projection.entities | Add-Member -NotePropertyName $name -NotePropertyValue $null -Force }
  }
  if (-not $Projection.PSObject.Properties['lifecycle'] -or -not $Projection.lifecycle) {
    $Projection | Add-Member -NotePropertyName lifecycle -NotePropertyValue ([pscustomobject]@{ status='unknown'; workspaceKey=''; ownerSessionKey=''; planFingerprint=''; contractRevision=0; completionTransactionId=''; completedAt=''; evidenceBinding=$null; quarantineTransactionId=''; quarantinedAt=''; quarantineReason=''; quarantineManifestPath=''; quarantineManifestHash=''; source='' }) -Force
  }
  foreach ($entry in @(@('status','unknown'),@('workspaceKey',''),@('ownerSessionKey',''),@('planFingerprint',''),@('contractRevision',0),@('completionTransactionId',''),@('completedAt',''),@('evidenceBinding',$null),@('quarantineTransactionId',''),@('quarantinedAt',''),@('quarantineReason',''),@('quarantineManifestPath',''),@('quarantineManifestHash',''),@('source',''))) {
    if (-not $Projection.lifecycle.PSObject.Properties[$entry[0]]) { $Projection.lifecycle | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1] -Force }
  }
  return $Projection
}

function Get-EntityValue([object]$Projection,[string]$Kind) {
  if (-not $Projection -or -not $Projection.entities) { return $null }
  $property = $Projection.entities.PSObject.Properties[$Kind]
  if ($property) { return $property.Value }
  return $null
}

function Set-EntityValue([object]$Projection,[string]$Kind,[object]$Value) {
  $Projection.entities | Add-Member -NotePropertyName $Kind -NotePropertyValue $Value -Force
}

function Get-TaskLifecycleStatusFromEntityStatus([string]$Status) {
  $normalized = ([string]$Status).Trim().ToLowerInvariant()
  if ($normalized -eq 'blocked') { return 'blocked' }
  if ($normalized -in @('paused','waiting')) { return 'paused' }
  if ($normalized -in @('active','running','in_progress')) { return 'active' }
  return ''
}

function Update-ProjectionLifecycleFromEntities([object]$Projection,[string]$Source) {
  $Projection = Ensure-ProjectionShape $Projection ([string]$Projection.taskId)
  if ([string]$Projection.lifecycle.status -in @('completed','cancelled','archived','quarantined')) { return $Projection.lifecycle }
  $statuses = @()
  foreach ($kind in @('checkpoint','task_card','context')) {
    $entity = Get-EntityValue $Projection $kind
    if ($entity) { $statuses += Get-TaskLifecycleStatusFromEntityStatus ([string]$entity.status) }
  }
  $statuses = @($statuses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  $next = if ($statuses -contains 'blocked') { 'blocked' } elseif ($statuses -contains 'active') { 'active' } elseif ($statuses -contains 'paused') { 'paused' } else { 'unknown' }
  $Projection.lifecycle.status = $next
  $Projection.lifecycle.source = Limit-Text $Source 120
  return $Projection.lifecycle
}

function New-OwnerRecord([object]$Value,[string]$AgentId,[string]$SessionId,[string]$Platform,[string]$Workspace,[int]$Seconds,[string]$Status) {
  if ($Value) {
    if ([string]::IsNullOrWhiteSpace($AgentId) -and $Value.PSObject.Properties['agentId']) { $AgentId = [string]$Value.agentId }
    if ([string]::IsNullOrWhiteSpace($SessionId) -and $Value.PSObject.Properties['sessionId']) { $SessionId = [string]$Value.sessionId }
    if ([string]::IsNullOrWhiteSpace($Platform) -and $Value.PSObject.Properties['platform']) { $Platform = [string]$Value.platform }
    if ([string]::IsNullOrWhiteSpace($Workspace) -and $Value.PSObject.Properties['workspace']) { $Workspace = [string]$Value.workspace }
  }
  $AgentId = ConvertTo-SuperBrainTaskStateAgentId $AgentId $Platform
  $active = $Status -in @('active','running','in_progress','paused','waiting','blocked')
  $leaseUntil = if ($active -and $Seconds -gt 0) { (Get-Date).AddSeconds($Seconds).ToString('o') } else { '' }
  $fingerprint = Get-ShortHash ((@($AgentId,$SessionId,$Platform,$Workspace) | ForEach-Object { ([string]$_).ToLowerInvariant() }) -join '|')
  return [pscustomobject]@{ agentId=Limit-Text $AgentId 120; sessionId=Limit-Text $SessionId 160; platform=Limit-Text $Platform 80; workspace=Limit-Text $Workspace 260; fingerprint=$fingerprint; leaseUntil=$leaseUntil }
}

function Test-OwnerComplete([object]$Owner) {
  if (-not $Owner) { return $false }
  foreach ($name in @('agentId','sessionId','platform','workspace')) {
    if (-not $Owner.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$Owner.$name)) { return $false }
  }
  return $true
}

function Test-OwnerMatch([object]$Expected,[object]$Actual) {
  if (-not (Test-OwnerComplete $Expected) -or -not (Test-OwnerComplete $Actual)) { return $false }
  $expectedAgentId = ConvertTo-SuperBrainTaskStateAgentId ([string]$Expected.agentId) ([string]$Expected.platform)
  $actualAgentId = ConvertTo-SuperBrainTaskStateAgentId ([string]$Actual.agentId) ([string]$Actual.platform)
  if (-not [string]::Equals($expectedAgentId,$actualAgentId,[System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  foreach ($name in @('sessionId','platform','workspace')) {
    if (-not [string]::Equals([string]$Expected.$name,[string]$Actual.$name,[System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
}

function Test-OwnerSessionRebind([object]$Previous,[object]$Next,[string]$PreviousSessionKey,[string]$NextSessionKey) {
  if (-not (Test-OwnerComplete $Previous) -or -not (Test-OwnerComplete $Next)) { return $false }
  if ([string]::IsNullOrWhiteSpace($PreviousSessionKey) -or [string]::IsNullOrWhiteSpace($NextSessionKey)) { return $false }
  # Older Desktop projections may retain the raw host thread id while the
  # contract has already normalized it to sid-*. A rebind may upgrade only
  # when that raw id deterministically resolves to the recorded old owner.
  $previousOwnerKey = Get-SuperBrainLocalSessionKey ([string]$Previous.sessionId)
  if (-not [string]::Equals($previousOwnerKey,$PreviousSessionKey,[System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  if (-not [string]::Equals([string]$Next.sessionId,$NextSessionKey,[System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  $previousAgentId = ConvertTo-SuperBrainTaskStateAgentId ([string]$Previous.agentId) ([string]$Previous.platform)
  $nextAgentId = ConvertTo-SuperBrainTaskStateAgentId ([string]$Next.agentId) ([string]$Next.platform)
  if (-not [string]::Equals($previousAgentId,$nextAgentId,[System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  foreach ($name in @('platform','workspace')) {
    if (-not [string]::Equals([string]$Previous.$name,[string]$Next.$name,[System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
}

function New-MaintenanceAudit([string]$ActionName,[string]$Reason,[string]$Writer) {
  if ([string]::IsNullOrWhiteSpace($Reason)) { throw "TASK_STATE_MAINTENANCE_REASON_REQUIRED action=$ActionName" }
  return [pscustomobject]@{
    override = $true
    action = $ActionName
    reason = Limit-Text $Reason 220
    source = Limit-Text $Writer 120
    requestedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  }
}

function Assert-MutationAuthority([int]$Expected,[object]$Owner,[object]$Previous,[switch]$Override,[string]$Reason,[string]$ActionName,[string]$Writer) {
  if ($Override) { return New-MaintenanceAudit $ActionName $Reason $Writer }
  if ($Expected -lt 0) { throw "TASK_STATE_REVISION_REQUIRED taskId=$TaskId" }
  if (-not (Test-OwnerComplete $Owner)) { throw "TASK_STATE_OWNER_REQUIRED taskId=$TaskId" }
  if ($Previous) {
    if (-not $Previous.PSObject.Properties['owner'] -or -not (Test-OwnerComplete $Previous.owner)) { throw "TASK_STATE_OWNER_UNVERIFIED taskId=$TaskId" }
    if (-not (Test-OwnerMatch $Owner $Previous.owner)) { throw "TASK_STATE_OWNER_MISMATCH taskId=$TaskId" }
  }
  return $null
}

function Read-Entity([string]$Path,[string]$Id) {
  $full = [IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "TASK_STATE_ENTITY_NOT_FOUND path=$full" }
  $value = Read-JsonFile $full
  if (-not $value) { throw "TASK_STATE_ENTITY_JSON_INVALID path=$full" }
  if ($value.PSObject.Properties['taskId'] -and -not [string]::IsNullOrWhiteSpace([string]$value.taskId) -and [string]$value.taskId -ne $Id) { throw "TASK_STATE_IDENTITY_MISMATCH expected=$Id actual=$($value.taskId)" }
  $status = if ($value.PSObject.Properties['status']) { [string]$value.status } elseif ($value.PSObject.Properties['action']) { [string]$value.action } else { '' }
  return [pscustomobject]@{ path=$full; hash=Get-FileSha256 $full; status=Limit-Text $status 80; value=$value }
}

function Read-Payload([string]$Path,[string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'TASK_STATE_PAYLOAD_PATH_REQUIRED' }
  $full = [IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "TASK_STATE_PAYLOAD_NOT_FOUND path=$full" }
  $item = Get-Item -LiteralPath $full
  if ($item.Length -gt 262144) { throw "TASK_STATE_PAYLOAD_TOO_LARGE bytes=$($item.Length)" }
  $value = Read-JsonFile $full
  if (-not $value) { throw "TASK_STATE_PAYLOAD_JSON_INVALID path=$full" }
  if (-not $value.PSObject.Properties['taskId'] -or [string]$value.taskId -ne $Id) { throw "TASK_STATE_IDENTITY_MISMATCH expected=$Id actual=$($value.taskId)" }
  $status = if ($value.PSObject.Properties['status']) { [string]$value.status } elseif ($value.PSObject.Properties['action']) { [string]$value.action } else { '' }
  return [pscustomobject]@{ path=$full; hash=Get-FileSha256 $full; status=Limit-Text $status 80; value=$value }
}

function New-IndexSummary([object]$Projection) {
  $entityKinds = @()
  foreach ($name in @('context','checkpoint','task_card')) { if ($null -ne (Get-EntityValue $Projection $name)) { $entityKinds += $name } }
  return [pscustomobject]@{ taskId=[string]$Projection.taskId; revision=[int]$Projection.revision; updatedAt=[string]$Projection.updatedAt; entityKinds=@($entityKinds); projectionPath=Get-ProjectionPath ([string]$Projection.taskId) }
}

function Update-Index([object]$Projection) {
  $index = Read-JsonFile $indexPath
  $tasks = @()
  if ($index -and $index.tasks) { $tasks += @($index.tasks | Where-Object { [string]$_.taskId -ne [string]$Projection.taskId }) }
  $tasks += New-IndexSummary $Projection
  $tasks = @($tasks | Sort-Object updatedAt -Descending | Select-Object -First 500)
  $value = [pscustomobject]@{ schema='super-brain.task-state-index.v2'; updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); taskCount=$tasks.Count; maxTasks=500; tasks=$tasks }
  Write-JsonUtf8NoBom $indexPath $value 8
  return $value
}

function Add-StateEvent([string]$Id,[object]$Event) {
  Add-Utf8LineLocked (Get-EventPath $Id) ($Event | ConvertTo-Json -Depth 12 -Compress)
}

function Get-TaskStateTemporaryPath([string]$Target,[string]$TransactionId,[string]$Kind) {
  $directory = Split-Path -Parent $Target
  $targetKey = [IO.Path]::GetFullPath($Target)
  $token = Get-SuperBrainStableHash ($TransactionId + '|' + $Kind + '|' + $targetKey) 16
  return Join-Path $directory ('.ts-' + $token + '.tmp')
}

function Materialize-Payload([string]$Payload,[string]$Target,[string]$TransactionId) {
  $dir = Split-Path -Parent $Target
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $text = [IO.File]::ReadAllText($Payload,[Text.Encoding]::UTF8)
  $temp = Get-TaskStateTemporaryPath $Target $TransactionId 'payload'
  try {
    [IO.File]::WriteAllText($temp,$text,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Target -Force
    return Get-FileSha256 $Target
  } finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  }
}

function Test-TaskStateMaterializationFaultInjected([string]$ErrorMessage) {
  # FaultAfterMaterialization is an intentional crash simulation, not a
  # materializer validation failure.  Keep the marker centralized so every
  # transaction entry point preserves its prepared WAL for explicit replay.
  return ([string]$ErrorMessage -like 'TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZATION*')
}

function Get-TaskMaterializationRollbackRoot([string]$Id,[string]$TransactionId) {
  $token = Get-SuperBrainCanonicalTaskToken $Id
  $root = Join-Path (Join-Path $stagingRoot $token) ('rollback-' + (Get-SuperBrainStableHash $TransactionId 24))
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
  return $root
}

function New-TaskMaterializationBackup([object]$Command,[string]$Id,[string]$WorkspaceKey,[string]$TransactionId,[int]$Ordinal) {
  $target = Assert-CompletionCommandTarget $Command $Id $WorkspaceKey
  $rollbackRoot = Get-TaskMaterializationRollbackRoot $Id $TransactionId
  $beforeExists = Test-Path -LiteralPath $target -PathType Leaf
  $beforePath = Join-Path $rollbackRoot ('before-{0:D4}.bin' -f $Ordinal)
  $beforeHash = ''
  if ($beforeExists) {
    $item = Get-Item -LiteralPath $target -ErrorAction Stop
    if ($item.Length -gt 1048576) { throw "TASK_STATE_MATERIALIZATION_BACKUP_TOO_LARGE role=$($Command.role) bytes=$($item.Length)" }
    Copy-Item -LiteralPath $target -Destination $beforePath -Force
    $beforeHash = Get-FileSha256 $target
    if ([string]::IsNullOrWhiteSpace($beforeHash) -or (Get-FileSha256 $beforePath) -ne $beforeHash) { throw "TASK_STATE_MATERIALIZATION_BACKUP_HASH_MISMATCH role=$($Command.role)" }
  }
  return [pscustomobject]@{
    targetPath = $target
    beforeExists = [bool]$beforeExists
    beforePath = if ($beforeExists) { $beforePath } else { '' }
    beforeHash = $beforeHash
    rollbackRoot = $rollbackRoot
    expectedAfterExists = if ([string]$Command.operation -in @('clear','delete_identity','archive_identity','quarantine_identity')) { $false } elseif ([string]$Command.operation -in @('conditional_pointer','upsert','replace_if_hash') -and -not $Command.payloadPath) { $false } else { $true }
    expectedAfterHash = if ($Command.PSObject.Properties['payloadHash']) { [string]$Command.payloadHash } else { '' }
    role = [string]$Command.role
    ordinal = $Ordinal
  }
}

function Restore-TaskMaterialization([object[]]$Records) {
  $restoreErrors = @()
  foreach ($record in @($Records | Sort-Object ordinal -Descending)) {
    try {
      $target = [IO.Path]::GetFullPath([string]$record.targetPath)
      $currentExists = Test-Path -LiteralPath $target -PathType Leaf
      $currentHash = if ($currentExists) { Get-FileSha256 $target } else { '' }
      # A command that threw before returning has no trustworthy post-state.
      # Only treat it as a safe no-op when the target is still byte-identical
      # to the pre-transaction state; otherwise fail closed and leave the
      # prepared transaction for explicit reconciliation instead of guessing
      # which writer owns the current bytes.
      if ($record.PSObject.Properties['postStateKnown'] -and -not [bool]$record.postStateKnown) {
        $matchesBefore = ([bool]$record.beforeExists -eq $currentExists) -and
          (-not $currentExists -or [string]::Equals($currentHash,[string]$record.beforeHash,[StringComparison]::OrdinalIgnoreCase))
        if (-not $matchesBefore) { throw 'rollback_post_state_unknown' }
        continue
      }
      # A rollback may only overwrite a target that is still in the exact
      # post-command state recorded by the transaction.  In particular,
      # distinguish an externally removed target from a target that was
      # intentionally materialized and is now ready to restore.  Without the
      # existence check below a concurrent delete could be silently replaced
      # by an older backup, losing an unrelated writer's change.
      if ($record.PSObject.Properties['expectedAfterExists'] -and [bool]$record.expectedAfterExists -ne $currentExists) { throw 'rollback_target_changed' }
      if ($record.PSObject.Properties['expectedAfterExists'] -and [bool]$record.expectedAfterExists -and
          $record.PSObject.Properties['expectedAfterHash'] -and -not [string]::IsNullOrWhiteSpace([string]$record.expectedAfterHash) -and
          $currentHash -ne [string]$record.expectedAfterHash) { throw 'rollback_target_changed' }
      if ([bool]$record.beforeExists) {
        $backup = [IO.Path]::GetFullPath([string]$record.beforePath)
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-FileSha256 $backup) -ne [string]$record.beforeHash) { throw 'backup_missing_or_changed' }
        if ($currentExists -and $currentHash -ne [string]$record.beforeHash) {
          $matchesPostState = $record.PSObject.Properties['expectedAfterExists'] -and [bool]$record.expectedAfterExists -and
            $record.PSObject.Properties['expectedAfterHash'] -and -not [string]::IsNullOrWhiteSpace([string]$record.expectedAfterHash) -and
            $currentHash -eq [string]$record.expectedAfterHash
          if (-not $matchesPostState) { throw 'rollback_target_changed' }
        }
        $temp = Get-TaskStateTemporaryPath $target ('rollback-' + [string]$record.ordinal) 'restore'
        try {
          [IO.File]::Copy($backup,$temp,$true)
          Move-Item -LiteralPath $temp -Destination $target -Force
        } finally {
          if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        if ((Get-FileSha256 $target) -ne [string]$record.beforeHash) { throw 'restore_hash_mismatch' }
      } elseif ($currentExists) {
        Remove-Item -LiteralPath $target -Force
      }
    } catch {
      $restoreErrors += ([string]$record.role + ':' + [string]$_.Exception.Message)
    }
  }
  if ($restoreErrors.Count -gt 0) { throw ('TASK_STATE_MATERIALIZATION_ROLLBACK_FAILED ' + ($restoreErrors -join '; ')) }
}

function Restore-TaskMaterializationSafely([object[]]$Records) {
  $items = @($Records)
  if ($items.Count -eq 0) {
    return [pscustomobject]@{ attempted=$false; verified=$true; error='' }
  }
  try {
    Restore-TaskMaterialization $items
    return [pscustomobject]@{ attempted=$true; verified=$true; error='' }
  } catch {
    return [pscustomobject]@{ attempted=$true; verified=$false; error=$_.Exception.Message }
  }
}

function Materialize-ProjectionPathRebindTarget([string]$Source,[string]$Target,[string]$ExpectedHash,[string]$TransactionId) {
  if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Target) -or [string]::IsNullOrWhiteSpace($ExpectedHash)) { throw 'TASK_STATE_REBIND_MATERIALIZATION_INPUT_REQUIRED' }
  if ((Get-FileSha256 $Source) -ne $ExpectedHash) { throw 'TASK_STATE_REBIND_MATERIALIZATION_SOURCE_CHANGED' }
  $targetFull = [IO.Path]::GetFullPath($Target)
  if (Test-Path -LiteralPath $targetFull -PathType Leaf) {
    if ((Get-FileSha256 $targetFull) -ne $ExpectedHash) { throw 'TASK_STATE_REBIND_MATERIALIZATION_TARGET_CONFLICT' }
    return [pscustomobject]@{ path=$targetFull; hash=$ExpectedHash; created=$false }
  }
  $dir = Split-Path -Parent $targetFull
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $temp = Get-TaskStateTemporaryPath $targetFull $TransactionId 'rebind'
  try {
    [IO.File]::Copy($Source,$temp,$true)
    try { [IO.File]::Move($temp,$targetFull) }
    catch {
      if (-not (Test-Path -LiteralPath $targetFull -PathType Leaf) -or (Get-FileSha256 $targetFull) -ne $ExpectedHash) { throw }
    }
    if ((Get-FileSha256 $targetFull) -ne $ExpectedHash) { throw 'TASK_STATE_REBIND_MATERIALIZATION_HASH_MISMATCH' }
    return [pscustomobject]@{ path=$targetFull; hash=$ExpectedHash; created=$true }
  } finally {
    if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  }
}

function Remove-StagingPayload([string]$Path) {
  if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-ChildPath $stagingRoot $Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)) { Remove-Item -LiteralPath $Path -Force }
}

function Commit-Projection([object]$Projection,[string]$Id,[string]$Kind,[string]$Op,[object]$EntityRecord,[int]$Revision,[string]$EventId,[string]$When) {
  Set-EntityValue $Projection $Kind $EntityRecord
  $null = Update-ProjectionLifecycleFromEntities $Projection 'entity-commit'
  $Projection.revision = $Revision
  $Projection.updatedAt = $When
  $Projection.lastEventId = $EventId
  Write-JsonUtf8NoBom (Get-ProjectionPath $Id) $Projection 10
  $null = Update-Index $Projection
}

function Assert-NoIncompleteTaskTransaction([string]$Id,[switch]$AllowParityRepair) {
  $events = @(Read-Events)
  $pending = @(Get-IncompleteTransactions $events | Where-Object { [string]$_.taskId -eq $Id })
  if ($pending.Count -gt 0) { throw "TASK_STATE_PENDING_TRANSACTION_REQUIRES_RECONCILE taskId=$Id count=$($pending.Count)" }
  $parity = Get-ProjectionParity $events $Id -SkipIndex
  if (-not $parity.ok -and -not $AllowParityRepair) { throw "TASK_STATE_PROJECTION_PARITY_REQUIRES_RECONCILE taskId=$Id projectionGaps=$($parity.projectionGapCount)" }
}

function Record-Entity([string]$Id,[string]$Kind,[string]$Op,[string]$Path,[int]$Expected,[string]$Writer,[switch]$Override,[string]$Reason) {
  if ([string]::IsNullOrWhiteSpace($Id)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  if (-not $Override) { throw 'TASK_STATE_MAINTENANCE_OVERRIDE_REQUIRED action=Record' }
  $maintenance = New-MaintenanceAudit 'Record' $Reason $Writer
  $entity = if ($Op -eq 'upsert') { Read-Entity $Path $Id } else { [pscustomobject]@{ path=if($Path){[IO.Path]::GetFullPath($Path)}else{''}; hash=''; status='cleared'; value=$null } }
  return Invoke-SuperBrainFileLock $mutationGate {
    Assert-NoIncompleteTaskTransaction $Id -AllowParityRepair:$Override
    $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $Id)) $Id
    $actualRevision = [int]$projection.revision
    if ($Expected -ge 0 -and $Expected -ne $actualRevision) { throw "TASK_STATE_CAS_MISMATCH expected=$Expected actual=$actualRevision taskId=$Id" }
    $workspaceKey = if ($entity.value -and $entity.value.PSObject.Properties['workspaceKey']) { Get-SuperBrainWorkspaceKey ([string]$entity.value.workspaceKey) } else { Get-SuperBrainWorkspaceKey ([string]$projection.lifecycle.workspaceKey) }
    if (Get-ExistingTaskAuthorityContract $Id $workspaceKey $entity.value) { throw "TASK_STATE_RECORD_CANONICAL_AUTHORITY_EXISTS_USE_COMMIT taskId=$Id" }
    $previous = Get-EntityValue $projection $Kind
    $same = if ($Op -eq 'clear') { $null -eq $previous } elseif ($previous) { [string]$previous.path -eq [string]$entity.path -and [string]$previous.hash -eq [string]$entity.hash -and [string]$previous.status -eq [string]$entity.status } else { $false }
    if ($same) { return [pscustomobject]@{ ok=$true; changed=$false; taskId=$Id; revision=$actualRevision; entityKind=$Kind; operation=$Op; projectionPath=Get-ProjectionPath $Id; eventPath=Get-EventPath $Id } }
    $nextRevision = $actualRevision + 1
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $eventId = [guid]::NewGuid().ToString('n')
    $owner = New-OwnerRecord $entity.value '' '' '' '' $LeaseSeconds $entity.status
    $entityRecord = if ($Op -eq 'clear') { $null } else { [pscustomobject]@{ path=$entity.path; hash=$entity.hash; status=$entity.status; source=Limit-Text $Writer 120; owner=$owner } }
    $event = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionId=''; eventId=$eventId; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entityKind=$Kind; operation=$Op; entity=$entityRecord; maintenance=$maintenance; source=Limit-Text $Writer 120; recordedAt=$now }
    Add-StateEvent $Id $event
    Commit-Projection $projection $Id $Kind $Op $entityRecord $nextRevision $eventId $now
    return [pscustomobject]@{ ok=$true; changed=$true; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entityKind=$Kind; operation=$Op; projectionPath=Get-ProjectionPath $Id; eventPath=Get-EventPath $Id; eventId=$eventId; mode='maintenance-record'; maintenanceOverride=$true; maintenanceReason=$maintenance.reason }
  }
}

function Get-ProjectionPathRebindTarget([string]$SourcePath,[string]$LegacyRoot) {
  if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($LegacyRoot)) { return '' }
  $sourceFull = [IO.Path]::GetFullPath($SourcePath)
  $legacyFull = [IO.Path]::GetFullPath($LegacyRoot)
  foreach ($mapping in @(
    [pscustomobject]@{ sourceRoot=(Join-Path $legacyFull 'workspace'); targetRoot=$WorkspaceRoot },
    [pscustomobject]@{ sourceRoot=(Join-Path $legacyFull 'shared'); targetRoot=$SharedRoot }
  )) {
    $sourceRoot = [IO.Path]::GetFullPath([string]$mapping.sourceRoot)
    if (-not (Test-ChildPath $sourceRoot $sourceFull)) { continue }
    $suffix = $sourceFull.Substring($sourceRoot.Length).TrimStart([char[]]@('\','/'))
    if ([string]::IsNullOrWhiteSpace($suffix)) { return '' }
    $target = [IO.Path]::GetFullPath((Join-Path ([string]$mapping.targetRoot) $suffix))
    if (-not (Test-ChildPath ([string]$mapping.targetRoot) $target)) { return '' }
    return $target
  }
  return ''
}

function Test-ProjectionPathRebindCompletionConflict([object]$Projection) {
  $context = Get-EntityValue $Projection 'context'
  $checkpoint = Get-EntityValue $Projection 'checkpoint'
  $taskCard = Get-EntityValue $Projection 'task_card'
  $contextActive = ($context -and [string]$context.status -eq 'active')
  $checkpointTerminal = ($checkpoint -and [string]$checkpoint.status -in @('completed','verified','cancelled','archived'))
  $taskCardTerminal = ($taskCard -and [string]$taskCard.status -in @('completed','verified','cancelled','archived'))
  return ($contextActive -and $checkpointTerminal -and $taskCardTerminal)
}

function Get-ProjectionPathRebindFingerprint([string]$LegacyRoot,[object[]]$Candidates) {
  $parts = @(
    'projection-path-rebind.v2',
    [IO.Path]::GetFullPath($LegacyRoot),
    $WorkspaceRoot,
    $SharedRoot
  )
  foreach ($candidate in @($Candidates | Sort-Object taskId,entityKind,sourcePath)) {
    $parts += (@(
      [string]$candidate.taskId,
      [string]$candidate.entityKind,
      [string]$candidate.projectionRevision,
      [string]$candidate.sourcePath,
      [string]$candidate.expectedHash,
      [string]$candidate.expectedStatus,
      [string]$candidate.materializationSourcePath,
      [string]$candidate.materializationSourceHash,
      [string]$candidate.materializationRequired,
      [string]$candidate.targetPath,
      [string]$candidate.targetHash
    ) -join [char]31)
  }
  return Get-SuperBrainStableHash ($parts -join "`n") 64
}

function Get-ProjectionPathRebindPlan([string]$LegacyRoot) {
  if ([string]::IsNullOrWhiteSpace($LegacyRoot)) { throw 'TASK_STATE_LEGACY_ROOT_REQUIRED action=RebindProjectionPaths' }
  $legacyFull = [IO.Path]::GetFullPath($LegacyRoot)
  if ([string]::Equals($legacyFull,$WorkspaceRoot,[StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($legacyFull,$SharedRoot,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'TASK_STATE_LEGACY_ROOT_MUST_DIFFER_FROM_CURRENT_ROOTS'
  }

  $storeEvents = @(Read-Events)
  $storeParity = Get-ProjectionParity $storeEvents
  $incompleteTransactions = @(Get-IncompleteTransactions $storeEvents)
  $candidates = @()
  $skipped = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $projectionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $raw = Read-JsonFile $file.FullName
    if (-not $raw) {
      $candidates += [pscustomobject]@{ taskId=''; entityKind=''; lifecycleStatus=''; projectionPath=$file.FullName; projectionRevision=-1; sourcePath=''; expectedHash=''; expectedStatus=''; materializationSourcePath=''; materializationSourceHash=''; materializationRequired=$false; targetPath=''; targetHash=''; ready=$false; reason='projection_json_invalid' }
      continue
    }
    try { $projection = Ensure-ProjectionShape $raw ([string]$raw.taskId) }
    catch {
      $candidates += [pscustomobject]@{ taskId=[string]$raw.taskId; entityKind=''; lifecycleStatus=''; projectionPath=$file.FullName; projectionRevision=-1; sourcePath=''; expectedHash=''; expectedStatus=''; materializationSourcePath=''; materializationSourceHash=''; materializationRequired=$false; targetPath=''; targetHash=''; ready=$false; reason='projection_identity_invalid' }
      continue
    }
    $lifecycleStatus = ([string]$projection.lifecycle.status).ToLowerInvariant()
    if ($lifecycleStatus -notin @('active','paused','blocked')) {
      $skipped += [pscustomobject]@{ taskId=[string]$projection.taskId; projectionPath=$file.FullName; lifecycleStatus=$lifecycleStatus; reason='terminal_or_nonactive_projection' }
      continue
    }
    $completionConflict = Test-ProjectionPathRebindCompletionConflict $projection
    foreach ($kind in @('context','checkpoint','task_card')) {
      $entity = Get-EntityValue $projection $kind
      if (-not $entity) { continue }
      $source = [string]$entity.path
      if (-not (Test-ChildPath $legacyFull $source)) { continue }
      $candidate = [pscustomobject]@{
        taskId=[string]$projection.taskId
        entityKind=$kind
        lifecycleStatus=$lifecycleStatus
        projectionPath=$file.FullName
        projectionRevision=[int]$projection.revision
        sourcePath=$source
        expectedHash=[string]$entity.hash
        expectedStatus=[string]$entity.status
        materializationSourcePath=''
        materializationSourceHash=''
        materializationRequired=$false
        targetPath=''
        targetHash=''
        ready=$false
        reason=''
      }
      if ($completionConflict) {
        $candidate.reason = 'completion_evidence_conflict'
        $candidates += $candidate
        continue
      }
      $target = Get-ProjectionPathRebindTarget $source $legacyFull
      if ([string]::IsNullOrWhiteSpace($target)) {
        $candidate.reason = 'legacy_path_outside_supported_state_roots'
        $candidates += $candidate
        continue
      }
      try {
        $canonicalTarget = Get-SuperBrainCanonicalTaskStateEntityPath $candidate.taskId $kind $WorkspaceRoot $SharedRoot $target
      } catch {
        $candidate.reason = 'rebind_target_outside_canonical_roots'
        $candidates += $candidate
        continue
      }
      $candidate.materializationSourcePath = $target
      $candidate.targetPath = $canonicalTarget
      if ([string]::IsNullOrWhiteSpace($candidate.expectedHash)) {
        $candidate.reason = 'projection_hash_missing'
        $candidates += $candidate
        continue
      }
      if (-not (Test-Path -LiteralPath $candidate.materializationSourcePath -PathType Leaf)) {
        $candidate.reason = 'rebind_materialization_source_missing'
        $candidates += $candidate
        continue
      }
      try { $sourceEntity = Read-Entity $candidate.materializationSourcePath $candidate.taskId }
      catch {
        $candidate.reason = 'rebind_materialization_source_invalid'
        $candidates += $candidate
        continue
      }
      $candidate.materializationSourceHash = [string]$sourceEntity.hash
      if (-not [string]::Equals($candidate.expectedHash,$candidate.materializationSourceHash,[StringComparison]::OrdinalIgnoreCase)) {
        $candidate.reason = 'rebind_materialization_source_hash_mismatch'
        $candidates += $candidate
        continue
      }
      if (-not [string]::Equals($candidate.expectedStatus,[string]$sourceEntity.status,[StringComparison]::OrdinalIgnoreCase)) {
        $candidate.reason = 'rebind_materialization_source_status_mismatch'
        $candidates += $candidate
        continue
      }
      if (Test-Path -LiteralPath $candidate.targetPath -PathType Leaf) {
        try { $targetEntity = Read-Entity $candidate.targetPath $candidate.taskId }
        catch {
          $candidate.reason = 'rebind_canonical_target_invalid'
          $candidates += $candidate
          continue
        }
        $candidate.targetHash = [string]$targetEntity.hash
        if (-not [string]::Equals($candidate.expectedHash,$candidate.targetHash,[StringComparison]::OrdinalIgnoreCase)) {
          $candidate.reason = 'rebind_canonical_target_hash_mismatch'
          $candidates += $candidate
          continue
        }
        if (-not [string]::Equals($candidate.expectedStatus,[string]$targetEntity.status,[StringComparison]::OrdinalIgnoreCase)) {
          $candidate.reason = 'rebind_canonical_target_status_mismatch'
          $candidates += $candidate
          continue
        }
      } else {
        $candidate.materializationRequired = $true
      }
      $candidate.ready = $true
      $candidates += $candidate
    }
  }

  foreach ($group in @($candidates | Where-Object { $_.ready } | Group-Object { ([string]$_.targetPath).ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })) {
    foreach ($candidate in @($group.Group)) {
      $candidate.ready = $false
      $candidate.reason = 'rebind_target_collision'
    }
  }
  $ready = @($candidates | Where-Object { $_.ready })
  $blocked = @($candidates | Where-Object { -not $_.ready })
  $deferred = @($blocked | Where-Object { $_.reason -eq 'completion_evidence_conflict' })
  $invalid = @($blocked | Where-Object { $_.reason -ne 'completion_evidence_conflict' })
  $taskPlans = @($ready | Group-Object taskId | ForEach-Object {
    $taskCandidates = @($_.Group | Sort-Object entityKind)
    [pscustomobject]@{ taskId=[string]$_.Name; projectionPath=[string]$taskCandidates[0].projectionPath; projectionRevision=[int]$taskCandidates[0].projectionRevision; candidates=$taskCandidates }
  } | Sort-Object taskId)
  $fingerprint = Get-ProjectionPathRebindFingerprint $legacyFull $ready
  return [pscustomobject]@{
    legacyStateRoot=$legacyFull
    candidateCount=$candidates.Count
    readyCount=$ready.Count
    blockedCount=$blocked.Count
    deferredCount=$deferred.Count
    invalidCount=$invalid.Count
    taskCount=$taskPlans.Count
    planFingerprint=$fingerprint
    storeParity=$storeParity
    incompleteTransactionCount=$incompleteTransactions.Count
    incompleteTransactions=@($incompleteTransactions | ForEach-Object { [pscustomobject]@{ taskId=[string]$_.taskId; transactionId=[string]$_.transactionId; transactionKind=if($_.PSObject.Properties['transactionKind']){[string]$_.transactionKind}else{''}; targetRevision=[int]$_.targetRevision } })
    candidates=@($candidates)
    ready=@($ready)
    blocked=@($blocked)
    deferred=@($deferred)
    invalid=@($invalid)
    taskPlans=@($taskPlans)
    skipped=@($skipped)
    guard='Only active, paused, or blocked projection entities under the explicit legacy workspace/shared roots are eligible. Each target must be a strict canonical entity path, retain the projected SHA-256 and status, parse as the same task, and have no target collision. Completion-evidence conflicts are deferred for independent reconciliation; terminal and unrelated projections are not touched.'
  }
}

function Copy-ProjectionPathRebindValue([AllowNull()][object]$Value) {
  if ($null -eq $Value) { return $null }
  $json = ConvertTo-Json -InputObject $Value -Depth 16
  return ConvertFrom-Json -InputObject $json
}

function Assert-ProjectionPathRebindCandidate([object]$Projection,[object]$Candidate) {
  $current = Get-EntityValue $Projection $Candidate.entityKind
  if (-not $current -or -not [string]::Equals([string]$current.path,[string]$Candidate.sourcePath,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$current.hash,[string]$Candidate.expectedHash,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$current.status,[string]$Candidate.expectedStatus,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'TASK_STATE_REBIND_SOURCE_CHANGED'
  }
  $canonical = Get-SuperBrainCanonicalTaskStateEntityPath $Candidate.taskId $Candidate.entityKind $WorkspaceRoot $SharedRoot $Candidate.materializationSourcePath
  if (-not [string]::Equals($canonical,[string]$Candidate.targetPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_REBIND_TARGET_NOT_CANONICAL' }
  $source = Read-Entity $Candidate.materializationSourcePath $Candidate.taskId
  if (-not [string]::Equals([string]$source.hash,[string]$Candidate.expectedHash,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$source.status,[string]$Candidate.expectedStatus,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'TASK_STATE_REBIND_MATERIALIZATION_SOURCE_CHANGED'
  }
  if (Test-Path -LiteralPath $canonical -PathType Leaf) {
    $target = Read-Entity $canonical $Candidate.taskId
    if (-not [string]::Equals([string]$target.hash,[string]$Candidate.expectedHash,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$target.status,[string]$Candidate.expectedStatus,[StringComparison]::OrdinalIgnoreCase)) {
      throw 'TASK_STATE_REBIND_TARGET_CHANGED'
    }
    return [pscustomobject]@{ path=$canonical; sourcePath=[string]$Candidate.materializationSourcePath; hash=[string]$target.hash; status=[string]$target.status; materializationRequired=$false }
  }
  return [pscustomobject]@{ path=$canonical; sourcePath=[string]$Candidate.materializationSourcePath; hash=[string]$source.hash; status=[string]$source.status; materializationRequired=$true }
}

function Commit-ProjectionPathRebindTask([object]$TaskPlan,[string]$PlanFingerprint,[string]$LegacyRoot,[string]$Writer,[object]$Maintenance) {
  $id = [string]$TaskPlan.taskId
  return Invoke-SuperBrainFileLock $mutationGate {
    Assert-NoIncompleteTaskTransaction $id
    $projection = Ensure-ProjectionShape (Read-JsonFile ([string]$TaskPlan.projectionPath)) $id
    if ([int]$projection.revision -ne [int]$TaskPlan.projectionRevision) { throw 'TASK_STATE_REBIND_PROJECTION_REVISION_CHANGED' }
    $beforeLifecycle = [string]$projection.lifecycle.status
    if ($beforeLifecycle -notin @('active','paused','blocked')) { throw 'TASK_STATE_REBIND_LIFECYCLE_NOT_ACTIVE' }
    if (Test-ProjectionPathRebindCompletionConflict $projection) { throw 'TASK_STATE_REBIND_COMPLETION_EVIDENCE_CONFLICT' }

    $entities = [pscustomobject]@{
      context=(Copy-ProjectionPathRebindValue (Get-EntityValue $projection 'context'))
      checkpoint=(Copy-ProjectionPathRebindValue (Get-EntityValue $projection 'checkpoint'))
      task_card=(Copy-ProjectionPathRebindValue (Get-EntityValue $projection 'task_card'))
    }
    $rebindRecords = @()
    foreach ($candidate in @($TaskPlan.candidates | Sort-Object entityKind)) {
      $target = Assert-ProjectionPathRebindCandidate $projection $candidate
      $nextEntity = Copy-ProjectionPathRebindValue (Get-EntityValue $projection $candidate.entityKind)
      if ($null -eq $nextEntity) { throw "TASK_STATE_REBIND_ENTITY_COPY_FAILED kind=$($candidate.entityKind)" }
      $nextEntity.path = $target.path
      $nextEntity.hash = $target.hash
      $nextEntity.status = $target.status
      $nextEntity.source = Limit-Text $Writer 120
      $entities | Add-Member -NotePropertyName $candidate.entityKind -NotePropertyValue $nextEntity -Force
      $rebindRecords += [pscustomobject]@{ entityKind=$candidate.entityKind; sourcePath=$candidate.sourcePath; materializationSourcePath=$target.sourcePath; targetPath=$target.path; hash=$target.hash; status=$target.status; materializationRequired=[bool]$target.materializationRequired }
    }
    $lifecycle = Copy-ProjectionPathRebindValue $projection.lifecycle
    $previousRevision = [int]$projection.revision
    $nextRevision = $previousRevision + 1
    $transactionId = [guid]::NewGuid().ToString('n')
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $workspaceKey = Get-SuperBrainWorkspaceKey ([string]$lifecycle.workspaceKey)
    $authority = $null
    $authorityBinding = Get-ExistingTaskAuthorityContract $id $workspaceKey $projection.lifecycle
    if ($authorityBinding) {
      if (-not (Test-TaskAuthorityProjectionStateParity $projection $authorityBinding)) { throw 'TASK_STATE_REBIND_SQLITE_AUTHORITY_PARITY_REQUIRED' }
      $authorityCommands = @($rebindRecords | ForEach-Object {
        $role = switch ([string]$_.entityKind) { 'context' {'current_context'} 'checkpoint' {'active_checkpoint'} 'task_card' {'active_task_card'} default { throw "TASK_STATE_ENTITY_KIND_INVALID kind=$($_.entityKind)" } }
        [pscustomobject]@{
          role=$role; operation='replace_if_hash'; targetPath=[string]$_.targetPath; payloadPath=[string]$_.materializationSourcePath; payloadHash=[string]$_.hash
          expectedTargetHash=Get-FileSha256 ([string]$_.targetPath); expectedTaskId=$id; expectedWorkspaceKey=$workspaceKey; applyWhenMissing=$false
        }
      })
      $authority = Apply-TaskAuthorityTransition $id $authorityBinding.contract $projection $entities $lifecycle $authorityCommands $previousRevision $Writer 'projection_path_rebind' ($PlanFingerprint + '|' + $transactionId)
      if (-not $authority.ok) { throw ('TASK_STATE_SQLITE_AUTHORITY_APPLY_FAILED code=' + [string]$authority.code + ' error=' + (Limit-Text ([string]$authority.error) 240)) }
    }
    $rebind = [pscustomobject]@{ schema='super-brain.projection-path-rebind.v2'; planFingerprint=$PlanFingerprint; legacyStateRoot=[IO.Path]::GetFullPath($LegacyRoot); sourceLifecycle=$beforeLifecycle; records=@($rebindRecords); materialization=@(); destructiveDeleteUsed=$false; authorityAggregateId=if($authority){[string]$authority.aggregateId}else{''}; authorityRevision=if($authority){[int]$authority.revision}else{0}; authorityStateHash=if($authority){[string]$authority.stateHash}else{''}; authorityOutboxEventId=if($authority){[string]$authority.outboxEventId}else{''} }
    if ($FaultPoint -eq 'after_authority') {
      if (-not $authority) { throw 'TASK_STATE_SQLITE_AUTHORITY_NOT_INITIALIZED' }
      throw 'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY'
    }
    $prepare = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='prepared'; transactionKind='projection_path_rebind'; transactionId=$transactionId; eventId=[guid]::NewGuid().ToString('n'); taskId=$id; revision=0; targetRevision=$nextRevision; previousRevision=$previousRevision; entities=$entities; lifecycle=$lifecycle; rebind=$rebind; authorityOutboxEventId=if($authority){[string]$authority.outboxEventId}else{''}; authorityStateHash=if($authority){[string]$authority.stateHash}else{''}; maintenance=$Maintenance; source=Limit-Text $Writer 120; recordedAt=$now }
    Add-StateEvent $id $prepare
    if ($FaultPoint -eq 'after_prepare') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_PREPARE' }
    $materialization = @()
    $materializedCount = 0
    $durableCommit = $false
    try {
      foreach ($candidate in @($TaskPlan.candidates | Sort-Object entityKind)) {
        $target = Assert-ProjectionPathRebindCandidate $projection $candidate
        if ($target.materializationRequired) {
          $role = switch ([string]$candidate.entityKind) {
            'context' { 'current_context' }
            'checkpoint' { 'active_checkpoint' }
            'task_card' { 'active_task_card' }
            default { throw "TASK_STATE_ENTITY_KIND_INVALID kind=$($candidate.entityKind)" }
          }
          $backupCommand = [pscustomobject]@{
            role=$role; operation='replace_if_hash'; targetPath=[string]$target.path; payloadPath=[string]$target.sourcePath; payloadHash=[string]$target.hash; expectedTargetHash=Get-FileSha256 ([string]$target.path)
            expectedTaskId=$id; expectedWorkspaceKey=$workspaceKey
          }
          $backup = New-TaskMaterializationBackup $backupCommand $id $workspaceKey $transactionId (@($materialization).Count + 1)
          $materializedRecord = [pscustomobject]@{
            targetPath=[string]$backup.targetPath; beforeExists=[bool]$backup.beforeExists; beforePath=[string]$backup.beforePath
            beforeHash=[string]$backup.beforeHash; rollbackRoot=[string]$backup.rollbackRoot
            expectedAfterExists=[bool]$backup.expectedAfterExists; expectedAfterHash=[string]$backup.expectedAfterHash
            role=[string]$backup.role; ordinal=[int]$backup.ordinal; action='pending'; changed=$false
          }
          $materialization += $materializedRecord
          $result = Materialize-ProjectionPathRebindTarget $target.sourcePath $target.path $target.hash $transactionId
          foreach ($property in @($result.PSObject.Properties)) {
            if ($property.Name -in @('targetPath','beforeExists','beforePath','beforeHash','rollbackRoot','expectedAfterExists','expectedAfterHash','role','ordinal')) { continue }
            $materializedRecord | Add-Member -NotePropertyName ([string]$property.Name) -NotePropertyValue $property.Value -Force
          }
          $materializedRecord | Add-Member -NotePropertyName afterHash -NotePropertyValue (Get-FileSha256 ([string]$materializedRecord.targetPath)) -Force
          $materializedCount++
          if ($FaultAfterMaterialization -gt 0 -and $materializedCount -eq $FaultAfterMaterialization) { throw "TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZATION boundary=$materializedCount" }
        }
      }
      if ($FaultPoint -eq 'after_materialize') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZE' }
      foreach ($candidate in @($TaskPlan.candidates)) { $null = Assert-ProjectionPathRebindCandidate $projection $candidate }
      $rebind.materialization = @($materialization)
      $eventId = [guid]::NewGuid().ToString('n')
      $committedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
      $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind='projection_path_rebind'; transactionId=$transactionId; authorityOutboxEventId=if($authority){[string]$authority.outboxEventId}else{''}; authorityStateHash=if($authority){[string]$authority.stateHash}else{''}; eventId=$eventId; taskId=$id; revision=$nextRevision; previousRevision=$previousRevision; entities=$entities; lifecycle=$lifecycle; rebind=$rebind; maintenance=$Maintenance; source=Limit-Text $Writer 120; recordedAt=$committedAt }
      Add-StateEvent $id $commit
      $durableCommit = $true
      if ($FaultPoint -eq 'after_commit') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_COMMIT' }
      Commit-TaskCompletionProjection $projection $id $entities $lifecycle $nextRevision $eventId $committedAt
      if ($authority) {
        $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$authority.outboxEventId)
        if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_SQLITE_AUTHORITY_OUTBOX_ACK_FAILED' }
      }
      Remove-TaskCompletionStaging @() '' $materialization
      return [pscustomobject]@{ ok=$true; taskId=$id; transactionId=$transactionId; revision=$nextRevision; previousRevision=$previousRevision; entityCount=$rebindRecords.Count; materializedCount=$materialization.Count; records=@($rebindRecords); materialization=@($materialization); authorityMode=if($authority){'sqlite'}else{'deferred_until_task_authority'}; authorityRevision=if($authority){[int]$authority.revision}else{0}; projectionPath=Get-ProjectionPath $id; eventPath=Get-EventPath $id; guard='All eligible entity pointers for this task were rebound in one recoverable transaction. Existing SQLite authority commits first; missing canonical targets are copied from hash-verified files before outbox acknowledgement.' }
    } catch {
      $originalError = $_.Exception.Message
      $preserveForRecovery = Test-TaskStateMaterializationFaultInjected $originalError
      $rollback = if (-not $durableCommit -and -not $preserveForRecovery) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error=if($durableCommit){'durable_commit_present'}else{'fault_injection_preserved'} } }
      if (-not $rollback.verified -and $rollback.attempted) { throw "TASK_STATE_REBIND_ROLLBACK_FAILED error=$($rollback.error) original=$originalError" }
      throw
    }
  }
}

function Invoke-ProjectionPathRebind([string]$LegacyRoot,[switch]$Write,[string]$Writer,[switch]$Override,[string]$Reason,[string]$ExpectedFingerprint) {
  if (-not $Override) { throw 'TASK_STATE_MAINTENANCE_OVERRIDE_REQUIRED action=RebindProjectionPaths' }
  $maintenance = New-MaintenanceAudit 'RebindProjectionPaths' $Reason $Writer
  $plan = Get-ProjectionPathRebindPlan $LegacyRoot
  if (-not $Write) {
    return [pscustomobject]@{ ok=($plan.storeParity.ok -and $plan.incompleteTransactionCount -eq 0 -and $plan.invalidCount -eq 0); action='RebindProjectionPaths'; applied=$false; legacyStateRoot=$plan.legacyStateRoot; planFingerprint=$plan.planFingerprint; candidateCount=$plan.candidateCount; readyCount=$plan.readyCount; taskCount=$plan.taskCount; blockedCount=$plan.blockedCount; deferredCount=$plan.deferredCount; invalidCount=$plan.invalidCount; storeParity=$plan.storeParity; incompleteTransactionCount=$plan.incompleteTransactionCount; incompleteTransactions=$plan.incompleteTransactions; candidates=$plan.candidates; blocked=$plan.blocked; deferred=$plan.deferred; invalid=$plan.invalid; skipped=$plan.skipped; guard=$plan.guard }
  }
  if ([string]::IsNullOrWhiteSpace($ExpectedFingerprint)) { throw 'TASK_STATE_REBIND_PLAN_FINGERPRINT_REQUIRED' }
  if (-not [string]::Equals($ExpectedFingerprint,$plan.planFingerprint,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_REBIND_PLAN_FINGERPRINT_STALE' }
  if (-not $plan.storeParity.ok) {
    return [pscustomobject]@{ ok=$false; action='RebindProjectionPaths'; applied=$false; legacyStateRoot=$plan.legacyStateRoot; planFingerprint=$plan.planFingerprint; candidateCount=$plan.candidateCount; readyCount=$plan.readyCount; taskCount=$plan.taskCount; blockedCount=$plan.blockedCount; deferredCount=$plan.deferredCount; invalidCount=$plan.invalidCount; storeParity=$plan.storeParity; candidates=$plan.candidates; blocked=$plan.blocked; deferred=$plan.deferred; invalid=$plan.invalid; skipped=$plan.skipped; guard='No writes were made because committed WAL and projection parity is not clean.' }
  }
  if ($plan.incompleteTransactionCount -gt 0) {
    return [pscustomobject]@{ ok=$false; action='RebindProjectionPaths'; applied=$false; legacyStateRoot=$plan.legacyStateRoot; planFingerprint=$plan.planFingerprint; candidateCount=$plan.candidateCount; readyCount=$plan.readyCount; taskCount=$plan.taskCount; blockedCount=$plan.blockedCount; deferredCount=$plan.deferredCount; invalidCount=$plan.invalidCount; storeParity=$plan.storeParity; incompleteTransactionCount=$plan.incompleteTransactionCount; incompleteTransactions=$plan.incompleteTransactions; guard='No writes were made because one or more prepared task-state transactions require reconciliation first.' }
  }
  if ($plan.invalidCount -gt 0) {
    return [pscustomobject]@{ ok=$false; action='RebindProjectionPaths'; applied=$false; legacyStateRoot=$plan.legacyStateRoot; planFingerprint=$plan.planFingerprint; candidateCount=$plan.candidateCount; readyCount=$plan.readyCount; taskCount=$plan.taskCount; blockedCount=$plan.blockedCount; deferredCount=$plan.deferredCount; invalidCount=$plan.invalidCount; storeParity=$plan.storeParity; candidates=$plan.candidates; blocked=$plan.blocked; deferred=$plan.deferred; invalid=$plan.invalid; skipped=$plan.skipped; guard='No writes were made because one or more legacy projections failed identity, canonical-path, status, hash, or collision validation.' }
  }
  if ($plan.readyCount -eq 0) {
    return [pscustomobject]@{ ok=$true; action='RebindProjectionPaths'; applied=$false; legacyStateRoot=$plan.legacyStateRoot; planFingerprint=$plan.planFingerprint; candidateCount=$plan.candidateCount; readyCount=0; taskCount=0; blockedCount=$plan.blockedCount; deferredCount=$plan.deferredCount; invalidCount=0; storeParity=$plan.storeParity; candidates=@(); blocked=@($plan.blocked); deferred=@($plan.deferred); skipped=$plan.skipped; guard='No safe legacy projection paths remain. Deferred completion-evidence conflicts require independent reconciliation.' }
  }

  $batchId = [guid]::NewGuid().ToString('n')
  $receiptDir = Join-Path $rebindReceiptRoot $batchId
  New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null
  $receiptPath = Join-Path $receiptDir 'receipt.json'
  $receipt = [pscustomobject]@{
    schema='super-brain.projection-path-rebind.v1'
    batchId=$batchId
    status='prepared'
    createdAt=(Get-Date).ToString('o')
    updatedAt=''
    completedAt=''
    legacyStateRoot=$plan.legacyStateRoot
    planFingerprint=$plan.planFingerprint
    maintenance=$maintenance
    candidates=@($plan.ready)
    tasks=@($plan.taskPlans)
    deferred=@($plan.deferred)
    applied=@()
    failures=@()
    destructiveDeleteUsed=$false
  }
  Write-JsonUtf8NoBom $receiptPath $receipt 12
  $applied = @()
  $failures = @()
  foreach ($taskPlan in @($plan.taskPlans | Sort-Object taskId)) {
    try {
      $result = Commit-ProjectionPathRebindTask $taskPlan $plan.planFingerprint $plan.legacyStateRoot $Writer $maintenance
      $applied += $result
    } catch {
      $failures += [pscustomobject]@{ taskId=$taskPlan.taskId; entityKinds=@($taskPlan.candidates | ForEach-Object { [string]$_.entityKind }); error=$_.Exception.Message; failureSite=$_.InvocationInfo.PositionMessage }
      break
    }
    $receipt.applied = @($applied)
    $receipt.failures = @($failures)
    $receipt.status = if ($failures.Count -eq 0) { 'in_progress' } else { 'partial' }
    $receipt.updatedAt = (Get-Date).ToString('o')
    Write-JsonUtf8NoBom $receiptPath $receipt 12
  }
  $receipt.applied = @($applied)
  $receipt.failures = @($failures)
  $receipt.status = if ($failures.Count -eq 0) { 'committed' } else { 'partial' }
  $receipt.completedAt = (Get-Date).ToString('o')
  Write-JsonUtf8NoBom $receiptPath $receipt 12
  $parity = Get-ProjectionParity @(Read-Events)
  $reboundCount = @($applied | ForEach-Object { [int]$_.entityCount } | Measure-Object -Sum).Sum
  $authorityRecords = @($applied | ForEach-Object { [pscustomobject]@{ taskId=[string]$_.taskId; authorityMode=[string]$_.authorityMode; authorityRevision=[int]$_.authorityRevision } })
  $authorityModes = @($authorityRecords | ForEach-Object { [string]$_.authorityMode } | Select-Object -Unique)
  $authorityMode = if ($authorityModes.Count -eq 1) { [string]$authorityModes[0] } elseif ($authorityModes.Count -eq 0) { 'none' } else { 'mixed' }
  $authorityRevision = if ($authorityRecords.Count -eq 1) { [int]$authorityRecords[0].authorityRevision } else { 0 }
  return [pscustomobject]@{ ok=($failures.Count -eq 0 -and $parity.ok); action='RebindProjectionPaths'; applied=$true; legacyStateRoot=$plan.legacyStateRoot; planFingerprint=$plan.planFingerprint; candidateCount=$plan.candidateCount; reboundCount=[int]$reboundCount; taskCount=$plan.taskCount; reboundTaskCount=$applied.Count; blockedCount=$plan.blockedCount; deferredCount=$plan.deferredCount; invalidCount=$plan.invalidCount; failureCount=$failures.Count; authorityMode=$authorityMode; authorityRevision=$authorityRevision; authorityRecords=@($authorityRecords); deferred=@($plan.deferred); appliedRecords=@($applied); failures=@($failures); receiptPath=$receiptPath; receiptHash=Get-FileSha256 $receiptPath; projectionParity=$parity; guard='Each task rebind is one recoverable WAL transaction after target hash, task identity, canonical-path, status, parity, and plan-fingerprint verification. No task lifecycle was completed, cancelled, archived, or deleted.' }
}

function Commit-Entity([string]$Id,[string]$Kind,[string]$Op,[string]$Path,[string]$Payload,[int]$Expected,[string]$Writer,[switch]$Override,[string]$Reason) {
  if ([string]::IsNullOrWhiteSpace($Id)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $target = Assert-EntityTarget $Kind $Path $Id
  $payloadValue = if (-not [string]::IsNullOrWhiteSpace($Payload)) { Read-Payload $Payload $Id } else { $null }
  if ($Op -eq 'upsert' -and -not $payloadValue) { throw 'TASK_STATE_PAYLOAD_PATH_REQUIRED' }
  return Invoke-SuperBrainFileLock $mutationGate {
    Assert-NoIncompleteTaskTransaction $Id -AllowParityRepair:$Override
    $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $Id)) $Id
    $actualRevision = [int]$projection.revision
    if ($Expected -ge 0 -and $Expected -ne $actualRevision) { throw "TASK_STATE_CAS_MISMATCH expected=$Expected actual=$actualRevision taskId=$Id" }
    if ([string]$projection.lifecycle.status -in @('completed','cancelled','archived','quarantined')) { throw "TASK_STATE_LIFECYCLE_TERMINAL taskId=$Id status=$($projection.lifecycle.status)" }
    $previous = Get-EntityValue $projection $Kind
    $status = if ($payloadValue) { [string]$payloadValue.status } else { 'cleared' }
    if ($Op -eq 'upsert' -and ([string]$status).ToLowerInvariant() -in @('completed','verified','cancelled','archived')) { throw "TASK_STATE_COMPLETION_TRANSACTION_REQUIRED taskId=$Id status=$status" }
    $owner = New-OwnerRecord $(if($payloadValue){$payloadValue.value}else{$null}) $OwnerAgentId $OwnerSessionId $OwnerPlatform $OwnerWorkspace $LeaseSeconds $status
    $maintenance = Assert-MutationAuthority $Expected $owner $previous -Override:$Override -Reason $Reason -ActionName 'Commit' -Writer $Writer
    $same = $false
    if ($Op -eq 'clear') { $same = ($null -eq $previous) }
    elseif ($previous) { $same = ([string]$previous.path -eq $target -and [string]$previous.hash -eq [string]$payloadValue.hash -and [string]$previous.status -eq [string]$payloadValue.status) }
    if ($same) {
      Remove-StagingPayload $Payload
      return [pscustomobject]@{ ok=$true; changed=$false; taskId=$Id; revision=$actualRevision; entityKind=$Kind; operation=$Op; projectionPath=Get-ProjectionPath $Id; eventPath=Get-EventPath $Id; transactionId=''; maintenanceOverride=[bool]$Override }
    }
    $nextRevision = $actualRevision + 1
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $transactionId = [guid]::NewGuid().ToString('n')
    $entityRecord = if ($Op -eq 'clear') { $null } else { [pscustomobject]@{ path=$target; hash=[string]$payloadValue.hash; status=$status; source=Limit-Text $Writer 120; owner=$owner } }
    $nextProjection = Ensure-ProjectionShape ($projection | ConvertTo-Json -Depth 16 | ConvertFrom-Json) $Id
    Set-EntityValue $nextProjection $Kind $entityRecord
    $null = Update-ProjectionLifecycleFromEntities $nextProjection $Writer
    $workspaceKey = if ($payloadValue -and $payloadValue.value) { Get-SuperBrainWorkspaceKey ([string]$payloadValue.value.workspaceKey) } else { Get-SuperBrainWorkspaceKey ([string]$nextProjection.lifecycle.workspaceKey) }
    # Observe the canonical target once under the mutation lock.  The same
    # value is used by the SQLite CAS command and the file materializer so a
    # concurrent writer cannot be silently overwritten.
    $expectedTargetHash = Get-FileSha256 $target
    $authority = $null
    $authorityBinding = Get-ExistingTaskAuthorityContract $Id $workspaceKey $(if($payloadValue){$payloadValue.value}else{$null})
    if ($authorityBinding) {
      $authorityContract = $authorityBinding.contract
      foreach ($entry in @(@('workspaceKey',$workspaceKey),@('ownerSessionKey',[string]$authorityContract.ownerSessionKey),@('taskInstanceId',[string]$authorityContract.taskInstanceId),@('planFingerprint',[string]$authorityContract.planReceipt.planFingerprint),@('contractRevision',[int]$authorityContract.revision))) {
        $nextProjection.lifecycle | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1] -Force
      }
      $role = switch ($Kind) { 'context' {'current_context'} 'checkpoint' {'active_checkpoint'} 'task_card' {'active_task_card'} default { throw "TASK_STATE_ENTITY_KIND_INVALID kind=$Kind" } }
      $authorityCommand = [pscustomobject]@{
        role=$role; operation=if($Op-eq'clear'){'delete_identity'}else{'replace_if_hash'}; targetPath=$target; payloadPath=if($payloadValue){[string]$payloadValue.path}else{''}; payloadHash=if($payloadValue){[string]$payloadValue.hash}else{''}
        expectedTargetHash=$expectedTargetHash; expectedTaskId=$Id; expectedWorkspaceKey=$workspaceKey; applyWhenMissing=$false
      }
      $authority = Apply-TaskAuthorityTransition $Id $authorityContract $projection $nextProjection.entities $nextProjection.lifecycle @($authorityCommand) $actualRevision $Writer 'entity_commit' ($transactionId + '|' + [string]$payloadValue.hash + '|' + $Kind + '|' + $Op)
      if (-not $authority.ok) { throw ('TASK_STATE_SQLITE_AUTHORITY_APPLY_FAILED code=' + [string]$authority.code + ' error=' + (Limit-Text ([string]$authority.error) 240)) }
    }
    if ($FaultPoint -eq 'after_authority') {
      if (-not $authority) { throw 'TASK_STATE_SQLITE_AUTHORITY_NOT_INITIALIZED' }
      throw 'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY'
    }
    $prepare = [pscustomobject]@{
      schema='super-brain.task-state-event.v2'; phase='prepared'; transactionId=$transactionId; eventId=[guid]::NewGuid().ToString('n'); taskId=$Id
      revision=0; targetRevision=$nextRevision; previousRevision=$actualRevision; entityKind=$Kind; operation=$Op
      command=[pscustomobject]@{ targetPath=$target; payloadPath=if($payloadValue){$payloadValue.path}else{''}; payloadHash=if($payloadValue){$payloadValue.hash}else{''}; expectedTargetHash=$expectedTargetHash; status=$status; owner=$owner; maintenance=$maintenance }
      authorityOutboxEventId=if($authority){[string]$authority.outboxEventId}else{''}; authorityStateHash=if($authority){[string]$authority.stateHash}else{''}; source=Limit-Text $Writer 120; recordedAt=$now
    }
    Add-StateEvent $Id $prepare
    if ($FaultPoint -eq 'after_prepare') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_PREPARE' }
    $materialization = @()
    $durableCommit = $false
    try {
      # Register the target backup before invoking the command.  A direct
      # entity commit has the same prepared-WAL recovery boundary as the
      # completion paths; if validation, projection, or authority acknowledgement
      # fails after materialization, restore only while the committed event is
      # still absent.  The expected post-state also protects against an
      # unrelated writer changing the target while rollback is in progress.
      $role = switch ($Kind) {
        'context' { 'current_context' }
        'checkpoint' { 'active_checkpoint' }
        'task_card' { 'active_task_card' }
        default { throw "TASK_STATE_ENTITY_KIND_INVALID kind=$Kind" }
      }
      $backupCommand = [pscustomobject]@{
        role=$role
        operation=if($Op -eq 'clear'){'delete_identity'}else{'upsert'}
        targetPath=$target
        payloadPath=if($payloadValue){[string]$payloadValue.path}else{''}
        payloadHash=if($payloadValue){[string]$payloadValue.hash}else{''}
        expectedTargetHash=$expectedTargetHash
        expectedTaskId=$Id
        expectedWorkspaceKey=$workspaceKey
      }
      $backup = New-TaskMaterializationBackup $backupCommand $Id $workspaceKey $transactionId 1
      $record = [pscustomobject]@{
        targetPath=[string]$backup.targetPath
        beforeExists=[bool]$backup.beforeExists
        beforePath=[string]$backup.beforePath
        beforeHash=[string]$backup.beforeHash
        rollbackRoot=[string]$backup.rollbackRoot
        expectedAfterExists=[bool]$backup.expectedAfterExists
        expectedAfterHash=[string]$backup.expectedAfterHash
        role=[string]$backup.role
        ordinal=[int]$backup.ordinal
        action='pending'
        changed=$false
        postStateKnown=$false
      }
      $materialization += $record

      # Direct Commit accepts payloads supplied by its CLI/API caller (they are
      # validated by Read-Payload above), so it cannot use the completion
      # materializer's staging-only payload guard. Reapply the same target CAS
      # and identity checks locally before the atomic payload swap.
      $currentHashBefore = Get-FileSha256 $target
      if ($currentHashBefore -ne $expectedTargetHash) { throw "TASK_STATE_COMPLETION_TARGET_CHANGED role=$role" }
      if ($Op -eq 'upsert') {
        $canonicalHash = Materialize-Payload $payloadValue.path $target $transactionId
        if (-not [string]::Equals([string]$canonicalHash,[string]$payloadValue.hash,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_ENTITY_MATERIALIZATION_HASH_MISMATCH' }
        $record | Add-Member -NotePropertyName action -NotePropertyValue 'upserted' -Force
        $record | Add-Member -NotePropertyName changed -NotePropertyValue $true -Force
      } else {
        if (Test-Path -LiteralPath $target -PathType Leaf) {
          $current = Read-JsonFile $target
          if (-not $current -or [string]$current.taskId -ne $Id -or (-not [string]::IsNullOrWhiteSpace($workspaceKey) -and -not (Test-CompletionWorkspace $current $workspaceKey))) {
            throw "TASK_STATE_COMPLETION_DELETE_IDENTITY_MISMATCH role=$role"
          }
          Remove-Item -LiteralPath $target -Force
        }
        $canonicalHash = ''
        $record | Add-Member -NotePropertyName action -NotePropertyValue 'deleted' -Force
        $record | Add-Member -NotePropertyName changed -NotePropertyValue $true -Force
      }
      $observedExists = Test-Path -LiteralPath $target -PathType Leaf
      $observedHash = if ($observedExists) { Get-FileSha256 $target } else { '' }
      $record | Add-Member -NotePropertyName observedAfterExists -NotePropertyValue ([bool]$observedExists) -Force
      $record | Add-Member -NotePropertyName observedAfterHash -NotePropertyValue $observedHash -Force
      $record | Add-Member -NotePropertyName afterHash -NotePropertyValue $observedHash -Force
      $record | Add-Member -NotePropertyName postStateKnown -NotePropertyValue $true -Force

      # Fault injection after materialization deliberately leaves the prepared
      # event and materialized target for explicit reconciliation.  Other
      # failures in this block are safe to roll back while no commit event is
      # durable.
      if ($FaultPoint -eq 'after_materialize') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZE' }
      $eventId = [guid]::NewGuid().ToString('n')
      $committedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
      $entityRecord = if ($Op -eq 'clear') { $null } else { [pscustomobject]@{ path=$target; hash=$canonicalHash; status=$status; source=Limit-Text $Writer 120; owner=$owner } }
      $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionId=$transactionId; authorityOutboxEventId=if($authority){[string]$authority.outboxEventId}else{''}; authorityStateHash=if($authority){[string]$authority.stateHash}else{''}; eventId=$eventId; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entityKind=$Kind; operation=$Op; entity=$entityRecord; maintenance=$maintenance; source=Limit-Text $Writer 120; recordedAt=$committedAt; materialization=@($materialization) }
      Add-StateEvent $Id $commit
      $durableCommit = $true
      if ($FaultPoint -eq 'after_commit') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_COMMIT' }
      Commit-Projection $projection $Id $Kind $Op $entityRecord $nextRevision $eventId $committedAt
      if ($authority) {
        $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$authority.outboxEventId)
        if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_SQLITE_AUTHORITY_OUTBOX_ACK_FAILED' }
      }
      Remove-TaskCompletionStaging @() '' $materialization
      Remove-StagingPayload $Payload
      return [pscustomobject]@{ ok=$true; changed=$true; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entityKind=$Kind; operation=$Op; transactionId=$transactionId; authorityMode=if($authority){'sqlite'}else{'deferred_until_task_authority'}; authorityRevision=if($authority){[int]$authority.revision}else{0}; projectionPath=Get-ProjectionPath $Id; eventPath=Get-EventPath $Id; materializedPath=$target; materialization=@($materialization); mode='wal-materializer'; maintenanceOverride=[bool]$Override }
    } catch {
      $originalError = $_.Exception.Message
      $preserveForRecovery = ($FaultPoint -eq 'after_materialize')
      $rollback = if (-not $durableCommit -and -not $preserveForRecovery) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error=if($durableCommit){'durable_commit_present'}else{'fault_injection_preserved'} } }
      if ($rollback.attempted -and -not $rollback.verified) { throw "TASK_STATE_ENTITY_ROLLBACK_FAILED error=$($rollback.error) original=$originalError" }
      throw
    }
  }
}

function Get-RecordWorkspaceKey([object]$Value) {
  if ($Value -and $Value.PSObject.Properties['workspaceKey']) { return [string]$Value.workspaceKey }
  return ''
}

function Test-CompletionWorkspace([object]$Value,[string]$WorkspaceKey) {
  $recorded = Get-RecordWorkspaceKey $Value
  if ([string]::IsNullOrWhiteSpace($recorded) -or [string]::IsNullOrWhiteSpace($WorkspaceKey)) { return $false }
  return Test-SuperBrainWorkspaceKey $recorded $WorkspaceKey
}

function Assert-CompletionManifest([string]$Path,[string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'TASK_STATE_COMPLETION_MANIFEST_REQUIRED' }
  $full = [IO.Path]::GetFullPath($Path)
  if (-not (Test-ChildPath $stagingRoot $full)) { throw "TASK_STATE_COMPLETION_MANIFEST_OUTSIDE_STAGING path=$full" }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "TASK_STATE_COMPLETION_MANIFEST_NOT_FOUND path=$full" }
  if ((Get-Item -LiteralPath $full).Length -gt 262144) { throw 'TASK_STATE_COMPLETION_MANIFEST_TOO_LARGE' }
  $manifestValue = Read-JsonFile $full
  if (-not $manifestValue -or [string]$manifestValue.schema -ne 'super-brain.task-completion-manifest.v1') { throw 'TASK_STATE_COMPLETION_MANIFEST_INVALID' }
  if ([string]$manifestValue.taskId -ne $Id) { throw "TASK_STATE_IDENTITY_MISMATCH expected=$Id actual=$($manifestValue.taskId)" }
  return [pscustomobject]@{ path=$full; hash=Get-FileSha256 $full; value=$manifestValue }
}

function Write-CompletionStagingValue([string]$Id,[string]$TransactionId,[string]$Name,[object]$Value) {
  $dir = Join-Path $stagingRoot (Get-SuperBrainCanonicalTaskToken $Id)
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $safeName = (($Name -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = [guid]::NewGuid().ToString('n') }
  if ($safeName.Length -gt 48) { $safeName = $safeName.Substring(0,48).TrimEnd('-') }
  $prefix = if($TransactionId.Length -ge 8){$TransactionId.Substring(0,8)}else{$TransactionId}
  $path = Join-Path $dir ($prefix + '-' + $safeName + '.json')
  Write-JsonUtf8NoBom $path $Value 14
  return $path
}

function New-CompletionCommand(
  [string]$Role,
  [string]$Operation,
  [string]$TargetPath,
  [string]$Payload = '',
  [string]$ExpectedHash = '',
  [string]$Id = $TaskId,
  [string]$WorkspaceKey = '',
  [bool]$ApplyWhenMissing = $false
) {
  $payloadHash = if ([string]::IsNullOrWhiteSpace($Payload)) { '' } else { Get-FileSha256 $Payload }
  return [pscustomobject]@{
    role = $Role
    operation = $Operation
    targetPath = [IO.Path]::GetFullPath($TargetPath)
    payloadPath = if($Payload){[IO.Path]::GetFullPath($Payload)}else{''}
    payloadHash = $payloadHash
    expectedTargetHash = $ExpectedHash
    expectedTaskId = $Id
    expectedWorkspaceKey = $WorkspaceKey
    applyWhenMissing = $ApplyWhenMissing
  }
}

function Find-UniqueCompletionRecord([string]$RootPath,[string]$Pattern,[string]$ExcludeTaskId,[string]$WorkspaceKey,[scriptblock]$Predicate) {
  if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) { return $null }
  $matches = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $RootPath -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
    $value = Read-JsonFile $file.FullName
    if (-not $value -or [string]$value.taskId -eq $ExcludeTaskId) { continue }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceKey) -and -not (Test-CompletionWorkspace $value $WorkspaceKey)) { continue }
    if (& $Predicate $value) { $matches += [pscustomobject]@{ path=$file.FullName; value=$value }; if($matches.Count-gt1){return $null} }
  }
  if($matches.Count-eq1){return $matches[0]}
  return $null
}

function Get-CompletionArchivePath([string]$Id,[string]$TransactionId,[string]$Role,[string]$TargetPath) {
  $safeRole = (($Role -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safeRole)) { $safeRole = 'state' }
  if($safeRole.Length-gt20){$safeRole=$safeRole.Substring(0,20).TrimEnd('-')}
  $taskToken = 't-' + (Get-ShortHash $Id)
  $transactionToken = if($TransactionId.Length-gt16){$TransactionId.Substring(0,16)}else{$TransactionId}
  $dir = Join-Path (Join-Path $completionArchiveRoot $taskToken) $transactionToken
  return Join-Path $dir ($safeRole + '--' + (Get-ShortHash ([IO.Path]::GetFullPath($TargetPath))) + '.json')
}

function Get-ConflictQuarantinePath([string]$Id,[string]$TransactionId,[string]$Role,[string]$TargetPath) {
  $safeRole = (($Role -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safeRole)) { $safeRole = 'state' }
  if ($safeRole.Length -gt 20) { $safeRole = $safeRole.Substring(0,20).TrimEnd('-') }
  $taskToken = 't-' + (Get-ShortHash $Id)
  $transactionToken = if($TransactionId.Length -gt 16){$TransactionId.Substring(0,16)}else{$TransactionId}
  $dir = Join-Path (Join-Path (Join-Path $quarantineRoot 'ambiguous-state') $taskToken) $transactionToken
  return Join-Path $dir ($safeRole + '--' + (Get-ShortHash ([IO.Path]::GetFullPath($TargetPath))) + '.json')
}

function Get-ConflictQuarantineManifestPath([string]$Id,[string]$TransactionId) {
  $taskToken = 't-' + (Get-ShortHash $Id)
  $transactionToken = if($TransactionId.Length -gt 16){$TransactionId.Substring(0,16)}else{$TransactionId}
  return Join-Path (Join-Path (Join-Path (Join-Path $quarantineRoot 'ambiguous-state') $taskToken) $transactionToken) 'quarantine-manifest.json'
}

function New-ArchivedCompletionCommand(
  [string]$Role,[string]$Operation,[string]$TargetPath,[string]$TransactionId,[string]$Payload='',
  [string]$ExpectedHash='',[string]$Id=$TaskId,[string]$WorkspaceKey=''
) {
  $command = New-CompletionCommand $Role $Operation $TargetPath $Payload $ExpectedHash $Id $WorkspaceKey
  $command | Add-Member -NotePropertyName archivePath -NotePropertyValue (Get-CompletionArchivePath $Id $TransactionId $Role $TargetPath) -Force
  return $command
}

function New-QuarantinedStateCommand(
  [string]$Role,[string]$TargetPath,[string]$TransactionId,[string]$ExpectedHash,
  [string]$Id=$TaskId,[string]$WorkspaceKey=''
) {
  $command = New-CompletionCommand $Role 'quarantine_identity' $TargetPath '' $ExpectedHash $Id $WorkspaceKey
  $command | Add-Member -NotePropertyName archivePath -NotePropertyValue (Get-ConflictQuarantinePath $Id $TransactionId $Role $TargetPath) -Force
  return $command
}

function Get-QuarantineSourceWorkspaceKey([object]$SourceValue,[string]$CandidateWorkspaceKey) {
  $recorded = Get-RecordWorkspaceKey $SourceValue
  if ([string]::IsNullOrWhiteSpace($recorded)) { return '' }
  if (-not [string]::IsNullOrWhiteSpace($CandidateWorkspaceKey) -and -not (Test-SuperBrainWorkspaceKey $recorded $CandidateWorkspaceKey)) {
    throw 'TASK_STATE_QUARANTINE_WORKSPACE_MISMATCH'
  }
  return $recorded
}

function New-CompletionPointerCommand([string]$Role,[string]$PointerPath,[string]$Id,[string]$WorkspaceKey,[object]$Replacement,[string]$TransactionId) {
  $current = Read-JsonFile $PointerPath
  if (-not $current -or [string]$current.taskId -ne $Id) { return $null }
  $payloadPath = ''
  if ($Replacement) { $payloadPath = Write-CompletionStagingValue $Id $TransactionId ($Role + '-replacement') $Replacement }
  return New-CompletionCommand $Role 'conditional_pointer' $PointerPath $payloadPath (Get-FileSha256 $PointerPath) $Id $WorkspaceKey $true
}

function Assert-CompletionPayload([string]$Path,[string]$Id,[string]$WorkspaceKey,[string]$ExpectedStatus,[string]$Name) {
  $payload = Read-Payload $Path $Id
  if (-not (Test-CompletionWorkspace $payload.value $WorkspaceKey)) { throw "TASK_STATE_COMPLETION_${Name}_WORKSPACE_MISMATCH" }
  if ([string]$payload.status -ne $ExpectedStatus) { throw "TASK_STATE_COMPLETION_${Name}_STATUS_INVALID expected=$ExpectedStatus actual=$($payload.status)" }
  if (@($payload.value.pendingSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { throw "TASK_STATE_COMPLETION_${Name}_PENDING_STEPS" }
  return $payload
}

function Test-CompletionPlanReceiptCurrent([string]$Id,[string]$WorkspaceKey,[string]$ContractPath,[string]$ExpectedContractHash) {
  $stateRoot = Split-Path -Parent $WorkspaceRoot
  $scriptPath = Join-Path $PSScriptRoot 'execution-contract.ps1'
  try {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action ValidatePlanReceipt -TaskId $Id -WorkspaceKey $WorkspaceKey -StateRoot $stateRoot -ReceiptContractPath $ContractPath -Json 2>$null)
    $exitCode = $LASTEXITCODE
    $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
    if (-not $value -or $exitCode -ne 0 -or $value.ok -ne $true) {
      return [pscustomobject]@{ ok=$false; code=if($value -and $value.PSObject.Properties['code']){[string]$value.code}else{'EXECUTION_CONTRACT_PLAN_RECEIPT_VALIDATION_FAILED'} }
    }
    if (-not [string]::Equals([string]$value.contractHash,[string]$ExpectedContractHash,[StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_CONTRACT_CHANGED' }
    }
    return [pscustomobject]@{ ok=$true; code=[string]$value.code }
  } catch {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_PLAN_RECEIPT_VALIDATION_FAILED' }
  }
}

function Test-CompletionIntentReceiptCurrent([string]$Id,[string]$WorkspaceKey,[string]$ContractPath,[string]$ExpectedContractHash) {
  $stateRoot = Split-Path -Parent $WorkspaceRoot
  $scriptPath = Join-Path $PSScriptRoot 'execution-contract.ps1'
  try {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action ValidateIntentReceipt -TaskId $Id -WorkspaceKey $WorkspaceKey -StateRoot $stateRoot -ReceiptContractPath $ContractPath -Json 2>$null)
    $exitCode = $LASTEXITCODE
    $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
    if (-not $value -or $exitCode -ne 0 -or $value.ok -ne $true) {
      return [pscustomobject]@{ ok=$false; code=if($value -and $value.PSObject.Properties['code']){[string]$value.code}else{'EXECUTION_CONTRACT_INTENT_RECEIPT_VALIDATION_FAILED'}; value=$value }
    }
    if (-not [string]::Equals([string]$value.contractHash,[string]$ExpectedContractHash,[StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_CONTRACT_CHANGED'; value=$value }
    }
    return [pscustomobject]@{ ok=$true; code=[string]$value.code; value=$value }
  } catch {
    return [pscustomobject]@{ ok=$false; code='EXECUTION_CONTRACT_INTENT_RECEIPT_VALIDATION_FAILED'; value=$null }
  }
}

function Assert-CompletionContract([object]$Manifest,[string]$Id,[string]$WorkspaceKey,[string]$PackageVersion,[string]$CallerSessionKey,[switch]$Override) {
  $path = [string]$Manifest.executionContractPath
  if ([string]::IsNullOrWhiteSpace($path)) {
    if ($Override) { return $null }
    throw 'TASK_STATE_COMPLETION_CONTRACT_REQUIRED'
  }
  $full = [IO.Path]::GetFullPath($path)
  $contractRoot = Join-Path $WorkspaceRoot 'runtime-state\execution-contracts'
  if (-not (Test-ChildPath $contractRoot $full)) { throw "TASK_STATE_COMPLETION_CONTRACT_PATH_INVALID path=$full" }
  $contract = Read-JsonFile $full
  if (-not $contract) { throw 'TASK_STATE_COMPLETION_CONTRACT_NOT_FOUND' }
  if ([string]$contract.taskId -ne $Id) { throw 'TASK_STATE_COMPLETION_CONTRACT_TASK_MISMATCH' }
  if (-not (Test-CompletionWorkspace $contract $WorkspaceKey)) { throw 'TASK_STATE_COMPLETION_CONTRACT_WORKSPACE_MISMATCH' }
  if ([string]$contract.status -ne 'active') { throw 'TASK_STATE_COMPLETION_CONTRACT_NOT_ACTIVE' }
  if ([string]$contract.packageVersion -ne $PackageVersion) { throw 'TASK_STATE_COMPLETION_CONTRACT_VERSION_MISMATCH' }
  if (-not $contract.PSObject.Properties['taskInstanceId'] -or [string]$contract.taskInstanceId -notmatch '^ti-[a-f0-9]{32}$') { throw 'TASK_STATE_COMPLETION_TASK_INSTANCE_REQUIRED' }
  if (-not $Manifest.PSObject.Properties['expectedTaskInstanceId'] -or [string]$Manifest.expectedTaskInstanceId -notmatch '^ti-[a-f0-9]{32}$') { throw 'TASK_STATE_COMPLETION_TASK_INSTANCE_REQUIRED' }
  if ([string]$contract.taskInstanceId -ne [string]$Manifest.expectedTaskInstanceId) { throw 'TASK_STATE_COMPLETION_TASK_INSTANCE_MISMATCH' }
  try {
    $contractAge = ((Get-Date) - [datetime]::Parse([string]$contract.updatedAt)).TotalHours
    if ($contractAge -gt 168) { throw 'TASK_STATE_COMPLETION_CONTRACT_STALE' }
    if ($contractAge -lt -0.25) { throw 'TASK_STATE_COMPLETION_CONTRACT_FUTURE_TIMESTAMP' }
  } catch {
    if ([string]$_.Exception.Message -like 'TASK_STATE_COMPLETION_CONTRACT_*') { throw }
    throw 'TASK_STATE_COMPLETION_CONTRACT_TIMESTAMP_INVALID'
  }
  $contractHash = Get-FileSha256 $full
  if ([int]$contract.revision -ne [int]$Manifest.expectedContractRevision) { throw 'TASK_STATE_COMPLETION_CONTRACT_REVISION_MISMATCH' }
  if (-not $contract.planReceipt -or [string]$contract.planReceipt.planFingerprint -ne [string]$Manifest.expectedPlanFingerprint -or [int]$contract.planReceipt.contractRevision -ne [int]$contract.revision) { throw 'TASK_STATE_COMPLETION_PLAN_FINGERPRINT_MISMATCH' }
  if (-not $Override) {
    $receiptCurrent = Test-CompletionPlanReceiptCurrent $Id $WorkspaceKey $full $contractHash
    if (-not $receiptCurrent.ok) { throw ('TASK_STATE_COMPLETION_PLAN_RECEIPT_STALE code=' + [string]$receiptCurrent.code) }
  }
  if ([string]$contract.ownerSessionKey -ne [string]$Manifest.ownerSessionKey) { throw 'TASK_STATE_COMPLETION_SESSION_MISMATCH' }
  $caller = Get-SuperBrainLocalSessionKey $CallerSessionKey
  $manifestCaller = if($Manifest.PSObject.Properties['callerSessionKey']){Get-SuperBrainLocalSessionKey ([string]$Manifest.callerSessionKey)}else{''}
  if ([string]::IsNullOrWhiteSpace($caller) -or [string]::IsNullOrWhiteSpace($manifestCaller)) { throw 'TASK_STATE_COMPLETION_CALLER_SESSION_REQUIRED' }
  if ($caller -ne $manifestCaller -or $caller -ne [string]$Manifest.ownerSessionKey -or $caller -ne [string]$contract.ownerSessionKey) { throw 'TASK_STATE_COMPLETION_CALLER_SESSION_MISMATCH' }
  if (@($contract.returnStack).Count -gt 0) { throw 'TASK_STATE_COMPLETION_PARENT_SUSPENDED' }
  if ($contract.PSObject.Properties['canonicalPlan'] -and $contract.canonicalPlan) {
    $canonicalState=Test-SuperBrainCanonicalPlan $contract.canonicalPlan
    if(-not$canonicalState.ok){throw ('TASK_STATE_COMPLETION_CANONICAL_INVALID code='+[string]$canonicalState.code)}
    $contract.canonicalPlan=$canonicalState.plan
    $canonicalItems = @($canonicalState.plan.items)
    if (@($canonicalItems | Where-Object { [string]$_.status -in @('pending','in_progress') }).Count -gt 0) { throw 'TASK_STATE_COMPLETION_PENDING_STEPS' }
  } elseif (@($contract.pendingSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
    throw 'TASK_STATE_COMPLETION_PENDING_STEPS'
  }
  if ($contract.PSObject.Properties['needsReconciliation'] -and $contract.needsReconciliation -eq $true) { throw 'TASK_STATE_COMPLETION_RECONCILIATION_REQUIRED' }
  return [pscustomobject]@{ path=$full; hash=$contractHash; value=$contract }
}

function Assert-CompletionVerification([object]$Manifest,[string]$Id,[string]$WorkspaceKey,[string]$PackageVersion,[switch]$Override) {
  $path = [string]$Manifest.verificationPath
  if ([string]::IsNullOrWhiteSpace($path)) {
    if ($Override) { return $null }
    throw 'TASK_STATE_COMPLETION_VERIFICATION_REQUIRED'
  }
  $full = [IO.Path]::GetFullPath($path)
  $verification = Read-JsonFile $full
  if (-not $verification -or $verification.ok -ne $true) { throw 'TASK_STATE_COMPLETION_VERIFICATION_INVALID' }
  if ([string]$verification.taskId -ne $Id) { throw 'TASK_STATE_COMPLETION_VERIFICATION_TASK_MISMATCH' }
  if (-not (Test-CompletionWorkspace $verification $WorkspaceKey)) { throw 'TASK_STATE_COMPLETION_VERIFICATION_WORKSPACE_MISMATCH' }
  $version = if ($verification.PSObject.Properties['packageVersion']) { [string]$verification.packageVersion } else { [string]$verification.version }
  if ($version -ne $PackageVersion) { throw 'TASK_STATE_COMPLETION_VERIFICATION_VERSION_MISMATCH' }
  $binding = if ($Manifest.PSObject.Properties['evidenceBinding']) { $Manifest.evidenceBinding } else { $null }
  if (-not $binding -or -not $verification.PSObject.Properties['evidenceBinding'] -or -not $verification.evidenceBinding) { throw 'TASK_STATE_COMPLETION_VERIFICATION_HISTORICAL' }
  foreach ($name in @('schema','packageVersion','gitTreeHash','treeAlgorithm','gitHeadTreeHash','taskId','workspaceKey','ownerSessionKey','artifactKind')) {
    if ([string]$verification.evidenceBinding.$name -ne [string]$binding.$name) { throw ('TASK_STATE_COMPLETION_EVIDENCE_BINDING_RECORD_MISMATCH field=' + $name) }
  }
  $bindingCheck = Test-SuperBrainEvidenceBinding -Binding $binding -TaskId $Id -WorkspaceKey $WorkspaceKey -OwnerSessionKey ([string]$Manifest.ownerSessionKey) -ArtifactPath $full -RequireArtifactHash -Root $Root
  if (-not $bindingCheck.ok) {
    if ([string]$bindingCheck.reason -eq 'historical_evidence_binding_missing') { throw 'TASK_STATE_COMPLETION_VERIFICATION_HISTORICAL' }
    throw ('TASK_STATE_COMPLETION_EVIDENCE_BINDING_INVALID reason=' + [string]$bindingCheck.reason)
  }
  if (@($verification.nextSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { throw 'TASK_STATE_COMPLETION_VERIFICATION_HAS_NEXT_STEPS' }
  return [pscustomobject]@{ path=$full; hash=Get-FileSha256 $full; value=$verification; evidenceBinding=$binding }
}

function Assert-CompletionIntent([object]$ContractRecord,[object]$VerificationRecord,[string]$Id,[string]$WorkspaceKey,[string]$PackageVersion,[switch]$Override,[switch]$SkipReceiptCheck) {
  $contract = if($ContractRecord -and $ContractRecord.value){$ContractRecord.value}else{$null}
  if (-not $contract) {
    if ($Override) { return [pscustomobject]@{ schema='super-brain.intent-completion-binding.v1'; required=$false; status='override'; intentRevision=0; intentContractFingerprint=''; intentReceiptId=''; intentReceiptPayloadHash=''; requirementsFingerprint=''; fulfillmentFingerprint=''; fulfillmentArtifactHash=''; requirementCount=0; rawPromptStored=$false; rawTranscriptStored=$false } }
    throw 'TASK_STATE_COMPLETION_INTENT_CONTRACT_REQUIRED'
  }
  $required = ($contract.PSObject.Properties['intentContractRequired'] -and $contract.intentContractRequired -eq $true)
  if (-not $required) { return [pscustomobject]@{ schema='super-brain.intent-completion-binding.v1'; required=$false; status='not_required'; intentRevision=0; intentContractFingerprint=''; intentReceiptId=''; intentReceiptPayloadHash=''; requirementsFingerprint=''; fulfillmentFingerprint=''; fulfillmentArtifactHash=if($VerificationRecord){[string]$VerificationRecord.hash}else{''}; requirementCount=0; rawPromptStored=$false; rawTranscriptStored=$false } }
  if (-not $SkipReceiptCheck) {
    $receiptCurrent = Test-CompletionIntentReceiptCurrent $Id $WorkspaceKey ([string]$ContractRecord.path) ([string]$ContractRecord.hash)
    if (-not $receiptCurrent.ok) { throw ('TASK_STATE_COMPLETION_INTENT_RECEIPT_STALE code=' + [string]$receiptCurrent.code) }
  }
  if (-not $VerificationRecord -or -not $VerificationRecord.value -or -not $VerificationRecord.value.PSObject.Properties['intentFulfillment']) { throw 'TASK_STATE_COMPLETION_INTENT_FULFILLMENT_REQUIRED' }
  $fulfillment = $VerificationRecord.value.intentFulfillment
  $status = Test-SuperBrainIntentFulfillment $contract $fulfillment
  if (-not $status.ok) { throw ('TASK_STATE_COMPLETION_INTENT_FULFILLMENT_UNSATISFIED code=' + [string]$status.code + ' missing=' + (@($status.missing) -join ',')) }
  if ([string]$contract.taskId -ne $Id -or -not (Test-CompletionWorkspace $contract $WorkspaceKey) -or [string]$contract.packageVersion -ne $PackageVersion) { throw 'TASK_STATE_COMPLETION_INTENT_BINDING_MISMATCH' }
  return [pscustomobject]@{
    schema='super-brain.intent-completion-binding.v1';required=$true;status='current';intentRevision=[int]$contract.intentRevision
    intentContractFingerprint=[string]$contract.intentResolutionReceipt.intentContractFingerprint;intentReceiptId=[string]$contract.intentResolutionReceipt.receiptId
    intentReceiptPayloadHash=[string]$contract.intentResolutionReceipt.payloadHash;requirementsFingerprint=[string]$fulfillment.requirementsFingerprint
    fulfillmentFingerprint=[string]$status.fingerprint;fulfillmentArtifactHash=[string]$VerificationRecord.hash;requirementCount=[int]$status.requirementCount
    rawPromptStored=$false;rawTranscriptStored=$false
  }
}

function Assert-CompletionDecisionBinding([object]$ContractRecord,[object]$VerificationRecord,[string]$Id,[string]$WorkspaceKey,[string]$PackageVersion,[switch]$Override) {
  $contract = if ($ContractRecord -and $ContractRecord.value) { $ContractRecord.value } else { $null }
  if (-not $contract) {
    if ($Override) { return [pscustomobject]@{ required=$false; status='override'; binding=$null; results=@() } }
    throw 'TASK_STATE_COMPLETION_DECISION_CONTRACT_REQUIRED'
  }
  $stageKind = if ($contract.PSObject.Properties['stageKind']) { [string]$contract.stageKind } else { '' }
  if ([string]::IsNullOrWhiteSpace($stageKind)) { return [pscustomobject]@{ required=$false; status='not_required'; binding=$null; results=@() } }
  if ($stageKind -notin @('build','package','release','deploy','test')) { throw 'TASK_STATE_COMPLETION_DECISION_STAGE_INVALID' }
  if (-not $contract.PSObject.Properties['decisionBinding'] -or -not $contract.decisionBinding) { throw 'TASK_STATE_COMPLETION_DECISION_BINDING_REQUIRED' }
  $binding = $contract.decisionBinding
  if ([string]$binding.status -notin @('bound','none_applicable') -or [string]::IsNullOrWhiteSpace([string]$binding.path) -or [string]::IsNullOrWhiteSpace([string]$binding.bindingDigest)) { throw 'TASK_STATE_COMPLETION_DECISION_BINDING_INVALID' }
  $stateRoot = Split-Path -Parent $WorkspaceRoot
  $bindingScript = Join-Path $PSScriptRoot 'decision-binding.ps1'
  if (-not (Test-Path -LiteralPath $bindingScript -PathType Leaf)) { throw 'TASK_STATE_COMPLETION_DECISION_BINDING_SCRIPT_MISSING' }
  $intentFingerprint = if ($contract.PSObject.Properties['decisionIntentFingerprint']) { [string]$contract.decisionIntentFingerprint } else { '' }
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bindingScript -Action ValidateCompletion -TaskId $Id -TaskInstanceId ([string]$contract.taskInstanceId) -WorkspaceKey $WorkspaceKey -WorklineId ([string]$contract.focusId) -StageKind $stageKind -IntentFingerprint $intentFingerprint -ContractRevision ([int]$contract.revision) -PlanFingerprint ([string]$contract.planReceipt.planFingerprint) -OwnerSessionKey ([string]$contract.ownerSessionKey) -ReceiptPath ([string]$binding.path) -StateRoot $stateRoot -Json 2>$null)
  $exitCode = $LASTEXITCODE
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  if (-not $value -or $exitCode -ne 0 -or $value.ok -ne $true) { throw ('TASK_STATE_COMPLETION_DECISION_RESULTS_UNSATISFIED code=' + $(if($value -and $value.PSObject.Properties['code']){[string]$value.code}else{'unknown'})) }
  if ([string]$value.bindingDigest -ne [string]$binding.bindingDigest) { throw 'TASK_STATE_COMPLETION_DECISION_BINDING_DIGEST_MISMATCH' }
  if (-not $VerificationRecord -or -not $VerificationRecord.value -or -not $VerificationRecord.value.PSObject.Properties['decisionBinding'] -or -not $VerificationRecord.value.decisionBinding) { throw 'TASK_STATE_COMPLETION_DECISION_VERIFICATION_MISSING' }
  $verificationBinding = $VerificationRecord.value.decisionBinding
  if ($verificationBinding.ok -ne $true -or [string]$verificationBinding.bindingDigest -ne [string]$value.bindingDigest -or [string]$verificationBinding.status -ne [string]$value.status) { throw 'TASK_STATE_COMPLETION_DECISION_VERIFICATION_MISMATCH' }
  $results = @($value.results | ForEach-Object { [pscustomobject]@{ decisionId=[string]$_.decisionId; revision=[int]$_.revision; resultPath=[string]$_.resultPath; resultHash=[string]$_.resultHash } })
  foreach ($result in $results) {
    if ([string]::IsNullOrWhiteSpace([string]$result.resultPath) -or [string]$result.resultHash -notmatch '^[a-f0-9]{64}$' -or (Get-FileSha256 ([string]$result.resultPath)) -ne [string]$result.resultHash) { throw 'TASK_STATE_COMPLETION_DECISION_RESULT_CHANGED' }
  }
  return [pscustomobject]@{ required=$true; status=[string]$value.status; bindingDigest=[string]$value.bindingDigest; stageKind=$stageKind; intentFingerprint=$intentFingerprint; results=@($results); binding=$binding }
}

function Assert-CompletionCommandTarget([object]$Command,[string]$Id,[string]$WorkspaceKey) {
  $target = [IO.Path]::GetFullPath([string]$Command.targetPath)
  $role = [string]$Command.role
  if ([string]$Command.operation -eq 'quarantine_identity' -and $role -in @('completed_checkpoint','completed_task_card')) {
    $quarantineSourceRoot = if ($role -eq 'completed_checkpoint') { Join-Path $WorkspaceRoot 'runtime-state\checkpoints\completed' } else { Join-Path $SharedRoot 'tasks\completed' }
    if (-not (Test-ChildPath $quarantineSourceRoot $target)) { throw "TASK_STATE_COMPLETION_TARGET_INVALID role=$role path=$target" }
    return $target
  }
  $exact = @{
    completed_checkpoint = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\checkpoints\completed') $Id '.json'
    completed_task_card = Get-SuperBrainCanonicalTaskPath (Join-Path $SharedRoot 'tasks\completed') $Id '.task.json'
    workspace_context_pointer = if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { '' } else { Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'guard-state\current-task-context-pointers') $WorkspaceKey '.json' }
    legacy_context_pointer = Join-Path $WorkspaceRoot 'current-task-context.json'
    checkpoint_pointer = Join-Path $WorkspaceRoot 'active-checkpoint.json'
    contract_pointer = Join-Path $WorkspaceRoot 'last-execution-contract.json'
    goal_lock_pointer = Join-Path $WorkspaceRoot 'goal-route-lock.json'
    route_checkpoint_pointer = Join-Path $WorkspaceRoot 'route-checkpoint.json'
    task_graph = Join-Path $WorkspaceRoot 'task-graph.json'
    last_completed_task_graph = Join-Path $WorkspaceRoot 'last-completed-task-graph.json'
    last_completed_checkpoint = Join-Path $WorkspaceRoot 'last-completed-checkpoint.json'
    terminal_plan_seal = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'task-state-store\terminal-plan-seals') $Id '.json'
    task_completion_receipt = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\task-completion-receipts') $Id '.json'
  }
  if ($exact.ContainsKey($role)) {
    if (-not [string]::Equals($target,[IO.Path]::GetFullPath([string]$exact[$role]),[StringComparison]::OrdinalIgnoreCase)) { throw "TASK_STATE_COMPLETION_TARGET_INVALID role=$role path=$target" }
    return $target
  }
  $allowedRoot = switch ($role) {
    'active_checkpoint' { Join-Path $WorkspaceRoot 'runtime-state\checkpoints\active' }
    'current_context' { Join-Path $WorkspaceRoot 'guard-state\current-task-contexts' }
    'active_task_card' { Join-Path $SharedRoot 'tasks' }
    'active_task_card_cleanup' { Join-Path $SharedRoot 'tasks' }
    'execution_contract' { Join-Path $WorkspaceRoot 'runtime-state\execution-contracts' }
    'goal_route_lock' { Join-Path $WorkspaceRoot 'guard-state\goal-route-locks' }
    'route_checkpoint' { Join-Path $WorkspaceRoot 'guard-state\route-checkpoints' }
    'execution_hot_index' { Join-Path $WorkspaceRoot 'runtime-state\execution-hot-index' }
    'conflict_manifest' { Join-Path $quarantineRoot 'ambiguous-state' }
    default { '' }
  }
  if ([string]::IsNullOrWhiteSpace($allowedRoot) -or -not (Test-ChildPath $allowedRoot $target)) { throw "TASK_STATE_COMPLETION_TARGET_INVALID role=$role path=$target" }
  return $target
}

function Test-LegacyUnscopedCompatibilityPointer([object]$Value) {
  if (-not $Value) { return $false }
  if (-not $Value.PSObject.Properties['workspaceKey']) { return $true }
  return [string]::IsNullOrWhiteSpace([string]$Value.workspaceKey)
}

function Materialize-CompletionCommand([object]$Command,[string]$Id,[string]$WorkspaceKey,[string]$TransactionId) {
  $target = Assert-CompletionCommandTarget $Command $Id $WorkspaceKey
  $payloadPath = [string]$Command.payloadPath
  $desiredHash = [string]$Command.payloadHash
  if ($payloadPath) {
    if (-not (Test-ChildPath $stagingRoot $payloadPath) -or -not (Test-Path -LiteralPath $payloadPath -PathType Leaf) -or (Get-FileSha256 $payloadPath) -ne $desiredHash) { throw "TASK_STATE_COMPLETION_PAYLOAD_INVALID role=$($Command.role)" }
  }
  $currentHash = Get-FileSha256 $target
  if ($desiredHash -and $currentHash -eq $desiredHash) { return [pscustomobject]@{ role=$Command.role; action='already_materialized'; changed=$false } }
  $operation = [string]$Command.operation
  if ($operation -eq 'conditional_pointer') {
    $current = Read-JsonFile $target
    $replaceLegacyUnscoped = ($Command.PSObject.Properties['replaceLegacyUnscopedPointer'] -and [bool]$Command.replaceLegacyUnscopedPointer -and $MaintenanceOverride)
    if ($current -and [string]$current.taskId -ne $Id -and -not ($replaceLegacyUnscoped -and (Test-LegacyUnscopedCompatibilityPointer $current))) {
      return [pscustomobject]@{ role=$Command.role; action='foreign_pointer_preserved'; changed=$false }
    }
    if (-not $currentHash -and -not $payloadPath) { return [pscustomobject]@{ role=$Command.role; action='pointer_already_removed'; changed=$false } }
    if ([string]$Command.expectedTargetHash -and $currentHash -ne [string]$Command.expectedTargetHash) { throw "TASK_STATE_COMPLETION_TARGET_CHANGED role=$($Command.role)" }
    if (-not $current -and $Command.applyWhenMissing -ne $true) { return [pscustomobject]@{ role=$Command.role; action='pointer_absent'; changed=$false } }
    if ($payloadPath) { $null = Materialize-Payload $payloadPath $target $TransactionId; return [pscustomobject]@{ role=$Command.role; action='pointer_replaced'; changed=$true } }
    if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
    return [pscustomobject]@{ role=$Command.role; action='pointer_removed'; changed=$true }
  }
  if ($operation -in @('archive_identity','archive_replace','quarantine_identity')) {
    $archivePath = if($Command.PSObject.Properties['archivePath']){[IO.Path]::GetFullPath([string]$Command.archivePath)}else{''}
    $archiveParent = if ($operation -eq 'quarantine_identity') { Join-Path $quarantineRoot 'ambiguous-state' } else { $completionArchiveRoot }
    if ([string]::IsNullOrWhiteSpace($archivePath) -or -not (Test-ChildPath $archiveParent $archivePath)) { throw "TASK_STATE_COMPLETION_ARCHIVE_PATH_INVALID role=$($Command.role)" }
    $expectedHash = [string]$Command.expectedTargetHash
    if ([string]::IsNullOrWhiteSpace($expectedHash)) { throw "TASK_STATE_COMPLETION_ARCHIVE_HASH_REQUIRED role=$($Command.role)" }
    $archiveHash = Get-FileSha256 $archivePath
    if ($archiveHash -and $archiveHash -ne $expectedHash) { throw "TASK_STATE_COMPLETION_ARCHIVE_CONFLICT role=$($Command.role)" }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
      if ($currentHash -ne $expectedHash) { throw "TASK_STATE_COMPLETION_TARGET_CHANGED role=$($Command.role)" }
      $current = Read-JsonFile $target
      if (-not $current -or [string]$current.taskId -ne $Id -or (-not [string]::IsNullOrWhiteSpace($WorkspaceKey) -and -not (Test-CompletionWorkspace $current $WorkspaceKey))) { throw "TASK_STATE_COMPLETION_ARCHIVE_IDENTITY_MISMATCH role=$($Command.role)" }
      if (-not $archiveHash) {
        $archiveDir = Split-Path -Parent $archivePath
        if (-not [IO.Directory]::Exists($archiveDir)) { New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null }
        Copy-Item -LiteralPath $target -Destination $archivePath -Force
        if ((Get-FileSha256 $archivePath) -ne $expectedHash) { throw "TASK_STATE_COMPLETION_ARCHIVE_HASH_MISMATCH role=$($Command.role)" }
      }
    } elseif (-not $archiveHash) {
      throw "TASK_STATE_COMPLETION_ARCHIVE_SOURCE_MISSING role=$($Command.role)"
    }
    if ($operation -in @('archive_identity','quarantine_identity')) {
      if (Test-Path -LiteralPath $target -PathType Leaf) {
        if ((Get-FileSha256 $target) -ne $expectedHash) { throw "TASK_STATE_COMPLETION_TARGET_CHANGED_BEFORE_REMOVE role=$($Command.role)" }
        Remove-Item -LiteralPath $target -Force
      }
      $verb = if ($operation -eq 'quarantine_identity') { 'quarantined' } else { 'archived' }
      return [pscustomobject]@{ role=$Command.role; action=if($currentHash){$verb}else{'already_'+$verb}; changed=[bool]$currentHash; archivePath=$archivePath; archiveHash=$expectedHash }
    }
    if (-not $payloadPath) { throw "TASK_STATE_COMPLETION_ARCHIVE_REPLACEMENT_REQUIRED role=$($Command.role)" }
    if ($currentHash -ne $desiredHash) { $null = Materialize-Payload $payloadPath $target $TransactionId }
    return [pscustomobject]@{ role=$Command.role; action=if($currentHash-eq$desiredHash){'already_archived_and_replaced'}else{'archived_and_replaced'}; changed=($currentHash-ne$desiredHash); archivePath=$archivePath; archiveHash=$expectedHash }
  }
  if ($operation -eq 'delete_identity') {
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return [pscustomobject]@{ role=$Command.role; action='already_absent'; changed=$false } }
    if ([string]$Command.expectedTargetHash -and $currentHash -ne [string]$Command.expectedTargetHash) { throw "TASK_STATE_COMPLETION_TARGET_CHANGED role=$($Command.role)" }
    $current = Read-JsonFile $target
    if (-not $current -or [string]$current.taskId -ne $Id -or (-not [string]::IsNullOrWhiteSpace($WorkspaceKey) -and -not (Test-CompletionWorkspace $current $WorkspaceKey))) { throw "TASK_STATE_COMPLETION_DELETE_IDENTITY_MISMATCH role=$($Command.role)" }
    Remove-Item -LiteralPath $target -Force
    return [pscustomobject]@{ role=$Command.role; action='deleted'; changed=$true }
  }
  if ($operation -in @('upsert','replace_if_hash')) {
    $expectedHash = [string]$Command.expectedTargetHash
    if ($operation -eq 'replace_if_hash' -and $currentHash -ne $expectedHash) {
      if (-not $desiredHash -and -not $currentHash) { return [pscustomobject]@{ role=$Command.role; action='already_absent'; changed=$false } }
      throw "TASK_STATE_COMPLETION_TARGET_CHANGED role=$($Command.role)"
    }
    if ($operation -eq 'upsert' -and $expectedHash -and $currentHash -ne $expectedHash) { throw "TASK_STATE_COMPLETION_TARGET_CHANGED role=$($Command.role)" }
    if ($operation -eq 'upsert' -and -not $expectedHash -and $currentHash -and $currentHash -ne $desiredHash) { throw "TASK_STATE_COMPLETION_TARGET_ALREADY_EXISTS role=$($Command.role)" }
    if ($payloadPath) { $null = Materialize-Payload $payloadPath $target $TransactionId; return [pscustomobject]@{ role=$Command.role; action='upserted'; changed=$true } }
    if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
    return [pscustomobject]@{ role=$Command.role; action='removed'; changed=$true }
  }
  throw "TASK_STATE_COMPLETION_OPERATION_INVALID operation=$operation"
}

function Add-UniqueCompletionCommand([System.Collections.ArrayList]$Commands,[hashtable]$Seen,[object]$Command) {
  if (-not $Command) { return }
  $key = ([string]$Command.targetPath).ToLowerInvariant()
  if ($Seen.ContainsKey($key)) { return }
  $Seen[$key] = $true
  [void]$Commands.Add($Command)
}

function Get-MatchingCompletionFiles([string]$RootPath,[string]$Pattern,[string]$Id,[string]$WorkspaceKey,[scriptblock]$Predicate) {
  $items = @()
  if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) { return @() }
  foreach ($file in @(Get-ChildItem -LiteralPath $RootPath -Filter $Pattern -File -ErrorAction SilentlyContinue)) {
    $value = Read-JsonFile $file.FullName
    if (-not $value -or [string]$value.taskId -ne $Id -or -not (Test-CompletionWorkspace $value $WorkspaceKey)) { continue }
    if (& $Predicate $value) { $items += [pscustomobject]@{ path=$file.FullName; value=$value; hash=Get-FileSha256 $file.FullName } }
  }
  return @($items)
}

function New-ResolvedCompletionState([object]$Value,[string]$Kind,[string]$Id,[string]$WorkspaceKey) {
  $copy = $Value | ConvertTo-Json -Depth 14 | ConvertFrom-Json
  $copy | Add-Member -NotePropertyName taskId -NotePropertyValue $Id -Force
  if (-not [string]::IsNullOrWhiteSpace($WorkspaceKey)) { $copy | Add-Member -NotePropertyName workspaceKey -NotePropertyValue $WorkspaceKey -Force }
  $copy | Add-Member -NotePropertyName checkedAt -NotePropertyValue (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') -Force
  if ($Kind -eq 'goal_lock') {
    $copy | Add-Member -NotePropertyName status -NotePropertyValue 'cleared' -Force
    $copy | Add-Member -NotePropertyName active -NotePropertyValue $false -Force
    $copy | Add-Member -NotePropertyName action -NotePropertyValue 'Clear' -Force
    $copy | Add-Member -NotePropertyName guard -NotePropertyValue 'Goal route lock closed by the committed task completion transaction.' -Force
  } else {
    $copy | Add-Member -NotePropertyName status -NotePropertyValue 'resolved' -Force
    $copy | Add-Member -NotePropertyName unresolvedRouteDrift -NotePropertyValue $false -Force
    $copy | Add-Member -NotePropertyName phase -NotePropertyValue 'Clear' -Force
    $copy | Add-Member -NotePropertyName violations -NotePropertyValue @() -Force
    $copy | Add-Member -NotePropertyName blockers -NotePropertyValue @() -Force
    $copy | Add-Member -NotePropertyName guard -NotePropertyValue 'Route checkpoint closed by the committed task completion transaction.' -Force
  }
  return $copy
}

function New-TerminalPlanSeal([string]$Id,[string]$WorkspaceKey,[object]$ContractRecord,[object]$Manifest,[string]$PackageVersion,[object]$IntentCompletion,[object]$CompletedCheckpointRecord=$null,[object]$CompletedTaskCardRecord=$null) {
  $contract = if($ContractRecord -and $ContractRecord.value){$ContractRecord.value}else{$null}
  $canonicalPlan = if ($contract -and $contract.PSObject.Properties['canonicalPlan'] -and $contract.canonicalPlan) { $contract.canonicalPlan | ConvertTo-Json -Depth 14 | ConvertFrom-Json } else { $null }
  $legacySource = if($contract){$contract}elseif($CompletedCheckpointRecord -and $CompletedCheckpointRecord.value){$CompletedCheckpointRecord.value}elseif($CompletedTaskCardRecord -and $CompletedTaskCardRecord.value){$CompletedTaskCardRecord.value}else{$null}
  if(-not$canonicalPlan-and-not$legacySource){throw 'TASK_STATE_COMPLETION_TERMINAL_PLAN_EVIDENCE_REQUIRED'}
  $legacyPlan = if ($canonicalPlan) { $null } else {
    [pscustomobject]@{
      focusId = Limit-Text ([string]$legacySource.focusId) 120
      currentPhase = Limit-Text ([string]$legacySource.currentPhase) 120
      currentStep = Limit-Text ([string]$legacySource.currentStep) 220
      completedSteps = @($legacySource.completedSteps | ForEach-Object { Limit-Text ([string]$_) 180 })
      pendingSteps = @($legacySource.pendingSteps | ForEach-Object { Limit-Text ([string]$_) 180 })
    }
  }
  return [pscustomobject]@{
    schema = 'super-brain.terminal-plan-seal.v1'
    taskId = $Id
    workspaceKey = $WorkspaceKey
    packageVersion = $PackageVersion
    ownerSessionKey = [string]$Manifest.ownerSessionKey
    contractRevision = [int]$Manifest.expectedContractRevision
    planFingerprint = [string]$Manifest.expectedPlanFingerprint
    evidenceBinding = if($Manifest.PSObject.Properties['evidenceBinding'] -and $Manifest.evidenceBinding){$Manifest.evidenceBinding | ConvertTo-Json -Depth 6 | ConvertFrom-Json}else{$null}
    decisionBinding = if($contract -and $contract.PSObject.Properties['decisionBinding'] -and $contract.decisionBinding){$contract.decisionBinding | ConvertTo-Json -Depth 8 | ConvertFrom-Json}else{$null}
    intentCompletion = if($IntentCompletion){$IntentCompletion | ConvertTo-Json -Depth 8 | ConvertFrom-Json}else{$null}
    canonicalPlan = $canonicalPlan
    legacyPlan = $legacyPlan
    sourceContractHash = if($ContractRecord){[string]$ContractRecord.hash}else{''}
    sealedAt = (Get-Date).ToString('o')
    terminalStatus = 'completed'
    rawPromptStored = $false
    rawTranscriptStored = $false
    rawSessionIdStored = $false
  }
}

function New-TaskCompletionReceipt(
  [string]$Id,
  [string]$WorkspaceKey,
  [string]$TransactionId,
  [int]$TargetRevision,
  [object]$Manifest,
  [object]$ContractRecord,
  [object]$VerificationRecord,
  [object]$IntentCompletion,
  [string]$ManifestHash,
  [string]$TerminalPlanSealHash,
  [string]$CallerSessionKey,
  [string]$PackageVersion
) {
  $contract = if($ContractRecord -and $ContractRecord.value){$ContractRecord.value}else{$null}
  return [pscustomobject]@{
    schema = 'super-brain.task-completion-receipt.v1'
    taskId = $Id
    workspaceKey = $WorkspaceKey
    transactionId = $TransactionId
    targetRevision = $TargetRevision
    taskInstanceId = if($contract){[string]$contract.taskInstanceId}else{''}
    ownerSessionKey = [string]$Manifest.ownerSessionKey
    callerSessionKey = Get-SuperBrainLocalSessionKey $CallerSessionKey
    packageVersion = $PackageVersion
    contractRevision = [int]$Manifest.expectedContractRevision
    planFingerprint = [string]$Manifest.expectedPlanFingerprint
    manifestHash = $ManifestHash
    contractHash = if($ContractRecord){[string]$ContractRecord.hash}else{''}
    verificationHash = if($VerificationRecord){[string]$VerificationRecord.hash}else{''}
    terminalPlanSealHash = $TerminalPlanSealHash
    evidenceBinding = if($VerificationRecord -and $VerificationRecord.evidenceBinding){$VerificationRecord.evidenceBinding | ConvertTo-Json -Depth 6 | ConvertFrom-Json}else{$null}
    decisionBinding = if($VerificationRecord -and $VerificationRecord.value -and $VerificationRecord.value.PSObject.Properties['decisionBinding']){$VerificationRecord.value.decisionBinding | ConvertTo-Json -Depth 8 | ConvertFrom-Json}elseif($contract -and $contract.PSObject.Properties['decisionBinding']){$contract.decisionBinding | ConvertTo-Json -Depth 8 | ConvertFrom-Json}else{$null}
    intentCompletion = if($IntentCompletion){$IntentCompletion | ConvertTo-Json -Depth 8 | ConvertFrom-Json}else{$null}
    receiptState = 'prepared'
    createdAt = (Get-Date).ToString('o')
    rawPromptStored = $false
    rawTranscriptStored = $false
    rawSessionIdStored = $false
  }
}

function Build-TaskCompletionCommands(
  [string]$Id,
  [string]$WorkspaceKey,
  [string]$TransactionId,
  [object]$Projection,
  [object]$Manifest,
  [object]$CompletedCheckpoint,
  [object]$CompletedTaskCard,
  [object]$Contract,
  [object]$Verification,
  [object]$IntentCompletion,
  [string]$ManifestHash,
  [string]$CallerSessionKey,
  [int]$TargetRevision
) {
  $commands = New-Object System.Collections.ArrayList
  $seen = @{}
  $completedCheckpointTarget = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\checkpoints\completed') $Id '.json'
  $completedTaskCardTarget = Get-SuperBrainCanonicalTaskPath (Join-Path $SharedRoot 'tasks\completed') $Id '.task.json'
  $terminalPlanSealTarget = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'task-state-store\terminal-plan-seals') $Id '.json'
  $terminalPlanSealValue = New-TerminalPlanSeal $Id $WorkspaceKey $Contract $Manifest ([string](Get-SuperBrainManifest $Root).version) $IntentCompletion $CompletedCheckpoint $CompletedTaskCard
  $terminalPlanSealPayload = Write-CompletionStagingValue $Id $TransactionId 'terminal-plan-seal' $terminalPlanSealValue
  Add-UniqueCompletionCommand $commands $seen (New-CompletionCommand 'terminal_plan_seal' 'upsert' $terminalPlanSealTarget $terminalPlanSealPayload (Get-FileSha256 $terminalPlanSealTarget) $Id $WorkspaceKey)
  Add-UniqueCompletionCommand $commands $seen (New-CompletionCommand 'completed_checkpoint' 'upsert' $completedCheckpointTarget $CompletedCheckpoint.path (Get-FileSha256 $completedCheckpointTarget) $Id $WorkspaceKey)
  Add-UniqueCompletionCommand $commands $seen (New-CompletionCommand 'completed_task_card' 'upsert' $completedTaskCardTarget $CompletedTaskCard.path (Get-FileSha256 $completedTaskCardTarget) $Id $WorkspaceKey)
  Add-UniqueCompletionCommand $commands $seen (New-CompletionCommand 'last_completed_checkpoint' 'replace_if_hash' (Join-Path $WorkspaceRoot 'last-completed-checkpoint.json') $CompletedCheckpoint.path (Get-FileSha256 (Join-Path $WorkspaceRoot 'last-completed-checkpoint.json')) $Id $WorkspaceKey)

  $activeCheckpointRoot = Join-Path $WorkspaceRoot 'runtime-state\checkpoints\active'
  foreach ($item in @(Get-MatchingCompletionFiles $activeCheckpointRoot '*.json' $Id $WorkspaceKey { param($v) [string]$v.status -eq 'active' })) {
    Add-UniqueCompletionCommand $commands $seen (New-ArchivedCompletionCommand 'active_checkpoint' 'archive_identity' $item.path $TransactionId '' $item.hash $Id $WorkspaceKey)
  }
  $contextRoot = Join-Path $WorkspaceRoot 'guard-state\current-task-contexts'
  foreach ($item in @(Get-MatchingCompletionFiles $contextRoot '*.json' $Id $WorkspaceKey { param($v) [string]$v.status -eq 'active' })) {
    Add-UniqueCompletionCommand $commands $seen (New-ArchivedCompletionCommand 'current_context' 'archive_identity' $item.path $TransactionId '' $item.hash $Id $WorkspaceKey)
  }
  foreach ($life in @('active','paused','blocked')) {
    $taskRoot = Join-Path $SharedRoot ("tasks\" + $life)
    foreach ($item in @(Get-MatchingCompletionFiles $taskRoot '*.task.json' $Id $WorkspaceKey { param($v) [string]$v.status -notin @('completed','verified','cancelled','archived') })) {
      Add-UniqueCompletionCommand $commands $seen (New-ArchivedCompletionCommand 'active_task_card' 'archive_identity' $item.path $TransactionId '' $item.hash $Id $WorkspaceKey)
    }
  }

  $contextReplacement = Find-UniqueCompletionRecord $contextRoot '*.json' $Id $WorkspaceKey { param($v) [string]$v.status -eq 'active' }
  $contextReplacementValue = if($contextReplacement){$contextReplacement.value}else{$null}
  $workspacePointer = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'guard-state\current-task-context-pointers') $WorkspaceKey '.json'
  Add-UniqueCompletionCommand $commands $seen (New-CompletionPointerCommand 'workspace_context_pointer' $workspacePointer $Id $WorkspaceKey $contextReplacementValue $TransactionId)
  Add-UniqueCompletionCommand $commands $seen (New-CompletionPointerCommand 'legacy_context_pointer' (Join-Path $WorkspaceRoot 'current-task-context.json') $Id $WorkspaceKey $contextReplacementValue $TransactionId)

  $checkpointReplacement = Find-UniqueCompletionRecord $activeCheckpointRoot '*.json' $Id $WorkspaceKey { param($v) [string]$v.status -eq 'active' }
  $checkpointReplacementValue = if($checkpointReplacement){$checkpointReplacement.value}else{$null}
  Add-UniqueCompletionCommand $commands $seen (New-CompletionPointerCommand 'checkpoint_pointer' (Join-Path $WorkspaceRoot 'active-checkpoint.json') $Id $WorkspaceKey $checkpointReplacementValue $TransactionId)

  $contractRoot = Join-Path $WorkspaceRoot 'runtime-state\execution-contracts'
  foreach ($item in @(Get-MatchingCompletionFiles $contractRoot '*.json' $Id $WorkspaceKey { param($v) [string]$v.status -eq 'active' })) {
    Add-UniqueCompletionCommand $commands $seen (New-ArchivedCompletionCommand 'execution_contract' 'archive_identity' $item.path $TransactionId '' $item.hash $Id $WorkspaceKey)
  }
  $contractReplacement = Find-UniqueCompletionRecord $contractRoot '*.json' $Id $WorkspaceKey { param($v) [string]$v.status -eq 'active' }
  $contractReplacementValue = if($contractReplacement){$contractReplacement.value}else{$null}
  Add-UniqueCompletionCommand $commands $seen (New-CompletionPointerCommand 'contract_pointer' (Join-Path $WorkspaceRoot 'last-execution-contract.json') $Id $WorkspaceKey $contractReplacementValue $TransactionId)

  $goalRoot = Join-Path $WorkspaceRoot 'guard-state\goal-route-locks'
  foreach ($item in @(Get-MatchingCompletionFiles $goalRoot '*.json' $Id $WorkspaceKey { param($v) $v.active -eq $true -or [string]$v.status -eq 'active' })) {
    $resolved = New-ResolvedCompletionState $item.value 'goal_lock' $Id $WorkspaceKey
    $payload = Write-CompletionStagingValue $Id $TransactionId ('goal-lock-' + (Get-ShortHash $item.path)) $resolved
    Add-UniqueCompletionCommand $commands $seen (New-ArchivedCompletionCommand 'goal_route_lock' 'archive_replace' $item.path $TransactionId $payload $item.hash $Id $WorkspaceKey)
  }
  $goalReplacement = Find-UniqueCompletionRecord $goalRoot '*.json' $Id $WorkspaceKey { param($v) $v.active -eq $true -and [string]$v.status -eq 'active' }
  $goalReplacementValue = if($goalReplacement){$goalReplacement.value}else{$null}
  Add-UniqueCompletionCommand $commands $seen (New-CompletionPointerCommand 'goal_lock_pointer' (Join-Path $WorkspaceRoot 'goal-route-lock.json') $Id $WorkspaceKey $goalReplacementValue $TransactionId)

  $routeRoot = Join-Path $WorkspaceRoot 'guard-state\route-checkpoints'
  foreach ($item in @(Get-MatchingCompletionFiles $routeRoot '*.json' $Id $WorkspaceKey { param($v) [string]$v.status -in @('clean','route_drift_detected') })) {
    $resolved = New-ResolvedCompletionState $item.value 'route_checkpoint' $Id $WorkspaceKey
    $payload = Write-CompletionStagingValue $Id $TransactionId ('route-checkpoint-' + (Get-ShortHash $item.path)) $resolved
    Add-UniqueCompletionCommand $commands $seen (New-ArchivedCompletionCommand 'route_checkpoint' 'archive_replace' $item.path $TransactionId $payload $item.hash $Id $WorkspaceKey)
  }
  $routeReplacement = Find-UniqueCompletionRecord $routeRoot '*.json' $Id $WorkspaceKey { param($v) [string]$v.status -eq 'clean' }
  $routeReplacementValue = if($routeReplacement){$routeReplacement.value}else{$null}
  Add-UniqueCompletionCommand $commands $seen (New-CompletionPointerCommand 'route_checkpoint_pointer' (Join-Path $WorkspaceRoot 'route-checkpoint.json') $Id $WorkspaceKey $routeReplacementValue $TransactionId)

  $hotRoot = Join-Path $WorkspaceRoot 'runtime-state\execution-hot-index'
  if (Test-Path -LiteralPath $hotRoot -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $hotRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $index = Read-JsonFile $file.FullName
      if (-not $index -or -not (Test-SuperBrainWorkspaceKey ([string]$index.workspaceKey) $WorkspaceKey)) { continue }
      $entries = @($index.entries)
      if (@($entries | Where-Object { [string]$_.taskId -eq $Id }).Count -eq 0) { continue }
      $remaining = @($entries | Where-Object { [string]$_.taskId -ne $Id })
      $payload = ''
      if ($remaining.Count -gt 0) {
        $index.entries = @($remaining)
        $index.entryCount = $remaining.Count
        $index.updatedAt = (Get-Date).ToString('o')
        $payload = Write-CompletionStagingValue $Id $TransactionId ('hot-index-' + (Get-ShortHash $file.FullName)) $index
      }
      Add-UniqueCompletionCommand $commands $seen (New-CompletionCommand 'execution_hot_index' 'replace_if_hash' $file.FullName $payload (Get-FileSha256 $file.FullName) $Id $WorkspaceKey)
    }
  }

  # P5: legacy global step-ledger/task-graph files are migration diagnostics,
  # never current completion authority. Canonical contract, checkpoint, and
  # TaskStateStore state decide whether a task can close. Historical prepared
  # transactions remain replayable through their already-recorded commands.
  $terminalPlanSealCommand = @($commands | Where-Object { [string]$_.role -eq 'terminal_plan_seal' } | Select-Object -First 1)
  $terminalPlanSealHash = if($terminalPlanSealCommand.Count -eq 1){[string]$terminalPlanSealCommand[0].payloadHash}else{''}
  if ([string]::IsNullOrWhiteSpace($terminalPlanSealHash)) { throw 'TASK_STATE_COMPLETION_TERMINAL_PLAN_SEAL_REQUIRED' }
  $receiptTarget = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\task-completion-receipts') $Id '.json'
  $receiptValue = New-TaskCompletionReceipt $Id $WorkspaceKey $TransactionId $TargetRevision $Manifest $Contract $Verification $IntentCompletion $ManifestHash $terminalPlanSealHash $CallerSessionKey ([string](Get-SuperBrainManifest $Root).version)
  $receiptPayload = Write-CompletionStagingValue $Id $TransactionId 'task-completion-receipt' $receiptValue
  Add-UniqueCompletionCommand $commands $seen (New-CompletionCommand 'task_completion_receipt' 'upsert' $receiptTarget $receiptPayload (Get-FileSha256 $receiptTarget) $Id $WorkspaceKey)
  return @($commands)
}

function Get-TaskCompletionActiveRecords([string]$Id,[string]$WorkspaceKey) {
  $records = New-Object System.Collections.ArrayList
  function Add-ActiveRecord([string]$Kind,[string]$Path,[object]$Value) { [void]$records.Add([pscustomobject]@{ kind=$Kind; path=$Path; status=if($Value.PSObject.Properties['status']){[string]$Value.status}else{'active'} }) }
  foreach ($spec in @(
    [pscustomobject]@{kind='context';root=(Join-Path $WorkspaceRoot 'guard-state\current-task-contexts');pattern='*.json';active={param($v)[string]$v.status -eq 'active'}},
    [pscustomobject]@{kind='checkpoint';root=(Join-Path $WorkspaceRoot 'runtime-state\checkpoints\active');pattern='*.json';active={param($v)[string]$v.status -eq 'active'}},
    [pscustomobject]@{kind='task_card';root=(Join-Path $SharedRoot 'tasks\active');pattern='*.task.json';active={param($v)[string]$v.status -notin @('completed','verified','cancelled','archived')}},
    [pscustomobject]@{kind='task_card';root=(Join-Path $SharedRoot 'tasks\paused');pattern='*.task.json';active={param($v)[string]$v.status -notin @('completed','verified','cancelled','archived')}},
    [pscustomobject]@{kind='task_card';root=(Join-Path $SharedRoot 'tasks\blocked');pattern='*.task.json';active={param($v)[string]$v.status -notin @('completed','verified','cancelled','archived')}},
    [pscustomobject]@{kind='contract';root=(Join-Path $WorkspaceRoot 'runtime-state\execution-contracts');pattern='*.json';active={param($v)[string]$v.status -eq 'active'}},
    [pscustomobject]@{kind='goal_lock';root=(Join-Path $WorkspaceRoot 'guard-state\goal-route-locks');pattern='*.json';active={param($v)$v.active -eq $true -or [string]$v.status -eq 'active'}},
    [pscustomobject]@{kind='route_checkpoint';root=(Join-Path $WorkspaceRoot 'guard-state\route-checkpoints');pattern='*.json';active={param($v)[string]$v.status -in @('clean','route_drift_detected')}}
  )) {
    foreach ($item in @(Get-MatchingCompletionFiles $spec.root $spec.pattern $Id $WorkspaceKey $spec.active)) { Add-ActiveRecord $spec.kind $item.path $item.value }
  }
  foreach ($pointer in @('current-task-context.json','active-checkpoint.json','goal-route-lock.json','route-checkpoint.json','last-execution-contract.json')) {
    $path = Join-Path $WorkspaceRoot $pointer
    $value = Read-JsonFile $path
    if ($value -and [string]$value.taskId -eq $Id) { Add-ActiveRecord 'compatibility_pointer' $path $value }
  }
  $workspacePointer = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'guard-state\current-task-context-pointers') $WorkspaceKey '.json'
  $workspacePointerValue = Read-JsonFile $workspacePointer
  if ($workspacePointerValue -and [string]$workspacePointerValue.taskId -eq $Id) { Add-ActiveRecord 'workspace_pointer' $workspacePointer $workspacePointerValue }
  $hotRoot = Join-Path $WorkspaceRoot 'runtime-state\execution-hot-index'
  if (Test-Path -LiteralPath $hotRoot -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $hotRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $index = Read-JsonFile $file.FullName
      if ($index -and @($index.entries | Where-Object { [string]$_.taskId -eq $Id }).Count -gt 0) { Add-ActiveRecord 'execution_hot_index' $file.FullName $index }
    }
  }
  return @($records)
}

function New-TaskCompletionEntityRecord([string]$Path,[string]$Hash,[string]$Status,[string]$Source,[object]$Owner) {
  return [pscustomobject]@{ path=[IO.Path]::GetFullPath($Path); hash=$Hash; status=$Status; source=Limit-Text $Source 120; owner=$Owner }
}

function Commit-TaskCompletionProjection([object]$Projection,[string]$Id,[object]$Entities,[object]$Lifecycle,[int]$Revision,[string]$EventId,[string]$When) {
  $Projection = Ensure-ProjectionShape $Projection $Id
  Set-EntityValue $Projection 'context' $Entities.context
  Set-EntityValue $Projection 'checkpoint' $Entities.checkpoint
  Set-EntityValue $Projection 'task_card' $Entities.task_card
  $Projection.lifecycle = $Lifecycle
  $Projection.revision = $Revision
  $Projection.updatedAt = $When
  $Projection.lastEventId = $EventId
  Write-JsonUtf8NoBom (Get-ProjectionPath $Id) $Projection 12
  $null = Update-Index $Projection
}

function Invoke-TaskCompletionMaterialization([object[]]$Commands,[string]$Id,[string]$WorkspaceKey,[string]$TransactionId,[int]$FaultAfter=0) {
  $results = @()
  $index = 0
  try {
    foreach ($command in @($Commands)) {
      $index++
      $commandWorkspaceKey = if ($command -and $command.PSObject.Properties['expectedWorkspaceKey']) { [string]$command.expectedWorkspaceKey } else { $WorkspaceKey }
      $backup = New-TaskMaterializationBackup $command $Id $commandWorkspaceKey $TransactionId $index
      # Register the backup before invoking the command.  Some commands copy
      # an archive and then remove/replace the source; if the second operation
      # fails, the target may already be changed even though the command throws.
      # Keeping the record in the rollback set closes that single-command
      # partial-materialization window.
      $record = [pscustomobject]@{
        targetPath = [string]$backup.targetPath
        beforeExists = [bool]$backup.beforeExists
        beforePath = [string]$backup.beforePath
        beforeHash = [string]$backup.beforeHash
        rollbackRoot = [string]$backup.rollbackRoot
        expectedAfterExists = [bool]$backup.expectedAfterExists
        expectedAfterHash = [string]$backup.expectedAfterHash
        role = [string]$backup.role
        ordinal = [int]$backup.ordinal
        action = 'pending'
        changed = $false
        postStateKnown = $false
      }
      $results += $record
      $materialized = Materialize-CompletionCommand $command $Id $commandWorkspaceKey $TransactionId
      foreach ($property in @($materialized.PSObject.Properties)) {
        if ($property.Name -in @('targetPath','beforeExists','beforePath','beforeHash','rollbackRoot','expectedAfterExists','expectedAfterHash','role','ordinal')) { continue }
        $record | Add-Member -NotePropertyName ([string]$property.Name) -NotePropertyValue $property.Value -Force
      }
      $observedExists = Test-Path -LiteralPath ([string]$record.targetPath) -PathType Leaf
      $observedHash = if ($observedExists) { Get-FileSha256 ([string]$record.targetPath) } else { '' }
      $record | Add-Member -NotePropertyName observedAfterExists -NotePropertyValue ([bool]$observedExists) -Force
      $record | Add-Member -NotePropertyName observedAfterHash -NotePropertyValue $observedHash -Force
      # A command may be a safe no-op (foreign pointer preserved, pointer
      # absent, already materialized).  Capture the actual post-command state
      # so a later failure does not reject rollback merely because the desired
      # payload was not installed by that no-op.
      $record | Add-Member -NotePropertyName expectedAfterExists -NotePropertyValue ([bool]$observedExists) -Force
      $record | Add-Member -NotePropertyName expectedAfterHash -NotePropertyValue $observedHash -Force
      if ($observedExists) { $record | Add-Member -NotePropertyName afterHash -NotePropertyValue $observedHash -Force }
      $record | Add-Member -NotePropertyName postStateKnown -NotePropertyValue $true -Force
      if ($FaultAfter -gt 0 -and $index -eq $FaultAfter) {
        # This is an intentional crash point used by the transaction recovery
        # regression.  Preserve the already-materialized prefix and prepared
        # WAL so explicit Reconcile can replay the same command list.  A real
        # materializer exception below still follows the normal rollback path.
        throw "TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZATION boundary=$index"
      }
    }
  } catch {
    # A genuine materialization/validation failure must not leave a partially
    # replaced contract, context, checkpoint, or pointer.  The intentional
    # FaultAfterMaterialization marker is the one exception: it preserves the
    # already-materialized prefix for explicit prepared-WAL reconciliation.
    if (-not (Test-TaskStateMaterializationFaultInjected $_.Exception.Message) -and $results.Count -gt 0) { Restore-TaskMaterialization $results }
    throw
  }
  return @($results)
}

function Remove-TaskCompletionStaging([object[]]$Commands,[string]$ManifestPath,[object[]]$Materialization=@()) {
  foreach ($command in @($Commands)) { Remove-StagingPayload ([string]$command.payloadPath) }
  Remove-StagingPayload $ManifestPath
  $rollbackRoots = @($Materialization | ForEach-Object {
      if ($_.PSObject.Properties['rollbackRoot'] -and -not [string]::IsNullOrWhiteSpace([string]$_.rollbackRoot)) {
        [string]$_.rollbackRoot
      } elseif (-not [string]::IsNullOrWhiteSpace([string]$_.beforePath)) {
        Split-Path -Parent ([string]$_.beforePath)
      }
    } | Select-Object -Unique)
  foreach ($root in $rollbackRoots) {
    if ((Test-ChildPath $stagingRoot $root) -and (Test-Path -LiteralPath $root -PathType Container)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Complete-TaskState([string]$Id,[string]$ManifestPath,[int]$Expected,[string]$Writer,[switch]$Override,[string]$Reason) {
  if ([string]::IsNullOrWhiteSpace($Id)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  if ($Expected -lt 0 -and -not $Override) { throw "TASK_STATE_REVISION_REQUIRED taskId=$Id" }
  $manifestRecord = Assert-CompletionManifest $ManifestPath $Id
  $manifestValue = $manifestRecord.value
  $packageVersion = [string](Get-SuperBrainManifest $Root).version
  if ([string]$manifestValue.packageVersion -ne $packageVersion) { throw 'TASK_STATE_COMPLETION_MANIFEST_VERSION_MISMATCH' }
  $workspaceKey = Get-SuperBrainWorkspaceKey ([string]$manifestValue.workspaceKey)
  if ([string]::IsNullOrWhiteSpace([string]$manifestValue.workspaceKey)) { throw 'TASK_STATE_COMPLETION_WORKSPACE_REQUIRED' }
  $completionStatus = ([string]$manifestValue.completionStatus).ToLowerInvariant()
  if ($completionStatus -ne 'completed') { throw "TASK_STATE_COMPLETION_STATUS_UNSUPPORTED status=$completionStatus" }
  if ([string]::IsNullOrWhiteSpace([string]$manifestValue.ownerSessionKey) -and -not $Override) { throw 'TASK_STATE_COMPLETION_SESSION_REQUIRED' }
  if ([string]::IsNullOrWhiteSpace([string]$manifestValue.expectedPlanFingerprint) -and -not $Override) { throw 'TASK_STATE_COMPLETION_PLAN_FINGERPRINT_REQUIRED' }
  $callerSessionKey = Get-SuperBrainLocalSessionKey $CallerSessionKey
  if ([string]::IsNullOrWhiteSpace($callerSessionKey) -and -not $Override) { throw 'TASK_STATE_COMPLETION_CALLER_SESSION_REQUIRED' }

  $completedCheckpoint = Assert-CompletionPayload ([string]$manifestValue.completedCheckpointPayloadPath) $Id $workspaceKey 'completed' 'CHECKPOINT'
  $completedTaskCard = Assert-CompletionPayload ([string]$manifestValue.completedTaskCardPayloadPath) $Id $workspaceKey 'completed' 'TASK_CARD'
  $contract = Assert-CompletionContract $manifestValue $Id $workspaceKey $packageVersion $callerSessionKey -Override:$Override
  $verification = Assert-CompletionVerification $manifestValue $Id $workspaceKey $packageVersion -Override:$Override
  $decisionBinding = Assert-CompletionDecisionBinding $contract $verification $Id $workspaceKey $packageVersion -Override:$Override
  $intentCompletion = Assert-CompletionIntent $contract $verification $Id $workspaceKey $packageVersion -Override:$Override

  return Invoke-SuperBrainFileLock $mutationGate {
    # Re-read all mutable completion evidence under the mutation lock to close the
    # preflight-to-materialization window for direct and recovery-adjacent callers.
    # The preflight above performs the full receipt validation. Re-entering that
    # validator here would start a child PowerShell process while this mutation
    # lock is held, which can self-deadlock. A byte-identical contract is the
    # required in-lock proof that the already validated receipt is still current.
    if (-not $Override -and (Get-FileSha256 ([string]$contract.path)) -ne [string]$contract.hash) {
      throw 'TASK_STATE_COMPLETION_CONTRACT_CHANGED_AFTER_PRECHECK'
    }
    $verification = Assert-CompletionVerification $manifestValue $Id $workspaceKey $packageVersion -Override:$Override
    $lockedIntentCompletion = Assert-CompletionIntent $contract $verification $Id $workspaceKey $packageVersion -Override:$Override -SkipReceiptCheck
    if ([string]$lockedIntentCompletion.fulfillmentFingerprint -ne [string]$intentCompletion.fulfillmentFingerprint -or [string]$lockedIntentCompletion.intentContractFingerprint -ne [string]$intentCompletion.intentContractFingerprint) { throw 'TASK_STATE_COMPLETION_INTENT_CHANGED_AFTER_PRECHECK' }
    $intentCompletion = $lockedIntentCompletion
    foreach ($result in @($decisionBinding.results)) {
      if ([string]::IsNullOrWhiteSpace([string]$result.resultPath) -or (Get-FileSha256 ([string]$result.resultPath)) -ne [string]$result.resultHash) { throw 'TASK_STATE_COMPLETION_DECISION_RESULT_CHANGED_AFTER_PRECHECK' }
    }
    Assert-NoIncompleteTaskTransaction $Id
    $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $Id)) $Id
    $actualRevision = [int]$projection.revision
    if ($Expected -ge 0 -and $Expected -ne $actualRevision) { throw "TASK_STATE_CAS_MISMATCH expected=$Expected actual=$actualRevision taskId=$Id" }
    if ([string]$projection.lifecycle.status -eq 'quarantined') { throw "TASK_STATE_QUARANTINED_REQUIRES_RECONCILIATION taskId=$Id" }
    if ([string]$projection.lifecycle.status -in @('completed','cancelled','archived')) {
      $residualCount=@(Get-TaskCompletionActiveRecords $Id $workspaceKey).Count
      if($residualCount-gt0){throw "TASK_STATE_COMPLETION_RESIDUAL_STATE_REQUIRES_RECONCILIATION count=$residualCount taskId=$Id"}
      return [pscustomobject]@{ ok=$true; changed=$false; taskId=$Id; revision=$actualRevision; lifecycleStatus=[string]$projection.lifecycle.status; transactionId=[string]$projection.lifecycle.completionTransactionId; activeStateCount=0 }
    }
    $activeCheckpointEntity = Get-EntityValue $projection 'checkpoint'
    $activeTaskCardEntity = Get-EntityValue $projection 'task_card'
    if (-not $Override -and (-not $activeCheckpointEntity -or -not $activeTaskCardEntity)) { throw 'TASK_STATE_COMPLETION_REQUIRED_ENTITIES_MISSING' }
    $authorityEntity = if ($activeCheckpointEntity) { $activeCheckpointEntity } else { $activeTaskCardEntity }
    $requestOwner = New-OwnerRecord $completedCheckpoint.value $OwnerAgentId $OwnerSessionId $OwnerPlatform $OwnerWorkspace $LeaseSeconds 'completed'
    if (-not $Override) {
      if (-not (Test-OwnerComplete $requestOwner)) { throw "TASK_STATE_OWNER_REQUIRED taskId=$Id" }
      if (-not $authorityEntity.owner -or -not (Test-OwnerMatch $requestOwner $authorityEntity.owner)) { throw "TASK_STATE_OWNER_MISMATCH taskId=$Id" }
    }
    foreach ($entity in @($activeCheckpointEntity,$activeTaskCardEntity,(Get-EntityValue $projection 'context'))) {
      if (-not $entity) { continue }
      $current = Read-JsonFile ([string]$entity.path)
      if (-not $current -or [string]$current.taskId -ne $Id) { throw "TASK_STATE_COMPLETION_ENTITY_MISSING path=$($entity.path)" }
      if (-not (Test-CompletionWorkspace $current $workspaceKey)) { throw 'TASK_STATE_COMPLETION_ENTITY_WORKSPACE_MISMATCH' }
      if ([string]$entity.hash -and (Get-FileSha256 ([string]$entity.path)) -ne [string]$entity.hash) { throw "TASK_STATE_COMPLETION_ENTITY_CHANGED path=$($entity.path)" }
      if (@($current.pendingSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { throw 'TASK_STATE_COMPLETION_PENDING_STEPS' }
    }
    $authorityContract = if ($contract -and $contract.value) { $contract.value } else { $null }
    if (-not $authorityContract) {
      if (-not $Override) { throw 'TASK_STATE_COMPLETION_CONTRACT_REQUIRED' }
      $authorityBinding = Get-ExistingTaskAuthorityContract $Id $workspaceKey $completedCheckpoint.value
      $authorityContract = if ($authorityBinding) { $authorityBinding.contract } else { New-CompatibilityCompletionAuthorityContract $Id $workspaceKey $manifestValue $completedCheckpoint $completedTaskCard }
      if (-not $authorityContract -or [string]$authorityContract.taskInstanceId -notmatch '^ti-[a-f0-9]{32}$') { throw 'TASK_STATE_COMPATIBILITY_AUTHORITY_INVALID' }
      # The maintenance override is explicit, but the bridged identity still has
      # to be written into every terminal projection and receipt consistently.
      $manifestValue | Add-Member -NotePropertyName ownerSessionKey -NotePropertyValue ([string]$authorityContract.ownerSessionKey) -Force
      $manifestValue | Add-Member -NotePropertyName callerSessionKey -NotePropertyValue ([string]$authorityContract.ownerSessionKey) -Force
      $manifestValue | Add-Member -NotePropertyName expectedTaskInstanceId -NotePropertyValue ([string]$authorityContract.taskInstanceId) -Force
      $manifestValue | Add-Member -NotePropertyName expectedPlanFingerprint -NotePropertyValue ([string]$authorityContract.planReceipt.planFingerprint) -Force
      $manifestValue | Add-Member -NotePropertyName expectedContractRevision -NotePropertyValue ([int]$authorityContract.revision) -Force
      $callerSessionKey = [string]$authorityContract.ownerSessionKey
      $contract = [pscustomobject]@{ path=''; hash=''; value=$authorityContract; compatibilityAuthority=$true }
    }
    $maintenance = if($Override){New-MaintenanceAudit 'CompleteTask' $Reason $Writer}else{$null}
    $nextRevision = $actualRevision + 1
    $transactionId = [guid]::NewGuid().ToString('n')
    $commands = @(Build-TaskCompletionCommands $Id $workspaceKey $transactionId $projection $manifestValue $completedCheckpoint $completedTaskCard $contract $verification $intentCompletion ([string]$manifestRecord.hash) $callerSessionKey $nextRevision)
    if ($commands.Count -eq 0) { throw 'TASK_STATE_COMPLETION_COMMANDS_EMPTY' }
    $checkpointTarget = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\checkpoints\completed') $Id '.json'
    $taskCardTarget = Get-SuperBrainCanonicalTaskPath (Join-Path $SharedRoot 'tasks\completed') $Id '.task.json'
    $completedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $checkpointOwner = New-OwnerRecord $completedCheckpoint.value $OwnerAgentId $OwnerSessionId $OwnerPlatform $OwnerWorkspace $LeaseSeconds 'completed'
    $taskCardOwner = New-OwnerRecord $completedTaskCard.value $OwnerAgentId $OwnerSessionId $OwnerPlatform $OwnerWorkspace $LeaseSeconds 'completed'
    $terminalPlanSealCommand = @($commands | Where-Object { [string]$_.role -eq 'terminal_plan_seal' } | Select-Object -First 1)
    $terminalPlanSealCommand = if ($terminalPlanSealCommand.Count -gt 0) { $terminalPlanSealCommand[0] } else { $null }
    $completionReceiptCommand = @($commands | Where-Object { [string]$_.role -eq 'task_completion_receipt' } | Select-Object -First 1)
    $completionReceiptCommand = if ($completionReceiptCommand.Count -gt 0) { $completionReceiptCommand[0] } else { $null }
    if (-not $completionReceiptCommand -or [string]::IsNullOrWhiteSpace([string]$completionReceiptCommand.payloadHash)) { throw 'TASK_STATE_COMPLETION_RECEIPT_REQUIRED' }
    $entities = [pscustomobject]@{
      context = $null
      checkpoint = New-TaskCompletionEntityRecord $checkpointTarget ([string]$completedCheckpoint.hash) 'completed' $Writer $checkpointOwner
      task_card = New-TaskCompletionEntityRecord $taskCardTarget ([string]$completedTaskCard.hash) 'completed' $Writer $taskCardOwner
    }
    $lifecycle = [pscustomobject]@{
      status = 'completed'
      workspaceKey = $workspaceKey
      ownerSessionKey = [string]$manifestValue.ownerSessionKey
      planFingerprint = [string]$manifestValue.expectedPlanFingerprint
      contractRevision = [int]$manifestValue.expectedContractRevision
      completionTransactionId = $transactionId
      completedAt = $completedAt
      source = Limit-Text $Writer 120
      verificationHash = if($verification){[string]$verification.hash}else{''}
      evidenceBinding = if($verification -and $verification.evidenceBinding){$verification.evidenceBinding | ConvertTo-Json -Depth 6 | ConvertFrom-Json}else{$null}
      manifestHash = [string]$manifestRecord.hash
      terminalPlanSealPath = if($terminalPlanSealCommand){[string]$terminalPlanSealCommand.targetPath}else{''}
      terminalPlanSealHash = if($terminalPlanSealCommand){[string]$terminalPlanSealCommand.payloadHash}else{''}
      completionReceiptPath = [string]$completionReceiptCommand.targetPath
      completionReceiptHash = [string]$completionReceiptCommand.payloadHash
      callerSessionKey = $callerSessionKey
      taskInstanceId = [string]$manifestValue.expectedTaskInstanceId
      decisionBinding = $decisionBinding
      intentCompletion = $intentCompletion
    }
    $authorityRecoveryEvidence = [pscustomobject]@{
      transactionId=$transactionId; manifestPath=[string]$manifestRecord.path; manifestHash=[string]$manifestRecord.hash
      verificationPath=if($verification){[string]$verification.path}else{''}; verificationHash=if($verification){[string]$verification.hash}else{''}; evidenceBinding=if($verification -and $verification.evidenceBinding){$verification.evidenceBinding}else{$null}
      contractPath=if($contract){[string]$contract.path}else{''}; contractHash=if($contract){[string]$contract.hash}else{''}; callerSessionKey=$callerSessionKey; taskInstanceId=[string]$manifestValue.expectedTaskInstanceId
      receiptRequired=$true; completionReceiptPath=[string]$completionReceiptCommand.targetPath; completionReceiptHash=[string]$completionReceiptCommand.payloadHash; decisionBinding=$decisionBinding; intentCompletion=$intentCompletion
    }
    $authority = Apply-TaskAuthorityTransition $Id $authorityContract $projection $entities $lifecycle @($commands) $actualRevision $Writer 'task_completion' ([string]$manifestRecord.hash) $authorityRecoveryEvidence
    if (-not $authority.ok) { throw ('TASK_STATE_SQLITE_AUTHORITY_APPLY_FAILED code=' + [string]$authority.code + ' error=' + (Limit-Text ([string]$authority.error) 240)) }
    $lifecycle | Add-Member -NotePropertyName authorityAggregateId -NotePropertyValue ([string]$authority.aggregateId) -Force
    $lifecycle | Add-Member -NotePropertyName authorityRevision -NotePropertyValue ([int]$authority.revision) -Force
    $lifecycle | Add-Member -NotePropertyName authorityStateHash -NotePropertyValue ([string]$authority.stateHash) -Force
    $lifecycle | Add-Member -NotePropertyName authorityOutboxEventId -NotePropertyValue ([string]$authority.outboxEventId) -Force
    if ($FaultPoint -eq 'after_authority') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY' }
    $prepare = [pscustomobject]@{
      schema='super-brain.task-state-event.v2'; phase='prepared'; transactionKind='task_completion'; transactionId=$transactionId; eventId=[guid]::NewGuid().ToString('n')
      taskId=$Id; revision=0; targetRevision=$nextRevision; previousRevision=$actualRevision; commands=@($commands); entities=$entities; lifecycle=$lifecycle
      completion=[pscustomobject]@{ workspaceKey=$workspaceKey; status='completed'; manifestPath=$manifestRecord.path; manifestHash=$manifestRecord.hash; verificationPath=if($verification){$verification.path}else{''}; verificationHash=if($verification){$verification.hash}else{''}; evidenceBinding=if($verification -and $verification.evidenceBinding){$verification.evidenceBinding}else{$null}; decisionBinding=$decisionBinding; intentCompletion=$intentCompletion; contractPath=if($contract){$contract.path}else{''}; contractHash=if($contract){$contract.hash}else{''}; callerSessionKey=$callerSessionKey; taskInstanceId=[string]$manifestValue.expectedTaskInstanceId; terminalPlanSealPath=if($terminalPlanSealCommand){[string]$terminalPlanSealCommand.targetPath}else{''}; terminalPlanSealHash=if($terminalPlanSealCommand){[string]$terminalPlanSealCommand.payloadHash}else{''}; completionReceiptPath=[string]$completionReceiptCommand.targetPath; completionReceiptHash=[string]$completionReceiptCommand.payloadHash; receiptRequired=$true; authorityAggregateId=[string]$authority.aggregateId; authorityRevision=[int]$authority.revision; authorityStateHash=[string]$authority.stateHash; authorityOutboxEventId=[string]$authority.outboxEventId; maintenance=$maintenance }
      source=Limit-Text $Writer 120; recordedAt=$completedAt
    }
    Add-StateEvent $Id $prepare
    if ($FaultPoint -eq 'after_prepare') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_PREPARE' }
    $materialization = @()
    $durableCommit = $false
    try {
      $materialization = @(Invoke-TaskCompletionMaterialization $commands $Id $workspaceKey $transactionId $FaultAfterMaterialization)
      # Fault injection after materialization deliberately leaves the prepared
      # transaction for the explicit reconciliation path.  A real validation
      # or projection failure below is rolled back while the commit event is
      # still absent.
      if ($FaultPoint -eq 'after_materialize') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZE' }
      if ((Get-FileSha256 ([string]$completionReceiptCommand.targetPath)) -ne [string]$completionReceiptCommand.payloadHash) { throw 'TASK_STATE_COMPLETION_RECEIPT_HASH_MISMATCH' }
      $active = @(Get-TaskCompletionActiveRecords $Id $workspaceKey)
      if ($active.Count -gt 0) { throw "TASK_STATE_COMPLETION_ACTIVE_STATE_REMAINS count=$($active.Count)" }
      $eventId = [guid]::NewGuid().ToString('n')
      $committedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
      $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind='task_completion'; transactionId=$transactionId; authorityOutboxEventId=[string]$authority.outboxEventId; authorityStateHash=[string]$authority.stateHash; eventId=$eventId; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entities=$entities; lifecycle=$lifecycle; source=Limit-Text $Writer 120; recordedAt=$committedAt; materialization=@($materialization) }
      Add-StateEvent $Id $commit
      $durableCommit = $true
      if ($FaultPoint -eq 'after_commit') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_COMMIT' }
      Commit-TaskCompletionProjection $projection $Id $entities $lifecycle $nextRevision $eventId $committedAt
      $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$authority.outboxEventId)
      if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_SQLITE_AUTHORITY_OUTBOX_ACK_FAILED' }
      Remove-TaskCompletionStaging $commands $manifestRecord.path $materialization
      return [pscustomobject]@{ ok=$true; changed=$true; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; lifecycleStatus='completed'; transactionId=$transactionId; commandCount=$commands.Count; activeStateCount=0; authorityAggregateId=[string]$authority.aggregateId; authorityRevision=[int]$authority.revision; authorityStateHash=[string]$authority.stateHash; intentFulfillmentFingerprint=[string]$intentCompletion.fulfillmentFingerprint; terminalPlanSealPath=if($terminalPlanSealCommand){[string]$terminalPlanSealCommand.targetPath}else{''}; terminalPlanSealHash=if($terminalPlanSealCommand){[string]$terminalPlanSealCommand.payloadHash}else{''}; completionReceiptPath=[string]$completionReceiptCommand.targetPath; completionReceiptHash=[string]$completionReceiptCommand.payloadHash; projectionPath=Get-ProjectionPath $Id; eventPath=Get-EventPath $Id; maintenanceOverride=[bool]$Override }
    } catch {
      $originalError = $_.Exception.Message
      $preserveForRecovery = ($FaultPoint -eq 'after_materialize' -or (Test-TaskStateMaterializationFaultInjected $originalError))
      $rollback = if (-not $durableCommit -and -not $preserveForRecovery) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error=if($durableCommit){'durable_commit_present'}else{'fault_injection_preserved'} } }
      if ($rollback.attempted -and -not $rollback.verified) { throw "TASK_STATE_COMPLETION_ROLLBACK_FAILED error=$($rollback.error) original=$originalError" }
      throw
    }
  }
}

function Get-ContinuityManifestRecord([string]$ManifestPath,[string]$Id) {
  if ([string]::IsNullOrWhiteSpace($ManifestPath)) { throw 'TASK_STATE_CONTINUITY_MANIFEST_REQUIRED' }
  $full = [IO.Path]::GetFullPath($ManifestPath)
  if (-not (Test-ChildPath $stagingRoot $full)) { throw "TASK_STATE_CONTINUITY_MANIFEST_OUTSIDE_STAGING path=$full" }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "TASK_STATE_CONTINUITY_MANIFEST_NOT_FOUND path=$full" }
  if ((Get-Item -LiteralPath $full).Length -gt 262144) { throw 'TASK_STATE_CONTINUITY_MANIFEST_TOO_LARGE' }
  $value = Read-JsonFile $full
  if (-not $value -or [string]$value.schema -ne 'super-brain.contract-continuity-manifest.v1') { throw 'TASK_STATE_CONTINUITY_MANIFEST_INVALID' }
  if ([string]$value.taskId -ne $Id) { throw "TASK_STATE_IDENTITY_MISMATCH expected=$Id actual=$($value.taskId)" }
  if ([string]::IsNullOrWhiteSpace([string]$value.workspaceKey)) { throw 'TASK_STATE_CONTINUITY_WORKSPACE_REQUIRED' }
  if ([string]$value.packageVersion -ne [string](Get-SuperBrainManifest $Root).version) { throw 'TASK_STATE_CONTINUITY_MANIFEST_VERSION_MISMATCH' }
  if (-not $value.PSObject.Properties['commands'] -or @($value.commands).Count -eq 0) { throw 'TASK_STATE_CONTINUITY_COMMANDS_REQUIRED' }
  if (-not $value.PSObject.Properties['expectedTaskStateRevision'] -or [int]$value.expectedTaskStateRevision -lt 0) { throw 'TASK_STATE_CONTINUITY_REVISION_REQUIRED' }
  return [pscustomobject]@{ path=$full; hash=Get-FileSha256 $full; value=$value }
}

function Get-ContinuityCommand([object[]]$Commands,[string]$Role,[switch]$Required) {
  $matches = @($Commands | Where-Object { [string]$_.role -eq $Role })
  if ($matches.Count -gt 1) { throw "TASK_STATE_CONTINUITY_COMMAND_DUPLICATE role=$Role" }
  if ($Required -and $matches.Count -ne 1) { throw "TASK_STATE_CONTINUITY_COMMAND_REQUIRED role=$Role" }
  if ($matches.Count -eq 1) { return $matches[0] }
  return $null
}

function Assert-ContractContinuityCommand([object]$Command,[string]$Role,[string]$Operation,[string]$Id,[string]$WorkspaceKey) {
  if (-not $Command) { throw "TASK_STATE_CONTINUITY_COMMAND_REQUIRED role=$Role" }
  if ([string]$Command.operation -ne $Operation) { throw "TASK_STATE_CONTINUITY_OPERATION_INVALID role=$Role operation=$($Command.operation)" }
  $null = Assert-CompletionCommandTarget $Command $Id $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace([string]$Command.payloadPath)) { throw "TASK_STATE_CONTINUITY_PAYLOAD_REQUIRED role=$Role" }
  return Read-Payload ([string]$Command.payloadPath) $Id
}

function Get-ContinuityLifecycle([object]$Projection,[object]$Contract,[string]$WorkspaceKey,[string]$Source) {
  $lifecycle = if ($Projection.lifecycle) { $Projection.lifecycle | ConvertTo-Json -Depth 12 | ConvertFrom-Json } else { [pscustomobject]@{} }
  foreach ($entry in @(@('status','active'),@('workspaceKey',$WorkspaceKey),@('ownerSessionKey',[string]$Contract.ownerSessionKey),@('planFingerprint',[string]$Contract.planReceipt.planFingerprint),@('contractRevision',[int]$Contract.revision),@('completionTransactionId',''),@('completedAt',''),@('evidenceBinding',$null),@('quarantineTransactionId',''),@('quarantinedAt',''),@('quarantineReason',''),@('quarantineManifestPath',''),@('quarantineManifestHash',''),@('source',(Limit-Text $Source 120)))) {
    $lifecycle | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1] -Force
  }
  return $lifecycle
}

function Get-ContractContinuitySessionRebind([object]$Projection,[object]$Contract,[string]$Id,[string]$WorkspaceKey) {
  $previousSessionKey = if ($Projection -and $Projection.lifecycle -and $Projection.lifecycle.PSObject.Properties['ownerSessionKey']) { [string]$Projection.lifecycle.ownerSessionKey } else { '' }
  $nextSessionKey = [string]$Contract.ownerSessionKey
  if ([string]::Equals($previousSessionKey,$nextSessionKey,[StringComparison]::OrdinalIgnoreCase)) { return $null }
  if ([string]::IsNullOrWhiteSpace($previousSessionKey) -or [string]::IsNullOrWhiteSpace($nextSessionKey)) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_OWNER_REQUIRED' }
  $candidates = @()
  foreach ($name in @('intentSessionRebindReceipt','taskSessionRebindReceipt')) {
    if ($Contract.PSObject.Properties[$name] -and $Contract.$name) {
      $candidate = $Contract.$name
      if ($candidate.PSObject.Properties['previousOwnerSessionKey'] -and $candidate.PSObject.Properties['newOwnerSessionKey'] -and [string]::Equals([string]$candidate.previousOwnerSessionKey,$previousSessionKey,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals([string]$candidate.newOwnerSessionKey,$nextSessionKey,[StringComparison]::OrdinalIgnoreCase)) {
        $candidates += $candidate
      }
    }
  }
  if ($candidates.Count -eq 0) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_REQUIRED' }
  # A contract with a required task intent legitimately carries two lineage
  # receipts: one for the intent aggregate and one for the task aggregate.
  # TaskStateStore must consume the task receipt here; treating the pair as an
  # ambiguity incorrectly blocks otherwise valid cross-session continuity.
  $taskCandidates = @($candidates | Where-Object {
    ([string]$_.schema -eq 'super-brain.local-session-rebind-result.v1' -and [string]$_.aggregateKind -eq 'task') -or
    [string]$_.schema -eq 'super-brain.task-session-rebind-receipt.v1'
  })
  if ($taskCandidates.Count -gt 0) { $candidates = $taskCandidates }
  if ($candidates.Count -ne 1) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_AMBIGUOUS' }
  $receipt = $candidates[0]
  $schema = [string]$receipt.schema
  if ($schema -eq 'super-brain.local-session-rebind-result.v1') {
    if (-not $receipt.PSObject.Properties['status'] -or [string]$receipt.status -ne 'finalized') { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_NOT_FINALIZED' }
    if (-not $receipt.PSObject.Properties['aggregateKind'] -or [string]$receipt.aggregateKind -ne 'task') { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_KIND_INVALID' }
    foreach ($name in @('refHash','contractHash','planFingerprint','packageVersion')) {
      if (-not $receipt.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$receipt.$name)) { throw "TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_FIELD_REQUIRED field=$name" }
    }
    if ([string]$receipt.refHash -notmatch '^[a-f0-9]{64}$' -or [string]$receipt.contractHash -notmatch '^[a-f0-9]{64}$') { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_HASH_INVALID' }
    if (-not $receipt.PSObject.Properties['expectedRevision'] -or [int]$receipt.expectedRevision -lt 0) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_TASK_REVISION_INVALID' }
    if (-not $receipt.PSObject.Properties['contractRevision'] -or [int]$receipt.contractRevision -lt 1) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_CONTRACT_REVISION_INVALID' }
    if ($receipt.PSObject.Properties['expectedStateHash'] -and -not [string]::IsNullOrWhiteSpace([string]$receipt.expectedStateHash) -and [string]$receipt.expectedStateHash -notmatch '^[a-f0-9]{64}$') { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_TASK_HASH_INVALID' }
    return [pscustomobject]@{
      schema=$schema; aggregateId=[string]$receipt.aggregateId; rebindId=[string]$receipt.rebindId
      taskId=$Id; taskInstanceId=[string]$Contract.taskInstanceId; workspaceKey=$WorkspaceKey
      previousOwnerSessionKey=$previousSessionKey; newOwnerSessionKey=$nextSessionKey; packageVersion=[string]$receipt.packageVersion
      status=[string]$receipt.status; aggregateKind='task'; expectedRevision=[int]$receipt.expectedRevision; expectedStateHash=([string]$receipt.expectedStateHash).ToLowerInvariant()
      taskRevision=[int]$receipt.expectedRevision; taskStateHash=([string]$receipt.expectedStateHash).ToLowerInvariant(); contractRevision=[int]$receipt.contractRevision; planFingerprint=[string]$receipt.planFingerprint; refHash=[string]$receipt.refHash; contractHash=[string]$receipt.contractHash
    }
  }
  if ($schema -notin @('super-brain.intent-session-rebind-result.v1','super-brain.task-session-rebind-receipt.v1')) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_INVALID' }
  foreach ($entry in @(
    @('taskId',$Id),@('taskInstanceId',[string]$Contract.taskInstanceId),@('workspaceKey',$WorkspaceKey),
    @('previousOwnerSessionKey',$previousSessionKey),@('newOwnerSessionKey',$nextSessionKey)
  )) {
    if (-not $receipt.PSObject.Properties[$entry[0]] -or -not [string]::Equals([string]$receipt.($entry[0]),[string]$entry[1],[StringComparison]::OrdinalIgnoreCase)) {
      throw "TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_MISMATCH field=$($entry[0])"
    }
  }
  foreach ($name in @('aggregateId','rebindId')) {
    if (-not $receipt.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$receipt.$name)) { throw "TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_FIELD_REQUIRED field=$name" }
  }
  if ($schema -eq 'super-brain.intent-session-rebind-result.v1') {
    foreach ($name in @('latestReceiptId','latestReceiptPayloadHash')) {
      if (-not $receipt.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$receipt.$name)) { throw "TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_FIELD_REQUIRED field=$name" }
    }
    if (-not $receipt.PSObject.Properties['intentRevision'] -or [int]$receipt.intentRevision -lt 1) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_INTENT_REVISION_INVALID' }
    return [pscustomobject]@{
      schema=$schema; aggregateId=[string]$receipt.aggregateId; rebindId=[string]$receipt.rebindId
      taskId=$Id; taskInstanceId=[string]$Contract.taskInstanceId; workspaceKey=$WorkspaceKey
      previousOwnerSessionKey=$previousSessionKey; newOwnerSessionKey=$nextSessionKey; intentRevision=[int]$receipt.intentRevision
      latestReceiptId=[string]$receipt.latestReceiptId; latestReceiptPayloadHash=[string]$receipt.latestReceiptPayloadHash
    }
  }
  foreach ($name in @('packageVersion','taskStateHash','planFingerprint')) {
    if (-not $receipt.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$receipt.$name)) { throw "TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_FIELD_REQUIRED field=$name" }
  }
  if (-not $receipt.PSObject.Properties['taskRevision'] -or [int]$receipt.taskRevision -lt 0) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_TASK_REVISION_INVALID' }
  if (-not $receipt.PSObject.Properties['contractRevision'] -or [int]$receipt.contractRevision -lt 1) { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_CONTRACT_REVISION_INVALID' }
  if ([string]$receipt.taskStateHash -notmatch '^[a-f0-9]{64}$') { throw 'TASK_STATE_CONTINUITY_SESSION_REBIND_RECEIPT_TASK_HASH_INVALID' }
  return [pscustomobject]@{
    schema=$schema; aggregateId=[string]$receipt.aggregateId; rebindId=[string]$receipt.rebindId
    taskId=$Id; taskInstanceId=[string]$Contract.taskInstanceId; workspaceKey=$WorkspaceKey
    previousOwnerSessionKey=$previousSessionKey; newOwnerSessionKey=$nextSessionKey; packageVersion=[string]$receipt.packageVersion
    taskRevision=[int]$receipt.taskRevision; taskStateHash=([string]$receipt.taskStateHash).ToLowerInvariant(); contractRevision=[int]$receipt.contractRevision; planFingerprint=[string]$receipt.planFingerprint
  }
}

function Get-ContractContinuityChecklistSignature([object[]]$Values) {
  return (@($Values | ForEach-Object { Limit-Text ([string]$_) 180 }) -join [string][char]31)
}

function Test-ContractContinuityPlanCheckpointRequired([object]$Contract) {
  if (-not $Contract -or -not $Contract.PSObject.Properties['canonicalPlan'] -or -not $Contract.canonicalPlan) { return $false }
  $canonical = Test-SuperBrainCanonicalPlan $Contract.canonicalPlan
  if (-not $canonical.ok) { throw ('TASK_STATE_CONTINUITY_CANONICAL_PLAN_INVALID code=' + [string]$canonical.code) }
  return $true
}

function Assert-ContractContinuityProgressPayload(
  [object]$Payload,
  [object]$Command,
  [string]$Role,
  [object]$Contract,
  [int]$TargetRevision,
  [string]$Id,
  [string]$WorkspaceKey,
  [string]$ContractHash
) {
  $value = $Payload.value
  if (-not (Test-CompletionWorkspace $value $WorkspaceKey)) { throw "TASK_STATE_CONTINUITY_${Role}_WORKSPACE_MISMATCH" }
  if ([string]$value.status -ne 'active') { throw "TASK_STATE_CONTINUITY_${Role}_STATUS_INVALID" }
  $expectedPath = if ($Role -eq 'active_checkpoint') {
    Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\checkpoints\active') $Id '.json'
  } else {
    Get-SuperBrainCanonicalTaskPath (Join-Path (Join-Path $SharedRoot 'tasks') 'active') $Id '.task.json'
  }
  if (-not [string]::Equals([IO.Path]::GetFullPath([string]$Command.targetPath),[IO.Path]::GetFullPath($expectedPath),[StringComparison]::OrdinalIgnoreCase)) {
    throw "TASK_STATE_CONTINUITY_${Role}_TARGET_INVALID"
  }
  foreach ($entry in @(
    [pscustomobject]@{ name='taskStateRevision'; expected=$TargetRevision; code='TASK_STATE_REVISION_MISMATCH' },
    [pscustomobject]@{ name='contractRevision'; expected=[int]$Contract.revision; code='CONTRACT_REVISION_MISMATCH' },
    [pscustomobject]@{ name='planFingerprint'; expected=[string]$Contract.planReceipt.planFingerprint; code='PLAN_FINGERPRINT_MISMATCH' },
    [pscustomobject]@{ name='continuityContractHash'; expected=$ContractHash; code='CONTRACT_HASH_MISMATCH' },
    [pscustomobject]@{ name='taskInstanceId'; expected=[string]$Contract.taskInstanceId; code='TASK_INSTANCE_MISMATCH' },
    [pscustomobject]@{ name='ownerSessionKey'; expected=[string]$Contract.ownerSessionKey; code='OWNER_SESSION_MISMATCH' },
    [pscustomobject]@{ name='currentPhase'; expected=[string]$Contract.currentPhase; code='CURRENT_PHASE_MISMATCH' },
    [pscustomobject]@{ name='currentStep'; expected=[string]$Contract.currentStep; code='CURRENT_STEP_MISMATCH' },
    [pscustomobject]@{ name='nextAction'; expected=[string]$Contract.nextAction; code='NEXT_ACTION_MISMATCH' }
  )) {
    if (-not $value.PSObject.Properties[$entry.name] -or [string]$value.($entry.name) -ne [string]$entry.expected) {
      throw "TASK_STATE_CONTINUITY_${Role}_$($entry.code)"
    }
  }
  if ((Get-ContractContinuityChecklistSignature @($value.completedSteps)) -ne (Get-ContractContinuityChecklistSignature @($Contract.completedSteps))) {
    throw "TASK_STATE_CONTINUITY_${Role}_COMPLETED_CHECKLIST_MISMATCH"
  }
  if ((Get-ContractContinuityChecklistSignature @($value.pendingSteps)) -ne (Get-ContractContinuityChecklistSignature @($Contract.pendingSteps))) {
    throw "TASK_STATE_CONTINUITY_${Role}_PENDING_CHECKLIST_MISMATCH"
  }
  return $value
}

function Get-OrderedContractContinuityCommands([object[]]$Commands) {
  $order = @('execution_contract','current_context','active_checkpoint','active_task_card','workspace_context_pointer','legacy_context_pointer','checkpoint_pointer','route_checkpoint','route_checkpoint_pointer','contract_pointer')
  $ordered = @()
  foreach ($role in $order) {
    $command = Get-ContinuityCommand $Commands $role
    if ($command) { $ordered += $command }
  }
  return @($ordered)
}

function Assert-ContractContinuityManifest([object]$Manifest,[string]$Id,[int]$ActualRevision) {
  $value = $Manifest.value
  $workspaceKey = Get-SuperBrainWorkspaceKey ([string]$value.workspaceKey)
  if ([string]::IsNullOrWhiteSpace($workspaceKey)) { throw 'TASK_STATE_CONTINUITY_WORKSPACE_REQUIRED' }
  if ([int]$value.expectedTaskStateRevision -ne $ActualRevision) { throw "TASK_STATE_CAS_MISMATCH expected=$($value.expectedTaskStateRevision) actual=$ActualRevision taskId=$Id" }
  $commands = @($value.commands)
  $allowedRoles = @('current_context','active_checkpoint','active_task_card','workspace_context_pointer','legacy_context_pointer','checkpoint_pointer','route_checkpoint','route_checkpoint_pointer','execution_contract','contract_pointer')
  foreach ($command in $commands) {
    if ([string]$command.role -notin $allowedRoles) { throw "TASK_STATE_CONTINUITY_ROLE_INVALID role=$($command.role)" }
  }
  $contractCommand = Get-ContinuityCommand $commands 'execution_contract' -Required
  $contractPayload = Assert-ContractContinuityCommand $contractCommand 'execution_contract' 'replace_if_hash' $Id $workspaceKey
  $contract = $contractPayload.value
  if ([string]$contract.schema -ne 'super-brain.execution-contract.v1' -or [string]$contract.status -ne 'active') { throw 'TASK_STATE_CONTINUITY_CONTRACT_INVALID' }
  if (-not (Test-CompletionWorkspace $contract $workspaceKey)) { throw 'TASK_STATE_CONTINUITY_CONTRACT_WORKSPACE_MISMATCH' }
  if ([string]$contract.packageVersion -ne [string](Get-SuperBrainManifest $Root).version) { throw 'TASK_STATE_CONTINUITY_CONTRACT_VERSION_MISMATCH' }
  if (-not $contract.PSObject.Properties['planReceipt'] -or [string]::IsNullOrWhiteSpace([string]$contract.planReceipt.planFingerprint)) { throw 'TASK_STATE_CONTINUITY_PLAN_FINGERPRINT_REQUIRED' }
  if (-not $value.PSObject.Properties['contractRevision'] -or [int]$value.contractRevision -ne [int]$contract.revision) { throw 'TASK_STATE_CONTINUITY_CONTRACT_REVISION_MISMATCH' }
  if (-not $value.PSObject.Properties['planFingerprint'] -or [string]$value.planFingerprint -ne [string]$contract.planReceipt.planFingerprint) { throw 'TASK_STATE_CONTINUITY_PLAN_FINGERPRINT_MISMATCH' }
  if ($value.PSObject.Properties['taskInstanceId'] -and [string]$value.taskInstanceId -ne [string]$contract.taskInstanceId) { throw 'TASK_STATE_CONTINUITY_TASK_INSTANCE_MISMATCH' }
  $planCheckpointRequired = Test-ContractContinuityPlanCheckpointRequired $contract
  if ($value.PSObject.Properties['planCheckpointRequired'] -and [bool]$value.planCheckpointRequired -ne [bool]$planCheckpointRequired) { throw 'TASK_STATE_CONTINUITY_CHECKPOINT_REQUIREMENT_MISMATCH' }
  $checkpointProjectionIncluded = if ($value.PSObject.Properties['checkpointProjectionIncluded']) { [bool]$value.checkpointProjectionIncluded } else { [bool]$planCheckpointRequired }
  if ($planCheckpointRequired -and -not $checkpointProjectionIncluded) { throw 'TASK_STATE_CONTINUITY_REQUIRED_CHECKPOINT_OMITTED' }

  $contextCommand = Get-ContinuityCommand $commands 'current_context' -Required
  $contextPayload = Assert-ContractContinuityCommand $contextCommand 'current_context' 'replace_if_hash' $Id $workspaceKey
  $context = $contextPayload.value
  $bootstrapContext = ($value.PSObject.Properties['bootstrapContext'] -and [bool]$value.bootstrapContext)
  if ($bootstrapContext -and -not [bool]$contextCommand.applyWhenMissing) { throw 'TASK_STATE_CONTINUITY_BOOTSTRAP_CONTEXT_CREATE_REQUIRED' }
  if (-not $bootstrapContext -and [bool]$contextCommand.applyWhenMissing) { throw 'TASK_STATE_CONTINUITY_CONTEXT_REPLACE_REQUIRED' }
  if ([string]$context.status -ne 'active' -or [string]$context.bindingState -ne 'bound' -or [string]$context.authorizationState -ne 'authorizing') { throw 'TASK_STATE_CONTINUITY_CONTEXT_NOT_AUTHORIZING' }
  if (-not (Test-CompletionWorkspace $context $workspaceKey)) { throw 'TASK_STATE_CONTINUITY_CONTEXT_WORKSPACE_MISMATCH' }
  if ([int]$context.taskStateRevision -ne ($ActualRevision + 1)) { throw 'TASK_STATE_CONTINUITY_CONTEXT_TASK_STATE_REVISION_MISMATCH' }
  if ([int]$context.contractRevision -ne [int]$contract.revision -or [string]$context.planFingerprint -ne [string]$contract.planReceipt.planFingerprint) { throw 'TASK_STATE_CONTINUITY_CONTEXT_CONTRACT_MISMATCH' }
  if ([string]$context.ownerSessionKey -ne [string]$contract.ownerSessionKey) { throw 'TASK_STATE_CONTINUITY_CONTEXT_SESSION_MISMATCH' }
  if ([string]$context.targetHash -ne [string]$contractPayload.hash) { throw 'TASK_STATE_CONTINUITY_CONTEXT_TARGET_HASH_MISMATCH' }
  if ([string]$context.contractFileName -ne (Split-Path -Leaf ([string]$contractCommand.targetPath))) { throw 'TASK_STATE_CONTINUITY_CONTEXT_CONTRACT_PATH_MISMATCH' }

  foreach ($role in @('workspace_context_pointer','legacy_context_pointer')) {
    $pointer = Get-ContinuityCommand $commands $role -Required
    $payload = Assert-ContractContinuityCommand $pointer $role 'conditional_pointer' $Id $workspaceKey
    if ([string]$payload.hash -ne [string]$contextPayload.hash) { throw "TASK_STATE_CONTINUITY_POINTER_PAYLOAD_MISMATCH role=$role" }
  }
  $contractPointer = Get-ContinuityCommand $commands 'contract_pointer' -Required
  $contractPointerPayload = Assert-ContractContinuityCommand $contractPointer 'contract_pointer' 'conditional_pointer' $Id $workspaceKey
  if ([string]$contractPointerPayload.hash -ne [string]$contractPayload.hash) { throw 'TASK_STATE_CONTINUITY_POINTER_PAYLOAD_MISMATCH role=contract_pointer' }

  $targetRevision = $ActualRevision + 1
  $checkpointCommand = Get-ContinuityCommand $commands 'active_checkpoint' -Required:$checkpointProjectionIncluded
  $checkpointPayload = $null
  $checkpoint = $null
  if ($checkpointProjectionIncluded) {
    $checkpointPayload = Assert-ContractContinuityCommand $checkpointCommand 'active_checkpoint' 'replace_if_hash' $Id $workspaceKey
    $checkpoint = Assert-ContractContinuityProgressPayload $checkpointPayload $checkpointCommand 'active_checkpoint' $contract $targetRevision $Id $workspaceKey ([string]$contractPayload.hash)
  } elseif ($checkpointCommand -or (Get-ContinuityCommand $commands 'checkpoint_pointer')) {
    throw 'TASK_STATE_CONTINUITY_CHECKPOINT_FORBIDDEN_FOR_NONCANONICAL_PLAN'
  }
  $taskCardCommand = Get-ContinuityCommand $commands 'active_task_card' -Required
  $taskCardPayload = Assert-ContractContinuityCommand $taskCardCommand 'active_task_card' 'replace_if_hash' $Id $workspaceKey
  $taskCard = Assert-ContractContinuityProgressPayload $taskCardPayload $taskCardCommand 'active_task_card' $contract $targetRevision $Id $workspaceKey ([string]$contractPayload.hash)
  if ($checkpointProjectionIncluded) {
    $checkpointPointer = Get-ContinuityCommand $commands 'checkpoint_pointer' -Required
    $checkpointPointerPayload = Assert-ContractContinuityCommand $checkpointPointer 'checkpoint_pointer' 'conditional_pointer' $Id $workspaceKey
    if ([string]$checkpointPointerPayload.hash -ne [string]$checkpointPayload.hash) { throw 'TASK_STATE_CONTINUITY_POINTER_PAYLOAD_MISMATCH role=checkpoint_pointer' }
  }

  $routeCommand = Get-ContinuityCommand $commands 'route_checkpoint'
  if ($routeCommand) {
    $routePayload = Assert-ContractContinuityCommand $routeCommand 'route_checkpoint' 'replace_if_hash' $Id $workspaceKey
    $route = $routePayload.value
    if (-not (Test-CompletionWorkspace $route $workspaceKey)) { throw 'TASK_STATE_CONTINUITY_ROUTE_WORKSPACE_MISMATCH' }
    if ([string]$route.bindingState -ne 'bound' -or [int]$route.taskStateRevision -ne ($ActualRevision + 1) -or [int]$route.contractRevision -ne [int]$contract.revision -or [string]$route.planFingerprint -ne [string]$contract.planReceipt.planFingerprint -or [string]$route.targetHash -ne [string]$contractPayload.hash) { throw 'TASK_STATE_CONTINUITY_ROUTE_BINDING_MISMATCH' }
    $routePointer = Get-ContinuityCommand $commands 'route_checkpoint_pointer' -Required
    $routePointerPayload = Assert-ContractContinuityCommand $routePointer 'route_checkpoint_pointer' 'conditional_pointer' $Id $workspaceKey
    if ([string]$routePointerPayload.hash -ne [string]$routePayload.hash) { throw 'TASK_STATE_CONTINUITY_POINTER_PAYLOAD_MISMATCH role=route_checkpoint_pointer' }
  } elseif (Get-ContinuityCommand $commands 'route_checkpoint_pointer') {
    throw 'TASK_STATE_CONTINUITY_ROUTE_POINTER_WITHOUT_ROUTE'
  }
  $ordered = Get-OrderedContractContinuityCommands $commands
  if ($ordered.Count -ne $commands.Count) { throw 'TASK_STATE_CONTINUITY_COMMAND_ORDER_INCOMPLETE' }
  return [pscustomobject]@{ workspaceKey=$workspaceKey; bootstrapContext=$bootstrapContext; planCheckpointRequired=[bool]$planCheckpointRequired; checkpointProjectionIncluded=[bool]$checkpointProjectionIncluded; commands=@($ordered); contractCommand=$contractCommand; contractPayload=$contractPayload; contract=$contract; contextCommand=$contextCommand; contextPayload=$contextPayload; context=$context; checkpointCommand=$checkpointCommand; checkpointPayload=$checkpointPayload; checkpoint=$checkpoint; taskCardCommand=$taskCardCommand; taskCardPayload=$taskCardPayload; taskCard=$taskCard; routeCommand=$routeCommand }
}

function Commit-ContractContinuity([string]$Id,[string]$ManifestPath,[string]$Writer) {
  if ([string]::IsNullOrWhiteSpace($Id)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $manifest = Get-ContinuityManifestRecord $ManifestPath $Id
  return Invoke-SuperBrainFileLock $mutationGate {
    Assert-NoIncompleteTaskTransaction $Id
    $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $Id)) $Id
    if ([string]$projection.lifecycle.status -in @('completed','cancelled','archived','quarantined')) { throw "TASK_STATE_LIFECYCLE_TERMINAL taskId=$Id status=$($projection.lifecycle.status)" }
    $actualRevision = [int]$projection.revision
    $validated = Assert-ContractContinuityManifest $manifest $Id $actualRevision
    $bootstrapContext = [bool]$validated.bootstrapContext
    $previousContext = Get-EntityValue $projection 'context'
    if ($bootstrapContext -and $previousContext) { throw 'TASK_STATE_CONTINUITY_BOOTSTRAP_CONTEXT_ALREADY_EXISTS' }
    if (-not $bootstrapContext -and -not $previousContext) { throw 'TASK_STATE_CONTINUITY_CONTEXT_ENTITY_REQUIRED' }
    $previousContextValue = if ($previousContext) { (Read-Entity ([string]$previousContext.path) $Id).value } else { $null }
    $previousContract = $null
    $contractRoot = Join-Path $WorkspaceRoot 'runtime-state\execution-contracts'
    $candidatePreviousContractPath = ''
    if ($previousContextValue -and $previousContextValue.PSObject.Properties['contractPath'] -and -not [string]::IsNullOrWhiteSpace([string]$previousContextValue.contractPath)) {
      $candidatePreviousContractPath = [string]$previousContextValue.contractPath
    } elseif ($previousContextValue -and $previousContextValue.PSObject.Properties['contractFileName'] -and -not [string]::IsNullOrWhiteSpace([string]$previousContextValue.contractFileName)) {
      $contractFileName = [string]$previousContextValue.contractFileName
      if ([string]::Equals($contractFileName,(Split-Path -Leaf $contractFileName),[StringComparison]::OrdinalIgnoreCase)) { $candidatePreviousContractPath = Join-Path $contractRoot $contractFileName }
    }
    if (-not [string]::IsNullOrWhiteSpace($candidatePreviousContractPath)) {
      if (Test-SuperBrainPhaseCloseoutChildPath $contractRoot $candidatePreviousContractPath) { $previousContract = Read-JsonFile $candidatePreviousContractPath }
    }
    if (-not $bootstrapContext -and -not $previousContract) { throw 'TASK_STATE_CONTINUITY_PREVIOUS_CONTRACT_REQUIRED' }
    if (-not $bootstrapContext) {
      $phaseCloseout = Assert-SuperBrainPhaseCloseoutTransition $previousContract $validated.contract $WorkspaceRoot ([string](Get-SuperBrainManifest $Root).version)
      if (-not $phaseCloseout.ok) { throw ('TASK_STATE_' + [string]$phaseCloseout.code) }
    }
    $previousCheckpoint = Get-EntityValue $projection 'checkpoint'
    $previousTaskCard = Get-EntityValue $projection 'task_card'
    $planCheckpointRequired = [bool]$validated.planCheckpointRequired
    $checkpointProjectionIncluded = [bool]$validated.checkpointProjectionIncluded
    if ($checkpointProjectionIncluded -and -not $previousCheckpoint) { throw 'TASK_STATE_CONTINUITY_CHECKPOINT_ENTITY_REQUIRED' }
    if (-not $previousTaskCard) { throw 'TASK_STATE_CONTINUITY_TASK_CARD_ENTITY_REQUIRED' }
    $owner = New-OwnerRecord $validated.context '' '' '' '' $LeaseSeconds 'active'
    if (-not (Test-OwnerComplete $owner)) { throw 'TASK_STATE_CONTINUITY_CONTEXT_OWNER_REQUIRED' }
    $checkpointOwner = if($checkpointProjectionIncluded){New-OwnerRecord $validated.checkpoint '' '' '' '' $LeaseSeconds 'active'}else{$null}
    $taskCardOwner = New-OwnerRecord $validated.taskCard '' '' '' '' $LeaseSeconds 'active'
    $taskSessionRebind = if ($bootstrapContext) { $null } else { Get-ContractContinuitySessionRebind $projection $validated.contract $Id $validated.workspaceKey }
    if ($bootstrapContext) {
      if (-not $previousTaskCard.owner -or -not (Test-OwnerMatch $owner $previousTaskCard.owner)) { throw 'TASK_STATE_CONTINUITY_BOOTSTRAP_OWNER_MISMATCH' }
      if ($checkpointProjectionIncluded -and (-not $previousCheckpoint.owner -or -not (Test-OwnerMatch $owner $previousCheckpoint.owner))) { throw 'TASK_STATE_CONTINUITY_BOOTSTRAP_OWNER_MISMATCH' }
    } elseif ($taskSessionRebind) {
      $previousSessionKey = [string]$taskSessionRebind.previousOwnerSessionKey
      if (-not $previousContext.owner -or -not (Test-OwnerSessionRebind $previousContext.owner $owner $previousSessionKey ([string]$taskSessionRebind.newOwnerSessionKey))) { throw 'TASK_STATE_CONTINUITY_CONTEXT_SESSION_REBIND_OWNER_MISMATCH' }
      if ($checkpointProjectionIncluded -and (-not $previousCheckpoint.owner -or -not (Test-OwnerSessionRebind $previousCheckpoint.owner $checkpointOwner $previousSessionKey ([string]$taskSessionRebind.newOwnerSessionKey)))) { throw 'TASK_STATE_CONTINUITY_CHECKPOINT_SESSION_REBIND_OWNER_MISMATCH' }
      if (-not $previousTaskCard.owner -or -not (Test-OwnerSessionRebind $previousTaskCard.owner $taskCardOwner $previousSessionKey ([string]$taskSessionRebind.newOwnerSessionKey))) { throw 'TASK_STATE_CONTINUITY_TASK_CARD_SESSION_REBIND_OWNER_MISMATCH' }
    } else {
      if (-not $previousContext.owner -or -not (Test-OwnerMatch $owner $previousContext.owner)) { throw 'TASK_STATE_CONTINUITY_CONTEXT_OWNER_MISMATCH' }
      if ($checkpointProjectionIncluded -and (-not (Test-OwnerComplete $checkpointOwner) -or -not $previousCheckpoint.owner -or -not (Test-OwnerMatch $checkpointOwner $previousCheckpoint.owner))) { throw 'TASK_STATE_CONTINUITY_CHECKPOINT_OWNER_MISMATCH' }
      if (-not (Test-OwnerComplete $taskCardOwner) -or -not $previousTaskCard.owner -or -not (Test-OwnerMatch $taskCardOwner $previousTaskCard.owner)) { throw 'TASK_STATE_CONTINUITY_TASK_CARD_OWNER_MISMATCH' }
    }
    $nextRevision = $actualRevision + 1
    $transactionId = [guid]::NewGuid().ToString('n')
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $entities = [pscustomobject]@{
      context = New-TaskCompletionEntityRecord ([string]$validated.contextCommand.targetPath) ([string]$validated.contextPayload.hash) 'active' $Writer $owner
      checkpoint = if($checkpointProjectionIncluded){New-TaskCompletionEntityRecord ([string]$validated.checkpointCommand.targetPath) ([string]$validated.checkpointPayload.hash) 'active' $Writer $checkpointOwner}else{$previousCheckpoint}
      task_card = New-TaskCompletionEntityRecord ([string]$validated.taskCardCommand.targetPath) ([string]$validated.taskCardPayload.hash) 'active' $Writer $taskCardOwner
    }
    $lifecycle = Get-ContinuityLifecycle $projection $validated.contract $validated.workspaceKey $Writer
    $continuity = [pscustomobject]@{
      manifestPath=$manifest.path; manifestHash=$manifest.hash; workspaceKey=$validated.workspaceKey; contractPath=[string]$validated.contractCommand.targetPath; contractHash=[string]$validated.contractPayload.hash
      contractRevision=[int]$validated.contract.revision; planFingerprint=[string]$validated.contract.planReceipt.planFingerprint; taskInstanceId=[string]$validated.contract.taskInstanceId
      bootstrapContext=$bootstrapContext; planCheckpointRequired=$planCheckpointRequired; checkpointProjectionIncluded=$checkpointProjectionIncluded; contextPath=[string]$validated.contextCommand.targetPath; contextHash=[string]$validated.contextPayload.hash; checkpointPath=if($checkpointProjectionIncluded){[string]$validated.checkpointCommand.targetPath}else{''}; checkpointHash=if($checkpointProjectionIncluded){[string]$validated.checkpointPayload.hash}else{''}; taskCardPath=[string]$validated.taskCardCommand.targetPath; taskCardHash=[string]$validated.taskCardPayload.hash; routePath=if($validated.routeCommand){[string]$validated.routeCommand.targetPath}else{''}; routeHash=if($validated.routeCommand){[string](Get-ContinuityCommand @($validated.commands) 'route_checkpoint').payloadHash}else{''}
    }
    if ($taskSessionRebind) { $continuity | Add-Member -NotePropertyName taskSessionRebind -NotePropertyValue $taskSessionRebind -Force }
    # The prepared WAL is the durable hand-off boundary.  Do not touch SQLite
    # task authority until every H7 contract/context/checkpoint/task-card/route
    # projection has been materialized and hash-verified below.  This keeps a
    # projection failure from silently transferring the task owner early.
    $continuity | Add-Member -NotePropertyName authorityState -NotePropertyValue 'pending' -Force
    $prepare = [pscustomobject]@{
      schema='super-brain.task-state-event.v2'; phase='prepared'; transactionKind='contract_continuity'; transactionId=$transactionId; eventId=[guid]::NewGuid().ToString('n')
      taskId=$Id; revision=0; targetRevision=$nextRevision; previousRevision=$actualRevision; commands=@($validated.commands); entities=$entities; lifecycle=$lifecycle; continuity=$continuity
      source=Limit-Text $Writer 120; recordedAt=$now
    }
    Add-StateEvent $Id $prepare
    if ($FaultPoint -eq 'after_prepare') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_PREPARE' }
    $materialization = @()
    $durableCommit = $false
    try {
      $materialization = @(Invoke-TaskCompletionMaterialization @($validated.commands) $Id $validated.workspaceKey $transactionId $FaultAfterMaterialization)
      # Keep an injected post-materialization interruption replayable from the
      # prepared WAL. Ordinary validation/projection failures are rolled back
      # before the committed event becomes durable.
      if ($FaultPoint -eq 'after_materialize') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZE' }
    foreach ($record in @(@($continuity.contractPath,$continuity.contractHash),@($continuity.contextPath,$continuity.contextHash),@($continuity.checkpointPath,$continuity.checkpointHash),@($continuity.taskCardPath,$continuity.taskCardHash),@($continuity.routePath,$continuity.routeHash))) {
      if (-not [string]::IsNullOrWhiteSpace([string]$record[0]) -and (Get-FileSha256 ([string]$record[0])) -ne [string]$record[1]) { throw "TASK_STATE_CONTINUITY_MATERIALIZATION_HASH_MISMATCH path=$($record[0])" }
    }
    $authority = Apply-TaskAuthorityTransition $Id $validated.contract $projection $entities $lifecycle @($validated.commands) $actualRevision $Writer 'contract_continuity' ([string]$manifest.hash) $null $taskSessionRebind
    if (-not $authority.ok) {
      # Authority is the owner/session source of truth. If it rejects the CAS
      # after file materialization, the enclosing transaction catch restores
      # every replaced target exactly once before surfacing the failure; the
      # prepared event remains available for explicit reconcile/replay.
      throw ('TASK_STATE_SQLITE_AUTHORITY_APPLY_FAILED code=' + [string]$authority.code + ' error=' + (Limit-Text ([string]$authority.error) 240))
    }
    $continuity | Add-Member -NotePropertyName authorityState -NotePropertyValue 'applied' -Force
    $continuity | Add-Member -NotePropertyName authorityAggregateId -NotePropertyValue ([string]$authority.aggregateId) -Force
    $continuity | Add-Member -NotePropertyName authorityRevision -NotePropertyValue ([int]$authority.revision) -Force
    $continuity | Add-Member -NotePropertyName authorityStateHash -NotePropertyValue ([string]$authority.stateHash) -Force
    $continuity | Add-Member -NotePropertyName authorityOutboxEventId -NotePropertyValue ([string]$authority.outboxEventId) -Force
    if ($FaultPoint -eq 'after_authority') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY' }
    $eventId = [guid]::NewGuid().ToString('n')
    $committedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind='contract_continuity'; transactionId=$transactionId; eventId=$eventId; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entities=$entities; lifecycle=$lifecycle; continuity=$continuity; source=Limit-Text $Writer 120; recordedAt=$committedAt; materialization=@($materialization) }
    Add-StateEvent $Id $commit
    if ($FaultPoint -eq 'after_commit') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_COMMIT' }
    Commit-TaskCompletionProjection $projection $Id $entities $lifecycle $nextRevision $eventId $committedAt
    $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$authority.outboxEventId)
    if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_SQLITE_AUTHORITY_OUTBOX_ACK_FAILED' }
    Remove-TaskCompletionStaging @($validated.commands) $manifest.path $materialization
    return [pscustomobject]@{ ok=$true; changed=$true; taskId=$Id; transactionId=$transactionId; revision=$nextRevision; previousRevision=$actualRevision; bootstrapContext=$bootstrapContext; planCheckpointRequired=$planCheckpointRequired; checkpointProjectionIncluded=$checkpointProjectionIncluded; contractRevision=[int]$validated.contract.revision; planFingerprint=[string]$validated.contract.planReceipt.planFingerprint; authorityAggregateId=[string]$authority.aggregateId; authorityRevision=[int]$authority.revision; authorityStateHash=[string]$authority.stateHash; contextPath=[string]$continuity.contextPath; checkpointPath=[string]$continuity.checkpointPath; taskCardPath=[string]$continuity.taskCardPath; routePath=[string]$continuity.routePath; projectionPath=Get-ProjectionPath $Id; eventPath=Get-EventPath $Id; guard=if($checkpointProjectionIncluded){'SQLite task authority committed contract, bound context, active checkpoint, active task card, routes, and compatibility pointers through one recoverable transaction.'}else{'SQLite task authority committed contract, bound context, active task card, routes, and compatibility pointers through one recoverable transaction; no active checkpoint was present.'} }
    } catch {
      $originalError = $_.Exception.Message
      $preserveForRecovery = ($FaultPoint -eq 'after_materialize' -or (Test-TaskStateMaterializationFaultInjected $originalError))
      $rollback = if (-not $durableCommit -and -not $preserveForRecovery) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error=if($durableCommit){'durable_commit_present'}else{'fault_injection_preserved'} } }
      if ($rollback.attempted -and -not $rollback.verified) { throw "TASK_STATE_CONTINUITY_ROLLBACK_FAILED error=$($rollback.error) original=$originalError" }
      throw
    }
  }
}

function Complete-PreparedContractContinuity([object]$Prepare) {
  $id = [string]$Prepare.taskId
  $workspaceKey = [string]$Prepare.continuity.workspaceKey
  $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
  $actualRevision = [int]$projection.revision
  if ($actualRevision -ne [int]$Prepare.previousRevision -or [int]$Prepare.targetRevision -ne ($actualRevision + 1)) { return [pscustomobject]@{ ok=$false; reason='revision_advanced'; taskId=$id; transactionId=$Prepare.transactionId } }
  $materialization = @()
  $authorityCommitted = $false
  $durableCommit = $false
  try {
    # Re-validate the staged manifest before replay.  A prepared continuity
    # record may have survived a process crash before SQLite authority was
    # applied, so the recovery path must reconstruct the exact contract and
    # hashes instead of assuming an authority outbox id was already written.
    $manifestRecord = Get-ContinuityManifestRecord ([string]$Prepare.continuity.manifestPath) $id
    $validated = Assert-ContractContinuityManifest $manifestRecord $id ([int]$Prepare.previousRevision)
    $materialization = @(Invoke-TaskCompletionMaterialization @($Prepare.commands) $id $workspaceKey ([string]$Prepare.transactionId) 0)
    foreach ($record in @(@([string]$Prepare.continuity.contractPath,[string]$Prepare.continuity.contractHash),@([string]$Prepare.continuity.contextPath,[string]$Prepare.continuity.contextHash),@([string]$Prepare.continuity.checkpointPath,[string]$Prepare.continuity.checkpointHash),@([string]$Prepare.continuity.taskCardPath,[string]$Prepare.continuity.taskCardHash),@([string]$Prepare.continuity.routePath,[string]$Prepare.continuity.routeHash))) {
      if (-not [string]::IsNullOrWhiteSpace([string]$record[0]) -and (Get-FileSha256 ([string]$record[0])) -ne [string]$record[1]) { throw "TASK_STATE_CONTINUITY_MATERIALIZATION_HASH_MISMATCH path=$($record[0])" }
    }
    $taskSessionRebind = if ($Prepare.continuity.PSObject.Properties['taskSessionRebind']) { $Prepare.continuity.taskSessionRebind } else { $null }
    $targetRevision = [int]$Prepare.targetRevision
    $authority = $null
    $pendingAuthority = @(
      Get-PendingTaskAuthorityOutbox | Where-Object {
        [string]$_.payload.taskId -eq $id -and
        [int]$_.revision -eq $targetRevision -and
        [string]$_.payload.schema -eq 'super-brain.task-projection-outbox.v1' -and
        [string]$_.payload.projection.transactionKind -eq 'contract_continuity'
      }
    )
    if ($pendingAuthority.Count -gt 1) { throw 'TASK_STATE_AUTHORITY_OUTBOX_AMBIGUOUS' }
    if ($pendingAuthority.Count -eq 1) {
      $candidate = $pendingAuthority[0]
      if ($Prepare.continuity.PSObject.Properties['authorityStateHash'] -and -not [string]::IsNullOrWhiteSpace([string]$Prepare.continuity.authorityStateHash) -and [string]$candidate.payload.stateHash -ne [string]$Prepare.continuity.authorityStateHash) { throw 'TASK_STATE_AUTHORITY_OUTBOX_STATE_MISMATCH' }
      $authorityCommitted = $true
      $authority = [pscustomobject]@{
        ok=$true; aggregateId=[string]$candidate.aggregateId; revision=[int]$candidate.revision;
        stateHash=[string]$candidate.payload.stateHash; outboxEventId=[string]$candidate.eventId; idempotent=$true
      }
    } else {
      # Inspect the current authority revision without mutating it.  If the
      # process died after Apply-TaskAuthorityTransition committed, reuse that
      # state and its durable outbox/snapshot rather than issuing a second CAS.
      $authorityScope = [ordered]@{
        taskId=$id; taskInstanceId=[string]$validated.contract.taskInstanceId; workspaceKey=$workspaceKey
        ownerSessionKey=[string]$validated.contract.ownerSessionKey; packageVersion=[string]$validated.contract.packageVersion
      }
      if ($taskSessionRebind) { $authorityScope.taskSessionRebind = $taskSessionRebind }
      $authorityRead = Invoke-TaskAuthorityControl 'prepare-task' $authorityScope
      if (-not $authorityRead.ok) { throw ('TASK_STATE_AUTHORITY_READ_FAILED code=' + [string]$authorityRead.code) }
      if ([int]$authorityRead.expectedRevision -eq $targetRevision) {
        if (-not $authorityRead.state -or [int]$authorityRead.state.taskStateRevision -ne $targetRevision -or [string]$authorityRead.state.ownerSessionKey -ne [string]$validated.contract.ownerSessionKey) {
          throw 'TASK_STATE_AUTHORITY_STATE_MISMATCH'
        }
        $snapshots = @(Get-TaskAuthorityProjectionSnapshots | Where-Object { [string]$_.payload.taskId -eq $id -and [int]$_.revision -eq $targetRevision -and [string]$_.payload.schema -eq 'super-brain.task-projection-outbox.v1' })
        if ($snapshots.Count -ne 1) { throw 'TASK_STATE_AUTHORITY_SNAPSHOT_MISSING' }
        $authorityCommitted = $true
        $authority = [pscustomobject]@{
          ok=$true; aggregateId=[string]$snapshots[0].aggregateId; revision=[int]$snapshots[0].revision;
          stateHash=[string]$snapshots[0].payload.stateHash; outboxEventId=[string]$snapshots[0].eventId; idempotent=$true
        }
      } elseif (
        [int]$authorityRead.expectedRevision -eq 0 -and
        [int]$Prepare.previousRevision -gt 0 -and
        $null -eq $authorityRead.state
      ) {
        # A first bound-context transaction can legitimately prepare its file
        # projection before SQLite has ever seen this task.  The projection
        # revision is still the scoped source of truth for the bootstrap: it
        # was validated from the prepared manifest, task instance, workspace,
        # owner session, package version, and exact file hashes above.  Import
        # that one prior revision, then apply the prepared transition through
        # the normal CAS path.  Never import when an authority state exists or
        # when the observed revision is anything other than the empty store;
        # those cases remain conflicts and fail closed.
        $seed = Ensure-TaskAuthorityAggregate $id $validated.contract $projection ([int]$Prepare.previousRevision) ([string]$Prepare.source) $taskSessionRebind
        if (-not $seed.ok) {
          throw ('TASK_STATE_AUTHORITY_BOOTSTRAP_FAILED code=' + [string]$seed.code + ' error=' + (Limit-Text ([string]$seed.error) 240))
        }
        $authority = Apply-TaskAuthorityTransition $id $validated.contract $projection $Prepare.entities $Prepare.lifecycle @($validated.commands) ([int]$Prepare.previousRevision) ([string]$Prepare.source) 'contract_continuity' ([string]$manifestRecord.hash) $null $taskSessionRebind
        if (-not $authority.ok) { throw ('TASK_STATE_AUTHORITY_APPLY_FAILED code=' + [string]$authority.code + ' error=' + [string]$authority.error) }
        $authorityCommitted = $true
      } elseif ([int]$authorityRead.expectedRevision -eq [int]$Prepare.previousRevision) {
        $authority = Apply-TaskAuthorityTransition $id $validated.contract $projection $Prepare.entities $Prepare.lifecycle @($validated.commands) ([int]$Prepare.previousRevision) ([string]$Prepare.source) 'contract_continuity' ([string]$manifestRecord.hash) $null $taskSessionRebind
        if (-not $authority.ok) { throw ('TASK_STATE_AUTHORITY_APPLY_FAILED code=' + [string]$authority.code + ' error=' + [string]$authority.error) }
        $authorityCommitted = $true
      } else {
        throw "TASK_STATE_AUTHORITY_REVISION_CONFLICT expected=$($Prepare.previousRevision) actual=$($authorityRead.expectedRevision)"
      }
    }
    $continuity = $Prepare.continuity
    $continuity | Add-Member -NotePropertyName authorityState -NotePropertyValue 'applied' -Force
    $continuity | Add-Member -NotePropertyName authorityAggregateId -NotePropertyValue ([string]$authority.aggregateId) -Force
    $continuity | Add-Member -NotePropertyName authorityRevision -NotePropertyValue ([int]$authority.revision) -Force
    $continuity | Add-Member -NotePropertyName authorityStateHash -NotePropertyValue ([string]$authority.stateHash) -Force
    $continuity | Add-Member -NotePropertyName authorityOutboxEventId -NotePropertyValue ([string]$authority.outboxEventId) -Force
    $eventId = [guid]::NewGuid().ToString('n')
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind='contract_continuity'; transactionId=[string]$Prepare.transactionId; eventId=$eventId; taskId=$id; revision=$actualRevision+1; previousRevision=$actualRevision; entities=$Prepare.entities; lifecycle=$Prepare.lifecycle; continuity=$continuity; source=Limit-Text ([string]$Prepare.source) 120; recordedAt=$now; recovered=$true; materialization=@($materialization) }
    Add-StateEvent $id $commit
    $durableCommit = $true
    Commit-TaskCompletionProjection $projection $id $Prepare.entities $Prepare.lifecycle ($actualRevision+1) $eventId $now
    $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$authority.outboxEventId)
    if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_AUTHORITY_OUTBOX_ACK_FAILED' }
    Remove-TaskCompletionStaging @($Prepare.commands) ([string]$Prepare.continuity.manifestPath) $materialization
    return [pscustomobject]@{ ok=$true; taskId=$id; transactionId=$Prepare.transactionId; revision=$actualRevision+1; recovered=$true; contractRevision=[int]$Prepare.continuity.contractRevision; planFingerprint=[string]$Prepare.continuity.planFingerprint }
  } catch {
    $rollback = [pscustomobject]@{ attempted=$false; verified=$false; error='' }
    if (-not $durableCommit) { $rollback = Restore-TaskMaterializationSafely $materialization }
    elseif ($authorityCommitted) { $rollback.error = 'durable_commit_present' }
    return [pscustomobject]@{ ok=$false; reason='materialization_failed'; error=$_.Exception.Message; taskId=$id; transactionId=$Prepare.transactionId; rollback=$rollback; authorityCommitted=$authorityCommitted }
  }
}

function Get-ActiveBundleManifestRecord([string]$ManifestPath,[string]$Id) {
  if ([string]::IsNullOrWhiteSpace($ManifestPath)) { throw 'TASK_STATE_ACTIVE_BUNDLE_MANIFEST_REQUIRED' }
  $full = [IO.Path]::GetFullPath($ManifestPath)
  if (-not (Test-ChildPath $stagingRoot $full)) { throw "TASK_STATE_ACTIVE_BUNDLE_MANIFEST_OUTSIDE_STAGING path=$full" }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "TASK_STATE_ACTIVE_BUNDLE_MANIFEST_NOT_FOUND path=$full" }
  if ((Get-Item -LiteralPath $full).Length -gt 262144) { throw 'TASK_STATE_ACTIVE_BUNDLE_MANIFEST_TOO_LARGE' }
  $value = Read-JsonFile $full
  if (-not $value -or [string]$value.schema -ne 'super-brain.active-task-bundle-manifest.v1') { throw 'TASK_STATE_ACTIVE_BUNDLE_MANIFEST_INVALID' }
  if ([string]$value.taskId -ne $Id) { throw "TASK_STATE_IDENTITY_MISMATCH expected=$Id actual=$($value.taskId)" }
  if ([string]::IsNullOrWhiteSpace([string]$value.workspaceKey)) { throw 'TASK_STATE_ACTIVE_BUNDLE_WORKSPACE_REQUIRED' }
  if ([string]$value.packageVersion -ne [string](Get-SuperBrainManifest $Root).version) { throw 'TASK_STATE_ACTIVE_BUNDLE_VERSION_MISMATCH' }
  if (-not $value.PSObject.Properties['commands'] -or @($value.commands).Count -lt 3) { throw 'TASK_STATE_ACTIVE_BUNDLE_COMMANDS_REQUIRED' }
  if (-not $value.PSObject.Properties['expectedTaskStateRevision'] -or [int]$value.expectedTaskStateRevision -lt 0) { throw 'TASK_STATE_ACTIVE_BUNDLE_REVISION_REQUIRED' }
  return [pscustomobject]@{ path=$full; hash=Get-FileSha256 $full; value=$value }
}

function Get-ActiveBundleCommand([object[]]$Commands,[string]$Role,[switch]$Required) {
  $matches = @($Commands | Where-Object { [string]$_.role -eq $Role })
  if ($matches.Count -gt 1) { throw "TASK_STATE_ACTIVE_BUNDLE_COMMAND_DUPLICATE role=$Role" }
  if ($Required -and $matches.Count -ne 1) { throw "TASK_STATE_ACTIVE_BUNDLE_COMMAND_REQUIRED role=$Role" }
  if ($matches.Count -eq 1) { return $matches[0] }
  return $null
}

function Get-ActiveBundleTaskCardDirectory([string]$Status) {
  $normalized = ([string]$Status).ToLowerInvariant()
  if ($normalized -in @('paused','waiting')) { return 'paused' }
  if ($normalized -eq 'blocked') { return 'blocked' }
  if ($normalized -in @('active','running','in_progress')) { return 'active' }
  throw "TASK_STATE_ACTIVE_BUNDLE_STATUS_INVALID status=$Status"
}

function Assert-ActiveBundlePayloadCommand([object]$Command,[string]$Role,[string]$Operation,[string]$Id,[string]$WorkspaceKey) {
  if (-not $Command) { throw "TASK_STATE_ACTIVE_BUNDLE_COMMAND_REQUIRED role=$Role" }
  if ([string]$Command.operation -ne $Operation) { throw "TASK_STATE_ACTIVE_BUNDLE_OPERATION_INVALID role=$Role operation=$($Command.operation)" }
  $null = Assert-CompletionCommandTarget $Command $Id $WorkspaceKey
  if ([string]::IsNullOrWhiteSpace([string]$Command.payloadPath)) { throw "TASK_STATE_ACTIVE_BUNDLE_PAYLOAD_REQUIRED role=$Role" }
  return Read-Payload ([string]$Command.payloadPath) $Id
}

function Get-OrderedActiveBundleCommands([object[]]$Commands) {
  $order = @('active_checkpoint','active_task_card','checkpoint_pointer','active_task_card_cleanup')
  $ordered = @()
  foreach ($role in $order) {
    foreach ($command in @($Commands | Where-Object { [string]$_.role -eq $role })) { $ordered += $command }
  }
  return @($ordered)
}

function Assert-ActiveBundleManifest([object]$Manifest,[string]$Id,[int]$ActualRevision) {
  $value = $Manifest.value
  $workspaceKey = Get-SuperBrainWorkspaceKey ([string]$value.workspaceKey)
  if ([string]::IsNullOrWhiteSpace($workspaceKey)) { throw 'TASK_STATE_ACTIVE_BUNDLE_WORKSPACE_REQUIRED' }
  if ([int]$value.expectedTaskStateRevision -ne $ActualRevision) { throw "TASK_STATE_CAS_MISMATCH expected=$($value.expectedTaskStateRevision) actual=$ActualRevision taskId=$Id" }
  $commands = @($value.commands)
  $allowedRoles = @('active_checkpoint','active_task_card','checkpoint_pointer','active_task_card_cleanup')
  foreach ($command in $commands) {
    if ([string]$command.role -notin $allowedRoles) { throw "TASK_STATE_ACTIVE_BUNDLE_ROLE_INVALID role=$($command.role)" }
  }
  $checkpointCommand = Get-ActiveBundleCommand $commands 'active_checkpoint' -Required
  $checkpointPayload = Assert-ActiveBundlePayloadCommand $checkpointCommand 'active_checkpoint' 'replace_if_hash' $Id $workspaceKey
  $checkpoint = $checkpointPayload.value
  if (-not (Test-CompletionWorkspace $checkpoint $workspaceKey)) { throw 'TASK_STATE_ACTIVE_BUNDLE_CHECKPOINT_WORKSPACE_MISMATCH' }
  $checkpointStatus = ([string]$checkpoint.status).ToLowerInvariant()
  if ($checkpointStatus -notin @('active','running','in_progress','paused','waiting','blocked')) { throw 'TASK_STATE_ACTIVE_BUNDLE_CHECKPOINT_STATUS_INVALID' }
  $expectedCheckpointPath = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\checkpoints\active') $Id '.json'
  if (-not [string]::Equals([IO.Path]::GetFullPath([string]$checkpointCommand.targetPath),$expectedCheckpointPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_ACTIVE_BUNDLE_CHECKPOINT_TARGET_INVALID' }

  $taskCardCommand = Get-ActiveBundleCommand $commands 'active_task_card' -Required
  $taskCardPayload = Assert-ActiveBundlePayloadCommand $taskCardCommand 'active_task_card' 'replace_if_hash' $Id $workspaceKey
  $taskCard = $taskCardPayload.value
  if (-not (Test-CompletionWorkspace $taskCard $workspaceKey)) { throw 'TASK_STATE_ACTIVE_BUNDLE_TASK_CARD_WORKSPACE_MISMATCH' }
  $taskCardStatus = ([string]$taskCard.status).ToLowerInvariant()
  if ($taskCardStatus -ne $checkpointStatus) { throw 'TASK_STATE_ACTIVE_BUNDLE_STATUS_MISMATCH' }
  $expectedTaskCardPath = Get-SuperBrainCanonicalTaskPath (Join-Path (Join-Path $SharedRoot 'tasks') (Get-ActiveBundleTaskCardDirectory $taskCardStatus)) $Id '.task.json'
  if (-not [string]::Equals([IO.Path]::GetFullPath([string]$taskCardCommand.targetPath),$expectedTaskCardPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_ACTIVE_BUNDLE_TASK_CARD_TARGET_INVALID' }

  $pointerCommand = Get-ActiveBundleCommand $commands 'checkpoint_pointer' -Required
  $pointerPayload = Assert-ActiveBundlePayloadCommand $pointerCommand 'checkpoint_pointer' 'conditional_pointer' $Id $workspaceKey
  if ([string]$pointerPayload.hash -ne [string]$checkpointPayload.hash) { throw 'TASK_STATE_ACTIVE_BUNDLE_POINTER_PAYLOAD_MISMATCH' }
  foreach ($cleanup in @($commands | Where-Object { [string]$_.role -eq 'active_task_card_cleanup' })) {
    if ([string]$cleanup.operation -ne 'delete_identity') { throw 'TASK_STATE_ACTIVE_BUNDLE_CLEANUP_OPERATION_INVALID' }
    $target = Assert-CompletionCommandTarget $cleanup $Id $workspaceKey
    if ([string]::Equals($target,$expectedTaskCardPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_ACTIVE_BUNDLE_CLEANUP_TARGET_CURRENT' }
    if (-not [string]::IsNullOrWhiteSpace([string]$cleanup.payloadPath)) { throw 'TASK_STATE_ACTIVE_BUNDLE_CLEANUP_PAYLOAD_FORBIDDEN' }
  }
  $ordered = Get-OrderedActiveBundleCommands $commands
  if ($ordered.Count -ne $commands.Count) { throw 'TASK_STATE_ACTIVE_BUNDLE_COMMAND_ORDER_INCOMPLETE' }
  return [pscustomobject]@{ workspaceKey=$workspaceKey; commands=@($ordered); checkpointCommand=$checkpointCommand; checkpointPayload=$checkpointPayload; checkpoint=$checkpoint; taskCardCommand=$taskCardCommand; taskCardPayload=$taskCardPayload; taskCard=$taskCard }
}

function Get-ActiveBundleLifecycle([object]$Projection,[object]$Entities,[string]$WorkspaceKey,[string]$Source) {
  $lifecycle = if ($Projection.lifecycle) { $Projection.lifecycle | ConvertTo-Json -Depth 12 | ConvertFrom-Json } else { [pscustomobject]@{} }
  $trial = [pscustomobject]@{ taskId=[string]$Projection.taskId; revision=[int]$Projection.revision; updatedAt=''; lastEventId=''; entities=$Entities; lifecycle=$lifecycle }
  $null = Update-ProjectionLifecycleFromEntities $trial $Source
  $trial.lifecycle | Add-Member -NotePropertyName workspaceKey -NotePropertyValue $WorkspaceKey -Force
  $trial.lifecycle | Add-Member -NotePropertyName source -NotePropertyValue (Limit-Text $Source 120) -Force
  return $trial.lifecycle
}

function Commit-ActiveTaskBundle([string]$Id,[string]$ManifestPath,[string]$Writer) {
  if ([string]::IsNullOrWhiteSpace($Id)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $manifest = Get-ActiveBundleManifestRecord $ManifestPath $Id
  return Invoke-SuperBrainFileLock $mutationGate {
    Assert-NoIncompleteTaskTransaction $Id
    $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $Id)) $Id
    if ([string]$projection.lifecycle.status -in @('completed','cancelled','archived','quarantined')) { throw "TASK_STATE_LIFECYCLE_TERMINAL taskId=$Id status=$($projection.lifecycle.status)" }
    $actualRevision = [int]$projection.revision
    $validated = Assert-ActiveBundleManifest $manifest $Id $actualRevision
    $maintenance = if ($MaintenanceOverride) { New-MaintenanceAudit 'CommitActiveBundle' $MaintenanceReason $Writer } else { $null }
    $checkpointOwner = New-OwnerRecord $validated.checkpoint '' '' '' '' $LeaseSeconds ([string]$validated.checkpoint.status)
    $taskCardOwner = New-OwnerRecord $validated.taskCard '' '' '' '' $LeaseSeconds ([string]$validated.taskCard.status)
    foreach ($entry in @(@('checkpoint',(Get-EntityValue $projection 'checkpoint'),$checkpointOwner),@('task_card',(Get-EntityValue $projection 'task_card'),$taskCardOwner))) {
      if (-not (Test-OwnerComplete $entry[2])) { throw "TASK_STATE_ACTIVE_BUNDLE_OWNER_REQUIRED kind=$($entry[0])" }
      if (-not $MaintenanceOverride -and $entry[1] -and (-not $entry[1].owner -or -not (Test-OwnerMatch $entry[2] $entry[1].owner))) { throw "TASK_STATE_ACTIVE_BUNDLE_OWNER_MISMATCH kind=$($entry[0])" }
    }
    $nextRevision = $actualRevision + 1
    $transactionId = [guid]::NewGuid().ToString('n')
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $entities = [pscustomobject]@{
      context = Get-EntityValue $projection 'context'
      checkpoint = New-TaskCompletionEntityRecord ([string]$validated.checkpointCommand.targetPath) ([string]$validated.checkpointPayload.hash) ([string]$validated.checkpoint.status) $Writer $checkpointOwner
      task_card = New-TaskCompletionEntityRecord ([string]$validated.taskCardCommand.targetPath) ([string]$validated.taskCardPayload.hash) ([string]$validated.taskCard.status) $Writer $taskCardOwner
    }
    $lifecycle = Get-ActiveBundleLifecycle $projection $entities $validated.workspaceKey $Writer
    $bundle = [pscustomobject]@{ manifestPath=$manifest.path; manifestHash=$manifest.hash; workspaceKey=$validated.workspaceKey; checkpointPath=[string]$validated.checkpointCommand.targetPath; checkpointHash=[string]$validated.checkpointPayload.hash; taskCardPath=[string]$validated.taskCardCommand.targetPath; taskCardHash=[string]$validated.taskCardPayload.hash }
    $authority = $null
    $authorityBinding = Get-ExistingTaskAuthorityContract $Id $validated.workspaceKey $validated.checkpoint
    if ($authorityBinding) {
      $authorityContract = $authorityBinding.contract
      $lifecycle | Add-Member -NotePropertyName ownerSessionKey -NotePropertyValue ([string]$authorityContract.ownerSessionKey) -Force
      $lifecycle | Add-Member -NotePropertyName taskInstanceId -NotePropertyValue ([string]$authorityContract.taskInstanceId) -Force
      $lifecycle | Add-Member -NotePropertyName planFingerprint -NotePropertyValue ([string]$authorityContract.planReceipt.planFingerprint) -Force
      $lifecycle | Add-Member -NotePropertyName contractRevision -NotePropertyValue ([int]$authorityContract.revision) -Force
      $authority = Apply-TaskAuthorityTransition $Id $authorityContract $projection $entities $lifecycle @($validated.commands) $actualRevision $Writer 'active_task_bundle' ([string]$manifest.hash)
      if (-not $authority.ok) { throw ('TASK_STATE_SQLITE_AUTHORITY_APPLY_FAILED code=' + [string]$authority.code + ' error=' + (Limit-Text ([string]$authority.error) 240)) }
      foreach ($entry in @(@('authorityAggregateId',[string]$authority.aggregateId),@('authorityRevision',[int]$authority.revision),@('authorityStateHash',[string]$authority.stateHash),@('authorityOutboxEventId',[string]$authority.outboxEventId))) {
        $lifecycle | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1] -Force
        $bundle | Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1] -Force
      }
    }
    if ($FaultPoint -eq 'after_authority') {
      if (-not $authority) { throw 'TASK_STATE_SQLITE_AUTHORITY_NOT_INITIALIZED' }
      throw 'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY'
    }
    $prepare = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='prepared'; transactionKind='active_task_bundle'; transactionId=$transactionId; eventId=[guid]::NewGuid().ToString('n'); taskId=$Id; revision=0; targetRevision=$nextRevision; previousRevision=$actualRevision; commands=@($validated.commands); entities=$entities; lifecycle=$lifecycle; bundle=$bundle; maintenance=$maintenance; source=Limit-Text $Writer 120; recordedAt=$now }
    Add-StateEvent $Id $prepare
    if ($FaultPoint -eq 'after_prepare') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_PREPARE' }
    $materialization = @()
    $durableCommit = $false
    try {
    $materialization = @(Invoke-TaskCompletionMaterialization @($validated.commands) $Id $validated.workspaceKey $transactionId $FaultAfterMaterialization)
    if ($FaultPoint -eq 'after_materialize') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZE' }
    foreach ($record in @(@($bundle.checkpointPath,$bundle.checkpointHash),@($bundle.taskCardPath,$bundle.taskCardHash))) {
      if ((Get-FileSha256 ([string]$record[0])) -ne [string]$record[1]) { throw "TASK_STATE_ACTIVE_BUNDLE_MATERIALIZATION_HASH_MISMATCH path=$($record[0])" }
    }
    $eventId = [guid]::NewGuid().ToString('n')
    $committedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind='active_task_bundle'; transactionId=$transactionId; authorityOutboxEventId=if($authority){[string]$authority.outboxEventId}else{''}; authorityStateHash=if($authority){[string]$authority.stateHash}else{''}; eventId=$eventId; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entities=$entities; lifecycle=$lifecycle; bundle=$bundle; maintenance=$maintenance; source=Limit-Text $Writer 120; recordedAt=$committedAt; materialization=@($materialization) }
    Add-StateEvent $Id $commit
    $durableCommit = $true
    if ($FaultPoint -eq 'after_commit') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_COMMIT' }
    Commit-TaskCompletionProjection $projection $Id $entities $lifecycle $nextRevision $eventId $committedAt
    if ($authority) {
      $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$authority.outboxEventId)
      if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_SQLITE_AUTHORITY_OUTBOX_ACK_FAILED' }
    }
    Remove-TaskCompletionStaging @($validated.commands) $manifest.path $materialization
    return [pscustomobject]@{ ok=$true; changed=$true; taskId=$Id; transactionId=$transactionId; revision=$nextRevision; previousRevision=$actualRevision; authorityMode=if($authority){'sqlite'}else{'deferred_until_task_authority'}; authorityRevision=if($authority){[int]$authority.revision}else{0}; checkpointPath=$bundle.checkpointPath; taskCardPath=$bundle.taskCardPath; projectionPath=Get-ProjectionPath $Id; eventPath=Get-EventPath $Id; materialization=@($materialization); maintenanceOverride=[bool]$MaintenanceOverride; maintenanceReason=if($maintenance){[string]$maintenance.reason}else{''}; guard=if($authority){'Existing SQLite task authority committed first; active checkpoint and task-card compatibility projections were then materialized and acknowledged.'}else{'No SQLite task aggregate exists yet. The recoverable file transaction remains a compatibility bootstrap and will be imported when a task-scoped contract establishes canonical authority.'} }
    } catch {
      $originalError = $_.Exception.Message
      $preserveForRecovery = ($FaultPoint -eq 'after_materialize' -or (Test-TaskStateMaterializationFaultInjected $originalError))
      $rollback = if (-not $durableCommit -and -not $preserveForRecovery) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error=if($durableCommit){'durable_commit_present'}else{'fault_injection_preserved'} } }
      if ($rollback.attempted -and -not $rollback.verified) { throw "TASK_STATE_ACTIVE_BUNDLE_ROLLBACK_FAILED error=$($rollback.error) original=$originalError" }
      throw
    }
  }
}

function Complete-PreparedActiveTaskBundle([object]$Prepare) {
  $id = [string]$Prepare.taskId
  $workspaceKey = [string]$Prepare.bundle.workspaceKey
  $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
  $actualRevision = [int]$projection.revision
  if ($actualRevision -ne [int]$Prepare.previousRevision -or [int]$Prepare.targetRevision -ne ($actualRevision + 1)) { return [pscustomobject]@{ ok=$false; reason='revision_advanced'; taskId=$id; transactionId=$Prepare.transactionId } }
  $materialization = @()
  $authorityCommitted = [bool]($Prepare.bundle -and -not [string]::IsNullOrWhiteSpace([string]$Prepare.bundle.authorityOutboxEventId))
  $durableCommit = $false
  try {
    $materialization = @(Invoke-TaskCompletionMaterialization @($Prepare.commands) $id $workspaceKey ([string]$Prepare.transactionId) 0)
    foreach ($record in @(@([string]$Prepare.bundle.checkpointPath,[string]$Prepare.bundle.checkpointHash),@([string]$Prepare.bundle.taskCardPath,[string]$Prepare.bundle.taskCardHash))) {
      if ((Get-FileSha256 ([string]$record[0])) -ne [string]$record[1]) { throw "TASK_STATE_ACTIVE_BUNDLE_MATERIALIZATION_HASH_MISMATCH path=$($record[0])" }
    }
    $eventId = [guid]::NewGuid().ToString('n')
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind='active_task_bundle'; transactionId=[string]$Prepare.transactionId; authorityOutboxEventId=if($Prepare.bundle){[string]$Prepare.bundle.authorityOutboxEventId}else{''}; authorityStateHash=if($Prepare.bundle){[string]$Prepare.bundle.authorityStateHash}else{''}; eventId=$eventId; taskId=$id; revision=$actualRevision+1; previousRevision=$actualRevision; entities=$Prepare.entities; lifecycle=$Prepare.lifecycle; bundle=$Prepare.bundle; source=Limit-Text ([string]$Prepare.source) 120; recordedAt=$now; recovered=$true; materialization=@($materialization) }
    Add-StateEvent $id $commit
    $durableCommit = $true
    # Once the committed WAL event is durable, replay must finish the
    # projection/outbox work rather than roll files back behind the journal.
    Commit-TaskCompletionProjection $projection $id $Prepare.entities $Prepare.lifecycle ($actualRevision+1) $eventId $now
    if ($Prepare.bundle -and -not [string]::IsNullOrWhiteSpace([string]$Prepare.bundle.authorityOutboxEventId)) {
      $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$Prepare.bundle.authorityOutboxEventId)
      if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_AUTHORITY_OUTBOX_ACK_FAILED' }
    }
    Remove-TaskCompletionStaging @($Prepare.commands) ([string]$Prepare.bundle.manifestPath) $materialization
    return [pscustomobject]@{ ok=$true; taskId=$id; transactionId=$Prepare.transactionId; revision=$actualRevision+1; recovered=$true }
  } catch {
    $rollback = [pscustomobject]@{ attempted=$false; verified=$false; error='' }
    if (-not $durableCommit) { $rollback = Restore-TaskMaterializationSafely $materialization }
    elseif ($authorityCommitted) { $rollback.error = 'durable_commit_present' }
    return [pscustomobject]@{ ok=$false; reason='materialization_failed'; error=$_.Exception.Message; taskId=$id; transactionId=$Prepare.transactionId; rollback=$rollback; authorityCommitted=$authorityCommitted; durableCommit=$durableCommit }
  }
}

function Complete-PreparedProjectionPathRebind([object]$Prepare) {
  $id = [string]$Prepare.taskId
  $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
  $actualRevision = [int]$projection.revision
  if ($actualRevision -ne [int]$Prepare.previousRevision -or [int]$Prepare.targetRevision -ne ($actualRevision + 1)) { return [pscustomobject]@{ ok=$false; reason='revision_advanced'; taskId=$id; transactionId=$Prepare.transactionId } }
  if (-not $Prepare.rebind -or -not $Prepare.rebind.records) { return [pscustomobject]@{ ok=$false; reason='rebind_records_missing'; taskId=$id; transactionId=$Prepare.transactionId } }
  if (-not [string]::Equals([string]$projection.lifecycle.status,[string]$Prepare.rebind.sourceLifecycle,[StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ ok=$false; reason='lifecycle_changed'; taskId=$id; transactionId=$Prepare.transactionId } }
  $workspaceKey = Get-SuperBrainWorkspaceKey ([string]$projection.lifecycle.workspaceKey)
  $materialization = @()
  $durableCommit = $false
  foreach ($record in @($Prepare.rebind.records)) {
    try {
      $canonical = Get-SuperBrainCanonicalTaskStateEntityPath $id ([string]$record.entityKind) $WorkspaceRoot $SharedRoot ([string]$record.materializationSourcePath)
      if (-not [string]::Equals($canonical,[string]$record.targetPath,[StringComparison]::OrdinalIgnoreCase)) { throw "TASK_STATE_REBIND_TARGET_NOT_CANONICAL entityKind=$($record.entityKind)" }
      $source = Read-Entity ([string]$record.materializationSourcePath) $id
      if (-not [string]::Equals([string]$source.hash,[string]$record.hash,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$source.status,[string]$record.status,[StringComparison]::OrdinalIgnoreCase)) {
        throw "TASK_STATE_REBIND_MATERIALIZATION_SOURCE_CHANGED entityKind=$($record.entityKind)"
      }
      if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
        $role = switch ([string]$record.entityKind) {
          'context' { 'current_context' }
          'checkpoint' { 'active_checkpoint' }
          'task_card' { 'active_task_card' }
          default { throw "TASK_STATE_ENTITY_KIND_INVALID kind=$($record.entityKind)" }
        }
        $backupCommand = [pscustomobject]@{
          role=$role; operation='replace_if_hash'; targetPath=$canonical; payloadPath=[string]$record.materializationSourcePath; payloadHash=[string]$record.hash; expectedTargetHash=Get-FileSha256 $canonical
          expectedTaskId=$id; expectedWorkspaceKey=$workspaceKey
        }
        $backup = New-TaskMaterializationBackup $backupCommand $id $workspaceKey ([string]$Prepare.transactionId) (@($materialization).Count + 1)
        $materializedRecord = [pscustomobject]@{
          targetPath=[string]$backup.targetPath; beforeExists=[bool]$backup.beforeExists; beforePath=[string]$backup.beforePath
          beforeHash=[string]$backup.beforeHash; rollbackRoot=[string]$backup.rollbackRoot
          expectedAfterExists=[bool]$backup.expectedAfterExists; expectedAfterHash=[string]$backup.expectedAfterHash
          role=[string]$backup.role; ordinal=[int]$backup.ordinal; action='pending'; changed=$false
        }
        $materialization += $materializedRecord
        $result = Materialize-ProjectionPathRebindTarget ([string]$record.materializationSourcePath) $canonical ([string]$record.hash) ([string]$Prepare.transactionId)
        foreach ($property in @($result.PSObject.Properties)) {
          if ($property.Name -in @('targetPath','beforeExists','beforePath','beforeHash','rollbackRoot','expectedAfterExists','expectedAfterHash','role','ordinal')) { continue }
          $materializedRecord | Add-Member -NotePropertyName ([string]$property.Name) -NotePropertyValue $property.Value -Force
        }
        $materializedRecord | Add-Member -NotePropertyName afterHash -NotePropertyValue (Get-FileSha256 ([string]$materializedRecord.targetPath)) -Force
      }
      $target = Read-Entity $canonical $id
      if (-not [string]::Equals([string]$target.hash,[string]$record.hash,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$target.status,[string]$record.status,[StringComparison]::OrdinalIgnoreCase)) {
        throw "TASK_STATE_REBIND_TARGET_CHANGED entityKind=$($record.entityKind)"
      }
    } catch {
      $failure = $_.Exception.Message
      $rollback = if (-not $durableCommit) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error='durable_commit_present' } }
      return [pscustomobject]@{ ok=$false; reason='target_invalid'; taskId=$id; transactionId=$Prepare.transactionId; entityKind=[string]$record.entityKind; error=$failure; rollback=$rollback; durableCommit=$durableCommit }
    }
  }
  try {
    $rebind = Copy-ProjectionPathRebindValue $Prepare.rebind
    $rebind | Add-Member -NotePropertyName materialization -NotePropertyValue @($materialization) -Force
    $eventId = [guid]::NewGuid().ToString('n')
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind='projection_path_rebind'; transactionId=[string]$Prepare.transactionId; authorityOutboxEventId=if($Prepare.PSObject.Properties['authorityOutboxEventId']){[string]$Prepare.authorityOutboxEventId}else{''}; authorityStateHash=if($Prepare.PSObject.Properties['authorityStateHash']){[string]$Prepare.authorityStateHash}else{''}; eventId=$eventId; taskId=$id; revision=$actualRevision+1; previousRevision=$actualRevision; entities=$Prepare.entities; lifecycle=$Prepare.lifecycle; rebind=$rebind; maintenance=if($Prepare.PSObject.Properties['maintenance']){$Prepare.maintenance}else{$null}; source=Limit-Text ([string]$Prepare.source) 120; recordedAt=$now; recovered=$true }
    Add-StateEvent $id $commit
    $durableCommit = $true
    Commit-TaskCompletionProjection $projection $id $Prepare.entities $Prepare.lifecycle ($actualRevision+1) $eventId $now
    if ($Prepare.PSObject.Properties['authorityOutboxEventId'] -and -not [string]::IsNullOrWhiteSpace([string]$Prepare.authorityOutboxEventId)) {
      $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$Prepare.authorityOutboxEventId)
      if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_AUTHORITY_OUTBOX_ACK_FAILED' }
    }
    Remove-TaskCompletionStaging @() '' $materialization
    return [pscustomobject]@{ ok=$true; taskId=$id; transactionId=$Prepare.transactionId; revision=$actualRevision+1; recovered=$true; materialization=@($materialization); guard='Recovered the entire prepared projection-path rebind as one task transaction after revalidating every canonical target.' }
  } catch {
    $rollback = if (-not $durableCommit) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error='durable_commit_present' } }
    return [pscustomobject]@{ ok=$false; reason='commit_failed'; taskId=$id; transactionId=$Prepare.transactionId; error=$_.Exception.Message; rollback=$rollback; durableCommit=$durableCommit }
  }
}

function Complete-PreparedTaskCompletion([object]$Prepare) {
  $id = [string]$Prepare.taskId
  $workspaceKey = [string]$Prepare.completion.workspaceKey
  $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
  $actualRevision = [int]$projection.revision
  if ($actualRevision -ne [int]$Prepare.previousRevision -or [int]$Prepare.targetRevision -ne ($actualRevision + 1)) { return [pscustomobject]@{ ok=$false; reason='revision_advanced'; taskId=$id; transactionId=$Prepare.transactionId } }
  $materialization = @()
  $durableCommit = $false
  try {
    $completionEvidence = if($Prepare.PSObject.Properties['completion']){$Prepare.completion}else{$null}
    $verificationPath = if($completionEvidence -and $completionEvidence.PSObject.Properties['verificationPath']){[string]$completionEvidence.verificationPath}else{''}
    $verificationHash = if($completionEvidence -and $completionEvidence.PSObject.Properties['verificationHash']){[string]$completionEvidence.verificationHash}else{''}
    $binding = if($completionEvidence -and $completionEvidence.PSObject.Properties['evidenceBinding']){$completionEvidence.evidenceBinding}else{$null}
    if ([string]::IsNullOrWhiteSpace($verificationPath) -or [string]::IsNullOrWhiteSpace($verificationHash) -or -not $binding) { return [pscustomobject]@{ ok=$false; reason='historical_completion_evidence'; taskId=$id; transactionId=$Prepare.transactionId } }
    if ((Get-FileSha256 $verificationPath) -ne $verificationHash -or [string]$binding.artifactHash -ne $verificationHash) { return [pscustomobject]@{ ok=$false; reason='completion_artifact_changed_after_prepare'; taskId=$id; transactionId=$Prepare.transactionId } }
    $bindingCheck = Test-SuperBrainEvidenceBinding -Binding $binding -TaskId $id -WorkspaceKey $workspaceKey -OwnerSessionKey ([string]$Prepare.lifecycle.ownerSessionKey) -ArtifactPath $verificationPath -RequireArtifactHash -Root $Root
    if (-not $bindingCheck.ok) { return [pscustomobject]@{ ok=$false; reason=('completion_evidence_' + [string]$bindingCheck.reason); taskId=$id; transactionId=$Prepare.transactionId } }
    $receiptRequired = ($completionEvidence -and $completionEvidence.PSObject.Properties['receiptRequired'] -and $completionEvidence.receiptRequired -eq $true)
    $receiptCommand = @($Prepare.commands | Where-Object { [string]$_.role -eq 'task_completion_receipt' } | Select-Object -First 1)
    if ($receiptRequired -and ($receiptCommand.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$receiptCommand[0].payloadHash))) { return [pscustomobject]@{ ok=$false; reason='completion_receipt_missing_after_prepare'; taskId=$id; transactionId=$Prepare.transactionId } }
    $materialization = @(Invoke-TaskCompletionMaterialization @($Prepare.commands) $id $workspaceKey ([string]$Prepare.transactionId) 0)
    if ($receiptRequired -and (Get-FileSha256 ([string]$receiptCommand[0].targetPath)) -ne [string]$receiptCommand[0].payloadHash) { throw 'TASK_STATE_COMPLETION_RECEIPT_CHANGED_AFTER_PREPARE' }
    $active = @(Get-TaskCompletionActiveRecords $id $workspaceKey)
    if ($active.Count -gt 0) { throw "TASK_STATE_COMPLETION_ACTIVE_STATE_REMAINS count=$($active.Count)" }
    $eventId = [guid]::NewGuid().ToString('n')
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind='task_completion'; transactionId=[string]$Prepare.transactionId; authorityOutboxEventId=if($completionEvidence){[string]$completionEvidence.authorityOutboxEventId}else{''}; authorityStateHash=if($completionEvidence){[string]$completionEvidence.authorityStateHash}else{''}; eventId=$eventId; taskId=$id; revision=$actualRevision+1; previousRevision=$actualRevision; entities=$Prepare.entities; lifecycle=$Prepare.lifecycle; source=Limit-Text ([string]$Prepare.source) 120; recordedAt=$now; recovered=$true; materialization=@($materialization) }
    Add-StateEvent $id $commit
    $durableCommit = $true
    Commit-TaskCompletionProjection $projection $id $Prepare.entities $Prepare.lifecycle ($actualRevision+1) $eventId $now
    if ($completionEvidence -and -not [string]::IsNullOrWhiteSpace([string]$completionEvidence.authorityOutboxEventId)) {
      $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$completionEvidence.authorityOutboxEventId)
      if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { throw 'TASK_STATE_AUTHORITY_OUTBOX_ACK_FAILED' }
    }
    Remove-TaskCompletionStaging @($Prepare.commands) ([string]$Prepare.completion.manifestPath) $materialization
    return [pscustomobject]@{ ok=$true; taskId=$id; transactionId=$Prepare.transactionId; revision=$actualRevision+1; recovered=$true; activeStateCount=0 }
  } catch {
    $rollback = if (-not $durableCommit) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error='durable_commit_present' } }
    return [pscustomobject]@{ ok=$false; reason='materialization_failed'; error=$_.Exception.Message; taskId=$id; transactionId=$Prepare.transactionId; rollback=$rollback; durableCommit=$durableCommit }
  }
}

function Test-TaskStateTerminalEvidenceStatus([string]$Status) {
  return ([string]$Status).ToLowerInvariant() -in @('completed','verified','cancelled','archived')
}

function Get-AmbiguousStateExpectedPath([string]$Id,[string]$Kind) {
  switch ($Kind) {
    'context' { return Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'guard-state\current-task-contexts') $Id '.json' }
    'checkpoint' { return Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'runtime-state\checkpoints\completed') $Id '.json' }
    'task_card' { return Get-SuperBrainCanonicalTaskPath (Join-Path $SharedRoot 'tasks\completed') $Id '.task.json' }
  }
  throw "TASK_STATE_AMBIGUOUS_KIND_INVALID kind=$Kind"
}

function Get-AmbiguousStateRole([string]$Kind) {
  switch ($Kind) {
    'context' { return 'current_context' }
    'checkpoint' { return 'completed_checkpoint' }
    'task_card' { return 'completed_task_card' }
  }
  throw "TASK_STATE_AMBIGUOUS_KIND_INVALID kind=$Kind"
}

function Get-AmbiguousWakeRole([string]$Kind) {
  switch ($Kind) {
    'context' { return 'current_context' }
    'checkpoint' { return 'active_checkpoint' }
    'task_card' { return 'active_task_card' }
    'execution_contract' { return 'execution_contract' }
    'goal_route_lock' { return 'goal_route_lock' }
    'route_checkpoint' { return 'route_checkpoint' }
  }
  return ''
}

function Get-AmbiguousStateEntity([string]$Id,[string]$Kind,[object]$ProjectedEntity) {
  $expectedPath = Get-AmbiguousStateExpectedPath $Id $Kind
  $projectedPath = if ($ProjectedEntity) { [string]$ProjectedEntity.path } else { '' }
  $projectedHash = if ($ProjectedEntity) { [string]$ProjectedEntity.hash } else { '' }
  $projectedStatus = if ($ProjectedEntity) { [string]$ProjectedEntity.status } else { '' }
  $errors = New-Object System.Collections.ArrayList
  $root = Split-Path -Parent $expectedPath
  $pattern = if ($Kind -eq 'task_card') { '*.task.json' } else { '*.json' }
  $matching = @()
  $sameTaskWrongState = @()
  if (Test-Path -LiteralPath $root -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter $pattern -File -ErrorAction SilentlyContinue)) {
      $candidate = Read-JsonFile $file.FullName
      if (-not $candidate -or [string]$candidate.taskId -ne $Id) { continue }
      $status = [string]$candidate.status
      $validStatus = if ($Kind -eq 'context') { $status -eq 'active' } else { Test-TaskStateTerminalEvidenceStatus $status }
      if ($validStatus) { $matching += [pscustomobject]@{path=$file.FullName;value=$candidate;hash=Get-FileSha256 $file.FullName;status=$status;canonical=[string]::Equals($file.FullName,$expectedPath,[StringComparison]::OrdinalIgnoreCase)} }
      else { $sameTaskWrongState += [pscustomobject]@{path=$file.FullName;status=$status} }
    }
  }
  $matching = @($matching | Sort-Object @{Expression='canonical';Descending=$true},path)
  if ($matching.Count -gt 1) { [void]$errors.Add('ambiguous_current_source') }
  if ($matching.Count -eq 0 -and $sameTaskWrongState.Count -gt 0) {
    $stateError = if ($Kind -eq 'context') { 'current_context_not_active' } else { 'current_terminal_evidence_status_invalid' }
    [void]$errors.Add($stateError)
  }
  if ($projectedPath -and (Test-Path -LiteralPath $projectedPath -PathType Leaf) -and -not (Test-ChildPath $root $projectedPath)) {
    [void]$errors.Add('projected_source_outside_current_root')
  }
  $selected = if ($matching.Count -eq 1) { $matching[0] } elseif ($matching.Count -gt 1 -and $matching[0].canonical) { $matching[0] } else { $null }
  $exists = ($null -ne $selected)
  $value = if ($selected) { $selected.value } else { $null }
  $actualHash = if ($selected) { [string]$selected.hash } else { '' }
  $actualStatus = if ($selected) { [string]$selected.status } else { '' }
  $currentPath = if ($selected) { [string]$selected.path } else { $expectedPath }
  return [pscustomobject]@{
    kind = $Kind
    role = Get-AmbiguousStateRole $Kind
    projectedPath = $projectedPath
    projectedHash = $projectedHash
    projectedStatus = $projectedStatus
    currentPath = $currentPath
    currentExists = [bool]$exists
    currentHash = $actualHash
    currentStatus = $actualStatus
    currentValue = $value
    errors = @($errors)
  }
}

function Get-TaskWakeReferences([string]$Id,[string[]]$AllowedPaths=@()) {
  $allowed = @{}
  foreach ($path in @($AllowedPaths)) { if ($path) { $allowed[[IO.Path]::GetFullPath($path).ToLowerInvariant()] = $true } }
  $references = New-Object System.Collections.ArrayList
  function Add-WakeReference([string]$Kind,[string]$Path,[string]$Status='') {
    $full = [IO.Path]::GetFullPath($Path)
    if ($allowed.ContainsKey($full.ToLowerInvariant())) { return }
    [void]$references.Add([pscustomobject]@{ kind=$Kind; path=$full; hash=Get-FileSha256 $full; status=$Status })
  }
  foreach ($spec in @(
    [pscustomobject]@{kind='context';root=(Join-Path $WorkspaceRoot 'guard-state\current-task-contexts');pattern='*.json';predicate={param($v)[string]$v.status -eq 'active'}},
    [pscustomobject]@{kind='checkpoint';root=(Join-Path $WorkspaceRoot 'runtime-state\checkpoints\active');pattern='*.json';predicate={param($v)[string]$v.status -eq 'active'}},
    [pscustomobject]@{kind='task_card';root=(Join-Path $SharedRoot 'tasks\active');pattern='*.task.json';predicate={param($v)[string]$v.status -notin @('completed','verified','cancelled','archived')}},
    [pscustomobject]@{kind='task_card';root=(Join-Path $SharedRoot 'tasks\paused');pattern='*.task.json';predicate={param($v)[string]$v.status -notin @('completed','verified','cancelled','archived')}},
    [pscustomobject]@{kind='task_card';root=(Join-Path $SharedRoot 'tasks\blocked');pattern='*.task.json';predicate={param($v)[string]$v.status -notin @('completed','verified','cancelled','archived')}},
    [pscustomobject]@{kind='execution_contract';root=(Join-Path $WorkspaceRoot 'runtime-state\execution-contracts');pattern='*.json';predicate={param($v)[string]$v.status -eq 'active'}},
    [pscustomobject]@{kind='goal_route_lock';root=(Join-Path $WorkspaceRoot 'guard-state\goal-route-locks');pattern='*.json';predicate={param($v)$v.active -eq $true -or [string]$v.status -eq 'active'}},
    [pscustomobject]@{kind='route_checkpoint';root=(Join-Path $WorkspaceRoot 'guard-state\route-checkpoints');pattern='*.json';predicate={param($v)[string]$v.status -in @('clean','route_drift_detected')}}
  )) {
    if (-not (Test-Path -LiteralPath $spec.root -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $spec.root -Filter $spec.pattern -File -ErrorAction SilentlyContinue)) {
      $value = Read-JsonFile $file.FullName
      if ($value -and [string]$value.taskId -eq $Id -and (& $spec.predicate $value)) { Add-WakeReference $spec.kind $file.FullName ([string]$value.status) }
    }
  }
  $pointerRoot = Join-Path $WorkspaceRoot 'guard-state\current-task-context-pointers'
  if (Test-Path -LiteralPath $pointerRoot -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $pointerRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $value = Read-JsonFile $file.FullName
      if ($value -and [string]$value.taskId -eq $Id) { Add-WakeReference 'workspace_pointer' $file.FullName ([string]$value.status) }
    }
  }
  foreach ($name in @('current-task-context.json','active-checkpoint.json','goal-route-lock.json','route-checkpoint.json','last-execution-contract.json')) {
    $path = Join-Path $WorkspaceRoot $name
    $value = Read-JsonFile $path
    if ($value -and [string]$value.taskId -eq $Id) { Add-WakeReference 'compatibility_pointer' $path ([string]$value.status) }
  }
  $hotRoot = Join-Path $WorkspaceRoot 'runtime-state\execution-hot-index'
  if (Test-Path -LiteralPath $hotRoot -PathType Container) {
    foreach ($file in @(Get-ChildItem -LiteralPath $hotRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $index = Read-JsonFile $file.FullName
      if ($index -and @($index.entries | Where-Object { [string]$_.taskId -eq $Id }).Count -gt 0) { Add-WakeReference 'execution_hot_index' $file.FullName 'active' }
    }
  }
  return @($references)
}

function Get-TaskStateSourceProjectionReferences([string]$Id,[object[]]$Entities) {
  $sources=@{}
  foreach($entity in @($Entities | Where-Object { $_.currentExists })) { $sources[[IO.Path]::GetFullPath([string]$entity.currentPath).ToLowerInvariant()] = $true }
  if($sources.Count-eq0){return @()}
  $references=New-Object System.Collections.ArrayList
  foreach($file in @(Get-ChildItem -LiteralPath $projectionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)){
    $projection=Read-JsonFile $file.FullName
    if (-not $projection -or [string]::IsNullOrWhiteSpace([string]$projection.taskId) -or [string]$projection.taskId -eq $Id -or -not $projection.entities) { continue }
    if (-not [string]::Equals($file.FullName,(Get-ProjectionPath ([string]$projection.taskId)),[StringComparison]::OrdinalIgnoreCase)) { continue }
    foreach($kind in @('context','checkpoint','task_card')){
      $entity=$projection.entities.PSObject.Properties[$kind]
      if (-not $entity -or -not $entity.Value -or [string]::IsNullOrWhiteSpace([string]$entity.Value.path)) { continue }
      $path=[IO.Path]::GetFullPath([string]$entity.Value.path)
      if($sources.ContainsKey($path.ToLowerInvariant())){[void]$references.Add([pscustomobject]@{taskId=[string]$projection.taskId;kind=$kind;path=$path})}
    }
  }
  return @($references)
}

function Get-AmbiguousStateCandidate([object]$Projection,[hashtable]$PendingTaskIds) {
  if (-not $Projection -or [string]::IsNullOrWhiteSpace([string]$Projection.taskId)) { return $null }
  $id = [string]$Projection.taskId
  $Projection = Ensure-ProjectionShape $Projection $id
  if ([string]$Projection.lifecycle.status -in @('completed','cancelled','archived','quarantined')) { return $null }
  $context = Get-EntityValue $Projection 'context'
  $checkpoint = Get-EntityValue $Projection 'checkpoint'
  $taskCard = Get-EntityValue $Projection 'task_card'
  $contextActive = ($context -and [string]$context.status -eq 'active')
  $checkpointTerminal = ($checkpoint -and (Test-TaskStateTerminalEvidenceStatus ([string]$checkpoint.status)))
  $taskCardTerminal = ($taskCard -and (Test-TaskStateTerminalEvidenceStatus ([string]$taskCard.status)))
  $classification = ''
  $kinds = @()
  if ($contextActive -and $checkpointTerminal -and $taskCardTerminal -and [string]::IsNullOrWhiteSpace([string]$Projection.lifecycle.completionTransactionId)) {
    $classification = 'completion_evidence_conflict'
    $kinds = @('context','checkpoint','task_card')
  } elseif ($contextActive -and -not $checkpoint -and -not $taskCard) {
    $classification = 'lost_authority'
    $kinds = @('context')
  } else { return $null }

  $entities = @()
  foreach ($kind in $kinds) { $entities += Get-AmbiguousStateEntity $id $kind (Get-EntityValue $Projection $kind) }
  $errors = New-Object System.Collections.ArrayList
  foreach ($entity in $entities) { foreach ($errorCode in @($entity.errors)) { [void]$errors.Add("$($entity.kind):$errorCode") } }
  $existingCount = @($entities | Where-Object { $_.currentExists }).Count
  $sharedSourceReferences=@(Get-TaskStateSourceProjectionReferences $id $entities)
  if($sharedSourceReferences.Count-gt0){[void]$errors.Add('source_referenced_by_other_projection')}
  if ($classification -eq 'completion_evidence_conflict' -and $existingCount -notin @(0,3)) { [void]$errors.Add('partial_current_evidence_set') }
  if ($PendingTaskIds.ContainsKey($id)) { [void]$errors.Add('incomplete_wal_transaction') }
  $terminalSealPath = Get-SuperBrainCanonicalTaskPath (Join-Path $WorkspaceRoot 'task-state-store\terminal-plan-seals') $id '.json'
  if (Test-Path -LiteralPath $terminalSealPath -PathType Leaf) { [void]$errors.Add('terminal_plan_seal_requires_exact_terminal_reconciliation') }
  $allowedPaths = @($entities | Where-Object { $_.kind -eq 'context' -and $_.currentExists } | ForEach-Object { $_.currentPath })
  $wakeReferences = @(Get-TaskWakeReferences $id $allowedPaths)
  $auxiliaryWakeRecords=@()
  $blockedWakeReferences=@()
  foreach($reference in $wakeReferences){
    $role=Get-AmbiguousWakeRole ([string]$reference.kind)
    if([string]::IsNullOrWhiteSpace($role)){$blockedWakeReferences += $reference;continue}
    $duplicateCore=@($entities|Where-Object{$_.currentExists-and[string]::Equals([string]$_.currentPath,[string]$reference.path,[StringComparison]::OrdinalIgnoreCase)}).Count-gt0
    if($duplicateCore){continue}
    $auxiliaryWakeRecords += [pscustomobject]@{kind=[string]$reference.kind;role=$role;path=[string]$reference.path;hash=[string]$reference.hash;status=[string]$reference.status}
  }
  if ($blockedWakeReferences.Count -gt 0) { [void]$errors.Add('external_wake_reference_present') }

  $workspaceKeys = @()
  foreach ($entity in $entities) {
    if ($entity.currentValue -and $entity.currentValue.PSObject.Properties['workspaceKey'] -and -not [string]::IsNullOrWhiteSpace([string]$entity.currentValue.workspaceKey)) { $workspaceKeys += Get-SuperBrainWorkspaceKey ([string]$entity.currentValue.workspaceKey) }
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Projection.lifecycle.workspaceKey)) { $workspaceKeys += Get-SuperBrainWorkspaceKey ([string]$Projection.lifecycle.workspaceKey) }
  $workspaceKeys = @($workspaceKeys | Select-Object -Unique)
  if ($workspaceKeys.Count -gt 1) { [void]$errors.Add('workspace_identity_conflict') }
  $workspaceKey = if ($workspaceKeys.Count -eq 1) { [string]$workspaceKeys[0] } else { '' }
  $fingerprintPayload = [pscustomobject]@{
    taskId=$id; revision=[int]$Projection.revision; classification=$classification; workspaceKey=$workspaceKey
    entities=@($entities | ForEach-Object { [pscustomobject]@{kind=$_.kind;projectedPath=$_.projectedPath;projectedHash=$_.projectedHash;projectedStatus=$_.projectedStatus;currentPath=$_.currentPath;currentExists=$_.currentExists;currentHash=$_.currentHash;currentStatus=$_.currentStatus} })
    sharedSourceReferences=@($sharedSourceReferences | ForEach-Object { [pscustomobject]@{taskId=$_.taskId;kind=$_.kind;path=$_.path} })
    auxiliaryWakeRecords=@($auxiliaryWakeRecords | ForEach-Object { [pscustomobject]@{kind=$_.kind;role=$_.role;path=$_.path;hash=$_.hash;status=$_.status} })
    blockedWakeReferences=@($blockedWakeReferences | ForEach-Object { [pscustomobject]@{kind=$_.kind;path=$_.path;hash=$_.hash;status=$_.status} })
  }
  return [pscustomobject]@{
    taskId=$id
    revision=[int]$Projection.revision
    classification=$classification
    workspaceKey=$workspaceKey
    entities=@($entities)
    sharedSourceReferences=@($sharedSourceReferences)
    auxiliaryWakeRecords=@($auxiliaryWakeRecords)
    blockedWakeReferences=@($blockedWakeReferences)
    sourceCount=$existingCount
    errors=@($errors | Select-Object -Unique)
    applySafe=($errors.Count -eq 0)
    fingerprint=Get-SuperBrainStableHash ($fingerprintPayload | ConvertTo-Json -Depth 10 -Compress) 32
  }
}

function Get-AmbiguousStateCandidates([string]$OnlyTaskId='') {
  $pendingIds=@{}
  foreach ($transaction in @(Get-IncompleteTransactions @(Read-Events))) { $pendingIds[[string]$transaction.taskId]=$true }
  $candidates=@()
  foreach ($file in @(Get-ChildItem -LiteralPath $projectionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $projection=Read-JsonFile $file.FullName
    if (-not $projection -or [string]::IsNullOrWhiteSpace([string]$projection.taskId)) { continue }
    $id=[string]$projection.taskId
    if ($OnlyTaskId -and $id -ne $OnlyTaskId) { continue }
    if (-not [string]::Equals($file.FullName,(Get-ProjectionPath $id),[StringComparison]::OrdinalIgnoreCase)) { continue }
    $candidate=Get-AmbiguousStateCandidate $projection $pendingIds
    if ($candidate) { $candidates += $candidate }
  }
  return @($candidates)
}

function ConvertTo-AmbiguousStateCandidateSummary([object]$Candidate) {
  if (-not $Candidate) { return $null }
  return [pscustomobject]@{
    taskId=[string]$Candidate.taskId;revision=[int]$Candidate.revision;classification=[string]$Candidate.classification;workspaceKey=[string]$Candidate.workspaceKey
    sourceCount=[int]$Candidate.sourceCount;applySafe=[bool]$Candidate.applySafe;errors=@($Candidate.errors);fingerprint=[string]$Candidate.fingerprint
    entities=@($Candidate.entities | ForEach-Object { [pscustomobject]@{kind=$_.kind;role=$_.role;projectedPath=$_.projectedPath;projectedHash=$_.projectedHash;projectedStatus=$_.projectedStatus;currentPath=$_.currentPath;currentExists=[bool]$_.currentExists;currentHash=$_.currentHash;currentStatus=$_.currentStatus;errors=@($_.errors)} })
    sharedSourceReferences=@($Candidate.sharedSourceReferences | ForEach-Object { [pscustomobject]@{taskId=$_.taskId;kind=$_.kind;path=$_.path} })
    auxiliaryWakeRecords=@($Candidate.auxiliaryWakeRecords | ForEach-Object { [pscustomobject]@{kind=$_.kind;role=$_.role;path=$_.path;hash=$_.hash;status=$_.status} })
    blockedWakeReferences=@($Candidate.blockedWakeReferences | ForEach-Object { [pscustomobject]@{kind=$_.kind;path=$_.path;hash=$_.hash;status=$_.status} })
  }
}

function New-QuarantineEntityRecord([object]$Entity,[string]$ArchivePath,[string]$Writer) {
  $owner = $null
  $projected = $Entity.projectedEntity
  if ($projected -and $projected.PSObject.Properties['owner']) { $owner = $projected.owner }
  return [pscustomobject]@{ path=[IO.Path]::GetFullPath($ArchivePath); hash=[string]$Entity.currentHash; status='quarantined'; source=Limit-Text $Writer 120; owner=$owner }
}

function Invoke-AmbiguousStateQuarantine([object]$Preflight,[string]$Writer) {
  return Invoke-SuperBrainFileLock $mutationGate {
    $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath ([string]$Preflight.taskId))) ([string]$Preflight.taskId)
    if ([int]$projection.revision -ne [int]$Preflight.revision) { throw "TASK_STATE_CAS_MISMATCH expected=$($Preflight.revision) actual=$($projection.revision) taskId=$($Preflight.taskId)" }
    $pendingIds=@{}
    foreach ($transaction in @(Get-IncompleteTransactions @(Read-Events))) { $pendingIds[[string]$transaction.taskId]=$true }
    $candidate=Get-AmbiguousStateCandidate $projection $pendingIds
    if (-not $candidate -or -not $candidate.applySafe -or [string]$candidate.fingerprint -ne [string]$Preflight.fingerprint) { throw "TASK_STATE_AMBIGUOUS_PREFLIGHT_CHANGED taskId=$($Preflight.taskId)" }

    $id=[string]$candidate.taskId
    $actualRevision=[int]$projection.revision
    $nextRevision=$actualRevision+1
    $transactionId=[guid]::NewGuid().ToString('n')
    $now=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $entityCommands=New-Object System.Collections.ArrayList
    $auxiliaryCommands=New-Object System.Collections.ArrayList
    $seenSourcePaths=@{}
    $entityRecords=[ordered]@{context=$null;checkpoint=$null;task_card=$null}
    $manifestEntities=@()
    foreach ($entity in @($candidate.entities)) {
      $archivePath=''
      if ($entity.currentExists) {
        $sourceKey=[IO.Path]::GetFullPath([string]$entity.currentPath).ToLowerInvariant()
        if($seenSourcePaths.ContainsKey($sourceKey)){throw "TASK_STATE_QUARANTINE_DUPLICATE_SOURCE path=$($entity.currentPath)"}
        $seenSourcePaths[$sourceKey]=$true
        $sourceWorkspaceKey=Get-QuarantineSourceWorkspaceKey $entity.currentValue ([string]$candidate.workspaceKey)
        $command=New-QuarantinedStateCommand $entity.role $entity.currentPath $transactionId $entity.currentHash $id $sourceWorkspaceKey
        [void]$entityCommands.Add($command)
        $archivePath=[string]$command.archivePath
        $projectedEntity=Get-EntityValue $projection ([string]$entity.kind)
        $entityForRecord=$entity | Select-Object *
        $entityForRecord | Add-Member -NotePropertyName projectedEntity -NotePropertyValue $projectedEntity -Force
        $entityRecords[[string]$entity.kind]=New-QuarantineEntityRecord $entityForRecord $archivePath $Writer
      }
      $manifestEntities += [pscustomobject]@{kind=$entity.kind;projectedPath=$entity.projectedPath;projectedHash=$entity.projectedHash;projectedStatus=$entity.projectedStatus;currentPath=$entity.currentPath;currentExists=$entity.currentExists;currentHash=$entity.currentHash;currentStatus=$entity.currentStatus;quarantinePath=$archivePath}
    }
    $manifestAuxiliary=@()
    foreach($reference in @($candidate.auxiliaryWakeRecords)){
      $sourceKey=[IO.Path]::GetFullPath([string]$reference.path).ToLowerInvariant()
      if($seenSourcePaths.ContainsKey($sourceKey)){continue}
      $seenSourcePaths[$sourceKey]=$true
      $referenceValue=Read-JsonFile ([string]$reference.path)
      $sourceWorkspaceKey=Get-QuarantineSourceWorkspaceKey $referenceValue ([string]$candidate.workspaceKey)
      $command=New-QuarantinedStateCommand $reference.role $reference.path $transactionId $reference.hash $id $sourceWorkspaceKey
      [void]$auxiliaryCommands.Add($command)
      $manifestAuxiliary += [pscustomobject]@{kind=$reference.kind;status=$reference.status;sourcePath=$reference.path;sourceHash=$reference.hash;quarantinePath=[string]$command.archivePath}
    }
    $manifestValue=[pscustomobject]@{
      schema='super-brain.ambiguous-state-quarantine.v1';taskId=$id;classification=[string]$candidate.classification
      projectionRevision=$actualRevision;candidateFingerprint=[string]$candidate.fingerprint;workspaceKey=[string]$candidate.workspaceKey
      reason=if($candidate.classification-eq'completion_evidence_conflict'){'terminal checkpoint and task card coexist with active context without a transaction-bound terminal seal'}else{'active context has no remaining checkpoint or task-card authority'}
      entities=@($manifestEntities);auxiliaryWakeRecords=@($manifestAuxiliary);wakeReferenceCount=$manifestAuxiliary.Count;rawPayloadStored=$false;rawMemoryStored=$false;completionInferred=$false;destructiveDeleteUsed=$false;createdAt=$now
    }
    $manifestStagingPath=Write-CompletionStagingValue $id $transactionId 'ambiguous-state-manifest' $manifestValue
    $manifestTargetPath=Get-ConflictQuarantineManifestPath $id $transactionId
    $commands=New-Object System.Collections.ArrayList
    [void]$commands.Add((New-CompletionCommand 'conflict_manifest' 'upsert' $manifestTargetPath $manifestStagingPath (Get-FileSha256 $manifestTargetPath) $id $candidate.workspaceKey))
    foreach ($command in @($entityCommands)) { [void]$commands.Add($command) }
    foreach ($command in @($auxiliaryCommands)) { [void]$commands.Add($command) }
    $manifestHash=Get-FileSha256 $manifestStagingPath
    $lifecycle=[pscustomobject]@{
      status='quarantined';workspaceKey=[string]$candidate.workspaceKey;ownerSessionKey=[string]$projection.lifecycle.ownerSessionKey
      planFingerprint=[string]$projection.lifecycle.planFingerprint;contractRevision=[int]$projection.lifecycle.contractRevision
      completionTransactionId='';completedAt='';quarantineTransactionId=$transactionId;quarantinedAt=$now
      quarantineReason=[string]$candidate.classification;quarantineManifestPath=$manifestTargetPath;quarantineManifestHash=$manifestHash
      source=Limit-Text $Writer 120
    }
    $entities=[pscustomobject]@{context=$entityRecords.context;checkpoint=$entityRecords.checkpoint;task_card=$entityRecords.task_card}
    $authority=$null
    $authorityWorkspace=[string]$candidate.workspaceKey
    if([string]::IsNullOrWhiteSpace($authorityWorkspace)){
      foreach($entity in @($candidate.entities)){
        if ($entity.currentValue -and $entity.currentValue.PSObject.Properties['workspaceKey'] -and -not [string]::IsNullOrWhiteSpace([string]$entity.currentValue.workspaceKey)) {$authorityWorkspace=[string]$entity.currentValue.workspaceKey;break}
      }
    }
    # Preserve the projection's recorded workspace key as an authority alias candidate.
    # Candidate summaries intentionally normalize it for comparison, but SQLite may still
    # contain a legacy raw key from before workspace-key canonicalization.
    $authorityBinding=if([string]::IsNullOrWhiteSpace($authorityWorkspace)){$null}else{Get-ExistingTaskAuthorityContract $id (Get-SuperBrainWorkspaceKey $authorityWorkspace) $projection.lifecycle}
    if($authorityBinding){
      $authorityContract=$authorityBinding.contract
      $lifecycle|Add-Member -NotePropertyName taskInstanceId -NotePropertyValue ([string]$authorityContract.taskInstanceId) -Force
      $quarantineRecovery=[pscustomobject]@{transactionId=$transactionId;manifestTargetPath=$manifestTargetPath;manifestHash=$manifestHash;candidateFingerprint=[string]$candidate.fingerprint}
      $authority=Apply-TaskAuthorityTransition $id $authorityContract $projection $entities $lifecycle @($commands) $actualRevision $Writer 'task_quarantine' ([string]$candidate.fingerprint) $quarantineRecovery
      if(-not$authority.ok){throw('TASK_STATE_SQLITE_AUTHORITY_APPLY_FAILED code='+[string]$authority.code+' error='+(Limit-Text ([string]$authority.error) 240))}
      foreach($entry in @(@('authorityAggregateId',[string]$authority.aggregateId),@('authorityRevision',[int]$authority.revision),@('authorityStateHash',[string]$authority.stateHash),@('authorityOutboxEventId',[string]$authority.outboxEventId))){$lifecycle|Add-Member -NotePropertyName $entry[0] -NotePropertyValue $entry[1] -Force}
    }
    if($FaultPoint-eq'after_authority'){
      if(-not$authority){throw'TASK_STATE_SQLITE_AUTHORITY_NOT_INITIALIZED'}
      throw'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY'
    }
    $prepare=[pscustomobject]@{
      schema='super-brain.task-state-event.v2';phase='prepared';transactionKind='task_quarantine';transactionId=$transactionId;eventId=[guid]::NewGuid().ToString('n')
      taskId=$id;revision=0;targetRevision=$nextRevision;previousRevision=$actualRevision;commands=@($commands);entities=$entities;lifecycle=$lifecycle
      quarantine=[pscustomobject]@{classification=[string]$candidate.classification;manifestStagingPath=$manifestStagingPath;manifestTargetPath=$manifestTargetPath;manifestHash=$manifestHash;candidateFingerprint=[string]$candidate.fingerprint;authorityOutboxEventId=if($authority){[string]$authority.outboxEventId}else{''};authorityStateHash=if($authority){[string]$authority.stateHash}else{''}}
      source=Limit-Text $Writer 120;recordedAt=$now
    }
    Add-StateEvent $id $prepare
    if ($FaultPoint -eq 'after_prepare') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_PREPARE' }
    $materialization=@()
    $durableCommit=$false
    try {
    $materialization=@(Invoke-TaskCompletionMaterialization @($commands) $id ([string]$candidate.workspaceKey) $transactionId $FaultAfterMaterialization)
    # Preserve an injected post-materialization interruption for explicit WAL
    # reconciliation. Ordinary validation failures roll files back here.
    if ($FaultPoint -eq 'after_materialize') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZE' }
    if (@(Get-TaskWakeReferences $id @()).Count -gt 0) { throw "TASK_STATE_QUARANTINE_WAKE_REFERENCE_REMAINS taskId=$id" }
    if ((Get-FileSha256 $manifestTargetPath) -ne $manifestHash) { throw "TASK_STATE_QUARANTINE_MANIFEST_HASH_MISMATCH taskId=$id" }
    foreach ($entity in @($candidate.entities | Where-Object { $_.currentExists })) { if (Test-Path -LiteralPath $entity.currentPath -PathType Leaf) { throw "TASK_STATE_QUARANTINE_SOURCE_REMAINS kind=$($entity.kind) taskId=$id" } }
     $eventId=[guid]::NewGuid().ToString('n')
    $committedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $commit=[pscustomobject]@{schema='super-brain.task-state-event.v2';phase='committed';transactionKind='task_quarantine';transactionId=$transactionId;authorityOutboxEventId=if($authority){[string]$authority.outboxEventId}else{''};authorityStateHash=if($authority){[string]$authority.stateHash}else{''};eventId=$eventId;taskId=$id;revision=$nextRevision;previousRevision=$actualRevision;entities=$entities;lifecycle=$lifecycle;quarantine=$prepare.quarantine;source=Limit-Text $Writer 120;recordedAt=$committedAt;materialization=@($materialization)}
     Add-StateEvent $id $commit
     $durableCommit=$true
    Commit-TaskCompletionProjection $projection $id $entities $lifecycle $nextRevision $eventId $committedAt
    if($authority){$authorityAck=Acknowledge-TaskAuthorityOutbox ([string]$authority.outboxEventId);if(-not$authorityAck.ok-or[int]$authorityAck.materialized-ne1){throw'TASK_STATE_SQLITE_AUTHORITY_OUTBOX_ACK_FAILED'}}
     Remove-TaskCompletionStaging @($commands) $manifestStagingPath $materialization
     return [pscustomobject]@{ok=$true;taskId=$id;classification=$candidate.classification;revision=$nextRevision;previousRevision=$actualRevision;transactionId=$transactionId;manifestPath=$manifestTargetPath;manifestHash=$manifestHash;sourceCount=$candidate.sourceCount;wakeReferenceCount=0;lifecycleStatus='quarantined'}
    } catch {
      $originalError=$_.Exception.Message
      $preserveForRecovery=($FaultPoint -eq 'after_materialize' -or (Test-TaskStateMaterializationFaultInjected $originalError))
      $rollback=if(-not$durableCommit -and -not$preserveForRecovery){Restore-TaskMaterializationSafely $materialization}else{[pscustomobject]@{attempted=$false;verified=$false;error=if($durableCommit){'durable_commit_present'}else{'fault_injection_preserved'}}}
      if($rollback.attempted-and-not$rollback.verified){throw "TASK_STATE_QUARANTINE_ROLLBACK_FAILED error=$($rollback.error) original=$originalError"}
      throw
    }
  }
}

function Complete-PreparedTaskQuarantine([object]$Prepare) {
  $id=[string]$Prepare.taskId
  $projection=Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
  $actualRevision=[int]$projection.revision
  if ($actualRevision -ne [int]$Prepare.previousRevision -or [int]$Prepare.targetRevision -ne ($actualRevision+1)) { return [pscustomobject]@{ok=$false;reason='revision_advanced';taskId=$id;transactionId=$Prepare.transactionId} }
  $materialization=@()
  $durableCommit=$false
  try {
    $materialization=@(Invoke-TaskCompletionMaterialization @($Prepare.commands) $id ([string]$Prepare.lifecycle.workspaceKey) ([string]$Prepare.transactionId) 0)
    if (@(Get-TaskWakeReferences $id @()).Count -gt 0) { throw 'TASK_STATE_QUARANTINE_WAKE_REFERENCE_REMAINS' }
    if ((Get-FileSha256 ([string]$Prepare.quarantine.manifestTargetPath)) -ne [string]$Prepare.quarantine.manifestHash) { throw 'TASK_STATE_QUARANTINE_MANIFEST_HASH_MISMATCH' }
    $eventId=[guid]::NewGuid().ToString('n')
    $now=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $commit=[pscustomobject]@{schema='super-brain.task-state-event.v2';phase='committed';transactionKind='task_quarantine';transactionId=[string]$Prepare.transactionId;authorityOutboxEventId=if($Prepare.quarantine){[string]$Prepare.quarantine.authorityOutboxEventId}else{''};authorityStateHash=if($Prepare.quarantine){[string]$Prepare.quarantine.authorityStateHash}else{''};eventId=$eventId;taskId=$id;revision=$actualRevision+1;previousRevision=$actualRevision;entities=$Prepare.entities;lifecycle=$Prepare.lifecycle;quarantine=$Prepare.quarantine;source=Limit-Text ([string]$Prepare.source) 120;recordedAt=$now;recovered=$true;materialization=@($materialization)}
    Add-StateEvent $id $commit
    $durableCommit=$true
    Commit-TaskCompletionProjection $projection $id $Prepare.entities $Prepare.lifecycle ($actualRevision+1) $eventId $now
    if($Prepare.quarantine-and-not[string]::IsNullOrWhiteSpace([string]$Prepare.quarantine.authorityOutboxEventId)){$authorityAck=Acknowledge-TaskAuthorityOutbox ([string]$Prepare.quarantine.authorityOutboxEventId);if(-not$authorityAck.ok-or[int]$authorityAck.materialized-ne1){throw'TASK_STATE_AUTHORITY_OUTBOX_ACK_FAILED'}}
    Remove-TaskCompletionStaging @($Prepare.commands) ([string]$Prepare.quarantine.manifestStagingPath) $materialization
    return [pscustomobject]@{ok=$true;taskId=$id;transactionId=$Prepare.transactionId;revision=$actualRevision+1;recovered=$true;lifecycleStatus='quarantined'}
  } catch {
    $rollback = if (-not $durableCommit) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error='durable_commit_present' } }
    return [pscustomobject]@{ok=$false;reason='materialization_failed';error=$_.Exception.Message;taskId=$id;transactionId=$Prepare.transactionId;rollback=$rollback;durableCommit=$durableCommit}
  }
}

function Get-Projection([string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
  $projection = Read-JsonFile (Get-ProjectionPath $Id)
  if ($projection -and $projection.PSObject.Properties['taskId'] -and [string]$projection.taskId -ne $Id) { throw "TASK_STATE_IDENTITY_MISMATCH expected=$Id actual=$($projection.taskId)" }
  return $projection
}

function Read-Events {
  $streams = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $eventRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $fileEvents=@()
    foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $fileEvents += ($line | ConvertFrom-Json) } catch { throw "TASK_STATE_EVENT_INVALID path=$($file.FullName)" }
    }
    $taskIds=@($fileEvents|ForEach-Object{[string]$_.taskId}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Select-Object -Unique)
    if($taskIds.Count-ne1){throw "TASK_STATE_EVENT_STREAM_IDENTITY_INVALID path=$($file.FullName)"}
    $id=$taskIds[0]
    $canonicalPath=Get-EventPath $id
    $streams += [pscustomobject]@{taskId=$id;path=$file.FullName;canonical=[string]::Equals($file.FullName,$canonicalPath,[StringComparison]::OrdinalIgnoreCase);lastWriteTimeUtc=$file.LastWriteTimeUtc;events=@($fileEvents)}
  }
  $events=@()
  foreach($group in @($streams|Group-Object taskId)){
    $canonical=@($group.Group|Where-Object{$_.canonical}|Sort-Object LastWriteTimeUtc -Descending)
    $selected=if($canonical.Count-gt0){$canonical[0]}else{@($group.Group|Sort-Object LastWriteTimeUtc -Descending)[0]}
    $events += @($selected.events)
  }
  return @($events)
}

function Get-IncompleteTransactions([object[]]$Events) {
  $terminal = @{}
  foreach ($event in @($Events)) {
    $phase = if ($event.PSObject.Properties['phase']) { [string]$event.phase } else { 'committed' }
    $transactionId = if ($event.PSObject.Properties['transactionId']) { [string]$event.transactionId } else { '' }
    if ($transactionId -and $phase -in @('committed','aborted')) { $terminal[$transactionId] = $true }
  }
  return @($Events | Where-Object { $_.PSObject.Properties['phase'] -and [string]$_.phase -eq 'prepared' -and -not $terminal.ContainsKey([string]$_.transactionId) })
}

function ConvertTo-ProjectionParityValue([object]$Value,[string[]]$IgnoreProperties=@()) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [System.ValueType]) { return $Value }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = [ordered]@{}
    foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
      if ($IgnoreProperties -contains $key) { continue }
      $copy[$key] = ConvertTo-ProjectionParityValue $Value[$key] $IgnoreProperties
    }
    return [pscustomobject]$copy
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = New-Object System.Collections.ArrayList
    foreach ($item in $Value) { [void]$items.Add((ConvertTo-ProjectionParityValue $item $IgnoreProperties)) }
    return ,($items.ToArray())
  }
  $copy = [ordered]@{}
  foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
    if ($IgnoreProperties -contains [string]$property.Name) { continue }
    $copy[[string]$property.Name] = ConvertTo-ProjectionParityValue $property.Value $IgnoreProperties
  }
  return [pscustomobject]$copy
}

function Get-ProjectionParityFingerprint([object]$Projection,[string]$Id) {
  $projection = Ensure-ProjectionShape $Projection $Id
  $value = [ordered]@{
    taskId = [string]$projection.taskId
    entities = ConvertTo-ProjectionParityValue $projection.entities @('source')
    lifecycle = ConvertTo-ProjectionParityValue $projection.lifecycle @('source')
  }
  return ($value | ConvertTo-Json -Depth 16 -Compress)
}

function Get-ProjectionParity([object[]]$Events,[string]$OnlyTaskId='',[switch]$SkipIndex) {
  $selectedEvents = @($Events)
  if (-not [string]::IsNullOrWhiteSpace($OnlyTaskId)) { $selectedEvents = @($selectedEvents | Where-Object { [string]$_.taskId -eq $OnlyTaskId }) }
  $rebuilt = Build-ProjectionsFromEvents $selectedEvents
  $projectionGaps = @()
  foreach ($id in @($rebuilt.Keys | Sort-Object)) {
    $expected = Ensure-ProjectionShape $rebuilt[$id] $id
    $path = Get-ProjectionPath $id
    $actualRaw = Read-JsonFile $path
    if (-not $actualRaw) {
      $projectionGaps += [pscustomobject]@{ taskId=$id; classification='committed_wal_projection_lag'; reason=if(Test-Path -LiteralPath $path -PathType Leaf){'projection_invalid'}else{'projection_missing'}; projectionPath=$path; expectedRevision=[int]$expected.revision; actualRevision=-1; expectedLastEventId=[string]$expected.lastEventId; actualLastEventId='' }
      continue
    }
    try { $actual = Ensure-ProjectionShape $actualRaw $id } catch {
      $projectionGaps += [pscustomobject]@{ taskId=$id; classification='committed_wal_projection_lag'; reason='projection_identity_invalid'; projectionPath=$path; expectedRevision=[int]$expected.revision; actualRevision=-1; expectedLastEventId=[string]$expected.lastEventId; actualLastEventId='' }
      continue
    }
    $actualRevision = [int]$actual.revision
    $expectedRevision = [int]$expected.revision
    if ($actualRevision -ne $expectedRevision) {
      $projectionGaps += [pscustomobject]@{ taskId=$id; classification=if($actualRevision -lt $expectedRevision){'committed_wal_projection_lag'}else{'projection_revision_mismatch'}; reason='projection_revision_mismatch'; projectionPath=$path; expectedRevision=$expectedRevision; actualRevision=$actualRevision; expectedLastEventId=[string]$expected.lastEventId; actualLastEventId=[string]$actual.lastEventId }
      continue
    }
    if ([string]$actual.lastEventId -ne [string]$expected.lastEventId) {
      $projectionGaps += [pscustomobject]@{ taskId=$id; classification='projection_last_event_mismatch'; reason='projection_last_event_mismatch'; projectionPath=$path; expectedRevision=$expectedRevision; actualRevision=$actualRevision; expectedLastEventId=[string]$expected.lastEventId; actualLastEventId=[string]$actual.lastEventId }
      continue
    }
    if ((Get-ProjectionParityFingerprint $actual $id) -ne (Get-ProjectionParityFingerprint $expected $id)) {
      $projectionGaps += [pscustomobject]@{ taskId=$id; classification='projection_content_mismatch'; reason='projection_content_mismatch'; projectionPath=$path; expectedRevision=$expectedRevision; actualRevision=$actualRevision; expectedLastEventId=[string]$expected.lastEventId; actualLastEventId=[string]$actual.lastEventId }
    }
  }

  $indexGaps = @()
  if (-not $SkipIndex -and [string]::IsNullOrWhiteSpace($OnlyTaskId)) {
    $index = Read-JsonFile $indexPath
    $expectedIndexCount = [Math]::Min($rebuilt.Keys.Count,500)
    if (-not $index) {
      if ($expectedIndexCount -gt 0) { $indexGaps += [pscustomobject]@{ classification='index_missing'; reason='index_missing'; taskId=''; indexPath=$indexPath } }
    } else {
      $entries = @($index.tasks)
      if ([int]$index.taskCount -ne $expectedIndexCount -or $entries.Count -ne $expectedIndexCount) {
        $indexGaps += [pscustomobject]@{ classification='index_count_mismatch'; reason='index_count_mismatch'; taskId=''; indexPath=$indexPath; expectedCount=$expectedIndexCount; actualTaskCount=[int]$index.taskCount; actualEntryCount=$entries.Count }
      }
      $entriesById = @{}
      foreach ($entry in $entries) {
        $entryId = [string]$entry.taskId
        if ([string]::IsNullOrWhiteSpace($entryId) -or $entriesById.ContainsKey($entryId)) {
          $indexGaps += [pscustomobject]@{ classification='index_entry_invalid'; reason='index_entry_invalid'; taskId=$entryId; indexPath=$indexPath }
          continue
        }
        $entriesById[$entryId] = $entry
        if (-not $rebuilt.ContainsKey($entryId)) {
          $indexGaps += [pscustomobject]@{ classification='index_entry_unbacked'; reason='index_entry_unbacked'; taskId=$entryId; indexPath=$indexPath }
          continue
        }
        $summary = New-IndexSummary $rebuilt[$entryId]
        $entryKinds = @($entry.entityKinds | ForEach-Object { [string]$_ } | Sort-Object)
        $summaryKinds = @($summary.entityKinds | ForEach-Object { [string]$_ } | Sort-Object)
        if ([int]$entry.revision -ne [int]$summary.revision -or -not [string]::Equals([string]$entry.projectionPath,[string]$summary.projectionPath,[StringComparison]::OrdinalIgnoreCase) -or (($entryKinds -join '|') -ne ($summaryKinds -join '|'))) {
          $indexGaps += [pscustomobject]@{ classification='index_entry_mismatch'; reason='index_entry_mismatch'; taskId=$entryId; indexPath=$indexPath; expectedRevision=[int]$summary.revision; actualRevision=[int]$entry.revision }
        }
      }
      if ($expectedIndexCount -eq $rebuilt.Keys.Count) {
        foreach ($id in @($rebuilt.Keys | Sort-Object)) {
          if (-not $entriesById.ContainsKey($id)) { $indexGaps += [pscustomobject]@{ classification='index_entry_missing'; reason='index_entry_missing'; taskId=$id; indexPath=$indexPath } }
        }
      }
    }
  }
  $committedLagTaskIds = @($projectionGaps | Where-Object { [string]$_.classification -eq 'committed_wal_projection_lag' } | ForEach-Object { [string]$_.taskId } | Select-Object -Unique)
  return [pscustomobject]@{
    ok = ($projectionGaps.Count -eq 0 -and $indexGaps.Count -eq 0)
    expectedProjectionCount = $rebuilt.Keys.Count
    projectionGapCount = $projectionGaps.Count
    indexGapCount = $indexGaps.Count
    committedProjectionLagCount = $committedLagTaskIds.Count
    committedProjectionLagTaskIds = @($committedLagTaskIds)
    projectionGaps = @($projectionGaps)
    indexGaps = @($indexGaps)
  }
}

function Get-ProjectionOwner([object]$Projection,[string]$PreferredKind) {
  foreach ($kind in @($PreferredKind,'task_card','checkpoint','context') | Select-Object -Unique) {
    $entity = Get-EntityValue $Projection $kind
    if ($entity -and $entity.PSObject.Properties['owner']) { return $entity.owner }
  }
  return $null
}

function Test-SameOwner([object]$Left,[object]$Right) {
  if (-not $Left -or -not $Right) { return $false }
  if ([string]::IsNullOrWhiteSpace([string]$Left.sessionId) -or [string]::IsNullOrWhiteSpace([string]$Right.sessionId)) { return $false }
  if ([string]$Left.sessionId -ne [string]$Right.sessionId) { return $false }
  if ($Left.agentId -and $Right.agentId -and [string]$Left.agentId -ne [string]$Right.agentId) { return $false }
  if ($Left.workspace -and $Right.workspace -and [string]$Left.workspace -ne [string]$Right.workspace) { return $false }
  return $true
}

function Get-AuditResult {
  $legacyContext = Read-JsonFile (Join-Path $WorkspaceRoot 'current-task-context.json')
  $legacyCheckpoint = Read-JsonFile (Join-Path $WorkspaceRoot 'active-checkpoint.json')
  $scopedContext = Get-SuperBrainCurrentTaskContext $WorkspaceRoot $OwnerWorkspace
  $context = if ($scopedContext) { $scopedContext } else { $legacyContext }
  $workspaceSelector = Get-SuperBrainRelevantCheckpoint $WorkspaceRoot $context $OwnerWorkspace
  $checkpoint = if ($scopedContext -and $workspaceSelector.checkpoint) { $workspaceSelector.checkpoint } else { $legacyCheckpoint }
  $taskGraph = Read-JsonFile (Join-Path $WorkspaceRoot 'task-graph.json')
  $stepLedger = Read-JsonFile (Join-Path $WorkspaceRoot 'step-ledger.json')
  $contextTaskId = if ($context) { [string]$context.taskId } else { '' }
  $checkpointTaskId = if ($checkpoint) { [string]$checkpoint.taskId } else { '' }
  $legacyContextTaskId = if ($legacyContext) { [string]$legacyContext.taskId } else { '' }
  $legacyCheckpointTaskId = if ($legacyCheckpoint) { [string]$legacyCheckpoint.taskId } else { '' }
  $taskGraphTaskId = if ($taskGraph) { [string]$taskGraph.taskId } else { '' }
  $stepLedgerTaskId = if ($stepLedger) { [string]$stepLedger.taskId } else { '' }
  $contextProjection = Get-Projection $contextTaskId
  $checkpointProjection = Get-Projection $checkpointTaskId
  $contextOwner = Get-ProjectionOwner $contextProjection 'context'
  $checkpointOwner = Get-ProjectionOwner $checkpointProjection 'checkpoint'
  $sameOwner = Test-SameOwner $contextOwner $checkpointOwner
  $consistency = 'empty'
  if ($contextTaskId -or $checkpointTaskId) { $consistency = 'partial' }
  if ($contextTaskId -and $checkpointTaskId) {
    if ($contextTaskId -eq $checkpointTaskId) { $consistency = 'consistent' }
    elseif ($contextProjection -and $checkpointProjection -and -not $sameOwner) { $consistency = 'parallel' }
    else { $consistency = 'conflict' }
  }
  $missing = @()
  foreach ($id in @($contextTaskId,$checkpointTaskId) | Select-Object -Unique) { if ($id -and -not (Get-Projection $id)) { $missing += $id } }
  $eventFiles = @(Get-ChildItem -LiteralPath $eventRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
  $eventBytes = [long](($eventFiles | Measure-Object Length -Sum).Sum)
  $archiveFiles = @(Get-ChildItem -LiteralPath $archiveRoot -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue)
  $events = @(Read-Events)
  $incomplete = @(Get-IncompleteTransactions $events)
  $projectionParity = Get-ProjectionParity $events
  $index = Read-JsonFile $indexPath
  $compatibilityTaskIds = @($legacyContextTaskId,$legacyCheckpointTaskId,$taskGraphTaskId,$stepLedgerTaskId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  return [pscustomobject]@{
    ok = ($missing.Count -eq 0 -and $incomplete.Count -eq 0 -and $projectionParity.ok)
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    schema = 'super-brain.task-state-audit.v2'
    consistency = $consistency
    pointerMismatch = ($contextTaskId -and $checkpointTaskId -and $contextTaskId -ne $checkpointTaskId)
    sameOwner = $sameOwner
    merged = $false
    authority = 'task_state_store_and_workspace_selector'
    automaticContinuationSafe = (($null -eq $workspaceSelector.checkpoint) -or [string]$workspaceSelector.state -eq 'relevant')
    automaticContinuationTaskId = if($workspaceSelector.checkpoint){[string]$workspaceSelector.checkpoint.taskId}else{''}
    workspaceSelection = [pscustomobject]@{ state=$workspaceSelector.state; contextState=$workspaceSelector.contextState; contextSource=if($scopedContext){'workspace_scoped'}else{'legacy_global'}; source=$workspaceSelector.source; ignoredTaskId=$workspaceSelector.ignoredTaskId }
    contextTaskId = $contextTaskId
    checkpointTaskId = $checkpointTaskId
    conflictingTaskId = if ($consistency -eq 'conflict') { $checkpointTaskId } else { '' }
    parallelTaskIds = if ($consistency -eq 'parallel') { @($contextTaskId,$checkpointTaskId) } else { @() }
    compatibilityPointers = [pscustomobject]@{ contextTaskId=$legacyContextTaskId; checkpointTaskId=$legacyCheckpointTaskId; taskGraphTaskId=$taskGraphTaskId; stepLedgerTaskId=$stepLedgerTaskId; divergent=($compatibilityTaskIds.Count -gt 1); distinctTaskIds=@($compatibilityTaskIds) }
    missingProjectionTaskIds = @($missing)
    incompleteTransactionCount = $incomplete.Count
    incompleteTransactions = @($incomplete | ForEach-Object { [pscustomobject]@{ taskId=$_.taskId; transactionId=$_.transactionId; entityKind=$_.entityKind; operation=$_.operation; targetRevision=$_.targetRevision } })
    projectionParity = $projectionParity
    projectionParityGapCount = [int]$projectionParity.projectionGapCount
    indexParityGapCount = [int]$projectionParity.indexGapCount
    committedProjectionLagCount = [int]$projectionParity.committedProjectionLagCount
    committedProjectionLagTaskIds = @($projectionParity.committedProjectionLagTaskIds)
    taskCount = if ($index) { [int]$index.taskCount } else { 0 }
    eventFileCount = $eventFiles.Count
    eventBytes = $eventBytes
    archiveFileCount = $archiveFiles.Count
    archiveBytes = [long](($archiveFiles | Measure-Object Length -Sum).Sum)
    journalPressure = if ($eventBytes -gt 10MB) { 'high' } elseif ($eventBytes -gt 5MB) { 'watch' } else { 'ok' }
    storeRoot = $storeRoot
    indexPath = $indexPath
    guard = 'Different task IDs remain separate. Ownership distinguishes same-session conflict from legitimate parallel tasks; no audit path merges state.'
  }
}

function Build-ProjectionsFromEvents([object[]]$Events) {
  $byTask = @{}
  foreach ($event in @($Events)) {
    $phase = if ($event.PSObject.Properties['phase']) { [string]$event.phase } else { 'committed' }
    if ($phase -in @('prepared','aborted')) { continue }
    $id = [string]$event.taskId
    if ($phase -eq 'snapshot') {
      $byTask[$id] = Ensure-ProjectionShape $event.projection $id
      continue
    }
    if (-not $byTask.ContainsKey($id)) { $byTask[$id] = New-Projection $id }
    $projection = $byTask[$id]
    $expected = [int]$projection.revision + 1
    if ([int]$event.revision -ne $expected -or [int]$event.previousRevision -ne [int]$projection.revision) { throw "TASK_STATE_EVENT_REVISION_GAP taskId=$id expected=$expected actual=$($event.revision)" }
    if ($event.PSObject.Properties['transactionKind'] -and [string]$event.transactionKind -in @('task_completion','task_quarantine','contract_continuity','active_task_bundle','entity_commit','projection_path_rebind')) {
      Set-EntityValue $projection 'context' $event.entities.context
      Set-EntityValue $projection 'checkpoint' $event.entities.checkpoint
      Set-EntityValue $projection 'task_card' $event.entities.task_card
      $projection.lifecycle = $event.lifecycle
    } else {
      Set-EntityValue $projection ([string]$event.entityKind) $event.entity
      $null = Update-ProjectionLifecycleFromEntities $projection 'event-rebuild'
    }
    $projection.revision = [int]$event.revision
    $projection.updatedAt = [string]$event.recordedAt
    $projection.lastEventId = [string]$event.eventId
  }
  return $byTask
}

function New-TaskAuthoritySnapshotProjection([object]$Snapshot,[string]$EventId,[string]$When) {
  $payload = $Snapshot.payload
  $envelope = if ($payload -and $payload.PSObject.Properties['projection']) { $payload.projection } else { $null }
  if (-not $payload -or -not $envelope -or [string]$envelope.schema -ne 'super-brain.task-projection.v1') { throw 'TASK_STATE_SQLITE_AUTHORITY_SNAPSHOT_INVALID' }
  $id = [string]$payload.taskId
  if ([string]::IsNullOrWhiteSpace($id) -or [int]$payload.revision -lt 1 -or -not $envelope.entities -or -not $envelope.lifecycle) { throw 'TASK_STATE_SQLITE_AUTHORITY_SNAPSHOT_INVALID' }
  $projection = New-Projection $id
  $projection.entities = $envelope.entities | ConvertTo-Json -Depth 24 | ConvertFrom-Json
  $projection.lifecycle = $envelope.lifecycle | ConvertTo-Json -Depth 24 | ConvertFrom-Json
  $projection.revision = [int]$payload.revision
  $projection.updatedAt = $When
  $projection.lastEventId = $EventId
  return $projection
}

function Get-TaskAuthoritySnapshotRestorePlan([object[]]$Events) {
  $fromEvents = Build-ProjectionsFromEvents $Events
  $restorable = @()
  $conflicts = @()
  foreach ($snapshot in @(Get-TaskAuthorityProjectionSnapshots)) {
    try {
      $payload = $snapshot.payload
      $envelope = if ($payload -and $payload.PSObject.Properties['projection']) { $payload.projection } else { $null }
      if (-not $payload -or -not $envelope -or [string]$envelope.schema -ne 'super-brain.task-projection.v1') { continue }
      $id = [string]$payload.taskId
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      if ([string]$snapshot.status -ne 'materialized') {
        $conflicts += [pscustomobject]@{ taskId=$id; fileRevision=if($fromEvents.ContainsKey($id)){[int]$fromEvents[$id].revision}else{-1}; authorityRevision=[int]$payload.revision; stateHash=[string]$payload.stateHash; reason='authority_snapshot_not_materialized' }
        continue
      }
      if (-not $fromEvents.ContainsKey($id)) {
        $restorable += [pscustomobject]@{ snapshot=$snapshot; taskId=$id; revision=[int]$payload.revision; stateHash=[string]$payload.stateHash }
        continue
      }
      $fileProjection = Ensure-ProjectionShape $fromEvents[$id] $id
      $authorityProjection = New-TaskAuthoritySnapshotProjection $snapshot ([string]$fileProjection.lastEventId) ([string]$fileProjection.updatedAt)
      if ([int]$fileProjection.revision -ne [int]$authorityProjection.revision -or -not (Test-TaskAuthorityProjectionParity $fileProjection $envelope ([int]$authorityProjection.revision))) {
        $conflicts += [pscustomobject]@{ taskId=$id; fileRevision=[int]$fileProjection.revision; authorityRevision=[int]$authorityProjection.revision; stateHash=[string]$payload.stateHash; reason='file_projection_differs_from_sqlite_authority' }
      }
    } catch {
      $conflicts += [pscustomobject]@{ taskId=if($snapshot -and $snapshot.payload){[string]$snapshot.payload.taskId}else{''}; fileRevision=-1; authorityRevision=if($snapshot){[int]$snapshot.revision}else{-1}; stateHash=''; reason='authority_snapshot_invalid'; error=$_.Exception.Message }
    }
  }
  return [pscustomobject]@{ restorable=@($restorable); conflicts=@($conflicts); authoritySnapshotCount=@($restorable).Count+@($conflicts).Count; ok=(@($conflicts).Count -eq 0) }
}

function Restore-TaskAuthoritySnapshots([object[]]$Events,[switch]$Write) {
  $plan = Get-TaskAuthoritySnapshotRestorePlan $Events
  if (-not $Write -or -not $plan.ok -or @($plan.restorable).Count -eq 0) { return [pscustomobject]@{ plan=$plan; restored=@(); applied=$false } }
  $restored = @(Invoke-SuperBrainFileLock $mutationGate {
    foreach ($entry in @($plan.restorable)) {
      $eventId = [guid]::NewGuid().ToString('n')
      $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
      $projection = New-TaskAuthoritySnapshotProjection $entry.snapshot $eventId $now
      $event = [pscustomobject]@{
        schema='super-brain.task-state-event.v2'; phase='snapshot'; transactionKind='sqlite_authority_snapshot'; transactionId='sqlite-snapshot-'+([string]$entry.snapshot.eventId)
        authorityOutboxEventId=[string]$entry.snapshot.eventId; authorityStateHash=[string]$entry.stateHash; eventId=$eventId; taskId=[string]$entry.taskId; revision=[int]$entry.revision; previousRevision=0
        projection=$projection; source='task-state-store.ps1:sqlite-authority-rebuild'; recordedAt=$now; recovered=$true
      }
      Add-StateEvent ([string]$entry.taskId) $event | Out-Null
      [pscustomobject]@{ taskId=[string]$entry.taskId; revision=[int]$entry.revision; eventId=$eventId; authorityOutboxEventId=[string]$entry.snapshot.eventId }
    }
  })
  return [pscustomobject]@{ plan=$plan; restored=@($restored); applied=(@($restored).Count -gt 0) }
}

function Rebuild-Store([switch]$Write) {
  $events = @(Read-Events)
  $authorityRestore = Restore-TaskAuthoritySnapshots $events -Write:$Write
  if (-not $authorityRestore.plan.ok) {
    return [pscustomobject]@{ ok=$false; action='Rebuild'; applied=[bool]$Write; eventCount=$events.Count; projectionCount=0; indexPath=$indexPath; projectionParity=$null; authorityParity=$authorityRestore.plan; authorityRestoredCount=0; guard='SQLite authority and file compatibility projection disagree. Rebuild is withheld until the task is reconciled; neither side is silently preferred.' }
  }
  if ($authorityRestore.applied) { $events = @(Read-Events) }
  $projections = Build-ProjectionsFromEvents $events
  if ($Write) {
    Invoke-SuperBrainFileLock $mutationGate {
      foreach ($id in @($projections.Keys | Sort-Object)) { Write-JsonUtf8NoBom (Get-ProjectionPath $id) $projections[$id] 10 }
      $summaries = @($projections.Keys | ForEach-Object { New-IndexSummary $projections[$_] } | Sort-Object updatedAt -Descending | Select-Object -First 500)
      Write-JsonUtf8NoBom $indexPath ([pscustomobject]@{ schema='super-brain.task-state-index.v2'; updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); taskCount=$summaries.Count; maxTasks=500; tasks=$summaries }) 8
    } | Out-Null
  }
  $projectionParity = Get-ProjectionParity @(Read-Events)
  return [pscustomobject]@{ ok=$projectionParity.ok; action='Rebuild'; applied=[bool]$Write; eventCount=$events.Count; projectionCount=$projections.Count; indexPath=$indexPath; projectionParity=$projectionParity; authorityParity=$authorityRestore.plan; authorityRestoredCount=@($authorityRestore.restored).Count; guard=if($Write){'Projection and index rebuilt from file compatibility events plus verified SQLite authority snapshots.'}else{'Dry run only; use -Apply to write rebuilt projections; authority conflicts are reported without choosing a side.'} }
}

function Complete-PreparedTransaction([object]$Prepare) {
  if ($Prepare.PSObject.Properties['transactionKind'] -and [string]$Prepare.transactionKind -eq 'task_completion') { return Complete-PreparedTaskCompletion $Prepare }
  if ($Prepare.PSObject.Properties['transactionKind'] -and [string]$Prepare.transactionKind -eq 'task_quarantine') { return Complete-PreparedTaskQuarantine $Prepare }
  if ($Prepare.PSObject.Properties['transactionKind'] -and [string]$Prepare.transactionKind -eq 'contract_continuity') { return Complete-PreparedContractContinuity $Prepare }
  if ($Prepare.PSObject.Properties['transactionKind'] -and [string]$Prepare.transactionKind -eq 'active_task_bundle') { return Complete-PreparedActiveTaskBundle $Prepare }
  if ($Prepare.PSObject.Properties['transactionKind'] -and [string]$Prepare.transactionKind -eq 'projection_path_rebind') { return Complete-PreparedProjectionPathRebind $Prepare }
  $id = [string]$Prepare.taskId
  $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
  $actualRevision = [int]$projection.revision
  if ($actualRevision -ne [int]$Prepare.previousRevision -or [int]$Prepare.targetRevision -ne ($actualRevision + 1)) { return [pscustomobject]@{ ok=$false; reason='revision_advanced'; taskId=$id; transactionId=$Prepare.transactionId } }
  $command = $Prepare.command
  $target = Assert-EntityTarget ([string]$Prepare.entityKind) ([string]$command.targetPath) $id
  $op = [string]$Prepare.operation
  $expectedTargetHash = if ($command.PSObject.Properties['expectedTargetHash']) { [string]$command.expectedTargetHash } else { '' }
  $currentTargetHash = Get-FileSha256 $target
  # Recovery must honor the target observation captured before the prepared
  # transaction.  A different current hash may be a legitimate already-
  # materialized result, but any other drift belongs to explicit reconciliation
  # and must never be overwritten by replay.
  $targetMatchesExpected = if ([string]::IsNullOrWhiteSpace($expectedTargetHash)) {
    [string]::IsNullOrWhiteSpace($currentTargetHash)
  } else {
    [string]::Equals($currentTargetHash,$expectedTargetHash,[StringComparison]::OrdinalIgnoreCase)
  }
  $alreadyMaterialized = ([string]$op -eq 'upsert' -and [string]::Equals($currentTargetHash,[string]$command.payloadHash,[StringComparison]::OrdinalIgnoreCase))
  if (-not $targetMatchesExpected -and -not $alreadyMaterialized) {
    return [pscustomobject]@{ ok=$false; reason='target_changed_after_prepare'; taskId=$id; transactionId=$Prepare.transactionId; path=$target; expectedTargetHash=$expectedTargetHash; actualTargetHash=$currentTargetHash }
  }
  if ($op -eq 'upsert' -or -not [string]::IsNullOrWhiteSpace([string]$command.payloadPath)) {
    $targetHash = $currentTargetHash
    if ($targetHash -ne [string]$command.payloadHash) {
      if (-not (Test-Path -LiteralPath $command.payloadPath -PathType Leaf) -or (Get-FileSha256 $command.payloadPath) -ne [string]$command.payloadHash) { return [pscustomobject]@{ ok=$false; reason='payload_missing_or_changed'; taskId=$id; transactionId=$Prepare.transactionId } }
      $targetHash = Materialize-Payload ([string]$command.payloadPath) $target ([string]$Prepare.transactionId)
    }
  } else {
    if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }
    $targetHash = ''
  }
  $eventId = [guid]::NewGuid().ToString('n')
  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  $entityRecord = if ($op -eq 'clear') { $null } else { [pscustomobject]@{ path=$target; hash=$targetHash; status=[string]$command.status; source=Limit-Text ([string]$Prepare.source) 120; owner=$command.owner } }
  $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionId=[string]$Prepare.transactionId; eventId=$eventId; taskId=$id; revision=$actualRevision+1; previousRevision=$actualRevision; entityKind=[string]$Prepare.entityKind; operation=$op; entity=$entityRecord; maintenance=if($command.PSObject.Properties['maintenance']){$command.maintenance}else{$null}; source=Limit-Text ([string]$Prepare.source) 120; recordedAt=$now; recovered=$true }
  Add-StateEvent $id $commit
  Commit-Projection $projection $id ([string]$Prepare.entityKind) $op $entityRecord ($actualRevision+1) $eventId $now
  if ($Prepare.PSObject.Properties['authorityOutboxEventId'] -and -not [string]::IsNullOrWhiteSpace([string]$Prepare.authorityOutboxEventId)) {
    $authorityAck = Acknowledge-TaskAuthorityOutbox ([string]$Prepare.authorityOutboxEventId)
    if (-not $authorityAck.ok -or [int]$authorityAck.materialized -ne 1) { return [pscustomobject]@{ ok=$false; reason='authority_outbox_ack_failed'; taskId=$id; transactionId=$Prepare.transactionId } }
  }
  Remove-StagingPayload ([string]$command.payloadPath)
  return [pscustomobject]@{ ok=$true; taskId=$id; transactionId=$Prepare.transactionId; revision=$actualRevision+1 }
}

function Test-TaskAuthorityProjectionParity([object]$Projection,[object]$Envelope,[int]$TargetRevision) {
  if (-not $Projection -or -not $Envelope -or [int]$Projection.revision -ne $TargetRevision) { return $false }
  foreach ($kind in @('context','checkpoint','task_card')) {
    $projected = Get-EntityValue $Projection $kind
    $expected = if ($Envelope.entities -and $Envelope.entities.PSObject.Properties[$kind]) { $Envelope.entities.$kind } else { $null }
    if (($null -eq $projected) -xor ($null -eq $expected)) { return $false }
    if ($null -eq $expected) { continue }
    foreach ($field in @('path','hash','status')) {
      if (-not [string]::Equals([string]$projected.$field,[string]$expected.$field,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
  }
  foreach ($field in @('status','workspaceKey','ownerSessionKey','planFingerprint','contractRevision','completionTransactionId','quarantineTransactionId')) {
    $actual = if ($Projection.lifecycle -and $Projection.lifecycle.PSObject.Properties[$field]) { [string]$Projection.lifecycle.$field } else { '' }
    $expected = if ($Envelope.lifecycle -and $Envelope.lifecycle.PSObject.Properties[$field]) { [string]$Envelope.lifecycle.$field } else { '' }
    if (-not [string]::Equals($actual,$expected,[StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
}

function Convert-TaskAuthorityOutboxCommand([object]$Command,[string]$Id,[string]$WorkspaceKey,[string]$TransactionId,[int]$Index) {
  if (-not $Command) { throw 'TASK_STATE_SQLITE_AUTHORITY_COMMAND_INVALID' }
  $copy = [ordered]@{}
  foreach ($property in @($Command.PSObject.Properties)) {
    if ([string]$property.Name -in @('payload','payloadText','payloadCanonicalHash','payloadPath')) { continue }
    $copy[[string]$property.Name] = $property.Value
  }
  $target = Assert-CompletionCommandTarget $Command $Id $WorkspaceKey
  $desiredHash = ([string]$Command.payloadHash).ToLowerInvariant()
  $payloadPath = ''
  if (-not [string]::IsNullOrWhiteSpace($desiredHash) -and -not [string]::Equals((Get-FileSha256 $target),$desiredHash,[StringComparison]::OrdinalIgnoreCase)) {
    if ($Command.PSObject.Properties['payloadText'] -and -not [string]::IsNullOrWhiteSpace([string]$Command.payloadText)) {
      $dir = Join-Path $stagingRoot (Get-SuperBrainCanonicalTaskToken $Id)
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      $payloadPath = Join-Path $dir (('sqlite-{0:D3}-{1}.json' -f $Index,(([string]$Command.role -replace '[^A-Za-z0-9._-]+','-').Trim('-'))))
      Write-Utf8NoBom $payloadPath ([string]$Command.payloadText)
    } elseif ($Command.PSObject.Properties['payload'] -and $null -ne $Command.payload) {
      $payloadPath = Write-CompletionStagingValue $Id $TransactionId (('sqlite-outbox-{0:D3}-{1}' -f $Index,[string]$Command.role)) $Command.payload
    } else {
      throw "TASK_STATE_SQLITE_AUTHORITY_PAYLOAD_MISSING role=$($Command.role)"
    }
    if (-not [string]::Equals((Get-FileSha256 $payloadPath),$desiredHash,[StringComparison]::OrdinalIgnoreCase)) {
      throw "TASK_STATE_SQLITE_AUTHORITY_PAYLOAD_HASH_MISMATCH role=$($Command.role)"
    }
  }
  $copy['payloadPath'] = $payloadPath
  return [pscustomobject]$copy
}

function Test-TaskAuthorityMaterializedEntities([object]$Envelope) {
  foreach ($kind in @('context','checkpoint','task_card')) {
    $entity = if ($Envelope.entities -and $Envelope.entities.PSObject.Properties[$kind]) { $Envelope.entities.$kind } else { $null }
    if ($null -eq $entity) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$entity.path) -or [string]::IsNullOrWhiteSpace([string]$entity.hash)) { return $false }
    if (-not [string]::Equals((Get-FileSha256 ([string]$entity.path)),[string]$entity.hash,[StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  return $true
}

function Complete-TaskAuthorityOutbox([object]$Outbox) {
  $payload = if ($Outbox) { $Outbox.payload } else { $null }
  $envelope = if ($payload -and $payload.PSObject.Properties['projection']) { $payload.projection } else { $null }
  if (-not $payload -or [string]$payload.schema -ne 'super-brain.task-projection-outbox.v1') { return [pscustomobject]@{ ok=$false; reason='authority_outbox_invalid' } }
  if (-not $envelope -or [string]$envelope.schema -ne 'super-brain.task-projection.v1') { return [pscustomobject]@{ ok=$false; reason='authority_projection_missing'; eventId=[string]$Outbox.eventId } }
  $id = [string]$payload.taskId
  $workspaceKey = Get-SuperBrainWorkspaceKey ([string]$payload.workspaceKey)
  $targetRevision = [int]$payload.revision
  if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($workspaceKey) -or $targetRevision -lt 1) { return [pscustomobject]@{ ok=$false; reason='authority_projection_scope_invalid'; eventId=[string]$Outbox.eventId } }
  if ([string]$envelope.taskId -ne $id -or -not (Test-SuperBrainWorkspaceKey ([string]$envelope.workspaceKey) $workspaceKey) -or [int]$envelope.taskStateRevision -ne $targetRevision) { return [pscustomobject]@{ ok=$false; reason='authority_projection_binding_mismatch'; taskId=$id; eventId=[string]$Outbox.eventId } }
  $transactionKind = [string]$envelope.transactionKind
  if ($transactionKind -notin @('task_completion','task_quarantine','contract_continuity','active_task_bundle','entity_commit','projection_path_rebind')) { return [pscustomobject]@{ ok=$false; reason='authority_projection_transaction_invalid'; taskId=$id; eventId=[string]$Outbox.eventId } }
  $commands = @($envelope.commands)
  if ($commands.Count -eq 0) { return [pscustomobject]@{ ok=$false; reason='authority_projection_commands_missing'; taskId=$id; eventId=[string]$Outbox.eventId } }
  $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
  $actualRevision = [int]$projection.revision
  if ($actualRevision -gt $targetRevision -or $actualRevision -lt ($targetRevision - 1)) { return [pscustomobject]@{ ok=$false; reason='authority_projection_revision_conflict'; taskId=$id; eventId=[string]$Outbox.eventId; expectedPreviousRevision=$targetRevision-1; actualRevision=$actualRevision } }

  $recoveryEvidence = if ($envelope.PSObject.Properties['recoveryEvidence']) { $envelope.recoveryEvidence } else { $null }
  $transactionId = if ($recoveryEvidence -and -not [string]::IsNullOrWhiteSpace([string]$recoveryEvidence.transactionId)) { [string]$recoveryEvidence.transactionId } else { 'sqlite-' + ([string]$Outbox.eventId -replace '[^A-Za-z0-9._-]+','-') }
  $recoveryCommands = @()
  $materialization = @()
  $durableCommit = $false
  try {
    if ($transactionKind -eq 'task_completion') {
      if (-not $recoveryEvidence) { throw 'TASK_STATE_SQLITE_AUTHORITY_COMPLETION_EVIDENCE_REQUIRED' }
      $verificationPath = [string]$recoveryEvidence.verificationPath
      $verificationHash = [string]$recoveryEvidence.verificationHash
      $binding = $recoveryEvidence.evidenceBinding
      if ([string]::IsNullOrWhiteSpace($verificationPath) -or [string]::IsNullOrWhiteSpace($verificationHash) -or -not $binding) { throw 'TASK_STATE_SQLITE_AUTHORITY_COMPLETION_EVIDENCE_REQUIRED' }
      if (-not [string]::Equals((Get-FileSha256 $verificationPath),$verificationHash,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$binding.artifactHash,$verificationHash,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_SQLITE_AUTHORITY_COMPLETION_EVIDENCE_CHANGED' }
      $bindingCheck = Test-SuperBrainEvidenceBinding -Binding $binding -TaskId $id -WorkspaceKey $workspaceKey -OwnerSessionKey ([string]$envelope.lifecycle.ownerSessionKey) -ArtifactPath $verificationPath -RequireArtifactHash -Root $Root
      if (-not $bindingCheck.ok) { throw ('TASK_STATE_SQLITE_AUTHORITY_COMPLETION_EVIDENCE_' + [string]$bindingCheck.reason) }
      foreach ($result in @($recoveryEvidence.decisionBinding.results)) {
        if ([string]::IsNullOrWhiteSpace([string]$result.resultPath) -or -not [string]::Equals((Get-FileSha256 ([string]$result.resultPath)),[string]$result.resultHash,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_SQLITE_AUTHORITY_COMPLETION_DECISION_RESULT_CHANGED' }
      }
    }
    $index = 0
    foreach ($command in $commands) { $index++; $recoveryCommands += Convert-TaskAuthorityOutboxCommand $command $id $workspaceKey $transactionId $index }
    $materialization = @(Invoke-TaskCompletionMaterialization $recoveryCommands $id $workspaceKey $transactionId 0)
    if (-not (Test-TaskAuthorityMaterializedEntities $envelope)) { throw 'TASK_STATE_SQLITE_AUTHORITY_ENTITY_HASH_MISMATCH' }
    if ($transactionKind -eq 'task_completion') {
      if (@(Get-TaskCompletionActiveRecords $id $workspaceKey).Count -gt 0) { throw 'TASK_STATE_SQLITE_AUTHORITY_COMPLETION_ACTIVE_STATE_REMAINS' }
      if ($recoveryEvidence.receiptRequired -eq $true -and -not [string]::Equals((Get-FileSha256 ([string]$recoveryEvidence.completionReceiptPath)),[string]$recoveryEvidence.completionReceiptHash,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_SQLITE_AUTHORITY_COMPLETION_RECEIPT_CHANGED' }
    }
    if ($transactionKind -eq 'task_quarantine') {
      if (-not $recoveryEvidence -or [string]::IsNullOrWhiteSpace([string]$recoveryEvidence.manifestTargetPath) -or [string]::IsNullOrWhiteSpace([string]$recoveryEvidence.manifestHash)) { throw 'TASK_STATE_SQLITE_AUTHORITY_QUARANTINE_EVIDENCE_REQUIRED' }
      if (@(Get-TaskWakeReferences $id @()).Count -gt 0) { throw 'TASK_STATE_SQLITE_AUTHORITY_QUARANTINE_WAKE_REFERENCE_REMAINS' }
      if (-not [string]::Equals((Get-FileSha256 ([string]$recoveryEvidence.manifestTargetPath)),[string]$recoveryEvidence.manifestHash,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_SQLITE_AUTHORITY_QUARANTINE_MANIFEST_CHANGED' }
    }

    $events = @(Read-Events)
    $existing = @($events | Where-Object {
      [string]$_.taskId -eq $id -and [int]$_.revision -eq $targetRevision -and
      $(if($_.PSObject.Properties['phase']){[string]$_.phase}else{'committed'}) -eq 'committed'
    })
    if ($existing.Count -gt 1) { throw 'TASK_STATE_SQLITE_AUTHORITY_EVENT_AMBIGUOUS' }
    $event = if ($existing.Count -eq 1) { $existing[0] } else { $null }
    if (-not $event) {
      $event = [pscustomobject]@{
        schema='super-brain.task-state-event.v2'; phase='committed'; transactionKind=$transactionKind; transactionId=$transactionId; authorityOutboxEventId=[string]$Outbox.eventId; authorityStateHash=[string]$payload.stateHash
        eventId=[guid]::NewGuid().ToString('n'); taskId=$id; revision=$targetRevision; previousRevision=$targetRevision-1; entities=$envelope.entities; lifecycle=$envelope.lifecycle; source='task-state-store.ps1:sqlite-outbox-recovery'; recordedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'); recovered=$true; materialization=@($materialization)
      }
      Add-StateEvent $id $event
    }
    # Whether the event was newly appended or already present from an earlier
    # replay, the durable journal is now the source of truth.  Any later
    # projection/ack failure must be repaired from it rather than rolling files
    # back behind a committed event.
    $durableCommit = $true
    if (-not (Test-TaskAuthorityProjectionParity $projection $envelope $targetRevision)) {
      Commit-TaskCompletionProjection $projection $id $envelope.entities $envelope.lifecycle $targetRevision ([string]$event.eventId) ([string]$event.recordedAt)
      $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
    }
    if (-not (Test-TaskAuthorityProjectionParity $projection $envelope $targetRevision)) { throw 'TASK_STATE_SQLITE_AUTHORITY_PROJECTION_PARITY_FAILED' }
    $ack = Acknowledge-TaskAuthorityOutbox ([string]$Outbox.eventId)
    if (-not $ack.ok -or [int]$ack.materialized -ne 1) { throw 'TASK_STATE_SQLITE_AUTHORITY_OUTBOX_ACK_FAILED' }
    foreach ($command in $recoveryCommands) { Remove-StagingPayload ([string]$command.payloadPath) }
    return [pscustomobject]@{ ok=$true; taskId=$id; eventId=[string]$Outbox.eventId; revision=$targetRevision; transactionKind=$transactionKind; recovered=$true }
  } catch {
    $rollback = if (-not $durableCommit) { Restore-TaskMaterializationSafely $materialization } else { [pscustomobject]@{ attempted=$false; verified=$false; error='durable_commit_present' } }
    return [pscustomobject]@{ ok=$false; reason='authority_projection_recovery_failed'; error=$_.Exception.Message; taskId=$id; eventId=[string]$Outbox.eventId; revision=$targetRevision; rollback=$rollback; durableCommit=$durableCommit }
  }
}

function Reconcile-Store([switch]$Write) {
  $events = @(Read-Events)
  $pending = @(Get-IncompleteTransactions $events)
  $authorityPending = @(Get-PendingTaskAuthorityOutbox)
  $beforeParity = Get-ProjectionParity $events
  if (-not $Write) { return [pscustomobject]@{ ok=($pending.Count -eq 0 -and $authorityPending.Count -eq 0 -and $beforeParity.ok); action='Reconcile'; applied=$false; pendingCount=$pending.Count; authorityPendingCount=$authorityPending.Count; recoveredCount=0; blockedCount=0; transactions=@($pending | ForEach-Object { $_.transactionId }); authorityEvents=@($authorityPending | ForEach-Object { $_.eventId }); projectionParity=$beforeParity; committedProjectionLagCount=[int]$beforeParity.committedProjectionLagCount; guard='Dry run only; use -Apply to reconcile prepared file transactions, recover pending SQLite projection outbox events, and rebuild committed projection or index lag.' } }
  $recovered = @()
  $authorityRecovered = @()
  $authorityBlocked = @()
  $blocked = @()
  foreach ($prepare in $pending) {
    $result = Invoke-SuperBrainFileLock $mutationGate { Complete-PreparedTransaction $prepare }
    if ($result.ok) { $recovered += $result } else { $blocked += $result }
  }
  $authorityPending = @(Get-PendingTaskAuthorityOutbox)
  $blockedTaskIds = @($blocked | ForEach-Object { [string]$_.taskId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  foreach ($outbox in $authorityPending) {
    if ([string]$outbox.payload.taskId -in $blockedTaskIds) { continue }
    $result = Invoke-SuperBrainFileLock $mutationGate { Complete-TaskAuthorityOutbox $outbox }
    if ($result.ok) { $authorityRecovered += $result } else { $authorityBlocked += $result; $blocked += $result }
  }
  $rebuild = Rebuild-Store -Write
  $afterParity = $rebuild.projectionParity
  return [pscustomobject]@{ ok=($blocked.Count -eq 0 -and $afterParity.ok); action='Reconcile'; applied=$true; pendingCount=$pending.Count; authorityPendingCount=$authorityPending.Count; recoveredCount=$recovered.Count; authorityRecoveredCount=$authorityRecovered.Count; authorityBlockedCount=$authorityBlocked.Count; blockedCount=$blocked.Count; recovered=@($recovered); authorityRecovered=@($authorityRecovered); authorityBlocked=@($authorityBlocked); blocked=@($blocked); projectionRebuilt=[bool]$rebuild.applied; projectionCount=[int]$rebuild.projectionCount; projectionParityBefore=$beforeParity; projectionParity=$afterParity; committedProjectionLagCount=[int]$beforeParity.committedProjectionLagCount; recoveredCommittedProjectionLagCount=if($afterParity.projectionGapCount -eq 0){[int]$beforeParity.committedProjectionLagCount}else{0}; guard='Reconcile completes prepared file transactions first. A blocked task keeps its SQLite outbox pending; only unblocked tasks may rebuild compatibility projections from the durable outbox before canonical projection parity is reported.' }
}

function Get-LegacyProjectionCandidates([hashtable]$Rebuilt) {
  $candidates=@()
  foreach($file in @(Get-ChildItem -LiteralPath $projectionRoot -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object Name)){
    $value=Read-JsonFile $file.FullName
    if(-not$value-or[string]::IsNullOrWhiteSpace([string]$value.taskId)){continue}
    $id=[string]$value.taskId
    $canonicalPath=Get-ProjectionPath $id
    if([string]::Equals($file.FullName,$canonicalPath,[StringComparison]::OrdinalIgnoreCase)){continue}
    $hasReplay=$Rebuilt.ContainsKey($id)
    $candidates += [pscustomobject]@{taskId=$id;classification=if($hasReplay){'rebuildable_legacy_projection'}else{'lost_projection_authority'};sourcePath=$file.FullName;sourceHash=Get-FileSha256 $file.FullName;sourceRevision=[int]$value.revision;canonicalPath=$canonicalPath;replayRevision=if($hasReplay){[int]$Rebuilt[$id].revision}else{0};applySafe=[bool]$hasReplay}
  }
  return @($candidates)
}

function Get-LegacyEventCandidates {
  $candidates=@()
  foreach($file in @(Get-ChildItem -LiteralPath $eventRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue|Sort-Object Name)){
    $taskIds=@()
    foreach($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)){
      if([string]::IsNullOrWhiteSpace($line)){continue}
      try{$event=$line|ConvertFrom-Json}catch{continue}
      if(-not[string]::IsNullOrWhiteSpace([string]$event.taskId)){$taskIds += [string]$event.taskId}
    }
    $taskIds=@($taskIds|Select-Object -Unique)
    if($taskIds.Count-ne1){continue}
    $id=$taskIds[0]
    $canonicalPath=Get-EventPath $id
    if([string]::Equals($file.FullName,$canonicalPath,[StringComparison]::OrdinalIgnoreCase)){continue}
    $canonicalExists=[IO.File]::Exists($canonicalPath)
    $candidates += [pscustomobject]@{taskId=$id;classification=if($canonicalExists){'legacy_event_shadow'}else{'legacy_event_migration'};sourcePath=$file.FullName;sourceHash=Get-FileSha256 $file.FullName;canonicalPath=$canonicalPath;canonicalExists=$canonicalExists;applySafe=$true}
  }
  return @($candidates)
}

function Reconcile-ResidualState([switch]$Write) {
  $events=@(Read-Events)
  $rebuilt=Build-ProjectionsFromEvents $events
  $candidates=@(Get-LegacyProjectionCandidates $rebuilt)
  $eventCandidates=@(Get-LegacyEventCandidates)
  $safe=@($candidates|Where-Object{$_.applySafe})
  $blocked=@($candidates|Where-Object{-not$_.applySafe})
  if(-not$Write){return [pscustomobject]@{ok=$true;action='ReconcileResiduals';applied=$false;candidateCount=$candidates.Count;safeCount=$safe.Count;blockedCount=$blocked.Count;eventCandidateCount=$eventCandidates.Count;eventMigrateCount=@($eventCandidates|Where-Object{$_.classification-eq'legacy_event_migration'}).Count;eventShadowCount=@($eventCandidates|Where-Object{$_.classification-eq'legacy_event_shadow'}).Count;candidates=@($candidates);eventCandidates=@($eventCandidates);guard='Dry run only. Legacy event streams are migrated to canonical names or quarantined as shadows before projections are rebuilt. Rebuildable legacy projections may then move byte-for-byte into quarantine; lost authority is never inferred or removed.'}}

  $eventResult=Invoke-SuperBrainFileLock $mutationGate {
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $batchRoot=Join-Path (Join-Path $quarantineRoot 'legacy-events') $stamp
    $migrated=@();$quarantined=@();$eventBlocked=@()
    foreach($candidate in $eventCandidates){
      $source=[IO.Path]::GetFullPath([string]$candidate.sourcePath);$canonical=[IO.Path]::GetFullPath([string]$candidate.canonicalPath)
      if(-not[IO.File]::Exists($source)){continue}
      if((Get-FileSha256 $source)-ne[string]$candidate.sourceHash){$eventBlocked += [pscustomobject]@{taskId=$candidate.taskId;classification='event_source_changed_after_preview';sourcePath=$source};continue}
      if([string]$candidate.classification-eq'legacy_event_migration'){
        if([IO.File]::Exists($canonical)){$eventBlocked += [pscustomobject]@{taskId=$candidate.taskId;classification='canonical_event_appeared_after_preview';sourcePath=$source;canonicalPath=$canonical};continue}
        Move-Item -LiteralPath $source -Destination $canonical
        if((Get-FileSha256 $canonical)-ne[string]$candidate.sourceHash){throw "TASK_STATE_EVENT_MIGRATION_HASH_MISMATCH taskId=$($candidate.taskId)"}
        $migrated += [pscustomobject]@{taskId=$candidate.taskId;classification='legacy_event_migrated';sourcePath=$source;sourceHash=$candidate.sourceHash;canonicalPath=$canonical}
      }else{
        if(-not[IO.Directory]::Exists($batchRoot)){New-Item -ItemType Directory -Force -Path $batchRoot|Out-Null}
        $destination=Join-Path $batchRoot ('e-'+(Get-ShortHash ([string]$candidate.taskId))+'-'+(Get-ShortHash $source)+'.jsonl')
        Move-Item -LiteralPath $source -Destination $destination
        if((Get-FileSha256 $destination)-ne[string]$candidate.sourceHash){throw "TASK_STATE_EVENT_QUARANTINE_HASH_MISMATCH taskId=$($candidate.taskId)"}
        $quarantined += [pscustomobject]@{taskId=$candidate.taskId;classification='legacy_event_shadow_quarantined';sourcePath=$source;sourceHash=$candidate.sourceHash;destinationPath=$destination;canonicalPath=$canonical;canonicalHash=Get-FileSha256 $canonical}
      }
    }
    return [pscustomobject]@{migrated=@($migrated);quarantined=@($quarantined);blocked=@($eventBlocked);batchRoot=$batchRoot}
  }
  if(@($eventResult.blocked).Count-gt0){
    if(-not[IO.Directory]::Exists($eventResult.batchRoot)){New-Item -ItemType Directory -Force -Path $eventResult.batchRoot|Out-Null}
    $eventManifestPath=Join-Path $eventResult.batchRoot 'quarantine-manifest.json'
    Write-JsonUtf8NoBom $eventManifestPath ([pscustomobject]@{schema='super-brain.residual-quarantine.v1';createdAt=(Get-Date).ToString('o');source='task-state-store.ps1:ReconcileResiduals';eventMigrations=@($eventResult.migrated);eventQuarantines=@($eventResult.quarantined);moved=@();blocked=@($eventResult.blocked);rawMemoryStored=$false;destructiveDeleteUsed=$false}) 12
    return [pscustomobject]@{ok=$false;action='ReconcileResiduals';applied=$true;candidateCount=$candidates.Count;movedCount=0;eventMigratedCount=@($eventResult.migrated).Count;eventQuarantinedCount=@($eventResult.quarantined).Count;blockedCount=@($eventResult.blocked).Count;blocked=@($eventResult.blocked);manifestPath=$eventManifestPath;guard='Event migration stopped before projection quarantine because one or more source hashes or canonical targets changed.'}
  }
  $null=Rebuild-Store -Write
  $result=Invoke-SuperBrainFileLock $mutationGate {
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $batchRoot=Join-Path (Join-Path $quarantineRoot 'legacy-projections') $stamp
    $moved=@();$applyBlocked=@($blocked)
    foreach($candidate in $safe){
      $source=[IO.Path]::GetFullPath([string]$candidate.sourcePath)
      $canonical=[IO.Path]::GetFullPath([string]$candidate.canonicalPath)
      if(-not[IO.File]::Exists($source)){continue}
      if((Get-FileSha256 $source)-ne[string]$candidate.sourceHash){$applyBlocked += [pscustomobject]@{taskId=$candidate.taskId;classification='source_changed_after_preview';sourcePath=$source;applySafe=$false};continue}
      $canonicalValue=Read-JsonFile $canonical
      if(-not$canonicalValue-or[string]$canonicalValue.taskId-ne[string]$candidate.taskId-or[int]$canonicalValue.revision-ne[int]$candidate.replayRevision){$applyBlocked += [pscustomobject]@{taskId=$candidate.taskId;classification='canonical_rebuild_verification_failed';sourcePath=$source;canonicalPath=$canonical;applySafe=$false};continue}
      if(-not[IO.Directory]::Exists($batchRoot)){New-Item -ItemType Directory -Force -Path $batchRoot|Out-Null}
      $destination=Join-Path $batchRoot ('p-'+(Get-ShortHash ([string]$candidate.taskId))+'-'+(Get-ShortHash $source)+'.json')
      if([IO.File]::Exists($destination)){throw "TASK_STATE_QUARANTINE_DESTINATION_EXISTS path=$destination"}
      Move-Item -LiteralPath $source -Destination $destination
      if((Get-FileSha256 $destination)-ne[string]$candidate.sourceHash){throw "TASK_STATE_QUARANTINE_HASH_MISMATCH taskId=$($candidate.taskId)"}
      $moved += [pscustomobject]@{taskId=$candidate.taskId;classification='legacy_projection_quarantined';sourcePath=$source;sourceHash=$candidate.sourceHash;sourceRevision=[int]$candidate.sourceRevision;destinationPath=$destination;canonicalPath=$canonical;canonicalHash=Get-FileSha256 $canonical;canonicalRevision=[int]$canonicalValue.revision}
    }
    $manifestPath=''
    if($moved.Count-gt0-or$applyBlocked.Count-gt0-or@($eventResult.migrated).Count-gt0-or@($eventResult.quarantined).Count-gt0){
      if(-not[IO.Directory]::Exists($batchRoot)){New-Item -ItemType Directory -Force -Path $batchRoot|Out-Null}
      $manifestPath=Join-Path $batchRoot 'quarantine-manifest.json'
      Write-JsonUtf8NoBom $manifestPath ([pscustomobject]@{schema='super-brain.residual-quarantine.v1';createdAt=(Get-Date).ToString('o');source='task-state-store.ps1:ReconcileResiduals';eventMigrations=@($eventResult.migrated);eventQuarantines=@($eventResult.quarantined);moved=@($moved);blocked=@($applyBlocked);rawMemoryStored=$false;destructiveDeleteUsed=$false}) 12
    }
    return [pscustomobject]@{ok=($applyBlocked.Count-eq0);action='ReconcileResiduals';applied=$true;candidateCount=$candidates.Count;movedCount=$moved.Count;eventMigratedCount=@($eventResult.migrated).Count;eventQuarantinedCount=@($eventResult.quarantined).Count;blockedCount=$applyBlocked.Count;moved=@($moved);eventMigrations=@($eventResult.migrated);eventQuarantines=@($eventResult.quarantined);blocked=@($applyBlocked);manifestPath=$manifestPath;guard='Legacy event streams were canonicalized first; projections were then rebuilt from committed WAL before byte-preserving quarantine. No task identity was merged and no private history was deleted.'}
  }
  return $result
}

function Reconcile-AmbiguousState([switch]$Write) {
  $candidates=@(Get-AmbiguousStateCandidates $TaskId)
  $safe=@($candidates|Where-Object{$_.applySafe})
  $blocked=@($candidates|Where-Object{-not$_.applySafe})
  $completionConflicts=@($candidates|Where-Object{$_.classification-eq'completion_evidence_conflict'})
  $lostAuthority=@($candidates|Where-Object{$_.classification-eq'lost_authority'})
  if(-not$Write){
    return [pscustomobject]@{
      ok=$true;action='ReconcileAmbiguousState';applied=$false;candidateCount=$candidates.Count;safeCount=$safe.Count;blockedCount=$blocked.Count
      completionConflictCount=$completionConflicts.Count;lostAuthorityCount=$lostAuthority.Count;candidates=@($candidates | ForEach-Object { ConvertTo-AmbiguousStateCandidateSummary $_ })
      guard='Dry run only. Ambiguous lifecycle evidence is never promoted to completion. Safe candidates require stable task identity, no incomplete WAL, and no external wake reference.'
    }
  }
  if($safe.Count-eq0){
    return [pscustomobject]@{
      ok=$false;action='ReconcileAmbiguousState';applied=$false;candidateCount=$candidates.Count;safeCount=$safe.Count;blockedCount=$blocked.Count
      completionConflictCount=$completionConflicts.Count;lostAuthorityCount=$lostAuthority.Count;blocked=@($blocked | ForEach-Object { ConvertTo-AmbiguousStateCandidateSummary $_ })
      guard='No candidate was changed because every ambiguous task failed preflight. Resolve identity or wake-reference conflicts, then rerun the dry-run.'
    }
  }
  $results=@();$failures=@();$blockedResults=@($blocked | ForEach-Object { ConvertTo-AmbiguousStateCandidateSummary $_ })
  foreach($candidate in $safe){
    try{$results += Invoke-AmbiguousStateQuarantine $candidate $Source}catch{$failures += [pscustomobject]@{taskId=$candidate.taskId;classification=$candidate.classification;error=$_.Exception.Message;failureSite=$_.InvocationInfo.PositionMessage;stack=$_.ScriptStackTrace};break}
  }
  $allBlocked=@($blockedResults)+@($failures)
  return [pscustomobject]@{
    ok=($allBlocked.Count-eq0-and$failures.Count-eq0);action='ReconcileAmbiguousState';applied=($results.Count-gt0);candidateCount=$candidates.Count;quarantinedCount=$results.Count;blockedCount=$allBlocked.Count
    completionConflictCount=$completionConflicts.Count;lostAuthorityCount=$lostAuthority.Count;results=@($results);blocked=@($allBlocked)
    guard=if($failures.Count-eq0){'Each safe task was quarantined through its own recoverable WAL transaction. Existing bytes were hash-verified before archival; missing evidence was recorded without inferring completion; preflight-blocked tasks were left unchanged.'}else{'The batch stopped at the first runtime failure. Any prepared transaction remains recoverable through Reconcile; later safe tasks were not touched.'}
  }
}

function Get-TaskStateCompactionLifecycle([string]$Id,[object]$Projection=$null) {
  $projection = if ($Projection) { $Projection } else { Read-JsonFile (Get-ProjectionPath $Id) }
  if (-not $projection) { return [pscustomobject]@{ ok=$false; status='missing'; projection=$null; reason='projection_missing' } }
  try { $projection = Ensure-ProjectionShape $projection $Id } catch { return [pscustomobject]@{ ok=$false; status='invalid'; projection=$null; reason='projection_identity_invalid' } }
  $status = ([string]$projection.lifecycle.status).ToLowerInvariant()
  $terminal = $status -in @('completed','cancelled','archived','quarantined')
  return [pscustomobject]@{ ok=$terminal; status=$status; projection=$projection; reason=if($terminal){''}else{'active_or_unresolved_lifecycle'} }
}

function Invoke-TaskStateJournalCompaction([object]$Candidate) {
  return Invoke-SuperBrainFileLock $mutationGate {
    $eventPath = [string]$Candidate.path
    if (-not (Test-Path -LiteralPath $eventPath -PathType Leaf)) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='journal_missing'; pendingTransactionCount=0 } }
    $sourceHash = Get-FileSha256 $eventPath
    if (-not [string]::Equals($sourceHash,[string]$Candidate.hash,[StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='journal_changed'; pendingTransactionCount=0 } }
    $liveEvents = @(Read-Events)
    $livePending = @(Get-IncompleteTransactions $liveEvents | Where-Object { [string]$_.taskId -eq [string]$Candidate.taskId })
    if ($livePending.Count -gt 0) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='incomplete_transaction'; pendingTransactionCount=$livePending.Count } }
    try { $rebuilt = Build-ProjectionsFromEvents $liveEvents } catch { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='wal_replay_failed'; error=$_.Exception.Message; pendingTransactionCount=0 } }
    if (-not $rebuilt.ContainsKey([string]$Candidate.taskId)) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='wal_projection_missing'; pendingTransactionCount=0 } }
    $replayProjection = Ensure-ProjectionShape $rebuilt[[string]$Candidate.taskId] ([string]$Candidate.taskId)
    $diskProjection = Read-JsonFile (Get-ProjectionPath ([string]$Candidate.taskId))
    if (-not $diskProjection) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='projection_missing'; pendingTransactionCount=0 } }
    try { $diskProjection = Ensure-ProjectionShape $diskProjection ([string]$Candidate.taskId) } catch { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='projection_identity_invalid'; pendingTransactionCount=0 } }
    if ([int]$diskProjection.revision -ne [int]$replayProjection.revision -or [string]$diskProjection.lastEventId -ne [string]$replayProjection.lastEventId -or (Get-ProjectionParityFingerprint $diskProjection ([string]$Candidate.taskId)) -ne (Get-ProjectionParityFingerprint $replayProjection ([string]$Candidate.taskId))) {
      return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='projection_wal_mismatch'; lifecycleStatus=[string]$replayProjection.lifecycle.status; pendingTransactionCount=0 }
    }
    $lifecycle = Get-TaskStateCompactionLifecycle ([string]$Candidate.taskId) $replayProjection
    if (-not $lifecycle.ok) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason=$lifecycle.reason; lifecycleStatus=$lifecycle.status; pendingTransactionCount=0 } }

    try {
      $recordedWorkspaceKey = ([string]$replayProjection.lifecycle.workspaceKey).Trim()
      if ([string]::IsNullOrWhiteSpace($recordedWorkspaceKey)) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='sqlite_authority_scope_missing'; lifecycleStatus=$lifecycle.status; pendingTransactionCount=0 } }
      $authority = Get-ExistingTaskAuthorityContract ([string]$Candidate.taskId) (Get-SuperBrainWorkspaceKey $recordedWorkspaceKey) $replayProjection.lifecycle
      if (-not $authority) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='sqlite_authority_missing'; lifecycleStatus=$lifecycle.status; pendingTransactionCount=0 } }
      if (-not (Test-TaskAuthorityProjectionStateParity $replayProjection $authority)) { return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='sqlite_authority_mismatch'; lifecycleStatus=$lifecycle.status; pendingTransactionCount=0 } }
    } catch {
      return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='sqlite_authority_check_failed'; error=$_.Exception.Message; lifecycleStatus=$lifecycle.status; pendingTransactionCount=0 }
    }

    $projection = $replayProjection
    $safe = Get-SuperBrainCanonicalTaskToken ([string]$Candidate.taskId)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $taskArchive = Join-Path $archiveRoot $safe
    $taskSnapshots = Join-Path $snapshotRoot $safe
    foreach ($dir in @($taskArchive,$taskSnapshots)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
    $archivePath = Join-Path $taskArchive ("$stamp-r$($projection.revision).jsonl")
    $snapshotPath = Join-Path $taskSnapshots ("r$($projection.revision)-$stamp.json")
    $archiveTemp = "$archivePath.pending-$([guid]::NewGuid().ToString('n'))"
    $snapshotTemp = "$snapshotPath.pending-$([guid]::NewGuid().ToString('n'))"
    $eventTemp = "$eventPath.compact-$([guid]::NewGuid().ToString('n')).tmp"
    $swapped = $false
    try {
      Copy-Item -LiteralPath $eventPath -Destination $archiveTemp -Force -ErrorAction Stop
      if (-not [string]::Equals((Get-FileSha256 $archiveTemp),$sourceHash,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_COMPACT_ARCHIVE_HASH_MISMATCH' }
      Move-Item -LiteralPath $archiveTemp -Destination $archivePath -ErrorAction Stop
      if (-not [string]::Equals((Get-FileSha256 $archivePath),$sourceHash,[StringComparison]::OrdinalIgnoreCase)) { throw 'TASK_STATE_COMPACT_ARCHIVE_FINAL_HASH_MISMATCH' }

      $snapshot = [pscustomobject]@{ schema='super-brain.task-state-snapshot.v2'; taskId=$Candidate.taskId; baseRevision=[int]$projection.revision; compactedAt=(Get-Date).ToString('o'); projection=$projection; archivedEventPath=$archivePath; archivedEventHash=$sourceHash; sourceEventCount=$Candidate.events; sourceBytes=$Candidate.bytes }
      [IO.File]::WriteAllText($snapshotTemp,($snapshot | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
      if (-not (Read-JsonFile $snapshotTemp)) { throw 'TASK_STATE_COMPACT_SNAPSHOT_INVALID' }

      $snapshotEvent = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='snapshot'; transactionId=''; eventId=[guid]::NewGuid().ToString('n'); taskId=$Candidate.taskId; revision=[int]$projection.revision; previousRevision=0; projection=$projection; archivedEventPath=$archivePath; archivedEventHash=$sourceHash; source='task-state-store.ps1:compact'; recordedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') }
      [IO.File]::WriteAllText($eventTemp,(($snapshotEvent | ConvertTo-Json -Depth 14 -Compress) + "`n"),[Text.UTF8Encoding]::new($false))
      $validatedSnapshotEvent = Read-JsonFile $eventTemp
      if (-not $validatedSnapshotEvent -or [string]$validatedSnapshotEvent.phase -ne 'snapshot' -or [string]$validatedSnapshotEvent.taskId -ne [string]$Candidate.taskId) { throw 'TASK_STATE_COMPACT_EVENT_SNAPSHOT_INVALID' }
      Move-Item -LiteralPath $eventTemp -Destination $eventPath -Force -ErrorAction Stop
      $swapped = $true
      $liveSnapshotEvent = Read-JsonFile $eventPath
      if (-not $liveSnapshotEvent -or [string]$liveSnapshotEvent.phase -ne 'snapshot' -or [string]$liveSnapshotEvent.archivedEventHash -ne $sourceHash) { throw 'TASK_STATE_COMPACT_POST_SWAP_INVALID' }
      Move-Item -LiteralPath $snapshotTemp -Destination $snapshotPath -ErrorAction Stop
      return [pscustomobject]@{ compacted=$true; taskId=$Candidate.taskId; revision=[int]$projection.revision; lifecycleStatus=$lifecycle.status; archivedPath=$archivePath; archivedHash=$sourceHash; snapshotPath=$snapshotPath; snapshotHash=Get-FileSha256 $snapshotPath; beforeEvents=$Candidate.events; beforeBytes=$Candidate.bytes; afterEvents=1 }
    } catch {
      $rollbackVerified = $false
      $rollbackError = ''
      try {
        if ((Test-Path -LiteralPath $archivePath -PathType Leaf) -and [string]::Equals((Get-FileSha256 $archivePath),$sourceHash,[StringComparison]::OrdinalIgnoreCase)) {
          if ($swapped) {
            $restoreTemp = "$eventPath.restore-$([guid]::NewGuid().ToString('n')).tmp"
            Copy-Item -LiteralPath $archivePath -Destination $restoreTemp -Force -ErrorAction Stop
            Move-Item -LiteralPath $restoreTemp -Destination $eventPath -Force -ErrorAction Stop
          }
          $rollbackVerified = [string]::Equals((Get-FileSha256 $eventPath),$sourceHash,[StringComparison]::OrdinalIgnoreCase)
        }
      } catch { $rollbackError = $_.Exception.Message }
      return [pscustomobject]@{ compacted=$false; taskId=$Candidate.taskId; reason='compaction_failed'; error=$_.Exception.Message; rollbackVerified=$rollbackVerified; rollbackError=$rollbackError; pendingTransactionCount=0 }
    } finally {
      foreach ($path in @($archiveTemp,$snapshotTemp,$eventTemp)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
    }
  }
}

function Compact-Store([switch]$Write) {
  if ($MaxEventsPerTask -lt 2) { throw 'TASK_STATE_COMPACT_MAX_EVENTS_MINIMUM: 2' }
  if ($MaxBytesPerTask -lt 1024) { throw 'TASK_STATE_COMPACT_MAX_BYTES_MINIMUM: 1024' }
  $events = @(Read-Events)
  $rebuilt = Build-ProjectionsFromEvents $events
  $pendingByTask = @{}
  foreach ($transaction in @(Get-IncompleteTransactions $events)) {
    $pendingByTask[[string]$transaction.taskId] = @($pendingByTask[[string]$transaction.taskId]) + $transaction
  }
  $candidates = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $eventRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
    $count = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8).Count
    if ($count -le $MaxEventsPerTask -and $file.Length -le $MaxBytesPerTask) { continue }
    $taskIds = @(
      Get-Content -LiteralPath $file.FullName -Encoding UTF8 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { try { [string](($_ | ConvertFrom-Json).taskId) } catch { '' } } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
    $candidateTaskId = if ($taskIds.Count -eq 1) { [string]$taskIds[0] } else { '' }
    $pendingCount = if ($pendingByTask.ContainsKey($candidateTaskId)) { @($pendingByTask[$candidateTaskId]).Count } else { 0 }
    if ($candidateTaskId -and $rebuilt.ContainsKey($candidateTaskId)) {
      $replayProjection = Ensure-ProjectionShape $rebuilt[$candidateTaskId] $candidateTaskId
      $diskProjection = Read-JsonFile (Get-ProjectionPath $candidateTaskId)
      $projectionMatches = $false
      if ($diskProjection) {
        try {
          $diskProjection = Ensure-ProjectionShape $diskProjection $candidateTaskId
          $projectionMatches = ([int]$diskProjection.revision -eq [int]$replayProjection.revision -and [string]$diskProjection.lastEventId -eq [string]$replayProjection.lastEventId -and (Get-ProjectionParityFingerprint $diskProjection $candidateTaskId) -eq (Get-ProjectionParityFingerprint $replayProjection $candidateTaskId))
        } catch { $projectionMatches = $false }
      }
      $lifecycle = if (-not $projectionMatches) { [pscustomobject]@{ ok=$false; status=[string]$replayProjection.lifecycle.status; reason='projection_wal_mismatch' } } else { Get-TaskStateCompactionLifecycle $candidateTaskId $replayProjection }
    } elseif ($candidateTaskId) {
      $lifecycle = [pscustomobject]@{ ok=$false; status='missing'; reason='wal_projection_missing' }
    } else {
      $lifecycle = [pscustomobject]@{ ok=$false; status='unknown'; reason='mixed_task_identity' }
    }
    $blockReason = if ($taskIds.Count -ne 1) { 'mixed_task_identity' } elseif ($pendingCount -gt 0) { 'incomplete_transaction' } elseif (-not $lifecycle.ok) { $lifecycle.reason } else { '' }
    $candidates += [pscustomobject]@{ path=$file.FullName; hash=Get-FileSha256 $file.FullName; taskId=$candidateTaskId; taskIds=@($taskIds); events=$count; bytes=$file.Length; lifecycleStatus=$lifecycle.status; blocked=(-not [string]::IsNullOrWhiteSpace($blockReason)); blockReason=$blockReason; pendingTransactionCount=$pendingCount }
  }
  $initialBlocked = @($candidates | Where-Object { $_.blocked })
  if (-not $Write) { return [pscustomobject]@{ ok=$true; action='Compact'; applied=$false; candidateCount=$candidates.Count; eligibleCount=($candidates.Count-$initialBlocked.Count); blockedCount=$initialBlocked.Count; compactedCount=0; candidates=@($candidates); guard='Dry run only. Only terminal task lifecycles without incomplete transactions are eligible; active or unresolved work is never compacted.' } }
  $compacted = @()
  $blocked = @($initialBlocked | ForEach-Object { [pscustomobject]@{ taskId=$_.taskId; reason=$_.blockReason; lifecycleStatus=$_.lifecycleStatus; pendingTransactionCount=$_.pendingTransactionCount; taskIds=@($_.taskIds) } })
  foreach ($candidate in @($candidates | Where-Object { -not $_.blocked })) {
    $item = Invoke-TaskStateJournalCompaction $candidate
    if ($item.compacted) { $compacted += $item } else { $blocked += $item }
  }
  return [pscustomobject]@{ ok=$true; action='Compact'; applied=$true; candidateCount=$candidates.Count; eligibleCount=($candidates.Count-$blocked.Count); blockedCount=$blocked.Count; compactedCount=$compacted.Count; compacted=@($compacted); blocked=@($blocked); guard='Only closed task journals are compacted. Original event bytes are hash-verified in archive before a replayable snapshot replaces the hot journal; a failed swap restores the source journal.' }
}

function Import-CurrentState([switch]$Write) {
  $candidates = @()
  $contextRoot = Join-Path $WorkspaceRoot 'guard-state\current-task-contexts'
  foreach ($file in @(Get-ChildItem -LiteralPath $contextRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) { $candidates += [pscustomobject]@{ kind='context'; path=$file.FullName; source='current-task-context.ps1' } }
  foreach ($life in @('active','completed')) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $WorkspaceRoot "runtime-state\checkpoints\$life") -Filter '*.json' -File -ErrorAction SilentlyContinue)) { $candidates += [pscustomobject]@{ kind='checkpoint'; path=$file.FullName; source='checkpoint-writer.ps1' } }
  }
  foreach ($life in @('active','paused','blocked','completed')) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $SharedRoot "tasks\$life") -Filter '*.task.json' -File -ErrorAction SilentlyContinue)) { $candidates += [pscustomobject]@{ kind='task_card'; path=$file.FullName; source='task-register.ps1' } }
  }
  $plans = @(); $invalid = @()
  foreach ($candidate in $candidates) {
    $entity = Read-JsonFile $candidate.path
    $id = if ($entity) { [string]$entity.taskId } else { '' }
    if ([string]::IsNullOrWhiteSpace($id)) { $invalid += [pscustomobject]@{ path=$candidate.path; taskId=''; kind=$candidate.kind; reason='task_identity_missing' }; continue }
    try {
      $record = Read-Entity $candidate.path $id
      if (([string]$record.status).ToLowerInvariant() -in @('completed','verified','cancelled','archived')) {
        $invalid += [pscustomobject]@{ path=$candidate.path; taskId=$id; kind=$candidate.kind; reason='terminal_state_requires_completion_or_reconciliation' }
        continue
      }
      $workspaceKey = if ($record.value.PSObject.Properties['workspaceKey']) { Get-SuperBrainWorkspaceKey ([string]$record.value.workspaceKey) } else { '' }
      $authority = Get-ExistingTaskAuthorityContract $id $workspaceKey $record.value
      if ($authority) {
        if (Test-TaskAuthorityEntityParity $authority.state $candidate.kind ([pscustomobject]@{ path=$record.path; hash=$record.hash; status=$record.status })) {
          $plans += [pscustomobject]@{ action='already_authoritative'; taskId=$id; kind=$candidate.kind; path=$candidate.path; workspaceKey=$workspaceKey }
        } else {
          $invalid += [pscustomobject]@{ path=$candidate.path; taskId=$id; kind=$candidate.kind; reason='sqlite_authority_conflict' }
        }
      } else {
        $plans += [pscustomobject]@{ action='record_bootstrap'; taskId=$id; kind=$candidate.kind; path=$candidate.path; workspaceKey=$workspaceKey }
      }
    } catch {
      $invalid += [pscustomobject]@{ path=$candidate.path; taskId=$id; kind=$candidate.kind; reason='preflight_failed'; error=$_.Exception.Message }
    }
  }
  if ($invalid.Count -gt 0) {
    return [pscustomobject]@{ ok=$false; action='Import'; applied=$false; candidates=$candidates.Count; plannedCount=$plans.Count; imported=0; unchanged=@($plans|Where-Object{$_.action-eq'already_authoritative'}).Count; invalidCount=$invalid.Count; invalid=@($invalid); invalidPaths=@($invalid|ForEach-Object{$_.path}); audit=$null; guard='No import writes were made because one or more files were terminal, invalid, ambiguous, unavailable, or conflicted with SQLite authority.' }
  }
  if (-not $Write) {
    return [pscustomobject]@{ ok=$true; action='Import'; applied=$false; candidates=$candidates.Count; plannedCount=$plans.Count; bootstrapCount=@($plans|Where-Object{$_.action-eq'record_bootstrap'}).Count; unchanged=@($plans|Where-Object{$_.action-eq'already_authoritative'}).Count; invalidCount=0; plans=@($plans); invalid=@(); invalidPaths=@(); audit=$null; guard='Dry run only. Existing SQLite authority is never overwritten; terminal files require completion or reconciliation.' }
  }
  $imported = 0; $unchanged = @($plans|Where-Object{$_.action-eq'already_authoritative'}).Count; $failures=@()
  foreach ($plan in @($plans|Where-Object{$_.action-eq'record_bootstrap'})) {
    try {
      $result = Record-Entity $plan.taskId $plan.kind 'upsert' $plan.path -1 ('import:' + $plan.kind) -Override -Reason 'Import verified active task-scoped compatibility state before canonical task authority exists.'
      if ($result.changed) { $imported++ } else { $unchanged++ }
    } catch { $failures += [pscustomobject]@{ taskId=$plan.taskId; kind=$plan.kind; path=$plan.path; error=$_.Exception.Message }; break }
  }
  return [pscustomobject]@{ ok=($failures.Count-eq0); action='Import'; applied=($imported-gt0); candidates=$candidates.Count; plannedCount=$plans.Count; imported=$imported; unchanged=$unchanged; invalidCount=0; failureCount=$failures.Count; failures=@($failures); invalid=@(); invalidPaths=@(); audit=Get-AuditResult; guard=if($failures.Count-eq0){'Only verified active files without SQLite task authority were indexed as compatibility bootstrap state; existing authority and terminal state were not changed.'}else{'Import stopped at the first runtime conflict; existing SQLite authority was not overwritten.'} }
}

try {
  $result = switch ($Action) {
    'Record' { Record-Entity $TaskId $EntityKind $Operation $EntityPath $ExpectedRevision $Source -Override:$MaintenanceOverride -Reason $MaintenanceReason }
    'Commit' { Commit-Entity $TaskId $EntityKind $Operation $EntityPath $PayloadPath $ExpectedRevision $Source -Override:$MaintenanceOverride -Reason $MaintenanceReason }
    'CompleteTask' { Complete-TaskState $TaskId $CompletionManifestPath $ExpectedRevision $Source -Override:$MaintenanceOverride -Reason $MaintenanceReason }
    'CommitContinuity' { Commit-ContractContinuity $TaskId $ContinuityManifestPath $Source }
    'CommitActiveBundle' { Commit-ActiveTaskBundle $TaskId $ActiveBundleManifestPath $Source }
    'Get' { Get-Projection $TaskId }
    'Audit' { Get-AuditResult }
    'Rebuild' { Rebuild-Store -Write:$Apply }
    'Reconcile' { Reconcile-Store -Write:$Apply }
    'ReconcileResiduals' { Reconcile-ResidualState -Write:$Apply }
    'ReconcileAmbiguousState' { Reconcile-AmbiguousState -Write:$Apply }
    'RebindProjectionPaths' { Invoke-ProjectionPathRebind $LegacyStateRoot -Write:$Apply -Writer $Source -Override:$MaintenanceOverride -Reason $MaintenanceReason -ExpectedFingerprint $ExpectedPlanFingerprint }
    'Compact' { Compact-Store -Write:$Apply }
    'Import' { Import-CurrentState -Write:$Apply }
  }
  if ($Json) { if ($null -eq $result) { 'null' } else { $result | ConvertTo-Json -Depth 12 } }
  else { if ($null -eq $result) { Write-Host 'TASK_STATE_STORE none' } else { Write-Host "TASK_STATE_STORE action=$Action ok=$($result.ok) taskId=$TaskId" } }
  if ($result -and $result.PSObject.Properties['ok'] -and $result.ok -ne $true) { exit 1 }
  exit 0
} catch {
  $failure = [pscustomobject]@{ ok=$false; action=$Action; taskId=$TaskId; error=$_.Exception.Message; storeRoot=$storeRoot }
  if ($Json) { $failure | ConvertTo-Json -Depth 6 } else { Write-Host "TASK_STATE_STORE_FAILED $($_.Exception.Message)" }
  exit 1
}
