param(
  [switch]$Force,
  [int]$MaxAgeMinutes = 720,
  [switch]$VerifyIfStale,
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statePath = Join-Path $workspace 'super-brain-state.json'
$statusPath = Join-Path $workspace 'last-verify-package.json'
$needsVerify = $Force
$usedState = $false
$staleReason = if ($Force) { 'force' } else { '' }

function Get-SuperBrainVerificationAxis([object]$State,[object]$Verify) {
  if ($State -and $State.PSObject.Properties['verification'] -and $State.verification) {
    $axis = $State.verification
    return [pscustomobject]@{
      state = if ($axis.PSObject.Properties['state']) { [string]$axis.state } else { if ($axis.passed -eq $true) { 'passed' } else { 'failed' } }
      passed = [bool]$axis.passed
      lastResultOk = if ($axis.PSObject.Properties['lastResultOk']) { [bool]$axis.lastResultOk } else { [bool]$axis.passed }
      checkedAt = if ($axis.PSObject.Properties['checkedAt']) { [string]$axis.checkedAt } else { [string]$State.lastVerifyAt }
      requiredForCore = if ($axis.PSObject.Properties['requiredForCore']) { [bool]$axis.requiredForCore } else { $false }
    }
  }
  if ($State) {
    $passed = [bool]$State.lastVerifyOk
    return [pscustomobject]@{ state=if($passed){'passed'}else{'failed'}; passed=$passed; lastResultOk=$passed; checkedAt=[string]$State.lastVerifyAt; requiredForCore=$false }
  }
  if ($Verify) {
    $passed = [bool]$Verify.ok
    return [pscustomobject]@{ state=if($passed){'passed'}else{'failed'}; passed=$passed; lastResultOk=$passed; checkedAt=[string]$Verify.checkedAt; requiredForCore=$false }
  }
  return [pscustomobject]@{ state='not_run'; passed=$false; lastResultOk=$false; checkedAt=''; requiredForCore=$false }
}

function Get-SuperBrainEffectiveVerificationAxis([object]$Axis,[int]$AgeMinutes) {
  $declared = [string]$Axis.state
  if ($declared -in @('not_run','invalid','failed')) {
    return [pscustomobject]@{ state=$declared; passed=$false; lastResultOk=[bool]$Axis.lastResultOk; checkedAt=[string]$Axis.checkedAt; requiredForCore=[bool]$Axis.requiredForCore }
  }
  if (-not [bool]$Axis.lastResultOk) {
    return [pscustomobject]@{ state='failed'; passed=$false; lastResultOk=$false; checkedAt=[string]$Axis.checkedAt; requiredForCore=[bool]$Axis.requiredForCore }
  }
  $checkedAt = ConvertFrom-SuperBrainTimestamp ([string]$Axis.checkedAt)
  if ($null -eq $checkedAt) {
    return [pscustomobject]@{ state='invalid'; passed=$false; lastResultOk=$true; checkedAt=[string]$Axis.checkedAt; requiredForCore=[bool]$Axis.requiredForCore }
  }
  $now = Get-SuperBrainUtcNow
  if ($checkedAt -gt $now) {
    return [pscustomobject]@{ state='future'; passed=$false; lastResultOk=$true; checkedAt=[string]$Axis.checkedAt; requiredForCore=[bool]$Axis.requiredForCore }
  }
  if (($now - $checkedAt).TotalMinutes -gt $AgeMinutes) {
    return [pscustomobject]@{ state='stale'; passed=$false; lastResultOk=$true; checkedAt=[string]$Axis.checkedAt; requiredForCore=[bool]$Axis.requiredForCore }
  }
  return [pscustomobject]@{ state='passed'; passed=$true; lastResultOk=$true; checkedAt=[string]$Axis.checkedAt; requiredForCore=[bool]$Axis.requiredForCore }
}

function Get-CompactAutoCheckResult {
  $state = $null
  $status = $null
  if (Test-Path $statePath) { try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  if (Test-Path $statusPath) { try { $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  $coreAvailable = if ($state -and $state.PSObject.Properties['coreAvailable']) { [bool]$state.coreAvailable } elseif ($state) { [bool]$state.ok } else { $false }
  $verification = Get-SuperBrainEffectiveVerificationAxis (Get-SuperBrainVerificationAxis $state $status) $MaxAgeMinutes
  return [pscustomobject]@{
    ok = [bool]($coreAvailable -and $verification.passed)
    okScope = 'strict_cache_verification'
    source = if ($state) { 'state' } elseif ($status) { 'verify' } else { 'missing' }
    version = if ($state) { [string]$state.version } elseif ($status) { [string]$status.version } else { '' }
    updatedAt = if ($state) { [string]$state.updatedAt } else { '' }
    checkedAt = if ($status) { [string]$status.checkedAt } else { '' }
    coreAvailable = $coreAvailable
    verification = $verification
    cacheReady = [bool]($coreAvailable -and $verification.passed -and -not $script:needsVerify)
    hookOk = if ($state) { $state.hookOk } else { $null }
    hookAcceleration = if ($state -and $state.PSObject.Properties['hookAcceleration']) { $state.hookAcceleration } else { $null }
    p7 = if ($state -and $state.PSObject.Properties['p7']) { $state.p7 } else { $null }
    lastVerifyOk = $verification.lastResultOk
    stale = [bool]$script:needsVerify
    staleReason = [string]$script:staleReason
    verifySuggested = [bool]($script:needsVerify -and -not $Force -and -not $VerifyIfStale)
    statePath = if (Test-Path $statePath) { $statePath } else { '' }
    verifyPath = if (Test-Path $statusPath) { $statusPath } else { '' }
    note = 'Compact auto-check output. Default mode does not run full verify on stale state; use -Force or -VerifyIfStale for verification.'
  }
}

function ConvertFrom-SuperBrainTimestamp([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $parsed = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AllowWhiteSpaces,[ref]$parsed)) { return $null }
  return $parsed.ToUniversalTime()
}

if (-not $needsVerify -and (Test-Path $statePath)) {
  try {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $updatedAt = ConvertFrom-SuperBrainTimestamp ([string]$state.updatedAt)
    $now = Get-SuperBrainUtcNow
    $stateFuture = ($null -ne $updatedAt -and $updatedAt -gt $now)
    $stateFresh = ($null -ne $updatedAt -and -not $stateFuture -and ($now - $updatedAt).TotalMinutes -le $MaxAgeMinutes)
    $coreAvailable = if ($state.PSObject.Properties['coreAvailable']) { [bool]$state.coreAvailable } else { [bool]$state.ok }
    $verification = Get-SuperBrainEffectiveVerificationAxis (Get-SuperBrainVerificationAxis $state $null) $MaxAgeMinutes
    if ($stateFresh -and $coreAvailable -and $verification.passed) {
      $usedState = $true
    } else {
      $needsVerify = $true
      if ($stateFuture) { $staleReason = 'state_from_future' }
      elseif (-not $stateFresh) { $staleReason = 'state_stale' }
      elseif (-not $coreAvailable) { $staleReason = 'core_not_available' }
      elseif ($verification.state -eq 'future') { $staleReason = 'verify_from_future' }
      elseif ($verification.state -eq 'stale') { $staleReason = 'verify_stale' }
      elseif ($verification.state -eq 'invalid') { $staleReason = 'verify_invalid' }
      elseif ($verification.state -eq 'not_run') { $staleReason = 'verify_missing' }
      elseif ($verification.state -eq 'failed') { $staleReason = 'last_verify_not_ok' }
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
      $verification = Get-SuperBrainEffectiveVerificationAxis (Get-SuperBrainVerificationAxis $null $status) $MaxAgeMinutes
      if (-not $verification.passed) {
        $needsVerify = $true
        $staleReason = switch ($verification.state) {
          'future' { 'verify_from_future' }
          'stale' { 'verify_stale' }
          'invalid' { 'verify_invalid' }
          'not_run' { 'verify_missing' }
          default { 'verify_not_ok' }
        }
      }
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
