$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Contract = Join-Path $Root 'scripts\execution-contract.ps1'
$BrainCli = Join-Path $Root 'runtime\brain_cli.py'
. (Join-Path $Root 'scripts\common.ps1')

function Invoke-H7Contract([string]$StateRoot,[hashtable]$Parameters) {
  $Parameters.StateRoot = $StateRoot
  $Parameters.NoExit = $true
  $Parameters.Json = $true
  $raw = @(& $Contract @Parameters 2>$null)
  return (($raw -join "`n") | ConvertFrom-Json)
}

function Invoke-H7Runtime([string]$StateRoot,[string]$HostRoot,[string]$SessionKey,[string]$Phase='open',[string]$TurnIntent='continuity',[string]$ProgressCheckpointBase64='',[string]$ProjectProgressProofBase64='',[string]$TransitionId='',[string]$VisibleProgressAssertionBase64='') {
  $oldState = $env:SUPER_BRAIN_STATE_ROOT
  $oldThread = $env:CODEX_THREAD_ID
  $oldWorkspace = $env:SUPER_BRAIN_WORKSPACE_KEY
  $oldCodexHome = $env:CODEX_HOME
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $env:CODEX_THREAD_ID = $SessionKey
    $isolatedCodexHome = Join-Path $StateRoot 'codex-home'
    New-Item -ItemType Directory -Force -Path $isolatedCodexHome | Out-Null
    $env:CODEX_HOME = $isolatedCodexHome
    Push-Location $HostRoot
    $env:SUPER_BRAIN_WORKSPACE_KEY = Get-SuperBrainWorkspaceKey $HostRoot
    $args = @('-X','utf8',$BrainCli,'--package-root',$Root,'--memory-root',(Join-Path $StateRoot 'shared'),'turn-runtime','--phase',$Phase,'--memory-mode','auto','--turn-intent',$TurnIntent,'--timeout-seconds','12')
    if($ProgressCheckpointBase64){ $args += @('--progress-checkpoint-base64',$ProgressCheckpointBase64) }
    if($ProjectProgressProofBase64){ $args += @('--project-progress-proof-base64',$ProjectProgressProofBase64) }
    if($VisibleProgressAssertionBase64){ $args += @('--visible-progress-assertion-base64',$VisibleProgressAssertionBase64) }
    if($TransitionId){ $args += @('--transition-id',$TransitionId) }
    $raw = @(& python @args 2>$null)
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
    if($null -eq $oldState){ Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
    if($null -eq $oldThread){ Remove-Item Env:\CODEX_THREAD_ID -ErrorAction SilentlyContinue } else { $env:CODEX_THREAD_ID = $oldThread }
    if($null -eq $oldWorkspace){ Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspace }
    if($null -eq $oldCodexHome){ Remove-Item Env:\CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $oldCodexHome }
  }
  return [pscustomobject]@{ exitCode=$exitCode; value=(($raw -join "`n") | ConvertFrom-Json) }
}

function New-H7Fixture {
  $stateRoot = Join-Path $TestDrive ('h7-wake-' + [guid]::NewGuid().ToString('n'))
  $hostRoot = Join-Path $TestDrive ('h7-host-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $stateRoot,$hostRoot,(Join-Path $stateRoot 'shared') | Out-Null
  $workspaceKey = Get-SuperBrainWorkspaceKey $hostRoot
  $sessionKey = 'sid-e777777777777777777777777'
  return [pscustomobject]@{ stateRoot=$stateRoot;hostRoot=$hostRoot;workspaceKey=$workspaceKey;sessionKey=$sessionKey }
}

function New-H7ProjectProofBase64([string]$HostRoot,[string]$Phase,[string]$CurrentStep,[string]$NextAction) {
  $evidencePath = Join-Path $HostRoot 'h7-project-proof.txt'
  [IO.File]::WriteAllText($evidencePath,'H7 project-proof fixture',[Text.Encoding]::UTF8)
  $proof = [ordered]@{
    schema='super-brain.project-progress-input.v1'
    phase=$Phase
    currentStep=$CurrentStep
    completedItems=@()
    projectEvidence=@([ordered]@{kind='project_file';relativePath='h7-project-proof.txt';sha256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()})
    verificationResults=@()
    nextAction=$NextAction
  } | ConvertTo-Json -Depth 8 -Compress
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($proof))
}

function New-H7AssistantProgressBase64([string]$Sentence,[string]$Phase,[string]$CurrentStep,[string]$NextAction) {
  $checkpoint = [ordered]@{last_confirmed_sentence=$Sentence;source='assistant_visible_reply';current_phase=$Phase;current_step=$CurrentStep;next_action=$NextAction} | ConvertTo-Json -Compress
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($checkpoint))
}

