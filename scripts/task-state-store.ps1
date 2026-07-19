[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Record','Commit','Get','Audit','Rebuild','Reconcile','Compact','Import')]
  [string]$Action = 'Audit',
  [string]$TaskId = '',
  [ValidateSet('context','checkpoint','task_card')]
  [string]$EntityKind = 'task_card',
  [ValidateSet('upsert','clear')]
  [string]$Operation = 'upsert',
  [string]$EntityPath = '',
  [string]$PayloadPath = '',
  [int]$ExpectedRevision = -1,
  [string]$Source = 'task-state-store.ps1',
  [string]$OwnerAgentId = '',
  [string]$OwnerSessionId = '',
  [string]$OwnerPlatform = '',
  [string]$OwnerWorkspace = '',
  [switch]$MaintenanceOverride,
  [string]$MaintenanceReason = '',
  [int]$LeaseSeconds = 86400,
  [int]$MaxEventsPerTask = 200,
  [long]$MaxBytesPerTask = 1048576,
  [ValidateSet('none','after_prepare','after_materialize')]
  [string]$FaultPoint = 'none',
  [string]$WorkspaceRoot = '',
  [string]$SharedRoot = '',
  [switch]$Apply,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

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
$indexPath = Join-Path $storeRoot 'index.json'
$mutationGate = Join-Path $storeRoot 'mutation-gate'
foreach ($dir in @($WorkspaceRoot,$SharedRoot,$storeRoot,$eventRoot,$projectionRoot,$stagingRoot,$snapshotRoot,$archiveRoot)) {
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
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
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

function New-OwnerRecord([object]$Value,[string]$AgentId,[string]$SessionId,[string]$Platform,[string]$Workspace,[int]$Seconds,[string]$Status) {
  if ($Value) {
    if ([string]::IsNullOrWhiteSpace($AgentId) -and $Value.PSObject.Properties['agentId']) { $AgentId = [string]$Value.agentId }
    if ([string]::IsNullOrWhiteSpace($SessionId) -and $Value.PSObject.Properties['sessionId']) { $SessionId = [string]$Value.sessionId }
    if ([string]::IsNullOrWhiteSpace($Platform) -and $Value.PSObject.Properties['platform']) { $Platform = [string]$Value.platform }
    if ([string]::IsNullOrWhiteSpace($Workspace) -and $Value.PSObject.Properties['workspace']) { $Workspace = [string]$Value.workspace }
  }
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
  foreach ($name in @('agentId','sessionId','platform','workspace')) {
    if (-not [string]::Equals([string]$Expected.$name,[string]$Actual.$name,[System.StringComparison]::OrdinalIgnoreCase)) { return $false }
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

function Materialize-Payload([string]$Payload,[string]$Target,[string]$TransactionId) {
  $dir = Split-Path -Parent $Target
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $text = [IO.File]::ReadAllText($Payload,[Text.Encoding]::UTF8)
  $temp = Join-Path $dir ('.taskstate-' + $TransactionId + '.tmp')
  try {
    [IO.File]::WriteAllText($temp,$text,[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Target -Force
    return Get-FileSha256 $Target
  } finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  }
}

function Remove-StagingPayload([string]$Path) {
  if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-ChildPath $stagingRoot $Path) -and (Test-Path -LiteralPath $Path -PathType Leaf)) { Remove-Item -LiteralPath $Path -Force }
}

function Commit-Projection([object]$Projection,[string]$Id,[string]$Kind,[string]$Op,[object]$EntityRecord,[int]$Revision,[string]$EventId,[string]$When) {
  Set-EntityValue $Projection $Kind $EntityRecord
  $Projection.revision = $Revision
  $Projection.updatedAt = $When
  $Projection.lastEventId = $EventId
  Write-JsonUtf8NoBom (Get-ProjectionPath $Id) $Projection 10
  $null = Update-Index $Projection
}

function Record-Entity([string]$Id,[string]$Kind,[string]$Op,[string]$Path,[int]$Expected,[string]$Writer,[switch]$Override,[string]$Reason) {
  if ([string]::IsNullOrWhiteSpace($Id)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  if (-not $Override) { throw 'TASK_STATE_MAINTENANCE_OVERRIDE_REQUIRED action=Record' }
  $maintenance = New-MaintenanceAudit 'Record' $Reason $Writer
  $entity = if ($Op -eq 'upsert') { Read-Entity $Path $Id } else { [pscustomobject]@{ path=if($Path){[IO.Path]::GetFullPath($Path)}else{''}; hash=''; status='cleared'; value=$null } }
  return Invoke-SuperBrainFileLock $mutationGate {
    $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $Id)) $Id
    $actualRevision = [int]$projection.revision
    if ($Expected -ge 0 -and $Expected -ne $actualRevision) { throw "TASK_STATE_CAS_MISMATCH expected=$Expected actual=$actualRevision taskId=$Id" }
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

function Commit-Entity([string]$Id,[string]$Kind,[string]$Op,[string]$Path,[string]$Payload,[int]$Expected,[string]$Writer,[switch]$Override,[string]$Reason) {
  if ([string]::IsNullOrWhiteSpace($Id)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $target = Assert-EntityTarget $Kind $Path $Id
  $payloadValue = if (-not [string]::IsNullOrWhiteSpace($Payload)) { Read-Payload $Payload $Id } else { $null }
  if ($Op -eq 'upsert' -and -not $payloadValue) { throw 'TASK_STATE_PAYLOAD_PATH_REQUIRED' }
  return Invoke-SuperBrainFileLock $mutationGate {
    $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $Id)) $Id
    $actualRevision = [int]$projection.revision
    if ($Expected -ge 0 -and $Expected -ne $actualRevision) { throw "TASK_STATE_CAS_MISMATCH expected=$Expected actual=$actualRevision taskId=$Id" }
    $previous = Get-EntityValue $projection $Kind
    $status = if ($payloadValue) { [string]$payloadValue.status } else { 'cleared' }
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
    $prepare = [pscustomobject]@{
      schema='super-brain.task-state-event.v2'; phase='prepared'; transactionId=$transactionId; eventId=[guid]::NewGuid().ToString('n'); taskId=$Id
      revision=0; targetRevision=$nextRevision; previousRevision=$actualRevision; entityKind=$Kind; operation=$Op
      command=[pscustomobject]@{ targetPath=$target; payloadPath=if($payloadValue){$payloadValue.path}else{''}; payloadHash=if($payloadValue){$payloadValue.hash}else{''}; status=$status; owner=$owner; maintenance=$maintenance }
      source=Limit-Text $Writer 120; recordedAt=$now
    }
    Add-StateEvent $Id $prepare
    if ($FaultPoint -eq 'after_prepare') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_PREPARE' }
    if ($Op -eq 'upsert' -or $payloadValue) { $canonicalHash = Materialize-Payload $payloadValue.path $target $transactionId }
    else { if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force }; $canonicalHash = '' }
    if ($FaultPoint -eq 'after_materialize') { throw 'TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZE' }
    $eventId = [guid]::NewGuid().ToString('n')
    $committedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $entityRecord = if ($Op -eq 'clear') { $null } else { [pscustomobject]@{ path=$target; hash=$canonicalHash; status=$status; source=Limit-Text $Writer 120; owner=$owner } }
    $commit = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='committed'; transactionId=$transactionId; eventId=$eventId; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entityKind=$Kind; operation=$Op; entity=$entityRecord; maintenance=$maintenance; source=Limit-Text $Writer 120; recordedAt=$committedAt }
    Add-StateEvent $Id $commit
    Commit-Projection $projection $Id $Kind $Op $entityRecord $nextRevision $eventId $committedAt
    Remove-StagingPayload $Payload
    return [pscustomobject]@{ ok=$true; changed=$true; taskId=$Id; revision=$nextRevision; previousRevision=$actualRevision; entityKind=$Kind; operation=$Op; transactionId=$transactionId; projectionPath=Get-ProjectionPath $Id; eventPath=Get-EventPath $Id; materializedPath=$target; mode='wal-materializer'; maintenanceOverride=[bool]$Override }
  }
}

function Get-Projection([string]$Id) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
  $projection = Read-JsonFile (Get-ProjectionPath $Id)
  if ($projection -and $projection.PSObject.Properties['taskId'] -and [string]$projection.taskId -ne $Id) { throw "TASK_STATE_IDENTITY_MISMATCH expected=$Id actual=$($projection.taskId)" }
  return $projection
}

