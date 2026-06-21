param(
  [Parameter(Mandatory=$true)][string]$TeamTaskId,
  [int]$DelegationIndex = -1,
  [string]$Role = '',
  [string]$Task = '',
  [ValidateSet('pending','accepted','rejected','needs_revision','rollback_required')][string]$Result = 'accepted',
  [string[]]$ChangedFiles = @(),
  [string[]]$VerificationEvidence = @(),
  [string]$Notes = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$path = Join-Path (Join-Path $workspace 'team-tasks') "$TeamTaskId.json"
if (-not (Test-Path $path)) { throw "Team task not found: $TeamTaskId" }

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

$record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
$delegations = @($record.delegations)
if ($DelegationIndex -lt 0) {
  for ($i = 0; $i -lt $delegations.Count; $i++) {
    if (($Role -eq '' -or $delegations[$i].role -eq $Role) -and ($Task -eq '' -or $delegations[$i].task -eq $Task)) { $DelegationIndex = $i; break }
  }
}
if ($DelegationIndex -lt 0 -or $DelegationIndex -ge $delegations.Count) { throw 'Delegation not found. Pass -DelegationIndex or matching -Role/-Task.' }

$delegation = $delegations[$DelegationIndex]
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

$delegations[$DelegationIndex] = $delegation
$record.delegations = @($delegations)
$record.updatedAt = $now
Write-JsonUtf8NoBom $path $record 14
& (Join-Path $PSScriptRoot 'team-task-index.ps1') | Out-Null

$resultObj = [pscustomobject]@{ ok=$true; teamTaskId=$TeamTaskId; delegationIndex=$DelegationIndex; driftStatus=$driftStatus; reviewResult=$finalResult; outOfScope=@($outRequests); delegation=$delegation; path=$path }
if ($Json) { $resultObj | ConvertTo-Json -Depth 14 } else { Write-Host "TEAM_TASK_REVIEW_OK id=$TeamTaskId index=$DelegationIndex result=$finalResult drift=$driftStatus" }
exit 0
