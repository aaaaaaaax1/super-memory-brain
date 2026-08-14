[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$Neurobase = "",
  [ValidateSet('Prompt','Shared','SplitMemory')]
  [string]$MemoryMode = 'Shared',
  [switch]$SkipVerify,
  [switch]$NoBackup,
  [switch]$PruneBackups,
  [int]$KeepBackups = 5,
  [switch]$SkipRuntime,
  [switch]$SkipHealthCheck,
  [switch]$SkipZCode,
  [switch]$SkipCodex,
  [switch]$IncludeZCode,
  [switch]$Isolated,
  [string]$InstallBackupRoot = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Neurobase = Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $Neurobase -Operation 'install'
$runtimeInstalled = $false
$installZCode = ($IncludeZCode -and -not $SkipZCode)
$installCodex = (-not $SkipCodex)
if (-not $installZCode -and -not $installCodex) { throw 'INSTALL_TARGET_HOST_REQUIRED' }
$requestedMemoryMode = $MemoryMode
if ($MemoryMode -ne 'Shared') {
  Write-Host "MEMORY_MODE_RETIRED requested=$MemoryMode resolved=Shared reason=single-super-brain-memory-authority"
  $MemoryMode = 'Shared'
}
$ZCodeMemoryRoot = $Neurobase
$CodexMemoryRoot = $Neurobase

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$installBackupRoot = if ([string]::IsNullOrWhiteSpace($InstallBackupRoot)) { Get-SuperBrainInstallBackupRoot $Root } else { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($InstallBackupRoot)) }
$backupRoot = Join-Path $installBackupRoot ("install-backup-$timestamp")
$backups = @()

function Copy-Skill($Source, $Name, $DestRoot, $MemoryRoot) {
  if (-not (Test-Path $DestRoot)) {
    New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null
  }

  $dest = Join-Path $DestRoot $Name
  $destinationExisted = Test-Path $dest
  if ($destinationExisted -and -not $NoBackup) {
    $safeRoot = ($DestRoot -replace '[:\/ ]', '_').Trim('_')
    $backupDir = Join-Path $backupRoot $safeRoot
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backup = Join-Path $backupDir $Name
    Copy-Item -LiteralPath $dest -Destination $backup -Recurse -Force
    $script:backups += [pscustomobject]@{ dest = $dest; backup = $backup; created = $false }
    Write-Host "Backup skill: $dest -> $backup"
  }
  if (-not $destinationExisted) {
    $script:backups += [pscustomobject]@{ dest = $dest; backup = ''; created = $true }
  }

  if (Test-Path $dest) {
    Remove-Item -LiteralPath $dest -Recurse -Force
  }
  Copy-Item -LiteralPath $Source -Destination $dest -Recurse -Force
  Write-SuperBrainPackageRootMarker $dest $Root
  Write-SuperBrainMemoryRootMarker $dest $MemoryRoot
  Write-Host "Installed skill: $dest"
  Write-Host "Package root marker: $(Join-Path $dest 'package-root.txt')"
  Write-Host "Memory root marker: $(Join-Path $dest 'memory-root.txt')"
}

function Restore-Backups {
  foreach ($entry in @($script:backups | Sort-Object { $_.dest.Length } -Descending)) {
    if (Test-Path $entry.dest) {
      Remove-Item -LiteralPath $entry.dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $entry.created -and (Test-Path $entry.backup)) {
      Copy-Item -LiteralPath $entry.backup -Destination $entry.dest -Recurse -Force
      Write-Host "Restored skill: $($entry.dest)"
    } elseif ($entry.created) {
      Write-Host "Removed newly created skill during rollback: $($entry.dest)"
    }
  }
}

function Refresh-InstalledMemoryRootMarkers($DestRoot, $MemoryRoot) {
  if (-not (Test-Path -LiteralPath $DestRoot)) { return }
  $normalizedRoot = Get-NormalizedSuperBrainRoot $Root
  foreach ($skillDir in @(Get-ChildItem -LiteralPath $DestRoot -Directory -ErrorAction SilentlyContinue)) {
    $packageMarker = Join-Path $skillDir.FullName 'package-root.txt'
    if (-not (Test-Path -LiteralPath $packageMarker)) { continue }
    $markerRoot = (Get-Content -LiteralPath $packageMarker -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($markerRoot)) { continue }
    try { $markerRoot = Get-NormalizedSuperBrainRoot $markerRoot } catch { continue }
    if (-not $markerRoot.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase)) { continue }
    Write-SuperBrainMemoryRootMarker $skillDir.FullName $MemoryRoot
  }
}

