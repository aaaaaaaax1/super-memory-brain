$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $Root 'tests\powershell'

if (-not (Test-Path $testRoot)) {
  Write-Host "PESTER_SKIPPED reason=no_tests path=$testRoot"
  exit 0
}

$invokePester = Get-Command Invoke-Pester -ErrorAction SilentlyContinue
if (-not $invokePester) {
  Write-Host 'PESTER_SKIPPED reason=Pester_not_installed'
  exit 0
}

$result = Invoke-Pester -Path $testRoot -PassThru
if ($result.FailedCount -eq 0) {
  Write-Host "PESTER_OK tests=$($result.TotalCount)"
  exit 0
}

Write-Host "PESTER_FAILED failed=$($result.FailedCount) total=$($result.TotalCount)"
exit 1
