[CmdletBinding()]
param(
  [ValidateSet('Fast','Core','Full')][string]$Tier = 'Full',
  [ValidateRange(0,7200)][int]$SuiteTimeoutSeconds = 0,
  # Zero chooses a bounded CPU-aware default.  Core suites are individually
  # state-isolated, so a fixed three-worker cap cannot finish the current
  # 22-suite Core tier inside its 120-second budget on this machine.
  [ValidateRange(0,12)][int]$MaxParallelSuites = 0,
  [string]$ReportPath = '',
  [switch]$Worker,
  [string]$TestPath = '',
  [string]$ResultPath = '',
  [string]$StateRoot = ''
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')
$testRoot = Join-Path $Root 'tests\powershell'

function Get-SuperBrainPesterTierFiles([string]$RequestedTier) {
  $tierMap = [ordered]@{
    Fast = @(
      'Ci.Tests.ps1','Common.Tests.ps1','Manifest.Tests.ps1','McpProcessAudit.Tests.ps1','RouteRegression.Tests.ps1',
      'TestPesterTiers.Tests.ps1','VersionBumpPrivacy.Tests.ps1','PackageVersionRebind.Tests.ps1','McpRegistrationSafety.Tests.ps1'
    )
    Core = @(
      # Measured longest-first order keeps all three workers balanced instead
      # of launching the two recovery matrices only at the tier deadline.
      'CanonicalPlanContinuity.Tests.ps1','DecisionExecutionBinding.Tests.ps1','RecoveryContinuityMatrix.Tests.ps1',
      'CurrentTaskContextScope.Tests.ps1','CrossSessionRecoveryMatrix.Tests.ps1','LocalRebindExecutionContract.Tests.ps1',
      'TurnCloseContinuation.Tests.ps1','RuntimeWakeControlPlane.Tests.ps1','WorkspaceContinuity.Tests.ps1',
      'CompletionLifecycleAuthority.Tests.ps1','LegacyWriterRetirement.Tests.ps1','RecoveryCheckpointFreshness.Tests.ps1',
      'RecoveryCheckpoint.Tests.ps1','H7RuntimeWakeControlPlane.Tests.ps1','NoHookTurnCloseBridge.Tests.ps1',
      'RuntimeDriftCheckpoint.Tests.ps1','ColdStartCapabilityMap.Tests.ps1','ActivationReceipt.Tests.ps1',
      'AdaptationConfirmationReceipt.Tests.ps1','VerifyPackageReceiptProtocol.Tests.ps1','InstallUiAccessibility.Tests.ps1',
      'QualityGateProgress.Tests.ps1','NoHookTurnCloseDispatcher.Tests.ps1'
    )
  }
  if ($RequestedTier -eq 'Full') { return @(Get-ChildItem -LiteralPath $testRoot -Filter '*.Tests.ps1' | Sort-Object Name) }
  $missing = @()
  $selected = @()
  foreach ($name in @($tierMap[$RequestedTier])) {
    $path = Join-Path $testRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing += $name; continue }
    $selected += Get-Item -LiteralPath $path
  }
  if ($missing.Count -gt 0) { throw "PESTER_TIER_INCOMPLETE tier=$RequestedTier missing=$($missing -join ',')" }
  return @($selected)
}

function Get-SuperBrainPesterSelectedFiles([string]$RequestedTier,[string]$RequestedPath) {
  if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
    return @(Get-SuperBrainPesterTierFiles $RequestedTier)
  }
  if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
    throw "PESTER_TEST_PATH_MISSING path=$RequestedPath"
  }
  $candidate = Get-Item -LiteralPath $RequestedPath -ErrorAction Stop
  if ($candidate.Name -notlike '*.Tests.ps1') {
    throw "PESTER_TEST_PATH_NOT_SUITE path=$RequestedPath"
  }
  $rootPath = ([System.IO.Path]::GetFullPath($testRoot)).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar))
  $candidatePath = [System.IO.Path]::GetFullPath($candidate.FullName)
  $insideTestRoot = $candidatePath.StartsWith($rootPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
  if (-not $insideTestRoot) {
    throw "PESTER_TEST_PATH_OUTSIDE_TEST_ROOT path=$RequestedPath"
  }
  return @($candidate)
}

