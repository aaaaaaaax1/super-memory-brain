param(
  [int]$MaxAgeHours = 48,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$warningPath = Join-Path $workspace 'last-tool-schema-warning.json'
$warning = $null
if (Test-Path $warningPath) {
  try { $warning = Get-Content -LiteralPath $warningPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $warning = $null }
}

$stale = $true
if ($warning -and $warning.checkedAt) {
  try { $stale = ([datetime]::Parse([string]$warning.checkedAt).AddHours($MaxAgeHours) -lt (Get-Date)) } catch { $stale = $true }
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  warningExists = (Test-Path $warningPath)
  warningFresh = ($warning -and -not $stale)
  maxAgeHours = $MaxAgeHours
  warningPath = $warningPath
  warning = if ($warning) { $warning } else { $null }
  recommendation = if ($warning -and -not $stale) { 'Optional tool schema warning is recent; use checkpoint/status fallback and inspect host tool schema if it recurs.' } else { 'No recent optional tool schema warning.' }
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else {
  Write-Host "TOOL_HEALTH ok=True warningExists=$($result.warningExists) warningFresh=$($result.warningFresh) path=$warningPath"
}
exit 0
