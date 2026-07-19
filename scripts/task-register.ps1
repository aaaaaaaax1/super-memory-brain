param(
  [string]$TaskId = '',
  [string]$TaskName = '',
  [ValidateSet('active','running','in_progress','paused','waiting','blocked','completed','verified')]
  [string]$Status = 'active',
  [string]$Agent = 'agent',
  [string]$AgentId = '',
  [string]$Platform = 'zcode',
  [string]$SessionId = '',
  [Alias('ConversationTitle')]
  [string]$SessionTitle = '',
  [string]$SessionName = '',
  [string]$WorkspaceKey = '',
  [string]$Goal = '',
  [string]$CurrentPhase = '',
  [string]$CurrentStep = '',
  [string]$NextAction = '',
  [string[]]$CompletedSteps = @(),
  [string[]]$PendingSteps = @(),
  [string[]]$Blockers = @(),
  [string[]]$Evidence = @(),
  [string[]]$MemoryIds = @(),
  [bool]$WaitingForUser = $false,
  [switch]$Auto,
  [string]$Reason = '',
  [string]$Source = 'task-register.ps1',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'task-link-store.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
# Fast path only: writes memory/shared/agents, sessions, tasks, and links. It never touches active-checkpoint.json or calls doctor.ps1, verify-package.ps1, hot-refresh-skills.ps1, ci.ps1, super-brain-dashboard.ps1, auto-check.ps1, or recall-search.ps1.

function Limit-Text([string]$Text, [int]$Max = 180) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ([string]$Text).Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}

function Limit-List([object[]]$Items, [int]$MaxItems = 8, [int]$MaxChars = 160) {
  return @(@($Items) | Select-Object -First $MaxItems | ForEach-Object { Limit-Text ([string]$_) $MaxChars })
}

