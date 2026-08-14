$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$contextScript = Join-Path $root 'scripts\current-task-context.ps1'
. (Join-Path $root 'scripts\common.ps1')

function Invoke-BootstrapJson([string]$Script,[hashtable]$Parameters) {
  $bound = @{}
  foreach ($key in $Parameters.Keys) { $bound[$key] = $Parameters[$key] }
  $bound.NoExit = $true
  $bound.Json = $true
  $raw = @(& $Script @bound 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return ($text | ConvertFrom-Json)
}

Describe 'Current task context active-bundle bootstrap' {
  It 'creates checkpoint and task-card projections before allowing a new bound context to authorize' {
    $stateRoot = Join-Path $TestDrive 'context-bootstrap'
    $workspaceKey = 'ws-context-bootstrap-4242424242'
    $sessionKey = 'sid-context-bootstrap-4242424242'
    $taskId = 'task-context-bootstrap'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey

      $created = Invoke-BootstrapJson $contractScript @{
        Action='Set';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey
        FocusId='bootstrap-main';FocusLabel='Bootstrap main';InstructionMode='continue'
        LatestUserInstruction='start a bound task with a complete active bundle';NextAction='execute bootstrap action'
        CurrentPhase='P0';CurrentStep='bootstrap the active task state';PendingSteps=@('execute bootstrap action')
        EnableCanonicalPlan=$true
        StateRoot=$stateRoot;Source='CurrentTaskContextBootstrap.Tests.ps1'
      }
      $created.ok | Should Be $true

      $context = Invoke-BootstrapJson $contextScript @{
        Action='Create';TaskId=$taskId;WorkspaceKey=$workspaceKey;AgentId='codex';SessionId=$sessionKey;Platform='codex';OwnerWorkspace=$root
        AcceptedGoal='Create a recoverable active bundle before authorizing the task.'
        AcceptedRoute=@('create checkpoint','create task card','bind context atomically')
        MustPreserve=@('task/session/workspace isolation')
        MustNotDriftTo=@('partial context without active bundle')
        Evidence=@('CurrentTaskContextBootstrap.Tests.ps1')
        MaxAgeHours=24
      }
      $context.ok | Should Be $true
      $context.bindingState | Should Be 'bound'

      $projectionRoot = Join-Path $stateRoot 'workspace\task-state-store\projections'
      $projectionPath = @(Get-ChildItem -LiteralPath $projectionRoot -Filter ($taskId + '*.json') -File | Select-Object -First 1)[0].FullName
      Test-Path -LiteralPath $projectionPath | Should Be $true
      $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $projection.entities.checkpoint.status | Should Be 'active'
      $projection.entities.task_card.status | Should Be 'active'
      Test-Path -LiteralPath $projection.entities.checkpoint.path | Should Be $true
      Test-Path -LiteralPath $projection.entities.task_card.path | Should Be $true

      $resolved = Invoke-BootstrapJson $contractScript @{
        Action='Resolve';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;StateRoot=$stateRoot
      }
      $resolved.actionAuthorization | Should Be 'allowed'
      $resolved.continuity.code | Should Be 'EXECUTION_CONTRACT_CONTINUITY_CURRENT'

      Remove-Item -LiteralPath $projection.entities.task_card.path -Force
      $tampered = Invoke-BootstrapJson $contractScript @{
        Action='Resolve';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;StateRoot=$stateRoot
      }
      $tampered.actionAuthorization | Should Be 'withheld'
      $tampered.resumeFrom | Should Be 'execution_contract_continuity_stale'
      $tampered.continuity.code | Should Match '^EXECUTION_CONTRACT_CONTINUITY_'
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'binds an ordinary task to its task card without creating a plan checkpoint' {
    $stateRoot = Join-Path $TestDrive 'ordinary-context'
    $workspaceKey = 'ws-ordinary-context-4242424242'
    $sessionKey = 'sid-ordinary-context-4242424242'
    $taskId = 'task-ordinary-context'
    $taskScript = Join-Path $root 'scripts\task-register.ps1'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey

      $registered = Invoke-BootstrapJson $taskScript @{
        TaskId=$taskId;TaskName='Ordinary bound task';Status='active';Agent='codex';AgentId='codex';Platform='codex'
        SessionId=$sessionKey;SessionTitle='ordinary context';WorkspaceKey=$workspaceKey;Goal='Run an ordinary task without an approved multi-step plan.'
      }
      $registered.ok | Should Be $true

      $created = Invoke-BootstrapJson $contractScript @{
        Action='Set';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey
        FocusId='ordinary-main';FocusLabel='Ordinary main';InstructionMode='continue'
        LatestUserInstruction='continue ordinary task';NextAction='perform one bounded action'
        CurrentPhase='execution';CurrentStep='perform one bounded action';PendingSteps=@()
        StateRoot=$stateRoot;Source='CurrentTaskContextBootstrap.Tests.ps1'
      }
      $created.ok | Should Be $true

      $context = Invoke-BootstrapJson $contextScript @{
        Action='Create';TaskId=$taskId;WorkspaceKey=$workspaceKey;AgentId='codex';SessionId=$sessionKey;Platform='codex';OwnerWorkspace=$root
        AcceptedGoal='Run an ordinary task without creating a plan checkpoint.'
        AcceptedRoute=@('reuse task card','bind context atomically')
        MustPreserve=@('task/session/workspace isolation')
        MustNotDriftTo=@('ordinary context promoted to approved plan checkpoint')
        Evidence=@('CurrentTaskContextBootstrap.Tests.ps1 ordinary task')
        MaxAgeHours=24
      }
      $context.ok | Should Be $true
      $context.bindingState | Should Be 'bound'
      $context.planCheckpointRequired | Should Be $false

      $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $stateRoot 'workspace\task-state-store\projections') $taskId '.json'
      $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $projection.entities.task_card.status | Should Be 'active'
      $projection.entities.task_card.owner.workspace | Should Be $root
      $projection.entities.checkpoint | Should BeNullOrEmpty
      $checkpointPath = Get-SuperBrainCanonicalTaskPath (Join-Path $stateRoot 'workspace\runtime-state\checkpoints\active') $taskId '.json'
      Test-Path -LiteralPath $checkpointPath | Should Be $false
      Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\active-checkpoint.json') | Should Be $false

      $resolved = Invoke-BootstrapJson $contractScript @{
        Action='Resolve';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey;StateRoot=$stateRoot
      }
      $resolved.actionAuthorization | Should Be 'allowed'
      $resolved.continuity.code | Should Be 'EXECUTION_CONTRACT_CONTINUITY_CURRENT'
      $resolved.continuity.planCheckpointRequired | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }
}
