$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:decisionBindingScript = Join-Path $root 'scripts\decision-binding.ps1'
$script:executionContractScript = Join-Path $root 'scripts\execution-contract.ps1'
. (Join-Path $PSScriptRoot 'H7TestFixture.ps1')

function Invoke-DecisionBindingTestScript([string]$StateRoot,[string[]]$Arguments) {
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:decisionBindingScript @Arguments -StateRoot $StateRoot -Json 2>&1)
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'DECISION_BINDING_TEST_EMPTY_OUTPUT' }
  return $text | ConvertFrom-Json
}

function New-DecisionBindingTestIdentity([string]$Suffix) {
  return [pscustomobject]@{
    taskId = 'task-decision-binding-' + $Suffix
    taskInstanceId = 'ti-0123456789abcdef0123456789abcdef'
    workspaceKey = 'ws-decision-binding-' + $Suffix
    ownerSessionKey = 'sid-decision-binding-' + $Suffix
    planFingerprint = ('p' * 64)
  }
}

function Invoke-DecisionContractTestScript([string]$StateRoot,[string[]]$Arguments) {
  $boundArguments = @($Arguments) + @('-StateRoot',$StateRoot,'-NoExit','-Json')
  $boundArguments = @(Add-H7FixtureCheckpointArguments -Arguments $boundArguments -Root $root)
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:executionContractScript @boundArguments 2>&1)
  $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { throw 'DECISION_CONTRACT_TEST_EMPTY_OUTPUT' }
  return $text | ConvertFrom-Json
}

