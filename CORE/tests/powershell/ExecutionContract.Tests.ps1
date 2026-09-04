$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
. (Join-Path $PSScriptRoot 'H7TestFixture.ps1')

function Write-TestJson([string]$Path,[object]$Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function Invoke-Contract([string[]]$Arguments) {
  return Invoke-H7FixtureContractScript $contractScript $root $Arguments
}

function ConvertTo-TestReturnCardList([object[]]$Items) {
  return @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
}

function Get-TestReturnCardFingerprintV1([object]$Card,[string]$TaskId,[string]$WorkspaceKey,[string[]]$Lineage) {
  # v1 intentionally predates retained merge dossiers; keep this fixture stable for migration coverage.
  $payload = [ordered]@{
    taskId = [string]$TaskId
    workspaceKey = [string]$WorkspaceKey
    lineage = @($Lineage)
    focusId = [string]$Card.focusId
    focusLabel = [string]$Card.focusLabel
    nextAction = [string]$Card.nextAction
    assistantCommitment = [string]$Card.assistantCommitment
    constraints = @(ConvertTo-TestReturnCardList @($Card.constraints))
    acceptanceCriteria = @(ConvertTo-TestReturnCardList @($Card.acceptanceCriteria))
    currentPhase = [string]$Card.currentPhase
    currentStep = [string]$Card.currentStep
    completedSteps = @(ConvertTo-TestReturnCardList @($Card.completedSteps))
    pendingSteps = @(ConvertTo-TestReturnCardList @($Card.pendingSteps))
    blockers = @(ConvertTo-TestReturnCardList @($Card.blockers))
    evidence = @(ConvertTo-TestReturnCardList @($Card.evidence))
    verificationResults = @(ConvertTo-TestReturnCardList @($Card.verificationResults))
    topicKeys = @($Card.topicKeys)
    topicKeySource = [string]$Card.topicKeySource
    prioritySource = [string]$Card.prioritySource
    priorityReason = [string]$Card.priorityReason
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 8 -Compress))
    return -join ($sha.ComputeHash($bytes)[0..7] | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha.Dispose()
  }
}

