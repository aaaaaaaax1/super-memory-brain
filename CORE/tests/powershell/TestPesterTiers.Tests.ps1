Describe 'Super Memory Brain tiered Pester runner' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $root 'scripts\common.ps1')
    $script:runner = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'scripts\test-pester.ps1')
    $script:ci = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'scripts\ci.ps1')
    $script:coldStart = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'scripts\cold-start-audit.ps1')
    $script:common = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'scripts\common.ps1')
  }

  It 'keeps Fast Core and Full selection explicit while Full remains the default' {
    $runner.Contains("ValidateSet('Fast','Core','Full')") | Should Be $true
    $runner.Contains('[string]$Tier = ''Full''') | Should Be $true
    $runner.Contains("'Fast' { return 45 }") | Should Be $true
    $runner.Contains("if (`$SuiteName -eq 'CanonicalPlanContinuity.Tests.ps1') { return 105 }") | Should Be $true
    $runner.Contains("return 90") | Should Be $true
    $runner.Contains("default=90;CanonicalPlanContinuity.Tests.ps1=105") | Should Be $true
    $runner.Contains("if (`$SuiteName -eq 'ExecutionContract.Tests.ps1') { return 540 }") | Should Be $true
    $runner.Contains("if (`$SuiteName -eq 'TaskCompletionTransaction.Tests.ps1') { return 600 }") | Should Be $true
    $runner.Contains("return 360") | Should Be $true
    $runner.Contains('Get-SuperBrainPesterTierBudgetMs') | Should Be $true
    $runner.Contains('default { return 3600000 }') | Should Be $true
    $runner.Contains('Get-SuperBrainPesterSuiteTimeout $Tier $SuiteTimeoutSeconds $file.Name') | Should Be $true
    $runner.Contains('suiteTimeoutPolicy') | Should Be $true
    $runner.Contains('default=360;ExecutionContract.Tests.ps1=540;TaskCompletionTransaction.Tests.ps1=600') | Should Be $true
    $runner.Contains('PESTER_TIER_BUDGET_EXCEEDED') | Should Be $true
    $runner.Contains('tierBudgetMs = $tierBudgetMs') | Should Be $true
    $runner.Contains('[ValidateRange(0,12)][int]$MaxParallelSuites = 0') | Should Be $true
    $runner.Contains('function Get-SuperBrainPesterParallelism') | Should Be $true
    $runner.Contains('[Math]::Min([Math]::Max(3, $ParallelismCap), [Math]::Max(3, [int][Math]::Floor($logicalProcessors / 2)))') | Should Be $true
    $runner.Contains("`$parallelismCap = if (`$Tier -eq 'Core') { 6 } else { 8 }") | Should Be $true
    $runner.Contains('parallelismCap = $parallelismCap') | Should Be $true
    $runner.Contains('per_suite_rebased_shared_policy') | Should Be $true
    $runner.Contains('observedMaxParallelSuites') | Should Be $true
    $runner.Contains("'PesterParallelSandbox.Tests.ps1'") | Should Be $true
    $runner.Contains("'RuntimeWakeControlPlane.Tests.ps1'") | Should Be $true
    $runner.Contains("'CurrentTaskContextScope.Tests.ps1'") | Should Be $true
    $runner.Contains("'CanonicalPlanContinuity.Tests.ps1'") | Should Be $true
    $runner.Contains("'AdaptationConfirmationReceipt.Tests.ps1'") | Should Be $true
    $runner.Contains("'LegacyWriterRetirement.Tests.ps1'") | Should Be $true
    $runner.Contains("'DecisionExecutionBinding.Tests.ps1'") | Should Be $true
    $runner.Contains("'InstallUiAccessibility.Tests.ps1'") | Should Be $true
    $runner.Contains("'RuntimeDriftCheckpoint.Tests.ps1'") | Should Be $true
    $runner.Contains('Test-SuperBrainPesterExclusiveSuite') | Should Be $true
    $runner.Contains('if ($RequestedTier -eq ''Full'') { return @(Get-ChildItem') | Should Be $true
    $runner.Contains('PESTER_TIER_INCOMPLETE') | Should Be $true
    $runner.Contains("`$stateSeed = 'empty-controlled-state'") | Should Be $true
    $runner.Contains('Tests never mirror active private state') | Should Be $true
    $runner.Contains('Initialize-SuperBrainPesterStateRoot') | Should Be $true
    $runner.Contains('single_controlled_state') | Should Be $true
  }

  It 'limits timeout cleanup to processes started by the runner' {
    $common.Contains('function Stop-SuperBrainOwnedProcessTree') | Should Be $true
    $common.Contains('function Invoke-SuperBrainOwnedProcess') | Should Be $true
    $common.Contains('function Start-SuperBrainOwnedProcess') | Should Be $true
    $common.Contains('function Complete-SuperBrainOwnedProcess') | Should Be $true
    $runner.Contains('Start-SuperBrainOwnedProcess') | Should Be $true
    $runner.Contains('Complete-SuperBrainOwnedProcess') | Should Be $true
    $runner.Contains('terminatedProcessIds') | Should Be $true
    $ci.Contains('Invoke-CiOwnedStepWithProgress') | Should Be $true
    $ci.Contains('terminatedProcessIds') | Should Be $true
    $ci.Contains('Test-CiPesterReport') | Should Be $true
    $ci.Contains('CI_RESULT_GUARD') | Should Be $true
    $runner.Contains('[Console]::OutputEncoding = $utf8NoBom') | Should Be $true
    $runner.Contains('$OutputEncoding = $utf8NoBom') | Should Be $true
  }

  It 'terminates only the timeout runner child tree' {
    $encodedSleep = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 20'))
    $sleepArgumentLine = '-NoProfile -EncodedCommand ' + $encodedSleep
    $sentinel = Start-Process -FilePath 'powershell.exe' -ArgumentList $sleepArgumentLine -PassThru -WindowStyle Hidden
    try {
      $outcome = Invoke-SuperBrainOwnedProcess -FilePath 'powershell.exe' -ArgumentLine $sleepArgumentLine -TimeoutSeconds 1
      $outcome.started | Should Be $true
      $outcome.timedOut | Should Be $true
      @($outcome.terminatedProcessIds).Count | Should BeGreaterThan 0
      $sentinel.Refresh()
      $sentinel.HasExited | Should Be $false
    } finally {
      try { Stop-Process -Id $sentinel.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
  }

  It 'records timing with clear cold and hot-path boundaries' {
    $runner.Contains('super-brain.pester-report.v1') | Should Be $true
    $runner.Contains("scope = 'isolated test-suite process duration; not prompt-hook latency'") | Should Be $true
    $runner.Contains('p50Ms = Get-SuperBrainPercentileMs') | Should Be $true
    $coldStart.Contains("scope = 'cold-path audit command execution; not prompt-hook hot-path latency'") | Should Be $true
    $coldStart.Contains('durationMs = $DurationMs') | Should Be $true
    $coldStart.Contains('p95Ms = Get-SuperBrainPercentileMs') | Should Be $true
    $coldStart.Contains('Get-SuperBrainColdStartObservedSummary') | Should Be $true
  }
}
