[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = "$env:USERPROFILE\.codex",
  [string]$MemoryRoot = '',
  [string]$CodexCli = '',
  [string]$McpName = 'super-memory-brain',
  [switch]$Remove,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$MemoryRoot = Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $MemoryRoot -Operation 'install-runtime'
$CodexHome = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexHome))
$configPath = Join-Path $CodexHome 'config.toml'
$runtimeCli = Join-Path $Root 'runtime\brain_cli.py'
$mcpScript = Join-Path $Root 'runtime\brain_mcp.py'
$runtimeIdentity = Get-SuperBrainMcpRuntimeIdentity $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$resultPath = Join-Path $workspace 'last-runtime-install.json'
$bindingPath = Join-Path $workspace 'runtime-state\mcp-runtime-binding.json'
$registrationEpoch = [guid]::NewGuid().ToString('N')

function Resolve-CodexCli {
  if (-not [string]::IsNullOrWhiteSpace($CodexCli) -and (Test-Path -LiteralPath $CodexCli)) { return [IO.Path]::GetFullPath($CodexCli) }
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
  throw 'CODEX_CLI_NOT_FOUND'
}

function Invoke-Codex([string[]]$Arguments) {
  $previousPreference = $ErrorActionPreference
  $previousCodexHome = $env:CODEX_HOME
  $ErrorActionPreference = 'Continue'
  try {
    $env:CODEX_HOME = $CodexHome
    $output = @(& $codexPath @Arguments 2>&1)
    $code = $LASTEXITCODE
  } finally {
    if ($null -eq $previousCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previousCodexHome }
    $ErrorActionPreference = $previousPreference
  }
  return [pscustomobject]@{ code=$code; text=(($output | ForEach-Object { [string]$_ }) -join "`n") }
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

function Assert-McpBinding([object]$Registered,[string]$ExpectedEpoch) {
  $registeredPackage = Get-McpTransportValue $Registered 'SUPER_BRAIN_PACKAGE_ROOT'
  $registeredMemory = Get-McpTransportValue $Registered 'NEXSANDBASE_HOME'
  $registeredIdentity = Get-McpTransportValue $Registered 'SUPER_BRAIN_RUNTIME_IDENTITY'
  $registeredTransport = Get-McpTransportValue $Registered 'SUPER_BRAIN_MCP_TRANSPORT'
  $registeredEpoch = Get-McpTransportValue $Registered 'SUPER_BRAIN_MCP_REGISTRATION_EPOCH'
  $packageArg = Get-McpTransportValue $Registered '--package-root'
  $memoryArg = Get-McpTransportValue $Registered '--memory-root'
  $samePackage = (Get-NormalizedSuperBrainRoot $registeredPackage) -eq (Get-NormalizedSuperBrainRoot $Root) -and (Get-NormalizedSuperBrainRoot $packageArg) -eq (Get-NormalizedSuperBrainRoot $Root)
  $sameMemory = (Get-NormalizedSuperBrainRoot $registeredMemory) -eq (Get-NormalizedSuperBrainRoot $MemoryRoot) -and (Get-NormalizedSuperBrainRoot $memoryArg) -eq (Get-NormalizedSuperBrainRoot $MemoryRoot)
  $sameIdentity = ([string]$registeredIdentity -eq [string]$runtimeIdentity)
  if (-not $samePackage -or -not $sameMemory -or -not $sameIdentity -or $registeredTransport -ne 'codex_registered_v1' -or $registeredEpoch -ne $ExpectedEpoch -or $Registered.enabled -ne $true) {
    throw "MCP_BINDING_MISMATCH expectedPackage=$Root expectedMemory=$MemoryRoot expectedIdentity=$runtimeIdentity expectedEpoch=$ExpectedEpoch actualPackage=$registeredPackage actualMemory=$registeredMemory actualIdentity=$registeredIdentity actualEpoch=$registeredEpoch packageArg=$packageArg memoryArg=$memoryArg enabled=$($Registered.enabled)"
  }
}

$codexPath = Resolve-CodexCli
if ($Remove) {
  $removeCall = Invoke-Codex @('mcp','remove',$McpName)
  $removed = ($removeCall.code -eq 0)
  $result = [pscustomobject]@{ ok=$removed; action='remove'; mcpName=$McpName; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
  Write-JsonUtf8NoBom $resultPath $result 6
  if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-Host "RUNTIME_REMOVE ok=$removed mcp=$McpName" }
  if (-not $removed) { exit 1 }; exit 0
}

$healthRaw = @(& python $runtimeCli --package-root $Root --memory-root $MemoryRoot health 2>&1)
if ($LASTEXITCODE -ne 0) { throw "RUNTIME_HEALTH_FAILED $($healthRaw -join ' ')" }
$health = (($healthRaw -join "`n") | ConvertFrom-Json)
if ($health.ok -ne $true) { throw 'RUNTIME_HEALTH_NOT_OK' }

# Runtime registration must be portable: the current user's private memory is
# data, not an installation dependency.  Validate the H7/MCP transport and
# its fail-closed metadata boundary with the isolated contract replay here.
# Full natural-language recall quality remains a separate local quality gate;
# it must never block a one-entry MCP re-registration merely because a user
# has pruned, superseded, or never created a particular memory card.
$evalArguments = @(
  '--package-root', $Root,
  '--memory-root', $MemoryRoot,
  '--mcp-replay',
  '--contract-only'
)
$evalMode = 'portable-contract-and-mcp'
$evalRaw = @(& python (Join-Path $Root 'runtime\brain_eval.py') @evalArguments 2>&1)
if ($LASTEXITCODE -ne 0) { throw "RUNTIME_EVAL_FAILED $($evalRaw -join ' ')" }
$eval = (($evalRaw -join "`n") | ConvertFrom-Json)
if ($eval.ok -ne $true) { throw 'RUNTIME_EVAL_NOT_OK' }

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $CodexHome 'backups_state\super-brain-runtime'
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$configBackup = Join-Path $backupRoot "config-$timestamp.toml"
$configExisted = Test-Path -LiteralPath $configPath
if ($configExisted) { Copy-Item -LiteralPath $configPath -Destination $configBackup -Force }

function Write-RuntimeBinding([string]$State) {
  $binding = [ordered]@{
    schema = 'super-brain.mcp-runtime-binding.v1'
    state = $State
    registrationEpoch = $registrationEpoch
    packageVersion = [string](Get-SuperBrainManifest $Root).version
    runtimeIdentity = $runtimeIdentity
    # Keep the installer binding compatible with Python's runtime-side
    # _mcp_path_hash. A normal Windows casing difference must never leave a
    # newly registered MCP permanently restart_required. Python H7 binds the
    # canonical state root (private-state), while the active memory transport
    # intentionally points at its shared child.
    packageRootHash = Get-SuperBrainMcpPathHash $Root
    memoryRootHash = Get-SuperBrainMcpPathHash (Get-SuperBrainMemoryBaseRoot $Root)
    configuredAt = (Get-Date).ToUniversalTime().ToString('o')
    liveHandshake = $null
    rawPromptStored = $false
    rawTranscriptStored = $false
  }
  $binding.payloadHash = Get-SuperBrainStableHash (($binding | ConvertTo-Json -Depth 8 -Compress)) 64
  $parent = Split-Path -Parent $bindingPath
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temporary = $bindingPath + '.tmp'
  Write-JsonUtf8NoBom $temporary $binding 8 -Compress
  Move-Item -LiteralPath $temporary -Destination $bindingPath -Force
}

$installLockPath = Join-Path $CodexHome ('.super-memory-brain-' + (Get-SuperBrainStableHash $McpName 16) + '-registration')
$result = $null
$installError = $null

try {
  # A registration is a single read/remove/write/verify transaction.  The
  # Codex app-server can service several sessions concurrently, so serialize
  # this exact MCP entry and never let two epochs cross in config or binding.
  Invoke-SuperBrainFileLock $installLockPath {
    $previous = $null
    $previousCall = Invoke-Codex @('mcp','get',$McpName,'--json')
    if ($previousCall.code -eq 0) { try { $previous = ConvertFrom-SuperBrainJsonOutput $previousCall.text 'previous MCP binding' } catch {} }
    $previousBindingText = if (Test-Path -LiteralPath $bindingPath -PathType Leaf) { Get-Content -LiteralPath $bindingPath -Raw -Encoding UTF8 } else { '' }

    try {
      # Publish the new desired epoch before touching static config. A failed
      # config mutation restores both config and the binding under this lock.
      Write-RuntimeBinding 'restart_required'
      if ($previous) {
        $removeCall = Invoke-Codex @('mcp','remove',$McpName)
        if ($removeCall.code -ne 0) { throw "EXISTING_MCP_REMOVE_FAILED: $($removeCall.text)" }
      }
      $addArgs = @(
        'mcp','add',$McpName,
        '--env',"SUPER_BRAIN_PACKAGE_ROOT=$Root",
        '--env',"NEXSANDBASE_HOME=$MemoryRoot",
        '--env',"SUPER_BRAIN_RUNTIME_IDENTITY=$runtimeIdentity",
        '--env',"SUPER_BRAIN_MCP_TRANSPORT=codex_registered_v1",
        '--env',"SUPER_BRAIN_MCP_REGISTRATION_EPOCH=$registrationEpoch",
        '--','python',$mcpScript,'--package-root',$Root,'--memory-root',$MemoryRoot
      )
      $addCall = Invoke-Codex $addArgs
      if ($addCall.code -ne 0) { throw "MCP_ADD_FAILED: $($addCall.text)" }
      $verifyCall = Invoke-Codex @('mcp','get',$McpName,'--json')
      if ($verifyCall.code -ne 0) { throw "MCP_VERIFY_FAILED: $($verifyCall.text)" }
      $registered = ConvertFrom-SuperBrainJsonOutput $verifyCall.text 'verified MCP binding'
      Assert-McpBinding $registered $registrationEpoch
      $script:result = [pscustomobject]@{
        ok = $true
        action = 'install'
        checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        version = (Get-SuperBrainManifest $Root).version
        mcpName = $McpName
        codexCli = $codexPath
        packageRoot = $Root
        memoryRoot = $MemoryRoot
        runtimeIdentity = $runtimeIdentity
        registrationEpochHash = Get-SuperBrainStableHash $registrationEpoch 64
        configurationState = 'configuration_applied'
        liveTransportState = 'restart_required'
        restartRequired = $true
        fullRuntimeReady = $false
        runtime = $mcpScript
        tools = @('brain_recall','brain_status','brain_turn','brain_recent')
        evaluationMode = 'offline_replay_only'
        offlineReplay = [pscustomobject]@{ mode=$evalMode; total=$eval.total; passed=$eval.passed; p50Ms=$eval.latency.p50Ms; p95Ms=$eval.latency.p95Ms }
        contract = [pscustomobject]@{ total=$eval.total; passed=$eval.passed; p50Ms=$eval.latency.p50Ms; p95Ms=$eval.latency.p95Ms }
        configBackup = if ($configExisted) { $configBackup } else { '' }
        previousMcpReplaced = ($null -ne $previous)
        registered = $registered
        rollback = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'install-runtime.ps1')`" -Remove"
      }
    } catch {
      if ($configExisted -and (Test-Path -LiteralPath $configBackup)) {
        Copy-Item -LiteralPath $configBackup -Destination $configPath -Force
      } elseif (-not $configExisted -and (Test-Path -LiteralPath $configPath)) {
        Remove-Item -LiteralPath $configPath -Force
      }
      if ($previousBindingText) {
        Write-Utf8NoBom $bindingPath $previousBindingText
      } elseif (Test-Path -LiteralPath $bindingPath) {
        Remove-Item -LiteralPath $bindingPath -Force
      }
      throw
    }
  } -TimeoutMs 60000
} catch {
  $installError = $_
}

if ($installError) { throw $installError }
if (-not $result) { throw 'MCP_INSTALL_RESULT_MISSING' }
Write-JsonUtf8NoBom $resultPath $result 12
if ($Json) { $result | ConvertTo-Json -Depth 12 } else {
  Write-Host "RUNTIME_INSTALL_CONFIGURED_RESTART_REQUIRED mcp=$McpName tools=4 p50Ms=$($eval.latency.p50Ms) p95Ms=$($eval.latency.p95Ms)"
  Write-Host 'Restart Codex, then call the registered Super Brain brain_status to complete the live MCP handshake.'
}
exit 0
