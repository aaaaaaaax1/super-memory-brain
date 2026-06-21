param(
  [switch]$Apply
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$Sandglass = Join-Path $memoryRoot 'sandglass.txt'
$Tags = @('[CURRENT]','[VERIFIED]','[HISTORY]','[STALE]','[BLOCKER]','[KNOWN_LIMITATION]','[PRIVACY]','[DECISION]')

if (-not (Test-Path $Sandglass)) { throw "Missing sandglass: $Sandglass" }
$lines = Get-Content -LiteralPath $Sandglass -Encoding UTF8
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
  $backup = "$Sandglass.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item -LiteralPath $Sandglass -Destination $backup -Force
  Set-Content -LiteralPath $Sandglass -Value $newLines -Encoding UTF8
  Remove-Item -LiteralPath (Join-Path $memoryRoot 'sandglass.idx') -ErrorAction SilentlyContinue
  Write-Host "TAGGED_LEGACY_MEMORY backup=$backup"
} else {
  Write-Host 'Dry run only. Rerun with -Apply to modify sandglass.txt.'
}
