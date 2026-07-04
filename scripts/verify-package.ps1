param(
  [switch]$Integration,
  [switch]$WithShareBuild,
  [switch]$WithTempInstall
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$ok = $true
$results = @()

if ($Integration) {
  $WithShareBuild = $true
  $WithTempInstall = $true
}

function Mark-Ok([string]$Message) {
  Write-Host "OK $Message"
  $script:results += [pscustomobject]@{ name = $Message; ok = $true }
}

function Mark-Fail([string]$Message) {
  Write-Host "FAILED $Message"
  $script:ok = $false
  $script:results += [pscustomobject]@{ name = $Message; ok = $false }
}

function Read-Utf8([string]$RelativePath) {
  $path = Join-Path $Root $RelativePath
  try {
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  } catch {
    Mark-Fail "READ_UTF8 $RelativePath $($_.Exception.Message)"
    return ''
  }
}

$required = @(
  'README.md','QUICK_START.md','COMMANDS.md','manifest.json','CHANGELOG.md','CURRENT_BASELINE.md','BASELINE_HISTORY.md','memory-policy.json','maintenance-policy.json',
  'super-memory-brain\SKILL.md',
  'modules\skill-orchestrator\SKILL.md',
  'modules\plusunm-g1\SKILL.md',
  'modules\nexsandglass-dedicated-memory\SKILL.md',
  'vendor\NexSandglass-Agent-DedicatedMemory\sandglass_log.py',
  'vendor\NexSandglass-Agent-DedicatedMemory\sandglass_lock.py',
  'memory\shared\scripts\sandglass_log.py',
  'memory\shared\scripts\sandglass_lock.py',
  'memory\shared\scripts\sandglass_vault.py',
  'memory\graph.jsonl',
  'memory\workspace\session-notes.md',
  'memory\workspace\team-task-index.json',
  'memory\workspace\agent-teams.json',
  'tests\memory-recall-tests.json','tests\memory-eval-tests.json',
  'scripts\workspace-lifecycle-manager.ps1','scripts\auto-hygiene-runner.ps1','scripts\post-task-maintenance.ps1','scripts\self-improvement-queue.ps1',
  'scripts\install.ps1','scripts\install.bat','scripts\install-ui.ps1','scripts\install-ui.vbs','scripts\brain.bat','scripts\brain-ui.vbs','scripts\check-install-ui-paths.ps1','scripts\status.ps1','scripts\doctor.ps1','scripts\maintain.ps1','scripts\summary.ps1','scripts\script-tiers.ps1','scripts\memory-health.ps1','scripts\write-memory.ps1','scripts\write-experience.ps1','scripts\audit-memory.ps1',
  'scripts\baseline-update.ps1','scripts\prepare-share.ps1','scripts\compact.ps1','scripts\compact-report.ps1','scripts\compact-apply.ps1','scripts\backup.ps1','scripts\backup-retention.ps1',
  'scripts\verify-package.ps1','scripts\auto-check.ps1','scripts\startup-check.ps1','scripts\update-state.ps1','scripts\state.ps1','scripts\recall-search.ps1','scripts\recall-recent.ps1','scripts\session-restore.ps1','scripts\session-binding.ps1','scripts\learn-memory.ps1','scripts\profile-card.ps1','scripts\skill-sync-check.ps1','scripts\memory-mode.ps1','scripts\install-agent.ps1','scripts\hot-refresh-skills.ps1','scripts\install-menu.ps1','scripts\cleanup-legacy-memory.ps1','scripts\cleanup-install-backups.ps1','scripts\migrate-memory-layout.ps1','scripts\repair-hook.ps1','scripts\encoding-check.ps1','scripts\graph-normalize.ps1','scripts\write-decision.ps1','scripts\decision-search.ps1','scripts\decision-audit.ps1','scripts\bootstrap.ps1','scripts\release-private.ps1','scripts\release-share.ps1','scripts\graph-add.ps1','scripts\graph-search.ps1','scripts\extract-facts.ps1',
  'scripts\optimize-advisor.ps1','scripts\tool-health.ps1','scripts\skill-capability-map.ps1',
  'scripts\accepted-constraints-preflight.ps1',
  'scripts\goal-route-lock.ps1','scripts\route-checkpoint.ps1','scripts\verified-module-snapshot.ps1','scripts\integration-parity-check.ps1','scripts\causal-change-plan.ps1',
  'scripts\checkpoint-writer.ps1','scripts\task-register.ps1',
  'scripts\test-recall.ps1','scripts\memory-eval.ps1','scripts\memory-eval-report.ps1','scripts\tag-legacy-memory.ps1','scripts\ci.ps1','scripts\lint.ps1','scripts\test-pester.ps1','scripts\concurrency-smoke-test.ps1','scripts\task-verification.ps1','scripts\team-dispatch-check.ps1','scripts\team-template-list.ps1','scripts\team-template-select.ps1','scripts\team-task-new.ps1','scripts\team-task-add-delegation.ps1','scripts\team-task-authorize.ps1','scripts\team-task-review.ps1','scripts\team-task-audit.ps1','scripts\team-task-decision.ps1','scripts\team-task-status.ps1','scripts\team-task-index.ps1','scripts\smoke-test.ps1','scripts\common.ps1','scripts\session-compact.ps1','scripts\verify-share.ps1','scripts\release.ps1'
)

foreach ($rel in $required) {
  $path = Join-Path $Root $rel
  if (Test-Path $path) { Mark-Ok $rel } else { Mark-Fail "MISSING $rel" }
}

try {
  $manifest = Read-Utf8 'manifest.json' | ConvertFrom-Json
  Mark-Ok 'manifest.json parse'
  Write-Host "Version: $($manifest.version)"
} catch {
  Mark-Fail "manifest.json parse $($_.Exception.Message)"
  $manifest = [pscustomobject]@{ version = 'UNKNOWN'; scripts = @(); internalScripts = @(); scriptMetadata = @() }
}

if ((Test-Path (Join-Path $Root (Join-Path $manifest.entrySkill 'SKILL.md'))) -and @($manifest.modules).Count -gt 0) { Mark-Ok 'package bundled skill shape' } else { Mark-Fail 'package bundled skill shape missing' }
foreach ($module in @($manifest.modules)) {
  if (Test-Path (Join-Path (Join-Path $Root 'modules') (Join-Path $module 'SKILL.md'))) { Mark-Ok "package bundled module $module" } else { Mark-Fail "package bundled module missing $module" }
}

$manifestScripts = @($manifest.scripts)
$actualPublicScripts = @(Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -File | Where-Object { $_.Extension -in @('.ps1','.bat','.vbs') } | ForEach-Object { $_.Name })
$duplicateScripts = @($manifestScripts | Group-Object | Where-Object { $_.Count -gt 1 })
if ($duplicateScripts.Count -eq 0) { Mark-Ok 'manifest script list unique' } else { Mark-Fail ('manifest duplicate scripts ' + (($duplicateScripts | ForEach-Object { $_.Name }) -join ',')) }
if ($manifest.PSObject.Properties['scriptGroups'] -and @($manifest.scriptGroups.PSObject.Properties).Count -gt 0) {
  Mark-Ok 'manifest compact script groups present'
  foreach ($group in @($manifest.scriptGroups.PSObject.Properties)) {
    foreach ($script in @($group.Value)) {
      if ($manifestScripts -contains $script) { Mark-Ok "manifest script group $($group.Name) listed $script" } else { Mark-Fail "manifest script group $($group.Name) unknown $script" }
    }
  }
} else { Mark-Fail 'manifest compact script groups missing' }
foreach ($script in $manifestScripts) {
  if (Test-Path (Join-Path (Join-Path $Root 'scripts') $script)) { Mark-Ok "manifest script exists $script" } else { Mark-Fail "manifest script missing $script" }
}
foreach ($script in $actualPublicScripts) {
  if ($manifestScripts -contains $script) { Mark-Ok "script inventory listed $script" } else { Mark-Fail "script inventory missing $script" }
}

$metadata = @($manifest.scriptMetadata)
if ($metadata.Count -gt 0) { Mark-Ok 'script metadata present' } else { Mark-Fail 'script metadata missing' }
$metadataByPath = @{}
foreach ($entry in $metadata) {
  if ($metadataByPath.ContainsKey($entry.path)) {
    Mark-Fail "duplicate script metadata $($entry.path)"
  } else {
    $metadataByPath[$entry.path] = $entry
  }
  if ($entry.tier -in @('T0','T1','T2','T3')) { Mark-Ok "script tier $($entry.path) $($entry.tier)" } else { Mark-Fail "script tier invalid $($entry.path)" }
  if (($entry.path -like '*.ps1') -or ($entry.path -like '*.bat') -or ($entry.path -like '*.vbs') -or ($entry.path -like '*.py')) {
    if (Test-Path (Join-Path (Join-Path $Root 'scripts') $entry.path)) { Mark-Ok "script metadata path exists $($entry.path)" } else { Mark-Fail "script metadata path missing $($entry.path)" }
  }
}
foreach ($script in $manifestScripts) {
  if ($metadataByPath.ContainsKey($script)) { Mark-Ok "script metadata listed $script" } else { Mark-Fail "script metadata missing $script" }
}
foreach ($script in @($manifest.internalScripts)) {
  if ($metadataByPath.ContainsKey($script)) { Mark-Ok "internal script metadata listed $script" } else { Mark-Fail "internal script metadata missing $script" }
  if (Test-Path (Join-Path (Join-Path $Root 'scripts') $script)) { Mark-Ok "internal script exists $script" } else { Mark-Fail "internal script missing $script" }
}

$mutatingCommands = @('Remove-Item','Set-Content','Add-Content','Copy-Item','New-Item','Compress-Archive')
$controlledSwitches = @('Apply','ApplySafe','ApplyConfirmed','Force','Fix','NoBackup','NoGraph','SkipVerify','SkipPrepare','ConfirmPrivate','Preview','AllowDuplicate','Refresh','Integration','WithShareBuild','WithTempInstall','SkipIntegration','SmokeTest','AllKnown')
foreach ($entry in $metadata) {
  $scriptPath = Join-Path (Join-Path $Root 'scripts') $entry.path
  if (-not (Test-Path $scriptPath)) { continue }
  $scriptText = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
  $hasMutation = $false
  foreach ($command in $mutatingCommands) {
    if ($scriptText -like "*$command*") { $hasMutation = $true; break }
  }
  if ($entry.tier -eq 'T0' -and $hasMutation) {
    Mark-Fail "T0 script has mutating command $($entry.path)"
  } else {
    Mark-Ok "script mutation tier $($entry.path)"
  }
  foreach ($switch in $controlledSwitches) {
    if ($scriptText -match ('(?m)^\s*\[switch\]\$' + [regex]::Escape($switch) + '\b')) {
      if (@($entry.dangerousSwitches) -contains $switch) { Mark-Ok "script switch declared $($entry.path) -$switch" } else { Mark-Fail "script switch missing metadata $($entry.path) -$switch" }
    }
  }
}

try {
  $memoryPolicy = Read-Utf8 'memory-policy.json' | ConvertFrom-Json
  Mark-Ok 'memory-policy.json parse'
} catch {
  Mark-Fail "memory-policy.json parse $($_.Exception.Message)"
  $memoryPolicy = [pscustomobject]@{}
}

foreach ($tag in @('[PROFILE]','[PROJECT]','[TASK]','[SESSION]','[SUMMARY]','[NEGATIVE_FEEDBACK]')) {
  if (@($memoryPolicy.requiredTags) -contains $tag) { Mark-Ok "memory policy tag $tag" } else { Mark-Fail "memory policy tag missing $tag" }
}
foreach ($layer in @('profile','project','decision','task','session')) {
  if (@($memoryPolicy.layers.allowed) -contains $layer) { Mark-Ok "memory policy layer $layer" } else { Mark-Fail "memory policy layer missing $layer" }
}
if ([int]$memoryPolicy.retrieval.top_k -gt 0 -and [int]$memoryPolicy.retrieval.max_tokens -gt 0) { Mark-Ok 'memory policy retrieval budget' } else { Mark-Fail 'memory policy retrieval budget missing' }
if ($memoryPolicy.retrieval.contextBudget.enabled -eq $true -and $null -ne $memoryPolicy.retrieval.contextBudget.evidenceTokens -and $null -ne $memoryPolicy.retrieval.contextBudget.cardSnippetTokens -and $memoryPolicy.retrieval.contextBudget.defaultOutput -eq 'evidenceCard') { Mark-Ok 'memory policy context budget evidence cards' } else { Mark-Fail 'memory policy context budget evidence cards missing' }
if ($null -ne $memoryPolicy.retrieval.summaryFirst) { Mark-Ok 'memory policy summary first' } else { Mark-Fail 'memory policy summary first missing' }
if (@($memoryPolicy.feedback.negativePatterns).Count -gt 0 -and $memoryPolicy.feedback.negativeTag -eq '[NEGATIVE_FEEDBACK]') { Mark-Ok 'memory policy negative feedback' } else { Mark-Fail 'memory policy negative feedback missing' }
if ($null -ne $memoryPolicy.expiry.profileDays -and $null -ne $memoryPolicy.expiry.sessionDays) { Mark-Ok 'memory policy expiry' } else { Mark-Fail 'memory policy expiry missing' }
if (@($memoryPolicy.memoryModes) -contains 'auto' -and @($memoryPolicy.memoryModes) -contains 'force' -and @($memoryPolicy.memoryModes) -contains 'off') { Mark-Ok 'memory policy modes' } else { Mark-Fail 'memory policy modes missing' }
if (@($memoryPolicy.requiredTags) -contains '[ADR]' -and $null -ne $memoryPolicy.adr.statuses) { Mark-Ok 'memory policy ADR schema' } else { Mark-Fail 'memory policy ADR schema missing' }
if (@($memoryPolicy.provenanceRequired) -contains 'platform' -and @($memoryPolicy.provenanceRequired) -contains 'agent' -and @($memoryPolicy.provenanceRequired) -contains 'sessionId' -and @($memoryPolicy.provenanceRequired) -contains 'taskId' -and $null -ne $memoryPolicy.checkpointLifecycle.preExecution -and $null -ne $memoryPolicy.checkpointLifecycle.completion -and $memoryPolicy.preflight.enabled -eq $true -and @($memoryPolicy.preflight.acceptedConstraintTags).Count -gt 0) { Mark-Ok 'memory policy provenance checkpoint preflight schema' } else { Mark-Fail 'memory policy provenance checkpoint preflight schema missing' }
if ($memoryPolicy.retrieval.hybrid.enabled -eq $true -and $null -ne $memoryPolicy.retrieval.hybrid.sourceWeights -and $null -ne $memoryPolicy.retrieval.hybrid.boosts -and $null -ne $memoryPolicy.retrieval.hybrid.penalties) { Mark-Ok 'memory policy hybrid recall' } else { Mark-Fail 'memory policy hybrid recall missing' }
if ($memoryPolicy.retrieval.hybrid.sourceWeights.PSObject.Properties['sessionBinding'] -and [double]$memoryPolicy.retrieval.hybrid.sourceWeights.sessionBinding -gt 0) { Mark-Ok 'memory policy session binding source weight' } else { Mark-Fail 'memory policy session binding source weight missing' }
if ($memoryPolicy.retrieval.recency.enabled -eq $true -and $null -ne $memoryPolicy.retrieval.recency.halfLifeDays -and $null -ne $memoryPolicy.retrieval.recency.maxBoost -and @($memoryPolicy.retrieval.hybrid.profileIntentTriggers).Count -gt 0 -and @($memoryPolicy.retrieval.hybrid.experienceIntentTriggers).Count -gt 0 -and @($memoryPolicy.retrieval.hybrid.personaIntentTriggers).Count -gt 0) { Mark-Ok 'memory policy recency and persona intent schema' } else { Mark-Fail 'memory policy recency and persona intent schema missing' }
if (@($memoryPolicy.writeAllowSignals) -contains '我的偏好' -and @($memoryPolicy.writeAllowSignals) -contains '我的性格' -and @($memoryPolicy.writeAllowSignals) -contains '我的经历') { Mark-Ok 'memory policy profile write signals' } else { Mark-Fail 'memory policy profile write signals missing' }
if (@($memoryPolicy.requiredTags) -contains '[TEAM_TASK]' -and @($memoryPolicy.requiredTags) -contains '[COMMANDER]' -and @($memoryPolicy.requiredTags) -contains '[DELEGATION]' -and @($memoryPolicy.requiredTags) -contains '[EVIDENCE]' -and $memoryPolicy.teamTasks.enabled -eq $true -and @($memoryPolicy.teamTasks.dispatchLevels) -contains 'review_board' -and @($memoryPolicy.teamTasks.requiredDelegationFields) -contains 'evidence') { Mark-Ok 'memory policy team task schema' } else { Mark-Fail 'memory policy team task schema missing' }
if ($memoryPolicy.teamTasks.codeCapable.requiresCommanderAuthorization -eq $true -and $memoryPolicy.teamTasks.codeCapable.requiresAllowedFiles -eq $true -and $memoryPolicy.teamTasks.codeCapable.requiresForbiddenFiles -eq $true -and $memoryPolicy.teamTasks.codeCapable.requiresVerificationCommands -eq $true -and $memoryPolicy.teamTasks.codeCapable.requiresReviewBeforeAcceptance -eq $true -and $memoryPolicy.teamTasks.codeCapable.patchApplication -eq 'reserved_not_automatic') { Mark-Ok 'memory policy code-capable schema' } else { Mark-Fail 'memory policy code-capable schema missing' }

try {
  $maintenancePolicy = Read-Utf8 'maintenance-policy.json' | ConvertFrom-Json
  Mark-Ok 'maintenance-policy.json parse'
} catch {
  Mark-Fail "maintenance-policy.json parse $($_.Exception.Message)"
  $maintenancePolicy = [pscustomobject]@{}
}
if ($maintenancePolicy.mode -eq 'bounded_auto' -and $maintenancePolicy.automaticActions.postTaskMaintenance.enabled -eq $true -and @($maintenancePolicy.requiresConfirmation).Count -gt 0 -and @($maintenancePolicy.continuationPriority)[0] -eq 'visible_context') { Mark-Ok 'maintenance policy bounded auto schema' } else { Mark-Fail 'maintenance policy bounded auto schema missing' }

$runtimeFiles = @($manifest.runtimeFiles)
if ($runtimeFiles.Count -gt 0) { Mark-Ok 'runtime files manifest present' } else { Mark-Fail 'runtime files manifest missing' }
foreach ($runtimeFile in $runtimeFiles) {
  if (Test-Path (Join-Path (Join-Path $Root 'vendor\NexSandglass-Agent-DedicatedMemory') $runtimeFile)) { Mark-Ok "runtime vendor file $runtimeFile" } else { Mark-Fail "runtime vendor file missing $runtimeFile" }
}

try {
  $resolvedHookPath = Get-SuperBrainHookPath ''
  if (-not [string]::IsNullOrWhiteSpace($resolvedHookPath)) { Mark-Ok 'hook auto discovery' } else { Mark-Fail 'hook auto discovery empty' }
} catch {
  Mark-Fail "hook auto discovery $($_.Exception.Message)"
}

try {
  Read-Utf8 'tests\memory-recall-tests.json' | ConvertFrom-Json | Out-Null
  Mark-Ok 'memory-recall-tests.json parse'
} catch {
  Mark-Fail "memory-recall-tests.json parse $($_.Exception.Message)"
}
try {
  Read-Utf8 'tests\memory-eval-tests.json' | ConvertFrom-Json | Out-Null
  Mark-Ok 'memory-eval-tests.json parse'
} catch {
  Mark-Fail "memory-eval-tests.json parse $($_.Exception.Message)"
}

$baselineText = Read-Utf8 'CURRENT_BASELINE.md'
if ($baselineText -like "*Package Version: $($manifest.version)*") { Mark-Ok 'Baseline version' } else { Mark-Fail 'Baseline version mismatch' }
if ($baselineText -match '鈹|锛|瀹|�|\x07') { Mark-Fail 'CURRENT_BASELINE.md mojibake markers' } else { Mark-Ok 'CURRENT_BASELINE.md encoding markers' }
if ($baselineText -like '*CURRENT_BASELINE.md*manifest.json*CHANGELOG.md*') { Mark-Ok 'baseline recall order' } else { Mark-Fail 'baseline recall order missing' }

$historyText = Read-Utf8 'BASELINE_HISTORY.md'
if ($historyText -like "*## $($manifest.version)*") { Mark-Ok 'Baseline history' } else { Mark-Fail 'Baseline history missing current version' }

$changelogText = Read-Utf8 'CHANGELOG.md'
if ($changelogText -like "*## $($manifest.version)*") { Mark-Ok 'Changelog current version' } else { Mark-Fail 'Changelog missing current version' }

$readmeText = Read-Utf8 'README.md'
if ($readmeText -like "*$($manifest.version)*") { Mark-Ok 'README current version' } else { Mark-Fail 'README missing current version' }
if ($readmeText -like '*CURRENT_BASELINE.md*manifest.json*CHANGELOG.md*') { Mark-Ok 'README recall order' } else { Mark-Fail 'README recall order missing' }
if ($readmeText -like '*QUICK_START.md*' -and $readmeText -like '*COMMANDS.md*' -and $readmeText -like '*doctor.ps1*') { Mark-Ok 'README quick command docs' } else { Mark-Fail 'README quick command docs missing' }
if ($readmeText -like '*last-ci.json*') { Mark-Ok 'README CI status docs' } else { Mark-Fail 'README CI status docs missing' }
if ($readmeText.Contains('Hybrid Recall') -and $readmeText.Contains('memory-eval.ps1') -and $readmeText.Contains('last-memory-eval.json') -and $readmeText.Contains('[ADR]')) { Mark-Ok 'README hybrid ADR eval docs' } else { Mark-Fail 'README hybrid ADR eval docs missing' }
if ($readmeText -like '*cleanup-install-backups.ps1*') { Mark-Ok 'README install backup cleanup docs' } else { Mark-Fail 'README install backup cleanup docs missing' }
if ($readmeText -like '*install-ui.ps1*' -and $readmeText -like '*install-ui.vbs*' -and $readmeText -like '*install.bat console*' -and $readmeText -like '*scripts\brain.bat*' -and $readmeText -like '*控制台*' -and $readmeText -like '*一键全局注入/刷新*' -and $readmeText -like '*install-backup-*' -and $readmeText -like '*实时写入日志框*' -and $readmeText -like '*check-install-ui-paths.ps1*') { Mark-Ok 'README skill injector UI docs' } else { Mark-Fail 'README skill injector UI docs missing' }
if ($readmeText -like '*Commander Agent Teams*' -and $readmeText -like '*team-dispatch-check.ps1*' -and $readmeText -like '*team-task-status.ps1*') { Mark-Ok 'README Commander team docs' } else { Mark-Fail 'README Commander team docs missing' }

$quickStartText = Read-Utf8 'QUICK_START.md'
if ($quickStartText -like '*doctor.ps1*' -and $quickStartText -like '*summary.ps1*' -and $quickStartText -like '*startup-check.ps1*' -and $quickStartText -like '*skill-sync-check.ps1*' -and $quickStartText -like '*memory-mode.ps1*' -and $quickStartText -like '*memory-health.ps1*' -and $quickStartText -like '*release-share.ps1*') { Mark-Ok 'QUICK_START command coverage' } else { Mark-Fail 'QUICK_START command coverage missing' }
if (($quickStartText -like '*install backups*' -or $quickStartText -like '*安装备份*') -and ($quickStartText -like '*dry-run preview*' -or $quickStartText -like '*预览*')) { Mark-Ok 'QUICK_START install backup cleanup docs' } else { Mark-Fail 'QUICK_START install backup cleanup docs missing' }
if ($quickStartText -like '*install-ui.vbs*' -and $quickStartText -like '*install.bat console*' -and $quickStartText -like '*技能注入器*' -and $quickStartText -like '*全局共享记忆*' -and $quickStartText -like '*实时显示子脚本日志*' -and $quickStartText -like '*check-install-ui-paths.ps1*') { Mark-Ok 'QUICK_START skill injector UI docs' } else { Mark-Fail 'QUICK_START skill injector UI docs missing' }
if ($quickStartText -like '*team-dispatch-check.ps1*' -and $quickStartText -like '*Commander*') { Mark-Ok 'QUICK_START Commander team docs' } else { Mark-Fail 'QUICK_START Commander team docs missing' }
if ($quickStartText -like '*Hybrid Recall*' -and $quickStartText -like '*memory-eval.ps1*' -and $quickStartText -like '*last-memory-eval.json*' -and $quickStartText -like '*AdrOnly*') { Mark-Ok 'QUICK_START hybrid ADR eval docs' } else { Mark-Fail 'QUICK_START hybrid ADR eval docs missing' }

$commandsText = Read-Utf8 'COMMANDS.md'
if ($commandsText -like '*script-tiers.ps1*' -and $commandsText -like '*T0*' -and $commandsText -like '*T3*') { Mark-Ok 'COMMANDS tier coverage' } else { Mark-Fail 'COMMANDS tier coverage missing' }
if ($commandsText -like '*cleanup-install-backups.ps1*' -and $commandsText -like '*cleanup-install-backups.ps1 -Apply*') { Mark-Ok 'COMMANDS install backup cleanup coverage' } else { Mark-Fail 'COMMANDS install backup cleanup coverage missing' }
if ($commandsText -like '*install-ui.ps1 -SmokeTest*' -and $commandsText -like '*install-ui.vbs*' -and $commandsText -like '*brain.bat*' -and $commandsText -like '*控制台*' -and $commandsText -like '*install.bat console*' -and $commandsText -like '*Chinese native Windows skill injector UI*' -and $commandsText -like '*install-backup-*' -and $commandsText -like '*check-install-ui-paths.ps1*') { Mark-Ok 'COMMANDS skill injector UI coverage' } else { Mark-Fail 'COMMANDS skill injector UI coverage missing' }
if ($commandsText -like '*memory-eval.ps1 -Json*' -and $commandsText -like '*memory-eval-report.ps1*' -and $commandsText -like '*write-decision.ps1 -Adr*' -and $commandsText -like '*decision-search.ps1 -AdrOnly*') { Mark-Ok 'COMMANDS hybrid ADR eval coverage' } else { Mark-Fail 'COMMANDS hybrid ADR eval coverage missing' }
if ($commandsText -like '*team-dispatch-check.ps1 -Json*' -and $commandsText -like '*team-task-new.ps1*' -and $commandsText -like '*team-task-decision.ps1*' -and $commandsText -like '*team-task-status.ps1*' -and $commandsText -like '*team-task-review-gate.ps1*' -and $commandsText -like '*team-memory-retrieval.ps1*' -and $commandsText -like '*roadmap-manager.ps1*' -and $commandsText -like '*memory-regression-checker.ps1*' -and $commandsText -like '*task-state-reporter.ps1*' -and $commandsText -like '*privacy-sentinel.ps1*' -and $commandsText -like '*completion-guard.ps1*' -and $commandsText -like '*super-brain-dashboard.ps1*' -and $commandsText -like '*auto-continuation.ps1*' -and $commandsText -like '*status-snapshot-writer.ps1*' -and $commandsText -like '*privacy-hit-locator.ps1*' -and $commandsText -like '*memory-quality-fixer.ps1*' -and $commandsText -like '*optimize-advisor.ps1*' -and $commandsText -like '*lesson-replay.ps1*') { Mark-Ok 'COMMANDS Commander team coverage' } else { Mark-Fail 'COMMANDS Commander team coverage missing' }

$graphText = Read-Utf8 'memory\graph.jsonl'
$currentSubject = '"subject":"v' + $manifest.version + '"'
if ($graphText -like "*$currentSubject*") { Mark-Ok 'graph current lineage' } else { Mark-Fail 'graph current lineage missing' }
$graphParseErrors = 0
foreach ($graphLine in @($graphText -split "`r?`n")) {
  if ([string]::IsNullOrWhiteSpace($graphLine)) { continue }
  $cleanGraphLine = $graphLine.TrimStart([char]0xFEFF)
  try { $cleanGraphLine | ConvertFrom-Json | Out-Null } catch { $graphParseErrors += 1 }
}
if ($graphParseErrors -eq 0) { Mark-Ok 'graph jsonl parse' } else { Mark-Fail "graph jsonl parse errors $graphParseErrors" }

$migrateMemoryText = Read-Utf8 'scripts\migrate-memory-layout.ps1'
if ($migrateMemoryText -like '*Merge-TextMemoryFile*' -and $migrateMemoryText -like '*MIGRATED_LEGACY_MEMORY*' -and $migrateMemoryText -like '*MIGRATE_KEEP_NEW*') { Mark-Ok 'migrate memory merge strategy' } else { Mark-Fail 'migrate memory merge strategy missing' }

$writeDecisionText = Read-Utf8 'scripts\write-decision.ps1'
if ($writeDecisionText -like '*decision_particles*' -and $writeDecisionText -like '*[DECISION][CURRENT][VERIFIED]*' -and $writeDecisionText -like '*Add-GraphRecord*') { Mark-Ok 'write decision structured lifecycle' } else { Mark-Fail 'write decision structured lifecycle missing' }
if ($writeDecisionText.Contains('[ADR]') -and $writeDecisionText.Contains('has_status') -and $writeDecisionText.Contains('has_context') -and $writeDecisionText.Contains('has_consequence') -and $writeDecisionText.Contains('superseded_by')) { Mark-Ok 'write decision ADR lifecycle' } else { Mark-Fail 'write decision ADR lifecycle missing' }

$doctorText = Read-Utf8 'scripts\doctor.ps1'
if ($doctorText -like '*session-binding.json*' -and $doctorText -like '*session_binding_expired*' -and $doctorText -like '*session_binding_version_mismatch*' -and $doctorText -like '*session_binding_memory_root_mismatch*' -and $doctorText -like '*session_binding_raw_content_risk*') { Mark-Ok 'doctor session binding risk visibility' } else { Mark-Fail 'doctor session binding risk visibility missing' }

$checkpointWriterText = Read-Utf8 'scripts\checkpoint-writer.ps1'
if ($checkpointWriterText -like '*AgentId*' -and $checkpointWriterText -like '*SessionName*' -and $checkpointWriterText -like '*TaskName*' -and $checkpointWriterText -like '*MemoryIds*' -and $checkpointWriterText -like '*session-task-links.json*' -and $checkpointWriterText -like '*task-memory-links.json*') { Mark-Ok 'checkpoint writer shared identity index' } else { Mark-Fail 'checkpoint writer shared identity index missing' }
$taskRegisterText = Read-Utf8 'scripts\task-register.ps1'
if ($taskRegisterText -like '*memory/shared/agents*' -and $taskRegisterText -like '*session-task-links.json*' -and $taskRegisterText -like '*task-memory-links.json*' -and $taskRegisterText -like '*Fast path only*' -and $taskRegisterText -like '*SessionTitle*' -and $taskRegisterText -like '*ConversationTitle*') { Mark-Ok 'task register fast identity path' } else { Mark-Fail 'task register fast identity path missing' }
if ($taskRegisterText -notlike '*active-checkpoint.json*' -or $taskRegisterText -like '*never touches active-checkpoint.json*') { Mark-Ok 'task register avoids active checkpoint lifecycle' } else { Mark-Fail 'task register active checkpoint write risk' }
if ($taskRegisterText -like '*doctor.ps1*' -or $taskRegisterText -like '*verify-package.ps1*' -or $taskRegisterText -like '*hot-refresh-skills.ps1*' -or $taskRegisterText -like '*ci.ps1*' -or $taskRegisterText -like '*super-brain-dashboard.ps1*' -or $taskRegisterText -like '*recall-search.ps1*') { Mark-Ok 'task register documents heavy-flow exclusions' } else { Mark-Fail 'task register heavy-flow exclusion markers missing' }
$taskIndexText = Read-Utf8 'scripts\task-index.ps1'
if ($taskIndexText.Contains('[switch]$Table') -and $taskIndexText.Contains('[string]$Agent') -and $taskIndexText.Contains('[string]$SessionId') -and $taskIndexText.Contains('sessionName') -and $taskIndexText.Contains('agentId') -and $taskIndexText.Contains('identityKey') -and $taskIndexText.Contains('未知，不等于没有任务') -and $taskIndexText.Contains('# | 来源 | 会话 / 状态 | 进度')) { Mark-Ok 'task-index shared identity compact table' } else { Mark-Fail 'task-index shared identity compact table missing' }
$skillText = Read-Utf8 'super-memory-brain\SKILL.md'
if ($skillText -like '*Cross-agent/session task identity index rule*' -and $skillText -like '*compact task status table*' -and $skillText -like '*sessionName*' -and $skillText -like '*agentId*' -and $skillText -like '*未知，不等于没有任务*') { Mark-Ok 'entry skill task identity table rule' } else { Mark-Fail 'entry skill task identity table rule missing' }

$repairHookText = Read-Utf8 'scripts\repair-hook.ps1'
if ($repairHookText -like '*MaxStartupRuleChars*' -and $repairHookText -like '*startup rule too long*') { Mark-Ok 'repair hook startup length guard' } else { Mark-Fail 'repair hook startup length guard missing' }
if ($repairHookText -like '*load Skill super-memory-brain first*' -and $repairHookText -like '*explicit*' -and $repairHookText -like '*memory:auto silent*' -and $repairHookText -like '*visible G1*' -and $repairHookText -like '*no G1 for ok/chat/code*' -and $repairHookText -like '*light recall if state needed*' -and $repairHookText -like '*semantic/keyword recall*') { Mark-Ok 'repair hook silent explicit router rule' } else { Mark-Fail 'repair hook silent explicit router rule missing' }

$skillText = Read-Utf8 'super-memory-brain\SKILL.md'
if ($skillText.Contains('must first load this `super-memory-brain` skill in read-only mode') -and $skillText.Contains('does not block loading this skill')) { Mark-Ok 'entry skill mandatory load rule' } else { Mark-Fail 'entry skill mandatory load rule missing' }
if ($skillText.Contains('Bare Super Brain trigger rule') -and $skillText.Contains('Do not treat these bare wake words as ordinary greeting/chat') -and $skillText.Contains('Explicit skill links') -and $skillText.Contains('`超级大脑`') -and $skillText.Contains('`G1`')) { Mark-Ok 'entry skill bare Super Brain trigger rule' } else { Mark-Fail 'entry skill bare Super Brain trigger rule missing' }
if ($skillText.Contains('0. Ensure this `super-memory-brain` skill has been loaded read-only')) { Mark-Ok 'entry skill answer priority includes skill load' } else { Mark-Fail 'entry skill answer priority skill load missing' }
if ($skillText.Contains('memory:auto') -and $skillText.Contains('keyword + semantic triggers') -and $skillText.Contains('silent by default') -and $skillText.Contains('Plan/Explore/Tool thresholds')) { Mark-Ok 'entry skill silent memory router policy' } else { Mark-Fail 'entry skill silent memory router policy missing' }
if ($skillText.Contains('package-root.txt') -and $skillText.Contains('memory-root.txt')) { Mark-Ok 'entry skill root marker support' } else { Mark-Fail 'entry skill root marker support missing' }
if ($skillText.Contains('Default sharing rule') -and $skillText.Contains('global shared memory') -and $skillText.Contains('silently by default') -and $skillText.Contains('Do not print the START checklist')) { Mark-Ok 'entry skill default shared and silent START rules' } else { Mark-Fail 'entry skill default shared or silent START rules missing' }
if ($skillText.Contains('Visible `G1` prefix is explicit-only') -and $skillText.Contains('standalone `G1` line') -and $skillText.Contains('ordinary acknowledgements') -and $skillText.Contains('dormant `memory:auto` routing') -and $skillText.Contains('Prevent logic breakpoints') -and $skillText.Contains('continue from the next concrete action')) { Mark-Ok 'entry skill explicit-only G1 prefix and breakpoint recovery rules' } else { Mark-Fail 'entry skill explicit-only G1 prefix or breakpoint recovery rules missing' }
if ($skillText.Contains('START rule') -and $skillText.Contains('completion status') -and $skillText.Contains('what remains')) { Mark-Ok 'entry skill START response discipline' } else { Mark-Fail 'entry skill START response discipline missing' }
if ($skillText.Contains('Commander Team Memory') -and $skillText.Contains('off the cold-start path') -and $skillText.Contains('only loads Commander Team Memory when the user explicitly asks') -and $skillText.Contains('Commander Team Memory stays unloaded until explicit approval') -and $skillText.Contains('Findings without evidence are assumptions')) { Mark-Ok 'entry skill Commander team explicit-only cold-start gate' } else { Mark-Fail 'entry skill Commander team explicit-only cold-start gate missing' }

if ($skillText.Contains('Temporary session binding protocol') -and $skillText.Contains('session-binding.json') -and $skillText.Contains('raw full chat') -and $skillText.Contains('memory:off') -and $skillText.Contains('Avoidable Issue Elimination Rule')) { Mark-Ok 'entry skill session binding and avoidable issue rules' } else { Mark-Fail 'entry skill session binding or avoidable issue rules missing' }
if ($skillText.Contains('Learn protocol') -and $skillText.Contains('session-restore.ps1') -and $skillText.Contains('Token budget rule') -and $skillText.Contains('learn-memory.ps1')) { Mark-Ok 'entry skill learn and session restore protocols' } else { Mark-Fail 'entry skill learn or session restore protocols missing' }

if ($skillText.Contains('Version iteration review rule') -and $skillText.Contains('before/after comparison checklist') -and $skillText.Contains('positive optimization') -and $skillText.Contains('negative optimization/regression') -and $skillText.Contains('Detail-control rule') -and $skillText.Contains('large mistakes are prevented')) { Mark-Ok 'entry skill version iteration and detail-control rules' } else { Mark-Fail 'entry skill version iteration or detail-control rules missing' }
if ($skillText.Contains('long-memory risk') -and $skillText.Contains('proactively inspect and compress') -and $skillText.Contains('ADR/graph evidence') -and $skillText.Contains('Experience learning rule') -and $skillText.Contains('user preference patterns')) { Mark-Ok 'entry skill proactive compression and experience learning rules' } else { Mark-Fail 'entry skill proactive compression or experience learning rules missing' }

$orcText = Read-Utf8 'modules\skill-orchestrator\SKILL.md'
if ($orcText.Contains('before/after comparison checklist') -and $orcText.Contains('positive optimizations') -and $orcText.Contains('negative optimizations/regressions') -and $orcText.Contains('meticulous detail control') -and $orcText.Contains('release assets')) { Mark-Ok 'ORC version iteration and detail-control rules' } else { Mark-Fail 'ORC version iteration or detail-control rules missing' }
if ($orcText.Contains('Temporary session binding') -and $orcText.Contains('Avoidable Issue Elimination Rule') -and $orcText.Contains('expired, mismatched, `memory:off`, or privacy-risky') -and $orcText.Contains('preventable failures')) { Mark-Ok 'ORC session binding and avoidable issue rules' } else { Mark-Fail 'ORC session binding or avoidable issue rules missing' }
if ($orcText.Contains('hidden long-memory risk') -and $orcText.Contains('proactively compress') -and $orcText.Contains('reusable experience') -and $orcText.Contains('user preference patterns')) { Mark-Ok 'ORC proactive compression and experience learning rules' } else { Mark-Fail 'ORC proactive compression or experience learning rules missing' }
if ($orcText.Contains('Team Dispatch On Demand') -and $orcText.Contains('routing dormant by default') -and $orcText.Contains('Do not run dispatch scoring') -and $orcText.Contains('Load Commander Team Memory only when the user explicitly asks') -and $orcText.Contains('do not load templates, inspect team-task state, or run team dispatch scoring') -and $orcText.Contains('Code-capable subagents require explicit Commander authorization')) { Mark-Ok 'ORC team dispatch explicit-only on-demand rules' } else { Mark-Fail 'ORC team dispatch explicit-only on-demand rules missing' }

$startupCheckText = Read-Utf8 'scripts\startup-check.ps1'
if ($startupCheckText -like '*Hook startup rule length*' -and $startupCheckText -like '*MaxStartupRuleChars*') { Mark-Ok 'startup hook length check' } else { Mark-Fail 'startup hook length check missing' }
if ($startupCheckText -like '*Hook short router*' -and $startupCheckText -like '*semantic/keyword recall*' -and $startupCheckText -like '*ORC routes*' -and $startupCheckText -like '*Sandglass on semantic/keyword recall*') { Mark-Ok 'startup hook short router check' } else { Mark-Fail 'startup hook short router check missing' }
if ($startupCheckText -like '*Hook explicit Super Brain wake words*' -and $startupCheckText -like '*load Skill super-memory-brain first*' -and (($startupCheckText -like '*超级大脑*') -or ($startupCheckText -like '*0x8D85*')) -and $startupCheckText -like '*G1*' -and $startupCheckText -like '*explicit*') { Mark-Ok 'startup hook explicit wake word check' } else { Mark-Fail 'startup hook explicit wake word check missing' }
if ($startupCheckText -like '*Hook silent memory auto*' -and $startupCheckText -like '*memory:auto silent*' -and $startupCheckText -like '*no G1 for ok/chat/code*') { Mark-Ok 'startup hook silent memory auto check' } else { Mark-Fail 'startup hook silent memory auto check missing' }

$statusText = Read-Utf8 'scripts\status.ps1'
if ($statusText -like '*Hook mandatory skill load*' -and $statusText -like '*semantic/keyword recall*' -and $statusText -like '*Hook short router*') { Mark-Ok 'status hook short router check' } else { Mark-Fail 'status hook short router check missing' }
if ($statusText -like '*exit 0*') { Mark-Ok 'status explicit success exit' } else { Mark-Fail 'status explicit success exit missing' }
if ($statusText -like '*session-binding.json*' -and $statusText -like '*sessionBinding*' -and $statusText -like '*packageVersionMatch*' -and $statusText -like '*memoryRootMatch*') { Mark-Ok 'status session binding visibility' } else { Mark-Fail 'status session binding visibility missing' }

$compactApplyText = Read-Utf8 'scripts\compact-apply.ps1'
if ($compactApplyText.Contains('[switch]$Force') -and $compactApplyText.Contains('COMPACT_APPLY_CONFIRM_REQUIRED')) { Mark-Ok 'compact apply confirmation guard' } else { Mark-Fail 'compact apply confirmation guard missing' }

$writeMemoryText = Read-Utf8 'scripts\write-memory.ps1'
if ($writeMemoryText -like '*MemoryMode*' -and $writeMemoryText -like '*Layer*' -and $writeMemoryText -like '*Summary*' -and $writeMemoryText -like '*ExpiresAt*' -and $writeMemoryText -like '*negativePatterns*') { Mark-Ok 'write memory layered policy support' } else { Mark-Fail 'write memory layered policy support missing' }
if ($writeMemoryText -like '*profileIntentPatterns*' -and $writeMemoryText -like '*writeAllowSignals*' -and $writeMemoryText -like '*OrdinalIgnoreCase*' -and $writeMemoryText -like '*$Layer = ''profile''*') { Mark-Ok 'write memory profile routing support' } else { Mark-Fail 'write memory profile routing support missing' }

$recallSearchText = Read-Utf8 'scripts\recall-search.ps1'
if ($recallSearchText -like '*TopK*' -and $recallSearchText -like '*MaxTokens*' -and $recallSearchText -like '*MemoryMode*' -and $recallSearchText -like '*summaryFirst*' -and $recallSearchText -like '*Layer*') { Mark-Ok 'recall search router budget support' } else { Mark-Fail 'recall search router budget support missing' }
if ($recallSearchText -like '*sourceType*' -and $recallSearchText -like '*confidence*' -and $recallSearchText -like '*tokenEstimate*' -and $recallSearchText -like '*graph_decision_or_lineage*' -and $recallSearchText -like '*state_recall_priority*') { Mark-Ok 'recall search hybrid candidate schema' } else { Mark-Fail 'recall search hybrid candidate schema missing' }
if ($recallSearchText -like '*Get-RecencyBoost*' -and $recallSearchText -like '*ageDays*' -and $recallSearchText -like '*recencyScore*' -and $recallSearchText -like '*Get-PersonaSnippets*' -and $recallSearchText -like '*profileIntentTriggers*') { Mark-Ok 'recall search recency and persona support' } else { Mark-Fail 'recall search recency and persona support missing' }
if ($recallSearchText -like '*New-EvidenceCard*' -and $recallSearchText -like '*evidenceCard*' -and $recallSearchText -like '*contextBudget*' -and $recallSearchText -like '*maxEvidenceCards*' -and $recallSearchText -like '*cardSnippetTokens*') { Mark-Ok 'recall search context budget evidence card support' } else { Mark-Fail 'recall search context budget evidence card support missing' }
if ($recallSearchText -like '*session-binding.json*' -and $recallSearchText -like '*sessionBinding*' -and $recallSearchText -like '*temporary_session_binding*' -and $recallSearchText -like '*Test-SuperBrainSamePath*' -and $recallSearchText -like '*expiresAt*') { Mark-Ok 'recall search session binding source support' } else { Mark-Fail 'recall search session binding source support missing' }

$learnMemoryText = Read-Utf8 'scripts\learn-memory.ps1'
if ($learnMemoryText -like '*write-memory.ps1*' -and $learnMemoryText -like '*write-experience.ps1*' -and $learnMemoryText -like '*last-learn-memory.json*' -and $learnMemoryText -like '*ConfirmPrivate*' -and $learnMemoryText -like '*Preview*' -and $learnMemoryText -like '*AllowDuplicate*' -and $learnMemoryText -like '*similarEvidenceCards*' -and $learnMemoryText -like '*profile-card.ps1*') { Mark-Ok 'learn memory preview duplicate profile support' } else { Mark-Fail 'learn memory preview duplicate profile support missing' }
if ($learnMemoryText -like '*ValueFromRemainingArguments*' -and $learnMemoryText -like '*RemainingArgs*' -and $learnMemoryText -like '*extraTags*' -and $learnMemoryText -like '*extraEvidence*') { Mark-Ok 'learn memory forgiving string-array CLI support' } else { Mark-Fail 'learn memory forgiving string-array CLI support missing' }

$profileCardText = Read-Utf8 'scripts\profile-card.ps1'
if ($profileCardText -like '*profile-card.json*' -and $profileCardText -like '*profileSummary*' -and $profileCardText -like '*evidenceCards*' -and $profileCardText -like '*MaxTokens*' -and $profileCardText -like '*recall-search.ps1*') { Mark-Ok 'profile card compact support' } else { Mark-Fail 'profile card compact support missing' }

$sessionBindingText = Read-Utf8 'scripts\session-binding.ps1'
if ($sessionBindingText -like '*session-binding.json*' -and $sessionBindingText -like '*bindingId*' -and $sessionBindingText -like '*expiresAt*' -and $sessionBindingText -like '*TtlMinutes*' -and $sessionBindingText -like '*MemoryMode*' -and $sessionBindingText -like '*memory:off*' -and $sessionBindingText -like '*Write-JsonUtf8NoBom*' -and $sessionBindingText -like '*Get-SuperBrainActiveMemoryRoot*' -and $sessionBindingText -like '*noRawChat*' -and $sessionBindingText -like '*currentUserInstructionWins*') { Mark-Ok 'session binding script schema and guards' } else { Mark-Fail 'session binding script schema or guards missing' }

$sessionRestoreText = Read-Utf8 'scripts\session-restore.ps1'
if ($sessionRestoreText -like '*last-session-restore.json*' -and $sessionRestoreText -like '*tokenBudget*' -and $sessionRestoreText -like '*evidenceCards*' -and $sessionRestoreText -like '*active-checkpoint.json*' -and $sessionRestoreText -like '*experience-index.md*' -and $sessionRestoreText -like '*recallTriggered*' -and $sessionRestoreText -like '*profileCard*' -and $sessionRestoreText -like '*profile-card.ps1*' -and $sessionRestoreText -like '*BindSession*' -and $sessionRestoreText -like '*session-binding.ps1*' -and $sessionRestoreText -like '*sessionBinding*' -and $sessionRestoreText -like '*TtlMinutes*') { Mark-Ok 'session restore lightweight protocol script support' } else { Mark-Fail 'session restore lightweight protocol script support missing' }

$acceptedPreflightText = Read-Utf8 'scripts\accepted-constraints-preflight.ps1'
if ($acceptedPreflightText -like '*last-accepted-constraints-preflight.json*' -and $acceptedPreflightText -like '*decision-search.ps1*' -and $acceptedPreflightText -like '*recall-search.ps1*' -and $acceptedPreflightText -like '*active-checkpoint.json*' -and $acceptedPreflightText -like '*session-binding.json*' -and $acceptedPreflightText -like '*mustPreserve*' -and $acceptedPreflightText -like '*mustNotViolate*' -and $acceptedPreflightText -like '*guardHash*' -and $acceptedPreflightText -like '*noTail*') { Mark-Ok 'accepted constraints preflight support' } else { Mark-Fail 'accepted constraints preflight support missing' }

$projectContinuityText = Read-Utf8 'scripts\project-continuity.ps1'
if ($projectContinuityText -like '*task-graph.json*' -and $projectContinuityText -like '*agent-findings*' -and $projectContinuityText -like '*SkipStep*' -and $projectContinuityText -like '*AdmitFinding*' -and $projectContinuityText -like '*RejectFinding*' -and $projectContinuityText -like '*candidate-only*' -and $projectContinuityText -like '*Commander admission*') { Mark-Ok 'project continuity task graph and findings isolation support' } else { Mark-Fail 'project continuity task graph and findings isolation support missing' }
if ($projectContinuityText -like '*super-brain.project-graph.v2*' -and $projectContinuityText -like '*super-brain.structure-baseline.v2*' -and $projectContinuityText -like '*super-brain.step-ledger.v2*' -and $projectContinuityText -like '*open_steps*' -and $projectContinuityText -like '*candidate_findings_pending*') { Mark-Ok 'project continuity v2 status blockers support' } else { Mark-Fail 'project continuity v2 status blockers support missing' }

if ($projectContinuityText -like '*CompleteTask*' -and $projectContinuityText -like '*ClearTask*' -and $projectContinuityText -like '*ArchiveTask*' -and $projectContinuityText -like '*last-completed-task-graph.json*' -and $projectContinuityText -like '*task-archive*') { Mark-Ok 'project continuity task lifecycle support' } else { Mark-Fail 'project continuity task lifecycle support missing' }

$codegraphText = Read-Utf8 'scripts\codegraph-index.ps1'
if ($codegraphText -like '*codegraph-index.json*' -and $codegraphText -like '*last-codegraph-index.json*' -and $codegraphText -like '*Parser]::ParseFile*' -and $codegraphText -like '*FunctionDefinitionAst*' -and $codegraphText -like '*script_call*' -and $codegraphText -like '*hasMutation*') { Mark-Ok 'codegraph index static support' } else { Mark-Fail 'codegraph index static support missing' }
if ($codegraphText -like '*super-brain.codegraph-index.v2*' -and $codegraphText -like '*script_call_joinpath*' -and $codegraphText -like '*script_call_runstep*' -and $codegraphText -like '*script_call_variable*' -and $codegraphText -like '*script_call_dynamic_unknown*' -and $codegraphText -like '*workspace_read*' -and $codegraphText -like '*workspace_write*') { Mark-Ok 'codegraph index v2 dynamic call and workspace dataflow support' } else { Mark-Fail 'codegraph index v2 dynamic call and workspace dataflow support missing' }
if ($codegraphText -like '*CommandAst*' -and $codegraphText -like '*GetCommandName*' -and $codegraphText -like '*Invoke-Expression*' -and $codegraphText -like '*script_call_dynamic_unknown*') { Mark-Ok 'codegraph ast dynamic unknown support' } else { Mark-Fail 'codegraph ast dynamic unknown support missing' }
try {
  $codegraphJsonText = & (Join-Path $PSScriptRoot 'codegraph-index.ps1') -Json -NoWrite
  $codegraphJson = $codegraphJsonText | ConvertFrom-Json
  if ([int]$codegraphJson.summary.scriptCount -gt 0 -and $codegraphJson.schema -eq 'super-brain.codegraph-index.v2') { Mark-Ok 'codegraph index json command' } else { Mark-Fail 'codegraph index json command missing scripts' }
} catch { Mark-Fail "codegraph index json command $($_.Exception.Message)" }

$impactAdvisorText = Read-Utf8 'scripts\impact-advisor.ps1'
if ($impactAdvisorText -like '*last-impact-advisor.json*' -and $impactAdvisorText -like '*riskLevel*' -and $impactAdvisorText -like '*recommendedChecks*' -and $impactAdvisorText -like '*directCallers*' -and $impactAdvisorText -like '*directCallees*' -and $impactAdvisorText -like '*affectedWorkspaceFiles*') { Mark-Ok 'impact advisor static support' } else { Mark-Fail 'impact advisor static support missing' }
try {
  $impactJsonText = & (Join-Path $PSScriptRoot 'impact-advisor.ps1') -ChangedFiles 'scripts/codegraph-index.ps1' -Json
  $impactJson = $impactJsonText | ConvertFrom-Json
  if ($impactJson.schema -eq 'super-brain.impact-advisor.v1' -and -not [string]::IsNullOrWhiteSpace([string]$impactJson.riskLevel)) { Mark-Ok 'impact advisor json command' } else { Mark-Fail 'impact advisor json command missing riskLevel' }
} catch { Mark-Fail "impact advisor json command $($_.Exception.Message)" }

$checkpointWriterText = Read-Utf8 'scripts\checkpoint-writer.ps1'
if ($checkpointWriterText -like '*active-checkpoint.json*' -and $checkpointWriterText -like '*Action = ''Get''*' -and $checkpointWriterText -like '*Start*' -and $checkpointWriterText -like '*Complete*' -and $checkpointWriterText -like '*Clear*' -and $checkpointWriterText -like '*platform*' -and $checkpointWriterText -like '*agent*' -and $checkpointWriterText -like '*sessionId*' -and $checkpointWriterText -like '*taskId*' -and $checkpointWriterText -like '*currentStep*' -and $checkpointWriterText -like '*nextAction*' -and $checkpointWriterText -like '*evidence*' -and $checkpointWriterText -like '*acceptedConstraints*' -and $checkpointWriterText -like '*guardHash*') { Mark-Ok 'checkpoint writer lifecycle constraint support' } else { Mark-Fail 'checkpoint writer lifecycle constraint support missing' }

$autoContinuationText = Read-Utf8 'scripts\auto-continuation.ps1'
if ($autoContinuationText -like '*active-checkpoint.json*' -and $autoContinuationText -like '*currentStep*' -and $autoContinuationText -like '*checkpointStatus*') { Mark-Ok 'auto continuation checkpoint support' } else { Mark-Fail 'auto continuation checkpoint support missing' }

$dashboardText = Read-Utf8 'scripts\super-brain-dashboard.ps1'
if ($dashboardText -like '*active-checkpoint.json*' -and $dashboardText -like '*active_checkpoint_present*' -and $dashboardText -like '*activeCheckpoint*') { Mark-Ok 'dashboard checkpoint support' } else { Mark-Fail 'dashboard checkpoint support missing' }

$completionGuardText = Read-Utf8 'scripts\completion-guard.ps1'
if ($completionGuardText -like '*active-checkpoint*' -and $completionGuardText -like '*status=*' -and $completionGuardText -like '*none*' -and $completionGuardText -like '*last-accepted-constraints-preflight.json*' -and $completionGuardText -like '*accepted-constraints-preflight*') { Mark-Ok 'completion guard checkpoint constraint support' } else { Mark-Fail 'completion guard checkpoint constraint support missing' }
if ($completionGuardText -like '*last-runtime-drift-checkpoint.json*' -and $completionGuardText -like '*runtime-drift-checkpoint*' -and $completionGuardText -like '*unresolvedDrift*') { Mark-Ok 'completion guard runtime drift support' } else { Mark-Fail 'completion guard runtime drift support missing' }
if ($completionGuardText -like '*last-route-checkpoint.json*' -and $completionGuardText -like '*route-checkpoint*' -and $completionGuardText -like '*unresolvedRouteDrift*') { Mark-Ok 'completion guard route drift support' } else { Mark-Fail 'completion guard route drift support missing' }
if ($completionGuardText -like '*last-integration-parity-check.json*' -and $completionGuardText -like '*integration-parity-check*' -and $completionGuardText -like '*unresolvedIntegrationDrift*' -and $completionGuardText -like '*moduleVerification*' -and $completionGuardText -like '*userAcceptanceVerification*') { Mark-Ok 'completion guard integration parity support' } else { Mark-Fail 'completion guard integration parity support missing' }

$goalRouteText = Read-Utf8 'scripts\goal-route-lock.ps1'
if ($goalRouteText -like '*super-brain.goal-route-lock.v1*' -and $goalRouteText -like '*goal-route-lock.json*' -and $goalRouteText -like '*acceptedGoal*' -and $goalRouteText -like '*acceptedRoute*' -and $goalRouteText -like '*mustNotDriftTo*' -and $goalRouteText -like '*routeHash*') { Mark-Ok 'goal route lock support' } else { Mark-Fail 'goal route lock support missing' }
$routeCheckpointText = Read-Utf8 'scripts\route-checkpoint.ps1'
if ($routeCheckpointText -like '*super-brain.route-checkpoint.v1*' -and $routeCheckpointText -like '*ROUTE_DRIFT_DETECTED*' -and $routeCheckpointText -like '*unresolvedRouteDrift*' -and $routeCheckpointText -like '*goal_route_drift*' -and $routeCheckpointText -like '*scope_creep*') { Mark-Ok 'route checkpoint support' } else { Mark-Fail 'route checkpoint support missing' }
$moduleSnapshotText = Read-Utf8 'scripts\verified-module-snapshot.ps1'
if ($moduleSnapshotText -like '*super-brain.verified-module-snapshot.v1*' -and $moduleSnapshotText -like '*verifiedBehavior*' -and $moduleSnapshotText -like '*entrypoint*' -and $moduleSnapshotText -like '*environment*' -and $moduleSnapshotText -like '*snapshotHash*') { Mark-Ok 'verified module snapshot support' } else { Mark-Fail 'verified module snapshot support missing' }
$integrationParityText = Read-Utf8 'scripts\integration-parity-check.ps1'
if ($integrationParityText -like '*super-brain.integration-parity-check.v1*' -and $integrationParityText -like '*INTEGRATION_DRIFT_DETECTED*' -and $integrationParityText -like '*module smoke OK*' -and $integrationParityText -like '*integration smoke OK*' -and $integrationParityText -like '*user-facing acceptance OK*' -and $integrationParityText -like '*scattered_assembly*' -and $integrationParityText -like '*module_context_changed*') { Mark-Ok 'integration parity guard support' } else { Mark-Fail 'integration parity guard support missing' }

$cognitiveEnforceText = Read-Utf8 'scripts\cognitive-enforce.ps1'
if ($cognitiveEnforceText -like '*super-brain.cognitive-enforce.v1*' -and $cognitiveEnforceText -like '*last-cognitive-enforce.json*' -and $cognitiveEnforceText -like '*AllowMissingPreflight*' -and $cognitiveEnforceText -like '*High-risk work must pass cognitive preflight*') { Mark-Ok 'cognitive enforce hard gate support' } else { Mark-Fail 'cognitive enforce hard gate support missing' }

$runtimeDriftText = Read-Utf8 'scripts\runtime-drift-checkpoint.ps1'
if ($runtimeDriftText -like '*super-brain.runtime-drift-checkpoint.v1*' -and $runtimeDriftText -like '*DRIFT_DETECTED*' -and $runtimeDriftText -like '*unresolvedDrift*' -and $runtimeDriftText -like '*BeforeCompletion*' -and $runtimeDriftText -like '*reply_as_goal_completed*') { Mark-Ok 'runtime drift checkpoint support' } else { Mark-Fail 'runtime drift checkpoint support missing' }

$reflectionPromotionText = Read-Utf8 'scripts\reflection-promotion.ps1'
if ($reflectionPromotionText -like '*super-brain.reflection-promotion.v1*' -and $reflectionPromotionText -like '*defaultNoDurableWrite*' -and $reflectionPromotionText -like '*privacyCheck*' -and $reflectionPromotionText -like '*duplicateCheck*' -and $reflectionPromotionText -like '*skill-evolution.ps1*' -and $reflectionPromotionText -like '*learn-memory.ps1*') { Mark-Ok 'reflection promotion self-learning support' } else { Mark-Fail 'reflection promotion self-learning support missing' }
if ($reflectionPromotionText -like '*candidateType*' -and $reflectionPromotionText -like '*gap*' -and $reflectionPromotionText -like '*logic_breakpoint*' -and $reflectionPromotionText -like '*missing_route_lock*' -and $reflectionPromotionText -like '*integration_drift*' -and $reflectionPromotionText -like '*noDurableWriteWithoutApply*') { Mark-Ok 'reflection promotion gap and logic breakpoint candidates' } else { Mark-Fail 'reflection promotion gap and logic breakpoint candidates missing' }

$procedureCardText = Read-Utf8 'memory\workspace\procedure-cards\agent-bridge-channel.json'
if ($procedureCardText -like '*super-brain.procedure-card.v1*' -and $procedureCardText -like '*nested_agent_launch*' -and $procedureCardText -like '*idle_as_blocked*' -and $procedureCardText -like '*auto_close_without_explicit_close*') { Mark-Ok 'AgentBridge procedure memory card support' } else { Mark-Fail 'AgentBridge procedure memory card support missing' }
$goalProcedureCardText = Read-Utf8 'memory\workspace\procedure-cards\goal-route-lock.json'
if ($goalProcedureCardText -like '*super-brain.procedure-card.v1*' -and $goalProcedureCardText -like '*goal_route_drift*' -and $goalProcedureCardText -like '*scope_creep*' -and $goalProcedureCardText -like '*known facts -> cause*') { Mark-Ok 'goal route procedure memory card support' } else { Mark-Fail 'goal route procedure memory card support missing' }
$integrationProcedureCardText = Read-Utf8 'memory\workspace\procedure-cards\verified-integration-guard.json'
if ($integrationProcedureCardText -like '*super-brain.procedure-card.v1*' -and $integrationProcedureCardText -like '*module smoke OK*' -and $integrationProcedureCardText -like '*integration smoke OK*' -and $integrationProcedureCardText -like '*user-facing acceptance OK*' -and $integrationProcedureCardText -like '*scattered_assembly*') { Mark-Ok 'verified integration procedure memory card support' } else { Mark-Fail 'verified integration procedure memory card support missing' }

$statusSnapshotWriterText = Read-Utf8 'scripts\status-snapshot-writer.ps1'
if ($statusSnapshotWriterText -like '*ClearCheckpoint*' -and $statusSnapshotWriterText -like '*checkpoint-writer.ps1*') { Mark-Ok 'status snapshot checkpoint clearing support' } else { Mark-Fail 'status snapshot checkpoint clearing support missing' }
if ($statusSnapshotWriterText -like '*last-project-continuity.json*' -and $statusSnapshotWriterText -like '*task-graph.json*' -and $statusSnapshotWriterText -like '*last-impact-advisor.json*' -and $statusSnapshotWriterText -like '*codegraph*' -and $statusSnapshotWriterText -like '*continuity*' -and $statusSnapshotWriterText -like '*impact*') { Mark-Ok 'status snapshot crash continuation summaries' } else { Mark-Fail 'status snapshot crash continuation summaries missing' }

$taskVerificationText = Read-Utf8 'scripts\task-verification.ps1'
if ($taskVerificationText -like '*checkpoint-writer.ps1*' -and $taskVerificationText -like '*Action Complete*' -and $taskVerificationText -like '*constraintPreflight*' -and $taskVerificationText -like '*constraintsPreserved*') { Mark-Ok 'task verification checkpoint constraint completion support' } else { Mark-Fail 'task verification checkpoint constraint completion support missing' }
if ($taskVerificationText -like '*project-continuity.ps1*' -and $taskVerificationText -like '*CompleteTask*' -and $taskVerificationText -like '*status-snapshot-writer.ps1*' -and $taskVerificationText -like '*continuity*' -and $taskVerificationText -like '*impact*') { Mark-Ok 'task verification auto continuity snapshot support' } else { Mark-Fail 'task verification auto continuity snapshot support missing' }

$decisionSearchText = Read-Utf8 'scripts\decision-search.ps1'
if ($decisionSearchText -like '*TopK*' -and $decisionSearchText -like '*MaxTokens*') { Mark-Ok 'decision search budget support' } else { Mark-Fail 'decision search budget support missing' }
if ($decisionSearchText -like '*AdrOnly*' -and $decisionSearchText -like '*Status*' -and $decisionSearchText -like '*Owner*' -and $decisionSearchText -like '*Scope*' -and $decisionSearchText -like '*supersededBy*') { Mark-Ok 'decision search ADR filters' } else { Mark-Fail 'decision search ADR filters missing' }

$memoryModeText = Read-Utf8 'scripts\memory-mode.ps1'
if ($memoryModeText -like '*Shared*' -and $memoryModeText -like '*SplitMemory*' -and $memoryModeText -like '*AgentName*' -and $memoryModeText -like '*GroupName*' -and $memoryModeText -like '*memory-root.txt*' -and $memoryModeText -like '*Get-SuperBrainSharedMemoryRoot*' -and $memoryModeText -like '*Get-SuperBrainGroupMemoryRoot*') { Mark-Ok 'memory mode script support' } else { Mark-Fail 'memory mode script support missing' }

$commonText = Read-Utf8 'scripts\common.ps1'
if ($commonText -like '*Get-SuperBrainSharedMemoryRoot*' -and $commonText -like '*Get-SuperBrainAgentMemoryRoot*' -and $commonText -like '*Get-SuperBrainGroupMemoryRoot*' -and $commonText -like '*memory-sharing-policy.json*' -and $commonText -like '*.memory-scope.json*') { Mark-Ok 'scoped memory layout helpers' } else { Mark-Fail 'scoped memory layout helpers missing' }
if ($commonText.Contains("initialized = `$true") -and $commonText.Contains("mode = 'shared'") -and $commonText.Contains('Default installs use all-agent shared memory')) { Mark-Ok 'default shared memory policy' } else { Mark-Fail 'default shared memory policy missing' }

if ($commonText -like '*Compaction/resume priority*' -and $commonText -like '*visible conversation*' -and $commonText -like '*Maintenance autonomy*' -and $commonText -like '*post-task maintenance*') { Mark-Ok 'global startup compaction and maintenance autonomy guards' } else { Mark-Fail 'global startup compaction or maintenance autonomy guards missing' }

$installAgentText = Read-Utf8 'scripts\install-agent.ps1'
if ($installAgentText -like '*AgentName*' -and $installAgentText -like '*SkillRoot*' -and $installAgentText.Contains("[string]`$Mode = 'Shared'") -and $installAgentText -like '*Get-SuperBrainAgentMemoryRoot*' -and $installAgentText -like '*Write-SuperBrainMemoryRootMarker*') { Mark-Ok 'generic agent install support' } else { Mark-Fail 'generic agent install support missing' }

$hotRefreshText = Read-Utf8 'scripts\hot-refresh-skills.ps1'
if ($hotRefreshText -like '*last-hot-refresh.json*' -and $hotRefreshText -like '*HOT_REFRESH_OK*' -and $hotRefreshText -like '*Get-SuperBrainSourceItems*' -and $hotRefreshText -like '*package-root.txt*' -and $hotRefreshText -like '*Write-SuperBrainMemoryRootMarker*') { Mark-Ok 'hot refresh skills support' } else { Mark-Fail 'hot refresh skills support missing' }

$installMenuText = Read-Utf8 'scripts\install-menu.ps1'
if ($installMenuText -like '*Get-AgentCandidates*' -and $installMenuText -like '*Install-ManualAgent*' -and $installMenuText -like '*install-agent.ps1*' -and $installMenuText -like '*Global inject / refresh ZCode + Codex*') { Mark-Ok 'bat menu skill injector support' } else { Mark-Fail 'bat menu skill injector support missing' }
if ($installMenuText -like '*cleanup-install-backups.ps1*' -and $installMenuText -like '*Keep how many newest install backups*' -and $installMenuText -like '*Type DELETE to remove older install backups*') { Mark-Ok 'bat menu install backup cleanup support' } else { Mark-Fail 'bat menu install backup cleanup support missing' }

$installUiText = Read-Utf8 'scripts\install-ui.ps1'
if ($installUiText -like '*System.Windows.Forms*' -and $installUiText -like '*INSTALL_UI_SMOKE_OK*' -and $installUiText -like '*SmokeTest*' -and $installUiText -like '*INSTALL_UI_READY*' -and $installUiText -like '*Set-UiBusy*' -and $installUiText -like '*BeginInvoke*' -and $installUiText -like '*超级大脑技能注入器*' -and $installUiText -like '*技能注入*' -and $installUiText -like '*热刷新已安装技能*' -and $installUiText -like '*hot-refresh-skills.ps1*' -and $installUiText -like '*last-hot-refresh.json*' -and $installUiText -like '*记忆导入*' -and $installUiText -like '*打开记忆导入页*' -and $installUiText -like '*分享包*' -and $installUiText -like '*打开分享包页*' -and $installUiText -like '*包含记忆（私人包，不建议分享给别人）*' -and $installUiText -like '*release-share.ps1*' -and $installUiText -like '*release-private.ps1*' -and $installUiText -like '*last-release.json*' -and $installUiText -like '*最近结果*' -and $installUiText -like '*打开最近输出目录*' -and $installUiText -like '*刷新最近结果*' -and $installUiText -like '*Update-ReleaseStatusBox*' -and $installUiText -like '*RELEASE_UI_OK*' -and $installUiText -like '*RELEASE_UI_FAILED*' -and $installUiText -like '*PRIVATE*' -and $installUiText -like '*返回技能注入页*' -and $installUiText -like '*merge-overlay*' -and $installUiText -like '*整个 memory 文件夹*' -and $installUiText -like '*nestedMemory*' -and $installUiText -like '*输入 MERGE 后合并旧记忆*' -and $installUiText -like '*输入 OVERWRITE 后覆盖冲突文件*' -and $installUiText -like '*导入目录已清理*' -and $installUiText -like '*导入目录已保留*' -and $installUiText -like '*清理 install-backup-*' -and $installUiText -like '*打开清理备份页*' -and $installUiText -like '*只预览旧备份*' -and $installUiText -like '*输入 DELETE 后删除*' -and $installUiText -like '*Get-InstallBackupCleanupPlan*' -and $installUiText -like '*Remove-InstallBackupCandidates*' -and $installUiText -like '*INSTALL_BACKUP_CLEANUP_ERROR*' -and $installUiText -like '*注入手动目录*') { Mark-Ok 'install UI script support' } else { Mark-Fail 'install UI script support missing' }

$installUiVbsText = Read-Utf8 'scripts\install-ui.vbs'
if ($installUiVbsText -like '*shell.Run*' -and $installUiVbsText -like '*WindowStyle Hidden*' -and $installUiVbsText -like '*install-ui.ps1*') { Mark-Ok 'install UI no-console launcher' } else { Mark-Fail 'install UI no-console launcher missing' }

$brainBatText = Read-Utf8 'scripts\brain.bat'
if ($brainBatText -like '*brain-ui.vbs*' -and $brainBatText -like '*Super Brain Console exited*') { Mark-Ok 'brain console bat launcher' } else { Mark-Fail 'brain console bat launcher missing' }

$brainUiVbsText = Read-Utf8 'scripts\brain-ui.vbs'
if ($brainUiVbsText -like '*Super Brain Console*' -and $brainUiVbsText -like '*HasPython*' -and $brainUiVbsText -like '*PickMode*') { Mark-Ok 'brain console vbs launcher' } else { Mark-Fail 'brain console vbs launcher missing' }

$installUiPathCheckText = Read-Utf8 'scripts\check-install-ui-paths.ps1'
if ($installUiPathCheckText -like '*INSTALL_UI_PATHS*' -and $installUiPathCheckText -like '*requiredScripts*' -and $installUiPathCheckText -like '*agentCandidates*' -and $installUiPathCheckText -like '*merge-overlay*' -and $installUiPathCheckText -like '*last-install-ui-events.log*') { Mark-Ok 'install UI path check support' } else { Mark-Fail 'install UI path check support missing' }
$installUiPathJsonText = & (Join-Path $PSScriptRoot 'check-install-ui-paths.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $installUiPathJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'install UI path check json' } catch { Mark-Fail "install UI path check json parse $($_.Exception.Message)" }
} else { Mark-Fail 'install UI path check command' }

$teamTaskNewText = Read-Utf8 'scripts\team-task-new.ps1'
if ($teamTaskNewText -like '*AutoTemplate*' -and $teamTaskNewText -like '*teamTemplate*' -and $teamTaskNewText -like '*team-template-select.ps1*') { Mark-Ok 'team task template support' } else { Mark-Fail 'team task template support missing' }

$teamReviewGateText = Read-Utf8 'scripts\team-task-review-gate.ps1'
if ($teamReviewGateText -like '*drift_guard_commander_review*' -and $teamReviewGateText -like '*missing_authorization*' -and $teamReviewGateText -like '*unreviewed*' -and $teamReviewGateText -like '*verification_not_final*') { Mark-Ok 'team task review gate support' } else { Mark-Fail 'team task review gate support missing' }

$teamMemoryRetrievalText = Read-Utf8 'scripts\team-memory-retrieval.ps1'
if ($teamMemoryRetrievalText -like '*TeamTaskMatch*' -and $teamMemoryRetrievalText -like '*IncludeDelegations*' -and $teamMemoryRetrievalText -like '*score*' -and $teamMemoryRetrievalText -like '*memoryAdmission*') { Mark-Ok 'team memory retrieval support' } else { Mark-Fail 'team memory retrieval support missing' }

$roadmapManagerText = Read-Utf8 'scripts\roadmap-manager.ps1'
if ($roadmapManagerText -like '*decision-search.ps1*' -and $roadmapManagerText -like '*completedVersions*' -and $roadmapManagerText -like '*remainingVersions*' -and $roadmapManagerText -like '*last-task-verification.json*') { Mark-Ok 'roadmap manager support' } else { Mark-Fail 'roadmap manager support missing' }

$memoryRegressionText = Read-Utf8 'scripts\memory-regression-checker.ps1'
if ($memoryRegressionText -like '*agent-subagent-roadmap*' -and $memoryRegressionText -like '*version-0523-team-memory*' -and $memoryRegressionText -like '*g1-display-rule*') { Mark-Ok 'memory regression checker support' } else { Mark-Fail 'memory regression checker support missing' }

$taskStateReporterText = Read-Utf8 'scripts\task-state-reporter.ps1'
if ($taskStateReporterText -like '*last-verify-package.json*' -and $taskStateReporterText -like '*roadmap-manager.ps1*' -and $taskStateReporterText -like '*team-task-review-gate.ps1*') { Mark-Ok 'task state reporter support' } else { Mark-Fail 'task state reporter support missing' }

$privacySentinelText = Read-Utf8 'scripts\privacy-sentinel.ps1'
if ($privacySentinelText -like '*memory-health.ps1*' -and $privacySentinelText -like '*privatePatternHits*' -and $privacySentinelText -like '*Do not auto-delete memory*') { Mark-Ok 'privacy sentinel support' } else { Mark-Fail 'privacy sentinel support missing' }

$completionGuardText = Read-Utf8 'scripts\completion-guard.ps1'
if ($completionGuardText -like '*AllowPrivacyRisk*' -and $completionGuardText -like '*memory-regression-checker.ps1*' -and $completionGuardText -like '*privacy-sentinel.ps1*' -and $completionGuardText -like '*last-hot-refresh.json*') { Mark-Ok 'completion guard support' } else { Mark-Fail 'completion guard support missing' }

$dashboardText = Read-Utf8 'scripts\super-brain-dashboard.ps1'
if ($dashboardText -like '*roadmap-manager.ps1*' -and $dashboardText -like '*memory-regression-checker.ps1*' -and $dashboardText -like '*privacy-sentinel.ps1*' -and $dashboardText -like '*nextAction*') { Mark-Ok 'super brain dashboard support' } else { Mark-Fail 'super brain dashboard support missing' }

$autoContinuationText = Read-Utf8 'scripts\auto-continuation.ps1'
if ($autoContinuationText -like '*super-brain-dashboard.ps1*' -and $autoContinuationText -like '*last-status-snapshot.json*' -and $autoContinuationText -like '*nextAction*' -and $autoContinuationText -like '*blockers*') { Mark-Ok 'auto continuation support' } else { Mark-Fail 'auto continuation support missing' }

$statusSnapshotWriterText = Read-Utf8 'scripts\status-snapshot-writer.ps1'
if ($statusSnapshotWriterText -like '*last-status-snapshot.json*' -and $statusSnapshotWriterText -like '*Write-JsonUtf8NoBom*' -and $statusSnapshotWriterText -like '*NextAction*' -and $statusSnapshotWriterText -like '*super-brain-dashboard.ps1*') { Mark-Ok 'status snapshot writer support' } else { Mark-Fail 'status snapshot writer support missing' }

$privacyHitLocatorText = Read-Utf8 'scripts\privacy-hit-locator.ps1'
if ($privacyHitLocatorText -like '*privatePatterns*' -and $privacyHitLocatorText -like '*likelyFalsePositive*' -and $privacyHitLocatorText -like '*preview*') { Mark-Ok 'privacy hit locator support' } else { Mark-Fail 'privacy hit locator support missing' }

$memoryQualityFixerText = Read-Utf8 'scripts\memory-quality-fixer.ps1'
if ($memoryQualityFixerText -like '*WhatIfOnly*' -and $memoryQualityFixerText -like '*untagged*' -and $memoryQualityFixerText -like '*too_long*' -and $memoryQualityFixerText -like '*malformed_decision_particle*' -and $memoryQualityFixerText -like '*ShowDetails*' -and $memoryQualityFixerText -like '*suggestedSummary*') { Mark-Ok 'memory quality fixer support' } else { Mark-Fail 'memory quality fixer support missing' }

$optimizeAdvisorText = Read-Utf8 'scripts\optimize-advisor.ps1'
if ($optimizeAdvisorText -like '*OPTIMIZE_ADVISOR*' -and $optimizeAdvisorText -like '*topAdvice*' -and $optimizeAdvisorText -like '*doctor.ps1*' -and $optimizeAdvisorText -like '*memory-quality-fixer.ps1*' -and $optimizeAdvisorText -like '*memory-eval.ps1*') { Mark-Ok 'optimize advisor support' } else { Mark-Fail 'optimize advisor support missing' }
$optimizeJsonText = & (Join-Path $PSScriptRoot 'optimize-advisor.ps1') -Json
if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) {
  try { $optimizeJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'optimize advisor json' } catch { Mark-Fail "optimize advisor json parse $($_.Exception.Message)" }
} else { Mark-Fail 'optimize advisor command' }

