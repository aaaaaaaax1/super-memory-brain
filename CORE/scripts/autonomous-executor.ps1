param(
  [string]$Goal = '',
  [string]$TaskName = '',
  [string]$SessionTitle = '',
  [string[]]$PlanSteps = @(),
  [switch]$ApprovedPlan,
  [switch]$Json,
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Text
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$outPath = Join-Path $workspace 'last-autonomous-executor.json'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function Limit-Text([string]$Value,[int]$Max=500){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Get-SafeTaskId([string]$Value){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if($safe.Length -gt 120){return $safe.Substring(0,120)}; return $safe }
function Quote-PowerShellArg([string]$Value){ return "'" + (([string]$Value) -replace "'", "''") + "'" }
function Invoke-JsonScript([string]$ScriptName,[string[]]$ScriptArgs){
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  $parts = @('&', (Quote-PowerShellArg $scriptPath))
  foreach($arg in @($ScriptArgs)){ if(([string]$arg) -like '-*'){ $parts += [string]$arg } else { $parts += (Quote-PowerShellArg ([string]$arg)) } }
  $parts += '-Json'
  $raw=@(Invoke-Expression ($parts -join ' ') 2>&1)
  $text=($raw|ForEach-Object{[string]$_}) -join "`n"
  $start=$text.IndexOf('{')
  if($start -lt 0){ throw "No JSON from ${ScriptName}: $text" }
  return ($text.Substring($start)|ConvertFrom-Json)
}

$inputText = (($Text -join ' ').Trim())
$workspaceKey = Get-SuperBrainWorkspaceKey
$hostPlatform = if(-not[string]::IsNullOrWhiteSpace([string]$env:SUPER_BRAIN_HOST_PLATFORM)){[string]$env:SUPER_BRAIN_HOST_PLATFORM}elseif(-not[string]::IsNullOrWhiteSpace([string]$env:CODEX_THREAD_ID)){'codex'}else{'unknown'}
$hostAgent = if(-not[string]::IsNullOrWhiteSpace([string]$env:SUPER_BRAIN_HOST_AGENT)){[string]$env:SUPER_BRAIN_HOST_AGENT}else{$hostPlatform}
if([string]::IsNullOrWhiteSpace($Goal)){ $Goal = $inputText }
if([string]::IsNullOrWhiteSpace($TaskName)){ $TaskName = if($Goal.Length -gt 80){$Goal.Substring(0,80)}else{$Goal} }
if([string]::IsNullOrWhiteSpace($SessionTitle)){ $SessionTitle = $TaskName }

$gate = Invoke-JsonScript -ScriptName 'intent-gate.ps1' -ScriptArgs @($Goal)
$router = Invoke-JsonScript -ScriptName 'intent-router.ps1' -ScriptArgs @('-Text',$Goal)
$scout = Invoke-JsonScript -ScriptName 'memory-scout.ps1' -ScriptArgs @('-Goal',$Goal,'-TopK','4')
$why = Invoke-JsonScript -ScriptName 'why-plan.ps1' -ScriptArgs @('-Goal',$Goal,'-Intent',[string]$gate.intent,'-Evidence','memory-scout.ps1')

$policy = Get-Content -LiteralPath (Join-Path $Root 'memory-policy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$minimumSteps = [int]$policy.checkpointLifecycle.minimumAutoCheckpointSteps
if($minimumSteps -lt 1){ $minimumSteps = 3 }
$normalizedSteps = @($PlanSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$approvedExecution = ($ApprovedPlan -and $normalizedSteps.Count -ge $minimumSteps)
$shouldCreateTask = ($approvedExecution -or $gate.intent -eq 'execute' -or $gate.shouldExecute -eq $true)
$task = $null
$context = $null
$routeLock = $null
$acceptedConstraints = $null
$cognitivePreflight = $null
$runtimeDrift = $null
$checkpoint = $null
$executionContract = $null
$executionSessionKey = ''
$contextBindingOk = $false
$checkpointReason = 'not an approved plan with enough steps'
if($shouldCreateTask){
  $sessionSeed = [string]$env:CODEX_THREAD_ID
  if([string]::IsNullOrWhiteSpace($sessionSeed)){
    $sessionSeed='autonomous-'+(Get-SuperBrainStableHash ($workspaceKey+'|'+$TaskName+'|'+$Goal) 24)
  }
  $executionSessionKey = Get-SuperBrainHostSessionKey $sessionSeed
  $task = Invoke-JsonScript -ScriptName 'task-register.ps1' -ScriptArgs @('-Auto','-WorkspaceKey',$workspaceKey,'-TaskName',$TaskName,'-Status','active','-Goal',$Goal,'-CurrentStep','Autonomous executor initialized: intent/memory/why-plan collected.','-NextAction','Execute the smallest verified route from why-plan.','-SessionId',$executionSessionKey,'-SessionTitle',$SessionTitle,'-HostPlatform',$hostPlatform,'-HostAgent',$hostAgent,'-Reason','automatic cognitive executor authorized by natural goal/execute intent','-Evidence','last-memory-scout.json;last-why-plan.json')
  $taskId = [string]$task.taskId
  $taskOwnerAgentId = if ($task -and $task.PSObject.Properties['agentId']) { [string]$task.agentId } else { '' }
  $routeLock = Invoke-JsonScript -ScriptName 'goal-route-lock.ps1' -ScriptArgs @('-Action','Create','-TaskId',$taskId,'-AcceptedGoal',$Goal,'-AcceptedRoute','intent gate -> memory scout -> why-plan -> task card -> route lock -> preflight -> drift checkpoint -> execute -> verify','-NonGoals','do not mutate for plan/status-only requests','-MustPreserve','automatic task card, route lock, preflight, drift checkpoint, and context updates','-MustNotDriftTo','manual reminder driven workflow','-ApprovalEvidence','autonomous-executor execute intent')
  $acceptedConstraints = Invoke-JsonScript -ScriptName 'accepted-constraints-preflight.ps1' -ScriptArgs @('-Query',$Goal,'-Scope','autonomous-executor')
  $cognitivePreflight = Invoke-JsonScript -ScriptName 'cognitive-preflight.ps1' -ScriptArgs @('-Query',$Goal,'-Scope','autonomous-executor')
  $runtimeDrift = Invoke-JsonScript -ScriptName 'runtime-drift-checkpoint.ps1' -ScriptArgs @('-Phase','BeforeAct','-TaskId',$taskId,'-WorkspaceKey',$workspaceKey,'-ObservedAction','autonomous executor initialized task card, route lock, accepted constraints preflight, cognitive preflight, and runtime drift checkpoint before execution','-Query',$Goal)
  if($ApprovedPlan -and $normalizedSteps.Count -ge $minimumSteps -and $runtimeDrift.ok -eq $true -and $runtimeDrift.unresolvedDrift -ne $true){
    $checkpointRaw = & (Join-Path $PSScriptRoot 'checkpoint-writer.ps1') -Action Start -TaskId $taskId -TaskName $TaskName -SessionId $executionSessionKey -SessionName $SessionTitle -WorkspaceKey $workspaceKey -HostPlatform $hostPlatform -HostAgent $hostAgent -Goal $Goal -CurrentPhase approved_plan -CurrentStep ([string]$normalizedSteps[0]) -NextAction ([string]$normalizedSteps[0]) -PendingSteps $normalizedSteps -Evidence @('approved plan; autonomous-executor.ps1') -Source autonomous-executor.ps1 -Json
    $checkpoint = $checkpointRaw | ConvertFrom-Json
    $checkpointReason = "approved plan has $($normalizedSteps.Count) steps; threshold=$minimumSteps"
  } elseif($ApprovedPlan -and ($runtimeDrift.ok -ne $true -or $runtimeDrift.unresolvedDrift -eq $true)) {
    $checkpointReason = 'approved plan was not checkpointed because the execution hard gate failed'
  } elseif($ApprovedPlan) {
    $checkpointReason = "approved plan has $($normalizedSteps.Count) steps; threshold=$minimumSteps"
  }
}

$executionGateBaseOk = (-not $shouldCreateTask) -or ($null -ne $task -and -not [string]::IsNullOrWhiteSpace([string]$task.taskId) -and $routeLock.ok -eq $true -and $routeLock.active -eq $true -and $acceptedConstraints.ok -eq $true -and $cognitivePreflight.ok -eq $true -and $runtimeDrift.ok -eq $true -and $runtimeDrift.unresolvedDrift -ne $true)
if($shouldCreateTask-and$executionGateBaseOk-and$task){
  $initialStep=if($normalizedSteps.Count-gt0){[string]$normalizedSteps[0]}else{'Execute the smallest verified route from why-plan.'}
  $contractParameters=@{
    Action='Set';TaskId=[string]$task.taskId;WorkspaceKey=$workspaceKey;SessionKey=$executionSessionKey
    FocusId='main-line';FocusLabel=$TaskName;InstructionMode='continue';LatestUserInstruction=$Goal
    AssistantCommitment='Execute the governed autonomous plan and verify before completion.'
    LastConfirmedSentence='Autonomous execution contract initialized from the accepted goal.';LastConfirmedSource='assistant_commitment'
    NextAction=$initialStep;CurrentPhase=$(if($approvedExecution){'approved_plan'}else{'execution'});CurrentStep=$initialStep
    Evidence=@('task-register.ps1;goal-route-lock.ps1;runtime-drift-checkpoint.ps1')
    Constraints=@('preserve task, workspace, session, and current-evidence binding')
    AcceptanceCriteria=@($why.successCriteria|ForEach-Object{[string]$_})
    PendingSteps=@($normalizedSteps);EnableCanonicalPlan=[bool]$approvedExecution;Source='autonomous-executor.ps1';NoExit=$true;Json=$true
  }
  $executionContractRaw=@(& (Join-Path $PSScriptRoot 'execution-contract.ps1') @contractParameters 2>&1)
  $executionContractText=($executionContractRaw|ForEach-Object{[string]$_})-join"`n"
  if($LASTEXITCODE-ne0-or[string]::IsNullOrWhiteSpace($executionContractText)){throw "EXECUTION_CONTRACT_CREATE_FAILED: $executionContractText"}
  $executionContract=$executionContractText|ConvertFrom-Json
  if($executionContract.ok-eq$true){
    $context = Invoke-JsonScript -ScriptName 'current-task-context.ps1' -ScriptArgs @('-Action','Create','-TaskId',[string]$task.taskId,'-WorkspaceKey',$workspaceKey,'-AgentId',$taskOwnerAgentId,'-SessionId',$executionSessionKey,'-HostPlatform',$hostPlatform,'-HostAgent',$hostAgent,'-AcceptedGoal',$Goal,'-AcceptedRoute','intent gate -> memory scout -> why-plan -> task card -> route lock -> preflight -> drift checkpoint -> execution contract -> current context -> execute -> verify','-NonGoals','do not mutate for plan/status-only requests','-MustPreserve','automatic task card, route lock, execution contract, preflight, drift checkpoint, and context updates','-MustNotDriftTo','manual reminder driven workflow','-Evidence','last-autonomous-executor.json;execution-contract.ps1')
    $contextBindingOk=($context.ok-eq$true-and[string]$context.bindingState-eq'bound'-and[string]$context.authorizationState-eq'authorizing'-and[string]$context.ownerSessionKey-eq[string]$executionContract.ownerSessionKey)
  }
}
$executionContractOk = (-not $shouldCreateTask) -or ($executionContract-and$executionContract.ok-eq$true-and$executionContract.sessionBound-eq$true-and-not[string]::IsNullOrWhiteSpace([string]$executionContract.ownerSessionKey))
$executionGateOk = $executionGateBaseOk-and$executionContractOk-and((-not$shouldCreateTask)-or$contextBindingOk)
$autonomyAuthorization = $null
if($executionGateOk -and $checkpoint -and $approvedExecution -and $task){
  $safeTaskId = Get-SafeTaskId ([string]$task.taskId)
  if(-not [string]::IsNullOrWhiteSpace($safeTaskId)){
    $authorizationRoot = Join-Path $workspace 'runtime-state\autonomy-authorizations'
    if(-not(Test-Path -LiteralPath $authorizationRoot)){New-Item -ItemType Directory -Force -Path $authorizationRoot|Out-Null}
    $authorizationPath = Join-Path $authorizationRoot ($safeTaskId + '.json')
    $authorization = [pscustomobject]@{
      schema='super-brain.governed-autonomy-authorization.v1'
      recordId='autonomy-auth-' + $safeTaskId
      taskId=[string]$task.taskId
      workspaceKey=$workspaceKey
      packageVersion=(Get-SuperBrainManifest $Root).version
      authorizedAt=(Get-Date).ToString('o')
      source='autonomous-executor.ps1'
      authorizationMode='approved_plan'
      autonomyTier=if($why.collaborationGate){[string]$why.collaborationGate.autonomyTier}else{''}
      executionHardGateOk=$true
      checkpointCreated=$true
      checkpointTaskId=[string]$checkpoint.taskId
      executionContractPath=[string]$executionContract.path
      executionContractRevision=[int]$executionContract.revision
      routeHash=if($routeLock){[string]$routeLock.routeHash}else{''}
      guardHash=if($acceptedConstraints){[string]$acceptedConstraints.guardHash}else{''}
      rawGoalStored=$false
      rawPromptStored=$false
    }
    Write-JsonUtf8NoBom $authorizationPath $authorization 10
    $autonomyAuthorization = [pscustomobject]@{ created=$true; recordId=$authorization.recordId; taskId=$authorization.taskId; sha256=(Get-FileHash -LiteralPath $authorizationPath -Algorithm SHA256).Hash.ToLowerInvariant(); path=$authorizationPath; rawGoalStored=$false; rawPromptStored=$false }
  }
}
$result=[pscustomobject]@{
  ok=$executionGateOk; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.autonomous-executor.v1'; version=(Get-SuperBrainManifest $Root).version
  input=Limit-Text $inputText 700; goal=Limit-Text $Goal 700; intent=[pscustomobject]@{ gate=$gate.intent; canMutate=$gate.canMutate; shouldExecute=$gate.shouldExecute; router=$router.intent; confidence=$router.confidence }
  taskCard=[pscustomobject]@{ shouldCreate=$shouldCreateTask; taskId=if($task){$task.taskId}else{''}; status=if($task){$task.status}else{'not_created'}; reason=if($approvedExecution){'approved plan meets checkpoint threshold'}elseif($shouldCreateTask){'execute intent or authorization detected'}else{'plan/status/clarify intent'} }
  memoryScout=[pscustomobject]@{ cards=@($scout.cards).Count; path=$scout.path }
  whyPlan=[pscustomobject]@{ why=$why.why; successCriteria=@($why.successCriteria); verificationPlan=@($why.verificationPlan); path=$why.path }
  currentTaskContext=[pscustomobject]@{ created=($null -ne $context); taskId=if($context){$context.taskId}else{''} }
  executionContract=[pscustomobject]@{ created=($null-ne$executionContract); ok=($executionContract-and$executionContract.ok-eq$true); taskId=if($executionContract){[string]$executionContract.taskId}else{''}; ownerSessionKey=if($executionContract){[string]$executionContract.ownerSessionKey}else{''}; revision=if($executionContract){[int]$executionContract.revision}else{0}; path=if($executionContract){[string]$executionContract.path}else{''} }
  checkpoint=[pscustomobject]@{ created=($null -ne $checkpoint); approved=[bool]$ApprovedPlan; stepCount=@($PlanSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count; taskId=if($checkpoint){$checkpoint.taskId}else{''}; reason=$checkpointReason }
  autonomyAuthorization=if($autonomyAuthorization){$autonomyAuthorization}else{[pscustomobject]@{created=$false;recordId='';taskId='';sha256='';path='';rawGoalStored=$false;rawPromptStored=$false}}
  executionHardGate=[pscustomobject]@{
    required=$shouldCreateTask
    taskId=if($task){$task.taskId}else{''}
    taskCardOk=($null -ne $task -and -not [string]::IsNullOrWhiteSpace([string]$task.taskId))
    currentTaskContextOk=($null -ne $context -and [string]$context.taskId -eq [string]$task.taskId-and$contextBindingOk)
    contextBindingOk=$contextBindingOk
    executionContractOk=$executionContractOk
    routeLockOk=($null -ne $routeLock -and $routeLock.ok -eq $true -and $routeLock.active -eq $true)
    acceptedConstraintsOk=($null -ne $acceptedConstraints -and $acceptedConstraints.ok -eq $true)
    cognitivePreflightOk=($null -ne $cognitivePreflight -and $cognitivePreflight.ok -eq $true)
    runtimeDriftOk=($null -ne $runtimeDrift -and $runtimeDrift.ok -eq $true -and $runtimeDrift.unresolvedDrift -ne $true)
    routeHash=if($routeLock){$routeLock.routeHash}else{''}
    guardHash=if($acceptedConstraints){$acceptedConstraints.guardHash}else{''}
    capabilitiesCovered=@('rule_auto_application','current_task_detection','real_user_path_acceptance','self_learning_loop_hook','multi_agent_non_regression','compact_report_discipline','rule_skill_fusion','ponytail_minimal_safe_change','grill_me_challenge_and_acceptance')
    ruleSkillFusion=[pscustomobject]@{
      active=$shouldCreateTask
      mode='rules_as_execution_constraints_not_menu_calls'
      strategy='dynamic_rule_skill_fusion_strategy_from_capability_map'
      ruleChain=@('pre_action_constraint','challenge_gate','review_verifier')
      ponytail='Before implementation, prefer skip/delete/stdlib/native/existing dependency/smallest safe diff; never cut validation, privacy, error handling, tests, rollback, or explicit user requirements.'
      grillMe='Before committing to a plan, challenge weak assumptions, unresolved requirements, counterexamples, acceptance evidence, and non-goals; explore code instead of asking when evidence is local.'
      reviewVerifier='After mutation and before completion, use review/chinese-code-review capability as evidence-backed verifier; it cannot replace tests or approve unevidenced completion.'
      guard='Super Brain should know available rule skills and apply them as pre-action constraints, challenge gates, and completion verifiers when they fit the task, not wait for the user to name them.'
    }
    evidence=@('task-register.ps1','current-task-context.ps1','goal-route-lock.ps1','accepted-constraints-preflight.ps1','cognitive-preflight.ps1','runtime-drift-checkpoint.ps1','task-verification.ps1','reflection-promotion.ps1','agent-bridge-channel.ps1','ponytail minimal safe change ladder','grill-me challenge/acceptance questioning','concise conclusion/evidence/risk/next report shape')
  }
  guard='Natural goals and execution approvals should automatically run intent, memory scouting, why-plan, task card/context creation, route lock, accepted constraints/cognitive preflight, runtime drift checkpoint, then execution/verification. Users should not need to request these mechanics.'
  nextAction=if($shouldCreateTask){'Continue concrete implementation and update the same task card at material steps; verify task-specific evidence before completion.'}else{'Return plan/status/clarification without mutation unless user authorizes execution.'}
  path=$outPath
}
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "AUTONOMOUS_EXECUTOR ok=$executionGateOk intent=$($gate.intent) taskId=$($result.taskCard.taskId) path=$outPath"}
if(-not $executionGateOk){exit 1}; exit 0
