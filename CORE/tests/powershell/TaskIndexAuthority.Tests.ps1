$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$indexScript = Join-Path $root 'scripts\task-index.ps1'
$memoryScoutScript = Join-Path $root 'scripts\memory-scout.ps1'
$taskRegisterScript = Join-Path $root 'scripts\task-register.ps1'
. (Join-Path $root 'scripts\common.ps1')

function Invoke-AuthorityContract([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $contractScript @Arguments 2>$null)
  return [pscustomobject]@{
    exitCode = $LASTEXITCODE
    value = (($raw -join "`n") | ConvertFrom-Json)
  }
}

Describe 'Task index execution-contract authority' {
  It 'suppresses a stale shared task card when an active contract owns the same task' {
    $stateRoot = Join-Path $TestDrive 'contract-authority'
    $workspaceKey = 'ws-task-index-authority-20260723'
    $taskId = 'task-index-authority'
    $contract = Invoke-AuthorityContract @(
      '-Action','Set',
      '-TaskId',$taskId,
      '-WorkspaceKey',$workspaceKey,
      '-FocusId','phase-eight',
      '-FocusLabel','Phase 8 evaluation',
      '-NextAction','use the current contract action',
      '-CurrentPhase','Phase 8',
      '-CurrentStep','sealed source is ready',
      '-StateRoot',$stateRoot,
      '-Json'
    )
    $contract.exitCode | Should Be 0

    $cardPath = Join-Path $stateRoot ('shared\tasks\active\' + $taskId + '.task.json')
    $cardDirectory = Split-Path -Parent $cardPath
    New-Item -ItemType Directory -Force -Path $cardDirectory | Out-Null
    $staleCard = [pscustomobject]@{
      schema = 'super-brain.task-card.v1'
      taskId = $taskId
      taskName = 'stale task card'
      agentId = 'zcodeid-default'
      agentName = 'super-memory-brain'
      platform = 'zcode'
      workspaceKey = $workspaceKey
      status = 'active'
      goal = 'obsolete checkpoint goal'
      currentPhase = 'Phase 1'
      currentStep = 'obsolete checkpoint step'
      nextAction = 'repeat obsolete work'
      completedSteps = @()
      pendingSteps = @('obsolete work')
      blockers = @()
      evidence = @()
      updatedAt = '2026-07-20 00:00:00'
    }
    [IO.File]::WriteAllText($cardPath,($staleCard | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

    $previousRoot = $env:SUPER_BRAIN_STATE_ROOT
    $previousWorkspace = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $indexScript -Json 2>$null)
      $exitCode = $LASTEXITCODE
      $index = (($raw -join "`n") | ConvertFrom-Json)
      $scoutRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $memoryScoutScript -Json 2>$null)
      $scoutExitCode = $LASTEXITCODE
      $scout = (($scoutRaw -join "`n") | ConvertFrom-Json)
    } finally {
      if ($null -eq $previousRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousRoot }
      if ($null -eq $previousWorkspace) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $previousWorkspace }
    }

    $exitCode | Should Be 0
    $matches = @($index.current | Where-Object { $_.taskId -eq $taskId })
    $matches.Count | Should Be 1
    $matches[0].source | Should Be 'execution-contract'
    $matches[0].agentName | Should Be 'super-memory-brain'
    $matches[0].agentId | Should Be 'super-brain-control-plane'
    $matches[0].platform | Should Be 'super-brain'
    $matches[0].currentStep | Should Be 'sealed source is ready'
    $matches[0].nextAction | Should Be 'use the current contract action'
    @($index.all | Where-Object { $_.taskId -eq $taskId -and $_.source -eq 'shared/tasks/active' }).Count | Should Be 0
    $scoutExitCode | Should Be 0
    @($scout.cards | Where-Object { $_.kind -eq 'current_task' }).Count | Should Be 1
    ($scout.cards | Where-Object { $_.kind -eq 'current_task' } | Select-Object -First 1).path | Should Match 'execution-contracts'
  }

  It 'writes task-register projections to the TaskStateStore canonical task path' {
    $stateRoot = Join-Path $TestDrive 'task-register-canonical-path'
    $workspaceKey = 'ws-task-register-canonical-20260723'
    $taskId = 'task-register-canonical'
    $previousRoot = $env:SUPER_BRAIN_STATE_ROOT
    $previousWorkspace = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $taskRegisterScript -TaskId $taskId -TaskName 'canonical task registration' -SessionId 'session-task-register-canonical' -WorkspaceKey $workspaceKey -CurrentPhase 'Phase 8' -CurrentStep 'canonical projection' -NextAction 'retain the current task card' -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      if ($null -eq $previousRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousRoot }
      if ($null -eq $previousWorkspace) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $previousWorkspace }
    }

    $result = (($raw -join "`n") | ConvertFrom-Json)
    $expectedPath = Get-SuperBrainCanonicalTaskPath (Join-Path $stateRoot 'shared\tasks\active') $taskId '.task.json'
    $exitCode | Should Be 0
    $result.wrote.task | Should Be $expectedPath
    Test-Path -LiteralPath $expectedPath | Should Be $true
    (Get-Content -LiteralPath $expectedPath -Raw -Encoding UTF8 | ConvertFrom-Json).currentPhase | Should Be 'Phase 8'
  }
}
