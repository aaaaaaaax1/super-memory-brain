param(
  [switch]$SkipIntegration,
  [ValidateSet('Fast','Core','Full')][string]$PesterTier = 'Full',
  [ValidateRange(0,7200)][int]$StepTimeoutSeconds = 0
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$executionWorkspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statusPath = Join-Path $workspace 'last-ci.json'
$ok = $true
$steps = @()

if (-not (Test-Path $workspace)) {
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
}

function ConvertTo-CiProcessArgument([string]$Value) {
  return '"' + $Value.Replace('"','\"') + '"'
}

function Get-CiStepTimeout([string]$Name) {
  if ($StepTimeoutSeconds -gt 0) { return $StepTimeoutSeconds }
  switch ($Name) {
    'pester' { return 3900 }
    'verify-package' { return 900 }
    'verify-package-integration' { return 1200 }
    'smoke-test' { return 900 }
    default { return 300 }
  }
}

function Get-CiDiagnosticExcerpt([string]$Text,[int]$MaxChars=1600) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $clean = $Text -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
  if ($clean.Length -le $MaxChars) { return $clean.Trim() }
  return ('[truncated] ' + $clean.Substring($clean.Length - $MaxChars).Trim())
}

function Test-CiSafeProgressLine([string]$Line) {
  if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
  return $Line -match '^(VERIFY_(STEP|HEARTBEAT|PACKAGE_(OK|FAILED))|PESTER_(START|SUITE|OK|FAILED)|COLD_START_AUDIT|INSTALL_UI_REGRESSION|RUNTIME_[A-Z0-9_]+|CI_)'
}

function Invoke-CiOwnedStepWithProgress([string]$Name,[string]$ArgumentLine,[int]$TimeoutSeconds) {
  # The package lives in CORE, but H7 task scope belongs to the outer project
  # workspace.  Child checks must inherit that host workspace so they can
  # observe the same scoped checkpoint as the runtime rather than manufacture
  # a second CORE-only workspace key.
  $handle = Start-SuperBrainOwnedProcess -FilePath 'powershell.exe' -ArgumentLine $ArgumentLine -WorkingDirectory $executionWorkspaceRoot
  if (-not $handle.started) { return (Complete-SuperBrainOwnedProcess -Handle $handle -TimeoutSeconds $TimeoutSeconds) }

  $emittedLength = 0
  $lastHeartbeatUtc = [DateTime]::UtcNow
  while ($true) {
    $captured = [string](Get-SuperBrainOwnedProcessOutputSnapshot $handle).stdout
    if ($captured.Length -gt $emittedLength) {
      $delta = $captured.Substring($emittedLength)
      $emittedLength = $captured.Length
      foreach ($line in @($delta -split "`r?`n")) {
        if (Test-CiSafeProgressLine $line) {
          $safeLine = $line.Trim()
          if ($safeLine.Length -gt 320) { $safeLine = $safeLine.Substring(0,320) }
          Write-Host "CI_PROGRESS step=$Name text=$safeLine"
        }
      }
    }

    $hasExited = $false
    try { $handle.process.Refresh(); $hasExited = [bool]$handle.process.HasExited } catch { $hasExited = $true }
    if ($hasExited) { return (Complete-SuperBrainOwnedProcess -Handle $handle -TimeoutSeconds $TimeoutSeconds) }
    if ($handle.watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return (Complete-SuperBrainOwnedProcess -Handle $handle -TimedOut -TimeoutSeconds $TimeoutSeconds) }
    if (([DateTime]::UtcNow - $lastHeartbeatUtc).TotalSeconds -ge 30) {
      Write-Host "CI_HEARTBEAT step=$Name elapsedSeconds=$([int]$handle.watch.Elapsed.TotalSeconds) timeoutSeconds=$TimeoutSeconds outputChars=$captured.Length"
      $lastHeartbeatUtc = [DateTime]::UtcNow
    }
    Start-Sleep -Milliseconds 250
  }
}

function Get-CiArgumentValue([string[]]$Arguments,[string]$Name) {
  for ($index = 0; $index -lt (@($Arguments).Count - 1); $index++) {
    if ([string]$Arguments[$index] -eq $Name) { return [string]$Arguments[$index + 1] }
  }
  return ''
}

