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
$mcpLauncher = Join-Path $Root 'runtime\local_mcp_launcher.py'
$runtimeIdentity = Get-SuperBrainMcpRuntimeIdentity $Root
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$resultPath = Join-Path $workspace 'last-runtime-install.json'
$bindingPath = Join-Path $workspace 'runtime-state\mcp-runtime-binding.json'
$registrationEpoch = [guid]::NewGuid().ToString('N')
$configurationScope = Get-SuperBrainMcpConfigurationScopeKey -CodexHome $CodexHome -ExplicitCodexHome:$useExplicitCodexHome
# An explicitly selected isolated home owns its configuration directory, so
# keep its serialisation lock there as well. The Desktop-native default has no
# package-specific configuration root; it therefore uses the shared local
# Codex lock namespace to serialize every package targeting that one registry.
$registrationLockRoot = if ($useExplicitCodexHome) { Join-Path $CodexHome '.super-memory-brain-locks' } else { '' }
$installLockPath = Get-SuperBrainMcpRegistrationLockPath -McpName $McpName -ConfigurationScope $configurationScope -LockRoot $registrationLockRoot

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

function Assert-McpBinding([object]$Registered,[string]$ExpectedEpoch) {
  $assessment = Test-SuperBrainMcpRegistrationContract -Registered $Registered -PackageRoot $Root -MemoryRoot $MemoryRoot -RuntimeIdentity $runtimeIdentity -ExpectedEpoch $ExpectedEpoch -RequireEnabled
  if (-not $assessment.current) {
    throw "MCP_BINDING_MISMATCH code=$($assessment.code) expectedPackage=$Root expectedMemory=$MemoryRoot expectedIdentity=$runtimeIdentity expectedEpoch=$ExpectedEpoch actualPackage=$($assessment.packageRoot) actualMemory=$($assessment.memoryRoot) actualEpoch=$($assessment.registrationEpoch) commandMatches=$($assessment.commandMatches) argumentsMatch=$($assessment.argumentsMatch) enabled=$($assessment.enabled)"
  }
}

function Test-McpBinding([object]$Registered,[string]$ExpectedEpoch = '') {
  return [bool](Test-SuperBrainMcpRegistrationContract -Registered $Registered -PackageRoot $Root -MemoryRoot $MemoryRoot -RuntimeIdentity $runtimeIdentity -ExpectedEpoch $ExpectedEpoch -RequireEnabled).current
}

function Test-SuperBrainMcpRegistration([object]$Registered) {
  return [bool](Test-SuperBrainMcpRegistrationContract -Registered $Registered -PackageRoot $Root -MemoryRoot $MemoryRoot).owned
}

function Test-CurrentRuntimeBinding([object]$Binding,[string]$ExpectedEpoch) {
  return [bool](Test-SuperBrainMcpRuntimeBinding -Binding $Binding -PackageRoot $Root -MemoryBaseRoot (Get-SuperBrainMemoryBaseRoot $Root) -RuntimeIdentity $runtimeIdentity -RegistrationEpoch $ExpectedEpoch)
}

$codexPath = Resolve-CodexCli
if ($Remove) {
  $script:removeCall = $null
  $removeError = $null
  try {
    Invoke-SuperBrainFileLock $installLockPath {
      $existingCall = Invoke-Codex @('mcp','get',$McpName,'--json')
      if ($existingCall.code -ne 0) { throw "MCP_REMOVE_ENTRY_UNAVAILABLE: $($existingCall.text)" }
      $existing = ConvertFrom-SuperBrainJsonOutput $existingCall.text 'MCP removal ownership check'
      $ownership = Test-SuperBrainMcpRegistrationContract -Registered $existing -PackageRoot $Root -MemoryRoot $MemoryRoot
      if (-not $ownership.owned) { throw "MCP_REMOVE_FOREIGN_ENTRY_DENIED: $($ownership.code)" }
      $script:removeCall = Invoke-Codex @('mcp','remove',$McpName)
      if ($script:removeCall.code -ne 0) { throw "MCP_REMOVE_FAILED: $($script:removeCall.text)" }
    } -TimeoutMs 60000
  } catch {
    $removeError = $_
  }
  $removed = ($null -eq $removeError -and $script:removeCall -and $script:removeCall.code -eq 0)
  $result = [pscustomobject]@{ ok=$removed; action='remove'; mcpName=$McpName; configurationScope=$configurationScope; checkedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); error=if($removeError){$removeError.Exception.Message}else{''} }
  Write-JsonUtf8NoBom $resultPath $result 6
  if ($Json) { $result | ConvertTo-Json -Depth 6 } else { Write-Host "RUNTIME_REMOVE ok=$removed mcp=$McpName" }
  if (-not $removed) {
    if ($removeError) { throw $removeError }
    throw 'MCP_REMOVE_FAILED'
  }
  exit 0
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
        $script:registrationEpoch = Get-SuperBrainMcpTransportValue $previous 'SUPER_BRAIN_MCP_REGISTRATION_EPOCH'
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
          configurationScope = $configurationScope
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
        '--env','SUPER_BRAIN_MCP_REGISTRATION_SCHEMA=super-brain.codex-mcp.v2',
        '--env',"SUPER_BRAIN_MCP_REGISTRATION_EPOCH=$registrationEpoch",
        '--','python',$mcpLauncher,'--package-root',$Root,'--memory-root',$MemoryRoot
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
          configurationScope = $configurationScope
          configurationAuthority = if ($useExplicitCodexHome) { 'explicit_codex_home' } else { 'codex_native_effective_config' }
          liveTransportState = 'runtime_probe_required'
        restartRequired = $false
        fullRuntimeReady = $false
        runtime = $mcpLauncher
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
