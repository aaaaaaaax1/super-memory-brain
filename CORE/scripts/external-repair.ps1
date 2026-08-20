[CmdletBinding()]
param(
  [ValidateSet('inspect','plan','verify')][string]$Action = 'inspect',
  [ValidateSet('rapid','standard','critical')][string]$Mode = 'rapid',
  [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot),
  [string[]]$Path = @(),
  [string[]]$Test = @()
)

$ErrorActionPreference = 'Stop'
$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) { throw 'Python is required for the external repair lane.' }

$arguments = @(
  (Join-Path $PSScriptRoot 'external_repair.py'),
  '--package-root', $PackageRoot,
  '--action', $Action,
  '--mode', $Mode,
  '--json'
)
foreach ($item in $Path) { $arguments += @('--path', $item) }
foreach ($item in $Test) { $arguments += @('--test', $item) }

& $python.Source @arguments
exit $LASTEXITCODE
