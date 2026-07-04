param(
  [ValidateSet('Create','Status')]
  [string]$Action = 'Create',
  [string]$BridgeId = '',
  [string]$TargetAgent = '',
  [string]$TargetHost = 'generic',
  [ValidateSet('handoff','failover','new-session','verify')]
  [string]$DispatchKind = 'handoff',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$bridgeRoot = Join-Path $workspace 'agent-bridge'
$dispatchRoot = Join-Path $bridgeRoot 'dispatch'
$statePath = Join-Path $bridgeRoot 'bridge-state.json'
$statusPath = Join-Path $bridgeRoot 'last-agent-bridge-dispatch.json'
if (-not (Test-Path $dispatchRoot)) { New-Item -ItemType Directory -Force -Path $dispatchRoot | Out-Null }

function Limit-Text([string]$Text, [int]$Max = 900) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $value = ($Text -replace '\s+', ' ').Trim()
  if ($value.Length -gt $Max) { return $value.Substring(0, $Max) + '...' }
  return $value
}
function Read-Json($Path) { if (Test-Path -LiteralPath $Path) { try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }; return $null }
function Last-Cards($State, [int]$Count = 5) { return @($State.history | Select-Object -Last $Count | ForEach-Object { [pscustomobject]@{ sender=$_.sender; receiver=$_.receiver; intent=$_.intent; summary=$_.summary; evidence=$_.evidence; blockers=$_.blockers; nextAction=$_.nextAction; status=$_.status; timestamp=$_.timestamp } }) }
function Get-LastNextAction($State) {
  $cards = @($State.history)
  if ($cards.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$cards[-1].nextAction)) { return [string]$cards[-1].nextAction }
  if (-not [string]::IsNullOrWhiteSpace([string]$State.nextAction)) { return [string]$State.nextAction }
  return 'Continue from the task brief and return a compact evidence card.'
}
function Get-RecentBlockers($State) {
  $items = @()
  foreach ($card in @($State.history | Select-Object -Last 5)) { $items += @($card.blockers) }
  return @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 12)
}
function New-CommandHint([string]$HostName, [string]$Path) {
  if ($HostName -eq 'zcode') { return "Open a new ZCode session and paste/use the handoff prompt from $Path." }
  if ($HostName -eq 'codex') { return "Open a new Codex session and paste/use the handoff prompt from $Path." }
  return "Provide the handoff prompt from $Path to the selected agent/session."
}

$state = Read-Json $statePath
if (-not $state -and $Action -eq 'Create') { throw 'No active agent bridge state. Open a bridge session first.' }
if ($state -and [string]::IsNullOrWhiteSpace($BridgeId)) { $BridgeId = [string]$state.bridgeId }
if ($state -and [string]::IsNullOrWhiteSpace($TargetAgent)) { $TargetAgent = [string]$state.currentOwner }
$now = Get-Date

if ($Action -eq 'Status') {
  $files = @(Get-ChildItem -LiteralPath $dispatchRoot -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
  $result = [pscustomobject]@{ ok=$true; version=[string]$manifest.version; bridgeId=$BridgeId; dispatchCount=$files.Count; recent=@($files | ForEach-Object { $_.FullName }); statusPath=$statusPath }
} else {
  $dispatchId = 'dispatch-' + $now.ToUniversalTime().ToString('yyyyMMddHHmmssfff')
  $recentCardsJson = (Last-Cards $state 5 | ConvertTo-Json -Depth 8)
  $nextAction = Get-LastNextAction $state
  $handoffPrompt = @"
You are receiving a Super Brain Agent Bridge task handoff.

Rules:
- Treat this as a compact task packet, not a full chat transcript.
- Continue from the nextAction; do not restart from zero.
- Keep outputs as compact evidence cards.
- Do not write authoritative shared memory unless Commander explicitly adopts your result.
- If blocked or stale, return a bridge result card so Commander can fail over.

Bridge: $($state.bridgeId)
Task: $($state.taskId)
Mode: $($state.mode)
Dispatch kind: $DispatchKind
Commander: $($state.commander)
Target agent: $TargetAgent
Goal: $($state.goal)
Task brief: $($state.taskBrief)
Current owner: $($state.currentOwner)
Status: $($state.status)
Failover count: $($state.failoverCount)
Next action: $nextAction

Recent cards:
$recentCardsJson

Respond with:
{
  "bridgeId": "$($state.bridgeId)",
  "taskId": "$($state.taskId)",
  "agent": "$TargetAgent",
  "status": "done|blocked|needs-clarification",
  "summary": "...",
  "evidence": ["..."],
  "blockers": ["..."],
  "nextAction": "..."
}
"@
  $packet = [pscustomobject]@{
    ok = $true
    dispatchId = $dispatchId
    bridgeId = [string]$state.bridgeId
    taskId = [string]$state.taskId
    kind = $DispatchKind
    targetAgent = $TargetAgent
    targetHost = $TargetHost
    createdAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
    packageVersion = [string]$manifest.version
    isolated = $true
    stateRoot = $bridgeRoot
    taskPacket = [pscustomobject]@{
      goal = $state.goal
      taskBrief = $state.taskBrief
      currentOwner = $state.currentOwner
      completedOrRecent = @(Last-Cards $state 5)
      blockers = @(Get-RecentBlockers $state)
      nextAction = $nextAction
      constraints = @('isolated bridge state only','no shared memory writes unless Commander adopts','return compact evidence card')
    }
    handoffPrompt = (Limit-Text $handoffPrompt 6000)
    commandHint = ''
    outputPath = ''
  }
  $outPath = Join-Path $dispatchRoot ($dispatchId + '.json')
  $packet.outputPath = $outPath
  $packet.commandHint = New-CommandHint $TargetHost $outPath
  Write-JsonUtf8NoBom $outPath $packet 12
  $result = $packet
}
Write-JsonUtf8NoBom $statusPath $result 12
if ($Json) { $result | ConvertTo-Json -Depth 12 } else { Write-Host "AGENT_BRIDGE_DISPATCH ok=$($result.ok) id=$($result.dispatchId) target=$TargetAgent path=$($result.outputPath)" }
exit 0
