param(
  [string]$Destination = ""
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Destination)) {
  $manifest = Get-Content -LiteralPath (Join-Path $Root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $Destination = Join-Path (Split-Path -Parent $Root) ("super-memory-brain-package-release-v" + $manifest.version)
}

& (Join-Path $PSScriptRoot 'verify-package.ps1')
if ($LASTEXITCODE -ne 0) {
  throw 'Package verification failed; release aborted.'
}

& (Join-Path $PSScriptRoot 'prepare-share.ps1') -Destination $Destination
& (Join-Path $PSScriptRoot 'verify-share.ps1') -Destination $Destination -SkipPrepare
if ($LASTEXITCODE -ne 0) {
  throw 'Share verification failed; release aborted.'
}

Write-Host "RELEASE_PACKAGE_OK $Destination"
