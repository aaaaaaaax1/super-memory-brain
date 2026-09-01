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
$codexHomeWasExplicit = $PSBoundParameters.ContainsKey('CodexHome')
$MemoryRoot = Resolve-SuperBrainActiveMemoryRoot -Root $Root -Candidate $MemoryRoot -Operation 'install-runtime'
$CodexHome = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexHome))
$defaultCodexHome = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex'))
$useExplicitCodexHome = $codexHomeWasExplicit -and -not (Test-SuperBrainSamePath $CodexHome $defaultCodexHome)
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
    # In Codex Desktop the default configuration can be mediated by the
    # resident app. Preserve that effective channel unless a non-default
    # isolated home was explicitly requested.
    if ($useExplicitCodexHome) { $env:CODEX_HOME = $CodexHome }
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
  if (-not (Test-McpBinding $Registered $ExpectedEpoch)) {
    throw "MCP_BINDING_MISMATCH expectedPackage=$Root expectedMemory=$MemoryRoot expectedIdentity=$runtimeIdentity expectedEpoch=$ExpectedEpoch actualPackage=$registeredPackage actualMemory=$registeredMemory actualIdentity=$registeredIdentity actualEpoch=$registeredEpoch packageArg=$packageArg memoryArg=$memoryArg enabled=$($Registered.enabled)"
  }
}

function Test-McpBinding([object]$Registered,[string]$ExpectedEpoch = '') {
  if (-not $Registered -or $Registered.enabled -ne $true -or -not $Registered.transport -or [string]$Registered.transport.type -ne 'stdio') { return $false }
  $registeredPackage = Get-McpTransportValue $Registered 'SUPER_BRAIN_PACKAGE_ROOT'
  $registeredMemory = Get-McpTransportValue $Registered 'NEXSANDBASE_HOME'
  $registeredIdentity = Get-McpTransportValue $Registered 'SUPER_BRAIN_RUNTIME_IDENTITY'
  $registeredTransport = Get-McpTransportValue $Registered 'SUPER_BRAIN_MCP_TRANSPORT'
  $registeredEpoch = Get-McpTransportValue $Registered 'SUPER_BRAIN_MCP_REGISTRATION_EPOCH'
  $packageArg = Get-McpTransportValue $Registered '--package-root'
  $memoryArg = Get-McpTransportValue $Registered '--memory-root'
  $samePackage = (Get-NormalizedSuperBrainRoot $registeredPackage) -eq (Get-NormalizedSuperBrainRoot $Root) -and (Get-NormalizedSuperBrainRoot $packageArg) -eq (Get-NormalizedSuperBrainRoot $Root)
  $sameMemory = (Get-NormalizedSuperBrainRoot $registeredMemory) -eq (Get-NormalizedSuperBrainRoot $MemoryRoot) -and (Get-NormalizedSuperBrainRoot $memoryArg) -eq (Get-NormalizedSuperBrainRoot $MemoryRoot)
  $epochOk = ([string]$registeredEpoch -match '^[a-f0-9]{32}$')
  $expectedEpochOk = [string]::IsNullOrWhiteSpace($ExpectedEpoch) -or [string]$registeredEpoch -eq [string]$ExpectedEpoch
  return ($samePackage -and $sameMemory -and ([string]$registeredIdentity -eq [string]$runtimeIdentity) -and $registeredTransport -eq 'codex_registered_v1' -and $epochOk -and $expectedEpochOk)
}

function Test-SuperBrainMcpRegistration([object]$Registered) {
  if (-not $Registered -or -not $Registered.transport -or [string]$Registered.transport.type -ne 'stdio') { return $false }
  $registeredTransport = Get-McpTransportValue $Registered 'SUPER_BRAIN_MCP_TRANSPORT'
  $registeredPackage = Get-McpTransportValue $Registered 'SUPER_BRAIN_PACKAGE_ROOT'
  $registeredIdentity = Get-McpTransportValue $Registered 'SUPER_BRAIN_RUNTIME_IDENTITY'
  return ($registeredTransport -eq 'codex_registered_v1' -or -not [string]::IsNullOrWhiteSpace($registeredPackage) -or -not [string]::IsNullOrWhiteSpace($registeredIdentity))
}