$taskVerificationText = Read-Utf8 'scripts\task-verification.ps1'
if ($taskVerificationText -like '*[CmdletBinding(PositionalBinding = $false)]*') { Mark-Ok 'task verification non-positional binding' } else { Mark-Fail 'task verification non-positional binding missing' }

$verifyPackageText = Read-Utf8 'scripts\verify-package.ps1'
if ($verifyPackageText -like '*.tmp-verify-package*' -and $verifyPackageText -like '*Get-SuperBrainSharingPolicyPath*' -and $verifyPackageText -like '*Write-Utf8NoBom $policyPath $originalPolicy*' -and $verifyPackageText -like '*Remove-Item -LiteralPath $policyPath -Force*') { Mark-Ok 'verify package temp install policy restoration guard' } else { Mark-Fail 'verify package temp install policy restoration guard missing' }

$smokeTestText = Read-Utf8 'scripts\smoke-test.ps1'
if ($smokeTestText -like '*Get-SuperBrainSharingPolicyPath*' -and $smokeTestText -like '*$originalPolicy*' -and $smokeTestText -like '*Write-Utf8NoBom $policyPath $originalPolicy*' -and $smokeTestText -like '*Remove-Item -LiteralPath $policyPath -Force*') { Mark-Ok 'smoke test policy restoration guard' } else { Mark-Fail 'smoke test policy restoration guard missing' }

