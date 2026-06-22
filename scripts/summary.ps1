param(
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path $Path)) { return $null }
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

$manifestPath = Join-Path $Root 'manifest.json'
$memoryRoot = Get-SuperBrainActiveMemoryRoot $Root
$statePath = Join-Path $Root 'memory\workspace\super-brain-state.json'
$verifyPath = Join-Path $Root 'memory\workspace\last-verify-package.json'
$evalPath = Join-Path $Root 'memory\workspace\last-memory-eval.json'
$statusCardPath = Join-Path $Root 'memory\workspace\status-card.json'
$memoryPath = Join-Path $memoryRoot 'sandglass.txt'

$manifest = Read-JsonFile $manifestPath
$state = Read-JsonFile $statePath
$lastVerify = Read-JsonFile $verifyPath
$lastEval = Read-JsonFile $evalPath
$statusCard = Read-JsonFile $statusCardPath

$memoryLines = 0
if (Test-Path $memoryPath) {
  $memoryLines = @(Get-Content -LiteralPath $memoryPath -Encoding UTF8).Count
}

$summary = [pscustomobject]@{
  ok = (($null -ne $manifest) -and (Test-Path $memoryPath))
  version = if ($null -ne $manifest) { $manifest.version } else { 'UNKNOWN' }
  packageRoot = $Root
  memoryPath = $memoryPath
  memoryExists = Test-Path $memoryPath
  memoryLines = $memoryLines
  stateExists = Test-Path $statePath
  stateOk = if ($null -ne $state) { [bool]$state.ok } else { $false }
  hookOk = if ($null -ne $state) { [bool]$state.hookOk } else { $false }
  lastVerifyExists = Test-Path $verifyPath
  lastVerifyOk = if ($null -ne $lastVerify) { [bool]$lastVerify.ok } else { $false }
  lastEvalExists = Test-Path $evalPath
  lastEvalOk = if ($null -ne $lastEval) { [bool]$lastEval.ok } else { $false }
  lastEvalPassRate = if ($null -ne $lastEval) { $lastEval.passRate } else { $null }
  statusCardExists = Test-Path $statusCardPath
  statusCardOk = if ($null -ne $statusCard) { [bool]$statusCard.ok } else { $false }
  statusCardUpdatedAt = if ($null -ne $statusCard) { $statusCard.updatedAt } else { $null }
  stateUpdatedAt = if ($null -ne $state) { $state.updatedAt } else { $null }
  lastVerifyCheckedAt = if ($null -ne $lastVerify) { $lastVerify.checkedAt } else { $null }
  lastEvalCheckedAt = if ($null -ne $lastEval) { $lastEval.checkedAt } else { $null }
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 5
} else {
  Write-Host "SUPER_BRAIN_SUMMARY version=$($summary.version) ok=$($summary.ok) stateOk=$($summary.stateOk) hookOk=$($summary.hookOk) lastVerifyOk=$($summary.lastVerifyOk) lastEvalOk=$($summary.lastEvalOk) statusCardOk=$($summary.statusCardOk) evalPassRate=$($summary.lastEvalPassRate) memoryLines=$($summary.memoryLines)"
  Write-Host "package=$($summary.packageRoot)"
  Write-Host "memory=$($summary.memoryPath)"
}

exit 0
