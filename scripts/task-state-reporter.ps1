param(
  [switch]$Json
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

$manifest = Get-SuperBrainManifest $Root
$state = Read-WorkspaceJson 'super-brain-state.json'
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$roadmapJson = & (Join-Path $PSScriptRoot 'roadmap-manager.ps1') -Json
$roadmap = $null
try { $roadmap = $roadmapJson | ConvertFrom-Json } catch {}
$reviewGateJson = & (Join-Path $PSScriptRoot 'team-task-review-gate.ps1') -Json
$reviewGate = $null
try { $reviewGate = $reviewGateJson | ConvertFrom-Json } catch {}

$result = [pscustomobject]@{
  ok = ($reviewGate -and $reviewGate.ok -eq $true)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $manifest.version
  packageRoot = $Root
  stateOk = if ($state) { $state.ok } else { $null }
  lastVerifyOk = if ($lastVerify) { $lastVerify.ok } else { $null }
  lastVerifyAt = if ($lastVerify) { $lastVerify.checkedAt } else { '' }
  lastTaskSummary = if ($lastTask) { $lastTask.summary } else { '' }
  lastHotRefreshOk = if ($lastHotRefresh) { $lastHotRefresh.ok } else { $null }
  roadmapCompletedVersions = if ($roadmap) { @($roadmap.completedVersions) } else { @() }
  roadmapRemainingVersions = if ($roadmap) { @($roadmap.remainingVersions) } else { @() }
  reviewGateOk = if ($reviewGate) { $reviewGate.ok } else { $null }
  reviewGateBlockers = if ($reviewGate) { $reviewGate.blockerCount } else { $null }
  evidence = @('super-brain-state.json','last-verify-package.json','last-task-verification.json','roadmap-manager.ps1','team-task-review-gate.ps1')
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "TASK_STATE ok=$($result.ok) version=$($result.version) verify=$($result.lastVerifyOk) reviewGate=$($result.reviewGateOk) blockers=$($result.reviewGateBlockers)"
  Write-Host "TASK_STATE_ROADMAP completed=$(@($result.roadmapCompletedVersions) -join ',') remaining=$(@($result.roadmapRemainingVersions) -join ',')"
  Write-Host "TASK_STATE_LAST $($result.lastTaskSummary)"
}
if (-not $result.ok) { exit 1 }
exit 0
