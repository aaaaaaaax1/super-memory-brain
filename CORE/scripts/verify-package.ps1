param(
  [switch]$Integration,
  [switch]$PackageOnly,
  [switch]$WithTempInstall,
  [ValidateRange(0,7200)][int]$TimeoutSeconds = 0,
  [ValidateRange(1,120)][int]$HeartbeatSeconds = 15,
  [switch]$Worker,
  [switch]$Json,
  [string]$ProgressPath = '',
  [string]$ResultPath = '',
  [string]$RunId = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'internal\verify-package-receipt.ps1')

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'

# Source-only verification intentionally has no installed-skill, MCP,
# startup, report, or state-snapshot dependency.  It is the pre-deployment
# package gate: a package must prove its source semantics before a refresh can
# be used to prove the separate installed-entry checks.  Keeping this branch
# report-free prevents the old "deploy first so deployment checks pass" loop.
if ($PackageOnly -and -not $Worker) {
  $started = [DateTime]::UtcNow
  $script:checks = @()
  $script:sourceOk = $true
  function Invoke-PackageOnlyCheck([string]$Name,[scriptblock]$Command) {
    $output = @(& $Command 2>&1)
    $exitCode = $LASTEXITCODE
    $passed = ($exitCode -eq 0)
    if (-not $passed) { $script:sourceOk = $false }
    $detail = if ($passed) { '' } else { (($output | Select-Object -Last 4) -join "`n").Trim() }
    $script:checks += [pscustomobject]@{
      name=$Name
      ok=$passed
      exitCode=$exitCode
      detail=$detail
    }
  }
  Push-Location $Root
  try {
    Invoke-PackageOnlyCheck 'python runtime compile' { python -m py_compile runtime\brain_core.py runtime\execution_assist.py runtime\turn_runtime.py runtime\brain_mcp.py runtime\brain_cli.py runtime\host_visible_tail.py }
    Invoke-PackageOnlyCheck 'core rule registry regression' { python tests\runtime_core_rule_registry_regression.py }
    Invoke-PackageOnlyCheck 'execution assist regression' { python tests\runtime_execution_assist_regression.py }
    Invoke-PackageOnlyCheck 'host visible tail regression' { python tests\runtime_host_visible_tail_regression.py }
    Invoke-PackageOnlyCheck 'host continuation bridge regression' { python tests\runtime_host_continuation_bridge_regression.py }
    Invoke-PackageOnlyCheck 'turn runtime regression' { python tests\runtime_turn_runtime_regression.py }
    Invoke-PackageOnlyCheck 'verify package layers regression' { python tests\runtime_verify_package_layers_regression.py }
    Invoke-PackageOnlyCheck 'memory eval' { powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\memory-eval.ps1 -Json }
  } finally {
    Pop-Location
  }
  $result = [pscustomobject]@{
    schema='super-brain.verify-package-source-result.v1'
    scope='package_source_only'
    ok=[bool]$script:sourceOk
    checkedAt=Get-SuperBrainUtcTimestamp
    packageRoot=$Root
    version=(Get-SuperBrainManifest $Root).version
    deploymentChecked=$false
    wrotePackageStatus=$false
    durationMs=[int](([DateTime]::UtcNow - $started).TotalMilliseconds)
    results=@($script:checks)
  }
  if ($Json) { $result | ConvertTo-Json -Depth 6 } elseif ($script:sourceOk) { Write-Host 'VERIFY_PACKAGE_SOURCE_OK' } else { Write-Host 'VERIFY_PACKAGE_SOURCE_FAILED' }
  if (-not $script:sourceOk) { exit 1 }
  exit 0
}

function ConvertTo-VerifyPackageArgument([string]$Value) {
  return '"' + $Value.Replace('"','\\"') + '"'
}

function Invoke-VerifyPackageCli {
  param(
    [Parameter(Mandatory=$true)][string]$ScriptPath,
    [string[]]$ScriptArguments = @(),
    [switch]$IncludeStderr
  )
  $nativeArguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath) + @($ScriptArguments)
  $output = if ($IncludeStderr) { @(& powershell.exe @nativeArguments 2>&1) } else { @(& powershell.exe @nativeArguments) }
  $exitCode = $LASTEXITCODE
  Set-Variable -Name LASTEXITCODE -Scope Global -Value $exitCode
  return @($output)
}

function Write-VerifyPackageStream([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  foreach ($line in @($Text -split "`r?`n")) {
    $clean = $line.Trim()
    if ($clean -match '^(VERIFY_PACKAGE_|FAILED )') { Write-Host $clean }
  }
}

function Write-VerifyPackageProgress([string]$Line) {
  if ([string]::IsNullOrWhiteSpace($Line)) { return }
  Write-Host $Line
  if ([string]::IsNullOrWhiteSpace($ProgressPath)) { return }
  try {
    $directory = Split-Path -Parent $ProgressPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    [System.IO.File]::AppendAllText($ProgressPath, $Line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
  } catch { }
}

# The public entry runs the existing verifier in an owned child. This gives the
# full package gate a hard stop and heartbeats without changing its checks.
if (-not $Worker) {
  $effectiveTimeoutSeconds = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } elseif ($Integration) { 1200 } else { 900 }
  $workerProgressPath = $ProgressPath
  $removeWorkerProgressPath = $false
  if ([string]::IsNullOrWhiteSpace($workerProgressPath)) {
    $workerProgressPath = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-verify-progress-' + [guid]::NewGuid().ToString('n') + '.log')
    $removeWorkerProgressPath = $true
  }
  $workerResultPath = $ResultPath
  $removeWorkerResultPath = $false
  if ([string]::IsNullOrWhiteSpace($workerResultPath)) {
    $workerResultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('super-brain-verify-result-' + [guid]::NewGuid().ToString('n') + '.json')
    $removeWorkerResultPath = $true
  }
  $workerRunId = if ([string]::IsNullOrWhiteSpace($RunId)) { 'vpr-' + [guid]::NewGuid().ToString('n') } else { $RunId.Trim() }
  if (-not (Clear-VerifyPackageResultReceipt $workerResultPath)) {
    if ($removeWorkerProgressPath) { Remove-Item -LiteralPath $workerProgressPath -Force -ErrorAction SilentlyContinue }
    if ($removeWorkerResultPath) { Remove-Item -LiteralPath $workerResultPath -Force -ErrorAction SilentlyContinue }
    $failure = New-VerifyPackagePublicFailureResult ([pscustomobject]@{
      error = 'VERIFY_PACKAGE_RESULT_PATH_UNAVAILABLE'
      runId = $workerRunId
      exitCode = -1
      timedOut = $false
      timeoutSeconds = $effectiveTimeoutSeconds
      durationMs = 0
      terminatedProcessIds = @()
    })
    if ($Json) { $failure | ConvertTo-Json -Depth 5 } else { Write-Host 'VERIFY_PACKAGE_FAILED error=VERIFY_PACKAGE_RESULT_PATH_UNAVAILABLE' }
    exit 1
  }
  $argumentParts = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-VerifyPackageArgument $PSCommandPath), '-Worker', '-ProgressPath', (ConvertTo-VerifyPackageArgument $workerProgressPath), '-ResultPath', (ConvertTo-VerifyPackageArgument $workerResultPath), '-RunId', (ConvertTo-VerifyPackageArgument $workerRunId)
  )
  if ($Integration) { $argumentParts += '-Integration' }
  if ($WithTempInstall) { $argumentParts += '-WithTempInstall' }
  $handle = Start-SuperBrainOwnedProcess -FilePath 'powershell.exe' -ArgumentLine ($argumentParts -join ' ') -WorkingDirectory $Root
  if (-not $handle.started) {
    if ($removeWorkerProgressPath) { Remove-Item -LiteralPath $workerProgressPath -Force -ErrorAction SilentlyContinue }
    if ($removeWorkerResultPath) { Remove-Item -LiteralPath $workerResultPath -Force -ErrorAction SilentlyContinue }
    $failure = New-VerifyPackagePublicFailureResult ([pscustomobject]@{
      error = 'VERIFY_PACKAGE_START_FAILED'
      runId = $workerRunId
      exitCode = -1
      timedOut = $false
      timeoutSeconds = $effectiveTimeoutSeconds
      durationMs = 0
      terminatedProcessIds = @()
    })
    $failure | Add-Member -NotePropertyName startError -NotePropertyValue ([string]$handle.startError)
    if ($Json) { $failure | ConvertTo-Json -Depth 5 } else { Write-Host "VERIFY_PACKAGE_FAILED startError=$($handle.startError)" }
    exit 1
  }

  $emittedProgressLength = 0
  $completedStepCount = 0
  $lastHeartbeatUtc = [DateTime]::UtcNow
  $outcome = $null
  while ($null -eq $outcome) {
    $captured = [string](Get-SuperBrainOwnedProcessOutputSnapshot $handle).stdout
    $progress = ''
    if (Test-Path -LiteralPath $workerProgressPath) {
      try { $progress = [System.IO.File]::ReadAllText($workerProgressPath) } catch { $progress = '' }
    }
    if ($progress.Length -gt $emittedProgressLength) {
      $delta = $progress.Substring($emittedProgressLength)
      $emittedProgressLength = $progress.Length
      foreach ($line in @($delta -split "`r?`n")) {
        if ($line -match '^VERIFY_STEP ') {
          $completedStepCount += 1
          $emitStep = $false
          $stepName = ''
          $stepOk = ''
          $stepDurationMs = 0
          if ($line -match '^VERIFY_STEP name=(.+) ok=(true|false) durationMs=(\d+)$') {
            $stepName = $Matches[1]
            $stepOk = $Matches[2]
            $stepDurationMs = [int]$Matches[3]
            $emitStep = ($stepOk -ne 'true' -or ($completedStepCount % 100) -eq 0 -or $stepDurationMs -ge 5000)
          }
          if (-not $Json -and $emitStep) {
            Write-Host "VERIFY_PROGRESS completedSteps=$completedStepCount last=$stepName ok=$stepOk durationMs=$stepDurationMs"
          }
        } elseif ($line -match '^VERIFY_STARTED') {
          if (-not $Json) { Write-Host $line.Trim() }
        }
      }
    }

    $hasExited = $false
    try { $handle.process.Refresh(); $hasExited = [bool]$handle.process.HasExited } catch { $hasExited = $true }
    if ($hasExited) {
      $outcome = Complete-SuperBrainOwnedProcess -Handle $handle -TimeoutSeconds $effectiveTimeoutSeconds
      break
    }
    if ($handle.watch.Elapsed.TotalSeconds -ge $effectiveTimeoutSeconds) {
      $outcome = Complete-SuperBrainOwnedProcess -Handle $handle -TimedOut -TimeoutSeconds $effectiveTimeoutSeconds
      break
    }
    if (-not $Json -and (([DateTime]::UtcNow - $lastHeartbeatUtc).TotalSeconds -ge $HeartbeatSeconds)) {
      Write-Host "VERIFY_HEARTBEAT elapsedSeconds=$([int]$handle.watch.Elapsed.TotalSeconds) timeoutSeconds=$effectiveTimeoutSeconds completedSteps=$completedStepCount outputChars=$($captured.Length)"
      $lastHeartbeatUtc = [DateTime]::UtcNow
    }
    Start-Sleep -Milliseconds 250
  }

  if (-not $Json) { Write-VerifyPackageStream $outcome.stdout }
  $receiptCheck = Test-VerifyPackageResultReceipt $workerResultPath $workerRunId
  $workerDecision = Resolve-VerifyPackageWorkerOutcome -Outcome $outcome -ReceiptCheck $receiptCheck -ExpectedRunId $workerRunId -TimeoutSeconds $effectiveTimeoutSeconds
  $verifyOk = ($workerDecision.ok -eq $true)
  if ($Json) {
    Get-VerifyPackagePublicResult $workerDecision | ConvertTo-Json -Depth 16
  }
  if ($removeWorkerProgressPath) { Remove-Item -LiteralPath $workerProgressPath -Force -ErrorAction SilentlyContinue }
  if ($removeWorkerResultPath) { Remove-Item -LiteralPath $workerResultPath -Force -ErrorAction SilentlyContinue }
  if ($verifyOk) { exit 0 }
  if (-not $Json) { Write-Host "VERIFY_PACKAGE_FAILED error=$($workerDecision.error) exitCode=$($outcome.exitCode) timedOut=$($outcome.timedOut) durationMs=$($outcome.durationMs)" }
  exit 1
}

$ok = $true
$results = @()
$script:verifyStartedUtc = [DateTime]::UtcNow
$script:lastVerifyStepUtc = $script:verifyStartedUtc
if ($Worker -and ([string]::IsNullOrWhiteSpace($ResultPath) -or [string]::IsNullOrWhiteSpace($RunId))) {
  Write-Host 'VERIFY_PACKAGE_FAILED error=VERIFY_PACKAGE_WORKER_RECEIPT_PARAMETERS_REQUIRED'
  exit 1
}
if ($Worker) { Write-VerifyPackageProgress 'VERIFY_STARTED' }

if ($Integration) {
  $WithTempInstall = $true
}

function Mark-Ok([string]$Message) {
  $nowUtc = [DateTime]::UtcNow
  $durationMs = [int]($nowUtc - $script:lastVerifyStepUtc).TotalMilliseconds
  $script:lastVerifyStepUtc = $nowUtc
  Write-Host "OK $Message"
  Write-VerifyPackageProgress "VERIFY_STEP name=$Message ok=true durationMs=$durationMs"
  $script:results += [pscustomobject]@{ name = $Message; ok = $true; durationMs = $durationMs }
}

