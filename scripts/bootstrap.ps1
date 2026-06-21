param(
  [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot 'install.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot 'repair-hook.ps1') -PackageRoot $Root
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot 'encoding-check.ps1') -Fix
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot 'graph-normalize.ps1') -Fix
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not $SkipVerify) {
  & (Join-Path $PSScriptRoot 'verify-package.ps1') -Integration
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "BOOTSTRAP_OK $Root"
