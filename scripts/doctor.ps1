param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$ok = $true

function Run-JsonScript([string]$Name) {
  $path = Join-Path $PSScriptRoot $Name
  $output = @()
  $errorText = ''
  switch ($Name) {
    'summary.ps1' { $output = @(& $path -Json 2>&1) }
    'startup-check.ps1' { $output = @(& $path -Json 2>&1) }
    'skill-sync-check.ps1' { $output = @(& $path -Json 2>&1) }
    'memory-health.ps1' { $output = @(& $path -Json 2>&1) }
    'script-tiers.ps1' { $output = @(& $path -Json 2>&1) }
    'tool-health.ps1' { $output = @(& $path -Json 2>&1) }
    'task-lifecycle-audit.ps1' { $output = @(& $path -Json 2>&1) }
    default { $output = @(& $path 2>&1) }
  }
  $exitCode = $LASTEXITCODE
  $raw = ($output -join "`n")
  $jsonStart = -1
  for ($index = 0; $index -lt $output.Count; $index++) {
    if ([string]$output[$index] -match '^\s*[\{\[]') { $jsonStart = $index; break }
  }
  try {
    if ($jsonStart -ge 0) {
      $parsed = (@($output[$jsonStart..($output.Count - 1)]) -join "`n") | ConvertFrom-Json
    } else {
      $parsed = $null
      $errorText = 'no json output'
      $exitCode = 1
    }
  } catch {
    $parsed = $null
    $errorText = $_.Exception.Message
    $exitCode = 1
  }
  $rawPreview = $raw
  if ($rawPreview.Length -gt 500) { $rawPreview = $rawPreview.Substring(0, 500) + '...' }
  return [pscustomobject]@{ name=$Name; ok=($exitCode -eq 0); exitCode=$exitCode; data=$parsed; error=$errorText; rawPreview=$rawPreview }
}

$summary = Run-JsonScript 'summary.ps1'
$startup = Run-JsonScript 'startup-check.ps1'
$skillSync = Run-JsonScript 'skill-sync-check.ps1'
$memoryHealth = Run-JsonScript 'memory-health.ps1'
$scriptTiers = Run-JsonScript 'script-tiers.ps1'
$toolHealth = Run-JsonScript 'tool-health.ps1'
$taskLifecycle = Run-JsonScript 'task-lifecycle-audit.ps1'

foreach ($item in @($summary,$startup,$skillSync,$memoryHealth,$scriptTiers,$toolHealth,$taskLifecycle)) {
  if (-not $item.ok) { $ok = $false }
}
if ($summary.data -and -not $summary.data.ok) { $ok = $false }
if ($startup.data -and -not $startup.data.ok) { $ok = $false }
if ($skillSync.data -and -not $skillSync.data.ok) { $ok = $false }
if ($memoryHealth.data -and -not $memoryHealth.data.ok) { $ok = $false }
if ($memoryHealth.data -and [int]$memoryHealth.data.duplicateCount -gt 0) { $ok = $false }

$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

$risks = @()
function Add-DoctorRisk([string]$Severity, [string]$Code, [string]$Message, [string]$Source = '') {
  $script:risks += [pscustomobject]@{
    severity = $Severity
    code = $Code
    message = $Message
    source = $Source
  }
}

