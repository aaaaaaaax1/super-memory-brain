param(
  [string]$TeamTaskId = '',
  [string]$StateRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'team-task-common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Get-TeamTaskWorkspace $Root $StateRoot
$teamRoot = Join-Path $workspace 'team-tasks'

function Get-TeamTaskFiles([string]$Id) {
  if (-not [string]::IsNullOrWhiteSpace($Id)) {
    $path = Join-Path $teamRoot "$Id.json"
    if (-not (Test-Path $path)) { throw "Team task not found: $Id" }
    return @(Get-Item -LiteralPath $path)
  }
  return @(Get-ChildItem -LiteralPath $teamRoot -Filter 'team-*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}

$taskSummaries = @()
$blockers = @()

foreach ($file in Get-TeamTaskFiles $TeamTaskId) {
  try { $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
  $delegations = @($record.delegations)
  $codeCapable = @($delegations | Where-Object { $_.mode -eq 'code-capable' })
  $taskBlockers = @()
  $decision = $record.commanderDecision
  $integratedJoinSlots = if ($decision -and $decision.PSObject.Properties['integratedJoinSlots']) { @($decision.integratedJoinSlots) } else { @() }
  $integratedDelegationIds = if ($decision -and $decision.PSObject.Properties['integratedDelegationIds']) { @($decision.integratedDelegationIds) } else { @() }
  $join = Get-TeamTaskJoinStatus $record $integratedJoinSlots $integratedDelegationIds

  foreach ($delegation in $codeCapable) {
    $role = [string]$delegation.role
    if (-not $delegation.authorization) { $taskBlockers += "missing_authorization:$role"; continue }
    if (@($delegation.authorization.allowedFiles).Count -eq 0) { $taskBlockers += "missing_allowed_files:$role" }
    if (@($delegation.authorization.forbiddenFiles).Count -eq 0) { $taskBlockers += "missing_forbidden_files:$role" }
    if (@($delegation.authorization.verificationCommands).Count -eq 0) { $taskBlockers += "missing_verification_commands:$role" }
    if ([string]::IsNullOrWhiteSpace([string]$delegation.authorization.rollback)) { $taskBlockers += "missing_rollback:$role" }
    if (-not $delegation.review -or $delegation.review.commanderReviewed -ne $true) { $taskBlockers += "unreviewed:$role" }
    elseif ($delegation.review.result -ne 'accepted') { $taskBlockers += "review_not_accepted:${role}:$($delegation.review.result)" }
    if ($delegation.driftGuard -and $delegation.driftGuard.status -ne 'within_scope') { $taskBlockers += "drift_guard_blocked:${role}:$($delegation.driftGuard.status)" }
  }

  if ($record.commanderDecision.status -notin @('accepted','verified')) { $taskBlockers += "commander_decision_not_final:$($record.commanderDecision.status)" }
  if ($record.verification.status -notin @('verified','passed')) { $taskBlockers += "verification_not_final:$($record.verification.status)" }
  foreach ($joinBlocker in @($join.blockers)) { $taskBlockers += "join_$joinBlocker" }

  foreach ($blocker in $taskBlockers) {
    $blockers += [pscustomobject]@{ teamTaskId = $record.teamTaskId; blocker = $blocker; path = $file.FullName }
  }

  $taskSummaries += [pscustomobject]@{
    teamTaskId = $record.teamTaskId
    userGoal = $record.userGoal
    dispatchLevel = $record.dispatchLevel
    codeCapableDelegationCount = @($codeCapable).Count
    expectedJoinSlotCount = $join.expectedSlotCount
    terminalJoinSlotCount = $join.terminalSlotCount
    integratedJoinSlotCount = $join.integratedSlotCount
    commanderDecisionStatus = $record.commanderDecision.status
    verificationStatus = $record.verification.status
    gateStatus = if ($taskBlockers.Count -eq 0) { 'passed' } else { 'blocked' }
    blockerCount = $taskBlockers.Count
    path = $file.FullName
  }
}

$result = [pscustomobject]@{
  ok = ($blockers.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  gate = 'drift_guard_commander_review'
  teamTaskCount = @($taskSummaries).Count
  blockerCount = @($blockers).Count
  blockers = @($blockers | Select-Object -First 20)
  tasks = @($taskSummaries | Select-Object -First 20)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "TEAM_TASK_REVIEW_GATE ok=$($result.ok) tasks=$($result.teamTaskCount) blockers=$($result.blockerCount)"
  foreach ($blocker in @($result.blockers)) { Write-Host "TEAM_TASK_REVIEW_GATE_BLOCKER id=$($blocker.teamTaskId) blocker=$($blocker.blocker)" }
}
if (-not $result.ok) { exit 1 }
exit 0
