$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$storeScript = Join-Path $root 'scripts\task-state-store.ps1'
. (Join-Path $root 'scripts\common.ps1')
. (Join-Path $root 'scripts\internal\intent-resolution.ps1')

function Write-CompletionJson([string]$Path,[object]$Value) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
}

function Invoke-CompletionStore([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $storeScript @Arguments 2>$null)
  $exitCode = $LASTEXITCODE
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $value = if ([string]::IsNullOrWhiteSpace($text) -or $text.Trim() -eq 'null') { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode=$exitCode; value=$value; text=$text }
}

function Get-CompletionOwnerArgs {
  return @('-OwnerAgentId','agent-completion','-OwnerSessionId','session-completion','-OwnerPlatform','codex','-OwnerWorkspace','G:\completion-tests')
}

function New-CompletionIntentJson {
  return ([pscustomobject]@{
    schema='super-brain.intent-contract.v2';literalRequestDigest='editable notebook, but no direct database writes'
    resolvedOutcome='Users can edit notebook entries through governed commands.';productRole='local notebook UI backed by a governed command API'
    integrationObligations=@('local UI','governed command API','task receipt');materialUnknowns=@();compatibilityGuards=@('no browser-side direct SQLite or database writes')
    preservedCapabilities=@('editable notebook');acceptanceCriteria=@('an edit produces a receipt');governedEquivalent='governed command editing through a local API';autonomyTier='align'
    integrationMap=[pscustomobject]@{entryPoint='notebook page';userFlow='open note, edit, save, observe receipt';domainOwner='BrainControl command engine';stateOwner='brain-state SQLite authority';downstreamConsumers=@('notebook query projection','history view');failureRecovery='CAS conflict keeps the draft and offers retry';privacyPerformance='loopback only and bounded payloads';compatibilityMigration='legacy records remain read-only until migration';verification='command API and real user edit-flow regression';completionCondition='edit, history, and rollback path are verified'}
    investigationEvidence=@('runtime/brain_control.py command authority');materialBranches=@();focusedQuestion='';preserveExistingFlow=$true;replacementReceipt=''
    componentResolution=[pscustomobject]@{requestedComponent='direct database editor';resolvedComponent='governed command API';outcomePreserved=$true;reason='the governed command path preserves editing with receipts and rollback'}
  } | ConvertTo-Json -Depth 10 -Compress)
}

function New-CompletionIntentFulfillmentJson([object]$Contract) {
  $make = {
    param([object[]]$Values,[string]$EvidencePrefix)
    return @($Values | ForEach-Object { [pscustomobject]@{ requirement=[string]$_; ok=$true; evidenceRefs=@($EvidencePrefix + ':' + (Get-SuperBrainStableHash ([string]$_) 16)) } })
  }
  return ([pscustomobject]@{
    integrationObligations=@(& $make @($Contract.intentContract.integrationObligations) 'integration')
    preservedCapabilities=@(& $make @($Contract.intentContract.preservedCapabilities) 'preserved')
    acceptanceCriteria=@(& $make @($Contract.intentContract.acceptanceCriteria) 'acceptance')
  } | ConvertTo-Json -Depth 8 -Compress)
}

function Invoke-SeedCommit([string]$TaskId,[string]$Kind,[string]$Payload,[string]$Target,[int]$Revision,[string]$Workspace,[string]$Shared) {
  $args = @('-Action','Commit','-TaskId',$TaskId,'-EntityKind',$Kind,'-Operation','upsert','-PayloadPath',$Payload,'-EntityPath',$Target,'-ExpectedRevision',[string]$Revision,'-WorkspaceRoot',$Workspace,'-SharedRoot',$Shared,'-Source','TaskCompletionTransaction.Tests.ps1','-Json')
  $args += Get-CompletionOwnerArgs
  return Invoke-CompletionStore $args
}

