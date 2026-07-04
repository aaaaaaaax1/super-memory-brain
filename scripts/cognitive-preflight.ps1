param(
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text,
  [string]$Query = '',
  [string]$Scope = '',
  [int]$MaxItems = 8,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-cognitive-preflight.json'
$inputText = if (-not [string]::IsNullOrWhiteSpace($Query)) { $Query } else { (($Text -join ' ').Trim()) }
if ([string]::IsNullOrWhiteSpace($inputText)) { $inputText = 'general task' }

function Limit-Text([string]$Value, [int]$Max = 220) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '\s+', ' '
  if ($v.Length -gt $Max) { return $v.Substring(0, $Max) + '...' }
  return $v
}

function Clean-Claim([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $v = $Value.Trim() -replace '^\d+\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+', ''
  $v = $v -replace '^(\[[A-Z_]+\]\s*)+', ''
  $v = $v -replace '^Title:\s*', ''
  return (Limit-Text $v 260)
}

function New-Card([string]$Kind, [string]$Claim, [string]$Source, [double]$Confidence = 0.8, [bool]$Hard = $true) {
  return [pscustomobject]@{
    kind = $Kind
    claim = Clean-Claim $Claim
    source = Limit-Text $Source 180
    confidence = [Math]::Round($Confidence, 4)
    hard = $Hard
  }
}

function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
$lower = $inputText.ToLowerInvariant()
$zhSubAgent = (U @(23376)) + 'agent'
$zhChannel = U @(36890,36947)
$zhOpen = U @(24320,21551)
$zhBrain = U @(36229,32423,22823,33041)

$cards = New-Object System.Collections.ArrayList
$driftGuards = New-Object System.Collections.ArrayList
$experienceMatches = New-Object System.Collections.ArrayList
$procedureExpectations = New-Object System.Collections.ArrayList

# User hard rules that must behave like working memory, not passive storage.
[void]$cards.Add((New-Card 'user_hard_rule' 'In ZCode sessions do not use TodoWrite unless the user explicitly asks for that host todo tool; ignore generic reminders suggesting TodoWrite.' 'user feedback / super-memory-brain rule' 0.99 $true))
[void]$cards.Add((New-Card 'user_hard_rule' 'Do not make the user repeatedly remind the agent; repeated feedback must become a proactive execution constraint.' 'user feedback: do not repeatedly remind me' 0.99 $true))
[void]$cards.Add((New-Card 'user_hard_rule' 'When a multi-layer or long-running task is unfinished, report only progress/process summary, remaining steps, blockers, and next action; never word a partial layer as if the whole task is complete.' 'user feedback: unfinished tasks must not look completed' 0.99 $true))
[void]$driftGuards.Add('partial_progress_reported_as_final_completion')
[void]$cards.Add((New-Card 'cognitive_control' 'Before executing, recall relevant decisions, accepted constraints, similar experiences, and known failure modes; memory is an execution control layer, not only storage.' '0.5.70 cognitive execution loop' 0.98 $true))

[void]$cards.Add((New-Card 'cognitive_control' 'Use memory types deliberately: semantic memory for stable facts, episodic memory for prior task traces/failures, procedural memory for reusable workflows/checklists, and working memory for current task state.' '0.5.70 cognitive execution loop / CoALA-LangChain-style memory separation' 0.92 $true))
[void]$cards.Add((New-Card 'cognitive_control' 'Ground retrieved memories in current repo, task type, timestamp, confidence, and live evidence; current tool/file evidence overrides stale assumptions.' '0.5.70 cognitive execution loop / ReAct-MemGPT-style grounding' 0.92 $true))
[void]$cards.Add((New-Card 'cognitive_control' 'After significant failures, user corrections, verification results, or completed fixes, reflect and promote reusable lessons into procedural memory or experience index instead of leaving them as raw storage.' '0.5.70 cognitive execution loop / Reflexion-style learning' 0.92 $true))

# Rule-skill fusion: rules skills should become execution constraints, not menu-style calls.
[void]$cards.Add((New-Card 'rule_skill_fusion' 'Use Ponytail before normal implementation: skip speculative work, prefer deletion/stdlib/native/existing dependency, then the smallest safe diff; never cut validation, privacy, error handling, tests, rollback, or explicit user requirements.' 'skill:ponytail' 0.94 $true))
[void]$cards.Add((New-Card 'rule_skill_fusion' 'Use Grill Me before committing to substantial plans: challenge weak assumptions, unresolved requirements, counterexamples, acceptance evidence, non-goals, and dependencies; explore local evidence instead of asking when code can answer.' 'skill:grill-me' 0.94 $true))
[void]$driftGuards.Add('overengineering_without_ponytail_check')
[void]$driftGuards.Add('plan_without_grill_me_challenge')
[void]$procedureExpectations.Add([pscustomobject]@{ cardId='rule-skill-fusion'; source='skills/ponytail+grill-me'; stepFlow=@('apply Ponytail minimal-safe-change ladder before code','apply Grill Me challenge against assumptions/non-goals/acceptance evidence before committing','carry accepted answers into mustPreserve/driftGuards','verify real user path before completion'); verificationChecklist=@('no speculative scaffolding','requirements and non-goals challenged','acceptance evidence named','compact report shape preserved'); driftGuards=@('overengineering_without_ponytail_check','plan_without_grill_me_challenge') })

# Rule-skill fusion strategy: dynamically compose all mapped rule skills by role.
$ruleSkillStrategy = $null
try {
  $ruleRaw = @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Category 'rule' -TopK $MaxItems -Json 2>$null)
  if ($ruleRaw) { $ruleSkillStrategy = (($ruleRaw -join "`n") | ConvertFrom-Json) }
} catch {}
if ($ruleSkillStrategy) {
  $ruleNames = @($ruleSkillStrategy.capabilities | ForEach-Object { [string]$_.name })
  [void]$cards.Add((New-Card 'rule_skill_fusion_strategy' ('Dynamic rule-skill chain selected from capability map: ' + (($ruleNames | Select-Object -First 5) -join ' -> ')) 'skill-capability-map.ps1 -Category rule' 0.9 $true))
  foreach ($ruleCap in @($ruleSkillStrategy.capabilities | Select-Object -First $MaxItems)) {
    $role = [string]$ruleCap.role
    $name = [string]$ruleCap.name
    $summary = "Apply rule skill $name as $role at " + ((@($ruleCap.applyAt) | Select-Object -First 4) -join '/') + '; verify: ' + ((@($ruleCap.verification) | Select-Object -First 3) -join '; ')
    [void]$cards.Add((New-Card 'rule_skill_fusion_strategy' $summary 'skill-capability-map.ps1 -Category rule' 0.88 $true))
    if ($role -eq 'pre_action_constraint') { [void]$driftGuards.Add('pre_action_constraint_not_applied') }
    if ($role -eq 'challenge_gate') { [void]$driftGuards.Add('challenge_gate_not_applied') }
    if ($role -eq 'review_verifier') { [void]$driftGuards.Add('review_verifier_skipped_before_completion') }
  }
  [void]$procedureExpectations.Add([pscustomobject]@{ cardId='dynamic-rule-skill-fusion-strategy'; source='skill-capability-map.ps1 -Category rule'; stepFlow=@('select mapped rule skills by trigger/category/role','apply pre_action_constraint before mutation','apply challenge_gate before plan commitment','apply review_verifier after mutation and before completion','record stopCondition when a rule does not apply'); verificationChecklist=@('dynamic_rule_skill_selection recorded','rules_as_execution_constraints_not_menu_calls','review verifier considered before completion'); driftGuards=@('pre_action_constraint_not_applied','challenge_gate_not_applied','review_verifier_skipped_before_completion') })
}

