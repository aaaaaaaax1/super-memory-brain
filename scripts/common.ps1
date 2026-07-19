$SuperBrainRoot = Split-Path -Parent $PSScriptRoot

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Get-SuperBrainStableHash([string]$Value,[int]$Length = 16) {
  if ([string]::IsNullOrWhiteSpace($Value)) { throw 'SUPER_BRAIN_HASH_VALUE_REQUIRED' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hex = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Value)) | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0,[Math]::Min($Length,$hex.Length))
  } finally {
    $sha.Dispose()
  }
}

function Get-SuperBrainHostSessionKey([string]$SessionId = '') {
  $candidate = $SessionId
  if ([string]::IsNullOrWhiteSpace($candidate) -and -not [string]::IsNullOrWhiteSpace($env:CODEX_THREAD_ID)) { $candidate = [string]$env:CODEX_THREAD_ID }
  if ([string]::IsNullOrWhiteSpace($candidate)) { return '' }
  $candidate = $candidate.Trim()
  if ($candidate -match '^sid-[0-9a-f]{16,64}$') { return $candidate.ToLowerInvariant() }
  return 'sid-' + (Get-SuperBrainStableHash $candidate 24)
}

function Get-SuperBrainCanonicalTaskToken([string]$TaskId) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $safe = (([string]$TaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'task' }
  if ($safe.Length -gt 96) { $safe = $safe.Substring(0,96).TrimEnd('-') }
  return $safe + '--' + (Get-SuperBrainStableHash ([string]$TaskId) 16)
}

function Get-SuperBrainCanonicalTaskFileName([string]$TaskId,[string]$Suffix = '.json') {
  if ([string]::IsNullOrWhiteSpace($Suffix)) { throw 'TASK_STATE_SUFFIX_REQUIRED' }
  return (Get-SuperBrainCanonicalTaskToken $TaskId) + $Suffix
}

function Get-SuperBrainCanonicalTaskPath([string]$Root,[string]$TaskId,[string]$Suffix = '.json') {
  if ([string]::IsNullOrWhiteSpace($Root)) { throw 'TASK_STATE_ROOT_REQUIRED' }
  return Join-Path ([System.IO.Path]::GetFullPath($Root)) (Get-SuperBrainCanonicalTaskFileName $TaskId $Suffix)
}

function Test-SuperBrainChildPath([string]$Parent,[string]$Child) {
  try {
    $prefix = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::GetFullPath($Child).StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function Get-SuperBrainCanonicalTaskStateEntityPath(
  [string]$TaskId,
  [ValidateSet('context','checkpoint','task_card')][string]$EntityKind,
  [string]$WorkspaceRoot,
  [string]$SharedRoot,
  [string]$RequestedPath = '',
  [switch]$RequireCanonical
) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $workspace = [System.IO.Path]::GetFullPath($WorkspaceRoot)
  $shared = [System.IO.Path]::GetFullPath($SharedRoot)
  $roots = @()
  $suffix = '.json'
  switch ($EntityKind) {
    'context' { $roots = @(Join-Path $workspace 'guard-state\current-task-contexts') }
    'checkpoint' {
      $roots = @(
        (Join-Path $workspace 'runtime-state\checkpoints\active'),
        (Join-Path $workspace 'runtime-state\checkpoints\completed')
      )
    }
    'task_card' {
      $suffix = '.task.json'
      $roots = @('active','paused','blocked','completed' | ForEach-Object { Join-Path $shared (Join-Path 'tasks' $_) })
    }
  }
  $requested = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { '' } else { [System.IO.Path]::GetFullPath($RequestedPath) }
  $targetRoot = $null
  if ($requested) {
    foreach ($candidate in $roots) {
      if (Test-SuperBrainChildPath $candidate $requested) { $targetRoot = $candidate; break }
    }
    if (-not $targetRoot) { throw "TASK_STATE_TARGET_OUTSIDE_ROOT kind=$EntityKind path=$requested" }
  } elseif ($roots.Count -eq 1) {
    $targetRoot = $roots[0]
  } else {
    throw "TASK_STATE_TARGET_PATH_REQUIRED kind=$EntityKind"
  }
  $expected = Get-SuperBrainCanonicalTaskPath $targetRoot $TaskId $suffix
  if ($RequireCanonical -and -not [string]::Equals($requested,$expected,[System.StringComparison]::OrdinalIgnoreCase)) {
    throw "TASK_STATE_TARGET_TASK_MISMATCH expected=$expected actual=$requested taskId=$TaskId"
  }
  return $expected
}

function Get-SuperBrainTaskStateOwnerInput(
  [object]$EntityValue = $null,
  [string]$AgentId = '',
  [string]$SessionId = '',
  [string]$Platform = '',
  [string]$Workspace = ''
) {
  if ($EntityValue) {
    if ([string]::IsNullOrWhiteSpace($AgentId) -and $EntityValue.PSObject.Properties['agentId']) { $AgentId = [string]$EntityValue.agentId }
    if ([string]::IsNullOrWhiteSpace($SessionId) -and $EntityValue.PSObject.Properties['sessionId']) { $SessionId = [string]$EntityValue.sessionId }
    if ([string]::IsNullOrWhiteSpace($Platform) -and $EntityValue.PSObject.Properties['platform']) { $Platform = [string]$EntityValue.platform }
    if ([string]::IsNullOrWhiteSpace($Workspace) -and $EntityValue.PSObject.Properties['workspace']) { $Workspace = [string]$EntityValue.workspace }
  }
  if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = Get-NormalizedSuperBrainRoot $SuperBrainRoot }
  else { try { $Workspace = [System.IO.Path]::GetFullPath($Workspace).TrimEnd('\','/') } catch { $Workspace = $Workspace.Trim() } }
  if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = if ($env:SUPER_BRAIN_PLATFORM) { [string]$env:SUPER_BRAIN_PLATFORM } else { 'zcode' } }
  if ([string]::IsNullOrWhiteSpace($AgentId)) { $AgentId = if ($env:SUPER_BRAIN_AGENT_ID) { [string]$env:SUPER_BRAIN_AGENT_ID } else { ([string]$Platform).ToLowerInvariant() + '-agent' } }
  if ([string]::IsNullOrWhiteSpace($SessionId)) {
    $SessionId = if ($env:SUPER_BRAIN_SESSION_ID) { [string]$env:SUPER_BRAIN_SESSION_ID } else { 'session-' + (Get-SuperBrainStableHash ("$AgentId|$Platform|$Workspace") 16) }
  }
  return [pscustomobject]@{ agentId=$AgentId.Trim(); sessionId=$SessionId.Trim(); platform=$Platform.Trim(); workspace=$Workspace }
}

function Get-NormalizedSuperBrainRoot([string]$Root = $SuperBrainRoot) {
  return ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\','/')
}

function Get-SuperBrainWorkspaceKey([string]$Workspace = '') {
  $value = $Workspace
  if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_WORKSPACE_KEY)) {
    $value = $env:SUPER_BRAIN_WORKSPACE_KEY
  }
  if ([string]::IsNullOrWhiteSpace($value)) { $value = (Get-Location).Path }
  $value = ([string]$value).Trim()
  if ($value -match '^ws-[0-9a-f]{24}$') { return $value.ToLowerInvariant() }
  try { $value = [System.IO.Path]::GetFullPath($value).TrimEnd('\','/') } catch {}
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($value.ToLowerInvariant()))
    return 'ws-' + (-join ($hash[0..11] | ForEach-Object { $_.ToString('x2') }))
  } finally {
    $sha.Dispose()
  }
}

