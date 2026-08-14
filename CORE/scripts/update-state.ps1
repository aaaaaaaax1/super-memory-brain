param(
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$MemoryRoot = "",
  [switch]$AllowStaleVerify,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) {
  $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root
}
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$statePath = Join-Path $workspace 'super-brain-state.json'

$manifest = Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$startup = $null
try {
  $startupText = & (Join-Path $PSScriptRoot 'startup-check.ps1') -ZCodeSkills $ZCodeSkills -CodexSkills $CodexSkills -MemoryRoot $MemoryRoot -Json
  $startup = $startupText | ConvertFrom-Json
} catch {
  $startup = [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
}

$lastVerifyPath = Join-Path $workspace 'last-verify-package.json'
$lastVerifyOk = $false
$lastVerifyAt = $null
$verificationState = 'not_run'
if (Test-Path $lastVerifyPath) {
  try {
    $lastVerify = Get-Content -LiteralPath $lastVerifyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lastVerifyOk = ($lastVerify.ok -eq $true)
    $lastVerifyAt = $lastVerify.checkedAt
    if (-not $lastVerifyOk) {
      $verificationState = 'failed'
    } else {
      $parsedVerifyAt = [DateTimeOffset]::MinValue
      if ([string]::IsNullOrWhiteSpace([string]$lastVerifyAt) -or -not [DateTimeOffset]::TryParse([string]$lastVerifyAt,[ref]$parsedVerifyAt)) {
        $verificationState = 'invalid'
      } else {
        $verificationAgeMinutes = ((Get-SuperBrainUtcNow) - $parsedVerifyAt.ToUniversalTime()).TotalMinutes
        if ($verificationAgeMinutes -lt 0) { $verificationState = 'future' }
        elseif ($verificationAgeMinutes -gt 720) { $verificationState = 'stale' }
        else { $verificationState = 'passed' }
      }
    }
  } catch { $verificationState = 'invalid' }
}
$verificationPassed = ($verificationState -eq 'passed')

$startupCoreAvailable = if ($startup.PSObject.Properties['coreAvailable']) { [bool]$startup.coreAvailable } else { [bool]$startup.ok }
$legacyStrictOk = ($startupCoreAvailable -and $verificationPassed)
$startupRetiredTransportGuard = if ($startup.PSObject.Properties['retiredTransportGuard']) {
  $startup.retiredTransportGuard
} else {
  [pscustomobject]@{
    schema='super-brain.retired-transport-guard.v1'
    state='unknown'
    code='H7_RETIRED_TRANSPORT_GUARD_UNAVAILABLE'
    requiredForCore=$true
    h7Transport=[pscustomobject]@{ mode='hookless_turn_runtime'; primary='mcp'; fallback='same_h7_cli'; entryAvailable=$false }
    superBrainHookRegistration=[pscustomobject]@{ state='unverifiable'; registered=$null; configurationReadable=$false }
    actionAuthorization='not_authorizing'
    legacyDependency='none'
    rawPromptStored=$false
    rawTranscriptStored=$false
  }
}
$startupActivation = if ($startup.PSObject.Properties['activation']) {
  $startup.activation
} else {
  [pscustomobject]@{ state='withheld'; fullBrainActive=$false; code='ACTIVATION_AXIS_MISSING'; activationId=''; receiptHash=''; coreReady=$false; rawPromptStored=$false }
}

$state = [pscustomobject]@{
  schema = 'super-brain.state.v2'
  # Compatibility only: `ok` preserves the old strict readiness projection.
  # Callers that need operational health must use coreAvailable explicitly.
  ok = $legacyStrictOk
  okScope = 'legacy_strict_core_and_current_verification'
  coreAvailable = $startupCoreAvailable
  operational = [pscustomobject]@{
    state = if ($startupCoreAvailable) { 'available' } else { 'unavailable' }
    available = $startupCoreAvailable
  }
  verification = [pscustomobject]@{
    state = $verificationState
    passed = $verificationPassed
    lastResultOk = $lastVerifyOk
    checkedAt = $lastVerifyAt
    requiredForCore = $false
    gateSatisfied = $verificationPassed
  }
  version = $manifest.version
  packageRoot = $Root
  memoryRoot = $MemoryRoot
  retiredTransportGuard = $startupRetiredTransportGuard
  activation = $startupActivation
  fullBrainActive = [bool]$startupActivation.fullBrainActive
  startupStrictOk = [bool]$startup.ok
  lastVerifyOk = $lastVerifyOk
  lastVerifyAt = $lastVerifyAt
  updatedAt = Get-SuperBrainUtcTimestamp
}
Write-JsonUtf8NoBom $statePath $state 5

if ($Json) {
  Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
} else {
  Write-Host "STATE_UPDATE_OK $statePath version=$($state.version) transportGuard=$($state.retiredTransportGuard.state)"
}

$maintenanceExitAllowed = ($startupCoreAvailable -and ($verificationState -eq 'passed' -or (($AllowStaleVerify -eq $true) -and $verificationState -eq 'stale')))
if (-not $maintenanceExitAllowed) { exit 1 }
exit 0
