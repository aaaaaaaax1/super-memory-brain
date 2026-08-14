$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ContractScript = Join-Path $Root 'scripts\execution-contract.ps1'
$ContextScript = Join-Path $Root 'scripts\current-task-context.ps1'
$RouteScript = Join-Path $Root 'scripts\route-checkpoint.ps1'
$CheckpointScript = Join-Path $Root 'scripts\checkpoint-writer.ps1'
$TaskStateStoreScript = Join-Path $Root 'scripts\task-state-store.ps1'

function Invoke-ProjectionScript([string]$ScriptPath,[string[]]$Arguments,[string]$StateRoot) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n").Trim()
  $value = $null
  if (-not [string]::IsNullOrWhiteSpace($text)) { try { $value = $text | ConvertFrom-Json } catch {} }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

function Start-ProjectionCheckpoint([string]$StateRoot,[string]$TaskId,[string]$WorkspaceKey,[string]$AgentId,[string]$SessionId,[string]$OwnerWorkspace,[string]$Goal,[string]$CurrentStep) {
  return Invoke-ProjectionScript $CheckpointScript @(
    '-Action','Start','-TaskId',$TaskId,'-WorkspaceKey',$WorkspaceKey,
    '-AgentId',$AgentId,'-SessionId',$SessionId,'-Platform','zcode','-OwnerWorkspace',$OwnerWorkspace,
    '-TaskName','Transactional continuity fixture','-Goal',$Goal,
    '-CurrentPhase','initial','-CurrentStep',$CurrentStep,'-NextAction',$CurrentStep,
    '-PendingSteps',$CurrentStep,'-Json'
  ) $StateRoot
}

function Read-ProjectionCheckpoint([string]$StateRoot,[string]$TaskId) {
  $path = @(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'workspace\runtime-state\checkpoints\active') -Filter '*.json' -File | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).taskId -eq $TaskId
  } | Select-Object -First 1)[0].FullName
  return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-ProjectionTaskCard([string]$StateRoot,[string]$TaskId) {
  $path = @(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'shared\tasks\active') -Filter '*.task.json' -File | Where-Object {
    (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).taskId -eq $TaskId
  } | Select-Object -First 1)[0].FullName
  return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

