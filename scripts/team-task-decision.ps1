param(
  [Parameter(Mandatory=$true)][string]$TeamTaskId,
  [ValidateSet('pending','accepted','rejected','conflict','verified')][string]$Status = 'accepted',
  [string[]]$AdoptedFindings = @(),
  [string[]]$RejectedFindings = @(),
  [string[]]$Conflicts = @(),
  [string]$Reason = '',
  [switch]$WriteLongTerm,
  [string[]]$AcceptedFacts = @(),
  [switch]$AllowUnreviewedCodeCapable,
  [string]$AllowUnreviewedReason = '',
  [string[]]$IntegratedJoinSlots = @(),
  [string[]]$IntegratedDelegationIds = @(),
  [string]$StateRoot = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'team-task-common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Get-TeamTaskWorkspace $Root $StateRoot
$path = Join-Path (Join-Path $workspace 'team-tasks') "$TeamTaskId.json"
if (-not (Test-Path -LiteralPath $path)) { throw "Team task not found: $TeamTaskId" }

$integratedJoinSlotsProvided = $PSBoundParameters.ContainsKey('IntegratedJoinSlots')
$integratedDelegationIdsProvided = $PSBoundParameters.ContainsKey('IntegratedDelegationIds')
$result = Invoke-TeamTaskRecordLock $path {
  $record = Read-TeamTaskRecord $path
  $existingDecision = $record.commanderDecision
  $existingIntegratedJoinSlots = if ($existingDecision -and $existingDecision.PSObject.Properties['integratedJoinSlots']) { @($existingDecision.integratedJoinSlots) } else { @() }
  $existingIntegratedDelegationIds = if ($existingDecision -and $existingDecision.PSObject.Properties['integratedDelegationIds']) { @($existingDecision.integratedDelegationIds) } else { @() }
  $allIntegratedJoinSlots = @($existingIntegratedJoinSlots)
  $allIntegratedDelegationIds = @($existingIntegratedDelegationIds)
  if ($integratedJoinSlotsProvided) { $allIntegratedJoinSlots += @($IntegratedJoinSlots) }
  if ($integratedDelegationIdsProvided) { $allIntegratedDelegationIds += @($IntegratedDelegationIds) }
  $allIntegratedJoinSlots = @($allIntegratedJoinSlots | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
  $allIntegratedDelegationIds = @($allIntegratedDelegationIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique)
  $join = Get-TeamTaskJoinStatus $record $allIntegratedJoinSlots $allIntegratedDelegationIds

  $terminalDecision = $Status -in @('accepted','rejected','conflict','verified')
  if ($terminalDecision -and -not $join.ok) { throw ('TEAM_TASK_JOIN_INCOMPLETE: ' + ($join.blockers -join '; ')) }

  if ($Status -in @('accepted','verified') -and -not $AllowUnreviewedCodeCapable) {
    $blockers = @()
    foreach ($delegation in @($record.delegations)) {
      if ($delegation.mode -ne 'code-capable') { continue }
      if (-not $delegation.authorization) { $blockers += "missing_authorization:$($delegation.role)"; continue }
      if (-not $delegation.review -or $delegation.review.commanderReviewed -ne $true) { $blockers += "unreviewed:$($delegation.role)"; continue }
      if ($delegation.review.result -ne 'accepted') { $blockers += "review_not_accepted:$($delegation.role):$($delegation.review.result)" }
      if ($delegation.driftGuard -and $delegation.driftGuard.status -ne 'within_scope') { $blockers += "drift:$($delegation.role):$($delegation.driftGuard.status)" }
    }
    if ($blockers.Count -gt 0) { throw ('CODE_CAPABLE_REVIEW_REQUIRED: ' + ($blockers -join '; ')) }
  }

  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $record.commanderDecision = [pscustomobject]@{
    status = $Status
    adoptedFindings = @($AdoptedFindings)
    rejectedFindings = @($RejectedFindings)
    conflicts = @($Conflicts)
    integratedJoinSlots = @($join.integratedSlotIds)
    integratedDelegationIds = @($allIntegratedDelegationIds)
    join = [pscustomobject]@{
      required = $join.required
      expectedSlotCount = $join.expectedSlotCount
      terminalSlotCount = $join.terminalSlotCount
      integratedSlotCount = $join.integratedSlotCount
      status = if ($join.ok) { 'complete' } else { 'pending' }
      pendingSlotIds = @($join.pendingSlotIds)
      unintegratedSlotIds = @($join.unintegratedSlotIds)
      blockers = @($join.blockers)
    }
    allowUnreviewedCodeCapable = [bool]$AllowUnreviewedCodeCapable
    allowUnreviewedReason = $AllowUnreviewedReason
    reason = $Reason
  }
  $record.memoryAdmission = [pscustomobject]@{
    writeLongTerm = [bool]$WriteLongTerm
    acceptedFacts = @($AcceptedFacts)
    reason = if ($WriteLongTerm) { 'Commander accepted verified facts for long-term memory admission' } else { 'No long-term memory admission requested' }
  }
  $record.updatedAt = $now
  Write-TeamTaskRecordUnlocked $path $record 14
  return [pscustomobject]@{ ok=$true; teamTaskId=$TeamTaskId; decision=$record.commanderDecision; memoryAdmission=$record.memoryAdmission; join=$join; path=$path }
}

Update-TeamTaskIndex $PSScriptRoot $StateRoot | Out-Null
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "TEAM_TASK_DECISION_OK id=$TeamTaskId status=$Status" }
exit 0
