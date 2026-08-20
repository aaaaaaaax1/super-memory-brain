$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$contractScript = Join-Path $root 'scripts\execution-contract.ps1'
$brainCli = Join-Path $root 'runtime\brain_cli.py'
$phaseCloseoutCore = Join-Path $root 'scripts\internal\phase-closeout-core.ps1'
. (Join-Path $root 'scripts\common.ps1')
. $phaseCloseoutCore

function Invoke-PhaseCloseoutContract([string]$ProjectRoot,[string[]]$Arguments) {
  Push-Location -LiteralPath $ProjectRoot
  try {
    $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $contractScript @Arguments 2>$null)
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{ exitCode=$LASTEXITCODE; value=($text | ConvertFrom-Json) }
  } finally {
    Pop-Location
  }
}

function Invoke-PhaseCloseoutH7([string]$StateRoot,[string]$ProjectRoot,[string]$SessionKey,[string]$Phase='evidence',[string]$ProgressCheckpointBase64='') {
  $oldState = $env:SUPER_BRAIN_STATE_ROOT
  $oldSession = $env:SUPER_BRAIN_LOCAL_SESSION_ID
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $env:SUPER_BRAIN_STATE_ROOT = $StateRoot
    $env:SUPER_BRAIN_LOCAL_SESSION_ID = $SessionKey
    Push-Location -LiteralPath $ProjectRoot
    $args = @('-X','utf8',$brainCli,'--package-root',$root,'--memory-root',(Join-Path $StateRoot 'shared'),'turn-runtime','--phase',$Phase,'--memory-mode','auto','--turn-intent','continuity','--timeout-seconds','12')
    if ($ProgressCheckpointBase64) { $args += @('--progress-checkpoint-base64',$ProgressCheckpointBase64) }
    $raw = @(& python @args 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
    $ErrorActionPreference = $oldErrorActionPreference
    if ($null -eq $oldState) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldState }
    if ($null -eq $oldSession) { Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $oldSession }
  }
  if ($exitCode -ne 0) { throw ('phase closeout H7 runtime failed: ' + ($raw -join "`n")) }
  return [pscustomobject]@{ exitCode=$exitCode; value=((($raw -join "`n").Trim()) | ConvertFrom-Json) }
}

function Write-PhaseCloseoutJson([string]$Path,[object]$Value) {
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}

function New-PhaseCloseoutProof([string]$ProjectRoot,[string]$Phase,[string]$Step,[string]$NextAction) {
  $evidencePath = Join-Path $ProjectRoot 'phase-evidence.txt'
  [IO.File]::WriteAllText($evidencePath,'H7 phase closeout proof',[Text.UTF8Encoding]::new($false))
  $sha = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
  return [ordered]@{
    schema='super-brain.project-progress-input.v1'
    phase=$Phase
    currentStep=$Step
    completedItems=@([ordered]@{ itemKey=$Step; evidenceRefs=@("project:file:phase-evidence.txt@sha256:$sha"); verificationIds=@('phase-closeout-h7') })
    projectEvidence=@([ordered]@{ kind='project_file'; relativePath='phase-evidence.txt'; sha256=$sha })
    verificationResults=@([ordered]@{ id='phase-closeout-h7'; status='passed' })
    nextAction=$NextAction
  }
}

