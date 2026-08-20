[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = "$env:USERPROFILE\.codex",
  [string]$MemoryRoot = '',
  [string]$McpName = 'super-memory-brain',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root }
$CodexHome = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexHome))
$runtimeCli = Join-Path $Root 'runtime\brain_cli.py'
$healthRaw = @(& python $runtimeCli --package-root $Root --memory-root $MemoryRoot health 2>$null)
$health = $null
try { $health = (($healthRaw -join "`n") | ConvertFrom-Json) } catch {}

$knownRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
$known = Get-ChildItem -LiteralPath $knownRoot -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notlike '*WindowsApps*' } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
$codex = if ($known) { [pscustomobject]@{ Source=$known.FullName } } else { Get-Command codex.exe -ErrorAction SilentlyContinue }
if (-not $codex) { $codex = Get-Command codex -ErrorAction SilentlyContinue }
$mcp = $null
if ($codex) {
  $previousCodexHome = $env:CODEX_HOME
  try {
    # The CLI reads CODEX_HOME, so status must inspect the requested target rather than the host default.
    $env:CODEX_HOME = $CodexHome
    $mcpRaw = @(& $codex.Source mcp get $McpName --json 2>$null)
    $mcpExitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previousCodexHome) { $env:CODEX_HOME = $null } else { $env:CODEX_HOME = $previousCodexHome }
  }
  if ($mcpExitCode -eq 0) { try { $mcp = (($mcpRaw -join "`n") | ConvertFrom-Json) } catch {} }
}

function Get-McpTransportValue([object]$Registered,[string]$Name) {
  if (-not $Registered -or -not $Registered.transport) { return '' }
  if ($Registered.transport.env -and $Registered.transport.env.PSObject.Properties[$Name]) { return [string]$Registered.transport.env.$Name }
  $args = @($Registered.transport.args)
  for ($index = 0; $index -lt ($args.Count - 1); $index++) {
    if ([string]$args[$index] -eq $Name) { return [string]$args[$index + 1] }
  }
  return ''
}

$expectedIdentity = Get-SuperBrainMcpRuntimeIdentity $Root
$bindingPath = Join-Path (Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace') 'runtime-state\mcp-runtime-binding.json'
$binding = $null
try { if (Test-Path -LiteralPath $bindingPath -PathType Leaf) { $binding = Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
$registeredIdentity = Get-McpTransportValue $mcp 'SUPER_BRAIN_RUNTIME_IDENTITY'
$registeredTransport = Get-McpTransportValue $mcp 'SUPER_BRAIN_MCP_TRANSPORT'
$registeredEpoch = Get-McpTransportValue $mcp 'SUPER_BRAIN_MCP_REGISTRATION_EPOCH'
$staticMcpOk = ($null -ne $mcp -and $registeredIdentity -eq $expectedIdentity -and $registeredTransport -eq 'codex_registered_v1' -and -not [string]::IsNullOrWhiteSpace($registeredEpoch))
$bindingOk = ($binding -and [string]$binding.schema -eq 'super-brain.mcp-runtime-binding.v1' -and [string]$binding.runtimeIdentity -eq $expectedIdentity -and [string]$binding.registrationEpoch -eq $registeredEpoch)
$handshake = if ($binding -and $binding.liveHandshake) { $binding.liveHandshake } else { $null }
$recordedHandshakeOk = ($bindingOk -and $handshake -and [string]$handshake.schema -eq 'super-brain.mcp-live-handshake.v1' -and [string]$handshake.registrationEpoch -eq $registeredEpoch -and [string]$handshake.runtimeIdentity -eq $expectedIdentity -and [string]$handshake.transport -eq 'codex_registered_mcp_stdio')

$result = [pscustomobject]@{
  # ``ok`` here is explicitly static/CLI health, never a claim that the
  # currently resident Codex MCP has answered a live status request.
  ok = ($health -and $health.ok -eq $true -and $staticMcpOk -and $bindingOk)
  staticOk = ($health -and $health.ok -eq $true -and $staticMcpOk -and $bindingOk)
  runtimeReady = ($health -and $health.ok -eq $true)
  taskStateInitialized = [bool]($health -and $health.status -and [string]$health.status.stateTrust -ne 'unknown')
  taskStateTrust = if ($health -and $health.status) { [string]$health.status.stateTrust } else { 'unavailable' }
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  runtimeHealth = $health
  mcpRegistered = ($null -ne $mcp)
  mcpStaticConfig = [pscustomobject]@{ state=if($staticMcpOk){'configured_current'}else{'stale_or_missing'}; runtimeIdentityMatches=($registeredIdentity -eq $expectedIdentity); transportMatches=($registeredTransport -eq 'codex_registered_v1'); registrationEpochPresent=(-not [string]::IsNullOrWhiteSpace($registeredEpoch)) }
  recordedLiveHandshake = [pscustomobject]@{ state=if($recordedHandshakeOk){'recorded_current'}elseif($bindingOk){'restart_required'}else{'missing_or_invalid'}; realtimeProcessVerified=$false }
  mcpExecutionReady = $false
  mcpExecutionState = 'runtime_probe_required'
  mcpExecutionProbe = 'Call the registered MCP brain_status; require runtimeIdentity.state=current and liveMcpHandshake.state=current.'
  mcpName = $McpName
  mcp = $mcp
  codexHome = [IO.Path]::GetFullPath($CodexHome)
}
if ($Json) { $result | ConvertTo-Json -Depth 10 } else {
  Write-Host "RUNTIME_STATUS staticOk=$($result.staticOk) mcpExecution=$($result.mcpExecutionState) health=$($health.ok)"
}
if (-not $result.ok) { exit 1 }
exit 0
