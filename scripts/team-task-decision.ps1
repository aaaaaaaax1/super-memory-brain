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
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$path = Join-Path (Join-Path $workspace 'team-tasks') "$TeamTaskId.json"
if (-not (Test-Path $path)) { throw "Team task not found: $TeamTaskId" }

$record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
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
$record.commanderDecision = [pscustomobject]@{
  status = $Status
  adoptedFindings = @($AdoptedFindings)
  rejectedFindings = @($RejectedFindings)
  conflicts = @($Conflicts)
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
Write-JsonUtf8NoBom $path $record 12
& (Join-Path $PSScriptRoot 'team-task-index.ps1') | Out-Null

$result = [pscustomobject]@{ ok=$true; teamTaskId=$TeamTaskId; decision=$record.commanderDecision; memoryAdmission=$record.memoryAdmission; path=$path }
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "TEAM_TASK_DECISION_OK id=$TeamTaskId status=$Status" }
exit 0