function Get-SuperBrainPesterSuiteTimeout([string]$RequestedTier,[int]$RequestedTimeout,[string]$SuiteName='') {
  if ($RequestedTimeout -gt 0) { return $RequestedTimeout }
  switch ($RequestedTier) {
    'Fast' { return 45 }
    'Core' {
      # This matrix completes in roughly 68 seconds alone but can cross the
      # former 90-second ceiling while six contract-heavy workers contend for
      # child-process startup. Keep the tier budget at 120 seconds and grant
      # only this measured suite a small scheduling margin.
      if ($SuiteName -eq 'CanonicalPlanContinuity.Tests.ps1') { return 105 }
      return 90
    }
    default {
      # Measured on 2026-07-29: ExecutionContract has 68 isolated behavioral
      # paths and completes in about 480 seconds. Keep every other Full suite
      # at the normal six-minute ceiling instead of globally inflating timeouts.
      if ($SuiteName -eq 'ExecutionContract.Tests.ps1') { return 540 }
      return 360
    }
  }
}

function Get-SuperBrainPesterTierBudgetMs([string]$RequestedTier) {
  switch ($RequestedTier) {
    'Fast' { return 45000 }
    'Core' { return 120000 }
    default { return 3600000 }
  }
}

function Get-SuperBrainPesterParallelism([int]$RequestedParallelism,[int]$ParallelismCap=8) {
  if ($RequestedParallelism -gt 0) { return $RequestedParallelism }
  # Each suite can start both PowerShell and Python authorities. Keep the
  # default at half the logical CPUs and let Core use a lower cap because its
  # contract-heavy suites contend on child-process startup; this preserves the
  # 120-second tier budget instead of hiding scheduler contention as a timeout.
  $logicalProcessors = [Math]::Max(1, [Environment]::ProcessorCount)
  return [Math]::Min([Math]::Max(3, $ParallelismCap), [Math]::Max(3, [int][Math]::Floor($logicalProcessors / 2)))
}

function ConvertTo-SuperBrainProcessArgument([string]$Value) {
  return '"' + $Value.Replace('"','\"') + '"'
}

function Write-SuperBrainPesterWorkerResult([object]$Value) {
  if ([string]::IsNullOrWhiteSpace($ResultPath)) { return }
  $directory = Split-Path -Parent $ResultPath
  if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  Write-JsonUtf8NoBom $ResultPath $Value 8
}

function Initialize-SuperBrainPesterStateRoot([string]$StateRoot) {
  $workspaceRoot = Join-Path $StateRoot 'workspace'
  $sharedRoot = Join-Path $StateRoot 'shared'
  New-Item -ItemType Directory -Force -Path $workspaceRoot,$sharedRoot | Out-Null
  $policyPath = Join-Path $workspaceRoot 'memory-sharing-policy.json'
  $policy = [pscustomobject]@{
    initialized = $true
    mode = 'shared'
    activeRoot = [System.IO.Path]::GetFullPath($sharedRoot)
    sharedRoot = [System.IO.Path]::GetFullPath($sharedRoot)
    agentsRoot = [System.IO.Path]::GetFullPath((Join-Path $StateRoot 'agents'))
    groupsRoot = [System.IO.Path]::GetFullPath((Join-Path $StateRoot 'groups'))
    members = @()
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    note = 'Pester sandbox policy: all reads and writes stay under the temporary test state root.'
  }
  Write-JsonUtf8NoBom $policyPath $policy 6
  return $policyPath
}

function Test-SuperBrainPesterExclusiveSuite([object]$File) {
  # Each Core worker owns its state root, but this dispatcher launches nested
  # PowerShell H7 authority transactions. Run it after the parallel batch so
  # CPU contention cannot turn a bounded fail-closed transaction into a flaky
  # continuation result. This preserves the 12-second authority deadline.
  return @(
    'PesterParallelSandbox.Tests.ps1',
    'NoHookTurnCloseDispatcher.Tests.ps1'
  ) -contains [string]$File.Name
}

