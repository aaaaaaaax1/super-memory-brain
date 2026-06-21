$ErrorActionPreference = 'Stop'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$root = Split-Path -Parent $PSScriptRoot
$memoryRoot = Join-Path $root 'memory'
$backupRoot = Join-Path $root "backup-$stamp"
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

$paths = @(
  "$env:USERPROFILE\.zcode\skills\super-memory-brain",
  "$env:USERPROFILE\.zcode\skills\skill-orchestrator",
  "$env:USERPROFILE\.zcode\skills\plusunm-g1",
  "$env:USERPROFILE\.zcode\skills\nexsandglass-dedicated-memory",
  $memoryRoot
)

foreach ($p in $paths) {
  if (Test-Path $p) {
    $name = Split-Path $p -Leaf
    Copy-Item -LiteralPath $p -Destination (Join-Path $backupRoot $name) -Recurse -Force
  }
}

Write-Host "Backup created: $backupRoot"
