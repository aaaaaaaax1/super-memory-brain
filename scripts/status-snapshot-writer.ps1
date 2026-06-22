param(
  [string]$Summary = '',
  [string]$NextAction = '',
  [string[]]$Evidence = @(),
  [switch]$ClearCheckpoint,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
New-Item -ItemType Directory -Force -Path $workspace | Out-Null

function Invoke-JsonTool([string]$ScriptName) {
  try {
    $output = @(& (Join-Path $PSScriptRoot $ScriptName) -Json 6>$null)
    $jsonStart = -1
    for ($index = 0; $index -lt $output.Count; $index++) {
      if ([string]$output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
    }
    if ($jsonStart -lt 0) { throw "No JSON output from $ScriptName" }
    $jsonText = (@($output[$jsonStart..($output.Count - 1)]) -join "`n")
    return $jsonText | ConvertFrom-Json
  } catch {
    return [pscustomobject]@{ ok=$false; error=$_.Exception.Message }
  }
}

$dashboard = Invoke-JsonTool 'super-brain-dashboard.ps1'
if ($ClearCheckpoint) {
  try { & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Clear | Out-Null } catch {}
}
if ([string]::IsNullOrWhiteSpace($Summary)) {
  $Summary = if ($dashboard.task -and -not [string]::IsNullOrWhiteSpace([string]$dashboard.task.summary)) { $dashboard.task.summary } else { 'Super Brain status snapshot' }
}
if ([string]::IsNullOrWhiteSpace($NextAction)) {
  $NextAction = if ($dashboard.nextAction) { $dashboard.nextAction } else { 'Continue from dashboard state.' }
}

$snapshot = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  summary = $Summary
  nextAction = $NextAction
  roadmapCompletedVersions = @($dashboard.roadmap.completedVersions)
  roadmapRemainingVersions = @($dashboard.roadmap.remainingVersions)
  verifyOk = $dashboard.verify.ok
  hotRefreshOk = $dashboard.hotRefresh.ok
  memoryRegressionOk = $dashboard.memoryRegression.ok
  reviewGateOk = $dashboard.reviewGate.ok
  privacyOk = $dashboard.privacy.ok
  risks = @($dashboard.risks)
  evidence = @($Evidence + @('super-brain-dashboard.ps1','last-verify-package.json','last-task-verification.json'))
}

$path = Join-Path $workspace 'last-status-snapshot.json'
Write-JsonUtf8NoBom $path $snapshot 10

$statusCard = [pscustomobject]@{
  ok = $snapshot.ok
  updatedAt = $snapshot.checkedAt
  version = $snapshot.version
  packageOk = $dashboard.ok
  verifyOk = $snapshot.verifyOk
  hotRefreshOk = $snapshot.hotRefreshOk
  memoryRegressionOk = $snapshot.memoryRegressionOk
  reviewGateOk = $snapshot.reviewGateOk
  privacyOk = $snapshot.privacyOk
  risksCount = @($snapshot.risks).Count
  nextAction = $snapshot.nextAction
  source = 'status-snapshot-writer.ps1'
}
$statusCardPath = Join-Path $workspace 'status-card.json'
Write-JsonUtf8NoBom $statusCardPath $statusCard 6

if ($Json) {
  $snapshot | Add-Member -NotePropertyName statusCardPath -NotePropertyValue $statusCardPath -Force
  $snapshot | ConvertTo-Json -Depth 10
} else {
  Write-Host "STATUS_SNAPSHOT_WRITER ok=True path=$path version=$($snapshot.version) statusCard=$statusCardPath"
  Write-Host "STATUS_SNAPSHOT_SUMMARY $($snapshot.summary)"
  Write-Host "STATUS_SNAPSHOT_NEXT $($snapshot.nextAction)"
}
exit 0