foreach ($item in @($summary,$startup,$skillSync,$memoryHealth,$scriptTiers,$toolHealth,$taskLifecycle)) {
  if (-not $item.ok) { Add-DoctorRisk 'high' 'check_failed' "$($item.name) exited with $($item.exitCode)." $item.name }
  if (([string]$item.error -match 'MEMORY_LOCK_TIMEOUT') -or ([string]$item.rawPreview -match 'MEMORY_LOCK_TIMEOUT')) {
    Add-DoctorRisk 'high' 'memory_lock_timeout' "Lock timeout while running $($item.name)." $item.name
  }
}
if ($summary.data -and -not $summary.data.ok) { Add-DoctorRisk 'high' 'summary_not_ok' 'Package summary reports an unhealthy state.' 'summary.ps1' }
if ($startup.data -and -not $startup.data.ok) { Add-DoctorRisk 'high' 'startup_not_ok' 'Startup hook or config readiness is unhealthy.' 'startup-check.ps1' }
if ($skillSync.data -and -not $skillSync.data.ok) { Add-DoctorRisk 'high' 'skill_sync_not_ok' 'Installed skill copies or root markers are not synchronized.' 'skill-sync-check.ps1' }
if ($memoryHealth.data -and -not $memoryHealth.data.ok) { Add-DoctorRisk 'high' 'memory_health_not_ok' 'Active memory root or main memory file is unhealthy.' 'memory-health.ps1' }
if ($memoryHealth.data -and [int]$memoryHealth.data.duplicateCount -gt 0) { Add-DoctorRisk 'medium' 'memory_duplicates' "Memory has $($memoryHealth.data.duplicateCount) duplicate entries." 'memory-health.ps1' }
if ($memoryHealth.data -and [int]$memoryHealth.data.privatePatternHitCount -gt 0) { Add-DoctorRisk 'high' 'private_pattern_hits' "Memory has $($memoryHealth.data.privatePatternHitCount) private-pattern hits." 'memory-health.ps1' }
if ($memoryHealth.data -and [int]$memoryHealth.data.graphParseErrorCount -gt 0) { Add-DoctorRisk 'high' 'graph_parse_errors' "Graph has $($memoryHealth.data.graphParseErrorCount) parse errors." 'memory-health.ps1' }
if ($memoryHealth.data -and [int]$memoryHealth.data.invalidExpiryCount -gt 0) { Add-DoctorRisk 'medium' 'invalid_expiry' "Memory has $($memoryHealth.data.invalidExpiryCount) invalid expiry markers." 'memory-health.ps1' }

$lockStatuses = @(Get-SuperBrainKnownLockStatuses $Root 120)
$staleLocks = @($lockStatuses | Where-Object { $_.stale })
foreach ($lock in $staleLocks) {
  Add-DoctorRisk 'high' 'stale_lock' "Stale memory lock age=$($lock.ageSeconds)s target=$($lock.target)" $lock.lock
}

if ($toolHealth.data -and $toolHealth.data.warningFresh -eq $true) {
  Add-DoctorRisk 'low' 'optional_tool_schema_warning' 'Recent optional tool schema warning exists; checkpoint/status fallback should be used if it recurs.' 'tool-health.ps1'
}
if ($taskLifecycle.data) {
  if ([int]$taskLifecycle.data.counts.diagnosticCards -gt 0) { Add-DoctorRisk 'medium' 'diagnostic_task_state_present' "Task state contains $($taskLifecycle.data.counts.diagnosticCards) known diagnostic cards outside a test sandbox." 'task-lifecycle-audit.ps1' }
  if ([int]$taskLifecycle.data.counts.zeroPendingActiveCards -gt 0) { Add-DoctorRisk 'low' 'zero_pending_active_tasks' "Task state contains $($taskLifecycle.data.counts.zeroPendingActiveCards) active cards with no pending steps." 'task-lifecycle-audit.ps1' }
  if ([int]$taskLifecycle.data.counts.staleUnboundActiveCards -gt 0) { Add-DoctorRisk 'medium' 'stale_unbound_active_tasks' "Task state contains $($taskLifecycle.data.counts.staleUnboundActiveCards) stale active cards without checkpoint, context, or execution contract bindings." 'task-lifecycle-audit.ps1' }
  if ($taskLifecycle.data.pointerState -and $taskLifecycle.data.pointerState.mismatch -eq $true) {
    $severity = if ($taskLifecycle.data.pointerState.automaticContinuationSafe -eq $true) { 'low' } else { 'high' }
    Add-DoctorRisk $severity 'task_pointer_divergence' 'Compatibility task pointers refer to different task IDs; scoped selection remains authoritative.' 'task-lifecycle-audit.ps1'
  }
}

