$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$CheckpointScript = Join-Path $Root 'scripts\checkpoint-writer.ps1'
$TaskStateStoreScript = Join-Path $Root 'scripts\task-state-store.ps1'

. (Join-Path $Root 'scripts\common.ps1')

function Invoke-CheckpointTransactionScript([string]$ScriptPath,[string[]]$Arguments,[string]$StateRoot) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue }
    else { $env:SUPER_BRAIN_STATE_ROOT = $previous }
  }
  $text = ($raw -join "`n").Trim()
  return [pscustomobject]@{ exitCode=$exitCode; value=if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}; text=$text }
}

Describe 'Checkpoint start transaction' {
  It 'replaces only a legacy unscoped compatibility pointer when the approved start uses maintenance override' {
    $stateRoot = Join-Path $TestDrive 'legacy-pointer'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-current-pointer'
    $workspaceKey = 'ws-current-pointer-20260814'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    [IO.File]::WriteAllText(
      (Join-Path $workspace 'active-checkpoint.json'),
      (([pscustomobject]@{ taskId='legacy-zcode-task'; status='active'; agentId='zcodeid-default'; platform='zcode' }) | ConvertTo-Json -Depth 6),
      [Text.UTF8Encoding]::new($false)
    )

    $started = Invoke-CheckpointTransactionScript $CheckpointScript @(
      '-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,
      '-TaskName','Current pointer','-CurrentStep','replace legacy pointer safely',
      '-PendingSteps','verify current pointer','-MaintenanceOverride',
      '-MaintenanceReason','Replace only the stale unscoped compatibility pointer for the approved current task.','-Json'
    ) $stateRoot

    $started.exitCode | Should Be 0
    $started.value.compatibilityPointerChanged | Should Be $true
    $pointer = Get-Content -LiteralPath (Join-Path $workspace 'active-checkpoint.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $pointer.taskId | Should Be $taskId
    $pointer.workspaceKey | Should Be (Get-SuperBrainWorkspaceKey $workspaceKey)
  }

  It 'commits the active checkpoint and task card in one TaskStateStore revision' {
    $stateRoot = Join-Path $TestDrive 'start'
    $workspace = Join-Path $stateRoot 'workspace'
    $shared = Join-Path $stateRoot 'shared'
    $taskId = 'task-start-txn'
    $workspaceKey = 'ws-start-txn-20260726'
    $started = Invoke-CheckpointTransactionScript $CheckpointScript @('-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Start transaction','-CurrentStep','write both state surfaces','-PendingSteps','verify active bundle','-Json') $stateRoot
    $started.exitCode | Should Be 0
    $started.value.taskStateRevision | Should Be 1
    $started.value.taskStateTransactionId.Length | Should BeGreaterThan 0

    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.revision | Should Be 1
    $projection.lifecycle.status | Should Be 'active'
    $projection.entities.checkpoint.status | Should Be 'active'
    $projection.entities.task_card.status | Should Be 'active'
    Test-Path -LiteralPath $projection.entities.checkpoint.path | Should Be $true
    Test-Path -LiteralPath $projection.entities.task_card.path | Should Be $true
    $events = @(Get-Content -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    @($events).Count | Should Be 2
    @($events | ForEach-Object { $_.transactionKind } | Select-Object -Unique) | Should Be @('active_task_bundle')
  }

  It 'reconciles a start interrupted after materialization without splitting task state versions' {
    $stateRoot = Join-Path $TestDrive 'recover'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-start-recover'
    $workspaceKey = 'ws-start-recover-20260726'
    $interrupted = Invoke-CheckpointTransactionScript $CheckpointScript @('-Action','Start','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TaskName','Recover start transaction','-CurrentStep','reconcile prepared state','-PendingSteps','finish recovery','-FaultPoint','after_materialize','-Json') $stateRoot
    $interrupted.exitCode | Should Be 1

    $reconcile = Invoke-CheckpointTransactionScript $TaskStateStoreScript @('-Action','Reconcile','-Apply','-Json') $stateRoot
    $reconcile.exitCode | Should Be 0
    $reconcile.value.recoveredCount | Should Be 1
    $reconcile.value.blockedCount | Should Be 0

    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.revision | Should Be 1
    $projection.entities.checkpoint.status | Should Be 'active'
    $projection.entities.task_card.status | Should Be 'active'
    Test-Path -LiteralPath $projection.entities.checkpoint.path | Should Be $true
    Test-Path -LiteralPath $projection.entities.task_card.path | Should Be $true
  }
}