function Read-Events {
  $events = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $eventRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $events += ($line | ConvertFrom-Json) } catch { throw "TASK_STATE_EVENT_INVALID path=$($file.FullName)" }
    }
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
  $context = Read-JsonFile (Join-Path $WorkspaceRoot 'current-task-context.json')
  $checkpoint = Read-JsonFile (Join-Path $WorkspaceRoot 'active-checkpoint.json')
  $taskGraph = Read-JsonFile (Join-Path $WorkspaceRoot 'task-graph.json')
  $stepLedger = Read-JsonFile (Join-Path $WorkspaceRoot 'step-ledger.json')
  $contextTaskId = if ($context) { [string]$context.taskId } else { '' }
  $checkpointTaskId = if ($checkpoint) { [string]$checkpoint.taskId } else { '' }
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
  $index = Read-JsonFile $indexPath
  $workspaceSelector = Get-SuperBrainRelevantCheckpoint $WorkspaceRoot $context $OwnerWorkspace
  $compatibilityTaskIds = @($contextTaskId,$checkpointTaskId,$taskGraphTaskId,$stepLedgerTaskId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  return [pscustomobject]@{
    ok = ($missing.Count -eq 0 -and $incomplete.Count -eq 0)
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    schema = 'super-brain.task-state-audit.v2'
    consistency = $consistency
    pointerMismatch = ($contextTaskId -and $checkpointTaskId -and $contextTaskId -ne $checkpointTaskId)
    sameOwner = $sameOwner
    merged = $false
    authority = 'task_state_store_and_workspace_selector'
    automaticContinuationSafe = (($null -eq $workspaceSelector.checkpoint) -or [string]$workspaceSelector.state -eq 'relevant')
    automaticContinuationTaskId = if($workspaceSelector.checkpoint){[string]$workspaceSelector.checkpoint.taskId}else{''}
    workspaceSelection = [pscustomobject]@{ state=$workspaceSelector.state; contextState=$workspaceSelector.contextState; source=$workspaceSelector.source; ignoredTaskId=$workspaceSelector.ignoredTaskId }
    contextTaskId = $contextTaskId
    checkpointTaskId = $checkpointTaskId
    conflictingTaskId = if ($consistency -eq 'conflict') { $checkpointTaskId } else { '' }
    parallelTaskIds = if ($consistency -eq 'parallel') { @($contextTaskId,$checkpointTaskId) } else { @() }
    compatibilityPointers = [pscustomobject]@{ contextTaskId=$contextTaskId; checkpointTaskId=$checkpointTaskId; taskGraphTaskId=$taskGraphTaskId; stepLedgerTaskId=$stepLedgerTaskId; divergent=($compatibilityTaskIds.Count -gt 1); distinctTaskIds=@($compatibilityTaskIds) }
    missingProjectionTaskIds = @($missing)
    incompleteTransactionCount = $incomplete.Count
    incompleteTransactions = @($incomplete | ForEach-Object { [pscustomobject]@{ taskId=$_.taskId; transactionId=$_.transactionId; entityKind=$_.entityKind; operation=$_.operation; targetRevision=$_.targetRevision } })
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
    Set-EntityValue $projection ([string]$event.entityKind) $event.entity
    $projection.revision = [int]$event.revision
    $projection.updatedAt = [string]$event.recordedAt
    $projection.lastEventId = [string]$event.eventId
  }
  return $byTask
}

