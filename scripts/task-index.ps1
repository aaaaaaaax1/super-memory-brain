param(
  [switch]$Json,
  [switch]$Table,
  [string]$Agent = '',
  [string]$SessionId = '',
  [switch]$IncludeCompleted
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
$statusPath = Join-Path $workspace 'last-task-index.json'
if (-not (Test-Path $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }

function Read-WorkspaceJson([string]$Name) {
  $path = Join-Path $workspace $Name
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Limit-Text([string]$Text, [int]$Max = 180) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ([string]$Text).Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}

function Get-AgeMinutes([string]$TimeText) {
  if ([string]::IsNullOrWhiteSpace($TimeText)) { return 999999 }
  try { return [Math]::Round(((Get-Date) - [DateTime]::Parse($TimeText)).TotalMinutes, 1) } catch { return 999999 }
}

function Get-SafeId([string]$Value, [string]$Fallback) {
  $safe = ([string]$Value -replace '[^A-Za-z0-9._-]','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = $Fallback }
  return $safe.ToLowerInvariant()
}

function Get-DefaultAgentId([string]$Platform, [string]$AgentName) {
  $base = if (-not [string]::IsNullOrWhiteSpace($Platform)) { $Platform } elseif (-not [string]::IsNullOrWhiteSpace($AgentName)) { $AgentName } else { 'agent' }
  return (Get-SafeId $base 'agent') + 'id-default'
}

function Short-Id([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '未登记' }
  $trimmed = $Value.Trim()
  if ($trimmed.Length -le 16) { return $trimmed }
  return $trimmed.Substring(0,8) + "..." + $trimmed.Substring($trimmed.Length - 4)
}

function Short-Time([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  try { return ([DateTime]::Parse($Value)).ToString('HH:mm') } catch { return (Limit-Text $Value 16) }
}

function Escape-Cell([string]$Value) {
  $v = Limit-Text $Value 90
  $escaped = $v -replace '\|','/'
  return ($escaped -replace "`r?`n", '<br>')
}

function New-TaskCandidate(
  [string]$Id,
  [string]$Title,
  [string]$Status,
  [string]$Source,
  [double]$Confidence,
  [int]$Rank,
  [string]$Reason,
  [string]$UpdatedAt = '',
  [string]$CurrentStep = '',
  [string]$NextAction = '',
  [object[]]$Completed = @(),
  [object[]]$Pending = @(),
  [object[]]$Evidence = @(),
  [string]$AgentName = '',
  [string]$AgentId = '',
  [string]$Platform = '',
  [string]$SessionId = '',
  [string]$SessionName = '',
  [string]$TaskName = '',
  [string]$SourcePath = '',
  [object[]]$MemoryIds = @()
) {
  $taskId = Limit-Text $Id 120
  $platformValue = Limit-Text $Platform 80
  $agentNameValue = Limit-Text $AgentName 80
  if ([string]::IsNullOrWhiteSpace($agentNameValue)) { $agentNameValue = if ($platformValue) { $platformValue } else { 'unknown' } }
  $agentIdValue = Limit-Text $(if ($AgentId) { $AgentId } else { Get-DefaultAgentId $platformValue $agentNameValue }) 120
  $sessionIdValue = Limit-Text $SessionId 160
  $taskNameValue = Limit-Text $(if ($TaskName) { $TaskName } elseif ($Title) { $Title } else { $taskId }) 120
  $sessionNameValue = Limit-Text $(if ($SessionName) { $SessionName } elseif ($taskNameValue) { $taskNameValue } else { '未命名会话' }) 120
  $identityKey = ($agentIdValue + '|' + $sessionIdValue + '|' + $taskId).ToLowerInvariant()
  return [pscustomobject]@{
    id = $taskId
    taskId = $taskId
    taskName = $taskNameValue
    title = (Limit-Text $Title 180)
    status = (Limit-Text $Status 80)
    source = (Limit-Text $Source 160)
    sourcePath = (Limit-Text $SourcePath 240)
    confidence = [Math]::Round($Confidence, 2)
    stateConfidence = [Math]::Round($Confidence, 2)
    rank = $Rank
    reason = (Limit-Text $Reason 180)
    updatedAt = (Limit-Text $UpdatedAt 80)
    ageMinutes = Get-AgeMinutes $UpdatedAt
    currentStep = (Limit-Text $CurrentStep 180)
    nextAction = (Limit-Text $NextAction 220)
    completed = @($Completed | Select-Object -First 8 | ForEach-Object { Limit-Text ([string]$_) 160 })
    pending = @($Pending | Select-Object -First 8 | ForEach-Object { Limit-Text ([string]$_) 160 })
    evidence = @($Evidence | Select-Object -First 6 | ForEach-Object { Limit-Text ([string]$_) 160 })
    agent = $agentNameValue
    agentName = $agentNameValue
    agentId = $agentIdValue
    platform = $platformValue
    sessionId = $sessionIdValue
    sessionName = $sessionNameValue
    memoryIds = @($MemoryIds | Select-Object -First 8 | ForEach-Object { Limit-Text ([string]$_) 160 })
    identityKey = $identityKey
  }
}

function Get-SessionCards {
  $sessions = @{}
  $dir = Join-Path $sharedRoot 'sessions'
  if (-not (Test-Path -LiteralPath $dir)) { return $sessions }
  foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.session.json' -File -ErrorAction SilentlyContinue)) {
    $card = Read-JsonFile $file.FullName
    if ($card -and $card.sessionId) { $sessions[[string]$card.sessionId] = $card }
  }
  return $sessions
}

function Add-SharedTaskCards([System.Collections.Hashtable]$SessionCards) {
  $items = @()
  $tasksRoot = Join-Path $sharedRoot 'tasks'
  foreach ($state in @('active','paused','blocked','completed')) {
    $dir = Join-Path $tasksRoot $state
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.task.json' -File -ErrorAction SilentlyContinue)) {
      $task = Read-JsonFile $file.FullName
      if (-not $task) { continue }
      $sessionCard = $null
      if ($task.sessionId -and $SessionCards.ContainsKey([string]$task.sessionId)) { $sessionCard = $SessionCards[[string]$task.sessionId] }
      $sessionName = if ($task.sessionName) { [string]$task.sessionName } elseif ($sessionCard -and $sessionCard.sessionName) { [string]$sessionCard.sessionName } else { '' }
      $items += New-TaskCandidate ([string]$task.taskId) ([string]$task.goal) ([string]$task.status) ('shared/tasks/' + $state) 0.99 5 'shared task identity index' ([string]$task.updatedAt) ([string]$task.currentStep) ([string]$task.nextAction) @($task.completedSteps) @($task.pendingSteps) @($task.evidence) ([string]$task.agentName) ([string]$task.agentId) ([string]$task.platform) ([string]$task.sessionId) $sessionName ([string]$task.taskName) $file.FullName @($task.memoryIds)
    }
  }
  return $items
}

$candidates = @()
$sessionCards = Get-SessionCards
$candidates += Add-SharedTaskCards $sessionCards

$activeCheckpoint = Read-WorkspaceJson 'active-checkpoint.json'
if ($activeCheckpoint) {
  $title = if ($activeCheckpoint.goal) { [string]$activeCheckpoint.goal } else { [string]$activeCheckpoint.taskId }
  $candidates += New-TaskCandidate ([string]$activeCheckpoint.taskId) $title ([string]$activeCheckpoint.status) 'active-checkpoint.json' 0.88 10 'legacy active checkpoint fallback' ([string]$activeCheckpoint.timestamp) ([string]$activeCheckpoint.currentStep) ([string]$activeCheckpoint.nextAction) @($activeCheckpoint.completedSteps) @($activeCheckpoint.pendingSteps) @('active-checkpoint.json') ([string]$activeCheckpoint.agent) ([string]$activeCheckpoint.agentId) ([string]$activeCheckpoint.platform) ([string]$activeCheckpoint.sessionId) ([string]$activeCheckpoint.sessionName) ([string]$activeCheckpoint.taskName) (Join-Path $workspace 'active-checkpoint.json') @($activeCheckpoint.memoryIds)
}

$taskGraph = Read-WorkspaceJson 'task-graph.json'
$stepLedger = Read-WorkspaceJson 'step-ledger.json'
if ($taskGraph -and -not [string]::IsNullOrWhiteSpace([string]$taskGraph.taskId)) {
  $status = if ($taskGraph.status) { [string]$taskGraph.status } else { 'unknown' }
  $openSteps = if ($stepLedger) { @($stepLedger.openSteps) } else { @() }
  $completedSteps = if ($stepLedger) { @($stepLedger.completedSteps) } else { @() }
  $currentStep = if ($openSteps.Count -gt 0) { [string]$openSteps[0].step } else { '' }
  $nextAction = if ($openSteps.Count -gt 0) { 'Continue first open step or mark skipped with reason.' } elseif ($taskGraph.PSObject.Properties['nextAction']) { [string]$taskGraph.nextAction } else { '' }
  $rank = if ($status -eq 'active') { 20 } elseif ($status -in @('paused','blocked','waiting')) { 30 } elseif ($status -in @('completed','archived','idle')) { 60 } else { 45 }
  $confidence = if ($status -eq 'active') { 0.78 } elseif ($status -in @('paused','blocked','waiting')) { 0.72 } elseif ($status -in @('completed','archived','idle')) { 0.55 } else { 0.65 }
  $reason = if ($status -eq 'active') { 'active task graph with step ledger' } elseif ($status -in @('paused','blocked','waiting')) { 'paused or blocked task graph should be offered after active checkpoint' } else { 'task graph candidate' }
  $candidates += New-TaskCandidate ([string]$taskGraph.taskId) ([string]$taskGraph.goal) $status 'task-graph.json + step-ledger.json' $confidence $rank $reason ([string]$taskGraph.updatedAt) $currentStep $nextAction @($completedSteps | ForEach-Object { if ($_.step) { $_.step } else { $_ } }) @($openSteps | ForEach-Object { if ($_.step) { $_.step } else { $_ } }) @('task-graph.json','step-ledger.json') 'super-memory-brain' 'zcodeid-default' 'zcode' '' '' ([string]$taskGraph.goal) (Join-Path $workspace 'task-graph.json') @()
}

$lastCompletedCheckpoint = Read-WorkspaceJson 'last-completed-checkpoint.json'
if ($lastCompletedCheckpoint) {
  $candidates += New-TaskCandidate ([string]$lastCompletedCheckpoint.taskId) ([string]$lastCompletedCheckpoint.goal) 'completed' 'last-completed-checkpoint.json' 0.52 70 'recent completed checkpoint is useful for status but should not override active work' ([string]$lastCompletedCheckpoint.timestamp) ([string]$lastCompletedCheckpoint.currentStep) ([string]$lastCompletedCheckpoint.nextAction) @($lastCompletedCheckpoint.completedSteps) @($lastCompletedCheckpoint.pendingSteps) @('last-completed-checkpoint.json') ([string]$lastCompletedCheckpoint.agent) ([string]$lastCompletedCheckpoint.agentId) ([string]$lastCompletedCheckpoint.platform) ([string]$lastCompletedCheckpoint.sessionId) ([string]$lastCompletedCheckpoint.sessionName) ([string]$lastCompletedCheckpoint.taskName) (Join-Path $workspace 'last-completed-checkpoint.json') @($lastCompletedCheckpoint.memoryIds)
}

$lastTaskVerification = Read-WorkspaceJson 'last-task-verification.json'
if ($lastTaskVerification -and -not [string]::IsNullOrWhiteSpace([string]$lastTaskVerification.summary)) {
  $candidates += New-TaskCandidate 'last-task-verification' ([string]$lastTaskVerification.summary) $(if ($lastTaskVerification.ok -eq $true) { 'completed_or_verified' } else { 'needs_attention' }) 'last-task-verification.json' 0.42 80 'verification summary is a weak status candidate' ([string]$lastTaskVerification.checkedAt) '' ([string](@($lastTaskVerification.nextSteps) -join '; ')) @($lastTaskVerification.changed) @($lastTaskVerification.nextSteps) @('last-task-verification.json') 'super-memory-brain' 'zcodeid-default' 'zcode' '' '验证摘要' 'last-task-verification' (Join-Path $workspace 'last-task-verification.json') @()
}

$statusCard = Read-WorkspaceJson 'status-card.json'
if ($statusCard -and -not [string]::IsNullOrWhiteSpace([string]$statusCard.nextAction)) {
  $candidates += New-TaskCandidate 'status-card' ([string]$statusCard.nextAction) $(if ($statusCard.ok -eq $true) { 'status_hint' } else { 'status_risk' }) 'status-card.json' 0.35 90 'status card is a fallback hint, not a task override' ([string]$statusCard.updatedAt) '' ([string]$statusCard.nextAction) @() @() @('status-card.json') 'super-memory-brain' 'zcodeid-default' 'zcode' '' '状态提示' 'status-card' (Join-Path $workspace 'status-card.json') @()
}

$filtered = @($candidates | Where-Object {
  $agentOk = $true
  if (-not [string]::IsNullOrWhiteSpace($Agent)) {
    $agentLower = $Agent.ToLowerInvariant()
    $agentOk = ([string]$_.platform).ToLowerInvariant() -eq $agentLower -or ([string]$_.agentName).ToLowerInvariant() -eq $agentLower -or ([string]$_.agentId).ToLowerInvariant() -eq $agentLower
  }
  $sessionOk = $true
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $sessionOk = ([string]$_.sessionId) -eq $SessionId }
  $completionOk = $IncludeCompleted -or (-not ($_.status -like 'completed*' -or $_.status -eq 'verified'))
  $agentOk -and $sessionOk -and $completionOk
})

$unique = @()
$seen = @{}
foreach ($candidate in @($filtered | Sort-Object -Property @{Expression='rank';Descending=$false}, @{Expression='confidence';Descending=$true}, @{Expression='ageMinutes';Descending=$false})) {
  $key = if ($candidate.identityKey) { [string]$candidate.identityKey } elseif ($candidate.id) { [string]$candidate.id } else { [string]$candidate.title }
  if ([string]::IsNullOrWhiteSpace($key)) { continue }
  if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $unique += $candidate }
}

