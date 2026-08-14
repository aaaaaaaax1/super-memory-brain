$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Contract = Join-Path $Root 'scripts\execution-contract.ps1'
$Hook = Join-Path $Root 'scripts\codex-user-prompt-hook.ps1'
$NativeHook = Join-Path $Root 'runtime\codex_prompt_hook.py'
. (Join-Path $Root 'scripts\common.ps1')
. (Join-Path $Root 'scripts\internal\runtime-wake-core.ps1')

function Invoke-RuntimeWakeContract([hashtable]$Parameters) {
  $Parameters.StateRoot = $script:RuntimeWakeStateRoot
  $Parameters.NoExit = $true
  $Parameters.Json = $true
  $raw = @(& $Contract @Parameters 2>$null)
  return (($raw -join "`n") | ConvertFrom-Json)
}

function New-RuntimeWakeRouteSignals(
  [bool]$HookCandidate=$false,
  [bool]$Continuity=$false,
  [bool]$ContextReply=$false,
  [bool]$ExplicitSuperBrain=$false,
  [bool]$ActionEntry=$false,
  [string]$ActionKind=''
) {
  return [pscustomobject]@{
    hookCandidate=$HookCandidate
    continuitySignal=$Continuity
    contextReplySignal=$ContextReply
    explicitSuperBrain=$ExplicitSuperBrain
    workflowPreferenceSignal=$false
    actionEntrySignal=$ActionEntry
    actionKind=$ActionKind
  }
}

function Invoke-NativeRuntimeWakeHook([string]$Payload) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $previousDispatched = $env:SUPER_BRAIN_HOOK_DISPATCHED
  try {
    # This test invokes the package-native handler directly.  Do not allow an
    # unrelated installed Desktop dispatcher to turn an isolated fixture into
    # a global binding/integration test.
    $env:SUPER_BRAIN_HOOK_DISPATCHED = '1'
    $raw = @($Payload | & python -X utf8 $NativeHook --package-root $Root 2>$null)
  } finally {
    if ($null -eq $previousDispatched) { Remove-Item Env:\SUPER_BRAIN_HOOK_DISPATCHED -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_HOOK_DISPATCHED = $previousDispatched }
  }
  $watch.Stop()
  return [pscustomobject]@{
    raw = @($raw)
    exitCode = $LASTEXITCODE
    envelopeMs = [int]$watch.ElapsedMilliseconds
  }
}

