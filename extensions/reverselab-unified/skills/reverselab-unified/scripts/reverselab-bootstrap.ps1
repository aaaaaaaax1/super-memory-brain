param(
  [string]$InstallRoot = '',
  [ValidateSet('Core','Full')]
  [string]$Profile = 'Core',
  [switch]$Apply,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
  $InstallRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'ReverseLab'
}

$openReverse = Join-Path $InstallRoot 'open-reverselab'
$openTgty = Join-Path $InstallRoot 'Open-tgtylab'
$actions = @()

function Add-Action([string]$Name, [string]$Command, [string]$Reason) {
  $script:actions += [pscustomobject]@{ name = $Name; command = $Command; reason = $Reason }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Add-Action 'install-git' 'Install Git for Windows from https://git-scm.com/download/win' 'git is required to clone upstream repositories'
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
  Add-Action 'install-python' 'Install Python 3.10+ from https://www.python.org/downloads/windows/' 'Python is required for MCP and helper scripts'
}
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
  Add-Action 'install-uv' 'python -m pip install --user uv' 'uv is recommended for Open-tgtylab MCP startup'
}
if (-not (Test-Path -LiteralPath $openReverse)) {
  Add-Action 'clone-open-reverselab' "git clone https://github.com/LING71671/open-reverselab.git `"$openReverse`"" 'clone LING71671/open-reverselab'
}
if (-not (Test-Path -LiteralPath $openTgty)) {
  Add-Action 'clone-open-tgtylab' "git clone https://github.com/GeniusHu-tgty/Open-tgtylab.git `"$openTgty`"" 'clone GeniusHu-tgty/Open-tgtylab'
}

$openReverseBootstrap = Join-Path $openReverse 'scripts\misc\bootstrap.ps1'
$openReverseInstaller = Join-Path $openReverse 'scripts\misc\install_tools.ps1'
$openReverseMcp = Join-Path $openReverse 'tools\skills\mcp\ReverseLabToolsMCP'
$openTgtyMcp = Join-Path $openTgty 'tools\skills\mcp\ReverseLabToolsMCP'

if (Test-Path -LiteralPath $openReverseBootstrap) {
  Add-Action 'create-open-reverselab-wrappers' "powershell -ExecutionPolicy Bypass -File `"$openReverseBootstrap`" -Force" 'create portable tools/bin wrappers for core ReverseLab commands'
}
if ((Test-Path -LiteralPath $openReverseMcp) -and (Get-Command uv -ErrorAction SilentlyContinue)) {
  Add-Action 'uv-sync-open-reverselab-mcp' "uv sync --project `"$openReverseMcp`"" 'install ReverseLabToolsMCP Python dependencies for open-reverselab'
}
if ((Test-Path -LiteralPath $openTgtyMcp) -and (Get-Command uv -ErrorAction SilentlyContinue)) {
  Add-Action 'uv-sync-open-tgtylab-mcp' "uv sync --project `"$openTgtyMcp`"" 'install ReverseLabToolsMCP Python dependencies for Open-tgtylab'
}

if ($Profile -eq 'Full') {
  Add-Action 'full-toolchain-note' 'Read references/install-and-share.md for full toolchain setup details.' 'full setup includes third-party GUI tools, network downloads, and tools that may require local GUI/path confirmation'
  if (Test-Path -LiteralPath $openReverseInstaller) {
    Add-Action 'plan-open-reverselab-all-tools' "powershell -ExecutionPolicy Bypass -File `"$openReverseInstaller`" -All" 'install Android, Windows, CTF, Common, Go, and MCP tool groups from open-reverselab'
  }
  Add-Action 'manual-gui-tools' 'Verify/install Ghidra, x64dbg, Scylla, HxD, Burp Suite, Android SDK platform-tools, and optional emulator tools according to upstream README files.' 'some full-stack reverse-engineering tools cannot be guaranteed by silent CLI install because they require GUI, license, archive extraction, or host-specific configuration'
}

$result = [ordered]@{
  ok = $true
  mode = if ($Apply) { 'apply' } else { 'plan-only' }
  profile = $Profile
  installRoot = $InstallRoot
  plannedActions = @($actions)
  warning = 'This script does not edit Codex/ZCode global config. Use reverselab-deploy.ps1 -RegisterCodexMcp for one-click MCP registration. Full profile may require third-party downloads and local GUI/path steps.'
}

if ($Apply) {
  New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
  foreach ($action in @($actions)) {
    if ($action.name -eq 'clone-open-reverselab') {
      & git clone 'https://github.com/LING71671/open-reverselab.git' $openReverse
      if ($LASTEXITCODE -ne 0) { throw "Failed action: $($action.name)" }
    } elseif ($action.name -eq 'clone-open-tgtylab') {
      & git clone 'https://github.com/GeniusHu-tgty/Open-tgtylab.git' $openTgty
      if ($LASTEXITCODE -ne 0) { throw "Failed action: $($action.name)" }
    } elseif ($action.name -eq 'create-open-reverselab-wrappers') {
      & powershell -ExecutionPolicy Bypass -File $openReverseBootstrap -Force
      if ($LASTEXITCODE -ne 0) { throw "Failed action: $($action.name)" }
    } elseif ($action.name -eq 'uv-sync-open-reverselab-mcp') {
      & uv sync --project $openReverseMcp
      if ($LASTEXITCODE -ne 0) { throw "Failed action: $($action.name)" }
    } elseif ($action.name -eq 'uv-sync-open-tgtylab-mcp') {
      & uv sync --project $openTgtyMcp
      if ($LASTEXITCODE -ne 0) { throw "Failed action: $($action.name)" }
    } elseif ($action.name -eq 'plan-open-reverselab-all-tools') {
      & powershell -ExecutionPolicy Bypass -File $openReverseInstaller -All
      if ($LASTEXITCODE -ne 0) { throw "Failed action: $($action.name)" }
    }
  }
}

if ($Json) { [pscustomobject]$result | ConvertTo-Json -Depth 8 }
else {
  Write-Host "REVERSELAB_BOOTSTRAP mode=$($result.mode) profile=$Profile actions=$(@($actions).Count) root=$InstallRoot"
  foreach ($action in @($actions)) { Write-Host "ACTION $($action.name): $($action.command)" }
}
