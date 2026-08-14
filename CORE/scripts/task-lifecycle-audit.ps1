param(
  [switch]$Json,
  [int]$StaleDays = 7,
  [string]$WorkspaceKey = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
$outPath = Join-Path $workspace 'last-task-lifecycle-audit.json'

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Resolve-ProjectionEvidencePath([string]$Path,[string]$ExpectedHash = '') {
  $result = [pscustomobject]@{
    originalPath = [string]$Path
    path = [string]$Path
    resolved = $false
    code = 'projected_path'
  }
  if ([string]::IsNullOrWhiteSpace($Path)) {
    $result.code = 'path_missing'
    return $result
  }
  if (Test-Path -LiteralPath $Path -PathType Leaf) { return $result }

  $match = [regex]::Match($Path,'(?i)[\\/](workspace|shared)[\\/](.+)$')
  if (-not $match.Success) {
    $result.code = 'outside_known_state_roots'
    return $result
  }
  $targetRoot = if ($match.Groups[1].Value.ToLowerInvariant() -eq 'workspace') { $workspace } else { $sharedRoot }
  $relative = $match.Groups[2].Value -replace '[\\/]',[IO.Path]::DirectorySeparatorChar
  $candidate = Join-Path $targetRoot $relative
  if (-not (Test-SuperBrainChildPath $targetRoot $candidate)) {
    $result.code = 'canonical_target_outside_root'
    return $result
  }
  $result.path = $candidate
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    $result.code = 'canonical_target_missing'
    return $result
  }
  if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
    $actualHash = ''
    try { $actualHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash } catch {}
    if (-not [string]::Equals($actualHash,$ExpectedHash,[StringComparison]::OrdinalIgnoreCase)) {
      $result.code = 'canonical_target_hash_mismatch'
      return $result
    }
  }
  $result.resolved = $true
  $result.code = 'hash_verified_migration_alias'
  return $result
}

function Get-ActiveIds([string]$Path, [string]$Pattern) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $Path -Filter $Pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
    $item = Read-JsonFile $_.FullName
    if ($item -and [string]$item.status -eq 'active' -and -not [string]::IsNullOrWhiteSpace([string]$item.taskId)) { [string]$item.taskId }
  } | Select-Object -Unique)
}

function Get-ActiveCheckpointRecords([string]$Path) {
  $records = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $records }
  foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
    $item = Read-JsonFile $file.FullName
    if (-not $item -or [string]$item.status -ne 'active' -or [string]::IsNullOrWhiteSpace([string]$item.taskId)) { continue }
    $taskId = [string]$item.taskId
    $candidate = [pscustomobject]@{
      record = $item
      path = $file.FullName
      pendingCount = @($item.pendingSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
      canonical = [string]::Equals($file.FullName,(Get-SuperBrainCanonicalTaskPath $Path $taskId '.json'),[StringComparison]::OrdinalIgnoreCase)
      lastWriteTimeUtc = $file.LastWriteTimeUtc
    }
    $existing = $records[$taskId]
    if ($null -eq $existing -or ($candidate.canonical -and -not $existing.canonical) -or (($candidate.canonical -eq $existing.canonical) -and $candidate.lastWriteTimeUtc -gt $existing.lastWriteTimeUtc)) {
      $records[$taskId] = $candidate
    }
  }
  return $records
}

function Test-DiagnosticTaskId([string]$TaskId) {
  return $TaskId -match '^task-(alpha|beta|card-writer|checkpoint-writer|context-writer)$'
}

function Get-ProjectionRecords([string]$Path) {
  $records=@{}
  $legacyFiles=@()
  if(-not(Test-Path -LiteralPath $Path -PathType Container)){return [pscustomobject]@{records=$records;legacyFiles=@()}}
  foreach($file in @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending)){
    $value=Read-JsonFile $file.FullName
    if(-not$value-or[string]::IsNullOrWhiteSpace([string]$value.taskId)){continue}
    $taskId=[string]$value.taskId
    $canonicalPath=Get-SuperBrainCanonicalTaskPath $Path $taskId '.json'
    $canonical=[string]::Equals($file.FullName,$canonicalPath,[StringComparison]::OrdinalIgnoreCase)
    if(-not$canonical){$legacyFiles += [pscustomobject]@{taskId=$taskId;path=$file.FullName;revision=[int]$value.revision;canonicalPath=$canonicalPath;canonicalExists=[IO.File]::Exists($canonicalPath);hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}}
    $existing=$records[$taskId]
    if($null-eq$existing-or($canonical-and-not$existing.canonical)-or(($canonical-eq$existing.canonical)-and$file.LastWriteTimeUtc-gt$existing.lastWriteTimeUtc)){$records[$taskId]=[pscustomobject]@{value=$value;path=$file.FullName;canonical=$canonical;lastWriteTimeUtc=$file.LastWriteTimeUtc}}
  }
  return [pscustomobject]@{records=$records;legacyFiles=@($legacyFiles)}
}

