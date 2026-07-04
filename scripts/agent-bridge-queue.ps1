param(
  [ValidateSet('Enqueue','Poll','Ack','Status','Clear')]
  [string]$Action = 'Status',
  [string]$BridgeId = '',
  [string]$To = '',
  [string]$From = 'super-memory-brain',
  [string]$Intent = 'message',
  [string]$Summary = '',
  [string[]]$Evidence = @(),
  [string]$MessageId = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$bridgeRoot = Join-Path $workspace 'agent-bridge'
$queuePath = Join-Path $bridgeRoot 'bridge-queue.json'
$statusPath = Join-Path $bridgeRoot 'last-agent-bridge-queue.json'
if (-not (Test-Path $bridgeRoot)) { New-Item -ItemType Directory -Force -Path $bridgeRoot | Out-Null }

function Read-Queue { if (Test-Path -LiteralPath $queuePath) { try { return Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }; return [pscustomobject]@{ ok=$true; schema='agent-bridge.queue.v1'; version=[string]$manifest.version; updatedAt=''; messages=@() } }
function Save-Queue($Q) { $Q.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); $Q.version=[string]$manifest.version; Write-JsonUtf8NoBom $queuePath $Q 10 }
function New-MessageId { return 'msg-' + ([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')) }

$q = Read-Queue
if ($Action -eq 'Enqueue') {
  if ([string]::IsNullOrWhiteSpace($To)) { throw 'To is required for Enqueue.' }
  if ([string]::IsNullOrWhiteSpace($MessageId)) { $MessageId = New-MessageId }
  $msg = [pscustomobject]@{ messageId=$MessageId; bridgeId=$BridgeId; from=$From; to=$To; intent=$Intent; summary=$Summary; evidence=@($Evidence); status='pending'; createdAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); ackAt='' }
  $q.messages = @(@($q.messages) + @($msg))
  Save-Queue $q
  $result = $msg
} elseif ($Action -eq 'Poll') {
  $items = @($q.messages | Where-Object { ($_.status -eq 'pending') -and ([string]::IsNullOrWhiteSpace($To) -or $_.to -eq $To) })
  $result = [pscustomobject]@{ ok=$true; action='Poll'; to=$To; count=$items.Count; messages=@($items); queuePath=$queuePath }
} elseif ($Action -eq 'Ack') {
  if ([string]::IsNullOrWhiteSpace($MessageId)) { throw 'MessageId is required for Ack.' }
  foreach ($m in @($q.messages)) { if ($m.messageId -eq $MessageId) { $m.status='acked'; $m.ackAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } }
  Save-Queue $q
  $result = [pscustomobject]@{ ok=$true; action='Ack'; messageId=$MessageId; queuePath=$queuePath }
} elseif ($Action -eq 'Clear') {
  $q.messages = @()
  Save-Queue $q
  $result = [pscustomobject]@{ ok=$true; action='Clear'; queuePath=$queuePath }
} else {
  $pending = @($q.messages | Where-Object { $_.status -eq 'pending' })
  $result = [pscustomobject]@{ ok=$true; action='Status'; total=@($q.messages).Count; pending=$pending.Count; queuePath=$queuePath; updatedAt=$q.updatedAt }
}
Write-JsonUtf8NoBom $statusPath $result 10
if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "AGENT_BRIDGE_QUEUE action=$Action ok=$($result.ok) path=$statusPath" }
exit 0
