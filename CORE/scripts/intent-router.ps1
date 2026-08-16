[CmdletBinding()]
param(
  [Parameter(Position=0,ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [string]$Workspace = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'routing-kernel.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$inputText = (($Text -join ' ').Trim())
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = (Get-Location).Path }
$routeSignals = Get-SuperBrainRouteSignals $inputText
$normalized = [string]$routeSignals.text
$intent = 'general_task'
$confidence = 0.55
$recommendedAction = 'Use smart-next.ps1 or ask for the next concrete task.'
$dispatchHints = @()
$commands = @('scripts\smart-next.ps1 -Json')
$workflowPreferenceTriggers = @()
try {
  $memoryPolicy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($memoryPolicy.retrieval.PSObject.Properties['workflowPreferenceTriggers']) {
    $workflowPreferenceTriggers = @($memoryPolicy.retrieval.workflowPreferenceTriggers)
  }
} catch {}

function U([int[]]$Codes) {
  return -join ($Codes | ForEach-Object { [char]$_ })
}

function New-CapabilityRouteReceipt([object]$CapabilityRoute) {
  $nativeReceipts = if ($CapabilityRoute -and $CapabilityRoute.PSObject.Properties['nativeRouteReceipts']) { @($CapabilityRoute.nativeRouteReceipts) } else { @() }
  $provenanceHashes = New-Object System.Collections.ArrayList
  $parityHashes = New-Object System.Collections.ArrayList
  $nativeIds = New-Object System.Collections.ArrayList
  $contractIds = New-Object System.Collections.ArrayList
  foreach ($nativeReceipt in @($nativeReceipts)) {
    if (-not $nativeReceipt) { continue }
    $capabilityId = [string]$nativeReceipt.capabilityId
    $contractId = [string]$nativeReceipt.contractId
    if ([string]::IsNullOrWhiteSpace($capabilityId) -or [string]::IsNullOrWhiteSpace($contractId)) { continue }
    [void]$nativeIds.Add($capabilityId)
    [void]$contractIds.Add($contractId)
    $capability = @($CapabilityRoute.capabilities | Where-Object { [string]$_.capabilityId -eq $capabilityId } | Select-Object -First 1)
    $provenanceHash = if (@($capability).Count -eq 1) { [string]$capability[0].provenanceHash } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($provenanceHash)) {
      [void]$provenanceHashes.Add([pscustomobject]@{ capabilityId=$capabilityId; provenanceHash=$provenanceHash })
    }
    $parityHash = [string]$nativeReceipt.parityHash
    if ([string]::IsNullOrWhiteSpace($parityHash)) {
      $parityPayload = [ordered]@{
        contractId = $contractId
        entry = [string]$nativeReceipt.entry
        executionOwner = [string]$nativeReceipt.executionOwner
        sourceUse = [string]$nativeReceipt.sourceUse
        requiredReceipts = @($nativeReceipt.requiredReceipts)
        verification = @($nativeReceipt.verification)
      }
      $parityHash = Get-SuperBrainStableHash (($parityPayload | ConvertTo-Json -Depth 8 -Compress)) 64
    }
    [void]$parityHashes.Add([pscustomobject]@{
      capabilityId = $capabilityId
      contractId = $contractId
      parityHash = $parityHash
    })
  }
  # This PowerShell router is an external compatibility producer, not the
  # package-owned shadow evaluator.  It must never claim that an upstream-ish
  # route has passed the native activation experiment.  H7 recalculates the
  # actual native route and its hash-bound gate from the package registry.
  $hasExternalSelection = @($contractIds).Count -gt 0
  $shadowGateBody = [ordered]@{
    activationAllowed = $false
    code = if ($hasExternalSelection) { 'H7_CAPABILITY_ACTIVATION_SHADOW_WITHHELD' } else { 'H7_CAPABILITY_SHADOW_NOT_APPLICABLE' }
    evaluationPayloadHash = ''
    nonAuthorizing = $true
    rawPromptStored = $false
    rawTranscriptStored = $false
    schema = 'super-brain.capability-shadow-gate.v1'
    selectedContractCount = if ($hasExternalSelection) { @($contractIds | Select-Object -Unique).Count } else { 0 }
    state = if ($hasExternalSelection) { 'withheld' } else { 'not_applicable' }
  }
  $shadowGate = [pscustomobject]@{
    schema = [string]$shadowGateBody.schema
    state = [string]$shadowGateBody.state
    code = [string]$shadowGateBody.code
    evaluationPayloadHash = [string]$shadowGateBody.evaluationPayloadHash
    selectedContractCount = [int]$shadowGateBody.selectedContractCount
    activationAllowed = $false
    nonAuthorizing = $true
    rawPromptStored = $false
    rawTranscriptStored = $false
    payloadHash = Get-SuperBrainStableHash (($shadowGateBody | ConvertTo-Json -Depth 6 -Compress)) 64
  }
  $routePayload = [ordered]@{
    schema = 'super-brain.capability-route-receipt.v1'
    state = if ($hasExternalSelection) { 'withheld' } else { 'not_applicable' }
    code = if ($hasExternalSelection) { 'CAPABILITY_ROUTE_EVALUATION_WITHHELD' } else { 'CAPABILITY_ROUTE_NOT_APPLICABLE' }
    selectionPolicy = if ($CapabilityRoute) { [string]$CapabilityRoute.selectionPolicy } else { '' }
    selectedNativeCapabilityIds = @()
    nativeContractIds = @()
    provenanceHashes = @()
    parityHashes = @()
    shadowGate = $shadowGate
    nonAuthorizing = $true
    rawPromptStored = $false
    rawTranscriptStored = $false
    sourcePathsOmitted = $true
  }
  return [pscustomobject]@{
    schema = [string]$routePayload.schema
    state = [string]$routePayload.state
    code = [string]$routePayload.code
    selectedNativeCapabilityIds = @($routePayload.selectedNativeCapabilityIds)
    nativeContractIds = @($routePayload.nativeContractIds)
    provenanceHashes = @($routePayload.provenanceHashes)
    parityHashes = @($routePayload.parityHashes)
    routeHash = Get-SuperBrainStableHash (($routePayload | ConvertTo-Json -Depth 10 -Compress)) 64
    nonAuthorizing = $true
    rawPromptStored = $false
    rawTranscriptStored = $false
    sourcePathsOmitted = $true
    shadowGate = $shadowGate
  }
}

$zhContinue = U @(32487,32493)
$zhStatus = U @(29366,24577)
$zhTask = U @(20219,21153)
$zhNowWhere = U @(29616,22312,20570,21040,21738,20102)
$zhLast = U @(19978,27425)
$zhBefore = U @(20043,21069)
$zhAnotherSession = U @(21478,19968,20010,20250,35805)
$zhNormal = U @(27491,24120)
$zhFix = U @(20462)
$zhFail = U @(22833,36133)
$zhFeature = U @(21151,33021)
$zhOptimize = U @(20248,21270)
$zhMemory = U @(35760,24518)
$zhRemember = U @(35760,20303)
$zhStillRemember = U @(36824,35760,24471)
$zhPreference = U @(20559,22909)
$zhSearch = U @(25628,32034)
$zhTeam = U @(22242,38431)
$zhReview = U @(23457,26597)
$zhOpen = U @(25171,24320)
$zhStart = U @(24320,21551)
$zhConnect = U @(36830,25509)
$zhConnect2 = U @(25509,20837)
$zhOpenChannel = $zhStart + (U @(23376)) + 'agent' + (U @(36890,36947))
$zhOpenChannel2 = $zhOpen + (U @(23376)) + 'agent' + (U @(36890,36947))
$zhConnectChannel = $zhConnect + (U @(23376)) + 'agent' + (U @(36890,36947))
$zhConnectChannel2 = $zhConnect2 + (U @(23376)) + 'agent' + (U @(36890,36947))
$zhSendTo = U @(21457,36865,20449,24687)
$zhSendMsg = U @(21457,28040,24687)
$zhReadChannelReply = U @(35835,21462)
$zhCloseChannel = U @(20851,38381)
$zhChannel = U @(36890,36947)
$zhSubAgent = (U @(23376)) + 'agent'
$zhTo = U @(21521)
$zhGive = U @(32473)
$zhWhatIs = U @(20160,20040,26159)
$zhWhich = U @(21738,20123)
$zhDesignPattern = U @(35774,35745,27169,24335)
$zhMeaning = U @(33521,25991,26159,20160,20040,24847,24605)
$zhSuperBrain = U @(36229,32423,22823,33041)
$zhInstall = U @(23433,35013)
$zhRefresh = U @(21047,26032)
$zhRefreshSuperBrain = $zhRefresh + $zhSuperBrain
$zhProxyAgent = U @(23376,20195,29702)
$zhExecute = U @(25191,34892)
$zhAudit = U @(23457,35745)
$zhVerify = U @(39564,35777)
$zhModify = U @(20462,25913)
$zhTestWord = U @(27979,35797)
$zhInvestigate = U @(35843,26597)
$zhEvidence = U @(35777,25454)
$zhReview2 = U @(23457,26680)

function Test-Any([string[]]$Needles) {
  foreach ($needle in $Needles) {
    if ($normalized.Contains($needle.ToLowerInvariant())) { return $true }
  }
  return $false
}

function Test-All([string[]]$Needles) {
  foreach ($needle in $Needles) {
    if (-not $normalized.Contains($needle.ToLowerInvariant())) { return $false }
  }
  return $true
}

function Normalize-WorkflowText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $form = $Value.Normalize([System.Text.NormalizationForm]::FormKC).ToLowerInvariant()
  return [regex]::Replace($form, '[\s\p{P}\p{S}]+', '')
}