function Test-SuperBrainWorkspaceKey([string]$RecordedKey,[string]$CurrentKey = '') {
  if ([string]::IsNullOrWhiteSpace($RecordedKey)) { return $false }
  $current = Get-SuperBrainWorkspaceKey $CurrentKey
  $recorded = Get-SuperBrainWorkspaceKey $RecordedKey
  return $recorded.Equals($current,[System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SuperBrainRelevantCheckpoint([string]$WorkspaceRoot,[object]$CurrentTaskContext = $null,[string]$WorkspaceKey = '',[string]$ExpectedTaskId = '') {
  $currentKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  function Read-ContinuityJson([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  }
  function Get-ContinuityTaskSafeId([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $safe = (($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0,120) }
    return $safe
  }

  $context = $CurrentTaskContext
  $contextActive = ($context -and [string]$context.status -eq 'active' -and $context.stale -ne $true -and -not [string]::IsNullOrWhiteSpace([string]$context.taskId))
  if ($contextActive -and $context.expiresAt) {
    try { $contextActive = ([datetime]::Parse([string]$context.expiresAt) -gt (Get-Date)) } catch { $contextActive = $false }
  }
  $contextKey = if ($context -and $context.PSObject.Properties['workspaceKey']) { [string]$context.workspaceKey } else { '' }
  $contextState = if (-not $contextActive) { 'none' } elseif ([string]::IsNullOrWhiteSpace($contextKey)) { 'legacy_unscoped' } elseif (Test-SuperBrainWorkspaceKey $contextKey $currentKey) { 'relevant' } else { 'foreign_workspace' }
  $relevantContext = if ($contextState -eq 'relevant') { $context } else { $null }

  $expectedTask = if (-not [string]::IsNullOrWhiteSpace($ExpectedTaskId)) { $ExpectedTaskId.Trim() } elseif ($relevantContext) { [string]$relevantContext.taskId } else { '' }
  $candidateLocations = @()
  if (-not [string]::IsNullOrWhiteSpace($expectedTask)) {
    $checkpointRoot = Join-Path $WorkspaceRoot 'runtime-state\checkpoints\active'
    $candidateLocations += [pscustomobject]@{ path=(Get-SuperBrainCanonicalTaskPath $checkpointRoot $expectedTask '.json'); source='runtime-state/checkpoints/active' }
    $safeTaskId = Get-ContinuityTaskSafeId $expectedTask
    if (-not [string]::IsNullOrWhiteSpace($safeTaskId)) {
      $candidateLocations += [pscustomobject]@{ path=(Join-Path $checkpointRoot ($safeTaskId + '.json')); source='runtime-state/checkpoints/active' }
    }
  }
  $candidateLocations += [pscustomobject]@{ path=(Join-Path $WorkspaceRoot 'active-checkpoint.json'); source='active-checkpoint.json' }

  $candidateRecords = @()
  $seenPaths = @{}
  foreach ($location in $candidateLocations) {
    $pathKey = try { [IO.Path]::GetFullPath([string]$location.path).ToLowerInvariant() } catch { ([string]$location.path).ToLowerInvariant() }
    if ($seenPaths.ContainsKey($pathKey)) { continue }
    $seenPaths[$pathKey] = $true
    $item = Read-ContinuityJson ([string]$location.path)
    if (-not $item) { continue }

    $itemTaskId = [string]$item.taskId
    $itemKey = if ($item.PSObject.Properties['workspaceKey']) { [string]$item.workspaceKey } else { '' }
    $itemState = 'none'
    if ([string]$item.status -ne 'active') {
      $itemState = 'inactive'
    } elseif (-not [string]::IsNullOrWhiteSpace($expectedTask) -and $itemTaskId -ne $expectedTask) {
      $itemState = 'parallel_unselected'
    } elseif (-not [string]::IsNullOrWhiteSpace($itemKey)) {
      $itemState = if (Test-SuperBrainWorkspaceKey $itemKey $currentKey) { 'relevant' } else { 'foreign_workspace' }
    } elseif (-not [string]::IsNullOrWhiteSpace($expectedTask) -and $itemTaskId -eq $expectedTask) {
      $itemState = 'legacy_compatible'
    } else {
      $itemState = 'legacy_unscoped'
    }
    $candidateRecords += [pscustomobject]@{ value=$item; source=[string]$location.source; state=$itemState }
  }

  # Exact workspace evidence always wins, even when an earlier task-scoped file is legacy or foreign.
  $selectedRecord = @($candidateRecords | Where-Object { $_.state -eq 'relevant' } | Select-Object -First 1)
  if ($selectedRecord.Count -eq 0) {
    $selectedRecord = @($candidateRecords | Where-Object { $_.state -eq 'legacy_compatible' } | Select-Object -First 1)
  }
  $selectedRecord = if ($selectedRecord.Count -gt 0) { $selectedRecord[0] } else { $null }
  $diagnosticRecord = $selectedRecord
  if (-not $diagnosticRecord) {
    foreach ($diagnosticState in @('foreign_workspace','parallel_unselected','legacy_unscoped','inactive')) {
      $match = @($candidateRecords | Where-Object { $_.state -eq $diagnosticState } | Select-Object -First 1)
      if ($match.Count -gt 0) { $diagnosticRecord = $match[0]; break }
    }
  }
  $state = if ($selectedRecord) { [string]$selectedRecord.state } elseif ($diagnosticRecord) { [string]$diagnosticRecord.state } else { 'none' }
  $selected = if ($selectedRecord) { $selectedRecord.value } else { $null }
  $candidate = if ($diagnosticRecord) { $diagnosticRecord.value } else { $null }
  $source = if ($diagnosticRecord) { [string]$diagnosticRecord.source } else { '' }

  return [pscustomobject]@{
    ok = $true
    state = $state
    contextState = $contextState
    workspaceKey = $currentKey
    source = $source
    checkpoint = $selected
    context = $relevantContext
    confidence = if ($state -eq 'relevant') { 'high' } elseif ($state -eq 'legacy_compatible') { 'low' } else { 'none' }
    legacyCompatibility = ($state -eq 'legacy_compatible')
    candidateCount = @($candidateRecords).Count
    candidateTaskId = if ($candidate) { [string]$candidate.taskId } else { '' }
    ignoredTaskId = if ($candidate -and -not $selected) { [string]$candidate.taskId } else { '' }
    guard = 'Exact task-and-workspace checkpoints outrank all compatibility pointers. A missing workspace key is low-confidence legacy evidence only; an explicit foreign workspace key is never inferred from task identity.'
  }
}

function Get-SuperBrainLockPath([string]$Path) {
  $full = [System.IO.Path]::GetFullPath($Path)
  return $full + '.lock'
}

function Invoke-SuperBrainFileLock([string]$Path, [scriptblock]$Body, [int]$TimeoutMs = 15000, [int]$StaleAfterSeconds = 120) {
  $lockPath = Get-SuperBrainLockPath $Path
  $lockDir = Split-Path -Parent $lockPath
  if (-not [string]::IsNullOrWhiteSpace($lockDir) -and -not (Test-Path $lockDir)) {
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
  }

  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  $lockStream = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      if (Test-Path $lockPath) {
        try {
          $age = (Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime
          if ($age.TotalSeconds -gt $StaleAfterSeconds) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
        } catch {}
      }
      $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      $lockInfo = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID acquiredAt=$((Get-Date).ToString('o')) path=$Path")
      $lockStream.Write($lockInfo, 0, $lockInfo.Length)
      $lockStream.Flush()
      break
    } catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 40
    }
  }

  if ($null -eq $lockStream) {
    throw "MEMORY_LOCK_TIMEOUT path=$Path lock=$lockPath timeoutMs=$TimeoutMs"
  }

  try {
    return & $Body
  } finally {
    try { $lockStream.Dispose() } catch {}
    try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  Invoke-SuperBrainFileLock $Path {
    $tmp = "$Path.tmp.$PID.$([Guid]::NewGuid().ToString('N'))"
    try {
      [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
      if (Test-Path $Path) {
        Move-Item -LiteralPath $tmp -Destination $Path -Force
      } else {
        Move-Item -LiteralPath $tmp -Destination $Path
      }
    } finally {
      if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
  } | Out-Null
}

function Add-Utf8LineLocked([string]$Path, [string]$Line) {
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  Invoke-SuperBrainFileLock $Path {
    $value = if ($Line.EndsWith("`n")) { $Line } else { $Line + "`n" }
    [System.IO.File]::AppendAllText($Path, $value, [System.Text.UTF8Encoding]::new($false))
  } | Out-Null
}

function Write-JsonUtf8NoBom([string]$Path, [object]$Value, [int]$Depth = 8, [switch]$Compress) {
  Write-Utf8NoBom $Path ($Value | ConvertTo-Json -Depth $Depth -Compress:$Compress)
}

function Invoke-SuperBrainTaskStateStore([hashtable]$Parameters) {
  $storeScript = Join-Path $PSScriptRoot 'task-state-store.ps1'
  if (-not (Test-Path -LiteralPath $storeScript)) { throw "TASK_STATE_STORE_SCRIPT_MISSING path=$storeScript" }
  $Parameters.Json = $true
  $raw = @(& $storeScript @Parameters 2>&1)
  $exitCode = $LASTEXITCODE
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n")
  if ($text.Trim() -eq 'null') {
    if ($exitCode -ne 0) { throw "TASK_STATE_STORE_SYNC_FAILED null result" }
    return $null
  }
  $start = $text.IndexOf('{')
  $end = $text.LastIndexOf('}')
  if ($start -lt 0 -or $end -lt $start) { throw "TASK_STATE_STORE_NO_JSON output=$text" }
  $result = $text.Substring($start,$end-$start+1) | ConvertFrom-Json
  if ($exitCode -ne 0 -or ($result.PSObject.Properties['ok'] -and $result.ok -ne $true)) {
    $detail = if ($result.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$result.error)) { [string]$result.error } else { $text }
    throw "TASK_STATE_STORE_SYNC_FAILED $detail"
  }
  return $result
}

function Get-SuperBrainTaskStateExpectedRevision([string]$TaskId) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $projection = Invoke-SuperBrainTaskStateStore @{ Action='Get'; TaskId=$TaskId }
  if (-not $projection) { return 0 }
  return [int]$projection.revision
}

function Set-SuperBrainTaskStatePayloadTargetPath([object]$EntityValue,[string]$RequestedPath,[string]$CanonicalPath) {
  if (-not $EntityValue) { return }
  foreach ($propertyName in @('path','sourcePath')) {
    $property = $EntityValue.PSObject.Properties[$propertyName]
    if ($property -and ([string]::IsNullOrWhiteSpace([string]$property.Value) -or [string]::Equals([string]$property.Value,$RequestedPath,[System.StringComparison]::OrdinalIgnoreCase))) {
      $EntityValue | Add-Member -NotePropertyName $propertyName -NotePropertyValue $CanonicalPath -Force
    }
  }
}

function Sync-SuperBrainTaskState(
  [string]$TaskId,
  [ValidateSet('context','checkpoint','task_card')][string]$EntityKind,
  [ValidateSet('upsert','clear')][string]$Operation,
  [string]$EntityPath,
  [string]$Source
) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  $parameters = @{ Action='Record'; TaskId=$TaskId; EntityKind=$EntityKind; Operation=$Operation; Source=$Source; MaintenanceOverride=$true; MaintenanceReason=('legacy sync: ' + $Source) }
  if (-not [string]::IsNullOrWhiteSpace($EntityPath)) { $parameters.EntityPath = $EntityPath }
  return Invoke-SuperBrainTaskStateStore $parameters
}

function Commit-SuperBrainTaskState(
  [string]$TaskId,
  [ValidateSet('context','checkpoint','task_card')][string]$EntityKind,
  [object]$EntityValue,
  [string]$EntityPath,
  [string]$Source,
  [ValidateSet('upsert','clear')][string]$Operation = 'upsert',
  [int]$ExpectedRevision = -1,
  [string]$OwnerWorkspace = '',
  [string]$OwnerAgentId = '',
  [string]$OwnerSessionId = '',
  [string]$OwnerPlatform = '',
  [switch]$MaintenanceOverride,
  [string]$MaintenanceReason = ''
) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'TASK_STATE_TASK_ID_REQUIRED' }
  if ($Operation -eq 'upsert' -and $null -eq $EntityValue) { throw 'TASK_STATE_ENTITY_VALUE_REQUIRED' }
  $root = Split-Path -Parent $PSScriptRoot
  $workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $root) 'workspace'
  $shared = Get-SuperBrainSharedMemoryRoot $root
  $canonicalPath = Get-SuperBrainCanonicalTaskStateEntityPath $TaskId $EntityKind $workspace $shared $EntityPath
  Set-SuperBrainTaskStatePayloadTargetPath $EntityValue $EntityPath $canonicalPath
  $stageDir = Join-Path (Join-Path $workspace 'task-state-store\staging') (Get-SuperBrainCanonicalTaskToken $TaskId)
  if (-not (Test-Path -LiteralPath $stageDir)) { New-Item -ItemType Directory -Force -Path $stageDir | Out-Null }
  $payloadPath = ''
  if ($null -ne $EntityValue) {
    $payloadPath = Join-Path $stageDir (([guid]::NewGuid().ToString('n')) + '.json')
    Write-JsonUtf8NoBom $payloadPath $EntityValue 12
  }
  $owner = Get-SuperBrainTaskStateOwnerInput $EntityValue $OwnerAgentId $OwnerSessionId $OwnerPlatform $OwnerWorkspace
  if ($ExpectedRevision -lt 0 -and -not $MaintenanceOverride) { $ExpectedRevision = Get-SuperBrainTaskStateExpectedRevision $TaskId }
  $parameters = @{ Action='Commit'; TaskId=$TaskId; EntityKind=$EntityKind; Operation=$Operation; EntityPath=$canonicalPath; Source=$Source; ExpectedRevision=$ExpectedRevision; OwnerAgentId=$owner.agentId; OwnerSessionId=$owner.sessionId; OwnerPlatform=$owner.platform; OwnerWorkspace=$owner.workspace; MaintenanceOverride=[bool]$MaintenanceOverride; MaintenanceReason=$MaintenanceReason }
  if ($payloadPath) { $parameters.PayloadPath = $payloadPath }
  return Invoke-SuperBrainTaskStateStore $parameters
}

