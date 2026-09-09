[CmdletBinding(PositionalBinding=$false)]
param(
  [ValidateSet('Prompt','Shared','SplitMemory')]
  [string]$MemoryMode = 'Shared',
  [string]$Neurobase = '',
  [string]$ZCodeSkills = "$env:USERPROFILE\.zcode\skills",
  [string]$CodexSkills = "$env:USERPROFILE\.codex\skills",
  [switch]$IncludeZCode,
  [switch]$SkipVerify,
  [string]$TransactionRoot = '',
  [switch]$Json
)

# Explicit upgrade surface.  All transaction, rollback, and verification
# behavior remains owned by the single bootstrap orchestrator. Use named
# splatting so switch/string parameters remain typed across the script call.
$arguments = @{
  MemoryMode = $MemoryMode
  Neurobase = $Neurobase
  ZCodeSkills = $ZCodeSkills
  CodexSkills = $CodexSkills
  Upgrade = $true
}
if ($IncludeZCode) { $arguments.IncludeZCode = $true }
if ($SkipVerify) { $arguments.SkipVerify = $true }
if ($TransactionRoot) { $arguments.TransactionRoot = $TransactionRoot }
if ($Json) { $arguments.Json = $true }
& (Join-Path $PSScriptRoot 'bootstrap.ps1') @arguments
exit $LASTEXITCODE