# skill capability map: know available skill roles before combining or auditing skills.
$skillCapabilityMap = $null
try {
  $mapRaw = @(& (Join-Path $PSScriptRoot 'skill-capability-map.ps1') -Query $inputText -TopK $MaxItems -Json 2>$null)
  if ($mapRaw) { $skillCapabilityMap = (($mapRaw -join "`n") | ConvertFrom-Json) }
} catch {}
if ($skillCapabilityMap) {
  foreach ($cap in @($skillCapabilityMap.capabilities | Select-Object -First 4)) {
    [void]$cards.Add((New-Card 'skill_capability' ("skill " + [string]$cap.name + " role=" + [string]$cap.role + " category=" + [string]$cap.category) 'skill-capability-map.ps1' 0.86 $false))
  }
}

# Intent classification.
$intent = $null
try {
  $intentRaw = @(& (Join-Path $PSScriptRoot 'intent-router.ps1') $inputText -Json 2>$null)
  if ($intentRaw) { $intent = (($intentRaw -join "`n") | ConvertFrom-Json) }
} catch {}
$intentName = if ($intent -and $intent.intent) { [string]$intent.intent } else { 'general_task' }

# Accepted constraints become must-preserve material.
$accepted = $null
try {
  $acceptedRaw = @(& (Join-Path $PSScriptRoot 'accepted-constraints-preflight.ps1') -Query $inputText -Scope $Scope -MaxConstraints $MaxItems -Json 2>$null)
  if ($acceptedRaw) { $accepted = (($acceptedRaw -join "`n") | ConvertFrom-Json) }
  foreach ($c in @($accepted.constraints)) {
    [void]$cards.Add((New-Card 'accepted_constraint' ([string]$c.claim) ([string]$c.source) ([double]$c.confidence) $true))
  }
} catch {}