function Mark-Fail([string]$Message) {
  $nowUtc = [DateTime]::UtcNow
  $durationMs = [int]($nowUtc - $script:lastVerifyStepUtc).TotalMilliseconds
  $script:lastVerifyStepUtc = $nowUtc
  Write-Host "FAILED $Message"
  Write-VerifyPackageProgress "VERIFY_STEP name=$Message ok=false durationMs=$durationMs"
  $script:ok = $false
  $script:results += [pscustomobject]@{ name = $Message; ok = $false; durationMs = $durationMs }
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

function Test-ContainsAll([string]$Text, [string[]]$Markers) {
  foreach ($marker in $Markers) {
    if (-not $Text.Contains($marker)) { return $false }
  }
  return $true
}

$required = @(
  'README.md','QUICK_START.md','COMMANDS.md','START_HERE.md','install.bat','manifest.json','super-brain-rules.json','CHANGELOG.md','CURRENT_BASELINE.md','BASELINE_HISTORY.md','memory-policy.json','maintenance-policy.json','intelligence-policy.json','objective-benchmark-policy.json','route-map.json','capabilities.json','runtime-layout.example.json','references\index.md','references\runtime-control-plane.md','references\engineering-judgment.md','references\technology-decision.md','references\technology-catalog.json','references\objective-evaluation.md','references\phase6-memory-evaluation.md','references\four-layer-runtime-layout.md','references\skill-capability-map.seed.json',
  'super-memory-brain\SKILL.md',
  'modules\skill-orchestrator\SKILL.md',
  'modules\plusunm-g1\SKILL.md',
  'modules\nexsandglass-dedicated-memory\SKILL.md',
  'runtime\brain_core.py','runtime\core_rule_registry.py','runtime\turn_intent.py','runtime\brain_context.py','runtime\brain_control.py','runtime\brain_cli.py','runtime\brain_mcp.py','runtime\brain_eval.py','runtime\phase6_memory_eval.py','runtime\continuation_policy.py','runtime\turn_close_dispatcher.py','runtime\codex_prompt_hook.py','runtime\codex_prompt_hook_launcher.py','runtime\codex_prompt_hook_dispatcher.py','runtime\codex_stop_hook.py','runtime\codex_stop_hook_dispatcher.py','runtime\instruction_anchor_store.py','runtime\memory_consolidation.py',
  'vendor\NexSandglass-Agent-DedicatedMemory\sandglass_log.py',
  'vendor\NexSandglass-Agent-DedicatedMemory\sandglass_lock.py',
  'vendor\NexSandglass-Agent-DedicatedMemory\sandglass_sqlite.py',
  'tests\memory-recall-tests.json','tests\memory-eval-tests.json','tests\runtime_core_rule_registry_regression.py','tests\runtime_turn_intent_regression.py','tests\runtime_brain_regression.py','tests\runtime_brain_control_regression.py','tests\runtime_native_memory_prompt_hook_regression.py','tests\runtime_brain_ui_server_regression.py','tests\runtime_migration_launcher_regression.py','tests\runtime_index_regression.py','tests\runtime_index_cache_regression.py','tests\runtime_sqlite_resource_regression.py','tests\runtime_verify_package_layers_regression.py','tests\recall_quality_diagnostic.py','tests\phase6_memory_eval_regression.py','tests\powershell\TurnCloseContinuation.Tests.ps1','tests\powershell\NoHookTurnCloseDispatcher.Tests.ps1','tests\powershell\RecoveryCheckpointFreshness.Tests.ps1','tests\powershell\CrossSessionRecoveryMatrix.Tests.ps1','tests\powershell\Phase6AnswerArtifactGenerator.Tests.ps1','tests\powershell\ObjectiveAnswerArtifactGenerator.Tests.ps1','tests\powershell\ObjectiveBenchmarkRunner.Tests.ps1','tests\powershell\SelfImprovementQueue.Tests.ps1','tests\powershell\SkillEvolution.Tests.ps1','tests\powershell\BootstrapTransaction.Tests.ps1','tests\powershell\IntentContract.Tests.ps1','tests\powershell\ColdStartCapabilityMap.Tests.ps1',
  'tests\powershell\AbsorbedCapabilityRouting.Tests.ps1','tests\powershell\H7RuntimeWakeControlPlane.Tests.ps1',
  'scripts\workspace-lifecycle-manager.ps1','scripts\auto-hygiene-runner.ps1','scripts\post-task-maintenance.ps1','scripts\self-model.ps1','scripts\self-improvement-queue.ps1',
  'scripts\install.ps1','scripts\install.bat','scripts\install-ui.ps1','scripts\install-ui.vbs','scripts\brain.bat','scripts\brain-ui.vbs','scripts\check-install-ui-paths.ps1','scripts\status.ps1','scripts\doctor.ps1','scripts\maintain.ps1','scripts\summary.ps1','scripts\script-tiers.ps1','scripts\memory-health.ps1','scripts\write-memory.ps1','scripts\write-experience.ps1','scripts\audit-memory.ps1',
  'scripts\baseline-update.ps1','scripts\compact.ps1','scripts\compact-report.ps1','scripts\compact-apply.ps1','scripts\backup.ps1','scripts\backup-retention.ps1',
  'scripts\verify-package.ps1','scripts\auto-check.ps1','scripts\startup-check.ps1','scripts\first-load-bootstrap.ps1','scripts\retire-codex-super-brain-hooks.ps1','scripts\codex-user-prompt-hook.ps1','scripts\internal\verify-package-receipt.ps1','scripts\internal\hook-runtime-common.ps1','scripts\internal\codex-hook-host-state.ps1','scripts\internal\intent-resolution.ps1','scripts\internal\phase-closeout-core.ps1','scripts\internal\install-transaction.ps1','scripts\internal\memory-rewrite-transaction.ps1','scripts\internal\responses-api-bridge.ps1','scripts\install-codex-user-prompt-hook.ps1','scripts\install-codex-stop-hook.ps1','scripts\install-runtime.ps1','scripts\runtime-eval.ps1','scripts\runtime-status.ps1','scripts\script-call-contract.ps1','scripts\update-state.ps1','scripts\state.ps1','scripts\recall-search.ps1','scripts\recall-recent.ps1','scripts\session-restore.ps1','scripts\session-binding.ps1','scripts\learn-memory.ps1','scripts\profile-card.ps1','scripts\user-adaptation.ps1','scripts\user-adaptation-observer.ps1','scripts\internal\user-adaptation-core.ps1','scripts\internal\runtime-wake-core.ps1','scripts\install-agent.ps1','scripts\hot-refresh-skills.ps1','scripts\install-menu.ps1','scripts\cleanup-legacy-memory.ps1','scripts\cleanup-install-backups.ps1','scripts\migrate-memory-layout.ps1','scripts\repair-hook.ps1','scripts\encoding-check.ps1','scripts\graph-normalize.ps1','scripts\write-decision.ps1','scripts\decision-search.ps1','scripts\decision-audit.ps1','scripts\bootstrap.ps1','scripts\graph-add.ps1','scripts\graph-search.ps1','scripts\extract-facts.ps1','scripts\phase6-memory-eval.ps1','scripts\phase6-answer-artifact-generator.ps1','scripts\objective-answer-artifact-generator.ps1','scripts\evaluation-learning-bridge.ps1',
  'scripts\optimize-advisor.ps1','scripts\tool-health.ps1','scripts\skill-capability-map.ps1','scripts\absorbed-capability-route.ps1',
  'scripts\accepted-constraints-preflight.ps1',
  'scripts\goal-route-lock.ps1','scripts\route-checkpoint.ps1','scripts\verified-module-snapshot.ps1','scripts\integration-parity-check.ps1','scripts\causal-change-plan.ps1','scripts\engineering-decision-gate.ps1','scripts\technology-decision.ps1','scripts\decision-binding.ps1',
  'scripts\checkpoint-writer.ps1','scripts\execution-contract.ps1','scripts\task-register.ps1','scripts\task-link-store.ps1','scripts\task-state-store.ps1','scripts\task-lifecycle-audit.ps1','scripts\routing-kernel.ps1',
  'modules\skill-pool-router\scripts\skill-catalog.ps1',
  'scripts\test-recall.ps1','scripts\route-regression.ps1','scripts\memory-eval.ps1','scripts\intelligence-eval.ps1','scripts\autonomy-evidence-ledger.ps1','scripts\objective-benchmark.ps1','scripts\objective-benchmark-runner.ps1','scripts\objective-answer-artifact-generator.ps1','scripts\memory-eval-report.ps1','scripts\tag-legacy-memory.ps1','scripts\ci.ps1','scripts\lint.ps1','scripts\test-pester.ps1','scripts\concurrency-smoke-test.ps1','scripts\task-verification.ps1','scripts\team-dispatch-check.ps1','scripts\team-template-list.ps1','scripts\team-task-new.ps1','scripts\team-task-add-delegation.ps1','scripts\team-task-authorize.ps1','scripts\team-task-review.ps1','scripts\team-task-audit.ps1','scripts\team-task-decision.ps1','scripts\team-task-status.ps1','scripts\team-task-index.ps1','scripts\smoke-test.ps1','scripts\common.ps1','scripts\session-compact.ps1'
)

foreach ($rel in $required) {
  $path = Join-Path $Root $rel
  if (Test-Path $path) { Mark-Ok $rel } else { Mark-Fail "MISSING $rel" }
}

$invalidSkillFrontmatter = @()
foreach ($skillRootName in @('super-memory-brain','modules','extensions')) {
  $skillRootPath = Join-Path $Root $skillRootName
  foreach ($skillFile in @(Get-ChildItem -LiteralPath $skillRootPath -Recurse -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue)) {
    $bytes = [IO.File]::ReadAllBytes($skillFile.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 45 -or $bytes[1] -ne 45 -or $bytes[2] -ne 45) {
      $invalidSkillFrontmatter += $skillFile.FullName.Substring($Root.Length).TrimStart('\','/')
    }
  }
}
if ($invalidSkillFrontmatter.Count -eq 0) { Mark-Ok 'all package skills start with YAML frontmatter at byte zero' } else { Mark-Fail ('skill frontmatter/BOM invalid: ' + ($invalidSkillFrontmatter -join ', ')) }

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

$controlledSwitches = @('Apply','ApplySafe','ApplyConfirmed','Force','Fix','NoBackup','NoGraph','SkipVerify','SkipHook','SkipHealthCheck','ConfirmPrivate','Preview','AllowDuplicate','Refresh','Integration','WithTempInstall','SkipIntegration','SmokeTest','AllKnown')
foreach ($entry in $metadata) {
  $scriptPath = Join-Path (Join-Path $Root 'scripts') $entry.path
  if (-not (Test-Path $scriptPath)) { continue }
  $scriptText = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
  $mutationAnalysis = Test-SuperBrainPersistentScriptMutation $scriptPath
  if (-not $mutationAnalysis.ok) {
    Mark-Fail "script mutation analysis parse $($entry.path)"
  } elseif ($entry.tier -eq 'T0' -and @($mutationAnalysis.mutations).Count -gt 0) {
    Mark-Fail "T0 script has persistent mutating command $($entry.path)"
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
if ($null -ne $memoryPolicy.selfModel -and $memoryPolicy.selfModel.enabled -eq $true -and [int]$memoryPolicy.selfModel.maxAgeHours -gt 0 -and [int]$memoryPolicy.selfModel.maxEvidenceItems -gt 0 -and [int]$memoryPolicy.selfModel.maxPreferenceItems -gt 0 -and $null -ne $memoryPolicy.selfModel.alwaysOnInjection -and $memoryPolicy.selfModel.alwaysOnInjection -eq $false -and @($memoryPolicy.selfModel.refreshSources) -contains 'last-verify-package.json' -and @($memoryPolicy.selfModel.refreshSources) -contains 'current-task-context.json' -and @($memoryPolicy.selfModel.refreshSources) -contains 'user-adaptation/profile.json') { Mark-Ok 'memory policy bounded self-model schema' } else { Mark-Fail 'memory policy bounded self-model schema missing' }

try {
  $maintenancePolicy = Read-Utf8 'maintenance-policy.json' | ConvertFrom-Json
  Mark-Ok 'maintenance-policy.json parse'
} catch {
  Mark-Fail "maintenance-policy.json parse $($_.Exception.Message)"
  $maintenancePolicy = [pscustomobject]@{}
}
if ($maintenancePolicy.mode -eq 'plan_only' -and $maintenancePolicy.mutationAuthorization.default -eq 'deny' -and $maintenancePolicy.automaticActions.postTaskMaintenance.enabled -eq $true -and @($maintenancePolicy.requiresConfirmation).Count -gt 0 -and @($maintenancePolicy.continuationPriority)[0] -eq 'visible_context') { Mark-Ok 'maintenance policy plan-only authorization schema' } else { Mark-Fail 'maintenance policy plan-only authorization schema missing' }

try {
  $intelligencePolicy = Read-Utf8 'intelligence-policy.json' | ConvertFrom-Json
  Mark-Ok 'intelligence-policy.json parse'
} catch {
  Mark-Fail "intelligence-policy.json parse $($_.Exception.Message)"
  $intelligencePolicy = [pscustomobject]@{}
}
$personalWeightSum = @($intelligencePolicy.weights.personalControlPlane.PSObject.Properties | Measure-Object -Property Value -Sum).Sum
$autonomousWeightSum = @($intelligencePolicy.weights.autonomousBrain.PSObject.Properties | Measure-Object -Property Value -Sum).Sum
if ($intelligencePolicy.schema -eq 'super-brain.intelligence-policy.v1' -and $intelligencePolicy.claimScope -eq 'internal_acceptance_only' -and [Math]::Abs([double]$personalWeightSum-1.0) -lt 0.000001 -and [Math]::Abs([double]$autonomousWeightSum-1.0) -lt 0.000001 -and [double]$intelligencePolicy.targets.personalControlPlane -ge 9.0 -and [double]$intelligencePolicy.targets.autonomousBrain -ge 8.5 -and [int]$intelligencePolicy.antiOverfitting.personalMinimumHoldoutCases -ge 30 -and [double]$intelligencePolicy.antiOverfitting.gapPenaltyScale -gt 0 -and [double]$intelligencePolicy.antiOverfitting.noHoldoutPersonalCeiling -lt [double]$intelligencePolicy.targets.personalControlPlane) { Mark-Ok 'intelligence policy internal-only anti-overfit gates' } else { Mark-Fail 'intelligence policy internal-only anti-overfit gates missing' }

try {
  $objectivePolicy = Read-Utf8 'objective-benchmark-policy.json' | ConvertFrom-Json
  Mark-Ok 'objective-benchmark-policy.json parse'
} catch {
  Mark-Fail "objective-benchmark-policy.json parse $($_.Exception.Message)"
  $objectivePolicy = [pscustomobject]@{}
}
$objectiveIds = @($objectivePolicy.benchmarks | ForEach-Object { [string]$_.id })
$objectiveRequired = @('swebench_verified','bfcl','longmemeval','longmemeval_v2','tau3_bench')
$objectiveMissing = @($objectiveRequired | Where-Object { $objectiveIds -notcontains $_ })
$objectivePinsValid = @($objectivePolicy.benchmarks | Where-Object { [string]$_.pinnedCommit -notmatch '^[0-9a-f]{40}$' }).Count -eq 0
if ($objectivePolicy.schema -eq 'super-brain.objective-benchmark-policy.v1' -and $objectivePolicy.claimPolicy.beforeOfficialRun -eq 'not_scored' -and $objectivePolicy.claimPolicy.forbidCrossBenchmarkAggregate -eq $true -and $objectivePolicy.claimPolicy.requiredDesign -eq 'paired_ab_same_host_model' -and $objectiveMissing.Count -eq 0 -and $objectivePinsValid) { Mark-Ok 'objective benchmark external paired protocol' } else { Mark-Fail 'objective benchmark external paired protocol missing' }

$runtimeFiles = @($manifest.runtimeFiles)
if ($runtimeFiles.Count -gt 0) { Mark-Ok 'runtime files manifest present' } else { Mark-Fail 'runtime files manifest missing' }
foreach ($runtimeFile in $runtimeFiles) {
  if (Test-Path (Join-Path (Join-Path $Root 'vendor\NexSandglass-Agent-DedicatedMemory') $runtimeFile)) { Mark-Ok "runtime vendor file $runtimeFile" } else { Mark-Fail "runtime vendor file missing $runtimeFile" }
}

$nativeRuntimeFiles = @($manifest.nativeRuntimeFiles)
$legacyCompatibilityFiles = @($manifest.legacyCompatibilityFiles)
if ($nativeRuntimeFiles.Count -gt 0) { Mark-Ok 'native runtime files manifest present' } else { Mark-Fail 'native runtime files manifest missing' }
$nativeRuntimeDuplicates = @($nativeRuntimeFiles | Group-Object | Where-Object { $_.Count -gt 1 })
if ($nativeRuntimeDuplicates.Count -eq 0) { Mark-Ok 'native runtime files unique' } else { Mark-Fail ('native runtime duplicate files ' + (($nativeRuntimeDuplicates | ForEach-Object { $_.Name }) -join ',')) }
foreach ($nativeRuntimeFile in $nativeRuntimeFiles) {
  $nativePath = Join-Path $Root ([string]$nativeRuntimeFile)
  if (Test-Path -LiteralPath $nativePath) { Mark-Ok "native runtime file $nativeRuntimeFile" } else { Mark-Fail "native runtime file missing $nativeRuntimeFile" }
}
$legacyCompatibilityDuplicates = @($legacyCompatibilityFiles | Group-Object | Where-Object { $_.Count -gt 1 })
if ($legacyCompatibilityDuplicates.Count -eq 0 -and $legacyCompatibilityFiles.Count -gt 0) { Mark-Ok 'retired compatibility inventory present' } else { Mark-Fail 'retired compatibility inventory missing or duplicated' }
foreach ($legacyCompatibilityFile in $legacyCompatibilityFiles) {
  $legacyPath = Join-Path $Root ([string]$legacyCompatibilityFile)
  if (Test-Path -LiteralPath $legacyPath) { Mark-Ok "retired compatibility file $legacyCompatibilityFile" } else { Mark-Fail "retired compatibility file missing $legacyCompatibilityFile" }
}
$inactiveRuntimeBackups = @()
$actualNativeRuntimeFiles = @(Get-ChildItem -LiteralPath (Join-Path $Root 'runtime') -File -ErrorAction SilentlyContinue | Where-Object {
  if ($_.Name -match '\.local-runtime-backup-[A-Za-z0-9._-]+$') {
    $inactiveRuntimeBackups += $_
    return $false
  }
  return $true
} | ForEach-Object { 'runtime\' + $_.Name })
foreach ($backup in @($inactiveRuntimeBackups)) { Mark-Ok "inactive runtime backup excluded from active source inventory runtime\$($backup.Name)" }
foreach ($nativeRuntimeFile in $actualNativeRuntimeFiles) {
  if ($nativeRuntimeFiles -contains $nativeRuntimeFile) { Mark-Ok "native runtime inventory listed $nativeRuntimeFile" } elseif ($legacyCompatibilityFiles -contains $nativeRuntimeFile) { Mark-Ok "retired native runtime compatibility listed $nativeRuntimeFile" } else { Mark-Fail "native runtime inventory missing $nativeRuntimeFile" }
}
if ($manifest.runtimeMode -eq 'hookless_h7' -and $legacyCompatibilityFiles.Count -gt 0) { Mark-Ok 'manifest H7 runtime mode and retired compatibility boundary' } else { Mark-Fail 'manifest H7 runtime mode or retired compatibility boundary missing' }
$coreRuleRegistryPath = Join-Path $Root 'super-brain-rules.json'
$coreRuleRegistryTest = Join-Path $Root 'tests\runtime_core_rule_registry_regression.py'
try {
  $coreRuleRegistry = Get-Content -LiteralPath $coreRuleRegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $declaredCoreRuleRegistry = $manifest.coreRuleRegistry
  $declaredCoreRuleIds = @($declaredCoreRuleRegistry.requiredRuleIds | ForEach-Object { [string]$_ })
  $actualCoreRuleIds = @($coreRuleRegistry.rules | ForEach-Object { [string]$_.ruleId })
  $requiredCoreRuleIds = @('SB-PROJECT-GROUNDED-DESIGN-001','SB-DEFECT-ROOT-REPAIR-001','SB-RULE-MEMORY-SPLIT-001','SB-UNIFIED-SHARED-MEMORY-001','SB-ABILITY-ABSORPTION-001','SB-FOUR-QUADRANT-EXECUTION-001','SB-CONCURRENT-STATE-CAS-001','SB-LATEST-STATE-001','SB-VISIBLE-PROGRESS-ANCHOR-001','SB-PROGRESS-TRUTH-001','SB-PROPOSAL-GATE-001','SB-AUTO-RESUME-001','SB-STAGE-VERIFY-001','SB-STAGE-USER-RECEIPT-001','SB-EFFICIENT-DELIVERY-001','SB-NO-REPEAT-FAILED-ROUTE-001','SB-CHILD-LIFECYCLE-001','SB-H7-ACTIVATION-001','SB-RUNTIME-ADAPTER-INDEPENDENCE-001','SB-ADAPTER-CONCISENESS-001','SB-BOOTSTRAP-SINGLE-SOURCE-001')
  $registryShapeCurrent = (
    $coreRuleRegistry.schema -eq 'super-brain.core-rule-registry.v1' -and
    [int]$coreRuleRegistry.registryVersion -ge 1 -and
    $coreRuleRegistry.hashAlgorithm -eq 'sha256(canonical-json-without-payloadHash)' -and
    [string]$coreRuleRegistry.payloadHash -match '^[0-9a-f]{64}$' -and
    $declaredCoreRuleRegistry.path -eq 'super-brain-rules.json' -and
    $declaredCoreRuleRegistry.schema -eq $coreRuleRegistry.schema -and
    $declaredCoreRuleRegistry.hashAlgorithm -eq $coreRuleRegistry.hashAlgorithm -and
    @($requiredCoreRuleIds | Where-Object { $declaredCoreRuleIds -notcontains $_ -or $actualCoreRuleIds -notcontains $_ }).Count -eq 0
  )
  if ($registryShapeCurrent) { Mark-Ok 'core rule registry manifest declaration' } else { Mark-Fail 'core rule registry manifest declaration invalid' }
} catch {
  Mark-Fail "core rule registry parse $($_.Exception.Message)"
}
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction SilentlyContinue }
if ($null -eq $pythonCommand) {
  Mark-Fail 'core rule registry validator Python unavailable'
} else {
  $coreRuleRegistryOutput = @(& $pythonCommand.Source -X utf8 $coreRuleRegistryTest 2>&1)
  $coreRuleRegistryExitCode = $LASTEXITCODE
  if ($coreRuleRegistryExitCode -eq 0 -and (($coreRuleRegistryOutput -join [Environment]::NewLine) -match 'CORE_RULE_REGISTRY_REGRESSION_OK')) { Mark-Ok 'core rule registry signed validator' } else { Mark-Fail ('core rule registry signed validator failed ' + (($coreRuleRegistryOutput | Select-Object -Last 3) -join ' ')) }
}
$turnIntentText = Read-Utf8 'runtime\turn_intent.py'
if (Test-ContainsAll $turnIntentText @('TURN_INTENTS','projectEvidenceRequired','learningWriteAllowed','executionAssistRequired','executionAssistAllowed','rawPromptStored','resolve_turn_intent')) { Mark-Ok 'stateless turn intent split' } else { Mark-Fail 'stateless turn intent split missing' }
$selfModelRuntimeText = Read-Utf8 'runtime\brain_core.py'
if (Test-ContainsAll $selfModelRuntimeText @('def agent_identity','independent_control_plane_agent','def authority_model','latest_user_instruction','h7_scope_bound_execution_contract','assistant_visible_reply_plus_current_project_progress_proof','live_project_evidence','versioned_core_rule_registry','entry_only_non_authorizing','bounded_collaborator_agents','withhold_reconcile')) { Mark-Ok 'independent control-plane Agent identity and role-separated authority model' } else { Mark-Fail 'independent control-plane Agent identity or authority model missing' }
if ($selfModelRuntimeText -like '*def _self_model_candidates*' -and $selfModelRuntimeText -like '*snapshotStatus*' -and $selfModelRuntimeText -like '*verificationStatus*' -and $selfModelRuntimeText -like '*rawPromptStored*' -and $selfModelRuntimeText -like '*KNOWN_LIMITATION*' -and $selfModelRuntimeText -like '*if verification_status == "verified"*') { Mark-Ok 'native runtime self-model evidence and degradation guard' } else { Mark-Fail 'native runtime self-model evidence and degradation guard missing' }
if ($selfModelRuntimeText -like '*def _retrieval_output_policy*' -and $selfModelRuntimeText -like '*summary_confidence*' -and $selfModelRuntimeText -like '*inject_confidence*' -and $selfModelRuntimeText -like '*recallDisposition*' -and $selfModelRuntimeText -like '*injectReady*') { Mark-Ok 'native runtime retrieval policy parity guard' } else { Mark-Fail 'native runtime retrieval policy parity guard missing' }
if ($selfModelRuntimeText -like '*adaptiveSparse*' -and $selfModelRuntimeText -like '*sandglass_fts5_readonly*' -and $selfModelRuntimeText -like '*def _read_only_fts_rows*' -and $selfModelRuntimeText -like '*def _scan_sandglass_candidates*' -and $selfModelRuntimeText -notlike '*sync_incremental*' -and $selfModelRuntimeText -notlike '*_module(*') { Mark-Ok 'native runtime read-only adaptive sparse recall guard' } else { Mark-Fail 'native runtime read-only adaptive sparse recall guard missing' }
$turnCloseDispatcherText = Read-Utf8 'runtime\turn_close_dispatcher.py'
$brainCliText = Read-Utf8 'runtime\brain_cli.py'
if ((Test-ContainsAll $turnCloseDispatcherText @('dispatch_turn_close','decide_turn_close','-Action','CloseTurn','ExpectedRevision','ExpectedPlanFingerprint','rawPromptStored')) -and (Test-ContainsAll $brainCliText @('turn-close','dispatch_turn_close','--completion-evidence-ref'))) { Mark-Ok 'no-Hook turn-close dispatcher and CLI route' } else { Mark-Fail 'no-Hook turn-close dispatcher or CLI route missing' }
$contextRuntimeText = Read-Utf8 'runtime\brain_context.py'
if ($contextRuntimeText -like '*Pure, scope-bound Super Brain context projection helpers*' -and $contextRuntimeText -like '*never creates directories*' -and $contextRuntimeText -like '*select_native_memory_entries*' -and $contextRuntimeText -notlike '*sqlite3.connect*') { Mark-Ok 'native current-turn context pure-read guard' } else { Mark-Fail 'native current-turn context pure-read guard missing' }
$sandglassLogText = Read-Utf8 'vendor\NexSandglass-Agent-DedicatedMemory\sandglass_log.py'
if ($sandglassLogText -like '*from sandglass_sqlite import sync_incremental*' -and $sandglassLogText -like '*from sandglass_vault import _sync_index*') { Mark-Ok 'accepted memory writes refresh derived indexes' } else { Mark-Fail 'accepted memory write index refresh missing' }
$learningQueueText = Read-Utf8 'scripts\self-improvement-queue.ps1'
$learnMemoryText = Read-Utf8 'scripts\learn-memory.ps1'
if (
  (Test-ContainsAll $learningQueueText @('function Invoke-ControlledMemoryPromotion','function Complete-ControlledMemoryPromotion','function Mark-ReflectionCandidatePromoted','[hashtable]$Parameters','& $ScriptPath @Parameters','CONTROLLED_MEMORY_VALIDATION_REQUIRED','controlled_memory_promotion_committed')) -and
  (Test-ContainsAll $learnMemoryText @('TaskId = $TaskId','WorkspaceKey = $WorkspaceKey','SessionId = $SessionId','2>&1 3>$null 4>$null 5>$null 6>$null'))
) { Mark-Ok 'controlled learning memory promotion and JSON protocol guard' } else { Mark-Fail 'controlled learning memory promotion or JSON protocol guard missing' }
$compactApplyText = Read-Utf8 'scripts\compact-apply.ps1'
$tagLegacyText = Read-Utf8 'scripts\tag-legacy-memory.ps1'
$autoHygieneRewriteText = Read-Utf8 'scripts\auto-hygiene-runner.ps1'
$memoryRewriteTransactionText = Read-Utf8 'scripts\internal\memory-rewrite-transaction.ps1'
$archiveText = Read-Utf8 'vendor\NexSandglass-Agent-DedicatedMemory\sandglass_archive.py'
$pulseText = Read-Utf8 'vendor\NexSandglass-Agent-DedicatedMemory\pulse.py'
if ((Test-ContainsAll ($compactApplyText + $tagLegacyText + $autoHygieneRewriteText) @('Invoke-SuperBrainMemoryRewriteTransaction')) -and (Test-ContainsAll $memoryRewriteTransactionText @('MEMORY_REWRITE_SOURCE_HASH_MISMATCH','New-SuperBrainMemoryDerivedIndexSnapshot','Restore-SuperBrainMemoryDerivedIndexSnapshot','rebuild_indexes','rolled_back')) -and (Test-ContainsAll $archiveText @('cold_migration_preview_only','requiresConfirmation')) -and $pulseText -like '*cold_migration(dry_run=True)*') { Mark-Ok 'physical memory rewrite transaction and cold migration guard' } else { Mark-Fail 'physical memory rewrite transaction or cold migration guard missing' }
$runtimeRegressionOutput = @(& python (Join-Path $Root 'tests\runtime_brain_regression.py') 2>&1)
$runtimeRegressionText = ($runtimeRegressionOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $runtimeRegressionText -like '*RUNTIME_BRAIN_REGRESSION_OK*') { Mark-Ok 'native runtime regression' } else { Mark-Fail "native runtime regression $runtimeRegressionText" }
$executionAssistRegressionOutput = @(& python (Join-Path $Root 'tests\runtime_execution_assist_regression.py') 2>&1)
$executionAssistRegressionText = ($executionAssistRegressionOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $executionAssistRegressionText -like '*runtime_execution_assist_regression: PASS*') { Mark-Ok 'native four-quadrant execution-assist regression' } else { Mark-Fail "native four-quadrant execution-assist regression $executionAssistRegressionText" }
$brainControlRegressionOutput = @(& python (Join-Path $Root 'tests\runtime_brain_control_regression.py') 2>&1)
$brainControlRegressionText = ($brainControlRegressionOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $brainControlRegressionText -like '*RUNTIME_BRAIN_CONTROL_REGRESSION_OK*') { Mark-Ok 'SQLite control-plane shadow regression' } else { Mark-Fail "SQLite control-plane shadow regression $brainControlRegressionText" }
$nativeMemoryPromptHookOutput = @(& python (Join-Path $Root 'tests\runtime_native_memory_prompt_hook_regression.py') 2>&1)
$nativeMemoryPromptHookText = ($nativeMemoryPromptHookOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $nativeMemoryPromptHookText -like '*RUNTIME_H7_HOOKLESS_RETIREMENT_REGRESSION_OK*') { Mark-Ok 'retired P7 dispatcher compatibility regression' } else { Mark-Fail "retired P7 dispatcher compatibility regression $nativeMemoryPromptHookText" }
$uiServerRegressionOutput = @(& python (Join-Path $Root 'tests\runtime_brain_ui_server_regression.py') 2>&1)
$uiServerRegressionText = ($uiServerRegressionOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $uiServerRegressionText -like '*RUNTIME_BRAIN_UI_SERVER_REGRESSION_OK*') { Mark-Ok 'Control Center API and privacy regression' } else { Mark-Fail "Control Center API and privacy regression $uiServerRegressionText" }
$longMemEvalV2AdapterOutput = @(& python (Join-Path $Root 'tests\runtime_longmemeval_v2_adapter_regression.py') 2>&1)
$longMemEvalV2AdapterText = ($longMemEvalV2AdapterOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $longMemEvalV2AdapterText -like '*runtime_longmemeval_v2_adapter_regression: PASS*') { Mark-Ok 'LongMemEval-V2 isolated adapter regression' } else { Mark-Fail "LongMemEval-V2 isolated adapter regression $longMemEvalV2AdapterText" }
$longMemEvalV2EntryOutput = @(& python (Join-Path $Root 'tests\runtime_longmemeval_v2_harness_entry_regression.py') 2>&1)
$longMemEvalV2EntryText = ($longMemEvalV2EntryOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $longMemEvalV2EntryText -like '*runtime_longmemeval_v2_harness_entry_regression: PASS*') { Mark-Ok 'LongMemEval-V2 wrapper retry-budget regression' } else { Mark-Fail "LongMemEval-V2 wrapper retry-budget regression $longMemEvalV2EntryText" }
$runtimeIndexOutput = @(& python (Join-Path $Root 'tests\runtime_index_regression.py') 2>&1)
$runtimeIndexExit = $LASTEXITCODE
$runtimeIndexText = ($runtimeIndexOutput | ForEach-Object { [string]$_ }) -join "`n"
try {
  $runtimeIndex = $runtimeIndexText | ConvertFrom-Json
  if ($runtimeIndexExit -eq 0 -and $runtimeIndex.ok -eq $true -and $runtimeIndex.failedCalls -eq 0 -and $runtimeIndex.stderrCount -eq 0 -and $runtimeIndex.temporaryFileCount -eq 0) { Mark-Ok 'native runtime mixed index concurrency regression' } else { Mark-Fail "native runtime mixed index concurrency regression $runtimeIndexText" }
} catch {
  Mark-Fail "native runtime mixed index concurrency regression parse $runtimeIndexText"
}
$sqliteResourceOutput = @(& python (Join-Path $Root 'tests\runtime_sqlite_resource_regression.py') 2>&1)
$sqliteResourceText = ($sqliteResourceOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $sqliteResourceText -like '*RUNTIME_SQLITE_RESOURCE_REGRESSION_OK*') { Mark-Ok 'native runtime sqlite resource regression' } else { Mark-Fail "native runtime sqlite resource regression $sqliteResourceText" }
$indexCacheOutput = @(& python (Join-Path $Root 'tests\runtime_index_cache_regression.py') 2>&1)
$indexCacheText = ($indexCacheOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $indexCacheText -like '*RUNTIME_INDEX_CACHE_REGRESSION_OK*') { Mark-Ok 'native runtime index cache regression' } else { Mark-Fail "native runtime index cache regression $indexCacheText" }
$diagnosticText = Read-Utf8 'tests\recall_quality_diagnostic.py'
if ($diagnosticText -like '*diagnostic_non_publishable*' -and $diagnosticText -like '*sealedHoldoutsRead*' -and $diagnosticText -like '*unknownAbstentionRate*' -and $diagnosticText -like '*--variants*') { Mark-Ok 'isolated recall quality diagnostic is non-publishable and variant-aware' } else { Mark-Fail 'isolated recall quality diagnostic guard missing' }
$phase6Text = Read-Utf8 'runtime\phase6_memory_eval.py'
$phase6ReferenceText = Read-Utf8 'references\phase6-memory-evaluation.md'
if ($phase6Text -like '*super-brain.memory-e2e-holdout.sealed.v1*' -and $phase6Text -like '*super-brain.memory-e2e-answer-input.v1*' -and $phase6Text -like '*super-brain.memory-e2e-answer-provenance.v2*' -and $phase6Text -like '*validate-answer-input*' -and $phase6Text -like '*ANSWER_INPUT_REQUIRED*' -and $phase6Text -like '*HOLDOUT_ALREADY_RESERVED*' -and $phase6Text -like '*AGGREGATE_FAMILY_OVERLAP*' -and $phase6Text -like '*AGGREGATE_GENERATOR_RUN_REUSE*' -and $phase6Text -like '*memoryRuntimeTreeSha256*' -and $phase6Text -like '*external_blinded_input*' -and $phase6Text -like '*evaluation_ranked_evidence*' -and $phase6Text -like '*AGGREGATE_MARKER_MISSING*' -and $phase6Text -like '*AGGREGATE_FAMILY_REUSE*' -and $phase6Text -like '*objectiveIntelligenceScore*False*' -and $phase6ReferenceText -like '*phase6-answer-artifact-generator.ps1*' -and $phase6ReferenceText -like '*PrepareAnswerInput*' -and $phase6ReferenceText -like '*at least 20 cases*' -and $phase6ReferenceText -like '*Recall@10*' -and $phase6ReferenceText -like '*diagnostic_non_publishable*') { Mark-Ok 'Phase 6 isolated memory E2E contract and anti-overfit guards' } else { Mark-Fail 'Phase 6 isolated memory E2E contract or anti-overfit guards missing' }
$phase6RegressionOutput = @(& python (Join-Path $Root 'tests\phase6_memory_eval_regression.py') 2>&1)
$phase6RegressionText = ($phase6RegressionOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $phase6RegressionText -like '*PHASE6_MEMORY_EVAL_REGRESSION_OK*') { Mark-Ok 'Phase 6 memory E2E regression' } else { Mark-Fail "Phase 6 memory E2E regression $phase6RegressionText" }
$responsesClientRegressionOutput = @(& python (Join-Path $Root 'tests\runtime_responses_api_client_regression.py') 2>&1)
$responsesClientRegressionText = ($responsesClientRegressionOutput | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -eq 0 -and $responsesClientRegressionText -like '*runtime_responses_api_client_regression: PASS*') { Mark-Ok 'Responses transport selection and fail-closed regression' } else { Mark-Fail "Responses transport selection and fail-closed regression $responsesClientRegressionText" }
$evaluationLearningBridgeText = Read-Utf8 'scripts\evaluation-learning-bridge.ps1'
$skillEvolutionText = Read-Utf8 'scripts\skill-evolution.ps1'
if ($evaluationLearningBridgeText -like '*super-brain.evaluation-learning-bridge.v1*' -and $evaluationLearningBridgeText -like '*AGGREGATE_STALE*' -and $evaluationLearningBridgeText -like '*staged_only*' -and $evaluationLearningBridgeText -like '*noAutomaticRuleMutation*' -and $skillEvolutionText -like '*VALIDATION_ARTIFACT_REQUIRED*' -and $skillEvolutionText -like '*WorkspaceRoot*' -and $skillEvolutionText -like '*PROPOSAL_ID_COLLISION*') { Mark-Ok 'evaluation learning bridge and evidence-bound validation guards' } else { Mark-Fail 'evaluation learning bridge or evidence-bound validation guards missing' }
$blindRunnerText = Read-Utf8 'scripts\objective-benchmark-runner.ps1'
$phase6GeneratorText = Read-Utf8 'scripts\phase6-answer-artifact-generator.ps1'
$objectiveGeneratorText = Read-Utf8 'scripts\objective-answer-artifact-generator.ps1'
$responsesBridgeText = Read-Utf8 'scripts\internal\responses-api-bridge.ps1'
if ($phase6GeneratorText -like '*GENERATE_APPLY_REQUIRED*' -and $phase6GeneratorText -like '*ANSWER_OUTPUT_NOT_PRIVATE*' -and $phase6GeneratorText -like '*SUPER_BRAIN_ANSWER_RESPONSES_URL*' -and $phase6GeneratorText -like '*expectedAnswerDataAvailable = $false*' -and $phase6GeneratorText -like '*rawResponseStored = $false*' -and $phase6GeneratorText -like '*responseReceiptSha256*' -and $responsesBridgeText -like '*codex_desktop_config*' -and $responsesBridgeText -like '*smag_managed_cache*' -and $responsesBridgeText -like '*SMAG_RESPONSES_URL*') { Mark-Ok 'Phase 6 private external answer generator and credential fallback guards' } else { Mark-Fail 'Phase 6 private external answer generator or credential fallback guards missing' }
if ($objectiveGeneratorText -like '*super-brain.objective-answer-input.v1*' -and $objectiveGeneratorText -like '*OBJECTIVE_OUTPUT_NOT_PRIVATE*' -and $objectiveGeneratorText -like '*OBJECTIVE_BASELINE_CONTEXT_NOT_EMPTY*' -and $objectiveGeneratorText -like '*GENERATE_APPLY_REQUIRED*' -and $objectiveGeneratorText -like '*referenceOrRubricSentToModel = $false*' -and $objectiveGeneratorText -like '*benchmarkVariant = ''s_cleaned''*' -and $objectiveGeneratorText -like '*independentExecution = $true*' -and $objectiveGeneratorText -like '*rawResponseStored = $false*') { Mark-Ok 'objective private single-arm answer generator guards' } else { Mark-Fail 'objective private single-arm answer generator guards missing' }
if (
  $blindRunnerText -like '*ANSWER_CASE_SET_HASH_MISMATCH*' -and
  $blindRunnerText -like '*ANSWER_MODEL_IDENTITY_INVALID*' -and
  $blindRunnerText -like '*ANSWER_BENCHMARK_VARIANT_INVALID*' -and
  $blindRunnerText -like '*ANSWER_RESPONSE_MODEL_MISMATCH*' -and
  $blindRunnerText -like '*JUDGE_REPORTED_MODEL_MISMATCH*' -and
  $blindRunnerText -like '*ConvertFrom-JudgeEventStream*' -and
  $blindRunnerText -like '*response.completed*' -and
  $blindRunnerText -like '*JUDGE_CHECKPOINT_ENDPOINT_MISSING*' -and
  $blindRunnerText -like '*ExpectedStateSha256*' -and
  $blindRunnerText -like '*ANSWER_ARTIFACT_TAMPERED*' -and
  $blindRunnerText -like '*JUDGE_CHECKPOINT_EVIDENCE_MISMATCH*' -and
  $blindRunnerText -like '*Assert-SuperBrainResponsesTransportProbeReceipt*' -and
  $blindRunnerText -like '*objective-judge*' -and
  $blindRunnerText -like '*transportProbeReceiptSha256*' -and
  $blindRunnerText -like '*newDecisionCount*'
) { Mark-Ok 'objective blind runner binds case set, actual models, prepared state, and source artifacts' }
else { Mark-Fail 'objective blind runner integrity guards missing' }
$intelligenceBehaviorFiles = @($manifest.intelligenceBehaviorFiles)
if ($intelligenceBehaviorFiles.Count -ge 6) { Mark-Ok 'intelligence behavior source binding inventory present' } else { Mark-Fail 'intelligence behavior source binding inventory missing' }
foreach ($behaviorFile in $intelligenceBehaviorFiles) {
  if (Test-Path -LiteralPath (Join-Path $Root ([string]$behaviorFile)) -PathType Leaf) { Mark-Ok "intelligence behavior source $behaviorFile" } else { Mark-Fail "intelligence behavior source missing $behaviorFile" }
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
if ($baselineText -like '*super-brain-rules.json*' -and $baselineText -like '*latest real assistant-visible reply*' -and $baselineText -like '*direct Git working tree*') { Mark-Ok 'baseline current control-plane summary' } else { Mark-Fail 'baseline current control-plane summary missing' }

$historyText = Read-Utf8 'BASELINE_HISTORY.md'
if ($historyText -like "*## $($manifest.version)*") { Mark-Ok 'Baseline history' } else { Mark-Fail 'Baseline history missing current version' }

$changelogText = Read-Utf8 'CHANGELOG.md'
if ($changelogText -like "*## $($manifest.version)*") { Mark-Ok 'Changelog current version' } else { Mark-Fail 'Changelog missing current version' }

$readmeText = Read-Utf8 'README.md'
if ($readmeText -like "*$($manifest.version)*") { Mark-Ok 'README current version' } else { Mark-Fail 'README missing current version' }
if ($readmeText -like '*CURRENT_BASELINE.md*manifest.json*CHANGELOG.md*') { Mark-Ok 'README recall order' } else { Mark-Fail 'README recall order missing' }
if ($readmeText -like '*QUICK_START.md*' -and $readmeText -like '*COMMANDS.md*' -and $readmeText -like '*doctor.ps1*') { Mark-Ok 'README quick command docs' } else { Mark-Fail 'README quick command docs missing' }
if ($readmeText -like '*verify-package.ps1*' -and $readmeText -like '*PackageOnly*' -and $readmeText -like '*release-readiness.ps1*') { Mark-Ok 'README source verification docs' } else { Mark-Fail 'README source verification docs missing' }
if ($readmeText.Contains('Hybrid Recall') -and $readmeText.Contains('memory-eval.ps1') -and $readmeText.Contains('last-memory-eval.json') -and $readmeText.Contains('ADR')) { Mark-Ok 'README hybrid ADR eval docs' } else { Mark-Fail 'README hybrid ADR eval docs missing' }
if ($readmeText -like '*cleanup-install-backups.ps1*') { Mark-Ok 'README install backup cleanup docs' } else { Mark-Fail 'README install backup cleanup docs missing' }
if (Test-ContainsAll $readmeText @('scripts\install-ui.vbs','scripts\install.bat console','scripts\brain.bat','super-memory-brain','host entry','uses H7','brain_turn','install or depend on P7/Hook','check-install-ui-paths.ps1')) { Mark-Ok 'README H7 installer and control-center docs' } else { Mark-Fail 'README H7 installer and control-center docs missing' }
if ($readmeText -like '*Commander Agent Teams*' -and $readmeText -like '*team-dispatch-check.ps1*' -and $readmeText -like '*team-task-status.ps1*') { Mark-Ok 'README Commander team docs' } else { Mark-Fail 'README Commander team docs missing' }

$quickStartText = Read-Utf8 'QUICK_START.md'
if ($quickStartText -like '*doctor.ps1*' -and $quickStartText -like '*summary.ps1*' -and $quickStartText -like '*startup-check.ps1*' -and $quickStartText -like '*skill-sync-check.ps1*' -and $quickStartText -like '*memory-mode.ps1*' -and $quickStartText -like '*memory-health.ps1*') { Mark-Ok 'QUICK_START command coverage' } else { Mark-Fail 'QUICK_START command coverage missing' }
if (($quickStartText -like '*direct Git root*' -or $quickStartText -like '*direct Git*') -and $quickStartText -like '*There is no share-package*') { Mark-Ok 'QUICK_START direct Git source docs' } else { Mark-Fail 'QUICK_START direct Git source docs missing' }
if (Test-ContainsAll $quickStartText @('scripts\install-ui.vbs','scripts\install.bat console','single','active memory root','check-install-ui-paths.ps1','H7 `brain_turn`','does not install P7/Hook')) { Mark-Ok 'QUICK_START H7 installer and control-center docs' } else { Mark-Fail 'QUICK_START H7 installer and control-center docs missing' }
if ($quickStartText -like '*team-dispatch-check.ps1*' -and $quickStartText -like '*Commander*') { Mark-Ok 'QUICK_START Commander team docs' } else { Mark-Fail 'QUICK_START Commander team docs missing' }
if ($quickStartText -like '*Hybrid Recall*' -and $quickStartText -like '*memory-eval.ps1*' -and $quickStartText -like '*last-memory-eval.json*' -and $quickStartText -like '*AdrOnly*') { Mark-Ok 'QUICK_START hybrid ADR eval docs' } else { Mark-Fail 'QUICK_START hybrid ADR eval docs missing' }

$commandsText = Read-Utf8 'COMMANDS.md'
if ($commandsText -like '*script-tiers.ps1*' -and $commandsText -like '*T0*' -and $commandsText -like '*T3*') { Mark-Ok 'COMMANDS tier coverage' } else { Mark-Fail 'COMMANDS tier coverage missing' }
if ($commandsText -like '*cleanup-install-backups.ps1*' -and $commandsText -like '*cleanup-install-backups.ps1 -Apply*') { Mark-Ok 'COMMANDS install backup cleanup coverage' } else { Mark-Fail 'COMMANDS install backup cleanup coverage missing' }
if ($commandsText -like '*install-ui.ps1 -SmokeTest*' -and $commandsText -like '*install-ui.vbs*' -and $commandsText -like '*brain.bat*' -and $commandsText -like '*install.bat console*' -and $commandsText -like '*install-backup-*' -and $commandsText -like '*check-install-ui-paths.ps1*') { Mark-Ok 'COMMANDS skill injector UI coverage' } else { Mark-Fail 'COMMANDS skill injector UI coverage missing' }
if ($commandsText -like '*memory-eval.ps1 -Json*' -and $commandsText -like '*memory-eval-report.ps1*' -and $commandsText -like '*write-decision.ps1 -Adr*' -and $commandsText -like '*decision-search.ps1 -AdrOnly*') { Mark-Ok 'COMMANDS hybrid ADR eval coverage' } else { Mark-Fail 'COMMANDS hybrid ADR eval coverage missing' }
if ($commandsText -like '*team-dispatch-check.ps1 -Json*' -and $commandsText -like '*team-task-new.ps1*' -and $commandsText -like '*team-task-decision.ps1*' -and $commandsText -like '*team-task-status.ps1*' -and $commandsText -like '*team-task-review-gate.ps1*' -and $commandsText -like '*team-memory-retrieval.ps1*' -and $commandsText -like '*roadmap-manager.ps1*' -and $commandsText -like '*memory-regression-checker.ps1*' -and $commandsText -like '*task-state-reporter.ps1*' -and $commandsText -like '*privacy-sentinel.ps1*' -and $commandsText -like '*completion-guard.ps1*' -and $commandsText -like '*super-brain-dashboard.ps1*' -and $commandsText -like '*auto-continuation.ps1*' -and $commandsText -like '*status-snapshot-writer.ps1*' -and $commandsText -like '*privacy-hit-locator.ps1*' -and $commandsText -like '*memory-quality-fixer.ps1*' -and $commandsText -like '*optimize-advisor.ps1*' -and $commandsText -like '*lesson-replay.ps1*') { Mark-Ok 'COMMANDS Commander team coverage' } else { Mark-Fail 'COMMANDS Commander team coverage missing' }

$migrateMemoryText = Read-Utf8 'scripts\migrate-memory-layout.ps1'
if (Test-ContainsAll $migrateMemoryText @("ValidateSet('Plan','Stage','Import','Verify','Cutover','RollbackAdapter','Status')",'migration-plan','migration-stage','migration-import','migration-verify','migration-cutover','migration-rollback-adapter','expectedPlanFingerprint','expectedManifestHash','MIGRATION_APPLY_REQUIRED','MIGRATION_CLEANUP_PREVIEW_ONLY')) { Mark-Ok 'hash-bound staged memory migration control' } else { Mark-Fail 'hash-bound staged memory migration control missing' }

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
if (Test-ContainsAll $taskRegisterText @('TASK_REGISTER_TERMINAL_STATUS_REQUIRES_COMPLETION_TRANSACTION','TaskStateStore CompleteTask','exit 1')) { Mark-Ok 'task register terminal lifecycle hard gate' } else { Mark-Fail 'task register terminal lifecycle hard gate missing' }
$taskStateStoreText = Read-Utf8 'scripts\task-state-store.ps1'
$commonText = Read-Utf8 'scripts\common.ps1'
$currentTaskContextText = Read-Utf8 'scripts\current-task-context.ps1'
if (Test-ContainsAll $taskStateStoreText @('super-brain.task-state-event.v2','TASK_STATE_CAS_MISMATCH','Build-ProjectionsFromEvents','Commit-Entity','Complete-TaskState','TASK_STATE_COMPLETION_TRANSACTION_REQUIRED','phase=''prepared''','phase=''committed''','Reconcile-Store','Compact-Store','incomplete_transaction','leaseUntil','Different task IDs remain separate','merged = $false','Import-CurrentState')) { Mark-Ok 'task state store WAL CAS replay reconcile compact contract' } else { Mark-Fail 'task state store WAL CAS replay reconcile compact contract missing' }
if (Test-ContainsAll $taskStateStoreText @('super-brain.terminal-plan-seal.v1','terminal-plan-seals','sourceContractHash','terminalPlanSealPath','terminalPlanSealHash')) { Mark-Ok 'task completion terminal plan seal before active-state removal' } else { Mark-Fail 'task completion terminal plan seal contract missing' }
if ((Test-ContainsAll $commonText @('Get-SuperBrainSourceTreeBinding','git-worktree-v1','portable-content-tree-v1','New-SuperBrainEvidenceBinding','Test-SuperBrainEvidenceBinding')) -and (Test-ContainsAll $taskStateStoreText @('TASK_STATE_COMPLETION_VERIFICATION_HISTORICAL','evidenceBinding','completion_artifact_changed_after_prepare'))) { Mark-Ok 'completion evidence version binding and recovery guard' } else { Mark-Fail 'completion evidence version binding and recovery guard missing' }
if ((Test-ContainsAll $taskStateStoreText @('super-brain.task-completion-receipt.v1','task_completion_receipt','TASK_STATE_COMPLETION_CALLER_SESSION_MISMATCH','receiptRequired')) -and (Test-ContainsAll $commonText @('callerSessionKey = $resolvedCallerSessionKey','CallerSessionKey=$resolvedCallerSessionKey')) -and (Test-ContainsAll $checkpointWriterText @('CallerSessionKey','completionReceiptPath','completionReceiptHash')) -and (Test-ContainsAll (Read-Utf8 'scripts\task-verification.ps1') @('-CallerSessionKey (Get-SuperBrainHostSessionKey)','completionTransactionId'))) { Mark-Ok 'completion receipt and caller-session propagation chain' } else { Mark-Fail 'completion receipt or caller-session propagation chain missing' }
if ((Test-ContainsAll $checkpointWriterText @('Commit-SuperBrainTaskState','checkpoint-writer.ps1:Start','checkpoint-writer.ps1:complete','checkpoint-writer.ps1:task-card','Sync-SuperBrainTaskState','checkpoint-writer.ps1:legacy-import')) -and (Test-ContainsAll $currentTaskContextText @('Commit-SuperBrainTaskState','current-task-context.ps1:clear','Sync-SuperBrainTaskState','current-task-context.ps1:legacy-import')) -and $taskRegisterText.Contains('Commit-SuperBrainTaskState') -and -not $taskRegisterText.Contains('Sync-SuperBrainTaskState')) { Mark-Ok 'task state writer commit integration with bounded legacy import' } else { Mark-Fail 'task state writer commit integration with bounded legacy import missing' }
if (Test-ContainsAll $currentTaskContextText @('bindingState','bindingReason','authorizationState','locator_only_non_authorizing','taskStateRevision','contractRevision','planFingerprint','ownerSessionKey','lifecycleStatus','compatibilityEpoch','contractFileName','targetHash','locator_only')) { Mark-Ok 'current task context exact contract and lifecycle binding' } else { Mark-Fail 'current task context exact contract and lifecycle binding missing' }
$turnRuntimeText = Read-Utf8 'runtime\turn_runtime.py'
$turnCloseDispatcherText = Read-Utf8 'runtime\turn_close_dispatcher.py'
$brainMcpText = Read-Utf8 'runtime\brain_mcp.py'
$hostContinuationBridgeText = Read-Utf8 'runtime\host_continuation_bridge.py'
$dispatcherText = Read-Utf8 'runtime\codex_prompt_hook_dispatcher.py'
$hooklessRetirementText = Read-Utf8 'scripts\retire-codex-super-brain-hooks.ps1'
if ((Test-ContainsAll $turnRuntimeText @('def open_turn','def checkpoint_turn','def close_turn','def read_evidence','hookless_turn_runtime','visible_progress_assertion','recovery_event','recoveryPresentation','H7_RECOVERY_PRESENTATION_CURRENT','H7_RECOVERY_PRESENTATION_SUPPRESSED','H7_VISIBLE_TAIL_ASSERTION_REQUIRED','H7_USER_ATTESTED_VISIBLE_PROGRESS_INTENT_REQUIRED','H7_PARENT_RETURN_STATE_CARD_CURRENT','observed_display_only','rawPromptStored')) -and (Test-ContainsAll $turnCloseDispatcherText @('latest assistant progress','progress_checkpoint','ResumeParent')) -and (Test-ContainsAll $brainMcpText @('brain_turn','brain_recall','brain_status','brain_recent','visible_progress_assertion','recovery_event','pause_resume'))) { Mark-Ok 'H7 governed turn lifecycle, visible-tail assertion, display-only continuity, recovery presentation, and MCP surface' } else { Mark-Fail 'H7 governed turn lifecycle, visible-tail assertion, display-only continuity, recovery presentation, or MCP surface missing' }
if ((Test-ContainsAll $turnRuntimeText @('super-brain.visible-tail-observation.v4','H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED','H7_SESSION_REBOUND_REPUBLISH_REQUIRED','h7ReceiptHash')) -and (Test-ContainsAll $brainMcpText @('super-brain.visible-tail-observation.v4','h7_receipt_hash','envelope_version')) -and (Test-ContainsAll $hostContinuationBridgeText @('HOST_VISIBLE_TAIL_READ_TIMEOUT_SECONDS = 5.0','HOST_VISIBLE_TAIL_READ_TIMEOUT','attempts = (1, 2)','HOST_VISIBLE_TAIL_MAX_NONEMPTY_LINES = 3'))) { Mark-Ok 'H7 v4 receipt-bound continuation and bounded Host bridge' } else { Mark-Fail 'H7 v4 receipt-bound continuation or bounded Host bridge missing' }
$brainContextProgressText = Read-Utf8 'runtime\brain_context.py'
if (
  (Test-ContainsAll $turnRuntimeText @('_project_progress_status','projectProgressHash','H7_PROJECT_PROGRESS_WITHHELD','project_progress_proof')) -and
  (Test-ContainsAll $turnCloseDispatcherText @('_normalize_project_progress_proof','ProjectProgressProofBase64','ProjectRoot')) -and
  (Test-ContainsAll $brainContextProgressText @('validate_project_progress_proof','project_progress_root_hash','visible_progress_scope_binding_hash','scopeBindingHash','H7_PROJECT_PROGRESS_EVIDENCE_HASH_MISMATCH','candidate.relative_to(root_value)'))
) { Mark-Ok 'H7 project progress truth proof and live evidence recheck' } else { Mark-Fail 'H7 project progress truth proof or live evidence recheck missing' }
if (Test-ContainsAll $dispatcherText @('Retired P7 dispatcher compatibility shim','"state": "retired"','H7 brain_turn','UserPromptSubmit')) { Mark-Ok 'retired P7 dispatcher is fail-open compatibility only' } else { Mark-Fail 'retired P7 dispatcher compatibility contract missing' }
if (Test-ContainsAll $hooklessRetirementText @('super-brain.hookless-retirement.v1','Remove-SuperBrainHookEntries','otherHooksPreserved','-Apply after H7 runtime verification')) { Mark-Ok 'hookless retirement is explicit and report-first' } else { Mark-Fail 'hookless retirement guard missing' }
$freshCodexSkillText = Read-Utf8 'super-memory-brain\SKILL.md'
if ($freshCodexSkillText -like '*Fresh Codex Or Missing Conversation History*' -and $freshCodexSkillText -like '*brain_cli.py turn-runtime*' -and $freshCodexSkillText -like '*H7_RUNTIME_UNAVAILABLE*' -and $freshCodexSkillText -like '*Missing chat history is never evidence*' -and $freshCodexSkillText -like '*read_thread*' -and $freshCodexSkillText -like '*visible_progress_assertion*' -and $freshCodexSkillText -like '*H7_VISIBLE_TAIL_EXPLICIT_RECONCILIATION_REQUIRED*' -and $freshCodexSkillText -notlike '*use visible/live evidence for a direct answer*') { Mark-Ok 'fresh Codex H7 equivalent-transport and visible-tail boundary' } else { Mark-Fail 'fresh Codex H7 equivalent-transport or visible-tail boundary missing' }
$taskIndexText = Read-Utf8 'scripts\task-index.ps1'
if ($taskIndexText.Contains('[switch]$Table') -and $taskIndexText.Contains('[string]$Agent') -and $taskIndexText.Contains('[string]$SessionId') -and $taskIndexText.Contains('sessionName') -and $taskIndexText.Contains('agentId') -and $taskIndexText.Contains('identityKey') -and $taskIndexText.Contains('未知，不等于没有任务') -and $taskIndexText.Contains('# | 来源 | 会话 / 状态 | 进度')) { Mark-Ok 'task-index shared identity compact table' } else { Mark-Fail 'task-index shared identity compact table missing' }
$taskLifecycleAuditText = Read-Utf8 'scripts\task-lifecycle-audit.ps1'
if ($taskLifecycleAuditText.Contains('super-brain.task-lifecycle-audit.v2') -and $taskLifecycleAuditText.Contains('diagnosticCards') -and $taskLifecycleAuditText.Contains('zeroPendingActiveCards') -and $taskLifecycleAuditText.Contains('staleUnboundActiveCards') -and $taskLifecycleAuditText.Contains('quarantinedProjections') -and $taskLifecycleAuditText.Contains('automaticContinuationSafe')) { Mark-Ok 'task lifecycle audit support' } else { Mark-Fail 'task lifecycle audit support missing' }
if ($taskIndexText.Contains('[switch]$IncludeDiagnostic') -and $taskIndexText.Contains('Test-DiagnosticTaskId')) { Mark-Ok 'task index diagnostic state exclusion' } else { Mark-Fail 'task index diagnostic state exclusion missing' }
$skillText = Read-Utf8 'super-memory-brain\SKILL.md'
$runtimeWakeText = Read-Utf8 'scripts\internal\runtime-wake-core.ps1'
$runtimeControlPlaneText = Read-Utf8 'references\runtime-control-plane.md'
if (Test-ContainsAll ($runtimeWakeText + $runtimeControlPlaneText) @('super-brain.execution-hot-index.v1','ownerSessionKey','workspaceKey','wakeEligible','Runtime Control Plane')) { Mark-Ok 'runtime compact task identity and wake eligibility hot index' } else { Mark-Fail 'runtime compact task identity or wake eligibility hot index missing' }

$retireHooksText = Read-Utf8 'scripts\retire-codex-super-brain-hooks.ps1'
if (Test-ContainsAll $retireHooksText @('super-brain.hookless-retirement.v1','otherHooksPreserved','-Apply after H7 runtime verification')) { Mark-Ok 'H7 hook retirement report and preservation guard' } else { Mark-Fail 'H7 hook retirement report and preservation guard missing' }

$skillText = Read-Utf8 'super-memory-brain\SKILL.md'
$entryContracts = @(
  [pscustomobject]@{ name='entry skill explicit wake router'; markers=@('Wake And Route Triggers','Load this adapter for:','bare_wake','Do not load it for greetings') },
  [pscustomobject]@{ name='entry skill memory mode governance'; markers=@('Memory And Privacy','memory:auto','memory:force','memory:off','confidence gates') },
  [pscustomobject]@{ name='entry skill G1 visibility contract'; markers=@('Visible G1 invariant','first user-facing update','final summary','Intermediate updates do not','line is exactly `G1`','Never show','`G1` when Super Brain did not participate') },
  [pscustomobject]@{ name='entry skill runtime continuity boundary'; markers=@('lightweight host adapter','Runtime Handoff','brain_turn','execution-contract.ps1','do not reproduce this with','skill prose') },
  [pscustomobject]@{ name='entry skill privacy and compact memory contract'; markers=@('Memory And Privacy','Never store secrets','Durable writes are limited to compact verified') },
  [pscustomobject]@{ name='entry skill workflow separation'; markers=@('single_agent_subagent_workflow','Delegation And Compatibility','legacy/manual-only compatibility') },
  [pscustomobject]@{ name='entry skill maintenance safety'; markers=@('Maintenance And Quality','Prefer report or','Ask before destructive cleanup') },
  [pscustomobject]@{ name='entry skill anti-degradation and output contract'; markers=@('GPT-5 Anti-Degradation Guard','verify before closeout','Output Contracts','State:','Evidence:','Next:') },
  [pscustomobject]@{ name='entry skill root marker support'; markers=@('package-root.txt','memory-root.txt') }
)
foreach ($contract in $entryContracts) {
  if (Test-ContainsAll $skillText @($contract.markers)) { Mark-Ok $contract.name } else { Mark-Fail "$($contract.name) missing" }
}
$adapterQualityMarkers = @('does not own task trees','references/runtime-control-plane.md','Adapter prose is a soft conciseness optimization','never delete operating boundaries to satisfy a fixed byte ceiling')
if (Test-ContainsAll $skillText $adapterQualityMarkers) { Mark-Ok 'entry skill remains a bounded complete runtime adapter' } else { Mark-Fail 'entry skill runtime adapter boundary or conciseness quality failed' }

$orcText = Read-Utf8 'modules\skill-orchestrator\SKILL.md'
$orcContracts = @(
  [pscustomobject]@{ name='ORC complexity and direct-answer gate'; markers=@('ORC is a complexity gate, not the default answer path','When unsure, start direct and escalate only if complexity becomes real') },
  [pscustomobject]@{ name='ORC current-evidence and memory governance'; markers=@('Current user instruction, visible context, live files, and verified tool output','Never store secrets','compact stable facts') },
  [pscustomobject]@{ name='ORC verification and rollback contract'; markers=@('verify before final claims','rollback awareness','changed files, verification, gaps') },
  [pscustomobject]@{ name='ORC team and bridge separation'; markers=@('Keep team/subagent routing dormant by default','Code-capable','subagents require explicit authorization','Agent Bridge is separate from delegation') },
  [pscustomobject]@{ name='ORC structured routing sources'; markers=@('route-map.json','capabilities.json','references/index.md') }
)
foreach ($contract in $orcContracts) {
  if (Test-ContainsAll $orcText @($contract.markers)) { Mark-Ok $contract.name } else { Mark-Fail "$($contract.name) missing" }
}

$canonicalGitIgnorePath = Join-Path (Get-SuperBrainRuntimeWorkspaceRoot $Root) '.gitignore'
$canonicalGitIgnoreRules = @('private-state/**','private-archive/**','memory/**','!memory/','runtime-layout.json','*.lnk')
if (Test-Path -LiteralPath $canonicalGitIgnorePath) {
  $canonicalGitIgnore = Get-Content -LiteralPath $canonicalGitIgnorePath -Raw -Encoding UTF8
  $missingGitIgnoreRules = @($canonicalGitIgnoreRules | Where-Object { $canonicalGitIgnore -notmatch [regex]::Escape($_) })
  if ($missingGitIgnoreRules.Count -eq 0) { Mark-Ok 'canonical direct Git privacy guardrails' } else { Mark-Fail ('canonical direct Git privacy rules missing '+($missingGitIgnoreRules -join ',')) }
} else { Mark-Fail 'canonical direct Git privacy guardrails missing' }

try {
  $routeMap = Read-Utf8 'route-map.json' | ConvertFrom-Json
  $requiredRoutes = @('normal_chat','browser_automation','bare_wake','current_task_status','system_status','current_session_continue','historical_recovery','agent_bridge_channel','privacy_memory_gate','memory_write_candidate','workflow_preference_recall','direct_answer','orc_complex_routing','maintenance_hot_refresh','single_agent_subagent_workflow')
  $actualRoutes = @($routeMap.routes | ForEach-Object { [string]$_.route })
  $missingRoutes = @($requiredRoutes | Where-Object { $actualRoutes -notcontains $_ })
  if ($missingRoutes.Count -eq 0) { Mark-Ok 'structured route map coverage' } else { Mark-Fail ('structured route map missing ' + ($missingRoutes -join ',')) }
} catch { Mark-Fail "structured route map parse $($_.Exception.Message)" }

$runtimeLayoutPath = Join-Path $Root 'runtime-layout.json'
if (Test-Path -LiteralPath $runtimeLayoutPath) {
  try {
    $runtimeLayout = Get-Content -LiteralPath $runtimeLayoutPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $workspaceRootFull = Get-SuperBrainRuntimeWorkspaceRoot $Root
    $sourceRootFull = if ([string]::IsNullOrWhiteSpace([string]$runtimeLayout.sourceRoot)) { $workspaceRootFull } else { Resolve-SuperBrainRuntimeLayoutPath $Root ([string]$runtimeLayout.sourceRoot) }
    $runtimeRootFull = Resolve-SuperBrainRuntimeLayoutPath $Root ([string]$runtimeLayout.runtimeRoot)
    $stateRootFull = Resolve-SuperBrainRuntimeLayoutPath $Root ([string]$runtimeLayout.stateRoot)
    $archiveRootFull = Resolve-SuperBrainRuntimeLayoutPath $Root ([string]$runtimeLayout.archiveRoot)
    $sourceRootOk = (Test-Path -LiteralPath $sourceRootFull) -and (Test-SuperBrainSamePath $sourceRootFull $workspaceRootFull)
    $runtimeRootOk = (Test-Path -LiteralPath $runtimeRootFull) -and (Test-SuperBrainSamePath $runtimeRootFull $Root)
    $stateRootOk = (Test-Path -LiteralPath $stateRootFull) -and (Test-SuperBrainRuntimeLayoutWorkspacePath $sourceRootFull $stateRootFull) -and -not (Test-SuperBrainSamePath $stateRootFull $runtimeRootFull)
    $archiveRootOk = (Test-Path -LiteralPath $archiveRootFull) -and (Test-SuperBrainRuntimeLayoutWorkspacePath $sourceRootFull $archiveRootFull) -and -not (Test-SuperBrainSamePath $archiveRootFull $runtimeRootFull)
    $memoryLink = Get-Item -LiteralPath (Join-Path $Root 'memory') -Force -ErrorAction Stop
    $memoryTargets = @($memoryLink.Target | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $memoryTargetOk = $false
    foreach ($memoryTarget in $memoryTargets) {
      $candidate = if ([IO.Path]::IsPathRooted($memoryTarget)) { $memoryTarget } else { Join-Path (Split-Path -Parent $memoryLink.FullName) $memoryTarget }
      if (Test-SuperBrainSamePath $candidate $stateRootFull) { $memoryTargetOk = $true; break }
    }
    $memoryLinkOk = [bool]($memoryLink.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $memoryTargetOk
    if ([string]$runtimeLayout.schema -eq 'super-brain.runtime-layout.v1' -and $sourceRootOk -and $runtimeRootOk -and $stateRootOk -and $archiveRootOk -and $memoryLinkOk) { Mark-Ok 'portable four-layer runtime layout' } else { Mark-Fail 'portable four-layer runtime layout invalid' }
  } catch { Mark-Fail "four-layer runtime layout parse $($_.Exception.Message)" }
} else { Mark-Ok 'four-layer runtime layout optional for portable source' }

if (Test-Path -LiteralPath $runtimeLayoutPath) {
  $runtimeBackupResidue = @()
  foreach ($scanRoot in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('memory','private-state','private-archive','.git') })) {
    $runtimeBackupResidue += @(Get-ChildItem -LiteralPath $scanRoot.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.bak-' })
  }
  if ($runtimeBackupResidue.Count -eq 0) { Mark-Ok 'runtime backup residue absent' } else { Mark-Fail "runtime backup residue count=$($runtimeBackupResidue.Count)" }

  $invalidScriptInstallRoots = @('-MemoryMode','Prompt','Shared','SplitMemory') | ForEach-Object { Join-Path (Join-Path $Root 'scripts') $_ } | Where-Object { Test-Path -LiteralPath $_ }
  if (@($invalidScriptInstallRoots).Count -eq 0) { Mark-Ok 'invalid script install roots absent' } else { Mark-Fail "invalid script install root count=$(@($invalidScriptInstallRoots).Count)" }
}

$routeRegressionJsonText = & (Join-Path $PSScriptRoot 'route-regression.ps1') -Json -Strict
$routeRegressionExitCode = $LASTEXITCODE
try {
  $routeRegressionJson = $routeRegressionJsonText | ConvertFrom-Json
  if ($routeRegressionExitCode -eq 0 -and $routeRegressionJson.ok -eq $true -and [int]$routeRegressionJson.failed -eq 0 -and [int]$routeRegressionJson.total -ge 42) { Mark-Ok 'strict route regression' } else { Mark-Fail 'strict route regression failed' }
} catch { Mark-Fail "strict route regression parse $($_.Exception.Message)" }

$startupCheckText = Read-Utf8 'scripts\startup-check.ps1'
if (Test-ContainsAll $startupCheckText @('TURN_RUNTIME_HOOKLESS','H7_RETIRED_TRANSPORT_GUARD','same_h7_cli','requiredForCore','hookless_turn_runtime')) { Mark-Ok 'H7 hookless startup state check' } else { Mark-Fail 'H7 hookless startup state check missing' }
if (Test-ContainsAll $startupCheckText @('superBrainHookRegistration','H7_RETIRED_TRANSPORT_GUARD_CURRENT','H7_SUPER_BRAIN_HOOK_REGISTRATION_CONFLICT','requiredForCore')) { Mark-Ok 'retired Super Brain hook registration guard' } else { Mark-Fail 'retired Super Brain hook registration guard missing' }
if ($startupCheckText -like '*ZCode host is not installed*' -and $startupCheckText -like '*Codex host is not installed yet*') { Mark-Ok 'optional host startup boundary' } else { Mark-Fail 'optional host startup boundary missing' }
$stageReceiptSkillText = Read-Utf8 'super-memory-brain\SKILL.md'
$stageReceiptRulesText = Read-Utf8 'super-brain-rules.json'
if ((Test-ContainsAll $stageReceiptSkillText @('Stage User Receipt','before beginning the next phase','Never','silently advance a phase','explicit user-visible receipt')) -and (Test-ContainsAll $stageReceiptRulesText @('SB-STAGE-VERIFY-001','verify_each_stage_before_next_stage','stage_gate_replay'))) { Mark-Ok 'explicit user-visible stage receipt rule' } else { Mark-Fail 'explicit user-visible stage receipt rule missing' }

$statusText = Read-Utf8 'scripts\status.ps1'
if (Test-ContainsAll $statusText @('startup-check.ps1','startupCoreAvailable','startupStrictOk','turnRuntime','retiredTransportGuard','requiredForCore')) { Mark-Ok 'status canonical startup axis projection' } else { Mark-Fail 'status canonical startup axis projection missing' }
if ($statusText -like '*exit 0*') { Mark-Ok 'status explicit success exit' } else { Mark-Fail 'status explicit success exit missing' }
if ($statusText -like '*session-binding.json*' -and $statusText -like '*sessionBinding*' -and $statusText -like '*packageVersionMatch*' -and $statusText -like '*memoryRootMatch*') { Mark-Ok 'status session binding visibility' } else { Mark-Fail 'status session binding visibility missing' }

$compactApplyText = Read-Utf8 'scripts\compact-apply.ps1'
if ($compactApplyText.Contains('[switch]$Force') -and $compactApplyText.Contains("status='confirmation_required'") -and $compactApplyText.Contains('Use -Force only after reviewing compact-report')) { Mark-Ok 'compact apply confirmation guard' } else { Mark-Fail 'compact apply confirmation guard missing' }

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

$userAdaptationText = Read-Utf8 'scripts\user-adaptation.ps1'
$userAdaptationCoreText = Read-Utf8 'scripts\internal\user-adaptation-core.ps1'
if ($userAdaptationText -like '*Observe*' -and $userAdaptationText -like '*Synthesize*' -and $userAdaptationText -like '*Packet*' -and $userAdaptationText -like '*ConfirmForget*' -and $userAdaptationText -like '*rawPromptStored*' -and $userAdaptationCoreText -like '*minimumDistinctTasks*' -and $userAdaptationCoreText -like '*minimumDistinctContexts*' -and $userAdaptationCoreText -like '*maxDirectives*' -and $userAdaptationCoreText -like '*maxTokens*' -and $userAdaptationCoreText -like '*tombstones*') { Mark-Ok 'governed user adaptation support' } else { Mark-Fail 'governed user adaptation support missing' }

$sessionBindingText = Read-Utf8 'scripts\session-binding.ps1'
if ($sessionBindingText -like '*session-binding.json*' -and $sessionBindingText -like '*bindingId*' -and $sessionBindingText -like '*expiresAt*' -and $sessionBindingText -like '*TtlMinutes*' -and $sessionBindingText -like '*MemoryMode*' -and $sessionBindingText -like '*memory:off*' -and $sessionBindingText -like '*Write-JsonUtf8NoBom*' -and $sessionBindingText -like '*Get-SuperBrainActiveMemoryRoot*' -and $sessionBindingText -like '*noRawChat*' -and $sessionBindingText -like '*currentUserInstructionWins*') { Mark-Ok 'session binding script schema and guards' } else { Mark-Fail 'session binding script schema or guards missing' }

$sessionRestoreText = Read-Utf8 'scripts\session-restore.ps1'
if ($sessionRestoreText -like '*last-session-restore.json*' -and $sessionRestoreText -like '*tokenBudget*' -and $sessionRestoreText -like '*evidenceCards*' -and $sessionRestoreText -like '*Get-SuperBrainRelevantCheckpoint*' -and $sessionRestoreText -like '*checkpointSelection*' -and $sessionRestoreText -like '*experience-index.md*' -and $sessionRestoreText -like '*recallTriggered*' -and $sessionRestoreText -like '*profileCard*' -and $sessionRestoreText -like '*profile-card.ps1*' -and $sessionRestoreText -like '*BindSession*' -and $sessionRestoreText -like '*session-binding.ps1*' -and $sessionRestoreText -like '*sessionBinding*' -and $sessionRestoreText -like '*TtlMinutes*' -and $sessionRestoreText -like '*Get-RestoreContinuationReceiptCompatibility*' -and $sessionRestoreText -like '*currentUserInstructionAuthority*' -and $sessionRestoreText -like '*latestAssistantProgressReceipt*') { Mark-Ok 'session restore lightweight protocol and scoped assistant-progress receipt support' } else { Mark-Fail 'session restore lightweight protocol or scoped assistant-progress receipt support missing' }

$statusRecoveryText = Read-Utf8 'references\status-recovery.md'
if ($statusRecoveryText -like '*time-latest real assistant reply*' -and $statusRecoveryText -like '*current_visible_assistant*' -and $statusRecoveryText -like '*task instance*' -and $statusRecoveryText -like '*current ordered action*') { Mark-Ok 'latest assistant progress continuation invariant' } else { Mark-Fail 'latest assistant progress continuation invariant missing' }

$acceptedPreflightText = Read-Utf8 'scripts\accepted-constraints-preflight.ps1'
if ($acceptedPreflightText -like '*last-accepted-constraints-preflight.json*' -and $acceptedPreflightText -like '*decision-search.ps1*' -and $acceptedPreflightText -like '*recall-search.ps1*' -and $acceptedPreflightText -like '*active-checkpoint.json*' -and $acceptedPreflightText -like '*session-binding.json*' -and $acceptedPreflightText -like '*mustPreserve*' -and $acceptedPreflightText -like '*mustNotViolate*' -and $acceptedPreflightText -like '*guardHash*' -and $acceptedPreflightText -like '*noTail*') { Mark-Ok 'accepted constraints preflight support' } else { Mark-Fail 'accepted constraints preflight support missing' }

$projectContinuityText = Read-Utf8 'scripts\project-continuity.ps1'
if ($projectContinuityText -like '*PROJECT_CONTINUITY_LEGACY_WRITER_RETIRED*' -and $projectContinuityText -like '*retired_read_only*' -and $projectContinuityText -like '*execution-contract.ps1 + TaskStateStore*' -and $projectContinuityText -notlike '*Write-JsonUtf8NoBom*') { Mark-Ok 'project continuity legacy writer retirement support' } else { Mark-Fail 'project continuity legacy writer retirement support missing' }

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
$executionContractText = Read-Utf8 'scripts\execution-contract.ps1'
if ($executionContractText -like '*super-brain.execution-contract.v1*' -and $executionContractText -like '*visible_conversation*' -and $executionContractText -like '*needsReconciliation*' -and $executionContractText -like '*EXECUTION_CONTRACT_WORK_INVALIDATED*' -and $executionContractText -like '*ResumeParent*' -and $executionContractText -like '*returnStack*' -and $executionContractText -like '*workLineStatus*' -and $executionContractText -like '*intentContractRequired*' -and $executionContractText -like '*intentResolutionReceipt*' -and $executionContractText -like '*rawTranscriptStored*') { Mark-Ok 'latest execution contract support' } else { Mark-Fail 'latest execution contract support missing' }
 $intentResolutionText = Read-Utf8 'scripts\internal\intent-resolution.ps1'
if (Test-ContainsAll $intentResolutionText @('super-brain.intent-contract.v2','super-brain.intent-resolution-receipt.v2','super-brain.intent-fulfillment.v1','taskInstanceId','latestInstructionHash','intentContractFingerprint','payloadHash','EXECUTION_CONTRACT_INTENT_RECEIPT_STALE','ConvertTo-IntentResolutionPublicCode','TASK_INTENT_FULFILLMENT_CURRENT','rawTranscriptStored')) { Mark-Ok 'task-scoped intent resolution receipt and fulfillment support' } else { Mark-Fail 'task-scoped intent resolution receipt or fulfillment support missing' }
if ((Test-ContainsAll $executionContractText @('ValidateIntentReceipt','EXECUTION_CONTRACT_INTENT_RECEIPT_CURRENT')) -and (Test-ContainsAll $taskStateStoreText @('Assert-CompletionIntent','TASK_STATE_COMPLETION_INTENT_FULFILLMENT_REQUIRED','intentCompletion')) -and (Test-ContainsAll (Read-Utf8 'scripts\task-verification.ps1') @('IntentFulfillmentJson','New-SuperBrainIntentFulfillment','intentFulfillment')) -and (Test-ContainsAll (Read-Utf8 'scripts\completion-guard.ps1') @('Get-TaskIntentFulfillmentStatus','intent-fulfillment','intent_fulfillment_bound_to_terminal_evidence'))) { Mark-Ok 'intent fulfillment completion authority chain' } else { Mark-Fail 'intent fulfillment completion authority chain missing' }
if (Test-ContainsAll $executionContractText @('EXECUTION_CONTRACT_REVISION_MISMATCH','EXECUTION_CONTRACT_PLAN_FINGERPRINT_MISMATCH','transitionReceipts','payloadHash','New-TransitionReplayResult','TransitionReceiptMaxCount')) { Mark-Ok 'execution contract Set CAS and structural idempotency receipts' } else { Mark-Fail 'execution contract Set CAS or structural idempotency receipts missing' }
if (Test-ContainsAll ($executionContractText + $runtimeWakeText) @('ObserveUser','needsReconciliation','latestUserInstruction','Test-SuperBrainRuntimeWakeContextReply','Test-SuperBrainRuntimeWakeBareContinuation','structuralGuardsRequired','RequireStructuralGuards','EXECUTION_CONTRACT_STRUCTURAL_GUARD_REQUIRED')) { Mark-Ok 'execution contract pending-instruction preservation and mandatory structural guard upgrade' } else { Mark-Fail 'execution contract pending-instruction preservation or structural guard upgrade missing' }
if ($runtimeWakeText -like '*super-brain.execution-hot-index.v1*' -and $runtimeWakeText -like '*Get-SuperBrainRuntimeWakeDecision*' -and $runtimeWakeText -like '*modelCalled=$false*' -and $runtimeWakeText -like '*networkCalled=$false*' -and $runtimeWakeText -like '*deepRecallCalled=$false*' -and $runtimeWakeText -like '*memoryBodyLoaded=$false*' -and ($executionContractText -like '*Sync-SuperBrainRuntimeWakeEntry*' -or $executionContractText -like '*Write-SuperBrainRuntimeWakeEntry*')) { Mark-Ok 'system runtime automatic wake and hot-path isolation' } else { Mark-Fail 'system runtime automatic wake or hot-path isolation missing' }
if ($autoContinuationText -like '*active-checkpoint.json*' -and $autoContinuationText -like '*execution-contract.ps1*' -and $autoContinuationText -like '*visible_conversation*' -and $autoContinuationText -like '*parent_return*' -and $autoContinuationText -like '*checkpoint_state_only*' -and $autoContinuationText -like '*mutationAuthorized*' -and $autoContinuationText -like '*checkpointStatus*') { Mark-Ok 'auto continuation contract and checkpoint support' } else { Mark-Fail 'auto continuation contract and checkpoint support missing' }

$dashboardText = Read-Utf8 'scripts\super-brain-dashboard.ps1'
if ($dashboardText -like '*Get-SuperBrainRelevantCheckpoint*' -and $dashboardText -like '*checkpointSelection*' -and $dashboardText -like '*workspaceKey*' -and $dashboardText -like '*active_checkpoint_present*' -and $dashboardText -like '*activeCheckpoint*') { Mark-Ok 'dashboard workspace-scoped checkpoint support' } else { Mark-Fail 'dashboard workspace-scoped checkpoint support missing' }

$completionGuardText = Read-Utf8 'scripts\completion-guard.ps1'
if ($completionGuardText -like '*active-checkpoint*' -and $completionGuardText -like '*status=*' -and $completionGuardText -like '*none*' -and $completionGuardText -like '*last-accepted-constraints-preflight.json*' -and $completionGuardText -like '*accepted-constraints-preflight*') { Mark-Ok 'completion guard checkpoint constraint support' } else { Mark-Fail 'completion guard checkpoint constraint support missing' }
if ($completionGuardText -like '*last-runtime-drift-checkpoint.json*' -and $completionGuardText -like '*runtime-drift-checkpoint*' -and $completionGuardText -like '*unresolvedDrift*') { Mark-Ok 'completion guard runtime drift support' } else { Mark-Fail 'completion guard runtime drift support missing' }
if (Test-ContainsAll $completionGuardText @('Read-TaskStateAuthority','task-state-projection','task-state-transaction','task-state-lifecycle','runtime-drift-checkpoints','Get-SuperBrainCanonicalTaskPath')) { Mark-Ok 'completion guard canonical lifecycle authority' } else { Mark-Fail 'completion guard canonical lifecycle authority missing' }
if ($completionGuardText -like '*last-route-checkpoint.json*' -and $completionGuardText -like '*route-checkpoint*' -and $completionGuardText -like '*unresolvedRouteDrift*') { Mark-Ok 'completion guard route drift support' } else { Mark-Fail 'completion guard route drift support missing' }
if ($completionGuardText -like '*last-integration-parity-check.json*' -and $completionGuardText -like '*integration-parity-check*' -and $completionGuardText -like '*unresolvedIntegrationDrift*' -and $completionGuardText -like '*moduleVerification*' -and $completionGuardText -like '*userAcceptanceVerification*') { Mark-Ok 'completion guard integration parity support' } else { Mark-Fail 'completion guard integration parity support missing' }

$goalRouteText = Read-Utf8 'scripts\goal-route-lock.ps1'
if ($goalRouteText -like '*super-brain.goal-route-lock.v1*' -and $goalRouteText -like '*goal-route-lock.json*' -and $goalRouteText -like '*acceptedGoal*' -and $goalRouteText -like '*acceptedRoute*' -and $goalRouteText -like '*mustNotDriftTo*' -and $goalRouteText -like '*routeHash*') { Mark-Ok 'goal route lock support' } else { Mark-Fail 'goal route lock support missing' }
$routeCheckpointText = Read-Utf8 'scripts\route-checkpoint.ps1'
if ($routeCheckpointText -like '*super-brain.route-checkpoint.v1*' -and $routeCheckpointText -like '*ROUTE_DRIFT_DETECTED*' -and $routeCheckpointText -like '*unresolvedRouteDrift*' -and $routeCheckpointText -like '*goal_route_drift*' -and $routeCheckpointText -like '*scope_creep*') { Mark-Ok 'route checkpoint support' } else { Mark-Fail 'route checkpoint support missing' }
if ((Test-ContainsAll $routeCheckpointText @('bindingState','route-checkpoint-contract-v1','taskStateRevision','contractRevision','planFingerprint','ownerSessionKey','lifecycleStatus','targetHash','route_checkpoint_binding_required','Status is read-only')) -and (Test-ContainsAll $completionGuardText @('Get-RouteCheckpointBindingStatus','route-checkpoint-binding','active_task_state_revision_mismatch','active_contract_hash_mismatch','bound_to_terminal_lifecycle'))) { Mark-Ok 'route checkpoint exact lifecycle binding and stale-evidence rejection' } else { Mark-Fail 'route checkpoint exact lifecycle binding or stale-evidence rejection missing' }
$moduleSnapshotText = Read-Utf8 'scripts\verified-module-snapshot.ps1'
if ($moduleSnapshotText -like '*super-brain.verified-module-snapshot.v1*' -and $moduleSnapshotText -like '*verifiedBehavior*' -and $moduleSnapshotText -like '*entrypoint*' -and $moduleSnapshotText -like '*environment*' -and $moduleSnapshotText -like '*snapshotHash*') { Mark-Ok 'verified module snapshot support' } else { Mark-Fail 'verified module snapshot support missing' }
$integrationParityText = Read-Utf8 'scripts\integration-parity-check.ps1'
if ($integrationParityText -like '*super-brain.integration-parity-check.v1*' -and $integrationParityText -like '*INTEGRATION_DRIFT_DETECTED*' -and $integrationParityText -like '*module smoke OK*' -and $integrationParityText -like '*integration smoke OK*' -and $integrationParityText -like '*user-facing acceptance OK*' -and $integrationParityText -like '*scattered_assembly*' -and $integrationParityText -like '*module_context_changed*') { Mark-Ok 'integration parity guard support' } else { Mark-Fail 'integration parity guard support missing' }

$cognitiveEnforceText = Read-Utf8 'scripts\cognitive-enforce.ps1'
if ($cognitiveEnforceText -like '*super-brain.cognitive-enforce.v1*' -and $cognitiveEnforceText -like '*last-cognitive-enforce.json*' -and $cognitiveEnforceText -like '*AllowMissingPreflight*' -and $cognitiveEnforceText -like '*fresh query-matched cognitive preflight*' -and $cognitiveEnforceText -like '*intent-resolution-receipt*' -and $cognitiveEnforceText -like '*preflightDiagnosticOnly*' -and $cognitiveEnforceText -like '*engineering-decision-gate*') { Mark-Ok 'cognitive enforce hard gate support' } else { Mark-Fail 'cognitive enforce hard gate support missing' }

$engineeringDecisionText = Read-Utf8 'scripts\engineering-decision-gate.ps1'
if ($engineeringDecisionText -like '*super-brain.engineering-decision-gate.v1*' -and $engineeringDecisionText -like '*FACT*' -and $engineeringDecisionText -like '*INFERENCE*' -and $engineeringDecisionText -like '*UNKNOWN*' -and $engineeringDecisionText -like '*unsupported_optimal_claim*' -and $engineeringDecisionText -like '*untested_root_cause_hypothesis*' -and $engineeringDecisionText -like '*execution_step_without_contract*') { Mark-Ok 'engineering decision evidence and optimality gate support' } else { Mark-Fail 'engineering decision evidence and optimality gate support missing' }

$technologyDecisionText = Read-Utf8 'scripts\technology-decision.ps1'
$technologyReferenceText = Read-Utf8 'references\technology-decision.md'
$technologyCatalogText = Read-Utf8 'references\technology-catalog.json'
if ($technologyDecisionText -like "*ValidateSet('Questionnaire','Recommend','Catalog','Validate')*" -and $technologyDecisionText -like '*recommended_under_current_evidence*' -and $technologyDecisionText -like '*dimensionContributions*' -and $technologyDecisionText -like '*requirementContributions*' -and $technologyDecisionText -like '*volatileFactsToVerify*' -and $technologyReferenceText -like '*multiple-choice requirements*' -and $technologyCatalogText -like '*super-brain.technology-catalog.v1*') { Mark-Ok 'structured technology decision support' } else { Mark-Fail 'structured technology decision support missing' }

$runtimeDriftText = Read-Utf8 'scripts\runtime-drift-checkpoint.ps1'
if ($runtimeDriftText -like '*super-brain.runtime-drift-checkpoint.v1*' -and $runtimeDriftText -like '*DRIFT_DETECTED*' -and $runtimeDriftText -like '*unresolvedDrift*' -and $runtimeDriftText -like '*BeforeCompletion*' -and $runtimeDriftText -like '*reply_as_goal_completed*') { Mark-Ok 'runtime drift checkpoint support' } else { Mark-Fail 'runtime drift checkpoint support missing' }
if (Test-ContainsAll $runtimeDriftText @('$hasTaskScope','DRIFT_TASK_SCOPE_REQUIRED','missing_task_scope','Unscoped runtime drift writes are retired','$outPath = if ($hasTaskScope)')) { Mark-Ok 'runtime drift scoped writer guard' } else { Mark-Fail 'runtime drift scoped writer guard missing' }

$reflectionPromotionText = Read-Utf8 'scripts\reflection-promotion.ps1'
if ($reflectionPromotionText -like '*super-brain.reflection-promotion.v2*' -and $reflectionPromotionText -like '*correctionLifecycle*' -and $reflectionPromotionText -like '*defaultNoDurableWrite*' -and $reflectionPromotionText -like '*privacyCheck*' -and $reflectionPromotionText -like '*duplicateCheck*' -and $reflectionPromotionText -like '*rule_or_skill_approval_required*' -and $reflectionPromotionText -like '*skill_evolution_proposal_staged*' -and $reflectionPromotionText -like '*controlled_queue_adoption_required*' -and $reflectionPromotionText -like '*requiresControlledAdoption*' -and $reflectionPromotionText -like '*self-improvement-queue.ps1*') { Mark-Ok 'reflection promotion controlled learning support' } else { Mark-Fail 'reflection promotion controlled learning support missing' }
if ($reflectionPromotionText -like '*candidateType*' -and $reflectionPromotionText -like '*gap*' -and $reflectionPromotionText -like '*logic_breakpoint*' -and $reflectionPromotionText -like '*missing_route_lock*' -and $reflectionPromotionText -like '*integration_drift*' -and $reflectionPromotionText -like '*noDurableWriteWithoutApply*') { Mark-Ok 'reflection promotion gap and logic breakpoint candidates' } else { Mark-Fail 'reflection promotion gap and logic breakpoint candidates missing' }
if ($reflectionPromotionText -like '*Get-VerifiedOutcomeForCorrection*' -and $reflectionPromotionText -like '*autonomyEvidenceLink*' -and $reflectionPromotionText -like '*verifiedOutcomeSha256*') { Mark-Ok 'reflection promotion verified correction evidence linkage' } else { Mark-Fail 'reflection promotion verified correction evidence linkage missing' }
if ($reflectionPromotionText -like '*self-model.ps1*' -and $reflectionPromotionText -like '*-Action Refresh*' -and $reflectionPromotionText -like '*selfModelRefresh*' -and $reflectionPromotionText -like '*rawPromptStored=$false*') { Mark-Ok 'reflection promotion self-model refresh integration' } else { Mark-Fail 'reflection promotion self-model refresh integration missing' }

# Procedure cards are private, mutable operating state.  A package verifier
# must prove the public implementation contracts that consume those optional
# cards, never read their bodies or require a particular user's memory root.
$agentBridgeText = Read-Utf8 'scripts\agent-bridge-channel.ps1'
$runtimeDriftText = Read-Utf8 'scripts\runtime-drift-checkpoint.ps1'
if ((Test-ContainsAll ($agentBridgeText + $runtimeDriftText) @('WaitInbox','nested_agent_launch','idle_as_blocked','auto_close_without_explicit_close'))) { Mark-Ok 'AgentBridge public procedure contract support' } else { Mark-Fail 'AgentBridge public procedure contract support missing' }
if ((Test-ContainsAll ($goalRouteText + $routeCheckpointText) @('super-brain.goal-route-lock.v1','goal_route_drift','scope_creep','acceptedGoal','acceptedRoute'))) { Mark-Ok 'goal route public procedure contract support' } else { Mark-Fail 'goal route public procedure contract support missing' }
if (Test-ContainsAll $integrationParityText @('module smoke OK','integration smoke OK','user-facing acceptance OK','scattered_assembly')) { Mark-Ok 'verified integration public procedure contract support' } else { Mark-Fail 'verified integration public procedure contract support missing' }
if (Test-ContainsAll $engineeringDecisionText @('FACT','unsupported_optimal_claim','execution_step_without_contract')) { Mark-Ok 'engineering judgment public procedure contract support' } else { Mark-Fail 'engineering judgment public procedure contract support missing' }

$statusSnapshotWriterText = Read-Utf8 'scripts\status-snapshot-writer.ps1'
if ($statusSnapshotWriterText -like '*ClearCheckpoint*' -and $statusSnapshotWriterText -like '*checkpoint-writer.ps1*') { Mark-Ok 'status snapshot checkpoint clearing support' } else { Mark-Fail 'status snapshot checkpoint clearing support missing' }
if ($statusSnapshotWriterText -like '*last-project-continuity.json*' -and $statusSnapshotWriterText -like '*task-graph.json*' -and $statusSnapshotWriterText -like '*last-impact-advisor.json*' -and $statusSnapshotWriterText -like '*codegraph*' -and $statusSnapshotWriterText -like '*continuity*' -and $statusSnapshotWriterText -like '*impact*') { Mark-Ok 'status snapshot crash continuation summaries' } else { Mark-Fail 'status snapshot crash continuation summaries missing' }

$taskVerificationText = Read-Utf8 'scripts\task-verification.ps1'
if ($taskVerificationText -like '*checkpoint-writer.ps1*' -and $taskVerificationText -like '*Action Complete*' -and $taskVerificationText -like '*constraintPreflight*' -and $taskVerificationText -like '*constraintsPreserved*') { Mark-Ok 'task verification checkpoint constraint completion support' } else { Mark-Fail 'task verification checkpoint constraint completion support missing' }
if ($taskVerificationText -like '*retired project-continuity writer*' -and $taskVerificationText -like '*status-snapshot-writer.ps1*' -and $taskVerificationText -like '*continuity*' -and $taskVerificationText -like '*impact*') { Mark-Ok 'task verification canonical continuity snapshot support' } else { Mark-Fail 'task verification canonical continuity snapshot support missing' }
if ($taskVerificationText -like '*super-brain.verified-task-outcome.v1*' -and $taskVerificationText -like '*verified-task-outcomes*' -and $taskVerificationText -like '*Get-AutonomyAuthorization*' -and $taskVerificationText -like '*rawSummaryStored=$false*') { Mark-Ok 'task verification strict autonomy outcome support' } else { Mark-Fail 'task verification strict autonomy outcome support missing' }

$autonomyLedgerText = Read-Utf8 'scripts\autonomy-evidence-ledger.ps1'
if ($autonomyLedgerText -like '*super-brain.autonomy-evidence-ledger.v1*' -and $autonomyLedgerText -like '*completedCheckpointOrTaskCardAloneCounts = $false*' -and $autonomyLedgerText -like '*callerSuppliedCountsAccepted = $false*' -and $autonomyLedgerText -like '*verified-task-outcomes*' -and $autonomyLedgerText -like '*autonomy-authorizations*') { Mark-Ok 'strict autonomy evidence ledger support' } else { Mark-Fail 'strict autonomy evidence ledger support missing' }

$intelligenceEvalText = Read-Utf8 'scripts\intelligence-eval.ps1'
if ($intelligenceEvalText -like '*Get-AutonomyEvidenceLedger*' -and $intelligenceEvalText -like '*callerSuppliedCountsIgnored*' -and $intelligenceEvalText -like '*derived_autonomy_evidence_ledger*') { Mark-Ok 'intelligence evaluator ledger-derived autonomy counts' } else { Mark-Fail 'intelligence evaluator ledger-derived autonomy counts missing' }

$decisionSearchText = Read-Utf8 'scripts\decision-search.ps1'
if ($decisionSearchText -like '*TopK*' -and $decisionSearchText -like '*MaxTokens*') { Mark-Ok 'decision search budget support' } else { Mark-Fail 'decision search budget support missing' }
if ($decisionSearchText -like '*AdrOnly*' -and $decisionSearchText -like '*Status*' -and $decisionSearchText -like '*Owner*' -and $decisionSearchText -like '*Scope*' -and $decisionSearchText -like '*supersededBy*') { Mark-Ok 'decision search ADR filters' } else { Mark-Fail 'decision search ADR filters missing' }

$memoryModeText = Read-Utf8 'scripts\memory-mode.ps1'
if ($memoryModeText -like '*MEMORY_MODE_RETIRED*' -and $memoryModeText -like '*single-super-brain-memory-authority*' -and $memoryModeText -like '*memory-root.txt*' -and $memoryModeText -like '*Get-SuperBrainSharedMemoryRoot*' -and $memoryModeText -notlike '*Get-SuperBrainAgentMemoryRoot*' -and $memoryModeText -notlike '*Get-SuperBrainGroupMemoryRoot*') { Mark-Ok 'unified shared memory mode support' } else { Mark-Fail 'unified shared memory mode support missing' }

$commonText = Read-Utf8 'scripts\common.ps1'
if ($commonText -like '*Get-SuperBrainSharedMemoryRoot*' -and $commonText -like '*Get-SuperBrainActiveMemoryRoot*' -and $commonText -like '*Never reactivate a historical per-agent/group root*' -and $commonText -like '*legacy migration sources*' -and $commonText -like '*Get-SuperBrainExtensionCatalog*' -and $commonText -like '*Resolve-SuperBrainExtensionIds*') { Mark-Ok 'unified memory and extension selection helpers' } else { Mark-Fail 'unified memory or extension selection helpers missing' }
if ($commonText.Contains("initialized = `$true") -and $commonText.Contains("mode = 'shared'") -and $commonText.Contains('only live write target')) { Mark-Ok 'single shared memory policy' } else { Mark-Fail 'single shared memory policy missing' }

$globalStartupBlock = ''
try { $globalStartupBlock = Get-SuperBrainGlobalStartupBlock $Root } catch { $globalStartupBlock = '' }
if ($globalStartupBlock -like '*Super Memory Brain Bootstrap*' -and $globalStartupBlock -like '*Authority: bootstrap only*' -and $globalStartupBlock -like '*super-brain-rules.json*' -and $globalStartupBlock -like '*bootstrap never selects a continuation anchor*' -and $globalStartupBlock -like '*same H7 CLI*' -and $globalStartupBlock -like '*Never use Hook/P7*' -and $globalStartupBlock -notlike '*Compaction:*') { Mark-Ok 'thin global startup H7 route and retirement guards' } else { Mark-Fail 'thin global startup H7 route or retirement guards missing' }
$globalStartupWorkflowMarkers = @('Git workflow trigger','Super Memory Brain Bootstrap','Authority: bootstrap only','super-brain-rules.json','must never duplicate or override','bootstrap never selects a continuation anchor','same H7 CLI','Never use Hook/P7')
if ((Test-ContainsAll $globalStartupBlock $globalStartupWorkflowMarkers) -and $freshCodexSkillText -like '*sole behavioral-policy*' -and $freshCodexSkillText -like '*Every same-workline continuation is visible-context-first*' -and $freshCodexSkillText -like '*visible-readback/state card*' -and $freshCodexSkillText -like '*to another approved workline*' -and $freshCodexSkillText -like '*codex_visible_context*' -and $freshCodexSkillText -like '*recovery event*' -and $freshCodexSkillText -like '*is never an assertion substitute*') { Mark-Ok 'bootstrap single-source and skill recovery guards' } else { Mark-Fail 'bootstrap single-source or skill recovery guards missing' }
if ($commonText -like '*PACKAGE_ROOT_MARKER_SOURCE_MISSING*' -and $commonText -like '*PACKAGE_ROOT_MARKER_VERIFY_FAILED*' -and $commonText -like '*MEMORY_ROOT_MARKER_SOURCE_MISSING*' -and $commonText -like '*MEMORY_ROOT_MARKER_VERIFY_FAILED*') { Mark-Ok 'root marker source and writeback verification guards' } else { Mark-Fail 'root marker source or writeback verification guards missing' }

$installAgentText = Read-Utf8 'scripts\install-agent.ps1'
if ($installAgentText -like '*AgentName*' -and $installAgentText -like '*SkillRoot*' -and $installAgentText.Contains("[string]`$Mode = 'Shared'") -and $installAgentText -like '*MEMORY_MODE_RETIRED*' -and $installAgentText -like '*Get-SuperBrainSharedMemoryRoot*' -and $installAgentText -notlike '*Get-SuperBrainAgentMemoryRoot*' -and $installAgentText -notlike '*Extensions*' -and $installAgentText -like '*absorbedCapabilities=package-owned-cold-sources*' -and $installAgentText -like '*Write-SuperBrainMemoryRootMarker*') { Mark-Ok 'generic shared-agent install support' } else { Mark-Fail 'generic shared-agent install support missing' }

$hotRefreshText = Read-Utf8 'scripts\hot-refresh-skills.ps1'
if (Test-ContainsAll $hotRefreshText @('last-hot-refresh.json','HOT_REFRESH_OK','Get-SuperBrainHostAdapterItems','package-root.txt','Write-SuperBrainMemoryRootMarker','Write-SuperBrainGlobalStartup','ABSORBED_PROVENANCE_ONLY_NO_STANDALONE_INSTALL')) { Mark-Ok 'hot refresh skills support' } else { Mark-Fail 'hot refresh skills support missing' }

$installMenuText = Read-Utf8 'scripts\install-menu.ps1'
if ($installMenuText -like '*Get-AgentCandidates*' -and $installMenuText -like '*Install-ManualAgent*' -and $installMenuText -like '*install-agent.ps1*' -and $installMenuText -like '*Bundled capability sources are absorbed by Super Brain*' -and $installMenuText -notlike '*Select-ExtensionsForInstall*') { Mark-Ok 'menu skill injector and absorbed capability support' } else { Mark-Fail 'menu skill injector or absorbed capability support missing' }
if ($installMenuText -like '*cleanup-install-backups.ps1*' -and $installMenuText -like '*Keep how many newest install backups*' -and $installMenuText -like '*Type DELETE to remove older install backups*') { Mark-Ok 'bat menu install backup cleanup support' } else { Mark-Fail 'bat menu install backup cleanup support missing' }

$installUiText = Read-Utf8 'scripts\install-ui.ps1'
if ((Test-ContainsAll $installUiText @('System.Windows.Forms','INSTALL_UI_SMOKE_OK','SmokeTest','INSTALL_UI_READY','Set-UiBusy','BeginInvoke','超级大脑技能注入器','热刷新已安装技能','hot-refresh-skills.ps1','last-hot-refresh.json','打开记忆导入页','Get-InstallBackupCleanupPlan','Remove-InstallBackupCandidates','注入手动目录')) -and $installUiText -notlike '*Select-ExtensionsForUi*') { Mark-Ok 'install UI script support' } else { Mark-Fail 'install UI script support missing' }

$installUiVbsText = Read-Utf8 'scripts\install-ui.vbs'
if ($installUiVbsText -like '*shell.Run*' -and $installUiVbsText -like '*WindowStyle Hidden*' -and $installUiVbsText -like '*install-ui.ps1*') { Mark-Ok 'install UI no-console launcher' } else { Mark-Fail 'install UI no-console launcher missing' }

$brainBatText = Read-Utf8 'scripts\brain.bat'
if ($brainBatText -like '*brain-ui.vbs*' -and $brainBatText -like '*Super Brain Console exited*') { Mark-Ok 'brain console bat launcher' } else { Mark-Fail 'brain console bat launcher missing' }

$brainUiVbsText = Read-Utf8 'scripts\brain-ui.vbs'
if ($brainUiVbsText -like '*CONTROL_CENTER_LAUNCHER*' -and $brainUiVbsText -like '*open-control-center.ps1*' -and $brainUiVbsText -like '*brain_ui_server.py*' -and $brainUiVbsText -like '*did not fall back*') { Mark-Ok 'brain console vbs launcher' } else { Mark-Fail 'brain console vbs launcher missing' }

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
$autonomyLedgerText = Read-Utf8 'scripts\autonomy-evidence-ledger.ps1'
if ((Test-ContainsAll $taskVerificationText @('Get-TaskEvidenceBinding','Get-CompletedTaskEvidenceBinding','evidenceBindingStatus')) -and (Test-ContainsAll $completionGuardText @('Get-TaskEvidenceBindingStatus','evidence-version-binding','historical_evidence_binding_missing')) -and (Test-ContainsAll $autonomyLedgerText @('historicalOutcomeCount','Test-SameEvidenceBinding','historical_evidence_binding_missing'))) { Mark-Ok 'verification completion guard and autonomy ledger evidence binding integration' } else { Mark-Fail 'verification completion guard and autonomy ledger evidence binding integration missing' }
$adaptationObserverText = Read-Utf8 'scripts\user-adaptation-observer.ps1'
if (Test-ContainsAll $adaptationObserverText @('USER_ADAPTATION_OBSERVER_VERIFIED_ARTIFACT_REQUIRED','USER_ADAPTATION_OBSERVER_CLOSED_CORRECTION_REQUIRED','maxSignalsPerTask','rawPromptStored=$false','$WorkspaceKey`:$($WorkflowKey.ToLowerInvariant())')) { Mark-Ok 'verified outcome adaptation observer support' } else { Mark-Fail 'verified outcome adaptation observer support missing' }
if (Test-ContainsAll $taskVerificationText @('AdaptationSignals','user-adaptation-observer.ps1','NoExit=$true','adaptationObservation','USER_ADAPTATION_COMPLETED_TASK_REQUIRED','pending_work_preserved')) { Mark-Ok 'task verification adaptation integration and fail-closed outcome guard' } else { Mark-Fail 'task verification adaptation integration or fail-closed outcome guard missing' }

$verifyPackageText = Read-Utf8 'scripts\verify-package.ps1'
if ($verifyPackageText -like '*.tmp-verify-package*' -and $verifyPackageText -like '*Get-SuperBrainSharingPolicyPath*' -and $verifyPackageText -like '*Write-Utf8NoBom $policyPath $originalPolicy*' -and $verifyPackageText -like '*Remove-Item -LiteralPath $policyPath -Force*') { Mark-Ok 'verify package temp install policy restoration guard' } else { Mark-Fail 'verify package temp install policy restoration guard missing' }

$smokeTestText = Read-Utf8 'scripts\smoke-test.ps1'
if (
  $smokeTestText -like '*$tmpStateRoot = Join-Path $tmpRoot ''state''*' -and
  $smokeTestText -like '*$tmpMemory = Join-Path $tmpStateRoot ''shared''*' -and
  $smokeTestText -like '*$env:SUPER_BRAIN_STATE_ROOT = $tmpStateRoot*' -and
  $smokeTestText -like '*$env:SUPER_BRAIN_ARCHIVE_ROOT = $tmpArchive*' -and
  $smokeTestText -like '*-Isolated -NoBackup -SkipRuntime*' -and
  $smokeTestText -like '*-Isolated -SkipRuntime*' -and
  $smokeTestText -like '*Assert-UnchangedFile ''Codex config''*' -and
  $smokeTestText -like '*Assert-UnchangedFile ''Codex bootstrap''*' -and
  $smokeTestText -like '*foreach ($name in $savedEnvironment.Keys)*' -and
  $smokeTestText -like '*Remove-Item -LiteralPath $tmpRoot -Recurse -Force*'
) { Mark-Ok 'smoke test isolated state and user-config guard' } else { Mark-Fail 'smoke test isolated state and user-config guard missing' }

$workspaceLifecycleText = Read-Utf8 'scripts\workspace-lifecycle-manager.ps1'
if ($workspaceLifecycleText -like '*last-workspace-lifecycle.json*' -and $workspaceLifecycleText -like '*session-binding.json*' -and $workspaceLifecycleText -like '*agent-bridge*' -and $workspaceLifecycleText -like '*active-agent-bridge-channel.json*' -and $workspaceLifecycleText -like '*ApplySafe*' -and $workspaceLifecycleText -like '*requires_confirmation*' -and $workspaceLifecycleText -like '*Invoke-SuperBrainTaskStateStore*' -and $workspaceLifecycleText -like '*Reconcile*' -and $workspaceLifecycleText -like '*Compact*' -and $workspaceLifecycleText -like '*blocked_pending_transaction*' -and $workspaceLifecycleText -like '*blocked_active_or_unresolved_task*' -and $workspaceLifecycleText -like '*task-lifecycle-audit.ps1*' -and $workspaceLifecycleText -like '*neverInferUserTaskCompletionFromAge*') { Mark-Ok 'workspace lifecycle manager and task-state cold maintenance support' } else { Mark-Fail 'workspace lifecycle manager and task-state cold maintenance support missing' }

$autoHygieneText = Read-Utf8 'scripts\auto-hygiene-runner.ps1'
if ($autoHygieneText -like '*last-memory-hygiene.json*' -and $autoHygieneText -like '*compressed-memory-evidence*' -and $autoHygieneText -like '*compress_with_original_archive*' -and $autoHygieneText -like '*private_pattern*' -and $autoHygieneText -like '*requires_confirmation*' -and $autoHygieneText -like '*Invoke-SuperBrainMemoryRewriteTransaction*') { Mark-Ok 'auto hygiene runner support' } else { Mark-Fail 'auto hygiene runner support missing' }

$postTaskMaintenanceText = Read-Utf8 'scripts\post-task-maintenance.ps1'
if ($postTaskMaintenanceText -like '*workspace-lifecycle-manager.ps1*' -and $postTaskMaintenanceText -like '*auto-hygiene-runner.ps1*' -and $postTaskMaintenanceText -like '*self-improvement-queue.ps1*' -and $postTaskMaintenanceText -like '*status-snapshot-writer.ps1*' -and $postTaskMaintenanceText -like '*user-adaptation.ps1*' -and $postTaskMaintenanceText -like '*if(-not$ApplySafe){& $adaptationScript -Action Status -Json;return}*' -and $postTaskMaintenanceText -like '*-Action Synthesize -ExpectedRevision*' -and $postTaskMaintenanceText -like "*if(`$ApplySafe){'Maintain'}else{'Status'}*" -and $postTaskMaintenanceText -like '*last-post-task-maintenance.json*') { Mark-Ok 'post task maintenance hook support' } else { Mark-Fail 'post task maintenance hook support missing' }
if ($postTaskMaintenanceText -like '*self-model.ps1*' -and $postTaskMaintenanceText -like '*Refresh*' -and $postTaskMaintenanceText -like '*Status*' -and $postTaskMaintenanceText -like '*last-post-task-maintenance.json*') { Mark-Ok 'post task self-model refresh integration' } else { Mark-Fail 'post task self-model refresh integration missing' }
$selfModelText = Read-Utf8 'scripts\self-model.ps1'
if ($selfModelText -like "*ValidateSet('Status','Refresh')*" -and $selfModelText -like '*maxAgeHours*' -and $selfModelText -like '*maxEvidenceItems*' -and $selfModelText -like '*maxPreferenceItems*' -and $selfModelText -like '*evidenceStatus*' -and $selfModelText -like '*sourceTreeBinding*' -and $selfModelText -like '*Get-LearningQueueTrust*' -and $selfModelText -like '*rawPromptStored=$false*' -and $selfModelText -like '*alwaysOnInjection=$false*' -and $selfModelText -like '*last-verify-package.json*') { Mark-Ok 'bounded self-model lifecycle support' } else { Mark-Fail 'bounded self-model lifecycle support missing' }

$selfImprovementQueueText = Read-Utf8 'scripts\self-improvement-queue.ps1'
if ($selfImprovementQueueText -like '*self-improvement-queue.json*' -and $selfImprovementQueueText -like "*ValidateSet('Status','Collect','Maintain','Resolve','RecordVerification','IssueAdoptionReceipt')*" -and $selfImprovementQueueText -like '*RESOLUTION_EVIDENCE_REQUIRED*' -and $selfImprovementQueueText -like '*MANUAL_RESOLUTION_DISABLED*' -and $selfImprovementQueueText -like '*ADOPTION_RECEIPT_MISMATCH*' -and $selfImprovementQueueText -like '*LEARNING_EFFECT_ARTIFACT_NO_IMPROVEMENT*' -and $selfImprovementQueueText -like '*VERIFICATION_RECEIPT_DUPLICATE*' -and $selfImprovementQueueText -like '*Sync-ReflectionLifecycle*' -and $selfImprovementQueueText -like '*Sync-SkillEvolutionLifecycle*' -and $selfImprovementQueueText -like '*sideEffectFree*' -and $selfImprovementQueueText -like '*familyKey*' -and $selfImprovementQueueText -like '*self-improvement-archive.v1*' -and $selfImprovementQueueText -like '*candidateOnly*' -and $selfImprovementQueueText -like '*noAutomaticSkillMutation*' -and $selfImprovementQueueText -like '*auto-evidence-only*' -and $selfImprovementQueueText -like '*reflection-promotion.ps1*') { Mark-Ok 'bounded self improvement queue lifecycle support' } else { Mark-Fail 'bounded self improvement queue lifecycle support missing' }

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
if ($coldStartAuditText -like '*session-restore.ps1*' -and $coldStartAuditText -like '*smart-next.ps1*' -and $coldStartAuditText -like '*super-brain-dashboard.ps1*' -and $coldStartAuditText -like '*auto-check.ps1*' -and $coldStartAuditText -like '*trigger-simulation.ps1*' -and $coldStartAuditText -like '*recallTriggered*' -and $coldStartAuditText -like '*dashboardMode*' -and $coldStartAuditText -like '*verifySuggested*' -and $coldStartAuditText -like '*durationMs*' -and $coldStartAuditText -like '*Get-SuperBrainPercentileMs*' -and $coldStartAuditText -like '*Get-SuperBrainColdStartObservedSummary*') { Mark-Ok 'cold-start audit support compact evidence and latency reporting' } else { Mark-Fail 'cold-start audit support compact evidence or latency reporting missing' }

$pesterRunnerText = Read-Utf8 'scripts\test-pester.ps1'
$ciText = Read-Utf8 'scripts\ci.ps1'
if ((Test-ContainsAll $pesterRunnerText @("ValidateSet('Fast','Core','Full')",'PESTER_TIER_INCOMPLETE','Start-SuperBrainOwnedProcess','Complete-SuperBrainOwnedProcess','timedOutSuiteCount','last-pester-','super-brain.pester-report.v1','Initialize-SuperBrainPesterStateRoot','per_suite_rebased_shared_policy','memory-sharing-policy.json','observedMaxParallelSuites')) -and (Test-ContainsAll $ciText @("ValidateSet('Fast','Core','Full')",'PesterTier','Start-SuperBrainOwnedProcess','Complete-SuperBrainOwnedProcess','last-pester.json','terminatedProcessIds','timeoutSeconds'))) { Mark-Ok 'tiered Pester owned CI timeout and sandbox state isolation support' } else { Mark-Fail 'tiered Pester owned CI timeout or sandbox state isolation support missing' }

$intentRouterText = Read-Utf8 'scripts\intent-router.ps1'
if ($intentRouterText -like '*intent*' -and $intentRouterText -like '*recommendedAction*' -and $intentRouterText -like '*dispatchHints*' -and $intentRouterText -like '*absorbed-capability-route.ps1*' -and $intentRouterText -like '*capabilityRoute*' -and $intentRouterText -like '*absorbedCapabilities*') { Mark-Ok 'intent router support' } else { Mark-Fail 'intent router support missing' }
if ($intentRouterText -like '*Normalize-WorkflowText*' -and $intentRouterText -like '*Test-WorkflowPreferenceScope*' -and $intentRouterText -like '*workflowPreference*' -and $intentRouterText -like '*decision-search.ps1*') { Mark-Ok 'intent router exact workflow preference support' } else { Mark-Fail 'intent router exact workflow preference support missing' }

$smartNextText = Read-Utf8 'scripts\smart-next.ps1'
if ($smartNextText -like '*intent-router.ps1*' -and $smartNextText -like '*auto-continuation.ps1*' -and $smartNextText -like '*dispatch-learning.ps1*' -and $smartNextText -like '*nextAction*') { Mark-Ok 'smart next support' } else { Mark-Fail 'smart next support missing' }
if ($smartNextText -like '*canonicalResponseContract*' -and $smartNextText -like '*workflow_preference_recall*' -and $smartNextText -like '*decision-search.ps1*' -and $smartNextText -like '*canonical_missing*' -and $smartNextText -like '*canonical_conflict*') { Mark-Ok 'smart next canonical workflow resolver support' } else { Mark-Fail 'smart next canonical workflow resolver support missing' }

$healthSummaryText = Read-Utf8 'scripts\health-summary.ps1'
if ($healthSummaryText -like '*super-brain-dashboard.ps1*' -and $healthSummaryText -like '*doctor.ps1*' -and $healthSummaryText -like '*riskSummary*') { Mark-Ok 'health summary support' } else { Mark-Fail 'health summary support missing' }

$agentScorecardText = Read-Utf8 'scripts\agent-scorecard.ps1'
if ($agentScorecardText -like '*agent-teams.json*' -and $agentScorecardText -like '*team-task-index.json*' -and $agentScorecardText -like '*score*' -and $agentScorecardText -like '*recommendation*') { Mark-Ok 'agent scorecard support' } else { Mark-Fail 'agent scorecard support missing' }

$taskRetrospectiveText = Read-Utf8 'scripts\task-retrospective.ps1'
if ($taskRetrospectiveText -like '*last-retrospective.json*' -and $taskRetrospectiveText -like '*didWell*' -and $taskRetrospectiveText -like '*improveNext*') { Mark-Ok 'task retrospective support' } else { Mark-Fail 'task retrospective support missing' }

$releaseReadinessText = Read-Utf8 'scripts\release-readiness.ps1'
if ($releaseReadinessText -like '*last-install-ui-regression.json*' -and $releaseReadinessText -like '*full_ci_missing_stale_or_version_mismatch*' -and $releaseReadinessText -like '*Package-ready for direct Git review*') { Mark-Ok 'direct Git readiness support' } else { Mark-Fail 'direct Git readiness support missing' }

$brainText = Read-Utf8 'scripts\brain.ps1'
if ($brainText -like '*health-summary.ps1*' -and $brainText -like '*smart-next.ps1*' -and $brainText -like '*release-readiness.ps1*' -and $brainText -like '*agent-scorecard.ps1*' -and $brainText -like '*optimize-advisor.ps1*') { Mark-Ok 'brain unified command support' } else { Mark-Fail 'brain unified command support missing' }

$versionBumpText = Read-Utf8 'scripts\version-bump.ps1'
if (
  $versionBumpText -like '*manifest.json*' -and
  $versionBumpText -like '*BASELINE_HISTORY.md*' -and
  $versionBumpText -like '*maintenance-policy.json*' -and
  $versionBumpText -like '*super-brain-rules.json*' -and
  $versionBumpText -like '*Apply*' -and
  $versionBumpText -notlike '*graph-add.ps1*' -and
  $versionBumpText -notlike '*memory\graph.jsonl*'
) { Mark-Ok 'version bump source-only preview support' } else { Mark-Fail 'version bump source-only preview support missing' }

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
if ($hostCacheCheckText -like '*currentSessionCacheRisk*' -and $hostCacheCheckText -like '*loadedSkillLimitation*' -and $hostCacheCheckText -like '*liveMcpIdentityLimitation*' -and $hostCacheCheckText -like '*SUPER_BRAIN_RUNTIME_IDENTITY*' -and $hostCacheCheckText -like '*brain_status/runtimeIdentity=current*' -and $hostCacheCheckText -like '*newSessionPrompt*' -and $hostCacheCheckText -like '*hot-refresh-skills.ps1 -AllKnown*' -and $hostCacheCheckText -like '*Get-H7McpBinding*' -and $hostCacheCheckText -like '*Get-H7RetiredTransportGuard*' -and $hostCacheCheckText -like '*retiredTransportGuard*' -and $hostCacheCheckText -like '*H7_RETIRED_TRANSPORT_CONFLICT*' -and $hostCacheCheckText -like '*retire-codex-super-brain-hooks.ps1*' -and $hostCacheCheckText -notlike '*install-codex-user-prompt-hook.ps1*' -and $hostCacheCheckText -notlike '*Get-SuperBrainCodexHookHostState*') { Mark-Ok 'H7 MCP adapter cache and retired-transport guard support' } else { Mark-Fail 'H7 MCP adapter cache or retired-transport guard support missing' }

$cleanupLegacyText = Read-Utf8 'scripts\cleanup-legacy-memory.ps1'
if ($cleanupLegacyText -like '*memory-zcode*' -and $cleanupLegacyText -like '*memory-codex*' -and $cleanupLegacyText -like '*Get-FileHash*' -and $cleanupLegacyText -like '*-Apply*') { Mark-Ok 'legacy memory cleanup support' } else { Mark-Fail 'legacy memory cleanup support missing' }

$cleanupInstallBackupsText = Read-Utf8 'scripts\cleanup-install-backups.ps1'
if ($cleanupInstallBackupsText -like '*install-backup-*' -and $cleanupInstallBackupsText -like '*Keep*' -and $cleanupInstallBackupsText -like '*-Apply*') { Mark-Ok 'install backup cleanup support' } else { Mark-Fail 'install backup cleanup support missing' }
if ($cleanupInstallBackupsText -like '*install-transactions*' -and $cleanupInstallBackupsText -like '*KeepTransactions*' -and $cleanupInstallBackupsText -like '*KeepRolledBackTransactions*' -and $cleanupInstallBackupsText -like '*Refusing transaction with unresolved status*') { Mark-Ok 'install transaction retention guard' } else { Mark-Fail 'install transaction retention guard missing' }

$migrateMemoryText = Read-Utf8 'scripts\migrate-memory-layout.ps1'
if ($migrateMemoryText -like '*memory-zcode*' -and $migrateMemoryText -like '*memory-codex*' -and $migrateMemoryText -like '*Get-SuperBrainMemoryBaseRoot*' -and $migrateMemoryText -like '*MIGRATION_APPLY_REQUIRED*') { Mark-Ok 'memory layout migration support' } else { Mark-Fail 'memory layout migration support missing' }
if (Test-ContainsAll $migrateMemoryText @('ImportRoot','EpochId','AdapterName','StateRoot','Resolve-ImportMemoryRoot','MIGRATION_IMPORT_NESTED_MEMORY','MIGRATION_SKIP_ACTIVE_OR_PARENT','MIGRATION_CLEANUP_PREVIEW_ONLY','MIGRATION_LEGACY_MODE_IGNORED')) { Mark-Ok 'memory import staged compatibility launcher' } else { Mark-Fail 'memory import staged compatibility launcher missing' }

$psScripts = Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Filter '*.ps1' -File -Recurse
foreach ($scriptFile in $psScripts) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -eq 0) { Mark-Ok "parse scripts\$($scriptFile.Name)" } else { Mark-Fail "parse scripts\$($scriptFile.Name) $($errors[0].Message)" }
}

$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'startup-check.ps1') -Json | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'startup hook/config check' } else { Mark-Ok 'startup optional MCP binding not configured; same H7 CLI remains available' }

$global:LASTEXITCODE = 0
$hooklessRetirementJson = & (Join-Path $PSScriptRoot 'retire-codex-super-brain-hooks.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $hooklessRetirement = $hooklessRetirementJson | ConvertFrom-Json; if($hooklessRetirement.ok -and $hooklessRetirement.otherHooksPreserved){Mark-Ok 'H7 hookless retirement audit'}else{Mark-Fail 'H7 hookless retirement audit failed'} } catch { Mark-Fail "H7 hookless retirement report parse $($_.Exception.Message)" }
} else { Mark-Fail 'H7 hookless retirement report' }

$firstLoadBootstrapText = Read-Utf8 'scripts\first-load-bootstrap.ps1'
if ($firstLoadBootstrapText -like '*super-brain.first-load-bootstrap.v1*' -and $firstLoadBootstrapText -like '*RepairMcp*' -and $firstLoadBootstrapText -like '*mcpBindingOk*' -and $firstLoadBootstrapText -like '*mcpFunctionalOk*' -and $firstLoadBootstrapText -like '*McpProbeMaxAgeMinutes*' -and $firstLoadBootstrapText -like '*-McpOnly*' -and $firstLoadBootstrapText -like '*memory-root.txt*' -and $firstLoadBootstrapText -like '*rawPromptStored = $false*') { Mark-Ok 'first-load MCP bootstrap guard' } else { Mark-Fail 'first-load MCP bootstrap guard missing' }

$bootstrapText = Read-Utf8 'scripts\bootstrap.ps1'
$installTransactionText = Read-Utf8 'scripts\internal\install-transaction.ps1'
$installStageText = Read-Utf8 'scripts\install.ps1'
if ($bootstrapText -like '*super-brain.bootstrap.v3*' -and $bootstrapText -like '*PreflightOnly*' -and $bootstrapText -like '*New-SuperBrainInstallTransaction*' -and $bootstrapText -like '*Restore-SuperBrainInstallTransaction*' -and $bootstrapText -like '*retire-codex-super-brain-hooks*' -and $bootstrapText -notlike '*install-codex-user-prompt-hook.ps1*' -and $bootstrapText -like '*install-runtime*' -and $bootstrapText -like '*post-install-health-check-codex*' -and $bootstrapText -like '*-FailOnNotReady*' -and $bootstrapText -like '*BOOTSTRAP_NO_BACKUP_UNSUPPORTED*') { Mark-Ok 'one-click H7-only transaction bootstrap guard' } else { Mark-Fail 'one-click H7-only transaction bootstrap guard missing' }
if ($installTransactionText -like '*super-brain.install-transaction.v1*' -and $installTransactionText -like '*prepared*' -and $installTransactionText -like '*committed*' -and $installTransactionText -like '*rolled_back*' -and $installTransactionText -like '*INSTALL_TRANSACTION_PAYLOAD_MISSING*') { Mark-Ok 'install transaction snapshot and rollback helper' } else { Mark-Fail 'install transaction snapshot and rollback helper missing' }
if ($installTransactionText.Contains('Resolve-SuperBrainWritableTransactionRoot') -and $installTransactionText.Contains('Test-SuperBrainWritableDirectory') -and $installTransactionText.Contains('INSTALL_TRANSACTION_NO_WRITABLE_ROOT') -and $bootstrapText.Contains('transactionRoot = [string]$transaction.root')) { Mark-Ok 'default writable transaction-root fallback' } else { Mark-Fail 'default writable transaction-root fallback missing' }
if ($installStageText -like '*SkipHealthCheck*' -and $installStageText -like '*InstallBackupRoot*' -and $installStageText -like '*SkipRuntime*' -and $installStageText -like '*SkipZCode*' -and $bootstrapText -like '*skipAbsentDefaultZCode*') { Mark-Ok 'single-host skill and runtime transaction stages' } else { Mark-Fail 'single-host skill and runtime transaction stages missing' }

$installRuntimeText = Read-Utf8 'scripts\install-runtime.ps1'
if ($installRuntimeText -like '*CODEX_HOME*' -and $installRuntimeText -like '*MCP_BINDING_MISMATCH*' -and $installRuntimeText -like '*Assert-McpBinding*' -and $installRuntimeText -like '*ConvertFrom-SuperBrainJsonOutput*') { Mark-Ok 'isolated MCP home and binding guard' } else { Mark-Fail 'isolated MCP home or binding guard missing' }
if ($firstLoadBootstrapText -like '*ConvertFrom-SuperBrainJsonOutput*') { Mark-Ok 'Codex warning-tolerant JSON parsing' } else { Mark-Fail 'Codex warning-tolerant JSON parsing missing' }

$global:LASTEXITCODE = 0
$callContractJsonText = & (Join-Path $PSScriptRoot 'script-call-contract.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $callContract=$callContractJsonText|ConvertFrom-Json; if($callContract.ok -and [int]$callContract.violationCount-eq0){Mark-Ok 'script call contracts'}else{Mark-Fail 'script call contract violations'} } catch { Mark-Fail "script call contract parse $($_.Exception.Message)" }
} else { Mark-Fail 'script call contracts' }

$summaryJsonText = & (Join-Path $PSScriptRoot 'summary.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try { $summaryJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'summary json' } catch { Mark-Fail "summary json parse $($_.Exception.Message)" }
} else { Mark-Fail 'summary json command' }

$doctorJsonText = & (Join-Path $PSScriptRoot 'doctor.ps1') -Json
$doctorExitCode = $LASTEXITCODE
try {
  $doctorJson = $doctorJsonText | ConvertFrom-Json
  Mark-Ok 'doctor json contract'
  if (($doctorExitCode -eq 0) -eq ($doctorJson.ok -eq $true)) { Mark-Ok 'doctor health exit contract' } else { Mark-Fail 'doctor health exit contract mismatch' }
  $doctorFields = @($doctorJson.PSObject.Properties.Name)
  if (@('riskSummary','risks','lastMemoryEval','lastTaskVerification','taskLifecycle' | Where-Object { $doctorFields -notcontains $_ }).Count -eq 0) { Mark-Ok 'doctor risk aggregation fields' } else { Mark-Fail 'doctor risk aggregation fields missing' }
  if ($null -ne $doctorJson.teamTasks -and $null -ne $doctorJson.teamTasks.count -and $null -ne $doctorJson.teamTasks.indexOk) { Mark-Ok 'doctor team task fields' } else { Mark-Fail 'doctor team task fields missing' }
  if ($null -ne $doctorJson.agentTeams -and [int]$doctorJson.agentTeams.templateCount -ge 4) { Mark-Ok 'doctor agent team fields' } else { Mark-Fail 'doctor agent team fields missing' }
  if ($null -ne $doctorJson.codeCapableAudit -and $null -ne $doctorJson.codeCapableAudit.codeCapableDelegationCount -and $null -ne $doctorJson.codeCapableAudit.unreviewedCodeChangeCount -and $null -ne $doctorJson.codeCapableAudit.driftRiskCount) { Mark-Ok 'doctor code-capable audit fields' } else { Mark-Fail 'doctor code-capable audit fields missing' }
} catch { Mark-Fail "doctor json parse $($_.Exception.Message)" }

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

$completionGuardJsonText = & (Join-Path $PSScriptRoot 'completion-guard.ps1') -Json -AllowPrivacyRisk -AllowActiveCheckpoint -ContractOnly -PackageVerificationInProgress
try {
  $completionGuardJson = $completionGuardJsonText | ConvertFrom-Json
  $completionGuardContractOk = ($null -ne $completionGuardJson.ok -and $null -ne $completionGuardJson.completionAuthorized -and $null -ne $completionGuardJson.failed -and $null -ne $completionGuardJson.taskId -and $null -ne $completionGuardJson.checks)
  if (-not $completionGuardContractOk) {
    Mark-Fail 'completion guard fields missing'
  } elseif ($completionGuardJson.completionAuthorized -ne $false) {
    Mark-Fail 'completion guard authorized completion during package self-verification'
  } elseif ($completionGuardJson.ok -eq $true) {
    Mark-Ok 'completion guard json'
  } else {
    $failedCompletionChecks = @($completionGuardJson.checks | Where-Object { $_.ok -ne $true } | ForEach-Object { $_.name })
    Mark-Fail "completion guard failed taskId=$($completionGuardJson.taskId) checks=$($failedCompletionChecks -join ',')"
  }
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

$statusSnapshotJsonText = & (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') -Summary 'verify-package status snapshot' -NextAction 'continue from dashboard' -AllowActiveCheckpoint -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $statusSnapshotJson = $statusSnapshotJsonText | ConvertFrom-Json
    if ($null -ne $statusSnapshotJson.ok -and $null -ne $statusSnapshotJson.nextAction -and $null -ne $statusSnapshotJson.verifyCheckedAt) { Mark-Ok 'status snapshot writer json' } else { Mark-Fail 'status snapshot writer fields missing' }
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
    if ($coldStartAuditJson.ok -eq $true -and [int]$coldStartAuditJson.total -gt 0 -and [int]$coldStartAuditJson.failed -eq 0 -and $null -ne $coldStartAuditJson.latency -and $null -ne $coldStartAuditJson.latency.p50Ms -and $null -ne $coldStartAuditJson.latency.p95Ms) { Mark-Ok 'cold-start audit json and latency fields' } else { Mark-Fail 'cold-start audit fields missing' }
  } catch { Mark-Fail "cold-start audit json parse $($_.Exception.Message)" }
} else { Mark-Fail 'cold-start audit command' }

$intentRouterJsonText = & (Join-Path $PSScriptRoot 'intent-router.ps1') -Text '继续' -Json
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

$workspaceLifecycleStateRoot = Join-Path ([IO.Path]::GetTempPath()) ('super-brain-verify-lifecycle-' + [guid]::NewGuid().ToString('N'))
$previousSuperBrainStateRoot = $env:SUPER_BRAIN_STATE_ROOT
try {
  New-Item -ItemType Directory -Force -Path $workspaceLifecycleStateRoot | Out-Null
  $env:SUPER_BRAIN_STATE_ROOT = $workspaceLifecycleStateRoot
  $workspaceLifecycleJsonText = & (Join-Path $PSScriptRoot 'workspace-lifecycle-manager.ps1') -Json
  $workspaceLifecycleExitCode = $LASTEXITCODE
  if ($workspaceLifecycleExitCode -eq 0) {
    try {
      $workspaceLifecycleJson = $workspaceLifecycleJsonText | ConvertFrom-Json
      if ($workspaceLifecycleJson.ok -eq $true -and $workspaceLifecycleJson.schema -eq 'super-brain.workspace-lifecycle.v1') { Mark-Ok 'workspace lifecycle manager isolated-state json' } else { Mark-Fail 'workspace lifecycle manager isolated-state fields missing' }
    } catch { Mark-Fail "workspace lifecycle manager isolated-state json parse $($_.Exception.Message)" }
  } else { Mark-Fail 'workspace lifecycle manager isolated-state command' }
} finally {
  if ($null -eq $previousSuperBrainStateRoot) { $env:SUPER_BRAIN_STATE_ROOT = $null } else { $env:SUPER_BRAIN_STATE_ROOT = $previousSuperBrainStateRoot }
  if (Test-Path -LiteralPath $workspaceLifecycleStateRoot) { Remove-Item -LiteralPath $workspaceLifecycleStateRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$autoHygieneJsonText = & (Join-Path $PSScriptRoot 'auto-hygiene-runner.ps1') -Json
if ($LASTEXITCODE -eq 0) {
  try {
    $autoHygieneJson = $autoHygieneJsonText | ConvertFrom-Json
    if ($autoHygieneJson.ok -eq $true -and $autoHygieneJson.schema -eq 'super-brain.auto-hygiene.v1') { Mark-Ok 'auto hygiene runner json' } else { Mark-Fail 'auto hygiene runner fields missing' }
  } catch { Mark-Fail "auto hygiene runner json parse $($_.Exception.Message)" }
} else { Mark-Fail 'auto hygiene runner command' }

$postTaskMaintenanceJsonText = & (Join-Path $PSScriptRoot 'post-task-maintenance.ps1') -Summary 'verify-package post-task maintenance plan' -Json
$postTaskMaintenanceExitCode = $LASTEXITCODE
try {
  $postTaskMaintenanceJson = $postTaskMaintenanceJsonText | ConvertFrom-Json
  if ($postTaskMaintenanceJson.schema -eq 'super-brain.post-task-maintenance.v1' -and $null -ne $postTaskMaintenanceJson.outputs) { Mark-Ok 'post task maintenance json contract' } else { Mark-Fail 'post task maintenance fields missing' }
  if (($postTaskMaintenanceExitCode -eq 0) -eq ($postTaskMaintenanceJson.ok -eq $true)) { Mark-Ok 'post task maintenance health exit contract' } else { Mark-Fail 'post task maintenance health exit contract mismatch' }
} catch { Mark-Fail "post task maintenance json parse $($_.Exception.Message)" }

$selfModelStatusJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'self-model.ps1') -ScriptArguments @('-Action','Status','-Json')
if ($LASTEXITCODE -eq 0) {
  try {
    $selfModelStatusJson = $selfModelStatusJsonText | ConvertFrom-Json
    if ($selfModelStatusJson.ok -eq $true -and $selfModelStatusJson.schema -eq 'super-brain.self-model-status.v1' -and $selfModelStatusJson.action -eq 'Status' -and $selfModelStatusJson.rawPromptStored -eq $false -and $null -ne $selfModelStatusJson.evidenceStatus -and $null -ne $selfModelStatusJson.path) { Mark-Ok 'self-model read-only status json contract' } else { Mark-Fail 'self-model status json fields missing' }
  } catch { Mark-Fail "self-model status json parse $($_.Exception.Message)" }
} else { Mark-Fail 'self-model status command' }

$selfImprovementQueueJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'self-improvement-queue.ps1') -ScriptArguments @('-Action','Status','-Summary','verify-package queue scan','-Json')
if ($LASTEXITCODE -eq 0) {
  try {
    $selfImprovementQueueJson = $selfImprovementQueueJsonText | ConvertFrom-Json
    if ($selfImprovementQueueJson.ok -eq $true -and $selfImprovementQueueJson.action -eq 'Status' -and $selfImprovementQueueJson.sideEffectFree -eq $true -and $null -ne $selfImprovementQueueJson.queuePath -and $null -ne $selfImprovementQueueJson.active -and $null -ne $selfImprovementQueueJson.maxActive) { Mark-Ok 'self improvement queue read-only status json' } else { Mark-Fail 'self improvement queue read-only status fields missing' }
  } catch { Mark-Fail "self improvement queue json parse $($_.Exception.Message)" }
} else { Mark-Fail 'self improvement queue command' }

$maintainJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'maintain.ps1') -ScriptArguments @('-Json')
$maintainExitCode = $LASTEXITCODE
try {
  $maintainJson = $maintainJsonText | ConvertFrom-Json
  if ($null -ne $maintainJson.ok -and $null -ne $maintainJson.steps -and $null -ne $maintainJson.safeActions) { Mark-Ok 'maintain json contract' } else { Mark-Fail 'maintain json fields missing' }
  if (($maintainExitCode -eq 0) -eq ($maintainJson.ok -eq $true)) { Mark-Ok 'maintain health exit contract' } else { Mark-Fail 'maintain health exit contract mismatch' }
} catch { Mark-Fail "maintain json parse $($_.Exception.Message)" }

$scriptTiersJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'script-tiers.ps1') -ScriptArguments @('-Json')
if ($LASTEXITCODE -eq 0) {
  try { $scriptTiersJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'script tiers json' } catch { Mark-Fail "script tiers json parse $($_.Exception.Message)" }
} else { Mark-Fail 'script tiers json command' }

$memoryHealthJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'memory-health.ps1') -ScriptArguments @('-Json')
if ($LASTEXITCODE -eq 0) {
  try {
    $memoryHealthJson = $memoryHealthJsonText | ConvertFrom-Json
    Mark-Ok 'memory health json'
    if ($null -ne $memoryHealthJson.layerCounts -and $null -ne $memoryHealthJson.summaryCount -and $null -ne $memoryHealthJson.negativeFeedbackCount -and $null -ne $memoryHealthJson.expiredCount) { Mark-Ok 'memory health layer expiry feedback counters' } else { Mark-Fail 'memory health layer expiry feedback counters missing' }
    if ($null -ne $memoryHealthJson.adrGraphCount -and $null -ne $memoryHealthJson.adrCurrentCount -and $null -ne $memoryHealthJson.adrSupersededCount) { Mark-Ok 'memory health ADR counters' } else { Mark-Fail 'memory health ADR counters missing' }
  } catch { Mark-Fail "memory health json parse $($_.Exception.Message)" }
} else { Mark-Fail 'memory health json command' }

$decisionAuditJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'decision-audit.ps1') -ScriptArguments @('-Json')
$decisionAuditExitCode = $LASTEXITCODE
try {
  $decisionAuditJson = $decisionAuditJsonText | ConvertFrom-Json
  if ($decisionAuditExitCode -eq 0 -and $decisionAuditJson.ok -eq $true) {
    Mark-Ok 'decision audit json'
    if ($null -ne $decisionAuditJson.adrGraphCount -and $null -ne $decisionAuditJson.adrSchemaIssueCount -and $null -ne $decisionAuditJson.adrCurrentConflictCount) { Mark-Ok 'decision audit ADR counters' } else { Mark-Fail 'decision audit ADR counters missing' }
  } elseif ($decisionAuditExitCode -eq 1 -and $decisionAuditJson.ok -eq $false) {
    Mark-Fail "decision audit health failure adrSchemaIssues=$($decisionAuditJson.adrSchemaIssueCount) graphParseErrors=$($decisionAuditJson.graphParseErrorCount) currentConflicts=$($decisionAuditJson.adrCurrentConflictCount)"
  } else {
    Mark-Fail "decision audit exit contract mismatch exit=$decisionAuditExitCode ok=$($decisionAuditJson.ok)"
  }
} catch { Mark-Fail "decision audit json parse $($_.Exception.Message)" }

$decisionSearchJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'decision-search.ps1') -ScriptArguments @('-Query','super-memory-brain','-TopK','1','-MaxTokens','80','-Json')
if ($LASTEXITCODE -eq 0) {
  try { $decisionSearchJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'decision search json' } catch { Mark-Fail "decision search json parse $($_.Exception.Message)" }
} else { Mark-Fail 'decision search json command' }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'encoding-check.ps1') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'encoding check' } else { Mark-Fail 'encoding check' }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'graph-normalize.ps1') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'graph normalize check' } else { Mark-Fail 'graph normalize check' }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'install-ui.ps1') -ScriptArguments @('-SmokeTest') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'install UI smoke test' } else { Mark-Fail 'install UI smoke test' }

$stateJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'state.ps1') -ScriptArguments @('-Json')
if ($LASTEXITCODE -eq 0) {
  try { $stateJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'state cache read json' } catch { Mark-Fail "state cache read json parse $($_.Exception.Message)" }
} else { Mark-Fail 'state cache read json command' }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'recall-recent.ps1') -ScriptArguments @('-Count','1') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'recall recent helper' } else { Mark-Fail 'recall recent helper' }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'recall-search.ps1') -ScriptArguments @('-Query','super-memory-brain','-Limit','1','-TopK','1','-MaxTokens','80','-Layer','all') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'recall search helper' } else { Mark-Fail 'recall search helper' }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'skill-sync-check.ps1') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'skill sync check' } else { Mark-Fail 'skill sync check' }
$skillSyncJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'skill-sync-check.ps1') -ScriptArguments @('-Json')
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

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'compact-report.ps1') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'compact report' } else { Mark-Fail 'compact report' }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'compact-apply.ps1') -ScriptArguments @('-WhatIfOnly') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'compact apply dry run' } else { Mark-Fail 'compact apply dry run' }