$sessionBinding = Read-WorkspaceJson 'session-binding.json'
$sessionBindingPath = Join-Path $workspace 'session-binding.json'
$sessionBindingStatus = [pscustomobject]@{ exists=(Test-Path $sessionBindingPath); active=$false; status='missing'; path=$sessionBindingPath }
if ((Test-Path $sessionBindingPath) -and $null -eq $sessionBinding) {
  Add-DoctorRisk 'medium' 'session_binding_parse_failed' 'session-binding.json exists but cannot be parsed.' 'session-binding.json'
  $sessionBindingStatus = [pscustomobject]@{ exists=$true; active=$false; status='parse_failed'; path=$sessionBindingPath }
} elseif ($sessionBinding) {
  $expired = $true
  try { $expired = ([datetime]::Parse([string]$sessionBinding.expiresAt) -lt (Get-Date)) } catch {}
  $versionMatch = ([string]$sessionBinding.packageVersion -eq [string]$summary.data.version)
  $rootMatch = (Test-SuperBrainSamePath ([string]$sessionBinding.memoryRoot) (Get-SuperBrainActiveMemoryRoot $Root))
  $rawText = $sessionBinding | ConvertTo-Json -Depth 12 -Compress
  $rawRisk = ($rawText -match '(?i)(api[_-]?key|client[_-]?secret|password\s*[=:]|access[_-]?token\s*[=:]|refresh[_-]?token\s*[=:]|bearer\s+[A-Za-z0-9._-]+|sk-[A-Za-z0-9])')
  if ($expired -and [string]$sessionBinding.status -eq 'active') { Add-DoctorRisk 'low' 'session_binding_expired' 'Active session binding is expired and will be ignored.' 'session-binding.json' }
  if (-not $versionMatch) { Add-DoctorRisk 'medium' 'session_binding_version_mismatch' 'Session binding packageVersion does not match current package version.' 'session-binding.json' }
  if (-not $rootMatch) { Add-DoctorRisk 'medium' 'session_binding_memory_root_mismatch' 'Session binding memoryRoot does not match active memory root.' 'session-binding.json' }
  if ($rawRisk) { Add-DoctorRisk 'high' 'session_binding_raw_content_risk' 'Session binding may contain private raw content.' 'session-binding.json' }
  $sessionBindingStatus = [pscustomobject]@{
    exists = $true
    active = ([string]$sessionBinding.status -eq 'active' -and -not $expired -and $versionMatch -and $rootMatch -and -not $rawRisk)
    status = $sessionBinding.status
    bindingId = $sessionBinding.bindingId
    sessionId = $sessionBinding.sessionId
    taskId = $sessionBinding.taskId
    expiresAt = $sessionBinding.expiresAt
    expired = $expired
    packageVersionMatch = $versionMatch
    memoryRootMatch = $rootMatch
    rawContentRisk = $rawRisk
    path = $sessionBindingPath
  }
}

$lastVerify = Read-WorkspaceJson 'last-verify-package.json'
$lastRelease = Read-WorkspaceJson 'last-release.json'
$lastHotRefresh = Read-WorkspaceJson 'last-hot-refresh.json'
$lastCi = Read-WorkspaceJson 'last-ci.json'
$lastMemoryEval = Read-WorkspaceJson 'last-memory-eval.json'
$lastTaskVerification = Read-WorkspaceJson 'last-task-verification.json'
$lastTeamTaskIndex = Read-WorkspaceJson 'team-task-index.json'
$teamTaskRoot = Join-Path $workspace 'team-tasks'
$teamTaskCount = if (Test-Path $teamTaskRoot) { @(Get-ChildItem -LiteralPath $teamTaskRoot -Filter 'team-*.json' -File -ErrorAction SilentlyContinue).Count } else { 0 }
if ($teamTaskCount -gt 0 -and $null -eq $lastTeamTaskIndex) { Add-DoctorRisk 'medium' 'missing_team_task_index' 'Team task records exist but team-task-index.json is missing or invalid.' 'team-task-index.ps1' }
$agentTeamsConfig = Read-WorkspaceJson 'agent-teams.json'
$agentTeamsPath = Join-Path $workspace 'agent-teams.json'
$agentTeamsConfigExists = Test-Path $agentTeamsPath
if ($agentTeamsConfigExists -and $null -eq $agentTeamsConfig) { Add-DoctorRisk 'medium' 'agent_teams_parse_failed' 'Agent team template config exists but cannot be parsed.' 'agent-teams.json' }
$agentTeamTemplateCount = if ($agentTeamsConfig) { @($agentTeamsConfig.templates).Count } else { 0 }
if ($agentTeamsConfig -and $agentTeamTemplateCount -lt 4) { Add-DoctorRisk 'medium' 'agent_teams_missing_templates' 'Agent team template config has fewer than four default templates.' 'agent-teams.json' }
$teamTaskAudit = $null
try {
  $teamTaskAuditJson = & (Join-Path $PSScriptRoot 'team-task-audit.ps1') -Json
  $teamTaskAudit = $teamTaskAuditJson | ConvertFrom-Json
} catch { $teamTaskAudit = $null }
if ($teamTaskAudit) {
  if ([int]$teamTaskAudit.unreviewedCodeChangeCount -gt 0) { Add-DoctorRisk 'high' 'unreviewed_code_capable' "Team tasks have $($teamTaskAudit.unreviewedCodeChangeCount) unreviewed code-capable delegations." 'team-task-audit.ps1' }
  if ([int]$teamTaskAudit.driftRiskCount -gt 0) { Add-DoctorRisk 'high' 'code_capable_drift' "Team tasks have $($teamTaskAudit.driftRiskCount) code-capable drift risks." 'team-task-audit.ps1' }
  if ([int]$teamTaskAudit.authorizationMissingCount -gt 0) { Add-DoctorRisk 'medium' 'code_capable_authorization_missing' "Team tasks have $($teamTaskAudit.authorizationMissingCount) code-capable delegations with missing or incomplete authorization." 'team-task-audit.ps1' }
}
foreach ($state in @(
  @{ name='last-verify-package.json'; value=$lastVerify; source='verify-package.ps1'; severity='high' },
  @{ name='last-release.json'; value=$lastRelease; source='release-share.ps1'; severity='medium' },
  @{ name='last-hot-refresh.json'; value=$lastHotRefresh; source='hot-refresh-skills.ps1'; severity='medium' },
  @{ name='last-memory-eval.json'; value=$lastMemoryEval; source='memory-eval-report.ps1'; severity='medium' }
)) {
  if ($null -eq $state.value) {
    Add-DoctorRisk $state.severity 'missing_state' "Missing $($state.name)." $state.source
  } elseif ($state.value.ok -ne $true) {
    Add-DoctorRisk $state.severity 'state_not_ok' "$($state.name) reports ok=false." $state.source
  }
}