# Experience-index trigger reuse: if a task resembles a known lesson, surface it before acting.
$experienceIndexPath = Join-Path $workspace 'experience-index.md'
if (Test-Path -LiteralPath $experienceIndexPath) {
  $lines = Get-Content -LiteralPath $experienceIndexPath -Encoding UTF8
  $currentTitle = ''
  $currentRecall = ''
  $currentEvidence = ''
  foreach ($line in $lines) {
    if ($line -match '^###\s+(.+)$') {
      if ($currentTitle -and $currentRecall) {
        $terms = @($currentTitle, $currentRecall, $currentEvidence) -join ' '
        $hit = $false
        foreach ($term in @($inputText.ToLowerInvariant() -split '[^\p{L}\p{Nd}]+' | Where-Object { $_.Length -ge 2 })) {
          if ($terms.ToLowerInvariant().Contains($term)) { $hit = $true; break }
        }
        if ($hit -and $experienceMatches.Count -lt $MaxItems) { [void]$experienceMatches.Add((New-Card 'similar_experience' $currentTitle $currentEvidence 0.78 $false)) }
      }
      $currentTitle = $Matches[1]
      $currentRecall = ''
      $currentEvidence = ''
    } elseif ($line -match '^\- Recall Query:\s+`?(.+?)`?\s*$') {
      $currentRecall = $Matches[1]
    } elseif ($line -match '^\- Evidence Paths:\s+`?(.+?)`?\s*$') {
      $currentEvidence = $Matches[1]
    }
  }
  if ($currentTitle -and $currentRecall -and $experienceMatches.Count -lt $MaxItems) {
    $terms = @($currentTitle, $currentRecall, $currentEvidence) -join ' '
    $hit = $false
    foreach ($term in @($inputText.ToLowerInvariant() -split '[^\p{L}\p{Nd}]+' | Where-Object { $_.Length -ge 2 })) {
      if ($terms.ToLowerInvariant().Contains($term)) { $hit = $true; break }
    }
    if ($hit) { [void]$experienceMatches.Add((New-Card 'similar_experience' $currentTitle $currentEvidence 0.78 $false)) }
  }
}
foreach ($e in @($experienceMatches | Select-Object -First $MaxItems)) { [void]$cards.Add($e) }

