param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$Neurobase = "",
  [ValidateSet('Prompt','Shared','SplitMemory')]
  [string]$MemoryMode = 'Shared',
  [switch]$SkipVerify,
  [switch]$NoBackup,
  [int]$KeepBackups = 5
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
$backupRoot = Join-Path $Root ("install-backup-$timestamp")
$backups = @()

function Copy-Skill($Source, $Name, $DestRoot, $MemoryRoot) {
  if (-not (Test-Path $DestRoot)) {
    New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null
  }

  $dest = Join-Path $DestRoot $Name
  if ((Test-Path $dest) -and -not $NoBackup) {
    $safeRoot = ($DestRoot -replace '[:\/ ]', '_').Trim('_')
    $backupDir = Join-Path $backupRoot $safeRoot
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backup = Join-Path $backupDir $Name
    Copy-Item -LiteralPath $dest -Destination $backup -Recurse -Force
    $script:backups += [pscustomobject]@{ dest = $dest; backup = $backup }
    Write-Host "Backup skill: $dest -> $backup"
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
    if (Test-Path $entry.backup) {
      Copy-Item -LiteralPath $entry.backup -Destination $entry.dest -Recurse -Force
      Write-Host "Restored skill: $($entry.dest)"
    }
  }
}

function Prune-InstallBackups {
  if ($NoBackup) { return }
  $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'install-backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
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

  Copy-Skill (Join-Path $Root 'super-memory-brain') 'super-memory-brain' $ZCodeSkills $ZCodeMemoryRoot
  Copy-Skill (Join-Path $Root 'modules\skill-orchestrator') 'skill-orchestrator' $ZCodeSkills $ZCodeMemoryRoot
  Copy-Skill (Join-Path $Root 'modules\plusunm-g1') 'plusunm-g1' $ZCodeSkills $ZCodeMemoryRoot
  Copy-Skill (Join-Path $Root 'modules\nexsandglass-dedicated-memory') 'nexsandglass-dedicated-memory' $ZCodeSkills $ZCodeMemoryRoot

  Copy-Skill (Join-Path $Root 'super-memory-brain') 'super-memory-brain' $CodexSkills $CodexMemoryRoot
  Copy-Skill (Join-Path $Root 'modules\skill-orchestrator') 'skill-orchestrator' $CodexSkills $CodexMemoryRoot
  Copy-Skill (Join-Path $Root 'modules\plusunm-g1') 'plusunm-g1' $CodexSkills $CodexMemoryRoot
  Copy-Skill (Join-Path $Root 'modules\nexsandglass-dedicated-memory') 'nexsandglass-dedicated-memory' $CodexSkills $CodexMemoryRoot

  & (Join-Path $PSScriptRoot 'repair-hook.ps1') -PackageRoot $Root

  Write-Host "Installed NexSandglass runtime/memory for ZCode: $ZCodeMemoryRoot"
  Write-Host "Installed NexSandglass runtime/memory for Codex: $CodexMemoryRoot"
  Write-Host "Memory mode: $MemoryMode"
  Write-Host "Set for current shell if needed: `$env:NEXSANDBASE_HOME='$ZCodeMemoryRoot'; `$env:PYTHONPATH='$(Join-Path $ZCodeMemoryRoot 'scripts')'"

  if (-not $SkipVerify) {
    Write-Host 'Running post-install health check...'
    & (Join-Path $PSScriptRoot 'health-check.ps1') -ZCodeSkills $ZCodeSkills -CodexSkills $CodexSkills -MemoryRoot $ZCodeMemoryRoot
    if ($LASTEXITCODE -ne 0) {
      throw 'Post-install health check failed.'
    }
    Write-Host 'POST_INSTALL_HEALTH_CHECK_OK'
  }

  Prune-InstallBackups
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