$workspaceLifecycleText = Read-Utf8 'scripts\workspace-lifecycle-manager.ps1'
if ($workspaceLifecycleText -like '*last-workspace-lifecycle.json*' -and $workspaceLifecycleText -like '*session-binding.json*' -and $workspaceLifecycleText -like '*agent-bridge*' -and $workspaceLifecycleText -like '*active-agent-bridge-channel.json*' -and $workspaceLifecycleText -like '*ApplySafe*' -and $workspaceLifecycleText -like '*requires_confirmation*') { Mark-Ok 'workspace lifecycle manager support' } else { Mark-Fail 'workspace lifecycle manager support missing' }

$autoHygieneText = Read-Utf8 'scripts\auto-hygiene-runner.ps1'
if ($autoHygieneText -like '*last-memory-hygiene.json*' -and $autoHygieneText -like '*compressed-memory-evidence*' -and $autoHygieneText -like '*compress_with_original_archive*' -and $autoHygieneText -like '*private_pattern*' -and $autoHygieneText -like '*requires_confirmation*') { Mark-Ok 'auto hygiene runner support' } else { Mark-Fail 'auto hygiene runner support missing' }

$postTaskMaintenanceText = Read-Utf8 'scripts\post-task-maintenance.ps1'
if ($postTaskMaintenanceText -like '*workspace-lifecycle-manager.ps1*' -and $postTaskMaintenanceText -like '*auto-hygiene-runner.ps1*' -and $postTaskMaintenanceText -like '*self-improvement-queue.ps1*' -and $postTaskMaintenanceText -like '*status-snapshot-writer.ps1*' -and $postTaskMaintenanceText -like '*last-post-task-maintenance.json*') { Mark-Ok 'post task maintenance hook support' } else { Mark-Fail 'post task maintenance hook support missing' }