function New-PhaseCloseoutFixture([switch]$ActivateH7,[string]$Phase='P7',[string]$Step='finish P7',[string]$NextAction='enter P8') {
  $token = [guid]::NewGuid().ToString('n').Substring(0,8)
  $stateRoot = Join-Path $TestDrive ('s-' + $token)
  $projectRoot = Join-Path $TestDrive ('p-' + $token)
  New-Item -ItemType Directory -Force -Path $stateRoot,$projectRoot,(Join-Path $stateRoot 'shared') | Out-Null
  $workspaceKey = Get-SuperBrainWorkspaceKey $projectRoot
  $sessionKey = 'sid-e777777777777777777777777'
  $taskId = 'task-phase-closeout-' + [guid]::NewGuid().ToString('n')
  $proofInput = New-PhaseCloseoutProof $projectRoot $Phase $Step $NextAction
  $proofBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($proofInput | ConvertTo-Json -Depth 8 -Compress)))
  $created = Invoke-PhaseCloseoutContract $projectRoot @(
    '-Action','Set','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,
    '-FocusId','main-line','-InstructionMode','continue','-CurrentPhase',$Phase,'-CurrentStep',$Step,
    '-CompletedSteps',$Step,'-PendingSteps',$NextAction,'-NextAction',$NextAction,
    '-ProjectRoot',$projectRoot,'-ProjectProgressProofBase64',$proofBase64,
    '-PhaseEvidencePolicy','h7_current','-StateRoot',$stateRoot,'-Json'
  )
  if ($created.exitCode -ne 0) { throw 'phase closeout fixture contract setup failed' }
  $contract = $created.value
  $checkpoint = $null
  $evidence = $null
  if ($ActivateH7) {
    $checkpointBody = [ordered]@{
      last_confirmed_sentence=('H7 checkpoint proves the current ' + $Phase + ' progress.')
      current_phase=$Phase
      current_step=$Step
      next_action=$NextAction
      source='assistant_visible_reply'
    } | ConvertTo-Json -Compress
    $checkpointBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($checkpointBody))
    $checkpoint = Invoke-PhaseCloseoutH7 $stateRoot $projectRoot $sessionKey 'checkpoint' $checkpointBase64
    if ($checkpoint.exitCode -ne 0 -or $checkpoint.value.checkpoint.ok -ne $true) { throw 'phase closeout H7 checkpoint setup failed' }
    $current = Invoke-PhaseCloseoutContract $projectRoot @('-Action','Get','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-SessionKey',$sessionKey,'-StateRoot',$stateRoot,'-Json')
    if ($current.exitCode -ne 0) { throw 'phase closeout H7 current contract read failed' }
    $contract = $current.value
    $evidence = Invoke-PhaseCloseoutH7 $stateRoot $projectRoot $sessionKey 'evidence'
    if ($evidence.exitCode -ne 0) { throw 'phase closeout H7 evidence setup failed' }
  }
  return [pscustomobject]@{
    stateRoot=$stateRoot;projectRoot=$projectRoot;workspaceKey=$workspaceKey;sessionKey=$sessionKey;taskId=$taskId
    contract=$contract;checkpoint=$checkpoint;evidence=$evidence
  }
}

function New-HostStageReceipt([object]$Fixture,[object]$Evidence,[switch]$TamperVisibleProgressHash) {
  $visibleHash = [string]$Evidence.value.visibleProgress.payloadHash
  if ($TamperVisibleProgressHash) { $visibleHash = ('0' * 64) }
  return [ordered]@{
    schema='super-brain.host-stage-receipt.v1'
    observationSource='codex_app_read_thread'
    taskId=[string]$Fixture.contract.taskId
    workspaceKey=[string]$Fixture.contract.workspaceKey
    ownerSessionKey=[string]$Fixture.contract.ownerSessionKey
    phase=(Get-SuperBrainFormalPhaseToken ([string]$Fixture.contract.currentPhase))
    contractRevision=[int]$Fixture.contract.revision
    planFingerprint=[string]$Fixture.contract.planReceipt.planFingerprint
    scopeRef=[string]$Evidence.value.scope.scopeRef
    visibleProgressPayloadHash=$visibleHash
    h7EntryReceiptHash=[string]$Evidence.value.entry.receipt.receiptHash
    state='observed'
    rawPromptStored=$false
    rawTranscriptStored=$false
  }
}

function New-HostReadbackProjection([string]$ObservationSource='codex_app_read_thread',[switch]$AddForbiddenHash) {
  $projection = [ordered]@{
    schema='super-brain.host-readback-projection.v1'
    observationSource=$ObservationSource
    state='observed'
    rawPromptStored=$false
    rawTranscriptStored=$false
  }
  if ($AddForbiddenHash) { $projection.scopeRef=('0' * 64) }
  return $projection
}

function ConvertTo-PhaseCloseoutBase64([object]$Value) {
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 8 -Compress)))
}

