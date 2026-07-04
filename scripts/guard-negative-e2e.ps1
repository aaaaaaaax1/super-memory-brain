param([switch]$Json)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
$outPath = Join-Path $workspace 'last-guard-negative-e2e.json'
$lastStateNames = @('current-task-context.json','last-route-checkpoint.json','route-checkpoint.json','last-integration-parity-check.json','last-integration-contract-replay.json','last-causal-change-review.json')
$guardStateRoot = Join-Path $workspace 'guard-state'
$guardStateBackup = Join-Path $workspace ('guard-state.backup.' + [guid]::NewGuid().ToString('n'))
if (Test-Path -LiteralPath $guardStateRoot) { Copy-Item -LiteralPath $guardStateRoot -Destination $guardStateBackup -Recurse -Force }
$lastStateBackup = @{}
foreach ($name in $lastStateNames) { $p = Join-Path $workspace $name; if (Test-Path -LiteralPath $p) { $lastStateBackup[$name] = Get-Content -LiteralPath $p -Raw -Encoding UTF8 } }
$checks = New-Object System.Collections.ArrayList

function Add-Check([string]$Name,[bool]$Ok,[string]$Evidence){ [void]$checks.Add([pscustomobject]@{ name=$Name; ok=$Ok; evidence=$Evidence }) }
function Run-JsonAllowFail([string]$ScriptName,[string[]]$ScriptArgs){
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  $quotedArgs = @($ScriptArgs | ForEach-Object { if ($_ -like '-*') { $_ } else { "'" + (($_ -replace "'", "''")) + "'" } })
  $command = "& '$scriptPath' $($quotedArgs -join ' ') -Json"
  $output = Invoke-Expression $command 2>&1
  $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
  $jsonStart = $text.IndexOf('{')
  if ($jsonStart -ge 0) { try { return ($text.Substring($jsonStart) | ConvertFrom-Json) } catch {} }
  return [pscustomobject]@{ ok=$false; raw=$text }
}

$oldTask = 'negative-old-task'
$newTask = 'negative-new-task'

try {
  $null = Run-JsonAllowFail 'current-task-context.ps1' @('-Action','Create','-TaskId',$newTask,'-AcceptedGoal','negative e2e current task','-AcceptedRoute','negative checks')
  $null = Run-JsonAllowFail 'goal-route-lock.ps1' @('-Action','Create','-TaskId',$oldTask,'-AcceptedGoal','old task','-AcceptedRoute','old route','-ApprovalEvidence','negative-e2e')
  $null = Run-JsonAllowFail 'route-checkpoint.ps1' @('-Phase','BeforeCompletion','-TaskId',$oldTask,'-ObservedAction','old task completed')
  $stale = Run-JsonAllowFail 'completion-guard.ps1' @('-TaskId',$newTask,'-AllowPrivacyRisk','-AllowActiveCheckpoint')
  $staleCheck = @($stale.checks | Where-Object { $_.name -eq 'task-scoped-route-checkpoint' }) | Select-Object -First 1
  Add-Check 'stale-route-checkpoint-rejected' ($stale.ok -ne $true -or ($staleCheck -and $staleCheck.ok -ne $true)) "completionOk=$($stale.ok) scopedRouteOk=$($staleCheck.ok)"
} catch { Add-Check 'stale-route-checkpoint-rejected' $false $_.Exception.Message }

try {
  $null = Run-JsonAllowFail 'verified-module-snapshot.ps1' @('-Action','Create','-Module','negative-demo','-VerifiedBehavior','echo ok','-Entrypoint','demo','-Outputs','ok','-VerificationCommand','negative-e2e','-Evidence','module ok')
  $mismatch = Run-JsonAllowFail 'integration-contract-replay.ps1' @('-TaskId',$newTask,'-Module','negative-demo','-ExpectedOutput','ok','-IntegratedCommand','Write-Output bad')
  Add-Check 'integration-behavior-mismatch-blocked' ($mismatch.ok -ne $true -and $mismatch.unresolvedBehaviorMismatch -eq $true) "ok=$($mismatch.ok) mismatches=$(@($mismatch.mismatches).Count)"
} catch { Add-Check 'integration-behavior-mismatch-blocked' $false $_.Exception.Message }