$selfImprovementQueueText = Read-Utf8 'scripts\self-improvement-queue.ps1'
if ($selfImprovementQueueText -like '*self-improvement-queue.json*' -and $selfImprovementQueueText -like '*candidateOnly*' -and $selfImprovementQueueText -like '*noAutomaticSkillMutation*' -and $selfImprovementQueueText -like '*reflection-promotion.ps1*' -and $selfImprovementQueueText -like '*do not remind*') { Mark-Ok 'self improvement queue support' } else { Mark-Fail 'self improvement queue support missing' }

$maintainText = Read-Utf8 'scripts\maintain.ps1'
if ($maintainText -like '*workspace-lifecycle-manager*' -and $maintainText -like '*auto-hygiene-runner*' -and $maintainText -like '*post-task-maintenance*') { Mark-Ok 'maintain automatic maintenance integration' } else { Mark-Fail 'maintain automatic maintenance integration missing' }

$lessonReplayText = Read-Utf8 'scripts\lesson-replay.ps1'
if ($lessonReplayText -like '*experience-index.md*' -and $lessonReplayText -like '*Recall Query*' -and $lessonReplayText -like '*LESSON_REPLAY*') { Mark-Ok 'lesson replay support' } else { Mark-Fail 'lesson replay support missing' }

$dispatchLearningText = Read-Utf8 'scripts\dispatch-learning.ps1'
if ($dispatchLearningText -like '*team-task-index.json*' -and $dispatchLearningText -like '*templateStats*' -and $dispatchLearningText -like '*recommendations*' -and $dispatchLearningText -like '*blockedCount*') { Mark-Ok 'dispatch learning support' } else { Mark-Fail 'dispatch learning support missing' }

