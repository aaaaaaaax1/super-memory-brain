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
foreach ($dir in @($workspace,$scopeRoot)) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null } }
$contextPath = Join-Path $workspace 'current-task-context.json'
$outPath = Join-Path $workspace 'last-current-task-context.json'

function Limit-Text([string]$Value,[int]$Max=500){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function New-TaskId([string]$Goal){ $seed=if([string]::IsNullOrWhiteSpace($Goal)){[guid]::NewGuid().ToString('n')}else{$Goal + '|' + (Get-Date).ToString('yyyyMMddHHmmss')}; $sha=[Security.Cryptography.SHA256]::Create(); 'task-' + (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))[0..5] | ForEach-Object { $_.ToString('x2') })) }
function Safe-TaskId([string]$Value){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $safe=(($Value -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant(); if($safe.Length -gt 120){$safe=$safe.Substring(0,120)}; return $safe }
function Read-Context { if(Test-Path -LiteralPath $contextPath){ try{ return Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json }catch{} }; return $null }
function Guard-Path([string]$Kind,[string]$Id,[switch]$Directory){ $safe=Safe-TaskId $Id; if([string]::IsNullOrWhiteSpace($safe)){return ''}; $base=Join-Path $scopeRoot $Kind; if($Directory){ return (Join-Path $base $safe) }; return (Join-Path $base ($safe + '.json')) }
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

$current = Read-Context
if($Action -eq 'Clear'){
  $result=[pscustomobject]@{ ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status='cleared'; taskId=if($current){$current.taskId}else{$TaskId}; stale=$false; freshness=[pscustomobject]@{ fresh=$true; ageHours=0; reason='cleared_explicitly' }; guard='Current task context cleared explicitly; guard scripts must not treat older global last-* evidence as current task proof.'; path=$contextPath }
  Write-JsonUtf8NoBom $contextPath $result 10; Write-JsonUtf8NoBom $outPath $result 10
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "CURRENT_TASK_CONTEXT ok=True status=cleared path=$contextPath"}; exit 0
}

if($Action -in @('Create','Update')){
  if([string]::IsNullOrWhiteSpace($TaskId) -and $current -and [string]$current.status -eq 'active'){ $TaskId = [string]$current.taskId }
  if([string]::IsNullOrWhiteSpace($TaskId)){ $TaskId = New-TaskId $AcceptedGoal }
  if([string]::IsNullOrWhiteSpace($AcceptedGoal) -and $current -and [string]$current.status -eq 'active'){ $AcceptedGoal = [string]$current.acceptedGoal }
  if(@($AcceptedRoute).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $AcceptedRoute = @($current.acceptedRoute) }
  if(@($NonGoals).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $NonGoals = @($current.nonGoals) }
  if(@($MustPreserve).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $MustPreserve = @($current.mustPreserve) }
  if(@($MustNotDriftTo).Count -eq 0 -and $current -and [string]$current.status -eq 'active'){ $MustNotDriftTo = @($current.mustNotDriftTo) }
  $now = Get-Date
  $result=[pscustomobject]@{
    ok=$true; checkedAt=$now.ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status='active'; stale=$false; expiresAt=$now.AddHours($MaxAgeHours).ToString('yyyy-MM-dd HH:mm:ss')
    taskId=Limit-Text $TaskId 120; acceptedGoal=Limit-Text $AcceptedGoal 800; acceptedRoute=@($AcceptedRoute | ForEach-Object { Limit-Text $_ 300 }); nonGoals=@($NonGoals | ForEach-Object { Limit-Text $_ 300 }); mustPreserve=@($MustPreserve | ForEach-Object { Limit-Text $_ 300 }); mustNotDriftTo=@($MustNotDriftTo | ForEach-Object { Limit-Text $_ 300 })
    guardStatePaths=[pscustomobject]@{ goalRouteLock=(Guard-Path 'goal-route-locks' $TaskId); routeCheckpoint=(Guard-Path 'route-checkpoints' $TaskId); causalPlans=(Guard-Path 'change-causality' $TaskId -Directory); causalReviews=(Guard-Path 'change-causality-reviews' $TaskId -Directory); engineeringDecisions=(Guard-Path 'engineering-decisions' $TaskId -Directory); integrationParity=(Guard-Path 'integration-parity-check' $TaskId); integrationContractReplay=(Guard-Path 'integration-contract-replay' $TaskId -Directory) }
    completionRequirements=@('fresh current-task-context for taskId','fresh route checkpoint for taskId','causal review for taskId','valid task-scoped engineering decision when engineering judgment applies','integration parity/replay for taskId when modules are involved','real user path or concrete acceptance evidence when acceptance is claimed','lesson-scope gate before durable learning')
    evidence=@($Evidence | ForEach-Object { Limit-Text $_ 360 })
    guard='All guard scripts should inherit this taskId before reading global last-* fallback; stale, cleared, or version-mismatched current-task-context must not satisfy current-task completion.'
    nextAction='Pass -TaskId from current-task-context into route, causal, engineering decision, integration replay, task-verification, and completion-guard scripts; refresh context when stale.'
    path=$contextPath
  }
  Write-JsonUtf8NoBom $contextPath $result 12; Write-JsonUtf8NoBom $outPath $result 12
  if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "CURRENT_TASK_CONTEXT ok=True taskId=$TaskId path=$contextPath"}; exit 0
}

$freshness = Test-ContextFresh $current $MaxAgeHours
$active = ($null -ne $current -and [string]$current.status -eq 'active' -and -not [string]::IsNullOrWhiteSpace([string]$current.taskId))
$ok = ($active -and $freshness.fresh -eq $true)
$result=[pscustomobject]@{ ok=$ok; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.current-task-context.v1'; version=(Get-SuperBrainManifest $Root).version; action=$Action; status=if($ok){'active'}elseif($active){'stale'}else{'missing'}; stale=($active -and $freshness.fresh -ne $true); freshness=$freshness; maxAgeHours=$MaxAgeHours; current=$current; guard='Missing/stale current-task-context means long/high-risk guard flow may fall back to stale global last-* state; stale context is not valid current-task proof.'; nextAction=if($ok){'Use current.taskId for guard scripts.'}else{'Create or update current-task-context before long/high-risk work, then pass its taskId into guard scripts.'}; path=$contextPath }
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "CURRENT_TASK_CONTEXT ok=$($result.ok) status=$($result.status) path=$contextPath"}
if(-not $result.ok){exit 1}; exit 0
