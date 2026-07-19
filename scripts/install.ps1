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
  [string[]]$Extensions = @()
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Neurobase)) {
  $Neurobase = Get-SuperBrainSharedMemoryRoot $Root
}

if ($MemoryMode -eq 'SplitMemory') {
  $ZCodeMemoryRoot = Get-SuperBrainAgentMemoryRoot 'zcode' $Root
  $CodexMemoryRoot = Get-SuperBrainAgentMemoryRoot 'codex' $Root
} else {
  $ZCodeMemoryRoot = $Neurobase
  $CodexMemoryRoot = $Neurobase
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$installBackupRoot = Get-SuperBrainInstallBackupRoot $Root
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

try {
  if ($MemoryMode -eq 'SplitMemory') {
    Initialize-SuperBrainMemoryRoot $ZCodeMemoryRoot $Root 'agent' @('zcode')
    Initialize-SuperBrainMemoryRoot $CodexMemoryRoot $Root 'agent' @('codex')
    Write-SuperBrainSharingPolicy $Root 'split' $ZCodeMemoryRoot @('zcode','codex') | Out-Null
  } elseif ($MemoryMode -eq 'Shared') {
    Initialize-SuperBrainMemoryRoot $ZCodeMemoryRoot $Root 'shared' @('all-agents')
    Initialize-SuperBrainMemoryRoot $CodexMemoryRoot $Root 'shared' @('all-agents')
    Write-SuperBrainSharingPolicy $Root 'shared' $ZCodeMemoryRoot @('all-agents') | Out-Null
  } else {
    Initialize-SuperBrainMemoryRoot $ZCodeMemoryRoot $Root 'shared-pending' @('all-agents')
    Initialize-SuperBrainMemoryRoot $CodexMemoryRoot $Root 'shared-pending' @('all-agents')
    Write-JsonUtf8NoBom (Get-SuperBrainSharingPolicyPath $Root) (Get-SuperBrainDefaultSharingPolicy $Root) 6
  }

  foreach ($item in @(Get-SuperBrainSourceItems)) {
    Copy-Skill (Join-Path $Root $item.source) $item.name $ZCodeSkills $ZCodeMemoryRoot
  }

  if ($Extensions.Count -gt 0) {
    foreach ($item in @(Get-SuperBrainExtensionItems $Extensions $Root)) {
      Copy-Skill (Join-Path $Root $item.source) $item.name $ZCodeSkills $ZCodeMemoryRoot
    }
  }

  foreach ($item in @(Get-SuperBrainSourceItems)) {
    Copy-Skill (Join-Path $Root $item.source) $item.name $CodexSkills $CodexMemoryRoot
  }

  if ($Extensions.Count -gt 0) {
    foreach ($item in @(Get-SuperBrainExtensionItems $Extensions $Root)) {
      Copy-Skill (Join-Path $Root $item.source) $item.name $CodexSkills $CodexMemoryRoot
    }
  }

  Refresh-InstalledMemoryRootMarkers $ZCodeSkills $ZCodeMemoryRoot
  Refresh-InstalledMemoryRootMarkers $CodexSkills $CodexMemoryRoot

  foreach ($path in @(Write-SuperBrainGlobalStartup $ZCodeSkills $Root -NoBackup:$NoBackup)) { Write-Host "GLOBAL_STARTUP_WRITTEN agent=zcode path=$path" }
  foreach ($path in @(Write-SuperBrainGlobalStartup $CodexSkills $Root -NoBackup:$NoBackup)) { Write-Host "GLOBAL_STARTUP_WRITTEN agent=codex path=$path" }
  $coldSkillRoot = Join-Path $env:USERPROFILE '.codex-cold-skills'
  $defaultCodexSkills = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex\skills')).TrimEnd('\','/')
  $targetCodexSkills = [IO.Path]::GetFullPath($CodexSkills).TrimEnd('\','/')
  if ($targetCodexSkills.Equals($defaultCodexSkills,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $coldSkillRoot)) {
    & (Join-Path $Root 'modules\skill-pool-router\scripts\manage-skill-pool.ps1') -Action Reindex -ActiveRoot $CodexSkills -ColdRoot $coldSkillRoot
    if ($LASTEXITCODE -ne 0) { throw 'SKILL_POOL_REINDEX_FAILED' }
  }
  & (Join-Path $PSScriptRoot 'install-codex-user-prompt-hook.ps1') -CodexHome (Split-Path -Parent $CodexSkills) -PackageRoot $Root -NoBackup:$NoBackup
  if ($LASTEXITCODE -ne 0) { throw 'Codex UserPromptSubmit hook installation failed.' }
  & (Join-Path $PSScriptRoot 'repair-hook.ps1') -PackageRoot $Root

  if (-not $SkipRuntime) {
    Write-Host 'Installing local Super Brain runtime and narrow MCP...'
    & (Join-Path $PSScriptRoot 'install-runtime.ps1') -CodexHome (Split-Path -Parent $CodexSkills) -MemoryRoot $CodexMemoryRoot
    if ($LASTEXITCODE -ne 0) { throw 'Super Brain runtime/MCP installation failed.' }
  }

  Write-Host "Installed NexSandglass runtime/memory for ZCode: $ZCodeMemoryRoot"
  Write-Host "Installed NexSandglass runtime/memory for Codex: $CodexMemoryRoot"
  Write-Host "Memory mode: $MemoryMode"
  Write-Host "Set for current shell if needed: `$env:NEXSANDBASE_HOME='$ZCodeMemoryRoot'; `$env:PYTHONPATH='$(Join-Path $ZCodeMemoryRoot 'scripts')'"

  if (-not $SkipVerify) {
    Write-Host 'Running post-install health check...'
    & (Join-Path $PSScriptRoot 'health-check.ps1') -ZCodeSkills $ZCodeSkills -CodexSkills $CodexSkills -MemoryRoot $ZCodeMemoryRoot -SkipRuntime:$SkipRuntime
    if ($LASTEXITCODE -ne 0) {
      throw 'Post-install health check failed.'
    }
    Write-Host 'POST_INSTALL_HEALTH_CHECK_OK'
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

