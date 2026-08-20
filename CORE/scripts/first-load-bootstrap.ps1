[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = "$env:USERPROFILE\.codex",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$MemoryRoot = '',
  [switch]$RepairMcp,
  [switch]$Force,
  [switch]$FailOnNotReady,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$CodexHome = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexHome))
$CodexSkills = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexSkills))
$MemoryRoot = Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $MemoryRoot -Operation 'first-load-bootstrap'
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statePath = Join-Path $workspace 'first-load-bootstrap.json'
$entryRoot = Join-Path $CodexSkills 'super-memory-brain'
$manifest = Get-SuperBrainManifest $Root
$mcpRuntimeIdentity = Get-SuperBrainMcpRuntimeIdentity $Root

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Same-Path([string]$Left,[string]$Right) {
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
  try { return (Get-NormalizedSuperBrainRoot $Left) -eq (Get-NormalizedSuperBrainRoot $Right) } catch { return $false }
}

function Resolve-CodexCli {
  $knownRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  $known = Get-ChildItem -LiteralPath $knownRoot -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike '*WindowsApps*' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($known) { return $known.FullName }
  foreach ($name in @('codex.exe','codex')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
  }
  return ''
}

function Invoke-CodexJson([string]$CodexPath,[string[]]$Arguments) {
  if ([string]::IsNullOrWhiteSpace($CodexPath)) { return [pscustomobject]@{ code=127; value=$null; text='CODEX_CLI_NOT_FOUND' } }
  $previous = $env:CODEX_HOME
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $env:CODEX_HOME = $CodexHome
    $raw = @(& $CodexPath @Arguments 2>&1)
    $code = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previous }
    $ErrorActionPreference = $previousPreference
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  if ($code -ne 0) { return [pscustomobject]@{ code=$code; value=$null; text=$text } }
  try { return [pscustomobject]@{ code=$code; value=(ConvertFrom-SuperBrainJsonOutput $text 'Codex MCP response'); text='' } }
  catch { return [pscustomobject]@{ code=1; value=$null; text='CODEX_JSON_INVALID' } }
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

function Test-McpBinding([object]$Registered) {
  if (-not $Registered -or $Registered.enabled -ne $true) { return $false }
  $registeredPackage = Get-McpTransportValue $Registered 'SUPER_BRAIN_PACKAGE_ROOT'
  $registeredMemory = Get-McpTransportValue $Registered 'NEXSANDBASE_HOME'
  $registeredIdentity = Get-McpTransportValue $Registered 'SUPER_BRAIN_RUNTIME_IDENTITY'
  $registeredTransport = Get-McpTransportValue $Registered 'SUPER_BRAIN_MCP_TRANSPORT'
  $packageArg = Get-McpTransportValue $Registered '--package-root'
  $memoryArg = Get-McpTransportValue $Registered '--memory-root'
  return ((Same-Path $registeredPackage $Root) -and (Same-Path $packageArg $Root) -and (Same-Path $registeredMemory $MemoryRoot) -and (Same-Path $memoryArg $MemoryRoot) -and ([string]$registeredIdentity -eq [string]$mcpRuntimeIdentity) -and ([string]$registeredTransport -eq 'codex_registered_v1'))
}

function Invoke-McpProtocolReplay {
  $runtimeEval = Join-Path $PSScriptRoot 'runtime-eval.ps1'
  $checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  if (-not (Test-Path -LiteralPath $runtimeEval)) {
    return [pscustomobject]@{ ok=$false; code='MCP_FUNCTIONAL_PROBE_SCRIPT_MISSING'; checkedAt=$checkedAt; durationMs=0; checkCount=0; failureCount=1 }
  }
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeEval -MemoryRoot $MemoryRoot -McpOnly -Json 2>&1)
  $exitCode = $LASTEXITCODE
  $watch.Stop()
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  try {
    $value = ConvertFrom-SuperBrainJsonOutput $text 'Super Brain MCP functional probe'
  } catch {
    return [pscustomobject]@{ ok=$false; code='MCP_FUNCTIONAL_PROBE_JSON_INVALID'; checkedAt=$checkedAt; durationMs=[int]$watch.ElapsedMilliseconds; checkCount=0; failureCount=1 }
  }
  $replay = if ($value -and $value.PSObject.Properties['mcpReplay']) { $value.mcpReplay } else { $null }
  $checks = if ($replay -and $replay.PSObject.Properties['checks']) { @($replay.checks) } else { @() }
  $failureCount = if ($replay -and $replay.PSObject.Properties['errors']) { @($replay.errors).Count } else { 1 }
  $ok = ($exitCode -eq 0 -and $value -and $value.ok -eq $true -and $replay -and $replay.ok -eq $true)
  return [pscustomobject]@{
    ok = $ok
    code = if ($ok) { 'MCP_FUNCTIONAL_PROBE_OK' } elseif ($exitCode -ne 0) { 'MCP_FUNCTIONAL_PROBE_EXIT' } else { 'MCP_FUNCTIONAL_PROBE_FAILED' }
    checkedAt = $checkedAt
    durationMs = [int]$watch.ElapsedMilliseconds
    checkCount = $checks.Count
    failureCount = $failureCount
  }
}

