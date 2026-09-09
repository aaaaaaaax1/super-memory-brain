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
# behavior remains owned by the single bootstrap orchestrator.
$arguments = @('-MemoryMode', $MemoryMode, '-Neurobase', $Neurobase, '-ZCodeSkills', $ZCodeSkills, '-CodexSkills', $CodexSkills, '-Upgrade')
if ($IncludeZCode) { $arguments += '-IncludeZCode' }
if ($SkipVerify) { $arguments += '-SkipVerify' }
if ($TransactionRoot) { $arguments += @('-TransactionRoot', $TransactionRoot) }
if ($Json) { $arguments += '-Json' }
& (Join-Path $PSScriptRoot 'bootstrap.ps1') @arguments
exit $LASTEXITCODE
