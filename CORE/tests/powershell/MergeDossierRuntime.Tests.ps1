$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$nativeHook = Join-Path $root 'runtime\codex_prompt_hook.py'

function Invoke-MergeContract([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $contractScript @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{
    exitCode = $exitCode
    value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
    text = $text
  }
}

Describe 'Merge dossier runtime handoff' {
  It 'wakes a unique retained branch into merge review without loading its full dossier into the hot path' {
    $stateRoot = Join-Path $TestDrive 'merge-dossier-runtime'
    $workspaceKey = 'ws-fa1010101010101010101010'
    $sessionKey = 'sid-fa1010101010101010101010'
    $taskId = 'task-merge-dossier-runtime'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      (Invoke-MergeContract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-FocusLabel','Main line','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
      (Invoke-MergeContract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','ui-backend','-FocusLabel','UI backend','-TopicKeys','ui-backend','-NextAction','finish UI backend','-Evidence','artifact inspected','-VerificationResults','manual verification passed','-RetainForMerge','-ArtifactRefs','prototype/ui.html','-InterfaceContracts','backend API v1','-Dependencies','backend service','-VerificationSteps','verify UI API mapping','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
      $resumed = Invoke-MergeContract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','UI backend verified','-StateRoot',$stateRoot,'-Json')
      $resumed.exitCode | Should Be 0
      $intent = $resumed.value.mergeIntents[0]

      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $hookRaw = @(& python -B $nativeHook --package-root $root --test-prompt 'ui-backend merge' --test-session-id $sessionKey 2>$null)
      $hook = (($hookRaw -join "`n") | ConvertFrom-Json)
      $context = [string]$hook.hookSpecificOutput.additionalContext
      $intentPattern = [regex]::Escape([string]$intent.mergeIntentId)
      $context.Length | Should BeLessThan 3500
      $context | Should Match 'PrepareMerge-before-integration'
      $context | Should Match $intentPattern
      $context | Should Not Match 'prototype/ui.html'

      $observed = Invoke-MergeContract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')
      $observed.exitCode | Should Be 0
      $observed.value.latestMessageClassification.recommendedInstructionMode | Should Be 'merge_review'
      $observed.value.latestMessageClassification.mergeIntentId | Should Be $intent.mergeIntentId
      $observed.value.needsReconciliation | Should Be $true

      $reconciled = Invoke-MergeContract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','main-line','-NextAction','prepare the retained branch merge','-StateRoot',$stateRoot,'-Json')
      $reconciled.exitCode | Should Be 0
      $prepared = Invoke-MergeContract @('-Action','PrepareMerge','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-MergeIntentId',$intent.mergeIntentId,'-StateRoot',$stateRoot,'-Json')
      $prepared.exitCode | Should Be 0
      $prepared.value.mergeIntent.noReimplementation | Should Be $true
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey
    }
  }
}
