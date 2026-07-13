$SuperBrainRoot = Split-Path -Parent $PSScriptRoot

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Get-NormalizedSuperBrainRoot([string]$Root = $SuperBrainRoot) {
  return ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\','/')
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

function Write-JsonUtf8NoBom([string]$Path, [object]$Value, [int]$Depth = 8) {
  Write-Utf8NoBom $Path ($Value | ConvertTo-Json -Depth $Depth)
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
  return @('super-memory-brain','skill-orchestrator','plusunm-g1','nexsandglass-dedicated-memory','skill-evolution-loop')
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

function Get-SuperBrainMemoryBaseRoot([string]$Root = $SuperBrainRoot) {
  return Join-Path $Root 'memory'
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
    @{ name='agent-bridge'; source='modules\agent-bridge' }
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

function Get-SuperBrainGlobalStartupBlock([string]$Root = $SuperBrainRoot) {
  $packageRoot = Get-NormalizedSuperBrainRoot $Root
  $memoryRoot = Get-NormalizedSuperBrainRoot (Get-SuperBrainSharedMemoryRoot $Root)
  $lines = @(
    '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->',
    '## Super Memory Brain Short Router',
    '',
    'At the start of every new agent conversation, treat the Super Memory Brain short router as active even if the full `super-memory-brain` skill body has not been loaded yet.',
    '',
    ('- Public entry: `super-memory-brain`; package root: `' + $packageRoot + '`; memory root: `' + $memoryRoot + '`.'),
    '- Keep startup lightweight: `memory:auto`, G1 governs memory decisions, ORC routes tasks, and NexSandglass/Hybrid Recall is used only when continuity, status, prior decisions, or evidence are needed.',
    '- Treat a terse request matching a configured canonical workflow preference as a `memory:auto` recall trigger: perform one bounded lookup before replying and do not replace its current verified contract with a generic template.',
    '- Workflow trigger hot index: `git怎么写`, `git呢`, `怎么提交`, `提交怎么写`, and spacing/punctuation variants map to `decision_key=git-ui-commit-response`; resolve it with exact current-and-verified decision lookup, never generic semantic fallback.',
    '- G1 visibility: when Super Brain/G1/ORC/NexSandglass or governed memory actually participates, the final reply first line must be exactly `G1`; never display it without participation and never omit it after participation.',
    '- Load/read `super-memory-brain` first for explicit wake/control/status/recall/learning/restore/maintenance/agent-bridge phrases such as `超级大脑`, `启动超级大脑`, `刷新超级大脑`, `Super Brain`, `G1`, `任务状态`, `还记得`, `上次`, `另一个会话`, `开启agent通道`, `开启子agent通道`, `打开子agent通道`, `连接子agent通道`, `agent通道`, `子agent通道`, `agent bridge`, or `subagent channel`.',
    '- Agent Bridge startup route: any mixed Chinese/English user phrase containing `agent` plus channel/open/connect/send/bridge/communication intent must load/read `super-memory-brain` first, not the host default agent/worker/explorer help. Short commands such as open agent channel, connect agent channel, send to agent, subagent channel, and agent bridge are Super Brain agent-bridge commands.',
    '- Hard guard: any user phrase containing ASCII `agent` together with CJK/non-English characters should be treated as Super Brain Agent Bridge routing, not host default explorer/worker/default agent role help, unless the user explicitly asks for role help or says explorer/worker/default.',
    '- Agent Bridge target-mode guard: `open agent channel` / `subagent channel` / mixed `agent` channel open commands must create a fresh channel in the current conversation unless a channel id is explicitly supplied. Do not launch nested agents/workers/explorers/helpers/Tesla to open the channel. `WaitConnect`/`WaitInbox` idle or timeout means quiet idle waiting, not blocked/paused/failed/completed; do not repeat status messages. After one reply, the sub-agent must not report Goal/target completion and must keep waiting for the next message until explicit close.',
    '- Compaction/resume priority: after context compression, first use visible conversation, compressed summary/records, checkpoint/status/ledger/recent tool results; treat long-term memory as supplemental and never let stale memory override newer visible context.',
    '- Maintenance autonomy: safe local hygiene may run automatically through workspace lifecycle, auto hygiene, post-task maintenance, and self-improvement queue; destructive deletion, private/raw-secret handling, external publishing, broad overwrites, hook/install/global rewrites, or unclear risk require confirmation.',
    '- Shiroyama: Do not send optional commentary.',
    '- Do not load full Super Brain, deep recall, team dispatch, or package verification for ordinary chat when visible context is enough.',
    '',
    '## Browser Route',
    '',
    'For browser operations, default to `browser-act` CLI, not Playwright.',
    '',
    '- Browser operations include opening URLs, clicking, typing, forms, screenshots, rendered/JavaScript page extraction, browser sessions, login-state workflows, and visible checkbox-style verification such as Cloudflare / I am human.',
    '- `browser-act` is a CLI skill and may not appear as a dedicated MCP/tool button. If no browser-act tool is exposed, check PATH and then use the Windows CLI path: `<user-home>\AppData\Roaming\Python\Python312\Scripts\browser-act.exe`.',
    '- Before the first browser-act command in a task, read `browser-act get-skills core --skill-version 2.0.2` or `& "<user-home>\AppData\Roaming\Python\Python312\Scripts\browser-act.exe" get-skills core --skill-version 2.0.2`.',
    '- Use Playwright only when the user explicitly asks for Playwright, when writing/running Playwright tests, when browser-act CLI is unavailable and the user declines installation, or for a Playwright-specific devtools/test workflow.',
    '- When the user asks to click a visible verification checkbox, treat it as authorized browser clicking of a visible control, not as bypassing or cracking hidden captcha. If solving hidden/third-party captcha, API key, payment, login credentials, submission, or sensitive action is required, ask first.',
    '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_END -->'
  )
  return ($lines -join "`r`n")
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
      $singleBlock = ([regex]::Matches($text, '<!-- SUPER_MEMORY_BRAIN_BOOTSTRAP_START -->')).Count -eq 1
      $singleRouter = ([regex]::Matches($text, '## Super Memory Brain Short Router')).Count -eq 1
      if ($singleBlock -and $singleRouter -and ($text -like '*super-memory-brain*') -and ($text -like '*browser-act*') -and ($text -like '*workflow preference*') -and ($text -like '*Workflow trigger hot index*') -and ($text -like '*decision_key=git-ui-commit-response*') -and ($text -like '*G1 visibility*') -and ($text -like '*Agent Bridge startup route*') -and ($text -like '*Hard guard*') -and ($text -like '*CJK/non-English*') -and ($text -like '*subagent channel*') -and ($text -like '*Agent Bridge target-mode guard*') -and ($text -like '*Compaction/resume priority*') -and ($text -like '*Maintenance autonomy*')) { $found += $path }
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