function Clear-SuperBrainTaskState(
  [string]$TaskId,
  [ValidateSet('context','checkpoint','task_card')][string]$EntityKind,
  [string]$EntityPath,
  [string]$Source,
  [string]$OwnerWorkspace = '',
  [int]$ExpectedRevision = -1,
  [string]$OwnerAgentId = '',
  [string]$OwnerSessionId = '',
  [string]$OwnerPlatform = '',
  [switch]$MaintenanceOverride,
  [string]$MaintenanceReason = ''
) {
  return Commit-SuperBrainTaskState -TaskId $TaskId -EntityKind $EntityKind -EntityValue $null -EntityPath $EntityPath -Source $Source -Operation clear -ExpectedRevision $ExpectedRevision -OwnerWorkspace $OwnerWorkspace -OwnerAgentId $OwnerAgentId -OwnerSessionId $OwnerSessionId -OwnerPlatform $OwnerPlatform -MaintenanceOverride:$MaintenanceOverride -MaintenanceReason $MaintenanceReason
}

function Get-SuperBrainFileLockStatus([string]$Path, [int]$StaleAfterSeconds = 120) {
  $full = [System.IO.Path]::GetFullPath($Path)
  $lockPath = Get-SuperBrainLockPath $full
  $exists = Test-Path $lockPath
  $ageSeconds = 0
  $lastWriteTime = $null
  $preview = ''
  if ($exists) {
    try {
      $item = Get-Item -LiteralPath $lockPath
      $lastWriteTime = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
      $ageSeconds = [Math]::Round(((Get-Date) - $item.LastWriteTime).TotalSeconds, 2)
      try { $preview = ([System.IO.File]::ReadAllText($lockPath, [System.Text.Encoding]::UTF8)).Trim() } catch {}
      if ($preview.Length -gt 180) { $preview = $preview.Substring(0, 180) + '...' }
    } catch {}
  }
  return [pscustomobject]@{
    target = $full
    lock = $lockPath
    exists = $exists
    ageSeconds = $ageSeconds
    staleAfterSeconds = $StaleAfterSeconds
    stale = ($exists -and $ageSeconds -gt $StaleAfterSeconds)
    lastWriteTime = $lastWriteTime
    preview = $preview
  }
}

function Get-SuperBrainKnownLockStatuses([string]$Root = $SuperBrainRoot, [int]$StaleAfterSeconds = 120) {
  $memoryBase = Get-SuperBrainMemoryBaseRoot $Root
  $memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
  $workspace = Join-Path $memoryBase 'workspace'
  $targets = @(
    (Join-Path $memoryRoot 'sandglass.txt'),
    (Join-Path $memoryRoot 'decision_particles.txt'),
    (Join-Path $memoryBase 'graph.jsonl'),
    (Join-Path $workspace 'active-checkpoint.json'),
    (Join-Path $workspace 'status-card.json'),
    (Join-Path $workspace 'last-status-snapshot.json'),
    (Join-Path $workspace 'last-verify-package.json'),
    (Join-Path $workspace 'last-ci.json'),
    (Join-Path $workspace 'session-binding.json')
  )
  return @($targets | ForEach-Object { Get-SuperBrainFileLockStatus $_ $StaleAfterSeconds } | Where-Object { $_.exists })
}

function Get-SuperBrainSkillNames {
  return @('super-memory-brain','skill-orchestrator','plusunm-g1','nexsandglass-dedicated-memory','skill-evolution-loop','skill-pool-router')
}

function Get-SuperBrainManifest([string]$Root = $SuperBrainRoot) {
  return Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-SuperBrainRuntimeFiles([string]$Root = $SuperBrainRoot) {
  $manifest = Get-SuperBrainManifest $Root
  if ($manifest.runtimeFiles) {
    return @($manifest.runtimeFiles)
  }
  return @(
    'sandglass_paths.py','sandglass_lock.py','sandglass_vault.py','sandglass_sqlite.py','sandglass_log.py','sandglass.py',
    'sandglass_think.py','sandglass_archive.py','sandglass_mcp.py','nexsandglass.py','nightwatch.py',
    'pulse.py','heartbeat.py','persona_l3.py','offset_l3.py','emotion_l3.py','scene_l3.py',
    'weave_l3.py','weavethread.py','l3_tasks.py','l3_persona_verify.py','l3_search_core.py',
    'l3_persona.py','discipline.py','offset_signals.py','decision_particles.py','emotion_vocab.py',
    'shadow_sand.py','search_router.py','l0_buffer.py','soul_diff.py','plugin.py','migrate_v2_4.py','metrics.py'
  )
}


function Get-SafeSuperBrainName([string]$Name, [string]$Fallback = 'default') {
  $safeName = ($Name -replace '[^A-Za-z0-9._-]','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = $Fallback }
  return $safeName.ToLowerInvariant()
}

function Get-SuperBrainRuntimeLayout([string]$Root = $SuperBrainRoot) {
  $path = Join-Path $Root 'runtime-layout.json'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $layout = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$layout.schema -ne 'super-brain.runtime-layout.v1') { return $null }
    return $layout
  } catch { return $null }
}

