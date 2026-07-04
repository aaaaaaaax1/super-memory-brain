param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Convert-ToolJson([object[]]$Output, [string]$ScriptName) {
  $jsonStart = -1
  for ($index = 0; $index -lt $Output.Count; $index++) {
    if ([string]$Output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
  }
  if ($jsonStart -lt 0) { return [pscustomobject]@{ ok=$false; error="No JSON from $ScriptName" } }
  return ((@($Output[$jsonStart..($Output.Count - 1)]) -join "`n") | ConvertFrom-Json)
}

$inputText = (($Text -join ' ').Trim())
$intent = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'intent-router.ps1') $inputText -Json 6>$null) 'intent-router.ps1'
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
  [void]$skillRoutePlan.Add([pscustomobject]@{ name=$cap.name; category=$cap.category; role=$cap.role; applyAt=@($cap.applyAt); verification=@($cap.verification); mode='rules_as_execution_constraints_not_menu_calls' })
}
foreach ($cap in @($capabilityMap.capabilities | Where-Object { [string]$_.category -ne 'rule' })) {
  [void]$skillRoutePlan.Add([pscustomobject]@{ name=$cap.name; category=$cap.category; role=$cap.role; applyAt=@($cap.applyAt); verification=@($cap.verification); mode='orc_auto_composition_route' })
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
function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
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

if ($intent.intent -eq 'agent_bridge_channel') {
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
    'scripts\integration-contract-replay.ps1 -TaskId <taskId> -Module <module> -ExpectedOutput <expected> -ActualOutput <actual> -Json',
    'scripts\causal-change-review.ps1 -TaskId <taskId> -ActualResult <actual> -Evidence <evidence> -Decision keep|revise|rollback -Json',
    'scripts\task-verification.ps1 -TaskId <taskId> -Summary <summary> -Evidence <evidence> -Json',
    'scripts\completion-guard.ps1 -TaskId <taskId> -Json',
    'scripts\verify-package.ps1',
    'scripts\ci.ps1'
  )
  $why += 'feature_intent_guarded_default_flow'
  $confidence = 0.82
}

$why += 'orc_auto_composition_route'
Add-CompositionCommand 'scripts\skill-capability-map.ps1 -Query "<user command>" -Json'
$completionSkillAudit = [pscustomobject]@{
  required = $true
  source = 'orcComposition.routePlan'
  auditMode = 'before_completion_skill_audit'
  expectedRoles = @('pre_action_constraint','challenge_gate','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair')
  presentRoles = @($skillRoutePlan | ForEach-Object { [string]$_.role } | Select-Object -Unique)
  missingRoles = @('pre_action_constraint','challenge_gate','review_verifier','test_strategy','skill_gap_repair' | Where-Object { @($skillRoutePlan | ForEach-Object { [string]$_.role }) -notcontains $_ })
  guard = 'Before completion, audit whether expected rule/verifier/real-user-path/version/cache/learning skills were routed, applied, or explicitly marked not applicable; do not approve unevidenced completion.'
}

$result = [pscustomobject]@{
  ok = ($intent.ok -ne $false -and $orcComposition.enabled -eq $true)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = $dashboard.version
  input = $inputText
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
  completionSkillAudit = $completionSkillAudit
  blockers = @($continuation.blockers)
  dispatchRecommendations = @($dispatchLearning.recommendations | Select-Object -First 3)
}

if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "SMART_NEXT intent=$($result.intent) mode=$($result.dashboardMode) action=$($result.nextAction) blockers=$(@($result.blockers).Count)" }
if (-not $result.ok) { exit 1 }
exit 0
