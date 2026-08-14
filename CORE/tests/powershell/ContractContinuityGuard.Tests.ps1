$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ContractScript = Join-Path $Root 'scripts\execution-contract.ps1'
$ContextScript = Join-Path $Root 'scripts\current-task-context.ps1'
$RouteScript = Join-Path $Root 'scripts\route-checkpoint.ps1'
$CheckpointScript = Join-Path $Root 'scripts\checkpoint-writer.ps1'

function Invoke-ContinuityGuardScript([string]$ScriptPath,[string[]]$Arguments,[string]$StateRoot) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n").Trim()
  return [pscustomobject]@{ exitCode=$exitCode; value=if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}; text=$text }
}

function Invoke-ContinuityGuardContract([string[]]$Arguments,[string]$StateRoot) {
  $parameters = @{}
  $switches = @('RebindSession')
  for ($index = 0; $index -lt $Arguments.Count; ) {
    $rawName = [string]$Arguments[$index]
    if (-not $rawName.StartsWith('-')) { throw "expected parameter name, got $rawName" }
    $name = $rawName.TrimStart('-')
    if ($switches -contains $name) {
      $parameters[$name] = $true
      $index++
      continue
    }
    if (($index + 1) -ge $Arguments.Count) { throw "missing value for $rawName" }
    $parameters[$name] = $Arguments[$index + 1]
    $index += 2
  }
  $parameters.NoExit = $true
  $parameters.Json = $true
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& $ContractScript @parameters 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n").Trim()
  return [pscustomobject]@{ exitCode=$exitCode; value=if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}; text=$text }
}

function Start-GuardCheckpoint([string]$StateRoot,[string]$TaskId,[string]$WorkspaceKey,[string]$AgentId,[string]$SessionId,[string]$OwnerWorkspace,[string]$Goal) {
  return Invoke-ContinuityGuardScript $CheckpointScript @(
    '-Action','Start','-TaskId',$TaskId,'-WorkspaceKey',$WorkspaceKey,
    '-AgentId',$AgentId,'-SessionId',$SessionId,'-Platform','zcode','-OwnerWorkspace',$OwnerWorkspace,
    '-TaskName','Continuity guard fixture','-Goal',$Goal,
    '-CurrentPhase','initial','-CurrentStep','first action','-NextAction','first action',
    '-PendingSteps','first action','-Json'
  ) $StateRoot
}

