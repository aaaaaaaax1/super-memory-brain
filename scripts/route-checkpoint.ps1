param(
  [ValidateSet('BeforeAct','BeforeMutation','BeforeCompletion','AfterUserCorrection','Status','Clear')]
  [string]$Phase = 'BeforeAct',
  [string]$ObservedAction = '',
  [string]$TaskId = '',
  [switch]$AllowMissingGoalLock,
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
$routeScopeRoot = Join-Path $scopeRoot 'route-checkpoints'
if (-not (Test-Path -LiteralPath $routeScopeRoot)) { New-Item -ItemType Directory -Force -Path $routeScopeRoot | Out-Null }
$statePath = Join-Path $workspace 'route-checkpoint.json'
$outPath = Join-Path $workspace 'last-route-checkpoint.json'
function Limit-Text([string]$Value,[int]$Max=360){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Get-ScopedPath([string]$Value) { $safe=Safe-TaskId $Value; if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; return (Join-Path $routeScopeRoot ($safe + '.json')) }
function Read-WorkspaceJson([string]$Name){ $p=Join-Path $workspace $Name; if(Test-Path -LiteralPath $p){ try{ Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json }catch{$null} } else {$null} }
function Read-ScopedOrWorkspaceJson([string]$Name,[string]$ScopedPath){ if(-not [string]::IsNullOrWhiteSpace($ScopedPath) -and (Test-Path -LiteralPath $ScopedPath)){ try{ return Get-Content -LiteralPath $ScopedPath -Raw -Encoding UTF8 | ConvertFrom-Json }catch{} }; return (Read-WorkspaceJson $Name) }
function Add-Violation($List,[string]$Code,[string]$Evidence,[string]$Severity='high'){ [void]$List.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $Evidence 420 }) }

if($Phase -eq 'Clear'){
  $targetStatePath = Get-ScopedPath $TaskId
  if ([string]::IsNullOrWhiteSpace($targetStatePath)) { $targetStatePath = $statePath }
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.route-checkpoint.v1'; version=(Get-SuperBrainManifest $Root).version; phase=$Phase; status='resolved'; unresolvedRouteDrift=$false; taskId=Limit-Text $TaskId 120; violations=@(); blockers=@(); guard='ROUTE_DRIFT_DETECTED issues were cleared after returning to accepted goal route.'; nextAction='Continue with a route checkpoint before the next major action.'; path=$targetStatePath }
  Write-JsonUtf8NoBom $targetStatePath $result 10; Write-JsonUtf8NoBom $statePath $result 10; Write-JsonUtf8NoBom $outPath $result 10
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "ROUTE_CHECKPOINT ok=True status=resolved path=$statePath"}; exit 0
}

$scopedRoutePath = Get-ScopedPath $TaskId
$scopedGoalPath = ''
if (-not [string]::IsNullOrWhiteSpace((Safe-TaskId $TaskId))) { $scopedGoalPath = Join-Path (Join-Path $scopeRoot 'goal-route-locks') ((Safe-TaskId $TaskId) + '.json') }
$lock=Read-ScopedOrWorkspaceJson 'goal-route-lock.json' $scopedGoalPath
$previous=Read-ScopedOrWorkspaceJson 'route-checkpoint.json' $scopedRoutePath
$violations=New-Object System.Collections.ArrayList
$lower=$ObservedAction.ToLowerInvariant()
if(-not $lock -or $lock.active -eq $false -or [string]$lock.status -ne 'active'){
  if(-not $AllowMissingGoalLock -and $Phase -eq 'BeforeCompletion'){ Add-Violation $violations 'missing_goal_route_lock' 'No active goal-route-lock.json; long/high-risk tasks can lose the user-approved route.' 'medium' }
}else{
  foreach($ng in @($lock.nonGoals)){ if(-not [string]::IsNullOrWhiteSpace($ng) -and $lower.Contains(([string]$ng).ToLowerInvariant())){ Add-Violation $violations 'non_goal_touched' "Observed action touches nonGoal=$ng" } }
  foreach($d in @($lock.mustNotDriftTo)){ if(-not [string]::IsNullOrWhiteSpace($d) -and $lower.Contains(([string]$d).ToLowerInvariant())){ Add-Violation $violations 'must_not_drift_to_touched' "Observed action touches mustNotDriftTo=$d" } }
  if($Phase -eq 'BeforeCompletion' -and [string]::IsNullOrWhiteSpace($ObservedAction)){ Add-Violation $violations 'completion_without_route_alignment_evidence' 'BeforeCompletion requires observed action or acceptance evidence tied to acceptedGoal.' 'medium' }
}
if($lower -match '(scope creep|expand scope|change goal|new unrelated|unapproved|自作主张|换方向|偏航)'){ Add-Violation $violations 'scope_creep_or_goal_change_signal' 'Observed action contains scope creep / unapproved goal-change signal.' }
foreach($v in @($violations)){ }
$status=if($violations.Count -gt 0 -or ($previous -and $previous.unresolvedRouteDrift -eq $true)){'route_drift_detected'}else{'clean'}
$unresolved=($status -eq 'route_drift_detected')
$blockers=@($violations | ForEach-Object { "$($_.code): $($_.evidence)" })
$result=[pscustomobject]@{
  ok=(-not $unresolved); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.route-checkpoint.v1'; version=(Get-SuperBrainManifest $Root).version; phase=$Phase; status=$status; unresolvedRouteDrift=$unresolved; taskId=Limit-Text $TaskId 120
  acceptedGoal=if($lock){$lock.acceptedGoal}else{''}; routeHash=if($lock){$lock.routeHash}else{''}; observedAction=Limit-Text $ObservedAction 500
  violations=@($violations); blockers=@($blockers); candidateSignals=@($violations | ForEach-Object { [pscustomobject]@{ candidateType='logic_breakpoint'; breakpointKind='goal_route_drift'; severity=$_.severity; code=$_.code; expectedInvariant='Current action must remain aligned with acceptedGoal, acceptedRoute, nonGoals, and mustNotDriftTo.'; observedViolation=$_.evidence; evidence=@('goal-route-lock.json','last-route-checkpoint.json') } })
  guard='ROUTE_DRIFT_DETECTED means stop, return to the accepted user goal/route, and do not expand scope or change direction without approval.'; nextAction=if($unresolved){'Report ROUTE_DRIFT_DETECTED and realign the action with goal-route-lock before continuing.'}else{'Route remains aligned; re-check before mutation/completion.'}; path=if([string]::IsNullOrWhiteSpace($scopedRoutePath)){$statePath}else{$scopedRoutePath}
}
$targetStatePath = if([string]::IsNullOrWhiteSpace($scopedRoutePath)){$statePath}else{$scopedRoutePath}
Write-JsonUtf8NoBom $targetStatePath $result 12; Write-JsonUtf8NoBom $statePath $result 12; Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "ROUTE_CHECKPOINT ok=$($result.ok) phase=$Phase status=$status violations=$(@($violations).Count) path=$statePath"}
if(-not $result.ok){exit 1}; exit 0