function Get-SuperBrainMemoryBaseRoot([string]$Root = $SuperBrainRoot) {
  if (-not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_STATE_ROOT)) {
    return [System.IO.Path]::GetFullPath($env:SUPER_BRAIN_STATE_ROOT).TrimEnd('\','/')
  }
  $layout = Get-SuperBrainRuntimeLayout $Root
  if ($layout -and -not [string]::IsNullOrWhiteSpace([string]$layout.stateRoot)) {
    return [System.IO.Path]::GetFullPath([string]$layout.stateRoot).TrimEnd('\','/')
  }
  return Join-Path $Root 'memory'
}

function Get-SuperBrainArchiveRoot([string]$Root = $SuperBrainRoot) {
  if (-not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_ARCHIVE_ROOT)) {
    return [System.IO.Path]::GetFullPath($env:SUPER_BRAIN_ARCHIVE_ROOT).TrimEnd('\','/')
  }
  $layout = Get-SuperBrainRuntimeLayout $Root
  if ($layout -and -not [string]::IsNullOrWhiteSpace([string]$layout.archiveRoot)) {
    return [System.IO.Path]::GetFullPath([string]$layout.archiveRoot).TrimEnd('\','/')
  }
  return Join-Path $Root 'archives'
}

function Get-SuperBrainInstallBackupRoot([string]$Root = $SuperBrainRoot) {
  return Join-Path (Get-SuperBrainArchiveRoot $Root) 'install-backups'
}

function Get-SuperBrainSharedMemoryRoot([string]$Root = $SuperBrainRoot) {
  return Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'shared'
}

function Get-SuperBrainAgentMemoryRoot([string]$AgentName, [string]$Root = $SuperBrainRoot) {
  return Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'agents') (Get-SafeSuperBrainName $AgentName 'agent')
}

function Get-SuperBrainGroupMemoryRoot([string]$GroupName, [string]$Root = $SuperBrainRoot) {
  return Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'groups') (Get-SafeSuperBrainName $GroupName 'group')
}

function Get-SuperBrainSharingPolicyPath([string]$Root = $SuperBrainRoot) {
  return Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'memory-sharing-policy.json'
}

function Get-SuperBrainDefaultSharingPolicy([string]$Root = $SuperBrainRoot) {
  $sharedRoot = (Get-NormalizedSuperBrainRoot (Get-SuperBrainSharedMemoryRoot $Root))
  return [pscustomobject]@{
    initialized = $true
    mode = 'shared'
    activeRoot = $sharedRoot
    sharedRoot = $sharedRoot
    agentsRoot = (Get-NormalizedSuperBrainRoot (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'agents'))
    groupsRoot = (Get-NormalizedSuperBrainRoot (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'groups'))
    updatedAt = ''
    note = 'Default installs use all-agent shared memory. Switch a specific agent to private or group memory only after explicit user intent.'
  }
}

function Get-SuperBrainSharingPolicy([string]$Root = $SuperBrainRoot) {
  $path = Get-SuperBrainSharingPolicyPath $Root
  if (Test-Path $path) {
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  return Get-SuperBrainDefaultSharingPolicy $Root
}

function Write-SuperBrainSharingPolicy([string]$Root, [string]$Mode, [string]$ActiveRoot, [string[]]$Members = @()) {
  $path = Get-SuperBrainSharingPolicyPath $Root
  $policy = [pscustomobject]@{
    initialized = $true
    mode = $Mode
    activeRoot = (Get-NormalizedSuperBrainRoot $ActiveRoot)
    sharedRoot = (Get-NormalizedSuperBrainRoot (Get-SuperBrainSharedMemoryRoot $Root))
    agentsRoot = (Get-NormalizedSuperBrainRoot (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'agents'))
    groupsRoot = (Get-NormalizedSuperBrainRoot (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'groups'))
    members = @($Members)
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    note = 'Writes are allowed only to the selected activeRoot. Shared/group roots require explicit user choice to avoid memory pollution.'
  }
  Write-JsonUtf8NoBom $path $policy 6
  return $policy
}

function Get-SuperBrainActiveMemoryRoot([string]$Root = $SuperBrainRoot) {
  $policy = Get-SuperBrainSharingPolicy $Root
  if ($policy.initialized -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$policy.activeRoot)) {
    return [string]$policy.activeRoot
  }
  return Get-SuperBrainSharedMemoryRoot $Root
}

function Get-SuperBrainMemoryLifecyclePolicy([string]$Root = $SuperBrainRoot) {
  $defaults = [pscustomobject]@{
    enabled = $true
    maxLines = 240
    maxChars = 180000
    warnAt = 0.8
    maxLinesByLayer = [pscustomobject]@{ profile = 32; project = 120; decision = 96; task = 48; session = 24 }
    retentionDays = [pscustomobject]@{ profile = 3650; project = 730; decision = 1095; task = 120; session = 30 }
    preserveTags = @('[CURRENT]','[VERIFIED]','[PROFILE]','[DECISION]')
    autoArchive = [pscustomobject]@{ exactDuplicates = $true; explicitExpiry = $true; staleHistory = $false; budgetOverflow = $false; requireConfirmationForBudgetOverflow = $true }
  }
  try {
    $path = Join-Path $Root 'memory-policy.json'
    $policy = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($policy.PSObject.Properties['lifecycle'] -and $policy.lifecycle) { return $policy.lifecycle }
  } catch {}
  return $defaults
}

function Get-SuperBrainMemoryLineRecord([string]$Line, [int]$LineNumber = 0) {
  $value = if ($null -eq $Line) { '' } else { [string]$Line }
  $match = [regex]::Match($value, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| ([^|]+) \| (.*)$')
  $timestamp = $null
  $sender = ''
  $text = $value
  if ($match.Success) {
    try { $timestamp = [datetime]::ParseExact($match.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) } catch {}
    $sender = $match.Groups[2].Value.Trim()
    $text = $match.Groups[3].Value
  }
  $tags = @([regex]::Matches($text, '\[[A-Z_]+\]') | ForEach-Object { $_.Value } | Select-Object -Unique)
  $layer = 'project'
  foreach ($candidate in @('profile','decision','task','session','project')) {
    if ($text.Contains("[$($candidate.ToUpperInvariant())]")) { $layer = $candidate; break }
  }
  if ($text.Contains('[ADR]')) { $layer = 'decision' }
  $expiryMatch = [regex]::Match($text, 'expires=(\d{4}-\d{2}-\d{2})')
  $expired = $false
  $expiry = ''
  if ($expiryMatch.Success) {
    $expiry = $expiryMatch.Groups[1].Value
    try { $expired = ([datetime]::ParseExact($expiry, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) -lt (Get-Date).Date) } catch { $expired = $true }
  }
  $ageDays = 0.0
  if ($timestamp) { $ageDays = [Math]::Max(0, ((Get-Date) - $timestamp).TotalDays) }
  return [pscustomobject]@{
    line = $LineNumber
    raw = $value
    text = $text
    timestamp = $timestamp
    sender = $sender
    tags = @($tags)
    layer = $layer
    expired = $expired
    expiry = $expiry
    ageDays = [Math]::Round($ageDays, 2)
    current = $text.Contains('[CURRENT]')
    verified = $text.Contains('[VERIFIED]')
    stale = $text.Contains('[STALE]')
    history = $text.Contains('[HISTORY]')
    protected = ($text.Contains('[CURRENT]') -and $text.Contains('[VERIFIED]'))
  }
}

function Get-SuperBrainMemoryBudget([object[]]$Records, [string]$CandidateText = '', [string]$CandidateLayer = '', [string]$Root = $SuperBrainRoot) {
  $lifecycle = Get-SuperBrainMemoryLifecyclePolicy $Root
  $items = @($Records | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.raw) })
  $maxLines = [int]$lifecycle.maxLines
  $maxChars = [int]$lifecycle.maxChars
  $currentLines = $items.Count
  $currentChars = 0
  foreach ($item in $items) { $currentChars += ([string]$item.raw).Length }
  $candidate = if ([string]::IsNullOrWhiteSpace($CandidateText)) { $null } else { [string]$CandidateText }
  $projectedLines = $currentLines + $(if ($candidate) { 1 } else { 0 })
  $projectedChars = [int]$currentChars + $(if ($candidate) { $candidate.Length } else { 0 })
  $layerCounts = [ordered]@{}
  $layerUtilization = [ordered]@{}
  foreach ($layer in @('profile','project','decision','task','session')) {
    $count = @($items | Where-Object { [string]$_.layer -eq $layer }).Count
    if ($candidate -and $CandidateLayer -eq $layer) { $count += 1 }
    $limit = [int]$lifecycle.maxLinesByLayer.$layer
    $layerCounts[$layer] = $count
    $layerUtilization[$layer] = [Math]::Round($(if ($limit -gt 0) { $count / $limit } else { 0 }), 4)
  }
  $lineUtilization = if ($maxLines -gt 0) { $projectedLines / $maxLines } else { 1 }
  $charUtilization = if ($maxChars -gt 0) { $projectedChars / $maxChars } else { 1 }
  $layerBlocked = @($layerUtilization.Keys | Where-Object { [double]$layerUtilization[$_] -gt 1 }).Count -gt 0
  $blocked = ($projectedLines -gt $maxLines -or $projectedChars -gt $maxChars -or $layerBlocked)
  $warning = (-not $blocked -and ($lineUtilization -ge [double]$lifecycle.warnAt -or $charUtilization -ge [double]$lifecycle.warnAt -or @($layerUtilization.Values | Where-Object { [double]$_ -ge [double]$lifecycle.warnAt }).Count -gt 0))
  return [pscustomobject]@{
    enabled = [bool]$lifecycle.enabled
    status = if ($blocked) { 'blocked' } elseif ($warning) { 'warning' } else { 'ok' }
    admissionStatus = if ($blocked) { 'blocked' } elseif ($warning) { 'warning' } else { 'allowed' }
    currentLines = $currentLines
    currentChars = [int]$currentChars
    projectedLines = $projectedLines
    projectedChars = $projectedChars
    maxLines = $maxLines
    maxChars = $maxChars
    warnAt = [double]$lifecycle.warnAt
    lineUtilization = [Math]::Round($lineUtilization, 4)
    charUtilization = [Math]::Round($charUtilization, 4)
    layerCounts = $layerCounts
    layerUtilization = $layerUtilization
    retentionDays = $lifecycle.retentionDays
    reason = if ($blocked) { 'memory_budget_exceeded' } elseif ($warning) { 'memory_budget_near_limit' } else { 'within_memory_budget' }
  }
}

