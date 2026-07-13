param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [string]$Workspace = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = (Get-Location).Path }

function Convert-ToolJson([object[]]$Output, [string]$ScriptName) {
  $jsonStart = -1
  for ($index = 0; $index -lt $Output.Count; $index++) {
    if ([string]$Output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
  }
  if ($jsonStart -lt 0) { return [pscustomobject]@{ ok=$false; error="No JSON from $ScriptName" } }
  return ((@($Output[$jsonStart..($Output.Count - 1)]) -join "`n") | ConvertFrom-Json)
}
function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
function Test-EngineeringJudgmentIntent([string]$IntentName,[string]$Value) {
  if ($IntentName -eq 'add_or_optimize_feature') { return $true }
  $valueLower = $Value.ToLowerInvariant()
  foreach ($term in @('fix','debug','repair','optimize','optimization','architecture','architect','root cause','tradeoff','trade-off','best option','optimal','performance','bottleneck','regression','refactor','migration','failure analysis')) {
    if ($valueLower.Contains($term)) { return $true }
  }
  foreach ($term in @((U @(20462,22797)),(U @(20248,21270)),(U @(26550,26500)),(U @(26681,22240)),(U @(26368,20248)),(U @(26368,20339)),(U @(24615,33021)),(U @(37325,26500)),(U @(25925,38556)),(U @(35774,35745)),(U @(20915,31574)))) {
    if ($Value.Contains($term)) { return $true }
  }
  return $false
}

$inputText = (($Text -join ' ').Trim())
$intent = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'intent-router.ps1') -Text $inputText -Workspace $Workspace -Json 6>$null) 'intent-router.ps1'
$capabilityMap = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Query $inputText -TopK 12 -Json 6>$null) 'skill-capability-map.ps1'
$ruleCapabilities = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Query $inputText -Category 'rule' -TopK 4 -Json 6>$null) 'skill-capability-map.ps1'
$continuation = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'auto-continuation.ps1') -Json 6>$null) 'auto-continuation.ps1'
$dashboardMode = if ($intent.intent -eq 'team_or_review') { 'Team' } elseif ($intent.intent -in @('status','release')) { 'Full' } else { 'Light' }
$dashboard = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') -Mode $dashboardMode -Json 6>$null) 'super-brain-dashboard.ps1'
$dispatchLearning = [pscustomobject]@{ ok=$true; recommendations=@() }
if ($intent.intent -eq 'team_or_review') {
  $dispatchLearning = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'dispatch-learning.ps1') -Json 6>$null) 'dispatch-learning.ps1'
}

