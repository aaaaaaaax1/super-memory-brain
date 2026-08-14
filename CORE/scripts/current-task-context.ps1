param(
  [ValidateSet('Create','Status','Update','Clear','Preview')]
  [string]$Action = 'Status',
  [string]$TaskId = '',
  [string]$AcceptedGoal = '',
  [string[]]$AcceptedRoute = @(),
  [string[]]$NonGoals = @(),
  [string[]]$MustPreserve = @(),
  [string[]]$MustNotDriftTo = @(),
  [string[]]$Evidence = @(),
  [string]$WorkspaceKey = '',
  [int]$ExpectedRevision = -1,
  [string]$AgentId = 'super-brain-control-plane',
  [string]$SessionId = '',
  [string]$Platform = 'super-brain',
  [string]$HostAgent = '',
  [string]$HostAgentId = '',
  [string]$HostPlatform = '',
  [string]$OwnerWorkspace = '',
  [string]$ContractPath = '',
  [string]$ContractFileName = '',
  [string]$ContractHash = '',
  [int]$TaskStateRevisionOverride = 0,
  [int]$MaxAgeHours = 24,
  [switch]$NoExit,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$scopeRoot = Join-Path $workspace 'guard-state'
$contextRoot = Join-Path $scopeRoot 'current-task-contexts'
$pointerRoot = Join-Path $scopeRoot 'current-task-context-pointers'
foreach ($dir in @($workspace,$scopeRoot,$contextRoot,$pointerRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
$contextPath = Join-Path $workspace 'current-task-context.json'
$outPath = Join-Path $workspace 'last-current-task-context.json'
$resolvedWorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey

function Write-ContextResult([object]$Value,[int]$ExitCode=0){
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "CURRENT_TASK_CONTEXT ok=$($Value.ok) status=$($Value.status) path=$($Value.path)"}
  if($NoExit){$script:CurrentTaskContextExitCode=$ExitCode;return}
  exit $ExitCode
}

function Limit-Text([string]$Value,[int]$Max=500){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function New-HostMetadata { return [pscustomobject]@{ agentName=Limit-Text $HostAgent 80; agentId=Limit-Text $HostAgentId 120; platform=Limit-Text $HostPlatform 80; authority='metadata_only' } }
function New-TaskId([string]$Goal){ $seed=if([string]::IsNullOrWhiteSpace($Goal)){[guid]::NewGuid().ToString('n')}else{$Goal + '|' + (Get-SuperBrainLocalNow).ToString('yyyyMMddHHmmss')}; $sha=[Security.Cryptography.SHA256]::Create(); 'task-' + (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))[0..5] | ForEach-Object { $_.ToString('x2') })) }
function Get-ScopedContextPath([string]$Id){ if([string]::IsNullOrWhiteSpace($Id)){return ''}; return (Get-SuperBrainCanonicalTaskPath $contextRoot $Id '.json') }
function Get-WorkspacePointerPath([string]$Key=$resolvedWorkspaceKey){ return (Get-SuperBrainCanonicalTaskPath $pointerRoot (Get-SuperBrainWorkspaceKey $Key) '.json') }
function Read-JsonFile([string]$Path){ if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path)){return $null}; try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null} }
function Test-ContextWorkspaceScope($Context,[string]$ExpectedWorkspaceKey=$resolvedWorkspaceKey){
  return ($Context -and $Context.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$Context.workspaceKey) $ExpectedWorkspaceKey))
}
function Read-Context([string]$Id=''){
  if(-not[string]::IsNullOrWhiteSpace($Id)){
    $scoped=Read-JsonFile (Get-ScopedContextPath $Id)
    if($scoped -and (Test-ContextWorkspaceScope $scoped)){return $scoped}
    $legacy=Read-JsonFile $contextPath
    if($legacy-and[string]$legacy.taskId-eq$Id-and(Test-ContextWorkspaceScope $legacy)){return $legacy}
    return $null
  }
  $pointer=Read-JsonFile (Get-WorkspacePointerPath $resolvedWorkspaceKey)
  if($pointer -and (Test-ContextWorkspaceScope $pointer)){return $pointer}
  $legacy=Read-JsonFile $contextPath
  if($legacy-and(Test-ContextWorkspaceScope $legacy)){return $legacy}
  return $null
}
function Import-LegacyContext{
  $legacy=Read-JsonFile $contextPath
  if(-not$legacy-or[string]::IsNullOrWhiteSpace([string]$legacy.taskId)-or-not(Test-ContextWorkspaceScope $legacy)){return}
  $scopedPath=Get-ScopedContextPath ([string]$legacy.taskId)
  if(-not(Test-Path -LiteralPath $scopedPath)){
    Write-JsonUtf8NoBom $scopedPath $legacy 12
    $null=Sync-SuperBrainTaskState ([string]$legacy.taskId) 'context' 'upsert' $scopedPath 'current-task-context.ps1:legacy-import'
  }
  $workspacePointerPath=Get-WorkspacePointerPath ([string]$legacy.workspaceKey)
  if(-not(Test-Path -LiteralPath $workspacePointerPath)){Write-JsonUtf8NoBom $workspacePointerPath $legacy 12}
}
function Get-ActiveContexts([string]$ExcludeTaskId='',[string]$ExpectedWorkspaceKey=$resolvedWorkspaceKey){
  $items=@()
  foreach($file in @(Get-ChildItem -LiteralPath $contextRoot -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)){
    $item=Read-JsonFile $file.FullName
    if(-not$item-or[string]$item.status-ne'active'-or-not(Test-ContextWorkspaceScope $item $ExpectedWorkspaceKey)){continue}
    if(-not[string]::IsNullOrWhiteSpace($ExcludeTaskId)-and[string]$item.taskId-eq$ExcludeTaskId){continue}
    $items+=$item
  }
  return @($items)
}
function Remove-CompatibilityContext([string]$ChangedTaskId){
  $replacement=$null
  $changed=$false
  $workspacePointerPath=Get-WorkspacePointerPath $resolvedWorkspaceKey
  $pointer=Read-JsonFile $workspacePointerPath
  if($pointer-and[string]$pointer.taskId-eq$ChangedTaskId-and(Test-ContextWorkspaceScope $pointer)){
    $replacement=@(Get-ActiveContexts -ExcludeTaskId $ChangedTaskId -ExpectedWorkspaceKey $resolvedWorkspaceKey)|Select-Object -First 1
    if($replacement){Write-JsonUtf8NoBom $workspacePointerPath $replacement 12}elseif(Test-Path -LiteralPath $workspacePointerPath){Remove-Item -LiteralPath $workspacePointerPath -Force}
    $changed=$true
  }
  $legacy=Read-JsonFile $contextPath
  if($legacy-and[string]$legacy.taskId-eq$ChangedTaskId-and(Test-ContextWorkspaceScope $legacy)){
    if(-not$replacement){$replacement=@(Get-ActiveContexts -ExcludeTaskId $ChangedTaskId -ExpectedWorkspaceKey $resolvedWorkspaceKey)|Select-Object -First 1}
    if($replacement){Write-JsonUtf8NoBom $contextPath $replacement 12}elseif(Test-Path -LiteralPath $contextPath){Remove-Item -LiteralPath $contextPath -Force}
    $changed=$true
  }
  return $changed
}
function Get-GuardTaskToken([string]$Id){
  if([string]::IsNullOrWhiteSpace($Id)){return ''}
  $safe=(($Id -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if($safe.Length-gt120){$safe=$safe.Substring(0,120)}
  return $safe
}
function Guard-Path([string]$Kind,[string]$Id,[switch]$Directory){
  $safe=Get-GuardTaskToken $Id
  if([string]::IsNullOrWhiteSpace($safe)){return ''}
  $base=Join-Path $scopeRoot $Kind
  if($Kind-in@('goal-route-locks','route-checkpoints')){return (Get-SuperBrainCanonicalTaskPath $base $Id '.json')}
  if($Directory){return (Join-Path $base $safe)}
  return (Join-Path $base ($safe+'.json'))
}
function Test-ContextTaskStateBinding($Context){
  if(-not$Context-or[string]$Context.bindingState-ne'bound'-or[string]$Context.authorizationState-ne'authorizing'){return [pscustomobject]@{current=$true;reason='not_required'}}
  $taskId=[string]$Context.taskId
  $projectionPath=Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $taskId '.json'
  $projection=Read-JsonFile $projectionPath
  $contextFile=Get-ScopedContextPath $taskId
  if(-not$projection-or-not$projection.entities-or-not$projection.entities.PSObject.Properties['context']-or-not(Test-Path -LiteralPath $contextFile -PathType Leaf)){return [pscustomobject]@{current=$false;reason='task_state_projection_missing'}}
  $entity=$projection.entities.context
  $hash=(Get-FileHash -LiteralPath $contextFile -Algorithm SHA256).Hash
  if([int]$projection.revision-ne[int]$Context.taskStateRevision-or-not$entity-or[string]$entity.status-ne'active'-or[string]$entity.path-ne$contextFile-or-not[string]::Equals([string]$entity.hash,$hash,[StringComparison]::OrdinalIgnoreCase)){return [pscustomobject]@{current=$false;reason='task_state_projection_stale';projectionRevision=if($projection){[int]$projection.revision}else{0};contextRevision=[int]$Context.taskStateRevision}}
  return [pscustomobject]@{current=$true;reason='task_state_projection_current'}
}
function Test-ContextFresh($Context,[int]$Hours){
  if(-not $Context){ return [pscustomobject]@{ fresh=$false; ageHours=$null; reason='missing' } }
  $checked = $null
  try { $checked = [DateTimeOffset]::Parse([string]$Context.checkedAt,[Globalization.CultureInfo]::InvariantCulture) } catch {}
  if(-not $checked){ return [pscustomobject]@{ fresh=$false; ageHours=$null; reason='missing_or_invalid_checkedAt' } }
  $age = ((Get-SuperBrainUtcNow) - $checked.ToUniversalTime()).TotalHours
  if($Hours -gt 0 -and $age -gt $Hours){ return [pscustomobject]@{ fresh=$false; ageHours=[Math]::Round($age,2); reason='stale_checkedAt' } }
  $manifestVersion = [string](Get-SuperBrainManifest $Root).version
  if(-not [string]::IsNullOrWhiteSpace([string]$Context.version) -and [string]$Context.version -ne $manifestVersion){ return [pscustomobject]@{ fresh=$false; ageHours=[Math]::Round($age,2); reason='version_mismatch' } }
  $binding=Get-CurrentExecutionContractBinding ([string]$Context.taskId) ([string]$Context.workspaceKey)
  if($binding){
    $mismatch=([string]$Context.bindingState-ne'bound'-or[int]$Context.contractRevision-ne[int]$binding.contractRevision-or[string]$Context.planFingerprint-ne[string]$binding.planFingerprint-or[string]$Context.ownerSessionKey-ne[string]$binding.ownerSessionKey-or[string]$Context.contractFileName-ne[string]$binding.contractFileName-or-not[string]::Equals([string]$Context.targetHash,[string]$binding.targetHash,[StringComparison]::OrdinalIgnoreCase)-or[string]$Context.canonicalPlanId-ne[string]$binding.canonicalPlanId-or[int]$Context.canonicalGeneration-ne[int]$binding.canonicalGeneration-or[string]$Context.canonicalFingerprint-ne[string]$binding.canonicalFingerprint-or[string]$Context.stageKind-ne[string]$binding.stageKind-or[string]$Context.decisionBindingStatus-ne[string]$binding.decisionBindingStatus-or[string]$Context.decisionBindingDigest-ne[string]$binding.decisionBindingDigest)
    if($mismatch){ return [pscustomobject]@{ fresh=$false; ageHours=[Math]::Round($age,2); reason='contract_binding_stale'; contractRevision=[int]$binding.contractRevision; planFingerprint=[string]$binding.planFingerprint } }
  }
  $taskStateBinding=Test-ContextTaskStateBinding $Context
  if(-not$taskStateBinding.current){return [pscustomobject]@{fresh=$false;ageHours=[Math]::Round($age,2);reason=[string]$taskStateBinding.reason;taskStateRevision=if($taskStateBinding.PSObject.Properties['contextRevision']){[int]$taskStateBinding.contextRevision}else{0};projectionRevision=if($taskStateBinding.PSObject.Properties['projectionRevision']){[int]$taskStateBinding.projectionRevision}else{0}}}
  return [pscustomobject]@{ fresh=$true; ageHours=[Math]::Round($age,2); reason='fresh' }
}
function Get-CurrentExecutionContractBinding([string]$Id,[string]$Key){
  if([string]::IsNullOrWhiteSpace($Id)-or[string]::IsNullOrWhiteSpace($Key)){return $null}
  $records=@()
  if(-not[string]::IsNullOrWhiteSpace($ContractPath)){
    $full=[IO.Path]::GetFullPath($ContractPath)
    if(Test-Path -LiteralPath $full -PathType Leaf){
      $records += [pscustomobject]@{ path=$full; name=if([string]::IsNullOrWhiteSpace($ContractFileName)){Split-Path -Leaf $full}else{Split-Path -Leaf $ContractFileName}; hash=if([string]::IsNullOrWhiteSpace($ContractHash)){(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash}else{$ContractHash} }
    }
  }else{
    $contractRoot=Join-Path $workspace 'runtime-state\execution-contracts'
    if(-not(Test-Path -LiteralPath $contractRoot -PathType Container)){return $null}
    foreach($file in @(Get-ChildItem -LiteralPath $contractRoot -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending)){
      $records += [pscustomobject]@{ path=$file.FullName; name=$file.Name; hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
  }
  foreach($record in @($records)){
    $contract=Read-JsonFile $record.path
    if(-not$contract-or[string]$contract.taskId-ne$Id-or-not(Test-SuperBrainWorkspaceKey ([string]$contract.workspaceKey) $Key)){continue}
    if([string]$contract.status-ne'active'-or-not$contract.planReceipt-or[string]::IsNullOrWhiteSpace([string]$contract.planReceipt.planFingerprint)){continue}
    $canonicalPlan=$null
    if($contract.PSObject.Properties['canonicalPlan'] -and $contract.canonicalPlan){$canonicalState=Test-SuperBrainCanonicalPlan $contract.canonicalPlan;if(-not$canonicalState.ok){continue};$canonicalPlan=$canonicalState.plan}
    $continuityReceipt=[pscustomobject]@{
      source='execution_contract'
      phase=if($contract.PSObject.Properties['currentPhase']){Limit-Text ([string]$contract.currentPhase) 120}else{''}
      currentStep=if($contract.PSObject.Properties['currentStep']){Limit-Text ([string]$contract.currentStep) 220}else{''}
      taskNextAction=if($contract.PSObject.Properties['nextAction']){Limit-Text ([string]$contract.nextAction) 320}else{''}
      lastConfirmedSentence=if($contract.PSObject.Properties['lastConfirmedSentence']){Limit-Text ([string]$contract.lastConfirmedSentence) 320}else{''}
      lastConfirmedSource=if($contract.PSObject.Properties['lastConfirmedSource']){Limit-Text ([string]$contract.lastConfirmedSource) 80}else{''}
      evidence=@(if($contract.PSObject.Properties['evidence']){@($contract.evidence|Select-Object -Last 4|ForEach-Object{Limit-Text ([string]$_) 180})})
      verificationResults=@(if($contract.PSObject.Properties['verificationResults']){@($contract.verificationResults|Select-Object -Last 3|ForEach-Object{Limit-Text ([string]$_) 180})})
    }
    return [pscustomobject]@{
      contractRevision=[int]$contract.revision;planFingerprint=Limit-Text ([string]$contract.planReceipt.planFingerprint) 64
      ownerSessionKey=Limit-Text ([string]$contract.ownerSessionKey) 160;lifecycleStatus='active';compatibilityEpoch='context-contract-v1'
      contractFileName=$record.name;targetHash=$record.hash
      canonicalPlanId=if($canonicalPlan){Limit-Text ([string]$canonicalPlan.planId) 80}else{''}
      canonicalGeneration=if($canonicalPlan){[int]$canonicalPlan.generation}else{0}
      canonicalFingerprint=if($canonicalPlan){Limit-Text ([string]$canonicalPlan.currentFingerprint) 64}else{''}
      stageKind=if($contract.PSObject.Properties['stageKind']){Limit-Text ([string]$contract.stageKind) 24}else{''}
      decisionBindingStatus=if($contract.PSObject.Properties['decisionBinding'] -and $contract.decisionBinding){Limit-Text ([string]$contract.decisionBinding.status) 32}else{''}
      decisionBindingDigest=if($contract.PSObject.Properties['decisionBinding'] -and $contract.decisionBinding){Limit-Text ([string]$contract.decisionBinding.bindingDigest) 64}else{''}
      continuityReceipt=$continuityReceipt
    }
  }
  return $null
}
function Test-ContextBootstrapEligible([string]$Id,[switch]$RequirePlanCheckpoint){
  if([string]::IsNullOrWhiteSpace($Id)){return $false}
  $projectionPath=Get-SuperBrainCanonicalTaskPath (Join-Path $workspace 'task-state-store\projections') $Id '.json'
  $projection=Read-JsonFile $projectionPath
  if(-not$projection-or-not$projection.entities){return $false}
  $requiredKinds=@('task_card')
  if($RequirePlanCheckpoint){$requiredKinds=@('checkpoint','task_card')}
  foreach($kind in $requiredKinds){
    $entity=if($projection.entities.PSObject.Properties[$kind]){$projection.entities.$kind}else{$null}
    if(-not$entity-or[string]$entity.status-ne'active'-or[string]::IsNullOrWhiteSpace([string]$entity.path)-or-not(Test-Path -LiteralPath ([string]$entity.path) -PathType Leaf)){return $false}
  }
  return $true
}

function Test-ContextPlanCheckpointRequired([object]$Binding){
  return ($Binding -and -not [string]::IsNullOrWhiteSpace([string]$Binding.canonicalPlanId))
}
function Invoke-ContextBootstrap([object]$Context){
  $contractScript=Join-Path $PSScriptRoot 'execution-contract.ps1'
  $previousStateRoot=$env:SUPER_BRAIN_STATE_ROOT
  try{
    $stateRoot=Get-SuperBrainMemoryBaseRoot $Root
    $env:SUPER_BRAIN_STATE_ROOT=$stateRoot
    $arguments=@{
      Action='BindContext'; TaskId=[string]$Context.taskId; WorkspaceKey=[string]$Context.workspaceKey; StateRoot=$stateRoot
      ContextAcceptedGoal=[string]$Context.acceptedGoal; ContextAcceptedRoute=@($Context.acceptedRoute); ContextNonGoals=@($Context.nonGoals); ContextMustPreserve=@($Context.mustPreserve); ContextMustNotDriftTo=@($Context.mustNotDriftTo); ContextEvidence=@($Context.evidence)
      ContextAgentId=[string]$Context.agentId; ContextSessionId=[string]$Context.sessionId; ContextPlatform=[string]$Context.platform; ContextOwnerWorkspace=[string]$Context.workspace
      ContextMaxAgeHours=$MaxAgeHours
      Json=$true; NoExit=$true
    }
    $raw=@(& $contractScript @arguments 2>&1)
  }finally{
    if($null-eq$previousStateRoot){Remove-Item Env:\SUPER_BRAIN_STATE_ROOT -ErrorAction SilentlyContinue}else{$env:SUPER_BRAIN_STATE_ROOT=$previousStateRoot}
  }
  $text=(@($raw|ForEach-Object{[string]$_})-join "`n").Trim()
  $value=$null
  try{if(-not[string]::IsNullOrWhiteSpace($text)){$value=$text|ConvertFrom-Json}}catch{}
  if(-not$value-or$value.ok-ne$true-or-not$value.context){throw ('CURRENT_TASK_CONTEXT_BOOTSTRAP_FAILED code=' + $(if($value-and$value.code){[string]$value.code}else{'unparseable'}))}
  return $value
}

function Invoke-ContextActiveBundleBootstrap([object]$Context){
  $checkpointScript=Join-Path $PSScriptRoot 'checkpoint-writer.ps1'
  if(-not(Test-Path -LiteralPath $checkpointScript -PathType Leaf)){throw 'CURRENT_TASK_CONTEXT_CHECKPOINT_BOOTSTRAP_SCRIPT_MISSING'}
  $receipt=if($Context.PSObject.Properties['continuityReceipt']){$Context.continuityReceipt}else{$null}
  $phase=if($receipt -and $receipt.PSObject.Properties['phase']){Limit-Text ([string]$receipt.phase) 120}else{''}
  $step=if($receipt -and $receipt.PSObject.Properties['currentStep']){Limit-Text ([string]$receipt.currentStep) 160}else{''}
  $next=if($receipt -and $receipt.PSObject.Properties['taskNextAction']){Limit-Text ([string]$receipt.taskNextAction) 220}else{''}
  if([string]::IsNullOrWhiteSpace($step)){$step=Limit-Text ([string]$Context.acceptedGoal) 160}
  if([string]::IsNullOrWhiteSpace($next)){$next=$step}
  $hostMetadata=$null
  if($Context.PSObject.Properties['host'] -and $Context.host){$hostMetadata=$Context.host}
  $hostArgs=@()
  foreach($entry in @(
    [pscustomobject]@{name='-HostAgent';value=if($hostMetadata -and $hostMetadata.PSObject.Properties['agentName']){[string]$hostMetadata.agentName}else{''}},
    [pscustomobject]@{name='-HostAgentId';value=if($hostMetadata -and $hostMetadata.PSObject.Properties['agentId']){[string]$hostMetadata.agentId}else{''}},
    [pscustomobject]@{name='-HostPlatform';value=if($hostMetadata -and $hostMetadata.PSObject.Properties['platform']){[string]$hostMetadata.platform}else{''}}
  )){
    if(-not[string]::IsNullOrWhiteSpace([string]$entry.value)){$hostArgs+=@([string]$entry.name,[string]$entry.value)}
  }
  $args=@(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',$checkpointScript,
    '-Action','Start','-TaskId',[string]$Context.taskId,'-WorkspaceKey',[string]$Context.workspaceKey,
    '-SessionId',[string]$Context.sessionId,'-AgentId',[string]$Context.agentId,'-Platform',[string]$Context.platform
  ) + $hostArgs + @(
    '-OwnerWorkspace',[string]$Context.workspace,'-TaskName',(Limit-Text ([string]$Context.acceptedGoal) 120),
    '-Goal',(Limit-Text ([string]$Context.acceptedGoal) 180),'-CurrentPhase',$phase,'-CurrentStep',$step,
    '-NextAction',$next,'-Status','active','-Source','current-task-context.ps1:active-bundle-bootstrap','-Json'
  )
  $raw=@(& powershell.exe @args 2>&1)
  $exitCode=$LASTEXITCODE
  $text=(@($raw|ForEach-Object{[string]$_})-join [Environment]::NewLine).Trim()
  $value=$null
  try{if(-not[string]::IsNullOrWhiteSpace($text)){$value=$text|ConvertFrom-Json}}catch{}
  if($exitCode-ne0-or-not$value-or$value.ok-ne$true){
    $code=if($value-and$value.PSObject.Properties['code']){[string]$value.code}else{'CURRENT_TASK_CONTEXT_ACTIVE_BUNDLE_BOOTSTRAP_FAILED'}
    throw ($code + ': active checkpoint and task card could not be created before an authorizing context.')
  }
  return $value
}

if($Action -ne 'Preview'){Import-LegacyContext}
$current = Read-Context $TaskId
if($Action -eq 'Clear'){
  $targetTaskId=if(-not[string]::IsNullOrWhiteSpace($TaskId)){$TaskId}elseif($current){[string]$current.taskId}else{''}
  $scopedPath=Get-ScopedContextPath $targetTaskId
  $workspacePointerPath=Get-WorkspacePointerPath $resolvedWorkspaceKey
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-SuperBrainUtcTimestamp); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status='cleared'; taskId=$targetTaskId; stale=$false; freshness=[pscustomobject]@{ fresh=$true; ageHours=0; reason='cleared_explicitly' }; guard='Current task context cleared explicitly; guard scripts must not treat older global last-* evidence as current task proof.'; path=$scopedPath; workspacePointerPath=$workspacePointerPath; compatibilityPath=$contextPath }
  if(-not[string]::IsNullOrWhiteSpace($targetTaskId)){$null=Clear-SuperBrainTaskState -TaskId $targetTaskId -EntityKind context -EntityPath $scopedPath -Source 'current-task-context.ps1:clear' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $OwnerWorkspace -OwnerAgentId $AgentId -OwnerSessionId $SessionId -OwnerPlatform $Platform}
  $pointerChanged=if([string]::IsNullOrWhiteSpace($targetTaskId)){$false}else{Remove-CompatibilityContext $targetTaskId}
  $result|Add-Member -NotePropertyName compatibilityPointerChanged -NotePropertyValue $pointerChanged -Force
  Write-JsonUtf8NoBom $outPath $result 10
  Write-ContextResult $result 0
  if($NoExit){return}
}

if($Action -in @('Create','Update','Preview')){
  if([string]::IsNullOrWhiteSpace($TaskId) -and $current -and [string]$current.status -eq 'active'){ $TaskId = [string]$current.taskId }
  if([string]::IsNullOrWhiteSpace($TaskId)){ $TaskId = New-TaskId $AcceptedGoal }
  if(-not$current-or[string]$current.taskId-ne$TaskId){$current=Read-Context $TaskId}
  if([string]::IsNullOrWhiteSpace($AcceptedGoal) -and $current -and [string]$current.status -eq 'active'){ $AcceptedGoal = [string]$current.acceptedGoal }
  if(@($AcceptedRoute).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $AcceptedRoute = @($current.acceptedRoute) }
  if(@($NonGoals).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $NonGoals = @($current.nonGoals) }
  if(@($MustPreserve).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $MustPreserve = @($current.mustPreserve) }
  if(@($MustNotDriftTo).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $MustNotDriftTo = @($current.mustNotDriftTo) }
  if([string]::IsNullOrWhiteSpace($WorkspaceKey) -and $current -and $current.PSObject.Properties['workspaceKey']){ $WorkspaceKey = [string]$current.workspaceKey }
  $WorkspaceKey = $resolvedWorkspaceKey
  $owner = Get-SuperBrainTaskStateOwnerInput $null $AgentId $SessionId $Platform $OwnerWorkspace
  $now = Get-SuperBrainUtcNow
  $taskStateBaseRevision = if($TaskStateRevisionOverride -gt 0){$TaskStateRevisionOverride-1}elseif($ExpectedRevision-ge0){$ExpectedRevision}else{Get-SuperBrainTaskStateExpectedRevision $TaskId}
  $contractBinding = Get-CurrentExecutionContractBinding $TaskId $WorkspaceKey
  $requiresPlanCheckpoint = Test-ContextPlanCheckpointRequired $contractBinding
  $taskReceipt = if($contractBinding -and $contractBinding.PSObject.Properties['continuityReceipt']){$contractBinding.continuityReceipt}else{$null}
  $taskEvidence = @()
  $taskVerificationResults = @()
  if($taskReceipt -and $taskReceipt.PSObject.Properties['evidence']){$taskEvidence=@($taskReceipt.evidence|ForEach-Object{Limit-Text ([string]$_) 180})}
  if($taskReceipt -and $taskReceipt.PSObject.Properties['verificationResults']){$taskVerificationResults=@($taskReceipt.verificationResults|ForEach-Object{Limit-Text ([string]$_) 180})}
  $result=[pscustomobject]@{
    ok=$true; checkedAt=$now.ToString('o'); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status='active'; stale=$false; expiresAt=$now.AddHours($MaxAgeHours).ToString('o')
    taskId=Limit-Text $TaskId 120; workspaceKey=$WorkspaceKey; agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace; host=New-HostMetadata; acceptedGoal=Limit-Text $AcceptedGoal 800; acceptedRoute=@($AcceptedRoute | ForEach-Object { Limit-Text $_ 300 }); nonGoals=@($NonGoals | ForEach-Object { Limit-Text $_ 300 }); mustPreserve=@($MustPreserve | ForEach-Object { Limit-Text $_ 300 }); mustNotDriftTo=@($MustNotDriftTo | ForEach-Object { Limit-Text $_ 300 })
    guardStatePaths=[pscustomobject]@{ goalRouteLock=(Guard-Path 'goal-route-locks' $TaskId); routeCheckpoint=(Guard-Path 'route-checkpoints' $TaskId); causalPlans=(Guard-Path 'change-causality' $TaskId -Directory); causalReviews=(Guard-Path 'change-causality-reviews' $TaskId -Directory); engineeringDecisions=(Guard-Path 'engineering-decisions' $TaskId -Directory); integrationParity=(Guard-Path 'integration-parity-check' $TaskId); integrationContractReplay=(Guard-Path 'integration-contract-replay' $TaskId -Directory) }
    completionRequirements=@('fresh current-task-context for taskId','fresh route checkpoint for taskId','causal review for taskId','valid task-scoped engineering decision when engineering judgment applies','integration parity/replay for taskId when modules are involved','real user path or concrete acceptance evidence when acceptance is claimed','lesson-scope gate before durable learning')
    evidence=@($Evidence | ForEach-Object { Limit-Text $_ 360 })
    bindingState=if($contractBinding){'bound'}else{'locator_only'}; bindingReason=if($contractBinding){'exact_task_contract_binding'}else{'active_contract_missing_or_ambiguous'}; authorizationState=if($contractBinding){'authorizing'}else{'locator_only_non_authorizing'}; taskStateRevision=($taskStateBaseRevision+1)
    planCheckpointRequired=[bool]$requiresPlanCheckpoint
    contractRevision=if($contractBinding){[int]$contractBinding.contractRevision}else{0}; planFingerprint=if($contractBinding){[string]$contractBinding.planFingerprint}else{''}
    canonicalPlanId=if($contractBinding){[string]$contractBinding.canonicalPlanId}else{''}; canonicalGeneration=if($contractBinding){[int]$contractBinding.canonicalGeneration}else{0}; canonicalFingerprint=if($contractBinding){[string]$contractBinding.canonicalFingerprint}else{''}
    stageKind=if($contractBinding){[string]$contractBinding.stageKind}else{''}; decisionBindingStatus=if($contractBinding){[string]$contractBinding.decisionBindingStatus}else{''}; decisionBindingDigest=if($contractBinding){[string]$contractBinding.decisionBindingDigest}else{''}
    continuityReceipt=$taskReceipt
    taskStateSource=if($taskReceipt){'continuity_receipt'}else{'none'}
    taskPhase=if($taskReceipt -and $taskReceipt.PSObject.Properties['phase']){Limit-Text ([string]$taskReceipt.phase) 120}else{''}
    taskCurrentStep=if($taskReceipt -and $taskReceipt.PSObject.Properties['currentStep']){Limit-Text ([string]$taskReceipt.currentStep) 220}else{''}
    taskNextAction=if($taskReceipt -and $taskReceipt.PSObject.Properties['taskNextAction']){Limit-Text ([string]$taskReceipt.taskNextAction) 320}else{''}
    taskLastConfirmedSentence=if($taskReceipt -and $taskReceipt.PSObject.Properties['lastConfirmedSentence']){Limit-Text ([string]$taskReceipt.lastConfirmedSentence) 320}else{''}
    taskLastConfirmedSource=if($taskReceipt -and $taskReceipt.PSObject.Properties['lastConfirmedSource']){Limit-Text ([string]$taskReceipt.lastConfirmedSource) 80}else{''}
    taskEvidence=@($taskEvidence)
    taskVerificationResults=@($taskVerificationResults)
    ownerSessionKey=if($contractBinding){[string]$contractBinding.ownerSessionKey}else{''}; lifecycleStatus=if($contractBinding){[string]$contractBinding.lifecycleStatus}else{'unknown'}
    compatibilityEpoch=if($contractBinding -and -not [string]::IsNullOrWhiteSpace([string]$contractBinding.canonicalPlanId)){'context-contract-v2'}elseif($contractBinding){[string]$contractBinding.compatibilityEpoch}else{'context-contract-v1'}; contractFileName=if($contractBinding){[string]$contractBinding.contractFileName}else{''}; targetHash=if($contractBinding){[string]$contractBinding.targetHash}else{''}
    guard='All guard scripts should inherit this taskId before reading global last-* fallback; stale, cleared, or version-mismatched current-task-context must not satisfy current-task completion.'
    nextAction='Pass -TaskId from current-task-context into route, causal, engineering decision, integration replay, task-verification, and completion-guard scripts; refresh context when stale.'
    path=(Get-ScopedContextPath $TaskId); workspacePointerPath=(Get-WorkspacePointerPath $WorkspaceKey); compatibilityPath=$contextPath; scope='task'
  }
  if($Action -eq 'Preview'){
    if($Json){$result|ConvertTo-Json -Depth 12}else{Write-Host "CURRENT_TASK_CONTEXT ok=$($result.ok) status=$($result.status) path=$($result.path)"}
    if($NoExit){return}
    exit 0
  }
  $bootstrapEligible=Test-ContextBootstrapEligible $TaskId -RequirePlanCheckpoint:$requiresPlanCheckpoint
  # An authorizing context must never be created against a bare contract.
  # Bootstrap the required task-state bundle before binding, regardless of
  # whether this contract carries a canonical plan.
  if($contractBinding-and-not$bootstrapEligible){
    $null=Invoke-ContextActiveBundleBootstrap $result
    $bootstrapEligible=Test-ContextBootstrapEligible $TaskId -RequirePlanCheckpoint:$requiresPlanCheckpoint
    if(-not$bootstrapEligible){throw 'CURRENT_TASK_CONTEXT_ACTIVE_BUNDLE_BOOTSTRAP_INCOMPLETE'}
  }
  if($contractBinding-and-not$current-and$bootstrapEligible){
    $bootstrap=Invoke-ContextBootstrap $result
    $boundContext=$bootstrap.context
    Write-JsonUtf8NoBom $outPath $boundContext 12
    Write-ContextResult $boundContext 0
    if($NoExit){return}
  }
  $null=Commit-SuperBrainTaskState -TaskId $TaskId -EntityKind context -EntityValue $result -EntityPath $result.path -Source 'current-task-context.ps1' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $owner.workspace -OwnerAgentId $owner.agentId -OwnerSessionId $owner.sessionId -OwnerPlatform $owner.platform
  Write-JsonUtf8NoBom $result.workspacePointerPath $result 12
  $legacyPointer=Read-JsonFile $contextPath
  if(-not$legacyPointer-or(Test-ContextWorkspaceScope $legacyPointer $WorkspaceKey)){Write-JsonUtf8NoBom $contextPath $result 12}
  Write-JsonUtf8NoBom $outPath $result 12
  Write-ContextResult $result 0
  if($NoExit){return}
}

$freshness = Test-ContextFresh $current $MaxAgeHours
$active = ($null -ne $current -and [string]$current.status -eq 'active' -and -not [string]::IsNullOrWhiteSpace([string]$current.taskId))
$ok = ($active -and $freshness.fresh -eq $true)
$result=[pscustomobject]@{ ok=$ok; checkedAt=(Get-SuperBrainUtcTimestamp); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status=if($ok){'active'}elseif($active){'stale'}else{'missing'}; stale=($active -and $freshness.fresh -ne $true); freshness=$freshness; maxAgeHours=$MaxAgeHours; workspaceKey=$resolvedWorkspaceKey; current=$current; guard='Missing/stale current-task-context means long/high-risk guard flow may fall back to stale global last-* state; stale context is not valid current-task proof.'; nextAction=if($ok){'Use current.taskId for guard scripts.'}else{'Create or update current-task-context before long/high-risk work, then pass its taskId into guard scripts.'}; path=if(-not[string]::IsNullOrWhiteSpace($TaskId)){Get-ScopedContextPath $TaskId}else{Get-WorkspacePointerPath $resolvedWorkspaceKey}; workspacePointerPath=(Get-WorkspacePointerPath $resolvedWorkspaceKey); compatibilityPath=$contextPath; scope=if(-not[string]::IsNullOrWhiteSpace($TaskId)){'task'}else{'workspace_pointer'} }
Write-JsonUtf8NoBom $outPath $result 12
Write-ContextResult $result $(if($result.ok){0}else{1})
if($NoExit){return}