try {
  $acceptance = Run-JsonAllowFail 'integration-parity-check.ps1' @('-TaskId',$newTask,'-Module','negative-demo','-CurrentEntrypoint','demo','-IntegrationCommand','negative-e2e','-ModuleSmokeOk','-IntegrationSmokeOk','-UserAcceptanceOk')
  $code = @($acceptance.drifts | ForEach-Object { $_.code }) -contains 'missing_user_acceptance_evidence'
  Add-Check 'acceptance-ok-requires-evidence' ($acceptance.ok -ne $true -and $code) "ok=$($acceptance.ok) drifts=$(@($acceptance.drifts).Count)"
} catch { Add-Check 'acceptance-ok-requires-evidence' $false $_.Exception.Message }

try {
  $weakAcceptance = Run-JsonAllowFail 'integration-parity-check.ps1' @('-TaskId',$newTask,'-Module','negative-demo','-CurrentEntrypoint','demo','-IntegrationCommand','negative-e2e','-UserAcceptanceEvidence','looks good','-ModuleSmokeOk','-IntegrationSmokeOk','-UserAcceptanceOk')
  $weakCode = @($weakAcceptance.drifts | ForEach-Object { $_.code }) -contains 'weak_user_acceptance_evidence'
  Add-Check 'weak-acceptance-evidence-rejected' ($weakAcceptance.ok -ne $true -and $weakCode) "ok=$($weakAcceptance.ok) drifts=$(@($weakAcceptance.drifts).Count)"
} catch { Add-Check 'weak-acceptance-evidence-rejected' $false $_.Exception.Message }

try {
  $null = Run-JsonAllowFail 'current-task-context.ps1' @('-Action','Create','-TaskId',$newTask,'-AcceptedGoal','negative e2e current task','-AcceptedRoute','negative checks')
  $null = Run-JsonAllowFail 'verified-module-snapshot.ps1' @('-Action','Create','-Module','negative-context-demo','-VerifiedBehavior','echo ok','-Entrypoint','demo','-Outputs','ok','-VerificationCommand','negative-e2e','-Evidence','module ok')
  $parityInherited = Run-JsonAllowFail 'integration-parity-check.ps1' @('-Module','negative-context-demo','-CurrentEntrypoint','demo','-IntegrationCommand','negative-e2e','-UserAcceptanceEvidence','negative-e2e actual output ok','-ModuleSmokeOk','-IntegrationSmokeOk','-UserAcceptanceOk')
  $replayInherited = Run-JsonAllowFail 'integration-contract-replay.ps1' @('-Module','negative-context-demo','-ExpectedOutput','ok','-IntegratedCommand','Write-Output ok')
  Add-Check 'current-task-context-auto-inherited' (($parityInherited.taskId -eq $newTask) -and ($replayInherited.taskId -eq $newTask)) "parityTaskId=$($parityInherited.taskId) replayTaskId=$($replayInherited.taskId)"
} catch { Add-Check 'current-task-context-auto-inherited' $false $_.Exception.Message }

try {
  $freshTask = 'negative-fresh-task-no-parity'
  $null = Run-JsonAllowFail 'current-task-context.ps1' @('-Action','Create','-TaskId',$freshTask,'-AcceptedGoal','fresh task without parity','-AcceptedRoute','negative checks')
  $null = Run-JsonAllowFail 'integration-parity-check.ps1' @('-TaskId',$oldTask,'-Module','negative-context-demo','-CurrentEntrypoint','demo','-IntegrationCommand','old-e2e','-UserAcceptanceEvidence','old accepted','-ModuleSmokeOk','-IntegrationSmokeOk','-UserAcceptanceOk')
  $staleParity = Run-JsonAllowFail 'completion-guard.ps1' @('-TaskId',$freshTask,'-AllowPrivacyRisk','-AllowActiveCheckpoint')
  $parityScope = @($staleParity.checks | Where-Object { $_.name -eq 'task-scoped-integration-parity' }) | Select-Object -First 1
  Add-Check 'old-integration-parity-cannot-satisfy-current-task' ($parityScope -and $parityScope.ok -ne $true) "completionOk=$($staleParity.ok) scopedParityOk=$($parityScope.ok) requiredTask=negative-fresh-task-no-parity"
  $null = Run-JsonAllowFail 'current-task-context.ps1' @('-Action','Create','-TaskId',$newTask,'-AcceptedGoal','negative e2e current task','-AcceptedRoute','negative checks')
} catch { Add-Check 'old-integration-parity-cannot-satisfy-current-task' $false $_.Exception.Message }