function Test-WorkflowPreferenceScope([object]$Candidate) {
  $scope = [string]$Candidate.scope
  if ([string]::IsNullOrWhiteSpace($scope)) { return $true }
  $context = ($Workspace + ' ' + $inputText).ToLowerInvariant()
  foreach ($term in @($scope -split '[/,;|]')) {
    $value = ([string]$term).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($value) -and $context.Contains($value)) { return $true }
  }
  return $false
}

$workflowPreferenceMatch = $null
$workflowPreferenceMatchedPhrase = ''
$normalizedWorkflowInput = Normalize-WorkflowText $inputText
foreach ($candidate in @($workflowPreferenceTriggers)) {
  if (-not (Test-WorkflowPreferenceScope $candidate)) { continue }
  foreach ($phrase in @($candidate.phrases)) {
    $value = [string]$phrase
    $normalizedPhrase = Normalize-WorkflowText $value
    if (-not [string]::IsNullOrWhiteSpace($normalizedPhrase) -and $normalizedWorkflowInput.Contains($normalizedPhrase)) {
      $workflowPreferenceMatch = $candidate
      $workflowPreferenceMatchedPhrase = $value
      break
    }
  }
  if ($null -ne $workflowPreferenceMatch) { break }
}
$hasWorkflowPreferenceRecall = ($null -ne $workflowPreferenceMatch)
$workflowPreference = $null