$triggerSimulationText = Read-Utf8 'scripts\trigger-simulation.ps1'
if ($triggerSimulationText -like '*team-dispatch-check.ps1*' -and $triggerSimulationText -like '*team-template-select.ps1*' -and $triggerSimulationText -like '*expectedLevel*' -and $triggerSimulationText -like '*expectedTemplate*') { Mark-Ok 'trigger simulation support' } else { Mark-Fail 'trigger simulation support missing' }
if ($triggerSimulationText -like '*bare_superbrain_zh*' -and $triggerSimulationText -like '*bare_g1*' -and $triggerSimulationText -like '*superbrain_optimize*' -and $triggerSimulationText -like '*ack_ok_zh*' -and $triggerSimulationText -like '*incidental_g1_mention*' -and $triggerSimulationText -like '*human_brain_self_report*' -and $triggerSimulationText -like '*superbrain_fault*' -and $triggerSimulationText -like '*expectedSkill*' -and $triggerSimulationText -like '*requiresG1*' -and $triggerSimulationText -like '*bare_superbrain_wake_word*') { Mark-Ok 'trigger simulation explicit and negative Super Brain skill coverage' } else { Mark-Fail 'trigger simulation explicit and negative Super Brain skill coverage missing' }

$coldStartAuditText = Read-Utf8 'scripts\cold-start-audit.ps1'
if ($coldStartAuditText -like '*session-restore.ps1*' -and $coldStartAuditText -like '*smart-next.ps1*' -and $coldStartAuditText -like '*super-brain-dashboard.ps1*' -and $coldStartAuditText -like '*auto-check.ps1*' -and $coldStartAuditText -like '*trigger-simulation.ps1*' -and $coldStartAuditText -like '*recallTriggered*' -and $coldStartAuditText -like '*dashboardMode*' -and $coldStartAuditText -like '*verifySuggested*') { Mark-Ok 'cold-start audit support' } else { Mark-Fail 'cold-start audit support missing' }

