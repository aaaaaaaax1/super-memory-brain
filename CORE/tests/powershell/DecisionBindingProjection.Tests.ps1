$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\common.ps1')

function Invoke-DecisionProjectionScript([string]$StateRoot,[string]$ScriptName,[string[]]$Arguments,[string]$EnvironmentWorkspaceKey='') {
  $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  $previousWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    if (-not [string]::IsNullOrWhiteSpace($EnvironmentWorkspaceKey)) { $env:SUPER_BRAIN_WORKSPACE_KEY = $EnvironmentWorkspaceKey }
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root ('scripts\' + $ScriptName)) @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
    if ($null -eq $previousWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $previousWorkspaceKey }
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { ConvertFrom-SuperBrainJsonOutput $text ($ScriptName + ' decision projection test') }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

function New-DecisionProjectionFixture([string]$StateRoot,[string]$TaskId) {
  $workspaceKey = 'ws-decision-projection-424242'
  $sessionKey = 'sid-decision-projection-424242'
  $agentId = 'agent-decision-projection'
  $sessionId = 'session-decision-projection'
  $ownerWorkspace = 'G:\decision-projection-tests'
  $privateGuidance = 'archive executable, installer, release notes, and test report together'
  $registered = Invoke-DecisionProjectionScript $StateRoot 'decision-binding.ps1' @(
    '-Action','Register','-DecisionId','release-archive','-WorkspaceKey',$workspaceKey,
    '-StageKinds','release','-Enforcement','completion_gate','-Authority','user_confirmed','-Lifecycle','active',
    '-ContentHash',('a' * 64),'-CompletionCriteriaDigest',('b' * 64),'-PrivateGuidance',$privateGuidance,'-Json'
  )
  $registered.exitCode | Should Be 0

  $contract = Invoke-DecisionProjectionScript $StateRoot 'execution-contract.ps1' @(
    '-Action','Set','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
    '-FocusId','release-main','-TopicKeys','release','-InstructionMode','continue','-LatestUserInstruction','prepare the release archive','-AssistantCommitment','deliver the verified release archive',
    '-NextAction','assemble the release archive','-CurrentPhase','release','-CurrentStep','assemble deliverables',
    '-PendingSteps','verify release archive','-StageKind','release','-DecisionIntentFingerprint','release-intent','-Json'
  )
  $contract.exitCode | Should Be 0
  $contract.value.decisionBinding.status | Should Be 'bound'

  $checkpoint = Invoke-DecisionProjectionScript $StateRoot 'checkpoint-writer.ps1' @(
    '-Action','Start','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Decision projection',
    '-CurrentStep','assemble deliverables','-PendingSteps','verify release archive','-AgentId',$agentId,'-SessionId',$sessionId,
    '-Platform','codex','-OwnerWorkspace',$ownerWorkspace,'-Json'
  )
  $checkpoint.exitCode | Should Be 0

  $context = Invoke-DecisionProjectionScript $StateRoot 'current-task-context.ps1' @(
    '-Action','Create','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,'-SessionId',$sessionId,
    '-AcceptedGoal','deliver the verified release archive','-AcceptedRoute','contract -> checkpoint -> context -> route',
    '-AgentId',$agentId,'-Platform','codex','-OwnerWorkspace',$ownerWorkspace,'-Json'
  )
  $context.exitCode | Should Be 0

  $goal = Invoke-DecisionProjectionScript $StateRoot 'goal-route-lock.ps1' @(
    '-Action','Create','-TaskId',$TaskId,'-AcceptedGoal','deliver the verified release archive',
    '-AcceptedRoute','contract -> checkpoint -> context -> route','-ApprovalEvidence','DecisionBindingProjection.Tests.ps1','-Json'
  )
  $goal.exitCode | Should Be 0

  $route = Invoke-DecisionProjectionScript $StateRoot 'route-checkpoint.ps1' @(
    '-Phase','BeforeMutation','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,
    '-ObservedAction','assemble the verified release archive','-Json'
  )
  $route.exitCode | Should Be 0
  return [pscustomobject]@{
    taskId=$TaskId; workspaceKey=$workspaceKey; sessionKey=$sessionKey; privateGuidance=$privateGuidance
    contract=$contract.value; checkpoint=$checkpoint.value; context=$context.value; route=$route.value
  }
}

Describe 'Decision binding projections and guarded guidance' {
  It 'propagates a decision digest without copying private guidance and rejects a stale route digest' {
    $stateRoot = Join-Path $TestDrive 'projection'
    $fixture = New-DecisionProjectionFixture $stateRoot 'task-decision-projection'
    $digest = [string]$fixture.contract.decisionBinding.bindingDigest

    foreach ($projection in @($fixture.checkpoint,$fixture.context,$fixture.route)) {
      $projection.stageKind | Should Be 'release'
      $projection.decisionBindingStatus | Should Be 'bound'
      $projection.decisionBindingDigest | Should Be $digest
      ($projection | ConvertTo-Json -Depth 12) | Should Not Match $fixture.privateGuidance
    }
    $fixture.route.bindingRequired | Should Be $true

    $storedRoute = Get-Content -LiteralPath $fixture.route.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $storedRoute.decisionBindingDigest = ('f' * 64)
    Write-JsonUtf8NoBom $fixture.route.path $storedRoute 12

    $guard = Invoke-DecisionProjectionScript $stateRoot 'completion-guard.ps1' @(
      '-TaskId',$fixture.taskId,'-AllowPrivacyRisk','-AllowActiveCheckpoint','-Json'
    )
    $bindingCheck = @($guard.value.checks | Where-Object { $_.name -eq 'route-checkpoint-binding' }) | Select-Object -First 1
    $bindingCheck.ok | Should Be $false
    $bindingCheck.evidence | Should Match 'active_decision_binding_digest_mismatch'

    $status = Invoke-DecisionProjectionScript $stateRoot 'route-checkpoint.ps1' @(
      '-Phase','Status','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-Json'
    )
    $status.exitCode | Should Be 1
    $status.value.status | Should Be 'stale'
    $status.value.freshness.reason | Should Be 'contract_binding_stale'
  }

  It 'loads private decision guidance only during a guarded mutation phase' {
    $stateRoot = Join-Path $TestDrive 'guidance'
    $fixture = New-DecisionProjectionFixture $stateRoot 'task-decision-guidance'
    $beforeAct = Invoke-DecisionProjectionScript $stateRoot 'cognitive-enforce.ps1' @(
      '-Query','prepare the release archive','-TaskId',$fixture.taskId,'-SessionKey',$fixture.sessionKey,
      '-ProposedWorkId','release-main','-Phase','BeforeAct','-AllowMissingPreflight','-Json'
    ) $fixture.workspaceKey
    $beforeAct.exitCode | Should Be 0
    $beforeAct.value.executionContract.decisionGuidanceRequired | Should Be $false
    @($beforeAct.value.executionContract.decisionGuidance).Count | Should Be 0
    $beforeAct.text | Should Not Match $fixture.privateGuidance

    $beforeMutation = Invoke-DecisionProjectionScript $stateRoot 'cognitive-enforce.ps1' @(
      '-Query','prepare the release archive','-TaskId',$fixture.taskId,'-SessionKey',$fixture.sessionKey,
      '-ProposedWorkId','release-main','-Phase','BeforeMutation','-AllowMissingPreflight','-Json'
    ) $fixture.workspaceKey
    $beforeMutation.exitCode | Should Be 0
    $beforeMutation.value.executionContract.decisionGuidanceRequired | Should Be $true
    $beforeMutation.value.executionContract.decisionGuidanceOk | Should Be $true
    @($beforeMutation.value.executionContract.decisionGuidance).Count | Should BeGreaterThan 0
    $beforeMutation.value.executionContract.decisionGuidance[0].text | Should Match 'archive executable'
  }
}
