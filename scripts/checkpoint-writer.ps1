param(
  [ValidateSet('Start','Complete','Clear','Get')]
  [string]$Action = 'Get',
  [string]$TaskId = '',
  [string]$SessionId = '',
  [string]$Agent = 'super-memory-brain',
  [string]$AgentId = '',
  [string]$Platform = 'zcode',
  [string]$SessionName = '',
  [string]$TaskName = '',
  [string]$CurrentStep = '',
  [string]$NextAction = '',
  [string[]]$Blockers = @(),
  [string[]]$Evidence = @(),
  [string[]]$AcceptedConstraints = @(),
  [string[]]$ConstraintSources = @(),
  [string[]]$MemoryIds = @(),
  [string]$PreflightId = '',
  [string]$GuardHash = '',
  [string]$Source = '',
  [string]$Status = 'active',
  [string]$Goal = '',
  [string]$CurrentPhase = '',
  [string[]]$CompletedSteps = @(),
  [string[]]$PendingSteps = @(),
  [string[]]$ChangedFiles = @(),
  [string[]]$VerificationCommands = @(),
  [string[]]$VerificationResults = @(),
  [bool]$WaitingForUser = $false,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
New-Item -ItemType Directory -Force -Path $workspace | Out-Null
$path = Join-Path $workspace 'active-checkpoint.json'
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
# Shared identity index paths: memory/shared/agents, memory/shared/sessions, memory/shared/tasks, memory/shared/links.

function Read-Checkpoint {
  if (-not (Test-Path $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Limit-Text([string]$Text, [int]$Max = 180) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ([string]$Text).Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}

function Limit-List([object[]]$Items, [int]$MaxItems = 8, [int]$MaxChars = 160) {
  return @(@($Items) | Select-Object -First $MaxItems | ForEach-Object { Limit-Text ([string]$_) $MaxChars })
}

function Get-IdentitySafeName([string]$Value, [string]$Fallback) {
  $safe = ([string]$Value -replace '[^A-Za-z0-9._-]','-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = $Fallback }
  return $safe.ToLowerInvariant()
}

function Get-DefaultAgentId([string]$PlatformValue, [string]$AgentValue) {
  if (-not [string]::IsNullOrWhiteSpace($AgentId)) { return Get-IdentitySafeName $AgentId 'agentid-default' }
  $base = if (-not [string]::IsNullOrWhiteSpace($PlatformValue)) { $PlatformValue } elseif (-not [string]::IsNullOrWhiteSpace($AgentValue)) { $AgentValue } else { 'agent' }
  return (Get-IdentitySafeName $base 'agent') + 'id-default'
}

function Get-TaskDirectoryForStatus([string]$StatusValue) {
  $normalized = ([string]$StatusValue).ToLowerInvariant()
  if ($normalized -in @('paused','waiting')) { return 'paused' }
  if ($normalized -eq 'blocked') { return 'blocked' }
  if ($normalized -like 'completed*' -or $normalized -eq 'verified') { return 'completed' }
  return 'active'
}

function Read-JsonFile([string]$JsonPath) {
  if (-not (Test-Path -LiteralPath $JsonPath)) { return $null }
  try { return Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-SharedTaskIdentity([object]$Checkpoint, [string]$Lifecycle) {
  $taskIdValue = [string]$Checkpoint.taskId
  if ([string]::IsNullOrWhiteSpace($taskIdValue)) { return }

  $agentName = if ($Checkpoint.agent) { [string]$Checkpoint.agent } else { $Agent }
  $platformName = if ($Checkpoint.platform) { [string]$Checkpoint.platform } else { $Platform }
  $agentIdValue = if ($Checkpoint.agentId) { Get-IdentitySafeName ([string]$Checkpoint.agentId) 'agentid-default' } else { Get-DefaultAgentId $platformName $agentName }
  $sessionIdValue = if ($Checkpoint.sessionId) { [string]$Checkpoint.sessionId } else { '' }
  $sessionNameValue = if ($Checkpoint.sessionName) { [string]$Checkpoint.sessionName } elseif ($Checkpoint.taskName) { [string]$Checkpoint.taskName } elseif ($Checkpoint.goal) { Limit-Text ([string]$Checkpoint.goal) 60 } else { '' }
  $taskNameValue = if ($Checkpoint.taskName) { [string]$Checkpoint.taskName } elseif ($Checkpoint.goal) { Limit-Text ([string]$Checkpoint.goal) 90 } else { $taskIdValue }
  $statusValue = if ($Checkpoint.status) { [string]$Checkpoint.status } else { 'active' }
  $updatedAt = if ($Checkpoint.timestamp) { [string]$Checkpoint.timestamp } elseif ($Checkpoint.updatedAt) { [string]$Checkpoint.updatedAt } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

  $agentsDir = Join-Path $sharedRoot 'agents'
  $sessionsDir = Join-Path $sharedRoot 'sessions'
  $tasksRoot = Join-Path $sharedRoot 'tasks'
  $linksDir = Join-Path $sharedRoot 'links'
  foreach ($dir in @($agentsDir,$sessionsDir,$tasksRoot,$linksDir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $agentCardPath = Join-Path $agentsDir ($agentIdValue + '.agent.json')
  $agentCard = [pscustomobject]@{
    schema = 'super-brain.agent-card.v1'
    agentId = $agentIdValue
    agentName = $agentName
    platform = $platformName
    memoryScope = 'shared-index'
    privateMemoryRoot = Join-Path (Join-Path $memoryBase 'agents') (Get-IdentitySafeName $platformName 'agent')
    sharedIndexRoot = $sharedRoot
    lastSeenAt = $updatedAt
    source = 'checkpoint-writer.ps1'
  }
  Write-JsonUtf8NoBom $agentCardPath $agentCard 8

  if (-not [string]::IsNullOrWhiteSpace($sessionIdValue)) {
    $sessionCardPath = Join-Path $sessionsDir ((Get-IdentitySafeName $sessionIdValue 'session') + '.session.json')
    $existingSession = Read-JsonFile $sessionCardPath
    $taskIds = @()
    if ($existingSession -and $existingSession.currentTaskIds) { $taskIds += @($existingSession.currentTaskIds) }
    if ($statusValue -in @('active','running','in_progress','paused','blocked','waiting')) { $taskIds += $taskIdValue }
    $taskIds = @($taskIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    $sessionCard = [pscustomobject]@{
      schema = 'super-brain.session-card.v1'
      sessionId = $sessionIdValue
      sessionName = $sessionNameValue
      agentId = $agentIdValue
      agentName = $agentName
      platform = $platformName
      status = if ($statusValue -in @('active','running','in_progress')) { 'active' } elseif ($statusValue -in @('paused','blocked','waiting')) { $statusValue } else { 'completed' }
      currentTaskIds = @($taskIds)
      memoryIds = @($Checkpoint.memoryIds)
      lastSeenAt = $updatedAt
      source = 'checkpoint-writer.ps1'
    }
    Write-JsonUtf8NoBom $sessionCardPath $sessionCard 8
  }

  $taskDirName = Get-TaskDirectoryForStatus $statusValue
  $taskDir = Join-Path $tasksRoot $taskDirName
  New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
  $taskCardPath = Join-Path $taskDir ((Get-IdentitySafeName $taskIdValue 'task') + '.task.json')
  $taskCard = [pscustomobject]@{
    schema = 'super-brain.task-card.v1'
    taskId = $taskIdValue
    taskName = $taskNameValue
    agentId = $agentIdValue
    agentName = $agentName
    platform = $platformName
    sessionId = $sessionIdValue
    sessionName = $sessionNameValue
    status = $statusValue
    goal = [string]$Checkpoint.goal
    currentPhase = [string]$Checkpoint.currentPhase
    currentStep = [string]$Checkpoint.currentStep
    nextAction = [string]$Checkpoint.nextAction
    completedSteps = @($Checkpoint.completedSteps)
    pendingSteps = @($Checkpoint.pendingSteps)
    blockers = @($Checkpoint.blockers)
    waitingForUser = [bool]$Checkpoint.waitingForUser
    evidence = @($Checkpoint.evidence)
    memoryIds = @($Checkpoint.memoryIds)
    source = 'checkpoint-writer.ps1'
    sourcePath = $taskCardPath
    lifecycle = $Lifecycle
    updatedAt = $updatedAt
  }
  Write-JsonUtf8NoBom $taskCardPath $taskCard 10

  foreach ($other in @('active','paused','blocked','completed')) {
    if ($other -eq $taskDirName) { continue }
    $otherPath = Join-Path (Join-Path $tasksRoot $other) ((Get-IdentitySafeName $taskIdValue 'task') + '.task.json')
    if (Test-Path -LiteralPath $otherPath) { Remove-Item -LiteralPath $otherPath -Force -ErrorAction SilentlyContinue }
  }

  $sessionTaskPath = Join-Path $linksDir 'session-task-links.json'
  $taskMemoryPath = Join-Path $linksDir 'task-memory-links.json'
  $sessionTaskLinks = @()
  $existingLinks = Read-JsonFile $sessionTaskPath
  if ($existingLinks -and $existingLinks.links) { $sessionTaskLinks += @($existingLinks.links) }
  $sessionTaskLinks += [pscustomobject]@{ sessionId=$sessionIdValue; sessionName=$sessionNameValue; agentId=$agentIdValue; platform=$platformName; taskId=$taskIdValue; status=$statusValue; updatedAt=$updatedAt; source='checkpoint-writer.ps1' }
  $sessionTaskLinks = @($sessionTaskLinks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.taskId) } | Sort-Object sessionId,taskId,updatedAt -Unique)
  Write-JsonUtf8NoBom $sessionTaskPath ([pscustomobject]@{ schema='super-brain.session-task-links.v1'; updatedAt=$updatedAt; links=@($sessionTaskLinks) }) 10

  $taskMemoryLinks = @()
  $existingMemoryLinks = Read-JsonFile $taskMemoryPath
  if ($existingMemoryLinks -and $existingMemoryLinks.links) { $taskMemoryLinks += @($existingMemoryLinks.links) }
  foreach ($memoryId in @($Checkpoint.memoryIds)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$memoryId)) { $taskMemoryLinks += [pscustomobject]@{ taskId=$taskIdValue; memoryId=[string]$memoryId; agentId=$agentIdValue; sessionId=$sessionIdValue; updatedAt=$updatedAt; source='checkpoint-writer.ps1' } }
  }
  $taskMemoryLinks = @($taskMemoryLinks | Sort-Object taskId,memoryId,updatedAt -Unique)
  Write-JsonUtf8NoBom $taskMemoryPath ([pscustomobject]@{ schema='super-brain.task-memory-links.v1'; updatedAt=$updatedAt; links=@($taskMemoryLinks) }) 10
}

switch ($Action) {
  'Get' {
    $current = Read-Checkpoint
    if ($Json) {
      if ($null -eq $current) { 'null' } else { $current | ConvertTo-Json -Depth 8 }
    } else {
      if ($null -eq $current) { Write-Host 'CHECKPOINT none' } else { Write-Host "CHECKPOINT status=$($current.status) taskId=$($current.taskId) step=$($current.currentStep)" }
    }
    exit 0
  }
  'Clear' {
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
    if ($Json) { [pscustomobject]@{ ok=$true; action='Clear'; path=$path } | ConvertTo-Json -Depth 6 } else { Write-Host "CHECKPOINT_CLEARED path=$path" }
    exit 0
  }
  'Start' {
    if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = 'task-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    $checkpoint = [pscustomobject]@{
      ok = $true
      action = 'Start'
      taskId = $TaskId
      taskName = Limit-Text $TaskName 120
      sessionId = $SessionId
      sessionName = Limit-Text $SessionName 120
      agent = $Agent
      agentId = Get-DefaultAgentId $Platform $Agent
      platform = $Platform
      timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      status = if ([string]::IsNullOrWhiteSpace($Status)) { 'active' } else { $Status }
      source = Limit-Text $Source 120
      goal = Limit-Text $Goal 180
      currentPhase = Limit-Text $CurrentPhase 120
      completedSteps = @(Limit-List $CompletedSteps 12 160)
      pendingSteps = @(Limit-List $PendingSteps 12 160)
      currentStep = Limit-Text $CurrentStep 160
      blockers = @(Limit-List $Blockers 8 160)
      nextAction = Limit-Text $NextAction 220
      changedFiles = @(Limit-List $ChangedFiles 12 180)
      verificationCommands = @(Limit-List $VerificationCommands 8 180)
      verificationResults = @(Limit-List $VerificationResults 8 180)
      waitingForUser = [bool]$WaitingForUser
      evidence = @(Limit-List $Evidence 8 160)
      memoryIds = @(Limit-List $MemoryIds 12 160)
      acceptedConstraints = @(Limit-List $AcceptedConstraints 8 160)
      constraintSources = @(Limit-List $ConstraintSources 8 160)
      preflightId = Limit-Text $PreflightId 120
      guardHash = Limit-Text $GuardHash 120
    }
    Write-JsonUtf8NoBom $path $checkpoint 8
    Write-SharedTaskIdentity $checkpoint 'Start'
    if ($Json) { $checkpoint | ConvertTo-Json -Depth 8 } else { Write-Host "CHECKPOINT_STARTED taskId=$TaskId step=$CurrentStep" }
    exit 0
  }
  'Complete' {
    $current = Read-Checkpoint
    $checkpoint = [pscustomobject]@{
      ok = $true
      action = 'Complete'
      taskId = if ($TaskId) { $TaskId } elseif ($current) { $current.taskId } else { '' }
      taskName = if ($TaskName) { Limit-Text $TaskName 120 } elseif ($current) { [string]$current.taskName } else { '' }
      sessionId = if ($SessionId) { $SessionId } elseif ($current) { $current.sessionId } else { '' }
      sessionName = if ($SessionName) { Limit-Text $SessionName 120 } elseif ($current) { [string]$current.sessionName } else { '' }
      agent = if ($Agent) { $Agent } elseif ($current) { $current.agent } else { 'super-memory-brain' }
      agentId = if ($AgentId) { Get-IdentitySafeName $AgentId 'agentid-default' } elseif ($current -and $current.agentId) { [string]$current.agentId } else { Get-DefaultAgentId $Platform $Agent }
      platform = if ($Platform) { $Platform } elseif ($current) { $current.platform } else { 'zcode' }
      timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      status = 'completed'
      source = if ($Source) { Limit-Text $Source 120 } elseif ($current) { Limit-Text ([string]$current.source) 120 } else { '' }
      goal = if ($Goal) { Limit-Text $Goal 180 } elseif ($current) { Limit-Text ([string]$current.goal) 180 } else { '' }
      currentPhase = if ($CurrentPhase) { Limit-Text $CurrentPhase 120 } elseif ($current) { Limit-Text ([string]$current.currentPhase) 120 } else { '' }
      completedSteps = if ($CompletedSteps.Count -gt 0) { @(Limit-List $CompletedSteps 12 160) } elseif ($current) { @($current.completedSteps) } else { @() }
      pendingSteps = if ($PendingSteps.Count -gt 0) { @(Limit-List $PendingSteps 12 160) } elseif ($current) { @($current.pendingSteps) } else { @() }
      currentStep = Limit-Text $CurrentStep 160
      blockers = @(Limit-List $Blockers 8 160)
      nextAction = Limit-Text $NextAction 220
      changedFiles = if ($ChangedFiles.Count -gt 0) { @(Limit-List $ChangedFiles 12 180) } elseif ($current) { @($current.changedFiles) } else { @() }
      verificationCommands = if ($VerificationCommands.Count -gt 0) { @(Limit-List $VerificationCommands 8 180) } elseif ($current) { @($current.verificationCommands) } else { @() }
      verificationResults = if ($VerificationResults.Count -gt 0) { @(Limit-List $VerificationResults 8 180) } else { @() }
      waitingForUser = [bool]$WaitingForUser
      evidence = @(Limit-List $Evidence 8 160)
      memoryIds = if ($MemoryIds.Count -gt 0) { @(Limit-List $MemoryIds 12 160) } elseif ($current) { @($current.memoryIds) } else { @() }
      acceptedConstraints = if ($AcceptedConstraints.Count -gt 0) { @(Limit-List $AcceptedConstraints 8 160) } elseif ($current) { @($current.acceptedConstraints) } else { @() }
      constraintSources = if ($ConstraintSources.Count -gt 0) { @(Limit-List $ConstraintSources 8 160) } elseif ($current) { @($current.constraintSources) } else { @() }
      preflightId = if ($PreflightId) { Limit-Text $PreflightId 120 } elseif ($current) { Limit-Text ([string]$current.preflightId) 120 } else { '' }
      guardHash = if ($GuardHash) { Limit-Text $GuardHash 120 } elseif ($current) { Limit-Text ([string]$current.guardHash) 120 } else { '' }
      supersedes = if ($current) { $current.taskId } else { '' }
    }
    Write-JsonUtf8NoBom (Join-Path $workspace 'last-completed-checkpoint.json') $checkpoint 8
    Write-SharedTaskIdentity $checkpoint 'Complete'
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
    if ($Json) { $checkpoint | ConvertTo-Json -Depth 8 } else { Write-Host "CHECKPOINT_COMPLETED taskId=$($checkpoint.taskId)" }
    exit 0
  }
}