function Test-ProjectionEntityHash([object]$Entity) {
  if(-not$Entity-or[string]::IsNullOrWhiteSpace([string]$Entity.path)){return $false}
  if([string]::IsNullOrWhiteSpace([string]$Entity.hash)){return $false}
  $resolved = Resolve-ProjectionEvidencePath ([string]$Entity.path) ([string]$Entity.hash)
  if(-not[IO.File]::Exists([string]$resolved.path)){return $false}
  return ((Get-FileHash -LiteralPath ([string]$resolved.path) -Algorithm SHA256).Hash-eq[string]$Entity.hash)
}

function Get-ContextContractAuthority([object]$Context,[object]$Projection,[string]$TaskId) {
  $result = [pscustomobject]@{ current=$false; code='context_not_bound'; contractPath=''; contractRevision=0; planFingerprint='' }
  if (-not $Context -or [string]$Context.taskId -ne $TaskId -or [string]$Context.status -ne 'active') { return $result }
  if ([string]$Context.bindingState -ne 'bound' -or [string]$Context.authorizationState -ne 'authorizing') { return $result }
  if (-not $Projection -or [string]$Projection.taskId -ne $TaskId -or [int]$Projection.revision -ne [int]$Context.taskStateRevision) {
    $result.code = 'task_state_revision_mismatch'
    return $result
  }
  $fileName = Split-Path -Leaf ([string]$Context.contractFileName)
  if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -ne [string]$Context.contractFileName) {
    $result.code = 'contract_file_name_invalid'
    return $result
  }
  $contractPath = Join-Path (Join-Path $workspace 'runtime-state\execution-contracts') $fileName
  $result.contractPath = $contractPath
  if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    $result.code = 'contract_file_missing'
    return $result
  }
  $contract = Read-JsonFile $contractPath
  if (-not $contract -or [string]$contract.taskId -ne $TaskId -or [string]$contract.status -ne 'active' -or -not (Test-SuperBrainWorkspaceKey ([string]$contract.workspaceKey) ([string]$Context.workspaceKey))) {
    $result.code = 'contract_identity_mismatch'
    return $result
  }
  if (-not $contract.planReceipt -or [string]::IsNullOrWhiteSpace([string]$contract.planReceipt.planFingerprint)) {
    $result.code = 'contract_plan_receipt_missing'
    return $result
  }
  $actualHash = (Get-FileHash -LiteralPath $contractPath -Algorithm SHA256).Hash
  $matches = ([int]$Context.contractRevision -eq [int]$contract.revision -and [string]$Context.planFingerprint -eq [string]$contract.planReceipt.planFingerprint -and [string]$Context.ownerSessionKey -eq [string]$contract.ownerSessionKey -and [string]::Equals([string]$Context.targetHash,$actualHash,[StringComparison]::OrdinalIgnoreCase))
  if (-not $matches) {
    $result.code = 'contract_binding_mismatch'
    $result.contractRevision = [int]$contract.revision
    $result.planFingerprint = [string]$contract.planReceipt.planFingerprint
    return $result
  }
  $result.current = $true
  $result.code = 'current'
  $result.contractRevision = [int]$contract.revision
  $result.planFingerprint = [string]$contract.planReceipt.planFingerprint
  return $result
}