function Test-CiPesterReport([string[]]$Arguments,[object]$Outcome,[datetime]$StartedAtUtc) {
  $failureMarker = ([string]$Outcome.stdout -match '(?m)^PESTER_FAILED\b') -or ([string]$Outcome.stderr -match '(?m)^PESTER_FAILED\b')
  if ($failureMarker) { return [pscustomobject]@{ ok=$false; reason='pester_failure_marker' } }
  $reportPath = Get-CiArgumentValue $Arguments '-ReportPath'
  if ([string]::IsNullOrWhiteSpace($reportPath)) { $reportPath = Join-Path $workspace 'last-pester.json' }
  if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { return [pscustomobject]@{ ok=$false; reason='pester_report_missing' } }
  try {
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $writtenAtUtc = (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc
    if ($writtenAtUtc -lt $StartedAtUtc.AddSeconds(-1)) { return [pscustomobject]@{ ok=$false; reason='pester_report_stale' } }
    if ($report.ok -ne $true) { return [pscustomobject]@{ ok=$false; reason='pester_report_not_ok' } }
    return [pscustomobject]@{ ok=$true; reason='pester_report_ok' }
  } catch {
    return [pscustomobject]@{ ok=$false; reason='pester_report_invalid' }
  }
}

function Run-Step([string]$Name, [string]$ScriptPath, [string[]]$ArgumentList = @()) {
  $timeout = Get-CiStepTimeout $Name
  Write-Host "CI_RUN step=$Name timeoutSeconds=$timeout"
  $argumentLine = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(ConvertTo-CiProcessArgument $ScriptPath))
  foreach ($argument in @($ArgumentList)) { $argumentLine += ConvertTo-CiProcessArgument ([string]$argument) }
  $startedAtUtc = [DateTime]::UtcNow
  $outcome = Invoke-CiOwnedStepWithProgress -Name $Name -ArgumentLine ($argumentLine -join ' ') -TimeoutSeconds $timeout
  $reportedResult = if ($Name -eq 'pester') { Test-CiPesterReport $ArgumentList $outcome $startedAtUtc } else { [pscustomobject]@{ ok=$true; reason='not_applicable' } }
  $stepOk = ($outcome.started -eq $true -and $outcome.timedOut -ne $true -and $outcome.exitCode -eq 0 -and $reportedResult.ok -eq $true)
  if ($stepOk) {
    Write-Host "CI_OK step=$Name durationMs=$($outcome.durationMs)"
  } else {
    Write-Host "CI_FAILED step=$Name exitCode=$($outcome.exitCode) timedOut=$($outcome.timedOut) durationMs=$($outcome.durationMs)"
    if ($reportedResult.ok -ne $true) { Write-Host "CI_RESULT_GUARD step=$Name reason=$($reportedResult.reason)" }
    $diagnostic = Get-CiDiagnosticExcerpt (($outcome.stderr + [Environment]::NewLine + $outcome.stdout).Trim())
    if (-not [string]::IsNullOrWhiteSpace($diagnostic)) { Write-Host "CI_DIAGNOSTIC step=$Name text=$diagnostic" }
    $script:ok = $false
  }
  $script:steps += [pscustomobject]@{
    name = $Name
    ok = $stepOk
    exitCode = $outcome.exitCode
    durationMs = [int]$outcome.durationMs
    timedOut = [bool]$outcome.timedOut
    timeoutSeconds = [int]$timeout
    terminatedProcessIds = @($outcome.terminatedProcessIds)
    startError = [string]$outcome.startError
    stdoutChars = ([string]$outcome.stdout).Length
    stderrChars = ([string]$outcome.stderr).Length
    reportedResultOk = [bool]$reportedResult.ok
    reportedResultReason = [string]$reportedResult.reason
  }
}

