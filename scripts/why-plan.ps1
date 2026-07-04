param(
  [string]$Goal = '',
  [string]$Intent = '',
  [string[]]$Evidence = @(),
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$outPath = Join-Path $workspace 'last-why-plan.json'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function Limit-Text([string]$Value,[int]$Max=500){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Infer-Why([string]$G){
  if($G -match '自动|智能|记忆|线索|执行'){ return 'Reduce repeated user reminders by making execution-control, memory scouting, task tracking, and verification automatic after natural goals or authorization.' }
  if($G -match '修|bug|失败|error|fail'){ return 'Fix the root cause and prevent recurrence rather than patching the visible symptom only.' }
  if($G -match '优化|性能|效率'){ return 'Improve quality, stability, speed, or maintainability with the smallest safe change.' }
  return 'Convert the user goal into a scoped, verified outcome with minimal drift and clear completion evidence.'
}

$why = Infer-Why $Goal
$success = @('goal is implemented or answered within stated scope','task card/context is created or updated when execution is authorized','relevant memory/evidence is consulted when continuity or risk matters','targeted verification passes or failures are reported honestly')
$nonGoals = @('do not mutate files for plan-only/status-only requests','do not inject raw long history by default','do not expand scope without evidence or approval')
$efficiency = @('reuse existing scripts before adding new mechanisms','prefer compact evidence cards over broad recall','batch independent read-only checks','use negative E2E for regressions that users had to point out')
$risks = @('over-automation without authorization','stale last-* evidence polluting current task','creating duplicate task cards','claiming completion without acceptance evidence')
$verification = @('lint or parser checks for changed scripts','positive E2E for intended automatic path','negative E2E for stale/weak/missing evidence','completion guard and verify-package before completion when package changes')

$result=[pscustomobject]@{
  ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.why-plan.v1'; version=(Get-SuperBrainManifest $Root).version
  goal=Limit-Text $Goal 700; intent=Limit-Text $Intent 120; why=$why; successCriteria=$success; nonGoals=$nonGoals; efficiencyOptimizations=$efficiency; risks=$risks; verificationPlan=$verification; evidence=@($Evidence|Select-Object -First 8|ForEach-Object{Limit-Text ([string]$_) 240})
  guard='Before acting, preserve why/scope/non-goals/verification so execution behaves like a goal-directed assistant, not a command macro.'; nextAction='Create/update task context and execute the smallest verified route.'; path=$outPath
}
Write-JsonUtf8NoBom $outPath $result 10
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "WHY_PLAN ok=True path=$outPath"}
exit 0