function Test-SuperBrainSamePath([string]$Left, [string]$Right) {
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
  return ((Get-NormalizedSuperBrainRoot $Left) -eq (Get-NormalizedSuperBrainRoot $Right))
}

function Assert-SuperBrainMemoryWriteAllowed([string]$Root, [string]$MemoryRoot, [string]$Operation = 'write') {
  $policy = Get-SuperBrainSharingPolicy $Root
  if ($policy.initialized -ne $true) {
    throw "MEMORY_SHARING_UNCONFIRMED: choose memory sharing first with scripts\memory-mode.ps1 -Mode Shared, -Mode Agent, -Mode Group, or -Mode SplitMemory before $Operation. This prevents accidental shared-memory pollution."
  }
  if (-not (Test-SuperBrainSamePath $MemoryRoot ([string]$policy.activeRoot))) {
    throw "MEMORY_SCOPE_MISMATCH: $Operation target '$MemoryRoot' does not match active policy root '$($policy.activeRoot)'. Switch memory mode or pass the correct memory root."
  }
}

function Read-SuperBrainMemoryRootMarker([string]$SkillDir) {
  $markerPath = Join-Path $SkillDir 'memory-root.txt'
  if (-not (Test-Path $markerPath)) { return '' }
  return ([System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8)).Trim()
}

function Get-SuperBrainExtensionManifests([string[]]$Extensions = @(), [string]$Root = $SuperBrainRoot) {
  $extensionRoot = Join-Path $Root 'extensions'
  if (-not (Test-Path $extensionRoot)) { return @() }
  $manifests = @()
  foreach ($manifestPath in @(Get-ChildItem -LiteralPath $extensionRoot -Filter 'extension.json' -Recurse -File -ErrorAction SilentlyContinue)) {
    try {
      $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $manifest | Add-Member -NotePropertyName manifestPath -NotePropertyValue $manifestPath.FullName -Force
      $manifest | Add-Member -NotePropertyName extensionRoot -NotePropertyValue (Split-Path -Parent $manifestPath.FullName) -Force
      if ($Extensions.Count -eq 0 -or ($Extensions -contains [string]$manifest.id)) { $manifests += $manifest }
    } catch {}
  }
  return @($manifests)
}

function Get-SuperBrainExtensionItems([string[]]$Extensions = @(), [string]$Root = $SuperBrainRoot) {
  $items = @()
  foreach ($extension in @(Get-SuperBrainExtensionManifests $Extensions $Root)) {
    foreach ($skill in @($extension.skills)) {
      $source = Join-Path (Resolve-Path -LiteralPath $extension.extensionRoot).Path ([string]$skill.path)
      $rootPath = (Get-NormalizedSuperBrainRoot $Root)
      $sourcePath = (Get-NormalizedSuperBrainRoot $source)
      $relativeSource = $sourcePath.Substring($rootPath.Length).TrimStart('\','/')
      $items += @{ name=[string]$skill.name; source=$relativeSource; extensionId=[string]$extension.id; optional=$true }
    }
  }
  return @($items)
}

function Get-SuperBrainSourceItems([string[]]$Extensions = @()) {
  $items = @(
    @{ name='super-memory-brain'; source='super-memory-brain' },
    @{ name='skill-orchestrator'; source='modules\skill-orchestrator' },
    @{ name='plusunm-g1'; source='modules\plusunm-g1' },
    @{ name='nexsandglass-dedicated-memory'; source='modules\nexsandglass-dedicated-memory' },
    @{ name='skill-evolution-loop'; source='modules\skill-evolution-loop' },
    @{ name='skill-pool-router'; source='modules\skill-pool-router' }
  )
  if ($Extensions.Count -gt 0) { $items += @(Get-SuperBrainExtensionItems $Extensions $SuperBrainRoot) }
  return @($items)
}

function Write-SuperBrainMemoryScope([string]$MemoryRoot, [string]$Scope, [string[]]$Members = @(), [string]$Root = $SuperBrainRoot) {
  $scopeInfo = [pscustomobject]@{
    scope = $Scope
    members = @($Members)
    packageRoot = (Get-NormalizedSuperBrainRoot $Root)
    memoryRoot = (Get-NormalizedSuperBrainRoot $MemoryRoot)
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
  Write-JsonUtf8NoBom (Join-Path $MemoryRoot '.memory-scope.json') $scopeInfo 6
}

function Initialize-SuperBrainMemoryRoot([string]$MemoryRoot, [string]$Root = $SuperBrainRoot, [string]$Scope = 'custom', [string[]]$Members = @()) {
  $scripts = Join-Path $MemoryRoot 'scripts'
  New-Item -ItemType Directory -Force -Path $MemoryRoot,$scripts,(Join-Path $MemoryRoot 'persona'),(Join-Path $MemoryRoot 'archive') | Out-Null
  $vendor = Join-Path $Root 'vendor\NexSandglass-Agent-DedicatedMemory'
  foreach ($file in Get-SuperBrainRuntimeFiles $Root) {
    $src = Join-Path $vendor $file
    if (Test-Path $src) {
      Copy-Item -LiteralPath $src -Destination (Join-Path $scripts $file) -Force
    }
  }
  Write-SuperBrainMemoryScope $MemoryRoot $Scope $Members $Root
}

function Write-SuperBrainPackageRootMarker([string]$SkillDir, [string]$Root = $SuperBrainRoot) {
  $normalized = Get-NormalizedSuperBrainRoot $Root
  if (-not (Test-Path -LiteralPath $normalized)) { throw "PACKAGE_ROOT_MARKER_SOURCE_MISSING: $normalized" }
  $path = Join-Path $SkillDir 'package-root.txt'
  Write-Utf8NoBom $path ($normalized + "`n")
  $written = ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)).Trim()
  if (-not (Test-SuperBrainSamePath $written $normalized)) { throw "PACKAGE_ROOT_MARKER_VERIFY_FAILED: $path" }
}

function Write-SuperBrainMemoryRootMarker([string]$SkillDir, [string]$MemoryRoot) {
  $normalized = Get-NormalizedSuperBrainRoot $MemoryRoot
  if (-not (Test-Path -LiteralPath $normalized)) { throw "MEMORY_ROOT_MARKER_SOURCE_MISSING: $normalized" }
  $path = Join-Path $SkillDir 'memory-root.txt'
  Write-Utf8NoBom $path ($normalized + "`n")
  $written = ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)).Trim()
  if (-not (Test-SuperBrainSamePath $written $normalized)) { throw "MEMORY_ROOT_MARKER_VERIFY_FAILED: $path" }
}

function Get-SuperBrainGlobalStartupMaxChars() { return 1900 }

function Get-SuperBrainGlobalStartupBlock([string]$Root = $SuperBrainRoot) {
  $lines = @(
    '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->',
    '## Super Memory Brain Short Router',
    '',
    'Route-critical guards only; details stay cold.',
    '',
    '- Entry: `super-memory-brain`; roots come from installed markers.',
    '- Budget: <1900 chars; no catalogs, guides, examples, or memory bodies.',
    '- `memory:auto`: recall only for continuity/status/decisions/evidence/exact workflow preference; ordinary tasks stay direct.',
    '- Workflow trigger hot index: `git怎么写`/`git呢`/`怎么提交` -> `decision_key=git-ui-commit-response`; current verified only; output only `Summary`, `Description`, and `Commit button text`.',
    '- G1 visibility: first/final update starts `G1` only when Super Brain participates; middle updates stay plain.',
    '- Load for explicit control/status/recall/learning/restore/maintenance/prior-session.',
    '- Agent Bridge startup: agent + channel/bridge intent (CJK/non-English); generic agent stays direct.',
    '- Agent Bridge target: fresh channel unless id; quiet idle; wait for explicit close.',
    '- Compaction/resume: visible context, summaries, checkpoints, evidence, memory last; stale memory loses.',
    '- Maintenance: safe hygiene/post-task auto; destructive, secret, publish, global/hook/install writes need confirmation.',
    '- Skill availability guard: check `skill-pool-router`, read one verified `SKILL.md`; no activation or restart.',
    '- Skip full recall/team/package checks when visible context suffices.',
    '',
    '## Browser Route',
    '',
    'Use Playwright for normal browser automation. Load `browser-act` only when requested or Playwright cannot reliably complete visible verification/browser-state control; then read its skill.',
    '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->'
  )
  $block = $lines -join "`r`n"
  $maxChars = Get-SuperBrainGlobalStartupMaxChars
  if ($block.Length -gt $maxChars) { throw "SUPER_BRAIN_GLOBAL_STARTUP_TOO_LARGE: $($block.Length) > $maxChars" }
  return $block
}