if ($Worker) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [Console]::OutputEncoding = $utf8NoBom
  $OutputEncoding = $utf8NoBom
  $workerWatch = [Diagnostics.Stopwatch]::StartNew()
  $workerResult = [ordered]@{ ok=$false; testPath=$TestPath; total=0; passed=0; failed=0; failures=@(); error=''; durationMs=0 }
  try {
    if ([string]::IsNullOrWhiteSpace($TestPath) -or -not (Test-Path -LiteralPath $TestPath -PathType Leaf)) { throw 'PESTER_WORKER_TEST_PATH_REQUIRED' }
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
      if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) { throw 'PESTER_WORKER_STATE_ROOT_MISSING' }
      $env:SUPER_BRAIN_STATE_ROOT = [System.IO.Path]::GetFullPath($StateRoot)
      $env:SUPER_BRAIN_ARCHIVE_ROOT = Join-Path $env:SUPER_BRAIN_STATE_ROOT 'archive'
      Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue
      $env:SUPER_BRAIN_LOCAL_SESSION_ID = 'pester-' + [guid]::NewGuid().ToString('n')
    }
    if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) { throw 'PESTER_WORKER_PESTER_NOT_INSTALLED' }
    $pesterResult = Invoke-Pester -Script $TestPath -PassThru -Quiet
    $failures = @($pesterResult.TestResult | Where-Object { $_.Passed -ne $true } | Select-Object -First 12 | ForEach-Object {
      [pscustomobject]@{ name=[string]$_.Name; result=[string]$_.Result; message=[string]$_.FailureMessage }
    })
    $workerResult.total = [int]$pesterResult.TotalCount
    $workerResult.failed = [int]$pesterResult.FailedCount
    $workerResult.passed = [Math]::Max(0, $workerResult.total - $workerResult.failed)
    $workerResult.failures = @($failures)
    $workerResult.ok = ($workerResult.failed -eq 0)
  } catch {
    $workerResult.error = $_.Exception.Message
  } finally {
    $workerWatch.Stop()
    $workerResult.durationMs = [int]$workerWatch.ElapsedMilliseconds
    Write-SuperBrainPesterWorkerResult ([pscustomobject]$workerResult)
  }
  if ($workerResult.ok) { exit 0 }
  exit 1
}

if (-not (Test-Path $testRoot)) {
  Write-Host "PESTER_SKIPPED reason=no_tests path=$testRoot"
  exit 0
}
if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
  Write-Host 'PESTER_SKIPPED reason=Pester_not_installed'
  exit 0
}

function Complete-SuperBrainPesterSuite {
  param(
    [Parameter(Mandatory=$true)][object]$Entry,
    [switch]$TimedOut,
    [string]$TimeoutReason = ''
  )
  $outcome = Complete-SuperBrainOwnedProcess -Handle $Entry.handle -TimedOut:$TimedOut -TimeoutSeconds $Entry.timeoutSeconds
  $workerPayload = $null
  $workerReadError = ''
  if (Test-Path -LiteralPath $Entry.resultPath) {
    try { $workerPayload = Get-Content -Raw -Encoding UTF8 -LiteralPath $Entry.resultPath | ConvertFrom-Json } catch { $workerReadError = $_.Exception.Message }
    Remove-Item -LiteralPath $Entry.resultPath -Force -ErrorAction SilentlyContinue
  }
  $suiteOk = ($outcome.started -eq $true -and $outcome.timedOut -ne $true -and $outcome.exitCode -eq 0 -and $null -ne $workerPayload -and $workerPayload.ok -eq $true)
  $suite = [pscustomobject]@{
    order = [int]$Entry.order
    file = $Entry.file.Name
    ok = $suiteOk
    total = if ($workerPayload) { [int]$workerPayload.total } else { 0 }
    passed = if ($workerPayload) { [int]$workerPayload.passed } else { 0 }
    failed = if ($workerPayload) { [int]$workerPayload.failed } else { 1 }
    durationMs = [int]$outcome.durationMs
    workerDurationMs = if ($workerPayload) { [int]$workerPayload.durationMs } else { 0 }
    timedOut = [bool]$outcome.timedOut
    timeoutSeconds = [int]$Entry.timeoutSeconds
    timeoutReason = $TimeoutReason
    terminatedProcessIds = @($outcome.terminatedProcessIds)
    error = if (-not [string]::IsNullOrWhiteSpace($workerReadError)) { $workerReadError } elseif ($workerPayload -and -not [string]::IsNullOrWhiteSpace([string]$workerPayload.error)) { [string]$workerPayload.error } elseif (-not [string]::IsNullOrWhiteSpace([string]$outcome.startError)) { [string]$outcome.startError } else { '' }
    failures = if ($workerPayload) { @($workerPayload.failures) } else { @() }
  }
  return [pscustomobject]@{ suite=$suite; diagnostic=(($outcome.stderr + "`n" + $outcome.stdout).Trim()) }
}

