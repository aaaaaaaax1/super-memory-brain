param(
  [switch]$Json,
  [switch]$AllowStaleVerify
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

function Invoke-JsonTool([string]$ScriptName, [switch]$UseAllowStaleVerify) {
  try {
    if ($UseAllowStaleVerify) {
      $output = @(& (Join-Path $PSScriptRoot $ScriptName) -Json -AllowStaleVerify 6>$null)
    } else {
      $output = @(& (Join-Path $PSScriptRoot $ScriptName) -Json 6>$null)
    }
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

$dashboard = Invoke-JsonTool 'super-brain-dashboard.ps1' -UseAllowStaleVerify:$AllowStaleVerify
$manifest = Get-SuperBrainManifest $Root
$activeCheckpoint = Read-WorkspaceJson 'active-checkpoint.json'
$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastStatusSnapshot = Read-WorkspaceJson 'last-status-snapshot.json'

$lastTaskStale = $false
$staleReasons = @()
if ($lastTask) {
  if (-not [string]::IsNullOrWhiteSpace([string]$lastTask.version) -and [string]$lastTask.version -ne [string]$manifest.version) {
    $lastTaskStale = $true
    $staleReasons += "last_task_version_mismatch:$($lastTask.version)!=$($manifest.version)"
  }
  if ($lastVerify -and -not [string]::IsNullOrWhiteSpace([string]$lastTask.checkedAt) -and -not [string]::IsNullOrWhiteSpace([string]$lastVerify.checkedAt)) {
    try {
      $taskAt = [datetime]::ParseExact([string]$lastTask.checkedAt, 'yyyy-MM-dd HH:mm:ss', $null)
      $verifyAt = [datetime]::ParseExact([string]$lastVerify.checkedAt, 'yyyy-MM-dd HH:mm:ss', $null)
      if ($taskAt -lt $verifyAt) {
        $lastTaskStale = $true
        $staleReasons += 'last_task_older_than_verify'
      }
    } catch {}
  }
}

$blockers = @()
if (-not ($lastVerify -and $lastVerify.ok -eq $true) -and -not $AllowStaleVerify) { $blockers += 'Run or fix scripts/verify-package.ps1.' }
if ($dashboard.reviewGate -and $dashboard.reviewGate.blockerCount -gt 0) { $blockers += 'Resolve team-task review gate blockers.' }
if ($dashboard.memoryRegression -and $dashboard.memoryRegression.failed -gt 0) { $blockers += 'Fix memory-regression-checker failed cases.' }
if ($dashboard.privacy -and $dashboard.privacy.privatePatternHits -gt 0) { $blockers += 'Review privacy-sentinel private-pattern hits before sharing.' }

function Limit-Text([string]$Text, [int]$Max = 180) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ([string]$Text).Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}

$nextAction = 'Ask for the next user task or define the next roadmap item.'
$resumeFrom = ''
if ($activeCheckpoint -and -not [string]::IsNullOrWhiteSpace([string]$activeCheckpoint.nextAction)) {
  $nextAction = $activeCheckpoint.nextAction
  $resumeFrom = 'active-checkpoint.json'
} elseif ($lastStatusSnapshot -and -not [string]::IsNullOrWhiteSpace([string]$lastStatusSnapshot.nextAction)) {
  $nextAction = $lastStatusSnapshot.nextAction
  $resumeFrom = 'last-status-snapshot.json'
} elseif ($lastTask -and @($lastTask.nextSteps).Count -gt 0) {
  $nextAction = (@($lastTask.nextSteps) -join '; ')
  $resumeFrom = 'last-task-verification.json'
}
if ($blockers.Count -gt 0) {
  $nextAction = $blockers[0]
  $resumeFrom = 'blocker-analysis'
}

$result = [pscustomobject]@{
  ok = ($blockers.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  resumeFrom = $resumeFrom
  taskGoal = if ($activeCheckpoint) { Limit-Text ([string]$activeCheckpoint.goal) 180 } else { '' }
  currentPhase = if ($activeCheckpoint) { Limit-Text ([string]$activeCheckpoint.currentPhase) 120 } else { '' }
  completedSteps = if ($activeCheckpoint) { @($activeCheckpoint.completedSteps | Select-Object -First 8) } else { @() }
  pendingSteps = if ($activeCheckpoint) { @($activeCheckpoint.pendingSteps | Select-Object -First 8) } else { @() }
  changedFiles = if ($activeCheckpoint) { @($activeCheckpoint.changedFiles | Select-Object -First 8) } else { @() }
  waitingForUser = if ($activeCheckpoint) { [bool]$activeCheckpoint.waitingForUser } else { $false }
  lastSummary = if ($lastTask -and -not $lastTaskStale) { Limit-Text ([string]$lastTask.summary) 180 } elseif ($lastStatusSnapshot) { Limit-Text ([string]$lastStatusSnapshot.summary) 180 } else { '' }
  lastTaskStale = [bool]$lastTaskStale
  staleReasons = @($staleReasons)
  currentStep = if ($activeCheckpoint) { $activeCheckpoint.currentStep } else { '' }
  checkpointStatus = if ($activeCheckpoint) { $activeCheckpoint.status } else { '' }
  nextAction = Limit-Text ([string]$nextAction) 220
  blockers = @($blockers)
  evidence = @('super-brain-dashboard.ps1','active-checkpoint.json','last-task-verification.json','last-status-snapshot.json','last-verify-package.json')
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "AUTO_CONTINUATION ok=$($result.ok) version=$($result.version) resumeFrom=$($result.resumeFrom)"
  Write-Host "AUTO_CONTINUATION_LAST $($result.lastSummary)"
  Write-Host "AUTO_CONTINUATION_NEXT $($result.nextAction)"
  foreach ($blocker in @($blockers)) { Write-Host "AUTO_CONTINUATION_BLOCKER $blocker" }
}
if (-not $result.ok) { exit 1 }
exit 0