function Get-ActiveProjectionEntityParity([hashtable]$ProjectionRecords) {
  $findings = @()
  $resolutions = @()
  $activeProjectionCount = 0
  $checkedEntityCount = 0
  foreach ($taskId in @($ProjectionRecords.Keys | Sort-Object)) {
    $record = $ProjectionRecords[$taskId]
    $projection = $record.value
    $status = if ($projection -and $projection.lifecycle) { ([string]$projection.lifecycle.status).ToLowerInvariant() } else { 'unknown' }
    if ($status -notin @('active','paused','blocked')) { continue }
    $activeProjectionCount++
    foreach ($kind in @('context','checkpoint','task_card')) {
      $entity = if ($projection.entities -and $projection.entities.PSObject.Properties[$kind]) { $projection.entities.$kind } else { $null }
      if (-not $entity) { continue }
      $checkedEntityCount++
      $path = [string]$entity.path
      $expectedHash = [string]$entity.hash
      $resolved = Resolve-ProjectionEvidencePath $path $expectedHash
      $evidencePath = [string]$resolved.path
      $base = [ordered]@{ taskId=$taskId; lifecycleStatus=$status; entityKind=$kind; projectionPath=[string]$record.path; entityPath=$path; resolvedEntityPath=$evidencePath; pathResolution=[string]$resolved.code; expectedHash=$expectedHash }
      if ([string]::IsNullOrWhiteSpace($path)) {
        $findings += [pscustomobject]($base + @{ classification='active_projection_entity_path_missing'; reason='projected entity has no path' })
        continue
      }
      if (-not [IO.File]::Exists($evidencePath)) {
        $findings += [pscustomobject]($base + @{ classification='active_projection_entity_missing'; reason='projected entity file is missing' })
        continue
      }
      if ($resolved.resolved) {
        $resolutions += [pscustomobject]@{ taskId=$taskId; entityKind=$kind; projectionPath=[string]$record.path; originalPath=$path; resolvedPath=$evidencePath; expectedHash=$expectedHash; resolution=[string]$resolved.code }
      }
      if ([string]::IsNullOrWhiteSpace($expectedHash)) {
        $findings += [pscustomobject]($base + @{ classification='active_projection_entity_hash_missing'; reason='projected entity has no hash' })
        continue
      }
      $actualHash = ''
      try { $actualHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash } catch {}
      if ([string]::IsNullOrWhiteSpace($actualHash) -or -not [string]::Equals($actualHash,$expectedHash,[StringComparison]::OrdinalIgnoreCase)) {
        $findings += [pscustomobject]($base + @{ classification='active_projection_entity_hash_mismatch'; reason='projected entity hash differs from file'; actualHash=$actualHash })
        continue
      }
      $value = Read-JsonFile $evidencePath
      if (-not $value) {
        $findings += [pscustomobject]($base + @{ classification='active_projection_entity_invalid'; reason='projected entity file is not valid JSON' })
        continue
      }
      if ($value.PSObject.Properties['taskId'] -and [string]$value.taskId -ne $taskId) {
        $findings += [pscustomobject]($base + @{ classification='active_projection_entity_task_mismatch'; reason='projected entity belongs to a different task'; actualTaskId=[string]$value.taskId })
        continue
      }
      if ($value.PSObject.Properties['status'] -and -not [string]::IsNullOrWhiteSpace([string]$entity.status) -and [string]$value.status -ne [string]$entity.status) {
        $findings += [pscustomobject]($base + @{ classification='active_projection_entity_status_mismatch'; reason='projected entity status differs from file'; actualStatus=[string]$value.status; expectedStatus=[string]$entity.status })
      }
    }
  }
  return [pscustomobject]@{ activeProjectionCount=$activeProjectionCount; checkedEntityCount=$checkedEntityCount; findings=@($findings); resolutions=@($resolutions) }
}

$activeTaskRoot = Join-Path $sharedRoot 'tasks\active'
$activeCheckpointRoot = Join-Path $workspace 'runtime-state\checkpoints\active'
$activeContextRoot = Join-Path $workspace 'guard-state\current-task-contexts'
$activeContractRoot = Join-Path $workspace 'runtime-state\execution-contracts'
$checkpointRecords = Get-ActiveCheckpointRecords $activeCheckpointRoot
$checkpointIds = @($checkpointRecords.Keys)
$contextIds = @(Get-ActiveIds $activeContextRoot '*.json')
$contractIds = @(Get-ActiveIds $activeContractRoot '*.json')
$projectionState=Get-ProjectionRecords (Join-Path $workspace 'task-state-store\projections')
$projectionRecords=$projectionState.records
$activeProjectionEntityParity=Get-ActiveProjectionEntityParity $projectionRecords
$cards = @()
$parseFailures = @()

