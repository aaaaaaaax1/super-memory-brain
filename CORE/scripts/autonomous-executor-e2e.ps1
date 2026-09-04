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
$originalLocation = (Get-Location).Path
# The E2E models one local embedding process.  Pin its cwd to the repository
# root so the contract workspace key and H7 project-proof root are identical
# regardless of where the runner was launched from; restore it in the outer
# finally below.
$projectRoot = Split-Path -Parent $Root
Push-Location -LiteralPath $projectRoot
$originalStateRoot = $env:SUPER_BRAIN_STATE_ROOT
$originalWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
$originalLocalSession = $env:SUPER_BRAIN_LOCAL_SESSION_ID
$stableLocalSession = 'sid-' + ([guid]::NewGuid().ToString('n'))
$env:SUPER_BRAIN_LOCAL_SESSION_ID = $stableLocalSession
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
  try { $output = Invoke-Expression $command 2>&1 }
  catch {
    $text = @($_ | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{ ok=$false; raw=$text; error=[string]$_.Exception.Message }
  }
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
function Get-E2eCanonicalPayloadHash([object]$Value){
  $temp = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 20 -Compress),[Text.UTF8Encoding]::new($false))
    $program = "import hashlib,json,sys; v=json.load(open(sys.argv[1],encoding='utf-8')); print(hashlib.sha256(json.dumps(v,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode('utf-8')).hexdigest())"
    $hash = ((@(& python -c $program $temp 2>&1) | ForEach-Object { [string]$_ }) -join '').Trim().ToLowerInvariant()
    if($hash -notmatch '^[a-f0-9]{64}$'){ throw 'E2E_CANONICAL_HASH_INVALID' }
    return $hash
  } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
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
  $body = [ordered]@{
    schema='super-brain.canonical-plan-mutation.v2'
    scope=[ordered]@{taskId=[string]$Contract.taskId;taskInstanceId=[string]$Contract.taskInstanceId;workspaceKey=[string]$Contract.workspaceKey;ownerSessionKey=[string]$Contract.ownerSessionKey}
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
  $body.payloadHash = Get-E2eCanonicalPayloadHash $body
  return [pscustomobject]$body
}
function Invoke-E2eContract([string[]]$Arguments){
  return Run-JsonAllowFail 'execution-contract.ps1' $Arguments
}
function Invoke-E2eCheckpoint([string[]]$Arguments){
  return Run-JsonAllowFail 'checkpoint-writer.ps1' $Arguments
}
function Invoke-E2eH7Runtime([string]$StateRoot,[string]$SessionKey,[string]$Phase='open',[string]$TurnIntent='continuity',[string]$ProgressCheckpointBase64='',[string]$ProjectProgressProofBase64='',[string]$LatestUserInstruction='',[string]$TransitionId='',[string]$RecoveryEvent='none') {
  $oldState=$env:SUPER_BRAIN_STATE_ROOT; $oldSession=$env:SUPER_BRAIN_LOCAL_SESSION_ID
  try {
    # The H7 CLI derives workspace identity from its real cwd and the strict
    # local session id.  Never inject a second workspace selector here: MCP
    # and CLI must resolve the same local scope.
    $env:SUPER_BRAIN_STATE_ROOT=$StateRoot; $env:SUPER_BRAIN_LOCAL_SESSION_ID=$SessionKey
    $args=@('-X','utf8',(Join-Path $Root 'runtime\brain_cli.py'),'--package-root',$Root,'--memory-root',(Join-Path $StateRoot 'shared'),'turn-runtime','--phase',$Phase,'--memory-mode','auto','--turn-intent',$TurnIntent,'--recovery-event',$RecoveryEvent,'--timeout-seconds','12')
    if($ProgressCheckpointBase64){$args += @('--progress-checkpoint-base64',$ProgressCheckpointBase64)}
    if($ProjectProgressProofBase64){$args += @('--project-progress-proof-base64',$ProjectProgressProofBase64)}
    if($LatestUserInstruction){$args += @('--latest-user-instruction-base64',[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LatestUserInstruction)))}
    if($TransitionId){$args += @('--transition-id',$TransitionId)}
    $raw=@(& python @args 2>&1); $exit=$LASTEXITCODE
  } finally {
    if($null -eq $oldState){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$oldState}
    if($null -eq $oldSession){Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_LOCAL_SESSION_ID=$oldSession}
  }
  $text=($raw|ForEach-Object{[string]$_}) -join "`n"; $jsonStart=$text.IndexOf('{'); $value=$null
  if($jsonStart -ge 0){try{$value=$text.Substring($jsonStart)|ConvertFrom-Json}catch{}}
  [pscustomobject]@{ok=($exit -eq 0 -and $value);exitCode=$exit;value=$value;raw=$text}
}
function New-E2eH7Observation([object]$Runtime,[string]$Source='h7_turn_runtime') {
  $v=if($Runtime){$Runtime.value}else{$null}
  [pscustomobject]@{source=$Source;status=if($Runtime -and $Runtime.ok -and $v -and [string]$v.mode -eq 'hookless_turn_runtime' -and $v.available -eq $true){'passed'}else{'failed'};exitCode=if($Runtime){[int]$Runtime.exitCode}else{-1};code=if($v){[string]$v.code}else{''};scope=if($v){$v.scope}else{$null};rawPromptStored=$false;rawTranscriptStored=$false;rawSessionIdStored=$false}
}
function New-E2eH7ProofBase64([string]$Phase,[string]$Step,[string]$NextAction,[object[]]$CompletedSteps=@()) {
  $relative='CORE/super-brain-rules.json'; $path=Join-Path $projectRoot ($relative -replace '/','\')
  $sha=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  $items=@($CompletedSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object {
    [ordered]@{itemKey=[string]$_;evidenceRefs=@("project:file:$relative@sha256:$sha");verificationIds=@('autonomous-executor-e2e-h7')}
  })
  $body=[ordered]@{schema='super-brain.project-progress-input.v1';phase=$Phase;currentStep=$Step;completedItems=$items;projectEvidence=@([ordered]@{kind='project_file';relativePath=$relative;sha256=$sha});verificationResults=@([ordered]@{id='autonomous-executor-e2e-h7';status='passed'});nextAction=$NextAction}|ConvertTo-Json -Compress -Depth 8
  [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
}
function New-E2eH7CheckpointBase64([string]$Phase,[string]$Step,[string]$NextAction) {
  $body=[ordered]@{last_confirmed_sentence="H7 confirms $Phase progress.";current_phase=$Phase;current_step=$Step;next_action=$NextAction;source='assistant_visible_reply'}|ConvertTo-Json -Compress
  [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
}
function Invoke-E2eH7ProgressCheckpoint([string]$StateRoot,[string]$SessionKey,[string]$Phase,[string]$Step,[string]$NextAction,[object[]]$CompletedSteps,[string]$LatestUserInstruction,[string]$TransitionId){
  return Invoke-E2eH7Runtime -StateRoot $StateRoot -SessionKey $SessionKey -Phase 'checkpoint' -TurnIntent 'continuity' -ProgressCheckpointBase64 (New-E2eH7CheckpointBase64 $Phase $Step $NextAction) -ProjectProgressProofBase64 (New-E2eH7ProofBase64 $Phase $Step $NextAction $CompletedSteps) -LatestUserInstruction $LatestUserInstruction -TransitionId $TransitionId
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
# The sandbox state root is fresh for this run, so no global/legacy checkpoint
# cleanup is needed.  Any cleanup below is always bound to the task id created
# by this run.
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
    $p0PhaseInitialized = if($p0Initial -and $p0Initial.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','enter formal P0 verification phase with H7 current evidence','-NextAction','A','-CurrentPhase','P0','-CurrentStep','A','-PhaseEvidencePolicy','h7_current','-ExpectedRevision',[string]([int]$p0Initial.revision),'-ExpectedPlanFingerprint',[string]$p0Initial.planReceipt.planFingerprint,'-TransitionId','p0-enter-formal-phase','-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-formal-phase-is-bound-to-current-contract' ($p0PhaseInitialized -and $p0PhaseInitialized.ok -eq $true -and [string]$p0PhaseInitialized.currentPhase -eq 'P0') "phase=$($p0PhaseInitialized.currentPhase) revision=$($p0PhaseInitialized.revision)"
    $p0Initial = if($p0PhaseInitialized -and $p0PhaseInitialized.ok -eq $true){$p0PhaseInitialized}else{$null}

    # The compatibility checkpoint is one legacy pointer, not a second scope
    # selector.  A foreign workspace must never overwrite the pointer owned by
    # the current task; scoped records remain the authoritative isolation path.
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
      $compatibilityPointerPath = Join-Path $compatibilityStateRoot 'workspace\active-checkpoint.json'
      $compatibilityPointer = if(Test-Path -LiteralPath $compatibilityPointerPath){Get-Content -LiteralPath $compatibilityPointerPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
      $compatibilityCompleteAlpha = Invoke-E2eCheckpoint @('-Action','Complete','-TaskId','task-p0-compat-alpha','-WorkspaceKey',$compatibilityAlpha,'-MaintenanceOverride','-MaintenanceReason','isolated P0 compatibility pointer regression')
      $compatibilityPointerAfterComplete = if(Test-Path -LiteralPath $compatibilityPointerPath){Get-Content -LiteralPath $compatibilityPointerPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
      $compatibilityReceiptPath = Get-SuperBrainCanonicalTaskPath (Join-Path $compatibilityStateRoot 'workspace\runtime-state\task-completion-receipts') 'task-p0-compat-alpha' '.json'
      $compatibilityReceipt = if(Test-Path -LiteralPath $compatibilityReceiptPath){Get-Content -LiteralPath $compatibilityReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
      # Scoped records for a foreign workspace are valid and must not be
      # rejected merely because the legacy compatibility pointer is owned by
      # alpha.  The isolation invariant is that beta's scoped start succeeds
      # without replacing alpha's pointer, and alpha completion clears only
      # the pointer it owns.
      $pointerOwnedByAlpha = ($null -ne $compatibilityPointer -and [string]$compatibilityPointer.taskId -eq 'task-p0-compat-alpha' -and [string]$compatibilityPointer.workspaceKey -eq $compatibilityAlpha)
      $pointerClearedAfterAlpha = ($null -eq $compatibilityPointerAfterComplete)
      $completionReceiptBound = ($null -ne $compatibilityReceipt -and [string]$compatibilityReceipt.taskInstanceId -match '^ti-[a-f0-9]{32}$' -and [string]$compatibilityReceipt.workspaceKey -eq $compatibilityAlpha)
      $p0CompatibilityPointerGuard = ($compatibilityStartAlpha.ok -eq $true -and $compatibilityStartBeta.ok -eq $true -and $pointerOwnedByAlpha -and $compatibilityCompleteAlpha.ok -eq $true -and $pointerClearedAfterAlpha -and $completionReceiptBound)
      $p0CompatibilityEvidence = "alphaStart=$($compatibilityStartAlpha.ok) betaStart=$($compatibilityStartBeta.ok) betaRaw=$([string]$compatibilityStartBeta.raw) pointerBeforeComplete=$([string]$compatibilityPointer.taskId) pointerAfterComplete=$([string]$compatibilityPointerAfterComplete.taskId) alphaComplete=$($compatibilityCompleteAlpha.ok) receipt=$([string]$compatibilityReceipt.taskInstanceId)"
      foreach($compatibilityTask in @('task-p0-compat-alpha','task-p0-compat-beta')){ Run-JsonAllowFail 'checkpoint-writer.ps1' @('-Action','Clear','-TaskId',$compatibilityTask) | Out-Null }
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

    # A material Set invalidates the prior progress proof.  Establish a fresh
    # main-line H7 checkpoint before opening a side branch so the parent return
    # card has a valid visible recovery anchor.
    $p0MainCheckpoint = if($p0Appended -and $p0Appended.ok -eq $true){ Invoke-E2eH7ProgressCheckpoint $p0StateRoot $p0SessionKey 'P0' 'A' 'A' @($p0Appended.completedSteps) 'continue the current P0 main-line verification' 'p0-main-h7-checkpoint' }else{$null}
    $p0AfterMainCheckpoint = if($p0MainCheckpoint -and $p0MainCheckpoint.ok){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    $p0Side = if($p0AfterMainCheckpoint -and $p0AfterMainCheckpoint.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','p0-side-proof','-FocusLabel','P0 side proof','-InstructionMode','side_branch','-LatestUserInstruction','inspect the isolated P0 side proof','-NextAction','verify side proof','-PendingSteps','verify side proof','-ExpectedRevision',[string]([int]$p0AfterMainCheckpoint.revision),'-ExpectedPlanFingerprint',[string]$p0AfterMainCheckpoint.planReceipt.planFingerprint,'-TransitionId','p0-open-side-proof','-StateRoot',$p0StateRoot) }else{$null}
    $p0SideOpen = if($p0Side -and $p0Side.ok -eq $true){Invoke-E2eH7Runtime $p0StateRoot $p0SessionKey 'open' 'continuity'}else{$null}
    $p0SideCheckpoint = if($p0Side -and $p0Side.ok -eq $true){ Invoke-E2eH7ProgressCheckpoint $p0StateRoot $p0SessionKey 'side_branch' 'verify side proof' 'verify side proof' @($p0Side.completedSteps) 'continue the isolated P0 side proof with current H7 evidence' 'p0-side-h7-checkpoint' }else{$null}
    $p0SideAfterCheckpoint = if($p0SideCheckpoint -and $p0SideCheckpoint.ok){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    $p0SideH7 = if($p0SideAfterCheckpoint -and $p0SideAfterCheckpoint.ok -eq $true){Invoke-E2eH7Runtime $p0StateRoot $p0SessionKey 'open' 'continuity'}else{$p0SideOpen}
    Add-Check 'p0-side-branch-keeps-canonical-a-through-i-visible' ($p0SideH7 -and $p0SideH7.ok -and $p0SideH7.value.available -eq $true -and [string]$p0SideH7.value.context.task.taskId -eq $p0TaskId -and $p0SideAfterCheckpoint -and (@($p0SideAfterCheckpoint.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) -join ',') -eq 'A,B,C,D,E,F,G,H,I') "h7Code=$($p0SideH7.value.code) task=$($p0SideH7.value.context.task.taskId) canonical=$(@($p0SideAfterCheckpoint.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) -join ',')"

    # The synthetic native observation is explicitly observe-only. The following
    # governed Set performs the fresh reconciliation; the synthetic probe never
    # impersonates a user-origin instruction or mutates the contract itself.
    $p0SideAfterH7 = if($p0SideAfterCheckpoint -and $p0SideAfterCheckpoint.ok -eq $true){ $p0SideAfterCheckpoint }elseif($p0Side -and $p0Side.ok -eq $true){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    $p0Reconciled = if($p0SideAfterH7 -and $p0SideAfterH7.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','p0-side-proof','-FocusLabel','P0 side proof','-InstructionMode','continue','-LatestUserInstruction','current plan and progress','-NextAction','verify side proof','-ExpectedRevision',[string]([int]$p0SideAfterH7.revision),'-ExpectedPlanFingerprint',[string]$p0SideAfterH7.planReceipt.planFingerprint,'-TransitionId','p0-reconcile-status-query','-StateRoot',$p0StateRoot) }else{$null}
    $p0ResumeCheckpoint = if($p0Reconciled -and $p0Reconciled.ok -eq $true){ Invoke-E2eH7ProgressCheckpoint $p0StateRoot $p0SessionKey ([string]$p0Reconciled.currentPhase) ([string]$p0Reconciled.currentStep) ([string]$p0Reconciled.nextAction) @($p0Reconciled.completedSteps) 'continue after reconciling the current P0 side proof' 'p0-resume-h7-checkpoint' }else{$null}
    $p0BeforeResume = if($p0ResumeCheckpoint -and $p0ResumeCheckpoint.ok){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    $p0Resumed = if($p0BeforeResume -and $p0BeforeResume.ok -eq $true){ Invoke-E2eContract @('-Action','ResumeParent','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-ExpectedRevision',[string]([int]$p0BeforeResume.revision),'-ExpectedPlanFingerprint',[string]$p0BeforeResume.planReceipt.planFingerprint,'-TransitionId','p0-return-to-parent','-BranchStatus','completed','-CompletionEvidence','p0 side proof verified by the user-path acceptance check','-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-return-to-parent-restores-canonical-main' ($p0Reconciled -and $p0Reconciled.ok -eq $true -and $p0Reconciled.needsReconciliation -eq $false -and $p0Resumed -and $p0Resumed.ok -eq $true -and @($p0Resumed.returnStack).Count -eq 0 -and (@($p0Resumed.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) -join ',') -eq 'A,B,C,D,E,F,G,H,I') "reconciled=$($p0Reconciled.ok) returnDepth=$(@($p0Resumed.returnStack).Count) canonical=$(@($p0Resumed.canonicalPlan.items | Sort-Object ordinal | ForEach-Object { $_.label }) -join ',')"

    # H7 turn-runtime observes the natural-language status turn and writes
    # scope-bound telemetry before governed reconciliation resumes execution.
    $p0ParentCheckpoint = if($p0Resumed -and $p0Resumed.ok -eq $true){ Invoke-E2eH7ProgressCheckpoint $p0StateRoot $p0SessionKey ([string]$p0Resumed.currentPhase) ([string]$p0Resumed.currentStep) ([string]$p0Resumed.nextAction) @($p0Resumed.completedSteps) 'continue the restored P0 canonical main line' 'p0-parent-h7-checkpoint' }else{$null}
    $p0NativeH7 = if($p0ParentCheckpoint -and $p0ParentCheckpoint.ok){Invoke-E2eH7Runtime $p0StateRoot $p0SessionKey 'open' 'continuity'}else{$null}
    $p0NativeObservation = New-E2eH7Observation $p0NativeH7
    $p0AfterNativeH7 = if($p0NativeH7 -and $p0NativeH7.ok){Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot)}else{$null}
    $p0NativeReconciled = if($p0AfterNativeH7 -and $p0AfterNativeH7.ok -eq $true){Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','reconcile the H7 current-plan observation','-NextAction','collect P0 behavior evidence','-CurrentPhase','P0','-CurrentStep','A','-ExpectedRevision',[string]([int]$p0AfterNativeH7.revision),'-ExpectedPlanFingerprint',[string]$p0AfterNativeH7.planReceipt.planFingerprint,'-TransitionId','p0-reconcile-native-current-plan','-StateRoot',$p0StateRoot)}else{$null}
    Add-Check 'p0-h7-runtime-observes-current-plan' ($p0NativeObservation.status -eq 'passed' -and [string]$p0NativeH7.value.context.task.taskId -eq $p0TaskId -and [string]$p0NativeH7.value.context.scope.ownerSessionKey -eq $p0SessionKey) "h7Code=$($p0NativeH7.value.code) runtime=$($p0NativeObservation.status)"
    Add-Check 'p0-h7-runtime-never-promotes-local-work-package' ($p0NativeH7.value.available -eq $true -and [string]$p0NativeH7.value.context.task.taskId -eq $p0TaskId) "h7Code=$($p0NativeH7.value.code)"

    $p0BeforeCloseout = if($p0NativeReconciled -and $p0NativeReconciled.ok -eq $true){$p0NativeReconciled}else{$null}
    $p0AdvanceWithoutCloseout = if($p0BeforeCloseout -and $p0BeforeCloseout.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance from P0 after static checks only','-NextAction','start P1','-CurrentPhase','P1','-CurrentStep','start P1','-ExpectedRevision',[string]([int]$p0BeforeCloseout.revision),'-ExpectedPlanFingerprint',[string]$p0BeforeCloseout.planReceipt.planFingerprint,'-TransitionId','p0-advance-without-closeout','-StateRoot',$p0StateRoot) }else{$null}
    $p0AfterRejectedAdvance = if($p0BeforeCloseout){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-formal-phase-rejects-static-only-advance' ($p0AdvanceWithoutCloseout -and $p0AdvanceWithoutCloseout.ok -ne $true -and [string]$p0AdvanceWithoutCloseout.code -eq 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED' -and $p0AfterRejectedAdvance -and [int]$p0AfterRejectedAdvance.revision -eq [int]$p0BeforeCloseout.revision -and [string]$p0AfterRejectedAdvance.currentPhase -eq 'P0') "blocked=$($p0AdvanceWithoutCloseout.code) revision=$($p0AfterRejectedAdvance.revision)"

    # A retired v1 closeout is rejected by schema/policy even when its files
    # have valid hashes.  This keeps the old Hook/P7 evidence path closed.
    $p0LegacyCloseout = if($p0BeforeCloseout){Write-E2ePhaseEvidence 'p0-legacy-schema-closeout' ([pscustomobject]@{
      schema='super-brain.phase-closeout-receipt.v1';taskId=$p0TaskId;workspaceKey=$p0WorkspaceKey;ownerSessionKey=$p0SessionKey;packageVersion=[string](Get-SuperBrainManifest $Root).version
      phase='P0';contractRevision=[int]$p0BeforeCloseout.revision;planFingerprint=[string]$p0BeforeCloseout.planReceipt.planFingerprint;phaseEvidencePolicy='h7_current';decision='accepted';rawPromptStored=$false;rawTranscriptStored=$false
    }) $p0WorkspaceRoot}else{$null}
    $p0LegacyAdvance = if($p0BeforeCloseout -and $p0LegacyCloseout){Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance P0 with retired schema evidence','-NextAction','start P1','-CurrentPhase','P1','-CurrentStep','start P1','-ExpectedRevision',[string]([int]$p0BeforeCloseout.revision),'-ExpectedPlanFingerprint',[string]$p0BeforeCloseout.planReceipt.planFingerprint,'-TransitionId','p0-advance-retired-schema','-PhaseCloseoutPath',$p0LegacyCloseout.path,'-StateRoot',$p0StateRoot)}else{$null}
    $p0AfterLegacy = if($p0BeforeCloseout){Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot)}else{$null}
    Add-Check 'p0-legacy-closeout-schema-is-rejected' ($p0LegacyAdvance -and $p0LegacyAdvance.ok -ne $true -and [string]$p0LegacyAdvance.code -in @('EXECUTION_CONTRACT_PHASE_CLOSEOUT_RETIRED_P7_EVIDENCE','EXECUTION_CONTRACT_PHASE_CLOSEOUT_SCHEMA_INVALID') -and $p0AfterLegacy -and [int]$p0AfterLegacy.revision -eq [int]$p0BeforeCloseout.revision -and [string]$p0AfterLegacy.currentPhase -eq 'P0') "blocked=$($p0LegacyAdvance.code)"

    $p0Checkpoint = if($p0BeforeCloseout){ Invoke-E2eH7ProgressCheckpoint $p0StateRoot $p0SessionKey 'P0' 'A' 'start P1' @($p0BeforeCloseout.completedSteps) 'continue the current P0 verification toward P1' 'p0-h7-checkpoint' }else{$null}
    $p0AfterCheckpoint = if($p0Checkpoint -and $p0Checkpoint.ok){ Invoke-E2eContract @('-Action','Get','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-StateRoot',$p0StateRoot) }else{$null}
    $p0Evidence = if($p0Checkpoint -and $p0Checkpoint.ok){ Invoke-E2eH7Runtime $p0StateRoot $p0SessionKey 'evidence' 'continuity' }else{$null}
    $p0CloseoutReceipt = if($p0Evidence -and $p0Evidence.ok -and $p0Evidence.value.code -eq 'H7_EVIDENCE_CURRENT' -and $p0AfterCheckpoint -and $p0AfterCheckpoint.ok -eq $true){
      Invoke-E2eContract @('-Action','CreatePhaseCloseout','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-ProjectRoot',$projectRoot,'-ExpectedRevision',[string]([int]$p0AfterCheckpoint.revision),'-ExpectedPlanFingerprint',[string]$p0AfterCheckpoint.planReceipt.planFingerprint,'-StateRoot',$p0StateRoot)
    }else{$null}
    $p0CloseoutOriginal = if($p0CloseoutReceipt -and (Test-Path -LiteralPath $p0CloseoutReceipt.path)){ Get-Content -LiteralPath $p0CloseoutReceipt.path -Raw -Encoding UTF8 }else{''}
    if($p0CloseoutReceipt -and (Test-Path -LiteralPath $p0CloseoutReceipt.path)){
      $p0TamperedCloseout = Get-Content -LiteralPath $p0CloseoutReceipt.path -Raw -Encoding UTF8 | ConvertFrom-Json
      $p0TamperedCloseout.h7.contractHash = ('0' * 64)
      [IO.File]::WriteAllText($p0CloseoutReceipt.path,($p0TamperedCloseout | ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
    }
    $p0TamperedAdvance = if($p0AfterCheckpoint -and $p0CloseoutReceipt){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance P0 with a tampered H7 closeout binding','-NextAction','start P1','-CurrentPhase','P1','-CurrentStep','start P1','-ExpectedRevision',[string]([int]$p0AfterCheckpoint.revision),'-ExpectedPlanFingerprint',[string]$p0AfterCheckpoint.planReceipt.planFingerprint,'-TransitionId','p0-advance-tampered-h7-binding','-PhaseCloseoutPath',$p0CloseoutReceipt.path,'-StateRoot',$p0StateRoot) }else{$null}
    if($p0CloseoutReceipt -and (Test-Path -LiteralPath $p0CloseoutReceipt.path)){ [IO.File]::WriteAllText($p0CloseoutReceipt.path,$p0CloseoutOriginal,[Text.UTF8Encoding]::new($false)) }
    Add-Check 'p0-h7-closeout-binding-mismatch-is-rejected' ($p0TamperedAdvance -and $p0TamperedAdvance.ok -ne $true -and [string]$p0TamperedAdvance.code -in @('EXECUTION_CONTRACT_PHASE_CLOSEOUT_H7_BINDING_MISMATCH','EXECUTION_CONTRACT_PHASE_CLOSEOUT_H7_BINDING_INVALID','EXECUTION_CONTRACT_PHASE_CLOSEOUT_BINDING_MISMATCH')) "blocked=$($p0TamperedAdvance.code)"
    $p0Advanced = if($p0AfterCheckpoint -and $p0CloseoutReceipt){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance from P0 after current H7 closeout and binding checks pass','-NextAction','start P1','-CurrentPhase','P1','-CurrentStep','start P1','-ExpectedRevision',[string]([int]$p0AfterCheckpoint.revision),'-ExpectedPlanFingerprint',[string]$p0AfterCheckpoint.planReceipt.planFingerprint,'-TransitionId','p0-advance-with-closeout','-PhaseCloseoutPath',$p0CloseoutReceipt.path,'-StateRoot',$p0StateRoot) }else{$null}
    $p0RecordedCloseouts = if($p0Advanced){ @($p0Advanced.phaseCloseouts | Where-Object { [string]$_.phase -eq 'P0' }) }else{@()}
    $p0RecordedCloseoutCount = @($p0RecordedCloseouts).Count
    $p0RecordedCloseout = @($p0RecordedCloseouts | Select-Object -First 1)[0]
    Add-Check 'p0-formal-phase-requires-h7-current-closeout' ($p0Advanced -and $p0Advanced.ok -eq $true -and [string]$p0Advanced.currentPhase -eq 'P1' -and $p0RecordedCloseoutCount -eq 1 -and [string]$p0RecordedCloseout.phaseEvidencePolicy -eq 'h7_current' -and $p0RecordedCloseout.h7 -and [string]$p0RecordedCloseout.h7.mode -eq 'hookless_turn_runtime') "code=$($p0Advanced.code) phase=$($p0Advanced.currentPhase) closeouts=$p0RecordedCloseoutCount"

    $p0Observed = if($p0Advanced -and $p0Advanced.ok -eq $true){ Invoke-E2eContract @('-Action','ObserveUser','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-UserInstruction','continue while the canonical state requires reconciliation','-RequiresReconciliation','-StateRoot',$p0StateRoot) }else{$null}
    $p0ConflictH7 = if($p0Observed -and $p0Observed.ok -eq $true){Invoke-E2eH7Runtime $p0StateRoot $p0SessionKey 'open' 'continuity'}else{$null}
    $p0BlockedLocal = if($p0Observed -and $p0Observed.ok -eq $true){ Invoke-E2eContract @('-Action','Set','-TaskId',$p0TaskId,'-WorkspaceKey',$p0WorkspaceKey,'-SessionKey',$p0SessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','only do the newest local detail','-NextAction','local-only-action-must-not-start','-StateRoot',$p0StateRoot) }else{$null}
    Add-Check 'p0-reconciliation-conflict-blocks-local-execution' ($p0Observed -and $p0Observed.needsReconciliation -eq $true -and $p0ConflictH7 -and $p0ConflictH7.value.available -eq $false -and [string]$p0ConflictH7.value.code -eq 'H7_PROJECT_PROGRESS_WITHHELD' -and $p0BlockedLocal -and $p0BlockedLocal.ok -ne $true -and [string]$p0BlockedLocal.code -eq 'EXECUTION_CONTRACT_STRUCTURAL_GUARD_REQUIRED') "observed=$($p0Observed.needsReconciliation) h7Code=$($p0ConflictH7.value.code) blocked=$($p0BlockedLocal.code)"

    $admissionRoot = Join-Path $p0StateRoot 'missing-approved-plan'
    $savedStateRoot = $env:SUPER_BRAIN_STATE_ROOT
    $savedWorkspaceKey = $env:SUPER_BRAIN_WORKSPACE_KEY
    try {
      $env:SUPER_BRAIN_STATE_ROOT = $admissionRoot
      $admission = Invoke-E2eH7Runtime $admissionRoot $stableLocalSession 'open' 'continuity'
      $admissionContracts = Join-Path $admissionRoot 'workspace\runtime-state\execution-contracts'
      Add-Check 'p0-missing-full-plan-stops-at-admission-gate' ($admission -and $admission.ok -and $admission.value.available -eq $false -and -not(Test-Path -LiteralPath $admissionContracts -PathType Container)) "h7Code=$($admission.value.code) contractDirectoryExists=$(Test-Path -LiteralPath $admissionContracts -PathType Container)"
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
  $variantFormal = if($variantInitial -and $variantInitial.ok -eq $true){Invoke-E2eContract @('-Action','Set','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','enter P2.2 evidence phase with H7 current evidence','-NextAction','inventory evidence','-CurrentPhase','P2.2','-CurrentStep','inventory evidence','-PhaseEvidencePolicy','h7_current','-ExpectedRevision',[string]([int]$variantInitial.revision),'-ExpectedPlanFingerprint',[string]$variantInitial.planReceipt.planFingerprint,'-TransitionId','generic-enter-p2-2','-StateRoot',$variantStateRoot)}else{$null}
  $variantInitialH7 = if($variantFormal -and $variantFormal.ok -eq $true){Invoke-E2eH7Runtime $variantStateRoot $variantSessionKey 'open' 'continuity'}else{$null}
  $variantFormalCheckpoint = if($variantFormal -and $variantFormal.ok -eq $true){ Invoke-E2eH7ProgressCheckpoint $variantStateRoot $variantSessionKey 'P2.2' 'inventory evidence' 'inventory evidence' @($variantFormal.completedSteps) 'continue the P2.2 verification with current H7 evidence' 'generic-initial-h7-checkpoint' }else{$null}
  $variantAfterFormalCheckpoint = if($variantFormalCheckpoint -and $variantFormalCheckpoint.ok){ Invoke-E2eContract @('-Action','Get','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-StateRoot',$variantStateRoot) }else{$null}
  $variantH7 = if($variantAfterFormalCheckpoint -and $variantAfterFormalCheckpoint.ok -eq $true){Invoke-E2eH7Runtime $variantStateRoot $variantSessionKey 'open' 'continuity'}else{$variantInitialH7}
  $variantNativeObservation = New-E2eH7Observation $variantH7
  $variantAfterNative = if($variantH7 -and $variantH7.ok){Invoke-E2eContract @('-Action','Get','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-StateRoot',$variantStateRoot)}else{$null}
  $variantReady = if($variantAfterNative -and $variantAfterNative.ok -eq $true){Invoke-E2eContract @('-Action','Set','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','reconcile native P2.2 current-plan observation','-NextAction','inventory evidence','-CurrentPhase','P2.2','-CurrentStep','inventory evidence','-ExpectedRevision',[string]([int]$variantAfterNative.revision),'-ExpectedPlanFingerprint',[string]$variantAfterNative.planReceipt.planFingerprint,'-TransitionId','generic-reconcile-native-current-plan','-StateRoot',$variantStateRoot)}else{$null}
  $variantBlocked = if($variantReady -and $variantReady.ok -eq $true){Invoke-E2eContract @('-Action','Set','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance P2.2 without behavior proof','-NextAction','verify transition','-CurrentPhase','P2.3','-CurrentStep','verify transition','-ExpectedRevision',[string]([int]$variantReady.revision),'-ExpectedPlanFingerprint',[string]$variantReady.planReceipt.planFingerprint,'-TransitionId','generic-blocked-p2-3','-StateRoot',$variantStateRoot)}else{$null}
  $variantCheckpoint = if($variantReady){ Invoke-E2eH7ProgressCheckpoint $variantStateRoot $variantSessionKey 'P2.2' 'inventory evidence' 'verify transition' @($variantReady.completedSteps) 'continue P2.2 after the native H7 observation' 'generic-h7-checkpoint' }else{$null}
  $variantAfterCheckpoint = if($variantCheckpoint -and $variantCheckpoint.ok){ Invoke-E2eContract @('-Action','Get','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-StateRoot',$variantStateRoot) }else{$null}
  $variantEvidence = if($variantCheckpoint -and $variantCheckpoint.ok){ Invoke-E2eH7Runtime $variantStateRoot $variantSessionKey 'evidence' 'continuity' }else{$null}
  $variantReceipt = if($variantEvidence -and $variantEvidence.ok -and $variantEvidence.value.code -eq 'H7_EVIDENCE_CURRENT' -and $variantAfterCheckpoint -and $variantAfterCheckpoint.ok -eq $true){
    Invoke-E2eContract @('-Action','CreatePhaseCloseout','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-ProjectRoot',$projectRoot,'-ExpectedRevision',[string]([int]$variantAfterCheckpoint.revision),'-ExpectedPlanFingerprint',[string]$variantAfterCheckpoint.planReceipt.planFingerprint,'-StateRoot',$variantStateRoot)
  }else{$null}
  $variantAdvanced = if($variantAfterCheckpoint -and $variantReceipt){Invoke-E2eContract @('-Action','Set','-TaskId',$variantTaskId,'-WorkspaceKey',$variantWorkspaceKey,'-SessionKey',$variantSessionKey,'-FocusId','main-line','-InstructionMode','continue','-LatestUserInstruction','advance P2.2 after current H7 closeout','-NextAction','verify transition','-CurrentPhase','P2.3','-CurrentStep','verify transition','-ExpectedRevision',[string]([int]$variantAfterCheckpoint.revision),'-ExpectedPlanFingerprint',[string]$variantAfterCheckpoint.planReceipt.planFingerprint,'-TransitionId','generic-advance-p2-3','-PhaseCloseoutPath',$variantReceipt.path,'-StateRoot',$variantStateRoot)}else{$null}
  $variantCloseout = @($variantAdvanced.phaseCloseouts | Where-Object { [string]$_.phase -eq 'P2.2' } | Select-Object -First 1)[0]
  Add-Check 'phase-closeout-generalizes-h7-current-policy-beyond-p0' ($variantReady -and $variantReady.ok -eq $true -and $variantNativeObservation.status -eq 'passed' -and $variantBlocked -and [string]$variantBlocked.code -eq 'EXECUTION_CONTRACT_PHASE_CLOSEOUT_REQUIRED' -and $variantAdvanced -and $variantAdvanced.ok -eq $true -and [string]$variantAdvanced.currentPhase -eq 'P2.3' -and $variantCloseout -and [string]$variantCloseout.phaseEvidencePolicy -eq 'h7_current' -and $variantCloseout.h7 -and [string]$variantCloseout.h7.mode -eq 'hookless_turn_runtime') "blocked=$($variantBlocked.code) phase=$($variantAdvanced.currentPhase)"
  if(-not [string]::IsNullOrWhiteSpace($variantTaskId)){Remove-TaskArtifacts $variantTaskId}
  } finally {
    $env:SUPER_BRAIN_STATE_ROOT = $variantPreviousStateRoot
    if($null -eq $variantPreviousWorkspaceKey){Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_WORKSPACE_KEY=$variantPreviousWorkspaceKey}
  }
} catch { Add-Check 'phase-closeout-generalizes-h7-current-policy-beyond-p0' $false $_.Exception.Message }

$failed = @($checks | Where-Object { $_.ok -ne $true })
Restore-TaskContext
$result=[pscustomobject]@{ ok=($failed.Count -eq 0); checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.autonomous-executor-e2e.v1'; version=(Get-SuperBrainManifest $Root).version; failed=$failed.Count; checks=@($checks); guard='Natural execute goals and threshold-approved plans create task checkpoints; question/plan-only goals do not mutate; E2E runs under an isolated state root.'; path=$outPath; sandboxStateRoot=if($KeepSandbox){$sandboxStateRoot}else{''} }
Write-JsonUtf8NoBom $outPath $result 12
$jsonText = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8
$exitCode = if($result.ok){0}else{1}
} finally {
  $env:SUPER_BRAIN_STATE_ROOT = $originalStateRoot
  if($null -eq $originalWorkspaceKey){ Remove-Item Env:\SUPER_BRAIN_WORKSPACE_KEY -ErrorAction SilentlyContinue }else{$env:SUPER_BRAIN_WORKSPACE_KEY=$originalWorkspaceKey}
  if($null -eq $originalLocalSession){ Remove-Item Env:\SUPER_BRAIN_LOCAL_SESSION_ID -ErrorAction SilentlyContinue }else{$env:SUPER_BRAIN_LOCAL_SESSION_ID=$originalLocalSession}
  if(-not $KeepSandbox){ Remove-E2eSandbox }
  try { Set-Location -LiteralPath $originalLocation } catch {}
}
if($Json){$jsonText}else{Write-Host "AUTONOMOUS_EXECUTOR_E2E ok=$($result.ok) failed=$($result.failed) path=$outPath"}
exit $exitCode