Describe 'Execution contract continuity' {
  It 'writes contract, transition, and continuation timestamps in UTC' {
    $stateRoot = Join-Path $TestDrive 'utc-contract-timestamps'
    $set = Invoke-Contract @(
      '-Action','Set','-TaskId','task-utc-timestamps','-WorkspaceKey','ws-utc111111111111111111111','-SessionKey','sid-utc111111111111111111111',
      '-FocusId','utc-clock','-NextAction','verify timestamp authority','-TransitionId','utc-timestamp-regression','-StateRoot',$stateRoot,'-Json'
    )

    $set.exitCode | Should Be 0
    ([DateTimeOffset]::Parse([string]$set.value.updatedAt)).Offset.TotalMinutes | Should Be 0
    ([DateTimeOffset]::Parse([string]$set.value.lastTransition.recordedAt)).Offset.TotalMinutes | Should Be 0
    ([DateTimeOffset]::Parse([string]$set.value.continuationReceipt.createdAt)).Offset.TotalMinutes | Should Be 0
  }

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

  It 'preserves current progress and the last confirmed receipt when only next action changes' {
    $stateRoot = Join-Path $TestDrive 'preserve-current-progress'
    $workspaceKey = 'ws-preserve-current-progress-20260723'
    $taskId = 'task-preserve-current-progress'
    $initial = Invoke-Contract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,
      '-FocusId','phase-eight','-InstructionMode','continue',
      '-AssistantCommitment','old commitment must not replace the confirmed receipt',
      '-NextAction','run the transport probe',
      '-CurrentPhase','Phase 8','-CurrentStep','inspect the failed transport receipt',
      '-LastConfirmedSentence','the previous probe returned HTTP 502',
      '-LastConfirmedSource','checkpoint_summary',
      '-StateRoot',$stateRoot,'-Json'
    )
    $initial.exitCode | Should Be 0

    $updated = Invoke-Contract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,
      '-FocusId','phase-eight','-InstructionMode','continue',
      '-LatestUserInstruction','continue the active Phase 8 investigation',
      '-NextAction','inspect the local proxy logs',
      '-ExpectedRevision',[string]$initial.value.revision,
      '-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,
      '-TransitionId','preserve-current-progress-next-action',
      '-StateRoot',$stateRoot,'-Json'
    )

    $updated.exitCode | Should Be 0
    $updated.value.currentStep | Should Be 'inspect the failed transport receipt'
    $updated.value.continuityStateCard.currentStep | Should Be 'inspect the failed transport receipt'
    $updated.value.nextAction | Should Be 'inspect the local proxy logs'
    $updated.value.lastConfirmedSentence | Should Be 'the previous probe returned HTTP 502'
    # H7 visible-progress receipts are assistant-visible by construction;
    # legacy checkpoint_summary is no longer an authorizing source.
    $updated.value.lastConfirmedSource | Should Be 'assistant_visible_reply'
    $updated.value.needsReconciliation | Should Be $false
  }

  It 'treats a serialized empty return stack as empty on the next mutation' {
    $stateRoot = Join-Path $TestDrive 'empty-return-stack-next-mutation'
    $workspaceKey = 'ws-empty-return-stack-20260819'
    $taskId = 'task-empty-return-stack-next-mutation'

    $initial = Invoke-Contract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,
      '-FocusId','empty-stack-focus','-InstructionMode','continue',
      '-NextAction','publish the current checkpoint',
      '-StateRoot',$stateRoot,'-Json'
    )
    $initial.exitCode | Should Be 0
    @($initial.value.returnStack).Count | Should Be 0

    $updated = Invoke-Contract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,
      '-FocusId','empty-stack-focus','-InstructionMode','continue',
      '-NextAction','complete the closeout',
      '-ExpectedRevision',[string]$initial.value.revision,
      '-ExpectedPlanFingerprint',[string]$initial.value.planReceipt.planFingerprint,
      '-TransitionId','empty-return-stack-next-mutation',
      '-StateRoot',$stateRoot,'-Json'
    )

    $updated.exitCode | Should Be 0
    @($updated.value.returnStack).Count | Should Be 0
    $updated.value.nextAction | Should Be 'complete the closeout'
  }

  It 'keeps singleton evidence and checklist entries inside the durable continuation receipt' {
    $stateRoot = Join-Path $TestDrive 'singleton-continuation-receipt'
    $workspaceKey = 'ws-singleton-continuation-20260728'
    $sessionKey = 'sid-singleton-continuation-20260728'
    $taskId = 'task-singleton-continuation'
    $set = Invoke-Contract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','verify the current P4 evidence',
      '-CurrentPhase','P4','-CurrentStep','verify one evidence receipt','-CompletedSteps','P3',
      '-PendingSteps','P4','-Evidence','fixture:singleton-proof','-NextAction','finish P4',
      '-StateRoot',$stateRoot,'-Json'
    )
    $set.exitCode | Should Be 0

    $runtime = Join-Path $root 'runtime\brain_control.py'
    $request = [ordered]@{ taskId=$taskId; workspaceKey=[string]$set.value.workspaceKey; ownerSessionKey=[string]$set.value.ownerSessionKey }
    $payload = $request | ConvertTo-Json -Depth 4 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $raw = @(& python -X utf8 $runtime --state-root $stateRoot get-continuation-receipt --request-base64 $encoded 2>$null)
    $receipt = (($raw -join "`n") | ConvertFrom-Json)

    $receipt.ok | Should Be $true
    $receipt.available | Should Be $true
    @($receipt.receipt.state.completedSteps) | Should Be @('P3')
    @($receipt.receipt.state.pendingSteps) | Should Be @('P4')
    (@($receipt.receipt.state.evidence) -contains 'fixture:singleton-proof') | Should Be $true
  }

  It 'keeps an additive active checklist complete across continuation, compaction, and parent return' {
    $stateRoot = Join-Path $TestDrive 'active-checklist-additive'
    $workspaceKey = 'ws-active-checklist-202607200000'
    $sessionKey = 'sid-active-checklist-202607200000'
    $taskId = 'task-active-checklist-additive'
    $base = @('-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-InstructionMode','continue','-StateRoot',$stateRoot,'-Json')

    $initial = Invoke-Contract (@('-Action','Set') + $base + @('-LatestUserInstruction','confirm A through G','-NextAction','A','-PendingSteps','A','B','C','D','E','F','G'))
    $afterH = Invoke-Contract (@('-Action','Set') + $base + @('-LatestUserInstruction','also add H','-NextAction','A','-PendingSteps','H'))
    $afterI = Invoke-Contract (@('-Action','Set') + $base + @('-LatestUserInstruction','also add I','-NextAction','A','-PendingSteps','I'))
    $afterComplete = Invoke-Contract (@('-Action','Set') + $base + @('-LatestUserInstruction','A is complete; continue the current plan','-NextAction','B','-CompletedSteps','A'))

    $initial.exitCode | Should Be 0
    $afterH.exitCode | Should Be 0
    $afterI.exitCode | Should Be 0
    $afterComplete.exitCode | Should Be 0
    @($afterI.value.pendingSteps) | Should Be @('A','B','C','D','E','F','G','H','I')
    @($afterComplete.value.completedSteps) | Should Be @('A')
    @($afterComplete.value.pendingSteps) | Should Be @('B','C','D','E','F','G','H','I')
    @($afterComplete.value.continuityStateCard.activeChecklist | ForEach-Object { $_.status + ':' + $_.label }) | Should Be @('completed:A','pending:B','pending:C','pending:D','pending:E','pending:F','pending:G','pending:H','pending:I')
    $afterComplete.value.planReceipt.schema | Should Be 'super-brain.plan-receipt.v2'
    $afterComplete.value.planReceipt.completedStepCount | Should Be 1
    $afterComplete.value.planReceipt.pendingStepCount | Should Be 8

    $compacted = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')
    $compacted.exitCode | Should Be 0
    @($compacted.value.continuityStateCard.activeChecklist | ForEach-Object { $_.status + ':' + $_.label }) | Should Be @('completed:A','pending:B','pending:C','pending:D','pending:E','pending:F','pending:G','pending:H','pending:I')

    $side = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','side-line','-LatestUserInstruction','inspect a short side branch','-CurrentPhase','side branch','-CurrentStep','inspect side','-NextAction','inspect side','-CompletedSteps','-PendingSteps','inspect side','-StateRoot',$stateRoot,'-Json')
    $restored = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','side verified','-StateRoot',$stateRoot,'-Json')
    $side.exitCode | Should Be 0
    $side.value.returnStack[0].returnCardFingerprintVersion | Should Be 'v6'
    $restored.exitCode | Should Be 0
    @($restored.value.completedSteps) | Should Be @('A')
    @($restored.value.pendingSteps) | Should Be @('B','C','D','E','F','G','H','I')

    $added = Invoke-Contract (@('-Action','Set') + $base + @('-LatestUserInstruction','also add J','-NextAction','B','-PendingSteps','J'))
    $replaced = Invoke-Contract (@('-Action','Set') + $base + @('-LatestUserInstruction','replace the old checklist with K','-NextAction','K','-CompletedSteps','-PendingSteps','K'))
    $added.exitCode | Should Be 0
    @($added.value.pendingSteps) | Should Be @('B','C','D','E','F','G','H','I','J')
    $replaced.exitCode | Should Be 0
    $replaced.value.checklistUpdateMode | Should Be 'replace'
    @($replaced.value.pendingSteps) | Should Be @('K')
    @($replaced.value.supersededChecklistSteps) | Should Be @('A','B','C','D','E','F','G','H','I','J')
  }

  It 'does not let a caller-requested checklist replace erase accepted main-line work' {
    $stateRoot = Join-Path $TestDrive 'checklist-replace-user-authorization'
    $workspaceKey = 'ws-checklist-replace-user-auth'
    $sessionKey = 'sid-checklist-replace-user-auth'
    $taskId = 'task-checklist-replace-user-auth'
    # Keep the two-item root plan intact.  powershell.exe -File can flatten
    # string[] arguments, which would make this regression fixture test the
    # launcher quirk instead of checklist replacement authorization.
    $initialRaw = @(& $contractScript -Action Set -TaskId $taskId -WorkspaceKey $workspaceKey -SessionKey $sessionKey `
      -FocusId 'history-main' -InstructionMode continue -LatestUserInstruction 'confirm the history and P7 work' `
      -NextAction 'project history relationships' -PendingSteps @('project history relationships','P7 evidence later') `
      -StateRoot $stateRoot -Json)
    $initial = [pscustomobject]@{ exitCode=$LASTEXITCODE; value=(($initialRaw -join "`n") | ConvertFrom-Json); text=($initialRaw -join "`n") }
    $attempt = Invoke-Contract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-FocusId','history-main','-InstructionMode','continue','-ChecklistUpdateMode','replace',
      '-LatestUserInstruction','continue the active work','-NextAction','finish a short side detail','-PendingSteps','finish a short side detail',
      '-StateRoot',$stateRoot,'-Json'
    )
    $after = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')

    $initial.exitCode | Should Be 0
    $attempt.exitCode | Should Be 1
    $attempt.value.code | Should Be 'EXECUTION_CONTRACT_CHECKLIST_REPLACEMENT_USER_AUTH_REQUIRED'
    $after.exitCode | Should Be 0
    @($after.value.pendingSteps) | Should Be @('project history relationships','P7 evidence later')
    $after.value.nextAction | Should Be 'project history relationships'
  }

  It 'preserves the matching assistant progress receipt when a newer instruction blocks restore' {
    $stateRoot = Join-Path $TestDrive 'assistant-progress-receipt-restore'
    $workspaceKey = 'ws-assistant-progress-202607280001'
    $sessionKey = 'sid-assistant-progress-202607280001'
    $progressTaskId = 'task-progress-receipt'
    $otherTaskId = 'task-other-receipt'
    $workspace = Join-Path $stateRoot 'workspace'
    $escapedContractScript = $contractScript.Replace("'", "''")
    $escapedStateRoot = $stateRoot.Replace("'", "''")
    $progressCommand = "& '$escapedContractScript' -Action Set -TaskId '$progressTaskId' -WorkspaceKey '$workspaceKey' -SessionKey '$sessionKey' -FocusId 'canonical-main' -InstructionMode continue -LatestUserInstruction 'confirm A through G' -CurrentPhase 'P0' -CurrentStep 'A is complete; B through G remain.' -LastConfirmedSentence 'A is complete; B through G remain.' -LastConfirmedSource 'assistant_commitment' -NextAction 'execute B through G in order' -CompletedSteps @('A') -PendingSteps @('B','C','D','E','F','G') -StateRoot '$escapedStateRoot' -Json"
    $progressRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $progressCommand 2>$null)
    $progress = [pscustomobject]@{exitCode=$LASTEXITCODE;value=(($progressRaw -join "`n") | ConvertFrom-Json);text=($progressRaw -join "`n")}
    $other = Invoke-Contract @('-Action','Set','-TaskId',$otherTaskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','other-main','-InstructionMode','continue','-LatestUserInstruction','inspect the unrelated other task','-CurrentPhase','P9','-CurrentStep','other task is at P9','-LastConfirmedSentence','other task is at P9','-LastConfirmedSource','assistant_commitment','-NextAction','run unrelated other action','-StateRoot',$stateRoot,'-Json')
    $observed = Invoke-Contract @('-Action','ObserveUser','-TaskId',$progressTaskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-UserInstruction','also add H and I; do not replace A through G','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $version = [string](Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
    Write-TestJson (Join-Path $workspace "runtime-state\checkpoints\active\$progressTaskId.json") ([pscustomobject]@{status='active';taskId=$progressTaskId;workspaceKey=$workspaceKey;version=$version;currentPhase='P0';currentStep='stale checkpoint';nextAction='repeat stale checkpoint action';timestamp=(Get-Date).AddMinutes(-5).ToString('o')})

    $progress.exitCode | Should Be 0
    $other.exitCode | Should Be 0
    $observed.exitCode | Should Be 0

    $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $oldWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $stateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $workspaceKey
      $restoreRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\session-restore.ps1') -Query 'continue' -WorkspaceKey $workspaceKey -SessionKey $sessionKey -Json 2>$null)
      $restore = (($restoreRaw -join "`n") | ConvertFrom-Json)
      $foreignRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\session-restore.ps1') -Query 'continue' -WorkspaceKey $workspaceKey -SessionKey 'sid-foreign-progress-202607280001' -Json 2>$null)
      $foreign = (($foreignRaw -join "`n") | ConvertFrom-Json)

      $restore.recoveryPoint.taskId | Should Be $progressTaskId
      $restore.instructionAnchor.latestUserInstruction | Should Be 'also add H and I; do not replace A through G'
      $restore.continuationReceipt.taskId | Should Be $progressTaskId
      $restore.resumeReceipt.state | Should Be 'reconcile_newest_instruction_preserve_assistant_progress'
      $restore.resumeReceipt.assistantProgress.state | Should Be 'newer_instruction_pending'
      $restore.resumeReceipt.assistantProgress.lastConfirmedSentence | Should Be 'A is complete; B through G remain.'
      $restore.resumeReceipt.assistantProgress.currentPhase | Should Be 'P0'
      @($restore.resumeReceipt.assistantProgress.pendingSteps) | Should Be @('B','C','D','E','F','G')
      $restore.executionResolution.actionAuthorization | Should Be 'withheld'
      $restore.nextAction | Should Match '^Reconcile the latest user instruction'
      $restore.nextAction | Should Not Match 'stale checkpoint|execute B through G|unrelated other'
      $restore.continuationReceipt.state.nextAction | Should BeNullOrEmpty
      ($restore | ConvertTo-Json -Depth 12 -Compress) | Should Not Match 'repeat stale checkpoint action|run unrelated other action'

      $foreign.resumeReceipt.assistantProgress.available | Should Be $false
      ($foreign | ConvertTo-Json -Depth 12 -Compress) | Should Not Match 'A is complete; B through G remain.|execute B through G'
    } finally {
      if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
      if ($null -eq $oldWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspaceKey }
    }
  }

  It 'does not fabricate a pending step for an explicit no-automatic-action closure' {
    $stateRoot = Join-Path $TestDrive 'closed-contract-card'
    $workspaceKey = 'ws-242424242424242424242424'
    $escapedContractScript = $contractScript.Replace("'", "''")
    $escapedStateRoot = $stateRoot.Replace("'", "''")
    $closureCommand = "& '$escapedContractScript' -Action Set -TaskId 'task-closed-card' -WorkspaceKey '$workspaceKey' -SessionKey 'closure-card-session' -FocusId 'closure-focus' -NextAction 'No automatic action: closure is complete.' -CurrentPhase 'closure complete' -CurrentStep 'verification recorded' -PendingSteps @() -StateRoot '$escapedStateRoot' -Json"
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $closureCommand 2>$null)
    $exitCode = $LASTEXITCODE
    $closed = (($raw -join "`n") | ConvertFrom-Json)

    $exitCode | Should Be 0
    @($closed.pendingSteps).Count | Should Be 0
    @($closed.continuityStateCard.pendingSteps).Count | Should Be 0
    $closed.continuityStateCard.currentStep | Should Be 'verification recorded'
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

    $resolved.value.resumeFrom | Should Be 'execution_contract_instruction_anchor_pending'
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
    $side.value.workLineStatus.lineageDepth | Should Be 1
    @($side.value.workLineStatus.lineage).Count | Should Be 2
    $side.value.workLineStatus.lineage[0].focusId | Should Be 'parent-focus'
    $side.value.workLineStatus.lineage[1].parentFocusId | Should Be 'parent-focus'
    $side.value.workLineStatus.userView.directParent.focusId | Should Be 'parent-focus'
    @($side.value.continuityStateCard.lineage).Count | Should Be 2
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

  It 'restores every approved root item after a side branch instead of collapsing the mainline to P7' {
    $stateRoot = Join-Path $TestDrive 'root-pending-survives-side-branch'
    $workspaceKey = 'ws-979898979898979898989898'
    $taskId = 'task-root-pending-survives-side-branch'
    $sessionKey = 'sid-979898979898979898989898'
    $rootPending = @(
      'HISTORY_CANDIDATE_PROJECTION_SENTINEL',
      'STAR_MAP_RELATION_PROJECTION_SENTINEL',
      'P7_EVIDENCE_LATER_SENTINEL'
    )

    $rootArguments = @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-InstructionMode','continue','-FocusId','super-brain-autonomous-recall','-FocusLabel','Super Brain autonomous recall',
      '-CurrentPhase','mainline','-CurrentStep',$rootPending[0],'-NextAction',$rootPending[0],
      '-ChecklistUpdateMode','replace','-PendingSteps'
    )
    $rootArguments += $rootPending
    $rootArguments += @('-StateRoot',$stateRoot,'-Json')
    $rootResult = Invoke-Contract $rootArguments
    $rootResult.exitCode | Should Be 0
    $rootResult.value.ok | Should Be $true
    @($rootResult.value.pendingSteps) | Should Be $rootPending

    $side = Invoke-Contract @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-InstructionMode','side_branch','-FocusId','status-answer','-FocusLabel','Status answer',
      '-NextAction','answer the inserted status question','-PendingSteps','answer the inserted status question',
      '-StateRoot',$stateRoot,'-NoExit','-Json'
    )
    $side.exitCode | Should Be 0
    $side.value.focusId | Should Be 'status-answer'
    @($side.value.returnStack).Count | Should Be 1

    $resumed = Invoke-Contract @(
      '-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
      '-BranchStatus','completed','-CompletionEvidence','status answer delivered and verified',
      '-StateRoot',$stateRoot,'-NoExit','-Json'
    )
    $resumed.exitCode | Should Be 0
    $resumed.value.focusId | Should Be 'super-brain-autonomous-recall'
    $resumed.value.nextAction | Should Be $rootPending[0]
    @($resumed.value.pendingSteps) | Should Be $rootPending
    @($resumed.value.returnStack).Count | Should Be 0
    $resumed.value.workLineStatus.mainLine | Should Be 'super-brain-autonomous-recall'
    $resumed.value.workLineStatus.activeLine | Should Be 'super-brain-autonomous-recall'
    @($resumed.value.workLineStatus.activeWorkPackage.checklist | Where-Object { $_.status -eq 'pending' } | ForEach-Object { $_.label }) | Should Be $rootPending
    $resumed.value.nextAction | Should Not Match 'P7_EVIDENCE_LATER_SENTINEL'
  }

  It 'preserves a root-to-current hierarchy for nested branches and resumes one parent at a time' {
    $stateRoot = Join-Path $TestDrive 'nested-branch-lineage'
    $workspaceKey = 'ws-989898989898989898989898'
    (Invoke-Contract @('-Action','Set','-TaskId','task-nested','-WorkspaceKey',$workspaceKey,'-FocusId','root-main','-FocusLabel','Root main','-NextAction','continue root plan','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId','task-nested','-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','git-parent','-FocusLabel','Git parent','-NextAction','finish git parent','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $nested = Invoke-Contract @('-Action','Set','-TaskId','task-nested','-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','hierarchy-child','-FocusLabel','Hierarchy child','-NextAction','repair nested hierarchy','-StateRoot',$stateRoot,'-Json')
    $nested.exitCode | Should Be 0
    $nested.value.workLineStatus.mainLine | Should Be 'root-main'
    $nested.value.workLineStatus.activeLine | Should Be 'hierarchy-child'
    $nested.value.workLineStatus.currentLineCount | Should Be 3
    $nested.value.workLineStatus.lineageLineCount | Should Be 3
    $nested.value.workLineStatus.unfinishedLineCount | Should Be 0
    $nested.value.workLineStatus.userView.currentLineCount | Should Be 3
    $nested.value.workLineStatus.lineageDepth | Should Be 2
    @($nested.value.workLineStatus.lineage).Count | Should Be 3
    @($nested.value.workLineStatus.userView.path) | Should Be @('Root main','Git parent','Hierarchy child')
    $nested.value.workLineStatus.lineage[0].depth | Should Be 0
    $nested.value.workLineStatus.lineage[0].childFocusId | Should Be 'git-parent'
    $nested.value.workLineStatus.lineage[1].parentFocusId | Should Be 'root-main'
    $nested.value.workLineStatus.lineage[1].childFocusId | Should Be 'hierarchy-child'
    $nested.value.workLineStatus.lineage[2].parentFocusId | Should Be 'git-parent'
    $nested.value.workLineStatus.userView.directParent.focusId | Should Be 'git-parent'
    @($nested.value.continuityStateCard.lineage).Count | Should Be 3
    $nested.value.continuityStateCard.currentLineCount | Should Be 3

    $cycle = Invoke-Contract @('-Action','Set','-TaskId','task-nested','-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','root-main','-NextAction','incorrectly reopen root as child','-StateRoot',$stateRoot,'-Json')
    $cycle.exitCode | Should Be 1
    $cycle.value.code | Should Be 'EXECUTION_CONTRACT_ANCESTOR_REENTRY_REQUIRES_RESUME'

    $toGit = Invoke-Contract @('-Action','ResumeParent','-TaskId','task-nested','-WorkspaceKey',$workspaceKey,'-BranchStatus','completed','-CompletionEvidence','nested hierarchy verified','-StateRoot',$stateRoot,'-Json')
    $toGit.exitCode | Should Be 0
    $toGit.value.focusId | Should Be 'git-parent'
    $toGit.value.workLineStatus.lineageDepth | Should Be 1
    $toGit.value.workLineStatus.userView.directParent.focusId | Should Be 'root-main'

    $gitReconciled = Invoke-Contract @('-Action','Set','-TaskId','task-nested','-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','git-parent','-NextAction','finish git parent','-StateRoot',$stateRoot,'-Json')
    $gitReconciled.exitCode | Should Be 0
    $gitReconciled.value.focusId | Should Be 'git-parent'

    $toRoot = Invoke-Contract @('-Action','ResumeParent','-TaskId','task-nested','-WorkspaceKey',$workspaceKey,'-BranchStatus','completed','-CompletionEvidence','git parent verified','-StateRoot',$stateRoot,'-Json')
    $toRoot.exitCode | Should Be 0
    $toRoot.value.focusId | Should Be 'root-main'
    $toRoot.value.workLineStatus.lineageDepth | Should Be 0
    $toRoot.value.workLineStatus.userView.directParent | Should BeNullOrEmpty
  }

  It 'requires a current plan receipt after a newer observed instruction' {
    $stateRoot = Join-Path $TestDrive 'plan-receipt-freshness'
    $workspaceKey = 'ws-979797979797979797979797'
    $set = Invoke-Contract @('-Action','Set','-TaskId','task-plan-receipt','-WorkspaceKey',$workspaceKey,'-FocusId','accepted-plan','-NextAction','execute accepted plan','-StateRoot',$stateRoot,'-Json')
    $set.exitCode | Should Be 0
    $set.value.planReceiptRequired | Should Be $true
    $set.value.planReceipt.contractRevision | Should Be $set.value.revision
    $set.value.planReceipt.focusId | Should Be 'accepted-plan'
    $set.value.planReceipt.planFingerprint | Should Not BeNullOrEmpty

    $observed = Invoke-Contract @('-Action','ObserveUser','-TaskId','task-plan-receipt','-WorkspaceKey',$workspaceKey,'-UserInstruction','use the newer approved plan','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $observed.exitCode | Should Be 0
    # Fast observation appends an instruction anchor without mutating the
    # contract. The resolver, not the observed projection, must withhold work.
    $observed.value.planReceipt.contractRevision | Should Be $set.value.planReceipt.contractRevision
    $observed.value.revision | Should Be $set.value.revision
    $pending = Invoke-Contract @('-Action','Resolve','-TaskId','task-plan-receipt','-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    $pending.value.actionAuthorization | Should Be 'withheld'
    $pending.value.resumeFrom | Should Be 'execution_contract_instruction_anchor_pending'

    $reconciled = Invoke-Contract @('-Action','Set','-TaskId','task-plan-receipt','-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','accepted-plan','-LatestUserInstruction','use the newer approved plan','-NextAction','execute the newer accepted plan','-ExpectedRevision',$set.value.revision,'-ExpectedPlanFingerprint',$set.value.planReceipt.planFingerprint,'-TransitionId','plan-receipt-reconcile','-StateRoot',$stateRoot,'-Json')
    $reconciled.exitCode | Should Be 0

    $tampered = Get-Content -LiteralPath $reconciled.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $tampered.needsReconciliation = $false
    $tampered.latestMessageClassification = [pscustomobject]@{mode='continue';topicAffinity='active';targetLineId='accepted-plan';targetLineLabel='accepted-plan';confidence='high';matchedKeys=@('explicit_instruction_mode');candidateLineIds=@('accepted-plan');needsClarification=$false;recommendedInstructionMode='continue';reason='test';rawInstructionStored=$false}
    $tampered.planReceipt.contractRevision = [int]$tampered.revision - 1
    Write-TestJson $reconciled.value.path $tampered

    $blocked = Invoke-Contract @('-Action','Guard','-TaskId','task-plan-receipt','-WorkspaceKey',$workspaceKey,'-ProposedWorkId','accepted-plan','-StateRoot',$stateRoot,'-Json')
    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PLAN_RECEIPT_STALE'

    $repaired = Invoke-Contract @('-Action','Set','-TaskId','task-plan-receipt','-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','accepted-plan','-LatestUserInstruction','use the newer approved plan','-NextAction','execute the newer accepted plan','-StateRoot',$stateRoot,'-Json')
    $repaired.exitCode | Should Be 0
    $repaired.value.planReceipt.contractRevision | Should Be $repaired.value.revision
    (Invoke-Contract @('-Action','Guard','-TaskId','task-plan-receipt','-WorkspaceKey',$workspaceKey,'-ProposedWorkId','accepted-plan','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
  }

  It 'removes an explicit active focus from stale invalidation history' {
    $stateRoot = Join-Path $TestDrive 'explicit-focus-revival'
    $workspaceKey = 'ws-969696969696969696969696'
    $revived = Invoke-Contract @('-Action','Set','-TaskId','task-revival','-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','revived-main','-NextAction','continue the explicitly revived main line','-InvalidatedWorkItems','revived-main','-StateRoot',$stateRoot,'-Json')
    $revived.exitCode | Should Be 0
    @($revived.value.invalidatedWorkItems) -contains 'revived-main' | Should Be $false
    (Invoke-Contract @('-Action','Guard','-TaskId','task-revival','-WorkspaceKey',$workspaceKey,'-ProposedWorkId','revived-main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
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

    $reopened = Invoke-Contract @('-Action','Set','-TaskId','task-partial-plan','-WorkspaceKey',$workspaceKey,'-FocusId','side-line','-InstructionMode','side_branch','-NextAction','finish side action','-StateRoot',$stateRoot,'-Json')
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
    $reconciled = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','continuity-side','-LatestUserInstruction','explicit main-line reference reviewed; remain on continuity side','-NextAction','finish continuity fix','-StateRoot',$stateRoot,'-Json')
    $bareEnglish = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction','continue','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $bareChinese = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction',$continueWord,'-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $bareNextStep = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction',$nextStepWord,'-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $bareProceedNextStep = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction',$proceedNextStepWord,'-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')
    $unrelatedShortMessage = Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-UserInstruction','hello','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')

    $chinese.value.latestMessageClassification.targetLineId | Should Be 'objective-main'
    $chinese.value.latestMessageClassification.topicAffinity | Should Be 'suspended:objective-main'
    $english.value.latestMessageClassification.targetLineId | Should Be 'objective-main'
    $english.value.latestMessageClassification.topicAffinity | Should Be 'suspended:objective-main'
    $reconciled.exitCode | Should Be 0
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

    $oldThreadId = $env:SUPER_BRAIN_LOCAL_SESSION_ID
    try {
      Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue
      $missingKeySet = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','session-owned-line','-NextAction','bypass without session key','-StateRoot',$stateRoot,'-Json')
      $missingKeyGet = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    } finally {
      if ($null -eq $oldThreadId) { Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $oldThreadId }
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
    $oldThreadId = $env:SUPER_BRAIN_LOCAL_SESSION_ID
    try {
      Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue
      $noKeyResolve = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
      $noKeyGuard = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ProposedWorkId','legacy-line','-StateRoot',$stateRoot,'-Json')
      $noKeyGet = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    } finally {
      if ($null -eq $oldThreadId) { Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $oldThreadId }
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
      $dashboard.workLineStatus.currentLineCount | Should Be 2
      @($dashboard.workLineStatus.activePath).Count | Should Be 2
      $dashboard.workLineStatus.userView.path[0] | Should Be 'Main line'
      $dashboard.workLineStatus.userView.directParent.focusId | Should Be 'main-line'

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

    $oldThreadId = $env:SUPER_BRAIN_LOCAL_SESSION_ID
    try {
      Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue
      $missingSession = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-VisibleUserInstruction','continue owned line','-VisibleAssistantCommitment',$visibleBypass,'-StateRoot',$stateRoot,'-Json')
    } finally {
      if ($null -eq $oldThreadId) { Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $oldThreadId }
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

  It 'does not let continue change focus or jump to an ancestor' {
    $stateRoot = Join-Path $TestDrive 'continue-focus-gate'
    $workspaceKey = 'ws-f70707070707070707070707'
    $taskId = 'task-continue-focus-gate'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','root-line','-NextAction','finish root','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','child-line','-NextAction','finish child','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $jump = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','root-line','-NextAction','jump to root','-StateRoot',$stateRoot,'-Json')
    $jump.exitCode | Should Be 1
    $jump.value.code | Should Be 'EXECUTION_CONTRACT_CONTINUE_FOCUS_MISMATCH'
    $jump.value.directParentFocusId | Should Be 'root-line'
  }

  It 'recomputes the current plan fingerprint before authorizing mutation' {
    $stateRoot = Join-Path $TestDrive 'plan-content-fingerprint'
    $workspaceKey = 'ws-f71717171717171717171717'
    $taskId = 'task-plan-content-fingerprint'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','fingerprint-line','-NextAction','verified action','-StateRoot',$stateRoot,'-Json')
    $tampered = Get-Content -LiteralPath $created.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $tampered.nextAction = 'tampered action at same revision'
    Write-TestJson $created.value.path $tampered

    $guarded = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ProposedWorkId','fingerprint-line','-StateRoot',$stateRoot,'-Json')
    $guarded.exitCode | Should Be 1
    $guarded.value.code | Should Be 'EXECUTION_CONTRACT_PLAN_RECEIPT_STALE'
  }

  It 'rejects a modified parent return card before resuming it' {
    $stateRoot = Join-Path $TestDrive 'return-card-fingerprint'
    $workspaceKey = 'ws-f72727272727272727272727'
    $taskId = 'task-return-card-fingerprint'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','parent-line','-NextAction','verified parent action','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $side = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','child-line','-NextAction','finish child','-StateRoot',$stateRoot,'-Json')
    $tampered = Get-Content -LiteralPath $side.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $tampered.returnStack[0].nextAction = 'modified parent action'
    Write-TestJson $side.value.path $tampered

    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 1
    $resumed.value.code | Should Be 'EXECUTION_CONTRACT_RETURN_CARD_INVALID'
    $resumed.text.Contains('modified parent action') | Should Be $false
  }

  It 'does not let a visible commitment bypass pending reconciliation' {
    $stateRoot = Join-Path $TestDrive 'visible-pending-hard-gate'
    $workspaceKey = 'ws-f73737373737373737373737'
    $taskId = 'task-visible-pending-hard-gate'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','pending-owner','-FocusId','pending-line','-NextAction','old action','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','ObserveUser','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','pending-owner','-UserInstruction','new instruction','-RequiresReconciliation','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','pending-owner','-VisibleUserInstruction','new instruction','-VisibleAssistantCommitment','pretend this reconciled it','-StateRoot',$stateRoot,'-Json')
    $guarded = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','pending-owner','-ProposedWorkId','pending-line','-StateRoot',$stateRoot,'-Json')
    $resolved.value.actionAuthorization | Should Be 'withheld'
    $resolved.value.claimAllowed | Should Be $false
    $resolved.text.Contains('pretend this reconciled it') | Should Be $false
    $guarded.value.code | Should Be 'EXECUTION_CONTRACT_RECONCILIATION_REQUIRED'
  }

  It 'does not project foreign-session work-line counts or ancestry' {
    $stateRoot = Join-Path $TestDrive 'foreign-lineage-isolation'
    $workspaceKey = 'ws-f74747474747474747474747'
    $taskId = 'task-foreign-lineage-isolation'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','lineage-owner','-FocusId','root-line','-NextAction','finish root','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','lineage-owner','-InstructionMode','side_branch','-FocusId','child-line','-NextAction','finish child','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $foreign = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey','foreign-reader','-StateRoot',$stateRoot,'-Json')
    $foreign.value.actionAuthorization | Should Be 'withheld'
    $foreign.value.focusId | Should BeNullOrEmpty
    $foreign.value.workLineStatus | Should BeNullOrEmpty
    @($foreign.value.returnStack).Count | Should Be 0
  }

  It 'replays a ResumeParent transition id without popping another level' {
    $stateRoot = Join-Path $TestDrive 'resume-parent-idempotent'
    $workspaceKey = 'ws-f75757575757575757575757'
    $taskId = 'task-resume-parent-idempotent'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','root-line','-NextAction','finish root','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','parent-line','-NextAction','finish parent','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','side_branch','-FocusId','child-line','-NextAction','finish child','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $first = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TransitionId','resume-child-once','-BranchStatus','completed','-CompletionEvidence','child verified','-StateRoot',$stateRoot,'-Json')
    $intervening = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','parent-line','-NextAction','parent progress after lost response','-StateRoot',$stateRoot,'-Json')
    $second = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TransitionId','resume-child-once','-BranchStatus','completed','-CompletionEvidence','child verified','-StateRoot',$stateRoot,'-Json')
    $conflict = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-TransitionId','resume-child-once','-BranchStatus','completed','-CompletionEvidence','different child evidence','-StateRoot',$stateRoot,'-Json')
    $first.exitCode | Should Be 0
    $intervening.exitCode | Should Be 0
    $second.exitCode | Should Be 0
    $second.value.idempotentReplay | Should Be $true
    $second.value.focusId | Should Be 'parent-line'
    [int]$second.value.revision | Should Be ([int]$intervening.value.revision)
    @($second.value.returnStack).Count | Should Be 1
    $conflict.exitCode | Should Be 1
    $conflict.value.code | Should Be 'EXECUTION_CONTRACT_TRANSITION_ID_CONFLICT'
  }

  It 'binds mutation guards to the caller observed revision and plan fingerprint' {
    $stateRoot = Join-Path $TestDrive 'caller-bound-guard'
    $workspaceKey = 'ws-f76767676767676767676767'
    $taskId = 'task-caller-bound-guard'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','bound-line','-NextAction','first action','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $observed = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','bound-line','-NextAction','second action','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0

    $stale = Invoke-Contract @('-Action','Guard','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ProposedWorkId','bound-line','-ExpectedRevision',([string]$observed.value.contractRevision),'-ExpectedPlanFingerprint',([string]$observed.value.planFingerprint),'-StateRoot',$stateRoot,'-Json')
    $stale.exitCode | Should Be 1
    $stale.value.code | Should Be 'EXECUTION_CONTRACT_REVISION_MISMATCH'
  }

  It 'enforces caller-bound revision and plan fingerprint on Set when supplied' {
    $stateRoot = Join-Path $TestDrive 'caller-bound-set'
    $workspaceKey = 'ws-f76767676767676767676768'
    $taskId = 'task-caller-bound-set'
    $first = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-FocusId','bound-line','-NextAction','first action','-StateRoot',$stateRoot,'-Json')
    $second = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','bound-line','-NextAction','second action','-ExpectedRevision',([string]$first.value.revision),'-ExpectedPlanFingerprint',([string]$first.value.planReceipt.planFingerprint),'-StateRoot',$stateRoot,'-Json')
    $staleRevision = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','bound-line','-NextAction','stale action','-ExpectedRevision',([string]$first.value.revision),'-ExpectedPlanFingerprint',([string]$first.value.planReceipt.planFingerprint),'-StateRoot',$stateRoot,'-Json')
    $wrongFingerprint = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-InstructionMode','continue','-FocusId','bound-line','-NextAction','wrong fingerprint action','-ExpectedRevision',([string]$second.value.revision),'-ExpectedPlanFingerprint','0000000000000000','-StateRoot',$stateRoot,'-Json')
    $current = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-StateRoot',$stateRoot,'-Json')

    $first.exitCode | Should Be 0
    $second.exitCode | Should Be 0
    $staleRevision.exitCode | Should Be 1
    $staleRevision.value.code | Should Be 'EXECUTION_CONTRACT_REVISION_MISMATCH'
    $wrongFingerprint.exitCode | Should Be 1
    $wrongFingerprint.value.code | Should Be 'EXECUTION_CONTRACT_PLAN_FINGERPRINT_MISMATCH'
    $current.value.nextAction | Should Be 'second action'
    [int]$current.value.revision | Should Be ([int]$second.value.revision)
  }

  It 'requires structural CAS and transition identity after a contract opts into guarded mutations' {
    $stateRoot = Join-Path $TestDrive 'structural-guard-opt-in'
    $workspaceKey = 'ws-f76767676767676767676769'
    $sessionKey = 'sid-f76767676767676767676769'
    $taskId = 'task-structural-guard-opt-in'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','root-line','-NextAction','finish root','-RequireStructuralGuards','-StateRoot',$stateRoot,'-Json')
    $continued = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','root-line','-NextAction','record ordinary progress','-StateRoot',$stateRoot,'-Json')
    $blockedSide = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','side-line','-NextAction','finish side','-StateRoot',$stateRoot,'-Json')
    $side = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','side-line','-NextAction','finish side','-ExpectedRevision',([string]$continued.value.revision),'-ExpectedPlanFingerprint',([string]$continued.value.planReceipt.planFingerprint),'-TransitionId','open-side-once','-StateRoot',$stateRoot,'-Json')
    $blockedResume = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','side verified','-StateRoot',$stateRoot,'-Json')
    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','side verified','-ExpectedRevision',([string]$side.value.revision),'-ExpectedPlanFingerprint',([string]$side.value.planReceipt.planFingerprint),'-TransitionId','resume-side-once','-StateRoot',$stateRoot,'-Json')
    $blockedClear = Invoke-Contract @('-Action','Clear','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')
    $cleared = Invoke-Contract @('-Action','Clear','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-ExpectedRevision',([string]$resumed.value.revision),'-ExpectedPlanFingerprint',([string]$resumed.value.planReceipt.planFingerprint),'-TransitionId','clear-task-once','-StateRoot',$stateRoot,'-Json')

    $created.exitCode | Should Be 0
    $created.value.structuralGuardsRequired | Should Be $true
    $continued.exitCode | Should Be 0
    $blockedSide.exitCode | Should Be 1
    $blockedSide.value.code | Should Be 'EXECUTION_CONTRACT_STRUCTURAL_GUARD_REQUIRED'
    $side.exitCode | Should Be 0
    $blockedResume.exitCode | Should Be 1
    $blockedResume.value.code | Should Be 'EXECUTION_CONTRACT_STRUCTURAL_GUARD_REQUIRED'
    $resumed.exitCode | Should Be 0
    $blockedClear.exitCode | Should Be 1
    $blockedClear.value.code | Should Be 'EXECUTION_CONTRACT_STRUCTURAL_GUARD_REQUIRED'
    $cleared.exitCode | Should Be 0
    $cleared.value.removed | Should Be $true
  }

  It 'rejects a structural retry with stale CAS after its bounded receipt is evicted' {
    $stateRoot = Join-Path $TestDrive 'structural-receipt-eviction'
    $workspaceKey = 'ws-f76767676767676767676770'
    $sessionKey = 'sid-f76767676767676767676770'
    $taskId = 'task-structural-receipt-eviction'
    $root = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','root-line','-NextAction','finish root','-RequireStructuralGuards','-StateRoot',$stateRoot,'-Json')
    $side = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','side-line','-NextAction','finish side','-ExpectedRevision',([string]$root.value.revision),'-ExpectedPlanFingerprint',([string]$root.value.planReceipt.planFingerprint),'-TransitionId','open-side-eviction','-StateRoot',$stateRoot,'-Json')
    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','side verified','-ExpectedRevision',([string]$side.value.revision),'-ExpectedPlanFingerprint',([string]$side.value.planReceipt.planFingerprint),'-TransitionId','resume-side-eviction','-StateRoot',$stateRoot,'-Json')
    $current = $resumed
    foreach ($index in 1..9) {
      $current = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','continue','-FocusId','root-line','-NextAction',("progress $index"),'-ExpectedRevision',([string]$current.value.revision),'-ExpectedPlanFingerprint',([string]$current.value.planReceipt.planFingerprint),'-TransitionId',("progress-$index"),'-StateRoot',$stateRoot,'-Json')
      $current.exitCode | Should Be 0
    }
    $retry = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','side verified','-ExpectedRevision',([string]$side.value.revision),'-ExpectedPlanFingerprint',([string]$side.value.planReceipt.planFingerprint),'-TransitionId','resume-side-eviction','-StateRoot',$stateRoot,'-Json')
    $after = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')

    $retry.exitCode | Should Be 1
    $retry.value.code | Should Be 'EXECUTION_CONTRACT_REVISION_MISMATCH'
    [int]$after.value.revision | Should Be ([int]$current.value.revision)
    $after.value.focusId | Should Be 'root-line'
    @($after.value.returnStack).Count | Should Be 0
  }

}

Describe 'Project progress truth proof' {
  It 'binds phase, completed item, live file hash, passed verification, and next action as one proof' {
    $stateRoot = Join-Path $TestDrive 'project-progress-proof'
    $projectRoot = Join-Path $TestDrive 'project-root'
    New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
    $evidencePath = Join-Path $projectRoot 'source.txt'
    [IO.File]::WriteAllText($evidencePath,'source-v1',[Text.UTF8Encoding]::new($false))
    $sha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $proofInput = [ordered]@{
      schema='super-brain.project-progress-input.v1'
      phase='Phase 15'
      currentStep='bind proof'
      completedItems=@([ordered]@{ itemKey='bind proof'; evidenceRefs=@("project:file:source.txt@sha256:$sha"); verificationIds=@('proof-test') })
      projectEvidence=@([ordered]@{ kind='project_file'; relativePath='source.txt'; sha256=$sha })
      verificationResults=@([ordered]@{ id='proof-test'; status='passed' })
      nextAction='tamper replay'
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($proofInput | ConvertTo-Json -Depth 8 -Compress)))
    $created = Invoke-Contract @(
      '-Action','Set','-TaskId','task-project-progress-proof','-WorkspaceKey','ws-project-progress-proof','-SessionKey','sid-project-progress-proof',
      '-FocusId','proof-line','-InstructionMode','continue','-CurrentPhase','Phase 15','-CurrentStep','bind proof','-CompletedSteps','bind proof',
      '-PendingSteps','tamper replay','-NextAction','tamper replay','-ProjectRoot',$projectRoot,'-ProjectProgressProofBase64',$encoded,'-StateRoot',$stateRoot,'-Json'
    )

    $created.exitCode | Should Be 0
    $created.value.projectProgressProof.state | Should Be 'current'
    $created.value.projectProgressProof.payloadHash | Should Match '^[a-f0-9]{64}$'
    $created.value.continuityStateCard.projectProgress.payloadHash | Should Be $created.value.projectProgressProof.payloadHash
    @($created.value.projectProgressProof.completedItems).Count | Should Be 1
    @($created.value.projectProgressProof.projectEvidence).Count | Should Be 1
    @($created.value.projectProgressProof.verificationResults).Count | Should Be 1

    [IO.File]::WriteAllText($evidencePath,'source-tampered',[Text.UTF8Encoding]::new($false))
    $replayed = Invoke-Contract @(
      '-Action','Set','-TaskId','task-project-progress-proof','-WorkspaceKey','ws-project-progress-proof','-SessionKey','sid-project-progress-proof',
      '-FocusId','proof-line','-InstructionMode','continue','-CurrentPhase','Phase 15','-CurrentStep','bind proof','-NextAction','tamper replay',
      '-ProjectRoot',$projectRoot,'-H7FixtureSkipCheckpoint','-StateRoot',$stateRoot,'-Json'
    )
    $replayed.exitCode | Should Be 0
    $replayed.value.projectProgressProof.state | Should Be 'withheld'
    (@($replayed.value.projectProgressProof.missing) -contains 'project_progress_proof') | Should Be $true
  }
}

Describe 'Merge dossier contract' {
  It 'retains a completed branch as a verified merge dossier and records one bounded integration' {
    $stateRoot = Join-Path $TestDrive 'merge-dossier-lifecycle'
    $workspaceKey = 'ws-f77777777777777777777777'
    $taskId = 'task-merge-dossier-lifecycle'
    $sessionKey = 'sid-f77777777777777777777777'
    $main = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-FocusLabel','Main line','-TopicKeys','main-merge-target','-NextAction','finish main','-CurrentPhase','release','-RequireStructuralGuards','-StateRoot',$stateRoot,'-Json')
    $main.exitCode | Should Be 0
    $main.value.stageKind | Should Be ''
    $side = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','ui-backend','-FocusLabel','UI backend','-TopicKeys','ui-backend','-NextAction','finish UI backend','-CompletedSteps','prototype completed','-Evidence','artifact inspected','-VerificationResults','manual test passed','-RetainForMerge','-ArtifactRefs','prototype/ui.html','-InterfaceContracts','backend API v1','-Dependencies','backend service','-VerificationSteps','verify UI API mapping','-ExpectedRevision',([string]$main.value.revision),'-ExpectedPlanFingerprint',([string]$main.value.planReceipt.planFingerprint),'-TransitionId','open-ui-backend-merge','-StateRoot',$stateRoot,'-Json')
    $side.exitCode | Should Be 0

    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','UI backend branch verified','-ExpectedRevision',([string]$side.value.revision),'-ExpectedPlanFingerprint',([string]$side.value.planReceipt.planFingerprint),'-TransitionId','resume-ui-backend-merge','-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 0
    $resumed.value.stageKind | Should Be ''
    @($resumed.value.mergeIntents).Count | Should Be 1
    $intent = $resumed.value.mergeIntents[0]
    $intent.sourceFocusId | Should Be 'ui-backend'
    $intent.targetFocusId | Should Be 'main-line'
    $intent.evidenceReadiness | Should Be 'ready'
    $intent.noReimplementation | Should Be $true
    (@($intent.artifactRefs) -contains 'prototype/ui.html') | Should Be $true
    @($resumed.value.workLineStatus.pendingMergeIntents).Count | Should Be 1

    $prepared = Invoke-Contract @('-Action','PrepareMerge','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-MergeIntentId',$intent.mergeIntentId,'-StateRoot',$stateRoot,'-Json')
    $prepared.exitCode | Should Be 0
    $prepared.value.mergeIntent.mergeIntentId | Should Be $intent.mergeIntentId
    (@($prepared.value.requiredSteps) -contains 'read_retained_branch_dossier') | Should Be $true

    $completedArgs = @('-Action','CompleteMerge','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-MergeIntentId',$intent.mergeIntentId,'-MergeIntegrationEvidence','integrated retained UI artifact through backend API v1','-ExpectedRevision',([string]$prepared.value.contractRevision),'-ExpectedPlanFingerprint',([string]$prepared.value.planFingerprint),'-TransitionId','complete-ui-backend-merge','-StateRoot',$stateRoot,'-Json')
    $completed = Invoke-Contract $completedArgs
    $replayed = Invoke-Contract $completedArgs
    $completed.exitCode | Should Be 0
    $completed.value.stageKind | Should Be ''
    (@($completed.value.mergeIntents | Where-Object { $_.mergeIntentId -eq $intent.mergeIntentId })[0].status) | Should Be 'integrated'
    (@($completed.value.mergeIntents | Where-Object { $_.mergeIntentId -eq $intent.mergeIntentId })[0].integrationEvidence) | Should Match 'retained UI artifact'
    $completed.value.workLineStatus.pendingMergeIntentCount | Should Be 0
    $replayed.exitCode | Should Be 0
    $replayed.value.idempotentReplay | Should Be $true
    [int]$replayed.value.revision | Should Be ([int]$completed.value.revision)
    (Test-Path -LiteralPath (Join-Path $stateRoot 'workspace\db\index.json') -PathType Leaf) | Should Be $false
  }

  It 'refuses a retained branch merge with incomplete evidence instead of recreating it' {
    $stateRoot = Join-Path $TestDrive 'merge-dossier-evidence-gate'
    $workspaceKey = 'ws-f78787878787878787878787'
    $taskId = 'task-merge-dossier-evidence-gate'
    $sessionKey = 'sid-f78787878787878787878787'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','unverified-branch','-TopicKeys','unverified-branch','-NextAction','finish branch','-VerificationSteps','verify branch','-RetainForMerge','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','branch says done','-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 0
    $intent = $resumed.value.mergeIntents[0]

    $prepared = Invoke-Contract @('-Action','PrepareMerge','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-MergeIntentId',$intent.mergeIntentId,'-StateRoot',$stateRoot,'-Json')
    $prepared.exitCode | Should Be 1
    $prepared.value.code | Should Be 'EXECUTION_CONTRACT_MERGE_EVIDENCE_INCOMPLETE'
    (@($prepared.value.missingEvidence) -contains 'verification_results') | Should Be $true
    $prepared.value.guard | Should Match 'Do not reimplement'
  }

  It 'removes a stale merge intent when its source branch is reopened' {
    $stateRoot = Join-Path $TestDrive 'merge-dossier-reopen'
    $workspaceKey = 'ws-f79797979797979797979797'
    $taskId = 'task-merge-dossier-reopen'
    $sessionKey = 'sid-f79797979797979797979797'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','reopen-branch','-TopicKeys','reopen-branch','-NextAction','finish branch','-Evidence','artifact checked','-RetainForMerge','-ArtifactRefs','artifact.txt','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','branch verified','-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 0
    @($resumed.value.mergeIntents).Count | Should Be 1

    $reopened = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','reopen-branch','-NextAction','continue branch with new evidence','-StateRoot',$stateRoot,'-Json')
    $reopened.exitCode | Should Be 0
    @($reopened.value.mergeIntents).Count | Should Be 0
  }

  It 'does not choose among multiple retained merge dossiers from a generic merge request' {
    $stateRoot = Join-Path $TestDrive 'merge-dossier-ambiguity'
    $workspaceKey = 'ws-f80808080808080808080808'
    $taskId = 'task-merge-dossier-ambiguity'
    $sessionKey = 'sid-f80808080808080808080808'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    foreach ($branch in @('ui-branch','backend-branch')) {
      (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId',$branch,'-TopicKeys','merge','-NextAction',('finish ' + $branch),'-Evidence',($branch + ' artifact checked'),'-RetainForMerge','-ArtifactRefs',($branch + '.txt'),'-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
      (Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence',($branch + ' verified'),'-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    }

    $resolved = Invoke-Contract @('-Action','Resolve','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-VisibleUserInstruction','merge','-StateRoot',$stateRoot,'-Json')
    $resolved.exitCode | Should Be 0
    $resolved.value.latestMessageClassification.topicAffinity | Should Be 'ambiguous'
    $resolved.value.latestMessageClassification.needsClarification | Should Be $true
    @($resolved.value.latestMessageClassification.candidateLineIds).Count | Should Be 2
    $resolved.value.actionAuthorization | Should Be 'withheld'
  }
}

Describe 'Formal phase closeout labels' {
  It 'blocks a descriptive P4-to-P5 transition until a closeout receipt exists' {
    $stateRoot = Join-Path $TestDrive 'descriptive-phase-closeout'
    $workspaceKey = 'ws-f83838383838383838383838'
    $taskId = 'task-descriptive-phase-closeout'
    $sessionKey = 'sid-f83838383838383838383838'
    $created = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-InstructionMode','continue','-CurrentPhase','P4 of 12: editable control center','-CurrentStep','finish P4 acceptance','-NextAction','finish P4 acceptance','-StateRoot',$stateRoot,'-Json')

    $created.exitCode | Should Be 0
    $renamed = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-InstructionMode','continue','-CurrentPhase','P4 of 12: visual acceptance and security boundary','-CurrentStep','finish P4 acceptance','-NextAction','finish P4 acceptance','-ExpectedRevision',[string]$created.value.revision,'-ExpectedPlanFingerprint',[string]$created.value.planReceipt.planFingerprint,'-StateRoot',$stateRoot,'-Json')
    $renamed.exitCode | Should Be 0

    $blocked = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-InstructionMode','continue','-CurrentPhase','P5 of 12: shadow migration','-CurrentStep','start P5','-NextAction','start P5','-ExpectedRevision',[string]$renamed.value.revision,'-ExpectedPlanFingerprint',[string]$renamed.value.planReceipt.planFingerprint,'-StateRoot',$stateRoot,'-Json')
    $after = Invoke-Contract @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED'
    $blocked.value.phase | Should Be 'P4'
    $blocked.value.nextPhase | Should Be 'P5'
    $after.value.revision | Should Be $renamed.value.revision
    $after.value.currentPhase | Should Be 'P4 of 12: visual acceptance and security boundary'
  }
}

Describe 'Return-card fingerprint evolution' {
  It 'accepts verified v1 cards and upgrades them to v6 while resuming the immediate parent' {
    $stateRoot = Join-Path $TestDrive 'return-card-v1-migration'
    $workspaceKey = 'ws-f81818181818181818181818'
    $taskId = 'task-return-card-v1-migration'
    $sessionKey = 'sid-f81818181818181818181818'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-FocusLabel','Main line','-TopicKeys','main-line','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','git-line','-FocusLabel','Git line','-TopicKeys','git-line','-NextAction','finish Git line','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $child = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','child-line','-FocusLabel','Child line','-TopicKeys','child-line','-NextAction','finish child line','-StateRoot',$stateRoot,'-Json')
    $child.exitCode | Should Be 0

    $contract = Get-Content -LiteralPath $child.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $lineage = @()
    foreach ($card in @($contract.returnStack)) {
      $lineage += [string]$card.focusId
      $card.returnCardFingerprintVersion = 'v1'
      $card.returnCardFingerprint = Get-TestReturnCardFingerprintV1 $card $taskId $workspaceKey $lineage
    }
    Write-TestJson $child.value.path $contract

    $resumed = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','child line verified','-StateRoot',$stateRoot,'-Json')
    $resumed.exitCode | Should Be 0
    $resumed.value.focusId | Should Be 'git-line'
    $resumed.value.returnStack[0].returnCardFingerprintVersion | Should Be 'v6'

    $main = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','Git line verified','-StateRoot',$stateRoot,'-Json')
    $main.exitCode | Should Be 0
    $main.value.focusId | Should Be 'main-line'
  }

  It 'rejects merge data that an authenticated v1 card could not have covered' {
    $stateRoot = Join-Path $TestDrive 'return-card-v1-unbound-merge'
    $workspaceKey = 'ws-f82828282828282828282828'
    $taskId = 'task-return-card-v1-unbound-merge'
    $sessionKey = 'sid-f82828282828282828282828'
    (Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-FocusId','main-line','-TopicKeys','main-line','-NextAction','finish main','-StateRoot',$stateRoot,'-Json')).exitCode | Should Be 0
    $side = Invoke-Contract @('-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-InstructionMode','side_branch','-FocusId','child-line','-TopicKeys','child-line','-NextAction','finish child line','-StateRoot',$stateRoot,'-Json')
    $side.exitCode | Should Be 0

    $contract = Get-Content -LiteralPath $side.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $card = $contract.returnStack[0]
    $card.returnCardFingerprintVersion = 'v1'
    $card.returnCardFingerprint = Get-TestReturnCardFingerprintV1 $card $taskId $workspaceKey @([string]$card.focusId)
    $card.mergeCaptureRequest = [pscustomobject]@{ requested=$true; requestId='unbound-merge-request'; targetFocusId='main-line' }
    Write-TestJson $side.value.path $contract

    $blocked = Invoke-Contract @('-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-BranchStatus','completed','-CompletionEvidence','child line verified','-StateRoot',$stateRoot,'-Json')
    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_RETURN_CARD_INVALID'
    $blocked.value.reason | Should Be 'legacy_merge_capture_unbound'
  }
}
