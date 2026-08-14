param(
  [ValidateSet('BeforeAct','BeforeMutation','BeforeCompletion','AfterUserCorrection','Status','Clear')]
  [string]$Phase = 'BeforeAct',
  [string]$ObservedAction = '',
  [string]$TaskId = '',
  [string]$WorkspaceKey = '',
  [int]$MaxAgeHours = 24,
  [switch]$AllowMissingGoalLock,
  [switch]$Preview,
  [string]$ContractPath = '',
  [string]$ContractFileName = '',
  [string]$ContractHash = '',
  [int]$TaskStateRevisionOverride = 0,
  [switch]$NoExit,
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
$resolvedWorkspaceKey = if ([string]::IsNullOrWhiteSpace($WorkspaceKey)) { '' } else { Get-SuperBrainWorkspaceKey $WorkspaceKey }

function Write-RouteResult([object]$Value,[int]$ExitCode=0){
  if($Json){$Value|ConvertTo-Json -Depth 12}else{Write-Host "ROUTE_CHECKPOINT ok=$($Value.ok) phase=$($Value.phase) status=$($Value.status) path=$($Value.path)"}
  if($NoExit){$script:RouteCheckpointExitCode=$ExitCode;return}
  exit $ExitCode
}
function Limit-Text([string]$Value,[int]$Max=360){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Get-ScopedPath([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; return (Get-SuperBrainCanonicalTaskPath $routeScopeRoot $Value '.json') }
function Get-LegacyScopedPath([string]$Value) { $safe=Safe-TaskId $Value; if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; return (Join-Path $routeScopeRoot ($safe + '.json')) }
function Read-JsonPath([string]$Path){ if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}; try{Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{$null} }
function Read-WorkspaceJson([string]$Name){ $p=Join-Path $workspace $Name; if(Test-Path -LiteralPath $p){ try{ Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json }catch{$null} } else {$null} }
function Get-ProjectionLifecycleStatus($Projection){
  if($Projection-and$Projection.PSObject.Properties['lifecycle']-and$Projection.lifecycle-and-not[string]::IsNullOrWhiteSpace([string]$Projection.lifecycle.status)){return ([string]$Projection.lifecycle.status).ToLowerInvariant()}
  $statuses=@()
  if($Projection-and$Projection.PSObject.Properties['entities']-and$Projection.entities){
    foreach($name in @('checkpoint','task_card','context')){
      $property=$Projection.entities.PSObject.Properties[$name]
      if(-not$property-or-not$property.Value){continue}
      $status=([string]$property.Value.status).ToLowerInvariant()
      if($status-eq'blocked'){$statuses+='blocked'}elseif($status-in@('active','running','in_progress')){$statuses+='active'}elseif($status-in@('paused','waiting')){$statuses+='paused'}
    }
  }
  if($statuses-contains'blocked'){return'blocked'}elseif($statuses-contains'active'){return'active'}elseif($statuses-contains'paused'){return'paused'}
  return'unknown'
}
function Get-RouteBinding([string]$Id,[string]$ExpectedWorkspaceKey=''){
  $empty=[pscustomobject]@{bindingState='locator_only';bindingReason='task_or_contract_missing';bindingRequired=$false;taskStateRevision=0;contractRevision=0;planFingerprint='';canonicalPlanId='';canonicalGeneration=0;canonicalFingerprint='';stageKind='';decisionBindingStatus='';decisionBindingDigest='';ownerSessionKey='';lifecycleStatus='unknown';compatibilityEpoch='route-checkpoint-contract-v1';contractFileName='';targetHash='';workspaceKey=$ExpectedWorkspaceKey;expiresAt=''}
  if([string]::IsNullOrWhiteSpace($Id)){return $empty}
  $candidates=@()
  if(-not[string]::IsNullOrWhiteSpace($ContractPath)){
    $full=[IO.Path]::GetFullPath($ContractPath)
    if(Test-Path -LiteralPath $full -PathType Leaf){
      $contract=Read-JsonPath $full
      if($contract-and[string]$contract.taskId-eq$Id-and[string]$contract.status-eq'active'-and([string]::IsNullOrWhiteSpace($ExpectedWorkspaceKey)-or(Test-SuperBrainWorkspaceKey ([string]$contract.workspaceKey) $ExpectedWorkspaceKey))){$candidates += [pscustomobject]@{value=$contract;path=$full;name=if([string]::IsNullOrWhiteSpace($ContractFileName)){Split-Path -Leaf $full}else{Split-Path -Leaf $ContractFileName};hash=if([string]::IsNullOrWhiteSpace($ContractHash)){(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash}else{$ContractHash}}}
    }
  }else{
    $contractRoot=Join-Path $workspace 'runtime-state\execution-contracts'
    if(Test-Path -LiteralPath $contractRoot -PathType Container){
      foreach($file in @(Get-ChildItem -LiteralPath $contractRoot -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending)){
        $contract=Read-JsonPath $file.FullName
      if(-not$contract-or[string]$contract.taskId-ne$Id-or[string]$contract.status-ne'active'){continue}
      if(-not[string]::IsNullOrWhiteSpace($ExpectedWorkspaceKey)-and-not(Test-SuperBrainWorkspaceKey ([string]$contract.workspaceKey) $ExpectedWorkspaceKey)){continue}
        $candidates+=[pscustomobject]@{value=$contract;path=$file.FullName;name=$file.Name;hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
      }
    }
  }
  $empty.bindingRequired=(@($candidates|Where-Object{$_.value.PSObject.Properties['structuralGuardsRequired']-and$_.value.structuralGuardsRequired-eq$true}).Count-gt0)
  if($candidates.Count-ne1){$empty.bindingReason=if($candidates.Count-gt1){'ambiguous_active_contract'}else{'active_contract_missing'};return $empty}
  $record=$candidates[0]
  $contract=$record.value
  $empty.bindingRequired=($contract.PSObject.Properties['structuralGuardsRequired']-and$contract.structuralGuardsRequired-eq$true)
  $contractWorkspaceKey=Get-SuperBrainWorkspaceKey ([string]$contract.workspaceKey)
  $projectionPath=Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $Id '.json'
  $projection=Read-JsonPath $projectionPath
  if(-not$projection-or[string]$projection.taskId-ne$Id){$empty.bindingReason='task_state_projection_missing';$empty.workspaceKey=$contractWorkspaceKey;return $empty}
  $lifecycleStatus=Get-ProjectionLifecycleStatus $projection
  $projectionWorkspaceKey=if($projection.PSObject.Properties['lifecycle']-and$projection.lifecycle-and$projection.lifecycle.PSObject.Properties['workspaceKey']){[string]$projection.lifecycle.workspaceKey}else{''}
  if($lifecycleStatus-ne'active'){$empty.bindingReason='task_state_not_active';$empty.lifecycleStatus=$lifecycleStatus;$empty.workspaceKey=$contractWorkspaceKey;return $empty}
  if(-not[string]::IsNullOrWhiteSpace($projectionWorkspaceKey)-and-not(Test-SuperBrainWorkspaceKey $projectionWorkspaceKey $contractWorkspaceKey)){$empty.bindingReason='task_state_workspace_mismatch';$empty.workspaceKey=$contractWorkspaceKey;return $empty}
  if(-not$contract.planReceipt-or[string]::IsNullOrWhiteSpace([string]$contract.planReceipt.planFingerprint)){$empty.bindingReason='contract_plan_fingerprint_missing';$empty.workspaceKey=$contractWorkspaceKey;return $empty}
  $effectiveTaskStateRevision=if($TaskStateRevisionOverride-gt0){$TaskStateRevisionOverride}else{[int]$projection.revision}
  if($effectiveTaskStateRevision-le0){$empty.bindingReason='task_state_revision_missing';$empty.workspaceKey=$contractWorkspaceKey;return $empty}
  $canonicalPlan=$null
  if($contract.PSObject.Properties['canonicalPlan'] -and $contract.canonicalPlan){
    $canonicalState=Test-SuperBrainCanonicalPlan $contract.canonicalPlan
    if(-not$canonicalState.ok){$empty.bindingReason='contract_canonical_plan_invalid';$empty.workspaceKey=$contractWorkspaceKey;return $empty}
    $canonicalPlan=$canonicalState.plan
  }
  $stageKindValue=if($contract.PSObject.Properties['stageKind']){Limit-Text ([string]$contract.stageKind) 24}else{''}
  $decisionBindingStatusValue=if($contract.PSObject.Properties['decisionBinding'] -and $contract.decisionBinding){Limit-Text ([string]$contract.decisionBinding.status) 32}else{''}
  $decisionBindingDigestValue=if($contract.PSObject.Properties['decisionBinding'] -and $contract.decisionBinding){Limit-Text ([string]$contract.decisionBinding.bindingDigest) 64}else{''}
  $decisionBindingRequired=($decisionBindingStatusValue -eq 'bound' -and -not [string]::IsNullOrWhiteSpace($decisionBindingDigestValue))
  return [pscustomobject]@{
    bindingState='bound';bindingReason='exact_task_contract_binding';bindingRequired=([bool]($empty.bindingRequired -or $decisionBindingRequired))
    taskStateRevision=[int]$effectiveTaskStateRevision;contractRevision=[int]$contract.revision;planFingerprint=Limit-Text ([string]$contract.planReceipt.planFingerprint) 64
    canonicalPlanId=if($canonicalPlan){Limit-Text ([string]$canonicalPlan.planId) 80}else{''}
    canonicalGeneration=if($canonicalPlan){[int]$canonicalPlan.generation}else{0}
    canonicalFingerprint=if($canonicalPlan){Limit-Text ([string]$canonicalPlan.currentFingerprint) 64}else{''}
    stageKind=$stageKindValue;decisionBindingStatus=$decisionBindingStatusValue;decisionBindingDigest=$decisionBindingDigestValue
    ownerSessionKey=Limit-Text ([string]$contract.ownerSessionKey) 160;lifecycleStatus=$lifecycleStatus;compatibilityEpoch=if($canonicalPlan){'route-checkpoint-contract-v2'}else{'route-checkpoint-contract-v1'}
    contractFileName=$record.name;targetHash=$record.hash;workspaceKey=$contractWorkspaceKey
    expiresAt=(Get-Date).AddHours([Math]::Max(1,$MaxAgeHours)).ToString('yyyy-MM-dd HH:mm:ss')
  }
}
function Get-ActiveScopedRoutes([string]$ExcludeTaskId='') {
  $items=@()
  foreach($file in @(Get-ChildItem -LiteralPath $routeScopeRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
    try { $item=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; if($item -and [string]$item.status -eq 'clean' -and [string]$item.taskId -ne $ExcludeTaskId){$items+=$item} } catch {}
  }
  return @($items)
}
function Test-RouteCheckpointFresh($Stored){
  if(-not$Stored){return [pscustomobject]@{fresh=$false;reason='missing'}}
  if($Stored.ok-ne$true-or[string]$Stored.status-ne'clean'){return [pscustomobject]@{fresh=$false;reason='not_clean'}}
  $expires=$null;try{$expires=[datetime]::Parse([string]$Stored.expiresAt)}catch{}
  if(-not$expires-or$expires-le(Get-Date)){return [pscustomobject]@{fresh=$false;reason='expired'}}
  $expectedKey=if(-not[string]::IsNullOrWhiteSpace($resolvedWorkspaceKey)){$resolvedWorkspaceKey}else{[string]$Stored.workspaceKey}
  if([string]::IsNullOrWhiteSpace([string]$Stored.taskId)-or-not(Test-SuperBrainWorkspaceKey ([string]$Stored.workspaceKey) $expectedKey)){return [pscustomobject]@{fresh=$false;reason='identity_mismatch'}}
  $binding=Get-RouteBinding ([string]$Stored.taskId) $expectedKey
  $bindingMustMatch=($binding.bindingRequired -or -not [string]::IsNullOrWhiteSpace([string]$binding.stageKind) -or -not [string]::IsNullOrWhiteSpace([string]$binding.decisionBindingDigest))
  if($bindingMustMatch){
    $mismatch=([string]$Stored.bindingState-ne'bound'-or[int]$Stored.taskStateRevision-ne[int]$binding.taskStateRevision-or[int]$Stored.contractRevision-ne[int]$binding.contractRevision-or[string]$Stored.planFingerprint-ne[string]$binding.planFingerprint-or[string]$Stored.ownerSessionKey-ne[string]$binding.ownerSessionKey-or[string]$Stored.contractFileName-ne[string]$binding.contractFileName-or-not[string]::Equals([string]$Stored.targetHash,[string]$binding.targetHash,[StringComparison]::OrdinalIgnoreCase)-or[string]$Stored.canonicalPlanId-ne[string]$binding.canonicalPlanId-or[int]$Stored.canonicalGeneration-ne[int]$binding.canonicalGeneration-or[string]$Stored.canonicalFingerprint-ne[string]$binding.canonicalFingerprint-or[string]$Stored.stageKind-ne[string]$binding.stageKind-or[string]$Stored.decisionBindingStatus-ne[string]$binding.decisionBindingStatus-or[string]$Stored.decisionBindingDigest-ne[string]$binding.decisionBindingDigest)
    if($mismatch){return [pscustomobject]@{fresh=$false;reason='contract_binding_stale';contractRevision=[int]$binding.contractRevision;planFingerprint=[string]$binding.planFingerprint}}
  }
  return [pscustomobject]@{fresh=$true;reason='fresh';contractRevision=[int]$binding.contractRevision;planFingerprint=[string]$binding.planFingerprint}
}
function Update-CompatibilityRoute([object]$ChangedRoute,[switch]$RemoveChanged) {
  $pointer=$null
  if(Test-Path -LiteralPath $statePath){try{$pointer=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
  $changedTaskId=[string]$ChangedRoute.taskId
  $pointerMatches=($pointer -and [string]$pointer.taskId -eq $changedTaskId)
  if($RemoveChanged){
    if(-not $pointerMatches){return $false}
    $candidates=@(Get-ActiveScopedRoutes $changedTaskId|Group-Object taskId|ForEach-Object{$_.Group|Select-Object -First 1})
    $replacement=if($candidates.Count-eq1){$candidates[0]}else{$null}
    if($replacement){Write-JsonUtf8NoBom $statePath $replacement 12}elseif(Test-Path -LiteralPath $statePath){Remove-Item -LiteralPath $statePath -Force}
    return $true
  }
  if(-not $pointer -or $pointerMatches -or [string]$pointer.status -notin @('clean','route_drift_detected','resolved')){Write-JsonUtf8NoBom $statePath $ChangedRoute 12;return $true}
  return $false
}
function Read-ScopedOrWorkspaceJson([string]$Name,[string]$ScopedPath,[string]$LegacyPath=''){
  foreach($candidate in @($ScopedPath,$LegacyPath)){
    if([string]::IsNullOrWhiteSpace($candidate)-or-not(Test-Path -LiteralPath $candidate -PathType Leaf)){continue}
    try{$value=Get-Content -LiteralPath $candidate -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$value.taskId-eq$TaskId){return $value}}catch{}
  }
  if([string]::IsNullOrWhiteSpace($TaskId)){return (Read-WorkspaceJson $Name)}
  return $null
}
function Add-Violation($List,[string]$Code,[string]$Evidence,[string]$Severity='high'){ [void]$List.Add([pscustomobject]@{ code=$Code; severity=$Severity; evidence=Limit-Text $Evidence 420 }) }

$scopedRoutePath = Get-ScopedPath $TaskId
$legacyRoutePath = Get-LegacyScopedPath $TaskId
if($Phase -eq 'Status'){
  $stored=Read-ScopedOrWorkspaceJson 'route-checkpoint.json' $scopedRoutePath $legacyRoutePath
  if($stored){
    $freshness=Test-RouteCheckpointFresh $stored
    $stored|Add-Member -NotePropertyName freshness -NotePropertyValue $freshness -Force
    $stored|Add-Member -NotePropertyName stale -NotePropertyValue (-not$freshness.fresh) -Force
    if(-not$freshness.fresh){$stored|Add-Member -NotePropertyName ok -NotePropertyValue $false -Force;$stored|Add-Member -NotePropertyName status -NotePropertyValue 'stale' -Force;$stored|Add-Member -NotePropertyName nextAction -NotePropertyValue 'Run a fresh route checkpoint before guarded mutation or completion.' -Force}
    Write-RouteResult $stored $(if($stored.ok-eq$true-and$freshness.fresh){0}else{1})
    if($NoExit){return}
  }
  $missing=[pscustomobject]@{ok=$false;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');schema='super-brain.route-checkpoint.v1';version=(Get-SuperBrainManifest $Root).version;phase=$Phase;status='missing';unresolvedRouteDrift=$false;taskId=Limit-Text $TaskId 120;workspaceKey=$resolvedWorkspaceKey;bindingState='locator_only';bindingReason='checkpoint_missing';violations=@();blockers=@();guard='Status is read-only and does not evaluate or create route checkpoint state.';nextAction='Run a route checkpoint before the next guarded action.';path=if([string]::IsNullOrWhiteSpace($scopedRoutePath)){$statePath}else{$scopedRoutePath}}
  Write-RouteResult $missing 1
  if($NoExit){return}
}

if($Phase -eq 'Clear'){
  $targetStatePath = Get-ScopedPath $TaskId
  if ([string]::IsNullOrWhiteSpace($targetStatePath)) { $targetStatePath = $statePath }
  $binding=Get-RouteBinding $TaskId $resolvedWorkspaceKey
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.route-checkpoint.v1'; version=(Get-SuperBrainManifest $Root).version; phase=$Phase; status='resolved'; unresolvedRouteDrift=$false; taskId=Limit-Text $TaskId 120; workspaceKey=$binding.workspaceKey; bindingState=$binding.bindingState; bindingReason=$binding.bindingReason; bindingRequired=$binding.bindingRequired; taskStateRevision=$binding.taskStateRevision; contractRevision=$binding.contractRevision; planFingerprint=$binding.planFingerprint; canonicalPlanId=$binding.canonicalPlanId; canonicalGeneration=$binding.canonicalGeneration; canonicalFingerprint=$binding.canonicalFingerprint; stageKind=$binding.stageKind; decisionBindingStatus=$binding.decisionBindingStatus; decisionBindingDigest=$binding.decisionBindingDigest; ownerSessionKey=$binding.ownerSessionKey; lifecycleStatus=$binding.lifecycleStatus; compatibilityEpoch=$binding.compatibilityEpoch; contractFileName=$binding.contractFileName; targetHash=$binding.targetHash; expiresAt=$binding.expiresAt; violations=@(); blockers=@(); guard='ROUTE_DRIFT_DETECTED issues were cleared after returning to accepted goal route.'; nextAction='Continue with a route checkpoint before the next major action.'; path=$targetStatePath }
  Write-JsonUtf8NoBom $targetStatePath $result 10
  if([string]::IsNullOrWhiteSpace($TaskId)){Write-JsonUtf8NoBom $statePath $result 10}else{Update-CompatibilityRoute $result -RemoveChanged|Out-Null}
  Write-JsonUtf8NoBom $outPath $result 10
  Write-RouteResult $result 0
  if($NoExit){return}
}

$scopedGoalPath = if([string]::IsNullOrWhiteSpace($TaskId)){''}else{Get-SuperBrainCanonicalTaskPath (Join-Path $scopeRoot 'goal-route-locks') $TaskId '.json'}
$legacyGoalPath = if([string]::IsNullOrWhiteSpace((Safe-TaskId $TaskId))){''}else{Join-Path (Join-Path $scopeRoot 'goal-route-locks') ((Safe-TaskId $TaskId)+'.json')}
$lock=Read-ScopedOrWorkspaceJson 'goal-route-lock.json' $scopedGoalPath $legacyGoalPath
$previous=Read-ScopedOrWorkspaceJson 'route-checkpoint.json' $scopedRoutePath $legacyRoutePath
$binding=Get-RouteBinding $TaskId $resolvedWorkspaceKey
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
if($binding.bindingRequired-and$binding.bindingState-ne'bound'){Add-Violation $violations 'route_checkpoint_binding_required' ("reason=$($binding.bindingReason) taskId=$TaskId workspaceKey=$($binding.workspaceKey)")}
foreach($v in @($violations)){ }
$status=if($violations.Count -gt 0 -or ($previous -and $previous.unresolvedRouteDrift -eq $true)){'route_drift_detected'}else{'clean'}
$unresolved=($status -eq 'route_drift_detected')
$blockers=@($violations | ForEach-Object { "$($_.code): $($_.evidence)" })
$result=[pscustomobject]@{
  ok=(-not $unresolved); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.route-checkpoint.v1'; version=(Get-SuperBrainManifest $Root).version; phase=$Phase; status=$status; unresolvedRouteDrift=$unresolved; taskId=Limit-Text $TaskId 120; workspaceKey=$binding.workspaceKey
  bindingState=$binding.bindingState; bindingReason=$binding.bindingReason; bindingRequired=$binding.bindingRequired; taskStateRevision=$binding.taskStateRevision; contractRevision=$binding.contractRevision; planFingerprint=$binding.planFingerprint; canonicalPlanId=$binding.canonicalPlanId; canonicalGeneration=$binding.canonicalGeneration; canonicalFingerprint=$binding.canonicalFingerprint; stageKind=$binding.stageKind; decisionBindingStatus=$binding.decisionBindingStatus; decisionBindingDigest=$binding.decisionBindingDigest; ownerSessionKey=$binding.ownerSessionKey; lifecycleStatus=$binding.lifecycleStatus; compatibilityEpoch=$binding.compatibilityEpoch; contractFileName=$binding.contractFileName; targetHash=$binding.targetHash; expiresAt=$binding.expiresAt
  acceptedGoal=if($lock){$lock.acceptedGoal}else{''}; routeHash=if($lock){$lock.routeHash}else{''}; observedAction=Limit-Text $ObservedAction 500
  violations=@($violations); blockers=@($blockers); candidateSignals=@($violations | ForEach-Object { [pscustomobject]@{ candidateType='logic_breakpoint'; breakpointKind='goal_route_drift'; severity=$_.severity; code=$_.code; expectedInvariant='Current action must remain aligned with acceptedGoal, acceptedRoute, nonGoals, and mustNotDriftTo.'; observedViolation=$_.evidence; evidence=@('goal-route-lock.json','last-route-checkpoint.json') } })
  guard='ROUTE_DRIFT_DETECTED means stop, return to the accepted user goal/route, and do not expand scope or change direction without approval.'; nextAction=if($unresolved){'Report ROUTE_DRIFT_DETECTED and realign the action with goal-route-lock before continuing.'}else{'Route remains aligned; re-check before mutation/completion.'}; path=if([string]::IsNullOrWhiteSpace($scopedRoutePath)){$statePath}else{$scopedRoutePath}
}
if($Preview){
  Write-RouteResult $result $(if($result.ok){0}else{1})
  if($NoExit){return}
}
$targetStatePath = if([string]::IsNullOrWhiteSpace($scopedRoutePath)){$statePath}else{$scopedRoutePath}
Write-JsonUtf8NoBom $targetStatePath $result 12
if([string]::IsNullOrWhiteSpace($TaskId)){Write-JsonUtf8NoBom $statePath $result 12}else{Update-CompatibilityRoute $result|Out-Null}
Write-JsonUtf8NoBom $outPath $result 12
Write-RouteResult $result $(if($result.ok){0}else{1})
if($NoExit){return}
