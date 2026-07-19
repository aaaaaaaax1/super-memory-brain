$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$sessionRestoreScript = Join-Path $root 'scripts\session-restore.ps1'

function Invoke-StateCardContract([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $contractScript @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text|ConvertFrom-Json}else{$null}; text=$text }
}

function Invoke-StateCardRestore([string]$StateRoot,[string[]]$Arguments) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sessionRestoreScript @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text|ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'Whole-line continuity state card' {
  It 'persists and resolves the complete active-line state' {
    $stateRoot = Join-Path $TestDrive 'state-card-contract'
    $workspaceKey = 'ws-state-card-contract-111111111111'
    $sessionKey = 'sid-state-card-contract'
    $set = Invoke-StateCardContract @(
      '-Action','Set','-TaskId','task-state-card-contract','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-FocusId','active-line','-FocusLabel','Active line','-InstructionMode','continue',
      '-NextAction','run state-card regression','-CurrentPhase','verification','-CurrentStep','execute focused test',
      '-CompletedSteps','capture plan','-PendingSteps','execute focused test','-Blockers','none',
      '-Evidence','contract revision evidence','-VerificationResults','not run','-StateCardSource','pester',
      '-StateRoot',$stateRoot,'-Json'
    )
    $set.exitCode | Should Be 0
    $set.value.continuityStateCard.schema | Should Be 'super-brain.task-state-card.v1'
    $set.value.continuityStateCard.taskId | Should Be 'task-state-card-contract'
    $set.value.continuityStateCard.activeLineId | Should Be 'active-line'
    $set.value.continuityStateCard.phase | Should Be 'verification'
    $set.value.continuityStateCard.currentStep | Should Be 'execute focused test'
    @($set.value.continuityStateCard.completedSteps) | Should Be @('capture plan')
    @($set.value.continuityStateCard.pendingSteps) | Should Be @('execute focused test')
    -not [string]::IsNullOrWhiteSpace([string]$set.value.continuityStateCard.stateFingerprint) | Should Be $true

    $resolved = Invoke-StateCardContract @('-Action','Resolve','-TaskId','task-state-card-contract','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')
    $resolved.exitCode | Should Be 0
    $resolved.value.continuityStateCard.activeLineId | Should Be 'active-line'
    $resolved.value.continuityStateCard.phase | Should Be 'verification'
    $resolved.value.continuityStateCard.currentStep | Should Be 'execute focused test'
    $resolved.value.continuityStateCard.nextAction | Should Be 'run state-card regression'
  }

  It 'restores the parent line state after a side branch' {
    $stateRoot = Join-Path $TestDrive 'state-card-parent-return'
    $workspaceKey = 'ws-state-card-parent-222222222222'
    $sessionKey = 'sid-state-card-parent'
    $parentArgs = @('-TaskId','task-state-card-parent','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')
    (Invoke-StateCardContract (@('-Action','Set') + $parentArgs + @('-FocusId','parent-line','-FocusLabel','Parent line','-InstructionMode','continue','-NextAction','resume parent action','-CurrentPhase','parent-phase','-CurrentStep','parent-step','-CompletedSteps','parent-done','-PendingSteps','parent-pending','-Evidence','parent-evidence'))).exitCode | Should Be 0
    (Invoke-StateCardContract (@('-Action','Set') + $parentArgs + @('-FocusId','side-line','-FocusLabel','Side line','-InstructionMode','side_branch','-LatestUserInstruction','continue side-line audit','-NextAction','finish side action','-CurrentPhase','side-phase','-CurrentStep','side-step','-CompletedSteps','side-done','-PendingSteps','side-pending','-Evidence','side-evidence'))).exitCode | Should Be 0

    $resumed = Invoke-StateCardContract (@('-Action','ResumeParent') + $parentArgs + @('-BranchStatus','completed','-CompletionEvidence','side branch verified'))
    $resumed.exitCode | Should Be 0
    $resumed.value.focusId | Should Be 'parent-line'
    $resumed.value.continuityStateCard.activeLineId | Should Be 'parent-line'
    $resumed.value.continuityStateCard.phase | Should Be 'parent-phase'
    $resumed.value.continuityStateCard.currentStep | Should Be 'parent-step'
    @($resumed.value.continuityStateCard.completedSteps) | Should Be @('parent-done')
    @($resumed.value.continuityStateCard.pendingSteps) | Should Be @('parent-pending')
    @($resumed.value.continuityStateCard.evidence) | Should Be @('parent-evidence')
    $resumed.value.completedSideBranchFocusId | Should Be 'side-line'
  }

  It 'keeps line identity visible but withholds actions for unresolved instructions' {
    $stateRoot = Join-Path $TestDrive 'state-card-withheld'
    $workspaceKey = 'ws-state-card-withheld-333333333333'
    $sessionKey = 'sid-state-card-withheld'
    (Invoke-StateCardContract @('-Action','Set','-TaskId','task-state-card-withheld','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','known-line','-NextAction','known action','-CurrentStep','known step','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $resolved = Invoke-StateCardContract @('-Action','Resolve','-TaskId','task-state-card-withheld','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-VisibleUserInstruction','do an unrelated unknown request','-StateRoot',$stateRoot,'-Json')
    $resolved.exitCode | Should Be 0
    $resolved.value.claimAllowed | Should Be $false
    $resolved.value.continuityStateCard.activeLineId | Should Be 'known-line'
    $resolved.value.continuityStateCard.nextAction | Should BeNullOrEmpty
    $resolved.value.continuityStateCard.currentStep | Should BeNullOrEmpty
    $resolved.text.Contains('known action') | Should Be $false
    $resolved.text.Contains('known step') | Should Be $false
  }

  It 'includes the scoped state card in the bounded session restore packet' {
    $stateRoot = Join-Path $TestDrive 'state-card-restore'
    $workspaceKey = 'ws-state-card-restore-444444444444'
    $sessionKey = 'sid-state-card-restore'
    (Invoke-StateCardContract @('-Action','Set','-TaskId','task-state-card-restore','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','restore-line','-NextAction','restore exact line','-CurrentPhase','restore-phase','-CurrentStep','restore-step','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $restore = Invoke-StateCardRestore $stateRoot @('-TaskId','task-state-card-restore','-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-MemoryMode','auto','-MaxTokens','300','-TopK','1','-Json')
    $restore.exitCode | Should Be 0
    $restore.value.recoveryPoint.continuityStateCard.schema | Should Be 'super-brain.task-state-card.v1'
    $restore.value.recoveryPoint.continuityStateCard.activeLineId | Should Be 'restore-line'
    $restore.value.recoveryPoint.continuityStateCard.phase | Should Be 'restore-phase'
    $restore.value.recoveryPoint.continuityStateCard.currentStep | Should Be 'restore-step'
    $restore.value.packetLimits.serializedChars -le $restore.value.packetLimits.maxChars | Should Be $true
  }
}