$compactApplyOutput = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'compact-apply.ps1')
if ($LASTEXITCODE -eq 0) {
  Mark-Ok 'compact apply guarded command'
} else {
  Mark-Fail 'compact apply guarded command'
}

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'backup-retention.ps1') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'backup retention dry run' } else { Mark-Fail 'backup retention dry run' }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'state.ps1') -ScriptArguments @('-Json') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'state cache read helper' } else { Mark-Fail 'state cache read helper' }

$memoryRecentOutput = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'recall-recent.ps1') -ScriptArguments @('-Count','1') -IncludeStderr
if ($LASTEXITCODE -eq 0) { Mark-Ok 'memory recent helper json' } else { Mark-Fail ('memory recent helper json ' + (($memoryRecentOutput | Select-Object -Last 1) -join ' ')) }

Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'test-recall.ps1') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'integrated recall tests' } else { Mark-Fail 'integrated recall tests' }
$testRecallJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'test-recall.ps1') -ScriptArguments @('-Json')
if ($LASTEXITCODE -eq 0) {
  try { $testRecallJsonText | ConvertFrom-Json | Out-Null; Mark-Ok 'integrated recall tests json' } catch { Mark-Fail "integrated recall tests json parse $($_.Exception.Message)" }
} else { Mark-Fail 'integrated recall tests json command' }
$memoryEvalJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'memory-eval.ps1') -ScriptArguments @('-Json')
if ($LASTEXITCODE -eq 0) {
  try {
    $memoryEvalJson = $memoryEvalJsonText | ConvertFrom-Json
    if ($memoryEvalJson.ok -eq $true -and $memoryEvalJson.total -gt 0 -and $null -ne $memoryEvalJson.metrics) { Mark-Ok 'memory eval harness json' } else { Mark-Fail 'memory eval harness json ok=false' }
  } catch { Mark-Fail "memory eval harness json parse $($_.Exception.Message)" }
} else { Mark-Fail 'memory eval harness command' }
Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'memory-eval-report.ps1') | Out-Null
if ($LASTEXITCODE -eq 0) { Mark-Ok 'memory eval report' } else { Mark-Fail 'memory eval report' }


