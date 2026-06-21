param(
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $Root 'memory\workspace\super-brain-state.json'
if (-not (Test-Path $statePath)) {
  & (Join-Path $PSScriptRoot 'update-state.ps1') | Out-Null
}

if ($Json) {
  Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
  exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host "SUPER_BRAIN_STATE version=$($state.version) ok=$($state.ok) hookOk=$($state.hookOk) lastVerifyOk=$($state.lastVerifyOk) updatedAt=$($state.updatedAt)"
Write-Host "package=$($state.packageRoot)"
Write-Host "memory=$($state.memoryRoot)"
