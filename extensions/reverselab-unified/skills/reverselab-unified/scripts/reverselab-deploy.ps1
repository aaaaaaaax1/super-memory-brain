param(
  [string]$InstallRoot = '',
  [string]$OpenReverseLabPath = '',
  [string]$OpenTgtyLabPath = '',
  [ValidateSet('Core','Full')]
  [string]$Profile = 'Full',
  [switch]$RegisterCodexMcp,
  [string]$CodexConfig = '',
  [switch]$Apply,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
  $InstallRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'ReverseLab'
}
if ([string]::IsNullOrWhiteSpace($CodexConfig)) {
  $CodexConfig = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\config.toml'
}

$openReverse = if ([string]::IsNullOrWhiteSpace($OpenReverseLabPath)) { Join-Path $InstallRoot 'open-reverselab' } else { $OpenReverseLabPath }
$openTgty = if ([string]::IsNullOrWhiteSpace($OpenTgtyLabPath)) { Join-Path $InstallRoot 'Open-tgtylab' } else { $OpenTgtyLabPath }
$openReverseMcp = Join-Path $openReverse 'tools\skills\mcp\ReverseLabToolsMCP'
$openTgtyMcp = Join-Path $openTgty 'tools\skills\mcp\ReverseLabToolsMCP'
$log = New-Object System.Collections.ArrayList
$planned = New-Object System.Collections.ArrayList
$manualRemaining = New-Object System.Collections.ArrayList

function Add-Log([string]$Status, [string]$Name, [string]$Detail) {
  [void]$script:log.Add([pscustomobject]@{ status = $Status; name = $Name; detail = $Detail })
}

function Add-Plan([string]$Name, [string]$Command, [string]$Reason) {
  [void]$script:planned.Add([pscustomobject]@{ name = $Name; command = $Command; reason = $Reason })
}