if ($WithTempInstall) {
  $tmpRoot = Join-Path $Root '.tmp-verify-package'
  $policyPath = Get-SuperBrainSharingPolicyPath $Root
  $hadPolicy = Test-Path $policyPath
  $originalPolicy = if ($hadPolicy) { Get-Content -LiteralPath $policyPath -Raw -Encoding UTF8 } else { $null }
  if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
  $zSkills = Join-Path $tmpRoot 'zcode-skills'
  $codexSkills = Join-Path $tmpRoot 'codex-skills'
  $tmpStateRoot = Join-Path $tmpRoot 'state'
  $tmpMemory = Join-Path $tmpStateRoot 'shared'
  $tmpArchive = Join-Path $tmpRoot 'archive'
  $previousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  $previousArchiveRoot = $env:SUPER_BRAIN_ARCHIVE_ROOT
  try {
    # A temp install is a fully isolated host fixture.  The live-memory guard
    # accepts its shared root only when the fixture state root is explicit;
    # never bypass that guard with an arbitrary memory-path override.
    $env:SUPER_BRAIN_STATE_ROOT = $tmpStateRoot
    $env:SUPER_BRAIN_ARCHIVE_ROOT = $tmpArchive
    Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'install.ps1') -ScriptArguments @('-ZCodeSkills',$zSkills,'-CodexSkills',$codexSkills,'-Neurobase',$tmpMemory,'-IncludeZCode','-Isolated','-NoBackup') | Out-Null
    if ($LASTEXITCODE -eq 0) { Mark-Ok 'integrated temp install' } else { Mark-Fail 'integrated temp install' }

    if (Test-Path (Join-Path $tmpMemory '.memory-scope.json')) { Mark-Ok 'integrated temp memory scope marker' } else { Mark-Fail 'integrated temp memory scope marker missing' }

    foreach ($skillName in Get-SuperBrainSkillNames) {
      foreach ($skillRoot in @($zSkills,$codexSkills)) {
        $pkg = Test-SuperBrainPackageRootMarker (Join-Path $skillRoot $skillName) $Root
        $mem = Test-SuperBrainMemoryRootMarker (Join-Path $skillRoot $skillName)
        if ($pkg.ok -and $mem.ok) { Mark-Ok "integrated root marker $skillName" } else { Mark-Fail "integrated root marker $skillName" }
      }
    }

    $statusJsonText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'status.ps1') -ScriptArguments @('-ZCodeSkills',$zSkills,'-CodexSkills',$codexSkills,'-MemoryRoot',$tmpMemory,'-Isolated','-Json')
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
    if ($null -eq $previousStateRoot) { Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_STATE_ROOT = $previousStateRoot }
    if ($null -eq $previousArchiveRoot) { Remove-Item Env:\SUPER_BRAIN_ARCHIVE_ROOT -ErrorAction SilentlyContinue } else { $env:SUPER_BRAIN_ARCHIVE_ROOT = $previousArchiveRoot }
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

