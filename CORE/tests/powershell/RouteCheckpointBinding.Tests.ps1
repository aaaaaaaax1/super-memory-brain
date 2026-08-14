$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\common.ps1')

function Invoke-RouteBindingScript([string]$StateRoot,[string]$ScriptName,[string[]]$Arguments) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root ('scripts\' + $ScriptName)) @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    $env:SUPER_BRAIN_STATE_ROOT = $previous
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { ConvertFrom-SuperBrainJsonOutput $text ($ScriptName + ' route binding test') }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

function New-BoundRouteFixture([string]$StateRoot,[string]$TaskId) {
  $workspaceKey = 'ws-424242424242424242424242'
  $sessionKey = 'sid-424242424242424242424242'
  $contract = Invoke-RouteBindingScript $StateRoot 'execution-contract.ps1' @(
    '-Action','Set','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
    '-FocusId','route-binding-main','-NextAction','verify exact route binding','-RequireStructuralGuards','-Json'
  )
  $contract.exitCode | Should Be 0
  $context = Invoke-RouteBindingScript $StateRoot 'current-task-context.ps1' @(
    '-Action','Create','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,'-AcceptedGoal','verify exact route binding',
    '-AcceptedRoute','contract -> task state -> route checkpoint','-AgentId','agent-route-binding',
    '-SessionId','session-route-binding','-Platform','codex','-OwnerWorkspace','G:\route-binding-tests','-Json'
  )
  $context.exitCode | Should Be 0
  $goal = Invoke-RouteBindingScript $StateRoot 'goal-route-lock.ps1' @(
    '-Action','Create','-TaskId',$TaskId,'-AcceptedGoal','verify exact route binding',
    '-AcceptedRoute','contract -> task state -> route checkpoint','-ApprovalEvidence','RouteCheckpointBinding.Tests.ps1','-Json'
  )
  $goal.exitCode | Should Be 0
  $route = Invoke-RouteBindingScript $StateRoot 'route-checkpoint.ps1' @(
    '-Phase','BeforeMutation','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,
    '-ObservedAction','verify exact route binding','-Json'
  )
  return [pscustomobject]@{ workspaceKey=$workspaceKey; sessionKey=$sessionKey; contract=$contract.value; context=$context.value; route=$route }
}

Describe 'Route checkpoint exact lifecycle binding' {
  It 'binds a protected checkpoint to the exact task-state and execution-contract revisions' {
    $stateRoot = Join-Path $TestDrive 'bound-route'
    $fixture = New-BoundRouteFixture $stateRoot 'task-route-bound'
    $fixture.route.exitCode | Should Be 0
    $route = $fixture.route.value
    $route.bindingState | Should Be 'bound'
    $route.bindingRequired | Should Be $true
    [int]$route.taskStateRevision | Should Be ([int]$fixture.context.taskStateRevision)
    [int]$route.contractRevision | Should Be ([int]$fixture.contract.revision)
    $route.planFingerprint | Should Be $fixture.contract.planReceipt.planFingerprint
    $route.ownerSessionKey | Should Be $fixture.contract.ownerSessionKey
    $route.lifecycleStatus | Should Be 'active'
    $route.compatibilityEpoch | Should Be 'route-checkpoint-contract-v1'
    $route.targetHash | Should Not BeNullOrEmpty

    $beforeHash = (Get-FileHash -LiteralPath $route.path -Algorithm SHA256).Hash
    $status = Invoke-RouteBindingScript $stateRoot 'route-checkpoint.ps1' @('-Phase','Status','-TaskId','task-route-bound','-WorkspaceKey',$fixture.workspaceKey,'-Json')
    $status.exitCode | Should Be 0
    $status.value.bindingState | Should Be 'bound'
    (Get-FileHash -LiteralPath $route.path -Algorithm SHA256).Hash | Should Be $beforeHash
  }

  It 'fails closed when a structural contract has no authoritative task-state projection' {
    $stateRoot = Join-Path $TestDrive 'missing-projection'
    $taskId = 'task-route-missing-projection'
    $workspaceKey = 'ws-434343434343434343434343'
    $contract = Invoke-RouteBindingScript $stateRoot 'execution-contract.ps1' @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','sid-434343434343434343434343',
      '-FocusId','route-binding-main','-NextAction','verify missing projection','-RequireStructuralGuards','-Json'
    )
    $contract.exitCode | Should Be 0
    (Invoke-RouteBindingScript $stateRoot 'goal-route-lock.ps1' @('-Action','Create','-TaskId',$taskId,'-AcceptedGoal','verify missing projection','-AcceptedRoute','fail closed','-ApprovalEvidence','test','-Json')).exitCode | Should Be 0
    $route = Invoke-RouteBindingScript $stateRoot 'route-checkpoint.ps1' @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','verify missing projection','-Json')
    $route.exitCode | Should Be 1
    $route.value.bindingState | Should Be 'locator_only'
    $route.value.bindingReason | Should Be 'task_state_projection_missing'
    @($route.value.violations.code) -contains 'route_checkpoint_binding_required' | Should Be $true
  }

  It 'lets the completion guard reject a checkpoint after its task-state revision becomes stale' {
    $stateRoot = Join-Path $TestDrive 'stale-route'
    $fixture = New-BoundRouteFixture $stateRoot 'task-route-stale'
    $fixture.route.exitCode | Should Be 0
    $updated = Invoke-RouteBindingScript $stateRoot 'current-task-context.ps1' @(
      '-Action','Update','-TaskId','task-route-stale','-WorkspaceKey',$fixture.workspaceKey,
      '-ExpectedRevision',[string]$fixture.context.taskStateRevision,'-AcceptedGoal','verify exact route binding',
      '-AcceptedRoute','refresh context after route','-AgentId','agent-route-binding','-SessionId','session-route-binding',
      '-Platform','codex','-OwnerWorkspace','G:\route-binding-tests','-Json'
    )
    $updated.exitCode | Should Be 0
    [int]$updated.value.taskStateRevision | Should BeGreaterThan ([int]$fixture.route.value.taskStateRevision)

    $guard = Invoke-RouteBindingScript $stateRoot 'completion-guard.ps1' @('-TaskId','task-route-stale','-AllowPrivacyRisk','-AllowActiveCheckpoint','-Json')
    $bindingCheck = @($guard.value.checks | Where-Object { $_.name -eq 'route-checkpoint-binding' }) | Select-Object -First 1
    $bindingCheck.ok | Should Be $false
    $bindingCheck.evidence | Should Match 'active_task_state_revision_mismatch'
  }

  It 'lets the completion guard reject a route checkpoint after the bound contract changes' {
    $stateRoot = Join-Path $TestDrive 'contract-drift'
    $fixture = New-BoundRouteFixture $stateRoot 'task-route-contract-drift'
    $fixture.route.exitCode | Should Be 0
    $contractPath = Join-Path (Join-Path $stateRoot 'workspace\runtime-state\execution-contracts') $fixture.route.value.contractFileName
    $contract = Get-Content -LiteralPath $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $contract.revision = [int]$contract.revision + 1
    [IO.File]::WriteAllText($contractPath,($contract | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))

    $guard = Invoke-RouteBindingScript $stateRoot 'completion-guard.ps1' @('-TaskId','task-route-contract-drift','-AllowPrivacyRisk','-AllowActiveCheckpoint','-Json')
    $bindingCheck = @($guard.value.checks | Where-Object { $_.name -eq 'route-checkpoint-binding' }) | Select-Object -First 1
    $bindingCheck.ok | Should Be $false
    $bindingCheck.evidence | Should Match 'active_contract_hash_mismatch'
  }

  It 'keeps legacy guard-only callers usable as non-authorizing locator checkpoints' {
    $stateRoot = Join-Path $TestDrive 'legacy-locator'
    $taskId = 'task-route-legacy-locator'
    (Invoke-RouteBindingScript $stateRoot 'goal-route-lock.ps1' @('-Action','Create','-TaskId',$taskId,'-AcceptedGoal','legacy guard flow','-AcceptedRoute','route only','-ApprovalEvidence','test','-Json')).exitCode | Should Be 0
    $route = Invoke-RouteBindingScript $stateRoot 'route-checkpoint.ps1' @('-Phase','BeforeAct','-TaskId',$taskId,'-ObservedAction','legacy guard flow','-Json')
    $route.exitCode | Should Be 0
    $route.value.bindingState | Should Be 'locator_only'
    $route.value.bindingRequired | Should Be $false
  }

  It 'binds canonical plan identity into the route checkpoint without copying the plan body' {
    $stateRoot = Join-Path $TestDrive 'canonical-route-binding'
    $taskId = 'task-route-canonical'
    $workspaceKey = 'ws-canonical-route-202607'
    $sessionKey = 'sid-canonical-route-202607'
    $contract = Invoke-RouteBindingScript $stateRoot 'execution-contract.ps1' @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-FocusId','canonical-main','-NextAction','A','-PendingSteps','A','-EnableCanonicalPlan','-RequireStructuralGuards','-Json'
    )
    $contract.exitCode | Should Be 0
    $context = Invoke-RouteBindingScript $stateRoot 'current-task-context.ps1' @(
      '-Action','Create','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-AcceptedGoal','bind canonical route',
      '-AcceptedRoute','canonical contract -> task state -> route','-AgentId','agent-route-binding',
      '-SessionId','session-route-binding','-Platform','codex','-OwnerWorkspace','G:\route-binding-tests','-Json'
    )
    $context.exitCode | Should Be 0
    (Invoke-RouteBindingScript $stateRoot 'goal-route-lock.ps1' @('-Action','Create','-TaskId',$taskId,'-AcceptedGoal','bind canonical route','-AcceptedRoute','canonical only','-ApprovalEvidence','test','-Json')).exitCode | Should Be 0
    $route = Invoke-RouteBindingScript $stateRoot 'route-checkpoint.ps1' @('-Phase','BeforeMutation','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','bind canonical route','-Json')
    $route.exitCode | Should Be 0
    $route.value.canonicalPlanId | Should Be $contract.value.canonicalPlan.planId
    [int]$route.value.canonicalGeneration | Should Be 1
    $route.value.canonicalFingerprint | Should Be $contract.value.canonicalPlan.currentFingerprint
    $route.value.compatibilityEpoch | Should Be 'route-checkpoint-contract-v2'
    $route.text.Contains('"items"') | Should Be $false

    $guard = Invoke-RouteBindingScript $stateRoot 'completion-guard.ps1' @('-TaskId',$taskId,'-AllowPrivacyRisk','-AllowActiveCheckpoint','-Json')
    $bindingCheck = @($guard.value.checks | Where-Object { $_.name -eq 'route-checkpoint-binding' }) | Select-Object -First 1
    $bindingCheck.ok | Should Be $true
    $bindingCheck.evidence | Should Match 'bound_to_active_contract_and_task_state'
  }
}
