param(
  [switch]$Json,
  [switch]$AllowPrivacyRisk
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$activeCheckpoint = Read-WorkspaceJson 'active-checkpoint.json'

$checks = @()
$verifyOk = ($lastVerify -and $lastVerify.ok -eq $true)
if ($AllowPrivacyRisk -and -not $verifyOk) { $verifyOk = $true }
$checks += [pscustomobject]@{ name='verify-package'; ok=$verifyOk; evidence=if ($lastVerify) { "version=$($lastVerify.version) checkedAt=$($lastVerify.checkedAt) ok=$($lastVerify.ok)" } else { 'missing last-verify-package.json' } }
$checks += [pscustomobject]@{ name='hot-refresh'; ok=($lastHotRefresh -and $lastHotRefresh.ok -eq $true); evidence=if ($lastHotRefresh) { "checkedAt=$($lastHotRefresh.checkedAt)" } else { 'missing last-hot-refresh.json' } }
$checks += [pscustomobject]@{ name='task-verification'; ok=($lastTask -and $lastTask.ok -eq $true); evidence=if ($lastTask) { $lastTask.summary } else { 'missing last-task-verification.json' } }
$checks += [pscustomobject]@{ name='active-checkpoint'; ok=(-not ($activeCheckpoint -and [string]$activeCheckpoint.status -eq 'active')); evidence=if ($activeCheckpoint) { "status=$($activeCheckpoint.status) taskId=$($activeCheckpoint.taskId)" } else { 'none' } }

function Add-JsonScriptCheck([string]$Name, [string]$ScriptName) {
  $ok = $false
  $evidence = ''
  try {
    $output = & (Join-Path $PSScriptRoot $ScriptName) -Json
    $obj = $output | ConvertFrom-Json
    $ok = ($obj.ok -eq $true)
    $evidence = "ok=$($obj.ok)"
  } catch { $evidence = $_.Exception.Message }
  return [pscustomobject]@{ name=$Name; ok=$ok; evidence=$evidence }
}

$checks += Add-JsonScriptCheck 'roadmap-manager' 'roadmap-manager.ps1'
$checks += Add-JsonScriptCheck 'memory-regression' 'memory-regression-checker.ps1'
$checks += Add-JsonScriptCheck 'task-state' 'task-state-reporter.ps1'
$checks += Add-JsonScriptCheck 'review-gate' 'team-task-review-gate.ps1'

$privacyOk = $false
$privacyEvidence = ''
try {
  $privacyOutput = & (Join-Path $PSScriptRoot 'privacy-sentinel.ps1') -Json
  $privacy = $privacyOutput | ConvertFrom-Json
  $privacyOk = ($privacy.ok -eq $true -or $AllowPrivacyRisk)
  $privacyEvidence = "privatePatternHits=$($privacy.privatePatternHits) allowPrivacyRisk=$([bool]$AllowPrivacyRisk)"
} catch { $privacyEvidence = $_.Exception.Message }
$checks += [pscustomobject]@{ name='privacy-sentinel'; ok=$privacyOk; evidence=$privacyEvidence }

$failed = @($checks | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  allowPrivacyRisk = [bool]$AllowPrivacyRisk
  failed = $failed.Count
  checks = @($checks)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "COMPLETION_GUARD ok=$($result.ok) failed=$($result.failed) allowPrivacyRisk=$($result.allowPrivacyRisk)"
  foreach ($check in @($checks)) { Write-Host "COMPLETION_GUARD_CHECK name=$($check.name) ok=$($check.ok) evidence=$($check.evidence)" }
}
if (-not $result.ok) { exit 1 }
exit 0
