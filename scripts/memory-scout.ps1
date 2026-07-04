param(
  [string]$Goal = '',
  [int]$TopK = 5,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$outPath = Join-Path $workspace 'last-memory-scout.json'
if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function Limit-Text([string]$Value,[int]$Max=360){ if([string]::IsNullOrWhiteSpace($Value)){return ''}; $v=$Value.Trim() -replace '\s+',' '; if($v.Length -gt $Max){return $v.Substring(0,$Max)+'...'}; return $v }
function Read-WorkspaceJson([string]$Name){ $p=Join-Path $workspace $Name; if(-not(Test-Path -LiteralPath $p)){return $null}; try{Get-Content -LiteralPath $p -Raw -Encoding UTF8|ConvertFrom-Json}catch{return $null} }
function Add-Card($List,[string]$Kind,[string]$Title,[string]$Summary,[string]$Path,[double]$Confidence){ [void]$List.Add([pscustomobject]@{ kind=$Kind; title=Limit-Text $Title 120; summary=Limit-Text $Summary 420; path=$Path; confidence=[Math]::Round($Confidence,4) }) }

$cards = New-Object System.Collections.ArrayList
$taskIndexText = ''
try {
  $taskIndexText = (& (Join-Path $PSScriptRoot 'task-index.ps1') -Json 2>$null) -join "`n"
  $taskIndex = $taskIndexText | ConvertFrom-Json
  foreach($task in @($taskIndex.current | Select-Object -First $TopK)) { Add-Card $cards 'current_task' ([string]$task.taskName) ([string]$task.currentStep + ' next=' + [string]$task.nextAction) ([string]$task.sourcePath) 0.9 }
} catch {}

foreach($name in @('current-task-context.json','active-checkpoint.json','last-verify-package.json','last-guard-negative-e2e.json','last-guard-flow-e2e.json','last-completion-guard.json','last-hot-refresh.json','last-reflection-promotion.json')) {
  $obj = Read-WorkspaceJson $name
  if($obj){ Add-Card $cards 'workspace_state' $name (($obj | ConvertTo-Json -Depth 4 -Compress)) (Join-Path $workspace $name) 0.65 }
}

$recallCards = @()
if(-not [string]::IsNullOrWhiteSpace($Goal)) {
  try {
    $recallRaw = @(& (Join-Path $PSScriptRoot 'recall-search.ps1') -Query $Goal -TopK $TopK -MaxTokens 700 -MemoryMode auto -Json 2>$null)
    if($recallRaw){ $recallCards = @(($recallRaw -join "`n") | ConvertFrom-Json) }
    foreach($r in @($recallCards | Select-Object -First $TopK)) {
      $title = if($r.title){[string]$r.title}elseif($r.text){Limit-Text ([string]$r.text) 100}else{'memory'}
      $summary = if($r.evidenceCard){($r.evidenceCard | ConvertTo-Json -Depth 4 -Compress)}else{[string]$r.text}
      $confidence = 0.45
      if($null -ne $r.confidence){ $confidence = [double]$r.confidence }
      Add-Card $cards 'memory_hint' $title $summary ([string]$r.source) $confidence
    }
  } catch {}
}

$result=[pscustomobject]@{
  ok=$true; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); schema='super-brain.memory-scout.v1'; version=(Get-SuperBrainManifest $Root).version
  goal=Limit-Text $Goal 500; cards=@($cards | Select-Object -First ($TopK * 4)); guard='Lightweight scout only: compact task/state/memory hints, no raw long history injection.'
  nextAction='Use these cards to decide current context, constraints, and evidence before execution.'; path=$outPath
}
Write-JsonUtf8NoBom $outPath $result 12
if($Json){Get-Content -LiteralPath $outPath -Raw -Encoding UTF8}else{Write-Host "MEMORY_SCOUT ok=True cards=$(@($result.cards).Count) path=$outPath"}
exit 0
