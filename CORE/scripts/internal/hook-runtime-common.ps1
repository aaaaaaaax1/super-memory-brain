function Get-SuperBrainStableHash([string]$Value,[int]$Length=16) {
  if ([string]::IsNullOrWhiteSpace($Value)) { throw 'SUPER_BRAIN_HASH_VALUE_REQUIRED' }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hex = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Value)) | ForEach-Object { $_.ToString('x2') })
    return $hex.Substring(0,[Math]::Min($Length,$hex.Length))
  } finally { $sha.Dispose() }
}

function Get-SuperBrainLocalSessionKey([string]$SessionId='') {
  $candidate = $SessionId
  if ([string]::IsNullOrWhiteSpace($candidate) -and -not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_LOCAL_SESSION_ID)) { $candidate = [string]$env:SUPER_BRAIN_LOCAL_SESSION_ID }
  if ([string]::IsNullOrWhiteSpace($candidate)) { return '' }
  $candidate = $candidate.Trim()
  if ($candidate -match '^sid-[0-9a-f]{16,64}$') { return $candidate.ToLowerInvariant() }
  return 'sid-' + (Get-SuperBrainStableHash $candidate 24)
}

function Get-SuperBrainWorkspaceKey([string]$Workspace='') {
  $value = $Workspace
  if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_WORKSPACE_KEY)) { $value = [string]$env:SUPER_BRAIN_WORKSPACE_KEY }
  if ([string]::IsNullOrWhiteSpace($value)) { $value = (Get-Location).Path }
  $value = ([string]$value).Trim()
  if ($value -match '^ws-[0-9a-f]{24}$') { return $value.ToLowerInvariant() }
  try { $value = [IO.Path]::GetFullPath($value).TrimEnd('\','/') } catch {}
  return 'ws-' + (Get-SuperBrainStableHash $value.ToLowerInvariant() 24)
}

function Get-SuperBrainHookTaskToken([string]$TaskId) {
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return '' }
  $safe = (($TaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'task' }
  if ($safe.Length -gt 96) { $safe = $safe.Substring(0,96).TrimEnd('-') }
  return $safe + '--' + (Get-SuperBrainStableHash $TaskId 16)
}

function Get-SuperBrainHookFileSha256([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return '' }
}

function Test-SuperBrainWorkspaceKey([string]$RecordedKey,[string]$CurrentKey='') {
  if ([string]::IsNullOrWhiteSpace($RecordedKey)) { return $false }
  return [string]::Equals((Get-SuperBrainWorkspaceKey $RecordedKey),(Get-SuperBrainWorkspaceKey $CurrentKey),[StringComparison]::OrdinalIgnoreCase)
}

function Get-SuperBrainHookCurrentTaskContext([string]$WorkspaceRoot,[string]$WorkspaceKey='',[string]$PackageVersion='',[string]$SessionKey='') {
  if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return $null }
  try { $resolvedRoot = [IO.Path]::GetFullPath($WorkspaceRoot) } catch { return $null }
  $resolvedKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  $safe = (($resolvedKey -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'workspace' }
  $pointerPath = Join-Path (Join-Path $resolvedRoot 'guard-state\current-task-context-pointers') ($safe + '--' + (Get-SuperBrainStableHash $resolvedKey 16) + '.json')

  function Read-HookContextProjection([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
  }

  $pointerExists = Test-Path -LiteralPath $pointerPath -PathType Leaf
  if ($pointerExists) {
    $context = Read-HookContextProjection $pointerPath
    $source = 'workspace_scoped'
    $sourcePath = $pointerPath
  } else {
    $sourcePath = Join-Path $resolvedRoot 'current-task-context.json'
    $context = Read-HookContextProjection $sourcePath
    $source = 'legacy_global'
  }
  if (-not $context -or -not $context.PSObject.Properties['workspaceKey'] -or -not (Test-SuperBrainWorkspaceKey ([string]$context.workspaceKey) $resolvedKey)) { return $null }
  if ([string]$context.status -ne 'active' -or $context.stale -eq $true -or [string]::IsNullOrWhiteSpace([string]$context.taskId)) { return $null }
  $bindingDeclared = $context.PSObject.Properties['bindingState']
  $expiresAt = $null
  try { $expiresAt = [datetime]::Parse([string]$context.expiresAt) } catch {}
  if ($bindingDeclared -and (-not $expiresAt -or $expiresAt -le (Get-Date))) { return $null }
  if (-not $bindingDeclared -and $expiresAt -and $expiresAt -le (Get-Date)) { return $null }
  if (-not [string]::IsNullOrWhiteSpace($PackageVersion) -and -not [string]::IsNullOrWhiteSpace([string]$context.version) -and [string]$context.version -ne $PackageVersion) { return $null }
  if ($bindingDeclared) {
    if ([string]$context.bindingState -ne 'bound' -or [string]$context.lifecycleStatus -ne 'active' -or [int]$context.taskStateRevision -le 0 -or [int]$context.contractRevision -le 0 -or [string]::IsNullOrWhiteSpace([string]$context.planFingerprint) -or [string]::IsNullOrWhiteSpace([string]$context.ownerSessionKey) -or [string]::IsNullOrWhiteSpace([string]$context.contractFileName) -or [string]::IsNullOrWhiteSpace([string]$context.targetHash)) { return $null }
    $contractRoot = Join-Path $resolvedRoot 'runtime-state\execution-contracts'
    $contractPath = Join-Path $contractRoot (Split-Path -Leaf ([string]$context.contractFileName))
    if (-not (Test-SuperBrainChildPath $contractRoot $contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf) -or (Get-SuperBrainHookFileSha256 $contractPath) -ne [string]$context.targetHash) { return $null }
    try { $contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    $noAction = -not [string]::IsNullOrWhiteSpace([string]$contract.nextAction) -and ([string]$contract.nextAction).Trim().StartsWith('No automatic action:',[StringComparison]::OrdinalIgnoreCase)
    if ([string]$contract.taskId -ne [string]$context.taskId -or -not (Test-SuperBrainWorkspaceKey ([string]$contract.workspaceKey) $resolvedKey) -or [string]$contract.status -ne 'active' -or $noAction -or [int]$contract.revision -ne [int]$context.contractRevision -or [string]$contract.planReceipt.planFingerprint -ne [string]$context.planFingerprint -or [string]$contract.ownerSessionKey -ne [string]$context.ownerSessionKey) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($PackageVersion) -and [string]$contract.packageVersion -ne $PackageVersion) { return $null }
    $projectionPath = Join-Path (Join-Path $resolvedRoot 'task-state-store\projections') ((Get-SuperBrainHookTaskToken ([string]$context.taskId)) + '.json')
    try { $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ([int]$projection.revision -ne [int]$context.taskStateRevision -or -not $projection.entities.context -or [string]$projection.entities.context.status -ne 'active' -or [string]$projection.entities.context.path -ne [string]$context.path -or (Get-SuperBrainHookFileSha256 ([string]$context.path)) -ne [string]$projection.entities.context.hash) { return $null }
    $authorization = if ([string]::IsNullOrWhiteSpace($SessionKey) -or [string]$context.ownerSessionKey -eq (Get-SuperBrainLocalSessionKey $SessionKey)) { 'allowed' } else { 'foreign_session_locator' }
    $context | Add-Member -NotePropertyName contextProjectionAuthorization -NotePropertyValue $authorization -Force
  } else {
    $context | Add-Member -NotePropertyName contextProjectionAuthorization -NotePropertyValue 'legacy_compatibility' -Force
  }
  $context | Add-Member -NotePropertyName contextProjectionSource -NotePropertyValue $source -Force
  $context | Add-Member -NotePropertyName contextProjectionPath -NotePropertyValue $sourcePath -Force
  return $context
}

function Test-SuperBrainChildPath([string]$Parent,[string]$Child) {
  try {
    $prefix = [IO.Path]::GetFullPath($Parent).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    return [IO.Path]::GetFullPath($Child).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function Get-SuperBrainRuntimeLayout([string]$Root) {
  $path = Join-Path $Root 'runtime-layout.json'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try {
    $layout = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
    if ([string]$layout.schema -ne 'super-brain.runtime-layout.v1') { return $null }
    return $layout
  } catch { return $null }
}

function Get-SuperBrainRuntimeWorkspaceRoot([string]$Root) {
  $runtimeRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
  if ([string]::Equals((Split-Path -Leaf $runtimeRoot),'CORE',[StringComparison]::OrdinalIgnoreCase)) {
    return (Split-Path -Parent $runtimeRoot).TrimEnd('\','/')
  }
  return $runtimeRoot
}

function Resolve-SuperBrainRuntimeLayoutPath([string]$Root,[string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $runtimeRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
  $workspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $runtimeRoot
  $expanded = [Environment]::ExpandEnvironmentVariables($Value.Trim())
  $candidate = if ([IO.Path]::IsPathRooted($expanded)) { $expanded } else { Join-Path $runtimeRoot $expanded }
  $full = [IO.Path]::GetFullPath($candidate).TrimEnd('\','/')
  $prefix = $workspaceRoot + [IO.Path]::DirectorySeparatorChar
  if (-not [string]::Equals($full,$workspaceRoot,[StringComparison]::OrdinalIgnoreCase) -and -not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
    throw "SUPER_BRAIN_RUNTIME_LAYOUT_PATH_OUTSIDE_WORKSPACE: $Value"
  }
  return $full
}

function Get-SuperBrainMemoryBaseRoot([string]$Root) {
  if (-not [string]::IsNullOrWhiteSpace($env:SUPER_BRAIN_STATE_ROOT)) { return [IO.Path]::GetFullPath($env:SUPER_BRAIN_STATE_ROOT).TrimEnd('\','/') }
  $layout = Get-SuperBrainRuntimeLayout $Root
  if ($layout -and -not [string]::IsNullOrWhiteSpace([string]$layout.stateRoot)) { return Resolve-SuperBrainRuntimeLayoutPath $Root ([string]$layout.stateRoot) }
  $workspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $Root
  if (-not [string]::Equals($workspaceRoot,[IO.Path]::GetFullPath($Root).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)) { return Join-Path $workspaceRoot 'private-state' }
  return Join-Path $Root 'memory'
}

function Invoke-SuperBrainFileLock([string]$Path,[scriptblock]$Body,[int]$TimeoutMs=15000,[int]$StaleAfterSeconds=120) {
  $lockPath = [IO.Path]::GetFullPath($Path) + '.lock'
  $directory = Split-Path -Parent $lockPath
  if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
  $stream = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      if (Test-Path -LiteralPath $lockPath) {
        try { if (((Get-Date)-(Get-Item -LiteralPath $lockPath).LastWriteTime).TotalSeconds -gt $StaleAfterSeconds) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } } catch {}
      }
      $stream = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
      break
    } catch [IO.IOException] { Start-Sleep -Milliseconds 40 }
  }
  if (-not $stream) { throw "MEMORY_LOCK_TIMEOUT path=$Path timeoutMs=$TimeoutMs" }
  try { return & $Body }
  finally {
    try { $stream.Dispose() } catch {}
    try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Write-Utf8NoBom([string]$Path,[string]$Content) {
  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  Invoke-SuperBrainFileLock $Path {
    $temporary = "$Path.tmp.$PID.$([guid]::NewGuid().ToString('n'))"
    try {
      [IO.File]::WriteAllText($temporary,$Content,[Text.UTF8Encoding]::new($false))
      Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
  } | Out-Null
}

function Write-JsonUtf8NoBom([string]$Path,[object]$Value,[int]$Depth=8,[switch]$Compress) {
  Write-Utf8NoBom $Path ($Value | ConvertTo-Json -Depth $Depth -Compress:$Compress)
}
