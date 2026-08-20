param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [string]$Query = '',
  [string]$Scope = '',
  [string]$TaskId = '',
  [string]$SessionKey = '',
  [string]$ProposedWorkId = '',
  [ValidateSet('BeforeAct','BeforeMutation','BeforeCompletion','AfterUserCorrection','Status')]
  [string]$Phase = 'BeforeAct',
  [int]$MaxAgeMinutes = 60,
  [switch]$AllowMissingPreflight,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$hostSessionKey = Get-SuperBrainLocalSessionKey $SessionKey
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-cognitive-enforce.json'
$inputText = if (-not [string]::IsNullOrWhiteSpace($Query)) { $Query } else { (($Text -join ' ').Trim()) }
if ([string]::IsNullOrWhiteSpace($inputText)) { $inputText = 'general task' }

function Limit-Text([string]$Value, [int]$Max = 240) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Add-Check([System.Collections.ArrayList]$Checks, [string]$Name, [bool]$Ok, [string]$Evidence, [bool]$Required = $true) {
  [void]$Checks.Add([pscustomobject]@{ name=$Name; ok=$Ok; required=$Required; evidence=Limit-Text $Evidence 360 })
}

function New-UnavailableMemoryInfluence([string]$Code,[string]$Status='unavailable') {
  return [pscustomobject]@{
    available=$false
    ok=$true
    status=$Status
    code=$Code
    schema='super-brain.execution-memory-influence.v1'
    kindEffects=[pscustomobject]@{
      note='reference_only'
      preference='behavior_shaping'
      experience='advice_and_reuse'
      decision='receipt_bound_constraint'
      procedure='governed_steps'
      reflection='learning_candidate_only'
    }
    behaviorGuidance=@()
    reusableAdvice=@()
    procedureSteps=@()
    references=@()
    learningCandidates=@()
    decisionHandling=[pscustomobject]@{ effect='receipt_bound_constraint'; source='get_decision_context.constraints'; requiresDecisionReceipt=$true }
    omitted=[pscustomobject]@{ invalid=0; expired=0; notReady=0; unmatched=0 }
    focusStored=$false
    rawPromptStored=$false
  }
}

function Get-ExecutionMemoryInfluence([string]$WorkspaceKey,[string]$EffectiveTaskId,[string]$TaskInstanceId,[string]$Focus) {
  $databasePath = Join-Path $memoryBase 'workspace\brain-state.sqlite3'
  if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
    return New-UnavailableMemoryInfluence 'MEMORY_INFLUENCE_DATABASE_ABSENT'
  }
  $python = Get-Command python -ErrorAction SilentlyContinue
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  if (-not $python -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return New-UnavailableMemoryInfluence 'MEMORY_INFLUENCE_RUNTIME_UNAVAILABLE'
  }
  $pythonPath = [string]$python.Source
  if ([string]::IsNullOrWhiteSpace($pythonPath)) { $pythonPath = [string]$python.Name }
  $request = [ordered]@{
    workspaceKey=$WorkspaceKey
    taskId=$EffectiveTaskId
    taskInstanceId=$TaskInstanceId
    ownerSessionKey=$hostSessionKey
    focus=(Limit-Text $Focus 480)
    maxPerKind=3
  }
  try {
    $json = $request | ConvertTo-Json -Depth 8 -Compress
    $raw = @($json | & $pythonPath -X utf8 -B $runtime --state-root $memoryBase get-memory-influence 2>&1)
    $exitCode = $LASTEXITCODE
    $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $value = ConvertFrom-SuperBrainJsonOutput $text 'cognitive enforce memory influence'
    if ($exitCode -ne 0 -or -not $value -or $value.ok -ne $true) {
      return [pscustomobject]@{
        available=$true
        ok=$false
        status='withheld'
        code=if($value -and $value.PSObject.Properties['code']){[string]$value.code}else{'MEMORY_INFLUENCE_LOOKUP_FAILED'}
        schema='super-brain.execution-memory-influence.v1'
        kindEffects=[pscustomobject]@{}
        behaviorGuidance=@()
        reusableAdvice=@()
        procedureSteps=@()
        references=@()
        learningCandidates=@()
        decisionHandling=[pscustomobject]@{ effect='receipt_bound_constraint'; source='get_decision_context.constraints'; requiresDecisionReceipt=$true }
        omitted=[pscustomobject]@{ invalid=0; expired=0; notReady=0; unmatched=0 }
        focusStored=$false
        rawPromptStored=$false
      }
    }
    $value | Add-Member -NotePropertyName available -NotePropertyValue $true -Force
    $value | Add-Member -NotePropertyName code -NotePropertyValue 'MEMORY_INFLUENCE_READY' -Force
    return $value
  } catch {
    return [pscustomobject]@{
      available=$true
      ok=$false
      status='withheld'
      code='MEMORY_INFLUENCE_LOOKUP_FAILED'
      schema='super-brain.execution-memory-influence.v1'
      kindEffects=[pscustomobject]@{}
      behaviorGuidance=@()
      reusableAdvice=@()
      procedureSteps=@()
      references=@()
      learningCandidates=@()
      decisionHandling=[pscustomobject]@{ effect='receipt_bound_constraint'; source='get_decision_context.constraints'; requiresDecisionReceipt=$true }
      omitted=[pscustomobject]@{ invalid=0; expired=0; notReady=0; unmatched=0 }
      focusStored=$false
      rawPromptStored=$false
    }
  }
}

