param(
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')
$statePath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'super-brain-state.json'
if (-not (Test-Path $statePath)) {
  & (Join-Path $PSScriptRoot 'update-state.ps1') | Out-Null
}

if ($Json) {
  Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
  exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$coreAvailable = if ($state.PSObject.Properties['coreAvailable']) { [bool]$state.coreAvailable } else { [bool]$state.ok }
$transportGuardState = if ($state.PSObject.Properties['retiredTransportGuard'] -and $state.retiredTransportGuard) { [string]$state.retiredTransportGuard.state } else { 'unknown' }
$transportGuardCode = if ($state.PSObject.Properties['retiredTransportGuard'] -and $state.retiredTransportGuard) { [string]$state.retiredTransportGuard.code } else { 'H7_RETIRED_TRANSPORT_GUARD_UNAVAILABLE' }
$verificationState = if ($state.PSObject.Properties['verification'] -and $state.verification) { [string]$state.verification.state } elseif ($state.lastVerifyOk -eq $true) { 'passed' } else { 'failed' }
Write-Host "SUPER_BRAIN_STATE version=$($state.version) ok=$($state.ok) coreAvailable=$coreAvailable verification=$verificationState transportGuard=$transportGuardState transportCode=$transportGuardCode lastVerifyOk=$($state.lastVerifyOk) updatedAt=$($state.updatedAt)"
Write-Host "package=$($state.packageRoot)"
Write-Host "memory=$($state.memoryRoot)"
