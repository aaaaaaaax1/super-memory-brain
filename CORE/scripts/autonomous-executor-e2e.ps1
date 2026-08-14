param(
  [switch]$Json,
  [string]$OutputPath = '',
  [switch]$KeepSandbox
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$originalStateRoot = $env:SUPER_BRAIN_STATE_ROOT
$originalWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
$realMemoryBase = Get-SuperBrainMemoryBaseRoot $Root
$realWorkspace = Join-Path $realMemoryBase 'workspace'
if(-not(Test-Path -LiteralPath $realWorkspace)){ New-Item -ItemType Directory -Force -Path $realWorkspace | Out-Null }
# Keep ephemeral integration state short and outside private memory. Deep
# package paths plus immutable telemetry filenames can exceed Windows' legacy
# file API limit before the feature itself has a chance to run.
$sandboxParentRoot = Join-Path ([IO.Path]::GetTempPath()) 'super-brain-e2e'
$sandboxStateRoot = Join-Path $sandboxParentRoot ('a' + $PID + '-' + [guid]::NewGuid().ToString('n').Substring(0,8))
$env:SUPER_BRAIN_STATE_ROOT = $sandboxStateRoot
$workspace = Join-Path $sandboxStateRoot 'workspace'
$outPath = if([string]::IsNullOrWhiteSpace($OutputPath)){
  Join-Path $realWorkspace 'last-autonomous-executor-e2e.json'
} else {
  [IO.Path]::GetFullPath($OutputPath)
}
$outDirectory = Split-Path -Parent $outPath
if(-not [string]::IsNullOrWhiteSpace($outDirectory) -and -not(Test-Path -LiteralPath $outDirectory)){
  New-Item -ItemType Directory -Force -Path $outDirectory | Out-Null
}
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
function Get-E2eFingerprint([string]$Value){
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))[0..7] | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}
function Get-E2eSha256([string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){return ''}
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}
function Write-E2eCanonicalMutation([string]$Name,[object]$Value,[string]$StateRoot=$sandboxStateRoot){
  $path = Join-Path $StateRoot ('mutations\\' + $Name + '.json')
  $directory = Split-Path -Parent $path
  if(-not(Test-Path -LiteralPath $directory)){ New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  [IO.File]::WriteAllText($path,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  return $path
}
function Write-E2ePhaseEvidence([string]$Name,[object]$Value,[string]$WorkspaceRoot){
  $root = Join-Path $WorkspaceRoot 'runtime-state\phase-evidence'
  if(-not(Test-Path -LiteralPath $root)){ New-Item -ItemType Directory -Force -Path $root | Out-Null }
  $path = Join-Path $root ($Name + '.json')
  [IO.File]::WriteAllText($path,($Value | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{ path=$path; relativePath=($Name + '.json'); sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function New-E2eCanonicalMutation(
  [object]$Contract,
  [string]$Operation,
  [string]$TransitionId,
  [string]$Instruction,
  [object[]]$Items=@(),
  [string[]]$TargetItemIds=@(),
  [string]$Status='',
  [string[]]$EvidenceRefs=@()
){
  return [pscustomobject]@{
    schema='super-brain.canonical-plan-mutation.v1'
    targetScope='canonical_main'
    operation=$Operation
    targetItemIds=@($TargetItemIds)
    items=@($Items)
    status=$Status
    evidenceRefs=@($EvidenceRefs)
    approvalSource=if($Operation -eq 'set_status'){'verified_status_transition'}else{'user_confirmation'}
    userInstructionFingerprint=Get-E2eFingerprint $Instruction
    expectedPlanId=[string]$Contract.canonicalPlan.planId
    expectedGeneration=[int]$Contract.canonicalPlan.generation
    expectedRevision=[int]$Contract.revision
    expectedFingerprint=[string]$Contract.canonicalPlan.currentFingerprint
    transitionId=$TransitionId
  }
}
function Invoke-E2eContract([string[]]$Arguments){
  return Run-JsonAllowFail 'execution-contract.ps1' $Arguments
}
function Invoke-E2eCheckpoint([string[]]$Arguments){
  return Run-JsonAllowFail 'checkpoint-writer.ps1' $Arguments
}
function Invoke-E2eHook([string]$Prompt,[string]$SessionKey){
  $hook = Join-Path $PSScriptRoot 'codex-user-prompt-hook.ps1'
  $payload = ([pscustomobject]@{session_id=$SessionKey;prompt=$Prompt} | ConvertTo-Json -Compress)
  # A PowerShell -File parent does not reliably forward stdin to a nested
  # PowerShell -File child. The launcher is a real stdin hop, not a mock.
  $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
  $hookBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($hook))
  $launcher = '$payload=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $payloadBase64 + ''')); $hook=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $hookBase64 + ''')); $payload | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hook'
  $launcherBase64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcher))
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $launcherBase64 2>&1)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $exitCode = $LASTEXITCODE
  $jsonStart = $text.IndexOf('{')
  if($jsonStart -ge 0){
    try {
      $value = $text.Substring($jsonStart) | ConvertFrom-Json
      $value | Add-Member -NotePropertyName e2eRaw -NotePropertyValue $text -Force
      $value | Add-Member -NotePropertyName e2eExitCode -NotePropertyValue $exitCode -Force
      return $value
    } catch {}
  }
  return [pscustomobject]@{ hookSpecificOutput=[pscustomobject]@{additionalContext=''};raw=$text;exitCode=$exitCode }
}
function Invoke-E2eNativeHook([string]$Prompt,[string]$SessionKey){
  $hook = Join-Path $Root 'runtime\codex_prompt_hook.py'
  $raw = @(& python -X utf8 -B $hook --package-root $Root --test-prompt $Prompt --test-session-id $SessionKey --test-observe-only 2>&1)
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $exitCode = $LASTEXITCODE
  $jsonStart = $text.IndexOf('{')
  $value = $null
  if($jsonStart -ge 0){try{$value=$text.Substring($jsonStart)|ConvertFrom-Json}catch{}}
  $context = if($value -and $value.hookSpecificOutput){[string]$value.hookSpecificOutput.additionalContext}else{''}
  return [pscustomobject]@{ok=($exitCode -eq 0 -and $value -and [string]$value.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit');exitCode=$exitCode;value=$value;context=$context;raw=$text}
}
function New-E2eNativeHookObservation([object]$Hook,[string]$StateRoot,[string]$SessionKey,[string]$WorkspaceKey){
  $relative = 'runtime-state\prompt-hook-telemetry\' + $SessionKey + '--' + $WorkspaceKey + '.json'
  $path = Join-Path (Join-Path $StateRoot 'workspace') $relative
  $telemetry = if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
  $context = if($Hook){[string]$Hook.context}else{''}
  $provenance = if($telemetry -and $telemetry.PSObject.Properties['deliveryProvenance']){$telemetry.deliveryProvenance}else{$null}
  $native = ($Hook -and $Hook.ok -eq $true -and $telemetry -and [string]$telemetry.routeSignalMode -eq 'native' -and $telemetry.testObservationOnly -eq $true -and $provenance -and [string]$provenance.origin -eq 'synthetic_cli')
  return [pscustomobject]@{
    source='synthetic_native_cli';status=if($native){'passed'}else{'failed'};exitCode=if($Hook){[int]$Hook.exitCode}else{-1}
    eventName=if($Hook -and $Hook.value -and $Hook.value.hookSpecificOutput){[string]$Hook.value.hookSpecificOutput.hookEventName}else{''}
    actionAuthorization=if($context.Contains('actionAuthorization=withheld')){'withheld'}else{''};contextSha256=Get-E2eSha256 $context
    telemetryRelativePath=$relative;telemetrySha256=if(Test-Path -LiteralPath $path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}
    deliveryProvenance=$provenance
    rawPromptStored=$false;rawTranscriptStored=$false;rawSessionIdStored=$false
  }
}
function Write-E2eBehaviorEvidence([string]$Name,[string]$Kind,[string]$ScenarioId,[object]$Contract,[object[]]$Observations,[string]$WorkspaceRoot){
  $artifact=[pscustomobject]@{
    schema='super-brain.phase-behavior-evidence.v1';kind=$Kind;producer='super-brain.behavior-capture.v1';scenarioId=$ScenarioId;ok=(@($Observations).Count -gt 0)
    taskId=[string]$Contract.taskId;workspaceKey=[string]$Contract.workspaceKey;ownerSessionKey=[string]$Contract.ownerSessionKey;packageVersion=[string](Get-SuperBrainManifest $Root).version
    contractRevision=[int]$Contract.revision;planFingerprint=[string]$Contract.planReceipt.planFingerprint;phase=[string]$Contract.currentPhase;phaseEvidencePolicy=if($Contract.PSObject.Properties['phaseEvidencePolicy']){[string]$Contract.phaseEvidencePolicy}else{'host_user_attested'};observations=@($Observations)
    rawPromptStored=$false;rawTranscriptStored=$false;rawSessionIdStored=$false
  }
  return Write-E2ePhaseEvidence $Name $artifact $WorkspaceRoot
}
function Remove-TaskArtifacts([string]$TaskId,[string]$WorkspaceRoot=$workspace){
  foreach($dirName in @('active','paused','blocked','completed')){ $p=Join-Path (Join-Path (Join-Path $sharedRoot 'tasks') $dirName) ($TaskId + '.task.json'); if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Force } }
  $safe=(($TaskId -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if(-not [string]::IsNullOrWhiteSpace($safe)){
    foreach($relative in @('goal-route-locks','route-checkpoints','integration-parity-check')){ $p=Join-Path (Join-Path (Join-Path $WorkspaceRoot 'guard-state') $relative) ($safe + '.json'); if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Force } }
    foreach($relative in @('change-causality','change-causality-reviews','integration-contract-replay')){ $p=Join-Path (Join-Path (Join-Path $WorkspaceRoot 'guard-state') $relative) $safe; if(Test-Path -LiteralPath $p){ Remove-Item -LiteralPath $p -Recurse -Force } }
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
# Runtime drift state is task-scoped. Never clear a legacy global checkpoint
# before this test has established the task identity it is allowed to mutate.
try { Run-JsonAllowFail 'checkpoint-writer.ps1' @('-Action','Clear') | Out-Null } catch {}
try {
  $first = Run-JsonAllowFail 'autonomous-executor.ps1' @('-Goal','start autonomous e2e auto task','-TaskName',$taskName,'-SessionTitle','autonomous e2e')
  $taskId = [string]$first.taskCard.taskId
  Add-Check 'execute-intent-auto-creates-task' ($first.ok -eq $true -and $first.taskCard.shouldCreate -eq $true -and -not [string]::IsNullOrWhiteSpace($taskId)) "taskId=$taskId intent=$($first.intent.gate)"
  $contract = if($first.executionContract.path-and(Test-Path -LiteralPath ([string]$first.executionContract.path))){Get-Content -LiteralPath ([string]$first.executionContract.path) -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
  $context = if(Test-Path -LiteralPath $currentTaskContextPath){Get-Content -LiteralPath $currentTaskContextPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
  Add-Check 'autonomous-executor-creates-session-bound-contract' ($first.executionContract.ok -eq $true -and $contract -and [string]$contract.taskId -eq $taskId -and $contract.sessionBound -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$contract.ownerSessionKey)) "contract=$($first.executionContract.ok) owner=$($first.executionContract.ownerSessionKey)"
  Add-Check 'autonomous-executor-creates-authorizing-context' ($first.executionHardGate.contextBindingOk -eq $true -and $context -and [string]$context.bindingState -eq 'bound' -and [string]$context.authorizationState -eq 'authorizing' -and [string]$context.ownerSessionKey -eq [string]$contract.ownerSessionKey) "binding=$($first.executionHardGate.contextBindingOk) context=$($context.bindingState)"
  Add-Check 'superbrain_optimization_execution_control_hard_gate' ($first.executionHardGate.required -eq $true -and $first.executionHardGate.taskCardOk -eq $true -and $first.executionHardGate.currentTaskContextOk -eq $true -and $first.executionHardGate.executionContractOk -eq $true -and $first.executionHardGate.contextBindingOk -eq $true -and $first.executionHardGate.routeLockOk -eq $true -and $first.executionHardGate.acceptedConstraintsOk -eq $true -and $first.executionHardGate.cognitivePreflightOk -eq $true -and $first.executionHardGate.runtimeDriftOk -eq $true) "task=$($first.executionHardGate.taskCardOk) context=$($first.executionHardGate.currentTaskContextOk) contract=$($first.executionHardGate.executionContractOk) route=$($first.executionHardGate.routeLockOk) constraints=$($first.executionHardGate.acceptedConstraintsOk) cognitive=$($first.executionHardGate.cognitivePreflightOk) drift=$($first.executionHardGate.runtimeDriftOk)"
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
  Run-JsonAllowFail 'checkpoint-writer.ps1' @('-Action','Clear','-TaskId',[string]$active.taskId) | Out-Null
  Add-Check 'completed-checkpoint-is-cleared' (-not (Test-Path -LiteralPath $activeCheckpointPath)) 'checkpoint-writer Complete removes active checkpoint after supplied verification result'
  if($threeStep.taskCard.taskId){ Remove-TaskArtifacts ([string]$threeStep.taskCard.taskId) }

  $statusWordPlan = Run-AutonomousPlan 'what remains in the approved release verification?' 'autonomous e2e approved status wording' @('inspect','change','verify')
  Add-Check 'approved-plan-overrides-status-wording' ($statusWordPlan.ok -eq $true -and $statusWordPlan.intent.gate -eq 'status_only' -and $statusWordPlan.taskCard.shouldCreate -eq $true -and $statusWordPlan.checkpoint.created -eq $true) "intent=$($statusWordPlan.intent.gate) task=$($statusWordPlan.taskCard.shouldCreate) checkpoint=$($statusWordPlan.checkpoint.created)"
  if($statusWordPlan.taskCard.taskId){ Run-JsonAllowFail 'checkpoint-writer.ps1' @('-Action','Clear','-TaskId',[string]$statusWordPlan.taskCard.taskId) | Out-Null; Remove-TaskArtifacts ([string]$statusWordPlan.taskCard.taskId) }
} catch { Add-Check 'approved-plan-checkpoint-flow' $false $_.Exception.Message }

try {
  $plan = Run-JsonAllowFail 'autonomous-executor.ps1' @('-Goal','how should autonomous executor work?','-TaskName','autonomous e2e question','-SessionTitle','autonomous e2e')
  Add-Check 'question-does-not-create-task' ($plan.ok -eq $true -and $plan.taskCard.shouldCreate -ne $true -and [string]::IsNullOrWhiteSpace([string]$plan.taskCard.taskId)) "intent=$($plan.intent.gate) taskId=$($plan.taskCard.taskId)"
} catch { Add-Check 'question-does-not-create-task' $false $_.Exception.Message }

# This is deliberately one user journey rather than a collection of isolated
# helpers: approved main -> additive request -> side work -> parent return ->
# natural-language status/continue -> ambiguous state must stop.
try {
  # Keep this scenario separate from the executor smoke cases above. A user has
  # one current task/session here, so leftover contracts cannot create a false
  # ambiguity or hide the actual continuation behavior.
  $p0StateRoot = Join-Path $sandboxStateRoot 'p0-user-path'
  $p0WorkspaceRoot = Join-Path $p0StateRoot 'workspace'
  $p0PreviousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  $p0PreviousWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
  $p0TaskId = ''
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $p0StateRoot
    Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue
    $p0Steps = @('A','B','C','D','E','F','G')
    $p0Plan = Run-AutonomousPlan 'execute the approved P0 canonical plan' 'p0 canonical user path' $p0Steps
    $p0TaskId = [string]$p0Plan.taskCard.taskId
    $p0StoredContract = if($p0Plan.executionContract.path -and (Test-Path -LiteralPath ([string]$p0Plan.executionContract.path))){ Get-Content -LiteralPath ([string]$p0Plan.executionContract.path) -Raw -Encoding UTF8 | ConvertFrom-Json }else{$null}
    $p0WorkspaceKey = if($p0StoredContract){[string]$p0StoredContract.workspaceKey}else{''}
    $p0SessionKey = if($p0StoredContract){[string]$p0StoredContract.ownerSessionKey}else{''}
    $env:SUPER_BRAIN_WORKSPACE_KEY = $p0WorkspaceKey
    $p0Initial = if($p0StoredContract){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-approved-plan-creates-canonical-a-through-g' ($p0Plan.ok -eq $true -and $p0Initial -and $p0Initial.ok -eq $true -and (@($p0Initial.canonicalPlan.items | ForEach-Object { $_.label }) -join ',') -eq 'A,B,C,D,E,F,G') "task=$p0TaskId canonical=$(@($p0Initial.canonicalPlan.items | ForEach-Object { $_.label }) -join ',')"
    $p0PhaseInitialized = if($p0Initial -and $p0Initial.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','enter formal P0 verification phase with user-authorized synthetic native evidence','-NextAction','A','-CurrentPhase','P0','-CurrentStep','A','-PhaseEvidencePolicy','user_authorized_synthetic','-ExpectedRevision',[string]([int]$p0Initial.revision),'-ExpectedPlanFingerprint',[string]$p0Initial.planReceipt.planFingerprint,'-TransitionId','p0-enter-formal-phase','-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-formal-phase-is-bound-to-current-contract' ($p0PhaseInitialized -and $p0PhaseInitialized.ok -eq $true -and [string]$p0PhaseInitialized.currentPhase -eq 'P0') "phase=$($p0PhaseInitialized.currentPhase) revision=$($p0PhaseInitialized.revision)"
    $p0Initial = if($p0PhaseInitialized -and $p0PhaseInitialized.ok -eq $true){$p0PhaseInitialized}else{$null}

    # A compatibility checkpoint is a real host-facing path. Its completion
    # must not leave a stale global pointer or promote an active task from a
    # different workspace.
    $compatibilityStateRoot = Join-Path $sandboxStateRoot 'p0-compatibility-completion'
    $compatibilityPreviousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $compatibilityPreviousWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    $p0CompatibilityPointerGuard = $false
    $p0CompatibilityEvidence = ''
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $compatibilityStateRoot
      Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue
      $compatibilityAlpha = 'ws-a22222222222222222222222'
      $compatibilityBeta = 'ws-b33333333333333333333333'
      $compatibilityStartAlpha = Invoke-E2eCheckpoint @('-Action','Start','-TaskId','task-p0-compat-alpha','-WorkspaceKey',$compatibilityAlpha,'-TaskName','P0 compatibility alpha','-CurrentStep','alpha')
      $compatibilityStartBeta = Invoke-E2eCheckpoint @('-Action','Start','-TaskId','task-p0-compat-beta','-WorkspaceKey',$compatibilityBeta,'-TaskName','P0 compatibility beta','-CurrentStep','beta')
      $compatibilityCompleteAlpha = Invoke-E2eCheckpoint @('-Action','Complete','-TaskId','task-p0-compat-alpha','-WorkspaceKey',$compatibilityAlpha,'-MaintenanceOverride','-MaintenanceReason','isolated P0 compatibility pointer regression')
      $compatibilityPointerPath = Join-Path $compatibilityStateRoot 'workspace\active-checkpoint.json'
      $compatibilityBetaState = Invoke-E2eCheckpoint @('-Action','Get','-TaskId','task-p0-compat-beta')
      $compatibilityReceiptPath = Get-SuperBrainCanonicalTaskPath (Join-Path $compatibilityStateRoot 'workspace\runtime-state\task-completion-receipts') 'task-p0-compat-alpha' '.json'
      $compatibilityReceipt = if(Test-Path -LiteralPath $compatibilityReceiptPath){Get-Content -LiteralPath $compatibilityReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
      $p0CompatibilityPointerGuard = ($compatibilityStartAlpha.ok -eq $true -and $compatibilityStartBeta.ok -eq $true -and $compatibilityCompleteAlpha.ok -eq $true -and -not (Test-Path -LiteralPath $compatibilityPointerPath) -and $compatibilityBetaState.ok -eq $true -and [string]$compatibilityBetaState.status -eq 'active' -and $compatibilityReceipt -and [string]$compatibilityReceipt.taskInstanceId -match '^ti-[a-f0-9]{32}$' -and [string]$compatibilityReceipt.workspaceKey -eq $compatibilityAlpha)
      $p0CompatibilityEvidence = "complete=$($compatibilityCompleteAlpha.ok) pointer=$(-not (Test-Path -LiteralPath $compatibilityPointerPath)) beta=$($compatibilityBetaState.status) receipt=$([string]$compatibilityReceipt.taskInstanceId)"
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $compatibilityPreviousStateRoot
      if($null -eq $compatibilityPreviousWorkspaceKey){Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_WORKSPACE_KEY=$compatibilityPreviousWorkspaceKey}
    }
    Add-Check 'p0-compatibility-completion-keeps-workspaces-isolated' $p0CompatibilityPointerGuard $p0CompatibilityEvidence

    $appendInstruction = 'append H and I to the approved canonical main plan'
    $appendEnvelope = if($p0Initial -and $p0Initial.ok -eq $true){ New-E2eCanonicalMutation $p0Initial 'append' 'p0-append-hi-once' $appendInstruction @([pscustomobject]@{label='H';status='pending'},[pscustomobject]@{label='I';status='pending'}) }else{$null}
    $appendPath = if($appendEnvelope){ Write-E2eCanonicalMutation 'p0-append-hi-once' $appendEnvelope $p0StateRoot }else{''}
    $p0Appended = if($appendEnvelope){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction',$appendInstruction,'-NextAction','A','-ExpectedRevision',[string]([int]$p0Initial.revision),'-ExpectedPlanFingerprint',[string]$p0Initial.planReceipt.planFingerprint,'-TransitionId','p0-append-hi-once','-CanonicalMutationPath',$appendPath,'-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-additive-user-request-appends-h-and-i' ($p0Appended -and $p0Appended.ok -eq $true -and (@($p0Appended.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) -join ',') -eq 'A,B,C,D,E,F,G,H,I') "canonical=$(@($p0Appended.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) -join ',')"

    $p0Side = if($p0Appended -and $p0Appended.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','p0-side-proof','-FocusLabel','P0 side proof','-InstructionMode','side_branch','-LatestUserInstruction','inspect the isolated P0 side proof','-NextAction','verify side proof','-PendingSteps','verify side proof','-ExpectedRevision',[string]([int]$p0Appended.revision),'-ExpectedPlanFingerprint',[string]$p0Appended.planReceipt.planFingerprint,'-TransitionId','p0-open-side-proof','-StateRoot',$p0StateRoot) }else{$null}
    $p0SideHook = if($p0Side -and $p0Side.ok -eq $true){Invoke-E2eHook 'current plan and progress' $p0SessionKey}else{$null}
    $p0SideContext = if($p0SideHook){[string]$p0SideHook.hookSpecificOutput.additionalContext}else{''}
    Add-Check 'p0-side-branch-keeps-canonical-a-through-i-visible' ($p0Side -and $p0Side.ok -eq $true -and $p0SideContext.Contains('canonicalChecklist=1:pending:A') -and $p0SideContext.Contains('9:pending:I') -and $p0SideContext.Contains('activeWorkPackage=P0 side proof[p0-side-proof]:side_branch') -and ($p0SideContext.IndexOf('canonicalMain=') -lt $p0SideContext.IndexOf('activeWorkPackage='))) "hookLength=$($p0SideContext.Length) hookExit=$($p0SideHook.e2eExitCode) workspace=$p0WorkspaceKey session=$p0SessionKey"

    # The synthetic native observation is explicitly observe-only. The following
    # governed Set performs the fresh reconciliation; the synthetic probe never
    # impersonates a user-origin instruction or mutates the contract itself.
    $p0SideAfterHook = if($p0Side -and $p0Side.ok -eq $true){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    $p0Reconciled = if($p0SideAfterHook -and $p0SideAfterHook.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','p0-side-proof','-FocusLabel','P0 side proof','-InstructionMode','continue','-LatestUserInstruction','current plan and progress','-NextAction','verify side proof','-ExpectedRevision',[string]([int]$p0SideAfterHook.revision),'-ExpectedPlanFingerprint',[string]$p0SideAfterHook.planReceipt.planFingerprint,'-TransitionId','p0-reconcile-status-query','-StateRoot',$p0StateRoot) }else{$null}
    $p0Resumed = if($p0Reconciled -and $p0Reconciled.ok -eq $true){ Invoke-E2eContract @('-Action','ResumeParent','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-ExpectedRevision',[string]([int]$p0Reconciled.revision),'-ExpectedPlanFingerprint',[string]$p0Reconciled.planReceipt.planFingerprint,'-TransitionId','p0-return-to-parent','-BranchStatus','completed','-CompletionEvidence','p0 side proof verified by the user-path acceptance check','-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-return-to-parent-restores-canonical-main' ($p0Reconciled -and $p0Reconciled.ok -eq $true -and $p0Reconciled.needsReconciliation -eq $false -and $p0Resumed -and $p0Resumed.ok -eq $true -and @($p0Resumed.returnStack).Count -eq 0 -and (@($p0Resumed.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) -join ',') -eq 'A,B,C,D,E,F,G,H,I') "reconciled=$($p0Reconciled.ok) returnDepth=$(@($p0Resumed.returnStack).Count) canonical=$(@($p0Resumed.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) -join ',')"

    # This is the deployed Python prompt-hook command, not the PowerShell
    # fallback. It observes the natural-language status turn and writes native
    # telemetry before the governed reconciliation resumes execution.
    $p0NativeHook = if($p0Resumed -and $p0Resumed.ok -eq $true){Invoke-E2eNativeHook 'current plan' $p0SessionKey}else{$null}
    $p0NativeContext = if($p0NativeHook){[string]$p0NativeHook.context}else{''}
    $p0NativeObservation = New-E2eNativeHookObservation $p0NativeHook $p0StateRoot $p0SessionKey $p0WorkspaceKey
    $p0AfterNativeHook = if($p0NativeHook -and $p0NativeHook.ok -eq $true){Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot)}else{$null}
    $p0NativeReconciled = if($p0AfterNativeHook -and $p0AfterNativeHook.ok -eq $true){Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','reconcile the native current-plan observation','-NextAction','collect P0 behavior evidence','-CurrentPhase','P0','-CurrentStep','A','-ExpectedRevision',[string]([int]$p0AfterNativeHook.revision),'-ExpectedPlanFingerprint',[string]$p0AfterNativeHook.planReceipt.planFingerprint,'-TransitionId','p0-reconcile-native-current-plan','-StateRoot',$p0StateRoot)}else{$null}
    Add-Check 'p0-native-hook-observes-current-plan' ($p0NativeObservation.status -eq 'passed' -and $p0NativeContext.Contains('canonicalChecklist=1:pending:A') -and $p0NativeContext.Contains('9:pending:I') -and $p0NativeContext.Contains('canonicalCounts=0/9/0') -and $p0NativeContext.Contains('shown=9/9')) "native=$($p0NativeObservation.status) hookExit=$($p0NativeObservation.exitCode)"
    Add-Check 'p0-current-plan-hook-never-promotes-local-work-package' ($p0NativeContext.Contains('canonicalChecklist=1:pending:A') -and $p0NativeContext.Contains('canonicalCounts=0/9/0') -and -not $p0NativeContext.Contains('activeWorkPackage=P0 side proof[p0-side-proof]:side_branch')) "hookLength=$($p0NativeContext.Length) hookExit=$($p0NativeObservation.exitCode)"

    $p0BeforeCloseout = if($p0NativeReconciled -and $p0NativeReconciled.ok -eq $true){$p0NativeReconciled}else{$null}
    $p0AdvanceWithoutCloseout = if($p0BeforeCloseout -and $p0BeforeCloseout.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance from P0 after static checks only','-NextAction','start P1','-CurrentPhase','P1','-CurrentStep','start P1','-ExpectedRevision',[string]([int]$p0BeforeCloseout.revision),'-ExpectedPlanFingerprint',[string]$p0BeforeCloseout.planReceipt.planFingerprint,'-TransitionId','p0-advance-without-closeout','-StateRoot',$p0StateRoot) }else{$null}
    $p0AfterRejectedAdvance = if($p0BeforeCloseout){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-formal-phase-rejects-static-only-advance' ($p0AdvanceWithoutCloseout -and $p0AdvanceWithoutCloseout.ok -ne $true -and [string]$p0AdvanceWithoutCloseout.code -eq 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED' -and $p0AfterRejectedAdvance -and [int]$p0AfterRejectedAdvance.revision -eq [int]$p0BeforeCloseout.revision -and [string]$p0AfterRejectedAdvance.currentPhase -eq 'P0') "blocked=$($p0AdvanceWithoutCloseout.code) revision=$($p0AfterRejectedAdvance.revision)"

    $p0EvidenceRoot = Join-Path $p0WorkspaceRoot 'runtime-state\phase-evidence'
    New-Item -ItemType Directory -Force -Path $p0EvidenceRoot | Out-Null
    $p0HashOnlyRealPath = Join-Path $p0EvidenceRoot 'p0-hash-only-real.txt'
    $p0HashOnlyCounterPath = Join-Path $p0EvidenceRoot 'p0-hash-only-counter.txt'
    [IO.File]::WriteAllText($p0HashOnlyRealPath,'arbitrary hash-valid text is not behavior evidence',[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($p0HashOnlyCounterPath,'arbitrary hash-valid text is not a counterexample',[Text.UTF8Encoding]::new($false))
    $p0HashOnlyReceipt = if($p0BeforeCloseout){Write-E2ePhaseEvidence 'p0-hash-only-closeout' ([pscustomobject]@{
      schema='super-brain.phase-closeout-receipt.v1';taskId=$p0TaskId;workspaceKey=$p0WorkspaceKey;ownerSessionKey=$p0SessionKey;packageVersion=[string](Get-SuperBrainManifest $Root).version
      phase='P0';contractRevision=[int]$p0BeforeCloseout.revision;planFingerprint=[string]$p0BeforeCloseout.planReceipt.planFingerprint;phaseEvidencePolicy='user_authorized_synthetic';decision='accepted'
      syntheticNativePath=[pscustomobject]@{ok=$true;scenarioId='hash-only-synthetic';artifactRelativePath='p0-hash-only-real.txt';artifactSha256=(Get-FileHash -LiteralPath $p0HashOnlyRealPath -Algorithm SHA256).Hash.ToLowerInvariant()}
      counterexample=[pscustomobject]@{ok=$true;scenarioId='hash-only-counter';artifactRelativePath='p0-hash-only-counter.txt';artifactSha256=(Get-FileHash -LiteralPath $p0HashOnlyCounterPath -Algorithm SHA256).Hash.ToLowerInvariant()}
      rawPromptStored=$false;rawTranscriptStored=$false
    }) $p0WorkspaceRoot}else{$null}
    $p0HashOnlyAdvance = if($p0BeforeCloseout -and $p0HashOnlyReceipt){Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance P0 with arbitrary hash-valid files','-NextAction','start P1','-CurrentPhase','P1','-CurrentStep','start P1','-ExpectedRevision',[string]([int]$p0BeforeCloseout.revision),'-ExpectedPlanFingerprint',[string]$p0BeforeCloseout.planReceipt.planFingerprint,'-TransitionId','p0-advance-hash-only-evidence','-PhaseCloseoutPath',$p0HashOnlyReceipt.path,'-StateRoot',$p0StateRoot)}else{$null}
    $p0AfterHashOnlyAdvance = if($p0BeforeCloseout){Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot)}else{$null}
    Add-Check 'p0-hash-only-evidence-is-rejected' ($p0HashOnlyAdvance -and $p0HashOnlyAdvance.ok -ne $true -and [string]$p0HashOnlyAdvance.code -eq 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_EVIDENCE_FORMAT_INVALID' -and $p0AfterHashOnlyAdvance -and [int]$p0AfterHashOnlyAdvance.revision -eq [int]$p0BeforeCloseout.revision -and [string]$p0AfterHashOnlyAdvance.currentPhase -eq 'P0') "blocked=$($p0HashOnlyAdvance.code)"

    $p0CounterObservation = [pscustomobject]@{source='governed_execution';status=if($p0AdvanceWithoutCloseout -and $p0AdvanceWithoutCloseout.ok -ne $true){'blocked'}else{'failed'};blocked=($p0AdvanceWithoutCloseout -and $p0AdvanceWithoutCloseout.ok -ne $true);resultOk=if($p0AdvanceWithoutCloseout){[bool]$p0AdvanceWithoutCloseout.ok}else{$true};resultCode=if($p0AdvanceWithoutCloseout){[string]$p0AdvanceWithoutCloseout.code}else{''};rawPromptStored=$false;rawTranscriptStored=$false;rawSessionIdStored=$false}
    $p0RealPathArtifact = if($p0BeforeCloseout){ Write-E2eBehaviorEvidence 'p0-synthetic-native-path' 'synthetic_native_path' 'canonical-main-additive-side-return-synthetic-native-hook' $p0BeforeCloseout @($p0NativeObservation) $p0WorkspaceRoot }else{$null}
    $p0CounterexampleArtifact = if($p0BeforeCloseout){ Write-E2eBehaviorEvidence 'p0-counterexample' 'counterexample' 'phase-advance-without-closeout-is-blocked' $p0BeforeCloseout @($p0CounterObservation) $p0WorkspaceRoot }else{$null}
    $p0CloseoutReceipt = if($p0BeforeCloseout -and $p0RealPathArtifact -and $p0CounterexampleArtifact){
      Write-E2ePhaseEvidence 'p0-closeout-receipt' ([pscustomobject]@{
        schema='super-brain.phase-closeout-receipt.v1';taskId=$p0TaskId;workspaceKey=$p0WorkspaceKey;ownerSessionKey=$p0SessionKey;packageVersion=[string](Get-SuperBrainManifest $Root).version
        phase='P0';contractRevision=[int]$p0BeforeCloseout.revision;planFingerprint=[string]$p0BeforeCloseout.planReceipt.planFingerprint;phaseEvidencePolicy='user_authorized_synthetic';decision='accepted'
        syntheticNativePath=[pscustomobject]@{ok=$true;scenarioId='canonical-main-additive-side-return-synthetic-native-hook';artifactRelativePath=$p0RealPathArtifact.relativePath;artifactSha256=$p0RealPathArtifact.sha256}
        counterexample=[pscustomobject]@{ok=$true;scenarioId='phase-advance-without-closeout-is-blocked';artifactRelativePath=$p0CounterexampleArtifact.relativePath;artifactSha256=$p0CounterexampleArtifact.sha256}
        rawPromptStored=$false;rawTranscriptStored=$false
      }) $p0WorkspaceRoot
    }else{$null}
    $p0CounterexampleOriginal = if($p0CounterexampleArtifact -and (Test-Path -LiteralPath $p0CounterexampleArtifact.path)){ Get-Content -LiteralPath $p0CounterexampleArtifact.path -Raw -Encoding UTF8 }else{''}
    if($p0CounterexampleArtifact){ [IO.File]::WriteAllText($p0CounterexampleArtifact.path,'tampered phase evidence',[Text.UTF8Encoding]::new($false)) }
    $p0TamperedAdvance = if($p0BeforeCloseout -and $p0CloseoutReceipt){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance P0 with altered behavior evidence','-NextAction','start P1','-CurrentPhase','P1','-CurrentStep','start P1','-ExpectedRevision',[string]([int]$p0BeforeCloseout.revision),'-ExpectedPlanFingerprint',[string]$p0BeforeCloseout.planReceipt.planFingerprint,'-TransitionId','p0-advance-tampered-evidence','-PhaseCloseoutPath',$p0CloseoutReceipt.path,'-StateRoot',$p0StateRoot) }else{$null}
    if($p0CounterexampleArtifact){ [IO.File]::WriteAllText($p0CounterexampleArtifact.path,$p0CounterexampleOriginal,[Text.UTF8Encoding]::new($false)) }
    Add-Check 'p0-tampered-behavior-evidence-blocks-advance' ($p0TamperedAdvance -and $p0TamperedAdvance.ok -ne $true -and [string]$p0TamperedAdvance.code -eq 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_EVIDENCE_HASH_MISMATCH') "blocked=$($p0TamperedAdvance.code)"
    $p0Advanced = if($p0BeforeCloseout -and $p0CloseoutReceipt){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance from P0 after user-authorized synthetic native path and counterexample pass','-NextAction','start P1','-CurrentPhase','P1','-CurrentStep','start P1','-ExpectedRevision',[string]([int]$p0BeforeCloseout.revision),'-ExpectedPlanFingerprint',[string]$p0BeforeCloseout.planReceipt.planFingerprint,'-TransitionId','p0-advance-with-closeout','-PhaseCloseoutPath',$p0CloseoutReceipt.path,'-StateRoot',$p0StateRoot) }else{$null}
    $p0RecordedCloseouts = if($p0Advanced){ @($p0Advanced.phaseCloseouts | Where-Object { [string]$_.phase -eq 'P0' }) }else{@()}
    $p0RecordedCloseoutCount = @($p0RecordedCloseouts).Count
    $p0RecordedCloseout = @($p0RecordedCloseouts | Select-Object -First 1)[0]
    Add-Check 'p0-formal-phase-requires-user-authorized-synthetic-path-and-counterexample' ($p0Advanced -and $p0Advanced.ok -eq $true -and [string]$p0Advanced.currentPhase -eq 'P1' -and $p0RecordedCloseoutCount -eq 1 -and [string]$p0RecordedCloseout.phaseEvidencePolicy -eq 'user_authorized_synthetic' -and [string]$p0RecordedCloseout.syntheticNativePath.scenarioId -eq 'canonical-main-additive-side-return-synthetic-native-hook' -and [string]$p0RecordedCloseout.counterexample.scenarioId -eq 'phase-advance-without-closeout-is-blocked' -and [string]$p0RecordedCloseout.syntheticNativePath.producer -eq 'super-brain.behavior-capture.v1') "code=$($p0Advanced.code) phase=$($p0Advanced.currentPhase) closeouts=$p0RecordedCloseoutCount"

    $p0Observed = if($p0Advanced -and $p0Advanced.ok -eq $true){ Invoke-E2eContract @('-Action','ObserveUser','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-UserInstruction','continue while the canonical state requires reconciliation','-RequiresReconciliation','-StateRoot',$p0StateRoot) }else{$null}
    $p0ConflictHook = if($p0Observed -and $p0Observed.ok -eq $true){Invoke-E2eHook 'continue current plan' $p0SessionKey}else{$null}
    $p0ConflictContext = if($p0ConflictHook){[string]$p0ConflictHook.hookSpecificOutput.additionalContext}else{''}
    $p0BlockedLocal = if($p0Observed -and $p0Observed.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','only do the newest local detail','-NextAction','local-only-action-must-not-start','-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-reconciliation-conflict-blocks-local-execution' ($p0Observed -and $p0Observed.needsReconciliation -eq $true -and $p0ConflictContext.Contains('actionAuthorization=withheld') -and $p0BlockedLocal -and $p0BlockedLocal.ok -ne $true -and [string]$p0BlockedLocal.code -eq 'EXECUTION_CONTRACT_STRUCTURAL_GUARD_REQUIRED') "observed=$($p0Observed.needsReconciliation) hookLength=$($p0ConflictContext.Length) hookExit=$($p0ConflictHook.e2eExitCode) blocked=$($p0BlockedLocal.code)"

    $admissionRoot = Join-Path $p0StateRoot 'missing-approved-plan'
    $savedStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $savedWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $admissionRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = 'ws-p0-missing-approved-plan-202607'
      New-Item -ItemType Directory -Force -Path (Join-Path $admissionRoot 'workspace\runtime-state\prompt-hook-telemetry') | Out-Null
      $admissionRaw = @(& (Join-Path $PSScriptRoot 'codex-user-prompt-hook.ps1') -TestPrompt 'confirm and follow this plan' -TestSessionId 'sid-p0-missing-approved-plan-202607' 2>$null)
      $admission = (($admissionRaw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json
      $admissionContext = [string]$admission.hookSpecificOutput.additionalContext
      $admissionContracts = Join-Path $admissionRoot 'workspace\runtime-state\execution-contracts'
      Add-Check 'p0-missing-full-plan-stops-at-admission-gate' ($admissionContext.Contains('CANONICAL_PLAN_ADMISSION_GATE') -and $admissionContext.Contains('never invent a partial checklist') -and -not(Test-Path -LiteralPath $admissionContracts -PathType Container)) "contractDirectoryExists=$(Test-Path -LiteralPath $admissionContracts -PathType Container)"
    } finally {
      $env:SUPER_BRAIN_STATE_ROOT = $savedStateRoot
      $env:SUPER_BRAIN_WORKSPACE_KEY = $savedWorkspaceKey
    }
  } finally {
    if(-not [string]::IsNullOrWhiteSpace($p0TaskId)){ Remove-TaskArtifacts $p0TaskId $p0WorkspaceRoot }
    $env:SUPER_BRAIN_STATE_ROOT = $p0PreviousStateRoot
    if($null -eq $p0PreviousWorkspaceKey){ Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue }else{$env:SUPER_BRAIN_WORKSPACE_KEY=$p0PreviousWorkspaceKey}
  }
} catch { Add-Check 'p0-canonical-user-path' $false $_.Exception.Message }

try {
  $variantTaskId = ''
  $variantStateRoot = Join-Path $sandboxStateRoot 'phase-closeout-variant'
  $variantWorkspaceRoot = Join-Path $variantStateRoot 'workspace'
  $variantPreviousStateRoot = $env:SUPER_BRAIN_STATE_ROOT
  $variantPreviousWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
  try {
    $env:SUPER_BRAIN_STATE_ROOT = $variantStateRoot
    Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue
  $variant = Run-AutonomousPlan 'execute a separate verification workflow' 'phase closeout generic path' @('inventory evidence','challenge false completion','verify transition')
  $variantTaskId = [string]$variant.taskCard.taskId
  $variantStored = if($variant.executionContract.path -and (Test-Path -LiteralPath ([string]$variant.executionContract.path))){ Get-Content -LiteralPath ([string]$variant.executionContract.path) -Raw -Encoding UTF8 | ConvertFrom-Json }else{$null}
  $variantWorkspaceKey = if($variantStored){[string]$variantStored.workspaceKey}else{''}
  $variantSessionKey = if($variantStored){[string]$variantStored.ownerSessionKey}else{''}
  $variantInitial = if($variantStored){Invoke-E2eContract @('-Action','Get','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-StateRoot',$variantStateRoot)}else{$null}
  $variantFormal = if($variantInitial -and $variantInitial.ok -eq $true){Invoke-E2eContract @('-Action','Set','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','enter P2.2 evidence phase with user-authorized synthetic native evidence','-NextAction','inventory evidence','-CurrentPhase','P2.2','-CurrentStep','inventory evidence','-PhaseEvidencePolicy','user_authorized_synthetic','-ExpectedRevision',[string]([int]$variantInitial.revision),'-ExpectedPlanFingerprint',[string]$variantInitial.planReceipt.planFingerprint,'-TransitionId','generic-enter-p2-2','-StateRoot',$variantStateRoot)}else{$null}
  $variantPreviousWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
  try {
    $env:SUPER_BRAIN_WORKSPACE_KEY = $variantWorkspaceKey
    $variantNativeHook = if($variantFormal -and $variantFormal.ok -eq $true){Invoke-E2eNativeHook 'current plan' $variantSessionKey}else{$null}
  } finally {
    if($null -eq $variantPreviousWorkspaceKey){Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_WORKSPACE_KEY=$variantPreviousWorkspaceKey}
  }
  $variantNativeObservation = New-E2eNativeHookObservation $variantNativeHook $variantStateRoot $variantSessionKey $variantWorkspaceKey
  $variantAfterNative = if($variantNativeHook -and $variantNativeHook.ok -eq $true){Invoke-E2eContract @('-Action','Get','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-StateRoot',$variantStateRoot)}else{$null}
  $variantReady = if($variantAfterNative -and $variantAfterNative.ok -eq $true){Invoke-E2eContract @('-Action','Set','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','reconcile native P2.2 current-plan observation','-NextAction','inventory evidence','-CurrentPhase','P2.2','-CurrentStep','inventory evidence','-ExpectedRevision',[string]([int]$variantAfterNative.revision),'-ExpectedPlanFingerprint',[string]$variantAfterNative.planReceipt.planFingerprint,'-TransitionId','generic-reconcile-native-current-plan','-StateRoot',$variantStateRoot)}else{$null}
  $variantBlocked = if($variantReady -and $variantReady.ok -eq $true){Invoke-E2eContract @('-Action','Set','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance P2.2 without behavior proof','-NextAction','verify transition','-CurrentPhase','P2.3','-CurrentStep','verify transition','-ExpectedRevision',[string]([int]$variantReady.revision),'-ExpectedPlanFingerprint',[string]$variantReady.planReceipt.planFingerprint,'-TransitionId','generic-blocked-p2-3','-StateRoot',$variantStateRoot)}else{$null}
  $variantCounterObservation=[pscustomobject]@{source='governed_execution';status=if($variantBlocked -and $variantBlocked.ok -ne $true){'blocked'}else{'failed'};blocked=($variantBlocked -and $variantBlocked.ok -ne $true);resultOk=if($variantBlocked){[bool]$variantBlocked.ok}else{$true};resultCode=if($variantBlocked){[string]$variantBlocked.code}else{''};rawPromptStored=$false;rawTranscriptStored=$false;rawSessionIdStored=$false}
  $variantReal = if($variantReady){Write-E2eBehaviorEvidence 'generic-synthetic-native-path' 'synthetic_native_path' 'different-task-synthetic-native-current-plan' $variantReady @($variantNativeObservation) $variantWorkspaceRoot}else{$null}
  $variantCounter = if($variantReady){Write-E2eBehaviorEvidence 'generic-counterexample' 'counterexample' 'different-task-static-advance-blocked' $variantReady @($variantCounterObservation) $variantWorkspaceRoot}else{$null}
  $variantReceipt = if($variantReady -and $variantReal -and $variantCounter){Write-E2ePhaseEvidence 'generic-phase-closeout' ([pscustomobject]@{
    schema='super-brain.phase-closeout-receipt.v1';taskId=$variantTaskId;workspaceKey=$variantWorkspaceKey;ownerSessionKey=$variantSessionKey;packageVersion=[string](Get-SuperBrainManifest $Root).version
    phase='P2.2';contractRevision=[int]$variantReady.revision;planFingerprint=[string]$variantReady.planReceipt.planFingerprint;phaseEvidencePolicy='user_authorized_synthetic';decision='accepted'
    syntheticNativePath=[pscustomobject]@{ok=$true;scenarioId='different-task-synthetic-native-current-plan';artifactRelativePath=$variantReal.relativePath;artifactSha256=$variantReal.sha256}
    counterexample=[pscustomobject]@{ok=$true;scenarioId='different-task-static-advance-blocked';artifactRelativePath=$variantCounter.relativePath;artifactSha256=$variantCounter.sha256}
    rawPromptStored=$false;rawTranscriptStored=$false
  }) $variantWorkspaceRoot}else{$null}
  $variantAdvanced = if($variantReady -and $variantReceipt){Invoke-E2eContract @('-Action','Set','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance P2.2 after independent behavior checks','-NextAction','verify transition','-CurrentPhase','P2.3','-CurrentStep','verify transition','-ExpectedRevision',[string]([int]$variantReady.revision),'-ExpectedPlanFingerprint',[string]$variantReady.planReceipt.planFingerprint,'-TransitionId','generic-advance-p2-3','-PhaseCloseoutPath',$variantReceipt.path,'-StateRoot',$variantStateRoot)}else{$null}
  $variantCloseout = @($variantAdvanced.phaseCloseouts | Where-Object { [string]$_.phase -eq 'P2.2' } | Select-Object -First 1)[0]
  Add-Check 'phase-closeout-generalizes-user-authorized-synthetic-policy-beyond-p0' ($variantReady -and $variantReady.ok -eq $true -and $variantNativeObservation.status -eq 'passed' -and $variantBlocked -and [string]$variantBlocked.code -eq 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED' -and $variantAdvanced -and $variantAdvanced.ok -eq $true -and [string]$variantAdvanced.currentPhase -eq 'P2.3' -and $variantCloseout -and [string]$variantCloseout.phaseEvidencePolicy -eq 'user_authorized_synthetic' -and [string]$variantCloseout.syntheticNativePath.scenarioId -eq 'different-task-synthetic-native-current-plan') "blocked=$($variantBlocked.code) phase=$($variantAdvanced.currentPhase)"
  if(-not [string]::IsNullOrWhiteSpace($variantTaskId)){Remove-TaskArtifacts $variantTaskId}
  } finally {
    $env:SUPER_BRAIN_STATE_ROOT = $variantPreviousStateRoot
    if($null -eq $variantPreviousWorkspaceKey){Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_WORKSPACE_KEY=$variantPreviousWorkspaceKey}
  }
} catch { Add-Check 'phase-closeout-generalizes-beyond-p0' $false $_.Exception.Message }

$failed = @($checks | Where-Object { $_.ok -ne $true })
Restore-TaskContext
$result=[pscustomobject]@{ ok=($failed.Count -eq 0); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.autonomous-executor-e2e.v1'; version=(Get-SuperBrainManifest $Root).version; failed=$failed.Count; checks=@($checks); guard='Natural execute goals and threshold-approved plans create task checkpoints; question/plan-only goals do not mutate; E2E runs under an isolated state root.'; path=$outPath; sandboxStateRoot=if($KeepSandbox){$sandboxStateRoot}else{''} }
Write-JsonUtf8NoBom $outPath $result 12
$jsonText = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8
$exitCode = if($result.ok){0}else{1}
} finally {
  $env:SUPER_BRAIN_STATE_ROOT = $originalStateRoot
  if($null -eq $originalWorkspaceKey){ Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue }else{$env:SUPER_BRAIN_WORKSPACE_KEY=$originalWorkspaceKey}
  if(-not $KeepSandbox){ Remove-E2eSandbox }
}
if($Json){$jsonText}else{Write-Host "AUTONOMOUS_EXECUTOR_E2E ok=$($result.ok) failed=$($result.failed) path=$outPath"}
exit $exitCode