Describe 'Execution contract continuity projection refresh' {
  It 'does not block a non-authorizing locator context' {
    $stateRoot = Join-Path $TestDrive 'locator-context'
    $workspaceKey = 'ws-locator-context-20260722'
    $taskId = 'task-locator-context'
    $sessionKey = 'sid-locator-context-20260722'
    $locator = Invoke-ProjectionScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-locator','-SessionId','context-locator','-Platform','zcode','-OwnerWorkspace','G:\locator-context','-AcceptedGoal','locate only','-AcceptedRoute','defer binding','-Json') $stateRoot
    $locator.exitCode | Should Be 0
    $locator.value.bindingState | Should Be 'locator_only'

    $initial = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    $initial.value.continuityRefresh.reason | Should Be 'context_non_authorizing'
    $updated = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','second action','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','locator-update','-StateRoot',$stateRoot,'-Json') $stateRoot
    $updated.exitCode | Should Be 0
    $updated.value.continuityRefresh.reason | Should Be 'context_non_authorizing'
  }

  It 'recovers an interrupted first bound-context bootstrap without accepting its partial state' {
    $stateRoot = Join-Path $TestDrive 'bootstrap-transaction'
    $workspaceKey = 'ws-bootstrap-transaction-20260728'
    $taskId = 'task-bootstrap-transaction'
    $sessionKey = 'sid-bootstrap-transaction-20260728'
    $agentId = 'agent-bootstrap'
    $sessionId = 'context-bootstrap'
    $ownerWorkspace = 'G:\bootstrap-transaction'
    $initial = Invoke-ProjectionScript $ContractScript @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json'
    ) $stateRoot
    $initial.exitCode | Should Be 0
    (Start-ProjectionCheckpoint $stateRoot $taskId $workspaceKey $agentId $sessionId $ownerWorkspace 'recover the first bound context transaction' 'first action').exitCode | Should Be 0

    $interrupted = Invoke-ProjectionScript $ContractScript @(
      '-Action','BindContext','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,
      '-ContextAcceptedGoal','recover the first bound context transaction','-ContextAcceptedRoute','contract then bootstrap context',
      '-ContextAgentId',$agentId,'-ContextSessionId',$sessionId,'-ContextPlatform','zcode','-ContextOwnerWorkspace',$ownerWorkspace,
      '-ContinuityFaultPoint','after_materialize','-StateRoot',$stateRoot,'-Json'
    ) $stateRoot
    $interrupted.exitCode | Should Be 1
    $interrupted.value.code | Should Be 'EXECUTION_CONTRACT_CONTINUITY_TRANSACTION_FAILED'

    $beforeRecovery = Invoke-ProjectionScript $ContextScript @('-Action','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $beforeRecovery.exitCode | Should Be 1
    $beforeRecovery.value.status | Should Not Be 'active'
    $pendingAudit = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Audit','-Json') $stateRoot
    $pendingAudit.exitCode | Should Be 1
    $pendingAudit.value.incompleteTransactionCount | Should Be 1

    $reconcile = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Reconcile','-Apply','-Json') $stateRoot
    $reconcile.exitCode | Should Be 0
    $reconcile.value.recoveredCount | Should Be 1
    $contextStatus = Invoke-ProjectionScript $ContextScript @('-Action','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $contextStatus.exitCode | Should Be 0
    $contextStatus.value.current.bindingState | Should Be 'bound'
    $projectionPath = @(
      Get-ChildItem -LiteralPath (Join-Path $stateRoot 'workspace\task-state-store\projections') -Filter '*.json' -File |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).taskId -eq $taskId } |
        Select-Object -First 1
    )[0].FullName
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.revision | Should Be 2
    $projection.entities.context.status | Should Be 'active'
    $projection.entities.checkpoint.status | Should Be 'active'
    $projection.entities.task_card.status | Should Be 'active'
  }

  It 'refreshes an existing context and route checkpoint after a contract revision' {
    $stateRoot = Join-Path $TestDrive 'projection-refresh'
    $workspaceKey = 'ws-projection-refresh-20260722'
    $taskId = 'task-projection-refresh'
    $sessionKey = 'sid-projection-refresh-20260722'

    $initial = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    (Start-ProjectionCheckpoint $stateRoot $taskId $workspaceKey 'agent-refresh' 'context-refresh' 'G:\projection-refresh' 'keep projections current' 'first action').exitCode | Should Be 0
    $context = Invoke-ProjectionScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-refresh','-SessionId','context-refresh','-Platform','zcode','-OwnerWorkspace','G:\projection-refresh','-AcceptedGoal','keep projections current','-AcceptedRoute','contract then projections','-Json') $stateRoot
    $context.exitCode | Should Be 0
    $route = Invoke-ProjectionScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','initial projection binding','-AllowMissingGoalLock','-Json') $stateRoot
    $route.exitCode | Should Be 0

    $updated = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','second action','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','projection-refresh-update','-StateRoot',$stateRoot,'-Json') $stateRoot
    $updated.exitCode | Should Be 0
    $updated.value.continuityRefresh.state | Should Be 'refreshed'

    $contextStatus = Invoke-ProjectionScript $ContextScript @('-Action','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $contextStatus.exitCode | Should Be 0
    $contextStatus.value.freshness.reason | Should Be 'fresh'
    $contextStatus.value.current.contractRevision | Should Be $updated.value.revision
    $contextStatus.value.current.planFingerprint | Should Be $updated.value.planReceipt.planFingerprint

    $routeStatus = Invoke-ProjectionScript $RouteScript @('-Phase','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $routeStatus.exitCode | Should Be 0
    $routeStatus.value.freshness.reason | Should Be 'fresh'
    $routeStatus.value.contractRevision | Should Be $updated.value.revision
    $routeStatus.value.planFingerprint | Should Be $updated.value.planReceipt.planFingerprint

    $checkpoint = Read-ProjectionCheckpoint $stateRoot $taskId
    $checkpoint.contractRevision | Should Be $updated.value.revision
    $checkpoint.planFingerprint | Should Be $updated.value.planReceipt.planFingerprint
    $checkpoint.currentStep | Should Be $updated.value.currentStep
    $checkpoint.nextAction | Should Be 'second action'
    $checkpoint.taskStateRevision | Should Be $routeStatus.value.taskStateRevision
    $taskCard = Read-ProjectionTaskCard $stateRoot $taskId
    $taskCard.contractRevision | Should Be $updated.value.revision
    $taskCard.planFingerprint | Should Be $updated.value.planReceipt.planFingerprint
    $taskCard.currentStep | Should Be $updated.value.currentStep
    $taskCard.nextAction | Should Be 'second action'
    $taskCard.taskStateRevision | Should Be $routeStatus.value.taskStateRevision
  }

  It 'fails closed when a route checkpoint binding is expired or stale' {
    $stateRoot = Join-Path $TestDrive 'route-freshness'
    $workspaceKey = 'ws-route-freshness-20260722'
    $taskId = 'task-route-freshness'
    $sessionKey = 'sid-route-freshness-20260722'
    $initial = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    (Invoke-ProjectionScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-route','-SessionId','context-route','-Platform','zcode','-OwnerWorkspace','G:\route-freshness','-AcceptedGoal','keep routes current','-AcceptedRoute','route checkpoint freshness','-Json') $stateRoot).exitCode | Should Be 0
    $route = Invoke-ProjectionScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','initial route binding','-AllowMissingGoalLock','-Json') $stateRoot
    $route.exitCode | Should Be 0
    $stored = Get-Content -LiteralPath $route.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $stored.expiresAt = (Get-Date).AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss')
    [IO.File]::WriteAllText([string]$route.value.path,($stored|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))

    $status = Invoke-ProjectionScript $RouteScript @('-Phase','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $status.exitCode | Should Be 1
    $status.value.status | Should Be 'stale'
    $status.value.freshness.reason | Should Be 'expired'
  }

  It 'recovers an interrupted contract continuity transaction without accepting its partial projection' {
    $stateRoot = Join-Path $TestDrive 'txn'
    $workspaceKey = 'ws-txn-20260726'
    $taskId = 'task-txn'
    $sessionKey = 'sid-txn-20260726'
    $initial = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    (Start-ProjectionCheckpoint $stateRoot $taskId $workspaceKey 'agent-transaction' 'context-transaction' 'G:\projection-transaction' 'recover a single continuity transaction' 'first action').exitCode | Should Be 0
    $createdContext = Invoke-ProjectionScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-transaction','-SessionId','context-transaction','-Platform','zcode','-OwnerWorkspace','G:\projection-transaction','-AcceptedGoal','recover a single continuity transaction','-AcceptedRoute','prepare then recover','-Json') $stateRoot
    if ($createdContext.exitCode -ne 0) { throw ('CONTEXT_CREATE_FAILED ' + $createdContext.text) }
    $createdContext.exitCode | Should Be 0
    (Invoke-ProjectionScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','initial transactional projection binding','-AllowMissingGoalLock','-Json') $stateRoot).exitCode | Should Be 0

    $interrupted = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','second action','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','projection-transaction-recovery','-ContinuityFaultPoint','after_materialize','-StateRoot',$stateRoot,'-Json') $stateRoot
    $interrupted.exitCode | Should Be 1
    $interrupted.value.code | Should Be 'EXECUTION_CONTRACT_CONTINUITY_TRANSACTION_FAILED'

    $beforeRecovery = Invoke-ProjectionScript $RouteScript @('-Phase','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $beforeRecovery.exitCode | Should Be 1
    $beforeRecovery.value.status | Should Be 'stale'
    $pendingAudit = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Audit','-Json') $stateRoot
    $pendingAudit.exitCode | Should Be 1
    $pendingAudit.value.incompleteTransactionCount | Should Be 1

    $reconcile = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Reconcile','-Apply','-Json') $stateRoot
    $reconcile.exitCode | Should Be 0
    $reconcile.value.recoveredCount | Should Be 1
    $reconcile.value.blockedCount | Should Be 0

    $contextStatus = Invoke-ProjectionScript $ContextScript @('-Action','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $contextStatus.exitCode | Should Be 0
    $contextStatus.value.freshness.reason | Should Be 'fresh'
    $routeStatus = Invoke-ProjectionScript $RouteScript @('-Phase','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $routeStatus.exitCode | Should Be 0
    $routeStatus.value.freshness.reason | Should Be 'fresh'
    $routeStatus.value.contractRevision | Should Be 2
    (Read-ProjectionCheckpoint $stateRoot $taskId).currentStep | Should Be 'first action'
    (Read-ProjectionTaskCard $stateRoot $taskId).currentStep | Should Be 'first action'
  }

  It 'rebuilds continuity from the SQLite outbox when the process stops before file WAL prepare' {
    $stateRoot = Join-Path $TestDrive 'sqlite-outbox-recovery'
    $workspaceKey = 'ws-sqlite-outbox-20260727'
    $taskId = 'task-sqlite-outbox'
    $sessionKey = 'sid-sqlite-outbox-20260727'
    $initial = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    (Start-ProjectionCheckpoint $stateRoot $taskId $workspaceKey 'agent-sqlite-outbox' 'context-sqlite-outbox' 'G:\projection-sqlite-outbox' 'recover from the durable SQLite outbox' 'first action').exitCode | Should Be 0
    (Invoke-ProjectionScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-sqlite-outbox','-SessionId','context-sqlite-outbox','-Platform','zcode','-OwnerWorkspace','G:\projection-sqlite-outbox','-AcceptedGoal','recover from the durable SQLite outbox','-AcceptedRoute','SQLite authority then projection','-Json') $stateRoot).exitCode | Should Be 0
    (Invoke-ProjectionScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','initial SQLite outbox binding','-AllowMissingGoalLock','-Json') $stateRoot).exitCode | Should Be 0

    $interrupted = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','second action','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','sqlite-outbox-only-recovery','-ContinuityFaultPoint','after_authority','-StateRoot',$stateRoot,'-Json') $stateRoot
    $interrupted.exitCode | Should Be 1
    $interrupted.value.code | Should Be 'EXECUTION_CONTRACT_CONTINUITY_TRANSACTION_FAILED'

    $pendingAudit = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Audit','-Json') $stateRoot
    $pendingAudit.value.incompleteTransactionCount | Should Be 0
    $dryRun = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Reconcile','-Json') $stateRoot
    $dryRun.exitCode | Should Be 1
    $dryRun.value.authorityPendingCount | Should Be 1

    $reconcile = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Reconcile','-Apply','-Json') $stateRoot
    if ($reconcile.exitCode -ne 0) { throw ('SQLITE_OUTBOX_RECONCILE_FAILED ' + $reconcile.text) }
    $reconcile.exitCode | Should Be 0
    $reconcile.value.recoveredCount | Should Be 0
    $reconcile.value.authorityRecoveredCount | Should Be 1
    $reconcile.value.blockedCount | Should Be 0
    $reconcile.value.authorityPendingCount | Should Be 1

    $routeStatus = Invoke-ProjectionScript $RouteScript @('-Phase','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $routeStatus.exitCode | Should Be 0
    $routeStatus.value.freshness.reason | Should Be 'fresh'
    $routeStatus.value.contractRevision | Should Be 2
    (Read-ProjectionCheckpoint $stateRoot $taskId).taskStateRevision | Should Be $routeStatus.value.taskStateRevision
    (Read-ProjectionTaskCard $stateRoot $taskId).taskStateRevision | Should Be $routeStatus.value.taskStateRevision

    $after = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Reconcile','-Json') $stateRoot
    $after.exitCode | Should Be 0
    $after.value.authorityPendingCount | Should Be 0
  }

  It 'recovers an active bundle from SQLite after task authority already exists' {
    $stateRoot = Join-Path $TestDrive 'active-bundle-authority'
    $workspaceKey = 'ws-active-bundle-authority-20260727'
    $taskId = 'task-active-bundle-authority'
    $sessionKey = 'sid-active-bundle-authority-20260727'
    $initial = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    (Start-ProjectionCheckpoint $stateRoot $taskId $workspaceKey 'agent-active-authority' 'context-active-authority' 'G:\active-bundle-authority' 'keep active progress canonical' 'first action').exitCode | Should Be 0
    (Invoke-ProjectionScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-active-authority','-SessionId','context-active-authority','-Platform','zcode','-OwnerWorkspace','G:\active-bundle-authority','-AcceptedGoal','keep active progress canonical','-AcceptedRoute','authority then active projection','-Json') $stateRoot).exitCode | Should Be 0
    (Invoke-ProjectionScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','initial active authority binding','-AllowMissingGoalLock','-Json') $stateRoot).exitCode | Should Be 0
    $updated = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','second action','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','active-authority-contract','-StateRoot',$stateRoot,'-Json') $stateRoot
    $updated.exitCode | Should Be 0
    $route = Invoke-ProjectionScript $RouteScript @('-Phase','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json') $stateRoot
    $route.exitCode | Should Be 0

    $interrupted = Invoke-ProjectionScript $CheckpointScript @(
      '-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,
      '-AgentId','agent-active-authority','-SessionId','context-active-authority','-Platform','zcode','-OwnerWorkspace','G:\active-bundle-authority',
      '-TaskName','Active authority update','-Goal','keep active progress canonical','-CurrentPhase','implementation','-CurrentStep','third action','-NextAction','third action',
      '-PendingSteps','third action','-ExpectedRevision',[string]$route.value.taskStateRevision,'-FaultPoint','after_authority','-Json'
    ) $stateRoot
    $interrupted.exitCode | Should Be 1
    $interrupted.text | Should Match 'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY'

    $reconcile = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Reconcile','-Apply','-Json') $stateRoot
    $reconcile.exitCode | Should Be 0
    $reconcile.value.recoveredCount | Should Be 0
    $reconcile.value.authorityRecoveredCount | Should Be 1
    (Read-ProjectionCheckpoint $stateRoot $taskId).currentStep | Should Be 'third action'
    (Read-ProjectionTaskCard $stateRoot $taskId).currentStep | Should Be 'third action'
  }

  It 'rebuilds a missing compatibility journal and projection from SQLite authority' {
    $stateRoot = Join-Path $TestDrive 'sqlite-snapshot-rebuild'
    $workspaceKey = 'ws-sqlite-snapshot-20260727'
    $taskId = 'task-sqlite-snapshot'
    $sessionKey = 'sid-sqlite-snapshot-20260727'
    $initial = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','first action','-StateRoot',$stateRoot,'-Json') $stateRoot
    $initial.exitCode | Should Be 0
    (Start-ProjectionCheckpoint $stateRoot $taskId $workspaceKey 'agent-snapshot' 'context-snapshot' 'G:\sqlite-snapshot' 'rebuild compatibility from authority' 'first action').exitCode | Should Be 0
    (Invoke-ProjectionScript $ContextScript @('-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AgentId','agent-snapshot','-SessionId','context-snapshot','-Platform','zcode','-OwnerWorkspace','G:\sqlite-snapshot','-AcceptedGoal','rebuild compatibility from authority','-AcceptedRoute','SQLite authority snapshot','-Json') $stateRoot).exitCode | Should Be 0
    (Invoke-ProjectionScript $RouteScript @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','initial snapshot binding','-AllowMissingGoalLock','-Json') $stateRoot).exitCode | Should Be 0
    $updated = Invoke-ProjectionScript $ContractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-NextAction','second action','-ExpectedRevision',[string]$initial.value.revision,'-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,'-TransitionId','sqlite-snapshot-contract','-StateRoot',$stateRoot,'-Json') $stateRoot
    $updated.exitCode | Should Be 0

    $eventFile = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'workspace\task-state-store\events') -Filter '*.jsonl' -File | Where-Object {
      @(Get-Content -LiteralPath $_.FullName -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { [string]$_.taskId -eq $taskId }).Count -gt 0
    } | Select-Object -First 1)[0]
    $eventFile | Should Not BeNullOrEmpty
    $projectionFile = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'workspace\task-state-store\projections') -Filter '*.json' -File | Where-Object {
      (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).taskId -eq $taskId
    } | Select-Object -First 1)[0]
    $projectionFile | Should Not BeNullOrEmpty
    Remove-Item -LiteralPath $eventFile.FullName -Force
    Remove-Item -LiteralPath $projectionFile.FullName -Force

    $rebuilt = Invoke-ProjectionScript $TaskStateStoreScript @('-Action','Rebuild','-Apply','-Json') $stateRoot
    $rebuilt.exitCode | Should Be 0
    $rebuilt.value.authorityRestoredCount | Should Be 1
    (Read-ProjectionCheckpoint $stateRoot $taskId).nextAction | Should Be 'second action'
    (Read-ProjectionTaskCard $stateRoot $taskId).nextAction | Should Be 'second action'
  }
}
