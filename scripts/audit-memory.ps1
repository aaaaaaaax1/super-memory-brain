. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$Sandglass = Join-Path $MemoryRoot 'sandglass.txt'
$Policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not (Test-Path $Sandglass)) {
  Write-Host "MISSING sandglass: $Sandglass"
  exit 1
}

$lines = Get-Content -LiteralPath $Sandglass -Encoding UTF8
$total = $lines.Count
Write-Host "Memory root: $MemoryRoot"
Write-Host "Total memories: $total"

$tags = @('[CURRENT]','[VERIFIED]','[HISTORY]','[STALE]','[BLOCKER]','[KNOWN_LIMITATION]','[PRIVACY]','[DECISION]')
$tagCounts = @{}
foreach ($tag in $tags) { $tagCounts[$tag] = 0 }
$untagged = 0

foreach ($line in $lines) {
  if (-not $line) { continue }
  $parts = $line -split ' \| ', 3
  $text = if ($parts.Count -ge 3) { $parts[2].Trim() } else { $line.Trim() }
  $prefixMatch = [regex]::Match($text, '^\s*(?:\[[A-Z_]+\]\s*)+')
  if ($prefixMatch.Success) {
    $prefix = $prefixMatch.Value
    foreach ($tag in $tags) {
      if ($prefix.Contains($tag)) { $tagCounts[$tag] += 1 }
    }
  } else {
    $untagged += 1
  }
}

foreach ($tag in $tags) {
  Write-Host "$tag $($tagCounts[$tag])"
}
Write-Host "Untagged: $untagged"

$long = ($lines | Where-Object { $_.Length -gt [int]$Policy.maxMemoryChars }).Count
Write-Host "Too long: $long"

$privatePatterns = @()
if ($Policy.privatePatterns) { $privatePatterns = $Policy.privatePatterns }
elseif ($Policy.denyPatterns) { $privatePatterns = $Policy.denyPatterns }

foreach ($pattern in $privatePatterns) {
  $hits = ($lines | Where-Object { $_.ToLowerInvariant().Contains($pattern.ToLowerInvariant()) }).Count
  if ($hits -gt 0) { Write-Host "Possible private pattern '$pattern': $hits" }
}

Write-Host "`nRecent 10:"
$lines | Select-Object -Last 10
