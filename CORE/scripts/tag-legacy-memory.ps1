param(
  [switch]$Apply
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\memory-rewrite-transaction.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$Sandglass = Join-Path $memoryRoot 'sandglass.txt'
$Tags = @('[CURRENT]','[VERIFIED]','[HISTORY]','[STALE]','[BLOCKER]','[KNOWN_LIMITATION]','[PRIVACY]','[DECISION]')

if (-not (Test-Path $Sandglass)) { throw "Missing sandglass: $Sandglass" }
$lines = Get-Content -LiteralPath $Sandglass -Encoding UTF8
$sourceHash = Get-SuperBrainFileSha256 $Sandglass
$newLines = @()
$changed = 0

foreach ($line in $lines) {
  if (-not $line) { $newLines += $line; continue }
  $parts = $line -split ' \| ', 3
  if ($parts.Count -lt 3) { $newLines += $line; continue }
  $text = $parts[2].Trim()
  $hasTag = $false
  foreach ($tag in $Tags) { if ($text.StartsWith($tag) -or $text.StartsWith("$tag ")) { $hasTag = $true; break } }
  if (-not $hasTag) {
    $parts[2] = "[HISTORY] " + $parts[2]
    $newLines += ($parts -join ' | ')
    $changed += 1
  } else {
    $newLines += $line
  }
}

Write-Host "Legacy untagged candidates: $changed"
if ($Apply -and $changed -gt 0) {
  $transaction = Invoke-SuperBrainMemoryRewriteTransaction -MemoryRoot $memoryRoot -MemoryPath $Sandglass -ReplacementText (ConvertTo-SuperBrainMemoryRewriteText @($newLines)) -ExpectedSourceHash $sourceHash -TransactionKind 'tag-legacy'
  Write-Host "TAGGED_LEGACY_MEMORY backup=$($transaction.backupPath) receipt=$($transaction.receiptPath) indexes=rebuilt"
} else {
  Write-Host 'Dry run only. Rerun with -Apply to modify sandglass.txt.'
}
