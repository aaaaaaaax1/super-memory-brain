param(
  [ValidateSet('Create','Status','Update','Clear')]
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
  [string]$AgentId = '',
  [string]$SessionId = '',
  [string]$Platform = 'zcode',
  [string]$OwnerWorkspace = '',
  [int]$MaxAgeHours = 24,
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
foreach ($dir in @($workspace,$scopeRoot,$contextRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
$contextPath = Join-Path $workspace 'current-task-context.json'
$outPath = Join-Path $workspace 'last-current-task-context.json'

function Limit-Text([string]$Value,[int]$Max=500){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function New-TaskId([string]$Goal){ $seed=if([string]::IsNullOrWhiteSpace($Goal)){[guid]::NewGuid().ToString('n')}else{$Goal + '|' + (Get-Date).ToString('yyyyMMddHHmmss')}; $sha=[Security.Cryptography.SHA256]::Create(); 'task-' + (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))[0..5] | ForEach-Object { $_.ToString('x2') })) }
function Get-ScopedContextPath([string]$Id){ if([string]::IsNullOrWhiteSpace($Id)){return ''}; return (Get-SuperBrainCanonicalTaskPath $contextRoot $Id '.json') }
function Read-JsonFile([string]$Path){ if([string]::IsNullOrWhiteSpace($Path)-or-not(Test-Path -LiteralPath $Path)){return $null}; try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null} }
function Read-Context([string]$Id=''){
  if(-not[string]::IsNullOrWhiteSpace($Id)){
    $scoped=Read-JsonFile (Get-ScopedContextPath $Id)
    if($scoped){return $scoped}
    $legacy=Read-JsonFile $contextPath
    if($legacy-and[string]$legacy.taskId-eq$Id){return $legacy}
    return $null
  }
  return Read-JsonFile $contextPath
}
function Import-LegacyContext{
  $legacy=Read-JsonFile $contextPath
  if(-not$legacy-or[string]::IsNullOrWhiteSpace([string]$legacy.taskId)){return}
  $scopedPath=Get-ScopedContextPath ([string]$legacy.taskId)
  if(-not(Test-Path -LiteralPath $scopedPath)){
    Write-JsonUtf8NoBom $scopedPath $legacy 12
    $null=Sync-SuperBrainTaskState ([string]$legacy.taskId) 'context' 'upsert' $scopedPath 'current-task-context.ps1:legacy-import'
  }
}
function Get-ActiveContexts([string]$ExcludeTaskId=''){
  $items=@()
  foreach($file in @(Get-ChildItem -LiteralPath $contextRoot -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)){
    $item=Read-JsonFile $file.FullName
    if(-not$item-or[string]$item.status-ne'active'){continue}
    if(-not[string]::IsNullOrWhiteSpace($ExcludeTaskId)-and[string]$item.taskId-eq$ExcludeTaskId){continue}
    $items+=$item
  }
  return @($items)
}
function Remove-CompatibilityContext([string]$ChangedTaskId){
  $pointer=Read-JsonFile $contextPath
  if(-not$pointer-or[string]$pointer.taskId-ne$ChangedTaskId){return $false}
  $replacement=@(Get-ActiveContexts -ExcludeTaskId $ChangedTaskId)|Select-Object -First 1
  if($replacement){Write-JsonUtf8NoBom $contextPath $replacement 12}elseif(Test-Path -LiteralPath $contextPath){Remove-Item -LiteralPath $contextPath -Force}
  return $true
}
function Guard-Path([string]$Kind,[string]$Id,[switch]$Directory){ if([string]::IsNullOrWhiteSpace($Id)){return ''}; $base=Join-Path $scopeRoot $Kind; if($Directory){ return (Join-Path $base (Get-SuperBrainCanonicalTaskToken $Id)) }; return (Get-SuperBrainCanonicalTaskPath $base $Id '.json') }
function Test-ContextFresh($Context,[int]$Hours){
  if(-not $Context){ return [pscustomobject]@{ fresh=$false; ageHours=$null; reason='missing' } }
  $checked = $null
  try { $checked = [datetime]::Parse([string]$Context.checkedAt) } catch {}
  if(-not $checked){ return [pscustomobject]@{ fresh=$false; ageHours=$null; reason='missing_or_invalid_checkedAt' } }
  $age = ((Get-Date) - $checked).TotalHours
  if($Hours -gt 0 -and $age -gt $Hours){ return [pscustomobject]@{ fresh=$false; ageHours=[Math]::Round($age,2); reason='stale_checkedAt' } }
  $manifestVersion = [string](Get-SuperBrainManifest $Root).version
  if(-not [string]::IsNullOrWhiteSpace([string]$Context.version) -and [string]$Context.version -ne $manifestVersion){ return [pscustomobject]@{ fresh=$false; ageHours=[Math]::Round($age,2); reason='version_mismatch' } }
  return [pscustomobject]@{ fresh=$true; ageHours=[Math]::Round($age,2); reason='fresh' }
}

