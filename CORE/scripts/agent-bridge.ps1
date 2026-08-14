param(
  [ValidateSet('Open','Send','Receive','Heartbeat','Failover','Adopt','Close','Status')]
  [string]$Action = 'Status',
  [string]$BridgeId = '',
  [string]$TaskId = '',
  [string]$Mode = 'commander',
  [string]$Commander = 'super-memory-brain',
  [string]$LeadAgent = '',
  [string]$Sender = '',
  [string]$Receiver = '',
  [string]$Intent = '',
  [string]$Summary = '',
  [string[]]$Evidence = @(),
  [string[]]$Blockers = @(),
  [string]$NextAction = '',
  [string]$Status = 'open',
  [string]$TaskBrief = '',
  [string]$Goal = '',
  [string[]]$Participants = @(),
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$bridgeRoot = Join-Path $workspace 'agent-bridge'
$statePath = Join-Path $bridgeRoot 'bridge-state.json'
$logPath = Join-Path $bridgeRoot 'bridge-log.jsonl'
$heartbeatPath = Join-Path $bridgeRoot 'bridge-heartbeat.json'
$archiveRoot = Join-Path $bridgeRoot 'archive'
if (-not (Test-Path $bridgeRoot)) { New-Item -ItemType Directory -Force -Path $bridgeRoot,$archiveRoot | Out-Null }

function Limit-Text([string]$Text, [int]$Max = 320) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ($Text -replace '\s+', ' ').Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}
function Limit-List([string[]]$Items, [int]$MaxItems = 12, [int]$MaxChars = 180) {
  return @(@($Items) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First $MaxItems | ForEach-Object { Limit-Text ([string]$_) $MaxChars })
}
function New-BridgeId { return 'bridge-' + ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')) }
function Read-State {
  if (Test-Path -LiteralPath $statePath) {
    try { return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  return $null
}
function Write-State($State) { Write-JsonUtf8NoBom $statePath $State 12 }
function Append-Event($Event) { Add-Utf8LineLocked $logPath ($Event | ConvertTo-Json -Depth 12 -Compress) }
function Ensure-Open($State) { if (-not $State) { throw 'No active bridge session. Open first.' } return $State }
function Touch-Heartbeat($State) {
  $hb = [pscustomobject]@{
    bridgeId = $State.bridgeId
    taskId = $State.taskId
    commander = $State.commander
    leadAgent = $State.leadAgent
    status = $State.status
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    lastSender = $State.lastSender
    lastReceiver = $State.lastReceiver
    failoverCount = $State.failoverCount
  }
  Write-JsonUtf8NoBom $heartbeatPath $hb 8
  return $hb
}
function New-MessageCard([string]$Sender, [string]$Receiver, [string]$Intent, [string]$Summary, [string[]]$Evidence, [string[]]$Blockers, [string]$NextAction, [string]$Status) {
  return [pscustomobject]@{
    sender = Limit-Text $Sender 80
    receiver = Limit-Text $Receiver 80
    intent = Limit-Text $Intent 80
    summary = Limit-Text $Summary 360
    evidence = @(Limit-List $Evidence 12 180)
    blockers = @(Limit-List $Blockers 8 180)
    nextAction = Limit-Text $NextAction 220
    status = Limit-Text $Status 40
    timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  }
}
function New-State([string]$BridgeId,[string]$TaskId,[string]$Mode,[string]$Commander,[string]$LeadAgent,[string[]]$Participants,[string]$TaskBrief,[string]$Goal) {
  return [pscustomobject]@{
    ok = $true
    bridgeId = $BridgeId
    taskId = $TaskId
    mode = $Mode
    commander = $Commander
    leadAgent = $LeadAgent
    participants = @($Participants)
    taskBrief = Limit-Text $TaskBrief 600
    goal = Limit-Text $Goal 360
    status = 'open'
    currentOwner = if ([string]::IsNullOrWhiteSpace($LeadAgent)) { $Commander } else { $LeadAgent }
    createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    lastSender = $Commander
    lastReceiver = $LeadAgent
    messageCount = 0
    failoverCount = 0
    staleAgents = @()
    adopted = $false
    history = @()
    notes = 'Bridge state is isolated to memory/workspace/agent-bridge and does not write shared memory unless explicitly adopted.'
  }
}

$state = Read-State
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$result = $null

switch ($Action) {
  'Open' {
    if ([string]::IsNullOrWhiteSpace($BridgeId)) { $BridgeId = New-BridgeId }
    $state = New-State $BridgeId $TaskId $Mode $Commander $LeadAgent $Participants $TaskBrief $Goal
    $state.history = @()
    $state.currentOwner = if ([string]::IsNullOrWhiteSpace($LeadAgent)) { $Commander } else { $LeadAgent }
    $state.updatedAt = $now
    Write-State $state
    $result = $state
  }
  'Send' {
    $state = Ensure-Open $state
    $state.lastSender = if ([string]::IsNullOrWhiteSpace($Sender)) { $Commander } else { $Sender }
    $state.lastReceiver = if ([string]::IsNullOrWhiteSpace($Receiver)) { $state.currentOwner } else { $Receiver }
    $state.messageCount = [int]$state.messageCount + 1
    $card = New-MessageCard $state.lastSender $state.lastReceiver $Intent $Summary $Evidence $Blockers $NextAction $Status
    $state.history = @(@($state.history) + @($card))
    $state.updatedAt = $now
    Write-State $state
    $result = $card
  }
  'Receive' {
    $state = Ensure-Open $state
    $state.lastReceiver = if ([string]::IsNullOrWhiteSpace($Receiver)) { $state.currentOwner } else { $Receiver }
    $state.status = 'waiting'
    $state.updatedAt = $now
    Write-State $state
    $result = [pscustomobject]@{ ok=$true; bridgeId=$state.bridgeId; taskId=$state.taskId; status=$state.status; history=@($state.history | Select-Object -Last 1) }
  }
  'Heartbeat' {
    $state = Ensure-Open $state
    $state.updatedAt = $now
    Write-State $state
    $result = Touch-Heartbeat $state
  }
  'Failover' {
    $state = Ensure-Open $state
    $failed = if (-not [string]::IsNullOrWhiteSpace($Receiver)) { $Receiver } elseif (-not [string]::IsNullOrWhiteSpace($Sender)) { $Sender } else { $state.currentOwner }
    $state.staleAgents = @(@($state.staleAgents) + @($failed) | Select-Object -Unique)
    $state.failoverCount = [int]$state.failoverCount + 1
    if (-not [string]::IsNullOrWhiteSpace($LeadAgent)) { $state.currentOwner = $LeadAgent }
    $state.status = 'open'
    $state.updatedAt = $now
    $card = New-MessageCard $Commander $state.currentOwner 'failover' "Failover from $failed to $($state.currentOwner)." $Evidence $Blockers $NextAction 'open'
    $state.history = @(@($state.history) + @($card))
    Write-State $state
    $result = [pscustomobject]@{ ok=$true; bridgeId=$state.bridgeId; taskId=$state.taskId; currentOwner=$state.currentOwner; staleAgents=@($state.staleAgents); failoverCount=$state.failoverCount; note='Failover packet prepared for new agent or new conversation.' }
  }
  'Adopt' {
    $state = Ensure-Open $state
    $state.adopted = $true
    $state.status = 'done'
    $state.updatedAt = $now
    $state.history = @(@($state.history) + @(New-MessageCard $Commander $Commander 'adopt' $Summary $Evidence $Blockers $NextAction 'done'))
    Write-State $state
    $result = [pscustomobject]@{ ok=$true; bridgeId=$state.bridgeId; taskId=$state.taskId; adopted=$true; note='Bridge result marked as authoritative only by Commander adoption.' }
  }
  'Close' {
    $state = Ensure-Open $state
    $archivePath = Join-Path $archiveRoot ($state.bridgeId + '.json')
    Write-JsonUtf8NoBom $archivePath $state 12
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    $closed = [pscustomobject]@{ ok=$true; bridgeId=$state.bridgeId; taskId=$state.taskId; archived=$archivePath; closedAt=$now }
    $result = $closed
  }
  'Status' {
    if ($state) { $result = $state } else { $result = [pscustomobject]@{ ok=$true; bridgeId=''; status='idle'; note='No active bridge session.' } }
  }
}

if ($null -ne $result) {
  $event = [pscustomobject]@{
    action = $Action
    bridgeId = if ($state) { $state.bridgeId } else { $BridgeId }
    taskId = if ($state) { $state.taskId } else { $TaskId }
    timestamp = $now
    summary = Limit-Text $Summary 260
    nextAction = Limit-Text $NextAction 180
  }
  Append-Event $event
  if ($Action -ne 'Close' -and $state) { Touch-Heartbeat $state | Out-Null }
  if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "AGENT_BRIDGE action=$Action bridgeId=$($result.bridgeId) taskId=$($result.taskId) status=$($result.status)" }
}
