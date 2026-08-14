param(
  [int]$Keep = 1,
  [int]$KeepTransactions = 3,
  [int]$KeepRolledBackTransactions = 5,
  [switch]$Apply
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$installBackupRoot = Get-SuperBrainInstallBackupRoot $Root
$transactionRoot = Join-Path (Get-SuperBrainArchiveRoot $Root) 'install-transactions'
if ($Keep -lt 0 -or $KeepTransactions -lt 0 -or $KeepRolledBackTransactions -lt 0) { throw 'Retention counts must be zero or greater.' }

$backups = if (Test-Path -LiteralPath $installBackupRoot) { @(Get-ChildItem -LiteralPath $installBackupRoot -Directory -Filter 'install-backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending) } else { @() }
$delete = @($backups | Select-Object -Skip $Keep)

function Get-TransactionEntries([string]$RootPath) {
  if (-not (Test-Path -LiteralPath $RootPath)) { return @() }
  $entries = @()
  foreach ($dir in @(Get-ChildItem -LiteralPath $RootPath -Directory -Filter 'install-transaction-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
    $manifestPath = Join-Path $dir.FullName 'transaction.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $entries += [pscustomobject]@{ dir=$dir; status=[string]$manifest.status; manifest=$manifestPath }
    } catch {
      Write-Host "INSTALL_TRANSACTION_CLEANUP_SKIP invalidManifest=$manifestPath"
    }
  }
  return @($entries)
}

$transactions = @(Get-TransactionEntries $transactionRoot)
$committedTransactions = @($transactions | Where-Object { $_.status -eq 'committed' })
$rolledBackTransactions = @($transactions | Where-Object { $_.status -eq 'rolled_back' })
$transactionDelete = @(
  @($committedTransactions | Select-Object -Skip $KeepTransactions) +
  @($rolledBackTransactions | Select-Object -Skip $KeepRolledBackTransactions)
)

Write-Host "INSTALL_BACKUP_CLEANUP total=$($backups.Count) keep=$Keep delete=$($delete.Count) apply=$Apply"
foreach ($dir in $backups | Select-Object -First $Keep) {
  Write-Host "INSTALL_BACKUP_KEEP $($dir.FullName)"
}
foreach ($dir in $delete) {
  Write-Host "INSTALL_BACKUP_DELETE_CANDIDATE $($dir.FullName)"
}
Write-Host "INSTALL_TRANSACTION_CLEANUP committed=$($committedTransactions.Count) keepCommitted=$KeepTransactions rolledBack=$($rolledBackTransactions.Count) keepRolledBack=$KeepRolledBackTransactions delete=$($transactionDelete.Count) apply=$Apply"
foreach ($entry in $transactionDelete) {
  Write-Host "INSTALL_TRANSACTION_DELETE_CANDIDATE status=$($entry.status) path=$($entry.dir.FullName)"
}

if (-not $Apply) {
  Write-Host 'INSTALL_BACKUP_CLEANUP_DRY_RUN use -Apply to delete candidates.'
  exit 0
}

foreach ($dir in $delete) {
  $full = Get-NormalizedSuperBrainRoot $dir.FullName
  $parent = Get-NormalizedSuperBrainRoot $installBackupRoot
  $name = Split-Path -Leaf $full
  if (-not $full.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing outside install backup root: $full" }
  if ($name -notlike 'install-backup-*') { throw "Refusing non install backup: $full" }
  Remove-Item -LiteralPath $dir.FullName -Recurse -Force
  Write-Host "INSTALL_BACKUP_DELETED $($dir.FullName)"
}

foreach ($entry in $transactionDelete) {
  $full = Get-NormalizedSuperBrainRoot $entry.dir.FullName
  $parent = Get-NormalizedSuperBrainRoot $transactionRoot
  $name = Split-Path -Leaf $full
  if (-not $full.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing outside install transaction root: $full" }
  if ($name -notlike 'install-transaction-*') { throw "Refusing non install transaction: $full" }
  if ($entry.status -notin @('committed','rolled_back')) { throw "Refusing transaction with unresolved status: $full" }
  Remove-Item -LiteralPath $entry.dir.FullName -Recurse -Force
  Write-Host "INSTALL_TRANSACTION_DELETED status=$($entry.status) path=$($entry.dir.FullName)"
}

Write-Host 'INSTALL_BACKUP_CLEANUP_OK'
