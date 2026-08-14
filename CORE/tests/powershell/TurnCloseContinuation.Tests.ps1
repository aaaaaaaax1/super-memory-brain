$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
. (Join-Path $PSScriptRoot 'H7TestFixture.ps1')

function Invoke-TurnCloseContract([string[]]$Arguments) {
  return Invoke-H7FixtureContractScript -ContractScript $contractScript -Root $root -Arguments $Arguments
}

function New-TurnCloseFixture([string]$StateRoot,[string]$TaskId) {
  $workspaceKey = 'ws-turn-close-4242424242424242'
  $sessionKey = 'sid-turn-close-4242424242424242'
  $parent = Invoke-TurnCloseContract @(
    '-Action','Set','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
    '-FocusId','approved-main','-FocusLabel','Approved main line','-InstructionMode','continue',
    '-LatestUserInstruction','continue the approved main line','-AssistantCommitment','continue the approved main line after any handled insertion',
    '-NextAction','run the approved local verification','-CurrentPhase','Stage 3','-CurrentStep','run the approved local verification',
    '-PendingSteps','run the approved local verification','-StateRoot',$StateRoot,'-Json'
  )
  $parent.exitCode | Should Be 0
  $side = Invoke-TurnCloseContract @(
    '-Action','Set','-TaskId',$TaskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
    '-FocusId','status-insertion','-FocusLabel','Handled status insertion','-InstructionMode','side_branch',
    '-LatestUserInstruction','handle the status insertion then return to the approved main line',
    '-AssistantCommitment','answer the status insertion then restore the approved main line',
    '-NextAction','finish the bounded status insertion','-CurrentPhase','Stage 3','-CurrentStep','finish the bounded status insertion',
    '-PendingSteps','finish the bounded status insertion',
    '-ExpectedRevision',[string]$parent.value.revision,'-ExpectedPlanFingerprint',[string]$parent.value.planReceipt.planFingerprint,
    '-TransitionId','open-status-insertion','-StateRoot',$StateRoot,'-Json'
  )
  $side.exitCode | Should Be 0
  return [pscustomobject]@{ stateRoot=$StateRoot; taskId=$TaskId; workspaceKey=$workspaceKey; sessionKey=$sessionKey; parent=$parent.value; side=$side.value }
}