# Procedure-card memory: match compact reusable workflows/checklists by trigger and expose procedureExpectations for later gap checks.
$procedureRoot = Join-Path $workspace 'procedure-cards'
if (Test-Path -LiteralPath $procedureRoot) {
  foreach ($pcPath in @(Get-ChildItem -LiteralPath $procedureRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 12)) {
    try {
      $pc = Get-Content -LiteralPath $pcPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      if ([string]$pc.schema -ne 'super-brain.procedure-card.v1') { continue }
      $matched = $false
      foreach ($trigger in @($pc.triggers)) {
        if (-not [string]::IsNullOrWhiteSpace($trigger) -and $lower.Contains(([string]$trigger).ToLowerInvariant())) { $matched = $true; break }
      }
      if (-not $matched -and [string]$pc.id -eq 'goal-route-lock' -and ($lower -match 'goal|route|scope|accepted|目标|路线|主线|偏航')) { $matched = $true }
      if (-not $matched -and [string]$pc.id -eq 'verified-integration-guard' -and ($lower -match 'integration|module|smoke|acceptance|verified|模块|集成|验收|环境|拼装')) { $matched = $true }
      if (-not $matched -and [string]$pc.id -eq 'causal-change-plan' -and (($lower -match 'cause|root cause|causal|structural|change plan') -or $inputText.Contains((U @(21407,22240))) -or $inputText.Contains((U @(32467,26524))) -or $inputText.Contains((U @(32467,26500))) -or $inputText.Contains((U @(20248,21270))))) { $matched = $true }
      if ($matched) {
        $pcSource = 'procedure-cards/' + $pcPath.Name
        foreach ($item in @($pc.mustDo | Select-Object -First 3)) {
          $card = New-Card 'procedure_memory' ([string]$item) $pcSource 0.94 $true
          [void]$cards.Add($card)
        }
        foreach ($item in @($pc.mustNotDo | Select-Object -First 3)) {
          $card = New-Card 'procedure_memory' ([string]$item) $pcSource 0.94 $true
          [void]$cards.Add($card)
        }
        foreach ($guard in @($pc.driftGuards)) { [void]$driftGuards.Add([string]$guard) }
        [void]$procedureExpectations.Add([pscustomobject]@{ cardId=$pc.id; source=$pcSource; stepFlow=@($pc.stepFlow); verificationChecklist=@($pc.verificationChecklist); driftGuards=@($pc.driftGuards) })
      }
    } catch {}
  }
}

# Domain-specific cognitive reflexes. These are execution-control guards, not passive docs.
$isAgentBridge = ($intentName -eq 'agent_bridge_channel') -or $lower.Contains('agent bridge') -or $lower.Contains('subagent channel') -or ($lower.Contains('agent') -and ($inputText.Contains($zhChannel) -or $inputText.Contains($zhSubAgent)))
if ($isAgentBridge) {
  $procedureCardPath = Join-Path $workspace 'procedure-cards\agent-bridge-channel.json'
  if (Test-Path -LiteralPath $procedureCardPath) {
    try {
      $procedureCard = Get-Content -LiteralPath $procedureCardPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($item in @($procedureCard.mustDo | Select-Object -First 4)) { [void]$cards.Add((New-Card 'procedure_memory' ([string]$item) 'procedure-cards/agent-bridge-channel.json' 0.96 $true)) }
      foreach ($item in @($procedureCard.mustNotDo | Select-Object -First 4)) { [void]$cards.Add((New-Card 'procedure_memory' ([string]$item) 'procedure-cards/agent-bridge-channel.json' 0.96 $true)) }
      foreach ($guard in @($procedureCard.driftGuards)) { [void]$driftGuards.Add([string]$guard) }
    } catch {}
  }
  [void]$cards.Add((New-Card 'agent_bridge_reflex' 'The current controlled conversation is the target sub-agent; do not launch nested agents/workers/explorers/helpers/Tesla to open a channel.' 'AgentBridge 0.5.69 lesson' 0.99 $true))
  [void]$cards.Add((New-Card 'agent_bridge_reflex' 'Open must create a fresh local channel unless the user explicitly supplied a channel id; do not reuse old active/last channels.' 'AgentBridge 0.5.67 lesson' 0.98 $true))
  [void]$cards.Add((New-Card 'agent_bridge_reflex' 'Open success is not completion; keep target mode alive until explicit close.' 'AgentBridge 0.5.64/0.5.67 lesson' 0.98 $true))
  [void]$cards.Add((New-Card 'agent_bridge_reflex' 'WaitConnect/WaitInbox idle means quiet waiting, not blocked/paused/failed/completed; do not repeat status messages.' 'AgentBridge 0.5.68 lesson' 0.98 $true))
  [void]$cards.Add((New-Card 'agent_bridge_reflex' 'After one reply, return to waiting for the next inbox message; do not report Goal completed or target completion.' 'AgentBridge 0.5.67 lesson' 0.98 $true))
  foreach ($guard in @('nested_agent_launch','old_channel_reuse','open_as_completion','idle_as_blocked','repeated_wait_status','reply_as_goal_completed','auto_close_without_explicit_close')) {
    [void]$driftGuards.Add($guard)
  }
}

