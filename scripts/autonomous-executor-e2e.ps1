param([switch]$Json)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$originalStateRoot = $env:SUPER_BRAIN_STATE_ROOT
$realMemoryBase = Get-SuperBrainMemoryBaseRoot $Root
$realWorkspace = Join-Path $realMemoryBase 'workspace'
if(-not(Test-Path -LiteralPath $realWorkspace)){ New-Item -ItemType Directory -Force -Path $realWorkspace | Out-Null }
$sandboxParentRoot = Join-Path $realMemoryBase 'e2e'
$sandboxStateRoot = Join-Path $sandboxParentRoot ('a' + $PID + '-' + [guid]::NewGuid().ToString('n').Substring(0,8))
$env:SUPER_BRAIN_STATE_ROOT = $sandboxStateRoot
$workspace = Join-Path $sandboxStateRoot 'workspace'
$outPath = Join-Path $realWorkspace 'last-autonomous-executor-e2e.json'
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
$currentTaskContextPath = Join-Path $workspace 'current-task-context.json'
$originalTaskContextText = if(Test-Path -LiteralPath $currentTaskContextPath){ Get-Content -LiteralPath $currentTaskContextPath -Raw -Encoding UTF8 } else { $null }
$activeCheckpointPath = Join-Path $workspace 'active-checkpoint.json'
$originalCheckpointText = if(Test-Path -LiteralPath $activeCheckpointPath){ Get-Content -LiteralPath $activeCheckpointPath -Raw -Encoding UTF8 } else { $null }
$lastCompletedCheckpointPath = Join-Path $workspace 'last-completed-checkpoint.json'
$originalLastCompletedText = if(Test-Path -LiteralPath $lastCompletedCheckpointPath){ Get-Content -LiteralPath $lastCompletedCheckpointPath -Raw -Encoding UTF8 } else { $null }
$sessionTaskLinksPath = Join-Path (Join-Path $sharedRoot 'links') 'session-task-links.json'
$originalSessionTaskLinksText = if(Test-Path -LiteralPath $sessionTaskLinksPath){ Get-Content -LiteralPath $sessionTaskLinksPath -Raw -Encoding UTF8 } else { $null }
$taskMemoryLinksPath = Join-Path (Join-Path $sharedRoot 'links') 'task-memory-links.json'
$originalTaskMemoryLinksText = if(Test-Path -LiteralPath $taskMemoryLinksPath){ Get-Content -LiteralPath $taskMemoryLinksPath -Raw -Encoding UTF8 } else { $null }
$checks = New-Object System.Collections.ArrayList

function Remove-E2eSandbox {
  $sandboxFull = [IO.Path]::GetFullPath($sandboxStateRoot)
  $sandboxParent = [IO.Path]::GetFullPath($sandboxParentRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
  if($sandboxFull.StartsWith($sandboxParent,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $sandboxFull)){ Remove-Item -LiteralPath $sandboxFull -Recurse -Force }
}

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
function Run-AutonomousPlan([string]$Goal,[string]$TaskName,[string[]]$Steps){
  $raw = @(& (Join-Path $PSScriptRoot 'autonomous-executor.ps1') -Goal $Goal -TaskName $TaskName -SessionTitle 'autonomous e2e' -ApprovedPlan -PlanSteps $Steps -Json 2>&1)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $jsonStart = $text.IndexOf('{')
  if($jsonStart -ge 0){ try { return ($text.Substring($jsonStart) | ConvertFrom-Json) } catch {} }
  return [pscustomobject]@{ ok=$false; raw=$text }
}
function Remove-TaskArtifacts([string]$TaskId){
  foreach($dirName in @('active','paused','blocked','completed')){ $p=Join-Path (Join-Path (Join-Path $sharedRoot 'tasks') $dirName) ($TaskId + '.task.json'); if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Force } }
  $safe=(($TaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if(-not [string]::IsNullOrWhiteSpace($safe)){
    foreach($relative in @('goal-route-locks','route-checkpoints','integration-parity-check')){ $p=Join-Path (Join-Path (Join-Path $workspace 'guard-state') $relative) ($safe + '.json'); if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Force } }
    foreach($relative in @('change-causality','change-causality-reviews','integration-contract-replay')){ $p=Join-Path (Join-Path (Join-Path $workspace 'guard-state') $relative) $safe; if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Recurse -Force } }
  }
}
function Restore-TaskContext {
  if($null -ne $originalTaskContextText){ Write-Utf8NoBom $currentTaskContextPath $originalTaskContextText }
  elseif(Test-Path -LiteralPath $currentTaskContextPath){ Remove-Item -LiteralPath $currentTaskContextPath -Force }
  if($null -ne $originalCheckpointText){ Write-Utf8NoBom $activeCheckpointPath $originalCheckpointText }
  elseif(Test-Path -LiteralPath $activeCheckpointPath){ Remove-Item -LiteralPath $activeCheckpointPath -Force }
  foreach($item in @(
    [pscustomobject]@{ Path=$lastCompletedCheckpointPath; Text=$originalLastCompletedText },
    [pscustomobject]@{ Path=$sessionTaskLinksPath; Text=$originalSessionTaskLinksText },
    [pscustomobject]@{ Path=$taskMemoryLinksPath; Text=$originalTaskMemoryLinksText }
  )) {
    if($null -ne $item.Text){ Write-Utf8NoBom $item.Path ([string]$item.Text) }
    elseif(Test-Path -LiteralPath $item.Path){ Remove-Item -LiteralPath $item.Path -Force }
  }
}

