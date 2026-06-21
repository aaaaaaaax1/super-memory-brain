param(
  [switch]$Force,
  [int]$MaxAgeMinutes = 720,
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path $Root 'memory\workspace'
$statePath = Join-Path $workspace 'super-brain-state.json'
$statusPath = Join-Path $workspace 'last-verify-package.json'
$needsVerify = $Force
$usedState = $false

if (-not $needsVerify -and (Test-Path $statePath)) {
  try {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $updatedAt = [datetime]::ParseExact($state.updatedAt, 'yyyy-MM-dd HH:mm:ss', $null)
    $fresh = (((Get-Date) - $updatedAt).TotalMinutes -le $MaxAgeMinutes)
    if ($fresh -and $state.ok -eq $true -and $state.hookOk -eq $true -and $state.lastVerifyOk -eq $true) {
      $usedState = $true
    } else {
      $needsVerify = $true
    }
  } catch {
    $needsVerify = $true
  }
}

if (-not $usedState -and -not $needsVerify) {
  if (-not (Test-Path $statusPath)) {
    $needsVerify = $true
  } else {
    try {
      $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $checkedAt = [datetime]::ParseExact($status.checkedAt, 'yyyy-MM-dd HH:mm:ss', $null)
      if (((Get-Date) - $checkedAt).TotalMinutes -gt $MaxAgeMinutes) { $needsVerify = $true }
      if ($status.ok -ne $true) { $needsVerify = $true }
    } catch {
      $needsVerify = $true
    }
  }
}

if ($needsVerify) {
  & (Join-Path $PSScriptRoot 'verify-package.ps1') | Out-Host
  if ($LASTEXITCODE -ne 0) {
    if ($Json -and (Test-Path $statusPath)) { Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 }
    exit 1
  }
  & (Join-Path $PSScriptRoot 'update-state.ps1') | Out-Null
}

if ($Json) {
  if (Test-Path $statePath) { Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 }
  elseif (Test-Path $statusPath) { Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 }
} else {
  if (Test-Path $statePath) {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "AUTO_CHECK_OK source=state version=$($state.version) updatedAt=$($state.updatedAt) state=$statePath"
  } else {
    $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "AUTO_CHECK_OK source=verify version=$($status.version) checkedAt=$($status.checkedAt) status=$statusPath"
  }
}
