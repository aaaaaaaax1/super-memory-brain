param([switch]$Json)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$outPath = Join-Path $workspace 'last-autonomous-executor-e2e.json'
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
$currentTaskContextPath = Join-Path $workspace 'current-task-context.json'
$originalTaskContextText = if(Test-Path -LiteralPath $currentTaskContextPath){ Get-Content -LiteralPath $currentTaskContextPath -Raw -Encoding UTF8 } else { $null }
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
}

$taskName = 'autonomous e2e auto task'
try { Run-JsonAllowFail 'runtime-drift-checkpoint.ps1' @('-Phase','Clear') | Out-Null } catch {}
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
  $plan = Run-JsonAllowFail 'autonomous-executor.ps1' @('-Goal','how should autonomous executor work?','-TaskName','autonomous e2e question','-SessionTitle','autonomous e2e')
  Add-Check 'question-does-not-create-task' ($plan.ok -eq $true -and $plan.taskCard.shouldCreate -ne $true -and [string]::IsNullOrWhiteSpace([string]$plan.taskCard.taskId)) "intent=$($plan.intent.gate) taskId=$($plan.taskCard.taskId)"
} catch { Add-Check 'question-does-not-create-task' $false $_.Exception.Message }

$failed = @($checks | Where-Object { $_.ok -ne $true })
Restore-TaskContext
$result=[pscustomobject]@{ ok=($failed.Count -eq 0); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.autonomous-executor-e2e.v1'; version=(Get-SuperBrainManifest $Root).version; failed=$failed.Count; checks=@($checks); guard='Natural execute goals auto-create/update one task card; question/plan-only goals do not mutate; E2E restores current-task-context so test tasks do not pollute real task completion.'; path=$outPath }
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "AUTONOMOUS_EXECUTOR_E2E ok=$($result.ok) failed=$($result.failed) path=$outPath"}
if(-not $result.ok){exit 1}; exit 0
