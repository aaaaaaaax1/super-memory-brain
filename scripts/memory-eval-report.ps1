param(
  [string]$TestsPath = '',
  [ValidateSet('static','recall','decision','all')]
  [string]$Mode = 'all'
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path $Root 'memory\workspace'
$statusPath = Join-Path $workspace 'last-memory-eval.json'
if (-not (Test-Path $workspace)) {
  New-Item -ItemType Directory -Force -Path $workspace | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($TestsPath)) {
  $output = (& (Join-Path $PSScriptRoot 'memory-eval.ps1') -Json -Mode $Mode -TestsPath $TestsPath) -join "`n"
} else {
  $output = (& (Join-Path $PSScriptRoot 'memory-eval.ps1') -Json -Mode $Mode) -join "`n"
}
$exitCode = $LASTEXITCODE
try {
  $report = $output | ConvertFrom-Json
} catch {
  $report = [pscustomobject]@{
    ok = $false
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    packageRoot = $Root
    suite = 'memory-eval'
    error = $_.Exception.Message
    rawLength = $output.Length
  }
}
$report | Add-Member -NotePropertyName reportExitCode -NotePropertyValue $exitCode -Force
Write-JsonUtf8NoBom $statusPath $report 10

if ($report.ok -eq $true -and $exitCode -eq 0) {
  Write-Host "MEMORY_EVAL_REPORT_OK $statusPath"
  exit 0
}

Write-Host "MEMORY_EVAL_REPORT_FAILED $statusPath exitCode=$exitCode"
exit 1
