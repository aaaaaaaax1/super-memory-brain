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
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root }
$MemoryRoot = Get-NormalizedSuperBrainRoot $MemoryRoot
$workspace = Join-Path (Get-SuperBrainMemoryBaseRoot $Root) 'workspace'
$statePath = Join-Path $workspace 'first-load-bootstrap.json'
$entryRoot = Join-Path $CodexSkills 'super-memory-brain'
$manifest = Get-SuperBrainManifest $Root

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
  try {
    $env:CODEX_HOME = $CodexHome
    $raw = @(& $CodexPath @Arguments 2>&1)
    $code = $LASTEXITCODE
  } finally {
    if ($null -eq $previous) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $previous }
  }
  $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
  if ($code -ne 0) { return [pscustomobject]@{ code=$code; value=$null; text=$text } }
  try { return [pscustomobject]@{ code=$code; value=($text | ConvertFrom-Json); text='' } }
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
  $packageArg = Get-McpTransportValue $Registered '--package-root'
  $memoryArg = Get-McpTransportValue $Registered '--memory-root'
  return ((Same-Path $registeredPackage $Root) -and (Same-Path $packageArg $Root) -and (Same-Path $registeredMemory $MemoryRoot) -and (Same-Path $memoryArg $MemoryRoot))
}

function Read-Marker([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
}

New-Item -ItemType Directory -Force -Path $workspace | Out-Null
$packageMarker = Read-Marker (Join-Path $entryRoot 'package-root.txt')
$memoryMarker = Read-Marker (Join-Path $entryRoot 'memory-root.txt')
$entrySkillOk = (Test-Path -LiteralPath (Join-Path $entryRoot 'SKILL.md')) -and (Same-Path $packageMarker $Root) -and (Same-Path $memoryMarker $MemoryRoot)
$codexPath = Resolve-CodexCli
$mcpProbe = Invoke-CodexJson $codexPath @('mcp','get','super-memory-brain','--json')
$registered = $mcpProbe.value
$mcpBindingOk = Test-McpBinding $registered
$repairAttempted = $false
$repairResult = $null
$cacheUsed = $false
$previous = Read-JsonFile $statePath
if (-not $Force -and $previous -and [string]$previous.version -eq [string]$manifest.version -and (Same-Path ([string]$previous.packageRoot) $Root) -and $entrySkillOk -and $mcpBindingOk) {
  $cacheUsed = $true
}

if (-not $mcpBindingOk -and $RepairMcp -and -not $cacheUsed) {
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
}

$memoryRootExists = Test-Path -LiteralPath $MemoryRoot
$ok = ($entrySkillOk -and $memoryRootExists -and $mcpBindingOk)
$needsNewTask = [bool]($repairAttempted -and $repairResult -and $repairResult.ok -eq $true)
$action = if ($ok) { 'ready' } elseif (-not $entrySkillOk) { 'run_one_click_install' } elseif ($repairAttempted) { 'inspect_mcp_repair_and_open_new_task' } else { 'repair_mcp_on_first_load' }
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
  memoryRootExists = $memoryRootExists
  mcpRegistered = ($null -ne $registered)
  mcpBindingOk = $mcpBindingOk
  repairAttempted = $repairAttempted
  repairOk = if ($repairResult) { [bool]$repairResult.ok } else { $false }
  needsNewTask = $needsNewTask
  cacheUsed = $cacheUsed
  action = $action
  repairSwitch = '-RepairMcp'
  rawPromptStored = $false
}
Write-JsonUtf8NoBom $statePath $result 10
if ($Json) { $result | ConvertTo-Json -Depth 10 } else { Write-Host "FIRST_LOAD_BOOTSTRAP ok=$($result.ok) entry=$($result.entrySkillOk) mcp=$($result.mcpBindingOk) action=$action" }
if ($FailOnNotReady -and -not $ok) { exit 1 }
exit 0
