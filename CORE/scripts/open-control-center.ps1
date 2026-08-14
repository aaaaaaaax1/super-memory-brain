[CmdletBinding(PositionalBinding=$false)]
param(
  [int]$Port = 0,
  [ValidateRange(60,86400)]
  [int]$IdleSeconds = 900,
  [switch]$NoOpen,
  [switch]$Wait,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $root 'runtime\brain_ui_server.py'
$assetsRoot = Join-Path $root 'ui\dist'
if (-not (Test-Path -LiteralPath $serverPath -PathType Leaf)) { throw 'BRAIN_UI_SERVER_MISSING' }
if (-not (Test-Path -LiteralPath (Join-Path $assetsRoot 'index.html') -PathType Leaf)) { throw 'BRAIN_UI_ASSETS_MISSING' }

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if ($null -eq $python) { throw 'BRAIN_UI_PYTHON_UNAVAILABLE' }

$stateRoot = Get-SuperBrainMemoryBaseRoot $root
$workspaceRoot = Split-Path -Parent $root
$workspaceKey = Get-SuperBrainWorkspaceKey $workspaceRoot
$arguments = @($serverPath, '--state-root', $stateRoot, '--assets-root', $assetsRoot, '--workspace-key', $workspaceKey, '--port', [string]$Port, '--idle-seconds', [string]$IdleSeconds)
if (-not $NoOpen) { $arguments += '--open' }

if ($Wait) {
  & $python.Source @arguments
  exit $LASTEXITCODE
}

$quotedArguments = @($arguments | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' }) -join ' '
$process = Start-Process -FilePath $python.Source -ArgumentList $quotedArguments -WorkingDirectory $root -WindowStyle Hidden -PassThru
$result = [pscustomobject]@{
  ok = $true
  schema = 'super-brain.control-center-launch.v1'
  processId = $process.Id
  opened = -not $NoOpen
  idleSeconds = $IdleSeconds
}
if ($Json) { $result | ConvertTo-Json -Compress } else { Write-Host "Super Brain Control Center started (pid=$($process.Id))." }