function Prune-InstallBackups {
  if (-not $PruneBackups) { return }
  if ($NoBackup) { return }
  if (-not (Test-Path -LiteralPath $installBackupRoot)) { return }
  $dirs = @(Get-ChildItem -LiteralPath $installBackupRoot -Directory -Filter 'install-backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  $old = @($dirs | Select-Object -Skip $KeepBackups)
  foreach ($dir in $old) {
    Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Pruned install backup: $($dir.FullName)"
  }
}

$hostAdapterItems = @(Get-SuperBrainHostAdapterItems)

try {
  Initialize-SuperBrainMemoryRoot $Neurobase $Root 'shared' @('all-agents')
  if (-not $Isolated) { Write-SuperBrainSharingPolicy $Root 'shared' $Neurobase @('all-agents') | Out-Null }

  if ($installZCode) {
    foreach ($item in $hostAdapterItems) {
      Copy-Skill (Join-Path $Root $item.source) $item.name $ZCodeSkills $Neurobase
    }
  }

  if ($installCodex) {
    foreach ($item in $hostAdapterItems) {
      Copy-Skill (Join-Path $Root $item.source) $item.name $CodexSkills $Neurobase
    }
  }

  if ($installZCode) { Refresh-InstalledMemoryRootMarkers $ZCodeSkills $ZCodeMemoryRoot }
  if ($installCodex) { Refresh-InstalledMemoryRootMarkers $CodexSkills $CodexMemoryRoot }

  if ($installZCode) { foreach ($path in @(Write-SuperBrainGlobalStartup $ZCodeSkills $Root -NoBackup:$NoBackup)) { Write-Host "GLOBAL_STARTUP_WRITTEN agent=zcode path=$path" } }
  if ($installCodex) { foreach ($path in @(Write-SuperBrainGlobalStartup $CodexSkills $Root -NoBackup:$NoBackup)) { Write-Host "GLOBAL_STARTUP_WRITTEN agent=codex path=$path" } }
  if (-not $SkipRuntime -and $installCodex) {
    Write-Host 'Installing Hookless Turn Runtime and Super Brain MCP...'
    & (Join-Path $PSScriptRoot 'install-runtime.ps1') -CodexHome (Split-Path -Parent $CodexSkills) -MemoryRoot $CodexMemoryRoot
    if ($LASTEXITCODE -ne 0) { throw 'Super Brain runtime/MCP installation failed.' }
    $runtimeInstalled = $true
  }

  if ($installZCode) { Write-Host "Installed Super Brain compatibility adapter for ZCode; shared memory: $Neurobase" }
  if ($installCodex) { Write-Host "Installed Super Brain host adapter for Codex; shared memory: $Neurobase" }
  if (-not $installZCode) { Write-Host 'ZCode compatibility adapter was not installed. Use -IncludeZCode only for an explicit compatible-host install.' }
  Write-Host "Memory mode: Shared (requested=$requestedMemoryMode)"
  Write-Host 'HOST_SKILL_POLICY super-memory-brain-only; extension sources are absorbed provenance-only cold capabilities.'
  Write-Host 'Absorbed package capabilities remain Super Brain-owned cold sources; no standalone extension skills were installed.'
  Write-Host "Set for current shell if needed: `$env:NEXSANDBASE_HOME='$Neurobase'; `$env:PYTHONPATH='$(Get-SuperBrainRuntimePythonPath $Root)'"

  if (-not $SkipVerify -and -not $SkipHealthCheck) {
    Write-Host 'Running post-install health check...'
    # Use named splatting.  An argument array can reinterpret switch-shaped
    # values as positionals in Windows PowerShell, which breaks isolated
    # installer fixtures and can accidentally inspect the user's host state.
    $healthArgs = @{
      ZCodeSkills = $ZCodeSkills
      CodexSkills = $CodexSkills
      MemoryRoot = $Neurobase
      SkipRuntime = [bool]$SkipRuntime
      Isolated = [bool]$Isolated
    }
    if ($installZCode) { $healthArgs.IncludeZCode = $true }
    & (Join-Path $PSScriptRoot 'health-check.ps1') @healthArgs
    if ($LASTEXITCODE -ne 0) {
      throw 'Post-install health check failed.'
    }
    Write-Host 'POST_INSTALL_HEALTH_CHECK_OK'
  } elseif ($SkipHealthCheck) {
    Write-Host 'POST_INSTALL_HEALTH_CHECK_DEFERRED'
  }

  if ($PruneBackups) {
    Prune-InstallBackups
  } else {
    Write-Host 'Install backups preserved. Use cleanup-install-backups.ps1 -Apply or rerun with -PruneBackups for explicit cleanup.'
  }
  Write-Host "Done. Restart ZCode/Codex to pick up new skills."
} catch {
  Write-Host "INSTALL_FAILED $($_.Exception.Message)"
  if ($backups.Count -gt 0) {
    Write-Host 'INSTALL_ROLLBACK_START'
    Restore-Backups
    Write-Host 'INSTALL_ROLLBACK_DONE'
  }
  exit 1
}