Describe 'Decision-to-execution binding' {
  BeforeEach {
    $script:stateRoot = Join-Path $env:TEMP ('sbdb-' + [guid]::NewGuid().ToString('n').Substring(0,8))
    $script:identity = New-DecisionBindingTestIdentity ([guid]::NewGuid().ToString('n').Substring(0,8))
    $script:contentHash = ('a' * 64)
    $script:criteriaHash = ('b' * 64)
  }

  AfterEach {
    if (Test-Path -LiteralPath $script:stateRoot) { Remove-Item -LiteralPath $script:stateRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'rejects local success until every bound completion decision has a current result' {
    $registered = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','Register','-DecisionId','release-archive','-WorkspaceKey',$script:identity.workspaceKey,
      '-StageKinds','release','-Enforcement','completion_gate','-Authority','user_confirmed','-Lifecycle','active',
      '-ContentHash',$script:contentHash,'-CompletionCriteriaDigest',$script:criteriaHash,'-PrivateGuidance','archive the executable, installer, notes, and test report together'
    )
    $registered.ok | Should Be $true

    $resolved = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','Resolve','-TaskId',$script:identity.taskId,'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey',$script:identity.workspaceKey,'-WorklineId','main','-StageKind','release','-IntentFingerprint','release-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey
    )
    $resolved.status | Should Be 'bound'

    $guidance = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','GetPrivateGuidance','-TaskId',$script:identity.taskId,'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey',$script:identity.workspaceKey,'-WorklineId','main','-StageKind','release','-IntentFingerprint','release-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey,
      '-ReceiptPath',$resolved.path
    )
    $guidance.ok | Should Be $true
    $guidance.guidance[0].text | Should Match 'archive the executable'

    $before = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','ValidateCompletion','-TaskId',$script:identity.taskId,'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey',$script:identity.workspaceKey,'-WorklineId','main','-StageKind','release','-IntentFingerprint','release-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey,
      '-ReceiptPath',$resolved.path
    )
    $before.ok | Should Be $false
    $before.code | Should Be 'DECISION_BINDING_COMPLETION_RESULTS_UNSATISFIED'

    $written = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','RecordResult','-TaskId',$script:identity.taskId,'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey',$script:identity.workspaceKey,'-WorklineId','main','-StageKind','release','-IntentFingerprint','release-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey,
      '-ReceiptPath',$resolved.path,'-BindingDigest',$resolved.bindingDigest,'-DecisionId','release-archive','-Revision','1','-ResultOk','-EvidenceRefs','archive-manifest'
    )
    $written.ok | Should Be $true

    $after = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','ValidateCompletion','-TaskId',$script:identity.taskId,'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey',$script:identity.workspaceKey,'-WorklineId','main','-StageKind','release','-IntentFingerprint','release-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey,
      '-ReceiptPath',$resolved.path
    )
    $after.ok | Should Be $true
    $after.code | Should Be 'DECISION_BINDING_COMPLETION_RESULTS_CURRENT'
  }

  It 'fails closed for overlapping hard decisions and never treats a foreign workspace as current' {
    foreach ($id in @('release-archive','release-notes')) {
      $registered = Invoke-DecisionBindingTestScript $script:stateRoot @(
        '-Action','Register','-DecisionId',$id,'-WorkspaceKey',$script:identity.workspaceKey,
        '-StageKinds','release','-Enforcement','completion_gate','-Authority','user_confirmed','-Lifecycle','active',
        '-ContentHash',$script:contentHash,'-CompletionCriteriaDigest',$script:criteriaHash
      )
      $registered.ok | Should Be $true
    }

    $withheld = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','Resolve','-TaskId',$script:identity.taskId,'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey',$script:identity.workspaceKey,'-WorklineId','main','-StageKind','release','-IntentFingerprint','release-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey
    )
    $withheld.ok | Should Be $false
    $withheld.status | Should Be 'withheld'

    $foreign = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','Resolve','-TaskId',$script:identity.taskId,'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey','ws-foreign','-WorklineId','main','-StageKind','package','-IntentFingerprint','package-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey
    )
    $foreign.ok | Should Be $true
    $foreign.status | Should Be 'none_applicable'
  }

  It 'rejects a valid receipt when another task attempts to reuse it' {
    $registered = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','Register','-DecisionId','release-archive','-WorkspaceKey',$script:identity.workspaceKey,
      '-StageKinds','release','-Enforcement','completion_gate','-Authority','user_confirmed','-Lifecycle','active',
      '-ContentHash',$script:contentHash,'-CompletionCriteriaDigest',$script:criteriaHash
    )
    $registered.ok | Should Be $true
    $resolved = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','Resolve','-TaskId',$script:identity.taskId,'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey',$script:identity.workspaceKey,'-WorklineId','main','-StageKind','release','-IntentFingerprint','release-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey
    )
    $resolved.ok | Should Be $true
    $foreign = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','ValidateReceipt','-TaskId',($script:identity.taskId + '-foreign'),'-TaskInstanceId',$script:identity.taskInstanceId,
      '-WorkspaceKey',$script:identity.workspaceKey,'-WorklineId','main','-StageKind','release','-IntentFingerprint','release-intent',
      '-ContractRevision','1','-PlanFingerprint',$script:identity.planFingerprint,'-OwnerSessionKey',$script:identity.ownerSessionKey,
      '-ReceiptPath',$resolved.path
    )
    $foreign.ok | Should Be $false
    $foreign.code | Should Be 'DECISION_BINDING_RECEIPT_TASKID_MISMATCH'
  }

  It 'keeps automatic phase labels direct until a typed decision registry exists while preserving explicit binding' {
    $automatic = Invoke-DecisionContractTestScript $script:stateRoot @(
      '-Action','Set','-TaskId',$script:identity.taskId,'-WorkspaceKey',$script:identity.workspaceKey,'-SessionKey',$script:identity.ownerSessionKey,
      '-FocusId','release-main','-LatestUserInstruction','prepare release artifacts','-AssistantCommitment','deliver the release',
      '-NextAction','prepare release artifacts','-CurrentPhase','release','-CurrentStep','prepare release archive','-PendingSteps','verify release archive'
    )
    $automatic.ok | Should Be $true
    $automatic.stageKind | Should Be ''
    $automatic.decisionBinding | Should Be $null
    (Test-Path -LiteralPath (Join-Path $script:stateRoot 'workspace\db\index.json') -PathType Leaf) | Should Be $false

    $explicit = Invoke-DecisionContractTestScript $script:stateRoot @(
      '-Action','Set','-TaskId',($script:identity.taskId + '-explicit'),'-WorkspaceKey',$script:identity.workspaceKey,'-SessionKey',$script:identity.ownerSessionKey,
      '-FocusId','release-explicit','-LatestUserInstruction','prepare release artifacts','-AssistantCommitment','deliver the release',
      '-NextAction','prepare release artifacts','-CurrentPhase','release','-CurrentStep','prepare release archive','-PendingSteps','verify release archive',
      '-StageKind','release','-DecisionIntentFingerprint','release-intent'
    )
    $explicit.ok | Should Be $true
    $explicit.stageKind | Should Be 'release'
    $explicit.decisionBinding.status | Should Be 'none_applicable'
  }

  It 'keeps automatic decision routing direct across parent resumption and retained merge completion before a registry exists' {
    $taskId = $script:identity.taskId + '-merge'
    $main = Invoke-DecisionContractTestScript $script:stateRoot @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$script:identity.workspaceKey,'-SessionKey',$script:identity.ownerSessionKey,
      '-FocusId','main-line','-FocusLabel','Main line','-TopicKeys','main-merge-target','-LatestUserInstruction','prepare release delivery',
      '-AssistantCommitment','deliver the release','-NextAction','finish release','-CurrentPhase','release','-CurrentStep','prepare release archive'
    )
    $main.ok | Should Be $true
    $main.stageKind | Should Be ''

    $side = Invoke-DecisionContractTestScript $script:stateRoot @(
      '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$script:identity.workspaceKey,'-SessionKey',$script:identity.ownerSessionKey,
      '-InstructionMode','side_branch','-FocusId','ui-backend','-FocusLabel','UI backend','-TopicKeys','ui-backend',
      '-LatestUserInstruction','finish retained UI backend work','-AssistantCommitment','retain verified merge evidence',
      '-NextAction','finish UI backend','-CompletedSteps','prototype completed','-Evidence','artifact inspected',
      '-VerificationResults','manual test passed','-RetainForMerge','-ArtifactRefs','prototype/ui.html',
      '-InterfaceContracts','backend API v1','-Dependencies','backend service','-VerificationSteps','verify UI API mapping'
    )
    $side.ok | Should Be $true

    $resumed = Invoke-DecisionContractTestScript $script:stateRoot @(
      '-Action','ResumeParent','-TaskId',$taskId,'-WorkspaceKey',$script:identity.workspaceKey,'-SessionKey',$script:identity.ownerSessionKey,
      '-BranchStatus','completed','-CompletionEvidence','UI backend branch verified'
    )
    $resumed.ok | Should Be $true
    $resumed.stageKind | Should Be ''
    @($resumed.mergeIntents).Count | Should Be 1

    $prepared = Invoke-DecisionContractTestScript $script:stateRoot @(
      '-Action','PrepareMerge','-TaskId',$taskId,'-WorkspaceKey',$script:identity.workspaceKey,'-SessionKey',$script:identity.ownerSessionKey,
      '-MergeIntentId',[string]$resumed.mergeIntents[0].mergeIntentId
    )
    $prepared.ok | Should Be $true

    $completed = Invoke-DecisionContractTestScript $script:stateRoot @(
      '-Action','CompleteMerge','-TaskId',$taskId,'-WorkspaceKey',$script:identity.workspaceKey,'-SessionKey',$script:identity.ownerSessionKey,
      '-MergeIntentId',[string]$resumed.mergeIntents[0].mergeIntentId,
      '-MergeIntegrationEvidence','integrated retained UI artifact through backend API v1'
    )
    $completed.ok | Should Be $true
    $completed.stageKind | Should Be ''
    (Test-Path -LiteralPath (Join-Path $script:stateRoot 'workspace\db\index.json') -PathType Leaf) | Should Be $false
  }

  It 'materializes an exact stage receipt in the execution contract without copying a decision body' {
    $null = Invoke-DecisionBindingTestScript $script:stateRoot @(
      '-Action','Register','-DecisionId','release-archive','-WorkspaceKey',$script:identity.workspaceKey,
      '-StageKinds','release','-Enforcement','completion_gate','-Authority','user_confirmed','-Lifecycle','active',
      '-ContentHash',$script:contentHash,'-CompletionCriteriaDigest',$script:criteriaHash
    )
    $contract = Invoke-DecisionContractTestScript $script:stateRoot @(
      '-Action','Set','-TaskId',$script:identity.taskId,'-WorkspaceKey',$script:identity.workspaceKey,'-SessionKey',$script:identity.ownerSessionKey,
      '-FocusId','release-main','-LatestUserInstruction','prepare the release','-AssistantCommitment','publish the verified release archive',
      '-NextAction','materialize release artifacts','-CurrentPhase','release','-CurrentStep','prepare release archive','-PendingSteps','verify release archive',
      '-DecisionIntentFingerprint','release-intent'
    )
    $contract.ok | Should Be $true
    $contract.stageKind | Should Be 'release'
    $contract.decisionBinding.status | Should Be 'bound'
    $contract.decisionBinding.receiptSchema | Should Be 'super-brain.decision-resolution-receipt.v2'
    [string]$contract.decisionBinding.receiptId | Should Match '^decision-composite-[a-f0-9]{16}$'
    [string]$contract.decisionBinding.bindingDigest | Should Match '^[a-f0-9]{64}$'
    [string]$contract.decisionBinding.packageManifestHash | Should Match '^[a-f0-9]{64}$'
    ($contract.PSObject.Properties['decisionBinding'] -and ($contract.decisionBinding | ConvertTo-Json -Depth 8) -notmatch 'release archive') | Should Be $true
  }
}