$nextAction = if ($continuation.nextAction) { [string]$continuation.nextAction } else { 'Ask for the next concrete user task.' }
$confidence = 0.7
$why = @('auto-continuation')
$commands = @('scripts\super-brain-dashboard.ps1 -Mode Light -Json')
$skillRoutePlan = New-Object System.Collections.ArrayList
foreach ($cap in @($ruleCapabilities.capabilities)) {
  [void]$skillRoutePlan.Add([pscustomobject]@{ name=$cap.name; category=$cap.category; role=$cap.role; score=$cap.score; applyAt=@($cap.applyAt); verification=@($cap.verification); mode='rules_as_execution_constraints_not_menu_calls' })
}
foreach ($cap in @($capabilityMap.capabilities | Where-Object { [string]$_.category -ne 'rule' })) {
  [void]$skillRoutePlan.Add([pscustomobject]@{ name=$cap.name; category=$cap.category; role=$cap.role; score=$cap.score; applyAt=@($cap.applyAt); verification=@($cap.verification); mode='orc_auto_composition_route' })
}
$engineeringCapabilityHits = @($capabilityMap.capabilities | Where-Object { [string]$_.role -eq 'engineering_decision' -and [int]$_.score -gt 0 })
$engineeringJudgmentRequired = ((Test-EngineeringJudgmentIntent ([string]$intent.intent) $inputText) -or $engineeringCapabilityHits.Count -gt 0)
$engineeringActivationReasons = @()
if ($intent.intent -eq 'add_or_optimize_feature') { $engineeringActivationReasons += 'engineering_intent' }
if ($engineeringCapabilityHits.Count -gt 0) { $engineeringActivationReasons += 'engineering_capability_match' }
if ($engineeringJudgmentRequired -and $engineeringActivationReasons.Count -eq 0) { $engineeringActivationReasons += 'engineering_language_match' }
$completionExpectedRoles = @('pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair')
$completionAuditRequested = ($inputText -match '(?i)completion\s+(skill\s+)?audit|before\s+completion')
if ($completionAuditRequested) {
  foreach ($role in $completionExpectedRoles) {
    if (@($skillRoutePlan | ForEach-Object { [string]$_.role }) -contains $role) { continue }
    $roleMap = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Role $role -TopK 1 -NoExtensions -Json 6>$null) 'skill-capability-map.ps1'
    foreach ($cap in @($roleMap.capabilities | Select-Object -First 1)) {
      [void]$skillRoutePlan.Add([pscustomobject]@{ name=$cap.name; category=$cap.category; role=$cap.role; score=$cap.score; applyAt=@($cap.applyAt); verification=@($cap.verification); mode='completion_audit_route' })
    }
  }
}
$orcComposition = [pscustomobject]@{
  enabled = $true
  source = 'skill-capability-map.ps1'
  selectionMode = 'intent_plus_capability_map_not_user_menu'
  ruleChain = @($ruleCapabilities.capabilities | ForEach-Object { [string]$_.role })
  routePlan = @($skillRoutePlan)
  guard = 'ORC should combine rule skills, verifiers, coordinators, and domain executors by intent/capability; the user should not need to name skills manually.'
}
function Add-CompositionCommand([string]$Command) {
  if (-not ($commands -contains $Command)) { $script:commands += $Command }
}
$zhOpenChannel = (U @(24320,21551)) + (U @(23376)) + 'agent' + (U @(36890,36947))
$zhOpenChannel2 = (U @(25171,24320)) + (U @(23376)) + 'agent' + (U @(36890,36947))
$zhConnectChannel = (U @(36830,25509)) + (U @(23376)) + 'agent' + (U @(36890,36947))
$zhConnectChannel2 = (U @(25509,20837)) + (U @(23376)) + 'agent' + (U @(36890,36947))
$zhSendTo = U @(21457,36865,20449,24687)
$zhSendMsg = U @(21457,28040,24687)
$zhRead = U @(35835,21462)
$zhClose = U @(20851,38381)
$zhChannel = U @(36890,36947)
$channelOpen = $inputText.Contains($zhOpenChannel) -or $inputText.Contains($zhOpenChannel2) -or ($inputText -match 'open subagent channel')
$channelConnect = $inputText.Contains($zhConnectChannel) -or $inputText.Contains($zhConnectChannel2) -or ($inputText -match 'connect subagent channel')
$channelSend = ($inputText.Contains($zhSendTo) -or $inputText.Contains($zhSendMsg) -or ($inputText -match 'send.+message'))
$channelRead = ($inputText.Contains($zhRead) -and $inputText.Contains($zhChannel)) -or ($inputText -match 'read.+channel.+reply')
$channelClose = ($inputText.Contains($zhClose) -and $inputText.Contains($zhChannel)) -or ($inputText -match 'close.+channel')

$workflowPreferenceOk = $true
$canonicalResponseContract = [pscustomobject]@{
  ok = $true
  status = 'not_applicable'
  decisionKey = ''
  content = ''
  source = ''
  tags = ''
}

