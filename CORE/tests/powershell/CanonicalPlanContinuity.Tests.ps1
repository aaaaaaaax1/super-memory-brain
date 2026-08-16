$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
. (Join-Path $PSScriptRoot 'H7TestFixture.ps1')

function Invoke-CanonicalContract([hashtable]$Parameters) {
  $bound = @{}
  foreach ($key in $Parameters.Keys) { $bound[$key] = $Parameters[$key] }
  Add-H7FixtureCheckpoint -Parameters $bound -Root $root
  $bound.NoExit = $true
  $bound.Json = $true
  $raw = @(& $contractScript @bound 2>$null)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=if($value -and $value.ok -eq $true){0}else{1}; value=$value; text=$text }
}

function Write-CanonicalMutation([string]$StateRoot,[string]$Name,[object]$Value) {
  $path = Join-Path $StateRoot ('mutations\' + $Name + '.json')
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  return $path
}

function Get-CanonicalTestFingerprint([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))[0..7] | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function New-CanonicalRoot([string]$StateRoot,[string]$TaskId,[string[]]$Labels) {
  $workspaceKey = 'ws-canonical-4242424242424242'
  $sessionKey = 'sid-canonical-4242424242424242'
  $created = Invoke-CanonicalContract @{
    Action='Set';TaskId=$TaskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey
    FocusId='main-line';FocusLabel='Approved canonical main';InstructionMode='continue'
    LatestUserInstruction='confirm the complete canonical main plan';NextAction=[string]$Labels[0]
    PendingSteps=@($Labels);EnableCanonicalPlan=$true;RequireStructuralGuards=$true
    StateRoot=$StateRoot;Source='CanonicalPlanContinuity.Tests.ps1'
  }
  $created.exitCode | Should Be 0
  return [pscustomobject]@{ stateRoot=$StateRoot;taskId=$TaskId;workspaceKey=$workspaceKey;sessionKey=$sessionKey;contract=$created.value }
}

function New-CanonicalMutationEnvelope(
  [object]$Contract,
  [string]$Operation,
  [string]$TransitionId,
  [string]$ApprovalSource,
  [string]$Instruction,
  [object[]]$Items=@(),
  [string[]]$TargetItemIds=@(),
  [string]$Status='',
  [string[]]$EvidenceRefs=@()
) {
  return [pscustomobject]@{
    schema='super-brain.canonical-plan-mutation.v1'
    targetScope='canonical_main'
    operation=$Operation
    targetItemIds=@($TargetItemIds)
    items=@($Items)
    status=$Status
    evidenceRefs=@($EvidenceRefs)
    approvalSource=$ApprovalSource
    userInstructionFingerprint=Get-CanonicalTestFingerprint $Instruction
    expectedPlanId=[string]$Contract.canonicalPlan.planId
    expectedGeneration=[int]$Contract.canonicalPlan.generation
    expectedRevision=[int]$Contract.revision
    expectedFingerprint=[string]$Contract.canonicalPlan.currentFingerprint
    transitionId=$TransitionId
  }
}

function Invoke-CanonicalMutation([object]$Fixture,[object]$Contract,[object]$Envelope,[string]$Instruction,[string]$NextAction='continue canonical main') {
  $path = Write-CanonicalMutation $Fixture.stateRoot ([string]$Envelope.transitionId) $Envelope
  return Invoke-CanonicalContract @{
    Action='Set';TaskId=$Fixture.taskId;WorkspaceKey=$Fixture.workspaceKey;SessionKey=$Fixture.sessionKey
    FocusId='main-line';InstructionMode='continue';LatestUserInstruction=$Instruction;NextAction=$NextAction
    ExpectedRevision=[int]$Contract.revision;ExpectedPlanFingerprint=[string]$Contract.planReceipt.planFingerprint
    TransitionId=[string]$Envelope.transitionId;CanonicalMutationPath=$path
    StateRoot=$Fixture.stateRoot;Source='CanonicalPlanContinuity.Tests.ps1'
  }
}

Describe 'Canonical plan continuity authority' {
  It 'does not treat file-content replacement authorization as canonical-plan replacement' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'content-replacement-not-scope') 'task-canonical-content-replacement' @('A','B')
    $instruction = 'user authorized the isolated history rewrite and replacement of historical machine-path literals in a test file; keep the current plan'
    $updated = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='main-line';InstructionMode='continue';LatestUserInstruction=$instruction;NextAction='A'
      ExpectedRevision=[int]$fixture.contract.revision;ExpectedPlanFingerprint=[string]$fixture.contract.planReceipt.planFingerprint
      TransitionId='content-replacement-does-not-replace-plan';StateRoot=$fixture.stateRoot
    }
    $updated.exitCode | Should Be 0
    $updated.value.canonicalPlan.currentFingerprint | Should Be $fixture.contract.canonicalPlan.currentFingerprint
    @($updated.value.canonicalPlan.items | ForEach-Object { $_.label }) | Should Be @('A','B')
  }

  It 'does not replay a historical canonical replacement as every later progress mutation' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'historical-replacement-does-not-repeat') 'task-canonical-historical-replacement' @('A','B')
    $replaceInstruction = 'replace the complete canonical main plan with K and L'
    $replaceEnvelope = New-CanonicalMutationEnvelope $fixture.contract 'replace_canonical' 'replace-historical-plan-once' 'user_confirmation' $replaceInstruction @(
      [pscustomobject]@{label='K';status='pending'},
      [pscustomobject]@{label='L';status='pending'}
    )
    $replaced = Invoke-CanonicalMutation $fixture $fixture.contract $replaceEnvelope $replaceInstruction 'continue K'
    $replaced.exitCode | Should Be 0

    $progress = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='main-line';InstructionMode='continue';NextAction='continue K with current evidence'
      ExpectedRevision=[int]$replaced.value.revision;ExpectedPlanFingerprint=[string]$replaced.value.planReceipt.planFingerprint
      TransitionId='post-replacement-progress-once';StateRoot=$fixture.stateRoot;Source='CanonicalPlanContinuity.Tests.ps1'
    }
    $progress.exitCode | Should Be 0
    @($progress.value.canonicalPlan.items | ForEach-Object { $_.label }) | Should Be @('K','L')
  }

  It 'requires a CAS-bound transition before an unreconciled canonical plan can be cleared' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'reconciliation-cas') 'task-canonical-reconciliation-cas' @('A','B','C')
    $observed = Invoke-CanonicalContract @{
      Action='ObserveUser';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      UserInstruction='reconcile the approved canonical plan';RequiresReconciliation=$true;StateRoot=$fixture.stateRoot
    }
    $observed.exitCode | Should Be 0
    $observed.value.needsReconciliation | Should Be $true

    $unguarded = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='main-line';InstructionMode='continue';LatestUserInstruction='reconcile the approved canonical plan';NextAction='continue A';StateRoot=$fixture.stateRoot
    }
    $unguarded.exitCode | Should Be 1
    $unguarded.value.code | Should Be 'EXECUTION_CONTRACT_STRUCTURAL_GUARD_REQUIRED'

    $guarded = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='main-line';InstructionMode='continue';LatestUserInstruction='reconcile the approved canonical plan';NextAction='continue A'
      ExpectedRevision=[int]$observed.value.revision;ExpectedPlanFingerprint=[string]$observed.value.planReceipt.planFingerprint;TransitionId='reconcile-canonical-once';StateRoot=$fixture.stateRoot
    }
    $guarded.exitCode | Should Be 0
    $guarded.value.needsReconciliation | Should Be $false
  }

  It 'keeps stable item identity and original order when H and I are appended and C completes first' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'stable-order') 'task-canonical-order' @('A','B','C','D','E','F','G')
    $initial = $fixture.contract
    $initial.canonicalPlan.orderConfidence | Should Be 'verified'
    $initialIds = @{}
    foreach ($item in @($initial.canonicalPlan.items)) { $initialIds[[string]$item.label] = [string]$item.itemId }

    $appendInstruction = 'append H and I to the approved canonical main plan'
    $appendEnvelope = New-CanonicalMutationEnvelope $initial 'append' 'append-hi-once' 'user_confirmation' $appendInstruction @(
      [pscustomobject]@{label='H';status='pending'},
      [pscustomobject]@{label='I';status='pending'}
    )
    $appended = Invoke-CanonicalMutation $fixture $initial $appendEnvelope $appendInstruction 'continue A'
    $appended.exitCode | Should Be 0

    $cItem = @($appended.value.canonicalPlan.items | Where-Object { $_.label -eq 'C' })[0]
    $completeInstruction = 'verification evidence marks canonical item C completed'
    $missingEvidence = New-CanonicalMutationEnvelope $appended.value 'set_status' 'complete-c-without-evidence' 'verified_status_transition' $completeInstruction @() @([string]$cItem.itemId) 'completed'
    $blockedCompletion = Invoke-CanonicalMutation $fixture $appended.value $missingEvidence $completeInstruction 'continue A'
    $blockedCompletion.exitCode | Should Be 1
    $blockedCompletion.value.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_STATUS_EVIDENCE_REQUIRED'
    $completeEnvelope = New-CanonicalMutationEnvelope $appended.value 'set_status' 'complete-c-once' 'verified_status_transition' $completeInstruction @() @([string]$cItem.itemId) 'completed' @('test:canonical-c-complete')
    $completed = Invoke-CanonicalMutation $fixture $appended.value $completeEnvelope $completeInstruction 'continue A'
    $completed.exitCode | Should Be 0

    @($completed.value.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) | Should Be @('A','B','C','D','E','F','G','H','I')
    @($completed.value.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { [int]$_.ordinal }) | Should Be @(1,2,3,4,5,6,7,8,9)
    @($completed.value.continuityStateCard.activeChecklist | ForEach-Object { $_.status + ':' + $_.label }) | Should Be @('pending:A','pending:B','completed:C','pending:D','pending:E','pending:F','pending:G','pending:H','pending:I')
    (@($completed.value.canonicalPlan.items | Where-Object { $_.label -eq 'C' })[0].evidenceRefs) | Should Be @('test:canonical-c-complete')
    foreach ($label in @('A','B','C','D','E','F','G')) {
      (@($completed.value.canonicalPlan.items | Where-Object { $_.label -eq $label })[0].itemId) | Should Be $initialIds[$label]
    }
  }

  It 'preserves an in-progress canonical root item in every root projection' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'in-progress-projection') 'task-canonical-in-progress' @('A','B','C')
    $initial = $fixture.contract
    $bItem = @($initial.canonicalPlan.items | Where-Object { $_.label -eq 'B' })[0]
    $instruction = 'begin approved canonical item B'
    $envelope = New-CanonicalMutationEnvelope $initial 'set_status' 'start-b-once' 'user_confirmation' $instruction @() @([string]$bItem.itemId) 'in_progress'
    $started = Invoke-CanonicalMutation $fixture $initial $envelope $instruction 'continue B'

    $started.exitCode | Should Be 0
    (@($started.value.canonicalPlan.items | Where-Object { $_.label -eq 'B' })[0].status) | Should Be 'in_progress'
    (@($started.value.workLineStatus.activeWorkPackage.checklist | Where-Object { $_.label -eq 'B' })[0].status) | Should Be 'in_progress'
    (@($started.value.continuityStateCard.activeChecklist | Where-Object { $_.label -eq 'B' })[0].status) | Should Be 'in_progress'
    (@($started.value.continuityStateCard.activeWorkPackageChecklist | Where-Object { $_.label -eq 'B' })[0].status) | Should Be 'in_progress'
  }

  It 'reports the canonical main first and keeps a side-branch checklist as an active work package' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'branch-separation') 'task-canonical-branch' @('A','B','C')
    $rootContract = $fixture.contract
    $side = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='side_branch';FocusId='side-diagnostic';FocusLabel='Local diagnostic package'
      LatestUserInstruction='inspect a local diagnostic package';NextAction='inspect side one';PendingSteps=@('side one','side two')
      ExpectedRevision=[int]$rootContract.revision;ExpectedPlanFingerprint=[string]$rootContract.planReceipt.planFingerprint
      TransitionId='open-canonical-side-once';StateRoot=$fixture.stateRoot;Source='CanonicalPlanContinuity.Tests.ps1'
    }
    $side.exitCode | Should Be 0
    $side.value.canonicalPlan.planId | Should Be $rootContract.canonicalPlan.planId
    @($side.value.continuityStateCard.activeChecklist | ForEach-Object { $_.label }) | Should Be @('A','B','C')
    @($side.value.continuityStateCard.activeWorkPackageChecklist | ForEach-Object { $_.label }) | Should Be @('side one','side two')
    $side.value.workLineStatus.canonicalMain.planId | Should Be $rootContract.canonicalPlan.planId
    $side.value.workLineStatus.activeWorkPackage.focusId | Should Be 'side-diagnostic'
    $side.value.workLineStatus.activeWorkPackage.role | Should Be 'side_branch'

    $resolved = Invoke-CanonicalContract @{Action='Resolve';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey;StateRoot=$fixture.stateRoot}
    $resolved.exitCode | Should Be 0
    @($resolved.value.continuityStateCard.activeChecklist | ForEach-Object { $_.label }) | Should Be @('A','B','C')
    @($resolved.value.continuityStateCard.activeWorkPackageChecklist | ForEach-Object { $_.label }) | Should Be @('side one','side two')
  }

  It 'replaces only the active side-branch checklist without mutating canonical main' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'branch-checklist-replace') 'task-canonical-branch-replace' @('A','B','C')
    $rootContract = $fixture.contract
    $side = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='side_branch';FocusId='side-plan';FocusLabel='Audited child plan'
      LatestUserInstruction='open a child plan';NextAction='draft one';PendingSteps=@('draft one','draft two')
      ExpectedRevision=[int]$rootContract.revision;ExpectedPlanFingerprint=[string]$rootContract.planReceipt.planFingerprint
      TransitionId='open-side-plan-once';StateRoot=$fixture.stateRoot;Source='CanonicalPlanContinuity.Tests.ps1'
    }
    $side.exitCode | Should Be 0

    $replaced = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='continue';ChecklistUpdateMode='replace';FocusId='side-plan';FocusLabel='Audited child plan'
      LatestUserInstruction='replace only the active child checklist and keep canonical main unchanged'
      NextAction='implementation one';CompletedSteps=@('design complete');PendingSteps=@('implementation one','implementation two')
      ExpectedRevision=[int]$side.value.revision;ExpectedPlanFingerprint=[string]$side.value.planReceipt.planFingerprint
      TransitionId='replace-side-plan-once';StateRoot=$fixture.stateRoot;Source='CanonicalPlanContinuity.Tests.ps1'
    }

    $replaced.exitCode | Should Be 0
    $replaced.value.canonicalPlan.currentFingerprint | Should Be $rootContract.canonicalPlan.currentFingerprint
    @($replaced.value.canonicalPlan.items | ForEach-Object { $_.label }) | Should Be @('A','B','C')
    @($replaced.value.continuityStateCard.activeWorkPackageChecklist | ForEach-Object { $_.status + ':' + $_.label }) | Should Be @('completed:design complete','pending:implementation one','pending:implementation two')
  }

  It 'requires targeted cancellation and an explicit canonical replacement envelope' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'replacement') 'task-canonical-replace' @('A','B','C','D','E','F','G','H','I')
    $current = $fixture.contract
    $naturalCancel = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='continue';ChecklistUpdateMode='replace';FocusId='main-line';LatestUserInstruction='cancel H';NextAction='continue A';PendingSteps=@('A')
      ExpectedRevision=[int]$current.revision;ExpectedPlanFingerprint=[string]$current.planReceipt.planFingerprint
      TransitionId='natural-cancel-must-fail';StateRoot=$fixture.stateRoot
    }
    $naturalCancel.exitCode | Should Be 1
    $naturalCancel.value.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_MUTATION_REQUIRED'

    $hItem = @($current.canonicalPlan.items | Where-Object { $_.label -eq 'H' })[0]
    $cancelInstruction = 'cancel only canonical item H'
    $cancelEnvelope = New-CanonicalMutationEnvelope $current 'cancel_item' 'cancel-h-once' 'user_confirmation' $cancelInstruction @() @([string]$hItem.itemId)
    $cancelled = Invoke-CanonicalMutation $fixture $current $cancelEnvelope $cancelInstruction 'continue A'
    $cancelled.exitCode | Should Be 0
    (@($cancelled.value.canonicalPlan.items | Where-Object { $_.label -eq 'H' })[0].status) | Should Be 'cancelled'
    @($cancelled.value.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) | Should Be @('A','B','C','D','E','F','G','H','I')

    $replaceInstruction = 'replace the complete canonical main plan with K and L'
    $replaceEnvelope = New-CanonicalMutationEnvelope $cancelled.value 'replace_canonical' 'replace-canonical-once' 'user_confirmation' $replaceInstruction @(
      [pscustomobject]@{label='K';status='pending'},
      [pscustomobject]@{label='L';status='pending'}
    )
    $replaced = Invoke-CanonicalMutation $fixture $cancelled.value $replaceEnvelope $replaceInstruction 'continue K'
    $replaced.exitCode | Should Be 0
    [int]$replaced.value.canonicalPlan.generation | Should Be 2
    $replaced.value.canonicalPlan.planId | Should Not Be $cancelled.value.canonicalPlan.planId
    @($replaced.value.canonicalPlan.items | ForEach-Object { $_.label }) | Should Be @('K','L')
    @($replaced.value.canonicalPlan.supersessionHistory).Count | Should Be 1
    $replaced.value.canonicalPlan.supersessionHistory[0].planId | Should Be $cancelled.value.canonicalPlan.planId
  }

  It 'rejects malformed mutations and a twenty-fifth item without changing the contract' {
    $labels = @(1..24 | ForEach-Object { 'P' + $_ })
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'bounded') 'task-canonical-bounded' $labels
    $current = $fixture.contract

    $appendInstruction = 'append the twenty-fifth item'
    $appendEnvelope = New-CanonicalMutationEnvelope $current 'append' 'append-25-must-fail' 'user_confirmation' $appendInstruction @([pscustomobject]@{label='P25';status='pending'})
    $overflow = Invoke-CanonicalMutation $fixture $current $appendEnvelope $appendInstruction 'continue P1'
    $overflow.exitCode | Should Be 1
    $overflow.value.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_ITEM_LIMIT_EXCEEDED'

    $malformed = New-CanonicalMutationEnvelope $current 'append' 'scalar-items-must-fail' 'user_confirmation' 'append malformed item'
    $malformed.items = 'not-an-array'
    $malformedPath = Write-CanonicalMutation $fixture.stateRoot 'scalar-items-must-fail' $malformed
    $malformedResult = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='main-line';InstructionMode='continue';LatestUserInstruction='append malformed item';NextAction='continue P1'
      ExpectedRevision=[int]$current.revision;ExpectedPlanFingerprint=[string]$current.planReceipt.planFingerprint
      TransitionId='scalar-items-must-fail';CanonicalMutationPath=$malformedPath;StateRoot=$fixture.stateRoot
    }
    $malformedResult.exitCode | Should Be 1
    $malformedResult.value.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_MUTATION_ITEMS_ARRAY_REQUIRED'

    $after = Invoke-CanonicalContract @{Action='Get';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey;StateRoot=$fixture.stateRoot}
    [int]$after.value.revision | Should Be ([int]$current.revision)
    @($after.value.canonicalPlan.items).Count | Should Be 24
  }

  It 'migrates a legacy checklist only through an explicit guarded write' {
    $stateRoot = Join-Path $TestDrive 'legacy-migration'
    $taskId = 'task-canonical-legacy'
    $workspaceKey = 'ws-canonical-legacy-42424242'
    $sessionKey = 'sid-canonical-legacy-42424242'
    $legacy = Invoke-CanonicalContract @{
      Action='Set';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey
      FocusId='main-line';InstructionMode='continue';NextAction='A';PendingSteps=@('A','B');StateRoot=$stateRoot
    }
    $legacy.exitCode | Should Be 0
    $legacy.value.canonicalPlan | Should BeNullOrEmpty

    $migrated = Invoke-CanonicalContract @{
      Action='Set';TaskId=$taskId;WorkspaceKey=$workspaceKey;SessionKey=$sessionKey
      FocusId='main-line';InstructionMode='continue';NextAction='A';EnableCanonicalPlan=$true;RequireStructuralGuards=$true
      ExpectedRevision=[int]$legacy.value.revision;ExpectedPlanFingerprint=[string]$legacy.value.planReceipt.planFingerprint
      TransitionId='enable-canonical-legacy-once';StateRoot=$stateRoot
    }
    $migrated.exitCode | Should Be 0
    $migrated.value.canonicalPlan.orderConfidence | Should Be 'legacy_derived'
    @($migrated.value.canonicalPlan.items | ForEach-Object { $_.label }) | Should Be @('A','B')
    $migrated.value.structuralGuardsRequired | Should Be $true
  }

  It 'replays an identical canonical transition and rejects changed content under the same transition id' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'idempotent') 'task-canonical-idempotent' @('A','B')
    $current = $fixture.contract
    $instruction = 'append C to the approved canonical main plan'
    $envelope = New-CanonicalMutationEnvelope $current 'append' 'append-c-idempotent' 'user_confirmation' $instruction @([pscustomobject]@{label='C';status='pending'})
    $first = Invoke-CanonicalMutation $fixture $current $envelope $instruction 'continue A'
    $first.exitCode | Should Be 0

    $replay = Invoke-CanonicalMutation $fixture $current $envelope $instruction 'continue A'
    $replay.exitCode | Should Be 0
    $replay.value.idempotentReplay | Should Be $true
    [int]$replay.value.revision | Should Be ([int]$first.value.revision)

    $changed = New-CanonicalMutationEnvelope $current 'append' 'append-c-idempotent' 'user_confirmation' $instruction @([pscustomobject]@{label='D';status='pending'})
    $conflict = Invoke-CanonicalMutation $fixture $current $changed $instruction 'continue A'
    $conflict.exitCode | Should Be 1
    $conflict.value.code | Should Be 'EXECUTION_CONTRACT_TRANSITION_ID_CONFLICT'
    $after = Invoke-CanonicalContract @{Action='Get';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey;StateRoot=$fixture.stateRoot}
    @($after.value.canonicalPlan.items | ForEach-Object { $_.label }) | Should Be @('A','B','C')
  }

  It 'binds canonical identity into v4 return cards and preserves the main plan on parent resume' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'resume-parent') 'task-canonical-resume' @('A','B','C')
    $rootContract = $fixture.contract
    $side = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='side_branch';FocusId='side-proof';FocusLabel='Side proof package';LatestUserInstruction='open side proof package'
      NextAction='verify side proof';PendingSteps=@('verify side proof')
      ExpectedRevision=[int]$rootContract.revision;ExpectedPlanFingerprint=[string]$rootContract.planReceipt.planFingerprint
      TransitionId='open-side-proof';StateRoot=$fixture.stateRoot
    }
    $side.exitCode | Should Be 0
    $side.value.returnStack[0].returnCardFingerprintVersion | Should Be 'v6'
    $side.value.returnStack[0].canonicalPlanId | Should Be $rootContract.canonicalPlan.planId

    $resumed = Invoke-CanonicalContract @{
      Action='ResumeParent';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      ExpectedRevision=[int]$side.value.revision;ExpectedPlanFingerprint=[string]$side.value.planReceipt.planFingerprint
      TransitionId='resume-canonical-parent';StateRoot=$fixture.stateRoot
    }
    $resumed.exitCode | Should Be 0
    $resumed.value.canonicalPlan.planId | Should Be $rootContract.canonicalPlan.planId
    $resumed.value.planReceipt.schema | Should Be 'super-brain.plan-receipt.v3'
    @($resumed.value.continuityStateCard.activeChecklist | ForEach-Object { $_.label }) | Should Be @('A','B','C')
    @($resumed.value.returnStack).Count | Should Be 0
  }

  It 'withholds a suspended canonical parent whose visible progress predates a canonical action change' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'resume-parent-after-mutation') 'task-canonical-resume-mutation' @('A','B','C')
    $side = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='side_branch';FocusId='side-proof';LatestUserInstruction='open side proof';NextAction='verify side proof';PendingSteps=@('verify side proof')
      ExpectedRevision=[int]$fixture.contract.revision;ExpectedPlanFingerprint=[string]$fixture.contract.planReceipt.planFingerprint
      TransitionId='open-side-before-parent-mutation';StateRoot=$fixture.stateRoot
    }
    $side.exitCode | Should Be 0
    $aItem = @($side.value.canonicalPlan.items | Where-Object { $_.label -eq 'A' })[0]
    $instruction = 'verification marks canonical item A completed while the side proof remains active'
    $envelope = New-CanonicalMutationEnvelope $side.value 'set_status' 'complete-a-while-side-active' 'verified_status_transition' $instruction @() @([string]$aItem.itemId) 'completed' @('test:canonical-a-complete')
    $path = Write-CanonicalMutation $fixture.stateRoot 'complete-a-while-side-active' $envelope
    $mutated = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='continue';FocusId='side-proof';LatestUserInstruction=$instruction;NextAction='verify side proof'
      ExpectedRevision=[int]$side.value.revision;ExpectedPlanFingerprint=[string]$side.value.planReceipt.planFingerprint
      TransitionId='complete-a-while-side-active';CanonicalMutationPath=$path;StateRoot=$fixture.stateRoot
    }
    $mutated.exitCode | Should Be 0
    $mutated.value.returnStack[0].actionBindingState | Should Be 'stale_canonical_change'

    $resumed = Invoke-CanonicalContract @{
      Action='ResumeParent';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      ExpectedRevision=[int]$mutated.value.revision;ExpectedPlanFingerprint=[string]$mutated.value.planReceipt.planFingerprint
      TransitionId='resume-reconciled-canonical-parent';StateRoot=$fixture.stateRoot
    }
    $resumed.exitCode | Should Be 1
    $resumed.value.code | Should Be 'EXECUTION_CONTRACT_VISIBLE_PROGRESS_RECEIPT_MISMATCH'
  }

  It 'requires replace_canonical when replacing the root focus' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'replace-root-scope') 'task-canonical-replace-root' @('A','B')
    $instruction = 'replace the complete canonical main plan with the new-root plan K'
    $appendEnvelope = New-CanonicalMutationEnvelope $fixture.contract 'append' 'append-cannot-replace-root' 'user_confirmation' $instruction @([pscustomobject]@{label='K';status='pending'})
    $appendPath = Write-CanonicalMutation $fixture.stateRoot 'append-cannot-replace-root' $appendEnvelope
    $blocked = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='replace';FocusId='new-root';LatestUserInstruction=$instruction;NextAction='K'
      ExpectedRevision=[int]$fixture.contract.revision;ExpectedPlanFingerprint=[string]$fixture.contract.planReceipt.planFingerprint
      TransitionId='append-cannot-replace-root';CanonicalMutationPath=$appendPath;StateRoot=$fixture.stateRoot
    }
    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_CANONICAL_REPLACEMENT_REQUIRED'

    $replaceEnvelope = New-CanonicalMutationEnvelope $fixture.contract 'replace_canonical' 'replace-root-canonical' 'user_confirmation' $instruction @([pscustomobject]@{label='K';status='pending'})
    $replaceEnvelope | Add-Member -NotePropertyName rootFocusId -NotePropertyValue 'new-root' -Force
    $replacePath = Write-CanonicalMutation $fixture.stateRoot 'replace-root-canonical' $replaceEnvelope
    $replaced = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='replace';FocusId='new-root';LatestUserInstruction=$instruction;NextAction='K'
      ExpectedRevision=[int]$fixture.contract.revision;ExpectedPlanFingerprint=[string]$fixture.contract.planReceipt.planFingerprint
      TransitionId='replace-root-canonical';CanonicalMutationPath=$replacePath;StateRoot=$fixture.stateRoot
    }
    $replaced.exitCode | Should Be 0
    $replaced.value.focusId | Should Be 'new-root'
    $replaced.value.canonicalPlan.rootFocusId | Should Be 'new-root'
  }

  It 'fails closed when a canonical v4 parent binding is tampered' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'tampered-parent') 'task-canonical-tamper' @('A','B')
    $side = Invoke-CanonicalContract @{
      Action='Set';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      InstructionMode='side_branch';FocusId='side-tamper';LatestUserInstruction='open side tamper check';NextAction='inspect'
      ExpectedRevision=[int]$fixture.contract.revision;ExpectedPlanFingerprint=[string]$fixture.contract.planReceipt.planFingerprint
      TransitionId='open-side-tamper';StateRoot=$fixture.stateRoot
    }
    $side.exitCode | Should Be 0
    $stored = Get-Content -LiteralPath $side.value.path -Raw -Encoding UTF8 | ConvertFrom-Json
    $stored.returnStack[0].canonicalFingerprint = 'tampered-canonical-fingerprint'
    [IO.File]::WriteAllText([string]$side.value.path,($stored | ConvertTo-Json -Depth 14 -Compress),[Text.UTF8Encoding]::new($false))

    $blocked = Invoke-CanonicalContract @{
      Action='ResumeParent';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      ExpectedRevision=[int]$side.value.revision;ExpectedPlanFingerprint=[string]$side.value.planReceipt.planFingerprint
      TransitionId='resume-tampered-parent';StateRoot=$fixture.stateRoot
    }
    $blocked.exitCode | Should Be 1
    (@('EXECUTION_CONTRACT_RETURN_CARD_INVALID','EXECUTION_CONTRACT_MISSING_OR_STALE') -contains [string]$blocked.value.code) | Should Be $true
  }

  It 'keeps canonical state unchanged during observation and allows duplicate labels only through stable item ids' {
    $fixture = New-CanonicalRoot (Join-Path $TestDrive 'observe-duplicate') 'task-canonical-observe' @('A','B')
    $current = $fixture.contract
    $instruction = 'append another A as a separately identified canonical item'
    $envelope = New-CanonicalMutationEnvelope $current 'append' 'append-duplicate-label' 'user_confirmation' $instruction @([pscustomobject]@{label='A';status='pending'})
    $appended = Invoke-CanonicalMutation $fixture $current $envelope $instruction 'continue A'
    $appended.exitCode | Should Be 0
    @($appended.value.canonicalPlan.items | Where-Object { $_.label -eq 'A' }).Count | Should Be 2
    @($appended.value.canonicalPlan.items | Where-Object { $_.label -eq 'A' } | ForEach-Object { $_.itemId } | Select-Object -Unique).Count | Should Be 2

    $observed = Invoke-CanonicalContract @{
      Action='ObserveUser';TaskId=$fixture.taskId;WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      UserInstruction='continue the current approved task';StateRoot=$fixture.stateRoot
    }
    $observed.exitCode | Should Be 0
    $observed.value.canonicalPlan.currentFingerprint | Should Be $appended.value.canonicalPlan.currentFingerprint
    @($observed.value.canonicalPlan.items | ForEach-Object { $_.itemId }) | Should Be @($appended.value.canonicalPlan.items | ForEach-Object { $_.itemId })
  }
}
