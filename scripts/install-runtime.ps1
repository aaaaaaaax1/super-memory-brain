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
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root }
$CodexHome = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexHome))
$configPath = Join-Path $CodexHome 'config.toml'
$runtimeCli = Join-Path $Root 'runtime\brain_cli.py'
$mcpScript = Join-Path $Root 'runtime\brain_mcp.py'
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$resultPath = Join-Path $workspace 'last-runtime-install.json'

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

function Assert-McpBinding([object]$Registered) {
  $registeredPackage = Get-McpTransportValue $Registered 'SUPER_BRAIN_PACKAGE_ROOT'
  $registeredMemory = Get-McpTransportValue $Registered 'NEXSANDBASE_HOME'
  $packageArg = Get-McpTransportValue $Registered '--package-root'
  $memoryArg = Get-McpTransportValue $Registered '--memory-root'
  $samePackage = (Get-NormalizedSuperBrainRoot $registeredPackage) -eq (Get-NormalizedSuperBrainRoot $Root) -and (Get-NormalizedSuperBrainRoot $packageArg) -eq (Get-NormalizedSuperBrainRoot $Root)
  $sameMemory = (Get-NormalizedSuperBrainRoot $registeredMemory) -eq (Get-NormalizedSuperBrainRoot $MemoryRoot) -and (Get-NormalizedSuperBrainRoot $memoryArg) -eq (Get-NormalizedSuperBrainRoot $MemoryRoot)
  if (-not $samePackage -or -not $sameMemory -or $Registered.enabled -ne $true) {
    throw "MCP_BINDING_MISMATCH expectedPackage=$Root expectedMemory=$MemoryRoot actualPackage=$registeredPackage actualMemory=$registeredMemory packageArg=$packageArg memoryArg=$memoryArg enabled=$($Registered.enabled)"
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

$evalArguments = @(
  '--package-root', $Root,
  '--memory-root', $MemoryRoot,
  '--mcp-replay'
)
$evalMode = 'full-recall'
if ([int]$health.memoryCount -eq 0) {
  # A fresh install has a valid runtime but no durable memory to replay yet.
  $evalArguments += '--contract-only'
  $evalMode = 'bootstrap-contract-only'
}
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

$previous = $null
$previousCall = Invoke-Codex @('mcp','get',$McpName,'--json')
if ($previousCall.code -eq 0) { try { $previous = ($previousCall.text | ConvertFrom-Json) } catch {} }

try {
  if ($previous) {
    $removeCall = Invoke-Codex @('mcp','remove',$McpName)
    if ($removeCall.code -ne 0) { throw "EXISTING_MCP_REMOVE_FAILED: $($removeCall.text)" }
  }
  $addArgs = @(
    'mcp','add',$McpName,
    '--env',"SUPER_BRAIN_PACKAGE_ROOT=$Root",
    '--env',"NEXSANDBASE_HOME=$MemoryRoot",
    '--','python',$mcpScript,'--package-root',$Root,'--memory-root',$MemoryRoot
  )
  $addCall = Invoke-Codex $addArgs
  if ($addCall.code -ne 0) { throw "MCP_ADD_FAILED: $($addCall.text)" }
  $verifyCall = Invoke-Codex @('mcp','get',$McpName,'--json')
  if ($verifyCall.code -ne 0) { throw "MCP_VERIFY_FAILED: $($verifyCall.text)" }
  $registered = ($verifyCall.text | ConvertFrom-Json)
  Assert-McpBinding $registered
  $result = [pscustomobject]@{
    ok = $true
    action = 'install'
    checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    version = (Get-SuperBrainManifest $Root).version
    mcpName = $McpName
    codexCli = $codexPath
    packageRoot = $Root
    memoryRoot = $MemoryRoot
    runtime = $mcpScript
    tools = @('brain_recall','brain_status','brain_recent')
    evaluationMode = $evalMode
    contract = [pscustomobject]@{ total=$eval.total; passed=$eval.passed; p50Ms=$eval.latency.p50Ms; p95Ms=$eval.latency.p95Ms }
    configBackup = if ($configExisted) { $configBackup } else { '' }
    previousMcpReplaced = ($null -ne $previous)
    registered = $registered
    rollback = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'install-runtime.ps1')`" -Remove"
  }
  Write-JsonUtf8NoBom $resultPath $result 12
  if ($Json) { $result | ConvertTo-Json -Depth 12 } else {
    Write-Host "RUNTIME_INSTALL_OK mcp=$McpName tools=3 p50Ms=$($eval.latency.p50Ms) p95Ms=$($eval.latency.p95Ms)"
    Write-Host 'Open a new Codex task to load the MCP tools.'
  }
  exit 0
} catch {
  if ($configExisted -and (Test-Path -LiteralPath $configBackup)) {
    Copy-Item -LiteralPath $configBackup -Destination $configPath -Force
  } elseif (-not $configExisted -and (Test-Path -LiteralPath $configPath)) {
    Remove-Item -LiteralPath $configPath -Force
  }
  throw
}
