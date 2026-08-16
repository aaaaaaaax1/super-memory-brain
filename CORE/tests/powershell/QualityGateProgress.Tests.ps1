Describe 'Super Memory Brain package verification quality gate' {
  BeforeAll {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $verifyText = Get-Content -LiteralPath (Join-Path $root 'scripts\verify-package.ps1') -Raw -Encoding UTF8
    $receiptText = Get-Content -LiteralPath (Join-Path $root 'scripts\internal\verify-package-receipt.ps1') -Raw -Encoding UTF8
    $script:verify = $verifyText + [Environment]::NewLine + $receiptText
  }

  It 'runs the package verifier in a bounded owned worker by default' {
    $verify.Contains('[ValidateRange(0,7200)][int]$TimeoutSeconds = 0') | Should Be $true
    $verify.Contains('[switch]$Worker') | Should Be $true
    $verify.Contains('Start-SuperBrainOwnedProcess') | Should Be $true
    $verify.Contains('Complete-SuperBrainOwnedProcess') | Should Be $true
    $verify.Contains('VERIFY_PACKAGE_TIMEOUT') | Should Be $true
    $verify.Contains('elseif ($Integration) { 1200 } else { 900 }') | Should Be $true
    $verify.Contains("'-ProgressPath'") | Should Be $true
  }

  It 'emits bounded progress and preserves per-check duration evidence' {
    $verify.Contains('VERIFY_HEARTBEAT') | Should Be $true
    $verify.Contains('VERIFY_STARTED') | Should Be $true
    $verify.Contains('VERIFY_STEP name=$Message') | Should Be $true
    $verify.Contains('Write-VerifyPackageProgress') | Should Be $true
    $verify.Contains('($completedStepCount % 100) -eq 0') | Should Be $true
    $verify.Contains('durationMs = $durationMs') | Should Be $true
    $verify.Contains('timeoutControlled = $true') | Should Be $true
    $verify.Contains('runtime_brain_ui_server_regression.py') | Should Be $true
    $verify.Contains('Control Center API and privacy regression') | Should Be $true
    $verify.Contains('runtime_work_dag_regression.py') | Should Be $true
    $verify.Contains('native H7 work-DAG regression') | Should Be $true
  }
}