function New-H7VisibleTailAssertionBase64([string]$SessionKey,[string]$Sentence,[string]$Phase,[string]$CurrentStep,[string]$NextAction,[string]$MessageId,[string]$ReceiptHash) {
  $assertion = [ordered]@{
    schema='super-brain.visible-tail-observation.v4'
    observation_source='codex_app_read_thread'
    selection='current_visible_assistant'
    host_thread_id=$SessionKey
    host_turn_id='019fe035-b8ac-73e2-947c-6f6fd16cdc65'
    host_message_id=$MessageId
    message_phase='commentary'
    last_confirmed_sentence=$Sentence
    source='assistant_visible_reply'
    publication_kind='h7_durable_progress'
    envelope_version='v4'
    h7_receipt_hash=$ReceiptHash
    raw_prompt_stored=$false
    raw_transcript_stored=$false
  } | ConvertTo-Json -Compress
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($assertion))
}

Describe 'H7 runtime wake control plane' {
  It 'opens one scoped contract with a compact progress receipt and no raw prompt' {
    $fixture = New-H7Fixture
    $initialProof = New-H7ProjectProofBase64 $fixture.hostRoot 'stage-h7' 'verify scoped runtime' 'read current evidence'
    $initialCheckpoint = New-H7AssistantProgressBase64 'H7 progress is bound to the current contract.' 'stage-h7' 'verify scoped runtime' 'read current evidence'
    $created = Invoke-H7Contract $fixture.stateRoot @{
      Action='Set';TaskId='task-h7-open';WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='h7-main';FocusLabel='H7 main line';InstructionMode='continue'
      LastConfirmedSentence='H7 progress is bound to the current contract.';LastConfirmedSource='assistant_commitment'
      CurrentPhase='stage-h7';CurrentStep='verify scoped runtime';NextAction='read current evidence'
      PendingSteps=@('read current evidence','run acceptance');TopicKeys=@('h7','wake')
      ProjectRoot=$fixture.hostRoot;ProjectProgressProofBase64=$initialProof;ProgressCheckpointBase64=$initialCheckpoint;TransitionId='h7-open-seed'
    }
    $tailAssertion = New-H7VisibleTailAssertionBase64 $fixture.sessionKey 'H7 progress is bound to the current contract.' 'stage-h7' 'verify scoped runtime' 'read current evidence' 'item-h7-open-progress' $created.visibleProgressReceipt.payloadHash
    $opened = Invoke-H7Runtime $fixture.stateRoot $fixture.hostRoot $fixture.sessionKey 'open' 'continuity' '' '' '' $tailAssertion

    $created.ok | Should Be $true
    $opened.exitCode | Should Be 0
    $opened.value.available | Should Be $true
    $opened.value.context.task.taskId | Should Be 'task-h7-open'
    $opened.value.context.task.lastConfirmedSentence | Should Be 'H7 progress is bound to the current contract.'
    $opened.value.activation.state | Should Be 'full_brain_active'
    $opened.value.visibleTailAssertion.state | Should Be 'current'
    $opened.value.rawPromptStored | Should Be $false
    $opened.value.rawTranscriptStored | Should Be $false
  }

  It 'writes a four-field assistant progress checkpoint through H7 CAS' {
    $fixture = New-H7Fixture
    $initialProof = New-H7ProjectProofBase64 $fixture.hostRoot 'stage-h7' 'prepare checkpoint' 'write checkpoint'
    $initialCheckpoint = New-H7AssistantProgressBase64 'H7 checkpoint preparation is published.' 'stage-h7' 'prepare checkpoint' 'write checkpoint'
    $created = Invoke-H7Contract $fixture.stateRoot @{
      Action='Set';TaskId='task-h7-checkpoint';WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='h7-checkpoint';FocusLabel='H7 checkpoint';InstructionMode='continue'
      CurrentPhase='stage-h7';CurrentStep='prepare checkpoint';NextAction='write checkpoint';PendingSteps=@('write checkpoint')
      ProjectRoot=$fixture.hostRoot;ProjectProgressProofBase64=$initialProof;ProgressCheckpointBase64=$initialCheckpoint;TransitionId='h7-checkpoint-seed'
    }
    $base64 = New-H7AssistantProgressBase64 'H7 checkpoint is the latest assistant progress.' 'stage-h7' 'checkpoint acceptance' 'read H7 evidence'
    $checkpointProof = New-H7ProjectProofBase64 $fixture.hostRoot 'stage-h7' 'checkpoint acceptance' 'read H7 evidence'
    $written = Invoke-H7Runtime $fixture.stateRoot $fixture.hostRoot $fixture.sessionKey 'checkpoint' 'continuity' $base64 $checkpointProof 'h7-checkpoint-transition'

    $created.ok | Should Be $true
    $written.exitCode | Should Be 0
    $written.value.available | Should Be $true
    $written.value.checkpoint.ok | Should Be $true
    $written.value.checkpoint.code | Should Be 'H7_PROGRESS_CHECKPOINT_WRITTEN'
    [int]$written.value.checkpoint.revision | Should Be ([int]$created.revision + 1)
  }

  It 'returns current H7 evidence and projects the retired transport guard' {
    $fixture = New-H7Fixture
    $initialProof = New-H7ProjectProofBase64 $fixture.hostRoot 'stage-h7' 'collect evidence' 'verify evidence'
    $initialCheckpoint = New-H7AssistantProgressBase64 'H7 evidence collection is published.' 'stage-h7' 'collect evidence' 'verify evidence'
    $created = Invoke-H7Contract $fixture.stateRoot @{
      Action='Set';TaskId='task-h7-evidence';WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='h7-evidence';FocusLabel='H7 evidence';InstructionMode='continue'
      CurrentPhase='stage-h7';CurrentStep='collect evidence';NextAction='verify evidence';PendingSteps=@('verify evidence')
      ProjectRoot=$fixture.hostRoot;ProjectProgressProofBase64=$initialProof;ProgressCheckpointBase64=$initialCheckpoint;TransitionId='h7-evidence-seed'
    }
    $tailAssertion = New-H7VisibleTailAssertionBase64 $fixture.sessionKey 'H7 evidence collection is published.' 'stage-h7' 'collect evidence' 'verify evidence' 'item-h7-evidence-progress' $created.visibleProgressReceipt.payloadHash
    $opened = Invoke-H7Runtime $fixture.stateRoot $fixture.hostRoot $fixture.sessionKey 'open' 'continuity' '' '' '' $tailAssertion
    $evidence = Invoke-H7Runtime $fixture.stateRoot $fixture.hostRoot $fixture.sessionKey 'evidence' 'continuity'

    $created.ok | Should Be $true
    $opened.value.available | Should Be $true
    $evidence.exitCode | Should Be 0
    $evidence.value.available | Should Be $true
    $evidence.value.code | Should Be 'H7_EVIDENCE_CURRENT'
    $evidence.value.entry.current | Should Be $true
    $evidence.value.coreRules.status | Should Be 'current'
    $evidence.value.retiredTransportGuard.state | Should Be 'ready'
    $evidence.value.retiredTransportGuard.code | Should Be 'H7_RETIRED_TRANSPORT_GUARD_CURRENT'
    $evidence.value.retiredTransportGuard.actionAuthorization | Should Be 'not_authorizing'
    (@($evidence.value.PSObject.Properties.Name) -contains 'p7') | Should Be $false
  }

  It 'keeps greeting turns direct while governed turns remain scope-bound' {
    $fixture = New-H7Fixture
    $created = Invoke-H7Contract $fixture.stateRoot @{
      Action='Set';TaskId='task-h7-greeting';WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='h7-greeting';FocusLabel='H7 greeting';InstructionMode='continue'
      CurrentPhase='stage-h7';CurrentStep='direct greeting';NextAction='answer directly';PendingSteps=@('answer directly')
    }
    $greeting = Invoke-H7Runtime $fixture.stateRoot $fixture.hostRoot $fixture.sessionKey 'open' 'greeting'

    $created.ok | Should Be $true
    $greeting.exitCode | Should Be 0
    $greeting.value.available | Should Be $false
    $greeting.value.code | Should Be 'TURN_INTENT_DIRECT_HOST_PATH'
    $greeting.value.turnIntent.kind | Should Be 'greeting'
    $greeting.value.turnIntent.memoryMode | Should Be 'off'
    $greeting.value.rawPromptStored | Should Be $false
  }

  It 'uses the latest scoped task pointer instead of an older active task' {
    $fixture = New-H7Fixture
    $first = Invoke-H7Contract $fixture.stateRoot @{
      Action='Set';TaskId='task-h7-old';WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='old-line';FocusLabel='Old line';InstructionMode='continue';CurrentPhase='stage-h7';CurrentStep='old';NextAction='old next';PendingSteps=@('old next')
    }
    $latest = Invoke-H7Contract $fixture.stateRoot @{
      Action='Set';TaskId='task-h7-latest';WorkspaceKey=$fixture.workspaceKey;SessionKey=$fixture.sessionKey
      FocusId='latest-line';FocusLabel='Latest line';InstructionMode='continue';CurrentPhase='stage-h7';CurrentStep='latest';NextAction='latest next';PendingSteps=@('latest next')
    }
    $pointerPath = Join-Path $fixture.stateRoot 'workspace\last-execution-contract.json'
    $current = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $first.ok | Should Be $true
    $latest.ok | Should Be $true
    Test-Path -LiteralPath $pointerPath | Should Be $true
    $current.taskId | Should Be 'task-h7-latest'
    $current.taskId | Should Not Be 'task-h7-old'
  }
}
