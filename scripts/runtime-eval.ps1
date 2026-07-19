[CmdletBinding(PositionalBinding=$false)]
param(
  [string]$MemoryRoot = '',
  [switch]$Json,
  [switch]$McpReplay
)

. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MemoryRoot)) { $MemoryRoot = Get-SuperBrainActiveMemoryRoot $Root }
$runner = Join-Path $Root 'runtime\brain_eval.py'
$arguments = @('--package-root', $Root, '--memory-root', $MemoryRoot)
if ($McpReplay) { $arguments += '--mcp-replay' }
$raw = @(& python $runner @arguments 2>$null)
$text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
if ($Json) { Write-Output $text } else {
  $result = $text | ConvertFrom-Json
  Write-Host "RUNTIME_EVAL ok=$($result.ok) total=$($result.total) passed=$($result.passed) failed=$($result.failed) p50Ms=$($result.latency.p50Ms) p95Ms=$($result.latency.p95Ms)"
}
exit $LASTEXITCODE