function Get-RuntimeWakeTelemetryPath([string]$StateRoot,[string]$SessionKey,[string]$WorkspaceKey) {
  return Join-Path $StateRoot ('workspace\runtime-state\prompt-hook-telemetry\'+$SessionKey+'--'+$WorkspaceKey+'.json')
}

Describe 'Runtime wake control plane' {
  BeforeEach {
    $script:PreviousWakeStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $script:PreviousWakeWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    $script:RuntimeWakeStateRoot = Join-Path $TestDrive ('runtime-wake-'+[guid]::NewGuid().ToString('n'))
    $script:RuntimeWakeWorkspaceKey = 'ws-e11111111111111111111111'
    $script:RuntimeWakeSessionKey = 'sid-e111111111111111111111111'
    $env:SUPER_BRAIN_STATE_ROOT = $script:RuntimeWakeStateRoot
    $env:SUPER_BRAIN_WORKSPACE_KEY = $script:RuntimeWakeWorkspaceKey
  }

  AfterEach {
    if ($null -eq $script:PreviousWakeStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $script:PreviousWakeStateRoot }
    if ($null -eq $script:PreviousWakeWorkspaceKey) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $script:PreviousWakeWorkspaceKey }
  }

  It 'writes a bounded non-executable session and workspace hot index' {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-index';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake reliability';TopicKeys=@('runtime-wake')
      CurrentStep='preserve automatic recall latency and feature parity'
      NextAction='SECRET_ACTION_SENTINEL_SHOULD_NOT_ENTER_THE_HOT_INDEX_BODY'
      AssistantCommitment='SECRET_COMMITMENT_SENTINEL_SHOULD_NOT_ENTER_THE_HOT_INDEX_BODY'
    }
    $created.ok | Should Be $true

    $path = Get-SuperBrainRuntimeWakeIndexPath $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    Test-Path -LiteralPath $path | Should Be $true
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
    $index = $text | ConvertFrom-Json
    $index.schema | Should Be 'super-brain.execution-hot-index.v1'
    [int]$index.entryCount | Should Be 1
    [int]$index.entries[0].lineCount | Should Be 1
    $index.rawPromptStored | Should Be $false
    $index.memoryBodyStored | Should Be $false
    $index.executableActionStored | Should Be $false
    $text.ToLowerInvariant().Contains('secret_action_sentinel_should_not_enter_the_hot_index_body') | Should Be $false
    $text.ToLowerInvariant().Contains('secret_commitment_sentinel_should_not_enter_the_hot_index_body') | Should Be $false
    ($text.Length -lt 8192) | Should Be $true
  }

  It 'filters secret-shaped topic data before it reaches the hot index' {
    $secretKey = 'api' + '_key'
    $secretValue = 'super' + 'secretvalue'
    $secondSecret = 'another' + 'secretvalue'
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-redaction';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-redaction';FocusLabel='Runtime wake redaction';TopicKeys=@('runtime-wake',($secretKey+'='+$secretValue))
      CurrentStep='verify sensitive cache filtering';NextAction='verify no secret reaches the hot index'
      AssistantCommitment=(('to'+'ken')+'='+$secondSecret+' must not become a wake term')
    }
    $path = Get-SuperBrainRuntimeWakeIndexPath $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
    $text.Contains($secretValue) | Should Be $false
    $text.Contains($secondSecret) | Should Be $false
    $text.Contains('[REDACTED]') | Should Be $false
    $created.ok | Should Be $true
  }

  It 'rebuilds a hot index from bounded recovery evidence' {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-recovery';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-recovery';FocusLabel='Runtime wake recovery';TopicKeys=@('runtime-wake-recovery')
      CurrentStep='rebuild the bounded hot index';NextAction='verify recovery evidence'
    }
    $indexPath = Get-SuperBrainRuntimeWakeIndexPath $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    $markerPath = Get-SuperBrainRuntimeWakeRecoveryPath $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey 'task-runtime-wake-recovery'
    Remove-Item -LiteralPath $indexPath -Force
    (Write-SuperBrainRuntimeWakeRecoveryMarker $script:RuntimeWakeStateRoot $created 'RUNTIME_WAKE_TEST_RECOVERY') | Should Be $true
    $recovered = Restore-SuperBrainRuntimeWakeRecovery $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    $recovered.schema | Should Be 'super-brain.execution-hot-index.v1'
    (Test-Path -LiteralPath $markerPath) | Should Be $false
    $decision = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'runtime-wake-recovery' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey (New-RuntimeWakeRouteSignals) ([string]$created.packageVersion)
    $decision.shouldWake | Should Be $true
  }

  It 'classifies a semantic state dependency without a continuation keyword' {
    Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-affinity';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake reliability';TopicKeys=@('wake-control')
      CurrentStep='prevent regression while keeping automatic recall fast'
      NextAction='measure automatic recall latency and preserve parity'
      AssistantCommitment='retain prior capability while improving runtime wake'
    } | Out-Null
    $observed = Invoke-RuntimeWakeContract @{
      Action='ObserveUser';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      UserInstruction='do not regress the existing automatic recall speed';RequiresReconciliation=$true;Source='runtime-wake-test'
    }
    $observed.ok | Should Be $true
    $observed.latestMessageClassification.topicAffinity | Should Be 'active'
    $observed.latestMessageClassification.confidence | Should Be 'high'
    ([string]$observed.latestMessageClassification.matchedKeys).Contains('derived_state:') | Should Be $true
    $observed.latestMessageClassification.needsClarification | Should Be $false
    $observed.needsReconciliation | Should Be $true
  }

  It 'keeps PowerShell classification aligned with shared parity fixtures' {
    $fixtures = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'tests\runtime_wake_parity_fixtures.json') | ConvertFrom-Json
    foreach ($case in @($fixtures.cases)) {
      $decision = [pscustomobject]@{
        contextReply = [bool]$case.contextReply
        continuitySignal = [bool]$case.continuitySignal
        affinity = $case.affinity
      }
      $classification = New-SuperBrainRuntimeWakeObservationClassification $case.contract $decision ([string]$case.prompt)
      foreach ($property in $case.expected.PSObject.Properties) {
        $classification.($property.Name) | Should Be $property.Value
      }
    }
  }

  It 'wakes only for task-dependent or contextual input and performs no deep work' {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-decision';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake reliability';TopicKeys=@('wake-control')
      CurrentStep='keep automatic recall fast without capability regression';NextAction='measure the bounded wake gate'
    }
    $direct = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'what is the capital of france' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey (New-RuntimeWakeRouteSignals) ([string]$created.packageVersion)
    $direct.active | Should Be $true
    $direct.shouldWake | Should Be $false

    $dependent = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'automatic recall must stay fast' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey (New-RuntimeWakeRouteSignals) ([string]$created.packageVersion)
    $dependent.shouldWake | Should Be $true
    $dependent.affinity.topicAffinity | Should Be 'active'

    $replies = @(@('ok','2+3','1 b+c') | ForEach-Object {
      Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot $_ $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey (New-RuntimeWakeRouteSignals -ContextReply $true) ([string]$created.packageVersion)
    })
    foreach ($reply in $replies) { $reply.shouldWake | Should Be $true }
    foreach ($result in @($direct,$dependent)+$replies) {
      $result.modelCalled | Should Be $false
      $result.networkCalled | Should Be $false
      $result.deepRecallCalled | Should Be $false
      $result.memoryBodyLoaded | Should Be $false
    }
  }

  It 'routes exact critical actions through bounded scoped preflight without deep recall' {
    foreach ($kind in @('commit','package','test','modify','sync')) {
      $taskId = 'task-runtime-action-'+$kind
      $created = Invoke-RuntimeWakeContract @{
        Action='Set';TaskId=$taskId;WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
        FocusId='action-line';FocusLabel='Critical action preflight';TopicKeys=@('action-preflight')
        CurrentStep='verify action dependencies';NextAction='ACTION_SENTINEL_MUST_NOT_BE_LEAKED'
        Constraints=@('keep current scope');AcceptanceCriteria=@('verify before mutation')
      }
      $signals = New-RuntimeWakeRouteSignals -ActionEntry $true -ActionKind $kind
      $decision = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot $kind $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey $signals ([string]$created.packageVersion)
      $decision.shouldWake | Should Be $true
      $decision.actionEntrySignal | Should Be $true
      $decision.actionKind | Should Be $kind
      $decision.modelCalled | Should Be $false
      $decision.networkCalled | Should Be $false
      $decision.deepRecallCalled | Should Be $false
      $observed = Invoke-SuperBrainRuntimeWakeObservation $script:RuntimeWakeStateRoot $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey $kind $decision 'runtime-action-preflight-test'
      $observed.ok | Should Be $true
      $observed.needsReconciliation | Should Be $true
      $observed.latestMessageClassification.mode | Should Be 'action_preflight'
      $observed.latestMessageClassification.needsClarification | Should Be $true
      (Invoke-RuntimeWakeContract @{Action='Clear';TaskId=$taskId;WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}).ok | Should Be $true
    }
  }

  It 'keeps next as a continuation while rejecting near action-token matches' {
    . (Join-Path $Root 'scripts\routing-kernel.ps1')
    $next = Get-SuperBrainHotRouteSignals 'next'
    $next.actionEntrySignal | Should Be $true
    $next.actionKind | Should Be 'next'
    $next.continuitySignal | Should Be $true
    foreach ($prompt in @('testing','package.json','sync status')) {
      $signal = Get-SuperBrainHotRouteSignals $prompt
      $signal.actionEntrySignal | Should Be $false
    }
  }

  It 'keeps multiple current tasks ambiguous instead of selecting the newest one' {
    foreach ($task in @('task-runtime-wake-a','task-runtime-wake-b')) {
      Invoke-RuntimeWakeContract @{
        Action='Set';TaskId=$task;WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
        FocusId=($task+'-line');FocusLabel=$task;TopicKeys=@($task);NextAction=('continue '+$task)
      } | Out-Null
    }
    $index = Read-SuperBrainRuntimeWakeIndex $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    [int]$index.entryCount | Should Be 2
    $decision = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'continue the current task' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey (New-RuntimeWakeRouteSignals -Continuity $true)
    $decision.active | Should Be $true
    $decision.ambiguous | Should Be $true
    $decision.shouldWake | Should Be $true
    [string]::IsNullOrWhiteSpace([string]$decision.taskId) | Should Be $true
  }

  It 'does not automatically wake an active contract with an explicit no-action terminal plan' {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-terminal';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='terminal-line';FocusLabel='Terminal line';CurrentStep='verification recorded'
      NextAction='No automatic action: closure is complete.';PendingSteps=@()
    }
    $created.ok | Should Be $true
    $index = Read-SuperBrainRuntimeWakeIndex $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    $index.entries[0].wakeEligible | Should Be $false

    $decision = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'continue' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey (New-RuntimeWakeRouteSignals -Continuity $true) ([string]$created.packageVersion)
    $decision.active | Should Be $false
    $decision.shouldWake | Should Be $false

    $payload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='continue'} | ConvertTo-Json -Compress)
    $native = Invoke-NativeRuntimeWakeHook $payload
    $native.exitCode | Should Be 0
    @($native.raw).Count | Should Be 1
    ([string](($native.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext) | Should Be ''
  }

  It 'uses revision CAS while the fast observation only appends a redacted instruction anchor' {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-cas';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake reliability';TopicKeys=@('wake-control')
      CurrentStep='keep automatic recall fast';NextAction='verify the fast observation transaction'
    }
    $signals = New-RuntimeWakeRouteSignals -HookCandidate $true
    $decision = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'update the runtime wake transaction' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey $signals ([string]$created.packageVersion)
    $sensitiveFixture = 'api' + '_key=' + 'supersecretvalue update the runtime wake transaction'
    $fast = Invoke-SuperBrainRuntimeWakeObservation $script:RuntimeWakeStateRoot $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey $sensitiveFixture $decision 'runtime-wake-test'
    $fast.ok | Should Be $true
    $fast.latestUserInstruction.Contains('supersecretvalue') | Should Be $false
    $fast.latestUserInstruction.Contains('[REDACTED]') | Should Be $true
    $fast.needsReconciliation | Should Be $true
    [int]$fast.revision | Should Be ([int]$created.revision)
    $current = Invoke-RuntimeWakeContract @{Action='Get';TaskId='task-runtime-wake-cas';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    [int]$current.revision | Should Be ([int]$created.revision)

    $withheld = Invoke-RuntimeWakeContract @{Action='Resolve';TaskId='task-runtime-wake-cas';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    $withheld.actionAuthorization | Should Be 'withheld'
    $withheld.resumeFrom | Should Be 'execution_contract_instruction_anchor_pending'

    $reconciled = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-cas';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake reliability';InstructionMode='continue';LatestUserInstruction='redacted runtime wake scope reconciled'
      CurrentStep='keep automatic recall fast';NextAction='verify the fast observation transaction'
      ExpectedRevision=[int]$created.revision;ExpectedPlanFingerprint=[string]$created.planReceipt.planFingerprint;TransitionId='runtime-wake-cas-reconcile'
    }
    $reconciled.ok | Should Be $true

    $stale = Invoke-SuperBrainRuntimeWakeObservation $script:RuntimeWakeStateRoot $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey 'repeat stale work' $decision 'runtime-wake-test'
    $stale.ok | Should Be $false
    $stale.code | Should Be 'RUNTIME_WAKE_FAST_OBSERVE_REVISION_MISMATCH'
    $current = Invoke-RuntimeWakeContract @{Action='Get';TaskId='task-runtime-wake-cas';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    [int]$current.revision | Should Be ([int]$reconciled.revision)
  }

  It 'preserves a substantive pending instruction across compact replies in both hot hooks' -Skip {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-pending-preserve';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake pending instruction';TopicKeys=@('pending-instruction')
      CurrentStep='preserve the substantive pending instruction';NextAction='wait for explicit reconciliation'
    }
    $substantivePrompt = 'pending-instruction add J and cancel H'
    $decision = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot $substantivePrompt $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey (New-RuntimeWakeRouteSignals -HookCandidate $true) ([string]$created.packageVersion)
    $pending = Invoke-SuperBrainRuntimeWakeObservation $script:RuntimeWakeStateRoot $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey $substantivePrompt $decision 'runtime-wake-test'
    $pending.ok | Should Be $true
    $pending.needsReconciliation | Should Be $true

    $continueDecision = Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'continue' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey (New-RuntimeWakeRouteSignals -Continuity $true) ([string]$created.packageVersion)
    $continued = Invoke-SuperBrainRuntimeWakeObservation $script:RuntimeWakeStateRoot $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey 'continue' $continueDecision 'runtime-wake-test'
    $continued.ok | Should Be $true
    [int]$continued.revision | Should Be ([int]$pending.revision)
    $continued.latestUserInstruction | Should Be $pending.latestUserInstruction
    $continued.needsReconciliation | Should Be $true

    $pendingContract = Invoke-RuntimeWakeContract @{Action='Get';TaskId='task-runtime-wake-pending-preserve';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    $reconciled = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-pending-preserve';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';InstructionMode='continue';LatestUserInstruction='pending-instruction scope reconciled'
      CurrentStep='preserve the substantive pending instruction';NextAction='wait for explicit reconciliation'
      ExpectedRevision=[int]$pendingContract.revision;ExpectedPlanFingerprint=[string]$pendingContract.planReceipt.planFingerprint;TransitionId='runtime-wake-reconcile-pending'
    }
    $reconciled.needsReconciliation | Should Be $false

    $nativePendingPayload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt=$substantivePrompt} | ConvertTo-Json -Compress)
    (Invoke-NativeRuntimeWakeHook $nativePendingPayload).exitCode | Should Be 0
    $afterNativePending = Invoke-RuntimeWakeContract @{Action='Get';TaskId='task-runtime-wake-pending-preserve';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    # The native hook appends only the durable instruction anchor. The stored
    # contract remains untouched, while a read projection must surface the
    # anchor so callers cannot resume the older action by mistake.
    $storedAfterNativePending = Get-Content -Raw -Encoding UTF8 -LiteralPath $pendingContract.path | ConvertFrom-Json
    $storedAfterNativePending.needsReconciliation | Should Be $false
    [int]$storedAfterNativePending.revision | Should Be ([int]$reconciled.revision)
    $afterNativePending.needsReconciliation | Should Be $true
    $afterNativePending.observationProjection | Should Be 'instruction_anchor_pending'
    [int]$afterNativePending.revision | Should Be ([int]$reconciled.revision)
    $afterNativePendingResolution = Invoke-RuntimeWakeContract @{Action='Resolve';TaskId='task-runtime-wake-pending-preserve';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    $afterNativePendingResolution.actionAuthorization | Should Be 'withheld'
    $afterNativePendingResolution.resumeFrom | Should Be 'execution_contract_instruction_anchor_pending'

    $nativeContinuePayload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='ok'} | ConvertTo-Json -Compress)
    (Invoke-NativeRuntimeWakeHook $nativeContinuePayload).exitCode | Should Be 0
    $afterNativeContinue = Invoke-RuntimeWakeContract @{Action='Get';TaskId='task-runtime-wake-pending-preserve';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    [int]$afterNativeContinue.revision | Should Be ([int]$afterNativePending.revision)
    $afterNativeContinue.latestUserInstruction | Should Be $afterNativePending.latestUserInstruction
    $afterNativeContinue.needsReconciliation | Should Be $true
    $afterNativeContinueResolution = Invoke-RuntimeWakeContract @{Action='Resolve';TaskId='task-runtime-wake-pending-preserve';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    $afterNativeContinueResolution.actionAuthorization | Should Be 'withheld'
    $afterNativeContinueResolution.resumeFrom | Should Be 'execution_contract_instruction_anchor_pending'
  }

  It 'keeps the incremental hot decision p95 within 25 milliseconds' {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-performance';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake performance';TopicKeys=@('wake-control')
      CurrentStep='keep automatic recall fast without capability regression';NextAction='measure bounded wake latency'
    }
    $signals = New-RuntimeWakeRouteSignals
    1..8 | ForEach-Object { Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'automatic recall must stay fast' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey $signals ([string]$created.packageVersion) | Out-Null }
    $samples = @(1..64 | ForEach-Object { [int](Get-SuperBrainRuntimeWakeDecision $script:RuntimeWakeStateRoot 'automatic recall must stay fast' $script:RuntimeWakeWorkspaceKey $script:RuntimeWakeSessionKey $signals ([string]$created.packageVersion)).durationMs } | Sort-Object)
    $p95 = [int]$samples[[Math]::Max(0,[Math]::Ceiling($samples.Count*0.95)-1)]
    $p95 | Should BeLessThan 26
  }

  It 'keeps the native continuation packet aligned with the additive checklist contract' -Skip {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-additive';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake reliability';InstructionMode='continue';LatestUserInstruction='confirm A through I'
      LastConfirmedSentence='Confirmed plan A through I.';LastConfirmedSource='assistant_commitment';NextAction='A';PendingSteps=@('A','B','C','D','E','F','G','H','I')
    }
    $created.ok | Should Be $true

    $payload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='continue current plan'} | ConvertTo-Json -Compress)
    $run = Invoke-NativeRuntimeWakeHook $payload
    $context = [string](($run.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext

    $run.exitCode | Should Be 0
    $context.Contains('activeChecklist=1:pending:A') | Should Be $true
    $context.Contains('9:pending:I') | Should Be $true
    $context.Contains('checklistRule=additive-unless-explicit-replace') | Should Be $true
    $context.Contains('lastConfirmedSource=assistant_commitment') | Should Be $true
    $context.Contains('lastConfirmedSentence=Confirmed plan A through I.') | Should Be $true
    $context.Contains('assistantProgressReceipt=latest') | Should Be $true
    $context.Contains('visibleResumeRule=first-response-state-last-confirmed-progress-before-current-action') | Should Be $true
    $context.Contains('Completed history is never current.') | Should Be $true
    $context.Contains('Do not execute, infer, or restore an older action') | Should Be $true
  }

  It 'surfaces the latest recorded assistant progress before a resumed action' -Skip {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-progress-receipt';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='progress-main';FocusLabel='Progress main';InstructionMode='continue';LatestUserInstruction='continue the verified progress line'
      CurrentPhase='P0';CurrentStep='anchor and receipt storage are implemented';NextAction='run the scoped regression'
      PendingSteps=@('run scoped regression')
    }
    $created.ok | Should Be $true

    $payload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='continue'} | ConvertTo-Json -Compress)
    $run = Invoke-NativeRuntimeWakeHook $payload
    $context = [string](($run.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext

    $run.exitCode | Should Be 0
    $context.Contains('assistantProgressReceipt=latest') | Should Be $true
    $context.Contains('lastConfirmedSource=execution_state_projection') | Should Be $true
    $context.Contains('lastConfirmedSentence=Progress checkpoint: anchor and receipt storage are implemented') | Should Be $true
    $context.Contains('visibleResumeRule=first-response-state-last-confirmed-progress-before-current-action') | Should Be $true
  }

  It 'keeps the native hot hook canonical-main-first while storing only canonical identity in the hot index' -Skip {
    $rootContract = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-canonical';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='canonical-main';FocusLabel='Approved canonical main';InstructionMode='continue';LatestUserInstruction='confirm A through C'
      NextAction='A';PendingSteps=@('A','B','C');EnableCanonicalPlan=$true;RequireStructuralGuards=$true
    }
    $side = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-canonical';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='canonical-side';FocusLabel='Canonical side proof';InstructionMode='side_branch';LatestUserInstruction='inspect side proof'
      NextAction='side one';PendingSteps=@('side one','side two');ExpectedRevision=[int]$rootContract.revision
      ExpectedPlanFingerprint=[string]$rootContract.planReceipt.planFingerprint;TransitionId='runtime-wake-open-canonical-side'
    }
    $side.ok | Should Be $true

    $payload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='current plan and progress'} | ConvertTo-Json -Compress)
    $run = Invoke-NativeRuntimeWakeHook $payload
    $context = [string](($run.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext
    $run.exitCode | Should Be 0
    $context.Contains('canonicalMain=') | Should Be $true
    $context.Contains('canonicalChecklist=1:pending:A | 2:pending:B | 3:pending:C') | Should Be $true
    $context.Contains('activeWorkPackage=Canonical side proof[canonical-side]:side_branch') | Should Be $true
    $context.Contains('workPackageChecklist=1:pending:side one | 2:pending:side two') | Should Be $true
    ($context.IndexOf('canonicalMain=') -lt $context.IndexOf('activeWorkPackage=')) | Should Be $true
    $context.Contains('Do not execute, infer, or restore an older action') | Should Be $true

    $indexPath = Get-SuperBrainRuntimeWakeIndexPath $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    $indexText = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath
    $entry = ($indexText | ConvertFrom-Json).entries[0]
    $entry.canonicalPlanId | Should Be $side.canonicalPlan.planId
    [int]$entry.canonicalGeneration | Should Be 1
    $entry.canonicalFingerprint | Should Be $side.canonicalPlan.currentFingerprint
    $indexText.Contains('side one') | Should Be $false
    $indexText.Contains('side two') | Should Be $false
  }

  It 'never silently truncates an oversized canonical checklist' -Skip {
    $longSteps = @(1..24 | ForEach-Object { ('step-{0:D2}-' -f $_) + ('x' * 120) })
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-large-canonical';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='large-canonical-main';FocusLabel='Large canonical main';InstructionMode='continue';LatestUserInstruction='approve the large plan'
      NextAction=$longSteps[0];PendingSteps=$longSteps;EnableCanonicalPlan=$true;RequireStructuralGuards=$true
    }
    $created.ok | Should Be $true

    $payload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='current plan'} | ConvertTo-Json -Compress)
    $run = Invoke-NativeRuntimeWakeHook $payload
    $context = [string](($run.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext

    $run.exitCode | Should Be 0
    $context.Contains('canonicalChecklist=compact coverage=24/24') | Should Be $true
    $context.Contains('checklistDetail=authoritative-state-required') | Should Be $true
    $context.Contains('shown=') | Should Be $false
    $context.Contains('canonicalRule=append-or-targeted-mutation-unless-explicit-replace-envelope') | Should Be $true
    $context.Contains('Do not execute, infer, or restore an older action') | Should Be $true
  }

  It 'uses the installed native hot hook for semantic and compact contextual replies but not greetings or independent questions' -Skip {
    $created = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-hook';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake reliability';TopicKeys=@('wake-control')
      CurrentStep='prevent regression while keeping automatic recall fast';NextAction='verify automatic runtime wake behavior'
    }
    $beforeRevision = [int]$created.revision

    $semanticPayload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='do not regress automatic recall speed'} | ConvertTo-Json -Compress)
    $semanticRun = Invoke-NativeRuntimeWakeHook $semanticPayload
    $semanticRun.exitCode | Should Be 0
    $semanticContext = [string](($semanticRun.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext
    $semanticContext.Contains('EXECUTION_CONTRACT_RESUME_PACKET') | Should Be $true
    $semanticContext.Contains('messageAffinity=active') | Should Be $true
    $semanticContext.Contains('confidence=high') | Should Be $true
    $semanticContext.Contains('authorizedNextAction=verify automatic runtime wake behavior') | Should Be $false
    $hookStatePath = Get-RuntimeWakeTelemetryPath $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    $semanticState = Get-Content -Raw -Encoding UTF8 -LiteralPath $hookStatePath | ConvertFrom-Json
    $pointerPath = Join-Path $script:RuntimeWakeStateRoot 'workspace\last-codex-user-prompt-hook.json'
    $pointer = Get-Content -Raw -Encoding UTF8 -LiteralPath $pointerPath | ConvertFrom-Json
    $pointer.schema | Should Be 'super-brain.codex-user-prompt-hook-pointer.v1'
    $pointer.scope | Should Be 'session_workspace'
    ([string]$pointer.telemetryRelativePath).Contains('task-runtime-wake-hook') | Should Be $false
    $semanticState.runtimeWake.fastObserveAttempted | Should Be $true
    $semanticState.runtimeWake.fastObserveOk | Should Be $true
    $semanticState.routeSignalMode | Should Be 'native'
    Write-Host ('RUNTIME_WAKE_SEMANTIC_PHASES '+($semanticState.phaseMs|ConvertTo-Json -Compress))
    [int]$semanticState.durationMs | Should BeLessThan 250
    $nativeSamples = @($semanticRun.envelopeMs)
    $hotSamples = @([int]$semanticState.durationMs)
    1..19 | ForEach-Object {
      $sample = Invoke-NativeRuntimeWakeHook $semanticPayload
      $sample.exitCode | Should Be 0
      $nativeSamples += $sample.envelopeMs
      $sampleState = Get-Content -Raw -Encoding UTF8 -LiteralPath $hookStatePath | ConvertFrom-Json
      $hotSamples += [int]$sampleState.durationMs
    }
    $nativeSamples = @($nativeSamples | Sort-Object)
    $hotSamples = @($hotSamples | Sort-Object)
    $nativeP95 = [int]$nativeSamples[[Math]::Max(0,[Math]::Ceiling($nativeSamples.Count*0.95)-1)]
    $hotP95 = [int]$hotSamples[[Math]::Max(0,[Math]::Ceiling($hotSamples.Count*0.95)-1)]
    Write-Host ('RUNTIME_WAKE_HOT_P95_MS '+$hotP95+' COLD_ENVELOPE_P95_MS '+$nativeP95)
    # The hot hook has a hard functional latency gate. The surrounding Python
    # process launch is a separately reported cold-start metric because it is
    # owned by host and OS scheduling, not by the wake control plane.
    $hotP95 | Should BeLessThan 250

    $reconciled = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-hook';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='runtime-wake-line';FocusLabel='Runtime wake reliability';InstructionMode='continue';LatestUserInstruction='preserve runtime wake capability'
      CurrentStep='prevent regression while keeping automatic recall fast';NextAction='verify automatic runtime wake behavior'
    }
    $replyPayload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='ok'} | ConvertTo-Json -Compress)
    $replyRun = Invoke-NativeRuntimeWakeHook $replyPayload
    $replyRun.exitCode | Should Be 0
    $replyContext = [string](($replyRun.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext
    $replyContext.Contains('EXECUTION_CONTRACT_RESUME_PACKET') | Should Be $true
    $replyContext.Contains('messageAffinity=active') | Should Be $true
    $replyState = Get-Content -Raw -Encoding UTF8 -LiteralPath $hookStatePath | ConvertFrom-Json
    $replyState.runtimeWake.fastObserveOk | Should Be $true
    [int]$replyState.durationMs | Should BeLessThan 250

    $afterReply = Invoke-RuntimeWakeContract @{Action='Get';TaskId='task-runtime-wake-hook';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    [int]$afterReply.revision | Should Be ([int]$reconciled.revision)

    $helloPayload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='hello'} | ConvertTo-Json -Compress)
    $helloRun = Invoke-NativeRuntimeWakeHook $helloPayload
    $helloRun.exitCode | Should Be 0
    @($helloRun.raw).Count | Should Be 1
    ([string](($helloRun.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext) | Should Be ''
    $questionPayload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='what is the capital of france'} | ConvertTo-Json -Compress)
    $questionRun = Invoke-NativeRuntimeWakeHook $questionPayload
    $questionRun.exitCode | Should Be 0
    @($questionRun.raw).Count | Should Be 1
    ([string](($questionRun.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext) | Should Be ''
    $afterDirect = Invoke-RuntimeWakeContract @{Action='Get';TaskId='task-runtime-wake-hook';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey}
    [int]$afterDirect.revision | Should Be ([int]$afterReply.revision)
  }

  It 'uses the current task pointer to disambiguate multiple active hot-index entries' -Skip {
    $predecessor = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-pointer-predecessor';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='predecessor-line';FocusLabel='Predecessor line';TopicKeys=@('predecessor')
      CurrentStep='remain available for history only';NextAction='do not use this predecessor for current work'
    }
    $current = Invoke-RuntimeWakeContract @{
      Action='Set';TaskId='task-runtime-wake-pointer-current';WorkspaceKey=$script:RuntimeWakeWorkspaceKey;SessionKey=$script:RuntimeWakeSessionKey
      FocusId='current-line';FocusLabel='Current line';TopicKeys=@('pointer-current')
      CurrentStep='resolve the current task through the scoped pointer';NextAction='verify pointer-bound native wake'
    }
    $indexPath = Get-SuperBrainRuntimeWakeIndexPath $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    $index = Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json
    @($index.entries).Count | Should BeGreaterThan 1
    $pointerPath = Get-SuperBrainCanonicalTaskPath (Join-Path $script:RuntimeWakeStateRoot 'workspace\guard-state\current-task-context-pointers') $script:RuntimeWakeWorkspaceKey '.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pointerPath) | Out-Null
    Write-JsonUtf8NoBom $pointerPath ([pscustomobject]@{
      schema='super-brain.current-task-context.v1'; taskId='task-runtime-wake-pointer-current'; workspaceKey=$script:RuntimeWakeWorkspaceKey
      ownerSessionKey=$script:RuntimeWakeSessionKey; contractRevision=[int]$current.revision; rawPromptStored=$false; rawSessionIdStored=$false
    }) 8

    $payload = ([pscustomobject]@{session_id=$script:RuntimeWakeSessionKey;prompt='continue'} | ConvertTo-Json -Compress)
    $run = Invoke-NativeRuntimeWakeHook $payload
    $statePath = Get-RuntimeWakeTelemetryPath $script:RuntimeWakeStateRoot $script:RuntimeWakeSessionKey $script:RuntimeWakeWorkspaceKey
    $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
    $context = [string](($run.raw -join [Environment]::NewLine) | ConvertFrom-Json).hookSpecificOutput.additionalContext

    $predecessor.ok | Should Be $true
    $current.ok | Should Be $true
    $run.exitCode | Should Be 0
    $state.routeSignalMode | Should Be 'native'
    $state.executionContractCapture.taskId | Should Be 'task-runtime-wake-pointer-current'
    $state.executionContractCapture.actionAuthorization | Should Be 'withheld'
    $state.executionContractCapture.oldActionsOmitted | Should Be $true
    $context.Contains('task=task-runtime-wake-pointer-current') | Should Be $true
    $context.Contains('task-runtime-wake-pointer-predecessor') | Should Be $false
  }
}
