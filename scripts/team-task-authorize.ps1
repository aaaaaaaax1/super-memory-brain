param(
  [Parameter(Mandatory=$true)][string]$TeamTaskId,
  [Parameter(Mandatory=$true)][string]$Role,
  [Parameter(Mandatory=$true)][string]$Task,
  [Parameter(Mandatory=$true)][string[]]$AllowedFiles,
  [Parameter(Mandatory=$true)][string[]]$ForbiddenFiles,
  [Parameter(Mandatory=$true)][string[]]$SuccessCriteria,
  [Parameter(Mandatory=$true)][string[]]$VerificationCommands,
  [Parameter(Mandatory=$true)][string]$Rollback,
  [string]$Notes = '',
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
$delegations = @($record.delegations)
$index = -1
for ($i = 0; $i -lt $delegations.Count; $i++) {
  if ($delegations[$i].role -eq $Role -and $delegations[$i].task -eq $Task) { $index = $i; break }
}
if ($index -lt 0) {
  $delegations += [pscustomobject]@{
    role = $Role
    task = $Task
    status = 'assigned'
    reportedAt = $now
    findings = @()
    evidence = @()
    assumptions = @()
    unknowns = @()
    risks = @()
    recommendation = ''
  }
  $index = $delegations.Count - 1
}

$delegation = $delegations[$index]
$delegation | Add-Member -NotePropertyName mode -NotePropertyValue 'code-capable' -Force
$delegation | Add-Member -NotePropertyName authorization -NotePropertyValue ([pscustomobject]@{
  authorizedBy = 'Commander'
  authorizedAt = $now
  allowedFiles = @($AllowedFiles)
  forbiddenFiles = @($ForbiddenFiles)
  successCriteria = @($SuccessCriteria)
  verificationCommands = @($VerificationCommands)
  rollback = $Rollback
  notes = $Notes
}) -Force
$delegation | Add-Member -NotePropertyName driftGuard -NotePropertyValue ([pscustomobject]@{
  status = 'within_scope'
  outOfScopeRequests = @()
}) -Force
$delegation | Add-Member -NotePropertyName review -NotePropertyValue ([pscustomobject]@{
  commanderReviewed = $false
  reviewedBy = ''
  reviewedAt = ''
  result = 'pending'
  notes = ''
  changedFiles = @()
  verificationEvidence = @()
}) -Force
$delegation | Add-Member -NotePropertyName patch -NotePropertyValue ([pscustomobject]@{
  status = 'not_provided'
  summary = ''
  changedFiles = @()
  diffRef = ''
}) -Force

$delegations[$index] = $delegation
$record.delegations = @($delegations)
$record.updatedAt = $now
Write-JsonUtf8NoBom $path $record 14
& (Join-Path $PSScriptRoot 'team-task-index.ps1') | Out-Null

$result = [pscustomobject]@{ ok=$true; teamTaskId=$TeamTaskId; delegationIndex=$index; delegation=$delegation; path=$path }
if ($Json) { $result | ConvertTo-Json -Depth 14 } else { Write-Host "TEAM_TASK_AUTHORIZED id=$TeamTaskId role=$Role index=$index" }
exit 0
