param(
  [ValidateSet('Start','Complete','Clear','Get','RefreshTaskCard')]
  [string]$Action = 'Get',
  [string]$TaskId = '',
  [string]$SessionId = '',
  [string]$Agent = 'super-memory-brain',
  [string]$AgentId = '',
  [string]$Platform = 'super-brain',
  [string]$HostAgent = '',
  [string]$HostAgentId = '',
  [string]$HostPlatform = '',
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
  [string]$ExecutionContractPath = '',
  [string]$VerificationPath = '',
  [string]$ExpectedPlanFingerprint = '',
  [int]$ExpectedContractRevision = 0,
  [string]$OwnerSessionKey = '',
  [string]$CallerSessionKey = '',
  [string]$OwnerWorkspace = '',
  [string]$Goal = '',
  [string]$CurrentPhase = '',
  [string[]]$CompletedSteps = @(),
  [string[]]$PendingSteps = @(),
  [string[]]$ChangedFiles = @(),
  [string[]]$VerificationCommands = @(),
  [string[]]$VerificationResults = @(),
  [bool]$WaitingForUser = $false,
  [switch]$MaintenanceOverride,
  [string]$MaintenanceReason = '',
  [ValidateSet('none','after_authority','after_prepare','after_materialize')]
  [string]$FaultPoint = 'none',
  [int]$FaultAfterMaterialization = 0,
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

function Get-CheckpointDecisionBinding([string]$Id,[string]$ExpectedWorkspaceKey) {
  if ([string]::IsNullOrWhiteSpace($Id)) { return [pscustomobject]@{ stageKind=''; status=''; bindingDigest='' } }
  $contractRoot = Join-Path $workspace 'runtime-state\execution-contracts'
  if (-not (Test-Path -LiteralPath $contractRoot -PathType Container)) { return [pscustomobject]@{ stageKind=''; status=''; bindingDigest='' } }
  foreach ($file in @(Get-ChildItem -LiteralPath $contractRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
    $contract = Read-JsonFile $file.FullName
    if (-not $contract -or [string]$contract.taskId -ne $Id -or [string]$contract.status -ne 'active' -or -not (Test-SuperBrainWorkspaceKey ([string]$contract.workspaceKey) $ExpectedWorkspaceKey)) { continue }
    return [pscustomobject]@{
      stageKind = if($contract.PSObject.Properties['stageKind']){Limit-Text ([string]$contract.stageKind) 24}else{''}
      status = if($contract.PSObject.Properties['decisionBinding'] -and $contract.decisionBinding){Limit-Text ([string]$contract.decisionBinding.status) 32}else{''}
      bindingDigest = if($contract.PSObject.Properties['decisionBinding'] -and $contract.decisionBinding){Limit-Text ([string]$contract.decisionBinding.bindingDigest) 64}else{''}
    }
  }
  return [pscustomobject]@{ stageKind=''; status=''; bindingDigest='' }
}

function Get-ActiveCheckpoints([string]$ExcludeTaskId='',[string]$WorkspaceKey='') {
  $items = @()
  foreach ($file in @(Get-ChildItem -LiteralPath $activeCheckpointRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
    $item = Read-JsonFile $file.FullName
    if (-not $item -or [string]$item.status -ne 'active') { continue }
    if (-not [string]::IsNullOrWhiteSpace($ExcludeTaskId) -and [string]$item.taskId -eq $ExcludeTaskId) { continue }
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceKey) -and -not (Test-SuperBrainWorkspaceKey ([string]$item.workspaceKey) $WorkspaceKey)) { continue }
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
    $pointerWorkspaceKey = if ($pointer -and $pointer.PSObject.Properties['workspaceKey']) { [string]$pointer.workspaceKey } else { '' }
    $replacement = if ([string]::IsNullOrWhiteSpace($pointerWorkspaceKey)) { @() } else { @(Get-ActiveCheckpoints -ExcludeTaskId $ChangedTaskId -WorkspaceKey $pointerWorkspaceKey) | Select-Object -First 1 }
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
  if ([string]::Equals($PlatformValue,'super-brain',[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($AgentValue,'super-memory-brain',[StringComparison]::OrdinalIgnoreCase)) { return 'super-brain-control-plane' }
  $base = if (-not [string]::IsNullOrWhiteSpace($PlatformValue)) { $PlatformValue } elseif (-not [string]::IsNullOrWhiteSpace($AgentValue)) { $AgentValue } else { 'agent' }
  return (Get-IdentitySafeName $base 'agent') + 'id-default'
}

function New-HostMetadata([object]$Existing = $null) {
  if ($Existing) { return $Existing }
  return [pscustomobject]@{
    agentName = Limit-Text $HostAgent 80
    agentId = Limit-Text $HostAgentId 120
    platform = Limit-Text $HostPlatform 80
    authority = 'metadata_only'
  }
}

function Get-CheckpointOwner {
  $ownerAgentId = if (-not [string]::IsNullOrWhiteSpace($AgentId)) { Get-IdentitySafeName $AgentId 'agentid-default' } else { Get-DefaultAgentId $Platform $Agent }
  return Get-SuperBrainTaskStateOwnerInput $null $ownerAgentId $SessionId $Platform $OwnerWorkspace
}

function Get-CheckpointCompletionOwner([object]$Current) {
  $currentAgentId = if($Current -and $Current.PSObject.Properties['agentId']){[string]$Current.agentId}else{''}
  $currentSessionId = if($Current -and $Current.PSObject.Properties['sessionId']){[string]$Current.sessionId}else{''}
  $currentPlatform = if($Current -and $Current.PSObject.Properties['platform']){[string]$Current.platform}else{''}
  $currentWorkspace = if($Current -and $Current.PSObject.Properties['workspace']){[string]$Current.workspace}else{''}
  $resolvedAgentId = if($PSBoundParameters.ContainsKey('AgentId') -and -not[string]::IsNullOrWhiteSpace($AgentId)){$AgentId}elseif($currentAgentId){$currentAgentId}else{Get-DefaultAgentId $Platform $Agent}
  $resolvedSessionId = if($PSBoundParameters.ContainsKey('SessionId') -and -not[string]::IsNullOrWhiteSpace($SessionId)){$SessionId}elseif($currentSessionId){$currentSessionId}else{$SessionId}
  $resolvedPlatform = if($PSBoundParameters.ContainsKey('Platform') -and -not[string]::IsNullOrWhiteSpace($Platform)){$Platform}elseif($currentPlatform){$currentPlatform}else{'super-brain'}
  $resolvedWorkspace = if($PSBoundParameters.ContainsKey('OwnerWorkspace') -and -not[string]::IsNullOrWhiteSpace($OwnerWorkspace)){$OwnerWorkspace}elseif($currentWorkspace){$currentWorkspace}else{$OwnerWorkspace}
  return Get-SuperBrainTaskStateOwnerInput $Current $resolvedAgentId $resolvedSessionId $resolvedPlatform $resolvedWorkspace
}

function Get-TaskDirectoryForStatus([string]$StatusValue) {
  $normalized = ([string]$StatusValue).ToLowerInvariant()
  if ($normalized -in @('paused','waiting')) { return 'paused' }
  if ($normalized -eq 'blocked') { return 'blocked' }
  if ($normalized -like 'completed*' -or $normalized -eq 'verified') { return 'completed' }
  return 'active'
}

function New-SharedTaskCardPlan([object]$Checkpoint,[string]$Lifecycle) {
  $taskIdValue = [string]$Checkpoint.taskId
  if ([string]::IsNullOrWhiteSpace($taskIdValue)) { throw 'CHECKPOINT_TASK_REQUIRED' }
  $agentName = if ($Checkpoint.agent) { [string]$Checkpoint.agent } else { $Agent }
  $platformName = if ($Checkpoint.platform) { [string]$Checkpoint.platform } else { $Platform }
  $agentIdValue = if ($Checkpoint.agentId) { Get-IdentitySafeName ([string]$Checkpoint.agentId) 'agentid-default' } else { Get-DefaultAgentId $platformName $agentName }
  $sessionIdValue = if ($Checkpoint.sessionId) { [string]$Checkpoint.sessionId } else { '' }
  $sessionNameValue = if ($Checkpoint.sessionName) { [string]$Checkpoint.sessionName } elseif ($Checkpoint.taskName) { [string]$Checkpoint.taskName } elseif ($Checkpoint.goal) { Limit-Text ([string]$Checkpoint.goal) 60 } else { '' }
  $workspaceKeyValue = if ($Checkpoint.PSObject.Properties['workspaceKey']) { [string]$Checkpoint.workspaceKey } else { '' }
  $taskNameValue = if ($Checkpoint.taskName) { [string]$Checkpoint.taskName } elseif ($Checkpoint.goal) { Limit-Text ([string]$Checkpoint.goal) 90 } else { $taskIdValue }
  $statusValue = if ($Checkpoint.status) { [string]$Checkpoint.status } else { 'active' }
  $updatedAt = if ($Checkpoint.timestamp) { [string]$Checkpoint.timestamp } elseif ($Checkpoint.updatedAt) { [string]$Checkpoint.updatedAt } else { (Get-SuperBrainUtcTimestamp) }
  $taskDirName = Get-TaskDirectoryForStatus $statusValue
  $taskCardPath = Get-SuperBrainCanonicalTaskPath (Join-Path (Join-Path $sharedRoot 'tasks') $taskDirName) $taskIdValue '.task.json'
  $taskCard = [pscustomobject]@{
    schema='super-brain.task-card.v1'; taskId=$taskIdValue; taskName=$taskNameValue; agentId=$agentIdValue; agentName=$agentName; platform=$platformName; host=(New-HostMetadata $(if($Checkpoint.PSObject.Properties['host']){$Checkpoint.host}else{$null}))
    workspaceKey=$workspaceKeyValue; workspace=if($Checkpoint.PSObject.Properties['workspace']){[string]$Checkpoint.workspace}else{''}; sessionId=$sessionIdValue; sessionName=$sessionNameValue
    status=$statusValue; goal=[string]$Checkpoint.goal; currentPhase=[string]$Checkpoint.currentPhase; currentStep=[string]$Checkpoint.currentStep; nextAction=[string]$Checkpoint.nextAction
    completedSteps=@($Checkpoint.completedSteps); pendingSteps=@($Checkpoint.pendingSteps); blockers=@($Checkpoint.blockers); waitingForUser=[bool]$Checkpoint.waitingForUser
    evidence=@($Checkpoint.evidence); memoryIds=@($Checkpoint.memoryIds); source='checkpoint-writer.ps1'; sourcePath=$taskCardPath; lifecycle=$Lifecycle; updatedAt=$updatedAt
  }
  return [pscustomobject]@{ path=$taskCardPath; value=$taskCard; directory=$taskDirName }
}

function Write-SharedTaskIdentity([object]$Checkpoint, [string]$Lifecycle, [switch]$MaintenanceOverride, [string]$MaintenanceReason = '', [switch]$SkipTaskCardState) {
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
  $updatedAt = if ($Checkpoint.timestamp) { [string]$Checkpoint.timestamp } elseif ($Checkpoint.updatedAt) { [string]$Checkpoint.updatedAt } else { (Get-SuperBrainUtcTimestamp) }

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
    sharedIndexRoot = $sharedRoot
    host = New-HostMetadata $(if($Checkpoint.PSObject.Properties['host']){$Checkpoint.host}else{$null})
    lastSeenAt = $updatedAt
    source = 'checkpoint-writer.ps1'
  }
  Write-JsonUtf8NoBom $agentCardPath $agentCard 8

  if (-not [string]::IsNullOrWhiteSpace($sessionIdValue)) {
    $sessionScopeId = Get-SuperBrainTaskWorkspaceToken $sessionIdValue $workspaceKeyValue
    $sessionCardPath = Get-SuperBrainCanonicalTaskPath $sessionsDir $sessionScopeId '.session.json'
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
      host = New-HostMetadata $(if($Checkpoint.PSObject.Properties['host']){$Checkpoint.host}else{$null})
      workspaceKey = $workspaceKeyValue
      status = if ($statusValue -in @('active','running','in_progress')) { 'active' } elseif ($statusValue -in @('paused','blocked','waiting')) { $statusValue } else { 'completed' }
      currentTaskIds = @($taskIds)
      memoryIds = @($Checkpoint.memoryIds)
      lastSeenAt = $updatedAt
      source = 'checkpoint-writer.ps1'
    }
    Write-JsonUtf8NoBom $sessionCardPath $sessionCard 8
  }

  $taskCardPlan = New-SharedTaskCardPlan $Checkpoint $Lifecycle
  $taskDirName = [string]$taskCardPlan.directory
  $taskDir = Join-Path $tasksRoot $taskDirName
  New-Item -ItemType Directory -Force -Path $taskDir | Out-Null
  $taskCardPath = [string]$taskCardPlan.path
  if (-not $SkipTaskCardState) {
    $null = Commit-SuperBrainTaskState $taskIdValue 'task_card' $taskCardPlan.value $taskCardPath 'checkpoint-writer.ps1:task-card' -MaintenanceOverride:$MaintenanceOverride -MaintenanceReason $MaintenanceReason
    foreach ($other in @('active','paused','blocked','completed')) {
      if ($other -eq $taskDirName) { continue }
      $otherPath = Get-SuperBrainCanonicalTaskPath (Join-Path $tasksRoot $other) $taskIdValue '.task.json'
      if (Test-Path -LiteralPath $otherPath) { Remove-Item -LiteralPath $otherPath -Force -ErrorAction SilentlyContinue }
    }
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

function Write-CheckpointBundleStagingValue([string]$Id,[string]$Name,[object]$Value) {
  $stageRoot = Join-Path (Join-Path $workspace 'task-state-store\staging') (Get-SuperBrainCanonicalTaskToken $Id)
  if (-not (Test-Path -LiteralPath $stageRoot)) { New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null }
  $safe = (($Name -replace '[^A-Za-z0-9._-]+','-').Trim('-')).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'value' }
  if ($safe.Length -gt 12) { $safe = $safe.Substring(0,12).TrimEnd('-') }
  $stagePath = Join-Path $stageRoot (([guid]::NewGuid().ToString('n').Substring(0,12)) + '-' + $safe + '.json')
  Write-JsonUtf8NoBom $stagePath $Value 12
  return $stagePath
}

function Get-CheckpointBundleFileHash([string]$TargetPath) {
  if ([string]::IsNullOrWhiteSpace($TargetPath) -or -not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { return '' }
  return (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash
}

function New-CheckpointBundleCommand([string]$Role,[string]$Operation,[string]$TargetPath,[string]$PayloadPath,[string]$ExpectedHash,[string]$Id,[string]$WorkspaceValue,[bool]$ApplyWhenMissing=$false,[bool]$ReplaceLegacyUnscopedPointer=$false) {
  $payloadHash = if ([string]::IsNullOrWhiteSpace($PayloadPath)) { '' } else { (Get-FileHash -LiteralPath $PayloadPath -Algorithm SHA256).Hash }
  return [pscustomobject]@{
    role=$Role; operation=$Operation; targetPath=[IO.Path]::GetFullPath($TargetPath); payloadPath=if($PayloadPath){[IO.Path]::GetFullPath($PayloadPath)}else{''}; payloadHash=$payloadHash
    expectedTargetHash=$ExpectedHash; expectedTaskId=$Id; expectedWorkspaceKey=$WorkspaceValue; applyWhenMissing=$ApplyWhenMissing; replaceLegacyUnscopedPointer=$ReplaceLegacyUnscopedPointer
  }
}

function Invoke-CheckpointActiveBundle([object]$Checkpoint,[object]$TaskCardPlan,[object]$Owner) {
  $id = [string]$Checkpoint.taskId
  $workspaceValue = [string]$Checkpoint.workspaceKey
  $expected = if ($ExpectedRevision -ge 0) { $ExpectedRevision } else { Get-SuperBrainTaskStateExpectedRevision $id }
  $stagedPaths = New-Object System.Collections.ArrayList
  $transactionInvoked = $false
  try {
    $checkpointPayloadPath = Write-CheckpointBundleStagingValue $id 'active-checkpoint' $Checkpoint
    [void]$stagedPaths.Add($checkpointPayloadPath)
    $taskCardPayloadPath = Write-CheckpointBundleStagingValue $id 'active-task-card' $TaskCardPlan.value
    [void]$stagedPaths.Add($taskCardPayloadPath)
    $commands = New-Object System.Collections.ArrayList
    $checkpointPath = Get-ScopedCheckpointPath $id
    [void]$commands.Add((New-CheckpointBundleCommand 'active_checkpoint' 'replace_if_hash' $checkpointPath $checkpointPayloadPath (Get-CheckpointBundleFileHash $checkpointPath) $id $workspaceValue))
    [void]$commands.Add((New-CheckpointBundleCommand 'active_task_card' 'replace_if_hash' ([string]$TaskCardPlan.path) $taskCardPayloadPath (Get-CheckpointBundleFileHash ([string]$TaskCardPlan.path)) $id $workspaceValue))
    [void]$commands.Add((New-CheckpointBundleCommand 'checkpoint_pointer' 'conditional_pointer' $path $checkpointPayloadPath (Get-CheckpointBundleFileHash $path) $id $workspaceValue $true ([bool]$MaintenanceOverride)))
    foreach ($lifecycle in @('active','paused','blocked')) {
      if ($lifecycle -eq [string]$TaskCardPlan.directory) { continue }
      $otherPath = Get-SuperBrainCanonicalTaskPath (Join-Path (Join-Path $sharedRoot 'tasks') $lifecycle) $id '.task.json'
      if (-not (Test-Path -LiteralPath $otherPath -PathType Leaf)) { continue }
      $other = Read-JsonFile $otherPath
      if (-not $other -or [string]$other.taskId -ne $id -or -not (Test-SuperBrainWorkspaceKey ([string]$other.workspaceKey) $workspaceValue)) { continue }
      [void]$commands.Add((New-CheckpointBundleCommand 'active_task_card_cleanup' 'delete_identity' $otherPath '' (Get-CheckpointBundleFileHash $otherPath) $id $workspaceValue))
    }
    $bundleManifest = [pscustomobject]@{
      schema='super-brain.active-task-bundle-manifest.v1'; taskId=$id; workspaceKey=$workspaceValue; packageVersion=[string](Get-SuperBrainManifest $Root).version
      expectedTaskStateRevision=$expected; commands=@($commands); source='checkpoint-writer.ps1:Start'; rawPromptStored=$false; rawTranscriptStored=$false
    }
    $manifestPath = Write-CheckpointBundleStagingValue $id 'active-bundle-manifest' $bundleManifest
    [void]$stagedPaths.Add($manifestPath)
    $transactionInvoked = $true
    return Invoke-SuperBrainTaskStateStore @{ Action='CommitActiveBundle'; TaskId=$id; ActiveBundleManifestPath=$manifestPath; Source='checkpoint-writer.ps1:Start'; WorkspaceRoot=$workspace; SharedRoot=$sharedRoot; FaultPoint=$FaultPoint; FaultAfterMaterialization=$FaultAfterMaterialization; MaintenanceOverride=[bool]$MaintenanceOverride; MaintenanceReason=$MaintenanceReason }
  } finally {
    if (-not $transactionInvoked) {
      foreach ($staged in @($stagedPaths)) { if ($staged -and (Test-Path -LiteralPath $staged -PathType Leaf)) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue } }
    }
  }
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
    $owner = Get-CheckpointCompletionOwner $current
    if (-not [string]::IsNullOrWhiteSpace($targetTaskId)) { $null = Clear-SuperBrainTaskState -TaskId $targetTaskId -EntityKind checkpoint -EntityPath $scopedPath -Source 'checkpoint-writer.ps1:clear' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $owner.workspace -OwnerAgentId $owner.agentId -OwnerSessionId $owner.sessionId -OwnerPlatform $owner.platform }
    $pointerChanged = if ([string]::IsNullOrWhiteSpace($targetTaskId)) { $false } else { Update-CompatibilityCheckpoint -ChangedTaskId $targetTaskId -ChangedCheckpoint $null -RemoveChanged }
    $result = [pscustomobject]@{ ok=$true; action='Clear'; taskId=$targetTaskId; scopedPath=$scopedPath; compatibilityPath=$path; compatibilityPointerChanged=$pointerChanged }
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-Host "CHECKPOINT_CLEARED taskId=$targetTaskId path=$scopedPath" }
    exit 0
  }
  'Start' {
    if ($MaintenanceOverride -and [string]::IsNullOrWhiteSpace($MaintenanceReason)) { throw 'CHECKPOINT_MAINTENANCE_REASON_REQUIRED' }
    if ([string]::IsNullOrWhiteSpace($TaskId)) { $TaskId = 'task-' + (Get-SuperBrainLocalNow).ToString('yyyyMMdd-HHmmssfff') + '-' + ([guid]::NewGuid().ToString('n').Substring(0,6)) }
    $WorkspaceKey = Get-SuperBrainWorkspaceKey $WorkspaceKey
    $owner = Get-CheckpointOwner
    $decisionBinding = Get-CheckpointDecisionBinding $TaskId $WorkspaceKey
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
      host = New-HostMetadata
      workspace = $owner.workspace
      workspaceKey = $WorkspaceKey
      timestamp = Get-SuperBrainUtcTimestamp
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
      stageKind = $decisionBinding.stageKind
      decisionBindingStatus = $decisionBinding.status
      decisionBindingDigest = $decisionBinding.bindingDigest
    }
    $scopedPath = Get-ScopedCheckpointPath $TaskId
    $taskCardPlan = New-SharedTaskCardPlan $checkpoint 'Start'
    $activeBundle = Invoke-CheckpointActiveBundle $checkpoint $taskCardPlan $owner
    $pointerMaterialization = @($activeBundle.materialization | Where-Object { [string]$_.role -eq 'checkpoint_pointer' } | Select-Object -First 1)
    $pointerChanged = [bool]($pointerMaterialization -and $pointerMaterialization.changed -eq $true)
    $compatibilityCheckpoint = Read-JsonFile $path
    if (-not $compatibilityCheckpoint -or [string]$compatibilityCheckpoint.taskId -ne $TaskId -or -not (Test-SuperBrainWorkspaceKey ([string]$compatibilityCheckpoint.workspaceKey) $WorkspaceKey)) {
      $pointerAction = if ($pointerMaterialization) { [string]$pointerMaterialization.action } else { 'not_materialized' }
      throw "CHECKPOINT_COMPATIBILITY_POINTER_NOT_CURRENT taskId=$TaskId action=$pointerAction"
    }
    $taskCardPath = Write-SharedTaskIdentity $checkpoint 'Start' -MaintenanceOverride:$MaintenanceOverride -MaintenanceReason $MaintenanceReason -SkipTaskCardState
    $checkpoint | Add-Member -NotePropertyName scopedPath -NotePropertyValue $scopedPath -Force
    $checkpoint | Add-Member -NotePropertyName compatibilityPath -NotePropertyValue $path -Force
    $checkpoint | Add-Member -NotePropertyName compatibilityPointerChanged -NotePropertyValue $pointerChanged -Force
    $checkpoint | Add-Member -NotePropertyName taskStateRevision -NotePropertyValue ([int]$activeBundle.revision) -Force
    $checkpoint | Add-Member -NotePropertyName taskStateTransactionId -NotePropertyValue ([string]$activeBundle.transactionId) -Force
    $checkpoint | Add-Member -NotePropertyName maintenanceOverride -NotePropertyValue ([bool]$activeBundle.maintenanceOverride) -Force
    $checkpoint | Add-Member -NotePropertyName maintenanceReason -NotePropertyValue ([string]$activeBundle.maintenanceReason) -Force
    if ($Json) { $checkpoint | ConvertTo-Json -Depth 8 } else { Write-Host "CHECKPOINT_STARTED taskId=$TaskId step=$CurrentStep path=$scopedPath" }
    exit 0
  }
  'RefreshTaskCard' {
    if ([string]::IsNullOrWhiteSpace($TaskId)) { throw 'CHECKPOINT_TASK_REQUIRED' }
    if ($MaintenanceOverride -and [string]::IsNullOrWhiteSpace($MaintenanceReason)) { throw 'CHECKPOINT_MAINTENANCE_REASON_REQUIRED' }
    $current = Read-Checkpoint $TaskId
    if (-not $current) { throw "CHECKPOINT_TASK_NOT_ACTIVE: $TaskId" }
    if ([string]$current.taskId -ne $TaskId) { throw "CHECKPOINT_TASK_MISMATCH: requested=$TaskId active=$($current.taskId)" }
    $taskCardPath = Write-SharedTaskIdentity $current 'RefreshTaskCard' -MaintenanceOverride:$MaintenanceOverride -MaintenanceReason $MaintenanceReason
    $result = [pscustomobject]@{
      ok = $true
      action = 'RefreshTaskCard'
      taskId = $TaskId
      status = [string]$current.status
      pendingStepCount = @($current.pendingSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
      taskCardPath = $taskCardPath
      source = 'checkpoint-writer.ps1:refresh-task-card'
      maintenanceOverride = [bool]$MaintenanceOverride
      maintenanceReason = if($MaintenanceOverride){Limit-Text $MaintenanceReason 180}else{''}
    }
    if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-Host "CHECKPOINT_TASK_CARD_REFRESHED taskId=$TaskId path=$taskCardPath" }
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
    $owner = Get-CheckpointCompletionOwner $current
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
      host = New-HostMetadata $(if($current -and $current.PSObject.Properties['host']){$current.host}else{$null})
      workspace = $owner.workspace
      workspaceKey = if ($WorkspaceKey) { Get-SuperBrainWorkspaceKey $WorkspaceKey } elseif ($current -and $current.PSObject.Properties['workspaceKey']) { [string]$current.workspaceKey } else { Get-SuperBrainWorkspaceKey }
      timestamp = Get-SuperBrainUtcTimestamp
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
    $taskCardPlan = New-SharedTaskCardPlan $checkpoint 'Complete'
    $completion = Complete-SuperBrainTaskState -TaskId $resolvedTaskId -WorkspaceKey ([string]$checkpoint.workspaceKey) -CompletedCheckpoint $checkpoint -CompletedTaskCard $taskCardPlan.value -ExecutionContractPath $ExecutionContractPath -VerificationPath $VerificationPath -ExpectedPlanFingerprint $ExpectedPlanFingerprint -ExpectedContractRevision $ExpectedContractRevision -OwnerSessionKey $OwnerSessionKey -CallerSessionKey $CallerSessionKey -Source 'checkpoint-writer.ps1:complete' -ExpectedRevision $ExpectedRevision -OwnerWorkspace $owner.workspace -OwnerAgentId $owner.agentId -OwnerSessionId $owner.sessionId -OwnerPlatform $owner.platform -MaintenanceOverride:$MaintenanceOverride -MaintenanceReason $MaintenanceReason -FaultPoint $FaultPoint -FaultAfterMaterialization $FaultAfterMaterialization
    $taskCardPath = Write-SharedTaskIdentity $checkpoint 'Complete' -SkipTaskCardState
    $pointerChanged = $true
    $checkpoint | Add-Member -NotePropertyName scopedPath -NotePropertyValue $completedScopedPath -Force
    $checkpoint | Add-Member -NotePropertyName compatibilityPath -NotePropertyValue $path -Force
    $checkpoint | Add-Member -NotePropertyName compatibilityPointerChanged -NotePropertyValue $pointerChanged -Force
    $checkpoint | Add-Member -NotePropertyName taskStateRevision -NotePropertyValue ([int]$completion.revision) -Force
    $checkpoint | Add-Member -NotePropertyName completionTransactionId -NotePropertyValue ([string]$completion.transactionId) -Force
    $checkpoint | Add-Member -NotePropertyName completionReceiptPath -NotePropertyValue ([string]$completion.completionReceiptPath) -Force
    $checkpoint | Add-Member -NotePropertyName completionReceiptHash -NotePropertyValue ([string]$completion.completionReceiptHash) -Force
    if ($Json) { $checkpoint | ConvertTo-Json -Depth 8 } else { Write-Host "CHECKPOINT_COMPLETED taskId=$($checkpoint.taskId) path=$completedScopedPath" }
    exit 0
  }
}
