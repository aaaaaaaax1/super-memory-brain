param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$healthJson = & (Join-Path $PSScriptRoot 'memory-health.ps1') -Json
$health = $null
try { $health = $healthJson | ConvertFrom-Json } catch {}

$privateHits = 0
if ($health -and $null -ne $health.privatePatternHits) { $privateHits = [int]$health.privatePatternHits }
elseif ($health -and $null -ne $health.privateHits) { $privateHits = [int]$health.privateHits }

$recommendations = @()
if ($privateHits -gt 0) {
  $recommendations += 'Review memory-health private-pattern hits before sharing memory or creating private releases.'
  $recommendations += 'Do not auto-delete memory; inspect source lines and confirm whether they are false positives or private data.'
} else {
  $recommendations += 'No private-pattern hits reported by memory-health.'
}

$result = [pscustomobject]@{
  ok = ($privateHits -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  memoryRoot = $memoryRoot
  privatePatternHits = $privateHits
  shareSafe = ($privateHits -eq 0)
  recommendations = @($recommendations)
  source = 'memory-health.ps1'
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "PRIVACY_SENTINEL ok=$($result.ok) privatePatternHits=$privateHits shareSafe=$($result.shareSafe)"
  foreach ($recommendation in @($recommendations)) { Write-Host "PRIVACY_SENTINEL_RECOMMENDATION $recommendation" }
}
if (-not $result.ok) { exit 1 }
exit 0
