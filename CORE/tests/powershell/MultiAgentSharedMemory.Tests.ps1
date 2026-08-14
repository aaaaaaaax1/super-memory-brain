$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$taskRegisterScript = Join-Path $root 'scripts\task-register.ps1'
$checkpointScript = Join-Path $root 'scripts\checkpoint-writer.ps1'
$contextScript = Join-Path $root 'scripts\current-task-context.ps1'
$taskIndexScript = Join-Path $root 'scripts\task-index.ps1'
$autonomousScript = Join-Path $root 'scripts\autonomous-executor.ps1'
. (Join-Path $root 'scripts\common.ps1')

function Invoke-SharedStateScript([string]$StateRoot,[string]$WorkspaceKey,[string]$Script,[string[]]$Arguments) {
  $oldState = $env:SUPER_BRAIN_STATE_ROOT
  $oldWorkspace = $env:SUPER_BRAIN_WORKSPACE_KEY
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $env:SUPER_BRAIN_WORKSPACE_KEY = $WorkspaceKey
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
    if ($null -eq $oldWorkspace) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspace }
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ exitCode=$exitCode; value=if($text){$text|ConvertFrom-Json}else{$null}; text=$text }
}

Describe 'Super Brain shared identity and scope isolation' {
  It 'uses the Super Brain control-plane identity and keeps same-named sessions scoped by workspace' {
    $stateRoot = Join-Path $TestDrive 'shared-identity'
    $workspaceA = 'ws-aaaaaaaaaaaaaaaaaaaaaaaa'
    $workspaceB = 'ws-bbbbbbbbbbbbbbbbbbbbbbbb'
    $sessionId = 'sid-shared-name-42424242424242'

    $taskA = Invoke-SharedStateScript $stateRoot $workspaceA $taskRegisterScript @('-TaskId','task-workspace-a','-TaskName','Workspace A','-SessionId',$sessionId,'-WorkspaceKey',$workspaceA,'-CurrentStep','step a','-NextAction','next a','-Json')
    $taskB = Invoke-SharedStateScript $stateRoot $workspaceB $taskRegisterScript @('-TaskId','task-workspace-b','-TaskName','Workspace B','-SessionId',$sessionId,'-WorkspaceKey',$workspaceB,'-CurrentStep','step b','-NextAction','next b','-Json')

    $taskA.exitCode | Should Be 0
    $taskB.exitCode | Should Be 0
    foreach ($task in @($taskA.value,$taskB.value)) {
      $task.agent | Should Be 'super-memory-brain'
      $task.agentId | Should Be 'super-brain-control-plane'
      $task.platform | Should Be 'super-brain'
    }

    $agentPath = Join-Path $stateRoot 'shared\agents\super-brain-control-plane.agent.json'
    Test-Path -LiteralPath $agentPath | Should Be $true
    $agentCard = Get-Content -LiteralPath $agentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $agentCard.agentName | Should Be 'super-memory-brain'
    $agentCard.agentId | Should Be 'super-brain-control-plane'
    $agentCard.platform | Should Be 'super-brain'
    $agentCard.PSObject.Properties['privateMemoryRoot'] | Should BeNullOrEmpty
    Test-Path -LiteralPath (Join-Path $stateRoot 'shared\agents\zcodeid-default.agent.json') | Should Be $false

    $sessionFiles = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'shared\sessions') -Filter '*.session.json' -File)
    $sessionFiles.Count | Should Be 2
    $sessions = @($sessionFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json })
    @($sessions | Where-Object { $_.workspaceKey -eq $workspaceA -and @($_.currentTaskIds) -contains 'task-workspace-a' }).Count | Should Be 1
    @($sessions | Where-Object { $_.workspaceKey -eq $workspaceB -and @($_.currentTaskIds) -contains 'task-workspace-b' }).Count | Should Be 1
    @($sessions | Where-Object { $_.workspaceKey -eq $workspaceA -and @($_.currentTaskIds) -contains 'task-workspace-b' }).Count | Should Be 0

    $indexA = Invoke-SharedStateScript $stateRoot $workspaceA $taskIndexScript @('-WorkspaceKey',$workspaceA,'-Json')
    $indexB = Invoke-SharedStateScript $stateRoot $workspaceB $taskIndexScript @('-WorkspaceKey',$workspaceB,'-Json')
    $indexA.exitCode | Should Be 0
    $indexB.exitCode | Should Be 0
    @($indexA.value.current | ForEach-Object { $_.taskId }) | Should Be @('task-workspace-a')
    @($indexB.value.current | ForEach-Object { $_.taskId }) | Should Be @('task-workspace-b')
  }

  It 'uses the same control-plane defaults for checkpoint and context projections' {
    $stateRoot = Join-Path $TestDrive 'projection-defaults'
    $workspaceKey = 'ws-cccccccccccccccccccccccc'
    $sessionId = 'sid-projection-default-42424242'
    $checkpoint = Invoke-SharedStateScript $stateRoot $workspaceKey $checkpointScript @('-Action','Start','-TaskId','task-default-checkpoint','-SessionId',$sessionId,'-WorkspaceKey',$workspaceKey,'-CurrentStep','write canonical identity','-NextAction','verify canonical identity','-Json')
    $context = Invoke-SharedStateScript $stateRoot $workspaceKey $contextScript @('-Action','Preview','-TaskId','task-default-context','-SessionId',$sessionId,'-WorkspaceKey',$workspaceKey,'-AcceptedGoal','preview canonical identity','-AcceptedRoute','preview only','-Json')

    $checkpoint.exitCode | Should Be 0
    $checkpoint.value.agent | Should Be 'super-memory-brain'
    $checkpoint.value.agentId | Should Be 'super-brain-control-plane'
    $checkpoint.value.platform | Should Be 'super-brain'
    $context.exitCode | Should Be 0
    $context.value.agentId | Should Be 'super-brain-control-plane'
    $context.value.platform | Should Be 'super-brain'

    $taskCardPath = Get-SuperBrainCanonicalTaskPath (Join-Path $stateRoot 'shared\tasks\active') 'task-default-checkpoint' '.task.json'
    $taskCard = Get-Content -LiteralPath $taskCardPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $taskCard.agentName | Should Be 'super-memory-brain'
    $taskCard.agentId | Should Be 'super-brain-control-plane'
    $taskCard.platform | Should Be 'super-brain'
  }

  It 'does not reintroduce explicit ZCode ownership in the autonomous route' {
    $text = Get-Content -LiteralPath $autonomousScript -Raw -Encoding UTF8
    $text | Should Not Match "'-Agent','zcode'|-Platform\s+zcode|'-Platform','zcode'"
  }
}
