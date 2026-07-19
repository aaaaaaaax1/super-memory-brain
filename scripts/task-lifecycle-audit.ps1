param(
  [switch]$Json,
  [int]$StaleDays = 7
)

. (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$manifest = Get-SuperBrainManifest $Root
$memoryBase = Get-SuperBrainMemoryBaseRoot $Root
$sharedRoot = Get-SuperBrainSharedMemoryRoot $Root
$workspace = Join-Path $memoryBase 'workspace'
$outPath = Join-Path $workspace 'last-task-lifecycle-audit.json'

function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-ActiveIds([string]$Path, [string]$Pattern) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $Path -Filter $Pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
    $item = Read-JsonFile $_.FullName
    if ($item -and [string]$item.status -eq 'active' -and -not [string]::IsNullOrWhiteSpace([string]$item.taskId)) { [string]$item.taskId }
  } | Select-Object -Unique)
}

function Test-DiagnosticTaskId([string]$TaskId) {
  return $TaskId -match '^task-(alpha|beta|card-writer|checkpoint-writer|context-writer)$'
}

$activeTaskRoot = Join-Path $sharedRoot 'tasks\active'
$activeCheckpointRoot = Join-Path $workspace 'runtime-state\checkpoints\active'
$activeContextRoot = Join-Path $workspace 'guard-state\current-task-contexts'
$activeContractRoot = Join-Path $workspace 'runtime-state\execution-contracts'
$checkpointIds = @(Get-ActiveIds $activeCheckpointRoot '*.json')
$contextIds = @(Get-ActiveIds $activeContextRoot '*.json')
$contractIds = @(Get-ActiveIds $activeContractRoot '*.json')
$cards = @()
$parseFailures = @()

if (Test-Path -LiteralPath $activeTaskRoot -PathType Container) {
  foreach ($file in @(Get-ChildItem -LiteralPath $activeTaskRoot -Filter '*.task.json' -File -ErrorAction SilentlyContinue)) {
    $task = Read-JsonFile $file.FullName
    if (-not $task) { $parseFailures += $file.FullName; continue }
    $updated = $null
    try { $updated = [datetime]::Parse([string]$task.updatedAt) } catch { $updated = $file.LastWriteTime }
    $ageDays = [Math]::Round(((Get-Date) - $updated).TotalDays, 2)
    $taskId = [string]$task.taskId
    $pendingCount = @($task.pendingSteps | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    $bound = ($checkpointIds -contains $taskId) -or ($contextIds -contains $taskId) -or ($contractIds -contains $taskId)
    $cards += [pscustomobject]@{
      taskId = $taskId
      taskName = [string]$task.taskName
      status = [string]$task.status
      updatedAt = [string]$task.updatedAt
      ageDays = $ageDays
      pendingCount = $pendingCount
      nextAction = [string]$task.nextAction
      bound = $bound
      diagnostic = Test-DiagnosticTaskId $taskId
      sourcePath = $file.FullName
    }
  }
}

$diagnosticCards = @($cards | Where-Object { $_.diagnostic })
$zeroPendingCards = @($cards | Where-Object { $_.pendingCount -eq 0 })
$unboundCards = @($cards | Where-Object { -not $_.bound })
$staleUnboundCards = @($unboundCards | Where-Object { $_.ageDays -ge $StaleDays })
$storeAudit = $null
try {
  $raw = @(& (Join-Path $PSScriptRoot 'task-state-store.ps1') -Action Audit -Json 2>$null)
  if ($LASTEXITCODE -eq 0) { $storeAudit = (($raw -join "`n") | ConvertFrom-Json) }
} catch { $storeAudit = $null }

$findingCount = $diagnosticCards.Count + $zeroPendingCards.Count + $staleUnboundCards.Count + $parseFailures.Count
$result = [pscustomobject]@{
  ok = ($parseFailures.Count -eq 0 -and ($null -eq $storeAudit -or $storeAudit.automaticContinuationSafe -eq $true))
  checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  schema = 'super-brain.task-lifecycle-audit.v1'
  version = [string]$manifest.version
  staleDays = $StaleDays
  counts = [pscustomobject]@{
    activeCards = $cards.Count
    activeCheckpoints = $checkpointIds.Count
    activeContexts = $contextIds.Count
    activeContracts = $contractIds.Count
    diagnosticCards = $diagnosticCards.Count
    zeroPendingActiveCards = $zeroPendingCards.Count
    unboundActiveCards = $unboundCards.Count
    staleUnboundActiveCards = $staleUnboundCards.Count
    parseFailures = $parseFailures.Count
    findings = $findingCount
  }
  pointerState = if ($storeAudit) { [pscustomobject]@{
    mismatch = [bool]$storeAudit.pointerMismatch
    automaticContinuationSafe = [bool]$storeAudit.automaticContinuationSafe
    automaticContinuationTaskId = [string]$storeAudit.automaticContinuationTaskId
    parallelTaskIds = @($storeAudit.parallelTaskIds)
    distinctCompatibilityTaskIds = @($storeAudit.compatibilityPointers.distinctTaskIds)
  } } else { $null }
  diagnosticCards = @($diagnosticCards)
  zeroPendingActiveCards = @($zeroPendingCards)
  staleUnboundActiveCards = @($staleUnboundCards)
  parseFailures = @($parseFailures)
  guard = 'Known diagnostic task IDs are never resume candidates. Empty or stale unbound active cards are findings, not automatically completed user tasks.'
  path = $outPath
}

if (-not (Test-Path -LiteralPath $workspace)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null }
Write-JsonUtf8NoBom $outPath $result 12
if ($Json) { Get-Content -LiteralPath $outPath -Raw -Encoding UTF8 } else {
  Write-Host "TASK_LIFECYCLE_AUDIT ok=$($result.ok) active=$($cards.Count) diagnostic=$($diagnosticCards.Count) zeroPending=$($zeroPendingCards.Count) staleUnbound=$($staleUnboundCards.Count) pointerMismatch=$($result.pointerState.mismatch)"
}
if (-not $result.ok) { exit 1 }
exit 0