Describe 'Execution contract continuity action guard' {

  It 'rebinds a fully projected governed task to a new root session in one continuity transaction' {
    $stateRoot = Join-Path $TestDrive 'session-rebind'
    $taskId = 'task-guard-session-rebind'
    $workspaceKey = 'ws-guard-session-rebind-20260729'
    $firstSession = 'sid-guard-session-rebind-owner'
    $secondSession = 'sid-guard-session-rebind-successor'
    $intentJson = ([pscustomobject]@{
      schema='super-brain.intent-contract.v2';literalRequestDigest='continue the same governed task after reconnect';resolvedOutcome='The original task continues under a verified new root session.'
      productRole='governed task continuity';integrationObligations=@('task receipt','continuity projection');materialUnknowns=@();compatibilityGuards=@('preserve original task identity');preservedCapabilities=@('original plan')
      acceptanceCriteria=@('a verified session handoff keeps the original task');governedEquivalent='receipt-bound owner handoff';autonomyTier='align'
      integrationMap=[pscustomobject]@{entryPoint='session restore';userFlow='reopen conversation, recover task, continue';domainOwner='execution contract';stateOwner='task authority';downstreamConsumers=@('continuation receipt');failureRecovery='owner mismatch fails closed';privacyPerformance='local bounded receipt';compatibilityMigration='keep old task id';verification='continuity transaction';completionCondition='new owner is authoritative'}
      investigationEvidence=@('verified old task contract');materialBranches=@();focusedQuestion='';preserveExistingFlow=$true;replacementReceipt=''
      componentResolution=[pscustomobject]@{requestedComponent='original task';resolvedComponent='same task under new owner';outcomePreserved=$true;reason='session changes must not replace the task'}
    } | ConvertTo-Json -Compress)
    $initial = Invoke-ContinuityGuardContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$firstSession,'-FocusId','main','-NextAction','continue original task','-LatestUserInstruction','continue the original governed task','-IntentContractJson',$intentJson,'-StateRoot',$stateRoot) -StateRoot $stateRoot
    $initial.exitCode | Should Be 0
    (Start-GuardCheckpoint $stateRoot $taskId $workspaceKey 'agent-rebind' ([string]$initial.value.ownerSessionKey) 'G:\guard-session-rebind' 'preserve original task ownership').exitCode | Should Be 0
    (Invoke-ContinuityGuardScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-rebind','-SessionId',([string]$initial.value.ownerSessionKey),'-Platform','zcode','-OwnerWorkspace','G:\guard-session-rebind','-AcceptedGoal','preserve original task ownership','-AcceptedRoute','verify then transfer owner','-Json') $stateRoot).exitCode | Should Be 0
    (Invoke-ContinuityGuardScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','bind session-rebind route','-AllowMissingGoalLock','-Json') $stateRoot).exitCode | Should Be 0
    $synchronized = Invoke-ContinuityGuardContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$firstSession,'-FocusId','main','-NextAction','continue original task','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','session-rebind-synchronize','-StateRoot',$stateRoot) -StateRoot $stateRoot
    $synchronized.exitCode | Should Be 0

    $rebound = Invoke-ContinuityGuardContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$secondSession,'-RebindSession','-InstructionMode','continue','-FocusId','main','-NextAction','continue original task','-ExpectedRevision',[string]$synchronized.value.revision,'-ExpectedPlanFingerprint',[string]$synchronized.value.planReceipt.planFingerprint,'-TransitionId','session-rebind-transaction','-StateRoot',$stateRoot) -StateRoot $stateRoot
    if ($rebound.exitCode -ne 0) { throw ('SESSION_REBIND_FAILED ' + $rebound.text) }
    $rebound.exitCode | Should Be 0
    $rebound.value.taskId | Should Be $taskId
    $rebound.value.taskInstanceId | Should Be $synchronized.value.taskInstanceId
    $rebound.value.ownerSessionKey | Should Not Be $initial.value.ownerSessionKey
    $rebound.value.intentSessionRebindReceipt.previousOwnerSessionKey | Should Be $initial.value.ownerSessionKey
    $rebound.value.intentSessionRebindReceipt.newOwnerSessionKey | Should Be $rebound.value.ownerSessionKey

    $stateStore = Join-Path $Root 'scripts\task-state-store.ps1'
    $state = Invoke-ContinuityGuardScript $stateStore @('-Action','Get','-TaskId',$taskId,'-Json') $stateRoot
    $state.exitCode | Should Be 0
    $state.value.lifecycle.ownerSessionKey | Should Be $rebound.value.ownerSessionKey
    $state.value.entities.context.owner.sessionId | Should Be $rebound.value.ownerSessionKey
    $state.value.entities.checkpoint.owner.sessionId | Should Be $rebound.value.ownerSessionKey
    $state.value.entities.task_card.owner.sessionId | Should Be $rebound.value.ownerSessionKey

    $oldRead = Invoke-ContinuityGuardContract -Arguments @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$firstSession,'-StateRoot',$stateRoot) -StateRoot $stateRoot
    $oldRead.value.ok | Should Be $false
    $oldRead.value.code | Should Be 'EXECUTION_CONTRACT_FOREIGN_SESSION'
    (Invoke-ContinuityGuardContract -Arguments @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$secondSession,'-ProposedWorkId','main','-StateRoot',$stateRoot) -StateRoot $stateRoot).exitCode | Should Be 0
  }

  It 'rebinds a fully projected non-intent task with a task-authority receipt' {
    $stateRoot = Join-Path $TestDrive 'non-intent-session-rebind'
    $taskId = 'task-guard-non-intent-rebind'
    $workspaceKey = 'ws-guard-non-intent-rebind-20260801'
    $firstSession = 'legacy-host-session-non-intent-owner'
    $secondSession = 'sid-guard-non-intent-successor'

    $initial = Invoke-ContinuityGuardContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$firstSession,'-FocusId','main','-NextAction','continue original task','-LatestUserInstruction','continue the original task','-StateRoot',$stateRoot) -StateRoot $stateRoot
    $initial.exitCode | Should Be 0
    $initial.value.intentContractRequired | Should Be $false
    (Start-GuardCheckpoint $stateRoot $taskId $workspaceKey 'agent-non-intent-rebind' $firstSession 'G:\guard-non-intent-rebind' 'preserve original task ownership').exitCode | Should Be 0
    (Invoke-ContinuityGuardScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-non-intent-rebind','-SessionId',$firstSession,'-Platform','zcode','-OwnerWorkspace','G:\guard-non-intent-rebind','-AcceptedGoal','preserve original task ownership','-AcceptedRoute','verify then transfer owner','-Json') $stateRoot).exitCode | Should Be 0
    (Invoke-ContinuityGuardScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','bind non-intent session-rebind route','-AllowMissingGoalLock','-Json') $stateRoot).exitCode | Should Be 0
    $synchronized = Invoke-ContinuityGuardContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$firstSession,'-FocusId','main','-NextAction','continue original task','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','non-intent-session-rebind-synchronize','-StateRoot',$stateRoot) -StateRoot $stateRoot
    $synchronized.exitCode | Should Be 0

    $rebound = Invoke-ContinuityGuardContract -Arguments @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$secondSession,'-RebindSession','-InstructionMode','continue','-FocusId','main','-NextAction','continue original task','-ExpectedRevision',[string]$synchronized.value.revision,'-ExpectedPlanFingerprint',[string]$synchronized.value.planReceipt.planFingerprint,'-TransitionId','non-intent-session-rebind-transaction','-StateRoot',$stateRoot) -StateRoot $stateRoot
    if ($rebound.exitCode -ne 0) { throw ('NON_INTENT_SESSION_REBIND_FAILED ' + $rebound.text) }
    $rebound.exitCode | Should Be 0
    $rebound.value.ownerSessionKey | Should Not Be $initial.value.ownerSessionKey
    $rebound.value.taskSessionRebindReceipt.schema | Should Be 'super-brain.task-session-rebind-receipt.v1'
    $rebound.value.taskSessionRebindReceipt.previousOwnerSessionKey | Should Be $initial.value.ownerSessionKey
    $rebound.value.taskSessionRebindReceipt.newOwnerSessionKey | Should Be $rebound.value.ownerSessionKey
    $rebound.value.taskSessionRebindReceipt.taskRevision | Should BeGreaterThan 0

    $stateStore = Join-Path $Root 'scripts\task-state-store.ps1'
    $state = Invoke-ContinuityGuardScript $stateStore @('-Action','Get','-TaskId',$taskId,'-Json') $stateRoot
    $state.exitCode | Should Be 0
    $state.value.lifecycle.ownerSessionKey | Should Be $rebound.value.ownerSessionKey
    $state.value.entities.context.owner.sessionId | Should Be $rebound.value.ownerSessionKey
    $state.value.entities.checkpoint.owner.sessionId | Should Be $rebound.value.ownerSessionKey
    $state.value.entities.task_card.owner.sessionId | Should Be $rebound.value.ownerSessionKey
  }

  It 'keeps a contract without a current context on the compatible direct path' {
    $stateRoot = Join-Path $TestDrive 'direct'
    $taskId = 'task-guard-direct'
    $workspaceKey = 'ws-guard-direct-20260726'
    $sessionKey = 'sid-guard-direct-20260726'
    (Invoke-ContinuityGuardScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','perform direct work','-StateRoot',$stateRoot,'-Json') $stateRoot).exitCode | Should Be 0

    $guard = Invoke-ContinuityGuardScript $ContractScript @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','main','-StateRoot',$stateRoot,'-Json') $stateRoot
    $guard.exitCode | Should Be 0
    $guard.value.code | Should Be 'EXECUTION_CONTRACT_GUARD_OK'
    $guard.value.continuity.required | Should Be $false
  }

  It 'permits a fully bound contract after the transactional continuity refresh' {
    $stateRoot = Join-Path $TestDrive 'bound'
    $taskId = 'task-guard-bound'
    $workspaceKey = 'ws-guard-bound-20260726'
    $sessionKey = 'sid-guard-bound-20260726'
    $initial = Invoke-ContinuityGuardScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    (Start-GuardCheckpoint $stateRoot $taskId $workspaceKey 'agent-guard' 'context-guard' 'G:\guard-bound' 'guard exact continuity').exitCode | Should Be 0
    (Invoke-ContinuityGuardScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-guard','-SessionId','context-guard','-Platform','zcode','-OwnerWorkspace','G:\guard-bound','-AcceptedGoal','guard exact continuity','-AcceptedRoute','bind then mutate','-Json') $stateRoot).exitCode | Should Be 0
    (Invoke-ContinuityGuardScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','bind route before guarded work','-AllowMissingGoalLock','-Json') $stateRoot).exitCode | Should Be 0
    $synchronized = Invoke-ContinuityGuardScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','guard-bound-synchronize','-StateRoot',$stateRoot,'-Json') $stateRoot
    $synchronized.exitCode | Should Be 0
    $updated = Invoke-ContinuityGuardScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','second action','-ExpectedRevision',[string]$synchronized.value.revision,'-ExpectedPlanFingerprint',[string]$synchronized.value.planReceipt.planFingerprint,'-TransitionId','guard-bound-update','-StateRoot',$stateRoot,'-Json') $stateRoot
    $updated.exitCode | Should Be 0

    $guard = Invoke-ContinuityGuardScript $ContractScript @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','main','-ExpectedRevision',[string]$updated.value.revision,'-ExpectedPlanFingerprint',[string]$updated.value.planReceipt.planFingerprint,'-StateRoot',$stateRoot,'-Json') $stateRoot
    $guard.exitCode | Should Be 0
    $guard.value.code | Should Be 'EXECUTION_CONTRACT_GUARD_OK'
    $guard.value.continuity.required | Should Be $true
    $guard.value.continuity.current | Should Be $true
    $guard.value.continuity.code | Should Be 'EXECUTION_CONTRACT_CONTINUITY_CURRENT'
  }

  It 'withholds mutation when a bound route or prepared transaction is no longer current' {
    $stateRoot = Join-Path $TestDrive 'withheld'
    $taskId = 'task-guard-withheld'
    $workspaceKey = 'ws-guard-withheld-20260726'
    $sessionKey = 'sid-guard-withheld-20260726'
    $initial = Invoke-ContinuityGuardScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    (Start-GuardCheckpoint $stateRoot $taskId $workspaceKey 'agent-withheld' 'context-withheld' 'G:\guard-withheld' 'withhold stale continuity').exitCode | Should Be 0
    (Invoke-ContinuityGuardScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-withheld','-SessionId','context-withheld','-Platform','zcode','-OwnerWorkspace','G:\guard-withheld','-AcceptedGoal','withhold stale continuity','-AcceptedRoute','verify before mutation','-Json') $stateRoot).exitCode | Should Be 0
    $route = Invoke-ContinuityGuardScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','bind route before mutation','-AllowMissingGoalLock','-Json') $stateRoot
    $route.exitCode | Should Be 0
    $synchronized = Invoke-ContinuityGuardScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','guard-withheld-synchronize','-StateRoot',$stateRoot,'-Json') $stateRoot
    $synchronized.exitCode | Should Be 0

    $storedRoute = Get-Content -LiteralPath $route.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $storedRoute.targetHash = '0' * 64
    [IO.File]::WriteAllText([string]$route.value.path,($storedRoute | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $routeBlocked = Invoke-ContinuityGuardScript $ContractScript @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','main','-StateRoot',$stateRoot,'-Json') $stateRoot
    $routeBlocked.exitCode | Should Be 1
    $routeBlocked.value.code | Should Be 'EXECUTION_CONTRACT_CONTINUITY_ROUTE_BINDING_MISMATCH'

    $interrupted = Invoke-ContinuityGuardScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','second action','-ExpectedRevision',[string]$synchronized.value.revision,'-ExpectedPlanFingerprint',[string]$synchronized.value.planReceipt.planFingerprint,'-TransitionId','guard-pending-update','-ContinuityFaultPoint','after_materialize','-StateRoot',$stateRoot,'-Json') $stateRoot
    $interrupted.exitCode | Should Be 1
    $pendingBlocked = Invoke-ContinuityGuardScript $ContractScript @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ProposedWorkId','main','-StateRoot',$stateRoot,'-Json') $stateRoot
    $pendingBlocked.exitCode | Should Be 1
    $pendingBlocked.value.code | Should Match '^EXECUTION_CONTRACT_CONTINUITY_'
  }
}