Import-LegacyContext
$current = Read-Context $TaskId
if($Action -eq 'Clear'){
  $targetTaskId=if(-not[string]::IsNullOrWhiteSpace($TaskId)){$TaskId}elseif($current){[string]$current.taskId}else{''}
  $scopedPath=Get-ScopedContextPath $targetTaskId
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status='cleared'; taskId=$targetTaskId; stale=$false; freshness=[pscustomobject]@{ fresh=$true; ageHours=0; reason='cleared_explicitly' }; guard='Current task context cleared explicitly; guard scripts must not treat older global last-* evidence as current task proof.'; path=$scopedPath; compatibilityPath=$contextPath }
  if(-not[string]::IsNullOrWhiteSpace($targetTaskId)){$null=Clear-SuperBrainTaskState -TaskId $targetTaskId -EntityKind context -EntityPath $scopedPath -Source 'current-task-context.ps1:clear' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $OwnerWorkspace -OwnerAgentId $AgentId -OwnerSessionId $SessionId -OwnerPlatform $Platform}
  $pointerChanged=if([string]::IsNullOrWhiteSpace($targetTaskId)){$false}else{Remove-CompatibilityContext $targetTaskId}
  $result|Add-Member -NotePropertyName compatibilityPointerChanged -NotePropertyValue $pointerChanged -Force
  Write-JsonUtf8NoBom $outPath $result 10
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "CURRENT_TASK_CONTEXT ok=True status=cleared taskId=$targetTaskId path=$scopedPath"}; exit 0
}

