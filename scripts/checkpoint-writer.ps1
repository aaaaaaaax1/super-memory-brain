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
  [string]$WorkspaceKey = '',
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
  [int]$ExpectedRevision = -1,
  [string]$OwnerWorkspace = '',
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
. (Join-Path $PSScriptRoot 'task-link-store.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
New-Item -ItemType Directory -Force -Path $workspace | Out-Null
$path = Join-Path $workspace 'active-checkpoint.json'
$checkpointRoot = Join-Path $workspace 'runtime-state\checkpoints'
$activeCheckpointRoot = Join-Path $checkpointRoot 'active'
$completedCheckpointRoot = Join-Path $checkpointRoot 'completed'
foreach ($dir in @($checkpointRoot,$activeCheckpointRoot,$completedCheckpointRoot)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
# Shared identity index paths: memory/shared/agents, memory/shared/sessions, memory/shared/tasks, memory/shared/links.

function Get-ScopedCheckpointPath([string]$Id,[string]$Lifecycle='active') {
  if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
  $root = if ($Lifecycle -eq 'completed') { $completedCheckpointRoot } else { $activeCheckpointRoot }
  return Get-SuperBrainCanonicalTaskPath $root $Id '.json'
}

function Read-JsonFile([string]$JsonPath) {
  if ([string]::IsNullOrWhiteSpace($JsonPath) -or -not (Test-Path -LiteralPath $JsonPath)) { return $null }
  try { return Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Read-Checkpoint([string]$Id='') {
  if (-not [string]::IsNullOrWhiteSpace($Id)) {
    $scoped = Read-JsonFile (Get-ScopedCheckpointPath $Id)
    if ($scoped) { return $scoped }
    $legacy = Read-JsonFile $path
    if ($legacy -and [string]$legacy.taskId -eq $Id) { return $legacy }
    return $null
  }
  $current = Read-JsonFile $path
  if ($current) { return $current }
  $latest = Get-ChildItem -LiteralPath $activeCheckpointRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) { return Read-JsonFile $latest.FullName }
  return $null
}

function Get-ActiveCheckpoints([string]$ExcludeTaskId='') {
  $items = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $activeCheckpointRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
    $item = Read-JsonFile $file.FullName
    if (-not $item -or [string]$item.status -ne 'active') { continue }
    if (-not [string]::IsNullOrWhiteSpace($ExcludeTaskId) -and [string]$item.taskId -eq $ExcludeTaskId) { continue }
    $items += $item
  }
  return @($items)
}

function Import-LegacyCheckpoint {
  $legacy = Read-JsonFile $path
  if (-not $legacy -or [string]::IsNullOrWhiteSpace([string]$legacy.taskId) -or [string]$legacy.status -ne 'active') { return }
  $scopedPath = Get-ScopedCheckpointPath ([string]$legacy.taskId)
  if (-not (Test-Path -LiteralPath $scopedPath)) {
    Write-JsonUtf8NoBom $scopedPath $legacy 10
    $null = Sync-SuperBrainTaskState ([string]$legacy.taskId) 'checkpoint' 'upsert' $scopedPath 'checkpoint-writer.ps1:legacy-import'
  }
}

function Update-CompatibilityCheckpoint([string]$ChangedTaskId,[object]$ChangedCheckpoint,[switch]$RemoveChanged) {
  $pointer = Read-JsonFile $path
  $pointerMatches = ($pointer -and [string]$pointer.taskId -eq $ChangedTaskId)
  if ($RemoveChanged) {
    if (-not $pointerMatches) { return $false }
    $replacement = @(Get-ActiveCheckpoints -ExcludeTaskId $ChangedTaskId) | Select-Object -First 1
    if ($replacement) { Write-JsonUtf8NoBom $path $replacement 10 } elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    return $true
  }
  if (-not $pointer -or $pointerMatches -or [string]$pointer.status -ne 'active') {
    Write-JsonUtf8NoBom $path $ChangedCheckpoint 10
    return $true
  }
  return $false
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

function Get-CheckpointOwner {
  $ownerAgentId = if (-not [string]::IsNullOrWhiteSpace($AgentId)) { Get-IdentitySafeName $AgentId 'agentid-default' } else { Get-DefaultAgentId $Platform $Agent }
  return Get-SuperBrainTaskStateOwnerInput $null $ownerAgentId $SessionId $Platform $OwnerWorkspace
}

function Get-TaskDirectoryForStatus([string]$StatusValue) {
  $normalized = ([string]$StatusValue).ToLowerInvariant()
  if ($normalized -in @('paused','waiting')) { return 'paused' }
  if ($normalized -eq 'blocked') { return 'blocked' }
  if ($normalized -like 'completed*' -or $normalized -eq 'verified') { return 'completed' }
  return 'active'
}

function Write-SharedTaskIdentity([object]$Checkpoint, [string]$Lifecycle) {
  $taskIdValue = [string]$Checkpoint.taskId
  if ([string]::IsNullOrWhiteSpace($taskIdValue)) { return }

  $agentName = if ($Checkpoint.agent) { [string]$Checkpoint.agent } else { $Agent }
  $platformName = if ($Checkpoint.platform) { [string]$Checkpoint.platform } else { $Platform }
  $agentIdValue = if ($Checkpoint.agentId) { Get-IdentitySafeName ([string]$Checkpoint.agentId) 'agentid-default' } else { Get-DefaultAgentId $platformName $agentName }
  $sessionIdValue = if ($Checkpoint.sessionId) { [string]$Checkpoint.sessionId } else { '' }
  $sessionNameValue = if ($Checkpoint.sessionName) { [string]$Checkpoint.sessionName } elseif ($Checkpoint.taskName) { [string]$Checkpoint.taskName } elseif ($Checkpoint.goal) { Limit-Text ([string]$Checkpoint.goal) 60 } else { '' }
  $workspaceKeyValue = if ($Checkpoint.PSObject.Properties['workspaceKey']) { [string]$Checkpoint.workspaceKey } else { '' }
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
    else { $taskIds = @($taskIds | Where-Object { [string]$_ -ne $taskIdValue }) }
    $taskIds = @($taskIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    $sessionCard = [pscustomobject]@{
      schema = 'super-brain.session-card.v1'
      sessionId = $sessionIdValue
      sessionName = $sessionNameValue
      agentId = $agentIdValue
      agentName = $agentName
      platform = $platformName
      workspaceKey = $workspaceKeyValue
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
  $taskCardPath = Get-SuperBrainCanonicalTaskPath $taskDir $taskIdValue '.task.json'
  $taskCard = [pscustomobject]@{
    schema = 'super-brain.task-card.v1'
    taskId = $taskIdValue
    taskName = $taskNameValue
    agentId = $agentIdValue
    agentName = $agentName
    platform = $platformName
    workspaceKey = $workspaceKeyValue
    workspace = if ($Checkpoint.PSObject.Properties['workspace']) { [string]$Checkpoint.workspace } else { '' }
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
  $null = Commit-SuperBrainTaskState $taskIdValue 'task_card' $taskCard $taskCardPath 'checkpoint-writer.ps1:task-card'

  foreach ($other in @('active','paused','blocked','completed')) {
    if ($other -eq $taskDirName) { continue }
    $otherPath = Get-SuperBrainCanonicalTaskPath (Join-Path $tasksRoot $other) $taskIdValue '.task.json'
    if (Test-Path -LiteralPath $otherPath) { Remove-Item -LiteralPath $otherPath -Force -ErrorAction SilentlyContinue }
  }

  $sessionTaskPath = Join-Path $linksDir 'session-task-links.json'
  $taskMemoryPath = Join-Path $linksDir 'task-memory-links.json'
  $linkPolicy = Get-SuperBrainTaskLinkPolicy $Root
  $sessionLink = [pscustomobject]@{ sessionId=$sessionIdValue; sessionName=$sessionNameValue; agentId=$agentIdValue; platform=$platformName; workspaceKey=$workspaceKeyValue; taskId=$taskIdValue; status=$statusValue; updatedAt=$updatedAt; source='checkpoint-writer.ps1' }
  $null = Update-SuperBrainTaskLinkFile -Path $sessionTaskPath -Schema 'super-brain.session-task-links.v1' -Kind 'session-task' -Incoming @($sessionLink) -MaxItems $linkPolicy.maxSessionTaskLinks -CompletedRetentionDays $linkPolicy.completedRetentionDays -UpdatedAt $updatedAt

  $taskMemoryLinks = @()
  foreach ($memoryId in @($Checkpoint.memoryIds)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$memoryId)) { $taskMemoryLinks += [pscustomobject]@{ taskId=$taskIdValue; memoryId=[string]$memoryId; agentId=$agentIdValue; sessionId=$sessionIdValue; updatedAt=$updatedAt; source='checkpoint-writer.ps1' } }
  }
  $null = Update-SuperBrainTaskLinkFile -Path $taskMemoryPath -Schema 'super-brain.task-memory-links.v1' -Kind 'task-memory' -Incoming @($taskMemoryLinks) -MaxItems $linkPolicy.maxTaskMemoryLinks -CompletedRetentionDays $linkPolicy.completedRetentionDays -UpdatedAt $updatedAt
  return $taskCardPath
}

Import-LegacyCheckpoint

switch ($Action) {
  'Get' {
    $current = Read-Checkpoint $TaskId
    if ($Json) {
      if ($null -eq $current) { 'null' } else { $current | ConvertTo-Json -Depth 8 }
    } else {
      if ($null -eq $current) { Write-Host 'CHECKPOINT none' } else { Write-Host "CHECKPOINT status=$($current.status) taskId=$($current.taskId) step=$($current.currentStep)" }
    }
    exit 0
  }
  'Clear' {
    $current = Read-Checkpoint $TaskId
    $targetTaskId = if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $TaskId } elseif ($current) { [string]$current.taskId } else { '' }
    $scopedPath = Get-ScopedCheckpointPath $targetTaskId
    $owner = Get-CheckpointOwner
    if (-not [string]::IsNullOrWhiteSpace($targetTaskId)) { $null = Clear-SuperBrainTaskState -TaskId $targetTaskId -EntityKind checkpoint -EntityPath $scopedPath -Source 'checkpoint-writer.ps1:clear' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $owner.workspace -OwnerAgentId $owner.agentId -OwnerSessionId $owner.sessionId -OwnerPlatform $owner.platform }
    $pointerChanged = if ([string]::IsNullOrWhiteSpace($targetTaskId)) { $false } else { Update-CompatibilityCheckpoint -ChangedTaskId $targetTaskId -ChangedCheckpoint $null -RemoveChanged }
    $result = [pscustomobject]@{ ok=$true; action='Clear'; taskId=$targetTaskId; scopedPath=$scopedPath; compatibilityPath=$path; compatibilityPointerChanged=$pointerChanged }
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-Host "CHECKPOINT_CLEARED taskId=$targetTaskId path=$scopedPath" }
    exit 0
  }
  'Start' {
    if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = 'task-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + ([guid]::NewGuid().ToString('n').Substring(0,6)) }
    $WorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
    $owner = Get-CheckpointOwner
    $checkpoint = [pscustomobject]@{
      ok = $true
      action = 'Start'
      taskId = $TaskId
      taskName = Limit-Text $TaskName 120
      sessionId = $owner.sessionId
      sessionName = Limit-Text $SessionName 120
      agent = $Agent
      agentId = $owner.agentId
      platform = $owner.platform
      workspace = $owner.workspace
      workspaceKey = $WorkspaceKey
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
    $scopedPath = Get-ScopedCheckpointPath $TaskId
    $null = Commit-SuperBrainTaskState -TaskId $TaskId -EntityKind checkpoint -EntityValue $checkpoint -EntityPath $scopedPath -Source 'checkpoint-writer.ps1:start' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $owner.workspace -OwnerAgentId $owner.agentId -OwnerSessionId $owner.sessionId -OwnerPlatform $owner.platform
    $pointerChanged = Update-CompatibilityCheckpoint -ChangedTaskId $TaskId -ChangedCheckpoint $checkpoint
    $taskCardPath = Write-SharedTaskIdentity $checkpoint 'Start'
    $checkpoint | Add-Member -NotePropertyName scopedPath -NotePropertyValue $scopedPath -Force
    $checkpoint | Add-Member -NotePropertyName compatibilityPath -NotePropertyValue $path -Force
    $checkpoint | Add-Member -NotePropertyName compatibilityPointerChanged -NotePropertyValue $pointerChanged -Force
    if ($Json) { $checkpoint | ConvertTo-Json -Depth 8 } else { Write-Host "CHECKPOINT_STARTED taskId=$TaskId step=$CurrentStep path=$scopedPath" }
    exit 0
  }
  'Complete' {
    $current = Read-Checkpoint $TaskId
    if (-not $current) {
      $requested = if ([string]::IsNullOrWhiteSpace($TaskId)) { '<current>' } else { $TaskId }
      throw "CHECKPOINT_TASK_NOT_ACTIVE: $requested"
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskId) -and [string]$current.taskId -ne $TaskId) { throw "CHECKPOINT_TASK_MISMATCH: requested=$TaskId active=$($current.taskId)" }
    $resolvedTaskId = [string]$current.taskId
    $owner = Get-CheckpointOwner
    $checkpoint = [pscustomobject]@{
      ok = $true
      action = 'Complete'
      taskId = $resolvedTaskId
      taskName = if ($TaskName) { Limit-Text $TaskName 120 } elseif ($current) { [string]$current.taskName } else { '' }
      sessionId = $owner.sessionId
      sessionName = if ($SessionName) { Limit-Text $SessionName 120 } elseif ($current) { [string]$current.sessionName } else { '' }
      agent = if ($PSBoundParameters.ContainsKey('Agent')) { $Agent } elseif ($current) { $current.agent } else { 'super-memory-brain' }
      agentId = $owner.agentId
      platform = $owner.platform
      workspace = $owner.workspace
      workspaceKey = if ($WorkspaceKey) { Get-SuperBrainWorkspaceKey $WorkspaceKey } elseif ($current -and $current.PSObject.Properties['workspaceKey']) { [string]$current.workspaceKey } else { Get-SuperBrainWorkspaceKey }
      timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      status = 'completed'
      source = if ($Source) { Limit-Text $Source 120 } elseif ($current) { Limit-Text ([string]$current.source) 120 } else { '' }
      goal = if ($Goal) { Limit-Text $Goal 180 } elseif ($current) { Limit-Text ([string]$current.goal) 180 } else { '' }
      currentPhase = if ($CurrentPhase) { Limit-Text $CurrentPhase 120 } elseif ($current) { Limit-Text ([string]$current.currentPhase) 120 } else { '' }
      completedSteps = if ($CompletedSteps.Count -gt 0) { @(Limit-List $CompletedSteps 12 160) } elseif ($current) { @($current.completedSteps) } else { @() }
      pendingSteps = @()
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
      supersedes = $resolvedTaskId
    }
    $completedScopedPath = Get-ScopedCheckpointPath $resolvedTaskId 'completed'
    $null = Commit-SuperBrainTaskState -TaskId $resolvedTaskId -EntityKind checkpoint -EntityValue $checkpoint -EntityPath $completedScopedPath -Source 'checkpoint-writer.ps1:complete' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $owner.workspace -OwnerAgentId $owner.agentId -OwnerSessionId $owner.sessionId -OwnerPlatform $owner.platform
    Write-JsonUtf8NoBom (Join-Path $workspace 'last-completed-checkpoint.json') $checkpoint 8
    $taskCardPath = Write-SharedTaskIdentity $checkpoint 'Complete'
    $activeScopedPath = Get-ScopedCheckpointPath $resolvedTaskId
    if (Test-Path -LiteralPath $activeScopedPath) { Remove-Item -LiteralPath $activeScopedPath -Force }
    $pointerChanged = Update-CompatibilityCheckpoint -ChangedTaskId $resolvedTaskId -ChangedCheckpoint $null -RemoveChanged
    $checkpoint | Add-Member -NotePropertyName scopedPath -NotePropertyValue $completedScopedPath -Force
    $checkpoint | Add-Member -NotePropertyName compatibilityPath -NotePropertyValue $path -Force
    $checkpoint | Add-Member -NotePropertyName compatibilityPointerChanged -NotePropertyValue $pointerChanged -Force
    if ($Json) { $checkpoint | ConvertTo-Json -Depth 8 } else { Write-Host "CHECKPOINT_COMPLETED taskId=$($checkpoint.taskId) path=$completedScopedPath" }
    exit 0
  }
}
