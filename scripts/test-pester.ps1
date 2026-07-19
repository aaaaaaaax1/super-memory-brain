$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'common.ps1')
$testRoot = Join-Path $Root 'tests\powershell'
$sandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-pester-' + [guid]::NewGuid().ToString('n'))
$sourceStateRoot = Get-SuperBrainMemoryBaseRoot $Root
$previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT

if (-not (Test-Path $testRoot)) {
  Write-Host "PESTER_SKIPPED reason=no_tests path=$testRoot"
  exit 0
}

$invokePester = Get-Command Invoke-Pester -ErrorAction SilentlyContinue
if (-not $invokePester) {
  Write-Host 'PESTER_SKIPPED reason=Pester_not_installed'
  exit 0
}

try {
  New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
  if (Test-Path -LiteralPath $sourceStateRoot -PathType Container) {
    foreach ($item in @(Get-ChildItem -LiteralPath $sourceStateRoot -Force -ErrorAction Stop)) {
      Copy-Item -LiteralPath $item.FullName -Destination $sandboxRoot -Recurse -Force -ErrorAction Stop
    }
  }
  $env:SUPER_BRAIN_STATE_ROOT = $sandboxRoot
  $result = Invoke-Pester -Script $testRoot -PassThru -Quiet
} finally {
  $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot
  if (Test-Path -LiteralPath $sandboxRoot) { Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($result.FailedCount -eq 0) {
  Write-Host "PESTER_OK tests=$($result.TotalCount)"
  exit 0
}

Write-Host "PESTER_FAILED failed=$($result.FailedCount) total=$($result.TotalCount)"
foreach ($failure in @($result.TestResult | Where-Object { $_.Passed -ne $true })) {
  Write-Host "PESTER_CASE_FAILED name=$($failure.Name) result=$($failure.Result) message=$($failure.FailureMessage)"
}
exit 1