if ($intent.intent -eq 'workflow_preference_recall') {
  $preference = $intent.workflowPreference
  $decisionKey = [string]$preference.decisionKey
  $decisionOutput = @(& (Join-Path $PSScriptRoot 'decision-search.ps1') -Key $decisionKey -CurrentOnly -Relation 'decides' -TopK 2 -MaxTokens 600 -Json 6>$null)
  $resolved = Convert-ToolJson $decisionOutput 'decision-search.ps1'
  $active = @(@($resolved) | Where-Object {
    $tags = [string]$_.tags
    $_.relation -eq 'decides' -and
    $tags.Contains('[CURRENT]') -and
    $tags.Contains('[VERIFIED]') -and
    -not ($_.adr -and $_.adr.superseded -eq $true)
  })
  if ($active.Count -eq 1) {
    $item = $active[0]
    $canonicalResponseContract = [pscustomobject]@{
      ok = $true
      status = 'resolved'
      decisionKey = $decisionKey
      content = [string]$item.object
      source = [string]$item.evidence
      tags = [string]$item.tags
      title = [string]$item.adr.title
      scope = [string]$item.adr.scope
    }
    $nextAction = 'Answer with canonicalResponseContract.content and the current verified task facts; do not substitute generic Git commands.'
    $why += 'workflow_preference_exact_canonical_resolved'
  } else {
    $workflowPreferenceOk = $false
    $status = if ($active.Count -eq 0) { 'canonical_missing' } else { 'canonical_conflict' }
    $canonicalResponseContract = [pscustomobject]@{
      ok = $false
      status = $status
      decisionKey = $decisionKey
      content = ''
      source = ''
      tags = ''
      activeCount = $active.Count
    }
    $nextAction = "Canonical workflow preference '$decisionKey' is $status; report the missing or conflicting evidence and do not invent a response format."
    $why += 'workflow_preference_exact_canonical_blocked'
  }
  $commands = @("scripts\decision-search.ps1 -Key `"$decisionKey`" -CurrentOnly -Relation decides -TopK 1 -MaxTokens 600 -Json")
  $confidence = 0.99
} elseif ($intent.intent -eq 'agent_bridge_channel') {
  $nextAction = 'Use the Agent Bridge channel short-command protocol; Open is a persistent target-mode wait state, not completion.'
  if ($channelOpen) {
    $commands = @(
      'scripts\cognitive-preflight.ps1 "<user command>" -Json',
      'scripts\cognitive-enforce.ps1 "<user command>" -Phase BeforeAct -Json',
      'scripts\runtime-drift-checkpoint.ps1 -Phase BeforeAct -ObservedAction "open fresh AgentBridge target channel" -Json',
      'scripts\agent-bridge-channel.ps1 -Action Open -ChannelId <new-channel-id-or-omit-to-auto-create-fresh> -FromAgentId <agentId> -Alias "子agent" -Json',
      'do not create or launch a nested agent/worker/helper; the current conversation is the sub-agent target',
      'scripts\agent-bridge-channel.ps1 -Action WaitConnect -ChannelId <channelId> -AgentId <agentId> -WaitSeconds 900 -PollIntervalSeconds 5 -Json',
      'scripts\agent-bridge-channel.ps1 -Action WaitInbox -ChannelId <channelId> -AgentId <agentId> -WaitSeconds 900 -PollIntervalSeconds 5 -Json',
      'if WaitConnect/WaitInbox returns idle_waiting_* then stay quiet; do not report blocked, do not repeat status, and wait for user/main-agent activity',
      'after replying to a received message, return to WaitInbox; do not report Goal/target completion unless explicit close is requested'
    )
    $why += 'agent_bridge_channel_open_no_auto_close'
  } elseif ($channelConnect) {
    $commands = @('scripts\agent-bridge-channel.ps1 -Action Connect -ChannelId <channelId> -OperatorAgentId <mainAgentId> -ToAgentId <targetAgentId> -Alias "子agent" -Json')
    $why += 'agent_bridge_channel_connect'
  } elseif ($channelSend) {
    $commands = @('scripts\agent-bridge-channel.ps1 -Action SendAndWait -Alias "子agent" -Summary "<message>" -WaitSeconds 60 -PollIntervalSeconds 2 -AutoAck -Json')
    $why += 'agent_bridge_channel_send'
  } elseif ($channelRead) {
    $commands = @('scripts\agent-bridge-channel.ps1 -Action WaitReply -WaitSeconds 30 -PollIntervalSeconds 2 -AutoAck -Json')
    $why += 'agent_bridge_channel_wait_reply'
  } elseif ($channelClose) {
    $commands = @('scripts\agent-bridge-channel.ps1 -Action Close -Json')
    $why += 'agent_bridge_channel_explicit_close'
  } else {
    $commands = @('scripts\agent-bridge-channel.ps1 -Action Active -Json')
    $why += 'agent_bridge_channel_status'
  }
  $confidence = 0.9
} elseif ($intent.intent -eq 'release') {
  $nextAction = 'Run release-readiness, then release-share if ready.'
    $commands = @('scripts\cognitive-preflight.ps1 "<user command>" -Json','scripts\release-readiness.ps1 -Json','scripts\release-share.ps1')
  $why += 'release_intent'
  $confidence = 0.88
} elseif ($intent.intent -eq 'status') {
  $nextAction = 'Read health-summary and full dashboard before changing state.'
  $commands = @('scripts\health-summary.ps1 -Json','scripts\super-brain-dashboard.ps1 -Mode Full -Json')
  $why += 'status_intent'
  $confidence = 0.86
} elseif ($intent.intent -eq 'team_or_review') {
  $nextAction = 'Review dispatch learning and agent scorecard before team/review-board work.'
  $commands = @('scripts\dispatch-learning.ps1 -Json','scripts\agent-scorecard.ps1 -Json','scripts\team-task-review-gate.ps1 -Json')
  $why += 'team_intent'
  $confidence = 0.84
} elseif ($intent.intent -eq 'add_or_optimize_feature') {
  $nextAction = 'Implement the focused feature with cognitive/route/causal guards, then run behavior replay, task verification, completion guard, verify-package, and CI.'
  $commands = @(
    'scripts\cognitive-preflight.ps1 "<user command>" -Json',
    'scripts\cognitive-enforce.ps1 "<user command>" -Phase BeforeAct -Json',
    'scripts\goal-route-lock.ps1 -Action Create -TaskId <taskId> -AcceptedGoal <goal> -AcceptedRoute <route steps> -Json',
    'scripts\route-checkpoint.ps1 -Phase BeforeMutation -TaskId <taskId> -ObservedAction <action> -Json',
    'scripts\causal-change-plan.ps1 -Action Create -TaskId <taskId> -ObservedProblem <problem> -RootCause <cause> -KnownFacts <facts> -ProposedChange <change> -ExpectedOptimization <expected> -VerificationMethod <method> -Json',
    'scripts\engineering-decision-gate.ps1 -Action Create -TaskId <taskId> -Problem <problem> -PainPoint <pain> -Objective <objective> -Facts <facts> -FactEvidence <evidence> -Assumptions <inferences> -Unknowns <unknowns> -CriticalUnknowns <critical> -RootCauseStatus verified|hypothesis|unknown -RootCause <cause> -Constraints <constraints> -Options <options> -Tradeoffs <tradeoffs> -Criteria <criteria> -SelectedOption <option> -DiscriminatingTest <test> -ExecutionSteps <steps> -StepInputs <inputs> -StepOutputs <outputs> -StepAcceptance <acceptance> -StepStopConditions <stops> -AcceptanceCriteria <final acceptance> -Risks <risks> -Json',
    'scripts\cognitive-enforce.ps1 "<user command>" -TaskId <taskId> -Phase BeforeMutation -Json',
    'scripts\integration-contract-replay.ps1 -TaskId <taskId> -Module <module> -ExpectedOutput <expected> -ActualOutput <actual> -Json',
    'scripts\causal-change-review.ps1 -TaskId <taskId> -ActualResult <actual> -Evidence <evidence> -Decision keep|revise|rollback -Json',
    'scripts\task-verification.ps1 -TaskId <taskId> -Summary <summary> -Evidence <evidence> -Json',
    'scripts\completion-guard.ps1 -TaskId <taskId> -RequireEngineeringDecision -Json',
    'scripts\verify-package.ps1',
    'scripts\ci.ps1'
  )
  $why += 'feature_intent_guarded_default_flow'
  $confidence = 0.82
}

if ($engineeringJudgmentRequired -and $intent.intent -ne 'add_or_optimize_feature') {
  Add-CompositionCommand 'scripts\cognitive-preflight.ps1 "<user command>" -Json'
  Add-CompositionCommand 'scripts\engineering-decision-gate.ps1 -Action Create -TaskId <taskId> -Problem <problem> -PainPoint <pain> -Objective <objective> -Facts <facts> -FactEvidence <evidence> -RootCauseStatus verified|hypothesis|unknown -RootCause <cause> -Constraints <constraints> -Options <options> -Tradeoffs <tradeoffs> -Criteria <criteria> -SelectedOption <option> -ExecutionSteps <steps> -StepInputs <inputs> -StepOutputs <outputs> -StepAcceptance <acceptance> -StepStopConditions <stops> -AcceptanceCriteria <final acceptance> -Risks <risks> -Json'
  Add-CompositionCommand 'scripts\cognitive-enforce.ps1 "<user command>" -TaskId <taskId> -Phase BeforeMutation -Json'
  $why += 'engineering_judgment_active'
  if ($intent.intent -notin @('release','status','team_or_review','agent_bridge_channel','workflow_preference_recall')) { $nextAction = 'Build an evidence-bounded engineering decision, resolve critical unknowns with the cheapest discriminating test, then execute and verify in dependency order.' }
}

$why += 'orc_auto_composition_route'
Add-CompositionCommand 'scripts\skill-capability-map.ps1 -Query "<user command>" -Json'
$completionSkillAudit = [pscustomobject]@{
  required = $true
  source = 'orcComposition.routePlan'
  auditMode = 'before_completion_skill_audit'
  auditRequested = $completionAuditRequested
  expectedRoles = @($completionExpectedRoles)
  presentRoles = @($skillRoutePlan | ForEach-Object { [string]$_.role } | Select-Object -Unique)
  missingRoles = @($completionExpectedRoles | Where-Object { @($skillRoutePlan | ForEach-Object { [string]$_.role }) -notcontains $_ })
  guard = 'Before completion, audit evidence grounding, engineering decision quality, rule/verifier/real-user-path/version/cache/learning roles, and mark only genuinely inapplicable roles as such; do not approve unevidenced completion.'
}

$result = [pscustomobject]@{
  ok = ($intent.ok -ne $false -and $orcComposition.enabled -eq $true -and $workflowPreferenceOk)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  input = $inputText
  workspace = $Workspace
  intent = $intent.intent
  dashboardMode = $dashboardMode
  dashboardOk = $dashboard.ok
  dashboardRisks = @($dashboard.risks)
  blockingConditions = @($continuation.blockers)
  confidence = $confidence
  nextAction = $nextAction
  why = @($why)
  commands = @($commands)
  orcComposition = $orcComposition
  engineeringJudgment = [pscustomobject]@{
    required = $engineeringJudgmentRequired
    activationReasons = @($engineeringActivationReasons | Select-Object -Unique)
    method = 'references/engineering-judgment.md'
    decisionGate = 'engineering-decision-gate.ps1'
    epistemicClasses = @('FACT','INFERENCE','UNKNOWN')
    rootCauseStatuses = @('verified','hypothesis','unknown')
    outputContract = @('Judgment','Evidence','Best option','Execution chain','Acceptance/Risk')
  }
  completionSkillAudit = $completionSkillAudit
  blockers = @($continuation.blockers)
  dispatchRecommendations = @($dispatchLearning.recommendations | Select-Object -First 3)
  workflowPreference = $intent.workflowPreference
  canonicalResponseContract = $canonicalResponseContract
}

if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "SMART_NEXT intent=$($result.intent) mode=$($result.dashboardMode) action=$($result.nextAction) blockers=$(@($result.blockers).Count)" }
if (-not $result.ok) { exit 1 }
exit 0