$riskCounts = [ordered]@{ high = 0; medium = 0; low = 0 }
foreach ($risk in $risks) {
  if ($riskCounts.Contains($risk.severity)) { $riskCounts[$risk.severity] = [int]$riskCounts[$risk.severity] + 1 }
}
$riskSummary = [pscustomobject]@{
  total = @($risks).Count
  high = [int]$riskCounts.high
  medium = [int]$riskCounts.medium
  low = [int]$riskCounts.low
}

$experienceIndexPath = Join-Path $workspace 'experience-index.md'
$experienceRoot = Join-Path $workspace 'experiences'
$experienceCount = if (Test-Path $experienceRoot) { @(Get-ChildItem -LiteralPath $experienceRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count } else { 0 }

$result = [pscustomobject]@{
  ok = $ok
  packageRoot = $Root
  version = if ($summary.data) { $summary.data.version } else { 'UNKNOWN' }
  summary = $summary.data
  startupOk = if ($startup.data) { [bool]$startup.data.ok } else { $false }
  skillSyncOk = if ($skillSync.data) { [bool]$skillSync.data.ok } else { $false }
  memoryHealth = $memoryHealth.data
  lockHealth = [pscustomobject]@{ staleAfterSeconds=120; lockCount=@($lockStatuses).Count; staleCount=@($staleLocks).Count; locks=@($lockStatuses) }
  toolHealth = $toolHealth.data
  taskLifecycle = $taskLifecycle.data
  riskSummary = $riskSummary
  risks = @($risks)
  scriptTierCount = if ($scriptTiers.data) { @($scriptTiers.data.scripts).Count } else { 0 }
  lastVerify = if ($lastVerify) { [pscustomobject]@{ ok=$lastVerify.ok; version=$lastVerify.version; checkedAt=$lastVerify.checkedAt } } else { $null }
  lastRelease = if ($lastRelease) { [pscustomobject]@{ ok=$lastRelease.ok; kind=$lastRelease.kind; destination=$lastRelease.destination; checkedAt=$lastRelease.checkedAt } } else { $null }
  lastHotRefresh = if ($lastHotRefresh) { [pscustomobject]@{ ok=$lastHotRefresh.ok; checkedAt=$lastHotRefresh.checkedAt } } else { $null }
  lastCi = if ($lastCi) { [pscustomobject]@{ ok=$lastCi.ok; checkedAt=$lastCi.checkedAt; skipIntegration=$lastCi.skipIntegration } } else { $null }
  lastMemoryEval = if ($lastMemoryEval) { [pscustomobject]@{ ok=$lastMemoryEval.ok; checkedAt=$lastMemoryEval.checkedAt; total=$lastMemoryEval.total; passed=$lastMemoryEval.passed; failed=$lastMemoryEval.failed; skipped=$lastMemoryEval.skipped } } else { $null }
  lastTaskVerification = if ($lastTaskVerification) { [pscustomobject]@{ ok=$lastTaskVerification.ok; checkedAt=$lastTaskVerification.checkedAt; summary=$lastTaskVerification.summary } } else { $null }
  teamTasks = [pscustomobject]@{
    count = $teamTaskCount
    indexOk = ($null -ne $lastTeamTaskIndex)
    updatedAt = if ($lastTeamTaskIndex) { $lastTeamTaskIndex.updatedAt } else { $null }
    recent = if ($lastTeamTaskIndex) { @($lastTeamTaskIndex.recent | Select-Object -First 5) } else { @() }
  }
  agentTeams = [pscustomobject]@{
    configExists = $agentTeamsConfigExists
    configOk = ($null -ne $agentTeamsConfig)
    templateCount = $agentTeamTemplateCount
    path = $agentTeamsPath
  }
  codeCapableAudit = if ($teamTaskAudit) { [pscustomobject]@{ ok=$teamTaskAudit.ok; codeCapableDelegationCount=$teamTaskAudit.codeCapableDelegationCount; unreviewedCodeChangeCount=$teamTaskAudit.unreviewedCodeChangeCount; driftRiskCount=$teamTaskAudit.driftRiskCount; blockedScopeExpansionCount=$teamTaskAudit.blockedScopeExpansionCount; authorizationMissingCount=$teamTaskAudit.authorizationMissingCount } } else { $null }
  experienceIndex = [pscustomobject]@{ exists=(Test-Path $experienceIndexPath); count=$experienceCount; path=$experienceIndexPath }
  sessionBinding = $sessionBindingStatus
  checks = @(@($summary,$startup,$skillSync,$memoryHealth,$scriptTiers,$toolHealth,$taskLifecycle) | ForEach-Object { [pscustomobject]@{ name=$_.name; ok=$_.ok; exitCode=$_.exitCode } })
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "DOCTOR version=$($result.version) ok=$($result.ok) startupOk=$($result.startupOk) skillSyncOk=$($result.skillSyncOk) risks=$($result.riskSummary.total) high=$($result.riskSummary.high) medium=$($result.riskSummary.medium) duplicates=$($result.memoryHealth.duplicateCount) memoryLines=$($result.summary.memoryLines) experiences=$($result.experienceIndex.count)"
  Write-Host "package=$Root"
  if ($result.lastVerify) { Write-Host "lastVerify ok=$($result.lastVerify.ok) version=$($result.lastVerify.version) checkedAt=$($result.lastVerify.checkedAt)" }
  if ($result.lastRelease) { Write-Host "lastRelease ok=$($result.lastRelease.ok) destination=$($result.lastRelease.destination)" }
  if ($result.lastHotRefresh) { Write-Host "lastHotRefresh ok=$($result.lastHotRefresh.ok) checkedAt=$($result.lastHotRefresh.checkedAt)" }
  if ($result.lastMemoryEval) { Write-Host "lastMemoryEval ok=$($result.lastMemoryEval.ok) passed=$($result.lastMemoryEval.passed)/$($result.lastMemoryEval.total) skipped=$($result.lastMemoryEval.skipped)" }
  Write-Host "locks count=$($result.lockHealth.lockCount) stale=$($result.lockHealth.staleCount)"
  if ($result.toolHealth) { Write-Host "toolHealth warningFresh=$($result.toolHealth.warningFresh) warningExists=$($result.toolHealth.warningExists)" }
  Write-Host "teamTasks count=$($result.teamTasks.count) indexOk=$($result.teamTasks.indexOk) updatedAt=$($result.teamTasks.updatedAt)"
  Write-Host "agentTeams templates=$($result.agentTeams.templateCount) configOk=$($result.agentTeams.configOk) path=$($result.agentTeams.path)"
  if ($result.codeCapableAudit) { Write-Host "codeCapable delegations=$($result.codeCapableAudit.codeCapableDelegationCount) unreviewed=$($result.codeCapableAudit.unreviewedCodeChangeCount) drift=$($result.codeCapableAudit.driftRiskCount) missingAuth=$($result.codeCapableAudit.authorizationMissingCount)" }
  Write-Host "sessionBinding exists=$($result.sessionBinding.exists) active=$($result.sessionBinding.active) status=$($result.sessionBinding.status) expiresAt=$($result.sessionBinding.expiresAt)"
  foreach ($risk in @($result.risks)) { Write-Host "RISK $($risk.severity) $($risk.code) source=$($risk.source) $($risk.message)" }
  if ($ok) { Write-Host 'DOCTOR_OK' } else { Write-Host 'DOCTOR_FAILED' }
}

if (-not $ok) { exit 1 }
exit 0