function Test-CurrentRuntimeBinding([object]$Binding,[string]$ExpectedEpoch) {
  if (-not $Binding) { return $false }
  $fields = @('schema','state','registrationEpoch','packageVersion','runtimeIdentity','packageRootHash','memoryRootHash','configuredAt','liveHandshake','rawPromptStored','rawTranscriptStored')
  $payload = [ordered]@{}
  foreach ($field in $fields) {
    if (-not $Binding.PSObject.Properties[$field]) { return $false }
    $payload[$field] = $Binding.$field
  }
  $expectedHash = Get-SuperBrainStableHash (($payload | ConvertTo-Json -Depth 8 -Compress)) 64
  return (
    [string]$Binding.schema -eq 'super-brain.mcp-runtime-binding.v1' -and
    [string]$Binding.state -in @('restart_required','current') -and
    [string]$Binding.registrationEpoch -eq [string]$ExpectedEpoch -and
    [string]$Binding.runtimeIdentity -eq [string]$runtimeIdentity -and
    [string]$Binding.packageRootHash -eq (Get-SuperBrainMcpPathHash $Root) -and
    [string]$Binding.memoryRootHash -eq (Get-SuperBrainMcpPathHash (Get-SuperBrainMemoryBaseRoot $Root)) -and
    [string]$Binding.payloadHash -eq $expectedHash
  )
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

$installLockPath = Join-Path $workspace ('.super-memory-brain-' + (Get-SuperBrainStableHash $McpName 16) + '-registration')
$result = $null
$installError = $null
$mcpConfigurationMutationAttempted = $false

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
      # A current static entry is already the desired deployment. Reusing its
      # epoch avoids a remove/add window and does not churn a running Desktop
      # configuration. The local binding is merely rebuilt if absent/stale.
      if (Test-McpBinding $previous) {
        $script:registrationEpoch = Get-McpTransportValue $previous 'SUPER_BRAIN_MCP_REGISTRATION_EPOCH'
        $previousBinding = $null
        if ($previousBindingText) { try { $previousBinding = $previousBindingText | ConvertFrom-Json } catch {} }
        if (-not (Test-CurrentRuntimeBinding $previousBinding $registrationEpoch)) { Write-RuntimeBinding 'restart_required' }
        $script:result = [pscustomobject]@{
          ok = $true
          action = 'already_configured'
          checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
          version = (Get-SuperBrainManifest $Root).version
          mcpName = $McpName
          codexCli = $codexPath
          packageRoot = $Root
          memoryRoot = $MemoryRoot
          runtimeIdentity = $runtimeIdentity
          registrationEpochHash = Get-SuperBrainStableHash $registrationEpoch 64
          configurationState = 'configuration_current'
          configurationAuthority = if ($useExplicitCodexHome) { 'explicit_codex_home' } else { 'codex_native_effective_config' }
          liveTransportState = 'runtime_probe_required'
          restartRequired = $false
          fullRuntimeReady = $false
          runtime = $mcpScript
          tools = @('brain_recall','brain_status','brain_turn','brain_recent')
          evaluationMode = 'offline_replay_only'
          offlineReplay = [pscustomobject]@{ mode=$evalMode; total=$eval.total; passed=$eval.passed; p50Ms=$eval.latency.p50Ms; p95Ms=$eval.latency.p95Ms }
          contract = [pscustomobject]@{ total=$eval.total; passed=$eval.passed; p50Ms=$eval.latency.p50Ms; p95Ms=$eval.latency.p95Ms }
          configBackup = ''
          previousMcpReplaced = $false
          registered = $previous
          rollback = 'No configuration write was required. Verify the live MCP with brain_status in Codex.'
        }
        return
      }
      if ($previous -and -not (Test-SuperBrainMcpRegistration $previous)) { throw 'MCP_NAME_CONFLICT_FOREIGN_ENTRY' }
      # Publish the new desired epoch before touching static config. A failed
      # config mutation restores only the package-owned binding under this
      # lock. Codex owns config.toml, so it is never whole-file restored here.
      Write-RuntimeBinding 'restart_required'
      if ($previous) {
        $script:mcpConfigurationMutationAttempted = $true
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
      $script:mcpConfigurationMutationAttempted = $true
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
          configurationAuthority = if ($useExplicitCodexHome) { 'explicit_codex_home' } else { 'codex_native_effective_config' }
          liveTransportState = 'runtime_probe_required'
        restartRequired = $false
        fullRuntimeReady = $false
        runtime = $mcpScript
        tools = @('brain_recall','brain_status','brain_turn','brain_recent')
        evaluationMode = 'offline_replay_only'
        offlineReplay = [pscustomobject]@{ mode=$evalMode; total=$eval.total; passed=$eval.passed; p50Ms=$eval.latency.p50Ms; p95Ms=$eval.latency.p95Ms }
        contract = [pscustomobject]@{ total=$eval.total; passed=$eval.passed; p50Ms=$eval.latency.p50Ms; p95Ms=$eval.latency.p95Ms }
          configBackup = ''
        previousMcpReplaced = ($null -ne $previous)
        registered = $registered
        rollback = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'install-runtime.ps1')`" -Remove"
      }
    } catch {
      if ($previousBindingText) {
        Write-Utf8NoBom $bindingPath $previousBindingText
      } elseif (Test-Path -LiteralPath $bindingPath) {
        Remove-Item -LiteralPath $bindingPath -Force
      }
      $failureCode = if ($script:mcpConfigurationMutationAttempted) { 'MCP_REGISTRATION_PARTIAL_REPAIR_REQUIRED_NO_WHOLE_FILE_ROLLBACK' } else { 'MCP_REGISTRATION_FAILED_BEFORE_CONFIG_MUTATION' }
      throw "${failureCode}: $($_.Exception.Message)"
    }
  } -TimeoutMs 60000
} catch {
  $installError = $_
}

if ($installError) { throw $installError }
if (-not $result) { throw 'MCP_INSTALL_RESULT_MISSING' }
Write-JsonUtf8NoBom $resultPath $result 12
if ($Json) { $result | ConvertTo-Json -Depth 12 } else {
  Write-Host "RUNTIME_INSTALL_CONFIGURED_RUNTIME_PROBE_REQUIRED mcp=$McpName tools=4 p50Ms=$($eval.latency.p50Ms) p95Ms=$($eval.latency.p95Ms)"
  Write-Host 'Call the registered Super Brain brain_status in Codex to complete the live MCP verification; restart only if that live probe reports a stale or unavailable runtime.'
}
exit 0