function New-NoLearningCandidate([string]$Code,[string]$Status='not_applicable') {
  return [pscustomobject]@{
    attempted=$false
    ok=$true
    status=$Status
    code=$Code
    candidate=$null
    rawPromptStored=$false
    memoryBodyStored=$false
  }
}

function Invoke-H7MemoryLearningCandidate([string]$WorkspaceKey,[string]$EffectiveTaskId,[string]$TaskInstanceId) {
  if ([string]::IsNullOrWhiteSpace($EffectiveTaskId) -or [string]::IsNullOrWhiteSpace($TaskInstanceId)) {
    return New-NoLearningCandidate 'H7_MEMORY_LEARNING_TASK_SCOPE_UNAVAILABLE' 'withheld'
  }
  $python = Get-Command python -ErrorAction SilentlyContinue
  $brainCli = Join-Path $Root 'runtime\brain_cli.py'
  $runtime = Join-Path $Root 'runtime\brain_control.py'
  if (-not $python -or -not (Test-Path -LiteralPath $brainCli -PathType Leaf) -or -not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
    return [pscustomobject]@{
      attempted=$true; ok=$false; status='withheld'; code='H7_MEMORY_LEARNING_RUNTIME_UNAVAILABLE'; candidate=$null
      rawPromptStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false
    }
  }
  $pythonPath = [string]$python.Source
  if ([string]::IsNullOrWhiteSpace($pythonPath)) { $pythonPath = [string]$python.Name }
  $oldThread = $env:SUPER_BRAIN_LOCAL_SESSION_ID
  $oldWorkspace = $env:SUPER_BRAIN_WORKSPACE_KEY
  $oldStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  try {
    $env:SUPER_BRAIN_LOCAL_SESSION_ID = $hostSessionKey
    $env:SUPER_BRAIN_WORKSPACE_KEY = $WorkspaceKey
    $env:SUPER_BRAIN_STATE_ROOT = $memoryBase
    $memoryRoot = Join-Path $memoryBase 'shared'
    $evidenceRaw = @(& $pythonPath -X utf8 -B $brainCli --package-root $Root --memory-root $memoryRoot turn-runtime --phase evidence --memory-mode auto --turn-intent memory_write --timeout-seconds 20 2>&1)
    $evidenceExitCode = $LASTEXITCODE
    $evidenceText = (@($evidenceRaw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $evidence = ConvertFrom-SuperBrainJsonOutput $evidenceText 'cognitive enforce H7 learning evidence'
    if ($evidenceExitCode -ne 0 -or -not $evidence -or $evidence.ok -ne $true -or $evidence.available -ne $true -or [string]$evidence.code -ne 'H7_EVIDENCE_CURRENT') {
      return [pscustomobject]@{
        attempted=$true; ok=$false; status='withheld'; code=if($evidence -and $evidence.PSObject.Properties['code']){[string]$evidence.code}else{'H7_MEMORY_LEARNING_EVIDENCE_UNAVAILABLE'}; candidate=$null
        rawPromptStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false
      }
    }
    $scope = $evidence.scope
    $entry = $evidence.entry
    $telemetry = $evidence.telemetry
    $memoryInjection = $evidence.memoryInjection
    $entryReceipt = if($entry){$entry.receipt}else{$null}
    if (-not $scope -or -not $entry -or $entry.current -ne $true -or -not $entryReceipt -or -not $telemetry -or $telemetry.current -ne $true -or -not $memoryInjection) {
      return New-NoLearningCandidate 'H7_MEMORY_LEARNING_EVIDENCE_INCOMPLETE' 'withheld'
    }
    if ([string]$scope.workspaceKey -ne $WorkspaceKey -or [string]$scope.taskId -ne $EffectiveTaskId -or [string]$scope.taskInstanceId -ne $TaskInstanceId -or [string]::IsNullOrWhiteSpace([string]$scope.scopeRef) -or [string]::IsNullOrWhiteSpace([string]$entryReceipt.receiptHash) -or [string]::IsNullOrWhiteSpace([string]$telemetry.payloadHash) -or [string]::IsNullOrWhiteSpace([string]$memoryInjection.refsHash)) {
      return New-NoLearningCandidate 'H7_MEMORY_LEARNING_SCOPE_OR_HASH_MISMATCH' 'withheld'
    }
    $request = [ordered]@{
      workspaceKey=$WorkspaceKey
      ownerSessionKey=$hostSessionKey
      taskId=$EffectiveTaskId
      taskInstanceId=$TaskInstanceId
      scopeRef=[string]$scope.scopeRef
      entryReceiptHash=[string]$entryReceipt.receiptHash
      telemetryHash=[string]$telemetry.payloadHash
      typedMemoryRefsHash=[string]$memoryInjection.refsHash
      maxAgeMinutes=$MaxAgeMinutes
    }
    $json = $request | ConvertTo-Json -Depth 8 -Compress
    $raw = @($json | & $pythonPath -X utf8 -B $runtime --state-root $memoryBase record-h7-memory-learning-candidate 2>&1)
    $exitCode = $LASTEXITCODE
    $text = (@($raw | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $value = ConvertFrom-SuperBrainJsonOutput $text 'cognitive enforce H7 memory learning candidate'
    if ($exitCode -ne 0 -or -not $value -or $value.ok -ne $true) {
      return [pscustomobject]@{
        attempted=$true; ok=$false; status='withheld'; code=if($value -and $value.PSObject.Properties['code']){[string]$value.code}else{'H7_MEMORY_LEARNING_CAPTURE_FAILED'}; candidate=$null
        rawPromptStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false
      }
    }
    $value | Add-Member -NotePropertyName attempted -NotePropertyValue $true -Force
    return $value
  } catch {
    return [pscustomobject]@{
      attempted=$true; ok=$false; status='withheld'; code='H7_MEMORY_LEARNING_CAPTURE_FAILED'; candidate=$null
      rawPromptStored=$false; rawTranscriptStored=$false; memoryBodyStored=$false
    }
  } finally {
    if ($null -eq $oldThread) { Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_LOCAL_SESSION_ID = $oldThread }
    if ($null -eq $oldWorkspace) { Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_WORKSPACE_KEY = $oldWorkspace }
    if ($null -eq $oldStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $oldStateRoot }
  }
}

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
$lower = $inputText.ToLowerInvariant()
$zhSubAgent = (U @(23376)) + 'agent'
$zhChannel = U @(36890,36947)

function Test-EngineeringJudgmentIntent([string]$IntentName) {
  if ($IntentName -eq 'add_or_optimize_feature') { return $true }
  foreach ($term in @('fix','debug','repair','optimize','optimization','architecture','architect','root cause','tradeoff','trade-off','best option','optimal','performance','bottleneck','regression','refactor','migration','failure analysis')) {
    if ($lower.Contains($term)) { return $true }
  }
  foreach ($term in @((U @(20462,22797)),(U @(20248,21270)),(U @(26550,26500)),(U @(26681,22240)),(U @(26368,20248)),(U @(26368,20339)),(U @(24615,33021)),(U @(37325,26500)),(U @(25925,38556)),(U @(35774,35745)),(U @(20915,31574)))) {
    if ($inputText.Contains($term)) { return $true }
  }
  return $false
}

$intent = $null
try {
  $intentRaw = @(& (Join-Path $PSScriptRoot 'intent-router.ps1') -Text $inputText -Json 2>$null)
  if ($intentRaw) { $intent = (($intentRaw -join "`n") | ConvertFrom-Json) }
} catch {}
$intentName = if ($intent -and $intent.intent) { [string]$intent.intent } else { 'general_task' }
$collaborativeIntent = ($intentName -eq 'add_or_optimize_feature' -or ($intent -and @($intent.dispatchHints) -contains 'collaborative_intent'))
$engineeringRequiredFromInput = Test-EngineeringJudgmentIntent $intentName

$highRiskReasons = New-Object System.Collections.ArrayList
if ($intentName -eq 'agent_bridge_channel' -or $lower.Contains('agent bridge') -or ($lower.Contains('agent') -and ($inputText.Contains($zhChannel) -or $inputText.Contains($zhSubAgent)))) { [void]$highRiskReasons.Add('agent_bridge_channel') }
if ($engineeringRequiredFromInput) { [void]$highRiskReasons.Add('engineering_judgment') }
foreach ($term in @('memory mechanism','cognitive','preflight','startup','global route','hot-refresh','version bump','release','historical import','destructive','apply','force','delete','remove','overwrite')) {
  if ($lower.Contains($term)) { [void]$highRiskReasons.Add($term.Replace(' ','_')) }
}
foreach ($term in @((U @(35760,24518)),(U @(20840,23616)),(U @(36335,30001)),(U @(21457,24067)),(U @(21382,21490)),(U @(21024,38500)))) {
  if ($inputText.Contains($term)) { [void]$highRiskReasons.Add('cjk_high_risk') }
}
$isHighRisk = ($highRiskReasons.Count -gt 0)

$preflight = Read-WorkspaceJson 'last-cognitive-preflight.json'
$checks = New-Object System.Collections.ArrayList
$violations = New-Object System.Collections.ArrayList
$blockers = New-Object System.Collections.ArrayList

$preflightExists = ($null -ne $preflight)
$preflightExistsEvidence = if ($preflightExists) { "path=last-cognitive-preflight.json checkedAt=$($preflight.checkedAt)" } else { 'missing last-cognitive-preflight.json' }
Add-Check $checks 'cognitive-preflight-exists' ($preflightExists -or -not $isHighRisk -or $AllowMissingPreflight) $preflightExistsEvidence $isHighRisk

$preflightQueryMatch = ($preflightExists -and [string]$preflight.query -eq (Limit-Text $inputText 260))
$preflightQueryEvidence = if ($preflightExists) { "expected=$(Limit-Text $inputText 260) observed=$($preflight.query)" } else { 'missing preflight' }
Add-Check $checks 'cognitive-preflight-query-match' ($preflightQueryMatch -or -not $isHighRisk -or $AllowMissingPreflight) $preflightQueryEvidence $isHighRisk

$preflightFresh = $false
if ($preflightExists -and $preflight.checkedAt) {
  try {
    $age = ((Get-Date) - [datetime]::Parse([string]$preflight.checkedAt)).TotalMinutes
    $preflightFresh = ($age -le $MaxAgeMinutes)
  } catch { $preflightFresh = $false }
}
$preflightFreshEvidence = if ($preflightExists) { "maxAgeMinutes=$MaxAgeMinutes checkedAt=$($preflight.checkedAt)" } else { 'no preflight to age-check' }
Add-Check $checks 'cognitive-preflight-fresh' ($preflightFresh -or -not $isHighRisk -or $AllowMissingPreflight) $preflightFreshEvidence $isHighRisk

$modeOk = ($preflightExists -and [string]$preflight.cognitiveMode -eq 'memory_driven_execution_control')
$modeEvidence = if ($preflightExists) { "cognitiveMode=$($preflight.cognitiveMode)" } else { 'missing preflight' }
Add-Check $checks 'memory-driven-mode' ($modeOk -or -not $isHighRisk -or $AllowMissingPreflight) $modeEvidence $isHighRisk

$mustCount = if ($preflightExists) { @($preflight.mustPreserve).Count } else { 0 }
$guardCount = if ($preflightExists) { @($preflight.driftGuards).Count } else { 0 }
Add-Check $checks 'must-preserve-present' ($mustCount -gt 0 -or -not $isHighRisk -or $AllowMissingPreflight) "mustPreserve=$mustCount" $isHighRisk
Add-Check $checks 'drift-guards-present' ($guardCount -gt 0 -or -not $isHighRisk -or $AllowMissingPreflight) "driftGuards=$guardCount" $isHighRisk

$engineeringRequired = ($engineeringRequiredFromInput -or ($preflightExists -and $preflightQueryMatch -and $preflight.engineeringJudgment.required -eq $true))
$engineeringContractPresent = ($preflightExists -and $preflight.engineeringJudgment -and [string]$preflight.engineeringJudgment.decisionGate -eq 'engineering-decision-gate.ps1')
Add-Check $checks 'engineering-judgment-contract' ($engineeringContractPresent -or -not $engineeringRequired -or $AllowMissingPreflight) "required=$engineeringRequired decisionGate=$($preflight.engineeringJudgment.decisionGate)" $engineeringRequired

$currentTaskContext = Get-SuperBrainCurrentTaskContext $workspace
$workspaceKey = Get-SuperBrainWorkspaceKey
$executionContractRequired = $false
$executionContractGuard = $null
$executionResolutionFailed = $false
$executionResolutionFailureCode = ''
$executionResolutionNoContract = $false
$resolution = $null
$intentReceiptRequired = $false
$intentReceiptOk = $true
$intentReceiptCode = 'EXECUTION_CONTRACT_INTENT_RECEIPT_NOT_REQUIRED'
$intentReceiptMissing = @()
$decisionGuidanceRequired = $false
$decisionGuidanceOk = $true
$decisionGuidanceCode = 'DECISION_BINDING_GUIDANCE_NOT_REQUIRED'
$decisionGuidance = @()
if ($Phase -in @('BeforeMutation','BeforeCompletion')) {
  try {
    $resolveParameters = @{Action='Resolve';WorkspaceKey=$workspaceKey;SessionKey=$hostSessionKey;NoExit=$true;Json=$true}
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $resolveParameters.TaskId = $TaskId }
    $resolveRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') @resolveParameters 2>$null)
    if (-not $resolveRaw) { throw 'execution contract returned no JSON' }
    $resolution = (($resolveRaw -join "`n") | ConvertFrom-Json)
    if (-not $resolution -or $resolution.ok -ne $true) {
      $executionResolutionFailed = $true
      $executionResolutionFailureCode = if($resolution){[string]$resolution.code}else{'EXECUTION_CONTRACT_EMPTY_RESULT'}
      $executionContractRequired = $true
    } else {
      $executionResolutionNoContract = ([string]$resolution.resolutionSource -eq 'none' -and [string]$resolution.actionAuthorization -eq 'not_applicable')
      if (-not $executionResolutionNoContract -and [string]::IsNullOrWhiteSpace($TaskId) -and -not [string]::IsNullOrWhiteSpace([string]$resolution.taskId)) { $TaskId = [string]$resolution.taskId }
      $executionContractRequired = (-not $executionResolutionNoContract -and (-not [string]::IsNullOrWhiteSpace($TaskId) -or [string]$resolution.resumeFrom -in @('execution_contract','execution_contract_pending_reconciliation','execution_contract_topic_unresolved','execution_contract_foreign_session','execution_contract_session_unbound','parent_return') -or [string]$resolution.actionAuthorization -eq 'withheld'))
      if ($executionResolutionNoContract -and $collaborativeIntent -and -not [string]::IsNullOrWhiteSpace($TaskId)) {
        $executionContractRequired = $true
        $intentReceiptRequired = $true
        $intentReceiptOk = $false
        $intentReceiptCode = 'EXECUTION_CONTRACT_INTENT_RECEIPT_REQUIRED'
        $intentReceiptMissing = @('task-scoped execution contract and intent receipt')
      }
    }
    if ($executionContractRequired -and -not $executionResolutionFailed) {
      $guardParameters = @{Action='Guard';WorkspaceKey=$workspaceKey;SessionKey=$hostSessionKey;ProposedWorkId=$ProposedWorkId;NoExit=$true;Json=$true}
      if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $guardParameters.TaskId = $TaskId }
      if ($resolution -and [int]$resolution.contractRevision -gt 0) { $guardParameters.ExpectedRevision = [int]$resolution.contractRevision }
      if ($resolution -and -not [string]::IsNullOrWhiteSpace([string]$resolution.planFingerprint)) { $guardParameters.ExpectedPlanFingerprint = [string]$resolution.planFingerprint }
      if ($collaborativeIntent) { $guardParameters.RequireIntentContract = $true }
      $guardRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') @guardParameters 2>$null)
      if ($guardRaw) { $executionContractGuard = (($guardRaw -join "`n") | ConvertFrom-Json) }
      if ($executionContractGuard -and $executionContractGuard.PSObject.Properties['intentReceipt']) {
        $intentReceiptRequired = [bool]$executionContractGuard.intentReceipt.required
        $intentReceiptOk = ([bool]$executionContractGuard.intentReceipt.current -and $executionContractGuard.ok -eq $true)
        $intentReceiptCode = [string]$executionContractGuard.intentReceipt.code
        $intentReceiptMissing = @($executionContractGuard.intentReceipt.missing)
      } elseif ($collaborativeIntent) {
        $intentReceiptRequired = $true
        $intentReceiptOk = $false
        $intentReceiptCode = if($executionContractGuard){[string]$executionContractGuard.code}else{'EXECUTION_CONTRACT_INTENT_RECEIPT_REQUIRED'}
        $intentReceiptMissing = @('task-scoped IntentContract and IntentResolutionReceipt')
      }
      if ($executionContractGuard -and $executionContractGuard.ok -eq $true -and $executionContractGuard.PSObject.Properties['decisionGuidance'] -and $executionContractGuard.decisionGuidance -and $executionContractGuard.decisionGuidance.required -eq $true) {
        $decisionGuidanceRequired = $true
        try {
          $guidance = $executionContractGuard.decisionGuidance
          $guidanceRaw = @(& (Join-Path $PSScriptRoot 'decision-binding.ps1') -Action GetPrivateGuidance -TaskId $TaskId -TaskInstanceId ([string]$guidance.taskInstanceId) -WorkspaceKey $workspaceKey -WorklineId ([string]$executionContractGuard.currentFocusId) -StageKind ([string]$guidance.stageKind) -IntentFingerprint ([string]$guidance.intentFingerprint) -ContractRevision ([int]$executionContractGuard.contractRevision) -PlanFingerprint ([string]$executionContractGuard.planFingerprint) -OwnerSessionKey ([string]$guidance.ownerSessionKey) -ReceiptPath ([string]$guidance.receiptPath) -StateRoot (Split-Path -Parent $workspace) -NoExit -Json 2>$null)
          $guidanceValue = if ($guidanceRaw) { (($guidanceRaw -join "`n") | ConvertFrom-Json) } else { $null }
          $decisionGuidanceOk = ($guidanceValue -and $guidanceValue.ok -eq $true -and [string]$guidanceValue.status -eq 'bound')
          $decisionGuidanceCode = if($guidanceValue){[string]$guidanceValue.code}else{'DECISION_BINDING_GUIDANCE_EMPTY'}
          if ($decisionGuidanceOk) { $decisionGuidance = @($guidanceValue.guidance | Select-Object -First 4) }
        } catch {
          $decisionGuidanceOk = $false
          $decisionGuidanceCode = 'DECISION_BINDING_GUIDANCE_LOOKUP_FAILED'
        }
      }
    }
  } catch {
    $executionResolutionFailed = $true
    $executionContractRequired = $true
    if ([string]::IsNullOrWhiteSpace($executionResolutionFailureCode)) { $executionResolutionFailureCode = 'EXECUTION_CONTRACT_RESOLVE_FAILED' }
  }
}

$memoryInfluence = New-UnavailableMemoryInfluence 'MEMORY_INFLUENCE_NOT_REQUESTED' 'not_applicable'
$memoryTaskInstanceId = ''
if ($Phase -in @('BeforeMutation','BeforeCompletion')) {
  if ($executionContractGuard -and $executionContractGuard.PSObject.Properties['decisionGuidance'] -and $executionContractGuard.decisionGuidance -and $executionContractGuard.decisionGuidance.PSObject.Properties['taskInstanceId'] -and -not [string]::IsNullOrWhiteSpace([string]$executionContractGuard.decisionGuidance.taskInstanceId)) {
    $memoryTaskInstanceId = [string]$executionContractGuard.decisionGuidance.taskInstanceId
  } elseif ($resolution -and $resolution.PSObject.Properties['taskInstanceId']) {
    $memoryTaskInstanceId = [string]$resolution.taskInstanceId
  }
  $memoryInfluence = Get-ExecutionMemoryInfluence $workspaceKey $TaskId $memoryTaskInstanceId $inputText
}

$engineeringGateRequired = ($engineeringRequired -and $Phase -in @('BeforeMutation','BeforeCompletion'))
$engineeringStatus = $null
if ($engineeringGateRequired) {
  try {
    $engineeringRaw = @(& (Join-Path $PSScriptRoot 'engineering-decision-gate.ps1') -Action Status -TaskId $TaskId -Json 2>$null)
    if ($engineeringRaw) { $engineeringStatus = (($engineeringRaw -join "`n") | ConvertFrom-Json) }
  } catch {}
}
$engineeringDecision = if($engineeringStatus -and $engineeringStatus.latest){$engineeringStatus.latest}else{$null}
$engineeringTaskMatch = ([string]::IsNullOrWhiteSpace($TaskId) -or ($engineeringDecision -and [string]$engineeringDecision.taskId -eq $TaskId))
$engineeringResolutionOk = (-not $engineeringDecision -or [string]$engineeringDecision.rootCause.status -eq 'verified' -or -not [string]::IsNullOrWhiteSpace([string]$engineeringDecision.rootCause.discriminatingTestEvidence))
$engineeringCompletionEvidenceOk = ($Phase -ne 'BeforeCompletion' -or $engineeringResolutionOk)
$engineeringGateOk = (-not $engineeringGateRequired -or ($engineeringStatus -and $engineeringStatus.ok -eq $true -and $engineeringDecision.ok -eq $true -and $engineeringDecision.epistemicGrounding.factsSupported -eq $true -and $engineeringCompletionEvidenceOk -and $engineeringTaskMatch))
$engineeringGateEvidence = 'not required before this phase'
if ($engineeringGateRequired) {
  $engineeringGateEvidence = if($engineeringDecision){"taskId=$($engineeringDecision.taskId) requiredTaskId=$TaskId decisionId=$($engineeringDecision.decisionId) rootCauseStatus=$($engineeringDecision.rootCause.status) completionEvidenceOk=$engineeringCompletionEvidenceOk gaps=$(@($engineeringDecision.gaps).Count)"}else{'missing valid task-scoped engineering decision'}
}
Add-Check $checks 'engineering-decision-gate' $engineeringGateOk $engineeringGateEvidence $engineeringGateRequired

$executionContractOk = (-not $executionContractRequired -or ($executionContractGuard -and $executionContractGuard.ok -eq $true))
$executionContractEvidence = if($executionResolutionFailed){"code=$executionResolutionFailureCode resolver failed before mutation authorization"}elseif($executionContractRequired){"code=$($executionContractGuard.code) currentFocus=$($executionContractGuard.currentFocusId) proposedWork=$ProposedWorkId"}elseif($executionResolutionNoContract){'no execution contract applies to this root session and workspace'}else{'no current task execution contract requires enforcement'}
Add-Check $checks 'execution-contract-guard' $executionContractOk $executionContractEvidence $executionContractRequired
$decisionGuidanceEvidence = if($decisionGuidanceRequired){"code=$decisionGuidanceCode guidanceCount=$(@($decisionGuidance).Count)"}else{'no bound completion decision requires private execution guidance'}
Add-Check $checks 'decision-binding-guidance' $decisionGuidanceOk $decisionGuidanceEvidence $decisionGuidanceRequired
$intentReceiptEvidence = if($intentReceiptRequired){"code=$intentReceiptCode missing=$($intentReceiptMissing -join ',')"}else{'task-scoped intent receipt is not required for this direct request'}
Add-Check $checks 'intent-resolution-receipt' $intentReceiptOk $intentReceiptEvidence $intentReceiptRequired

if (($isHighRisk -and -not $AllowMissingPreflight) -or $executionContractRequired) {
  foreach ($check in @($checks)) {
    if ($check.required -and $check.ok -ne $true) {
      [void]$violations.Add($check.name)
      [void]$blockers.Add("$($check.name): $($check.evidence)")
    }
  }
}

$learningCandidate = New-NoLearningCandidate 'NATIVE_MEMORY_LEARNING_NOT_A_COMPLETION_PHASE'
if ($Phase -eq 'BeforeCompletion') {
  if ($violations.Count -gt 0) {
    $learningCandidate = New-NoLearningCandidate 'NATIVE_MEMORY_LEARNING_GUARD_WITHHELD' 'withheld'
  } elseif (-not $executionContractRequired -or -not $executionContractGuard -or $executionContractGuard.ok -ne $true) {
    $learningCandidate = New-NoLearningCandidate 'NATIVE_MEMORY_LEARNING_EXECUTION_CONTRACT_REQUIRED' 'withheld'
  } else {
    $learningCandidate = Invoke-H7MemoryLearningCandidate $workspaceKey $TaskId $memoryTaskInstanceId
  }
}

$result = [pscustomobject]@{
  ok = ($violations.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.cognitive-enforce.v1'
  version = (Get-SuperBrainManifest $Root).version
  query = Limit-Text $inputText 260
  intent = $intentName
  phase = $Phase
  required = $isHighRisk
  highRiskReasons = @($highRiskReasons | Select-Object -Unique)
  checks = @($checks)
  violations = @($violations)
  blockers = @($blockers)
  candidateSignals = @($violations | ForEach-Object { [pscustomobject]@{ candidateType='gap'; gapKind=if($_ -like '*intent-resolution*'){'missing_intent_resolution'}elseif($_ -like '*engineering-decision*'){'missing_engineering_decision'}elseif($_ -like '*query-match*'){'stale_or_wrong_preflight'}elseif($_ -like '*fresh*'){'stale_state'}elseif($_ -like '*must*'){'missing_must_preserve'}elseif($_ -like '*drift*'){'missing_drift_guards'}else{'missing_preflight'}; severity='medium'; code=$_; expected=@('fresh query-matched cognitive-preflight','mustPreserve','driftGuards','current task-scoped intent receipt when required','valid engineering decision when required'); observed=@($_); missing=@($_); evidence=@('last-cognitive-enforce.json') } })
  mustPreserve = if ($preflightExists) { @($preflight.mustPreserve) } else { @() }
  driftGuards = if ($preflightExists) { @($preflight.driftGuards) } else { @() }
  memoryInfluence = $memoryInfluence
  learningCandidate = $learningCandidate
  engineeringJudgment = [pscustomobject]@{ required=$engineeringRequired; gateRequired=$engineeringGateRequired; gateOk=$engineeringGateOk; completionEvidenceOk=$engineeringCompletionEvidenceOk; taskId=$TaskId; decisionId=if($engineeringDecision){$engineeringDecision.decisionId}else{''}; epistemicClasses=@('FACT','INFERENCE','UNKNOWN') }
  executionContract = [pscustomobject]@{ required=$executionContractRequired; ok=($executionContractOk-and$decisionGuidanceOk); status=if($executionResolutionFailed){'resolver_failed'}elseif($executionResolutionNoContract){'no_contract'}elseif($executionContractRequired){'guarded'}else{'not_required'}; proposedWorkId=$ProposedWorkId; code=if($executionResolutionFailed){$executionResolutionFailureCode}elseif($executionContractGuard){[string]$executionContractGuard.code}else{''}; currentFocusId=if($executionContractGuard){[string]$executionContractGuard.currentFocusId}else{''}; decisionGuidanceRequired=$decisionGuidanceRequired; decisionGuidanceOk=$decisionGuidanceOk; decisionGuidanceCode=$decisionGuidanceCode; decisionGuidance=@($decisionGuidance) }
  intentResolution = [pscustomobject]@{ required=$intentReceiptRequired; ok=$intentReceiptOk; code=$intentReceiptCode; missing=@($intentReceiptMissing); preflightDiagnosticOnly=$true; guard='A global cognitive-preflight can suggest a candidate but cannot authorize product work.' }
  guard = 'High-risk work must pass a fresh query-matched cognitive preflight; a current task-scoped intent receipt is the product authorization when required; engineering mutation/completion must also pass evidence and decision grounding; a current execution contract blocks unreconciled or superseded work.'
  nextAction = if ($executionResolutionFailed) { 'Repair or re-run execution-contract resolution before mutation.' } elseif (@($violations) -contains 'intent-resolution-receipt') { 'Resolve the current product outcome and bind an IntentContractJson receipt to this task before structural mutation.' } elseif (@($violations) -contains 'execution-contract-guard') { 'Reconcile the latest user instruction and assistant commitment, then update the execution contract before mutation.' } elseif (@($violations) -contains 'engineering-decision-gate') { 'Create a valid task-scoped engineering decision with evidence, options, execution contracts, acceptance, and risk, then re-run cognitive-enforce.' } elseif ($violations.Count -gt 0) { 'Run scripts\cognitive-preflight.ps1 for the current command, then re-run cognitive-enforce before action.' } else { 'Proceed while applying mustPreserve and driftGuards; stop on failed engineering acceptance and run runtime-drift-checkpoint before major steps.' }
  path = $outPath
}

Write-JsonUtf8NoBom $outPath $result 10
$typedMemoryTrial = [pscustomobject]@{
  attempted = $false
  ok = $true
  status = 'not_requested'
  verdict = 'inconclusive'
  code = 'TYPED_MEMORY_TRIAL_NOT_A_MEMORY_GATE_PHASE'
  rawPromptStored = $false
  rawSummaryStored = $false
  rawTranscriptStored = $false
  memoryBodyStored = $false
}
if ($Phase -in @('BeforeMutation','BeforeCompletion')) {
  if ($result.ok -ne $true) {
    $typedMemoryTrial = [pscustomobject]@{
      attempted = $true
      ok = $true
      status = 'withheld'
      verdict = 'inconclusive'
      code = 'TYPED_MEMORY_TRIAL_GUARD_WITHHELD'
      rawPromptStored = $false
      rawSummaryStored = $false
      rawTranscriptStored = $false
      memoryBodyStored = $false
    }
  } else {
    try {
      $trialScript = Join-Path $PSScriptRoot 'typed-memory-trial.ps1'
      $trialRaw = @(& $trialScript -Action Start -TaskId $TaskId -TaskInstanceId $memoryTaskInstanceId -WorkspaceKey $workspaceKey -SessionKey $hostSessionKey -CognitiveEvidencePath $outPath -NoExit -Json 2>$null)
      $trialValue = ConvertFrom-SuperBrainJsonOutput (($trialRaw | ForEach-Object { [string]$_ }) -join "`n") 'cognitive enforce typed memory trial'
      $typedMemoryTrial = $trialValue
      $typedMemoryTrial | Add-Member -NotePropertyName attempted -NotePropertyValue $true -Force
    } catch {
      $typedMemoryTrial = [pscustomobject]@{
        attempted = $true
        ok = $true
        status = 'inconclusive'
        verdict = 'inconclusive'
        code = 'TYPED_MEMORY_TRIAL_START_UNAVAILABLE'
        rawPromptStored = $false
        rawSummaryStored = $false
        rawTranscriptStored = $false
        memoryBodyStored = $false
      }
    }
  }
}
$result | Add-Member -NotePropertyName typedMemoryTrial -NotePropertyValue $typedMemoryTrial -Force
Write-JsonUtf8NoBom $outPath $result 10
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "COGNITIVE_ENFORCE ok=$($result.ok) required=$($result.required) intent=$($result.intent) violations=$(@($result.violations).Count) path=$outPath" }
if (-not $result.ok) { exit 1 }
exit 0
