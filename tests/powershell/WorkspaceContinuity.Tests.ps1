$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Contract = Join-Path $Root 'scripts\execution-contract.ps1'
$SessionRestore = Join-Path $Root 'scripts\session-restore.ps1'
$SnapshotWriter = Join-Path $Root 'scripts\status-snapshot-writer.ps1'

. (Join-Path $Root 'scripts\common.ps1')

function Write-WorkspaceTestJson([string]$Path,[object]$Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Invoke-WorkspaceJsonScript([string]$ScriptPath,[string[]]$Arguments,[string]$StateRoot) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n")
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text|ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'Workspace-scoped continuation consumers' {
  It 'never accepts a foreign same-task checkpoint and prefers an exact workspace candidate' {
    $stateRoot = Join-Path $TestDrive 'checkpoint-selector'
    $workspace = Join-Path $stateRoot 'workspace'
    $checkpointRoot = Join-Path $workspace 'runtime-state\checkpoints\active'
    $taskId = 'task-shared-id'
    $workspaceA = 'ws-a11111111111111111111111'
    $workspaceB = 'ws-b22222222222222222222222'
    $context = [pscustomobject]@{status='active';stale=$false;taskId=$taskId;workspaceKey=$workspaceA;expiresAt=(Get-Date).AddHours(1).ToString('o')}
    $foreign = [pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceB;currentStep='foreign step';nextAction='foreign action'}
    Write-WorkspaceTestJson (Get-SuperBrainCanonicalTaskPath $checkpointRoot $taskId '.json') $foreign
    Write-WorkspaceTestJson (Join-Path $workspace 'active-checkpoint.json') $foreign

    $rejected = Get-SuperBrainRelevantCheckpoint $workspace $context $workspaceA $taskId
    $rejected.state | Should Be 'foreign_workspace'
    $rejected.contextState | Should Be 'relevant'
    $rejected.checkpoint | Should BeNullOrEmpty

    $exact = [pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceA;currentStep='exact step';nextAction='exact action'}
    Write-WorkspaceTestJson (Join-Path $workspace 'active-checkpoint.json') $exact
    $selected = Get-SuperBrainRelevantCheckpoint $workspace $context $workspaceA $taskId
    $selected.state | Should Be 'relevant'
    $selected.checkpoint.currentStep | Should Be 'exact step'
    $selected.checkpoint.nextAction | Should Be 'exact action'
  }

  It 'clamps restore budgets and does not emit foreign same-task actions' {
    $stateRoot = Join-Path $TestDrive 'bounded-restore'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-shared-restore'
    $workspaceA = 'ws-a33333333333333333333333'
    $workspaceB = 'ws-b44444444444444444444444'
    $foreignAction = 'FOREIGN_RESTORE_ACTION_MUST_NOT_APPEAR'
    Write-WorkspaceTestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{status='active';stale=$false;taskId=$taskId;workspaceKey=$workspaceB;expiresAt=(Get-Date).AddHours(1).ToString('o');nextAction=$foreignAction})
    Write-WorkspaceTestJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceB;currentStep='foreign step';nextAction=$foreignAction})
    Write-WorkspaceTestJson (Join-Path $workspace 'status-card.json') ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceB;nextAction=$foreignAction})
    Write-WorkspaceTestJson (Join-Path $workspace 'last-status-snapshot.json') ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceB;nextAction=$foreignAction})

    $restore = Invoke-WorkspaceJsonScript $SessionRestore @('-TaskId',$taskId,'-WorkspaceKey',$workspaceA,'-MaxTokens','999999','-TopK','999','-Json') $stateRoot
    $restore.exitCode | Should Be 0
    $restore.value.tokenBudget | Should Be 4000
    $restore.value.topK | Should Be 8
    $restore.value.checkpointSelection.state | Should Be 'foreign_workspace'
    $restore.value.activeCheckpoint | Should BeNullOrEmpty
    $restore.value.recoveryPoint.nextAction | Should BeNullOrEmpty
    $restore.text.Contains($foreignAction) | Should Be $false
    $restore.text.Length -le [int]$restore.value.packetLimits.maxChars | Should Be $true
  }

  It 'excludes foreign task graph ledger and continuity data from snapshots' {
    $stateRoot = Join-Path $TestDrive 'snapshot-isolation'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-shared-snapshot'
    $workspaceA = 'ws-a55555555555555555555555'
    $workspaceB = 'ws-b66666666666666666666666'
    $foreignMarker = 'FOREIGN_SNAPSHOT_DATA_MUST_NOT_APPEAR'
    $version = [string](Get-SuperBrainManifest $Root).version
    Write-WorkspaceTestJson (Join-Path $workspace 'last-verify-package.json') ([pscustomobject]@{ok=$true;version=$version;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')})
    Write-WorkspaceTestJson (Join-Path $workspace 'last-hot-refresh.json') ([pscustomobject]@{ok=$true;version=$version;checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')})
    Write-WorkspaceTestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{status='active';stale=$false;taskId=$taskId;workspaceKey=$workspaceA;acceptedGoal='exact workspace goal';expiresAt=(Get-Date).AddHours(1).ToString('o')})
    Write-WorkspaceTestJson (Join-Path $workspace 'task-graph.json') ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceB;goal=$foreignMarker;status='active'})
    Write-WorkspaceTestJson (Join-Path $workspace 'step-ledger.json') ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceB;openSteps=@([pscustomobject]@{step=$foreignMarker});completedSteps=@($foreignMarker);blockedSteps=@($foreignMarker);skippedSteps=@()})
    Write-WorkspaceTestJson (Join-Path $workspace 'last-project-continuity.json') ([pscustomobject]@{taskId=$taskId;workspaceKey=$workspaceB;nextAction=$foreignMarker;findingCounts=[pscustomobject]@{candidate=99}})

    $snapshot = Invoke-WorkspaceJsonScript $SnapshotWriter @('-WorkspaceKey',$workspaceA,'-Json') $stateRoot
    $snapshot.exitCode | Should Be 0
    $snapshot.value.workspaceKey | Should Be $workspaceA
    $snapshot.value.continuity.taskId | Should Be $taskId
    $snapshot.value.continuity.goal | Should Be 'exact workspace goal'
    $snapshot.value.continuity.openStepCount | Should Be 0
    $snapshot.value.continuity.completedCount | Should Be 0
    $snapshot.value.continuity.candidateFindings | Should Be 0
    $snapshot.value.continuity.nextAction | Should BeNullOrEmpty
    $snapshot.text.Contains($foreignMarker) | Should Be $false
  }

  It 'restores a parent-return plan while keeping the packet bounded' {
    $stateRoot = Join-Path $TestDrive 'parent-return-restore'
    $workspaceKey = 'ws-a77777777777777777777777'
    $taskId = 'task-parent-return-restore'
    @(& $Contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -FocusId 'main-line' -NextAction 'resume exact main action' -StateRoot $stateRoot -NoExit -Json) | Out-Null
    @(& $Contract -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -InstructionMode side_branch -FocusId 'side-line' -NextAction 'finish side line' -StateRoot $stateRoot -NoExit -Json) | Out-Null
    @(& $Contract -Action ResumeParent -TaskId $taskId -WorkspaceKey $workspaceKey -BranchStatus completed -CompletionEvidence 'side verified' -StateRoot $stateRoot -NoExit -Json) | Out-Null

    $restore = Invoke-WorkspaceJsonScript $SessionRestore @('-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-MaxTokens','999999','-TopK','999','-Json') $stateRoot
    $restore.exitCode | Should Be 0
    $restore.value.recoveryPoint.source | Should Be 'execution_contract_plan'
    $restore.value.recoveryPoint.focusId | Should Be 'main-line'
    $restore.value.recoveryPoint.nextAction | Should Be 'resume exact main action'
    $restore.value.recoveryPoint.planAuthorized | Should Be $true
    $restore.value.tokenBudget | Should Be 4000
    $restore.value.topK | Should Be 8
    $restore.text.Length -le [int]$restore.value.packetLimits.maxChars | Should Be $true
  }
}
