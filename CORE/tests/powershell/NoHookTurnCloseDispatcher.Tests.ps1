$root = Split-Path -Parent (Split-Path $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$brainCli = Join-Path $root 'runtime\brain_cli.py'
. (Join-Path $root 'scripts\common.ps1')
. (Join-Path $PSScriptRoot 'H7TestFixture.ps1')

function Invoke-DispatcherContract([string[]]$Arguments) {
  return Invoke-H7FixtureContractScript -ContractScript $contractScript -Root $root -Arguments $Arguments
}

function Invoke-NoHookDispatcher([string]$PackageRoot,[string]$MemoryRoot,[string]$ProjectRoot,[string]$TaskId,[string]$WorkspaceKey,[string]$SessionKey,[string]$Outcome,[string]$Evidence,[string]$UserControl='none') {
  $previousLocalSession = $env:SUPER_BRAIN_LOCAL_SESSION_ID
  $env:SUPER_BRAIN_LOCAL_SESSION_ID = $SessionKey
  Push-Location $ProjectRoot
  try {
    $raw = @(& python -X utf8 $brainCli --package-root $PackageRoot --memory-root $MemoryRoot turn-close --task-id $TaskId --workspace-key $WorkspaceKey --session-key $SessionKey --turn-outcome $Outcome --user-control $UserControl --completion-evidence-ref $Evidence 2>$null)
    $exitCode = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  } finally {
    Pop-Location
    if ($null -eq $previousLocalSession) { Remove-Item Env:SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $previousLocalSession }
  }
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text|ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'No-Hook turn-close dispatcher' {
  It 'automatically resumes the direct parent and replays the same transition idempotently' {
    $stateRoot = Join-Path $TestDrive 'dispatcher-state'
    $memoryRoot = Join-Path $stateRoot 'shared'
    $hostRoot = Join-Path $stateRoot 'host-project'
    New-Item -ItemType Directory -Force -Path $hostRoot | Out-Null
    $taskId = 'task-no-hook-dispatcher'
    $workspaceKey = 'ws-' + (Get-SuperBrainStableHash ([IO.Path]::GetFullPath($hostRoot).TrimEnd('\','/').ToLowerInvariant()) 24)
    $sessionKey = 'sid-424242424242424242424242'
    $parent = Invoke-DispatcherContract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','approved-main','-FocusLabel','Approved main','-InstructionMode','continue','-LatestUserInstruction','continue the approved main','-CurrentPhase','Stage 3','-CurrentStep','run the approved verification','-LastConfirmedSentence','The approved main is ready.','-LastConfirmedSource','assistant_commitment','-NextAction','run the approved verification','-PendingSteps','run the approved verification','-ProjectRoot',$hostRoot,'-StateRoot',$stateRoot,'-Json')
    $side = Invoke-DispatcherContract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','status-insertion','-FocusLabel','Status insertion','-InstructionMode','side_branch','-LatestUserInstruction','answer the status insertion then return to the approved main','-CurrentPhase','Stage 3','-CurrentStep','finish the status insertion','-LastConfirmedSentence','The status insertion is handled.','-LastConfirmedSource','assistant_commitment','-NextAction','finish the status insertion','-PendingSteps','finish the status insertion','-ExpectedRevision',[string]$parent.value.revision,'-ExpectedPlanFingerprint',[string]$parent.value.planReceipt.planFingerprint,'-TransitionId','open-dispatcher-side','-ProjectRoot',$hostRoot,'-StateRoot',$stateRoot,'-Json')
    $first = Invoke-NoHookDispatcher $root $memoryRoot $hostRoot $taskId $workspaceKey $sessionKey 'side_branch_completed' 'test:side-insertion-complete'
    $second = Invoke-NoHookDispatcher $root $memoryRoot $hostRoot $taskId $workspaceKey $sessionKey 'side_branch_completed' 'test:side-insertion-complete'

    $parent.exitCode | Should Be 0
    $side.exitCode | Should Be 0
    $first.exitCode | Should Be 0
    $first.value.ok | Should Be $true
    $first.value.policy.decision | Should Be 'resume_parent_required'
    $first.value.transition.action | Should Be 'ResumeParent'
    $first.value.transition.focusId | Should Be 'approved-main'
    $first.value.stateMutated | Should Be $true
    $second.exitCode | Should Be 0
    $second.value.ok | Should Be $true
    $second.value.transition.idempotentReplay | Should Be $true
    $second.value.transition.revision | Should Be $first.value.transition.revision
    ($first.text + $second.text) | Should Not Match 'hooks.json|StopHook|UserPromptSubmit'
  }

  It 'fails closed without mutating when the current contract is foreign' {
    $stateRoot = Join-Path $TestDrive 'dispatcher-foreign'
    $memoryRoot = Join-Path $stateRoot 'shared'
    $hostRoot = Join-Path $stateRoot 'host-project'
    New-Item -ItemType Directory -Force -Path $hostRoot | Out-Null
    $taskId = 'task-no-hook-dispatcher-foreign'
    $workspaceKey = 'ws-' + (Get-SuperBrainStableHash ([IO.Path]::GetFullPath($hostRoot).TrimEnd('\','/').ToLowerInvariant()) 24)
    $ownerSession = 'sid-aaaaaaaaaaaaaaaaaaaaaaaa'
    $foreignSession = 'sid-bbbbbbbbbbbbbbbbbbbbbbbb'
    $created = Invoke-DispatcherContract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$ownerSession,'-FocusId','foreign-main','-InstructionMode','continue','-LatestUserInstruction','continue foreign-owned task','-CurrentPhase','Stage 3','-CurrentStep','private action','-NextAction','private action','-PendingSteps','private action','-ProjectRoot',$hostRoot,'-StateRoot',$stateRoot,'-Json')
    $foreign = Invoke-NoHookDispatcher $root $memoryRoot $hostRoot $taskId $workspaceKey $foreignSession 'side_branch_completed' 'test:must-withhold'

    $created.exitCode | Should Be 0
    $foreign.exitCode | Should Be 0
    $foreign.value.ok | Should Be $true
    $foreign.value.stateMutated | Should Be $false
    $foreign.value.policy.decision | Should Be 'withhold_reconcile'
    ($foreign.text) | Should Not Match 'private action'
  }

  It 'honors no-action and explicit stop gates without writing a transition' {
    $stateRoot = Join-Path $TestDrive 'dispatcher-gates'
    $memoryRoot = Join-Path $stateRoot 'shared'
    $hostRoot = Join-Path $stateRoot 'host-project'
    New-Item -ItemType Directory -Force -Path $hostRoot | Out-Null
    $taskId = 'task-no-hook-dispatcher-gates'
    $workspaceKey = 'ws-' + (Get-SuperBrainStableHash ([IO.Path]::GetFullPath($hostRoot).TrimEnd('\','/').ToLowerInvariant()) 24)
    $sessionKey = 'sid-cccccccccccccccccccccccc'
    $paused = Invoke-DispatcherContract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','gated-line','-InstructionMode','continue','-LatestUserInstruction','wait for the deployment target','-CurrentPhase','Stage 3','-CurrentStep','waiting for target','-NextAction','No automatic action: waiting for the user to choose a deployment target.','-ProjectRoot',$hostRoot,'-StateRoot',$stateRoot,'-Json')
    $noAction = Invoke-NoHookDispatcher $root $memoryRoot $hostRoot $taskId $workspaceKey $sessionKey 'side_branch_completed' 'test:no-action'
    $beforeStop = Get-FileHash -LiteralPath $paused.value.path -Algorithm SHA256
    $stop = Invoke-NoHookDispatcher $root $memoryRoot $hostRoot $taskId $workspaceKey $sessionKey 'side_branch_completed' 'test:stop-gate' 'stop'
    $afterStop = Get-FileHash -LiteralPath $paused.value.path -Algorithm SHA256

    $paused.exitCode | Should Be 0
    $noAction.exitCode | Should Be 0
    $noAction.value.policy.decision | Should Be 'pause_with_blocker'
    $noAction.value.stateMutated | Should Be $false
    $noAction.value.transition | Should BeNullOrEmpty
    $stop.exitCode | Should Be 0
    $stop.value.policy.decision | Should Be 'pause_with_blocker'
    $stop.value.stateMutated | Should Be $false
    $beforeStop.Hash | Should Be $afterStop.Hash
  }
}
