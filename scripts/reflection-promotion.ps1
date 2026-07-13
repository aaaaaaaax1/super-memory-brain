param(
  [ValidateSet('Analyze','Preview','Apply','List')]
  [string]$Mode = 'Analyze',
  [ValidateSet('user_correction','failed_verification','completed_fix','release_result','dispatch_result','manual')]
  [string]$TriggerType = 'manual',
  [string]$Summary = '',
  [string]$Evidence = '',
  [string]$Scope = 'super-memory-brain',
  [double]$MinConfidence = 0.7,
  [switch]$ConfirmPrivate,
  [switch]$AllowDuplicate,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$reflectionRoot = Join-Path $workspace 'reflection'
$candidateRoot = Join-Path $reflectionRoot 'candidates'
foreach ($dir in @($workspace,$reflectionRoot,$candidateRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
$outPath = Join-Path $workspace 'last-reflection-promotion.json'

function Limit-Text([string]$Value, [int]$Max = 420) {
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

function Test-PrivateText([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ($Value -match '(?i)(api[_-]?key|password|passwd|token|cookie|secret|private[_-]?key|authorization:)')
}

function New-Candidate([string]$Target, [string]$Title, [string]$Text, [double]$Confidence, [string[]]$EvidenceItems, [string]$Reason) {
  $idSeed = "$TriggerType|$Target|$Title|$Text"
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($idSeed)
  $hash = -join ($sha.ComputeHash($bytes)[0..5] | ForEach-Object { $_.ToString('x2') })
  return [pscustomobject]@{
    id = "learn-$hash"
    target = $Target
    title = Limit-Text $Title 120
    summary = Limit-Text $Text 700
    triggerType = $TriggerType
    scope = $Scope
    confidence = [Math]::Round($Confidence, 4)
    evidence = @($EvidenceItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    reason = Limit-Text $Reason 260
    reusable = ($Target -in @('experience','procedural_rule','skill_evolution'))
    privacyHit = (Test-PrivateText "$Title $Text $Evidence")
    duplicateCheck = [pscustomobject]@{ checked=$false; possibleDuplicate=$false; source='' }
    qualityCheck = [pscustomobject]@{ hasEvidence=(@($EvidenceItems).Count -gt 0); aboveThreshold=($Confidence -ge $MinConfidence); notNoise=($Text.Length -ge 20) }
    promotion = [pscustomobject]@{ wouldWrite=($Mode -eq 'Apply'); requiresApproval=($Target -in @('skill_evolution','procedural_rule') -or (Test-PrivateText "$Title $Text $Evidence")); applied=$false; command='' }
  }
}

$retro = Read-WorkspaceJson 'last-retrospective.json'
$task = Read-WorkspaceJson 'last-task-verification.json'
$ci = Read-WorkspaceJson 'last-ci.json'
$verify = Read-WorkspaceJson 'last-verify-package.json'
$preflight = Read-WorkspaceJson 'last-cognitive-preflight.json'
$enforce = Read-WorkspaceJson 'last-cognitive-enforce.json'
$drift = Read-WorkspaceJson 'last-runtime-drift-checkpoint.json'
$route = Read-WorkspaceJson 'last-route-checkpoint.json'
$integration = Read-WorkspaceJson 'last-integration-parity-check.json'
$causalReview = Read-WorkspaceJson 'last-causal-change-review.json'
$contractReplay = Read-WorkspaceJson 'last-integration-contract-replay.json'
$goalLock = Read-WorkspaceJson 'goal-route-lock.json'
$smartNext = $null
try {
  $smartRaw = @(& (Join-Path $PSScriptRoot 'smart-next.ps1') 'skill proficiency self learning closure verify regression before completion' -Json 2>$null)
  if ($smartRaw) { $smartNext = (($smartRaw -join "`n") | ConvertFrom-Json) }
} catch {}

if ([string]::IsNullOrWhiteSpace($Summary)) {
  if ($retro -and $retro.summary) { $Summary = [string]$retro.summary }
  elseif ($task -and $task.summary) { $Summary = [string]$task.summary }
  elseif ($drift -and @($drift.violations).Count -gt 0) { $Summary = 'Runtime drift was detected and should become a guarded lesson candidate.' }
  else { $Summary = 'No explicit summary supplied; analyze recent verification and cognitive artifacts.' }
}

$evidenceItems = New-Object System.Collections.ArrayList
foreach ($name in @('last-retrospective.json','last-task-verification.json','last-ci.json','last-verify-package.json','last-cognitive-preflight.json','last-cognitive-enforce.json','last-runtime-drift-checkpoint.json','goal-route-lock.json','last-route-checkpoint.json','last-integration-parity-check.json','last-causal-change-review.json','last-integration-contract-replay.json')) {
  if (Test-Path -LiteralPath (Join-Path $workspace $name)) { [void]$evidenceItems.Add($name) }
}
if (-not [string]::IsNullOrWhiteSpace($Evidence)) { [void]$evidenceItems.Add($Evidence) }

function Add-CandidateMetadata($Candidate, [string]$CandidateType, [string]$Kind, [string]$Severity, [string[]]$Expected, [string[]]$Observed, [string[]]$Missing, [string[]]$Signals) {
  $Candidate | Add-Member -NotePropertyName candidateType -NotePropertyValue $CandidateType -Force
  if ($CandidateType -eq 'gap') { $Candidate | Add-Member -NotePropertyName gapKind -NotePropertyValue $Kind -Force } else { $Candidate | Add-Member -NotePropertyName breakpointKind -NotePropertyValue $Kind -Force }
  $Candidate | Add-Member -NotePropertyName severity -NotePropertyValue $Severity -Force
  $Candidate | Add-Member -NotePropertyName expected -NotePropertyValue @($Expected) -Force
  $Candidate | Add-Member -NotePropertyName observed -NotePropertyValue @($Observed) -Force
  $Candidate | Add-Member -NotePropertyName missing -NotePropertyValue @($Missing) -Force
  $Candidate | Add-Member -NotePropertyName sourceSignals -NotePropertyValue @($Signals) -Force
  $Candidate | Add-Member -NotePropertyName safeAutonomy -NotePropertyValue ([pscustomobject]@{ candidateOnly=($Mode -ne 'Apply'); noDurableWriteWithoutApply=$true; requiresHumanApprovalForProcedureOrSkill=$true; noDirectSkillMutation=$true }) -Force
  return $Candidate
}

$candidates = New-Object System.Collections.ArrayList
if ($TriggerType -eq 'user_correction' -or ($drift -and $drift.unresolvedDrift -eq $true)) {
  [void]$candidates.Add((New-Candidate 'skill_evolution' 'User correction or drift should stage a bounded skill-evolution failure sample' $Summary 0.82 @($evidenceItems) 'Corrections and unresolved drift are reusable failure evidence, but must not mutate skills directly.'))
}
if (($verify -and $verify.ok -eq $true) -or ($ci -and $ci.ok -eq $true) -or $TriggerType -eq 'completed_fix') {
  [void]$candidates.Add((New-Candidate 'experience' 'Verified fix should become reusable experience when scoped and evidenced' $Summary 0.78 @($evidenceItems) 'Verified outcomes can be promoted into experience for future similar tasks.'))
}
if ($preflight -and @($preflight.driftGuards).Count -gt 0) {
  [void]$candidates.Add((New-Candidate 'procedural_rule' 'Repeated drift guards should remain procedural memory candidates' ($Summary + ' Guards: ' + ((@($preflight.driftGuards) | Select-Object -First 8) -join ', ')) 0.74 @($evidenceItems) 'Cognitive preflight provided reusable drift guards that should be available before similar work.'))
}
if ((-not $goalLock) -and ($Scope -match 'super-memory-brain|long|multi|agent|integration')) {
  $c = New-Candidate 'procedural_rule' 'Missing goal route lock can let long tasks lose the accepted line' 'Long-running or high-risk work should lock acceptedGoal, acceptedRoute, nonGoals, mustPreserve, and mustNotDriftTo before action.' 0.76 @($evidenceItems) 'No active goal-route-lock was available for route preservation.'
  [void]$candidates.Add((Add-CandidateMetadata $c 'gap' 'missing_route_lock' 'medium' @('active goal-route-lock.json') @('no goal-route-lock evidence') @('acceptedGoal','acceptedRoute','nonGoals') @('goal-route-lock')))
}
if ($route -and $route.unresolvedRouteDrift -eq $true) {
  foreach ($v in @($route.violations)) {
    $c = New-Candidate 'skill_evolution' 'ROUTE_DRIFT_DETECTED should become a logic-breakpoint candidate' ([string]$v.evidence) 0.84 @($evidenceItems) 'Route drift means execution left the user-approved goal line.'
    [void]$candidates.Add((Add-CandidateMetadata $c 'logic_breakpoint' 'goal_route_drift' ([string]$v.severity) @('current action follows acceptedGoal and acceptedRoute') @([string]$v.evidence) @('route realignment') @([string]$v.code)))
  }
}
if ($integration -and $integration.unresolvedIntegrationDrift -eq $true) {
  foreach ($d in @($integration.drifts)) {
    $kind = if ([string]$d.code -eq 'missing_acceptance_path') { 'false_completion' } elseif ([string]$d.code -eq 'module_context_changed') { 'module_context_changed' } elseif ([string]$d.code -eq 'scattered_assembly') { 'scattered_assembly' } else { 'integration_drift' }
    $c = New-Candidate 'procedural_rule' 'INTEGRATION_DRIFT_DETECTED should become a guarded integration lesson' ([string]$d.evidence) 0.83 @($evidenceItems) 'Verified module behavior no longer proves main-system behavior when context or acceptance path changes.'
    [void]$candidates.Add((Add-CandidateMetadata $c 'logic_breakpoint' $kind ([string]$d.severity) @('module smoke OK','integration smoke OK','user-facing acceptance OK','verified contract parity') @([string]$d.evidence) @('integration parity or acceptance evidence') @([string]$d.code)))
  }
}
if ($causalReview -and ($causalReview.ok -ne $true -or @($causalReview.gaps).Count -gt 0 -or [string]$causalReview.expectedVsActual.decision -in @('revise','rollback'))) {
  $status = if ([string]$causalReview.expectedVsActual.decision -in @('revise','rollback')) { 'hypothesis_failed_or_revised' } else { 'causal_review_gap' }
  $c = New-Candidate 'procedural_rule' 'Causal hypothesis review should feed learning candidates' ([string]$causalReview.actualResult) 0.8 @($evidenceItems) 'Expected-vs-actual review prevents failed or unproven hypotheses from becoming durable lessons.'
  [void]$candidates.Add((Add-CandidateMetadata $c 'logic_breakpoint' $status 'medium' @('expected optimization matches actual evidence','decision keep/revise/rollback is explicit') @([string]$causalReview.actualResult) @('confirmed expected-vs-actual evidence') @('causal-change-review')))
}
if ($contractReplay -and ($contractReplay.unresolvedBehaviorMismatch -eq $true -or $contractReplay.ok -ne $true)) {
  foreach ($m in @($contractReplay.mismatches)) {
    $c = New-Candidate 'procedural_rule' 'Integration contract replay mismatch should block completion learning' ([string]$m.evidence) 0.84 @($evidenceItems) 'Behavior-level replay catches cases where standalone module verification no longer matches integrated behavior.'
    [void]$candidates.Add((Add-CandidateMetadata $c 'logic_breakpoint' 'integration_behavior_mismatch' ([string]$m.severity) @('integrated output matches verified contract output') @([string]$m.evidence) @('matching behavior replay') @([string]$m.code)))
  }
}
if ($enforce -and $enforce.ok -ne $true) {
  foreach ($v in @($enforce.violations)) {
    $c = New-Candidate 'experience' 'Cognitive enforcement gap should remain visible before similar work' ([string]$v) 0.78 @($evidenceItems) 'High-risk execution-control prerequisite was missing or stale.'
    [void]$candidates.Add((Add-CandidateMetadata $c 'gap' 'missing_preflight' 'medium' @('fresh cognitive-preflight','mustPreserve','driftGuards') @([string]$v) @('execution-control prerequisite') @([string]$v)))
  }
}
if ($preflight -and @($preflight.procedureExpectations).Count -gt 0) {
  $evidenceText = ($Summary + ' ' + ($Evidence -join ' '))
  foreach ($pe in @($preflight.procedureExpectations | Select-Object -First 4)) {
    foreach ($check in @($pe.verificationChecklist | Select-Object -First 4)) {
      if (-not [string]::IsNullOrWhiteSpace($check) -and -not $evidenceText.ToLowerInvariant().Contains(([string]$check).ToLowerInvariant())) {
        $c = New-Candidate 'procedural_rule' 'Procedure checklist gap should be reviewed' "Missing procedure verification checklist item: $check" 0.71 @($evidenceItems) 'Procedure card expectation was available but not present in current evidence.'
        [void]$candidates.Add((Add-CandidateMetadata $c 'gap' 'missing_procedure_check' 'low' @([string]$check) @('not found in current summary/evidence') @([string]$check) @([string]$pe.cardId)))
      }
    }
  }
}
if ($smartNext -and $smartNext.completionSkillAudit) {
  $audit = $smartNext.completionSkillAudit
  $presentRoles = @($audit.presentRoles | ForEach-Object { [string]$_ })
  $missingRoles = @($audit.missingRoles | ForEach-Object { [string]$_ })
  $routeNames = @($smartNext.orcComposition.routePlan | ForEach-Object { [string]$_.name })
  if ($missingRoles.Count -gt 0) {
    $c = New-Candidate 'skill_evolution' 'Skill proficiency gap: expected routed skill roles were missing' ('Missing roles: ' + ($missingRoles -join ', ')) 0.82 @($evidenceItems) 'Completion skill audit found required roles missing from ORC route plan.'
    [void]$candidates.Add((Add-CandidateMetadata $c 'gap' 'missing_skill_role' 'medium' @($audit.expectedRoles) @($presentRoles) @($missingRoles) @('completionSkillAudit','skill_proficiency_self_learning_loop')))
      } else {
        $c = New-Candidate 'experience' 'Skill proficiency success sample should update routing confidence' ('Successful completion skill audit roles: ' + ($presentRoles -join ', ') + '; route: ' + (($routeNames | Select-Object -First 10) -join ' -> ')) 0.77 @($evidenceItems) 'A successful ORC route plan with no missing completion-audit roles can improve future skill selection confidence for skill proficiency self-learning.'
        [void]$candidates.Add((Add-CandidateMetadata $c 'gap' 'skill_proficiency_success_sample' 'low' @('pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair') @($presentRoles) @() @('completionSkillAudit','skill_proficiency_self_learning_loop')))
      }
}
if ($candidates.Count -eq 0) {
  [void]$candidates.Add((New-Candidate 'none' 'No durable learning candidate' $Summary 0.4 @($evidenceItems) 'Insufficient verified reusable evidence; keep as retrospective only.'))
}

foreach ($candidate in @($candidates)) {
  try {
    $lessonRaw = @(& (Join-Path $PSScriptRoot 'lesson-replay.ps1') -Query $candidate.summary -Json 2>$null)
    if ($lessonRaw) {
      $lesson = (($lessonRaw -join "`n") | ConvertFrom-Json)
      $candidate.duplicateCheck.checked = $true
      $candidate.duplicateCheck.possibleDuplicate = (@($lesson.matches).Count -gt 0)
      $candidate.duplicateCheck.source = 'lesson-replay.ps1'
    }
  } catch {}
  if ($candidate.privacyHit -and -not $ConfirmPrivate) { $candidate.promotion.wouldWrite = $false; $candidate.promotion.requiresApproval = $true }
  if ($candidate.duplicateCheck.possibleDuplicate -and -not $AllowDuplicate) { $candidate.promotion.wouldWrite = $false }
  if (-not $candidate.qualityCheck.hasEvidence -or -not $candidate.qualityCheck.aboveThreshold -or -not $candidate.qualityCheck.notNoise) { $candidate.promotion.wouldWrite = $false }
  try {
    $scopeRaw = @(& (Join-Path $PSScriptRoot 'lesson-scope-gate.ps1') -Lesson $candidate.summary -Scope $Scope -Evidence @($candidate.evidence) -AppliesWhen $candidate.reason -DoesNotApplyWhen 'Outside the stated scope or without matching evidence.' -CounterExamples 'Future verification may falsify this candidate.' -ValidationConditions 'Before reuse, verify matching scope, evidence freshness, and expected outcome in the target task.' -Confidence $candidate.confidence -Json 2>$null)
    if ($scopeRaw) {
      $scopeGate = (($scopeRaw -join "`n") | ConvertFrom-Json)
      $candidate | Add-Member -NotePropertyName scopeGate -NotePropertyValue ([pscustomobject]@{ checked=$true; ok=$scopeGate.ok; gaps=@($scopeGate.gaps).Count; source='lesson-scope-gate.ps1' }) -Force
      if ($scopeGate.ok -ne $true) { $candidate.promotion.wouldWrite = $false }
    }
  } catch { $candidate | Add-Member -NotePropertyName scopeGate -NotePropertyValue ([pscustomobject]@{ checked=$false; ok=$false; error=$_.Exception.Message; source='lesson-scope-gate.ps1' }) -Force; $candidate.promotion.wouldWrite = $false }
  $candidate.promotion.command = switch ($candidate.target) {
    'experience' { 'learn-memory.ps1 -Layer experience -Preview/-Apply path' }
    'procedural_rule' { 'write-experience.ps1 draft procedure candidate; user approval before rule adoption' }
    'skill_evolution' { 'skill-evolution.ps1 -Mode Capture/Propose' }
    'memory' { 'learn-memory.ps1 -Layer project' }
    default { 'no durable promotion' }
  }
}

$applied = New-Object System.Collections.ArrayList
if ($Mode -eq 'Apply') {
  foreach ($candidate in @($candidates | Where-Object { $_.promotion.wouldWrite -eq $true -and $_.target -ne 'none' })) {
    $candidatePath = Join-Path $candidateRoot ($candidate.id + '.json')
    Write-JsonUtf8NoBom $candidatePath $candidate 10
    if ($candidate.target -eq 'skill_evolution') {
      $null = & (Join-Path $PSScriptRoot 'skill-evolution.ps1') -Mode Capture -Text $candidate.summary -Source 'reflection-promotion' -Json 2>$null
      $candidate.promotion.applied = $true
      [void]$applied.Add($candidate.id)
    } elseif ($candidate.target -in @('experience','procedural_rule','memory')) {
      $layer = if ($candidate.target -eq 'memory') { 'project' } else { 'experience' }
      $args = @('-Text', $candidate.summary, '-Layer', $layer, '-Title', $candidate.title, '-Json')
      if ($ConfirmPrivate) { $args += '-ConfirmPrivate' }
      if ($AllowDuplicate) { $args += '-AllowDuplicate' }
      $null = & (Join-Path $PSScriptRoot 'learn-memory.ps1') @args 2>$null
      $candidate.promotion.applied = $true
      [void]$applied.Add($candidate.id)
    }
  }
} else {
  foreach ($candidate in @($candidates)) {
    $candidatePath = Join-Path $candidateRoot ($candidate.id + '.json')
    Write-JsonUtf8NoBom $candidatePath $candidate 10
  }
}

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.reflection-promotion.v1'
  version = (Get-SuperBrainManifest $Root).version
  mode = $Mode
  triggerType = $TriggerType
  summary = Limit-Text $Summary 500
  safety = [pscustomobject]@{
    defaultNoDurableWrite = ($Mode -ne 'Apply')
    privacyCheck = $true
    duplicateCheck = $true
    evidenceCheck = $true
    confidenceThreshold = $MinConfidence
    noDirectSkillMutation = $true
  }
  candidates = @($candidates)
  applied = @($applied)
  nextAction = if ($Mode -eq 'Apply') { 'Review applied learning outputs and run verification.' } else { 'Review candidates; use -Mode Apply only for scoped, evidenced, non-private or confirmed learning.' }
  path = $outPath
}

Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else { Write-Host "REFLECTION_PROMOTION mode=$Mode candidates=$(@($candidates).Count) applied=$(@($applied).Count) path=$outPath" }
exit 0