try {
$taskName = 'autonomous e2e auto task'
try { Run-JsonAllowFail 'runtime-drift-checkpoint.ps1' @('-Phase','Clear') | Out-Null } catch {}
try { Run-JsonAllowFail 'checkpoint-writer.ps1' @('-Action','Clear') | Out-Null } catch {}
try {
  $first = Run-JsonAllowFail 'autonomous-executor.ps1' @('-Goal','start autonomous e2e auto task','-TaskName',$taskName,'-SessionTitle','autonomous e2e')
  $taskId = [string]$first.taskCard.taskId
  Add-Check 'execute-intent-auto-creates-task' ($first.ok -eq $true -and $first.taskCard.shouldCreate -eq $true -and -not [string]::IsNullOrWhiteSpace($taskId)) "taskId=$taskId intent=$($first.intent.gate)"
  Add-Check 'superbrain_optimization_execution_control_hard_gate' ($first.executionHardGate.required -eq $true -and $first.executionHardGate.taskCardOk -eq $true -and $first.executionHardGate.currentTaskContextOk -eq $true -and $first.executionHardGate.routeLockOk -eq $true -and $first.executionHardGate.acceptedConstraintsOk -eq $true -and $first.executionHardGate.cognitivePreflightOk -eq $true -and $first.executionHardGate.runtimeDriftOk -eq $true) "task=$($first.executionHardGate.taskCardOk) context=$($first.executionHardGate.currentTaskContextOk) route=$($first.executionHardGate.routeLockOk) constraints=$($first.executionHardGate.acceptedConstraintsOk) cognitive=$($first.executionHardGate.cognitivePreflightOk) drift=$($first.executionHardGate.runtimeDriftOk)"
  $covered=@($first.executionHardGate.capabilitiesCovered)
  Add-Check 'six_self_assessment_capabilities_are_tracked' (@('rule_auto_application','current_task_detection','real_user_path_acceptance','self_learning_loop_hook','multi_agent_non_regression','compact_report_discipline') | Where-Object { $covered -notcontains $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }) "covered=$($covered -join ',')"
  Add-Check 'rule_skills_are_fused_as_execution_constraints' (@('rule_skill_fusion','ponytail_minimal_safe_change','grill_me_challenge_and_acceptance') | Where-Object { $covered -notcontains $_ } | Measure-Object | ForEach-Object { $_.Count -eq 0 }) "ruleSkills=$($first.executionHardGate.ruleSkillFusion.mode); ponytail=$(-not [string]::IsNullOrWhiteSpace([string]$first.executionHardGate.ruleSkillFusion.ponytail)); grillMe=$(-not [string]::IsNullOrWhiteSpace([string]$first.executionHardGate.ruleSkillFusion.grillMe))"
  $second = Run-JsonAllowFail 'autonomous-executor.ps1' @('-Goal','continue autonomous e2e auto task','-TaskName',$taskName,'-SessionTitle','autonomous e2e')
  Add-Check 'auto-register-reuses-task-card' ($second.taskCard.taskId -eq $taskId) "first=$taskId second=$($second.taskCard.taskId)"
  if(-not [string]::IsNullOrWhiteSpace($taskId)){ Remove-TaskArtifacts $taskId }
} catch { Add-Check 'execute-auto-flow' $false $_.Exception.Message }

try {
  $twoStep = Run-AutonomousPlan 'apply approved two step plan' 'autonomous e2e two step' @('inspect','verify')
  Add-Check 'two-step-plan-does-not-auto-checkpoint' ($twoStep.ok -eq $true -and $twoStep.checkpoint.created -ne $true -and -not (Test-Path -LiteralPath $activeCheckpointPath)) "created=$($twoStep.checkpoint.created) steps=$($twoStep.checkpoint.stepCount)"
  if($twoStep.taskCard.taskId){ Remove-TaskArtifacts ([string]$twoStep.taskCard.taskId) }

  $threeStep = Run-AutonomousPlan 'apply approved three step plan' 'autonomous e2e three step' @('inspect','change','verify')
  $active = if(Test-Path -LiteralPath $activeCheckpointPath){ Get-Content -LiteralPath $activeCheckpointPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
  Add-Check 'approved-three-step-plan-auto-checkpoints' ($threeStep.ok -eq $true -and $threeStep.checkpoint.created -eq $true -and $active -and [string]$active.taskId -eq [string]$threeStep.taskCard.taskId -and @($active.pendingSteps).Count -eq 3) "created=$($threeStep.checkpoint.created) taskId=$($active.taskId) steps=$(@($active.pendingSteps).Count)"
  $authorizationPath = if($threeStep.taskCard.taskId){ Join-Path $workspace ("runtime-state\autonomy-authorizations\" + [string]$threeStep.taskCard.taskId + '.json') }else{''}
  $authorization = if($authorizationPath -and (Test-Path -LiteralPath $authorizationPath)){ Get-Content -LiteralPath $authorizationPath -Raw -Encoding UTF8 | ConvertFrom-Json }else{$null}
  Add-Check 'approved-three-step-plan-writes-private-autonomy-authorization' ($threeStep.autonomyAuthorization.created -eq $true -and $authorization -and [string]$authorization.schema -eq 'super-brain.governed-autonomy-authorization.v1' -and [string]$authorization.taskId -eq [string]$threeStep.taskCard.taskId -and $authorization.executionHardGateOk -eq $true -and $authorization.checkpointCreated -eq $true -and $authorization.rawGoalStored -eq $false -and $authorization.rawPromptStored -eq $false) "created=$($threeStep.autonomyAuthorization.created) taskId=$($authorization.taskId) private=$($authorization.rawGoalStored -eq $false -and $authorization.rawPromptStored -eq $false)"
  Run-JsonAllowFail 'checkpoint-writer.ps1' @('-Action','Complete','-TaskId',[string]$active.taskId,'-VerificationResults','e2e verified') | Out-Null
  Add-Check 'completed-checkpoint-is-cleared' (-not (Test-Path -LiteralPath $activeCheckpointPath)) 'checkpoint-writer Complete removes active checkpoint after supplied verification result'
  if($threeStep.taskCard.taskId){ Remove-TaskArtifacts ([string]$threeStep.taskCard.taskId) }

  $statusWordPlan = Run-AutonomousPlan 'what remains in the approved release verification?' 'autonomous e2e approved status wording' @('inspect','change','verify')
  Add-Check 'approved-plan-overrides-status-wording' ($statusWordPlan.ok -eq $true -and $statusWordPlan.intent.gate -eq 'status_only' -and $statusWordPlan.taskCard.shouldCreate -eq $true -and $statusWordPlan.checkpoint.created -eq $true) "intent=$($statusWordPlan.intent.gate) task=$($statusWordPlan.taskCard.shouldCreate) checkpoint=$($statusWordPlan.checkpoint.created)"
  if($statusWordPlan.taskCard.taskId){ Run-JsonAllowFail 'checkpoint-writer.ps1' @('-Action','Complete','-TaskId',[string]$statusWordPlan.taskCard.taskId,'-VerificationResults','approved status wording verified') | Out-Null; Remove-TaskArtifacts ([string]$statusWordPlan.taskCard.taskId) }
} catch { Add-Check 'approved-plan-checkpoint-flow' $false $_.Exception.Message }

try {
  $plan = Run-JsonAllowFail 'autonomous-executor.ps1' @('-Goal','how should autonomous executor work?','-TaskName','autonomous e2e question','-SessionTitle','autonomous e2e')
  Add-Check 'question-does-not-create-task' ($plan.ok -eq $true -and $plan.taskCard.shouldCreate -ne $true -and [string]::IsNullOrWhiteSpace([string]$plan.taskCard.taskId)) "intent=$($plan.intent.gate) taskId=$($plan.taskCard.taskId)"
} catch { Add-Check 'question-does-not-create-task' $false $_.Exception.Message }

$failed = @($checks | Where-Object { $_.ok -ne $true })
Restore-TaskContext
$result=[pscustomobject]@{ ok=($failed.Count -eq 0); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.autonomous-executor-e2e.v1'; version=(Get-SuperBrainManifest $Root).version; failed=$failed.Count; checks=@($checks); guard='Natural execute goals and threshold-approved plans create task checkpoints; question/plan-only goals do not mutate; E2E runs under an isolated state root.'; path=$outPath }
Write-JsonUtf8NoBom $outPath $result 12
$jsonText = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8
$exitCode = if($result.ok){0}else{1}
} finally {
  $env:SUPER_BRAIN_STATE_ROOT = $originalStateRoot
  Remove-E2eSandbox
}
if($Json){$jsonText}else{Write-Host "AUTONOMOUS_EXECUTOR_E2E ok=$($result.ok) failed=$($result.failed) path=$outPath"}
exit $exitCode
