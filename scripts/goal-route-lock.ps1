param(
  [ValidateSet('Create','Status','Check','Update','Clear')]
  [string]$Action = 'Status',
  [string]$AcceptedGoal = '',
  [string[]]$AcceptedRoute = @(),
  [string[]]$NonGoals = @(),
  [string[]]$MustPreserve = @(),
  [string[]]$MustNotDriftTo = @(),
  [string[]]$ApprovalEvidence = @(),
  [string]$TaskId = '',
  [string]$ObservedAction = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$scopeRoot = Join-Path $workspace 'guard-state'
$goalScopeRoot = Join-Path $scopeRoot 'goal-route-locks'
if (-not (Test-Path -LiteralPath $goalScopeRoot)) { New-Item -ItemType Directory -Force -Path $goalScopeRoot | Out-Null }
$lockPath = Join-Path $workspace 'goal-route-lock.json'
$outPath = Join-Path $workspace 'last-goal-route-lock.json'

function Limit-Text([string]$Value, [int]$Max = 360) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $v=$Value.Trim() -replace '\s+',' '; if ($v.Length -gt $Max) { return $v.Substring(0,$Max)+'...' }; return $v }
function Get-RouteHash([string]$Goal,[string[]]$Route,[string[]]$No,[string[]]$Must,[string[]]$NoDrift) { $raw=($Goal + '|' + (($Route+$No+$Must+$NoDrift) -join '|')); $sha=[System.Security.Cryptography.SHA256]::Create(); (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw))[0..7] | ForEach-Object { $_.ToString('x2') })) }
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Get-ScopedPath([string]$Value) { $safe=Safe-TaskId $Value; if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; return (Join-Path $goalScopeRoot ($safe + '.json')) }
function Read-Lock { 
  $scoped = Get-ScopedPath $TaskId
  if (-not [string]::IsNullOrWhiteSpace($scoped) -and (Test-Path -LiteralPath $scoped)) { try { return Get-Content -LiteralPath $scoped -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  if (Test-Path -LiteralPath $lockPath) { try { return Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }
}

if ($Action -eq 'Clear') {
  $targetLockPath = Get-ScopedPath $TaskId
  if ([string]::IsNullOrWhiteSpace($targetLockPath)) { $targetLockPath = $lockPath }
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.goal-route-lock.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status='cleared'; active=$false; taskId=Limit-Text $TaskId 120; routeHash=''; guard='Goal route lock cleared explicitly.'; nextAction='Create a new goal-route-lock before long-running or high-risk work.'; path=$targetLockPath }
  Write-JsonUtf8NoBom $targetLockPath $result 10; Write-JsonUtf8NoBom $lockPath $result 10; Write-JsonUtf8NoBom $outPath $result 10
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "GOAL_ROUTE_LOCK ok=True status=cleared path=$lockPath" }
  exit 0
}

$current = Read-Lock
if ($Action -in @('Create','Update')) {
  if ([string]::IsNullOrWhiteSpace($AcceptedGoal) -and $current) { $AcceptedGoal = [string]$current.acceptedGoal }
  if ($AcceptedRoute.Count -eq 0 -and $current) { $AcceptedRoute = @($current.acceptedRoute) }
  if ($NonGoals.Count -eq 0 -and $current) { $NonGoals = @($current.nonGoals) }
  if ($MustPreserve.Count -eq 0 -and $current) { $MustPreserve = @($current.mustPreserve) }
  if ($MustNotDriftTo.Count -eq 0 -and $current) { $MustNotDriftTo = @($current.mustNotDriftTo) }
  if ($ApprovalEvidence.Count -eq 0 -and $current) { $ApprovalEvidence = @($current.approvalEvidence) }
  if ([string]::IsNullOrWhiteSpace($AcceptedGoal)) { $AcceptedGoal = 'accepted goal not specified' }
  $hash = Get-RouteHash $AcceptedGoal $AcceptedRoute $NonGoals $MustPreserve $MustNotDriftTo
  $result=[pscustomobject]@{
    ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.goal-route-lock.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status='active'; active=$true; taskId=Limit-Text $TaskId 120
    acceptedGoal=Limit-Text $AcceptedGoal 700; acceptedRoute=@($AcceptedRoute | ForEach-Object { Limit-Text $_ 260 }); nonGoals=@($NonGoals | ForEach-Object { Limit-Text $_ 260 }); mustPreserve=@($MustPreserve | ForEach-Object { Limit-Text $_ 260 }); mustNotDriftTo=@($MustNotDriftTo | ForEach-Object { Limit-Text $_ 260 }); approvalEvidence=@($ApprovalEvidence | ForEach-Object { Limit-Text $_ 260 })
    routeHash=$hash; guard='Accepted user goal and route are the main line; later actions must not silently change goal, expand scope, or drift to non-goals.'; nextAction='Run route-checkpoint.ps1 before major actions and before completion.'; path=if([string]::IsNullOrWhiteSpace((Get-ScopedPath $TaskId))){$lockPath}else{Get-ScopedPath $TaskId}
  }
  $targetLockPath = if([string]::IsNullOrWhiteSpace((Get-ScopedPath $TaskId))){$lockPath}else{Get-ScopedPath $TaskId}
  Write-JsonUtf8NoBom $targetLockPath $result 12; Write-JsonUtf8NoBom $lockPath $result 12; Write-JsonUtf8NoBom $outPath $result 12
  if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "GOAL_ROUTE_LOCK ok=True status=active routeHash=$hash path=$lockPath" }
  exit 0
}

$current = Read-Lock
$ok = ($null -ne $current -and $current.active -ne $false -and [string]$current.status -eq 'active')
$violations=@()
if ($Action -eq 'Check' -and $ok -and -not [string]::IsNullOrWhiteSpace($ObservedAction)) {
  $lower=$ObservedAction.ToLowerInvariant()
  foreach ($ng in @($current.nonGoals + $current.mustNotDriftTo)) { if (-not [string]::IsNullOrWhiteSpace($ng) -and $lower.Contains(([string]$ng).ToLowerInvariant())) { $violations += "route_touches_non_goal:$ng" } }
}
$result=[pscustomobject]@{ ok=($ok -and @($violations).Count -eq 0); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.goal-route-lock.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status=if($ok){'active'}else{'missing'}; active=$ok; taskId=Limit-Text $TaskId 120; acceptedGoal=if($current){$current.acceptedGoal}else{''}; routeHash=if($current){$current.routeHash}else{''}; violations=@($violations); observedAction=Limit-Text $ObservedAction 360; guard='Goal route lock prevents losing the user-approved target line during long tasks.'; nextAction=if($ok){'Use route-checkpoint for phase-specific route drift checks.'}else{'Create goal-route-lock for approved long-running/high-risk goals.'}; path=if($current -and $current.path){$current.path}else{$lockPath} }
Write-JsonUtf8NoBom $outPath $result 10
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "GOAL_ROUTE_LOCK ok=$($result.ok) status=$($result.status) violations=$(@($violations).Count) path=$outPath" }
if (-not $result.ok -and $Action -eq 'Check') { exit 1 }
exit 0
