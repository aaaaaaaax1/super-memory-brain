param(
  [ValidateSet('Init','Set','Check','Status')]
  [string]$Action = 'Status',
  [string]$Agent = '',
  [ValidateSet('reader','advisor','code-suggester','adopt-requester','commander')]
  [string]$Role = 'reader',
  [string]$Operation = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$bridgeRoot = Join-Path $workspace 'agent-bridge'
$permPath = Join-Path $bridgeRoot 'bridge-permissions.json'
$statusPath = Join-Path $bridgeRoot 'last-agent-bridge-permissions.json'
if (-not (Test-Path $bridgeRoot)) { New-Item -ItemType Directory -Force -Path $bridgeRoot | Out-Null }

function Default-Permissions {
  [pscustomobject]@{
    ok = $true
    schema = 'agent-bridge.permissions.v1'
    version = [string]$manifest.version
    updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    defaultRole = 'reader'
    roles = [pscustomobject]@{
      reader = @('read_packet','reply_summary')
      advisor = @('read_packet','reply_summary','suggest_next_action')
      'code-suggester' = @('read_packet','reply_summary','suggest_next_action','suggest_code_change')
      'adopt-requester' = @('read_packet','reply_summary','suggest_next_action','request_adopt')
      commander = @('read_packet','reply_summary','suggest_next_action','suggest_code_change','request_adopt','adopt','failover','close')
    }
    agents = [pscustomobject]@{ 'super-memory-brain' = 'commander' }
    guard = 'Only commander can adopt, failover, or close authoritative bridge outcomes. Other roles remain advisory.'
  }
}
function Read-Perms { if (Test-Path -LiteralPath $permPath) { try { return Get-Content -LiteralPath $permPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }; return Default-Permissions }
function Save-Perms($P) { $P.updatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); $P.version = [string]$manifest.version; Write-JsonUtf8NoBom $permPath $P 10 }
function Get-AgentRole($P,[string]$Name) { if ($P.agents.PSObject.Properties[$Name]) { return [string]$P.agents.$Name }; return [string]$P.defaultRole }
function Role-Ops($P,[string]$R) { if ($P.roles.PSObject.Properties[$R]) { return @($P.roles.$R) }; return @() }

$perms = Read-Perms
if ($Action -eq 'Init') {
  $perms = Default-Permissions
  Save-Perms $perms
  $result = $perms
} elseif ($Action -eq 'Set') {
  if ([string]::IsNullOrWhiteSpace($Agent)) { throw 'Agent is required for Set.' }
  $perms.agents | Add-Member -NotePropertyName $Agent -NotePropertyValue $Role -Force
  Save-Perms $perms
  $result = [pscustomobject]@{ ok=$true; action='Set'; agent=$Agent; role=$Role; permissions=@(Role-Ops $perms $Role); path=$permPath }
} elseif ($Action -eq 'Check') {
  if ([string]::IsNullOrWhiteSpace($Agent)) { throw 'Agent is required for Check.' }
  if ([string]::IsNullOrWhiteSpace($Operation)) { throw 'Operation is required for Check.' }
  $agentRole = Get-AgentRole $perms $Agent
  $ops = @(Role-Ops $perms $agentRole)
  $allowed = @($ops | Where-Object { $_ -eq $Operation }).Count -gt 0
  $result = [pscustomobject]@{ ok=$true; action='Check'; agent=$Agent; role=$agentRole; operation=$Operation; allowed=$allowed; permissions=$ops; guard=$perms.guard }
} else {
  $result = $perms
}
Write-JsonUtf8NoBom $statusPath $result 10
if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "AGENT_BRIDGE_PERMISSIONS action=$Action ok=$($result.ok) path=$statusPath" }
exit 0
