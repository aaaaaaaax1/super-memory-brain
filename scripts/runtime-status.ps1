[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$CodexHome = "$env:USERPROFILE\.codex",
  [string]$MemoryRoot = '',
  [string]$McpName = 'super-memory-brain',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root }
$runtimeCli = Join-Path $Root 'runtime\brain_cli.py'
$healthRaw = @(& python $runtimeCli --package-root $Root --memory-root $MemoryRoot health 2>$null)
$health = $null
try { $health = (($healthRaw -join "`n") | ConvertFrom-Json) } catch {}

$knownRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
$known = Get-ChildItem -LiteralPath $knownRoot -Recurse -File -Filter 'codex.exe' -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notlike '*WindowsApps*' } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
$codex = if ($known) { [pscustomobject]@{ Source=$known.FullName } } else { Get-Command codex.exe -ErrorAction SilentlyContinue }
if (-not $codex) { $codex = Get-Command codex -ErrorAction SilentlyContinue }
$mcp = $null
if ($codex) {
  $mcpRaw = @(& $codex.Source mcp get $McpName --json 2>$null)
  if ($LASTEXITCODE -eq 0) { try { $mcp = (($mcpRaw -join "`n") | ConvertFrom-Json) } catch {} }
}

$result = [pscustomobject]@{
  ok = ($health -and $health.ok -eq $true -and $mcp)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  runtimeHealth = $health
  mcpRegistered = ($null -ne $mcp)
  mcpName = $McpName
  mcp = $mcp
  codexHome = [IO.Path]::GetFullPath($CodexHome)
}
if ($Json) { $result | ConvertTo-Json -Depth 10 } else {
  Write-Host "RUNTIME_STATUS ok=$($result.ok) mcp=$($result.mcpRegistered) health=$($health.ok)"
}
if (-not $result.ok) { exit 1 }
exit 0
