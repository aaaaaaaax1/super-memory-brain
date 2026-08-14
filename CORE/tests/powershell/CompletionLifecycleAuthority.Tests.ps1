$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\common.ps1')

function Write-LifecycleJson([string]$Path,[object]$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Invoke-LifecycleGuard([string]$StateRoot,[string]$TaskId) {
  $previous = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\completion-guard.ps1') -TaskId $TaskId -AllowPrivacyRisk -AllowActiveCheckpoint -Json 2>$null)
    $exitCode = $LASTEXITCODE
    $value = ConvertFrom-SuperBrainJsonOutput (($raw -join "`n")) 'completion lifecycle guard test'
    return [pscustomobject]@{ exitCode=$exitCode; value=$value }
  } finally {
    $env:SUPER_BRAIN_STATE_ROOT = $previous
  }
}

Describe 'Completion lifecycle authority' {
  It 'requires a completed canonical projection and an empty task WAL pending set' {
    $stateRoot = Join-Path $TestDrive 'guard-lifecycle'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-guard-lifecycle'
    $workspaceKey = 'ws-111111111111111111111111'
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\events') $taskId '.jsonl'
    $driftPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\runtime-drift-checkpoints') $taskId '.json'
    $activeProjection = [pscustomobject]@{
      schema='super-brain.task-state-projection.v2'; taskId=$taskId; revision=3
      entities=[pscustomobject]@{
        context=[pscustomobject]@{status='active'}
        checkpoint=[pscustomobject]@{status='active'}
        task_card=[pscustomobject]@{status='active'}
      }
      lifecycle=[pscustomobject]@{status='active';workspaceKey=$workspaceKey}
    }
    Write-LifecycleJson $projectionPath $activeProjection
    $eventParent = Split-Path -Parent $eventPath
    if (-not (Test-Path -LiteralPath $eventParent)) { New-Item -ItemType Directory -Force -Path $eventParent | Out-Null }
    $prepared = [pscustomobject]@{schema='super-brain.task-state-event.v2';phase='prepared';transactionId='tx-pending';taskId=$taskId}
    [IO.File]::WriteAllText($eventPath,(($prepared | ConvertTo-Json -Compress) + "`n"),[Text.UTF8Encoding]::new($false))
    Write-LifecycleJson (Join-Path $workspace 'last-runtime-drift-checkpoint.json') ([pscustomobject]@{ok=$false;taskId='foreign-task';status='drift_detected';unresolvedDrift=$true;violations=@('foreign')})
    Write-LifecycleJson $driftPath ([pscustomobject]@{ok=$true;taskId=$taskId;workspaceKey=$workspaceKey;status='clean';unresolvedDrift=$false;violations=@();checkedAt=(Get-Date).ToString('o')})

    $active = Invoke-LifecycleGuard $stateRoot $taskId
    (@($active.value.checks | Where-Object { $_.name -eq 'task-state-projection' })[0].ok) | Should Be $true
    (@($active.value.checks | Where-Object { $_.name -eq 'task-state-transaction' })[0].ok) | Should Be $false
    (@($active.value.checks | Where-Object { $_.name -eq 'task-state-lifecycle' })[0].ok) | Should Be $false
    (@($active.value.checks | Where-Object { $_.name -eq 'runtime-drift-checkpoint' })[0].ok) | Should Be $true

    $completedProjection = [pscustomobject]@{
      schema='super-brain.task-state-projection.v2'; taskId=$taskId; revision=4
      entities=[pscustomobject]@{
        context=$null
        checkpoint=[pscustomobject]@{status='completed'}
        task_card=[pscustomobject]@{status='completed'}
      }
      lifecycle=[pscustomobject]@{status='completed';workspaceKey=$workspaceKey}
    }
    Write-LifecycleJson $projectionPath $completedProjection
    $committed = [pscustomobject]@{schema='super-brain.task-state-event.v2';phase='committed';transactionId='tx-pending';taskId=$taskId}
    [IO.File]::AppendAllText($eventPath,(($committed | ConvertTo-Json -Compress) + "`n"),[Text.UTF8Encoding]::new($false))
    $completed = Invoke-LifecycleGuard $stateRoot $taskId
    (@($completed.value.checks | Where-Object { $_.name -eq 'task-state-transaction' })[0].ok) | Should Be $true
    (@($completed.value.checks | Where-Object { $_.name -eq 'task-state-lifecycle' })[0].ok) | Should Be $true
  }

  It 'rejects terminal task-register status before any state write' {
    foreach ($status in @('completed','verified')) {
      $stateRoot = Join-Path $TestDrive ("task-register-" + $status)
      $previous = $env:SUPER_BRAIN_STATE_ROOT
      try {
        $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
        $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\task-register.ps1') -TaskId 'task-terminal-register' -TaskName 'terminal register' -Status $status -SessionId 'session-terminal' -Json 2>$null)
        $exitCode = $LASTEXITCODE
      } finally {
        $env:SUPER_BRAIN_STATE_ROOT = $previous
      }
      $result = (($raw -join "`n") | ConvertFrom-Json)
      $exitCode | Should Be 1
      $result.errorCode | Should Be 'TASK_REGISTER_TERMINAL_STATUS_REQUIRES_COMPLETION_TRANSACTION'
      Test-Path -LiteralPath (Join-Path $stateRoot 'shared\agents') | Should Be $false
      Test-Path -LiteralPath (Join-Path $stateRoot 'shared\sessions') | Should Be $false
      Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\task-state-store') | Should Be $false
    }
  }
}