$current = @($unique | Where-Object { $_.status -in @('active','running','in_progress') })
$paused = @($unique | Where-Object { $_.status -in @('paused','blocked','waiting','needs_attention') })
$completed = @($unique | Where-Object { $_.status -like 'completed*' -or $_.status -eq 'verified' })
$hints = @($unique | Where-Object { $_.status -notin @('active','running','in_progress','paused','blocked','waiting','needs_attention','verified') -and $_.status -notlike 'completed*' })
$unfinished = @($current + $paused)

$unknownSession = $false
if (-not [string]::IsNullOrWhiteSpace($SessionId) -and @($unique).Count -eq 0) { $unknownSession = $true }

$result = [pscustomobject]@{
  ok = $true
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = [string]$manifest.version
  packageRoot = $Root
  sharedIndexRoot = $sharedRoot
  query = [pscustomobject]@{ agent=$Agent; sessionId=$SessionId; includeCompleted=[bool]$IncludeCompleted }
  current = @($current)
  paused = @($paused)
  completed = @($completed)
  candidates = @($hints)
  all = @($unique)
  unknownSession = $unknownSession
  unknownReason = if ($unknownSession) { '共享索引未登记该会话；未知，不等于没有任务' } else { '' }
  rankingPolicy = 'rank/confidence/freshness: shared task identity index rank 5 > legacy active checkpoint rank 10 > active task graph rank 20 > paused/blocked rank 30 > weak verification rank 80 > status-card fallback rank 90; ties use confidence then freshness.'
  choiceListPolicy = 'When multiple plausible candidates remain, return a numbered choice list with status, scope, freshness, and next action instead of guessing.'
  counts = [pscustomobject]@{ current=@($current).Count; paused=@($paused).Count; completed=@($completed).Count; candidates=@($hints).Count; total=@($unique).Count }
  nextAction = if (@($current).Count -eq 1) { 'Resume the single current task if the user authorized execution.' } elseif (@($current).Count -gt 1) { 'Ask the user to choose which current task to resume.' } elseif (@($paused).Count -gt 0) { 'Ask whether to resume a paused/blocked task.' } elseif ($unknownSession) { 'Ask the owning agent/session to write a shared session card and task checkpoint.' } else { 'No active task is registered in the shared index; unknown is not the same as no task outside the index.' }
  statusPath = $statusPath
}
Write-JsonUtf8NoBom $statusPath $result 12