function Invoke-CreatePhaseCloseout([object]$Fixture,[object]$Projection=(New-HostReadbackProjection),[string[]]$ExtraArguments=@()) {
  $args = @(
    '-Action','CreatePhaseCloseout','-TaskId',$Fixture.taskId,'-WorkspaceKey',$Fixture.workspaceKey,'-SessionKey',$Fixture.sessionKey,
    '-ProjectRoot',$Fixture.hostRoot,'-ExpectedRevision',[string]$Fixture.contract.revision,
    '-ExpectedPlanFingerprint',[string]$Fixture.contract.planReceipt.planFingerprint,
    '-HostReadbackProjectionBase64',(ConvertTo-PhaseCloseoutBase64 $Projection),'-StateRoot',$Fixture.stateRoot,'-Json'
  )
  if ($ExtraArguments) { $args += @($ExtraArguments) }
  return Invoke-PhaseCloseoutContract $Fixture.hostRoot $args
}

function New-H7CloseoutReceipt([object]$Fixture,[object]$Evidence,[switch]$TamperEntryHash,[switch]$OmitHostStageReceipt,[switch]$TamperVisibleProgressHash) {
  $entryHash = [string]$Evidence.value.entry.receipt.receiptHash
  if ($TamperEntryHash) { $entryHash = ('0' * 64) }
  $receipt = [ordered]@{
    schema='super-brain.phase-closeout-receipt.v3'
    taskId=[string]$Fixture.contract.taskId
    workspaceKey=[string]$Fixture.contract.workspaceKey
    ownerSessionKey=[string]$Fixture.contract.ownerSessionKey
    packageVersion=[string]$Fixture.contract.packageVersion
    phase=(Get-SuperBrainFormalPhaseToken ([string]$Fixture.contract.currentPhase))
    contractRevision=[int]$Fixture.contract.revision
    planFingerprint=[string]$Fixture.contract.planReceipt.planFingerprint
    phaseEvidencePolicy='h7_current'
    decision='accepted'
    h7=[ordered]@{
      mode='hookless_turn_runtime'
      scopeRef=[string]$Evidence.value.scope.scopeRef
      contractHash=[string]$Evidence.value.scope.contractHash
      entryReceiptHash=$entryHash
      telemetryPayloadHash=[string]$Evidence.value.telemetry.payloadHash
      projectProgressPayloadHash=[string]$Evidence.value.projectProgress.payloadHash
      visibleProgressPayloadHash=[string]$Evidence.value.visibleProgress.payloadHash
    }
    rawPromptStored=$false
    rawTranscriptStored=$false
  }
  if (-not $OmitHostStageReceipt) { $receipt.hostStageReceipt = New-HostStageReceipt $Fixture $Evidence -TamperVisibleProgressHash:$TamperVisibleProgressHash }
  return $receipt
}

function Write-H7CloseoutReceipt([object]$Fixture,[object]$Receipt) {
  $path = Join-Path $Fixture.stateRoot 'workspace\runtime-state\phase-evidence\h7-closeout.json'
  Write-PhaseCloseoutJson $path $Receipt
  return $path
}

function Invoke-H7PhaseAdvance([object]$Fixture,[string]$ReceiptPath='',[string]$NextPhase='P8',[string]$NextStep='start P8',[string]$InstructionMode='continue') {
  $args = @(
    '-Action','Set','-TaskId',$Fixture.taskId,'-WorkspaceKey',$Fixture.workspaceKey,'-SessionKey',$Fixture.sessionKey,
    '-FocusId','main-line','-InstructionMode',$InstructionMode,'-CurrentPhase',$NextPhase,'-CurrentStep',$NextStep,'-NextAction',$NextStep,
    '-ProjectRoot',$Fixture.hostRoot,'-ExpectedRevision',[string]$Fixture.contract.revision,
    '-ExpectedPlanFingerprint',[string]$Fixture.contract.planReceipt.planFingerprint,'-TransitionId','h7-phase-advance',
    '-StateRoot',$Fixture.stateRoot,'-Json'
  )
  if ($ReceiptPath) { $args += @('-PhaseCloseoutPath',$ReceiptPath) }
  return Invoke-PhaseCloseoutContract $Fixture.hostRoot $args
}