$intentRouterText = Read-Utf8 'scripts\intent-router.ps1'
if ($intentRouterText -like '*intent*' -and $intentRouterText -like '*recommendedAction*' -and $intentRouterText -like '*dispatchHints*') { Mark-Ok 'intent router support' } else { Mark-Fail 'intent router support missing' }

$smartNextText = Read-Utf8 'scripts\smart-next.ps1'
if ($smartNextText -like '*intent-router.ps1*' -and $smartNextText -like '*auto-continuation.ps1*' -and $smartNextText -like '*dispatch-learning.ps1*' -and $smartNextText -like '*nextAction*') { Mark-Ok 'smart next support' } else { Mark-Fail 'smart next support missing' }

$healthSummaryText = Read-Utf8 'scripts\health-summary.ps1'
if ($healthSummaryText -like '*super-brain-dashboard.ps1*' -and $healthSummaryText -like '*doctor.ps1*' -and $healthSummaryText -like '*riskSummary*') { Mark-Ok 'health summary support' } else { Mark-Fail 'health summary support missing' }

$agentScorecardText = Read-Utf8 'scripts\agent-scorecard.ps1'
if ($agentScorecardText -like '*agent-teams.json*' -and $agentScorecardText -like '*team-task-index.json*' -and $agentScorecardText -like '*score*' -and $agentScorecardText -like '*recommendation*') { Mark-Ok 'agent scorecard support' } else { Mark-Fail 'agent scorecard support missing' }

$taskRetrospectiveText = Read-Utf8 'scripts\task-retrospective.ps1'
if ($taskRetrospectiveText -like '*last-retrospective.json*' -and $taskRetrospectiveText -like '*didWell*' -and $taskRetrospectiveText -like '*improveNext*') { Mark-Ok 'task retrospective support' } else { Mark-Fail 'task retrospective support missing' }

$releaseReadinessText = Read-Utf8 'scripts\release-readiness.ps1'
if ($releaseReadinessText -like '*last-release.json*' -and $releaseReadinessText -like '*full_ci_missing_or_skipped*' -and $releaseReadinessText -like '*share_release_missing_or_stale*') { Mark-Ok 'release readiness support' } else { Mark-Fail 'release readiness support missing' }

$brainText = Read-Utf8 'scripts\brain.ps1'
if ($brainText -like '*health-summary.ps1*' -and $brainText -like '*smart-next.ps1*' -and $brainText -like '*release-readiness.ps1*' -and $brainText -like '*agent-scorecard.ps1*' -and $brainText -like '*optimize-advisor.ps1*') { Mark-Ok 'brain unified command support' } else { Mark-Fail 'brain unified command support missing' }

$versionBumpText = Read-Utf8 'scripts\version-bump.ps1'
if ($versionBumpText -like '*ValidateSet*' -or ($versionBumpText -like '*manifest.json*' -and $versionBumpText -like '*BASELINE_HISTORY.md*' -and $versionBumpText -like '*graph-add.ps1*' -and $versionBumpText -like '*Apply*')) { Mark-Ok 'version bump preview support' } else { Mark-Fail 'version bump preview support missing' }

$agentBridgeText = Read-Utf8 'scripts\agent-bridge.ps1'
if ($agentBridgeText -like '*memory/workspace/agent-bridge*' -and $agentBridgeText -like '*Failover*' -and $agentBridgeText -like '*Adopt*' -and $agentBridgeText -like '*bridge-heartbeat.json*') { Mark-Ok 'agent bridge core lifecycle support' } else { Mark-Fail 'agent bridge core lifecycle support missing' }

$agentBridgeDispatchText = Read-Utf8 'scripts\agent-bridge-dispatch.ps1'
if ($agentBridgeDispatchText -like '*Get-LastNextAction*' -and $agentBridgeDispatchText -like '*Recent cards*' -and $agentBridgeDispatchText -like '*handoffPrompt*' -and $agentBridgeDispatchText -like '*outputPath*' -and $agentBridgeDispatchText -like '*No active agent bridge state*') { Mark-Ok 'agent bridge dispatch packet support' } else { Mark-Fail 'agent bridge dispatch packet support missing' }

$agentBridgeChannelText = Read-Utf8 'scripts\agent-bridge-channel.ps1'
if ($agentBridgeChannelText -like '*Open*' -and $agentBridgeChannelText -like '*Connect*' -and $agentBridgeChannelText -like '*SendAndWait*' -and $agentBridgeChannelText -like '*WaitReply*' -and $agentBridgeChannelText -like '*Active*' -and $agentBridgeChannelText -like '*target-session*' -and $agentBridgeChannelText -like '*last-agent-bridge-channel.json*' -and $agentBridgeChannelText -like '*active-agent-bridge-channel.json*' -and $agentBridgeChannelText -like '*channel-log.jsonl*') { Mark-Ok 'agent bridge shared channel support' } else { Mark-Fail 'agent bridge shared channel support missing' }

$agentBridgePermissionsText = Read-Utf8 'scripts\agent-bridge-permissions.ps1'
if ($agentBridgePermissionsText -like '*code-suggester*' -and $agentBridgePermissionsText -like '*adopt-requester*' -and $agentBridgePermissionsText -like '*commander*' -and $agentBridgePermissionsText -like '*Operation is required for Check*') { Mark-Ok 'agent bridge permission role support' } else { Mark-Fail 'agent bridge permission role support missing' }

$agentBridgeQueueText = Read-Utf8 'scripts\agent-bridge-queue.ps1'
if ($agentBridgeQueueText -like '*Enqueue*' -and $agentBridgeQueueText -like '*Poll*' -and $agentBridgeQueueText -like '*Ack*' -and $agentBridgeQueueText -like '*bridge-queue.json*' -and $agentBridgeQueueText -like '*status=''pending''*') { Mark-Ok 'agent bridge queue relay support' } else { Mark-Fail 'agent bridge queue relay support missing' }

$teamTaskArchiveText = Read-Utf8 'scripts\team-task-archive.ps1'
if ($teamTaskArchiveText -like '*KeepRecent*' -and $teamTaskArchiveText -like '*-Apply*' -and $teamTaskArchiveText -like '*Dry run only*' -and $teamTaskArchiveText -like '*team-tasks-archive*') { Mark-Ok 'team task archival dry-run support' } else { Mark-Fail 'team task archival dry-run support missing' }

$hostCacheCheckText = Read-Utf8 'scripts\host-cache-check.ps1'
if ($hostCacheCheckText -like '*currentSessionCacheRisk*' -and $hostCacheCheckText -like '*loadedSkillLimitation*' -and $hostCacheCheckText -like '*newSessionPrompt*' -and $hostCacheCheckText -like '*hot-refresh-skills.ps1 -AllKnown*') { Mark-Ok 'host cache limitation prompt support' } else { Mark-Fail 'host cache limitation prompt support missing' }

$cleanupLegacyText = Read-Utf8 'scripts\cleanup-legacy-memory.ps1'
if ($cleanupLegacyText -like '*memory-zcode*' -and $cleanupLegacyText -like '*memory-codex*' -and $cleanupLegacyText -like '*Get-FileHash*' -and $cleanupLegacyText -like '*-Apply*') { Mark-Ok 'legacy memory cleanup support' } else { Mark-Fail 'legacy memory cleanup support missing' }

$cleanupInstallBackupsText = Read-Utf8 'scripts\cleanup-install-backups.ps1'
if ($cleanupInstallBackupsText -like '*install-backup-*' -and $cleanupInstallBackupsText -like '*Keep*' -and $cleanupInstallBackupsText -like '*-Apply*') { Mark-Ok 'install backup cleanup support' } else { Mark-Fail 'install backup cleanup support missing' }

$migrateMemoryText = Read-Utf8 'scripts\migrate-memory-layout.ps1'
if ($migrateMemoryText -like '*memory-zcode*' -and $migrateMemoryText -like '*memory-codex*' -and $migrateMemoryText -like '*Get-SuperBrainSharedMemoryRoot*' -and $migrateMemoryText -like '*-Apply*') { Mark-Ok 'memory layout migration support' } else { Mark-Fail 'memory layout migration support missing' }
if ($migrateMemoryText -like '*Merge-TextMemoryFile*' -and $migrateMemoryText -like '*MIGRATED_LEGACY_MEMORY*' -and $migrateMemoryText -like '*MIGRATE_KEEP_NEW*') { Mark-Ok 'migrate memory merge strategy' } else { Mark-Fail 'migrate memory merge strategy missing' }
if ($migrateMemoryText -like '*ImportRoot*' -and $migrateMemoryText -like '*merge-overlay*' -and $migrateMemoryText -like '*Resolve-ImportMemoryRoot*' -and $migrateMemoryText -like '*MIGRATE_IMPORT_NESTED_MEMORY*' -and $migrateMemoryText -like '*Overwrite*' -and $migrateMemoryText -like '*CleanupImport*' -and $migrateMemoryText -like '*MIGRATE_IMPORT_CLEANED*' -and $migrateMemoryText -like '*MIGRATE_CLEANUP_REFUSED*') { Mark-Ok 'memory import merge overlay support' } else { Mark-Fail 'memory import merge overlay support missing' }