function Write-SuperBrainPesterSuiteResult {
  param([Parameter(Mandatory=$true)][object]$Completion)
  $suite = $Completion.suite
  Write-Host "PESTER_SUITE tier=$Tier file=$($suite.file) ok=$($suite.ok) tests=$($suite.total) failed=$($suite.failed) durationMs=$($suite.durationMs) timedOut=$($suite.timedOut)"
  if (-not $suite.ok -and -not [string]::IsNullOrWhiteSpace([string]$Completion.diagnostic)) {
    $diagnostic = [string]$Completion.diagnostic
    Write-Host ("PESTER_WORKER_OUTPUT file={0} text={1}" -f $suite.file, $diagnostic.Substring(0, [Math]::Min(1600, $diagnostic.Length)))
  }
  return $suite
}

$sandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-pester-' + [guid]::NewGuid().ToString('n'))
$suiteTimeout = Get-SuperBrainPesterSuiteTimeout $Tier $SuiteTimeoutSeconds
$tierBudgetMs = Get-SuperBrainPesterTierBudgetMs $Tier
$stateSeed = 'empty-controlled-state'
$stateSeedPolicy = 'Tests never mirror active private state; every suite must create the smallest explicit fixture it needs.'
$parallelExecution = ($Tier -ne 'Full')
$parallelismCap = if ($Tier -eq 'Core') { 6 } else { 8 }
$effectiveMaxParallelSuites = if ($parallelExecution) { Get-SuperBrainPesterParallelism $MaxParallelSuites $parallelismCap } else { 1 }
$stateRootIsolation = if ($parallelExecution) { 'per_suite_rebased_shared_policy' } else { 'single_controlled_state' }
$exclusiveSuiteNames = @()
$reportPathExplicit = -not [string]::IsNullOrWhiteSpace($ReportPath)
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  $reportPathDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'super-brain-pester-reports'
  New-Item -ItemType Directory -Force -Path $reportPathDirectory | Out-Null
  $ReportPath = Join-Path $reportPathDirectory ('last-pester-' + [guid]::NewGuid().ToString('n') + '.json')
}
$suites = @()
$active = New-Object System.Collections.ArrayList
$observedMaxParallelSuites = 0
$runWatch = [Diagnostics.Stopwatch]::StartNew()