function Write-TaskTable([object]$IndexResult) {
  if ($IndexResult.unknownSession -eq $true) {
    Write-Output '### 会话任务状态'
    Write-Output ''
    Write-Output '| 项目 | 内容 |'
    Write-Output '|---|---|'
    Write-Output '| 状态 | 未知 |'
    Write-Output "| 会话 | ``$(Short-Id $SessionId)`` |"
    Write-Output '| 原因 | 共享索引未登记该会话 |'
    Write-Output '| 结论 | 未知，不等于没有任务 |'
    return
  }

  $rows = @($IndexResult.current + $IndexResult.paused)
  if ($IncludeCompleted) { $rows += @($IndexResult.completed) }
  $rows = @($rows | Select-Object -First 12)
  $titleAgent = if ([string]::IsNullOrWhiteSpace($Agent)) { '当前未完成任务' } else { ((Get-Culture).TextInfo.ToTitleCase($Agent.ToLowerInvariant()) + ' 当前任务') }
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $item = @($rows | Select-Object -First 1)
    Write-Output '### 会话任务状态'
    Write-Output ''
    if ($item.Count -eq 0) { Write-Output '未发现已登记任务。'; return }
    $t = $item[0]
    Write-Output '| 项目 | 内容 |'
    Write-Output '|---|---|'
    Write-Output "| 会话 | $(Escape-Cell $t.sessionName) |"
    Write-Output "| 会话 ID | ``$($t.sessionId)`` |"
    Write-Output "| Agent | $(Escape-Cell $t.agentName) / ``$($t.agentId)`` |"
    Write-Output "| 状态 | ``$($t.status)`` · $(Short-Time $t.updatedAt) |"
    Write-Output "| 任务 | ``$($t.taskId)`` |"
    Write-Output "| 当前 | $(Escape-Cell $t.currentStep) |"
    Write-Output "| 下一步 | $(Escape-Cell $t.nextAction) |"
    return
  }

  Write-Output "### $titleAgent：$($rows.Count) 个"
  Write-Output ''
  if ($rows.Count -eq 0) {
    Write-Output '未在共享索引中发现未完成任务。未知不等于没有任务。'
    return
  }
  if ([string]::IsNullOrWhiteSpace($Agent)) {
    Write-Output '| # | 来源 | 会话 / 状态 | 进度 |'
    Write-Output '|---|---|---|---|'
    $i = 1
    foreach ($t in $rows) {
      $source = if ($t.platform) { $t.platform } else { $t.agentName }
      $sessionCell = "$(Escape-Cell $t.sessionName)<br>``$($t.status)`` · $(Short-Time $t.updatedAt)<br>``$(Short-Id $t.sessionId)``"
      $progressCell = "当前：$(Escape-Cell $t.currentStep)<br>下一步：$(Escape-Cell $t.nextAction)"
      Write-Output "| $i | $(Escape-Cell $source) | $sessionCell | $progressCell |"
      $i += 1
    }
  } else {
    Write-Output '| # | 会话 / 状态 | 进度 |'
    Write-Output '|---|---|---|'
    $i = 1
    foreach ($t in $rows) {
      $sessionCell = "$(Escape-Cell $t.sessionName)<br>``$($t.status)`` · $(Short-Time $t.updatedAt)<br>``$(Short-Id $t.sessionId)``"
      $progressCell = "当前：$(Escape-Cell $t.currentStep)<br>下一步：$(Escape-Cell $t.nextAction)"
      Write-Output "| $i | $sessionCell | $progressCell |"
      $i += 1
    }
  }
}

if ($Json) { $result | ConvertTo-Json -Depth 12 }
elseif ($Table) { Write-TaskTable $result }
else { Write-Host "TASK_INDEX current=$(@($current).Count) paused=$(@($paused).Count) completed=$(@($completed).Count) candidates=$(@($hints).Count) status=$statusPath" }
exit 0
