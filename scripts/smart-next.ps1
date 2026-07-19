[CmdletBinding(PositionalBinding=$false)]
param(
  [Parameter(Position=0,ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [string]$Workspace = '',
  [string]$SessionKey = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = (Get-Location).Path }
$workspaceKey = Get-SuperBrainWorkspaceKey $Workspace
$hostSessionKey = Get-SuperBrainHostSessionKey $SessionKey

function Convert-ToolJson([object[]]$Output, [string]$ScriptName) {
  $jsonStart = -1
  for ($index = 0; $index -lt $Output.Count; $index++) {
    if ([string]$Output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
  }
  if ($jsonStart -lt 0) { return [pscustomobject]@{ ok=$false; error="No JSON from $ScriptName" } }
  return ((@($Output[$jsonStart..($Output.Count - 1)]) -join "`n") | ConvertFrom-Json)
}
function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
function Limit-SmartNextText([string]$Value,[int]$Max=220) {
  if ([string]::IsNullOrWhiteSpace($Value) -or $Max -le 0) { return '' }
  $clean = ($Value.Trim() -replace '\s+',' ')
  if ($clean.Length -le $Max) { return $clean }
  if ($Max -le 3) { return $clean.Substring(0,$Max) }
  return $clean.Substring(0,$Max - 3).TrimEnd() + '...'
}
function Select-BoundedStrings([object[]]$Values,[int]$MaxItems=12,[int]$MaxChars=220,[switch]$PreserveTail) {
  $items = @($Values | ForEach-Object { Limit-SmartNextText ([string]$_) $MaxChars } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($items.Count -le $MaxItems) { return @($items) }
  if (-not $PreserveTail -or $MaxItems -lt 4) { return @($items | Select-Object -First $MaxItems) }
  $tailCount = [Math]::Min(4,$MaxItems - 1)
  $headCount = $MaxItems - $tailCount
  return @(@($items | Select-Object -First $headCount) + @($items | Select-Object -Last $tailCount) | Select-Object -Unique)
}
function ConvertTo-BoundedRoutePlan([object[]]$Plans) {
  return @($Plans | Select-Object -First 12 | ForEach-Object {
    [pscustomobject]@{
      name = Limit-SmartNextText ([string]$_.name) 120
      category = Limit-SmartNextText ([string]$_.category) 60
      role = Limit-SmartNextText ([string]$_.role) 80
      score = [int]$_.score
      applyAt = @(Select-BoundedStrings @($_.applyAt) 4 120)
      verification = @(Select-BoundedStrings @($_.verification) 4 160)
      mode = Limit-SmartNextText ([string]$_.mode) 80
    }
  })
}
function ConvertTo-BoundedClassification([object]$Classification) {
  if (-not $Classification) { return $null }
  return [pscustomobject]@{
    mode = Limit-SmartNextText ([string]$Classification.mode) 40
    topicAffinity = Limit-SmartNextText ([string]$Classification.topicAffinity) 120
    targetLineId = Limit-SmartNextText ([string]$Classification.targetLineId) 120
    targetLineLabel = Limit-SmartNextText ([string]$Classification.targetLineLabel) 100
    confidence = Limit-SmartNextText ([string]$Classification.confidence) 20
    matchedKeys = @(Select-BoundedStrings @($Classification.matchedKeys) 6 48)
    candidateLineIds = @(Select-BoundedStrings @($Classification.candidateLineIds) 6 120)
    needsClarification = [bool]$Classification.needsClarification
    recommendedInstructionMode = Limit-SmartNextText ([string]$Classification.recommendedInstructionMode) 40
    reason = Limit-SmartNextText ([string]$Classification.reason) 180
    rawInstructionStored = $false
  }
}
function Protect-SmartNextResolution([object]$Resolution,[string]$GuardText) {
  if (-not $Resolution) { return $null }
  $protected = Remove-SuperBrainExecutableActions $Resolution
  $protected.nextAction = $GuardText
  $protected.guard = $GuardText
  if ($protected.workLineStatus -and $protected.workLineStatus.latestMessageClassification) { $protected.workLineStatus.latestMessageClassification = ConvertTo-BoundedClassification $protected.workLineStatus.latestMessageClassification }
  if ($protected.latestMessageClassification) { $protected.latestMessageClassification = ConvertTo-BoundedClassification $protected.latestMessageClassification }
  return $protected
}
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

$inputParts = @($Text | Select-Object -First 16 | ForEach-Object { Limit-SmartNextText ([string]$_) 300 })
$inputText = Limit-SmartNextText (($inputParts -join ' ').Trim()) 1200
$workspaceDisplay = Limit-SmartNextText $Workspace 260
$intent = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'intent-router.ps1') -Text $inputText -Workspace $Workspace -Json 6>$null) 'intent-router.ps1'
$capabilityMap = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Query $inputText -TopK 12 -Json 6>$null) 'skill-capability-map.ps1'
$ruleCapabilities = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Query $inputText -Category 'rule' -TopK 4 -Json 6>$null) 'skill-capability-map.ps1'
$visibleExecutionResolution = $null
$visibleExecutionResolutionFailed = $false
if (-not [string]::IsNullOrWhiteSpace($inputText)) {
  try {
    $resolutionRaw = @(& (Join-Path $PSScriptRoot 'execution-contract.ps1') -Action Resolve -WorkspaceKey $workspaceKey -SessionKey $hostSessionKey -VisibleUserInstruction $inputText -NoExit -Json 2>$null)
    if ($resolutionRaw) { $visibleExecutionResolution = (($resolutionRaw -join "`n") | ConvertFrom-Json) }
    if (-not $visibleExecutionResolution -or $visibleExecutionResolution.ok -ne $true) { $visibleExecutionResolutionFailed = $true }
  } catch { $visibleExecutionResolutionFailed = $true }
}
$continuation = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'auto-continuation.ps1') -WorkspaceKey $workspaceKey -SessionKey $hostSessionKey -Json 6>$null) 'auto-continuation.ps1'
$dashboardMode = if ($intent.intent -eq 'team_or_review') { 'Team' } elseif ($intent.intent -in @('status','release')) { 'Full' } else { 'Light' }
$dashboard = Convert-ToolJson @(& (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') -Mode $dashboardMode -WorkspaceKey $workspaceKey -SessionKey $hostSessionKey -Json 6>$null) 'super-brain-dashboard.ps1'
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
$zhSubAgentAlias = (U @(23376)) + 'agent'
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
    $nextAction = 'Answer with canonicalResponseContract.content and the current verified task facts; output Summary, Description, and Commit button text only; do not substitute generic Git commands or apology text.'
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
      "scripts\agent-bridge-channel.ps1 -Action Open -ChannelId <new-channel-id-or-omit-to-auto-create-fresh> -FromAgentId <agentId> -Alias `"$zhSubAgentAlias`" -Json",
      'do not create or launch a nested agent/worker/helper; the current conversation is the sub-agent target',
      'scripts\agent-bridge-channel.ps1 -Action WaitConnect -ChannelId <channelId> -AgentId <agentId> -WaitSeconds 900 -PollIntervalSeconds 5 -Json',
      'scripts\agent-bridge-channel.ps1 -Action WaitInbox -ChannelId <channelId> -AgentId <agentId> -WaitSeconds 900 -PollIntervalSeconds 5 -Json',
      'if WaitConnect/WaitInbox returns idle_waiting_* then stay quiet; do not report blocked, do not repeat status, and wait for user/main-agent activity',
      'after replying to a received message, return to WaitInbox; do not report Goal/target completion unless explicit close is requested'
    )
    $why += 'agent_bridge_channel_open_no_auto_close'
  } elseif ($channelConnect) {
    $commands = @("scripts\agent-bridge-channel.ps1 -Action Connect -ChannelId <channelId> -OperatorAgentId <mainAgentId> -ToAgentId <targetAgentId> -Alias `"$zhSubAgentAlias`" -Json")
    $why += 'agent_bridge_channel_connect'
  } elseif ($channelSend) {
    $commands = @("scripts\agent-bridge-channel.ps1 -Action SendAndWait -Alias `"$zhSubAgentAlias`" -Summary `"<message>`" -WaitSeconds 60 -PollIntervalSeconds 2 -AutoAck -Json")
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
  Add-CompositionCommand 'scripts\causal-change-review.ps1 -TaskId <taskId> -ActualResult <actual> -Evidence <evidence> -Decision keep|revise|rollback -Json (after mutation, before completion)'
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
  postMutationReview = [pscustomobject]@{ artifact='task-scoped causal-change-review.ps1 result'; requiredWhen='mutation-bearing work reaches completion'; command='scripts\causal-change-review.ps1 -TaskId <taskId> -ActualResult <actual> -Evidence <evidence> -Decision keep -Json'; acceptance='actual result and evidence are present, taskId matches, and decision=keep' }
  guard = 'Before completion, audit evidence grounding, engineering decision quality, rule/verifier/real-user-path/version/cache/learning roles, and require a task-scoped causal review with decision=keep for mutation-bearing work; role presence alone is not evidence.'
}
$effectiveExecutionResolution = if ($visibleExecutionResolution) { $visibleExecutionResolution } elseif ($continuation.executionResolution) { $continuation.executionResolution } else { $null }
$compactExecutionResolution = if ($visibleExecutionResolution) { ConvertTo-SuperBrainCompactExecutionResolution $visibleExecutionResolution } elseif ($continuation.executionResolution) { $continuation.executionResolution } else { $null }
$compactDashboardWorkLines = if ($dashboard) { ConvertTo-SuperBrainCompactWorkLineStatus $dashboard.workLineStatus } else { $null }
$classification = if ($compactExecutionResolution -and $compactExecutionResolution.latestMessageClassification) { $compactExecutionResolution.latestMessageClassification } elseif ($compactExecutionResolution -and $compactExecutionResolution.workLineStatus) { $compactExecutionResolution.workLineStatus.latestMessageClassification } else { $null }
$topicAffinity = if ($classification) { [string]$classification.topicAffinity } else { '' }
$resolvedTaskId = if ($effectiveExecutionResolution) { [string]$effectiveExecutionResolution.taskId } else { '' }
$candidateTaskIds = if ($effectiveExecutionResolution -and $effectiveExecutionResolution.PSObject.Properties['candidateTaskIds']) { @($effectiveExecutionResolution.candidateTaskIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) } else { @() }
$hasTaskScopedResolution = (([string]::IsNullOrWhiteSpace($resolvedTaskId) -eq $false) -or $candidateTaskIds.Count -gt 0)
$needsConfirmation = ($effectiveExecutionResolution -and $effectiveExecutionResolution.needsConfirmation -eq $true) -or ($continuation.needsConfirmation -eq $true)
$continuationHasTask = ($continuation.executionResolution -and -not [string]::IsNullOrWhiteSpace([string]$continuation.executionResolution.taskId))
$isolatedSessionAccess = ($effectiveExecutionResolution -and [string]$effectiveExecutionResolution.sessionAccess -in @('foreign','unbound','session_required')) -or ($continuation.executionResolution -and [string]$continuation.executionResolution.sessionAccess -in @('foreign','unbound','session_required'))
$continuityIntent = ([string]$intent.intent -in @('continue','historical_recovery','current_task_status','status'))
$foreignContextContinuity = ($continuityIntent -and $effectiveExecutionResolution -and $effectiveExecutionResolution.foreignContextDetected -eq $true)
$taskResolutionDenied = ($hasTaskScopedResolution -and $effectiveExecutionResolution -and $effectiveExecutionResolution.actionAuthorization -ne 'allowed')
$continuationResolutionDenied = ($continuityIntent -and $continuationHasTask -and $continuation.actionWithheld -eq $true)
$isolatedSessionDenied = ($isolatedSessionAccess -and ($hasTaskScopedResolution -or $continuityIntent))
$authorizationDenied = ($visibleExecutionResolutionFailed -or $foreignContextContinuity -or $isolatedSessionDenied -or $taskResolutionDenied -or $continuationResolutionDenied)
$requiresUserDisambiguation = ($classification -and $classification.needsClarification -eq $true) -or ($compactExecutionResolution -and $compactExecutionResolution.workLineStatus -and $compactExecutionResolution.workLineStatus.requiresUserDisambiguation -eq $true) -or ($continuation.requiresUserDisambiguation -eq $true)
$unknownAffinity = ($hasTaskScopedResolution -and -not [string]::IsNullOrWhiteSpace($inputText) -and ([string]::IsNullOrWhiteSpace($topicAffinity) -or $topicAffinity -eq 'unknown'))
$ambiguousAffinity = ($topicAffinity -eq 'ambiguous')
$actionWithheld = ($authorizationDenied -or ($hasTaskScopedResolution -and ($needsConfirmation -or $requiresUserDisambiguation -or $unknownAffinity -or $ambiguousAffinity)))
$continuationState = if ($authorizationDenied) { 'needs_confirmation' } elseif (-not $hasTaskScopedResolution) { 'not_applicable' } elseif ($ambiguousAffinity -or $requiresUserDisambiguation) { 'requires_user_disambiguation' } elseif ($unknownAffinity) { 'unknown_affinity' } elseif ($needsConfirmation) { 'needs_confirmation' } else { 'actionable' }
$withheldAction = 'Action withheld: confirm or reconcile how the latest user instruction maps to the active work line before mutation.'
if ($actionWithheld) {
  $nextAction = $withheldAction
  $commands = @()
  $compactExecutionResolution = Protect-SmartNextResolution $compactExecutionResolution $withheldAction
  $orcComposition.routePlan = @()
  $completionSkillAudit.postMutationReview.command = ''
} else {
  $orcComposition.routePlan = @(ConvertTo-BoundedRoutePlan @($skillRoutePlan))
}
if ($compactExecutionResolution -and $compactExecutionResolution.latestMessageClassification) {
  $compactExecutionResolution.latestMessageClassification = ConvertTo-BoundedClassification $compactExecutionResolution.latestMessageClassification
}
if ($compactExecutionResolution -and $compactExecutionResolution.workLineStatus -and $compactExecutionResolution.workLineStatus.latestMessageClassification) {
  $compactExecutionResolution.workLineStatus.latestMessageClassification = ConvertTo-BoundedClassification $compactExecutionResolution.workLineStatus.latestMessageClassification
}
$allPresentRoles = @($skillRoutePlan | ForEach-Object { [string]$_.role } | Where-Object { $_ } | Select-Object -Unique)
$orderedPresentRoles = @(@($completionExpectedRoles | Where-Object { $allPresentRoles -contains $_ }) + @($allPresentRoles | Where-Object { $completionExpectedRoles -notcontains $_ }))
$completionSkillAudit.expectedRoles = @(Select-BoundedStrings @($completionExpectedRoles) 12 80)
$completionSkillAudit.presentRoles = @(Select-BoundedStrings @($orderedPresentRoles) 12 80)
$completionSkillAudit.missingRoles = @(Select-BoundedStrings @($completionExpectedRoles | Where-Object { $allPresentRoles -notcontains $_ }) 12 80)
$completionSkillAudit.source = Limit-SmartNextText ([string]$completionSkillAudit.source) 100
$completionSkillAudit.auditMode = Limit-SmartNextText ([string]$completionSkillAudit.auditMode) 80
$completionSkillAudit.guard = Limit-SmartNextText ([string]$completionSkillAudit.guard) 240
$completionSkillAudit.postMutationReview.artifact = Limit-SmartNextText ([string]$completionSkillAudit.postMutationReview.artifact) 120
$completionSkillAudit.postMutationReview.requiredWhen = Limit-SmartNextText ([string]$completionSkillAudit.postMutationReview.requiredWhen) 120
$completionSkillAudit.postMutationReview.command = Limit-SmartNextText ([string]$completionSkillAudit.postMutationReview.command) 220
$completionSkillAudit.postMutationReview.acceptance = Limit-SmartNextText ([string]$completionSkillAudit.postMutationReview.acceptance) 180
$workflowPreferenceOutput = if ($intent.workflowPreference) {
  [pscustomobject]@{
    id = Limit-SmartNextText ([string]$intent.workflowPreference.id) 100
    decisionKey = Limit-SmartNextText ([string]$intent.workflowPreference.decisionKey) 120
    query = Limit-SmartNextText ([string]$intent.workflowPreference.query) 180
    scope = Limit-SmartNextText ([string]$intent.workflowPreference.scope) 80
    matchedPhrase = Limit-SmartNextText ([string]$intent.workflowPreference.matchedPhrase) 120
  }
} else { $null }
$canonicalResponseOutput = [pscustomobject]@{
  ok = [bool]$canonicalResponseContract.ok
  status = Limit-SmartNextText ([string]$canonicalResponseContract.status) 60
  decisionKey = Limit-SmartNextText ([string]$canonicalResponseContract.decisionKey) 120
  content = Limit-SmartNextText ([string]$canonicalResponseContract.content) 900
  source = Limit-SmartNextText ([string]$canonicalResponseContract.source) 220
  tags = Limit-SmartNextText ([string]$canonicalResponseContract.tags) 180
  title = Limit-SmartNextText ([string]$canonicalResponseContract.title) 120
  scope = Limit-SmartNextText ([string]$canonicalResponseContract.scope) 80
  activeCount = [int]$canonicalResponseContract.activeCount
}
$baseMutationAuthorized = if ($visibleExecutionResolution) { $visibleExecutionResolution.actionAuthorization -eq 'allowed' -and [bool]$visibleExecutionResolution.claimAllowed -and $visibleExecutionResolution.needsConfirmation -ne $true } else { [bool]$continuation.mutationAuthorized }

$result = [pscustomobject]@{
  ok = ($intent.ok -ne $false -and $orcComposition.enabled -eq $true -and $workflowPreferenceOk)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = Limit-SmartNextText ([string]$dashboard.version) 40
  input = $inputText
  workspace = $workspaceDisplay
  workspaceKey = $workspaceKey
  intent = Limit-SmartNextText ([string]$intent.intent) 80
  dashboardMode = Limit-SmartNextText ([string]$dashboardMode) 20
  dashboardOk = $dashboard.ok
  dashboardRisks = @(Select-BoundedStrings @($dashboard.risks) 6 180)
  executionResolution = $compactExecutionResolution
  continuityStateCard = if ($compactExecutionResolution) { $compactExecutionResolution.continuityStateCard } else { $null }
  workLineStatus = if ($compactExecutionResolution) { $compactExecutionResolution.workLineStatus } else { $compactDashboardWorkLines }
  latestMessageClassification = if ($compactExecutionResolution) { $compactExecutionResolution.latestMessageClassification } else { $null }
  needsConfirmation = [bool]$needsConfirmation
  requiresUserDisambiguation = [bool]$requiresUserDisambiguation
  topicAffinity = Limit-SmartNextText $topicAffinity 120
  continuationState = $continuationState
  actionWithheld = [bool]$actionWithheld
  workLineMutationAuthorized = (-not $actionWithheld -and $baseMutationAuthorized)
  blockingConditions = @(Select-BoundedStrings @($continuation.blockers) 6 180)
  confidence = $confidence
  nextAction = Limit-SmartNextText $nextAction 240
  why = @(Select-BoundedStrings @($why) 12 120)
  commands = @(Select-BoundedStrings @($commands) 12 420 -PreserveTail)
  orcComposition = $orcComposition
  engineeringJudgment = [pscustomobject]@{
    required = $engineeringJudgmentRequired
    activationReasons = @(Select-BoundedStrings @($engineeringActivationReasons | Select-Object -Unique) 6 80)
    method = 'references/engineering-judgment.md'
    decisionGate = 'engineering-decision-gate.ps1'
    epistemicClasses = @('FACT','INFERENCE','UNKNOWN')
    rootCauseStatuses = @('verified','hypothesis','unknown')
    outputContract = @('Judgment','Evidence','Best option','Execution chain','Acceptance/Risk')
  }
  completionSkillAudit = $completionSkillAudit
  blockers = @(Select-BoundedStrings @($continuation.blockers) 6 180)
  dispatchRecommendations = @(
    if (-not $actionWithheld) { Select-BoundedStrings @($dispatchLearning.recommendations) 3 220 }
  )
  workflowPreference = $workflowPreferenceOutput
  canonicalResponseContract = $canonicalResponseOutput
}

if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "SMART_NEXT intent=$($result.intent) mode=$($result.dashboardMode) action=$($result.nextAction) blockers=$(@($result.blockers).Count)" }
if (-not $result.ok) { exit 1 }
exit 0
