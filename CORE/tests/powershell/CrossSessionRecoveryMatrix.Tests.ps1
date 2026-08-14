$root = Split-Path -Parent (Split-Path $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$restoreScript = Join-Path $root 'scripts\session-restore.ps1'
$compactScript = Join-Path $root 'scripts\session-compact.ps1'

function Invoke-CrossSessionJson([string]$Script,[string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text|ConvertFrom-Json}else{$null}; text=$text }
}

function Invoke-CrossSessionRestore([string]$StateRoot,[string]$TaskId,[string]$WorkspaceKey,[string]$SessionKey) {
  $old = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    return Invoke-CrossSessionJson $restoreScript @('-Query','continue','-TaskId',$TaskId,'-WorkspaceKey',$WorkspaceKey,'-SessionId',$SessionKey,'-Json')
  } finally {
    if ($null -eq $old) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $old }
  }
}

Describe 'Cross-session and paused recovery matrix' {
  It 'withholds a foreign session, then restores the exact state after explicit rebind' {
    $stateRoot = Join-Path $TestDrive 'cross-session-rebind'
    $taskId = 'task-cross-session-rebind'
    $workspaceKey = 'ws-cross-session-rebind-424242424242'
    $oldSession = 'sid-cross-session-old-42424242'
    $newSession = 'sid-cross-session-new-42424242'
    $created = Invoke-CrossSessionJson $contractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$oldSession,'-FocusId','main','-InstructionMode','continue','-LatestUserInstruction','continue the current main','-CurrentPhase','P4','-CurrentStep','restore the exact step','-LastConfirmedSentence','The exact step is still pending.','-LastConfirmedSource','assistant_commitment','-NextAction','restore the exact step','-PendingSteps','restore the exact step','-StateRoot',$stateRoot,'-Json')
    $foreign = Invoke-CrossSessionRestore $stateRoot $taskId $workspaceKey $newSession
    $rebound = Invoke-CrossSessionJson $contractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$newSession,'-RebindSession','-InstructionMode','continue','-FocusId','main','-LatestUserInstruction','continue the current main after reconnect','-CurrentPhase','P4','-CurrentStep','restore the exact step','-LastConfirmedSentence','The exact step is still pending.','-LastConfirmedSource','assistant_commitment','-NextAction','restore the exact step','-ExpectedRevision',[string]$created.value.revision,'-ExpectedPlanFingerprint',[string]$created.value.planReceipt.planFingerprint,'-TransitionId','cross-session-rebind','-StateRoot',$stateRoot,'-Json')
    $restored = Invoke-CrossSessionRestore $stateRoot $taskId $workspaceKey $newSession

    $created.exitCode | Should Be 0
    $foreign.exitCode | Should Be 0
    ($foreign.text) | Should Not Match 'restore the exact step|The exact step is still pending'
    $foreign.value.executionResolution.actionAuthorization | Should Be 'withheld'
    $rebound.exitCode | Should Be 0
    $rebound.value.ownerSessionKey | Should Not Be $created.value.ownerSessionKey
    $restored.exitCode | Should Be 0
    $restored.value.executionResolution.actionAuthorization | Should Be 'allowed'
    $restored.value.resumeReceipt.currentPhase | Should Be 'P4'
    $restored.value.resumeReceipt.currentStep | Should Be 'restore the exact step'
    $restored.value.nextAction | Should Be 'restore the exact step'
    $restored.value.instructionAnchor.latestUserInstruction | Should Be 'continue the current main after reconnect'
  }

  It 'keeps a paused no-action boundary and resumes only after a new explicit action is committed' {
    $stateRoot = Join-Path $TestDrive 'paused-boundary'
    $taskId = 'task-paused-boundary'
    $workspaceKey = 'ws-paused-boundary-424242424242'
    $sessionKey = 'sid-paused-boundary-42424242'
    $paused = Invoke-CrossSessionJson $contractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-InstructionMode','continue','-LatestUserInstruction','wait for the user choice','-CurrentPhase','P4','-CurrentStep','waiting for target','-LastConfirmedSentence','Paused at the user-choice boundary.','-LastConfirmedSource','assistant_commitment','-NextAction','No automatic action: waiting for the user to choose a target.','-StateRoot',$stateRoot,'-Json')
    $pausedRestore = Invoke-CrossSessionRestore $stateRoot $taskId $workspaceKey $sessionKey
    $resumed = Invoke-CrossSessionJson $contractScript @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','main','-LatestUserInstruction','the target is chosen; continue now','-CurrentPhase','P4','-CurrentStep','execute after target selection','-LastConfirmedSentence','The target is chosen; continue now.','-LastConfirmedSource','assistant_commitment','-NextAction','execute after target selection','-ExpectedRevision',[string]$paused.value.revision,'-ExpectedPlanFingerprint',[string]$paused.value.planReceipt.planFingerprint,'-TransitionId','resume-after-pause','-StateRoot',$stateRoot,'-Json')
    $resumedRestore = Invoke-CrossSessionRestore $stateRoot $taskId $workspaceKey $sessionKey

    $paused.exitCode | Should Be 0
    $pausedRestore.exitCode | Should Be 0
    $pausedRestore.value.resumeReceipt.nextAction | Should Match '^No automatic action:'
    $pausedRestore.value.executionResolution.actionAuthorization | Should Be 'allowed'
    $resumed.exitCode | Should Be 0
    $resumedRestore.exitCode | Should Be 0
    $resumedRestore.value.resumeReceipt.nextAction | Should Be 'execute after target selection'
    $resumedRestore.value.resumeReceipt.currentStep | Should Be 'execute after target selection'
    $resumedRestore.value.instructionAnchor.latestUserInstruction | Should Be 'the target is chosen; continue now'
  }

  It 'does not archive historical text when the compaction scope is unavailable' {
    $stateRoot = Join-Path $TestDrive 'compact-without-state'
    $archiveRoot = Join-Path $TestDrive 'archive'
    New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
    $oldState = $env:SUPER_BRAIN_STATE_ROOT
    $oldArchive = $env:SUPER_BRAIN_ARCHIVE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_ARCHIVE_ROOT = $archiveRoot
      $compact = Invoke-CrossSessionJson $compactScript @('-InputText','verified text must not be archived without a scoped task','-TaskId','','-WorkspaceKey','','-SessionId','sid-compact-without-state-424242','-Json')
      $compact.exitCode | Should Be 1
      @(Get-ChildItem -LiteralPath $archiveRoot -Recurse -Filter '*.json' -ErrorAction SilentlyContinue).Count | Should Be 0
    } finally {
      if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
      if ($null -eq $oldArchive) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $oldArchive }
    }
  }
}