if (Test-Path -LiteralPath $activeTaskRoot -PathType Container) {
  foreach ($file in @(Get-ChildItem -LiteralPath $activeTaskRoot -Filter '*.task.json' -File -ErrorAction SilentlyContinue)) {
    $task = Read-JsonFile $file.FullName
    if (-not $task) { $parseFailures += $file.FullName; continue }
    $updated = $null
    try { $updated = [datetime]::Parse([string]$task.updatedAt) } catch { $updated = $file.LastWriteTime }
    $ageDays = [Math]::Round(((Get-Date) - $updated).TotalDays, 2)
    $taskId = [string]$task.taskId
    $pendingCount = @($task.pendingSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    $checkpointRecord = if ($checkpointRecords.ContainsKey($taskId)) { $checkpointRecords[$taskId] } else { $null }
    $bound = ($checkpointIds -contains $taskId) -or ($contextIds -contains $taskId) -or ($contractIds -contains $taskId)
    $cards += [pscustomobject]@{
      taskId = $taskId
      taskName = [string]$task.taskName
      status = [string]$task.status
      updatedAt = [string]$task.updatedAt
      ageDays = $ageDays
      pendingCount = $pendingCount
      checkpointPendingCount = if ($checkpointRecord) { [int]$checkpointRecord.pendingCount } else { 0 }
      checkpointAuthoritative = [bool]($null -ne $checkpointRecord)
      checkpointSourcePath = if ($checkpointRecord) { [string]$checkpointRecord.path } else { '' }
      nextAction = [string]$task.nextAction
      bound = $bound
      diagnostic = Test-DiagnosticTaskId $taskId
      sourcePath = $file.FullName
    }
  }
}

$diagnosticCards = @($cards | Where-Object { $_.diagnostic })
$cardCheckpointDivergences = @($cards | Where-Object { $_.pendingCount -eq 0 -and $_.checkpointAuthoritative -and $_.checkpointPendingCount -gt 0 })
$zeroPendingCards = @($cards | Where-Object { $_.pendingCount -eq 0 -and -not ($_.checkpointAuthoritative -and $_.checkpointPendingCount -gt 0) })
$unboundCards = @($cards | Where-Object { -not $_.bound })
$staleUnboundCards = @($unboundCards | Where-Object { $_.ageDays -ge $StaleDays })
$legacyCompletionConflicts=@()
$orphanActiveContexts=@()
$contractBackedActiveContexts=@()
$quarantinedProjections=@()
foreach($taskId in @($projectionRecords.Keys)){
  $projection=$projectionRecords[$taskId].value
  if ($projection.lifecycle -and [string]$projection.lifecycle.status -eq 'quarantined') {
    $manifestPath=if($projection.lifecycle.PSObject.Properties['quarantineManifestPath']){[string]$projection.lifecycle.quarantineManifestPath}else{''}
    $manifestHash=if($projection.lifecycle.PSObject.Properties['quarantineManifestHash']){[string]$projection.lifecycle.quarantineManifestHash}else{''}
    $resolvedManifest = Resolve-ProjectionEvidencePath $manifestPath $manifestHash
    $manifestEvidencePath = [string]$resolvedManifest.path
    $manifestHashValid=($manifestPath -and $manifestHash -and (Test-Path -LiteralPath $manifestEvidencePath -PathType Leaf) -and ((Get-FileHash -LiteralPath $manifestEvidencePath -Algorithm SHA256).Hash -eq $manifestHash))
    $quarantinedProjections += [pscustomobject]@{taskId=$taskId;classification='quarantined_ambiguous_state';reason=if($projection.lifecycle.PSObject.Properties['quarantineReason']){[string]$projection.lifecycle.quarantineReason}else{''};transactionId=if($projection.lifecycle.PSObject.Properties['quarantineTransactionId']){[string]$projection.lifecycle.quarantineTransactionId}else{''};manifestPath=$manifestPath;resolvedManifestPath=$manifestEvidencePath;manifestPathResolution=[string]$resolvedManifest.code;manifestHashValid=[bool]$manifestHashValid;quarantinedAt=if($projection.lifecycle.PSObject.Properties['quarantinedAt']){[string]$projection.lifecycle.quarantinedAt}else{''}}
    continue
  }
  $contextEntity=if($projection.entities){$projection.entities.context}else{$null}
  $checkpointEntity=if($projection.entities){$projection.entities.checkpoint}else{$null}
  $taskCardEntity=if($projection.entities){$projection.entities.task_card}else{$null}
  $contextActive=($contextEntity-and[string]$contextEntity.status-eq'active')
  $checkpointTerminal=($checkpointEntity-and[string]$checkpointEntity.status-in@('completed','verified','cancelled','archived'))
  $taskCardTerminal=($taskCardEntity-and[string]$taskCardEntity.status-in@('completed','verified','cancelled','archived'))
  if($contextActive-and$checkpointTerminal-and$taskCardTerminal){
    $legacyCompletionConflicts += [pscustomobject]@{taskId=$taskId;classification='completion_evidence_conflict';contextPath=[string]$contextEntity.path;checkpointPath=[string]$checkpointEntity.path;taskCardPath=[string]$taskCardEntity.path;contextHashValid=(Test-ProjectionEntityHash $contextEntity);checkpointHashValid=(Test-ProjectionEntityHash $checkpointEntity);taskCardHashValid=(Test-ProjectionEntityHash $taskCardEntity);reason='terminal checkpoint and task card coexist with an active context but no committed terminal lifecycle seal'}
  } elseif($contextActive-and-not$checkpointEntity-and-not$taskCardEntity){
    $resolvedContext = Resolve-ProjectionEvidencePath ([string]$contextEntity.path) ([string]$contextEntity.hash)
    $contextValue=Read-JsonFile ([string]$resolvedContext.path)
    $contractAuthority=Get-ContextContractAuthority $contextValue $projection $taskId
    if($contractAuthority.current){
      $contractBackedActiveContexts += [pscustomobject]@{taskId=$taskId;classification='contract_backed_active_context';contextPath=[string]$contextEntity.path;contractPath=[string]$contractAuthority.contractPath;contractRevision=[int]$contractAuthority.contractRevision;planFingerprint=[string]$contractAuthority.planFingerprint}
    }else{
      $orphanActiveContexts += [pscustomobject]@{taskId=$taskId;classification='lost_authority';contextPath=[string]$contextEntity.path;contextHashValid=(Test-ProjectionEntityHash $contextEntity);contractPath=[string]$contractAuthority.contractPath;contractAuthorityCode=[string]$contractAuthority.code;reason='active context has neither checkpoint/task-card authority nor an exact bound active contract'}
    }
  }
}
$storeAudit = $null
try {
  $auditWorkspace = if(-not[string]::IsNullOrWhiteSpace($WorkspaceKey)){$WorkspaceKey}elseif(-not[string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_WORKSPACE_KEY)){$env:SUPER_BRAIN_WORKSPACE_KEY}else{(Get-Location).Path}
  $raw = @(& (Join-Path $PSScriptRoot 'task-state-store.ps1') -Action Audit -OwnerWorkspace $auditWorkspace -Json 2>$null)
  if ($LASTEXITCODE -eq 0) { $storeAudit = (($raw -join "`n") | ConvertFrom-Json) }
} catch { $storeAudit = $null }

$findingCount = $diagnosticCards.Count + $zeroPendingCards.Count + $cardCheckpointDivergences.Count + $staleUnboundCards.Count + $parseFailures.Count + $legacyCompletionConflicts.Count + $orphanActiveContexts.Count + @($projectionState.legacyFiles).Count + @($activeProjectionEntityParity.findings).Count
$reconciliationRequired = ($legacyCompletionConflicts.Count -gt 0 -or $orphanActiveContexts.Count -gt 0 -or @($projectionState.legacyFiles).Count -gt 0 -or @($activeProjectionEntityParity.findings).Count -gt 0)
$storeAuditAvailable = ($null -ne $storeAudit)
$storeAuditOk = ($storeAuditAvailable -and $storeAudit.automaticContinuationSafe -eq $true -and $storeAudit.ok -eq $true)
$hardFindingCount = $parseFailures.Count + $legacyCompletionConflicts.Count + $orphanActiveContexts.Count + @($projectionState.legacyFiles).Count + @($activeProjectionEntityParity.findings).Count
$result = [pscustomobject]@{
  # The store audit may be scoped to a different workspace selection; its result remains visible,
  # while lifecycle failure is driven by evidence found in this audit's own state scope.
  ok = ($hardFindingCount -eq 0 -and -not $reconciliationRequired)
  checkedAt = Get-SuperBrainUtcTimestamp
  schema = 'super-brain.task-lifecycle-audit.v2'
  version = [string]$manifest.version
  staleDays = $StaleDays
  counts = [pscustomobject]@{
    activeCards = $cards.Count
    activeCheckpoints = $checkpointIds.Count
    activeContexts = $contextIds.Count
    activeContracts = $contractIds.Count
    activeProjections = [int]$activeProjectionEntityParity.activeProjectionCount
    activeProjectionEntitiesChecked = [int]$activeProjectionEntityParity.checkedEntityCount
    activeProjectionEntityParityFailures = @($activeProjectionEntityParity.findings).Count
    migratedProjectionPathsResolved = @($activeProjectionEntityParity.resolutions).Count
    diagnosticCards = $diagnosticCards.Count
    zeroPendingActiveCards = $zeroPendingCards.Count
    cardCheckpointDivergences = $cardCheckpointDivergences.Count
    unboundActiveCards = $unboundCards.Count
    staleUnboundActiveCards = $staleUnboundCards.Count
    parseFailures = $parseFailures.Count
    legacyProjectionFiles = @($projectionState.legacyFiles).Count
    legacyProjectionShadows = @($projectionState.legacyFiles|Where-Object{$_.canonicalExists}).Count
    legacyProjectionOnly = @($projectionState.legacyFiles|Where-Object{-not$_.canonicalExists}).Count
    completionEvidenceConflicts = $legacyCompletionConflicts.Count
    orphanActiveContexts = $orphanActiveContexts.Count
    contractBackedActiveContexts = $contractBackedActiveContexts.Count
    quarantinedProjections = $quarantinedProjections.Count
    findings = $findingCount
    hardFindings = $hardFindingCount
  }
  pointerState = if ($storeAudit) { [pscustomobject]@{
    mismatch = [bool]$storeAudit.pointerMismatch
    compatibilityMismatch = [bool]$storeAudit.compatibilityPointers.divergent
    automaticContinuationSafe = [bool]$storeAudit.automaticContinuationSafe
    automaticContinuationTaskId = [string]$storeAudit.automaticContinuationTaskId
    parallelTaskIds = @($storeAudit.parallelTaskIds)
    distinctCompatibilityTaskIds = @($storeAudit.compatibilityPointers.distinctTaskIds)
    authoritySource = [string]$storeAudit.workspaceSelection.contextSource
  } } else { $null }
  diagnosticCards = @($diagnosticCards)
  zeroPendingActiveCards = @($zeroPendingCards)
  cardCheckpointDivergences = @($cardCheckpointDivergences)
  staleUnboundActiveCards = @($staleUnboundCards)
  legacyProjectionFiles = @($projectionState.legacyFiles)
  activeProjectionEntityParity = @($activeProjectionEntityParity.findings)
  migratedProjectionPathResolutions = @($activeProjectionEntityParity.resolutions)
  completionEvidenceConflicts = @($legacyCompletionConflicts)
  orphanActiveContexts = @($orphanActiveContexts)
  contractBackedActiveContexts = @($contractBackedActiveContexts)
  quarantinedProjections = @($quarantinedProjections)
  parseFailures = @($parseFailures)
  reconciliationRequired = $reconciliationRequired
  storeAuditAvailable = $storeAuditAvailable
  storeAuditOk = $storeAuditOk
  guard = 'Known diagnostic task IDs are never resume candidates. Zero pending steps or age alone never proves completion. Every active, paused, or blocked projection must still match its task-scoped entity files and hashes. Migration-era absolute paths may resolve read-only to the canonical workspace/shared suffix only when the target SHA-256 matches; projections are not rewritten by this audit. A context-only active projection is legitimate only when its exact active contract matches task, workspace, session, revision, plan fingerprint, and file hash; otherwise it is lost authority. Terminal checkpoint plus task-card evidence with an active context is quarantined as a conflict until a transaction-bound terminal seal exists; quarantined projections are resolved non-completion dispositions and retain manifest-hash evidence; legacy projections are migration inputs, not current authority.'
  path = $outPath
}

if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else {
  Write-Host "TASK_LIFECYCLE_AUDIT ok=$($result.ok) active=$($cards.Count) diagnostic=$($diagnosticCards.Count) zeroPending=$($zeroPendingCards.Count) staleUnbound=$($staleUnboundCards.Count) pointerMismatch=$($result.pointerState.mismatch)"
}
if (-not $result.ok) { exit 1 }
exit 0