Describe 'Turn-close continuation dispatcher' {
  It 'restores the approved parent through the public no-Hook dispatcher after a completed insertion' {
    $fixture = New-TurnCloseFixture (Join-Path $TestDrive 'completed') 'task-turn-close-completed'
    $closed = Invoke-TurnCloseContract @(
      '-Action','CloseTurn','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,
      '-TurnOutcome','side_branch_completed','-UserControl','none','-CompletionEvidence','test:status-insertion-handled',
      '-ExpectedRevision',[string]$fixture.side.revision,'-ExpectedPlanFingerprint',[string]$fixture.side.planReceipt.planFingerprint,
      '-TransitionId','close-status-insertion','-StateRoot',$fixture.stateRoot,'-Json'
    )

    $closed.exitCode | Should Be 0
    $closed.value.decision | Should Be 'auto_resumed'
    $closed.value.policyDecision | Should Be 'resume_parent_required'
    $closed.value.transitionAction | Should Be 'ResumeParent'
    $closed.value.focusId | Should Be 'approved-main'
    $closed.value.nextAction | Should Be 'run the approved local verification'
    $closed.value.currentStep | Should Be 'run the approved local verification'
    @($closed.value.returnStack).Count | Should Be 0
    (@($closed.value.completedWorkLines) -contains 'status-insertion') | Should Be $true

    $resolved = Invoke-TurnCloseContract @(
      '-Action','Resolve','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,
      '-StateRoot',$fixture.stateRoot,'-Json'
    )
    $resolved.exitCode | Should Be 0
    $resolved.value.resumeFrom | Should Be 'parent_return'
    $resolved.value.actionAuthorization | Should Be 'allowed'
    $resolved.value.canResumeParent | Should Be $false

    $replay = Invoke-TurnCloseContract @(
      '-Action','CloseTurn','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,
      '-TurnOutcome','side_branch_completed','-UserControl','none','-CompletionEvidence','test:status-insertion-handled',
      '-ExpectedRevision',[string]$fixture.side.revision,'-ExpectedPlanFingerprint',[string]$fixture.side.planReceipt.planFingerprint,
      '-TransitionId','close-status-insertion','-StateRoot',$fixture.stateRoot,'-Json'
    )
    $replay.exitCode | Should Be 0
    $replay.value.idempotentReplay | Should Be $true
    [int]$replay.value.revision | Should Be ([int]$closed.value.revision)
  }

  It 'returns to the parent but retains a partially handled insertion as unfinished work' {
    $fixture = New-TurnCloseFixture (Join-Path $TestDrive 'partial') 'task-turn-close-partial'
    $closed = Invoke-TurnCloseContract @(
      '-Action','CloseTurn','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,
      '-TurnOutcome','side_branch_partial','-UserControl','none','-CompletionEvidence','test:partial-status-insertion-handoff',
      '-ExpectedRevision',[string]$fixture.side.revision,'-ExpectedPlanFingerprint',[string]$fixture.side.planReceipt.planFingerprint,
      '-TransitionId','close-partial-status-insertion','-StateRoot',$fixture.stateRoot,'-Json'
    )

    $closed.exitCode | Should Be 0
    $closed.value.decision | Should Be 'auto_resumed'
    $closed.value.resumedBranchStatus | Should Be 'partial'
    $closed.value.focusId | Should Be 'approved-main'
    (@($closed.value.completedWorkLines) -contains 'status-insertion') | Should Be $false
    (@($closed.value.unfinishedWorkPlans | Where-Object { $_.focusId -eq 'status-insertion' })).Count | Should Be 1
  }

  It 'does not resume when the caller cannot attest current-turn control or the user stopped work' {
    $fixture = New-TurnCloseFixture (Join-Path $TestDrive 'terminal-control') 'task-turn-close-terminal-control'
    $before = Get-FileHash -LiteralPath $fixture.side.path -Algorithm SHA256

    $unknown = Invoke-TurnCloseContract @(
      '-Action','CloseTurn','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,
      '-TurnOutcome','side_branch_completed','-CompletionEvidence','test:unattested-turn-close',
      '-ExpectedRevision',[string]$fixture.side.revision,'-ExpectedPlanFingerprint',[string]$fixture.side.planReceipt.planFingerprint,
      '-TransitionId','close-unattested-status-insertion','-StateRoot',$fixture.stateRoot,'-Json'
    )
    $afterUnknown = Get-FileHash -LiteralPath $fixture.side.path -Algorithm SHA256
    $unknown.exitCode | Should Be 0
    $unknown.value.decision | Should Be 'withhold_reconcile'
    $unknown.value.nextAction | Should BeNullOrEmpty
    $before.Hash | Should Be $afterUnknown.Hash

    $stopped = Invoke-TurnCloseContract @(
      '-Action','CloseTurn','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,
      '-TurnOutcome','side_branch_completed','-UserControl','stop','-CompletionEvidence','test:stopped-turn-close',
      '-ExpectedRevision',[string]$fixture.side.revision,'-ExpectedPlanFingerprint',[string]$fixture.side.planReceipt.planFingerprint,
      '-TransitionId','close-stopped-status-insertion','-StateRoot',$fixture.stateRoot,'-Json'
    )
    $afterStopped = Get-FileHash -LiteralPath $fixture.side.path -Algorithm SHA256
    $stopped.exitCode | Should Be 0
    $stopped.value.decision | Should Be 'pause_with_blocker'
    $stopped.value.nextAction | Should BeNullOrEmpty
    $before.Hash | Should Be $afterStopped.Hash
  }

  It 'fails closed for a foreign session and never exposes either saved action' {
    $fixture = New-TurnCloseFixture (Join-Path $TestDrive 'foreign') 'task-turn-close-foreign'
    $before = Get-FileHash -LiteralPath $fixture.side.path -Algorithm SHA256
    $foreign = Invoke-TurnCloseContract @(
      '-Action','CloseTurn','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey','sid-turn-close-foreign-4242424242424242',
      '-TurnOutcome','side_branch_completed','-UserControl','none','-CompletionEvidence','test:foreign-must-not-resume',
      '-ExpectedRevision',[string]$fixture.side.revision,'-ExpectedPlanFingerprint',[string]$fixture.side.planReceipt.planFingerprint,
      '-TransitionId','close-foreign-status-insertion','-StateRoot',$fixture.stateRoot,'-Json'
    )
    $after = Get-FileHash -LiteralPath $fixture.side.path -Algorithm SHA256
    $foreign.exitCode | Should Be 0
    $foreign.value.decision | Should Be 'withhold_reconcile'
    $foreign.value.actionAuthorization | Should Be 'withheld'
    $foreign.value.nextAction | Should BeNullOrEmpty
    (($foreign.value | ConvertTo-Json -Depth 10).Contains('run the approved local verification')) | Should Be $false
    (($foreign.value | ConvertTo-Json -Depth 10).Contains('finish the bounded status insertion')) | Should Be $false
    $before.Hash | Should Be $after.Hash
  }

  It 'pauses instead of resuming when the active branch records no automatic action' {
    $fixture = New-TurnCloseFixture (Join-Path $TestDrive 'no-automatic-action') 'task-turn-close-no-automatic-action'
    $stopped = Invoke-TurnCloseContract @(
      '-Action','Set','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,
      '-FocusId','status-insertion','-FocusLabel','Handled status insertion','-InstructionMode','continue',
      '-LatestUserInstruction','wait for a deployment target before continuing the insertion',
      '-NextAction','No automatic action: waiting for the user to choose a deployment target.',
      '-ExpectedRevision',[string]$fixture.side.revision,'-ExpectedPlanFingerprint',[string]$fixture.side.planReceipt.planFingerprint,
      '-TransitionId','record-no-automatic-action','-StateRoot',$fixture.stateRoot,'-Json'
    )
    $stopped.exitCode | Should Be 0
    $before = Get-FileHash -LiteralPath $stopped.value.path -Algorithm SHA256
    $closed = Invoke-TurnCloseContract @(
      '-Action','CloseTurn','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,
      '-TurnOutcome','side_branch_completed','-UserControl','none','-CompletionEvidence','test:no-automatic-action',
      '-ExpectedRevision',[string]$stopped.value.revision,'-ExpectedPlanFingerprint',[string]$stopped.value.planReceipt.planFingerprint,
      '-TransitionId','close-no-automatic-action','-StateRoot',$fixture.stateRoot,'-Json'
    )
    $after = Get-FileHash -LiteralPath $stopped.value.path -Algorithm SHA256
    $closed.exitCode | Should Be 0
    $closed.value.decision | Should Be 'pause_with_blocker'
    $closed.value.nextAction | Should BeNullOrEmpty
    $before.Hash | Should Be $after.Hash
  }
}
