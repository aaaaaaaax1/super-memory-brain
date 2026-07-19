param(
  [switch]$Json,
  [switch]$ApplySafe,
  [int]$AgentBridgeTtlMinutes = 120,
  [int]$StaleLockSeconds = 120,
  [int]$DraftMaxAgeDays = 7,
  [int]$MaxWorkspaceJsonMB = 16,
  [int]$TaskStateMaxEventsPerTask = 200,
  [long]$TaskStateMaxBytesPerTask = 1048576
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
$bridgeRoot = Join-Path $workspace 'agent-bridge'
$channelsRoot = Join-Path $bridgeRoot 'channels'
$bridgeArchiveRoot = Join-Path $bridgeRoot 'archive'
$lifecycleArchiveRoot = Join-Path $workspace 'lifecycle-archive'
foreach ($dir in @($workspace,$bridgeRoot,$channelsRoot,$bridgeArchiveRoot,$lifecycleArchiveRoot)) {
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}
$outPath = Join-Path $workspace 'last-workspace-lifecycle.json'

$actions = New-Object System.Collections.ArrayList
$errors = New-Object System.Collections.ArrayList
$now = Get-Date
$stamp = $now.ToString('yyyyMMdd-HHmmss')

function Limit-Text([string]$Value, [int]$Max = 300) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return [pscustomobject]@{ parseFailed=$true; error=$_.Exception.Message } }
}