try {
  $selectedFiles = @(Get-SuperBrainPesterSelectedFiles $Tier $TestPath)
  $exclusiveSuiteNames = @($selectedFiles | Where-Object { Test-SuperBrainPesterExclusiveSuite $_ } | ForEach-Object { $_.Name })
  New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
  $resultRoot = Join-Path $sandboxRoot 'results'
  New-Item -ItemType Directory -Force -Path $resultRoot | Out-Null
  if ($Tier -eq 'Full') {
    Initialize-SuperBrainPesterStateRoot $sandboxRoot | Out-Null
  }
  $tierDeadlineUtc = if ($tierBudgetMs -gt 0) { [DateTime]::UtcNow.AddMilliseconds($tierBudgetMs) } else { $null }
  $pending = New-Object System.Collections.Queue
  foreach ($file in @($selectedFiles)) { $pending.Enqueue($file) }
  $nextOrder = 0
  $suiteTimeoutPolicy = if ($SuiteTimeoutSeconds -gt 0) {
    'uniform=' + $suiteTimeout
  } elseif ($Tier -eq 'Full') {
    'default=360;ExecutionContract.Tests.ps1=540'
  } elseif ($Tier -eq 'Core') {
    'default=90;CanonicalPlanContinuity.Tests.ps1=105'
  } else {
    'uniform=' + $suiteTimeout
  }
  Write-Host "PESTER_START tier=$Tier suites=$($selectedFiles.Count) suiteTimeoutSeconds=$suiteTimeout suiteTimeoutPolicy=$suiteTimeoutPolicy tierBudgetMs=$tierBudgetMs maxParallelSuites=$effectiveMaxParallelSuites exclusiveSuites=$($exclusiveSuiteNames -join ',') stateSeed=$stateSeed stateRootIsolation=$stateRootIsolation"

  while ($pending.Count -gt 0 -or $active.Count -gt 0) {
    $nowUtc = [DateTime]::UtcNow
    if ($null -ne $tierDeadlineUtc -and $nowUtc -ge $tierDeadlineUtc) {
      foreach ($entry in @($active)) {
        $completion = Complete-SuperBrainPesterSuite -Entry $entry -TimedOut -TimeoutReason 'tier_budget'
        $suites += (Write-SuperBrainPesterSuiteResult $completion)
        [void]$active.Remove($entry)
      }
      $unstartedSuiteCount = $pending.Count
      $pending.Clear()
      $suites += [pscustomobject]@{ order=999999; file='runner'; ok=$false; total=0; passed=0; failed=1; durationMs=0; workerDurationMs=0; timedOut=$true; timeoutSeconds=0; timeoutReason='tier_budget'; terminatedProcessIds=@(); error=("PESTER_TIER_BUDGET_EXCEEDED unstartedSuites=$unstartedSuiteCount"); failures=@() }
      break
    }

    while ($pending.Count -gt 0 -and $active.Count -lt $effectiveMaxParallelSuites) {
      $nextFile = $pending.Peek()
      if ((Test-SuperBrainPesterExclusiveSuite $nextFile) -and $active.Count -gt 0) { break }
      if ($active.Count -gt 0 -and @($active | Where-Object { $_.exclusive }).Count -gt 0) { break }
      $nowUtc = [DateTime]::UtcNow
      if ($null -ne $tierDeadlineUtc -and $nowUtc -ge $tierDeadlineUtc) { break }
      $file = $pending.Dequeue()
      $nextOrder += 1
      $remainingMs = if ($null -ne $tierDeadlineUtc) { [int]($tierDeadlineUtc - $nowUtc).TotalMilliseconds } else { 0 }
      $requestedSuiteTimeout = Get-SuperBrainPesterSuiteTimeout $Tier $SuiteTimeoutSeconds $file.Name
      $effectiveSuiteTimeout = if ($remainingMs -gt 0) { [Math]::Max(1, [Math]::Min($requestedSuiteTimeout, [int][Math]::Ceiling($remainingMs / 1000.0))) } else { $requestedSuiteTimeout }
      $suiteStateRoot = if ($parallelExecution) {
        $path = Join-Path $sandboxRoot ('suite-state-' + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        Initialize-SuperBrainPesterStateRoot $path | Out-Null
        $path
      } else {
        $sandboxRoot
      }
      $workerResultPath = Join-Path $resultRoot ('pester-worker-' + [guid]::NewGuid().ToString('n') + '.json')
      $argumentLine = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',(ConvertTo-SuperBrainProcessArgument $PSCommandPath),
        '-Worker','-TestPath',(ConvertTo-SuperBrainProcessArgument $file.FullName),
        '-ResultPath',(ConvertTo-SuperBrainProcessArgument $workerResultPath),
        '-StateRoot',(ConvertTo-SuperBrainProcessArgument $suiteStateRoot)
      ) -join ' '
      $handle = Start-SuperBrainOwnedProcess -FilePath 'powershell.exe' -ArgumentLine $argumentLine -WorkingDirectory $Root
      $suiteDeadlineUtc = $nowUtc.AddSeconds($effectiveSuiteTimeout)
      if ($null -ne $tierDeadlineUtc -and $suiteDeadlineUtc -gt $tierDeadlineUtc) { $suiteDeadlineUtc = $tierDeadlineUtc }
      [void]$active.Add([pscustomobject]@{ order=$nextOrder; file=$file; exclusive=(Test-SuperBrainPesterExclusiveSuite $file); handle=$handle; resultPath=$workerResultPath; timeoutSeconds=$effectiveSuiteTimeout; deadlineUtc=$suiteDeadlineUtc })
      $observedMaxParallelSuites = [Math]::Max($observedMaxParallelSuites, $active.Count)
    }

    $completedEntries = @()
    $nowUtc = [DateTime]::UtcNow
    foreach ($entry in @($active)) {
      if (-not $entry.handle.started) {
        $completion = Complete-SuperBrainPesterSuite -Entry $entry
      } else {
        $hasExited = $false
        try { $entry.handle.process.Refresh(); $hasExited = [bool]$entry.handle.process.HasExited } catch { $hasExited = $true }
        if ($hasExited) {
          $completion = Complete-SuperBrainPesterSuite -Entry $entry
        } elseif ($nowUtc -ge $entry.deadlineUtc) {
          $reason = if ($null -ne $tierDeadlineUtc -and $nowUtc -ge $tierDeadlineUtc) { 'tier_budget' } else { 'suite_timeout' }
          $completion = Complete-SuperBrainPesterSuite -Entry $entry -TimedOut -TimeoutReason $reason
        } else {
          continue
        }
      }
      $suites += (Write-SuperBrainPesterSuiteResult $completion)
      $completedEntries += $entry
    }
    foreach ($entry in @($completedEntries)) { [void]$active.Remove($entry) }
    if ($completedEntries.Count -eq 0 -and $active.Count -gt 0) { Start-Sleep -Milliseconds 50 }
  }
} catch {
  $suites += [pscustomobject]@{ order=999999; file='runner'; ok=$false; total=0; passed=0; failed=1; durationMs=0; workerDurationMs=0; timedOut=$false; timeoutSeconds=$suiteTimeout; timeoutReason='runner_error'; terminatedProcessIds=@(); error=$_.Exception.Message; failures=@() }
} finally {
  foreach ($entry in @($active)) {
    $completion = Complete-SuperBrainPesterSuite -Entry $entry -TimedOut -TimeoutReason 'runner_cleanup'
    $suites += (Write-SuperBrainPesterSuiteResult $completion)
    [void]$active.Remove($entry)
  }
  $runWatch.Stop()
  if (Test-Path -LiteralPath $sandboxRoot) { Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$suites = @($suites | Sort-Object order,file)

$failedSuites = @($suites | Where-Object { $_.ok -ne $true })
$timedOutSuites = @($suites | Where-Object { $_.timedOut -eq $true })
$suiteDurations = @($suites | Where-Object { $_.durationMs -gt 0 } | ForEach-Object { [int]$_.durationMs })
$durationMs = [int]$runWatch.ElapsedMilliseconds
$budgetMet = ($tierBudgetMs -eq 0 -or $durationMs -le $tierBudgetMs)
$report = [pscustomobject]@{
  schema = 'super-brain.pester-report.v1'
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  tier = $Tier
  stateSeed = $stateSeed
  stateSeedPolicy = $stateSeedPolicy
  stateRootIsolation = $stateRootIsolation
  reportPathExplicit = $reportPathExplicit
  parallelExecution = $parallelExecution
  maxParallelSuites = $effectiveMaxParallelSuites
  parallelismCap = $parallelismCap
  observedMaxParallelSuites = $observedMaxParallelSuites
  exclusiveSuites = @($exclusiveSuiteNames)
  suiteTimeoutSeconds = $suiteTimeout
  suiteTimeoutPolicy = if ($SuiteTimeoutSeconds -gt 0) {
    'uniform=' + $suiteTimeout
  } elseif ($Tier -eq 'Full') {
    'default=360;ExecutionContract.Tests.ps1=540'
  } elseif ($Tier -eq 'Core') {
    'default=90;CanonicalPlanContinuity.Tests.ps1=105'
  } else {
    'uniform=' + $suiteTimeout
  }
  tierBudgetMs = $tierBudgetMs
  durationMs = $durationMs
  budgetMet = $budgetMet
  ok = ($failedSuites.Count -eq 0 -and $budgetMet)
  suiteCount = @($suites).Count
  failedSuiteCount = $failedSuites.Count
  timedOutSuiteCount = $timedOutSuites.Count
  total = [int](@($suites | Measure-Object -Property total -Sum).Sum)
  passed = [int](@($suites | Measure-Object -Property passed -Sum).Sum)
  failed = [int](@($suites | Measure-Object -Property failed -Sum).Sum)
  latency = [pscustomobject]@{
    scope = 'isolated test-suite process duration; not prompt-hook latency'
    sampleCount = $suiteDurations.Count
    p50Ms = Get-SuperBrainPercentileMs -Samples $suiteDurations -Percentile 0.50
    p95Ms = Get-SuperBrainPercentileMs -Samples $suiteDurations -Percentile 0.95
    maxMs = if ($suiteDurations.Count -gt 0) { [int](($suiteDurations | Measure-Object -Maximum).Maximum) } else { 0 }
  }
  suites = @($suites)
}
Write-JsonUtf8NoBom $ReportPath $report 10
if ($report.ok) {
  Write-Host "PESTER_OK tier=$Tier tests=$($report.total) suites=$($report.suiteCount) durationMs=$($report.durationMs) maxParallelSuites=$($report.maxParallelSuites) observedMaxParallelSuites=$($report.observedMaxParallelSuites) p50Ms=$($report.latency.p50Ms) p95Ms=$($report.latency.p95Ms) report=$ReportPath"
  exit 0
}
Write-Host "PESTER_FAILED tier=$Tier failedSuites=$($report.failedSuiteCount) timedOutSuites=$($report.timedOutSuiteCount) budgetMet=$($report.budgetMet) failed=$($report.failed) total=$($report.total) report=$ReportPath"
foreach ($suite in @($failedSuites)) {
  Write-Host "PESTER_SUITE_FAILED file=$($suite.file) timedOut=$($suite.timedOut) error=$($suite.error)"
  foreach ($failure in @($suite.failures)) { Write-Host "PESTER_CASE_FAILED name=$($failure.name) result=$($failure.result) message=$($failure.message)" }
}
exit 1
