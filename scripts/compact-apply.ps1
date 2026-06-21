param(
  [switch]$WhatIfOnly,
  [switch]$Force
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryPath = Join-Path (Get-SuperBrainActiveMemoryRoot $Root) 'sandglass.txt'
if (-not (Test-Path $memoryPath)) { throw "Missing memory file: $memoryPath" }

$lines = @(Get-Content -LiteralPath $memoryPath -Encoding UTF8)
$seen = @{}
$out = @()
$removed = 0
foreach ($line in $lines) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $key = $line -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| [^|]+ \| ', ''
  if ($seen.ContainsKey($key)) {
    $removed += 1
    continue
  }
  $seen[$key] = $true
  $out += $line
}

if ($WhatIfOnly) {
  Write-Host "COMPACT_APPLY_DRY_RUN wouldRemove=$removed memory=$memoryPath"
  exit 0
}

if ($removed -gt 0) {
  if (-not $Force) {
    Write-Host "COMPACT_APPLY_CONFIRM_REQUIRED wouldRemove=$removed memory=$memoryPath use=-Force"
    exit 0
  }

  $backup = "$memoryPath.bak-compact-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item -LiteralPath $memoryPath -Destination $backup -Force
  Set-Content -LiteralPath $memoryPath -Value $out -Encoding UTF8
  Write-Host "COMPACT_APPLY_OK removed=$removed backup=$backup"
} else {
  Write-Host "COMPACT_APPLY_NO_CHANGE memory=$memoryPath"
}
