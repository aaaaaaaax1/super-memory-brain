param(
  [switch]$Json,
  [switch]$AllowPrivacyRisk,
  [switch]$AllowActiveCheckpoint,
  [string]$TaskId = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
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
  return Read-WorkspaceJson $FallbackName
}
function Test-TaskScopedEvidence($Obj) {
  if ([string]::IsNullOrWhiteSpace($TaskId) -or -not $Obj) { return $true }
  return ([string]$Obj.taskId -eq $TaskId)
}

$currentTaskContext = Read-WorkspaceJson 'current-task-context.json'
if ([string]::IsNullOrWhiteSpace($TaskId) -and $currentTaskContext -and [string]$currentTaskContext.status -eq 'active') { $TaskId = [string]$currentTaskContext.taskId }
$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$lastTask = Read-WorkspaceJson 'last-task-verification.json'
$smartNextAudit = $null
$completionAuditExpectedRoles = @('pre_action_constraint','challenge_gate','review_verifier','test_strategy','real_user_path_verifier','version_record_keeper','cache_freshness_checker','skill_gap_repair')
try {
  $smartRaw = @(& (Join-Path $PSScriptRoot 'smart-next.ps1') 'completion skill audit verify test regression before completion' -Json 2>$null)
  if ($smartRaw) { $smartNextAudit = (($smartRaw -join "`n") | ConvertFrom-Json) }
} catch {}
$activeCheckpoint = Read-WorkspaceJson 'active-checkpoint.json'
$constraintPreflight = Read-WorkspaceJson 'last-accepted-constraints-preflight.json'
$driftCheckpoint = Read-WorkspaceJson 'last-runtime-drift-checkpoint.json'
$routeCheckpoint = Read-TaskScopedJson 'route-checkpoints' 'last-route-checkpoint.json'
$integrationParity = Read-TaskScopedJson 'integration-parity-check' 'last-integration-parity-check.json'
$causalReview = Read-TaskScopedJson 'change-causality-reviews' 'last-causal-change-review.json'
$contractReplay = Read-TaskScopedJson 'integration-contract-replay' 'last-integration-contract-replay.json'

