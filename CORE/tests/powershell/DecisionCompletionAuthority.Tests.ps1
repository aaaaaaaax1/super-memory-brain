$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$storeScript = Join-Path $root 'scripts\task-state-store.ps1'
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$bindingScript = Join-Path $root 'scripts\decision-binding.ps1'
. (Join-Path $root 'scripts\common.ps1')

function Write-DecisionCompletionJson([string]$Path,[object]$Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
}

function Invoke-DecisionCompletionStore([string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $storeScript @Arguments 2>&1)
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=if([string]::IsNullOrWhiteSpace($text)){$null}else{$text|ConvertFrom-Json}; text=$text }
}

function Invoke-DecisionCompletionBinding([string]$StateRoot,[string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bindingScript @Arguments -StateRoot $StateRoot -Json 2>&1)
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'DECISION_COMPLETION_BINDING_EMPTY_OUTPUT' }
  return $text | ConvertFrom-Json
}

function New-DecisionCompletionFixture([string]$Base,[string]$TaskId) {
  $workspace = Join-Path $Base 'workspace'
  $shared = Join-Path $Base 'shared'
  $workspaceKey = 'ws-111111111111111111111111'
  $sessionKey = 'sid-aaaaaaaaaaaaaaaa'
  $version = [string](Get-SuperBrainManifest $root).version
  $token = Get-SuperBrainCanonicalTaskToken $TaskId
  $contextPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'guard-state\current-task-contexts') $TaskId '.json'
  $checkpointPath = Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'runtime-state\checkpoints\active') $TaskId '.json'
  $taskCardPath = Get-SuperBrainCanonicalTaskPath (Join-Path $shared 'tasks\active') $TaskId '.task.json'
  $stage = Join-Path $workspace (Join-Path 'task-state-store\staging' $token)
  $completedCheckpointPayload = Join-Path $stage 'completed-checkpoint.json'
  $completedTaskCardPayload = Join-Path $stage 'completed-task-card.json'
  $verificationPath = Join-Path $stage 'verification.json'
  $manifestPath = Join-Path $stage 'completion-manifest.json'
  $owner = @{ agentId='decision-agent'; sessionId='decision-session'; platform='codex'; workspace='G:\decision-completion-tests' }
  $context = [pscustomobject]@{ schema='super-brain.current-task-context.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='active'; stale=$false; acceptedGoal='publish a governed release'; agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace }
  $checkpoint = [pscustomobject]@{ schema='super-brain.checkpoint.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='active'; pendingSteps=@(); completedSteps=@('release artifacts verified'); currentStep='complete'; nextAction='complete'; agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace }
  $taskCard = [pscustomobject]@{ schema='super-brain.task-card.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='active'; pendingSteps=@(); completedSteps=@('release artifacts verified'); agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace }
  $completedCheckpoint = [pscustomobject]@{ schema='super-brain.checkpoint.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='completed'; pendingSteps=@(); completedSteps=@('done'); source='task-verification.ps1'; agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace }
  $completedTaskCard = [pscustomobject]@{ schema='super-brain.task-card.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; status='completed'; pendingSteps=@(); completedSteps=@('done'); source='checkpoint-writer.ps1'; agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace }
  $contextPayload = Join-Path $stage 'context.json'; $checkpointPayload = Join-Path $stage 'checkpoint.json'; $taskCardPayload = Join-Path $stage 'task-card.json'
  foreach ($pair in @(@($contextPayload,$context),@($checkpointPayload,$checkpoint),@($taskCardPayload,$taskCard),@($completedCheckpointPayload,$completedCheckpoint),@($completedTaskCardPayload,$completedTaskCard))) { Write-DecisionCompletionJson $pair[0] $pair[1] }
  $ownerArgs = @('-OwnerAgentId',$owner.agentId,'-OwnerSessionId',$owner.sessionId,'-OwnerPlatform',$owner.platform,'-OwnerWorkspace',$owner.workspace)
  $commit = { param($kind,$payload,$target,$revision) Invoke-DecisionCompletionStore (@('-Action','Commit','-TaskId',$TaskId,'-EntityKind',$kind,'-Operation','upsert','-PayloadPath',$payload,'-EntityPath',$target,'-ExpectedRevision',[string]$revision,'-WorkspaceRoot',$workspace,'-SharedRoot',$shared,'-Source','DecisionCompletionAuthority.Tests.ps1','-Json') + $ownerArgs) }
  (& $commit 'context' $contextPayload $contextPath 0).exitCode | Should Be 0
  (& $commit 'checkpoint' $checkpointPayload $checkpointPath 1).exitCode | Should Be 0
  (& $commit 'task_card' $taskCardPayload $taskCardPath 2).exitCode | Should Be 0

  $registered = Invoke-DecisionCompletionBinding $Base @('-Action','Register','-DecisionId','release-archive','-WorkspaceKey',$workspaceKey,'-StageKinds','release','-Enforcement','completion_gate','-Authority','user_confirmed','-Lifecycle','active','-ContentHash',('a'*64),'-CompletionCriteriaDigest',('b'*64),'-PrivateGuidance','archive all release deliverables together')
  $registered.ok | Should Be $true
  $contractRaw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $contractScript -Action Set -TaskId $TaskId -WorkspaceKey $workspaceKey -SessionKey $sessionKey -FocusId 'release-main' -LatestUserInstruction 'release artifacts ready' -AssistantCommitment 'deliver the release archive' -NextAction 'release artifacts ready' -CurrentPhase release -CurrentStep 'release artifacts ready' -CompletedSteps 'release artifacts ready' -DecisionIntentFingerprint 'release-intent' -StateRoot $Base -NoExit -Json 2>&1)
  $contract = ConvertFrom-SuperBrainJsonOutput ($contractRaw -join "`n") 'decision completion fixture contract'
  $contract.ok | Should Be $true
  $contract.needsReconciliation = $false
  Write-DecisionCompletionJson ([string]$contract.path) $contract
  $evidenceBinding = New-SuperBrainEvidenceBinding -TaskId $TaskId -WorkspaceKey $workspaceKey -OwnerSessionKey $sessionKey -Root $root
  $verification = [pscustomobject]@{ schema='super-brain.task-verification.v1'; ok=$true; taskId=$TaskId; workspaceKey=$workspaceKey; version=$version; nextSteps=@(); checkedAt=(Get-Date).ToString('o'); evidenceBinding=$evidenceBinding }
  Write-DecisionCompletionJson $verificationPath $verification
  $completionBinding = [pscustomobject]@{ schema=[string]$evidenceBinding.schema; packageVersion=[string]$evidenceBinding.packageVersion; gitTreeHash=[string]$evidenceBinding.gitTreeHash; treeAlgorithm=[string]$evidenceBinding.treeAlgorithm; gitHeadTreeHash=[string]$evidenceBinding.gitHeadTreeHash; taskId=[string]$evidenceBinding.taskId; workspaceKey=[string]$evidenceBinding.workspaceKey; ownerSessionKey=[string]$evidenceBinding.ownerSessionKey; artifactHash=(Get-FileHash -LiteralPath $verificationPath -Algorithm SHA256).Hash.ToLowerInvariant(); artifactKind='task_verification' }
  $manifest = [pscustomobject]@{ schema='super-brain.task-completion-manifest.v1'; taskId=$TaskId; workspaceKey=$workspaceKey; packageVersion=$version; completionStatus='completed'; ownerSessionKey=$sessionKey; callerSessionKey=$sessionKey; expectedTaskInstanceId=[string]$contract.taskInstanceId; expectedPlanFingerprint=[string]$contract.planReceipt.planFingerprint; expectedContractRevision=[int]$contract.revision; completedCheckpointPayloadPath=$completedCheckpointPayload; completedTaskCardPayloadPath=$completedTaskCardPayload; executionContractPath=[string]$contract.path; verificationPath=$verificationPath; evidenceBinding=$completionBinding; source='DecisionCompletionAuthority.Tests.ps1' }
  Write-DecisionCompletionJson $manifestPath $manifest
  return [pscustomobject]@{ taskId=$TaskId; workspace=$workspace; shared=$shared; workspaceKey=$workspaceKey; sessionKey=$sessionKey; contract=$contract; verificationPath=$verificationPath; manifestPath=$manifestPath; completionBinding=$completionBinding; ownerArgs=$ownerArgs }
}

function Invoke-DecisionCompletion([object]$Fixture) {
  return Invoke-DecisionCompletionStore (@('-Action','CompleteTask','-TaskId',$Fixture.taskId,'-CompletionManifestPath',$Fixture.manifestPath,'-ExpectedRevision','3','-WorkspaceRoot',$Fixture.workspace,'-SharedRoot',$Fixture.shared,'-Source','DecisionCompletionAuthority.Tests.ps1','-CallerSessionKey',$Fixture.sessionKey,'-Json') + $Fixture.ownerArgs)
}

function Add-DecisionCompletionResult([object]$Fixture) {
  $contract = $Fixture.contract
  $record = Invoke-DecisionCompletionBinding (Split-Path -Parent $Fixture.workspace) @('-Action','RecordResult','-TaskId',$Fixture.taskId,'-TaskInstanceId',[string]$contract.taskInstanceId,'-WorkspaceKey',$Fixture.workspaceKey,'-WorklineId',[string]$contract.focusId,'-StageKind',[string]$contract.stageKind,'-IntentFingerprint',[string]$contract.decisionIntentFingerprint,'-ContractRevision',[string]$contract.revision,'-PlanFingerprint',[string]$contract.planReceipt.planFingerprint,'-OwnerSessionKey',$Fixture.sessionKey,'-ReceiptPath',[string]$contract.decisionBinding.path,'-BindingDigest',[string]$contract.decisionBinding.bindingDigest,'-DecisionId','release-archive','-Revision','1','-ResultOk','-EvidenceRefs','release-archive-manifest')
  $record.ok | Should Be $true
  $validated = Invoke-DecisionCompletionBinding (Split-Path -Parent $Fixture.workspace) @('-Action','ValidateCompletion','-TaskId',$Fixture.taskId,'-TaskInstanceId',[string]$contract.taskInstanceId,'-WorkspaceKey',$Fixture.workspaceKey,'-WorklineId',[string]$contract.focusId,'-StageKind',[string]$contract.stageKind,'-IntentFingerprint',[string]$contract.decisionIntentFingerprint,'-ContractRevision',[string]$contract.revision,'-PlanFingerprint',[string]$contract.planReceipt.planFingerprint,'-OwnerSessionKey',$Fixture.sessionKey,'-ReceiptPath',[string]$contract.decisionBinding.path)
  $validated.ok | Should Be $true
  $verification = Get-Content -LiteralPath $Fixture.verificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $verification | Add-Member -NotePropertyName decisionBinding -NotePropertyValue ([pscustomobject]@{ required=$true; ok=$true; status=[string]$validated.status; code=[string]$validated.code; stageKind=[string]$contract.stageKind; bindingDigest=[string]$validated.bindingDigest; results=@($validated.results); rawDecisionBodyStored=$false }) -Force
  Write-DecisionCompletionJson $Fixture.verificationPath $verification
  $manifest = Get-Content -LiteralPath $Fixture.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $manifest.evidenceBinding.artifactHash = (Get-FileHash -LiteralPath $Fixture.verificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-DecisionCompletionJson $Fixture.manifestPath $manifest
}

Describe 'Decision completion authority' {
  It 'does not allow a task to close until the bound delivery decision has a current result' {
    $fixture = New-DecisionCompletionFixture (Join-Path $TestDrive 'missing') 'task-decision-completion-missing'
    $blocked = Invoke-DecisionCompletion $fixture
    $blocked.exitCode | Should Be 1
    $blocked.value.error | Should Match 'TASK_STATE_COMPLETION_DECISION_RESULTS_UNSATISFIED'
    Test-Path -LiteralPath (Get-SuperBrainCanonicalTaskPath (Join-Path $fixture.workspace 'runtime-state\checkpoints\active') $fixture.taskId '.json') | Should Be $true
  }

  It 'closes only after the same task, plan, session, and binding digest have passing result evidence' {
    $fixture = New-DecisionCompletionFixture (Join-Path $TestDrive 'passing') 'task-decision-completion-passing'
    Add-DecisionCompletionResult $fixture
    $completed = Invoke-DecisionCompletion $fixture
    $completed.exitCode | Should Be 0
    $projectionPath = Get-SuperBrainCanonicalTaskPath (Join-Path $fixture.workspace 'task-state-store\projections') $fixture.taskId '.json'
    $projection = Get-Content -LiteralPath $projectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $projection.lifecycle.status | Should Be 'completed'
    $projection.lifecycle.decisionBinding.bindingDigest | Should Be $fixture.contract.decisionBinding.bindingDigest
  }
}
