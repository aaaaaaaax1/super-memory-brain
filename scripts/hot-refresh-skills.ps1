param(
  [string[]]$SkillRoots = @(),
  [switch]$AllKnown,
  [switch]$NoBackup
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$StatusPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'last-hot-refresh.json'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$results = @()
$ok = $true

function Add-Result([string]$SkillRoot, [string]$SkillName, [bool]$Success, [string]$Message) {
  $script:results += [pscustomobject]@{
    skillRoot = $SkillRoot
    skillName = $SkillName
    ok = $Success
    message = $Message
  }
  if (-not $Success) { $script:ok = $false }
}

function Get-KnownSkillRoots {
  $roots = @(
    Join-Path $env:USERPROFILE '.zcode\skills'
    Join-Path $env:USERPROFILE '.codex\skills'
  )
  return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Test-InstalledForCurrentPackage([string]$SkillDir) {
  $marker = Join-Path $SkillDir 'package-root.txt'
  if (-not (Test-Path $marker)) { return $false }
  try {
    $actual = ([System.IO.File]::ReadAllText($marker, [System.Text.Encoding]::UTF8)).Trim()
    return ((Get-NormalizedSuperBrainRoot $actual) -eq (Get-NormalizedSuperBrainRoot $Root))
  } catch {
    return $false
  }
}

function Get-MemoryRootForSkill([string]$SkillDir) {
  $existing = Read-SuperBrainMemoryRootMarker $SkillDir
  if (-not [string]::IsNullOrWhiteSpace($existing)) { return $existing }
  return Get-SuperBrainSharedMemoryRoot $Root
}

function Refresh-MemoryRuntime([string]$MemoryRoot, [string]$Scope, [string[]]$Members) {
  if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { return }
  Initialize-SuperBrainMemoryRoot $MemoryRoot $Root $Scope $Members
  Write-Host "HOT_REFRESH_MEMORY_OK memory=$MemoryRoot scope=$Scope"
}

function Refresh-Skill([string]$SkillRoot, [object]$Item) {
  $source = Join-Path $Root $Item.source
  $dest = Join-Path $SkillRoot $Item.name
  if (-not (Test-Path $dest)) {
    Add-Result $SkillRoot $Item.name $false 'missing installed skill directory'
    return
  }
  if (-not (Test-InstalledForCurrentPackage $dest)) {
    Add-Result $SkillRoot $Item.name $false 'installed skill does not point to current package-root.txt'
    return
  }

  $memoryRoot = Get-MemoryRootForSkill $dest
  Refresh-MemoryRuntime $memoryRoot 'hot-refresh' @($Item.name)
  if (-not $NoBackup) {
    $backup = Join-Path $Root ("install-backup-$timestamp\hot-refresh\$($SkillRoot -replace '[:\\/ ]','_')\$($Item.name)")
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
    Copy-Item -LiteralPath $dest -Destination $backup -Recurse -Force
  }
  Remove-Item -LiteralPath $dest -Recurse -Force
  Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
  Write-SuperBrainPackageRootMarker $dest $Root
  Write-SuperBrainMemoryRootMarker $dest $memoryRoot
  Add-Result $SkillRoot $Item.name $true "refreshed memory=$memoryRoot"
  Write-Host "HOT_REFRESH_SKILL_OK root=$SkillRoot skill=$($Item.name) memory=$memoryRoot"
}

try {
  $roots = @($SkillRoots)
  if ($roots.Count -eq 0 -or $AllKnown) { $roots += Get-KnownSkillRoots }
  $roots = @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
  if ($roots.Count -eq 0) { throw 'No skill roots specified or detected.' }

  foreach ($skillRoot in $roots) {
    if (-not (Test-Path $skillRoot)) {
      Add-Result $skillRoot '' $false 'skill root missing'
      continue
    }
    foreach ($item in Get-SuperBrainSourceItems) {
      Refresh-Skill $skillRoot $item
    }
  }

  $status = [pscustomobject]@{
    ok = $ok
    packageRoot = $Root
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    results = $results
    note = 'Hot refresh updates installed skill files, package/memory root markers, and memory runtime files for installed agents; open a new agent session if the agent caches skill content.'
  }
  Write-JsonUtf8NoBom $StatusPath $status 8
  if ($ok) { Write-Host "HOT_REFRESH_OK $StatusPath" } else { Write-Host "HOT_REFRESH_PARTIAL $StatusPath"; exit 1 }
} catch {
  Write-JsonUtf8NoBom $StatusPath ([pscustomobject]@{
    ok = $false
    packageRoot = $Root
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    error = $_.Exception.Message
    results = $results
  }) 8
  Write-Host "HOT_REFRESH_FAILED $($_.Exception.Message)"
  exit 1
}
