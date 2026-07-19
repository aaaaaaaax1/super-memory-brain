$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'

function Write-TestJson([string]$Path,[object]$Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Invoke-Contract([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $contractScript @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

Describe 'Execution contract continuity' {
  It 'prefers visible conversation over contract and checkpoint state' {
    $stateRoot = Join-Path $TestDrive 'visible-priority'
    $workspace = Join-Path $stateRoot 'workspace'
    $checkpoint = Join-Path $workspace 'checkpoint.json'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    [IO.File]::WriteAllText($checkpoint,([pscustomobject]@{taskId='task-visible';workspaceKey='ws-111111111111111111111111';nextAction='repeat old evidence work';timestamp='2026-07-17 09:00:00'} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))

    $set = Invoke-Contract @('-Action','Set','-TaskId','task-visible','-WorkspaceKey','ws-111111111111111111111111','-FocusId','engineering-holdout','-NextAction','build the engineering behavior holdout','-StateRoot',$stateRoot,'-Json')
    $set.exitCode | Should Be 0
    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId','task-visible','-WorkspaceKey','ws-111111111111111111111111','-CheckpointPath',$checkpoint,'-VisibleUserInstruction','continue from the latest reply','-VisibleAssistantCommitment','add observable engineering behavior contracts','-StateRoot',$stateRoot,'-Json')

    $resolved.exitCode | Should Be 0
    $resolved.value.resumeFrom | Should Be 'visible_conversation'
    $resolved.value.nextAction | Should Be 'add observable engineering behavior contracts'
    $resolved.value.nextAction | Should Not Match 'old evidence'
  }

  It 'requires reconciliation for a visible user instruction without a commitment and preserves parent return state' {
    $stateRoot = Join-Path $TestDrive 'visible-user-pending'
    $workspaceKey = 'ws-121212121212121212121212'
    (Invoke-Contract @('-Action','Set','-TaskId','task-visible-pending','-WorkspaceKey',$workspaceKey,'-FocusId','parent-focus','-NextAction','finish the parent','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId','task-visible-pending','-WorkspaceKey',$workspaceKey,'-FocusId','side-focus','-NextAction','finish the side request','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId','task-visible-pending','-WorkspaceKey',$workspaceKey,'-VisibleUserInstruction','please also verify the side request','-StateRoot',$stateRoot,'-Json')

    $resolved.exitCode | Should Be 0
    $resolved.value.resumeFrom | Should Be 'visible_conversation'
    $resolved.value.claimAllowed | Should Be $false
    $resolved.value.needsConfirmation | Should Be $true
    @($resolved.value.returnStack).Count | Should Be 1
    $resolved.value.returnTo.focusId | Should Be 'parent-focus'
    $resolved.value.canResumeParent | Should Be $false
    $resolved.value.actionAuthorization | Should Be 'withheld'
    $resolved.value.returnTo.nextAction | Should BeNullOrEmpty
    $resolved.value.workLineStatus.activePlan.nextAction | Should BeNullOrEmpty
    $resolved.value.workLineStatus.mainPlan.nextAction | Should BeNullOrEmpty
    $serialized = $resolved.value | ConvertTo-Json -Depth 12
    $serialized.Contains('finish the parent') | Should Be $false
    $serialized.Contains('finish the side request') | Should Be $false
  }

  It 'uses a newer task execution contract before an older checkpoint' {
    $stateRoot = Join-Path $TestDrive 'contract-priority'
    $workspace = Join-Path $stateRoot 'workspace'
    $checkpoint = Join-Path $workspace 'checkpoint.json'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    [IO.File]::WriteAllText($checkpoint,([pscustomobject]@{taskId='task-contract';workspaceKey='ws-222222222222222222222222';nextAction='repeat evidence freshness edits';timestamp='2026-07-17 09:00:00'} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))

    $set = Invoke-Contract @('-Action','Set','-TaskId','task-contract','-WorkspaceKey','ws-222222222222222222222222','-FocusId','engineering-holdout','-NextAction','implement observable behavior holdout','-InvalidatedWorkItems','evidence-freshness','-StateRoot',$stateRoot,'-Json')
    $set.exitCode | Should Be 0
    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId','task-contract','-WorkspaceKey','ws-222222222222222222222222','-CheckpointPath',$checkpoint,'-StateRoot',$stateRoot,'-Json')

    $resolved.exitCode | Should Be 0
    $resolved.value.resumeFrom | Should Be 'execution_contract'
    $resolved.value.focusId | Should Be 'engineering-holdout'
    $resolved.value.nextAction | Should Be 'implement observable behavior holdout'
  }

  It 'preserves omitted contract lists while allowing explicitly bound empty lists to clear them' {
    $stateRoot = Join-Path $TestDrive 'preserve-contract-lists'
    $workspaceKey = 'ws-232323232323232323232323'
    (Invoke-Contract @('-Action','Set','-TaskId','task-list-preserve','-WorkspaceKey',$workspaceKey,'-FocusId','list-focus','-Constraints','preserve user data','-AcceptanceCriteria','regression passes','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $updated = Invoke-Contract @('-Action','Set','-TaskId','task-list-preserve','-WorkspaceKey',$workspaceKey,'-FocusId','list-focus','-NextAction','continue the focused work','-StateRoot',$stateRoot,'-Json')
    $updated.exitCode | Should Be 0
    @($updated.value.constraints) | Should Be @('preserve user data')
    @($updated.value.acceptanceCriteria) | Should Be @('regression passes')

    $escapedContractScript = $contractScript.Replace("'", "''")
    $escapedStateRoot = $stateRoot.Replace("'", "''")
    $clearCommand = "& '$escapedContractScript' -Action Set -TaskId 'task-list-preserve' -WorkspaceKey '$workspaceKey' -FocusId 'list-focus' -Constraints @() -AcceptanceCriteria @() -StateRoot '$escapedStateRoot' -Json"
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $clearCommand 2>$null)
    $clearExitCode = $LASTEXITCODE
    $cleared = (($raw -join "`n") | ConvertFrom-Json)

    $clearExitCode | Should Be 0
    @($cleared.constraints).Count | Should Be 0
    @($cleared.acceptanceCriteria).Count | Should Be 0
  }

  It 'blocks superseded work before another mutation' {
    $stateRoot = Join-Path $TestDrive 'superseded-guard'
    $workspaceKey = 'ws-333333333333333333333333'
    $set = Invoke-Contract @('-Action','Set','-TaskId','task-guard','-WorkspaceKey',$workspaceKey,'-FocusId','engineering-holdout','-NextAction','implement observable behavior holdout','-InvalidatedWorkItems','evidence-freshness','-StateRoot',$stateRoot,'-Json')
    $set.exitCode | Should Be 0
    $blocked = Invoke-Contract @('-Action','Guard','-TaskId','task-guard','-WorkspaceKey',$workspaceKey,'-ProposedWorkId','evidence-freshness','-StateRoot',$stateRoot,'-Json')

    $blocked.exitCode | Should Be 1
    $blocked.value.ok | Should Be $false
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_WORK_INVALIDATED'
    $blocked.value.currentFocusId | Should Be 'engineering-holdout'
  }

  It 'returns unknown after compaction when neither visible tail nor a current contract exists' {
    $stateRoot = Join-Path $TestDrive 'unknown-after-compaction'
    $workspace = Join-Path $stateRoot 'workspace'
    $checkpoint = Join-Path $workspace 'checkpoint.json'
    New-Item -ItemType Directory -Force -Path $workspace | Out-Null
    [IO.File]::WriteAllText($checkpoint,([pscustomobject]@{taskId='task-unknown';workspaceKey='ws-444444444444444444444444';currentPhase='holdout';currentStep='old checkpoint step';nextAction='repeat old mutation';timestamp='2026-07-17 09:00:00'} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))

    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId','task-unknown','-WorkspaceKey','ws-444444444444444444444444','-CheckpointPath',$checkpoint,'-StateRoot',$stateRoot,'-Json')

    $resolved.exitCode | Should Be 0
    $resolved.value.resumeFrom | Should Be 'checkpoint_state_only'
    $resolved.value.claimAllowed | Should Be $false
    $resolved.value.needsConfirmation | Should Be $true
    $resolved.value.nextAction | Should Be ''
    (($resolved.value | ConvertTo-Json -Depth 12).Contains('repeat old mutation')) | Should Be $false
    $resolved.value.currentPhase | Should Be 'holdout'
  }

  It 'keeps a newly observed user instruction pending until commitment reconciliation' {
    $stateRoot = Join-Path $TestDrive 'pending-reconciliation'
    $workspaceKey = 'ws-555555555555555555555555'
    (Invoke-Contract @('-Action','Set','-TaskId','task-pending','-WorkspaceKey',$workspaceKey,'-FocusId','old-work','-NextAction','continue old work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','ObserveUser','-TaskId','task-pending','-WorkspaceKey',$workspaceKey,'-UserInstruction','new requirement after disconnect','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId','task-pending','-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    $guarded = Invoke-Contract @('-Action','Guard','-TaskId','task-pending','-WorkspaceKey',$workspaceKey,'-ProposedWorkId','old-work','-StateRoot',$stateRoot,'-Json')

    $resolved.value.resumeFrom | Should Be 'execution_contract_pending_reconciliation'
    $resolved.value.claimAllowed | Should Be $false
    $resolved.value.needsConfirmation | Should Be $true
    $guarded.exitCode | Should Be 1
    $guarded.value.code | Should Be 'EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'
  }

  It 'integrates a newer contract ahead of an older checkpoint in auto continuation' {
    $stateRoot = Join-Path $TestDrive 'auto-contract-priority'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-auto-contract'
    $workspaceKey = 'ws-666666666666666666666666'
    $version = [string](Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Write-TestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{status='active';stale=$false;taskId=$taskId;workspaceKey=$workspaceKey;version=$version;expiresAt=(Get-Date).AddHours(2).ToString('o')})
    Write-TestJson (Join-Path $workspace "runtime-state\checkpoints\active\$taskId.json") ([pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceKey;version=$version;currentPhase='holdout';currentStep='old phase step';nextAction='repeat old evidence edit';timestamp=(Get-Date).AddHours(-1).ToString('o')})
    Write-TestJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceKey;version=$version;currentPhase='holdout';currentStep='old phase step';nextAction='repeat old evidence edit';timestamp=(Get-Date).AddHours(-1).ToString('o')})
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','latest-contract','-NextAction','resume latest behavior contract','-InvalidatedWorkItems','old-phase-step','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\auto-continuation.ps1') -WorkspaceKey $workspaceKey -AllowStaleVerify -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    $result = (($raw -join "`n") | ConvertFrom-Json)

    $exitCode | Should Be 0
    $result.resumeFrom | Should Be 'execution_contract'
    $result.nextAction | Should Be 'resume latest behavior contract'
    $result.mutationAuthorized | Should Be $true
    $result.nextAction | Should Not Match 'old evidence'
  }

  It 'does not authorize a checkpoint action when compression removed the tail and contract' {
    $stateRoot = Join-Path $TestDrive 'auto-unknown-priority'
    $workspace = Join-Path $stateRoot 'workspace'
    $taskId = 'task-auto-unknown'
    $workspaceKey = 'ws-777777777777777777777777'
    $version = [string](Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Write-TestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{status='active';stale=$false;taskId=$taskId;workspaceKey=$workspaceKey;version=$version;expiresAt=(Get-Date).AddHours(2).ToString('o')})
    Write-TestJson (Join-Path $workspace "runtime-state\checkpoints\active\$taskId.json") ([pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceKey;version=$version;currentPhase='holdout';currentStep='known phase only';nextAction='dangerous repeated mutation';timestamp=(Get-Date).AddHours(-1).ToString('o')})
    Write-TestJson (Join-Path $workspace 'active-checkpoint.json') ([pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceKey;version=$version;currentPhase='holdout';currentStep='known phase only';nextAction='dangerous repeated mutation';timestamp=(Get-Date).AddHours(-1).ToString('o')})

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\auto-continuation.ps1') -WorkspaceKey $workspaceKey -AllowStaleVerify -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    $result = (($raw -join "`n") | ConvertFrom-Json)

    $exitCode | Should Be 0
    $result.resumeFrom | Should Be 'checkpoint_state_only'
    $result.currentPhase | Should Be 'holdout'
    $result.currentStep | Should BeNullOrEmpty
    $result.mutationAuthorized | Should Be $false
    $result.nextAction | Should Match 'unknown'
    $result.nextAction | Should Not Match 'dangerous repeated mutation'
  }

  It 'blocks an unreconciled contract through the real before-mutation gate' {
    $stateRoot = Join-Path $TestDrive 'cognitive-enforce-contract'
    $workspaceKey = 'ws-888888888888888888888888'
    $taskId = 'task-cognitive-contract'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','old-work','-NextAction','continue old work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction','replace the old work with a safer route','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\cognitive-enforce.ps1') -Query 'apply local change' -TaskId $taskId -ProposedWorkId 'old-work' -Phase BeforeMutation -AllowMissingPreflight -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey
    }
    $result = (($raw -join "`n") | ConvertFrom-Json)

    $exitCode | Should Be 1
    $result.ok | Should Be $false
    @($result.violations) -contains 'execution-contract-guard' | Should Be $true
    $result.executionContract.code | Should Be 'EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'
  }

  It 'runs the execution-contract guard for a parent return before mutation' {
    $stateRoot = Join-Path $TestDrive 'cognitive-enforce-parent-return'
    $workspaceKey = 'ws-898989898989898989898989'
    $taskId = 'task-cognitive-parent-return'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','parent-focus','-NextAction','continue the parent','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','side-focus','-NextAction','check the side request','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\cognitive-enforce.ps1') -Query 'apply local change' -TaskId $taskId -ProposedWorkId 'parent-focus' -Phase BeforeMutation -AllowMissingPreflight -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey
    }
    $result = (($raw -join "`n") | ConvertFrom-Json)

    $exitCode | Should Be 0
    $result.executionContract.required | Should Be $true
    $result.executionContract.code | Should Be 'EXECUTION_CONTRACT_GUARD_OK'
  }

  It 'preserves the parent task when a new focus becomes a side branch' {
    $stateRoot = Join-Path $TestDrive 'side-branch-return'
    $workspaceKey = 'ws-999999999999999999999999'
    (Invoke-Contract @('-Action','Set','-TaskId','task-side','-WorkspaceKey',$workspaceKey,'-FocusId','parent-focus','-NextAction','resume the original build','-AssistantCommitment','finish the original build','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','ObserveUser','-TaskId','task-side','-WorkspaceKey',$workspaceKey,'-UserInstruction','also check this unrelated report','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $side = Invoke-Contract @('-Action','Set','-TaskId','task-side','-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','side-report','-NextAction','check the unrelated report','-AssistantCommitment','handle the inserted report request','-StateRoot',$stateRoot,'-Json')
    $side.exitCode | Should Be 0
    $side.value.instructionMode | Should Be 'side_branch'
    @($side.value.returnStack).Count | Should Be 1
    $side.value.returnTo.focusId | Should Be 'parent-focus'
    $side.value.returnTo.nextAction | Should Be 'resume the original build'
    $side.value.workLineStatus.mainLine | Should Be 'parent-focus'
    $side.value.workLineStatus.activeLine | Should Be 'side-report'
    @($side.value.workLineStatus.suspendedLines) | Should Be @('parent-focus')
    $side.value.workLineStatus.defaultNextLine | Should Be 'parent-focus'
    $side.value.workLineStatus.priorityPolicy | Should Be 'latest_explicit_user_priority_then_nearest_suspended_parent'
    @($side.value.invalidatedWorkItems) -contains 'parent-focus' | Should Be $false

    # Refreshing the active branch must not unwrap a single parent card.
    $refreshed = Invoke-Contract @('-Action','Set','-TaskId','task-side','-WorkspaceKey',$workspaceKey,'-FocusId','side-report','-InstructionMode','continue','-NextAction','finish the report','-AssistantCommitment','close the report with evidence','-StateRoot',$stateRoot,'-Json')
    $refreshed.exitCode | Should Be 0
    @($refreshed.value.returnStack).Count | Should Be 1
    $refreshed.value.canResumeParent | Should Be $true
    $refreshed.value.returnTo.focusId | Should Be 'parent-focus'

    $blocked = Invoke-Contract @('-Action','Guard','-TaskId','task-side','-WorkspaceKey',$workspaceKey,'-ProposedWorkId','parent-focus','-StateRoot',$stateRoot,'-Json')
    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PARENT_SUSPENDED'

    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId','task-side','-WorkspaceKey',$workspaceKey,'-BranchStatus','completed','-CompletionEvidence','report completion verified','-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 0
    $resumed.value.instructionMode | Should Be 'resume_parent'
    $resumed.value.focusId | Should Be 'parent-focus'
    $resumed.value.nextAction | Should Be 'resume the original build'
    @($resumed.value.returnStack).Count | Should Be 0
    @($resumed.value.completedWorkLines) | Should Be @('side-report')
    $resumed.value.workLineStatus.mainLine | Should Be 'parent-focus'
    $resumed.value.workLineStatus.activeLine | Should Be 'parent-focus'
    @($resumed.value.workLineStatus.completedRecent) | Should Be @('side-report')
    @($resumed.value.workLineStatus.suspendedLines).Count | Should Be 0

    $version = [string](Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Write-TestJson (Join-Path $stateRoot 'workspace\current-task-context.json') ([pscustomobject]@{status='active';stale=$false;taskId='task-side';workspaceKey=$workspaceKey;version=$version;expiresAt=(Get-Date).AddHours(2).ToString('o')})
    Write-TestJson (Join-Path $stateRoot 'workspace\runtime-state\checkpoints\active\task-side.json') ([pscustomobject]@{status='active';taskId='task-side';workspaceKey=$workspaceKey;version=$version;currentPhase='side-branch';currentStep='side report complete';nextAction='repeat the side report';timestamp=(Get-Date).AddMinutes(-1).ToString('o')})

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\auto-continuation.ps1') -WorkspaceKey $workspaceKey -AllowStaleVerify -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    $continuation = (($raw -join "`n") | ConvertFrom-Json)
    $exitCode | Should Be 0
    $continuation.resumeFrom | Should Be 'parent_return'
    $continuation.instructionMode | Should Be 'resume_parent'
    $continuation.nextAction | Should Be 'resume the original build'
    $continuation.mutationAuthorized | Should Be $true
    $continuation.nextAction | Should Not Match 'repeat the side report'
  }

  It 'keeps a resumed branch unfinished unless completion evidence is declared' {
    $stateRoot = Join-Path $TestDrive 'partial-branch-return'
    $workspaceKey = 'ws-bbbbbbbbbbbbbbbbbbbbbbbb'
    (Invoke-Contract @('-Action','Set','-TaskId','task-partial','-WorkspaceKey',$workspaceKey,'-FocusId','parent-focus','-NextAction','finish parent work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId','task-partial','-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','partial-branch','-NextAction','investigate side work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $partial = Invoke-Contract @('-Action','ResumeParent','-TaskId','task-partial','-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')

    $partial.exitCode | Should Be 0
    $partial.value.resumedBranchStatus | Should Be 'partial'
    @($partial.value.completedWorkLines) -contains 'partial-branch' | Should Be $false
    @($partial.value.unfinishedWorkLines) -contains 'partial-branch' | Should Be $true

    (Invoke-Contract @('-Action','Set','-TaskId','task-partial','-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','completed-branch','-NextAction','finish documented side work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $completed = Invoke-Contract @('-Action','ResumeParent','-TaskId','task-partial','-WorkspaceKey',$workspaceKey,'-BranchStatus','completed','-CompletionEvidence','reviewed result and acceptance evidence','-StateRoot',$stateRoot,'-Json')

    $completed.exitCode | Should Be 0
    $completed.value.resumedBranchStatus | Should Be 'completed'
    @($completed.value.completedWorkLines) -contains 'completed-branch' | Should Be $true
    @($completed.value.unfinishedWorkLines) -contains 'completed-branch' | Should Be $false
  }

  It 'rejects a new side branch when the bounded return stack is full' {
    $stateRoot = Join-Path $TestDrive 'return-stack-full'
    $workspaceKey = 'ws-cccccccccccccccccccccccc'
    (Invoke-Contract @('-Action','Set','-TaskId','task-stack-full','-WorkspaceKey',$workspaceKey,'-FocusId','parent-0','-NextAction','start parent work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    foreach ($index in 1..4) {
      (Invoke-Contract @('-Action','Set','-TaskId','task-stack-full','-WorkspaceKey',$workspaceKey,'-FocusId',("branch-" + $index),'-NextAction',('handle branch ' + $index),'-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    }

    $overflow = Invoke-Contract @('-Action','Set','-TaskId','task-stack-full','-WorkspaceKey',$workspaceKey,'-FocusId','branch-5','-NextAction','handle branch 5','-StateRoot',$stateRoot,'-Json')
    $current = Invoke-Contract @('-Action','Get','-TaskId','task-stack-full','-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')

    $overflow.exitCode | Should Be 1
    $overflow.value.code | Should Be 'EXECUTION_CONTRACT_RETURN_STACK_FULL'
    $overflow.value.maxReturnStackDepth | Should Be 4
    @($overflow.value.returnStack).Count | Should Be 4
    $current.value.focusId | Should Be 'branch-4'
    @($current.value.returnStack).Count | Should Be 4
  }

  It 'keeps recovered next action while blockers disable mutation and exposes unfinished lines' {
    $stateRoot = Join-Path $TestDrive 'auto-blockers-preserve-next-action'
    $workspace = Join-Path $stateRoot 'workspace'
    $workspaceKey = 'ws-dddddddddddddddddddddddd'
    $taskId = 'task-auto-blocker'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','parent-focus','-NextAction','resume the parent work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','unfinished-side','-NextAction','inspect the side work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $version = [string](Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Write-TestJson (Join-Path $workspace 'current-task-context.json') ([pscustomobject]@{status='active';stale=$false;taskId=$taskId;workspaceKey=$workspaceKey;version=$version;expiresAt=(Get-Date).AddHours(2).ToString('o')})
    Write-TestJson (Join-Path $workspace "runtime-state\checkpoints\active\$taskId.json") ([pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceKey;version=$version;currentPhase='parent';currentStep='resume parent';nextAction='stale checkpoint next action';timestamp=(Get-Date).AddMinutes(-1).ToString('o')})

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\auto-continuation.ps1') -WorkspaceKey $workspaceKey -Json 2>$null)
      $exitCode = $LASTEXITCODE
    } finally { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    $continuation = (($raw -join "`n") | ConvertFrom-Json)

    $exitCode | Should Be 1
    $continuation.resumeFrom | Should Be 'parent_return'
    $continuation.nextAction | Should Be 'resume the parent work'
    $continuation.mutationAuthorized | Should Be $false
    $continuation.blockerNextAction | Should Match 'verify-package'
    $continuation.workLineStatus.activeLine | Should Be 'parent-focus'
    @($continuation.unfinishedLines) -contains 'unfinished-side' | Should Be $true
  }

  It 'requires explicit replacement before discarding a parent task' {
    $stateRoot = Join-Path $TestDrive 'explicit-replace'
    $workspaceKey = 'ws-aaaaaaaaaaaaaaaaaaaaaaaa'
    (Invoke-Contract @('-Action','Set','-TaskId','task-replace','-WorkspaceKey',$workspaceKey,'-FocusId','parent-focus','-NextAction','continue parent','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','ObserveUser','-TaskId','task-replace','-WorkspaceKey',$workspaceKey,'-UserInstruction','replace the old task with this one','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $replaced = Invoke-Contract @('-Action','Set','-TaskId','task-replace','-WorkspaceKey',$workspaceKey,'-FocusId','new-primary','-InstructionMode','replace','-NextAction','continue the replacement','-StateRoot',$stateRoot,'-Json')
    $replaced.exitCode | Should Be 0
    $replaced.value.instructionMode | Should Be 'replace'
    @($replaced.value.returnStack).Count | Should Be 0
    @($replaced.value.invalidatedWorkItems) -contains 'parent-focus' | Should Be $true
  }

  It 'preserves concrete plans and classifies the latest message against active and suspended lines' {
    $stateRoot = Join-Path $TestDrive 'topic-affinity-lines'
    $workspaceKey = 'ws-e11111111111111111111111'
    (Invoke-Contract @('-Action','Set','-TaskId','task-topic-lines','-WorkspaceKey',$workspaceKey,'-FocusId','recall-main','-FocusLabel','Recall quality main line','-TopicKeys','objective-judge','-PrioritySource','explicit_user','-PriorityReason','user selected objective scoring','-NextAction','run the objective judge','-AssistantCommitment','finish objective scoring','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId','task-topic-lines','-WorkspaceKey',$workspaceKey,'-FocusId','continuity-side','-FocusLabel','Plan continuity side branch','-TopicKeys','topic-affinity','-NextAction','verify topic affinity','-AssistantCommitment','finish continuity repair','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $active = Invoke-Contract @('-Action','ObserveUser','-TaskId','task-topic-lines','-WorkspaceKey',$workspaceKey,'-UserInstruction','topic-affinity must remain precise','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $active.exitCode | Should Be 0
    $active.value.latestMessageClassification.topicAffinity | Should Be 'active'
    $active.value.latestMessageClassification.confidence | Should Be 'high'
    $active.value.workLineStatus.userView.main.label | Should Be 'Recall quality main line'
    $active.value.workLineStatus.userView.current.label | Should Be 'Plan continuity side branch'
    $active.value.workLineStatus.activePlan.nextAction | Should Be 'verify topic affinity'
    $active.value.workLineStatus.mainPlan.nextAction | Should Be 'run the objective judge'
    @($active.value.workLineStatus.priorityOrder).Count | Should Be 2
    $active.value.workLineStatus.priorityOrder[0].focusId | Should Be 'continuity-side'
    $active.value.workLineStatus.priorityOrder[1].focusId | Should Be 'recall-main'

    $parent = Invoke-Contract @('-Action','ObserveUser','-TaskId','task-topic-lines','-WorkspaceKey',$workspaceKey,'-UserInstruction','objective-judge scoring still needs review','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $parent.exitCode | Should Be 0
    $parent.value.latestMessageClassification.topicAffinity | Should Be 'suspended:recall-main'
    $parent.value.latestMessageClassification.targetLineId | Should Be 'recall-main'
    $parent.value.latestMessageClassification.recommendedInstructionMode | Should Be 'resume_parent'
  }

  It 'fails closed when topic affinity is ambiguous' {
    $stateRoot = Join-Path $TestDrive 'topic-affinity-ambiguous'
    $workspaceKey = 'ws-e22222222222222222222222'
    (Invoke-Contract @('-Action','Set','-TaskId','task-topic-ambiguous','-WorkspaceKey',$workspaceKey,'-FocusId','main-line','-TopicKeys','shared-anchor','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId','task-topic-ambiguous','-WorkspaceKey',$workspaceKey,'-FocusId','side-line','-TopicKeys','shared-anchor','-NextAction','finish side','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $observed = Invoke-Contract @('-Action','ObserveUser','-TaskId','task-topic-ambiguous','-WorkspaceKey',$workspaceKey,'-UserInstruction','shared-anchor needs another check','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $guarded = Invoke-Contract @('-Action','Guard','-TaskId','task-topic-ambiguous','-WorkspaceKey',$workspaceKey,'-ProposedWorkId','side-line','-StateRoot',$stateRoot,'-Json')

    $observed.value.latestMessageClassification.topicAffinity | Should Be 'ambiguous'
    $observed.value.latestMessageClassification.needsClarification | Should Be $true
    @($observed.value.latestMessageClassification.candidateLineIds).Count | Should Be 2
    $observed.value.workLineStatus.requiresUserDisambiguation | Should Be $true
    $guarded.exitCode | Should Be 1
    $guarded.value.code | Should Be 'EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'
  }

  It 'keeps direct Set unresolved for unknown or ambiguous affinity until an explicit plan mapping' {
    $stateRoot = Join-Path $TestDrive 'topic-affinity-direct-set'
    $workspaceKey = 'ws-e23232323232323232323232'
    $taskId = 'task-topic-direct-set'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','main-line','-TopicKeys','shared-anchor','-NextAction','DIRECT_MAIN_ACTION_SENTINEL','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','side-line','-TopicKeys','shared-anchor','-NextAction','DIRECT_SIDE_ACTION_SENTINEL','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    foreach ($instruction in @('shared-anchor needs another check','a completely unmapped instruction')) {
      $updated = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-LatestUserInstruction',$instruction,'-StateRoot',$stateRoot,'-Json')
      $resolved = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
      $guarded = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ProposedWorkId','side-line','-StateRoot',$stateRoot,'-Json')
      $updated.exitCode | Should Be 0
      $updated.value.needsReconciliation | Should Be $true
      $resolved.value.actionAuthorization | Should Be 'withheld'
      $resolved.value.resumeFrom | Should Match 'pending_reconciliation|topic_unresolved'
      $guarded.exitCode | Should Be 1
      (($resolved.value | ConvertTo-Json -Depth 12).Contains('DIRECT_MAIN_ACTION_SENTINEL')) | Should Be $false
      (($resolved.value | ConvertTo-Json -Depth 12).Contains('DIRECT_SIDE_ACTION_SENTINEL')) | Should Be $false
    }

    $reconciled = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','side-line','-NextAction','explicitly reconciled side action','-StateRoot',$stateRoot,'-Json')
    $allowed = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ProposedWorkId','side-line','-StateRoot',$stateRoot,'-Json')
    $reconciled.exitCode | Should Be 0
    $reconciled.value.needsReconciliation | Should Be $false
    $reconciled.value.latestMessageClassification.confidence | Should Be 'high'
    $allowed.exitCode | Should Be 0
  }

  It 'keeps a partial branch plan recoverable and restores it when reopened' {
    $stateRoot = Join-Path $TestDrive 'partial-branch-plan'
    $workspaceKey = 'ws-e33333333333333333333333'
    (Invoke-Contract @('-Action','Set','-TaskId','task-partial-plan','-WorkspaceKey',$workspaceKey,'-FocusId','main-line','-FocusLabel','Main line','-TopicKeys','main-anchor','-NextAction','finish main action','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId','task-partial-plan','-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','side-line','-FocusLabel','Side line','-TopicKeys','side-anchor','-NextAction','finish side action','-AssistantCommitment','retain side evidence','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId','task-partial-plan','-WorkspaceKey',$workspaceKey,'-BranchStatus','partial','-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 0
    @($resumed.value.unfinishedWorkPlans).Count | Should Be 1
    $resumed.value.workLineStatus.unfinishedPlans[0].focusId | Should Be 'side-line'
    $resumed.value.workLineStatus.unfinishedPlans[0].nextAction | Should Be 'finish side action'

    $reopened = Invoke-Contract @('-Action','Set','-TaskId','task-partial-plan','-WorkspaceKey',$workspaceKey,'-FocusId','side-line','-InstructionMode','side_branch','-StateRoot',$stateRoot,'-Json')
    $reopened.exitCode | Should Be 0
    $reopened.value.nextAction | Should Be 'finish side action'
    $reopened.value.focusLabel | Should Be 'Side line'
    $reopened.value.returnTo.focusId | Should Be 'main-line'
    @($reopened.value.unfinishedWorkPlans).Count | Should Be 0
  }

  It 'preserves the real active line when visible conversation wins' {
    $stateRoot = Join-Path $TestDrive 'visible-line-identity'
    $workspaceKey = 'ws-e44444444444444444444444'
    (Invoke-Contract @('-Action','Set','-TaskId','task-visible-line','-WorkspaceKey',$workspaceKey,'-FocusId','real-active-line','-FocusLabel','Real active line','-TopicKeys','active-anchor','-NextAction','continue real action','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId','task-visible-line','-WorkspaceKey',$workspaceKey,'-VisibleUserInstruction','active-anchor needs adjustment','-VisibleAssistantCommitment','apply the visible adjustment','-StateRoot',$stateRoot,'-Json')

    $resolved.exitCode | Should Be 0
    $resolved.value.resumeFrom | Should Be 'visible_conversation'
    $resolved.value.resolutionSource | Should Be 'visible_conversation'
    $resolved.value.focusId | Should Be 'real-active-line'
    $resolved.value.workLineStatus.activeLine | Should Be 'real-active-line'
    $resolved.value.workLineStatus.activePlan.focusLabel | Should Be 'Real active line'
    $resolved.value.nextAction | Should Be 'apply the visible adjustment'
  }

  It 'blocks parent resumption when the bound parent plan is missing' {
    $stateRoot = Join-Path $TestDrive 'missing-parent-plan'
    $workspaceKey = 'ws-e55555555555555555555555'
    (Invoke-Contract @('-Action','Set','-TaskId','task-missing-parent','-WorkspaceKey',$workspaceKey,'-FocusId','parent-line','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId','task-missing-parent','-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','side-line','-NextAction','finish side','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId','task-missing-parent','-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 1
    $resumed.value.code | Should Be 'EXECUTION_CONTRACT_PARENT_PLAN_MISSING'
    $resumed.value.parentFocusId | Should Be 'parent-line'
  }

  It 'hash-isolates colliding task ids and refuses an ambiguous implicit task' {
    $stateRoot = Join-Path $TestDrive 'task-id-collision'
    $workspaceKey = 'ws-e66666666666666666666666'
    $first = Invoke-Contract @('-Action','Set','-TaskId','task/a','-WorkspaceKey',$workspaceKey,'-FocusId','first-line','-NextAction','first action','-StateRoot',$stateRoot,'-Json')
    $second = Invoke-Contract @('-Action','Set','-TaskId','task:a','-WorkspaceKey',$workspaceKey,'-FocusId','second-line','-NextAction','second action','-StateRoot',$stateRoot,'-Json')
    $firstGet = Invoke-Contract @('-Action','Get','-TaskId','task/a','-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    $secondGet = Invoke-Contract @('-Action','Get','-TaskId','task:a','-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    $ambiguous = Invoke-Contract @('-Action','Resolve','-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')

    $first.exitCode | Should Be 0
    $second.exitCode | Should Be 0
    $first.value.path | Should Not Be $second.value.path
    $firstGet.value.focusId | Should Be 'first-line'
    $secondGet.value.focusId | Should Be 'second-line'
    $ambiguous.exitCode | Should Be 1
    $ambiguous.value.code | Should Be 'EXECUTION_CONTRACT_TASK_AMBIGUOUS'
    @($ambiguous.value.candidateTaskIds).Count | Should Be 2
  }

  It 'isolates the same task id across workspaces for set get resolve and clear' {
    $stateRoot = Join-Path $TestDrive 'same-task-two-workspaces'
    $taskId = 'task-shared-id'
    $workspaceA = 'ws-a11111111111111111111111'
    $workspaceB = 'ws-b22222222222222222222222'
    $setA = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceA,'-FocusId','workspace-a-line','-NextAction','continue workspace A','-StateRoot',$stateRoot,'-Json')
    $setB = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceB,'-FocusId','workspace-b-line','-NextAction','continue workspace B','-StateRoot',$stateRoot,'-Json')

    $setA.exitCode | Should Be 0
    $setB.exitCode | Should Be 0
    $setA.value.path | Should Not Be $setB.value.path
    (Split-Path -Parent $setA.value.path) | Should Be (Join-Path $stateRoot 'workspace\runtime-state\execution-contracts')
    (Split-Path -Parent $setB.value.path) | Should Be (Join-Path $stateRoot 'workspace\runtime-state\execution-contracts')
    @(Get-ChildItem -LiteralPath (Split-Path -Parent $setA.value.path) -Filter '*.json' -File).Count | Should Be 2

    (Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceA,'-StateRoot',$stateRoot,'-Json')).value.focusId | Should Be 'workspace-a-line'
    (Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceB,'-StateRoot',$stateRoot,'-Json')).value.focusId | Should Be 'workspace-b-line'
    (Invoke-Contract @('-Action','Resolve','-WorkspaceKey',$workspaceA,'-StateRoot',$stateRoot,'-Json')).value.focusId | Should Be 'workspace-a-line'
    (Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceB,'-StateRoot',$stateRoot,'-Json')).value.focusId | Should Be 'workspace-b-line'

    (Invoke-Contract @('-Action','Clear','-TaskId',$taskId,'-WorkspaceKey',$workspaceA,'-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $missingA = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceA,'-StateRoot',$stateRoot,'-Json')
    $remainingB = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceB,'-StateRoot',$stateRoot,'-Json')
    $missingA.exitCode | Should Be 1
    $missingA.value.code | Should Be 'EXECUTION_CONTRACT_NOT_FOUND'
    $remainingB.exitCode | Should Be 0
    $remainingB.value.focusId | Should Be 'workspace-b-line'
  }

  It 'reads and migrates a task-only contract only for its exact workspace' {
    $stateRoot = Join-Path $TestDrive 'legacy-task-only-contract'
    $workspace = Join-Path $stateRoot 'workspace'
    $workspaceA = 'ws-a33333333333333333333333'
    $workspaceB = 'ws-b44444444444444444444444'
    $taskId = 'task-legacy-scoped'
    $legacyPath = Join-Path $workspace 'runtime-state\execution-contracts\task-legacy-scoped.json'
    $version = [string](Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Write-TestJson $legacyPath ([pscustomobject]@{
      ok=$true; schema='super-brain.execution-contract.v1'; taskId=$taskId; workspaceKey=$workspaceA; packageVersion=$version; revision=1; status='active';
      focusId='legacy-a-line'; focusLabel='Legacy A line'; instructionMode='continue'; returnStack=@(); completedWorkLines=@(); unfinishedWorkLines=@(); unfinishedWorkPlans=@();
      latestUserInstruction=''; assistantCommitment='continue legacy A'; nextAction='continue legacy A'; constraints=@(); topicKeys=@('legacy-anchor'); topicKeySource='explicit';
      prioritySource='current_contract'; priorityReason='legacy contract'; invalidatedWorkItems=@(); acceptanceCriteria=@(); needsReconciliation=$false; updatedAt=(Get-Date).ToString('o')
    })

    $wrongGet = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceB,'-StateRoot',$stateRoot,'-Json')
    $wrongClear = Invoke-Contract @('-Action','Clear','-TaskId',$taskId,'-WorkspaceKey',$workspaceB,'-StateRoot',$stateRoot,'-Json')
    $rightGet = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceA,'-StateRoot',$stateRoot,'-Json')
    $wrongGet.exitCode | Should Be 1
    $wrongClear.exitCode | Should Be 1
    $wrongClear.value.code | Should Be 'EXECUTION_CONTRACT_IDENTITY_MISMATCH'
    (Test-Path -LiteralPath $legacyPath) | Should Be $true
    $rightGet.exitCode | Should Be 1
    $rightGet.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_UNBOUND'

    $migrated = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceA,'-SessionKey','legacy-migration-session','-RebindSession','-FocusId','legacy-a-line','-NextAction','continue migrated A','-StateRoot',$stateRoot,'-Json')
    $migrated.exitCode | Should Be 0
    $migrated.value.path | Should Not Be $legacyPath
    (Test-Path -LiteralPath $migrated.value.path) | Should Be $true
    (Test-Path -LiteralPath $legacyPath) | Should Be $false
  }

  It 'assigns explicit Chinese and English continuation lines before binding bare continue' {
    $stateRoot = Join-Path $TestDrive 'explicit-continuation-line'
    $workspaceKey = 'ws-a55555555555555555555555'
    $taskId = 'task-explicit-continuation'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','objective-main','-FocusLabel','Objective judge main line','-TopicKeys','objective-judge','-NextAction','finish objective judge','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','continuity-side','-FocusLabel','Continuity side line','-TopicKeys','continuity-fix','-NextAction','finish continuity fix','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $continueWord = -join (@(0x7EE7,0x7EED) | ForEach-Object { [char]$_ })
    $mainLineWord = -join (@(0x4E3B,0x7EBF) | ForEach-Object { [char]$_ })
    $nextStepWord = -join (@(0x4E0B,0x4E00,0x6B65) | ForEach-Object { [char]$_ })
    $proceedNextStepWord = -join (@(0x8FDB,0x884C,0x4E0B,0x4E00,0x6B65) | ForEach-Object { [char]$_ })
    $chinese = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction',($continueWord + $mainLineWord + ' objective-judge'),'-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $english = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction','continue the main line objective-judge','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $bareEnglish = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction','continue','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $bareChinese = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction',$continueWord,'-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $bareNextStep = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction',$nextStepWord,'-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $bareProceedNextStep = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction',$proceedNextStepWord,'-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $unrelatedShortMessage = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction','hello','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')

    $chinese.value.latestMessageClassification.targetLineId | Should Be 'objective-main'
    $chinese.value.latestMessageClassification.topicAffinity | Should Be 'suspended:objective-main'
    $english.value.latestMessageClassification.targetLineId | Should Be 'objective-main'
    $english.value.latestMessageClassification.topicAffinity | Should Be 'suspended:objective-main'
    $bareEnglish.value.latestMessageClassification.targetLineId | Should Be 'continuity-side'
    @($bareEnglish.value.latestMessageClassification.matchedKeys) | Should Be @('continuation_signal')
    $bareChinese.value.latestMessageClassification.targetLineId | Should Be 'continuity-side'
    $bareNextStep.value.latestMessageClassification.targetLineId | Should Be 'continuity-side'
    $bareNextStep.value.latestMessageClassification.confidence | Should Be 'high'
    $bareProceedNextStep.value.latestMessageClassification.targetLineId | Should Be 'continuity-side'
    $unrelatedShortMessage.value.latestMessageClassification.mode | Should Be 'unclassified'
  }

  It 'matches Latin topic keys on token boundaries' {
    $stateRoot = Join-Path $TestDrive 'latin-topic-boundary'
    $workspaceKey = 'ws-a66666666666666666666666'
    $taskId = 'task-latin-boundary'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','short-key-main','-TopicKeys','ai','-NextAction','finish AI line','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','boundary-side','-TopicKeys','continuity-anchor','-NextAction','finish side line','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $insideWord = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction','maintenance changed','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $token = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction','AI needs review','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $insideWord.value.latestMessageClassification.topicAffinity | Should Be 'unknown'
    @($insideWord.value.latestMessageClassification.candidateLineIds).Count | Should Be 0
    $token.value.latestMessageClassification.targetLineId | Should Be 'short-key-main'
    $token.value.latestMessageClassification.topicAffinity | Should Be 'suspended:short-key-main'
  }

  It 'isolates automatic prompt observation by root Codex session and requires explicit rebind' {
    $stateRoot = Join-Path $TestDrive 'root-session-isolation'
    $workspaceKey = 'ws-a67676767676767676767676'
    $taskId = 'task-root-session-isolation'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-session-a','-FocusId','session-owned-line','-NextAction','finish session owned work','-StateRoot',$stateRoot,'-Json')
    $created.exitCode | Should Be 0
    $created.value.sessionBound | Should Be $true
    $created.value.ownerSessionKey | Should Match '^sid-[0-9a-f]{24}$'
    ($created.text.Contains('root-session-a')) | Should Be $false

    $oldThreadId = $env:CODEX_THREAD_ID
    try {
      Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue
      $missingKeySet = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','session-owned-line','-NextAction','bypass without session key','-StateRoot',$stateRoot,'-Json')
      $missingKeyGet = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    } finally {
      if ($null -eq $oldThreadId) { Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue } else { $env:CODEX_THREAD_ID = $oldThreadId }
    }
    $missingKeySet.exitCode | Should Be 1
    $missingKeySet.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_REQUIRED'
    $missingKeySet.text.Contains('bypass without session key') | Should Be $false
    $missingKeyGet.exitCode | Should Be 1
    $missingKeyGet.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_REQUIRED'

    $sameSession = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-session-a','-UserInstruction','continue session owned work','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $sameSession.exitCode | Should Be 0
    $sameSession.value.needsReconciliation | Should Be $true
    $revision = [int]$sameSession.value.revision

    $foreign = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-session-b','-UserInstruction','replace this from another chat','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $foreign.exitCode | Should Be 1
    $foreign.value.code | Should Be 'EXECUTION_CONTRACT_FOREIGN_SESSION'
    $foreignGet = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-session-b','-StateRoot',$stateRoot,'-Json')
    $foreignGet.exitCode | Should Be 1
    $foreignGet.value.code | Should Be 'EXECUTION_CONTRACT_FOREIGN_SESSION'
    $foreignGet.text.Contains('finish session owned work') | Should Be $false
    $unchanged = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-session-a','-StateRoot',$stateRoot,'-Json')
    [int]$unchanged.value.revision | Should Be $revision
    $unchanged.value.latestUserInstruction | Should Be 'continue session owned work'

    $implicitForeign = Invoke-Contract @('-Action','ObserveUser','-WorkspaceKey',$workspaceKey,'-SessionKey','root-session-b','-UserInstruction','implicit foreign prompt','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $implicitForeign.exitCode | Should Be 1
    $implicitForeign.value.code | Should Be 'EXECUTION_CONTRACT_NOT_FOUND'

    $blockedRebind = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-session-b','-FocusId','session-owned-line','-NextAction','continue after recovery','-StateRoot',$stateRoot,'-Json')
    $blockedRebind.exitCode | Should Be 1
    $blockedRebind.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_REBIND_REQUIRED'
    $rebound = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-session-b','-RebindSession','-FocusId','session-owned-line','-NextAction','continue after explicit recovery','-StateRoot',$stateRoot,'-Json')
    $rebound.exitCode | Should Be 0
    $rebound.value.ownerSessionKey | Should Not Be $created.value.ownerSessionKey
    $rebound.value.nextAction | Should Be 'continue after explicit recovery'
  }

  It 'projects an unbound legacy contract without executable actions and blocks mutation' {
    $stateRoot = Join-Path $TestDrive 'unbound-session-projection'
    $workspaceKey = 'ws-a67676767676767676767676'
    $taskId = 'task-unbound-session'
    $sentinel = 'UNBOUND_ACTION_MUST_NOT_LEAK'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','legacy-owner','-FocusId','legacy-line','-NextAction',$sentinel,'-AssistantCommitment','UNBOUND_COMMITMENT_MUST_NOT_LEAK','-StateRoot',$stateRoot,'-Json')
    $created.exitCode | Should Be 0
    $legacy = Get-Content -LiteralPath $created.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $legacy.PSObject.Properties.Remove('ownerSessionKey')
    $legacy.sessionBound = $false
    Write-TestJson $created.value.path $legacy

    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','new-root-session','-StateRoot',$stateRoot,'-Json')
    $guard = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','new-root-session','-ProposedWorkId','legacy-line','-StateRoot',$stateRoot,'-Json')
    $oldThreadId = $env:CODEX_THREAD_ID
    try {
      Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue
      $noKeyResolve = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
      $noKeyGuard = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ProposedWorkId','legacy-line','-StateRoot',$stateRoot,'-Json')
      $noKeyGet = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    } finally {
      if ($null -eq $oldThreadId) { Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue } else { $env:CODEX_THREAD_ID = $oldThreadId }
    }

    $resolved.exitCode | Should Be 0
    $resolved.value.sessionAccess | Should Be 'unbound'
    $resolved.value.actionAuthorization | Should Be 'withheld'
    $resolved.value.claimAllowed | Should Be $false
    (($resolved.value | ConvertTo-Json -Depth 12).Contains($sentinel)) | Should Be $false
    (($resolved.value | ConvertTo-Json -Depth 12).Contains('UNBOUND_COMMITMENT_MUST_NOT_LEAK')) | Should Be $false
    $guard.exitCode | Should Be 1
    $guard.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_UNBOUND'
    $noKeyResolve.value.sessionAccess | Should Be 'unbound'
    $noKeyResolve.value.actionAuthorization | Should Be 'withheld'
    $noKeyGuard.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_UNBOUND'
    $noKeyGet.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_UNBOUND'
  }

  It 'bounds partial unfinished plans to the twelve most recent branches and caps contract size' {
    $stateRoot = Join-Path $TestDrive 'bounded-unfinished-plans'
    $workspaceKey = 'ws-a77777777777777777777777'
    $taskId = 'task-bounded-unfinished'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','main-line','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    foreach ($index in 1..15) {
      (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId',('partial-' + $index),'-NextAction',('finish partial ' + $index),'-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
      (Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-BranchStatus','partial','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    }

    $current = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    $current.exitCode | Should Be 0
    @($current.value.unfinishedWorkLines).Count | Should Be 12
    @($current.value.unfinishedWorkPlans).Count | Should Be 12
    $current.value.unfinishedWorkPlans[0].focusId | Should Be 'partial-4'
    $current.value.unfinishedWorkPlans[-1].focusId | Should Be 'partial-15'
    (@($current.value.unfinishedWorkPlans.focusId) -contains 'partial-1') | Should Be $false
    ((Get-Item -LiteralPath $current.value.path).Length -lt 65536) | Should Be $true
  }

  It 'orders unfinished branches after the active line and nearest suspended parent in the user view' {
    $stateRoot = Join-Path $TestDrive 'unfinished-user-view-priority'
    $workspaceKey = 'ws-a88888888888888888888888'
    $taskId = 'task-unfinished-priority'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','main-line','-FocusLabel','Main line','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    foreach ($sideId in @('older-partial','recent-partial')) {
      (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId',$sideId,'-FocusLabel',$sideId,'-NextAction',('finish ' + $sideId),'-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
      (Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-BranchStatus','partial','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    }
    $active = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','active-side','-FocusLabel','Active side','-NextAction','finish active side','-StateRoot',$stateRoot,'-Json')

    $active.exitCode | Should Be 0
    @($active.value.workLineStatus.priorityOrder).Count | Should Be 4
    $active.value.workLineStatus.priorityOrder[0].focusId | Should Be 'active-side'
    $active.value.workLineStatus.priorityOrder[0].executionRank | Should Be 1
    $active.value.workLineStatus.priorityOrder[1].focusId | Should Be 'main-line'
    $active.value.workLineStatus.priorityOrder[1].executionRank | Should Be 2
    $active.value.workLineStatus.priorityOrder[2].focusId | Should Be 'recent-partial'
    $active.value.workLineStatus.priorityOrder[2].role | Should Be 'unfinished_branch'
    $active.value.workLineStatus.priorityOrder[3].focusId | Should Be 'older-partial'
    @($active.value.workLineStatus.userView.unfinished).Count | Should Be 2
    $active.value.workLineStatus.userView.unfinished[0].focusId | Should Be 'recent-partial'
    $active.value.workLineStatus.userView.unfinished[0].executionRank | Should Be 3
  }

  It 'keeps contract plans canonical across dashboard snapshot restore and smart-next' {
    $stateRoot = Join-Path $TestDrive 'continuity-consumers'
    $workspace = Join-Path $stateRoot 'workspace'
    $workspaceKey = 'ws-e77777777777777777777777'
    Write-TestJson (Join-Path $workspace 'last-status-snapshot.json') ([pscustomobject]@{workspaceKey='ws-foreignforeignforeign000000';nextAction='foreign snapshot action';checkedAt=(Get-Date).ToString('o')})
    Write-TestJson (Join-Path $workspace 'skill-capability-map.json') ([pscustomobject]@{schema='super-brain.skill-capability-map.v1';capabilities=@()})
    (Invoke-Contract @('-Action','Set','-TaskId','task-consumers','-WorkspaceKey',$workspaceKey,'-FocusId','main-line','-FocusLabel','Main line','-TopicKeys','main-anchor','-NextAction','main exact action','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId','task-consumers','-WorkspaceKey',$workspaceKey,'-FocusId','side-line','-FocusLabel','Side line','-TopicKeys','side-anchor','-NextAction','side exact action','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $dashboardRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\super-brain-dashboard.ps1') -WorkspaceKey $workspaceKey -Json 2>$null)
      $dashboard = (($dashboardRaw -join "`n") | ConvertFrom-Json)
      $dashboard.nextAction | Should Be 'side exact action'
      $dashboard.nextAction | Should Not Match 'foreign'
      $dashboard.workLineStatus.mainPlan.focusId | Should Be 'main-line'
      $dashboard.workLineStatus.activePlan.focusId | Should Be 'side-line'

      $snapshotRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\status-snapshot-writer.ps1') -WorkspaceKey $workspaceKey -NextAction 'generic maintenance action' -Json 2>$null)
      $snapshot = (($snapshotRaw -join "`n") | ConvertFrom-Json)
      $snapshot.nextAction | Should Be 'side exact action'
      $snapshot.nextActionSource | Should Be 'execution_contract'
      (Test-Path -LiteralPath $snapshot.scopedSnapshotPath) | Should Be $true
      (Test-Path -LiteralPath $snapshot.scopedStatusCardPath) | Should Be $true
      ((Get-Item -LiteralPath $snapshot.scopedSnapshotPath).Length -lt 7000) | Should Be $true
      ((Get-Item -LiteralPath $snapshot.scopedStatusCardPath).Length -lt 3500) | Should Be $true

      (Invoke-Contract @('-Action','ObserveUser','-TaskId','task-consumers','-WorkspaceKey',$workspaceKey,'-UserInstruction','side-anchor needs another change','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
      $restoreRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\session-restore.ps1') -Query 'continue' -TaskId 'task-consumers' -WorkspaceKey $workspaceKey -Json 2>$null)
      $restore = (($restoreRaw -join "`n") | ConvertFrom-Json)
      $restore.executionResolution.needsConfirmation | Should Be $true
      $restore.nextAction | Should Match '^Reconcile the latest user instruction'
      $restore.nextAction | Should Not Be 'side exact action'
      $restore.recoveryPoint.workLineStatus.activePlan.focusId | Should Be 'side-line'

      $smartRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\smart-next.ps1') -Workspace $workspaceKey -Json 'side-anchor still belongs here' 2>$null)
      $smart = (($smartRaw -join "`n") | ConvertFrom-Json)
      $smart.executionResolution.focusId | Should Be 'side-line'
      $smart.latestMessageClassification.topicAffinity | Should Be 'active'
      $smart.latestMessageClassification.confidence | Should Be 'high'
      $smart.workLineMutationAuthorized | Should Be $false
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'rejects foreign generic status memory when a task-scoped plan is missing' {
    $stateRoot = Join-Path $TestDrive 'task-scoped-memory-fallback'
    $workspace = Join-Path $stateRoot 'workspace'
    $workspaceKey = 'ws-e88888888888888888888888'
    Write-TestJson (Join-Path $workspace 'status-card.json') ([pscustomobject]@{workspaceKey='ws-foreignforeignforeign000001';nextAction='foreign generic action';continuity=[pscustomobject]@{taskId='foreign-task'}})
    (Invoke-Contract @('-Action','Set','-TaskId','task-plan-missing','-WorkspaceKey',$workspaceKey,'-FocusId','missing-plan-line','-TopicKeys','missing-anchor','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $restoreRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\session-restore.ps1') -Query 'continue' -TaskId 'task-plan-missing' -WorkspaceKey $workspaceKey -Json 2>$null)
      $restore = (($restoreRaw -join "`n") | ConvertFrom-Json)
      $restore.recoveryPoint.planAvailable | Should Be $false
      $restore.recoveryPoint.memoryFallback | Should Be 'task_and_workspace_scoped_evidence_missing'
      $restore.nextAction | Should Match 'Task-and-workspace-scoped plan evidence is missing'
      $restore.nextAction | Should Not Match 'foreign generic action'
      @($restore.evidenceCards).Count | Should Be 0
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
    }
  }

  It 'does not let visible commitments bypass foreign unbound or missing session ownership' {
    $stateRoot = Join-Path $TestDrive 'visible-session-bypass'
    $workspaceKey = 'ws-f10101010101010101010101'
    $taskId = 'task-visible-session-bypass'
    $oldAction = 'FOREIGN_OLD_ACTION_MUST_NOT_LEAK'
    $visibleBypass = 'VISIBLE_COMMITMENT_MUST_NOT_AUTHORIZE'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-owner-a','-FocusId','owned-line','-NextAction',$oldAction,'-StateRoot',$stateRoot,'-Json')
    $created.exitCode | Should Be 0

    $foreign = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-owner-b','-VisibleUserInstruction','continue owned line','-VisibleAssistantCommitment',$visibleBypass,'-StateRoot',$stateRoot,'-Json')
    $foreign.value.actionAuthorization | Should Be 'withheld'
    $foreign.value.claimAllowed | Should Be $false
    $foreign.value.assistantCommitment | Should BeNullOrEmpty
    $foreign.value.nextAction | Should Match 'Session ownership'
    $foreign.text.Contains($oldAction) | Should Be $false
    $foreign.text.Contains($visibleBypass) | Should Be $false

    $unbound = Get-Content -LiteralPath $created.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $unbound.PSObject.Properties.Remove('ownerSessionKey')
    $unbound.sessionBound = $false
    Write-TestJson $created.value.path $unbound
    $unboundResolve = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-owner-b','-VisibleUserInstruction','continue owned line','-VisibleAssistantCommitment',$visibleBypass,'-StateRoot',$stateRoot,'-Json')
    $unboundResolve.value.sessionAccess | Should Be 'unbound'
    $unboundResolve.value.actionAuthorization | Should Be 'withheld'
    $unboundResolve.text.Contains($visibleBypass) | Should Be $false

    $oldThreadId = $env:CODEX_THREAD_ID
    try {
      Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue
      $missingSession = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-VisibleUserInstruction','continue owned line','-VisibleAssistantCommitment',$visibleBypass,'-StateRoot',$stateRoot,'-Json')
    } finally {
      if ($null -eq $oldThreadId) { Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue } else { $env:CODEX_THREAD_ID = $oldThreadId }
    }
    $missingSession.value.actionAuthorization | Should Be 'withheld'
    $missingSession.text.Contains($visibleBypass) | Should Be $false
  }

  It 'requires concrete bound focus and action values to clear reconciliation' {
    $stateRoot = Join-Path $TestDrive 'empty-explicit-reconciliation'
    $workspaceKey = 'ws-f20202020202020202020202'
    $taskId = 'task-empty-explicit-reconciliation'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-empty-map','-FocusId','mapped-line','-TopicKeys','mapped-anchor','-NextAction','finish mapped work','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $observed = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-empty-map','-UserInstruction','mapped-anchor needs a follow-up','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $observed.value.needsReconciliation | Should Be $true
    $observed.value.latestMessageClassification.topicAffinity | Should Be 'active'
    $observed.value.latestMessageClassification.confidence | Should Be 'high'

    $emptyMappingRaw = @(& $contractScript -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey 'root-empty-map' -InstructionMode continue -FocusId '' -NextAction '' -StateRoot $stateRoot -NoExit -Json)
    $emptyMapping = (($emptyMappingRaw -join "`n") | ConvertFrom-Json)
    $guarded = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-empty-map','-ProposedWorkId','mapped-line','-StateRoot',$stateRoot,'-Json')
    $emptyMapping.ok | Should Be $true
    $emptyMapping.needsReconciliation | Should Be $true
    $guarded.exitCode | Should Be 1
    $guarded.value.code | Should Be 'EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'
  }

  It 'does not resume a parent through an unresolved active branch' {
    $stateRoot = Join-Path $TestDrive 'resume-parent-reconciliation-gate'
    $workspaceKey = 'ws-f30303030303030303030303'
    $taskId = 'task-resume-parent-reconciliation-gate'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-parent-gate','-FocusId','parent-line','-NextAction','finish parent','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-parent-gate','-InstructionMode','side_branch','-FocusId','side-line','-NextAction','finish side','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-parent-gate','-UserInstruction','unmapped interruption','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-parent-gate','-BranchStatus','completed','-CompletionEvidence','must not bypass','-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 1
    $resumed.value.code | Should Be 'EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'
    $resumed.text.Contains('finish parent') | Should Be $false
  }

  It 'treats visible context as non-authorizing for missing contracts and blocks invalid contracts' {
    $stateRoot = Join-Path $TestDrive 'visible-missing-invalid-contract'
    $workspaceKey = 'ws-f31313131313131313131313'
    $visibleBypass = 'MISSING_OR_INVALID_VISIBLE_COMMITMENT'
    $missing = Invoke-Contract @('-Action','Resolve','-TaskId','task-visible-missing','-WorkspaceKey',$workspaceKey,'-SessionKey','root-visible-missing','-VisibleUserInstruction','continue missing task','-VisibleAssistantCommitment',$visibleBypass,'-StateRoot',$stateRoot,'-Json')
    $missing.exitCode | Should Be 0
    $missing.value.resolutionSource | Should Be 'none'
    $missing.value.actionAuthorization | Should Be 'not_applicable'
    $missing.value.claimAllowed | Should Be $true
    $missing.value.needsConfirmation | Should Be $false
    $missing.value.nextAction | Should BeNullOrEmpty
    $missing.value.assistantCommitment | Should BeNullOrEmpty
    $missing.text.Contains($visibleBypass) | Should Be $false

    $created = Invoke-Contract @('-Action','Set','-TaskId','task-visible-invalid','-WorkspaceKey',$workspaceKey,'-SessionKey','root-visible-invalid','-FocusId','invalid-line','-NextAction','INVALID_STORED_ACTION','-StateRoot',$stateRoot,'-Json')
    $invalid = Get-Content -LiteralPath $created.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $invalid.status = 'inactive'
    Write-TestJson $created.value.path $invalid
    $invalidResolve = Invoke-Contract @('-Action','Resolve','-TaskId','task-visible-invalid','-WorkspaceKey',$workspaceKey,'-SessionKey','root-visible-invalid','-VisibleUserInstruction','continue invalid task','-VisibleAssistantCommitment',$visibleBypass,'-StateRoot',$stateRoot,'-Json')
    $invalidResolve.value.actionAuthorization | Should Be 'withheld'
    $invalidResolve.value.claimAllowed | Should Be $false
    $invalidResolve.value.nextAction | Should Match 'stale or invalid'
    $invalidResolve.text.Contains('INVALID_STORED_ACTION') | Should Be $false
    $invalidResolve.text.Contains($visibleBypass) | Should Be $false
  }

  It 'does not resume a parent from a missing classification or blank instruction' {
    $stateRoot = Join-Path $TestDrive 'resume-parent-missing-classification'
    $workspaceKey = 'ws-f32323232323232323232323'
    $taskId = 'task-resume-parent-missing-classification'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-missing-classification','-FocusId','parent-line','-NextAction','finish parent','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $side = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-missing-classification','-InstructionMode','side_branch','-FocusId','side-line','-NextAction','finish side','-StateRoot',$stateRoot,'-Json')
    $tampered = Get-Content -LiteralPath $side.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $tampered.PSObject.Properties.Remove('latestMessageClassification')
    $tampered.latestUserInstruction = ''
    $tampered.needsReconciliation = $false
    Write-TestJson $side.value.path $tampered

    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-missing-classification','-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 1
    $resumed.value.code | Should Be 'EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'
    $resumed.text.Contains('finish parent') | Should Be $false
  }

  It 'requires the owner session before clearing a legacy task-only contract' {
    $stateRoot = Join-Path $TestDrive 'legacy-clear-session-gate'
    $workspaceKey = 'ws-f40404040404040404040404'
    $taskId = 'task-legacy-clear-session-gate'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-clear-owner','-FocusId','legacy-clear-line','-NextAction','finish legacy clear work','-StateRoot',$stateRoot,'-Json')
    $legacyPath = Join-Path $stateRoot 'workspace\runtime-state\execution-contracts\task-legacy-clear-session-gate.json'
    Write-TestJson $legacyPath (Get-Content -LiteralPath $created.value.path -Raw -Encoding UTF8 | ConvertFrom-Json)
    Remove-Item -LiteralPath $created.value.path -Force
    Remove-Item -LiteralPath (Join-Path $stateRoot 'workspace\last-execution-contract.json') -Force

    $foreignClear = Invoke-Contract @('-Action','Clear','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-clear-foreign','-StateRoot',$stateRoot,'-Json')
    $foreignClear.exitCode | Should Be 1
    $foreignClear.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_REBIND_REQUIRED'
    (Test-Path -LiteralPath $legacyPath) | Should Be $true

    $ownerClear = Invoke-Contract @('-Action','Clear','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-clear-owner','-StateRoot',$stateRoot,'-Json')
    $ownerClear.exitCode | Should Be 0
    (Test-Path -LiteralPath $legacyPath) | Should Be $false
  }

  It 'requires the owner session before clearing a pointer-only contract' {
    $stateRoot = Join-Path $TestDrive 'pointer-clear-session-gate'
    $workspaceKey = 'ws-f41414141414141414141414'
    $taskId = 'task-pointer-clear-session-gate'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-pointer-owner','-FocusId','pointer-line','-NextAction','finish pointer work','-StateRoot',$stateRoot,'-Json')
    $pointerPath = Join-Path $stateRoot 'workspace\last-execution-contract.json'
    Remove-Item -LiteralPath $created.value.path -Force

    $foreignClear = Invoke-Contract @('-Action','Clear','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-pointer-foreign','-StateRoot',$stateRoot,'-Json')
    $foreignClear.exitCode | Should Be 1
    $foreignClear.value.code | Should Be 'EXECUTION_CONTRACT_SESSION_REBIND_REQUIRED'
    (Test-Path -LiteralPath $pointerPath) | Should Be $true

    $ownerClear = Invoke-Contract @('-Action','Clear','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-pointer-owner','-StateRoot',$stateRoot,'-Json')
    $ownerClear.exitCode | Should Be 0
    (Test-Path -LiteralPath $pointerPath) | Should Be $false
  }

  It 'ignores a foreign current-context pointer during implicit observation' {
    $stateRoot = Join-Path $TestDrive 'foreign-context-implicit-observation'
    $workspaceKey = 'ws-f50505050505050505050505'
    $taskId = 'task-foreign-context-implicit-observation'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-context-owner','-FocusId','owner-line','-NextAction','finish owner line','-StateRoot',$stateRoot,'-Json')
    Write-TestJson (Join-Path $stateRoot 'workspace\current-task-context.json') ([pscustomobject]@{status='active';taskId=$taskId;workspaceKey=$workspaceKey})

    $implicit = Invoke-Contract @('-Action','ObserveUser','-WorkspaceKey',$workspaceKey,'-SessionKey','root-context-foreign','-UserInstruction','ordinary unrelated work','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $implicit.exitCode | Should Be 1
    $implicit.value.code | Should Be 'EXECUTION_CONTRACT_NOT_FOUND'
    $implicit.value.foreignContextDetected | Should Be $true
    $unchanged = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','root-context-owner','-StateRoot',$stateRoot,'-Json')
    [int]$unchanged.value.revision | Should Be ([int]$created.value.revision)
  }

  It 'treats a successful implicit no-contract resolution as nonblocking and non-authorizing' {
    $stateRoot = Join-Path $TestDrive 'implicit-no-contract'
    $workspaceKey = 'ws-f60606060606060606060606'
    $resolved = Invoke-Contract @('-Action','Resolve','-WorkspaceKey',$workspaceKey,'-SessionKey','root-no-contract','-StateRoot',$stateRoot,'-Json')
    $resolved.exitCode | Should Be 0
    $resolved.value.resolutionSource | Should Be 'none'
    $resolved.value.actionAuthorization | Should Be 'not_applicable'
    $resolved.value.claimAllowed | Should Be $true
    $resolved.value.needsConfirmation | Should Be $false
    $resolved.value.nextAction | Should BeNullOrEmpty
  }
}
