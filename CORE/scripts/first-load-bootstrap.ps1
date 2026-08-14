[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = "$env:USERPROFILE\.codex",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [string]$MemoryRoot = '',
  [switch]$RepairMcp,
  [switch]$Force,
  [ValidateRange(1,1440)]
  [int]$McpProbeMaxAgeMinutes = 60,
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
  $packageArg = Get-McpTransportValue $Registered '--package-root'
  $memoryArg = Get-McpTransportValue $Registered '--memory-root'
  return ((Same-Path $registeredPackage $Root) -and (Same-Path $packageArg $Root) -and (Same-Path $registeredMemory $MemoryRoot) -and (Same-Path $memoryArg $MemoryRoot) -and ([string]$registeredIdentity -eq [string]$mcpRuntimeIdentity))
}

function Test-FreshMcpFunctionalProbe([object]$Previous) {
  if (-not $Previous -or $Previous.mcpFunctionalOk -ne $true -or [string]::IsNullOrWhiteSpace([string]$Previous.mcpFunctionalCheckedAt)) { return $false }
  try {
    return ([datetime]::Parse([string]$Previous.mcpFunctionalCheckedAt).AddMinutes($McpProbeMaxAgeMinutes) -ge (Get-Date))
  } catch {
    return $false
  }
}

function Invoke-McpFunctionalProbe {
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
$entrySkillOk = $entrySkillFresh -and (Same-Path $packageMarker $Root) -and (Same-Path $memoryMarker $MemoryRoot)
$entrySkillState = if (-not (Test-Path -LiteralPath $entrySkillPath -PathType Leaf)) { 'missing' } elseif (-not $entrySkillFresh) { 'stale' } elseif (-not (Same-Path $packageMarker $Root) -or -not (Same-Path $memoryMarker $MemoryRoot)) { 'marker_mismatch' } else { 'ready' }
$codexPath = Resolve-CodexCli
$mcpProbe = Invoke-CodexJson $codexPath @('mcp','get','super-memory-brain','--json')
$registered = $mcpProbe.value
$mcpBindingOk = Test-McpBinding $registered
$repairAttempted = $false
$repairResult = $null
$cacheUsed = $false
$previous = Read-JsonFile $statePath
$cacheIdentityMatches = ($previous -and [string]$previous.version -eq [string]$manifest.version -and [string]$previous.mcpRuntimeIdentity -eq [string]$mcpRuntimeIdentity -and (Same-Path ([string]$previous.packageRoot) $Root) -and (Same-Path ([string]$previous.memoryRoot) $MemoryRoot))
$mcpFunctionalProbe = $null
$mcpFunctionalOk = $false
$mcpFunctionalCheckedAt = ''
if ($mcpBindingOk -and -not $Force -and $cacheIdentityMatches -and (Test-FreshMcpFunctionalProbe $previous)) {
  $cacheUsed = $true
  $mcpFunctionalOk = $true
  $mcpFunctionalCheckedAt = [string]$previous.mcpFunctionalCheckedAt
} elseif ($mcpBindingOk) {
  $mcpFunctionalProbe = Invoke-McpFunctionalProbe
  $mcpFunctionalOk = [bool]$mcpFunctionalProbe.ok
  $mcpFunctionalCheckedAt = [string]$mcpFunctionalProbe.checkedAt
}

if ((-not $mcpBindingOk -or -not $mcpFunctionalOk) -and $RepairMcp) {
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
  $mcpBindingOk = Test-McpBinding $registered
  if ($mcpBindingOk) {
    $mcpFunctionalProbe = Invoke-McpFunctionalProbe
    $mcpFunctionalOk = [bool]$mcpFunctionalProbe.ok
    $mcpFunctionalCheckedAt = [string]$mcpFunctionalProbe.checkedAt
    $cacheUsed = $false
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
$readiness = Get-SuperBrainRuntimeReadiness -EntryAdapterReady $entrySkillOk -MemoryRootReady $memoryRootExists -McpBindingReady $mcpBindingOk -McpFunctionalReady $mcpFunctionalOk -ActivationCoreReady $activationCoreReady -CliRuntimeReady $activationCoreReady
$ok = [bool]($readiness.coreRuntimeReady -and $entrySkillOk)
$needsNewTask = [bool]($repairAttempted -and $repairResult -and $repairResult.ok -eq $true -and $mcpFunctionalOk)
$action = if (-not $entrySkillOk) { 'refresh_codex_entry_adapter' } elseif (-not $readiness.coreRuntimeReady -and $repairAttempted) { 'inspect_mcp_repair_and_open_new_task' } else { [string]$readiness.action }
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
  entrySkillFresh = $entrySkillFresh
  entrySkillState = $entrySkillState
  hostEntryReady = $entrySkillOk
  coreRuntimeReady = [bool]$readiness.coreRuntimeReady
  adapterRequired = $true
  adapterState = $entrySkillState
  transport = [string]$readiness.transport
  availability = if ($ok) { 'full' } else { 'withheld' }
  memoryRootExists = $memoryRootExists
  mcpRegistered = ($null -ne $registered)
  mcpBindingOk = $mcpBindingOk
  mcpRuntimeIdentity = $mcpRuntimeIdentity
  mcpFunctionalOk = $mcpFunctionalOk
  mcpFunctionalCheckedAt = $mcpFunctionalCheckedAt
  mcpFunctionalProbe = if ($mcpFunctionalProbe) { [pscustomobject]@{ code=[string]$mcpFunctionalProbe.code; durationMs=[int]$mcpFunctionalProbe.durationMs; checkCount=[int]$mcpFunctionalProbe.checkCount; failureCount=[int]$mcpFunctionalProbe.failureCount } } else { $null }
  activationState = if ($activation) { [string]$activation.activationState } else { 'withheld' }
  fullBrainActive = ($activation -and [string]$activation.activationState -eq 'full_brain_active')
  activationCoreReady = [bool]$activationCoreReady
  activationProbeCode = $activationProbeCode
  activationReceipt = if ($activation) { [pscustomobject]@{ activationId=[string]$activation.activationId; receiptHash=[string]$activation.receiptHash; scopeRef=[string]$activation.scope.scopeRef; packageVersion=[string]$activation.package.version; routeMapHash=[string]$activation.route.routeMapHash; coreReady=[bool]$activation.capabilities.coreReady; rawPromptStored=$false; rawTranscriptStored=$false } } else { $null }
  mcpProbeMaxAgeMinutes = $McpProbeMaxAgeMinutes
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