$psScripts = Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Filter '*.ps1' -File
foreach ($scriptFile in $psScripts) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -eq 0) { Mark-Ok "parse scripts\$($scriptFile.Name)" } else { Mark-Fail "parse scripts\$($scriptFile.Name) $($errors[0].Message)" }
}

& (Join-Path $PSScriptRoot 'startup-check.ps1')
if ($LASTEXITCODE -eq 0) { Mark-Ok 'startup hook/config check' } else { Mark-Fail 'startup hook/config check' }

$summaryJsonText = & (Join-Path $PSScriptRoot 'summary.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $summaryJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'summary json' } catch { Mark-Fail "summary json parse $($_.Exception.Message)" }
} else { Mark-Fail 'summary json command' }

$doctorJsonText = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $doctorJson = $doctorJsonText | ConvertFrom-Json
    Mark-Ok 'doctor json'
    if ($null -ne $doctorJson.riskSummary -and $null -ne $doctorJson.risks -and $null -ne $doctorJson.lastMemoryEval -and $null -ne $doctorJson.lastTaskVerification) { Mark-Ok 'doctor risk aggregation fields' } else { Mark-Fail 'doctor risk aggregation fields missing' }
    if ($null -ne $doctorJson.teamTasks -and $null -ne $doctorJson.teamTasks.count -and $null -ne $doctorJson.teamTasks.indexOk) { Mark-Ok 'doctor team task fields' } else { Mark-Fail 'doctor team task fields missing' }
    if ($null -ne $doctorJson.agentTeams -and [int]$doctorJson.agentTeams.templateCount -ge 4) { Mark-Ok 'doctor agent team fields' } else { Mark-Fail 'doctor agent team fields missing' }
    if ($null -ne $doctorJson.codeCapableAudit -and $null -ne $doctorJson.codeCapableAudit.codeCapableDelegationCount -and $null -ne $doctorJson.codeCapableAudit.unreviewedCodeChangeCount -and $null -ne $doctorJson.codeCapableAudit.driftRiskCount) { Mark-Ok 'doctor code-capable audit fields' } else { Mark-Fail 'doctor code-capable audit fields missing' }
  } catch { Mark-Fail "doctor json parse $($_.Exception.Message)" }
} else { Mark-Fail 'doctor json command' }

$dispatchJsonText = & (Join-Path $PSScriptRoot 'team-dispatch-check.ps1') -ArchitectureChange -LongTask -LogicSafetyRequired -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $dispatchJson = $dispatchJsonText | ConvertFrom-Json
    if ($dispatchJson.dispatchLevel -eq 'review_board') { Mark-Ok 'team dispatch review board json' } else { Mark-Fail 'team dispatch review board level mismatch' }
  } catch { Mark-Fail "team dispatch json parse $($_.Exception.Message)" }
} else { Mark-Fail 'team dispatch command' }

$teamStatusJsonText = & (Join-Path $PSScriptRoot 'team-task-status.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $teamStatusJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'team task status json' } catch { Mark-Fail "team task status json parse $($_.Exception.Message)" }
} else { Mark-Fail 'team task status command' }

$templateListJsonText = & (Join-Path $PSScriptRoot 'team-template-list.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $templateListJson = $templateListJsonText | ConvertFrom-Json
    if ([int]$templateListJson.templateCount -ge 4) { Mark-Ok 'team template list json' } else { Mark-Fail 'team template list count too low' }
  } catch { Mark-Fail "team template list json parse $($_.Exception.Message)" }
} else { Mark-Fail 'team template list command' }

$templateSelectJsonText = & (Join-Path $PSScriptRoot 'team-template-select.ps1') -DispatchLevel review_board -Reason @('architecture_change','logic_safety_required') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $templateSelectJson = $templateSelectJsonText | ConvertFrom-Json
    if ($templateSelectJson.selected.id -eq 'review-team') { Mark-Ok 'team template select review team' } else { Mark-Fail 'team template select review team mismatch' }
  } catch { Mark-Fail "team template select json parse $($_.Exception.Message)" }
} else { Mark-Fail 'team template select command' }

$teamAuditJsonText = & (Join-Path $PSScriptRoot 'team-task-audit.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $teamAuditJson = $teamAuditJsonText | ConvertFrom-Json
    if ($null -ne $teamAuditJson.codeCapableDelegationCount -and $null -ne $teamAuditJson.unreviewedCodeChangeCount -and $null -ne $teamAuditJson.driftRiskCount -and $null -ne $teamAuditJson.authorizationMissingCount) { Mark-Ok 'team task audit json' } else { Mark-Fail 'team task audit fields missing' }
  } catch { Mark-Fail "team task audit json parse $($_.Exception.Message)" }
} else { Mark-Fail 'team task audit command' }

$teamReviewGateJsonText = & (Join-Path $PSScriptRoot 'team-task-review-gate.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $teamReviewGateJson = $teamReviewGateJsonText | ConvertFrom-Json
    if ($teamReviewGateJson.ok -eq $true -and $null -ne $teamReviewGateJson.gate -and $null -ne $teamReviewGateJson.blockerCount) { Mark-Ok 'team task review gate json' } else { Mark-Fail 'team task review gate fields missing' }
  } catch { Mark-Fail "team task review gate json parse $($_.Exception.Message)" }
} else { Mark-Fail 'team task review gate command' }

$teamMemoryRetrievalJsonText = & (Join-Path $PSScriptRoot 'team-memory-retrieval.ps1') -Query 'subagent' -TopK 3 -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $teamMemoryRetrievalJson = $teamMemoryRetrievalJsonText | ConvertFrom-Json
    if ($teamMemoryRetrievalJson.ok -eq $true -and $null -ne $teamMemoryRetrievalJson.results) { Mark-Ok 'team memory retrieval json' } else { Mark-Fail 'team memory retrieval fields missing' }
  } catch { Mark-Fail "team memory retrieval json parse $($_.Exception.Message)" }
} else { Mark-Fail 'team memory retrieval command' }

$roadmapManagerJsonText = & (Join-Path $PSScriptRoot 'roadmap-manager.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $roadmapManagerJson = $roadmapManagerJsonText | ConvertFrom-Json
    if ($roadmapManagerJson.ok -eq $true -and $roadmapManagerJson.roadmapFound -eq $true) { Mark-Ok 'roadmap manager json' } else { Mark-Fail 'roadmap manager fields missing' }
  } catch { Mark-Fail "roadmap manager json parse $($_.Exception.Message)" }
} else { Mark-Fail 'roadmap manager command' }

$memoryRegressionJsonText = & (Join-Path $PSScriptRoot 'memory-regression-checker.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $memoryRegressionJson = $memoryRegressionJsonText | ConvertFrom-Json
    if ($memoryRegressionJson.ok -eq $true -and [int]$memoryRegressionJson.total -gt 0) { Mark-Ok 'memory regression checker json' } else { Mark-Fail 'memory regression checker fields missing' }
  } catch { Mark-Fail "memory regression checker json parse $($_.Exception.Message)" }
} else { Mark-Fail 'memory regression checker command' }

$taskStateReporterJsonText = & (Join-Path $PSScriptRoot 'task-state-reporter.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $taskStateReporterJson = $taskStateReporterJsonText | ConvertFrom-Json
    if ($taskStateReporterJson.ok -eq $true -and $null -ne $taskStateReporterJson.version) { Mark-Ok 'task state reporter json' } else { Mark-Fail 'task state reporter fields missing' }
  } catch { Mark-Fail "task state reporter json parse $($_.Exception.Message)" }
} else { Mark-Fail 'task state reporter command' }

$privacySentinelJsonText = & (Join-Path $PSScriptRoot 'privacy-sentinel.ps1') -Json
try {
  $privacySentinelJson = $privacySentinelJsonText | ConvertFrom-Json
  if ($null -ne $privacySentinelJson.privatePatternHits -and $null -ne $privacySentinelJson.shareSafe) { Mark-Ok 'privacy sentinel json' } else { Mark-Fail 'privacy sentinel fields missing' }
} catch { Mark-Fail "privacy sentinel json parse $($_.Exception.Message)" }

$completionGuardTaskId = ''
try {
  $lastTaskForGuardPath = Join-Path $workspace 'last-task-verification.json'
  if (Test-Path -LiteralPath $lastTaskForGuardPath) {
    $lastTaskForGuard = Get-Content -LiteralPath $lastTaskForGuardPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($lastTaskForGuard -and -not [string]::IsNullOrWhiteSpace([string]$lastTaskForGuard.taskId)) { $completionGuardTaskId = [string]$lastTaskForGuard.taskId }
  }
} catch {}
if (-not [string]::IsNullOrWhiteSpace($completionGuardTaskId)) {
  $completionGuardJsonText = & (Join-Path $PSScriptRoot 'completion-guard.ps1') -TaskId $completionGuardTaskId -Json -AllowPrivacyRisk -AllowActiveCheckpoint
} else {
  $completionGuardJsonText = & (Join-Path $PSScriptRoot 'completion-guard.ps1') -Json -AllowPrivacyRisk -AllowActiveCheckpoint
}
try {
  $completionGuardJson = $completionGuardJsonText | ConvertFrom-Json
  if ($completionGuardJson.ok -eq $true -and $null -ne $completionGuardJson.checks) { Mark-Ok 'completion guard json' } else { Mark-Fail 'completion guard fields missing' }
} catch { Mark-Fail "completion guard json parse $($_.Exception.Message)" }

$dashboardJsonText = & (Join-Path $PSScriptRoot 'super-brain-dashboard.ps1') -Json -AllowStaleVerify -AllowActiveCheckpoint
if ($LASTEXITCODE -eq 0) {
  try {
    $dashboardJson = $dashboardJsonText | ConvertFrom-Json
    if ($dashboardJson.ok -eq $true -and $null -ne $dashboardJson.nextAction -and $null -ne $dashboardJson.risks) { Mark-Ok 'super brain dashboard json' } else { Mark-Fail 'super brain dashboard fields missing' }
  } catch { Mark-Fail "super brain dashboard json parse $($_.Exception.Message)" }
} else { Mark-Fail 'super brain dashboard command' }

$autoContinuationJsonText = & (Join-Path $PSScriptRoot 'auto-continuation.ps1') -Json -AllowStaleVerify
if ($LASTEXITCODE -eq 0) {
  try {
    $autoContinuationJson = $autoContinuationJsonText | ConvertFrom-Json
    if ($autoContinuationJson.ok -eq $true -and $null -ne $autoContinuationJson.nextAction) { Mark-Ok 'auto continuation json' } else { Mark-Fail 'auto continuation fields missing' }
  } catch { Mark-Fail "auto continuation json parse $($_.Exception.Message)" }
} else { Mark-Fail 'auto continuation command' }

$statusSnapshotJsonText = & (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') -Summary 'verify-package status snapshot' -NextAction 'continue from dashboard' -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $statusSnapshotJson = $statusSnapshotJsonText | ConvertFrom-Json
    if ($statusSnapshotJson.ok -eq $true -and $null -ne $statusSnapshotJson.nextAction) { Mark-Ok 'status snapshot writer json' } else { Mark-Fail 'status snapshot writer fields missing' }
  } catch { Mark-Fail "status snapshot writer json parse $($_.Exception.Message)" }
} else { Mark-Fail 'status snapshot writer command' }

$privacyHitLocatorJsonText = & (Join-Path $PSScriptRoot 'privacy-hit-locator.ps1') -Json 2>$null
$privacyHitLocatorExitCode = $LASTEXITCODE
try {
  $privacyHitLocatorJson = $privacyHitLocatorJsonText | ConvertFrom-Json
  if ($null -ne $privacyHitLocatorJson.hitCount -and $null -ne $privacyHitLocatorJson.hits) { Mark-Ok 'privacy hit locator json' } else { Mark-Fail 'privacy hit locator fields missing' }
} catch { Mark-Fail "privacy hit locator json parse $($_.Exception.Message)" }

$memoryQualityFixerJsonText = & (Join-Path $PSScriptRoot 'memory-quality-fixer.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $memoryQualityFixerJson = $memoryQualityFixerJsonText | ConvertFrom-Json
    if ($memoryQualityFixerJson.ok -eq $true -and $memoryQualityFixerJson.mode -eq 'WhatIfOnly') { Mark-Ok 'memory quality fixer json' } else { Mark-Fail 'memory quality fixer fields missing' }
  } catch { Mark-Fail "memory quality fixer json parse $($_.Exception.Message)" }
} else { Mark-Fail 'memory quality fixer command' }

$lessonReplayJsonText = & (Join-Path $PSScriptRoot 'lesson-replay.ps1') -Query 'install ui' -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $lessonReplayJson = $lessonReplayJsonText | ConvertFrom-Json
    if ($lessonReplayJson.ok -eq $true -and $null -ne $lessonReplayJson.matches) { Mark-Ok 'lesson replay json' } else { Mark-Fail 'lesson replay fields missing' }
  } catch { Mark-Fail "lesson replay json parse $($_.Exception.Message)" }
} else { Mark-Fail 'lesson replay command' }

$dispatchLearningJsonText = & (Join-Path $PSScriptRoot 'dispatch-learning.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $dispatchLearningJson = $dispatchLearningJsonText | ConvertFrom-Json
    if ($dispatchLearningJson.ok -eq $true -and $null -ne $dispatchLearningJson.recommendations -and $null -ne $dispatchLearningJson.templateStats) { Mark-Ok 'dispatch learning json' } else { Mark-Fail 'dispatch learning fields missing' }
  } catch { Mark-Fail "dispatch learning json parse $($_.Exception.Message)" }
} else { Mark-Fail 'dispatch learning command' }

$triggerSimulationJsonText = & (Join-Path $PSScriptRoot 'trigger-simulation.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $triggerSimulationJson = $triggerSimulationJsonText | ConvertFrom-Json
    if ($triggerSimulationJson.ok -eq $true -and [int]$triggerSimulationJson.total -gt 0 -and [int]$triggerSimulationJson.failed -eq 0) { Mark-Ok 'trigger simulation json' } else { Mark-Fail 'trigger simulation fields missing' }
  } catch { Mark-Fail "trigger simulation json parse $($_.Exception.Message)" }
} else { Mark-Fail 'trigger simulation command' }

$coldStartAuditJsonText = & (Join-Path $PSScriptRoot 'cold-start-audit.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $coldStartAuditJson = $coldStartAuditJsonText | ConvertFrom-Json
    if ($coldStartAuditJson.ok -eq $true -and [int]$coldStartAuditJson.total -gt 0 -and [int]$coldStartAuditJson.failed -eq 0) { Mark-Ok 'cold-start audit json' } else { Mark-Fail 'cold-start audit fields missing' }
  } catch { Mark-Fail "cold-start audit json parse $($_.Exception.Message)" }
} else { Mark-Fail 'cold-start audit command' }

$intentRouterJsonText = & (Join-Path $PSScriptRoot 'intent-router.ps1') '继续' -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $intentRouterJson = $intentRouterJsonText | ConvertFrom-Json
    if ($intentRouterJson.ok -eq $true -and $intentRouterJson.intent -eq 'continue') { Mark-Ok 'intent router json' } else { Mark-Fail 'intent router fields missing' }
  } catch { Mark-Fail "intent router json parse $($_.Exception.Message)" }
} else { Mark-Fail 'intent router command' }

