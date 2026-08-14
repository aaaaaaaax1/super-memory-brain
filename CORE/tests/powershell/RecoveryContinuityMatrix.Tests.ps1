$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$compactScript = Join-Path $root 'scripts\session-compact.ps1'
$restoreScript = Join-Path $root 'scripts\session-restore.ps1'
$checkpointScript = Join-Path $root 'scripts\recovery-checkpoint.ps1'

function Invoke-JsonFileScript([string]$Script,[string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

function Invoke-ContractMatrix([string[]]$Arguments) {
  return Invoke-JsonFileScript $contractScript $Arguments
}

Describe 'Stage 2 user-level recovery continuity matrix' {
  It 'prioritizes the newest instruction and preserves progress without reusing the old action' {
    $stateRoot = Join-Path $TestDrive 'latest-instruction'
    $taskId = 'task-stage2-latest-instruction'
    $workspaceKey = 'ws-stage2-latest-instruction-424242424242'
    $sessionKey = 'sid-stage2-latest-instruction-42424242'
    $set = Invoke-ContractMatrix @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-InstructionMode','continue','-LatestUserInstruction','continue the approved main line','-CurrentPhase','P2','-CurrentStep','old step is complete','-LastConfirmedSentence','old step is complete','-LastConfirmedSource','assistant_commitment','-NextAction','run the old next action','-PendingSteps','run the old next action','-StateRoot',$stateRoot,'-Json')
    $observe = Invoke-ContractMatrix @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-UserInstruction','answer the inserted status question first; then return to the main line','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $oldState = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $restore = Invoke-JsonFileScript $restoreScript @('-Query','continue','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-Json')
      $set.exitCode | Should Be 0
      $observe.exitCode | Should Be 0
      $restore.exitCode | Should Be 0
      $restore.value.instructionAnchor.latestUserInstruction | Should Be 'answer the inserted status question first; then return to the main line'
      $restore.value.resumeReceipt.state | Should Be 'reconcile_newest_instruction_preserve_assistant_progress'
      $restore.value.resumeReceipt.assistantProgress.lastConfirmedSentence | Should Be 'old step is complete'
      $restore.value.executionResolution.actionAuthorization | Should Be 'withheld'
      $restore.value.nextAction | Should Match '^Reconcile the latest user instruction'
      $restore.value.resumeReceipt.nextAction | Should BeNullOrEmpty
      $restore.value.executionResolution.nextAction | Should Match '^Reconcile the latest user instruction'
    } finally {
      if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
    }
  }

  It 'makes repeated identical compaction idempotent and does not duplicate archive notes' {
    $stateRoot = Join-Path $TestDrive 'compact-idempotent'
    $taskId = 'task-stage2-compact-idempotent'
    $workspaceKey = 'ws-stage2-compact-idempotent-4242424242'
    $sessionKey = 'sid-stage2-compact-idempotent-42424242'
    $set = Invoke-ContractMatrix @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main','-InstructionMode','continue','-LatestUserInstruction','continue the approved main line','-CurrentPhase','P2','-CurrentStep','checkpoint is ready','-LastConfirmedSentence','checkpoint is ready','-LastConfirmedSource','assistant_commitment','-NextAction','run the verified next action','-PendingSteps','run the verified next action','-StateRoot',$stateRoot,'-Json')
    $set.exitCode | Should Be 0
    $oldState = $env:SUPER_BRAIN_STATE_ROOT
    $oldArchive = $env:SUPER_BRAIN_ARCHIVE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $archive = Join-Path $TestDrive 'archive'
      $env:SUPER_BRAIN_ARCHIVE_ROOT = $archive
      $first = Invoke-JsonFileScript $compactScript @('-InputText','verified: checkpoint is ready`nNext: run the verified next action','-Title','Stage 2 compact','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionId',$sessionKey,'-Json')
      $second = Invoke-JsonFileScript $compactScript @('-InputText','verified: checkpoint is ready`nNext: run the verified next action','-Title','Stage 2 compact','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionId',$sessionKey,'-Json')
      $taskArchive = Get-ChildItem -LiteralPath (Join-Path $archive 'historical-session-notes') -Recurse -Filter '*.json' -ErrorAction SilentlyContinue
      $first.exitCode | Should Be 0
      $second.exitCode | Should Be 0
      $first.value.ok | Should Be $true
      $second.value.ok | Should Be $true
      $second.value.idempotent | Should Be $true
      $second.value.noteId | Should Be $first.value.noteId
      @($taskArchive).Count | Should Be 1
      $second.value.recoveryCheckpoint.checkpointHash | Should Be $first.value.recoveryCheckpoint.checkpointHash
    } finally {
      if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
      if ($null -eq $oldArchive) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $oldArchive }
    }
  }

  It 'fails closed when a scoped recovery checkpoint is tampered' {
    $stateRoot = Join-Path $TestDrive 'checkpoint-tamper'
    $taskId = 'task-stage2-checkpoint-tamper'
    $workspaceKey = 'ws-stage2-checkpoint-tamper-4242424242'
    $sessionKey = 'sid-stage2-checkpoint-tamper-42424242'
    $write = Invoke-JsonFileScript $checkpointScript @('-Action','Write','-StateRoot',$stateRoot,'-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-CurrentPhase','P2','-CurrentStep','verified step','-NextAction','continue verified step','-Json')
    $write.exitCode | Should Be 0
    $path = [string]$write.value.path
    $tampered = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $tampered.nextAction = 'replay an old action'
    [IO.File]::WriteAllText($path,($tampered | ConvertTo-Json -Depth 16 -Compress),[Text.UTF8Encoding]::new($false))
    $validate = Invoke-JsonFileScript $checkpointScript @('-Action','Validate','-StateRoot',$stateRoot,'-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-Json')
    $validate.exitCode | Should Be 1
    $validate.value.code | Should Be 'RECOVERY_CHECKPOINT_INVALID'
  }

  It 'does not expose or execute a foreign-session checkpoint' {
    $stateRoot = Join-Path $TestDrive 'foreign-checkpoint'
    $taskId = 'task-stage2-foreign-checkpoint'
    $workspaceKey = 'ws-stage2-foreign-checkpoint-4242424242'
    $ownerSession = 'sid-stage2-foreign-owner-42424242'
    $foreignSession = 'sid-stage2-foreign-reader-42424242'
    $write = Invoke-JsonFileScript $checkpointScript @('-Action','Write','-StateRoot',$stateRoot,'-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$ownerSession,'-CurrentPhase','P2','-CurrentStep','private step','-NextAction','private action','-Json')
    $write.exitCode | Should Be 0
    $oldState = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $restore = Invoke-JsonFileScript $restoreScript @('-Query','continue','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$foreignSession,'-Json')
      $restore.exitCode | Should Be 0
      ($restore.text) | Should Not Match 'private action|private step'
      $restore.value.recoveryCheckpointLookup.available | Should Be $false
    } finally {
      if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
    }
  }

  It 'does not reactivate a closed phase or its old action' {
    $stateRoot = Join-Path $TestDrive 'closed-phase'
    $taskId = 'task-stage2-closed-phase'
    $workspaceKey = 'ws-stage2-closed-phase-424242424242'
    $sessionKey = 'sid-stage2-closed-phase-42424242'
    $set = Invoke-ContractMatrix @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','closed','-InstructionMode','continue','-LatestUserInstruction','phase closed; keep history only','-CurrentPhase','P1 complete','-CurrentStep','verification recorded','-LastConfirmedSentence','P1 complete and verified','-LastConfirmedSource','assistant_commitment','-NextAction','No automatic action: phase is complete.','-StateRoot',$stateRoot,'-Json')
    $set.exitCode | Should Be 0
    $oldState = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $restore = Invoke-JsonFileScript $restoreScript @('-Query','continue','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-Json')
      $restore.exitCode | Should Be 0
      $restore.value.resumeReceipt.nextAction | Should Match '^No automatic action:'
      $restore.value.executionResolution.actionAuthorization | Should Be 'allowed'
      @($restore.value.resumeReceipt.pendingSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count | Should Be 0
    } finally {
      if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
    }
  }
}
