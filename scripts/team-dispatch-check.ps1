param(
  [switch]$ArchitectureChange,
  [switch]$LongTask,
  [switch]$BroadSearch,
  [switch]$LogicSafetyRequired,
  [switch]$RepeatedFailure,
  [switch]$VerificationRequired,
  [switch]$Parallelizable,
  [switch]$MemorySensitive,
  [switch]$SimpleDirect,
  [switch]$KnownSingleFile,
  [switch]$FastRequested,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$score = 0
$reasons = @()

function Add-DispatchScore([int]$Delta, [string]$Reason) {
  $script:score += $Delta
  $script:reasons += $Reason
}

if ($ArchitectureChange) { Add-DispatchScore 2 'architecture_change' }
if ($LongTask) { Add-DispatchScore 2 'long_task' }
if ($BroadSearch) { Add-DispatchScore 2 'broad_search' }
if ($LogicSafetyRequired) { Add-DispatchScore 2 'logic_safety_required' }
if ($RepeatedFailure) { Add-DispatchScore 2 'repeated_failure_or_drift' }
if ($VerificationRequired) { Add-DispatchScore 1 'verification_required' }
if ($Parallelizable) { Add-DispatchScore 1 'parallelizable' }
if ($MemorySensitive) { Add-DispatchScore 1 'memory_sensitive' }
if ($SimpleDirect) { Add-DispatchScore -2 'simple_direct' }
if ($KnownSingleFile) { Add-DispatchScore -2 'known_single_file' }
if ($FastRequested) { Add-DispatchScore -1 'fast_requested' }

if ($score -le 1) {
  $level = 'direct'
} elseif ($score -le 3) {
  $level = 'single_delegate'
} elseif ($score -le 5) {
  $level = 'team_parallel'
} else {
  $level = 'review_board'
}

$result = [pscustomobject]@{
  ok = $true
  score = $score
  dispatchLevel = $level
  reasons = @($reasons)
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

if ($Json) {
  $result | ConvertTo-Json -Depth 6
} else {
  Write-Host "TEAM_DISPATCH score=$score level=$level reasons=$($reasons -join ',')"
}

exit 0