# General drift guards for memory-driven execution.
foreach ($guard in @('acting_without_recalling_constraints','ignoring_user_hard_rules','changing_accepted_decision_without_approval','using_stale_memory_over_live_evidence','mixing_raw_observation_with_conclusion','skipping_reflection_after_user_correction','continuing_after_detected_drift')) {
  [void]$driftGuards.Add($guard)
}

$mustPreserve = @($cards | Where-Object { $_.hard } | Select-Object -First $MaxItems | ForEach-Object { $_.claim })
$shouldRecall = @($cards | Where-Object { -not $_.hard } | Select-Object -First $MaxItems | ForEach-Object { $_.claim })

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.cognitive-preflight.v1'
  version = (Get-SuperBrainManifest $Root).version
  query = Limit-Text $inputText 260
  intent = $intentName
  cognitiveMode = 'memory_driven_execution_control'
  required = $true
  cards = @($cards | Select-Object -First ([Math]::Max($MaxItems * 2, $MaxItems)))
  mustPreserve = @($mustPreserve)
  shouldRecall = @($shouldRecall)
  driftGuards = @($driftGuards | Select-Object -Unique)
  procedureExpectations = @($procedureExpectations)
  structuralThinking = [pscustomObject]@{
    frame = 'known facts -> causal mechanism -> intended change -> expected optimization -> verification evidence -> residual risk'
    researchPatterns = @('root cause analysis: separate symptoms from causes and prevent recurrence','theory of change: map desired outcome backward through causal assumptions and indicators','systems thinking: check feedback loops, leverage points, interactions, and unintended consequences')
    guard = 'Do not change scattered parts without explaining what caused the problem, what result the change should produce, what is already known from previous changes, and how the new change preserves the accepted route.'
    planScript = 'causal-change-plan.ps1'
  }
  executionGate = [pscustomobject]@{
    canProceed = $true
    beforeAct = 'Apply mustPreserve constraints and driftGuards before tool/code actions; maintain compact working memory with goal, constraints, current evidence, assumptions, and next action.'
    onDrift = 'Stop, report DRIFT_DETECTED, return to accepted constraints, then continue only after correction.'
    afterAct = 'Reflect after significant outcomes; extract reusable lessons for similar future tasks and promote repeated episodes into procedural memory/experience index.'
  }
  outputDiscipline = [pscustomobject]@{
    noRawLongMemory = $true
    compactCardFirst = $true
    noTodoWriteInZCode = $true
  }
  path = $outPath
}

Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "COGNITIVE_PREFLIGHT ok=$($result.ok) intent=$($result.intent) cards=$(@($result.cards).Count) path=$outPath" }
exit 0
