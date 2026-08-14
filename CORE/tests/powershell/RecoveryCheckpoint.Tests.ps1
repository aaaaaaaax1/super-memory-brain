$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$checkpointScript = Join-Path $root 'scripts\recovery-checkpoint.ps1'
$restoreScript = Join-Path $root 'scripts\session-restore.ps1'
$compactScript = Join-Path $root 'scripts\session-compact.ps1'

function Invoke-Checkpoint([string]$Action,[string]$StateRoot,[string[]]$Extra=@()) {
  $base = @('-Action',$Action,'-StateRoot',$StateRoot,'-TaskId','task-recovery-checkpoint','-WorkspaceKey','ws-recovery-checkpoint-424242424242424242424242','-SessionKey','sid-recovery-checkpoint-424242424242424242','-Json')
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checkpointScript @base @Extra 2>&1)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text | ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'Atomic recovery checkpoint' {
  It 'commits, validates, and exposes one scoped checkpoint' {
    $state = Join-Path $TestDrive 'recovery-checkpoint'
    $write = Invoke-Checkpoint 'Write' $state @('-ContractRevision','9','-CurrentPhase','Stage 2','-CurrentStep','checkpoint write','-NextAction','restore exact state')
    $write.exitCode | Should Be 0
    $write.value.status | Should Be 'committed'
    $write.value.checkpoint.checkpointHash | Should Match '^[a-f0-9]{64}$'
    $validate = Invoke-Checkpoint 'Validate' $state
    $validate.exitCode | Should Be 0
    $validate.value.code | Should Be 'RECOVERY_CHECKPOINT_CURRENT'
    $validate.value.checkpoint.checkpointRevision | Should Be 1
    $files = @(Get-ChildItem -LiteralPath (Join-Path $state 'workspace\runtime-state\recovery-checkpoints') -Filter '*.json')
    $files.Count | Should Be 1
  }

  It 'fails closed on a compare-and-swap revision mismatch' {
    $state = Join-Path $TestDrive 'recovery-cas'
    $write = Invoke-Checkpoint 'Write' $state
    $write.exitCode | Should Be 0
    $retry = Invoke-Checkpoint 'Write' $state @('-ExpectedRevision','0')
    $retry.exitCode | Should Be 1
    $retry.value.code | Should Be 'RECOVERY_CHECKPOINT_CAS_MISMATCH'
  }

  It 'writes a checkpoint before historical compaction and restores it by scope' {
    $state = Join-Path $TestDrive 'recovery-compact'
    $archive = Join-Path $TestDrive 'archive'
    New-Item -ItemType Directory -Force -Path $archive | Out-Null
    $oldState = $env:SUPER_BRAIN_STATE_ROOT
    $oldArchive = $env:SUPER_BRAIN_ARCHIVE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $state
      $env:SUPER_BRAIN_ARCHIVE_ROOT = $archive
      $compactRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $compactScript -InputText 'compact a bounded historical note' -TaskId 'task-recovery-checkpoint' -WorkspaceKey 'ws-recovery-checkpoint-424242424242424242424242' -SessionId 'sid-recovery-checkpoint-424242424242424242' -Json 2>&1)
      $compactCode = $LASTEXITCODE
      $compact = (($compactRaw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
      $compactCode | Should Be 0
      $compact.recoveryCheckpoint.checkpointId | Should Match '^rc-'
      $restoreRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restoreScript -TaskId 'task-recovery-checkpoint' -WorkspaceKey 'ws-recovery-checkpoint-424242424242424242424242' -SessionId 'sid-recovery-checkpoint-424242424242424242' -Json 2>&1)
      $restore = (($restoreRaw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
      $restore.recoveryCheckpointLookup.code | Should Be 'RECOVERY_CHECKPOINT_CURRENT'
      $restore.recoveryCheckpoint.checkpointId | Should Be $compact.recoveryCheckpoint.checkpointId
      $restore.resumeReceipt.completedHistoryIsCurrent | Should Be $false
    } finally {
      if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
      if ($null -eq $oldArchive) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $oldArchive }
    }
  }
}