function Test-Cmd([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Step([string]$Name, [string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory = '') {
  $display = "$FilePath $($ArgumentList -join ' ')"
  if (-not $Apply) {
    Add-Plan $Name $display 'planned by one-click ReverseLab deployment'
    return
  }
  Add-Log 'RUN' $Name $display
  if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    & $FilePath @ArgumentList
  } else {
    Push-Location $WorkingDirectory
    try { & $FilePath @ArgumentList } finally { Pop-Location }
  }
  if ($LASTEXITCODE -ne 0) { throw "Step failed: $Name exit=$LASTEXITCODE" }
  Add-Log 'OK' $Name $display
}

function Ensure-Directory([string]$Path) {
  if ($Apply) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
  else { Add-Plan 'create-install-root' "New-Item -ItemType Directory -Force -Path `"$Path`"" 'create ReverseLab install root' }
}

function Ensure-Uv {
  if (Test-Cmd 'uv') { Add-Log 'OK' 'uv' 'uv found in PATH'; return }
  if (-not (Test-Cmd 'python')) { Add-Log 'MISSING' 'uv' 'python is missing, cannot install uv'; return }
  Invoke-Step 'install-uv' 'python' @('-m','pip','install','--user','uv')
}

function Ensure-Repo([string]$Name, [string]$Url, [string]$Path) {
  if (Test-Path -LiteralPath $Path) { Add-Log 'OK' $Name "repo exists: $Path"; return }
  if (-not (Test-Cmd 'git')) { throw "git is required to clone $Name" }
  Invoke-Step "clone-$Name" 'git' @('clone', $Url, $Path)
}

function Ensure-McpConfig {
  if (-not $RegisterCodexMcp) {
    Add-Log 'SKIP' 'register-codex-mcp' 'RegisterCodexMcp was not supplied'
    return
  }
  if (-not (Test-Path -LiteralPath $CodexConfig)) { throw "Codex config not found: $CodexConfig" }
  $marker = '[mcp_servers.reverse_lab_tools]'
  $text = [System.IO.File]::ReadAllText($CodexConfig)
  if ($text.Contains($marker)) {
    Add-Log 'OK' 'register-codex-mcp' 'reverse_lab_tools already present'
    return
  }
  $uvCommand = 'uv'
  $uvInfo = Get-Command uv -ErrorAction SilentlyContinue
  if ($uvInfo) { $uvCommand = $uvInfo.Source }
  $mcpScript = Join-Path $openTgtyMcp 'reverse_lab_tools_mcp.py'
  $block = @"

[mcp_servers.reverse_lab_tools]
command = '$($uvCommand -replace '\\','\\')'
args = ['run', '--project', '$($openTgtyMcp -replace '\\','\\')', 'python', '$($mcpScript -replace '\\','\\')']
startup_timeout_sec = 120
"@
  if (-not $Apply) {
    Add-Plan 'register-codex-mcp' "Append reverse_lab_tools block to `"$CodexConfig`" after backup" 'make MCP available to Codex'
    return
  }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = "$CodexConfig.bak-reverselab-$stamp"
  Copy-Item -LiteralPath $CodexConfig -Destination $backup -Force
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::AppendAllText($CodexConfig, $block + [Environment]::NewLine, $utf8)
  Add-Log 'OK' 'register-codex-mcp' "added reverse_lab_tools; backup=$backup"
}

function Run-Status {
  $statusScript = Join-Path $PSScriptRoot 'reverselab-status.ps1'
  if (Test-Path -LiteralPath $statusScript) {
    Invoke-Step 'status-check' 'powershell' @('-ExecutionPolicy','Bypass','-File',$statusScript,'-OpenReverseLabPath',$openReverse,'-OpenTgtyLabPath',$openTgty,'-Json')
  }
}

function Run-Toolcheck {
  $toolcheck = Join-Path $openReverse 'tools\bin\ai_toolcheck.bat'
  if (Test-Path -LiteralPath $toolcheck) {
    Invoke-Step 'ai-toolcheck-common' $toolcheck @('--board','common')
    if ($Profile -eq 'Full') {
      Invoke-Step 'ai-toolcheck-windows' $toolcheck @('--board','windows')
      Invoke-Step 'ai-toolcheck-android' $toolcheck @('--board','android')
      Invoke-Step 'ai-toolcheck-ctf' $toolcheck @('--board','ctf-website')
    }
  } else {
    Add-Log 'WARN' 'ai-toolcheck' 'tools/bin/ai_toolcheck.bat is not available yet'
  }
}

Ensure-Directory $InstallRoot
if (-not (Test-Cmd 'git')) { Add-Log 'MISSING' 'git' 'Git is required for one-click deployment' }
if (-not (Test-Cmd 'python')) { Add-Log 'MISSING' 'python' 'Python 3.10+ is required for MCP and helper tools' }
Ensure-Uv

Ensure-Repo 'open-reverselab' 'https://github.com/LING71671/open-reverselab.git' $openReverse
Ensure-Repo 'Open-tgtylab' 'https://github.com/GeniusHu-tgty/Open-tgtylab.git' $openTgty

$bootstrap = Join-Path $openReverse 'scripts\misc\bootstrap.ps1'
if (Test-Path -LiteralPath $bootstrap) {
  Invoke-Step 'open-reverselab-core-wrappers' 'powershell' @('-ExecutionPolicy','Bypass','-File',$bootstrap,'-Force')
}

if (Test-Path -LiteralPath $openReverseMcp) { Invoke-Step 'uv-sync-open-reverselab-mcp' 'uv' @('sync','--project',$openReverseMcp) }
if (Test-Path -LiteralPath $openTgtyMcp) { Invoke-Step 'uv-sync-open-tgtylab-mcp' 'uv' @('sync','--project',$openTgtyMcp) }

if ($Profile -eq 'Full') {
  $installer = Join-Path $openReverse 'scripts\misc\install_tools.ps1'
  if (Test-Path -LiteralPath $installer) {
    Invoke-Step 'open-reverselab-full-toolchain' 'powershell' @('-ExecutionPolicy','Bypass','-File',$installer,'-All')
  } else {
    Add-Log 'WARN' 'open-reverselab-full-toolchain' 'install_tools.ps1 not found'
  }
  [void]$manualRemaining.Add('Ghidra may require manual download/extraction and Java setup depending on host.')
  [void]$manualRemaining.Add('x64dbg, Scylla, HxD, Burp Suite, Android SDK platform-tools, emulator/device drivers, and some GUI tools may require manual license, GUI, or archive setup.')
}

Ensure-McpConfig
Run-Status
Run-Toolcheck

$result = [pscustomobject]@{
  ok = ($true)
  mode = if ($Apply) { 'apply' } else { 'plan-only' }
  profile = $Profile
  installRoot = $InstallRoot
  openReverseLab = $openReverse
  openTgtyLab = $openTgty
  registerCodexMcp = [bool]$RegisterCodexMcp
  planned = @($planned)
  log = @($log)
  manualRemaining = @($manualRemaining)
  note = 'One-click deploy installs/clones/syncs/verifies the core ReverseLab stack. GUI/license/device-specific tools are reported when upstream cannot silently install them.'
}

if ($Json) { $result | ConvertTo-Json -Depth 8 }
else {
  Write-Host "REVERSELAB_DEPLOY mode=$($result.mode) profile=$Profile root=$InstallRoot"
  foreach ($item in @($planned)) { Write-Host "PLAN $($item.name): $($item.command)" }
  foreach ($item in @($log)) { Write-Host "$($item.status) $($item.name): $($item.detail)" }
  foreach ($item in @($manualRemaining)) { Write-Host "MANUAL_REMAINING $item" }
}
