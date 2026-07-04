param(
  [switch]$Force,
  [int]$MaxAgeMinutes = 720,
  [switch]$VerifyIfStale,
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path $Root 'memory\workspace'
$statePath = Join-Path $workspace 'super-brain-state.json'
$statusPath = Join-Path $workspace 'last-verify-package.json'
$needsVerify = $Force
$usedState = $false
$staleReason = if ($Force) { 'force' } else { '' }

function Get-CompactAutoCheckResult {
  $state = $null
  $status = $null
  if (Test-Path $statePath) { try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  if (Test-Path $statusPath) { try { $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  return [pscustomobject]@{
    ok = if ($state) { [bool]$state.ok } elseif ($status) { [bool]$status.ok } else { $false }
    source = if ($state) { 'state' } elseif ($status) { 'verify' } else { 'missing' }
    version = if ($state) { [string]$state.version } elseif ($status) { [string]$status.version } else { '' }
    updatedAt = if ($state) { [string]$state.updatedAt } else { '' }
    checkedAt = if ($status) { [string]$status.checkedAt } else { '' }
    hookOk = if ($state) { $state.hookOk } else { $null }
    lastVerifyOk = if ($state) { $state.lastVerifyOk } elseif ($status) { $status.ok } else { $null }
    stale = [bool]$script:needsVerify
    staleReason = [string]$script:staleReason
    verifySuggested = [bool]($script:needsVerify -and -not $Force -and -not $VerifyIfStale)
    statePath = if (Test-Path $statePath) { $statePath } else { '' }
    verifyPath = if (Test-Path $statusPath) { $statusPath } else { '' }
    note = 'Compact auto-check output. Default mode does not run full verify on stale state; use -Force or -VerifyIfStale for verification.'
  }
}

if (-not $needsVerify -and (Test-Path $statePath)) {
  try {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $updatedAt = [datetime]::ParseExact($state.updatedAt, 'yyyy-MM-dd HH:mm:ss', $null)
    $fresh = (((Get-Date) - $updatedAt).TotalMinutes -le $MaxAgeMinutes)
    if ($fresh -and $state.ok -eq $true -and $state.hookOk -eq $true -and $state.lastVerifyOk -eq $true) {
      $usedState = $true
    } else {
      $needsVerify = $true
      if (-not $fresh) { $staleReason = 'state_stale' }
      elseif ($state.ok -ne $true) { $staleReason = 'state_not_ok' }
      elseif ($state.hookOk -ne $true) { $staleReason = 'hook_not_ok' }
      elseif ($state.lastVerifyOk -ne $true) { $staleReason = 'last_verify_not_ok' }
      else { $staleReason = 'state_unusable' }
    }
  } catch {
    $needsVerify = $true
    $staleReason = 'state_parse_failed'
  }
}

if (-not $usedState -and -not $needsVerify) {
  if (-not (Test-Path $statusPath)) {
    $needsVerify = $true
    $staleReason = 'verify_missing'
  } else {
    try {
      $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $checkedAt = [datetime]::ParseExact($status.checkedAt, 'yyyy-MM-dd HH:mm:ss', $null)
      if (((Get-Date) - $checkedAt).TotalMinutes -gt $MaxAgeMinutes) { $needsVerify = $true; $staleReason = 'verify_stale' }
      if ($status.ok -ne $true) { $needsVerify = $true; $staleReason = 'verify_not_ok' }
    } catch {
      $needsVerify = $true
      $staleReason = 'verify_parse_failed'
    }
  }
}

if ($needsVerify -and -not $Force -and -not $VerifyIfStale) {
  if ($Json) { Get-CompactAutoCheckResult | ConvertTo-Json -Depth 8 } else { Write-Host "AUTO_CHECK_STALE reason=$staleReason verifySuggested=True state=$statePath status=$statusPath" }
  exit 0
}

if ($needsVerify) {
  if ($Json) {
    $null = @(& (Join-Path $PSScriptRoot 'verify-package.ps1') 2>&1)
  } else {
    & (Join-Path $PSScriptRoot 'verify-package.ps1') | Out-Host
  }
  if ($LASTEXITCODE -ne 0) {
    if ($Json) { Get-CompactAutoCheckResult | ConvertTo-Json -Depth 8 }
    exit 1
  }
  & (Join-Path $PSScriptRoot 'update-state.ps1') | Out-Null
  $needsVerify = $false
  $staleReason = ''
}

if ($Json) {
  Get-CompactAutoCheckResult | ConvertTo-Json -Depth 8
} else {
  if (Test-Path $statePath) {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "AUTO_CHECK_OK source=state version=$($state.version) updatedAt=$($state.updatedAt) state=$statePath"
  } else {
    $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "AUTO_CHECK_OK source=verify version=$($status.version) checkedAt=$($status.checkedAt) status=$statusPath"
  }
}