$isUserAgentQuestion = (
  $normalized.Contains('user agent') -and
  (Test-Any @('what is','what''s','meaning','explain',$zhWhatIs))
)
$isAgentMeaningQuestion = (
  $normalized.Contains('agent') -and
  (Test-Any @('what is agent','what does agent mean','meaning of agent',$zhMeaning))
)
$isAgentConceptQuestion = (
  $normalized.Contains('agent') -and
  (Test-Any @('design pattern','design patterns','pattern','patterns','architecture','concept','concepts','what is','what are',$zhWhatIs,$zhWhich,$zhDesignPattern))
)
$hasAgentBridgeIntent = [bool]$routeSignals.agentBridgeIntent
$hasHistoricalReference = Test-Any @(
  'previous task','last task','previous session','last session','last time','last-time','another session',
  'remember last','remember previous',
  $zhLast,$zhBefore,$zhAnotherSession
)
$hasHistoricalContinue = (
  ((Test-Any @($zhContinue,'continue','resume')) -and $hasHistoricalReference) -or
  $hasHistoricalReference
)
$hasCurrentTaskStatus = (
  (Test-Any @('task status','current progress','where are we','where are we at','next step',($zhTask + $zhStatus),$zhNowWhere)) -or
  ($normalized.Contains($zhTask) -and $normalized.Contains($zhStatus))
)
$hasSystemStatus = [bool]$routeSignals.systemStatusIntent
$hasSecretMemoryWrite = (
  (Test-Any @('remember',$zhRemember)) -and
  (Test-Any @('api key','apikey','token','password','secret','sk-'))
)
$hasPreferenceMemoryWrite = (
  (Test-Any @('remember this preference','remember preference',$zhRemember)) -and
  (Test-Any @('preference',$zhPreference))
)
$hasComplexOrc = (
  (Test-Any @('multi-step','migration','migrate','tests','test plan')) -and
  (Test-Any @('plan','app','release','migration','migrate'))
)
$hasMaintenanceHotRefresh = (
  (Test-Any @('hot-refresh','hot refresh',$zhRefreshSuperBrain)) -or
  ((Test-Any @('refresh',$zhRefresh)) -and (Test-Any @('super brain','superbrain',$zhSuperBrain,'install',$zhInstall)))
)
$hasSingleAgentWorkflow = (
  -not $hasAgentBridgeIntent -and
  (Test-Any @('subagent','sub-agent','executor subagent','reviewer subagent','verifier subagent',$zhProxyAgent,($zhExecute + $zhProxyAgent),($zhAudit + $zhProxyAgent),($zhVerify + $zhProxyAgent))) -and
  (Test-Any @('modify','edit','change','test','run tests','verify','verification','audit','review','inspect','investigate','evidence',$zhModify,$zhAudit,$zhReview2,$zhVerify,$zhTestWord,$zhInvestigate,$zhEvidence))
)
$hasExplicitTeamReview = Test-Any @($zhTeam,$zhReview,'team','cluster','review','audit')
$isGenericAgentRequest = (
  $routeSignals.genericAgent -and -not $hasAgentBridgeIntent -and -not $hasSingleAgentWorkflow -and -not $hasExplicitTeamReview -and
  -not $routeSignals.strongAction -and -not $routeSignals.materialRisk -and -not $routeSignals.continuitySignal
)

