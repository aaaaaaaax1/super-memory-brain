param(
  [ValidateSet('Light','Full','Team')]
  [string]$Mode = 'Light',
  [switch]$Json,
  [switch]$AllowStaleVerify,
  [switch]$AllowActiveCheckpoint
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

function Limit-Text([string]$Text, [int]$Max = 180) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ([string]$Text).Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}

function Compact-Checkpoint([object]$Checkpoint) {
  if (-not $Checkpoint) { return $null }
  return [pscustomobject]@{
    status = [string]$Checkpoint.status
    taskId = [string]$Checkpoint.taskId
    currentStep = Limit-Text ([string]$Checkpoint.currentStep) 160
    nextAction = Limit-Text ([string]$Checkpoint.nextAction) 220
    blockerCount = @($Checkpoint.blockers).Count
    evidenceCount = @($Checkpoint.evidence).Count
  }
}

function Compact-Snapshot([object]$Snapshot) {
  if (-not $Snapshot) { return $null }
  return [pscustomobject]@{
    checkedAt = [string]$Snapshot.checkedAt
    version = [string]$Snapshot.version
    summary = Limit-Text ([string]$Snapshot.summary) 180
    nextAction = Limit-Text ([string]$Snapshot.nextAction) 220
    risksCount = @($Snapshot.risks).Count
  }
}

$manifest = Get-SuperBrainManifest $Root
$state = Read-WorkspaceJson 'super-brain-state.json'
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$activeCheckpoint = Read-WorkspaceJson 'active-checkpoint.json'
$lastStatusSnapshot = Read-WorkspaceJson 'last-status-snapshot.json'
$statusCard = Read-WorkspaceJson 'status-card.json'

$roadmap = [pscustomobject]@{ ok=$null; completedVersions=@(); remainingVersions=@(); roadmapFound=$null }
$taskState = [pscustomobject]@{ ok=$null }
$memoryRegression = [pscustomobject]@{ ok=$null; failed=0; total=0 }
$privacy = [pscustomobject]@{ ok=$null; privatePatternHits=0; shareSafe=$null }
$reviewGate = [pscustomobject]@{ ok=$null; blockerCount=0 }

if ($Mode -in @('Full','Team')) {
  $roadmap = Invoke-JsonTool 'roadmap-manager.ps1'
  $taskState = Invoke-JsonTool 'task-state-reporter.ps1'
  $memoryRegression = Invoke-JsonTool 'memory-regression-checker.ps1'
  $privacy = Invoke-JsonTool 'privacy-sentinel.ps1'
}
if ($Mode -eq 'Team') {
  $reviewGate = Invoke-JsonTool 'team-task-review-gate.ps1'
}

$risks = @()
if (-not ($lastVerify -and $lastVerify.ok -eq $true) -and -not $AllowStaleVerify) { $risks += 'last_verify_not_ok' }
if (-not ($lastHotRefresh -and $lastHotRefresh.ok -eq $true)) { $risks += 'last_hot_refresh_not_ok' }
if ($activeCheckpoint -and [string]$activeCheckpoint.status -eq 'active' -and -not $AllowActiveCheckpoint) { $risks += 'active_checkpoint_present' }
if ($Mode -in @('Full','Team')) {
  if ($privacy -and $privacy.privatePatternHits -gt 0) { $risks += 'privacy_private_pattern_hits' }
  if ($memoryRegression -and $memoryRegression.failed -gt 0) { $risks += 'memory_regression_failed' }
}
if ($Mode -eq 'Team') {
  if ($reviewGate -and $reviewGate.blockerCount -gt 0) { $risks += 'review_gate_blockers' }
}

$dashboardNextAction = ''
if ($activeCheckpoint -and -not [string]::IsNullOrWhiteSpace([string]$activeCheckpoint.nextAction)) {
  $dashboardNextAction = [string]$activeCheckpoint.nextAction
} elseif ($lastStatusSnapshot -and -not [string]::IsNullOrWhiteSpace([string]$lastStatusSnapshot.nextAction)) {
  $dashboardNextAction = [string]$lastStatusSnapshot.nextAction
} elseif ($risks.Count -eq 0) {
  $dashboardNextAction = 'Ready for next roadmap item or user task.'
} else {
  $dashboardNextAction = 'Resolve dashboard risks before declaring completion.'
}
$dashboardNextAction = Limit-Text $dashboardNextAction 220

$result = [pscustomobject]@{
  ok = ($risks.Count -eq 0)
  mode = $Mode
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $manifest.version
  packageRoot = $Root
  stateOk = if ($state) { $state.ok } else { $null }
  verify = [pscustomobject]@{ ok=if ($lastVerify) { $lastVerify.ok } else { $null }; checkedAt=if ($lastVerify) { $lastVerify.checkedAt } else { '' }; version=if ($lastVerify) { $lastVerify.version } else { '' } }
  hotRefresh = [pscustomobject]@{ ok=if ($lastHotRefresh) { $lastHotRefresh.ok } else { $null }; checkedAt=if ($lastHotRefresh) { $lastHotRefresh.checkedAt } else { '' } }
  roadmap = [pscustomobject]@{ ok=$roadmap.ok; completedVersions=@($roadmap.completedVersions); remainingVersions=@($roadmap.remainingVersions); found=$roadmap.roadmapFound }
  task = [pscustomobject]@{ summary=if ($lastTask) { Limit-Text ([string]$lastTask.summary) 180 } else { '' }; ok=if ($lastTask) { $lastTask.ok } else { $null }; teamTask=if ($lastTask) { $lastTask.teamTask } else { $null } }
  memoryRegression = [pscustomobject]@{ ok=$memoryRegression.ok; failed=$memoryRegression.failed; total=$memoryRegression.total }
  privacy = [pscustomobject]@{ ok=$privacy.ok; privatePatternHits=$privacy.privatePatternHits; shareSafe=$privacy.shareSafe }
  reviewGate = [pscustomobject]@{ ok=$reviewGate.ok; blockerCount=$reviewGate.blockerCount }
  statusCard = if ($statusCard) { [pscustomobject]@{ ok=$statusCard.ok; updatedAt=$statusCard.updatedAt; nextAction=Limit-Text ([string]$statusCard.nextAction) 220 } } else { $null }
  activeCheckpoint = Compact-Checkpoint $activeCheckpoint
  lastStatusSnapshot = Compact-Snapshot $lastStatusSnapshot
  risks = @($risks)
  nextAction = $dashboardNextAction
}

if ($Json) {
  $result | ConvertTo-Json -Depth 12
} else {
  Write-Host "SUPER_BRAIN_DASHBOARD mode=$($result.mode) ok=$($result.ok) version=$($result.version) risks=$($risks.Count)"
  Write-Host "STATE version=$($result.version) verify=$($result.verify.ok) hotRefresh=$($result.hotRefresh.ok) memoryRegression=$($result.memoryRegression.ok) privacy=$($result.privacy.ok) reviewGate=$($result.reviewGate.ok)"
  Write-Host "ROADMAP completed=$(@($result.roadmap.completedVersions) -join ',') remaining=$(@($result.roadmap.remainingVersions) -join ',')"
  Write-Host "TASK $($result.task.summary)"
  if ($risks.Count -gt 0) { Write-Host "RISKS $($risks -join ',')" } else { Write-Host "RISKS none" }
  Write-Host "NEXT $($result.nextAction)"
}
if (-not $result.ok) { exit 1 }
exit 0
