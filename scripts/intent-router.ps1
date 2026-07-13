param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [string]$Workspace = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$inputText = (($Text -join ' ').Trim())
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = (Get-Location).Path }
$normalized = $inputText.ToLowerInvariant()
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
$zhRelease = U @(21457,21253)
$zhShare = U @(20998,20139)
$zhMemory = U @(35760,24518)
$zhRemember = U @(35760,20303)
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
$hasAgentBridgeNoun = Test-Any @('agent channel','agent bridge','subagent channel',$zhChannel)
$hasAgentBridgeVerb = Test-Any @('open','connect','send','read','close',$zhOpen,$zhStart,$zhConnect,$zhConnect2,$zhSendTo,$zhSendMsg,$zhReadChannelReply,$zhCloseChannel)
$hasAgentBridgeIntent = (
  (Test-Any @($zhOpenChannel,$zhOpenChannel2,$zhConnectChannel,$zhConnectChannel2,'open subagent channel','connect subagent channel','agent bridge channel')) -or
  ($normalized.Contains('agent') -and $hasAgentBridgeNoun -and $hasAgentBridgeVerb) -or
  (($normalized.Contains($zhTo) -or $normalized.Contains($zhGive)) -and (Test-Any @($zhSendTo,$zhSendMsg)) -and (Test-Any @($zhSubAgent,'codex','agent'))) -or
  (($normalized.Contains($zhReadChannelReply) -or $normalized.Contains($zhCloseChannel)) -and $normalized.Contains($zhChannel))
)
$hasHistoricalReference = Test-Any @(
  'previous task','last task','previous session','last session','last time','last-time','another session',
  'remember last','remember previous','do you remember',
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
$hasSystemStatus = Test-Any @('super brain status','g1 status','system status','health','version','dashboard','overall','ready')
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

if ($isUserAgentQuestion -or $isAgentMeaningQuestion -or ($isAgentConceptQuestion -and -not $hasAgentBridgeIntent)) {
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
  $recommendedAction = "Perform one bounded memory:auto canonical lookup for workflow preference '$preferenceId' before answering. Use only the current verified record for '$decisionKey'; preserve its response format and do not substitute generic Git commands."
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
} elseif ($hasSystemStatus -or (Test-Any @($zhStatus,$zhNormal,'status'))) {
  $intent = 'status'
  $confidence = 0.88
  $recommendedAction = 'Read health-summary for human status, then dashboard for full machine state.'
  $commands = @('scripts\health-summary.ps1 -Json','scripts\super-brain-dashboard.ps1 -Json')
} elseif ($hasComplexOrc) {
  $intent = 'orc_complex_routing'
  $confidence = 0.87
  $recommendedAction = 'Use ORC complexity routing with the smallest skill/tool set and explicit verification plan.'
  $commands = @('references\orc-routing.md','capabilities.json')
  $dispatchHints = @('orc_complex_routing','verification_required')
} elseif ($hasMaintenanceHotRefresh) {
  $intent = 'maintenance_hot_refresh'
  $confidence = 0.9
  $recommendedAction = 'Use install-refresh maintenance route with approval and rollback requirements.'
  $commands = @('references\install-refresh.md','scripts\hot-refresh-skills.ps1 -ReportOnly -Json')
  $dispatchHints = @('maintenance_hot_refresh','rollback_required')
} elseif (Test-Any @($zhFix,$zhFail,'bug','fix','failed','error')) {
  $intent = 'fix_bug'
  $confidence = 0.78
  $recommendedAction = 'Diagnose, patch root cause, then run targeted verification.'
  $dispatchHints = @('verification_required','logic_safety_required')
} elseif (Test-Any @($zhFeature,$zhOptimize,'feature','implement','add','optimize')) {
  $intent = 'add_or_optimize_feature'
  $confidence = 0.76
  $recommendedAction = 'Plan scope, implement focused changes, then verify through package checks.'
  $dispatchHints = @('verification_required')
} elseif (Test-Any @($zhRelease,$zhShare,'release','share','package')) {
  $intent = 'release'
  $confidence = 0.9
  $recommendedAction = 'Run release readiness, then release-share if safe.'
  $commands = @('scripts\release-readiness.ps1 -Json','scripts\release-share.ps1')
  $dispatchHints = @('release','share','verification_required')
} elseif (Test-Any @($zhMemory,$zhSearch,'memory','recall','search')) {
  $intent = 'memory_recall'
  $confidence = 0.82
  $recommendedAction = 'Use recall-search and relevant memory quality checks before changing state.'
  $commands = @('scripts\recall-search.ps1 -Query "..." -Json','scripts\memory-health.ps1 -Json')
} elseif (Test-Any @($zhTeam,$zhReview,'agent','team','cluster','review')) {
  $intent = 'team_or_review'
  $confidence = 0.86
  $recommendedAction = 'Use dispatch learning, trigger simulation, and review gate before accepting team findings.'
  $commands = @('scripts\dispatch-learning.ps1 -Json','scripts\agent-scorecard.ps1 -Json','scripts\team-task-review-gate.ps1 -Json')
  $dispatchHints = @('logic_safety_required','verification_required')
}

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
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "INTENT_ROUTER intent=$intent confidence=$confidence action=$recommendedAction" }
exit 0