function Get-SafeName([string]$Value, [string]$Fallback) {
  $safe = ([string]$Value -replace '[^A-Za-z0-9._-]','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = $Fallback }
  return $safe.ToLowerInvariant()
}

function Get-AgentId([string]$PlatformValue, [string]$AgentValue) {
  if (-not [string]::IsNullOrWhiteSpace($AgentId)) { return Get-SafeName $AgentId 'agentid-default' }
  $base = if (-not [string]::IsNullOrWhiteSpace($PlatformValue)) { $PlatformValue } elseif (-not [string]::IsNullOrWhiteSpace($AgentValue)) { $AgentValue } else { 'agent' }
  return (Get-SafeName $base 'agent') + 'id-default'
}

function Get-TaskDirectory([string]$StatusValue) {
  $normalized = ([string]$StatusValue).ToLowerInvariant()
  if ($normalized -in @('paused','waiting')) { return 'paused' }
  if ($normalized -eq 'blocked') { return 'blocked' }
  if ($normalized -in @('completed','verified')) { return 'completed' }
  return 'active'
}

function New-TaskId {
  return 'task-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + ([guid]::NewGuid().ToString('n').Substring(0,6))
}

function Read-JsonFile([string]$JsonPath) {
  if (-not (Test-Path -LiteralPath $JsonPath)) { return $null }
  try { return Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Find-AutoReusableTask([string]$NameValue, [string]$SessionNameValue, [string]$AgentIdValue, [string]$WorkspaceKeyValue) {
  $roots = @('active','paused','blocked') | ForEach-Object { Join-Path (Join-Path $sharedRoot 'tasks') $_ }
  foreach ($rootDir in $roots) {
    if (-not (Test-Path -LiteralPath $rootDir)) { continue }
    $cards = Get-ChildItem -LiteralPath $rootDir -Filter '*.task.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($cardFile in @($cards)) {
      $card = Read-JsonFile $cardFile.FullName
      if (-not $card) { continue }
      $sameName = (-not [string]::IsNullOrWhiteSpace($NameValue) -and [string]$card.taskName -eq $NameValue)
      $sameSession = (-not [string]::IsNullOrWhiteSpace($SessionNameValue) -and [string]$card.sessionName -eq $SessionNameValue)
      $sameAgent = ([string]::IsNullOrWhiteSpace($AgentIdValue) -or [string]$card.agentId -eq $AgentIdValue)
      $sameWorkspace = ($card.PSObject.Properties['workspaceKey'] -and (Test-SuperBrainWorkspaceKey ([string]$card.workspaceKey) $WorkspaceKeyValue))
      $sessionMatches = ([string]::IsNullOrWhiteSpace($SessionNameValue) -or $sameSession)
      if ($sameAgent -and $sameWorkspace -and $sameName -and $sessionMatches) { return $card }
    }
  }
  return $null
}

$agentIdValue = Get-AgentId $Platform $Agent
$workspaceKeyValue = Get-SuperBrainWorkspaceKey $WorkspaceKey
$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$taskNameValue = if ($TaskName) { Limit-Text $TaskName 120 } elseif ($Goal) { Limit-Text $Goal 120 } else { $TaskId }
$sessionTitleValue = Limit-Text $SessionTitle 120
$sessionNameValue = if ($SessionName) { Limit-Text $SessionName 120 } elseif ($sessionTitleValue) { $sessionTitleValue } elseif ($taskNameValue) { $taskNameValue } else { 'unnamed session' }
if ($Auto -and [string]::IsNullOrWhiteSpace($TaskId)) {
  $reusable = Find-AutoReusableTask $taskNameValue $sessionNameValue $agentIdValue $workspaceKeyValue
  if ($reusable -and -not [string]::IsNullOrWhiteSpace([string]$reusable.taskId)) { $TaskId = [string]$reusable.taskId }
}
if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = New-TaskId }
if ([string]::IsNullOrWhiteSpace($taskNameValue)) { $taskNameValue = $TaskId }
$statusDir = Get-TaskDirectory $Status

$agentsDir = Join-Path $sharedRoot 'agents'
$sessionsDir = Join-Path $sharedRoot 'sessions'
$tasksRoot = Join-Path $sharedRoot 'tasks'
$taskDir = Join-Path $tasksRoot $statusDir
$linksDir = Join-Path $sharedRoot 'links'
foreach ($dir in @($agentsDir,$sessionsDir,$tasksRoot,$taskDir,$linksDir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$agentCardPath = Join-Path $agentsDir ($agentIdValue + '.agent.json')
$agentCard = [pscustomobject]@{
  schema = 'super-brain.agent-card.v1'
  agentId = $agentIdValue
  agentName = $Agent
  platform = $Platform
  memoryScope = 'shared-index'
  privateMemoryRoot = Join-Path (Join-Path $memoryBase 'agents') (Get-SafeName $Platform 'agent')
  sharedIndexRoot = $sharedRoot
  lastSeenAt = $timestamp
  source = $Source
}
Write-JsonUtf8NoBom $agentCardPath $agentCard 8

$sessionCardPath = ''
if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
  $sessionCardPath = Join-Path $sessionsDir ((Get-SafeName $SessionId 'session') + '.session.json')
  $existingSession = Read-JsonFile $sessionCardPath
  $taskIds = @()
  if ($existingSession -and $existingSession.currentTaskIds) { $taskIds += @($existingSession.currentTaskIds) }
  if ($Status -in @('active','running','in_progress','paused','waiting','blocked')) { $taskIds += $TaskId }
  else { $taskIds = @($taskIds | Where-Object { [string]$_ -ne $TaskId }) }
  $taskIds = @($taskIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  $sessionCard = [pscustomobject]@{
    schema = 'super-brain.session-card.v1'
    sessionId = $SessionId
    sessionName = $sessionNameValue
    agentId = $agentIdValue
    agentName = $Agent
    platform = $Platform
    workspaceKey = $workspaceKeyValue
    status = if ($Status -in @('active','running','in_progress')) { 'active' } elseif ($Status -in @('paused','waiting','blocked')) { $Status } else { 'completed' }
    currentTaskIds = @($taskIds)
    memoryIds = @(Limit-List $MemoryIds 12 160)
    lastSeenAt = $timestamp
    source = $Source
  }
  Write-JsonUtf8NoBom $sessionCardPath $sessionCard 8
}

$taskCardPath = Join-Path $taskDir ((Get-SafeName $TaskId 'task') + '.task.json')
$taskCard = [pscustomobject]@{
  schema = 'super-brain.task-card.v1'
  taskId = $TaskId
  taskName = $taskNameValue
  agentId = $agentIdValue
  agentName = $Agent
  platform = $Platform
  workspaceKey = $workspaceKeyValue
  sessionId = $SessionId
  sessionName = $sessionNameValue
  status = $Status
  goal = Limit-Text $Goal 180
  currentPhase = Limit-Text $CurrentPhase 120
  currentStep = Limit-Text $CurrentStep 180
  nextAction = Limit-Text $NextAction 220
  completedSteps = @(Limit-List $CompletedSteps 12 160)
  pendingSteps = @(Limit-List $PendingSteps 12 160)
  blockers = @(Limit-List $Blockers 8 160)
  waitingForUser = [bool]$WaitingForUser
  evidence = @(Limit-List $Evidence 8 160)
  memoryIds = @(Limit-List $MemoryIds 12 160)
  source = $Source
  sourcePath = $taskCardPath
  lifecycle = if($Auto){'AutoRegister'}else{'Register'}
  auto = [bool]$Auto
  reason = Limit-Text $Reason 220
  updatedAt = $timestamp
}
$taskState = Commit-SuperBrainTaskState $TaskId 'task_card' $taskCard $taskCardPath 'task-register.ps1'

foreach ($other in @('active','paused','blocked','completed')) {
  if ($other -eq $statusDir) { continue }
  $otherPath = Join-Path (Join-Path $tasksRoot $other) ((Get-SafeName $TaskId 'task') + '.task.json')
  if (Test-Path -LiteralPath $otherPath) { Remove-Item -LiteralPath $otherPath -Force -ErrorAction SilentlyContinue }
}

$sessionTaskPath = Join-Path $linksDir 'session-task-links.json'
$linkPolicy = Get-SuperBrainTaskLinkPolicy $Root
$sessionLink = [pscustomobject]@{ sessionId=$SessionId; sessionName=$sessionNameValue; agentId=$agentIdValue; platform=$Platform; workspaceKey=$workspaceKeyValue; taskId=$TaskId; status=$Status; updatedAt=$timestamp; source=$Source }
$sessionLinkResult = Update-SuperBrainTaskLinkFile -Path $sessionTaskPath -Schema 'super-brain.session-task-links.v1' -Kind 'session-task' -Incoming @($sessionLink) -MaxItems $linkPolicy.maxSessionTaskLinks -CompletedRetentionDays $linkPolicy.completedRetentionDays -UpdatedAt $timestamp

$taskMemoryPath = Join-Path $linksDir 'task-memory-links.json'
$taskMemoryLinks = @()
foreach ($memoryId in @($MemoryIds)) {
  if (-not [string]::IsNullOrWhiteSpace([string]$memoryId)) { $taskMemoryLinks += [pscustomobject]@{ taskId=$TaskId; memoryId=[string]$memoryId; agentId=$agentIdValue; sessionId=$SessionId; updatedAt=$timestamp; source=$Source } }
}
$taskMemoryLinkResult = Update-SuperBrainTaskLinkFile -Path $taskMemoryPath -Schema 'super-brain.task-memory-links.v1' -Kind 'task-memory' -Incoming @($taskMemoryLinks) -MaxItems $linkPolicy.maxTaskMemoryLinks -CompletedRetentionDays $linkPolicy.completedRetentionDays -UpdatedAt $timestamp

$result = [pscustomobject]@{
  ok = $true
  fastPath = $true
  checkedAt = $timestamp
  taskId = $TaskId
  taskName = $taskNameValue
  status = $Status
  statusDir = $statusDir
  agentId = $agentIdValue
  agent = $Agent
  platform = $Platform
  workspaceKey = $workspaceKeyValue
  sessionId = $SessionId
  sessionName = $sessionNameValue
  sessionTitle = $sessionTitleValue
  wrote = [pscustomobject]@{ agent=$agentCardPath; session=$sessionCardPath; task=$taskCardPath; sessionTaskLinks=$sessionTaskPath; taskMemoryLinks=$taskMemoryPath }
  linkLifecycle = [pscustomobject]@{ sessionTaskBefore=$sessionLinkResult.beforeCount; sessionTaskAfter=$sessionLinkResult.afterCount; sessionTaskPruned=$sessionLinkResult.prunedCount; taskMemoryBefore=$taskMemoryLinkResult.beforeCount; taskMemoryAfter=$taskMemoryLinkResult.afterCount; taskMemoryPruned=$taskMemoryLinkResult.prunedCount }
  taskStateRevision = [int]$taskState.revision
  note = 'fast task registration only; no active checkpoint, doctor, verify, hot-refresh, CI, dashboard, auto-check, or recall was run'
  auto = [bool]$Auto
  reason = Limit-Text $Reason 220
}

if ($Json) { $result | ConvertTo-Json -Depth 8 } else { Write-Host "TASK_REGISTER_OK taskId=$TaskId sessionId=$SessionId status=$Status path=$taskCardPath" }
exit 0
