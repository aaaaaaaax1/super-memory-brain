$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$driftScript = Join-Path $root 'scripts\runtime-drift-checkpoint.ps1'
. (Join-Path $root 'scripts\common.ps1')

function Write-DriftJson([string]$Path,[object]$Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}

function Invoke-Drift([string]$StateRoot,[string[]]$Arguments) {
  $old = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $driftScript @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
  } finally { $env:SUPER_BRAIN_STATE_ROOT = $old }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

Describe 'Runtime drift checkpoint task isolation' {
  It 'fails closed without creating a legacy checkpoint when mutation scope is missing' {
    $stateRoot = Join-Path $TestDrive 'unscoped'
    $workspace = Join-Path $stateRoot 'workspace'
    $result = Invoke-Drift $stateRoot @('-Phase','BeforeAct','-ObservedAction','unsafe unscoped write','-Json')
    $result.exitCode | Should Be 1
    $result.value.status | Should Be 'scope_required'
    (@($result.value.violations.code) -contains 'missing_task_scope') | Should Be $true
    Test-Path -LiteralPath (Join-Path $workspace 'runtime-drift-checkpoint.json') | Should Be $false
    Test-Path -LiteralPath (Join-Path $workspace 'last-runtime-drift-checkpoint.json') | Should Be $false
  }

  It 'ignores foreign global checkpoint and ledger state for a task-scoped completion check' {
    $stateRoot = Join-Path $TestDrive 'scope'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-drift-current'
    $workspaceKey = 'ws-222222222222222222222222'
    $query = 'complete the current scoped task'
    $now = (Get-Date).ToString('o')
    Write-DriftJson (Join-Path $workspace 'last-cognitive-preflight.json') ([pscustomobject]@{ ok=$true; checkedAt=$now; query=$query; driftGuards=@(); intent='general_task' })
    Write-DriftJson (Join-Path $workspace 'last-cognitive-enforce.json') ([pscustomobject]@{ ok=$true; checkedAt=$now; query=$query; violations=@(); engineeringJudgment=[pscustomobject]@{ taskId=$taskId } })
    Write-DriftJson (Join-Path $workspace 'last-accepted-constraints-preflight.json') ([pscustomobject]@{ ok=$true; checkedAt=$now; query=$query; conflicts=@() })
    Write-DriftJson (Join-Path $workspace 'step-ledger.json') ([pscustomobject]@{ taskId='task-foreign'; openSteps=@('foreign unfinished step'); blockedSteps=@() })
    Write-DriftJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{ taskId='task-foreign'; workspaceKey=$workspaceKey; status='active' })
    $scopedCheckpoint = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\active') $taskId '.json'
    Write-DriftJson $scopedCheckpoint ([pscustomobject]@{ taskId=$taskId; workspaceKey=$workspaceKey; status='completed'; pendingSteps=@() })

    $result = Invoke-Drift $stateRoot @('-Phase','BeforeCompletion','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction',$query,'-Query',$query,'-Json')
    if ($result.exitCode -ne 0) { throw "Scoped drift check failed: $($result.text)" }
    $result.exitCode | Should Be 0
    $result.value.ok | Should Be $true
    @($result.value.violations.code) -contains 'completion_with_active_checkpoint' | Should Be $false
    @($result.value.violations.code) -contains 'completion_with_open_or_blocked_steps' | Should Be $false
    $result.value.taskId | Should Be $taskId
    Test-Path -LiteralPath (Join-Path $workspace 'last-runtime-drift-checkpoint.json') | Should Be $false
  }

  It 'returns scoped status without reevaluating or rewriting the checkpoint' {
    $stateRoot = Join-Path $TestDrive 'status'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-drift-status'
    $workspaceKey = 'ws-333333333333333333333333'
    $statePath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\runtime-drift-checkpoints') $taskId '.json'
    Write-DriftJson $statePath ([pscustomobject]@{ ok=$true; schema='super-brain.runtime-drift-checkpoint.v2'; taskId=$taskId; workspaceKey=$workspaceKey; checkedAt='2026-07-20T00:00:00Z'; phase='BeforeMutation'; status='clean'; unresolvedDrift=$false; violations=@(); blockers=@() })
    $beforeHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash

    $result = Invoke-Drift $stateRoot @('-Phase','Status','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-Json')
    $result.exitCode | Should Be 0
    $result.value.status | Should Be 'clean'
    $result.value.taskId | Should Be $taskId
    (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash | Should Be $beforeHash
  }
}