function Get-SuperBrainAgentHomeFromSkillRoot([string]$SkillRoot) {
  if ([string]::IsNullOrWhiteSpace($SkillRoot)) { return '' }
  $full = Get-FullPath $SkillRoot
  $leaf = Split-Path -Leaf $full
  if ($leaf -ieq 'skills') { return Split-Path -Parent $full }
  return $full
}

function Get-SuperBrainGlobalStartupTargets([string]$SkillRoot) {
  $agentHome = Get-SuperBrainAgentHomeFromSkillRoot $SkillRoot
  if ([string]::IsNullOrWhiteSpace($agentHome)) { return @() }
  $known = @('AGENTS.md','CLAUDE.md','GEMINI.md')
  $existing = @()
  foreach ($name in $known) {
    $path = Join-Path $agentHome $name
    if (Test-Path -LiteralPath $path) { $existing += $path }
  }
  if ($existing.Count -gt 0) { return @($existing | Select-Object -Unique) }
  return @((Join-Path $agentHome 'AGENTS.md'))
}

function Write-SuperBrainGlobalStartup([string]$SkillRoot, [string]$Root = $SuperBrainRoot, [switch]$NoBackup) {
  $targets = @(Get-SuperBrainGlobalStartupTargets $SkillRoot)
  $written = @()
  if ($targets.Count -eq 0) { return @() }
  $block = Get-SuperBrainGlobalStartupBlock $Root
  $pattern = '(?s)<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->.*?<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->'
  $legacyPattern = '(?s)\A# Codex Global Bootstrap\s+## Super Memory Brain Short Router.*?## Browser Route.*?(?=\r?\n\r?\n## Shiroyama Output Rule)'
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  foreach ($path in $targets) {
    $old = ''
    if (Test-Path -LiteralPath $path) {
      $old = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      if (-not $NoBackup) { Copy-Item -LiteralPath $path -Destination "$path.bak-super-brain-bootstrap-$timestamp" -Force }
    }
    if ($old -match $legacyPattern) {
      $old = [regex]::Replace($old, $legacyPattern, "# Codex Global Bootstrap`r`n", 1)
    }
    if ($old -match $pattern) {
      $new = [regex]::Replace($old, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
    } elseif ([string]::IsNullOrWhiteSpace($old)) {
      $new = $block + "`r`n"
    } else {
      $new = $old.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
    }
    Write-Utf8NoBom $path $new
    $written += $path
  }
  return @($written)
}

function Test-SuperBrainGlobalStartup([string]$SkillRoot) {
  $targets = @(Get-SuperBrainGlobalStartupTargets $SkillRoot)
  $found = @()
  foreach ($path in $targets) {
    if (Test-Path -LiteralPath $path) {
      $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
      $blockMatch = [regex]::Match($text, '(?s)<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->.*?<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->')
      $singleBlock = ([regex]::Matches($text, '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->')).Count -eq 1
      $singleRouter = ([regex]::Matches($text, '## Super Memory Brain Short Router')).Count -eq 1
      $withinBudget = $blockMatch.Success -and $blockMatch.Value.Length -le (Get-SuperBrainGlobalStartupMaxChars)
      $playwrightFirst = ($text -like '*Use Playwright for normal browser automation*') -and ($text -like '*Playwright cannot reliably complete*')
      if ($singleBlock -and $singleRouter -and $withinBudget -and $playwrightFirst -and ($text -like '*super-memory-brain*') -and ($text -like '*browser-act*') -and ($text -like '*workflow preference*') -and ($text -like '*Workflow trigger hot index*') -and ($text -like '*git-ui-commit-response*') -and ($text -like '*G1 visibility*') -and ($text -like '*Agent Bridge startup*') -and ($text -like '*CJK/non-English*') -and ($text -like '*Agent Bridge target*') -and ($text -like '*Compaction/resume*') -and ($text -like '*Maintenance:*') -and ($text -like '*Skill availability guard*') -and ($text -like '*skill-pool-router*') -and ($text -like '*no activation or restart*')) { $found += $path }
    }
  }
  return [pscustomobject]@{ ok = ($found.Count -gt 0); paths = @($found); expected = @($targets) }
}

function Test-SuperBrainInstalledForPackage([string]$SkillRoot, [string]$Root = $SuperBrainRoot) {
  if ([string]::IsNullOrWhiteSpace($SkillRoot)) { return $false }
  $marker = Join-Path $SkillRoot 'super-memory-brain\package-root.txt'
  if (-not (Test-Path -LiteralPath $marker)) { return $false }
  try {
    $actual = ([System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8)).Trim()
    return ((Get-NormalizedSuperBrainRoot $actual) -eq (Get-NormalizedSuperBrainRoot $Root))
  } catch {
    return $false
  }
}

function Get-SuperBrainInstalledSkillRoots([string[]]$SeedRoots = @(), [string]$Root = $SuperBrainRoot) {
  $roots = @()
  foreach ($seed in @($SeedRoots)) {
    if (-not [string]::IsNullOrWhiteSpace($seed) -and (Test-SuperBrainInstalledForPackage -SkillRoot $seed -Root $Root)) { $roots += (Get-FullPath $seed) }
  }

  $profile = $env:USERPROFILE
  if (-not [string]::IsNullOrWhiteSpace($profile) -and (Test-Path -LiteralPath $profile)) {
    foreach ($dir in @(Get-ChildItem -LiteralPath $profile -Force -Directory -ErrorAction SilentlyContinue)) {
      $skillRoot = Join-Path $dir.FullName 'skills'
      if (Test-SuperBrainInstalledForPackage -SkillRoot $skillRoot -Root $Root) { $roots += (Get-FullPath $skillRoot) }
    }
  }

  return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-SuperBrainAdrState([object[]]$DecisionNodes, [object]$Policy) {
  $validStatuses = if ($Policy.adr.statuses) { @($Policy.adr.statuses) } else { @('proposed','accepted','deprecated','superseded','rejected') }
  $currentStatuses = if ($Policy.adr.currentStatuses) { @($Policy.adr.currentStatuses) } else { @('proposed','accepted') }
  $requiredRelations = if ($Policy.adr.requiredRelations) { @($Policy.adr.requiredRelations) } else { @('decides','has_title','has_status','has_context','has_consequence') }
  $bySubject = @{}

  function Get-AdrMeta([string]$Subject) {
    if (-not $bySubject.ContainsKey($Subject)) {
      $bySubject[$Subject] = [pscustomobject]@{ subject=$Subject; relations=@{}; status=''; supersedes=@(); supersededBy=@(); isAdr=$false }
    }
    return $bySubject[$Subject]
  }

  foreach ($node in @($DecisionNodes)) {
    $subject = [string]$node.subject
    if ([string]::IsNullOrWhiteSpace($subject)) { continue }
    $meta = Get-AdrMeta $subject
    $tags = [string]$node.tags
    $relation = [string]$node.relation
    if ($tags.Contains('[ADR]') -or $relation -in @('has_title','has_status','has_context','has_consequence','has_owner','affects','has_alternative')) { $meta.isAdr = $true }
    if (-not $meta.relations.ContainsKey($relation)) { $meta.relations[$relation] = @() }
    $meta.relations[$relation] = @($meta.relations[$relation] + [string]$node.object)
    if ($relation -eq 'has_status') { $meta.status = [string]$node.object }
    if ($relation -eq 'supersedes') { $meta.supersedes = @($meta.supersedes + [string]$node.object) }
    if ($relation -eq 'superseded_by') { $meta.supersededBy = @($meta.supersededBy + [string]$node.object) }
  }

  foreach ($node in @($DecisionNodes | Where-Object { [string]$_.relation -eq 'supersedes' })) {
    $oldSubject = [string]$node.object
    if ($oldSubject.StartsWith('decision:')) {
      $oldMeta = Get-AdrMeta $oldSubject
      $oldMeta.supersededBy = @($oldMeta.supersededBy + [string]$node.subject | Select-Object -Unique)
    }
  }

  $subjects = @($bySubject.Values | Where-Object { $_.isAdr })
  $missingSchema = @()
  $invalidStatus = @()
  $supersedesMissing = @()
  foreach ($adr in $subjects) {
    foreach ($relation in $requiredRelations) {
      if (-not $adr.relations.ContainsKey($relation) -or @($adr.relations[$relation]).Count -eq 0) { $missingSchema += "$($adr.subject):$relation" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$adr.status) -or $validStatuses -notcontains [string]$adr.status) { $invalidStatus += "$($adr.subject):$($adr.status)" }
    foreach ($oldSubject in @($adr.supersedes)) {
      if (-not $bySubject.ContainsKey([string]$oldSubject)) { $supersedesMissing += "$($adr.subject)->$oldSubject" }
    }
  }
  $currentSubjects = @($subjects | Where-Object { $currentStatuses -contains [string]$_.status -and @($_.supersededBy).Count -eq 0 })
  $currentConflicts = @($currentSubjects | Group-Object subject | Where-Object { $_.Count -gt 1 })
  $supersededSubjects = @($subjects | Where-Object { @($_.supersededBy).Count -gt 0 -or [string]$_.status -eq 'superseded' })
  $schemaIssueCount = $missingSchema.Count + $invalidStatus.Count + $supersedesMissing.Count + $currentConflicts.Count
  return [pscustomobject]@{
    ok=($schemaIssueCount -eq 0)
    subjectCount=$subjects.Count
    currentCount=$currentSubjects.Count
    supersededCount=$supersededSubjects.Count
    schemaIssueCount=$schemaIssueCount
    missingSchema=@($missingSchema)
    invalidStatus=@($invalidStatus)
    supersedesMissing=@($supersedesMissing)
    currentConflictCount=$currentConflicts.Count
  }
}

function Test-SuperBrainRootMarker([string]$SkillDir, [string]$MarkerName, [string]$ExpectedRoot = '', [string[]]$RequiredChildren = @()) {
  $markerPath = Join-Path $SkillDir $MarkerName
  $exists = Test-Path $markerPath
  $actual = ''
  $matches = $true
  $targetOk = $false
  if ($exists) {
    try {
      $actual = ([System.IO.File]::ReadAllText($markerPath, [System.Text.Encoding]::UTF8)).Trim()
      if (-not [string]::IsNullOrWhiteSpace($actual)) { $actual = Get-NormalizedSuperBrainRoot $actual }
      if (-not [string]::IsNullOrWhiteSpace($ExpectedRoot)) { $matches = ($actual -eq (Get-NormalizedSuperBrainRoot $ExpectedRoot)) }
      $targetOk = Test-Path $actual
      foreach ($child in $RequiredChildren) {
        if (-not (Test-Path (Join-Path $actual $child))) { $targetOk = $false }
      }
    } catch { $actual = $_.Exception.Message }
  }
  return [pscustomobject]@{ ok=($exists -and $matches -and $targetOk); exists=$exists; matches=$matches; targetOk=$targetOk; marker=$markerPath; actual=$actual; expected=$ExpectedRoot }
}

function Test-SuperBrainPackageRootMarker([string]$SkillDir, [string]$Root = $SuperBrainRoot) {
  return Test-SuperBrainRootMarker $SkillDir 'package-root.txt' $Root @('manifest.json','scripts','memory')
}

function Test-SuperBrainMemoryRootMarker([string]$SkillDir) {
  return Test-SuperBrainRootMarker $SkillDir 'memory-root.txt' '' @('scripts')
}

function Get-SuperBrainHookPath([string]$HookPath = '') {
  if (-not [string]::IsNullOrWhiteSpace($HookPath)) {
    return Get-FullPath $HookPath
  }

  $hooksRoot = Join-Path $env:USERPROFILE '.zcode\cli\plugins\cache\zcode-plugins-official\superpowers'
  $candidates = @()
  if (Test-Path $hooksRoot) {
    $candidates = @(Get-ChildItem -LiteralPath $hooksRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object {
        $path = Join-Path $_.FullName 'hooks\session-start'
        if (Test-Path $path) {
          [pscustomobject]@{ path = $path; version = $_.Name; modified = (Get-Item -LiteralPath $path).LastWriteTime }
        }
      })
  }

  if ($candidates.Count -gt 0) {
    foreach ($candidate in $candidates) {
      $versionText = $candidate.version -replace '[^0-9\.]',''
      try { $candidate | Add-Member -NotePropertyName parsedVersion -NotePropertyValue ([version]$versionText) -Force }
      catch { $candidate | Add-Member -NotePropertyName parsedVersion -NotePropertyValue ([version]'0.0.0') -Force }
    }
    return ($candidates | Sort-Object @{ Expression = 'parsedVersion'; Descending = $true }, @{ Expression = 'modified'; Descending = $true } | Select-Object -First 1).path
  }

  return Join-Path $hooksRoot '5.1.0\hooks\session-start'
}

function Limit-SuperBrainPacketText([string]$Value,[int]$Max=180) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $clean = ($Value.Trim() -replace '\s+',' ')
  if ($clean.Length -gt $Max) { return $clean.Substring(0,$Max) + '...' }
  return $clean
}

function Remove-SuperBrainExecutableActions([object]$Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [System.ValueType]) { return $Value }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = [ordered]@{}
    foreach ($key in @($Value.Keys)) {
      $name = ([string]$key).ToLowerInvariant()
      if ($name -in @('nextaction','authorizednextaction','knownnextaction','phasenextaction','suggestednextaction','resumenextaction','currentaction','assistantcommitment','currentstep','taskgoal','goal','summary','lastsummary')) { $copy[$key] = ''; continue }
      if ($name -in @('nextsteps','pendingsteps','recommendedactions','verificationcommands','commands','completedsteps','verificationresults')) { $copy[$key] = @(); continue }
      if ($name -in @('hasconcretenextaction','claimallowed','planauthorized','mutationauthorized','worklinemutationauthorized','canresumeparent')) { $copy[$key] = $false; continue }
      if ($name -eq 'actionauthorization') { $copy[$key] = 'withheld'; continue }
      $copy[$key] = Remove-SuperBrainExecutableActions $Value[$key]
    }
    return [pscustomobject]$copy
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    return @($Value | ForEach-Object { Remove-SuperBrainExecutableActions $_ })
  }
  $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty','Property','AliasProperty','ScriptProperty') })
  if ($properties.Count -eq 0) { return $Value }
  $result = [ordered]@{}
  foreach ($property in $properties) {
    $name = ([string]$property.Name).ToLowerInvariant()
    if ($name -in @('nextaction','authorizednextaction','knownnextaction','phasenextaction','suggestednextaction','resumenextaction','currentaction','assistantcommitment','currentstep','taskgoal','goal','summary','lastsummary')) { $result[$property.Name] = ''; continue }
    if ($name -in @('nextsteps','pendingsteps','recommendedactions','verificationcommands','commands','completedsteps','verificationresults')) { $result[$property.Name] = @(); continue }
    if ($name -in @('hasconcretenextaction','claimallowed','planauthorized','mutationauthorized','worklinemutationauthorized','canresumeparent')) { $result[$property.Name] = $false; continue }
    if ($name -eq 'actionauthorization') { $result[$property.Name] = 'withheld'; continue }
    $result[$property.Name] = Remove-SuperBrainExecutableActions $property.Value
  }
  return [pscustomobject]$result
}

