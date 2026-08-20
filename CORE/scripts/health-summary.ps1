param(
  [switch]$Json,
  [switch]$AllowActiveCheckpoint
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'

function Convert-ToolJson([object[]]$Output, [string]$ScriptName) {
  $jsonStart = -1
  for ($index = 0; $index -lt $Output.Count; $index++) {
    if ([string]$Output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
  }
  if ($jsonStart -lt 0) { return [pscustomobject]@{ ok=$false; error="No JSON from $ScriptName" } }
  return ((@($Output[$jsonStart..($Output.Count - 1)]) -join "`n") | ConvertFrom-Json)
}

$dashboardArgs = @{ Mode='Full'; Json=$true }
if ($AllowActiveCheckpoint) { $dashboardArgs.AllowActiveCheckpoint = $true }
$dashboard = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') @dashboardArgs 6>$null) 'super-brain-dashboard.ps1'
$doctor = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'doctor.ps1') -Json 6>$null) 'doctor.ps1'
$smartNext = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'smart-next.ps1') -Json 6>$null) 'smart-next.ps1'
$extensions = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'verify-extensions.ps1') -Json 6>$null) 'verify-extensions.ps1'

# Performance is a separate health axis.  Do not hide a runtime budget breach
# behind ``dashboard.ok`` or an empty static risk list, and do not claim that a
# missing telemetry sample is healthy.  Full diagnostics may inspect the most
# recently updated bounded telemetry projection; the fast status path never
# performs this scan.
$telemetryRoot = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $SuperBrainRoot) 'workspace') 'runtime-state\turn-runtime\telemetry'
$latestTelemetry = Get-ChildItem -LiteralPath $telemetryRoot -Filter '*.json' -File -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
$runtimePerformance = [pscustomobject]@{
  state = 'not_available'
  code = 'H7_RUNTIME_PERFORMANCE_SAMPLE_MISSING'
  p50Ms = $null
  p95Ms = $null
  maxMs = $null
  sampleCount = 0
  slowestPhase = ''
  checkedAt = $null
}
if ($latestTelemetry) {
  try {
    $telemetry = Get-Content -LiteralPath $latestTelemetry.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $observability = $telemetry.runObservability
    if ($observability) {
      $latency = $observability.runtimeLatency
      $slowestPhase = ''
      $events = @($telemetry.events | Where-Object { $_.runtimeDurationMs -ne $null } | Sort-Object runtimeDurationMs -Descending)
      if ($events.Count -gt 0) { $slowestPhase = [string]$events[0].phase }
      $runtimePerformance = [pscustomobject]@{
        state = [string]$observability.state
        code = [string]$observability.code
        p50Ms = if ($latency) { $latency.p50Ms } else { $null }
        p95Ms = if ($latency) { $latency.p95Ms } else { $null }
        maxMs = if ($latency) { $latency.maxMs } else { $null }
        sampleCount = [int]($observability.measuredSampleCount)
        slowestPhase = $slowestPhase
        checkedAt = $latestTelemetry.LastWriteTime.ToString('o')
      }
    }
  } catch {
    $runtimePerformance = [pscustomobject]@{
      state = 'invalid'
      code = 'H7_RUNTIME_PERFORMANCE_SAMPLE_INVALID'
      p50Ms = $null
      p95Ms = $null
      maxMs = $null
      sampleCount = 0
      slowestPhase = ''
      checkedAt = $latestTelemetry.LastWriteTime.ToString('o')
    }
  }
}

$summaryLines = @(
  "version=$($dashboard.version)",
  "ready=$($dashboard.ok)",
  "coreAvailable=$($doctor.coreAvailable)",
  "transportGuard=$($doctor.retiredTransportGuard.state)",
  "transportCode=$($doctor.retiredTransportGuard.code)",
  "verify=$($dashboard.verify.ok)",
  "hotRefresh=$($dashboard.hotRefresh.ok)",
  "privacy=$($dashboard.privacy.ok)",
  "reviewGate=$($dashboard.reviewGate.ok)",
  "risks=$(@($dashboard.risks).Count)",
  "locks=$($doctor.lockHealth.lockCount)/stale=$($doctor.lockHealth.staleCount)",
  "tools=$($doctor.toolHealth.warningFresh)",
  "extensions=$($extensions.extensionCount)/$($extensions.skillCount)",
  "performance=$($runtimePerformance.state) p95=$($runtimePerformance.p95Ms)ms max=$($runtimePerformance.maxMs)ms phase=$($runtimePerformance.slowestPhase)",
  "next=$($smartNext.nextAction)"
)

$result = [pscustomobject]@{
  ok = ($dashboard.ok -eq $true -and $doctor.ok -eq $true -and $extensions.ok -eq $true)
  checkedAt = Get-SuperBrainUtcTimestamp
  version = $dashboard.version
  ready = $dashboard.ok
  coreAvailable = [bool]$doctor.coreAvailable
  retiredTransportGuard = $doctor.retiredTransportGuard
  summary = ($summaryLines -join '; ')
  risks = @($dashboard.risks)
  riskSummary = $doctor.riskSummary
  lockHealth = $doctor.lockHealth
  toolHealth = $doctor.toolHealth
  extensions = [pscustomobject]@{ ok=$extensions.ok; extensionCount=$extensions.extensionCount; skillCount=$extensions.skillCount; collisionCount=$extensions.collisionCount }
  nextAction = $smartNext.nextAction
  runtimePerformance = $runtimePerformance
  recentTask = $dashboard.task.summary
  commands = @('scripts\smart-next.ps1 -Json','scripts\super-brain-dashboard.ps1 -Json','scripts\doctor.ps1 -Json','scripts\verify-extensions.ps1 -Json')
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "HEALTH_SUMMARY $($result.summary)"
  if (@($result.risks).Count -gt 0) { foreach ($risk in @($result.risks)) { Write-Host "RISK $risk" } }
}
if (-not $result.ok) { exit 1 }
exit 0
