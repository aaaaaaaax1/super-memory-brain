param(
  [int]$Keep = 10,
  [int]$MaxAgeDays = 0,
  [switch]$Apply,
  [string]$HookPath = ""
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$HookPath = Get-SuperBrainHookPath $HookPath

if ($Keep -lt 0) { throw 'Keep must be zero or greater.' }
if ($MaxAgeDays -lt 0) { throw 'MaxAgeDays must be zero or greater.' }

$cutoff = $null
if ($MaxAgeDays -gt 0) {
  $cutoff = (Get-Date).AddDays(-1 * $MaxAgeDays)
}

$candidateMap = @{}
$reports = @()

function Add-Candidates([string]$Name, [object[]]$Items) {
  $sorted = @($Items | Sort-Object LastWriteTime -Descending)
  $byCount = 0
  $byAge = 0

  for ($i = 0; $i -lt $sorted.Count; $i += 1) {
    $item = $sorted[$i]
    $removeByCount = $i -ge $script:Keep
    $removeByAge = $false
    if ($null -ne $script:cutoff) {
      $removeByAge = $item.LastWriteTime -lt $script:cutoff
    }

    if ($removeByCount -or $removeByAge) {
      if (-not $script:candidateMap.ContainsKey($item.FullName)) {
        $script:candidateMap[$item.FullName] = $item
      }
      if ($removeByCount) { $byCount += 1 }
      if ($removeByAge) { $byAge += 1 }
    }
  }

  $script:reports += [pscustomobject]@{
    name = $Name
    total = $sorted.Count
    keep = $script:Keep
    byCount = $byCount
    byAge = $byAge
  }
}

$archiveBackupRoot = Join-Path (Get-SuperBrainArchiveRoot $Root) 'backups'
$archiveBackups = if (Test-Path -LiteralPath $archiveBackupRoot) { @(Get-ChildItem -LiteralPath $archiveBackupRoot -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue) } else { @() }
$legacyPackageBackups = @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'backup-*' -ErrorAction SilentlyContinue)
Add-Candidates 'archive-backup-dirs' $archiveBackups
Add-Candidates 'legacy-package-backup-dirs' $legacyPackageBackups

$memoryPath = Join-Path (Get-SuperBrainActiveMemoryRoot $Root) 'sandglass.txt'
$memoryDir = Split-Path -Parent $memoryPath
if (Test-Path $memoryDir) {
  $compactBackups = @(Get-ChildItem -LiteralPath $memoryDir -File -Filter 'sandglass.txt.bak-compact-*' -ErrorAction SilentlyContinue)
  Add-Candidates 'compact-memory-backups' $compactBackups
} else {
  Add-Candidates 'compact-memory-backups' @()
}

$hookDir = Split-Path -Parent $HookPath
$hookName = Split-Path -Leaf $HookPath
if (Test-Path $hookDir) {
  $hookBackups = @(Get-ChildItem -LiteralPath $hookDir -File -Filter "$hookName.bak-super-memory-brain-*" -ErrorAction SilentlyContinue)
  Add-Candidates 'session-start-hook-backups' $hookBackups
} else {
  Add-Candidates 'session-start-hook-backups' @()
}

foreach ($report in $reports) {
  Write-Host "BACKUP_RETENTION_REPORT category=$($report.name) total=$($report.total) keep=$($report.keep) byCount=$($report.byCount) byAge=$($report.byAge)"
}

$candidates = @($candidateMap.Values | Sort-Object FullName)
if ($candidates.Count -eq 0) {
  Write-Host "BACKUP_RETENTION_NO_CANDIDATES keep=$Keep maxAgeDays=$MaxAgeDays apply=$($Apply.IsPresent)"
  exit 0
}

foreach ($candidate in $candidates) {
  Write-Host "BACKUP_RETENTION_CANDIDATE $($candidate.FullName)"
}

if (-not $Apply) {
  Write-Host "BACKUP_RETENTION_DRY_RUN candidates=$($candidates.Count) keep=$Keep maxAgeDays=$MaxAgeDays"
  exit 0
}

$removed = 0
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate.FullName) {
    Remove-Item -LiteralPath $candidate.FullName -Recurse -Force
    $removed += 1
  }
}

Write-Host "BACKUP_RETENTION_APPLY_OK removed=$removed keep=$Keep maxAgeDays=$MaxAgeDays"
exit 0