function ConvertTo-SuperBrainCompactPlan([object]$Plan,[int]$NextActionMax=180) {
  if (-not $Plan) { return $null }
  return [pscustomobject]@{
    focusId = Limit-SuperBrainPacketText ([string]$Plan.focusId) 120
    focusLabel = Limit-SuperBrainPacketText ([string]$Plan.focusLabel) 100
    nextAction = Limit-SuperBrainPacketText ([string]$Plan.nextAction) $NextActionMax
    topicKeys = @($Plan.topicKeys | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 48 })
    priority = if ($Plan.priority) { [pscustomobject]@{ executionRank=[int]$Plan.priority.executionRank; source=Limit-SuperBrainPacketText ([string]$Plan.priority.source) 48; reason=Limit-SuperBrainPacketText ([string]$Plan.priority.reason) 100 } } else { $null }
    hasConcreteNextAction = [bool]$Plan.hasConcreteNextAction
  }
}

function ConvertTo-SuperBrainCompactStateCard([object]$Card) {
  if (-not $Card) { return $null }
  return [pscustomobject]@{
    schema = Limit-SuperBrainPacketText ([string]$Card.schema) 80
    taskId = Limit-SuperBrainPacketText ([string]$Card.taskId) 160
    workspaceKey = Limit-SuperBrainPacketText ([string]$Card.workspaceKey) 64
    revision = [int]$Card.revision
    stateFingerprint = Limit-SuperBrainPacketText ([string]$Card.stateFingerprint) 32
    mainLineId = Limit-SuperBrainPacketText ([string]$Card.mainLineId) 120
    activeLineId = Limit-SuperBrainPacketText ([string]$Card.activeLineId) 120
    activeLineLabel = Limit-SuperBrainPacketText ([string]$Card.activeLineLabel) 100
    parentLineId = Limit-SuperBrainPacketText ([string]$Card.parentLineId) 120
    lineRole = Limit-SuperBrainPacketText ([string]$Card.lineRole) 32
    instructionMode = Limit-SuperBrainPacketText ([string]$Card.instructionMode) 48
    phase = Limit-SuperBrainPacketText ([string]$Card.phase) 120
    currentStep = Limit-SuperBrainPacketText ([string]$Card.currentStep) 180
    completedSteps = @($Card.completedSteps | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    pendingSteps = @($Card.pendingSteps | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    blockers = @($Card.blockers | Select-Object -First 4 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    evidence = @($Card.evidence | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    verificationResults = @($Card.verificationResults | Select-Object -First 4 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 150 })
    nextAction = Limit-SuperBrainPacketText ([string]$Card.nextAction) 200
    assistantCommitment = Limit-SuperBrainPacketText ([string]$Card.assistantCommitment) 220
    constraints = @($Card.constraints | Select-Object -First 5 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 140 })
    acceptanceCriteria = @($Card.acceptanceCriteria | Select-Object -First 5 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 140 })
    priorityOrder = @($Card.priorityOrder | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ executionRank=[int]$_.executionRank; focusId=Limit-SuperBrainPacketText ([string]$_.focusId) 120; focusLabel=Limit-SuperBrainPacketText ([string]$_.focusLabel) 80; role=Limit-SuperBrainPacketText ([string]$_.role) 40; source=Limit-SuperBrainPacketText ([string]$_.source) 56 } })
    suspendedLineIds = @($Card.suspendedLineIds | Select-Object -First 4 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    unfinishedLineIds = @($Card.unfinishedLineIds | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    returnStack = @($Card.returnStack | Select-Object -First 4 | ForEach-Object { [pscustomobject]@{ focusId=Limit-SuperBrainPacketText ([string]$_.focusId) 120; focusLabel=Limit-SuperBrainPacketText ([string]$_.focusLabel) 80; currentPhase=Limit-SuperBrainPacketText ([string]$_.currentPhase) 100; currentStep=Limit-SuperBrainPacketText ([string]$_.currentStep) 140; nextAction=Limit-SuperBrainPacketText ([string]$_.nextAction) 140; pendingSteps=@($_.pendingSteps | Select-Object -First 3 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 }); blockers=@($_.blockers | Select-Object -First 2 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 }) } })
    latestMessageClassification = ConvertTo-SuperBrainCompactMessageClassification $Card.latestMessageClassification
    source = Limit-SuperBrainPacketText ([string]$Card.source) 100
    capturedAt = Limit-SuperBrainPacketText ([string]$Card.capturedAt) 48
  }
}