function Read-Marker([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
}

New-Item -ItemType Directory -Force -Path $workspace | Out-Null
$packageMarker = Read-Marker (Join-Path $entryRoot 'package-root.txt')
$memoryMarker = Read-Marker (Join-Path $entryRoot 'memory-root.txt')
$entrySkillPath = Join-Path $entryRoot 'SKILL.md'
$sourceSkillPath = Join-Path $Root 'super-memory-brain\SKILL.md'
$entrySkillHash = if (Test-Path -LiteralPath $entrySkillPath -PathType Leaf) { (Get-FileHash -LiteralPath $entrySkillPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
$sourceSkillHash = if (Test-Path -LiteralPath $sourceSkillPath -PathType Leaf) { (Get-FileHash -LiteralPath $sourceSkillPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
$entrySkillFresh = -not [string]::IsNullOrWhiteSpace($entrySkillHash) -and $entrySkillHash -eq $sourceSkillHash
$startupRoute = Test-SuperBrainGlobalStartup $CodexSkills
$startupRouteReady = [bool]$startupRoute.ok
$entrySkillPhysicalOk = $entrySkillFresh -and (Same-Path $packageMarker $Root) -and (Same-Path $memoryMarker $MemoryRoot)
$entrySkillOk = $entrySkillPhysicalOk -and $startupRouteReady
$entrySkillState = if (-not (Test-Path -LiteralPath $entrySkillPath -PathType Leaf)) { 'missing' } elseif (-not $entrySkillFresh) { 'stale' } elseif (-not (Same-Path $packageMarker $Root) -or -not (Same-Path $memoryMarker $MemoryRoot)) { 'marker_mismatch' } elseif (-not $startupRouteReady) { 'startup_route_missing_or_stale' } else { 'ready' }
$codexPath = Resolve-CodexCli
$mcpProbe = Invoke-CodexJson $codexPath @('mcp','get','super-memory-brain','--json')
$registered = $mcpProbe.value
$mcpConfigBindingOk = Test-McpBinding $registered
$runtimeBindingPath = Join-Path $workspace 'runtime-state\mcp-runtime-binding.json'
$runtimeBinding = Read-JsonFile $runtimeBindingPath
$registeredEpoch = Get-McpTransportValue $registered 'SUPER_BRAIN_MCP_REGISTRATION_EPOCH'
$mcpEpochMatches = ($runtimeBinding -and [string]$runtimeBinding.schema -eq 'super-brain.mcp-runtime-binding.v1' -and [string]$runtimeBinding.state -in @('restart_required','current') -and [string]$runtimeBinding.registrationEpoch -eq [string]$registeredEpoch -and [string]$runtimeBinding.runtimeIdentity -eq [string]$mcpRuntimeIdentity)
$mcpBindingOk = ($mcpConfigBindingOk -and $mcpEpochMatches)
$liveHandshake = if ($runtimeBinding -and $runtimeBinding.liveHandshake) { $runtimeBinding.liveHandshake } else { $null }
$mcpLiveHandshakeVerified = ($mcpBindingOk -and $liveHandshake -and [string]$liveHandshake.schema -eq 'super-brain.mcp-live-handshake.v1' -and [string]$liveHandshake.registrationEpoch -eq [string]$registeredEpoch -and [string]$liveHandshake.runtimeIdentity -eq [string]$mcpRuntimeIdentity -and [string]$liveHandshake.transport -eq 'codex_registered_mcp_stdio')
$repairAttempted = $false
$repairResult = $null
$cacheUsed = $false
$mcpProtocolReplay = $null
if ($mcpBindingOk -and $Force) { $mcpProtocolReplay = Invoke-McpProtocolReplay }

# A temporary stdio replay validates the package protocol only.  It cannot
# prove which MCP process Codex has resident.  Only the registration-epoch
# handshake may make the live transport ready; the replay remains diagnostic.
$mcpFunctionalOk = [bool]$mcpLiveHandshakeVerified
$mcpFunctionalCheckedAt = if ($mcpLiveHandshakeVerified) { [string]$liveHandshake.checkedAt } else { '' }
$mcpLiveHandshakeState = if ($mcpLiveHandshakeVerified) { 'current' } elseif ($mcpBindingOk) { 'not_observed_restart_required' } else { 'configuration_missing_or_stale' }

if (-not $mcpBindingOk -and $RepairMcp) {
  $repairAttempted = $true
  $runtimeScript = Join-Path $PSScriptRoot 'install-runtime.ps1'
  $raw = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runtimeScript -CodexHome $CodexHome -MemoryRoot $MemoryRoot -Json 2>&1)
  $repairCode = $LASTEXITCODE
  $repairText = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  $start = $repairText.IndexOf('{')
  if ($start -ge 0) { try { $repairResult = $repairText.Substring($start) | ConvertFrom-Json } catch {} }
  if (-not $repairResult) { $repairResult = [pscustomobject]@{ ok=($repairCode -eq 0); error='MCP_REPAIR_OUTPUT_INVALID' } }
  $mcpProbe = Invoke-CodexJson (Resolve-CodexCli) @('mcp','get','super-memory-brain','--json')
  $registered = $mcpProbe.value
  $mcpConfigBindingOk = Test-McpBinding $registered
  $runtimeBinding = Read-JsonFile $runtimeBindingPath
  $registeredEpoch = Get-McpTransportValue $registered 'SUPER_BRAIN_MCP_REGISTRATION_EPOCH'
  $mcpEpochMatches = ($runtimeBinding -and [string]$runtimeBinding.schema -eq 'super-brain.mcp-runtime-binding.v1' -and [string]$runtimeBinding.state -in @('restart_required','current') -and [string]$runtimeBinding.registrationEpoch -eq [string]$registeredEpoch -and [string]$runtimeBinding.runtimeIdentity -eq [string]$mcpRuntimeIdentity)
  $mcpBindingOk = ($mcpConfigBindingOk -and $mcpEpochMatches)
  $liveHandshake = if ($runtimeBinding -and $runtimeBinding.liveHandshake) { $runtimeBinding.liveHandshake } else { $null }
  $mcpLiveHandshakeVerified = ($mcpBindingOk -and $liveHandshake -and [string]$liveHandshake.schema -eq 'super-brain.mcp-live-handshake.v1' -and [string]$liveHandshake.registrationEpoch -eq [string]$registeredEpoch -and [string]$liveHandshake.runtimeIdentity -eq [string]$mcpRuntimeIdentity -and [string]$liveHandshake.transport -eq 'codex_registered_mcp_stdio')
  if ($mcpBindingOk) {
    $mcpFunctionalOk = [bool]$mcpLiveHandshakeVerified
    $mcpFunctionalCheckedAt = if ($mcpLiveHandshakeVerified) { [string]$liveHandshake.checkedAt } else { '' }
    $mcpLiveHandshakeState = if ($mcpLiveHandshakeVerified) { 'current' } else { 'not_observed_restart_required' }
  }
}

$memoryRootExists = Test-Path -LiteralPath $MemoryRoot
$activation = $null
$activationProbeCode = ''
$activationRuntime = Join-Path $PSScriptRoot '..\runtime\brain_cli.py'
if (Test-Path -LiteralPath $activationRuntime) {
  try {
    $activationRaw = @(& python -X utf8 $activationRuntime --package-root $Root --memory-root $MemoryRoot activate --route first_load --action-authorization not_applicable 2>&1)
    $activationText = ($activationRaw | ForEach-Object { [string]$_ }) -join "`n"
    $activation = ConvertFrom-SuperBrainJsonOutput $activationText 'Super Brain activation receipt'
    $activationProbeCode = if ($activation -and $activation.activationState) { [string]$activation.activationState } else { 'invalid' }
  } catch {
    $activationProbeCode = 'ACTIVATION_PROBE_FAILED'
  }
} else {
  $activationProbeCode = 'ACTIVATION_RUNTIME_MISSING'
}
$activationCoreReady = ($activation -and $activation.receiptHash -and $activation.capabilities -and $activation.capabilities.coreReady -eq $true -and $activation.activationState -eq 'full_brain_active')
$readiness = Get-SuperBrainRuntimeReadiness -EntryAdapterReady $entrySkillOk -MemoryRootReady $memoryRootExists -McpBindingReady $mcpBindingOk -McpLiveHandshakeReady $mcpLiveHandshakeVerified -ActivationCoreReady $activationCoreReady -CliRuntimeReady $activationCoreReady
$ok = [bool]($readiness.coreRuntimeReady -and $entrySkillOk)
$needsNewTask = $false
$action = if (-not $entrySkillOk) { 'refresh_codex_entry_adapter' } elseif (-not $mcpBindingOk) { 'repair_mcp_registration' } elseif (-not $readiness.coreRuntimeReady -and $repairAttempted) { 'inspect_mcp_repair' } elseif ($mcpLiveHandshakeState -eq 'not_observed_restart_required') { 'restart_codex_and_verify_live_mcp' } else { [string]$readiness.action }
$result = [pscustomobject]@{
  ok = $ok
  schema = 'super-brain.first-load-bootstrap.v1'
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  version = [string]$manifest.version
  packageRoot = $Root
  codexHome = $CodexHome
  codexSkills = $CodexSkills
  memoryRoot = $MemoryRoot
  entrySkillOk = $entrySkillOk
  entrySkillPhysicalOk = $entrySkillPhysicalOk
  entrySkillFresh = $entrySkillFresh
  entrySkillState = $entrySkillState
  hostEntryReady = $entrySkillOk
  startupRouteReady = $startupRouteReady
  startupRouteState = if ($startupRouteReady) { 'ready' } else { 'withheld' }
  startupRouteReason = [string]$startupRoute.reason
  startupRoutePaths = @($startupRoute.paths)
  startupRouteExpected = @($startupRoute.expected)
  startupRouteFailed = @($startupRoute.failed)
  coreRuntimeReady = [bool]$readiness.coreRuntimeReady
  adapterRequired = $true
  adapterState = $entrySkillState
  transport = [string]$readiness.transport
  availability = if (-not $ok) { 'withheld' } elseif ($mcpLiveHandshakeState -eq 'not_observed_restart_required') { 'h7_cli_ready_mcp_restart_required' } else { 'full' }
  memoryRootExists = $memoryRootExists
  mcpRegistered = ($null -ne $registered)
  mcpConfigBindingOk = $mcpConfigBindingOk
  mcpEpochMatches = $mcpEpochMatches
  mcpBindingOk = $mcpBindingOk
  mcpRuntimeIdentity = $mcpRuntimeIdentity
  mcpLiveHandshakeState = $mcpLiveHandshakeState
  mcpLiveHandshakeVerified = [bool]$mcpLiveHandshakeVerified
  mcpFunctionalOk = $mcpFunctionalOk
  mcpFunctionalCheckedAt = $mcpFunctionalCheckedAt
  mcpProtocolReplay = if ($mcpProtocolReplay) { [pscustomobject]@{ code=[string]$mcpProtocolReplay.code; durationMs=[int]$mcpProtocolReplay.durationMs; checkCount=[int]$mcpProtocolReplay.checkCount; failureCount=[int]$mcpProtocolReplay.failureCount; mode='offline_replay_not_live_proof' } } else { $null }
  activationState = if ($activation) { [string]$activation.activationState } else { 'withheld' }
  fullBrainActive = ($activation -and [string]$activation.activationState -eq 'full_brain_active')
  activationCoreReady = [bool]$activationCoreReady
  activationProbeCode = $activationProbeCode
  activationReceipt = if ($activation) { [pscustomobject]@{ activationId=[string]$activation.activationId; receiptHash=[string]$activation.receiptHash; scopeRef=[string]$activation.scope.scopeRef; packageVersion=[string]$activation.package.version; routeMapHash=[string]$activation.route.routeMapHash; coreReady=[bool]$activation.capabilities.coreReady; rawPromptStored=$false; rawTranscriptStored=$false } } else { $null }
  repairAttempted = $repairAttempted
  repairOk = if ($repairResult) { [bool]$repairResult.ok } else { $false }
  needsNewTask = $needsNewTask
  cacheUsed = $cacheUsed
  action = $action
  repairSwitch = '-RepairMcp'
  rawPromptStored = $false
}
Write-JsonUtf8NoBom $statePath $result 10
if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "FIRST_LOAD_BOOTSTRAP ok=$($result.ok) activation=$($result.activationState) entry=$($result.entrySkillOk) mcp=$($result.mcpBindingOk) action=$action" }
if ($FailOnNotReady -and -not $ok) { exit 1 }
exit 0
