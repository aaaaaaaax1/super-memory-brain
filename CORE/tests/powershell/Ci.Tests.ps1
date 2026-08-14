Describe 'Super Memory Brain CI script' {
  It 'exists and writes last-ci.json in normal operation' {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Test-Path (Join-Path $root 'scripts\ci.ps1') | Should Be $true
    (Get-Content -LiteralPath (Join-Path $root 'scripts\ci.ps1') -Raw -Encoding UTF8).Contains('last-ci.json') | Should Be $true
  }

  It 'keeps Full Pester as the default and records owned timeout and safe-progress telemetry' {
    $text = Get-Content -LiteralPath (Join-Path $root 'scripts\ci.ps1') -Raw -Encoding UTF8
    $text.Contains('[string]$PesterTier = ''Full''') | Should Be $true
    $text.Contains('Invoke-CiOwnedStepWithProgress') | Should Be $true
    $text.Contains('Start-SuperBrainOwnedProcess') | Should Be $true
    $text.Contains('Complete-SuperBrainOwnedProcess') | Should Be $true
    $text.Contains('Test-CiSafeProgressLine') | Should Be $true
    $text.Contains('CI_HEARTBEAT') | Should Be $true
    $text.Contains('CI_PROGRESS') | Should Be $true
    $text.Contains('durationMs = [int]$outcome.durationMs') | Should Be $true
    $text.Contains('timedOut = [bool]$outcome.timedOut') | Should Be $true
    $text.Contains('terminatedProcessIds') | Should Be $true
    $text.Contains('CI_DIAGNOSTIC') | Should Be $true
    $text.Contains('stdoutChars') | Should Be $true
    $text.Contains('Test-CiPesterReport') | Should Be $true
    $text.Contains('pester_report_not_ok') | Should Be $true
    $text.Contains('CI_RESULT_GUARD') | Should Be $true
    $text.Contains('$executionWorkspaceRoot = Get-SuperBrainRuntimeWorkspaceRoot $Root') | Should Be $true
    $text.Contains('-WorkingDirectory $executionWorkspaceRoot') | Should Be $true
    $text.Contains("Run-Step 'maintain'") | Should Be $false
  }

  It 'keeps CI, evaluation reports, and UI events outside the CORE source tree' {
    foreach ($scriptName in @('ci.ps1','memory-eval-report.ps1','install-ui.ps1')) {
      $text = Get-Content -LiteralPath (Join-Path $root (Join-Path 'scripts' $scriptName)) -Raw -Encoding UTF8
      $text.Contains('Get-SuperBrainMemoryBaseRoot $Root') | Should Be $true
      $text.Contains("Join-Path `$Root 'memory\workspace'") | Should Be $false
    }
  }

  It 'binds release readiness to a current integrated CI result' {
    $ci = Get-Content -LiteralPath (Join-Path $root 'scripts\ci.ps1') -Raw -Encoding UTF8
    $readiness = Get-Content -LiteralPath (Join-Path $root 'scripts\release-readiness.ps1') -Raw -Encoding UTF8
    $ci.Contains('version = (Get-SuperBrainManifest $Root).version') | Should Be $true
    $readiness.Contains('full_ci_missing_stale_or_version_mismatch') | Should Be $true
    $readiness.Contains('$ciCheckedAt -ge $verifyCheckedAt') | Should Be $true
    $readiness.Contains("[string]`$lastCi.version -eq [string]`$manifest.version") | Should Be $true
  }

  It 'runs temporary package integration through an isolated state root' {
    $verify = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-package.ps1') -Raw -Encoding UTF8
    $verify.Contains("`$tmpStateRoot = Join-Path `$tmpRoot 'state'") | Should Be $true
    $verify.Contains('$env:SUPER_BRAIN_STATE_ROOT = $tmpStateRoot') | Should Be $true
    $verify.Contains("'-IncludeZCode','-Isolated','-NoBackup'") | Should Be $true
    $verify.Contains("'-MemoryRoot',`$tmpMemory,'-Isolated','-Json'") | Should Be $true
    $verify.Contains('Remove-Item Env:\SUPER_BRAIN_STATE_ROOT') | Should Be $true
  }
}
