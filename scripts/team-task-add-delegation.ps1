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
$delegation = [pscustomobject]@{
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

$delegations = @($record.delegations)
$delegations += $delegation
$record.delegations = @($delegations)
$record.updatedAt = $now
Write-JsonUtf8NoBom $path $record 12
& (Join-Path $PSScriptRoot 'team-task-index.ps1') | Out-Null

$result = [pscustomobject]@{ ok=$true; teamTaskId=$TeamTaskId; delegation=$delegation; path=$path }
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "TEAM_TASK_DELEGATION_ADDED id=$TeamTaskId role=$Role status=$Status" }
exit 0