Describe 'H7-only phase closeout evidence' {
  It 'blocks a formal phase transition when no phase closeout receipt exists' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7
    $blocked = Invoke-H7PhaseAdvance $fixture

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED'
    $blocked.value.phase | Should Be 'P7'
    $blocked.value.nextPhase | Should Be 'P8'
  }

  It 'blocks an R5 Stage 9-to-Stage 10 transition when no H7 closeout receipt exists' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'R5 Stage 9' -Step 'finish Stage 9' -NextAction 'enter Stage 10'
    $blocked = Invoke-H7PhaseAdvance $fixture '' 'R5 Stage 10' 'start Stage 10'

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED'
    $blocked.value.phase | Should Be 'R5-STAGE9'
    $blocked.value.nextPhase | Should Be 'R5-STAGE10'
  }

  It 'blocks a release-neutral Stage 0-to-Stage 1 transition when no H7 closeout receipt exists' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'Stage 0 - baseline' -Step 'finish Stage 0' -NextAction 'enter Stage 1'
    $blocked = Invoke-H7PhaseAdvance $fixture '' 'Stage 1 - rules' 'start Stage 1'

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED'
    $blocked.value.phase | Should Be 'STAGE0'
    $blocked.value.nextPhase | Should Be 'STAGE1'
  }

  It 'does not let side-branch mode bypass a same-workline R5 stage closeout' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'R5 Stage 9' -Step 'finish Stage 9' -NextAction 'enter Stage 10'
    $blocked = Invoke-H7PhaseAdvance $fixture '' 'R5 Stage 10' 'start Stage 10' 'side_branch'

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED'
  }

  It 'allows a same-workline formal stage correction without pretending it is a forward closeout' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'R5 Stage 10' -Step 'incorrect stage' -NextAction 'correct the stage state'
    $corrected = Invoke-H7PhaseAdvance $fixture '' 'R5 Stage 9' 'repair the stage gate'

    $corrected.exitCode | Should Be 0
    $corrected.value.currentPhase | Should Be 'R5 Stage 9'
  }

  It 'allows an R5 Stage 9-to-Stage 10 transition only with current H7 proof and closeout evidence' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'R5 Stage 9' -Step 'finish Stage 9' -NextAction 'enter Stage 10'
    $receiptPath = Write-H7CloseoutReceipt $fixture (New-H7CloseoutReceipt $fixture $fixture.evidence)
    $advanced = Invoke-H7PhaseAdvance $fixture $receiptPath 'R5 Stage 10' 'start Stage 10'

    $advanced.exitCode | Should Be 0
    $advanced.value.currentPhase | Should Be 'R5 Stage 10'
    $advanced.value.phaseCloseouts[-1].phase | Should Be 'R5-STAGE9'
    $advanced.value.phaseCloseouts[-1].nextPhase | Should Be 'R5-STAGE10'
    $advanced.value.phaseCloseouts[-1].hostStageReceipt.observationSource | Should Be 'codex_app_read_thread'
  }

  It 'creates an H7-only v3 closeout from a body-free Host readback without advancing the contract' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'R5 Stage 9' -Step 'finish Stage 9' -NextAction 'enter Stage 10'
    $created = Invoke-CreatePhaseCloseout $fixture
    $receipt = if ($created.exitCode -eq 0) { Get-Content -LiteralPath $created.value.receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $beforeAdvance = Invoke-PhaseCloseoutContract $fixture.hostRoot @('-Action','Get','-TaskId',$fixture.taskId,'-WorkspaceKey',$fixture.workspaceKey,'-SessionKey',$fixture.sessionKey,'-StateRoot',$fixture.stateRoot,'-Json')
    $advanced = if ($created.exitCode -eq 0) { Invoke-H7PhaseAdvance $fixture $created.value.receiptPath 'R5 Stage 10' 'start Stage 10' } else { $null }

    $created.exitCode | Should Be 0
    $created.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_CREATED'
    $created.value.contractMutated | Should Be $false
    $created.value.phase | Should Be 'R5-STAGE9'
    $created.value.revision | Should Be $fixture.contract.revision
    $created.value.receiptSha256 | Should Match '^[a-f0-9]{64}$'
    (Test-SuperBrainPhaseCloseoutChildPath (Join-Path $fixture.stateRoot 'workspace\runtime-state\phase-evidence') $created.value.receiptPath) | Should Be $true
    $receipt.schema | Should Be 'super-brain.phase-closeout-receipt.v3'
    $receipt.h7.visibleProgressPayloadHash | Should Be $fixture.evidence.value.visibleProgress.payloadHash
    $receipt.hostStageReceipt.observationSource | Should Be 'codex_app_read_thread'
    $receipt.rawPromptStored | Should Be $false
    $receipt.rawTranscriptStored | Should Be $false
    $beforeAdvance.exitCode | Should Be 0
    $beforeAdvance.value.revision | Should Be $fixture.contract.revision
    @($beforeAdvance.value.phaseCloseouts).Count | Should Be 0
    $advanced.exitCode | Should Be 0
    $advanced.value.currentPhase | Should Be 'R5 Stage 10'
  }

  It 'accepts the prompt-injected current-tail readback as the same bounded H7 source' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'R5 Stage 9' -Step 'finish Stage 9' -NextAction 'enter Stage 10'
    $created = Invoke-CreatePhaseCloseout $fixture (New-HostReadbackProjection 'codex_visible_context')
    $advanced = if ($created.exitCode -eq 0) { Invoke-H7PhaseAdvance $fixture $created.value.receiptPath 'R5 Stage 10' 'start Stage 10' } else { $null }

    $created.exitCode | Should Be 0
    $created.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_CREATED'
    $receipt = Get-Content -LiteralPath $created.value.receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $receipt.hostStageReceipt.observationSource | Should Be 'codex_visible_context'
    $advanced.exitCode | Should Be 0
    $advanced.value.currentPhase | Should Be 'R5 Stage 10'
    $advanced.value.phaseCloseouts[-1].hostStageReceipt.observationSource | Should Be 'codex_visible_context'
  }

  It 'replays the same issued closeout path without creating a second receipt or changing the contract' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7
    $first = Invoke-CreatePhaseCloseout $fixture
    $second = Invoke-CreatePhaseCloseout $fixture
    $evidenceRoot = Join-Path $fixture.stateRoot 'workspace\runtime-state\phase-evidence'

    $first.exitCode | Should Be 0
    $second.exitCode | Should Be 0
    $first.value.receiptPath | Should Be $second.value.receiptPath
    $first.value.receiptSha256 | Should Be $second.value.receiptSha256
    $second.value.replayed | Should Be $true
    @(Get-ChildItem -LiteralPath $evidenceRoot -Filter '*.json' -File).Count | Should Be 1
  }

  It 'rejects Host readback bodies that try to supply H7 scope or hash material' {
    foreach ($source in @('codex_app_read_thread','codex_visible_context')) {
      $fixture = New-PhaseCloseoutFixture -ActivateH7
      $blocked = Invoke-CreatePhaseCloseout $fixture (New-HostReadbackProjection $source -AddForbiddenHash)
      $evidenceRoot = Join-Path $fixture.stateRoot 'workspace\runtime-state\phase-evidence'

      $blocked.exitCode | Should Be 1
      $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_HOST_READBACK_FIELDS_INVALID'
      (Test-Path -LiteralPath $evidenceRoot) | Should Be $false
    }
  }

  It 'rejects closeout authority inputs outside its bounded Host projection and CAS scope' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7
    $blocked = Invoke-CreatePhaseCloseout $fixture (New-HostReadbackProjection) @('-LatestUserInstruction','raw caller text')
    $evidenceRoot = Join-Path $fixture.stateRoot 'workspace\runtime-state\phase-evidence'

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_INPUT_FORBIDDEN'
    (Test-Path -LiteralPath $evidenceRoot) | Should Be $false
  }

  It 'fails closeout creation on a stale contract revision before it writes an artifact' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7
    $fixture.contract.revision = [int]$fixture.contract.revision - 1
    $blocked = Invoke-CreatePhaseCloseout $fixture
    $evidenceRoot = Join-Path $fixture.stateRoot 'workspace\runtime-state\phase-evidence'

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_REVISION_MISMATCH'
    (Test-Path -LiteralPath $evidenceRoot) | Should Be $false
  }

  It 'blocks an R5 Stage 9-to-Stage 10 transition when H7 closeout lacks a host readback stage receipt' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'R5 Stage 9' -Step 'finish Stage 9' -NextAction 'enter Stage 10'
    $receiptPath = Write-H7CloseoutReceipt $fixture (New-H7CloseoutReceipt $fixture $fixture.evidence -OmitHostStageReceipt)
    $blocked = Invoke-H7PhaseAdvance $fixture $receiptPath 'R5 Stage 10' 'start Stage 10'

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_HOST_STAGE_RECEIPT_REQUIRED'
  }

  It 'blocks an R5 Stage 9-to-Stage 10 transition when host readback does not match current visible progress' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7 -Phase 'R5 Stage 9' -Step 'finish Stage 9' -NextAction 'enter Stage 10'
    $receiptPath = Write-H7CloseoutReceipt $fixture (New-H7CloseoutReceipt $fixture $fixture.evidence -TamperVisibleProgressHash)
    $blocked = Invoke-H7PhaseAdvance $fixture $receiptPath 'R5 Stage 10' 'start Stage 10'

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_HOST_STAGE_RECEIPT_MISMATCH'
  }

  It 'fails closed when a v2 receipt is supplied without current H7 evidence' {
    $fixture = New-PhaseCloseoutFixture
    $fakeEvidence = [pscustomobject]@{ value=[pscustomobject]@{
      scope=[pscustomobject]@{scopeRef=('a' * 64);contractHash=('b' * 64)}
      entry=[pscustomobject]@{receipt=[pscustomobject]@{receiptHash=('c' * 64)} }
      telemetry=[pscustomobject]@{payloadHash=('d' * 64)}
      projectProgress=[pscustomobject]@{payloadHash=[string]$fixture.contract.projectProgressProof.payloadHash}
    } }
    $receiptPath = Write-H7CloseoutReceipt $fixture (New-H7CloseoutReceipt $fixture $fakeEvidence)
    $blocked = Invoke-H7PhaseAdvance $fixture $receiptPath

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_H7_EVIDENCE_NOT_CURRENT'
  }

  It 'rejects a legacy phase-evidence policy before it can create a P7/Hook contract' {
    $stateRoot = Join-Path $TestDrive ('legacy-policy-' + [guid]::NewGuid().ToString('n').Substring(0,8))
    $hostRoot = Join-Path $TestDrive ('legacy-host-' + [guid]::NewGuid().ToString('n').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $stateRoot,$hostRoot | Out-Null
    $blocked = Invoke-PhaseCloseoutContract $hostRoot @(
      '-Action','Set','-TaskId','task-legacy-phase-policy','-WorkspaceKey',(Get-SuperBrainWorkspaceKey $hostRoot),
      '-SessionKey','sid-e777777777777777777777777','-FocusId','main-line','-InstructionMode','continue',
      '-CurrentPhase','P7','-CurrentStep','legacy policy','-NextAction','legacy policy',
      '-PhaseEvidencePolicy','host_user_attested','-StateRoot',$stateRoot,'-Json'
    )

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_EVIDENCE_POLICY_RETIRED'
  }

  It 'explicitly retires a legacy P7/Hook closeout receipt without consulting Hook evidence' {
    $fixture = New-PhaseCloseoutFixture
    $legacy = [ordered]@{
      schema='super-brain.phase-closeout-receipt.v1'
      taskId=[string]$fixture.contract.taskId;workspaceKey=[string]$fixture.contract.workspaceKey;ownerSessionKey=[string]$fixture.contract.ownerSessionKey
      packageVersion=[string]$fixture.contract.packageVersion;phase='P7';contractRevision=[int]$fixture.contract.revision
      planFingerprint=[string]$fixture.contract.planReceipt.planFingerprint;phaseEvidencePolicy='host_user_attested';decision='accepted'
      realUserPath=[pscustomobject]@{source='native_prompt_hook'};rawPromptStored=$false;rawTranscriptStored=$false
    }
    $receiptPath = Write-H7CloseoutReceipt $fixture $legacy
    $blocked = Invoke-H7PhaseAdvance $fixture $receiptPath

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_RETIRED_P7_EVIDENCE'
  }

  It 'allows a P7-to-P8 transition only when current H7 checkpoint, telemetry, and project proof all bind' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7
    $fixture.checkpoint.value.checkpoint.code | Should Be 'H7_PROGRESS_CHECKPOINT_WRITTEN'
    $fixture.evidence.value.code | Should Be 'H7_EVIDENCE_CURRENT'
    $fixture.evidence.value.entry.current | Should Be $true
    $fixture.evidence.value.telemetry.current | Should Be $true
    $fixture.evidence.value.projectProgress.state | Should Be 'current'
    $receiptPath = Write-H7CloseoutReceipt $fixture (New-H7CloseoutReceipt $fixture $fixture.evidence)
    $advanced = Invoke-H7PhaseAdvance $fixture $receiptPath

    $advanced.exitCode | Should Be 0
    $advanced.value.currentPhase | Should Be 'P8'
    $advanced.value.phaseCloseouts[-1].schema | Should Be 'super-brain.phase-closeout.v3'
    $advanced.value.phaseCloseouts[-1].phaseEvidencePolicy | Should Be 'h7_current'
    $advanced.value.phaseCloseouts[-1].h7.mode | Should Be 'hookless_turn_runtime'
    $advanced.value.phaseCloseouts[-1].h7.entryReceiptHash | Should Be $fixture.evidence.value.entry.receipt.receiptHash
  }

  It 'rejects a receipt whose claimed H7 receipt hash was tampered' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7
    $receiptPath = Write-H7CloseoutReceipt $fixture (New-H7CloseoutReceipt $fixture $fixture.evidence -TamperEntryHash)
    $blocked = Invoke-H7PhaseAdvance $fixture $receiptPath

    $blocked.exitCode | Should Be 1
    $blocked.value.code | Should Be 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_H7_BINDING_MISMATCH'
  }

  It 'revalidates the recorded closeout against current H7 evidence, not any Hook artifact' {
    $fixture = New-PhaseCloseoutFixture -ActivateH7
    $receiptPath = Write-H7CloseoutReceipt $fixture (New-H7CloseoutReceipt $fixture $fixture.evidence)
    $resolution = Resolve-SuperBrainPhaseCloseouts $fixture.contract 'P8' 'main-line' 'continue' $receiptPath (Join-Path $fixture.stateRoot 'workspace') ([string]$fixture.contract.packageVersion) $root $fixture.stateRoot $fixture.hostRoot
    $candidate = $fixture.contract | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $candidate.currentPhase = 'P8'
    $candidate.phaseCloseouts = @($resolution.closeout)
    $legacyHookPath = Join-Path $fixture.stateRoot 'workspace\runtime-state\prompt-hook-telemetry\legacy.json'
    Write-PhaseCloseoutJson $legacyHookPath ([ordered]@{schema='super-brain.codex-user-prompt-hook.v1';rawPromptStored=$false;rawSessionIdStored=$false;tampered=$true})
    $current = Assert-SuperBrainPhaseCloseoutTransition $fixture.contract $candidate (Join-Path $fixture.stateRoot 'workspace') ([string]$fixture.contract.packageVersion) $root $fixture.stateRoot $fixture.hostRoot

    $resolution.ok | Should Be $true
    $current.ok | Should Be $true

    $scopeRef = [string]$fixture.evidence.value.scope.scopeRef
    $openReceipt = Join-Path $fixture.stateRoot ('workspace\runtime-state\turn-runtime\receipts\' + $scopeRef + '\open.json')
    $raw = Get-Content -LiteralPath $openReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
    $raw.receiptHash = ('0' * 64)
    Write-PhaseCloseoutJson $openReceipt $raw
    $stale = Assert-SuperBrainPhaseCloseoutTransition $fixture.contract $candidate (Join-Path $fixture.stateRoot 'workspace') ([string]$fixture.contract.packageVersion) $root $fixture.stateRoot $fixture.hostRoot

    $stale.ok | Should Be $false
    $stale.code | Should Be 'PHASE_CLOSEOUT_H7_EVIDENCE_NOT_CURRENT'
  }
}
