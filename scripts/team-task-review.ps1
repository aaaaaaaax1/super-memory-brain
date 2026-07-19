param(
  [Parameter(Mandatory=$true)][string]$TeamTaskId,
  [int]$DelegationIndex = -1,
  [string]$DelegationId = '',
  [string]$Role = '',
  [string]$Task = '',
  [ValidateSet('pending','accepted','rejected','needs_revision','rollback_required')][string]$Result = 'accepted',
  [string[]]$ChangedFiles = @(),
  [string[]]$VerificationEvidence = @(),
  [string]$Notes = '',
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

function Test-GlobMatch([string]$Path, [string]$Pattern) {
  $normalized = ($Path -replace '\\','/').TrimStart('/')
  $glob = ($Pattern -replace '\\','/').TrimStart('/')
  $regex = '^' + [regex]::Escape($glob).Replace('\*\*','.*').Replace('\*','[^/]*') + '$'
  return ($normalized -match $regex)
}

function Test-AnyPattern([string]$Path, [string[]]$Patterns) {
  foreach ($pattern in @($Patterns)) {
    if (Test-GlobMatch $Path $pattern) { return $true }
  }
  return $false
}

$resultObj = Invoke-TeamTaskRecordLock $path {
  $record = Read-TeamTaskRecord $path
  $delegations = @($record.delegations)
  $resolvedDelegationIndex = $DelegationIndex
  if ($resolvedDelegationIndex -lt 0 -and -not [string]::IsNullOrWhiteSpace($DelegationId)) {
    for ($i = 0; $i -lt $delegations.Count; $i++) {
      if ($delegations[$i].PSObject.Properties['delegationId'] -and [string]$delegations[$i].delegationId -eq $DelegationId) { $resolvedDelegationIndex = $i; break }
    }
  }
  if ($resolvedDelegationIndex -lt 0) {
    for ($i = 0; $i -lt $delegations.Count; $i++) {
      if (($Role -eq '' -or $delegations[$i].role -eq $Role) -and ($Task -eq '' -or $delegations[$i].task -eq $Task)) { $resolvedDelegationIndex = $i; break }
    }
  }
  if ($resolvedDelegationIndex -lt 0 -or $resolvedDelegationIndex -ge $delegations.Count) { throw 'Delegation not found. Pass -DelegationId, -DelegationIndex, or matching -Role/-Task.' }

  $delegation = $delegations[$resolvedDelegationIndex]
  $auth = $delegation.authorization
  $allowed = if ($auth) { @($auth.allowedFiles) } else { @() }
  $forbidden = if ($auth) { @($auth.forbiddenFiles) } else { @() }
  $outOfScope = @()
  $forbiddenHits = @()
  foreach ($file in @($ChangedFiles)) {
    if ($allowed.Count -gt 0 -and -not (Test-AnyPattern $file $allowed)) { $outOfScope += $file }
    if ($forbidden.Count -gt 0 -and (Test-AnyPattern $file $forbidden)) { $forbiddenHits += $file }
  }

  $driftStatus = 'within_scope'
  $outRequests = @()
  if ($outOfScope.Count -gt 0 -or $forbiddenHits.Count -gt 0) {
    $driftStatus = 'out_of_scope'
    foreach ($file in @($outOfScope)) { $outRequests += "out_of_allowed_scope:$file" }
    foreach ($file in @($forbiddenHits)) { $outRequests += "forbidden_file:$file" }
  }

  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $finalResult = $Result
  if ($driftStatus -ne 'within_scope' -and $Result -eq 'accepted') { $finalResult = 'needs_revision' }

  $delegation | Add-Member -NotePropertyName driftGuard -NotePropertyValue ([pscustomobject]@{
    status = $driftStatus
    outOfScopeRequests = @($outRequests)
  }) -Force
  $delegation | Add-Member -NotePropertyName review -NotePropertyValue ([pscustomobject]@{
    commanderReviewed = $true
    reviewedBy = 'Commander'
    reviewedAt = $now
    result = $finalResult
    notes = $Notes
    changedFiles = @($ChangedFiles)
    verificationEvidence = @($VerificationEvidence)
  }) -Force
  if ($delegation.patch) {
    $delegation.patch.changedFiles = @($ChangedFiles)
  }

  $delegations[$resolvedDelegationIndex] = $delegation
  $record.delegations = @($delegations)
  $record.updatedAt = $now
  Write-TeamTaskRecordUnlocked $path $record 14
  return [pscustomobject]@{ ok=$true; teamTaskId=$TeamTaskId; delegationIndex=$resolvedDelegationIndex; driftStatus=$driftStatus; reviewResult=$finalResult; outOfScope=@($outRequests); delegation=$delegation; path=$path }
}

Update-TeamTaskIndex $PSScriptRoot $StateRoot | Out-Null
if ($Json) { $resultObj | ConvertTo-Json -Depth 14 } else { Write-Host "TEAM_TASK_REVIEW_OK id=$TeamTaskId index=$($resultObj.delegationIndex) result=$($resultObj.reviewResult) drift=$($resultObj.driftStatus)" }
exit 0
