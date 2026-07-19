$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts\common.ps1')

function Write-TestJson([string]$Path,[object]$Value) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}

function U([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

Describe 'Super Brain usability hardening' {
  It 'routes natural memory questions without confusing them with previous-session recovery' {
    $router = Join-Path $root 'scripts\intent-router.ps1'
    $naturalQuery = U @(36824,35760,24471,27983,35272,22120,33258,21160,21270,29616,22312,20248,20808,29992,20160,20040,24037,20855,21527)
    $historicalQuery = U @(36824,35760,24471,19978,27425,30340,20219,21153,21527)
    $memoryRecall = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $router -Text $naturalQuery -Workspace $TestDrive -Json | ConvertFrom-Json)
    $historical = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $router -Text $historicalQuery -Workspace $TestDrive -Json | ConvertFrom-Json)

    $memoryRecall.intent | Should Be 'memory_recall'
    $historical.intent | Should Be 'historical_recovery'
  }

  It 'recalls natural Chinese memory from a fresh process without mojibake or false confidence' {
    $stateRoot = Join-Path $TestDrive 'natural-recall-state'
    $shared = Join-Path $stateRoot 'shared'
    New-Item -ItemType Directory -Force -Path $shared | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'memory\shared\scripts') -Destination (Join-Path $shared 'scripts') -Recurse -Force
    $browserDecision = U @(26222,36890,27983,35272,22120,33258,21160,21270,40664,35748,20351,29992,32,80,108,97,121,119,114,105,103,104,116,65307,20165,24403,29992,25143,26126,30830,35201,27714,32,98,114,111,119,115,101,114,45,97,99,116,65292,25110,32,80,108,97,121,119,114,105,103,104,116,32,26080,27861,21487,38752,23436,25104,30446,26631,25805,20316,26102,65292,25165,21152,36733,32,98,114,111,119,115,101,114,45,97,99,116,32,20316,20026,34917,20805,25110,20828,24213,12290)
    $engineeringDecision = U @(24037,31243,21028,26029,24517,39035,21306,20998,32,70,65,67,84,12289,73,78,70,69,82,69,78,67,69,32,21644,32,85,78,75,78,79,87,78,65292,24182,29992,35777,25454,39564,35777,26681,22240,12290)
    $staleDecision = U @(25152,26377,27983,35272,22120,20219,21153,20248,20808,32,98,114,111,119,115,101,114,45,97,99,116,12290)
    $memoryLines = @(
      ('2026-07-14 09:54:51 | user | [CURRENT][VERIFIED][DECISION][ADR][SUMMARY] key=browser-automation-tool-priority decision=' + $browserDecision),
      ('2026-07-13 14:55:10 | user | [CURRENT][VERIFIED][PROFILE][SUMMARY] Evidence-bounded engineering judgment preference - ' + $engineeringDecision),
      ('2026-07-01 08:00:00 | user | [STALE][VERIFIED][DECISION][ADR] key=browser-act-old decision=' + $staleDecision)
    )
    [IO.File]::WriteAllText((Join-Path $shared 'sandglass.txt'),($memoryLines -join "`n") + "`n",[Text.UTF8Encoding]::new($false))

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $recallScript = Join-Path $root 'scripts\recall-search.ps1'
      $naturalQuery = U @(36824,35760,24471,27983,35272,22120,33258,21160,21270,29616,22312,20248,20808,29992,20160,20040,24037,20855,21527)
      $unknownQuery = U @(25105,26368,21916,27426,30340,32534,31243,35821,35328,26159,20160,20040)
      $result = @((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recallScript -Query $naturalQuery -TopK 3 -MaxTokens 500 -MemoryMode force -Json | ConvertFrom-Json) | Where-Object { $_ -ne $null })
      $unknown = @((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recallScript -Query $unknownQuery -TopK 3 -MaxTokens 500 -MemoryMode force -Json | ConvertFrom-Json) | Where-Object { $_ -ne $null })

      @($result).Count -gt 0 | Should Be $true
      ([string]$result[0].text).Contains('Playwright') | Should Be $true
      ([string]$result[0].text).Contains([char]0xFFFD) | Should Be $false
      ([double]$result[0].confidence) -lt 1 | Should Be $true
      @($unknown).Count | Should Be 0
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
  }

  It 'keeps foreign checkpoints and status actions out of session restore packets' {
    $stateRoot = Join-Path $TestDrive 'session-restore-isolation-state'
    $workspace = Join-Path $stateRoot 'workspace'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    $currentKey = Get-SuperBrainWorkspaceKey (Join-Path $TestDrive 'current-project')
    $foreignKey = Get-SuperBrainWorkspaceKey (Join-Path $TestDrive 'foreign-project')
    Write-TestJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{ taskId='foreign-task'; workspaceKey=$foreignKey; status='active'; nextAction='wrong foreign checkpoint action' })
    Write-TestJson (Join-Path $workspace 'status-card.json') ([pscustomobject]@{ ok=$true; workspaceKey=$foreignKey; nextAction='wrong foreign status action' })
    Write-TestJson (Join-Path $workspace 'last-status-snapshot.json') ([pscustomobject]@{ ok=$true; workspaceKey=$foreignKey; nextAction='wrong foreign snapshot action' })

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $restore = Join-Path $root 'scripts\session-restore.ps1'
      $result = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore -Query 'continue' -WorkspaceKey $currentKey -Json | ConvertFrom-Json)

      $result.checkpointSelection.state | Should Be 'foreign_workspace'
      $result.activeCheckpoint | Should Be $null
      $result.statusCard.nextAction | Should Be ''
      $result.lastSnapshot.nextAction | Should Be ''
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
  }

  It 'ignores legacy and foreign checkpoints but selects the current scoped task' {
    $workspace = Join-Path $TestDrive 'continuity-workspace'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    $alphaKey = Get-SuperBrainWorkspaceKey (Join-Path $TestDrive 'project-alpha')
    $betaKey = Get-SuperBrainWorkspaceKey (Join-Path $TestDrive 'project-beta')
    $pointer = Join-Path $workspace 'active-checkpoint.json'

    Write-TestJson $pointer ([pscustomobject]@{ taskId='legacy-task'; status='active'; nextAction='wrong legacy action' })
    $legacy = Get-SuperBrainRelevantCheckpoint $workspace $null $alphaKey
    $legacy.state | Should Be 'legacy_unscoped'
    $legacy.checkpoint | Should Be $null

    Write-TestJson $pointer ([pscustomobject]@{ taskId='foreign-task'; status='active'; workspaceKey=$betaKey; nextAction='wrong foreign action' })
    $foreign = Get-SuperBrainRelevantCheckpoint $workspace $null $alphaKey
    $foreign.state | Should Be 'foreign_workspace'
    $foreign.checkpoint | Should Be $null

    $context = [pscustomobject]@{ taskId='alpha-task'; status='active'; stale=$false; workspaceKey=$alphaKey; expiresAt=(Get-Date).AddHours(1).ToString('o') }
    $scoped = Join-Path $workspace 'runtime-state\checkpoints\active\alpha-task.json'
    Write-TestJson $scoped ([pscustomobject]@{ taskId='alpha-task'; status='active'; workspaceKey=$alphaKey; nextAction='correct alpha action' })
    $selected = Get-SuperBrainRelevantCheckpoint $workspace $context $alphaKey
    $selected.state | Should Be 'relevant'
    $selected.checkpoint.taskId | Should Be 'alpha-task'
    $selected.checkpoint.nextAction | Should Be 'correct alpha action'
  }

  It 'warns before memory capacity and blocks layer overflow without writing memory' {
    $warningRecords = @(1..96 | ForEach-Object { [pscustomobject]@{ raw=('x' * 80); layer='project' } })
    $warning = Get-SuperBrainMemoryBudget $warningRecords '' '' $root
    $warning.status | Should Be 'warning'
    $warning.admissionStatus | Should Be 'warning'

    $blockedRecords = @(1..121 | ForEach-Object { [pscustomobject]@{ raw=('x' * 80); layer='project' } })
    $blocked = Get-SuperBrainMemoryBudget $blockedRecords '' '' $root
    $blocked.status | Should Be 'blocked'
    $blocked.reason | Should Be 'memory_budget_exceeded'
  }

  It 'uses collision-resistant generated task ids and never reuses across workspaces' {
    $stateRoot = Join-Path $TestDrive 'task-register-state'
    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $script = Join-Path $root 'scripts\task-register.ps1'
      $alpha = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Auto -TaskName 'same-name' -SessionName 'same-session' -WorkspaceKey 'alpha-workspace' -Json | ConvertFrom-Json)
      $alphaAgain = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Auto -TaskName 'same-name' -SessionName 'same-session' -WorkspaceKey 'alpha-workspace' -Json | ConvertFrom-Json)
      $beta = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Auto -TaskName 'same-name' -SessionName 'same-session' -WorkspaceKey 'beta-workspace' -Json | ConvertFrom-Json)
      $alpha.taskId | Should Be $alphaAgain.taskId
      ($alpha.taskId -ne $beta.taskId) | Should Be $true
      $alpha.taskId | Should Match '^task-\d{8}-\d{9}-[0-9a-f]{6}$'
      $beta.taskId | Should Match '^task-\d{8}-\d{9}-[0-9a-f]{6}$'
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
  }

  It 'never resumes an unscoped stale task after rejecting its checkpoint' {
    $stateRoot = Join-Path $TestDrive 'stale-continuation-state'
    $workspace = Join-Path $stateRoot 'workspace'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    $version = [string](Get-SuperBrainManifest $root).version
    Write-TestJson (Join-Path $workspace 'last-verify-package.json') ([pscustomobject]@{ ok=$true; version=$version; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') })
    Write-TestJson (Join-Path $workspace 'last-hot-refresh.json') ([pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') })
    Write-TestJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{ taskId='legacy-task'; status='active'; nextAction='wrong checkpoint action' })
    Write-TestJson (Join-Path $workspace 'last-task-verification.json') ([pscustomobject]@{ ok=$true; version=$version; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); nextSteps=@('wrong stale task action') })
    Write-TestJson (Join-Path $workspace 'last-status-snapshot.json') ([pscustomobject]@{ ok=$true; version=$version; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); nextAction='wrong stale snapshot action' })

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $script = Join-Path $root 'scripts\auto-continuation.ps1'
      $result = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -WorkspaceKey 'current-workspace' -Json | ConvertFrom-Json)
      $result.checkpointSelection.state | Should Be 'legacy_unscoped'
      $result.lastTaskStale | Should Be $true
      $result.resumeFrom | Should Be 'none'
      $result.executionResolutionStatus | Should Be 'no_contract'
      $result.actionWithheld | Should Be $false
      $result.mutationAuthorized | Should Be $false
      $serialized = $result | ConvertTo-Json -Depth 10
      $serialized.Contains('wrong checkpoint action') | Should Be $false
      $serialized.Contains('wrong stale task action') | Should Be $false
      $serialized.Contains('wrong stale snapshot action') | Should Be $false
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
    }
  }
}
