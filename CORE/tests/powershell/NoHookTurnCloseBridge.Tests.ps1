$root = Split-Path -Parent (Split-Path $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$brainCli = Join-Path $root 'runtime\brain_cli.py'
. (Join-Path $root 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'H7TestFixture.ps1')

function Invoke-NoHookBridgeContract([string[]]$Arguments) {
  return Invoke-H7FixtureContractScript -ContractScript $contractScript -Root $root -Arguments $Arguments
}

Describe 'No-Hook turn-close bridge' {
  It 'projects a completed side branch to the public CloseTurn dispatcher before restoring its direct parent' {
    $stateRoot = Join-Path $TestDrive 'state'
    $hostRoot = Join-Path $TestDrive 'host-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot 'shared'),$hostRoot | Out-Null
    $workspaceKey = 'ws-' + (Get-SuperBrainStableHash ([IO.Path]::GetFullPath($hostRoot).TrimEnd('\','/').ToLowerInvariant()) 24)
    $sessionKey = 'sid-424242424242424242424242'
    $taskId = 'task-no-hook-turn-close'

    $parent = Invoke-NoHookBridgeContract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-FocusId','approved-main','-FocusLabel','Approved main line','-InstructionMode','continue',
      '-LatestUserInstruction','continue the approved main line','-LastConfirmedSentence','The approved main is ready to resume.',
      '-LastConfirmedSource','assistant_commitment','-NextAction','run the approved local verification',
      '-CurrentPhase','Stage 4','-CurrentStep','run the approved local verification',
      '-PendingSteps','run the approved local verification','-ProjectRoot',$hostRoot,'-StateRoot',$stateRoot,'-Json'
    )
    $parent.exitCode | Should Be 0

    $side = Invoke-NoHookBridgeContract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-FocusId','status-insertion','-FocusLabel','Handled status insertion','-InstructionMode','side_branch',
      '-LatestUserInstruction','answer the status question then return to the approved main line',
      '-LastConfirmedSentence','The status question was handled; return to the approved main.',
      '-LastConfirmedSource','assistant_commitment','-NextAction','finish the bounded status insertion',
      '-CurrentPhase','Stage 4','-CurrentStep','finish the bounded status insertion',
      '-PendingSteps','finish the bounded status insertion',
      '-ExpectedRevision',[string]$parent.value.revision,'-ExpectedPlanFingerprint',[string]$parent.value.planReceipt.planFingerprint,
      '-TransitionId','open-no-hook-status-insertion','-ProjectRoot',$hostRoot,'-StateRoot',$stateRoot,'-Json'
    )
    $side.exitCode | Should Be 0

    $previousThread = $env:SUPER_BRAIN_LOCAL_SESSION_ID
    $previousCwd = Get-Location
    try {
      $env:SUPER_BRAIN_LOCAL_SESSION_ID = $sessionKey
      Push-Location $hostRoot
      $before = Get-FileHash -LiteralPath $side.value.path -Algorithm SHA256
      $contextRaw = @(& python -X utf8 $brainCli --package-root $root --memory-root (Join-Path $stateRoot 'shared') context --memory-mode auto --turn-outcome side_branch_completed --user-control none --completion-evidence-present 2>$null)
      $context = (($contextRaw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
      $after = Get-FileHash -LiteralPath $side.value.path -Algorithm SHA256
    } finally {
      Pop-Location
      if ($null -eq $previousThread) { Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $previousThread }
    }

    $context.ok | Should Be $true
    $context.code | Should Be 'BRAIN_CONTEXT_READY'
    $context.task.lastConfirmedSentence | Should Be 'The status question was handled; return to the approved main.'
    $context.continuation.decision | Should Be 'resume_parent_required'
    $context.continuation.requiresParentResume | Should Be $true
    $before.Hash | Should Be $after.Hash

    $closed = Invoke-NoHookBridgeContract @(
      '-Action','CloseTurn','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-TurnOutcome','side_branch_completed','-UserControl','none','-CompletionEvidence','test:no-hook-context-attested-completion',
      '-ExpectedRevision',[string]$side.value.revision,'-ExpectedPlanFingerprint',[string]$side.value.planReceipt.planFingerprint,
      '-TransitionId','close-no-hook-status-insertion','-ProjectRoot',$hostRoot,'-StateRoot',$stateRoot,'-Json'
    )

    $closed.exitCode | Should Be 0
    $closed.value.policyDecision | Should Be 'resume_parent_required'
    $closed.value.transitionAction | Should Be 'ResumeParent'
    $closed.value.focusId | Should Be 'approved-main'
    $closed.value.nextAction | Should Be 'run the approved local verification'
  }
}
