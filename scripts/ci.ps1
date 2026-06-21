param(
  [switch]$SkipIntegration
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path $Root 'memory\workspace'
$statusPath = Join-Path $workspace 'last-ci.json'
$ok = $true
$steps = @()

if (-not (Test-Path $workspace)) {
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
}

function Run-Step([string]$Name, [string]$ScriptPath, [string[]]$ArgumentList = @()) {
  Write-Host "CI_RUN step=$Name"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ArgumentList
  $exitCode = $LASTEXITCODE
  $stepOk = ($exitCode -eq 0)
  if ($stepOk) {
    Write-Host "CI_OK step=$Name"
  } else {
    Write-Host "CI_FAILED step=$Name exitCode=$exitCode"
    $script:ok = $false
  }
  $script:steps += [pscustomobject]@{
    name = $Name
    ok = $stepOk
    exitCode = $exitCode
  }
}

Run-Step 'lint' (Join-Path $PSScriptRoot 'lint.ps1')
Run-Step 'pester' (Join-Path $PSScriptRoot 'test-pester.ps1')
Run-Step 'verify-package' (Join-Path $PSScriptRoot 'verify-package.ps1')
Run-Step 'super-brain-dashboard' (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') @('-Json')
Run-Step 'auto-continuation' (Join-Path $PSScriptRoot 'auto-continuation.ps1') @('-Json')
Run-Step 'completion-guard' (Join-Path $PSScriptRoot 'completion-guard.ps1') @('-Json','-AllowPrivacyRisk')
Run-Step 'memory-quality-fixer' (Join-Path $PSScriptRoot 'memory-quality-fixer.ps1') @('-Json')
Run-Step 'lesson-replay' (Join-Path $PSScriptRoot 'lesson-replay.ps1') @('-Query','install ui','-Json')
Run-Step 'dispatch-learning' (Join-Path $PSScriptRoot 'dispatch-learning.ps1') @('-Json')
Run-Step 'trigger-simulation' (Join-Path $PSScriptRoot 'trigger-simulation.ps1') @('-Json')
Run-Step 'intent-router' (Join-Path $PSScriptRoot 'intent-router.ps1') @('继续','-Json')
Run-Step 'smart-next' (Join-Path $PSScriptRoot 'smart-next.ps1') @('继续','-Json')
Run-Step 'health-summary' (Join-Path $PSScriptRoot 'health-summary.ps1') @('-Json')
Run-Step 'agent-scorecard' (Join-Path $PSScriptRoot 'agent-scorecard.ps1') @('-Json')
Run-Step 'brain-status' (Join-Path $PSScriptRoot 'brain.ps1') @('status','-Json')
Run-Step 'version-bump-preview' (Join-Path $PSScriptRoot 'version-bump.ps1') @('-Version','0.0.0','-Summary','preview only','-Json')
Run-Step 'memory-eval' (Join-Path $PSScriptRoot 'memory-eval-report.ps1')
Run-Step 'maintain' (Join-Path $PSScriptRoot 'maintain.ps1')
Run-Step 'verify-share' (Join-Path $PSScriptRoot 'verify-share.ps1')
Run-Step 'smoke-test' (Join-Path $PSScriptRoot 'smoke-test.ps1')

if (-not $SkipIntegration) {
  Run-Step 'verify-package-integration' (Join-Path $PSScriptRoot 'verify-package.ps1') @('-Integration')
} else {
  Write-Host 'CI_SKIP step=verify-package-integration reason=SkipIntegration'
  $steps += [pscustomobject]@{ name = 'verify-package-integration'; ok = $true; exitCode = 0; skipped = $true }
}

$status = [pscustomobject]@{
  ok = $ok
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  skipIntegration = [bool]$SkipIntegration
  steps = $steps
}
Write-JsonUtf8NoBom $statusPath $status 6

if ($ok) {
  Write-Host "CI_OK package=$Root status=$statusPath"
  exit 0
}

Write-Host "CI_FAILED package=$Root status=$statusPath"
exit 1