$checks = @()
$verifyOk = ($lastVerify -and $lastVerify.ok -eq $true)
if ($AllowPrivacyRisk -and -not $verifyOk) { $verifyOk = $true }
$checks += [pscustomobject]@{ name='verify-package'; ok=$verifyOk; evidence=if ($lastVerify) { "version=$($lastVerify.version) checkedAt=$($lastVerify.checkedAt) ok=$($lastVerify.ok)" } else { 'missing last-verify-package.json' } }
$checks += [pscustomobject]@{ name='hot-refresh'; ok=($lastHotRefresh -and $lastHotRefresh.ok -eq $true); evidence=if ($lastHotRefresh) { "checkedAt=$($lastHotRefresh.checkedAt)" } else { 'missing last-hot-refresh.json' } }
$checks += [pscustomobject]@{ name='task-verification'; ok=($lastTask -and $lastTask.ok -eq $true); evidence=if ($lastTask) { $lastTask.summary } else { 'missing last-task-verification.json' } }
$skillAudit = if ($smartNextAudit) { $smartNextAudit.completionSkillAudit } else { $null }
$skillAuditMissing = if ($skillAudit) { @($skillAudit.missingRoles) } else { @('missing_completion_skill_audit') }
$skillAuditOk = ($skillAudit -and $skillAudit.required -eq $true -and @($skillAuditMissing).Count -eq 0)
$checks += [pscustomobject]@{ name='completion-skill-audit'; ok=$skillAuditOk; evidence=if($skillAudit){"source=smart-next.ps1 auditMode=$($skillAudit.auditMode) presentRoles=$((@($skillAudit.presentRoles)-join ',')) missingRoles=$((@($skillAuditMissing)-join ','))"}else{'missing smart-next completionSkillAudit'} }
$constraintConflictCount = if ($constraintPreflight) { @($constraintPreflight.conflicts).Count } else { 0 }
$constraintOk = (-not $constraintPreflight) -or ($constraintPreflight.ok -eq $true -and $constraintConflictCount -eq 0 -and (-not $lastTask -or $lastTask.constraintsPreserved -ne $false))
$checks += [pscustomobject]@{ name='accepted-constraints-preflight'; ok=$constraintOk; evidence=if ($constraintPreflight) { "required=$($constraintPreflight.required) constraints=$(@($constraintPreflight.constraints).Count) conflicts=$constraintConflictCount guardHash=$($constraintPreflight.guardHash)" } else { 'none' } }
$checks += [pscustomobject]@{ name='active-checkpoint'; ok=(-not ($activeCheckpoint -and [string]$activeCheckpoint.status -eq 'active') -or $AllowActiveCheckpoint); evidence=if ($activeCheckpoint) { "status=$($activeCheckpoint.status) taskId=$($activeCheckpoint.taskId) allowActiveCheckpoint=$([bool]$AllowActiveCheckpoint)" } else { 'none' } }
$driftOk = (-not $driftCheckpoint) -or ($driftCheckpoint.unresolvedDrift -ne $true -and $driftCheckpoint.ok -eq $true)
$checks += [pscustomobject]@{ name='runtime-drift-checkpoint'; ok=$driftOk; evidence=if ($driftCheckpoint) { "status=$($driftCheckpoint.status) unresolvedDrift=$($driftCheckpoint.unresolvedDrift) violations=$(@($driftCheckpoint.violations).Count)" } else { 'none' } }
$checks += [pscustomobject]@{ name='task-scoped-route-checkpoint'; ok=(Test-TaskScopedEvidence $routeCheckpoint); evidence=if($routeCheckpoint){"taskId=$($routeCheckpoint.taskId) requiredTaskId=$TaskId"}else{'none'} }
$routeOk = (-not $routeCheckpoint) -or (($routeCheckpoint.unresolvedRouteDrift -ne $true -and $routeCheckpoint.ok -eq $true) -and (Test-TaskScopedEvidence $routeCheckpoint))
$checks += [pscustomobject]@{ name='route-checkpoint'; ok=$routeOk; evidence=if ($routeCheckpoint) { "status=$($routeCheckpoint.status) unresolvedRouteDrift=$($routeCheckpoint.unresolvedRouteDrift) violations=$(@($routeCheckpoint.violations).Count)" } else { 'none' } }
$checks += [pscustomobject]@{ name='task-scoped-integration-parity'; ok=(Test-TaskScopedEvidence $integrationParity); evidence=if($integrationParity){"taskId=$($integrationParity.taskId) requiredTaskId=$TaskId"}else{'none'} }
$integrationOk = (-not $integrationParity) -or (($integrationParity.unresolvedIntegrationDrift -ne $true -and $integrationParity.ok -eq $true) -and (Test-TaskScopedEvidence $integrationParity))
$checks += [pscustomobject]@{ name='integration-parity-check'; ok=$integrationOk; evidence=if ($integrationParity) { "unresolvedIntegrationDrift=$($integrationParity.unresolvedIntegrationDrift) drifts=$(@($integrationParity.drifts).Count) module=$($integrationParity.module) moduleVerification=$($integrationParity.moduleVerification.status) integrationVerification=$($integrationParity.integrationVerification.status) userAcceptanceVerification=$($integrationParity.userAcceptanceVerification.status)" } else { 'none' } }
$checks += [pscustomobject]@{ name='task-scoped-causal-review'; ok=(Test-TaskScopedEvidence $causalReview); evidence=if($causalReview){"taskId=$($causalReview.taskId) requiredTaskId=$TaskId"}else{'none'} }
$causalReviewOk = (-not $causalReview) -or (($causalReview.ok -eq $true -and @($causalReview.gaps).Count -eq 0) -and (Test-TaskScopedEvidence $causalReview))
$checks += [pscustomobject]@{ name='causal-change-review'; ok=$causalReviewOk; evidence=if ($causalReview) { "decision=$($causalReview.expectedVsActual.decision) gaps=$(@($causalReview.gaps).Count) expectedPresent=$($causalReview.expectedVsActual.expectedPresent) actualPresent=$($causalReview.expectedVsActual.actualPresent)" } else { 'none' } }
$checks += [pscustomobject]@{ name='task-scoped-integration-contract-replay'; ok=(Test-TaskScopedEvidence $contractReplay); evidence=if($contractReplay){"taskId=$($contractReplay.taskId) requiredTaskId=$TaskId"}else{'none'} }
$contractReplayOk = (-not $contractReplay) -or (($contractReplay.unresolvedBehaviorMismatch -ne $true -and $contractReplay.ok -eq $true) -and (Test-TaskScopedEvidence $contractReplay))
$checks += [pscustomobject]@{ name='integration-contract-replay'; ok=$contractReplayOk; evidence=if ($contractReplay) { "module=$($contractReplay.module) normalizedMatch=$($contractReplay.normalizedMatch) mismatches=$(@($contractReplay.mismatches).Count)" } else { 'none' } }

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
$result = [pscustomobject]@{
  ok = ($failed.Count -eq 0)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  allowPrivacyRisk = [bool]$AllowPrivacyRisk
  taskId = $TaskId
  failed = $failed.Count
  checks = @($checks)
}

if ($Json) {
  $result | ConvertTo-Json -Depth 10
} else {
  Write-Host "COMPLETION_GUARD ok=$($result.ok) failed=$($result.failed) allowPrivacyRisk=$($result.allowPrivacyRisk)"
  foreach ($check in @($checks)) { Write-Host "COMPLETION_GUARD_CHECK name=$($check.name) ok=$($check.ok) evidence=$($check.evidence)" }
}
if (-not $result.ok) { exit 1 }
exit 0
