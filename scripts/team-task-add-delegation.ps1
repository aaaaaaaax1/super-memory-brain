param(
  [Parameter(Mandatory=$true)][string]$TeamTaskId,
  [Parameter(Mandatory=$true)][string]$Role,
  [Parameter(Mandatory=$true)][string]$Task,
  [ValidateSet('assigned','reported','blocked','rejected')][string]$Status = 'reported',
  [ValidateSet('read-only','code-capable')][string]$Mode = 'read-only',
  [string[]]$Findings = @(),
  [string[]]$Evidence = @(),
  [string[]]$Assumptions = @(),
  [string[]]$Unknowns = @(),
  [string[]]$Risks = @(),
  [string]$Recommendation = '',
  [string[]]$ChangedFiles = @(),
  [string[]]$VerificationEvidence = @(),
  [string]$DelegationId = '',
  [string]$IdempotencyKey = '',
  [string]$JoinSlotId = '',
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

$reportInput = [pscustomobject]@{
  role = $Role
  task = $Task
  mode = $Mode
  status = $Status
  findings = @($Findings)
  evidence = @($Evidence)
  assumptions = @($Assumptions)
  unknowns = @($Unknowns)
  risks = @($Risks)
  recommendation = $Recommendation
  changedFiles = @($ChangedFiles)
  verificationEvidence = @($VerificationEvidence)
  joinSlotId = $JoinSlotId
}
$reportFingerprint = Get-TeamTaskReportFingerprint $reportInput

$result = Invoke-TeamTaskRecordLock $path {
  $record = Read-TeamTaskRecord $path
  $delegations = @($record.delegations)
  $candidateDelegationId = $DelegationId.Trim()
  $candidateIdempotencyKey = $IdempotencyKey.Trim()

  $matches = @()
  if (-not [string]::IsNullOrWhiteSpace($candidateDelegationId)) {
    $matches = @($delegations | Where-Object { $_.PSObject.Properties['delegationId'] -and [string]$_.delegationId -eq $candidateDelegationId })
  } elseif (-not [string]::IsNullOrWhiteSpace($candidateIdempotencyKey)) {
    $matches = @($delegations | Where-Object { $_.PSObject.Properties['idempotencyKey'] -and [string]$_.idempotencyKey -eq $candidateIdempotencyKey })
  } else {
    $matches = @($delegations | Where-Object { $_.PSObject.Properties['reportFingerprint'] -and [string]$_.reportFingerprint -eq $reportFingerprint })
  }
  if ($matches.Count -gt 1) { throw 'TEAM_TASK_IDEMPOTENCY_AMBIGUOUS' }
  if ($matches.Count -eq 1) {
    $existing = $matches[0]
    if ($existing.PSObject.Properties['reportFingerprint'] -and [string]$existing.reportFingerprint -eq $reportFingerprint) {
      return [pscustomobject]@{
        ok = $true
        teamTaskId = $TeamTaskId
        delegation = $existing
        delegationId = [string]$existing.delegationId
        joinSlotId = if ($existing.PSObject.Properties['joinSlotId']) { [string]$existing.joinSlotId } else { '' }
        idempotent = $true
        changed = $false
        path = $path
      }
    }
    throw 'TEAM_TASK_IDEMPOTENCY_CONFLICT'
  }

  if ([string]::IsNullOrWhiteSpace($candidateDelegationId)) { $candidateDelegationId = New-TeamTaskIdentity 'delegation' }
  if (@($delegations | Where-Object { $_.PSObject.Properties['delegationId'] -and [string]$_.delegationId -eq $candidateDelegationId }).Count -gt 0) {
    throw 'TEAM_TASK_DELEGATION_ID_COLLISION'
  }

  $expectedJoinSlots = @(if ($record.PSObject.Properties['expectedJoinSlots']) { @($record.expectedJoinSlots) } else { @() })
  $resolvedJoinSlotId = $JoinSlotId.Trim()
  $joinSlot = $null
  if ($expectedJoinSlots.Count -gt 0) {
    if ([string]::IsNullOrWhiteSpace($resolvedJoinSlotId)) {
      $roleMatches = @($expectedJoinSlots | Where-Object { [string]$_.slotId -ieq $Role })
      if ($roleMatches.Count -eq 1) { $resolvedJoinSlotId = [string]$roleMatches[0].slotId }
      else { throw 'TEAM_TASK_JOIN_SLOT_REQUIRED' }
    }
    $slotMatches = @($expectedJoinSlots | Where-Object { [string]$_.slotId -ieq $resolvedJoinSlotId })
    if ($slotMatches.Count -ne 1) { throw 'TEAM_TASK_JOIN_SLOT_NOT_EXPECTED' }
    $joinSlot = $slotMatches[0]
    if (-not [string]::IsNullOrWhiteSpace([string]$joinSlot.delegationId)) { throw 'TEAM_TASK_JOIN_SLOT_ALREADY_REPORTED' }
  } elseif (-not [string]::IsNullOrWhiteSpace($resolvedJoinSlotId)) {
    throw 'TEAM_TASK_JOIN_SLOT_NOT_EXPECTED'
  }

  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $delegation = [pscustomobject]@{
    delegationId = $candidateDelegationId
    idempotencyKey = $candidateIdempotencyKey
    reportFingerprint = $reportFingerprint
    joinSlotId = $resolvedJoinSlotId
    role = $Role
    task = $Task
    mode = $Mode
    status = $Status
    reportedAt = $now
    findings = @($Findings)
    evidence = @($Evidence)
    assumptions = @($Assumptions)
    unknowns = @($Unknowns)
    risks = @($Risks)
    recommendation = $Recommendation
    review = if ($Mode -eq 'code-capable') { [pscustomobject]@{ commanderReviewed=$false; reviewedBy=''; reviewedAt=''; result='pending'; notes=''; changedFiles=@($ChangedFiles); verificationEvidence=@($VerificationEvidence) } } else { $null }
    driftGuard = if ($Mode -eq 'code-capable') { [pscustomobject]@{ status='authorization_missing'; outOfScopeRequests=@() } } else { $null }
    patch = if ($Mode -eq 'code-capable') { [pscustomobject]@{ status='not_provided'; summary=''; changedFiles=@($ChangedFiles); diffRef='' } } else { $null }
  }

  $delegations += $delegation
  $record.delegations = @($delegations)
  if ($joinSlot) {
    $joinSlotStatus = if (Test-TeamTaskTerminalDelegationStatus $Status) { $Status } else { 'pending' }
    $joinSlotTerminalAt = if (Test-TeamTaskTerminalDelegationStatus $Status) { $now } else { '' }
    $joinSlot | Add-Member -NotePropertyName delegationId -NotePropertyValue $candidateDelegationId -Force
    $joinSlot | Add-Member -NotePropertyName reportedAt -NotePropertyValue $now -Force
    $joinSlot | Add-Member -NotePropertyName status -NotePropertyValue $joinSlotStatus -Force
    $joinSlot | Add-Member -NotePropertyName terminalAt -NotePropertyValue $joinSlotTerminalAt -Force
    $record.expectedJoinSlots = @($expectedJoinSlots)
  }
  $record.updatedAt = $now
  Write-TeamTaskRecordUnlocked $path $record 14
  return [pscustomobject]@{
    ok = $true
    teamTaskId = $TeamTaskId
    delegation = $delegation
    delegationId = $candidateDelegationId
    joinSlotId = $resolvedJoinSlotId
    idempotent = $false
    changed = $true
    path = $path
  }
}

if ($result.changed) { Update-TeamTaskIndex $PSScriptRoot $StateRoot | Out-Null }
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "TEAM_TASK_DELEGATION_ADDED id=$TeamTaskId role=$Role status=$Status" }
exit 0