if ($isUserAgentQuestion -or $isAgentMeaningQuestion -or ($isAgentConceptQuestion -and -not $hasAgentBridgeIntent) -or $isGenericAgentRequest) {
  $intent = 'general_task'
  $confidence = 0.88
  $recommendedAction = 'Answer the agent/user-agent concept question directly; do not route to team or Agent Bridge.'
  $commands = @('scripts\smart-next.ps1 -Json')
  $dispatchHints = @('negative_agent_trigger')
} elseif ($hasSingleAgentWorkflow) {
  $intent = 'single_agent_subagent_workflow'
  $confidence = 0.9
  $recommendedAction = 'Use single-agent internal subagent workflow: controller task card, executor/reviewer cards, evidence closeout; do not use Agent Bridge channel.'
  $commands = @('references\single-agent-subagent-workflow.md','references\orc-routing.md')
  $dispatchHints = @('single_agent_subagent_workflow','result_card','audit_card','no_channel_mode')
} elseif ($hasAgentBridgeIntent) {
  $intent = 'agent_bridge_channel'
  $confidence = 0.92
  $recommendedAction = 'Use agent-bridge-channel short-command protocol. Open means persistent target-mode wait, not completion; Close only on explicit close wording.'
  $commands = @('scripts\agent-bridge-channel.ps1 -Action Open -Json','scripts\agent-bridge-channel.ps1 -Action WaitConnect -Json','scripts\agent-bridge-channel.ps1 -Action WaitInbox -Json','scripts\agent-bridge-channel.ps1 -Action Connect -Json','scripts\agent-bridge-channel.ps1 -Action SendAndWait -Json')
  $dispatchHints = @('agent_bridge_channel','bounded_wait','no_auto_close')
} elseif ($hasSecretMemoryWrite) {
  $intent = 'privacy_memory_gate'
  $confidence = 0.94
  $recommendedAction = 'Apply memory privacy gate; do not store secrets or raw credentials.'
  $commands = @('references\memory-governance.md')
  $dispatchHints = @('privacy_memory_gate','no_secret_storage')
} elseif ($hasPreferenceMemoryWrite) {
  $intent = 'memory_write_candidate'
  $confidence = 0.88
  $recommendedAction = 'Treat as a compact durable preference candidate after conflict and privacy checks.'
  $commands = @('references\memory-governance.md')
  $dispatchHints = @('memory_write_candidate','compact_preference')
} elseif ($hasWorkflowPreferenceRecall) {
  $intent = 'workflow_preference_recall'
  $confidence = 0.98
  $preferenceId = [string]$workflowPreferenceMatch.id
  $recallQuery = [string]$workflowPreferenceMatch.query
  $decisionKey = [string]$workflowPreferenceMatch.decisionKey
  $workflowPreference = [pscustomobject]@{
    id = $preferenceId
    decisionKey = $decisionKey
    query = $recallQuery
    scope = [string]$workflowPreferenceMatch.scope
    matchedPhrase = $workflowPreferenceMatchedPhrase
    normalizedInput = $normalizedWorkflowInput
  }
  $recommendedAction = "Perform one bounded memory:auto canonical lookup for workflow preference '$preferenceId' before answering. Use only the current verified record for '$decisionKey'; output Summary, Description, and Commit button text only; do not substitute generic Git commands, apology text, or unverified claims."
  $commands = @(
    'references\memory-governance.md',
    "scripts\decision-search.ps1 -Key `"$decisionKey`" -CurrentOnly -Relation decides -TopK 1 -MaxTokens 400 -Json"
  )
  $dispatchHints = @('workflow_preference_recall','current_verified_canonical_only','no_generic_fallback')
} elseif ($hasHistoricalContinue) {
  $intent = 'historical_recovery'
  $confidence = 0.9
  $recommendedAction = 'Recover prior-session task state from status recovery and checkpoint paths before deep recall.'
  $commands = @('references\status-recovery.md','scripts\auto-continuation.ps1 -Json')
  $dispatchHints = @('historical_recovery','checkpoint_first')
} elseif ([string]::IsNullOrWhiteSpace($normalized) -or (Test-Any @($zhContinue,'continue','resume'))) {
  $intent = 'continue'
  $confidence = 0.9
  $recommendedAction = 'Resume from current visible context, auto-continuation, and dashboard state.'
  $commands = @('scripts\auto-continuation.ps1 -Json','scripts\super-brain-dashboard.ps1 -Json')
  $dispatchHints = @('simple_direct')
} elseif ($hasCurrentTaskStatus) {
  $intent = 'current_task_status'
  $confidence = 0.9
  $recommendedAction = 'Report current task progress from visible context/checkpoints; do not run system health.'
  $commands = @('references\status-recovery.md')
  $dispatchHints = @('current_task_status','no_system_health_dump')
} elseif ($hasSystemStatus) {
  $intent = 'status'
  $confidence = 0.88
  $recommendedAction = 'Read health-summary for human status, then dashboard for full machine state.'
  $commands = @('scripts\health-summary.ps1 -Json','scripts\super-brain-dashboard.ps1 -Json')
} elseif ($hasMaintenanceHotRefresh) {
  $intent = 'maintenance_hot_refresh'
  $confidence = 0.9
  $recommendedAction = 'Use install-refresh maintenance route with approval and rollback requirements.'
  $commands = @('references\install-refresh.md','scripts\hot-refresh-skills.ps1 -ReportOnly -Json')
  $dispatchHints = @('maintenance_hot_refresh','rollback_required')
} elseif ((Test-Any @($zhFeature,$zhOptimize,'feature','implement','add','optimize')) -or $routeSignals.featureIntentSignal -or $routeSignals.optimizationAction -or ($routeSignals.structuralChangeSignal -and $routeSignals.changeActionSignal)) {
   $intent = 'add_or_optimize_feature'
   $confidence = 0.76
   $recommendedAction = 'Run the collaborative intent gate first: identify the real outcome, product role, existing flow, non-goals, structural impact, autonomy tier, and smallest useful verification before implementation.'
   $commands = @('references\collaborative-intent.md','scripts\why-plan.ps1 -Goal "..." -Json')
   $dispatchHints = @('collaborative_intent','product_coherence_gate','bounded_autonomy','risk_based_verification')
} elseif ($hasComplexOrc) {
  $intent = 'orc_complex_routing'
  $confidence = 0.87
  $recommendedAction = 'Use ORC complexity routing with the smallest skill/tool set and explicit verification plan.'
  $commands = @('references\orc-routing.md','capabilities.json')
  $dispatchHints = @('orc_complex_routing','verification_required')
} elseif (Test-Any @($zhFix,$zhFail,'bug','fix','failed','error')) {
  $intent = 'fix_bug'
  $confidence = 0.78
  $recommendedAction = 'Diagnose, patch root cause, then run targeted verification.'
  $dispatchHints = @('verification_required','logic_safety_required')
} elseif (Test-Any @('git status','git diff','repository readiness','privacy preflight','仓库状态','隐私检查','发布前检查')) {
  $intent = 'repository_readiness'
  $confidence = 0.9
  $recommendedAction = 'Run the direct Git repository and privacy preflight; publish only from the current source tree.'
  $commands = @('scripts\release-readiness.ps1 -Json')
  $dispatchHints = @('repository_readiness','privacy_preflight','verification_required')
} elseif (Test-Any @($zhMemory,$zhSearch,$zhStillRemember,'memory','recall','search','do you remember','what do you remember')) {
  $intent = 'memory_recall'
  $confidence = 0.82
  $recommendedAction = 'Use recall-search and relevant memory quality checks before changing state.'
  $commands = @('scripts\recall-search.ps1 -Query "..." -Json','scripts\memory-health.ps1 -Json')
} elseif ($routeSignals.browserTaskSignal) {
  $intent = 'browser_automation'
  $confidence = 0.92
  if ($routeSignals.browserRoute -eq 'browser-act') {
    $recommendedAction = "Use browser-act only because routing reason=$($routeSignals.browserRouteReason); keep the browser decision visible in the task state."
    $commands = @('skills\browser-act\SKILL.md')
    $dispatchHints = @('browser_automation','browser_act_allowed',$routeSignals.browserRouteReason)
  } else {
    $recommendedAction = 'Use Playwright for normal browser automation. Load browser-act only after an explicit request or a verified Playwright reliability failure.'
    $commands = @('skills\playwright\SKILL.md')
    $dispatchHints = @('browser_automation','playwright_default')
  }
} elseif ($hasExplicitTeamReview) {
  $intent = 'team_or_review'
  $confidence = 0.86
  $recommendedAction = 'Use dispatch learning, trigger simulation, and review gate before accepting team findings.'
  $commands = @('scripts\dispatch-learning.ps1 -Json','scripts\agent-scorecard.ps1 -Json','scripts\team-task-review-gate.ps1 -Json')
  $dispatchHints = @('logic_safety_required','verification_required')
}

# Every non-trivial request receives one bounded automatic lookup of absorbed
# Super Brain capabilities after its operation intent is known.  This is not a
# user-facing skill menu: only high-confidence, compact cards are returned and
# they never grant authority to mutate state or override the H7 contract.
$capabilityRoute = $null
$capabilityRouteWithheld = $false
$capabilityRouteCode = ''
$nativeCapabilityReceipts = @()
try {
  $capabilityRouteRaw = @(& (Join-Path $PSScriptRoot 'absorbed-capability-route.ps1') -Text $inputText -Intent $intent -TopK 4 -Json 2>$null)
  if (-not $capabilityRouteRaw -or $LASTEXITCODE -ne 0) { throw 'CAPABILITY_ROUTE_UNAVAILABLE' }
  $capabilityRoute = (($capabilityRouteRaw -join "`n") | ConvertFrom-Json -ErrorAction Stop)
} catch {
  $capabilityRoute = [pscustomobject]@{
    ok = $false
    state = 'withheld'
    code = 'CAPABILITY_ROUTE_UNAVAILABLE'
    selected = $false
    reason = 'capability_route_unavailable'
    capabilities = @()
    withheldCapabilities = @()
    repairAction = 'Repair the absorbed capability route or map, then retry the same intent.'
    error = $_.Exception.Message
  }
}
if ($capabilityRoute -and [string]$capabilityRoute.state -eq 'withheld') {
  $capabilityRouteWithheld = $true
  $capabilityRouteCode = if([string]::IsNullOrWhiteSpace([string]$capabilityRoute.code)){'CAPABILITY_ROUTE_WITHHELD'}else{[string]$capabilityRoute.code}
  $dispatchHints += 'absorbed_capability_route_withheld'
  $dispatchHints += 'no_capability_route_fallback'
  $commands += 'scripts\absorbed-capability-route.ps1 -Text "..." -Intent "..." -Json'
  $recommendedAction += ' The absorbed capability layer is withheld; repair its declared map or provenance before loading a cold source. H7 and the current task contract remain independent.'
} elseif ($capabilityRoute -and $capabilityRoute.selected -eq $true) {
  $dispatchHints += 'absorbed_capability_route'
  $dispatchHints += 'capability_cards_non_authorizing'
  $commands += 'scripts\absorbed-capability-route.ps1 -Text "..." -Intent "..." -Json'
  $recommendedAction += ' Apply the selected Super Brain-owned capability cards only at their stated phase; preserve current authorization, project evidence, and verification gates.'
  $nativeCapabilityReceipts = @($capabilityRoute.nativeRouteReceipts)
  if (@($nativeCapabilityReceipts).Count -gt 0) {
    $dispatchHints += 'native_capability_contract_receipts'
    $recommendedAction += ' Execute each native capability contract from its route receipt; retained upstream sources are bounded provenance/cold references, never direct host-skill routes.'
  }
  $policyCards = @($capabilityRoute.capabilities | Where-Object { ([string]$_.externalActionPolicy -ne 'none') -or ([string]$_.projectMutationPolicy -ne 'none') })
  if (@($policyCards).Count -gt 0) {
    $dispatchHints += 'capability_policy_requires_authorization'
    $recommendedAction += ' Policy-bearing cards can only produce proposals until the existing project/external authorization guards are satisfied; a card never authorizes a mutation.'
  }
}

$capabilityRouteReceipt = New-CapabilityRouteReceipt $capabilityRoute

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  input = $inputText
  workspace = $Workspace
  intent = $intent
  confidence = $confidence
  recommendedAction = $recommendedAction
  dispatchHints = @($dispatchHints)
  commands = @($commands)
  workflowPreference = $workflowPreference
  capabilityRoute = $capabilityRoute
  capabilityRouteWithheld = [bool]$capabilityRouteWithheld
  capabilityRouteCode = $capabilityRouteCode
  absorbedCapabilities = if ($capabilityRoute) { @($capabilityRoute.capabilities) } else { @() }
  nativeCapabilityReceipts = @($nativeCapabilityReceipts)
  capabilityRouteReceipt = $capabilityRouteReceipt
  browserTaskSignal = [bool]$routeSignals.browserTaskSignal
  browserRoute = [string]$routeSignals.browserRoute
  browserRouteReason = [string]$routeSignals.browserRouteReason
  browserFallbackAllowed = ([string]$routeSignals.browserRoute -eq 'browser-act')
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "INTENT_ROUTER intent=$intent confidence=$confidence action=$recommendedAction" }
exit 0