function New-CompletionFixture([string]$Base,[string]$TaskId,[string[]]$PendingSteps=@(),[string]$ContractSession='sid-aaaaaaaaaaaaaaaa',[string]$VerificationVersion='',[ValidateSet('none','missing','complete')][string]$IntentMode='none') {
  $workspace = Join-Path $Base 'workspace'
  $shared = Join-Path $Base 'shared'
  $workspaceKey = 'ws-111111111111111111111111'
  $manifestVersion = [string](Get-SuperBrainManifest $root).version
  if ([string]::IsNullOrWhiteSpace($VerificationVersion)) { $VerificationVersion = $manifestVersion }
  $token = Get-SuperBrainCanonicalTaskToken $TaskId
  $contextPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-contexts') $TaskId '.json'
  $checkpointPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\active') $TaskId '.json'
  $taskCardPath = Get-SuperBrainCanonicalTaskPath (Join-Path $shared 'tasks\active') $TaskId '.task.json'
  $completedCheckpointPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\completed') $TaskId '.json'
  $completedTaskCardPath = Get-SuperBrainCanonicalTaskPath (Join-Path $shared 'tasks\completed') $TaskId '.task.json'
  $stageRoot = Join-Path $workspace (Join-Path 'task-state-store\staging' $token)
  $contextPayload = Join-Path $stageRoot 'seed-context.json'
  $checkpointPayload = Join-Path $stageRoot 'seed-checkpoint.json'
  $taskCardPayload = Join-Path $stageRoot 'seed-task-card.json'
  $completedCheckpointPayload = Join-Path $stageRoot 'completed-checkpoint.json'
  $completedTaskCardPayload = Join-Path $stageRoot 'completed-task-card.json'
  $verificationPath = Join-Path $stageRoot 'verification.json'
  $manifestPath = Join-Path $stageRoot 'completion-manifest.json'
  $contractPath = Join-Path (Join-Path $workspace 'runtime-state\execution-contracts') ($token + '--' + $workspaceKey + '.json')
  $goalLockPath = Join-Path (Join-Path $workspace 'guard-state\goal-route-locks') ($TaskId + '.json')
  $routeCheckpointPath = Join-Path (Join-Path $workspace 'guard-state\route-checkpoints') ($TaskId + '.json')
  $contextPointerPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-context-pointers') $workspaceKey '.json'
  $hotIndexPath = Join-Path (Join-Path $workspace 'runtime-state\execution-hot-index') ($ContractSession + '--' + $workspaceKey + '.json')

  $ownerFields = @{ agentId='agent-completion'; sessionId='session-completion'; platform='codex'; workspace='G:\completion-tests' }
  $context = [pscustomobject]@{ schema='super-brain.current-task-context.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='active'; stale=$false; acceptedGoal='finish safely'; agentId=$ownerFields.agentId; sessionId=$ownerFields.sessionId; platform=$ownerFields.platform; workspace=$ownerFields.workspace }
  $checkpoint = [pscustomobject]@{ schema='super-brain.checkpoint.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='active'; pendingSteps=@($PendingSteps); completedSteps=@(); currentStep='finish'; nextAction='complete transaction'; agentId=$ownerFields.agentId; sessionId=$ownerFields.sessionId; platform=$ownerFields.platform; workspace=$ownerFields.workspace }
  $taskCard = [pscustomobject]@{ schema='super-brain.task-card.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='active'; pendingSteps=@($PendingSteps); completedSteps=@(); agentId=$ownerFields.agentId; sessionId=$ownerFields.sessionId; platform=$ownerFields.platform; workspace=$ownerFields.workspace }
  $completedCheckpoint = [pscustomobject]@{ schema='super-brain.checkpoint.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='completed'; pendingSteps=@(); completedSteps=@('done'); source='task-verification.ps1'; agentId=$ownerFields.agentId; sessionId=$ownerFields.sessionId; platform=$ownerFields.platform; workspace=$ownerFields.workspace }
  $completedTaskCard = [pscustomobject]@{ schema='super-brain.task-card.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='completed'; pendingSteps=@(); completedSteps=@('done'); source='checkpoint-writer.ps1'; agentId=$ownerFields.agentId; sessionId=$ownerFields.sessionId; platform=$ownerFields.platform; workspace=$ownerFields.workspace }
  foreach ($pair in @(@($contextPayload,$context),@($checkpointPayload,$checkpoint),@($taskCardPayload,$taskCard),@($completedCheckpointPayload,$completedCheckpoint),@($completedTaskCardPayload,$completedTaskCard))) { Write-CompletionJson $pair[0] $pair[1] }

  (Invoke-SeedCommit $TaskId context $contextPayload $contextPath 0 $workspace $shared).exitCode | Should Be 0
  (Invoke-SeedCommit $TaskId checkpoint $checkpointPayload $checkpointPath 1 $workspace $shared).exitCode | Should Be 0
  (Invoke-SeedCommit $TaskId task_card $taskCardPayload $taskCardPath 2 $workspace $shared).exitCode | Should Be 0

  $contractScript = Join-Path $root 'scripts\execution-contract.ps1'
  $contractArgs=@{Action='Set';TaskId=$TaskId;WorkspaceKey=$workspaceKey;SessionKey=$ContractSession;FocusId='main-line';FocusLabel='finish safely';LatestUserInstruction='complete fixture transaction';AssistantCommitment='finish safely';NextAction='finish safely';CurrentPhase='completion';CurrentStep='finish safely';CompletedSteps=@('finish safely');AcceptanceCriteria=@('fixture completion verification');EnableCanonicalPlan=$true;StateRoot=$Base;Source='TaskCompletionTransaction.Tests.ps1';NoExit=$true;Json=$true}
  if($IntentMode-ne'none'){$contractArgs.IntentContractJson=New-CompletionIntentJson}
  $contractRaw = @(& $contractScript @contractArgs 2>$null)
  $contract = ConvertFrom-SuperBrainJsonOutput ($contractRaw -join "`n") 'completion fixture execution contract'
  if (-not $contract -or $contract.ok -ne $true) { throw 'FIXTURE_EXECUTION_CONTRACT_SET_INVALID' }
  $contractPath = [string]$contract.path
  $planFingerprint = [string]$contract.planReceipt.planFingerprint
  $taskInstanceId = [string]$contract.taskInstanceId
  $contractRevision = [int]$contract.revision
  # This fixture intentionally models a previously reconciled completion request.
  $contract.needsReconciliation = $false
  Write-CompletionJson $contractPath $contract
  $taskEvidenceBinding = New-SuperBrainEvidenceBinding -TaskId $TaskId -WorkspaceKey $workspaceKey -OwnerSessionKey $ContractSession -Root $root
  $verification = [pscustomobject]@{ schema='super-brain.task-verification.v1'; ok=$true; taskId=$TaskId; workspaceKey=$workspaceKey; version=$VerificationVersion; nextSteps=@(); checkedAt=(Get-Date).ToString('o'); evidenceBinding=$taskEvidenceBinding }
  $intentFulfillmentFingerprint=''
  if($IntentMode-eq'complete'){
    $intentFulfillment=New-SuperBrainIntentFulfillment $contract (New-CompletionIntentFulfillmentJson $contract)
    if($intentFulfillment.ok-ne$true){throw ('FIXTURE_INTENT_FULFILLMENT_FAILED '+[string]$intentFulfillment.code)}
    $verification|Add-Member -NotePropertyName intentFulfillment -NotePropertyValue $intentFulfillment.record -Force
    $intentFulfillmentFingerprint=[string]$intentFulfillment.record.fulfillmentFingerprint
  }
  Write-CompletionJson $verificationPath $verification
  $completionEvidenceBinding = [pscustomobject]@{
    schema=[string]$taskEvidenceBinding.schema;packageVersion=[string]$taskEvidenceBinding.packageVersion;gitTreeHash=[string]$taskEvidenceBinding.gitTreeHash
    treeAlgorithm=[string]$taskEvidenceBinding.treeAlgorithm;gitHeadTreeHash=[string]$taskEvidenceBinding.gitHeadTreeHash;taskId=[string]$taskEvidenceBinding.taskId
    workspaceKey=[string]$taskEvidenceBinding.workspaceKey;ownerSessionKey=[string]$taskEvidenceBinding.ownerSessionKey
    artifactHash=(Get-FileHash -LiteralPath $verificationPath -Algorithm SHA256).Hash.ToLowerInvariant();artifactKind='task_verification'
  }
  Write-CompletionJson $goalLockPath ([pscustomobject]@{ schema='super-brain.goal-route-lock.v1'; taskId=$TaskId; status='active'; active=$true; workspaceKey=$workspaceKey })
  Write-CompletionJson $routeCheckpointPath ([pscustomobject]@{ schema='super-brain.route-checkpoint.v1'; taskId=$TaskId; status='clean'; workspaceKey=$workspaceKey })
  Write-CompletionJson $contextPointerPath $context
  Write-CompletionJson (Join-Path $workspace 'current-task-context.json') $context
  Write-CompletionJson (Join-Path $workspace 'active-checkpoint.json') $checkpoint
  Write-CompletionJson (Join-Path $workspace 'goal-route-lock.json') ([pscustomobject]@{ taskId=$TaskId; status='active'; active=$true; workspaceKey=$workspaceKey })
  Write-CompletionJson (Join-Path $workspace 'route-checkpoint.json') ([pscustomobject]@{ taskId=$TaskId; status='clean'; workspaceKey=$workspaceKey })
  Write-CompletionJson (Join-Path $workspace 'last-execution-contract.json') $contract
  Write-CompletionJson $hotIndexPath ([pscustomobject]@{ schema='super-brain.execution-hot-index.v1'; packageVersion=$manifestVersion; workspaceKey=$workspaceKey; ownerSessionKey=$ContractSession; entryCount=1; entries=@([pscustomobject]@{ taskId=$TaskId; status='active'; workspaceKey=$workspaceKey; ownerSessionKey=$ContractSession; packageVersion=$manifestVersion }) })
  $originalStateHashes=@(@($contextPath,$checkpointPath,$taskCardPath,$contractPath,$goalLockPath,$routeCheckpointPath)|ForEach-Object{(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash})

  $manifest = [pscustomobject]@{
    schema='super-brain.task-completion-manifest.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; packageVersion=$manifestVersion
    completionStatus='completed'; ownerSessionKey=$ContractSession; callerSessionKey=$ContractSession; expectedTaskInstanceId=$taskInstanceId; expectedPlanFingerprint=$planFingerprint; expectedContractRevision=$contractRevision
    completedCheckpointPayloadPath=$completedCheckpointPayload; completedTaskCardPayloadPath=$completedTaskCardPayload
    executionContractPath=$contractPath; verificationPath=$verificationPath; evidenceBinding=$completionEvidenceBinding; source='TaskCompletionTransaction.Tests.ps1'
  }
  Write-CompletionJson $manifestPath $manifest
  return [pscustomobject]@{
    taskId=$TaskId; workspace=$workspace; shared=$shared; workspaceKey=$workspaceKey; manifestPath=$manifestPath
    contextPath=$contextPath; checkpointPath=$checkpointPath; taskCardPath=$taskCardPath; completedCheckpointPath=$completedCheckpointPath
    completedTaskCardPath=$completedTaskCardPath; contractPath=$contractPath; verificationPath=$verificationPath; goalLockPath=$goalLockPath; routeCheckpointPath=$routeCheckpointPath
    contextPointerPath=$contextPointerPath; hotIndexPath=$hotIndexPath; planFingerprint=$planFingerprint; taskInstanceId=$taskInstanceId; contractRevision=$contractRevision; contractSession=$ContractSession; completionEvidenceBinding=$completionEvidenceBinding
    intentMode=$IntentMode;intentFulfillmentFingerprint=$intentFulfillmentFingerprint
    originalStateHashes=@($originalStateHashes)
    terminalPlanSealPath=(Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\terminal-plan-seals') $TaskId '.json')
    completionReceiptPath=(Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\task-completion-receipts') $TaskId '.json')
  }
}

function Invoke-CompleteFixture([object]$Fixture,[string]$FaultPoint='none',[int]$FaultAfterMaterialization=0,[string]$CallerSessionKey='',[switch]$MaintenanceOverride) {
  if ([string]::IsNullOrWhiteSpace($CallerSessionKey)) { $CallerSessionKey = [string]$Fixture.contractSession }
  $args = @('-Action','CompleteTask','-TaskId',$Fixture.taskId,'-CompletionManifestPath',$Fixture.manifestPath,'-ExpectedRevision','3','-WorkspaceRoot',$Fixture.workspace,'-SharedRoot',$Fixture.shared,'-Source','TaskCompletionTransaction.Tests.ps1','-CallerSessionKey',$CallerSessionKey,'-Json')
  if ($FaultPoint -ne 'none') { $args += @('-FaultPoint',$FaultPoint) }
  if ($FaultAfterMaterialization -gt 0) { $args += @('-FaultAfterMaterialization',[string]$FaultAfterMaterialization) }
  if ($MaintenanceOverride) { $args += @('-MaintenanceOverride','-MaintenanceReason','fixture maintenance override') }
  $args += Get-CompletionOwnerArgs
  return Invoke-CompletionStore $args
}

function Assert-CompletionClosed([object]$Fixture) {
  $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $Fixture.workspace 'task-state-store\projections') $Fixture.taskId '.json'
  $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $projection.lifecycle.status | Should Be 'completed'
  $projection.entities.context | Should BeNullOrEmpty
  $projection.entities.checkpoint.status | Should Be 'completed'
  $projection.entities.task_card.status | Should Be 'completed'
  Test-Path -LiteralPath $Fixture.contextPath | Should Be $false
  Test-Path -LiteralPath $Fixture.checkpointPath | Should Be $false
  Test-Path -LiteralPath $Fixture.taskCardPath | Should Be $false
  Test-Path -LiteralPath $Fixture.completedCheckpointPath | Should Be $true
  Test-Path -LiteralPath $Fixture.completedTaskCardPath | Should Be $true
  Test-Path -LiteralPath $Fixture.contractPath | Should Be $false
  $archiveRoot=Join-Path $Fixture.workspace 'task-state-store\completion-archive'
  $archiveFiles=@(Get-ChildItem -LiteralPath $archiveRoot -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)
  $archiveHashes=@($archiveFiles|ForEach-Object{(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash})
  foreach($expectedHash in @($Fixture.originalStateHashes)){($archiveHashes-contains$expectedHash)|Should Be $true}
  Test-Path -LiteralPath $Fixture.terminalPlanSealPath | Should Be $true
  $seal = Get-Content -LiteralPath $Fixture.terminalPlanSealPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $seal.schema | Should Be 'super-brain.terminal-plan-seal.v1'
  $seal.taskId | Should Be $Fixture.taskId
  $seal.workspaceKey | Should Be $Fixture.workspaceKey
  $seal.planFingerprint | Should Be $Fixture.planFingerprint
  [int]$seal.contractRevision | Should Be ([int]$Fixture.contractRevision)
  $seal.canonicalPlan.planId | Should Not BeNullOrEmpty
  $seal.canonicalPlan.items[0].itemId | Should Not BeNullOrEmpty
  $seal.sourceContractHash | Should Not BeNullOrEmpty
  $seal.evidenceBinding.artifactHash | Should Be $Fixture.completionEvidenceBinding.artifactHash
  $seal.evidenceBinding.gitTreeHash | Should Be $Fixture.completionEvidenceBinding.gitTreeHash
  $projection.lifecycle.evidenceBinding.artifactHash | Should Be $Fixture.completionEvidenceBinding.artifactHash
  Test-Path -LiteralPath $Fixture.completionReceiptPath | Should Be $true
  $receipt = Get-Content -LiteralPath $Fixture.completionReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $receipt.schema | Should Be 'super-brain.task-completion-receipt.v1'
  $receipt.taskId | Should Be $Fixture.taskId
  $receipt.workspaceKey | Should Be $Fixture.workspaceKey
  $receipt.taskInstanceId | Should Be $Fixture.taskInstanceId
  $receipt.planFingerprint | Should Be $Fixture.planFingerprint
  $receipt.transactionId | Should Be $projection.lifecycle.completionTransactionId
  (Get-FileHash -LiteralPath $Fixture.completionReceiptPath -Algorithm SHA256).Hash | Should Be $projection.lifecycle.completionReceiptHash
  $receipt.terminalPlanSealHash | Should Be $projection.lifecycle.terminalPlanSealHash
  $receipt.receiptState | Should Be 'prepared'
  if(-not[string]::IsNullOrWhiteSpace([string]$Fixture.intentFulfillmentFingerprint)){
    $projection.lifecycle.intentCompletion.fulfillmentFingerprint | Should Be $Fixture.intentFulfillmentFingerprint
    $seal.intentCompletion.fulfillmentFingerprint | Should Be $Fixture.intentFulfillmentFingerprint
    $receipt.intentCompletion.fulfillmentFingerprint | Should Be $Fixture.intentFulfillmentFingerprint
    $events=@(Get-Content -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $Fixture.workspace 'task-state-store\events') $Fixture.taskId '.jsonl') -Encoding UTF8|ForEach-Object{$_|ConvertFrom-Json})
    $prepared=@($events|Where-Object{[string]$_.transactionKind-eq'task_completion'-and[string]$_.phase-eq'prepared'})[-1]
    $prepared.completion.intentCompletion.fulfillmentFingerprint | Should Be $Fixture.intentFulfillmentFingerprint
  }
  $seal.rawPromptStored | Should Be $false
  $seal.rawTranscriptStored | Should Be $false
  (Get-Content -LiteralPath $Fixture.goalLockPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should Be 'cleared'
  (Get-Content -LiteralPath $Fixture.routeCheckpointPath -Raw -Encoding UTF8 | ConvertFrom-Json).status | Should Be 'resolved'
  Test-Path -LiteralPath $Fixture.hotIndexPath | Should Be $false
}

Describe 'Task completion transaction' {
  It 'closes all task-owned active state in one recoverable transaction' {
    $fixture = New-CompletionFixture (Join-Path $TestDrive 'complete') 'task-complete-atomic'
    $completed = Invoke-CompleteFixture $fixture
    $completed.exitCode | Should Be 0
    $completed.value.activeStateCount | Should Be 0
    $completed.value.transactionId | Should Not BeNullOrEmpty
    Assert-CompletionClosed $fixture
  }

  It 'does not let legacy global graph or ledger records gate or mutate canonical completion' {
    $fixture = New-CompletionFixture (Join-Path $TestDrive 'legacy-read-only') 'task-complete-legacy-read-only'
    $legacyGraphPath = Join-Path $fixture.workspace 'task-graph.json'
    $legacyLedgerPath = Join-Path $fixture.workspace 'step-ledger.json'
    Write-CompletionJson $legacyGraphPath ([pscustomobject]@{
      taskId=$fixture.taskId; workspaceKey=$fixture.workspaceKey; goal='legacy compatibility record'; status='active'; updatedAt=(Get-Date).ToString('o')
    })
    Write-CompletionJson $legacyLedgerPath ([pscustomobject]@{
      taskId=$fixture.taskId; workspaceKey=$fixture.workspaceKey; openSteps=@([pscustomobject]@{step='obsolete global pending step'}); blockedSteps=@(); completedSteps=@(); skippedSteps=@()
    })
    $legacyGraphHash = (Get-FileHash -LiteralPath $legacyGraphPath -Algorithm SHA256).Hash
    $legacyLedgerHash = (Get-FileHash -LiteralPath $legacyLedgerPath -Algorithm SHA256).Hash

    $completed = Invoke-CompleteFixture $fixture
    $completed.exitCode | Should Be 0
    Assert-CompletionClosed $fixture
    (Get-FileHash -LiteralPath $legacyGraphPath -Algorithm SHA256).Hash | Should Be $legacyGraphHash
    (Get-FileHash -LiteralPath $legacyLedgerPath -Algorithm SHA256).Hash | Should Be $legacyLedgerHash
    Test-Path -LiteralPath (Join-Path $fixture.workspace 'last-completed-task-graph.json') | Should Be $false
  }

  It 'recovers a failure after prepare and after every materialization boundary' {
    $probe = New-CompletionFixture (Join-Path $TestDrive 'probe') 'task-complete-probe'
    $prepared = Invoke-CompleteFixture $probe 'after_prepare'
    $prepared.exitCode | Should Be 1
    $eventPath = Get-SuperBrainCanonicalTaskPath (Join-Path $probe.workspace 'task-state-store\events') $probe.taskId '.jsonl'
    $prepareEvent = @(Get-Content -LiteralPath $eventPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.phase -eq 'prepared' })[-1]
    $commandCount = @($prepareEvent.commands).Count
    $commandCount -gt 5 | Should Be $true
    (Invoke-CompletionStore @('-Action','Reconcile','-WorkspaceRoot',$probe.workspace,'-SharedRoot',$probe.shared,'-Apply','-Json')).exitCode | Should Be 0
    Assert-CompletionClosed $probe

    foreach ($boundary in 1..$commandCount) {
      $fixture = New-CompletionFixture (Join-Path $TestDrive ("boundary-$boundary")) ("task-complete-boundary-$boundary")
      $failed = Invoke-CompleteFixture $fixture 'none' $boundary
      $failed.exitCode | Should Be 1
      $failed.value.error.Contains('TASK_STATE_FAULT_INJECTED_AFTER_MATERIALIZATION') | Should Be $true
      $audit = Invoke-CompletionStore @('-Action','Audit','-WorkspaceRoot',$fixture.workspace,'-SharedRoot',$fixture.shared,'-Json')
      $audit.value.incompleteTransactionCount | Should Be 1
      if ($boundary -eq $commandCount) {
        Test-Path -LiteralPath $fixture.completionReceiptPath | Should Be $true
        $preparedReceipt = Get-Content -LiteralPath $fixture.completionReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $preparedReceipt.receiptState | Should Be 'prepared'
        $events = @(Get-Content -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $fixture.workspace 'task-state-store\events') $fixture.taskId '.jsonl') -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | Where-Object { [string]$_.transactionKind -eq 'task_completion' -and [string]$_.phase -eq 'committed' }).Count | Should Be 0
      }
      $reconciled = Invoke-CompletionStore @('-Action','Reconcile','-WorkspaceRoot',$fixture.workspace,'-SharedRoot',$fixture.shared,'-Apply','-Json')
      $reconciled.exitCode | Should Be 0
      $reconciled.value.recoveredCount | Should Be 1
      Assert-CompletionClosed $fixture
    }
  }

  It 'rebuilds projection and index state after a committed WAL event is written before its projection' {
    $fixture = New-CompletionFixture (Join-Path $TestDrive 'after-commit') 'task-complete-after-commit'
    $failed = Invoke-CompleteFixture $fixture 'after_commit'
    $failed.exitCode | Should Be 1

    $before = Invoke-CompletionStore @('-Action','Audit','-WorkspaceRoot',$fixture.workspace,'-SharedRoot',$fixture.shared,'-Json')
    $before.exitCode | Should Be 1
    $before.value.committedProjectionLagCount | Should Be 1

    $reconciled = Invoke-CompletionStore @('-Action','Reconcile','-WorkspaceRoot',$fixture.workspace,'-SharedRoot',$fixture.shared,'-Apply','-Json')
    $reconciled.exitCode | Should Be 0
    $reconciled.value.recoveredCount | Should Be 0
    $reconciled.value.recoveredCommittedProjectionLagCount | Should Be 1
    Assert-CompletionClosed $fixture
  }

  It 'recovers an authority-only completion and keeps changed evidence fail-closed' {
    $recover = New-CompletionFixture (Join-Path $TestDrive 'authority-only') 'task-complete-authority-only'
    $recoverFault = Invoke-CompleteFixture $recover 'after_authority'
    $recoverFault.exitCode | Should Be 1
    $recoverFault.text | Should Match 'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY'
    $recovered = Invoke-CompletionStore @('-Action','Reconcile','-WorkspaceRoot',$recover.workspace,'-SharedRoot',$recover.shared,'-Apply','-Json')
    $recovered.exitCode | Should Be 0
    $recovered.value.recoveredCount | Should Be 0
    $recovered.value.authorityRecoveredCount | Should Be 1
    Assert-CompletionClosed $recover

    $tamper = New-CompletionFixture (Join-Path $TestDrive 'authority-only-tamper') 'task-complete-authority-only-tamper'
    $tamperFault = Invoke-CompleteFixture $tamper 'after_authority'
    $tamperFault.exitCode | Should Be 1
    $tamperFault.text | Should Match 'TASK_STATE_FAULT_INJECTED_AFTER_SQLITE_AUTHORITY'
    $verification = Get-Content -LiteralPath $tamper.verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $verification | Add-Member -NotePropertyName tamperedAfterAuthority -NotePropertyValue $true -Force
    Write-CompletionJson $tamper.verificationPath $verification
    $blocked = Invoke-CompletionStore @('-Action','Reconcile','-WorkspaceRoot',$tamper.workspace,'-SharedRoot',$tamper.shared,'-Apply','-Json')
    $blocked.exitCode | Should Be 1
    $blocked.value.recoveredCount | Should Be 0
    $blocked.value.authorityRecoveredCount | Should Be 0
    $blocked.value.authorityBlockedCount | Should Be 1
    $blocked.value.authorityBlocked[0].error | Should Be 'TASK_STATE_SQLITE_AUTHORITY_COMPLETION_EVIDENCE_CHANGED'
    Test-Path -LiteralPath $tamper.checkpointPath | Should Be $true
  }

  It 'does not spawn a receipt-validation subprocess after acquiring the completion mutation lock' {
    $store = Get-Content -LiteralPath $storeScript -Raw -Encoding UTF8
    $completionStart = $store.IndexOf('function Complete-TaskState')
    $completionBody = $store.Substring($completionStart)
    $lockStart = $completionBody.IndexOf('return Invoke-SuperBrainFileLock $mutationGate {')
    $lockedBody = $completionBody.Substring($lockStart)
    $lockedBody.Contains('TASK_STATE_COMPLETION_CONTRACT_CHANGED_AFTER_PRECHECK') | Should Be $true
    $lockedBody.Contains('Assert-CompletionContract $manifestValue') | Should Be $false
  }

  It 'blocks completion while the accepted checklist still has pending work' {
    $fixture = New-CompletionFixture (Join-Path $TestDrive 'pending') 'task-complete-pending' @('H','I')
    $blocked = Invoke-CompleteFixture $fixture
    $blocked.exitCode | Should Be 1
    $blocked.value.error.Contains('TASK_STATE_COMPLETION_PENDING_STEPS') | Should Be $true
    Test-Path -LiteralPath $fixture.checkpointPath | Should Be $true
  }

  It 'blocks a suspended child line from closing the parent task' {
    $fixture = New-CompletionFixture (Join-Path $TestDrive 'child') 'task-complete-child'
    $contract = Get-Content -LiteralPath $fixture.contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $contract.returnStack = @([pscustomobject]@{ focusId='parent-line'; focusLabel='Parent'; nextAction='resume parent' })
    Write-CompletionJson $fixture.contractPath $contract
    $blocked = Invoke-CompleteFixture $fixture -MaintenanceOverride
    $blocked.exitCode | Should Be 1
    $blocked.value.error.Contains('TASK_STATE_COMPLETION_PARENT_SUSPENDED') | Should Be $true
  }

  It 'rejects foreign-session contracts and stale package verification' {
    $foreign = New-CompletionFixture (Join-Path $TestDrive 'foreign') 'task-complete-foreign' @() 'sid-bbbbbbbbbbbbbbbb'
    $manifest = Get-Content -LiteralPath $foreign.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.ownerSessionKey = 'sid-cccccccccccccccc'
    Write-CompletionJson $foreign.manifestPath $manifest
    $foreignResult = Invoke-CompleteFixture $foreign
    $foreignResult.exitCode | Should Be 1
    $foreignResult.value.error.Contains('TASK_STATE_COMPLETION_SESSION_MISMATCH') | Should Be $true

    $stale = New-CompletionFixture (Join-Path $TestDrive 'stale') 'task-complete-stale' @() 'sid-dddddddddddddddd' '0.0.0-stale'
    $staleResult = Invoke-CompleteFixture $stale
    $staleResult.exitCode | Should Be 1
    $staleResult.value.error.Contains('TASK_STATE_COMPLETION_VERIFICATION_VERSION_MISMATCH') | Should Be $true
  }

  It 'fails closed for missing workspace identity, stale contract, task-instance mismatch, and foreign caller session' {
    $missingWorkspace = New-CompletionFixture (Join-Path $TestDrive 'missing-workspace') 'task-complete-missing-workspace'
    $missingContract = Get-Content -LiteralPath $missingWorkspace.contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $missingContract.PSObject.Properties.Remove('workspaceKey')
    Write-CompletionJson $missingWorkspace.contractPath $missingContract
    $missingResult = Invoke-CompleteFixture $missingWorkspace
    $missingResult.exitCode | Should Be 1
    $missingResult.value.error.Contains('TASK_STATE_COMPLETION_CONTRACT_WORKSPACE_MISMATCH') | Should Be $true

    $staleContract = New-CompletionFixture (Join-Path $TestDrive 'stale-contract') 'task-complete-stale-contract'
    $staleValue = Get-Content -LiteralPath $staleContract.contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $staleValue.updatedAt = (Get-Date).AddHours(-169).ToString('o')
    Write-CompletionJson $staleContract.contractPath $staleValue
    $staleResult = Invoke-CompleteFixture $staleContract
    $staleResult.exitCode | Should Be 1
    $staleResult.value.error.Contains('TASK_STATE_COMPLETION_CONTRACT_STALE') | Should Be $true

    $instanceMismatch = New-CompletionFixture (Join-Path $TestDrive 'instance-mismatch') 'task-complete-instance-mismatch'
    $instanceManifest = Get-Content -LiteralPath $instanceMismatch.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $instanceManifest.expectedTaskInstanceId = 'ti-fedcba9876543210fedcba9876543210'
    Write-CompletionJson $instanceMismatch.manifestPath $instanceManifest
    $instanceResult = Invoke-CompleteFixture $instanceMismatch
    $instanceResult.exitCode | Should Be 1
    $instanceResult.value.error.Contains('TASK_STATE_COMPLETION_TASK_INSTANCE_MISMATCH') | Should Be $true

    $foreignCaller = New-CompletionFixture (Join-Path $TestDrive 'foreign-caller') 'task-complete-foreign-caller'
    $foreignCallerResult = Invoke-CompleteFixture $foreignCaller 'none' 0 'sid-bbbbbbbbbbbbbbbb'
    $foreignCallerResult.exitCode | Should Be 1
    $foreignCallerResult.value.error.Contains('TASK_STATE_COMPLETION_CALLER_SESSION_MISMATCH') | Should Be $true
  }

  It 'rejects historical, tampered, and source-tree-mismatched verification evidence without closing state' {
    $historical = New-CompletionFixture (Join-Path $TestDrive 'historical') 'task-complete-historical'
    $historicalManifest = Get-Content -LiteralPath $historical.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $historicalVerification = Get-Content -LiteralPath $historical.verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $historicalManifest.PSObject.Properties.Remove('evidenceBinding')
    $historicalVerification.PSObject.Properties.Remove('evidenceBinding')
    Write-CompletionJson $historical.manifestPath $historicalManifest
    Write-CompletionJson $historical.verificationPath $historicalVerification
    $historicalResult = Invoke-CompleteFixture $historical
    $historicalResult.exitCode | Should Be 1
    $historicalResult.value.error.Contains('TASK_STATE_COMPLETION_VERIFICATION_HISTORICAL') | Should Be $true
    Test-Path -LiteralPath $historical.checkpointPath | Should Be $true

    $tampered = New-CompletionFixture (Join-Path $TestDrive 'tampered') 'task-complete-tampered'
    $tamperedVerification = Get-Content -LiteralPath $tampered.verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tamperedVerification | Add-Member -NotePropertyName tamperedAfterVerification -NotePropertyValue $true -Force
    Write-CompletionJson $tampered.verificationPath $tamperedVerification
    $tamperedResult = Invoke-CompleteFixture $tampered
    $tamperedResult.exitCode | Should Be 1
    $tamperedResult.value.error.Contains('evidence_artifact_hash_mismatch') | Should Be $true
    Test-Path -LiteralPath $tampered.checkpointPath | Should Be $true

    $treeMismatch = New-CompletionFixture (Join-Path $TestDrive 'tree-mismatch') 'task-complete-tree-mismatch'
    $treeManifest = Get-Content -LiteralPath $treeMismatch.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $treeVerification = Get-Content -LiteralPath $treeMismatch.verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $treeVerification.evidenceBinding.gitTreeHash = ('0' * 64)
    Write-CompletionJson $treeMismatch.verificationPath $treeVerification
    $treeManifest.evidenceBinding.gitTreeHash = ('0' * 64)
    $treeManifest.evidenceBinding.artifactHash = (Get-FileHash -LiteralPath $treeMismatch.verificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-CompletionJson $treeMismatch.manifestPath $treeManifest
    $treeResult = Invoke-CompleteFixture $treeMismatch
    $treeResult.exitCode | Should Be 1
    $treeResult.value.error.Contains('evidence_git_tree_mismatch') | Should Be $true
    Test-Path -LiteralPath $treeMismatch.checkpointPath | Should Be $true
  }

  It 'fails closed when completion evidence changes after WAL prepare' {
    $fixture = New-CompletionFixture (Join-Path $TestDrive 'prepare-tamper') 'task-complete-prepare-tamper'
    $prepared = Invoke-CompleteFixture $fixture 'after_prepare'
    $prepared.exitCode | Should Be 1
    $verification = Get-Content -LiteralPath $fixture.verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $verification | Add-Member -NotePropertyName tamperedAfterPrepare -NotePropertyValue $true -Force
    Write-CompletionJson $fixture.verificationPath $verification
    $reconciled = Invoke-CompletionStore @('-Action','Reconcile','-WorkspaceRoot',$fixture.workspace,'-SharedRoot',$fixture.shared,'-Apply','-Json')
    $reconciled.exitCode | Should Be 1
    $reconciled.value.recoveredCount | Should Be 0
    $reconciled.value.blocked[0].reason | Should Be 'completion_artifact_changed_after_prepare'
    Test-Path -LiteralPath $fixture.checkpointPath | Should Be $true
  }

  It 'does not alter a legitimate parallel task' {
    $base = Join-Path $TestDrive 'parallel'
    $first = New-CompletionFixture $base 'task-complete-parallel-a'
    $second = New-CompletionFixture $base 'task-complete-parallel-b' @() 'sid-eeeeeeeeeeeeeeee'
    $completed = Invoke-CompleteFixture $first
    $completed.exitCode | Should Be 0
    Assert-CompletionClosed $first
    Test-Path -LiteralPath $second.contextPath | Should Be $true
    Test-Path -LiteralPath $second.checkpointPath | Should Be $true
    Test-Path -LiteralPath $second.taskCardPath | Should Be $true
    Test-Path -LiteralPath $second.contractPath | Should Be $true
  }
}

Describe 'Task completion intent fulfillment' {
  It 'blocks structural completion before WAL when intent fulfillment evidence is missing' {
    $fixture = New-CompletionFixture (Join-Path $TestDrive 'intent-missing') 'task-complete-intent-missing' @() 'sid-aaaaaaaaaaaaaaaa' '' 'missing'
    $result = Invoke-CompleteFixture $fixture
    $result.exitCode | Should Be 1
    $result.value.error | Should Match 'TASK_STATE_COMPLETION_INTENT_FULFILLMENT_REQUIRED'
    $eventPath=Get-SuperBrainCanonicalTaskPath (Join-Path $fixture.workspace 'task-state-store\events') $fixture.taskId '.jsonl'
    $completionPrepared=@(Get-Content -LiteralPath $eventPath -Encoding UTF8|ForEach-Object{$_|ConvertFrom-Json}|Where-Object{[string]$_.transactionKind-eq'task_completion'-and[string]$_.phase-eq'prepared'})
    $completionPrepared.Count | Should Be 0
  }

  It 'commits structural completion only when every intent requirement has evidence' {
    $fixture = New-CompletionFixture (Join-Path $TestDrive 'intent-complete') 'task-complete-intent-current' @() 'sid-aaaaaaaaaaaaaaaa' '' 'complete'
    $result = Invoke-CompleteFixture $fixture
    $result.exitCode | Should Be 0
    $result.value.intentFulfillmentFingerprint | Should Be $fixture.intentFulfillmentFingerprint
    Assert-CompletionClosed $fixture
  }
}