$statusDir = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path $statusDir)) { New-Item -ItemType Directory -Force -Path $statusDir | Out-Null }
$statusPath = Join-Path $statusDir 'last-verify-package.json'
$sourceTreeBinding = Get-SuperBrainSourceTreeBinding $Root
$status = [pscustomobject]@{
  schema = 'super-brain.verify-package-result.v1'
  runId = $RunId
  ok = $ok
  checkedAt = Get-SuperBrainUtcTimestamp
  packageRoot = $Root
  version = $manifest.version
  durationMs = [int](([DateTime]::UtcNow - $script:verifyStartedUtc).TotalMilliseconds)
  timeoutControlled = $true
  sourceTreeBinding = $sourceTreeBinding
  results = $results
  statusHash = ''
}
$status.statusHash = Get-VerifyPackageResultHash $status
Write-JsonUtf8NoBom $statusPath $status 6
Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'update-state.ps1') | Out-Null

$finalSnapshotOk = $false
try {
  $finalSnapshotText = Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') -ScriptArguments @('-Summary','verify-package final status','-NextAction',$(if ($status.ok) { 'Continue with the next user task.' } else { 'Resolve the latest verify-package failures.' }),'-Evidence','last-verify-package.json','update-state.ps1','-AllowActiveCheckpoint','-Json')
  $finalSnapshot = $finalSnapshotText | ConvertFrom-Json
  $finalSnapshotOk = (
    [string]$finalSnapshot.verifyCheckedAt -eq [string]$status.checkedAt -and
    [bool]$finalSnapshot.verifyOk -eq [bool]$status.ok -and
    [bool]$finalSnapshot.ok -eq [bool]$status.ok
  )
} catch {}
if (-not $finalSnapshotOk) {
  $ok = $false
  $results += [pscustomobject]@{ name = 'final status snapshot matches latest verification'; ok = $false }
  $status.ok = $false
  $status.results = $results
  $status.statusHash = Get-VerifyPackageResultHash $status
  Write-JsonUtf8NoBom $statusPath $status 6
  Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'update-state.ps1') | Out-Null
  Invoke-VerifyPackageCli -ScriptPath (Join-Path $PSScriptRoot 'status-snapshot-writer.ps1') -ScriptArguments @('-Summary','verify-package final status sync failed','-NextAction','Repair status snapshot synchronization.','-Evidence','last-verify-package.json','update-state.ps1','-Json') | Out-Null
}

$resultWritten = $true
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
  try {
    Write-JsonUtf8NoBom $ResultPath $status 16
    $resultRoundTrip = Test-VerifyPackageResultReceipt $ResultPath $RunId
    $resultWritten = ($resultRoundTrip.ok -eq $true -and $resultRoundTrip.receipt.ok -eq $status.ok)
  } catch { $resultWritten = $false }
}

if ($ok -and $resultWritten) { Write-Host "VERIFY_PACKAGE_OK $statusPath" } else { Write-Host "VERIFY_PACKAGE_FAILED $statusPath"; exit 1 }