function ConvertTo-SuperBrainCompactMessageClassification([object]$Classification) {
  if (-not $Classification) { return $null }
  return [pscustomobject]@{
    mode = Limit-SuperBrainPacketText ([string]$Classification.mode) 48
    topicAffinity = Limit-SuperBrainPacketText ([string]$Classification.topicAffinity) 120
    targetLineId = Limit-SuperBrainPacketText ([string]$Classification.targetLineId) 120
    targetLineLabel = Limit-SuperBrainPacketText ([string]$Classification.targetLineLabel) 100
    confidence = Limit-SuperBrainPacketText ([string]$Classification.confidence) 32
    matchedKeys = @($Classification.matchedKeys | Select-Object -First 8 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 48 })
    candidateLineIds = @($Classification.candidateLineIds | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    needsClarification = [bool]$Classification.needsClarification
    recommendedInstructionMode = Limit-SuperBrainPacketText ([string]$Classification.recommendedInstructionMode) 48
    reason = Limit-SuperBrainPacketText ([string]$Classification.reason) 180
    rawInstructionStored = [bool]$Classification.rawInstructionStored
  }
}

function ConvertTo-SuperBrainCompactWorkLineStatus([object]$Status) {
  if (-not $Status) { return $null }
  $activePlan = ConvertTo-SuperBrainCompactPlan $Status.activePlan 200
  $mainPlan = ConvertTo-SuperBrainCompactPlan $Status.mainPlan 160
  $nextPlan = ConvertTo-SuperBrainCompactPlan $Status.nextPlan 160
  return [pscustomobject]@{
    mainLine = Limit-SuperBrainPacketText ([string]$Status.mainLine) 120
    activeLine = Limit-SuperBrainPacketText ([string]$Status.activeLine) 120
    completedRecent = @($Status.completedRecent | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    unfinishedLines = @($Status.unfinishedLines | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    suspendedLines = @($Status.suspendedLines | Select-Object -First 4 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    defaultNextLine = Limit-SuperBrainPacketText ([string]$Status.defaultNextLine) 120
    priorityPolicy = Limit-SuperBrainPacketText ([string]$Status.priorityPolicy) 120
    priorityOrder = @($Status.priorityOrder | Select-Object -First 4 | ForEach-Object { [pscustomobject]@{ executionRank=[int]$_.executionRank; focusId=Limit-SuperBrainPacketText ([string]$_.focusId) 120; focusLabel=Limit-SuperBrainPacketText ([string]$_.focusLabel) 80; role=Limit-SuperBrainPacketText ([string]$_.role) 48; source=Limit-SuperBrainPacketText ([string]$_.source) 64 } })
    activePlan = $activePlan
    mainPlan = $mainPlan
    nextPlan = $nextPlan
    suspendedPlans = @($Status.suspendedPlans | Select-Object -First 4 | ForEach-Object { ConvertTo-SuperBrainCompactPlan $_ 140 })
    unfinishedPlans = @($Status.unfinishedPlans | Select-Object -First 6 | ForEach-Object { ConvertTo-SuperBrainCompactPlan $_ 140 })
    latestMessageClassification = ConvertTo-SuperBrainCompactMessageClassification $Status.latestMessageClassification
    requiresUserDisambiguation = [bool]$Status.requiresUserDisambiguation
    planRecoveryRequired = [bool]$Status.planRecoveryRequired
    userView = [pscustomobject]@{
      main = if ($mainPlan) { [pscustomobject]@{ focusId=$mainPlan.focusId; label=$mainPlan.focusLabel; status=if([string]$Status.mainLine -eq [string]$Status.activeLine){'active'}else{'suspended'} } } else { $null }
      current = if ($activePlan) { [pscustomobject]@{ focusId=$activePlan.focusId; label=$activePlan.focusLabel; status='active'; role=if(@($Status.suspendedLines).Count -gt 0){'side_branch'}else{'main_line'} } } else { $null }
    }
  }
}

function ConvertTo-SuperBrainCompactExecutionResolution([object]$Resolution) {
  if (-not $Resolution) { return $null }
  $result = [pscustomobject]@{
    ok = [bool]$Resolution.ok
    resumeFrom = [string]$Resolution.resumeFrom
    resolutionSource = Limit-SuperBrainPacketText ([string]$Resolution.resolutionSource) 64
    claimAllowed = [bool]$Resolution.claimAllowed
    needsConfirmation = [bool]$Resolution.needsConfirmation
    taskId = [string]$Resolution.taskId
    workspaceKey = [string]$Resolution.workspaceKey
    focusId = Limit-SuperBrainPacketText ([string]$Resolution.focusId) 120
    focusLabel = Limit-SuperBrainPacketText ([string]$Resolution.focusLabel) 100
    instructionMode = Limit-SuperBrainPacketText ([string]$Resolution.instructionMode) 48
    returnTo = if ($Resolution.returnTo) { [pscustomobject]@{ focusId=Limit-SuperBrainPacketText ([string]$Resolution.returnTo.focusId) 120; focusLabel=Limit-SuperBrainPacketText ([string]$Resolution.returnTo.focusLabel) 100; nextAction=Limit-SuperBrainPacketText ([string]$Resolution.returnTo.nextAction) 160 } } else { $null }
    canResumeParent = [bool]$Resolution.canResumeParent
    unfinishedWorkLines = @($Resolution.unfinishedWorkLines | Select-Object -First 6 | ForEach-Object { Limit-SuperBrainPacketText ([string]$_) 120 })
    continuityStateCard = ConvertTo-SuperBrainCompactStateCard $Resolution.continuityStateCard
    workLineStatus = ConvertTo-SuperBrainCompactWorkLineStatus $Resolution.workLineStatus
    latestMessageClassification = ConvertTo-SuperBrainCompactMessageClassification $Resolution.latestMessageClassification
    nextAction = Limit-SuperBrainPacketText ([string]$Resolution.nextAction) 220
    contractRevision = [int]$Resolution.contractRevision
    guard = Limit-SuperBrainPacketText ([string]$Resolution.guard) 220
    actionAuthorization = if ($Resolution.PSObject.Properties['actionAuthorization']) { [string]$Resolution.actionAuthorization } elseif ($Resolution.claimAllowed -eq $true -and $Resolution.needsConfirmation -ne $true) { 'allowed' } else { 'withheld' }
    sessionAccess = if ($Resolution.PSObject.Properties['sessionAccess']) { Limit-SuperBrainPacketText ([string]$Resolution.sessionAccess) 48 } else { '' }
    foreignContextDetected = ($Resolution.foreignContextDetected -eq $true)
    foreignContextSessionAccess = if ($Resolution.PSObject.Properties['foreignContextSessionAccess']) { Limit-SuperBrainPacketText ([string]$Resolution.foreignContextSessionAccess) 48 } else { '' }
  }
  $noContractApplies = ($result.resolutionSource -eq 'none' -and $result.actionAuthorization -eq 'not_applicable')
  if ($noContractApplies) {
    $result.claimAllowed = $true
    $result.needsConfirmation = $false
    $result.actionAuthorization = 'not_applicable'
    $result.canResumeParent = $false
  } elseif ($result.claimAllowed -ne $true -or $result.needsConfirmation -eq $true -or $result.actionAuthorization -ne 'allowed') {
    $result.claimAllowed = $false
    $result.needsConfirmation = $true
    $result.actionAuthorization = 'withheld'
    $result.canResumeParent = $false
    $result.returnTo = Remove-SuperBrainExecutableActions $result.returnTo
    $result.workLineStatus = Remove-SuperBrainExecutableActions $result.workLineStatus
  }
  return $result
}