if($Action -in @('Create','Update')){
  if([string]::IsNullOrWhiteSpace($TaskId) -and $current -and [string]$current.status -eq 'active'){ $TaskId = [string]$current.taskId }
  if([string]::IsNullOrWhiteSpace($TaskId)){ $TaskId = New-TaskId $AcceptedGoal }
  if(-not$current-or[string]$current.taskId-ne$TaskId){$current=Read-Context $TaskId}
  if([string]::IsNullOrWhiteSpace($AcceptedGoal) -and $current -and [string]$current.status -eq 'active'){ $AcceptedGoal = [string]$current.acceptedGoal }
  if(@($AcceptedRoute).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $AcceptedRoute = @($current.acceptedRoute) }
  if(@($NonGoals).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $NonGoals = @($current.nonGoals) }
  if(@($MustPreserve).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $MustPreserve = @($current.mustPreserve) }
  if(@($MustNotDriftTo).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $MustNotDriftTo = @($current.mustNotDriftTo) }
  if([string]::IsNullOrWhiteSpace($WorkspaceKey) -and $current -and $current.PSObject.Properties['workspaceKey']){ $WorkspaceKey = [string]$current.workspaceKey }
  $WorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
  $owner = Get-SuperBrainTaskStateOwnerInput $null $AgentId $SessionId $Platform $OwnerWorkspace
  $now = Get-Date
  $result=[pscustomobject]@{
    ok=$true; checkedAt=$now.ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status='active'; stale=$false; expiresAt=$now.AddHours($MaxAgeHours).ToString('yyyy-MM-dd HH:mm:ss')
    taskId=Limit-Text $TaskId 120; workspaceKey=$WorkspaceKey; agentId=$owner.agentId; sessionId=$owner.sessionId; platform=$owner.platform; workspace=$owner.workspace; acceptedGoal=Limit-Text $AcceptedGoal 800; acceptedRoute=@($AcceptedRoute | ForEach-Object { Limit-Text $_ 300 }); nonGoals=@($NonGoals | ForEach-Object { Limit-Text $_ 300 }); mustPreserve=@($MustPreserve | ForEach-Object { Limit-Text $_ 300 }); mustNotDriftTo=@($MustNotDriftTo | ForEach-Object { Limit-Text $_ 300 })
    guardStatePaths=[pscustomobject]@{ goalRouteLock=(Guard-Path 'goal-route-locks' $TaskId); routeCheckpoint=(Guard-Path 'route-checkpoints' $TaskId); causalPlans=(Guard-Path 'change-causality' $TaskId -Directory); causalReviews=(Guard-Path 'change-causality-reviews' $TaskId -Directory); engineeringDecisions=(Guard-Path 'engineering-decisions' $TaskId -Directory); integrationParity=(Guard-Path 'integration-parity-check' $TaskId); integrationContractReplay=(Guard-Path 'integration-contract-replay' $TaskId -Directory) }
    completionRequirements=@('fresh current-task-context for taskId','fresh route checkpoint for taskId','causal review for taskId','valid task-scoped engineering decision when engineering judgment applies','integration parity/replay for taskId when modules are involved','real user path or concrete acceptance evidence when acceptance is claimed','lesson-scope gate before durable learning')
    evidence=@($Evidence | ForEach-Object { Limit-Text $_ 360 })
    guard='All guard scripts should inherit this taskId before reading global last-* fallback; stale, cleared, or version-mismatched current-task-context must not satisfy current-task completion.'
    nextAction='Pass -TaskId from current-task-context into route, causal, engineering decision, integration replay, task-verification, and completion-guard scripts; refresh context when stale.'
    path=(Get-ScopedContextPath $TaskId); compatibilityPath=$contextPath; scope='task'
  }
  $null=Commit-SuperBrainTaskState -TaskId $TaskId -EntityKind context -EntityValue $result -EntityPath $result.path -Source 'current-task-context.ps1' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $owner.workspace -OwnerAgentId $owner.agentId -OwnerSessionId $owner.sessionId -OwnerPlatform $owner.platform
  Write-JsonUtf8NoBom $contextPath $result 12
  Write-JsonUtf8NoBom $outPath $result 12
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "CURRENT_TASK_CONTEXT ok=True taskId=$TaskId path=$($result.path)"}; exit 0
}

$freshness = Test-ContextFresh $current $MaxAgeHours
$active = ($null -ne $current -and [string]$current.status -eq 'active' -and -not [string]::IsNullOrWhiteSpace([string]$current.taskId))
$ok = ($active -and $freshness.fresh -eq $true)
$result=[pscustomobject]@{ ok=$ok; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status=if($ok){'active'}elseif($active){'stale'}else{'missing'}; stale=($active -and $freshness.fresh -ne $true); freshness=$freshness; maxAgeHours=$MaxAgeHours; workspaceKey=(Get-SuperBrainWorkspaceKey $WorkspaceKey); current=$current; guard='Missing/stale current-task-context means long/high-risk guard flow may fall back to stale global last-* state; stale context is not valid current-task proof.'; nextAction=if($ok){'Use current.taskId for guard scripts.'}else{'Create or update current-task-context before long/high-risk work, then pass its taskId into guard scripts.'}; path=if(-not[string]::IsNullOrWhiteSpace($TaskId)){Get-ScopedContextPath $TaskId}else{$contextPath}; compatibilityPath=$contextPath; scope=if(-not[string]::IsNullOrWhiteSpace($TaskId)){'task'}else{'compatibility_pointer'} }
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "CURRENT_TASK_CONTEXT ok=$($result.ok) status=$($result.status) path=$contextPath"}
if(-not $result.ok){exit 1}; exit 0
