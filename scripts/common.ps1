$SuperBrainRoot = Split-Path -Parent $PSScriptRoot

function Get-FullPath([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path)
}

function Get-NormalizedSuperBrainRoot([string]$Root = $SuperBrainRoot) {
  return ([System.IO.Path]::GetFullPath($Root)).TrimEnd('\','/')
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-JsonUtf8NoBom([string]$Path, [object]$Value, [int]$Depth = 8) {
  Write-Utf8NoBom $Path ($Value | ConvertTo-Json -Depth $Depth)
}

function Get-SuperBrainSkillNames {
  return @('super-memory-brain','skill-orchestrator','plusunm-g1','nexsandglass-dedicated-memory')
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
    'sandglass_paths.py','sandglass_vault.py','sandglass_sqlite.py','sandglass_log.py','sandglass.py',
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

function Get-SuperBrainSourceItems {
  return @(
    @{ name='super-memory-brain'; source='super-memory-brain' },
    @{ name='skill-orchestrator'; source='modules\skill-orchestrator' },
    @{ name='plusunm-g1'; source='modules\plusunm-g1' },
    @{ name='nexsandglass-dedicated-memory'; source='modules\nexsandglass-dedicated-memory' }
  )
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
  Write-Utf8NoBom (Join-Path $SkillDir 'package-root.txt') ((Get-NormalizedSuperBrainRoot $Root) + "`n")
}

function Write-SuperBrainMemoryRootMarker([string]$SkillDir, [string]$MemoryRoot) {
  Write-Utf8NoBom (Join-Path $SkillDir 'memory-root.txt') ((Get-NormalizedSuperBrainRoot $MemoryRoot) + "`n")
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
