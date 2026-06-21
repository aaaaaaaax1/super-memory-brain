param(
  [int]$Keep = 1,
  [switch]$Apply
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ($Keep -lt 0) { throw 'Keep must be zero or greater.' }

$backups = @(Get-ChildItem -LiteralPath $Root -Directory -Filter 'install-backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
$delete = @($backups | Select-Object -Skip $Keep)

Write-Host "INSTALL_BACKUP_CLEANUP total=$($backups.Count) keep=$Keep delete=$($delete.Count) apply=$Apply"
foreach ($dir in $backups | Select-Object -First $Keep) {
  Write-Host "INSTALL_BACKUP_KEEP $($dir.FullName)"
}
foreach ($dir in $delete) {
  Write-Host "INSTALL_BACKUP_DELETE_CANDIDATE $($dir.FullName)"
}

if (-not $Apply) {
  Write-Host 'INSTALL_BACKUP_CLEANUP_DRY_RUN use -Apply to delete candidates.'
  exit 0
}

foreach ($dir in $delete) {
  $full = Get-NormalizedSuperBrainRoot $dir.FullName
  $parent = Get-NormalizedSuperBrainRoot $Root
  $name = Split-Path -Leaf $full
  if (-not $full.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing outside package root: $full" }
  if ($name -notlike 'install-backup-*') { throw "Refusing non install backup: $full" }
  Remove-Item -LiteralPath $dir.FullName -Recurse -Force
  Write-Host "INSTALL_BACKUP_DELETED $($dir.FullName)"
}

Write-Host 'INSTALL_BACKUP_CLEANUP_OK'