Run-Step 'lint' (Join-Path $PSScriptRoot 'lint.ps1')
$pesterReportPath = Join-Path $workspace 'last-pester.json'
Run-Step 'pester' (Join-Path $PSScriptRoot 'test-pester.ps1') @('-Tier',$PesterTier,'-ReportPath',$pesterReportPath)
Run-Step 'runtime-eval-mcp' (Join-Path $PSScriptRoot 'runtime-eval.ps1') @('-McpReplay')
Run-Step 'concurrency-smoke-test' (Join-Path $PSScriptRoot 'concurrency-smoke-test.ps1')
Run-Step 'verify-package' (Join-Path $PSScriptRoot 'verify-package.ps1')
Run-Step 'codegraph-index' (Join-Path $PSScriptRoot 'codegraph-index.ps1') @('-Json')
Run-Step 'impact-advisor' (Join-Path $PSScriptRoot 'impact-advisor.ps1') @('-ChangedFiles','scripts/codegraph-index.ps1','-Json')
Run-Step 'super-brain-dashboard' (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') @('-Json','-AllowActiveCheckpoint')
Run-Step 'auto-continuation' (Join-Path $PSScriptRoot 'auto-continuation.ps1') @('-Json')
Run-Step 'status-snapshot-writer' (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') @('-Summary','CI status-card refresh','-NextAction','Continue from verified CI status card.','-AllowActiveCheckpoint','-Json')
$completionGuardArgs = @('-Json','-AllowPrivacyRisk','-AllowActiveCheckpoint','-ContractOnly','-PackageVerificationInProgress')
Run-Step 'completion-guard' (Join-Path $PSScriptRoot 'completion-guard.ps1') $completionGuardArgs
Run-Step 'memory-quality-fixer' (Join-Path $PSScriptRoot 'memory-quality-fixer.ps1') @('-Json')
Run-Step 'lesson-replay' (Join-Path $PSScriptRoot 'lesson-replay.ps1') @('-Query','install ui','-Json')
Run-Step 'dispatch-learning' (Join-Path $PSScriptRoot 'dispatch-learning.ps1') @('-Json')
Run-Step 'trigger-simulation' (Join-Path $PSScriptRoot 'trigger-simulation.ps1') @('-Json')
Run-Step 'cold-start-audit' (Join-Path $PSScriptRoot 'cold-start-audit.ps1') @('-Json')
Run-Step 'intent-router' (Join-Path $PSScriptRoot 'intent-router.ps1') @('-Text','继续','-Json')
Run-Step 'script-call-contract' (Join-Path $PSScriptRoot 'script-call-contract.ps1') @('-Json')
Run-Step 'smart-next' (Join-Path $PSScriptRoot 'smart-next.ps1') @('继续','-Json')
Run-Step 'health-summary' (Join-Path $PSScriptRoot 'health-summary.ps1') @('-Json','-AllowActiveCheckpoint')
Run-Step 'agent-scorecard' (Join-Path $PSScriptRoot 'agent-scorecard.ps1') @('-Json')
Run-Step 'brain-status' (Join-Path $PSScriptRoot 'brain.ps1') @('status','-Json','-AllowActiveCheckpoint')
Run-Step 'version-bump-preview' (Join-Path $PSScriptRoot 'version-bump.ps1') @('-Version','0.0.0','-Summary','preview only','-Json')
Run-Step 'memory-eval' (Join-Path $PSScriptRoot 'memory-eval-report.ps1')
Run-Step 'smoke-test' (Join-Path $PSScriptRoot 'smoke-test.ps1')

if (-not $SkipIntegration) {
  Run-Step 'verify-package-integration' (Join-Path $PSScriptRoot 'verify-package.ps1') @('-Integration')
} else {
  Write-Host 'CI_SKIP step=verify-package-integration reason=SkipIntegration'
  $steps += [pscustomobject]@{ name = 'verify-package-integration'; ok = $true; exitCode = 0; skipped = $true; durationMs = 0; timedOut = $false; timeoutSeconds = 0; terminatedProcessIds = @(); startError = ''; stdoutChars = 0; stderrChars = 0 }
}

$stepDurations = @($steps | ForEach-Object { [int]$_.durationMs })
$status = [pscustomobject]@{
  ok = $ok
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = (Get-SuperBrainManifest $Root).version
  packageRoot = $Root
  skipIntegration = [bool]$SkipIntegration
  pesterTier = $PesterTier
  latency = [pscustomobject]@{
    scope = 'owned CI subprocess duration; not prompt-hook latency'
    sampleCount = @($steps).Count
    p50Ms = Get-SuperBrainPercentileMs -Samples $stepDurations -Percentile 0.50
    p95Ms = Get-SuperBrainPercentileMs -Samples $stepDurations -Percentile 0.95
    maxMs = if (@($steps).Count -gt 0) { [int](($steps | Measure-Object -Property durationMs -Maximum).Maximum) } else { 0 }
  }
  steps = $steps
}
Write-JsonUtf8NoBom $statusPath $status 6

if ($ok) {
  Write-Host "CI_OK package=$Root status=$statusPath"
  exit 0
}

Write-Host "CI_FAILED package=$Root status=$statusPath"
exit 1