function Rebuild-Store([switch]$Write) {
  $events = @(Read-Events)
  $projections = Build-ProjectionsFromEvents $events
  if ($Write) {
    Invoke-SuperBrainFileLock $mutationGate {
      foreach ($id in @($projections.Keys | Sort-Object)) { Write-JsonUtf8NoBom (Get-ProjectionPath $id) $projections[$id] 10 }
      $summaries = @($projections.Keys | ForEach-Object { New-IndexSummary $projections[$_] } | Sort-Object updatedAt -Descending | Select-Object -First 500)
      Write-JsonUtf8NoBom $indexPath ([pscustomobject]@{ schema='super-brain.task-state-index.v2'; updatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); taskCount=$summaries.Count; maxTasks=500; tasks=$summaries }) 8
    } | Out-Null
  }
  return [pscustomobject]@{ ok=$true; action='Rebuild'; applied=[bool]$Write; eventCount=$events.Count; projectionCount=$projections.Count; indexPath=$indexPath; guard=if($Write){'Projection and index rebuilt from committed events and snapshots.'}else{'Dry run only; use -Apply to write rebuilt projections.'} }
}

function Complete-PreparedTransaction([object]$Prepare) {
  $id = [string]$Prepare.taskId
  $projection = Ensure-ProjectionShape (Read-JsonFile (Get-ProjectionPath $id)) $id
  $actualRevision = [int]$projection.revision
  if ($actualRevision -ne [int]$Prepare.previousRevision -or [int]$Prepare.targetRevision -ne ($actualRevision + 1)) { return [pscustomobject]@{ ok=$false; reason='revision_advanced'; taskId=$id; transactionId=$Prepare.transactionId } }
  $command = $Prepare.command
  $target = Assert-EntityTarget ([string]$Prepare.entityKind) ([string]$command.targetPath) $id
  $op = [string]$Prepare.operation
  if ($op -eq 'upsert' -or -not [string]::IsNullOrWhiteSpace([string]$command.payloadPath)) {
    $targetHash = Get-FileSha256 $target
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
  Remove-StagingPayload ([string]$command.payloadPath)
  return [pscustomobject]@{ ok=$true; taskId=$id; transactionId=$Prepare.transactionId; revision=$actualRevision+1 }
}

function Reconcile-Store([switch]$Write) {
  $pending = @(Get-IncompleteTransactions @(Read-Events))
  if (-not $Write) { return [pscustomobject]@{ ok=$true; action='Reconcile'; applied=$false; pendingCount=$pending.Count; recoveredCount=0; blockedCount=0; transactions=@($pending | ForEach-Object { $_.transactionId }); guard='Dry run only; use -Apply to reconcile prepared transactions.' } }
  $recovered = @()
  $blocked = @()
  foreach ($prepare in $pending) {
    $result = Invoke-SuperBrainFileLock $mutationGate { Complete-PreparedTransaction $prepare }
    if ($result.ok) { $recovered += $result } else { $blocked += $result }
  }
  return [pscustomobject]@{ ok=($blocked.Count -eq 0); action='Reconcile'; applied=$true; pendingCount=$pending.Count; recoveredCount=$recovered.Count; blockedCount=$blocked.Count; recovered=@($recovered); blocked=@($blocked); guard='Reconcile completes only the original task transaction and never merges task IDs.' }
}

function Compact-Store([switch]$Write) {
  if ($MaxEventsPerTask -lt 2) { throw 'TASK_STATE_COMPACT_MAX_EVENTS_MINIMUM: 2' }
  if ($MaxBytesPerTask -lt 1024) { throw 'TASK_STATE_COMPACT_MAX_BYTES_MINIMUM: 1024' }
  $pendingByTask = @{}
  foreach ($transaction in @(Get-IncompleteTransactions @(Read-Events))) {
    $pendingByTask[[string]$transaction.taskId] = @($pendingByTask[[string]$transaction.taskId]) + $transaction
  }
  $candidates = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $eventRoot -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
    $count = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8).Count
    if ($count -gt $MaxEventsPerTask -or $file.Length -gt $MaxBytesPerTask) {
      $taskIds = @(
        Get-Content -LiteralPath $file.FullName -Encoding UTF8 |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          ForEach-Object { try { [string](($_ | ConvertFrom-Json).taskId) } catch { '' } } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          Select-Object -Unique
      )
      $candidateTaskId = if ($taskIds.Count -eq 1) { [string]$taskIds[0] } else { '' }
      $pendingCount = if ($pendingByTask.ContainsKey($candidateTaskId)) { @($pendingByTask[$candidateTaskId]).Count } else { 0 }
      $blockReason = if ($taskIds.Count -ne 1) { 'mixed_task_identity' } elseif ($pendingCount -gt 0) { 'incomplete_transaction' } else { '' }
      $candidates += [pscustomobject]@{ path=$file.FullName; taskId=$candidateTaskId; taskIds=@($taskIds); events=$count; bytes=$file.Length; blocked=(-not [string]::IsNullOrWhiteSpace($blockReason)); blockReason=$blockReason; pendingTransactionCount=$pendingCount }
    }
  }
  $initialBlocked = @($candidates | Where-Object { $_.blocked })
  if (-not $Write) { return [pscustomobject]@{ ok=$true; action='Compact'; applied=$false; candidateCount=$candidates.Count; eligibleCount=($candidates.Count-$initialBlocked.Count); blockedCount=$initialBlocked.Count; compactedCount=0; candidates=@($candidates); guard='Dry run only; reconcile incomplete transactions before using -Apply to archive event segments and write replayable snapshots.' } }
  $compacted = @()
  $blocked = @($initialBlocked | ForEach-Object { [pscustomobject]@{ taskId=$_.taskId; reason=$_.blockReason; pendingTransactionCount=$_.pendingTransactionCount; taskIds=@($_.taskIds) } })
  foreach ($candidate in @($candidates | Where-Object { -not $_.blocked })) {
    $item = Invoke-SuperBrainFileLock $mutationGate {
      $livePending = @(Get-IncompleteTransactions @(Read-Events) | Where-Object { [string]$_.taskId -eq [string]$candidate.taskId })
      if ($livePending.Count -gt 0) { return [pscustomobject]@{ compacted=$false; taskId=$candidate.taskId; reason='incomplete_transaction'; pendingTransactionCount=$livePending.Count } }
      $projection = Get-Projection ([string]$candidate.taskId)
      if (-not $projection) { throw "TASK_STATE_COMPACT_PROJECTION_MISSING taskId=$($candidate.taskId)" }
      $safe = Get-SuperBrainCanonicalTaskToken ([string]$candidate.taskId)
      $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
      $taskArchive = Join-Path $archiveRoot $safe
      $taskSnapshots = Join-Path $snapshotRoot $safe
      foreach ($dir in @($taskArchive,$taskSnapshots)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
      $archivePath = Join-Path $taskArchive ("$stamp-r$($projection.revision).jsonl")
      $snapshotPath = Join-Path $taskSnapshots ("r$($projection.revision)-$stamp.json")
      Write-JsonUtf8NoBom $snapshotPath ([pscustomobject]@{ schema='super-brain.task-state-snapshot.v1'; taskId=$candidate.taskId; baseRevision=[int]$projection.revision; compactedAt=(Get-Date).ToString('o'); projection=$projection; archivedEventHash=Get-FileSha256 $candidate.path }) 12
      Move-Item -LiteralPath $candidate.path -Destination $archivePath
      $snapshotEvent = [pscustomobject]@{ schema='super-brain.task-state-event.v2'; phase='snapshot'; transactionId=''; eventId=[guid]::NewGuid().ToString('n'); taskId=$candidate.taskId; revision=[int]$projection.revision; previousRevision=0; projection=$projection; source='task-state-store.ps1:compact'; recordedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') }
      Write-Utf8NoBom $candidate.path (($snapshotEvent | ConvertTo-Json -Depth 12 -Compress) + "`n")
      return [pscustomobject]@{ compacted=$true; taskId=$candidate.taskId; revision=[int]$projection.revision; archivedPath=$archivePath; snapshotPath=$snapshotPath; beforeEvents=$candidate.events; beforeBytes=$candidate.bytes; afterEvents=1 }
    }
    if ($item.compacted) { $compacted += $item } else { $blocked += $item }
  }
  return [pscustomobject]@{ ok=$true; action='Compact'; applied=$true; candidateCount=$candidates.Count; eligibleCount=($candidates.Count-$blocked.Count); blockedCount=$blocked.Count; compactedCount=$compacted.Count; compacted=@($compacted); blocked=@($blocked); guard='Old segments are archived, not deleted; active journals restart from replayable metadata-only snapshots; incomplete transactions are never compacted.' }
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
  $imported = 0; $unchanged = 0; $invalid = @()
  foreach ($candidate in $candidates) {
    $entity = Read-JsonFile $candidate.path
    $id = if ($entity) { [string]$entity.taskId } else { '' }
    if ([string]::IsNullOrWhiteSpace($id)) { $invalid += $candidate.path; continue }
    if ($Write) { $record = Record-Entity $id $candidate.kind 'upsert' $candidate.path -1 ('import:' + $candidate.source) -Override -Reason 'Import current task-scoped state into the append-only store.'; if ($record.changed) { $imported++ } else { $unchanged++ } }
  }
  return [pscustomobject]@{ ok=($invalid.Count -eq 0); action='Import'; applied=[bool]$Write; candidates=$candidates.Count; imported=$imported; unchanged=$unchanged; invalidPaths=@($invalid); audit=if($Write){Get-AuditResult}else{$null}; guard=if($Write){'Imported task-scoped files as separate projections; compatibility pointers were not modified.'}else{'Dry run only; use -Apply to import current state.'} }
}

try {
  $result = switch ($Action) {
    'Record' { Record-Entity $TaskId $EntityKind $Operation $EntityPath $ExpectedRevision $Source -Override:$MaintenanceOverride -Reason $MaintenanceReason }
    'Commit' { Commit-Entity $TaskId $EntityKind $Operation $EntityPath $PayloadPath $ExpectedRevision $Source -Override:$MaintenanceOverride -Reason $MaintenanceReason }
    'Get' { Get-Projection $TaskId }
    'Audit' { Get-AuditResult }
    'Rebuild' { Rebuild-Store -Write:$Apply }
    'Reconcile' { Reconcile-Store -Write:$Apply }
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