try {
  $exitMismatch = Run-JsonAllowFail 'integration-contract-replay.ps1' @('-TaskId',$newTask,'-Module','negative-demo','-ExpectedOutput','ok','-IntegratedCommand','$global:LASTEXITCODE = 7; Write-Output ok','-ExpectedExitCode','0')
  $hasExitMismatch = @($exitMismatch.mismatches | ForEach-Object { $_.code }) -contains 'integration_command_exit_code_mismatch'
  Add-Check 'integrated-command-exit-code-blocked' ($exitMismatch.ok -ne $true -and $hasExitMismatch) "ok=$($exitMismatch.ok) mismatches=$(@($exitMismatch.mismatches).Count)"
} catch { Add-Check 'integrated-command-exit-code-blocked' $false $_.Exception.Message }

try {
  $scope = Run-JsonAllowFail 'lesson-scope-gate.ps1' @('-Lesson','Never use this approach anywhere','-Confidence','0.9')
  Add-Check 'broad-lesson-rejected' ($scope.ok -ne $true -and @($scope.gaps).Count -gt 0) "ok=$($scope.ok) gaps=$(@($scope.gaps).Count)"
} catch { Add-Check 'broad-lesson-rejected' $false $_.Exception.Message }

try {
  $missingValidation = Run-JsonAllowFail 'lesson-scope-gate.ps1' @('-Lesson','Use scoped task cards for approved plans','-Scope','approved multi-step tasks','-Evidence','user correction 2026-06-29','-AppliesWhen','approved multi-step execution','-DoesNotApplyWhen','ordinary Q&A','-CounterExamples','one-off small edit','-Confidence','0.8')
  $validationCode = @($missingValidation.gaps | ForEach-Object { $_.code }) -contains 'missing_validation_conditions'
  Add-Check 'lesson-validation-conditions-required' ($missingValidation.ok -ne $true -and $validationCode) "ok=$($missingValidation.ok) gaps=$(@($missingValidation.gaps).Count)"
} catch { Add-Check 'lesson-validation-conditions-required' $false $_.Exception.Message }

try {
  $null = Run-JsonAllowFail 'goal-route-lock.ps1' @('-Action','Create','-TaskId',$newTask,'-AcceptedGoal','negative e2e current task','-AcceptedRoute','stay scoped','-NonGoals','unrelated cleanup','-MustNotDriftTo','unrelated cleanup','-ApprovalEvidence','negative-e2e')
  $route = Run-JsonAllowFail 'route-checkpoint.ps1' @('-Phase','BeforeCompletion','-TaskId',$newTask,'-ObservedAction','expand scope to unrelated cleanup')
  Add-Check 'scope-creep-route-drift-blocked' ($route.ok -ne $true -and $route.unresolvedRouteDrift -eq $true) "ok=$($route.ok) status=$($route.status) violations=$(@($route.violations).Count)"
} catch { Add-Check 'scope-creep-route-drift-blocked' $false $_.Exception.Message }

try { $null = Run-JsonAllowFail 'route-checkpoint.ps1' @('-Phase','Clear','-TaskId',$newTask) } catch {}
try { $null = Run-JsonAllowFail 'current-task-context.ps1' @('-Action','Clear') } catch {}
foreach ($name in $lastStateNames) {
  $p = Join-Path $workspace $name
  if ($lastStateBackup.ContainsKey($name)) { Write-Utf8NoBom $p ([string]$lastStateBackup[$name]) }
  elseif (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
if (Test-Path -LiteralPath $guardStateRoot) { Remove-Item -LiteralPath $guardStateRoot -Recurse -Force }
if (Test-Path -LiteralPath $guardStateBackup) { Move-Item -LiteralPath $guardStateBackup -Destination $guardStateRoot -Force }
$failed = @($checks | Where-Object { $_.ok -ne $true })
$result = [pscustomobject]@{ ok=($failed.Count -eq 0); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.guard-negative-e2e.v1'; version=(Get-SuperBrainManifest $Root).version; failed=$failed.Count; checks=@($checks); guard='Negative E2E proves stale task evidence, behavior mismatch, missing acceptance evidence, broad lessons, and scope creep are blocked.'; path=$outPath }
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "GUARD_NEGATIVE_E2E ok=$($result.ok) failed=$($result.failed) path=$outPath"}
if(-not $result.ok){exit 1}; exit 0