function Test-PrivateRisk([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return ($Text -match '(?i)(api[_-]?key|client[_-]?secret|password\s*[=:]|access[_-]?token\s*[=:]|refresh[_-]?token\s*[=:]|bearer\s+[A-Za-z0-9._-]+|sk-[A-Za-z0-9]|BEGIN .*PRIVATE KEY)')
}

function Add-Action([string]$Type, [string]$Target, [string]$Action, [string]$Reason, [bool]$Applied = $false, [string]$Destination = '', [string]$Risk = 'low') {
  $item = [pscustomobject]@{
    type = $Type
    target = $Target
    action = $Action
    reason = Limit-Text $Reason 420
    risk = $Risk
    applied = $Applied
    destination = $Destination
  }
  [void]$script:actions.Add($item)
}

function Add-Error([string]$Where, [string]$Message) {
  [void]$script:errors.Add([pscustomobject]@{ where=$Where; message=Limit-Text $Message 500 })
}

function Test-ExpiredAt([object]$Value, [string]$PropertyName = 'expiresAt') {
  if (-not $Value) { return $false }
  $raw = ''
  try { $raw = [string]$Value.$PropertyName } catch { $raw = '' }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
  try { return ([datetime]::Parse($raw) -lt (Get-Date)) } catch { return $true }
}

function Get-ChannelExpired([object]$Channel) {
  if (-not $Channel) { return $false }
  if ([string]$Channel.status -eq 'closed') { return $true }
  if ($Channel.expiresAt) { return Test-ExpiredAt $Channel 'expiresAt' }
  $ttl = $AgentBridgeTtlMinutes
  if ($Channel.ttlMinutes) { try { $ttl = [int]$Channel.ttlMinutes } catch {} }
  if (-not $Channel.createdAt) { return $false }
  try { return (((Get-Date) - [datetime]::Parse([string]$Channel.createdAt)).TotalMinutes -gt $ttl) } catch { return $false }
}

function Archive-JsonObject([string]$ArchivePath, [object]$Object) {
  $dir = Split-Path -Parent $ArchivePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Write-JsonUtf8NoBom $ArchivePath $Object 14
}

# Session binding lifecycle.
$bindingPath = Join-Path $workspace 'session-binding.json'
if (Test-Path -LiteralPath $bindingPath) {
  $binding = Read-JsonFile $bindingPath
  if ($binding -and $binding.parseFailed) {
    Add-Action 'session_binding' $bindingPath 'requires_confirmation' 'session-binding.json cannot be parsed; automatic deletion is refused.' $false '' 'medium'
  } else {
    $expired = Test-ExpiredAt $binding 'expiresAt'
    $versionMismatch = ($binding -and [string]$binding.packageVersion -and [string]$binding.packageVersion -ne [string]$manifest.version)
    $rootMismatch = ($binding -and [string]$binding.memoryRoot -and -not (Test-SuperBrainSamePath ([string]$binding.memoryRoot) $memoryRoot))
    $inactive = ($binding -and [string]$binding.status -ne 'active')
    $rawRisk = Test-PrivateRisk ($binding | ConvertTo-Json -Depth 14 -Compress)
    if ($expired -or $versionMismatch -or $rootMismatch -or $inactive) {
      $reasonParts = @()
      if ($expired) { $reasonParts += 'expired' }
      if ($versionMismatch) { $reasonParts += 'version_mismatch' }
      if ($rootMismatch) { $reasonParts += 'memory_root_mismatch' }
      if ($inactive) { $reasonParts += 'inactive' }
      if ($rawRisk) {
        Add-Action 'session_binding' $bindingPath 'requires_confirmation' ('session binding has raw/private risk and was not archived or removed: ' + ($reasonParts -join ',')) $false '' 'high'
      } else {
        $archivePath = Join-Path (Join-Path $lifecycleArchiveRoot 'session-binding') ('session-binding-' + $stamp + '.json')
        if ($ApplySafe) {
          try {
            Archive-JsonObject $archivePath $binding
            Remove-Item -LiteralPath $bindingPath -Force -ErrorAction Stop
            Add-Action 'session_binding' $bindingPath 'archive_and_remove' ($reasonParts -join ',') $true $archivePath 'low'
          } catch { Add-Error 'session_binding' $_.Exception.Message; Add-Action 'session_binding' $bindingPath 'archive_and_remove_failed' ($reasonParts -join ',') $false $archivePath 'medium' }
        } else {
          Add-Action 'session_binding' $bindingPath 'would_archive_and_remove' ($reasonParts -join ',') $false $archivePath 'low'
        }
      }
    }
  }
}

# Agent Bridge channel lifecycle.
$channelArchiveDir = Join-Path $bridgeArchiveRoot ('channels-cleanup-' + $stamp)
$expiredChannelIds = @()
if (Test-Path -LiteralPath $channelsRoot) {
  foreach ($file in @(Get-ChildItem -LiteralPath $channelsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $channel = Read-JsonFile $file.FullName
    if ($channel -and $channel.parseFailed) {
      Add-Action 'agent_bridge_channel' $file.FullName 'requires_confirmation' 'Channel JSON parse failed; automatic archive refused.' $false '' 'medium'
      continue
    }
    if (Get-ChannelExpired $channel) {
      $channelId = if ($channel.channelId) { [string]$channel.channelId } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
      $expiredChannelIds += $channelId
      $dest = Join-Path $channelArchiveDir $file.Name
      if ($ApplySafe) {
        try {
          if (-not (Test-Path -LiteralPath $channelArchiveDir)) { New-Item -ItemType Directory -Force -Path $channelArchiveDir | Out-Null }
          Move-Item -LiteralPath $file.FullName -Destination $dest -Force -ErrorAction Stop
          Add-Action 'agent_bridge_channel' $file.FullName 'archive_channel_file' ('status=' + [string]$channel.status) $true $dest 'low'
        } catch { Add-Error 'agent_bridge_channel' $_.Exception.Message; Add-Action 'agent_bridge_channel' $file.FullName 'archive_channel_failed' $_.Exception.Message $false $dest 'medium' }
      } else {
        Add-Action 'agent_bridge_channel' $file.FullName 'would_archive_channel_file' ('status=' + [string]$channel.status) $false $dest 'low'
      }
    }
  }
}

$activePath = Join-Path $bridgeRoot 'active-agent-bridge-channel.json'
if (Test-Path -LiteralPath $activePath) {
  $active = Read-JsonFile $activePath
  if ($active -and $active.parseFailed) {
    Add-Action 'agent_bridge_active_pointer' $activePath 'requires_confirmation' 'Active pointer JSON parse failed; automatic removal refused.' $false '' 'medium'
  } else {
    $activeExpired = Test-ExpiredAt $active 'expiresAt'
    $activeChannelId = if ($active.channelId) { [string]$active.channelId } else { '' }
    $channelPath = if ($activeChannelId) { Join-Path $channelsRoot (($activeChannelId -replace '[^A-Za-z0-9._-]','-').Trim('-').ToLowerInvariant() + '.json') } else { '' }
    $channelMissing = ([string]::IsNullOrWhiteSpace($channelPath) -or -not (Test-Path -LiteralPath $channelPath))
    if ($activeExpired -or $channelMissing -or ($expiredChannelIds -contains $activeChannelId)) {
      $archivePath = Join-Path (Join-Path $lifecycleArchiveRoot 'agent-bridge') ('active-agent-bridge-channel-' + $stamp + '.json')
      if ($ApplySafe) {
        try {
          Archive-JsonObject $archivePath $active
          Remove-Item -LiteralPath $activePath -Force -ErrorAction Stop
          Add-Action 'agent_bridge_active_pointer' $activePath 'archive_and_remove' 'expired_or_missing_channel' $true $archivePath 'low'
        } catch { Add-Error 'agent_bridge_active_pointer' $_.Exception.Message; Add-Action 'agent_bridge_active_pointer' $activePath 'archive_and_remove_failed' $_.Exception.Message $false $archivePath 'medium' }
      } else {
        Add-Action 'agent_bridge_active_pointer' $activePath 'would_archive_and_remove' 'expired_or_missing_channel' $false $archivePath 'low'
      }
    }
  }
}

# Stale known lock cleanup.
try {
  foreach ($lock in @(Get-SuperBrainKnownLockStatuses $Root $StaleLockSeconds | Where-Object { $_.stale -eq $true })) {
    if ($ApplySafe) {
      try {
        Remove-Item -LiteralPath $lock.lock -Force -ErrorAction Stop
        Add-Action 'stale_lock' $lock.lock 'remove_stale_lock_file' ('ageSeconds=' + [string]$lock.ageSeconds) $true '' 'low'
      } catch { Add-Error 'stale_lock' $_.Exception.Message; Add-Action 'stale_lock' $lock.lock 'remove_stale_lock_failed' $_.Exception.Message $false '' 'medium' }
    } else {
      Add-Action 'stale_lock' $lock.lock 'would_remove_stale_lock_file' ('ageSeconds=' + [string]$lock.ageSeconds) $false '' 'low'
    }
  }
} catch { Add-Error 'stale_lock_scan' $_.Exception.Message }

# Workspace temp files. Only generated temp files are deleted automatically.
try {
  foreach ($tmp in @(Get-ChildItem -LiteralPath $workspace -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.tmp.*' -and (($now - $_.LastWriteTime).TotalDays -gt 1) })) {
    if ($ApplySafe) {
      try {
        Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction Stop
        Add-Action 'workspace_tmp' $tmp.FullName 'remove_temp_file' 'generated tmp file older than one day' $true '' 'low'
      } catch { Add-Error 'workspace_tmp' $_.Exception.Message; Add-Action 'workspace_tmp' $tmp.FullName 'remove_temp_file_failed' $_.Exception.Message $false '' 'medium' }
    } else {
      Add-Action 'workspace_tmp' $tmp.FullName 'would_remove_temp_file' 'generated tmp file older than one day' $false '' 'low'
    }
  }
} catch { Add-Error 'workspace_tmp_scan' $_.Exception.Message }

# Task-state WAL maintenance stays on this cold lifecycle path. ApplySafe first
# reconciles prepared transactions, then archives only replayable event segments.
try {
  $reconcilePlan = Invoke-SuperBrainTaskStateStore @{ Action='Reconcile' }
  if ([int]$reconcilePlan.pendingCount -gt 0) {
    if ($ApplySafe) {
      $reconcile = Invoke-SuperBrainTaskStateStore @{ Action='Reconcile'; Apply=$true }
      Add-Action 'task_state_reconcile' (Join-Path $workspace 'task-state-store') 'reconcile_prepared_transactions' ("pending=$($reconcile.pendingCount); recovered=$($reconcile.recoveredCount)") $true '' 'low'
    } else {
      Add-Action 'task_state_reconcile' (Join-Path $workspace 'task-state-store') 'would_reconcile_prepared_transactions' ("pending=$($reconcilePlan.pendingCount)") $false '' 'low'
    }
  }

  $compactParameters = @{ Action='Compact'; MaxEventsPerTask=$TaskStateMaxEventsPerTask; MaxBytesPerTask=$TaskStateMaxBytesPerTask }
  if ($ApplySafe) { $compactParameters.Apply = $true }
  $compact = Invoke-SuperBrainTaskStateStore $compactParameters
  if ($ApplySafe) {
    foreach ($item in @($compact.compacted)) {
      Add-Action 'task_state_journal' ([string]$item.taskId) 'archive_and_snapshot' ("events=$($item.beforeEvents); bytes=$($item.beforeBytes); revision=$($item.revision)") $true ([string]$item.archivedPath) 'low'
    }
  } else {
    foreach ($item in @($compact.candidates | Where-Object { -not $_.blocked })) {
      Add-Action 'task_state_journal' ([string]$item.taskId) 'would_archive_and_snapshot' ("events=$($item.events); bytes=$($item.bytes)") $false '' 'low'
    }
  }
  foreach ($item in @($(if($ApplySafe){$compact.blocked}else{$compact.candidates | Where-Object {$_.blocked}}))) {
    Add-Action 'task_state_journal' ([string]$item.taskId) 'blocked_pending_transaction' ("pending=$($item.pendingTransactionCount); reconcile before compaction") $false '' 'medium'
  }
} catch {
  Add-Error 'task_state_maintenance' $_.Exception.Message
  Add-Action 'task_state_store' (Join-Path $workspace 'task-state-store') 'maintenance_failed' $_.Exception.Message $false '' 'medium'
}

# Task lifecycle findings are read-only here. User task completion is never inferred
# from age or empty pending steps; only known diagnostic IDs are safe candidates.
try {
  $taskLifecycleRaw = @(& (Join-Path $PSScriptRoot 'task-lifecycle-audit.ps1') -Json 2>$null)
  if ($LASTEXITCODE -ne 0) { throw 'task lifecycle audit failed' }
  $taskLifecycle = (($taskLifecycleRaw -join "`n") | ConvertFrom-Json)
  foreach ($item in @($taskLifecycle.diagnosticCards)) {
    Add-Action 'diagnostic_task_state' ([string]$item.sourcePath) 'requires_confirmation' ("known diagnostic task state should be archived from the formal memory root; taskId=$($item.taskId)") $false '' 'low'
  }
  foreach ($item in @($taskLifecycle.staleUnboundActiveCards | Where-Object { -not $_.diagnostic })) {
    Add-Action 'stale_unbound_task' ([string]$item.sourcePath) 'requires_confirmation' ("active task has no current checkpoint/context/contract binding; taskId=$($item.taskId); ageDays=$($item.ageDays)") $false '' 'medium'
  }
  foreach ($item in @($taskLifecycle.zeroPendingActiveCards | Where-Object { -not $_.diagnostic -and $_.bound })) {
    Add-Action 'zero_pending_active_task' ([string]$item.sourcePath) 'requires_confirmation' ("active task has no pending steps but remains bound; taskId=$($item.taskId)") $false '' 'medium'
  }
} catch {
  Add-Error 'task_lifecycle_audit' $_.Exception.Message
  Add-Action 'task_lifecycle_audit' (Join-Path $workspace 'last-task-lifecycle-audit.json') 'audit_failed' $_.Exception.Message $false '' 'medium'
}

# Oversized JSON commonly indicates accidental serialization of PowerShell provider objects.
try {
  $maxWorkspaceJsonBytes = [Math]::Max(1, $MaxWorkspaceJsonMB) * 1MB
  foreach ($file in @(Get-ChildItem -LiteralPath $workspace -File -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt $maxWorkspaceJsonBytes })) {
    Add-Action 'oversized_workspace_json' $file.FullName 'requires_confirmation' ("workspace JSON is $([Math]::Round($file.Length/1MB,2)) MB; archive and replace it with a compact evidence pointer after hash verification") $false '' 'medium'
  }
} catch { Add-Error 'oversized_workspace_json_scan' $_.Exception.Message }

# Drafts are evidence, so old drafts are reported but not moved without an explicit confirmed cleanup.
$draftRoot = Join-Path $workspace 'learning-drafts'
if (Test-Path -LiteralPath $draftRoot) {
  foreach ($draft in @(Get-ChildItem -LiteralPath $draftRoot -File -ErrorAction SilentlyContinue | Where-Object { (($now - $_.LastWriteTime).TotalDays -gt $DraftMaxAgeDays) })) {
    Add-Action 'learning_draft' $draft.FullName 'requires_confirmation' ('draft older than ' + $DraftMaxAgeDays + ' days; evidence files are not moved automatically') $false '' 'low'
  }
}

$appliedCount = @($actions | Where-Object { $_.applied -eq $true }).Count
$requiresConfirmation = @($actions | Where-Object { $_.action -eq 'requires_confirmation' }).Count
$result = [pscustomobject]@{
  ok = ($errors.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.workspace-lifecycle.v1'
  version = [string]$manifest.version
  mode = if ($ApplySafe) { 'ApplySafe' } else { 'Plan' }
  packageRoot = $Root
  memoryRoot = $memoryRoot
  actionCount = $actions.Count
  appliedCount = $appliedCount
  requiresConfirmation = $requiresConfirmation
  errorCount = $errors.Count
  actions = @($actions)
  errors = @($errors)
  policy = [pscustomobject]@{
    archiveExpiredSessionBinding = $true
    archiveExpiredAgentBridgeChannels = $true
    clearExpiredActiveAgentBridgePointer = $true
    removeStaleLocks = $true
    deleteGeneratedTmpFilesOnly = $true
    reconcilePreparedTaskStateTransactions = $true
    archiveTaskStateJournalsBehindSnapshots = $true
    auditDiagnosticAndOrphanTaskState = $true
    neverInferUserTaskCompletionFromAge = $true
    oversizedWorkspaceJsonRequiresConfirmation = $true
    learningDraftsRequireConfirmation = $true
  }
}
Write-JsonUtf8NoBom $outPath $result 14
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else {
  Write-Host "WORKSPACE_LIFECYCLE ok=$($result.ok) mode=$($result.mode) actions=$($result.actionCount) applied=$($result.appliedCount) requiresConfirmation=$($result.requiresConfirmation) errors=$($result.errorCount) path=$outPath"
}
if ($errors.Count -gt 0) { exit 1 }
exit 0
