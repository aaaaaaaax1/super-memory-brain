param(
  [switch]$Json,
  [switch]$AllowPrivacyRisk,
  [switch]$AllowActiveCheckpoint,
  [switch]$ContractOnly,
  [switch]$PackageVerificationInProgress,
  [switch]$RequireEngineeringDecision,
  [int]$MaxEvidenceAgeMinutes = 720,
  [string]$TaskId = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$manifest = Get-SuperBrainManifest $Root
$currentVersion = [string]$manifest.version
if ($PackageVerificationInProgress -and -not $ContractOnly) { throw 'PACKAGE_VERIFICATION_IN_PROGRESS_REQUIRES_CONTRACT_ONLY' }
if ($PackageVerificationInProgress) { $TaskId = '' }

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Read-CheckedAt($Obj) {
  if (-not $Obj -or [string]::IsNullOrWhiteSpace([string]$Obj.checkedAt)) { return $null }
  try { return [datetime]::Parse([string]$Obj.checkedAt) } catch { return $null }
}
function Test-CurrentPackageEvidence($Obj) {
  if (-not $Obj -or $Obj.ok -ne $true) { return $false }
  if ([string]$Obj.version -ne $currentVersion) { return $false }
  if ([string]::IsNullOrWhiteSpace([string]$Obj.packageRoot)) { return $false }
  try {
    if ((Get-NormalizedSuperBrainRoot ([string]$Obj.packageRoot)) -ne (Get-NormalizedSuperBrainRoot $Root)) { return $false }
  } catch { return $false }
  $checkedAt = Read-CheckedAt $Obj
  if (-not $checkedAt -or $checkedAt -gt (Get-Date).AddMinutes(5)) { return $false }
  return (((Get-Date) - $checkedAt).TotalMinutes -le $MaxEvidenceAgeMinutes)
}
function Get-PackageEvidenceReason($Obj) {
  if (-not $Obj) { return 'missing evidence' }
  if ($Obj.ok -ne $true) { return 'ok=false' }
  if ([string]$Obj.version -ne $currentVersion) { return "version=$($Obj.version) required=$currentVersion" }
  if ([string]::IsNullOrWhiteSpace([string]$Obj.packageRoot)) { return 'packageRoot missing' }
  try {
    if ((Get-NormalizedSuperBrainRoot ([string]$Obj.packageRoot)) -ne (Get-NormalizedSuperBrainRoot $Root)) { return "packageRoot=$($Obj.packageRoot) required=$Root" }
  } catch { return 'packageRoot invalid' }
  $checkedAt = Read-CheckedAt $Obj
  if (-not $checkedAt) { return 'checkedAt missing or invalid' }
  if ($checkedAt -gt (Get-Date).AddMinutes(5)) { return "checkedAt is in the future: $checkedAt" }
  return "ageMinutes=$([Math]::Round(((Get-Date) - $checkedAt).TotalMinutes,2)) max=$MaxEvidenceAgeMinutes"
}
function Safe-TaskId([string]$Value) { if ([string]::IsNullOrWhiteSpace($Value)) { return '' }; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if ([string]::IsNullOrWhiteSpace($safe)) { return '' }; if ($safe.Length -gt 120) { return $safe.Substring(0,120) }; return $safe }
function Read-TaskScopedJson([string]$RelativeDir,[string]$FallbackName) {
  $safe = Safe-TaskId $TaskId
  if (-not [string]::IsNullOrWhiteSpace($safe)) {
    $root = Join-Path (Join-Path $workspace 'guard-state') $RelativeDir
    $candidate = Join-Path $root ($safe + '.json')
    if (Test-Path -LiteralPath $candidate) { try { return Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    $taskDir = Join-Path $root $safe
    if (Test-Path -LiteralPath $taskDir) {
      $latest = Get-ChildItem -LiteralPath $taskDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($latest) { try { return Get-Content -LiteralPath $latest.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    }
  }
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return $null }
  $fallback = Read-WorkspaceJson $FallbackName
  if ($fallback -and [string]$fallback.taskId -eq $TaskId) { return $fallback }
  return $null
}
function Test-TaskScopedEvidence($Obj) {
  if (-not $Obj) { return $true }
  if ($ContractOnly) { return $true }
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
  if ([string]$Obj.taskId -ne $TaskId) { return $false }
  if ($Obj.version -and [string]$Obj.version -ne $currentVersion) { return $false }
  $checkedAt = if ($Obj.checkedAt) { Read-CheckedAt $Obj } elseif ($Obj.timestamp) { try { [datetime]::Parse([string]$Obj.timestamp) } catch { $null } } else { $null }
  if ($checkedAt -and ($checkedAt -gt (Get-Date).AddMinutes(5) -or ((Get-Date) - $checkedAt).TotalMinutes -gt $MaxEvidenceAgeMinutes)) { return $false }
  if ($currentTaskContext -and $currentTaskContext.workspaceKey -and $Obj.workspaceKey) {
    if (-not (Test-SuperBrainWorkspaceKey ([string]$Obj.workspaceKey) ([string]$currentTaskContext.workspaceKey))) { return $false }
  }
  if ($Obj.packageRoot) {
    try {
      if ((Get-NormalizedSuperBrainRoot ([string]$Obj.packageRoot)) -ne (Get-NormalizedSuperBrainRoot $Root)) { return $false }
    } catch { return $false }
  }
  return $true
}
function U([int[]]$Codes) { return -join ($Codes | ForEach-Object { [char]$_ }) }
function Test-EngineeringJudgmentIntent([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  $lower = $Value.ToLowerInvariant()
  foreach ($term in @('fix','debug','repair','optimize','optimization','architecture','architect','root cause','tradeoff','trade-off','best option','optimal','performance','bottleneck','regression','refactor','migration','failure analysis')) {
    if ($lower.Contains($term)) { return $true }
  }
  foreach ($term in @((U @(20462,22797)),(U @(20248,21270)),(U @(26550,26500)),(U @(26681,22240)),(U @(26368,20248)),(U @(26368,20339)),(U @(24615,33021)),(U @(37325,26500)),(U @(25925,38556)),(U @(35774,35745)),(U @(20915,31574)))) {
    if ($Value.Contains($term)) { return $true }
  }
  return $false
}
function Test-MutationIntent([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  $lower = $Value.ToLowerInvariant()
  foreach ($term in @('add','implement','change','modify','edit','write','fix','debug','repair','optimize','refactor','migrate','create','delete','install','upgrade','patch','build','deploy','feature','mutation','code change','file change')) {
    if ($lower.Contains($term)) { return $true }
  }
  foreach ($term in @((U @(20462,22797)),(U @(20248,21270)),(U @(25913,21151)),(U @(20889,20837)),(U @(28155,21152)),(U @(23454,29616)),(U @(23433,35013)),(U @(37096,32626)),(U @(21024,38500)),(U @(36801,31227)),(U @(23436,21892)),(U @(37325,26500)),(U @(26500,24314)),(U @(21464,26356)),(U @(26356,26032)),(U @(24320,21457)))) {
    if ($Value.Contains($term)) { return $true }
  }
  return $false
}

$compatibilityTaskContext = Read-WorkspaceJson 'current-task-context.json'
if (-not $ContractOnly -and [string]::IsNullOrWhiteSpace($TaskId) -and $compatibilityTaskContext -and [string]$compatibilityTaskContext.status -eq 'active') { $TaskId = [string]$compatibilityTaskContext.taskId }
$currentTaskContext = $compatibilityTaskContext
if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
  $scopedContextPath = Join-Path (Join-Path (Join-Path $workspace 'guard-state') 'current-task-contexts') ((Safe-TaskId $TaskId) + '.json')
  if (Test-Path -LiteralPath $scopedContextPath) { try { $currentTaskContext = Get-Content -LiteralPath $scopedContextPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
}
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$smartNextAudit = $null
$completionAuditExpectedRoles = @('pre_action_constraint','challenge_gate','evidence_grounding','engineering_decision','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair')
try {
  $smartRaw = @(& (Join-Path $PSScriptRoot 'smart-next.ps1') -Text 'completion skill audit verify test regression before completion' -Json 2>$null)
  if ($smartRaw) { $smartNextAudit = (($smartRaw -join "`n") | ConvertFrom-Json) }
} catch {}
$activeCheckpoint = $null
if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
  $scopedCheckpointPath = Join-Path (Join-Path (Join-Path $workspace 'runtime-state') 'checkpoints\active') ((Safe-TaskId $TaskId) + '.json')
  if (Test-Path -LiteralPath $scopedCheckpointPath) { try { $activeCheckpoint = Get-Content -LiteralPath $scopedCheckpointPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
} else {
  $activeCheckpoint = Read-WorkspaceJson 'active-checkpoint.json'
}
$constraintPreflight = Read-WorkspaceJson 'last-accepted-constraints-preflight.json'
$driftCheckpoint = Read-WorkspaceJson 'last-runtime-drift-checkpoint.json'
$routeCheckpoint = Read-TaskScopedJson 'route-checkpoints' 'last-route-checkpoint.json'
$integrationParity = Read-TaskScopedJson 'integration-parity-check' 'last-integration-parity-check.json'
$causalReview = Read-TaskScopedJson 'change-causality-reviews' 'last-causal-change-review.json'
$contractReplay = Read-TaskScopedJson 'integration-contract-replay' 'last-integration-contract-replay.json'
$engineeringDecisionRaw = Read-TaskScopedJson 'engineering-decisions' 'last-engineering-decision-gate.json'
$engineeringDecision = if($engineeringDecisionRaw -and $engineeringDecisionRaw.latest){$engineeringDecisionRaw.latest}else{$engineeringDecisionRaw}
$contextCurrent = $false
if ($currentTaskContext -and [string]$currentTaskContext.status -eq 'active' -and $currentTaskContext.stale -ne $true -and [string]$currentTaskContext.version -eq $currentVersion) {
  try { $contextCurrent = ([datetime]::Parse([string]$currentTaskContext.expiresAt) -gt (Get-Date)) } catch { $contextCurrent = $false }
}
$contextApplies = (-not $ContractOnly -and $contextCurrent -and ([string]::IsNullOrWhiteSpace($TaskId) -or [string]$currentTaskContext.taskId -eq $TaskId))
$engineeringRequired = ([bool]$RequireEngineeringDecision -or ($contextApplies -and (Test-EngineeringJudgmentIntent ([string]$currentTaskContext.acceptedGoal))))
$taskIdentityRequired = (-not $ContractOnly)
$taskIdentityOk = (-not $taskIdentityRequired -or -not [string]::IsNullOrWhiteSpace($TaskId))
$taskScopedLastTask = [bool]($lastTask -and (Test-TaskScopedEvidence $lastTask))
$taskVerificationOk = if ($ContractOnly) { $true } else { [bool]($lastTask -and $lastTask.ok -eq $true -and $taskScopedLastTask) }
$changedFileEvidence = [bool]($taskScopedLastTask -and @($lastTask.changed | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0)
$lastTaskSummaryEvidence = if ($taskScopedLastTask) { [string]$lastTask.summary } else { '' }
$lastTaskChangedEvidence = if ($taskScopedLastTask) { (@($lastTask.changed) -join ' ') } else { '' }
$lastTaskCommandEvidence = if ($taskScopedLastTask) { (@($lastTask.commands) -join ' ') } else { '' }
$taskContextGoalEvidence = if ($contextApplies) { [string]$currentTaskContext.acceptedGoal } else { '' }
$taskContextRouteEvidence = if ($contextApplies) { (@($currentTaskContext.acceptedRoute) -join ' ') } else { '' }
$mutationEvidenceText = @(
  $taskContextGoalEvidence,
  $taskContextRouteEvidence,
  [string]$activeCheckpoint.goal,
  [string]$activeCheckpoint.currentStep,
  [string]$activeCheckpoint.currentPhase,
  $lastTaskSummaryEvidence,
  $lastTaskChangedEvidence,
  $lastTaskCommandEvidence
) -join ' '
$mutationIntent = [bool](Test-MutationIntent $mutationEvidenceText)
$causalReviewRequired = [bool]($taskIdentityRequired -and ($engineeringRequired -or $mutationIntent -or $changedFileEvidence))

$checks = @()
$verifyOk = ($PackageVerificationInProgress -or (Test-CurrentPackageEvidence $lastVerify))
$hotRefreshOk = ($PackageVerificationInProgress -or (Test-CurrentPackageEvidence $lastHotRefresh))
$checks += [pscustomobject]@{ name='task-identity'; ok=$taskIdentityOk; evidence=if($ContractOnly){'contract-only validation does not claim a task completion'}elseif($taskIdentityOk){"taskId=$TaskId"}else{'missing current TaskId; refuse unscoped completion evidence'} }
$checks += [pscustomobject]@{ name='verify-package'; ok=$verifyOk; evidence=if ($PackageVerificationInProgress) { 'self-verification in progress; final verify-package result remains authoritative' } elseif ($lastVerify) { "$(Get-PackageEvidenceReason $lastVerify)" } else { 'missing last-verify-package.json' } }
$checks += [pscustomobject]@{ name='hot-refresh'; ok=$hotRefreshOk; evidence=if ($PackageVerificationInProgress) { 'self-verification in progress; hot-refresh freshness is deferred to package verification' } elseif ($lastHotRefresh) { "$(Get-PackageEvidenceReason $lastHotRefresh)" } else { 'missing last-hot-refresh.json' } }
$checks += [pscustomobject]@{ name='task-verification'; ok=$taskVerificationOk; evidence=if ($ContractOnly) { 'contract-only validation does not reuse task verification' } elseif ($lastTask) { "taskId=$($lastTask.taskId) requiredTaskId=$TaskId match=$taskScopedLastTask version=$($lastTask.version) ok=$($lastTask.ok) summary=$($lastTask.summary)" } else { 'missing last-task-verification.json' } }
$skillAudit = if ($smartNextAudit) { $smartNextAudit.completionSkillAudit } else { $null }
$skillAuditMissing = if ($skillAudit) { @($skillAudit.missingRoles) } else { @('missing_completion_skill_audit') }
$skillAuditOk = ($skillAudit -and $skillAudit.required -eq $true -and @($skillAuditMissing).Count -eq 0)
$checks += [pscustomobject]@{ name='completion-skill-audit'; ok=$skillAuditOk; evidence=if($skillAudit){"source=smart-next.ps1 auditMode=$($skillAudit.auditMode) presentRoles=$((@($skillAudit.presentRoles)-join ',')) missingRoles=$((@($skillAuditMissing)-join ','))"}else{'missing smart-next completionSkillAudit'} }
$constraintConflictCount = if ($constraintPreflight) { @($constraintPreflight.conflicts).Count } else { 0 }
$constraintOk = (-not $constraintPreflight) -or ($constraintPreflight.ok -eq $true -and $constraintConflictCount -eq 0 -and (-not $taskScopedLastTask -or $lastTask.constraintsPreserved -ne $false))
$checks += [pscustomobject]@{ name='accepted-constraints-preflight'; ok=$constraintOk; evidence=if ($constraintPreflight) { "required=$($constraintPreflight.required) constraints=$(@($constraintPreflight.constraints).Count) conflicts=$constraintConflictCount guardHash=$($constraintPreflight.guardHash)" } else { 'none' } }
$activeCheckpointTaskOk = ($ContractOnly -or (Test-TaskScopedEvidence $activeCheckpoint))
$activeCheckpointOk = ($ContractOnly -or ($activeCheckpointTaskOk -and (-not ($activeCheckpoint -and [string]$activeCheckpoint.status -eq 'active') -or $AllowActiveCheckpoint)))
$checks += [pscustomobject]@{ name='active-checkpoint'; ok=$activeCheckpointOk; evidence=if ($activeCheckpoint) { "status=$($activeCheckpoint.status) taskId=$($activeCheckpoint.taskId) taskScopeOk=$activeCheckpointTaskOk allowActiveCheckpoint=$([bool]$AllowActiveCheckpoint)" } else { 'none' } }
$driftOk = (-not $driftCheckpoint) -or ($driftCheckpoint.unresolvedDrift -ne $true -and $driftCheckpoint.ok -eq $true)
$checks += [pscustomobject]@{ name='runtime-drift-checkpoint'; ok=$driftOk; evidence=if ($driftCheckpoint) { "status=$($driftCheckpoint.status) unresolvedDrift=$($driftCheckpoint.unresolvedDrift) violations=$(@($driftCheckpoint.violations).Count)" } else { 'none' } }
$checks += [pscustomobject]@{ name='task-scoped-route-checkpoint'; ok=(Test-TaskScopedEvidence $routeCheckpoint); evidence=if($routeCheckpoint){"taskId=$($routeCheckpoint.taskId) requiredTaskId=$TaskId"}else{'none'} }
$routeOk = (-not $routeCheckpoint) -or (($routeCheckpoint.unresolvedRouteDrift -ne $true -and $routeCheckpoint.ok -eq $true) -and (Test-TaskScopedEvidence $routeCheckpoint))
$checks += [pscustomobject]@{ name='route-checkpoint'; ok=$routeOk; evidence=if ($routeCheckpoint) { "status=$($routeCheckpoint.status) unresolvedRouteDrift=$($routeCheckpoint.unresolvedRouteDrift) violations=$(@($routeCheckpoint.violations).Count)" } else { 'none' } }
$checks += [pscustomobject]@{ name='task-scoped-integration-parity'; ok=(Test-TaskScopedEvidence $integrationParity); evidence=if($integrationParity){"taskId=$($integrationParity.taskId) requiredTaskId=$TaskId"}else{'none'} }
$integrationOk = (-not $integrationParity) -or (($integrationParity.unresolvedIntegrationDrift -ne $true -and $integrationParity.ok -eq $true) -and (Test-TaskScopedEvidence $integrationParity))
$checks += [pscustomobject]@{ name='integration-parity-check'; ok=$integrationOk; evidence=if ($integrationParity) { "unresolvedIntegrationDrift=$($integrationParity.unresolvedIntegrationDrift) drifts=$(@($integrationParity.drifts).Count) module=$($integrationParity.module) moduleVerification=$($integrationParity.moduleVerification.status) integrationVerification=$($integrationParity.integrationVerification.status) userAcceptanceVerification=$($integrationParity.userAcceptanceVerification.status)" } else { 'none' } }
$checks += [pscustomobject]@{ name='task-scoped-causal-review'; ok=(Test-TaskScopedEvidence $causalReview); evidence=if($causalReview){"taskId=$($causalReview.taskId) requiredTaskId=$TaskId"}else{'none'} }
$causalReviewTaskScoped = ($ContractOnly -or (Test-TaskScopedEvidence $causalReview))
$causalReviewQualityOk = if ($ContractOnly) { $true } else { [bool]($causalReview -and $causalReview.ok -eq $true -and @($causalReview.gaps).Count -eq 0 -and $causalReviewTaskScoped -and -not [string]::IsNullOrWhiteSpace([string]$causalReview.actualResult) -and @($causalReview.evidence).Count -gt 0 -and [string]$causalReview.expectedVsActual.decision -in @('keep','revise','rollback') -and $causalReview.expectedVsActual.expectedPresent -eq $true -and $causalReview.expectedVsActual.actualPresent -eq $true -and $causalReview.expectedVsActual.weakTermMatch -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$causalReview.verificationMethod) -and [string]$causalReview.planTaskId -eq $TaskId -and $causalReview.planTaskMatch -eq $true) }
$postMutationReviewOk = [bool](-not $causalReviewRequired -or ($causalReviewQualityOk -and [string]$causalReview.expectedVsActual.decision -eq 'keep'))
$checks += [pscustomobject]@{ name='post-mutation-review'; ok=$postMutationReviewOk; evidence=if($causalReviewRequired){if($causalReview){"required=true taskId=$($causalReview.taskId) requiredTaskId=$TaskId qualityOk=$causalReviewQualityOk decision=$($causalReview.expectedVsActual.decision)"}else{"required=true missing task-scoped causal review; mutationIntent=$mutationIntent changedFileEvidence=$changedFileEvidence"}}else{"required=false mutationIntent=$mutationIntent changedFileEvidence=$changedFileEvidence"} }
$causalReviewOk = if ($ContractOnly) { $true } else { (-not $causalReview) -or $causalReviewQualityOk }
$checks += [pscustomobject]@{ name='causal-change-review'; ok=$causalReviewOk; evidence=if ($causalReview) { "decision=$($causalReview.expectedVsActual.decision) gaps=$(@($causalReview.gaps).Count) expectedPresent=$($causalReview.expectedVsActual.expectedPresent) actualPresent=$($causalReview.expectedVsActual.actualPresent)" } else { 'none' } }
$checks += [pscustomobject]@{ name='task-scoped-integration-contract-replay'; ok=(Test-TaskScopedEvidence $contractReplay); evidence=if($contractReplay){"taskId=$($contractReplay.taskId) requiredTaskId=$TaskId"}else{'none'} }
$contractReplayOk = if ($ContractOnly) { $true } else { (-not $contractReplay) -or (($contractReplay.unresolvedBehaviorMismatch -ne $true -and $contractReplay.ok -eq $true) -and (Test-TaskScopedEvidence $contractReplay)) }
$checks += [pscustomobject]@{ name='integration-contract-replay'; ok=$contractReplayOk; evidence=if ($contractReplay) { "module=$($contractReplay.module) normalizedMatch=$($contractReplay.normalizedMatch) mismatches=$(@($contractReplay.mismatches).Count)" } else { 'none' } }
$engineeringTaskMatch = (Test-TaskScopedEvidence $engineeringDecision)
$engineeringResolutionOk = (-not $engineeringDecision -or [string]$engineeringDecision.rootCause.status -eq 'verified' -or -not [string]::IsNullOrWhiteSpace([string]$engineeringDecision.rootCause.discriminatingTestEvidence))
$engineeringDecisionOk = (-not $engineeringRequired -or ($engineeringDecision -and $engineeringDecision.ok -eq $true -and @($engineeringDecision.gaps).Count -eq 0 -and $engineeringDecision.epistemicGrounding.factsSupported -eq $true -and $engineeringDecision.optimality.qualified -eq $true -and $engineeringResolutionOk -and @($engineeringDecision.executionChain).Count -gt 0 -and @($engineeringDecision.acceptanceCriteria).Count -gt 0 -and $engineeringTaskMatch))
$checks += [pscustomobject]@{ name='engineering-decision-gate'; ok=$engineeringDecisionOk; evidence=if($engineeringRequired){if($engineeringDecision){"taskId=$($engineeringDecision.taskId) requiredTaskId=$TaskId decisionId=$($engineeringDecision.decisionId) factsSupported=$($engineeringDecision.epistemicGrounding.factsSupported) optimalityQualified=$($engineeringDecision.optimality.qualified) rootCauseStatus=$($engineeringDecision.rootCause.status) discriminatingTestEvidence=$(-not [string]::IsNullOrWhiteSpace([string]$engineeringDecision.rootCause.discriminatingTestEvidence)) gaps=$(@($engineeringDecision.gaps).Count)"}else{'missing valid task-scoped engineering decision'}}else{'not_required'} }

function Add-JsonScriptCheck([string]$Name, [string]$ScriptName) {
  $ok = $false
  $evidence = ''
  try {
    $output = & (Join-Path $PSScriptRoot $ScriptName) -Json
    $obj = $output | ConvertFrom-Json
    $ok = ($obj.ok -eq $true)
    $evidence = "ok=$($obj.ok)"
  } catch { $evidence = $_.Exception.Message }
  return [pscustomobject]@{ name=$Name; ok=$ok; evidence=$evidence }
}

$checks += Add-JsonScriptCheck 'roadmap-manager' 'roadmap-manager.ps1'
$checks += Add-JsonScriptCheck 'memory-regression' 'memory-regression-checker.ps1'
$checks += Add-JsonScriptCheck 'task-state' 'task-state-reporter.ps1'
$checks += Add-JsonScriptCheck 'review-gate' 'team-task-review-gate.ps1'

$privacyOk = $false
$privacyEvidence = ''
try {
  $privacyOutput = & (Join-Path $PSScriptRoot 'privacy-sentinel.ps1') -Json
  $privacy = $privacyOutput | ConvertFrom-Json
  $privacyOk = ($privacy.ok -eq $true -or $AllowPrivacyRisk)
  $privacyEvidence = "privatePatternHits=$($privacy.privatePatternHits) allowPrivacyRisk=$([bool]$AllowPrivacyRisk)"
} catch { $privacyEvidence = $_.Exception.Message }
$checks += [pscustomobject]@{ name='privacy-sentinel'; ok=$privacyOk; evidence=$privacyEvidence }

$failed = @($checks | Where-Object { $_.ok -ne $true })
$allChecksOk = ($failed.Count -eq 0)
$result = [pscustomobject]@{
  ok = $allChecksOk
  completionAuthorized = ($allChecksOk -and -not $PackageVerificationInProgress)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  allowPrivacyRisk = [bool]$AllowPrivacyRisk
  contractOnly = [bool]$ContractOnly
  packageVerificationInProgress = [bool]$PackageVerificationInProgress
  engineeringJudgmentRequired = $engineeringRequired
  postMutationReviewRequired = $causalReviewRequired
  postMutationReview = [pscustomobject]@{ required=$causalReviewRequired; mutationIntent=$mutationIntent; changedFileEvidence=$changedFileEvidence; evidenceText=if($causalReviewRequired){$mutationEvidenceText}else{''}; qualityOk=$causalReviewQualityOk; decision=if($causalReview){[string]$causalReview.expectedVsActual.decision}else{''}; acceptance='Mutation-bearing completion requires task-scoped causal review with actual result, evidence, and decision=keep.' }
  engineeringDecisionId = if($engineeringDecision){$engineeringDecision.decisionId}else{''}
  taskId = $TaskId
  failed = $failed.Count
  checks = @($checks)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "COMPLETION_GUARD ok=$($result.ok) completionAuthorized=$($result.completionAuthorized) failed=$($result.failed) allowPrivacyRisk=$($result.allowPrivacyRisk)"
  foreach ($check in @($checks)) { Write-Host "COMPLETION_GUARD_CHECK name=$($check.name) ok=$($check.ok) evidence=$($check.evidence)" }
}
if (-not $result.ok) { exit 1 }
exit 0
