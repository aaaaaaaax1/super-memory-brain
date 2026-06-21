param(
  [Parameter(Mandatory=$true)]
  [string]$Destination
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $Destination)) {
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
}

Copy-Item -LiteralPath $root -Destination (Join-Path $Destination 'super-memory-brain-package') -Recurse -Force
Write-Host "Package migrated to: $(Join-Path $Destination 'super-memory-brain-package')"