$smartNextJsonText = & (Join-Path $PSScriptRoot 'smart-next.ps1') '继续' -Json
try {
  $smartNextJson = $smartNextJsonText | ConvertFrom-Json
  if ($null -ne $smartNextJson.nextAction -and $null -ne $smartNextJson.intent) { Mark-Ok 'smart next json' } else { Mark-Fail 'smart next fields missing' }
} catch { Mark-Fail "smart next json parse $($_.Exception.Message)" }

$healthSummaryJsonText = & (Join-Path $PSScriptRoot 'health-summary.ps1') -Json
try {
  $healthSummaryJson = $healthSummaryJsonText | ConvertFrom-Json
  if ($null -ne $healthSummaryJson.version -and $null -ne $healthSummaryJson.nextAction -and $null -ne $healthSummaryJson.risks) { Mark-Ok 'health summary json' } else { Mark-Fail 'health summary fields missing' }
} catch { Mark-Fail "health summary json parse $($_.Exception.Message)" }

$agentScorecardJsonText = & (Join-Path $PSScriptRoot 'agent-scorecard.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $agentScorecardJson = $agentScorecardJsonText | ConvertFrom-Json
    if ($agentScorecardJson.ok -eq $true -and [int]$agentScorecardJson.cardCount -gt 0) { Mark-Ok 'agent scorecard json' } else { Mark-Fail 'agent scorecard fields missing' }
  } catch { Mark-Fail "agent scorecard json parse $($_.Exception.Message)" }
} else { Mark-Fail 'agent scorecard command' }

$brainJsonText = & (Join-Path $PSScriptRoot 'brain.ps1') status -Json
try {
  $brainJson = $brainJsonText | ConvertFrom-Json
  if ($null -ne $brainJson.version -and $null -ne $brainJson.ready) { Mark-Ok 'brain status json' } else { Mark-Fail 'brain status fields missing' }
} catch { Mark-Fail "brain status json parse $($_.Exception.Message)" }

$versionBumpJsonText = & (Join-Path $PSScriptRoot 'version-bump.ps1') -Version '0.0.0' -Summary 'preview only' -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $versionBumpJson = $versionBumpJsonText | ConvertFrom-Json
    if ($versionBumpJson.ok -eq $true -and $versionBumpJson.mode -eq 'preview') { Mark-Ok 'version bump preview json' } else { Mark-Fail 'version bump preview fields missing' }
  } catch { Mark-Fail "version bump preview json parse $($_.Exception.Message)" }
} else { Mark-Fail 'version bump preview command' }

$workspaceLifecycleJsonText = & (Join-Path $PSScriptRoot 'workspace-lifecycle-manager.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $workspaceLifecycleJson = $workspaceLifecycleJsonText | ConvertFrom-Json
    if ($workspaceLifecycleJson.ok -eq $true -and $workspaceLifecycleJson.schema -eq 'super-brain.workspace-lifecycle.v1') { Mark-Ok 'workspace lifecycle manager json' } else { Mark-Fail 'workspace lifecycle manager fields missing' }
  } catch { Mark-Fail "workspace lifecycle manager json parse $($_.Exception.Message)" }
} else { Mark-Fail 'workspace lifecycle manager command' }

$autoHygieneJsonText = & (Join-Path $PSScriptRoot 'auto-hygiene-runner.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $autoHygieneJson = $autoHygieneJsonText | ConvertFrom-Json
    if ($autoHygieneJson.ok -eq $true -and $autoHygieneJson.schema -eq 'super-brain.auto-hygiene.v1') { Mark-Ok 'auto hygiene runner json' } else { Mark-Fail 'auto hygiene runner fields missing' }
  } catch { Mark-Fail "auto hygiene runner json parse $($_.Exception.Message)" }
} else { Mark-Fail 'auto hygiene runner command' }

$postTaskMaintenanceJsonText = & (Join-Path $PSScriptRoot 'post-task-maintenance.ps1') -Summary 'verify-package post-task maintenance plan' -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $postTaskMaintenanceJson = $postTaskMaintenanceJsonText | ConvertFrom-Json
    if ($postTaskMaintenanceJson.ok -eq $true -and $null -ne $postTaskMaintenanceJson.outputs) { Mark-Ok 'post task maintenance json' } else { Mark-Fail 'post task maintenance fields missing' }
  } catch { Mark-Fail "post task maintenance json parse $($_.Exception.Message)" }
} else { Mark-Fail 'post task maintenance command' }

$selfImprovementQueueJsonText = & (Join-Path $PSScriptRoot 'self-improvement-queue.ps1') -Summary 'verify-package queue scan' -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $selfImprovementQueueJson = $selfImprovementQueueJsonText | ConvertFrom-Json
    if ($selfImprovementQueueJson.ok -eq $true -and $null -ne $selfImprovementQueueJson.queuePath) { Mark-Ok 'self improvement queue json' } else { Mark-Fail 'self improvement queue fields missing' }
  } catch { Mark-Fail "self improvement queue json parse $($_.Exception.Message)" }
} else { Mark-Fail 'self improvement queue command' }

$maintainJsonText = & (Join-Path $PSScriptRoot 'maintain.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $maintainJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'maintain json' } catch { Mark-Fail "maintain json parse $($_.Exception.Message)" }
} else { Mark-Fail 'maintain json command' }

$scriptTiersJsonText = & (Join-Path $PSScriptRoot 'script-tiers.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $scriptTiersJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'script tiers json' } catch { Mark-Fail "script tiers json parse $($_.Exception.Message)" }
} else { Mark-Fail 'script tiers json command' }

$memoryHealthJsonText = & (Join-Path $PSScriptRoot 'memory-health.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $memoryHealthJson = $memoryHealthJsonText | ConvertFrom-Json
    Mark-Ok 'memory health json'
    if ($null -ne $memoryHealthJson.layerCounts -and $null -ne $memoryHealthJson.summaryCount -and $null -ne $memoryHealthJson.negativeFeedbackCount -and $null -ne $memoryHealthJson.expiredCount) { Mark-Ok 'memory health layer expiry feedback counters' } else { Mark-Fail 'memory health layer expiry feedback counters missing' }
    if ($null -ne $memoryHealthJson.adrGraphCount -and $null -ne $memoryHealthJson.adrCurrentCount -and $null -ne $memoryHealthJson.adrSupersededCount) { Mark-Ok 'memory health ADR counters' } else { Mark-Fail 'memory health ADR counters missing' }
  } catch { Mark-Fail "memory health json parse $($_.Exception.Message)" }
} else { Mark-Fail 'memory health json command' }

$decisionAuditJsonText = & (Join-Path $PSScriptRoot 'decision-audit.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $decisionAuditJson = $decisionAuditJsonText | ConvertFrom-Json
    Mark-Ok 'decision audit json'
    if ($null -ne $decisionAuditJson.adrGraphCount -and $null -ne $decisionAuditJson.adrSchemaIssueCount -and $null -ne $decisionAuditJson.adrCurrentConflictCount) { Mark-Ok 'decision audit ADR counters' } else { Mark-Fail 'decision audit ADR counters missing' }
  } catch { Mark-Fail "decision audit json parse $($_.Exception.Message)" }
} else { Mark-Fail 'decision audit json command' }

$decisionSearchJsonText = & (Join-Path $PSScriptRoot 'decision-search.ps1') -Query 'super-memory-brain' -TopK 1 -MaxTokens 80 -Json
if ($LASTEXITCODE -eq 0) {
  try { $decisionSearchJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'decision search json' } catch { Mark-Fail "decision search json parse $($_.Exception.Message)" }
} else { Mark-Fail 'decision search json command' }

& (Join-Path $PSScriptRoot 'encoding-check.ps1')
if ($LASTEXITCODE -eq 0) { Mark-Ok 'encoding check' } else { Mark-Fail 'encoding check' }

& (Join-Path $PSScriptRoot 'graph-normalize.ps1')
if ($LASTEXITCODE -eq 0) { Mark-Ok 'graph normalize check' } else { Mark-Fail 'graph normalize check' }

& (Join-Path $PSScriptRoot 'install-ui.ps1') -SmokeTest
if ($LASTEXITCODE -eq 0) { Mark-Ok 'install UI smoke test' } else { Mark-Fail 'install UI smoke test' }

$stateJsonText = & (Join-Path $PSScriptRoot 'state.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $stateJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'state cache read json' } catch { Mark-Fail "state cache read json parse $($_.Exception.Message)" }
} else { Mark-Fail 'state cache read json command' }

& (Join-Path $PSScriptRoot 'recall-recent.ps1') -Count 1
if ($LASTEXITCODE -eq 0) { Mark-Ok 'recall recent helper' } else { Mark-Fail 'recall recent helper' }

& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query 'super-memory-brain' -Limit 1 -TopK 1 -MaxTokens 80 -Layer all
if ($LASTEXITCODE -eq 0) { Mark-Ok 'recall search helper' } else { Mark-Fail 'recall search helper' }

& (Join-Path $PSScriptRoot 'skill-sync-check.ps1')
if ($LASTEXITCODE -eq 0) { Mark-Ok 'skill sync check' } else { Mark-Fail 'skill sync check' }
$skillSyncJsonText = & (Join-Path $PSScriptRoot 'skill-sync-check.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $skillSyncJson = $skillSyncJsonText | ConvertFrom-Json
    $markerOk = $true
    foreach ($syncResult in @($skillSyncJson.results)) {
      if ($syncResult.zcodePackageRootOk -ne $true -or $syncResult.codexPackageRootOk -ne $true -or $syncResult.zcodeMemoryRootOk -ne $true -or $syncResult.codexMemoryRootOk -ne $true) { $markerOk = $false }
    }
    if ($markerOk) { Mark-Ok 'skill package and memory root markers' } else { Mark-Fail 'skill package and memory root markers' }
  } catch { Mark-Fail "skill root marker json parse $($_.Exception.Message)" }
} else { Mark-Fail 'skill root marker json command' }

& (Join-Path $PSScriptRoot 'compact-report.ps1')
if ($LASTEXITCODE -eq 0) { Mark-Ok 'compact report' } else { Mark-Fail 'compact report' }

& (Join-Path $PSScriptRoot 'compact-apply.ps1') -WhatIfOnly
if ($LASTEXITCODE -eq 0) { Mark-Ok 'compact apply dry run' } else { Mark-Fail 'compact apply dry run' }

$compactApplyOutput = & (Join-Path $PSScriptRoot 'compact-apply.ps1')
if ($LASTEXITCODE -eq 0) {
  Mark-Ok 'compact apply guarded command'
} else {
  Mark-Fail 'compact apply guarded command'
}

& (Join-Path $PSScriptRoot 'backup-retention.ps1')
if ($LASTEXITCODE -eq 0) { Mark-Ok 'backup retention dry run' } else { Mark-Fail 'backup retention dry run' }

& (Join-Path $PSScriptRoot 'state.ps1') -Json | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'state cache read helper' } else { Mark-Fail 'state cache read helper' }

$memoryRecentOutput = & (Join-Path $PSScriptRoot 'recall-recent.ps1') -Count 1 2>&1
if ($LASTEXITCODE -eq 0) { Mark-Ok 'memory recent helper json' } else { Mark-Fail ('memory recent helper json ' + (($memoryRecentOutput | Select-Object -Last 1) -join ' ')) }

& (Join-Path $PSScriptRoot 'test-recall.ps1')
if ($LASTEXITCODE -eq 0) { Mark-Ok 'integrated recall tests' } else { Mark-Fail 'integrated recall tests' }
$testRecallJsonText = & (Join-Path $PSScriptRoot 'test-recall.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $testRecallJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'integrated recall tests json' } catch { Mark-Fail "integrated recall tests json parse $($_.Exception.Message)" }
} else { Mark-Fail 'integrated recall tests json command' }
$memoryEvalJsonText = & (Join-Path $PSScriptRoot 'memory-eval.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $memoryEvalJson = $memoryEvalJsonText | ConvertFrom-Json
    if ($memoryEvalJson.ok -eq $true -and $memoryEvalJson.total -gt 0 -and $null -ne $memoryEvalJson.metrics) { Mark-Ok 'memory eval harness json' } else { Mark-Fail 'memory eval harness json ok=false' }
  } catch { Mark-Fail "memory eval harness json parse $($_.Exception.Message)" }
} else { Mark-Fail 'memory eval harness command' }
& (Join-Path $PSScriptRoot 'memory-eval-report.ps1')
if ($LASTEXITCODE -eq 0) { Mark-Ok 'memory eval report' } else { Mark-Fail 'memory eval report' }

if ($WithShareBuild) {
  & (Join-Path $PSScriptRoot 'verify-share.ps1')
  if ($LASTEXITCODE -eq 0) { Mark-Ok 'integrated share verification' } else { Mark-Fail 'integrated share verification' }
} else {
  Mark-Ok 'integrated share verification skipped'
}

if ($WithTempInstall) {
  $tmpRoot = Join-Path $Root '.tmp-verify-package'
  $policyPath = Get-SuperBrainSharingPolicyPath $Root
  $hadPolicy = Test-Path $policyPath
  $originalPolicy = if ($hadPolicy) { Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 } else { $null }
  if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
  $zSkills = Join-Path $tmpRoot 'zcode-skills'
  $codexSkills = Join-Path $tmpRoot 'codex-skills'
  $tmpMemory = Join-Path $tmpRoot 'memory'
  try {
    & (Join-Path $PSScriptRoot 'install.ps1') -ZCodeSkills $zSkills -CodexSkills $codexSkills -Neurobase $tmpMemory
    if ($LASTEXITCODE -eq 0) { Mark-Ok 'integrated temp install' } else { Mark-Fail 'integrated temp install' }

    if (Test-Path (Join-Path $tmpMemory '.memory-scope.json')) { Mark-Ok 'integrated temp memory scope marker' } else { Mark-Fail 'integrated temp memory scope marker missing' }

    foreach ($skillName in Get-SuperBrainSkillNames) {
      foreach ($skillRoot in @($zSkills,$codexSkills)) {
        $pkg = Test-SuperBrainPackageRootMarker (Join-Path $skillRoot $skillName) $Root
        $mem = Test-SuperBrainMemoryRootMarker (Join-Path $skillRoot $skillName)
        if ($pkg.ok -and $mem.ok) { Mark-Ok "integrated root marker $skillName" } else { Mark-Fail "integrated root marker $skillName" }
      }
    }

    $statusJsonText = & (Join-Path $PSScriptRoot 'status.ps1') -ZCodeSkills $zSkills -CodexSkills $codexSkills -MemoryRoot $tmpMemory -Json
    if ($LASTEXITCODE -ne 0) {
      Mark-Fail 'integrated status json command'
    } else {
      try {
        $statusJson = $statusJsonText | ConvertFrom-Json
        if ($statusJson.ok -eq $true) { Mark-Ok 'integrated status json' } else { Mark-Fail 'integrated status json ok=false' }
      } catch {
        Mark-Fail "integrated status json parse $($_.Exception.Message)"
      }
    }
  } finally {
    if ($hadPolicy) {
      Write-Utf8NoBom $policyPath $originalPolicy
    } elseif (Test-Path $policyPath) {
      Remove-Item -LiteralPath $policyPath -Force
    }
    if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
  }
} else {
  Mark-Ok 'integrated temp install skipped'
}

$statusDir = Join-Path $Root 'memory\workspace'
if (-not (Test-Path $statusDir)) { New-Item -ItemType Directory -Force -Path $statusDir | Out-Null }
$statusPath = Join-Path $statusDir 'last-verify-package.json'
$status = [pscustomobject]@{
  ok = $ok
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $Root
  version = $manifest.version
  results = $results
}
Write-JsonUtf8NoBom $statusPath $status 6
& (Join-Path $PSScriptRoot 'update-state.ps1') | Out-Null

if ($ok) { Write-Host "VERIFY_PACKAGE_OK $statusPath" } else { Write-Host "VERIFY_PACKAGE_FAILED $statusPath"; exit 1 }
